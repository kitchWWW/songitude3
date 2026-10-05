# Keeping Chromic (Android) in step with Songitude (Android)

`android-chromic/` was copied from `android/` on 2026-09-18 (with the uncommitted decode/download
work of that date included) and then branded. The Kotlin package was deliberately **not** renamed,
so a patch against `android/` applies here with only the directory prefix rewritten:

```bash
# What has drifted, ignoring the deliberate brand differences.
diff -ru android/app/src/main/java android-chromic/app/src/main/java \
  -x Brand.kt -x FirstRunScreen.kt -x AboutScreen.kt -x SoundwalksScreen.kt -x WalkDetailScreen.kt -x ContentStore.kt -x WalkDownloads.kt -x SquiggleField.kt -x seed

# Port a single commit's android/ changes, then resolve any rejects.
git format-patch -1 <sha> --stdout -- android/app/src/main \
  | sed -e 's#android/app/src/main/#android-chromic/app/src/main/#g' \
  | git apply -3 --reject
```

Expected, permanent differences — do not "fix" these when diffing:

- `app/build.gradle.kts`: `applicationId`, `versionCode`/`versionName` (reset to 1 / 1.0).
- `res/`: `strings.xml` (app name), `colors.xml`, `themes.xml` (launch), `drawable/launch_splash.xml`,
  `drawable/ic_notification.xml`, the adaptive icon (`mipmap-anydpi-v26`, `drawable-nodpi/ic_launcher_*`),
  everything in `drawable-nodpi/` and `font/`. `raw/resume_needs_app.mp3` is regenerated in the same ElevenLabs voice
  (River) saying "Chromic" where Songitude's says "Songitude" — never copy it across. Songitude's `ic_launcher_*.xml` / `splash_mark.xml`
  vectors are gone.
- `MainActivity.kt`: **rewritten** root — `FirstRun` (the welcome + the two permission pages, the
  permission plumbing itself verbatim from Songitude, each page skipped when already granted),
  `HomeRoot` (About → Soundwalks → walk with the map as an overlay, opening on Soundwalks, system
  Back walking it) and `HomeSession`, the process-scoped navigation state and background timer
  (`onStart` / `onStop`). Songitude's `Route`/splash/auto-open-the-list logic is gone. Nav logging
  under `ChromicNav`. See "Launch and return" below.
- `AppState.kt`: `maybeShowIntroCard` / `presentIntroCard` gated on `Brand.SHOWS_INTRO_CARD`; the
  `artistId` filter in `refreshCatalog`; `init` opens on the cached manifest, `refreshCatalog` and
  `loadArtist` go through `ContentStore` (cache-then-seed, store on fetch), `contentVersion`.
- `app/build.gradle.kts`: the `refreshSeed` task on `preBuild`. `data/ContentStore.kt` and
  `assets/seed/` are Chromic-only.
- `ui/MapScreen.kt`: `onOpenBrowser` → `onShowWalk` + `onBrowse`; Dorothy's icons for settings,
  home, play/pause (the disc *is* the button) and ±15 s; the title button leaves for the walk page.
- `ui/Cards.kt`: the intro card's close icon (unreachable, kept in step).
- `ui/screens/ReportSheet.kt`: footer wording and the `"app"` field.
- `ui/screens/SettingsScreen.kt`: credits rows, "Reset Chromic?".
- `service/PlaybackService.kt`: `Brand.NAME` for the session tag and notification title;
  `ic_notification` as the small icon.
- **Prefetch on the walk's page**: `data/WalkDownloads.kt` (Chromic-only) holds every download in
  flight, one per walk id, on the Application (`SongitudeApp.downloads`) rather than in
  `viewModelScope`. `WalkDetailScreen` calls `AppState.prefetch` when it opens; `openRemote`
  *claims* that download and watches its progress/map instead of starting its own, so the ring
  resumes where the prefetch got to and a destroyed Activity no longer kills a download. An
  unclaimed prefetch is cancelled by opening another walk's page, and by delete / Reset Cache /
  Reset App; backing out lets it finish. `WalkDownloader.download` un-marks `.complete`/`.version`
  before rewriting map.json and checks cancellation per chunk and before `.complete`. All of that
  but the page trigger would port cleanly to Songitude (whose list starts the download on tap);
  the Application-scoped download alone would fix the same Activity-death trap there. The walk
  page's button always reads "Start" (was "Open map" for the loaded walk; it still just returns
  to the map).
