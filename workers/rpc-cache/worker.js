// Cloudflare Worker for The Human Fund frontend.
//
// Two routes:
//   POST /                  → JSON-RPC caching proxy (default; Alchemy upstream)
//   POST /onramp/token      → mint a Coinbase Onramp session token
//
// Onramp moved to mandatory session-token auth on 2025-07-31, so the
// pure-client cbpay-js flow no longer works. We hold the Secret API
// Key here, sign a CDP JWT, and forward to api.developer.coinbase.com.
// The frontend then opens pay.coinbase.com/buy/select-asset?sessionToken=…
//
// Deploy: cd workers/rpc-cache && wrangler deploy
// Secrets: COINBASE_CDP_KEY_NAME, COINBASE_CDP_KEY_SECRET (PEM)

const CACHE_TTL = 900; // 15 minutes

const CORS_HEADERS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
  "Access-Control-Allow-Headers": "Content-Type",
  "Access-Control-Expose-Headers": "X-Cache, X-Cache-Age",
};

// Cache-key version. Bump this any time the cache-payload schema changes
// (e.g. adding stamped headers like X-Cached-At) to force eviction of all
// stale entries that won't carry the new metadata. Otherwise serves limp
// across deploys until the 15-min TTL expires per entry.
const CACHE_KEY_VERSION = "v3";

// Build a stable cache key by stripping volatile fields (request id, but
// NOT block ranges — those affect the response set and must be in the key).
function buildCacheKey(parsed) {
  const method = parsed.method;
  let key = null;

  if (method === "eth_blockNumber") {
    key = "eth_blockNumber";
  } else if (method === "eth_call") {
    const p = parsed.params || [];
    const call = p[0] || {};
    // eth_call's block tag is ignored (defaults to "latest"); per-block
    // pinning isn't used by the frontend and inflating the key with it
    // would tank cache hit rate.
    key = `eth_call:${(call.to || "").toLowerCase()}:${(call.data || "").toLowerCase()}`;
  } else if (method === "eth_getLogs") {
    const p = (parsed.params || [])[0] || {};
    // fromBlock/toBlock MUST be in the key — different ranges return
    // different log sets. Without this every chunked queryFilter() call
    // returned the first chunk's events, duplicating data on the chart
    // and dropping events from later chunks.
    key = `eth_getLogs:${(p.address || "").toLowerCase()}:${p.fromBlock || ""}:${p.toBlock || ""}:${JSON.stringify(p.topics || [])}`;
  }

  return key ? `${CACHE_KEY_VERSION}:${key}` : null;
}

async function sha256(text) {
  const buf = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(text));
  return [...new Uint8Array(buf)].map(b => b.toString(16).padStart(2, "0")).join("");
}

function jsonResp(body, headers) {
  return new Response(body, { headers: { ...CORS_HEADERS, "Content-Type": "application/json", ...headers } });
}

export default {
  async fetch(request, env) {
    if (request.method === "OPTIONS") {
      return new Response(null, { headers: CORS_HEADERS });
    }

    const url = new URL(request.url);

    // Onramp session-token endpoint
    if (url.pathname === "/onramp/token") {
      if (request.method !== "POST") {
        return jsonResp(JSON.stringify({ error: "POST only" }), { status: 405 });
      }
      return handleOnrampToken(request, env);
    }

    // Default: JSON-RPC caching proxy (root path, used by ethers BrowserProvider)
    if (request.method !== "POST") {
      return jsonResp('"Method not allowed"', { "X-Cache": "SKIP" });
    }

    if (!env.ALCHEMY_URL) {
      return jsonResp(JSON.stringify({ error: "ALCHEMY_URL not configured" }), { "X-Cache": "ERR" });
    }

    const body = await request.text();
    let parsed;
    try {
      parsed = JSON.parse(body);
    } catch {
      // Not valid JSON — forward as-is, don't cache
      const resp = await fetch(env.ALCHEMY_URL, {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body,
      });
      return jsonResp(await resp.text(), { "X-Cache": "SKIP" });
    }

    const requestId = parsed.id;
    const keyStr = buildCacheKey(parsed);

    // If we can't normalize, forward without caching
    if (!keyStr) {
      const resp = await fetch(env.ALCHEMY_URL, {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body,
      });
      return jsonResp(await resp.text(), { "X-Cache": "SKIP" });
    }

    const hash = await sha256(keyStr);
    const cacheKey = new Request(`https://cache/${hash}`, { method: "GET" });
    const cache = caches.default;

    // Check cache — we store only the "result" or "error" value, not the full envelope
    const cached = await cache.match(cacheKey);
    if (cached) {
      const cachedPayload = await cached.text();
      // Reconstruct JSON-RPC envelope with the caller's request id
      const envelope = JSON.parse(cachedPayload);
      envelope.id = requestId;
      // Compute cache age from the X-Cached-At header we stored on put.
      // (Don't use the standard Date header — Cloudflare's edge cache
      // overrides/strips it.)
      const cachedAtMs = parseInt(cached.headers.get("x-cached-at") || "0", 10);
      const ageSec = cachedAtMs
        ? Math.max(0, Math.floor((Date.now() - cachedAtMs) / 1000))
        : 0;
      return jsonResp(JSON.stringify(envelope), {
        "X-Cache": "HIT",
        "X-Cache-Age": String(ageSec),
      });
    }

    // Cache miss — forward to Alchemy
    const resp = await fetch(env.ALCHEMY_URL, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body,
    });

    const data = await resp.text();

    // Cache successful responses (strip the id before caching). Stamp an
    // X-Cached-At header so cache hits can compute their age cleanly.
    if (resp.ok) {
      try {
        const rpcResp = JSON.parse(data);
        if (rpcResp.result !== undefined || rpcResp.error) {
          // Store with a placeholder id — we'll replace it on cache hit
          rpcResp.id = 0;
          const toCache = JSON.stringify(rpcResp);
          await cache.put(cacheKey, new Response(toCache, {
            headers: {
              "Content-Type": "application/json",
              "Cache-Control": `public, max-age=${CACHE_TTL}`,
              "X-Cached-At": String(Date.now()),
            },
          }));
        }
      } catch {
        // Can't parse — don't cache
      }
    }

    return jsonResp(data, { "X-Cache": "MISS", "X-Cache-Age": "0" });
  },
};

