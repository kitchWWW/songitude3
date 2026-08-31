/* Songitude — editor
 * Front-end only. No server, no build step.
 * State lives in memory; Export/Import move it in and out of a .zip bundle
 * whose format is shared with the iOS app (see ../shared/FORMAT.md).
 */
(() => {
  "use strict";

  // ---------------------------------------------------------------- state ----
  const DEFAULT_INTRO_COLOR = "#101014";
  const state = {
    mode: "edit",              // "edit" | "listen"
    tool: "select",            // "select" | "pan" | "polygon" | "circle" | "route"
    name: "",
    creator: "",
    about: "",
    // Backdrop of the app's "about this walk" card:
    //   "artist" ⇒ follow the artist's page colour, null ⇒ system default, "#rrggbb" ⇒ custom.
    introColor: "artist",
    // { lat, lng, heading } ⇒ transportable: players move and turn the walk onto the listener.
    // null ⇒ the walk stays where it was drawn.
    startAnchor: null,
    walkId: null,              // set if this document is a published walk the user owns (update vs new)
    center: [40.7128, -74.006],
    zoom: 15,
    shapes: [],                // see makeShape()
    routes: [],                // see makeRoute() — purely visual suggested paths, never audible
    selectedIds: new Set(),    // multi-selection
    selectedRouteId: null,     // routes are selected one at a time, separately from sound areas
    albumArt: null,            // { name, blob, url } | null
    introAudio: null,          // walk-level intro clip filename (in audioStore), or null
    introGain: 1.0,            // 0..1 playback level for the intro clip
    exitAudio: null,           // walk-level exit/outro clip filename (in audioStore), or null
    exitGain: 1.0,             // 0..1 playback level for the exit clip
    listenSpeed: "walking",    // "walking" | "running" | "teleport"
    dialogueColors: null,      // per-walk dialogue state colors (set below)
    displayStyle: "classic",   // "classic" | "fuzzy" — how areas are drawn for listeners
  };
  // metres / second — walk, run, bike (~24 km/h), drive (~48 km/h). Teleport is instant.
  const LISTEN_SPEED = { walking: 1.4, running: 3.5, biking: 6.7, driving: 13.4 };

  // "fuzzy" drops the outline entirely and feathers an area's edge outward over a band this
  // fraction of its size; a polygon also takes a round-jointed stroke, which is what rounds its
  // corners into a blob. Only ever drawn in Listen mode — Edit mode has to stay crisp, since you
  // can't grab a vertex handle on a blurred shape.
  const FUZZ_BAND = 0.08;
  function fuzzyOn() { return state.displayStyle === "fuzzy" && state.mode === "listen"; }
  // Half the shape's smaller on-screen dimension, i.e. a radius in pixels at the current zoom.
  function shapePixelSize(shape) {
    const layer = shape.layer; if (!layer) return 0;
    if (shape.type === "circle") return layer._radius || 0;
    const b = layer.getBounds();
    const nw = map.latLngToLayerPoint(b.getNorthWest()), se = map.latLngToLayerPoint(b.getSouthEast());
    return Math.min(Math.abs(se.x - nw.x), Math.abs(se.y - nw.y)) / 2;
  }
  // The stroke exists only to round a polygon's corners, so it matches the fill exactly; the blur
  // does the actual feathering and is applied to the path element in applyFuzz.
  function withFuzz(shape, style) {
    // Classic has to put the stroke's alpha back explicitly. Leaflet keeps whatever was last set,
    // so a layer that has been fuzzy would otherwise keep its faded outline and read as thin-lined.
    if (!fuzzyOn()) return { opacity: 1, ...style };
    const fill = style.fillColor || style.color || shape.color;
    const op = style.fillOpacity ?? 0.25;
    return { ...style, color: fill, fillColor: fill, opacity: op,
             weight: shape.type === "polygon" ? Math.max(1, FUZZ_BAND * shapePixelSize(shape) * 0.6) : 0 };
  }
  function applyFuzz(shape) {
    const path = shape.layer && shape.layer._path; if (!path) return;
    const size = fuzzyOn() ? shapePixelSize(shape) : 0;
    path.style.filter = size > 4 ? `blur(${(FUZZ_BAND * size / 2).toFixed(2)}px)` : "";
  }
  function applyFuzzAll() { for (const s of state.shapes) applyFuzz(s); }

  // Fixed color per shape type so the map reads consistently: circles red, polygons blue.
  // (Individual shapes can still be recolored via the swatch.)
  const SHAPE_COLORS = { circle: "#e6194b", polygon: "#4363d8" };

  // Suggested routes are drawn, never heard. Each carries its own colour and thickness, so the
  // defaults here only seed a freshly drawn one.
  const DEFAULT_ROUTE_COLOR = "#111111";
  const DEFAULT_ROUTE_WIDTH = 6;
  const ROUTE_WIDTH_RANGE = [2, 16];
  let routeCounter = 0;

  // Dialogue shapes aren't colored individually — they show their playback state instead, using
  // this per-walk palette (authored in the Details tab, saved in map.json). One dialogue plays at a
  // time; the rest queue. Fixed fill opacities give "finished" its faded, see-through look.
  const DIALOGUE_STATES = ["unplayed", "queued", "playing", "finished"];
  const DEFAULT_DIALOGUE_COLORS = { unplayed: "#8a63d2", queued: "#f5a623", playing: "#2ecc71", finished: "#ffffff" };
  const DIALOGUE_STATE_OPACITY = { unplayed: 0.25, queued: 0.42, playing: 0.6, finished: 0.08 };
  state.dialogueColors = { ...DEFAULT_DIALOGUE_COLORS };
  const dColor = (st) => (state.dialogueColors && state.dialogueColors[st]) || DEFAULT_DIALOGUE_COLORS[st];
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
  // CARTO Positron, greyed by CSS (.leaflet-tile-pane) so authored areas are the only colour.
  // The key became mandatory in Aug 2026 — without it CARTO stamps "API KEY REQUIRED" across every
  // tile. It is a *public* key by nature (it rides in every tile URL, visible to anyone who loads
  // the map), so restrict it by domain in the CARTO dashboard rather than treating it as a secret.
  // Keep in step with web/listen/player.js and ios/Songitude/Songitude/Views/MapOverlayView.swift.
  const CARTO_KEY = "cb1_2log_1_19551f9fb4c0fbe576aadb40";
  const BASEMAP_URL =
    "https://basemaps.cartocdn.com/rastertiles/light_all/{z}/{x}/{y}{r}.png?key=" + CARTO_KEY;

  const map = L.map(mapEl, { zoomControl: true }).setView(state.center, state.zoom);
  L.tileLayer(BASEMAP_URL, {
    attribution: '&copy; OpenStreetMap &copy; CARTO',
    maxZoom: 20,
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
      mode: "loop",                  // "loop" | "syncedLoop" | "oneshot" | "dialogue"
      gain: 1.0,
      fadeIn: 2.0,
      fadeOut: 3.0,
      loopMode: "simple",            // loop only: "simple" | "crossfade"
      crossfade: 1.0,                // seconds; overlap for crossfade loops
      falloff: "none",               // circle loops: "none" | "linear" | "exponential" | "edge"
      solo: false,                   // inside this area, non-soloed areas duck to silence
      hidden: false,                 // audible, but never drawn for listeners (edit mode still shows it)
      layer: null,
      _rt: null,                     // listen-mode runtime, see engine
      ...geom,                       // circle: {center:[lat,lng], radius} | polygon: {points:[[lat,lng]...]}
    };
    buildLayer(shape);
    state.shapes.push(shape);
    return shape;
  }

  // A dialogue shape's current display state: its live playback state in listen mode, else "unplayed".
  function dialogueState(shape) {
    return (state.mode === "listen" && shape._rt && shape._rt.dstate) || "unplayed";
  }
  // Base map style for a shape (stroke/fill color + fill opacity), before selection/sounding tweaks.
  function baseStyle(shape) {
    if (shape.mode === "dialogue") {
      const st = dialogueState(shape);
      return { color: dColor(st), fillOpacity: DIALOGUE_STATE_OPACITY[st] };
    }
    return { color: shape.color, fillOpacity: 0.25 };
  }

  function buildLayer(shape) {
    if (shape.layer) { map.removeLayer(shape.layer); shape.layer = null; }
    const b = baseStyle(shape);
    const style = { color: b.color, weight: 2, fillColor: b.color, fillOpacity: b.fillOpacity,
                    // A dashed outline is the author's only cue that this area won't be drawn for
                    // a listener — in Edit mode it looks otherwise identical to a normal one.
                    dashArray: shape.hidden ? "6 5" : null };
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
    // Listen mode previews what the listener sees, so a hidden area is never put on the map there.
    if (state.mode !== "listen" || !shape.hidden) layer.addTo(map);
    shape.layer = layer;
    if (fuzzyOn()) { layer.setStyle(withFuzz(shape, style)); applyFuzz(shape); }
  }

  function shapeById(id) { return state.shapes.find((s) => s.id === id); }

  // ============================================================ ROUTE MODEL ==
  // A suggested route is a purely visual path laid over the map: an open polyline with a marker at
  // each end, optionally labelled. It has no audio, no containment test and no bearing on playback
  // of any kind — the only thing it does is show a listener where the walk means them to go. Every
  // reader treats it as optional, so a bundle without routes behaves exactly as it always did.
  function routeById(id) { return state.routes.find((r) => r.id === id); }

  function makeRoute(points) {
    routeCounter += 1;
    const route = {
      id: "r_" + Math.abs(hashStr("route" + routeCounter + points.length)).toString(36),
      name: `Route ${routeCounter}`,
      points,                              // [[lat,lng], ...] in walking order; at least 2
      color: DEFAULT_ROUTE_COLOR,
      width: DEFAULT_ROUTE_WIDTH,
      startLabel: "",                      // "" ⇒ a plain endpoint marker with no text
      endLabel: "",
      layer: null,
      markers: null,
    };
    buildRouteLayer(route);
    state.routes.push(route);
    return route;
  }

  function destroyRouteLayer(r) {
    if (r.layer) { map.removeLayer(r.layer); r.layer = null; }
    if (r.markers) {
      map.removeLayer(r.markers.start);
      map.removeLayer(r.markers.end);
      r.markers = null;
    }
  }

  /// Round caps and joins are native to Leaflet's SVG renderer (stroke-linecap / stroke-linejoin),
  /// so a route bends smoothly on its own — no need to fake the curve out of rectangles and dots.
  function buildRouteLayer(r) {
    destroyRouteLayer(r);
    r.layer = L.polyline(r.points, routeStyle(r)).addTo(map);
    r.layer.on("mousedown", (e) => {
      if (state.mode !== "edit" || state.tool !== "select") return;
      L.DomEvent.stop(e);
      startRouteDrag(r, e);
    });
    buildRouteMarkers(r);
  }

  function routeStyle(r) {
    const sel = state.selectedRouteId === r.id;
    return { color: r.color, weight: sel ? r.width + 3 : r.width, opacity: sel ? 1 : 0.9,
             lineCap: "round", lineJoin: "round" };
  }

  /// The two endpoint markers: a solid dot in the route's own colour, sized off the line's width so
  /// it reads as the end of the stroke rather than a badge stuck on it. A non-empty label rides
  /// alongside. Non-interactive, so they never swallow a click meant for the line or a handle under
  /// them. The icon's height is fixed in CSS, which is what lets iconAnchor keep the dot — not the
  /// label — sitting on the point.
  function routeEndDotSize(r) { return clamp(r.width || DEFAULT_ROUTE_WIDTH, 6, 14); }
  function routeEndIcon(r, kind) {
    const label = (kind === "start" ? r.startLabel : r.endLabel) || "";
    const d = routeEndDotSize(r);
    const dot = `<i style="background:${r.color};width:${d}px;height:${d}px"></i>`;
    const text = label ? `<b style="color:${r.color}">${escapeHtml(label)}</b>` : "";
    return L.divIcon({ className: "route-end route-end-" + kind, html: dot + text,
                       iconSize: null, iconAnchor: [d / 2, 10] });
  }
  function buildRouteMarkers(r) {
    if (r.points.length < 2) return;
    const mk = (pt, kind) => L.marker(pt, { icon: routeEndIcon(r, kind), interactive: false,
                                            keyboard: false, zIndexOffset: 900 }).addTo(map);
    r.markers = { start: mk(r.points[0], "start"), end: mk(r.points[r.points.length - 1], "end") };
  }
  function refreshRouteMarkers(r) {
    if (!r.markers) { buildRouteMarkers(r); return; }
    r.markers.start.setLatLng(r.points[0]);
    r.markers.start.setIcon(routeEndIcon(r, "start"));
    r.markers.end.setLatLng(r.points[r.points.length - 1]);
    r.markers.end.setIcon(routeEndIcon(r, "end"));
  }
  /// Re-style + re-seat a route in place, without tearing the layer down (which would drop the
  /// handles' object identity mid-drag).
  function refreshRoute(r) {
    if (r.layer) { r.layer.setLatLngs(r.points); r.layer.setStyle(routeStyle(r)); }
    refreshRouteMarkers(r);
  }

  function selectRoute(id) {
    state.selectedIds.clear();
    state.selectedRouteId = id;
    applySelection();
    renderRoutes();
  }

  function removeRoute(id) {
    const r = routeById(id); if (!r) return;
    destroyRouteLayer(r);
    clearEditHandles();
    state.routes = state.routes.filter((x) => x.id !== id);
    if (state.selectedRouteId === id) state.selectedRouteId = null;
  }

  function deleteRoute(id) {
    const r = routeById(id); if (!r) return;
    if (!confirm(`Delete “${r.name}”?\n\nThis only removes the drawn path; no audio is affected.`)) return;
    removeRoute(id);
    renderRoutes();
    applySelection();
    commit();
  }

  /// Move a whole route with the pointer. A press that never moves is a click: on the route whose
  /// handles are already up it drops a new point on the line, otherwise it selects the route.
  function startRouteDrag(r, e) {
    const press = e.latlng;
    map.dragging.disable();
    const startPt = map.latLngToContainerPoint(press);
    let last = press, moved = false;
    const onMove = (ev) => {
      if (!moved && map.latLngToContainerPoint(ev.latlng).distanceTo(startPt) <= DRAG_SLOP_PX) return;
      moved = true;
      const dLat = ev.latlng.lat - last.lat, dLng = ev.latlng.lng - last.lng;
      last = ev.latlng;
      r.points = r.points.map(([la, ln]) => [la + dLat, ln + dLng]);
      refreshRoute(r);
      for (const h of editHandles) { const p = h.getLatLng(); h.setLatLng([p.lat + dLat, p.lng + dLng]); }
    };
    const onUp = () => {
      map.off("mousemove", onMove);
      map.dragging.enable();
      if (moved) { commit(); return; }
      if (maybeInsertVertex(r, "route", press)) return;
      selectRoute(r.id);
    };
    map.on("mousemove", onMove);
    map.once("mouseup", onUp);
  }

  function serializeRoute(r) {
    return { id: r.id, name: r.name, points: r.points.map(([la, ln]) => [la, ln]),
             color: r.color, width: r.width,
             startLabel: r.startLabel || "", endLabel: r.endLabel || "" };
  }

  /// Rebuild every route from serialized form. Shared by import and undo/redo, so the two can't
  /// drift apart the way parallel hand-written copies do.
  function hydrateRoutes(list) {
    state.routes.forEach(destroyRouteLayer);
    state.routes = [];
    routeCounter = 0;
    for (const raw of list || []) {
      if (!Array.isArray(raw.points) || raw.points.length < 2) continue;   // nothing to draw
      routeCounter += 1;
      const r = {
        id: raw.id || ("r_" + routeCounter),
        name: raw.name || `Route ${routeCounter}`,
        points: raw.points.map((p) => [p[0], p[1]]),
        color: raw.color || DEFAULT_ROUTE_COLOR,
        width: raw.width ?? DEFAULT_ROUTE_WIDTH,
        startLabel: raw.startLabel || "",
        endLabel: raw.endLabel || "",
        layer: null, markers: null,
      };
      buildRouteLayer(r);
      state.routes.push(r);
    }
  }

  // ---- selection (multi) ------------------------------------------------
  // Sound areas and routes share one set of drag handles, so selecting either clears the other.
  function selectOnly(id) { state.selectedRouteId = null; state.selectedIds = new Set([id]); applySelection(); scrollToCard(id); }
  function toggleSelection(id) {
    state.selectedRouteId = null;
    if (state.selectedIds.has(id)) state.selectedIds.delete(id); else state.selectedIds.add(id);
    applySelection();
  }
  function setSelection(ids) { state.selectedRouteId = null; state.selectedIds = new Set(ids); applySelection(); }
  function clearSelection() {
    if (!state.selectedIds.size && !state.selectedRouteId) return;
    state.selectedIds.clear();
    state.selectedRouteId = null;
    applySelection();
    renderRoutes();
  }

  function applySelection() {
    // Update card highlight + shape outline in place (no DOM rebuild → keeps input focus).
    document.querySelectorAll(".card").forEach((c) =>
      c.classList.toggle("selected", state.selectedIds.has(c.dataset.id)));
    for (const s of state.shapes) if (s.layer) s.layer.setStyle({ weight: state.selectedIds.has(s.id) ? 4 : 2 });
    for (const r of state.routes) if (r.layer) r.layer.setStyle(routeStyle(r));
    document.querySelectorAll(".route-card").forEach((c) =>
      c.classList.toggle("selected", c.dataset.id === state.selectedRouteId));
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
    // The drag handles are their own map layers, not children of s.layer — without this the
    // deleted shape's vertex/centre grips stay stranded on the map. applySelection() in the
    // callers puts them back on whatever is still selected.
    clearEditHandles();
    state.shapes = state.shapes.filter((x) => x.id !== id);
    state.selectedIds.delete(id);
  }
  function deleteShape(id) {
    const s = shapeById(id); if (!s) return;
    if (!confirm(`Delete “${s.name}”?\n\nThis removes the sound area and its audio assignment.`)) return;
    removeShape(id);
    renderSide();
    applySelection();
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
    applySelection();
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
  // How far the pointer may wander between press and release and still count as a click. Measured in
  // screen pixels: a threshold in degrees is meaningless, since the same hand movement is a whole
  // continent at one zoom and a doorway at another.
  const DRAG_SLOP_PX = 4;

  // Drag a shape (or, if it's part of a multi-selection, the whole group).
  function startShapeDrag(shape, e) {
    const oe = e.originalEvent || {};
    const group = (state.selectedIds.has(shape.id) && state.selectedIds.size > 1)
      ? [...state.selectedIds].map(shapeById).filter(Boolean)
      : [shape];
    map.dragging.disable();
    const startPt = map.latLngToContainerPoint(e.latlng);
    let last = e.latlng, moved = false;
    const onMove = (ev) => {
      // Inside the slop nothing moves at all — otherwise a click meant to drop a point would also
      // nudge the whole outline by however much the hand shook.
      if (!moved && map.latLngToContainerPoint(ev.latlng).distanceTo(startPt) <= DRAG_SLOP_PX) return;
      moved = true;
      // `last` is still the press point on the first real move, so nothing is lost crossing the slop.
      const dLat = ev.latlng.lat - last.lat, dLng = ev.latlng.lng - last.lng;
      last = ev.latlng;
      for (const s of group) translateShape(s, dLat, dLng);
      for (const h of editHandles) { const p = h.getLatLng(); h.setLatLng([p.lat + dLat, p.lng + dLng]); }
    };
    const onUp = () => {
      map.off("mousemove", onMove);
      map.dragging.enable();
      if (!moved) { // a click, not a drag → add a point on the edge, else (de)select
        if (maybeInsertVertex(shape, "shape", e.latlng)) return;
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
  // The vertex the pointer last touched. Delete removes it and joins its neighbours up.
  let activeVertex = null;
  function clearEditHandles() {
    activeVertex = null;
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
    if (state.mode !== "edit" || draw) return;
    // Pan mode leaves nothing on the map to catch a drag; the selection itself is kept, so the
    // handles come straight back on the way out of it.
    if (state.tool === "pan") return;
    if (state.selectedRouteId) {
      const r = routeById(state.selectedRouteId);
      if (r && r.layer) buildVertexHandles(r, "route");
      return;
    }
    if (state.selectedIds.size !== 1) return;
    const s = shapeById([...state.selectedIds][0]);
    if (!s || !s.layer) return;
    if (s.type === "polygon") buildVertexHandles(s, "shape");
    else if (s.type === "circle") buildCircleHandles(s);
  }

  // Polygons and routes both keep their outline in `points`, so one set of handles serves both.
  function buildVertexHandles(obj, kind) {
    obj.points.forEach((pt, i) => {
      const h = newHandle(pt, "vertex", obj.color);
      h.on("mousedown", () => { activeVertex = { obj, kind, index: i }; });
      h.on("drag", () => {
        const ll = h.getLatLng();
        obj.points[i] = [ll.lat, ll.lng];
        if (kind === "route") refreshRoute(obj);
        else if (obj.layer) obj.layer.setLatLngs(obj.points);
      });
      h.on("dragend", () => commit());
      editHandles.push(h);
    });
  }

  // ---- adding and removing points on an existing outline ----------------
  const EDGE_HIT_PX = 12;   // how near the line a click has to land to count as "on the edge"

  /// The segment of `points` nearest `latlng`, measured in screen pixels so the tolerance feels the
  /// same at every zoom. `closed` wraps the last point back to the first (polygons); routes are open.
  /// Returns null when nothing is within `maxPx`.
  function nearestSegment(points, latlng, maxPx, closed) {
    if (!points || points.length < 2) return null;
    const p = map.latLngToContainerPoint(latlng);
    const n = points.length;
    const segs = closed ? n : n - 1;
    let best = null;
    for (let i = 0; i < segs; i++) {
      const a = map.latLngToContainerPoint(points[i]);
      const b = map.latLngToContainerPoint(points[(i + 1) % n]);
      const proj = L.LineUtil.closestPointOnSegment(p, a, b);
      const d = p.distanceTo(proj);
      if (!best || d < best.d) best = { d, index: i, point: map.containerPointToLatLng(proj) };
    }
    return best && best.d <= maxPx ? best : null;
  }

  /// Split the segment after `index` by dropping a new vertex on it.
  function insertVertex(obj, kind, index, latlng) {
    obj.points.splice(index + 1, 0, [latlng.lat, latlng.lng]);
    if (kind === "route") refreshRoute(obj);
    else if (obj.layer) obj.layer.setLatLngs(obj.points);
    refreshEditHandles();
    commit();
    toast("Point added — drag it to shape the line.", "ok");
  }

  /// A click (not a drag) on an object whose handles are showing, landing close to its outline,
  /// adds a point there rather than re-selecting. Returns true when it consumed the click — which
  /// is why the interior of a polygon still selects and drags exactly as before.
  function maybeInsertVertex(obj, kind, latlng) {
    const handlesUp = kind === "route"
      ? state.selectedRouteId === obj.id
      : state.selectedIds.size === 1 && state.selectedIds.has(obj.id);
    if (!handlesUp) return false;
    if (kind !== "route" && obj.type !== "polygon") return false;   // a circle has no vertices
    const hit = nearestSegment(obj.points, latlng, EDGE_HIT_PX, kind !== "route");
    if (!hit) return false;
    insertVertex(obj, kind, hit.index, hit.point);
    return true;
  }

  /// Delete on a vertex removes it and the two points either side simply join up. A polygon needs
  /// three points and a route needs two, so below that we refuse rather than quietly destroying
  /// the object out from under the author.
  function deleteActiveVertex() {
    if (!activeVertex) return false;
    const { obj, kind, index } = activeVertex;
    const min = kind === "route" ? 2 : 3;
    if (obj.points.length <= min) {
      toast(kind === "route" ? "A route needs at least two points."
                             : "A polygon needs at least three points.", "err");
      return true;
    }
    obj.points.splice(index, 1);
    if (kind === "route") refreshRoute(obj);
    else if (obj.layer) obj.layer.setLatLngs(obj.points);
    refreshEditHandles();          // also clears activeVertex; indices below it have shifted
    commit();
    toast("Point removed.", "ok");
    return true;
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
    ["Select", "Pan", "Polygon", "Circle", "Route"].forEach((t) =>
      $("tool" + t).classList.toggle("active", tool === t.toLowerCase()));
    // Kept short: the hint shares one row with the tool buttons, and a long one squeezes them.
    const hints = {
      select: "",
      pan: "Drag to move the map.",
      polygon: "Click each vertex; click the first to close.",
      circle: "Click the center, then the edge.",
      route: "Click each point; Enter to finish.",
    };
    $("toolHint").textContent = hints[tool];
    mapEl.style.cursor = tool === "select" ? "" : tool === "pan" ? "grab" : "crosshair";
    mapEl.classList.toggle("pan-mode", tool === "pan");
    refreshEditHandles();
  }

  function cancelDraw() {
    if (!draw) return;
    (draw.temp || []).forEach((l) => map.removeLayer(l));
    if (draw.rubber) map.removeLayer(draw.rubber);
    if (draw.redrawId) { const s = shapeById(draw.redrawId); if (s) buildLayer(s); } // restore dimmed original
    draw = null;
  }

  map.on("zoomend", applyFuzzAll);
  map.on("click", (e) => {
    if (state.mode === "listen") { placeListener(e.latlng); return; }
    if (state.tool === "polygon") polygonClick(e.latlng);
    else if (state.tool === "circle") circleClick(e.latlng);
    else if (state.tool === "route") routeClick(e.latlng);
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
    if ((draw.kind === "polygon" || draw.kind === "route") && draw.points.length) {
      const pts = draw.points.concat([e.latlng]);
      if (draw.rubber) draw.rubber.setLatLngs(pts);
    } else if (draw.kind === "circle" && draw.center) {
      draw.previewRadius = map.distance(draw.center, e.latlng);
      draw.circle.setRadius(draw.previewRadius);
    }
  });

  document.addEventListener("keydown", (e) => {
    if (e.key === "Enter" && draw && draw.kind === "route" && draw.points.length >= 2) {
      e.preventDefault(); finishRoute(); return;
    }
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

  // Backspace while placing a polygon or a route: pop the most recent vertex off the stack.
  function undoLastPolygonPoint() {
    if (!draw || (draw.kind !== "polygon" && draw.kind !== "route") || !draw.points.length) return;
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

  function routeClick(latlng) {
    if (!draw) {
      clearEditHandles();
      draw = { kind: "route", points: [], temp: [], rubber: null };
      draw.rubber = L.polyline([], { color: DEFAULT_ROUTE_COLOR, weight: DEFAULT_ROUTE_WIDTH,
                                     opacity: 0.65, lineCap: "round", lineJoin: "round",
                                     dashArray: "10,10" }).addTo(map);
    }
    // A route is open, so there is no first point to close onto — clicking the *last* point again
    // is what ends it (Enter does the same).
    if (draw.points.length >= 2) {
      const pl = map.latLngToContainerPoint(draw.points[draw.points.length - 1]);
      if (pl.distanceTo(map.latLngToContainerPoint(latlng)) < 14) { finishRoute(); return; }
    }
    draw.points.push(latlng);
    const vtx = L.circleMarker(latlng, { radius: 4, color: DEFAULT_ROUTE_COLOR,
                                         fillColor: "#fff", fillOpacity: 1 }).addTo(map);
    draw.temp.push(vtx);
    draw.rubber.setLatLngs(draw.points);
  }

  function finishRoute() {
    const points = draw.points.map((ll) => [ll.lat, ll.lng]);
    cancelDraw();
    if (points.length < 2) return;     // a single click isn't a path
    const r = makeRoute(points);
    renderRoutes();
    switchTab("routes");
    selectRoute(r.id);
    commit();
    toast("Route added — set its colour, thickness and end labels on the Routes tab.", "ok");
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

  // ---- routes panel ------------------------------------------------------
  function renderRoutes() {
    const list = $("routeList");
    list.innerHTML = "";
    $("routeCount").textContent = state.routes.length;
    $("routeEmpty").hidden = state.routes.length > 0;
    for (const r of state.routes) list.appendChild(cardForRoute(r));
  }

  function cardForRoute(r) {
    const card = el("div", "card route-card");
    card.dataset.id = r.id;
    if (state.selectedRouteId === r.id) card.classList.add("selected");
    card.onclick = () => selectRoute(r.id);

    const head = el("div", "card-head");
    const name = document.createElement("input");
    name.className = "name"; name.type = "text"; name.value = r.name;
    name.onclick = (e) => e.stopPropagation();
    name.oninput = () => { r.name = name.value; };
    name.onchange = () => commit();
    const del = el("button", "del", "✕");
    del.title = "Delete this route";
    del.onclick = (e) => { e.stopPropagation(); deleteRoute(r.id); };
    head.append(name, del);
    card.append(head);

    // colour + thickness
    const style = el("div", "params");
    const colorLab = el("label", null, "Colour ");
    const color = document.createElement("input");
    color.type = "color"; color.value = r.color;
    color.onclick = (e) => e.stopPropagation();
    color.oninput = (e) => { e.stopPropagation(); r.color = color.value.toLowerCase(); refreshRoute(r); };
    color.onchange = (e) => { e.stopPropagation(); commit(); };
    colorLab.append(color);

    const widthLab = el("label", null, "Thickness ");
    const width = document.createElement("input");
    width.type = "range";
    width.min = ROUTE_WIDTH_RANGE[0]; width.max = ROUTE_WIDTH_RANGE[1]; width.step = 1;
    width.value = r.width;
    const widthVal = el("span", null, r.width + " px");
    width.onclick = (e) => e.stopPropagation();
    width.oninput = (e) => {
      e.stopPropagation();
      r.width = parseInt(width.value, 10);
      widthVal.textContent = r.width + " px";
      refreshRoute(r);
    };
    width.onchange = (e) => { e.stopPropagation(); commit(); };
    widthLab.append(width, widthVal);
    style.append(colorLab, widthLab);
    card.append(style);

    // endpoint labels — leaving one empty gives a plain marker with no text
    const labels = el("div", "params");
    for (const [key, placeholder] of [["startLabel", "Start label"], ["endLabel", "End label"]]) {
      const lab = el("label", null, key === "startLabel" ? "Start " : "End ");
      const inp = document.createElement("input");
      inp.type = "text"; inp.className = "route-label-input";
      inp.value = r[key] || ""; inp.placeholder = placeholder; inp.maxLength = 40;
      inp.onclick = (e) => e.stopPropagation();
      inp.oninput = () => { r[key] = inp.value; refreshRouteMarkers(r); };
      inp.onchange = () => commit();
      lab.append(inp);
      labels.append(lab);
    }
    card.append(labels);
    card.append(el("span", "field-hint",
      "Leave a label empty for a plain marker. Click the line while this route is selected to add "
      + "a point; select a point and press Delete to remove it."));

    const actions = el("div", "shape-actions");
    const editBtn = el("button", "edit-btn", "✎ Edit points");
    editBtn.title = "Show draggable handles for this route's points";
    editBtn.onclick = (e) => { e.stopPropagation(); selectRoute(r.id); toast("Drag the handles to reshape the route.", "ok"); };
    actions.append(editBtn);
    card.append(actions);
    return card;
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
    let swatch;
    if (s.mode === "dialogue") {
      // Dialogue shapes are colored by playback state (see Details tab), not per-shape — show a
      // static swatch of the "unplayed" color rather than a color picker.
      swatch = el("span", "swatch swatch-static");
      swatch.style.background = dColor("unplayed");
      swatch.title = "Dialogue color is set by playback state (Details tab)";
    } else {
      swatch = el("button", "swatch");
      swatch.style.background = s.color;
      swatch.title = "Change color";
      swatch.onclick = (e) => {
        e.stopPropagation();
        openColorPopover(swatch, s.color, (color, done) => {
          s.color = color; swatch.style.background = color; buildLayer(s);
          if (done) commit();
        });
      };
    }
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
      const dl = el("button", "preview-btn", "⬇");
      dl.title = "Download this audio file";
      dl.onclick = (e) => { e.stopPropagation(); downloadAudio(s.audioFile); };
      dz.append(play, dl);
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
    modeSel.onchange = (e) => { e.stopPropagation(); s.mode = modeSel.value; buildLayer(s); renderSide(); commit(); };
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

    // loop-only: simple vs crossfade loop (+ crossfade time when enabled)
    if (s.mode === "loop") {
      const row = el("div", "params");
      const lab = el("label", "checkbox-field");
      const cb = document.createElement("input"); cb.type = "checkbox"; cb.checked = s.loopMode === "crossfade";
      cb.onclick = (e) => e.stopPropagation();
      cb.onchange = (e) => { e.stopPropagation(); s.loopMode = cb.checked ? "crossfade" : "simple"; renderSide(); commit(); };
      lab.title = "Overlap the loop point: a fresh copy fades in as the old one fades out (no seam click).";
      lab.append(cb, el("span", null, " Crossfade loop"));
      row.append(lab);
      card.append(row);
      if (s.loopMode === "crossfade") {
        const cf = el("div", "params");
        cf.append(numField("Crossfade (s)", s.crossfade, 0.1, 10, 0.1, (v) => { s.crossfade = v; }));
        card.append(cf);
      }
    }

    // loop-seam preview (loop / synced loop with audio)
    if ((s.mode === "loop" || s.mode === "syncedLoop") && s.audioFile) {
      const crossfade = s.mode === "loop" && s.loopMode === "crossfade";
      const pl = el("button", "loopprev-btn", crossfade ? "↻ Preview crossfade" : "↻ Preview loop");
      pl.title = crossfade
        ? "Play the crossfade loop — the tail of one copy blending into the head of the next — on repeat."
        : "Play the last 3s → first 3s (the loop point) on repeat, to catch clicks at the seam.";
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

    // solo + hidden: two per-shape flags that apply to circles and polygons alike
    {
      const row = el("div", "params");
      const soloLab = el("label", "check-inline");
      const solo = document.createElement("input");
      solo.type = "checkbox"; solo.checked = !!s.solo;
      solo.onclick = (e) => e.stopPropagation();
      solo.onchange = (e) => {
        e.stopPropagation();
        s.solo = solo.checked;
        if (state.mode === "listen" && engine.listener) engine.setListener(engine.listener);
        commit();
      };
      soloLab.title = "While the listener is inside this area, every other area they're inside "
                    + "ducks to silence. Overlapping soloed areas still play together.";
      soloLab.append(solo, el("span", null, " Solo"));

      const hideLab = el("label", "check-inline");
      const hide = document.createElement("input");
      hide.type = "checkbox"; hide.checked = !!s.hidden;
      hide.onclick = (e) => e.stopPropagation();
      hide.onchange = (e) => {
        e.stopPropagation();
        s.hidden = hide.checked;
        if (s.layer) s.layer.setStyle({ dashArray: s.hidden ? "6 5" : null });
        applyShapeVisibility();
        commit();
      };
      hideLab.title = "Keep the sound, drop the drawing: this area is never shown to a listener "
                    + "in the app or the web player. It stays visible here in Edit mode.";
      hideLab.append(hide, el("span", null, " Hide from listener"));

      row.append(soloLab, hideLab);
      card.append(row);
    }

    // shape-editing actions: drag-handles (all shapes) + polygon redraw
    const actions = el("div", "shape-actions");
    const editBtn = el("button", "edit-btn", "✎ Edit shape");
    editBtn.title = "Show draggable handles to fine-tune this shape's points";
    editBtn.onclick = (e) => { e.stopPropagation(); selectOnly(s.id); toast("Drag the highlighted handles to reshape.", "ok"); };
    actions.append(editBtn);
    if (s.type === "polygon") {
      const redraw = el("button", "redraw-btn", "⟲ Redraw shape");
      redraw.title = "Re-place this polygon's points from scratch on the map";
      redraw.onclick = (e) => { e.stopPropagation(); startRedraw(s.id); };
      actions.append(redraw);
    }
    card.append(actions);
    return card;
  }

  const MODE_HELP = {
    loop: "Loops while you're inside; fades in on enter, fades out on exit. Layers with everything.",
    syncedLoop: "Starts with playback and loops in perfect sample-lock with every other synced loop, everywhere at once. Location only fades its volume up/down (it keeps running, silent, when you're outside).",
    oneshot: "Plays once on entry, always to completion. No fades. Re-arms after you leave.",
    dialogue: "Plays through once, ever. If another dialogue is already playing, it queues and plays when that one finishes. Its color shows its state (set colors in Details).",
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

  // A shape still carrying its auto-assigned "Area N" name (vs. one the author has renamed).
  function isDefaultAreaName(name) { return /^Area \d+$/.test(name || ""); }
  function assignAudio(shape, file) {
    if (audioStore.has(file.name)) URL.revokeObjectURL(audioStore.get(file.name).url);
    audioStore.set(file.name, { blob: file, url: URL.createObjectURL(file) });
    decoded.delete(file.name);
    shape.audioFile = file.name;
    // If the area still has its default name, adopt the audio's filename (without extension).
    if (isDefaultAreaName(shape.name)) shape.name = file.name.replace(/\.[^./\\]+$/, "");
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

    // Crossfade loops: audition the real crossfade (tail of one copy blending into the next).
    if (shape.mode === "loop" && shape.loopMode === "crossfade") {
      const g = ctx.createGain(); g.gain.value = shape.gain; g.connect(ctx.destination);
      const ctrl = makeCrossfadeLoop(buf, shape.crossfade, g);
      loopPreview = { btn, src: ctrl, timer: null };
      btn.classList.add("active"); btn.textContent = "■ Stop preview";
      return;
    }

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

  function downloadAudio(name) {
    const rec = audioStore.get(name);
    if (!rec) { toast("Audio not loaded.", "err"); return; }
    const a = document.createElement("a");
    a.href = rec.url; a.download = name;
    document.body.appendChild(a); a.click(); a.remove();
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

  // A crossfade loop: overlapping copies of `buf` scheduled under `destGain`. Each copy fades in
  // over the crossfade window as the previous one fades out, so there's no seam. Returns an object
  // exposing stop(when) so it drops into the same slots as a plain looping AudioBufferSourceNode.
  function makeCrossfadeLoop(buf, crossfade, destGain) {
    const ctx = audioCtx();
    const D = buf.duration;
    const C = Math.min(Math.max(0.05, crossfade || 1), D * 0.5);   // clamp to ≤ half the clip
    const period = Math.max(0.05, D - C);
    const active = new Set();
    let nextStart = ctx.currentTime, first = true, stopAt = Infinity, torn = false;
    const scheduleCopy = (startAt) => {
      const src = ctx.createBufferSource(); src.buffer = buf;
      const cg = ctx.createGain();
      if (first) { cg.gain.setValueAtTime(1, startAt); first = false; }   // first copy starts full (no in-fade)
      else { cg.gain.setValueAtTime(0.0001, startAt); cg.gain.linearRampToValueAtTime(1, startAt + C); }
      cg.gain.setValueAtTime(1, startAt + D - C);
      cg.gain.linearRampToValueAtTime(0.0001, startAt + D);
      src.connect(cg).connect(destGain);
      src.start(startAt); src.stop(startAt + D + 0.05);
      active.add(src);
      src.onended = () => active.delete(src);
    };
    const tick = () => {
      if (torn) return;
      const ahead = Math.min(ctx.currentTime + 0.4, stopAt);   // schedule copies ~0.4s ahead
      while (nextStart < ahead) { scheduleCopy(nextStart); nextStart += period; }
    };
    tick();
    const timer = setInterval(tick, 150);
    const teardown = () => {
      if (torn) return; torn = true;
      clearInterval(timer);
      for (const src of active) { try { src.stop(ctx.currentTime); } catch (_) {} }
    };
    return {
      stop(when) {
        const at = (typeof when === "number" && when > ctx.currentTime) ? when : ctx.currentTime;
        stopAt = Math.min(stopAt, at);
        tick();   // keep crossfading until stopAt so a region fade-out stays seamless
        setTimeout(teardown, Math.max(0, (stopAt - ctx.currentTime) * 1000) + 80);
      },
    };
  }

  const engine = {
    listener: null,
    dialogueQueue: [],       // shape ids waiting to play, in entry order
    dialoguePlaying: null,   // shape id of the dialogue sounding right now (only one at a time)
    outroActive: false,      // the exit sequence is running — freeze location-driven playback
    _introVoice: null,
    _exitVoice: null,
    _soloOn: false,          // the listener is standing inside at least one soloed area

    // 1 normally; 0 while a solo elsewhere is ducking this shape. Applied to every mode alike —
    // a ducked voice keeps running at zero rather than stopping, so it returns where it would have
    // been (a dialogue picks up mid-line instead of restarting).
    _duck(s) { return (this._soloOn && !s.solo) ? 0 : 1; },

    async setListener(latlng) {
      this.listener = latlng;
      if (this.outroActive) return;   // during the outro, location changes are frozen
      const ctx = audioCtx();
      const insideIds = new Set();
      for (const s of state.shapes) if (contains(s, latlng)) insideIds.add(s.id);
      this._soloOn = state.shapes.some((s) => s.solo && insideIds.has(s.id));

      // ensure buffers for anything we might start
      await Promise.all(state.shapes
        .filter((s) => s.audioFile && insideIds.has(s.id))
        .map((s) => bufferFor(s.audioFile).catch(() => null)));

      for (const s of state.shapes) {
        if (!s._rt) s._rt = { inside: false, armed: true, source: null, gain: null, dstate: "unplayed" };
        const rt = s._rt;
        const nowIn = insideIds.has(s.id);
        const rising = nowIn && !rt.inside;
        // A solo that just switched on or off has to move voices that otherwise only set their
        // gain once (one-shots, dialogue) or that hold a constant level (loops with no falloff).
        const duck = this._duck(s);
        const duckChanged = rt.duck !== undefined && rt.duck !== duck;
        // Ducking uses the ducked shape's own fades, so it sounds like leaving/re-entering it.
        const duckDur = duck ? Math.max(0.02, s.fadeIn) : Math.max(0.02, s.fadeOut);
        rt.duck = duck;

        if (s.mode === "loop") {
          if (nowIn && !rt.source) this._startLoop(s, latlng);
          else if (nowIn && rt.source) this._updateLoopGain(s, latlng, duckChanged, duckDur);
          else if (!nowIn && rt.source) this._stopLoop(s);
        } else if (s.mode === "syncedLoop") {
          // Already running in sync (started on listen entry); only gate its volume.
          if (rt.source) {
            const target = nowIn ? this._targetGain(s, latlng) : 0;
            const dur = duckChanged ? duckDur
                      : (nowIn && !rt.inside) ? Math.max(0.02, s.fadeIn)
                      : (!nowIn && rt.inside) ? Math.max(0.02, s.fadeOut) : 0.12;
            const ctx = audioCtx(), t = ctx.currentTime;
            rt.gain.gain.cancelScheduledValues(t);
            rt.gain.gain.setValueAtTime(rt.gain.gain.value, t);
            rt.gain.gain.linearRampToValueAtTime(target, t + dur);
          }
        } else if (s.mode === "oneshot") {
          if (rising && rt.armed) { this._playOnce(s); rt.armed = false; }
          if (!nowIn) rt.armed = true;
          if (duckChanged && rt.gain) this._rampTo(rt.gain, s.gain * duck, duckDur);
        } else { // dialogue: play once ever; queue behind any dialogue already playing
          if (rising && rt.dstate === "unplayed") {
            rt.dstate = "queued";
            this.dialogueQueue.push(s.id);
            this._advanceDialogue();
          }
          if (duckChanged && rt.gain) this._rampTo(rt.gain, s.gain * duck, duckDur);
        }
        rt.inside = nowIn;
      }
      reflectSounding();
    },

    // Target linear gain at a point: the shape gain, scaled by proximity falloff for circles and
    // by any solo ducking in force.
    _targetGain(s, latlng) {
      if (s.type === "circle" && (s.falloff && s.falloff !== "none")) {
        const d = map.distance(L.latLng(s.center[0], s.center[1]), latlng);
        return s.gain * falloffLevel(s.falloff, d / s.radius) * this._duck(s);
      }
      return s.gain * this._duck(s);
    },

    _rampTo(g, target, dur) {
      const ctx = audioCtx(), t = ctx.currentTime;
      g.gain.cancelScheduledValues(t);
      g.gain.setValueAtTime(g.gain.value, t);
      g.gain.linearRampToValueAtTime(Math.max(0.0001, target), t + Math.max(0.01, dur));
    },

    _startLoop(s, latlng) {
      if (!s.audioFile) return;
      const buf = decoded.get(s.audioFile); if (!buf) return;
      const ctx = audioCtx();
      const g = ctx.createGain();   // region gain: enter/exit fades + proximity falloff
      const t = ctx.currentTime;
      g.gain.setValueAtTime(0.0001, t);
      g.gain.linearRampToValueAtTime(Math.max(0.0001, this._targetGain(s, latlng)), t + Math.max(0.01, s.fadeIn));
      g.connect(ctx.destination);
      s._rt.gain = g;
      if (s.loopMode === "crossfade") {
        s._rt.source = makeCrossfadeLoop(buf, s.crossfade, g);
      } else {
        const src = ctx.createBufferSource();
        src.buffer = buf; src.loop = true;
        src.connect(g); src.start();
        s._rt.source = src;
      }
    },

    // Start every synced loop together, sample-aligned, muted — call on entering listen mode.
    async startSyncedLoops() {
      const synced = state.shapes.filter((s) => s.mode === "syncedLoop" && s.audioFile);
      if (!synced.length) return;
      await Promise.all(synced.map((s) => bufferFor(s.audioFile).catch(() => null)));
      const ctx = audioCtx();
      const startAt = ctx.currentTime + 0.12;   // one shared start time → all begin on the same sample
      for (const s of synced) {
        if (!s._rt) s._rt = { inside: false, armed: true, source: null, gain: null, dstate: "unplayed" };
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
    _updateLoopGain(s, latlng, duckChanged, duckDur) {
      const rt = s._rt; if (!rt.gain) return;
      const tracksProximity = s.type === "circle" && s.falloff && s.falloff !== "none";
      // Constant-gain loops normally have nothing to do here — unless a solo just ducked them.
      if (!tracksProximity && !duckChanged) return;
      this._rampTo(rt.gain, this._targetGain(s, latlng), duckChanged ? duckDur : 0.12);
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
      g.gain.setValueAtTime(Math.max(0.0001, s.gain * this._duck(s)), ctx.currentTime);
      src.connect(g).connect(ctx.destination);
      src.onended = () => { if (s._rt && s._rt.source === src) { s._rt.source = null; s._rt.gain = null; reflectSounding(); } };
      src.start();
      s._rt.source = src; s._rt.gain = g;
    },

    // Play the next queued dialogue if none is currently sounding. One-at-a-time; FIFO.
    async _advanceDialogue() {
      if (this.dialoguePlaying) return;
      const nextId = this.dialogueQueue.shift();
      if (nextId === undefined) return;
      const s = shapeById(nextId);
      if (!s) return this._advanceDialogue();
      this.dialoguePlaying = s.id;
      s._rt.dstate = "playing";
      reflectSounding();
      const buf = s.audioFile ? await bufferFor(s.audioFile).catch(() => null) : null;
      // Guard against a mode switch / stopAll that happened while the buffer decoded.
      if (this.dialoguePlaying !== s.id) return;
      if (!buf) return this._onDialogueFinished(s);
      const ctx = audioCtx();
      const src = ctx.createBufferSource(); src.buffer = buf; src.loop = false;
      const g = ctx.createGain();
      g.gain.setValueAtTime(Math.max(0.0001, s.gain * this._duck(s)), ctx.currentTime);
      src.connect(g).connect(ctx.destination);
      src.onended = () => {
        if (s._rt && s._rt.source === src) { s._rt.source = null; s._rt.gain = null; this._onDialogueFinished(s); }
      };
      src.start();
      s._rt.source = src; s._rt.gain = g;
      reflectSounding();
    },

    _onDialogueFinished(s) {
      if (this.dialoguePlaying === s.id) this.dialoguePlaying = null;
      if (s._rt) { s._rt.source = null; s._rt.gain = null; s._rt.dstate = "finished"; }
      reflectSounding();
      this._advanceDialogue();
    },

    resetDialogue() {
      this.dialogueQueue = [];
      this.dialoguePlaying = null;
    },

    // ---- intro / exit (walk-level) clips ----
    _sleep(ms) { return new Promise((r) => setTimeout(r, ms)); },
    _playClipOnce(buf, gain, onended) {
      const ctx = audioCtx();
      const src = ctx.createBufferSource(); src.buffer = buf;
      const g = ctx.createGain(); g.gain.setValueAtTime(gain, ctx.currentTime);
      src.connect(g).connect(ctx.destination);
      if (onended) src.onended = onended;
      src.start();
      return { src, g };
    },
    async playIntro() {
      if (!state.introAudio) return;
      const buf = await bufferFor(state.introAudio).catch(() => null);
      if (!buf) return;
      if (this._introVoice) { try { this._introVoice.src.stop(); } catch (_) {} }
      this._introVoice = this._playClipOnce(buf, state.introGain, () => { this._introVoice = null; });
    },
    // Fade + stop every sounding voice matching `pick`, over `dur` seconds.
    _fadeVoices(dur, pick) {
      const ctx = audioCtx(), t = ctx.currentTime;
      for (const s of state.shapes) {
        if (!(s._rt && s._rt.source) || !pick(s)) continue;
        const g = s._rt.gain;
        g.gain.cancelScheduledValues(t); g.gain.setValueAtTime(g.gain.value, t);
        g.gain.linearRampToValueAtTime(0.0001, t + dur);
        try { s._rt.source.stop(t + dur + 0.05); } catch (_) {}
        s._rt.source = null; s._rt.gain = null;
      }
    },
    // The end-of-walk experience: fade any dialogue (1s) → exit clip → fade everything (5s) → done.
    async doOutro(onDone) {
      if (this.outroActive) return;
      this.outroActive = true;
      this._fadeVoices(1.0, (s) => s.mode === "dialogue");
      this.resetDialogue();
      for (const s of state.shapes) if (s.mode === "dialogue" && s._rt) s._rt.dstate = "finished";
      reflectSounding();
      await this._sleep(1000);
      if (!this.outroActive) return;
      const buf = state.exitAudio ? await bufferFor(state.exitAudio).catch(() => null) : null;
      if (buf) {
        await new Promise((resolve) => { this._exitVoice = this._playClipOnce(buf, state.exitGain, () => { this._exitVoice = null; resolve(); }); });
      }
      if (!this.outroActive) return;
      this._fadeVoices(5.0, () => true);   // everything else fades out
      await this._sleep(5000);
      if (!this.outroActive) return;
      this.outroActive = false;
      if (onDone) onDone();
    },

    stopShape(s) {
      if (!s._rt || !s._rt.source) return;
      try { s._rt.source.stop(); } catch (_) {}
      s._rt.source = null; s._rt.gain = null;
    },

    stopAll() {
      this.outroActive = false;
      if (this._introVoice) { try { this._introVoice.src.stop(); } catch (_) {} this._introVoice = null; }
      if (this._exitVoice) { try { this._exitVoice.src.stop(); } catch (_) {} this._exitVoice = null; }
      this.resetDialogue();
      this._soloOn = false;
      for (const s of state.shapes) {
        this.stopShape(s);
        if (s._rt) { s._rt.inside = false; s._rt.armed = true; s._rt.dstate = "unplayed"; s._rt.duck = undefined; }
      }
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

  /// Add or remove each shape's layer to match who is meant to see it. Hidden areas are for the
  /// author only: Edit mode always draws them (they'd be unselectable otherwise), Listen mode drops
  /// them off the map entirely so the preview matches what a listener actually sees.
  function applyShapeVisibility() {
    for (const s of state.shapes) {
      if (!s.layer) continue;
      const show = state.mode !== "listen" || !s.hidden;
      const on = map.hasLayer(s.layer);
      if (show && !on) s.layer.addTo(map);
      else if (!show && on) map.removeLayer(s.layer);
    }
  }

  function reflectSounding() {
    for (const s of state.shapes) {
      const g = s._rt && s._rt.gain;
      const sounding = !!(s._rt && s._rt.source) && (!g || g.gain.value > 0.005); // silent synced loops aren't "sounding"
      const card = document.querySelector(`.card[data-id="${s.id}"]`);
      if (card) card.classList.toggle("sounding", sounding);
      if (!s.layer) continue;
      const sel = state.selectedIds.has(s.id);
      if (s.mode === "dialogue") {
        // Color by playback state; the currently-playing one also reads as sounding.
        const st = dialogueState(s);
        const col = dColor(st);
        s.layer.setStyle(withFuzz(s, { color: col, fillColor: col, fillOpacity: DIALOGUE_STATE_OPACITY[st],
                           weight: sel ? 4 : (st === "playing" ? 3 : 2) }));
      } else {
        const weight = sel ? 4 : (sounding ? 3 : 2);
        s.layer.setStyle(withFuzz(s, { fillOpacity: sounding ? 0.5 : 0.25, weight }));
      }
      applyFuzz(s);
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
      applyShapeVisibility();      // hidden areas come back for editing
      reflectSounding();           // reset dialogue shapes back to their "unplayed" color
    } else {
      cancelDraw();
      clearEditHandles();
      // Nothing stays selected into Listen mode: selection is an authoring state, and leaving it up
      // would keep a card highlighted and an area outlined heavily over a preview that is meant to
      // look like what a listener sees. applySelection() inside here repaints the map, the cards
      // and the selection bar together.
      clearSelection();
      mapEl.style.cursor = "crosshair";
      audioCtx(); // unlock on user gesture
      engine.resetDialogue();
      for (const s of state.shapes) s._rt = { inside: false, armed: true, source: null, gain: null, dstate: "unplayed" };
      engine.startSyncedLoops();   // synced loops run from the moment you enter listen mode
      applyShapeVisibility();      // hidden areas disappear, as they will for the listener
      reflectSounding();
    }
    updateListenActions();
  }

  // ============================================================== ZIP I/O ===
  // The bundle metadata (map.json contents) for the current document.
  function bundleMeta() {
    return {
      version: 1,
      // Which published walk this document *is*, when it is one. Without it a re-imported bundle
      // looks like a brand-new walk and publishing mints a second copy instead of updating the
      // original. Absent (or someone else's) is handled: publish falls back to creating a new walk,
      // and the server refuses an update to a walk you do not own.
      walkId: state.walkId || null,
      name: state.name || "Untitled soundwalk",
      creator: state.creator || "",
      about: state.about || "",
      introColor: state.introColor ?? null,
      startAnchor: state.startAnchor ? { ...state.startAnchor } : null,
      albumArt: state.albumArt ? state.albumArt.name : null,
      intro: state.introAudio || null,
      introGain: state.introGain,
      exit: state.exitAudio || null,
      exitGain: state.exitGain,
      center: [map.getCenter().lat, map.getCenter().lng],
      zoom: map.getZoom(),
      dialogueColors: { ...state.dialogueColors },
      displayStyle: state.displayStyle,
      shapes: state.shapes.map(serializeShape),
      routes: state.routes.map(serializeRoute),
    };
  }

  // Build the .zip bundle in memory. onProgress(percent) is called during compression.
  async function buildBundleZip(onProgress) {
    const zip = new JSZip();
    const usedAudio = new Set(state.shapes.map((s) => s.audioFile).filter(Boolean));
    if (state.introAudio) usedAudio.add(state.introAudio);
    if (state.exitAudio) usedAudio.add(state.exitAudio);
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

  /// Put a button into a busy state: a spinner that keeps spinning across label changes (we only
  /// touch the text node — re-setting innerHTML would restart its CSS animation on every tick)
  /// and a fixed width so a counting percentage can't resize the button.
  function busyButton(btn) {
    const original = btn.innerHTML;
    btn.classList.add("btn-busy");
    btn.innerHTML = `<span class="spinner"></span><span class="btn-busy-label"></span>`;
    const label = btn.querySelector(".btn-busy-label");
    return {
      set(text) { label.textContent = text; },
      restore() { btn.classList.remove("btn-busy"); btn.innerHTML = original; },
    };
  }

  async function exportZip() {
    const btn = $("menuBtn");
    if (btn.disabled) return;                       // guard against double-clicks
    const busyBtn = busyButton(btn);
    const label = (pct) => busyBtn.set(`Exporting ${pct}%`);
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
      busyBtn.restore();
    }
  }

  function serializeShape(s) {
    const base = { id: s.id, name: s.name, type: s.type, color: s.color,
                   audioFile: s.audioFile, mode: s.mode, gain: s.gain,
                   fadeIn: s.fadeIn, fadeOut: s.fadeOut,
                   loopMode: s.loopMode || "simple", crossfade: s.crossfade ?? 1.0,
                   falloff: s.falloff || "none",
                   solo: !!s.solo, hidden: !!s.hidden };
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
      clearEditHandles();     // grips outlive their shape's layer otherwise
      state.routes.forEach(destroyRouteLayer);
      state.routes = []; state.selectedRouteId = null;
      // Carry the published id across the import, so re-opening an exported bundle still updates
      // the walk it came from rather than publishing a duplicate. Bundles written before this
      // field existed simply have none, which is the old behaviour.
      state.shapes = []; state.selectedIds.clear();
      state.walkId = typeof bundle.walkId === "string" && bundle.walkId ? bundle.walkId : null;
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
      state.creator = (artistProfile && artistProfile.name) || bundle.creator || "";
      state.about = bundle.about || "";
      state.introColor = bundle.introColor ?? null;   // absent ⇒ system, as older bundles meant
      state.startAnchor = bundle.startAnchor ? { ...bundle.startAnchor } : null;
      state.introAudio = (bundle.intro && audioStore.has(bundle.intro)) ? bundle.intro : null;
      state.introGain = bundle.introGain ?? 1.0;
      state.exitAudio = (bundle.exit && audioStore.has(bundle.exit)) ? bundle.exit : null;
      state.exitGain = bundle.exitGain ?? 1.0;
      state.dialogueColors = { ...DEFAULT_DIALOGUE_COLORS, ...(bundle.dialogueColors || {}) };
      state.displayStyle = bundle.displayStyle === "fuzzy" ? "fuzzy" : "classic";
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
          loopMode: raw.loopMode || "simple", crossfade: raw.crossfade ?? 1.0,
          falloff: raw.falloff || "none",
          solo: !!raw.solo, hidden: !!raw.hidden,
          layer: null, _rt: null, ...geom,
        };
        buildLayer(s);
        state.shapes.push(s);
      }
      hydrateRoutes(bundle.routes);
      renderSide();
      renderRoutes();
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

  // ---- intro / exit clips (walk-level dialogue) ------------------------
  // Both are stored in audioStore by filename (shared with shape audio) and bundled under audio/.
  const WALK_CLIPS = [["introAudio", "intro"], ["exitAudio", "exit"]];
  function setWalkClip(stateKey, file) {
    if (!audioStore.has(file.name)) audioStore.set(file.name, { blob: file, url: URL.createObjectURL(file) });
    state[stateKey] = file.name;
    updateWalkClipUI();
  }
  function updateWalkClipUI() {
    for (const [stateKey, id] of WALK_CLIPS) {
      const name = state[stateKey], has = !!name;
      $(id + "Choose").hidden = has;
      $(id + "Name").hidden = !has;
      $(id + "GainRow").hidden = !has;
      $(id + "Play").hidden = !has;
      $(id + "Dl").hidden = !has;
      $(id + "Clear").hidden = !has;
      if (has) { $(id + "Name").textContent = name; $(id + "Gain").value = state[id + "Gain"]; }
    }
    updateListenActions();
  }
  function updateListenActions() {
    if ($("doIntro")) $("doIntro").disabled = !state.introAudio;
    if ($("doOutro")) $("doOutro").disabled = state.mode !== "listen";
  }

  // =============================================================== HELPERS ===
  function escapeHtml(v) {
    return String(v).replace(/[&<>"']/g, (c) =>
      ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c]));
  }
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
      introColor: state.introColor,
      startAnchor: state.startAnchor ? { ...state.startAnchor } : null,
      albumArt: state.albumArt ? state.albumArt.name : null,
      intro: state.introAudio || null,
      introGain: state.introGain,
      exit: state.exitAudio || null,
      exitGain: state.exitGain,
      dialogueColors: { ...state.dialogueColors },
      displayStyle: state.displayStyle,
      selected: [...state.selectedIds],
      selectedRoute: state.selectedRouteId,
      shapes: state.shapes.map(serializeShape),
      routes: state.routes.map(serializeRoute),
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
                  loopMode: raw.loopMode || "simple", crossfade: raw.crossfade ?? 1.0,
                  falloff: raw.falloff || "none", solo: !!raw.solo, hidden: !!raw.hidden,
                  layer: null, _rt: null, ...geom };
      buildLayer(s);
      state.shapes.push(s);
    }
    state.name = snap.name || "";
    state.creator = snap.creator || "";
    state.about = snap.about || "";
    state.introColor = snap.introColor ?? null;
    state.startAnchor = snap.startAnchor ? { ...snap.startAnchor } : null;
    state.introAudio = (snap.intro && audioStore.has(snap.intro)) ? snap.intro : null;
    state.introGain = snap.introGain ?? 1.0;
    state.exitAudio = (snap.exit && audioStore.has(snap.exit)) ? snap.exit : null;
    state.exitGain = snap.exitGain ?? 1.0;
    state.dialogueColors = { ...DEFAULT_DIALOGUE_COLORS, ...(snap.dialogueColors || {}) };
    state.displayStyle = snap.displayStyle === "fuzzy" ? "fuzzy" : "classic";
    syncDetailsInputs();
    state.albumArt = (snap.albumArt && artStore.has(snap.albumArt))
      ? { name: snap.albumArt, blob: artStore.get(snap.albumArt).blob, url: artStore.get(snap.albumArt).url }
      : null;
    updateAlbumArtUI();
    hydrateRoutes(snap.routes);
    state.selectedIds = new Set(snap.selected || []);
    state.selectedRouteId = routeById(snap.selectedRoute) ? snap.selectedRoute : null;
    renderSide();
    renderRoutes();
    applySelection();   // restore outline weights + editing handles for the selected shape
  }
  // Record a new history entry — call AFTER a change has been applied to state.
  // ---- start anchor (transportable walks) --------------------------------------------------
  let anchorMarker = null;

  function anchorIcon(deg) {
    return L.divIcon({
      className: "anchor-pin",
      html: `<div class="anchor-arrow" style="transform:rotate(${deg}deg)">` +
            `<svg viewBox="0 0 24 24" width="26" height="26" aria-hidden="true">` +
            `<path d="M12 2 L18.5 21 L12 16.5 L5.5 21 Z" fill="#1b2440" stroke="#fff" ` +
            `stroke-width="1.6" stroke-linejoin="round"/></svg></div>`,
      iconSize: [30, 30], iconAnchor: [15, 15],
    });
  }

  /// Put the pin on the map (or take it off) to match state.startAnchor.
  function syncAnchorLayer() {
    const a = state.startAnchor;
    if (!a) {
      if (anchorMarker) { map.removeLayer(anchorMarker); anchorMarker = null; }
      return;
    }
    if (!anchorMarker) {
      anchorMarker = L.marker([a.lat, a.lng], {
        draggable: true, icon: anchorIcon(a.heading), zIndexOffset: 1000,
        title: "Where the listener starts",
      }).addTo(map);
      anchorMarker.on("dragend", () => {
        const p = anchorMarker.getLatLng();
        state.startAnchor = { ...state.startAnchor, lat: p.lat, lng: p.lng };
        commit();
      });
    } else {
      anchorMarker.setLatLng([a.lat, a.lng]);
      anchorMarker.setIcon(anchorIcon(a.heading));
    }
  }

  function syncAnchorInputs() {
    const a = state.startAnchor;
    $("mapAnchorOn").checked = !!a;
    $("anchorHeadingRow").hidden = !a;
    $("mapAnchorHeading").value = a ? a.heading : 0;
    $("anchorHeadingVal").textContent = a ? `${Math.round(a.heading)}°` : "";
    syncAnchorLayer();
  }

  $("mapAnchorOn").onchange = (e) => {
    if (e.target.checked) {
      const c = map.getCenter();
      state.startAnchor = { lat: c.lat, lng: c.lng, heading: 0 };
    } else {
      state.startAnchor = null;
    }
    syncAnchorInputs();
    commit();
  };
  $("mapAnchorHeading").oninput = (e) => {
    if (!state.startAnchor) return;
    state.startAnchor = { ...state.startAnchor, heading: Number(e.target.value) };
    $("anchorHeadingVal").textContent = `${state.startAnchor.heading}°`;
    syncAnchorLayer();
  };
  $("mapAnchorHeading").onchange = () => commit();

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
    for (const [name, btn, panel] of [["areas", "tabBtnAreas", "tabAreas"],
                                      ["routes", "tabBtnRoutes", "tabRoutes"],
                                      ["details", "tabBtnDetails", "tabDetails"]]) {
      $(btn).classList.toggle("active", which === name);
      $(panel).hidden = which !== name;
    }
  }
  function introColorMode() {
    if (state.introColor === "artist") return "artist";
    return state.introColor ? "custom" : "system";
  }
  function syncDetailsInputs() {
    $("mapName").value = state.name || "";
    $("mapCreator").value = state.creator || "";
    $("mapAbout").value = state.about || "";
    $("aboutCount").textContent = (state.about || "").length + " / 2000";
    renderMarkdownInto($("aboutPreview"), state.about);
    syncAnchorInputs();
    const mode = introColorMode();
    $("mapIntroColorMode").value = mode;
    $("mapIntroColor").disabled = mode !== "custom";
    $("mapIntroColor").value = mode === "custom" ? state.introColor : DEFAULT_INTRO_COLOR;
    $("mapDisplayStyle").value = state.displayStyle;
    $("dcUnplayed").value = dColor("unplayed");
    $("dcQueued").value = dColor("queued");
    $("dcPlaying").value = dColor("playing");
    $("dcFinished").value = dColor("finished");
    updateWalkClipUI();
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
  $("toolRoute").onclick = () => setTool("route");
  $("toolPan").onclick = () => setTool("pan");
  $("selDelete").onclick = bulkDelete;
  $("selClear").onclick = clearSelection;

  // Delete/Backspace removes the current selection (with confirmation), unless typing in a field.
  document.addEventListener("keydown", (e) => {
    if (e.key !== "Delete" && e.key !== "Backspace") return;
    const t = document.activeElement;
    if (t && /INPUT|TEXTAREA|SELECT/.test(t.tagName)) return;
    // While placing a polygon, Backspace removes the last dropped point (not the selected shape).
    if (e.key === "Backspace" && draw && (draw.kind === "polygon" || draw.kind === "route") && draw.points.length) {
      e.preventDefault(); undoLastPolygonPoint(); return;
    }
    // A vertex under the pointer takes priority over deleting the whole shape.
    if (state.mode === "edit" && activeVertex) { e.preventDefault(); deleteActiveVertex(); return; }
    if (state.mode === "edit" && state.selectedRouteId) { e.preventDefault(); deleteRoute(state.selectedRouteId); return; }
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
  $("mapAbout").oninput = (e) => {
    state.about = e.target.value;
    $("aboutCount").textContent = state.about.length + " / 2000";
    renderMarkdownInto($("aboutPreview"), state.about);
    syncAnchorInputs();
  };
  $("mapAbout").onchange = () => commit();
  $("mapIntroColorMode").onchange = (e) => {
    state.introColor = e.target.value === "artist" ? "artist"
                     : e.target.value === "custom" ? $("mapIntroColor").value.toLowerCase()
                     : null;
    $("mapIntroColor").disabled = e.target.value !== "custom";
    commit();
  };
  $("mapIntroColor").oninput = (e) => { state.introColor = e.target.value.toLowerCase(); };
  $("mapIntroColor").onchange = () => commit();
  $("mapDisplayStyle").onchange = (e) => {
    state.displayStyle = e.target.value === "fuzzy" ? "fuzzy" : "classic";
    // Only Listen mode draws the style, and rebuilding layers under Edit mode's drag handles would
    // strand them — Edit picks the change up when you next switch over. Rebuild rather than restyle:
    // switching styles changes the stroke as well as the blur, and a layer still carrying the other
    // style's stroke would keep a ghost outline under it.
    if (state.mode === "listen") {
      for (const sh of state.shapes) buildLayer(sh);
      applyShapeVisibility();
      reflectSounding();
    }
    commit();
  };
  // Per-walk dialogue state colors (Details tab). Recolor the map live; commit on release.
  for (const [key, id] of Object.entries({ unplayed: "dcUnplayed", queued: "dcQueued", playing: "dcPlaying", finished: "dcFinished" })) {
    $(id).oninput = (e) => {
      state.dialogueColors[key] = e.target.value;
      reflectSounding();     // recolor dialogue layers live (unplayed swatch also refreshes on renderSide)
    };
    $(id).onchange = () => { renderSide(); commit(); };
  }
  // Intro / exit clip pickers (Details tab)
  for (const [stateKey, id] of WALK_CLIPS) {
    $(id + "Choose").onclick = () => $(id + "Input").click();
    $(id + "Input").onchange = (e) => { if (e.target.files[0]) { setWalkClip(stateKey, e.target.files[0]); commit(); } e.target.value = ""; };
    $(id + "Play").onclick = () => { if (state[stateKey]) previewAudio(state[stateKey], $(id + "Play")); };
    $(id + "Dl").onclick = () => { if (state[stateKey]) downloadAudio(state[stateKey]); };
    $(id + "Gain").oninput = () => { state[id + "Gain"] = clamp(parseFloat($(id + "Gain").value) || 0, 0, 1); };
    $(id + "Gain").onchange = () => commit();
    $(id + "Clear").onclick = () => { state[stateKey] = null; updateWalkClipUI(); commit(); };
  }
  // Listen-tab intro / outro triggers
  $("doIntro").onclick = () => engine.playIntro();
  $("doOutro").onclick = () => {
    $("doOutro").disabled = true;
    engine.doOutro(() => {
      // Editor preview: after the outro, return to normal playback at the current spot.
      for (const s of state.shapes) { engine.stopShape(s); s._rt = { inside: false, armed: true, source: null, gain: null, dstate: "unplayed" }; }
      engine.resetDialogue();
      engine.startSyncedLoops();
      if (engine.listener) engine.setListener(engine.listener);
      reflectSounding();
      updateListenActions();
      toast("Outro finished — back to normal playback.", "ok");
    });
  };
  $("tabBtnAreas").onclick = () => switchTab("areas");
  $("tabBtnRoutes").onclick = () => switchTab("routes");
  $("tabBtnDetails").onclick = () => switchTab("details");
  $("albumArtInput").onchange = (e) => { if (e.target.files[0]) { setAlbumArt(e.target.files[0]); commit(); } };
  $("albumArtThumb").onclick = (e) => e.stopPropagation();

  // toolbar dropdown menu (Import / Export / My walks / Publish)
  const closeMenu = () => { $("menu").hidden = true; };
  $("menuBtn").onclick = (e) => { e.stopPropagation(); if (!$("menuBtn").disabled) $("menu").hidden = !$("menu").hidden; };
  document.addEventListener("click", (e) => { if (!e.target.closest(".menu-wrap")) closeMenu(); });
  /// Start a blank document. Mirrors importZip's wipe, then restores first-run defaults — the
  /// creator stays the signed-in artist, and the intro card goes back to following their colours.
  function newDocument() {
    if (dirty && !confirm("Start a new soundwalk? Your unexported changes will be lost.")) return;
    closeMenu();
    state.shapes.forEach((s) => { engine.stopShape(s); if (s.layer) map.removeLayer(s.layer); });
    clearEditHandles();       // grips outlive their shape's layer otherwise
    state.routes.forEach(destroyRouteLayer);
    state.routes = []; state.selectedRouteId = null;
    state.shapes = []; state.selectedIds.clear(); state.walkId = null;
    audioStore.forEach((r) => URL.revokeObjectURL(r.url));
    audioStore.clear(); decoded.clear();
    artStore.forEach((r) => URL.revokeObjectURL(r.url));
    artStore.clear();
    state.albumArt = null;

    state.name = "";
    state.creator = (artistProfile && artistProfile.name) || "";
    state.about = "";
    state.introColor = "artist";
    state.startAnchor = null;
    state.introAudio = null; state.introGain = 1.0;
    state.exitAudio = null; state.exitGain = 1.0;
    state.dialogueColors = { ...DEFAULT_DIALOGUE_COLORS };
    state.displayStyle = "classic";

    updateAlbumArtUI();
    syncDetailsInputs();
    renderSide();
    renderRoutes();
    resetHistory();          // the blank document becomes the new undo baseline
    toast("Started a new soundwalk.", "ok");
  }

  $("mNew").onclick = newDocument;
  $("mImport").onclick = () => { closeMenu(); $("importInput").click(); };
  $("mExport").onclick = () => { closeMenu(); exportZip(); };
  $("mWalks").onclick = () => { closeMenu(); openWalksModal(); };
  $("mPublish").onclick = () => { closeMenu(); openPublishModal(); };
  $("mLogout").onclick = () => logout();
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

  // ---- persisted sign-in: keep the Google token across refreshes so login isn't needed each time.
  const AUTH_KEY = "songitude.auth";
  function jwtExp(token) { try { return JSON.parse(atob(token.split(".")[1])).exp || 0; } catch (_) { return 0; } }
  function saveAuth() {
    try { localStorage.setItem(AUTH_KEY, JSON.stringify({ token: idToken, email: userEmail, exp: jwtExp(idToken) })); } catch (_) {}
  }
  function loadAuth() {
    try {
      const a = JSON.parse(localStorage.getItem(AUTH_KEY) || "null");
      if (a && a.token && a.exp * 1000 > Date.now() + 60000) return a;   // still valid (>1 min left)
    } catch (_) {}
    return null;
  }
  function clearAuth() { try { localStorage.removeItem(AUTH_KEY); } catch (_) {} }

  function applySignedIn(email) {
    $("loginGate").hidden = true;
    $("gateError").hidden = true;
    $("accountEmail").textContent = email || "signed in";
    $("accountEmail").hidden = false;
    $("mPublish").hidden = !publishReady;
    $("mWalks").hidden = !publishReady;
    $("mArtist").hidden = !publishReady;
    $("mLogout").hidden = false;
  }
  function applySignedOut() {
    idToken = null; userEmail = null;
    $("accountEmail").hidden = true;
    $("mPublish").hidden = true; $("mWalks").hidden = true; $("mArtist").hidden = true;
    $("mLogout").hidden = true;
    artistProfile = null;
    $("loginGate").hidden = false;
  }
  function verifyToken() {
    return fetch(CFG.publishApiUrl, {
      method: "POST",
      headers: { "Authorization": "Bearer " + idToken, "Content-Type": "application/json" },
      body: JSON.stringify({ check: true }),
    }).then((r) => (r.ok ? r.json() : null));
  }

  function initAuth() {
    if (!authReady) {
      // Not configured yet → editor stays open, publishing hidden.
      $("loginGate").hidden = true;
      return;
    }
    const stored = loadAuth();
    if (stored) {
      // Reuse the saved token so a refresh doesn't require signing in again.
      idToken = stored.token; userEmail = stored.email;
      applySignedIn(userEmail);
      // Re-verify in the background; if it's been revoked/de-listed, fall back to the gate.
      if (publishReady) verifyToken().then((d) => {
        if (!d || !d.authorized) { clearAuth(); applySignedOut(); return; }
        applyArtistProfile(d.artist);
      }).catch(() => {});
    } else {
      $("loginGate").hidden = false;   // gate the editor until signed in
    }
    const boot = () => {
      if (!(window.google && google.accounts && google.accounts.id)) { setTimeout(boot, 150); return; }
      google.accounts.id.initialize({ client_id: CFG.googleClientId, callback: onCredential, auto_select: true });
      google.accounts.id.renderButton($("gbtn"), { theme: "outline", size: "large", text: "signin_with", shape: "pill" });
      if (!idToken) google.accounts.id.prompt();   // silent auto-sign-in only when not already restored
    };
    boot();
  }
  async function onCredential(resp) {
    idToken = resp.credential;
    try { userEmail = JSON.parse(atob(idToken.split(".")[1])).email; } catch (_) {}
    if (publishReady) {
      // Verify against the allowlist server-side before unlocking the editor.
      try {
        const data = await verifyToken();
        if (!data || !data.authorized) { rejectAccess(); return; }
        applyArtistProfile(data.artist);
      } catch (_) { rejectAccess(); return; }
    }
    saveAuth();                 // remember across refreshes
    applySignedIn(userEmail);
  }

  function logout() {
    closeMenu();
    clearAuth();
    try { google.accounts.id.disableAutoSelect(); } catch (_) {}
    applySignedOut();
    try { google.accounts.id.prompt(); } catch (_) {}
  }

  function rejectAccess() {
    idToken = null;
    clearAuth();
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
    const audio = new Set(state.shapes.map((s) => s.audioFile).filter(Boolean));
    if (state.introAudio) audio.add(state.introAudio);
    if (state.exitAudio) audio.add(state.exitAudio);
    for (const n of audio) { const r = audioStore.get(n); if (r) total += r.blob.size; }
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

  // When the author ticked the rights box, kept for the record and sent with the publish.
  let rightsConfirmedAt = null;

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
    // With an update available, updating is the expected action — so it keeps the accent and
    // "publish as new" steps back to a plain button.
    $("pubGo").classList.toggle("publish", !owned);
    $("pubConfirm").checked = false;
    rightsConfirmedAt = null;      // each publish needs its own attestation
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
    const busyBtn = busyButton(btn);
    const label = (t) => busyBtn.set(t);
    const busy = (b) => { ["pubCancel", "pubClose", "pubConfirm", "pubGo", "pubUpdate"].forEach((id) => $(id).disabled = b); };
    busy(true); $("pubError").hidden = true;
    try {
      label("Zipping… 0%");
      const { blob } = await buildBundleZip((p) => label(`Zipping… ${p}%`));
      const m = bundleMeta();
      const meta = { name: m.name, creator: m.creator, about: m.about, center: m.center, zoom: m.zoom,
                     shapeCount: m.shapes.length, rightsConfirmedAt };
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
      busy(false); busyBtn.restore(); updatePubGo();
    }
  }

  let lastQrDataUrl = null, lastQrName = "soundwalk";
  // Render a QR code to a PNG data URL via qrcode-generator (pure client-side, no CDN build quirks).
  function qrPngDataUrl(text, px) {
    const qr = qrcode(0, "M");          // typeNumber 0 = auto-size, error correction "M"
    qr.addData(text);
    qr.make();
    const count = qr.getModuleCount(), margin = 4, total = count + margin * 2;
    const cell = Math.max(2, Math.floor(px / total)), size = cell * total;
    const cv = document.createElement("canvas");
    cv.width = cv.height = size;
    const cx = cv.getContext("2d");
    cx.fillStyle = "#fff"; cx.fillRect(0, 0, size, size);
    cx.fillStyle = "#000";
    for (let r = 0; r < count; r++)
      for (let c = 0; c < count; c++)
        if (qr.isDark(r, c)) cx.fillRect((c + margin) * cell, (r + margin) * cell, cell, cell);
    return cv.toDataURL("image/png");
  }
  function showSuccess(name, walkId) {
    const url = "https://songitude.com/w.html?walk=" + encodeURIComponent(walkId);
    $("successMsg").innerHTML = `<b>${name}</b><br>is now available in the app.`;
    $("successLink").textContent = url; $("successLink").href = url;
    lastQrName = (name || "soundwalk").replace(/[^\w.-]+/g, "_");
    lastQrDataUrl = null;
    if (window.qrcode) {
      try {
        lastQrDataUrl = qrPngDataUrl(url, 320);
        $("successQr").src = lastQrDataUrl;
      } catch (e) { console.error("QR generation failed", e); }
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
      const load = el("button", null, "✎ Load"); load.onclick = () => loadWalkIntoEditor(w, load);
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
  async function loadWalkIntoEditor(w, btn) {
    if (dirty && !confirm("Loading this walk will replace your current editor document. Continue?")) return;
    const orig = btn && btn.innerHTML;
    if (btn) { btn.disabled = true; btn.innerHTML = `<span class="spinner"></span> Loading…`; }
    try {
      const r = await fetch(w.zipUrl, { cache: "no-store" });
      if (!r.ok) throw new Error("HTTP " + r.status);
      await importZip(await r.blob());
      state.walkId = w.id;   // now editing an owned published walk → publish offers "Update existing"
      $("walksModal").hidden = true;
      toast(`Loaded “${w.name}”. Edit, then Publish → Update existing walk.`, "ok");
    } catch (e) {
      toast("Load failed: " + e.message, "err");
    } finally {
      if (btn) { btn.disabled = false; btn.innerHTML = orig; }
    }
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


  // ---- Artist details: display name + markdown bio + page colour, stored per account --------
  // The profile lives server-side at artists/<id>.json (id derived from the Google account), so
  // one edit re-labels every walk instead of each bundle carrying its own creator string.
  const ARTIST_BG_DEFAULT = "#101014";
  let artistProfile = null;

  function renderArtistPreview(src) { renderMarkdownInto($("artistPreview"), src); }

  // Perceived luminance (BT.601), the same test the app uses to pick light or dark text.
  function isDarkHex(hex) {
    if (!/^#[0-9a-fA-F]{6}$/.test(hex || "")) return false;
    const n = parseInt(hex.slice(1), 16);
    return (0.299 * ((n >> 16) & 255) + 0.587 * ((n >> 8) & 255) + 0.114 * (n & 255)) / 255 < 0.55;
  }

  /// Dress the bio preview in the artist's page colour so it previews the page itself. On "use
  /// system colors" it falls back to the editor's own panel, matching the app's default background.
  function applyArtistPreviewTheme() {
    const box = $("artistPreview");
    const custom = !$("artistBgAuto").checked && /^#[0-9a-fA-F]{6}$/.test($("artistBg").value);
    box.style.background = custom ? $("artistBg").value : "";
    box.classList.toggle("on-dark", custom && isDarkHex($("artistBg").value));
  }

  function renderMarkdownInto(box, src) {
    const text = (src || "").trim();
    if (!text) { box.innerHTML = `<p class="md-preview-empty">Preview appears here.</p>`; return; }
    // Sanitize even though it is the author's own text — the same markdown is rendered elsewhere.
    if (window.marked && window.DOMPurify) box.innerHTML = DOMPurify.sanitize(marked.parse(text, { breaks: true }));
    else box.textContent = text;                     // CDN blocked → readable fallback
  }

  /// Adopt a profile from the server: the display name is the creator on every walk.
  function applyArtistProfile(p) {
    if (!p) return;
    artistProfile = p;
    if (p.name) { state.creator = p.name; $("mapCreator").value = p.name; }
  }

  /// `hex` null/blank ⇒ "use system colors": the swatch shows the fallback but is disabled, and
  /// saving writes no colour so the app supplies its own background and text.
  function setArtistBg(hex) {
    const custom = /^#[0-9a-fA-F]{6}$/.test(hex || "");
    const v = custom ? hex.toLowerCase() : ARTIST_BG_DEFAULT;
    $("artistBgAuto").checked = !custom;
    $("artistBg").disabled = !custom;
    $("artistBgHex").disabled = !custom;
    $("artistBg").value = v; $("artistBgHex").value = v;
  }
  function updateArtistBioCount() {
    $("artistBioCount").textContent = `${$("artistBio").value.length} / 20000`;
  }

  function openArtistModal() {
    if (!idToken || !userEmail) { toast("Sign in with Google first.", "err"); return; }
    closeMenu();
    const p = artistProfile || {};
    $("artistError").hidden = true;
    $("artistName").value = p.name || state.creator || "";
    $("artistBio").value = p.bio || "";
    setArtistBg(p.bgColor);
    updateArtistBioCount();
    renderArtistPreview($("artistBio").value);
    applyArtistPreviewTheme();
    $("artistModal").hidden = false;
  }

  async function saveArtistDetails() {
    const btn = $("artistSave");
    const orig = btn.innerHTML;
    const name = $("artistName").value.trim();
    if (!name) { $("artistError").textContent = "A display name is required."; $("artistError").hidden = false; return; }
    btn.disabled = true; btn.innerHTML = `<span class="spinner"></span> Saving…`;
    $("artistError").hidden = true;
    try {
      const r = await fetch(CFG.publishApiUrl, {
        method: "POST",
        headers: { "Authorization": "Bearer " + idToken, "Content-Type": "application/json" },
        body: JSON.stringify({
          action: "artistPut", name, bio: $("artistBio").value,
          bgColor: $("artistBgAuto").checked ? null : $("artistBg").value,
        }),
      });
      if (!r.ok) throw new Error((await r.text().catch(() => "")) || ("HTTP " + r.status));
      applyArtistProfile((await r.json()).artist);
      $("artistModal").hidden = true;
      toast("Artist details saved. Republish a walk to update its credit.", "ok");
    } catch (e) {
      $("artistError").textContent = "Couldn't save: " + e.message;
      $("artistError").hidden = false;
    } finally { btn.disabled = false; btn.innerHTML = orig; }
  }

  $("mArtist").onclick = openArtistModal;
  $("creatorArtistLink").onclick = openArtistModal;
  $("artistClose").onclick = () => { $("artistModal").hidden = true; };
  $("artistCancel").onclick = () => { $("artistModal").hidden = true; };
  $("artistSave").onclick = saveArtistDetails;
  $("artistBio").oninput = () => { updateArtistBioCount(); renderArtistPreview($("artistBio").value); };
  $("artistBgAuto").onchange = (e) => {
    $("artistBg").disabled = e.target.checked;
    $("artistBgHex").disabled = e.target.checked;
    applyArtistPreviewTheme();
  };
  $("artistBg").oninput = (e) => {
    $("artistBgHex").value = e.target.value.toLowerCase();
    applyArtistPreviewTheme();
  };
  $("artistBgHex").oninput = (e) => {
    if (!/^#[0-9a-fA-F]{6}$/.test(e.target.value)) return;
    $("artistBg").value = e.target.value.toLowerCase();
    applyArtistPreviewTheme();
  };

  $("pubClose").onclick = closePublishModal;
  $("pubCancel").onclick = closePublishModal;
  $("pubConfirm").onchange = () => {
    rightsConfirmedAt = $("pubConfirm").checked ? new Date().toISOString() : null;
    updatePubGo();
  };
  $("pubGo").onclick = () => runPublish("new");
  $("pubUpdate").onclick = () => runPublish("update");
  $("successClose").onclick = () => { $("successModal").hidden = true; };
  $("successDownload").onclick = downloadQr;
  $("successCopy").onclick = async () => {
    const url = $("successLink").href;
    try {
      await navigator.clipboard.writeText(url);
      toast("Link copied.", "ok");
    } catch (_) {
      // Clipboard API needs a secure context / permission — fall back to a manual select.
      const t = document.createElement("textarea");
      t.value = url; document.body.appendChild(t); t.select();
      const ok = document.execCommand("copy");
      t.remove();
      toast(ok ? "Link copied." : "Couldn't copy — select the link above.", ok ? "ok" : "err");
    }
  };
  $("walksClose").onclick = () => { $("walksModal").hidden = true; };
  initAuth();

  setMode("edit");
  renderSide();
  renderRoutes();
  resetHistory();   // establish the initial (empty) history baseline
})();
