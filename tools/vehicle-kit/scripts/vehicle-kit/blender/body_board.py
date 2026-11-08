"""Owner review board for the body kit (Blender 4.5, background).

    blender --background --factory-startup --python body_board.py -- \
        --spec specs/lightrp-bodykit.json --fit specs/lightrp-bodykit-fit.json \
        --parts <build work>/parts --out <git-ignored dir> [--work <measure work>] \
        [--only all|parts|cars|overview] [--cars hella,galena] [--ids wing_gt,lip_race] [--cycles]

Writes PNG sheets into --out (git-ignored), every tile also under --out/tiles:
  parts_NN.png        eight parts per sheet, one row each: every finish in 3/4, then side and
                      top orthographic views with the triangle count and size (Workbench;
                      --cycles renders the finishes with Cycles on the CPU instead);
  car_<key>.png       two build tiles (rear and front 3/4, the first fit of each group),
                      then one tile pair per part on that car: a 3/4 view framed on the part
                      and an orthographic contact view (side or front) that shows whether it
                      touches, floats or cuts the body. For centre-line parts the side view
                      draws only the right half of the body, so the centre-line profile meets
                      the part. An excluded part gets a tile of its zone with the reason.
                      Captions carry the fit evidence (float, sink, cut, ground, pose, notes);
  overview.png        the 13 bodies alone, four views each (--only overview).

The car is the STOCK EXTERIOR assembled by body_measure.py from the meshes it extracted
outside the repository (%TEMP%/open77-vehicle-kit-measure/bodykit). The triangles live
in memory only and the PNGs stay in the git-ignored artifacts folder: nothing of the game
is written into the repository or a pack. The tyres are plain cylinders. Each caption
gives the fit numbers (gaps, sinks, clearances) from the fit table's evidence.
"""
import argparse
import json
import math
import sys
from pathlib import Path

import bpy
import numpy as np
from mathutils import Euler, Matrix, Vector

sys.path.insert(0, str(Path(__file__).resolve().parent))
import vk_common as vk  # noqa: E402
import render_preview as rp  # noqa: E402  (studio_world, area_light, material)
import body_surface as bs  # noqa: E402

TILE = (640, 480)

# Camera per group: 3/4 direction (from the target toward the camera), how much context
# around the part (multiple of its radius), and the orthographic contact view.
ZONES = {
    'spoiler':  {'dir': (-0.95, -1.25, 0.75), 'ctx': 2.6, 'ortho': 'left'},
    'louver':   {'dir': (-0.75, -1.2, 1.0), 'ctx': 2.6, 'ortho': 'left'},
    'lip':      {'dir': (-1.0, 1.5, 0.12), 'ctx': 1.3, 'ortho': 'left'},
    'canard':   {'dir': (-1.35, 1.05, 0.35), 'ctx': 2.1, 'ortho': 'front'},
    'skirt':    {'dir': (-1.0, 0.35, 0.28), 'ctx': 1.25, 'ortho': 'left'},
    'diffuser': {'dir': (-0.75, -1.35, -0.02), 'ctx': 1.6, 'ortho': 'left'},
    'hood':     {'dir': (-0.75, 1.25, 0.95), 'ctx': 2.6, 'ortho': 'left'},
    'roofrack': {'dir': (-1.0, 0.85, 0.95), 'ctx': 2.0, 'ortho': 'left'},
    'bullbar':  {'dir': (-1.1, 1.35, 0.35), 'ctx': 2.0, 'ortho': 'left'},
}
ORTHO_DIRS = {'left': (-1, 0, 0), 'front': (0, 1, 0), 'rear': (0, -1, 0), 'top': (0, 0, 1)}
# Parts on the centre line: their side contact view shows the body cut at x = 0 (only the
# right half is drawn), so the centre-line profile meets the part instead of hiding it.
SECTION_GROUPS = ('spoiler', 'louver', 'lip', 'diffuser', 'hood', 'roofrack', 'bullbar')
GLASS = ('window', 'glass', 'windshield')
LIGHTS = ('light', 'lamp')


