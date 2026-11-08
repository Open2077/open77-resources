"""Offline fit measurements of stock car bodies, for the vehicle-kit body parts.

    python scripts/vehicle-kit/blender/body_measure.py --extract            # extract, then measure
    python scripts/vehicle-kit/blender/body_measure.py                      # measure what is extracted
    python scripts/vehicle-kit/blender/body_measure.py --dealer <player inventory> --cars all --work <dir>

Plain Python 3 (no bpy, no numpy). Read-only on the game: WolvenKit CLI extracts the
entity, appearance, rig and exterior meshes of each car into a work folder OUTSIDE the
repository (default %TEMP%/open77-vehicle-kit-measure/bodykit, refused inside it), then
this script assembles the exterior panels in the vehicle frame and prints numbers.

Nothing it extracts may be committed. Its outputs are:
  <work>/measure.json   numbers only (bounds, wheel centres, roof, front bumper
                        bottom, sill line, slot bones), in the Root frame and the Base frame;
                        body_fit.py turns them into the spec's fit table;
  <work>/maps.json     coarse height maps (top/bottom per 4 cm cell, half-width per
                        4 cm of length and height, centre profile) for body_fit.py and
                        the review board's car proxies. Never committed.

Frames (metres, X right, Y forward, Z up):
  Root  the rig root = the vehicle entity frame (props.attach bone '' on a vehicle);
  Base  the rig bone the body shell is bound to (vehicle_slots/Base). Body panels are
        authored relative to their slot bone, so the assembly composes the rig's bind pose.
"""
import argparse
import json
import math
import os
import re
import struct
import subprocess
import sys
import tempfile
from pathlib import Path

CARS = 'hella bandit quartz cortes colby galena maimai hozuki thrax supron columbus merrimac semimaru caliburn'.split()
REPO = Path(__file__).resolve().parents[3]
DEALER = REPO / 'docs/generated/vehicle-components-dealer-2.50.json'
SKIP_FLAGS = {'placeable', 'shadow', 'decal', 'part:interior', 'wheel', 'tire', 'rim', 'part:chassis', 'widget'}
SLICE = 0.05          # profile slice along Y
CELL = 0.04           # height-map cell
# Factory accessories a kit part replaces or clashes with: measured on their own and kept
# out of the body numbers (the roof under a factory rack, the deck under a factory wing).
# wing_b / wing_c: the two blades of the Caliburn's active rear wing (wing_a is its centre).
ACCESSORY = re.compile(r'^(roof_rack|v_common_suitcase_01|junk_solar|wing_[abc]|trunk_spoiler|attachment_antenna)')
# The cars beyond the first 14 also leave out every factory part the kit hides on them
# (specs/lightrp-bodykit-hides.json, inventory/body_hides.py): a kit wing stands where the
# factory spoiler was. The first 14 keep ACCESSORY alone, so their numbers do not move.
HIDES = REPO / 'scripts/vehicle-kit/specs/lightrp-bodykit-hides.json'
_HIDDEN = {}


def hidden_names(key):
    if key in CARS:
        return set()
    if not _HIDDEN and HIDES.exists():
        for k, row in json.loads(HIDES.read_text(encoding='utf-8'))['cars'].items():
            _HIDDEN[k] = {n for names in (row.get('hide') or {}).values() for n in names}
    return _HIDDEN.get(key, set())


# --------------------------------------------------------------------------- math
def qmul(a, b):
    ax, ay, az, aw = a; bx, by, bz, bw = b
    return (aw * bx + ax * bw + ay * bz - az * by, aw * by - ax * bz + ay * bw + az * bx,
            aw * bz + ax * by - ay * bx + az * bw, aw * bw - ax * bx - ay * by - az * bz)


def qrot(q, v):
    x, y, z, w = q
    vx, vy, vz = v
    # v' = v + 2w (q x v) + 2 q x (q x v)
    cx, cy, cz = y * vz - z * vy, z * vx - x * vz, x * vy - y * vx
    cx2, cy2, cz2 = y * cz - z * cy, z * cx - x * cz, x * cy - y * cx
    return (vx + 2 * (w * cx + cx2), vy + 2 * (w * cy + cy2), vz + 2 * (w * cz + cz2))


def compose(parent, local):
    """(q, t) transforms: world = parent * local."""
    pq, pt = parent
    lq, lt = local
    r = qrot(pq, lt)
    return qmul(pq, lq), (pt[0] + r[0], pt[1] + r[1], pt[2] + r[2])


