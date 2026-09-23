# Chromic App Store screenshots

`compose.py` turns the device screenshots in `raw/` into App Store frames in `out/`: each is on the
app's own watercolor wash, with its squiggles, stars and dots, and a phone that is upright, tilted
in 3D, or (02 + 03) spread across two frames as one panorama. The style follows the references
Lucy picked (Ellen Reid SOUNDWALK, Bloomberg Connects).

    python3 ios-chromic/store/compose.py

Output is 1320 × 2868, Apple's required 6.9" size. Edit `FRAMES` at the top to change captions,
order, which screenshot is used, a phone's pose (`tilt`, `yaw`, `at`, `w`), or the sprite scatter
(`seed`). Raw screenshots are straight off an iPhone 15 (1179 × 2556). Their status bars are
replaced with a clean 9:41 one. Artwork and fonts come from the app itself (`Assets.xcassets`,
`Fonts/`), so a brand change there flows through.
