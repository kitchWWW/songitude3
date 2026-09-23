# Chromic: A World of Stories — App Store listing (DRAFT)

> **Shared copy for the team (Google Doc, edits come back here):**
> https://docs.google.com/document/d/1wfcaX1a59tjDz2ZPKUv7Ms6faApJh3rumy-RqEW6oMk/edit
> Once the team has edited it, the Doc is the source of truth. Copy their changes back into this file and into App Store Connect.

Everything below is **draft copy**. It uses Dorothy's short and long descriptions as written,
and adds direct quotes from the Shimmers in the Field press release (Washington Performing Arts /
Tregaron Conservancy, Sept 22, 2026). Quoted press-release text appears in "double quotes". Please
edit the text under each heading, leave the headings and limits as they are, and send it back.
Brian will paste the final version into App Store Connect.

This exact text is already in App Store Connect, so the record isn't empty. **Nothing has been
submitted to Apple** and nothing goes public until someone presses "Submit for Review".

| | |
|---|---|
| App Store Connect record | "Chromic: A World of Stories", app id `6815062440` |
| Bundle id / SKU | `com.brianellissound.chromic` / `chromic` |
| Version | 1.0 (build 2 uploaded to TestFlight, with the new "Icon Small" app icon) |
| Price | Free (placeholder, please confirm) |

Character limits are Apple's. The count in brackets is the current draft's length.

---

## App name — max 30

> Chromic: A World of Stories  *(27)*

Already set. The name on the home screen under the icon stays **Chromic**.

## Subtitle — max 30

Shown under the name in search results. Chosen by Brian, 2026-09-22 (lowercase is intended).

> our lives, scored to motion  *(27)*

## Promotional text — max 170

The line at the top of the page. It can be changed at any time without a new app review, so after
October 17 swap the premiere sentence for Dorothy's second short description:
"Explore places through immersive stories, music, and sound that unfold as you move." (83)

> Immersive stories, sounds, and music that bring the places around you to life. Premiering October 17: Shimmers in the Field at Tregaron Conservancy.  *(148)*

## Description — max 4,000

Dorothy's long description, verbatim, followed by press-release material. The App Store can't show
bold or links, so section titles are in capitals.

> A world of stories, waiting just beneath the surface.
>
> What if you could hear a place differently?
>
> Chromic creates immersive audio experiences that invite you to slow down, wander, and discover the stories held within the world around you.
>
> Put on your headphones, step outside, and explore. As you move through a landscape, stories, music, field recordings, and soundscapes will unfold around you, revealing hidden layers and new ways to experience familiar places.
>
> Every experience is rooted in a particular place. Some may lead you through a story. Others may invite you to listen closely, drawing your attention to something you might otherwise pass by. There is no wrong way to listen. Let the sounds around you become part of the experience.
>
> Created by Chromic, the app brings together music, storytelling, technology and place, to create immersive worlds that blur the boundaries between listening and exploring.
>
> Explore. Listen. Notice. Discover.
> Step into a story. See where it takes you.
>
> A new world may be closer than you think.
>
> SHIMMERS IN THE FIELD
> Premieres Saturday, October 17, 2026 at Tregaron Conservancy, Washington, D.C. Co-commissioned by Washington Performing Arts and Tregaron Conservancy.
>
> "Blending original music, narration, storytelling, and sound design, Shimmers in the Field transforms a visit to Tregaron into a guided act of listening." The walk follows no fixed route: "visitors chart their own paths, linger where they choose, and encounter the work differently on every visit and in every season."
>
> "Walking is an act of breathing. And when you walk, you start to notice the cycles of breath and moments of decay — the renewal that defines these moments." — Lucy Yao, Chromic
>
> HOW TO LISTEN
> Enable location services, put on headphones, and press play. "The GPS-triggered audio does the rest—no fixed route, no need to look at the phone." Experience a walk "in 10 minutes or an hour, from any starting point, and return across the seasons to discover new layers."
>
> MORE WALKS
> Listen to Chinatown (Manhattan), Emerald Futures (Manhattan) and how fragile, we bloom (Wave Hill, the Bronx).
>
> ABOUT CHROMIC
> Chromic, artists Lucy Yao and Dorothy Chan, "blends classical music, toy piano, and electronics into genre-fluid performances, immersive installations, and AR (Augmented Reality) soundwalks. Drawing from their experiences as immigrants and the Asian-American diaspora, they create concerts and experiences that invite listeners to slow down and wonder."
>
> YOUR LOCATION STAYS YOURS
> Your location is used on your phone, only while a walk is playing, to decide what you hear. It is never uploaded, stored or shared.