IDENTITY = ((0.0, 0.0, 0.0, 1.0), (0.0, 0.0, 0.0))


def apply(tf, p):
    q, t = tf
    r = qrot(q, p)
    return (r[0] + t[0], r[1] + t[1], r[2] + t[2])


# --------------------------------------------------------------------------- extraction
def cv(x):
    return x.get('$value') if isinstance(x, dict) else x


def run(cmd):
    out = subprocess.run(cmd, capture_output=True, text=True, encoding='utf-8', errors='replace')
    if out.returncode != 0:
        tail = '\n'.join((out.stdout + out.stderr).splitlines()[-15:])
        raise SystemExit(f'body_measure: {Path(cmd[0]).name} {cmd[1]} failed ({out.returncode})\n{tail}')
    return out.stdout


def depot_regexes(paths, limit=12000):
    """Regexes matching exactly these depot paths, grouped by folder and split so each
    stays far below the Windows command-line limit."""
    by_dir = {}
    for p in sorted(paths):
        d, _, name = p.rpartition('\\')
        by_dir.setdefault(d, []).append(name)
    groups, size, out = [], 0, []
    for d, names in by_dir.items():
        g = re.escape(d + '\\') + '(' + '|'.join(re.escape(n) for n in names) + ')'
        if groups and size + len(g) > limit:
            out.append('^(' + '|'.join(groups) + ')$')
            groups, size = [], 0
        groups.append(g)
        size += len(g) + 1
    if groups:
        out.append('^(' + '|'.join(groups) + ')$')
    return out


def wk_extract(cli, game, paths, outdir, uncook=False):
    # ep1 paths live in archive/pc/ep1, the rest in archive/pc/content.
    for folder, pick in (('archive/pc/content', lambda p: not p.startswith('ep1\\')), ('archive/pc/ep1', lambda p: p.startswith('ep1\\'))):
        src = Path(game) / folder
        mine = [p for p in paths if pick(p)]
        if not src.exists() or not mine:
            continue
        for regex in depot_regexes(mine):
            if uncook:
                run([cli, 'uncook', str(src), '--regex', regex, '--outpath', str(outdir), '--gamepath', str(game),
                     '--mesh-export-type', 'MeshOnly', '--verbosity', 'Minimal'])
            else:
                run([cli, 'extract', str(src), '--regex', regex, '--outpath', str(outdir), '--gamepath', str(game),
                     '--verbosity', 'Minimal'])


def serialize(cli, files, outdir):
    files = [str(f) for f in files]
    for i in range(0, len(files), 40):
        run([cli, 'convert', 'serialize', *files[i:i + 40], '--outpath', str(outdir), '--verbosity', 'Minimal'])


def comps_of(root):
    chunks = ((root.get('compiledData') or {}).get('Data') or {}).get('Chunks') or []
    return [c for c in (root.get('components') or []) + chunks if c]


def rig_path_of(ent_json):
    root = json.loads(Path(ent_json).read_text(encoding='utf-8'))['Data']['RootChunk']
    for c in comps_of(root):
        if c.get('$type') == 'entAnimatedComponent' and cv(c.get('name')) == 'deformation_rig':
            return cv(c['rig']['DepotPath'])
    raise SystemExit(f'body_measure: no deformation_rig in {ent_json}')


def selected_components(model):
    rows = []
    for c in model['components']:
        if not c.get('inPlayerAppearance'):
            continue
        flags = set(c.get('flags') or [])
        proxy = c['type'] == 'entAppearanceProxyMeshComponent'
        if not c.get('mesh') or (not proxy and (flags & SKIP_FLAGS or '__int01' in c['mesh'])):
            continue
        # A bare number is a depot hash the names table lacks (the Legatus' bullet-hole decal,
        # the Outlaw heist's light strip): nothing can extract or measure it by name.
        if c['mesh'].isdigit():
            continue
        if c['type'] == 'entSkinnedMeshComponent':
            continue
        rows.append(c)
    return rows


