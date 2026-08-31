# App Store assets

`compose.py` builds the App Store screenshots: each frame is a real device screenshot from
`raw/`, drawn inside a phone outline over a blurred, saturated wash of one of the walks' own maps,
with a headline and subline above it.

    python3 store/compose.py        # rewrites out/01.png … out/05.png

Output is 1320 × 2868 — the 6.9" size Apple requires (iPhone 17 / 16 Pro Max). Up to 10 are
allowed; the first two are what most people see without scrolling.

Edit the `SHOTS` table at the top of the script to change wording, reorder, swap which screenshot
sits behind which caption, or tune `punch` (backdrop saturation) if a frame looks washed out.
Replace anything in `raw/` to use newer screenshots — just keep them 1179 × 2556 portrait.
