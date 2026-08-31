"""App Store frames: each screenshot's own map, blurred into a backdrop, behind a phone + caption."""
import os
from PIL import Image, ImageDraw, ImageFont, ImageFilter, ImageEnhance

SRC = os.path.join(os.path.dirname(os.path.abspath(__file__)), "raw")
OUT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "out")
W, H = 1320, 2868                      # required 6.9" portrait size

# Edit this table to change the set. `backdrop` is the screenshot blurred behind the phone — a
# colourful map reads far better than a mostly-white list, so pale screens borrow one. `punch`
# scales that backdrop's saturation if a frame looks washed out.
SHOTS = [
    dict(shot="IMG_2710.PNG", backdrop="IMG_2710.PNG", punch=1.8,
         head="Songitude",
         sub="music on the map"),
    dict(shot="IMG_2704.PNG", backdrop="IMG_2705.PNG", punch=2.4,
         head="Find a walk near you",
         sub="Sorted by distance\nplus walks you can play anywhere"),
    dict(shot="IMG_2705.PNG", backdrop="IMG_2705.PNG", punch=2.4,
         head="The map is the score",
         sub="Colored areas are sounds,\nwaiting where you stand"),
    dict(shot="IMG_2707.PNG", backdrop="IMG_2707.PNG", punch=1.9,
         head="Then just walk",
         sub="Screen off, phone in your pocket.\nThe music follows you"),
    dict(shot="IMG_2706.PNG", backdrop="IMG_2706.PNG", punch=2.6,
         head="Know before you go",
         sub="Every walk opens with a note from the composer"),
    dict(shot="IMG_2708.PNG", backdrop="IMG_2707.PNG", punch=1.9,
         head="Meet the artist",
         sub="Read about them, then hear the rest of their work"),
]

BOLD = "/System/Library/Fonts/Supplemental/Arial Bold.ttf"
REG = "/System/Library/Fonts/Supplemental/Arial.ttf"

def backdrop(src_name, punch=1.9):
    """Blow the walk's own map up, blur it to an abstract wash, then sink it under a dark gradient
    so white type stays legible over whatever colors the walk happens to use."""
    im = Image.open(os.path.join(SRC, src_name)).convert("RGB")
    scale = max(W / im.width, H / im.height) * 1.35      # overscan, then crop the middle
    im = im.resize((int(im.width * scale), int(im.height * scale)), Image.LANCZOS)
    left, top = (im.width - W) // 2, (im.height - H) // 2
    im = im.crop((left, top, left + W, top + H))
    im = im.filter(ImageFilter.GaussianBlur(78))
    im = ImageEnhance.Color(im).enhance(punch)             # push the color that survived the blur
    im = ImageEnhance.Brightness(im).enhance(0.62)

    # darker at the top where the caption sits, easing off over the phone
    shade = Image.new("L", (1, H))
    for y in range(H):
        t = y / (H - 1)
        shade.putpixel((0, y), int(255 * (0.66 - 0.34 * min(1.0, t / 0.55))))
    shade = shade.resize((W, H))
    return Image.composite(Image.new("RGB", (W, H), (6, 7, 10)), im, shade)

