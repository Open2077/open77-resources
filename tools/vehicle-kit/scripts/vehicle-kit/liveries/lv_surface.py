"""The exterior a player sees, as the game draws it: shared by lv_decals.py and lv_composite.py.

The body-kit cache (../blender/body_measure.py --extract, outside the repository) holds each
model's MeshOnly glb exports and raw .mesh files. body_measure.assemble() reads every LOD_1
submesh of every exterior component, which is right for fit measurements and wrong for paint:

  - a component's chunkMask (in the player appearance of the .app) hides some chunks; the
    Hella's body_01, rear doors and trunk lid have hidden chunks;
  - a chunk's material decides what it is: the multilayered paint (MultilayerMask set), glass,
    lights, or a vanilla decal/sticker shell (drawn blended over the paint, never opaque).

This module rebuilds the surface with that information: per triangle its world position, its
UV0 (the multilayer mask's UV channel: UV1 is all zero on the Hella's body, and UV0 without a
V flip is the orientation under which the mask stays constant inside triangles, measured
2026-11-06), its component, and the kind and vanilla mask of its chunk.

Mesh materials come from the WolvenKit JSON of the .mesh files (serialized by the build into
work/game/meshjson, never shipped); the player appearance's meshAppearance and chunkMask come
from the .app JSON in the body-kit cache. A chunk's local material instance often overrides
nothing (hozuki, merrimac, maimai: `values: []` over multilayer_vehicle_destruction.mi or over
a material_instances/ext_*.mi): its kind comes from the chain of .mi files above it, read from
the serialized game files (work/game/json), never guessed from the local instance alone.
"""
from __future__ import annotations

import json
import math
import re
import struct
from pathlib import Path

import numpy as np

from lv_common import BS, component_frames, cv

import body_measure  # noqa: E402  (read-only reuse; lv_common puts ../blender on sys.path)

KIND_PAINT, KIND_ML_OTHER, KIND_GLASS, KIND_LIGHT, KIND_OTHER = 0, 1, 2, 3, 4
KIND_NAMES = ['paint', 'ml_other', 'glass', 'light', 'other']
ALL_CHUNKS = (1 << 64) - 1


# --------------------------------------------------------------------------- glb
def read_glb_lod1(path):
    """LOD_1 submeshes of a WolvenKit MeshOnly glb, in file order, engine axes.

    Returns [{'pos': (N,3), 'uv': (N,2), 'idx': (M,3)}]. glTF (x, y, z) -> engine (x, -z, y).
    """
    data = Path(path).read_bytes()
    n = struct.unpack_from('<I', data, 12)[0]
    doc = json.loads(data[20:20 + n])
    off = 20 + n
    blen = struct.unpack_from('<I', data, off)[0]
    blob = data[off + 8:off + 8 + blen]

    def accessor(i, comps):
        a = doc['accessors'][i]
        v = doc['bufferViews'][a['bufferView']]
        ct = {5126: 'f4', 5123: 'u2', 5121: 'u1', 5125: 'u4'}[a['componentType']]
        item = np.dtype('<' + ct).itemsize
        stride = v.get('byteStride', item * comps)
        start = v.get('byteOffset', 0) + a.get('byteOffset', 0)
        raw = np.ndarray((a['count'], comps), dtype='<' + ct, buffer=blob, offset=start, strides=(stride, item))
        out = raw.astype(np.float64)
        if a.get('normalized'):
            out /= {5123: 65535.0, 5121: 255.0}[a['componentType']]
        return out

    subs = []
    for mesh in doc['meshes']:
        # 'submesh_02_LOD_1_doubled': WolvenKit names a double-sided chunk that way (galena window_f)
        if not re.search(r'_LOD_1(_doubled)?$', mesh['name']):
            continue
        prim = mesh['primitives'][0]
        g = accessor(prim['attributes']['POSITION'], 3)
        pos = np.stack([g[:, 0], -g[:, 2], g[:, 1]], 1)
        uv = accessor(prim['attributes']['TEXCOORD_0'], 2) if 'TEXCOORD_0' in prim['attributes'] else np.zeros((len(pos), 2))
        ia = doc['accessors'][prim['indices']]
        iv = doc['bufferViews'][ia['bufferView']]
        fmt = {5121: '<u1', 5123: '<u2', 5125: '<u4'}[ia['componentType']]
        idx = np.frombuffer(blob, dtype=fmt, count=ia['count'], offset=iv.get('byteOffset', 0) + ia.get('byteOffset', 0))
        subs.append({'name': mesh['name'], 'pos': pos, 'uv': uv, 'idx': idx.astype(np.int64).reshape(-1, 3)})
    return subs


