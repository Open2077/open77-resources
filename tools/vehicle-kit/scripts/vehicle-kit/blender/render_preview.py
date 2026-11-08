"""Owner-review renders of a vehicle-kit part (Blender 4.5, background, Cycles CPU).

    blender --background --factory-startup --python render_preview.py -- \
        --part <part spec .json> --meta <id>.part.json --glb <id>.glb --out <dir> [--views 4]

Writes, per finish: <id>_<finish>_34.png (3/4 hero view) and, with --views 4,
<id>_<finish>_sheet.png (2x2: 3/4, face-on, profile, high rear 3/4).

This is an art review, not game evidence: the materials are Blender stand-ins
built from the same palette values as the cooked metal_base.remt instances. For
rims a plain preview-only tyre (never exported) gives the owner the proportions.
"""
import argparse
import math
import sys
from pathlib import Path

import bpy
import numpy as np
from mathutils import Vector

sys.path.insert(0, str(Path(__file__).resolve().parent))
import vk_common as vk  # noqa: E402


def parse():
    p = argparse.ArgumentParser()
    p.add_argument('--part', required=True, type=Path)
    p.add_argument('--meta', required=True, type=Path)
    p.add_argument('--glb', required=True, type=Path)
    p.add_argument('--out', required=True, type=Path)
    p.add_argument('--views', type=int, choices=(1, 4), default=4)
    p.add_argument('--samples', type=int, default=48)
    p.add_argument('--size', default='1280x960')
    p.add_argument('--no-tire', action='store_true')
    p.add_argument('--finish', default='', help='render only this finish (default: all)')
    return vk.script_args(p)


def studio_world(scene):
    world = bpy.data.worlds.new('vk_studio')
    scene.world = world
    world.use_nodes = True
    nt = world.node_tree
    nt.nodes.clear()
    coord = nt.nodes.new('ShaderNodeTexCoord')
    sep = nt.nodes.new('ShaderNodeSeparateXYZ')
    ramp = nt.nodes.new('ShaderNodeValToRGB')
    bg = nt.nodes.new('ShaderNodeBackground')
    out = nt.nodes.new('ShaderNodeOutputWorld')
    nt.links.new(coord.outputs['Generated'], sep.inputs['Vector'])
    nt.links.new(sep.outputs['Z'], ramp.inputs['Fac'])
    ramp.color_ramp.elements[0].position = 0.42
    ramp.color_ramp.elements[0].color = (0.10, 0.105, 0.11, 1)
    ramp.color_ramp.elements[1].position = 0.75
    ramp.color_ramp.elements[1].color = (0.85, 0.86, 0.88, 1)
    nt.links.new(ramp.outputs['Color'], bg.inputs['Color'])
    bg.inputs['Strength'].default_value = 0.6
    # Camera rays see a flat neutral grey; reflections and lighting keep the gradient.
    flat = nt.nodes.new('ShaderNodeBackground')
    flat.inputs['Color'].default_value = (0.32, 0.325, 0.33, 1)
    flat.inputs['Strength'].default_value = 1.0
    path = nt.nodes.new('ShaderNodeLightPath')
    mix = nt.nodes.new('ShaderNodeMixShader')
    nt.links.new(path.outputs['Is Camera Ray'], mix.inputs['Fac'])
    nt.links.new(bg.outputs['Background'], mix.inputs[1])
    nt.links.new(flat.outputs['Background'], mix.inputs[2])
    nt.links.new(mix.outputs['Shader'], out.inputs['Surface'])


def area_light(name, location, target, energy, size):
    light = bpy.data.lights.new(name, 'AREA')
    light.energy = energy
    light.size = size
    obj = bpy.data.objects.new(name, light)
    bpy.context.scene.collection.objects.link(obj)
    obj.location = location
    obj.rotation_euler = (Vector(target) - Vector(location)).to_track_quat('-Z', 'Y').to_euler()
    return obj


def material(name, color, metallic, roughness):
    return vk.preview_material(name, tuple(color), metallic, roughness)


def preview_tire(meta, mat):
    """Preview-only tyre: an original torus-like lathe sized from the rim parameters."""
    m = meta.get('mount', {})
    r, fx, w = m.get('radius', 0.2785), m.get('face_x', -0.208), m.get('width', 0.305)
    outer = r * 1.338
    x0, x1 = fx + 0.012, fx + w - 0.012
    prof = [(x0, r - 0.012), (x0 - 0.004, r + 0.03), (x0 + 0.004, outer - 0.03), (x0 + 0.03, outer),
            (x1 - 0.03, outer), (x1 - 0.004, outer - 0.03), (x1 + 0.004, r + 0.03), (x1, r - 0.012)]
    b = vk.MeshBuilder().lathe(prof, 96, closed=True)
    return vk.make_object('preview_tire', b, mat, smooth_angle_deg=60), outer


def stitch(paths, out_path, cols=2):
    imgs = [bpy.data.images.load(str(p), check_existing=False) for p in paths]
    w, h = imgs[0].size
    rows = math.ceil(len(imgs) / cols)
    sheet = np.ones((rows * h, cols * w, 4), dtype=np.float32)
    for i, img in enumerate(imgs):
        px = np.array(img.pixels[:], dtype=np.float32).reshape(h, w, 4)
        r, c = divmod(i, cols)
        # Blender pixel rows start at the bottom: row 0 of the sheet is its bottom row.
        y0 = (rows - 1 - r) * h
        sheet[y0:y0 + h, c * w:(c + 1) * w] = px
    out = bpy.data.images.new('vk_sheet', cols * w, rows * h, alpha=True)
    out.pixels.foreach_set(sheet.ravel())
    out.filepath_raw = str(out_path)
    out.file_format = 'PNG'
    out.save()


