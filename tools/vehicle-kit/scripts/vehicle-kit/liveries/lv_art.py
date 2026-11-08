"""Original livery artwork, drawn from the spec's parameters (Pillow, no input image).

    uv run --no-project --with pillow --with numpy python -I lv_art.py --spec <spec.json> --out <dir> --preview <dir>

One atlas per design, ATLAS_W x ATLAS_H (lv_common.REGIONS): the car seen from its left,
from its right and from above. Shapes are placed in metres on a nominal car (NOMINAL),
then each model stretches the same atlas over its own bounds (lv_decals.py), so the
artwork is authored once for every model. Text is pre-squeezed for the nominal car's
pixel aspect, so letters keep their shape on a typical body.

Writes, per design:
  <out>/<id>_d.png   RGBA: colour bled outward under transparent texels, the cut-out in the
                     alpha (as the vanilla full-colour stickers carry it; see lv_cook.py)
  <out>/<id>_m.png   the same cut-out, L (the decal material's MaskTexture, read from R)
  <preview>/<id>_flat.png  the atlas over a checkerboard, with the body colours
and <out>/art.json (per-region coverage, for the decal culling and the report).
Text uses Aileron, the CC0 typeface bundled with Pillow (ImageFont.load_default).
"""
from __future__ import annotations

import argparse
import json
import math
import random
import sys
from pathlib import Path

import numpy as np
from PIL import Image, ImageChops, ImageDraw, ImageFilter, ImageFont

sys.path.insert(0, str(Path(__file__).resolve().parent))
from lv_common import ATLAS_H, ATLAS_W, REGIONS, hex_rgb, region_box, write_json  # noqa: E402

SS = 2                                         # supersampling factor
NOMINAL = {'length': 4.6, 'side': 1.0, 'width': 1.9}   # metres: t along the car, h sill->roof, s across


class Region:
    """Metres on the nominal car -> supersampled pixels in one atlas region."""

    def __init__(self, view):
        x0, y0, x1, y1 = (v * SS for v in region_box(view))
        self.view, self.x0, self.y0, self.x1, self.y1 = view, x0, y0, x1, y1
        self.long = NOMINAL['length']
        self.cross = NOMINAL['width'] if view == 'top' else NOMINAL['side']
        self.mx = (x1 - x0) / self.long          # px per metre along the car
        self.my = (y1 - y0) / self.cross         # px per metre across (height or width)

    def x(self, t):
        f = t / self.long
        return self.x1 - f * (self.x1 - self.x0) if self.view == 'right' else self.x0 + f * (self.x1 - self.x0)

    def y(self, h):
        return self.y1 - h / self.cross * (self.y1 - self.y0)

    def pt(self, t, h):
        # Clamped to the region: a shape never spills into the neighbouring view.
        x = min(max(self.x(t), self.x0), self.x1)
        y = min(max(self.y(h), self.y0), self.y1)
        return (x, y)

    def poly(self, pts):
        return [self.pt(t, h) for t, h in pts]


def font(px):
    return ImageFont.load_default(size=max(6, int(px)))


def text(img, reg, t, h, s, cap, fill, stroke=0.07, anchor='mm'):
    """Draws `s` centred at (t, h) metres, cap height `cap` metres, aspect kept on the nominal car."""
    if not s:
        return
    size = cap * reg.my / 0.72                      # Aileron cap height ~0.72 em
    f = font(size)
    sw = max(1, int(size * stroke))
    box = f.getbbox(s, stroke_width=sw)
    w, hgt = box[2] - box[0] + 4 * sw, box[3] - box[1] + 4 * sw
    tile = Image.new('RGBA', (w, hgt), (0, 0, 0, 0))
    ImageDraw.Draw(tile).text((2 * sw - box[0], 2 * sw - box[1]), s, font=f, fill=fill, stroke_width=sw, stroke_fill=fill)
    # The glyphs are drawn at the vertical scale (my px per metre); the atlas runs at mx px per
    # metre along the car, so the tile is stretched by mx/my to keep the letters' aspect.
    tile = tile.resize((max(1, int(round(w * reg.mx / reg.my))), hgt), Image.LANCZOS)
    cx, cy = reg.pt(t, h)
    ox = {'m': tile.width / 2, 'l': 0, 'r': tile.width}[anchor[0]]
    img.alpha_composite(tile, (int(round(cx - ox)), int(round(cy - tile.height / 2))))


