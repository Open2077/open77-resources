"""Rear wing styles for make_spoiler.py beyond the original street wing (ORIGINAL geometry).

  gt     GT swan-neck wing: wide high plane hung from two neck blades that rise in front
         of the leading edge and hook onto the upper surface; tall end plates, gurney flap.
  duck   ducktail lip: no stands, a wedge sitting on the deck whose top sweeps up into a
         kicked trailing edge, height tapering toward the tips; also a roof-edge spoiler.
  rally  tall rally wing: high flat plane on two straight upright blades, tall raked end
         plates, gurney flap.
  lip    trunk lip spoiler: a slim concave flick on the deck's trailing edge (the duck's
         build with a smaller, concave section).
  low    bridge spoiler: a low plane carried at its tips by two pillar end plates that
         stand on the deck; no centre stands.
  dual   dual-element wing: main plane plus a steeper flap above and behind its trailing
         edge, large curved end plates, two straight stands.
  drift  time-attack wing: wide high plane on two struts canted outward, big square end
         plates with a cut-away front foot, gurney flap.
  bat    batwing: one curved plane whose tips sweep up into integrated fins (no separate
         end plates), on two stands.
  roof   roof spoiler: a visor bonded to the last few centimetres of the roof that runs
         back over the rear window or hatch, side fences under its tips.

Pivot (0, 0, 0): on the mounting surface, centre of the feet for the pedestal styles (gt,
rally, low, dual, drift, bat, street), the bottom of the trailing edge for duck and lip
(they extend forward, +Y, from there), and the front edge of the bonded base for roof (it
extends rearward, -Y, from there).
Slots: wing_main (plane, flap, end plates, duck body, visor) and wing_detail (stands, feet,
gurney, fences).

`crown` (duck, lip, roof): the span is bent down toward the tips by that many metres
(z -= crown * (x / half)^2) so it lies on a crowned deck or roof; the fit scales z to match
each car. Every builder returns the mount record body_fit.py places from: `feet`,
`footprintY`, `teY`, plus `contact` (points of the part frame that must touch the body,
with the direction they rest in) and `embed` (part-frame boxes allowed inside the body:
feet, the bonded base), which the fit audit uses.
"""
import math

import vk_common as vk
import body_geom as bg

STYLE_DEFAULTS = {
    'gt': dict(span=1.55, chord=0.32, height=0.30, aoa=9.0, camber=0.06, thickness=0.12, stand_spacing=0.84,
               stand_chord=0.06, endplate_height=0.24),
    'rally': dict(span=1.25, chord=0.24, height=0.42, aoa=6.0, camber=0.05, thickness=0.11, stand_spacing=0.76,
                  stand_chord=0.09, endplate_height=0.26),
    'duck': dict(span=1.30, chord=0.22, height=0.075, sweep=0.03, tip_taper=0.6, thickness=0.004, power=1.7, crown=0.0,
                 kick=0.008),
    'lip': dict(span=1.24, chord=0.12, height=0.042, sweep=0.012, tip_taper=0.55, thickness=0.003, power=2.6, crown=0.0,
                kick=0.006),
    'low': dict(span=1.34, chord=0.20, height=0.085, aoa=4.0, camber=0.04, thickness=0.09, endplate_height=0.11),
    'dual': dict(span=1.48, chord=0.26, height=0.26, aoa=7.0, camber=0.06, thickness=0.11, stand_spacing=0.80,
                 stand_chord=0.10, endplate_height=0.22, flap_ratio=0.52, flap_aoa=24.0),
    'drift': dict(span=1.62, chord=0.30, height=0.40, aoa=8.0, camber=0.06, thickness=0.11, stand_spacing=0.66,
                  stand_chord=0.09, endplate_height=0.34, cant=0.12),
    'bat': dict(span=1.36, chord=0.24, height=0.20, aoa=6.0, camber=0.05, thickness=0.10, stand_spacing=0.70,
                stand_chord=0.09, tip_radius=0.10, tip_rise=0.17),
    'roof': dict(span=1.10, chord=0.26, base=0.07, droop=7.0, thickness=0.014, crown=0.03, fence=0.03, kick=0.012),
}


