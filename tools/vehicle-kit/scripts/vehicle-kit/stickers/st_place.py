"""Placement of the original sticker motifs on each model: zones, hosts, fit, decal meshes.

    uv run --no-project --with pillow --with numpy python -I st_place.py inputs --cfg <place.json>
    uv run --no-project --with pillow --with numpy python -I st_place.py place  --cfg <place.json>

inputs  the files `place` reads besides the spec: the raw .mesh of every exterior component of
        every model (body-kit cache) and every .mi of their material chains -> inputs.json.
        The chains are only known once the meshes and the first .mi files are serialized, so
        the build calls it until `complete` is true (lv_composite.py inputs, same loop).
place   per model and theme, one decal per zone a motif names (st_place.ZONES), each hung on
        the stock panel the zone finds on that model -> placements.json + one glb per decal,
        a review board per set (cfg boards) and per theme an overview of the spec's
        overviewModels (cfg overviews).

How a zone becomes a decal (all measured on the exterior the player appearance draws,
lv_surface.model_surface: chunkMask, glass, lights and vanilla decal shells known; plus, here,
the chunks the game never draws opaque left out (drawn_chunks_only) and the .app's visualScale
applied, which lv_surface ignores):
  1. Raster. The car seen from the zone's view (left, right, top, rear) at --step (1 cm): per
     cell the nearest triangle, its component, its kind (paint, glass, ...) and its normal.
  2. Ground. A cell can carry a sticker when it is paint facing the view (|n . view| >= 0.6),
     smooth (no depth jump over 2 cm to a neighbour: no panel edge, no step), turned the view's
     way (a side panel's normal more sideways than vertical...), not a shell over a window
     (glass 10 cm or less behind the paint: the Caliburn's canopy and doors over its crystal
     dome) and outside the wheel discs (rig wheel bones + dealer tyre radii + 5 cm: the wheels
     are not in the surface).
  3. Region. Where on the car the zone is (ZONES). Top: on the centre line, the rows that are
     mostly glass (or paint over glass) and reach the upper part of the car (CABIN_GLASS: not a
     headlight cover) are the windscreen (frontmost) and the rear window (rearmost); hood ahead,
     roof between (it must reach the windscreen's top: a cabin), trunk behind. A bike has no
     cabin: its hood region is the tank between the axles, no roof, no trunk. Sides: the doors
     (components named door, front first; no door, a bike: the side's largest panels), door2
     (the doors entirely behind the front one: a four-door's rear door), the sill (between the
     arches, its lowest 22 cm), the wings (between door and wheel, above the wheel centre,
     below the belt line, the top of the front door's paint). Rear: the upper rear face.
  4. Hosts. Up to CANDIDATES components per zone, the largest share of the region's ground
     first (MIN_CANDIDATE m^2 at least): stock panels only, never one a body kit can hide
     (kitFits: its artwork would float where the part was), never a scaled one, never one
     flagged or named as trim (HOST_SKIP_FLAGS, HOST_SKIP_NAME: stripes, junk, addons...), and
     never a bumper except for 'rear'. A pair takes mirrored names (door_fl_a / door_fr_a).
  5. Fit. Motifs go in spec order. The motif's opaque footprint at the cell size, from scale 1
     down to minScale (SCALE_STEP), must lie on free cells: the host's ground eroded by MARGIN,
     minus the rectangles of the decals already placed in that view. The first candidate that
     fits at the largest scale wins; among its positions, the one nearest the region's anchor.
     Pairs (door_l / door_r, ...) fit on both sides at once: the right side's valid positions,
     mirrored, are intersected with the left's, so the pair is symmetric. Centre zones (hood,
     roof, trunk, rear) stay on the car's centre line. A motif with crop 'v' (stripes) keeps
     its width and takes the longest run along the car (>= minLength, capped at maxLength): the
     art's middle part when shorter, the art stretched when longer. A side motif with crop 'u'
     (sill bands, pinstripe segments) keeps its height and takes a run along the car the same
     way, on both sides at once; cropKeep names the part of the art kept when the run is
     shorter (start: the front end, middle, end: the rear end) and the run hugs that end of the
     panel. Its height prefers an anchor: alignTo (the height of an earlier motif's decal on the
     same side: a pinstripe continues from the door onto the wings), else the motif's own
     earlier unit, else anchorZ 'belt' (+ anchorOffset); anchorWeight trades length for
     distance to it; alignTolerance: a segment that continues another is left out rather than
     drawn at another height. A motif with a fallback that has no room even at its minScale
     (a long side motif on a bike) takes the named motif's art there instead (an emblem of the
     theme, its texture already in the pack). Motifs of one scaleGroup share the scale giving
     the largest total area; a member without room there takes, alone, its own best area below it.
  6. Mesh. A regular grid (--spacing, 2 cm) over the placed rectangle, kept where its four
     corners land on the host (same component, depth spread, centre check, facing: the
     lv_decals.py quad rules), pushed --offset (4 mm) out along the normal and expressed in the
     host's frame. UVs come from the rectangle; a mirrored motif's u runs the other way on the
     right side (a flag's pole at the front on both sides); an unmirrored one stays readable.
     One glb per decal.
  7. Assertions. Of the motif's opaque texels: the share the mesh carries (>= minCarried, one
     cell of slack for the 4 mm push), the share drawn in front of the body (>= minVisible),
     over the host (>= minOnHost), floating more than 2 cm off the body (<= maxFloating), and
     none on a wheel disc.

A zone the model has no room for is left out of that model's set (reported, with the hosts
tried). A set over maxDecalsPerSet (9, so a light livery still fits beside it) first loses its
optional motifs, the last one first, whole (both sides); a set still over it, or over
maxDecalsPerCar (12: the engine cap, a 13th decal on one vehicle crashes at spawn), is refused,
and so is one below minDecalsPerSet, so a theme a model cannot carry fails the build. Each
set's count is the integer `decals` of its sticker row (getDecalBudget); two themes on one car
are the server budget's business (the sum of the rows' decals).

extendedModels (the spec's second list: every vanilla player body past the dealer stock, keyed by
docs/generated/vehicle-player-scope-<ver>.json) are placed by the same rules, but leniently: a decal
that fails an assertion is left out with its pair partner (reported, like a zone without room),
and a set left under minDecalsPerSet is not produced (`droppedSets`, with the reason). A body where
no theme qualifies gets nothing. The 16 `models` stay strict: any failure fails the build.

Trims. A set is measured on the primary record's player appearance. Every other record of the
same body (the dealer table's `trims`: same entity, another appearance) is listed with the set when
its appearance carries every host component the set hangs on, with the same mesh and binding
(`records`; another mesh appearance on the same geometry, a `restyled` panel, still takes it);
the others are reported in `trimsRefused`. Quest variants (`Vehicle.q<digits>_*`) are not in
the scope table, so never a trim. A chunk mask that differs
between appearances is not checked (inference: the stock panels a sticker takes are not masked).
"""
from __future__ import annotations

import argparse
import collections
import contextlib
import json
import math
import re
import sys
from pathlib import Path

import numpy as np
from PIL import Image

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parent / 'liveries'))
sys.path.insert(0, str(HERE))
import lv_surface  # noqa: E402
from lv_common import (BS, MAX_DECALS_PER_TEMPLATE, REPO, cv, flat_name, inverse_apply,  # noqa: E402
                       inverse_rotate, read_json, unit, write_glb, write_json)
from lv_surface import (AXIS, KIND_GLASS, KIND_PAINT, VIEWS as RASTER_VIEWS, _quat_matrix, face_normals,  # noqa: E402
                        mesh_json_path, mesh_materials, model_surface, raster)

import body_measure  # noqa: E402  (read-only reuse; lv_common puts ../blender on sys.path)
import st_board  # noqa: E402

DEALER = REPO / 'docs/generated/vehicle-components-dealer-2.50.json'


def fail(msg):
    raise SystemExit(f'st_place: {msg}')


def all_models(spec):
    """The strict dealer models, then the extended ones (lenient placement, see the docstring)."""
    out = list(spec['models']) + list(spec.get('extendedModels') or [])
    if len(set(out)) != len(out):
        fail('a model is listed twice (models and extendedModels)')
    return out


def cmd_inputs(cfg):
    spec = read_json(cfg['spec'])
    dealer = {m['key']: m for m in read_json(cfg.get('dealer') or DEALER)['models']}
    work = Path(cfg['measureWork'])
    roots = [Path(r) for r in cfg['gameJson']]
    meshes, materials, complete, missing_models = {}, set(), True, set()
    only = [k for k in (cfg.get('only') or '').split(',') if k]
    for key in all_models(spec):
        if only and key not in only:
            continue
        m = dealer.get(key) or fail(f'{key} is not in the dealer table')
        ent = work / 'json' / (Path(m['entity']['path'].replace(BS, '/')).name + '.json')
        if not ent.exists():
            missing_models.add(key)
        for c in body_measure.selected_components(m):
            if c['type'] == 'entAppearanceProxyMeshComponent':
                continue
            raw = work / 'glb' / c['mesh'].replace(BS, '/')
            glb = work / 'glb' / (c['mesh'].replace(BS, '/')[:-5] + '.glb')
            if raw.exists() and glb.exists():
                meshes[c['mesh']] = str(raw)
            else:
                missing_models.add(key)
    todo = []
    for depot in sorted(meshes):
        mj = mesh_json_path(cfg['meshJson'], depot)
        if mj.exists():
            todo += sorted(mesh_materials(mj))
        else:
            complete = False
    while todo:
        mi = todo.pop()
        if not mi.lower().endswith('.mi') or mi in materials:
            continue
        materials.add(mi)
        p = next((r / (flat_name(mi) + '.json') for r in roots if (r / (flat_name(mi) + '.json')).exists()), None)
        if p is None:
            complete = False
            continue
        base = cv(read_json(p)['Data']['RootChunk'].get('baseMaterial'))
        if base:
            todo.append(base)
    write_json(cfg['inputsOut'], {'complete': complete, 'meshes': dict(sorted(meshes.items())),
                                  'materials': sorted(materials), 'missingModels': sorted(missing_models)})
    print(f'ST_INPUTS_OK meshes={len(meshes)} materials={len(materials)} complete={complete} '
          f'missingModels={",".join(sorted(missing_models)) or "none"}')


