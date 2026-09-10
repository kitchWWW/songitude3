# App Review notes — 1.0 resubmission

Draft for the **App Review Information → Notes** field. The live notes still read as the
pre-emptive Guideline 1.2 defense written for 1.0 (5); they say nothing about the three issues
Apple actually raised on 2026-08-25. Paste the updated text below once the two `TODO` items are
resolved.

## What Apple rejected (submission `c2fc32fe-1c95-4441-87d1-cec193abc67d`)

Reviewed on iPad Air 11-inch (M4), iPadOS 26.6, against 1.0 (5).

| Guideline | Issue | Where it stands |
|---|---|---|
| 5.1.1(iv) | "Enable" button before the location prompt | **Fixed** in `c2e30c4`; button now reads "Continue". First shipped in 1.0 (9). |
| 2.1(a) | "The widget button was unresponsive" | **Best candidate found and fixed in 1.0 (11).** No widget extension exists in the project, and no button fix landed between build 5 and build 10 — z-ordering was already correct in build 5. The likely culprit: `Settings → Report` (the screen the review notes send Apple to) showed "Report <walk>" and "Report <artist>" **greyed out** whenever no walk was loaded — which on an iPad, where every walk but one is geo-locked, is the normal state. Those rows are now hidden instead of disabled, and the map's transport controls are hidden when no walk is loaded. Still unconfirmed against Apple's actual repro. |
| 2.1 | Demo video required | Recorded (`docs/demo-videos/`). **Needs a public URL** — Apple wants a link, not an attachment. |

## Draft notes text

> CHANGES IN THIS BUILD — 1.0 (9)
>
> Guideline 5.1.1(iv). The pre-permission screen no longer uses the word "Enable". The button that
> advances to the system location prompt now reads "Continue", and the screen explains only what the
> app does with location. The alternative on that screen is "Not now", which dismisses without
> requesting anything.
>
> Guideline 2.1 — demo video:
> https://drive.google.com/drive/folders/1ENtu5j0dA9xBpT8iWo9p3Sy9xvea1ZBp?usp=sharing
> Recorded on a physical iPhone 15 running 1.0 (9). It shows first launch from a clean install,
> the location permission request, a walk downloading and playing, the map responding to movement,
> and audio continuing with the screen locked.
>
> Guideline 2.1(a) — TODO. Best current reading is that "the widget button" was the stacked-squares
> button (SF Symbol `square.stack.3d.up.fill`) that opens the walks list. NOT yet verified or fixed —
> do not claim a fix here until it is.

Everything below this line in the live notes (how the app works, the four Guideline 1.2 safeguards,
privacy) still reads correctly and should be kept as-is.

## Contact-info claim needs editing before submission

The live notes say the contact address "appears in the app (Settings → Report)". That row was
removed from the app's Report section on 2026-09-09, so the sentence is no longer true. The three
report forms still reach a person by email, and the address is still published on the support page
and in the privacy policy — so the safeguard itself stands. Reword that one clause rather than
claiming an in-app address that isn't there.

## What changed in 1.0 (11)

Cut after build 10 was already uploaded, so build 10 is superseded — do not submit it.

- **Report rows no longer greyed.** `Settings → Report` hid the walk/artist rows rather than
  disabling them; "Report an issue" is always offered, since a bug report about the app doesn't
  depend on a loaded walk. This is the best candidate for Guideline 2.1(a).
- **Transport controls hidden with no walk loaded.** The play and ±15s buttons used to render over
  a bare map with nothing to play.
- **Album art loads reliably.** The artwork fetch ignored the HTTP status (S3's XML error body was
  being fed to the image decoder) and never retried, so a transient failure left a row on its
  placeholder until it scrolled off and back. Now status-checked, with three attempts and backoff.
- **The in-app mailto row was removed** from the Report section — see the contact-info note below.
- **Site links are HTTPS** (`brianellissound.com`), in the app, the README and the marketing page.
