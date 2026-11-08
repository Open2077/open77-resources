"""Procedural ORIGINAL rear wing for Open77 (Blender 4.5, background).

    blender --background --factory-startup --python make_spoiler.py -- --part wing.json --out <dir>

Vehicle frame (engine/Blender, metres): X = right, Y = forward, Z = up. The wing
spans X, its chord runs along Y with the leading edge toward +Y, and the pivot
(0, 0, 0) is the centre of the two mounting feet on the trunk surface. A resource
attaches it to the vehicle root with a per-model offset (trunk height and Y).

Parameters (metres / degrees), all optional:
  style street (default) | gt | duck | rally | lip | low | dual | drift | bat | roof; the
        other styles are in body_wings.py and change the defaults below (see
        body_wings.STYLE_DEFAULTS, which also lists each style's own parameters)
  span 1.30  chord 0.26  height 0.20 (feet to wing underside)  aoa 7  camber 0.05
  thickness 0.11 (t/c)  stand_spacing 0.80  stand_chord 0.11  endplate_height 0.13
  seed 1  sections [18]  airfoil points per side, one entry per LOD (max 3). One LOD
  by default: every custom mesh proven visible in game has one.
Slots: wing_main (wing and end plates) and wing_detail (stands and feet).
The part.json `mount` record gives the feet positions (x, y), the footprint along Y, the
rear-most Y (teY) relative to the pivot, the contact points and the embed boxes:
body_fit.py places the wing from them.
"""
import math
import random
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import vk_common as vk  # noqa: E402
import body_wings  # noqa: E402

STYLES = ('street', 'gt', 'duck', 'rally', 'lip', 'low', 'dual', 'drift', 'bat', 'roof')
SURFACE_STYLES = ('duck', 'lip', 'roof')   # no stands: they rest on the deck or roof


def params_of(part):
    p = dict(span=1.30, chord=0.26, height=0.20, aoa=7.0, camber=0.05, thickness=0.11, stand_spacing=0.80,
             stand_chord=0.11, endplate_height=0.13, seed=1, sections=[18])
    style = part.get('params', {}).get('style', 'street')
    if style not in STYLES:
        raise SystemExit(f'style must be one of {STYLES}')
    p.update(body_wings.STYLE_DEFAULTS.get(style, {}))
    p.update(part.get('params', {}))
    p['style'] = style
    if style in ('duck', 'lip'):
        if not (0.6 <= p['span'] <= 2.2) or not (0.06 <= p['chord'] <= 0.4) or not (0.02 <= p['height'] <= 0.15):
            raise SystemExit(f'{style}: span 0.6..2.2, chord 0.06..0.4, height 0.02..0.15 m')
        if not (0.0 <= p['crown'] <= 0.12) or not (1.0 <= p['power'] <= 4.0):
            raise SystemExit(f'{style}: crown 0..0.12 m, power 1..4')
        return p
    if style == 'roof':
        if not (0.6 <= p['span'] <= 1.8) or not (0.12 <= p['chord'] <= 0.45) or not (0.03 <= p['base'] < p['chord'] / 2):
            raise SystemExit('roof: span 0.6..1.8, chord 0.12..0.45, base 0.03..chord/2 m')
        if not (0.0 <= p['droop'] <= 35) or not (0.0 <= p['crown'] <= 0.12):
            raise SystemExit('roof: droop 0..35 degrees, crown 0..0.12 m')
        return p
    if not (0.6 <= p['span'] <= 2.2):
        raise SystemExit('span must be 0.6..2.2 m')
    if not (0.1 <= p['chord'] <= 0.5):
        raise SystemExit('chord must be 0.1..0.5 m')
    if not (0.05 <= p['height'] <= 0.6):
        raise SystemExit('height must be 0.05..0.6 m')
    if p['stand_spacing'] >= p['span'] - 0.1:
        raise SystemExit('stand_spacing must be narrower than the span')
    if not (1 <= len(p['sections']) <= 3):
        raise SystemExit('sections: one entry per LOD, 1..3 LODs')
    return p


def airfoil(n, camber, thickness, p_pos=0.4):
    """NACA-4-style section, cosine spaced, as a closed loop (TE -> upper -> LE -> lower)."""
    xs = [0.5 * (1 - math.cos(math.pi * i / n)) for i in range(n + 1)]

    def half(x):
        yt = 5 * thickness * (0.2969 * math.sqrt(x) - 0.1260 * x - 0.3516 * x ** 2 + 0.2843 * x ** 3 - 0.1036 * x ** 4)
        if x < p_pos:
            yc, dy = camber / p_pos ** 2 * (2 * p_pos * x - x * x), 2 * camber / p_pos ** 2 * (p_pos - x)
        else:
            yc = camber / (1 - p_pos) ** 2 * ((1 - 2 * p_pos) + 2 * p_pos * x - x * x)
            dy = 2 * camber / (1 - p_pos) ** 2 * (p_pos - x)
        th = math.atan(dy)
        return (x - yt * math.sin(th), yc + yt * math.cos(th)), (x + yt * math.sin(th), yc - yt * math.cos(th))

    upper = [half(x)[0] for x in xs]
    lower = [half(x)[1] for x in xs]
    loop = list(reversed(upper))[:-1] + lower[:-1]   # TE..LE along the upper side, LE..TE lower
    return loop


