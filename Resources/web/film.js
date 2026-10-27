/* DeskPet desktop film: the character (pet.js) full-screen as a live wallpaper, shot like a film. The native shell
   (DesktopFilm.swift) loads this page into a window below the desktop icons and calls window.film:
     init(cfg)          the character, as for pet.init
     setLayout(l)       menu bar and Dock insets { top, bottom, left, right, menuBarDark } and what lies above the
                        film: widgets [{ x, y, w, h, owner, name }], other windows [[x, y, w, h]], desktop icons
                        [{ x, y, w, h, name }] (their pictures), iconColumn (icons whose places are unknown)
     setLive(on, o)     the desktop came into view (play, with a long or short opening) or was covered (freeze)
     pointer(x, y, in)  the pointer, for the gaze and the parallax
     click(x, y)        a click on the desktop; returns "head", "body", "bubble" or null
     glance(x, y)       look at a point for a few seconds, whatever the pointer does
     visit(o)           go to the icon of a file just put on the desktop ({ name, arrived })
   and passes on pet.js calls (say, play, setSleeping, …) while the pet is in the film. */
(function () {
  "use strict";

  const root = document.documentElement;
  const $ = (id) => document.getElementById(id);
  const native = (type, payload) => {
    try { window.webkit.messageHandlers.pet.postMessage(Object.assign({ type }, payload || {})); } catch (_) {}
  };
  const pet = window.pet;

  const camera = $("camera"), bump = $("bump"), actor = $("actor"), frame = $("frame");
  const card = $("card"), cardInner = card.querySelector(".inner"), curtain = $("curtain");
  const grain = $("grain"), flicker = $("flicker"), scratches = $("scratches");
  const dust = $("dust"), stars = $("stars"), bokeh = $("bokeh"), beams = $("beams"), ripples = $("ripples");

  const FPS = 24;               // the film's frame rate: grain, gate weave, flicker and dust
  // What the native shell tells about the screen (film.setLayout); the same fields before it first does.
  const NO_INSETS = { top: 0, bottom: 0, left: 0, right: 0, widgets: [], windows: [], icons: [], iconColumn: false };
  let insets = Object.assign({}, NO_INSETS);
  let geo = null;               // layout in CSS pixels (see layout)
  let started = false;          // the character is loaded
  let live = false;
  let sleeping = false;
  let opening = false;
  let shot = "wide";
  let hold = 0;                 // until when an interaction holds the camera (performance.now())
  let holdToken = 0;
  let nextCut = 0;
  let dwellSince = 0, attending = false;
  let lastKick = 0;

  const openingTimers = new Set();
  function cue(ms, fn) {
    const t = setTimeout(() => { openingTimers.delete(t); fn(); }, ms);
    openingTimers.add(t);
  }

  // ---------------------------------------------------------------- time of day

  let tod = "";
  let lightRGB = [255, 242, 214];
  function applyTimeOfDay() {
    const h = new Date().getHours();
    const forced = new URLSearchParams(location.search).get("tod");
    // The same hours as the act titles (DesktopView.chapter): dawn 5–8, dusk 17–19.
    const t = forced || (h >= 5 && h < 8 ? "dawn" : h >= 8 && h < 17 ? "day" : h >= 17 && h < 19 ? "dusk" : "night");
    if (t === tod) return;
    if (tod) root.classList.remove("tod-" + tod);
    root.classList.remove("tod-day");
    tod = t;
    root.classList.add("tod-" + t);
    lightRGB = getComputedStyle(root).getPropertyValue("--light").split(",").map((v) => parseInt(v, 10) || 255);
  }

  // ---------------------------------------------------------------- layout
  // The picture fills the screen. The floor reaches from a little below the middle to the bottom; the character
  // stands on it where nothing drawn above the film hides it (the desktop widgets, the desktop icons and other apps'
  // windows, passed in by the native shell, and the menu bar), the further back the smaller. Its subtitles run
  // under it at the foot of the picture, the chat box below them. On a visit (see visits) it stands elsewhere for
  // a while: on an icon, or behind a widget.

  let blocks = [];              // [left, top, right, bottom, thing] of everything above the film that would hide the character
  let home = null;              // { x, feet, size }: the character's place on the floor

  /** Share of the box [l, r] × [t, b] that something above the film hides (leaving `except` out). */
  function hidden(l, t, r, b, except) {
    let area = 0;
    for (const [bl, bt, br, bb, thing] of blocks) {
      if (except && thing === except) continue;
      area += Math.max(0, Math.min(r, br) - Math.max(l, bl)) * Math.max(0, Math.min(b, bb) - Math.max(t, bt));
    }
    return area / Math.max(1, (r - l) * (b - t));
  }

  /** The character's body [l, t, r, b] at x, feet at `feet`, at `size` times its full height (the stage is wider). */
  function body(x, feet, size, stageW, stageH) {
    const half = stageW * size * 0.36;
    return [x - half, feet - stageH * size * 0.92, x + half, feet + stageH * size * 0.04];
  }

  /** Where the character stands on the floor: where it stands now while that stays in view, otherwise the spot
      least hidden, preferring it at full size, at the front, and middle left (the sun on its other side). Where the
      room is short it stands further back on the floor (up to its far edge, `back`), or smaller, down to 46%. */
  function choosePlace(W, stageW, stageH, front, back, fresh) {
    const g = geo, h = home;
    if (!fresh && g && h && g.stageH === stageH && g.front === front && hidden(...body(h.x, h.feet, h.size, stageW, stageH)) < 0.004) {
      return h;
    }
    const prefer = W * 0.42;
    let best = null;
    for (const size of [1, 0.86, 0.72, 0.58, 0.46]) {
      const half = stageW * size * 0.36;
      for (let d = 0; d <= 1.001; d += 0.2) {
        const feet = front - (front - back) * d;
        for (let x = half + 10; x <= W - half - 10; x += 8) {
          const cost = hidden(...body(x, feet, size, stageW, stageH)) * 40 + (1 - size) * 4 + d * 0.3 + Math.abs(x - prefer) / W;
          if (!best || cost < best.cost) best = { x, feet, size, cost };
        }
      }
    }
    return { x: Math.round(best.x), feet: Math.round(best.feet), size: best.size };
  }

  /** Free horizontal room around `x` in the band [t, b], up to the nearest things above the film. */
  function room(W, x, t, b) {
    let l = 0, r = W;
    for (const [bl, bt, br, bb] of blocks) {
      if (bt >= b || bb <= t) continue;
      if (br <= x) l = Math.max(l, br); else if (bl >= x) r = Math.min(r, bl);
    }
    return Math.max(160, 2 * Math.min(x - l, r - x) - 24);
  }

  /** o.fresh: choose the place anew (a new showing); o.ms: move the camera there over this long. */
  function layout(o) {
    o = o || {};
    const W = innerWidth, H = innerHeight;
    const resized = !geo || geo.W !== W || geo.H !== H;
    const stageH = Math.round(H * 0.5), stageW = Math.round(stageH * 320 / 340);
    const subSize = Math.round(Math.max(17, Math.min(30, H * 0.025)));
    // From the bottom up: the Dock, the chat box (a click on the body opens it), two lines of subtitles, the feet.
    const chatY = Math.round(H - insets.bottom - 34);
    const subBottom = Math.round(insets.bottom + 68);
    const front = Math.round(H - subBottom - subSize * 2.9 - 6);
    const horizonY = Math.round(H * 0.6);
    const m = 8;
    blocks = [];
    for (const wg of insets.widgets) blocks.push([wg.x - m, wg.y - m, wg.x + wg.w + m, wg.y + wg.h + m, wg]);
    for (const [x, y, w, h] of insets.windows) blocks.push([x - m, y - m, x + w + m, y + h + m, null]);
    // An icon with its name below it.
    for (const ic of insets.icons) blocks.push([ic.x - ic.w * 0.3, ic.y - 4, ic.x + ic.w * 1.3, ic.y + ic.h + 34, ic]);
    if (insets.top) blocks.push([0, 0, W, insets.top + 4, null]);
    // Desktop icons whose places are unknown: along the right edge, where Finder puts them first.
    if (insets.iconColumn && !insets.icons.length) blocks.push([W - Math.min(W * 0.16, 260), 0, W, H, null]);
    home = choosePlace(W, stageW, stageH, front, horizonY + Math.round(H * 0.03), o.fresh);
    const sunFrac = home.x < W / 2 ? 0.7 : 0.28;
    geo = { W, H, stageW, stageH, front, horizonY, subBottom, subSize, chatY, sunFrac,
            floorY: home.feet, size: home.size, charX: home.x, charH: Math.round(stageH * home.size), charW: Math.round(stageW * home.size) };
    const vars = {
      "--menubar-h": insets.top + "px", "--dock-h": insets.bottom + "px", "--horizon-y": horizonY + "px",
      "--stage-w": stageW + "px", "--stage-h": stageH + "px", "--sub-size": subSize + "px", "--sub-bottom": subBottom + "px",
      // The sun on the far side of the character, so that its light falls across it.
      "--sun-x": Math.round(sunFrac * W) + "px", "--sun-y": Math.round(H * 0.2) + "px", "--dir": sunFrac > 0.5 ? "1" : "-1",
    };
    for (const [k, v] of Object.entries(vars)) root.style.setProperty(k, v);
    // On a visit the character stays there while the place still works; otherwise it goes home.
    const away = visit && visitPlace(visit);
    if (visit && !away) endVisit(false);
    if (!leaping) show(away || home);
    drawCasts();
    if (resized) {
      drawStars();
      placeBokeh();
      dust.width = Math.round(W / 2);
      dust.height = Math.round(H / 2);
    }
    if (!opening) applyShot(shot, o.ms || 0);
  }

  /** Puts the character at `p` ({ x, feet, size }), with its subtitles below it. */
  function show(p) {
    const g = geo;
    Object.assign(g, { charX: p.x, floorY: p.feet, size: p.size, charH: Math.round(g.stageH * p.size), charW: Math.round(g.stageW * p.size) });
    const subW = Math.round(Math.min(g.W * 0.66, 980, room(g.W, p.x, g.H - g.subBottom - g.subSize * 3, g.H - g.subBottom)));
    const subX = Math.round(Math.min(Math.max(p.x, subW / 2 + 8), g.W - subW / 2 - 8));
    const vars = {
      "--depth": String(p.size), "--floor-y": p.feet + "px", "--char-h": g.charH + "px", "--char-w": g.charW + "px",
      "--char-x": p.x + "px", "--sub-w": subW + "px", "--sub-x": subX + "px",
    };
    for (const [k, v] of Object.entries(vars)) root.style.setProperty(k, v);
    native("subtitles", { x: subX, y: g.chatY });
  }

  function drawStars() {
    stars.width = Math.round(geo.W / 2);
    stars.height = Math.round(geo.H * 0.35);
    const c = stars.getContext("2d");
    c.clearRect(0, 0, stars.width, stars.height);
    for (let i = 0; i < 170; i++) {
      const r = Math.random() < 0.08 ? 1.1 : 0.5 + Math.random() * 0.4;
      c.fillStyle = `rgba(230, 236, 255, ${0.35 + Math.random() * 0.6})`;
      c.beginPath();
      c.arc(Math.random() * stars.width, Math.pow(Math.random(), 1.4) * stars.height, r, 0, Math.PI * 2);
      c.fill();
    }
  }

  function placeBokeh() {
    if (bokeh.childElementCount) return;
    for (let i = 0; i < 16; i++) {
      const b = document.createElement("b");
      const size = (3 + Math.random() * 9) * geo.H / 100;
      Object.assign(b.style, {
        width: size + "px", height: size + "px",
        left: (Math.random() * 100) + "%", top: (8 + Math.pow(Math.random(), 0.8) * 62) + "%",
      });
      b.style.setProperty("--o", (0.16 + Math.random() * 0.34).toFixed(2));
      b.style.setProperty("--d", (30 + Math.random() * 40).toFixed(0) + "s");
      b.style.setProperty("--delay", (-Math.random() * 60).toFixed(0) + "s");
      b.style.setProperty("--dx", ((Math.random() - 0.5) * 140).toFixed(0) + "px");
      b.style.setProperty("--dy", ((Math.random() - 0.5) * 90).toFixed(0) + "px");
      bokeh.appendChild(b);
    }
  }

  // ---------------------------------------------------------------- camera
  // A shot puts a point of the character (`a`: that far up its height) at a height of the screen (`ty`), at a
  // scale, a little towards the middle (`dx`, a share of the screen width); the camera either dollies there (a slow
  // eased move) or cuts (at once, with a flicker). The picture always covers the screen, and the character stays
  // clear of the widgets and windows: where the full scale would take it under one, the shot takes the largest
  // scale and the nearest place that keep it as clear as in the wide shot.
  const SHOTS = {
    medium: { s: 1.34, a: 0.56, ty: 0.54, dx: 0.03 },
    close: { s: 1.8, a: 0.7, ty: 0.4, dx: 0.02 },
    side: { s: 1.14, a: 0.5, ty: 0.56, dx: 0.12 },
    low: { s: 1.1, a: 0, ty: 0.86, dx: -0.08 },
  };

  function shotTransform(name) {
    const g = geo, spec = SHOTS[name];
    if (!g || !spec) return { s: 1, x: 0, y: 0 };
    const [l, t, r, b] = body(g.charX, g.floorY, g.size, g.stageW, g.stageH);
    const fx = g.charX, fy = g.floorY - g.charH * spec.a, ty = spec.ty * g.H;
    const allowed = hidden(l, t, r, b) + 0.005;
    const prefer = g.charX + spec.dx * g.W * (g.charX < g.W / 2 ? 1 : -1);
    for (let s = spec.s; s >= 1.04; s -= 0.06) {
      const y = Math.min(0, Math.max(g.H - s * g.H, ty - s * fy));
      for (let k = 0; k <= g.W / 6; k++) {
        const tx = prefer + (k % 2 ? 1 : -1) * Math.ceil(k / 2) * 12;
        const x = Math.min(0, Math.max(g.W - s * g.W, tx - s * fx));
        const vl = Math.max(0, s * l + x), vr = Math.min(g.W, s * r + x), vt = Math.max(0, s * t + y), vb = Math.min(g.H, s * b + y);
        if (vr - vl > 40 && vb - vt > 40 && hidden(vl, vt, vr, vb) <= allowed) return { s, x, y };
      }
    }
    return { s: 1, x: 0, y: 0 };
  }

  function applyShot(name, ms, ease) {
    if ((visit || leaping) && name !== "wide") return;
    shot = name;
    const t = shotTransform(name);
    camera.style.transition = ms ? `transform ${ms}ms ${ease || "cubic-bezier(.45, .05, .25, 1)"}` : "none";
    camera.style.transform = `translate(${t.x.toFixed(1)}px, ${t.y.toFixed(1)}px) scale(${t.s})`;
    root.classList.toggle("close-shot", name === "close");
  }

  function cut(name) {
    applyShot(name, 0);
    flicker.style.opacity = "0.5";
  }

  /** An interaction takes the camera for `forMs` (Infinity: until released), then it returns to the wide shot. */
  function holdShot(name, ms, forMs) {
    const token = ++holdToken;
    if (name && name !== shot) applyShot(name, ms);
    hold = performance.now() + forMs;
    if (!isFinite(forMs)) return;
    setTimeout(() => {
      if (token !== holdToken || !live || opening) return;
      applyShot("wide", 3200);
      nextCut = performance.now() + 30000 + Math.random() * 30000;
    }, forMs);
  }

  /** Now and then the director changes the shot while nothing else happens. */
  function direct(now) {
    if (opening || visit || leaping || now < hold || sleeping || now < nextCut) return;
    nextCut = now + 45000 + Math.random() * 50000;
    const choices = ["wide", "wide", "medium", "side", "low"].filter((s) => s !== shot);
    const next = choices[Math.floor(Math.random() * choices.length)];
    if (Math.random() < 0.45) cut(next); else applyShot(next, 7000 + Math.random() * 4000);
  }

  // ---------------------------------------------------------------- visits
  // The desktop icons and widgets are drawn above the film. Now and then the character leaves its place on the
  // floor for one of them: it jumps onto an icon, small enough to sit on it, or steps behind a widget and peeks out
  // past its edge (most of it hidden, the head out). The camera stays on the wide shot meanwhile, so that the
  // character keeps its place against them. On arrival the native shell is told ("visit") and says the remark (it
  // knows what the widgets show); it also sends the character to a new file's icon (film.visit).

  const stageEl = $("stage"), casts = $("casts");
  let visit = null;    // { kind: "icon" | "widget", name, owner, at, place: { x, feet, size, side }, arrived, timers }
  let nextVisit = 0;
  let leaping = false;

  function later(ms, fn) {
    const v = visit;
    const t = setTimeout(() => { if (visit === v) fn(); }, ms);
    if (v) v.timers.push(t);
  }

  /** The icon or widget of a visit as now laid out (it may have moved), or null when it is gone. */
  function visitTarget(v) {
    if (v.kind === "icon") return insets.icons.find((ic) => ic.name === v.name) || null;
    // Widgets go by their owner and name; of several alike, the one nearest to where it was.
    const near = (w) => Math.hypot(w.x - v.at.x, w.y - v.at.y);
    return insets.widgets.filter((w) => w.owner === v.owner && w.name === v.name).sort((a, b) => near(a) - near(b))[0] || null;
  }

  /** On top of an icon: small enough to sit on it, the paws on its picture's visible top. */
  function perchOn(ic) {
    const g = geo;
    for (const size of [0.36, 0.31, 0.26]) {
      const h = g.stageH * size, half = g.stageW * size * 0.36;
      const x = ic.x + ic.w / 2, feet = ic.y + ic.h * 0.1, top = feet - h * 0.92;
      if (top < insets.top + 6 || x - half < 0 || x + half > g.W) continue;
      if (hidden(x - half, top, x + half, feet - 2, ic) < 0.01) return { x: Math.round(x), feet: Math.round(feet), size, side: 0 };
    }
    return null;
  }

  /** Ways to peek from behind a widget, larger first: past its right (side 1) or left (-1) edge with about 45% of
      the body out, standing on the floor or with the feet hidden behind it; or over its top edge (side 0), the
      head out. The part that shows must be clear of everything else. */
  function peekOptions(wg) {
    const g = geo, out = [];
    for (const size of [0.6, 0.5, 0.42]) {
      const h = g.stageH * size, bw = g.stageW * size * 0.72;
      const feet = Math.min(wg.y + wg.h - 8, g.front), top = feet - h * 0.92;
      if (top >= insets.top + 8 && top >= wg.y - h * 0.3 && feet >= wg.y + h * 0.35) {
        for (const side of [1, -1]) {
          const edge = side > 0 ? wg.x + wg.w : wg.x, x = edge - side * bw * 0.05;
          const shows = side > 0 ? [edge, top, x + bw / 2, Math.min(feet, wg.y + wg.h)] : [x - bw / 2, top, edge, Math.min(feet, wg.y + wg.h)];
          if (shows[0] >= 0 && shows[2] <= g.W && hidden(...shows, wg) < 0.01) out.push({ x: Math.round(x), feet: Math.round(feet), size, side });
        }
      }
      const overFeet = wg.y + h * 0.6, overTop = wg.y - h * 0.32, cx = wg.x + wg.w / 2;
      if (overFeet <= wg.y + wg.h - 6 && overTop >= insets.top + 8 && hidden(cx - bw / 2, overTop, cx + bw / 2, wg.y, wg) < 0.01) {
        out.push({ x: Math.round(cx), feet: Math.round(overFeet), size, side: 0 });
      }
    }
    return out;
  }

  /** Where the character stays on visit `v` now: the same way as before where it still works. */
  function visitPlace(v) {
    const t = visitTarget(v);
    if (!t) return null;
    v.at = { x: t.x, y: t.y };
    if (v.kind === "icon") return perchOn(t);
    const options = peekOptions(t), p = v.place;
    return options.find((o) => o.side === p.side && o.size === p.size) || options.find((o) => o.side === p.side) || null;
  }

  /** Starts a visit to an icon or widget if the character has a place there. */
  function startVisit(kind, target, arrived) {
    if (!live || opening || visit || leaping || !geo) return false;
    let place;
    if (kind === "icon") place = perchOn(target);
    else {
      const options = peekOptions(target), largest = options.filter((o) => o.size === (options[0] && options[0].size));
      place = largest[Math.floor(Math.random() * largest.length)];
    }
    if (!place) return false;
    visit = { kind, name: target.name || "", owner: target.owner || "", at: { x: target.x, y: target.y }, place, arrived, timers: [] };
    const go = () => leapTo(place, landed);
    if (shot !== "wide") { applyShot("wide", 700); later(750, go); } else go();
    return true;
  }

  function landed() {
    const v = visit;
    if (!v) return;
    root.classList.add("visiting");
    const tell = () => native("visit", { kind: v.kind, name: v.name, owner: v.owner, arrived: !!v.arrived });
    if (v.kind === "icon") {
      pet.play("sniff");
      later(2400, () => { pet.play("swipe"); tell(); });
      later(9000 + Math.random() * 6000, () => pet.play(Math.random() < 0.5 ? "groom" : "stretch"));
      later(18000 + Math.random() * 12000, () => endVisit(false));
    } else {
      // The paw that shows: the left one past a right edge, the right one past a left edge.
      pet.play("perk");
      later(1800, () => { pet.play(v.place.side > 0 ? "groom" : v.place.side < 0 ? "swipe" : "sniff"); tell(); });
      later(8000 + Math.random() * 4000, () => pet.play("swish"));
      later(15000 + Math.random() * 10000, () => endVisit(false));
    }
  }

  /** Ends a visit: back home with a jump, or at once (`snap`: the film stops). */
  function endVisit(snap) {
    const v = visit;
    if (!v) return;
    v.timers.forEach(clearTimeout);
    visit = null;
    nextVisit = performance.now() + 100000 + Math.random() * 100000;
    if (snap || !live) {
      root.classList.add("snap");
      show(home);
      void actor.offsetWidth;
      root.classList.remove("snap", "visiting");
      return;
    }
    root.classList.remove("visiting");
    leapTo(home);
  }

  /** A jump to `p`: crouch, an arc on the way (higher when jumping up), the size changing in flight, landing. */
  function leapTo(p, done) {
    leaping = true;
    const fromFeet = geo.floorY, fromX = geo.charX;
    pet.hop("crouch");
    setTimeout(() => {
      pet.hop("air");
      const ms = Math.round(750 + Math.min(550, Math.abs(p.feet - fromFeet) * 0.6 + Math.abs(p.x - fromX) * 0.25));
      root.style.setProperty("--move-ms", ms + "ms");
      show(p);
      const lift = 40 + Math.max(0, fromFeet - p.feet) * 0.25;
      stageEl.animate([{ translate: "0 0" }, { translate: `0 ${-lift}px`, offset: 0.45 }, { translate: "0 0" }], { duration: ms, easing: "ease-in-out" });
      setTimeout(() => {
        pet.hop("land");
        root.style.removeProperty("--move-ms");
        leaping = false;
        if (done) done();
      }, ms);
    }, 170);
  }

  /** Now and then, while nothing else happens: a visit to a random icon or widget that has a place for it. */
  function considerVisit(now) {
    if (visit || leaping || opening || sleeping || now < nextVisit || now < hold) return;
    nextVisit = now + 100000 + Math.random() * 100000;
    const targets = insets.icons.map((t) => ["icon", t]).concat(insets.widgets.map((t) => ["widget", t]));
    for (let i = targets.length - 1; i > 0; i--) {
      const j = Math.floor(Math.random() * (i + 1));
      [targets[i], targets[j]] = [targets[j], targets[i]];
    }
    targets.some(([kind, t]) => startVisit(kind, t, false));
  }

  /** The native shell's request: to the icon of a file just put on the desktop. Where there is no place to sit
      (or a visit is going on), the character looks at it from where it is and remarks on it all the same. */
  function visitIcon(o) {
    const ic = insets.icons.find((i) => i.name === o.name);
    if (ic && startVisit("icon", ic, !!o.arrived)) return true;
    if (ic) glance(ic.x + ic.w / 2, ic.y + ic.h / 2);
    pet.play("perk");
    native("visit", { kind: "icon", name: o.name, owner: "", arrived: !!o.arrived });
    return false;
  }

  /** Shadows of the widgets and icons on the set, cast away from the sun (at night their light instead), so that
      they seem to stand in the picture. */
  function drawCasts() {
    const g = geo, sunX = g.sunFrac * g.W;
    const one = (r, radius, blur) => {
      const dx = Math.max(-1, Math.min(1, (r.x + r.w / 2 - sunX) / g.W * 2)) * 18;
      return `<i style="left:${r.x}px;top:${r.y}px;width:${r.w}px;height:${r.h}px;--dx:${dx.toFixed(1)}px;--r:${radius}px;--blur:${blur}px"></i>`;
    };
    casts.innerHTML = insets.widgets.map((w) => one(w, 22, 16)).join("") + insets.icons.map((ic) => one(ic, 12, 9)).join("");
  }

  // ---------------------------------------------------------------- film stock

  const tiles = [];
  function makeGrain() {
    const c = document.createElement("canvas");
    c.width = c.height = 180;
    const x = c.getContext("2d");
    for (let k = 0; k < 6; k++) {
      const img = x.createImageData(180, 180), d = img.data;
      for (let i = 0; i < d.length; i += 4) {
        const v = 128 + (Math.random() - 0.5) * 160;
        d[i] = d[i + 1] = d[i + 2] = v;
        d[i + 3] = 255;
      }
      x.putImageData(img, 0, 0);
      tiles.push(`url(${c.toDataURL()})`);
    }
    grain.style.backgroundImage = tiles[0];
  }

  let motes = [];
  function mote(anywhere) {
    return { x: Math.random(), y: anywhere ? Math.random() : 1.04, r: 0.5 + Math.random() * 1.6,
             vx: (Math.random() - 0.5) * 0.0005, vy: -(0.00015 + Math.random() * 0.0005), ph: Math.random() * 6.28,
             a: 0.2 + Math.random() * 0.5 };
  }

  /** Dust floating in the light, brighter where the beams fall (towards the sun's side). */
  function drawDust(t) {
    if (!motes.length) motes = Array.from({ length: 80 }, () => mote(true));
    const c = dust.getContext("2d"), w = dust.width, h = dust.height;
    c.clearRect(0, 0, w, h);
    const [r, g, b] = lightRGB;
    for (const m of motes) {
      m.x += m.vx + Math.sin(t / 1700 + m.ph) * 0.0002;
      m.y += m.vy;
      if (m.y < -0.04 || m.x < -0.04 || m.x > 1.04) Object.assign(m, mote(false));
      const dir = geo.sunFrac > 0.5 ? 1 : -1;
      const inLight = 0.45 + 0.55 * Math.max(0, 1 - Math.abs(m.x - (geo.sunFrac - (m.y - 0.1) * 0.55 * dir)) * 3);
      c.fillStyle = `rgba(${r},${g},${b},${(m.a * inLight * (0.65 + 0.35 * Math.sin(t / 800 + m.ph))).toFixed(3)})`;
      c.beginPath();
      c.arc(m.x * w, m.y * h, m.r, 0, Math.PI * 2);
      c.fill();
    }
  }

  function scratch() {
    if (Math.random() < 0.7) {
      const i = document.createElement("i");
      if (Math.random() < 0.3) i.className = "dark";
      i.style.left = (Math.random() * 100).toFixed(2) + "%";
      i.style.top = (Math.random() * 30).toFixed(1) + "%";
      i.style.height = (40 + Math.random() * 60).toFixed(1) + "%";
      scratches.appendChild(i);
      setTimeout(() => i.remove(), 60 + Math.random() * 120);
    }
    for (let k = Math.floor(Math.random() * 3); k > 0; k--) {
      const s = document.createElement("s");
      const size = 2 + Math.random() * 4;
      Object.assign(s.style, { left: Math.random() * 100 + "%", top: Math.random() * 100 + "%", width: size + "px", height: size * (0.6 + Math.random()) + "px" });
      scratches.appendChild(s);
      setTimeout(() => s.remove(), 1000 / FPS + 4);
    }
  }

  // The paws on the floor: models leave a transparent margin below the feet (see pet.js's measureFeet), so the
  // stage is lowered by it, and the reflection raised by twice as much to meet the paws.
  const feetProbe = document.createElement("canvas");
  const feetCtx = feetProbe.getContext("2d", { willReadFrequently: true });
  let feetGap = 0;
  function measureFeet() {
    const drawn = root.classList.contains("figure-on") ? $("figure") : $("live2d");
    if (!drawn.offsetWidth || !drawn.offsetHeight) return;
    const w = 96, h = Math.max(1, Math.round(w * drawn.offsetHeight / drawn.offsetWidth));
    feetProbe.width = w;
    feetProbe.height = h;
    try { feetCtx.drawImage(drawn, 0, 0, w, h); } catch (_) { return; }
    const data = feetCtx.getImageData(0, 0, w, h).data;
    let row = -1;
    for (let y = h - 1; y >= 0 && row < 0; y--) {
      for (let x = 0; x < w; x++) if (data[(y * w + x) * 4 + 3] > 40) { row = y; break; }
    }
    if (row < 0) return;
    const gap = Math.round((h - 1 - row) / h * drawn.offsetHeight);
    if (Math.abs(gap - feetGap) < 3) return;
    feetGap = gap;
    root.style.setProperty("--feet-gap", gap + "px");
    actor.style.webkitBoxReflect = `below ${-2 * gap}px linear-gradient(transparent 72%, rgba(255, 255, 255, 0.16))`;
  }

  let frameNo = 0, loop = null, scratchTimer = null;

  function tick() {
    const now = performance.now();
    frameNo++;
    grain.style.backgroundImage = tiles[frameNo % tiles.length];
    grain.style.backgroundPosition = `${Math.floor(Math.random() * 180)}px ${Math.floor(Math.random() * 180)}px`;
    const fl = parseFloat(flicker.style.opacity) || 0;
    flicker.style.opacity = fl > 0.06 ? (fl * 0.55).toFixed(3) : (Math.random() * 0.028).toFixed(3);
    // Gate weave, on the picture inside the frame (the set reaches past the screen's edges, so none show).
    if (frameNo % 2 === 0) bump.style.translate = `${((Math.random() - 0.5) * 0.7).toFixed(2)}px ${((Math.random() - 0.5) * 0.9).toFixed(2)}px`;
    drawDust(now);
    direct(now);
    if (frameNo % (FPS * 3) === 0) measureFeet();
    considerVisit(now);
  }

  function startLoops() {
    if (loop) return;
    loop = setInterval(tick, 1000 / FPS);
    const next = () => { scratchTimer = setTimeout(() => { scratch(); next(); }, 2500 + Math.random() * 6500); };
    next();
  }

  function stopLoops() {
    clearInterval(loop);
    clearTimeout(scratchTimer);
    loop = scratchTimer = null;
    flicker.style.opacity = "0";
  }

  // ---------------------------------------------------------------- showings

  const esc = (t) => String(t == null ? "" : t).replace(/[&<>"]/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;" })[c]);

  function showCard(html) {
    cardInner.innerHTML = html;
    void card.offsetWidth;
    card.classList.add("on");
  }

  /** After a long time without the film: the picture fades in from black on a close-up, and the camera pulls back. */
  function longOpening() {
    opening = true;
    curtain.style.setProperty("--curtain-ms", "0ms");
    curtain.classList.add("shut");
    applyShot("close", 0);
    cue(200, () => {
      curtain.style.setProperty("--curtain-ms", "1400ms");
      curtain.classList.remove("shut");
      applyShot("wide", 5200, "cubic-bezier(.3, .1, .2, 1)");
    });
    cue(3400, () => finishOpening(true));
  }

  /** Shortly after the last showing: the projector starts and the camera settles from a closer shot. */
  function shortOpening() {
    opening = true;
    applyShot("medium", 0);
    flicker.style.opacity = "0.45";
    cue(60, () => applyShot("wide", 2600));
    cue(1100, () => finishOpening(false));
  }

  function finishOpening(long) {
    opening = false;
    nextCut = performance.now() + 35000 + Math.random() * 30000;
    native("opened", { long });
  }

  /** Ends an opening at once, everything in its place (the desktop was covered again meanwhile). */
  function cancelOpening() {
    openingTimers.forEach(clearTimeout);
    openingTimers.clear();
    if (!opening) return;
    opening = false;
    curtain.style.setProperty("--curtain-ms", "0ms");
    curtain.classList.remove("shut");
    applyShot("wide", 0);
  }

  function setLive(on, o) {
    o = o || {};
    on = !!on;
    if (on === live) return;
    live = on;
    if (on) {
      // The pet steps into the picture: a place chosen anew for this showing, taken at once.
      root.classList.add("snap");
      layout({ fresh: true });
      void actor.offsetWidth;
      root.classList.remove("paused", "offstage", "snap");
      pet.setPaused(false);
      startLoops();
      nextVisit = performance.now() + 25000 + Math.random() * 25000;
      if (o.long) longOpening(); else shortOpening();
    } else {
      cancelOpening();
      endVisit(true);
      holdToken++;
      hold = 0;
      attending = false;
      dwellSince = 0;
      stopLoops();
      // The pet steps back out to its own window; the still picture stays as the wallpaper.
      root.classList.add("paused", "offstage");
      pet.setPaused(true);
    }
  }

  // ---------------------------------------------------------------- interaction

  let glanceUntil = 0;

  function glance(x, y) {
    if (!started || !live) return;
    glanceUntil = performance.now() + 3500;
    pet.lookAt(x, y);
  }

  function pointer(x, y, inside) {
    if (!started || !geo) return;
    root.style.setProperty("--px", (x / geo.W - 0.5).toFixed(3));
    root.style.setProperty("--py", (y / geo.H - 0.5).toFixed(3));
    if (performance.now() >= glanceUntil) pet.lookAt(x, y);
    if (!live || opening) return;
    // Resting the pointer on the character brings the camera closer; moving away lets it go back.
    const r = actor.getBoundingClientRect();
    const on = inside && x > r.left + r.width * 0.22 && x < r.right - r.width * 0.22 && y > r.top + r.height * 0.12 && y < r.bottom;
    const now = performance.now();
    if (on) {
      if (!dwellSince) dwellSince = now;
      if (!attending && now - dwellSince > 1600 && now > hold) {
        attending = true;
        holdShot("medium", 2400, Infinity);
      }
    } else {
      dwellSince = 0;
      if (attending) {
        attending = false;
        holdShot(null, 0, 2500);
      }
    }
  }

  function ripple(x, y) {
    for (let i = 0; i < 2; i++) {
      const s = document.createElement("span");
      s.style.left = x + "px";
      s.style.top = y + "px";
      ripples.appendChild(s);
      setTimeout(() => s.remove(), 1700);
    }
  }

  function click(x, y) {
    if (!started || !live) return null;
    const area = pet.hitArea(x, y);
    attending = false;
    if (area === "head") holdShot("close", 1500, 4500);
    else if (area === "body") holdShot("medium", 1800, 8000);
    else if (!area) ripple(x, y);
    return area;
  }

  // pet.js calls passed on by the native shell, with the film's own touches.
  const baseSay = pet.say, baseBeat = pet.beat, baseGrooving = pet.setGrooving, baseSleeping = pet.setSleeping;

  /** A reminder first appears as a silent-film intertitle, then as a subtitle. */
  pet.say = function (text, opts) {
    if (live && !opening && opts && opts.kind === "reminder") {
      showCard(`<div class="intertitle">${esc(text)}</div>`);
      setTimeout(() => card.classList.remove("on"), 2800);
      setTimeout(() => baseSay(text, opts), 2900);
      return;
    }
    baseSay(text, opts);
  };

  /** Music turns the film into a music video: light pulses, and the camera kicks on strong beats. */
  pet.setGrooving = function (on) {
    root.classList.toggle("mv", !!on);
    baseGrooving(on);
  };

  pet.beat = function (strength) {
    baseBeat(strength);
    if (!live || opening) return;
    const now = performance.now();
    if ((strength || 0) > 0.55 && now - lastKick > 380 && !sleeping && !visit) {
      lastKick = now;
      bump.classList.remove("kick");
      void bump.offsetWidth;
      bump.classList.add("kick");
    }
    bokeh.classList.add("flash");
    beams.classList.add("flash");
    setTimeout(() => { bokeh.classList.remove("flash"); beams.classList.remove("flash"); }, 110);
  };

  /** Asleep, the picture dims and the camera creeps up to the sleeping face. */
  pet.setSleeping = function (on) {
    sleeping = !!on;
    root.classList.toggle("sleeping", sleeping);
    baseSleeping(on);
    if (!live || opening) return;
    if (sleeping && visit) endVisit(false);  // home to sleep
    if (sleeping) holdShot("close", 14000, Infinity);
    else { holdToken++; hold = 0; applyShot("wide", 3000); }
  };

  // ---------------------------------------------------------------- API for the native shell

  async function init(cfg) {
    applyTimeOfDay();
    if (!tiles.length) makeGrain();
    layout();
    root.classList.add("paused", "offstage");
    const mode = await pet.init(cfg || {});
    started = true;
    // Still frame: let the character settle into its pose, then stop drawing until the desktop is in view.
    setTimeout(measureFeet, 700);
    setTimeout(() => { if (!live) { measureFeet(); pet.setPaused(true); } }, 1500);
    return mode;
  }

  window.addEventListener("resize", layout);
  setInterval(applyTimeOfDay, 60000);

  window.film = {
    init,
    setLive,
    setLayout(l) {
      insets = Object.assign({}, NO_INSETS, l || {});
      root.classList.toggle("menubar-light", insets.menuBarDark === false);
      // While it plays, the character walks off from under a window or widget that arrives.
      if (geo) layout({ ms: live ? 1200 : 0 });
    },
    pointer,
    click,
    glance,
    visit: visitIcon,
  };

  // ---------------------------------------------------------------- standalone preview
  // In a browser (no native shell), served from Resources/: web/film.html?tod=night&short&still&model=<url>
  // &top=33&bottom=0&widgets=x,y,w,h,owner;…&icons=x,y,w,h,name;…&blocks=x,y,w,h;… (other windows)&lightbar;
  // widgets and windows are drawn as grey panels, icons as small tiles.
  // Keys: s say · r reminder · m music · z sleep · p pause/play · c next shot · w a window over the character ·
  // v a visit now · n a new file on the first icon.

  if (!window.webkit || !window.webkit.messageHandlers) {
    const q = new URLSearchParams(location.search);
    const list = (key) => (q.get(key) || "").split(";").filter(Boolean).map((w) => w.split(","));
    const blocks = list("blocks").map((w) => w.map(Number));
    const widgets = list("widgets").map(([x, y, w, h, owner]) => ({ x: +x, y: +y, w: +w, h: +h, owner: owner || "Widget", name: "" }));
    const icons = list("icons").map(([x, y, w, h, name]) => ({ x: +x, y: +y, w: +w, h: +h, name: name || "file" }));
    const outlines = document.createElement("div");
    document.body.appendChild(outlines);
    const panel = (x, y, w, h, r, label) => `<div style="position:fixed;z-index:95;left:${x}px;top:${y}px;width:${w}px;height:${h}px;` +
      `border-radius:${r}px;background:rgba(40,40,48,.78);border:1px solid rgba(255,255,255,.35);pointer-events:none;color:#ddd;` +
      `font:11px -apple-system;display:grid;place-items:center">${label}</div>`;
    const lay = () => {
      window.film.setLayout({ top: +(q.get("top") || 33), bottom: +(q.get("bottom") || 0), menuBarDark: !q.has("lightbar"),
                              widgets, windows: blocks, icons, iconColumn: false });
      outlines.innerHTML = widgets.map((w) => panel(w.x, w.y, w.w, w.h, 20, w.owner)).join("") +
        blocks.map(([x, y, w, h]) => panel(x, y, w, h, 10, "")).join("") + icons.map((i) => panel(i.x, i.y, i.w, i.h, 12, i.name)).join("");
    };
    lay();
    const cfg = q.get("model") ? { model: q.get("model") } : { sprite: q.get("sprite") || "../characters/claude-musume/character.json" };
    init(cfg).then(() => {
      if (!q.has("still")) setLive(true, { long: !q.has("short") });
    });
    addEventListener("mousemove", (e) => pointer(e.clientX, e.clientY, true));
    addEventListener("mousedown", (e) => {
      const area = click(e.clientX, e.clientY);
      if (area === "head") { pet.play("shy"); pet.say("嘿嘿，被摸头了～"); }
      else if (area === "body") pet.say("想和我聊点什么？");
    });
    let music = null;
    addEventListener("keydown", (e) => {
      if (e.key === "s") pet.say(["开拍啦——今天的主角是我！", "你来看我演出啦？", "这一段要不要再来一条？"][Math.floor(Math.random() * 3)]);
      if (e.key === "r") pet.say("该喝水啦，起来活动一下吧～", { kind: "reminder" });
      if (e.key === "m") {
        if (music) { clearInterval(music); music = null; pet.setGrooving(false); }
        else { pet.setGrooving(true); music = setInterval(() => pet.beat(0.4 + Math.random() * 0.6), 520); }
      }
      if (e.key === "z") pet.setSleeping(!sleeping);
      if (e.key === "p") setLive(!live, { long: false });
      if (e.key === "c") cut(["wide", "medium", "close", "side", "low"][Math.floor(Math.random() * 5)]);
      if (e.key === "v") { nextVisit = 0; hold = 0; considerVisit(performance.now()); }
      if (e.key === "n" && icons.length) visitIcon({ name: icons[0].name, arrived: true });
      if (e.key === "w") {
        const r = actor.getBoundingClientRect();
        blocks.push([Math.round(r.left + r.width * 0.2), Math.round(r.top + r.height * 0.3), 420, 300]);
        lay();
      }
    });
  }
})();