def parse():
    p = argparse.ArgumentParser()
    p.add_argument('--spec', type=Path)
    p.add_argument('--fit', type=Path)
    p.add_argument('--parts', type=Path)
    p.add_argument('--work', type=Path, default=bs.WORK)
    p.add_argument('--dealer', type=Path, default=bs.bm.DEALER, help='component inventory (player_body_components.py widens it)')
    p.add_argument('--out', required=True, type=Path)
    p.add_argument('--samples', type=int, default=24)
    p.add_argument('--cars', default='', help='comma list (default: every car in the fit table)')
    p.add_argument('--ids', default='', help='comma list of part ids for the car sheets (default: all)')
    p.add_argument('--only', choices=('all', 'parts', 'cars', 'overview'), default='all')
    p.add_argument('--cycles', action='store_true', help='render the parts sheets with Cycles (slow) instead of Workbench')
    return vk.script_args(p)


# --------------------------------------------------------------------------- scene
def use_cycles(scene, samples):
    scene.render.engine = 'CYCLES'
    scene.cycles.device = 'CPU'
    scene.cycles.samples = samples
    scene.cycles.use_denoising = True
    scene.view_settings.view_transform = 'AgX'


def use_workbench(scene):
    scene.render.engine = 'BLENDER_WORKBENCH'
    sh = scene.display.shading
    sh.light = 'STUDIO'
    sh.color_type = 'MATERIAL'
    sh.show_shadows = True
    sh.shadow_intensity = 0.35
    sh.show_cavity = True
    sh.cavity_type = 'BOTH'
    sh.show_specular_highlight = True
    scene.display.render_aa = '16'
    scene.view_settings.view_transform = 'Standard'


def setup_render(scene):
    scene.render.resolution_x, scene.render.resolution_y = TILE
    scene.render.resolution_percentage = 100
    scene.render.image_settings.file_format = 'PNG'
    scene.render.image_settings.color_mode = 'RGB'
    r = scene.render
    r.use_stamp = True
    for a in ('use_stamp_date', 'use_stamp_time', 'use_stamp_render_time', 'use_stamp_frame', 'use_stamp_frame_range',
              'use_stamp_memory', 'use_stamp_hostname', 'use_stamp_camera', 'use_stamp_lens', 'use_stamp_scene',
              'use_stamp_marker', 'use_stamp_filename', 'use_stamp_sequencer_strip'):
        if hasattr(r, a):
            setattr(r, a, False)
    r.use_stamp_note = True
    r.stamp_font_size = 13
    r.stamp_background = (0.0, 0.0, 0.0, 0.55)


def caption(scene, lines):
    scene.render.stamp_note_text = '\n'.join(short(t) for t in lines if t)


def make_camera(scene):
    data = bpy.data.cameras.new('board_cam')
    cam = bpy.data.objects.new('board_cam', data)
    scene.collection.objects.link(cam)
    scene.camera = cam
    return cam


def aim(cam, target, direction, dist, lens=50.0, ortho=None):
    cam.data.type = 'ORTHO' if ortho else 'PERSP'
    cam.data.clip_start = 0.02
    cam.data.clip_end = 200
    if ortho:
        cam.data.ortho_scale = ortho
    else:
        cam.data.lens = lens
    d = Vector(direction).normalized()
    cam.location = Vector(target) + d * dist
    up = 'Y' if abs(d.z) < 0.99 else 'Y'
    cam.rotation_euler = (Vector(target) - cam.location).to_track_quat('-Z', up).to_euler()
    if abs(d.z) > 0.99:
        cam.rotation_euler = Euler((0, 0, 0)) if d.z > 0 else Euler((math.pi, 0, 0))


def render(scene, path):
    scene.render.filepath = str(path)
    bpy.ops.render.render(write_still=True)
    return path


def stitch(rows, out_path):
    """rows: lists of PNG paths (None = empty dark tile), all TILE sized."""
    w, h = TILE
    cols = max(len(r) for r in rows)
    sheet = np.full((len(rows) * h, cols * w, 4), 0.12, dtype=np.float32)
    sheet[..., 3] = 1.0
    for r, row in enumerate(rows):
        for c, path in enumerate(row):
            if not path:
                continue
            img = bpy.data.images.load(str(path), check_existing=False)
            px = np.empty(h * w * img.channels, dtype=np.float32)
            img.pixels.foreach_get(px)
            px = px.reshape(h, w, img.channels)
            if img.channels == 3:
                px = np.concatenate([px, np.ones((h, w, 1), np.float32)], axis=2)
            y0 = (len(rows) - 1 - r) * h          # Blender rows start at the bottom
            sheet[y0:y0 + h, c * w:(c + 1) * w] = px
            bpy.data.images.remove(img)
    out = bpy.data.images.new('board_sheet', cols * w, len(rows) * h, alpha=False)
    out.pixels.foreach_set(sheet.ravel())
    out.filepath_raw = str(out_path)
    out.file_format = 'PNG'
    out.save()
    bpy.data.images.remove(out)
    return out_path


