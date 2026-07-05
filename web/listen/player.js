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
  const DONE_DELAY_MS = 30 * 1000;        // show the "All done?" button this long after play starts

  const $ = (id) => document.getElementById(id);
  const walksListEl = $("walksList");

  // ---- map ----
  const lmap = L.map("map", { zoomControl: false }).setView([40.7128, -74.006], 15);
  L.tileLayer("https://{s}.basemaps.cartocdn.com/light_all/{z}/{x}/{y}{r}.png",
    { attribution: "&copy; OpenStreetMap &copy; CARTO", subdomains: "abcd", maxZoom: 20 }).addTo(lmap);

  // ---- state ----
  let ctx = null, masterGain = null;
  let walk = null, shapes = [];
  const buffers = new Map(), loadingFiles = new Set();
  let running = false, syncedStarted = false, userCoord = null;
  let manifestWalks = [];
  let shapeLayers = new Map();
  let dialogueQueue = [], dialoguePlaying = null;   // one dialogue plays at a time; others wait in line
  let outroActive = false, doneTimer = null, introVoice = null, exitVoice = null;   // intro/exit (walk-level) clips
  const dColor = (st) => (walk && walk.map.dialogueColors && walk.map.dialogueColors[st]) || DEFAULT_DIALOGUE_COLORS[st];

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
  function targetGain(s, c) {
    if (s.type === "circle" && s.falloff && s.falloff !== "none" && s.center && s.radius)
      return s.gain * falloffLevel(s.falloff, haversine(s.center, c) / s.radius);
    return s.gain;
  }
  function rampGain(g, target, dur) {
    const t = ctx.currentTime;
    g.gain.cancelScheduledValues(t); g.gain.setValueAtTime(g.gain.value, t);
    g.gain.linearRampToValueAtTime(Math.max(0.0001, target), t + Math.max(0.01, dur));
  }
  // A crossfade loop: overlapping copies of `buf` under `destGain`, each fading in as the previous
  // fades out. Returns an object with stop(when), so it drops into the same slot as a looping source.
  function makeCrossfadeLoop(buf, crossfade, destGain) {
    const D = buf.duration;
    const C = Math.min(Math.max(0.05, crossfade || 1), D * 0.5);   // clamp to ≤ half the clip
    const period = Math.max(0.05, D - C);
    const active = new Set();
    let nextStart = ctx.currentTime, first = true, stopAt = Infinity, torn = false;
    const scheduleCopy = (startAt) => {
      const src = ctx.createBufferSource(); src.buffer = buf;
      const cg = ctx.createGain();
      if (first) { cg.gain.setValueAtTime(1, startAt); first = false; }
      else { cg.gain.setValueAtTime(0.0001, startAt); cg.gain.linearRampToValueAtTime(1, startAt + C); }
      cg.gain.setValueAtTime(1, startAt + D - C);
      cg.gain.linearRampToValueAtTime(0.0001, startAt + D);
      src.connect(cg).connect(destGain);
      src.start(startAt); src.stop(startAt + D + 0.05);
      active.add(src); src.onended = () => active.delete(src);
    };
    const tick = () => {
      if (torn) return;
      const ahead = Math.min(ctx.currentTime + 0.4, stopAt);
      while (nextStart < ahead) { scheduleCopy(nextStart); nextStart += period; }
    };
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
  function startLoop(s, c) {
    const buf = buffers.get(s.audioFile); if (!buf) return;
    const g = ctx.createGain(); g.gain.setValueAtTime(0.0001, ctx.currentTime);
    g.gain.linearRampToValueAtTime(Math.max(0.0001, targetGain(s, c)), ctx.currentTime + Math.max(0.01, s.fadeIn));
    g.connect(masterGain);
    s._rt.gain = g;
    if (s.loopMode === "crossfade") {
      s._rt.source = makeCrossfadeLoop(buf, s.crossfade, g);
    } else {
      const src = ctx.createBufferSource(); src.buffer = buf; src.loop = true;
      src.connect(g); src.start();
      s._rt.source = src;
    }
  }
  function updateLoopGain(s, c) {
    if (s.type === "circle" && s.falloff && s.falloff !== "none" && s._rt.gain) rampGain(s._rt.gain, targetGain(s, c), 0.12);
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
    const g = ctx.createGain(); g.gain.value = s.gain; src.connect(g).connect(masterGain);
    src.onended = () => { if (s._rt && s._rt.source === src) { s._rt.source = null; s._rt.gain = null; reflectSounding(); } };
    src.start(); s._rt.source = src; s._rt.gain = g;
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
    const g = ctx.createGain(); g.gain.value = s.gain; src.connect(g).connect(masterGain);
    src.onended = () => { if (s._rt && s._rt.source === src) { s._rt.source = null; s._rt.gain = null; onDialogueFinished(s); } };
    src.start(); s._rt.source = src; s._rt.gain = g;
    reflectSounding();
  }
  function onDialogueFinished(s) {
    if (dialoguePlaying === s.id) dialoguePlaying = null;
    if (s._rt) { s._rt.source = null; s._rt.gain = null; s._rt.dstate = "finished"; }
    reflectSounding();
    advanceDialogue();
  }

  // ---- intro / exit (walk-level) clips ----
  const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
  function playClipOnce(buf, gain, onended) {
    const src = ctx.createBufferSource(); src.buffer = buf;
    const g = ctx.createGain(); g.gain.value = gain; src.connect(g).connect(masterGain);
    if (onended) src.onended = onended;
    src.start();
    return { src, g };
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
    await ensureBuffer(file);
    const buf = buffers.get(file); if (!buf || !running) return;
    try { localStorage.setItem(key, String(Date.now())); } catch (_) {}
    if (introVoice) { try { introVoice.src.stop(); } catch (_) {} }
    introVoice = playClipOnce(buf, walk.map.introGain ?? 1, () => { introVoice = null; });
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
  function startSyncedIfReady() {
    if (!running || syncedStarted) return;
    const files = syncedFiles(); if (!files.length) { syncedStarted = true; return; }
    if (!files.every((f) => buffers.has(f))) return;
    const startAt = ctx.currentTime + 0.15;
    for (const s of shapes) {
      if (s.mode !== "syncedLoop" || !s.audioFile || (s._rt && s._rt.source)) continue;
      const buf = buffers.get(s.audioFile); if (!buf) continue;
      if (!s._rt) s._rt = { inside: false, armed: true, source: null, gain: null, dstate: "unplayed" };
      const src = ctx.createBufferSource(); src.buffer = buf; src.loop = true;
      const g = ctx.createGain(); g.gain.setValueAtTime(0, ctx.currentTime);
      src.connect(g).connect(masterGain); src.start(startAt);
      s._rt.source = src; s._rt.gain = g;
    }
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
    for (const s of shapes) {
      if (!s._rt) s._rt = { inside: false, armed: true, source: null, gain: null, dstate: "unplayed" };
      const rt = s._rt, nowIn = inside.has(s.id), rising = nowIn && !rt.inside;
      if (s.mode === "loop") {
        if (nowIn && !rt.source) startLoop(s, c);
        else if (nowIn && rt.source) updateLoopGain(s, c);
        else if (!nowIn && rt.source) stopLoop(s);
      } else if (s.mode === "syncedLoop") {
        if (rt.source) {
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
        layer.setStyle({ color: col, fillColor: col, fillOpacity: DIALOGUE_STATE_OPACITY[st], weight: st === "playing" ? 3 : 2 });
      } else {
        const on = !!(s._rt && s._rt.source && (!s._rt.gain || s._rt.gain.gain.value > 0.01));
        layer.setStyle({ fillOpacity: on ? 0.5 : 0.2, weight: on ? 3 : 2 });
      }
    }
  }

  // ---- shapes on map ----
  function drawShapes() {
    shapeLayers.forEach((l) => lmap.removeLayer(l)); shapeLayers.clear();
    for (const s of shapes) {
      const base = s.mode === "dialogue" ? dColor("unplayed") : (s.color || "#4363d8");
      const fo = s.mode === "dialogue" ? DIALOGUE_STATE_OPACITY.unplayed : 0.2;
      const style = { color: base, weight: 2, fillColor: base, fillOpacity: fo };
      let layer = null;
      if (s.type === "circle" && s.center && s.radius != null) layer = L.circle(s.center, { radius: s.radius, ...style });
      else if (s.type === "polygon" && s.points && s.points.length >= 3) layer = L.polygon(s.points, style);
      if (layer) { layer.addTo(lmap); shapeLayers.set(s.id, layer); }
    }
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
  function onFix(pos) { const c = [pos.coords.latitude, pos.coords.longitude]; updateUserMarker(c); ingestFix(c); }
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
    if (e.code === 1) { toast("Location permission denied — enable it to hear the walk.", "err"); stop(); }
    else toast("Location error: " + e.message, "err");
  }
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
      navigator.mediaSession.metadata = new MediaMetadata({ title: walk.map.name || "Sound walk", artist: walk.map.creator || "Songitude", artwork: art });
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
    running = true; syncedStarted = false; userCoord = null;
    dialogueQueue = []; dialoguePlaying = null;
    for (const s of shapes) s._rt = { inside: false, armed: true, source: null, gain: null, dstate: "unplayed" };
    syncedFiles().forEach(ensureBuffer);   // synced loops load immediately, start when all ready
    startSyncedIfReady();
    startWatch();
    acquireWake(); setMediaPlaying(true);
    // Reset the end-session UI and arm the "All done?" button; play the intro (gated per walk).
    outroActive = false;
    $("doneBtn").hidden = true; $("doneBtn").disabled = false;
    clearTimeout(doneTimer);
    doneTimer = setTimeout(() => { if (running) $("doneBtn").hidden = false; }, DONE_DELAY_MS);
    maybePlayIntro();
    renderPlay(); setStatus("Listening — keep this page open and your screen on. 🎧");
  }
  function stop() {
    running = false; syncedStarted = false;
    stopWatch(); virtual = null;
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
  }

  // ---- catalog + walk loading ----
  function dist(w, here) { return (w.center && here) ? haversine(w.center, here) : Infinity; }
  function fmtDist(m) { return m < 1000 ? Math.round(m) + " m" : (m / 1000).toFixed(1) + " km"; }
  function loadCatalog() {
    walksListEl.innerHTML = "<p class='empty'>Loading…</p>";
    fetch(MANIFEST_URL, { cache: "no-store" }).then((r) => r.json())
      .then((m) => { manifestWalks = m.walks || []; renderPicker(); })
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
      row.innerHTML = `<div class="info"><h4></h4><div class="meta"></div></div><div class="go">›</div>`;
      row.querySelector("h4").textContent = w.name || w.id;
      row.querySelector(".meta").textContent =
        `${w.creator ? w.creator + " · " : ""}${d != null ? fmtDist(d) + " · " : ""}${w.shapeCount || 0} areas`;
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
      const mapData = await (await fetch(`${base}/map.json`, { cache: "no-store" })).json();
      walk = { id, base, map: mapData };
      shapes = (mapData.shapes || []).map((s) => ({ ...s, _rt: null }));
      buffers.clear(); loadingFiles.clear(); syncedStarted = false;
      dialogueQueue = []; dialoguePlaying = null;
      drawShapes();
      if (Array.isArray(mapData.center)) lmap.setView(mapData.center, mapData.zoom || 16);
      $("titleBtn").textContent = (mapData.name || "Sound walk") + " ▾";
      setMediaMeta();
      $("playBtn").disabled = false;
      $("welcomeOverlay").hidden = true;
      setStatus("Ready — press play, then start walking.");
    } catch (e) { toast("Couldn't load that walk: " + e.message, "err"); }
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
  $("playBtn").onclick = toggle;
  $("doneBtn").onclick = endSession;
  $("browseBtn").onclick = openPicker;
  $("titleBtn").onclick = openPicker;
  $("welcomeBrowse").onclick = openPicker;
  $("pickerClose").onclick = closePicker;
  $("pickerRefresh").onclick = loadCatalog;

  // ---- deep link ?walk=<id> ----
  const deepId = new URLSearchParams(location.search).get("walk");
  if (deepId) { $("welcomeOverlay").hidden = true; loadCatalog(); loadWalk(deepId); }
})();
