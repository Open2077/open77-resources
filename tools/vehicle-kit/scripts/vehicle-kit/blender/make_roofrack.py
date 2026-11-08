"""Procedural ORIGINAL roof rack (tubular basket) for Open77 (Blender 4.5, background).

    blender --background --factory-startup --python make_roofrack.py -- --part rack.json --out <dir>

Vehicle frame (metres): X right, Y forward, Z up. Pivot (0, 0, 0): centre of the rack's
footprint on the roof; the four feet stand on z = 0. A floor frame with cross bars sits
`height` above the roof, a raised rail loop runs `basket` above it on short posts, and a
wind deflector closes the front.

Styles (every roof item is one group: one at a time on a car):
  basket    the tubular basket above (default);
  bars      two aero crossbars (wing-section extrusions) on four towers;
  tray      a flat expedition platform: square-tube frame, slats, and a light bar along
            its front edge (lens faces in the detail slot);
  lightbar  a slim LED light bar across the roof's front, on two brackets;
  scoop     a forward-facing roof scoop (the hood scoop's shell, smaller).

Parameters (metres), all optional:
  style basket  width 1.00  length 1.10  height 0.075  basket 0.065  tube 0.013  bars 4
  corner 0.10 (frame corner radius)  sections [8]  tube segments, one entry per LOD
Slots: rack_main (frame, bars, rail, posts, housing, shell) and rack_detail (feet, wind
deflector, towers, lenses, mouth wall).
"""
import math
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import vk_common as vk  # noqa: E402
import body_geom as bg  # noqa: E402

DEFAULTS = dict(width=1.00, length=1.10, height=0.075, basket=0.065, tube=0.013, bars=4, corner=0.10)
STYLES = {'basket': {}, 'bars': dict(width=1.04, length=0.72, height=0.07),
          'tray': dict(width=1.00, length=1.20, height=0.06),
          'lightbar': dict(width=0.98, length=0.10, height=0.07),
          'scoop': dict(width=0.32, length=0.40, height=0.07)}


def validate(p):
    if not (0.2 <= p['width'] <= 1.6) or not (0.05 <= p['length'] <= 2.2):
        raise SystemExit('width 0.2..1.6 m, length 0.05..2.2 m')
    if not (0.03 <= p['height'] <= 0.2) or not (0.0 <= p['basket'] <= 0.2) or not (0.006 <= p['tube'] <= 0.03):
        raise SystemExit('height 0.03..0.2, basket 0..0.2, tube 0.006..0.03 m')
    if not (2 <= int(p['bars']) <= 8):
        raise SystemExit('bars 2..8')


def frame(w, l, z, corner):
    pts = [(w / 2, l / 2, z), (-w / 2, l / 2, z), (-w / 2, -l / 2, z), (w / 2, -l / 2, z)]
    return bg.rounded_path(pts, corner, steps=4, closed=True)


def build_basket(p, lod, n):
    seg = max(6, min(12, n if n < 16 else 8))
    w, l, h, b, r = p['width'], p['length'], p['height'], p['basket'], p['tube']
    zf = h + r                                   # floor frame tube centre
    main = vk.MeshBuilder()
    main.extend(bg.tube(frame(w, l, zf, p['corner']), r, seg, closed=True))
    if b > 0:
        main.extend(bg.tube(frame(w, l, zf + b, p['corner']), r * 0.85, seg, closed=True))
        posts = [(sx * w / 2, sy * (l / 2 - p['corner'] - 0.02)) for sx in (-1, 1) for sy in (-1, 1)]
        posts += [(sx * w / 2, 0.0) for sx in (-1, 1)]
        posts += [(0.0, sy * l / 2) for sy in (-1, 1)]
        for x, y in posts:
            main.extend(bg.tube([(x, y, zf), (x, y, zf + b)], r * 0.7, seg))
    bars = int(p['bars'])
    for i in range(bars):
        y = -l / 2 + p['corner'] + (l - 2 * p['corner']) * i / (bars - 1)
        main.extend(bg.tube([(-w / 2, y, zf - r * 0.3), (w / 2, y, zf - r * 0.3)], r * 0.9, seg))
    # Two slats along the length for the basket floor.
    for x in (-w * 0.2, w * 0.2):
        main.extend(bg.tube([(x, -l / 2, zf - r * 0.2), (x, l / 2, zf - r * 0.2)], r * 0.6, seg))

    detail = vk.MeshBuilder()
    feet = [(sx * w / 2, sy * (l / 2 - p['corner'] * 0.6)) for sx in (-1, 1) for sy in (-1, 1)]
    for x, y in feet:
        tower = bg.rounded_rect(0.045, 0.09, 0.012)
        detail.extend(bg.prism_xy([(x + fx, y + fy) for fx, fy in tower], 0.012, zf))
        pad = bg.rounded_rect(0.06, 0.12, 0.018)
        detail.extend(bg.prism_xy([(x + fx, y + fy) for fx, fy in pad], 0.0, 0.012))
    # Wind deflector: a raked plate across the front of the basket.
    yd = l / 2 - 0.01
    defl = [(yd + 0.035, zf + 0.005), (yd + 0.045, zf + 0.012), (yd - 0.005, zf + b * 0.9 + r), (yd - 0.015, zf + b * 0.9 + r - 0.006)]
    detail.extend(bg.prism_yz(defl, -w / 2 + p['corner'], w / 2 - p['corner']))
    return main, detail, feet_mount(feet, 0.06, 0.12, zf), {'top': round(zf + b + r, 4)}