- `ui/screens/FirstRunScreen.kt` carries the Play Prominent Disclosure for location (Songitude's is
  `OnboardingScreen.kt`). Both must name *location data*, its locked-screen use, and that it is never
  shared, above the Continue button — Songitude 1.0.1 was rejected for less. No background location
  is requested in either app.
- Chromic-only files: `ui/Brand.kt`, `ui/screens/FirstRunScreen.kt`, `AboutScreen.kt`,
  `SoundwalksScreen.kt`, `WalkDetailScreen.kt`, `data/WalkDownloads.kt`, `ui/SquiggleField.kt`.
- `ui/SquiggleField.kt`: the landing's drifting squiggles, lifted out of `FirstRunScreen.kt` so
  the Soundwalks list draws them too: wash → squiggles → list, all siblings in one `Box`, so the
  field (like the wash) stays put while the cards scroll, and it has no pointer input. Welcome
  fades it behind the permission copy; the list uses it unfaded. Twin: `SquiggleField` in
  `ios-chromic/.../Brand.swift`.
- Soundwalks' way back to About is the map's settings cloud on the same 44dp chip as
  `GlassCircleButton` (`ScreenHeader(back = HeaderBack.About)`, drawable in `Brand.AboutButton`),
  described as "About". System Back still walks the stack. When Dorothy's gear lands, change only
  the settings button's drawable in `MapScreen`; the About button keeps the cloud. Twin:
  `ios-chromic/SYNC.md` (`WalksBrowserView.swift`).
- **"Chromic Duo" shows as "Chromic".** Older published walks (and the artist profile) carry the
  old name and can't be re-published, so `Brand.displayCreator` (an extension appended to
  `ui/Brand.kt`) maps a creator of "Chromic Duo" (trimmed, any case) to `Brand.NAME` for display;
  other names pass through. Every reader goes through it: `RemoteWalk.creatorText` and
  `ArtistProfile.displayName` (`data/RemoteCatalog.kt`) and a new getter-only
  `SoundMap.creatorText` (`model/Models.kt`, not serialized), which `ui/Cards.kt` and
  `SettingsScreen.kt` read instead of `map.creator`. Stored/fetched JSON and the `artistId`
  filter are untouched. Twin: `Brand.displayCreator(_:)` in `ios-chromic/.../Brand.swift`.

## Launch and return

The flow, decision for decision with `ios-chromic/SYNC.md`:

- **Cold start** (a new process — a swipe-away, or the system killing it, included): always the
  welcome, then the location page **only if** `ACCESS_FINE_LOCATION` isn't granted (coarse-only still
  gets it), then the notification page (13+) only if notifications aren't allowed, then
  **Soundwalks**. `hasOnboarded` is still recorded — it gates deep links and "Reset app" clears it —
  but no longer decides whether the welcome shows.
- **Soundwalks is the landing hub.** The stack is About with Soundwalks on it
  (`HomeSession.LANDING`), so the cloud is an ordinary pop to About, About's "Soundwalks" button
  pushes the list again, the artist's name clears the path to About, and system Back from
  Soundwalks goes to About, then out. Walks go deeper as before (walk page → Start → map).
- **Back from the background** (`onStop` → `onStart`): within `Brand.RESUME_WINDOW_MS` (5 min)
  nothing moves. Longer, and the app starts over at the welcome and lands on Soundwalks — **unless a
  walk is under way**: the engine is running, or the map is on screen (playing or paused), sampled
  when leaving *and* on return.
- **Activity recreation is not a cold start.** `HomeSession` is an `object` — process lifetime, like
  the engine and `SongitudeApp.loadedExperience` — so a recreated Activity keeps its page, its
  welcome-passed flag and the time already spent away (`elapsedRealtime`, which counts deep sleep).
  A process death resets it, which is what makes that a cold start.
- The map opens when a walk becomes current that hasn't been announced yet (Start, a deep link —
  also one that arrives during the welcome). Adopting the playing walk on a recreated Activity, or
  starting over with a loaded-but-idle walk, doesn't pop its map up. This replaces LIFECYCLE L10's
  "reopen → map": a recreated Activity now returns to whichever page it was on.

About is no longer where a later open lands.

- **"Play Outro" reads "Say Goodbye".** Chromic's wording for the end-session button on the map; the
  behavior (exit sequence, 30 s offer) is unchanged. Twin: `ContentView.swift` in `ios-chromic/`.

Everything else should be identical. If a diff shows anything beyond the list above, one side has
work the other is missing. The iOS twin of every decision here is `ios-chromic/SYNC.md`; when a
brand or flow change lands in one Chromic app, it belongs in the other.
