"""Procedural ORIGINAL bull bar (push bar) for Open77 (Blender 4.5, background).

    blender --background --factory-startup --python make_bullbar.py -- --part bar.json --out <dir>

Vehicle frame (metres): X right, Y forward, Z up. Pivot (0, 0, 0): on the centre line,
at the bottom of the bar, on the nominal bumper plane. The tube hoop stands `depth` in
front of that plane. Four mounting arms (two per side, at x = +-`arm_x`, on the lower and
middle cross tubes) run `arm_length` back from the hoop, through the bumper face to the
chassis: their rear part is meant to be inside the body (embed boxes); body_fit checks that
each one meets the face and enters it.

Styles (one front-protection item at a time):
  bar    the push bar above (default);
  strap  a textile tow strap: a bolted anchor plate on the bumper face, off the centre line
         at x = `strap_x`, and a flat loop hanging from it. Pivot for this style: the back
         of the anchor plate (y = 0 on the bumper face), centre of the plate; the plate's
         back continues 2 cm into the bumper (embed).

Parameters (metres), all optional:
  style bar  width 0.95 (hoop legs, centre to centre)  height 0.62  depth 0.14  tube 0.030
  inner 0.36 (inner uprights spacing)  arm_x 0.30  arm_length 0.48  sections [10]  tube segments, one entry per LOD
  (strap) strap_x -0.30  strap_width 0.035  loop 0.13
Slots: bar_main (hoop, uprights, cross tubes / strap) and bar_detail (skid plate, arms,
pads / anchor plate).
"""
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import vk_common as vk  # noqa: E402
import body_geom as bg  # noqa: E402

DEFAULTS = dict(width=0.95, height=0.62, depth=0.14, tube=0.030, inner=0.36, arm_x=0.30, arm_length=0.48, strap_x=-0.30, strap_width=0.035, loop=0.13)
STYLES = {'bar': {}, 'strap': {}}


def validate(p):
    if not (0.5 <= p['width'] <= 1.6) or not (0.3 <= p['height'] <= 1.0):
        raise SystemExit('width 0.5..1.6 m, height 0.3..1.0 m')
    if not (0.05 <= p['depth'] <= 0.4) or not (0.012 <= p['tube'] <= 0.05):
        raise SystemExit('depth 0.05..0.4 m, tube 0.012..0.05 m')
    if not (0.1 <= p['inner'] < p['width'] - 0.1):
        raise SystemExit('inner must be 0.1 m .. width - 0.1 m')
    if not (p['inner'] / 2 + 0.04 <= p['arm_x'] <= p['width'] / 2 - 0.04):
        raise SystemExit('arm_x must lie between the inner uprights and the legs (4 cm from each)')
    if not (p['depth'] + 0.05 <= p['arm_length'] <= 0.8):
        raise SystemExit('arm_length must be depth + 0.05 m .. 0.8 m')


