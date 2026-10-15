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

  // Semantic motions and how long the one-shot ones last (ms); sleepy and think stay until replaced.
  const MOTIONS = ["idle", "happy", "wave", "nod", "shake", "think", "surprised", "sleepy", "shy", "eat", "sad"];
  const MOTION_MS = { happy: 1800, wave: 2200, nod: 1100, shake: 1100, surprised: 1500, shy: 2600, eat: 4200, sad: 3200 };

  let mode = "none"; // "live2d" once a model is shown
  let l2d = null;   // { app, model, map }
  let motionTimer = null;
  let current = "idle";
  let sleeping = false;
  let talking = false;
  let researchOn = false;

  // ---------------------------------------------------------------- motions

  function play(motion) {
    if (!MOTIONS.includes(motion)) motion = "idle";
    clearTimeout(motionTimer);
    current = motion;
    playLive2D(motion);
    const ms = MOTION_MS[motion];
    if (ms) motionTimer = setTimeout(() => play(sleeping ? "sleepy" : "idle"), ms);
  }

  function lookAt(x, y) {
    trackHover(x, y);
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
    talking = on;
    root.classList.toggle("talking", on && !sleeping);
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
    if (l2d) {
      cr = canvas.getBoundingClientRect();
      const w = Math.max(1, Math.ceil(cr.width / CELL)), h = Math.max(1, Math.ceil(cr.height / CELL));
      probe.width = w; probe.height = h;
      probeCtx.clearRect(0, 0, w, h);
      try { probeCtx.drawImage(canvas, 0, 0, w, h); alpha = { w, h, data: probeCtx.getImageData(0, 0, w, h).data }; } catch (_) {}
    }
    let bits = "";
    for (let r = 0; r < rows; r++) {
      for (let c = 0; c < cols; c++) {
        const x = c * CELL + CELL / 2, y = r * CELL + CELL / 2;
        const el = document.elementFromPoint(x, y);
        let solid = false;
        if (el && el !== document.body && el !== root && el !== stage && el !== actor && el !== bubbles) {
          if (el === canvas) {
            if (alpha) {
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
  setInterval(computeMask, 200);

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

  /** Spontaneous small actions while nothing else happens (grooming, scratching an ear, …). */
  let idleActionTimer = null;
  function scheduleIdleAction() {
    clearTimeout(idleActionTimer);
    const actions = (l2d && l2d.map.idleActions) || [];
    if (!actions.length) return;
    const [min, max] = (l2d.map.idleActionSeconds || [18, 45]);
    idleActionTimer = setTimeout(() => {
      if (l2d && current === "idle" && !sleeping && !talking && !grooving) {
        const a = actions[Math.floor(Math.random() * actions.length)];
        l2d.model.motion(a.group, a.index, 2);
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

  // ---------------------------------------------------------------- API for the native shell

  window.pet = {
    async init(cfg) {
      cfg = cfg || {};
      if (cfg.scale) window.pet.setScale(cfg.scale);
      if (cfg.strings) strings = Object.assign(strings, cfg.strings);
      if (cfg.layout) window.pet.setLayout(cfg.layout[0], cfg.layout[1]);
      window.pet.setBubblesBelow(!!cfg.below);
      let problem = cfg.model ? null : (cfg.missing || "没有找到 Live2D 模型。");
      if (cfg.model) {
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
      if (!researchOn) bubbles.querySelectorAll(".bubble.answer").forEach((b) => dismiss(b, true));
    },
    setDragging(on) { if (on) play("surprised"); },
    setSleeping(on) {
      sleeping = !!on;
      if (l2d) l2d.stateParams = sleeping ? ((l2d.map.states || {}).sleep || {}) : {};
      play(sleeping ? "sleepy" : "idle");
    },
    setScale(s) { root.style.setProperty("--pet-scale", String(s || 1)); },
    /** Near the top of the screen the bubbles stack below the character, the newest nearest to it. */
    setBubblesBelow(on) { root.classList.toggle("bubbles-below", !!on); },
    /** A cat sound (meow.js) for characters whose pet-map.json declares "voice": "cat"; `volume` 0…1. */
    meow(kind, volume) {
      if (!l2d || l2d.map.voice !== "cat" || !window.Meow) return;
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
  if (!window.webkit || !window.webkit.messageHandlers) {
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