# --------------------------------------------------------------------------- materials
def _values(m):
    out = {}
    for v in m.get('values') or []:
        keys = [k for k in v if k != '$type']
        if keys:
            out[keys[0]] = v[keys[0]]
    return out


def _material_pool(root):
    loc = (root.get('localMaterialBuffer') or {}).get('materials') or []
    if loc:
        return loc
    return [(x.get('Data') if isinstance(x, dict) and 'Data' in x else x) for x in root.get('preloadLocalMaterialInstances') or []]


class Materials:
    """Material instance chains: a .mi inherits every parameter it does not set from its base."""

    def __init__(self, roots):
        self.roots = [Path(r) for r in roots]
        self.cache = {}

    def load(self, depot):
        if depot not in self.cache:
            for r in self.roots:
                p = r / (depot.replace(BS, '~') + '.json')
                if p.exists():
                    self.cache[depot] = json.loads(p.read_text(encoding='utf-8'))['Data']['RootChunk']
                    break
            else:
                raise SystemExit(f'lv_surface: material {depot} is not extracted (lv_composite.py inputs lists it)')
        return self.cache[depot]

    def chain(self, base):
        """(parameters inherited from the .mi chain above a chunk, the final .mt/.remt path)."""
        values, seen = {}, set()
        while base and base.lower().endswith('.mi') and base not in seen:
            seen.add(base)
            doc = self.load(base)
            for k, v in _values(doc).items():
                values.setdefault(k, v)
            base = cv(doc.get('baseMaterial')) or ''
        return values, base


INTERIOR = re.compile(r'(^|[_\\])int(\d|_|$)|interior')


def classify(name, base, values, materials=None):
    """Kind of a chunk material: its local instance, then the .mi chain above it."""
    merged = dict(values)
    final = base or ''
    if materials is not None and base:
        inherited, final = materials.chain(base)
        for k, v in inherited.items():
            merged.setdefault(k, v)
    mask = cv(merged.get('MultilayerMask')) if merged.get('MultilayerMask') is not None else None
    multilayer = bool(mask) or 'MultilayerSetup' in merged or 'multilayer' in final.lower()
    if multilayer:
        stem_ = (name + ' ' + (mask or '').split(BS)[-1]).lower()
        return (KIND_ML_OTHER if INTERIOR.search(stem_) else KIND_PAINT), (mask or None)
    low = (name + ' ' + (base or '')).lower()
    if 'decal' in low or 'sticker' in low or 'branding' in low:
        return None, None          # blended shells over the paint: not a surface of their own
    if 'glass' in low or 'window' in low:
        return KIND_GLASS, None
    if 'light' in low or 'emissive' in low or 'diode' in low or 'lamp' in low:
        return KIND_LIGHT, None
    return KIND_OTHER, None


