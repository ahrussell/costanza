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

// Per-method cache TTLs (seconds). Keys are method names; the
// build-cache-key function returns both the key and the TTL it should
// use. Defaults to DEFAULT_TTL (15min) for methods not listed.
const DEFAULT_TTL = 900;        // 15 min — eth_call (state can drift)
const SHORT_TTL = 10;           // ~5 blocks on Base — moving block tags
const FOREVER_TTL = 31536000;   // 1 year — immutable data (txes, sealed blocks)

const CORS_HEADERS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Methods": "GET, POST, OPTIONS",
  "Access-Control-Allow-Headers": "Content-Type, Authorization",
  "Access-Control-Expose-Headers": "X-Cache, X-Cache-Age",
};

// The Human Fund contract on Base mainnet — the only valid Onramp
// destination this worker mints tokens for. Server-pinned so a spoofed
// request can't divert ETH to a third party.
const FUND_ADDRESS = "0x678dc1756b123168f23a698374c000019e38318c";

// Cache-key version. Bump this any time the cache-payload schema changes
// (e.g. adding stamped headers like X-Cached-At) to force eviction of all
// stale entries that won't carry the new metadata. Otherwise serves limp
// across deploys until the per-key TTL expires per entry. v4 = added
// eth_getTransactionByHash + eth_getBlockByNumber + eth_getCode caching,
// normalized eth_getLogs toBlock; old v3 keys carry stale shape.
const CACHE_KEY_VERSION = "v4";

// Coarse-boundary rounding for eth_getLogs toBlock. The frontend's
// queryFilterChunked passes the live currentBlock as toBlock for the
// last chunk, which advances every Base block (~2s) and breaks the
// cache key. Round down to the nearest 1000 blocks (~33min on Base) so
// the cache stays warm. Trade-off: chart data at the bleeding edge
// can be up to ~33min stale. For a 6h epoch site, fine.
const LOGS_TOBLOCK_BUCKET = 1000;

// Block tags whose value changes block-to-block. Cache briefly (SHORT_TTL).
// Any other tag (assumed numeric) is cached forever — sealed blocks are
// immutable.
const VOLATILE_BLOCK_TAGS = new Set(["latest", "pending", "earliest", "safe", "finalized"]);

function isHexBlockNumber(s) {
  return typeof s === "string" && /^0x[0-9a-fA-F]+$/.test(s);
}

function normalizeToBlock(toBlock) {
  // Pass tag strings through untouched — the upstream RPC handles them.
  // Round numeric block hex down to the bucket boundary so the cache
  // key is stable across the ~33min that bucket covers.
  if (!isHexBlockNumber(toBlock)) return toBlock || "";
  const n = parseInt(toBlock, 16);
  if (!Number.isFinite(n)) return toBlock;
  const bucketed = Math.floor(n / LOGS_TOBLOCK_BUCKET) * LOGS_TOBLOCK_BUCKET;
  return "0x" + bucketed.toString(16);
}

