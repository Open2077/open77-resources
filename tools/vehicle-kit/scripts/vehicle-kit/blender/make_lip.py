"""Procedural ORIGINAL front lip / splitter for Open77 (Blender 4.5, background).

    blender --background --factory-startup --python make_lip.py -- --part lip.json --out <dir>

Vehicle frame (metres): X right, Y forward, Z up. Pivot (0, 0, 0): centre of the blade's
top face, on the front bumper's lower front edge. The blade's top face is z = 0; it
reaches `overhang` forward of the edge and `depth` back under the bumper; its planform
curves back by `sweep` at the tips to follow a rounded bumper.

Styles:
  splitter  flat blade with a drooped nose and two small fins under the tips (default);
  race      deeper, thicker splitter with tall end fences and two support rods that climb
            from the blade into the bumper face (their top ends are `anchors`: body_fit
            checks they are buried in the bumper, not floating in front of it);
  street    three-piece chin lip: a centre piece and two corner pieces split by 6 mm
            gaps, a front face angled down into a short air dam, an edge strip under it.

Parameters (metres), all optional:
  style splitter  width 1.60  overhang 0.06  depth 0.14  thickness 0.012  sweep 0.12
  fin_height 0.035  (race) rods 0.56 apart, rod_rise 0.10, rod_back 0.12  (street) dam 0.035
  sections [24]  planform sections across the width, one entry per LOD (max 3)
Slots: lip_main (blade, fences, pieces) and lip_detail (tip fins, rods, edge strip).
"""
import math
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import vk_common as vk  # noqa: E402
import body_geom as bg  # noqa: E402

DEFAULTS = dict(width=1.60, overhang=0.06, depth=0.14, thickness=0.012, sweep=0.12, fin_height=0.035, rods=0.56,
                rod_rise=0.10, rod_back=0.12, dam=0.035)
STYLES = {'splitter': {}, 'race': dict(overhang=0.10, depth=0.22, thickness=0.016, sweep=0.10, fin_height=0.055),
          'street': dict(overhang=0.035, depth=0.11, thickness=0.012, sweep=0.13)}


def validate(p):
    if not (0.8 <= p['width'] <= 2.4):
        raise SystemExit('width must be 0.8..2.4 m')
    if not (0.0 <= p['overhang'] <= 0.2) or not (0.04 <= p['depth'] <= 0.4):
        raise SystemExit('overhang 0..0.2 m, depth 0.04..0.4 m')
    if not (0.004 <= p['thickness'] <= 0.04) or not (0.0 <= p['sweep'] <= 0.4):
        raise SystemExit('thickness 0.004..0.04 m, sweep 0..0.4 m')


def blade_rings(p, x0, x1, count, section):
    """Rings across [x0, x1] of the swept planform; section(x, yf, yr) -> list of (y, z)."""
    half = p['width'] / 2
    rings = []
    for i in range(count):
        x = x0 + (x1 - x0) * i / (count - 1)
        u = x / half
        pull = p['sweep'] * u * u
        yf = p['overhang'] - pull                # front edge
        yr = -p['depth'] - 0.9 * pull            # rear edge follows the curve
        rings.append([(x, y, z) for y, z in section(x, yf, yr)])
    return rings


def front_at(p, x):
    u = x / (p['width'] / 2)
    pull = p['sweep'] * u * u
    return p['overhang'] - pull, -p['depth'] - 0.9 * pull


