# Songitude — Android player

A full port of the iOS app: the same bundle format, the same playback semantics, the same walks
from the same catalog. Kotlin + Jetpack Compose, no Android Studio required.

## Build and run

```bash
export JAVA_HOME=/opt/homebrew/opt/openjdk@21/libexec/openjdk.jdk/Contents/Home
./gradlew assembleDebug
adb install -r app/build/outputs/apk/debug/app-debug.apk
```

`JAVA_HOME` has to be set: this machine's default `java` is JDK 26, which the Android Gradle Plugin
rejects (it supports up to 21). `gradle.properties` pins the daemon to JDK 21, but the `gradlew`
launcher script needs a JVM before it can read that.

`local.properties` (git-ignored) carries two machine-local values:

```
sdk.dir=/Users/…/Library/Android/sdk
MAPS_API_KEY=…
```

The Maps key is injected into the manifest as a placeholder, so it never enters the repo. Restrict
it in Google Cloud Console to package `com.brianellissound.songitude` plus your signing SHA-1.

| | |
|---|---|
| AGP | 8.9.2 |
| Gradle | 8.11.1 (wrapper) |
| Kotlin | 2.0.21 |
| compileSdk / targetSdk | 36 |
| minSdk | 26 |

## Why the audio engine is written this way

`AudioEngine.swift` gives every sounding area its own `AVAudioPlayerNode` and launches synced clips
against a common `AVAudioTime` host time. Android offers no equivalent guarantee across independent
players, and `syncedLoop` is *defined* by sample alignment — the format says synced clips "launch
sample-aligned at one shared start time and run forever".

So `RenderEngine.kt` runs **one `AudioTrack` and mixes every voice itself**. With a single clock,
"the same frame" is the same instant by construction, with no drift to correct. Everything else
follows from that:

- Clips are decoded once to the engine's rate and channel count (`AudioDecoder`), so a 44.1 kHz file
  and a 48 kHz file agree on what a frame is.
- Ramps advance per frame inside the mix loop, so a fade lasts exactly as long as it was asked to,
  independent of block size.
- A voice can start mid-block, so synced loops are genuinely aligned rather than rounded to a block
  boundary.
- `skip` derives a synced voice's new position from the shared launch frame, not its own playhead —
  the same trick the iOS engine uses with host time.

## What Android does differently, and why

| Concern | iOS | Android |
|---|---|---|
| Background audio | Audio session + `UIBackgroundModes: audio`. Nothing shown to the user. | **Foreground service with a persistent notification.** Required, and since Android 14 it must declare both `mediaPlayback` and `location`. |
| Lock-screen transport | `MPNowPlayingInfoCenter` + `MPRemoteCommandCenter` | `MediaSessionCompat` + the notification's actions |
| Interruptions | `AVAudioSession.interruptionNotification` | `AudioManager` focus loss / gain |
| Headphones removed | Route change, `.oldDeviceUnavailable` | `ACTION_AUDIO_BECOMING_NOISY` |
| Basemap | CARTO raster tiles, because MapKit can't restyle | Google Maps JSON style (`res/raw/map_style_*.json`) |
| Background location | Part of the "Always" grant | A **separate** permission request, only offerable after the foreground grant |
| Engine lifetime | The app object | The `Application`, so a rotation can't silence a walk |

The pre-permission screen says **"Continue"**, never "Enable" — App Review rejected the older iOS
wording under Guideline 5.1.1(iv), and the reasoning holds here too.

## Parity notes

Two things are deliberate and worth knowing:

- **Labels don't travel with a transportable walk.** `SoundMap.transposed` moves the centre, the
  shapes and the routes, but not the labels — matching `GeoUtils.swift` exactly. This looks like an
  iOS bug (a caption left behind where the walk was authored points at nothing), but parity wins
  until the iOS side changes. Fix both together.
- **The "fuzzy" display style is approximated.** MapKit feathers a shape with a radial gradient; the
  Maps SDK has no gradient fill, so the edge is built from concentric bands. Visually the same soft
  edge, a few more overlays.

## Layout

```
model/      Models.kt        bundle format, every field optional with its historical default
            GeoUtils.kt      containment, distance, transposition
audio/      PcmBuffer.kt     decoded clip + crossfade baking
            AudioDecoder.kt  MediaCodec → float PCM at the engine's rate
            RenderEngine.kt  the mixer and the whole location-driven state machine
location/   LocationManager.kt   fused provider + compass, running only while playing
data/       RemoteCatalog.kt manifest, artist profiles, downloader, bundled assets
service/    PlaybackService.kt   foreground service, MediaSession, notification transport
ui/         MapScreen, MapOverlay, MapLabels, Cards, Theme
ui/screens/ WalksBrowser, Settings, ReportSheet, ArtistPage, Onboarding, Splash
AppState.kt the coordinator, ported from AppState.swift
```

## Changing playback behaviour

The editor preview, the web player, `AudioEngine.swift` and `RenderEngine.kt` implement the same
state machine. **Change one → change all four**, and update `shared/FORMAT.md`.
