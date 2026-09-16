#!/usr/bin/env python3
"""Generate the test fixtures: a wallpaper, a seamless ground tile, and text files.

Everything is drawn procedurally so the repo carries no binary assets and the
images are identical on every run.
"""
import math
import os
import sys

from PIL import Image, ImageDraw, ImageFont

HERE = os.path.dirname(os.path.abspath(__file__))


def font(size):
    for path in ("/usr/share/fonts/TTF/DejaVuSans-Bold.ttf",
                 "/usr/share/fonts/dejavu/DejaVuSans-Bold.ttf",
                 "/usr/share/fonts/noto/NotoSans-Bold.ttf"):
        if os.path.exists(path):
            return ImageFont.truetype(path, size)
    return ImageFont.load_default()


# One distinct wallpaper per space, so a frame says at a glance which space
# it is. Hue and label differ; the layout is the same.
SPACES = [
    ("1", (0.60, 0.50, 0.85)),   # blue
    ("2", (0.85, 0.45, 0.30)),   # orange
    ("3", (0.35, 0.70, 0.45)),   # green
    ("4", (0.75, 0.40, 0.75)),   # violet
]


def wallpaper(path, tint=(0.60, 0.50, 0.85), label="1", w=1920, h=1080):
    """A non-repeating image with a horizon, a sun, and labelled quadrants,
    so any crop of it says where on the screen it came from."""
    img = Image.new("RGB", (w, h))
    px = img.load()
    tr, tg, tb = tint
    for y in range(h):
        t = y / h
        for x in range(w):
            u = x / w
            base = 0.45 + 0.35 * (1 - t) + 0.10 * math.sin(u * 6.28)
            px[x, y] = (int(255 * min(1, base * tr + 0.10 * t)),
                        int(255 * min(1, base * tg + 0.05 * u)),
                        int(255 * min(1, base * tb)))
    d = ImageDraw.Draw(img)
    d.ellipse((w * 0.68 - 120, h * 0.28 - 120, w * 0.68 + 120, h * 0.28 + 120), fill=(255, 214, 120))
    for i in range(6):
        yy = h * 0.62 + i * 55
        d.line((0, yy, w, yy + 30), fill=(20, 40, 60), width=3)
    f = font(48)
    for q, (x, y) in {"NW": (60, 40), "NE": (w - 200, 40), "SW": (60, h - 100), "SE": (w - 200, h - 100)}.items():
        d.text((x, y), q, fill=(255, 255, 255), font=f)
    d.text((w / 2 - 260, h / 2 - 30), "kwin-canvas fixture", fill=(255, 255, 255), font=f)
    big = font(220)
    d.text((w / 2 - 70, h * 0.66), label, fill=(255, 255, 255), font=big)
    img.save(path)


def tile(path, n=256):
    """A seamless ground tile: soft checker with a dot at the centre."""
    img = Image.new("RGB", (n, n), (28, 31, 38))
    d = ImageDraw.Draw(img)
    d.rectangle((0, 0, n // 2 - 1, n // 2 - 1), fill=(33, 37, 45))
    d.rectangle((n // 2, n // 2, n - 1, n - 1), fill=(33, 37, 45))
    d.ellipse((n // 2 - 4, n // 2 - 4, n // 2 + 4, n // 2 + 4), fill=(127, 143, 176))
    d.line((0, 0, n - 1, 0), fill=(60, 66, 80))
    d.line((0, 0, 0, n - 1), fill=(60, 66, 80))
    img.save(path)


def texts():
    with open(os.path.join(HERE, "sample.txt"), "w") as fh:
        fh.write("kwin-canvas fixture text\n")
        fh.write("=" * 40 + "\n\n")
        for i in range(1, 41):
            fh.write(f"line {i:02d}  the quick brown fox jumps over the lazy dog\n")
    with open(os.path.join(HERE, "konsole.txt"), "w") as fh:
        fh.write("kwin-canvas fixture konsole\n")
        for i in range(1, 25):
            fh.write(f"{i:02d}  " + "#" * (i * 2) + "\n")


if __name__ == "__main__":
    out = sys.argv[1] if len(sys.argv) > 1 else HERE
    os.makedirs(out, exist_ok=True)
    for label, tint in SPACES:
        wallpaper(os.path.join(out, f"wallpaper-{label}.png"), tint, label)
    wallpaper(os.path.join(out, "wallpaper.png"), *SPACES[0][1:], SPACES[0][0])
    tile(os.path.join(out, "tile.png"))
    texts()
    print("fixtures written to", out)
