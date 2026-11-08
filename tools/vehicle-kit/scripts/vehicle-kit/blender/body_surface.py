"""Exact 1 cm body surfaces for the body-kit fit and review board (plain Python 3; Blender imports it too).

    python scripts/vehicle-kit/blender/body_surface.py            # build or refresh the cache, print a summary

The 4 cm height maps of body_measure.py take the highest sample per cell, which is good
enough to say where a part goes but not whether it touches: on a sloped deck a 4 cm cell
hides 1 to 3 cm of height. This module rasterizes the same exterior panels (body_measure's
component set, factory accessories and out-of-proxy panels left out) into 1 cm maps:

  top / bottom   highest / lowest z over (x, y)        a part resting on or hanging under the body
  right / left   largest / smallest x over (y, z)      a part against a side (skirts, canards)
  front / rear   largest / smallest y over (x, z)      a part against a face (tow strap, diffuser)

Every value is a triangle plane evaluated at the cell centre, plus every vertex splatted
into its cell, so thin panels seen edge-on still mark the cells they cross.

Cache: <work>/surface/<key>.bin + <key>.json beside the measurements, OUTSIDE the
repository (refused inside it, like body_measure.py). It is keyed by SURFACE_VERSION and
the measure.json bytes, so a re-measure rebuilds it. Nothing here is ever committed: the
maps are numbers derived from the game meshes, and the triangles exist only in memory.

Frame: Root (the vehicle entity frame), metres, X right, Y forward, Z up.
"""
import array
import hashlib
import json
import math
import sys
import tempfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import body_measure as bm  # noqa: E402

SURFACE_VERSION = 'body-surface/1'
RES = 0.01
MARGIN = 0.06
NONE = float('nan')
WORK = Path(tempfile.gettempdir()) / 'open77-vehicle-kit-measure' / 'bodykit'


def _check_outside_repo(path):
    try:
        Path(path).resolve().relative_to(bm.REPO)
    except ValueError:
        return
    raise SystemExit(f'body_surface: {path} is inside the repository; game-derived data must stay outside it')


