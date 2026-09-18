# Chromic — Android player

A **fork** of `android/` (Songitude) branded for the artist Chromic, mirroring `ios-chromic/`
decision for decision. Same engine, same flows, same bundle format, same catalog — it lists only
Chromic's walks and wears Chromic's name, icon, type, backgrounds and hand-drawn icons.

It is a literal copy kept in step by hand: the **sixth playback surface**. `SYNC.md` has the recipe
and the list of deliberate differences. The Kotlin package stays `com.brianellissound.songitude`
(only `applicationId` changed) so diffs and patches against `android/` line up file for file.

## Build and run

Same as `android/`:

```bash
export JAVA_HOME=/opt/homebrew/opt/openjdk@21/libexec/openjdk.jdk/Contents/Home
./gradlew assembleDebug
adb install -r app/build/outputs/apk/debug/app-debug.apk
```

`local.properties` and `keystore.properties` were copied from `android/` (both git-ignored). The
upload key is Songitude's; Play allows one upload key across apps, but Chromic can be given its own
before its first release if that is preferred.

**The Maps key must be extended before the map draws anything.** It is restricted to package +
signing fingerprint, and the fork is a new package. In Cloud Console → APIs & Services →
Credentials (`?authuser=1`), add to the Android key's restrictions:

| Package | SHA-1 | For |
|---|---|---|
| `com.brianellissound.chromic` | `D2:C9:3E:F9:EA:57:BF:E6:3F:46:86:F8:86:59:85:F6:BB:05:14:1E` | debug builds |
| `com.brianellissound.chromic` | `3D:45:B4:86:D4:8F:F5:10:C8:E4:42:79:B3:9D:AF:DD:CF:19:C0:A0` | the upload key (and Play's app-signing key, once Play issues one) |

Until then the SDK logs `Authorization failure` and the map is a blank tile.

## What differs from `android/`

| | Songitude (`android/`) | Chromic (`android-chromic/`) |
|---|---|---|
| `applicationId` | `com.brianellissound.songitude` | `com.brianellissound.chromic` (package unchanged) |
| Name / icon | Songitude, the wave mark | Chromic, the toy-piano favicon as an adaptive icon |
| Catalog | every walk | `artistId == Brand.ARTIST_ID` |
| First run | splash animation → two permission pages → map | landing (CHROMIC, drifting squiggles, tap) → location page → notification page → **Chromic (About)** |
| Structure | map at the root, list as a cover | **About → Soundwalks → walk page** at the root, **map over it** on Start |
| Intro card | shown on open | off (`Brand.SHOWS_INTRO_CARD`); the walk page does its job |
| Type | Roboto | Julius Sans One titles (bundled, OFL), system body |
| Backgrounds | flat | still wash on the walk page / About; five swaying paint layers (`LivingBackdrop`) on the landing, permissions and list |
| Icons | Material | Dorothy's: back chevron (mirrored for ›), close, play/pause disc, ‹‹15/››15, cloud = settings, house = list |
| Reports | same Lambda | plus `"app": "Chromic (Android)"` |
| Credits | Brian Ellis | Chromic, then Brian Ellis / Songitude engine |
| Nav logging | — | logcat tag `ChromicNav`: every screen change and first-run step |

Everything brand-specific in code goes through `ui/Brand.kt`. Screens: `ui/screens/FirstRunScreen.kt`,
`AboutScreen.kt`, `SoundwalksScreen.kt`, `WalkDetailScreen.kt`; the root is `MainActivity.kt`
(`FirstRun` / `HomeRoot`). Songitude's `WalksBrowserScreen`, `OnboardingScreen`, `SplashOverlay`,
`ArtistPageScreen` and `SongitudeMark` still compile but are unreachable — keep them in step anyway.

Not yet: a Play Console entry, store listing, or screenshots. About's Instagram / website icons
wait on URLs (`Brand.INSTAGRAM_URL` / `WEBSITE_URL`).
