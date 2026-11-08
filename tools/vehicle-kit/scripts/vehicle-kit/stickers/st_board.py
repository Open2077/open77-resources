"""Review board of one original sticker set on one model (st_place.py calls it).

Five orthographic views at 0.5 cm per pixel (left, right and top large, front and rear small,
lv_composite.sheet's layout): the drawn exterior of the player appearance shaded in the theme's
preview paint, glass, lights and trim in their lv_composite colours, the wheels (not in the
surface) drawn from the rig's wheel bones and the dealer table's tyre sizes with a depth test,
and every decal of the set rendered from its own mesh and the motif's texture, depth-tested
against the body and the wheels exactly like the game would order them (a decal more than 3 mm
behind the body is hidden). Each decal's zone is labelled in the view it was laid from; the
footer lists every decal with its host, scale and placement metrics, and the skipped zones.
`overview` puts one theme on a few models side by side (left, top and rear views, no labels):
the picture to show before anyone looks at the boards.

What a board shows is the offline geometry: no engine shading, no decal blending of the game.
"""
from __future__ import annotations

import math
import sys
from pathlib import Path

import numpy as np
from PIL import Image, ImageDraw, ImageFont

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parent / 'liveries'))
from lv_common import hex_rgb  # noqa: E402
from lv_composite import KIND_COLOURS, LIGHT, sheet, to_srgb8  # noqa: E402  (read-only reuse)
from lv_surface import KIND_PAINT, VIEWS, raster, to_image  # noqa: E402

STEP = 0.005
DECAL_BEHIND = 0.003
VIEW_ORDER = ('left', 'right', 'top', 'front', 'rear')
TYRE = np.array([0.025, 0.025, 0.028], np.float32)
RIM = np.array([0.30, 0.30, 0.32], np.float32)
LABEL = (200, 0, 160)


def srgb_to_linear(c):
    """Vectorised, for values in 0..1 (lv_common's is scalar, 0..255)."""
    c = np.asarray(c, np.float32)
    return np.where(c <= 0.04045, c / 12.92, ((c + 0.055) / 1.055) ** 2.4).astype(np.float32)


def wheel_layer(md, view, lo, na, nb):
    """Per cell: the nearest wheel depth (inf: none) and its linear colour."""
    A, B = VIEWS[view][0], VIEWS[view][1]
    ax = {'x': 0, 'y': 1, 'z': 2}
    ia, ib = ax[A], ax[B]
    a = lo[ia] + np.arange(na) * STEP
    b = lo[ib] + np.arange(nb) * STEP
    aa, bb = np.meshgrid(a, b, indexing='ij')
    depth = np.full((na, nb), np.inf)
    col = np.zeros((na, nb, 3), np.float32)
    d_axis, d_sign = VIEWS[view][2], VIEWS[view][3]
    for w in md.wheels:
        c, r, rim, width = np.array(w['centre']), w['tyre'], w['rim'], w['width']
        if view in ('left', 'right'):
            face = d_sign * (c[0] - d_sign * width / 2)        # the tyre's outer face, nearer the camera
            dd = (aa - c[1]) ** 2 + (bb - c[2]) ** 2
            tyre = dd <= r * r
            rim_ = dd <= rim * rim
        else:
            half = {'top': (r, width / 2), 'front': (width / 2, r), 'rear': (width / 2, r)}[view]
            ca, cb = c[ia], c[ib]
            tyre = (np.abs(aa - ca) <= half[0]) & (np.abs(bb - cb) <= half[1])
            rim_ = np.zeros_like(tyre)
            ext = {'top': c[2] + r, 'front': c[1] + r, 'rear': c[1] - r}[view]
            face = d_sign * ext
        nearer = tyre & (face < depth)
        depth[nearer] = face
        col[nearer] = TYRE
        col[nearer & rim_] = RIM
    return depth, col


def render_view(md, view, paint_lin, decals):
    lo, hi = md.lo, md.hi
    owner, zbuf, geo, _ = raster(md.s.tris, view, STEP, lo, hi)
    _A, _B, na, nb = geo
    valid = owner >= 0
    ow = owner.clip(0)
    cam = np.array(VIEWS[view][4])
    n = md.fn[ow]
    n = np.where(((n * cam).sum(-1) < 0)[..., None], -n, n)
    kind = np.where(valid, md.s.kind[ow], -1)
    col = np.ones((na, nb, 3), np.float32)
    col[valid & (kind == KIND_PAINT)] = paint_lin
    for k, c in KIND_COLOURS.items():
        col[valid & (kind == k)] = c
    shade = (0.38 + 0.62 * np.clip((n * LIGHT).sum(-1), 0, 1))[..., None].astype(np.float32)
    wdepth, wcol = wheel_layer(md, view, lo, na, nb)
    body_depth = np.where(valid, zbuf, np.inf)
    # decals: nearest first wins where several overlap (they never should)
    d_depth = np.full((na, nb), np.inf)
    d_rgb = np.zeros((na, nb, 3), np.float32)
    d_a = np.zeros((na, nb), np.float32)
    for pl, mesh, _metrics in decals:
        o, z, _g, bary = raster(mesh['world'], view, STEP, lo, hi, want_bary=True)
        hit = (o >= 0) & (z <= body_depth + DECAL_BEHIND) & (z < wdepth) & (z < d_depth)
        if not hit.any():
            continue
        uv = (mesh['uvTri'][o.clip(0)] * bary[..., None]).sum(-2)
        rgba = pl.motif.sample_rgba(uv[..., 0], uv[..., 1])
        a = rgba[..., 3] * hit
        keep = a > 0.01
        d_depth[keep] = z[keep]
        d_rgb[keep] = srgb_to_linear(rgba[..., :3][keep])
        d_a[keep] = a[keep]
    body = valid & (body_depth <= wdepth)
    img = np.ones((na, nb, 3), np.float32)
    lit = col * (1 - d_a[..., None]) + d_rgb * d_a[..., None]
    img[body] = (lit * shade)[body]
    wheel = np.isfinite(wdepth) & ~body
    img[wheel] = wcol[wheel]
    return to_srgb8(to_image(img, view)), (lo, na, nb)


