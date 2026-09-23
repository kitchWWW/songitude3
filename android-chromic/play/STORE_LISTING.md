# Chromic: A World of Stories — Google Play listing (DRAFT)

The Android twin of `ios-chromic/STORE_LISTING.md`. The copy is the same (Dorothy's text, with
quotes from the Shimmers in the Field press release), fitted to Play's fields. The one Android-only
line is about the playback notification. `listing.json` holds the text as it will be pushed.
`compose.py` makes every graphic.

| | |
|---|---|
| Package | `com.brianellissound.chromic` (the Kotlin package stays `com.brianellissound.songitude`) |
| Version | 1.0 (versionCode 1) |
| Play Console | not created yet: Play Console → **Create app** (see the steps at the bottom) |
| Push | `python3 ~/Documents/.credentials/google-play/play_publish.py android-chromic/play/listing.json` (dry run; add `--commit`) once the app exists |

---

## Store listing (Main store listing)

### App name — max 30

> Chromic: A World of Stories  *(27)*

### Short description — max 80

Play shows this under the name in search. Dorothy's first short description fits as written.

> Immersive stories, sounds, and music that bring the places around you to life.  *(78)*

### Full description — max 4,000

The App Store description with one Android line added (in HOW TO LISTEN). Like Apple, Play doesn't
want other platforms named, so "iOS" never appears. *(2,739 characters; full text in `listing.json`.)*

> A world of stories, waiting just beneath the surface. … [Dorothy's long description, verbatim] …
>
> HOW TO LISTEN
> Enable location services, put on headphones, and press play. **A small playback notification stays while a walk plays, with pause and skip at hand.** "The GPS-triggered audio does the rest—no fixed route, no need to look at the phone." …

There is no subtitle or promotional-text field on Play. "our lives, scored to motion" appears on
the feature graphic and the first screenshot instead.

### Graphics

| Asset | Play's rule | File |
|---|---|---|
| App icon | 512 × 512 PNG, ≤ 1 MB; Play applies its own round mask | `icon-512.png` |
| Feature graphic | 1024 × 500, JPEG or 24-bit PNG, no transparency; required | `feature-graphic.png` |
| Phone screenshots | 2–8, 16:9 or 9:16, sides 320–3840 px | `screenshots/01–06.png`, 1080 × 1920 |

The screenshots are real Android captures from the emulator (Android 16, System UI demo mode for
a clean 12:00 status bar). They're framed in the same style as the App Store set, with an Android
phone and a punch-hole camera. 02 + 03 are one panorama.
**05 (the map) is missing** until the Maps key is fixed (below). It is skipped, not faked.

### Categorization and contact details

| Field | Draft | Notes |
|---|---|---|
| App or game | App | |
| Category | Music & Audio | Travel & Local is the alternative |
| Tags (up to 5) | Music, Audio, Walking tours, Arts, Travel | pick from Play's list in the Console |
| Email (required, public) | brian.e2014@gmail.com | or a Chromic address? |
| Website | https://songitude.com/chromic/index.html | |
| Privacy policy (required) | https://songitude.com/chromic/privacy.html | already covers Android (notification, Google Maps) |

---

## App content (Policy → App content)

Play won't publish until every item here is answered.

- **Privacy policy:** the URL above.
- **Ads:** No, the app contains no ads.
- **App access:** "All functionality is available without special access". No login. Add reviewer
  instructions, because every walk only plays at its location:
  > Walks play only at their real-world locations. To hear Shimmers in the Field, set a mock
  > location of 38.9318, -77.0602 (Tregaron Conservancy, Washington, DC), open Soundwalks →
  > Shimmers in the Field → Start, and press play.
- **Content rating (IARC questionnaire):** category "All other app types". No violence, sex,
  language, drugs, gambling, or user-to-user interaction. Expected result: Everyone / PEGI 3.
- **Target audience:** 13 and over (the privacy policy says it isn't directed to children under 13).
  Don't tick the under-13 ranges; that pulls in the Families policy.
- **News app:** No. **COVID-19 app:** No. **Government app:** No. **Financial features:** None.
  **Health:** None.
- **Data safety:** draft answers:
  - *Location:* **not collected.** Play defines "collected" as sent off the device. Chromic reads
    location on the phone only, to choose what you hear.
  - *In-app report (Settings → Report):* **collected, optional, not shared**. When a listener
    chooses to send one, it carries the text they type, the walk it concerns, the app version, and
    the device model. Types: "App activity → Other user-generated content" and "App info and
    performance → Other app performance data". Purpose: App functionality / support. Not linked to
    identity. **Decision for you:** this is the conservative reading. Songitude's own form is the
    precedent to match.
  - Encrypted in transit: Yes (HTTPS). Deletion: nothing is stored about listeners; a request by
    email is honored.
- **Sensitive permissions** (Play asks when the first release is uploaded):
  - `ACCESS_BACKGROUND_LOCATION`: needs a declaration **and a short video**. Draft justification:
    > Chromic plays soundwalks, which are music and stories placed at real locations. A walk is heard
    > with the phone locked and in a pocket, so while a walk is playing the app keeps reading the
    > listener's location in the background to decide which sounds play as they move. Location is
    > used only while a walk is actively playing, inside a foreground service with a persistent
    > notification. It stops when the walk ends, and it never leaves the device.
  - Foreground service types `location` and `mediaPlayback`: same justification. The video can be
    the same one: first-run disclosure → system prompt → Start a walk → lock the phone → audio keeps
    playing with the notification showing. It must show **this** app, not Songitude.

---

## Before the first release

1. **Maps key (blocks the map today).** The Google Maps key rejects `com.brianellissound.chromic`,
   so the map is blank in Chromic on Android (confirmed on the emulator, 2026-09-22). In Cloud
   Console → APIs & Services → Credentials (`?authuser=1`), open the Android key used in
   `local.properties` and add three entries, all for package `com.brianellissound.chromic`:
   - debug `D2:C9:3E:F9:EA:57:BF:E6:3F:46:86:F8:86:59:85:F6:BB:05:14:1E`
   - upload `3D:45:B4:86:D4:8F:F5:10:C8:E4:42:79:B3:9D:AF:DD:CF:19:C0:A0`
   - the **Play app-signing** SHA-1. It only exists once the app is created and a build is
     uploaded (Play Console → Test and release → App integrity). Without it the map is blank for
     everyone who installs from Play.
2. Create the app in Play Console (account `/u/1/`, developer `6270347629935601857`): name
   "Chromic: A World of Stories", App, Free, and accept the declarations.
3. Grant the publishing service account access to the new app (Users and permissions → the
   service account → App permissions → add Chromic, with "Manage store presence"). Then run
   `play_publish.py` as above.
4. Build a signed release bundle (`./gradlew bundleRelease` with `JAVA_HOME` at JDK 21) and upload
   it to Internal testing first.
