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
  "about": "A meditative walk …",   // description, up to 2000 chars, Markdown (optional)
  "introColor": "artist",           // intro-card backdrop: "artist" (follow the artist's page
                                    //   colour), "#rrggbb" (custom), or absent/null (the app's own
                                    //   background, following its light/dark setting)
  "albumArt": "albumart.jpg",       // filename in the zip root, or null
  "intro": "intro.mp3",             // filename under audio/, or null — plays once when a walk begins
  "introGain": 1.0,                 // 0..1 playback level for the intro clip (absent ⇒ 1.0)
  "exit": "outro.mp3",              // filename under audio/, or null — plays when the listener ends the session
  "exitGain": 1.0,                  // 0..1 playback level for the exit clip (absent ⇒ 1.0)
  // Present ⇒ a transportable walk: players move and turn the whole composition so this pin lands
  // on the listener, facing the way they face. Absent ⇒ the walk is geo-locked where it was drawn.
  "startAnchor": { "lat": 40.8988, "lng": -73.9109, "heading": 0 },

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

  // How sound areas are drawn for listeners (optional; absent ⇒ "classic").
  "displayStyle": "classic",        // "classic" | "fuzzy"

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
      "falloff": "none",            // circle loops only: "none" | "linear" | "exponential" | "edge"
      "solo": false,                // absent ⇒ false; standing inside this area silences non-soloed areas
      "hidden": false               // absent ⇒ false; true ⇒ sounds normally but is never drawn for listeners
    }
  ],

  "routes": [                       // optional; absent or [] ⇒ nothing drawn
    {
      "id": "r_7f3a",
      "name": "The long way round",
      "points": [[lat, lng], [lat, lng], ...],   // ordered, open (never closed); at least 2
      "color": "#111111",
      "width": 6,                   // stroke width in px / points
      "startLabel": "Start here",   // "" or absent ⇒ a plain marker with no text
      "endLabel": ""
    }
  ]
}
```

### Intro card (`introColor`)

Opening a walk in the iOS app shows a card over the map with the walk's `name`, its `creator`
(linked to the artist's page when the walk was published with an `artistId`) and its `about` text.
`introColor` is the card's background, authored on the editor's **Details** tab, which offers three
choices:

| Editor choice | `introColor` | Reader behaviour |
|---|---|---|
| Use artist colors *(default)* | `"artist"` | Look up the walk's artist (`artistId` in the manifest) and use their page colour; if the artist uses system colours, so does the card. |
| Use system colors | absent / `null` | The reader's own background, following its Light/Dark/System setting. |
| Use custom color | `"#rrggbb"` | Exactly that colour. |

When a colour resolves to an actual value, readers pick black or white text from its luminance, so
any backdrop stays readable. Readers that predate `"artist"` treat the unknown string as no colour
and fall back to their own background, which is the safe outcome.

An artist's page colour (`bgColor` in `artists/<id>.json`) follows the same rule: absent ⇒ the app's
own background.

The card is shown the first time a walk is opened in a rolling ~10 minute window, so moving around
the app doesn't keep re-showing it. It is dismissed by its play button (which also starts playback)
or the ✕ in its top-left corner, and can be summoned again by tapping the walk's name in the top bar.

The field is UI-only: it does not affect playback, and players that don't draw an intro card
(the web player today) simply ignore it.

### Transportable walks (`startAnchor`)

A walk with no `startAnchor` is **geo-locked**: its areas sit at the coordinates they were drawn at.

With one, the walk is **listen-from-anywhere**. `startAnchor` is `{ lat, lng, heading }`, authored by
ticking "Listen from anywhere" on the editor's Details tab and dragging the pin;
`heading` is degrees clockwise from true north.

When such a walk opens, the player reads the listener's position and compass heading once and
applies a single rigid transform to every shape: translate so the anchor lands on the listener, then
rotate by (listener heading − anchor heading). Radii and the distances and bearings between areas are
untouched, so the composition plays exactly as written — just somewhere else, pointing somewhere
else. The transform is computed once when the walk opens and then held for the session, so turning
around doesn't spin the world.

If no location fix is available the walk is left where it was authored rather than guessed at. The
manifest exposes this as `portable`, which the apps use to split the catalog into "Geo-Locked" and
"Listen From Anywhere".

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

### Solo (`solo`)

Optional boolean on any shape, circle or polygon. Absent ⇒ `false` ⇒ the historical behaviour, where
overlapping areas simply layer.

While the listener stands inside **at least one** soloed area, only soloed areas are audible: every
non-soloed area the listener is simultaneously inside ducks to silence. Step back out and it returns.
Overlapping soloed areas do **not** duck each other — if two soloed areas overlap and the listener is
in both, both play.

Solo is a **gain duck, not a stop**: the ducked voice keeps running underneath at zero, so it comes
back exactly where it would have been rather than restarting. That matters most for `dialogue`, which
plays once ever — a dialogue ducked by a solo keeps advancing silently and can finish while inaudible.
There are deliberately **no per-mode exceptions**: loops, synced loops, one-shots and dialogue all duck
the same way. Ducking in and out uses the ducked shape's own `fadeOut` / `fadeIn`.

Walk-level `intro` and `exit` clips are never ducked — they aren't shapes and the listener isn't
"inside" them.

A soloed area with no `audioFile` is legal and useful: it silences everything else while the listener
is inside it, i.e. a hole of quiet punched through the walk.

### Hidden (`hidden`)

Optional boolean on any shape, circle or polygon. Absent ⇒ `false` ⇒ drawn as it always was.

`true` means the area is **audible but never drawn for a listener**: the iOS map, the web player's map,
and the editor's own Listen mode all skip it entirely (no outline, no fill, no sounding highlight). It
still sounds exactly as it otherwise would — `hidden` has no effect on playback whatsoever.

The editor's **Edit** mode always draws hidden areas, marked as hidden, so they stay selectable and
editable. Only the listener-facing renderings hide them.

### Display style (`displayStyle`)

Optional walk-level string, `"classic"` or `"fuzzy"`. Absent — or any unrecognised value — ⇒
`"classic"`, which is how every walk published before this field was drawn.

`classic` is the original look: each area is stroked with a solid outline and filled translucently.

`fuzzy` removes the outline entirely and feathers the fill outward instead, over a band **8% of the
area's own size** (its radius for a circle, half its smaller on-screen dimension for a polygon). The
band is proportional, so it holds its look at every zoom and has to be recomputed when the scale
changes. Polygons additionally take a round-jointed stroke in the fill's own colour, which rounds
their corners off into blobs rather than leaving hard vertices under the blur.

It is **purely visual**: `displayStyle` never affects containment, gain, triggering or any other
part of playback, and a walk sounds identical either way. Dialogue areas still take their colour
from `dialogueColors` and still show all four states; only the edge treatment changes.

Renderers reach the same look by different means, since the two map engines feather differently:

- **Web + editor (Leaflet/SVG)** — a CSS `blur()` on the path, sized from the shape's pixel radius,
  with the stroke set to match the fill.
- **iOS (MapKit)** — a radial gradient for circles, and for polygons a stack of round-jointed
  strokes clipped to the area's exterior, so the feather falls outward and the interior stays flat.

The editor draws `fuzzy` on the **Listen tab only**. Edit mode keeps hard outlines: vertex and
radius handles are unusable on a blurred shape.

### Suggested routes (`routes`)

Optional array of drawn paths. Absent or empty ⇒ nothing is drawn, which is what every walk
published before this field did.

A route is **purely visual**. It carries no audio, has no containment test, never gates or triggers
anything, and has no relationship to any shape. The only thing it does is show a listener where the
walk means them to go. Nothing about playback changes whether a walk has routes or not.

- `points` — ordered `[lat, lng]` pairs, **open**: the last point is never joined back to the first.
  Fewer than two points is not drawable and readers skip it.
- `color` / `width` — per route, so several routes can be told apart. Defaults `#111111` and `6`.
- `startLabel` / `endLabel` — text beside the first and last point. Empty or absent ⇒ a plain marker
  with no text, which is the right choice when the path speaks for itself.

Routes are stroked with **round caps and round joins** in every renderer (Leaflet `lineCap`/
`lineJoin`, `MKPolylineRenderer.lineCap`/`lineJoin`), so bends read as smooth curves rather than
mitred corners. They are drawn **beneath** the sound areas.

A route on a transportable walk (one with a `startAnchor`) is transposed along with everything else,
so the path lands around the listener rather than staying where it was authored.

Geometry is interpreted in WGS-84 lat/lng. Containment: circles use great-circle distance ≤
`radius`; polygons use even-odd ray casting on lat/lng.
