# Songitude — iOS player

SwiftUI app that plays an authored sound walk against the phone's real GPS. Audio keeps
rendering in the background (locked, in-pocket) and stops only when the app is fully quit.

## Build & run

```bash
open Songitude/Songitude.xcodeproj
```

1. Select the **Songitude** target → **Signing & Capabilities** → pick your Team.
   (Bundle id `com.brianellissound.songitude` — change if that id is taken.)
2. Build to a **real device**. GPS, background audio and the lock-screen require hardware; the
   Simulator can only fake a static location.
3. Run.

The project already includes a working demo bundle (`Experiences/sample-wave-hill.zip`) with
three areas — a looping pad, a one-shot chime, and a dialogue narration — so it runs out of the box.

## Adding / updating experiences

Drop exported `.zip` bundles from the web editor into `Songitude/Experiences/`. A
build phase (`import_experiences.sh`) unpacks each into `<App>.app/Bundled/<name>/` at build
time; the app lists them all. To point at "the latest version," replace the zip and rebuild.
The app holds several at once — pick between them in **Settings → Debug → Map**.

## What's wired up

| Requirement | Where |
|---|---|
| GPS permission + onboarding | `OnboardingView`, `LocationManager`, big "Enable location permissions" button |
| Denied-permission alert | `OnboardingView` / `ContentView` alerts |
| Layered loop / one-shot / dialogue playback with fades | `AudioEngine.swift` (AVAudioEngine) — same state machine as the editor preview |
| Big play/pause = engine on/off | `ContentView.playButton` → `RenderEngine.toggle()` |
| Background audio (locked / pocketed) | `UIBackgroundModes: audio + location`, `AVAudioSession .playback`, `allowsBackgroundLocationUpdates` |
| Stops on full quit | OS tears down the audio session when the process is killed |
| Map overlay matching the editor | `MapOverlayView` (MapKit, colored `MKCircle`/`MKPolygon`, sounding highlight) |
| Gear settings: map selection, re-request permission, credits, re-center over me | `SettingsView` (map selection + re-center hidden under **Debug**) |
| Lock-screen "live" now-playing + album art + map name as title | `RenderEngine.updateNowPlaying*` (`MPNowPlayingInfoPropertyIsLiveStream = true`) |

## Notes

- For the best in-pocket behavior, accept **Always** location (Settings → Debug → "Upgrade to
  Always"). "While Using" still works while the app is foregrounded or recently backgrounded.
- The "Import Experiences" build phase runs on every build (it's cheap) so newly dropped zips
  are always picked up.
- Audio files are decoded fully into memory on load; keep individual clips reasonable in length.
