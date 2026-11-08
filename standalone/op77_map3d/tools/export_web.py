"""Exports the game's 3D map to compact web assets for op77_map3d.

Output (into the directory given as argv[1], e.g. the resource's web/data):
  world.glb       terrain, water, roads, road borders, metro, cliffs and landmarks,
                  world transforms baked, one node per layer (three.js Y-up:
                  scene (x, y, z) = game (x, z, -y))
  buildings.bin   one 16-byte record per building box (255k), see manifest.buildings
  roads.bin       the GPS lane graph (vehicle lanes of the game's traffic system)
  manifest.json   layout of the binaries, districts, bounds, conventions

Game data read from the extracted folders next to this script (see README).
"""
import json, sys, pathlib, struct, time
import numpy as np
import trimesh
from mapdata import ROOT, RAW, districts, components, gl_to_world, quat_rotate

OUT = pathlib.Path(sys.argv[1])
OUT.mkdir(parents=True, exist_ok=True)
manifest = {
    'format': 'op77_map3d/1',
    'generated': time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime()),
    'source': 'Cyberpunk 2077 2.x + Phantom Liberty: base\\entities\\cameras\\3dmap, base\\worlds\\03_night_city\\sectors\\_generated\\traffic',
    'coordinates': 'game metres, X east, Y north, Z up; three.js scene = (x, z, -y)',
}


def to_scene(w):
    """game (x, y, z) -> three.js (x, z, -y)"""
    w = np.asarray(w, dtype=np.float64)
    return np.stack([w[:, 0], w[:, 2], -w[:, 1]], 1)


# --------------------------------------------------------------------------
# world.glb
comps = components()
LAYERS = [
    # layer, component, glb
    ('terrain', 'terrain_mesh', '3dmap_terrain.glb'),
    ('water', 'water_mesh', '3dmap_water.glb'),
    ('roads', '3dmap_roads', '3dmap_roads.glb'),
    ('roadBorders', '3dmap_roads_borders', '3dmap_roads_borders.glb'),
    ('metro', '3dmap_metro', '3dmap_metro.glb'),
    ('cliffs', '3dmap_cliffs', '3dmap_cliffs.glb'),
    ('landmarks', 'statue_splash_a', '3dmap_statue_splash_a.glb'),
    ('landmarks', 'ext_monument_av_building_b', '3dmap_ext_monument_av_building_b.glb'),
    ('landmarks', 'obelisk', '3dmap_obelisk.glb'),
    ('landmarks', 'monument_ave_pyramid', 'monument_ave_pyramid.glb'),
    ('landmarks', 'cz_cz_building_h_icosphere', 'cz_cz_building_h_icosphere.glb'),
    ('landmarks', 'ferris_wheel_pacifica', 'rcr_park_ferris_wheel.glb'),
    ('landmarks', 'ferris_wheel_collapsed', 'rcr_park_ferris_wheel.glb'),
    ('landmarks', 'northoak_sign_a', 'northoak_sign_a.glb'),
]
scene = trimesh.Scene()
layer_stats = {}
merged = {}
for layer, comp, glb in LAYERS:
    c = comps[comp]
    mesh = trimesh.load(RAW / 'entities/cameras/3dmap' / glb, force='mesh', process=False)
    w = gl_to_world(mesh.vertices) * np.array(c['scale'])
    q = c['quaternion']
    w = np.array([quat_rotate(q, v) for v in w]) if q != [0, 0, 0, 1] else w
    w = w + np.array(c['position'])
    merged.setdefault(layer, []).append((to_scene(w), np.asarray(mesh.faces)))
for layer, parts in merged.items():
    verts, faces, base = [], [], 0
    for v, f in parts:
        verts.append(v)
        faces.append(f + base)
        base += len(v)
    m = trimesh.Trimesh(np.concatenate(verts).astype(np.float32), np.concatenate(faces), process=True)
    m.remove_unreferenced_vertices()
    # positions only: the page shades with screen-space normals
    m.visual = trimesh.visual.ColorVisuals(m)
    scene.add_geometry(m, node_name=layer, geom_name=layer)
    layer_stats[layer] = {'triangles': int(len(m.faces)), 'vertices': int(len(m.vertices))}
    print(layer, layer_stats[layer], flush=True)
glb = scene.export(file_type='glb', include_normals=False)
(OUT / 'world.raw.glb').write_bytes(glb)
manifest['world'] = {'file': 'world.glb', 'layers': layer_stats}

# --------------------------------------------------------------------------
# buildings.bin: per box 16 bytes
#   u16 x3 position, normalized over the district's box (scene coordinates)
#   i8  x4 orientation quaternion (scene frame), /127
#   u16 x3 size (game x, y, z extents), normalized by the district's maxSize
bdist = []
chunks = []
offset = 0
for name, d in districts().items():
    center = to_scene(d['center'])
    # game quaternion -> scene frame: rotate the axis vector like positions
    qg = d['quat']
    axis = np.stack([qg[:, 0], qg[:, 2], -qg[:, 1]], 1)
    qs = np.concatenate([axis, qg[:, 3:4]], 1)
    qs /= np.linalg.norm(qs, axis=1, keepdims=True)
    size = np.stack([d['size'][:, 0], d['size'][:, 2], d['size'][:, 1]], 1)  # scene x, y(up), z
    lo, hi = center.min(0), center.max(0)
    span = np.maximum(hi - lo, 1e-3)
    maxsize = float(max(size.max(), 1e-3))
    pos16 = np.round((center - lo) / span * 65535).astype('<u2')
    q8 = np.round(qs * 127).astype('i1')
    size16 = np.round(size / maxsize * 65535).astype('<u2')
    rec = np.zeros(len(center), dtype=[('p', '<u2', 3), ('q', 'i1', 4), ('s', '<u2', 3)])
    rec['p'], rec['q'], rec['s'] = pos16, q8, size16
    chunks.append(rec.tobytes())
    bdist.append({'name': name, 'offset': offset, 'count': int(len(center)), 'min': lo.round(3).tolist(),
                  'span': span.round(3).tolist(), 'maxSize': round(maxsize, 4)})
    offset += len(center)
