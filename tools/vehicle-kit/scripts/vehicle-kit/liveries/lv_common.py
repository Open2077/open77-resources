"""Shared helpers of the livery pipeline (scripts/vehicle-kit/liveries).

Plain Python 3.11+; the scripts that draw or project need Pillow and numpy and are run
through `uv run --no-project --with pillow --with numpy python -I`.

Frames: the engine vehicle frame (metres, X right, Y forward, Z up), as in
../blender/body_measure.py. glTF is written Y-up: (x, y, z)_engine -> (x, z, -y)_gltf.
"""
from __future__ import annotations

import json
import math
import struct
import sys
from pathlib import Path

KIT = Path(__file__).resolve().parents[1]
REPO = KIT.parents[1]
BS = chr(92)

# Most VehicleDecalAttachment entries one colour template may carry. Measured on 2.5
# (docs/research/vehicles-api.md, 2026-11-06): 12 decals on one car are fine, 13 crash every
# client that spawns the car, at Cyberpunk2077.exe+0x37DD77. lv_plan.py folds decals into
# their parent panel to stay under it; lv_cook.py refuses a template above it.
MAX_DECALS_PER_TEMPLATE = 12

# Reuse the body-kit measurement code (read-only import, never edited from here).
sys.path.insert(0, str(KIT / 'blender'))
sys.path.insert(0, str(KIT / 'inventory'))

# --------------------------------------------------------------------------- atlas
# One texture pair per design, shared by every model: the UV of a decal vertex comes from
# its position in the car's own bounds, so the same artwork stretches over each body.
ATLAS_W, ATLAS_H = 2048, 1024
GUTTER = 8
REGIONS = {                      # x0, y0, x1, y1 in pixels
    'left': (0, 0, 2048, 320),   # car seen from its left (-X): front at the left edge
    'right': (0, 320, 2048, 640),  # car seen from its right (+X): front at the right edge
    'top': (0, 640, 2048, 1024),  # car seen from above: front at the left, its right side up
}


def region_box(view):
    x0, y0, x1, y1 = REGIONS[view]
    return x0 + GUTTER, y0 + GUTTER, x1 - GUTTER, y1 - GUTTER


# --------------------------------------------------------------------------- JSON
def cname(v):
    return {'$type': 'CName', '$storage': 'string', '$value': v}


def resource(path, flags='Default'):
    return {'DepotPath': {'$type': 'ResourcePath', '$storage': 'string', '$value': path}, 'Flags': flags}


def cv(x):
    if isinstance(x, dict):
        if 'DepotPath' in x:
            return x['DepotPath'].get('$value')
        if '$value' in x:
            return x['$value']
    return x


def read_json(p):
    return json.loads(Path(p).read_text(encoding='utf-8'))


def write_json(p, value, indent=1):
    p = Path(p)
    p.parent.mkdir(parents=True, exist_ok=True)
    p.write_text(json.dumps(value, indent=indent, ensure_ascii=False) + '\n', encoding='utf-8', newline='\n')


def depot_file(depot, root):
    return Path(root, *depot.split(BS))


def flat_name(depot):
    """WolvenKit's folder serialize/deserialize flattens folders (same-named files overwrite
    each other), so every file goes through one flat folder under a unique, reversible name."""
    return depot.replace(BS, '~')


# --------------------------------------------------------------------------- colour
def hex_rgb(h):
    h = h.lstrip('#')
    return tuple(int(h[i:i + 2], 16) for i in (0, 2, 4))


def srgb_to_linear(c):
    c = c / 255.0
    return c / 12.92 if c <= 0.04045 else ((c + 0.055) / 1.055) ** 2.4


def linear_to_srgb(c):
    c = max(0.0, min(1.0, c))
    v = c * 12.92 if c <= 0.0031308 else 1.055 * c ** (1 / 2.4) - 0.055
    return int(round(v * 255))


# --------------------------------------------------------------------------- transforms
def qconj(q):
    x, y, z, w = q
    return (-x, -y, -z, w)


def inverse_apply(tf, p):
    """World point -> component frame, for tf = (quaternion xyzw, translation)."""
    from body_measure import qrot
    q, t = tf
    return qrot(qconj(q), (p[0] - t[0], p[1] - t[1], p[2] - t[2]))


def inverse_rotate(tf, v):
    from body_measure import qrot
    return qrot(qconj(tf[0]), v)


