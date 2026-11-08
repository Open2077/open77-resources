"""Procedural ORIGINAL vehicle rim for Open77 (Blender 4.5, background).

    blender --background --factory-startup --python make_rim.py -- --part rim.json --out <dir>

Orientation matches the vanilla vehicle wheel meshes (measured, see ../README.md and
../docs/rims.md): spin axis = X, pivot = wheel centre (Y = Z = 0), outboard face toward
-X. The right-hand wheel slots are the left frames turned 180 degrees about Z (rig
reference pose of all 13 dealer cars) and the stock right rims bind the SAME left mesh
with an identity transform, so one rim fits all four slots with no extra turn.

The tyre is NOT part of this mesh: the car keeps its own tyre, so the rim is scaled per
model so that `radius` meets the tyre bead (see specs/lightrp-rims-fit.json).

Two families of styles share this script.

Legacy styles (split | straight | turbine | mesh), unchanged since the E0.9 test rim:
  slots rim_main (lip, spokes, hub face) and rim_detail (barrel, centre cap, lug nuts).
  radius 0.2785   width 0.305   face_x -0.208   dish 0.045   spokes 5   seed 1
  spoke_width 0.05  spoke_taper 0.55  hub_radius 0.085  lugs 5  lug_circle 0.055

Catalogue styles, swept members (classic | lattice | dish | fork | blade | beadlock |
aero | tech) and window-disc faces (star | twin | yspoke | vortex | threepiece | wire |
turbofan | steelie | offroad | hex):
  slots rim_main (face: spokes or disc, hub, barrel), rim_lip (outboard lip ring and
  its step or beadlock ring; also the barrel of the steel and wire wheels) and
  rim_detail (centre cap, lug nuts, bolts, valve, accents, the turbofan backing disc).
  Each style has its own defaults (STYLE_DEFAULTS); any of them can be overridden:
  radius 0.28  width 0.30  face_x -0.208  dish  spokes  spoke_width  spoke_taper
  hub_radius  lugs  lug_circle  lip_depth  twist  seed
  and per style: count (wire spokes, turbofan blades), bolts (threepiece), pitch_deg
  (turbofan), hole_circle (steelie, offroad), split (yspoke), row_split, hex_inner,
  hex_outer, hex_turn_deg (hex).
  Nothing is modelled in front of face_x: the lip face is the outboard-most plane, so
  the mount table can put it flush with the stock rim face. The build fails otherwise.

Both families: segments [72] (legacy) / [64] (catalogue) radial segments per LOD, one
LOD per entry, max 3. One LOD by default: every custom mesh proven visible in game has
one.
"""
import math
import random
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import vk_common as vk  # noqa: E402

TAU = math.tau
LEGACY_STYLES = ('split', 'straight', 'turbine', 'mesh')
# Per-style defaults of the catalogue styles (metres, radians, counts). Original
# designs: each is described in ../docs/rims.md.
STYLE_DEFAULTS = {
    'classic':  dict(spokes=10, spoke_width=0.026, spoke_taper=0.72, dish=0.050, lugs=5, hub_radius=0.072),
    'lattice':  dict(spokes=10, spoke_width=0.015, spoke_taper=0.80, dish=0.042, lugs=5, hub_radius=0.068, twist=0.30),
    'dish':     dict(spokes=8, spoke_width=0.032, spoke_taper=0.78, dish=0.110, lugs=5, hub_radius=0.070, lip_depth=0.062),
    'fork':     dict(spokes=5, spoke_width=0.026, spoke_taper=0.75, dish=0.055, lugs=5, hub_radius=0.074),
    'blade':    dict(spokes=12, spoke_width=0.030, spoke_taper=0.70, dish=0.040, lugs=5, hub_radius=0.080, twist=0.62),
    'beadlock': dict(spokes=6, spoke_width=0.062, spoke_taper=0.92, dish=0.068, lugs=6, hub_radius=0.082, lip_depth=0.052),
    'aero':     dict(spokes=8, spoke_width=0.010, spoke_taper=1.00, dish=0.034, lugs=0, hub_radius=0.060),
    'tech':     dict(spokes=3, spoke_width=0.078, spoke_taper=0.62, dish=0.058, lugs=6, hub_radius=0.088, twist=0.42),
    # Window-disc faces (cast or stamped): spoke_width is the full width at the axis line,
    # spoke_taper the ratio at the lip (Y-spoke: arm width / trunk width).
    'star':     dict(spokes=5, spoke_width=0.064, spoke_taper=0.70, dish=0.064, lugs=5, hub_radius=0.078, lip_depth=0.040),
    'twin':     dict(spokes=6, spoke_width=0.027, spoke_taper=0.80, dish=0.060, lugs=5, hub_radius=0.076, lip_depth=0.042, twist=0.112),
    'yspoke':   dict(spokes=6, spoke_width=0.044, spoke_taper=0.52, dish=0.064, lugs=5, hub_radius=0.078, lip_depth=0.042),
    'vortex':   dict(spokes=7, spoke_width=0.026, spoke_taper=1.35, dish=0.060, lugs=5, hub_radius=0.076, lip_depth=0.040, twist=0.55),
    'threepiece': dict(spokes=10, spoke_width=0.022, spoke_taper=0.85, dish=0.096, lugs=5, hub_radius=0.068, lip_depth=0.075, bolts=30),
    # Wire: count spokes in two crossing sets, twist = angle each spoke crosses over.
    'wire':     dict(spokes=6, spoke_width=0.020, spoke_taper=1.0, dish=0.060, lugs=0, hub_radius=0.060, lip_depth=0.036, twist=0.75, count=64),
    # Turbofan: count blades, each sweeping twist radians, pitched pitch_deg.
    'turbofan': dict(spokes=6, spoke_width=0.020, spoke_taper=1.0, dish=0.040, lugs=0, hub_radius=0.074, lip_depth=0.040, twist=0.20, count=24, pitch_deg=52),
    # Steel wheels: spokes = vent holes, spoke_width = hole diameter on hole_circle.
    'steelie':  dict(spokes=8, spoke_width=0.040, spoke_taper=1.0, dish=0.040, lugs=5, hub_radius=0.075, lip_depth=0.030, hole_circle=0.165),
    'offroad':  dict(spokes=8, spoke_width=0.048, spoke_taper=1.0, dish=0.090, lugs=6, hub_radius=0.082, lip_depth=0.042, lug_circle=0.058, hole_circle=0.158),
    # Hex: spokes = hexes in the inner row (the outer row has 1.5 times as many).
    'hex':      dict(spokes=12, spoke_width=0.020, spoke_taper=1.0, dish=0.058, lugs=6, hub_radius=0.074, lip_depth=0.042, lug_circle=0.052,
                     row_split=0.166, hex_inner=0.0255, hex_outer=0.0245),
}
STYLES = LEGACY_STYLES + tuple(STYLE_DEFAULTS)
CATALOGUE_SLOTS = ('rim_main', 'rim_lip', 'rim_detail')


def params_of(part):
    style = part.get('params', {}).get('style', 'split')
    if style in STYLE_DEFAULTS:
        p = dict(radius=0.28, width=0.30, face_x=-0.208, seed=1, lip_depth=0.045, lug_circle=0.050,
                 twist=0.0, segments=[64])
        p.update(STYLE_DEFAULTS[style])
    else:
        p = dict(radius=0.2785, width=0.305, face_x=-0.208, dish=0.045, spokes=5, style='split', seed=1,
                 spoke_width=0.05, spoke_taper=0.55, hub_radius=0.085, lugs=5, lug_circle=0.055,
                 segments=[72])
    p.update(part.get('params', {}))
    if p['style'] not in STYLES:
        raise SystemExit(f"rim style must be one of {STYLES}, got {p['style']!r}")
    if not (0.15 <= p['radius'] <= 0.45):
        raise SystemExit(f"rim radius {p['radius']} m is outside 0.15..0.45: check the mounting table")
    if not (0.12 <= p['width'] <= 0.5):
        raise SystemExit(f"rim width {p['width']} m is outside 0.12..0.5")
    if not (3 <= int(p['spokes']) <= 12):
        raise SystemExit('spokes must be 3..12')
    if not (1 <= len(p['segments']) <= 3):
        raise SystemExit('segments: one entry per LOD, 1..3 LODs')
    if p['hub_radius'] >= p['radius'] - 0.08:
        raise SystemExit('hub_radius too large for this radius')
    for key, lo, hi in (('count', 8, 96), ('bolts', 8, 48)):
        if key in p and not (lo <= int(p[key]) <= hi):
            raise SystemExit(f'{key} must be {lo}..{hi}')
    return p


# ============================================================================ legacy styles
def spoke_beam(b, a0, a1, r0, r1, x0, x1, hw0, hw1, th0, th1, steps):
    """One spoke swept from the hub (r0, angle a0) to the lip (r1, angle a1).
    Concave: the front face eases from the recessed hub toward the lip."""
    sections = []
    for i in range(steps + 1):
        s = i / steps
        smooth = s * s * (3 - 2 * s)
        a = a0 + (a1 - a0) * smooth
        r = r0 + (r1 - r0) * s
        xf = x0 + (x1 - x0) * (1 - (1 - s) ** 1.6)
        hw = hw0 + (hw1 - hw0) * s
        th = th0 + (th1 - th0) * s
        ch = th * 0.3
        py, pz = r * math.cos(a), r * math.sin(a)
        ty, tz = -math.sin(a), math.cos(a)
        ring = []
        for dx, dt in ((0, -hw * 0.62), (0, hw * 0.62), (ch, hw), (th, hw * 0.8), (th, -hw * 0.8), (ch, -hw)):
            ring.append((xf + dx, py + ty * dt, pz + tz * dt))
        sections.append(ring)
    b.sweep(sections, closed_section=True, cap=True)