(OUT / 'buildings.bin').write_bytes(b''.join(chunks))
manifest['buildings'] = {'file': 'buildings.bin', 'stride': 16, 'count': offset, 'districts': bdist,
                         'record': 'u16 pos[3] (min + v/65535*span), i8 quat[4] (/127, scene frame), u16 size[3] (v/65535*maxSize: scene x, y, z full extents)'}
print('buildings', offset, flush=True)

# --------------------------------------------------------------------------
# roads.bin: the GPS graph (vehicle lanes)
TJ = ROOT / 'json-traffic'
persist = json.load(open(TJ / 'all.traffic_persistent.json', encoding='utf-8'))['Data']['RootChunk']['data']['lanes']
polys = json.load(open(TJ / 'all.lane_polygons.json', encoding='utf-8'))['Data']['RootChunk']['data']
conns = json.load(open(TJ / 'all.lane_connections.json', encoding='utf-8'))['Data']['RootChunk']['data']
ROAD, PAVEMENT, GPSONLY, BLOCKADE, TRAFFIC_OFF, HIGHWAY = 16, 8, 512, 2048, 128, 16384
outline = {p['index']: p['value']['outline'] for p in polys}
links = {c['index']: [o['laneIndex'] for o in c['value'].get('outlanes', [])] for c in conns}
keep = []
for i, l in enumerate(persist):
    f = l['flags'] & 0xFFFF
    if f & PAVEMENT or f & BLOCKADE:
        continue
    if not (f & ROAD or f & GPSONLY):
        continue
    if len(outline.get(i, [])) < 2:
        continue
    keep.append(i)
remap = {old: new for new, old in enumerate(keep)}
pts, lane_off, lane_cnt, lane_flags, lane_speed, lane_len, out_start, out_list = [], [], [], [], [], [], [0], []
for old in keep:
    o = outline[old]
    lane_off.append(len(pts))
    lane_cnt.append(len(o))
    for p in o:
        pts.append((p['X'], p['Y'], p['Z']))
    l = persist[old]
    lane_flags.append(l['flags'] & 0xFFFF)
    lane_speed.append(min(255, int(round(l['maxSpeed']))))
    lane_len.append(l['length'])
    nxt = [remap[n] for n in links.get(old, []) if n in remap]
    out_list.extend(nxt)
    out_start.append(len(out_list))
# Lanes of the largest strongly connected component: the GPS snaps its ends to
# these so a route always exists (the rest are parking stubs and dead ends).
import networkx as nx
G = nx.DiGraph()
G.add_nodes_from(range(len(keep)))
for i in range(len(keep)):
    for j in out_list[out_start[i]:out_start[i + 1]]:
        G.add_edge(i, j)
main = max(nx.strongly_connected_components(G), key=len)
lane_main = np.array([1 if i in main else 0 for i in range(len(keep))], dtype='u1')
arrays = [
    ('points', np.asarray(pts, dtype='<f4')),            # game x, y, z
    ('laneMain', lane_main),
    ('laneOffset', np.asarray(lane_off, dtype='<u4')),
    ('laneCount', np.asarray(lane_cnt, dtype='<u2')),
    ('laneFlags', np.asarray(lane_flags, dtype='<u2')),
    ('laneSpeed', np.asarray(lane_speed, dtype='u1')),
    ('laneLength', np.asarray(lane_len, dtype='<f4')),
    ('outStart', np.asarray(out_start, dtype='<u4')),
    ('outLanes', np.asarray(out_list, dtype='<u4')),
]
blob, layout = b'', {}
for name, a in arrays:
    pad = (-len(blob)) % 4
    blob += b'\0' * pad
    layout[name] = {'offset': len(blob), 'length': int(a.size), 'type': a.dtype.str}
    blob += a.tobytes()
(OUT / 'roads.bin').write_bytes(blob)
manifest['roads'] = {'file': 'roads.bin', 'lanes': len(keep), 'points': len(pts), 'links': len(out_list), 'arrays': layout,
                     'flags': {'road': ROAD, 'gpsOnly': GPSONLY, 'trafficDisabled': TRAFFIC_OFF, 'highway': HIGHWAY},
                     'speed': 'm/s (lane maxSpeed)', 'points.coordinates': 'game x, y, z'}
print('roads', len(keep), 'lanes', len(pts), 'points', len(out_list), 'links', flush=True)

# --------------------------------------------------------------------------
manifest['districts'] = {n: {'center': np.round(np.mean(d['center'], 0), 1).tolist()} for n, d in districts().items()}
(OUT / 'manifest.json').write_text(json.dumps(manifest, indent=2))
print('manifest written', OUT)
