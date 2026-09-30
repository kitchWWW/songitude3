# Chromic: A World of Stories — App Store listing

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
| Price | Free (confirmed by Brian, 2026-09-28) |

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

Dorothy (Doc comment, 2026-09-23): keep the project-specific line until about **Nov 1**, then switch
to the app-general wording above.

> Immersive stories, sounds, and music that bring the places around you to life. Premiering October 17: Shimmers in the Field at Tregaron Conservancy.  *(148)*

## Description — max 4,000

Dorothy's long description, verbatim, then How to Listen, About Chromic and the location note. Dorothy
struck (2026-09-28, in the Doc) the Shimmers in the Field section, Lucy's quote, More Walks, and the
press-release quoting in How to Listen. The App Store can't show bold or links, so section titles are
in capitals.

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
> HOW TO LISTEN
> Enable location services, put on headphones, and press play. The GPS-triggered audio does the rest—no fixed route, no need to look at the phone.
>
> ABOUT CHROMIC
> Chromic, artists Lucy Yao and Dorothy Chan, "blends classical music, toy piano, and electronics into genre-fluid performances, immersive installations, and AR (Augmented Reality) soundwalks. Drawing from their experiences as immigrants and the Asian-American diaspora, they create concerts and experiences that invite listeners to slow down and wonder."
>
> YOUR LOCATION STAYS YOURS
> Your location is used on your phone, only while a walk is playing, to decide what you hear. It is never uploaded, stored or shared.

*(1,732 characters.)* Apple rejects listings that mention other platforms, so the press
release's "both iOS and Android" line is left out on purpose.

## Keywords — max 100, comma-separated, no spaces after commas

Words already in the name or subtitle ("Chromic", "World", "Stories", "lives", "motion") don't need repeating.

> soundwalk,Tregaron,Shimmers in the Field,audio walk,toy piano,immersive,sound art,GPS,Washington DC  *(99)*

## URLs


| Field | Required? | Draft | Notes |
|---|---|---|---|
| Support URL | yes | `https://songitude.com/chromic/support.html` | Live draft page |
| Marketing URL | no | `https://songitude.com/chromic/index.html` | Live draft page: the walks, how it works, bio, upcoming events. Please review the copy there too. |
| Privacy Policy URL | yes | `https://songitude.com/chromic/privacy.html` | Live. Written for this app: no accounts, location stays on the device, what a report sends. |

## Copyright

> 2026 Lucy Yao and Dorothy Chan

## Categories

- Primary: **Music**
- Secondary: **Travel**

(Same as Songitude. Entertainment is another option for the secondary.)

## What's New (1.0)

Not shown for a first release.

---

## Still needed before submission

- [x] **Screenshots**: 6.9" iPhone at 1320 × 2868, up to 10. The six frames in `store/out/` are uploaded (2026-09-28). `store/compose.py`
      can frame device screenshots of the Chromic app the same way as Songitude's.
- [x] **Age rating** (set 2026-09-28: 4+, no user-generated content since the app lists only Chromic's walks) questionnaire (Songitude's answers carry over: no objectionable content → 4+).
- [ ] **App Privacy** ("nutrition label"): *Data Not Collected*, same as Songitude. Location is used on
      the device and never leaves it.
- [x] **Availability / pricing** (2026-09-28: free, all 175 territories): set territories explicitly. Songitude showed "removed from sale"
      after approval because its record had no availability at all.
- [x] **App Review notes**: contact + notes are in ASC. The demo is a screen recording (2 min) uploaded as an App Review
      attachment on 2026-09-30, and the notes say it is attached.
- [x] **Instagram and website links** for the About page: instagram.com/chromic_duo and chromic.space
      are wired into `Brand.swift` and its Android twin (2026-09-30). Ship them in build 4.
- [x] **Submitted 2026-09-30** (build 4, releases on approval). **Release timing**: the press release says the app "arrives in October" and the walk premieres
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
> Tregaron Conservancy, 3100 Macomb St NW, Washington DC, on October 17, 2026. Because the audio only plays on
> site, a screen recording of the app playing a walk while walking is attached to this submission. No account or sign-in is required. Location is used only while a walk is playing and
> never leaves the device.
