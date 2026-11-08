"""Procedural ORIGINAL rear-window louvers for Open77 (Blender 4.5, background).

    blender --background --factory-startup --python make_louver.py -- --part louver.json --out <dir>

Vehicle frame (metres): X right, Y forward, Z up. Pivot (0, 0, 0): centre of the hinge
header's underside, on the roof's rear edge. The panel is built flat in the z = 0 plane and
runs rearward (-Y) for `length`; body_fit pitches it down onto the rear glass. Two side rails
stand on rubber pads `standoff` above the glass, a header and a tail bar close the frame,
and `slats` blades span between the rails, tilted `blade_angle` (front edge low) so the
glass shows between them from behind. The span crowns down by `crown` at the rails, like the
glass under it, and the panel widens by `taper` toward the rear like a backlight.

Parameters (metres), all optional:
  width 1.06  length 0.60  slats 9  blade 0.05  blade_angle 32  rail 0.032
  rail_height 0.022  crown 0.025  standoff 0.012  taper 0.10  sections [9]
Slots: louver_main (rails, header, tail, slats) and louver_detail (hinges and pads).
"""
import math
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import vk_common as vk  # noqa: E402
import body_geom as bg  # noqa: E402

DEFAULTS = dict(width=1.06, length=0.60, slats=9, blade=0.05, blade_angle=32.0, rail=0.032, rail_height=0.022,
                crown=0.025, standoff=0.012, taper=0.10)


def validate(p):
    if not (0.6 <= p['width'] <= 1.6) or not (0.3 <= p['length'] <= 1.2):
        raise SystemExit('width 0.6..1.6 m, length 0.3..1.2 m')
    if not (3 <= int(p['slats']) <= 16) or not (0.02 <= p['blade'] <= 0.1):
        raise SystemExit('slats 3..16, blade 0.02..0.1 m')
    if not (0.0 <= p['crown'] <= 0.08) or not (0.004 <= p['standoff'] <= 0.04) or not (0.0 <= p['taper'] <= 0.3):
        raise SystemExit('crown 0..0.08, standoff 0.004..0.04 m, taper 0..0.3')


def half_at(p, y):
    """Half-width of the panel at y (0 = header, -length = tail)."""
    f = -y / p['length']
    return p['width'] / 2 * (1 - p['taper'] / 2 + p['taper'] * f)


def crown_z(p, x, y):
    h = half_at(p, y)
    return -p['crown'] * min(1.0, (x / h) ** 2)


def bar_across(p, y_front, y_back, z0, z1, stations, inset=0.0):
    """A bar spanning between the rails, following the crown; section rounded on top."""
    rings = []
    for i in range(stations):
        u = -1 + 2 * i / (stations - 1)
        yc = (y_front + y_back) / 2
        h = half_at(p, yc) - inset
        x = u * h
        dz = crown_z(p, x, yc)
        r = 0.006
        rings.append([(x, y_back, z0 + dz), (x, y_front, z0 + dz), (x, y_front, z1 + dz - r), (x, y_front - r, z1 + dz),
                      (x, y_back + r, z1 + dz), (x, y_back, z1 + dz - r)])
    return vk.MeshBuilder().sweep(rings, closed_section=True, cap=True)