def _shift(points, dy, dz=0.0):
    return [(y + dy, z + dz) for y, z in points]


def _surface_z(points, y, upper=True):
    """Height of the airfoil loop at y (upper or lower side), by linear interpolation."""
    best = None
    n = len(points)
    for i in range(n):
        (y0, z0), (y1, z1) = points[i], points[(i + 1) % n]
        if (y0 - y) * (y1 - y) <= 0 and y0 != y1:
            z = z0 + (z1 - z0) * (y - y0) / (y1 - y0)
            if best is None or (upper and z > best) or (not upper and z < best):
                best = z
    return best


def _plane(pts, half, sections=5):
    rings = []
    for i in range(sections):
        x = -half + 2 * half * i / (sections - 1)
        rings.append([(x, y, z) for y, z in pts])
    return vk.MeshBuilder().sweep(rings, closed_section=True, cap=True)


def _gurney(pts, half, height):
    """A thin vertical strip standing on the upper trailing edge."""
    te = min(pts, key=lambda p: p[0])
    y, z = te
    outline = [(y + 0.004, z - 0.002), (y + 0.004, z + height), (y - 0.002, z + height), (y - 0.002, z - 0.002)]
    return bg.prism_yz(outline, -half + 0.006, half - 0.006)


def _end_plates(outline, half, t=0.008):
    out = vk.MeshBuilder()
    for side in (-1, 1):
        x_in, x_out = side * (half - 0.004), side * (half - 0.004 + t)
        out.extend(bg.prism_yz(outline, min(x_in, x_out), max(x_in, x_out)))
    return out


def pedestal_mount(feet, footprint, te_y, half_x):
    """Mount record of a wing standing on foot pads: the pads' undersides touch the deck,
    and the pads plus the lowest 8 cm of each stand may enter a sloped deck (body_fit's
    MAX_SINK)."""
    pts, embed = [], []
    for fx, fy in feet:
        for dx in (-half_x * 0.8, 0.0, half_x * 0.8):
            for f in (0.08, 0.5, 0.92):
                pts.append([round(fx + dx, 5), round(fy + footprint[0] + f * (footprint[1] - footprint[0]), 5), 0.0])
        embed.append([[fx - half_x - 0.03, fy + footprint[0] - 0.03, -0.2], [fx + half_x + 0.03, fy + footprint[1] + 0.03, 0.08]])
    return {'feet': [[round(a, 5), round(b, 5)] for a, b in feet], 'footprintY': list(footprint), 'teY': round(te_y, 4),
            'contact': [{'dir': 'down', 'pts': pts}], 'embed': embed}


def _round2d(points, r, steps=3):
    """A closed Y/Z outline with its corners filleted."""
    out = bg.rounded_path([(a, b, 0.0) for a, b in points], r, steps=steps, closed=True)
    return [(a, b) for a, b, _ in out[:-1]]


def _stand(x, top, chord, t, lean=-0.02, taper=0.30, rings=3, y0=0.0, cant=0.0):
    """A tapered blade from the foot (z = 0) up into the plane's underside at `top`; `cant`
    moves its top outward (x) for canted struts."""
    out = []
    for i in range(rings):
        s = i / (rings - 1)
        z = top * s
        w = chord * (1 - taper * s)
        xx = x + cant * s
        ly = y0 + lean * s
        out.append([(xx - t, ly + w * 0.55, z), (xx + t, ly + w * 0.55, z), (xx + t, ly - w * 0.45, z), (xx - t, ly - w * 0.45, z)])
    return vk.MeshBuilder().sweep(out, closed_section=True, cap=True)


def _foot(x, length, width=0.06, y=0.0):
    pad = bg.rounded_rect(width, length, 0.014)
    return bg.prism_xy([(x + fx, y + fy) for fx, fy in pad], 0.0, 0.008)


