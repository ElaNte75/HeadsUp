"""
Draws the logo of HeadsUp: a golden sunburst around an orange badge with an exclamation mark ("heads up!")
on a dark rounded square.

Writes:
  HeadsUp/Media/icon.tga     128 x 128, for the game (add-on list, minimap button)
  release/logo.png           512 x 512, for the CurseForge project page

Needs:  pip install pillow        Run:  python tools/make_icon.py
"""
import math
import os
from PIL import Image, ImageDraw, ImageFilter

HERE = os.path.dirname(os.path.abspath(__file__))
SIZE = 1024   # drawn big, then made smaller (smooth edges)

NAVY_TOP = (14, 19, 34)
NAVY_BOTTOM = (28, 36, 58)
GOLD = (255, 196, 64)
ORANGE_TOP = (255, 176, 56)
ORANGE_BOTTOM = (232, 104, 20)
DARK = (22, 26, 40)


def gradient(size, top, bottom):
    """A vertical gradient (top colour to bottom colour)."""
    column = Image.new("RGB", (1, size))
    for y in range(size):
        t = y / (size - 1)
        column.putpixel((0, y), tuple(int(top[i] + (bottom[i] - top[i]) * t) for i in range(3)))
    return column.resize((size, size))


def rounded_mask(size, radius):
    mask = Image.new("L", (size, size), 0)
    ImageDraw.Draw(mask).rounded_rectangle((0, 0, size - 1, size - 1), radius=radius, fill=255)
    return mask


def main():
    c = SIZE // 2
    image = gradient(SIZE, NAVY_TOP, NAVY_BOTTOM).convert("RGBA")

    # soft orange glow behind everything
    glow = Image.new("RGBA", (SIZE, SIZE), (0, 0, 0, 0))
    ImageDraw.Draw(glow).ellipse((c - 400, c - 400, c + 400, c + 400), fill=(255, 150, 30, 150))
    image = Image.alpha_composite(image, glow.filter(ImageFilter.GaussianBlur(120)))

    # the sunburst: 16 golden rays
    rays = Image.new("RGBA", (SIZE, SIZE), (0, 0, 0, 0))
    draw = ImageDraw.Draw(rays)
    count = 16
    for n in range(count):
        angle = 2 * math.pi * n / count
        long = n % 2 == 0
        length = 470 if long else 390
        half = 0.085 if long else 0.06
        tip = (c + length * math.cos(angle), c + length * math.sin(angle))
        left = (c + 250 * math.cos(angle - half), c + 250 * math.sin(angle - half))
        right = (c + 250 * math.cos(angle + half), c + 250 * math.sin(angle + half))
        draw.polygon([left, tip, right], fill=GOLD + (235 if long else 190,))
    image = Image.alpha_composite(image, rays)

    # the badge: a disc with a darker rim
    disc = Image.new("RGBA", (SIZE, SIZE), (0, 0, 0, 0))
    ImageDraw.Draw(disc).ellipse((c - 285, c - 285, c + 285, c + 285), fill=(255, 226, 150, 255))
    image = Image.alpha_composite(image, disc)
    fill = gradient(SIZE, ORANGE_TOP, ORANGE_BOTTOM).convert("RGBA")
    inner = Image.new("L", (SIZE, SIZE), 0)
    ImageDraw.Draw(inner).ellipse((c - 262, c - 262, c + 262, c + 262), fill=255)
    image.paste(fill, (0, 0), inner)

    # the exclamation mark
    mark = Image.new("RGBA", (SIZE, SIZE), (0, 0, 0, 0))
    draw = ImageDraw.Draw(mark)
    draw.rounded_rectangle((c - 52, c - 190, c + 52, c + 60), radius=50, fill=DARK + (255,))
    draw.ellipse((c - 62, c + 100, c + 62, c + 224), fill=DARK + (255,))
    image = Image.alpha_composite(image, mark)

    # the dark rounded square, with a thin light border
    shape = rounded_mask(SIZE, 230)
    final = Image.new("RGBA", (SIZE, SIZE), (0, 0, 0, 0))
    final.paste(image, (0, 0), shape)
    border = Image.new("RGBA", (SIZE, SIZE), (0, 0, 0, 0))
    ImageDraw.Draw(border).rounded_rectangle((3, 3, SIZE - 4, SIZE - 4), radius=228, outline=(255, 190, 90, 120), width=7)
    final = Image.alpha_composite(final, border)

    media = os.path.join(HERE, "..", "HeadsUp", "Media")
    release = os.path.join(HERE, "..", "release")
    os.makedirs(media, exist_ok=True)
    os.makedirs(release, exist_ok=True)
    final.resize((512, 512), Image.LANCZOS).save(os.path.join(release, "logo.png"))
    final.resize((128, 128), Image.LANCZOS).save(os.path.join(media, "icon.tga"))   # 32 bit, no compression
    print("wrote", os.path.normpath(os.path.join(media, "icon.tga")), "and", os.path.normpath(os.path.join(release, "logo.png")))


if __name__ == "__main__":
    main()
