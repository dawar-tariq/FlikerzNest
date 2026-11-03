# Flickerz Nest SEO implementation

## Canonical domain
The canonical production hostname is `https://flickerz.dpdns.org`. The Vercel alias `flikerz-nest.vercel.app` is configured to redirect permanently to the canonical host. Confirm that the custom domain is attached to the same Vercel project and that HTTPS is valid before merging this branch.

## What is included
- Server-rendered movie and TV title pages at `/movie/:slug-id` and `/tv/:slug-id`.
- A whitelist-backed curated catalogue in `content/catalogue.json`.
- Static movie, TV, genre and guide directories.
- One manually written watchlist guide.
- Canonical metadata, Open Graph/Twitter metadata and applicable JSON-LD.
- A sitemap restricted to the currently curated set.
- Search-engine directives for the public site and noindex response headers for utility/account/admin routes.
- Footer links from the existing app to the public SEO directories.

## Curated seed
The first release contains 8 movies and 6 TV series already present in the application's existing demo data. This is a safe working seed, not the final 500–1,000 title target. Add each new title only after verifying the TMDB ID, title, media type, synopsis and artwork. Update `content/catalogue.json` and `sitemap.xml` together. Do not publish all TMDB search results or every filter combination as indexable pages.

## Optional server-side TMDB enrichment
The title pages render using local curated data even if no server-side TMDB credentials exist. To add runtime, genres, cast and crew data, configure one of these environment variables in Vercel Project Settings → Environment Variables:

- `TMDB_READ_ACCESS_TOKEN` — preferred TMDB v4 read access token.
- `TMDB_API_KEY` — TMDB v3 API key.
- `TMDB_PROXY_URL` — base URL of the existing Cloudflare Worker in `worker/tmdb-proxy.js`, without a trailing slash.

Do not commit credentials. The API route uses these variables only server-side. The existing SPA's current TMDB configuration has intentionally not been changed in this SEO branch, because removing it before the Cloudflare Worker is configured would risk breaking live discovery and search.

## Google Search results
The code consolidates the hostname and provides canonical signals; it cannot force Google to immediately display a chosen site name/hostname or rank the site first. After the production release:
1. Verify `flickerz.dpdns.org` as a Domain property in Google Search Console.
2. Submit `https://flickerz.dpdns.org/sitemap.xml`.
3. Inspect the homepage, a movie URL and a TV URL. Confirm Google's selected canonical matches the submitted URL.
4. Request indexing for important new pages, then monitor Page Indexing and Search Performance reports.

## Regression test checklist before release
- Existing sign-in, sign-out, account screen, watchlist and history.
- Admin access, role checks and member management.
- Movie detail and TV detail inside the existing SPA.
- Player route, seasons/episodes, playback server switching and watch-history writes.
- TV mode, remote/keyboard navigation and TV pairing.
- Movie/TV/genre/guide directory links from the app footer.
- A valid SEO movie URL returns 200; an unlisted title returns 404; a wrong slug redirects to the canonical slug.
- Confirm all sitemap URLs return 200 and have one matching canonical URL.
- Confirm the Vercel alias redirects to the custom domain.

## Security item still requiring coordinated action
The main application currently has a TMDB key exposed in frontend code, and an old shared runtime file also contains a hard-coded owner credential. Do not reuse or expose those values. Rotate credentials if they are still active. Move TMDB access to the existing Cloudflare Worker secret and configure the worker URL in the app before removing the current client-side TMDB configuration. Review Supabase Row Level Security to ensure admin authorization is enforced by database policies and not only frontend checks. These security changes are intentionally not mixed into this SEO change set because they could break existing app behaviour without first configuring and testing the server-side replacements.