def rgba(h, a=255):
    return hex_rgb(h) + (a,)


def checker(d, reg, t0, t1, h0, h1, size, a, b, rows=2):
    """A rows-high band of alternating squares (size metres) from t0 to t1."""
    n = int(round((t1 - t0) / size))
    for i in range(n):
        for r in range(rows):
            col = a if (i + r) % 2 == 0 else b
            if col is None:
                continue
            hh0 = h0 + (h1 - h0) * r / rows
            hh1 = h0 + (h1 - h0) * (r + 1) / rows
            d.polygon(reg.poly([(t0 + i * size, hh0), (t0 + (i + 1) * size, hh0), (t0 + (i + 1) * size, hh1), (t0 + i * size, hh1)]), fill=col)


def rounded_band(d, reg, t0, t1, h0, h1, fill):
    r = (h1 - h0) / 2
    pts = []
    for k in range(13):
        a = math.pi / 2 + math.pi * k / 12
        pts.append((t0 + r + r * math.cos(a) * 1.0, (h0 + h1) / 2 + r * math.sin(a)))
    for k in range(13):
        a = -math.pi / 2 + math.pi * k / 12
        pts.append((t1 - r + r * math.cos(a) * 1.0, (h0 + h1) / 2 + r * math.sin(a)))
    d.polygon(reg.poly(pts), fill=fill)


def circle(d, reg, t, h, r, fill=None, outline=None, width=0):
    cx, cy = reg.pt(t, h)
    rx, ry = r * reg.mx, r * reg.my
    d.ellipse((cx - rx, cy - ry, cx + rx, cy + ry), fill=fill, outline=outline, width=int(width))


def gradient_fill(img, mask, c0, c1, horizontal=True, reverse=False):
    w, h = img.size
    a = np.linspace(0, 1, w if horizontal else h, dtype=np.float32)
    if reverse:
        a = a[::-1]
    c0, c1 = np.array(hex_rgb(c0), np.float32), np.array(hex_rgb(c1), np.float32)
    ramp = (c0[None, :] * (1 - a[:, None]) + c1[None, :] * a[:, None]).astype(np.uint8)
    grad = np.repeat(ramp[None, :, :], h, 0) if horizontal else np.repeat(ramp[:, None, :], w, 1)
    layer = Image.fromarray(np.dstack([grad, np.array(mask)]), 'RGBA')
    img.alpha_composite(layer)


