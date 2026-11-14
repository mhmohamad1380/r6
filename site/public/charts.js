"use strict";

/* Small SVG charts for the signed-in pages. No libraries (the page's security policy allows only this site's scripts).
   Every chart redraws at its box's width, has a hover and keyboard tooltip, and a "Show as table" view. Colours come
   from CSS classes in account.css, never from the data. */
(() => {
  const NS = "http://www.w3.org/2000/svg";
  function s(tag, attrs, ...kids) {
    const el = document.createElementNS(NS, tag);
    for (const [k, v] of Object.entries(attrs || {})) if (v != null) el.setAttribute(k, v);
    for (const kid of kids.flat()) if (kid != null) el.append(kid);
    return el;
  }
  function h(tag, props, ...kids) {
    const el = document.createElement(tag);
    for (const [k, v] of Object.entries(props || {})) {
      if (v == null || v === false) continue;
      if (k === "class") el.className = v; else if (k === "text") el.textContent = v; else el.setAttribute(k, v === true ? "" : v);
    }
    for (const kid of kids.flat()) if (kid != null && kid !== false) el.append(kid);
    return el;
  }

  /* ---------- the one tooltip ---------- */
  let tip = null;
  function showTip(lines, x, y) {
    if (!tip) { tip = h("div", { class: "ctip", role: "tooltip" }); document.body.append(tip); }
    tip.replaceChildren(...lines.map((l, i) => h(i === 0 ? "b" : "span", { text: l })));
    tip.hidden = false;
    const w = tip.offsetWidth, ht = tip.offsetHeight;
    const left = Math.min(Math.max(8, x - w / 2), window.innerWidth - w - 8);
    const top = y - ht - 12 < 8 ? y + 16 : y - ht - 12;
    tip.style.left = left + "px";
    tip.style.top = top + "px";
  }
  function hideTip() { if (tip) tip.hidden = true; }
  window.addEventListener("scroll", hideTip, { passive: true });

  /** A box that draws its chart at its own width, again when that changes. */
  function responsive(cls, draw) {
    const box = h("div", { class: "chart " + (cls || "") });
    let last = 0;
    const paint = () => { const w = Math.round(box.clientWidth); if (w > 0 && w !== last) { last = w; box.replaceChildren(draw(w)); } };
    let queued = false;
    new ResizeObserver(() => { if (!queued) { queued = true; requestAnimationFrame(() => { queued = false; paint(); }); } }).observe(box);   // draw next frame, not inside the callback
    return box;
  }

  function ticks(max, n = 4) { return Array.from({ length: n + 1 }, (_, i) => (max * i) / n); }
  function niceMax(v, pct) {
    if (pct) return 1;
    if (!(v > 0)) return 1;
    const step = Math.pow(10, Math.floor(Math.log10(v)));
    for (const m of [1, 2, 2.5, 5, 10]) if (m * step >= v) return m * step;
    return 10 * step;
  }

  /** Bars with a rounded data end (4px), anchored square to the baseline. */
  function barPath(x, y, w, h0, base) {
    const r = Math.min(4, w / 2, h0);
    if (h0 <= 0) return "";
    return `M${x},${base} V${y + r} Q${x},${y} ${x + r},${y} H${x + w - r} Q${x + w},${y} ${x + w},${y + r} V${base} Z`;
  }

  /**
   * A line over time: dots for each point and a line for its moving average.
   * points: [{ value, label (short, for the axis), tip: [lines] }]; avg: values for the line.
   */
  function line({ points, avg, format, pct = true, ref = null, height = 220, label, dotName = "Each match", lineName = "Average" }) {
    const box = responsive("line", (W) => {
      const L = 44, R = 12, T = 12, B = 28, H = height;
      const max = niceMax(Math.max(...points.map((p) => p.value || 0), ...(avg || []).map((v) => v || 0)), pct);
      const n = points.length;
      const X = (i) => L + (n === 1 ? (W - L - R) / 2 : (i * (W - L - R)) / (n - 1));
      const Y = (v) => T + (1 - v / max) * (H - T - B);
      const svg = s("svg", { width: W, height: H, viewBox: `0 0 ${W} ${H}`, class: "csvg", role: "img", "aria-label": label, tabindex: "0" });
      for (const t of ticks(max)) {
        svg.append(s("line", { x1: L, x2: W - R, y1: Y(t), y2: Y(t), class: "grid" }));
        svg.append(s("text", { x: L - 8, y: Y(t) + 4, class: "ax", "text-anchor": "end" }, format(t)));
      }
      if (ref != null) svg.append(s("line", { x1: L, x2: W - R, y1: Y(ref), y2: Y(ref), class: "ref" }));
      const every = Math.max(1, Math.ceil(n / Math.max(2, Math.floor((W - L - R) / 70))));
      points.forEach((p, i) => { if (i % every === 0 || i === n - 1) svg.append(s("text", { x: X(i), y: H - 8, class: "ax", "text-anchor": i === 0 && n > 1 ? "start" : i === n - 1 && n > 1 ? "end" : "middle" }, p.label)); });
      const dots = points.map((p, i) => (p.value == null ? null : s("circle", { cx: X(i), cy: Y(p.value), r: 4, class: "dot" })));
      svg.append(...dots.filter(Boolean));
      if (avg) {
        const d = avg.map((v, i) => (v == null ? "" : `${i && avg[i - 1] != null ? "L" : "M"}${X(i)},${Y(v)}`)).join("");
        svg.append(s("path", { d, class: "avg" }));
      }
      const cross = s("line", { y1: T, y2: H - B, class: "cross", visibility: "hidden" });
      const ring = s("circle", { r: 6, class: "ring", visibility: "hidden" });
      svg.append(cross, ring);
      let cur = -1;
      const at = (i) => {
        cur = i;
        const p = points[i];
        cross.setAttribute("x1", X(i)); cross.setAttribute("x2", X(i)); cross.setAttribute("visibility", "visible");
        if (p.value != null) { ring.setAttribute("cx", X(i)); ring.setAttribute("cy", Y(p.value)); ring.setAttribute("visibility", "visible"); } else ring.setAttribute("visibility", "hidden");
        const r = svg.getBoundingClientRect();
        showTip([...p.tip, ...(avg && avg[i] != null ? [lineName + ": " + format(avg[i])] : [])], r.left + X(i), r.top + (p.value != null ? Y(p.value) : T));
      };
      const off = () => { cur = -1; cross.setAttribute("visibility", "hidden"); ring.setAttribute("visibility", "hidden"); hideTip(); };
      svg.addEventListener("pointermove", (e) => {
        const r = svg.getBoundingClientRect();
        const i = n === 1 ? 0 : Math.round(((e.clientX - r.left - L) / (W - L - R)) * (n - 1));
        at(Math.max(0, Math.min(n - 1, i)));
      });
      svg.addEventListener("pointerleave", off);
      svg.addEventListener("blur", off);
      svg.addEventListener("keydown", (e) => {
        if (e.key === "ArrowRight" || e.key === "ArrowLeft") { e.preventDefault(); at(Math.max(0, Math.min(n - 1, cur < 0 ? n - 1 : cur + (e.key === "ArrowRight" ? 1 : -1)))); }
        if (e.key === "Escape") off();
      });
      return svg;
    });
    const legend = h("div", { class: "clegend" }, h("span", {}, h("i", { class: "k-dot" }), dotName), avg ? h("span", {}, h("i", { class: "k-line" }), lineName) : null);
    return h("div", { class: "cwrap" }, legend, box);
  }

  /**
   * Vertical bars, one group per category. series: [{ name, cls: "s1" | "s2", values }]. One series: no legend.
   * tips(i) returns the tooltip lines for category i.
   */
  function bars({ cats, series, format, pct = false, integer = false, height = 200, label, tips }) {
    const box = responsive("bars", (W) => {
      const L = 44, R = 8, T = 12, B = 30, H = height;
      const top = Math.max(...series.flatMap((x) => x.values.map((v) => v || 0)));
      const max = integer ? 4 * niceMax(Math.max(1, top / 4)) : niceMax(top, pct);   // whole-number counts get whole-number gridlines
      const Y = (v) => T + (1 - v / max) * (H - T - B);
      const base = Y(0);
      const slot = (W - L - R) / cats.length;
      const gap = 2, inner = Math.min(slot * 0.7, 28 * series.length + gap * (series.length - 1));
      const bw = (inner - gap * (series.length - 1)) / series.length;
      const svg = s("svg", { width: W, height: H, viewBox: `0 0 ${W} ${H}`, class: "csvg", role: "img", "aria-label": label });
      for (const t of ticks(max)) {
        svg.append(s("line", { x1: L, x2: W - R, y1: Y(t), y2: Y(t), class: "grid" }));
        svg.append(s("text", { x: L - 8, y: Y(t) + 4, class: "ax", "text-anchor": "end" }, format(t)));
      }
      const small = slot < 58;
      cats.forEach((c, i) => {
        const x0 = L + i * slot + (slot - inner) / 2;
        series.forEach((ser, j) => {
          const v = ser.values[i] || 0;
          svg.append(s("path", { d: barPath(x0 + j * (bw + gap), Y(v), bw, base - Y(v), base), class: "bar " + ser.cls }));
        });
        const lab = small && c.length > 6 ? c.split(/[–\s]/)[0] : c;
        svg.append(s("text", { x: L + i * slot + slot / 2, y: H - 10, class: "ax", "text-anchor": "middle" }, lab));
        const hit = s("rect", { x: L + i * slot, y: T, width: slot, height: H - T - B + 20, class: "hit", tabindex: "0", role: "button", "aria-label": (tips ? tips(i) : [c]).join(", ") });
        const on = () => { const r = hit.getBoundingClientRect(); hit.classList.add("on"); showTip(tips ? tips(i) : [c, ...series.map((x) => x.name + ": " + format(x.values[i] || 0))], r.left + r.width / 2, r.top + (Y(Math.max(...series.map((x) => x.values[i] || 0))) - T)); };
        const off = () => { hit.classList.remove("on"); hideTip(); };
        hit.addEventListener("pointerenter", on); hit.addEventListener("pointerleave", off);
        hit.addEventListener("focus", on); hit.addEventListener("blur", off);
        svg.append(hit);
      });
      return svg;
    });
    const legend = series.length > 1 ? h("div", { class: "clegend" }, ...series.map((x) => h("span", {}, h("i", { class: "k-sq " + x.cls }), x.name))) : null;
    return h("div", { class: "cwrap" }, legend, box);
  }

  /**
   * Horizontal bars as HTML rows: label, bar, value. rows: [{ label, value (0..max), text, note, tip: [lines] }].
   * ref: a mark across every track (e.g. 50%).
   */
  function hbars({ rows, max = 1, ref = null, label }) {
    const list = h("div", { class: "hbars", role: "list", "aria-label": label });
    for (const r of rows) {
      const fill = h("i", { class: "s1" });
      fill.style.width = Math.max(0, Math.min(1, (r.value || 0) / max)) * 100 + "%";
      const track = h("span", { class: "track", "aria-hidden": "true" }, fill);
      if (ref != null) { const m = h("b", { class: "refm" }); m.style.left = (ref / max) * 100 + "%"; track.append(m); }
      const row = h("div", { class: "hrow", role: "listitem", tabindex: "0", "aria-label": (r.tip || [r.label, r.text]).join(", ") },
        h("span", { class: "hl", text: r.label }), track, h("span", { class: "hv" }, h("b", { text: r.text }), r.note ? h("small", { text: r.note }) : null));
      const on = () => { const b = track.getBoundingClientRect(); showTip(r.tip || [r.label, r.text], b.left + b.width / 2, b.top); };
      row.addEventListener("pointerenter", on); row.addEventListener("pointerleave", hideTip);
      row.addEventListener("focus", on); row.addEventListener("blur", hideTip);
      list.append(row);
    }
    return list;
  }

  /** The same numbers as a table, folded away under the chart. */
  function tableView(cols, rows) {
    return h("details", { class: "ctable" }, h("summary", { text: "Show as table" }),
      h("div", { class: "tablebox" }, h("table", {}, h("thead", {}, h("tr", {}, ...cols.map((c) => h("th", { text: c })))),
        h("tbody", {}, ...rows.map((r) => h("tr", {}, ...r.map((c) => h("td", { text: String(c) }))))))));
  }

  window.R6C = { line, bars, hbars, tableView };
})();