*(2,654 characters.)* Apple rejects listings that mention other platforms, so the press
release's "both iOS and Android" line is left out on purpose.

## Keywords — max 100, comma-separated, no spaces after commas

Words already in the name or subtitle ("Chromic", "World", "Stories", "lives", "motion") don't need repeating.

> soundwalk,Tregaron,Shimmers in the Field,audio walk,toy piano,immersive,sound art,GPS,Washington DC  *(99)*

## URLs


| Field | Required? | Draft | Notes |
|---|---|---|---|
| Support URL | yes | `https://songitude.com/support/index.html` | Placeholder. Could be a Chromic contact page instead. |
| Marketing URL | no | `https://songitude.com/chromic/index.html` | Live draft page: the walks, how it works, bio, upcoming events. Please review the copy there too. |
| Privacy Policy URL | yes | `https://songitude.com/chromic/privacy.html` | Live. Written for this app: no accounts, location stays on the device, what a report sends. |

## Copyright

> 2026 Chromic  *(placeholder: who is the legal owner? Lucy Yao and Dorothy Chan?)*

## Categories

- Primary: **Music**
- Secondary: **Travel**

(Same as Songitude. Entertainment is another option for the secondary.)

## What's New (1.0)

Not shown for a first release.

---

## Still needed before submission

- [ ] **Screenshots**: 6.9" iPhone at 1320 × 2868, up to 10. None exist for Chromic yet. `store/compose.py`
      can frame device screenshots of the Chromic app the same way as Songitude's.
- [ ] **Age rating** questionnaire (Songitude's answers carry over: no objectionable content → 4+).
- [ ] **App Privacy** ("nutrition label"): *Data Not Collected*, same as Songitude. Location is used on
      the device and never leaves it.
- [ ] **Availability / pricing**: set territories explicitly. Songitude showed "removed from sale"
      after approval because its record had no availability at all.
- [ ] **App Review notes**: see below.
- [ ] **Instagram and website links** for the About page: the press release gives
      instagram.com/chromic_duo and chromic.space. They still need wiring into `Brand.swift` (and the
      Android twin), then a new build.
- [ ] **Release timing**: the press release says the app "arrives in October" and the walk premieres
      Oct 17. Allow a few days for App Review before that date.

### App Review risk: every walk is tied to a location

All four Chromic walks are geo-locked (DC, Manhattan ×2, the Bronx), including Shimmers in the Field. Apple's reviewer tests from
Cupertino on an iPad, so they won't hear a note of audio. Songitude got through because its catalog
includes a walk that plays wherever you are. Chromic has nothing like that. Options, roughly from
best to worst:

1. Publish a short **portable** Chromic walk (e.g. a sampler) that arranges itself around the listener.
2. Record a **demo video** on site and link it in the review notes. Apple accepted this for Songitude.
3. Explain it in the notes alone, which risks a Guideline 2.1 rejection.

### Draft review notes

> Chromic: A World of Stories plays soundwalks: music placed at real locations, heard through
> headphones as the listener walks. Every walk in this app is site-specific (Washington DC and New
> York City), so audio only plays within the walk's area. The launch walk, Shimmers in the Field,
> was co-commissioned by Washington Performing Arts and Tregaron Conservancy and premieres at
> Tregaron Conservancy, 3100 Macomb St NW, Washington DC, on October 17, 2026. A demo video recorded on location is here:
> [LINK TODO]. No account or sign-in is required. Location is used only while a walk is playing and
> never leaves the device.