def extract(work, game, cli, models):
    raw, js, glb = work / 'raw', work / 'json', work / 'glb'
    for d in (raw, js, glb):
        d.mkdir(parents=True, exist_ok=True)
    ents = {m['entity']['path'] for m in models}
    apps = {a['app'] for m in models for a in m['appearances'] if a['name'] == m['playerAppearance']}
    print(f'extract: {len(ents)} entities, {len(apps)} appearance files')
    wk_extract(cli, game, ents | apps, raw)
    serialize(cli, [p for p in raw.rglob('*') if p.suffix in ('.ent', '.app')], js)
    rigs = {rig_path_of(js / (Path(m['entity']['path'].replace('\\', '/')).name + '.json')) for m in models}
    print(f'extract: {len(rigs)} rigs')
    wk_extract(cli, game, rigs, raw)
    serialize(cli, list(raw.rglob('*.rig')), js)
    meshes = {c['mesh'] for m in models for c in selected_components(m)}
    print(f'extract: {len(meshes)} meshes (MeshOnly glb)')
    wk_extract(cli, game, meshes, glb, uncook=True)


# --------------------------------------------------------------------------- reading
def rig_bones(rig_json):
    root = json.loads(Path(rig_json).read_text(encoding='utf-8'))['Data']['RootChunk']
    names = [cv(n) for n in root['boneNames']]
    parents = root['boneParentIndexes']
    world = []
    for i, t in enumerate(root['boneTransforms']):
        r, tr = t['Rotation'], t['Translation']
        local = ((r['i'], r['j'], r['k'], r['r']), (tr['X'], tr['Y'], tr['Z']))
        world.append(local if parents[i] < 0 else compose(world[parents[i]], local))
    return dict(zip(names, world))


def slot_table(ent_json):
    """slot component name -> slot name -> (bone, relative transform)."""
    root = json.loads(Path(ent_json).read_text(encoding='utf-8'))['Data']['RootChunk']
    table = {}
    for c in comps_of(root):
        if c.get('$type') != 'entSlotComponent':
            continue
        slots = {}
        for s in c.get('slots') or []:
            p, q = s['relativePosition'], s['relativeRotation']
            slots[cv(s['slotName'])] = (cv(s['boneName']), ((q['i'], q['j'], q['k'], q['r']), (p['X'], p['Y'], p['Z'])))
        table[cv(c['name'])] = slots
    return table


def app_local_transforms(app_json, appearance):
    root = json.loads(Path(app_json).read_text(encoding='utf-8'))['Data']['RootChunk']
    for a in root.get('appearances') or []:
        if cv(a['Data']['name']) == appearance:
            out = {}
            for c in a['Data'].get('components') or []:
                t = c.get('localTransform')
                if not t or not c.get('name'):
                    continue
                o, p = t['Orientation'], t['Position']
                out[cv(c['name'])] = ((o['i'], o['j'], o['k'], o['r']),
                                      tuple((p[k].get('Bits', 0) if isinstance(p[k], dict) else 0) / 131072.0 for k in 'xyz'))
            return out
    raise SystemExit(f'body_measure: appearance {appearance} not in {app_json}')


def read_glb(path):
    """LOD_1 triangles of a WolvenKit MeshOnly glb, in engine axes (x, -z_gltf, y_gltf)."""
    data = Path(path).read_bytes()
    n = struct.unpack_from('<I', data, 12)[0]
    doc = json.loads(data[20:20 + n])
    off = 20 + n
    blen = struct.unpack_from('<I', data, off)[0]
    blob = data[off + 8:off + 8 + blen]
    tris = []
    for mesh in doc['meshes']:
        if not mesh['name'].endswith('LOD_1'):
            continue
        for prim in mesh['primitives']:
            acc = doc['accessors'][prim['attributes']['POSITION']]
            view = doc['bufferViews'][acc['bufferView']]
            stride = view.get('byteStride', 12)
            start = view.get('byteOffset', 0) + acc.get('byteOffset', 0)
            verts = []
            for i in range(acc['count']):
                gx, gy, gz = struct.unpack_from('<3f', blob, start + i * stride)
                verts.append((gx, -gz, gy))
            ia = doc['accessors'][prim['indices']]
            iv = doc['bufferViews'][ia['bufferView']]
            fmt = {5121: 'B', 5123: 'H', 5125: 'I'}[ia['componentType']]
            size = struct.calcsize(fmt)
            istart = iv.get('byteOffset', 0) + ia.get('byteOffset', 0)
            idx = struct.unpack_from(f'<{ia["count"]}{fmt}', blob, istart)
            for i in range(0, len(idx) - 2, 3):
                tris.append((verts[idx[i]], verts[idx[i + 1]], verts[idx[i + 2]]))
    return tris


