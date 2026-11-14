"use strict";

(() => {
  const $ = (sel, root = document) => root.querySelector(sel);
  const $$ = (sel, root = document) => [...root.querySelectorAll(sel)];

  // Decimal units, the way Android and Windows report file sizes.
  const size = (n) => (n >= 1e6 ? (n / 1e6).toFixed(1) + " MB" : Math.max(1, Math.round(n / 1e3)) + " KB");
  const day = (iso) => new Date(iso + "T00:00:00Z").toLocaleDateString("en-GB", { day: "numeric", month: "short", year: "numeric", timeZone: "UTC" });

  /* ---------- copy to the clipboard, with a fallback for old browsers ---------- */
  function legacyCopy(text) {
    const t = document.createElement("textarea");
    t.value = text;
    t.setAttribute("readonly", "");
    t.className = "offscreen";
    document.body.append(t);
    t.select();
    let ok = false;
    try { ok = document.execCommand("copy"); } catch { ok = false; }
    t.remove();
    return ok;
  }

  async function copyText(text) {
    // The modern call can hang when the page lacks permission, so it gets 1.5 seconds before the old way is tried.
    if (navigator.clipboard && window.isSecureContext) {
      try {
        await Promise.race([navigator.clipboard.writeText(text), new Promise((_, no) => setTimeout(() => no(new Error("timeout")), 1500))]);
        return true;
      } catch { /* fall through */ }
    }
    return legacyCopy(text);
  }

  function flash(button, label = "Copied") {
    const old = button.dataset.label || button.textContent;
    button.dataset.label = old;
    button.textContent = label;
    clearTimeout(button._t);
    button._t = setTimeout(() => { button.textContent = old; }, 1400);
  }

  /* ---------- downloads ---------- */
  async function loadInfo() {
    let info;
    try {
      const r = await fetch("/api/info", { headers: { Accept: "application/json" } });
      if (!r.ok) throw new Error(String(r.status));
      info = await r.json();
    } catch {
      $$("[data-file] [data-meta]").forEach((m) => { m.textContent = "Size unavailable"; });
      return;
    }
    const byName = Object.fromEntries(info.files.map((f) => [f.name, f]));
    $$("[data-file]").forEach((card) => {
      const f = byName[card.dataset.file];
      const meta = $("[data-meta]", card);
      const btn = $("[data-dl]", card);
      if (!f) {
        meta.textContent = "Not available right now";
        btn.setAttribute("aria-disabled", "true");
        btn.removeAttribute("href");
        return;
      }
      // Each piece stays on one line; the line breaks between pieces, never inside one.
      const bits = [f.version ? "Version " + f.version : null, size(f.size), f.requires || null, "updated " + day(f.updated)].filter(Boolean);
      meta.replaceChildren(...bits.flatMap((b, i) => {
        const span = document.createElement("span");
        span.className = "m";
        span.textContent = b;
        return i ? [document.createTextNode(" · "), span] : [span];
      }));
      $("[data-hash]", card).textContent = f.sha256;
      const copy = $("[data-copy-hash]", card);
      copy.addEventListener("click", async () => { if (await copyText(f.sha256)) flash(copy); });
    });
  }

  /* ---------- tokens, once per network address ---------- */
  const box = $("[data-token-box]");
  let unsaved = false;
  let issued = null;

  function show(state) {
    $$("[data-state]", box).forEach((el) => { el.hidden = el.dataset.state !== state; });
  }

  async function status() {
    show("loading");
    try {
      const r = await fetch("/api/token/status", { headers: { Accept: "application/json" } });
      if (!r.ok) throw new Error(String(r.status));
      const s = await r.json();
      show(s.issued ? "used" : "ready");
    } catch {
      fail("Could not reach the server. Check your connection and try again.");
    }
  }

  function fail(message) {
    $("[data-error]", box).textContent = message;
    show("error");
  }

  async function getTokens() {
    const btn = $("[data-get]", box);
    btn.setAttribute("aria-disabled", "true");
    try {
      const r = await fetch("/api/token", { method: "POST", headers: { "X-Requested-With": "r6-site", Accept: "application/json" } });
      const body = await r.json().catch(() => ({}));
      if (r.status === 409) { show("used"); return; }
      if (!r.ok) { fail(body.detail || "Could not get tokens right now. Try again in a minute."); return; }
      issued = body;
      for (const input of $$("[data-field]", box)) input.value = body[input.dataset.field] || "";
      unsaved = true;
      show("shown");
    } catch {
      fail("Could not reach the server. Check your connection and try again.");
    } finally {
      btn.removeAttribute("aria-disabled");
    }
  }

  // The tokens are safe once both were copied, or the file was saved.
  const copied = new Set();
  function markSaved(key) {
    if (key) copied.add(key); else { copied.add("uploadToken"); copied.add("readToken"); }
    if (copied.has("uploadToken") && copied.has("readToken")) unsaved = false;
  }

  if (box) {
    $("[data-get]", box).addEventListener("click", getTokens);
    $("[data-retry]", box).addEventListener("click", status);
    const note = $("[data-copied]", box);

    $$("[data-copy]", box).forEach((b) => b.addEventListener("click", async () => {
      const v = issued && issued[b.dataset.copy];
      if (v && (await copyText(v))) { flash(b); markSaved(b.dataset.copy); note.textContent = "Copied. Paste it into the app."; }
      else note.textContent = "Could not copy. Select the text and copy it by hand.";
    }));

    $$("[data-toggle]", box).forEach((b) => b.addEventListener("click", () => {
      const input = $(`[data-field="${b.dataset.toggle}"]`, box);
      const hide = input.type === "text";
      input.type = hide ? "password" : "text";
      b.textContent = hide ? "Show" : "Hide";
    }));

    $("[data-save]", box).addEventListener("click", () => {
      if (!issued) return;
      const text = [
        "R6 Coach settings",
        "",
        "Server address: " + issued.serverUrl,
        "Upload token (Windows uploader): " + issued.uploadToken,
        "Phone token (Android app): " + issued.readToken,
        "",
        "Keep this file private.",
        "",
      ].join("\n");
      const url = URL.createObjectURL(new Blob([text], { type: "text/plain" }));
      const a = document.createElement("a");
      a.href = url;
      a.download = "r6-coach-settings.txt";
      document.body.append(a);
      a.click();
      a.remove();
      setTimeout(() => URL.revokeObjectURL(url), 2000);
      markSaved();
      note.textContent = "Saved. Keep the file private.";
    });

    // Closing the tab before saving would lose the only copy.
    window.addEventListener("beforeunload", (e) => { if (unsaved) { e.preventDefault(); e.returnValue = ""; } });
    status();
  }

  /* ---------- setup tabs (arrow keys, as screen readers expect) ---------- */
  const tabs = $$('[role="tab"]');
  function select(tab, focus) {
    for (const t of tabs) {
      const on = t === tab;
      t.setAttribute("aria-selected", String(on));
      t.tabIndex = on ? 0 : -1;
      $("#" + t.getAttribute("aria-controls")).hidden = !on;
    }
    if (focus) tab.focus();
  }
  tabs.forEach((t, i) => {
    t.addEventListener("click", () => select(t, false));
    t.addEventListener("keydown", (e) => {
      const n = { ArrowRight: i + 1, ArrowLeft: i - 1, Home: 0, End: tabs.length - 1 }[e.key];
      if (n === undefined) return;
      e.preventDefault();
      select(tabs[(n + tabs.length) % tabs.length], true);
    });
  });

  /* ---------- show where you are in the page ---------- */
  const links = $$("nav a");
  if ("IntersectionObserver" in window) {
    const seen = new Map();
    const io = new IntersectionObserver((entries) => {
      for (const e of entries) seen.set(e.target.id, e.isIntersecting ? e.intersectionRatio : 0);
      const best = [...seen.entries()].sort((a, b) => b[1] - a[1])[0];
      for (const a of links) {
        if (best && best[1] > 0 && a.getAttribute("href") === "#" + best[0]) a.setAttribute("aria-current", "true");
        else a.removeAttribute("aria-current");
      }
    }, { rootMargin: "-20% 0px -55% 0px", threshold: [0, 0.2, 0.5, 1] });
    for (const a of links) { const s = $(a.getAttribute("href")); if (s) io.observe(s); }
  }

  loadInfo();
})();
