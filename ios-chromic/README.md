# Chromic — iOS player

A **fork** of `ios/` (Songitude) branded for the artist Chromic (formerly "chromic duo"). Same engine,
same flows, same bundle format, same catalog — it lists only Chromic's walks and wears Chromic's
name, icon, type and backgrounds.

It is a literal copy, not a second target: the two trees are kept in step by hand. That makes this
the **fifth playback surface** — a change to a mode, a fade, the dialogue queue or the intro/exit
sequence is not finished until it is here too. `SYNC.md` has the recipe.

## What differs from `ios/`

| | Songitude (`ios/`) | Chromic (`ios-chromic/`) |
|---|---|---|
| Project / target | `Songitude` | `Chromic` |
| Bundle id | `com.brianellissound.songitude` | `com.brianellissound.chromic` |
| Display name | Songitude | Chromic |
| Catalog | every walk in `walks/manifest.json` | walks whose `artistId == Brand.artistID` (`80cda9dee7513416`) |
| Universal links | `applinks:songitude.com` | none — this app is not in songitude.com's AASA |
| Reports | same Lambda | same Lambda, plus `"app": "Chromic"` so the email says which app it came from |
| Credits | Brian Ellis | Chromic, then Brian Ellis (engine) |
| Build number | tracks TestFlight | reset to 1 |

Everything brand-specific in code goes through `Chromic/Brand.swift`. Keep it that way: a
`diff -ru` against `ios/` should show engine and flow work, not renamed strings.

### Flow

One navigation stack at the root, with the map presented **over** it — the opposite way up from
Songitude, where the map is the root and the list a cover:

    Chromic (About)  →  Soundwalks  →  a walk's page  →  (Start) the map, as a cover

Onboarding lands on the "Chromic" page (photo, "Soundwalks" button, bio, link icons). The list is
one step in; a card opens the walk's page (title, artwork, **Start**, "by chromic duo ›",
description); Start loads the walk and presents the map with no intro card. The map's title button
dismisses back to the walk's page and its layers button to the list — the walk keeps playing. The
artist's name anywhere pops to the root. `HomeRoot` (in `SplashRootView.swift`) owns the path and
the cover; a QR deep link that makes a walk current presents the map too. Songitude's intro card
is compiled but switched off (`Brand.showsIntroCard`).

### Instant content

Chromic publish rarely, so the app ships a snapshot of the catalog (filtered), the artist profile
and the artwork in `Chromic/Seed/`. `ContentStore` reads **disk cache → seed**, so the first frame of
every catalog screen is complete with no network; fetches still happen in the background and
overwrite the disk copies for next time, silently. `tools/refresh_seed.py` takes the snapshot for
*both* apps and runs as the "Refresh Seed" build phase on every build (offline it warns and keeps
the last seed). Audio is not seeded — 223 MB — and still downloads on Start.

Backgrounds: `LivingBackdrop` (the five paint layers swaying) behind the landing, the permission
step and the list; the still `Backdrop` behind the walk page and About, where there is reading to do.
Navigation is logged under the `nav` category (Console: subsystem `com.brianellissound.chromic`).

First launch: a landing screen (CHROMIC over the wash, squiggles drifting; tap anywhere) then the
location ask (title, app icon, Continue / Not now). No splash animation; a returning launch opens
on the map.

Done from the Figma: the app icon (toy-piano favicon), the watercolor backdrops, Julius Sans One
titles, the first-run scene, About, the list and the walk page. Still Songitude's, pending the rest of the
brand pass (see `ASSETS.md`): the tab bar, the accent colour on the map screen, the transport
icons. About's Instagram / website icons wait on URLs (`Brand.instagramURL` / `websiteURL`). There is no tagline yet — the landing shows "Tap to begin" where the mock's
"tag line?" sits.

## Build & run

Same as `ios/` — see `ios/README.md` and `CLAUDE.md`. From `ios-chromic/Chromic/`:

```bash
xcodebuild -project Chromic.xcodeproj -scheme Chromic -configuration Debug \
  -destination 'id=B2D9B778-9F37-5F8E-B577-DC1198121CF0' \
  -derivedDataPath <scratch>/dd -allowProvisioningUpdates build
xcrun devicectl device install app --device B2D9B778-9F37-5F8E-B577-DC1198121CF0 \
  <scratch>/dd/Build/Products/Debug-iphoneos/Chromic.app
```

`CFBundleVersion` is hardcoded in `Chromic/Info.plist` (as in Songitude) — bump it there *and*
`CURRENT_PROJECT_VERSION` in the pbxproj before a TestFlight upload. App Store Connect record:
"Chromic: A World of Stories", app id `6815062440`; 1.0 (2) uploaded 2026-09-22. Marketing and privacy pages: `web/chromic/` → songitude.com/chromic/index.html, /chromic/privacy.html. Listing copy
drafts live in `STORE_LISTING.md`.
