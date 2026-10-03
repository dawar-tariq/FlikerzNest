/* ============================================================================
   Flickerz Nest - shared runtime used by every page
   (config, auth, TV detection, TV pairing codes, header/footer, focus nav)
   ============================================================================ */
(function () {
  "use strict";

  const OWNER = {
    email: "wanidawar03@gmail.com",
    password: "dawar@123",
    tmdbKey: "cc306d0684189df48d37b51bc9e06e04",
    supabaseUrl: "https://ctbrfynxmgcyvsrdihfg.supabase.co",
    supabaseAnonKey: "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6ImN0YnJmeW54bWdjeXZzcmRpaGZnIiwicm9sZSI6ImFub24iLCJpYXQiOjE3OTA1MzA4NzEsImV4cCI6MjEwNjEwNjg3MX0.zAtoKaymmXp9A2rA4NAf3QELlt8GZR4LExhACKIw2OA"
  };
  const TMDB = "https://api.themoviedb.org/3";
  const IMG = "https://image.tmdb.org/t/p/";
  const TV_KEY = "flickerz.tvmode.v1";

  const $ = (id) => document.getElementById(id);
  const esc = (v) => String(v ?? "").replace(/[&<>"']/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c]));
  const httpsUrl = (v) => { try { const u = new URL(String(v || "").trim()); return u.protocol === "https:" ? u.href : ""; } catch { return ""; } };
  const img = (p, size = "w500") => (!p ? "" : String(p).startsWith("/") ? IMG + size + p : httpsUrl(p));
  const yearOf = (i) => { const d = (i && (i.release_date || i.first_air_date)) || ""; return d ? String(d).slice(0, 4) : ""; };
  const titleOf = (i) => (i && (i.title || i.name)) || "Untitled";
  const timeAgo = (d) => {
    const t = new Date(d).getTime(); if (!t) return "-";
    const s = Math.max(1, Math.round((Date.now() - t) / 1000));
    if (s < 60) return "just now";
    const m = Math.round(s / 60); if (m < 60) return m + "m ago";
    const h = Math.round(m / 60); if (h < 24) return h + "h ago";
    const dd = Math.round(h / 24); return dd < 30 ? dd + "d ago" : new Date(t).toLocaleDateString();
  };

  const state = { sb: null, user: null, profile: null, tv: false, ready: false, listeners: [] };

  /* ---------------- TV detection (device model only) ---------------- */
  function detectTv() {
    const ua = navigator.userAgent || "";
    const viewport = Math.max(
      Number(window.screen?.width || 0),
      Number(window.innerWidth || 0)
    );

    // Explicit smart-TV / Cloud-TV browser identifiers.
    const knownTv = /SMART[-_ ]?TV|SmartTV|Smart TV|Tizen|WebOS|Web0S|NetCast|Viera|HbbTV|Android[ ._-]*TV|AFT(SS|KA|KR|SA)|BRAVIA|GoogleTV|Google TV|CrKey|AppleTV|NetTV|SkyQ|Freebox|Vestel|CloudTV|Cloud TV|CloudWalker/i.test(ua);

    // Some Android TV browsers expose only a generic Android UA.
    // Require a large viewport and no "Mobile" token so phones are not
    // accidentally switched into TV mode.
    const viewportHeight = Number(window.innerHeight || 0);
    const screenSize = Math.max(
      Number(window.screen?.width || 0),
      Number(window.screen?.height || 0)
    );

    const genericAndroidTv =
      /Android/i.test(ua) &&
      viewport >= 800 &&
      viewportHeight >= 450 &&
      screenSize >= 900;

    return knownTv || genericAndroidTv;
  }
  function applyTvMode(on, persist) {
    state.tv = Boolean(on);
    document.body.classList.toggle("tv", state.tv);
    if (persist) { try { localStorage.setItem(TV_KEY, state.tv ? "1" : "0"); } catch {} }
    document.dispatchEvent(new CustomEvent("fz:tv", { detail: { tv: state.tv } }));
  }
  function initTvMode() {
    let stored = null;
    try { stored = localStorage.getItem(TV_KEY); } catch {}
    const detected = detectTv();
    // A real TV must win over a stale "TV mode off" preference.
    applyTvMode(detected || stored === "1", false);
  }

  /* ---------------- toast ---------------- */
  function toast(msg, kind = "") {
    let box = $("fzToasts");
    if (!box) {
      box = document.createElement("div");
      box.id = "fzToasts";
      box.className = "fz-toasts";
      document.body.appendChild(box);
    }
    const el = document.createElement("div");
    el.className = ("fz-toast " + kind).trim();
    el.textContent = msg;
    box.appendChild(el);
    setTimeout(() => el.remove(), 4200);
  }

  /* ---------------- full screen ---------------- */
  function fullscreen(el) {
    const target = el || document.documentElement;
    const doc = document;
    const exit = doc.exitFullscreen || doc.webkitExitFullscreen || doc.mozCancelFullScreen;
    const req = target.requestFullscreen || target.webkitRequestFullscreen || target.mozRequestFullScreen;
    try {
      if (doc.fullscreenElement || doc.webkitFullscreenElement) (exit || function () {}).call(doc);
      else if (req) req.call(target);
      else toast("This browser does not support full screen.", "error");
    } catch {
      toast("Full screen was blocked. Use New tab instead.", "error");
    }
  }

  /* ---------------- auth ---------------- */
  function initSupabase() {
    if (state.sb || !window.supabase?.createClient) return state.sb;
    try {
      state.sb = window.supabase.createClient(OWNER.supabaseUrl, OWNER.supabaseAnonKey,
        { auth: { persistSession: true, autoRefreshToken: true, detectSessionInUrl: true } });
    } catch (e) { console.error("[FZ] supabase", e); }
    return state.sb;
  }
  async function refreshUser() {
    if (!initSupabase()) return null;
    const { data } = await state.sb.auth.getSession();
    state.user = data?.session?.user || null;
    if (state.user) await loadProfile();
    return state.user;
  }
  async function loadProfile() {
    if (!state.user || !state.sb) { state.profile = null; return null; }
    const base = "id,email,display_name,role,created_at";
    let r = await state.sb.from("profiles").select(base + ",is_blocked").eq("id", state.user.id).maybeSingle();
    if (r.error && /is_blocked|column/i.test(r.error.message || "")) r = await state.sb.from("profiles").select(base).eq("id", state.user.id).maybeSingle();
    state.profile = (!r.error && r.data) ? r.data
      : { id: state.user.id, email: state.user.email, display_name: "", role: isOwnerEmail(state.user.email) ? "admin" : "user", is_blocked: false };
    return state.profile;
  }
  const isOwnerEmail = (e) => String(e || "").trim().toLowerCase() === OWNER.email.toLowerCase();
  const isAdmin = () => Boolean(state.user && (isOwnerEmail(state.user.email) || (state.profile && state.profile.role === "admin" && !state.profile.is_blocked)));
  async function signIn(email, password) {
    if (!initSupabase()) return { error: new Error("Supabase is not configured.") };
    let res;
    try { res = await state.sb.auth.signInWithPassword({ email, password }); } catch (e) { res = { error: e }; }
    if (!res.error && res.data?.user) { state.user = res.data.user; await loadProfile(); }
    return res;
  }
  async function signOut() {
    if (state.sb) await state.sb.auth.signOut();
    state.user = null; state.profile = null;
    paintHeader();
  }

  /* ---------------- TV pairing ---------------- */
  async function makeTvCode() {
    if (!state.sb || !state.user) return { error: new Error("Sign in first, then link your TV.") };
    let ses = null;
    try { ses = (await state.sb.auth.getSession()).data?.session; } catch {}
    if (!ses) return { error: new Error("Your session expired. Sign in again.") };
    const chars = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789";
    let code = "";
    for (let i = 0; i < 8; i++) code += chars.charAt(Math.floor(Math.random() * chars.length));
    let res;
    try {
      res = await state.sb.from("tv_codes").insert({
        code: code, user_id: state.user.id,
        access_token: ses.access_token, refresh_token: ses.refresh_token
      });
    } catch (e) { res = { error: e }; }
    if (res.error) {
      const m = res.error.message || "";
      return { error: new Error(/tv_codes|relation|schema cache|column/i.test(m)
        ? "TV pairing is not set up yet. Run STEP 15 of schema.sql in Supabase." : m) };
    }
    return { code: code };
  }
  async function claimTvCode(rawCode) {
    const code = String(rawCode || "").trim().toUpperCase();
    if (code.length < 4) return { error: new Error("Enter the code shown on your other device.") };
    if (!state.sb) return { error: new Error("TV pairing needs Supabase.") };
    let res;
    try { res = await state.sb.from("tv_codes").select("code,access_token,refresh_token,expires_at").eq("code", code).maybeSingle(); }
    catch (e) { res = { error: e }; }
    const row = res.data;
    if (res.error || !row) {
      return { error: new Error(/tv_codes|relation|schema cache/i.test((res.error && res.error.message) || "")
        ? "TV pairing is not set up on this site (run STEP 15 of schema.sql)."
        : "That code is not valid. Generate a new one on your other device.") };
    }
    if (row.expires_at && new Date(row.expires_at).getTime() < Date.now()) return { error: new Error("That code has expired. Generate a new one.") };
    let out;
    try { out = await state.sb.auth.setSession({ access_token: row.access_token, refresh_token: row.refresh_token }); }
    catch (e) { out = { error: e }; }
    if (out.error || !out.data?.user) return { error: new Error((out.error && out.error.message) || "Could not connect this TV.") };
    try { await state.sb.from("tv_codes").delete().eq("code", code); } catch {}
    state.user = out.data.user;
    await loadProfile();
    paintHeader();
    return { user: state.user };
  }

  /* ---------------- header / footer ---------------- */
  const NAV = [
    ["index.html", "home", "Home", "ph-house"],
    ["explore.html", "explore", "Explore", "ph-compass"],
    ["explore.html?type=movie", "movies", "Movies", "ph-film-strip"],
    ["explore.html?type=tv", "tv", "TV Shows", "ph-television-simple"],
    ["mylist.html", "mylist", "My List", "ph-bookmark-simple"]
  ];
  function headerHTML(active) {
    const name = state.user ? (state.profile?.display_name || state.user.email.split("@")[0]) : "Sign in";
    return '<a class="brand" href="index.html"><span class="brand-mark">F</span><b>Flickerz&nbsp;<em>Nest</em></b></a>' +
      '<nav class="nav-links">' + NAV.map((n) =>
        '<a href="' + n[0] + '"' + (n[1] === active ? ' class="active"' : "") + ">" + esc(n[2]) + "</a>").join("") + "</nav>" +
      '<div class="nav-actions">' +
        '<a class="icon-btn" href="explore.html#search" aria-label="Search"><i class="ph ph-magnifying-glass"></i></a>' +
        (isAdmin() ? '<a class="icon-btn" href="admin.html" aria-label="Admin"><i class="ph ph-shield-check"></i></a>' : "") +
        '<button class="icon-btn fz-account" type="button" id="fzAccount" aria-label="Account"><i class="ph ph-user-circle"></i></button>' +
      "</div>" +
      '<div class="fz-menu" id="fzMenu" hidden>' +
        '<div class="fz-menu-head"><b>' + esc(name) + "</b><span>" + esc(state.user ? state.user.email : "Not signed in") + "</span></div>" +
        (state.user
          ? '<button class="fz-menu-item" type="button" data-fz="linktv"><i class="ph ph-television"></i> Link a TV</button>' +
            '<a class="fz-menu-item" href="mylist.html"><i class="ph ph-list-checks"></i> My watch history</a>' +
            '<button class="fz-menu-item" type="button" data-fz="tv"><i class="ph ph-corners-out"></i> ' + (state.tv ? "Turn off TV mode" : "Turn on TV mode") + "</button>" +
            '<button class="fz-menu-item danger" type="button" data-fz="signout"><i class="ph ph-sign-out"></i> Sign out</button>'
          : '<button class="fz-menu-item" type="button" data-fz="signin"><i class="ph ph-sign-in"></i> Sign in</button>' +
            '<button class="fz-menu-item" type="button" data-fz="tv"><i class="ph ph-corners-out"></i> ' + (state.tv ? "Turn off TV mode" : "Turn on TV mode") + "</button>") +
      "</div>";
  }
  function footerHTML() {
    return '<div class="fz-foot-grid">' +
      '<div><div class="fz-foot-brand"><span class="brand-mark">F</span><b>Flickerz&nbsp;<em>Nest</em></b></div>' +
      '<p class="fz-foot-tag">Discover trending films and series, organise your watchlist and pick up where you left off.</p>' +
      '<div class="fz-tmdb"><img src="https://www.themoviedb.org/assets/2/v4/logos/v2/blue_short-8e7b30f73a4020692ccca9c88bafe5dcb6f8a62a4c6bc55cd9ba82bb2cd95f6c.svg" alt="TMDB" width="90" onerror="this.replaceWith(Object.assign(document.createElement(\'b\'),{textContent:\'TMDB\'}))">' +
      '<p>This product uses the TMDB API but is not endorsed or certified by TMDB.</p></div></div>' +
      '<nav><h4>Browse</h4><a href="index.html">Home</a><a href="explore.html">Explore</a><a href="explore.html?type=movie">Movies</a><a href="explore.html?type=tv">TV Shows</a><a href="mylist.html">My List</a></nav>' +
      '<nav><h4>Company</h4><a href="about.html?page=about">About us</a><a href="about.html?page=contact">Contact</a><a href="about.html?page=dmca">DMCA</a></nav>' +
      '<nav><h4>Legal</h4><a href="about.html?page=privacy">Privacy policy</a><a href="about.html?page=terms">Terms of use</a></nav></div>' +
      '<div class="fz-foot-bottom"><span class="fz-made">Made with <i class="ph-fill ph-heart"></i> by <b>Dawar Tariq</b></span>' +
      '<span>&copy; ' + new Date().getFullYear() + " Flickerz Nest</span>" +
      '<span class="fz-foot-icons"><a href="index.html" aria-label="Back to top"><i class="ph ph-arrow-up"></i></a>' +
      '<a href="about.html?page=contact" aria-label="Contact"><i class="ph ph-envelope-simple"></i></a></span></div>';
  }
  function paintHeader() {
    const h = $("siteHeader");
    if (h) {
      h.innerHTML = headerHTML(h.dataset.active || "home");
      wireHeader();
    }
    const f = $("siteFooter");
    if (f) f.innerHTML = footerHTML();
  }
  function wireHeader() {
    const acc = $("fzAccount");
    if (acc) acc.addEventListener("click", () => {
      const m = $("fzMenu");
      m.hidden = !m.hidden;
      acc.setAttribute("aria-expanded", String(!m.hidden));
    });
    document.addEventListener("click", (e) => {
      const m = $("fzMenu");
      if (!m || m.hidden) return;
      if (!e.target.closest("#fzMenu") && !e.target.closest("#fzAccount")) m.hidden = true;
    });
    document.querySelectorAll("[data-fz]").forEach((b) => b.addEventListener("click", async () => {
      const act = b.dataset.fz;
      if (act === "signin") location.href = "index.html#signin";
      if (act === "signout") { await signOut(); toast("Signed out.", "ok"); location.reload(); }
      if (act === "tv") { applyTvMode(!state.tv, true); paintHeader(); toast(state.tv ? "TV mode on." : "TV mode off.", "ok"); }
      if (act === "linktv") {
        const r = await makeTvCode();
        if (r.error) { toast(r.error.message, "error"); return; }
        prompt("Give this code to your TV (valid 3 minutes, one use):", r.code);
      }
    }));
  }

  /* ---------------- remote / keyboard focus ---------------- */
  const FOCUSABLE = 'a[href],button:not([disabled]),input:not([disabled]),select:not([disabled]),textarea:not([disabled])';
  function moveFocus(dir) {
    const items = Array.from(document.querySelectorAll(FOCUSABLE)).filter((el) => {
      const r = el.getBoundingClientRect();
      return r.width > 0 && r.height > 0 && !el.closest("[hidden]");
    });
    if (!items.length) return;
    const cur = document.activeElement;
    if (!cur || items.indexOf(cur) === -1) { items[0].focus(); return; }
    const cr = cur.getBoundingClientRect();
    const cx = cr.left + cr.width / 2, cy = cr.top + cr.height / 2;
    let best = null, score = Infinity;
    items.forEach((el) => {
      if (el === cur) return;
      const r = el.getBoundingClientRect();
      const dx = (r.left + r.width / 2) - cx, dy = (r.top + r.height / 2) - cy;
      let fwd = 0, side = 0;
      if (dir === "left") { fwd = -dx; side = Math.abs(dy); }
      if (dir === "right") { fwd = dx; side = Math.abs(dy); }
      if (dir === "up") { fwd = -dy; side = Math.abs(dx); }
      if (dir === "down") { fwd = dy; side = Math.abs(dx); }
      if (fwd <= 6) return;
      const s = fwd + side * 2.2;
      if (s < score) { score = s; best = el; }
    });
    if (best) { best.focus(); best.scrollIntoView({ block: "nearest", inline: "nearest", behavior: "smooth" }); }
  }

  /* ---------------- shared styles ---------------- */
  const CSS = `
  :root{color-scheme:dark;--ink:#08090d;--card:#14161d;--text:#f3f4f7;--muted:#9aa0ad;--red:#e50914;--red-2:#ff2e3d;
    --gold:#ffcf70;--green:#5ed9a4;--line:rgba(255,255,255,.1);--line-2:rgba(255,255,255,.18);
    font-family:"Plus Jakarta Sans",Inter,system-ui,-apple-system,"Segoe UI",sans-serif}
  *{box-sizing:border-box}
  html,body{margin:0;min-width:320px;background:var(--ink);color:var(--text)}
  body{-webkit-font-smoothing:antialiased;padding-bottom:0}
  a{color:inherit;text-decoration:none}
  button,input,select,textarea{font:inherit;color:inherit}
  [hidden]{display:none!important}
  :focus-visible{outline:3px solid #ffd479;outline-offset:3px;border-radius:8px}
  .fz-header{position:sticky;top:0;z-index:50;display:flex;align-items:center;gap:22px;min-height:76px;
    padding:12px clamp(16px,4.5vw,68px);border-bottom:1px solid var(--line);background:rgba(10,11,15,.92);backdrop-filter:blur(18px)}
  .brand{display:flex;align-items:center;gap:11px;font-size:21px;font-weight:800;letter-spacing:-.055em}
  .brand-mark{width:33px;height:33px;display:grid;place-items:center;border-radius:11px 11px 11px 3px;background:var(--red);color:#fff;font-size:17px}
  .brand em{font-style:normal;color:var(--red-2)}
  .nav-links{display:flex;align-items:center;gap:clamp(12px,1.8vw,26px);font-size:14px;font-weight:600;color:rgba(243,244,247,.72)}
  .nav-links a{padding:6px 0;border-bottom:2px solid transparent}
  .nav-links a:hover{color:#fff}
  .nav-links a.active{color:#fff;border-bottom-color:var(--red)}
  .nav-actions{margin-left:auto;display:flex;align-items:center;gap:10px}
  .icon-btn{width:42px;height:42px;display:grid;place-items:center;border:1px solid var(--line);border-radius:50%;
    background:transparent;cursor:pointer;font-size:18px;transition:all .18s}
  .icon-btn:hover{background:rgba(255,255,255,.1);color:#fff}
  .fz-menu{position:absolute;top:72px;right:clamp(16px,4.5vw,68px);width:280px;padding:10px;border:1px solid var(--line-2);
    border-radius:15px;background:rgba(21,23,30,.98);box-shadow:0 26px 70px rgba(0,0,0,.6)}
  .fz-menu-head{padding:12px;border-bottom:1px solid var(--line);margin-bottom:6px}
  .fz-menu-head b{font-size:14px}
  .fz-menu-head span{display:block;margin-top:5px;color:var(--muted);font-size:11.5px;overflow:hidden;text-overflow:ellipsis;white-space:nowrap}
  .fz-menu-item{width:100%;display:flex;align-items:center;gap:11px;min-height:48px;padding:0 12px;border:0;border-radius:10px;
    background:transparent;cursor:pointer;text-align:left;font-size:14px}
  .fz-menu-item:hover{background:rgba(255,255,255,.08)}
  .fz-menu-item.danger{color:#ff8289}
  .fz-wrap{width:min(100%,1500px);margin:0 auto;padding:28px clamp(16px,4.5vw,68px) 80px}
  .fz-foot{border-top:1px solid var(--line);background:#07080b;padding:52px clamp(16px,4.5vw,68px) 26px}
  .fz-foot-grid{display:grid;grid-template-columns:minmax(0,1.5fr) repeat(3,minmax(0,1fr));gap:34px;width:min(100%,1500px);margin:0 auto}
  .fz-foot-brand{display:flex;align-items:center;gap:11px;font-size:18px;font-weight:800;letter-spacing:-.05em}
  .fz-foot-brand em{font-style:normal;color:var(--red-2)}
  .fz-foot-tag{max-width:380px;margin:12px 0 0;color:#8f94a0;font-size:12.5px;line-height:1.75}
  .fz-tmdb{display:flex;align-items:center;gap:14px;max-width:420px;margin-top:20px;padding:13px 14px;border:1px solid var(--line);border-radius:12px}
  .fz-tmdb img{width:90px}
  .fz-tmdb p{margin:0;color:#8b909c;font-size:11px;line-height:1.6}
  .fz-foot h4{margin:0 0 14px;font-size:11px;font-weight:700;letter-spacing:.12em;text-transform:uppercase}
  .fz-foot nav a{display:block;width:max-content;padding:5px 0;color:#9aa0ad;font-size:13.5px}
  .fz-foot nav a:hover{color:#fff}
  .fz-foot-bottom{display:flex;flex-wrap:wrap;align-items:center;justify-content:space-between;gap:12px;
    width:min(100%,1500px);margin:34px auto 0;padding-top:20px;border-top:1px solid var(--line);color:#7d828d;font-size:12.5px}
  .fz-made i{color:var(--red-2)}
  .fz-made b{color:#fff}
  .fz-foot-icons{display:flex;gap:8px}
  .fz-foot-icons a{width:36px;height:36px;display:grid;place-items:center;border:1px solid var(--line);border-radius:9px;font-size:16px}
  .fz-foot-icons a:hover{color:#fff;border-color:var(--line-2)}
  .fz-toasts{position:fixed;z-index:260;right:20px;bottom:20px;display:grid;gap:10px;width:min(360px,calc(100vw - 32px));pointer-events:none}
  .fz-toast{padding:14px 16px;border:1px solid var(--line-2);border-radius:12px;background:rgba(28,31,40,.98);font-size:13.5px}
  .fz-toast.ok{border-color:rgba(94,217,164,.45)}
  .fz-toast.error{border-color:rgba(255,99,109,.5)}
  .fz-btn{display:inline-flex;align-items:center;justify-content:center;gap:9px;min-height:48px;padding:0 20px;
    border:1px solid transparent;border-radius:11px;cursor:pointer;font-size:15px;font-weight:700;transition:all .18s}
  .fz-btn:hover{transform:translateY(-2px)}
  .fz-btn:disabled{opacity:.5;cursor:not-allowed;transform:none}
  .fz-btn.primary{background:var(--red);color:#fff}
  .fz-btn.primary:hover{background:var(--red-2)}
  .fz-btn.glass{border-color:var(--line-2);background:rgba(255,255,255,.05)}
  .fz-btn.glass:hover{background:rgba(255,255,255,.12)}
  .fz-btn.gold{border-color:rgba(255,207,112,.4);background:rgba(255,207,112,.12);color:var(--gold)}
  .fz-btn.sm{min-height:42px;padding:0 15px;font-size:13.5px}
  .fz-field{display:grid;gap:8px}
  .fz-field>span{color:#c9cdd5;font-size:13px;font-weight:700}
  .fz-field input,.fz-field textarea,.fz-field select{width:100%;min-height:52px;padding:13px 15px;
    border:1px solid var(--line-2);border-radius:11px;background:#0e1015;font-size:15px}
  .fz-field textarea{min-height:110px;resize:vertical}
  .fz-hint{margin:8px 0;color:#878b96;font-size:12.5px;line-height:1.7}
  .fz-status{min-height:20px;margin:10px 0;font-size:14px}
  .fz-status.error{color:#ff868e}
  .fz-status.ok{color:#74d9a4}
  .fz-note{margin:14px 0;padding:14px 16px;border:1px solid rgba(255,207,112,.28);border-radius:12px;
    background:rgba(255,207,112,.07);color:#ffd98c;font-size:13.5px;line-height:1.7}
  .fz-card{padding:22px;border:1px solid var(--line);border-radius:18px;background:var(--card)}
  .fz-title{margin:0 0 8px;font-size:clamp(28px,3.6vw,44px);letter-spacing:-.045em}
  .fz-sub{margin:0 0 22px;color:var(--muted);font-size:15px;line-height:1.75;max-width:820px}
  .fz-stats{display:grid;grid-template-columns:repeat(auto-fit,minmax(150px,1fr));gap:14px;margin:20px 0 26px}
  .fz-stat{padding:18px;border:1px solid var(--line);border-radius:15px;background:rgba(255,255,255,.035)}
  .fz-stat b{display:block;font-size:30px;letter-spacing:-.035em}
  .fz-stat span{display:block;margin-top:5px;color:var(--muted);font-size:11px;font-weight:700;letter-spacing:.1em;text-transform:uppercase}
  .fz-grid{display:grid;grid-template-columns:repeat(auto-fill,minmax(150px,1fr));gap:24px 18px}
  .fz-tile{min-width:0}
  .fz-poster{position:relative;display:block;width:100%;aspect-ratio:2/3;overflow:hidden;border:1px solid var(--line);
    border-radius:12px;background:#1c2029;cursor:pointer}
  .fz-poster img{width:100%;height:100%;object-fit:cover;transition:transform .35s}
  .fz-poster:hover img{transform:scale(1.06)}
  .fz-score{position:absolute;top:8px;left:8px;padding:3px 7px;border-radius:6px;background:rgba(8,9,12,.74);color:var(--gold);font-size:11px;font-weight:800}
  .fz-tile b{display:block;overflow:hidden;margin:10px 2px 2px;font-size:13.5px;text-overflow:ellipsis;white-space:nowrap}
  .fz-tile span{display:block;margin-left:2px;color:#858994;font-size:11.5px}
  .fz-chip{display:inline-flex;align-items:center;gap:6px;padding:7px 13px;border:1px solid var(--line);border-radius:999px;
    background:rgba(255,255,255,.04);cursor:pointer;font-size:12.5px;font-weight:600}
  .fz-chip.on{border-color:transparent;background:var(--red);color:#fff}
  body.tv{font-size:17px}
  body.tv .fz-header{min-height:92px}
  body.tv .nav-links{font-size:17px;gap:26px}
  body.tv .icon-btn{width:54px;height:54px;font-size:22px}
  body.tv .fz-btn{min-height:62px;font-size:19px;padding:0 28px}
  body.tv .fz-title{font-size:clamp(38px,4vw,58px)}
  body.tv .fz-sub,body.tv .fz-hint,body.tv .fz-note{font-size:17px}
  body.tv .fz-grid{gap:28px 22px}
  body.tv .fz-tile b{font-size:17px}
  body.tv .fz-stat b{font-size:34px}
  body.tv .fz-menu{width:340px}
  body.tv .fz-menu-item{min-height:56px;font-size:17px}
  body.tv .fz-field input,body.tv .fz-field select{min-height:60px;font-size:18px}
  @media (max-width:820px){
    .nav-links{display:none}
    .fz-foot-grid{grid-template-columns:1fr 1fr;gap:26px}
    .fz-menu{right:12px;top:66px}
  }
  @media (max-width:560px){
    .fz-header{min-height:64px;padding:10px 14px;gap:12px}
    .brand{font-size:18px}
    .brand-mark{width:28px;height:28px;font-size:15px}
    .fz-wrap{padding:20px 14px 60px}
    .fz-grid{grid-template-columns:repeat(auto-fill,minmax(124px,1fr));gap:18px 12px}
    .fz-foot{padding:36px 16px 22px}
    .fz-foot-grid{grid-template-columns:1fr}
    .fz-foot-bottom{flex-direction:column;align-items:flex-start}
    .fz-toasts{right:12px;bottom:12px}
  }`;

  function injectStyles() {
    if (document.getElementById("fzStyles")) return;
    const s = document.createElement("style");
    s.id = "fzStyles";
    s.textContent = CSS;
    document.head.appendChild(s);
  }

  /* ---------------- boot ---------------- */
  document.addEventListener("keydown", (ev) => {
    const t = ev.target;
    if (t && (t.tagName === "INPUT" || t.tagName === "TEXTAREA" || t.tagName === "SELECT")) return;
    const map = { ArrowLeft: "left", ArrowRight: "right", ArrowUp: "up", ArrowDown: "down" };
    if (!map[ev.key]) return;
    ev.preventDefault();
    moveFocus(map[ev.key]);
  }, true);

  async function boot() {
    injectStyles();
    initTvMode();
    initSupabase();
    await refreshUser();
    state.ready = true;
    paintHeader();
    state.listeners.forEach((fn) => { try { fn(state); } catch (e) { console.error("[FZ] listener", e); } });
  }

  window.FZ = {
    OWNER, TMDB, IMG,
    esc, httpsUrl, img, yearOf, titleOf, timeAgo, $,
    get sb() { return state.sb; },
    get user() { return state.user; },
    get profile() { return state.profile; },
    get tv() { return state.tv; },
    get ready() { return state.ready; },
    isOwnerEmail, isAdmin, signIn, signOut, refreshUser, loadProfile,
    makeTvCode, claimTvCode, toast, fullscreen, applyTvMode, paintHeader,
    setUser(u) { state.user = u; return loadProfile().then(paintHeader); },
    ready_(fn) { if (state.ready) fn(state); else state.listeners.push(fn); },
    playUrl(item, opts) {
      const o = opts || {};
      const q = new URLSearchParams({
        m: item.is_custom ? "custom" : (item.media_type || "movie"),
        t: String(item.id)
      });
      if (o.season) q.set("s", String(o.season));
      if (o.episode) q.set("e", String(o.episode));
      if (item.is_custom && item.custom_stream_url) q.set("u", item.custom_stream_url);
      return "player.html?" + q.toString();
    },
    tile(item) {
      const p = img(item.poster_path, "w342");
      return '<article class="fz-tile">' +
        '<a class="fz-poster" href="' + this.playUrl(item) + '" aria-label="Play ' + esc(titleOf(item)) + '">' +
        (p ? '<img src="' + esc(p) + '" alt="' + esc(titleOf(item)) + '" loading="lazy">' : "") +
        (item.vote_average ? '<span class="fz-score">' + Number(item.vote_average).toFixed(1) + "</span>" : "") +
        "</a><b>" + esc(titleOf(item)) + "</b><span>" +
        (item.is_custom ? "Nest original" : (item.media_type === "tv" ? "Series" : "Film")) +
        (yearOf(item) ? " | " + esc(yearOf(item)) : "") + "</span></article>";
    }
  };

  if (document.readyState === "loading") document.addEventListener("DOMContentLoaded", boot);
  else boot();
})();