def build_gt(p, n, wing_points):
    c = p['chord']
    raw = wing_points(dict(p), n)
    y_le = max(y for y, _ in raw)
    pts = _shift(raw, -0.03 - y_le)              # leading edge 3 cm behind the feet
    half = p['span'] / 2
    ys = [y for y, _ in pts]
    zs = [z for _, z in pts]
    main = vk.MeshBuilder()
    main.extend(_plane(pts, half - 0.004))
    eh = p['endplate_height']
    y_front, y_back = max(ys) + 0.02, min(ys) - 0.07
    z_lo, z_hi = min(zs) - eh * 0.45, max(zs) + eh * 0.55
    plate = [(y_front, z_lo + 0.03), (y_front - 0.03, z_hi), (y_back + 0.05, z_hi + 0.02), (y_back, z_hi - 0.04),
             (y_back, z_lo), (y_front - 0.06, z_lo - 0.01)]
    main.extend(_end_plates(plate, half))

    detail = vk.MeshBuilder()
    detail.extend(_gurney(pts, half, 0.016))
    # Swan necks: blades rising in front of the leading edge, hooking onto the top surface.
    y_att = min(ys) + 0.55 * (max(ys) - min(ys))
    z_att = _surface_z(pts, y_att, upper=True)
    z_le_top = _surface_z(pts, max(ys) - 0.02, upper=True)
    centre = bg.bezier2((0.0, 0.0), (0.03, z_le_top * 0.75), (0.0, z_le_top + 0.045), 6)[:-1] + \
        bg.bezier2((0.0, z_le_top + 0.045), (y_att + 0.02, z_le_top + 0.09), (y_att, z_att + 0.004), 6)
    outline = bg.ribbon_outline(centre, lambda u: 0.075 * (1 - u) + 0.032 * u)
    t = 0.0065
    for side in (-1, 1):
        x = side * p['stand_spacing'] / 2
        detail.extend(bg.prism_yz(outline, x - t, x + t))
        foot = bg.rounded_rect(0.07, 0.13, 0.015)
        detail.extend(bg.prism_xy([(x + fx, fy) for fx, fy in foot], 0.0, 0.008))
    feet = [[side * p['stand_spacing'] / 2, 0.0] for side in (-1, 1)]
    return main, detail, pedestal_mount(feet, [-0.065, 0.065], y_back, 0.035)


def build_rally(p, n, wing_points):
    raw = wing_points(dict(p), n)
    y_le = max(y for y, _ in raw)
    pts = _shift(raw, p['chord'] * 0.45 - y_le)   # uprights at 45 % of the chord
    half = p['span'] / 2
    ys = [y for y, _ in pts]
    zs = [z for _, z in pts]
    main = vk.MeshBuilder()
    main.extend(_plane(pts, half - 0.004))
    eh = p['endplate_height']
    y_front, y_back = max(ys) + 0.03, min(ys) - 0.04
    z_lo, z_hi = min(zs) - eh * 0.30, max(zs) + eh * 0.70
    plate = [(y_front, z_lo), (y_front + 0.01, z_hi - 0.08), (y_front - 0.06, z_hi), (y_back + 0.02, z_hi + 0.01),
             (y_back, z_hi - 0.02), (y_back, z_lo + 0.02)]
    main.extend(_end_plates(plate, half, 0.010))

    detail = vk.MeshBuilder()
    detail.extend(_gurney(pts, half, 0.020))
    sc = p['stand_chord']
    top = _surface_z(pts, 0.0, upper=False) + 0.01
    for side in (-1, 1):
        x = side * p['stand_spacing'] / 2
        t = 0.008
        rings = []
        for i in range(3):
            s = i / 2
            z = top * s
            w = sc * (1 - 0.30 * s)
            lean = -0.015 * s
            rings.append([(x - t, lean + w * 0.55, z), (x + t, lean + w * 0.55, z), (x + t, lean - w * 0.45, z), (x - t, lean - w * 0.45, z)])
        detail.sweep(rings, closed_section=True, cap=True)
        foot = bg.rounded_rect(0.06, 0.15, 0.015)
        detail.extend(bg.prism_xy([(x + fx, fy) for fx, fy in foot], 0.0, 0.008))
    feet = [[side * p['stand_spacing'] / 2, 0.0] for side in (-1, 1)]
    return main, detail, pedestal_mount(feet, [-0.075, 0.075], y_back, 0.03)