def chunk_table(mesh_json, mesh_appearance, materials=None):
    """Per LOD_1 chunk (render order): (material name, kind or None, vanilla mask path)."""
    root = json.loads(Path(mesh_json).read_text(encoding='utf-8'))['Data']['RootChunk']
    apps = {cv(a['Data']['name']): a['Data'] for a in root.get('appearances') or []}
    app = apps.get(mesh_appearance) or apps.get('default') or next(iter(apps.values()))
    names = [cv(x) for x in app['chunkMaterials']]
    infos = root['renderResourceBlob']['Data']['header']['renderChunkInfos']
    entries = {cv(e['name']): e for e in root.get('materialEntries') or []}
    pool = _material_pool(root)
    externals = [cv(x) for x in (root.get('externalMaterials') or [])]
    rows = []
    for i, info in enumerate(infos):
        if not (info.get('lodMask', 1) & 1):
            continue
        name = names[i] if i < len(names) else ''
        e = entries.get(name)
        base, values = '', {}
        if e is not None and e.get('isLocalInstance') and e['index'] < len(pool):
            m = pool[e['index']]
            base, values = cv(m.get('baseMaterial')) or '', _values(m)
        elif e is not None and e['index'] < len(externals):
            base = externals[e['index']] or ''
        kind, mask = classify(name, base, values, materials)
        rows.append({'chunk': i, 'material': name, 'base': base, 'kind': kind, 'mask': mask})
    return rows


def app_components(app_json, appearance_name):
    """component name -> (meshAppearance, chunkMask) in one appearance of an .app JSON."""
    root = json.loads(Path(app_json).read_text(encoding='utf-8'))['Data']['RootChunk']
    for a in root.get('appearances') or []:
        if cv(a['Data']['name']) == appearance_name:
            out = {}
            for c in a['Data'].get('components') or []:
                if c.get('name') is None:
                    continue
                cm = c.get('chunkMask')
                out[cv(c['name'])] = (cv(c.get('meshAppearance')) or 'default', int(cm) if cm is not None else ALL_CHUNKS)
            return out
    raise SystemExit(f'lv_surface: appearance {appearance_name} not in {app_json}')


def mesh_json_path(meshjson_dir, mesh_depot):
    return Path(meshjson_dir) / (mesh_depot.replace(BS, '~') + '.json')


# --------------------------------------------------------------------------- assembly
class Surface:
    """Visible exterior triangles of one model's player appearance, world frame."""

    def __init__(self):
        self.tris = None        # (T, 3, 3)
        self.uvs = None         # (T, 3, 2)
        self.comp = None        # (T,) index into names
        self.kind = None        # (T,) KIND_*
        self.mask = None        # (T,) index into masks (-1: none)
        self.names, self.masks, self.frames = [], [], {}
        self.hidden = {}        # component -> hidden LOD_1 chunks (indices), for the report
        self.chunks = {}        # component -> chunk table


def mesh_materials(mesh_json):
    """Every material path a mesh can draw with (local instance bases and external materials)."""
    root = json.loads(Path(mesh_json).read_text(encoding='utf-8'))['Data']['RootChunk']
    out = {cv(m.get('baseMaterial')) for m in _material_pool(root)}
    out |= {cv(x) for x in (root.get('externalMaterials') or [])}
    return {p for p in out if p}