class Grid:
    """One projection: a (u, v) grid at RES with the largest and smallest depth per cell."""

    def __init__(self, u0, v0, nu, nv, hi=None, lo=None):
        self.u0, self.v0, self.nu, self.nv = u0, v0, nu, nv
        n = nu * nv
        self.hi = hi if hi is not None else [-1e9] * n
        self.lo = lo if lo is not None else [1e9] * n

    def index(self, u, v):
        i = int(math.floor((u - self.u0) / RES))
        j = int(math.floor((v - self.v0) / RES))
        if 0 <= i < self.nu and 0 <= j < self.nv:
            return i * self.nv + j
        return None

    def splat(self, u, v, w):
        k = self.index(u, v)
        if k is not None:
            if w > self.hi[k]:
                self.hi[k] = w
            if w < self.lo[k]:
                self.lo[k] = w

    def raster(self, tris, ui, vi, wi):
        u0, v0, nu, nv, hi, lo = self.u0, self.v0, self.nu, self.nv, self.hi, self.lo
        for t in tris:
            a, b, c = t
            ua, va, wa = a[ui], a[vi], a[wi]
            ub, vb, wb = b[ui], b[vi], b[wi]
            uc, vc, wc = c[ui], c[vi], c[wi]
            for (uu, vv, ww) in ((ua, va, wa), (ub, vb, wb), (uc, vc, wc)):
                self.splat(uu, vv, ww)
            det = (vb - vc) * (ua - uc) + (uc - ub) * (va - vc)
            if abs(det) < 1e-12:
                continue
            i0 = max(0, int(math.ceil((min(ua, ub, uc) - u0) / RES - 0.5)))
            i1 = min(nu - 1, int(math.floor((max(ua, ub, uc) - u0) / RES - 0.5)))
            j0 = max(0, int(math.ceil((min(va, vb, vc) - v0) / RES - 0.5)))
            j1 = min(nv - 1, int(math.floor((max(va, vb, vc) - v0) / RES - 0.5)))
            if i0 > i1 or j0 > j1:
                continue
            inv = 1.0 / det
            e = -1e-9
            for i in range(i0, i1 + 1):
                cu = u0 + (i + 0.5) * RES
                du = cu - uc
                base = i * nv
                for j in range(j0, j1 + 1):
                    cv = v0 + (j + 0.5) * RES
                    dv = cv - vc
                    l1 = ((vb - vc) * du + (uc - ub) * dv) * inv
                    if l1 < e:
                        continue
                    l2 = ((vc - va) * du + (ua - uc) * dv) * inv
                    if l2 < e or l1 + l2 > 1 - e:
                        continue
                    w = l1 * wa + l2 * wb + (1 - l1 - l2) * wc
                    k = base + j
                    if w > hi[k]:
                        hi[k] = w
                    if w < lo[k]:
                        lo[k] = w

    def finish(self):
        self.hi = array.array('f', [NONE if x <= -1e8 else x for x in self.hi])
        self.lo = array.array('f', [NONE if x >= 1e8 else x for x in self.lo])

    def get(self, table, u, v):
        k = self.index(u, v)
        if k is None:
            return None
        x = table[k]
        return None if x != x else x

    def values(self, table, u0, u1, v0, v1):
        """Every defined value with its cell centre over [u0, u1] x [v0, v1]."""
        i0 = max(0, int(math.floor((min(u0, u1) - self.u0) / RES)))
        i1 = min(self.nu - 1, int(math.floor((max(u0, u1) - self.u0) / RES)))
        j0 = max(0, int(math.floor((min(v0, v1) - self.v0) / RES)))
        j1 = min(self.nv - 1, int(math.floor((max(v0, v1) - self.v0) / RES)))
        out = []
        for i in range(i0, i1 + 1):
            base = i * self.nv
            cu = self.u0 + (i + 0.5) * RES
            for j in range(j0, j1 + 1):
                x = table[base + j]
                if x == x:
                    out.append((cu, self.v0 + (j + 0.5) * RES, x))
        return out


class Surface:
    """The 1 cm maps of one car. Queries return None outside the body."""

    def __init__(self, key, xy, yz, xz, meta):
        self.key, self.xy, self.yz, self.xz, self.meta = key, xy, yz, xz, meta
        self.bounds = meta['bounds']

    # --- vertical
    def top(self, x, y):
        return self.xy.get(self.xy.hi, x, y)

    def bottom(self, x, y):
        return self.xy.get(self.xy.lo, x, y)

    def top_values(self, x0, x1, y0, y1):
        return [z for _, _, z in self.xy.values(self.xy.hi, x0, x1, y0, y1)]

    def top_cells(self, x0, x1, y0, y1):
        return self.xy.values(self.xy.hi, x0, x1, y0, y1)

    def bottom_cells(self, x0, x1, y0, y1):
        return self.xy.values(self.xy.lo, x0, x1, y0, y1)

    def top_near(self, x, y, r=0.015):
        v = self.top_values(x - r, x + r, y - r, y + r)
        return max(v) if v else None

    # --- lateral
    def right(self, y, z):
        return self.yz.get(self.yz.hi, y, z)

    def left(self, y, z):
        return self.yz.get(self.yz.lo, y, z)

    def outer(self, y, z, side=1):
        v = self.right(y, z) if side > 0 else self.left(y, z)
        return None if v is None else v * side

    def side_cells(self, y0, y1, z0, z1, side=1):
        t = self.yz.hi if side > 0 else self.yz.lo
        return [(y, z, w * side) for y, z, w in self.yz.values(t, y0, y1, z0, z1)]

    # --- longitudinal
    def front(self, x, z):
        return self.xz.get(self.xz.hi, x, z)

    def rear(self, x, z):
        return self.xz.get(self.xz.lo, x, z)

    def front_cells(self, x0, x1, z0, z1):
        return self.xz.values(self.xz.hi, x0, x1, z0, z1)

    def rear_cells(self, x0, x1, z0, z1):
        return self.xz.values(self.xz.lo, x0, x1, z0, z1)

    def inside(self, x, y, z, tol=0.004):
        """True when (x, y, z) lies strictly inside the body's vertical column at (x, y)."""
        t, b = self.top(x, y), self.bottom(x, y)
        return t is not None and b is not None and b + tol < z < t - tol

    def depth_below_top(self, x, y, z):
        """How far (x, y, z) lies under the top surface (> 0 = under it), None off the body."""
        t = self.top(x, y)
        return None if t is None else t - z

    def half_width(self, y0, y1, z0=-9.0, z1=9.0):
        vals = [w for _, _, w in self.side_cells(y0, y1, z0, z1, 1)] + [w for _, _, w in self.side_cells(y0, y1, z0, z1, -1)]
        return max(vals) if vals else None


