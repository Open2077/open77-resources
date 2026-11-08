"""Shared readers for the game's 3D map (base\\entities\\cameras\\3dmap).

World space = game metres, X east, Y north, Z up. The glTF exports are Y-up:
world (x, y, z) = glTF (x, -z, y). Components carry their own local transform
inside 3dmap_view.ent (roads, borders and metro are turned 180 degrees about Z).
District buildings are not meshes: 3d_map_cubes.mt draws one oriented box per
texel of a 16-bit point-cloud texture (WorldPosTex, 3 blocks of H x H):
  block 0 = position, normalized between TransMin and TransMax (+ component offset), A = valid
  block 1 = orientation quaternion (x, y, z, w) mapped from [-1, 1] to [0, 1]
  block 2 = box size, normalized by CubeSize
"""
import json, struct, pathlib
import numpy as np

ROOT = pathlib.Path(__file__).resolve().parent.parent
RAW = ROOT / 'raw' / 'base'
DDS = ROOT / 'raw-dds' / 'base' / 'fx' / 'textures' / '3dmap' / 'static'


def load_dds_rgba16(path):
    b = open(path, 'rb').read()
    h, w = struct.unpack('<II', b[12:20])
    assert b[84:88] == b'DX10' and struct.unpack('<I', b[128:132])[0] == 11, 'expected R16G16B16A16_UNORM'
    a = np.frombuffer(b[148:148 + w * h * 8], dtype='<u2').reshape(h, w, 4).astype(np.float64) / 65535.0
    return [a[:, i * h:(i + 1) * h, :].reshape(-1, 4) for i in range(3)], h


def gl_to_world(v):
    v = np.asarray(v, dtype=np.float64)
    return np.stack([v[:, 0], -v[:, 2], v[:, 1]], 1)


def _walk(o, out):
    if isinstance(o, dict):
        if o.get('$type') in ('entMeshComponent', 'entPhysicalMeshComponent'):
            out.append(o)
        for v in o.values():
            _walk(v, out)
    elif isinstance(o, list):
        for v in o:
            _walk(v, out)


def components():
    """Unique mesh components of 3dmap_view.ent: name -> {mesh, appearance, position, quaternion, scale}."""
    ent = json.load(open(ROOT / 'json' / '3dmap_view.ent.json', encoding='utf-8'))
    found = []
    _walk(ent, found)
    out = {}
    for c in found:
        name = c['name']['$value']
        lt = c['localTransform']
        pos = [lt['Position'][k]['Bits'] / 131072 for k in 'xyz']
        q = lt['Orientation']
        sc = c.get('visualScale', {'X': 1, 'Y': 1, 'Z': 1})
        out[name] = {
            'type': c['$type'],
            'mesh': c['mesh']['DepotPath']['$value'],
            'appearance': c.get('meshAppearance', {}).get('$value', 'default'),
            'position': pos,
            'quaternion': [q.get('i', 0), q.get('j', 0), q.get('k', 0), q.get('r', 1)],
            'scale': [sc.get('X', 1), sc.get('Y', 1), sc.get('Z', 1)],
        }
    return out


def cube_materials():
    mesh = json.load(open(ROOT / 'json' / '3dmap_triangle_soup.mesh.json', encoding='utf-8'))['Data']['RootChunk']
    names = [e['name']['$value'] for e in mesh['materialEntries']]
    mats = {}
    for n, m in zip(names, mesh['localMaterialBuffer']['materials']):
        p = {}
        for v in m['values']:
            for k, val in v.items():
                if k != '$type':
                    p[k] = val
        mats[n] = p
    return mats


def quat_rotate(q, v):
    x, y, z, w = q
    u = np.array([x, y, z])
    v = np.asarray(v, dtype=np.float64)
    return v + 2.0 * np.cross(u, np.cross(u, v) + w * v)


def districts():
    """Decoded building boxes per district: dict name -> dict(center, quat, size)."""
    comps = components()
    mats = cube_materials()
    out = {}
    for name, c in comps.items():
        if 'triangle_soup' not in c['mesh']:
            continue
        app = c['appearance']
        m = mats.get(app)
        if not m or 'TransMin' not in m:
            continue
        tex = m['WorldPosTex']['DepotPath']['$value'].split('\\')[-1].replace('.xbm', '.dds')
        (b0, b1, b2), H = load_dds_rgba16(DDS / tex)
        mn = np.array([m['TransMin'][k] for k in 'XYZ'])
        mx = np.array([m['TransMax'][k] for k in 'XYZ'])
        ok = b0[:, 3] > 0.5
        center = mn + b0[ok, :3] * (mx - mn) + np.array(c['position'])
        quat = b1[ok] * 2.0 - 1.0
        size = b2[ok, :3] * float(m['CubeSize'])
        out[app] = {'center': center, 'quat': quat, 'size': size, 'cubeSize': float(m['CubeSize'])}
    return out