def short(text, n=92):
    text = str(text)
    return text if len(text) <= n else text[:n - 3] + '...'


def flat_material(name, color, metallic=0.0, roughness=0.5):
    mat = rp.material(name, color, metallic, roughness)
    # Viewport (Workbench) settings only; Cycles reads the node tree. A full metal under
    # Workbench's studio light reflects a dark ambient and reads as gloss black, so the
    # board shows metals at a third of their metalness to keep steel and aluminium legible.
    mat.metallic = metallic * 0.35
    mat.roughness = roughness
    return mat


# --------------------------------------------------------------------------- parts
class PartMesh:
    """One imported part: a joined LOD_1 mesh with one material slot per kit slot."""

    def __init__(self, pid, parts_dir, palette, finishes):
        meta = json.loads((parts_dir / pid / f'{pid}.part.json').read_text(encoding='utf-8'))
        before = set(bpy.data.objects)
        bpy.ops.import_scene.gltf(filepath=str(parts_dir / pid / f'{pid}.glb'))
        new = [o for o in bpy.data.objects if o not in before]
        slot_of = {s['name']: s['slot'] for s in meta['submeshes']}
        keep = [o for o in new if o.type == 'MESH' and o.name in slot_of and o.name.endswith('_LOD_1')]
        for o in new:
            if o not in keep:
                bpy.data.objects.remove(o, do_unlink=True)
        for o in keep:
            o.data.materials.clear()
            o.data.materials.append(bpy.data.materials.get(f'slot:{slot_of[o.name]}') or bpy.data.materials.new(f'slot:{slot_of[o.name]}'))
        bpy.ops.object.select_all(action='DESELECT')
        for o in keep:
            o.select_set(True)
        bpy.context.view_layer.objects.active = keep[0]
        bpy.ops.object.transform_apply(location=True, rotation=True, scale=True)
        if len(keep) > 1:
            bpy.ops.object.join()
        self.obj = bpy.context.view_layer.objects.active
        self.obj.name = f'part_{pid}'
        self.mesh = self.obj.data
        self.slots = [m.name.split(':', 1)[1] for m in self.mesh.materials]
        self.meshes = {}
        for finish, by_slot in finishes.items():
            me = self.mesh.copy()
            me.name = f'{pid}_{finish}'
            for i, slot in enumerate(self.slots):
                entry = palette[by_slot[slot]]
                me.materials[i] = flat_material(f'{finish}:{by_slot[slot]}', entry['color'], entry['metalness'], entry['roughness'])
            self.meshes[finish] = me
        bpy.data.objects.remove(self.obj, do_unlink=True)
        self.meta = meta

    def instance(self, finish, name):
        obj = bpy.data.objects.new(name, self.meshes[finish])
        bpy.context.scene.collection.objects.link(obj)
        return obj


def place(obj, off, scale=(1, 1, 1), rot=(0, 0, 0)):
    obj.matrix_world = (Matrix.Translation(Vector(off))
                        @ Euler([math.radians(a) for a in rot], 'XYZ').to_matrix().to_4x4()
                        @ Matrix.Diagonal((*scale, 1.0)))


def world_bounds(objs):
    pts = [o.matrix_world @ Vector(c) for o in objs for c in o.bound_box]
    lo = Vector((min(p.x for p in pts), min(p.y for p in pts), min(p.z for p in pts)))
    hi = Vector((max(p.x for p in pts), max(p.y for p in pts), max(p.z for p in pts)))
    return lo, hi