def build(p, lod, n):
    half = p['width'] / 2
    t = p['thickness']
    count = max(9, n | 1)
    main, detail = vk.MeshBuilder(), vk.MeshBuilder()
    anchors, embed = [], []
    if p['style'] == 'street':
        dam = p['dam']

        def sec(x, yf, yr):
            return [(yr, 0.0), (yf - 0.012, 0.0), (yf + 0.004, -0.010), (yf - 0.004, -dam), (yf - 0.03, -dam - 0.004),
                    (yr, -t)]
        g = 0.003
        cuts = [(-half, -half * 0.5 - g), (-half * 0.5 + g, half * 0.5 - g), (half * 0.5 + g, half)]
        for x0, x1 in cuts:
            k = max(5, count // 2 | 1)
            main.extend(vk.MeshBuilder().sweep(blade_rings(p, x0, x1, k, sec), closed_section=True, cap=True))
            # Edge strip under the dam's front edge.
            strip = [[(x, yf - 0.006, -dam - 0.001), (x, yf - 0.004, -dam + 0.006), (x, yf - 0.026, -dam + 0.002), (x, yf - 0.03, -dam - 0.005)]
                     for x, yf in ((xx, front_at(p, xx)[0]) for xx in (x0 + (x1 - x0) * i / (k - 1) for i in range(k)))]
            detail.extend(vk.MeshBuilder().sweep(strip, closed_section=True, cap=True))
        low = -dam - 0.005
    else:
        def sec(x, yf, yr):
            return [(yr, 0.0), (yf - 0.014, 0.0), (yf, -0.004), (yf - 0.003, -t), (yf - 0.03, -t - 0.002), (yr, -t * 0.6)]
        main.extend(vk.MeshBuilder().sweep(blade_rings(p, -half, half, count, sec), closed_section=True, cap=True))
        fins = detail if p['style'] == 'splitter' else main
        for side in (-1, 1):
            x = side * (half - 0.012)
            yf, yr = front_at(p, x)
            fh = p['fin_height']
            if p['style'] == 'race':
                # Tall end fence: from under the blade up to 4 cm above it, raked at the front.
                fin = [(yr + 0.03, -t + 0.002), (yr + 0.03, 0.035), (yf - 0.05, 0.04), (yf - 0.005, 0.006),
                       (yf - 0.02, -t - fh), (yr + 0.08, -t - fh * 0.6)]
            else:
                fin = [(yr + 0.04, -t + 0.002), (yf - 0.01, -t + 0.002), (yf - 0.03, -t - fh), (yr + 0.07, -t - fh * 0.7)]
            fins.extend(bg.prism_yz(fin, x - 0.004, x + 0.004))
        low = -t - p['fin_height']
        if p['style'] == 'race':
            for side in (-1, 1):
                x = side * p['rods'] / 2
                yf, _ = front_at(p, x)
                a = (x, yf - 0.03, 0.0)
                b = (x, -p['rod_back'], p['rod_rise'])
                detail.extend(bg.tube([a, b], 0.0065, 8))
                foot = bg.rounded_rect(0.03, 0.04, 0.008)
                detail.extend(bg.prism_xy([(x + fx, a[1] + fy) for fx, fy in foot], 0.0, 0.006))
                anchors.append([round(x, 5), -p['rod_back'], round(p['rod_rise'] - 0.006, 5)])
                embed.append(bg.box((x - 0.03, -0.2, 0.0), (x + 0.03, 0.02, p['rod_rise'] + 0.02)))
    pts = []
    for i in range(9):
        x = -half * 0.92 + 1.84 * half * i / 8
        edge = front_at(p, x)[0] - p['overhang']   # the bumper's lower front edge over this x
        for back in (0.015, 0.05):                  # the strip just behind it: what is seen
            pts.append((x, edge - back, 0.0))
    embed.append(bg.box((-half, -0.6, 0.0), (half, 0.3, 0.3)))
    mount = {'style': p['style'], 'width': p['width'], 'overhang': p['overhang'], 'depth': p['depth'], 'sweep': p['sweep'],
             'thickness': t, 'bottom': round(low, 4), 'contact': [bg.contact('up', pts)], 'anchors': anchors, 'embed': embed}
    return {'lip_main': main, 'lip_detail': detail}, mount


if __name__ == '__main__':
    bg.run_generator('lip', DEFAULTS, validate, build,
                     {'lip_main': ((0.03, 0.03, 0.035), 0.25, 0.22), 'lip_detail': ((0.015, 0.015, 0.017), 0.3, 0.22)},
                     "centre of the blade's top face on the bumper's lower front edge",
                     'Generate an original front lip', styles=STYLES)
