"""
Draws the little pictures of the themed "Empowered effects" (frost, blood, poison...) of HeadsUp.
Every picture is white (or grey) on a transparent background: the add-on gives it its colour.

Writes HeadsUpAuras/Media/fx/*.tga (the sizes are powers of two, as the game needs).

Needs:  pip install pillow        Run:  python tools/make_fx.py
New picture files need a full restart of the game (a /reload is not enough).
"""
import math
import os
import random
from PIL import Image, ImageDraw, ImageFilter

HERE = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.join(HERE, "..", "HeadsUpAuras", "Media", "fx")
K = 4   # drawn 4 times bigger, then made smaller (smooth edges)


def canvas(w, h):
    return Image.new("RGBA", (w * K, h * K), (0, 0, 0, 0))


def finish(img, w, h, name, blur=0.0):
    if blur:
        img = img.filter(ImageFilter.GaussianBlur(blur * K))
    img = img.resize((w, h), Image.LANCZOS)
    os.makedirs(OUT, exist_ok=True)
    img.save(os.path.join(OUT, name + ".tga"))
    print("wrote", name + ".tga", w, "x", h)


def glow():
    """a soft round light"""
    w = h = 128
    img = Image.new("RGBA", (w, h))
    px = img.load()
    for y in range(h):
        for x in range(w):
            d = math.hypot(x - w / 2 + 0.5, y - h / 2 + 0.5) / (w / 2)
            a = max(0.0, 1.0 - d)
            px[x, y] = (255, 255, 255, int(255 * a * a))
    os.makedirs(OUT, exist_ok=True)
    img.save(os.path.join(OUT, "glow.tga"))
    print("wrote glow.tga")


def shard():
    """an icicle: wide at the top, a sharp point down, bright on one side"""
    w, h = 32, 128
    img = canvas(w, h)
    d = ImageDraw.Draw(img)
    W, H = w * K, h * K
    body = [(W * 0.08, 0), (W * 0.92, 0), (W * 0.58, H * 0.72), (W * 0.5, H), (W * 0.42, H * 0.7)]
    d.polygon(body, fill=(215, 235, 255, 235))
    # the lit side
    d.polygon([(W * 0.08, 0), (W * 0.42, 0), (W * 0.46, H * 0.9), (W * 0.42, H * 0.7)], fill=(255, 255, 255, 255))
    # a dark side, for depth
    d.polygon([(W * 0.7, 0), (W * 0.92, 0), (W * 0.58, H * 0.72), (W * 0.52, H * 0.95)], fill=(150, 195, 235, 235))
    finish(img, w, h, "shard", 0.4)


def flake():
    """a six-armed frost star"""
    w = h = 64
    img = canvas(w, h)
    d = ImageDraw.Draw(img)
    c = w * K / 2
    for n in range(6):
        a = math.radians(60 * n)
        tip = (c + math.cos(a) * c * 0.92, c + math.sin(a) * c * 0.92)
        d.line([(c, c), tip], fill=(255, 255, 255, 255), width=int(2.4 * K))
        for f in (0.45, 0.7):
            base = (c + math.cos(a) * c * 0.92 * f, c + math.sin(a) * c * 0.92 * f)
            for side in (-1, 1):
                b = a + side * math.radians(48)
                end = (base[0] + math.cos(b) * c * 0.28, base[1] + math.sin(b) * c * 0.28)
                d.line([base, end], fill=(255, 255, 255, 255), width=int(1.6 * K))
    d.ellipse((c - 3 * K, c - 3 * K, c + 3 * K, c + 3 * K), fill=(255, 255, 255, 255))
    finish(img, w, h, "flake", 0.3)