// ─── Coinbase Onramp session-token minting ────────────────────────────────

const CDP_HOST = "api.developer.coinbase.com";
const CDP_TOKEN_PATH = "/onramp/v1/token";

async function handleOnrampToken(request, env) {
  try {
    if (!env.COINBASE_CDP_KEY_NAME || !env.COINBASE_CDP_KEY_SECRET) {
      return jsonResp(JSON.stringify({ error: "CDP key not configured" }), { status: 500 });
    }

    const body = await request.json().catch(() => ({}));
    const address = (body.address || "").toLowerCase();
    const chain = body.chain || "base";
    if (!/^0x[a-f0-9]{40}$/.test(address)) {
      return jsonResp(JSON.stringify({ error: "invalid address" }), { status: 400 });
    }

    const jwt = await mintCdpJwt(env, "POST", CDP_HOST, CDP_TOKEN_PATH);

    const resp = await fetch(`https://${CDP_HOST}${CDP_TOKEN_PATH}`, {
      method: "POST",
      headers: {
        "Authorization": `Bearer ${jwt}`,
        "Content-Type": "application/json",
      },
      body: JSON.stringify({
        addresses: [{ address, blockchains: [chain] }],
        assets: ["ETH"],
      }),
    });

    const text = await resp.text();
    if (!resp.ok) {
      return jsonResp(JSON.stringify({
        error: "CDP token request failed",
        status: resp.status,
        upstream: text,
      }), { status: 502 });
    }
    // Pass through the upstream JSON ({ token, channel_id }).
    return jsonResp(text, { status: 200 });
  } catch (err) {
    return jsonResp(JSON.stringify({ error: err.message || "internal error" }), { status: 500 });
  }
}

async function mintCdpJwt(env, method, host, path) {
  const keyName = env.COINBASE_CDP_KEY_NAME;
  const keyPem = env.COINBASE_CDP_KEY_SECRET;
  const now = Math.floor(Date.now() / 1000);
  const nonce = randomHex(16);

  // Detect algorithm from the imported key. Coinbase CDP issues Ed25519
  // for newer accounts, ECDSA P-256 for older. Try Ed25519 first.
  const der = pemToDer(keyPem);
  let cryptoKey, alg;
  try {
    cryptoKey = await crypto.subtle.importKey(
      "pkcs8", der, { name: "Ed25519" }, false, ["sign"]
    );
    alg = "EdDSA";
  } catch {
    try {
      cryptoKey = await crypto.subtle.importKey(
        "pkcs8", der, { name: "ECDSA", namedCurve: "P-256" }, false, ["sign"]
      );
      alg = "ES256";
    } catch (err2) {
      throw new Error("Could not import CDP key as Ed25519 or ECDSA P-256: " + err2.message);
    }
  }

  const header = { alg, kid: keyName, nonce, typ: "JWT" };
  const payload = {
    iss: "cdp",
    nbf: now,
    exp: now + 120,
    sub: keyName,
    uri: `${method} ${host}${path}`,
  };

  const enc = new TextEncoder();
  const headerB64 = b64url(enc.encode(JSON.stringify(header)));
  const payloadB64 = b64url(enc.encode(JSON.stringify(payload)));
  const signingInput = `${headerB64}.${payloadB64}`;

  const sigBuf = await crypto.subtle.sign(
    alg === "EdDSA" ? { name: "Ed25519" } : { name: "ECDSA", hash: "SHA-256" },
    cryptoKey,
    enc.encode(signingInput),
  );
  return `${signingInput}.${b64url(new Uint8Array(sigBuf))}`;
}

function pemToDer(pem) {
  // Accepts: PEM with BEGIN/END lines, or raw base64. Tolerates literal
  // "\n" sequences (some secret-paste flows escape newlines).
  const cleaned = pem
    .replace(/\\n/g, "\n")
    .replace(/-----BEGIN [^-]+-----/g, "")
    .replace(/-----END [^-]+-----/g, "")
    .replace(/\s+/g, "");
  const bin = atob(cleaned);
  const buf = new Uint8Array(bin.length);
  for (let i = 0; i < bin.length; i++) buf[i] = bin.charCodeAt(i);
  return buf.buffer;
}

function b64url(bytes) {
  const arr = bytes instanceof Uint8Array ? bytes : new Uint8Array(bytes);
  let s = "";
  for (let i = 0; i < arr.length; i++) s += String.fromCharCode(arr[i]);
  return btoa(s).replace(/=+$/, "").replace(/\+/g, "-").replace(/\//g, "_");
}

function randomHex(bytes) {
  const arr = new Uint8Array(bytes);
  crypto.getRandomValues(arr);
  return [...arr].map(b => b.toString(16).padStart(2, "0")).join("");
}
