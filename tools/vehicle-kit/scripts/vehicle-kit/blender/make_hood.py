"""Procedural ORIGINAL hood scoop / hood vents for Open77 (Blender 4.5, background).

    blender --background --factory-startup --python make_hood.py -- --part hood.json --out <dir>

Vehicle frame (metres): X right, Y forward, Z up. Pivot (0, 0, 0): centre of the part's
footprint on the hood surface (its underside is z = 0 on the centre line); body_fit pitches
it to the hood's slope.

Styles:
  scoop  a forward-facing ram scoop: a thick arched shell rising from the hood toward an
         open mouth, on a thin base flange; a dark back wall closes the mouth;
  vents  two louvered vent panels left and right of the centre line, each a raised frame
         around a dark recess crossed by angled slats, banked outward by `bank`.

Parameters (metres), all optional:
  style scoop  width 0.46  length 0.50  height 0.075  wall 0.012
  (vents) spacing 0.56  vent_width 0.24  vent_length 0.30  slats 5  bank 5
Slots: hood_main (shell, flange / frames, slats) and hood_detail (mouth wall / recesses).
"""
import math
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import vk_common as vk  # noqa: E402
import body_geom as bg  # noqa: E402

DEFAULTS = dict(width=0.46, length=0.50, height=0.075, wall=0.012, spacing=0.56, vent_width=0.24,
                vent_length=0.30, slats=5, bank=5.0)
STYLES = {'scoop': {}, 'vents': {}}


def validate(p):
    if not (0.15 <= p['width'] <= 1.2) or not (0.15 <= p['length'] <= 1.2) or not (0.02 <= p['height'] <= 0.2):
        raise SystemExit('width 0.15..1.2, length 0.15..1.2, height 0.02..0.2 m')
    if not (0.004 <= p['wall'] <= 0.04):
        raise SystemExit('wall 0.004..0.04 m')


def arch(w, h, steps=7):
    """Half-ellipse arch from (-w/2, 0) over the top to (w/2, 0), flattened on top."""
    out = []
    for k in range(steps + 1):
        a = math.pi * (1 - k / steps)
        c, s = math.cos(a), math.sin(a)
        out.append((w / 2 * math.copysign(abs(c) ** 0.8, c), h * s ** 0.55))
    return out


def scoop(width, length, height, wall, flange=0.022, stations=7):
    """(main, detail, contact points, mouth y). Mouth at +Y."""
    main, detail = vk.MeshBuilder(), vk.MeshBuilder()
    rings = []
    y0, y1 = -length / 2, length / 2 - 0.02
    for i in range(stations):
        f = i / (stations - 1)
        y = y0 + (y1 - y0) * f
        h = max(0.006, height * (1 - (1 - f) ** 1.8))
        w = width * (0.72 + 0.28 * f)
        outer = arch(w, h)
        inner = arch(max(0.01, w - 2 * wall), max(0.003, h - wall))
        ring = [(x, y, z) for x, z in outer]
        ring += [(x, y, z) for x, z in reversed(inner)]
        rings.append(ring)
    main.extend(vk.MeshBuilder().sweep(rings, closed_section=True, cap=True))
    # Base flange: a thin rounded plate the shell stands on, its rim 2.2 cm wide.
    fl = bg.rounded_rect(width + 2 * flange, length + flange, 0.04, steps=4, cy=-flange / 2)
    main.extend(bg.prism_xy(fl, -0.002, 0.004))
    # Dark back wall inside the mouth.
    yb = y1 - 0.09
    inner = arch(max(0.01, width - 2 * wall), max(0.003, height * (1 - (1 - (yb - y0) / (y1 - y0)) ** 1.8) - wall))
    detail.extend(bg.prism_xz(inner, yb - 0.004, yb))
    pts = bg.grid_pts(-width / 2 - flange * 0.5, width / 2 + flange * 0.5, -length / 2 - flange * 0.5, length / 2 - flange, -0.002,
                      nx=5, ny=4)
    return main, detail, pts, y1