def feet_mount(feet, fw, fl, top):
    """Contact (pad undersides) and embed boxes of a roof item standing on pads."""
    pts, embed = [], []
    for x, y in feet:
        for dx in (-fw * 0.35, fw * 0.35):
            for dy in (-fl * 0.35, fl * 0.35):
                pts.append((x + dx, y + dy, 0.0))
        embed.append(bg.box((x - fw / 2 - 0.02, y - fl / 2 - 0.02, -0.2), (x + fw / 2 + 0.02, y + fl / 2 + 0.02, min(0.03, top))))
    return {'feet': [[round(x, 4), round(y, 4)] for x, y in feet], 'contact': [bg.contact('down', pts)], 'embed': embed}


def tower(x, y, h, w=0.05, l=0.11):
    """A rack foot: a pad plus a tapered tower up to h."""
    out = vk.MeshBuilder()
    pad = bg.rounded_rect(w * 1.2, l, 0.016)
    out.extend(bg.prism_xy([(x + fx, y + fy) for fx, fy in pad], 0.0, 0.012))
    rings = []
    for z, k in ((0.012, 1.0), (h, 0.7)):
        rr = bg.rounded_rect(w * k, l * 0.8 * k, 0.012)
        rings.append([(x + fx, y + fy, z) for fx, fy in rr])
    out.extend(vk.MeshBuilder().sweep(rings, closed_section=True, cap=True))
    return out


def aero_bar(x0, x1, y, z, chord=0.075, thick=0.022):
    """A crossbar with a flattened teardrop section, extruded along X."""
    sec = []
    for k in range(12):
        a = math.tau * k / 12
        c, s_ = math.cos(a), math.sin(a)
        yy = chord / 2 * c
        zz = thick / 2 * s_ * (1.0 - 0.35 * max(0.0, -c))
        sec.append((y + yy, z + zz))
    return bg.prism_yz(sec, x0, x1)


def build_bars(p, lod, n):
    w, l, h = p['width'], p['length'], p['height']
    main, detail = vk.MeshBuilder(), vk.MeshBuilder()
    feet = []
    for sy in (-1, 1):
        y = sy * l / 2
        main.extend(aero_bar(-w / 2, w / 2, y, h + 0.012))
        for sx in (-1, 1):
            x = sx * (w / 2 - 0.07)
            detail.extend(tower(x, y, h + 0.012))
            feet.append((x, y))
            cap = bg.rounded_rect(0.024, 0.08, 0.01)
            detail.extend(bg.prism_xz([(sx * w / 2 + cx * 0.5, h + 0.012 + cz * 0.4) for cx, cz in cap], y - 0.04, y + 0.04))
    return main, detail, feet_mount(feet, 0.06, 0.11, h), {'top': round(h + 0.024, 4)}


def lens_bar(cx, y, z, w, hgt, depth, curve=0.0):
    """(housing, lenses): a slim box housing curved back by `curve` at the ends, its front face
    split into lens tiles."""
    housing, lens = vk.MeshBuilder(), vk.MeshBuilder()
    k = 13
    rings = []
    for i in range(k):
        u = -1 + 2 * i / (k - 1)
        x = cx + u * w / 2
        yy = y - curve * u * u
        r = 0.008
        rings.append([(x, yy - depth, z), (x, yy, z), (x, yy, z + hgt), (x, yy - depth + r, z + hgt), (x, yy - depth, z + hgt - r)])
    housing.extend(vk.MeshBuilder().sweep(rings, closed_section=True, cap=True))
    tiles = 10
    for t in range(tiles):
        u0 = -1 + 2 * (t + 0.08) / tiles
        u1 = -1 + 2 * (t + 0.92) / tiles
        q = []
        for u in (u0, u1):
            x = cx + u * w / 2
            yy = y - curve * u * u + 0.003
            q.append([(x, yy - 0.004, z + hgt * 0.18), (x, yy, z + hgt * 0.18), (x, yy, z + hgt * 0.82), (x, yy - 0.004, z + hgt * 0.82)])
        lens.extend(vk.MeshBuilder().sweep(q, closed_section=True, cap=True))
    return housing, lens