def splat():
    """a splash: a blob with spikes and drops flying off it"""
    random.seed(11)
    w = h = 128
    img = canvas(w, h)
    d = ImageDraw.Draw(img)
    c = w * K / 2
    d.ellipse((c - 26 * K, c - 24 * K, c + 26 * K, c + 24 * K), fill=(235, 235, 235, 255))
    for n in range(10):                      # lobes
        a = random.uniform(0, 2 * math.pi)
        r = random.uniform(20, 30) * K
        rad = random.uniform(8, 14) * K
        x, y = c + math.cos(a) * r, c + math.sin(a) * r
        d.ellipse((x - rad, y - rad, x + rad, y + rad), fill=(235, 235, 235, 255))
    for n in range(9):                       # spikes
        a = 2 * math.pi * n / 9 + random.uniform(-0.2, 0.2)
        r1, r2 = 24 * K, random.uniform(44, 58) * K
        half = random.uniform(0.07, 0.13)
        d.polygon([(c + math.cos(a - half) * r1, c + math.sin(a - half) * r1),
                   (c + math.cos(a) * r2, c + math.sin(a) * r2),
                   (c + math.cos(a + half) * r1, c + math.sin(a + half) * r1)], fill=(235, 235, 235, 255))
    for n in range(14):                      # flying drops
        a = random.uniform(0, 2 * math.pi)
        r = random.uniform(40, 60) * K
        rad = random.uniform(1.5, 4.5) * K
        x, y = c + math.cos(a) * r, c + math.sin(a) * r
        d.ellipse((x - rad, y - rad, x + rad, y + rad), fill=(235, 235, 235, 255))
    # a shine on it
    d.ellipse((c - 14 * K, c - 16 * K, c - 2 * K, c - 8 * K), fill=(255, 255, 255, 255))
    finish(img, w, h, "splat", 0.5)


def drop():
    """a teardrop with a shine"""
    w, h = 32, 64
    img = canvas(w, h)
    d = ImageDraw.Draw(img)
    W, H = w * K, h * K
    d.polygon([(W / 2, H * 0.04), (W * 0.18, H * 0.58), (W * 0.82, H * 0.58)], fill=(235, 235, 235, 255))
    d.ellipse((W * 0.12, H * 0.42, W * 0.88, H * 0.96), fill=(235, 235, 235, 255))
    d.ellipse((W * 0.26, H * 0.56, W * 0.42, H * 0.76), fill=(255, 255, 255, 255))
    finish(img, w, h, "drop", 0.3)


def bubble():
    """a bubble: a ring, a faint inside and a shine"""
    w = h = 64
    img = canvas(w, h)
    d = ImageDraw.Draw(img)
    c = w * K / 2
    r = c * 0.86
    d.ellipse((c - r, c - r, c + r, c + r), fill=(255, 255, 255, 70))
    d.ellipse((c - r, c - r, c + r, c + r), outline=(255, 255, 255, 255), width=int(3 * K))
    d.arc((c - r * 0.7, c - r * 0.7, c + r * 0.7, c + r * 0.7), 200, 270, fill=(255, 255, 255, 255), width=int(3.5 * K))
    finish(img, w, h, "bubble", 0.3)


def mask():
    """a round mask (white disc): cuts the icon and its cooldown swipe to a circle"""
    w = h = 128
    img = canvas(w, h)
    d = ImageDraw.Draw(img)
    d.ellipse((1 * K, 1 * K, (w - 1) * K, (h - 1) * K), fill=(255, 255, 255, 255))
    finish(img, w, h, "mask")


def ringglow():
    """a soft ring of light, for the glow / pulse effect around a round icon"""
    w = h = 128
    img = Image.new("RGBA", (w, h))
    px = img.load()
    for y in range(h):
        for x in range(w):
            d = math.hypot(x - w / 2 + 0.5, y - h / 2 + 0.5) / (w / 2)
            a = max(0.0, 1.0 - abs(d - 0.72) / 0.28)
            px[x, y] = (255, 255, 255, int(255 * a * a))
    os.makedirs(OUT, exist_ok=True)
    img.save(os.path.join(OUT, "ringglow.tga"))
    print("wrote ringglow.tga")


def lerp(a, b, t):
    return tuple(int(a[i] + (b[i] - a[i]) * t) for i in range(3))