def vent(cx, w, l, slats, bank, frame=0.028, h=0.016):
    """One vent panel centred at x = cx, banked (outer side down) by `bank` degrees."""
    main, detail = vk.MeshBuilder(), vk.MeshBuilder()
    outer = bg.rounded_rect(w, l, 0.03, steps=4)
    inner = bg.rounded_rect(w - 2 * frame, l - 2 * frame, 0.016, steps=4)
    # Frame ring: outer wall, top and inner wall as one swept loop of sections.
    n = len(outer)
    ring_pts = []
    for (xo, yo), (xi, yi) in zip(outer, inner):
        ring_pts.append([(xo, yo, -0.002), (xo * 0.985, yo * 0.985, h), (xi * 1.02, yi * 1.02, h), (xi, yi, 0.004)])
    frame_mesh = vk.MeshBuilder().sweep([[ring_pts[k][j] for k in range(n)] for j in range(4)], closed_section=True, cap=False)
    # Close the bottom with a plate (also the dark recess, detail).
    main.extend(frame_mesh)
    detail.extend(bg.prism_xy(inner, -0.002, 0.004))
    main.extend(bg.prism_xy(outer, -0.003, -0.001))
    # Slats across the opening (x), tilted rear edge up.
    iw, il = w - 2 * frame, l - 2 * frame
    a = math.radians(38)
    c = il / slats * 1.05
    for k in range(slats):
        yc = -il / 2 + il * (k + 0.5) / slats
        dy, dz = -math.cos(a) * c / 2, math.sin(a) * c / 2
        zc = h * 0.55
        sec = [(yc - dy, zc - dz), (yc + dy, zc + dz), (yc + dy + 0.003, zc + dz - 0.003), (yc - dy + 0.003, zc - dz - 0.003)]
        main.extend(bg.prism_yz(sec, -iw / 2 + 0.002, iw / 2 - 0.002))
    out_m, out_d = vk.MeshBuilder(), vk.MeshBuilder()
    b = math.radians(bank) * (1 if cx >= 0 else -1)
    for src, dst in ((main, out_m), (detail, out_d)):
        for x, y, z in src.verts:
            xr = x * math.cos(b) + z * math.sin(b)
            zr = z * math.cos(b) - x * math.sin(b)
            dst.verts.append((cx + xr, y, zr))
        dst.faces = list(src.faces)
        dst.uvs = list(src.uvs)
    pts = []
    for x, y in ((-w / 2 + 0.02, -l / 2 + 0.02), (w / 2 - 0.02, -l / 2 + 0.02), (-w / 2 + 0.02, l / 2 - 0.02), (w / 2 - 0.02, l / 2 - 0.02),
                 (0.0, 0.0), (-w / 2 + 0.02, 0.0), (w / 2 - 0.02, 0.0)):
        pts.append((cx + x * math.cos(b), y, -0.003 - x * math.sin(b)))
    return out_m, out_d, pts


def build(p, lod, n):
    if p['style'] == 'scoop':
        main, detail, pts, mouth = scoop(p['width'], p['length'], p['height'], p['wall'])
        size = [p['width'], p['length']]
        embed = [bg.box((-p['width'] / 2 - 0.03, -p['length'] / 2 - 0.03, -0.15), (p['width'] / 2 + 0.03, p['length'] / 2 + 0.01, 0.006))]
    else:
        main, detail, pts = vk.MeshBuilder(), vk.MeshBuilder(), []
        for side in (-1, 1):
            m, d, q = vent(side * p['spacing'] / 2, p['vent_width'], p['vent_length'], int(p['slats']), p['bank'])
            main.extend(m)
            detail.extend(d)
            pts += q
        size = [p['spacing'] + p['vent_width'], p['vent_length']]
        embed = [bg.box((side * p['spacing'] / 2 - p['vent_width'] / 2 - 0.02, -p['vent_length'] / 2 - 0.02, -0.15),
                        (side * p['spacing'] / 2 + p['vent_width'] / 2 + 0.02, p['vent_length'] / 2 + 0.02, 0.004)) for side in (-1, 1)]
    mount = {'style': p['style'], 'size': [round(v, 4) for v in size], 'contact': [bg.contact('down', pts)], 'embed': embed}
    return {'hood_main': main, 'hood_detail': detail}, mount


if __name__ == '__main__':
    bg.run_generator('hood', DEFAULTS, validate, build,
                     {'hood_main': ((0.05, 0.052, 0.058), 0.0, 0.38), 'hood_detail': ((0.012, 0.012, 0.014), 0.0, 0.12)},
                     "centre of the footprint on the hood surface (underside z = 0)",
                     'Generate an original hood scoop or hood vents', styles=STYLES)