# --------------------------------------------------------------------------- emblems
def emblem(d, reg, kind, t, h, size, ink, accent):
    r = size / 2
    if kind == 'parcel':
        d.polygon(reg.poly([(t - r, h - r * 0.8), (t + r, h - r * 0.8), (t + r, h + r * 0.5), (t - r, h + r * 0.5)]), fill=ink)
        d.polygon(reg.poly([(t - r, h + r * 0.5), (t - r * 0.6, h + r * 0.95), (t + r * 1.2, h + r * 0.95), (t + r, h + r * 0.5)]), fill=ink)
        d.polygon(reg.poly([(t - r * 0.12, h - r * 0.8), (t + r * 0.12, h - r * 0.8), (t + r * 0.12, h + r * 0.5), (t - r * 0.12, h + r * 0.5)]), fill=accent)
    elif kind == 'chevrons':        # a bin pictogram
        d.polygon(reg.poly([(t - r * 0.7, h + r * 0.55), (t + r * 0.7, h + r * 0.55), (t + r * 0.55, h - r), (t - r * 0.55, h - r)]), fill=ink)
        d.polygon(reg.poly([(t - r * 0.85, h + r * 0.62), (t + r * 0.85, h + r * 0.62), (t + r * 0.85, h + r * 0.8), (t - r * 0.85, h + r * 0.8)]), fill=ink)
        for k in (-1, 0, 1):
            d.line(reg.poly([(t + k * r * 0.3, h + r * 0.35), (t + k * r * 0.25, h - r * 0.8)]), fill=accent, width=max(2, int(r * 0.12 * reg.my)))
    elif kind == 'recycle':
        for k in range(3):
            a0 = math.pi / 2 + k * 2 * math.pi / 3
            pts = []
            for j in range(9):
                a = a0 + j * (math.pi / 2) / 8
                pts.append((t + r * 0.8 * math.cos(a), h + r * 0.8 * math.sin(a)))
            for j in reversed(range(9)):
                a = a0 + j * (math.pi / 2) / 8
                pts.append((t + r * 0.45 * math.cos(a), h + r * 0.45 * math.sin(a)))
            d.polygon(reg.poly(pts), fill=ink)
            a = a0 + math.pi / 2
            tip = (t + r * 0.62 * math.cos(a + 0.35), h + r * 0.62 * math.sin(a + 0.35))
            d.polygon(reg.poly([(t + r * 0.95 * math.cos(a), h + r * 0.95 * math.sin(a)),
                                (t + r * 0.30 * math.cos(a), h + r * 0.30 * math.sin(a)), tip]), fill=ink)
    elif kind == 'fan':
        circle(d, reg, t, h, r, outline=ink, width=max(2, r * 0.14 * reg.my))
        for k in range(3):
            a = k * 2 * math.pi / 3
            pts = [(t, h)]
            for j in range(7):
                b = a + j * 0.9 / 6
                pts.append((t + r * 0.78 * math.cos(b), h + r * 0.78 * math.sin(b)))
            d.polygon(reg.poly(pts), fill=ink)
        circle(d, reg, t, h, r * 0.16, fill=accent)
    elif kind == 'wrench':
        w = r * 0.22
        d.polygon(reg.poly([(t - r, h - w), (t + r * 0.55, h - w), (t + r * 0.55, h + w), (t - r, h + w)]), fill=ink)
        circle(d, reg, t + r * 0.7, h, r * 0.42, fill=ink)
        d.polygon(reg.poly([(t + r * 0.7, h - w * 0.8), (t + r * 1.2, h - w * 0.8), (t + r * 1.2, h + w * 0.8), (t + r * 0.7, h + w * 0.8)]), fill=(0, 0, 0, 0))


def ecg(d, reg, t0, t1, h, amp, fill, width):
    pts, t = [], t0
    seg = (t1 - t0) / 3
    for k in range(3):
        b = t0 + k * seg
        pts += [(b, h), (b + seg * 0.35, h), (b + seg * 0.42, h + amp * 0.35), (b + seg * 0.5, h - amp * 0.5),
                (b + seg * 0.58, h + amp), (b + seg * 0.66, h - amp * 0.25), (b + seg * 0.72, h)]
    pts.append((t1, h))
    d.line(reg.poly(pts), fill=fill, width=int(width), joint='curve')


