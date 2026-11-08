"""Offline fit table for the Light RP body kit (plain Python 3, no bpy, no numpy).

    python scripts/vehicle-kit/blender/body_fit.py                       # defaults below
    python scripts/vehicle-kit/blender/body_fit.py --parts <dir with <id>/<id>.part.json + .glb>

Reads the numbers body_measure.py wrote OUTSIDE the repository (measure.json) and the exact
1 cm body surfaces of body_surface.py (top, bottom, sides, front, rear of the stock exterior
panels, plus per-component bounds), and each part's <id>.part.json and <id>.glb (default:
the build-pack work folder of the body-kit spec). It places every part on every car, audits
the result against the body, and writes specs/lightrp-bodykit-fit.json.

Every offset it writes is an OFFLINE ESTIMATE. Nothing here was seen in game: each fit
entry carries `estimate = "offline"` until the lead verifies it with /vkit.wing + /vkit.move.

Frames (metres, X right, Y forward, Z up):
  Root  the vehicle entity frame (props.attach bone ''), wheel centres at z = 0;
  Base  the vehicle_slots bone the body shell is bound to; on all 14 cars its bind pose
        is a pure translation (0, 0, 0.27..0.55) from Root, so Base offset = Root - base;
  lid   trunk_a / trunk_b / hood_a when the panel under a part is bound there (the part
        then rides the lid); their bind pose is also a pure translation.
A part is placed as  scale (per axis) -> pitch about +X -> offset, the order props use.

How a part meets the body: each generator writes a mount record with `contact` points (part
frame) and the direction they rest in (down on a top surface, up under a bottom surface,
out against a side, fwd/back against the front/rear face), `embed` boxes (regions allowed
inside the body: feet, a bonded base, a canard's root tongue) and `anchors` (points that
must be inside it, such as a splitter rod's top). The contact solver moves the part along
the contact direction so that no contact point floats while at most `sink` of it enters the
body; when the surface is too uneven for both, the remainder floats and is reported.

The audit then samples every triangle of the placed part (3.5 cm spacing) and checks it
against the body's visual hull (inside the top/bottom column, the side band and the
front/rear band at once): any sample outside the embed boxes that lies more than 6 mm
inside is a cut. It also checks the tyres (cylinders at the measured wheel centres), the
ground (static, `MIN_GROUND`) and the anchors. Placers search their free parameters (where
along the deck, how wide, which pitch) for the best audit and refuse the pair with a
reason when nothing passes. The long form is in scripts/vehicle-kit/docs/bodykit.md.
"""
import argparse
import json
import math
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import body_measure as bm  # noqa: E402  (read_glb, REPO, DEALER, CARS)
import body_surface as bs  # noqa: E402  (1 cm surfaces, component bounds)

REPO = bm.REPO
KIT = REPO / 'scripts/vehicle-kit'
SPEC = KIT / 'specs/lightrp-bodykit.json'
OUT = KIT / 'specs/lightrp-bodykit-fit.json'
# The cars added after the first 14 keep their design rows, style refusals and hide lists
# in data files instead of the tables below (load_extra()): every vanilla player car body.
CARS_SPEC = KIT / 'specs/lightrp-bodykit-cars.json'
HIDES = KIT / 'specs/lightrp-bodykit-hides.json'

GROUP_LABELS = {'spoiler': 'Wing / spoiler', 'louver': 'Rear louvers', 'lip': 'Front lip', 'canard': 'Canards',
                'skirt': 'Side skirts', 'diffuser': 'Rear diffuser', 'hood': 'Hood', 'roofrack': 'Roof',
                'bullbar': 'Front protection'}

# Per-car design choices read off the centre-line profiles (Root frame).
#   deck      [rear edge y, front limit y] of the rear deck a pedestal wing may stand on;
#   roofEdge  y of the roof's rear edge on hatches (duck, lip, rally wing sit there);
#   rackYs    roof run for the roof items when the measured one is wrong;
#   rackFeetX feet half-spacing when the default (roof half-width - 7 cm) misses;
#   body      what the car is, for the exclusion reasons.
DESIGN = {
    'hella':    {'body': 'four-door saloon', 'deck': (-2.80, -1.97)},
    'quartz':   {'body': 'two-door coupe with a short sloped deck', 'deck': (-2.33, -1.86)},
    'bandit':   {'body': 'raider rebuild of the Quartz', 'deck': (-2.20, -1.82)},
    'cortes':   {'body': 'four-door saloon', 'deck': (-2.88, -2.02)},
    'thrax':    {'body': 'luxury saloon', 'deck': (-3.08, -2.15)},
    'semimaru': {'body': 'mid-engine supercar', 'deck': (-2.25, -1.90)},
    # Staff-only in Light RP. deck = the housing of its active rear wing (wing_a/b/c, hidden
    # by a kit spoiler): from the tail's top edge (-2.26) to the housing's front wall, 3 cm
    # behind the engine cover (trunk_a, a lid) so no stand rests on the lid's edge.
    'caliburn': {'body': 'mid-engine hypercar with an active rear wing', 'deck': (-2.26, -1.97)},
    'hozuki':   {'body': 'fastback coupe (sloped hatch, factory wing on most trims)', 'deck': (-2.12, -1.25)},
    'maimai':   {'body': 'rear-engined city micro-hatch', 'roofEdge': -0.70},
    'galena':   {'body': 'compact hatch', 'roofEdge': -1.27, 'rackFeetX': 0.40, 'rackYs': (-1.05, 0.25)},
    'colby':    {'body': 'hatch / estate', 'roofEdge': -2.06},
    'supron':   {'body': 'panel van with barn doors', 'roofEdge': -1.80},
    'columbus': {'body': 'freight van with barn doors', 'roofEdge': -2.45},
    'merrimac': {'body': 'off-road pickup (open bed behind the cab)', 'roofEdge': -1.10, 'rackYs': (-0.95, 0.75)},
}

# Stock components a kit part replaces, by group (unknown names are skipped by the client,
# so other trims' names are listed too). Names come from the extracted .app files.
HIDE = {
    'spoiler': {'galena': ['trunk_spoiler', 'trunk_spoiler_shadow'],
                'hozuki': ['wing_a', 'wing_a_shadow'],
                'maimai': ['v_standard2_makigai_maimai__ext01_spoiler_gt_01', 'v_standard2_makigai_maimai__ext01_spoiler_gt_01_shadow'],
                # The active rear wing: wing_a (centre) + wing_b/wing_c (blades), _02 on other trims.
                'caliburn': [f'wing_{w}_{n}{s}' for n in ('01', '02') for w in 'abc' for s in ('', '_shadow')]},
    'lip': {'quartz': ['bumper_lip_f_01']},
    'skirt': {'columbus': ['jammer_skirts_01']},
    # colby junk_solar: the roof solar panel of the Suburban II and Worn trims (suburban_2*, poor_2*, 11 of
    # its 27 appearances, inventory/body_hides.py), which the player appearance lacks.
    'roofrack': {'colby': ['roof_rack', 'v_common_suitcase_01', 'junk_solar'], 'supron': ['junk_solar'], 'galena': ['junk_solar'],
                 'hella': ['junk_solar_01'], 'quartz': ['junk_solar'], 'maimai': ['junk_solar_01'], 'hozuki': ['junk_solar'],
                 'merrimac': ['body_rack']},
}

# Pairs refused on style or on a fact the surfaces cannot show, keyed by (group or part id,
# car). Measured refusals (cuts, floats, ground, tyres, slopes) are computed below.
VAN = 'flat vertical rear with split barn doors (trunk_a/trunk_b)'
STYLE_EXCLUDE = {
    ('spoiler', 'merrimac'): 'off-road pickup: the space behind the cab is an open bed; no deck to stand on',
    ('lip', 'merrimac'): 'off-road pickup: a splitter cuts the approach angle the body is built around',
    ('canard', 'merrimac'): 'off-road pickup: aero canards on a lifted off-roader are off-style',
    ('diffuser', 'merrimac'): 'off-road pickup: a diffuser under the bed cuts the departure angle the body is built around',
    ('skirt', 'merrimac'): 'off-road pickup: side steps (body_step) on 36 of its appearances and sill flares 12 cm outboard of the doors',
    ('skirt', 'maimai'): 'city micro-hatch: a factory side-step tube runs under the doors at the sill line, so a skirt would hang below it',
    ('skirt', 'hella'): ('player trim: its factory body kit (body_player_01) already carries flared rocker panels from arch to arch, '
                         'so a skirt would hang under their lip as a loose bar'),
    ('canard', 'supron'): 'panel van: aero canards on a utility van are off-style',
    ('canard', 'columbus'): 'freight van: aero canards on a freight van are off-style',
    ('diffuser', 'columbus'): 'freight van: a diffuser under barn doors and a step bumper is off-style',
    ('diffuser', 'supron'): 'panel van: a diffuser under barn doors is off-style',
    ('roof_rack', 'semimaru'): 'mid-engine supercar with the lowest roof of the 13 (0.92 m above the axle): a basket reads as a joke; geometry would fit',
    ('roof_tray', 'semimaru'): 'mid-engine supercar with the lowest roof of the 13: an expedition tray is off-style',
    ('roof_bars', 'semimaru'): 'mid-engine supercar with the lowest roof of the 13: load bars are off-style',
    ('roof_lightbar', 'semimaru'): 'mid-engine supercar: an off-road light bar is off-style',
    ('roof_scoop', 'supron'): 'panel van: a roof scoop on a van roof is off-style',
    ('roof_scoop', 'columbus'): 'freight van: a roof scoop on a van roof is off-style',
    ('roof_scoop', 'merrimac'): 'off-road pickup: a race roof scoop on the cab is off-style',
    ('roofrack', 'bandit'): 'factory rooftop fan add-ons (ventilation_rooftop_large_01_a_addon_fan_*) the offline assembly could not place; '
                            'they probably sit on the roof; enable only after seeing the roof in game',
    ('hood', 'bandit'): 'raider rebuild: the hood panel (hood_a_02) is a 0.78 m wide strip around an exposed engine; nothing to sit on',
    ('hood_scoop', 'semimaru'): 'mid-engine supercar: no engine under the front lid, a ram scoop there is off-style',
    ('hood_scoop', 'supron'): 'panel van: a ram scoop on a van nose is off-style',
    ('hood_scoop', 'columbus'): 'freight van: a ram scoop on a van nose is off-style',
    ('bull_bar', 'semimaru'): 'mid-engine supercar: a push bar on a splitter nose is off-style',
    ('roof_rack', 'caliburn'): 'mid-engine hypercar with the lowest roof of the 14 (0.83 m above the axle): a basket reads as a joke',
    ('roof_tray', 'caliburn'): 'mid-engine hypercar with the lowest roof of the 14: an expedition tray is off-style',
    ('roof_bars', 'caliburn'): 'mid-engine hypercar with the lowest roof of the 14: load bars are off-style',
    ('roof_lightbar', 'caliburn'): 'mid-engine hypercar: an off-road light bar is off-style',
    ('hood_scoop', 'caliburn'): 'mid-engine hypercar: the front lid (hood_a) covers a trunk, not an engine; a ram scoop there is off-style',
    ('bull_bar', 'caliburn'): 'mid-engine hypercar: a push bar on a splitter nose is off-style',
    ('wing_roof', 'caliburn'): ('no roof edge: the roof runs into the engine cover and its glass with no step (the centre line '
                                'falls 3 to 10 degrees all the way to the wing housing), so a roof spoiler has no edge to sit on'),
    ('wing_drift', 'thrax'): 'luxury saloon: a time-attack wing on the Thrax is off-style (the street, ducktail, lip and low wings suit it)',
    ('wing_drift', 'cortes'): 'four-door saloon: a time-attack wing on the Cortes is off-style',
}
# Fits corrected in game, which replace the offline placement (offset/rotation/scale given)
# and are written with estimate = "in_game". Keyed by (part id, car).
# 2026-11-06, lab 11855, /lightrp.lab refit: on the Archer Hella player the three lips sat
# 4.6 cm behind the nose on the bumper_f_01 bottom, behind and above the two stock lower
# plates of bumper_f_player_01, which the surfaces do not report as a visibility cut: only a
# 1 cm edge showed between the plates. 18 cm forward and 7 cm down, the blade rests under
# the plates' leading edge and shows across the whole front, its tip a few cm ahead of them.
IN_GAME = {
    ('lip_splitter', 'hella'): {'offset': [0.0, 2.676, -0.666]},
    ('lip_race', 'hella'): {'offset': [0.0, 2.676, -0.666]},
    ('lip_street', 'hella'): {'offset': [0.0, 2.646, -0.664]},
}
PEDESTAL_NEEDS_DECK = ('no rear deck: the {body} ends in a sloped or vertical rear, so a pedestal wing has nowhere level to stand '
                       '(the {roof_parts} sit on the roof edge instead)')

