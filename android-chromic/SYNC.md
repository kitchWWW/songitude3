# Keeping Chromic (Android) in step with Songitude (Android)

`android-chromic/` was copied from `android/` on 2026-09-18 (with the uncommitted decode/download
work of that date included) and then branded. The Kotlin package was deliberately **not** renamed,
so a patch against `android/` applies here with only the directory prefix rewritten:

```bash
# What has drifted, ignoring the deliberate brand differences.
diff -ru android/app/src/main/java android-chromic/app/src/main/java \
  -x Brand.kt -x FirstRunScreen.kt -x AboutScreen.kt -x SoundwalksScreen.kt -x WalkDetailScreen.kt -x ContentStore.kt -x seed

# Port a single commit's android/ changes, then resolve any rejects.
git format-patch -1 <sha> --stdout -- android/app/src/main \
  | sed -e 's#android/app/src/main/#android-chromic/app/src/main/#g' \
  | git apply -3 --reject
```

Expected, permanent differences — do not "fix" these when diffing:

- `app/build.gradle.kts`: `applicationId`, `versionCode`/`versionName` (reset to 1 / 1.0).
- `res/`: `strings.xml` (app name), `colors.xml`, `themes.xml` (launch), `drawable/launch_splash.xml`,
  `drawable/ic_notification.xml`, the adaptive icon (`mipmap-anydpi-v26`, `drawable-nodpi/ic_launcher_*`),
  everything in `drawable-nodpi/` and `font/`. Songitude's `ic_launcher_*.xml` / `splash_mark.xml`
  vectors are gone.
- `MainActivity.kt`: **rewritten** root — `FirstRun` (landing + the two permission pages, the
  permission plumbing itself verbatim from Songitude) and `HomeRoot` (About → Soundwalks → walk with
  the map as an overlay, system Back walking it). Songitude's `Route`/splash/auto-open-the-list
  logic is gone. Nav logging under `ChromicNav`.
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
- Chromic-only files: `ui/Brand.kt`, `ui/screens/FirstRunScreen.kt`, `AboutScreen.kt`,
  `SoundwalksScreen.kt`, `WalkDetailScreen.kt`.

Everything else should be identical. If a diff shows anything beyond the list above, one side has
work the other is missing. The iOS twin of every decision here is `ios-chromic/SYNC.md`; when a
brand or flow change lands in one Chromic app, it belongs in the other.
