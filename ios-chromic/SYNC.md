# Keeping Chromic in step with Songitude

`ios-chromic/` was copied from `ios/` on 2026-09-17 (Songitude at commit `c0154e6`, build 11) and
then branded. Nothing merges automatically. When engine or flow work lands in `ios/`, bring it here:

```bash
# What has drifted, ignoring the deliberate brand differences.
diff -ru ios/Songitude/Songitude ios-chromic/Chromic/Chromic \
  -x Assets.xcassets -x Info.plist -x '*.entitlements' -x Brand.swift \
  -x SongitudeApp.swift -x ChromicApp.swift -x WalkDetailView.swift -x FirstRunView.swift -x AboutView.swift -x ContentStore.swift -x Fonts -x Seed

# Port a single commit's ios/ changes (paths rewritten to the fork), then resolve any rejects.
git format-patch -1 <sha> --stdout -- ios/Songitude/Songitude \
  | sed -e 's#ios/Songitude/Songitude/#ios-chromic/Chromic/Chromic/#g' \
  | git apply -3 --reject
```

Expected, permanent differences — do not "fix" these when diffing:

- `RemoteCatalog.swift`: the `artistId` filter in `refresh`.
- `AudioEngine.swift`, `OnboardingView.swift`: `"Songitude"` → `Brand.name`.
- `AppState.swift`: `maybeShowIntroCard` / `presentIntroCard` are gated on `Brand.showsIntroCard`
  (false). The walk's page replaces the card.
- `ContentView.swift`: `Brand.name` fallback title; the title and layers buttons dismiss the map
  (`onShowWalk` / `onBrowse`) instead of presenting the list or the card.
- `WalksBrowserView.swift`: **rewritten** — now the whole About → Soundwalks → walk stack, with
  the path bound to `SplashRootView`'s state (it opens on Soundwalks, About beneath). Only `ArtistRoute` survives from Songitude's. Port
  *behaviour* changes from Songitude's list by hand. Soundwalks' way back to About is the map's
  settings cloud on the same 44pt material chip (`ScreenHeader(back: .about)`, asset in
  `Brand.AboutButton`), labelled "About", so the two read as a pair. When Dorothy's gear lands,
  change only the settings button's asset in `ContentView`; the About button keeps the cloud.
  Twin: `android-chromic/SYNC.md`.
- `SplashRootView.swift`: **rewritten** — the welcome/home switch, the navigation state (`path`,
  `showMap`) and the background timer, plus `HomeRoot` — the stack at the root with the map as a
  `fullScreenCover`, the inverse of Songitude. `ContentView` no longer presents the browser; it
  takes `onShowWalk` / `onBrowse` and its auto-open-the-list `onAppear` logic is gone. See
  "Launch and return" below.
- `WalkDetailView.swift`, `AboutView.swift`: Chromic-only (the walk page and About). The former
  also holds `RemoteWalk: Hashable`. `ArtistPageView.swift` still compiles but is unreachable.
- `FirstRunView.swift`: Chromic-only — the welcome (CHROMIC over drifting squiggles, tap to begin)
  and the permission step, as one scene, ending in `onDone`. No splash animation, no `splash.seen`
  key. `OnboardingView.swift` is **rewritten** as the permission step's icon + bottom block. Its
  5.1.1(iv) logic (`requested` / `advance` / `onChange(authorization)`) is Songitude's verbatim
  except that it calls `onDone()` where Songitude calls `app.completeOnboarding()` (`FirstRunView`
  does both) — port changes to that logic by hand.