MIN_GROUND = 0.05      # lowest acceptable static gap between a part and the ground
MAX_SINK = 0.08        # how deep stands/feet may enter a sloped surface
CUT_TOL = 0.006        # samples deeper than this inside the body (outside embed boxes) are cuts
CUT_MAX = 0.012        # a visible cut deeper than this refuses the pair
WHEEL_MARGIN = 0.025   # clearance kept around the tyres (static)
TYRE_WIDTH = 0.26
ROOF_WING_Z = 0.55     # z scale of a pedestal wing standing on a hatch's roof edge
BAR_CLEAR = 0.02       # gap kept between a push bar's hoop and the front face
BAR_REACH = 0.24       # longest bare mounting arm between the hoop and the bumper


def r3(v):
    return [round(float(x), 3) for x in v]


def r1(v):
    return round(float(v), 1)


def cm(v):
    return f'{v * 100:.1f}'.rstrip('0').rstrip('.') + ' cm'


# --------------------------------------------------------------------------- frames
class Pose:
    """scale -> pitch about +X (right-handed: +Y toward +Z) -> offset."""

    def __init__(self, off=(0.0, 0.0, 0.0), scale=(1.0, 1.0, 1.0), pitch=0.0):
        self.off, self.scale, self.pitch = tuple(off), tuple(scale), float(pitch)
        a = math.radians(self.pitch)
        self.c, self.s = math.cos(a), math.sin(a)

    def apply(self, v):
        x, y, z = v[0] * self.scale[0], v[1] * self.scale[1], v[2] * self.scale[2]
        y, z = y * self.c - z * self.s, y * self.s + z * self.c
        return (x + self.off[0], y + self.off[1], z + self.off[2])

    def moved(self, dx=0.0, dy=0.0, dz=0.0):
        return Pose((self.off[0] + dx, self.off[1] + dy, self.off[2] + dz), self.scale, self.pitch)


# --------------------------------------------------------------------------- car
class Car:
    def __init__(self, key, meas, surf, comps):
        self.key, self.m, self.s, self.comps = key, meas, surf, comps
        self.base = meas['baseBone']['translation']
        if any(abs(q) > 1e-6 for q in meas['baseBone']['rotation'][:3]):
            raise SystemExit(f'{key}: Base bone is rotated; this fit assumes a pure translation')
        self.ground = meas['groundZ']
        self.w = meas['wheels']

    def to_base(self, p):
        return [p[0] - self.base[0], p[1] - self.base[1], p[2] - self.base[2]]

    # --- surfaces
    def surface(self, direction, p):
        """The body surface a contact point resting `direction` meets, along its axis."""
        x, y, z = p
        s = self.s
        if direction == 'down':
            return s.top(x, y)
        if direction == 'up':
            return s.bottom(x, y)
        if direction == 'out':
            return s.right(y, z) if x >= 0 else s.left(y, z)
        if direction == 'fwd':
            return s.front(x, z)
        if direction == 'back':
            return s.rear(x, z)
        raise ValueError(direction)

    def gap(self, direction, p):
        """Signed gap of a contact point (> 0 floats off the body, < 0 is inside it)."""
        v = self.surface(direction, p)
        if v is None:
            return None
        x, y, z = p
        if direction == 'down':
            return z - v
        if direction == 'up':
            return v - z
        if direction == 'out':
            return x - v if x >= 0 else v - x
        if direction == 'fwd':
            return y - v
        return v - y

    def hull_depth(self, x, y, z):
        """How deep (x, y, z) lies inside the body's visual hull (> 0 inside), else None."""
        s = self.s
        t, b = s.top(x, y), s.bottom(x, y)
        if t is None or b is None or not (b < z < t):
            return None
        r, l = s.right(y, z), s.left(y, z)
        if r is None or l is None or not (l < x < r):
            return None
        f, rr = s.front(x, z), s.rear(x, z)
        if f is None or rr is None or not (rr < y < f):
            return None
        return min(t - z, z - b, r - x, x - l, f - y, y - rr)

    def wheel_depth(self, x, y, z):
        """How deep a point lies inside a tyre plus WHEEL_MARGIN (> 0), else None."""
        w = self.w
        best = None
        for wy, r in ((w['frontY'], w['tireRadius'][0]), (w['backY'], w['tireRadius'][1])):
            if abs(abs(x) - w['trackHalf']) > TYRE_WIDTH / 2 + WHEEL_MARGIN:
                continue
            d = r + WHEEL_MARGIN - math.hypot(y - wy, z - w['centreZ'])
            if d > 0 and (best is None or d > best):
                best = d
        return best

    def top_line(self, x, y0, y1, step=0.01):
        out = []
        n = max(1, int(round(abs(y1 - y0) / step)))
        for i in range(n + 1):
            y = y0 + (y1 - y0) * i / n
            out.append((y, self.s.top_near(x, y, 0.01)))
        return out

    def surface_half_width(self, y, z_ref, tol=0.06, step=0.01):
        """Half-width of the top surface at row y within tol of z_ref."""
        best = 0.0
        for side in (-1, 1):
            x = 0.0
            while abs(x) < 1.6:
                t = self.s.top_near(x, y, 0.006)
                if t is None or t < z_ref - tol:
                    break
                best = max(best, abs(x))
                x += side * step
        return best or None

    def comp(self, pattern, centred=False, min_width=0.0, y_sign=0):
        import re
        rx = re.compile(pattern)
        hits = []
        for name, c in self.comps.items():
            if not rx.search(name):
                continue
            lo, hi = c['lo'], c['hi']
            if centred and abs((lo[0] + hi[0]) / 2) > 0.12:
                continue
            if hi[0] - lo[0] < min_width:
                continue
            if y_sign and (lo[1] + hi[1]) / 2 * y_sign <= 0:
                continue
            hits.append((name, c))
        hits.sort(key=lambda t: -(t[1]['hi'][0] - t[1]['lo'][0]))
        return hits[0] if hits else (None, None)

    def roof_edge(self, d):
        """y and z of the roof's rear edge on the centre line: the design value, else a sharp
        step (3 cm of fall within 4 cm: a roof ridge over a lower glass) found within 15 cm
        behind the first point where the top falls faster than 20 degrees, else that point."""
        if 'roofEdge' in d:
            y = d['roofEdge']
            return y, self.s.top_near(0.0, y + 0.02, 0.01)
        top = lambda yy: self.s.top_near(0.0, yy, 0.01)  # noqa: E731
        ys = self.m['roof']['ys']
        y = (ys[0] + ys[1]) / 2
        last = top(y)
        soft = None
        while y > self.m['bounds'][0][1] + 0.1:
            z0, z1 = top(y), top(y - 0.06)
            if z0 is None or z1 is None:
                break
            if (z0 - z1) / 0.06 > math.tan(math.radians(20)):
                soft = (y, z0)
                break
            last = z0
            y -= 0.01
        if soft is None:
            return y, last
        yy = soft[0] + 0.02
        while yy > soft[0] - 0.15:
            z0, z1 = top(yy), top(yy - 0.04)
            if z0 is not None and z1 is not None and z0 - z1 > 0.03:
                return yy, z0
            yy -= 0.01
        return soft