def device_frame(shot):
    """An iPhone-ish body: brushed titanium rail, black bezel, rounded screen, side buttons."""
    bezel, rail = 13, 11                       # black surround, then the metal edge
    pad = bezel + rail
    sw, sh = shot.size
    fw, fh = sw + pad * 2, sh + pad * 2
    r_out, r_screen = 116, 88

    frame = Image.new("RGBA", (fw, fh), (0, 0, 0, 0))

    # the rail is a diagonal metal gradient, clipped to the body outline
    metal = Image.new("RGB", (64, 64))
    px = metal.load()
    for yy in range(64):
        for xx in range(64):
            t = (xx / 63 * 0.45 + yy / 63 * 0.55)
            v = int(214 - 128 * t)             # bright top-left → dark bottom-right
            px[xx, yy] = (v, v + 3, v + 10)
    metal = metal.resize((fw, fh), Image.BICUBIC)
    body = Image.new("L", (fw, fh), 0)
    ImageDraw.Draw(body).rounded_rectangle([0, 0, fw - 1, fh - 1], radius=r_out, fill=255)
    frame.paste(metal, (0, 0), body)

    # buttons sit just proud of the rail, in the same metal
    d = ImageDraw.Draw(frame)
    def button(x0, y0, x1, y1):
        d.rounded_rectangle([x0, y0, x1, y1], radius=7, fill=(150, 154, 164, 255))
    button(-5, int(fh * 0.150), 5, int(fh * 0.150) + 62)      # action
    button(-5, int(fh * 0.238), 5, int(fh * 0.238) + 104)     # volume up
    button(-5, int(fh * 0.330), 5, int(fh * 0.330) + 104)     # volume down
    button(fw - 6, int(fh * 0.255), fw + 4, int(fh * 0.255) + 168)   # side button

    # black bezel, then the screenshot with rounded corners
    d.rounded_rectangle([rail, rail, fw - rail - 1, fh - rail - 1], radius=r_out - rail,
                        fill=(9, 9, 11, 255))
    mask = Image.new("L", (sw, sh), 0)
    ImageDraw.Draw(mask).rounded_rectangle([0, 0, sw - 1, sh - 1], radius=r_screen, fill=255)
    frame.paste(shot, (pad, pad), mask)
    return frame, fw, fh

def wrap(draw, text, font, max_w):
    """Hard newlines are respected; anything still too wide wraps on words."""
    out = []
    for para in text.split("\n"):
        out.extend(_wrap_one(draw, para, font, max_w))
    return out

def _wrap_one(draw, text, font, max_w):
    words, lines, cur = text.split(), [], ""
    for w in words:
        trial = (cur + " " + w).strip()
        if draw.textlength(trial, font=font) <= max_w:
            cur = trial
        else:
            lines.append(cur); cur = w
    if cur: lines.append(cur)
    return lines

def compose(src, headline, sub, bg_src, dest, punch=1.9):
    bg = backdrop(bg_src, punch)
    d = ImageDraw.Draw(bg)
    f_head, f_sub = ImageFont.truetype(BOLD, 94), ImageFont.truetype(REG, 58)

    y = 140
    for line in wrap(d, headline, f_head, W - 150):
        d.text((W // 2 + 3, y + 3), line, font=f_head, fill=(0, 0, 0, 90), anchor="ma")
        d.text((W // 2, y), line, font=f_head, fill=(255, 255, 255), anchor="ma")
        y += 108
    y += 14
    for line in wrap(d, sub, f_sub, W - 200):
        d.text((W // 2, y), line, font=f_sub, fill=(198, 204, 218), anchor="ma")
        y += 72

    shot = Image.open(os.path.join(SRC, src)).convert("RGB")
    inner_w = 950
    shot = shot.resize((inner_w, int(shot.height * inner_w / shot.width)), Image.LANCZOS)

    frame, fw, fh = device_frame(shot)
    fx, top = (W - fw) // 2, max(y + 90, 560)

    # soft drop shadow so the device lifts off the wash
    shadow = Image.new("RGBA", (W, H), (0, 0, 0, 0))
    ImageDraw.Draw(shadow).rounded_rectangle([fx + 12, top + 26, fx + fw + 12, top + fh + 26],
                                             radius=110, fill=(0, 0, 0, 155))
    bg = Image.alpha_composite(bg.convert("RGBA"), shadow.filter(ImageFilter.GaussianBlur(36)))
    bg.paste(frame, (fx, top), frame)

    bg.convert("RGB").save(dest, "PNG")

if __name__ == "__main__":
    os.makedirs(OUT, exist_ok=True)
    for i, s in enumerate(SHOTS, 1):
        compose(s["shot"], s["head"], s["sub"], s["backdrop"],
                os.path.join(OUT, f"{i:02d}.png"), s.get("punch", 1.9))
        print("wrote", f"{i:02d}.png")
