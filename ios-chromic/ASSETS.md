# Chromic brand assets

Source of truth: the shared Drive folder
<https://drive.google.com/drive/folders/1xtlTLK2NyEmJTjzsWgiIMYkVhq5zBgb3> (owner
chromic.duo@gmail.com; Dorothy uploads, Lucy approves). Design references: the
"Chromic app Figma Screens" and Miro board linked from "App Dev Running Notepad" in that folder.

Raw downloads live in `design-assets/03. App Dev/` (git-ignored — 137 MB; unpacked from the Drive
zip on 2026-09-17). Only the processed files that ship go into `Chromic/Assets.xcassets`.

Two things about the raw files: every icon, squiggle and background is exported on the same
**2048×2732 transparent canvas** (an iPad Pro page) with the art drawn small in the middle, so
icons must be trimmed to their alpha bounding box before use. And Drive's zip mangled the angle
brackets: `Icons/_15.png` is the counter-clockwise arrow (**‹‹15, back**), `Icons/_15(1).png` the
clockwise one (**››15, forward**).

## Inventory (as of 2026-09-17) and where each goes

| Drive path | Files | Use in app |
|---|---|---|
| `App Icon/Icon Small.png` | the toy piano over the watercolor sky, 1702×1696 (the wash is partly translucent) | **AppIcon** — done 2026-09-22: centre-cropped square, flattened onto white, 1024² no alpha. Also regenerates `AppLogo`, `IconTile` (first-run location ask), Android `icon_tile` and the adaptive launcher (foreground = tile at 62%, background = the same picture blurred), and `web/chromic/` icons |
| `App Icon/Icon Large.png` | same art, larger piano | not used |
| `App Icon/CD TP Flavicon.png` | the toy-piano favicon, 2261×2644 opaque | superseded by Icon Small |
| `App Icon/Logo 1.png … Logo10.png` | ten candidates | not used (awaiting Lucy; superseded by the favicon) |
| `Background/Combined Background`, `Layer 1–5` | full-bleed background + its layers | **done** — `Backdrop` behind Home and the walk page |
| `Background/TrBk - Combined Background`, `TrBk - Layer 1–5` | same, transparent | **done** — `TrBk - Layer 1–5` → `Wash1–5` imagesets (1032px PNG), swaying in `LivingBackdrop` over the still wash |
| `Welcome Screen Squiggles/TR - Squiggle1–3, Star1–3, Dot1–3, All Squiggles` | transparent decorations, 3 options each | **done** — trimmed to `Squiggle1–3` / `Star1–3` / `Dot1–3` imagesets (≤360px @3x), drifting in `SquiggleField` on the first-run scene |
| `Welcome Screen Squiggles/Squiggles with Background.jpg` | composite reference | reference only |
| `Icons/Play.png`, `Pause.png` | transport | **done** — `IconPlay` / `IconPause`; the drawn disc *is* the map's 84pt button (trimmed at alpha > 40: the files carry a faint halo) |
| `Icons/<<15.png`, `>>15.png` | skip | **done** — `IconBack15` / `IconForward15` in the map's skip buttons |
| `Icons/< Back.png`, `X Close.png` | navigation | **done** — `IconBack` (screen headers; mirrored for the small › after the artist's name and the map title) and `IconClose` (far-away card) |
| `Icons/Home.png`, `Favorite.png`, `About.png` | tab-style icons | `About` (cloud) **done** as `IconCloud`, the map's settings button; `Home` **done** as `IconHome`, the map's button back to the Soundwalks list. `Favorite` unused: no feature behind it |
| `About Page - Headshot.jpg` | photo | **done** — `ArtistPhoto` imageset (1290px JPEG), the About page's image |
| `App Dev - About Page Language` (Doc) | bio + events calendar | artist page copy (bio already matches the published profile; the events list is new) |

**Type.** The Figma's display face is **Julius Sans One** (titles: 40pt, −0.4 tracking; it is a
capitals-only face, so "soundwalks" sets as SOUNDWALKS). It is an OFL Google Font, bundled in
`Chromic/Fonts/` with its licence — nothing was needed from the artists. Body text is Roboto/Inter
in the mock, which the system font stands in for (`Brand.body`).

**Backdrop.** `Background/Combined Background.png` is the exact fill the Figma frames use
(pixel-matched against the file's image fill). Shipped as `Assets.xcassets/Backdrop.imageset`
at 1290×1721 JPEG (306 KB) rather than the 7.9 MB PNG. The frames show it at 1:1 so only a
375×812 corner is visible in the mock; the app scales the whole wash to the screen instead,
which is also how the App Loading frames use it.

## About page copy (from the Doc, 2026-09-02)

> **we are chromic duo** — Blending toy piano, electronics, and multimedia into installations,
> genre-fluid concerts, and immersive experiences, we have cultivated partnerships with colleges +
> cultural institutions internationally to share our passion for transforming spaces into places of
> beauty + belonging. […] the heart of what we do is constant: to cultivate intentional spaces for
> gathering to share stories that have been left out.

Events: Oct 17 2026 *Garden of Memories* launch, Tregaron Conservancy, Washington DC ·
Feb 25 2027 Yale Schwarzman Center, New Haven · Feb 26 2027 92Y, New York ·
Apr 18 2027 Phillips Collection Music Series, Washington DC.

Note the Doc still says "chromic duo"; the brand is now **Chromic**. The published artist profile
(`artists/80cda9dee7513416.json`, name "chromic duo") is theirs to update from the editor.
