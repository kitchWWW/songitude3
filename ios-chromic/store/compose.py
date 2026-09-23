"""Chromic App Store frames: real screenshots in a phone, on the app's own watercolor wash, with its
squiggles, stars and dots drifting over and around the device.

    python3 ios-chromic/store/compose.py      # rewrites out/01.png … out/NN.png

The look follows the references Lucy picked: a full-bleed brand background, big type, and phones
that are sometimes upright, sometimes tilted in 3D, and once spread across two frames so the pair
reads as one panorama when the listing is swiped. Output is 1320 × 2868, Apple's 6.9" size.

Edit FRAMES to change wording, order, which screenshot sits where, or how a phone is posed.
Screenshots in raw/ are straight off an iPhone 15 (1179 × 2556). Their status bars are replaced
with a clean 9:41 one, so the time, battery and Focus icon of the moment don't leak into the store.
"""
import math
import os
import random
from PIL import Image, ImageDraw, ImageFilter, ImageFont

HERE = os.path.dirname(os.path.abspath(__file__))
RAW, OUT = os.path.join(HERE, "raw"), os.path.join(HERE, "out")
ASSETS = os.path.join(HERE, "..", "Chromic", "Chromic", "Assets.xcassets")
FONTS = os.path.join(HERE, "..", "Chromic", "Chromic", "Fonts")
W, H = 1320, 2868

JULIUS = os.path.join(FONTS, "JuliusSansOne-Regular.ttf")
SF = "/System/Library/Fonts/SFNS.ttf"
INK = (29, 27, 32)            # Brand.Palette.title
SUBINK = (60, 55, 66)

# Knobs for reuse: android-chromic/play/compose.py imports this module, then sets a 1080 × 1920
# canvas, SCALE = 1080 / 1320 (every size below is written in 1320-wide units), a punch-hole
# camera, and no status-bar cleanup (Android's demo mode already gives a clean one).
SCALE = 1.0
CAMERA = "island"             # "island" (iPhone) | "punch" (Android)
CLEAN_STATUS = True


def u(v):
    """A size in 1320-wide units, at the current canvas scale."""
    return int(round(v * SCALE))

# Each frame (or pair of frames, for a panorama) is a caption block plus one or more phones.
#   shot:  file in raw/;   w: screen width in px;   at: phone centre (x, y) on the canvas
#   tilt:  in-plane rotation, degrees (+ = clockwise);   yaw: 0 for flat, up to ~0.25 for a phone
#          turned away (its right edge recedes; negative turns the left edge away)
#   head / sub: caption;   text_at: "top" | "bottom";   seed: sprite layout
FRAMES = [
    dict(name="01", width=1,
         head="CHROMIC", head_size=210, kicker="A WORLD OF STORIES",
         sub="our lives, scored to motion", text_at="top", text_y=250,
         phones=[dict(shot="03-about-chromic.png", w=900, at=(660, 2230), tilt=0, yaw=0)],
         seed=3, wash_shift=0.0),
    dict(name=("02", "03"), width=2,
         head="EVERY STORY\nLIVES IN A PLACE",
         sub="Stories, music, field recordings, and soundscapes that unfold as you move.",
         text_at="top", text_y=230, text_x=660, text_w=1060,
         head2="A WORLD OF\nSOUNDWALKS", sub2="Gardens, woodlands, and city streets, each with a story waiting beneath the surface.",
         text2_at="top", text2_y=2330, text2_x=2000, text2_w=1020,
         phones=[dict(shot="04-soundwalks.png", w=780, at=(1270, 1500), tilt=-24, yaw=0.16)],
         seed=11, wash_shift=0.35),
    dict(name="04", width=1,
         head="STEP INTO\nA STORY",
         sub="Shimmers in the Field premieres October 17 at Tregaron Conservancy, Washington, D.C.",
         text_at="top", text_y=230,
         phones=[dict(shot="05-walk-shimmers.png", w=860, at=(660, 1890), tilt=0, yaw=0)],
         seed=5, wash_shift=0.6),
    dict(name="05", width=1,
         head="EXPLORE. LISTEN.\nNOTICE. DISCOVER.",
         sub="Put on your headphones and step outside. The music finds you as you walk.",
         text_at="top", text_y=230,
         phones=[dict(shot="06-map-shimmers.png", w=860, at=(720, 1930), tilt=12, yaw=-0.14)],
         seed=8, wash_shift=0.2),
    dict(name="06", width=1,
         head="CREATED\nBY CHROMIC",
         sub="Lucy Yao and Dorothy Chan blend toy piano, electronics, and storytelling into immersive worlds.",
         text_at="top", text_y=230, text_w=1260,
         phones=[dict(shot="03-about-chromic.png", w=860, at=(660, 1890), tilt=0, yaw=0)],
         seed=21, wash_shift=0.8),
]


