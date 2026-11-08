"""Procedural ORIGINAL side skirts (left and right in one mesh) for Open77 (Blender 4.5).

    blender --background --factory-startup --python make_skirt.py -- --part skirt.json --out <dir>

Vehicle frame (metres): X right, Y forward, Z up. Pivot (0, 0, 0): on the car's centre
line, halfway between the wheel arches, at the height of the sill's lower edge. Each
skirt is a strip whose outer face sits at X = +-half_span, from `drop` below the sill
line to `rise` above it, `length` long, with tapered ends and a thin blade along the
bottom. One mesh holds both sides, so one attach fits a car; the fit table scales X to
the car's sill and Y to its arch-to-arch length.

Styles:
  side    the plain skirt above (default);
  blade   a slimmer skirt carrying a flat splitter blade that stands `blade` proud along
          its bottom, with a small upturned winglet at its rear end;
  rocker  a taller rocker panel with a stepped face (the lower half kicks out 1.5 cm) and
          three vent inserts near its rear end.

Parameters (metres), all optional:
  style side  length 2.00  half_span 1.00  depth 0.045  drop 0.07  rise 0.04  blade 0.018
  taper 0.12  sections [24]  sections along the length, one entry per LOD (max 3)
Slots: skirt_main (skirt bodies, winglets) and skirt_detail (bottom blades, vent inserts).
"""
import math
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import vk_common as vk  # noqa: E402
import body_geom as bg  # noqa: E402

DEFAULTS = dict(length=2.00, half_span=1.00, depth=0.045, drop=0.07, rise=0.04, blade=0.018, taper=0.12)
STYLES = {'side': {}, 'blade': dict(depth=0.04, drop=0.055, rise=0.03, blade=0.05, taper=0.10),
          'rocker': dict(depth=0.06, drop=0.075, rise=0.07, blade=0.0, taper=0.14)}


def validate(p):
    if not (0.6 <= p['length'] <= 4.0) or not (0.6 <= p['half_span'] <= 1.5):
        raise SystemExit('length 0.6..4.0 m, half_span 0.6..1.5 m')
    if not (0.02 <= p['depth'] <= 0.12) or not (0.02 <= p['drop'] <= 0.2) or not (0.0 <= p['rise'] <= 0.15):
        raise SystemExit('depth 0.02..0.12, drop 0.02..0.2, rise 0..0.15 m')
    if not (0.04 <= p['taper'] <= p['length'] / 3):
        raise SystemExit('taper 0.04..length/3 m')


def stations(p, n):
    """Y stations along the skirt, denser in the tapers, with the taper factor (0..1)."""
    L, tp = p['length'], p['taper']
    ends = [i / 4 for i in range(5)]                     # 0..1 across one taper
    mid = max(2, n - 10)
    ys = [(-L / 2 + tp * e, math.sin(math.pi / 2 * e)) for e in ends]
    ys += [(-L / 2 + tp + (L - 2 * tp) * i / mid, 1.0) for i in range(1, mid)]
    ys += [(L / 2 - tp * e, math.sin(math.pi / 2 * e)) for e in reversed(ends)]
    return ys


def build(p, lod, n):
    W, d, dr, ri, bl = p['half_span'], p['depth'], p['drop'], p['rise'], p['blade']
    style = p['style']
    body, blade = [], []
    for y, f in stations(p, n):
        xo = W - d * 0.75 * (1 - f)                      # outer face pulled in at the ends
        lo = -dr * (0.45 + 0.55 * f)                     # bottom rises toward the ends
        xi = W - d
        if style == 'rocker':
            # Stepped face: upper half flush, lower half 1.5 cm proud.
            k = 0.015 * f
            mid = ri - (ri - lo) * 0.45
            body.append([(xi, y, ri), (xo - 0.02 - 0.006, y, ri), (xo - 0.02, y, ri - 0.012), (xo - 0.02, y, mid + 0.004),
                         (xo - 0.02 + k, y, mid - 0.006), (xo - 0.02 + k, y, lo + 0.012), (xo - 0.02 + k - 0.01, y, lo), (xi, y, lo)])
        else:
            body.append([(xi, y, ri), (xo - 0.006, y, ri), (xo, y, ri - 0.012), (xo, y, lo + 0.012), (xo - 0.01, y, lo), (xi, y, lo)])
        if bl > 0:
            b = bl * f + 0.002
            th = 0.008 if style == 'blade' else 0.008
            blade.append([(xo - 0.012, y, lo + 0.001), (xo + b, y, lo + 0.003), (xo + b, y, lo + 0.003 + th - 0.002),
                          (xo - 0.012, y, lo + 0.001 + th + 0.002)])
    right = vk.MeshBuilder().sweep(body, closed_section=True, cap=True)
    right_detail = vk.MeshBuilder()
    if blade:
        right_detail.extend(vk.MeshBuilder().sweep(blade, closed_section=True, cap=True))
    if style == 'blade':
        # Winglet: a small fin rising from the blade's rear end, raked forward.
        y0 = -p['length'] / 2 + p['taper'] * 0.6
        xo = W
        lo = -dr
        fin = [(y0, lo + 0.004), (y0 + 0.11, lo + 0.004), (y0 + 0.02, lo + 0.075), (y0 - 0.01, lo + 0.07)]
        right.extend(bg.prism_yz(fin, xo + bl * 0.5, xo + bl * 0.5 + 0.006))
    if style == 'rocker':
        # Three vent inserts on the stepped face near the rear end (dark slats).
        lo = -dr
        mid = ri - (ri - lo) * 0.45
        x = W - 0.02 + 0.015 + 0.002
        for k in range(3):
            yc = -p['length'] / 2 + p['taper'] + 0.08 + k * 0.075
            vent = [(yc - 0.03, mid - 0.016), (yc + 0.03, mid - 0.016), (yc + 0.03, lo + 0.02), (yc - 0.03, lo + 0.02)]
            right_detail.extend(bg.prism_yz(vent, x - 0.004, x + 0.002))
    main, detail = vk.MeshBuilder(), vk.MeshBuilder()
    for b, out in ((right, main), (right_detail, detail)):
        out.extend(b)
        out.extend(bg.mirror_x(b))
    outer = W - (0.02 if style == 'rocker' else 0.0)
    pts = [(side * (W - d), y, z) for side in (-1, 1) for y in (-p['length'] / 2 + p['taper'], 0.0, p['length'] / 2 - p['taper'])
           for z in (ri * 0.5, (ri - dr) / 2)]
    mount = {'style': style, 'length': p['length'], 'halfSpan': W, 'outer': round(outer, 4), 'depth': d, 'drop': dr, 'rise': ri,
             'blade': bl, 'contact': [bg.contact('out', pts)],
             'embed': [bg.box((W - d - 0.06, -p['length'], -0.2), (outer - 0.012, p['length'], 0.2)),
                       bg.box((-outer + 0.012, -p['length'], -0.2), (-W + d + 0.06, p['length'], 0.2))]}
    return {'skirt_main': main, 'skirt_detail': detail}, mount


if __name__ == '__main__':
    bg.run_generator('skirt', DEFAULTS, validate, build,
                     {'skirt_main': ((0.03, 0.03, 0.035), 0.25, 0.22), 'skirt_detail': ((0.015, 0.015, 0.017), 0.3, 0.22)},
                     'car centre line, halfway between the wheel arches, at the sill lower edge',
                     'Generate original side skirts', styles=STYLES)