def to_pixel(view, geo, a, b):
    lo, na, nb = geo
    A, B = {'x': 0, 'y': 1, 'z': 2}[VIEWS[view][0]], {'x': 0, 'y': 1, 'z': 2}[VIEWS[view][1]]
    ia = (a - lo[A]) / STEP
    ib = (b - lo[B]) / STEP
    row = nb - 1 - ib
    col = na - 1 - ia if view in ('left', 'top', 'front') else ia
    return col, row


def board(md, theme, decals, skipped, path, spec):
    paint_lin = srgb_to_linear(np.array(hex_rgb(theme['preview']['paint']), np.float32) / 255.0)
    font = ImageFont.load_default(size=12)
    panels, raw = [], {}
    for view in VIEW_ORDER:
        arr, geo = render_view(md, view, paint_lin, decals)
        raw[view] = arr
        img = Image.fromarray(arr, 'RGB')
        d = ImageDraw.Draw(img)
        for pl, _mesh, _m in decals:
            if pl.zone.view != view:
                continue
            (ca, cb), (ea, eb) = pl.centre, pl.ext
            xs, ys = zip(*[to_pixel(view, geo, ca + sa * ea / 2, cb + sb * eb / 2) for sa in (-1, 1) for sb in (-1, 1)])
            x0, y0 = min(xs), min(ys)
            d.text((x0, max(0, y0 - 14)), pl.zone.name, fill=LABEL, font=font)
        panels.append((view, np.asarray(img)))
    n = len(decals)
    title = (f'{md.key} ({md.m["label"]})  -  theme {theme["id"]} ({theme["label"]})  -  {n} decals '
             f'(cap {spec["maxDecalsPerCar"]})  -  offline geometry, not seen in game')
    out = sheet(panels, title)
    lines = [f'{pl.zone.name:8} {pl.motif.id:8} on {md.s.names[pl.host]:40} x{pl.scale:.2f}  '
             f'{pl.ext[0] * 100:5.1f} x {pl.ext[1] * 100:5.1f} cm  carried {m["carried"]:.3f}  visible {m["visible"]:.3f}  '
             f'onHost {m["onHost"]:.3f}  floating {m["floating"]:.3f}  onWheels {m["onWheels"]}'
             for pl, _mesh, m in decals]
    lines += [f'skipped {s["zone"]}: {s["reason"]}' for s in skipped]
    # As wide as its longest line: a bike's sheet is narrower than the metrics.
    width = max([out.width] + [int(math.ceil(font.getlength(t))) + 16 for t in lines])
    foot = Image.new('RGB', (width, 16 * len(lines) + 10), (255, 255, 255))
    fd = ImageDraw.Draw(foot)
    for i, t in enumerate(lines):
        fd.text((8, 4 + 16 * i), t, fill=(0, 0, 0) if not t.startswith('skipped') else (170, 60, 0), font=font)
    full = Image.new('RGB', (width, out.height + foot.height), (255, 255, 255))
    full.paste(out, (0, 0))
    full.paste(foot, (0, out.height))
    Path(path).parent.mkdir(parents=True, exist_ok=True)
    full.save(path, optimize=True)
    return raw


def overview(theme, tiles, path):
    """One theme on a few models: per model (title, {view: rgb}) a row of its left, top and rear
    views, unlabelled, at the boards' scale."""
    font = ImageFont.load_default(size=15)
    rows = []
    for title, views in tiles:
        imgs = [Image.fromarray(views[v], 'RGB') for v in ('left', 'top', 'rear') if v in views]
        row = Image.new('RGB', (sum(i.width for i in imgs) + 24 * (len(imgs) - 1), max(i.height for i in imgs) + 24),
                        (255, 255, 255))
        ImageDraw.Draw(row).text((4, 2), title, fill=(0, 0, 0), font=font)
        x = 0
        for i in imgs:
            row.paste(i, (x, 24))
            x += i.width + 24
        rows.append(row)
    out = Image.new('RGB', (max(r.width for r in rows) + 16, 44 + sum(r.height + 16 for r in rows)), (255, 255, 255))
    ImageDraw.Draw(out).text((8, 12), f'{theme["group"]}  -  {theme["board"]}  -  offline geometry, not seen in game',
                             fill=(0, 0, 0), font=font)
    y = 44
    for r in rows:
        out.paste(r, (8, y))
        y += r.height + 16
    Path(path).parent.mkdir(parents=True, exist_ok=True)
    out.save(path, optimize=True)
