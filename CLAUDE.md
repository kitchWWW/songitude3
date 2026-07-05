# Songitude

Location-based sound walks. Authors draw sound areas on a map and assign audio; listeners walk
the real space and hear it via GPS. One bundle format is shared across every component.

## Components

| Dir | What it is | Stack |
|-----|-----------|-------|
| `editor/` | Front-end-only authoring app. Draw shapes, assign audio, preview with a virtual listener, export/import `.zip`, publish. | Vanilla JS IIFE, no build step. Leaflet + JSZip + qrcode-generator + Google Identity, all via CDN. |
| `ios/` | SwiftUI app that plays a bundle for real using GPS, with background audio. | SwiftUI, AVAudioEngine, CoreLocation, MapKit. |
| `web/` | Marketing site, browser player (`listen/`), privacy/support pages, deep-link landing (`w.html`), AASA. | Vanilla JS + Leaflet. |
| `aws/` | Serverless publish backend: two Node 20 Lambdas + an S3 bucket. | AWS SDK v3, `adm-zip`. |
| `shared/FORMAT.md` | **Source of truth** for the bundle format. Update it when the format changes. | — |

There is no monorepo tooling — each component is independent. No test suite; verify by exercising
the actual app/editor.

## Bundle format (see `shared/FORMAT.md`)

A `.zip` with `map.json` (map + shapes), `audio/<files>`, and optional album art at the root.
`map.json` has `version`, `name`, `creator`, `about`, `albumArt`, `intro`/`exit` (walk-level
clips under `audio/`), `center`, `zoom`, `dialogueColors`, and `shapes[]`. Each shape: `id`, `name`, `type` (circle|polygon), `color`,
geometry (`center`+`radius` or `points`), `audioFile`, `mode`, `gain`, `fadeIn`, `fadeOut`,
`falloff`. The **same `map.json`** is produced by the editor, unpacked into S3 by the manifest
Lambda, and consumed by both the iOS app and the web player.

### Bundle backwards compatibility (REQUIRED)

The bundle format is versioned but **must stay backwards compatible**: walks published with older
editors keep playing in newer apps/players without migration. When you add or change anything in
`map.json` (walk-level or per-shape):

- **Only add optional fields.** Never rename, repurpose, or remove an existing field, and never make
  a previously-optional field required.
- **A missing field must decode to the old behavior.** Every reader supplies the historical default
  when the key is absent (e.g. `loopMode` absent ⇒ `"simple"`; `dialogueColors`/`intro`/`exit` absent
  ⇒ none). iOS relies on optional Swift properties + fallbacks; JS uses `x ?? default`.
- Apply the default in **all four readers** (editor, web player, iOS, and the manifest Lambda if it
  reads the field) and document the new field + its default in `shared/FORMAT.md`.
- Don't gate a new field behind a `version` bump that old readers reject — bump `version` only for a
  genuinely breaking change, which we avoid.

### Playback modes — semantics MUST stay identical in all three engines

The editor preview (`editor/editor.js` `engine`), the web player (`web/listen/player.js`), and the
iOS app (`ios/.../AudioEngine.swift`) each implement the same state machine. **Change one → change
all three** (and `FORMAT.md`).

- `loop` — loops while inside; fades in/out; circle loops honor `falloff` (proximity gain).
- `syncedLoop` — all synced clips launch sample-aligned at one shared start time and run forever;
  location only gates volume. Must stay resident in memory to hold sync.
- `oneshot` — plays once to completion on entry; re-arms after exit.
- `dialogue` — plays **once ever**; one at a time; entering while another dialogue plays **queues**
  it (FIFO). Colored by state (`unplayed`/`queued`/`playing`/`finished`) via the walk's
  `dialogueColors`, not a per-shape color. Colors are authored on the editor's **Details tab** and
  saved in the bundle.
- `intro`/`exit` — walk-level clips (Details tab). Intro plays once at start, gated ~1 h per walk so
  it doesn't replay on resume. Exit is the "end session" sequence: fade dialogue (1 s) → exit clip →
  fade everything (5 s) → stop. Apps trigger exit via an "All done?" button that appears 30 s after
  start; the editor's Listen tab has "Do intro"/"Do outro" buttons ("Do outro" returns to normal
  playback afterward instead of ending).

## Editor notes (`editor/editor.js`, ~1600 lines, single IIFE)

- One central mutable `state` object; side-stores (`audioStore`, `decoded`, `artStore`) keyed by
  filename. Undo/redo = JSON snapshots (`snapshot`/`restoreSnapshot`) — keep `serializeShape`,
  `importZip`, and `restoreSnapshot` in lockstep when adding a shape field.
- Sections are marked with banner comments (SHAPE MODEL, DRAWING, ENGINE, ZIP I/O, etc.).
- `bundleMeta()` builds `map.json`. `state.dialogueColors` is per-walk and round-trips through
  bundle + undo snapshots.
- Publishing: Google sign-in → allowlist check → presigned S3 PUT. `editor/config.js` holds the
  real endpoints/client id (not placeholders).

## iOS notes (`ios/Songitude/Songitude/`)

- `AppState` is the coordinator: owns `LocationManager`, `RenderEngine`, `RemoteCatalog`; wires GPS
  fixes (with slewing) into the engine and forwards child `objectWillChange`.
- `RenderEngine` (`AudioEngine.swift`): one `AVAudioPlayerNode` per sounding shape; proximity-based
  buffer residency (decode within 300 m, evict beyond 600 m); handles the audio session,
  interruptions (call/Siri auto-resume), route changes (headphones out → pause), and config changes.
  Publishes `soundingShapeIDs` and `dialogueStates` to drive the map.
- Location runs **only while playing** (privacy + battery). `RemoteCatalog` re-sorts nearest-first
  as fixes arrive and when the browser opens (`resort`).
- Bundles come from `Bundled/` (unzipped from `Experiences/*.zip` at build time by
  `import_experiences.sh`) or downloaded from the remote catalog into Caches — both yield the same
  `Experience` struct.
- Can't build here (no Xcode SDK) — SourceKit "cannot find type" / "No such module 'UIKit'" errors
  in this environment are cross-file resolution noise, not real. Verify in Xcode on a device (GPS +
  background audio need real hardware).

## AWS notes (`aws/`)

- `presign` Lambda (public Function URL, auth in-code via Google token + `ALLOWED_EMAILS`): verifies
  the token, gates publish/update/delete by owner, returns a presigned PUT to
  `walks/<id>/bundle.zip`.
- `manifest` Lambda (S3 ObjectCreated trigger): unpacks the zip into per-file objects and rebuilds
  `walks/manifest.json`. **Depends on `adm-zip`** — `deploy.sh`'s `deploy_fn` bundles `node_modules`
  when a `package.json` is present (the runtime ships only the AWS SDK). Don't strip that step.
- Read is fully public (`walks/*`); publish is invite-only. Deploy with `bash aws/deploy.sh` after
  setting `GOOGLE_CLIENT_ID` and `ALLOWED_EMAILS`.

## Conventions

- Match the surrounding style: terse vanilla JS in the web/editor; documented Swift with `// MARK:`
  sections in iOS. Comments explain *why*, not *what*.
- No frameworks or build steps in the editor/web — keep them CDN-loaded and open-in-browser.
- When touching playback behavior or the bundle shape, update `FORMAT.md` and all three engines.
