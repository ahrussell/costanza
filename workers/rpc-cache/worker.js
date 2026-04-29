// Cloudflare Worker: RPC caching proxy for The Human Fund frontend.
// Proxies JSON-RPC to Alchemy, caches responses with normalized keys.
// Deploy: cd workers/rpc-cache && wrangler deploy

const CACHE_TTL = 900; // 15 minutes

const CORS_HEADERS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
  "Access-Control-Allow-Headers": "Content-Type",
  // Browsers hide custom response headers from JS by default — expose ours
  // so the frontend can read X-Cache-Age and surface real data freshness
  // (cache age, not page-fetch age).
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
