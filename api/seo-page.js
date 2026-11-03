const catalogue = require("../content/catalogue.json");

const SITE = "https://flickerz.dpdns.org";
const IMAGE = "https://image.tmdb.org/t/p";
const TMDB = "https://api.themoviedb.org/3";

function escapeHtml(value) {
  return String(value == null ? "" : value).replace(/[&<>"']/g, function (c) {
    return { "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c];
  });
}
function slugify(value) {
  return String(value || "").normalize("NFKD").replace(/[\u0300-\u036f]/g, "")
    .toLowerCase().replace(/[^a-z0-9]+/g, "-").replace(/^-+|-+$/g, "");
}
function safeImage(path, size) {
  if (!path || typeof path !== "string" || path.charAt(0) !== "/") return "";
  return IMAGE + "/" + (size || "w780") + path;
}
function notFound(title, description, href) {
  return "<!doctype html><html lang=\"en\"><head><meta charset=\"utf-8\">" +
    "<meta name=\"viewport\" content=\"width=device-width,initial-scale=1\">" +
    "<meta name=\"robots\" content=\"noindex,nofollow\"><title>" + escapeHtml(title) + " | Flickerz Nest</title>" +
    "<meta name=\"description\" content=\"" + escapeHtml(description) + "\"><link rel=\"stylesheet\" href=\"/seo.css\"></head>" +
    "<body><main class=\"seo-wrap\"><a class=\"seo-brand\" href=\"/\">Flickerz <span>Nest</span></a>" +
    "<section class=\"seo-empty\"><p class=\"seo-kicker\">Flickerz Nest</p><h1>" + escapeHtml(title) + "</h1>" +
    "<p>" + escapeHtml(description) + "</p><p><a class=\"seo-button\" href=\"" + escapeHtml(href) + "\">Browse titles</a></p>" +
    "</section></main></body></html>";
}
async function fetchDetails(type, id) {
  const token = process.env.TMDB_READ_ACCESS_TOKEN;
  const apiKey = process.env.TMDB_API_KEY;
  const proxy = String(process.env.TMDB_PROXY_URL || "").replace(/\/+$/, "");
  if (!token && !apiKey && !proxy) return null;

  const path = "/" + type + "/" + id;
  const params = new URLSearchParams({
    language: "en-US",
    append_to_response: "credits,videos,similar,recommendations"
  });
  let url;
  const headers = { Accept: "application/json" };
  if (proxy) {
    url = proxy + path + "?" + params.toString();
  } else {
    url = TMDB + path + "?" + params.toString();
    if (token) headers.Authorization = "Bearer " + token;
    else url += "&api_key=" + encodeURIComponent(apiKey);
  }
  const response = await fetch(url, { headers, signal: AbortSignal.timeout(5000) });
  if (!response.ok) throw new Error("TMDB request returned " + response.status);
  return response.json();
}

function renderTitlePage(type, item, details) {
  const title = details && (details.title || details.name) || item.title;
  const overview = details && details.overview || item.overview;
  const date = details && (details.release_date || details.first_air_date) || item.releaseDate;
  const year = date ? String(date).slice(0, 4) : "";
  const rating = details && details.vote_average != null ? Number(details.vote_average) : item.voteAverage;
  const poster = safeImage(details && details.poster_path || item.posterPath, "w500");
  const backdrop = safeImage(details && details.backdrop_path || item.backdropPath, "w1280");
  const genres = details && Array.isArray(details.genres) ? details.genres.map(function (g) { return g.name; }) : [];
  const runtime = type === "movie" ? details && details.runtime : details && details.episode_run_time && details.episode_run_time[0];
  const cast = details && details.credits && Array.isArray(details.credits.cast)
    ? details.credits.cast.slice(0, 8).map(function (person) { return person.name; }) : [];
  const director = type === "movie" && details && details.credits && Array.isArray(details.credits.crew)
    ? details.credits.crew.find(function (person) { return person.job === "Director"; }) : null;

  const canonical = SITE + "/" + type + "/" + slugify(title) + "-" + item.id;
  const appRoute = "/#title/" + type + "/" + item.id;
  const image = poster || backdrop;
  const description = String(overview || ("Explore " + title + " on Flickerz Nest.")).slice(0, 300);
  const schema = {
    "@context": "https://schema.org",
    "@type": type === "movie" ? "Movie" : "TVSeries",
    "@id": canonical + "#title",
    "url": canonical,
    "name": title,
    "description": overview || description,
    "datePublished": date || undefined,
    "image": image || undefined,
    "genre": genres.length ? genres : undefined,
    "duration": type === "movie" && runtime ? "PT" + runtime + "M" : undefined,
    "director": director ? { "@type": "Person", "name": director.name } : undefined,
    "actor": cast.length ? cast.map(function (name) { return { "@type": "Person", "name": name }; }) : undefined,
    "isPartOf": { "@type": "WebSite", "name": "Flickerz Nest", "url": SITE + "/" }
  };
  Object.keys(schema).forEach(function (key) {
    if (schema[key] === undefined) delete schema[key];
  });

  const metaTitle = title + (year ? " (" + year + ")" : "") + " — Details | Flickerz Nest";
  const metaDescription = String(overview || ("Discover details for " + title + " on Flickerz Nest.")).slice(0, 160);
  const facts = [];
  if (year) facts.push("<span>" + escapeHtml(year) + "</span>");
  if (type === "movie" && runtime) facts.push("<span>" + escapeHtml(runtime) + " min</span>");
  if (type === "tv" && details && details.number_of_seasons) facts.push("<span>" + escapeHtml(details.number_of_seasons) + " seasons</span>");
  if (rating && Number.isFinite(rating)) facts.push("<span class=\"seo-score\">TMDB " + rating.toFixed(1) + "/10</span>");
  genres.forEach(function (name) {
    facts.push("<span>" + escapeHtml(name) + "</span>");
  });

  const castHtml = cast.length
    ? "<section class=\"seo-section\"><h2>Cast</h2><p>" + cast.map(escapeHtml).join(" · ") + "</p></section>"
    : "";
  const directorHtml = director
    ? "<p class=\"seo-muted\">Directed by " + escapeHtml(director.name) + "</p>"
    : "";
  const posterHtml = poster
    ? "<img class=\"seo-poster\" src=\"" + escapeHtml(poster) + "\" alt=\"" + escapeHtml(title) + " poster\" width=\"342\" height=\"513\">"
    : "";
  const backgroundStyle = backdrop
    ? " style=\"--seo-backdrop:url('" + escapeHtml(backdrop) + "')\""
    : "";
  const jsonLd = JSON.stringify(schema).replace(/</g, "\\u003c");

  return "<!doctype html><html lang=\"en\"><head><meta charset=\"utf-8\">" +
    "<meta name=\"viewport\" content=\"width=device-width,initial-scale=1\">" +
    "<meta name=\"robots\" content=\"index,follow,max-image-preview:large\">" +
    "<meta name=\"description\" content=\"" + escapeHtml(metaDescription) + "\">" +
    "<link rel=\"canonical\" href=\"" + escapeHtml(canonical) + "\">" +
    "<meta property=\"og:type\" content=\"video." + (type === "movie" ? "movie" : "tv_show") + "\">" +
    "<meta property=\"og:site_name\" content=\"Flickerz Nest\"><meta property=\"og:url\" content=\"" + escapeHtml(canonical) + "\">" +
    "<meta property=\"og:title\" content=\"" + escapeHtml(metaTitle) + "\"><meta property=\"og:description\" content=\"" + escapeHtml(metaDescription) + "\">" +
    (image ? "<meta property=\"og:image\" content=\"" + escapeHtml(image) + "\">" : "") +
    "<meta name=\"twitter:card\" content=\"summary_large_image\"><meta name=\"twitter:title\" content=\"" + escapeHtml(metaTitle) + "\">" +
    "<meta name=\"twitter:description\" content=\"" + escapeHtml(metaDescription) + "\">" +
    (image ? "<meta name=\"twitter:image\" content=\"" + escapeHtml(image) + "\">" : "") +
    "<title>" + escapeHtml(metaTitle) + "</title><link rel=\"stylesheet\" href=\"/seo.css\">" +
    "<link rel=\"icon\" href=\"/icon.svg\" type=\"image/svg+xml\">" +
    "<script type=\"application/ld+json\">" + jsonLd + "</script></head><body>" +
    "<main class=\"seo-wrap\"><header class=\"seo-header\"><a class=\"seo-brand\" href=\"/\">Flickerz <span>Nest</span></a>" +
    "<nav><a href=\"/movies\">Movies</a><a href=\"/tv-shows\">TV Shows</a><a href=\"/genres\">Genres</a><a href=\"/guides\">Guides</a></nav></header>" +
    "<section class=\"seo-title-hero\"" + backgroundStyle + "><div class=\"seo-title-grid\">" + posterHtml +
    "<div class=\"seo-title-copy\"><p class=\"seo-kicker\">" + (type === "movie" ? "Movie details" : "TV series details") + "</p>" +
    "<h1>" + escapeHtml(title) + "</h1><div class=\"seo-facts\">" + facts.join("") + "</div>" +
    "<p class=\"seo-overview\">" + escapeHtml(overview || "Explore the details for this title in Flickerz Nest.") + "</p>" + directorHtml +
    "<div class=\"seo-actions\"><a class=\"seo-button\" href=\"" + appRoute + "\">Open in Flickerz Nest</a>" +
    "<a class=\"seo-button seo-secondary\" href=\"/account.html\">Account</a></div>" +
    "<p class=\"seo-attribution\">Catalogue information and images are provided by TMDB. This product uses the TMDB API but is not endorsed or certified by TMDB.</p></div></div></section>" +
    castHtml +
    "<section class=\"seo-section\"><h2>Explore more</h2><p><a href=\"/movies\">Browse movies</a> · <a href=\"/tv-shows\">Browse TV shows</a> · <a href=\"/genres\">Explore genres</a> · <a href=\"/guides\">Read guides</a></p></section>" +
    "<footer class=\"seo-footer\">© " + new Date().getFullYear() + " Flickerz Nest</footer></main></body></html>";
}

module.exports = async function (req, res) {
  if (req.method !== "GET" && req.method !== "HEAD") {
    res.setHeader("Allow", "GET, HEAD");
    return res.status(405).send("Method not allowed");
  }
  const type = Array.isArray(req.query.type) ? req.query.type[0] : req.query.type;
  const slug = Array.isArray(req.query.slug) ? req.query.slug[0] : req.query.slug;
  if (type !== "movie" && type !== "tv") {
    return res.status(400).send("Invalid title type");
  }
  const match = /^([a-z0-9-]+)-(\d+)$/.exec(String(slug || "").toLowerCase());
  const directory = type === "movie" ? "/movies" : "/tv-shows";
  if (!match) {
    res.setHeader("X-Robots-Tag", "noindex, nofollow");
    return res.status(404).send(notFound("Title not found", "This title URL is not valid.", directory));
  }

  const id = Number(match[2]);
  const list = type === "movie" ? catalogue.movies : catalogue.tv;
  const item = list.find(function (entry) { return entry.id === id; });
  if (!item) {
    res.setHeader("X-Robots-Tag", "noindex, nofollow");
    return res.status(404).send(notFound(
      "Title not found",
      "This title is not part of the current curated Flickerz Nest catalogue.",
      directory
    ));
  }

  const canonical = SITE + "/" + type + "/" + slugify(item.title) + "-" + id;
  const requested = SITE + "/" + type + "/" + String(slug || "");
  if (requested !== canonical) {
    res.setHeader("Location", canonical);
    return res.status(308).end();
  }

  let details = null;
  try {
    details = await fetchDetails(type, id);
  } catch (error) {
    console.warn("[Flickerz SEO] TMDB enrichment skipped:", error.message);
  }

  res.setHeader("Content-Type", "text/html; charset=utf-8");
  res.setHeader("Cache-Control", "public, max-age=0, s-maxage=3600, stale-while-revalidate=86400");
  res.setHeader("X-Robots-Tag", "index, follow");
  if (req.method === "HEAD") return res.status(200).end();
  return res.status(200).send(renderTitlePage(type, item, details));
};
