// Cloudflare Worker: RPC caching proxy for The Human Fund frontend.
// Proxies JSON-RPC to Alchemy, caches responses with normalized keys.
// Deploy: cd workers/rpc-cache && wrangler deploy

const CACHE_TTL = 300; // 5 minutes

const CORS_HEADERS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
  "Access-Control-Allow-Headers": "Content-Type",
};

// Build a stable cache key by stripping volatile fields (block numbers, request id).
function buildCacheKey(parsed) {
  const method = parsed.method;

  if (method === "eth_getBlockNumber") {
    return "eth_getBlockNumber";
  }

  if (method === "eth_call") {
    const p = parsed.params || [];
    const call = p[0] || {};
    return `eth_call:${(call.to || "").toLowerCase()}:${(call.data || "").toLowerCase()}`;
  }

  if (method === "eth_getLogs") {
    const p = (parsed.params || [])[0] || {};
    return `eth_getLogs:${(p.address || "").toLowerCase()}:${JSON.stringify(p.topics || [])}`;
  }

  return null;
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
      return jsonResp(JSON.stringify(envelope), { "X-Cache": "HIT" });
    }

    // Cache miss — forward to Alchemy
    const resp = await fetch(env.ALCHEMY_URL, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body,
    });

    const data = await resp.text();

    // Cache successful responses (strip the id before caching)
    if (resp.ok) {
      try {
        const rpcResp = JSON.parse(data);
        if (rpcResp.result !== undefined || rpcResp.error) {
          // Store with a placeholder id — we'll replace it on cache hit
          rpcResp.id = 0;
          const toCache = JSON.stringify(rpcResp);
          await cache.put(cacheKey, new Response(toCache, {
            headers: { "Content-Type": "application/json", "Cache-Control": `public, max-age=${CACHE_TTL}` },
          }));
        }
      } catch {
        // Can't parse — don't cache
      }
    }

    return jsonResp(data, { "X-Cache": "MISS" });
  },
};