def cmd_extract(cfg):
    """The body-kit cache of the models inputs found missing (body_measure.extract: entity, .app,
    rig, raw meshes and MeshOnly glb; read-only on the game). Not body_measure's main(): that
    would also rewrite the cache's measure.json for these models only."""
    inputs = read_json(cfg['inputsOut'])
    dealer = {m['key']: m for m in read_json(cfg.get('dealer') or DEALER)['models']}
    work = Path(cfg['measureWork']).resolve()
    try:
        work.relative_to(REPO)
        fail(f'{work} is inside the repository; game data must stay outside it')
    except ValueError:
        pass
    models = [dealer[k] for k in inputs['missingModels']]
    body_measure.extract(work, cfg['game'], cfg['cli'], models)
    print(f'ST_EXTRACT_OK models={",".join(m["key"] for m in models)}')



# =========================================================================== place
FIT_FACING = 0.6           # |n . view| a cell under an opaque texel needs (stretch <= 1.67)
MESH_FACING = 0.45         # a decal quad corner (lv_decals.MIN_FACING): transparent margins may curve away
DEPTH_JUMP = 0.02          # metres between neighbouring cells at the fit step: a panel edge or a step
MARGIN = 0.015             # the host mask is eroded by this much: no texel touches a panel edge
WHEEL_MARGIN = 0.05        # around the tyre's disc
GLASS_UNDER = 0.10         # seen from above, paint with glass this close under it is a shell over a window
CABIN_GLASS = 0.55         # a windscreen or rear window reaches this share of the car's height (top view)
SCALE_STEP = 0.05
CANDIDATES = 4             # hosts tried per zone, largest share of the region first
MIN_CANDIDATE = 0.01       # m^2 of fit cells a component needs in a region to be tried
CENTRE_TOLERANCE = 0.01    # lv_decals.CENTRE_TOLERANCE
DECAL_BEHIND = 0.003       # lv_composite: a decal up to 3 mm behind the body still draws
DECAL_FLOAT = 0.02         # more than 2 cm in front of the body: floating
NOT_DRAWN = ('invisible.mt', 'top_down_car_proxy_depth.mt')   # chain finals the game never draws opaque
HOST_SKIP_FLAGS = {'part:mirror', 'plate', 'spoiler', 'part:fuel', 'part:exhaust', 'glass', 'light', 'wheel', 'tire',
                   'rim', 'decal', 'shadow', 'placeable', 'widget', 'part:interior', 'excludedFromCustomization'}
HOST_SKIP_NAME = re.compile(r'mirror|fx_cutout|stripe|wiper|plate|shadow|fuel|exhaust|lidar|sensor|antenna|junk|addon')
# A bumper is never a hood, roof, trunk, door, sill or wing (the Bandit's nose took its hood
# stripes): only the 'rear' zone may hang on one.
BUMPER_NAME = re.compile(r'bumper')
DOOR_NAME = re.compile(r'door')

# zone -> (view, kind). Pairs fit on both sides at once (PAIRS); centre zones stay on x = 0.
# door2: a second door entirely behind the first (a four-door's rear door), for motifs that run
# along the whole flank (a belt pinstripe); a two-door has none.
ZONES = {
    'hood': ('top', 'centre'), 'roof': ('top', 'centre'), 'trunk': ('top', 'centre'), 'rear': ('rear', 'centre'),
    'door_l': ('left', 'side'), 'door_r': ('right', 'side'), 'sill_l': ('left', 'side'), 'sill_r': ('right', 'side'),
    'wing_fl': ('left', 'side'), 'wing_fr': ('right', 'side'), 'wing_rl': ('left', 'side'), 'wing_rr': ('right', 'side'),
    'door2_l': ('left', 'side'), 'door2_r': ('right', 'side'),
}
PAIRS = {'door_l': 'door_r', 'sill_l': 'sill_r', 'wing_fl': 'wing_fr', 'wing_rl': 'wing_rr', 'door2_l': 'door2_r'}
CROP_KEEP = ('start', 'middle', 'end')
# Motif axes in a view's plane (lv_surface.VIEWS: A, B): (u axis, u sign, v axis, v sign), axis 0 = A, 1 = B.
# Side zones: u towards the car's rear as seen from the left (readable), v down. Top: v towards the front,
# u towards the car's left (readable from the front). Rear: u towards the car's right, v down.
ORIENT = {'left': (0, -1, 1, -1), 'right': (0, 1, 1, -1), 'top': (1, -1, 0, 1), 'rear': (0, 1, 1, -1)}
WORLD = {'x': (1.0, 0.0, 0.0), 'y': (0.0, 1.0, 0.0), 'z': (0.0, 0.0, 1.0)}
MIRROR_NAMES = [(re.compile(a), b) for a, b in (
    (r'left', 'right'), (r'(?<=_)fl(?=_|\d|$)', 'fr'), (r'(?<=_)bl(?=_|\d|$)', 'br'), (r'(?<=_)rl(?=_|\d|$)', 'rr'),
    (r'(?<=_)l(?=_|\d|$)', 'r'))]


def orient(view, mirrored):
    """A mirrored motif (right side, mirror = true) runs u the other way: it points the same way
    relative to the car as on the left (a flag's pole at the front on both sides)."""
    ua, us, va, vs = ORIENT[view]
    return (ua, -us if mirrored else us, va, vs)


def axis_dirs(view, o):
    """World unit vectors of the motif's +u and +v in a view, for an orientation o."""
    names = (RASTER_VIEWS[view][0], RASTER_VIEWS[view][1])
    ua, us, va, vs = o
    return np.array(WORLD[names[ua]]) * us, np.array(WORLD[names[va]]) * vs


def mirror_name(name):
    for rx, sub in MIRROR_NAMES:
        if rx.search(name):
            return rx.sub(sub, name)
    return name


@contextlib.contextmanager
def drawn_chunks_only():
    """lv_surface.model_surface with the chunks the game does not draw left out: fx_cutout.mi
    (chain final top_down_car_proxy_depth.mt) and invisible.mt (the semimaru's hidden stripe
    chunks) are classified KIND_OTHER there, i.e. opaque, and would hide the paint under them.
    The wrapper only lasts for this module's own calls; lv_surface is not edited."""
    original = lv_surface.classify

    def classify(name, base, values, materials=None):
        final = base or ''
        if materials is not None and final.lower().endswith('.mi'):
            final = materials.chain(final)[1]
        if final.lower().endswith(NOT_DRAWN):
            return None, None
        return original(name, base, values, materials)

    lv_surface.classify = classify
    try:
        yield
    finally:
        lv_surface.classify = original


def visual_scales(model, work):
    """component -> visualScale of the player appearance's .app, where it is not 1 (the Bandit's
    engine fans: 0.0625). lv_surface.model_surface does not apply it."""
    app = next(a for a in model['appearances'] if a['name'] == model['playerAppearance'])
    root = read_json(Path(work) / 'json' / (Path(app['app'].replace(BS, '/')).name + '.json'))['Data']['RootChunk']
    out = {}
    for a in root.get('appearances') or []:
        if cv(a['Data']['name']) != app['appearanceName']:
            continue
        for c in a['Data'].get('components') or []:
            vs = c.get('visualScale')
            if c.get('name') is not None and vs and any(abs(float(vs[k]) - 1) > 1e-4 for k in 'XYZ'):
                out[cv(c['name'])] = (float(vs['X']), float(vs['Y']), float(vs['Z']))
    return out


def apply_visual_scales(s, scales):
    for ci, name in enumerate(s.names):
        if name not in scales:
            continue
        q, t = s.frames[name]
        rot = _quat_matrix(q)
        sel = s.comp == ci
        local = (s.tris[sel] - np.array(t)) @ rot
        s.tris[sel] = (local * np.array(scales[name])) @ rot.T + np.array(t)


def box_count(mask, r):
    """Per cell, the number of True cells in its (2r+1)^2 window (outside the grid: False)."""
    m = np.pad(mask.astype(np.int32), ((r + 1, r), (r + 1, r)))
    c = m.cumsum(0).cumsum(1)
    k = 2 * r + 1
    return c[k:, k:] - c[:-k, k:] - c[k:, :-k] + c[:-k, :-k]


def erode(mask, r):
    return mask if r <= 0 else box_count(mask, r) == (2 * r + 1) ** 2


def dilate(mask, r):
    return mask if r <= 0 else box_count(mask, r) > 0


def fit_offsets(bad, fp):
    """valid[i, j]: footprint fp placed with its corner at cell (i, j) covers no bad cell."""
    na, nb = bad.shape
    fa, fb = fp.shape
    if fa > na or fb > nb:
        return np.zeros((0, 0), bool)
    sa, sb = 1 << (na + fa).bit_length(), 1 << (nb + fb).bit_length()
    conv = np.fft.irfft2(np.fft.rfft2(bad.astype(np.float64), (sa, sb)) *
                         np.fft.rfft2(fp[::-1, ::-1].astype(np.float64), (sa, sb)), (sa, sb))
    return conv[fa - 1:na, fb - 1:nb] < 0.5


def runs(flags):
    """[(start, stop)) of the True runs of a 1-D bool array."""
    d = np.diff(np.concatenate([[0], flags.astype(np.int8), [0]]))
    return list(zip(np.nonzero(d == 1)[0].tolist(), np.nonzero(d == -1)[0].tolist()))


