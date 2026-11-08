"""Drawn motifs of the original sticker themes: 01 Course, 02 Graffiti, 04 Tech, 05 Vague, 06 Filet.

Our own artwork, drawn from scratch by code (Pillow polygons, no font file, no game asset):
the concept boards' drawing code (scratchpad sticker-concepts/src, art.py + themes.py),
reduced to what the motifs of specs/original-stickers.json name in `source.draw`. A motif is
drawn in its own centimetres (x right, y down) inside its bounds; st_art.py turns the image
into the decal textures. Theme 03 (invented sponsor names) is not drawn here: its names are
not cleared.

What the boards' code needed and this module now has, all deterministic: masks (a shape drawn
once, then grown into an outline, shifted into a shadow, filled flat or with a vertical
gradient, or erased out of the art: holes that show the car's own paint), Catmull-Rom curves,
variable-width ribbons, and a small seeded generator (Rng: xorshift64*, so the same numbers on
every Python, unlike `random`'s algorithms). No text: the graffiti "letters" are abstract
bubbles, not glyphs of any alphabet; the only digits are theme 01's number.

Another theme needs no code: its motifs can be PNG files (`source.png`, see the spec notes).

    render(name, size_cm, palette, params, ppc) -> RGBA image of size_cm * ppc pixels
"""
from __future__ import annotations

import math

from PIL import Image, ImageChops, ImageDraw, ImageFilter

SS = 2                                  # supersampling of the pen
RIBBON_STEP = 0.5                       # cm between the samples of a ribbon's width function


def hexc(h, a=255):
    if isinstance(h, tuple):
        return h if len(h) == 4 else (*h, a)
    h = h.lstrip('#')
    return (int(h[0:2], 16), int(h[2:4], 16), int(h[4:6], 16), a)


def mix(c1, c2, t):
    a, b = hexc(c1), hexc(c2)
    return tuple(int(round(a[i] * (1 - t) + b[i] * t)) for i in range(4))


# --------------------------------------------------------------- stroke digits
# Glyph grid: height 6, y down; chamfered strokes drawn as polylines (no font).
DIGITS = {
    '0': (4, [[(1.2, 0), (2.8, 0), (4, 1.2), (4, 4.8), (2.8, 6), (1.2, 6), (0, 4.8), (0, 1.2), (1.2, 0)]]),
    '1': (2, [[(0, 1.4), (1.6, 0), (1.6, 6)]]),
    '2': (4, [[(0, 1.2), (1.2, 0), (2.8, 0), (4, 1.2), (4, 2.4), (0, 6), (4, 6)]]),
    '3': (4, [[(0, 0), (4, 0), (4, 1.0), (1.8, 2.8), (2.8, 2.8), (4, 4.0), (4, 4.8), (2.8, 6), (0, 6)]]),
    '4': (4, [[(3, 6), (3, 0), (0, 4.2), (4, 4.2)]]),
    '5': (4, [[(4, 0), (0.2, 0), (0, 2.8), (2.8, 2.8), (4, 3.8), (4, 4.8), (2.8, 6), (0, 6)]]),
    '6': (4, [[(3.6, 0), (1.2, 0), (0, 1.2), (0, 4.8), (1.2, 6), (2.8, 6), (4, 4.8), (4, 4.0), (2.8, 2.9), (0, 2.9)]]),
    '7': (4, [[(0, 0), (4, 0), (4, 0.9), (1.4, 6)]]),
    '8': (4, [[(1.0, 3), (0.2, 2.1), (0.2, 0.9), (1.1, 0), (2.9, 0), (3.8, 0.9), (3.8, 2.1), (3.0, 3), (1.0, 3),
               (0, 4.0), (0, 5.0), (1.0, 6), (3.0, 6), (4, 5.0), (4, 4.0), (3.0, 3)]]),
    '9': (4, [[(0.4, 6), (2.8, 6), (4, 4.8), (4, 1.2), (2.8, 0), (1.2, 0), (0, 1.2), (0, 2.0), (1.2, 3.1), (4, 3.1)]]),
}


def text_layout(s, track=1.3):
    """Polylines in glyph units and the total width (height 6)."""
    x, lines = 0.0, []
    for i, ch in enumerate(s):
        if ch not in DIGITS:
            raise SystemExit(f'st_draw: no glyph for {ch!r} (digits only)')
        w, polys = DIGITS[ch]
        lines += [[(x + px, py) for px, py in p] for p in polys]
        x += w + (track if i < len(s) - 1 else 0)
    return lines, x


