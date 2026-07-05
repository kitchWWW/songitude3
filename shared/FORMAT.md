# Sound Walk bundle format

A bundle is a `.zip` file with this layout:

```
bundle.zip
├── map.json          # the map definition (below)
├── albumart.jpg      # optional; lock-screen art (any image; original filename preserved in map.json)
└── audio/
    ├── <file1>.mp3   # audio clips, original filenames preserved
    ├── <file2>.wav
    └── ...
```

## `map.json`

```jsonc
{
  "version": 1,
  "name": "How Fragile We Bloom",   // title; shown as the lock-screen "track" title
  "creator": "Chromic Duo",         // author/composer (optional)
  "about": "A meditative walk …",   // description, up to 2000 chars (optional)
  "albumArt": "albumart.jpg",       // filename in the zip root, or null
  "intro": "intro.mp3",             // filename under audio/, or null — plays once when a walk begins
  "introGain": 1.0,                 // 0..1 playback level for the intro clip (absent ⇒ 1.0)
  "exit": "outro.mp3",              // filename under audio/, or null — plays when the listener ends the session
  "exitGain": 1.0,                  // 0..1 playback level for the exit clip (absent ⇒ 1.0)
  "center": [40.8988, -73.9109],    // default map center [lat, lng] (author's view)
  "zoom": 16,

  // Per-walk colors for the four dialogue playback states (optional; defaults shown). Dialogue
  // shapes are colored by their state instead of a per-shape color. See "dialogue" below.
  "dialogueColors": {
    "unplayed": "#8a63d2",
    "queued":   "#f5a623",
    "playing":  "#2ecc71",
    "finished": "#ffffff"
  },

  "shapes": [
    {
      "id": "s_ab12cd",
      "name": "Meadow loop",
      "type": "circle",             // "circle" | "polygon"
      "color": "#e6194b",

      // circle only:
      "center": [40.8990, -73.9110],
      "radius": 45.0,               // meters

      // polygon only:
      "points": [[lat, lng], [lat, lng], ...],   // ordered ring, not closed

      "audioFile": "meadow.mp3",    // filename under audio/, or null
      "mode": "loop",               // "loop" | "syncedLoop" | "oneshot" | "dialogue"
      "gain": 1.0,                  // 0..1 linear playback level
      "fadeIn": 2.0,                // seconds  (loop mode)
      "fadeOut": 3.0,               // seconds  (loop mode)
      "loopMode": "simple",         // loop mode only: "simple" | "crossfade" (absent ⇒ "simple")
      "crossfade": 1.0,             // seconds  (crossfade loops); overlap between the outgoing/incoming copy
      "falloff": "none"             // circle loops only: "none" | "linear" | "exponential" | "edge"
    }
  ]
}
```

### Playback modes (identical semantics in the web preview and the iOS app)

- **`loop`** — starts the moment the listener enters the shape and loops continuously,
  fading in over `fadeIn` and, on exit, fading out over `fadeOut`. Layers freely with every
  other sounding shape. `loopMode` picks how the clip repeats:
  - **`simple`** (default) — the clip restarts the instant it ends (a hard seam).
  - **`crossfade`** — as the clip nears its end a fresh copy starts, fading in over `crossfade`
    seconds while the outgoing copy fades out over the same window (loop period = clip length −
    `crossfade`). `crossfade` is clamped to at most half the clip length at playback.
- **`oneshot`** — plays exactly once on entry and always runs to completion, even if the
  listener leaves. No fades. Re-arms only after the listener has exited and re-entered.
- **`syncedLoop`** — starts the instant playback begins (regardless of where the listener is)
  and loops forever in **sample-lock with every other synced loop** — all launched at one shared
  start time so rhythmic material stays aligned. It keeps running even when silent; location only
  gates its **volume** (respecting `gain`, `falloff`, and `fadeIn`/`fadeOut` on region enter/exit).
  All synced clips must be resident at once, so the practical ceiling is total decoded audio fitting
  in memory (~1 GB) — dozens of short loops are fine.
- **`dialogue`** — plays through **once, ever** (no fade in, always to completion). Only one
  dialogue sounds at a time: if the listener enters a dialogue region while another dialogue is
  playing, this one **queues** and plays when the current one finishes (FIFO). A dialogue that has
  finished does not play again for the session. A dialogue shape is not colored individually —
  its fill shows its current state using the walk's `dialogueColors`: `unplayed` before entry,
  `queued` while waiting, `playing` while sounding, `finished` (faded/see-through) once done.
  Pausing playback lets any not-yet-finished dialogue play again on resume.

### Intro & exit dialogue (`intro`, `exit`)

Optional walk-level clips stored under `audio/`, independent of any shape:

- **`intro`** — plays once, over the top of normal playback, when a walk **begins**. Players gate it
  so it does *not* replay when you resume the same walk shortly after (a ~1 hour per-walk window),
  but does play again on a later visit. (The editor's "Do intro" button always plays it.)
- **`exit`** — the "end the session" clip. When the listener ends the session: any currently-playing
  dialogue fades out over **1 s**, then the exit clip starts while loops/other sounds keep playing;
  once the exit clip finishes, **all** remaining sound fades out over **5 s** and playback stops. In
  the apps this ends the session; in the editor's "Do outro" preview it returns to normal playback.

### Proximity falloff (`falloff`, circle loops only)

For a circle in `loop` mode, `falloff` scales the gain by the listener's distance from the
center (`r` = distance / radius, 0 at center → 1 at edge):

- **`none`** — full gain anywhere inside (binary in/out). Default.
- **`linear`** — `1 - r` (loudest at center, silent at the edge).
- **`exponential`** — `(1 - r)²` (falls off faster near the edge).
- **`edge`** — flat full gain from the center out to `0.5·radius`, then a linear drop to 0 at
  the edge.

Ignored for polygons and for `oneshot`/`dialogue` circles.

Geometry is interpreted in WGS-84 lat/lng. Containment: circles use great-circle distance ≤
`radius`; polygons use even-odd ray casting on lat/lng.