def sample(tris, spacing=0.035):
    """Vertices plus a barycentric grid on large triangles, so flat panels are sampled."""
    pts = []
    for a, b, c in tris:
        e = max(math.dist(a, b), math.dist(b, c), math.dist(c, a))
        k = max(1, int(math.ceil(e / spacing)))
        if k == 1:
            pts.extend((a, b, c))
            continue
        for i in range(k + 1):
            for j in range(k + 1 - i):
                u, v = i / k, j / k
                w = 1 - u - v
                pts.append((a[0] * w + b[0] * u + c[0] * v, a[1] * w + b[1] * u + c[1] * v, a[2] * w + b[2] * u + c[2] * v))
    return pts


# --------------------------------------------------------------------------- assembly
def assemble(model, work):
    js, glb = work / 'json', work / 'glb'
    ent_json = js / (Path(model['entity']['path'].replace('\\', '/')).name + '.json')
    bones = rig_bones(js / (Path(rig_path_of(ent_json).replace('\\', '/')).name + '.json'))
    slots = slot_table(ent_json)
    app = next(a for a in model['appearances'] if a['name'] == model['playerAppearance'])
    locals_ = app_local_transforms(js / (Path(app['app'].replace('\\', '/')).name + '.json'), app['appearanceName'])
    comps = {c['name']: c for c in model['components'] if c.get('inPlayerAppearance')}
    cache = {}

    def world_of(name, depth=0):
        if name in cache:
            return cache[name]
        if depth > 12:
            raise SystemExit(f'binding loop at {name}')
        c = comps.get(name)
        parent = (c or {}).get('parent') or {}
        bind, slot = parent.get('bindName'), parent.get('slotName')
        if bind in slots and slot:
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

    parts, proxy = [], []
    for c in selected_components(model):
        f = glb / (c['mesh'].replace('\\', '/')[:-5] + '.glb')
        if not f.exists():
            print(f'  {model["key"]}: missing {f.name}')
            continue
        tf = world_of(c['name'])
        tris = [tuple(apply(tf, p) for p in t) for t in read_glb(f)]
        (proxy if c['type'] == 'entAppearanceProxyMeshComponent' else parts).append((c['name'], tris))
    return bones, parts, proxy


def bbox(points):
    xs, ys, zs = zip(*points)
    return [[min(xs), min(ys), min(zs)], [max(xs), max(ys), max(zs)]]


def r3(v):
    return [round(x, 3) for x in v]


def body_parts(model, work):
    """The assembled exterior split the way the fit uses it: (bones, body, accessories,
    dropped, proxy box). body = [(name, tris, samples)] of the panels kept in the body
    numbers; accessories = {name: tris} (factory accessories a kit part replaces);
    dropped = {name: metres outside the proxy}. body_surface.py rasterizes the same set."""
    bones, parts, proxy = assemble(model, work)
    proxy_pts = [p for _, tris in proxy for t in tris for p in t]
    pbox = bbox(proxy_pts) if proxy_pts else None
    body, accessories, dropped = [], {}, {}
    hidden = hidden_names(model['key'])
    for name, tris in parts:
        s = sample(tris)
        b = bbox(s)
        # A part far outside the appearance proxy is mis-placed by this simple assembly
        # (an environment prop with its own transform chain): left out of the numbers.
        over = max(max(pbox[0][i] - b[0][i], b[1][i] - pbox[1][i]) for i in range(3)) if pbox else 0
        if ACCESSORY.search(name) or name in hidden:
            accessories[name] = tris
            continue
        if over > 0.08:
            dropped[name] = round(over, 3)
            continue
        body.append((name, tris, s))
    return bones, body, accessories, dropped, pbox