# --------------------------------------------------------------------------- parts
def sample_triangle(a, b, c, spacing):
    n = max(1, int(math.ceil(max(math.dist(a, b), math.dist(b, c), math.dist(c, a)) / spacing)))
    out = []
    for i in range(n + 1):
        for j in range(n + 1 - i):
            u, v = i / n, j / n
            out.append(tuple(a[k] + (b[k] - a[k]) * u + (c[k] - a[k]) * v for k in range(3)))
    return out


class Part:
    def __init__(self, spec_part, meta, glb):
        self.id, self.kind = spec_part['id'], spec_part['kind']
        self.group = self.kind
        self.params = spec_part.get('params') or {}
        self.style = self.params.get('style') or meta.get('mount', {}).get('style')
        self.meta = meta
        self.mount = meta.get('mount', {})
        self.bounds = meta['bounds']
        self.tris = bm.read_glb(glb)
        embed = self.mount.get('embed', [])
        seen, samples = set(), []
        for t in self.tris:
            for p in sample_triangle(*t, spacing=0.035):
                k = tuple(round(c, 3) for c in p)
                if k in seen:
                    continue
                seen.add(k)
                inside = any(all(lo[i] - 1e-6 <= p[i] <= hi[i] + 1e-6 for i in range(3)) for lo, hi in embed)
                samples.append((p, inside))
        self.samples = samples
        self.contacts = [(c['dir'], [tuple(p) for p in c['pts']]) for c in self.mount.get('contact', [])]
        self.anchors = [tuple(a) for a in self.mount.get('anchors', [])]
        self.low = min(p[2] for t in self.tris for p in t)


# --------------------------------------------------------------------------- solver + audit
def contact_gaps(car, part, pose, which=None):
    """[(gap or None, world point)] of the part's contact points under pose."""
    out = []
    for direction, pts in part.contacts:
        for i, p in enumerate(pts):
            if which is not None and i not in which:
                continue
            w = pose.apply(p)
            out.append((car.gap(direction, w), w, direction))
    return out


AXIS = {'down': (0, 0, 1), 'up': (0, 0, -1), 'fwd': (0, 1, 0), 'back': (0, -1, 0)}


def rest(car, part, pose, sink, which=None, min_hits=0.6):
    """Move the pose along the contact direction so no contact floats while at most `sink`
    enters the body. Returns (pose, stats) or (None, reason)."""
    gaps = contact_gaps(car, part, pose, which)
    if not gaps:
        return pose, {'float': 0.0, 'sink': 0.0, 'hits': 0}
    direction = gaps[0][2]
    vals = [g for g, _, _ in gaps if g is not None]
    if len(vals) < max(1, min_hits * len(gaps)):
        return None, f'{len(gaps) - len(vals)} of {len(gaps)} contact points find no body surface ({direction})'
    gmin, gmax = min(vals), max(vals)
    delta = -gmax if gmax - gmin <= sink else -sink - gmin
    ax = AXIS.get(direction)
    if ax is None:
        raise ValueError('rest() moves along down/up/fwd/back only')
    pose = pose.moved(ax[0] * delta, ax[1] * delta, ax[2] * delta)
    return pose, {'float': round(max(0.0, gmax + delta), 4), 'sink': round(max(0.0, -(gmin + delta)), 4),
                  'hits': len(vals), 'points': len(gaps)}


def spread(car, part, pose, which=None):
    vals = [g for g, _, _ in contact_gaps(car, part, pose, which) if g is not None]
    return (max(vals) - min(vals)) if vals else None


def best_pitch(car, part, pose, lo, hi, step=0.5, which=None, pivot=None):
    """Pitch (degrees) in [lo, hi] that makes the contact gaps most even."""
    best = None
    k = lo
    while k <= hi + 1e-9:
        p = Pose(pose.off, pose.scale, k)
        sp = spread(car, part, p, which)
        if sp is not None and (best is None or sp < best[0] - 1e-6):
            best = (sp, k)
        k += step
    return best[1] if best else pose.pitch


def audit(car, part, pose, visible=None):
    """Cuts, tyre hits, ground gap and anchors of a placed part. `visible(world point)` may
    mark samples that cannot be seen (their cuts are noted, not refused)."""
    cut, cut_at, n_cut, hidden_cut = 0.0, None, 0, 0.0
    wheel, ground = 0.0, 9.0
    for p, embedded in part.samples:
        w = pose.apply(p)
        ground = min(ground, w[2] - car.ground)
        wd = car.wheel_depth(*w)
        if wd is not None and not embedded:
            wheel = max(wheel, wd)
        if embedded:
            continue
        d = car.hull_depth(*w)
        if d is not None and d > CUT_TOL:
            if visible is not None and not visible(w):
                hidden_cut = max(hidden_cut, d)
                continue
            n_cut += 1
            if d > cut:
                cut, cut_at = d, w
    out_anchors = []
    for a in part.anchors:
        w = pose.apply(a)
        d = car.hull_depth(*w)
        if d is None:
            out_anchors.append(w)
    return {'cut': round(cut, 4), 'cutAt': r3(cut_at) if cut_at else None, 'cutSamples': n_cut,
            'hiddenCut': round(hidden_cut, 4), 'wheel': round(wheel, 4), 'ground': round(ground, 4),
            'anchorsOut': len(out_anchors), 'anchors': len(part.anchors)}


def verdict(a, min_ground=MIN_GROUND):
    if a['cut'] > CUT_MAX:
        return f"cuts {cm(a['cut'])} into the body at y {a['cutAt'][1]:.2f}, z {a['cutAt'][2]:.2f}"
    if a['wheel'] > 0:
        return f"comes within {cm(WHEEL_MARGIN - a['wheel'])} of a tyre (needs {cm(WHEEL_MARGIN)})"
    if a['ground'] < min_ground:
        return f"only {cm(a['ground'])} from the ground at rest (min {cm(min_ground)})"
    if a['anchorsOut']:
        return f"{a['anchorsOut']} of {a['anchors']} anchor points (rod or tongue ends) would stand outside the body"
    return None


def score(st, a):
    """Lower is better: floats weigh most, then cuts, sink."""
    return st['float'] * 6 + a['cut'] * 4 + st['sink'] * 0.5 + (1.0 if verdict(a) else 0.0)


# --------------------------------------------------------------------------- placers
def body_half_width(car, y0, y1, z0=-9.0, z1=9.0):
    return car.s.half_width(min(y0, y1), max(y0, y1), z0, z1)


def place_spoiler(car, part, d):
    style = part.style or 'street'
    if style in ('duck', 'lip'):
        return place_surface_wing(car, part, d)
    if style == 'roof':
        return place_roof_spoiler(car, part, d)
    return place_pedestal(car, part, d)


def place_pedestal(car, part, d):
    style = part.style or 'street'
    m = part.mount
    fp = m['footprintY']
    te, le = part.bounds[0][1], part.bounds[1][1]
    half_span = part.bounds[1][0]
    body_rear = car.m['bounds'][0][1]
    notes = []
    if 'deck' in d:
        rear, front = d['deck']
        mode = 'deck'
        lo = max(rear - fp[0], body_rear - 0.05 - te)      # feet on the deck, TE at most 5 cm past the body
        hi = front - fp[1]
        pref = min(max(rear - te, lo), hi)                  # TE flush with the deck's rear edge
    elif 'roofEdge' in d and style == 'rally' and d['body'].find('van') < 0:
        mode = 'roof edge'
        lo = hi = pref = d['roofEdge'] + 0.045 - fp[0]      # rear of the feet 4.5 cm ahead of the edge
    elif 'roofEdge' in d:
        roof_parts = 'ducktail, lip and roof spoiler' if 'van' in d['body'] else 'ducktail, lip, roof spoiler and rally wing'
        return None, PEDESTAL_NEEDS_DECK.format(body=d['body'], roof_parts=roof_parts)
    else:
        return None, f"no deck and no roof edge on this {d['body']}"
    if hi < lo:
        return None, 'deck too short for the feet'
    zdeck = car.s.top_near(0.0, pref, 0.02) or 0.0
    hw_body = body_half_width(car, pref + te, pref + le, zdeck - 0.15, zdeck + 0.6) or 0.8
    limit = hw_body - 0.06
    if mode == 'roof edge':
        roof_hw = car.surface_half_width(pref, zdeck, 0.08)
        if roof_hw:
            limit = min(limit, roof_hw + 0.05)
    sx = max(0.75, min(1.1, limit / half_span))
    sz = ROOF_WING_Z if mode == 'roof edge' else 1.0
    if sz != 1.0:
        notes.append(f'roof mount: stands and end plates shortened by z scale {sz}')
    n = max(1, int(round((hi - lo) / 0.02)))
    ys = sorted({round(lo + i * (hi - lo) / n, 4) for i in range(n + 1)} | {round(pref, 4)}, key=lambda y: abs(y - pref))
    trials = []
    for y in ys:
        pose, st = rest(car, part, Pose((0.0, y, 0.0), (sx, 1.0, sz)), MAX_SINK, min_hits=1.0)
        if pose is None:
            continue
        a = audit(car, part, pose)
        trials.append((y, pose, st, a))
        if st['sink'] <= 0.03 and st['float'] <= 0.002 and a['cut'] <= CUT_TOL and not verdict(a):
            break
    if not trials:
        return None, f'the feet find no {mode} surface under them anywhere along it'
    y, pose, st, a = min(trials, key=lambda t: (score(t[2], t[3]), abs(t[0] - pref)))
    v = verdict(a)
    if v:
        return None, f'{v} wherever the feet stand on the {mode}'
    if st['sink'] > MAX_SINK - 1e-6 and st['float'] > 0.005:
        return None, f"the {mode} slopes more than {cm(MAX_SINK)} under the feet wherever they stand"
    if st['sink'] > 0.03:
        notes.append(f"{mode} slopes under the feet: the stands enter the surface up to {cm(st['sink'])} at their high side")
    if abs(y - pref) > 0.011:
        notes.append(f'moved {(y - pref) * 100:+.0f} cm from the trailing-edge-flush position to sit flat and clear the body')
    past = body_rear - (y + te)
    if past > 0.005:
        notes.append(f'trailing edge {cm(past)} past the rear of the body')
    ev = {'mode': mode, 'teY': round(y + te, 3), 'bodyHalfWidth': round(hw_body, 3), 'span': round(2 * half_span * sx, 3)}
    return dict(pose=pose, st=st, a=a, ev=ev, notes=notes, contact=[(fx * sx, y) for fx, _ in m['feet']]), None