# --------------------------------------------------------------------- pen
class Pen:
    """Draws in motif centimetres (y down) onto a supersampled RGBA image."""

    def __init__(self, bounds, ppc):
        x0, y0, x1, y1 = bounds
        self.x0, self.y0, self.k = x0, y0, ppc * SS
        self.W = max(1, int(math.ceil((x1 - x0) * ppc)))
        self.H = max(1, int(math.ceil((y1 - y0) * ppc)))
        self.img = Image.new('RGBA', (self.W * SS, self.H * SS), (0, 0, 0, 0))
        self.d = ImageDraw.Draw(self.img, 'RGBA')

    def P(self, x, y):
        return ((x - self.x0) * self.k, (y - self.y0) * self.k)

    def poly(self, pts, fill):
        self.d.polygon([self.P(x, y) for x, y in pts], fill=hexc(fill))

    def rect(self, x0, y0, x1, y1, fill):
        self.d.rectangle([self.P(x0, y0), self.P(x1, y1)], fill=hexc(fill))

    def rrect(self, x0, y0, x1, y1, r, fill=None, outline=None, width=0.0):
        self.d.rounded_rectangle([self.P(x0, y0), self.P(x1, y1)], radius=r * self.k,
                                 fill=hexc(fill) if fill else None, outline=hexc(outline) if outline else None,
                                 width=max(1, int(round(width * self.k))) if outline else 0)

    def circle(self, c, r, fill):
        x, y = self.P(*c)
        rr = r * self.k
        self.d.ellipse([x - rr, y - rr, x + rr, y + rr], fill=hexc(fill))

    def ring(self, c, r, width, fill):
        x, y = self.P(*c)
        rr = r * self.k
        self.d.ellipse([x - rr, y - rr, x + rr, y + rr], outline=hexc(fill), width=max(1, int(round(width * self.k))))

    def line(self, pts, w, fill, caps=True):
        q = [self.P(x, y) for x, y in pts]
        self.d.line(q, fill=hexc(fill), width=max(1, int(round(w * self.k))), joint='curve')
        if caps:
            r = w * self.k / 2
            for x, y in (q[0], q[-1]):
                self.d.ellipse([x - r, y - r, x + r, y + r], fill=hexc(fill))

    def text(self, s, cx, cy, h, weight, fill, italic=0.0, track=1.3):
        lines, wu = text_layout(s, track)
        sc = h / 6.0
        ox, oy = cx - wu * sc / 2, cy - h / 2
        for pl in lines:
            self.line([(ox + px * sc + italic * (6 - py) * sc, oy + py * sc) for px, py in pl], weight * sc, fill)

    # masks: a shape drawn once (grey levels 0..255), then used as outline, shadow, fill or hole
    def mask(self):
        return Mask(self)

    def grow(self, m, r_cm):
        """The mask grown by r_cm (blur, threshold, soften): a die-cut outline."""
        r = r_cm * self.k
        if r <= 0.5:
            return m
        b = m.filter(ImageFilter.GaussianBlur(r / 2.0))
        return b.point(lambda v: 255 if v > 6 else 0).filter(ImageFilter.GaussianBlur(0.8))

    def shift(self, m, dx_cm, dy_cm):
        """The mask moved by (dx, dy) cm; what leaves the image is dropped (no wrap-around)."""
        out = Image.new('L', m.size, 0)
        out.paste(m, (int(round(dx_cm * self.k)), int(round(dy_cm * self.k))))
        return out

    def fill(self, m, col):
        layer = Image.new('RGBA', self.img.size, hexc(col))
        layer.putalpha(ImageChops.multiply(m, Image.new('L', m.size, hexc(col)[3])))
        self.img.alpha_composite(layer)

    def gradient(self, m, c_top, c_bot, y_top, y_bot):
        """The mask filled with a vertical gradient from c_top (at y_top cm) to c_bot (at y_bot)."""
        H = self.img.size[1]
        col = Image.new('RGBA', (1, H))
        yt, yb = self.P(0, y_top)[1], self.P(0, y_bot)[1]
        for yy in range(H):
            col.putpixel((0, yy), mix(c_top, c_bot, min(max((yy - yt) / max(yb - yt, 1), 0), 1)))
        layer = col.resize(self.img.size, Image.NEAREST)
        layer.putalpha(ImageChops.multiply(m, layer.getchannel('A')))
        self.img.alpha_composite(layer)

    def erase(self, m):
        """Cut the mask out of everything drawn so far: the car's paint shows through."""
        self.img.putalpha(ImageChops.subtract(self.img.getchannel('A'), m))

    def image(self):
        # premultiplied downsampling: no dark fringe at the cut-out's edge
        return self.img.convert('RGBa').resize((self.W, self.H), Image.LANCZOS).convert('RGBA')


class Mask:
    """A grey-level image the size of its pen's, drawn in the same centimetres."""

    def __init__(self, pen):
        self.P, self.k = pen.P, pen.k
        self.img = Image.new('L', pen.img.size, 0)
        self.d = ImageDraw.Draw(self.img)

    def poly(self, pts, v=255):
        self.d.polygon([self.P(x, y) for x, y in pts], fill=v)

    def rect(self, x0, y0, x1, y1, v=255):
        self.d.rectangle([self.P(x0, y0), self.P(x1, y1)], fill=v)

    def circle(self, c, r, v=255):
        x, y = self.P(*c)
        rr = r * self.k
        self.d.ellipse([x - rr, y - rr, x + rr, y + rr], fill=v)

    def line(self, pts, w, v=255, caps=True):
        q = [self.P(x, y) for x, y in pts]
        self.d.line(q, fill=v, width=max(1, int(round(w * self.k))), joint='curve')
        if caps:
            r = w * self.k / 2
            for x, y in (q[0], q[-1]):
                self.d.ellipse([x - r, y - r, x + r, y + r], fill=v)


# ------------------------------------------------------------ geometry helpers
MASK64 = (1 << 64) - 1


class Rng:
    """xorshift64*: a few seeded numbers for the hand-drawn irregularities, identical on every
    Python (the `random` module's seeding and choice algorithms are not a contract)."""

    def __init__(self, seed):
        self.s = ((int(seed) + 1) * 0x9E3779B97F4A7C15) & MASK64 or 1

    def random(self):
        x = self.s
        x ^= x >> 12
        x ^= (x << 25) & MASK64
        x ^= x >> 27
        self.s = x
        return (((x * 0x2545F4914F6CDD1D) & MASK64) >> 11) / float(1 << 53)

    def uniform(self, a, b):
        return a + (b - a) * self.random()

    def below(self, n):
        return min(n - 1, int(self.random() * n))

    def choice(self, seq):
        return seq[self.below(len(seq))]


