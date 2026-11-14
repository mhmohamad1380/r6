"use strict";

(() => {
  const A = window.R6A;
  const C = window.R6C;
  const app = document.getElementById("app");
  const nav = document.getElementById("nav");

  /* ---------- small helpers: elements are built, never written as HTML, so a player name cannot inject anything ---------- */
  function h(tag, props, ...kids) {
    const el = document.createElement(tag);
    for (const [k, v] of Object.entries(props || {})) {
      if (v == null || v === false) continue;
      if (k === "class") el.className = v;
      else if (k === "text") el.textContent = v;
      else if (k.startsWith("on")) el.addEventListener(k.slice(2), v);
      else el.setAttribute(k, v === true ? "" : v);
    }
    for (const kid of kids.flat()) if (kid != null && kid !== false) el.append(kid);
    return el;
  }
  const pct = (v, d = 0) => (v == null ? "–" : (v * 100).toFixed(d) + "%");
  const fix = (v, d = 2) => (v == null ? "–" : v.toFixed(d));
  const when = (ms) => (ms ? new Date(ms).toLocaleDateString("en-GB", { day: "numeric", month: "short", year: "numeric" }) : "Unknown date");
  const clock = (s) => (s == null ? "" : Math.floor(Math.max(s, 0) / 60) + ":" + String(Math.max(s, 0) % 60).padStart(2, "0"));
  const store = {
    get(k) { try { return localStorage.getItem(k); } catch { return null; } },
    set(k, v) { try { v == null ? localStorage.removeItem(k) : localStorage.setItem(k, v); } catch { /* private window: the choice just is not remembered */ } },
  };

  async function api(method, path, body) {
    let r;
    try {
      r = await fetch(path, { method, credentials: "same-origin", headers: { "X-Requested-With": "r6-site", Accept: "application/json", ...(body ? { "Content-Type": "application/json" } : {}) }, body: body ? JSON.stringify(body) : undefined });
    } catch {
      throw new Error("Could not reach the server. Check your connection and try again.");
    }
    const data = await r.json().catch(() => ({}));
    if (!r.ok) {
      const e = new Error(typeof data.detail === "string" ? data.detail : "Something went wrong. Try again.");
      e.status = r.status;
      throw e;
    }
    return data;
  }

  const state = { me: null, rounds: [], failed: 0, total: 0, player: null, detected: null, fetchedAt: null };

  function show(title, ...content) {
    document.title = title + " · R6 Coach";
    app.replaceChildren(...content.flat().filter((x) => x != null && x !== false));
    app.focus({ preventScroll: true });
    window.scrollTo(0, 0);
  }
  const busy = (btn, on, label) => { btn.setAttribute("aria-disabled", String(on)); if (label) btn.textContent = label; };

  /* ---------- 1. sign in or create an account ---------- */
  function authView(mode = "in", note = null) {
    const err = h("p", { class: "msg err", role: "alert", hidden: true });
    const name = h("input", { id: "f-name", name: "username", autocomplete: "username", required: true, autocapitalize: "none", spellcheck: "false", maxlength: "24" });
    const pass = h("input", { id: "f-pass", name: "password", type: "password", autocomplete: mode === "in" ? "current-password" : "new-password", required: true, maxlength: "200", minlength: mode === "in" ? null : "8" });
    const go = h("button", { class: "btn primary", type: "submit", text: mode === "in" ? "Sign in" : "Create account" });
    const form = h("form", { class: "form", novalidate: true },
      h("label", {}, "Name", mode === "up" ? h("span", { class: "hint", text: "3 to 24 letters, numbers, dots, dashes or underscores. It is only used to sign in." }) : null, name),
      h("label", {}, "Password", mode === "up" ? h("span", { class: "hint", text: "At least 8 characters. There is no email, so a lost password cannot be reset: write it down." }) : null, pass),
      err, go);
    form.addEventListener("submit", async (e) => {
      e.preventDefault();
      err.hidden = true;
      if (!name.value.trim() || !pass.value) { err.textContent = "Fill in both the name and the password."; err.hidden = false; return; }
      busy(go, true);
      try {
        state.me = await api("POST", "/api/account/" + (mode === "in" ? "login" : "signup"), { name: name.value, password: pass.value });
        await enter();
      } catch (x) {
        err.textContent = x.message;
        err.hidden = false;
        busy(go, false);
        pass.value = "";
        pass.focus();
      }
    });
    const tab = (m, label) => h("button", { type: "button", role: "tab", "aria-selected": String(m === mode), text: label, onclick: () => authView(m) });
    show(mode === "in" ? "Sign in" : "Create account",
      h("div", { class: "auth stack" },
        h("div", { class: "stack tight" }, h("p", { class: "eyebrow", text: "Your replays on the web" }), h("h1", { text: "See your matches here too." }),
          h("p", { class: "dim", text: "Create an account, save your phone token once, and your matches, stats and maps appear here, from the same replays as the app." })),
        note ? h("p", { class: "msg ok", role: "status", text: note }) : null,
        h("div", { class: "card" }, h("div", { class: "seg", role: "tablist", "aria-label": "Account" }, tab("in", "Sign in"), tab("up", "Create account")), form)));
    name.focus();
  }

  /* ---------- 2. save the token ---------- */
  function tokenView(changing = false) {
    const err = h("p", { class: "msg err", role: "alert", hidden: true });
    const input = h("input", { id: "f-token", type: "password", autocomplete: "off", spellcheck: "false", autocapitalize: "none", required: true, maxlength: "200", "aria-describedby": "token-help" });
    const save = h("button", { class: "btn primary", type: "submit", text: "Save token" });
    const eye = h("button", { class: "btn ghost small", type: "button", text: "Show", onclick: () => { const hide = input.type === "text"; input.type = hide ? "password" : "text"; eye.textContent = hide ? "Show" : "Hide"; } });
    const form = h("form", { class: "form", novalidate: true },
      h("label", {}, "Phone token", h("span", { class: "hint", id: "token-help", text: "The same token you paste into the Android app." }), h("div", { class: "row" }, h("div", { style: null, class: "grow" }, input), eye)),
      err, h("div", { class: "row" }, save, changing ? h("a", { class: "btn ghost", href: "#/settings", text: "Cancel" }) : null));
    form.addEventListener("submit", async (e) => {
      e.preventDefault();
      err.hidden = true;
      busy(save, true, "Checking…");
      try {
        state.me = await api("PUT", "/api/account/token", { token: input.value });
        await enter();
      } catch (x) {
        err.textContent = x.message;
        err.hidden = false;
        busy(save, false, "Save token");
      }
    });
    show("Save your token",
      h("div", { class: "auth stack" },
        h("div", { class: "stack tight" }, h("p", { class: "eyebrow", text: state.me ? "Signed in as " + state.me.name : "" }), h("h1", { text: changing ? "Change your token" : "One more step: your token" }),
          h("p", { class: "dim", text: "The token lets this page read the replays your Windows uploader sent. It is checked with the server before it is saved." })),
        h("div", { class: "card" },
          h("h2", { text: "Where is it?" }),
          h("ol", { class: "steps" },
            h("li", {}, h("b", { text: "Already put it in the app? " }), "Open the app, then Profile, and copy the token from there."),
            h("li", {}, h("b", { text: "No token yet? " }), "Get one on the ", h("a", { href: "/#tokens", text: "home page" }), ". It is shown once per network, so copy it first."),
            h("li", {}, h("b", { text: "Use the phone token, " }), "not the upload token. The upload token is only for the Windows uploader.")),
          form),
        h("button", { class: "btn ghost", type: "button", text: "Sign out", onclick: signOut })));
    input.focus();
  }

  async function signOut() {
    try { await api("POST", "/api/account/logout"); } catch { /* the cookie is gone either way once the server answers; if not, the next page load shows it */ }
    state.me = null;
    state.rounds = [];
    nav.hidden = true;
    history.replaceState(null, "", "/account");
    authView("in", "You are signed out.");
  }

  /* ---------- 3. loading the replays ---------- */
  async function load() {
    const data = await api("GET", "/api/data/rounds");
    state.rounds = data.rounds.map((x) => A.normalize(x.data, x.uploadedAt)).filter(Boolean);
    state.failed = data.failed;
    state.total = data.total;
    state.fetchedAt = new Date();
    state.detected = A.detectPlayer(state.rounds);
    const saved = store.get("r6.player");
    state.player = saved && state.rounds.some((r) => r.players.some((p) => A.same(p.name, saved))) ? saved : state.detected ? state.detected.name : null;
  }

  async function enter() {
    show("Loading", h("p", { class: "dim", role: "status", text: "Loading your matches…" }));
    if (!state.me.hasToken) { nav.hidden = true; tokenView(); return; }
    try {
      await load();
    } catch (x) {
      if (x.status === 401) { state.me = null; authView("in", "Please sign in again."); return; }
      if (x.status === 409) { state.me.hasToken = false; nav.hidden = true; tokenView(); return; }
      show("Could not load", h("div", { class: "card empty" }, h("h1", { text: "Could not load your matches" }), h("p", { class: "dim", text: x.message }), h("button", { class: "btn primary", text: "Try again", onclick: enter })));
      return;
    }
    buildNav();
    route();
  }

  /* ---------- navigation ---------- */
  const PAGES = [["", "Overview"], ["matches", "Matches"], ["insights", "Insights"], ["maps", "Maps"], ["operators", "Operators"], ["settings", "Account"]];
  function buildNav() {
    nav.replaceChildren(...PAGES.map(([p, label]) => h("a", { href: "#/" + p, "data-page": p, text: label })));
    nav.hidden = false;
  }
  function markNav(page) {
    for (const a of nav.querySelectorAll("a")) {
      if (a.dataset.page === page) a.setAttribute("aria-current", "page"); else a.removeAttribute("aria-current");
    }
  }
  function route() {
    if (!state.me || !state.me.hasToken) return;
    const [page = "", arg] = location.hash.replace(/^#\/?/, "").split("/");
    markNav(page === "match" ? "matches" : page);
    ({ "": overview, matches: matchesView, match: () => matchDetail(decodeURIComponent(arg || "")), insights: insightsView, maps: mapsView, operators: operatorsView, settings: settingsView }[page] || overview)();
  }
  window.addEventListener("hashchange", route);

  /* ---------- shared pieces ---------- */
  const mine = () => (state.player ? state.rounds.map((r) => A.analyzeRound(r, state.player)) : []);
  const myMatches = () => A.groupMatches(state.rounds).map((rs) => A.matchView(rs, state.player)).filter((m) => m.mine.some((x) => x.present));

  function refreshBar() {
    return h("div", { class: "row between" },
      h("p", { class: "dim small", text: state.fetchedAt ? "Updated " + state.fetchedAt.toLocaleTimeString("en-GB", { hour: "2-digit", minute: "2-digit" }) : "" }),
      h("button", { class: "btn ghost small", text: "Refresh", onclick: async (e) => { busy(e.target, true, "Refreshing…"); try { await load(); } catch (x) { if (x.status === 401) { state.me = null; authView("in", "Please sign in again."); return; } } route(); } }));
  }

  function emptyView(title, why, ...actions) {
    return h("div", { class: "card empty" }, h("h2", { text: title }), h("p", { class: "dim", text: why }), h("div", { class: "row" }, ...actions));
  }

  function noReplays() {
    return [h("h1", { text: "No matches yet" }), emptyView("Nothing has arrived", state.total ? "Your replays were uploaded but none could be read yet. The Windows uploader retries them automatically after an update." : "Install the Windows uploader, point it at your replay folder and press Upload now. Matches show up here within a minute.", h("a", { class: "btn primary", href: "/#download", text: "Get the uploader" }), h("button", { class: "btn ghost", text: "Check again", onclick: async () => { await load(); route(); } }))];
  }

  function noPlayer() {
    const names = new Map();
    for (const r of state.rounds) for (const p of r.players) if (p.name) names.set(p.name, (names.get(p.name) || 0) + 1);
    const top = [...names.entries()].sort((a, b) => b[1] - a[1]).slice(0, 12);
    return [h("h1", { text: "Which player are you?" }),
      h("div", { class: "card" }, h("p", { class: "dim", text: "These replays do not say whose they are. Pick your name and everything on this page will be about you." }),
        h("div", { class: "row" }, ...top.map(([n, c]) => h("button", { class: "btn ghost small", text: n + " · " + c, onclick: () => { choose(n); } }))))];
  }

  function choose(name) {
    state.player = name;
    store.set("r6.player", name);
    route();
  }

  function whoBar() {
    const how = state.detected && A.same(state.detected.name, state.player) ? (state.detected.how === "recorded" ? "Found from the replays you recorded." : "The one player in nearly every round.") : "Chosen by you.";
    const box = h("div", { class: "who" }, h("div", {}, h("span", { class: "dim small", text: "Showing stats for" }), h("br"), h("b", { text: state.player }), h("span", { class: "dim small", text: "  " + how })));
    const names = new Map();
    for (const r of state.rounds) for (const p of r.players) if (p.name) names.set(p.name, (names.get(p.name) || 0) + 1);
    const sel = h("select", { class: "inline-input", "aria-label": "Show stats for another player", onchange: (e) => { if (e.target.value) choose(e.target.value); } },
      h("option", { value: "", text: "Not you? Change" }), ...[...names.entries()].sort((a, b) => b[1] - a[1]).slice(0, 40).map(([n]) => h("option", { value: n, text: n })));
    sel.style.width = "auto";
    box.append(sel);
    return box;
  }

  function tile(label, value, note, cls) {
    return h("div", { class: "tile" }, h("span", { text: label }), h("b", { class: cls || "", text: value }), note ? h("small", { text: note }) : null);
  }

  function badge(m) {
    return h("span", { class: "badge " + (m.won === true ? "win" : m.won === false ? "loss" : ""), text: m.won === null ? m.wins + "–" + m.losses : (m.won ? "Won " : "Lost ") + m.wins + "–" + m.losses });
  }

  function matchRow(m) {
    const f = m.first;
    return h("li", {}, h("a", { class: "item", href: "#/match/" + encodeURIComponent(f.matchId) },
      h("span", { class: "t", text: f.map }), h("span", { class: "s", text: when(f.at) + " · " + f.matchType + " · " + m.rounds.length + " rounds · " + m.sum.kills + " kills, " + m.sum.deaths + " deaths" }),
      h("span", { class: "r" }, badge(m), h("span", { class: "dim small", text: "KOST " + pct(m.sum.kost) }))));
  }

  /* ---------- Overview ---------- */
  function overview() {
    if (!state.rounds.length) return show("Overview", noReplays());
    if (!state.player) return show("Who are you", noPlayer());
    const s = A.summarize(mine());
    const matches = myMatches();
    const last = mine().filter((x) => x.present).sort((a, b) => (a.round.at || 0) - (b.round.at || 0) || a.round.number - b.round.number).slice(-30);
    show("Overview",
      h("h1", { text: "Your matches" }), refreshBar(), whoBar(),
      state.failed ? h("p", { class: "msg", text: state.failed + " replay" + (state.failed === 1 ? "" : "s") + " could not be read. They are retried automatically." }) : null,
      h("div", { class: "tiles" },
        tile("Matches", String(matches.length), s.rounds + " rounds"),
        tile("Rounds won", pct(s.winRate), s.wins + " won, " + s.losses + " lost", s.winRate >= 0.5 ? "good" : "bad"),
        tile("K/D", fix(s.kd), s.kills + " kills, " + s.deaths + " deaths"),
        tile("KOST", pct(s.kost), s.kostIsLowerBound ? "at least; some rounds have no kill times" : "rounds with a kill, objective, survival or trade"),
        tile("Headshots", pct(s.headshotRate), "of your kills"),
        tile("Survival", pct(s.survival), "rounds you lived"),
        tile("Opening duels", pct(s.openingRate), s.openingKills + " won, " + s.openingDeaths + " lost"),
        tile("Dying alone", s.deaths ? pct(1 - s.avengedDeaths / s.deaths) : "–", "deaths no teammate answered")),
      findingsSection(A.findings(mine(), matches).slice(0, 4), true),
      matches.length >= 2 ? h("section", { class: "stack" }, h("div", { class: "row between" }, h("h2", { text: "Your form" }), h("a", { href: "#/insights", text: "More trends" })), formChart(A.matchSeries(matches), "kost")) : null,
      h("section", { class: "stack" }, h("h2", { text: "Last " + last.length + " rounds" }), h("div", { class: "mini", role: "img", "aria-label": last.map((x) => (x.won ? "won" : "lost")).join(", ") }, ...last.map((x) => h("i", { class: x.won === true ? "w" : x.won === false ? "l" : "" })))),
      h("section", { class: "stack" }, h("div", { class: "row between" }, h("h2", { text: "Recent matches" }), h("a", { href: "#/matches", text: "All matches" })), h("ul", { class: "list" }, ...matches.slice(0, 5).map(matchRow))));
  }

  /* ---------- charts and findings ---------- */
  const TONE = { good: "Strength", bad: "Work on", info: "Worth knowing" };
  function findingsSection(list, short) {
    if (!list.length) return short ? null : h("section", { class: "stack" }, h("h2", { text: "What stands out" }), h("p", { class: "dim", text: "Play a few more matches: findings need at least 10 rounds behind them." }));
    return h("section", { class: "stack" },
      h("div", { class: "row between" }, h("h2", { text: "What stands out" }), short ? h("a", { href: "#/insights", text: "All insights" }) : null),
      h("ul", { class: "finds" }, ...list.map((f) => h("li", { class: f.tone }, h("span", { class: "tag", text: TONE[f.tone] }), h("b", { text: f.title }), h("span", { text: f.text })))));
  }

  const METRICS = {
    kost: { name: "KOST", pct: true, ref: null, fmt: (v) => pct(v) },
    winRate: { name: "Rounds won", pct: true, ref: 0.5, fmt: (v) => pct(v) },
    kd: { name: "K/D", pct: false, ref: 1, fmt: (v) => fix(v, v >= 10 ? 0 : 1) },
    headshotRate: { name: "Headshots", pct: true, ref: null, fmt: (v) => pct(v) },
  };
  const shortDate = (ms) => (ms ? new Date(ms).toLocaleDateString("en-GB", { day: "numeric", month: "short" }) : "?");

  /** Each match as a dot, and the average of the last 5 as a line. */
  function formChart(series, metric) {
    const M = METRICS[metric];
    const values = series.map((m) => m[metric]);
    const n = Math.min(5, series.length);
    return C.line({
      points: series.map((m) => ({ value: m[metric], label: shortDate(m.at), tip: [m.map + " · " + shortDate(m.at), (m.won === true ? "Won " : m.won === false ? "Lost " : "") + m.wins + "–" + m.losses, M.name + ": " + (m[metric] == null ? "–" : M.fmt(m[metric])), m.kills + " kills, " + m.deaths + " deaths"] })),
      avg: A.rolling(values, n), pct: M.pct, ref: M.ref, format: M.fmt, label: M.name + " per match, oldest to newest, with a " + n + "-match average",
      dotName: "Each match", lineName: n + "-match average",
    });
  }

  function insightsView() {
    if (!state.rounds.length) return show("Insights", noReplays());
    if (!state.player) return show("Who are you", noPlayer());
    const all = mine(), matches = myMatches();
    const series = A.matchSeries(matches);

    // form, with a choice of number
    let metric = store.get("r6.metric") || "kost";
    if (!METRICS[metric]) metric = "kost";
    const formBox = h("div");
    const pills = h("div", { class: "pills", role: "group", "aria-label": "Number to show" });
    const drawForm = () => {
      for (const b of pills.children) b.setAttribute("aria-pressed", String(b.dataset.m === metric));
      formBox.replaceChildren(series.length >= 2 ? formChart(series, metric) : h("p", { class: "dim", text: "The form chart needs two or more matches." }),
        C.tableView(["Match", "Map", "Result", METRICS[metric].name], series.slice().reverse().map((m) => [shortDate(m.at), m.map, m.wins + "–" + m.losses, m[metric] == null ? "–" : METRICS[metric].fmt(m[metric])])));
    };
    for (const [k, M] of Object.entries(METRICS)) pills.append(h("button", { type: "button", "data-m": k, text: M.name, onclick: () => { metric = k; store.set("r6.metric", k); drawForm(); } }));
    drawForm();

    // when in the round
    const t = A.timing(all);
    const timingBox = t.rounds ? [C.bars({ cats: t.labels, series: [{ name: "Your kills", cls: "s1", values: t.kills }, { name: "Your deaths", cls: "s2", values: t.deaths }], integer: true, format: (v) => String(Math.round(v)), label: "Your kills and deaths by time left in the round",
      tips: (i) => [t.labels[i] === "After plant" ? "After the plant" : t.labels[i] + " left", "Kills: " + t.kills[i], "Deaths: " + t.deaths[i]] }),
      h("p", { class: "dim small", text: "Round clock in 30-second slices, from " + t.rounds + " rounds with kill times. After the plant the game shows the defuser timer, so those are counted apart." }),
      C.tableView(["Time left", "Kills", "Deaths"], t.labels.map((l, i) => [l, t.kills[i], t.deaths[i]]))]
      : [h("p", { class: "dim", text: "These replays have no kill times." })];

    // kills per round
    const kpr = A.killsPerRound(all);
    const rounds = kpr.reduce((a, b) => a + b, 0);
    const multi = kpr.slice(2).reduce((a, b) => a + b, 0);

    // first kill
    const o = A.openingImpact(all);
    const oRow = (label, x, note) => ({ label, value: x.rate, text: pct(x.rate), note: x.rounds + " rounds", tip: [label, pct(x.rate) + " of rounds won", x.wins + " of " + x.rounds + (note ? " · " + note : "")] });

    // clutches
    const c = A.clutches(all);
    const cl = c.vs.map((v, i) => ({ v, i })).filter((x) => x.v.rounds > 0);

    // time of day and sessions
    const day = A.byDaypart(matches).filter((d) => d.rounds > 0);
    const ses = A.sessions(matches);
    const nth = ses.nth.filter((x) => x.rounds > 0);

    show("Insights", h("h1", { text: "Insights" }), refreshBar(), whoBar(),
      findingsSection(A.findings(all, matches), false),
      h("section", { class: "stack" }, h("h2", { text: "Form over time" }), h("p", { class: "dim small", text: "One dot per match. The line smooths out single good or bad games, so you can see the trend." }), pills, formBox),
      h("section", { class: "stack" }, h("h2", { text: "When you fight" }), ...timingBox),
      h("div", { class: "two" },
        h("section", { class: "stack" }, h("h2", { text: "Kills per round" }),
          C.bars({ cats: ["0", "1", "2", "3", "4", "5"], series: [{ name: "Rounds", cls: "s1", values: kpr }], integer: true, format: (v) => String(Math.round(v)), label: "How many rounds had 0 to 5 kills",
            tips: (i) => [i + (i === 1 ? " kill" : " kills"), kpr[i] + " rounds (" + pct(rounds ? kpr[i] / rounds : null) + ")"] }),
          h("p", { class: "dim small", text: "Multi-kill rounds (2 or more): " + multi + " of " + rounds + " (" + pct(rounds ? multi / rounds : null) + "). Aces: " + kpr[5] + "." })),
        h("section", { class: "stack" }, h("h2", { text: "The first kill of the round" }),
          C.hbars({ ref: 0.5, label: "Rounds won after the first kill", rows: [oRow("Your team got it", o.teamFirst), oRow("Your team lost it", o.teamFirstDeath), oRow("You got it", o.youFirst, "your opening kills"), oRow("You were the first to die", o.youFirstDeath)] }),
          h("p", { class: "dim small", text: "Share of rounds won. The dashed mark is 50%." }))),
      h("div", { class: "two" },
        h("section", { class: "stack" }, h("h2", { text: "Clutches" }),
          cl.length ? C.hbars({ ref: 0.5, label: "Clutch rounds won by number of enemies left", rows: cl.map(({ v, i }) => ({ label: "1 vs " + (i + 1), value: v.rate, text: pct(v.rate), note: v.wins + " of " + v.rounds, tip: ["1 vs " + (i + 1), "Won " + v.wins + " of " + v.rounds] })) })
            : h("p", { class: "dim", text: "You were never the last one alive on your team yet." }),
          cl.length ? h("p", { class: "dim small", text: "Rounds where you were the last one alive on your team with enemies still up: " + c.rounds + ", won " + c.wins + "." }) : null),
        h("section", { class: "stack" }, h("h2", { text: "Time of day" }),
          day.length ? C.hbars({ ref: 0.5, label: "Rounds won by time of day", rows: day.map((d) => ({ label: d.name, value: d.rate, text: pct(d.rate), note: d.matches + " match" + (d.matches === 1 ? "" : "es"), tip: [d.name + " (" + ({ Night: "0–6", Morning: "6–12", Afternoon: "12–18", Evening: "18–24" })[d.name] + ")", pct(d.rate) + " of " + d.rounds + " rounds won", "K/D " + fix(d.kd)] })) })
            : h("p", { class: "dim", text: "No match times in these replays." }),
          h("p", { class: "dim small", text: "By when the match started, on this device's clock." }))),
      h("section", { class: "stack" }, h("h2", { text: "Sessions" }),
        h("div", { class: "duo" }, h("div", { class: "tile" }, h("span", { text: "Sessions" }), h("b", { text: String(ses.count) }), h("small", { text: "a break of 90 minutes or more starts a new one" })),
          h("div", { class: "tile" }, h("span", { text: "Matches per session" }), h("b", { text: fix(ses.avgMatches, 1) }), h("small", { text: "on average" }))),
        nth.length > 1 ? C.hbars({ ref: 0.5, label: "Rounds won by match number in the session", rows: nth.map((x) => ({ label: x.name, value: x.rate, text: pct(x.rate), note: x.matches + " match" + (x.matches === 1 ? "" : "es"), tip: [x.name + " of a session", pct(x.rate) + " of " + x.rounds + " rounds won", "KOST " + pct(x.kost)] })) }) : null,
        nth.length > 1 ? h("p", { class: "dim small", text: "Rounds won by how many matches into a session you were. A drop later on is a sign to take breaks." }) : null));
  }

  /* ---------- Matches ---------- */
  function matchesView() {
    if (!state.rounds.length) return show("Matches", noReplays());
    if (!state.player) return show("Who are you", noPlayer());
    const list = myMatches();
    show("Matches", h("h1", { text: "Matches" }), refreshBar(), whoBar(),
      list.length ? h("ul", { class: "list" }, ...list.map(matchRow)) : emptyView("No matches with " + state.player, "That name is not in these replays. Change the player above."));
  }

  function matchDetail(id) {
    const rounds = state.rounds.filter((r) => r.matchId === id).sort((a, b) => a.number - b.number);
    if (!rounds.length) return show("Match", h("a", { class: "crumb", href: "#/matches", text: "← All matches" }), emptyView("Match not found", "It may not have been uploaded yet.", h("a", { class: "btn primary", href: "#/matches", text: "Back to matches" })));
    const m = A.matchView(rounds, state.player);
    const f = m.first;
    const myTeam = (() => { const p = f.players.find((q) => A.same(q.name, state.player)); return p ? p.team : null; })();
    const board = A.leaderboard(rounds);
    const rowFor = (p) => h("tr", { class: A.same(p.name, state.player) ? "me" : "" },
      h("td", { text: p.name || "(unnamed)" }), h("td", { text: String(p.kills) }), h("td", { text: String(p.deaths) }), h("td", { text: fix(p.kd) }), h("td", { text: pct(p.kost) }), h("td", { text: pct(p.headshotRate) }));
    const group = (team, label) => [h("tr", { class: "sep" }, h("td", { colspan: "6", text: label })), ...board.filter((p) => p.team === team).map(rowFor)];
    const feedBox = h("div", { class: "stack" });
    const strip = h("div", { class: "strip", role: "group", "aria-label": "Rounds" });
    const pick = (r) => {
      for (const b of strip.querySelectorAll("button")) b.setAttribute("aria-pressed", String(b.dataset.n === String(r.number)));
      feedBox.replaceChildren(roundFeed(r));
    };
    for (const x of m.mine) {
      const cls = x.present ? (x.won === true ? "w" : x.won === false ? "l" : "") : "";
      strip.append(h("button", { type: "button", class: cls, "data-n": String(x.round.number), "aria-pressed": "false", "aria-label": "Round " + (x.round.number + 1) + (x.won === true ? ", won" : x.won === false ? ", lost" : ""), onclick: () => pick(x.round) },
        String(x.round.number + 1), h("small", { text: x.present ? (x.attack ? "ATK" : "DEF") : "" })));
    }
    show(f.map,
      h("a", { class: "crumb", href: "#/matches", text: "← All matches" }),
      h("div", { class: "stack tight" }, h("h1", { text: f.map }), h("div", { class: "row" }, badge(m), h("span", { class: "dim", text: when(f.at) + " · " + f.matchType + (f.mode ? " · " + f.mode : "") }))),
      h("div", { class: "tiles" }, tile("Kills", String(m.sum.kills)), tile("Deaths", String(m.sum.deaths)), tile("KOST", pct(m.sum.kost)), tile("Headshots", pct(m.sum.headshotRate))),
      h("section", { class: "stack" }, h("h2", { text: "Rounds" }), h("p", { class: "dim small", text: "Tap a round to see what happened in it." }), strip, feedBox),
      m.mine.some((x) => x.present) ? h("section", { class: "stack" }, h("h2", { text: "Your kills by round" }),
        C.bars({ cats: m.mine.map((x) => String(x.round.number + 1)), series: [{ name: "Kills", cls: "s1", values: m.mine.map((x) => x.kills) }], integer: true, format: (v) => String(Math.round(v)), label: "Your kills in each round of this match", height: 170,
          tips: (i) => { const x = m.mine[i]; return ["Round " + (x.round.number + 1) + (x.present ? (x.attack ? " · attack" : " · defense") : ""), x.kills + (x.kills === 1 ? " kill" : " kills") + (x.headshots ? ", " + x.headshots + " headshot" + (x.headshots === 1 ? "" : "s") : ""), !x.present ? "Not in this round" : x.died ? "Died" : "Survived", x.won === true ? "Round won" : x.won === false ? "Round lost" : ""].filter(Boolean); } })) : null,
      h("section", { class: "stack" }, h("h2", { text: "Scoreboard" }), h("div", { class: "tablebox" }, h("table", {},
        h("thead", {}, h("tr", {}, h("th", { text: "Player" }), h("th", { text: "K" }), h("th", { text: "D" }), h("th", { text: "K/D" }), h("th", { text: "KOST" }), h("th", { text: "HS" }))),
        h("tbody", {}, ...(myTeam === null ? [...group(0, "Team 1"), ...group(1, "Team 2")] : [...group(myTeam, "Your team"), ...group(1 - myTeam, "Opponents")]))))));
    const first = m.mine.find((x) => x.present && x.died) || m.mine[0];
    if (first) pick(first.round);
  }

  function roundFeed(r) {
    const teamOf = (n) => { const p = r.players.find((q) => A.same(q.name, n)); return p ? p.team : null; };
    const myTeam = teamOf(state.player);
    const head = r.teams.length === 2 ? r.teams.map((t) => t.role + " " + t.score).join("  –  ") : "";
    const items = r.events.filter((e) => e.kill || e.plant || e.defuse || e.type === "PlayerLeave").map((e) => {
      const who = (n) => (n ? h("span", { class: A.same(n, state.player) ? "you" : myTeam != null && teamOf(n) === myTeam ? "ally" : myTeam != null && teamOf(n) != null ? "foe" : "", text: A.same(n, state.player) ? n + " (you)" : n }) : h("span", { text: "Someone" }));
      let body;
      if (e.kill) body = [who(e.actor), " killed ", who(e.target), e.headshot ? " · headshot" : "", e.operator ? " · " + e.operator : ""];
      else if (e.plant) body = [who(e.actor), " planted the defuser"];
      else if (e.defuse) body = [who(e.actor), " defused it"];
      else body = [who(e.actor), " left the match"];
      return h("li", {}, h("time", { text: clock(e.remaining) }), h("div", {}, ...body));
    });
    return h("div", { class: "stack" },
      h("h3", { text: "Round " + (r.number + 1) + (r.site ? " · " + r.site : "") }), head ? h("p", { class: "dim small", text: head }) : null,
      items.length ? h("ol", { class: "feed" }, ...items) : h("p", { class: "dim", text: "No kills were recorded in this round." }));
  }

  /* ---------- Maps and operators ---------- */
  function table(cols, rows) {
    return h("div", { class: "tablebox" }, h("table", {}, h("thead", {}, h("tr", {}, ...cols.map((c) => h("th", { text: c })))), h("tbody", {}, ...rows)));
  }
  function winCell(wr) {
    const bar = h("i");
    bar.style.width = Math.round((wr || 0) * 100) + "%";
    return h("td", {}, pct(wr), h("span", { class: "bar", "aria-hidden": "true" }, bar));
  }

  function mapsView() {
    if (!state.rounds.length) return show("Maps", noReplays());
    if (!state.player) return show("Who are you", noPlayer());
    const all = mine();
    const byMap = A.groupBy(all, (r) => r.round.map);
    const sides = A.groupBy(all, (r) => (r.team ? (r.attack ? "Attack" : "Defense") : null));
    const sites = A.siteStats(all).filter((x) => x.rounds >= 2);
    show("Maps", h("h1", { text: "Maps and sides" }), refreshBar(), whoBar(),
      byMap.length ? h("section", { class: "stack" }, h("h2", { text: "Round wins by map" }),
        C.hbars({ ref: 0.5, label: "Share of rounds won on each map", rows: byMap.slice(0, 12).map((x) => ({ label: x.name, value: x.winRate, text: pct(x.winRate), note: x.rounds + " rounds", tip: [x.name, pct(x.winRate) + " of " + x.rounds + " rounds won", "K/D " + fix(x.kd) + " · KOST " + pct(x.kost)] })) }),
        h("p", { class: "dim small", text: "Most played first. The dashed mark is 50%." })) : null,
      sidesByMap(all),
      h("section", { class: "stack" }, h("h2", { text: "By map" }),
        table(["Map", "Matches", "Rounds", "Win", "K/D", "KOST"], byMap.map((x) => h("tr", {}, h("td", { text: x.name }), h("td", { text: String(x.matches) }), h("td", { text: String(x.rounds) }), winCell(x.winRate), h("td", { text: fix(x.kd) }), h("td", { text: pct(x.kost) }))))),
      sides.length ? h("section", { class: "stack" }, h("h2", { text: "Attack and defense" }),
        table(["Side", "Rounds", "Win", "K/D", "KOST"], sides.map((x) => h("tr", {}, h("td", { text: x.name }), h("td", { text: String(x.rounds) }), winCell(x.winRate), h("td", { text: fix(x.kd) }), h("td", { text: pct(x.kost) }))))) : null,
      sites.length ? h("section", { class: "stack" }, h("h2", { text: "By bombsite" }), h("p", { class: "dim small", text: "Rounds your team won, by map, side and site. Only sites with 2 or more rounds." }),
        table(["Site", "Side", "Rounds", "Win"], sites.map((x) => h("tr", {}, h("td", { text: x.map + " · " + x.site }), h("td", { text: x.attack ? "Attack" : "Defense" }), h("td", { text: String(x.rounds) }), winCell(x.wins / x.rounds))))) : null);
  }

  /** Attack and defense win rates side by side for each map with rounds on both sides. */
  function sidesByMap(all) {
    const maps = A.groupBy(all, (r) => r.round.map).slice(0, 8).map((m) => {
      const side = (atk) => A.summarize(all.filter((r) => r.present && r.team && r.round.map === m.name && r.attack === atk));
      return { name: m.name, atk: side(true), def: side(false) };
    }).filter((m) => m.atk.rounds >= 3 && m.def.rounds >= 3);
    if (!maps.length) return null;
    return h("section", { class: "stack" }, h("h2", { text: "Attack and defense by map" }),
      C.bars({ cats: maps.map((m) => m.name), pct: true, format: (v) => pct(v), label: "Rounds won on attack and on defense, per map",
        series: [{ name: "Attack", cls: "s1", values: maps.map((m) => m.atk.winRate) }, { name: "Defense", cls: "s2", values: maps.map((m) => m.def.winRate) }],
        tips: (i) => [maps[i].name, "Attack: " + pct(maps[i].atk.winRate) + " of " + maps[i].atk.rounds, "Defense: " + pct(maps[i].def.winRate) + " of " + maps[i].def.rounds] }),
      C.tableView(["Map", "Attack", "Defense"], maps.map((m) => [m.name, pct(m.atk.winRate) + " (" + m.atk.rounds + ")", pct(m.def.winRate) + " (" + m.def.rounds + ")"])));
  }

  function operatorsView() {
    if (!state.rounds.length) return show("Operators", noReplays());
    if (!state.player) return show("Who are you", noPlayer());
    const ops = A.groupBy(mine(), (r) => r.player.operator);
    const top = ops.filter((x) => x.rounds >= 3).slice(0, 10);
    show("Operators", h("h1", { text: "Operators" }), refreshBar(), whoBar(),
      top.length ? h("section", { class: "stack" }, h("h2", { text: "KOST by operator" }),
        C.hbars({ label: "KOST on your most played operators", rows: top.map((x) => ({ label: x.name, value: x.kost, text: pct(x.kost), note: x.rounds + " rounds", tip: [x.name, "KOST " + pct(x.kost) + " over " + x.rounds + " rounds", "K/D " + fix(x.kd) + " · won " + pct(x.winRate)] })) }),
        h("p", { class: "dim small", text: "Your most played operators with 3 or more rounds. KOST: rounds with a kill, objective, survival or trade." })) : null,
      ops.length ? table(["Operator", "Rounds", "Win", "K/D", "KOST", "HS"], ops.map((x) => h("tr", {}, h("td", { text: x.name }), h("td", { text: String(x.rounds) }), winCell(x.winRate), h("td", { text: fix(x.kd) }), h("td", { text: pct(x.kost) }), h("td", { text: pct(x.headshotRate) }))))
        : emptyView("No operators recorded", "These replays do not say which operator you played."));
  }

  /* ---------- Account ---------- */
  function settingsView() {
    const note = h("p", { class: "msg", role: "status", hidden: true });
    const pw = h("input", { class: "inline-input", type: "password", autocomplete: "current-password", "aria-label": "Your password", placeholder: "Your password" });
    const del = h("button", { class: "btn danger", type: "button", text: "Delete my account", onclick: async () => {
      if (!pw.value) { note.textContent = "Type your password first."; note.hidden = false; return; }
      try { await api("POST", "/api/account/delete", { password: pw.value }); state.me = null; nav.hidden = true; store.set("r6.player", null); authView("up", "Your account was deleted."); }
      catch (x) { note.textContent = x.message; note.hidden = false; }
    } });
    show("Account", h("h1", { text: "Account" }),
      h("div", { class: "card" }, h("h2", { text: state.me.name }), h("p", { class: "dim", text: "Token saved: " + state.me.tokenHint }),
        h("div", { class: "row" }, h("button", { class: "btn ghost", text: "Change token", onclick: () => tokenView(true) }),
          h("button", { class: "btn ghost", text: "Remove token", onclick: async () => { state.me = await api("DELETE", "/api/account/token"); nav.hidden = true; tokenView(); } }),
          h("button", { class: "btn ghost", text: "Sign out", onclick: signOut }))),
      h("div", { class: "card" }, h("h2", { text: "Delete account" }), h("p", { class: "dim", text: "Removes your name, password and saved token from this site. Your replays stay on the replay server, and the app keeps working." }), pw, note, del));
  }

  /* ---------- start ---------- */
  (async () => {
    try {
      state.me = await api("GET", "/api/account/me");
    } catch (x) {
      show("Offline", h("div", { class: "card empty" }, h("h1", { text: "Could not reach the server" }), h("p", { class: "dim", text: x.message }), h("button", { class: "btn primary", text: "Try again", onclick: () => location.reload() })));
      return;
    }
    if (!state.me.signedIn) { state.me = null; authView(location.hash === "#up" ? "up" : "in"); return; }
    await enter();
  })();
})();