def place_surface_wing(car, part, d):
    """Ducktail / trunk lip: trailing edge on the deck's (or roof's) rear edge, or as close
    ahead of it as the surface lets the flat-bottomed part sit, pitched to the surface and
    narrowed until its crown matches."""
    chord = part.bounds[1][1]
    half_span = part.bounds[1][0]
    if 'deck' in d:
        mode, edge = 'deck', d['deck'][0]
    elif 'roofEdge' in d:
        mode, edge = 'roof edge', d['roofEdge']
    else:
        return None, f"no deck and no roof edge on this {d['body']}"
    best = None
    for k in range(13):
        y = edge + 0.01 + 0.02 * k
        zc = car.s.top_near(0.0, y + chord / 2, 0.02)
        if zc is None:
            continue
        surf = car.surface_half_width(y + chord / 2, zc, 0.12) or half_span
        sx = sx0 = max(0.6, min(1.3, (surf - 0.03) / half_span))
        while True:
            base = Pose((0.0, y, 0.0), (sx, 1.0, 1.0))
            pitch = best_pitch(car, part, base, -16, 16, 0.5)
            pose, st = rest(car, part, Pose(base.off, base.scale, pitch), 0.025, min_hits=0.9)
            if pose is not None and st['float'] <= 0.006:
                break
            if sx <= 0.6:
                break
            sx = max(0.6, sx - 0.05)
        if pose is None:
            continue
        a = audit(car, part, pose)
        cand = (score(st, a) + 0.004 * k, y, pose, st, a, sx, pitch, k, surf, sx0)
        if best is None or cand[0] < best[0]:
            best = cand
        if st['float'] <= 0.004 and not verdict(a) and 2 * half_span * sx >= 0.9:
            break
    if best is None:
        return None, f'no {mode} surface behind the rear edge to sit on'
    _, y, pose, st, a, sx, pitch, k, surf, sx0 = best
    v = verdict(a)
    if v:
        return None, v
    if st['float'] > 0.012:
        return None, f"the {mode} is too uneven for the flat-bottomed {part.style}: {cm(st['float'])} would float wherever it sits"
    if 2 * half_span * sx < 0.9:
        if sx < sx0 - 1e-6:
            return None, (f'the {mode} crowns too much across for the flat-bottomed {part.style}: to sit flat on a '
                          f'{2 * surf:.2f} m wide {mode} it would shrink to a {2 * half_span * sx:.2f} m stub')
        return None, (f'the flat part of the {mode} is only {2 * (surf - 0.03):.2f} m wide where it would sit: '
                      f'it would shrink to a {2 * half_span * sx:.2f} m stub')
    notes = []
    if k:
        notes.append(f'set {(y - edge) * 100:.0f} cm ahead of the {mode} where the surface lets it sit')
    if st['sink'] > 0.012:
        notes.append(f"the underside enters the {mode} up to {cm(st['sink'])} where it crowns")
    if st['float'] > 0.004:
        notes.append(f"floats up to {cm(st['float'])} where the {mode} dips")
    ev = {'mode': mode, 'teY': round(y, 3), 'pitchDeg': round(pitch, 2), 'surfaceHalfWidth': round(surf, 3),
          'span': round(2 * half_span * sx, 3)}
    return dict(pose=pose, st=st, a=a, ev=ev, notes=notes, contact=[(0.0, y), (0.0, y + chord)]), None


def place_roof_spoiler(car, part, d):
    """Roof spoiler: the bonded base on the roof's last centimetres, the blade over the glass."""
    base = part.mount.get('base', 0.07)
    y_e, z_e = car.roof_edge(d)
    if z_e is None:
        return None, 'roof edge not found'
    # Roof width that stays within 2 cm of the edge's height: the bonded base must not
    # reach the roof's rolled-off sides.
    roof_hw = car.surface_half_width(y_e + 0.04, z_e, 0.02) or car.m['roof']['halfWidth']
    half = part.bounds[1][0]
    sx_max = max(0.75, min(1.3, (roof_hw - 0.06) / half))
    best = None
    sx = sx_max
    while sx >= 0.75 - 1e-6:
        for dy in (-0.06, -0.045, -0.03, -0.015, -0.005, 0.01, 0.025):
            y_o = y_e + base + dy
            p0 = Pose((0.0, y_o, 0.0), (sx, 1.0, 1.0))
            pitch0 = best_pitch(car, part, p0, -12, 15, 0.5)
            for extra in (0, 2, 4, 6, 8, 10):
                # Negative pitch lifts the blade's rear (it runs toward -Y) off the glass.
                pose, st = rest(car, part, Pose(p0.off, p0.scale, pitch0 - extra), 0.012, min_hits=0.8)
                if pose is None:
                    continue
                a = audit(car, part, pose)
                cand = (score(st, a) + 0.002 * extra + 0.05 * abs(dy + 0.005) + (sx_max - sx) * 0.05, pose, st, a, pitch0 - extra, y_o)
                if best is None or cand[0] < best[0]:
                    best = cand
                if a['cut'] <= CUT_TOL:
                    break
        if best and best[2]['float'] <= 0.008 and not verdict(best[3]):
            break
        sx = round(sx - 0.05, 3)
    if best is None:
        return None, 'the roof edge has no surface under the bonded base'
    _, pose, st, a, pitch, y_o = best
    v = verdict(a)
    if v:
        return None, f'{v}: the glass behind the roof climbs into the visor'
    if st['float'] > 0.01:
        return None, f"the roof's rear edge is too curved for the bonded base: {cm(st['float'])} would float"
    notes = []
    if st['float'] > 0.004:
        notes.append(f"base floats up to {cm(st['float'])} at its corners")
    sx = pose.scale[0]
    if sx < sx_max - 0.01:
        notes.append(f'narrowed to {2 * half * sx:.2f} m so the base rests on the roof edge')
    ev = {'mode': 'roof edge', 'roofEdgeY': round(y_e, 3), 'pitchDeg': round(pitch, 2), 'roofHalfWidth': round(roof_hw, 3),
          'span': round(2 * half * sx, 3)}
    return dict(pose=pose, st=st, a=a, ev=ev, notes=notes, contact=[(0.0, y_o - base / 2)]), None


def rear_glass(car):
    name, c = car.comp(r'^(window_b(_\d+)?$|window_b_player|window_back|trunk_a_window)', centred=True, min_width=0.6, y_sign=-1)
    return name, c


def place_louver(car, part, d):
    name, g = rear_glass(car)
    if not name:
        return None, 'no rear window panel on this body (the rear is a door or a cab wall)'
    y_top, y_bot = g['hi'][1], g['lo'][1]
    z_top, z_bot = car.s.top_near(0.0, y_top - 0.02, 0.01), car.s.top_near(0.0, y_bot + 0.02, 0.01)
    if z_top is None or z_bot is None:
        return None, f'rear glass ({name}) not found in the top surface'
    run = y_top - y_bot - 0.04
    if run < 0.08:
        return None, f'the rear glass ({name}) is a vertical cab wall: louvers lie on a sloped backlight, on an upright one they read as a cage'
    slope = math.degrees(math.atan2(z_top - z_bot, run))
    if slope > 50:
        return None, f'the rear glass ({name}) stands at {slope:.0f} degrees: louvers lie on a sloped backlight, on a near-vertical one they read as a cage'
    if slope < 8:
        return None, f'the rear glass ({name}) is nearly flat ({slope:.0f} degrees): no backlight to cover'
    glass_len = math.hypot(run, z_top - z_bot)
    L = part.mount['length']
    sy = max(0.6, min(1.5, (glass_len - 0.03) / L))
    glass_w = g['hi'][0] - g['lo'][0]
    sx = max(0.65, min(1.3, (glass_w - 0.03) / part.mount['width']))
    best = None
    sx0, sy0 = sx, sy
    for kx in (1.0, 0.92, 0.85, 0.78):
        for ky in (1.0, 0.85, 0.72):
            sx_, sy_ = sx0 * kx, sy0 * ky
            if part.mount['width'] * sx_ < 0.75 or L * sy_ < 0.35:
                continue
            for dy in (0.0, -0.02, -0.04):
                y_o = y_top - 0.015 + dy
                p0 = Pose((0.0, y_o, 0.0), (sx_, sy_, 1.0))
                pitch = best_pitch(car, part, p0, 5, 55, 0.5)
                pose, st = rest(car, part, Pose(p0.off, p0.scale, pitch), 0.008, min_hits=0.8)
                if pose is None:
                    continue
                a = audit(car, part, pose)
                cand = (score(st, a) + abs(dy) + (1 - kx) * 0.04 + (1 - ky) * 0.04, pose, st, a, pitch)
                if best is None or cand[0] < best[0]:
                    best = cand
        if best and best[2]['float'] <= 0.008 and not verdict(best[3]):
            break
    if best is None:
        return None, f'the louver pads find no glass under them ({name})'
    _, pose, st, a, pitch = best
    v = verdict(a)
    if v:
        return None, v
    if st['float'] > 0.015:
        return None, f"the rear glass curves too much for a rigid louver: {cm(st['float'])} would float"
    notes = []
    if st['float'] > 0.005:
        notes.append(f"pads float up to {cm(st['float'])} where the glass curves")
    sx, sy = pose.scale[0], pose.scale[1]
    if sx < sx0 - 0.01 or sy < sy0 - 0.01:
        notes.append(f"trimmed to {part.mount['width'] * sx:.2f} x {L * sy:.2f} m so the pads rest on the curved glass")
    ev = {'glass': name, 'glassSlopeDeg': round(slope, 1), 'pitchDeg': round(pitch, 2), 'length': round(L * sy, 3),
          'width': round(part.mount['width'] * sx, 3)}
    return dict(pose=pose, st=st, a=a, ev=ev, notes=notes, contact=[(0.0, y_top - 0.05), (0.0, y_bot + 0.05)]), None


