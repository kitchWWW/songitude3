"""Google Play graphics for Chromic: the App Store treatment from ios-chromic/store/compose.py
(watercolor wash, squiggles, a posed phone, Julius Sans One captions), at Play's sizes and with
real Android screenshots.

    python3 android-chromic/play/compose.py
        → screenshots/01.png …   1080 × 1920 (Play caps screenshots at 2:1; a bare Android shot
                                  is 1080 × 2400, 2.22:1, so it goes inside a phone on a 9:16 canvas)
        → feature-graphic.png     1024 × 500, required, shown at the top of the listing
        → icon-512.png            512 × 512, the app icon

Screenshots in raw/ come from the emulator (AVD poly36) with System UI demo mode on, so
the status bar is already clean (12:00, full Wi-Fi and battery, no notifications). A frame whose
raw shot is missing is skipped, not faked.
"""
import os
import sys
from PIL import Image

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.join(HERE, "..", "..")
sys.path.insert(0, os.path.join(ROOT, "ios-chromic", "store"))
import compose as c   # noqa: E402

c.W, c.H = 1080, 1920
c.SCALE = 1080 / 1320
c.CAMERA = "punch"
c.CLEAN_STATUS = False
c.RAW = os.path.join(HERE, "raw")
c.OUT = os.path.join(HERE, "screenshots")

# Same story as the App Store set, re-laid for the shorter canvas. Positions are in 1080 × 1920
# pixels; `w` is the screen width in pixels; head sizes stay in 1320-wide units (c.u scales them).
FRAMES = [
    dict(name="01", width=1,
         head="CHROMIC", head_size=210, kicker="A WORLD OF STORIES",
         sub="our lives, scored to motion", text_at="top", text_y=150,
         phones=[dict(shot="03-about-chromic.png", w=640, at=(540, 1540), tilt=0, yaw=0)],
         seed=3, wash_shift=0.0),
    dict(name=("02", "03"), width=2,
         head="EVERY STORY\nLIVES IN A PLACE",
         sub="Stories, music, field recordings, and soundscapes that unfold as you move.",
         text_at="top", text_y=140, text_x=500, text_w=880, head_size=104,
         head2="A WORLD OF\nSOUNDWALKS",
         sub2="Gardens, woodlands, and city streets, each with a story waiting beneath the surface.",
         text2_at="top", text2_y=1490, text2_x=1740, text2_w=700, head2_size=104,
         phones=[dict(shot="04-soundwalks.png", w=470, at=(1060, 1060), tilt=-24, yaw=0.16)],
         seed=11, wash_shift=0.35),
    dict(name="04", width=1,
         head="STEP INTO\nA STORY",
         sub="Shimmers in the Field premieres October 17 at Tregaron Conservancy, Washington, D.C.",
         text_at="top", text_y=140,
         phones=[dict(shot="05-walk-shimmers.png", w=600, at=(540, 1420), tilt=0, yaw=0)],
         seed=5, wash_shift=0.6),
    dict(name="05", width=1,
         head="EXPLORE. LISTEN.\nNOTICE. DISCOVER.",
         sub="Put on your headphones and step outside. The music finds you as you walk.",
         text_at="top", text_y=140,
         phones=[dict(shot="06-map-shimmers.png", w=600, at=(590, 1440), tilt=12, yaw=-0.14)],
         seed=8, wash_shift=0.2),
    dict(name="06", width=1,
         head="CREATED\nBY CHROMIC",
         sub="Lucy Yao and Dorothy Chan blend toy piano, electronics, and storytelling into immersive worlds.",
         text_at="top", text_y=140, text_w=1030,
         phones=[dict(shot="03-about-chromic.png", w=600, at=(540, 1420), tilt=0, yaw=0)],
         seed=21, wash_shift=0.8),
]


def feature_graphic(dest):
    """1024 × 500: the name and tagline on the left, a phone tilting in from the right."""
    W, H = 1024, 500
    saved = c.W, c.H, c.SCALE
    c.W, c.H, c.SCALE = W, H, 0.55
    canvas = c.wash(W, H, 0.3)
    block = dict(head="CHROMIC", sub="our lives, scored to motion", cx=330, y=120, width=560,
                 anchor="top", head_size=190, kicker="A WORLD OF STORIES")
    clear = c.caption(Image.new("RGBA", (W, H)), **block)
    behind, _ = c.sprites(W, H, 7, [clear])
    canvas.alpha_composite(behind)
    c.caption(canvas, **block)
    c.place_phone(canvas, dict(shot="03-about-chromic.png", w=250, at=(800, 400), tilt=14, yaw=-0.12))
    canvas.convert("RGB").save(dest)
    c.W, c.H, c.SCALE = saved
    print("wrote", os.path.basename(dest))


def icon(dest):
    """Play wants 512 × 512; it applies its own mask, so this is the full square app icon."""
    src = os.path.join(ROOT, "ios-chromic", "Chromic", "Chromic", "Assets.xcassets",
                       "AppIcon.appiconset", "AppIcon.png")
    Image.open(src).convert("RGB").resize((512, 512), Image.LANCZOS).save(dest)
    print("wrote", os.path.basename(dest))


if __name__ == "__main__":
    os.makedirs(c.OUT, exist_ok=True)
    for f in os.listdir(c.OUT):
        if f.endswith(".png"):
            os.remove(os.path.join(c.OUT, f))      # the set is regenerated whole; no stale frames
    for fr in FRAMES:
        missing = [p["shot"] for p in fr["phones"] if not os.path.exists(os.path.join(c.RAW, p["shot"]))]
        if missing:
            print("skipped", fr["name"], "(no raw", ", ".join(missing) + ")")
            continue
        c.render(fr)
    feature_graphic(os.path.join(HERE, "feature-graphic.png"))
    icon(os.path.join(HERE, "icon-512.png"))