def model_surface(model, model_plan, work, meshjson_dir, material_roots):
    """model: dealer row; model_plan: plan.json row (playerAppearance); work: body-kit cache;
    material_roots: folders of serialized game files holding the .mi chains."""
    work = Path(work)
    app = next(a for a in model['appearances'] if a['name'] == model_plan['playerAppearance'])
    app_json = work / 'json' / (Path(app['app'].replace(BS, '/')).name + '.json')
    comps_app = app_components(app_json, app['appearanceName'])
    rows = body_measure.selected_components(model)
    rows = [c for c in rows if c['type'] != 'entAppearanceProxyMeshComponent']
    frames = component_frames(model, work, [c['name'] for c in rows])
    materials = Materials(material_roots)
    s = Surface()
    s.frames = frames
    tris, uvs, comp, kind, mask = [], [], [], [], []
    for c in rows:
        glb = work / 'glb' / (c['mesh'].replace(BS, '/')[:-5] + '.glb')
        mj = mesh_json_path(meshjson_dir, c['mesh'])
        if not glb.exists() or not mj.exists() or c['name'] not in frames:
            continue
        mesh_app, chunk_mask = comps_app.get(c['name'], ('default', ALL_CHUNKS))
        table = chunk_table(mj, mesh_app, materials)
        subs = read_glb_lod1(glb)
        if len(subs) != len(table):
            raise SystemExit(f'lv_surface: {model["key"]}/{c["name"]}: glb has {len(subs)} LOD_1 submeshes, '
                             f'the mesh {len(table)} LOD_1 chunks')
        s.chunks[c['name']] = table
        ci = len(s.names)
        s.names.append(c['name'])
        q, t = frames[c['name']]
        rot = _quat_matrix(q)
        for sub, row in zip(subs, table):
            if not (chunk_mask >> row['chunk']) & 1:
                s.hidden.setdefault(c['name'], []).append(row['chunk'])
                continue
            if row['kind'] is None:
                continue
            p = sub['pos'] @ rot.T + np.array(t)
            tri = p[sub['idx']]
            tris.append(tri)
            uvs.append(sub['uv'][sub['idx']])
            comp.append(np.full(len(tri), ci))
            kind.append(np.full(len(tri), row['kind']))
            if row['mask']:
                if row['mask'] not in s.masks:
                    s.masks.append(row['mask'])
                mask.append(np.full(len(tri), s.masks.index(row['mask'])))
            else:
                mask.append(np.full(len(tri), -1))
    if not tris:
        raise SystemExit(f'lv_surface: {model["key"]}: no visible exterior geometry (body-kit cache or mesh JSON missing)')
    s.tris = np.concatenate(tris)
    s.uvs = np.concatenate(uvs)
    s.comp = np.concatenate(comp)
    s.kind = np.concatenate(kind)
    s.mask = np.concatenate(mask)
    return s


def _quat_matrix(q):
    x, y, z, w = q
    return np.array([
        [1 - 2 * (y * y + z * z), 2 * (x * y - z * w), 2 * (x * z + y * w)],
        [2 * (x * y + z * w), 1 - 2 * (x * x + z * z), 2 * (y * z - x * w)],
        [2 * (x * z - y * w), 2 * (y * z + x * w), 1 - 2 * (x * x + y * y)],
    ])


# --------------------------------------------------------------------------- raster
#        plane a, plane b, depth axis, depth sign (depth = sign * coordinate; nearer = smaller),
#        camera direction (towards the viewer)
VIEWS = {
    'left': ('y', 'z', 0, 1.0, (-1.0, 0.0, 0.0)),
    'right': ('y', 'z', 0, -1.0, (1.0, 0.0, 0.0)),
    'top': ('y', 'x', 2, -1.0, (0.0, 0.0, 1.0)),
    'front': ('x', 'z', 1, -1.0, (0.0, 1.0, 0.0)),
    'rear': ('x', 'z', 1, 1.0, (0.0, -1.0, 0.0)),
}
AXIS = {'x': 0, 'y': 1, 'z': 2}