// Build a stable cache key + the TTL it should use. Returns null when
// the method isn't one we know how to cache safely.
function buildCacheEntry(parsed) {
  const method = parsed.method;
  let key = null;
  let ttl = DEFAULT_TTL;

  if (method === "eth_blockNumber") {
    key = "eth_blockNumber";
    ttl = SHORT_TTL; // moves every block; brief cache absorbs concurrent visitors
  } else if (method === "eth_chainId" || method === "net_version") {
    key = method;
    ttl = FOREVER_TTL; // chain ID never changes
  } else if (method === "eth_gasPrice" || method === "eth_maxPriorityFeePerGas") {
    key = method;
    ttl = SHORT_TTL; // changes block-to-block but tolerable for display
  } else if (method === "eth_call") {
    const p = parsed.params || [];
    const call = p[0] || {};
    // eth_call's block tag is ignored (defaults to "latest"); per-block
    // pinning isn't used by the frontend and inflating the key with it
    // would tank cache hit rate.
    key = `eth_call:${(call.to || "").toLowerCase()}:${(call.data || "").toLowerCase()}`;
    ttl = DEFAULT_TTL;
  } else if (method === "eth_getLogs") {
    const p = (parsed.params || [])[0] || {};
    // fromBlock/toBlock affect the response set; both go in the key.
    // toBlock is bucketed to a coarse boundary so the chunked-query
    // last chunk doesn't burn a fresh cache miss every 2 seconds.
    const normTo = normalizeToBlock(p.toBlock);
    key = `eth_getLogs:${(p.address || "").toLowerCase()}:${p.fromBlock || ""}:${normTo}:${JSON.stringify(p.topics || [])}`;
    ttl = DEFAULT_TTL;
  } else if (method === "eth_getTransactionByHash" || method === "eth_getTransactionReceipt") {
    // Mined transactions / receipts are immutable. Cache forever.
    // (Pre-mined hashes return null; the cache TTL still applies but
    // we'd rather not cache nulls — see below.)
    const hash = (parsed.params || [])[0] || "";
    key = `${method}:${String(hash).toLowerCase()}`;
    ttl = FOREVER_TTL;
  } else if (method === "eth_getBlockByNumber" || method === "eth_getBlockByHash") {
    const tag = (parsed.params || [])[0] || "";
    const includeTxs = !!(parsed.params || [])[1];
    if (method === "eth_getBlockByNumber" && typeof tag === "string" && VOLATILE_BLOCK_TAGS.has(tag)) {
      key = `eth_getBlockByNumber:${tag}:${includeTxs ? "1" : "0"}`;
      ttl = SHORT_TTL;
    } else {
      // Specific block (hex number or hash) — sealed, immutable.
      key = `${method}:${String(tag).toLowerCase()}:${includeTxs ? "1" : "0"}`;
      ttl = FOREVER_TTL;
    }
  } else if (method === "eth_getCode") {
    const addr = (parsed.params || [])[0] || "";
    const tag = (parsed.params || [])[1] || "latest";
    // Code at the latest tag changes only on contract upgrades (rare
    // for the fund); SHORT_TTL absorbs the burst, FOREVER_TTL for
    // numbered blocks.
    if (typeof tag === "string" && VOLATILE_BLOCK_TAGS.has(tag)) {
      key = `eth_getCode:${String(addr).toLowerCase()}:${tag}`;
      ttl = SHORT_TTL;
    } else {
      key = `eth_getCode:${String(addr).toLowerCase()}:${String(tag).toLowerCase()}`;
      ttl = FOREVER_TTL;
    }
  }

  return key ? { key: `${CACHE_KEY_VERSION}:${key}`, ttl } : null;
}

async function sha256(text) {
  const buf = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(text));
  return [...new Uint8Array(buf)].map(b => b.toString(16).padStart(2, "0")).join("");
}

function jsonResp(body, init = {}) {
  // Accept either { status: 401, "X-Custom": "foo" } or just a flat
  // header bag { "X-Cache": "HIT" }. status defaults to 200. Earlier
  // version treated init as headers-only, which silently downgraded
  // every status:N error response to HTTP 200.
  const { status, ...headers } = init;
  return new Response(body, {
    status: status || 200,
    headers: { ...CORS_HEADERS, "Content-Type": "application/json", ...headers },
  });
}

