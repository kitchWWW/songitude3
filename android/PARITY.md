# iOS ↔ Android parity audit

Every difference found by reading the two implementations side by side, sorted by whether it is a
bug, a deliberate platform difference, or an approximation. Status is updated as each is resolved.

## A. Parity breaks — Android behaving differently by mistake

| # | Difference | Status |
|---|---|---|
| A1 | **The intro card dimmed the map.** `WalkIntroCard.swift` is explicit: *"No dimming behind the card — the map stays at full brightness. This layer exists only to catch taps outside the card."* Android drew a 45% black scrim. | fixed |
| A2 | **The card could cover the play button.** iOS pads the card 150pt at the bottom specifically to leave the transport uncovered; Android centred it. | fixed |
| A3 | **`introColor: "artist"` was ignored.** iOS resolves it to the artist's page colour, loading the profile if needed, so a palette change reaches every walk of theirs. Android fell through to the default surface. | fixed |
| A4 | **`about` came from the wrong place.** iOS prefers the catalog's copy and falls back to `map.json`, so an edited description shows without republishing the bundle. Android read only `map.json`. | fixed |
| A5 | **Recenter appeared one viewing early.** iOS gates on `introShowings > 1`; Android used `>= 1`. | fixed |
| A6 | **Authored backdrops could be unreadable.** iOS flips the card's colour scheme to suit the backdrop, so a dark `introColor` gets light text. Android kept theme colours. | fixed |
| A7 | **Row status glyph was wrong.** iOS shows a green check for the walk that is loaded, a determinate ring while downloading, and play otherwise. Android always showed play, plus a trash button. | fixed |
| A8 | **Distance text and its threshold.** iOS: feet (to the nearest 10) under 0.1 mi, one decimal under 10 mi, whole miles beyond; green under **two miles**. Android: feet under 0.19 mi, whole miles beyond, green under 0.19 mi. | fixed |
| A9 | **"Plays anywhere" replaced the distance** on portable rows. iOS shows distance regardless — the section header already says it plays anywhere. | fixed |
| A10 | **A downloading row still accepted taps.** iOS ignores them. | fixed |
| A11 | **The artist page used a different, thinner row** than the browser. iOS shares `WalkRow` between both so they behave identically. | fixed |
| A12 | **Markdown was rendered as plain text.** iOS renders `about` and artist bios as real Markdown — headings, lists, quotes, links. Android stripped the markers, so the same walk read flatter on Android than on an iPhone. | fixed |

## B. Deliberate platform differences — keep

| Difference | Why |
|---|---|
| Foreground service with a persistent notification | Android will not keep audio and GPS alive in the background without one. It doubles as the lock-screen transport, standing in for `MPNowPlayingInfoCenter`. |
| Background location opens system Settings | Android 11+ refuses to grant it from a dialog. |
| Uninstall is a button with a confirm, not a swipe | A swipe with no visible affordance is an iOS idiom; the button is discoverable and the confirm replaces the swipe's own undo-by-not-completing. |
| Basemap is a Maps JSON style, not CARTO tiles | Google Maps restyles itself; MapKit cannot, which is why iOS ships raster tiles. |
| Engine lives on the `Application` | An Activity-scoped engine would be silenced by a rotation. |

## C. Approximations — acceptable, worth knowing

| Approximation | Detail |
|---|---|
| Fuzzy display style | MapKit feathers with a radial gradient; the Maps SDK has no gradient fill, so the edge is concentric bands. |
| Label markers | Drawn as Compose marker content rather than custom `MKAnnotationView`s; same fixed screen size at every zoom. |
| Launcher icon proportions | The mark is drawn 15% smaller than the iOS tile's. Android masks icons with much heavier corner rounding, and at iOS's proportions the waves crowded the corners. The splash tile matches, so the drawing that flies into onboarding is the one on the home screen. |

## Verified on device

Catalog, artist page, download, transposition onto the listener, map overlays, sounding highlight,
transport, foreground service and audio output were all exercised on an emulator and a Galaxy
SM-A166U1 running Android 16. The audio path was confirmed at the source: `AudioTrack state:started`
at 48 kHz stereo, under a foreground service of type `mediaPlayback|location`.
