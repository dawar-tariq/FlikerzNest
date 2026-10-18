/**
 * Flickerz Nest - TMDB proxy (Cloudflare Worker, free tier)
 *
 * What it does
 *   - Holds your TMDB key as a secret on the server. The key never reaches
 *     the browser, so nobody can copy it from your page source.
 *   - Caches TMDB responses at Cloudflare's edge, so repeat requests (trending
 *     rows, genres, popular pages) are served in milliseconds without hitting
 *     TMDB again.
 *   - Only answers requests from your own domains (ALLOWED_ORIGINS below).
 *
 * Setup (about 5 minutes, no command line needed)
 *   1. https://dash.cloudflare.com  ->  Workers & Pages  ->  Create  ->
 *      Create Worker  ->  name it  flickerz-tmdb  ->  Deploy.
 *   2. Click "Edit code", delete the sample, paste THIS FILE, click Deploy.
 *   3. Settings  ->  Variables and Secrets  ->  Add:
 *        Type: Secret    Name: TMDB_KEY    Value: your TMDB v3 key
 *      (Optional) Type: Text  Name: ALLOWED_ORIGINS
 *        Value: https://yourdomain.com,https://www.yourdomain.com
 *      Save and deploy.
 *   4. Copy the Worker URL shown at the top, e.g.
 *        https://flickerz-tmdb.YOUR-SUBDOMAIN.workers.dev
 *      and paste it into index.html  ->  OWNER.tmdbProxy
 *   5. Reload your site. Admin > Overview should show TMDB "proxied".
 *
 * Then rotate the old key: TMDB -> Settings -> API -> regenerate, and put the
 * NEW key into the Worker secret. The old key that was visible in your page
 * source stops working.
 */

const TMDB = "https://api.themoviedb.org/3";

// Paths the site is allowed to request. Anything else is refused, so the
// Worker cannot be used as a general TMDB proxy by strangers.
const ALLOWED = [
  /^\/trending\/(movie|tv|all)\/(day|week)$/,
  /^\/(movie|tv)\/(popular|top_rated|now_playing|upcoming|airing_today|on_the_air)$/,
  /^\/(movie|tv)\/\d+$/,
  /^\/(movie|tv)\/\d+\/(videos|credits|similar|recommendations|images)$/,
  /^\/tv\/\d+\/season\/\d+$/,
  /^\/search\/(multi|movie|tv|person)$/,
  /^\/discover\/(movie|tv)$/,
  /^\/genre\/(movie|tv)\/list$/,
  /^\/person\/\d+(\/combined_credits)?$/,
  /^\/collection\/\d+$/,
  /^\/configuration$/
];

// How long each kind of response may be cached at the edge (seconds).
function ttlFor(path) {
  if (/^\/search\//.test(path)) return 60 * 10;            // 10 min: searches change often
  if (/^\/trending\//.test(path)) return 60 * 30;          // 30 min
  if (/^\/discover\//.test(path)) return 60 * 30;          // 30 min
  if (/\/(popular|top_rated|now_playing|upcoming|airing_today|on_the_air)$/.test(path)) return 60 * 60; // 1 h
  if (/^\/genre\//.test(path) || /^\/configuration$/.test(path)) return 60 * 60 * 24 * 7; // 7 days
  return 60 * 60 * 6;                                       // 6 h: title details, seasons, credits
}

function corsHeaders(origin, allowedOrigins) {
  const allowAll = allowedOrigins.length === 0;
  const ok = allowAll || allowedOrigins.includes(origin);
  return {
    "Access-Control-Allow-Origin": ok ? (allowAll ? "*" : origin) : "null",
    "Access-Control-Allow-Methods": "GET, OPTIONS",
    "Access-Control-Allow-Headers": "Accept, Content-Type",
    "Access-Control-Max-Age": "86400",
    "Vary": "Origin"
  };
}

export default {
  async fetch(request, env, ctx) {
    const url = new URL(request.url);
    const origin = request.headers.get("Origin") || "";
    const allowedOrigins = String(env.ALLOWED_ORIGINS || "")
      .split(",").map((s) => s.trim().replace(/\/+$/, "")).filter(Boolean);
    const cors = corsHeaders(origin, allowedOrigins);

    if (request.method === "OPTIONS") return new Response(null, { status: 204, headers: cors });
    if (request.method !== "GET") return json({ error: "Method not allowed" }, 405, cors);

    // Health check so you can confirm the deployment in a browser tab.
    if (url.pathname === "/" || url.pathname === "/health") {
      return json({ ok: true, service: "flickerz-tmdb-proxy", keyConfigured: Boolean(env.TMDB_KEY) }, 200, cors);
    }

    if (!env.TMDB_KEY) return json({ error: "TMDB_KEY secret is not set on the Worker" }, 500, cors);

    // Refuse browsers from other sites when an allow-list is configured.
    if (allowedOrigins.length && origin && !allowedOrigins.includes(origin)) {
      return json({ error: "Origin not allowed" }, 403, cors);
    }

    const path = url.pathname.replace(/\/+$/, "");
    if (!ALLOWED.some((re) => re.test(path))) return json({ error: "Path not allowed" }, 404, cors);

    // Build the upstream request. Strip any api_key a caller might try to pass.
    const upstream = new URL(TMDB + path);
    url.searchParams.forEach((v, k) => { if (k !== "api_key") upstream.searchParams.set(k, v); });
    upstream.searchParams.sort();

    // Edge cache: identical requests share one cached copy.
    const cache = caches.default;
    const cacheKey = new Request(upstream.toString(), { method: "GET" });
    let res = await cache.match(cacheKey);
    let fromCache = Boolean(res);

    if (!res) {
      const key = env.TMDB_KEY;
      const headers = { Accept: "application/json" };
      if (/^eyJ/.test(key)) headers.Authorization = "Bearer " + key;   // v4 token
      else upstream.searchParams.set("api_key", key);                   // v3 key
      const tmdbRes = await fetch(upstream.toString(), { headers, cf: { cacheTtl: 0 } });
      const body = await tmdbRes.arrayBuffer();
      const ttl = tmdbRes.ok ? ttlFor(path) : 30;
      res = new Response(body, {
        status: tmdbRes.status,
        headers: {
          "Content-Type": tmdbRes.headers.get("Content-Type") || "application/json; charset=utf-8",
          "Cache-Control": "public, max-age=" + Math.min(ttl, 300) + ", s-maxage=" + ttl
        }
      });
      if (tmdbRes.ok) ctx.waitUntil(cache.put(cacheKey, res.clone()));
    }

    const out = new Response(res.body, res);
    Object.entries(cors).forEach(([k, v]) => out.headers.set(k, v));
    out.headers.set("X-Cache", fromCache ? "HIT" : "MISS");
    return out;
  }
};

function json(obj, status, cors) {
  return new Response(JSON.stringify(obj), {
    status,
    headers: { "Content-Type": "application/json; charset=utf-8", ...cors }
  });
}
