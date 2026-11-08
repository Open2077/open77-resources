"""Procedural ORIGINAL rear diffuser for Open77 (Blender 4.5, background).

    blender --background --factory-startup --python make_diffuser.py -- --part diffuser.json --out <dir>

Vehicle frame (metres): X right, Y forward, Z up. Pivot (0, 0, 0): centre of the plate's
top face on its rear edge, which body_fit sets just inside the rear bumper's lower edge.
The plate is flat (top at z = 0) and reaches `depth` forward under the bumper; vertical
strakes hang under it, deepest (`strake`) at the rear and fading to nothing toward the
front, the way a diffuser's tunnels rise to the exit.

Styles:
  street  four strakes, rounded plate, a thin exit lip;
  race    six strakes, a taller pair of outer fences and a raised exit lip.

Parameters (metres), all optional:
  style street  width 1.00  depth 0.28  strakes 4  strake 0.06  plate 0.009
  fences 0.0 (outer fence extra depth)  lip 0.012  sections [8]
Slots: diff_main (plate, exit lip) and diff_detail (strakes, fences).
"""
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import vk_common as vk  # noqa: E402
import body_geom as bg  # noqa: E402

DEFAULTS = dict(width=1.00, depth=0.28, strakes=4, strake=0.06, plate=0.009, fences=0.0, lip=0.012)
STYLES = {'street': {}, 'race': dict(width=1.16, depth=0.36, strakes=6, strake=0.09, fences=0.035, lip=0.022)}


def validate(p):
    if not (0.5 <= p['width'] <= 1.8) or not (0.12 <= p['depth'] <= 0.6):
        raise SystemExit('width 0.5..1.8 m, depth 0.12..0.6 m')
    if not (2 <= int(p['strakes']) <= 10) or not (0.02 <= p['strake'] <= 0.2) or not (0.004 <= p['plate'] <= 0.03):
        raise SystemExit('strakes 2..10, strake 0.02..0.2 m, plate 0.004..0.03 m')


def build(p, lod, n):
    W, D, t = p['width'], p['depth'], p['plate']
    main, detail = vk.MeshBuilder(), vk.MeshBuilder()
    plate = bg.rounded_rect(W, D, 0.05, steps=4, cx=0.0, cy=D / 2)
    main.extend(bg.prism_xy(plate, -t, 0.0))
    # Exit lip: a slim bar along the rear edge, under the plate.
    lip = p['lip']
    main.extend(bg.prism_yz([(0.018, -t), (0.0, -t), (-0.004, -t - lip), (0.012, -t - lip)], -W / 2 + 0.03, W / 2 - 0.03))
    count = int(p['strakes'])
    span = W - 0.12
    for i in range(count):
        x = -span / 2 + span * i / (count - 1)
        h = p['strake']
        outer = i in (0, count - 1)
        if outer and p['fences']:
            h += p['fences']
        L = D * (0.92 if outer else 0.82)
        th = 0.007 if outer else 0.005
        fin = [(0.004, -t), (0.004, -t - h + 0.006), (0.012, -t - h), (L * 0.42, -t - h * 0.86), (L, -t)]
        detail.extend(bg.prism_yz(fin, x - th, x + th))
    pts = bg.grid_pts(-W / 2 + 0.06, W / 2 - 0.06, 0.012, 0.05, 0.0, nx=7, ny=2)   # rear 5 cm: the visible edge
    mount = {'width': W, 'depth': D, 'strake': p['strake'] + p['fences'], 'bottom': round(-t - p['strake'] - p['fences'], 4),
             'contact': [bg.contact('up', pts)],
             'embed': [bg.box((-W / 2, -0.01, -t * 0.5), (W / 2, D, 0.2))]}
    return {'diff_main': main, 'diff_detail': detail}, mount


if __name__ == '__main__':
    bg.run_generator('diffuser', DEFAULTS, validate, build,
                     {'diff_main': ((0.05, 0.052, 0.058), 0.0, 0.38), 'diff_detail': ((0.012, 0.012, 0.014), 0.0, 0.12)},
                     "centre of the plate's top face on its rear edge (plate runs to +Y)",
                     'Generate an original rear diffuser', styles=STYLES)