def raster(tris, view, spacing, lo, hi, want_bary=False):
    """Orthographic z-buffer: per grid cell, the nearest triangle (or -1), its depth and,
    on request, its barycentric coordinates (w0, w1, w2) at the cell centre."""
    a_ax, b_ax, d_axis, d_sign, _cam = VIEWS[view]
    A, B = AXIS[a_ax], AXIS[b_ax]
    na = int(math.floor((hi[A] - lo[A]) / spacing)) + 1
    nb = int(math.floor((hi[B] - lo[B]) / spacing)) + 1
    zbuf = np.full(na * nb, np.inf)
    owner = np.full(na * nb, -1, np.int64)
    bary = np.zeros((na * nb, 3)) if want_bary else None
    if not len(tris):
        return owner.reshape(na, nb), zbuf.reshape(na, nb), (A, B, na, nb), bary
    pa = (tris[:, :, A] - lo[A]) / spacing
    pb = (tris[:, :, B] - lo[B]) / spacing
    dep = d_sign * tris[:, :, d_axis]
    ia0 = np.ceil(pa.min(1)).astype(np.int64).clip(0, na - 1)
    ia1 = np.floor(pa.max(1)).astype(np.int64).clip(-1, na - 1)
    ib0 = np.ceil(pb.min(1)).astype(np.int64).clip(0, nb - 1)
    ib1 = np.floor(pb.max(1)).astype(np.int64).clip(-1, nb - 1)
    cnt_a = (ia1 - ia0 + 1).clip(0)
    cnt_b = (ib1 - ib0 + 1).clip(0)
    counts = cnt_a * cnt_b
    x0, y0 = pa[:, 0], pb[:, 0]
    d1a, d1b = pa[:, 1] - x0, pb[:, 1] - y0
    d2a, d2b = pa[:, 2] - x0, pb[:, 2] - y0
    den = d1a * d2b - d2a * d1b
    ok = (counts > 0) & (np.abs(den) > 1e-12)
    idx = np.nonzero(ok)[0]
    budget, start = 3_000_000, 0
    while start < len(idx):
        csum = np.cumsum(counts[idx[start:]])
        stop = start + max(1, int(np.searchsorted(csum, budget)))
        sel = idx[start:stop]
        start = stop
        c = counts[sel]
        tri = np.repeat(sel, c)
        first = np.repeat(np.cumsum(c) - c, c)
        local = np.arange(len(tri)) - first
        nbb = cnt_b[tri]
        ia = ia0[tri] + local // nbb
        ib = ib0[tri] + local % nbb
        px, py = ia - x0[tri], ib - y0[tri]
        u = (px * d2b[tri] - d2a[tri] * py) / den[tri]
        v = (d1a[tri] * py - px * d1b[tri]) / den[tri]
        w = 1 - u - v
        inside = (u >= -1e-6) & (v >= -1e-6) & (w >= -1e-6)
        tri, ia, ib, u, v, w = tri[inside], ia[inside], ib[inside], u[inside], v[inside], w[inside]
        d = w * dep[tri, 0] + u * dep[tri, 1] + v * dep[tri, 2]
        key = ia * nb + ib
        order = np.lexsort((d, key))
        key, d, tri, u, v, w = key[order], d[order], tri[order], u[order], v[order], w[order]
        firsts = np.ones(len(key), bool)
        firsts[1:] = key[1:] != key[:-1]
        key, d, tri, u, v, w = key[firsts], d[firsts], tri[firsts], u[firsts], v[firsts], w[firsts]
        better = d < zbuf[key]
        zbuf[key[better]] = d[better]
        owner[key[better]] = tri[better]
        if want_bary:
            bary[key[better]] = np.stack([w[better], u[better], v[better]], 1)
    return owner.reshape(na, nb), zbuf.reshape(na, nb), (A, B, na, nb), (bary.reshape(na, nb, 3) if want_bary else None)


def hit_points(view, zbuf, geo, lo, spacing):
    A, B, na, nb = geo
    _a, _b, d_axis, d_sign, _cam = VIEWS[view]
    ia, ib = np.meshgrid(np.arange(na), np.arange(nb), indexing='ij')
    p = np.zeros((na, nb, 3))
    p[..., A] = lo[A] + ia * spacing
    p[..., B] = lo[B] + ib * spacing
    p[..., d_axis] = d_sign * zbuf
    return p


def face_normals(tris):
    n = np.cross(tris[:, 1] - tris[:, 0], tris[:, 2] - tris[:, 0])
    return n / np.linalg.norm(n, axis=1, keepdims=True).clip(1e-12)


def to_image(arr, view):
    """(na, nb, ...) grid -> image rows/cols as a viewer sees the view (up = +z or +x)."""
    img = np.swapaxes(arr, 0, 1)[::-1]
    if view in ('left', 'top', 'front'):
        img = img[:, ::-1]
    return img