# --------------------------------------------------------------------------- designs
def draw(design, img):
    art, kind = design['art'], design['art']['kind']
    d = ImageDraw.Draw(img)
    sides = [Region('left'), Region('right')]
    top = Region('top')
    ink = rgba(art.get('ink', '#000000'))
    if kind == 'taxi':
        for reg in sides:
            checker(d, reg, 0.3, 4.3, 0.36, 0.46, 0.05, rgba(art['band']), None)
            text(img, reg, 1.95, 0.205, art['text'], 0.17, ink)
            text(img, reg, 3.0, 0.215, art['sub'], 0.05, ink)
            text(img, reg, 4.15, 0.53, 'No 0277', 0.035, ink)
        # Two-row chequer strip across the hood, the same squares as the side band.
        for k in range(16):
            for r in range(2):
                if (k + r) % 2 == 0:
                    t0, s0 = 0.55 + r * 0.1, 0.15 + k * 0.1
                    d.polygon(top.poly([(t0, s0), (t0 + 0.1, s0), (t0 + 0.1, s0 + 0.1), (t0, s0 + 0.1)]), fill=rgba(art['band']))
        text(img, top, 2.65, 0.95, art['roof'], 0.28, ink)
    elif kind == 'swoosh':
        for reg in sides:
            m = Image.new('L', img.size, 0)
            ImageDraw.Draw(m).polygon(reg.poly([(0.25, 0.04), (2.2, 0.06), (4.35, 0.20), (4.35, 0.33), (3.2, 0.24), (1.4, 0.15), (0.25, 0.12)]), fill=255)
            gradient_fill(img, m, art['from'], art['to'], reverse=(reg.view == 'right'))
            text(img, reg, 2.35, 0.43, art['text'], 0.065, ink)
            text(img, reg, 2.35, 0.335, art['sub'], 0.04, ink, stroke=0.03)
        for s0 in (0.16, 1.70):
            m = Image.new('L', img.size, 0)
            ImageDraw.Draw(m).polygon(top.poly([(0.3, s0), (4.3, s0), (4.3, s0 + 0.04), (0.3, s0 + 0.04)]), fill=255)
            gradient_fill(img, m, art['from'], art['to'])
    elif kind == 'service':
        band, accent = rgba(art['band']), rgba(art['accent'])
        for reg in sides:
            rounded_band(d, reg, 0.35, 4.25, 0.17, 0.41, band)
            emblem(d, reg, art['emblem'], 1.0, 0.29, 0.17, ink, accent)
            text(img, reg, 2.55, 0.315, art['text'], 0.075 if len(art['text']) < 15 else 0.06, ink)
            text(img, reg, 2.55, 0.225, art['sub'], 0.035, ink, stroke=0.03)
            if art['emblem'] == 'chevrons':
                for k in range(4):
                    t0 = 3.75 + k * 0.13
                    d.polygon(reg.poly([(t0, 0.02), (t0 + 0.06, 0.02), (t0 + 0.16, 0.15), (t0 + 0.10, 0.15)]), fill=accent)
        d.polygon(top.poly([(1.7, 0.83), (3.7, 0.83), (3.7, 1.07), (1.7, 1.07)]), fill=band)
        if art.get('roof'):
            text(img, top, 2.7, 0.95, art['roof'], 0.17, ink)
    elif kind == 'garage':
        f1, f2 = rgba(art['flame']), rgba(art['flame2'])
        for reg in sides:
            for col, sc in ((f1, 1.0), (f2, 0.62)):
                pts = [(0.25, 0.05)]
                for k, (tl, hh) in enumerate([(1.3, 0.10), (2.1, 0.16), (1.55, 0.21), (2.35, 0.27), (1.4, 0.31), (1.9, 0.38)]):
                    pts.append((0.25 + (tl - 0.25) * sc, 0.05 + hh * (0.6 + 0.4 * sc)))
                    pts.append((0.25 + (tl - 0.25) * sc * 0.72, 0.05 + hh * (0.6 + 0.4 * sc) + 0.025))
                pts.append((0.25, 0.05 + 0.40 * (0.6 + 0.4 * sc)))
                d.polygon(reg.poly(pts), fill=col)
            text(img, reg, 3.15, 0.36, art['text'], 0.07, ink)
            text(img, reg, 3.15, 0.275, art['sub'], 0.032, ink, stroke=0.03)
            emblem(d, reg, 'wrench', 3.15, 0.17, 0.16, ink, ink)
        for col, sc in ((f1, 1.0), (f2, 0.6)):
            pts = [(0.08, 0.1)]
            for k in range(7):
                s = 0.1 + (k + 0.5) * 1.7 / 7
                pts += [(0.08 + 1.25 * sc * (0.75 + 0.25 * ((k * 37) % 5) / 4), s), (0.08 + 0.55 * sc, s + 0.12)]
            pts.append((0.08, 1.8))
            d.polygon(top.poly(pts), fill=col)
    elif kind == 'medic':
        a, b = rgba(art['check_a']), rgba(art['check_b'])
        for reg in sides:
            checker(d, reg, 0.3, 4.3, 0.10, 0.34, 0.12, a, b)
            ecg(d, reg, 0.55, 1.95, 0.45, 0.06, ink, 0.018 * reg.my)
            text(img, reg, 3.05, 0.45, art['text'], 0.07, ink)
        for k in range(16):
            d.polygon(top.poly([(0.20, 0.15 + k * 0.1), (0.30, 0.15 + k * 0.1), (0.30, 0.25 + k * 0.1), (0.20, 0.25 + k * 0.1)]), fill=a if k % 2 else b)
        text(img, top, 2.65, 0.95, art['roof'], 0.24, ink)
    elif kind == 'patrol':
        for reg in sides:
            d.polygon(reg.poly([(0.0, -0.2), (4.6, -0.2), (4.6, 0.20), (0.0, 0.20)]), fill=rgba(art['lower']))
            d.polygon(reg.poly([(0.2, 0.215), (4.4, 0.215), (4.4, 0.255), (0.2, 0.255)]), fill=rgba(art['stripe']))
            text(img, reg, 2.15, 0.39, art['text'], 0.14, ink)
            text(img, reg, 3.35, 0.36, art['sub'], 0.045, ink)
            text(img, reg, 4.05, 0.47, 'NC-77', 0.035, ink)
        text(img, top, 2.65, 0.95, art['roof'], 0.30, ink)
        d.polygon(top.poly([(0.0, 0.0), (1.15, 0.0), (1.15, 1.9), (0.0, 1.9)]), fill=rgba(art['lower']))
    elif kind == 'racing':
        st = rgba(art['stripe'])
        for s0, s1 in ((0.66, 0.86), (1.04, 1.24)):
            d.polygon(top.poly([(0.0, s0), (4.6, s0), (4.6, s1), (0.0, s1)]), fill=st)
        for reg in sides:
            d.polygon(reg.poly([(0.2, 0.06), (4.4, 0.06), (4.4, 0.085), (0.2, 0.085)]), fill=st)
            circle(d, reg, 2.25, 0.30, 0.16, fill=rgba(art['roundel']))
            text(img, reg, 2.25, 0.30, art['number'], 0.13, ink)
    elif kind == 'slash':
        glow = Image.new('RGBA', img.size, (0, 0, 0, 0))
        g = ImageDraw.Draw(glow)
        cols = [rgba(art['a']), rgba(art['b']), rgba(art['c'])]
        for reg in sides:
            for k, col in enumerate(cols):
                o = k * 0.30
                for dd in (g, d):
                    dd.polygon(reg.poly([(0.8 + o, 0.05), (1.0 + o, 0.05), (3.4 + o, 0.42), (3.2 + o, 0.42)]) if k != 2 else
                               reg.poly([(1.4 + o, 0.05), (1.48 + o, 0.05), (3.6 + o, 0.40), (3.52 + o, 0.40)]), fill=col)
        for k, col in enumerate(cols[:2]):
            o = k * 0.25
            for dd in (g, d):
                dd.polygon(top.poly([(0.15 + o, 0.2), (0.3 + o, 0.2), (0.9 + o, 1.7), (0.75 + o, 1.7)]), fill=col)
                dd.polygon(top.poly([(3.7 + o, 0.2), (3.85 + o, 0.2), (4.45 + o, 1.7), (4.3 + o, 1.7)]), fill=col)
        glow = glow.filter(ImageFilter.GaussianBlur(10 * SS))
        ga = np.array(glow)
        ga[..., 3] = (ga[..., 3].astype(np.float32) * 0.85).astype(np.uint8)
        base = Image.fromarray(ga, 'RGBA')
        base.alpha_composite(img)
        img.paste(base)
    elif kind == 'camo':
        rnd = random.Random(art['seed'])
        tones = [rgba(c) for c in art['tones']]
        for reg in sides + [top]:
            cell = 0.07
            nt, nh = int(reg.long / cell) + 2, int(reg.cross / cell) + 2
            coarse = [[rnd.random() for _ in range(nh // 3 + 2)] for _ in range(nt // 3 + 2)]
            for i in range(nt):
                for j in range(nh):
                    v = coarse[i // 3][j // 3] * 0.7 + rnd.random() * 0.3
                    k = 0 if v < 0.30 else 1 if v < 0.55 else 2 if v < 0.78 else 3
                    if k == 0 and rnd.random() < 0.5:
                        continue
                    t0, h0 = i * cell, j * cell - 0.05
                    d.polygon(reg.poly([(t0, h0), (t0 + cell, h0), (t0 + cell, h0 + cell), (t0, h0 + cell)]), fill=tones[k])
    else:
        raise SystemExit(f'lv_art: unknown art kind {kind}')


def clip_regions(img):
    """Nothing may spill over a region border (the gutters stay transparent)."""
    keep = Image.new('L', img.size, 0)
    kd = ImageDraw.Draw(keep)
    for view in REGIONS:
        x0, y0, x1, y1 = region_box(view)
        kd.rectangle((x0 * SS, y0 * SS, x1 * SS - 1, y1 * SS - 1), fill=255)
    a = ImageChops.multiply(img.getchannel('A'), keep)
    img.putalpha(a)


def bleed(rgb, alpha, steps=24):
    """Pushes opaque colours into transparent texels so mips and filtering keep clean edges."""
    rgb = rgb.astype(np.float32)
    w = (alpha > 8).astype(np.float32)
    acc, wt = rgb * w[..., None], w.copy()
    out = rgb.copy()
    known = w > 0
    for _ in range(steps):
        acc = sum(np.roll(np.roll(acc, dy, 0), dx, 1) for dy in (-1, 0, 1) for dx in (-1, 0, 1))
        wt = sum(np.roll(np.roll(wt, dy, 0), dx, 1) for dy in (-1, 0, 1) for dx in (-1, 0, 1))
        new = (wt > 0) & ~known
        out[new] = acc[new] / wt[new][:, None]
        known |= new
        acc = out * known[..., None]
        wt = known.astype(np.float32)
    return out.clip(0, 255).astype(np.uint8)


def flat_preview(design, rgba_img, path):
    w, h = rgba_img.size
    bg = Image.new('RGBA', (w, h + 90), (255, 255, 255, 255))
    cb = Image.new('RGBA', (w, h), hex_rgb(design['primary']) + (255,))
    cb.alpha_composite(rgba_img)
    cd = ImageDraw.Draw(cb)
    for view in REGIONS:
        cd.rectangle(region_box(view), outline=(255, 0, 255, 255), width=1)
    bg.paste(cb, (0, 90))
    d = ImageDraw.Draw(bg)
    d.text((16, 14), f"{design['label']}  ({design['id']}, {design['finish']})", font=font(34), fill=(20, 20, 20))
    d.text((16, 54), 'left side (front at left)  /  right side (front at right)  /  top (front at left)', font=font(22), fill=(90, 90, 90))
    for k, key in enumerate(('primary', 'secondary')):
        x = w - 260 + k * 130
        d.rectangle((x, 14, x + 110, 74), fill=hex_rgb(design[key]), outline=(0, 0, 0))
        d.text((x + 4, 76), key, font=font(14), fill=(0, 0, 0))
    bg.convert('RGB').save(path, optimize=True)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--spec', required=True, type=Path)
    ap.add_argument('--out', required=True, type=Path)
    ap.add_argument('--preview', required=True, type=Path)
    ap.add_argument('--only', default='')
    a = ap.parse_args()
    spec = json.loads(a.spec.read_text(encoding='utf-8'))
    a.out.mkdir(parents=True, exist_ok=True)
    a.preview.mkdir(parents=True, exist_ok=True)
    stats = {}
    for design in spec['designs']:
        if a.only and design['id'] not in a.only.split(','):
            continue
        big = Image.new('RGBA', (ATLAS_W * SS, ATLAS_H * SS), (0, 0, 0, 0))
        draw(design, big)
        clip_regions(big)
        img = big.resize((ATLAS_W, ATLAS_H), Image.LANCZOS)
        arr = np.array(img)
        alpha = arr[..., 3]
        rgb = bleed(arr[..., :3], alpha)
        Image.fromarray(np.dstack([rgb, alpha]), 'RGBA').save(a.out / f"{design['id']}_d.png", optimize=True)
        Image.fromarray(alpha, 'L').save(a.out / f"{design['id']}_m.png", optimize=True)
        flat_preview(design, img, a.preview / f"{design['id']}_flat.png")
        cov = {}
        for view, (x0, y0, x1, y1) in REGIONS.items():
            cov[view] = round(float((alpha[y0:y1, x0:x1] > 8).mean()), 4)
        stats[design['id']] = {'coverage': cov}
        print(f"{design['id']:11} coverage {cov}")
    write_json(a.out / 'art.json', {'atlas': [ATLAS_W, ATLAS_H], 'regions': REGIONS, 'designs': stats})
    print(f'LV_ART_OK designs={len(stats)}')


if __name__ == '__main__':
    main()