def catmull(pts, n=12, closed=False):
    """A Catmull-Rom curve through pts, n samples per span."""
    P = list(pts)
    P = ([P[-1]] + P + [P[0], P[1]]) if closed else ([P[0]] + P + [P[-1]])
    out = []
    for i in range(1, len(P) - 2):
        p0, p1, p2, p3 = P[i - 1], P[i], P[i + 1], P[i + 2]
        for k in range(n):
            t = k / n
            t2, t3 = t * t, t * t * t
            out.append(tuple(0.5 * ((2 * p1[j]) + (-p0[j] + p2[j]) * t + (2 * p0[j] - 5 * p1[j] + 4 * p2[j] - p3[j]) * t2
                                    + (-p0[j] + 3 * p1[j] - 3 * p2[j] + p3[j]) * t3) for j in range(2)))
    if not closed:
        out.append(tuple(P[-2]))
    return out


def densify(pts, step):
    """pts with points added so that no segment is longer than step (the same path)."""
    out = [pts[0]]
    for a, b in zip(pts, pts[1:]):
        k = max(1, int(math.ceil(math.dist(a, b) / step)))
        out.extend((a[0] + (b[0] - a[0]) * i / k, a[1] + (b[1] - a[1]) * i / k) for i in range(1, k + 1))
    return out


def ribbon(pts, w0, w1=None, wfun=None):
    """The polygon of a stroke along pts whose width runs w0 -> w1 (or wfun(t), t = 0..1 of the length).
    A width function is sampled every RIBBON_STEP cm of the path: on a two-point stroke it would
    only be read at both ends (the pinstripes' tapers came out as hairlines and long wedges)."""
    w1 = w0 if w1 is None else w1
    if wfun is not None:
        pts = densify(pts, RIBBON_STEP)
    n = len(pts)
    run = [0.0]
    for i in range(1, n):
        run.append(run[-1] + math.dist(pts[i], pts[i - 1]))
    total = max(run[-1], 1e-9)
    left, right = [], []
    for i, (x, y) in enumerate(pts):
        a, b = pts[min(i + 1, n - 1)], pts[max(i - 1, 0)]
        tx, ty = a[0] - b[0], a[1] - b[1]
        k = math.hypot(tx, ty) or 1e-9
        nx, ny = -ty / k, tx / k
        t = run[i] / total
        w = wfun(t) if wfun else w0 + (w1 - w0) * t
        left.append((x + nx * w / 2, y + ny * w / 2))
        right.append((x - nx * w / 2, y - ny * w / 2))
    return left + right[::-1]


def rot(pts, ang, c=(0, 0)):
    a = math.radians(ang)
    ca, sa = math.cos(a), math.sin(a)
    return [(c[0] + (x - c[0]) * ca - (y - c[1]) * sa, c[1] + (x - c[0]) * sa + (y - c[1]) * ca) for x, y in pts]


def rrect_pts(cx, cy, w, h, r, ang=0, n=6):
    """A rounded rectangle centred on (cx, cy), turned by ang degrees, as a polygon."""
    r = min(r, w / 2, h / 2)
    pts = []
    for qx, qy, a0 in ((w / 2 - r, -h / 2 + r, -90), (w / 2 - r, h / 2 - r, 0), (-w / 2 + r, h / 2 - r, 90),
                       (-w / 2 + r, -h / 2 + r, 180)):
        for k in range(n + 1):
            a = math.radians(a0 + 90 * k / n)
            pts.append((qx + r * math.cos(a), qy + r * math.sin(a)))
    return [(cx + x, cy + y) for x, y in rot(pts, ang)]


def star(c, ro, ri, n, ang=0, jit=0.0, rng=None):
    pts = []
    for k in range(2 * n):
        r = ro if k % 2 == 0 else ri
        if rng is not None and jit:
            r *= 1 + rng.uniform(-jit, jit)
        a = math.radians(ang + 180 * k / n)
        pts.append((c[0] + r * math.cos(a), c[1] + r * math.sin(a)))
    return pts


def taper(t0, t1, w):
    """A width function for ribbon: 0 -> w over t in [0, t0], w, then w -> 0 over [t1, 1]."""
    def f(t):
        k = 1.0
        if t0 > 0 and t < t0:
            k = t / t0
        if t1 < 1 and t > t1:
            k = min(k, (1 - t) / (1 - t1))
        return w * max(0.04, k) ** 0.8
    return f


def centred(size):
    w, h = size
    return (-w / 2, -h / 2, w / 2, h / 2)


# ----------------------------------------------------------- theme 01, Course
def stripes(p, pal, size, params):
    """Two bands with a thin outer pin each; the length is the motif's own (hood, roof, trunk)."""
    h = size[1] / 2
    for s in (-1, 1):
        a, b = s * 5.5, s * 20.5
        p.rect(min(a, b), -h, max(a, b), h, pal['stripe'])
        o = max(a, b) + 1.3 if s > 0 else min(a, b) - 2.3
        p.rect(o, -h, o + 1.0, h, pal['pin'])


def roundel(p, pal, size, params):
    p.circle((0, 0), 21.5, pal['pin'])
    p.circle((0, 0), 19.6, pal['disc'])
    p.text(params.get('text', '77'), -0.6, 0.3, 17.5, 1.5, pal['num'], italic=0.12, track=1.1)


def sill(p, pal, size, params):
    """A pointed band (front at the left), a pin line above it and a chequer at its rear end."""
    p.poly([(-95, 0), (-80, -3.0), (70, -3.0), (70, 3.0), (-80, 3.0)], pal['stripe'])
    p.poly([(-68, -5.3), (70, -5.3), (70, -4.3), (-70, -4.3)], pal['pin'])
    cs = 2.9
    for i in range(7):
        for j in range(3):
            p.rect(72 + i * cs, -4.35 + j * cs, 72 + (i + 1) * cs, -4.35 + (j + 1) * cs,
                   pal['pin'] if (i + j) % 2 == 0 else pal['disc'])