def _bounds(tris):
    lo = [min(p[i] for t in tris for p in t) for i in range(3)]
    hi = [max(p[i] for t in tris for p in t) for i in range(3)]
    return lo, hi


def build(model, work):
    """Rasterize one car (no cache)."""
    bones, body, _, _, _ = bm.body_parts(model, work)
    tris = [t for _, ts, _ in body for t in ts]
    lo, hi = _bounds(tris)
    lo = [v - MARGIN for v in lo]
    hi = [v + MARGIN for v in hi]
    n = [int(math.ceil((hi[i] - lo[i]) / RES)) for i in range(3)]
    xy = Grid(lo[0], lo[1], n[0], n[1])
    yz = Grid(lo[1], lo[2], n[1], n[2])
    xz = Grid(lo[0], lo[2], n[0], n[2])
    xy.raster(tris, 0, 1, 2)
    yz.raster(tris, 1, 2, 0)
    xz.raster(tris, 0, 2, 1)
    for g in (xy, yz, xz):
        g.finish()
    meta = {'version': SURFACE_VERSION, 'key': model['key'], 'res': RES, 'origin': lo, 'cells': n,
            'bounds': [[round(v + MARGIN, 4) for v in lo], [round(v - MARGIN, 4) for v in hi]], 'triangles': len(tris),
            'components': sorted(name for name, _, _ in body)}
    return Surface(model['key'], xy, yz, xz, meta)


def _cache_key(work):
    h = hashlib.sha256(SURFACE_VERSION.encode())
    h.update((Path(work) / 'measure.json').read_bytes())
    return h.hexdigest()[:16]


def save(surface, folder, stamp):
    folder.mkdir(parents=True, exist_ok=True)
    meta = dict(surface.meta, stamp=stamp)
    with (folder / f'{surface.key}.bin').open('wb') as f:
        for g in (surface.xy, surface.yz, surface.xz):
            g.hi.tofile(f)
            g.lo.tofile(f)
    (folder / f'{surface.key}.json').write_text(json.dumps(meta), encoding='utf-8')


def load_cached(key, folder, stamp):
    mpath, bpath = folder / f'{key}.json', folder / f'{key}.bin'
    if not mpath.exists() or not bpath.exists():
        return None
    meta = json.loads(mpath.read_text(encoding='utf-8'))
    if meta.get('stamp') != stamp or meta.get('version') != SURFACE_VERSION:
        return None
    lo, n = meta['origin'], meta['cells']
    sizes = [n[0] * n[1], n[1] * n[2], n[0] * n[2]]
    data = []
    with bpath.open('rb') as f:
        for s in sizes:
            hi_, lo_ = array.array('f'), array.array('f')
            hi_.fromfile(f, s)
            lo_.fromfile(f, s)
            data.append((hi_, lo_))
    xy = Grid(lo[0], lo[1], n[0], n[1], *data[0])
    yz = Grid(lo[1], lo[2], n[1], n[2], *data[1])
    xz = Grid(lo[0], lo[2], n[0], n[2], *data[2])
    return Surface(key, xy, yz, xz, meta)


def dealer_models(dealer_path=bm.DEALER):
    dealer = json.loads(Path(dealer_path).read_text(encoding='utf-8'))
    return {m['key']: m for m in dealer['models']}