def ring(name, light, dark, outline, wobble=None, spikes=0, spike_color=None, bumps=0, bump_color=None, drips=0,
         seed=1):
    """A rim for a round icon, 256 x 256: the ring is between 0.74 and 0.97 of the half size (the icon is
    inside it, 0.77 of the half size), shaded from light (top left) to dark (bottom right).
    wobble(angle) -> a change of the outer radius (blobby edges); spikes: little crystals on the outside;
    bumps: little bubbles on the ring; drips: drops that hang from the bottom."""
    random.seed(seed)
    w = h = 256
    S = K * w
    c = S / 2
    r_in, r_out = 0.74 * c, 0.95 * c
    mask = Image.new("L", (S, S), 0)
    md = ImageDraw.Draw(mask)
    pts = []
    for n in range(720):
        a = 2 * math.pi * n / 720
        r = r_out + (wobble(a) * c if wobble else 0)
        pts.append((c + math.cos(a) * r, c + math.sin(a) * r))
    md.polygon(pts, fill=255)
    for n in range(spikes):                      # crystals on the outside
        a = 2 * math.pi * n / spikes + random.uniform(-0.05, 0.05)
        length = random.uniform(0.05, 0.12) * c
        half = 0.045
        base = r_out - 0.02 * c
        md.polygon([(c + math.cos(a - half) * base, c + math.sin(a - half) * base),
                    (c + math.cos(a) * (r_out + length), c + math.sin(a) * (r_out + length)),
                    (c + math.cos(a + half) * base, c + math.sin(a + half) * base)], fill=255)
    for n in range(bumps):                       # bubbles on the ring
        a = random.uniform(0, 2 * math.pi)
        rr = random.uniform(0.025, 0.055) * c
        rad = random.uniform(r_in + rr, r_out)
        md.ellipse((c + math.cos(a) * rad - rr, c + math.sin(a) * rad - rr,
                    c + math.cos(a) * rad + rr, c + math.sin(a) * rad + rr), fill=255)
    for n in range(drips):                       # drops hanging from the bottom
        a = math.pi / 2 + random.uniform(-0.9, 0.9)
        x = c + math.cos(a) * r_out * 0.97
        y = c + math.sin(a) * r_out * 0.97
        length = random.uniform(0.06, 0.16) * c
        wd = random.uniform(0.025, 0.045) * c
        md.polygon([(x - wd, y), (x + wd, y), (x, y + length)], fill=255)
        md.ellipse((x - wd, y + length - wd, x + wd, y + length + wd), fill=255)
    md.ellipse((c - r_in, c - r_in, c + r_in, c + r_in), fill=0)   # the hole for the icon
    # colour: light at the top left, dark at the bottom right
    col = Image.new("RGB", (S, S))
    cd = ImageDraw.Draw(col)
    steps = 64
    for i in range(steps):
        t = i / (steps - 1)
        cd.polygon([(0, 0), (S * 2 * t, 0), (0, S * 2 * t)], fill=lerp(dark, light, 1 - t) if False else lerp(light, dark, t))
    # (the diagonal stripes above are painted from the last to the first, so draw them in order)
    col = Image.new("RGB", (S, S), dark)
    cd = ImageDraw.Draw(col)
    for i in range(steps, 0, -1):
        t = i / steps
        cd.polygon([(0, 0), (S * 2 * t, 0), (0, S * 2 * t)], fill=lerp(light, dark, t))
    img = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    img.paste(col, (0, 0), mask)
    d = ImageDraw.Draw(img)
    # outlines (outer and inner edge) for depth, and a thin bright line inside the ring
    edge = mask.filter(ImageFilter.MaxFilter(5)).point(lambda v: 255 if v > 0 else 0)
    outline_layer = Image.new("RGBA", (S, S), outline + (255,))
    ring_edge = Image.new("L", (S, S), 0)
    ring_edge.paste(edge, (0, 0))
    inner = mask.filter(ImageFilter.MinFilter(5))
    border = Image.composite(Image.new("L", (S, S), 255), Image.new("L", (S, S), 0), edge)
    border = Image.eval(border, lambda v: v)
    border_only = Image.new("L", (S, S), 0)
    border_only.paste(border, (0, 0), Image.eval(inner, lambda v: 255 - v))
    img.paste(outline_layer, (0, 0), border_only)
    # sparkles on the spikes / bumps
    if spike_color:
        sp = Image.new("RGBA", (S, S), (0, 0, 0, 0))
        sd = ImageDraw.Draw(sp)
        for n in range(spikes):
            a = 2 * math.pi * n / spikes
            x, y = c + math.cos(a) * r_out, c + math.sin(a) * r_out
            sd.ellipse((x - 3 * K, y - 3 * K, x + 3 * K, y + 3 * K), fill=spike_color + (200,))
        img = Image.alpha_composite(img, sp)
    finish(img, w, h, name, 0.35)


if __name__ == "__main__":
    glow()
    shard()
    flake()
    splat()
    drop()
    bubble()
    mask()
    ringglow()
    ring("rim_gold", (255, 226, 130), (176, 110, 20), (60, 36, 6), seed=1)
    ring("rim_frost", (235, 250, 255), (90, 150, 215), (28, 60, 110), spikes=22, spike_color=(255, 255, 255), seed=2)
    ring("rim_blood", (190, 20, 24), (62, 0, 6), (24, 0, 2), wobble=lambda a: 0.018 * math.sin(7 * a) + 0.012 * math.sin(13 * a + 1),
         drips=9, seed=3)
    ring("rim_poison", (170, 255, 90), (30, 110, 20), (10, 50, 6), bumps=26, seed=4)
