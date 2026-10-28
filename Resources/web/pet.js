/* DeskPet renderer: the Live2D character, speech bubbles, hit testing and the click-through mask
   reported to the native shell. */
(function () {
  "use strict";

  const native = (type, payload) => {
    try { window.webkit.messageHandlers.pet.postMessage(Object.assign({ type }, payload || {})); } catch (_) {}
  };
  const log = (...args) => native("log", { text: args.map(String).join(" ") });
  window.addEventListener("error", (e) => log("JS error:", e.message, e.filename + ":" + e.lineno));

  const root = document.documentElement;
  const canvas = document.getElementById("live2d");
  const stage = document.getElementById("stage");
  const actor = document.getElementById("actor");
  const bubbles = document.getElementById("bubbles");
  const figure = document.getElementById("figure");
  // The desktop film (film.html) shows the same character full-screen below the desktop icons: no click-through
  // mask or feet measurement there (its window takes no clicks), and film.js runs the standalone preview.
  const filmMode = root.classList.contains("film");
  let paused = false;

  // Semantic motions and how long the one-shot ones last (ms); sleepy and think stay until replaced.
  const MOTIONS = ["idle", "happy", "wave", "nod", "shake", "think", "surprised", "sleepy", "shy", "eat", "sad",
                   "swipe", "sniff", "perk", "stretch", "groom", "swish", "grab"];
  const MOTION_MS = { happy: 1800, wave: 2200, nod: 1100, shake: 1100, surprised: 1500, shy: 2600, eat: 4200, sad: 3200 };

  let mode = "none"; // "live2d" once a model is shown
  let l2d = null;   // { app, model, map }
  let motionTimer = null;
  let current = "idle";
  let sleeping = false;
  let talking = false;
  // While the native voice reads a bubble aloud (Speaker.swift), the mouth keeps moving after the typing ends.
  let speaking = false;
  let researchOn = false;
  // Pictures instead of a Live2D model (see figureFrame): a sprite character (one picture per expression) as the
  // everyday character, and the research-mode figure (a single picture) while research mode is on.
  let researchURL = null;
  let sprite = null;       // { base, states, weights, motions, blink, head }
  let spritePick = "idle"; // the picture for the current motion
  let blinkUntil = 0, nextBlink = 0, nextRepick = 0;
  let figureOn = false;
  let figureSrc = "";
  let figureHead = 0.24;   // the top part of the picture that counts as the head
  let figureMotion = { name: "idle", t0: 0 };
  let figureAlpha = null;  // { w, h, data } of the shown picture, for hit testing
  const alphaCache = new Map();
  let lean = 0, leanTarget = 0;

  // ---------------------------------------------------------------- actions
  // Actions the models' own motion files lack (pawing at something, sniffing, stretching, …), played as keyframed
  // parameter tracks over whatever motion runs and faded in and out at their ends. A track names its parameter by
  // the ids it may have (Cubism 2 and Cubism 3 names; parameters a model lacks are left alone) and gives keys
  // [seconds, value], eased in between. An action that moves the forelegs shows the cats' movable foreleg parts
  // (PARTS_01_ARM_*_02, which their own motions switch to; a pose group keeps one of each pair visible). Pictures
  // act the actions with a picture of their own and a tween (figureFrame).

  const P = {
    angleX: ["PARAM_ANGLE_X", "ParamAngleX"], angleY: ["PARAM_ANGLE_Y", "ParamAngleY"], angleZ: ["PARAM_ANGLE_Z", "ParamAngleZ"],
    bodyX: ["PARAM_BODY_ANGLE_X", "ParamBodyAngleX"], bodyY: ["PARAM_BODY_ANGLE_Y", "ParamBodyAngleY"],
    eyeL: ["PARAM_EYE_L_OPEN", "ParamEyeLOpen"], eyeR: ["PARAM_EYE_R_OPEN", "ParamEyeROpen"],
    ballX: ["PARAM_EYE_BALL_X", "ParamEyeBallX"], ballY: ["PARAM_EYE_BALL_Y", "ParamEyeBallY"],
    mouth: ["PARAM_MOUTH_OPEN_Y", "ParamMouthOpenY"], tongue: ["PARAM_TONGUE"],
    earL: ["PARAM_EAR_L"], earR: ["PARAM_EAR_R"], tail: ["PARAM_TAIL"], tailAngry: ["PARAM_TAIL_ANGRY"],
    pawR: ["PARAM_ARM_R_MOVE"], pawL: ["PARAM_ARM_L"], whiskerL: ["PARAM_MUSTACHE_FRONT_L"], whiskerR: ["PARAM_MUSTACHE_FRONT_R"],
  };
  /** Keys that hold `v` from t0 to t1, reached from and returning to `rest` over `ramp` seconds. */
  const hold = (t0, t1, v, rest = 0, ramp = 0.25) => [[t0, rest], [t0 + ramp, v], [t1 - ramp, v], [t1, rest]];
  /** Keys alternating between a and b every `step` seconds from t0 to t1, then back to `rest`. */
  const alternate = (t0, t1, step, a, b, rest = 0) => {
    const keys = [[t0 - step, rest]];
    for (let t = t0, i = 0; t < t1; t += step, i++) keys.push([t, i % 2 ? b : a]);
    keys.push([t1 + step, rest]);
    return keys;
  };

  const FORELEGS = { show: ["PARTS_01_ARM_R_02", "PARTS_01_ARM_L_02"], hide: ["PARTS_01_ARM_R", "PARTS_01_ARM_L"] };
  const ACTIONS = {
    // Eyes on something below, ears forward, a little crouch; the right forepaw up and down on it twice.
    swipe: { s: 1.9, parts: FORELEGS, tracks: [
      [P.angleY, hold(0, 1.9, -12)], [P.ballY, hold(0, 1.9, -0.7)], [P.bodyY, hold(0, 1.9, -12)],
      [P.earL, hold(0, 1.9, 0.8)], [P.earR, hold(0, 1.9, 0.8)], [P.tail, hold(0, 1.9, 0.6, 0, 0.4)],
      [P.pawR, [[0, 0], [0.35, -2.4], [0.55, -0.4], [0.85, -2.3], [1.05, -0.3], [1.5, -0.3], [1.85, 0]]],
    ] },
    // Nose down and forward, nodding in small quick dips from side to side, whiskers twitching.
    sniff: { s: 2.4, tracks: [
      [P.angleY, alternate(0.3, 2.0, 0.15, -11, -6)], [P.angleX, [[0, 0], [0.4, -8], [1.3, 8], [2.1, 0]]],
      [P.whiskerL, alternate(0.3, 2.0, 0.15, -1, 1)], [P.whiskerR, alternate(0.3, 2.0, 0.15, 1, -1)],
      [P.eyeL, hold(0, 2.4, 0.75, 1)], [P.eyeR, hold(0, 2.4, 0.75, 1)], [P.ballY, hold(0, 2.4, -0.6)],
      [P.earL, hold(0, 2.4, 0.6)], [P.earR, hold(0, 2.4, 0.6)],
    ] },
    // Alert: ears up at once, head up and turned, eyes wide and aside, tail up.
    perk: { s: 1.8, tracks: [
      [P.earL, hold(0, 1.8, 1, 0, 0.12)], [P.earR, hold(0, 1.8, 1, 0, 0.12)],
      [P.angleY, hold(0, 1.8, 8, 0, 0.15)], [P.angleX, hold(0, 1.8, 12, 0, 0.15)], [P.ballX, hold(0, 1.8, 0.8, 0, 0.15)],
      [P.bodyY, hold(0, 1.8, 8, 0, 0.15)], [P.eyeL, hold(0, 1.8, 1, 1)], [P.eyeR, hold(0, 1.8, 1, 1)], [P.tail, hold(0, 1.8, 1, 0, 0.2)],
    ] },
    // Down onto the forepaws with the tail up, then up again into a long yawn, eyes shut, ears back.
    stretch: { s: 3.4, parts: FORELEGS, tracks: [
      [P.bodyY, [[0, 0], [0.5, -25], [1.6, -25], [2.2, 10], [3.0, 10], [3.4, 0]]],
      [P.angleY, [[0, 0], [0.5, -8], [1.6, -8], [2.2, 14], [3.0, 14], [3.4, 0]]],
      [P.pawR, hold(0, 2.0, -1)], [P.pawL, hold(0, 2.0, -0.8)], [P.tail, [[0, 0], [0.5, 1], [1.6, 1], [2.2, 0.3], [3.4, 0]]],
      [P.mouth, [[0, 0], [1.7, 0], [2.2, 1], [2.9, 1], [3.2, 0]]], [P.tongue, [[0, 0], [2.2, 0], [2.5, 0.6], [2.9, 0.6], [3.1, 0]]],
      [P.eyeL, [[0, 1], [1.6, 1], [2.0, 0], [3.0, 0], [3.3, 1]]], [P.eyeR, [[0, 1], [1.6, 1], [2.0, 0], [3.0, 0], [3.3, 1]]],
      [P.earL, [[0, 0], [0.5, -0.4], [2.2, -0.8], [3.0, -0.8], [3.4, 0]]], [P.earR, [[0, 0], [0.5, -0.4], [2.2, -0.8], [3.0, -0.8], [3.4, 0]]],
    ] },
    // The left forepaw up to the mouth, licked a few times with the eyes shut and the head tilted, then put down.
    groom: { s: 3.2, parts: FORELEGS, tracks: [
      [P.pawL, hold(0, 3.0, -2, 0, 0.4)], [P.tongue, alternate(0.6, 2.4, 0.3, 1, 0.1)], [P.mouth, alternate(0.6, 2.4, 0.3, 0.35, 0.1)],
      [P.eyeL, hold(0, 2.9, 0, 1, 0.3)], [P.eyeR, hold(0, 2.9, 0, 1, 0.3)],
      [P.angleZ, [[0, 0], [0.4, 10], [1.6, 14], [2.6, 8], [3.0, 0]]], [P.angleY, hold(0, 3.0, -8, 0, 0.4)],
      [P.earL, hold(0, 3.0, -0.3)], [P.earR, hold(0, 3.0, -0.3)],
    ] },
    // Reaching for the pointer: up on the hind legs with both forepaws raised, batting at it in turn; the head is left
    // to the gaze, so that the eyes stay on the pointer. Ears forward, eyes wide, the tail twitching.
    grab: { s: 2.8, parts: FORELEGS, tracks: [
      [P.bodyY, hold(0, 2.8, 14, 0, 0.35)],
      [P.pawR, [[0, 0], [0.35, -2.5], [0.65, -1.7], [0.95, -2.5], [1.25, -1.7], [1.55, -2.5], [1.85, -1.7], [2.15, -2.5], [2.55, -0.8], [2.8, 0]]],
      [P.pawL, [[0, 0], [0.45, -2], [0.8, -2], [1.1, -1.3], [1.4, -2], [1.7, -1.3], [2.0, -2], [2.3, -1.3], [2.6, -0.6], [2.8, 0]]],
      [P.earL, hold(0, 2.8, 1, 0, 0.15)], [P.earR, hold(0, 2.8, 1, 0, 0.15)],
      [P.eyeL, hold(0, 2.8, 1, 1)], [P.eyeR, hold(0, 2.8, 1, 1)], [P.mouth, hold(0.3, 2.4, 0.25)],
      [P.tail, alternate(0.2, 2.6, 0.22, 0.95, 0.35)],
    ] },
    // Mildly put out: the tail swishes, the ears turn back, the eyes narrow and look away.
    swish: { s: 2.2, tracks: [
      [P.tail, alternate(0.15, 2.0, 0.18, 0.9, 0.1)], [P.tailAngry, hold(0, 2.2, 1)],
      [P.earL, hold(0, 2.2, -0.5)], [P.earR, hold(0, 2.2, -0.5)], [P.eyeL, hold(0, 2.2, 0.6, 1)], [P.eyeR, hold(0, 2.2, 0.6, 1)],
      [P.angleX, hold(0, 2.2, -12)], [P.ballX, hold(0, 2.2, -0.8)],
    ] },
  };
  for (const [name, a] of Object.entries(ACTIONS)) MOTION_MS[name] = Math.round(a.s * 1000);
  // A sprite character without pictures of its own for an action shows these (its states, see character.json).
  const ACTION_PICTURES = { swipe: "cheer", sniff: "think", perk: "surprised", stretch: "happy", groom: "shy", swish: "pout",
                            grab: "cheer" };

  let action = null;  // { tracks, parts, s, t0, end }: the action playing on the Live2D model

  /** Value of a track `e` seconds in, eased between its keys. */
  function trackValue(keys, e) {
    if (e <= keys[0][0]) return keys[0][1];
    for (let i = 1; i < keys.length; i++) {
      const [t1, v1] = keys[i], [t0, v0] = keys[i - 1];
      if (e <= t1) {
        const u = (e - t0) / Math.max(1e-6, t1 - t0);
        return v0 + (v1 - v0) * u * u * (3 - 2 * u);
      }
    }
    return keys[keys.length - 1][1];
  }

  /** Sets the action's parameters (called before each model update), faded over 0.25 s at both ends. */
  function applyAction(cm, ids, parts) {
    const now = performance.now(), e = (now - action.t0) / 1000;
    const end = Math.min(action.s, action.end != null ? (action.end - action.t0) / 1000 : Infinity);
    if (e >= end) { action = null; return; }
    if (action.parts) {
      action.parts.show.forEach((id) => parts.has(id) && cm.setPartOpacityById(id, 1));
      action.parts.hide.forEach((id) => parts.has(id) && cm.setPartOpacityById(id, 0));
    }
    const w = Math.max(0, Math.min(1, e / 0.25, (end - e) / 0.25));
    for (const [names, keys] of action.tracks) {
      const id = names.find((n) => ids.has(n));
      if (!id) continue;
      const cur = cm.getParameterValueById(id);
      cm.setParameterValueById(id, cur + (trackValue(keys, e) - cur) * w);
    }
  }

  function startAction(name) {
    const a = ACTIONS[name];
    action = { tracks: a.tracks, parts: a.parts, s: a.s, t0: performance.now(), end: null };
  }

  /** Another motion takes over: the action fades out. */
  function endAction() {
    if (action && action.end == null) action.end = Math.min(performance.now() + 250, action.t0 + action.s * 1000);
  }

  // ---------------------------------------------------------------- motions

  function play(motion) {
    if (!MOTIONS.includes(motion)) motion = "idle";
    clearTimeout(motionTimer);
    current = motion;
    figureMotion = { name: motion, t0: performance.now() };
    if (sprite) pickSprite(motion);
    playLive2D(motion);
    const ms = MOTION_MS[motion];
    if (ms) motionTimer = setTimeout(() => play(sleeping ? "sleepy" : "idle"), ms);
  }

  function lookAt(x, y) {
    trackHover(x, y);
    const fr = figure.getBoundingClientRect();
    leanTarget = Math.max(-1, Math.min(1, (x - (fr.left + fr.width / 2)) / 400)) * 1.6;
    if (!l2d) return;
    const [cx, cy] = canvasPoint(x, y);
    l2d.model.focus(cx, cy);
  }

  // ---------------------------------------------------------------- bubbles
  // Bubbles stack above the head like a short chat: the newest sits at the bottom, older ones move up
  // and fade a little, and each disappears on its own timer. At most MAX_BUBBLES stay on screen,
  // plus the status bubble ("thinking…"), which always stays at the bottom.

  const MAX_BUBBLES = 3;
  let statusEl = null;
  let typingCount = 0;

  const liveBubbles = () => Array.from(bubbles.querySelectorAll(".bubble:not(.status):not(.leaving)"));

  /** Applies a change to the stack and slides the bubbles that moved from their old positions (FLIP). */
  function withReflow(change) {
    const before = new Map(Array.from(bubbles.children).map((el) => [el, el.getBoundingClientRect().top]));
    change();
    for (const [el, top] of before) {
      if (!el.isConnected) continue;
      const dy = top - el.getBoundingClientRect().top;
      if (Math.abs(dy) < 0.5) continue;
      el.animate([{ transform: `translateY(${dy}px)` }, { transform: "translateY(0)" }],
                 { duration: 280, easing: "cubic-bezier(.2,.8,.2,1)" });
    }
  }

  /** 0 for the newest bubble, 1 for the one above it, … (older bubbles are drawn fainter). */
  function updateDepth() {
    const live = liveBubbles();
    live.forEach((el, i) => (el.dataset.depth = String(live.length - 1 - i)));
  }

  /** Starts (or restarts) a bubble's display timer, unless the pointer is resting on it. */
  let hovered = null;
  function armBubble(el) {
    if (!el._stay || el.classList.contains("leaving")) return;
    clearTimeout(el._timer);
    el._armed = true;
    if (el !== hovered) el._timer = setTimeout(() => dismiss(el), el._stay);
  }

  /** Pauses the bubble under the pointer; the one it leaves gets its full time again. */
  function trackHover(x, y) {
    const hit = document.elementFromPoint(x, y);
    const el = hit && hit.closest(".bubble");
    if (el === hovered) return;
    const previous = hovered;
    hovered = el;
    if (el) clearTimeout(el._timer);
    if (previous && previous._armed && previous.isConnected) armBubble(previous);
  }

  function dismiss(el, fast) {
    if (!el || el.classList.contains("leaving")) return;
    clearTimeout(el._timer);
    el.classList.add("leaving");
    if (fast) el.classList.add("fast");
    updateDepth();
    setTimeout(() => {
      withReflow(() => el.remove());
      if (el.classList.contains("answer") && !bubbles.querySelector(".bubble.answer")) native("answersCleared");
    }, fast ? 260 : 1300);
  }

  // ---------------------------------------------------------------- music

  let grooving = false;
  /** Groove state: the tempo is estimated from recent beat intervals; a continuous beat phase drives
      smooth nodding and swaying, nudged towards each detected beat. `level` fades the dance in and out. */
  const groove = { level: 0, energy: 0.6, period: 0.55, phase: 0, correction: 0, lastBeat: 0, intervals: [], beats: 0, lastFrame: 0 };

  function setGrooving(on) {
    grooving = !!on;
    if (grooving) { groove.intervals = []; groove.lastBeat = 0; }
  }

  function beat(strength) {
    if (!grooving || sleeping) return;
    const now = performance.now() / 1000;
    if (groove.lastBeat) {
      const dt = now - groove.lastBeat;
      if (dt > 0.27 && dt < 1.4) {
        groove.intervals.push(dt);
        if (groove.intervals.length > 8) groove.intervals.shift();
        const sorted = [...groove.intervals].sort((a, b) => a - b);
        groove.period = Math.min(1.1, Math.max(0.33, sorted[Math.floor(sorted.length / 2)]));
      }
    }
    groove.lastBeat = now;
    // Steer the phase towards the nearest whole beat; applied gradually in grooveFrame, so nothing jumps.
    groove.correction = -(groove.phase - Math.round(groove.phase)) * 0.6;
    groove.energy = groove.energy * 0.7 + (strength || 0.6) * 0.3;
    if (++groove.beats % 3 === 0) spawnNote();
  }

  /** Per-frame dance offsets (degrees / parameter units); all zero when not grooving. */
  function grooveFrame() {
    const now = performance.now() / 1000;
    const dt = Math.min(0.1, groove.lastFrame ? now - groove.lastFrame : 0.016);
    groove.lastFrame = now;
    const target = grooving && !sleeping ? 1 : 0;
    groove.level += (target - groove.level) * Math.min(1, dt * 2.2);
    if (groove.level < 0.005) return null;
    const steer = groove.correction * Math.min(1, dt * 6);
    groove.correction -= steer;
    groove.phase += dt / groove.period + steer;
    const p = groove.phase;
    const amp = groove.level * (0.65 + 0.35 * Math.min(1, groove.energy));
    // Excited, not sleepy: the head stays a little raised and lifts on each beat (never drops),
    // and the side-to-side sway is half-time — one side every two beats.
    const lift = Math.pow((1 + Math.cos(2 * Math.PI * p)) / 2, 2);  // 1 on the beat, eased
    const half = Math.PI * p / 2;
    return {
      level: groove.level,
      nod: (5 + 3 * lift) * amp,                       // positive = chin up
      tilt: 15 * Math.sin(half) * amp,
      turn: 11 * Math.sin(half - 0.5) * amp,           // the turn follows the tilt a little later
      body: 5 * Math.sin(half - 0.9) * amp,            // the body later still
      ear: (0.3 + 0.2 * lift) * amp,                   // ears up, perking on the beat
    };
  }

  /** A music note that floats up beside the head. */
  function spawnNote() {
    const r = actor.getBoundingClientRect();
    const n = document.createElement("div");
    n.className = "note";
    n.textContent = ["♪", "♫", "♬", "♩"][Math.floor(Math.random() * 4)];
    const side = Math.random() < 0.5 ? -1 : 1;
    n.style.left = (r.left + r.width / 2 + side * (r.width * (0.18 + Math.random() * 0.12)) - 8) + "px";
    n.style.top = (r.top + r.height * (0.22 + Math.random() * 0.1)) + "px";
    n.style.setProperty("--dx", (side * (10 + Math.random() * 18)) + "px");
    document.body.appendChild(n);
    setTimeout(() => n.remove(), 1900);
  }

  // ---------------------------------------------------------------- bubble placement
  // The window may overhang the screen edge so that the character can sit at the edge; the shell
  // reports which horizontal part of the page is on screen, and the bubbles are kept inside it.

  let bubbleWidth = 304;
  let safe = { left: 0, right: Infinity };

  function layoutBubbles() {
    const vw = window.innerWidth;
    const left = Math.max(0, safe.left), right = Math.min(vw, safe.right);
    const width = Math.max(140, Math.min(bubbleWidth, right - left - 8));
    const x = Math.min(Math.max(vw / 2 - width / 2, left + 4), right - width - 4);
    bubbles.style.width = width + "px";
    bubbles.style.left = Math.max(0, x) + "px";
    bubbles.style.marginLeft = "0";
  }
  window.addEventListener("resize", layoutBubbles);

  function setTalking(on) {
    talking = on || speaking;
    root.classList.toggle("talking", talking && !sleeping);
  }

  /** Shows a bubble. opts: { from: "pet" | "user", kind: "" | "reminder" | "error", ms } */
  function say(text, opts) {
    opts = opts || {};
    const from = opts.from === "user" ? "user" : "pet";
    const chars = Array.from(String(text || ""));
    const el = document.createElement("div");
    el.className = "bubble " + from + (opts.kind ? " " + opts.kind : "");
    el.dataset.solid = "";
    if (from === "user") el.textContent = chars.join("");
    withReflow(() => { if (statusEl) bubbles.insertBefore(el, statusEl); else bubbles.appendChild(el); });
    const live = liveBubbles();
    live.slice(0, Math.max(0, live.length - MAX_BUBBLES)).forEach((old) => dismiss(old, true));
    updateDepth();

    const stay = opts.ms || (from === "user" ? 6000 + chars.length * 80 : Math.min(22000, 8000 + chars.length * 160));
    el._stay = stay;
    const arm = () => armBubble(el);
    if (from === "user") return arm();

    // Typewriter effect with mouth movement.
    let i = 0, finished = false;
    const done = () => {
      if (finished) return;
      finished = true;
      typingCount = Math.max(0, typingCount - 1);
      if (!typingCount) setTalking(false);
    };
    typingCount++;
    setTalking(true);
    const step = () => {
      if (!el.isConnected || el.classList.contains("leaving")) return done();
      i = Math.min(chars.length, i + (chars.length > 80 ? 3 : 1));
      el.textContent = chars.slice(0, i).join("");
      if (i < chars.length) return void setTimeout(step, 34);
      done();
      arm();
    };
    step();
  }

  // ---------------------------------------------------------------- research answers

  const answers = new Map(); // id -> { el, md, raw, timer }

  function beginAnswer(id) {
    const el = document.createElement("div");
    el.className = "bubble pet answer streaming";
    el.dataset.solid = "";
    el.innerHTML = `<div class="close" data-close title="关闭">×</div><div class="md"></div><div class="more"></div>`;
    el.querySelector(".more").textContent = strings.more;
    withReflow(() => { if (statusEl) bubbles.insertBefore(el, statusEl); else bubbles.appendChild(el); });
    const live = liveBubbles();
    live.slice(0, Math.max(0, live.length - MAX_BUBBLES)).forEach((old) => dismiss(old, true));
    updateDepth();
    answers.set(id, { el, md: el.querySelector(".md"), raw: "", timer: null });
    typingCount++;
    setTalking(true);
  }

  function renderAnswer(a) {
    const atBottom = a.el.scrollHeight - a.el.scrollTop - a.el.clientHeight < 24;
    a.md.innerHTML = window.DeskPetMarkdown ? DeskPetMarkdown.renderMarkdown(a.raw) : a.raw;
    if (atBottom) a.el.scrollTop = a.el.scrollHeight;
  }

  function answerDelta(id, piece) {
    const a = answers.get(id);
    if (!a) return;
    a.raw += piece;
    if (!a.timer) a.timer = setTimeout(() => { a.timer = null; renderAnswer(a); }, 150);
  }

  function finishAnswer(id, text, conversationID) {
    const a = answers.get(id);
    if (!a) return;
    clearTimeout(a.timer);
    a.raw = text;
    renderAnswer(a);
    a.el.classList.remove("streaming");
    if (conversationID) a.el.dataset.conversation = conversationID;
    typingCount = Math.max(0, typingCount - 1);
    if (!typingCount) setTalking(false);
    answers.delete(id);
    // 10–30 s depending on length; the timer pauses while the pointer is on the bubble.
    a.el._stay = Math.min(30, 10 + Array.from(text || "").length * 0.02) * 1000;
    armBubble(a.el);
  }

  function failAnswer(id) {
    const a = answers.get(id);
    if (!a) return;
    clearTimeout(a.timer);
    answers.delete(id);
    typingCount = Math.max(0, typingCount - 1);
    if (!typingCount) setTalking(false);
    dismiss(a.el, true);
  }

  let strings = { more: "点击查看完整内容 · 可滚动" };

  function setStatus(text) {
    if (!text) {
      if (statusEl) { const el = statusEl; statusEl = null; dismiss(el, true); }
      return;
    }
    if (!statusEl) {
      statusEl = document.createElement("div");
      statusEl.className = "bubble status";
      statusEl.dataset.solid = "";
      const el = statusEl;
      withReflow(() => bubbles.appendChild(el));
    }
    statusEl.innerHTML = "";
    statusEl.append(document.createTextNode(text));
    const dots = document.createElement("span");
    dots.className = "dots";
    statusEl.append(dots);
  }

  // ---------------------------------------------------------------- hit testing

  function hitArea(x, y) {
    const el = document.elementFromPoint(x, y);
    if (!el) return null;
    const bubble = el.closest(".bubble");
    // The × closes an answer; elsewhere on a finished answer opens the conversation.
    if (bubble && el.closest("[data-close]")) { dismiss(bubble, true); return "bubble"; }
    if (bubble && bubble.dataset.conversation) return "answer:" + bubble.dataset.conversation;
    if (bubble) { dismiss(bubble, true); return "bubble"; }
    if (el === figure && figureOn) {
      const r = figure.getBoundingClientRect();
      if (figureAlpha) {
        const ax = Math.floor((x - r.left) / r.width * figureAlpha.w), ay = Math.floor((y - r.top) / r.height * figureAlpha.h);
        if (ax < 0 || ay < 0 || ax >= figureAlpha.w || ay >= figureAlpha.h || figureAlpha.data[(ay * figureAlpha.w + ax) * 4 + 3] < 24) return null;
      }
      return y < r.top + r.height * figureHead ? "head" : "body";
    }
    if (el === canvas && l2d) {
      const [lx, ly] = canvasPoint(x, y);
      const names = l2d.model.hitTest(lx, ly).map((n) => n.toLowerCase());
      const headNames = (l2d.map.hitAreas && l2d.map.hitAreas.head || ["head", "face"]).map((n) => n.toLowerCase());
      if (names.some((n) => headNames.some((h) => n.includes(h)))) return "head";
      if (names.length) return "body";
      const b = l2d.model.getBounds();
      if (lx >= b.left && lx <= b.right && ly >= b.top && ly <= b.bottom) {
        return ly < b.top + b.height * 0.32 ? "head" : "body";
      }
      return null;
    }
    return null;
  }

  // ---------------------------------------------------------------- click-through mask

  const CELL = 10;
  let lastMask = "";
  const probe = document.createElement("canvas");
  const probeCtx = probe.getContext("2d", { willReadFrequently: true });

  function computeMask() {
    const cols = Math.ceil(window.innerWidth / CELL), rows = Math.ceil(window.innerHeight / CELL);
    let alpha = null, cr = null;
    const drawn = figureOn ? figure : (l2d ? canvas : null);
    if (drawn) {
      cr = drawn.getBoundingClientRect();
      const w = Math.max(1, Math.ceil(cr.width / CELL)), h = Math.max(1, Math.ceil(cr.height / CELL));
      probe.width = w; probe.height = h;
      probeCtx.clearRect(0, 0, w, h);
      try { probeCtx.drawImage(drawn, 0, 0, w, h); alpha = { w, h, data: probeCtx.getImageData(0, 0, w, h).data }; } catch (_) {}
    }
    let bits = "";
    for (let r = 0; r < rows; r++) {
      for (let c = 0; c < cols; c++) {
        const x = c * CELL + CELL / 2, y = r * CELL + CELL / 2;
        const el = document.elementFromPoint(x, y);
        let solid = false;
        if (el && el !== document.body && el !== root && el !== stage && el !== actor && el !== bubbles) {
          if (el === canvas || el === figure) {
            if (alpha && el === drawn) {
              const ax = Math.min(alpha.w - 1, Math.floor((x - cr.left) / CELL)), ay = Math.min(alpha.h - 1, Math.floor((y - cr.top) / CELL));
              solid = alpha.data[(ay * alpha.w + ax) * 4 + 3] > 24;
            }
          } else {
            solid = true;
          }
        }
        bits += solid ? "1" : "0";
      }
    }
    if (bits !== lastMask) {
      lastMask = bits;
      native("mask", { cols, rows, cell: CELL, bits });
    }
  }
  if (!filmMode) setInterval(computeMask, 200);

  // Distance from the bottom of the stage up to the lowest drawn pixel (the paws), so that the native shell
  // can put the feet exactly on a window edge; models leave a transparent margin below the character.
  const feetProbe = document.createElement("canvas");
  const feetCtx = feetProbe.getContext("2d", { willReadFrequently: true });
  let lastFeet = null;
  function measureFeet() {
    const drawn = figureOn ? figure : (l2d ? canvas : null);
    if (!drawn) return;
    const cr = drawn.getBoundingClientRect();
    const k = 3, w = Math.max(1, Math.ceil(cr.width / k)), h = Math.max(1, Math.ceil(cr.height / k));
    feetProbe.width = w;
    feetProbe.height = h;
    try { feetCtx.drawImage(drawn, 0, 0, w, h); } catch (_) { return; }
    const data = feetCtx.getImageData(0, 0, w, h).data;
    let row = -1;
    for (let y = h - 1; y >= 0 && row < 0; y--) {
      for (let x = 0; x < w; x++) if (data[(y * w + x) * 4 + 3] > 40) { row = y; break; }
    }
    if (row < 0) return;
    const gap = Math.max(0, Math.round(stage.getBoundingClientRect().bottom - (cr.top + (row + 1) * cr.height / h)));
    if (gap !== lastFeet) { lastFeet = gap; native("feet", { gap }); }
  }
  if (!filmMode) setInterval(measureFeet, 2000);

  // ---------------------------------------------------------------- Live2D

  function loadScript(src) {
    return new Promise((resolve, reject) => {
      const s = document.createElement("script");
      s.src = src;
      s.onload = resolve;
      s.onerror = () => reject(new Error("failed to load " + src));
      document.head.appendChild(s);
    });
  }

  /** Cubism Core 5.1+ moved the render order from `drawables.renderOrders` to `model.getRenderOrders()`;
      pixi-live2d-display 0.4.0 still reads the old property, so it is mapped onto the new call. */
  function patchCubismCore() {
    const Model = window.Live2DCubismCore && Live2DCubismCore.Model;
    if (!Model || Model.__deskpetPatched) return;
    const fromMoc = Model.fromMoc;
    Model.fromMoc = function (moc) {
      const model = fromMoc.call(this, moc);
      if (model && model.drawables && model.drawables.renderOrders === undefined && typeof model.getRenderOrders === "function") {
        Object.defineProperty(model.drawables, "renderOrders", { get: () => model.getRenderOrders(), configurable: true });
      }
      return model;
    };
    Model.__deskpetPatched = true;
  }

  async function initLive2D(cfg) {
    await loadScript("vendor/live2dcubismcore.min.js");
    patchCubismCore();
    await loadScript("vendor/pixi.min.js");
    await loadScript("vendor/cubism4.min.js");
    const app = new PIXI.Application({
      view: canvas,
      resizeTo: stage,
      backgroundAlpha: 0,
      antialias: true,
      autoDensity: true,
      resolution: window.devicePixelRatio || 2,
      preserveDrawingBuffer: true, // required to sample alpha for the click-through mask
    });
    const model = await PIXI.live2d.Live2DModel.from(cfg.model, { autoInteract: false });
    app.stage.addChild(model);
    const map = cfg.map || await fetch(new URL("pet-map.json", new URL(cfg.model, location.href)))
      .then((r) => (r.ok ? r.json() : {})).catch(() => ({}));
    const fit = () => {
      const w = stage.clientWidth, h = stage.clientHeight;
      model.scale.set(1);
      const s = Math.min(w / model.width, h / model.height) * (map.scale || 0.95);
      model.scale.set(s);
      model.anchor.set(0.5, 1);
      model.position.set(w / 2 + (map.offsetX || 0), h + (map.offsetY || 0));
    };
    fit();
    window.addEventListener("resize", fit);

    // Model settings: the LipSync group names the mouth parameter(s).
    const settings = await fetch(cfg.model).then((r) => r.json()).catch(() => ({}));
    const groupIds = (name) => ((settings.Groups || []).find((g) => g.Name === name) || {}).Ids || [];
    const lipIds = groupIds("LipSync").length ? groupIds("LipSync") : ["ParamMouthOpenY"];

    // pixi-live2d-display drives the gaze through the Cubism 3+ parameter names (ParamAngleX, …).
    // Models converted from Cubism 2 use PARAM_ANGLE_X etc., so their gaze is applied here.
    const ids = new Set(model.internalModel.coreModel.getModel().parameters.ids);
    const partIds = new Set(model.internalModel.coreModel.getModel().parts.ids);
    const legacy = ids.has("PARAM_ANGLE_X") && !ids.has("ParamAngleX");
    const gaze = map.gaze || (legacy ? { PARAM_ANGLE_X: 30, PARAM_ANGLE_Y: 30, PARAM_BODY_ANGLE_X: 8,
                                         PARAM_EYE_BALL_X: 1, PARAM_EYE_BALL_Y: 1 } : null);

    // Parameter overrides (from the current motion's "params" and from states such as sleep),
    // blended in and out over a few frames so that they never snap.
    const blend = {};
    model.internalModel.on("beforeModelUpdate", () => {
      const cm = model.internalModel.coreModel;
      if (gaze) {
        const f = model.internalModel.focusController;
        for (const [id, k] of Object.entries(gaze)) {
          if (ids.has(id)) cm.addParameterValueById(id, (/Y$/.test(id) ? f.y : f.x) * k);
        }
      }
      const targets = Object.assign({}, l2d.motionParams, l2d.stateParams);
      for (const id of new Set([...Object.keys(targets), ...Object.keys(blend)])) {
        if (!ids.has(id)) continue;
        const b = blend[id] || (blend[id] = { w: 0, v: targets[id] });
        const active = id in targets;
        if (active) b.v = targets[id];
        b.w += ((active ? 1 : 0) - b.w) * 0.12;
        if (!active && b.w < 0.01) { delete blend[id]; continue; }
        const cur = cm.getParameterValueById(id);
        cm.setParameterValueById(id, cur + (b.v - cur) * b.w);
      }
      if (action) applyAction(cm, ids, partIds);
      const g = grooveFrame();
      if (g) {
        const find = (names) => names.find((n) => ids.has(n));
        const add = (names, value) => { const id = find(names); if (id) cm.addParameterValueById(id, value); };
        // Swaying is centred: the head's own tilt and turn (from motions and gaze) are drawn back towards
        // the middle while dancing, so it swings evenly to both sides instead of around a leaning pose.
        const centre = (names, value) => {
          const id = find(names);
          if (id) cm.setParameterValueById(id, cm.getParameterValueById(id) * (1 - 0.8 * g.level) + value);
        };
        centre(["PARAM_ANGLE_Z", "ParamAngleZ"], g.tilt);
        centre(["PARAM_ANGLE_X", "ParamAngleX"], g.turn);
        centre(["PARAM_BODY_ANGLE_X", "ParamBodyAngleX"], g.body);
        add(["PARAM_ANGLE_Y", "ParamAngleY"], g.nod);
        add(["PARAM_EAR_L"], g.ear);
        add(["PARAM_EAR_R"], g.ear);
      }
      if (talking && !sleeping) {
        const v = 0.25 + 0.6 * Math.abs(Math.sin(performance.now() / 85));
        lipIds.forEach((id) => ids.has(id) && cm.setParameterValueById(id, v));
      }
    });

    l2d = { app, model, map, motionParams: {}, stateParams: {} };
    if (map.voice === "cat" && window.Meow) window.Meow.preload();
    mode = "live2d";
    playLive2D("idle");
    scheduleIdleAction();
  }

  function playLive2D(motion) {
    if (!l2d) return;
    const { model, map } = l2d;
    const groups = Object.keys((model.internalModel.motionManager.definitions) || {});
    const entry = (map.motions || {})[motion];
    // An action without a motion of the model's own (pet-map.json may name one) plays over the idle motion.
    if (!entry && ACTIONS[motion]) {
      l2d.motionParams = {};
      startAction(motion);
      return;
    }
    if (motion !== "idle") endAction();
    let group = entry && entry.group, index = entry && entry.index;
    if (!group) {
      // Without a mapping: idle uses an "Idle" group, everything else a random tap/other group.
      const idle = groups.find((g) => /idle/i.test(g));
      const others = groups.filter((g) => !/idle/i.test(g));
      group = motion === "idle" || motion === "sleepy" ? idle : others[Math.floor(Math.random() * others.length)] || idle;
    }
    l2d.motionParams = (entry && entry.params) || {};
    // Idle runs by itself between motions; other motions interrupt whatever is playing.
    if (group && motion !== "idle") model.motion(group, index, 3);
    const expression = entry && entry.expression;
    if (expression) model.expression(expression);
    else if (motion === "idle" && map.defaultExpression) model.expression(map.defaultExpression);
  }

  /** Spontaneous small actions while nothing else happens: the model's own (pet-map.json "idleActions": grooming,
      scratching an ear, …) and, two times in five, one of the actions above (a stretch, a lick of the paw, …). */
  const IDLE_ACTIONS = ["stretch", "groom", "swish", "perk", "sniff"];
  let idleActionTimer = null;
  function scheduleIdleAction() {
    clearTimeout(idleActionTimer);
    if (!l2d) return;
    const own = l2d.map.idleActions || [];
    const [min, max] = (l2d.map.idleActionSeconds || [18, 45]);
    idleActionTimer = setTimeout(() => {
      if (l2d && current === "idle" && !sleeping && !talking && !grooving && !action) {
        if (!own.length || Math.random() < 0.4) startAction(IDLE_ACTIONS[Math.floor(Math.random() * IDLE_ACTIONS.length)]);
        else { const a = own[Math.floor(Math.random() * own.length)]; l2d.model.motion(a.group, a.index, 2); }
      }
      scheduleIdleAction();
    }, (min + Math.random() * (max - min)) * 1000);
  }

  /** Converts page coordinates to the canvas' own (unscaled) coordinates. */
  function canvasPoint(x, y) {
    const r = canvas.getBoundingClientRect();
    const k = canvas.clientWidth ? r.width / canvas.clientWidth : 1;
    return [(x - r.left) / k, (y - r.top) / k];
  }

  // ---------------------------------------------------------------- pictures: sprite character and research figure
  // A picture cannot move its parts, so the whole figure breathes (a slight stretch about the feet), sways, leans
  // towards the pointer and acts out the motions with hops, tilts and shakes; a sprite character also changes
  // its picture with the motion and blinks.

  /** Loads a picture and keeps a small copy of its alpha channel for hit testing. */
  function loadPicture(src) {
    return new Promise((resolve) => {
      if (alphaCache.has(src)) { resolve(true); return; }
      const img = new Image();
      img.onload = () => {
        const c = document.createElement("canvas");
        c.width = Math.max(1, Math.round(img.naturalWidth / 4));
        c.height = Math.max(1, Math.round(img.naturalHeight / 4));
        const ctx = c.getContext("2d", { willReadFrequently: true });
        let alpha = null;
        try { ctx.drawImage(img, 0, 0, c.width, c.height); alpha = { w: c.width, h: c.height, data: ctx.getImageData(0, 0, c.width, c.height).data }; } catch (_) {}
        alphaCache.set(src, alpha);
        resolve(true);
      };
      img.onerror = () => { log("picture failed to load:", src); resolve(false); };
      img.src = src;
    });
  }

  function setResearchFigure(url) {
    researchURL = null;
    if (url) loadPicture(url).then((ok) => { if (ok) researchURL = url; });
  }

  async function initSprite(cfg) {
    const map = cfg.map || await fetch(cfg.sprite).then((r) => r.json());
    const base = new URL(".", new URL(cfg.sprite, location.href)).href;
    sprite = { base, states: map.states || {}, weights: map.weights || {}, motions: map.motions || {},
               blink: map.blink || null, head: map.headFraction || 0.5, height: map.height || 1 };
    const names = new Set(Object.values(sprite.states).flat());
    const results = await Promise.all([...names].map((n) => loadPicture(base + n + ".png")));
    if (!results.some(Boolean)) throw new Error("no pictures");
    mode = "sprite";
    pickSprite("idle");
  }

  /** The picture for a motion: one of its state's pictures, chosen by weight. */
  function pickSprite(motion) {
    const state = sprite.motions[motion] || (sprite.states[motion] ? motion : ACTION_PICTURES[motion] || motion);
    const list = sprite.states[state] || sprite.states.idle || ["idle"];
    const weight = (n) => (sprite.weights[n] == null ? 1 : sprite.weights[n]);
    let r = Math.random() * list.reduce((a, n) => a + weight(n), 0);
    spritePick = list.find((n) => (r -= weight(n)) < 0) || list[0];
    nextRepick = performance.now() + (20 + Math.random() * 10) * 1000;
    blinkUntil = 0;
  }

  /** Which picture to show now: the research figure in research mode, otherwise the sprite character. */
  function currentPicture(now) {
    if (researchOn && researchURL) return [researchURL, 0.24, 1];
    if (!sprite) return null;
    const b = sprite.blink;
    if (b && !sleeping && (b.from || []).includes(spritePick)) {
      if (!nextBlink) nextBlink = now + 2000;
      if (now >= nextBlink && now > blinkUntil) {
        blinkUntil = now + (b.ms || 140);
        const [lo, hi] = b.every || [2.5, 6];
        nextBlink = now + (lo + Math.random() * (hi - lo)) * 1000 * (Math.random() < 0.15 ? 0.15 : 1);  // now and then twice
      }
    }
    // A long-lasting expression with several pictures changes picture now and then.
    if (now > nextRepick && (current === "idle" || current === "think" || current === "sleepy")) pickSprite(current);
    const name = now < blinkUntil && sprite.states.blink ? sprite.states.blink[0] : spritePick;
    return [sprite.base + name + ".png", sprite.head, sprite.height];
  }

  function showPicture(now) {
    const pic = currentPicture(now);
    const on = !!pic;
    if (on !== figureOn) {
      figureOn = on;
      root.classList.toggle("figure-on", on);
      lastMask = "";
      lastFeet = null;
    }
    if (pic && pic[0] !== figureSrc) {
      figureSrc = pic[0];
      figure.src = figureSrc;
      figureAlpha = alphaCache.get(figureSrc) || null;
    }
    if (pic) {
      figureHead = pic[1];
      const h = Math.round(pic[2] * 100) + "%";
      if (figure.style.height !== h) figure.style.height = h;
    }
  }

  let figureLoop = true;
  function figureFrame(now) {
    if (paused) { figureLoop = false; return; }
    requestAnimationFrame(figureFrame);
    showPicture(now);
    if (!figureOn) return;
    const t = now / 1000, e = (now - figureMotion.t0) / 1000;
    const TAU = 2 * Math.PI;
    const breath = Math.sin(TAU * t / (sleeping ? 5 : 3.6));
    let rot = 0.6 * Math.sin(TAU * t / 5.5), dx = 0, dy = 0;
    let sy = 1 + (sleeping ? 0.014 : 0.009) * breath, sx = 1 - (sy - 1) * 0.5;
    const within = (d) => (e < d ? 1 - e / d : 0);           // fades out over d seconds
    const bump = (d) => (e < d ? Math.sin(Math.PI * e / d) : 0); // 0 → 1 → 0 over d seconds
    switch (figureMotion.name) {
      case "happy": dy -= 16 * Math.abs(Math.sin(TAU * 1.5 * e)) * within(1.8); sy += 0.02 * bump(1.8); break;
      case "wave": rot += 4 * Math.sin(TAU * 2.2 * e) * within(2.2); break;
      case "nod": dy += 6 * Math.max(0, Math.sin(TAU * 2 * e)) * within(1.1); sy -= 0.02 * Math.max(0, Math.sin(TAU * 2 * e)) * within(1.1); break;
      case "shake": rot += 3.5 * Math.sin(TAU * 3 * e) * within(1.1); break;
      case "think": { const k = Math.min(1, e * 3); rot -= 3 * k; dx -= 4 * k; break; }
      case "surprised": dy -= 20 * bump(0.45); sy += 0.035 * bump(0.45); sx -= 0.02 * bump(0.45); break;
      case "sleepy": { const k = Math.min(1, e * 1.5); rot += 4 * k; dy += 3 * k; break; }
      case "shy": rot += 2.5 * Math.sin(TAU * 1.6 * e) * within(2.6); sx -= 0.015 * bump(2.6); break;
      case "eat": dy += 4 * Math.abs(Math.sin(TAU * 2 * e)) * within(4.2); break;
      case "sad": { const k = Math.min(1, e * 2) * within(3.2 + 0.5) ; sy -= 0.03 * k; rot += 1.5 * k; break; }
      // The actions (see ACTIONS), as far as a picture can act them.
      case "swipe": { const jab = e < 0.9 ? Math.max(0, Math.sin(Math.PI * (e % 0.5) / 0.4)) * (e % 0.5 < 0.4 ? 1 : 0) : 0;
                      rot -= 7 * jab; dx -= 5 * jab; dy += 3 * jab; break; }
      case "sniff": dy += 3 * Math.abs(Math.sin(TAU * 3.3 * e)) * within(2.4); rot += 2 * Math.sin(TAU * 0.6 * e) * within(2.4); break;
      case "perk": dy -= 12 * bump(0.35); sy += 0.025 * (e < 1.6 ? Math.min(1, e * 6) : 0); break;
      case "stretch": { const down = e < 1.6 ? Math.min(1, e * 2) : Math.max(0, 1 - (e - 1.6) * 2);
                        const up = e > 1.6 && e < 3.4 ? Math.sin(Math.PI * (e - 1.6) / 1.8) : 0;
                        sy += 0.05 * up - 0.05 * down; sx += 0.04 * down; break; }
      case "groom": rot += 3 * Math.sin(TAU * 1.2 * e) * within(3.2); dy += 2 * Math.abs(Math.sin(TAU * 3.3 * e)) * within(3.2); break;
      case "swish": rot += 2 * Math.sin(TAU * 2.8 * e) * within(2.2); break;
      // Up on tiptoe towards the pointer (the lean follows it), bobbing a little with each grab.
      case "grab": { const up = Math.max(0, Math.min(1, e * 4, (2.8 - e) / 0.3));
                     sy += 0.05 * up; sx -= 0.02 * up; dy -= (6 + 4 * Math.abs(Math.sin(TAU * 1.7 * e))) * up; break; }
    }
    const g = grooveFrame();
    if (g) { rot += g.tilt * 0.3; dx += g.body * 1.4; dy -= g.nod * 0.5; sy += 0.01 * g.level * Math.max(0, g.nod / 8); }
    if (talking && !sleeping) dy -= 1.6 * Math.abs(Math.sin(now / 85));
    lean += (leanTarget - lean) * 0.06;
    rot += lean;
    figure.style.transform = `translateX(-50%) translate(${dx.toFixed(2)}px, ${dy.toFixed(2)}px) rotate(${rot.toFixed(3)}deg) scale(${sx.toFixed(4)}, ${sy.toFixed(4)})`;
  }
  requestAnimationFrame(figureFrame);

  // ---------------------------------------------------------------- API for the native shell

  window.pet = {
    async init(cfg) {
      cfg = cfg || {};
      if (cfg.scale) window.pet.setScale(cfg.scale);
      if (cfg.strings) strings = Object.assign(strings, cfg.strings);
      if (cfg.layout) window.pet.setLayout(cfg.layout[0], cfg.layout[1]);
      window.pet.setBubblesBelow(!!cfg.below);
      if (cfg.researchFigure) setResearchFigure(cfg.researchFigure);
      let problem = cfg.model || cfg.sprite ? null : (cfg.missing || "没有找到 Live2D 模型。");
      if (cfg.sprite) {
        try { await initSprite(cfg); }
        catch (e) { problem = "形象加载失败：" + (e && e.message); log(problem); }
      } else if (cfg.model) {
        try { await initLive2D(cfg); }
        catch (e) { problem = "Live2D 模型加载失败：" + (e && e.message); log(problem); }
      }
      native("ready", { mode });
      if (problem) say(problem + "\n请在 设置 → 通用 → 形象 中检查模型。", { kind: "error", ms: 120000 });
      return mode;
    },
    play,
    say,
    setStatus,
    lookAt,
    hitArea,
    setResearch(on) {
      researchOn = !!on;
      root.classList.toggle("research", researchOn);
      if (!researchOn) bubbles.querySelectorAll(".bubble.answer").forEach((b) => dismiss(b, true));
    },
    setResearchFigure,
    setDragging(on) { if (on) play("surprised"); },
    /** The native voice is reading a bubble aloud. */
    setSpeaking(on) {
      speaking = !!on;
      setTalking(typingCount > 0);
    },
    /** Stops drawing (the desktop film while windows cover it); the last frame stays. */
    setPaused(on) {
      paused = !!on;
      if (l2d) {
        if (paused) { l2d.app.ticker.stop(); PIXI.Ticker.shared.stop(); }
        else { PIXI.Ticker.shared.start(); l2d.app.ticker.start(); }
      }
      if (!paused && !figureLoop) { figureLoop = true; requestAnimationFrame(figureFrame); }
    },
    setSleeping(on) {
      sleeping = !!on;
      if (l2d) l2d.stateParams = sleeping ? ((l2d.map.states || {}).sleep || {}) : {};
      play(sleeping ? "sleepy" : "idle");
    },
    setScale(s) { root.style.setProperty("--pet-scale", String(s || 1)); },
    /** Near the top of the screen the bubbles stack below the character, the newest nearest to it. */
    setBubblesBelow(on) { root.classList.toggle("bubbles-below", !!on); },
    /** Room kept free under the character for the chat box, when the bubbles are below it. */
    setChatGap(px) { root.style.setProperty("--chat-gap", (px || 0) + "px"); },
    /** A cat sound (meow.js) for characters whose pet-map.json declares "voice": "cat"; `volume` 0…1. */
    meow(kind, volume) {
      if (!l2d || l2d.map.voice !== "cat" || !window.Meow || figureOn) return;  // the whale girl does not meow
      window.Meow.play(kind, volume).catch((e) => log("meow failed:", e && e.message));
    },
    /** Horizontal range of the page (CSS pixels) that is on screen. */
    setSafeArea(left, right) { safe = { left, right }; layoutBubbles(); },
    setGrooving,
    beat,
    /** Size of the bubble area in CSS pixels. */
    setLayout(w, h) {
      bubbleWidth = w;
      layoutBubbles();
      root.style.setProperty("--bubbles-w", w + "px");
      root.style.setProperty("--bubbles-h", h + "px");
    },
    /** Scrolls the bubble at a page point; positive `dy` moves the content down (shows earlier text). */
    scrollAt(x, y, dy) {
      const el = document.elementFromPoint(x, y);
      const bubble = el && el.closest(".bubble");
      if (!bubble) return;
      bubble.scrollTop -= dy;
    },
    beginAnswer,
    answerDelta,
    finishAnswer,
    failAnswer,
    /** "crouch" | "air" | "land" | "" — body shape during a hop. */
    hop(phase) {
      root.classList.remove("hop-crouch", "hop-air", "hop-land");
      if (phase) { void actor.offsetWidth; root.classList.add("hop-" + phase); }
      if (phase === "land") setTimeout(() => root.classList.remove("hop-land"), 360);
    },
    // Inspection helpers for writing pet-map.json.
    motionGroups() {
      if (!l2d) return null;
      const defs = l2d.model.internalModel.motionManager.definitions || {};
      return Object.fromEntries(Object.entries(defs).map(([g, list]) => [g, list.length]));
    },
    playGroup(group, index) { if (l2d) l2d.model.motion(group, index, 3); },
    /** Holds parameters at values ({ id: value }; {} releases them), for trying out poses. */
    holdParams(p) { if (l2d) l2d.stateParams = p || {}; },
    paramValue(id) { return l2d ? l2d.model.internalModel.coreModel.getParameterValueById(id) : null; },
    params() {
      if (!l2d) return null;
      const p = l2d.model.internalModel.coreModel.getModel().parameters;
      const out = {};
      p.ids.forEach((id, i) => (out[id] = [p.minimumValues[i], p.defaultValues[i], p.maximumValues[i]]));
      return out;
    },
  };

  // Standalone preview in a normal browser: no native shell, so run a short demo.
  if (!filmMode && (!window.webkit || !window.webkit.messageHandlers)) {
    const params = new URLSearchParams(location.search);
    if (!params.has("transparent")) document.body.style.background = "linear-gradient(#e9e4ff, #fde2ef)";
    window.pet.init({ model: params.get("model") || undefined });
    window.addEventListener("mousemove", (e) => lookAt(e.clientX, e.clientY));
    document.addEventListener("click", (e) => {
      const area = hitArea(e.clientX, e.clientY);
      if (area === "head") { play("shy"); say("嘿嘿，被摸头了～"); }
      else if (area === "body") play(MOTIONS[1 + Math.floor(Math.random() * (MOTIONS.length - 1))]);
    });
    if (!params.has("still")) setTimeout(() => { play("wave"); say("你好呀！点我的头或者身体试试看～"); }, 600);
  }
})();