# --------------------------------------------------------------------------- car body
def mesh_object(name, tris, mat):
    import bmesh
    verts = [p for t in tris for p in t]
    faces = [(3 * i, 3 * i + 1, 3 * i + 2) for i in range(len(tris))]
    me = bpy.data.meshes.new(name)
    me.from_pydata(verts, [], faces)
    me.validate(clean_customdata=False)
    bm_ = bmesh.new()
    bm_.from_mesh(me)
    bmesh.ops.remove_doubles(bm_, verts=bm_.verts, dist=1e-5)
    bm_.to_mesh(me)
    bm_.free()
    for poly in me.polygons:
        poly.use_smooth = True
    me.set_sharp_from_angle(angle=math.radians(35))
    me.materials.append(mat)
    obj = bpy.data.objects.new(name, me)
    bpy.context.scene.collection.objects.link(obj)
    return obj


def car_body(key, work, models, mats, accessories=False):
    """The stock exterior of one car (in memory, from the extracted meshes) + tyres. With
    `accessories`, the factory add-ons (rack, wing, solar panel) come as separate objects
    in a returned dict, so a part that replaces one can hide it."""
    groups = {'body': [], 'glass': [], 'lights': []}
    body = bs.car_triangles(key, work, models)
    for name, tris in body:
        n = name.lower()
        g = 'glass' if any(k in n for k in GLASS) else 'lights' if any(k in n for k in LIGHTS) else 'body'
        groups[g].extend(tris)
    objs = [mesh_object(f'car_{key}_{g}', tris, mats[g]) for g, tris in groups.items() if tris]
    if accessories:
        # The right half (x >= 0) for section views, hidden until asked for.
        half = []
        for g, tris in groups.items():
            keep = [t for t in tris if max(p[0] for p in t) >= 0.0]
            if keep:
                o = mesh_object(f'half_{key}_{g}', keep, mats[g])
                o.hide_render = True
                half.append(o)
    acc = {}
    if accessories:
        names = {n for n, _ in body}
        for name, tris in bs.car_triangles(key, work, models, with_accessories=True):
            if name not in names and tris:
                acc[name] = mesh_object(f'acc_{key}_{name}', tris, mats['body'])
    m = json.loads((Path(work) / 'measure.json').read_text(encoding='utf-8'))['cars'][key]
    w = m['wheels']
    for y, r in ((w['frontY'], w['tireRadius'][0]), (w['backY'], w['tireRadius'][1])):
        for sx in (-1, 1):
            bpy.ops.mesh.primitive_cylinder_add(vertices=40, radius=r, depth=0.21,
                                                location=(sx * (w['trackHalf'] + 0.01), y, w['centreZ']),
                                                rotation=(0, math.radians(90), 0))
            t = bpy.context.object
            t.data.materials.append(mats['tyre'])
            objs.append(t)
            bpy.ops.mesh.primitive_cylinder_add(vertices=40, radius=r * 0.62, depth=0.012,
                                                location=(sx * (w['trackHalf'] + 0.01 + 0.106), y, w['centreZ']),
                                                rotation=(0, math.radians(90), 0))
            hub = bpy.context.object
            hub.data.materials.append(mats['hub'])
            objs.append(hub)
    lo, hi = world_bounds(objs)
    if accessories:
        return objs, lo, hi, m, acc, half
    return objs, lo, hi, m


def car_materials():
    return {'body': flat_material('board_body', (0.56, 0.57, 0.59), 0.0, 0.45),
            'glass': flat_material('board_glass', (0.06, 0.07, 0.08), 0.0, 0.1),
            'lights': flat_material('board_lights', (0.30, 0.30, 0.32), 0.0, 0.2),
            'tyre': flat_material('board_tyre', (0.025, 0.025, 0.028), 0.0, 0.9),
            'hub': flat_material('board_hub', (0.35, 0.36, 0.38), 0.8, 0.3)}


def floor(scene, z):
    bpy.ops.mesh.primitive_plane_add(size=60, location=(0, 0, z - 0.001))
    f = bpy.context.object
    f.data.materials.append(flat_material('board_floor', (0.20, 0.205, 0.21), 0.0, 0.8))
    return f


def clear_dynamic(keep):
    for o in list(bpy.data.objects):
        if o not in keep:
            bpy.data.objects.remove(o, do_unlink=True)


def world_grey(scene):
    world = bpy.data.worlds.new('board_world')
    world.color = (0.16, 0.165, 0.17)
    scene.world = world