class Grid:
    """One orthographic view of the car's drawn exterior at the fit step (lv_surface.raster)."""

    def __init__(self, surface, fn, view, step, lo, hi):
        owner, zbuf, geo, _ = raster(surface.tris, view, step, lo, hi)
        self.view, self.step, self.lo, self.hi = view, step, lo, hi
        self.A, self.B, self.na, self.nb = geo
        self.valid = owner >= 0
        ow = owner.clip(0)
        cam = np.array(RASTER_VIEWS[view][4])
        n = fn[ow]
        f = (n * cam).sum(-1)
        self.n = np.where(f[..., None] < 0, -n, n)
        self.facing = np.where(self.valid, np.abs(f), 0)
        self.comp = np.where(self.valid, surface.comp[ow], -1)
        self.kind = np.where(self.valid, surface.kind[ow], -1)
        self.depth = zbuf
        self.a = lo[self.A] + np.arange(self.na) * step
        self.b = lo[self.B] + np.arange(self.nb) * step
        z = np.where(np.isfinite(zbuf), zbuf, 1e9)
        smooth = self.valid.copy()
        for axis in (0, 1):
            d = np.abs(np.diff(z, axis=axis)) <= DEPTH_JUMP
            pad = [(0, 0), (0, 0)]
            pad[axis] = (1, 0)
            smooth &= np.pad(d, pad, constant_values=False)
            pad[axis] = (0, 1)
            smooth &= np.pad(d, pad, constant_values=False)
        if view in ('left', 'right'):
            shape = np.abs(self.n[..., 0]) >= np.abs(self.n[..., 2])
        elif view == 'top':
            shape = self.n[..., 2] > np.abs(self.n[..., 0])
        else:
            shape = np.abs(self.n[..., 1]) >= np.abs(self.n[..., 2])
        # Paint a few centimetres in front of glass is a shell over a window: the Caliburn's
        # canopy and door panels cover its crystal-dome glass (fx_crystaldome_caliburn.mi), from
        # above and from the sides. Never a sticker's ground, and glass for the top zones.
        self.over_glass = np.zeros_like(self.valid)
        glass = surface.kind == KIND_GLASS
        if glass.any():
            _o, gz, _g, _ = raster(surface.tris[glass], view, step, lo, hi)
            with np.errstate(invalid='ignore'):
                self.over_glass = self.valid & (self.kind != KIND_GLASS) & np.isfinite(gz) & (gz - zbuf <= GLASS_UNDER)
        self.paint = (self.valid & (self.kind == KIND_PAINT) & (self.facing >= FIT_FACING) & smooth & shape
                      & ~self.over_glass)
        self.blocked = np.zeros_like(self.valid)      # wheel discs (side views)
        self.taken = np.zeros_like(self.valid)        # rectangles of the decals already placed in this view

    def ab(self):
        return np.meshgrid(self.a, self.b, indexing='ij')

    def take(self, centre, ext):
        aa, bb = self.ab()
        self.taken |= (np.abs(aa - centre[0]) <= ext[0] / 2 + MARGIN) & (np.abs(bb - centre[1]) <= ext[1] / 2 + MARGIN)


def wheel_table(model, work):
    """Wheel centres (rig bind pose) and tyre sizes: wheels are not in the surface (the body-kit
    selection skips them), so the side regions cut their discs out and the boards draw them."""
    js = work / 'json'
    ent = js / (Path(model['entity']['path'].replace(BS, '/')).name + '.json')
    bones = body_measure.rig_bones(js / (Path(body_measure.rig_path_of(ent).replace(BS, '/')).name + '.json'))
    out = []
    for end, names in (('front', ('wheel_front_left', 'wheel_front_right', 'wheel_front')),
                       ('back', ('wheel_back_left', 'wheel_back_right', 'wheel_back'))):
        w = model['wheels'][end]
        for name in names:
            if name in bones:
                c = bones[name][1]
                out.append({'end': end, 'bone': name, 'centre': [float(v) for v in c], 'tyre': float(w['tireRadius']),
                            'rim': float(w.get('rimRadius') or 0), 'width': float(w.get('tireWidth') or 0.2)})
    if not any(w['end'] == 'front' for w in out) or not any(w['end'] == 'back' for w in out):
        fail(f'{model["key"]}: no front or back wheel bone in the rig')
    return out


def block_wheels(g, wheels):
    if g.view not in ('left', 'right'):
        return
    aa, bb = g.ab()
    for w in wheels:
        y, z = w['centre'][1], w['centre'][2]
        g.blocked |= (aa - y) ** 2 + (bb - z) ** 2 <= (w['tyre'] + WHEEL_MARGIN) ** 2


class Model:
    """What the zones need of one model: its surface, its grids, its wheels and its hosts."""

    def __init__(self, cfg, dealer_row, kit_hidden):
        self.m = dealer_row
        self.key = dealer_row['key']
        self.step = cfg['step']
        work = Path(cfg['measureWork'])
        with drawn_chunks_only():
            self.s = model_surface(dealer_row, {'playerAppearance': dealer_row['playerAppearance']}, work,
                                   cfg['meshJson'], cfg['gameJson'])
        self.scaled = visual_scales(dealer_row, work)
        apply_visual_scales(self.s, self.scaled)
        self.fn = face_normals(self.s.tris)
        pts = self.s.tris.reshape(-1, 3)
        self.lo = pts.min(0) - 0.05
        self.hi = pts.max(0) + 0.05
        self.wheels = wheel_table(dealer_row, work)
        comps = {c['name']: c for c in dealer_row['components'] if c.get('name')}
        hidden = kit_hidden.get(dealer_row['record'], set())
        # A host: a stock body panel the player appearance draws, never one a body kit can hide
        # (its motif would float where the part was), never a scaled one (the decal entity's
        # frame would not follow the scale: unmeasured).
        self.hostable = np.array([
            n not in hidden and n not in self.scaled and not HOST_SKIP_NAME.search(n.lower()) and
            not (set((comps.get(n) or {}).get('flags') or []) & HOST_SKIP_FLAGS) and
            (comps.get(n) or {}).get('type') in ('entPhysicalMeshComponent', 'entMeshComponent')
            for n in self.s.names] + [False])        # index -1 (no component): never a host
        self.bumper = np.array([bool(BUMPER_NAME.search(n.lower())) for n in self.s.names] + [False])
        self.grids = {}

    def grid(self, view):
        if view not in self.grids:
            g = Grid(self.s, self.fn, view, self.step, self.lo, self.hi)
            block_wheels(g, self.wheels)
            g.paint &= ~g.blocked
            self.grids[view] = g
        return self.grids[view]

    def wheel(self, end, view):
        ws = [w for w in self.wheels if w['end'] == end]
        return min(ws, key=lambda w: w['centre'][0]) if view == 'left' else max(ws, key=lambda w: w['centre'][0])

    def hosts_in(self, g, region, bumpers=False):
        """Hostable components owning fit cells of a region, most cells first (at most CANDIDATES);
        bumpers only when asked (the rear zone)."""
        cells = g.comp[region & g.paint]
        cells = cells[self.hostable[cells] & (bumpers | ~self.bumper[cells])]
        if not len(cells):
            return []
        count = np.bincount(cells, minlength=len(self.s.names))
        order = [int(i) for i in np.argsort(-count, kind='stable') if count[i] * g.step ** 2 >= MIN_CANDIDATE]
        return order[:CANDIDATES]


# --------------------------------------------------------------------------- zones
class Zone:
    """Where a zone is on one model: its view and the hosts to try, each (component, fit cells, anchor);
    belt: for side zones, the height (metres) of the top of the front door's paint (the belt line)."""

    def __init__(self, name, view, cands=None, reason=None, belt=None):
        self.name, self.view, self.cands, self.reason, self.belt = name, view, cands or [], reason, belt


def top_regions(md):
    """hood / roof / trunk regions (bool grids of the top view) from the centre line seen from above.

    On the centre line (|x| <= 15 cm) the rows whose drawn cells are mostly glass (or paint over
    glass) make glass runs, kept when they reach the upper part of the car (CABIN_GLASS: not a
    headlight cover): the frontmost is the windscreen, the rearmost other one the rear
    window. hood = ahead of the windscreen, roof = between them (behind the windscreen to the end
    when no rear window shows from above), trunk = behind the rear window. A roof must reach the
    windscreen's top (a cabin); a bike's screen has none: its hood region is then the tank,
    between the wheel axles, and it has no roof and no trunk.
    """
    g = md.grid('top')
    aa, bb = g.ab()
    band = np.abs(g.b) <= 0.15
    zc = np.where(np.isfinite(g.depth), -g.depth, np.nan)
    glassy = (g.kind == KIND_GLASS) | g.over_glass
    rows = np.zeros(g.na, bool)
    for i in range(g.na):
        v = g.valid[i, band]
        rows[i] = v.sum() >= band.sum() * 0.5 and glassy[i, band][v].mean() > 0.5
    with np.errstate(all='ignore'):
        z_drawn = zc[np.isfinite(zc)]
        cabin_z = float(z_drawn.min() + CABIN_GLASS * (z_drawn.max() - z_drawn.min()))
        glass = [r for r in runs(rows) if (r[1] - r[0]) * g.step >= 0.08
                 and float(np.nanmax(np.where(glassy[r[0]:r[1]][:, band], zc[r[0]:r[1]][:, band], np.nan))) >= cabin_z]
    yf = md.wheel('front', 'left')['centre'][1]
    yb = md.wheel('back', 'left')['centre'][1]
    if glass:
        ws = max(glass, key=lambda r: r[1])           # the grid runs along +y: the largest rows are the front
        rw = min(glass, key=lambda r: r[0])
        rw = None if rw == ws else rw
        ws_lo, ws_hi = g.a[ws[0]], g.a[ws[1] - 1]
        with np.errstate(all='ignore'):
            ws_top = float(np.nanmax(zc[ws[0]:ws[1]][:, band]))
        roof = (aa < ws_lo) & (aa > (g.a[rw[1] - 1] if rw else -1e9))
        roof_z = np.where(roof & g.paint & (np.abs(bb) <= 0.3), zc, np.nan)
        cabin = bool(np.isfinite(roof_z).any()) and float(np.nanmax(roof_z)) >= ws_top - 0.06
        if cabin:
            out = {'hood': aa > ws_hi, 'roof': roof}
            if rw:
                out['trunk'] = aa < g.a[rw[0]]
            return g, out
    return g, {'hood': (aa < yf) & (aa > yb)}


