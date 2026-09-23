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
  the path bound to `HomeRoot`'s state. Only `ArtistRoute` survives from Songitude's. Port
  *behaviour* changes from Songitude's list by hand.
- `SplashRootView.swift`: also holds `HomeRoot` — the stack at the root with the map as a
  `fullScreenCover`, the inverse of Songitude. `ContentView` no longer presents the browser; it
  takes `onShowWalk` / `onBrowse` and its auto-open-the-list `onAppear` logic is gone.
- `WalkDetailView.swift`, `AboutView.swift`: Chromic-only (the walk page and About). The former
  also holds `RemoteWalk: Hashable`. `ArtistPageView.swift` still compiles but is unreachable.
- `FirstRunView.swift`: Chromic-only — the landing (CHROMIC over drifting squiggles, tap to begin)
  and the permission step, as one scene. `SplashRootView.swift` is reduced to the
  onboarded/first-run switch (no splash animation, no `splash.seen` key), and
  `OnboardingView.swift` is **rewritten** as the permission step's icon + bottom block. Its
  5.1.1(iv) logic (`requested` / `advance` / `onChange(authorization)`) is Songitude's verbatim —
  port changes to that logic by hand.
- `WalkRow.swift`: `ArtworkCache` thumbnails are 1200px, not 256 — the artwork is drawn 360pt wide
  here — and `load` shows the `ContentStore` copy first, revalidating once per session. `WalkRow`
  itself is now used only by `ArtistPageView`.
- `RemoteCatalog.swift`: also `init` from the cached manifest, `ContentStore.store` on fetch, and
  `ArtistStore.load` cache-then-seed. `ContentStore.swift` and `Seed/` are Chromic-only; the
  "Refresh Seed" build phase too.
- `ReportView.swift`: footer wording, the `"app"` field, the `NSError` domain.
- `SettingsView.swift`: the credits rows.
- `ChromicApp.swift` vs `SongitudeApp.swift`: struct name and the AASA comment.
- `Info.plist`: `UIAppFonts` (`Fonts/JuliusSansOne-Regular.ttf`); `Fonts/` and the `Backdrop`
  imageset exist only here.

Everything else should be identical. If a diff shows anything beyond the list above, one side has
work the other is missing. `WalkIntroCard.swift` and `SongitudeMark.swift` are still compiled but never shown; keep
them in step anyway.

## The website's backdrop

`web/chromic/backdrop.js` redraws `LivingBackdrop` (Brand.swift) and `SquiggleField` (FirstRunView.swift)
for songitude.com/chromic/*: the same layer periods, phases, zoom, travel and pace, and the same
sprite mix, speeds, spin and sway. It is not playback, so it is not one of the six engines, but if
the app's backdrop numbers or artwork change, change the script to match. Its images in
`web/chromic/bg/` are the app's `Wash1–5` (as 720px WebP) and the @3x sprites.