- `SquiggleField` (the landing's drifting squiggles) lives in `Brand.swift` beside
  `LivingBackdrop`, not in `FirstRunView.swift`, because the Soundwalks list draws it too:
  wash → squiggles → `ScrollView`, all ZStack siblings, so the field (like the wash) stays put
  while the cards scroll, never takes a touch, and freezes under Reduce Motion. Welcome masks it;
  the list uses it unmasked. Twin: `android-chromic/.../ui/SquiggleField.kt`.
- `WalkRow.swift`: `ArtworkCache` thumbnails are 1200px, not 256 — the artwork is drawn 360pt wide
  here — and `load` shows the `ContentStore` copy first, revalidating once per session. `WalkRow`
  itself is now used only by `ArtistPageView`.
- `RemoteCatalog.swift`: also `init` from the cached manifest, `ContentStore.store` on fetch, and
  `ArtistStore.load` cache-then-seed. `ContentStore.swift` and `Seed/` are Chromic-only; the
  "Refresh Seed" build phase too.
- **Prefetch on the walk's page** (`WalkDetailView.onAppear` → `AppState.prefetch`). `AppState`'s
  `openRemote` no longer calls `WalkDownloader.download` itself: every download goes through
  `startFetch`, one per walk id, and Start *claims* the one the page began (the map's halo resumes
  at its progress). An unclaimed prefetch is cancelled by opening another walk's page, and by
  delete / Reset Cache / Reset App; backing out lets it finish. `WalkDownloader.download` takes a
  `Cancellation`, un-marks `.complete`/`.version` before rewriting map.json, and writes every file
  `.atomic`. Those downloader changes (and the dedupe) would port cleanly to Songitude; the
  prefetch trigger has no home there, since its list starts the download on tap already.
- `WalkDetailView.swift`: the button always reads "Start" (was "Open map" for the loaded walk; it
  still just returns to the map rather than reloading).
- `ReportView.swift`: footer wording, the `"app"` field, the `NSError` domain.
- `SettingsView.swift`: the credits rows.
- `ChromicApp.swift` vs `SongitudeApp.swift`: struct name and the AASA comment.
- `Info.plist`: `UIAppFonts` (`Fonts/JuliusSansOne-Regular.ttf`); `Fonts/` and the `Backdrop`
  imageset exist only here.
- **"Chromic Duo" shows as "Chromic".** Older published walks (and the artist profile) carry the
  old name and can't be re-published, so `Brand.displayCreator(_:)` maps a creator of
  "Chromic Duo" (trimmed, any case) to `Brand.name` for display; other names pass through. Every
  reader goes through it: `RemoteWalk.creatorText`, `ArtistProfile.displayName`
  (`RemoteCatalog.swift`) and a new `SoundMap.creatorText` (`Models.swift`), which
  `SettingsView`, `ReportView` and `WalkIntroCard` read instead of `map.creator`;
  `ArtistPageView` uses `profile.displayName`. Stored/fetched JSON and the `artistId` filter are
  untouched. Twin: `Brand.displayCreator` in `android-chromic/.../ui/Brand.kt`.

- **"Play Outro" reads "Say Goodbye".** Chromic's wording for the end-session button on the map; the
  behavior (exit sequence, 30 s offer) is unchanged. Twin: `MapScreen.kt` in `android-chromic/`.

Everything else should be identical. If a diff shows anything beyond the list above, one side has
work the other is missing. `WalkIntroCard.swift` and `SongitudeMark.swift` are still compiled but never shown; keep
them in step anyway.

## Launch and return

The flow, decision for decision with `android-chromic/SYNC.md`:

- **Cold start** (a new process, including after a swipe-away): always the welcome, then the
  location page **only if** location isn't authorized (when-in-use or always), then **Soundwalks**.
  `hasOnboarded` is still recorded — it gates deep links and "Reset app" clears it — but it no
  longer decides whether the welcome shows.
- **Soundwalks is the landing hub.** The stack is About with Soundwalks pushed on it
  (`HomeRoot.landing = [.walks]`), so the cloud is an ordinary pop to About, About's "Soundwalks"
  button pushes the list again, and the artist's name anywhere clears the path to About. Walks go
  deeper as before (walk page → Start → map).
- **Back from the background** (`scenePhase` `.background` → `.active`): within
  `Brand.resumeWindow` (5 min) nothing moves. Longer, and the app starts over at the welcome and
  lands on Soundwalks — **unless a walk is under way**: the engine is running, or the map is on
  screen (playing or paused). That is sampled when leaving *and* on return, so a walk that was
  playing when the phone was pocketed is never reset. `.inactive` alone (notification shade,
  Control Center) is not an absence.
- The map opens whenever `current` changes (Start, or a deep link — including one that arrives during
  the welcome), watched at the root; a long-absence restart leaves a loaded-but-idle walk loaded
  without bouncing its map back up.

About is no longer where a later open lands.

## The website's backdrop

`web/chromic/backdrop.js` redraws `LivingBackdrop` and `SquiggleField` (both Brand.swift)
for songitude.com/chromic/*: the same layer periods, phases, zoom, travel and pace, and the same
sprite mix, speeds, spin and sway. It is not playback, so it is not one of the six engines, but if
the app's backdrop numbers or artwork change, change the script to match. Its images in
`web/chromic/bg/` are the app's `Wash1–5` (as 720px WebP) and the @3x sprites.