def build_bar(p, lod, n):
    seg = max(6, min(12, n if n < 16 else 10))
    w, h, d, r = p['width'], p['height'], p['depth'], p['tube']
    yb = d                                        # bar plane
    zlow = 0.10
    main = vk.MeshBuilder()
    hoop = [(-w / 2, yb, zlow), (-w / 2, yb, h - r), (-w * 0.22, yb, h - r), (0.0, yb + 0.01, h - r + 0.005),
            (w * 0.22, yb, h - r), (w / 2, yb, h - r), (w / 2, yb, zlow)]
    main.extend(bg.tube(bg.rounded_path(hoop, 0.13, steps=5), r, seg))
    zmid = h * 0.55
    main.extend(bg.tube([(-w / 2, yb, zmid), (w / 2, yb, zmid)], r * 0.8, seg))
    main.extend(bg.tube([(-w / 2, yb, zlow + 0.03), (w / 2, yb, zlow + 0.03)], r * 0.8, seg))
    for sx in (-1, 1):
        x = sx * p['inner'] / 2
        main.extend(bg.tube([(x, yb + 0.004, zlow + 0.03), (x, yb + 0.004, h - r)], r * 0.75, seg))

    detail = vk.MeshBuilder()
    # Skid plate under the hoop, raked back at the bottom.
    skid = [(yb + 0.012, zlow + 0.04), (yb + 0.02, 0.03), (yb - 0.02, 0.0), (yb - 0.06, 0.0), (yb - 0.03, 0.03), (yb - 0.01, zlow + 0.04)]
    detail.extend(bg.prism_yz(skid, -w / 2 + r, w / 2 - r))
    # Mounting arms: flat steel bars from the lower and middle cross tubes back through the
    # bumper face to the chassis rails, at +-arm_x (inboard, where the nose stands furthest
    # forward). Their rear part is inside the bumper.
    ya = yb - p['arm_length']
    arm_z = (zlow + 0.03, zmid)
    for sx in (-1, 1):
        x = sx * p['arm_x']
        for z in arm_z:
            arm = bg.rounded_rect(0.032, 0.05, 0.006)
            detail.extend(bg.prism_xz([(x + ax, z + az) for ax, az in arm], ya, yb))
        # Rubber push pad on the upper part of each inner upright.
        pad = bg.rounded_rect(0.07, 0.18, 0.02)
        detail.extend(bg.prism_xz([(sx * p['inner'] / 2 + px * 0.9, h * 0.78 + pz) for px, pz in pad], yb + r * 0.75, yb + r * 0.75 + 0.022))
    arms = [(sx * p['arm_x'], z) for sx in (-1, 1) for z in arm_z]
    mount = {'width': w, 'height': h, 'depth': d, 'barY': yb, 'armY': round(ya, 4), 'arms': [list(a) for a in arms],
             'embed': [bg.box((x - 0.025, ya - 0.01, z - 0.035), (x + 0.025, yb - r * 0.5, z + 0.035)) for x, z in arms]}
    return {'bar_main': main, 'bar_detail': detail}, mount


def build_strap(p, lod, n):
    x0, sw = p['strap_x'], p['strap_width']
    main, detail = vk.MeshBuilder(), vk.MeshBuilder()
    # Anchor plate: 7 x 5 cm, 1.2 cm proud of the face, 2 cm more inside it.
    plate = bg.rounded_rect(0.07, 0.05, 0.008)
    detail.extend(bg.prism_xz([(x0 + px, pz) for px, pz in plate], -0.02, 0.012))
    for bx in (-0.022, 0.022):
        bolt = bg.rounded_rect(0.012, 0.012, 0.005)
        detail.extend(bg.prism_xz([(x0 + bx + px, pz) for px, pz in bolt], 0.012, 0.017))
    # The loop: leaves the plate's lower front edge, hangs forward and down, folds back.
    L = p['loop']
    path = [(0.014, -0.012), (0.030, -0.030), (0.046, -0.060), (0.052, -L * 0.75), (0.046, -L + 0.012), (0.034, -L),
            (0.022, -L + 0.014), (0.022, -L * 0.62), (0.020, -0.050), (0.016, -0.022)]
    pts3 = [(x0, y, z) for y, z in path]
    main.extend(bg.strip_sweep(pts3, sw, 0.005, closed=True))
    # Stitched block where the loop folds over itself near the plate.
    main.extend(bg.prism_xz([(x0 - sw / 2 - 0.001, -0.016), (x0 + sw / 2 + 0.001, -0.016), (x0 + sw / 2 + 0.001, -0.046),
                             (x0 - sw / 2 - 0.001, -0.046)], 0.016, 0.03))
    pts = [(x0 + dx, 0.0, dz) for dx in (-0.028, 0.0, 0.028) for dz in (-0.018, 0.0, 0.018)]
    mount = {'style': 'strap', 'strapX': x0, 'loop': L, 'bottom': round(-L - 0.003, 4), 'contact': [bg.contact('fwd', pts)],
             'embed': [bg.box((x0 - 0.04, -0.2, -0.03), (x0 + 0.04, 0.0, 0.03))]}
    return {'bar_main': main, 'bar_detail': detail}, mount


def build(p, lod, n):
    return build_strap(p, lod, n) if p['style'] == 'strap' else build_bar(p, lod, n)


if __name__ == '__main__':
    bg.run_generator('bullbar', DEFAULTS, validate, build,
                     {'bar_main': ((0.015, 0.015, 0.017), 0.3, 0.22), 'bar_detail': ((0.02, 0.02, 0.02), 0.0, 0.8)},
                     'centre line, bottom of the bar, on the bumper plane the arms meet',
                     'Generate an original bull bar or tow strap', styles=STYLES)