def flag(p, pal, size, params):
    """A waving chequered flag, its pole at the front (left)."""
    cols, rows, cw, ch = 6, 4, 3.4, 3.0
    x0, y0 = -10, -6

    def warp(x, y):
        return (x, y + 1.6 * math.sin((x + 10) / 20 * 2 * math.pi) - 0.08 * x)

    for i in range(cols):
        for j in range(rows):
            q = [(x0 + i * cw, y0 + j * ch), (x0 + (i + 1) * cw, y0 + j * ch),
                 (x0 + (i + 1) * cw, y0 + (j + 1) * ch), (x0 + i * cw, y0 + (j + 1) * ch)]
            p.poly([warp(*v) for v in q], pal['pin'] if (i + j) % 2 == 0 else pal['disc'])
    p.line([(x0 - 0.6, y0 - 2.0), (x0 - 2.2, y0 + 15.5)], 1.0, pal['pin'])


# ----------------------------------------------------------- theme 02, Graffiti
# Abstract bubble shapes, never a letter of any alphabet, and no crew signature. Palette:
# f1 / f2 (fill gradient), outline (die-cut edge), shadow (offset drop), hi (highlights).
def sparkle(p, c, r, col, outline=None):
    if outline:
        p.poly(star(c, r + 0.9, r * 0.22 + 0.7, 4, -90), outline)
    p.poly(star(c, r, r * 0.22, 4, -90), col)


def _bubble(m, rng, cx, cy, w, h, holes, ang):
    """One abstract bubble 'letter': a rounded body plus a lobe, a stem or a foot, and a hole."""
    m.poly(rrect_pts(cx, cy, w, h, min(w, h) * 0.42, ang))
    k = rng.below(3)
    if k == 0:
        m.poly(rrect_pts(cx + w * 0.38, cy - h * 0.22, w * 0.55, h * 0.45, h * 0.2, ang + 18))
    elif k == 1:
        m.poly(rrect_pts(cx - w * 0.28, cy - h * 0.25, w * 0.42, h * 0.9, w * 0.2, ang - 8))
    else:
        m.poly(rrect_pts(cx + w * 0.15, cy + h * 0.38, w * 0.8, h * 0.34, h * 0.16, ang + 10))
    hw, hh = w * 0.22, h * 0.26
    holes.append(rrect_pts(cx + rng.uniform(-w * 0.12, w * 0.12), cy + rng.uniform(-h * 0.15, 0),
                           hw, hh, hw * 0.45, ang + rng.uniform(-20, 20)))


def bubble_tag(p, pal, specs, seed, drips=(), arrow=None, outline=1.6, shadow=(1.8, 2.2), sparkles=()):
    rng = Rng(seed)
    m = p.mask()
    holes = []
    for cx, cy, w, h, ang in specs:
        _bubble(m, rng, cx, cy, w, h, holes, ang)
    for x, y0, y1 in drips:
        m.line([(x, y0), (x, y1)], 1.5)
        m.circle((x, y1 + 0.3), 1.2)
    if arrow:
        pts = catmull(arrow, 10)
        m.poly(ribbon(pts, 3.2, 2.4))
        (x1, y1), (x2, y2) = pts[-2], pts[-1]
        a = math.atan2(y2 - y1, x2 - x1)
        m.poly([(x2 + 5.5 * math.cos(a), y2 + 5.5 * math.sin(a)), (x2 + 4.2 * math.cos(a + 1.75), y2 + 4.2 * math.sin(a + 1.75)),
                (x2 + 4.2 * math.cos(a - 1.75), y2 + 4.2 * math.sin(a - 1.75))])
    hm = p.mask()
    for h in holes:
        hm.poly(h)
    body = ImageChops.subtract(m.img, hm.img)
    p.fill(p.shift(p.grow(body, outline), *shadow), pal['shadow'])
    p.fill(p.grow(body, outline), pal['outline'])
    y0 = min(s[1] - s[3] / 2 for s in specs)
    y1 = max(s[1] + s[3] / 2 for s in specs)
    p.gradient(body, pal['f1'], pal['f2'], y0 + 2, y1 - 1)
    for cx, cy, w, h, ang in specs:
        hx, hy = cx - w * 0.28, cy - h * 0.3
        p.line(rot([(hx, hy + 1.2), (hx + w * 0.16, hy - 0.4)], ang, (hx, hy)), 1.0, pal['hi'])
        p.circle((hx + w * 0.26, hy - 0.6), 0.55, pal['hi'])
    for x, y, r in sparkles:
        sparkle(p, (x, y), r, pal['hi'], pal['outline'])


def graffiti_tag(p, pal, size, params):
    """Door: six bubbles, three drips, a hooked arrow at the rear end, sparkles."""
    specs = [(-46, 2, 19, 30, -8), (-27, -3, 19, 34, 6), (-8, 3, 20, 28, -4), (11, -2, 19, 33, 9),
             (30, 3, 20, 27, -6), (47, -3, 15, 24, 10)]
    bubble_tag(p, pal, specs, 7, drips=[(-30, 14, 20.5), (6, 15, 22), (27, 15, 19)],
               arrow=[(50, 10), (55, 14), (58, 6), (57, -6)],
               sparkles=[(-56, -15, 3.2), (40, -18, 2.6), (58, 16, 2.0)])