def side_regions(md, view):
    """name -> list of (component, fit cells) to try, name -> anchor (None: the cells' centroid),
    and the belt height. door2: the doors entirely behind the front one (a four-door's rear door)."""
    g = md.grid(view)
    aa, bb = g.ab()
    wf, wb = md.wheel('front', view), md.wheel('back', view)
    yf, zf, rf = wf['centre'][1], wf['centre'][2], wf['tyre']
    yb, zb, rb = wb['centre'][1], wb['centre'][2], wb['tyre']
    between = (aa < yf - rf) & (aa > yb + rb)
    doors = []
    for ci in np.unique(g.comp[g.paint]):
        if md.hostable[ci] and DOOR_NAME.search(md.s.names[ci].lower()):
            mask = g.paint & (g.comp == ci)
            if mask.sum() * g.step ** 2 >= 0.05:
                doors.append((float(aa[mask].mean()), int(ci), mask))
    doors.sort(key=lambda d: -d[0])                   # the front door first
    cands, anchors = {}, {}
    # No door (a bike): the side's largest hostable panels, wherever they are.
    cands['door'] = [(ci, mask) for _y, ci, mask in doors] or \
        [(ci, g.paint & (g.comp == ci)) for ci in md.hosts_in(g, g.valid)]
    door_cells = doors[0][2] if doors else None
    cands['door2'] = [(ci, mask) for _y, ci, mask in doors[1:] if float(aa[mask].max()) <= float(aa[door_cells].min()) + 0.05]
    paint_b = bb[g.paint]
    belt = float(bb[door_cells].max()) if doors else (float(paint_b.max()) if len(paint_b) else zf + 0.5)
    door_front = float(aa[door_cells].max()) if doors else yf - rf - 0.3
    door_rear = float(aa[doors[-1][2]].min()) if doors else yb + rb + 0.3
    regions = {}
    low = between & g.paint
    if low.any():
        z_low = float(np.percentile(bb[low], 3))
        regions['sill'] = between & (bb <= z_low + 0.22)
        anchors['sill'] = ((yf - rf + yb + rb) / 2, z_low)
    regions['wing_f'] = (aa >= door_front - 0.02) & (aa <= yf + rf + 0.2) & (bb >= zf) & (bb <= belt)
    regions['wing_r'] = (aa <= door_rear + 0.02) & (aa >= yb - rb - 0.2) & (bb >= zb) & (bb <= belt)
    for k, region in regions.items():
        cands[k] = [(ci, g.paint & (g.comp == ci) & region) for ci in md.hosts_in(g, region)]
    return g, cands, anchors, belt


def with_anchor(g, ci, mask, anchor):
    aa, bb = g.ab()
    return (ci, mask, anchor if anchor is not None else (float(aa[mask].mean()), float(bb[mask].mean())))


def find_zones(md, wanted):
    """zone name -> Zone (no candidates and a reason when the model has no such panel)."""
    zones = {}
    if wanted & {'hood', 'roof', 'trunk'}:
        g, regions = top_regions(md)
        aa, bb = g.ab()
        for name in sorted(wanted & {'hood', 'roof', 'trunk'}):
            if name not in regions:
                zones[name] = Zone(name, 'top', reason='no such panel seen from above (no cabin, or no rear window)')
                continue
            cands = [with_anchor(g, ci, g.paint & (g.comp == ci) & regions[name], None)
                     for ci in md.hosts_in(g, regions[name] & (np.abs(bb) <= 0.3))]
            cands = [(ci, m, (a[0], 0.0)) for ci, m, a in cands]
            zones[name] = Zone(name, 'top', cands, None if cands else 'no hostable paint on the centre line')
    if 'rear' in wanted:
        g = md.grid('rear')
        aa, bb = g.ab()
        region = bb >= 0.0
        cands = [with_anchor(g, ci, g.paint & (g.comp == ci) & region, None)
                 for ci in md.hosts_in(g, region & (np.abs(aa) <= 0.3), bumpers=True)]
        cands = [(ci, m, (0.0, a[1])) for ci, m, a in cands]
        zones['rear'] = Zone('rear', 'rear', cands, None if cands else 'no hostable paint facing rear')
    for view, sfx in (('left', 'l'), ('right', 'r')):
        names = {'door': f'door_{sfx}', 'sill': f'sill_{sfx}', 'wing_f': f'wing_f{sfx}', 'wing_r': f'wing_r{sfx}',
                 'door2': f'door2_{sfx}'}
        if not wanted & set(names.values()):
            continue
        g, cands, anchors, belt = side_regions(md, view)
        for key, name in names.items():
            if name not in wanted:
                continue
            cs = [with_anchor(g, ci, mask, anchors.get(key)) for ci, mask in cands.get(key, []) if mask.any()]
            reason = 'no second door behind the front one' if key == 'door2' else 'no hostable paint in the region'
            zones[name] = Zone(name, view, cs, None if cs else reason, belt)
    return zones


def pair_candidates(md, zs):
    """Candidate tuples, one host per zone: a pair takes the right side's component that mirrors
    the left one's name (door_fl_a / door_fr_a, body_01 / body_01), else the same rank."""
    if len(zs) == 1:
        return [(c,) for c in zs[0].cands]
    left, right = zs
    by_name = {md.s.names[c[0]]: c for c in right.cands}
    out = []
    for i, c in enumerate(left.cands):
        n = md.s.names[c[0]]
        mate = by_name.get(n) or by_name.get(mirror_name(n)) or (right.cands[i] if i < len(right.cands) else None)
        if mate is not None:
            out.append((c, mate))
    return out