# ------------------------------------------------------------------ background ----------------
def _load(name):
    for folder in (f"{name}.imageset",):
        p = os.path.join(ASSETS, folder)
        for f in sorted(os.listdir(p)):
            if f.lower().endswith((".png", ".jpg")):
                return Image.open(os.path.join(p, f)).convert("RGBA")
    raise FileNotFoundError(name)


def _cover(im, w, h, shift=0.5):
    """Scale to cover w×h and crop; `shift` slides the crop along whichever axis has slack."""
    s = max(w / im.width, h / im.height)
    im = im.resize((math.ceil(im.width * s), math.ceil(im.height * s)), Image.LANCZOS)
    x = int((im.width - w) * shift) if im.width > w else 0
    y = int((im.height - h) * 0.5) if im.height > h else 0
    return im.crop((x, y, x + w, y + h))


def wash(w, h, shift):
    """The app's backdrop: the still wash with the five transparent paint layers over it, each
    nudged the way LivingBackdrop sways them, frozen at one moment."""
    zoom = 1.12
    base = _cover(_load("Backdrop"), int(w * zoom), int(h * zoom), shift)
    canvas = base.copy()
    for i, (dx, dy) in enumerate([(0.03, -0.02), (-0.04, 0.03), (0.02, 0.04), (-0.03, -0.03), (0.04, 0.01)], 1):
        layer = _cover(_load(f"Wash{i}"), int(w * zoom), int(h * zoom), shift)
        canvas.alpha_composite(layer, (int(dx * w), int(dy * h)))
    ox, oy = (canvas.width - w) // 2, (canvas.height - h) // 2
    return canvas.crop((ox, oy, ox + w, oy + h))