def graffiti_drips(p, pal, size, params):
    """Sill band: a wavy paint run, drips hanging from it, a spray of dots above (uniform along u)."""
    rng = Rng(3)
    m = p.mask()
    top = [(-99 + i * 6, -3.6 + rng.uniform(-0.8, 0.8)) for i in range(34)]
    bot = [(x, y + 3.0 + rng.uniform(-0.6, 0.6)) for x, y in top]
    m.poly(top + bot[::-1])
    for i in range(15):
        x = -91 + i * 13 + rng.uniform(-3, 3)
        y1 = rng.uniform(1.5, 4.6)
        m.line([(x, -0.6), (x, y1)], 1.2)
        m.circle((x, y1 + 0.2), 0.95)
    p.fill(p.grow(m.img, 0.6), pal['outline'])
    p.gradient(m.img, pal['f2'], pal['f1'], -4, 3)
    for _ in range(64):
        p.circle((rng.uniform(-96, 96), rng.uniform(-6.6, -5.0)), rng.uniform(0.25, 0.55), pal['f1'])


def graffiti_burst(p, pal, size, params):
    """Hood: a jagged two-tone burst with three white bubbles in it, sparkles at its corners."""
    rng = Rng(11)
    m = p.mask()
    m.poly(star((0, 0), 41, 26, 13, -90, 0.12, rng))
    p.fill(p.shift(p.grow(m.img, 1.8), 2.0, 2.4), pal['shadow'])
    p.fill(p.grow(m.img, 1.8), pal['outline'])
    p.gradient(m.img, pal['f2'], pal['f1'], -40, 40)
    m2 = p.mask()
    m2.poly(star((0, 0), 28, 18, 13, -76, 0.15, rng))
    p.fill(p.grow(m2.img, 0.8), pal['outline'])
    p.gradient(m2.img, pal['f1'], pal['f2'], -28, 28)
    bubble_tag(p, dict(pal, f1='#ffffff', f2=mix(pal['f2'], '#ffffff', 0.55)),
               [(-11, 1, 12, 18, -10), (1, -2, 12, 20, 6), (13, 2, 12, 16, -6)], 5, outline=1.2, shadow=(1.2, 1.5))
    for x, y, r in [(-30, -30, 3.2), (31, -26, 2.4), (-26, 30, 2.2), (33, 28, 3.0)]:
        sparkle(p, (x, y), r, pal['hi'], pal['outline'])


def graffiti_throwup(p, pal, size, params):
    """Rear: a four-bubble throw-up, colours reversed, two sparkles."""
    bubble_tag(p, dict(pal, f1=pal['f2'], f2=pal['f1']),
               [(-22, 0, 15, 15, -6), (-7, -1, 15, 17, 7), (8, 1, 15, 14, -4), (22, -1, 13, 15, 8)], 21,
               outline=1.2, shadow=(1.2, 1.4), sparkles=[(-33, -6, 2.0), (33, 6, 1.6)])


def graffiti_arrows(p, pal, size, params):
    """Rear wings: two swept arrows pointing to the front (left), a sparkle at their tails."""
    m = p.mask()
    for pts, w in (([(24, 5), (8, 7), (-8, 4), (-19, -2)], 3.0), ([(22, -6), (8, -6), (-4, -9), (-14, -8)], 2.2)):
        c = catmull(pts, 10)
        m.poly(ribbon(c, w * 0.6, w))
        (x1, y1), (x2, y2) = c[-2], c[-1]
        a = math.atan2(y2 - y1, x2 - x1)
        hs = w * 1.5
        m.poly([(x2 + hs * 1.2 * math.cos(a), y2 + hs * 1.2 * math.sin(a)),
                (x2 + hs * math.cos(a + 1.8), y2 + hs * math.sin(a + 1.8)),
                (x2 + hs * math.cos(a - 1.8), y2 + hs * math.sin(a - 1.8))])
    p.fill(p.shift(p.grow(m.img, 1.0), 1.0, 1.3), pal['shadow'])
    p.fill(p.grow(m.img, 1.0), pal['outline'])
    p.gradient(m.img, pal['f1'], pal['f2'], -10, 9)
    sparkle(p, (19, 1), 2.2, pal['hi'], pal['outline'])


# ----------------------------------------------------------- theme 04, Tech
# Printed-circuit traces at 45 degrees ending in vias (rings whose hole shows the car's paint),
# chips, a data bar. Palette: trace, accent.
class Vias:
    def __init__(self, p, pal):
        self.p, self.pal, self.holes = p, pal, p.mask()

    def add(self, c, r=1.7):
        self.p.circle(c, r, self.pal['accent'])
        self.holes.circle(c, r * 0.45)

    def done(self):
        self.p.erase(self.holes.img)


def trace(p, pts, pal, w=1.1):
    p.line(pts, w, pal['trace'], caps=False)


def tech_circuit(p, pal, size, params):
    """Door: seven traces running from the front edge back, a chip at the top front, contacts at the rear."""
    v = Vias(p, pal)
    for y0, l1, e in zip((-18, -12, -6, 0, 6, 12, 18), (10, 18, 26, 34, 26, 18, 10), (44, 70, 30, 60, 52, 66, 38)):
        dy = -4 if y0 < 0 else (4 if y0 > 0 else 0)
        x1 = -74 + l1
        trace(p, [(-76, y0), (x1, y0), (x1 + abs(dy), y0 + dy), (e, y0 + dy)], pal)
        v.add((e + 1.5, y0 + dy))
    p.rrect(-48, -24.5, -30, -14.5, 1.0, fill=pal['trace'])
    p.rrect(-46.5, -23, -31.5, -16, 0.6, outline=pal['accent'], width=0.4)
    for k in range(6):
        x = -46.5 + k * 2.9
        p.rect(x, -26, x + 1.3, -24.8, pal['trace'])
    for k in range(5):
        p.rect(56 + k * 3.2, 20.5, 57.8 + k * 3.2, 24, pal['accent'] if k % 2 else pal['trace'])
    v.done()