def build_duck(p, n):
    half = p['span'] / 2
    c, h = p['chord'], p['height']
    steps = max(6, n // 2)
    sections = []
    gurney_rings = []
    contact = []
    count = 13
    for i in range(count):
        u = -1 + 2 * i / (count - 1)
        x = u * half
        k = 1 - (1 - p['tip_taper']) * u * u            # height taper toward the tips
        dy = p['sweep'] * u * u                         # trailing edge pulled forward at the tips
        hh = h * k
        cc = c * (1 - 0.25 * u * u)
        kick = p.get('kick', 0.008)
        dz = -p.get('crown', 0.0) * u * u               # span bent down toward the tips
        loop = [(dy, 0.0), (dy + cc, 0.0)]
        for s in range(steps + 1):                      # top: front (feathered) -> kicked tail
            v = s / steps
            y = dy + cc * (1 - v)
            z = p['thickness'] + (hh - p['thickness']) * v ** p.get('power', 1.7)
            loop.append((y, z))
        loop.append((dy - kick, hh + 0.002))             # small rearward kick at the lip
        sections.append([(x, y, z + dz) for y, z in loop])
        g = 0.011 * kick / 0.008
        gurney_rings.append([(x, dy - kick, hh + 0.002 + dz), (x, dy + 0.004, hh + 0.002 + dz),
                             (x, dy + 0.004, hh + g + dz), (x, dy - kick + 0.002, hh + g + dz)])
        for f in (0.04, 0.5, 0.96):
            contact.append([round(x * 0.97, 5), round(dy + f * cc, 5), round(dz, 5)])
    main = vk.MeshBuilder().sweep(sections, closed_section=True, cap=True)
    detail = vk.MeshBuilder().sweep(gurney_rings, closed_section=True, cap=True)
    return main, detail, {'feet': [[0.0, 0.0]], 'footprintY': [0.0, c], 'teY': -round(p.get('kick', 0.008), 4),
                          'contact': [{'dir': 'down', 'pts': contact}],
                          'embed': [[[-half - 0.01, -0.02, -0.2], [half + 0.01, c + 0.02, 0.004]]]}


def build_low(p, n, wing_points):
    """Bridge spoiler: the plane runs between two pillar end plates that are its only supports."""
    c = p['chord']
    raw = wing_points(dict(p), n)
    y_le = max(y for y, _ in raw)
    pts = _shift(raw, c * 0.5 - y_le)
    half = p['span'] / 2
    ys = [y for y, _ in pts]
    zs = [z for _, z in pts]
    main = vk.MeshBuilder()
    main.extend(_plane(pts, half - 0.004))
    t = 0.014
    eh = p['endplate_height']
    top = max(zs) + eh * 0.25
    pillar = _round2d([(0.065, 0.0), (max(ys) + 0.012, min(zs) - 0.004), (max(ys) + 0.004, top),
                       (min(ys) - 0.006, top + 0.012), (min(ys) - 0.028, max(zs) - 0.004), (-0.065, 0.0)], 0.012)
    main.extend(_end_plates(pillar, half, t))
    detail = vk.MeshBuilder()
    detail.extend(_gurney(pts, half - 0.004, 0.012))
    feet = []
    for side in (-1, 1):
        x = side * (half - 0.004 + t / 2)
        detail.extend(_foot(x, 0.14, 0.03))
        feet.append([x, 0.0])
    return main, detail, pedestal_mount(feet, [-0.07, 0.07], min(ys) - 0.028, 0.012)


def build_dual(p, n, wing_points):
    """Dual-element wing: main plane, a steeper flap above and behind it, big end plates."""
    c = p['chord']
    raw = wing_points(dict(p), n)
    y_le = max(y for y, _ in raw)
    main_pts = _shift(raw, c * 0.40 - y_le)
    te = min(main_pts, key=lambda q: q[0])
    fc = c * p['flap_ratio']
    fraw = wing_points(dict(p, chord=fc, aoa=p['aoa'] + p['flap_aoa'], height=0.0), n)
    fle = max(fraw, key=lambda q: q[0])
    flap_pts = _shift(fraw, te[0] + 0.16 * fc - fle[0], te[1] + 0.026 - fle[1])
    half = p['span'] / 2
    ys = [y for y, _ in main_pts] + [y for y, _ in flap_pts]
    zs_main = [z for _, z in main_pts]
    zs_flap = [z for _, z in flap_pts]
    main = vk.MeshBuilder()
    main.extend(_plane(main_pts, half - 0.004, 5))
    main.extend(_plane(flap_pts, half - 0.004, 3))
    eh = p['endplate_height']
    y_front, y_back = max(ys) + 0.03, min(ys) - 0.035
    z_lo = min(zs_main) - eh * 0.32
    z_hi = max(zs_flap) + 0.045
    plate = _round2d([(y_front, z_lo + 0.03), (y_front, max(zs_main) + 0.03), (y_front - 0.10, z_hi - 0.02),
                      (y_back + 0.03, z_hi), (y_back, z_hi - 0.03), (y_back, z_lo + 0.05), (y_back + 0.07, z_lo)], 0.022)
    main.extend(_end_plates(plate, half, 0.009))
    detail = vk.MeshBuilder()
    top = _surface_z(main_pts, 0.0, upper=False) + 0.01
    feet = []
    for side in (-1, 1):
        x = side * p['stand_spacing'] / 2
        detail.extend(_stand(x, top, p['stand_chord'], 0.0085, lean=-0.03, taper=0.28))
        detail.extend(_foot(x, 0.14))
        feet.append([x, 0.0])
    return main, detail, pedestal_mount(feet, [-0.07, 0.07], y_back, 0.03)


def build_drift(p, n, wing_points):
    """Time-attack wing: high wide plane on two outward-canted struts, big square end plates."""
    c = p['chord']
    raw = wing_points(dict(p), n)
    y_le = max(y for y, _ in raw)
    pts = _shift(raw, c * 0.45 - y_le)
    half = p['span'] / 2
    ys = [y for y, _ in pts]
    zs = [z for _, z in pts]
    main = vk.MeshBuilder()
    main.extend(_plane(pts, half - 0.004, 5))
    eh = p['endplate_height']
    y_front, y_back = max(ys) + 0.05, min(ys) - 0.10
    z_lo, z_hi = min(zs) - eh * 0.55, max(zs) + eh * 0.42
    plate = _round2d([(y_front, z_hi - 0.03), (y_back + 0.03, z_hi), (y_back, z_hi - 0.035), (y_back, z_lo + 0.03),
                      (y_back + 0.05, z_lo), (y_front - 0.13, z_lo), (y_front, z_lo + 0.11)], 0.02)
    main.extend(_end_plates(plate, half, 0.010))
    detail = vk.MeshBuilder()
    detail.extend(_gurney(pts, half - 0.004, 0.022))
    top = _surface_z(pts, 0.0, upper=False) + 0.01
    feet = []
    for side in (-1, 1):
        x = side * p['stand_spacing'] / 2
        detail.extend(_stand(x, top, p['stand_chord'], 0.009, lean=-0.02, taper=0.25, rings=4, cant=side * p['cant']))
        detail.extend(_foot(x, 0.15))
        feet.append([x, 0.0])
    return main, detail, pedestal_mount(feet, [-0.075, 0.075], y_back, 0.03)


def build_bat(p, n, wing_points):
    """Batwing: one plane swept along a U-shaped span line, so its tips turn up into fins."""
    c = p['chord']
    sec = wing_points(dict(p, height=0.0), max(10, n - 4))
    y_le = max(y for y, _ in sec)
    zmid = (max(z for _, z in sec) + min(z for _, z in sec)) / 2
    sec = [(y + c * 0.45 - y_le, z - zmid) for y, z in sec]
    thick = max(z for _, z in sec) - min(z for _, z in sec)
    half, R, rise = p['span'] / 2, p['tip_radius'], p['tip_rise']
    h = p['height'] + thick / 2
    right = [(0.0, h, 0.0), (half - R, h, 0.0)]
    for k in range(1, 6):
        a = -math.pi / 2 + (math.pi / 2) * k / 5
        right.append((half - R + R * math.cos(a), h + R + R * math.sin(a), min(1.0, k / 5)))
    right.append((half, h + rise, 1.0))
    path = [(-x, z, f) for x, z, f in reversed(right[1:])] + right[:1] + right[1:]
    yc = sum(y for y, _ in sec) / len(sec)
    rings = []
    for i, (x, z, f) in enumerate(path):
        a, b = path[max(0, i - 1)], path[min(len(path) - 1, i + 1)]
        tx, tz = b[0] - a[0], b[1] - a[1]
        L = math.hypot(tx, tz) or 1.0
        nx, nz = -tz / L, tx / L
        k = 1 - 0.28 * f                                  # tips taper and sweep back
        sweep = -0.035 * f
        rings.append([(x + nx * zl * k, yc + (y - yc) * k + sweep, z + nz * zl * k) for y, zl in sec])
    main = vk.MeshBuilder().sweep(rings, closed_section=True, cap=True)
    detail = vk.MeshBuilder()
    flat = [(y, zl + h) for y, zl in sec]
    top = _surface_z(flat, 0.0, upper=False) + 0.01
    feet = []
    for side in (-1, 1):
        x = side * p['stand_spacing'] / 2
        detail.extend(_stand(x, top, p['stand_chord'], 0.0085, lean=-0.025, taper=0.30))
        detail.extend(_foot(x, 0.14))
        feet.append([x, 0.0])
    te = min(y for y, _ in sec) - 0.035
    return main, detail, pedestal_mount(feet, [-0.07, 0.07], te, 0.03)


def build_roof(p, n):
    """Roof spoiler: a visor whose base is bonded to the roof's last `base` metres and whose
    blade runs back over the glass, drooping by `droop` degrees, with fences under its tips."""
    half, c, base = p['span'] / 2, p['chord'], p['base']
    droop, t, crown = math.radians(p['droop']), p['thickness'], p['crown']
    steps = max(6, n // 2)
    count = 15

    def under(yy):
        d = -yy - base
        return 0.0 if d <= 0 else -d * math.tan(droop)

    sections, contact, tips = [], [], {}
    for i in range(count):
        u = -1 + 2 * i / (count - 1)
        x = u * half
        cc = c * (1 - 0.16 * u * u)
        dz = -crown * u * u
        bottom = [(0.0, 0.0), (-base, 0.0)]
        for s in range(1, steps + 1):
            yy = -base - (cc - base) * s / steps
            bottom.append((yy, under(yy)))
        te_y = -cc
        top = []
        for s in range(1, steps + 2):
            v = s / (steps + 1)
            yy = te_y * (1 - v)                           # TE -> front
            th = t if -yy > 0.05 else 0.004 + (t - 0.004) * (-yy / 0.05)
            if -yy > cc - 0.05:                           # thin out toward the trailing edge
                th = min(th, max(0.005, t * (cc + yy) / 0.05 + 0.004))
            top.append((yy, under(yy) + th))
        top = [(te_y - 0.004, under(te_y) + p['kick'])] + top[:-1]   # kicked trailing edge
        loop = bottom + top
        sections.append([(x, yy, zz + dz) for yy, zz in loop])
        tips[i] = cc
        for f in (0.1, 0.55, 0.95):
            contact.append([round(x * 0.97, 5), round(-base * f, 5), round(dz, 5)])
    main = vk.MeshBuilder().sweep(sections, closed_section=True, cap=True)
    detail = vk.MeshBuilder()
    cc = c * (1 - 0.16 * 0.965 ** 2)
    for side in (-1, 1):
        x = side * half * 0.965
        dz = -crown * 0.965 ** 2
        ya, yb = -base - 0.03, -cc + 0.03
        za, zb = under(ya) + dz, under(yb) + dz
        # Fence: flush with the underside at its front, deepest (`fence`) at its rear.
        fence = [(ya, za + 0.006), (ya - 0.03, za - p['fence'] * 0.15), (yb + 0.02, zb - p['fence']), (yb, zb + 0.006)]
        detail.extend(bg.prism_yz(fence, x - 0.004, x + 0.004))
    mount = {'feet': [[0.0, -base / 2]], 'footprintY': [-base, 0.0], 'teY': round(-c - 0.004, 4), 'base': base,
             'contact': [{'dir': 'down', 'pts': contact}],
             'embed': [[[-half - 0.01, -base - 0.005, -0.2], [half + 0.01, 0.01, 0.003]]]}
    return main, detail, mount
