/* Songitude — editor
 * Front-end only. No server, no build step.
 * State lives in memory; Export/Import move it in and out of a .zip bundle
 * whose format is shared with the iOS app (see ../shared/FORMAT.md).
 */
(() => {
  "use strict";

  // ---------------------------------------------------------------- state ----
  const state = {
    mode: "edit",              // "edit" | "listen"
    tool: "select",            // "select" | "polygon" | "circle"
    name: "",
    creator: "",
    about: "",
    walkId: null,              // set if this document is a published walk the user owns (update vs new)
    center: [40.7128, -74.006],
    zoom: 15,
    shapes: [],                // see makeShape()
    selectedIds: new Set(),    // multi-selection
    albumArt: null,            // { name, blob, url } | null
    listenSpeed: "walking",    // "walking" | "running" | "teleport"
  };
  // metres / second — walk, run, bike (~24 km/h), drive (~48 km/h). Teleport is instant.
  const LISTEN_SPEED = { walking: 1.4, running: 3.5, biking: 6.7, driving: 13.4 };

  // Fixed color per shape type so the map reads consistently: circles red, polygons blue.
  // (Individual shapes can still be recolored via the swatch.)
  const SHAPE_COLORS = { circle: "#e6194b", polygon: "#4363d8" };
  let shapeCounter = 0;

  // filename -> { blob, url }
  const audioStore = new Map();
  // filename -> AudioBuffer (decoded lazily for listen mode)
  const decoded = new Map();
  // album-art blobs kept by name so undo/redo can restore a previous cover
  const artStore = new Map();

  // ---- undo/redo history: JSON snapshots of the editable state ----------
  const HISTORY_LIMIT = 500;   // ample; well beyond the 50-step minimum
  let undoStack = [], redoStack = [], currentSnap = null;
  let dirty = false;           // unexported edits present? (drives the "download your work" warning)

  // ----------------------------------------------------------------- dom ----
  const $ = (id) => document.getElementById(id);
  const mapEl = $("map");

  // ----------------------------------------------------------------- map ----
  const map = L.map(mapEl, { zoomControl: true }).setView(state.center, state.zoom);
  L.tileLayer("https://{s}.basemaps.cartocdn.com/light_all/{z}/{x}/{y}{r}.png", {
    attribution: '&copy; OpenStreetMap &copy; CARTO',
    subdomains: "abcd", maxZoom: 20,
  }).addTo(map);

  // ============================================================ SHAPE MODEL ==
  function makeShape(type, geom) {
    shapeCounter += 1;
    const color = SHAPE_COLORS[type] || "#4363d8";
    const shape = {
      id: "s_" + Math.abs(hashStr(type + shapeCounter + color)).toString(36),
      name: `Area ${shapeCounter}`,
      type,                          // "circle" | "polygon"
      color,
      audioFile: null,
      mode: "loop",                  // "loop" | "oneshot" | "dialogue"
      gain: 1.0,
      fadeIn: 2.0,
      fadeOut: 3.0,
      falloff: "none",               // circle loops: "none" | "linear" | "exponential" | "edge"
      layer: null,
      _rt: null,                     // listen-mode runtime, see engine
      ...geom,                       // circle: {center:[lat,lng], radius} | polygon: {points:[[lat,lng]...]}
    };
    buildLayer(shape);
    state.shapes.push(shape);
    return shape;
  }

  function buildLayer(shape) {
    if (shape.layer) { map.removeLayer(shape.layer); shape.layer = null; }
    const style = { color: shape.color, weight: 2, fillColor: shape.color, fillOpacity: 0.25 };
    let layer;
    if (shape.type === "circle") {
      layer = L.circle(shape.center, { radius: shape.radius, ...style });
    } else {
      layer = L.polygon(shape.points, style);
    }
    // In select mode, mousedown begins a drag (move); a mousedown with no movement is treated
    // as a click and (de)selects. startShapeDrag handles both.
    layer.on("mousedown", (e) => {
      if (state.mode !== "edit" || state.tool !== "select") return;
      L.DomEvent.stop(e);
      startShapeDrag(shape, e);
    });
    layer.addTo(map);
    shape.layer = layer;
  }

  function shapeById(id) { return state.shapes.find((s) => s.id === id); }

  // ---- selection (multi) ------------------------------------------------
  function selectOnly(id) { state.selectedIds = new Set([id]); applySelection(); scrollToCard(id); }
  function toggleSelection(id) {
    if (state.selectedIds.has(id)) state.selectedIds.delete(id); else state.selectedIds.add(id);
    applySelection();
  }
  function setSelection(ids) { state.selectedIds = new Set(ids); applySelection(); }
  function clearSelection() { if (state.selectedIds.size) { state.selectedIds.clear(); applySelection(); } }

  function applySelection() {
    // Update card highlight + shape outline in place (no DOM rebuild → keeps input focus).
    document.querySelectorAll(".card").forEach((c) =>
      c.classList.toggle("selected", state.selectedIds.has(c.dataset.id)));
    for (const s of state.shapes) if (s.layer) s.layer.setStyle({ weight: state.selectedIds.has(s.id) ? 4 : 2 });
    updateBulkBar();
    refreshEditHandles();
  }
  function scrollToCard(id) {
    const card = document.querySelector(`.card[data-id="${id}"]`);
    if (card) card.scrollIntoView({ behavior: "smooth", block: "nearest" });
  }
  function updateBulkBar() {
    const n = state.selectedIds.size;
    $("selBar").hidden = n === 0;
    $("selCount").textContent = n + " selected";
  }

  // ---- delete (with confirmation) ---------------------------------------
  function removeShape(id) {
    const s = shapeById(id); if (!s) return;
    engine.stopShape(s);
    if (s.layer) map.removeLayer(s.layer);
    state.shapes = state.shapes.filter((x) => x.id !== id);
    state.selectedIds.delete(id);
  }
  function deleteShape(id) {
    const s = shapeById(id); if (!s) return;
    if (!confirm(`Delete “${s.name}”?\n\nThis removes the sound area and its audio assignment.`)) return;
    removeShape(id);
    renderSide();
    commit();
  }
  function bulkDelete() {
    const ids = [...state.selectedIds];
    if (!ids.length) return;
    const msg = ids.length === 1
      ? `Delete “${shapeById(ids[0])?.name || "this area"}”?`
      : `Delete ${ids.length} sound areas? This removes them and their audio assignments.`;
    if (!confirm(msg + "\n\n(You can undo this with ⌘Z.)")) return;
    ids.forEach(removeShape);
    state.selectedIds.clear();
    renderSide();
    commit();
  }

  // ---- moving shapes ----------------------------------------------------
  function translateShape(s, dLat, dLng) {
    if (s.type === "circle") {
      s.center = [s.center[0] + dLat, s.center[1] + dLng];
      if (s.layer) s.layer.setLatLng(s.center);
    } else {
      s.points = s.points.map(([la, ln]) => [la + dLat, ln + dLng]);
      if (s.layer) s.layer.setLatLngs(s.points);
    }
  }
  function shapeAnchor(s) {
    if (s.type === "circle") return L.latLng(s.center[0], s.center[1]);
    const n = s.points.length;
    return L.latLng(s.points.reduce((a, p) => a + p[0], 0) / n,
                    s.points.reduce((a, p) => a + p[1], 0) / n);
  }
  // Drag a shape (or, if it's part of a multi-selection, the whole group).
  function startShapeDrag(shape, e) {
    const oe = e.originalEvent || {};
    const group = (state.selectedIds.has(shape.id) && state.selectedIds.size > 1)
      ? [...state.selectedIds].map(shapeById).filter(Boolean)
      : [shape];
    map.dragging.disable();
    let last = e.latlng, moved = false;
    const onMove = (ev) => {
      const dLat = ev.latlng.lat - last.lat, dLng = ev.latlng.lng - last.lng;
      if (Math.abs(dLat) > 1e-12 || Math.abs(dLng) > 1e-12) moved = true;
      last = ev.latlng;
      for (const s of group) translateShape(s, dLat, dLng);
      for (const h of editHandles) { const p = h.getLatLng(); h.setLatLng([p.lat + dLat, p.lng + dLng]); }
    };
    const onUp = () => {
      map.off("mousemove", onMove);
      map.dragging.enable();
      if (!moved) { // a click, not a drag → (de)select
        if (oe.shiftKey || oe.metaKey || oe.ctrlKey) toggleSelection(shape.id);
        else selectOnly(shape.id);
      } else {
        commit();   // record the move
      }
    };
    map.on("mousemove", onMove);
    map.once("mouseup", onUp);
  }

  // ---- vertex / radius editing handles (single selection) ---------------
  let editHandles = [];
  function clearEditHandles() {
    if (!editHandles.length) return;
    editHandles.forEach((h) => map.removeLayer(h));
    editHandles = [];
  }
  function handleIcon(kind, color) {
    const style = kind === "radius" ? `background:#fff;box-shadow:0 0 0 2px ${color}` : `background:${color}`;
    return L.divIcon({ className: "edit-handle " + kind, html: `<i style="${style}"></i>`,
                       iconSize: [15, 15], iconAnchor: [7.5, 7.5] });
  }
  // A point `dist` metres from [lat,lng] along `bearing`° — used to seat the circle's radius grip.
  function destPoint([lat, lng], dist, bearing) {
    const R = 6378137, br = bearing * Math.PI / 180, dr = dist / R;
    const la1 = lat * Math.PI / 180, ln1 = lng * Math.PI / 180;
    const la2 = Math.asin(Math.sin(la1) * Math.cos(dr) + Math.cos(la1) * Math.sin(dr) * Math.cos(br));
    const ln2 = ln1 + Math.atan2(Math.sin(br) * Math.sin(dr) * Math.cos(la1),
                                 Math.cos(dr) - Math.sin(la1) * Math.sin(la2));
    return [la2 * 180 / Math.PI, ln2 * 180 / Math.PI];
  }
  function newHandle(latlng, kind, color) {
    return L.marker(latlng, { icon: handleIcon(kind, color), draggable: true, keyboard: false,
                              zIndexOffset: 1200 }).addTo(map);
  }
  // Draggable handles for the single selected shape: polygon vertices, or a circle's centre
  // plus a grip on its perimeter (random bearing) that sets the radius.
  function refreshEditHandles() {
    clearEditHandles();
    if (state.mode !== "edit" || draw || state.selectedIds.size !== 1) return;
    const s = shapeById([...state.selectedIds][0]);
    if (!s || !s.layer) return;
    if (s.type === "polygon") buildPolygonHandles(s);
    else if (s.type === "circle") buildCircleHandles(s);
  }
  function buildPolygonHandles(s) {
    s.points.forEach((pt, i) => {
      const h = newHandle(pt, "vertex", s.color);
      h.on("drag", () => { const ll = h.getLatLng(); s.points[i] = [ll.lat, ll.lng]; s.layer.setLatLngs(s.points); });
      h.on("dragend", () => commit());
      editHandles.push(h);
    });
  }
  function buildCircleHandles(s) {
    const ctr = newHandle(s.center, "center", s.color);
    const grip = newHandle(destPoint(s.center, s.radius, Math.random() * 360), "radius", s.color);
    ctr.on("drag", () => {
      const ll = ctr.getLatLng();
      const dLat = ll.lat - s.center[0], dLng = ll.lng - s.center[1];
      s.center = [ll.lat, ll.lng]; s.layer.setLatLng(s.center);
      const g = grip.getLatLng(); grip.setLatLng([g.lat + dLat, g.lng + dLng]);
    });
    grip.on("drag", () => { s.radius = Math.max(3, map.distance(s.center, grip.getLatLng())); s.layer.setRadius(s.radius); });
    ctr.on("dragend", () => commit());
    grip.on("dragend", () => commit());
    editHandles.push(ctr, grip);
  }

  // ---- redraw an existing polygon ---------------------------------------
  function startRedraw(id) {
    const s = shapeById(id);
    if (!s || s.type !== "polygon") return;
    setTool("polygon");
    draw = { kind: "polygon", points: [], temp: [], redrawId: id,
             rubber: L.polyline([], { color: SHAPE_COLORS.polygon, weight: 2, dashArray: "5,5" }).addTo(map) };
    if (s.layer) s.layer.setStyle({ opacity: 0.3, fillOpacity: 0.05 }); // dim original while redrawing
    toast("Redrawing — click new points, click the first point to close.", "ok");
  }

  // ---- proximity falloff (circle loops) ---------------------------------
  // r = distance/radius in [0,1]. Returns a 0..1 multiplier on the shape's gain.
  function falloffLevel(mode, r) {
    r = Math.max(0, Math.min(1, r));
    switch (mode) {
      case "linear":      return 1 - r;
      case "exponential": return (1 - r) * (1 - r);
      case "edge":        return r <= 0.5 ? 1 : Math.max(0, 2 * (1 - r)); // flat inner half, ramp outer half
      default:            return 1;
    }
  }

  // ============================================================== DRAWING ===
  let draw = null; // transient drawing state

  function setTool(tool) {
    cancelDraw();
    state.tool = tool;
    ["Select", "Polygon", "Circle"].forEach((t) =>
      $("tool" + t).classList.toggle("active", tool === t.toLowerCase()));
    const hints = {
      select: "",
      polygon: "Click to drop each vertex. Click the first point to close. Backspace undoes the last point.",
      circle: "Click to set the center, then click again to set the radius.",
    };
    $("toolHint").textContent = hints[tool];
    mapEl.style.cursor = tool === "select" ? "" : "crosshair";
    refreshEditHandles();
  }

  function cancelDraw() {
    if (!draw) return;
    (draw.temp || []).forEach((l) => map.removeLayer(l));
    if (draw.rubber) map.removeLayer(draw.rubber);
    if (draw.redrawId) { const s = shapeById(draw.redrawId); if (s) buildLayer(s); } // restore dimmed original
    draw = null;
  }

  map.on("click", (e) => {
    if (state.mode === "listen") { placeListener(e.latlng); return; }
    if (state.tool === "polygon") polygonClick(e.latlng);
    else if (state.tool === "circle") circleClick(e.latlng);
    else if (state.tool === "select") {
      // Plain click on empty map clears the selection; Shift-click leaves it (used with marquee).
      if (!(e.originalEvent && e.originalEvent.shiftKey)) clearSelection();
    }
  });

  // Shift-drag on empty map = marquee box select. (Plain drag still pans the map.)
  map.on("mousedown", (e) => {
    if (state.mode !== "edit" || state.tool !== "select") return;
    if (!(e.originalEvent && e.originalEvent.shiftKey)) return;
    L.DomEvent.stop(e);
    map.dragging.disable();
    const start = e.latlng;
    const rect = L.rectangle([start, start],
      { color: "#2f6bff", weight: 1, dashArray: "4,4", fillOpacity: 0.08 }).addTo(map);
    const onMove = (ev) => rect.setBounds(L.latLngBounds(start, ev.latlng));
    const onUp = (ev) => {
      map.off("mousemove", onMove);
      map.dragging.enable();
      const bounds = L.latLngBounds(start, ev.latlng);
      map.removeLayer(rect);
      setSelection(state.shapes.filter((s) => bounds.contains(shapeAnchor(s))).map((s) => s.id));
    };
    map.on("mousemove", onMove);
    map.once("mouseup", onUp);
  });

  map.on("mousemove", (e) => {
    if (state.mode !== "edit" || !draw) return;
    if (draw.kind === "polygon" && draw.points.length) {
      const pts = draw.points.concat([e.latlng]);
      if (draw.rubber) draw.rubber.setLatLngs(pts);
    } else if (draw.kind === "circle" && draw.center) {
      draw.previewRadius = map.distance(draw.center, e.latlng);
      draw.circle.setRadius(draw.previewRadius);
    }
  });

  document.addEventListener("keydown", (e) => {
    if (e.key !== "Escape") return;
    closeColorPopover();
    if (draw) setTool("select");   // fully exit an in-progress circle/polygon (bail on accidental draws)
  });

  function polygonClick(latlng) {
    if (!draw) {
      clearEditHandles();
      draw = { kind: "polygon", points: [], temp: [], rubber: null };
      draw.rubber = L.polyline([], { color: SHAPE_COLORS.polygon, weight: 2, dashArray: "5,5" }).addTo(map);
    }
    // Close if clicking near the first vertex.
    if (draw.points.length >= 3) {
      const p0 = map.latLngToContainerPoint(draw.points[0]);
      const pc = map.latLngToContainerPoint(latlng);
      if (p0.distanceTo(pc) < 14) { finishPolygon(); return; }
    }
    draw.points.push(latlng);
    const vtx = L.circleMarker(latlng, { radius: 4, color: SHAPE_COLORS.polygon, fillColor: "#fff", fillOpacity: 1 }).addTo(map);
    draw.temp.push(vtx);
    draw.rubber.setLatLngs(draw.points);
  }

  // Backspace while placing a polygon: pop the most recent vertex off the in-progress stack.
  function undoLastPolygonPoint() {
    if (!draw || draw.kind !== "polygon" || !draw.points.length) return;
    draw.points.pop();
    const vtx = draw.temp.pop();
    if (vtx) map.removeLayer(vtx);
    if (draw.rubber) draw.rubber.setLatLngs(draw.points);
    toast(draw.points.length ? "Removed the last point." : "All points removed — click to start again.", "ok");
  }

  function finishPolygon() {
    const points = draw.points.map((ll) => [ll.lat, ll.lng]);
    const redrawId = draw.redrawId;
    if (redrawId) draw.redrawId = null;   // don't let cancelDraw restore the old outline
    cancelDraw();
    if (points.length < 3) { if (redrawId) buildLayer(shapeById(redrawId)); return; }
    if (redrawId) {
      const s = shapeById(redrawId);
      if (s) { s.points = points; buildLayer(s); selectOnly(s.id); commit(); toast("Shape redrawn.", "ok"); }
      setTool("select");
      return;
    }
    const s = makeShape("polygon", { points });
    renderSide();
    selectOnly(s.id);   // stay in polygon mode so you can keep drawing
    commit();
    toast("Polygon added — drop an audio file on its card.", "ok");
  }

  function circleClick(latlng) {
    if (!draw) {
      clearEditHandles();
      draw = { kind: "circle", center: latlng, previewRadius: 0, temp: [] };
      draw.circle = L.circle(latlng, { radius: 0, color: SHAPE_COLORS.circle, weight: 2, dashArray: "5,5", fillOpacity: 0.1 }).addTo(map);
      draw.temp.push(draw.circle);
      return;
    }
    const radius = Math.max(3, map.distance(draw.center, latlng));
    const center = [draw.center.lat, draw.center.lng];
    cancelDraw();
    const s = makeShape("circle", { center, radius });
    renderSide();
    selectOnly(s.id);   // stay in circle mode so you can keep drawing
    commit();
    toast("Circle added — drop an audio file on its card.", "ok");
  }

  // =========================================================== SIDE PANEL ===
  function renderSide() {
    stopLoopPreview();   // buttons get rebuilt; drop any running seam preview
    const list = $("shapeList");
    list.innerHTML = "";
    $("shapeCount").textContent = state.shapes.length;
    $("emptyState").hidden = state.shapes.length > 0;

    for (const s of state.shapes) list.appendChild(cardFor(s));
    reflectSounding();
    updateBulkBar();
  }

  // ---- color picker popover (8 presets + custom RGB) -------------------
  const COLOR_PRESETS = ["#e6194b","#f58231","#ffe119","#3cb44b",
                         "#42d4f4","#4363d8","#911eb4","#f032e6"];
  // Custom colors the user has chosen become reusable swatches (persisted across sessions).
  let customColors = loadCustomColors();
  function loadCustomColors() {
    try { return JSON.parse(localStorage.getItem("songitude.customColors") || "[]"); } catch (_) { return []; }
  }
  function addCustomColor(hex) {
    hex = (hex || "").toLowerCase();
    if (!/^#[0-9a-f]{6}$/.test(hex)) return;
    if (COLOR_PRESETS.some((c) => c.toLowerCase() === hex)) return;     // already a preset
    customColors = [hex, ...customColors.filter((c) => c !== hex)].slice(0, 12);
    try { localStorage.setItem("songitude.customColors", JSON.stringify(customColors)); } catch (_) {}
  }
  let openPopover = null;
  function closeColorPopover() {
    if (!openPopover) return;
    openPopover.remove(); openPopover = null;
    document.removeEventListener("pointerdown", popoverOutside, true);
  }
  function popoverOutside(e) { if (openPopover && !openPopover.contains(e.target)) closeColorPopover(); }
  // onPick(color, done): done=true is a final choice (commit); false is a live preview.
  function openColorPopover(anchor, current, onPick) {
    closeColorPopover();
    const pop = el("div", "color-popover");
    const makeOpt = (c) => {
      const b = el("button", "color-opt");
      b.style.background = c; b.title = c;
      if (c.toLowerCase() === (current || "").toLowerCase()) b.classList.add("sel");
      b.onclick = (e) => { e.stopPropagation(); onPick(c, true); closeColorPopover(); };
      return b;
    };
    const presetGrid = el("div", "color-grid");
    COLOR_PRESETS.forEach((c) => presetGrid.append(makeOpt(c)));
    pop.append(presetGrid);
    if (customColors.length) {
      pop.append(el("div", "color-section", "Recent"));
      const recentGrid = el("div", "color-grid");
      customColors.forEach((c) => recentGrid.append(makeOpt(c)));
      pop.append(recentGrid);
    }
    const custom = el("button", "color-custom", "＋ Custom RGB");
    custom.onclick = (e) => {
      e.stopPropagation();
      const input = document.createElement("input");
      input.type = "color"; input.value = current || "#4363d8";
      input.oninput = () => onPick(input.value, false);
      input.onchange = () => { addCustomColor(input.value); onPick(input.value, true); closeColorPopover(); };
      input.click();
    };
    pop.append(custom);
    document.body.append(pop);
    const r = anchor.getBoundingClientRect();
    pop.style.left = Math.max(8, Math.min(r.left, window.innerWidth - pop.offsetWidth - 8)) + "px";
    pop.style.top = (r.bottom + pop.offsetHeight + 10 > window.innerHeight
      ? r.top - pop.offsetHeight - 6 : r.bottom + 6) + "px";
    openPopover = pop;
    setTimeout(() => document.addEventListener("pointerdown", popoverOutside, true), 0);
  }

  function cardFor(s) {
    const card = el("div", "card");
    card.dataset.id = s.id;
    if (state.selectedIds.has(s.id)) card.classList.add("selected");

    // head: swatch, name, type badge, delete
    const head = el("div", "card-head");
    const swatch = el("button", "swatch");
    swatch.style.background = s.color;
    swatch.title = "Change color";
    swatch.onclick = (e) => {
      e.stopPropagation();
      openColorPopover(swatch, s.color, (color, done) => {
        s.color = color; swatch.style.background = color; buildLayer(s);
        if (done) commit();
      });
    };
    const name = el("input", "name");
    name.value = s.name; name.spellcheck = false;
    name.oninput = () => { s.name = name.value; };
    name.onchange = () => commit();
    const badge = el("span", "type-badge", s.type === "circle" ? "○ circle" : "▰ polygon");
    const del = el("button", "del", "✕");
    del.title = "Delete"; del.onclick = () => deleteShape(s.id);
    head.append(swatch, name, badge, del);
    card.append(head);
    card.onclick = (e) => {
      if (state.mode !== "edit") return;
      if (e.target.closest("input, button, select, .dropzone")) return; // don't steal control clicks
      if (e.shiftKey || e.metaKey || e.ctrlKey) toggleSelection(s.id);
      else selectOnly(s.id);
    };

    // audio dropzone
    const dz = el("div", "dropzone");
    if (s.audioFile) dz.classList.add("has-audio");
    const icon = el("span", null, "♪");
    const fname = el("span", "file-name", s.audioFile || "Drop an audio file here");
    dz.append(icon, fname);
    if (s.audioFile) {
      const play = el("button", "preview-btn", "▶");
      play.onclick = (e) => { e.stopPropagation(); previewAudio(s.audioFile, play); };
      dz.append(play);
    }
    dz.onclick = () => pickAudioFor(s);
    dz.ondragover = (e) => { e.preventDefault(); dz.classList.add("dragover"); };
    dz.ondragleave = () => dz.classList.remove("dragover");
    dz.ondrop = (e) => {
      e.preventDefault(); dz.classList.remove("dragover");
      const f = [...(e.dataTransfer.files || [])].find((f) => f.type.startsWith("audio") || /\.(mp3|wav|m4a|aac|ogg|flac|caf)$/i.test(f.name));
      if (f) assignAudio(s, f); else toast("That doesn't look like an audio file.", "err");
    };
    card.append(dz);

    // mode selector (dropdown)
    const modeRow = el("div", "params");
    const modeLab = el("label", null, "Mode ");
    const modeSel = document.createElement("select");
    for (const [m, label] of [["loop","Loop"],["syncedLoop","Synced loop"],["oneshot","One-shot"],["dialogue","Dialogue"]]) {
      const o = document.createElement("option"); o.value = m; o.textContent = label;
      if (s.mode === m) o.selected = true;
      modeSel.append(o);
    }
    modeSel.title = MODE_HELP[s.mode] || "";
    modeSel.onclick = (e) => e.stopPropagation();
    modeSel.onchange = (e) => { e.stopPropagation(); s.mode = modeSel.value; renderSide(); commit(); };
    modeLab.append(modeSel); modeRow.append(modeLab);
    card.append(modeRow);

    // params
    const params = el("div", "params");
    const gain = numField("Gain", s.gain, 0, 1, 0.05, (v) => { s.gain = v; });
    params.append(gain);
    if (s.mode === "loop" || s.mode === "syncedLoop") {
      params.append(numField("Fade in (s)", s.fadeIn, 0, 30, 0.5, (v) => { s.fadeIn = v; }));
      params.append(numField("Fade out (s)", s.fadeOut, 0, 30, 0.5, (v) => { s.fadeOut = v; }));
    }
    card.append(params);

    // loop-seam preview (loop / synced loop with audio)
    if ((s.mode === "loop" || s.mode === "syncedLoop") && s.audioFile) {
      const pl = el("button", "loopprev-btn", "↻ Preview loop");
      pl.title = "Play the last 3s → first 3s (the loop point) on repeat, to catch clicks at the seam.";
      pl.onclick = (e) => { e.stopPropagation(); previewLoopSeam(s, pl); };
      card.append(pl);
    }

    // circle: radius slider
    if (s.type === "circle") {
      const row = el("div", "params");
      const lab = el("label", null, "Radius ");
      const slider = document.createElement("input");
      slider.type = "range"; slider.min = 3; slider.step = 1;
      slider.max = Math.max(500, Math.ceil(s.radius * 2));
      slider.value = Math.round(s.radius);
      const val = el("span", null, Math.round(s.radius) + " m");
      const apply = () => { s.radius = parseFloat(slider.value); if (s.layer) s.layer.setRadius(s.radius); val.textContent = Math.round(s.radius) + " m"; };
      slider.oninput = (e) => { e.stopPropagation(); apply(); };
      slider.onchange = (e) => { e.stopPropagation(); commit(); };
      slider.onclick = (e) => e.stopPropagation();
      lab.append(slider, val);
      row.append(lab);
      card.append(row);
    }

    // circle + loop/synced: proximity falloff (fade toward center)
    if (s.type === "circle" && (s.mode === "loop" || s.mode === "syncedLoop")) {
      const row = el("div", "params");
      const lab = el("label", null, "Fade toward center ");
      const sel = document.createElement("select");
      for (const [v, label] of [["none","Off (whole circle)"],["linear","Linear"],["exponential","Exponential"],["edge","Just the edge"]]) {
        const o = document.createElement("option"); o.value = v; o.textContent = label;
        if ((s.falloff || "none") === v) o.selected = true;
        sel.append(o);
      }
      sel.onclick = (e) => e.stopPropagation();
      sel.onchange = (e) => { e.stopPropagation(); s.falloff = sel.value; commit(); };
      sel.title = "Gain by distance from center: 1 at the middle → 0 at the edge.";
      lab.append(sel);
      row.append(lab);
      card.append(row);
    }

    // polygon: redraw button
    if (s.type === "polygon") {
      const redraw = el("button", "redraw-btn", "✎ Redraw shape");
      redraw.title = "Re-place this polygon's points on the map";
      redraw.onclick = (e) => { e.stopPropagation(); startRedraw(s.id); };
      card.append(redraw);
    }
    return card;
  }

  const MODE_HELP = {
    loop: "Loops while you're inside; fades in on enter, fades out on exit. Layers with everything.",
    syncedLoop: "Starts with playback and loops in perfect sample-lock with every other synced loop, everywhere at once. Location only fades its volume up/down (it keeps running, silent, when you're outside).",
    oneshot: "Plays once on entry, always to completion. No fades. Re-arms after you leave.",
    dialogue: "Plays through like a one-shot, but fades out if another dialogue starts.",
  };

  function numField(label, val, min, max, step, onChange) {
    const l = el("label", null, label + " ");
    const inp = document.createElement("input");
    inp.type = "number"; inp.min = min; inp.max = max; inp.step = step; inp.value = val;
    inp.onclick = (e) => e.stopPropagation();
    inp.oninput = () => { const v = clamp(parseFloat(inp.value) || 0, min, max); onChange(v); };
    inp.onchange = () => commit();
    l.append(inp);
    return l;
  }

  // ============================================================ AUDIO I/O ===
  function pickAudioFor(s) {
    const input = document.createElement("input");
    input.type = "file"; input.accept = "audio/*";
    input.onchange = () => { if (input.files[0]) assignAudio(s, input.files[0]); };
    input.click();
  }

  function assignAudio(shape, file) {
    if (audioStore.has(file.name)) URL.revokeObjectURL(audioStore.get(file.name).url);
    audioStore.set(file.name, { blob: file, url: URL.createObjectURL(file) });
    decoded.delete(file.name);
    shape.audioFile = file.name;
    renderSide();
    commit();
    toast(`“${file.name}” assigned to ${shape.name}.`, "ok");
  }

  // ---- loop-seam preview: last ~3s → first ~3s (the real loop point), repeating with a small gap.
  let loopPreview = null;
  function stopLoopPreview() {
    if (!loopPreview) return;
    clearTimeout(loopPreview.timer);
    try { loopPreview.src && loopPreview.src.stop(); } catch (_) {}
    loopPreview.btn.classList.remove("active");
    loopPreview.btn.textContent = "↻ Preview loop";
    loopPreview = null;
  }
  async function previewLoopSeam(shape, btn) {
    if (loopPreview && loopPreview.btn === btn) { stopLoopPreview(); return; }
    stopLoopPreview();
    const buf = await bufferFor(shape.audioFile);
    if (!buf) { toast("Couldn't decode that audio.", "err"); return; }
    const ctx = audioCtx();
    const sr = buf.sampleRate, chs = buf.numberOfChannels;
    const segN = Math.max(1, Math.min(Math.floor(3 * sr), Math.floor(buf.length / 2)));
    const preview = ctx.createBuffer(chs, segN * 2, sr);
    for (let c = 0; c < chs; c++) {
      const src = buf.getChannelData(c), dst = preview.getChannelData(c);
      const lastStart = buf.length - segN;
      for (let i = 0; i < segN; i++) { dst[i] = src[lastStart + i]; dst[segN + i] = src[i]; }
    }
    loopPreview = { btn, src: null, timer: null };
    btn.classList.add("active"); btn.textContent = "■ Stop preview";
    const play = () => {
      const s = ctx.createBufferSource(); s.buffer = preview;
      const g = ctx.createGain(); g.gain.value = shape.gain;
      s.connect(g).connect(ctx.destination);
      s.onended = () => { if (loopPreview && loopPreview.src === s) loopPreview.timer = setTimeout(play, 250); };
      s.start();
      if (loopPreview) loopPreview.src = s;
    };
    play();
  }

  let previewEl = null, previewBtn = null;
  function previewAudio(name, btn) {
    const rec = audioStore.get(name);
    if (!rec) return;
    if (previewEl && previewBtn === btn && !previewEl.paused) {
      previewEl.pause(); btn.textContent = "▶"; return;
    }
    if (previewEl) { previewEl.pause(); if (previewBtn) previewBtn.textContent = "▶"; }
    previewEl = new Audio(rec.url); previewBtn = btn;
    previewEl.onended = () => { btn.textContent = "▶"; };
    previewEl.play(); btn.textContent = "⏸";
  }

  async function bufferFor(name) {
    if (decoded.has(name)) return decoded.get(name);
    const rec = audioStore.get(name);
    if (!rec) return null;
    const ab = await rec.blob.arrayBuffer();
    const buf = await audioCtx().decodeAudioData(ab.slice(0));
    decoded.set(name, buf);
    return buf;
  }

  // ====================================================== LISTEN-MODE ENGINE =
  // Mirrors the iOS AudioEngine semantics so the preview matches the app.
  let _ctx = null;
  function audioCtx() {
    if (!_ctx) _ctx = new (window.AudioContext || window.webkitAudioContext)();
    if (_ctx.state === "suspended") _ctx.resume();
    return _ctx;
  }

  const engine = {
    listener: null,

    async setListener(latlng) {
      this.listener = latlng;
      const ctx = audioCtx();
      const insideIds = new Set();
      for (const s of state.shapes) if (contains(s, latlng)) insideIds.add(s.id);

      // ensure buffers for anything we might start
      await Promise.all(state.shapes
        .filter((s) => s.audioFile && insideIds.has(s.id))
        .map((s) => bufferFor(s.audioFile).catch(() => null)));

      for (const s of state.shapes) {
        if (!s._rt) s._rt = { inside: false, armed: true, source: null, gain: null };
        const rt = s._rt;
        const nowIn = insideIds.has(s.id);
        const rising = nowIn && !rt.inside;

        if (s.mode === "loop") {
          if (nowIn && !rt.source) this._startLoop(s, latlng);
          else if (nowIn && rt.source) this._updateLoopGain(s, latlng); // proximity falloff
          else if (!nowIn && rt.source) this._stopLoop(s);
        } else if (s.mode === "syncedLoop") {
          // Already running in sync (started on listen entry); only gate its volume.
          if (rt.source) {
            const target = nowIn ? this._targetGain(s, latlng) : 0;
            const dur = (nowIn && !rt.inside) ? Math.max(0.02, s.fadeIn)
                      : (!nowIn && rt.inside) ? Math.max(0.02, s.fadeOut) : 0.12;
            const ctx = audioCtx(), t = ctx.currentTime;
            rt.gain.gain.cancelScheduledValues(t);
            rt.gain.gain.setValueAtTime(rt.gain.gain.value, t);
            rt.gain.gain.linearRampToValueAtTime(target, t + dur);
          }
        } else { // oneshot & dialogue
          if (rising && rt.armed) {
            this._playOnce(s);
            rt.armed = false;
            if (s.mode === "dialogue") this._duckOtherDialogues(s);
          }
          if (!nowIn) rt.armed = true;
        }
        rt.inside = nowIn;
      }
      reflectSounding();
    },

    // Target linear gain at a point: the shape gain, scaled by proximity falloff for circles.
    _targetGain(s, latlng) {
      if (s.type === "circle" && (s.falloff && s.falloff !== "none")) {
        const d = map.distance(L.latLng(s.center[0], s.center[1]), latlng);
        return s.gain * falloffLevel(s.falloff, d / s.radius);
      }
      return s.gain;
    },

    _startLoop(s, latlng) {
      if (!s.audioFile) return;
      const buf = decoded.get(s.audioFile); if (!buf) return;
      const ctx = audioCtx();
      const src = ctx.createBufferSource();
      src.buffer = buf; src.loop = true;
      const g = ctx.createGain();
      const t = ctx.currentTime;
      g.gain.setValueAtTime(0.0001, t);
      g.gain.linearRampToValueAtTime(Math.max(0.0001, this._targetGain(s, latlng)), t + Math.max(0.01, s.fadeIn));
      src.connect(g).connect(ctx.destination);
      src.start();
      s._rt.source = src; s._rt.gain = g;
    },

    // Start every synced loop together, sample-aligned, muted — call on entering listen mode.
    async startSyncedLoops() {
      const synced = state.shapes.filter((s) => s.mode === "syncedLoop" && s.audioFile);
      if (!synced.length) return;
      await Promise.all(synced.map((s) => bufferFor(s.audioFile).catch(() => null)));
      const ctx = audioCtx();
      const startAt = ctx.currentTime + 0.12;   // one shared start time → all begin on the same sample
      for (const s of synced) {
        if (!s._rt) s._rt = { inside: false, armed: true, source: null, gain: null };
        if (s._rt.source) continue;
        const buf = decoded.get(s.audioFile); if (!buf) continue;
        const src = ctx.createBufferSource(); src.buffer = buf; src.loop = true;
        const g = ctx.createGain(); g.gain.setValueAtTime(0, ctx.currentTime);
        src.connect(g).connect(ctx.destination);
        src.start(startAt);
        s._rt.source = src; s._rt.gain = g;
      }
      reflectSounding();
    },

    // Continuously track proximity gain as the listener moves inside a circle.
    _updateLoopGain(s, latlng) {
      const rt = s._rt; if (!rt.gain) return;
      if (!(s.type === "circle" && s.falloff && s.falloff !== "none")) return; // constant-gain loops: nothing to do
      const ctx = audioCtx(); const t = ctx.currentTime;
      rt.gain.gain.cancelScheduledValues(t);
      rt.gain.gain.setValueAtTime(rt.gain.gain.value, t);
      rt.gain.gain.linearRampToValueAtTime(Math.max(0.0001, this._targetGain(s, latlng)), t + 0.12);
    },

    _stopLoop(s) {
      const rt = s._rt; if (!rt.source) return;
      const ctx = audioCtx(); const t = ctx.currentTime;
      const src = rt.source, g = rt.gain;
      const fade = Math.max(0.01, s.fadeOut);
      g.gain.cancelScheduledValues(t);
      g.gain.setValueAtTime(g.gain.value, t);
      g.gain.linearRampToValueAtTime(0.0001, t + fade);
      try { src.stop(t + fade + 0.05); } catch (_) {}
      rt.source = null; rt.gain = null;
    },

    _playOnce(s) {
      if (!s.audioFile) return;
      const buf = decoded.get(s.audioFile); if (!buf) return;
      const ctx = audioCtx();
      const src = ctx.createBufferSource();
      src.buffer = buf; src.loop = false;
      const g = ctx.createGain();
      g.gain.setValueAtTime(s.gain, ctx.currentTime);
      src.connect(g).connect(ctx.destination);
      src.onended = () => { if (s._rt && s._rt.source === src) { s._rt.source = null; s._rt.gain = null; reflectSounding(); } };
      src.start();
      s._rt.source = src; s._rt.gain = g;
    },

    _duckOtherDialogues(current) {
      const ctx = audioCtx(); const t = ctx.currentTime;
      for (const s of state.shapes) {
        if (s.mode !== "dialogue" || s.id === current.id) continue;
        const rt = s._rt; if (!rt || !rt.source) continue;
        rt.gain.gain.cancelScheduledValues(t);
        rt.gain.gain.setValueAtTime(rt.gain.gain.value, t);
        rt.gain.gain.linearRampToValueAtTime(0.0001, t + 0.6);
        try { rt.source.stop(t + 0.65); } catch (_) {}
        rt.source = null; rt.gain = null;
      }
    },

    stopShape(s) {
      if (!s._rt || !s._rt.source) return;
      try { s._rt.source.stop(); } catch (_) {}
      s._rt.source = null; s._rt.gain = null;
    },

    stopAll() {
      for (const s of state.shapes) { this.stopShape(s); if (s._rt) { s._rt.inside = false; s._rt.armed = true; } }
      reflectSounding();
    },
  };

  // Listener + movement (walk / run / teleport) in listen mode.
  let listenerMarker = null;
  let listenerPos = null, listenerTarget = null, moveRAF = null, lastFrameTs = 0, lastEngineTs = 0;

  function updateListenerMarker(latlng) {
    if (!listenerMarker) {
      listenerMarker = L.marker(latlng, {
        icon: L.divIcon({ className: "", html: '<div class="listener-marker"></div>', iconSize: [18, 18], iconAnchor: [9, 9] }),
      }).addTo(map);
    } else {
      listenerMarker.setLatLng(latlng);
    }
    $("listenerReadout").textContent =
      `listener @ ${latlng.lat.toFixed(5)}, ${latlng.lng.toFixed(5)}` + (moveRAF ? ` · ${state.listenSpeed}…` : "");
  }

  // A map click sets the target: teleport jumps; walk/run animate there from the current spot.
  function placeListener(latlng) {
    const target = L.latLng(latlng.lat, latlng.lng);
    if (state.listenSpeed === "teleport" || !listenerPos) {
      stopMoving();
      listenerPos = target; listenerTarget = target;
      updateListenerMarker(listenerPos);
      engine.setListener(listenerPos);
      return;
    }
    listenerTarget = target;   // moving target — the walker re-routes toward it
    startMoving();
  }

  function startMoving() { if (!moveRAF) { lastFrameTs = 0; moveRAF = requestAnimationFrame(stepMove); } }
  function stopMoving() { if (moveRAF) { cancelAnimationFrame(moveRAF); moveRAF = null; } }

  function stepMove(ts) {
    if (!lastFrameTs) lastFrameTs = ts;
    const dt = Math.min(0.1, (ts - lastFrameTs) / 1000); lastFrameTs = ts;
    const remaining = map.distance(listenerPos, listenerTarget);
    const step = (LISTEN_SPEED[state.listenSpeed] || 1.4) * dt;   // metres this frame
    if (remaining <= step || remaining < 0.3) {                  // arrived
      listenerPos = listenerTarget; moveRAF = null;
      updateListenerMarker(listenerPos);
      engine.setListener(listenerPos);
      return;
    }
    const f = step / remaining;
    listenerPos = L.latLng(listenerPos.lat + (listenerTarget.lat - listenerPos.lat) * f,
                           listenerPos.lng + (listenerTarget.lng - listenerPos.lng) * f);
    updateListenerMarker(listenerPos);
    if (ts - lastEngineTs > 60) { engine.setListener(listenerPos); lastEngineTs = ts; }  // ~16 Hz audio
    moveRAF = requestAnimationFrame(stepMove);
  }

  function reflectSounding() {
    for (const s of state.shapes) {
      const g = s._rt && s._rt.gain;
      const sounding = !!(s._rt && s._rt.source) && (!g || g.gain.value > 0.005); // silent synced loops aren't "sounding"
      const card = document.querySelector(`.card[data-id="${s.id}"]`);
      if (card) card.classList.toggle("sounding", sounding);
      const weight = state.selectedIds.has(s.id) ? 4 : (sounding ? 3 : 2);
      if (s.layer) s.layer.setStyle({ fillOpacity: sounding ? 0.5 : 0.25, weight });
    }
  }

  // =============================================================== GEOMETRY =
  function contains(shape, latlng) {
    const lat = latlng.lat ?? latlng[0];
    const lng = latlng.lng ?? latlng[1];
    if (shape.type === "circle") {
      return map.distance(L.latLng(shape.center[0], shape.center[1]), L.latLng(lat, lng)) <= shape.radius;
    }
    return pointInPolygon(lat, lng, shape.points);
  }

  // even-odd ray casting on lat/lng
  function pointInPolygon(lat, lng, ring) {
    let inside = false;
    for (let i = 0, j = ring.length - 1; i < ring.length; j = i++) {
      const yi = ring[i][0], xi = ring[i][1];
      const yj = ring[j][0], xj = ring[j][1];
      const intersect = (yi > lat) !== (yj > lat) &&
        lng < ((xj - xi) * (lat - yi)) / (yj - yi + 1e-15) + xi;
      if (intersect) inside = !inside;
    }
    return inside;
  }

  // ============================================================ MODE SWITCH =
  function setMode(mode) {
    stopLoopPreview();
    state.mode = mode;
    $("modeEdit").classList.toggle("active", mode === "edit");
    $("modeListen").classList.toggle("active", mode === "listen");
    $("editToolbar").hidden = mode !== "edit";
    $("listenToolbar").hidden = mode !== "listen";
    if (mode === "edit") {
      engine.stopAll();
      stopMoving();
      listenerPos = null; listenerTarget = null;
      if (listenerMarker) { map.removeLayer(listenerMarker); listenerMarker = null; }
      $("listenerReadout").textContent = "No listener placed";
      setTool("select");
    } else {
      cancelDraw();
      clearEditHandles();
      mapEl.style.cursor = "crosshair";
      audioCtx(); // unlock on user gesture
      for (const s of state.shapes) s._rt = { inside: false, armed: true, source: null, gain: null };
      engine.startSyncedLoops();   // synced loops run from the moment you enter listen mode
    }
  }

  // ============================================================== ZIP I/O ===
  // The bundle metadata (map.json contents) for the current document.
  function bundleMeta() {
    return {
      version: 1,
      name: state.name || "Untitled sound walk",
      creator: state.creator || "",
      about: state.about || "",
      albumArt: state.albumArt ? state.albumArt.name : null,
      center: [map.getCenter().lat, map.getCenter().lng],
      zoom: map.getZoom(),
      shapes: state.shapes.map(serializeShape),
    };
  }

  // Build the .zip bundle in memory. onProgress(percent) is called during compression.
  async function buildBundleZip(onProgress) {
    const zip = new JSZip();
    const usedAudio = new Set(state.shapes.map((s) => s.audioFile).filter(Boolean));
    const bundle = bundleMeta();
    zip.file("map.json", JSON.stringify(bundle, null, 2));
    const audioDir = zip.folder("audio");
    for (const name of usedAudio) {
      const rec = audioStore.get(name);
      if (rec) audioDir.file(name, rec.blob);
    }
    if (state.albumArt) zip.file(state.albumArt.name, state.albumArt.blob);
    const blob = await zip.generateAsync(
      { type: "blob", compression: "DEFLATE" },
      (m) => onProgress && onProgress(Math.round(m.percent)));
    return { blob, bundle, usedAudio };
  }

  async function exportZip() {
    const btn = $("menuBtn");
    if (btn.disabled) return;                       // guard against double-clicks
    const original = btn.innerHTML;
    const label = (pct) => { btn.innerHTML = `<span class="spinner"></span> Exporting ${pct}%`; };
    btn.disabled = true; label(0);
    try {
      const { blob, usedAudio } = await buildBundleZip((p) => label(p));
      const fname = (state.name || "soundwalk").replace(/[^\w.-]+/g, "_") + "_" + timestamp() + ".zip";
      downloadBlob(blob, fname);
      dirty = false;   // work is saved to disk
      toast(`Exported ${fname} (${usedAudio.size} audio file${usedAudio.size === 1 ? "" : "s"}).`, "ok");
    } catch (err) {
      console.error(err);
      toast("Export failed: " + err.message, "err");
    } finally {
      btn.disabled = false;
      btn.innerHTML = original;
    }
  }

  function serializeShape(s) {
    const base = { id: s.id, name: s.name, type: s.type, color: s.color,
                   audioFile: s.audioFile, mode: s.mode, gain: s.gain,
                   fadeIn: s.fadeIn, fadeOut: s.fadeOut, falloff: s.falloff || "none" };
    if (s.type === "circle") return { ...base, center: s.center, radius: s.radius };
    return { ...base, points: s.points };
  }

  async function importZip(file) {
    try {
      const zip = await JSZip.loadAsync(file);
      const mapEntry = zip.file("map.json");
      if (!mapEntry) throw new Error("map.json not found in zip");
      const bundle = JSON.parse(await mapEntry.async("string"));

      // wipe current state
      state.shapes.forEach((s) => { engine.stopShape(s); if (s.layer) map.removeLayer(s.layer); });
      state.shapes = []; state.selectedIds.clear(); state.walkId = null;
      audioStore.forEach((r) => URL.revokeObjectURL(r.url));
      audioStore.clear(); decoded.clear();
      artStore.forEach((r) => URL.revokeObjectURL(r.url));
      artStore.clear();
      state.albumArt = null;
      updateAlbumArtUI();

      // load audio
      const audioFolder = zip.folder("audio");
      if (audioFolder) {
        const entries = [];
        zip.forEach((path, entry) => { if (path.startsWith("audio/") && !entry.dir) entries.push(entry); });
        for (const entry of entries) {
          const blob = await entry.async("blob");
          const name = entry.name.replace(/^audio\//, "");
          audioStore.set(name, { blob, url: URL.createObjectURL(blob) });
        }
      }
      // album art
      if (bundle.albumArt && zip.file(bundle.albumArt)) {
        const blob = await zip.file(bundle.albumArt).async("blob");
        setAlbumArt(new File([blob], bundle.albumArt, { type: blob.type }));
      }

      // meta
      state.name = bundle.name || "";
      state.creator = bundle.creator || "";
      state.about = bundle.about || "";
      syncDetailsInputs();
      if (Array.isArray(bundle.center)) map.setView(bundle.center, bundle.zoom || 15);

      // shapes
      shapeCounter = 0;
      for (const raw of bundle.shapes || []) {
        const geom = raw.type === "circle" ? { center: raw.center, radius: raw.radius } : { points: raw.points };
        shapeCounter += 1;
        const s = {
          id: raw.id || ("s_" + shapeCounter), name: raw.name || `Area ${shapeCounter}`,
          type: raw.type, color: raw.color || SHAPE_COLORS[raw.type] || "#4363d8",
          audioFile: raw.audioFile || null, mode: raw.mode || "loop",
          gain: raw.gain ?? 1, fadeIn: raw.fadeIn ?? 2, fadeOut: raw.fadeOut ?? 3,
          falloff: raw.falloff || "none",
          layer: null, _rt: null, ...geom,
        };
        buildLayer(s);
        state.shapes.push(s);
      }
      renderSide();
      setMode("edit");
      resetHistory();   // imported document is the new history baseline
      toast(`Imported “${state.name}” — ${state.shapes.length} area(s).`, "ok");
    } catch (err) {
      console.error(err);
      toast("Import failed: " + err.message, "err");
    }
  }

  // ============================================================ ALBUM ART ===
  function setAlbumArt(file) {
    // Keep every cover blob in artStore (never revoke) so undo/redo can bring an old one back.
    if (!artStore.has(file.name)) artStore.set(file.name, { blob: file, url: URL.createObjectURL(file) });
    const rec = artStore.get(file.name);
    state.albumArt = { name: file.name, blob: rec.blob, url: rec.url };
    updateAlbumArtUI();
  }
  function updateAlbumArtUI() {
    const thumb = $("albumArtThumb");
    if (state.albumArt) {
      thumb.src = state.albumArt.url; thumb.hidden = false;
      const n = state.albumArt.name;
      $("albumArtLabel").textContent = n.length > 14 ? n.slice(0, 12) + "…" : n;
    } else {
      thumb.hidden = true; thumb.removeAttribute("src");
      $("albumArtLabel").textContent = "＋ Choose image";
    }
  }

  // =============================================================== HELPERS ===
  function el(tag, cls, text) {
    const e = document.createElement(tag);
    if (cls) e.className = cls;
    if (text != null) e.textContent = text;
    return e;
  }
  function clamp(v, a, b) { return Math.max(a, Math.min(b, v)); }
  // Local YYYY-MM-DD_HHMMSS stamp appended to exported filenames so the newest sorts obviously.
  function timestamp() {
    const d = new Date(), p = (n) => String(n).padStart(2, "0");
    return `${d.getFullYear()}-${p(d.getMonth() + 1)}-${p(d.getDate())}_${p(d.getHours())}${p(d.getMinutes())}${p(d.getSeconds())}`;
  }
  function hashStr(str) { let h = 0; for (let i = 0; i < str.length; i++) { h = (h << 5) - h + str.charCodeAt(i); h |= 0; } return h; }
  function downloadBlob(blob, name) {
    const a = document.createElement("a");
    a.href = URL.createObjectURL(blob); a.download = name;
    document.body.appendChild(a); a.click();
    setTimeout(() => { URL.revokeObjectURL(a.href); a.remove(); }, 1000);
  }
  let toastTimer = null;
  function toast(msg, kind) {
    const t = $("toast"); t.textContent = msg; t.className = kind || ""; t.hidden = false;
    clearTimeout(toastTimer); toastTimer = setTimeout(() => { t.hidden = true; }, 3200);
  }

  // ============================================================ UNDO / REDO ==
  // Snapshot the editable state to a JSON string. Audio/art blobs live in their stores and are
  // referenced by name, so snapshots stay small and restoring is cheap.
  function snapshot() {
    return JSON.stringify({
      name: state.name, creator: state.creator, about: state.about,
      albumArt: state.albumArt ? state.albumArt.name : null,
      selected: [...state.selectedIds],
      shapes: state.shapes.map(serializeShape),
    });
  }
  function restoreSnapshot(json) {
    const snap = JSON.parse(json);
    state.shapes.forEach((s) => { engine.stopShape(s); if (s.layer) map.removeLayer(s.layer); });
    state.shapes = [];
    for (const raw of snap.shapes) {
      const geom = raw.type === "circle" ? { center: raw.center, radius: raw.radius } : { points: raw.points };
      const s = { id: raw.id, name: raw.name, type: raw.type, color: raw.color,
                  audioFile: raw.audioFile || null, mode: raw.mode || "loop",
                  gain: raw.gain ?? 1, fadeIn: raw.fadeIn ?? 2, fadeOut: raw.fadeOut ?? 3,
                  falloff: raw.falloff || "none", layer: null, _rt: null, ...geom };
      buildLayer(s);
      state.shapes.push(s);
    }
    state.name = snap.name || "";
    state.creator = snap.creator || "";
    state.about = snap.about || "";
    syncDetailsInputs();
    state.albumArt = (snap.albumArt && artStore.has(snap.albumArt))
      ? { name: snap.albumArt, blob: artStore.get(snap.albumArt).blob, url: artStore.get(snap.albumArt).url }
      : null;
    updateAlbumArtUI();
    state.selectedIds = new Set(snap.selected || []);
    renderSide();
    applySelection();   // restore outline weights + editing handles for the selected shape
  }
  // Record a new history entry — call AFTER a change has been applied to state.
  function commit() {
    if (currentSnap === null) currentSnap = snapshot();
    const next = snapshot();
    if (next === currentSnap) return;            // nothing actually changed
    undoStack.push(currentSnap);
    if (undoStack.length > HISTORY_LIMIT) undoStack.shift();
    redoStack = [];
    currentSnap = next;
    dirty = true;   // an edit happened since the last export/import
  }
  function undo() {
    if (!undoStack.length) { toast("Nothing to undo", ""); return; }
    redoStack.push(currentSnap);
    currentSnap = undoStack.pop();
    restoreSnapshot(currentSnap);
    toast("Undo", "");
  }
  function redo() {
    if (!redoStack.length) { toast("Nothing to redo", ""); return; }
    undoStack.push(currentSnap);
    currentSnap = redoStack.pop();
    restoreSnapshot(currentSnap);
    toast("Redo", "");
  }
  function resetHistory() { undoStack = []; redoStack = []; currentSnap = snapshot(); dirty = false; }

  // ---- side-panel tabs + details form ----------------------------------
  function switchTab(which) {
    const areas = which === "areas";
    $("tabBtnAreas").classList.toggle("active", areas);
    $("tabBtnDetails").classList.toggle("active", !areas);
    $("tabAreas").hidden = !areas;
    $("tabDetails").hidden = areas;
  }
  function syncDetailsInputs() {
    $("mapName").value = state.name || "";
    $("mapCreator").value = state.creator || "";
    $("mapAbout").value = state.about || "";
    $("aboutCount").textContent = (state.about || "").length + " / 2000";
  }

  // ================================================================ WIRING ===
  $("modeEdit").onclick = () => setMode("edit");
  $("modeListen").onclick = () => setMode("listen");
  $("listenSpeed").onchange = (e) => {
    state.listenSpeed = e.target.value;
    if (state.listenSpeed === "teleport") stopMoving();
    else if (listenerPos && listenerTarget && listenerPos !== listenerTarget) startMoving();
  };
  $("toolSelect").onclick = () => setTool("select");
  $("toolPolygon").onclick = () => setTool("polygon");
  $("toolCircle").onclick = () => setTool("circle");
  $("selDelete").onclick = bulkDelete;
  $("selClear").onclick = clearSelection;

  // Delete/Backspace removes the current selection (with confirmation), unless typing in a field.
  document.addEventListener("keydown", (e) => {
    if (e.key !== "Delete" && e.key !== "Backspace") return;
    const t = document.activeElement;
    if (t && /INPUT|TEXTAREA|SELECT/.test(t.tagName)) return;
    // While placing a polygon, Backspace removes the last dropped point (not the selected shape).
    if (e.key === "Backspace" && draw && draw.kind === "polygon" && draw.points.length) {
      e.preventDefault(); undoLastPolygonPoint(); return;
    }
    if (state.mode === "edit" && state.selectedIds.size) { e.preventDefault(); bulkDelete(); }
  });

  // Undo / redo — ⌘Z / ⌘⇧Z (and Ctrl on non-Mac; ⌘Y also redoes).
  document.addEventListener("keydown", (e) => {
    if (!(e.metaKey || e.ctrlKey)) return;
    const k = e.key.toLowerCase();
    if (k === "z") { e.preventDefault(); e.shiftKey ? redo() : undo(); }
    else if (k === "y") { e.preventDefault(); redo(); }
  });

  $("mapName").oninput = (e) => { state.name = e.target.value; };
  $("mapName").onchange = () => commit();
  $("mapCreator").oninput = (e) => { state.creator = e.target.value; };
  $("mapCreator").onchange = () => commit();
  $("mapAbout").oninput = (e) => { state.about = e.target.value; $("aboutCount").textContent = state.about.length + " / 2000"; };
  $("mapAbout").onchange = () => commit();
  $("tabBtnAreas").onclick = () => switchTab("areas");
  $("tabBtnDetails").onclick = () => switchTab("details");
  $("albumArtInput").onchange = (e) => { if (e.target.files[0]) { setAlbumArt(e.target.files[0]); commit(); } };
  $("albumArtThumb").onclick = (e) => e.stopPropagation();

  // toolbar dropdown menu (Import / Export / My walks / Publish)
  const closeMenu = () => { $("menu").hidden = true; };
  $("menuBtn").onclick = (e) => { e.stopPropagation(); if (!$("menuBtn").disabled) $("menu").hidden = !$("menu").hidden; };
  document.addEventListener("click", (e) => { if (!e.target.closest(".menu-wrap")) closeMenu(); });
  $("mImport").onclick = () => { closeMenu(); $("importInput").click(); };
  $("mExport").onclick = () => { closeMenu(); exportZip(); };
  $("mWalks").onclick = () => { closeMenu(); openWalksModal(); };
  $("mPublish").onclick = () => { closeMenu(); openPublishModal(); };
  $("importInput").onchange = (e) => { if (e.target.files[0]) importZip(e.target.files[0]); e.target.value = ""; };

  // Warn before leaving/closing the tab if there are edits that haven't been exported.
  // (Browsers show their own generic "Leave site?" text and ignore custom messages.)
  window.addEventListener("beforeunload", (e) => {
    if (!dirty) return;
    e.preventDefault();
    e.returnValue = "You have unexported changes — please Export .zip to save your work.";
    return e.returnValue;
  });

  // Drop a .zip anywhere to import.
  window.addEventListener("dragover", (e) => e.preventDefault());
  window.addEventListener("drop", (e) => {
    if (e.target.closest(".dropzone")) return; // per-card audio drop handles its own
    const zf = [...(e.dataTransfer?.files || [])].find((f) => /\.zip$/i.test(f.name));
    if (zf) { e.preventDefault(); importZip(zf); }
  });

  // =========================================================== AUTH / PUBLISH =
  const CFG = window.SONGITUDE_CONFIG || {};
  const authReady = CFG.googleClientId && !/REPLACE/.test(CFG.googleClientId);
  const publishReady = CFG.publishApiUrl && !/REPLACE/.test(CFG.publishApiUrl);
  let idToken = null, userEmail = null;

  function initAuth() {
    if (!authReady) {
      // Not configured yet → editor stays open, publishing hidden.
      $("loginGate").hidden = true;
      return;
    }
    $("loginGate").hidden = false;      // gate the editor until signed in
    const boot = () => {
      if (!(window.google && google.accounts && google.accounts.id)) { setTimeout(boot, 150); return; }
      google.accounts.id.initialize({ client_id: CFG.googleClientId, callback: onCredential, auto_select: true });
      google.accounts.id.renderButton($("gbtn"), { theme: "outline", size: "large", text: "signin_with", shape: "pill" });
      google.accounts.id.prompt();   // auto-sign-in returning users (remembers login across refreshes)
    };
    boot();
  }
  async function onCredential(resp) {
    idToken = resp.credential;
    try { userEmail = JSON.parse(atob(idToken.split(".")[1])).email; } catch (_) {}
    if (publishReady) {
      // Verify against the allowlist server-side before unlocking the editor.
      try {
        const r = await fetch(CFG.publishApiUrl, {
          method: "POST",
          headers: { "Authorization": "Bearer " + idToken, "Content-Type": "application/json" },
          body: JSON.stringify({ check: true }),
        });
        const data = r.ok ? await r.json() : null;
        if (!data || !data.authorized) { rejectAccess(); return; }
      } catch (_) { rejectAccess(); return; }
    }
    $("loginGate").hidden = true;
    $("gateError").hidden = true;
    $("accountEmail").textContent = userEmail || "signed in";
    $("accountEmail").hidden = false;
    $("mPublish").hidden = !publishReady;
    $("mWalks").hidden = !publishReady;
  }

  function rejectAccess() {
    idToken = null;
    try { google.accounts.id.disableAutoSelect(); } catch (_) {}
    const el = $("gateError");
    el.innerHTML = `<b>${userEmail || "This account"}</b> isn't approved yet.<br>` +
      `Email <a href="mailto:brian.e2014@gmail.com">brian.e2014@gmail.com</a> to request access, then sign in again.`;
    el.hidden = false;
    $("loginGate").hidden = false;
  }

  // ---- publish modal: review details, confirm rights, upload, show success + QR ----
  function fmtBytes(n) {
    if (n >= 1e6) return (n / 1e6).toFixed(1) + " MB";
    if (n >= 1e3) return Math.round(n / 1e3) + " KB";
    return n + " B";
  }
  function walkTotalSize() {
    let total = 0;
    for (const n of new Set(state.shapes.map((s) => s.audioFile).filter(Boolean))) {
      const r = audioStore.get(n); if (r) total += r.blob.size;
    }
    if (state.albumArt) total += state.albumArt.blob.size;
    return total;
  }
  function publishMissing() {
    const m = new Set();
    if (!(state.name || "").trim()) m.add("title");
    if (!(state.creator || "").trim()) m.add("creator");
    if (!(state.about || "").trim()) m.add("about");
    if (!state.albumArt) m.add("albumArt");
    if (!state.shapes.length) m.add("shapes");
    return m;
  }
  function updatePubGo() {
    const ok = publishMissing().size === 0 && $("pubConfirm").checked;
    $("pubGo").disabled = !ok; $("pubUpdate").disabled = !ok;
  }
  function closePublishModal() { $("publishModal").hidden = true; }

  function openPublishModal() {
    if (!idToken) { toast("Sign in with Google first.", "err"); return; }
    if (!publishReady) { toast("Publishing isn't configured yet.", "err"); return; }
    $("pubError").hidden = true;
    $("pubTitle").textContent = (state.name || "").trim();
    $("pubCreator").textContent = (state.creator || "").trim();
    $("pubAbout").textContent = (state.about || "").trim();
    $("pubArtName").textContent = state.albumArt ? state.albumArt.name : "";
    const art = $("pubArt");
    if (state.albumArt) { art.src = state.albumArt.url; art.hidden = false; $("pubArtEmpty").hidden = true; }
    else { art.hidden = true; $("pubArtEmpty").hidden = false; }
    const withAudio = new Set(state.shapes.map((s) => s.audioFile).filter(Boolean)).size;
    $("pubShapes").textContent = `${state.shapes.length} area${state.shapes.length === 1 ? "" : "s"} · ${withAudio} with audio`;
    $("pubSize").textContent = fmtBytes(walkTotalSize());
    const missing = publishMissing();
    document.querySelectorAll("#publishModal .pub-row[data-field]").forEach((row) =>
      row.classList.toggle("missing", missing.has(row.dataset.field)));
    // Update-vs-new: only when this document is an already-published walk the user owns.
    const owned = !!state.walkId;
    $("pubUpdate").hidden = !owned;
    $("pubGo").textContent = owned ? "☁ Publish as new" : "☁ Publish";
    $("pubConfirm").checked = false;
    updatePubGo();
    $("publishModal").hidden = false;
  }

  // XHR PUT with byte-level upload progress (fetch can't report upload progress).
  function putWithProgress(url, blob, contentType, onProgress) {
    return new Promise((resolve, reject) => {
      const xhr = new XMLHttpRequest();
      xhr.open("PUT", url);
      xhr.setRequestHeader("Content-Type", contentType);
      xhr.upload.onprogress = (e) => { if (e.lengthComputable) onProgress(e.loaded / e.total); };
      xhr.onload = () => (xhr.status >= 200 && xhr.status < 300) ? resolve() : reject(new Error("upload failed (HTTP " + xhr.status + ")"));
      xhr.onerror = () => reject(new Error("upload network error"));
      xhr.send(blob);
    });
  }

  async function runPublish(mode) {   // mode: "new" | "update"
    const btn = mode === "update" ? $("pubUpdate") : $("pubGo");
    if (btn.disabled) return;
    const orig = btn.innerHTML;
    const label = (t) => { btn.innerHTML = `<span class="spinner"></span> ${t}`; };
    const busy = (b) => { ["pubCancel", "pubClose", "pubConfirm", "pubGo", "pubUpdate"].forEach((id) => $(id).disabled = b); };
    busy(true); $("pubError").hidden = true;
    try {
      label("Zipping… 0%");
      const { blob } = await buildBundleZip((p) => label(`Zipping… ${p}%`));
      const m = bundleMeta();
      const meta = { name: m.name, creator: m.creator, about: m.about, center: m.center, zoom: m.zoom, shapeCount: m.shapes.length };
      if (mode === "update") { meta.action = "update"; meta.walkId = state.walkId; }
      label("Requesting…");
      const r = await fetch(CFG.publishApiUrl, {
        method: "POST",
        headers: { "Authorization": "Bearer " + idToken, "Content-Type": "application/json" },
        body: JSON.stringify(meta),
      });
      if (!r.ok) throw new Error((await r.text().catch(() => "")) || ("HTTP " + r.status));
      const { uploadUrl, walkId } = await r.json();
      label("Uploading… 0%");
      await putWithProgress(uploadUrl, blob, "application/zip", (f) => label(`Uploading… ${Math.round(f * 100)}%`));
      state.walkId = walkId;   // this document is now an owned, published walk
      dirty = false;
      closePublishModal();
      showSuccess(m.name, walkId);
    } catch (err) {
      console.error(err);
      $("pubError").textContent = "Publish failed: " + err.message;
      $("pubError").hidden = false;
    } finally {
      busy(false); btn.innerHTML = orig; updatePubGo();
    }
  }

  let lastQrDataUrl = null, lastQrName = "soundwalk";
  function showSuccess(name, walkId) {
    const url = "https://songitude.com/w.html?walk=" + encodeURIComponent(walkId);
    $("successMsg").innerHTML = `<b>${name}</b> is now available in the app.`;
    $("successLink").textContent = url; $("successLink").href = url;
    lastQrName = (name || "soundwalk").replace(/[^\w.-]+/g, "_");
    lastQrDataUrl = null;
    if (window.QRCode) {
      QRCode.toDataURL(url, { width: 320, margin: 2 }, (err, dataUrl) => {
        if (!err) { lastQrDataUrl = dataUrl; $("successQr").src = dataUrl; }
      });
    }
    $("successModal").hidden = false;
  }
  function downloadQr() {
    if (!lastQrDataUrl) { toast("QR not ready yet.", "err"); return; }
    const a = document.createElement("a");
    a.href = lastQrDataUrl; a.download = lastQrName + "_QR_code.png";
    document.body.appendChild(a); a.click(); a.remove();
  }

  // ---- My walks: manage the signed-in user's published walks -----------
  function openWalksModal() {
    if (!idToken || !userEmail) { toast("Sign in with Google first.", "err"); return; }
    $("walksModal").hidden = false;
    renderWalksList("<p class='walks-empty'>Loading…</p>");
    fetch("https://songitude-walks.s3.amazonaws.com/walks/manifest.json", { cache: "no-store" })
      .then((r) => r.json())
      .then((m) => renderWalksList((m.walks || []).filter((w) => (w.owner || "").toLowerCase() === userEmail.toLowerCase())))
      .catch((e) => renderWalksList("<p class='walks-empty'>Couldn't load: " + e.message + "</p>"));
  }
  function renderWalksList(walks) {
    const list = $("walksList");
    if (typeof walks === "string") { list.innerHTML = walks; return; }
    if (!walks.length) { list.innerHTML = "<p class='walks-empty'>You haven't published any walks yet.</p>"; return; }
    list.innerHTML = "";
    for (const w of walks) {
      const item = el("div", "walk-item");
      const info = el("div", "info");
      info.innerHTML = `<h4></h4><div class="meta"></div>`;
      info.querySelector("h4").textContent = w.name || w.id;
      info.querySelector(".meta").textContent =
        `${w.creator ? w.creator + " · " : ""}${w.shapeCount || 0} areas · ${w.sizeBytes ? fmtBytes(w.sizeBytes) : ""} · ${(w.updatedAt || "").slice(0, 10)}`;
      const actions = el("div", "actions");
      const dl = el("button", null, "⇩ Download"); dl.onclick = () => downloadWalkZip(w);
      const load = el("button", null, "✎ Load into editor"); load.onclick = () => loadWalkIntoEditor(w);
      const del = el("button", "danger", "🗑 Delete"); del.onclick = () => deleteWalkFromServer(w, del);
      actions.append(dl, load, del);
      item.append(info, actions);
      list.append(item);
    }
  }
  async function downloadWalkZip(w) {
    try {
      const r = await fetch(w.zipUrl, { cache: "no-store" });
      if (!r.ok) throw new Error("HTTP " + r.status);
      downloadBlob(await r.blob(), (w.name || "soundwalk").replace(/[^\w.-]+/g, "_") + ".zip");
    } catch (e) { toast("Download failed: " + e.message, "err"); }
  }
  async function loadWalkIntoEditor(w) {
    if (dirty && !confirm("Loading this walk will replace your current editor document. Continue?")) return;
    try {
      const r = await fetch(w.zipUrl, { cache: "no-store" });
      if (!r.ok) throw new Error("HTTP " + r.status);
      await importZip(await r.blob());
      state.walkId = w.id;   // now editing an owned published walk → publish offers "Update existing"
      $("walksModal").hidden = true;
      toast(`Loaded “${w.name}”. Edit, then Publish → Update existing walk.`, "ok");
    } catch (e) { toast("Load failed: " + e.message, "err"); }
  }
  async function deleteWalkFromServer(w, btn) {
    if (!confirm(`Delete “${w.name}” from the app for everyone? This can’t be undone.`)) return;
    const orig = btn.innerHTML; btn.disabled = true; btn.innerHTML = "…";
    try {
      const r = await fetch(CFG.publishApiUrl, {
        method: "POST",
        headers: { "Authorization": "Bearer " + idToken, "Content-Type": "application/json" },
        body: JSON.stringify({ action: "delete", walkId: w.id }),
      });
      if (!r.ok) throw new Error((await r.text().catch(() => "")) || ("HTTP " + r.status));
      if (state.walkId === w.id) state.walkId = null;
      toast(`Deleted “${w.name}”.`, "ok");
      setTimeout(openWalksModal, 900);   // manifest rebuild is async; refresh shortly
    } catch (e) { toast("Delete failed: " + e.message, "err"); btn.disabled = false; btn.innerHTML = orig; }
  }

  $("pubClose").onclick = closePublishModal;
  $("pubCancel").onclick = closePublishModal;
  $("pubConfirm").onchange = updatePubGo;
  $("pubGo").onclick = () => runPublish("new");
  $("pubUpdate").onclick = () => runPublish("update");
  $("successClose").onclick = () => { $("successModal").hidden = true; };
  $("successDownload").onclick = downloadQr;
  $("walksClose").onclick = () => { $("walksModal").hidden = true; };
  initAuth();

  setMode("edit");
  renderSide();
  resetHistory();   // establish the initial (empty) history baseline
})();