def tech_data(p, pal, size, params):
    """Sill band: a bar code of data blocks on a thin bus, tick marks above (uniform along u)."""
    rng = Rng(4)
    p.line([(-96, 2.9), (96, 2.9)], 0.5, pal['trace'], caps=False)
    x = -96.0
    while x < 96:
        w = rng.choice([1.5, 2.5, 4, 6, 9])
        p.rect(x, -1.4, min(x + w, 96), 1.4, pal['accent'] if rng.random() < 0.22 else pal['trace'])
        x += w + rng.choice([1.2, 1.8, 3.0])
    for k in range(13):
        xx = -94 + k * 16 + rng.uniform(-2, 2)
        p.rect(xx, -3.8, xx + 1.3, -2.5, pal['trace'])


def tech_chip(p, pal, size, params):
    """Hood: a chip with five pins a side, each fanning out into a trace and a via."""
    v = Vias(p, pal)
    p.rrect(-12, -12, 12, 12, 1.6, fill=pal['trace'])
    p.rrect(-8.5, -8.5, 8.5, 8.5, 1.0, outline=pal['accent'], width=0.7)
    p.circle((0, 0), 2.4, pal['accent'])
    for side in range(4):
        ang = side * 90
        reach = 58 if side in (0, 2) else 60
        for k, o in enumerate((-8, -4, 0, 4, 8)):
            p.poly(rot([(12, o - 0.7), (14, o - 0.7), (14, o + 0.7), (12, o + 0.7)], ang), pal['trace'])
            spread = o * 1.9
            xe = reach - abs(o) * 0.6 - (k % 2) * 6
            trace(p, rot([(14, o), (18, o), (18 + abs(spread - o), spread), (xe, spread)], ang), pal)
            v.add(rot([(xe + 1.6, spread)], ang)[0])
    v.done()


def tech_bus(p, pal, size, params):
    """Rear: a hexagonal node with four traces a side, each ending in a via."""
    v = Vias(p, pal)
    p.poly([(7 * math.cos(math.radians(60 * k)), 7 * math.sin(math.radians(60 * k))) for k in range(6)], pal['trace'])
    p.circle((0, 0), 2.6, pal['accent'])
    for s in (-1, 1):
        for k, y in enumerate((-4.5, -1.5, 1.5, 4.5)):
            x_end = s * (68 - k * 5)
            trace(p, [(s * 7.5, y * 0.55), (s * 14, y * 0.55), (s * (14 + abs(y)), y * 1.5), (x_end, y * 1.5)], pal, 0.8)
            v.add((x_end + s * 1.4, y * 1.5), 1.3)
    v.done()


def tech_roofchip(p, pal, size, params):
    """Roof: a small chip with eight traces in a star."""
    v = Vias(p, pal)
    p.rrect(-6, -6, 6, 6, 1.0, fill=pal['trace'])
    p.rrect(-3.6, -3.6, 3.6, 3.6, 0.6, outline=pal['accent'], width=0.5)
    for k in range(8):
        ang = k * 45
        reach = 26 if k % 2 == 0 else 20
        trace(p, rot([(6, 0), (12, 0), (16, 4), (reach, 4)], ang), pal, 0.8)
        v.add(rot([(reach + 1.4, 4)], ang)[0], 1.3)
    v.done()


# ----------------------------------------------------------- theme 05, Vague et soleil
# A great wave breaking towards the front, a sun disc cut by bands, seigaiha scales, curls,
# blossoms; no kanji, no rays. The thin lines inside the wave are holes: the car's paint.
# Palette: mass, band, foam, sun, petal.
def sun_disc(p, pal, c, r, gaps):
    m = p.mask()
    m.circle(c, r)
    for y, h in gaps:
        m.rect(c[0] - r - 1, c[1] + y, c[0] + r + 1, c[1] + y + h, 0)
    p.fill(m.img, pal['sun'])


WAVE_TOP = [(100, 13), (78, 10), (52, 7), (25, 2), (0, -5), (-22, -12), (-40, -18), (-55, -22), (-68, -21.5),
            (-79, -16.5), (-85, -9), (-84, -3.5), (-79, -1.5), (-74, -4.5), (-72.5, -9)]


def great_wave(p, pal, base_y=26):
    crest_pts = catmull(WAVE_TOP[:9], 8)
    top = catmull(WAVE_TOP, 8)
    face = [(-70, -6), (-66, 4), (-72, 14), (-86, 21), (-100, base_y)]
    p.poly(top + catmull(face, 6) + [(100, base_y)], pal['mass'])
    p.poly(crest_pts + [(x, y + 5.5) for x, y in crest_pts][::-1], pal['band'])
    lines = p.mask()
    for off in (10, 14.5, 19):
        ln = [(x, y + off) for x, y in crest_pts if x > -60]
        lines.line(ln, 0.9)
    p.erase(lines.img)
    for i in range(9):
        t = i / 8
        x = -36 - 46 * t
        y = -16.5 - 4 * math.sin(t * math.pi) + 9 * t * t
        p.poly([(x, y), (x - 4.2, y - 2.6), (x - 6.5, y + 0.8), (x - 3.4, y - 0.2), (x - 2.0, y + 2.8)], pal['foam'])
    p.line([(x, y - 0.2) for x, y in crest_pts[:len(crest_pts) - 10]], 1.1, pal['foam'])
    for dx, dy, r in ((-90, -18, 1.4), (-94, -12, 1.0), (-88, -24, 0.9), (-97, -20, 0.7), (-83, -26, 0.6)):
        p.circle((dx, dy), r, pal['foam'])


