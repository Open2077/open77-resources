"""Procedural ORIGINAL front canards (both sides in one mesh) for Open77 (Blender 4.5).

    blender --background --factory-startup --python make_canard.py -- --part canard.json --out <dir>

Vehicle frame (metres): X right, Y forward, Z up. Pivot (0, 0, 0): on the car's centre
line, level with the canards' root, halfway along their root chord. Each canard is a thin
plane whose root lies on the bumper's side face at X = +-half_span and which reaches
`span` outboard, swept back, its front edge lower than its rear (incidence) and its tip
raised (dihedral). The root continues `tongue` metres inboard so the plane meets a curved
bumper corner without a gap; body_fit buries that tongue in the bumper.

Styles:
  dive  two stacked planes per side, `gap` apart, the upper one shorter;
  fin   one larger plane per side with a vertical fence under its tip.

Parameters (metres), all optional:
  style dive  half_span 0.90  root 0.17  tip 0.07  span 0.10  sweep 0.07  incidence 9
  dihedral 9  thickness 0.007  gap 0.075  tongue 0.045  sections [8]
Slots: canard_main (planes) and canard_detail (tip fences, trailing-edge strips).
"""
import math
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import vk_common as vk  # noqa: E402
import body_geom as bg  # noqa: E402

DEFAULTS = dict(style='dive', half_span=0.90, root=0.17, tip=0.07, span=0.10, sweep=0.07, incidence=9.0, dihedral=9.0,
                thickness=0.007, gap=0.075, tongue=0.045)
STYLE_DEFAULTS = {'dive': {}, 'fin': dict(root=0.22, tip=0.10, span=0.13, sweep=0.08, incidence=7.0, dihedral=5.0)}


def validate(p):
    if not (0.5 <= p['half_span'] <= 1.4) or not (0.05 <= p['root'] <= 0.4) or not (0.03 <= p['span'] <= 0.25):
        raise SystemExit('half_span 0.5..1.4, root 0.05..0.4, span 0.03..0.25 m')
    if not (0.02 <= p['tip'] <= p['root']) or not (0.0 <= p['tongue'] <= 0.1):
        raise SystemExit('tip 0.02..root, tongue 0..0.1 m')


def plane(p, z0, span, x_root):
    """One right-hand canard plane, root at x_root, as a lofted lens section."""
    r, tip, sw, t = p['root'], p['tip'], p['sweep'], p['thickness']
    inc, dih = math.radians(p['incidence']), math.radians(p['dihedral'])
    xs = [x_root - p['tongue'], x_root, x_root + span * 0.5, x_root + span]
    rings, te_line = [], []
    for x in xs:
        f = max(0.0, (x - x_root) / span)
        c = r + (tip - r) * f
        yle = r / 2 - sw * f
        zb = z0 + max(0.0, x - x_root) * math.tan(dih)
        th = t * (1 - 0.35 * f)
        sec = []
        n = 8
        for k in range(n):
            a = math.pi * k / (n - 1)                     # LE -> TE upper side
            s = (1 - math.cos(a)) / 2
            y = yle - c * s
            zc = zb + (yle - y) * math.tan(inc)
            sec.append((x, y, zc + th / 2 * math.sin(math.pi * min(1.0, s * 1.6)) ** 0.7 + 0.0005))
        for k in range(n - 2, 0, -1):
            a = math.pi * k / (n - 1)
            s = (1 - math.cos(a)) / 2
            y = yle - c * s
            zc = zb + (yle - y) * math.tan(inc)
            sec.append((x, y, zc - th / 2 * math.sin(math.pi * min(1.0, s * 1.6)) ** 0.7 - 0.0005))
        rings.append(sec)
        te_line.append((x, yle - c, zb + c * math.tan(inc)))
    return vk.MeshBuilder().sweep(rings, closed_section=True, cap=True), te_line


def build(p, lod, n):
    q = p
    W = q['half_span']
    right_main, right_detail = vk.MeshBuilder(), vk.MeshBuilder()
    roots = []
    if q['style'] == 'dive':
        levels = [(-q['gap'] / 2, q['span']), (q['gap'] / 2, q['span'] * 0.82)]
    else:
        levels = [(0.0, q['span'])]
    for z0, span in levels:
        b, te = plane(q, z0, span, W)
        right_main.extend(b)
        # A thin strip along the visible trailing edge (gurney), detail colour.
        (xa, ya, za), (xb, yb, zb) = te[1], te[-1]
        strip = [(xa, ya + 0.004, za - 0.001), (xb - 0.004, yb + 0.004, zb - 0.001), (xb - 0.004, yb, zb + 0.008), (xa, ya, za + 0.008)]
        right_detail.extend(vk.MeshBuilder().sweep([[(x, y - 0.002, z) for x, y, z in strip], [(x, y + 0.002, z) for x, y, z in strip]],
                                                   closed_section=True, cap=True))
        roots.append(z0)
    if q['style'] == 'fin':
        # Vertical fence under the tip, following its chord.
        x = W + q['span'] - 0.003
        f = 1.0
        c = q['root'] + (q['tip'] - q['root']) * f
        yle = q['root'] / 2 - q['sweep'] * f
        zt = q['span'] * math.tan(math.radians(q['dihedral']))
        inc = math.tan(math.radians(q['incidence']))
        fence = [(yle + 0.004, zt - 0.002), (yle - c - 0.006, zt + c * inc + 0.002), (yle - c - 0.004, zt + c * inc - 0.055),
                 (yle - c * 0.35, zt - 0.05)]
        right_detail.extend(bg.prism_yz(fence, x - 0.0035, x + 0.0035))
    main, detail = vk.MeshBuilder(), vk.MeshBuilder()
    for b, out in ((right_main, main), (right_detail, detail)):
        out.extend(b)
        out.extend(bg.mirror_x(b))
    # Anchor points: the tongue's inner end must sit inside the bumper; root points are
    # where the visible plane should meet the bumper face.
    r = q['root']
    anchors, root_pts = [], []
    for side in (-1, 1):
        for z0 in roots:
            for f in (0.1, 0.5, 0.9):
                y = r / 2 - r * f
                z = z0 + (r / 2 - y) * math.tan(math.radians(q['incidence']))
                anchors.append([side * (W - q['tongue'] + 0.004), y, z])
                root_pts.append([side * W, y, z])
    mount = {'style': q['style'], 'halfSpan': W, 'span': q['span'], 'root': r, 'tongue': q['tongue'],
             'levels': [round(z, 4) for z in roots],
             'contact': [bg.contact('out', root_pts)], 'anchors': [[round(c, 5) for c in a] for a in anchors],
             'embed': [bg.box((W - q['tongue'] - 0.01, -r, -0.15), (W + 0.02, r, 0.15)),
                       bg.box((-W - 0.02, -r, -0.15), (-W + q['tongue'] + 0.01, r, 0.15))]}
    return {'canard_main': main, 'canard_detail': detail}, mount


if __name__ == '__main__':
    bg.run_generator('canard', DEFAULTS, validate, build,
                     {'canard_main': ((0.05, 0.052, 0.058), 0.0, 0.38), 'canard_detail': ((0.012, 0.012, 0.014), 0.0, 0.12)},
                     "car centre line, level with the root, halfway along the root chord",
                     'Generate original front canards', styles=STYLE_DEFAULTS)
