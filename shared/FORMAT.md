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
  "center": [40.8988, -73.9109],    // default map center [lat, lng] (author's view)
  "zoom": 16,
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
      "falloff": "none"             // circle loops only: "none" | "linear" | "exponential" | "edge"
    }
  ]
}
```

### Playback modes (identical semantics in the web preview and the iOS app)

- **`loop`** — starts the moment the listener enters the shape and loops continuously,
  fading in over `fadeIn` and, on exit, fading out over `fadeOut`. Layers freely with every
  other sounding shape.
- **`oneshot`** — plays exactly once on entry and always runs to completion, even if the
  listener leaves. No fades. Re-arms only after the listener has exited and re-entered.
- **`syncedLoop`** — starts the instant playback begins (regardless of where the listener is)
  and loops forever in **sample-lock with every other synced loop** — all launched at one shared
  start time so rhythmic material stays aligned. It keeps running even when silent; location only
  gates its **volume** (respecting `gain`, `falloff`, and `fadeIn`/`fadeOut` on region enter/exit).
  All synced clips must be resident at once, so the practical ceiling is total decoded audio fitting
  in memory (~1 GB) — dozens of short loops are fine.
- **`dialogue`** — like `oneshot` (plays through, no fade in), **but** when any *other*
  dialogue shape begins, this one fades out. Only one dialogue is ever foregrounded.

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