def wave_great(p, pal, size, params):
    """Doors: the great wave breaking forward (left), the sun behind it."""
    sun_disc(p, pal, (44, -6), 16, [(3.5, 1.3), (7.5, 1.7), (11.5, 2.1)])
    great_wave(p, pal)


def wave_scales(p, pal, size, params):
    """Sill band: two staggered rows of concentric arcs (seigaiha), cut flat at the bottom, a
    little inside the texture's edge (uniform along u)."""
    R = 5.0
    cols = [pal['mass'], pal['foam'], pal['band'], pal['foam'], pal['mass']]
    for yc, xo in ((1.0, R), (6.0, 0.0)):
        x = -100 + xo
        while x < 100:
            for k, rr in enumerate((R, R * 0.8, R * 0.6, R * 0.4, R * 0.2)):
                p.circle((x, yc), rr, cols[k])
            x += 2 * R
    cut = p.mask()
    cut.rect(-100, 5.6, 100, 12)
    p.erase(cut.img)


def wave_sunsea(p, pal, size, params):
    """Hood: the banded sun rising over three small curling waves (sun towards the windscreen)."""
    sun_disc(p, pal, (0, -6), 27, [(4, 1.8), (10, 2.3), (16, 2.8)])
    for k in range(3):
        ox = -20 + k * 20
        pts = catmull([(ox - 14, 26), (ox - 10, 18), (ox - 2, 13), (ox + 6, 15), (ox + 8, 20), (ox + 4, 22), (ox + 1, 19)], 8)
        p.poly(pts + [(ox + 12, 28), (ox - 14, 28)], pal['mass'])
        p.line(pts[:-6], 1.0, pal['foam'])
    p.rect(-34, 27, 34, 30, pal['mass'])
    p.line([(-32, 32.5), (32, 32.5)], 0.9, pal['band'])


def wave_surf(p, pal, size, params):
    """Rear: seven curls on their lines."""
    for k in range(7):
        ox = -52 + k * 52 / 3
        pts = catmull([(ox - 9, 5), (ox - 6, -1), (ox, -4), (ox + 5, -2.5), (ox + 6, 1), (ox + 3, 2.5), (ox + 1.2, 0.8)], 8)
        p.line(pts, 1.6, pal['mass'])
        p.line([(ox - 9, 5), (ox + 9, 5)], 1.0, pal['band'])


def wave_petals(p, pal, size, params):
    """Front wings: three five-petal blossoms and two loose petals."""
    def blossom(c, r, a0):
        for k in range(5):
            pt = rot([(0, 0), (r * 0.45, -r * 0.42), (r * 1.0, -r * 0.22), (r * 0.86, 0), (r * 1.0, r * 0.22),
                      (r * 0.45, r * 0.42)], a0 + k * 72)
            p.poly([(c[0] + x, c[1] + y) for x, y in pt], pal['petal'])
        p.circle(c, r * 0.22, pal['sun'])
    blossom((-9, -2), 6.0, 10)
    blossom((5, 5), 4.4, 40)
    blossom((12, -6), 3.2, 70)
    for c, a in (((-1, -9), 30), ((12.5, 7), -40)):
        p.poly([(c[0] + x, c[1] + y) for x, y in rot([(0, 0), (1.8, -1.2), (3.6, 0), (1.8, 1.2)], a)], pal['petal'])


# ----------------------------------------------------------- theme 06, Filet
# Coachbuilder's pinstripes: a main line and a thin one. The belt line is cut per panel (one
# decal hangs on one panel): door segments uniform along u, a front segment tapering to a point
# with a fork, a rear segment tapering with a flick. Palette: line, thin.
BELT_Y, THIN_Y, BELT_W, THIN_W = 0.0, 2.2, 1.3, 0.55


def filet_belt(p, pal, size, params):
    """Door segment: the two lines, uniform along u (cut square at the panel's ends)."""
    h = size[0] / 2 + 1
    p.rect(-h, BELT_Y - BELT_W / 2, h, BELT_Y + BELT_W / 2, pal['line'])
    p.rect(-h, THIN_Y - THIN_W / 2, h, THIN_Y + THIN_W / 2, pal['thin'])


def filet_belt_front(p, pal, size, params):
    """Front wing segment: the main line tapers to a point at the front (left), the thin line forks down."""
    h = size[0] / 2
    p.poly(ribbon([(-h + 1, BELT_Y), (h + 1, BELT_Y)], BELT_W, wfun=taper(0.16, 1.0, BELT_W)), pal['line'])
    p.poly(ribbon([(-h + 13, THIN_Y), (h + 1, THIN_Y)], THIN_W, wfun=taper(0.04, 1.0, THIN_W)), pal['thin'])
    fork = catmull([(-h + 22, THIN_Y), (-h + 12, THIN_Y + 0.8), (-h + 4, THIN_Y + 3.0)], 8)
    p.poly(ribbon(fork, THIN_W, wfun=taper(0.0, 0.55, THIN_W)), pal['thin'])


def filet_belt_rear(p, pal, size, params):
    """Rear wing segment: the main line tapers to a point at the rear (right), the thin line ends in a flick up."""
    h = size[0] / 2
    p.poly(ribbon([(-h - 1, BELT_Y), (h - 1, BELT_Y)], BELT_W, wfun=taper(0.0, 0.8, BELT_W)), pal['line'])
    p.poly(ribbon([(-h - 1, THIN_Y), (h - 16, THIN_Y)], THIN_W), pal['thin'])
    flick = catmull([(h - 16, THIN_Y), (h - 8, THIN_Y - 0.8), (h - 2, THIN_Y - 4.6)], 8)
    p.poly(ribbon(flick, THIN_W, wfun=taper(0.0, 0.5, THIN_W)), pal['thin'])