# ------------------------------------------------------------------ sprites -------------------
def sprites(w, h, seed, avoid):
    """Scatter the SquiggleField pieces: dots most, then stars, then squiggles. Returns
    (behind, in_front) layers; in_front is kept empty for now (see below). `avoid` is a list of
    boxes (caption blocks) to keep clear."""
    rnd = random.Random(seed)
    kinds = ["Squiggle1", "Squiggle2", "Squiggle3", "Star1", "Star2", "Star3", "Star1",
             "Dot1", "Dot2", "Dot3", "Dot1", "Dot2", "Dot3", "Dot2"] * max(1, w // 1320)
    behind = Image.new("RGBA", (w, h), (0, 0, 0, 0))
    front = Image.new("RGBA", (w, h), (0, 0, 0, 0))
    placed = []
    for i, k in enumerate(kinds):
        img = _load(k)
        scale = (rnd.uniform(1.5, 2.1) if k.startswith("Dot") else rnd.uniform(1.3, 1.9)) * SCALE
        img = img.resize((int(img.width * scale), int(img.height * scale)), Image.LANCZOS)
        img = img.rotate(rnd.uniform(-40, 40), resample=Image.BICUBIC, expand=True)
        for _ in range(60):
            x, y = rnd.randint(-60, w - img.width + 60), rnd.randint(-40, h - img.height + 40)
            box = (x, y, x + img.width, y + img.height)
            hit = any(box[0] < a[2] and box[2] > a[0] and box[1] < a[3] and box[3] > a[1] for a in avoid)
            near = any(abs((x + img.width / 2) - px) < u(230) and abs((y + img.height / 2) - py) < u(230) for px, py in placed)
            if not hit and not near:
                break
        placed.append((x + img.width / 2, y + img.height / 2))
        fade = rnd.uniform(0.82, 0.95)
        a = img.getchannel("A").point(lambda v: int(v * fade))
        img.putalpha(a)
        # All behind the phone: in front, even a dot lands on the app's own content.
        behind.alpha_composite(img, (x, y))
    return behind, front


# ------------------------------------------------------------------ status bar ----------------
def clean_status(shot):
    """Replace the captured status bar with a clean 9:41 one. Rows 124–150 sit under the old
    glyphs and above the app's own buttons on every screen, so they are pure background (wash or
    map). That strip is mirror-tiled up over the band, which keeps the texture and carries nothing
    across: mirroring taller slices dragged the map's buttons in, and filtering left the location
    badge behind."""
    top, bottom = 124, 150
    strip = shot.crop((0, top, shot.width, bottom))
    band = Image.new("RGB", (shot.width, bottom))
    y, flip = top, True
    while y > 0:
        piece = strip.transpose(Image.FLIP_TOP_BOTTOM) if flip else strip
        y -= strip.height
        band.paste(piece, (0, y))
        flip = not flip
    band.paste(strip, (0, top))
    shot.paste(band.crop((0, 0, shot.width, top)).filter(ImageFilter.GaussianBlur(3)), (0, 0))

    d = ImageDraw.Draw(shot)
    f = ImageFont.truetype(SF, 51)
    f.set_variation_by_name("Semibold")
    d.text((165, 72), "9:41", font=f, fill=(0, 0, 0), anchor="mm")
    # cellular bars
    x0, base = 862, 90
    for i, hgt in enumerate((14, 20, 27, 34)):
        d.rounded_rectangle([x0 + i * 13, base - hgt, x0 + i * 13 + 9, base], radius=3, fill=(0, 0, 0))
    # wi-fi: three arcs and a dot
    cx, cy = 968, 94
    for r in (38, 26, 14):
        d.arc([cx - r, cy - r, cx + r, cy + r], start=225, end=315, fill=(0, 0, 0), width=7)
    d.ellipse([cx - 5, cy - 7, cx + 5, cy + 3], fill=(0, 0, 0))
    # battery, full
    bx, by = 1010, 58
    d.rounded_rectangle([bx, by, bx + 72, by + 34], radius=10, outline=(0, 0, 0), width=4)
    d.rounded_rectangle([bx + 7, by + 7, bx + 65, by + 27], radius=5, fill=(0, 0, 0))
    d.rounded_rectangle([bx + 76, by + 11, bx + 81, by + 23], radius=2, fill=(0, 0, 0))
    return shot


# ------------------------------------------------------------------ device --------------------
def device(shot_name, screen_w):
    """An iPhone 15-style body around the screenshot: titanium rail, thin black bezel, rounded
    screen, Dynamic Island. Returns the flat face (RGBA) and its silhouette (L)."""
    shot = Image.open(os.path.join(RAW, shot_name)).convert("RGB")
    if CLEAN_STATUS:
        shot = clean_status(shot)
    shot = shot.resize((screen_w, round(shot.height * screen_w / shot.width)), Image.LANCZOS)
    k = screen_w / 950
    bezel, rail = int(16 * k), int(9 * k)
    pad = bezel + rail
    sw, sh = shot.size
    fw, fh = sw + pad * 2, sh + pad * 2
    r_out, r_scr = int(150 * k), int(128 * k)

    face = Image.new("RGBA", (fw, fh), (0, 0, 0, 0))
    metal = Image.linear_gradient("L").rotate(35, expand=False).resize((fw, fh))
    metal = Image.merge("RGB", [metal.point(lambda v: 110 + int(v * 0.45) + o) for o in (0, 3, 9)])
    body = Image.new("L", (fw, fh), 0)
    ImageDraw.Draw(body).rounded_rectangle([0, 0, fw - 1, fh - 1], radius=r_out, fill=255)
    face.paste(metal, (0, 0), body)
    d = ImageDraw.Draw(face)
    d.rounded_rectangle([rail, rail, fw - rail - 1, fh - rail - 1], radius=r_out - rail, fill=(8, 8, 10, 255))
    m = Image.new("L", (sw, sh), 0)
    ImageDraw.Draw(m).rounded_rectangle([0, 0, sw - 1, sh - 1], radius=r_scr, fill=255)
    face.paste(shot, (pad, pad), m)
    if CAMERA == "island":
        iw, ih = int(sw * 0.32), int(sw * 0.094)
        ix, iy = pad + (sw - iw) // 2, pad + int(sw * 0.028)
        d.rounded_rectangle([ix, iy, ix + iw, iy + ih], radius=ih // 2, fill=(0, 0, 0, 255))
    else:   # an Android punch-hole camera, centred in the status bar
        r = int(sw * 0.021)
        cx_, cy_ = pad + sw // 2, pad + int(sw * 0.030)
        d.ellipse([cx_ - r, cy_ - r, cx_ + r, cy_ + r], fill=(0, 0, 0, 255))
    return face, body


def _solve(a, b):
    """Gaussian elimination for the 8×8 perspective system (no numpy here)."""
    n = len(b)
    m = [row[:] + [b[i]] for i, row in enumerate(a)]
    for c in range(n):
        p = max(range(c, n), key=lambda r: abs(m[r][c]))
        m[c], m[p] = m[p], m[c]
        for r in range(n):
            if r != c:
                f = m[r][c] / m[c][c]
                m[r] = [x - f * y for x, y in zip(m[r], m[c])]
    return [m[i][n] / m[i][i] for i in range(n)]


def _coeffs(dst, src):
    """PIL PERSPECTIVE coefficients that map output quad `dst` back to input quad `src`."""
    a, b = [], []
    for (x, y), (u, v) in zip(dst, src):
        a.append([x, y, 1, 0, 0, 0, -u * x, -u * y]); b.append(u)
        a.append([0, 0, 0, x, y, 1, -v * x, -v * y]); b.append(v)
    return _solve(a, b)


def pose(img, tilt, yaw, pad=400):
    """Turn a flat face into a posed one: `yaw` shortens the receding edge (a cheap 3D turn),
    `tilt` rotates in the plane. Returns the warped image and the offset of its centre."""
    w, h = img.size
    hw, hh = w / 2, h / 2
    far = 1 - abs(yaw)
    pts = [(-hw, -hh), (hw, -hh), (hw, hh), (-hw, hh)]
    out = []
    for x, y in pts:
        side = x > 0 if yaw > 0 else x < 0
        sy = far if (yaw and side) else 1.0
        sx = (1 - abs(yaw) * 0.35) if yaw else 1.0
        out.append((x * sx, y * sy))
    t = math.radians(tilt)
    out = [(x * math.cos(t) - y * math.sin(t), x * math.sin(t) + y * math.cos(t)) for x, y in out]
    minx, miny = min(p[0] for p in out), min(p[1] for p in out)
    maxx, maxy = max(p[0] for p in out), max(p[1] for p in out)
    ow, oh = int(maxx - minx) + 2, int(maxy - miny) + 2
    dst = [(x - minx, y - miny) for x, y in out]
    src = [(0, 0), (w, 0), (w, h), (0, h)]
    warped = img.transform((ow, oh), Image.PERSPECTIVE, _coeffs(dst, src), Image.BICUBIC)
    return warped, (-minx, -miny)


def place_phone(canvas, spec):
    face, body = device(spec["shot"], spec["w"])
    tilt, yaw = spec.get("tilt", 0), spec.get("yaw", 0)
    posed, (cx, cy) = pose(face, tilt, yaw)
    x, y = int(spec["at"][0] - cx), int(spec["at"][1] - cy)

    # shadow under the device
    sil = Image.new("L", body.size, 0); sil.paste(body)
    sil_posed, _ = pose(Image.merge("RGBA", [sil, sil, sil, sil]), tilt, yaw)
    shadow = Image.new("RGBA", canvas.size, (0, 0, 0, 0))
    blk = Image.new("RGBA", sil_posed.size, (40, 20, 50, 120))
    shadow.paste(blk, (x + u(30), y + u(50)), sil_posed.getchannel("A"))
    canvas.alpha_composite(shadow.filter(ImageFilter.GaussianBlur(u(45))))

    # a tilted phone shows its edge: stack the silhouette a few px towards the receding side
    if yaw or tilt:
        depth = u(22)
        dirx = 1 if yaw >= 0 else -1
        for i in range(depth, 0, -2):
            shade = int(60 + 30 * i / depth)
            edge = Image.new("RGBA", sil_posed.size, (shade, shade + 2, shade + 8, 255))
            canvas.paste(edge, (x + dirx * i, y + i // 2), sil_posed.getchannel("A"))
    canvas.alpha_composite(posed, (max(x, 0), max(y, 0)), (max(-x, 0), max(-y, 0)))


# ------------------------------------------------------------------ type ----------------------
def _wrap(d, text, font, max_w):
    lines = []
    for para in text.split("\n"):
        cur = ""
        for word in para.split():
            trial = (cur + " " + word).strip()
            if d.textlength(trial, font=font) <= max_w:
                cur = trial
            else:
                lines.append(cur); cur = word
        if cur:
            lines.append(cur)
    return lines


def caption(canvas, head, sub, cx, y, width, anchor="top", head_size=118, kicker=None):
    """Headline in Julius Sans One (capitals, as the app sets titles), then a body-font line.
    Returns the block's bounding box so sprites can keep clear of it."""
    d = ImageDraw.Draw(canvas)
    head_size = u(head_size)
    fh = ImageFont.truetype(JULIUS, head_size)
    fk = ImageFont.truetype(JULIUS, u(64))
    fs = ImageFont.truetype(SF, u(54)); fs.set_variation_by_name("Regular")
    hl = _wrap(d, head, fh, width)
    sl = _wrap(d, sub, fs, width - u(60)) if sub else []
    lh, sh_ = int(head_size * 1.12), u(66)
    total = len(hl) * lh + (u(90) if kicker else 0) + (u(30) + len(sl) * sh_ if sl else 0)
    top = y if anchor == "top" else y - total
    yy = top
    for line in hl:
        d.text((cx, yy), line, font=fh, fill=INK, anchor="ma"); yy += lh
    if kicker:
        d.text((cx, yy + u(6)), kicker, font=fk, fill=INK, anchor="ma"); yy += u(90)
    if sl:
        yy += u(30)
        for line in sl:
            d.text((cx, yy), line, font=fs, fill=SUBINK, anchor="ma"); yy += sh_
    return (cx - width // 2 - u(40), top - u(40), cx + width // 2 + u(40), yy + u(40))


# ------------------------------------------------------------------ frames --------------------
def render(fr):
    """Background, then sprites behind, captions, phones, and the few dots that cross in front.
    Captions are laid out once first only to learn where the sprites must stay clear."""
    cw = W * fr["width"]
    blocks = [dict(head=fr["head"], sub=fr.get("sub"), cx=fr.get("text_x", W // 2), y=fr["text_y"],
                   width=fr.get("text_w", W - 180), anchor=fr.get("text_at", "top"),
                   head_size=fr.get("head_size", 118), kicker=fr.get("kicker"))]
    if fr.get("head2"):
        blocks.append(dict(head=fr["head2"], sub=fr.get("sub2"), cx=fr.get("text2_x", W + W // 2),
                           y=fr["text2_y"], width=fr.get("text2_w", W - 180),
                           anchor=fr.get("text2_at", "top"), head_size=fr.get("head2_size", 118), kicker=None))
    scratch = Image.new("RGBA", (cw, H))
    clear = [caption(scratch, **b) for b in blocks]

    canvas = wash(cw, H, fr.get("wash_shift", 0.5))
    behind, front = sprites(cw, H, fr["seed"], clear)
    canvas.alpha_composite(behind)
    for b in blocks:
        caption(canvas, **b)
    for p in fr["phones"]:
        place_phone(canvas, p)
    canvas.alpha_composite(front)

    names = fr["name"] if isinstance(fr["name"], tuple) else (fr["name"],)
    for i, n in enumerate(names):
        canvas.crop((i * W, 0, (i + 1) * W, H)).convert("RGB").save(os.path.join(OUT, f"{n}.png"))
        print("wrote", f"{n}.png")


if __name__ == "__main__":
    os.makedirs(OUT, exist_ok=True)
    for fr in FRAMES:
        render(fr)
