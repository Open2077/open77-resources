"""Motif textures of the original sticker themes (specs/original-stickers.json).

    uv run --no-project --with pillow --with numpy python -I st_art.py --spec <spec.json> --out <dir> [--preview <dir>]

One texture pair per motif of every theme, the motif filling the texture (UV 0..1 = the
motif's own bounds, its size in centimetres in the spec): the decal mesh st_place.py lays on
a panel maps that rectangle, so the texel aspect does not matter. Resolution: texelsPerCm of
the motif (the pinstripes: 8, their lines are 0.55 to 1.3 cm) or of the spec, along each axis,
rounded up to a power of two and capped at maxTexture (the livery atlas runs at 2 to 4.4
texels per centimetre on a car; the pilot uses 4).

Sources: `source.draw` names a drawing of st_draw.py (our own vector art, the concept boards'
code), `source.png` a committed RGBA image under art/<theme>/ (another theme's motifs, no code).

Writes, per motif, exactly what lv_art.py writes per livery design:
  <out>/<theme>_<motif>_d.png   RGBA: colour bled outward under transparent texels, the cut-out
                                in the alpha (the decal material reads the diffuse alpha)
  <out>/<theme>_<motif>_m.png   the same cut-out, L (the material's MaskTexture, read from R)
and <out>/art.json (texture sizes, opaque share), <preview>/<theme>.png (the motifs over a
checkerboard, on the theme's preview paint).
"""
from __future__ import annotations

import argparse
import json
import math
import re
import sys
from pathlib import Path

import numpy as np
from PIL import Image, ImageDraw, ImageFont

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
sys.path.insert(0, str(HERE.parent / 'liveries'))
from lv_art import bleed  # noqa: E402  (read-only reuse: the livery atlases' edge bleed)
from lv_common import write_json  # noqa: E402

import st_draw  # noqa: E402

ID_RE = r'^[a-z0-9]{2,16}$'


def fail(msg):
    raise SystemExit(f'st_art: {msg}')


def pow2(n, cap):
    return min(cap, 1 << max(2, math.ceil(math.log2(max(4, n)))))


def texture_size(motif, spec):
    """A motif's texelsPerCm (fine pinstripes) or the spec's, per axis, to a power of two."""
    w, h = motif['size']
    t = motif.get('texelsPerCm', spec['texelsPerCm'])
    return pow2(w * t, spec['maxTexture']), pow2(h * t, spec['maxTexture'])


def premultiplied_resize(img, size):
    return img.convert('RGBa').resize(size, Image.LANCZOS).convert('RGBA')


def motif_image(theme, motif, spec, size, art_root):
    src = motif['source']
    if 'draw' in src:
        params = {k: v for k, v in src.items() if k != 'draw'}
        ppc = max(size[0] / motif['size'][0], size[1] / motif['size'][1])
        img = st_draw.render(src['draw'], motif['size'], theme['palette'], params, ppc=max(4, math.ceil(ppc)))
    elif 'png' in src:
        p = (art_root / theme['id'] / src['png']).resolve()
        if art_root.resolve() not in p.parents:
            fail(f'{theme["id"]}/{motif["id"]}: {src["png"]} is outside art/{theme["id"]}')
        if not p.exists():
            fail(f'{theme["id"]}/{motif["id"]}: missing {p}')
        img = Image.open(p)
        if img.mode != 'RGBA':
            fail(f'{p.name} must be RGBA (the cut-out is its alpha), not {img.mode}')
    else:
        fail(f'{theme["id"]}/{motif["id"]}: source needs "draw" or "png"')
    return premultiplied_resize(img, size)