def filet_hood(p, pal, size, params):
    """Hood: two lines converging towards the nose (bottom), a thin line inside each, a diamond."""
    for s in (-1, 1):
        c = catmull([(s * 44, -62), (s * 30, -20), (s * 12, 30), (s * 4.2, 51.5)], 10)
        p.poly(ribbon(c, 1.0, wfun=lambda t: (0.25 + 0.75 * min(1.0, t / 0.12)) * (1.0 - 0.25 * t)), pal['line'])
        c2 = [(x - s * 2.2, y) for x, y in catmull([(s * 44, -55), (s * 30, -16), (s * 12, 30), (s * 4.8, 46)], 10)]
        p.poly(ribbon(c2, THIN_W, wfun=lambda t: THIN_W * (0.2 + 0.8 * min(1.0, t / 0.12))), pal['thin'])
    p.poly([(0, 52), (3.0, 56), (0, 60), (-3.0, 56)], pal['line'])
    p.poly([(0, 54.0), (1.4, 56), (0, 58.0), (-1.4, 56)], pal['thin'])


def filet_rear(p, pal, size, params):
    """Rear: a line each way from a centre diamond, tapering out, a thin line under each."""
    for s in (-1, 1):
        p.poly(ribbon([(s * 6, 0), (s * 74, 0)], 1.0, wfun=taper(0.0, 0.55, 1.0)), pal['line'])
        p.poly(ribbon([(s * 9, 2.2), (s * 52, 2.2)], THIN_W, wfun=taper(0.0, 0.5, THIN_W)), pal['thin'])
    p.poly([(0, -2.4), (2.8, 0), (0, 2.4), (-2.8, 0)], pal['line'])
    p.poly([(0, -1.1), (1.3, 0), (0, 1.1), (-1.3, 0)], pal['thin'])


def filet_sill(p, pal, size, params):
    """Sill: one fine line (7 mm, thinner than the belt line) tapering at both ends."""
    p.poly(ribbon([(-90, 0), (90, 0)], 0.7, wfun=taper(0.08, 0.92, 0.7)), pal['line'])


# name -> (draw, bounds of size): the bounds are the concept's own, so the motif keeps its framing
# (a little wider where the concept's outline or shadow touched its edge).
MOTIFS = {
    'stripes': (stripes, centred),
    'roundel': (roundel, lambda size: (-23, -23, 23, 23)),
    'sill': (sill, lambda size: (-96, -6, 96, 6)),
    'flag': (flag, lambda size: (-14, -10, 12, 12)),
    'g_tag': (graffiti_tag, lambda size: (-66, -29, 66, 29)),
    'g_drips': (graffiti_drips, lambda size: (-96, -7.5, 96, 7.5)),
    'g_burst': (graffiti_burst, lambda size: (-47, -47, 49, 49)),
    'g_throwup': (graffiti_throwup, lambda size: (-38, -15.6, 38, 12.4)),
    'g_arrows': (graffiti_arrows, lambda size: (-29, -14, 30, 14)),
    't_circuit': (tech_circuit, lambda size: (-78, -27, 78, 26)),
    't_data': (tech_data, lambda size: (-96, -4.5, 96, 4)),
    't_chip': (tech_chip, lambda size: (-64, -64, 64, 64)),
    't_bus': (tech_bus, lambda size: (-71, -9, 71, 9)),
    't_roofchip': (tech_roofchip, lambda size: (-30, -30, 30, 30)),
    'v_wave': (wave_great, lambda size: (-101, -29, 101, 27)),
    'v_scales': (wave_scales, lambda size: (-96, -4.5, 96, 6)),
    'v_sunsea': (wave_sunsea, lambda size: (-36, -36, 36, 34)),
    'v_surf': (wave_surf, lambda size: (-64, -6, 64, 7)),
    'v_petals': (wave_petals, lambda size: (-16, -12, 17, 11)),
    # The three belt segments share their vertical framing: the main line sits 1.5 cm above the
    # centre of each, so segments placed at one height (alignTo) continue each other's lines.
    'f_belt': (filet_belt, lambda size: (-size[0] / 2, -3.5, size[0] / 2, 6.5)),
    'f_belt_front': (filet_belt_front, lambda size: (-size[0] / 2, -3.5, size[0] / 2, 6.5)),
    'f_belt_rear': (filet_belt_rear, lambda size: (-size[0] / 2, -3.5, size[0] / 2, 6.5)),
    'f_hood': (filet_hood, lambda size: (-50, -64, 50, 62)),
    'f_rear': (filet_rear, lambda size: (-76, -3.5, 76, 3.5)),
    'f_sill': (filet_sill, lambda size: (-92, -1.5, 92, 1.5)),
}


def render(name, size, palette, params=None, ppc=10):
    if name not in MOTIFS:
        raise SystemExit(f'st_draw: unknown motif {name!r} (known: {", ".join(sorted(MOTIFS))})')
    draw, bounds_of = MOTIFS[name]
    b = bounds_of(size)
    if (round(b[2] - b[0], 6), round(b[3] - b[1], 6)) != (round(size[0], 6), round(size[1], 6)):
        raise SystemExit(f'st_draw: {name} is drawn {b[2] - b[0]} x {b[3] - b[1]} cm, the spec says {size[0]} x {size[1]}')
    pen = Pen(b, ppc)
    draw(pen, palette, size, params or {})
    return pen.image()