def build_tray(p, lod, n):
    w, l, h = p['width'], p['length'], p['height']
    main, detail = vk.MeshBuilder(), vk.MeshBuilder()
    s = 0.03
    zf = h
    # Square-tube frame: two long sides (along Y) and two cross members (along X).
    for sx in (-1, 1):
        main.extend(bg.prism_yz([(-l / 2, zf), (l / 2, zf), (l / 2, zf + s), (-l / 2, zf + s)], sx * w / 2 - s / 2, sx * w / 2 + s / 2))
    for sy in (-1, 1):
        y = sy * (l / 2 - s / 2)
        main.extend(bg.prism_xz([(-w / 2 + s / 2, zf), (w / 2 - s / 2, zf), (w / 2 - s / 2, zf + s), (-w / 2 + s / 2, zf + s)],
                                y - s / 2, y + s / 2))
    for i in range(6):
        y = -l / 2 + s + (l - 2 * s) * (i + 0.5) / 6
        main.extend(bg.prism_xz([(-w / 2 + s / 2, zf + s * 0.35), (w / 2 - s / 2, zf + s * 0.35), (w / 2 - s / 2, zf + s * 0.75),
                                 (-w / 2 + s / 2, zf + s * 0.75)], y - 0.04, y + 0.04))
    # Light bar on the front edge, on two short brackets.
    housing, lens = lens_bar(0.0, l / 2 + 0.065, zf + s + 0.006, w * 0.86, 0.055, 0.05)
    main.extend(housing)
    detail.extend(lens)
    for sx in (-1, 1):
        main.extend(bg.prism_yz([(l / 2 - 0.01, zf + s), (l / 2 + 0.03, zf + s), (l / 2 + 0.03, zf + s + 0.03), (l / 2 - 0.01, zf + s + 0.006)],
                                sx * w * 0.38 - 0.006, sx * w * 0.38 + 0.006))
    feet = [(sx * (w / 2 - 0.05), sy) for sx in (-1, 1) for sy in (-l / 2 + 0.1, 0.0, l / 2 - 0.1)]
    for x, y in feet:
        main.extend(tower(x, y, zf))
    return main, detail, feet_mount(feet, 0.06, 0.11, zf), {'top': round(zf + s + 0.06, 4)}


def build_lightbar(p, lod, n):
    w, l, h = p['width'], p['length'], p['height']
    main, detail = vk.MeshBuilder(), vk.MeshBuilder()
    housing, lens = lens_bar(0.0, 0.035, h, w, 0.06, 0.055, curve=0.03)
    main.extend(housing)
    detail.extend(lens)
    feet = []
    for sx in (-1, 1):
        x = sx * w * 0.36
        yy = 0.035 - 0.03 * (2 * x / w) ** 2 - 0.0275
        # L bracket: a foot pad on the roof and an upright into the housing's underside.
        main.extend(bg.prism_xy([(x + fx, yy + fy) for fx, fy in bg.rounded_rect(0.05, 0.09, 0.014)], 0.0, 0.01))
        main.extend(bg.prism_yz([(yy - 0.03, 0.01), (yy + 0.025, 0.01), (yy + 0.02, h + 0.004), (yy - 0.02, h + 0.004)], x - 0.006, x + 0.006))
        feet.append((x, yy))
    return main, detail, feet_mount(feet, 0.05, 0.09, h), {'top': round(h + 0.06, 4)}


def build_scoop(p, lod, n):
    import make_hood
    main, detail, pts, _ = make_hood.scoop(p['width'], p['length'], p['height'], 0.01, flange=0.018)
    mount = {'contact': [bg.contact('down', pts)],
             'embed': [bg.box((-p['width'] / 2 - 0.03, -p['length'] / 2 - 0.03, -0.15), (p['width'] / 2 + 0.03, p['length'] / 2 + 0.01, 0.006))]}
    return main, detail, mount, {'top': p['height']}


def build(p, lod, n):
    main, detail, mount, extra = globals()['build_' + p['style']](p, lod, n)
    mount = dict(mount, style=p['style'], width=p['width'], length=p['length'], height=p['height'], **extra)
    return {'rack_main': main, 'rack_detail': detail}, mount


if __name__ == '__main__':
    bg.run_generator('roofrack', DEFAULTS, validate, build,
                     {'rack_main': ((0.015, 0.015, 0.017), 0.3, 0.22), 'rack_detail': ((0.05, 0.05, 0.055), 0.6, 0.4)},
                     'centre of the footprint on the roof (feet on z = 0)',
                     'Generate an original roof rack', styles=STYLES)