def checker(size, cell=16):
    w, h = size
    yy, xx = np.mgrid[0:h, 0:w]
    v = np.where(((xx // cell) + (yy // cell)) % 2 == 0, 205, 235).astype(np.uint8)
    return Image.fromarray(np.dstack([v, v, v]), 'RGB')


def theme_preview(theme, spec, rendered, path):
    """The motifs at one scale (4 px per cm), each over a checkerboard and over the preview paint."""
    k = 4
    font = ImageFont.load_default(size=13)
    tiles = []
    for m in theme['motifs']:
        img = rendered[m['id']]
        w, h = int(m['size'][0] * k), int(m['size'][1] * k)
        art = premultiplied_resize(img, (w, h))
        a = checker((w, h)).convert('RGBA')
        a.alpha_composite(art)
        b = Image.new('RGBA', (w, h), tuple(int(theme['preview']['paint'][i:i + 2], 16) for i in (1, 3, 5)) + (255,))
        b.alpha_composite(art)
        tiles.append((m, a, b))
    W = max(40 + 2 * t[1].width + 20 for t in tiles + [(None, Image.new('RGB', (300, 1)), None)])
    H = 34 + sum(t[1].height + 34 for t in tiles)
    out = Image.new('RGB', (W, H), (255, 255, 255))
    d = ImageDraw.Draw(out)
    d.text((8, 8), f'{theme["id"]}: {theme["board"]}', fill=(0, 0, 0), font=font)
    y = 34
    for m, a, b in tiles:
        d.text((8, y), f'{m["id"]} {m["size"][0]}x{m["size"][1]} cm -> {", ".join(m["zones"])}'
                       f'{"  (mirrored on the right)" if m.get("mirror") else ""}', fill=(60, 60, 60), font=font)
        out.paste(a.convert('RGB'), (20, y + 18))
        out.paste(b.convert('RGB'), (40 + a.width, y + 18))
        y += a.height + 34
    path.parent.mkdir(parents=True, exist_ok=True)
    out.save(path, optimize=True)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--spec', required=True, type=Path)
    ap.add_argument('--out', required=True, type=Path)
    ap.add_argument('--preview', type=Path)
    a = ap.parse_args()
    spec = json.loads(a.spec.read_text(encoding='utf-8'))
    art_root = a.spec.parent.parent / 'art'
    a.out.mkdir(parents=True, exist_ok=True)
    report = {'schema': 'open77.vehicle-original-stickers.art/1', 'texelsPerCm': spec['texelsPerCm'], 'motifs': {}}
    for theme in spec['themes']:
        if not re.match(ID_RE, theme['id']):
            fail(f'theme id {theme["id"]!r} must match {ID_RE}')
        rendered = {}
        for m in theme['motifs']:
            if not re.match(ID_RE, m['id']):
                fail(f'motif id {theme["id"]}/{m["id"]!r} must match {ID_RE}')
            size = texture_size(m, spec)
            img = motif_image(theme, m, spec, size, art_root)
            arr = np.asarray(img)
            alpha = arr[..., 3].copy()
            if not (alpha > 8).any():
                fail(f'{theme["id"]}/{m["id"]}: the motif is fully transparent')
            rgb = bleed(arr[..., :3], alpha)
            stem = f'{theme["id"]}_{m["id"]}'
            Image.fromarray(np.dstack([rgb, alpha]), 'RGBA').save(a.out / f'{stem}_d.png', optimize=True)
            Image.fromarray(alpha, 'L').save(a.out / f'{stem}_m.png', optimize=True)
            rendered[m['id']] = img
            report['motifs'][stem] = {'theme': theme['id'], 'motif': m['id'], 'sizeCm': m['size'], 'texture': list(size),
                                      'texelsPerCm': [round(size[0] / m['size'][0], 2), round(size[1] / m['size'][1], 2)],
                                      'opaqueShare': round(float((alpha > 128).mean()), 4)}
            print(f'{stem:20} {m["size"][0]:>4}x{m["size"][1]:<4} cm -> {size[0]}x{size[1]} texels, '
                  f'opaque {report["motifs"][stem]["opaqueShare"]:.2f}')
        if a.preview:
            theme_preview(theme, spec, rendered, a.preview / f'{theme["id"]}.png')
    write_json(a.out / 'art.json', report)
    print(f'ST_ART_OK motifs={len(report["motifs"])}')


if __name__ == '__main__':
    main()