def main():
    args = parse()
    import json
    part = json.loads(args.part.read_text(encoding='utf-8'))
    meta = json.loads(args.meta.read_text(encoding='utf-8'))
    palette = part.get('palette', {})
    finishes = part.get('finishes', {})
    if not finishes:
        raise SystemExit('part has no finishes to preview')
    if args.finish:
        finishes = {args.finish: finishes[args.finish]}
    vk.clear_scene()
    scene = bpy.context.scene
    bpy.ops.import_scene.gltf(filepath=str(args.glb))
    slot_of = {s['name']: s['slot'] for s in meta['submeshes']}
    lod1 = [o for o in scene.objects if o.type == 'MESH' and o.name in slot_of and o.name.endswith('_LOD_1')]
    for o in [o for o in scene.objects if o not in lod1]:
        bpy.data.objects.remove(o, do_unlink=True)
    if not lod1:
        raise SystemExit('no LOD_1 submesh found in the glb')

    pts = [o.matrix_world @ v.co for o in lod1 for v in o.data.vertices]
    lo = Vector((min(p.x for p in pts), min(p.y for p in pts), min(p.z for p in pts)))
    hi = Vector((max(p.x for p in pts), max(p.y for p in pts), max(p.z for p in pts)))
    floor_z = lo.z
    if meta['kind'] == 'rim' and not args.no_tire:
        _, outer = preview_tire(meta, material('preview_tire', (0.018, 0.018, 0.02), 0.0, 0.85))
        lo = Vector((lo.x, -outer, -outer)); hi = Vector((hi.x, outer, outer))
        floor_z = -outer
    center = (lo + hi) / 2
    radius = (hi - lo).length / 2

    bpy.ops.mesh.primitive_plane_add(size=radius * 40, location=(center.x, center.y, floor_z - 0.001))
    bpy.context.object.data.materials.append(material('preview_floor', (0.30, 0.305, 0.31), 0.0, 0.7))
    studio_world(scene)
    k = radius * 6
    # Energy scales with distance squared so every part size gets the same exposure.
    e = (k * k) * 9.0
    area_light('key', center + Vector((-1.0, -0.8, 1.1)) * k, center, e * 1.0, radius * 3)
    area_light('fill', center + Vector((0.6, -1.2, 0.5)) * k, center, e * 0.35, radius * 4)
    area_light('rim', center + Vector((0.9, 1.0, 0.9)) * k, center, e * 0.6, radius * 2)

    cam_data = bpy.data.cameras.new('vk_cam')
    cam_data.lens = 70
    cam = bpy.data.objects.new('vk_cam', cam_data)
    scene.collection.objects.link(cam)
    scene.camera = cam
    fov = 2 * math.atan(cam_data.sensor_width / (2 * cam_data.lens))
    dist = radius / math.sin(fov / 2) * 1.12

    width, height = (int(v) for v in args.size.lower().split('x'))
    scene.render.engine = 'CYCLES'
    scene.cycles.device = 'CPU'
    scene.cycles.samples = args.samples
    scene.cycles.use_denoising = True
    scene.render.resolution_x, scene.render.resolution_y = width, height
    scene.render.resolution_percentage = 100
    scene.render.image_settings.file_format = 'PNG'
    scene.render.image_settings.color_mode = 'RGBA'
    scene.view_settings.view_transform = 'AgX'

    # Hero direction: the side an owner looks at. Rims face -X (outboard); a rear
    # spoiler is judged from behind the car (-Y) and slightly above.
    hero = Vector((-1, 0, 0)) if meta['kind'] == 'rim' else Vector((0, -1, 0))
    base_az = math.atan2(hero.y, hero.x)
    views = [('34', -38, 16), ('face', 0, 4), ('profile', 90, 8), ('rear34', 150, 42)]
    args.out.mkdir(parents=True, exist_ok=True)
    pid = meta['id']
    for finish, slots in finishes.items():
        for o in lod1:
            slot = slot_of[o.name]
            entry = palette[slots[slot]]
            mat = material(f'{finish}:{slot}', entry['color'], entry['metalness'], entry['roughness'])
            o.data.materials.clear()
            o.data.materials.append(mat)
        shots = []
        for name, az, el in (views if args.views == 4 else views[:1]):
            a = base_az + math.radians(az)
            e = math.radians(el)
            cam.location = center + Vector((math.cos(a) * math.cos(e), math.sin(a) * math.cos(e), math.sin(e))) * dist
            cam.rotation_euler = (center - cam.location).to_track_quat('-Z', 'Y').to_euler()
            path = args.out / f'{pid}_{finish}_{name}.png'
            scene.render.filepath = str(path)
            bpy.ops.render.render(write_still=True)
            shots.append(path)
        if args.views == 4:
            stitch(shots, args.out / f'{pid}_{finish}_sheet.png')
        print(f'VK_PREVIEW_OK {pid} finish={finish} files={[p.name for p in shots]}')


if __name__ == '__main__':
    main()