def wing_points(p, n):
    """Airfoil in the Y/Z plane. Inverted (downforce), LE forward (+Y), TE raised by the AoA."""
    c, aoa = p['chord'], math.radians(p['aoa'])
    y_le = c * 0.42
    z0 = p['height'] + 0.01
    pts = []
    for xc, yc in airfoil(n, p['camber'], p['thickness']):
        y = y_le - xc * c
        z = -yc * c
        # rotate about the leading edge so the trailing edge rises
        dy, dz = y - y_le, z
        pts.append((y_le + dy * math.cos(aoa) + dz * math.sin(aoa), z0 - dy * math.sin(aoa) + dz * math.cos(aoa)))
    return pts


def prism(points_yz, x0, x1):
    """Extrude a closed Y/Z polygon along X."""
    return vk.MeshBuilder().sweep([[(x0, y, z) for y, z in points_yz], [(x1, y, z) for y, z in points_yz]],
                                  closed_section=True, cap=True)


def build_lod(exp, p, lod, n, mats, seed):
    rng = random.Random(seed)
    half = p['span'] / 2
    pts = wing_points(p, n)
    ys = [y for y, _ in pts]; zs = [z for _, z in pts]
    # Wing: three sections, a slight dihedral sweep at the tips is the seed's variation.
    tip_lift = 0.006 * rng.uniform(0.5, 1.5)
    sections = []
    for x in (-half + 0.004, 0.0, half - 0.004):
        lift = tip_lift * abs(x) / half
        sections.append([(x, y, z + lift) for y, z in pts])
    # One sweep through three sections: the centre ring is real geometry (a later decal
    # or badge can sit on it) without an internal cap face.
    wing = vk.MeshBuilder().sweep(sections, closed_section=True, cap=True)
    # End plates: a swept-back trapezoid around the airfoil, 8 mm thick.
    eh = p['endplate_height']
    y_front, y_back = max(ys) + 0.025, min(ys) - 0.045
    z_lo, z_hi = min(zs) - eh * 0.35, max(zs) + eh * 0.65
    plate = [(y_front, z_lo + 0.02), (y_front - 0.02, z_hi - 0.01), (y_back + 0.03, z_hi + 0.015), (y_back, z_lo)]
    main = vk.MeshBuilder()
    main.extend(wing)
    for side in (-1, 1):
        x_in = side * (half - 0.004)
        x_out = side * (half + 0.006)
        main.extend(prism(plate, min(x_in, x_out), max(x_in, x_out)))
    exp.add(main, lod, 'wing_main', mats['wing_main'])

    # Stands: tapered blades leaning back, from the feet (z=0) into the wing underside.
    det = vk.MeshBuilder()
    sc = p['stand_chord']
    top = min(zs) + 0.02
    for side in (-1, 1):
        x = side * p['stand_spacing'] / 2
        t = 0.009
        rings = []
        steps = 4 if lod == 1 else 1
        for i in range(steps + 1):
            s = i / steps
            z = top * s
            lean = -0.05 * s
            w = sc * (1 - 0.35 * s)
            rings.append([(x - t, lean + w * 0.5, z), (x + t, lean + w * 0.5, z),
                          (x + t, lean - w * 0.5, z), (x - t, lean - w * 0.5, z)])
        det.sweep(rings, closed_section=True, cap=True)
        if lod == 1:
            foot = [(0.07, 0.0), (0.07, 0.008), (-0.07, 0.008), (-0.07, 0.0)]
            det.extend(prism([(y, z) for y, z in foot], x - 0.03, x + 0.03))
    exp.add(det, lod, 'wing_detail', mats['wing_detail'])


def main():
    parser = vk.base_parser('Generate an original rear wing part')
    args = vk.script_args(parser)
    part = vk.load_part(args.part)
    if part['kind'] != 'spoiler':
        raise SystemExit(f"make_spoiler.py builds kind 'spoiler', got {part['kind']!r}")
    p = params_of(part)
    vk.clear_scene()
    addon = vk.enable_cp77_addon()
    mats = {
        'wing_main': vk.preview_material('wing_main', (0.03, 0.03, 0.035), 0.2, 0.25),
        'wing_detail': vk.preview_material('wing_detail', (0.02, 0.02, 0.02), 0.3, 0.3),
    }
    exp = vk.PartExporter(part, args.out)
    mount = None
    for lod, n in enumerate(p['sections'], start=1):
        if p['style'] == 'street':
            build_lod(exp, p, lod, int(n), mats, int(p['seed']))
            ys = [y for y, _ in wing_points(p, int(n))]
            mount = mount or body_wings.pedestal_mount([[-p['stand_spacing'] / 2, 0.0], [p['stand_spacing'] / 2, 0.0]],
                                                       [-0.07, 0.07], min(ys) - 0.045, 0.03)
            continue
        if p['style'] in ('duck', 'lip'):
            main_b, detail_b, m = body_wings.build_duck(p, int(n))
        elif p['style'] == 'roof':
            main_b, detail_b, m = body_wings.build_roof(p, int(n))
        else:
            main_b, detail_b, m = getattr(body_wings, f"build_{p['style']}")(p, int(n), wing_points)
        exp.add(main_b, lod, 'wing_main', mats['wing_main'])
        exp.add(detail_b, lod, 'wing_detail', mats['wing_detail'])
        mount = mount or m
    pivot = ('bottom of the trailing edge on the deck or roof edge' if p['style'] in ('duck', 'lip')
             else "front edge of the bonded base, on the roof" if p['style'] == 'roof'
             else 'centre of the feet on the trunk surface')
    exp.export(args.exporter, addon, not args.no_blend, {
        'mount': dict({'frame': 'vehicle Base slot or root', 'pivot': pivot, 'style': p['style'],
                       'span': p['span'], 'height': p['height']}, **mount),
        'addon': addon,
    })


if __name__ == '__main__':
    main()