def build(p, lod, n):
    L, so, rh, rw = p['length'], p['standoff'], p['rail_height'], p['rail']
    stations = max(5, min(9, n | 1))
    main, detail = vk.MeshBuilder(), vk.MeshBuilder()
    # Side rails (right one built, then mirrored): straight along the tapered edges,
    # crowned down to -crown, outer top edge chamfered.
    rings = []
    z0 = so - p['crown']
    for k in range(5):
        y = -L * k / 4
        xo = half_at(p, y)
        xi = xo - rw
        rings.append([(xi, y, z0), (xo, y, z0), (xo, y, z0 + rh - 0.006), (xo - 0.006, y, z0 + rh), (xi, y, z0 + rh)])
    rail = vk.MeshBuilder().sweep(rings, closed_section=True, cap=True)
    main.extend(rail)
    main.extend(bg.mirror_x(rail))
    # Hinge header (front) and tail bar, between the rails.
    main.extend(bar_across(p, 0.0, -0.045, so, so + rh + 0.006, stations, inset=rw * 0.5))
    main.extend(bar_across(p, -L + 0.03, -L, so, so + rh * 0.8, stations, inset=rw * 0.5))
    # Slats: tilted blades, front edge low.
    count = int(p['slats'])
    a = math.radians(p['blade_angle'])
    c = p['blade']
    y_first, y_last = -0.045 - c * 0.55, -L + 0.03 + c * 0.45
    for i in range(count):
        yc = y_first + (y_last - y_first) * i / max(1, count - 1)
        zc = so + rh * 0.55
        dy, dz = -math.cos(a) * c / 2, math.sin(a) * c / 2       # centre -> rear edge
        t = 0.0035
        nyy, nzz = math.sin(a) * t, math.cos(a) * t             # blade normal (thickness)
        rings = []
        for k in range(stations):
            u = -1 + 2 * k / (stations - 1)
            h = half_at(p, yc) - rw * 0.6
            x = u * h
            cz = crown_z(p, x, yc)
            fy, fz = yc - dy, zc - dz + cz                         # front edge (low)
            ry, rz = yc + dy, zc + dz + cz                         # rear edge (high)
            rings.append([(x, fy - nyy, fz + nzz), (x, ry - nyy, rz + nzz), (x, ry + nyy, rz - nzz), (x, fy + nyy, fz - nzz)])
        main.extend(vk.MeshBuilder().sweep(rings, closed_section=True, cap=True))
    # Rubber pads under the rails and hinges on the header (right side, mirrored).
    pads, right = [], vk.MeshBuilder()
    for y in (-0.03, -L / 2, -L + 0.035):
        x = half_at(p, y) - rw / 2
        pad = bg.rounded_rect(rw * 0.9, 0.05, 0.008)
        right.extend(bg.prism_xy([(x + px, y + py) for px, py in pad], -p['crown'], z0 + 0.002))
        pads += [(x, y), (-x, y)]
    hx = half_at(p, 0.0) * 0.55
    hinge = bg.rounded_rect(0.05, 0.03, 0.006)
    right.extend(bg.prism_xy([(hx + px, 0.012 + py) for px, py in hinge], crown_z(p, hx, 0.0), so + 0.012))
    detail.extend(right)
    detail.extend(bg.mirror_x(right))
    pts = []
    for x, y in pads:
        for dx in (-0.01, 0.01):
            for dy in (-0.02, 0.02):
                pts.append((x + dx, y + dy, -p['crown']))
    for side in (-1, 1):
        pts.append((side * hx, 0.012, crown_z(p, hx, 0.0)))
    embed = [bg.box((x - rw, y - 0.035, -0.2), (x + rw, y + 0.035, so - p['crown'])) for x, y in pads]
    embed.append(bg.box((-half_at(p, 0.0), -0.01, -0.2), (half_at(p, 0.0), 0.04, so)))
    mount = {'width': p['width'], 'length': L, 'standoff': so, 'crown': p['crown'],
             'contact': [bg.contact('down', pts)], 'embed': embed,
             'groups': {'front': [i for i, q in enumerate(pts) if q[1] > -L / 3],
                        'rear': [i for i, q in enumerate(pts) if q[1] < -2 * L / 3]}}
    return {'louver_main': main, 'louver_detail': detail}, mount


if __name__ == '__main__':
    bg.run_generator('louver', DEFAULTS, validate, build,
                     {'louver_main': ((0.022, 0.022, 0.024), 0.0, 0.8), 'louver_detail': ((0.27, 0.28, 0.3), 1.0, 0.34)},
                     "centre of the hinge header's underside, on the roof's rear edge (panel runs to -Y)",
                     'Generate original rear-window louvers')