def measure(model, work, slots_out=('Base', 'trunk_a', 'trunk_b', 'hood_a', 'bumper_front', 'bumper_back')):
    bones, body, acc_tris, dropped, pbox = body_parts(model, work)
    base_tf = bones['Base']
    base_t = base_tf[1]
    base_q = base_tf[0]
    pts = []
    per_part = {}
    accessories = {name: [r3(b[0]), r3(b[1])] for name, tris in acc_tris.items()
                   for b in [bbox(sample(tris))]}
    for name, tris, s in body:
        pts.extend(s)
        per_part[name] = bbox(s)
    box = bbox(pts)

    # Wheels from the rig bind pose.
    wheels = {k: bones[k][1] for k in ('wheel_front_left', 'wheel_front_right', 'wheel_back_left', 'wheel_back_right') if k in bones}
    tire_f = model['wheels']['front']['tireRadius']
    tire_b = model['wheels']['back']['tireRadius']
    wf, wb = wheels['wheel_front_left'], wheels['wheel_back_left']
    ground = min(wf[2] - tire_f, wb[2] - tire_b)

    # Height maps on a CELL grid: top z, bottom z per (x, y); half-width per (y, z).
    top, bot, side = {}, {}, {}
    for x, y, z in pts:
        k = (round(x / CELL), round(y / CELL))
        if z > top.get(k, -9):
            top[k] = z
        if z < bot.get(k, 9):
            bot[k] = z
        ks = (round(y / CELL), round(z / CELL))
        if abs(x) > side.get(ks, 0):
            side[ks] = abs(x)

    def centre_top(y, half=0.30):
        vals = [z for (ix, iy), z in top.items() if abs(ix * CELL) <= half and abs(iy * CELL - y) < CELL * 0.75]
        return max(vals) if vals else None

    ymin, ymax = box[0][1], box[1][1]
    ys = [round(ymin + i * SLICE, 4) for i in range(int((ymax - ymin) / SLICE) + 1)]
    profile = []
    for y in ys:
        zt = centre_top(y)
        zb = [z for (ix, iy), z in bot.items() if abs(iy * CELL - y) < CELL * 0.75]
        hw = [w for (iy, iz), w in side.items() if abs(iy * CELL - y) < CELL * 0.75]
        profile.append({'y': y, 'top': None if zt is None else round(zt, 3), 'bottom': round(min(zb), 3) if zb else None,
                        'halfWidth': round(max(hw), 3) if hw else None})

    # Roof: the highest centre-line section and the run of the profile within 4 cm of it.
    roof_z = max(p['top'] for p in profile if p['top'] is not None)
    roof_run = [p['y'] for p in profile if p['top'] is not None and p['top'] >= roof_z - 0.04]
    flat_run = [p['y'] for p in profile if p['top'] is not None and p['top'] >= roof_z - 0.08]
    roof_ys = [min(roof_run), max(roof_run)]
    # Roof half-width at the roof's middle: cells within 10 cm of the top.
    ymid = (roof_ys[0] + roof_ys[1]) / 2
    row = [(ix * CELL, z) for (ix, iy), z in top.items() if abs(iy * CELL - ymid) < CELL * 0.75]
    # default=None: a roof crowned by a factory device off the centre line (galena_bobas)
    roof_half = max((abs(x) for x, z in row if z >= roof_z - 0.10), default=None) if row else None

    # Front bumper: lowest centre point in the front 40 cm, and how far forward the
    # bumper reaches 8 cm above that.
    front = [(x, y, z) for x, y, z in pts if y > ymax - 0.40 and abs(x) < 0.55]
    fz = min(z for _, _, z in front)
    fy_low = max(y for _, y, z in front if z < fz + 0.08)
    lowband = [(x, y, z) for x, y, z in pts if y > ymax - 0.45 and z < fz + 0.10]
    front_half = max(abs(x) for x, _, _ in lowband)
    front_face = [(x, y, z) for x, y, z in pts if y > ymax - 0.12 and abs(x) < 0.5]
    bar_top = max(z for _, _, z in front_face) if front_face else None

    # Sill: between the wheel arches, the lowest outer point and the side's width there.
    arch = max(tire_f, tire_b) + 0.10
    y0, y1 = wb[1] + arch, wf[1] - arch
    mid = [(x, y, z) for x, y, z in pts if y0 < y < y1]
    outer = max(abs(x) for x, _, _ in mid)
    sill_z = min(z for x, _, z in mid if abs(x) > outer - 0.22)
    sill_x = max(abs(x) for x, _, z in mid if sill_z <= z <= sill_z + 0.12)
    side_x = max(abs(x) for x, _, z in mid if sill_z + 0.12 <= z <= sill_z + 0.45)

    out = {
        'record': model['record'], 'appearance': model['playerAppearance'],
        'baseBone': {'translation': r3(base_t), 'rotation': r3(base_q)},
        'bounds': [r3(box[0]), r3(box[1])], 'proxyBounds': [r3(pbox[0]), r3(pbox[1])] if pbox else None,
        'groundZ': round(ground, 3),
        'wheels': {'frontY': round(wf[1], 3), 'backY': round(wb[1], 3), 'trackHalf': round(abs(wf[0]), 3),
                   'centreZ': round(wf[2], 3), 'tireRadius': [tire_f, tire_b], 'wheelbase': round(wf[1] - wb[1], 3)},
        'roof': {'z': round(roof_z, 3), 'ys': [round(v, 3) for v in roof_ys],
                 'flatYs': [round(min(flat_run), 3), round(max(flat_run), 3)],
                 'halfWidth': None if roof_half is None else round(roof_half, 3)},
        'front': {'y': round(ymax, 3), 'bumperBottomZ': round(fz, 3), 'bumperBottomY': round(fy_low, 3),
                  'halfWidthLow': round(front_half, 3), 'faceTopZ': None if bar_top is None else round(bar_top, 3)},
        'sill': {'y0': round(y0, 3), 'y1': round(y1, 3), 'z': round(sill_z, 3), 'x': round(sill_x, 3), 'sideX': round(side_x, 3)},
        'rear': {'y': round(ymin, 3)},
        'parts': {k: [r3(v[0]), r3(v[1])] for k, v in sorted(per_part.items())},
        'accessories': accessories, 'dropped': dropped,
        'slotBones': {s: {'translation': r3(bones[s][1]), 'rotation': r3(bones[s][0])} for s in slots_out if s in bones},
        'frames': 'Root (entity) frame; subtract baseBone.translation for the Base slot frame (Base rotation is identity when baseBone.rotation is [0,0,0,1])',
    }
    maps = {'cell': CELL, 'top': [[ix, iy, round(z, 3)] for (ix, iy), z in top.items()],
            'bottom': [[ix, iy, round(z, 3)] for (ix, iy), z in bot.items()],
            'side': [[iy, iz, round(w, 3)] for (iy, iz), w in side.items()], 'profile': profile}
    return out, maps


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('--work', type=Path, default=Path(tempfile.gettempdir()) / 'open77-vehicle-kit-measure' / 'bodykit')
    ap.add_argument('--dealer', type=Path, default=DEALER)
    ap.add_argument('--cars', default=','.join(CARS), help="comma list, or 'all' for every car of --dealer")
    ap.add_argument('--extract', action='store_true', help='extract the game files first (WolvenKit CLI, read-only)')
    ap.add_argument('--cli', default=os.environ.get('OP77_WOLVENKIT_CLI') or str(Path.home() / '.dotnet/tools/cp77tools.exe'))
    ap.add_argument('--game', default=os.environ.get('OP77_GAME_DIR'))
    args = ap.parse_args()
    work = args.work.resolve()
    try:
        work.relative_to(REPO)
        raise SystemExit(f'body_measure: {work} is inside the repository; game data must stay outside it')
    except ValueError:
        pass
    dealer = json.loads(args.dealer.read_text(encoding='utf-8'))
    if args.cars == 'all':
        # Every car of the inventory (player_body_components.py widens it to all player cars);
        # bikes are out of the body kit's scope.
        wanted = [m['key'] for m in dealer['models'] if m['tweakdb']['vehicleType'] != 'Bike']
    else:
        wanted = args.cars.split(',')
    models = [m for m in dealer['models'] if m['key'] in wanted]
    if args.extract:
        if not args.game:
            raise SystemExit('body_measure: --game or OP77_GAME_DIR is required to extract')
        extract(work, args.game, args.cli, models)
    result, maps = {}, {}
    for m in models:
        out, mp = measure(m, work)
        result[m['key']] = out
        maps[m['key']] = dict(mp, record=m['record'], groundZ=out['groundZ'], wheels=out['wheels'], baseBone=out['baseBone'])
        print(f"{m['key']:9} len {out['bounds'][1][1] - out['bounds'][0][1]:.2f} roof {out['roof']['z']:.2f} ys {out['roof']['ys']} "
              f"front {out['front']['bumperBottomZ']:.2f}@{out['front']['bumperBottomY']:.2f} hw {out['front']['halfWidthLow']:.2f} "
              f"sill z {out['sill']['z']:.2f} x {out['sill']['x']:.2f} ground {out['groundZ']:.2f} wb {out['wheels']['wheelbase']:.2f} "
              f"base {out['baseBone']['translation']} acc {sorted(out['accessories'])} dropped {sorted(out['dropped'])}")
    (work / 'measure.json').write_text(json.dumps({'schema': 'open77.vehicle-kit.body-measure/1', 'cars': result}, indent=1), encoding='utf-8')
    (work / 'maps.json').write_text(json.dumps(maps), encoding='utf-8')
    print(f'VK_BODY_MEASURE_OK cars={len(result)} out={work / "measure.json"}')


if __name__ == '__main__':
    main()