# --------------------------------------------------------------------------- motifs
class Motif:
    def __init__(self, theme, m, art_dir):
        self.theme, self.m = theme, m
        self.id, self.stem = m['id'], f'{theme["id"]}_{m["id"]}'
        self.size = (m['size'][0] / 100.0, m['size'][1] / 100.0)     # metres, (u, v)
        self.mirror = bool(m.get('mirror'))
        self.crop = m.get('crop')
        self.crop_keep = m.get('cropKeep', 'middle')
        self.min_length = m.get('minLength', 0) / 100.0
        self.max_length = m.get('maxLength', m['size'][1 if self.crop != 'u' else 0]) / 100.0
        self.min_scale = float(m.get('minScale', 0.5))
        self.optional = bool(m.get('optional'))
        self.align_to = m.get('alignTo')
        self.anchor_z = m.get('anchorZ')
        self.anchor_offset = m.get('anchorOffset', 0) / 100.0
        self.anchor_weight = float(m.get('anchorWeight', 0))
        tol = m.get('alignTolerance')
        self.align_tol = None if tol is None else tol / 100.0
        self.fallback, self.of = None, None           # set by with_fallbacks: the emblem art, its primary
        img = Image.open(Path(art_dir) / f'{self.stem}_d.png')
        self.rgba = np.asarray(img.convert('RGBA'), np.float32) / 255.0
        self.alpha = self.rgba[..., 3]

    def footprint(self, view, mirrored, scale, step):
        """Cells under any opaque texel of the motif in the view's plane (A, B), dilated by one cell."""
        nu = max(1, int(round(self.size[0] * scale / step)))
        nv = max(1, int(round(self.size[1] * scale / step)))
        a = Image.fromarray((self.alpha * 255).astype(np.uint8), 'L').resize((nu, nv), Image.BOX)
        img = np.asarray(a) > 2
        ua, us, va, vs = orient(view, mirrored)
        arr = img.T if ua == 0 else img
        if us < 0:
            arr = np.flip(arr, ua)
        if vs < 0:
            arr = np.flip(arr, va)
        return dilate(np.ascontiguousarray(arr), 1)

    def _px(self, fu, fv):
        h, w = self.alpha.shape
        return ((np.asarray(fv) * h).astype(np.int64).clip(0, h - 1), (np.asarray(fu) * w).astype(np.int64).clip(0, w - 1))

    def sample_alpha(self, fu, fv, alpha=None):
        return (self.alpha if alpha is None else alpha)[self._px(fu, fv)]

    def cell_alpha(self, pl, step):
        """The alpha at the cell size of a placement: per texel, the largest alpha of the texels
        one cell (step) centred there covers, so a line thinner than a cell (a pinstripe, a trace
        at a small scale) still counts as opaque where it runs, whatever its phase on the grid."""
        ua, _us, va, _vs = ORIENT[pl.zone.view]
        (u0, v0), (u1, v1) = pl.uv
        h, w = self.alpha.shape
        out = self.alpha
        for axis, n, span, ext in ((1, w, u1 - u0, pl.ext[ua]), (0, h, v1 - v0, pl.ext[va])):
            k = int(math.ceil(step / ext * span * n)) | 1        # texels per cell, odd: centred
            if k > 1:
                pad = [(0, 0), (0, 0)]
                pad[axis] = (k // 2, k // 2)
                out = np.lib.stride_tricks.sliding_window_view(np.pad(out, pad), k, axis=axis).max(-1)
        return out

    def sample_rgba(self, fu, fv):
        return self.rgba[self._px(fu, fv)]


class Placement:
    """centre and ext in the view's plane (A, B), metres; uv = ((u0, v0), (u1, v1)) of the texture."""

    def __init__(self, zone, host, motif, scale, centre, ext, mirrored, uv=((0.0, 0.0), (1.0, 1.0))):
        self.zone, self.host, self.motif, self.scale = zone, host, motif, scale
        self.centre, self.ext, self.mirrored, self.uv = centre, ext, mirrored, uv

    def area(self):
        return self.ext[0] * self.ext[1]


def scales_from(top, low):
    s, out = top, []
    while s >= low - 1e-9:
        out.append(round(s, 4))
        s -= SCALE_STEP
    return out


def plane_ext(view, motif, s, length=None, u_length=None):
    ua, _us, va, _vs = ORIENT[view]
    ext = [0.0, 0.0]
    ext[ua] = u_length if u_length is not None else motif.size[0] * s
    ext[va] = length if length is not None else motif.size[1] * s
    return tuple(ext)


def free_cells(g, mask):
    return erode(mask & ~g.taken, int(round(MARGIN / g.step)))


def fit_side_at(md, motif, zs, cand, s):
    """One candidate tuple (one host per zone) at scale s. A pair fits on both sides at once: the
    right side's valid corners intersected with the left's (the two views share the plane y, z)."""
    valid, mirrors, fa, fb = None, [], 0, 0
    for z, (ci, mask, _anchor) in zip(zs, cand):
        g = md.grid(z.view)
        mirrored = z.view == 'right' and motif.mirror
        fp = motif.footprint(z.view, mirrored, s, md.step)
        fa, fb = fp.shape
        mirrors.append(mirrored)
        v = fit_offsets(~free_cells(g, mask), fp)
        if not v.size:
            return None
        valid = v if valid is None else valid & v
    if not valid.any():
        return None
    g = md.grid(zs[0].view)
    ia, ib = np.nonzero(valid)
    ca = g.a[0] + (ia + (fa - 1) / 2) * md.step
    cb = g.b[0] + (ib + (fb - 1) / 2) * md.step
    ax = float(np.mean([c[2][0] for c in cand]))
    bx = float(np.mean([c[2][1] for c in cand]))
    k = int(np.argmin((ca - ax) ** 2 + (cb - bx) ** 2))
    return [Placement(z, c[0], motif, s, (float(ca[k]), float(cb[k])), plane_ext(z.view, motif, s), m)
            for z, c, m in zip(zs, cand, mirrors)]


def fit_side_crop_at(md, motif, zs, cand, s, anchor_z=None, tol=None):
    """A side motif with crop 'u' (a band along the car: a sill band, a pinstripe segment) at
    scale s: it keeps its height (v, at scale s) and runs along the car as far as the panel lets
    it, at least minLength, at most maxLength. A pair fits on both sides at once (the valid
    positions intersected, as fit_side_at). Among the rows and runs that fit, the longest wins,
    less anchorWeight x its distance to the anchor height (anchor_z when given: a belt line, the
    segment it aligns to; tol: no row farther than that from it), then the one nearest the
    anchor. Shorter than the art: the part
    cropKeep names (start = the front end, the end at u = 0; end = the rear end; middle); a
    capped segment hugs the end of its run nearest its neighbour (start: the rear end, towards
    the door; end: the front end; middle: nearest the anchor). Longer: the art stretched."""
    ok_all, nv, mirrors = None, 0, []
    for z, (ci, mask, _anchor) in zip(zs, cand):
        g = md.grid(z.view)
        mirrored = z.view == 'right' and motif.mirror
        mirrors.append(mirrored)
        fp = motif.footprint(z.view, mirrored, s, md.step)
        prof = fp.any(axis=0)                         # the height rows under any opaque texel
        nv = fp.shape[1]
        bad = ~free_cells(g, mask)
        nb = bad.shape[1]
        if nv > nb:
            return None
        acc = np.zeros((bad.shape[0], nb - nv + 1), bool)
        for j in np.nonzero(prof)[0]:
            acc |= bad[:, j:j + nb - nv + 1]
        ok_all = ~acc if ok_all is None else ok_all & ~acc
    if not ok_all.any():
        return None
    g = md.grid(zs[0].view)
    ay = float(np.mean([c[2][0] for c in cand]))
    az = float(np.mean([c[2][1] for c in cand])) if anchor_z is None else float(anchor_z)
    full = motif.size[0] * s
    best = None
    for j0 in np.nonzero(ok_all.any(0))[0].tolist():
        zc = float(g.b[0] + (j0 + (nv - 1) / 2) * md.step)
        if tol is not None and abs(zc - az) > tol + 1e-9:
            continue
        for r0, r1 in runs(ok_all[:, j0]):
            length = (r1 - r0 - 1) * md.step              # centres of the first and last good cells
            if length < motif.min_length - 1e-9:
                continue
            L = min(length, motif.max_length)
            rear, front = float(g.a[r0]), float(g.a[r1 - 1])
            if motif.crop_keep == 'start':
                yc = rear + L / 2
            elif motif.crop_keep == 'end':
                yc = front - L / 2
            else:
                yc = min(max(ay, rear + L / 2), front - L / 2)
            key = (round(L - motif.anchor_weight * abs(zc - az), 6), -round(abs(yc - ay) + abs(zc - az), 6))
            if best is None or key > best[0]:
                best = (key, yc, zc, L)
    if best is None:
        return None
    _key, yc, zc, L = best
    f = min(1.0, L / full)
    uv = {'start': ((0.0, 0.0), (f, 1.0)), 'end': ((1.0 - f, 0.0), (1.0, 1.0)),
          'middle': ((0.5 - f / 2, 0.0), (0.5 + f / 2, 1.0))}[motif.crop_keep]
    return [Placement(z, c[0], motif, s, (yc, zc), plane_ext(z.view, motif, s, u_length=L), m, uv)
            for z, c, m in zip(zs, cand, mirrors)]


def fit_centre_at(md, motif, zone, cand, s):
    """A centre zone on the car's centre line (x = 0 seen from above or from behind), at scale s.
    A motif with crop 'v' keeps its width and runs along v as far as the panel lets it (stripes)."""
    ci, mask, anchor = cand
    g = md.grid(zone.view)
    mk = free_cells(g, mask)
    _ua, _us, va, _vs = ORIENT[zone.view]
    across = 1 if zone.view == 'top' else 0           # the plane axis that is x: B seen from above, A from behind
    along = 1 - across
    coords = g.b if across == 1 else g.a
    base = g.a[0] if along == 0 else g.b[0]
    fp = motif.footprint(zone.view, False, s, md.step)
    n_x = fp.shape[across]
    off = int(round((0.0 - coords[0]) / md.step - (n_x - 1) / 2))
    if off < 0 or off + n_x > len(coords):
        return None
    cx = float(coords[0] + (off + (n_x - 1) / 2) * md.step)
    centre = [0.0, 0.0]
    if motif.crop == 'v':
        if va != along:
            fail(f'{motif.stem}: crop along v needs v along the car in the {zone.view} view')
        prof = fp.any(axis=along)
        sub = mk[:, off:off + n_x] if across == 1 else mk[off:off + n_x, :].T
        ok = ~(~sub & prof[None, :]).any(1)
        best = None
        for r0, r1 in runs(ok):
            length = (r1 - r0 - 1) * md.step          # centres of the first and last good rows
            if length < motif.min_length:
                continue
            key = (min(length, motif.max_length), -abs(base + (r0 + r1 - 1) / 2 * md.step - anchor[along]))
            if best is None or key > best[0]:
                best = (key, r0, r1)
        if best is None:
            return None
        (length, _), r0, r1 = best
        full = motif.size[1] * s
        centre[along], centre[across] = base + (r0 + r1 - 1) / 2 * md.step, cx
        # Shorter than the art: its middle part (the bands run along v). Longer (up to
        # maxLength): the whole art stretched along v, never a uv past 1 (no wrap assumed).
        f = min(1.0, length / full)
        return [Placement(zone, ci, motif, s, tuple(centre), plane_ext(zone.view, motif, s, length), False,
                          ((0.0, 0.5 - f / 2), (1.0, 0.5 + f / 2)))]
    valid = fit_offsets(~mk, fp)
    if not valid.size:
        return None
    line = valid[:, off] if across == 1 else valid[off, :]
    if not line.any():
        return None
    idx = np.nonzero(line)[0]
    c = base + (idx + (fp.shape[along] - 1) / 2) * md.step
    k = int(np.argmin(np.abs(c - anchor[along])))
    centre[along], centre[across] = float(c[k]), cx
    return [Placement(zone, ci, motif, s, tuple(centre), plane_ext(zone.view, motif, s), False)]


def record_skip(skipped, zone, reason):
    for s in skipped:
        if s['zone'] == zone:
            s['reason'] = reason
            return
    skipped.append({'zone': zone, 'reason': reason})


def zone_groups(motif, zones):
    """The motif's zones as fit units: a pair (left first) or a single zone."""
    names, done, out = motif.m['zones'], set(), []
    for zn in names:
        if zn in done:
            continue
        mate = PAIRS.get(zn) or next((a for a, b in PAIRS.items() if b == zn), None)
        group = [zn] + ([mate] if mate in names else [])
        group.sort(key=lambda z: z in PAIRS.values())
        done.update(group)
        out.append([zones[z] for z in group])
    return out


def fit_unit_at(md, motif, zs, s):
    """The first candidate (largest share of the region first) that fits at scale s."""
    for cand in pair_candidates(md, zs):
        pls = (fit_centre_at(md, motif, zs[0], cand[0], s) if ZONES[zs[0].name][1] == 'centre'
               else fit_side_at(md, motif, zs, cand, s))
        if pls:
            return pls
    return None


def take(md, pls):
    for pl in pls:
        md.grid(pl.zone.view).take(pl.centre, pl.ext)


def fit_crop_unit(md, motif, zs, anchor):
    """A crop 'u' unit: at each scale (1 down to minScale) the first candidate that fits, and of
    those the largest area (length x height), the larger scale on a tie. anchor: (height or None,
    follows: True when it is the height of a segment this one continues, alignTolerance then
    binding)."""
    anchor_z, follows = anchor
    tol = motif.align_tol if follows else None
    best, best_area = None, 0.0
    for s in scales_from(1.0, motif.min_scale):
        for cand in pair_candidates(md, zs):
            pls = fit_side_crop_at(md, motif, zs, cand, s, anchor_z, tol)
            if pls:
                area = sum(p.area() for p in pls)
                if area > best_area + 1e-9:
                    best, best_area = pls, area
                break
    return best


def crop_anchor(motif, zs, placed, first):
    """(height, follows) of a crop 'u' unit's anchor: the placed segment it aligns to (alignTo,
    same view) or the unit before it of the same motif (a rear door follows the front one), both
    followed (alignTolerance binds); else the belt (anchorZ 'belt' + anchorOffset); else None
    (the host's centroid)."""
    if motif.align_to:
        same = [p for p in placed if p.motif.id == motif.align_to and p.zone.view == zs[0].view]
        if same:
            return same[0].centre[1], True
    if first is not None:
        return first, True
    if motif.anchor_z == 'belt' and zs[0].belt is not None:
        return zs[0].belt + motif.anchor_offset, False
    return None, False


def fit_motif(md, motif, zones, skipped, placed=()):
    """Placements of one motif over its zones, each unit at the largest scale that fits (crop 'u':
    the largest area, fit_crop_unit)."""
    out, first = [], None
    for zs in zone_groups(motif, zones):
        missing = [z for z in zs if not z.cands]
        if missing:
            for z in zs:
                record_skip(skipped, z.name, z.reason if not z.cands else f'its pair {missing[0].name} has no panel')
            continue
        if motif.crop == 'u':
            anchor = crop_anchor(motif, zs, list(placed) + out, first)
            pls = fit_crop_unit(md, motif, zs, anchor)
            if pls:
                take(md, pls)
                out += pls
                first = pls[0].centre[1] if first is None else first
            else:
                for z in zs:
                    near = (f' within {motif.align_tol * 100:g} cm of the line it continues'
                            if motif.align_tol is not None and anchor[1] else '')
                    record_skip(skipped, z.name, f'no run of {motif.min_length * 100:.0f} cm at scale {motif.min_scale} '
                                                 f'or more{near} on {", ".join(md.s.names[c[0]] for c in z.cands)}')
            continue
        pls = None
        for mo in (motif, motif.fallback):
            for s in scales_from(1.0, mo.min_scale) if mo else []:
                pls = fit_unit_at(md, mo, zs, s)
                if pls:
                    break
            if pls:
                take(md, pls)
                out += pls
                break
        else:
            fb = (f' (nor its fallback {motif.fallback.id} at {motif.fallback.min_scale})' if motif.fallback else '')
            for z in zs:
                record_skip(skipped, z.name, f'no room at scale {motif.min_scale} or more{fb} on '
                                             f'{", ".join(md.s.names[c[0]] for c in z.cands)}')
    return out


def with_fallbacks(theme, motifs, art_dir):
    """A motif's fallback: another motif's art of the theme (an emblem), on the motif's own zones,
    mirrored as the motif is, from scale 1 down to the fallback's minScale, for the units the
    motif itself has no room for even at its minScale (a bike's side panels take no long side
    motif). Its decals use that art's texture: nothing new in the pack."""
    by_id = {mo.id: mo.m for mo in motifs}
    for mo in motifs:
        fb = mo.m.get('fallback')
        if fb:
            art = {k: v for k, v in by_id[fb['motif']].items() if k not in ('crop', 'scaleGroup', 'optional', 'fallback')}
            art.update(zones=mo.m['zones'], mirror=bool(mo.m.get('mirror')), minScale=fb['minScale'])
            mo.fallback = Motif(theme, art, art_dir)
            mo.fallback.of = mo
    return motifs


def fit_group(md, motifs, zones, skipped):
    """Motifs of one scaleGroup share one scale: the one giving the largest total area (length x
    width over every member's zones), the larger scale on a tie. A member without room at that
    scale takes, alone, the scale below it giving its own largest area (its row says which)."""
    units = [(mo, zs) for mo in motifs for zs in zone_groups(mo, zones)]
    for mo, zs in units:
        missing = [z for z in zs if not z.cands]
        for z in zs:
            if missing:
                record_skip(skipped, z.name, z.reason if not z.cands else f'its pair {missing[0].name} has no panel')
    units = [(mo, zs) for mo, zs in units if all(z.cands for z in zs)]
    low = max(mo.min_scale for mo in motifs)
    best, best_area = None, 0.0
    for s in scales_from(1.0, low):
        got = [(mo, zs, fit_unit_at(md, mo, zs, s)) for mo, zs in units]
        area = sum(sum(p.area() for p in pls) for _mo, _zs, pls in got if pls)
        if area > best_area + 1e-9:
            best, best_area = (s, got), area
    out = []
    top = best[0] if best else 1.0 + SCALE_STEP
    for mo, zs, pls in (best[1] if best else [(mo, zs, None) for mo, zs in units]):
        if not pls:     # no room at the group's scale: this member alone, narrower, largest area first
            tries = [fit_unit_at(md, mo, zs, s) for s in scales_from(top - SCALE_STEP, mo.min_scale)]
            tries = [t for t in tries if t]
            pls = max(tries, key=lambda t: sum(p.area() for p in t)) if tries else None
        if pls:
            take(md, pls)
            out += pls
        else:
            for z in zs:
                record_skip(skipped, z.name, f'no room at scale {mo.min_scale} or more on '
                                             f'{", ".join(md.s.names[c[0]] for c in z.cands)}')
    return out


# --------------------------------------------------------------------------- meshes
def grid_hits(view, tris, a0, b0, da, db, na, nb):
    """Exact ray hits at (a0 + i*da, b0 + j*db), i < na, j < nb: owner triangle index (or -1), depth."""
    A, B = AXIS[RASTER_VIEWS[view][0]], AXIS[RASTER_VIEWS[view][1]]
    t = tris.copy()
    t[..., A] = (t[..., A] - a0) / da
    t[..., B] = (t[..., B] - b0) / db
    lo, hi = np.full(3, -1e4), np.full(3, 1e4)
    lo[A] = lo[B] = 0.0
    hi[A], hi[B] = na - 1 + 1e-9, nb - 1 + 1e-9
    owner, zbuf, _geo, _ = raster(t, view, 1.0, lo, hi)
    return owner, zbuf


def build_mesh(md, pl, spacing, offset):
    """Decal quads over the placed rectangle where they land on the host (lv_decals.py's quad rules:
    four corners on the host's paint, depth spread, centre on the host within 1 cm, facing)."""
    z = pl.zone
    view = z.view
    host = pl.host
    A, B = AXIS[RASTER_VIEWS[view][0]], AXIS[RASTER_VIEWS[view][1]]
    d_axis, d_sign = RASTER_VIEWS[view][2], RASTER_VIEWS[view][3]
    cam = np.array(RASTER_VIEWS[view][4])
    eA, eB = pl.ext
    step = min(spacing, min(eA, eB) / 8)
    na, nb = int(math.ceil(eA / step)) + 1, int(math.ceil(eB / step)) + 1
    da, db = eA / (na - 1), eB / (nb - 1)
    a0, b0 = pl.centre[0] - eA / 2, pl.centre[1] - eB / 2
    t = md.s.tris
    sel = np.nonzero((t[:, :, A].max(1) >= a0 - 0.05) & (t[:, :, A].min(1) <= a0 + eA + 0.05) &
                     (t[:, :, B].max(1) >= b0 - 0.05) & (t[:, :, B].min(1) <= b0 + eB + 0.05))[0]
    tris = t[sel]
    owner, zbuf = grid_hits(view, tris, a0, b0, da, db, na, nb)
    own_c, z_c = grid_hits(view, tris, a0 + da / 2, b0 + db / 2, da, db, na - 1, nb - 1)
    valid = owner >= 0
    ow = sel[owner.clip(0)]
    n = md.fn[ow]
    f = (n * cam).sum(-1)
    n = np.where(f[..., None] < 0, -n, n)
    comp = np.where(valid, md.s.comp[ow], -1)
    good = valid & (comp == host) & (md.s.kind[ow] == KIND_PAINT) & (np.abs(f) >= MESH_FACING)
    zs = np.stack([zbuf[:-1, :-1], zbuf[1:, :-1], zbuf[:-1, 1:], zbuf[1:, 1:]], 0)
    with np.errstate(invalid='ignore'):
        spread = np.nan_to_num(zs.max(0) - zs.min(0), nan=1e9, posinf=1e9)
        hit_c = own_c >= 0
        oc = sel[own_c.clip(0)]
        centre_ok = hit_c & (np.where(hit_c, md.s.comp[oc], -1) == host) & (np.abs(z_c - zs.mean(0)) <= CENTRE_TOLERANCE)
    quad = good[:-1, :-1] & good[1:, :-1] & good[:-1, 1:] & good[1:, 1:] & (spread <= 2.5 * max(da, db)) & centre_ok
    if not quad.any():
        return None
    ia, ib = np.meshgrid(np.arange(na), np.arange(nb), indexing='ij')
    p = np.zeros((na, nb, 3))
    p[..., A] = a0 + ia * da
    p[..., B] = b0 + ib * db
    p[..., d_axis] = d_sign * np.where(np.isfinite(zbuf), zbuf, 0)
    o = orient(view, pl.mirrored)
    ua, us, va, vs = o
    fa_, fb_ = ia / (na - 1), ib / (nb - 1)
    fu = fa_ if ua == 0 else fb_
    fv = fb_ if va == 1 else fa_
    fu = fu if us > 0 else 1 - fu
    fv = fv if vs > 0 else 1 - fv
    (u0, v0), (u1, v1) = pl.uv
    uvs = np.stack([u0 + fu * (u1 - u0), v0 + fv * (v1 - v0)], -1)
    udir, vdir = axis_dirs(view, o)
    qa, qb = np.nonzero(quad)
    used = np.zeros((na, nb), bool)
    for d1, d2 in ((0, 0), (1, 0), (0, 1), (1, 1)):
        used[qa + d1, qb + d2] = True
    vid = np.full((na, nb), -1, np.int64)
    va_, vb_ = np.nonzero(used)
    vid[va_, vb_] = np.arange(len(va_))
    tf = md.s.frames[md.s.names[host]]
    pos, nor, tan, uv, world = [], [], [], [], []
    for a_, b_ in zip(va_.tolist(), vb_.tolist()):
        nn = n[a_, b_]
        wp = p[a_, b_] + nn * offset
        world.append(wp)
        pos.append(tuple(inverse_apply(tf, tuple(wp))))
        nor.append(unit(inverse_rotate(tf, tuple(nn))))
        tt = udir - nn * float(udir @ nn)
        tt = tt / (np.linalg.norm(tt) or 1.0)
        hand = 1.0 if float(np.cross(nn, tt) @ vdir) >= 0 else -1.0
        tan.append(unit(inverse_rotate(tf, tuple(tt))) + (hand,))
        uv.append((float(uvs[a_, b_, 0]), float(uvs[a_, b_, 1])))
    world = np.array(world)
    i00, i10, i01, i11 = vid[qa, qb], vid[qa + 1, qb], vid[qa, qb + 1], vid[qa + 1, qb + 1]
    gn = np.cross(world[i10] - world[i00], world[i01] - world[i00])
    flip = (gn * cam).sum(-1) < 0
    t1 = np.where(flip[:, None], np.stack([i00, i01, i10], 1), np.stack([i00, i10, i01], 1))
    t2 = np.where(flip[:, None], np.stack([i10, i01, i11], 1), np.stack([i10, i11, i01], 1))
    idx = np.concatenate([t1, t2], 1).reshape(-1)
    tri = idx.reshape(-1, 3)
    return {'pos': pos, 'nor': nor, 'tan': tan, 'uv': uv, 'idx': idx.tolist(),
            'world': world[tri], 'uvTri': np.array(uv)[tri], 'cell': [round(da, 4), round(db, 4)]}


def expected_uv(pl, aa, bb, inset=0.0):
    """Texture uv of plane points under the placed rectangle (no surface involved), and inside
    (the rectangle shrunk by `inset` metres, the cell size: a cell astride its edge is not
    evidence either way). A thin band (a pinstripe, a sill line) is shrunk less: at most a
    quarter of its side, and never below a middle window one cell wide, so one row of cells is
    inside it whatever its phase on the grid."""
    eA, eB = pl.ext

    def shrink(e):
        return min(inset, e / 4, max(0.0, (e - inset) / 2 - 1e-6)) / e
    ra = (aa - (pl.centre[0] - eA / 2)) / eA
    rb = (bb - (pl.centre[1] - eB / 2)) / eB
    ha, hb = shrink(eA), shrink(eB)
    ua, us, va, vs = orient(pl.zone.view, pl.mirrored)
    fu = ra if ua == 0 else rb
    fv = rb if va == 1 else ra
    fu = fu if us > 0 else 1 - fu
    fv = fv if vs > 0 else 1 - fv
    (u0, v0), (u1, v1) = pl.uv
    inside = (ra >= ha) & (ra <= 1 - ha) & (rb >= hb) & (rb <= 1 - hb)
    return u0 + fu * (u1 - u0), v0 + fv * (v1 - v0), inside


def check_decal(md, pl, mesh):
    """Of the motif's opaque texels, at the fit step in the zone's view (a cell is opaque when a
    texel it covers is, cell_alpha): the share the mesh carries, the share drawn in front of the
    body, over the host, floating; opaque cells over a wheel disc."""
    g = md.grid(pl.zone.view)
    owner, zbuf, _geo, bary = raster(mesh['world'], g.view, g.step, g.lo, g.hi, want_bary=True)
    drawn = owner >= 0
    uvc = (mesh['uvTri'][owner.clip(0)] * bary[..., None]).sum(-2)
    alpha = pl.motif.cell_alpha(pl, g.step)
    opaque = drawn & (pl.motif.sample_alpha(uvc[..., 0], uvc[..., 1], alpha) > 0.5)
    aa, bb = g.ab()
    eu, ev, inside = expected_uv(pl, aa, bb, g.step)
    want = inside & (pl.motif.sample_alpha(eu, ev, alpha) > 0.5)
    n_want, n_op = int(want.sum()), int(opaque.sum())
    carried = int((want & dilate(drawn, 1)).sum()) / max(1, n_want)
    vis = opaque & (zbuf <= g.depth + DECAL_BEHIND)
    host = vis & (g.comp == pl.host)
    flo = opaque & (zbuf < g.depth - DECAL_FLOAT)
    return {'opaqueCells': n_op, 'carried': round(carried, 4),
            'visible': round(int(vis.sum()) / max(1, n_op), 4), 'onHost': round(int(host.sum()) / max(1, n_op), 4),
            'floating': round(int(flo.sum()) / max(1, n_op), 4), 'onWheels': int((opaque & g.blocked).sum())}


# --------------------------------------------------------------------------- command
def set_budget(spec):
    """The decals one set may carry: maxDecalsPerSet (a light livery must still fit beside it), at
    most maxDecalsPerCar (the engine cap)."""
    return int(spec.get('maxDecalsPerSet', spec['maxDecalsPerCar']))


def check_spec(spec):
    if not 1 <= set_budget(spec) <= int(spec['maxDecalsPerCar']):
        fail(f'maxDecalsPerSet {set_budget(spec)} must be in 1..maxDecalsPerCar {spec["maxDecalsPerCar"]}')
    unknown = [k for k in spec.get('overviewModels', []) if k not in spec['models']]
    if unknown:
        fail(f'overviewModels names models the spec does not build: {", ".join(unknown)}')
    for theme in spec['themes']:
        seen, ids = set(), set()
        for m in theme['motifs']:
            crop = m.get('crop')
            if crop not in (None, 'v', 'u'):
                fail(f'{theme["id"]}/{m["id"]}: crop must be "v" (centre zones) or "u" (side zones)')
            for zn in m['zones']:
                if zn not in ZONES:
                    fail(f'{theme["id"]}/{m["id"]}: unknown zone {zn} (known: {", ".join(ZONES)})')
                if crop == 'v' and ZONES[zn][1] != 'centre':
                    fail(f'{theme["id"]}/{m["id"]}: crop is for the centre zones (hood, roof, trunk, rear), not {zn}')
                if crop == 'u' and ZONES[zn][1] != 'side':
                    fail(f'{theme["id"]}/{m["id"]}: crop "u" is for the side zones (doors, sills, wings), not {zn}')
                if (m.get('anchorZ') or m.get('alignTo')) and ZONES[zn][1] != 'side':
                    fail(f'{theme["id"]}/{m["id"]}: anchorZ / alignTo are for the side zones, not {zn}')
                if zn in seen:
                    fail(f'{theme["id"]}: zone {zn} is named by two motifs')
                seen.add(zn)
            if m.get('cropKeep', 'middle') not in CROP_KEEP or ('cropKeep' in m and crop != 'u'):
                fail(f'{theme["id"]}/{m["id"]}: cropKeep is {" | ".join(CROP_KEEP)}, with crop "u" only')
            if (m.get('anchorZ') or m.get('alignTo') or m.get('anchorWeight') or 'alignTolerance' in m) and crop != 'u':
                fail(f'{theme["id"]}/{m["id"]}: anchorZ, alignTo, anchorWeight and alignTolerance need crop "u"')
            if 'alignTolerance' in m and not 0 <= float(m['alignTolerance']) <= 20:
                fail(f'{theme["id"]}/{m["id"]}: alignTolerance must be in 0..20 cm')
            if m.get('anchorZ') not in (None, 'belt'):
                fail(f'{theme["id"]}/{m["id"]}: anchorZ must be "belt"')
            if m.get('alignTo') is not None and m['alignTo'] not in ids:
                fail(f'{theme["id"]}/{m["id"]}: alignTo names {m["alignTo"]!r}, not an earlier motif of the theme')
            if not 0 < float(m.get('minScale', 0.5)) <= 1:
                fail(f'{theme["id"]}/{m["id"]}: minScale must be in (0, 1]')
            fb = m.get('fallback')
            if fb is not None:
                art = next((o for o in theme['motifs'] if o['id'] == fb.get('motif') and o is not m), None)
                if art is None or crop or art.get('crop') or m.get('scaleGroup'):
                    fail(f'{theme["id"]}/{m["id"]}: fallback names another motif of the theme, without crop, '
                         f'for a motif without crop or scaleGroup')
                if not 0 < float(fb.get('minScale', 0)) <= 1:
                    fail(f'{theme["id"]}/{m["id"]}: fallback minScale must be in (0, 1]')
            ids.add(m['id'])
        if len(seen) > int(spec['maxDecalsPerCar']):
            fail(f'{theme["id"]}: {len(seen)} zones, over maxDecalsPerCar {spec["maxDecalsPerCar"]}')
        # The optional motifs are what drop_optional may leave out: what remains always fits.
        required = sum(len(m['zones']) for m in theme['motifs'] if not m.get('optional'))
        if required > set_budget(spec):
            fail(f'{theme["id"]}: {required} zones of required motifs, over maxDecalsPerSet {set_budget(spec)}')


def drop_optional(placed, motifs, budget, skipped):
    """Over the set budget, the optional motifs go, the last one in spec order first, each whole
    (both sides): the set stays at or under maxDecalsPerSet with what the model can carry."""
    def of(p):
        return p.motif.of or p.motif                  # a fallback's decal belongs to its primary
    for mo in reversed(motifs):
        if len(placed) <= budget:
            break
        if not mo.optional or not any(of(p) is mo for p in placed):
            continue
        for p in placed:
            if of(p) is mo:
                record_skip(skipped, p.zone.name, f'optional {mo.id} left out: the set is over maxDecalsPerSet {budget}')
        placed = [p for p in placed if of(p) is not mo]
    return placed


def place_theme(md, theme, cfg, failures, budget=MAX_DECALS_PER_TEMPLATE, lenient=False):
    """One set: the motifs in spec order (a scaleGroup when its first member comes), each decal
    taking its rectangle out of the view so the next ones never overlap it; over the set budget,
    the optional motifs left out (drop_optional); then the meshes and the assertions. `lenient`
    (an extended model): a decal that fails an assertion is left out with its pair partner instead
    of failing the build."""
    for g in md.grids.values():
        g.taken[:] = False
    motifs = with_fallbacks(theme, [Motif(theme, m, cfg['art']) for m in theme['motifs']], cfg['art'])
    zones = find_zones(md, {z for mo in motifs for z in mo.m['zones']})
    skipped, placed, groups = [], [], set()
    for mo in motifs:
        grp = mo.m.get('scaleGroup')
        if grp:
            if grp not in groups:
                groups.add(grp)
                placed += fit_group(md, [m for m in motifs if m.m.get('scaleGroup') == grp], zones, skipped)
        else:
            placed += fit_motif(md, mo, zones, skipped, placed)
    placed = drop_optional(placed, motifs, budget, skipped)
    if len(placed) > budget:
        failures.append(f'{md.key}/{theme["id"]}: {len(placed)} decals, over maxDecalsPerSet {budget} '
                        f'with every optional motif left out')
    lim = cfg['limits']
    decals = []
    for pl in placed:
        mesh = build_mesh(md, pl, cfg['spacing'], cfg['offset'])
        if mesh is None:
            record_skip(skipped, pl.zone.name, 'no decal quad lands on the host')
            continue
        metrics = check_decal(md, pl, mesh)
        bad = [k for k, ok in (('carried', metrics['carried'] >= lim['minCarried']),
                                ('visible', metrics['visible'] >= lim['minVisible']),
                                ('onHost', metrics['onHost'] >= lim['minOnHost']),
                                ('floating', metrics['floating'] <= lim['maxFloating']),
                                ('onWheels', metrics['onWheels'] == 0)) if not ok]
        if bad and not lenient:
            failures.append(f'{md.key}/{theme["id"]}/{pl.zone.name}: {", ".join(bad)} {metrics}')
        decals.append((pl, mesh, metrics, bad))
    if lenient:
        partner = {**PAIRS, **{b: a for a, b in PAIRS.items()}}
        out_zones = {}
        for pl, _, metrics, bad in decals:
            if bad:
                out_zones[pl.zone.name] = f'assertion failed ({", ".join(bad)}): left out'
        for zn in list(out_zones):
            if partner.get(zn) and partner[zn] not in out_zones:
                out_zones[partner[zn]] = f'pair partner {zn} failed an assertion: left out with it'
        for zn, why in out_zones.items():
            if any(d[0].zone.name == zn for d in decals):
                record_skip(skipped, zn, why)
        decals = [d for d in decals if d[0].zone.name not in out_zones]
    return [(pl, mesh, metrics) for pl, mesh, metrics, _ in decals], skipped


def trim_records(dealer_row, decals):
    """The records a set fits: the primary, then each trim whose appearance carries every host
    with the primary's mesh and binding (the dealer table's `trims`); and the refused trims."""
    hosts = sorted({d['host'] for d in decals})
    records, refused = [dealer_row['record']], []
    for t in dealer_row.get('trims') or []:
        if t['record'] == dealer_row['record']:
            continue
        if not t.get('found'):
            refused.append({'record': t['record'], 'reason': f'appearance {t.get("appearance")} not read'})
            continue
        missing = [h for h in hosts if h not in t['components']]
        differ = [h for h in hosts if h in t.get('differs', [])]
        if missing or differ:
            why = (f'appearance {t["appearance"]} lacks {", ".join(missing)}' if missing
                   else f'appearance {t["appearance"]} has another {", ".join(differ)}')
            refused.append({'record': t['record'], 'reason': why})
            continue
        records.append(t['record'])
    return records, refused


def cmd_place(cfg):
    spec = read_json(cfg['spec'])
    check_spec(spec)
    dealer = {m['key']: m for m in read_json(cfg.get('dealer') or DEALER)['models']}
    spec_dir = Path(cfg['spec']).parent
    kit_hidden = collections.defaultdict(set)
    for name in spec.get('kitFits', []):
        for part in read_json(spec_dir / name).get('parts', {}).values():
            for record, fit in (part.get('fit') or {}).items():
                kit_hidden[record].update(fit.get('hide') or [])
    cap = int(spec['maxDecalsPerCar'])
    if cap > MAX_DECALS_PER_TEMPLATE:
        fail(f'maxDecalsPerCar {cap} is above the engine cap {MAX_DECALS_PER_TEMPLATE}')
    out = Path(cfg['out'])
    only = [k for k in (cfg.get('only') or '').split(',') if k]
    result = {'schema': 'open77.vehicle-original-stickers.placements/1', 'step': cfg['step'], 'spacing': cfg['spacing'],
              'offset': cfg['offset'], 'limits': cfg['limits'], 'maxDecalsPerCar': cap, 'maxDecalsPerSet': set_budget(spec),
              'minDecalsPerSet': int(spec.get('minDecalsPerSet', 1)), 'sets': [], 'decalsPerModel': {}, 'skipped': [],
              'droppedSets': [], 'trimsRefused': [], 'modelsWithoutSets': {}}
    extended = set(spec.get('extendedModels') or [])
    failures = []
    shown = [k for k in spec.get('overviewModels', []) if not only or k in only]
    tiles = collections.defaultdict(list)             # theme -> [(title, views)] for st_board.overview
    for key in all_models(spec):
        if only and key not in only:
            continue
        lenient = key in extended
        md = Model(cfg, dealer[key], kit_hidden)
        produced = 0
        for theme in spec['themes']:
            decals, skipped = place_theme(md, theme, cfg, failures, set_budget(spec), lenient)
            n = len(decals)
            if n > cap:
                fail(f'{key}/{theme["id"]}: {n} decals, over the engine cap of {cap} per car (13 crash every client at spawn)')
            if n < result['minDecalsPerSet']:
                if not lenient:
                    failures.append(f'{key}/{theme["id"]}: {n} decals, under minDecalsPerSet {result["minDecalsPerSet"]}')
                else:
                    reason = f'{n} decal(s) qualify, under minDecalsPerSet {result["minDecalsPerSet"]}'
                    result['droppedSets'].append({'model': key, 'theme': theme['id'], 'decals': n,
                                                  'reason': reason, 'skipped': skipped})
                    print(f'{key:9} set {theme["id"]:8} dropped: {reason}  | skipped ' +
                          ', '.join(f'{x["zone"]} ({x["reason"]})' for x in skipped))
                    continue
            produced += 1
            rows = []
            for pl, mesh, metrics in decals:
                rel = f'{key}/{theme["id"]}_{pl.zone.name}.glb'
                write_glb(out / rel, mesh['pos'], mesh['nor'], mesh['tan'], mesh['uv'], mesh['idx'])
                rows.append({'zone': pl.zone.name, 'motif': pl.motif.id, 'stem': pl.motif.stem,
                             **({'fallbackFor': pl.motif.of.id} if pl.motif.of else {}),
                             'host': md.s.names[pl.host], 'view': pl.zone.view, 'scale': pl.scale,
                             'centre': [round(float(c), 4) for c in mesh['world'].reshape(-1, 3).mean(0)],
                             'sizeCm': [round(e * 100, 1) for e in pl.ext], 'mirrored': pl.mirrored,
                             'uv': [list(pl.uv[0]), list(pl.uv[1])], 'glb': rel, 'vertices': len(mesh['pos']),
                             'triangles': len(mesh['idx']) // 3, 'cell': mesh['cell'], 'metrics': metrics})
            records, refused = trim_records(dealer[key], rows)
            result['sets'].append({'model': key, 'record': dealer[key]['record'], 'label': dealer[key]['label'],
                                   'theme': theme['id'], 'decalCount': n, 'decals': rows, 'skipped': skipped,
                                   **({'records': records} if len(records) > 1 else {})})
            result['trimsRefused'] += [{'model': key, 'theme': theme['id'], **r} for r in refused]
            result['decalsPerModel'].setdefault(key, {})[theme['id']] = n
            result['skipped'] += [{'model': key, 'theme': theme['id'], **s} for s in skipped]
            print(f'{key:9} set {theme["id"]:8} {n:2} decals  ' +
                  '  '.join(f'{r["zone"]}@{r["host"]} x{r["scale"]:.2f}' for r in rows) +
                  (f'  | skipped {", ".join(s["zone"] for s in skipped)}' if skipped else ''))
            if cfg.get('boards'):
                views = st_board.board(md, theme, decals, skipped, Path(cfg['boards']) / f'{key}_{theme["id"]}.png', spec)
                if key in shown:
                    tiles[theme['id']].append((f'{key} ({dealer[key]["label"]}): {n} decals', views))
        if not produced:
            result['modelsWithoutSets'][key] = 'no theme qualifies: ' + '; '.join(
                f'{d["theme"]} {d["reason"]}' for d in result['droppedSets'] if d['model'] == key)
    if cfg.get('overviews'):
        for theme in spec['themes']:
            if tiles[theme['id']]:
                order = {k: i for i, k in enumerate(shown)}
                st_board.overview(theme, sorted(tiles[theme['id']], key=lambda t: order[t[0].split(' ')[0]]),
                                  Path(cfg['overviews']) / f'{theme["id"]}.png')
    result['totals'] = {'sets': len(result['sets']), 'decals': sum(s['decalCount'] for s in result['sets'])}
    write_json(out / 'placements.json', result)
    if failures:
        fail('placement assertions failed:\n  ' + '\n  '.join(failures))
    print(f'ST_PLACE_OK sets={result["totals"]["sets"]} decals={result["totals"]["decals"]}')


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('command', choices=['inputs', 'extract', 'place'])
    ap.add_argument('--cfg', required=True, type=Path)
    a = ap.parse_args()
    cfg = read_json(a.cfg)
    {'inputs': cmd_inputs, 'extract': cmd_extract, 'place': cmd_place}[a.command](cfg)


if __name__ == '__main__':
    main()