def load(key, work=WORK, models=None, verbose=False):
    """The car's Surface, from the cache when it is current, else rasterized and cached."""
    work = Path(work)
    _check_outside_repo(work)
    folder = work / 'surface'
    stamp = _cache_key(work)
    s = load_cached(key, folder, stamp)
    if s is None:
        models = models or dealer_models()
        if verbose:
            print(f'body_surface: rasterizing {key} ...', flush=True)
        s = build(models[key], work)
        save(s, folder, stamp)
    return s


def components(key, work=WORK, models=None):
    """Per-component bounds of the kept exterior (Root frame): {name: {lo, hi, rearLo, rearHi,
    rearSides, crossesCentre}} where rear* bound the component's triangles within 30 cm of its
    rear end (exhaust tips), rearSides splits those by side of the centre line, and
    crossesCentre says whether one of them straddles it.
    Cached beside the surfaces with the same stamp; numbers only."""
    work = Path(work)
    _check_outside_repo(work)
    folder = work / 'surface'
    stamp = _cache_key(work)
    path = folder / f'{key}.components.json'
    if path.exists():
        data = json.loads(path.read_text(encoding='utf-8'))
        if data.get('stamp') == stamp and data.get('version') == 2:
            return data['components']
    out = {}
    for name, tris in car_triangles(key, work, models):
        lo, hi = _bounds(tris)
        y_end = lo[1] + 0.30
        rear = [t for t in tris if min(p[1] for p in t) <= y_end]
        rlo, rhi = _bounds(rear) if rear else (lo, hi)
        sides = {}
        for sign in (-1, 1):
            half = [t for t in rear if all(p[0] * sign > 0 for p in t)]
            if half:
                hlo, hhi = _bounds(half)
                sides[str(sign)] = [[round(v, 4) for v in hlo], [round(v, 4) for v in hhi]]
        out[name] = {'lo': [round(v, 4) for v in lo], 'hi': [round(v, 4) for v in hi],
                     'rearLo': [round(v, 4) for v in rlo], 'rearHi': [round(v, 4) for v in rhi], 'rearSides': sides,
                     'crossesCentre': any(min(p[0] for p in t) < -0.01 and max(p[0] for p in t) > 0.01 for t in rear),
                     'triangles': len(tris)}
    folder.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps({'stamp': stamp, 'version': 2, 'components': out}), encoding='utf-8')
    return out


def car_triangles(key, work=WORK, models=None, with_accessories=False):
    """The kept exterior triangles of one car in the Root frame (for the review board's
    body render; in memory only). Accessories (a factory rack, wing...) on request."""
    models = models or dealer_models()
    bones, body, acc, _, _ = bm.body_parts(models[key], Path(work))
    out = [(name, ts) for name, ts, _ in body]
    if with_accessories:
        out += sorted(acc.items())
    return out


def main():
    import argparse
    import time
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('--work', type=Path, default=WORK)
    ap.add_argument('--cars', default=','.join(bm.CARS), help="comma list, or 'all' for every car of measure.json")
    ap.add_argument('--dealer', type=Path, default=bm.DEALER, help='component inventory (player_body_components.py widens it)')
    args = ap.parse_args()
    models = dealer_models(args.dealer)
    if args.cars == 'all':
        args.cars = ','.join(json.loads((args.work / 'measure.json').read_text(encoding='utf-8'))['cars'])
    for key in args.cars.split(','):
        t = time.time()
        s = load(key, args.work, models, verbose=True)
        b = s.bounds
        print(f'{key:9} {s.meta["triangles"]:6} tris  bounds x {b[0][0]:.3f}..{b[1][0]:.3f} y {b[0][1]:.3f}..{b[1][1]:.3f} '
              f'z {b[0][2]:.3f}..{b[1][2]:.3f}  ({time.time() - t:.1f} s)')
    print(f'VK_BODY_SURFACE_OK cars={len(args.cars.split(","))} out={args.work / "surface"}')


if __name__ == '__main__':
    main()
