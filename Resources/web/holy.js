/* The white-and-gold wheel behind the message list (rings, ticks, a ring of Greek letters, a hexagram; each layer
   turns at its own pace through CSS) and the two characters in the lower corners: the whale girl (DeepSeek-tan)
   and Claude-chan, who rests her chin on her hand while an answer is being written and blinks now and then. */
(function () {
  "use strict";
  const NS = "http://www.w3.org/2000/svg";
  const GOLD = "201,164,92";
  const svg = document.getElementById("holy");
  svg.setAttribute("viewBox", "-500 -500 1000 1000");

  function el(name, attrs, parent) {
    const e = document.createElementNS(NS, name);
    for (const [k, v] of Object.entries(attrs || {})) e.setAttribute(k, v);
    (parent || svg).appendChild(e);
    return e;
  }
  const group = (cls) => el("g", { class: "spin " + cls });
  const stroke = (a, w) => ({ fill: "none", stroke: `rgba(${GOLD},${Math.min(1, a * 1.35)})`, "stroke-width": w * 1.2 });
  const diamond = (x, y, r, parent, a = 0.85) =>
    el("path", { d: `M${x},${y - r} L${x + r * 0.6},${y} L${x},${y + r} L${x - r * 0.6},${y} Z`, fill: `rgba(${GOLD},${a})` }, parent);

  // Soft light in the middle.
  const defs = el("defs");
  const glow = el("radialGradient", { id: "holyGlow" }, defs);
  el("stop", { offset: "0", "stop-color": "#FFFFFF", "stop-opacity": "0.85" }, glow);
  el("stop", { offset: "1", "stop-color": "#FFFFFF", "stop-opacity": "0" }, glow);
  el("circle", { r: 260, fill: "url(#holyGlow)" });

  // Outer ring with fine ticks (slowest).
  const outer = group("cw-slow");
  el("circle", Object.assign({ r: 472 }, stroke(0.32, 1)), outer);
  el("circle", Object.assign({ r: 458 }, stroke(0.22, 0.8)), outer);
  for (let i = 0; i < 180; i++) {
    const a = i / 180 * Math.PI * 2, r1 = 444, r2 = i % 15 === 0 ? 470 : i % 5 === 0 ? 456 : 450;
    el("line", Object.assign({ x1: Math.cos(a) * r1, y1: Math.sin(a) * r1, x2: Math.cos(a) * r2, y2: Math.sin(a) * r2 },
                             stroke(i % 15 === 0 ? 0.55 : 0.3, 1)), outer);
  }
  for (let i = 0; i < 4; i++) { const a = i * Math.PI / 2; diamond(Math.cos(a) * 486, Math.sin(a) * 486, 9, outer); }

  // Ring of Greek letters (counter-clockwise).
  const runes = group("ccw");
  el("circle", Object.assign({ r: 412 }, stroke(0.25, 0.8)), runes);
  el("circle", Object.assign({ r: 378 }, stroke(0.25, 0.8)), runes);
  const GREEK = "ΑΒΓΔΕΖΗΘΙΚΛΜΝΞΟΠΡΣΤΥΦΧΨΩ";
  for (let i = 0; i < 72; i++) {
    const deg = i / 72 * 360;
    const t = el("text", { x: 0, y: -389, transform: `rotate(${deg})`, "text-anchor": "middle",
                           "font-family": "Times New Roman, serif", "font-size": i % 2 ? 17 : 12,
                           fill: `rgba(122,92,36,${i % 2 ? 0.55 : 0.4})` }, runes);
    t.textContent = i % 2 ? GREEK[(i >> 1) % 24] : "·";
  }

  // Broken arcs (counter-clockwise, faster).
  const arcs = group("ccw-fast");
  el("circle", Object.assign({ r: 340, "stroke-dasharray": "220 90 40 90 140 120", "stroke-linecap": "round" }, stroke(0.6, 1.6)), arcs);
  el("circle", Object.assign({ r: 322, "stroke-dasharray": "3 9" }, stroke(0.35, 1)), arcs);

  // Hexagram with diamonds on its points (clockwise).
  const star = group("cw");
  const R = 292;
  for (const k of [0, 1]) {
    const pts = [0, 1, 2].map((i) => {
      const a = -Math.PI / 2 + k * Math.PI + i * Math.PI * 2 / 3;
      return `${(Math.cos(a) * R).toFixed(1)},${(Math.sin(a) * R).toFixed(1)}`;
    });
    el("polygon", Object.assign({ points: pts.join(" ") }, stroke(0.42, 1.1)), star);
  }
  for (let i = 0; i < 6; i++) { const a = i * Math.PI / 3 - Math.PI / 2; diamond(Math.cos(a) * R, Math.sin(a) * R, 8, star); }
  el("circle", Object.assign({ r: 168 }, stroke(0.45, 1.2)), star);
  el("circle", Object.assign({ r: 150 }, stroke(0.25, 0.8)), star);

  // ---------------------------------------------------------------- characters

  const claudeImg = document.getElementById("claudeImg");
  const base = claudeImg ? claudeImg.getAttribute("src").replace(/[^/]+$/, "") : "";
  let busy = false;
  const pose = () => (busy ? "working-chin" : "idle");
  function blink() {
    if (!claudeImg || claudeImg.hidden) return;
    if (!busy) {
      claudeImg.src = base + "blink.png";
      setTimeout(() => { claudeImg.src = base + pose() + ".png"; }, 140);
    }
    setTimeout(blink, 2500 + Math.random() * 3500);
  }
  if (claudeImg) {
    for (const n of ["idle", "blink", "working-chin", "happy-smile"]) new Image().src = base + n + ".png";  // preload
    setTimeout(blink, 2500);
  }
  // A missing picture (the whale girl is installed separately) simply leaves its corner empty.
  document.querySelectorAll(".mascot img").forEach((img) => {
    img.addEventListener("error", () => { img.closest(".mascot").hidden = true; });
  });

  window.holy = {
    /** Claude-chan thinks while an answer is written, and smiles briefly when it is done. */
    setBusy(on) {
      const was = busy;
      busy = !!on;
      if (!claudeImg) return;
      claudeImg.src = base + (busy ? "working-chin" : was ? "happy-smile" : "idle") + ".png";
      if (was && !busy) setTimeout(() => { if (!busy) claudeImg.src = base + "idle.png"; }, 2500);
    },
  };
})();