export default {
  async fetch(request, env) {
    if (request.method === "OPTIONS") {
      return new Response(null, { headers: CORS_HEADERS });
    }

    const url = new URL(request.url);

    // Geo lookup — Cloudflare sets CF-IPCountry on every edge request.
    // Used by the frontend to conditionally show "Outside the US?"
    // copy on the card-pay button (Coinbase guest checkout is US-only).
    if (url.pathname === "/geo") {
      const country = request.headers.get("CF-IPCountry") || "";
      return jsonResp(JSON.stringify({ country }), { status: 200 });
    }

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

    // JSON-RPC supports batched requests as an array of envelopes. Process
    // each through the same cache logic and return the merged array. This
    // lets the frontend opt into batchMaxCount > 1 without losing cache
    // hits — without batch support here, every batched call would bypass
    // cache (parsed.method would be undefined).
    if (Array.isArray(parsed)) {
      // Empty batch is a malformed request per JSON-RPC; forward as-is.
      if (parsed.length === 0) {
        const resp = await fetch(env.ALCHEMY_URL, {
          method: "POST",
          headers: { "Content-Type": "application/json" },
          body,
        });
        return jsonResp(await resp.text(), { "X-Cache": "SKIP" });
      }
      const results = await Promise.all(parsed.map(req => processRpcRequest(req, env)));
      const responses = results.map(r => r.envelope);
      // Compose summary cache stats so the donor's devtools can see how
      // a batch landed without per-call breakdown.
      const hits = results.filter(r => r.cacheStatus === "HIT").length;
      const misses = results.filter(r => r.cacheStatus === "MISS").length;
      const skips = results.filter(r => r.cacheStatus === "SKIP").length;
      return jsonResp(JSON.stringify(responses), {
        "X-Cache": `BATCH (${hits}H/${misses}M/${skips}S)`,
        "X-Cache-Age": "0",
      });
    }

    const result = await processRpcRequest(parsed, env);
    return jsonResp(JSON.stringify(result.envelope), {
      "X-Cache": result.cacheStatus,
      "X-Cache-Age": String(result.cacheAge || 0),
    });
  },
};

// Process a single JSON-RPC request envelope through the cache + upstream
// fetch logic. Returns { envelope, cacheStatus, cacheAge } so a calling
// batch handler can compose responses + headers.
async function processRpcRequest(parsed, env) {
  const requestId = parsed.id;
  const entry = buildCacheEntry(parsed);

  // If we can't normalize, forward this single request to Alchemy.
  if (!entry) {
    const resp = await fetch(env.ALCHEMY_URL, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify(parsed),
    });
    let envelope;
    try { envelope = JSON.parse(await resp.text()); }
    catch { envelope = { jsonrpc: "2.0", id: requestId, error: { code: -32603, message: "upstream parse error" } }; }
    if (envelope && envelope.id === undefined) envelope.id = requestId;
    return { envelope, cacheStatus: "SKIP", cacheAge: 0 };
  }

  const hash = await sha256(entry.key);
  const cacheKey = new Request(`https://cache/${hash}`, { method: "GET" });
  const cache = caches.default;

  // Check cache — we store only the result/error envelope, not the full HTTP wrapper
  const cached = await cache.match(cacheKey);
  if (cached) {
    const envelope = JSON.parse(await cached.text());
    envelope.id = requestId;
    const cachedAtMs = parseInt(cached.headers.get("x-cached-at") || "0", 10);
    const ageSec = cachedAtMs ? Math.max(0, Math.floor((Date.now() - cachedAtMs) / 1000)) : 0;
    return { envelope, cacheStatus: "HIT", cacheAge: ageSec };
  }

  // Cache miss — forward to Alchemy
  const resp = await fetch(env.ALCHEMY_URL, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify(parsed),
  });
  const data = await resp.text();
  let envelope;
  try { envelope = JSON.parse(data); }
  catch {
    return {
      envelope: { jsonrpc: "2.0", id: requestId, error: { code: -32603, message: "upstream parse error" } },
      cacheStatus: "ERR",
      cacheAge: 0,
    };
  }

  // Cache successful responses with the per-method TTL. Skip caching of
  // null results for tx/receipt lookups (pre-mined hashes return null;
  // we don't want to pin "not yet mined" forever).
  if (resp.ok && envelope && (envelope.result !== undefined || envelope.error)) {
    const isNullableMethod = parsed.method === "eth_getTransactionByHash"
      || parsed.method === "eth_getTransactionReceipt"
      || parsed.method === "eth_getBlockByNumber"
      || parsed.method === "eth_getBlockByHash";
    const skipCacheOfNull = isNullableMethod && envelope.result === null;
    if (!skipCacheOfNull) {
      // Strip caller's id so the stored payload is donor-agnostic.
      const toCache = JSON.stringify({ ...envelope, id: 0 });
      try {
        await cache.put(cacheKey, new Response(toCache, {
          headers: {
            "Content-Type": "application/json",
            "Cache-Control": `public, max-age=${entry.ttl}`,
            "X-Cached-At": String(Date.now()),
          },
        }));
      } catch {/* cache.put is best-effort */}
    }
  }
  if (envelope && envelope.id === undefined) envelope.id = requestId;
  return { envelope, cacheStatus: "MISS", cacheAge: 0 };
}