# --------------------------------------------------------------------------- views
def view_34(cam, lo, hi, direction, ctx, lens=50, wide=False):
    """Perspective view of the box lo..hi from `direction`; `wide` fits the box to the
    horizontal field (long thin parts), else to the vertical one (context around it)."""
    centre = (lo + hi) / 2
    radius = max((hi - lo).length / 2, 0.12)
    fov = 2 * math.atan(36 / (2 * lens)) * (1.0 if wide else TILE[1] / TILE[0])
    dist = radius * ctx / math.sin(fov / 2)
    aim(cam, centre, direction, dist, lens=lens)


def view_ortho(cam, lo, hi, which, pad=1.5, floor_z=None):
    centre = (lo + hi) / 2
    size = hi - lo
    d = ORTHO_DIRS[which]
    if which == 'left':
        w, h = size.y, size.z
    elif which in ('front', 'rear'):
        w, h = size.x, size.z
    else:
        w, h = size.x, size.y
    scale = max(w, h * TILE[0] / TILE[1]) * pad + 0.10
    aim(cam, centre, d, 30, ortho=scale)


# --------------------------------------------------------------------------- main
def main():
    args = parse()
    out = args.out
    tiles = out / 'tiles'
    tiles.mkdir(parents=True, exist_ok=True)
    vk.clear_scene()
    scene = bpy.context.scene
    setup_render(scene)
    world_grey(scene)
    cam = make_camera(scene)
    models = bs.dealer_models(args.dealer)
    mats = car_materials()
    base_objs = set(bpy.data.objects)

    if args.only == 'overview':
        use_workbench(scene)
        cars = args.cars.split(',') if args.cars else list(json.loads((args.work / 'measure.json').read_text(encoding='utf-8'))['cars'])
        rows = []
        for key in cars:
            clear_dynamic(base_objs)
            objs, lo, hi, m = car_body(key, args.work, models, mats)
            floor(scene, m['groundZ'])
            row = []
            views = [('left', None), ('rear34', (-1.0, -1.25, 0.7)), ('front34', (-1.0, 1.25, 0.45)), ('top', None)]
            for name, d in views:
                if d:
                    view_34(cam, lo, hi, d, 1.05, lens=50)
                else:
                    view_ortho(cam, lo, hi, name, pad=1.08)
                caption(scene, [f'{key}  {name}', f"{m['record']}"])
                row.append(render(scene, tiles / f'overview_{key}_{name}.png'))
            rows.append(row)
            print(f'VK_BOARD_OVERVIEW {key}', flush=True)
        stitch(rows, out / 'overview.png')
        print(f'VK_BOARD_OK out={out}')
        return

    spec = json.loads(args.spec.read_text(encoding='utf-8'))
    ids = set(args.ids.split(',')) if args.ids else None
    sparts = [p for p in spec['parts'] if not ids or p['id'] in ids]
    if args.only in ('all', 'parts'):
        parts_sheets(scene, cam, spec, sparts, args, tiles, out, base_objs)
    if args.only in ('all', 'cars'):
        car_sheets(scene, cam, spec, sparts, args, tiles, out, base_objs, models, mats)
    print(f'VK_BOARD_OK out={out}')


PART_VIEWS = {   # 3/4 view direction per group for the isolated part (from the part toward the camera)
    'spoiler': (-1.0, -1.3, 0.8), 'louver': (-1.0, -1.1, 1.2), 'lip': (-1.0, 1.3, 0.7), 'canard': (1.3, 1.0, 0.5),
    'skirt': (1.3, 0.6, 0.5), 'diffuser': (-0.8, -1.3, -0.35), 'hood': (-0.9, 1.3, 1.0),
    'roofrack': (-1.0, 1.2, 0.9), 'bullbar': (-1.0, 1.4, 0.5)}


