/* Cat sounds: short CC0 recordings (sounds/, see THIRD_PARTY_NOTICES.md) played through Web Audio.
   Each kind picks one of its clips at random and a playback rate (pitch and speed together), so
   repeated sounds differ a little; "angry" and "sad" are ordinary meows played lower and slower. */
(function () {
  "use strict";

  const KINDS = {
    meow: { clips: ["meow1", "meow2", "meow3", "meow4"], rate: [0.97, 1.05] },
    mew: { clips: ["mew1", "mew2", "mew3"], rate: [0.98, 1.08] },
    trill: { clips: ["trill1", "trill2"], rate: [0.97, 1.04] },
    angry: { clips: ["meow1", "meow2"], rate: [0.78, 0.82] },
    sad: { clips: ["meow1", "meow4"], rate: [0.86, 0.9] },
    purr: { clips: ["purr"], rate: [0.96, 1.04] },
  };

  let ctx = null;
  let compressor = null;
  const buffers = {};
  // The output is suspended while nothing plays, so that the app does not keep an audio stream open.
  let playing = 0;
  let idleTimer = null;

  function context() {
    if (!ctx) {
      ctx = new (window.AudioContext || window.webkitAudioContext)();
      compressor = ctx.createDynamicsCompressor();
      compressor.connect(ctx.destination);
    }
    if (ctx.state === "suspended") ctx.resume();
    return ctx;
  }

  function load(name) {
    if (!buffers[name]) {
      buffers[name] = fetch("sounds/" + name + ".m4a")
        .then((r) => r.arrayBuffer())
        .then((data) => new Promise((resolve, reject) => context().decodeAudioData(data, resolve, reject)));
    }
    return buffers[name];
  }

  window.Meow = {
    kinds: Object.keys(KINDS),
    /** Decodes every clip ahead of time, so that the first sound is not late. */
    preload() {
      new Set(Object.values(KINDS).flatMap((k) => k.clips)).forEach((name) => load(name).catch(() => {}));
    },
    /** Plays one sound of `kind`; `volume` 0…1. Resolves when it has started. */
    async play(kind, volume) {
      const k = KINDS[kind] || KINDS.meow;
      const buffer = await load(k.clips[Math.floor(Math.random() * k.clips.length)]);
      const ac = context();
      const source = ac.createBufferSource();
      source.buffer = buffer;
      source.playbackRate.value = k.rate[0] + Math.random() * (k.rate[1] - k.rate[0]);
      const gain = ac.createGain();
      gain.gain.value = Math.max(0, Math.min(1, volume));
      source.connect(gain).connect(compressor);
      playing++;
      clearTimeout(idleTimer);
      source.onended = () => {
        gain.disconnect();
        if (--playing === 0) idleTimer = setTimeout(() => { if (playing === 0) ac.suspend(); }, 1500);
      };
      source.start();
    },
  };
})();