def flat_band(car, y0, y1, zc, tol=0.025, step=0.02, limit=1.0):
    """Half-width of the band around the centre line where the body bottom stays within
    `tol` of zc on every row of [y0, y1]."""
    hw = 0.0
    x = 0.0
    while x <= limit:
        ok = True
        yy = y0
        while yy <= y1 + 1e-6 and ok:
            for sx in (-1, 1):
                v = car.s.bottom(sx * x, yy)
                if v is None or abs(v - zc) > tol:
                    ok = False
                    break
            yy += 0.02
        if not ok:
            break
        hw = x
        x += step
    return hw


def exhaust_limit(car, y0, y1, z0, z1):
    """Inner |x| of the exhaust tips whose rear 30 cm reach the box [y0, y1] x [z0, z1], per
    side, and the names. A side whose tip reaches the centre line gives 0."""
    inner, names = None, []
    for name, c in car.comps.items():
        if 'exhaust' not in name.lower() and 'muffler' not in name.lower():
            continue
        for sign, (lo, hi) in (c.get('rearSides') or {}).items():
            if hi[1] < y0 or lo[1] > y1 or hi[2] < z0 or lo[2] > z1:
                continue
            v = min(abs(lo[0]), abs(hi[0]))
            inner = v if inner is None else min(inner, v)
            names.append(name)
    return inner, sorted(set(names))


def place_lip(car, part, d):
    """Pivot on the bumper's lower edge, searched from the nose back over 45 cm (at most
    10 cm behind the face). At each row the blade is as wide as the bumper allows (from 4 cm
    inside the lower body width down to 0.9 m) while its front contact strip rests within
    2 cm, pitched up to 8 degrees to the chin. What lies more than 8 cm behind the edge is
    under the car: cuts there are noted, not refused."""
    f = car.m['front']
    mt = part.mount
    W = mt.get('width', 1.6)
    fy = f['y']
    best, seen = None, []
    for k in range(30):
        y0 = fy - 0.01 - 0.015 * k
        zc = car.s.bottom(0.0, y0 - 0.03)
        if zc is None:
            continue
        face = car.s.front(0.0, zc + 0.03)
        setback = (face - y0) if face is not None else 0.0
        if setback > 0.10:
            continue
        hw = flat_band(car, y0 - 0.06, y0 - 0.02, zc, tol=0.03)
        seen.append(2 * hw)
        # Widest blade (from 1.25x down to 0.9 m) whose contact strip rests on the bumper.
        sx = min(1.25, 2 * (f['halfWidthLow'] - 0.04) / W)
        while W * sx >= 0.9 - 1e-6:
            p0 = Pose((0.0, y0, zc), (sx, 1.0, 1.0))
            pitch = best_pitch(car, part, p0, -8, 8, 0.5)
            pose, st = rest(car, part, Pose(p0.off, p0.scale, pitch), 0.012, min_hits=0.6)
            if pose is not None and st['float'] <= 0.02:
                a = audit(car, part, pose, visible=lambda q, yv=y0: q[1] > yv - 0.08)
                cand = (score(st, a) + setback * 0.3 + abs(pitch) * 0.002 - W * sx * 0.03, pose, st, a, y0, zc, sx, pitch, setback)
                if best is None or cand[0] < best[0]:
                    best = cand
                if not verdict(a):
                    break
            sx = round(sx - 0.05, 3)
    if best is None:
        if seen:
            return None, (f'the bumper bottom is level over at most {max(seen):.2f} m across: even a 0.9 m blade would float '
                          'more than 2 cm where the chin curves up toward the corners')
        return None, 'no bumper bottom within 10 cm of the nose'
    _, pose, st, a, y0, zc, sx, pitch, setback = best
    v = verdict(a)
    if v:
        if a['anchorsOut']:
            return None, 'the support rods would stand in front of the bumper face: the nose sets back above the lip line'
        return None, v
    if st['float'] > 0.03:
        return None, f"the bumper underside climbs {cm(st['float'])} above the blade toward its tips"
    notes = []
    if st['float'] > 0.012:
        notes.append(f"bumper underside rises up to {cm(st['float'])} above the blade toward its tips")
    if a['ground'] < 0.08:
        notes.append(f"low: {cm(a['ground'])} from the ground at rest")
    if W * sx < 2 * (f['halfWidthLow'] - 0.04) - 0.05:
        notes.append(f'narrowed to {W * sx:.2f} m to rest on the bumper bottom')
    if abs(pitch) >= 3:
        notes.append(f'pitched {pitch:+.1f} degrees to follow the chin')
    if setback > 0.03:
        notes.append(f'set {cm(setback)} behind the nose, where the bumper bottom levels out')
    if a['hiddenCut'] > 0.01:
        notes.append(f"the blade's rear runs {cm(a['hiddenCut'])} into the underbody, out of sight")
    ev = {'edgeY': round(y0, 3), 'bumperBottomZ': round(zc, 3), 'width': round(W * sx, 3), 'pitchDeg': round(pitch, 2)}
    return dict(pose=pose, st=st, a=a, ev=ev, notes=notes, contact=[(0.0, y0)]), None


def place_canard(car, part, d):
    mt = part.mount
    W, span, root, tongue = mt['halfSpan'], mt['span'], mt['root'], mt['tongue']
    f = car.m['front']
    w = car.w
    arch = w['frontY'] + w['tireRadius'][0] + 0.06
    face = f['y']
    zb, zt = f['bumperBottomZ'], f['faceTopZ'] or (f['bumperBottomZ'] + 0.4)
    levels = mt.get('levels', [0.0])
    best = None
    for zf in (0.25, 0.32, 0.39, 0.46, 0.53, 0.60):
        zc = zb + zf * (zt - zb)
        y = arch + root / 2 + 0.02
        while y <= face - root / 2 - 0.06:
            xs = []
            for side in (-1, 1):
                for lv in levels:
                    for k in range(5):
                        yy = y + root / 2 - root * k / 4
                        v = car.s.right(yy, zc + lv) if side > 0 else car.s.left(yy, zc + lv)
                        xs.append(None if v is None else abs(v))
            if None not in xs:
                xmin, xmax = min(xs), max(xs)
                x_r = (xmin - 0.008) / (1 - tongue / W)       # tongue end 8 mm inside the nearest face
                sx = x_r / W
                pose = Pose((0.0, y, zc), (sx, 1.0, 1.0))
                a = audit(car, part, pose)
                bury = max(0.0, xmax - x_r)
                # Prefer a root where the tips stay within the body's width (fender included).
                hw_ = body_half_width(car, y - 0.4, y + 0.1, zc - 0.2, zc + 0.3) or xmax
                proud_ = max(0.0, (W + span) * sx - hw_ - 0.02)
                cand = (bury * 3 + a['cut'] * 4 + proud_ * 4 + (1.0 if verdict(a, 0.10) else 0.0) + abs(zf - 0.42) * 0.05,
                        pose, a, y, zc, xmin, xmax, sx)
                if best is None or cand[0] < best[0]:
                    best = cand
            y += 0.01
    if best is None:
        return None, 'no bumper side face between the front wheel arch and the nose at canard height'
    _, pose, a, y, zc, xmin, xmax, sx = best
    v = verdict(a, 0.10)
    if v:
        return None, v
    bury = max(0.0, xmax - W * sx)
    if bury > span * sx * 0.45:
        return None, f'the bumper corner curves {cm(xmax - xmin)} along the canard root: it would bury half the plane'
    notes = []
    if bury > 0.01:
        notes.append(f'the bumper corner curves: the root is buried up to {cm(bury)} at one end')
    hw = body_half_width(car, y - 0.4, y + 0.1, zc - 0.2, zc + 0.3) or xmax
    proud = (W + span) * sx - hw
    if proud > 0.05:
        return None, f'the tips would stand {cm(proud)} outboard of the widest body panel at their height (5 cm at most)'
    if proud > 0.02:
        notes.append(f'tips stand {cm(proud)} outboard of the body width')
    st = {'float': 0.0, 'sink': round(bury, 4)}
    ev = {'archY': round(arch, 3), 'rootY': round(y, 3), 'rootZ': round(zc, 3), 'sideX': [round(xmin, 3), round(xmax, 3)],
          'tipProud': round(proud, 3)}
    return dict(pose=pose, st=st, a=a, ev=ev, notes=notes, contact=[(xmin, y)]), None


