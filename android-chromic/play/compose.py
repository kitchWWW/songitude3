"""Play Store frames: the App Store treatment from store/compose.py at Play's 9:16.

Play caps screenshots at 2:1, and a bare Android screenshot (1080 x 2340) is 2.17:1, so the raw
shots go inside the same phone-and-caption frame as the iOS set, on a 1080 x 1920 canvas. The
Samsung nav bar is cropped off the bottom; the status bar stays, as it does on iOS.

    python3 android/play/compose.py     # rewrites screenshots/01.png ... from raw/
"""
import os, sys
HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, "..", "..", "store"))
import compose as c

c.W, c.H = 1080, 1920
c.S = c.W / 1320
c.PHONE_W = 760                                            # narrower: the screen is taller and the canvas shorter
c.SRC = os.path.join(HERE, "raw")
c.OUT = os.path.join(HERE, "screenshots")
NAV = (0, 126)                                             # rows to drop: (status bar, nav bar)

SHOTS = [
    dict(shot="magic-square.jpg", backdrop="magic-square.jpg", punch=2.2, crop=NAV,
         head="Songitude",
         sub="music on the map"),
    dict(shot="walks.jpg", backdrop="zoid.jpg", punch=1.6, crop=NAV,
         head="Find a walk near you",
         sub="Sorted by distance\nfrom where you stand"),
    dict(shot="zoid.jpg", backdrop="zoid.jpg", punch=1.6, crop=NAV,
         head="Listen from anywhere",
         sub="Some walks arrange themselves\naround wherever you are"),
    dict(shot="artist.jpg", backdrop="magic-square.jpg", punch=2.2, crop=NAV,
         head="Meet the artist",
         sub="Read about them, then hear\nthe rest of their work"),
]

if __name__ == "__main__":
    os.makedirs(c.OUT, exist_ok=True)
    for i, s in enumerate(SHOTS, 1):
        c.compose(s["shot"], s["head"], s["sub"], s["backdrop"],
                  os.path.join(c.OUT, f"{i:02d}.png"), s["punch"], s["crop"])
        print("wrote", f"{i:02d}.png")
