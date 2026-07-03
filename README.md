# Songitude

A location-based audio experience system in two parts:

1. **`editor/`** — a front-end-only web app (no server, no build step) for authoring
   sound maps. Draw circles and polygons on a Leaflet map, assign audio files, choose
   playback behavior, preview with a virtual listener, and export everything as a single
   `.zip` bundle.
2. **`ios/`** — a SwiftUI iOS app that plays a bundle back for real, using the phone's
   GPS. Audio keeps rendering in the background (locked phone, in-pocket) and stops only
   when the app is fully quit.

The two halves share one bundle format (see `shared/FORMAT.md`).

## Quick start — Editor

```bash
open editor/index.html      # or drag it into any browser
```

No install. Leaflet and JSZip load from CDN, but everything runs client-side; nothing is
uploaded anywhere. Author a map, then **Export .zip**. Re-open it later with **Import .zip**.

## Quick start — iOS app

```bash
open ios/Songitude/Songitude.xcodeproj
```

1. Drop one or more exported `.zip` bundles into `ios/Songitude/Experiences/`.
2. Run `ios/Songitude/import_experiences.sh` (or let the Xcode build phase do it) to
   unpack them into the app bundle.
3. Select your team, build to a device (GPS + background audio need a real device), run.

See `ios/README.md` for details.

## Credits

- **Brian Ellis** — Creative Coder — <http://brianellissound.com>
- **Chromic Duo** (Lucy Yao & Dorothy Chan) — Composer & Creative Director — <https://www.chromic.space>