// ─── Coinbase Onramp session-token minting ────────────────────────────────

const CDP_HOST = "api.developer.coinbase.com";
const CDP_TOKEN_PATH = "/onramp/v1/token";

async function handleOnrampToken(request, env) {
  try {
    if (!env.COINBASE_CDP_KEY_NAME || !env.COINBASE_CDP_KEY_SECRET) {
      return jsonResp(JSON.stringify({ error: "CDP key not configured" }), { status: 500 });
    }
    if (!env.TURNSTILE_SECRET_KEY) {
      return jsonResp(JSON.stringify({ error: "Turnstile not configured" }), { status: 500 });
    }

    // ── Auth: verify Cloudflare Turnstile token ────────────────────────
    // Frontend obtains an invisible-challenge token via the Turnstile
    // widget on user click, sends it as Authorization: Bearer <token>.
    // We verify with Cloudflare's siteverify endpoint before minting.
    const auth = request.headers.get("Authorization") || "";
    const m = auth.match(/^Bearer\s+(.+)$/i);
    if (!m) {
      return jsonResp(JSON.stringify({ error: "Unauthorized: missing bearer token" }), { status: 401 });
    }
    const turnstileToken = m[1];
    const clientIp = request.headers.get("CF-Connecting-IP") || "";
    const turnstileOk = await verifyTurnstile(turnstileToken, env.TURNSTILE_SECRET_KEY, clientIp);
    if (!turnstileOk) {
      return jsonResp(JSON.stringify({ error: "Unauthorized: Turnstile verification failed" }), { status: 401 });
    }

    // ── Validate request ───────────────────────────────────────────────
    const body = await request.json().catch(() => ({}));
    const rawAddress = (body.address || "").trim();
    const chain = body.chain || "base";
    // Two destination paths:
    //   - FUND_ADDRESS                — anonymous direct-to-contract donations
    //   - throwaway EOA (any address) — for the donate-with-message flow,
    //     where the donor's frontend generates a one-shot key, Coinbase
    //     delivers ETH to it, and JS auto-signs donateWithMessage() to
    //     forward to the contract. Authentication for non-fund
    //     destinations rests on Turnstile (above) + the donor paying
    //     their own card. They can't drain our quota for free because
    //     they have to actually complete the card payment.
    // Validate case-insensitively but pass the original casing through to
    // Coinbase. Some Ethereum APIs reject lowercase addresses that aren't
    // EIP-55 checksum-valid; passing the donor's original (checksummed)
    // address avoids ambiguity.
    if (!/^0x[a-fA-F0-9]{40}$/.test(rawAddress)) {
      return jsonResp(JSON.stringify({ error: "invalid destination address" }), { status: 400 });
    }
    if (chain !== "base") {
      return jsonResp(JSON.stringify({ error: "Forbidden chain — only base is allowed" }), { status: 403 });
    }

    // ── Mint the Onramp session token ──────────────────────────────────
    const jwt = await mintCdpJwt(env, "POST", CDP_HOST, CDP_TOKEN_PATH);

    const resp = await fetch(`https://${CDP_HOST}${CDP_TOKEN_PATH}`, {
      method: "POST",
      headers: {
        "Authorization": `Bearer ${jwt}`,
        "Content-Type": "application/json",
      },
      body: JSON.stringify({
        addresses: [{ address: rawAddress, blockchains: ["base"] }],
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
    return jsonResp(text, { status: 200 });
  } catch (err) {
    return jsonResp(JSON.stringify({ error: err.message || "internal error" }), { status: 500 });
  }
}

async function verifyTurnstile(token, secret, clientIp) {
  if (!token) return false;
  const formData = new FormData();
  formData.append("secret", secret);
  formData.append("response", token);
  if (clientIp) formData.append("remoteip", clientIp);
  try {
    const resp = await fetch("https://challenges.cloudflare.com/turnstile/v0/siteverify", {
      method: "POST",
      body: formData,
    });
    if (!resp.ok) return false;
    const data = await resp.json();
    return data?.success === true;
  } catch {
    return false;
  }
}

async function mintCdpJwt(env, method, host, path) {
  const keyName = env.COINBASE_CDP_KEY_NAME;
  const keyPem = env.COINBASE_CDP_KEY_SECRET;
  const now = Math.floor(Date.now() / 1000);
  const nonce = randomHex(16);

  // Coinbase CDP keys can arrive in several shapes; try them in order:
  //   1. PKCS8 PEM (Ed25519 or ECDSA P-256, BEGIN PRIVATE KEY headers)
  //   2. Raw 32-byte Ed25519 private key (base64) — wrap in PKCS8
  //   3. Raw 64-byte Ed25519 keypair (priv||pub, base64) — take first 32
  //   4. PKCS8 PEM ECDSA P-256 (BEGIN EC PRIVATE KEY → SEC1, only sometimes
  //      works as PKCS8 depending on the export tool)
  const der = pemToDer(keyPem);
  let cryptoKey, alg;
  const errs = [];

  async function tryEd25519Pkcs8(buf) {
    return crypto.subtle.importKey("pkcs8", buf, { name: "Ed25519" }, false, ["sign"]);
  }
  async function tryEcdsaPkcs8(buf) {
    return crypto.subtle.importKey("pkcs8", buf, { name: "ECDSA", namedCurve: "P-256" }, false, ["sign"]);
  }

  // 1. Try PKCS8 directly (whatever's in `der`).
  try { cryptoKey = await tryEd25519Pkcs8(der); alg = "EdDSA"; }
  catch (e) { errs.push(`pkcs8/ed25519: ${e.message}`); }
  if (!cryptoKey) {
    try { cryptoKey = await tryEcdsaPkcs8(der); alg = "ES256"; }
    catch (e) { errs.push(`pkcs8/ecdsa: ${e.message}`); }
  }

  // 2. & 3. Raw Ed25519 — wrap in PKCS8 envelope.
  if (!cryptoKey) {
    const bytes = new Uint8Array(der);
    let raw32 = null;
    if (bytes.length === 32) raw32 = bytes;
    else if (bytes.length === 64) raw32 = bytes.slice(0, 32);
    if (raw32) {
      // PKCS8 wrapper for Ed25519:
      //   SEQUENCE { INTEGER 0, SEQUENCE { OID 1.3.101.112 }, OCTET STRING { OCTET STRING raw32 } }
      const prefix = new Uint8Array([
        0x30, 0x2e, 0x02, 0x01, 0x00, 0x30, 0x05, 0x06,
        0x03, 0x2b, 0x65, 0x70, 0x04, 0x22, 0x04, 0x20,
      ]);
      const wrapped = new Uint8Array(prefix.length + raw32.length);
      wrapped.set(prefix, 0);
      wrapped.set(raw32, prefix.length);
      try { cryptoKey = await tryEd25519Pkcs8(wrapped.buffer); alg = "EdDSA"; }
      catch (e) { errs.push(`raw-ed25519/${bytes.length}: ${e.message}`); }
    }
  }

  if (!cryptoKey) {
    throw new Error(`Could not import CDP key (der length=${der.byteLength}): ${errs.join("; ")}`);
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