def parts_sheets(scene, cam, spec, sparts, args, tiles, out, base_objs, per_sheet=8):
    """One row per part: each finish in a 3/4 view, then side and top orthographic views
    of the first finish with the triangle count. Sheets of `per_sheet` rows."""
    if args.cycles:
        use_cycles(scene, args.samples)
    else:
        use_workbench(scene)
    rows = []
    for sp in sparts:
        clear_dynamic(base_objs)
        pm = PartMesh(sp['id'], args.parts, spec['palette'], sp['finishes'])
        tris = pm.meta['lods']['1']['triangles']
        b = pm.meta['bounds']
        size = f"{b[1][0] - b[0][0]:.2f} x {b[1][1] - b[0][1]:.2f} x {b[1][2] - b[0][2]:.2f} m"
        row = []
        d = PART_VIEWS.get(sp['kind'], (-1, 1.2, 0.7))
        for finish in sp['finishes']:
            obj = pm.instance(finish, f'{sp["id"]}_{finish}')
            lo, hi = world_bounds([obj])
            view_34(cam, lo, hi, d, 1.08, lens=50, wide=True)
            caption(scene, [f"{sp['id']}  {finish}", f"{sp.get('label', '')}  [{sp['kind']}]"])
            row.append(render(scene, tiles / f"part_{sp['id']}_{finish}.png"))
            bpy.data.objects.remove(obj, do_unlink=True)
        obj = pm.instance(next(iter(sp['finishes'])), f'{sp["id"]}_ortho')
        lo, hi = world_bounds([obj])
        for which in ('left', 'top'):
            view_ortho(cam, lo, hi, which, pad=1.15)
            caption(scene, [f"{sp['id']}  {which}", f'{tris} tris  {size}'])
            row.append(render(scene, tiles / f"part_{sp['id']}_{which}.png"))
        rows.append(row)
        print(f"VK_BOARD_PART {sp['id']} tris={tris}", flush=True)
    for i in range(0, len(rows), per_sheet):
        stitch(rows[i:i + per_sheet], out / f'parts_{i // per_sheet + 1:02d}.png')


# Where each group sits on the car, as fractions of the car's bounding box (x, y, z from
# lo to hi): the target of an excluded part's tile.
ZONE_AT = {'spoiler': (0.5, 0.12, 0.8), 'louver': (0.5, 0.3, 0.9), 'lip': (0.5, 0.95, 0.1), 'canard': (0.1, 0.9, 0.3),
           'skirt': (0.0, 0.5, 0.15), 'diffuser': (0.5, 0.04, 0.15), 'hood': (0.5, 0.8, 0.7),
           'roofrack': (0.5, 0.5, 1.0), 'bullbar': (0.5, 0.97, 0.35)}
GROUP_ORDER = ('spoiler', 'louver', 'lip', 'canard', 'skirt', 'diffuser', 'hood', 'roofrack', 'bullbar')


def wrap(text, n=88):
    lines, cur = [], ''
    for wd in str(text).split():
        if cur and len(cur) + len(wd) + 1 > n:
            lines.append(cur)
            cur = wd
        else:
            cur = (cur + ' ' + wd).strip()
    return lines + ([cur] if cur else [])


def fit_caption(pid, label, finish, ev, fit):
    c, a = ev.get('contact', {}), ev.get('audit', {})
    nums = [f"float {c.get('float', 0) * 100:.1f} cm", f"sink {c.get('sink', 0) * 100:.1f} cm",
            f"cut {a.get('cut', 0) * 100:.1f} cm", f"ground {a.get('ground', 0) * 100:.0f} cm"]
    if a.get('hiddenCut'):
        nums.append(f"hidden cut {a['hiddenCut'] * 100:.1f} cm")
    pose = []
    if fit.get('rotation'):
        pose.append(f"pitch {fit['rotation'][0]:+.1f}")
    if fit.get('scale'):
        pose.append('scale ' + ' '.join(f'{v:.2f}' for v in fit['scale']))
    if ev.get('lid'):
        pose.append(f"rides {ev['lid']['slot']}")
    if fit.get('hide'):
        pose.append('hides ' + ', '.join(fit['hide'][:2]))
    lines = [f'{pid}  ({label}, {finish})', '  '.join(nums)]
    if pose:
        lines.append('  '.join(pose))
    for n in ev.get('notes', [])[:3]:
        lines += wrap(n)[:2]
    return lines