def place_skirt(car, part, d):
    s = car.m['sill']
    mt = part.mount
    outer = mt.get('outer', mt.get('halfSpan', 1.0))
    length, drop = mt.get('length', 2.0), mt.get('drop', 0.07)
    prof = []
    y = s['y0']
    while y <= s['y1'] + 1e-6:
        v = [abs(c[2]) for side in (-1, 1) for c in car.s.side_cells(y - 0.005, y + 0.005, s['z'], s['z'] + 0.10, side)]
        if v:
            prof.append((y, max(v)))
        y += 0.02
    if len(prof) < 5:
        return None, 'sill line not found between the wheel arches'
    ws = sorted(w for _, w in prof)
    median = ws[len(ws) // 2]
    room = s['z'] - car.ground - 0.07
    sz = min(1.0, room / drop)
    if sz < 0.45:
        return None, f"sill only {cm(s['z'] - car.ground)} above the ground: a skirt would have to be squashed below 45 %"
    # Outer face 1.5 cm proud of the median sill, arch to arch. If it cuts a bulge, step out
    # to a higher percentile of the sill line.
    run = (s['y0'], s['y1'])
    for q in (0.5, 0.7, 0.85, 0.95):
        med = ws[min(len(ws) - 1, int(len(ws) * q))]
        sx = (med + 0.015) / outer
        pose = Pose((0.0, (run[0] + run[1]) / 2, s['z']), (sx, (run[1] - run[0]) / length, sz))
        a = audit(car, part, pose)
        v = verdict(a)
        if not v:
            break
    if v:
        return None, v
    inside = sorted(w for y_, w in prof if run[0] <= y_ <= run[1])
    notes = []
    if q > 0.5:
        notes.append(f'set out to the {q * 100:.0f}th percentile of the sill line, {cm(med - median)} past its median, to clear a bulge')
    if sz < 1.0:
        notes.append(f'height squashed to {sz * 100:.0f} % to keep 7 cm to the ground')
    flare = inside[-1] - med
    tuck = med - inside[max(0, len(inside) // 10)]
    if q > 0.5 and tuck > 0.05:
        return None, f'the sill bulges locally: a skirt that clears it stands {cm(tuck)} off the rest of the sill'
    # The same 5 cm on the median line: a sill that tucks in further (an open arch liner, a
    # tube step, an armour recess) leaves the skirt as a loose bar. The first 14 tuck 4.2 cm
    # at most (quartz).
    if tuck > 0.05:
        return None, f'the sill tucks in {cm(tuck)} in places: a skirt would stand off the body there (5 cm at most)'
    if flare > 0.03:
        notes.append(f'sill flares {cm(flare)} out near the arches: the skirt ends sit inside that flare')
    if tuck > 0.03:
        notes.append(f'sill tucks in {cm(tuck)} in places: the skirt stands off the body there')
    st = {'float': round(max(0.0, tuck - 0.03), 4), 'sink': 0.0}
    ev = {'sillZ': s['z'], 'sillMedianX': round(med, 3), 'sillMaxX': round(ws[-1], 3), 'run': [round(run[0], 3), round(run[1], 3)]}
    return dict(pose=pose, st=st, a=a, ev=ev, notes=notes, contact=[(med, run[0]), (med, run[1])]), None


def place_diffuser(car, part, d):
    """The plate's rear edge at the bumper's lower rear edge, as far back as a level band of
    the bumper bottom wide enough for it lets; narrowed to that band, to the exhaust tips
    and to the tyres; pitched to follow the bumper bottom along the centre line (a diffuser
    ramp rises toward the exit) and rested on its rear 5 cm. Refused where the bumper bottom
    comes down more than 5 cm below the plate within 15 cm of its exit: the plate would then
    stick out of the bumper face as a ledge above the lower bumper instead of closing it."""
    ry = car.m['rear']['y']
    W, D = part.mount['width'], part.mount.get('depth', 0.3)
    w = car.w
    tyre_hw = w['trackHalf'] - TYRE_WIDTH / 2 - 0.05
    best, seen = None, []
    for k in range(24):
        y0 = ry + 0.02 * k
        zc = car.s.bottom(0.0, y0 + 0.04)
        if zc is None:
            continue
        face = car.s.rear(0.0, zc + 0.03)
        setback = y0 - face if face is not None else 0.0
        if setback > 0.10:
            continue
        hw = flat_band(car, y0 + 0.01, y0 + 0.05, zc)
        lim, tips = exhaust_limit(car, y0 - 0.05, y0 + D + 0.05, zc - 0.25, zc + 0.08)
        why = 'band'
        if lim is not None and lim - 0.05 < hw:
            hw, why = lim - 0.05, 'exhaust'
        if y0 + D > w['backY'] - w['tireRadius'][1] - 0.1 and tyre_hw < hw:
            hw, why = tyre_hw, 'tyres'
        sx = min(1.3, 2 * hw / W)
        seen.append((W * sx, why, tips, 0.0))
        if W * sx < 0.5:
            continue
        zf = car.s.bottom(0.0, y0 + 0.8 * D)
        pitch = 0.0 if zf is None else max(-20.0, min(15.0, math.degrees(math.atan2(zf - zc, 0.8 * D - 0.03))))
        pitch = round(pitch * 2) / 2
        pose, st = rest(car, part, Pose((0.0, y0, zc), (sx, 1.0, 1.0), pitch), 0.01, min_hits=0.9)
        if pose is None:
            continue
        tan_p = math.tan(math.radians(pitch))
        under = []
        for i in range(-4, 5):
            for j in range(1, 6):
                yy = y0 + 0.03 * j
                b = car.s.bottom(hw * i / 4, yy)
                if b is not None:
                    under.append(b - (pose.off[2] + (yy - y0) * tan_p))
        if under and min(under) < -0.05:
            seen.append((W * sx, 'ledge', tips, -min(under)))
            continue
        a = audit(car, part, pose, visible=lambda q, yv=y0: q[1] < yv + 0.10)
        cand = (score(st, a) + setback * 0.4 + (1.3 - sx) * 0.05, pose, st, a, y0, zc, sx, why, tips, setback, pitch)
        if best is None or cand[0] < best[0]:
            best = cand
    if best is None:
        if seen:
            ledges = [t for t in seen if t[1] == 'ledge']
            if ledges:
                drop = min(t[3] for t in ledges)
                return None, (f'the rear bumper bottom comes down {cm(drop)} or more just ahead of its rear edge: the plate would '
                              'stick out of the bumper face as a ledge instead of closing its bottom')
            wmax, why, tips, _ = max(seen, key=lambda t: t[0])
            if why == 'exhaust' and wmax < 0.15:
                return None, f"the exhaust ({', '.join(tips)}) runs under the centre of the rear bumper, where the diffuser would sit"
            if why == 'exhaust':
                return None, f"the exhaust ({', '.join(tips)}) exits within the bumper bottom: at most {wmax:.2f} m between the tips (needs 0.5 m)"
            if wmax < 0.1:
                return None, 'the rear bumper bottom is not level even on the centre line: it steps within 5 cm of its rear edge'
            return None, f'the rear bumper bottom is level over at most {wmax:.2f} m across (needs 0.5 m): the underside steps or curves'
        return None, 'no rear bumper bottom within 10 cm of the rear face: a plate there would sit out of sight under the bumper'
    _, pose, st, a, y0, zc, sx, why, tips, setback, pitch = best
    v = verdict(a, 0.07)
    if v:
        return None, v
    if st['float'] > 0.015:
        return None, f"the bumper bottom is too uneven across its width: the plate would hang {cm(st['float'])} below it"
    notes = []
    if why == 'exhaust':
        notes.append(f'narrowed to {W * sx:.2f} m to end inboard of the exhaust tips ({", ".join(tips)})')
    elif why == 'tyres':
        notes.append(f'narrowed to {W * sx:.2f} m to keep clear of the rear tyres')
    elif sx < 0.98:
        notes.append(f'narrowed to {W * sx:.2f} m: the bumper bottom is level over that width only')
    if setback > 0.03:
        notes.append(f'rear edge {cm(setback)} under the bumper face')
    if st['float'] > 0.006:
        notes.append(f"plate hangs up to {cm(st['float'])} below the bumper at its corners")
    if a['hiddenCut'] > 0.01:
        notes.append(f"the plate's front runs {cm(a['hiddenCut'])} into the underbody, out of sight")
    ev = {'rearEdgeY': round(y0, 3), 'bumperBottomZ': round(zc, 3), 'width': round(W * sx, 3), 'pitchDeg': round(pitch, 2),
          'exhaust': tips}
    return dict(pose=pose, st=st, a=a, ev=ev, notes=notes, contact=[(0.0, y0)]), None


def front_hood(car):
    name, c = car.comp(r'^hood', y_sign=1)
    if name:
        return name, c['lo'][1], c['hi'][1], (c['hi'][0] - c['lo'][0]) / 2
    wname, w = car.comp(r'^window_f$')
    if not wname:
        return None, None, None, None
    y0 = w['hi'][1] + 0.05
    y1 = car.m['front']['y'] - 0.25
    hw = body_half_width(car, y0, y1) or 0.7
    return 'front deck', y0, y1, hw - 0.1


def place_hood(car, part, d):
    name, y0, y1, hw = front_hood(car)
    if not name or y1 - y0 < 0.55:
        return None, 'no front hood long enough (0.55 m) to carry it'
    style = part.style or 'scoop'
    frac = 0.50 if style == 'scoop' else 0.58
    yc = y0 + frac * (y1 - y0)
    fracs = [frac] + [f for f in (0.40, 0.45, 0.55, 0.62, 0.68) if abs(f - frac) > 0.02]
    slope = None
    za, zb_ = car.s.top_near(0.0, yc - 0.15, 0.01), car.s.top_near(0.0, yc + 0.15, 0.01)
    if za is not None and zb_ is not None:
        slope = math.degrees(math.atan2(za - zb_, 0.30))
    if slope is not None and slope > 24:
        return None, f'the hood slopes {slope:.0f} degrees: a flat-based part would stand off it'
    size = part.mount.get('size', [0.5, 0.5])
    sx0 = 1.0 if style == 'scoop' else max(0.8, min(1.15, (hw - 0.08) / (size[0] / 2)))
    best = None
    sx = sx0
    while sx >= 0.75:
        for fr in fracs:
            yy = y0 + fr * (y1 - y0)
            p0 = Pose((0.0, yy, 0.0), (sx, 1.0, 1.0))
            pitch = best_pitch(car, part, p0, -26, 6, 0.5)
            pose, st = rest(car, part, Pose(p0.off, p0.scale, pitch), 0.012, min_hits=0.9)
            if pose is None:
                continue
            a = audit(car, part, pose)
            cand = (score(st, a) + abs(fr - frac) * 0.1 + (sx0 - sx) * 0.05, pose, st, a, pitch, sx)
            if best is None or cand[0] < best[0]:
                best = cand
        if best and best[2]['float'] <= 0.005:
            break
        sx -= 0.05
    if best is None:
        return None, f'the base finds no hood surface under it ({name})'
    _, pose, st, a, pitch, sx = best
    v = verdict(a)
    if v:
        return None, v
    if st['float'] > 0.015:
        return None, f"the hood crowns too much under it: {cm(st['float'])} would float"
    notes = []
    if st['float'] > 0.005:
        notes.append(f"base floats up to {cm(st['float'])} where the hood crowns")
    ev = {'hood': name, 'hoodYs': [round(y0, 3), round(y1, 3)], 'pitchDeg': round(pitch, 2), 'width': round(size[0] * sx, 3)}
    return dict(pose=pose, st=st, a=a, ev=ev, notes=notes, contact=[(0.0, yc)]), None


def place_roof(car, part, d):
    roof = car.m['roof']
    mt = part.mount
    style = mt.get('style', 'basket')
    ys = d.get('rackYs') or roof['ys']
    run = ys[1] - ys[0]
    hw = roof['halfWidth'] or 0.6
    yc = (ys[0] + ys[1]) / 2
    notes = []
    if style in ('basket', 'tray', 'bars'):
        feet_x = max(abs(f[0]) for f in mt['feet'])
        tx = d.get('rackFeetX') or (hw - 0.07)
        sx = max(0.75, min(1.3, tx / feet_x))
        span_y = max(f[1] for f in mt['feet']) - min(f[1] for f in mt['feet'])
        want = 0.85 * run - 0.12 if style != 'bars' else 0.62 * run
        sy = max(0.75, min(1.5, want / span_y)) if span_y > 0 else 1.0
        cands = [yc]
    elif style == 'lightbar':
        sx = max(0.75, min(1.25, 2 * (hw - 0.10) / mt['width']))
        sy = 1.0
        cands = [ys[1] - 0.06, ys[1] - 0.10, ys[1] - 0.14]
    else:   # scoop
        sx, sy = 1.0, 1.0
        cands = [ys[1] - 0.30, ys[1] - 0.36, yc]
    best = None
    for y in cands:
        p0 = Pose((0.0, y, 0.0), (sx, sy, 1.0))
        # A light bar is aimed level: it follows the roof's slope by 6 degrees at most.
        lim = 6 if style == 'lightbar' else 15
        pitch = best_pitch(car, part, p0, -lim, lim, 0.5)
        pose, st = rest(car, part, Pose(p0.off, p0.scale, pitch), 0.035 if style != 'scoop' else 0.012, min_hits=1.0)
        if pose is None:
            continue
        a = audit(car, part, pose)
        cand = (score(st, a) + abs(y - cands[0]) * 0.2, pose, st, a, pitch, y)
        if best is None or cand[0] < best[0]:
            best = cand
    if best is None:
        return None, 'a foot misses the roof'
    _, pose, st, a, pitch, y = best
    v = verdict(a)
    if v:
        return None, v
    if st['float'] > 0.01:
        return None, f"the roof twists or crowns too much under the feet: {cm(st['float'])} would float"
    if st['sink'] > 0.02:
        notes.append(f"roof crown/twist: the feet enter the roof up to {cm(st['sink'])} at one side")
    ev = {'style': style, 'roofZ': roof['z'], 'roofRun': [round(v_, 3) for v_ in ys], 'roofHalfWidth': hw, 'pitchDeg': round(pitch, 2)}
    return dict(pose=pose, st=st, a=a, ev=ev, notes=notes, contact=[(0.0, y)]), None


def place_bullbar(car, part, d):
    if (part.style or 'bar') == 'strap':
        return place_strap(car, part, d)
    f = car.m['front']
    mt = part.mount
    w, h = mt.get('width', 0.95), mt.get('height', 0.62)
    sx = max(0.85, min(1.25, 2 * 0.55 * f['halfWidthLow'] / w))
    zb = max(f['bumperBottomZ'], car.ground + 0.10)
    ymax = f['y']
    hood = car.s.top_values(-0.3, 0.3, ymax - 0.30, ymax - 0.15)
    hood_z = max(hood) if hood else (f['faceTopZ'] or zb + h)
    sz = max(0.55, min(1.2, (hood_z - 0.02 - zb) / h))
    zt = zb + h * sz
    xh = w / 2 * sx + 0.05
    low = [y for x, z, y in car.s.front_cells(-xh, xh, zb, zb + 0.15)]
    up = [y for x, z, y in car.s.front_cells(-xh, xh, zt - 0.15, zt)]
    if not low or not up:
        return None, 'front face not found in the bar band'
    y_low, y_up = max(low), max(up)
    rake = y_low - y_up
    if rake > 0.25:
        return None, f'raked nose: the face sets back {cm(rake)} between the bottom and the top of the bar, which would stand {cm(rake + mt.get("barY", 0.14))} proud of it'
    # The hoop stands BAR_CLEAR ahead of the face wherever it covers it (the arms, inside
    # embed boxes, do not count); the arms then bridge the gap and run into the bumper. The
    # hoop may lean back (up to 12 degrees) to follow a raked nose, which shortens the arms.
    arm_len = mt.get('barY', 0.14) - mt.get('armY', -0.28)
    best = None
    for pitch in range(0, 13):
        pose = Pose((0.0, max(y_low, y_up), zb), (sx, 1.0, sz), float(pitch))
        need = None
        for q, embedded in part.samples:
            if embedded:
                continue
            w_ = pose.apply(q)
            face = car.s.front(w_[0], w_[2])
            if face is not None and (need is None or face + BAR_CLEAR - w_[1] > need):
                need = face + BAR_CLEAR - w_[1]
        if need is None:
            continue
        pose = pose.moved(dy=need)
        arms = []
        for x, z in mt.get('arms', []):
            w_ = pose.apply((x, mt.get('barY', 0.14), z))
            face = car.s.front(w_[0], w_[2])
            arms.append((x, None if face is None else w_[1] - face, z))
        if not arms or any(g is None or g > arm_len - 0.06 for _, g, _ in arms):
            continue
        main = [min(g for x, g, _ in arms if (x > 0) == side) for side in (False, True)]
        cand = (max(main) + 0.004 * pitch, pose, arms, max(main), pitch)
        if best is None or cand[0] < best[0]:
            best = cand
    if best is None:
        return None, (f'the mounting arms ({cm(arm_len)} long) would end in the air: the nose is open or set too far back '
                      'behind the hoop where they would bolt on')
    _, pose, arms, reach, pitch = best
    if reach > BAR_REACH:
        return None, (f'the nose sets back {cm(reach)} behind the hoop where the arms bolt on: the bar would stand off the car '
                      f'on bare arms (at most {cm(BAR_REACH)})')
    a = audit(car, part, pose)
    v = verdict(a, 0.08)
    if v:
        return None, v
    bridges = [g for _, g, _ in arms]
    notes = []
    if reach > 0.15:
        notes.append(f'the hoop stands {cm(reach)} ahead of the bumper where the arms bolt on: long bare arms')
    deep = max(bridges)
    if deep > reach + 0.05:
        z_deep = next(z for _, g, z in arms if g == deep)
        which = 'lower' if z_deep <= min(z for _, _, z in arms) + 1e-6 else 'upper'
        notes.append(f'the {which} arms bridge {cm(deep)} to the body: the nose sets back at their height')
    if pitch >= 3:
        notes.append(f'leans back {pitch} degrees to follow the nose')
    if zb > f['bumperBottomZ']:
        notes.append('raised above the bumper bottom to keep 10 cm to the ground')
    st = {'float': 0.0, 'sink': round(max(0.0, arm_len - min(bridges)), 4), 'hits': len(bridges), 'points': len(bridges)}
    ev = {'rake': round(rake, 3), 'hoodEdgeZ': round(hood_z, 3), 'barTopZ': round(zt, 3), 'pitchDeg': pitch,
          'armBridge': [round(min(bridges), 3), round(deep, 3)], 'hoopClear': BAR_CLEAR}
    return dict(pose=pose, st=st, a=a, ev=ev, notes=notes, contact=[(0.0, pose.off[1])]), None


def place_strap(car, part, d):
    f = car.m['front']
    x0 = part.mount.get('strapX', -0.30)
    zb = f['bumperBottomZ']
    best = None
    for xa in [-0.24 - 0.02 * i for i in range(12)]:
        for dz in [0.04 + 0.02 * i for i in range(12)]:
            za = zb + dz
            face = car.s.front(xa, za)
            if face is None:
                continue
            p0 = Pose((xa - x0, face, za), (1.0, 1.0, 1.0))
            pose, st = rest(car, part, p0, 0.015, min_hits=1.0)
            if pose is None:
                continue
            a = audit(car, part, pose)
            cand = (score(st, a) + dz * 0.2 + abs(xa + 0.34) * 0.1, pose, st, a, xa, za)
            if best is None or cand[0] < best[0]:
                best = cand
    if best is None:
        return None, 'no bumper face low on the left of the nose for the anchor plate'
    _, pose, st, a, xa, za = best
    v = verdict(a, 0.10)
    if v:
        return None, v
    if st['float'] > 0.006:
        return None, f"the bumper face is too curved under the anchor plate: {cm(st['float'])} would float"
    ev = {'anchor': [round(xa, 3), round(pose.off[1], 3), round(za, 3)]}
    return dict(pose=pose, st=st, a=a, ev=ev, notes=[], contact=[(xa, pose.off[1])]), None


PLACERS = {'spoiler': place_spoiler, 'louver': place_louver, 'lip': place_lip, 'canard': place_canard, 'skirt': place_skirt,
           'diffuser': place_diffuser, 'hood': place_hood, 'roofrack': place_roof, 'bullbar': place_bullbar}


# --------------------------------------------------------------------------- lid slots
def lid_slot(car, meas, bindings, contact, z):
    """The non-Base slot whose panel holds every contact point, if any (the part then
    rides on that lid). Returns (slot, panel) or (None, None)."""
    hits = {}
    for name, b in meas['parts'].items():
        slot = bindings.get(name)
        if not slot or slot == 'Base':
            continue
        (x0, y0, z0), (x1, y1, z1) = b
        if all(x0 - 0.02 <= x <= x1 + 0.02 and y0 - 0.02 <= y <= y1 + 0.02 for x, y in contact) and z0 - 0.05 <= z <= z1 + 0.05:
            hits[slot] = name
    if len(hits) == 1:
        slot, name = next(iter(hits.items()))
        return slot, name
    return None, None


def dealer_bindings(dealer, key):
    for m in dealer['models']:
        if m['key'] == key:
            out = {}
            for c in m['components']:
                if not c.get('inPlayerAppearance'):
                    continue
                p = c.get('parent') or {}
                if p.get('bindName') == 'vehicle_slots' and p.get('slotName'):
                    out[c['name']] = p['slotName']
            return out
    return {}


# --------------------------------------------------------------------------- extra cars
DESIGN_KEYS = ('body', 'deck', 'roofEdge', 'rackYs', 'rackFeetX')


def load_extra(cars_spec, hides_path):
    """Merge the data-file cars into DESIGN, STYLE_EXCLUDE and HIDE. The first 14 keep the
    rows above; for them the hide file is only compared (hide_drift()), never applied, so
    their table entries stay exactly as fitted. Returns the hide file (or None)."""
    if cars_spec and Path(cars_spec).exists():
        extra = json.loads(Path(cars_spec).read_text(encoding='utf-8'))
        for key, row in extra['cars'].items():
            if key in DESIGN:
                raise SystemExit(f'body_fit: {key} is in both DESIGN and {cars_spec}')
            # `like`: a trim of a car already designed (same entity, same shell): its design
            # row and style refusals are taken over, the row's own keys win.
            like = row.get('like')
            if like and like not in DESIGN:
                raise SystemExit(f'body_fit: {key} is like {like}, which has no design row (list it first)')
            design = dict(DESIGN[like]) if like else {}
            design.update({k: (tuple(v) if isinstance(v, list) else v) for k, v in row.items() if k in DESIGN_KEYS})
            DESIGN[key] = design
            if like:
                for (target, car), why in list(STYLE_EXCLUDE.items()):
                    if car == like:
                        STYLE_EXCLUDE[(target, key)] = why
            for target, why in (row.get('exclude') or {}).items():
                STYLE_EXCLUDE[(target, key)] = why
            for target in row.get('allow') or []:
                STYLE_EXCLUDE.pop((target, key), None)
    hides = None
    if hides_path and Path(hides_path).exists():
        hides = json.loads(Path(hides_path).read_text(encoding='utf-8'))
        for key, row in hides['cars'].items():
            if key in bm.CARS:
                continue
            for group, names in (row.get('hide') or {}).items():
                if names:
                    HIDE.setdefault(group, {})[key] = list(names)
    return hides


def hide_drift(hides):
    """Names the per-appearance survey finds on a first-14 car that its HIDE row lacks."""
    out = {}
    for key, row in ((hides or {}).get('cars') or {}).items():
        if key not in bm.CARS:
            continue
        for group, names in (row.get('hide') or {}).items():
            missing = [n for n in names if n not in HIDE.get(group, {}).get(key, [])]
            if missing:
                out[f'{group}/{key}'] = missing
    return out


# --------------------------------------------------------------------------- main
def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('--work', type=Path, default=bs.WORK, help='body_measure.py work folder (measure.json, surface/)')
    ap.add_argument('--parts', type=Path, default=REPO / 'artifacts/vehicle-kit/lightrp_vk_body/work/parts')
    ap.add_argument('--spec', type=Path, default=SPEC)
    ap.add_argument('--dealer', type=Path, default=bm.DEALER)
    ap.add_argument('--out', type=Path, default=OUT)
    ap.add_argument('--cars-spec', type=Path, default=CARS_SPEC, help='design rows of the cars beyond the first 14')
    ap.add_argument('--hides', type=Path, default=HIDES, help='per-appearance factory part names (inventory/body_hides.py)')
    ap.add_argument('--ids', default='', help='only these part ids (debug; the written table then holds only them)')
    ap.add_argument('--cars', default='', help='only these cars (debug)')
    args = ap.parse_args()

    spec = json.loads(args.spec.read_text(encoding='utf-8'))
    meas = json.loads((args.work / 'measure.json').read_text(encoding='utf-8'))['cars']
    dealer = json.loads(args.dealer.read_text(encoding='utf-8'))
    models = {m['key']: m for m in dealer['models']}
    labels = {m['key']: m['label'] for m in dealer['models']}
    hides = load_extra(args.cars_spec, args.hides)
    # The first 14 in their historic order, then every other measured car with a design row.
    order = list(bm.CARS) + [k for k in meas if k not in bm.CARS and k in DESIGN]
    skipped = [k for k in meas if k not in bm.CARS and k not in DESIGN]
    if skipped and not args.cars:
        print(f'body_fit: no design row for {skipped}: left out', flush=True)
    cars = [k for k in order if k in meas and (not args.cars or k in args.cars.split(','))]
    # Records that share a car's exterior (player_body_components.py) get the same fit.
    records = {k: list(models.get(k, {}).get('records') or [meas[k]['record']]) for k in cars}
    resource = spec['resource']
    car_objs = {k: Car(k, meas[k], bs.load(k, args.work, models), bs.components(k, args.work, models)) for k in cars}

    sparts = [p for p in spec['parts'] if not args.ids or p['id'] in args.ids.split(',')]
    out_parts, summary = {}, {k: {'fits': [], 'excluded': {}} for k in cars}
    groups = {}
    for sp in sparts:
        pdir = args.parts / sp['id']
        meta_path, glb = pdir / f"{sp['id']}.part.json", pdir / f"{sp['id']}.glb"
        if not meta_path.exists():
            raise SystemExit(f'body_fit: {meta_path} missing; run build-pack (or the generators) first')
        part = Part(sp, json.loads(meta_path.read_text(encoding='utf-8')), glb)
        groups.setdefault(part.group, []).append(sp['id'])
        entry = {'kind': 'part', 'slot': 'Base', 'label': sp.get('label', sp['id']),
                 'variants': {f: f'asset:{resource}/{sp["id"]}_{f}' for f in sp['finishes']},
                 'fit': {}, 'excluded': {}, 'evidence': {}}
        for key in cars:
            car = car_objs[key]
            rec = meas[key]['record']
            d = DESIGN[key]
            reason = STYLE_EXCLUDE.get((sp['id'], key)) or STYLE_EXCLUDE.get((part.group, key))
            placed = None
            if not reason:
                placed, reason = PLACERS[part.kind](car, part, d)
            if reason:
                for r in records[key]:
                    entry['excluded'][r] = reason
                summary[key]['excluded'][sp['id']] = reason
                continue
            pose = placed['pose']
            fit = {'offset': r3(car.to_base(pose.off))}
            if abs(pose.pitch) >= 0.1:
                fit['rotation'] = [r1(pose.pitch), 0.0, 0.0]
            scale = [round(v, 3) for v in pose.scale]
            if any(abs(v - 1.0) > 1e-3 for v in scale):
                fit['scale'] = scale
            hide = HIDE.get(part.group, {}).get(key)
            if hide:
                fit['hide'] = list(hide)
            fit['estimate'] = 'offline'
            fix = IN_GAME.get((sp['id'], key))
            if fix:
                fit.update(fix)
                fit['estimate'] = 'in_game'
            ev = dict(placed['ev'])
            st, a = placed['st'], placed['a']
            ev['contact'] = {'float': round(st.get('float', 0.0), 3), 'sink': round(st.get('sink', 0.0), 3)}
            ev['audit'] = {'cut': a['cut'], 'ground': a['ground'], 'wheel': a['wheel']}
            if a.get('hiddenCut'):
                ev['audit']['hiddenCut'] = a['hiddenCut']
            ev['root'] = {'offset': r3(pose.off)}
            slot, panel = lid_slot(car, meas[key], dealer_bindings(dealer, key), placed['contact'], pose.off[2])
            if slot and slot in meas[key].get('slotBones', {}):
                t = meas[key]['slotBones'][slot]['translation']
                ev['lid'] = {'slot': slot, 'panel': panel,
                             'offset': r3([pose.off[0] - t[0], pose.off[1] - t[1], pose.off[2] - t[2]])}
            if placed['notes']:
                ev['notes'] = placed['notes']
            for r in records[key]:
                entry['fit'][r] = json.loads(json.dumps(fit))
                entry['evidence'][r] = json.loads(json.dumps(ev))
            summary[key]['fits'].append(sp['id'])
        out_parts[sp['id']] = entry
        print(f"{sp['id']:16} fits {len(entry['fit']):2}  excluded {len(entry['excluded']):2}", flush=True)

    doc = {
        'schema': 'open77.vehicle-kit.fit/1',
        'resource': resource,
        'status': 'OFFLINE ESTIMATE: every offset comes from 1 cm surfaces of the stock exterior panels '
                  '(body_measure.py + body_surface.py + body_fit.py); none has been seen in game',
        'frames': {
            'slot': 'Base: the vehicle_slots bone the body shell is bound to. fit.offset is in this frame '
                    '(metres, X right, Y forward, Z up). Its bind pose is a pure translation from Root on every car below.',
            'root': "evidence.root.offset: the same placement in the entity frame (props.attach bone ''), for /vkit.wing + /vkit.move",
            'lid': 'evidence.lid: for a part whose contact points lie on a lid panel bound to another slot, the offset in that '
                   'slot frame (the part then opens with the lid)',
            'rotation': 'degrees about the slot X axis only (pitch; right-handed, +Y toward +Z); sign to verify in game',
            'scale': 'per-axis visual scale of the part mesh (props visualScale), applied before the pitch',
        },
        'groups': {g: {'label': GROUP_LABELS.get(g, g), 'parts': ids} for g, ids in groups.items()},
        'registerParts': 'keep kind, slot, label, variants and per-record fit {offset, rotation, scale, hide}; '
                         'drop excluded/evidence/estimate when turning this into Open77.vehicles.registerParts. '
                         'groups: one part per group at a time (the Light RP studio groups by spec kind)',
        'cars': {k: dict({'record': meas[k]['record'], 'label': labels.get(k, k), 'body': DESIGN[k]['body'],
                          'base': meas[k]['baseBone']['translation'], 'fits': summary[k]['fits'],
                          'excluded': summary[k]['excluded']},
                         **({'records': records[k]} if len(records[k]) > 1 else {})) for k in cars},
        'parts': out_parts,
    }
    args.out.write_text(json.dumps(doc, indent=1, ensure_ascii=False) + '\n', encoding='utf-8')
    total = sum(len(p['fit']) for p in out_parts.values())
    excl = sum(len(p['excluded']) for p in out_parts.values())
    for k in cars:
        print(f"{k:9} fits {len(summary[k]['fits']):2}  {' '.join(summary[k]['fits'])}")
    for k, names in hide_drift(hides).items():
        print(f'body_fit: hide survey names missing from HIDE {k}: {names}')
    print(f'VK_BODY_FIT_OK parts={len(out_parts)} fits={total} excluded={excl} out={args.out}')


if __name__ == '__main__':
    main()
