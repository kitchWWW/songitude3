/* Songitude web player — a browser port of the iOS app's engine.
 * No background: keep the page open + screen on (Wake Lock helps). See /listen/.
 */
(() => {
  "use strict";
  const WALKS_BASE = "https://songitude-walks.s3.amazonaws.com";
  const MANIFEST_URL = WALKS_BASE + "/walks/manifest.json";
  const PRELOAD_M = 300, EVICT_M = 600;   // proximity residency thresholds (metres)

  // Dialogue shapes show playback state (one plays at a time; the rest queue). Colors come from the
  // walk's map.json (authored in the editor); these are the fallbacks. Opacity gives each state its look.
  const DEFAULT_DIALOGUE_COLORS = { unplayed: "#8a63d2", queued: "#f5a623", playing: "#2ecc71", finished: "#ffffff" };
  const DIALOGUE_STATE_OPACITY = { unplayed: 0.2, queued: 0.42, playing: 0.6, finished: 0.08 };
  const INTRO_GATE_MS = 60 * 60 * 1000;   // don't replay a walk's intro within 1 hour (resume window)
  // Holds `dialoguePlaying` while the intro narration runs, so a dialogue the listener already
  // stands in queues behind it. Not a shape id, so nothing maps it back to a shape.
  const INTRO_CHANNEL = "__intro__";
  const DONE_DELAY_MS = 30 * 1000;        // show the "Play Outro" button this long after play starts
  const SKIP_S = 15;                      // how far one press of a skip button moves every voice

  const $ = (id) => document.getElementById(id);
  const walksListEl = $("walksList");

  // ---- map ----
  // CARTO Positron, greyed by CSS (.leaflet-tile-pane) so authored areas are the only colour.
  // The key became mandatory in Aug 2026 — without it CARTO stamps "API KEY REQUIRED" across every
  // tile. It is a *public* key by nature (it rides in every tile URL, visible to anyone who loads
  // the map), so restrict it by domain in the CARTO dashboard rather than treating it as a secret.
  // Keep in step with editor/editor.js and ios/Songitude/Songitude/Views/MapOverlayView.swift.
  const CARTO_KEY = "cb1_2log_1_19551f9fb4c0fbe576aadb40";
  const BASEMAP_URL =
    "https://basemaps.cartocdn.com/rastertiles/light_all/{z}/{x}/{y}{r}.png?key=" + CARTO_KEY;

  const lmap = L.map("map", { zoomControl: false, attributionControl: false })
    .setView([40.7128, -74.006], 15);
  // Credit is rendered in #footerBar instead — Leaflet's control sits over the map bottom-right and
  // collides with the footer on narrow screens.
  L.tileLayer(BASEMAP_URL, { maxZoom: 20 }).addTo(lmap);

  // ---- state ----
  let ctx = null, masterGain = null;
  let walk = null, shapes = [], routes = [], labels = [];
  const buffers = new Map(), loadingFiles = new Set();
  let running = false, syncedStarted = false, userCoord = null;
  let manifestWalks = [];
  let shapeLayers = new Map();
  let routeLayers = [];      // suggested-route polylines + their endpoint markers
  let labelLayers = [];      // free-standing map markings (captions / artwork)
  let dialogueQueue = [], dialoguePlaying = null;   // one dialogue plays at a time; others wait in line
  let outroActive = false, doneTimer = null, introVoice = null, exitVoice = null;   // intro/exit (walk-level) clips
  // When the synced loops launched (context time) and the seconds of skipping applied since. A
  // synced voice's position comes from these rather than its own clock, so a skip lands every
  // synced clip on the same offset and they stay aligned with each other.
  let syncedEpoch = 0, syncedShift = 0;
  const dColor = (st) => (walk && walk.map.dialogueColors && walk.map.dialogueColors[st]) || DEFAULT_DIALOGUE_COLORS[st];
  // "fuzzy" drops the outline and feathers each area's edge outward over a band this fraction of
  // its size; a polygon also takes a round-jointed stroke, which rounds its corners into a blob.
  // Absent from the bundle ⇒ "classic", the outlined look every walk published before it had.
  const FUZZ_BAND = 0.08;
  const fuzzyOn = () => !!(walk && walk.map && walk.map.displayStyle === "fuzzy");
  // Half the shape's smaller on-screen dimension, i.e. a radius in pixels at the current zoom.
  function shapePixelSize(s, layer) {
    if (!layer) return 0;
    if (s.type === "circle") return layer._radius || 0;
    const b = layer.getBounds();
    const nw = lmap.latLngToLayerPoint(b.getNorthWest()), se = lmap.latLngToLayerPoint(b.getSouthEast());
    return Math.min(Math.abs(se.x - nw.x), Math.abs(se.y - nw.y)) / 2;
  }
  // The stroke only exists to round a polygon's corners, so it matches the fill exactly; the blur
  // on the path element does the feathering.
  function withFuzz(s, layer, style) {
    // Classic has to put the stroke's alpha back explicitly — Leaflet keeps whatever was last set.
    if (!fuzzyOn()) return { opacity: 1, ...style };
    const fill = style.fillColor || style.color;
    const op = style.fillOpacity ?? 0.2;
    return { ...style, color: fill, fillColor: fill, opacity: op,
             weight: s.type === "polygon" ? Math.max(1, FUZZ_BAND * shapePixelSize(s, layer) * 0.6) : 0 };
  }
  function applyFuzz(s, layer) {
    const path = layer && layer._path; if (!path) return;
    const size = fuzzyOn() ? shapePixelSize(s, layer) : 0;
    path.style.filter = size > 4 ? `blur(${(FUZZ_BAND * size / 2).toFixed(2)}px)` : "";
  }
  // The feather is sized in screen pixels, so it is redrawn whenever the scale changes.
  lmap.on("zoomend", () => { for (const s of shapes) applyFuzz(s, shapeLayers.get(s.id)); });

  // ---- geometry ----
  const R = 6371000, toR = (x) => x * Math.PI / 180;
  function haversine(a, b) {
    const dLat = toR(b[0] - a[0]), dLng = toR(b[1] - a[1]);
    const h = Math.sin(dLat / 2) ** 2 + Math.cos(toR(a[0])) * Math.cos(toR(b[0])) * Math.sin(dLng / 2) ** 2;
    return 2 * R * Math.asin(Math.sqrt(h));
  }
  function pointInPolygon(pt, ring) {
    let inside = false;
    for (let i = 0, j = ring.length - 1; i < ring.length; j = i++) {
      const yi = ring[i][0], xi = ring[i][1], yj = ring[j][0], xj = ring[j][1];
      if (((yi > pt[0]) !== (yj > pt[0])) && pt[1] < ((xj - xi) * (pt[0] - yi) / (yj - yi + 1e-15) + xi)) inside = !inside;
    }
    return inside;
  }
  function contains(s, c) {
    if (s.type === "circle") return s.center && s.radius != null && haversine(s.center, c) <= s.radius;
    return s.points && s.points.length >= 3 && pointInPolygon(c, s.points);
  }
  function regionDistance(s, c) {
    if (s.type === "circle") return (s.center && s.radius != null) ? Math.max(0, haversine(s.center, c) - s.radius) : Infinity;
    if (!s.points || s.points.length < 3) return Infinity;
    if (pointInPolygon(c, s.points)) return 0;
    return Math.min(...s.points.map((p) => haversine(p, c)));
  }
  function falloffLevel(mode, r) {
    r = Math.max(0, Math.min(1, r));
    switch (mode) {
      case "linear": return 1 - r;
      case "exponential": return (1 - r) * (1 - r);
      case "edge": return r <= 0.5 ? 1 : Math.max(0, 2 * (1 - r));
      default: return 1;
    }
  }

  // ---- audio engine ----
  function syncedFiles() { return [...new Set(shapes.filter((s) => s.mode === "syncedLoop" && s.audioFile).map((s) => s.audioFile))]; }
  // At least one soloed area is engaged (see soloEngaged). While that holds, only soloed areas are
  // audible; everything else the listener is inside ducks to silence and returns when it lets go.
  let soloOn = false;
  // Shape ids whose duck factor moved during the current location pass, so the pass doesn't ramp
  // them a second time and cut a duck fade short.
  let duckMoved = new Set();
  // A duck is a gain change, never a stop — the ducked voice keeps running underneath so it comes
  // back where it would have been. Applies to every mode alike, dialogue included.
  function duckFor(s) { return (soloOn && !s.solo) ? 0 : 1; }
  // Is this shape's solo engaging the duck right now? Containment is the test for every mode but
  // dialogue: a dialogue only *queues* on entry and plays once ever, so a soloed dialogue must duck
  // the walk while its own clip sounds — not while it waits its turn, and not once it's finished.
  // `insideIds` is the fresh containment set during a location pass; without it we use the last one
  // seen, which is what a dialogue starting between location updates needs.
  function soloEngaged(s, insideIds) {
    if (!s.solo) return false;
    if (s.mode === "dialogue") return !!(s._rt && s._rt.dstate === "playing");
    return insideIds ? insideIds.has(s.id) : !!(s._rt && s._rt.inside);
  }
  // Recompute the solo latch and move every voice whose duck factor changed. Called from the
  // location pass and from the dialogue queue (start/finish), since a soloed dialogue engages and
  // releases the duck between location updates. Ducking in and out uses the ducked shape's own
  // fades, so it sounds like leaving and re-entering it.
  function applySolo(insideIds) {
    soloOn = shapes.some((s) => soloEngaged(s, insideIds));
    for (const s of shapes) {
      if (!s._rt) s._rt = { inside: false, armed: true, source: null, gain: null, dstate: "unplayed" };
      const rt = s._rt, duck = duckFor(s);
      // Only act once a baseline is recorded — the first pass just notes where this shape sits.
      const changed = rt.duck !== undefined && rt.duck !== duck;
      rt.duck = duck;
      if (!changed) continue;
      duckMoved.add(s.id);
      if (!rt.gain) continue;
      const inNow = insideIds ? insideIds.has(s.id) : rt.inside;
      const target = (s.mode === "loop" || s.mode === "syncedLoop")
        ? (inNow && userCoord ? targetGain(s, userCoord) : 0)
        : s.gain * duck;
      rampGain(rt.gain, target, duck ? Math.max(0.02, s.fadeIn) : Math.max(0.02, s.fadeOut));
    }
  }
  function targetGain(s, c) {
    if (s.type === "circle" && s.falloff && s.falloff !== "none" && s.center && s.radius)
      return s.gain * falloffLevel(s.falloff, haversine(s.center, c) / s.radius) * duckFor(s);
    return s.gain * duckFor(s);
  }
  function rampGain(g, target, dur) {
    const t = ctx.currentTime;
    g.gain.cancelScheduledValues(t); g.gain.setValueAtTime(g.gain.value, t);
    g.gain.linearRampToValueAtTime(Math.max(0.0001, target), t + Math.max(0.01, dur));
  }
  // A crossfade loop: overlapping copies of `buf` under `destGain`, each fading in as the previous
  // fades out. Returns an object with stop(when), so it drops into the same slot as a looping source.
  // `startOffset` begins the cycle partway into the clip, which is how a skip lands on a crossfade
  // loop: its copies are scheduled ahead of time and can't be nudged once they're out, so the whole
  // overlap cycle is rebuilt at the new offset instead.
  function makeCrossfadeLoop(buf, crossfade, destGain, startOffset) {
    const D = buf.duration;
    const C = Math.min(Math.max(0.05, crossfade || 1), D * 0.5);   // clamp to ≤ half the clip
    const period = Math.max(0.05, D - C);
    const active = new Set();
    let nextStart = 0, first = true, stopAt = Infinity, torn = false;
    const scheduleCopy = (startAt, bufOffset) => {
      const off = bufOffset || 0, span = D - off;   // a copy that starts late also ends early
      const src = ctx.createBufferSource(); src.buffer = buf;
      const cg = ctx.createGain();
      if (first) { cg.gain.setValueAtTime(1, startAt); first = false; }
      else { cg.gain.setValueAtTime(0.0001, startAt); cg.gain.linearRampToValueAtTime(1, startAt + C); }
      cg.gain.setValueAtTime(1, startAt + span - C);
      cg.gain.linearRampToValueAtTime(0.0001, startAt + span);
      src.connect(cg).connect(destGain);
      src.start(startAt, off); src.stop(startAt + span + 0.05);
      active.add(src); src.onended = () => active.delete(src);
    };
    const tick = () => {
      if (torn) return;
      const ahead = Math.min(ctx.currentTime + 0.4, stopAt);
      while (nextStart < ahead) { scheduleCopy(nextStart); nextStart += period; }
    };
    const begin = ctx.currentTime, head = Math.min(Math.max(0, startOffset || 0), D * 0.999);
    scheduleCopy(begin, head);                       // the copy that lands on the requested offset
    nextStart = begin + Math.max(0.05, (D - head) - C);
    tick();
    const timer = setInterval(tick, 150);
    const teardown = () => { if (torn) return; torn = true; clearInterval(timer); for (const src of active) { try { src.stop(ctx.currentTime); } catch (_) {} } };
    return {
      stop(when) {
        const at = (typeof when === "number" && when > ctx.currentTime) ? when : ctx.currentTime;
        stopAt = Math.min(stopAt, at);
        tick();
        setTimeout(teardown, Math.max(0, (stopAt - ctx.currentTime) * 1000) + 80);
      },
    };
  }
  // Chrome mis-loops an AudioBuffer whose frame count is odd: instead of wrapping it pins the read
  // head at the end and repeats the last handful of samples forever — a stuck, high-pitched buzz
  // from the second pass onward. Naming the loop window explicitly sidesteps it. The frame this
  // gives up is a single sample (~0.02 ms) and inaudible; even-length buffers loop as before.
  function loopWholeBuffer(src, buf) {
    src.loop = true;
    if (buf.length % 2) { src.loopStart = 0; src.loopEnd = (buf.length - 1) / buf.sampleRate; }
  }
  function startLoop(s, c) {
    const buf = buffers.get(s.audioFile); if (!buf) return;
    const g = ctx.createGain(); g.gain.setValueAtTime(0.0001, ctx.currentTime);
    g.gain.linearRampToValueAtTime(Math.max(0.0001, targetGain(s, c)), ctx.currentTime + Math.max(0.01, s.fadeIn));
    g.connect(masterGain);
    s._rt.gain = g;
    s._rt.startedAt = ctx.currentTime; s._rt.offset = 0;
    if (s.loopMode === "crossfade") {
      s._rt.source = makeCrossfadeLoop(buf, s.crossfade, g, 0);
    } else {
      const src = ctx.createBufferSource(); src.buffer = buf; loopWholeBuffer(src, buf);
      src.connect(g); src.start();
      s._rt.source = src;
    }
  }
  function updateLoopGain(s, c) {
    if (!s._rt.gain) return;
    const tracksProximity = s.type === "circle" && s.falloff && s.falloff !== "none";
    if (!tracksProximity) return;   // constant-gain loop, nothing here moves it
    rampGain(s._rt.gain, targetGain(s, c), 0.12);
  }
  function stopLoop(s) {
    const rt = s._rt; if (!rt.source) return;
    const src = rt.source, t = ctx.currentTime, fade = Math.max(0.01, s.fadeOut);
    rampGain(rt.gain, 0, fade);
    try { src.stop(t + fade + 0.05); } catch (_) {}
    rt.source = null; rt.gain = null;
  }
  function playOnce(s) {
    const buf = buffers.get(s.audioFile); if (!buf) return;
    const src = ctx.createBufferSource(); src.buffer = buf;
    const g = ctx.createGain(); g.gain.value = Math.max(0.0001, s.gain * duckFor(s)); src.connect(g).connect(masterGain);
    src.onended = oneshotEnded(s, src);
    src.start(); s._rt.source = src; s._rt.gain = g;
    s._rt.startedAt = ctx.currentTime; s._rt.offset = 0;
  }
  // A one-shot has played itself out: drop the voice, leaving `armed` to the location pass so it
  // only re-arms on the way out of the area.
  function oneshotEnded(s, src) {
    return () => { if (s._rt && s._rt.source === src) { s._rt.source = null; s._rt.gain = null; reflectSounding(); } };
  }
  // Dialogue: play once, one at a time. Next queued dialogue starts when the current one finishes.
  async function advanceDialogue() {
    if (dialoguePlaying) return;
    const nextId = dialogueQueue.shift();
    if (nextId === undefined) return;
    const s = shapes.find((x) => x.id === nextId);
    if (!s) return advanceDialogue();
    dialoguePlaying = s.id;
    s._rt.dstate = "playing";
    reflectSounding();
    if (s.audioFile && !buffers.has(s.audioFile)) await ensureBuffer(s.audioFile);
    if (dialoguePlaying !== s.id) return;                     // stopped while the clip loaded
    const buf = s.audioFile ? buffers.get(s.audioFile) : null;
    if (!buf) return onDialogueFinished(s);
    const src = ctx.createBufferSource(); src.buffer = buf;
    const g = ctx.createGain(); g.gain.value = Math.max(0.0001, s.gain * duckFor(s)); src.connect(g).connect(masterGain);
    src.onended = dialogueEnded(s, src);
    src.start(); s._rt.source = src; s._rt.gain = g;
    s._rt.startedAt = ctx.currentTime; s._rt.offset = 0;
    // A soloed dialogue engages the duck only now, as its clip starts — entering its area merely
    // queued it, and the location pass that queued it is long over.
    applySolo();
    reflectSounding();
  }
  function dialogueEnded(s, src) {
    return () => { if (s._rt && s._rt.source === src) { s._rt.source = null; s._rt.gain = null; onDialogueFinished(s); } };
  }
  function onDialogueFinished(s) {
    if (dialoguePlaying === s.id) dialoguePlaying = null;
    if (s._rt) { s._rt.source = null; s._rt.gain = null; s._rt.dstate = "finished"; }
    reflectSounding();
    advanceDialogue();
    // A soloed dialogue's duck ends with its clip. Recompute after the queue has moved on, so
    // handing over to another soloed dialogue doesn't blip the duck off and straight back on.
    applySolo();
  }

  // ---- intro / exit (walk-level) clips ----
  const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
  function playClipOnce(buf, gain, onended) {
    const src = ctx.createBufferSource(); src.buffer = buf;
    const g = ctx.createGain(); g.gain.value = gain; src.connect(g).connect(masterGain);
    if (onended) src.onended = onended;
    src.start();
    return { src, g, buf, onended, startedAt: ctx.currentTime, offset: 0 };
  }
  // Fade + stop every sounding voice matching `pick`, over `dur` seconds.
  function fadeVoices(dur, pick) {
    const t = ctx.currentTime;
    for (const s of shapes) {
      if (!(s._rt && s._rt.source) || !pick(s)) continue;
      const g = s._rt.gain;
      g.gain.cancelScheduledValues(t); g.gain.setValueAtTime(g.gain.value, t);
      g.gain.linearRampToValueAtTime(0.0001, t + dur);
      try { s._rt.source.stop(t + dur + 0.05); } catch (_) {}
      s._rt.source = null; s._rt.gain = null;
    }
  }
  async function maybePlayIntro() {
    const file = walk && walk.map.intro;
    if (!file) return;
    const key = "songitude.intro." + walk.id;
    const last = parseInt(localStorage.getItem(key) || "0", 10);
    if (Date.now() - last < INTRO_GATE_MS) return;   // resumed recently → don't replay
    // Claim the dialogue channel before the decode: a fix landing in that gap would otherwise start
    // a dialogue over the intro. The intro fires at session start, so the channel is free; the
    // guard just means a dialogue somehow already speaking keeps the channel it holds.
    if (!dialoguePlaying) dialoguePlaying = INTRO_CHANNEL;
    await ensureBuffer(file);
    const buf = buffers.get(file);
    if (!buf || !running) { releaseIntroChannel(); return; }
    try { localStorage.setItem(key, String(Date.now())); } catch (_) {}
    if (introVoice) { try { introVoice.src.stop(); } catch (_) {} }
    introVoice = playClipOnce(buf, walk.map.introGain ?? 1,
                              () => { introVoice = null; releaseIntroChannel(); });
  }
  /// Hand the dialogue channel back and start whatever queued while the intro played.
  function releaseIntroChannel() {
    if (dialoguePlaying !== INTRO_CHANNEL) return;   // already cleared by a stop
    dialoguePlaying = null;
    advanceDialogue();
  }
  // End-of-walk: fade dialogue (1s) → exit clip → fade everything (5s) → stop the session.
  async function endSession() {
    if (outroActive || !running) return;
    outroActive = true;
    $("doneBtn").disabled = true;
    setStatus("Wrapping up…");
    fadeVoices(1.0, (s) => s.mode === "dialogue");
    dialogueQueue = []; dialoguePlaying = null;
    await sleep(1000);
    if (!outroActive) return;
    const exitFile = walk && walk.map.exit;
    if (exitFile) {
      await ensureBuffer(exitFile);
      const buf = buffers.get(exitFile);
      if (buf) await new Promise((resolve) => { exitVoice = playClipOnce(buf, walk.map.exitGain ?? 1, () => { exitVoice = null; resolve(); }); });
    }
    if (!outroActive) return;
    fadeVoices(5.0, () => true);   // everything else fades out
    await sleep(5000);
    if (!outroActive) return;
    outroActive = false;
    stop();
    setStatus("That's the end of the walk. 🎧");
  }
  // ---- skip (the ±15 s buttons) ----
  // Only ever a playhead move: it does not rewind the listener's position, revisit areas they have
  // walked out of, or start anything that isn't already sounding. The modes differ only in what the
  // ends of a clip mean — a loop wraps both ways, while a one-shot or dialogue is meant to be heard
  // once through, so rewinding past its start restarts it and skipping past its end plays it out.
  function playhead(rt) { return (ctx.currentTime - rt.startedAt) + rt.offset; }
  function wrapPos(pos, D) { const p = pos % D; return p < 0 ? p + D : p; }

  // Swap in a fresh source playing from `offset` seconds in, keeping the voice's gain node — and so
  // its level and any ramp in flight — exactly as it was.
  function restartSource(s, offset, when, loop) {
    const buf = buffers.get(s.audioFile); if (!buf || !s._rt.gain) return null;
    const old = s._rt.source;
    if (old) { try { old.onended = null; old.stop(); } catch (_) {} }
    const src = ctx.createBufferSource(); src.buffer = buf; src.loop = !!loop;
    src.connect(s._rt.gain);
    const at = (typeof when === "number") ? when : ctx.currentTime;
    src.start(at, offset);
    s._rt.source = src; s._rt.startedAt = at; s._rt.offset = offset;
    return src;
  }

  function skip(delta) {
    // The outro is a timed sequence (fade → clip → fade → stop); moving its audio underneath those
    // timers would only desynchronise them from what is actually playing.
    if (!running || outroActive || !ctx || !delta) return;
    // Every synced loop restarts at one common time, so they resume in lock-step.
    const syncedAt = ctx.currentTime + 0.15;
    syncedShift += delta;

    for (const s of shapes) {
      const rt = s._rt; if (!rt || !rt.source) continue;
      const buf = s.audioFile && buffers.get(s.audioFile); if (!buf || !(buf.duration > 0)) continue;
      const D = buf.duration;
      if (s.mode === "syncedLoop") {
        restartSource(s, wrapPos((syncedAt - syncedEpoch) + syncedShift, D), syncedAt, true);
      } else if (s.mode === "loop") {
        const pos = wrapPos(playhead(rt) + delta, D);
        if (s.loopMode === "crossfade") {
          try { rt.source.stop(); } catch (_) {}
          rt.source = makeCrossfadeLoop(buf, s.crossfade, rt.gain, pos);
          rt.startedAt = ctx.currentTime; rt.offset = pos;
        } else {
          restartSource(s, pos, null, true);
        }
      } else {
        const pos = playhead(rt) + delta;
        if (pos >= D) {                       // past the end ⇒ the same as having heard it out
          try { rt.source.onended = null; rt.source.stop(); } catch (_) {}
          rt.source = null; rt.gain = null;
          if (s.mode === "dialogue") onDialogueFinished(s); else reflectSounding();
        } else {
          const src = restartSource(s, Math.max(0, pos), null, false);
          if (src) src.onended = s.mode === "dialogue" ? dialogueEnded(s, src) : oneshotEnded(s, src);
        }
      }
    }
    // The walk's intro is a clip like any other, so it moves with everything else.
    if (introVoice) skipClip(introVoice, delta);
    reflectSounding();
  }

  function skipClip(v, delta) {
    const D = v.buf.duration; if (!(D > 0)) return;
    const pos = (ctx.currentTime - v.startedAt) + v.offset + delta;
    try { v.src.onended = null; v.src.stop(); } catch (_) {}
    if (pos >= D) { if (v.onended) v.onended(); return; }
    const src = ctx.createBufferSource(); src.buffer = v.buf;
    src.connect(v.g); src.onended = v.onended || null;
    src.start(ctx.currentTime, Math.max(0, pos));
    v.src = src; v.startedAt = ctx.currentTime; v.offset = Math.max(0, pos);
  }

  function startSyncedIfReady() {
    if (!running || syncedStarted) return;
    const files = syncedFiles(); if (!files.length) { syncedStarted = true; return; }
    if (!files.every((f) => buffers.has(f))) return;
    const startAt = ctx.currentTime + 0.15;
    for (const s of shapes) {
      if (s.mode !== "syncedLoop" || !s.audioFile || (s._rt && s._rt.source)) continue;
      const buf = buffers.get(s.audioFile); if (!buf) continue;
      if (!s._rt) s._rt = { inside: false, armed: true, source: null, gain: null, dstate: "unplayed" };
      const src = ctx.createBufferSource(); src.buffer = buf; loopWholeBuffer(src, buf);
      const g = ctx.createGain(); g.gain.setValueAtTime(0, ctx.currentTime);
      src.connect(g).connect(masterGain); src.start(startAt);
      s._rt.source = src; s._rt.gain = g;
      s._rt.startedAt = startAt; s._rt.offset = 0;
    }
    syncedEpoch = startAt; syncedShift = 0;
    syncedStarted = true; reflectSounding();
  }

  function fileInUse(f) { return shapes.some((s) => s.audioFile === f && s._rt && s._rt.source); }
  async function ensureBuffer(file) {
    if (buffers.has(file) || loadingFiles.has(file) || !ctx) return;
    loadingFiles.add(file);
    try {
      const url = `${walk.base}/audio/${file.split("/").map(encodeURIComponent).join("/")}`;
      const ab = await (await fetch(url, { mode: "cors", cache: "force-cache" })).arrayBuffer();
      buffers.set(file, await ctx.decodeAudioData(ab));
      if (running) { startSyncedIfReady(); if (userCoord) updateLocation(userCoord); }
    } catch (e) { console.warn("audio load failed", file, e); }
    finally { loadingFiles.delete(file); }
  }
  function updateResidency(c) {
    const synced = new Set(syncedFiles());
    for (const f of new Set(shapes.map((s) => s.audioFile).filter(Boolean))) {
      const d = synced.has(f) ? 0 : Math.min(...shapes.filter((s) => s.audioFile === f).map((s) => regionDistance(s, c)));
      if (!buffers.has(f)) { if (!loadingFiles.has(f) && d <= PRELOAD_M) ensureBuffer(f); }
      else if (!synced.has(f) && d > EVICT_M && !fileInUse(f)) buffers.delete(f);
    }
  }

  function updateLocation(c) {
    if (!running || outroActive) return;   // freeze location-driven playback during the outro
    userCoord = c;
    updateResidency(c);
    startSyncedIfReady();
    const inside = new Set();
    for (const s of shapes) if (contains(s, c)) inside.add(s.id);
    // Solo latch first: a duck switching on or off has to move voices that set their gain once
    // (one-shots, dialogue) or hold a constant level (loops with no falloff). Anything it already
    // ramped is left alone below so its duck fade isn't cut short.
    duckMoved.clear();
    applySolo(inside);
    for (const s of shapes) {
      if (!s._rt) s._rt = { inside: false, armed: true, source: null, gain: null, dstate: "unplayed" };
      const rt = s._rt, nowIn = inside.has(s.id), rising = nowIn && !rt.inside;
      if (s.mode === "loop") {
        if (nowIn && !rt.source) startLoop(s, c);
        else if (nowIn && rt.source && !duckMoved.has(s.id)) updateLoopGain(s, c);
        else if (!nowIn && rt.source) stopLoop(s);
      } else if (s.mode === "syncedLoop") {
        if (rt.source && !duckMoved.has(s.id)) {
          const target = nowIn ? targetGain(s, c) : 0;
          const dur = rising ? Math.max(0.02, s.fadeIn) : (!nowIn && rt.inside ? Math.max(0.02, s.fadeOut) : 0.12);
          rampGain(rt.gain, target, dur);
        }
      } else if (s.mode === "oneshot") {
        if (rising && rt.armed) { playOnce(s); rt.armed = false; }
        if (!nowIn) rt.armed = true;
      } else { // dialogue: play once ever; queue behind any dialogue already playing
        if (rising && rt.dstate === "unplayed") { rt.dstate = "queued"; dialogueQueue.push(s.id); advanceDialogue(); }
      }
      rt.inside = nowIn;
    }
    reflectSounding();
  }

  function reflectSounding() {
    for (const s of shapes) {
      const layer = shapeLayers.get(s.id); if (!layer) continue;
      if (s.mode === "dialogue") {
        const st = (running && s._rt && s._rt.dstate) || "unplayed";
        const col = dColor(st);
        layer.setStyle(withFuzz(s, layer, { color: col, fillColor: col, fillOpacity: DIALOGUE_STATE_OPACITY[st], weight: st === "playing" ? 3 : 2 }));
      } else {
        const on = !!(s._rt && s._rt.source && (!s._rt.gain || s._rt.gain.gain.value > 0.01));
        const base = s.color || "#4363d8";   // same fallback drawShapes used when the shape has no colour
        layer.setStyle(withFuzz(s, layer, { color: base, fillColor: base, fillOpacity: on ? 0.5 : 0.2, weight: on ? 3 : 2 }));
      }
      applyFuzz(s, layer);
    }
  }

  // ---- shapes on map ----
  function drawShapes() {
    shapeLayers.forEach((l) => lmap.removeLayer(l)); shapeLayers.clear();
    for (const s of shapes) {
      if (s.hidden) continue;              // audible, but the listener never sees it
      const base = s.mode === "dialogue" ? dColor("unplayed") : (s.color || "#4363d8");
      const fo = s.mode === "dialogue" ? DIALOGUE_STATE_OPACITY.unplayed : 0.2;
      const style = { color: base, weight: 2, fillColor: base, fillOpacity: fo };
      let layer = null;
      if (s.type === "circle" && s.center && s.radius != null) layer = L.circle(s.center, { radius: s.radius, ...style });
      else if (s.type === "polygon" && s.points && s.points.length >= 3) layer = L.polygon(s.points, style);
      if (layer) {
        layer.addTo(lmap); shapeLayers.set(s.id, layer);
        if (fuzzyOn()) { layer.setStyle(withFuzz(s, layer, style)); applyFuzz(s, layer); }
      }
    }
  }

  // ---- suggested routes on map ----
  // Purely decorative: a route never sounds, never gates anything, and is simply drawn under the
  // sound areas as a hint about where to walk. Round caps and joins come free from the SVG stroke.
  function drawRoutes() {
    routeLayers.forEach((l) => lmap.removeLayer(l)); routeLayers = [];
    for (const r of routes) {
      if (!Array.isArray(r.points) || r.points.length < 2) continue;
      const color = r.color || "#111111";
      const line = L.polyline(r.points, { color, weight: r.width ?? 6, opacity: 0.9,
                                          lineCap: "round", lineJoin: "round", interactive: false });
      line.addTo(lmap); line.bringToBack();
      routeLayers.push(line);
      const w = r.width ?? 6;
      routeLayers.push(routeEndMarker(r.points[0], color, w));
      routeLayers.push(routeEndMarker(r.points[r.points.length - 1], color, w));
    }
  }
  /// A solid dot in the route's own colour, sized off the line width so it reads as the end of the
  /// stroke rather than a badge on top of it. A caption at an endpoint is a Label now.
  function routeEndMarker(pt, color, width) {
    const d = Math.max(6, Math.min(width, 14));
    const icon = L.divIcon({
      className: "route-end",
      html: `<i style="background:${color};width:${d}px;height:${d}px"></i>`,
      iconSize: null, iconAnchor: [d / 2, 10],
    });
    return L.marker(pt, { icon, interactive: false, keyboard: false, zIndexOffset: 500 }).addTo(lmap);
  }
  // ---- labels: free-standing map markings ----
  // Purely decorative, exactly like a route. Drawn as a divIcon so a marking keeps one size on
  // screen at every zoom, and never interactive — a caption must not swallow a tap on the map.
  function drawLabels() {
    labelLayers.forEach((l) => lmap.removeLayer(l)); labelLayers = [];
    for (const l of labels) {
      if (!Array.isArray(l.point) || l.point.length !== 2) continue;
      const node = labelNode(l);
      if (!node) continue;                 // no image and no text — nothing to draw
      const icon = L.divIcon({ className: "map-label", html: node, iconSize: null });
      labelLayers.push(L.marker(l.point, { icon, interactive: false, keyboard: false,
                                           zIndexOffset: 1000 }).addTo(lmap));
    }
  }
  /// An image is drawn instead of the text when the bundle carries one; a named image that isn't
  /// in the bundle falls back to the text, as FORMAT.md specifies. Built as DOM rather than markup:
  /// the fallback needs an error handler, and an inline one would have to carry the author's text
  /// through an HTML attribute, which breaks the moment the caption contains a quote.
  function labelNode(l) {
    const size = l.size ?? (l.image ? 48 : 14);
    // `size` is a width for an image label, so it means nothing as a font size — text that stands
    // in for a missing image is drawn at the ordinary default instead.
    const textEl = () => {
      if (!l.text) return null;
      const span = document.createElement("span");
      span.textContent = l.text;
      span.style.fontSize = (l.image ? 14 : size) + "px";
      span.style.color = l.textColor || "#000000";
      if (l.bgColor !== "none") span.style.background = l.bgColor || "#ffffff";
      return span;
    };
    if (!l.image) return textEl();
    const img = document.createElement("img");
    img.src = `${walk.base}/images/${l.image.split("/").map(encodeURIComponent).join("/")}`;
    img.style.width = size + "px";
    img.alt = "";
    img.onerror = () => { const t = textEl(); if (t) img.replaceWith(t); else img.remove(); };
    return img;
  }
  function escapeHtml(v) {
    return String(v).replace(/[&<>"']/g, (c) =>
      ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c]));
  }

  // ---- GPS + slew ----
  let watchId = null, virtual = null, slewTimer = null, userMarker = null;
  function startWatch() {
    if (!navigator.geolocation) { toast("Geolocation isn't supported in this browser.", "err"); return; }
    watchId = navigator.geolocation.watchPosition(onFix, onGeoErr, { enableHighAccuracy: true, maximumAge: 0, timeout: 20000 });
  }
  function stopWatch() {
    if (watchId != null) { navigator.geolocation.clearWatch(watchId); watchId = null; }
    if (slewTimer) { clearInterval(slewTimer); slewTimer = null; }
  }
  function onFix(pos) {
    if (explore) return;                       // a stray fix must not fight the virtual walker
    const c = [pos.coords.latitude, pos.coords.longitude];
    updateUserMarker(c); ingestFix(c);
    // Far enough from every area that standing here would produce nothing but silence — which reads
    // as a broken page rather than as "you aren't there yet". Offer the alternative instead.
    const d = nearestAreaDistance(c);
    if (d > FAR_M) offerExplore(`You're about ${fmtDist(d)} from this walk, so where you're standing won't trigger any of it.`);
  }
  function ingestFix(c) {
    if (!virtual) { virtual = c; updateLocation(c); return; }
    if (slewTimer) clearInterval(slewTimer);
    const from = virtual.slice(), steps = Math.max(1, Math.min(25, Math.ceil(haversine(from, c) / 5)));
    let step = 0;
    slewTimer = setInterval(() => {
      step++; const f = step / steps;
      virtual = [from[0] + (c[0] - from[0]) * f, from[1] + (c[1] - from[1]) * f];
      updateUserMarker(virtual); updateLocation(virtual);
      if (step >= steps) { clearInterval(slewTimer); slewTimer = null; }
    }, 200);
  }
  function onGeoErr(e) {
    if (explore) return;
    if (e.code === 1) {
      stop();
      offerExplore("Without your location the walk can't tell where you are in it.");
    } else {
      toast("Location error: " + e.message, "err");
      offerExplore("Your location isn't coming through, so the walk can't follow you.");
    }
  }

  // ---- explore mode: click through the walk without being there ----
  // The same engine, driven by a virtual walker you move with map clicks instead of by GPS. The
  // intro, every area, the dialogue queue and the outro all behave exactly as they do on location;
  // only the listener's *movement* is simulated. No sound is ever synthesised here or anywhere else
  // in Songitude — every audible thing comes from the composer's own files in the bundle.
  // For listeners who want to hear a walk they can't travel to.
  const EXPLORE_SPEED = { walking: 1.4, running: 3.5, biking: 6.7, driving: 13.4 };   // m/s; teleport is instant
  const FAR_M = 4828;                          // ~3 miles from the nearest area
  let explore = false, exploreOffered = false, exploreSpeed = "walking";
  let exPos = null, exTarget = null, exRAF = null, exFrameTs = 0, exEngineTs = 0;

  function nearestAreaDistance(c) {
    let best = Infinity;
    for (const s of shapes) best = Math.min(best, regionDistance(s, c));
    return best;
  }
  // Offered once per walk: past that it would be nagging, and the bar is always there to switch back.
  function offerExplore(copy) {
    if (explore || exploreOffered || !walk || !shapes.length) return;
    exploreOffered = true;
    $("exploreCopy").textContent = copy +
      " You can still hear all of it — the intro, every area as you reach it, and the outro — by" +
      " clicking your way around the map.";
    $("exploreOverlay").hidden = false;
  }

  /// The speed picker lives in the header beside the walk title (behind the menu on phones).
  function setExploreControls(on) { $("exploreSpeed").hidden = !on; }

  function enterExplore() {
    $("exploreOverlay").hidden = true;
    explore = true;
    document.body.classList.add("exploring");
    setExploreControls(true);
    stopWatch(); virtual = null;
    // Start in the middle of the walk, so there is something to set off towards.
    const start = walk && walk.map && walk.map.center;
    if (Array.isArray(start) && start.length === 2) {
      exPos = start.slice(); exTarget = exPos.slice();
      updateUserMarker(exPos);
      if (running) updateLocation(exPos);
    }
    setStatus(running ? "Exploring — click the map to walk there. 🎧"
                      : "Exploring — press play, then click the map to walk.");
  }

  function exitExplore() {
    $("exploreOverlay").hidden = true;
    explore = false;
    document.body.classList.remove("exploring");
    setExploreControls(false);
    stopExploreMove();
    exPos = null; exTarget = null;
    if (running) { startWatch(); setStatus("Listening — keep this page open and your screen on. 🎧"); }
    else setStatus("Ready — press play, then start walking.");
  }

  // A map click sets the target: teleport jumps, the rest walk there at their own pace.
  function placeExplorer(latlng) {
    const target = [latlng.lat, latlng.lng];
    if (exploreSpeed === "teleport" || !exPos) {
      stopExploreMove();
      exPos = target; exTarget = target;
      updateUserMarker(exPos);
      if (running) updateLocation(exPos);
      return;
    }
    exTarget = target;                         // a moving target: the walker re-routes toward it
    startExploreMove();
  }
  function startExploreMove() { if (!exRAF) { exFrameTs = 0; exRAF = requestAnimationFrame(stepExplore); } }
  function stopExploreMove() { if (exRAF) { cancelAnimationFrame(exRAF); exRAF = null; } }

  function stepExplore(ts) {
    if (!exPos || !exTarget) { exRAF = null; return; }
    if (!exFrameTs) exFrameTs = ts;
    const dt = Math.min(0.1, (ts - exFrameTs) / 1000); exFrameTs = ts;
    const remaining = haversine(exPos, exTarget);
    const step = (EXPLORE_SPEED[exploreSpeed] || 1.4) * dt;   // metres this frame
    if (remaining <= step || remaining < 0.3) {               // arrived
      exPos = exTarget; exRAF = null;
      updateUserMarker(exPos);
      if (running) updateLocation(exPos);
      return;
    }
    const f = step / remaining;
    exPos = [exPos[0] + (exTarget[0] - exPos[0]) * f, exPos[1] + (exTarget[1] - exPos[1]) * f];
    updateUserMarker(exPos);
    if (running && ts - exEngineTs > 60) { updateLocation(exPos); exEngineTs = ts; }   // ~16 Hz audio
    exRAF = requestAnimationFrame(stepExplore);
  }

  lmap.on("click", (e) => { if (explore) placeExplorer(e.latlng); });
  function updateUserMarker(c) {
    if (!userMarker) {
      userMarker = L.marker(c, { icon: L.divIcon({ className: "", html: '<div class="user-marker"></div>', iconSize: [18, 18], iconAnchor: [9, 9] }) }).addTo(lmap);
      lmap.setView(c, Math.max(lmap.getZoom(), 17));
    } else userMarker.setLatLng(c);
  }

  // ---- wake lock + media session ----
  let wakeLock = null;
  async function acquireWake() { try { if ("wakeLock" in navigator) wakeLock = await navigator.wakeLock.request("screen"); } catch (_) {} }
  function releaseWake() { try { wakeLock && wakeLock.release(); } catch (_) {} wakeLock = null; }
  document.addEventListener("visibilitychange", () => { if (running && document.visibilityState === "visible" && !wakeLock) acquireWake(); });

  function setMediaMeta() {
    if (!("mediaSession" in navigator) || !walk) return;
    const art = walk.map.albumArt ? [{ src: `${walk.base}/${encodeURIComponent(walk.map.albumArt)}`, sizes: "512x512", type: "image/jpeg" }] : [];
    try {
      navigator.mediaSession.metadata = new MediaMetadata({ title: walk.map.name || "Soundwalk", artist: walk.map.creator || "Songitude", artwork: art });
      navigator.mediaSession.setActionHandler("play", () => { if (!running) play(); });
      navigator.mediaSession.setActionHandler("pause", () => { if (running) stop(); });
    } catch (_) {}
  }
  function setMediaPlaying(p) { if ("mediaSession" in navigator) navigator.mediaSession.playbackState = p ? "playing" : "paused"; }

  // ---- transport ----
  async function play() {
    if (!walk) { openPicker(); return; }
    if (!ctx) { ctx = new (window.AudioContext || window.webkitAudioContext)(); masterGain = ctx.createGain(); masterGain.connect(ctx.destination); }
    if (ctx.state === "suspended") await ctx.resume();
    running = true; syncedStarted = false; userCoord = null; soloOn = false; duckMoved.clear();
    syncedEpoch = 0; syncedShift = 0;
    dialogueQueue = []; dialoguePlaying = null;
    for (const s of shapes) s._rt = { inside: false, armed: true, source: null, gain: null, dstate: "unplayed" };
    syncedFiles().forEach(ensureBuffer);   // synced loops load immediately, start when all ready
    startSyncedIfReady();
    if (explore) { if (exPos) updateLocation(exPos); } else startWatch();
    acquireWake(); setMediaPlaying(true);
    // Reset the end-session UI and arm the "Play Outro" button; play the intro (gated per walk).
    outroActive = false;
    $("doneBtn").hidden = true; $("doneBtn").disabled = false;
    clearTimeout(doneTimer);
    // Only offered when the walk actually ships an outro to play.
    doneTimer = setTimeout(() => {
      if (running && walk && walk.map && walk.map.exit) $("doneBtn").hidden = false;
    }, DONE_DELAY_MS);
    maybePlayIntro();
    renderPlay();
    setStatus(explore ? "Exploring — click the map to walk there. 🎧"
                      : "Listening — keep this page open and your screen on. 🎧");
  }
  function stop() {
    running = false; syncedStarted = false; soloOn = false; duckMoved.clear();
    syncedEpoch = 0; syncedShift = 0;
    stopWatch(); virtual = null;
    stopExploreMove();                     // the walker stops where it stands; explore mode itself stays on
    dialogueQueue = []; dialoguePlaying = null;
    outroActive = false;
    clearTimeout(doneTimer); doneTimer = null;
    $("doneBtn").hidden = true; $("doneBtn").disabled = false;
    if (introVoice) { try { introVoice.src.stop(); } catch (_) {} introVoice = null; }
    if (exitVoice) { try { exitVoice.src.stop(); } catch (_) {} exitVoice = null; }
    for (const s of shapes) {
      if (s._rt && s._rt.source) { try { s._rt.source.stop(); } catch (_) {} s._rt.source = null; s._rt.gain = null; }
      if (s._rt) { s._rt.inside = false; s._rt.armed = true; s._rt.dstate = "unplayed"; }
    }
    releaseWake(); setMediaPlaying(false); reflectSounding(); renderPlay(); setStatus("Paused.");
  }
  function toggle() { running ? stop() : play(); }
  function renderPlay() {
    const b = $("playBtn");
    b.textContent = running ? "❚❚" : "▶";
    b.classList.toggle("playing", running);
    b.setAttribute("aria-label", running ? "Pause" : "Play");
    // The skips hold their place either side of play whether or not anything is sounding, so the
    // play button never moves under the thumb.
    $("skipBackBtn").disabled = !running;
    $("skipFwdBtn").disabled = !running;
  }

  // ---- catalog + walk loading ----
  function dist(w, here) { return (w.center && here) ? haversine(w.center, here) : Infinity; }
  // Same scale as the iOS list: feet up close, miles beyond, whole miles once precision stops
  // mattering. NEARBY_M matches the app's "close enough to go and hear right now" threshold.
  const NEARBY_M = 2 * 1609.344;
  function fmtDist(m) {
    const miles = m / 1609.344;
    if (miles < 0.1) return Math.round(m * 3.28084 / 10) * 10 + " ft";
    if (miles < 10) return miles.toFixed(1) + " miles";
    return Math.round(miles) + " miles";
  }
  function loadCatalog() {
    walksListEl.innerHTML = "<p class='empty'>Loading…</p>";
    fetch(MANIFEST_URL, { cache: "no-store" }).then((r) => r.json())
      .then((m) => {
        manifestWalks = m.walks || [];
        renderPicker();
        window.dispatchEvent(new Event("songitude:catalog"));
      })
      .catch((e) => { walksListEl.innerHTML = "<p class='empty'>Couldn't load: " + e.message + "</p>"; });
  }
  function renderPicker() {
    const here = virtual || (userMarker && [userMarker.getLatLng().lat, userMarker.getLatLng().lng]);
    const list = manifestWalks.slice();
    if (here) list.sort((a, b) => dist(a, here) - dist(b, here));
    else list.sort((a, b) => String(b.updatedAt || "").localeCompare(String(a.updatedAt || "")));
    if (!list.length) { walksListEl.innerHTML = "<p class='empty'>No published walks yet.</p>"; return; }
    walksListEl.innerHTML = "";
    for (const w of list) {
      const row = document.createElement("button"); row.className = "walk-row";
      const d = here && w.center ? dist(w, here) : null;
      row.innerHTML = `<div class="art"></div><div class="info"><h4></h4>` +
        `<div class="byline"></div><div class="meta"></div></div><div class="go">›</div>`;

      const art = row.querySelector(".art");
      if (w.artUrl) {
        const img = document.createElement("img");
        img.src = w.artUrl; img.alt = ""; img.loading = "lazy";
        img.onerror = () => { art.classList.add("art-empty"); img.remove(); };
        art.append(img);
      } else art.classList.add("art-empty");

      row.querySelector("h4").textContent = w.name || w.id;

      const byline = row.querySelector(".byline");
      if (w.creator) {
        byline.append(document.createTextNode("by "));
        if (w.artistId) {
          const a = document.createElement("button");
          a.className = "artist-link"; a.textContent = w.creator;
          a.onclick = (e) => { e.stopPropagation(); openArtist(w.artistId, w.creator); };
          byline.append(a);
        } else {
          const span = document.createElement("span"); span.textContent = w.creator;
          byline.append(span);
        }
      } else byline.hidden = true;

      const meta = row.querySelector(".meta");
      if (d != null) {
        const near = document.createElement("span");
        near.textContent = fmtDist(d) + " away";
        if (d < NEARBY_M) near.className = "near";
        meta.append(near, document.createTextNode(" · "));
      }
      meta.append(document.createTextNode(`${w.shapeCount || 0} areas`));

      row.onclick = () => { closePicker(); loadWalk(w.id); };
      walksListEl.append(row);
    }
  }
  async function loadWalk(id) {
    if (running) stop();
    setStatus("Loading walk…");
    const known = manifestWalks.find((x) => x.id === id);
    const base = known ? known.base : `${WALKS_BASE}/walks/${id}`;
    try {
      let mapData = await (await fetch(`${base}/map.json`, { cache: "no-store" })).json();
      if (mapData.startAnchor) {
        setStatus("Placing this walk around you…");
        const [here, heading] = await Promise.all([currentPosition(), readHeadingOnce()]);
        if (here) mapData = transposeWalk(mapData, here, heading);
        else toast("Couldn't read your location — showing this walk where it was authored.", "err");
      }
      walk = { id, base, map: mapData };
      exploreOffered = false;              // a different walk earns its own offer
      if (explore) exitExplore();          // and starts from the listener's real location again
      shapes = (mapData.shapes || []).map((s) => ({ ...s, _rt: null }));
      routes = mapData.routes || [];
      labels = mapData.labels || [];
      buffers.clear(); loadingFiles.clear(); syncedStarted = false;
      dialogueQueue = []; dialoguePlaying = null;
      drawShapes();
      drawRoutes();
      drawLabels();
      fitToWalk(mapData);
      $("titleBtn").textContent = (mapData.name || "Soundwalk") + " ▾";
      setMediaMeta();
      $("playBtn").disabled = false;
      $("welcomeOverlay").hidden = true;
      setStatus("Ready — press play, then start walking.");
      showIntroCard(mapData, known, false);
    } catch (e) { toast("Couldn't load that walk: " + e.message, "err"); }
  }

  // ---- markdown, artist profiles, intro card ------------------------------------------------
  const ARTISTS_BASE = WALKS_BASE + "/artists";
  const artistCache = new Map();
  const INTRO_CARD_MS = 10 * 60 * 1000;   // don't re-show a walk's card within this window

  function renderMd(box, src) {
    const text = (src || "").trim();
    if (!text) { box.innerHTML = ""; return; }
    // Sanitize even though it is the author's own text — it arrives from a public bucket.
    box.innerHTML = (window.marked && window.DOMPurify)
      ? DOMPurify.sanitize(marked.parse(text, { breaks: true }))
      : text.replace(/[<>&]/g, (c) => ({ "<": "&lt;", ">": "&gt;", "&": "&amp;" }[c]));
  }

  async function fetchArtist(id) {
    if (artistCache.has(id)) return artistCache.get(id);
    let p = null;
    try {
      const r = await fetch(`${ARTISTS_BASE}/${encodeURIComponent(id)}.json`, { cache: "no-store" });
      if (r.ok) p = await r.json();
    } catch (_) { /* no profile published yet */ }
    artistCache.set(id, p);
    return p;
  }

  // Perceived luminance (BT.601) decides whether an authored backdrop needs light text.
  function isDarkHex(hex) {
    if (!/^#[0-9a-f]{6}$/i.test(hex || "")) return false;
    const n = parseInt(hex.slice(1), 16);
    return (0.299 * ((n >> 16) & 255) + 0.587 * ((n >> 8) & 255) + 0.114 * (n & 255)) / 255 < 0.55;
  }
  function themeSheet(el, hex) {
    el.classList.toggle("themed", !!hex);
    el.classList.toggle("on-dark", isDarkHex(hex));
    el.style.background = hex || "";
  }

  /// The walk's backdrop: "artist" follows the artist's page colour, a hex is used as-is, and
  /// anything else (absent) leaves the player's own sheet colour alone.
  async function introBackdrop(mapData, known) {
    const raw = mapData.introColor;
    if (raw === "artist") {
      if (!known || !known.artistId) return null;
      const p = await fetchArtist(known.artistId);
      return (p && p.bgColor) || null;
    }
    return /^#[0-9a-f]{6}$/i.test(raw || "") ? raw : null;
  }

  async function showIntroCard(mapData, known, force) {
    const id = known ? known.id : (walk && walk.id);
    const seenKey = "introCard.seen." + id;
    if (!force) {
      const last = Number(localStorage.getItem(seenKey) || 0);
      if (last && Date.now() - last < INTRO_CARD_MS) return;
    }
    $("introTitle").textContent = mapData.name || "Soundwalk";
    const by = $("introBy");
    by.innerHTML = "";
    const creator = (known && known.creator) || mapData.creator || "";
    if (creator) {
      by.append(document.createTextNode("by "));
      if (known && known.artistId) {
        const a = document.createElement("button");
        a.className = "artist-link"; a.textContent = creator;
        a.onclick = () => { closeIntro(); openArtist(known.artistId, creator); };
        by.append(a);
      } else by.append(document.createTextNode(creator));
      by.hidden = false;
    } else by.hidden = true;

    renderMd($("introAbout"), (known && known.about) || mapData.about || "");
    themeSheet($("introSheet"), await introBackdrop(mapData, known));
    $("introOverlay").hidden = false;
  }
  function closeIntro() {
    const id = walk && walk.id;
    if (id) { try { localStorage.setItem("introCard.seen." + id, String(Date.now())); } catch (_) {} }
    $("introOverlay").hidden = true;
  }

  async function openArtist(artistId, fallbackName) {
    $("artistName").textContent = fallbackName || "Artist";
    $("artistBio").innerHTML = "";
    $("artistWalks").innerHTML = "";
    $("artistWalksHead").hidden = true;
    themeSheet($("artistSheet"), null);
    $("artistOverlay").hidden = false;

    const p = await fetchArtist(artistId);
    if (p && p.name) $("artistName").textContent = p.name;
    renderMd($("artistBio"), (p && p.bio) || "");
    if (!(p && p.bio)) $("artistBio").innerHTML = "<p class='empty'>This artist hasn't written a bio yet.</p>";
    themeSheet($("artistSheet"), (p && p.bgColor) || null);

    const mine = manifestWalks.filter((w) => w.artistId === artistId);
    if (mine.length) {
      const head = $("artistWalksHead");
      head.textContent = "Walks by " + ((p && p.name) || fallbackName || "this artist");
      head.hidden = false;
      const box = $("artistWalks");
      for (const w of mine) {
        const row = document.createElement("button"); row.className = "walk-row";
        row.innerHTML = `<div class="art"></div><div class="info"><h4></h4><div class="meta"></div></div><div class="go">›</div>`;
        const art = row.querySelector(".art");
        if (w.artUrl) {
          const img = document.createElement("img"); img.src = w.artUrl; img.alt = ""; img.loading = "lazy";
          img.onerror = () => { art.classList.add("art-empty"); img.remove(); };
          art.append(img);
        } else art.classList.add("art-empty");
        row.querySelector("h4").textContent = w.name || w.id;
        row.querySelector(".meta").textContent = `${w.shapeCount || 0} areas`;
        row.onclick = () => { $("artistOverlay").hidden = true; closePicker(); loadWalk(w.id); };
        box.append(row);
      }
    }
  }

  // ---- transportable walks -------------------------------------------------------------------
  // A walk carrying `startAnchor` is moved and turned so the anchor lands on the listener, facing
  // the way they face. Distances and relative bearings are preserved, so it plays as composed.
  const M_PER_DEG_LAT = 110540;
  const mPerDegLng = (lat) => 111320 * Math.cos(lat * Math.PI / 180);

  function transposeWalk(mapData, here, headingDeg) {
    const a = mapData.startAnchor;
    if (!a || !here) return mapData;
    const turn = ((headingDeg || 0) - (a.heading || 0)) * Math.PI / 180;
    const cs = Math.cos(turn), sn = Math.sin(turn);
    const move = ([lat, lng]) => {
      const east = (lng - a.lng) * mPerDegLng(a.lat);
      const north = (lat - a.lat) * M_PER_DEG_LAT;
      const e2 = east * cs + north * sn;
      const n2 = north * cs - east * sn;
      return [here[0] + n2 / M_PER_DEG_LAT, here[1] + e2 / mPerDegLng(here[0])];
    };
    const out = { ...mapData };
    if (Array.isArray(mapData.center) && mapData.center.length === 2) out.center = move(mapData.center);
    out.shapes = (mapData.shapes || []).map((sh) => {
      const c = { ...sh };
      if (Array.isArray(sh.center) && sh.center.length === 2) c.center = move(sh.center);
      if (Array.isArray(sh.points)) c.points = sh.points.map(move);
      return c;
    });
    // Routes travel with the walk — a suggested path left behind in the authoring city is worse
    // than none at all.
    out.routes = (mapData.routes || []).map((r) => ({ ...r, points: (r.points || []).map(move) }));
    // Labels travel with the walk for the same reason routes do.
    out.labels = (mapData.labels || [])
      .map((l) => (Array.isArray(l.point) ? { ...l, point: move(l.point) } : l));
    return out;
  }

  /// One compass reading, if the browser will give us one. Resolves to null quickly otherwise —
  /// without a heading we still place the walk, just without turning it.
  function readHeadingOnce(timeoutMs = 1200) {
    return new Promise((resolve) => {
      if (typeof window.DeviceOrientationEvent === "undefined") return resolve(null);
      let done = false;
      const finish = (v) => {
        if (done) return;
        done = true;
        window.removeEventListener("deviceorientationabsolute", onEvt);
        window.removeEventListener("deviceorientation", onEvt);
        resolve(v);
      };
      const onEvt = (e) => {
        if (typeof e.webkitCompassHeading === "number") return finish(e.webkitCompassHeading);
        if (e.absolute && typeof e.alpha === "number") return finish((360 - e.alpha) % 360);
      };
      window.addEventListener("deviceorientationabsolute", onEvt);
      window.addEventListener("deviceorientation", onEvt);
      setTimeout(() => finish(null), timeoutMs);
    });
  }

  function currentPosition(timeoutMs = 6000) {
    if (userCoord) return Promise.resolve(userCoord);
    if (!navigator.geolocation) return Promise.resolve(null);
    return new Promise((resolve) => {
      navigator.geolocation.getCurrentPosition(
        (p) => resolve([p.coords.latitude, p.coords.longitude]),
        () => resolve(null),
        { enableHighAccuracy: true, timeout: timeoutMs, maximumAge: 30000 });
    });
  }

  /// Frame the whole walk. map.json's `zoom` is the author's editing view, so it tends to crop a
  /// large walk and over-zoom a small one; the shapes themselves are the better guide.
  function fitToWalk(mapData) {
    const pts = [];
    for (const sh of mapData.shapes || []) {
      if (Array.isArray(sh.center) && sh.center.length === 2) {
        const r = sh.radius || 0;
        const dLat = r / 111000, dLng = r / (111000 * Math.max(0.2, Math.cos(sh.center[0] * Math.PI / 180)));
        pts.push([sh.center[0] - dLat, sh.center[1] - dLng], [sh.center[0] + dLat, sh.center[1] + dLng]);
      }
      for (const p of sh.points || []) if (p.length === 2) pts.push(p);
    }
    for (const r of mapData.routes || []) for (const p of r.points || []) if (p.length === 2) pts.push(p);
    for (const l of mapData.labels || []) if (Array.isArray(l.point) && l.point.length === 2) pts.push(l.point);
    if (pts.length) lmap.fitBounds(L.latLngBounds(pts).pad(0.18), { maxZoom: 18 });
    else if (Array.isArray(mapData.center)) lmap.setView(mapData.center, mapData.zoom || 16);
  }

  // ---- picker overlay ----
  function openPicker() { $("pickerOverlay").hidden = false; loadCatalog(); }
  function closePicker() { $("pickerOverlay").hidden = true; }

  // ---- ui helpers ----
  let statusTimer = null;
  function setStatus(t) { const s = $("status"); s.textContent = t; s.hidden = !t; }
  let toastTimer = null;
  function toast(msg, kind) { const t = $("toast"); t.textContent = msg; t.className = kind || ""; t.hidden = false; clearTimeout(toastTimer); toastTimer = setTimeout(() => t.hidden = true, 3500); }

  // ---- wiring ----
  $("playBtn").onclick = () => { if (!$("introOverlay").hidden) closeIntro(); toggle(); };
  $("exploreGo").onclick = enterExplore;
  $("exploreStay").onclick = () => { $("exploreOverlay").hidden = true; };
  $("exploreClose").onclick = () => { $("exploreOverlay").hidden = true; };
  $("exploreSpeed").onchange = (e) => {
    exploreSpeed = e.target.value;
    if (exploreSpeed === "teleport") stopExploreMove();
    else if (exPos && exTarget && haversine(exPos, exTarget) > 0.3) startExploreMove();
  };
  $("skipBackBtn").onclick = () => skip(-SKIP_S);
  $("skipFwdBtn").onclick = () => skip(SKIP_S);
  $("doneBtn").onclick = endSession;
  // Phone menu. Closes after any choice, and on any tap outside it, so it never sits over the map.
  const closeMenu = () => {
    document.body.classList.remove("menu-open");
    $("menuBtn").setAttribute("aria-expanded", "false");
  };
  $("menuBtn").onclick = (e) => {
    e.stopPropagation();
    const open = !document.body.classList.contains("menu-open");
    document.body.classList.toggle("menu-open", open);
    $("menuBtn").setAttribute("aria-expanded", String(open));
  };
  $("headerTools").onclick = (e) => { if (e.target.tagName !== "SELECT") closeMenu(); };
  document.addEventListener("click", (e) => {
    if (!document.body.classList.contains("menu-open")) return;
    if (!$("headerTools").contains(e.target) && e.target !== $("menuBtn")) closeMenu();
  });

  $("browseBtn").onclick = openPicker;
  // The title reopens the current walk's card (as in the app); the browse button stays the only
  // route to the full list.
  $("titleBtn").onclick = () => {
    if (walk) showIntroCard(walk.map, manifestWalks.find((x) => x.id === walk.id), true);
    else openPicker();
  };
  $("welcomeBrowse").onclick = openPicker;
  $("pickerClose").onclick = closePicker;
  $("pickerRefresh").onclick = loadCatalog;
  $("introClose").onclick = closeIntro;
  $("artistClose").onclick = () => { $("artistOverlay").hidden = true; };
  // Pressing play dismisses the card, exactly like the app's play button.
  $("introOverlay").onclick = (e) => { if (e.target === $("introOverlay")) closeIntro(); };
  $("artistOverlay").onclick = (e) => { if (e.target === $("artistOverlay")) $("artistOverlay").hidden = true; };

  // ---- deep link ?walk=<id> ----
  const deepId = new URLSearchParams(location.search).get("walk");
  if (deepId) { $("welcomeOverlay").hidden = true; loadCatalog(); loadWalk(deepId); }
  // The catalog carries creator/artistId/about; once it lands, refresh a card opened before it did.
  window.addEventListener("songitude:catalog", () => {
    if (walk && !$("introOverlay").hidden) {
      showIntroCard(walk.map, manifestWalks.find((x) => x.id === walk.id), true);
    }
  });
})();