def car_sheets(scene, cam, spec, sparts, args, tiles, out, base_objs, models, mats, per_row=4):
    """Per car: two build tiles (rear and front 3/4, one part per group), then for every
    part a 3/4 view framed on it and an orthographic contact view, both captioned with the
    fit evidence; an excluded part gets one tile of its zone with the reason."""
    use_workbench(scene)
    fit = json.loads(args.fit.read_text(encoding='utf-8'))
    pms = {sp['id']: PartMesh(sp['id'], args.parts, spec['palette'], sp['finishes']) for sp in sparts}
    base_objs = set(bpy.data.objects)
    cars = args.cars.split(',') if args.cars else list(fit['cars'])
    for key in cars:
        info = fit['cars'][key]
        rec = info['record']
        clear_dynamic(base_objs)
        objs, lo, hi, m, acc, half = car_body(key, args.work, models, mats, accessories=True)
        fl = floor(scene, m['groundZ'])
        keep = base_objs | set(objs) | set(acc.values()) | set(half) | {fl}
        shell = [o for o in objs if o.name.startswith('car_')]

        def put(sp, finish=None):
            entry = fit['parts'][sp['id']]
            f = entry['fit'].get(rec)
            if f is None:
                return None
            ev = entry['evidence'][rec]
            finish = finish or next(iter(sp['finishes']))
            obj = pms[sp['id']].instance(finish, f"fit_{sp['id']}")
            place(obj, ev['root']['offset'], f.get('scale', (1, 1, 1)), f.get('rotation', (0, 0, 0)))
            for name in f.get('hide', []):
                if name in acc:
                    acc[name].hide_render = True
            return obj, f, ev, finish

        def reset():
            clear_dynamic(keep)
            for o in acc.values():
                o.hide_render = False

        cells = []
        reset()
        build = []
        for g in GROUP_ORDER:
            for sp in sparts:
                if sp['kind'] == g and put(sp):
                    build.append(sp['id'])
                    break
        for name, d in (('rear', (-1.0, -1.25, 0.6)), ('front', (-1.0, 1.25, 0.45))):
            view_34(cam, lo, hi, d, 1.0, lens=50)
            caption(scene, [f"{key}  {info['label']}  ({info['body']})", f'{name} 3/4, the first fit of each group:',
                            ', '.join(build[:5]), ', '.join(build[5:])])
            cells.append(render(scene, tiles / f'car_{key}_build_{name}.png'))
        for sp in sparts:
            pid, g = sp['id'], sp['kind']
            z = ZONES.get(g, ZONES['spoiler'])
            reset()
            placed = put(sp)
            if placed is None:
                why = fit['parts'][pid]['excluded'].get(rec, 'not in the fit table')
                fx, fy, fz = ZONE_AT.get(g, (0.5, 0.5, 0.5))
                t = Vector((lo.x + fx * (hi.x - lo.x), lo.y + fy * (hi.y - lo.y), lo.z + fz * (hi.z - lo.z)))
                r = Vector((0.5, 0.5, 0.5))
                view_34(cam, t - r, t + r, z['dir'], 1.6)
                caption(scene, [f'{pid}  EXCLUDED on {key}', *wrap(why)[:5]])
                cells.append(render(scene, tiles / f'car_{key}_{pid}_x.png'))
                cells.append(None)
                continue
            obj, f, ev, finish = placed
            plo, phi = world_bounds([obj])
            view_34(cam, plo, phi, z['dir'], z['ctx'], lens=50)
            cap = fit_caption(pid, sp.get('label', pid), finish, ev, f)
            caption(scene, cap)
            cells.append(render(scene, tiles / f'car_{key}_{pid}_34.png'))
            # Contact view: orthographic, the part and 25 cm of body around it; a centre-line
            # part sees the body cut at x = 0.
            pad = Vector((0.25, 0.25, 0.25))
            section = g in SECTION_GROUPS and z['ortho'] == 'left'
            for o in shell:
                o.hide_render = section
            for o in half:
                o.hide_render = not section
            view_ortho(cam, plo - pad, phi + pad, z['ortho'], pad=1.15)
            caption(scene, [f"{pid}  {z['ortho']} (ortho{', body cut at x = 0' if section else ''})", cap[1]])
            cells.append(render(scene, tiles / f"car_{key}_{pid}_{z['ortho']}.png"))
            for o in shell:
                o.hide_render = False
            for o in half:
                o.hide_render = True
        reset()
        rows = [cells[i:i + 2 * per_row] for i in range(0, len(cells), 2 * per_row)]
        stitch(rows, out / f'car_{key}.png')
        print(f'VK_BOARD_CAR {key} tiles={len([c for c in cells if c])}', flush=True)


if __name__ == '__main__':
    main()