def component_frames(model, work, names=None):
    """Component name -> world transform of its mesh frame, for the player appearance.

    Same composition as body_measure.assemble (slot bone bind pose, slot offset, then the
    appearance's local transform), exposed per component because a decal is authored in
    the frame of the component it is attached to.
    """
    from body_measure import (IDENTITY, app_local_transforms, compose, rig_bones, rig_path_of,
                              slot_table)
    js = work / 'json'
    ent_json = js / (Path(model['entity']['path'].replace(BS, '/')).name + '.json')
    bones = rig_bones(js / (Path(rig_path_of(ent_json).replace(BS, '/')).name + '.json'))
    slots = slot_table(ent_json)
    app = next(a for a in model['appearances'] if a['name'] == model['playerAppearance'])
    locals_ = app_local_transforms(js / (Path(app['app'].replace(BS, '/')).name + '.json'), app['appearanceName'])
    comps = {c['name']: c for c in model['components'] if c.get('inPlayerAppearance')}
    cache = {}

    def world_of(name, depth=0):
        if name in cache:
            return cache[name]
        if depth > 12:
            raise SystemExit(f'liveries: binding loop at {name}')
        c = comps.get(name)
        parent = (c or {}).get('parent') or {}
        bind, slot = parent.get('bindName'), parent.get('slotName')
        if bind in slots and slot:
            if slot not in slots[bind]:
                raise SystemExit(f'liveries: {model["key"]}/{name} is bound to {bind}.{slot}, a slot the entity does not define')
            bone, rel = slots[bind][slot]
            base = compose(bones.get(bone, IDENTITY), rel)
        elif bind in ('deformation_rig', 'vehicle_rig', None, ''):
            base = IDENTITY
        elif bind in comps:
            base = world_of(bind, depth + 1)
        else:
            base = IDENTITY
        tf = compose(base, locals_.get(name, IDENTITY))
        cache[name] = tf
        return tf

    # Only the components asked for (and their parents): interior parts may name slots the
    # exterior entity does not carry, and they never get a decal.
    return {name: world_of(name) for name in (names if names is not None else comps) if name in comps}


# --------------------------------------------------------------------------- glb
def write_glb(path, positions, normals, tangents, uvs, indices, name='submesh_00_LOD_1'):
    """One primitive, engine-frame input. COLOR_0 and COLOR_1 are written white: the
    import layout has PS_Color streams and an absent colour is cooked as 00000000
    (../blender/vk_common.py, measured in E0.9)."""
    n = len(positions)
    gl = lambda p: (p[0], p[2], -p[1])
    pos = [gl(p) for p in positions]
    nor = [gl(v) for v in normals]
    tan = [gl(t[:3]) + (t[3],) for t in tangents]
    blobs, views, accessors = [], [], []

    def add(data, count, ctype, kind, target, minmax=None):
        while sum(len(b) for b in blobs) % 4:
            blobs.append(b'\0')
        offset = sum(len(b) for b in blobs)
        blobs.append(data)
        views.append({'buffer': 0, 'byteOffset': offset, 'byteLength': len(data), 'target': target})
        acc = {'bufferView': len(views) - 1, 'componentType': ctype, 'count': count, 'type': kind}
        if minmax:
            acc['min'], acc['max'] = minmax
        accessors.append(acc)
        return len(accessors) - 1

    flat = lambda rows: [x for r in rows for x in r]
    mins = [min(p[i] for p in pos) for i in range(3)]
    maxs = [max(p[i] for p in pos) for i in range(3)]
    a_pos = add(struct.pack(f'<{3 * n}f', *flat(pos)), n, 5126, 'VEC3', 34962, (mins, maxs))
    a_nor = add(struct.pack(f'<{3 * n}f', *flat(nor)), n, 5126, 'VEC3', 34962)
    a_tan = add(struct.pack(f'<{4 * n}f', *flat(tan)), n, 5126, 'VEC4', 34962)
    a_uv = add(struct.pack(f'<{2 * n}f', *flat(uvs)), n, 5126, 'VEC2', 34962)
    white = struct.pack(f'<{4 * n}f', *([1.0] * (4 * n)))
    a_c0 = add(white, n, 5126, 'VEC4', 34962)
    a_c1 = add(white, n, 5126, 'VEC4', 34962)
    a_idx = add(struct.pack(f'<{len(indices)}I', *indices), len(indices), 5125, 'SCALAR', 34963)
    blob = b''.join(blobs)
    while len(blob) % 4:
        blob += b'\0'
    doc = {
        'asset': {'version': '2.0', 'generator': 'open77 vehicle-kit liveries'},
        'scene': 0, 'scenes': [{'nodes': [0]}],
        'nodes': [{'mesh': 0, 'name': name}],
        'meshes': [{'name': name, 'primitives': [{
            'attributes': {'POSITION': a_pos, 'NORMAL': a_nor, 'TANGENT': a_tan, 'TEXCOORD_0': a_uv,
                           'COLOR_0': a_c0, 'COLOR_1': a_c1},
            'indices': a_idx, 'mode': 4}]}],
        'buffers': [{'byteLength': len(blob)}],
        'bufferViews': views, 'accessors': accessors,
    }
    js = json.dumps(doc, separators=(',', ':')).encode('utf-8')
    while len(js) % 4:
        js += b' '
    out = struct.pack('<III', 0x46546C67, 2, 12 + 8 + len(js) + 8 + len(blob))
    out += struct.pack('<II', len(js), 0x4E4F534A) + js + struct.pack('<II', len(blob), 0x004E4942) + blob
    Path(path).parent.mkdir(parents=True, exist_ok=True)
    Path(path).write_bytes(out)


def unit(v):
    n = math.sqrt(v[0] * v[0] + v[1] * v[1] + v[2] * v[2]) or 1.0
    return (v[0] / n, v[1] / n, v[2] / n)