def build_lod(exp, p, lod, segments, mats, rng_state):
    rng = random.Random(rng_state)
    R, W, fx, dish = p['radius'], p['width'], p['face_x'], p['dish']
    r_in = R - 0.05
    xh = fx + dish
    hub_r = p['hub_radius']
    detail = lod == 1
    steps = 6 if detail else 2

    # Outboard lip ring (rim_main): rounded outer edge, bead seat drop behind it.
    lip = vk.MeshBuilder().lathe([
        (fx + 0.030, r_in + 0.004), (fx + 0.008, r_in + 0.004), (fx + 0.001, r_in + 0.010),
        (fx, R - 0.010), (fx + 0.003, R - 0.002), (fx + 0.010, R), (fx + 0.018, R - 0.005),
        (fx + 0.026, R - 0.020), (fx + 0.030, R - 0.022)], segments, closed=True)

    # Spokes (rim_main), deterministic per seed.
    n = int(p['spokes'])
    phase = rng.uniform(0, TAU / n) * 0.25
    twist = 0.42 * rng.uniform(0.85, 1.15)
    hw0 = p['spoke_width'] / 2
    hw1 = hw0 * p['spoke_taper']
    th0, th1 = 0.032 * rng.uniform(0.9, 1.1), 0.022
    r0, r1 = hub_r - 0.012, r_in + 0.008
    x0, x1 = xh + 0.001, fx + 0.010
    spokes = vk.MeshBuilder()
    for k in range(n):
        a = phase + k * TAU / n
        style = p['style']
        if style == 'straight':
            beams = [(a, a, 1.0)]
        elif style == 'turbine':
            beams = [(a, a + twist, 0.9)]
        elif style == 'mesh':
            beams = [(a, a + twist, 0.55), (a, a - twist, 0.55)]
        else:  # split: a Y-spoke opening toward the lip
            spread = (TAU / n) * 0.16
            beams = [(a - 0.02, a - spread, 0.6), (a + 0.02, a + spread, 0.6)]
        for b0, b1, wscale in beams:
            spoke_beam(spokes, b0, b1, r0, r1, x0, x1, hw0 * wscale, hw1 * wscale, th0, th1, steps)

    hub = vk.MeshBuilder().lathe([
        (xh - 0.002, 0.0), (xh - 0.002, hub_r * 0.6), (xh + 0.004, hub_r),
        (xh + 0.040, hub_r), (xh + 0.040, 0.0)], segments)
    main = vk.MeshBuilder()
    for part in (lip, spokes, hub):
        main.extend(part)
    exp.add(main, lod, 'rim_main', mats['rim_main'])

    # Barrel (rim_detail): seen through the spokes, carries the tyre bead seat.
    xa, xb = fx + 0.028, fx + W
    barrel = vk.MeshBuilder().lathe([
        (xa, r_in + 0.006), (xa, R - 0.024), (xb - 0.030, R - 0.024), (xb - 0.016, R - 0.006),
        (xb - 0.006, R - 0.003), (xb, R - 0.010), (xb, r_in + 0.004), (xb - 0.010, r_in),
        (xa + 0.020, r_in)], segments, closed=True)
    cap_r = 0.034 * rng.uniform(0.92, 1.08)
    cap = vk.MeshBuilder().lathe([
        (xh - 0.018, 0.0), (xh - 0.016, cap_r * 0.45), (xh - 0.010, cap_r * 0.85),
        (xh - 0.004, cap_r), (xh - 0.0005, cap_r), (xh - 0.0005, 0.0)], max(12, segments // 2))
    det = vk.MeshBuilder()
    det.extend(barrel)
    det.extend(cap)
    if detail and int(p['lugs']) > 0:
        lugs = int(p['lugs'])
        for k in range(lugs):
            a = phase + TAU / n / 2 + k * TAU / lugs
            center = (p['lug_circle'] * math.cos(a), p['lug_circle'] * math.sin(a))
            det.extend(vk.MeshBuilder().lathe([
                (xh - 0.014, 0.0), (xh - 0.014, 0.006), (xh - 0.011, 0.0095),
                (xh, 0.0095), (xh, 0.0)], 6, center=center))
    exp.add(det, lod, 'rim_detail', mats['rim_detail'])


# ============================================================================ catalogue styles
# Cross-sections of a swept member, (dx, dt) pairs: dx toward +X (inboard) from the front
# face, dt across the member, in units of (thickness, half width).
SECTIONS = {
    'round': ((0, -0.62), (0, 0.62), (0.3, 1.0), (1.0, 0.8), (1.0, -0.8), (0.3, -1.0)),
    'flat': ((0, -1.0), (0, 1.0), (1.0, 1.0), (1.0, -1.0)),
    'blade': ((0, -0.25), (0, 0.25), (0.15, 1.0), (1.0, 0.35), (1.0, -0.35), (0.15, -1.0)),
    'chamfer': ((0, -0.7), (0, 0.7), (0.25, 1.0), (1.0, 1.0), (1.0, -1.0), (0.25, -1.0)),
}


def member(b, a0, a1, r0, r1, x0, x1, hw0, hw1, th0, th1, steps, section='round', curve=1.6, ease=True):
    """A spoke-like member swept from (r0, angle a0, x0) to (r1, angle a1, x1).

    x eases with exponent `curve` (concave face when the hub sits deeper than the lip);
    the angle follows a smoothstep when `ease` (a swept blade) or a straight line."""
    shape = SECTIONS[section]
    sections = []
    for i in range(steps + 1):
        s = i / steps
        t = s * s * (3 - 2 * s) if ease else s
        a = a0 + (a1 - a0) * t
        r = r0 + (r1 - r0) * s
        xf = x0 + (x1 - x0) * (1 - (1 - s) ** curve)
        hw = hw0 + (hw1 - hw0) * s
        th = th0 + (th1 - th0) * s
        py, pz = r * math.cos(a), r * math.sin(a)
        ty, tz = -math.sin(a), math.cos(a)
        sections.append([(xf + dx * th, py + ty * dt * hw, pz + tz * dt * hw) for dx, dt in shape])
    b.sweep(sections, closed_section=True, cap=True)


def bolt_ring(b, count, radius, x_front, head_r, height, phase=0.0, sides=6):
    """Hex bolt heads (or lug nuts) on a circle, front face at x_front, seated behind it."""
    for k in range(count):
        a = phase + k * TAU / count
        center = (radius * math.cos(a), radius * math.sin(a))
        b.extend(vk.MeshBuilder().lathe([
            (x_front, 0.0), (x_front, head_r * 0.62), (x_front + height * 0.3, head_r),
            (x_front + height, head_r), (x_front + height, 0.0)], sides, center=center))


def ring(b, segments, x0, x1, r0, r1, bevel=0.0):
    """A closed annulus of rectangular section between radii r0 < r1 and x0 < x1."""
    e = min(bevel, (x1 - x0) / 3, (r1 - r0) / 3)
    if e <= 0:
        b.lathe([(x0, r0), (x0, r1), (x1, r1), (x1, r0)], segments, closed=True)
    else:
        b.lathe([(x0, r0 + e), (x0, r1 - e), (x0 + e, r1), (x1, r1), (x1, r0), (x0 + e, r0)], segments, closed=True)


def standard_lip(segments, fx, R, depth, recess=0.0):
    """The outboard lip: rounded outer edge at the face, inner wall down to R - depth.
    recess > 0 sinks the flat of the lip behind its outer bead (room for rivets)."""
    r_in = R - depth
    if recess > 0:
        return vk.MeshBuilder().lathe([
            (fx + 0.030, r_in), (fx + recess + 0.004, r_in), (fx + recess, r_in + 0.004),
            (fx + recess, R - 0.014), (fx, R - 0.009), (fx + 0.004, R - 0.001), (fx + 0.011, R),
            (fx + 0.020, R - 0.006), (fx + 0.030, R - 0.020)], segments, closed=True)
    return vk.MeshBuilder().lathe([
        (fx + 0.030, r_in), (fx + 0.006, r_in), (fx, r_in + 0.006), (fx, R - 0.008),
        (fx + 0.004, R - 0.001), (fx + 0.011, R), (fx + 0.020, R - 0.006), (fx + 0.030, R - 0.020)],
        segments, closed=True)


def barrel(segments, xa, xb, R, r_in):
    """The barrel behind the lip, inboard flange at xb (seen through the spokes)."""
    return vk.MeshBuilder().lathe([
        (xa, r_in + 0.004), (xa, R - 0.022), (xb - 0.024, R - 0.022), (xb - 0.010, R - 0.006),
        (xb, R - 0.008), (xb, r_in + 0.008), (xa + 0.020, r_in)], segments, closed=True)


def hub(segments, xh, hub_r, depth=0.040, sides=None):
    return vk.MeshBuilder().lathe([
        (xh, 0.0), (xh, hub_r * 0.65), (xh + 0.006, hub_r), (xh + depth, hub_r), (xh + depth, 0.0)],
        sides or segments)


def centre_cap(segments, xh, cap_r, dome=0.016, sides=None):
    """A domed cap whose front sits `dome` in front of the hub face."""
    return vk.MeshBuilder().lathe([
        (xh - dome, 0.0), (xh - dome * 0.9, cap_r * 0.45), (xh - dome * 0.55, cap_r * 0.85),
        (xh - dome * 0.2, cap_r), (xh + 0.002, cap_r), (xh + 0.002, 0.0)], sides or max(12, segments // 2))


# ---------------------------------------------------------------------------- window discs
# A cast or stamped face is a solid disc band pierced by windows (the gaps between spokes,
# vent holes, hexes). Each window lives in its own sector, a closed 2D region of the wheel
# plane (y, z) bounded by seams that run through the material (spoke centre lines, radial
# lines between holes). A sector is built as one closed solid from rays cast from a point
# inside its window: window edge (with a chamfer), front face loops, the seam boundary, the
# back face and the walls. Neighbouring sectors abut on their seams, which lie in solid
# material and on the same front surface, so no gap or seam is visible.
#
# The window shape is a signed distance function in the plane (negative inside the window),
# built from lines and circles with rounded intersections, so every window corner is a true
# fillet of a chosen radius.

def polar(r, a):
    return (r * math.cos(a), r * math.sin(a))


def arc(r, a0, a1, step=math.radians(1.5)):
    n = max(2, int(abs(a1 - a0) / step) + 1)
    return [polar(r, a0 + (a1 - a0) * i / (n - 1)) for i in range(n)]


def sd_line(p0, p1, inside):
    """Signed distance to the line p0-p1: negative on the side of `inside`."""
    (ax, ay), (bx, by) = p0, p1
    nx, ny = by - ay, -(bx - ax)
    length = math.hypot(nx, ny)
    nx, ny = nx / length, ny / length
    if (inside[0] - ax) * nx + (inside[1] - ay) * ny > 0:
        nx, ny = -nx, -ny
    return lambda y, z: (y - ax) * nx + (z - ay) * ny


def sd_outside_circle(r, c=(0.0, 0.0)):
    """Negative outside the circle (a window that must stay beyond radius r)."""
    return lambda y, z: r - math.hypot(y - c[0], z - c[1])


def sd_inside_circle(r, c=(0.0, 0.0)):
    return lambda y, z: math.hypot(y - c[0], z - c[1]) - r


def sd_round(fs, r):
    """Intersection of the constraint fields fs with every convex corner filleted at r
    (hg_sdf fOpIntersectionRound, folded)."""
    def f(y, z):
        d = fs[0](y, z)
        for g in fs[1:]:
            e = g(y, z)
            d = min(-r, max(d, e)) + math.hypot(max(r + d, 0.0), max(r + e, 0.0))
        return d
    return f


def _ray_poly(poly, c, d):
    """Smallest t > 0 where c + t*d crosses the closed 2D polyline poly."""
    best = None
    cx, cy = c
    dx, dy = d
    n = len(poly)
    for i in range(n):
        ax, ay = poly[i]
        bx, by = poly[(i + 1) % n]
        ex, ey = bx - ax, by - ay
        den = dx * ey - dy * ex
        if abs(den) < 1e-15:
            continue
        wx, wy = ax - cx, ay - cy
        t = (wx * ey - wy * ex) / den
        s = (wx * dy - wy * dx) / den
        if t > 1e-9 and -1e-9 <= s <= 1 + 1e-9 and (best is None or t < best):
            best = t
    return best


def _cross(f, c, d, lo, hi, level=0.0):
    """t in (lo, hi) where f(c + t*d) crosses `level` upward (bisection)."""
    for _ in range(46):
        mid = (lo + hi) / 2
        if f(c[0] + d[0] * mid, c[1] + d[1] * mid) < level:
            lo = mid
        else:
            hi = mid
    return (lo + hi) / 2


class Sector:
    """One window and the seam boundary around it (see window_disc)."""

    def __init__(self, boundary, corners, centre, sdf):
        self.boundary = boundary    # closed polyline [(y, z)], seams and arcs, densely sampled
        self.corners = corners      # boundary points that must be vertices (seam ends, bends)
        self.centre = centre        # inside the window; the window and boundary are star-shaped from it
        self.sdf = sdf              # window field, negative inside


def seam_sector(r_in, r_out, seam_a, seam_b, centre, sdf, step=math.radians(1.5)):
    """Sector between two seams that run from r_in (first point) to r_out (last point):
    seam_a on the clockwise side, seam_b on the counter-clockwise side."""
    a_in, b_in = math.atan2(seam_a[0][1], seam_a[0][0]), math.atan2(seam_b[0][1], seam_b[0][0])
    a_out, b_out = math.atan2(seam_a[-1][1], seam_a[-1][0]), math.atan2(seam_b[-1][1], seam_b[-1][0])
    while b_in < a_in:
        b_in += TAU
    while b_out < a_out:
        b_out += TAU
    boundary = arc(r_in, a_in, b_in, step) + list(seam_b[1:-1]) + arc(r_out, b_out, a_out, step) + list(reversed(seam_a[1:-1]))
    corners = [seam_a[0], seam_b[0], seam_b[-1], seam_a[-1]] + list(seam_a[1:-1]) + list(seam_b[1:-1])
    return Sector(boundary, corners, centre, sdf)


def radial_sectors(n, phase, r_in, r_out, window, centre_r):
    """n identical sectors between radial seams at phase + k*TAU/n; window(k, a_mid) gives the
    window field of sector k centred on angle a_mid."""
    out = []
    for k in range(n):
        a0 = phase + k * TAU / n
        a1 = a0 + TAU / n
        am = (a0 + a1) / 2
        seam_a = [polar(r_in, a0), polar(r_out, a0)]
        seam_b = [polar(r_in, a1), polar(r_out, a1)]
        out.append(seam_sector(r_in, r_out, seam_a, seam_b, polar(centre_r, am), window(k, am)))
    return out


def window_disc(b, sectors, front, back, bevel=(0.0025, 0.0028), loops=(), max_turn=math.radians(18),
                max_len=0.020):
    """Build every sector as a closed solid into MeshBuilder b.

    front(y, z, d) -> x of the front face at a point d metres from the nearest window edge;
    back(y, z) -> x of the back face. bevel = (width, depth) of the chamfer round each
    window; loops = extra front loops (fractions from the chamfer to the seam), so the
    front face follows a curved profile."""
    for sec in sectors:
        c, f = sec.centre, sec.sdf
        if f(*c) >= 0:
            raise SystemExit('VK_RIM_FAILED window centre is not inside its window')
        # Window outline, densely, by rays; then the rays actually used: enough that the
        # outline turns at most max_turn and runs at most max_len between two, plus a ray
        # through every boundary corner so the sector keeps its exact shape.
        dense = []
        for i in range(720):
            a = TAU * i / 720
            d = (math.cos(a), math.sin(a))
            tb = _ray_poly(sec.boundary, c, d)
            tw = _cross(f, c, d, 0.0, tb)
            dense.append((a, c[0] + d[0] * tw, c[1] + d[1] * tw))
        corner_angles = sorted({math.atan2(q[1] - c[1], q[0] - c[0]) % TAU for q in sec.corners})

        def tangent(i):
            p, q = dense[i % 720], dense[(i + 1) % 720]
            return q[1] - p[1], q[2] - p[2]
        picked, last = [0.0], 0
        for j in range(1, 720):
            seg = math.hypot(dense[j][1] - dense[last][1], dense[j][2] - dense[last][2])
            h0, h1 = tangent(last), tangent(j)
            turn = abs(math.atan2(h0[0] * h1[1] - h0[1] * h1[0], h0[0] * h1[0] + h0[1] * h1[1]))
            if seg >= max_len or turn >= max_turn:
                picked.append(dense[j][0])
                last = j
        near = math.radians(0.6)
        rays = sorted(corner_angles + [a for a in picked
                                       if all(min(abs(a - ca), TAU - abs(a - ca)) > near for ca in corner_angles)])
        rows = []
        for a in rays:
            d = (math.cos(a), math.sin(a))
            tb = _ray_poly(sec.boundary, c, d)
            tw = _cross(f, c, d, 0.0, tb)
            room = tb - tw
            # The chamfer is measured across the edge (the field), never past half the material.
            if f(c[0] + d[0] * tb, c[1] + d[1] * tb) > bevel[0] * 1.6:
                tv = _cross(f, c, d, tw, tb, bevel[0])
            else:
                tv = tw + room * 0.3
            ts = [tw, tv] + [tv + (tb - tv) * s for s in loops] + [tb]
            pts = [(c[0] + d[0] * t, c[1] + d[1] * t) for t in ts]
            rows.append(pts)
        n = len(rows)
        nl = len(rows[0])
        front_idx, back_idx = [], []
        for pts in rows:
            ring = []
            for i, (y, z) in enumerate(pts):
                dist = max(0.0, f(y, z))
                x = front(y, z, dist) + (bevel[1] if i == 0 else 0.0)
                ring.append(b.vert((x, y, z)))
            front_idx.append(ring)
            (wy, wz), (by_, bz) = pts[0], pts[-1]
            back_idx.append((b.vert((back(wy, wz), wy, wz)), b.vert((back(by_, bz), by_, bz))))
        for j in range(n):
            k = (j + 1) % n
            u0, u1 = j / n, (j + 1) / n
            fa, fb = front_idx[j], front_idx[k]
            for i in range(nl - 1):
                b.face([fa[i], fb[i], fb[i + 1], fa[i + 1]], [(u0, i / nl), (u1, i / nl), (u1, (i + 1) / nl), (u0, (i + 1) / nl)])
            ba, bb = back_idx[j], back_idx[k]
            b.face([fa[0], ba[0], bb[0], fb[0]], [(u0, 0), (u0, 0.1), (u1, 0.1), (u1, 0)])            # window wall
            b.face([ba[0], ba[1], bb[1], bb[0]], [(u0, 0), (u0, 1), (u1, 1), (u1, 0)])                 # back face
            b.face([fa[-1], fb[-1], bb[1], ba[1]], [(u0, 1), (u1, 1), (u1, 0.9), (u0, 0.9)])           # seam wall
    return b


def profile(points):
    """Monotone cubic (PCHIP) through [(r, x), ...] sorted by r, clamped outside."""
    rs = [q[0] for q in points]
    xs = [q[1] for q in points]
    n = len(points)
    h = [rs[i + 1] - rs[i] for i in range(n - 1)]
    s = [(xs[i + 1] - xs[i]) / h[i] for i in range(n - 1)]
    m = [0.0] * n
    m[0], m[-1] = s[0], s[-1]
    for i in range(1, n - 1):
        if s[i - 1] * s[i] <= 0:
            m[i] = 0.0
        else:
            w1, w2 = 2 * h[i] + h[i - 1], h[i] + 2 * h[i - 1]
            m[i] = (w1 + w2) / (w1 / s[i - 1] + w2 / s[i])

    def f(r):
        if r <= rs[0]:
            return xs[0]
        if r >= rs[-1]:
            return xs[-1]
        i = max(0, min(n - 2, next(k for k in range(n - 1) if r <= rs[k + 1])))
        t = (r - rs[i]) / h[i]
        h00, h10, h01, h11 = 2 * t ** 3 - 3 * t ** 2 + 1, t ** 3 - 2 * t ** 2 + t, -2 * t ** 3 + 3 * t ** 2, t ** 3 - t ** 2
        return h00 * xs[i] + h10 * h[i] * m[i] + h01 * xs[i + 1] + h11 * h[i] * m[i + 1]
    return f


def crowned(base, crown, reach):
    """Front face: the profile base(r), raised by `crown` metres away from the window edges
    (reached `reach` metres in), so spokes and bridges get rounded shoulders."""
    def front(y, z, d):
        t = min(1.0, d / reach)
        return base(math.hypot(y, z)) - crown * (t * t * (3 - 2 * t))
    return front


def lug_bosses(b, count, radius, x_front, boss_r, height, phase, segments=8):
    """Raised seats round each lug nut, in the face material: the nut sits in a pocket."""
    for k in range(count):
        a = phase + k * TAU / count
        b.lathe([(x_front + height, boss_r * 0.55), (x_front, boss_r * 0.62), (x_front, boss_r * 0.86),
                 (x_front + height * 0.35, boss_r), (x_front + height, boss_r)], segments, closed=True,
                center=polar(radius, a))


def valve_stem(b, radius, angle, x_seat, length=0.022, r_stem=0.0036, tilt=math.radians(42)):
    """The tyre valve: a short stem leaving the barrel at `radius`, tilted toward the axis
    and outboard, so its cap shows between the spokes. It ends behind the face."""
    uy, uz = math.cos(angle), math.sin(angle)
    ty, tz = -uz, uy
    d = (-math.sin(tilt), -math.cos(tilt) * uy, -math.cos(tilt) * uz)
    q = (-math.cos(tilt), math.sin(tilt) * uy, math.sin(tilt) * uz)     # perpendicular to d, in the (x, radial) plane
    base = (x_seat, radius * uy, radius * uz)
    sections = []
    for s, rr in ((-0.006, r_stem * 1.5), (0.0015, r_stem * 1.5), (0.0035, r_stem), (length * 0.62, r_stem),
                  (length * 0.64, r_stem * 1.12), (length, r_stem * 1.05)):
        cx, cy, cz = (base[i] + d[i] * s for i in range(3))
        ring = []
        for j in range(8):
            t = TAU * j / 8
            ct, st = math.cos(t) * rr, math.sin(t) * rr
            ring.append((cx + q[0] * st, cy + ty * ct + q[1] * st, cz + tz * ct + q[2] * st))
        sections.append(ring)
    b.sweep(sections, closed_section=True, cap=True)


def sd_side(poly, inside):
    """Signed distance to an open polyline crossing the whole band (a curved spoke edge),
    negative on the side of `inside`. Its ends must lie outside the band."""
    segs = list(zip(poly, poly[1:]))

    def raw(y, z):
        best, sign = None, 1.0
        for (ay, az), (by, bz) in segs:
            ey, ez = by - ay, bz - az
            t = max(0.0, min(1.0, ((y - ay) * ey + (z - az) * ez) / (ey * ey + ez * ez)))
            qy, qz = ay + ey * t - y, az + ez * t - z
            d2 = qy * qy + qz * qz
            if best is None or d2 < best:
                best, sign = d2, (1.0 if ey * (z - az) - ez * (y - ay) > 0 else -1.0)
        return sign * math.sqrt(best)
    flip = -1.0 if raw(*inside) > 0 else 1.0
    return lambda y, z: flip * raw(y, z)


def at_radius(p0, p1, r):
    """The point of the ray p0 -> p1 (p0 inside radius r) at distance r from the axis."""
    dy, dz = p1[0] - p0[0], p1[1] - p0[1]
    a = dy * dy + dz * dz
    b = 2 * (p0[0] * dy + p0[1] * dz)
    c = p0[0] ** 2 + p0[1] ** 2 - r * r
    t = (-b + math.sqrt(b * b - 4 * a * c)) / (2 * a)
    return (p0[0] + dy * t, p0[1] + dz * t)


def offset_line(p0, p1, hw0, hw1, side):
    """The edge of a straight spoke whose centre line runs p0 -> p1, hw0/hw1 from it,
    on its left (side +1, counter-clockwise for an outward spoke) or right (-1)."""
    dy, dz = p1[0] - p0[0], p1[1] - p0[1]
    length = math.hypot(dy, dz)
    ny, nz = -dz / length * side, dy / length * side
    return (p0[0] + ny * hw0, p0[1] + nz * hw0), (p1[0] + ny * hw1, p1[1] + nz * hw1)


def offset_poly(poly, hw, side):
    """A curved spoke edge: the centre polyline offset by hw(s) (s = 0..1 along it)."""
    out = []
    n = len(poly)
    for i, (y, z) in enumerate(poly):
        a, b = poly[max(0, i - 1)], poly[min(n - 1, i + 1)]
        dy, dz = b[0] - a[0], b[1] - a[1]
        length = math.hypot(dy, dz)
        w = hw(i / (n - 1))
        out.append((y - dz / length * side * w, z + dy / length * side * w))
    return out


def tube(b, p0, p1, radius, sides=6):
    """A straight round bar (wire spoke) from p0 to p1, capped."""
    d = [p1[i] - p0[i] for i in range(3)]
    length = math.sqrt(sum(v * v for v in d))
    d = [v / length for v in d]
    ref = (1.0, 0.0, 0.0) if abs(d[0]) < 0.9 else (0.0, 1.0, 0.0)
    u = (d[1] * ref[2] - d[2] * ref[1], d[2] * ref[0] - d[0] * ref[2], d[0] * ref[1] - d[1] * ref[0])
    lu = math.sqrt(sum(v * v for v in u))
    u = [v / lu for v in u]
    w = (d[1] * u[2] - d[2] * u[1], d[2] * u[0] - d[0] * u[2], d[0] * u[1] - d[1] * u[0])
    rings = []
    for p in (p0, p1):
        rings.append([tuple(p[i] + radius * (math.cos(TAU * j / sides) * u[i] + math.sin(TAU * j / sides) * w[i])
                            for i in range(3)) for j in range(sides)])
    b.sweep(rings, closed_section=True, cap=True)


# Lens-shaped vane section, (chord, thickness) fractions.
VANE = ((-0.5, 0.0), (-0.36, -0.5), (0.3, -0.5), (0.5, 0.0), (0.3, 0.5), (-0.36, 0.5))


def vane(b, a0, a1, r0, r1, x_mid, chord0, chord1, thick, pitch, steps):
    """A turbofan blade from (r0, a0) to (r1, a1): a thin lens pitched `pitch` from the
    spin axis toward the tangent, its chord growing from chord0 to chord1."""
    cx, ct = math.cos(pitch), math.sin(pitch)
    sections = []
    for i in range(steps + 1):
        s = i / steps
        a, r, ch = a0 + (a1 - a0) * s, r0 + (r1 - r0) * s, chord0 + (chord1 - chord0) * s
        py, pz = polar(r, a)
        ty, tz = -math.sin(a), math.cos(a)
        ring = []
        for u, v in VANE:
            ax_, tg = cx * u * ch - ct * v * thick, ct * u * ch + cx * v * thick
            ring.append((x_mid + ax_, py + ty * tg, pz + tz * tg))
        sections.append(ring)
    b.sweep(sections, closed_section=True, cap=True)


def pad_hub(segments, xh, hub_r, depth=0.020, chamfer=0.0035, sides=None):
    """Flat hub pad of a cast face, front at xh. The face disc runs into its side wall,
    8 mm or more behind the pad face, so no two surfaces ever coincide."""
    return vk.MeshBuilder().lathe([(xh, 0.0), (xh, hub_r - chamfer), (xh + chamfer, hub_r), (xh + depth, hub_r),
                                   (xh + depth, 0.0)], sides or max(24, segments * 5 // 8))


def lug_set(main, det, p, xh, phase, boss=True, circle=None, head_r=0.0092, height=0.012):
    """Lug nuts on the hub pad, each in a raised seat of the face material."""
    lugs = int(p['lugs'])
    if lugs <= 0:
        return
    circle = circle or p['lug_circle']
    if boss:
        lug_bosses(main, lugs, circle, xh - 0.003, head_r * 1.62, 0.0045, phase)
    bolt_ring(det, lugs, circle, xh - 0.003 - height + 0.002, head_r, height, phase)


# Coarser ray spacing for the faces with many windows (6k-triangle budget, docs/rims.md).
LEAN = dict(max_turn=math.radians(22), max_len=0.026)


def cast_disc(main, sectors, base, thick, crown=0.0, reach=0.010, bevel=(0.0025, 0.0028), loops=(), **kw):
    window_disc(main, sectors, crowned(base, crown, reach), lambda y, z: base(math.hypot(y, z)) + thick, bevel, loops, **kw)


def build_catalogue(exp, p, lod, segments, mats, seed):
    rng = random.Random(seed)
    style = p['style']
    R, W, fx = p['radius'], p['width'], p['face_x']
    depth = p['lip_depth']
    r_in = R - depth
    xh = fx + p['dish']
    hub_r = p['hub_radius']
    n = int(p['spokes'])
    hw0 = p['spoke_width'] / 2
    hw1 = hw0 * p['spoke_taper']
    steps = 7 if lod == 1 else 3
    phase = rng.uniform(-0.04, 0.04)
    main, lip, det = vk.MeshBuilder(), vk.MeshBuilder(), vk.MeshBuilder()
    # Spokes overlap the hub and dive under the lip so no seam opens between them.
    r0, r1 = hub_r - 0.010, r_in + 0.010
    x_lip = fx + 0.012

    if style == 'classic':
        # Ten slim concave spokes, round section, lug nuts between every other pair.
        lip.extend(standard_lip(segments, fx, R, depth))
        for k in range(n):
            a = phase + k * TAU / n
            member(main, a, a, r0, r1, xh + 0.001, x_lip, hw0, hw1, 0.026, 0.018, steps, 'round', curve=1.8, ease=False)
        main.extend(hub(segments, xh, hub_r))
        det.extend(centre_cap(segments, xh, 0.032))
        bolt_ring(det, int(p['lugs']), p['lug_circle'], xh - 0.012, 0.0095, 0.013, phase + TAU / n / 2)

    elif style == 'lattice':
        # Cross-laced mesh: every spoke is two thin bars twisted opposite ways, so the
        # bars of neighbouring spokes cross; a riveted lip and a mid ring tie them.
        recess = 0.006
        lip.extend(standard_lip(segments, fx, R, depth, recess))
        tw = p['twist']
        for k in range(n):
            a = phase + k * TAU / n
            for sgn in (1, -1):
                member(main, a, a + sgn * tw, r0, r1, xh + 0.001, x_lip, hw0, hw1, 0.016, 0.013, max(2, steps - 2), 'chamfer', curve=1.5, ease=False)
        rm = 0.56 * R
        ring(main, segments, xh - 0.006 + (x_lip - xh) * 0.45, xh + 0.010 + (x_lip - xh) * 0.45, rm - 0.006, rm + 0.006)
        main.extend(hub(segments, xh, hub_r))
        det.extend(centre_cap(segments, xh, 0.030, dome=0.012))
        # Rivets stand proud of the recessed lip flat, never in front of the outer bead.
        rivet_r = (R - 0.014 + R - depth + 0.004) / 2
        bolt_ring(det, 16, rivet_r, fx + 0.0008, 0.0042, recess + 0.0015, phase, sides=6)
        bolt_ring(det, int(p['lugs']), p['lug_circle'], xh - 0.011, 0.0090, 0.012, phase + TAU / n)

    elif style == 'dish':
        # Deep dish: a wide flat lip and a step wall that drops to the recessed spoke
        # face; eight straight spokes climb from the deep hub to the step.
        step_x = fx + 0.070
        lip.lathe([
            (step_x, r_in - 0.004), (fx + 0.008, r_in - 0.004), (fx, r_in + 0.004), (fx, R - 0.008),
            (fx + 0.004, R - 0.001), (fx + 0.011, R), (fx + 0.020, R - 0.006), (fx + 0.030, R - 0.020),
            (step_x, R - 0.020)], segments, closed=True)
        for k in range(n):
            a = phase + k * TAU / n
            member(main, a, a, r0, r_in + 0.002, xh + 0.001, step_x - 0.004, hw0, hw1, 0.030, 0.024, steps, 'chamfer', curve=1.2, ease=False)
        main.extend(hub(segments, xh, hub_r))
        det.extend(centre_cap(segments, xh, 0.030, dome=0.014))
        bolt_ring(det, int(p['lugs']), p['lug_circle'], xh - 0.012, 0.0095, 0.013, phase + TAU / n / 2)

    elif style == 'fork':
        # Split five: each spoke leaves the hub as one and forks into two arms that meet
        # the lip apart, with a ridge between them.
        lip.extend(standard_lip(segments, fx, R, depth))
        spread = (TAU / n) * 0.17
        mid = r0 + (r1 - r0) * 0.38
        xm = xh + (x_lip - xh) * 0.55
        for k in range(n):
            a = phase + k * TAU / n
            member(main, a, a, r0, mid + 0.006, xh + 0.001, xm, hw0, hw0 * 0.92, 0.030, 0.026, max(2, steps // 2), 'round', curve=1.3, ease=False)
            for sgn in (1, -1):
                member(main, a + sgn * 0.006, a + sgn * spread, mid - 0.006, r1, xm, x_lip, hw0 * 0.62, hw1 * 0.62, 0.026, 0.019, steps, 'round', curve=1.6, ease=True)
        main.extend(hub(segments, xh, hub_r))
        det.extend(centre_cap(segments, xh, 0.034))
        bolt_ring(det, int(p['lugs']), p['lug_circle'], xh - 0.012, 0.0095, 0.013, phase + TAU / n / 2)

    elif style == 'blade':
        # Turbine: twelve thin swept blades, a narrow lip and a large flat cap.
        lip.extend(standard_lip(segments, fx, R, depth))
        for k in range(n):
            a = phase + k * TAU / n
            member(main, a, a + p['twist'], r0, r1, xh + 0.001, x_lip, hw0, hw1, 0.030, 0.020, steps, 'blade', curve=1.4, ease=True)
        main.extend(hub(segments, xh, hub_r))
        det.extend(centre_cap(segments, xh, 0.050, dome=0.010))
        bolt_ring(det, int(p['lugs']), 0.060, xh - 0.008, 0.0075, 0.010, phase)

    elif style == 'beadlock':
        # Off-road beadlock: a proud bolted ring on the lip, six wide flat spokes, six
        # lugs and a tall cap.
        ring_front = fx + 0.007
        lip.lathe([
            (fx + 0.040, r_in), (ring_front, r_in), (ring_front, R - 0.006), (ring_front + 0.004, R),
            (fx + 0.040, R), (fx + 0.040, R - 0.020)], segments, closed=True)
        lip.lathe([(fx + 0.020, r_in - 0.006), (fx + 0.020, r_in + 0.002), (fx + 0.050, r_in + 0.002),
                   (fx + 0.050, r_in - 0.006)], segments, closed=True)
        bolt_ring(det, 24, R - depth * 0.48, fx, 0.0062, 0.0075, phase)
        for k in range(n):
            a = phase + k * TAU / n
            member(main, a, a, r0, r1, xh + 0.001, fx + 0.024, hw0, hw1, 0.034, 0.030, steps, 'flat', curve=1.1, ease=False)
        main.extend(hub(segments, xh, hub_r, depth=0.046))
        det.extend(centre_cap(segments, xh, 0.046, dome=0.024))
        bolt_ring(det, int(p['lugs']), 0.064, xh - 0.012, 0.0100, 0.014, phase + TAU / n / 2)

    elif style == 'aero':
        # Aero disc: a closed, gently concave disc with a recessed groove and raised
        # vent ribs near the edge; no visible lug nuts.
        lip.extend(standard_lip(segments, fx, R, depth))
        disc_front = [(fx + 0.010, r_in + 0.004), (fx + 0.014, r_in - 0.010), (fx + 0.022, 0.70 * R),
                      (fx + 0.028, 0.66 * R), (fx + 0.022, 0.62 * R), (fx + 0.026, 0.40 * R),
                      (xh - 0.004, hub_r)]
        disc_back = [(xh + 0.010, hub_r), (fx + 0.040, 0.40 * R), (fx + 0.036, r_in - 0.010), (fx + 0.026, r_in + 0.004)]
        main.lathe(disc_front + disc_back, segments, closed=True)
        rib_r0, rib_r1 = 0.71 * R, r_in - 0.016
        for k in range(n):
            a = phase + k * TAU / n
            member(det, a, a + 0.10, rib_r0, rib_r1, fx + 0.017, fx + 0.010, 0.010, 0.006, 0.008, 0.008, 2, 'chamfer', curve=1.0, ease=False)
        main.extend(hub(segments, xh, hub_r, depth=0.030))
        det.extend(centre_cap(segments, xh, 0.046, dome=0.014))

    elif style == 'tech':
        # Night City "tech": a hex hub, a floating inner ring on six short arms, three
        # wide swept blades split by a counter-swept strut, and a raised accent ring.
        lip.extend(standard_lip(segments, fx, R, depth))
        hex_r = hub_r * 1.08
        main.extend(hub(segments, xh, hex_r, depth=0.044, sides=6))
        rm0, rm1 = 0.43 * R, 0.54 * R
        xr = xh - 0.004 + (x_lip - xh) * 0.35
        ring(main, segments, xr, xr + 0.022, rm0, rm1, 0.003)
        for k in range(6):
            a = phase + k * TAU / 6
            member(main, a, a, hex_r - 0.010, rm0 + 0.004, xh + 0.002, xr + 0.002, 0.014, 0.012, 0.022, 0.020, 2, 'flat', curve=1.0, ease=False)
        tw = p['twist']
        for k in range(n):
            a = phase + k * TAU / n
            member(main, a, a + tw, rm1 - 0.004, r1, xr, x_lip, hw0, hw1, 0.024, 0.020, steps, 'chamfer', curve=1.5, ease=True)
            member(main, a + TAU / n * 0.5, a + TAU / n * 0.5 - tw * 0.55, rm1 - 0.004, r1, xr + 0.002, x_lip, hw0 * 0.46, hw1 * 0.60, 0.018, 0.016, steps, 'chamfer', curve=1.5, ease=True)
        ring(det, segments, xr - 0.004, xr + 0.003, (rm0 + rm1) / 2 - 0.004, (rm0 + rm1) / 2 + 0.004, 0.0015)
        det.extend(centre_cap(segments, xh, 0.030, dome=0.012, sides=6))
        bolt_ring(det, int(p['lugs']), 0.058, xh - 0.010, 0.0080, 0.011, phase + TAU / 12)
    elif style in FACE_BUILDERS:
        g = Ctx(p=p, R=R, W=W, fx=fx, depth=depth, r_in=r_in, xh=xh, hub_r=hub_r, n=n, hw0=hw0, hw1=hw1,
                phase=phase, segments=segments, steps=steps, main=main, lip=lip, det=det, barrel=main)
        FACE_BUILDERS[style](g)
        barrel_to = g.barrel
    else:
        raise SystemExit(f'no catalogue builder for {style}')

    # The barrel carries the bead seat behind the lip; it is seen through the spokes.
    # The face styles spend their budget on the face: their barrel, seen only through the
    # windows, takes 3/4 of the radial segments.
    if style in FACE_BUILDERS:
        barrel_to.extend(barrel(max(32, segments * 3 // 4), fx + 0.028, fx + W, R, r_in))
    else:
        main.extend(barrel(segments, fx + 0.028, fx + W, R, r_in))
    exp.add(main, lod, 'rim_main', mats['rim_main'])
    exp.add(lip, lod, 'rim_lip', mats['rim_lip'])
    exp.add(det, lod, 'rim_detail', mats['rim_detail'])


# ---------------------------------------------------------------------------- face styles
# The styles below build their face from window discs, tubes and vanes. Each receives the
# shared geometry in a Ctx and fills g.main / g.lip / g.det; g.barrel names the slot the
# barrel goes to (main by default; steel and wire wheels put it with the lip).
class Ctx:
    def __init__(self, **kw):
        self.__dict__.update(kw)


def face_star(g):
    """Cast five-spoke: a concave disc pierced by five filleted windows; the spokes keep a
    rounded crown and a chamfered edge, wide at the hub and tapering to the lip."""
    R, fx, xh = g.R, g.fx, g.xh
    g.lip.extend(standard_lip(g.segments, fx, R, g.depth))
    r0, r1 = g.hub_r - 0.004, g.r_in + 0.010
    ra, rb = g.hub_r + 0.018, g.r_in - 0.006
    base = profile([(r0, xh + 0.009), (g.hub_r + 0.010, xh + 0.008), (0.135, fx + 0.042), (0.190, fx + 0.024),
                    (g.r_in - 0.002, fx + 0.0135), (r1, fx + 0.012)])

    def window(k, am):
        a0, a1 = am - math.pi / g.n, am + math.pi / g.n
        c = polar((ra + rb) / 2 + 0.012, am)
        return sd_round([sd_line(*offset_line(polar(0.0, a0), polar(rb, a0), g.hw0, g.hw1, +1), c),
                         sd_line(*offset_line(polar(0.0, a1), polar(rb, a1), g.hw0, g.hw1, -1), c),
                         sd_outside_circle(ra), sd_inside_circle(rb)], 0.014)
    sectors = radial_sectors(g.n, g.phase, r0, r1, window, (ra + rb) / 2 + 0.012)
    cast_disc(g.main, sectors, base, 0.020)
    g.main.extend(pad_hub(g.segments, xh, g.hub_r))
    g.det.extend(centre_cap(g.segments, xh, 0.031, dome=0.013))
    lug_set(g.main, g.det, g.p, xh, g.phase)
    valve_stem(g.det, g.r_in + 0.001, g.phase + math.pi / g.n, fx + 0.046)


def face_twin(g):
    """Twin six: six pairs of slim spokes opening in a shallow V from a shared root, with a
    narrow slot inside each pair and a wide window between pairs."""
    R, fx, xh, n = g.R, g.fx, g.xh, g.n
    g.lip.extend(standard_lip(g.segments, fx, R, g.depth))
    r0, r1 = g.hub_r - 0.004, g.r_in + 0.010
    ra, rb = g.hub_r + 0.016, g.r_in - 0.006
    spread = g.p['twist']                     # half-angle between the two spokes of a pair at the lip
    base = profile([(r0, xh + 0.009), (g.hub_r + 0.010, xh + 0.008), (0.140, fx + 0.040), (0.195, fx + 0.022),
                    (g.r_in - 0.002, fx + 0.0135), (r1, fx + 0.012)])

    def centre(k, side):
        # Spoke centre line of pair k, side -1/+1: from the hub axis region to beyond the lip.
        a = g.phase + k * TAU / n
        return polar(0.040, a + side * 0.02), polar(r1 + 0.02, a + side * spread)

    def clip(seg):
        # The seam is the spoke centre line between r0 and r1.
        return [at_radius(*seg, r0), at_radius(*seg, r1)]
    sectors = []
    for k in range(n):
        a = g.phase + k * TAU / n
        lo, hi = centre(k, -1), centre(k, +1)
        nxt = centre((k + 1) % n, -1)
        # Slot inside the pair.
        c = polar((ra + rb) / 2 + 0.035, a)
        slot = sd_round([sd_line(*offset_line(*lo, g.hw0, g.hw1, +1), c), sd_line(*offset_line(*hi, g.hw0, g.hw1, -1), c),
                         sd_outside_circle(ra + 0.022), sd_inside_circle(rb)], 0.006)
        sectors.append(seam_sector(r0, r1, clip(lo), clip(hi), c, slot))
        # Wide window to the next pair.
        am = a + math.pi / n
        c = polar((ra + rb) / 2 + 0.010, am)
        wide = sd_round([sd_line(*offset_line(*hi, g.hw0, g.hw1, +1), c), sd_line(*offset_line(*nxt, g.hw0, g.hw1, -1), c),
                         sd_outside_circle(ra), sd_inside_circle(rb)], 0.013)
        sectors.append(seam_sector(r0, r1, clip(hi), clip(nxt), c, wide))
    cast_disc(g.main, sectors, base, 0.020, **LEAN)
    g.main.extend(pad_hub(g.segments, xh, g.hub_r))
    g.det.extend(centre_cap(g.segments, xh, 0.030, dome=0.012))
    lug_set(g.main, g.det, g.p, xh, g.phase + math.pi / n)
    valve_stem(g.det, g.r_in + 0.001, g.phase + math.pi / n, fx + 0.046)


def face_yspoke(g):
    """Y-spoke monoblock: n solid trunks that split two-thirds out into arms meeting the lip
    evenly spaced, so the lip sees 2n tips; a narrow crotch window inside every Y."""
    R, fx, xh, n = g.R, g.fx, g.xh, g.n
    g.lip.extend(standard_lip(g.segments, fx, R, g.depth))
    r0, r1 = g.hub_r - 0.004, g.r_in + 0.010
    ra, rb = g.hub_r + 0.016, g.r_in - 0.006
    r_split = g.p['split'] if 'split' in g.p else 0.150
    tip = math.pi / (2 * n)                   # arm tips at a +- tip: 2n tips evenly spaced
    hw_t, hw_a = g.hw0, g.hw0 * g.p['spoke_taper']
    base = profile([(r0, xh + 0.009), (g.hub_r + 0.010, xh + 0.008), (0.140, fx + 0.038), (0.200, fx + 0.021),
                    (g.r_in - 0.002, fx + 0.0135), (r1, fx + 0.012)])

    def arm(k, side):
        # Arm centre line: from the split point through its tip on the window circle rb.
        a = g.phase + k * TAU / n
        return polar(r_split, a), polar(rb, a + side * tip)

    def seam(k, side):
        s, t = arm(k, side)
        return [polar(r0, g.phase + k * TAU / n), s, at_radius(s, t, r1)]

    def trunk(k):
        a = g.phase + k * TAU / n
        return polar(0.0, a), polar(r_split + 0.08, a)
    sectors = []
    for k in range(n):
        a = g.phase + k * TAU / n
        # Crotch window inside Y k: between the inner edges of its two arms.
        c = polar((r_split + rb) / 2 + 0.022, a)
        crotch = sd_round([sd_line(*offset_line(*arm(k, -1), hw_a, hw_a, +1), c), sd_line(*offset_line(*arm(k, +1), hw_a, hw_a, -1), c),
                           sd_inside_circle(rb)], 0.007)
        s_m, s_p = seam(k, -1), seam(k, +1)
        a_p, a_m = math.atan2(s_p[2][1], s_p[2][0]), math.atan2(s_m[2][1], s_m[2][0])
        a_m = a_p - ((a_p - a_m) % TAU)
        boundary = [s_p[1]] + arc(r1, a_p, a_m)
        sectors.append(Sector(boundary, [s_p[1], s_p[2], s_m[2]], c, crotch))
        # Wide window between Y k and Y k+1.
        am = a + math.pi / n
        c = polar((ra + r_split) / 2 + 0.035, am)
        wide = sd_round([sd_line(*offset_line(*trunk(k), hw_t, hw_t, +1), c), sd_line(*offset_line(*arm(k, +1), hw_a, hw_a, +1), c),
                         sd_line(*offset_line(*trunk(k + 1), hw_t, hw_t, -1), c), sd_line(*offset_line(*arm(k + 1, -1), hw_a, hw_a, -1), c),
                         sd_outside_circle(ra), sd_inside_circle(rb)], 0.012)
        sectors.append(seam_sector(r0, r1, seam(k, +1), seam(k + 1, -1), c, wide))
    cast_disc(g.main, sectors, base, 0.020, **LEAN)
    g.main.extend(pad_hub(g.segments, xh, g.hub_r))
    g.det.extend(centre_cap(g.segments, xh, 0.031, dome=0.013))
    lug_set(g.main, g.det, g.p, xh, g.phase + math.pi / n)
    valve_stem(g.det, g.r_in + 0.001, g.phase + math.pi / n, fx + 0.046)


def face_vortex(g):
    """Vortex: n curved spokes that sweep `twist` radians from hub to lip and widen toward
    it, so the face reads as turning (a directional design)."""
    R, fx, xh, n = g.R, g.fx, g.xh, g.n
    g.lip.extend(standard_lip(g.segments, fx, R, g.depth))
    r0, r1 = g.hub_r - 0.004, g.r_in + 0.010
    ra, rb = g.hub_r + 0.014, g.r_in - 0.006
    sweep = g.p['twist']
    base = profile([(r0, xh + 0.009), (g.hub_r + 0.010, xh + 0.008), (0.140, fx + 0.036), (0.200, fx + 0.020),
                    (g.r_in - 0.002, fx + 0.0135), (r1, fx + 0.012)])

    def angle(k, r):
        u = min(1.0, max(0.0, (r - r0) / (r1 - r0)))
        return g.phase + k * TAU / n + sweep * u ** 1.5

    def centre(k, r_lo, r_hi, m):
        return [polar(r, angle(k, r)) for r in (r_lo + (r_hi - r_lo) * i / m for i in range(m + 1))]

    def edge(k, side):
        return offset_poly(centre(k, 0.02, r1 + 0.04, 16), lambda s: g.hw0 + (g.hw1 - g.hw0) * s, side)
    sectors = []
    for k in range(n):
        rm = (ra + rb) / 2
        c = polar(rm, angle(k, rm) + math.pi / n)
        win = sd_round([sd_side(edge(k, +1), c), sd_side(edge(k + 1, -1), c), sd_outside_circle(ra), sd_inside_circle(rb)], 0.012)
        sectors.append(seam_sector(r0, r1, centre(k, r0, r1, 8), centre(k + 1, r0, r1, 8), c, win))
    cast_disc(g.main, sectors, base, 0.020, **LEAN)
    g.main.extend(pad_hub(g.segments, xh, g.hub_r))
    g.det.extend(centre_cap(g.segments, xh, 0.032, dome=0.012))
    lug_set(g.main, g.det, g.p, xh, g.phase + math.pi / n)
    valve_stem(g.det, g.r_in + 0.001, angle(0, g.r_in) + math.pi / n, fx + 0.046)


def rivet_ring(b, count, radius, x_front, head_r, height, phase, sides=6):
    """Domed assembly bolt heads on a circle, front at x_front. Each is open at the back:
    its base sinks into the flange it sits on."""
    for k in range(count):
        b.lathe([(x_front, 0.0), (x_front + height * 0.35, head_r * 0.78), (x_front + height, head_r)],
                sides, center=polar(radius, phase + k * TAU / count))


def face_threepiece(g):
    """Three-piece: a polished deep lip (a wide flat lip and a stepped wall dropping to the
    centre) and a ten-spoke centre bolted to it by a ring of domed assembly bolts."""
    R, fx, xh, n = g.R, g.fx, g.xh, g.n
    r_step = R - g.depth
    step_x = fx + 0.070
    g.lip.lathe([
        (step_x, r_step - 0.004), (fx + 0.008, r_step - 0.004), (fx, r_step + 0.004), (fx, R - 0.008),
        (fx + 0.004, R - 0.001), (fx + 0.011, R), (fx + 0.020, R - 0.006), (fx + 0.030, R - 0.020),
        (step_x, R - 0.020)], g.segments, closed=True)
    r0, r1 = g.hub_r - 0.004, r_step + 0.002
    ra, rb = g.hub_r + 0.014, r_step - 0.030
    flange_x = step_x - 0.003
    base = profile([(r0, xh + 0.009), (g.hub_r + 0.010, xh + 0.008), (0.150, flange_x + 0.004), (rb, flange_x),
                    (r1, flange_x)])

    def window(k, am):
        a0, a1 = am - math.pi / n, am + math.pi / n
        c = polar((ra + rb) / 2 + 0.006, am)
        return sd_round([sd_line(*offset_line(polar(0.0, a0), polar(rb, a0), g.hw0, g.hw1, +1), c),
                         sd_line(*offset_line(polar(0.0, a1), polar(rb, a1), g.hw0, g.hw1, -1), c),
                         sd_outside_circle(ra), sd_inside_circle(rb)], 0.008)
    cast_disc(g.main, radial_sectors(n, g.phase, r0, r1, window, (ra + rb) / 2 + 0.006), base, 0.018, **LEAN)
    g.main.extend(pad_hub(g.segments, xh, g.hub_r))
    bolts = int(g.p['bolts'])
    rivet_ring(g.det, bolts, (rb + r_step - 0.004) / 2, flange_x - 0.0045, 0.0052, 0.0050, g.phase + math.pi / bolts)
    g.det.extend(centre_cap(g.segments, xh, 0.030, dome=0.012))
    lug_set(g.main, g.det, g.p, xh, g.phase + math.pi / n)
    valve_stem(g.det, r_step - 0.004, g.phase + math.pi / n, step_x - 0.006, length=0.016)


def face_wire(g):
    """Wire wheel: a drum hub with two flanges, `count` straight spokes laced so that they
    cross on their way to the barrel, a narrow lip and a two-eared knock-off spinner."""
    R, fx = g.R, g.fx
    g.barrel = g.lip
    g.lip.extend(standard_lip(g.segments, fx, R, g.depth))
    count = int(g.p.get('count', 60)) // 2 * 2
    per = count // 2
    cross = g.p['twist']
    flanges = ((fx + 0.040, 0.060, fx + 0.088), (fx + 0.118, 0.066, fx + 0.044))   # flange x, radius, rim x
    r_nip = g.r_in + 0.008                    # nipples inside the barrel wall
    for f, (x_f, r_f, x_r) in enumerate(flanges):
        for i in range(per):
            a = g.phase + (i + 0.5 * f) * TAU / per
            to = a + (cross if i % 2 == 0 else -cross)
            hy, hz = polar(r_f - 0.004, a)
            ry, rz = polar(r_nip, to)
            tube(g.main, (x_f, hy, hz), (x_r, ry, rz), float(g.p.get('wire_radius', 0.0024)), 5)
    seg = max(24, g.segments // 2)
    # Drum and flanges (detail), the spinner in front of them.
    # The drum ends just behind the inboard flange: a longer one only deepens the centre.
    g.det.lathe([(fx + 0.034, 0.0), (fx + 0.034, 0.044), (fx + 0.036, 0.047), (fx + 0.124, 0.047), (fx + 0.124, 0.0)], seg)
    for x_f, r_f, _ in flanges:
        g.det.lathe([(x_f - 0.0035, 0.045), (x_f - 0.0035, r_f), (x_f + 0.0035, r_f), (x_f + 0.0035, 0.045)], seg, closed=True)
    g.det.lathe([(fx + 0.010, 0.0), (fx + 0.011, 0.020), (fx + 0.016, 0.034), (fx + 0.022, 0.038), (fx + 0.036, 0.038),
                 (fx + 0.036, 0.0)], 8)
    for side in (0.0, math.pi):
        a = g.phase + side
        member(g.det, a, a, 0.026, 0.086, fx + 0.006, fx + 0.013, 0.012, 0.005, 0.012, 0.008, 3, 'chamfer', curve=1.0, ease=False)
    valve_stem(g.det, g.r_in + 0.001, g.phase + TAU / per * 0.25, fx + 0.040)


def face_turbofan(g):
    """Turbofan: a flat outer ring and a domed centre cover joined by `count` pitched,
    curved fan blades, over a dark backing disc that shows between them."""
    R, fx = g.R, g.fx
    g.lip.extend(standard_lip(g.segments, fx, R, g.depth))
    seg = max(32, g.segments * 3 // 4)
    r_ring = g.r_in - 0.034
    g.main.lathe([(fx + 0.034, r_ring), (fx + 0.016, r_ring), (fx + 0.012, r_ring + 0.005), (fx + 0.012, g.r_in + 0.008),
                  (fx + 0.034, g.r_in + 0.008)], seg, closed=True)
    r_c = g.hub_r
    g.main.lathe([(fx + 0.017, 0.0), (fx + 0.018, r_c * 0.5), (fx + 0.022, r_c * 0.85), (fx + 0.027, r_c), (fx + 0.046, r_c),
                  (fx + 0.046, 0.0)], seg)
    count = int(g.p.get('count', 24))
    pitch = math.radians(g.p.get('pitch_deg', 52))
    for k in range(count):
        a = g.phase + k * TAU / count
        vane(g.main, a, a + g.p['twist'], r_c - 0.006, r_ring + 0.006, fx + 0.031, 0.026, 0.040, 0.0035, pitch, 3)
    g.det.lathe([(fx + 0.058, r_c - 0.010), (fx + 0.058, g.r_in + 0.004), (fx + 0.062, g.r_in + 0.004), (fx + 0.062, r_c - 0.010)],
                seg, closed=True)
    rivet_ring(g.det, 5, 0.058, fx + 0.0175, 0.0055, 0.0035, g.phase, sides=8)
    valve_stem(g.det, g.r_in + 0.001, g.phase + TAU / count * 0.5, fx + 0.046, length=0.012)


def face_steelie(g):
    """Steelie: a pressed steel disc set deep in a plain steel rim, a ring of round vents, a
    raised bead, a hat round the lug face, five lug nuts and a small dog-dish cap."""
    R, fx, xh, n = g.R, g.fx, g.xh, g.n
    g.barrel = g.lip
    r_in = g.r_in
    g.lip.lathe([(fx + 0.024, r_in), (fx + 0.006, r_in), (fx, r_in + 0.006), (fx, R - 0.007), (fx + 0.004, R),
                 (fx + 0.012, R - 0.004), (fx + 0.024, R - 0.016)], g.segments, closed=True)
    hat_r = g.hub_r
    disc_x = xh + 0.034
    # Hat: the lug face, a rounded shoulder and the cone down to the disc.
    g.main.lathe([(xh, 0.0), (xh, hat_r - 0.010), (xh + 0.002, hat_r - 0.004), (xh + 0.008, hat_r + 0.004),
                  (xh + 0.026, hat_r + 0.016), (disc_x - 0.002, hat_r + 0.024), (disc_x + 0.010, hat_r + 0.024),
                  (disc_x + 0.010, 0.0)], g.segments)
    r0, r1 = hat_r + 0.018, r_in + 0.004
    hole_r = g.p['spoke_width'] / 2
    hole_c = g.p.get('hole_circle', 0.170)
    base = profile([(r0, disc_x), (0.198, disc_x), (0.228, disc_x + 0.004), (r1, disc_x + 0.006)])

    def window(k, am):
        return sd_inside_circle(hole_r, polar(hole_c, am))
    sectors = radial_sectors(n, g.phase, r0, r1, window, hole_c)
    window_disc(g.main, sectors, lambda y, z, d: base(math.hypot(y, z)), lambda y, z: base(math.hypot(y, z)) + 0.006,
                bevel=(0.0035, 0.0030), loops=(0.5,), max_turn=math.radians(22), max_len=0.03)
    # Raised bead round the vents.
    g.main.lathe([(disc_x + 0.004, 0.206), (disc_x - 0.002, 0.209), (disc_x - 0.0035, 0.214), (disc_x - 0.002, 0.219),
                  (disc_x + 0.004, 0.222)], g.segments, closed=True)
    g.det.extend(centre_cap(g.segments, xh, 0.036, dome=0.014))
    bolt_ring(g.det, int(g.p['lugs']), g.p['lug_circle'], xh - 0.012, 0.0095, 0.0125, g.phase + math.pi / n)
    valve_stem(g.det, r_in + 0.001, g.phase + math.pi / n, fx + 0.034, length=0.018)


def face_offroad(g):
    """Off-road steel: a heavy lip, a flat outer ring, then a deep cone pierced by n large
    round holes down to a six-lug hub with an open bore and a small dark cap."""
    R, fx, xh, n = g.R, g.fx, g.xh, g.n
    g.barrel = g.lip
    g.lip.extend(standard_lip(g.segments, fx, R, g.depth))
    r_flat = g.r_in - 0.030
    g.main.lathe([(fx + 0.036, r_flat - 0.004), (fx + 0.020, r_flat - 0.004), (fx + 0.016, r_flat), (fx + 0.016, g.r_in + 0.008),
                  (fx + 0.036, g.r_in + 0.008)], max(32, g.segments * 3 // 4), closed=True)
    r0, r1 = g.hub_r - 0.004, r_flat + 0.004
    hole_r = g.p['spoke_width'] / 2
    hole_c = g.p.get('hole_circle', 0.158)
    cone = profile([(r0, xh + 0.010), (g.hub_r + 0.006, xh + 0.008), (r_flat - 0.010, fx + 0.024), (r1, fx + 0.021)])

    def window(k, am):
        return sd_inside_circle(hole_r, polar(hole_c, am))
    # The cone is steep: front loops keep its curve smooth between the holes and the hub.
    window_disc(g.main, radial_sectors(n, g.phase, r0, r1, window, hole_c), lambda y, z, d: cone(math.hypot(y, z)),
                lambda y, z: cone(math.hypot(y, z)) + 0.010, bevel=(0.004, 0.0035), loops=(0.33, 0.66),
                max_turn=math.radians(16), max_len=0.018)
    g.main.extend(pad_hub(g.segments, xh, g.hub_r, depth=0.024))
    g.det.lathe([(xh - 0.004, 0.0), (xh - 0.004, 0.026), (xh - 0.002, 0.030), (xh + 0.004, 0.030), (xh + 0.004, 0.0)],
                max(24, g.segments // 2))
    bolt_ring(g.det, int(g.p['lugs']), g.p['lug_circle'], xh - 0.015, 0.0115, 0.016, g.phase + math.pi / n)
    valve_stem(g.det, g.r_in + 0.001, g.phase + math.pi / n, fx + 0.040)


def face_hex(g):
    """Hex mesh: a concave face pierced by two staggered rows of sharp hexagonal windows (an
    inner row of n, an outer row of 1.5 n), a hexagonal hub and cap and an accent ring
    between the rows."""
    R, fx, xh, n = g.R, g.fx, g.xh, g.n
    g.lip.extend(standard_lip(g.segments, fx, R, g.depth))
    pad_r = g.hub_r * 1.06                    # hexagon circumradius; its flats are at pad_r * cos 30
    r0, r1 = pad_r * math.cos(math.pi / 6) - 0.006, g.r_in + 0.010
    r_mid = g.p.get('row_split', 0.168)
    # Two conical bands creased under the accent ring.
    base = polyline_profile([(pad_r, xh + 0.008), (r_mid, fx + 0.030), (g.r_in - 0.002, fx + 0.0135), (r1, fx + 0.012)])
    rows = ((n, r0, r_mid, (g.hub_r + r_mid) / 2 + 0.004, g.p.get('hex_inner', 0.025), 0.0),
            (n * 3 // 2, r_mid, r1, (r_mid + g.r_in) / 2 - 0.002, g.p.get('hex_outer', 0.0205), 0.5))
    # Flats face the axis and the lip (a vertex points to each neighbour): the rows follow the circle.
    turn = math.radians(g.p.get('hex_turn_deg', 30.0))

    def hexagon(c, am, size):
        return [(c[0] + size * math.cos(am + turn + j * TAU / 6), c[1] + size * math.sin(am + turn + j * TAU / 6)) for j in range(6)]
    for count, lo, hi, rc, size, shift in rows:
        def window(k, am, rc=rc, size=size):
            c = polar(rc, am)
            pts = hexagon(c, am, size)
            lines = [sd_line(pts[j], pts[(j + 1) % 6], c) for j in range(6)]
            return lambda y, z: max(f(y, z) for f in lines)
        secs = radial_sectors(count, g.phase + shift * TAU / count, lo, hi, window, rc)
        for s in secs:
            s.corners = s.corners + hexagon(s.centre, math.atan2(s.centre[1], s.centre[0]), size)
        cast_disc(g.main, secs, base, 0.018, bevel=(0.0022, 0.0026), max_turn=math.radians(70), max_len=0.05)
    g.det.extend(ring_band(max(32, g.segments * 3 // 4), base(r_mid) - 0.0035, base(r_mid) + 0.004, r_mid - 0.0035, r_mid + 0.0035))
    g.main.extend(pad_hub(g.segments, xh, pad_r, sides=6))
    g.det.extend(centre_cap(g.segments, xh, 0.032, dome=0.012, sides=6))
    lug_set(g.main, g.det, g.p, xh, g.phase + math.pi / 6, boss=False)
    valve_stem(g.det, g.r_in + 0.001, g.phase + 0.5 * TAU / (n * 3 // 2), fx + 0.046)


def polyline_profile(points):
    """Piecewise-linear [(r, x), ...] sorted by r, clamped outside: conical bands whose
    flat quads shade without facets, with a crease at each point."""
    def f(r):
        if r <= points[0][0]:
            return points[0][1]
        for (ra, xa), (rb, xb) in zip(points, points[1:]):
            if r <= rb:
                return xa + (xb - xa) * (r - ra) / (rb - ra)
        return points[-1][1]
    return f


def ring_band(segments, x0, x1, r0, r1):
    b = vk.MeshBuilder()
    ring(b, segments, x0, x1, r0, r1)
    return b


FACE_BUILDERS = {
    'star': face_star,
    'twin': face_twin,
    'yspoke': face_yspoke,
    'vortex': face_vortex,
    'threepiece': face_threepiece,
    'wire': face_wire,
    'turbofan': face_turbofan,
    'steelie': face_steelie,
    'offroad': face_offroad,
    'hex': face_hex,
}


def check_face(exp, p):
    """Nothing in front of the lip face, and nothing beyond the lip radius."""
    fx, R = p['face_x'], p['radius']
    xmin = min(v.co.x for o, _, _ in exp.objects for v in o.data.vertices)
    rmax = max(math.hypot(v.co.y, v.co.z) for o, _, _ in exp.objects for v in o.data.vertices)
    if xmin < fx - 1e-4:
        raise SystemExit(f'VK_RIM_FAILED geometry at x={xmin:.4f} sits in front of face_x={fx}')
    if rmax > R + 1e-4:
        raise SystemExit(f'VK_RIM_FAILED geometry at r={rmax:.4f} sits beyond radius={R}')
    # Deepest point of the centre (hub, spoke roots, cap) within 0.4 R: the fit compares it
    # with the stock rim's centre to predict clipping into brake discs and calipers.
    centre = [v.co.x for o, _, _ in exp.objects for v in o.data.vertices if math.hypot(v.co.y, v.co.z) < 0.4 * R]
    return xmin, rmax, (max(centre) if centre else None)


def main():
    parser = vk.base_parser('Generate an original rim part')
    args = vk.script_args(parser)
    part = vk.load_part(args.part)
    if part['kind'] != 'rim':
        raise SystemExit(f"make_rim.py builds kind 'rim', got {part['kind']!r}")
    p = params_of(part)
    vk.clear_scene()
    addon = vk.enable_cp77_addon()
    catalogue = p['style'] in STYLE_DEFAULTS
    mats = {
        'rim_main': vk.preview_material('rim_main', (0.80, 0.81, 0.83), 1.0, 0.18),
        'rim_detail': vk.preview_material('rim_detail', (0.05, 0.05, 0.055), 0.6, 0.4),
    }
    if catalogue:
        mats['rim_lip'] = vk.preview_material('rim_lip', (0.85, 0.85, 0.86), 1.0, 0.12)
    exp = vk.PartExporter(part, args.out)
    for lod, segments in enumerate(p['segments'], start=1):
        if catalogue:
            build_catalogue(exp, p, lod, int(segments), mats, int(p['seed']))
        else:
            build_lod(exp, p, lod, int(segments), mats, int(p['seed']))
    extra = {}
    if catalogue:
        xmin, rmax, centre_back = check_face(exp, p)
        extra = {'style': p['style'], 'measuredFaceX': round(xmin, 5), 'measuredRadius': round(rmax, 5),
                 'centreBackX': None if centre_back is None else round(centre_back, 5)}
    exp.export(args.exporter, addon, not args.no_blend, {
        'mount': {'axis': 'X', 'outboard': '-X', 'pivot': 'wheel centre',
                  'radius': p['radius'], 'face_x': p['face_x'], 'width': p['width'], **extra},
        'addon': addon,
    })


if __name__ == '__main__':
    main()
