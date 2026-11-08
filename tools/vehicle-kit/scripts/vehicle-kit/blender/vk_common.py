"""Shared helpers for the Open77 vehicle-kit Blender scripts.

Runs inside Blender 4.5 in background mode (bpy). Every part is ORIGINAL geometry
built from code: nothing here reads, copies or traces a game asset.

Axis convention (measured on vanilla vehicle meshes, see ../README.md):
  Blender/engine space, metres, Z up, X = vehicle right, Y = vehicle forward.
  glTF export converts to Y-up and WolvenKit's import converts back, so the
  Blender coordinates are the coordinates written into the cooked .mesh.

Submesh contract with WolvenKit's glb import onto a template .mesh:
  one Blender object per (material slot, LOD), named submesh_NN_LOD_L, numbered
  in creation order across LODs. A joined multi-material object would export one
  node with several primitives, and WolvenKit 8.x then keeps only the first.
"""
import argparse
import json
import math
import sys
from pathlib import Path

import bpy
import bmesh

TAU = math.tau


def script_args(parser: argparse.ArgumentParser):
    """Parse the arguments placed after '--' on the Blender command line."""
    argv = sys.argv[sys.argv.index('--') + 1:] if '--' in sys.argv else []
    return parser.parse_args(argv)


def base_parser(description: str) -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(description=description)
    p.add_argument('--part', required=True, type=Path, help='JSON file holding ONE part entry of the spec')
    p.add_argument('--out', required=True, type=Path, help='output folder for <id>.glb, <id>.part.json, <id>.blend')
    p.add_argument('--exporter', choices=('auto', 'cp77', 'gltf'), default='auto',
                   help='cp77 = Cyberpunk add-on exporter (validates the mesh), gltf = stock exporter')
    p.add_argument('--no-blend', action='store_true', help='skip saving the editable .blend')
    return p


def load_part(path: Path) -> dict:
    with path.open('r', encoding='utf-8') as f:
        part = json.load(f)
    for key in ('id', 'kind'):
        if key not in part:
            raise SystemExit(f'part spec is missing "{key}"')
    return part


def clear_scene():
    """Empty the factory scene without read_factory_settings (that would unregister add-ons)."""
    for obj in list(bpy.data.objects):
        bpy.data.objects.remove(obj, do_unlink=True)
    for coll in (bpy.data.meshes, bpy.data.materials, bpy.data.cameras, bpy.data.lights, bpy.data.images):
        for block in list(coll):
            if block.users == 0:
                coll.remove(block)


def enable_cp77_addon():
    """Enable the Cyberpunk IO Suite for this process only. Returns its version or None.

    default_set=False / persistent=False: nothing is written to the user's Blender
    preferences. The add-on is looked up through BLENDER_USER_SCRIPTS, which the
    build script points at a dedicated folder.
    """
    try:
        import addon_utils
    except ImportError:
        return None
    name = 'i_scene_cp77_gltf'
    if not any(m.__name__ == name for m in addon_utils.modules()):
        return None
    errors = []
    mod = addon_utils.enable(name, default_set=False, persistent=False, handle_error=errors.append)
    if mod is None or errors:
        print(f'VK_ADDON_ENABLE_FAILED {name}: {errors!r}')
        return None
    return '.'.join(map(str, getattr(mod, 'bl_info', {}).get('version', ())))


# --------------------------------------------------------------------------- geometry
class MeshBuilder:
    """Accumulates vertices, faces and per-face-corner UVs, then makes one object."""

    def __init__(self):
        self.verts = []
        self.faces = []
        self.uvs = []          # one list of (u, v) per face, same length as the face

    def vert(self, co):
        self.verts.append(tuple(float(c) for c in co))
        return len(self.verts) - 1

    def face(self, indices, uv):
        if len(set(indices)) < 3:
            return
        self.faces.append(tuple(indices))
        self.uvs.append(tuple(uv))

    def extend(self, other: 'MeshBuilder'):
        base = len(self.verts)
        self.verts.extend(other.verts)
        for f, uv in zip(other.faces, other.uvs):
            self.faces.append(tuple(i + base for i in f))
            self.uvs.append(uv)

    # A solid of revolution around the X axis (the wheel's spin axis).
    def lathe(self, profile, segments, closed=False, center=(0.0, 0.0), v_scale=1.0, u_offset=0.0):
        """profile: [(x, r), ...]. r == 0 points collapse to one axis vertex (fan), so the
        result has no zero-area triangles. closed=True joins the last point to the first."""
        cy, cz = center
        pts = list(profile) + ([profile[0]] if closed else [])
        lengths = [0.0]
        for (x0, r0), (x1, r1) in zip(pts, pts[1:]):
            lengths.append(lengths[-1] + math.hypot(x1 - x0, r1 - r0))
        total = lengths[-1] or 1.0
        rows = []
        for (x, r) in profile:
            if r <= 1e-9:
                idx = self.vert((x, cy, cz))
                rows.append([idx] * segments)
            else:
                rows.append([self.vert((x, cy + r * math.cos(TAU * j / segments),
                                        cz + r * math.sin(TAU * j / segments))) for j in range(segments)])
        if closed:
            rows.append(rows[0])
        for i in range(len(rows) - 1):
            v0 = lengths[i] / total * v_scale
            v1 = lengths[i + 1] / total * v_scale
            a, b = rows[i], rows[i + 1]
            for j in range(segments):
                k = (j + 1) % segments
                u0 = u_offset + j / segments
                u1 = u_offset + (j + 1) / segments
                quad = [a[j], a[k], b[k], b[j]]
                uv = [(u0, v0), (u1, v0), (u1, v1), (u0, v1)]
                # Collapse fans at the axis into triangles.
                keep = [(q, t) for n, (q, t) in enumerate(zip(quad, uv)) if q not in quad[:n]]
                self.face([q for q, _ in keep], [t for _, t in keep])
        return self

    def sweep(self, sections, closed_section=True, cap=True):
        """sections: list of rings (each a list of 3D points, same count). Builds the side
        faces between consecutive rings, optionally capping both ends."""
        rings = [[self.vert(p) for p in ring] for ring in sections]
        n = len(rings[0])
        for i in range(len(rings) - 1):
            v0, v1 = i / (len(rings) - 1), (i + 1) / (len(rings) - 1)
            span = n if closed_section else n - 1
            for j in range(span):
                k = (j + 1) % n
                self.face([rings[i][j], rings[i][k], rings[i + 1][k], rings[i + 1][j]],
                          [(j / n, v0), ((j + 1) / n, v0), ((j + 1) / n, v1), (j / n, v1)])
        if cap and closed_section:
            for ring, flip in ((rings[0], True), (rings[-1], False)):
                idx = list(reversed(ring)) if flip else list(ring)
                uv = [(0.5 + 0.5 * math.cos(TAU * j / n), 0.5 + 0.5 * math.sin(TAU * j / n)) for j in range(n)]
                self.face(idx, list(reversed(uv)) if flip else uv)
        return self


# Two color attributes because the import layout has a PS_Color stream: without a
# COLOR_0 WolvenKit fills it with 00000000, and metal_base.remt multiplies by vertex
# color and alpha, so the part draws nothing in the main pass (it still casts
# shadows). Measured in game in E0.9; the proven Light RP props write COLOR_0 and
# COLOR_1 = (1, 1, 1, 1) the same way.
VERTEX_COLORS = ('Col', 'Col1')


def add_white_vertex_colors(me):
    for name in VERTEX_COLORS:
        attr = me.color_attributes.new(name=name, type='BYTE_COLOR', domain='CORNER')
        attr.data.foreach_set('color', [1.0] * (4 * len(me.loops)))
    me.color_attributes.active_color = me.color_attributes[VERTEX_COLORS[0]]
    me.color_attributes.render_color_index = 0


# Vertex-color options for Blender 4.x's glTF exporter. The default 'MATERIAL' only
# exports a color attribute that a material node reads, and the parts export with
# materials NONE, so nothing would be written.
GLTF_COLOR_OPTIONS = {'export_vertex_color': 'ACTIVE', 'export_all_vertex_colors': True}


def _patch_cp77_color_options():
    """The add-on passes vertex-color options only for Blender 3.x. Extend its mesh
    options for this process (nothing is written to the add-on or the preferences)."""
    from i_scene_cp77_gltf.exporters import glb_export
    original = getattr(glb_export.cp77_mesh_options, '__wrapped__', glb_export.cp77_mesh_options)

    def cp77_mesh_options():
        options = original()
        options.update(GLTF_COLOR_OPTIONS)
        return options
    cp77_mesh_options.__wrapped__ = original
    glb_export.cp77_mesh_options = cp77_mesh_options


def check_glb_colors(path: Path, expected: int):
    """Every primitive must carry COLOR_0..COLOR_{n-1} with every component at 1.0."""
    import struct
    data = path.read_bytes()
    length = struct.unpack_from('<I', data, 12)[0]
    doc = json.loads(data[20:20 + length])
    offset = 20 + length
    bin_len = struct.unpack_from('<I', data, offset)[0]
    blob = data[offset + 8:offset + 8 + bin_len]
    formats = {5126: ('f', 4, 1.0), 5121: ('B', 1, 255.0), 5123: ('H', 2, 65535.0)}
    checked = 0
    for mesh in doc['meshes']:
        for prim in mesh['primitives']:
            for i in range(expected):
                key = f'COLOR_{i}'
                if key not in prim['attributes']:
                    raise SystemExit(f"VK_COLOR_FAILED {path.name}: {mesh['name']} has no {key}")
                acc = doc['accessors'][prim['attributes'][key]]
                view = doc['bufferViews'][acc['bufferView']]
                code, size, scale = formats[acc['componentType']]
                comps = {'VEC3': 3, 'VEC4': 4}[acc['type']]
                stride = view.get('byteStride', size * comps)
                start = view.get('byteOffset', 0) + acc.get('byteOffset', 0)
                for v in range(acc['count']):
                    values = struct.unpack_from(f'<{comps}{code}', blob, start + v * stride)
                    if any(abs(x / scale - 1.0) > 1e-3 for x in values):
                        raise SystemExit(f"VK_COLOR_FAILED {path.name}: {mesh['name']} {key} vertex {v} = {values}")
                checked += acc['count']
    return checked


def make_object(name: str, builder: MeshBuilder, material, smooth_angle_deg=40.0, recalc_normals=True):
    """Create a triangulated object with one UV layer and one material slot."""
    me = bpy.data.meshes.new(name)
    me.from_pydata(builder.verts, [], builder.faces)
    uv_layer = me.uv_layers.new(name='UVMap')
    loop = 0
    for face_uv in builder.uvs:
        for u, v in face_uv:
            uv_layer.data[loop].uv = (u, v)
            loop += 1
    me.validate(clean_customdata=False)
    bm = bmesh.new()
    bm.from_mesh(me)
    bmesh.ops.remove_doubles(bm, verts=bm.verts, dist=1e-6)
    # Drop faces that collapsed to zero area: the add-on refuses degenerate geometry
    # and the engine would waste index buffer on them.
    bad = [f for f in bm.faces if f.calc_area() < 1e-10]
    if bad:
        bmesh.ops.delete(bm, geom=bad, context='FACES_ONLY')
    if recalc_normals:
        bmesh.ops.recalc_face_normals(bm, faces=bm.faces)
    bmesh.ops.triangulate(bm, faces=bm.faces, quad_method='BEAUTY', ngon_method='BEAUTY')
    bad = [f for f in bm.faces if f.calc_area() < 1e-10]
    if bad:
        bmesh.ops.delete(bm, geom=bad, context='FACES_ONLY')
    loose = [v for v in bm.verts if not v.link_faces]
    if loose:
        bmesh.ops.delete(bm, geom=loose, context='VERTS')
    bm.to_mesh(me)
    bm.free()
    me.materials.append(material)
    for poly in me.polygons:
        poly.use_smooth = True
    me.set_sharp_from_angle(angle=math.radians(smooth_angle_deg))
    add_white_vertex_colors(me)
    obj = bpy.data.objects.new(name, me)
    bpy.context.scene.collection.objects.link(obj)
    return obj


def preview_material(name: str, color, metallic: float, roughness: float):
    """A Blender-side stand-in so the .blend and the glb carry the slot name. The cooked
    game material is generated later from the spec palette, not from this node tree."""
    mat = bpy.data.materials.get(name) or bpy.data.materials.new(name)
    mat.use_nodes = True
    mat.diffuse_color = (*color, 1.0)
    bsdf = mat.node_tree.nodes.get('Principled BSDF')
    bsdf.inputs['Base Color'].default_value = (*color, 1.0)
    bsdf.inputs['Metallic'].default_value = metallic
    bsdf.inputs['Roughness'].default_value = roughness
    return mat


# --------------------------------------------------------------------------- export
class PartExporter:
    """Collects submesh objects, names them for WolvenKit, exports glb + metadata."""

    def __init__(self, part: dict, out: Path):
        self.part = part
        self.out = out
        self.objects = []      # (obj, lod, slot)

    def add(self, builder: MeshBuilder, lod: int, slot: str, material, **kw):
        index = len(self.objects)
        name = f'submesh_{index:02d}_LOD_{lod}'
        obj = make_object(name, builder, material, **kw)
        self.objects.append((obj, lod, slot))
        return obj

    @staticmethod
    def _bounds(objs):
        xs, ys, zs = [], [], []
        for obj in objs:
            for v in obj.data.vertices:
                xs.append(v.co.x); ys.append(v.co.y); zs.append(v.co.z)
        return [[round(min(xs), 6), round(min(ys), 6), round(min(zs), 6)],
                [round(max(xs), 6), round(max(ys), 6), round(max(zs), 6)]]

    @staticmethod
    def _projected_area(objs):
        """Area projected on each axis, sum of |normal[i]| * area over the triangles.

        The cook writes it as the mesh's surfaceAreaPerAxis, computed the way the Light
        RP board-game props (proven visible) compute theirs, instead of leaving the
        template's (1, 1, 1). Objects carry an identity transform, as in _bounds.
        """
        total = [0.0, 0.0, 0.0]
        for obj in objs:
            for poly in obj.data.polygons:
                for i in range(3):
                    total[i] += abs(poly.normal[i]) * poly.area
        return [round(v, 6) for v in total]

    def export(self, exporter: str, addon_version, save_blend: bool, extra: dict):
        self.out.mkdir(parents=True, exist_ok=True)
        pid = self.part['id']
        glb = self.out / f'{pid}.glb'
        objs = [o for o, _, _ in self.objects]
        for obj in bpy.context.scene.objects:
            obj.select_set(obj in objs)
        bpy.context.view_layer.objects.active = objs[0]
        used = None
        if exporter in ('auto', 'cp77') and addon_version:
            # is_skinned=False: a static prop has no armature. try_fix=False: a
            # validation failure must stop the build, not be silently patched.
            _patch_cp77_color_options()
            bpy.ops.export_scene.cp77_glb(filepath=str(glb), limit_selected=True, is_skinned=False,
                                          try_fix=False, export_poses=False, apply_transform=True,
                                          apply_modifiers=True)
            used = f'cp77_glb (Cyberpunk IO Suite {addon_version})'
        elif exporter == 'cp77':
            raise SystemExit('--exporter cp77 requested but the Cyberpunk add-on is not available')
        else:
            bpy.ops.export_scene.gltf(filepath=str(glb), export_format='GLB', use_selection=True,
                                      export_texcoords=True, export_normals=True, export_tangents=True,
                                      export_materials='EXPORT', export_image_format='NONE',
                                      export_yup=True, export_animations=False, export_skins=False,
                                      export_morph=False, export_cameras=False, export_lights=False,
                                      **GLTF_COLOR_OPTIONS)
            used = 'gltf (Blender stock exporter)'
        if not glb.exists():
            raise SystemExit(f'export produced no file: {glb}')
        colored = check_glb_colors(glb, len(VERTEX_COLORS))
        lods = sorted({lod for _, lod, _ in self.objects})
        meta = {
            'schema': 'open77.vehicle-kit.part/1',
            'id': pid,
            'kind': self.part['kind'],
            'params': self.part.get('params', {}),
            'generator': {'blender': bpy.app.version_string, 'exporter': used},
            'vertexColors': {'attributes': [f'COLOR_{i}' for i in range(len(VERTEX_COLORS))],
                             'rgba': [1, 1, 1, 1], 'verticesChecked': colored},
            'submeshes': [{'name': o.name, 'lod': lod, 'slot': slot,
                           'triangles': len(o.data.polygons), 'vertices': len(o.data.vertices)}
                          for o, lod, slot in self.objects],
            'slots': sorted({slot for _, _, slot in self.objects}),
            'lods': {str(l): {'triangles': sum(len(o.data.polygons) for o, lod, _ in self.objects if lod == l),
                              'bounds': self._bounds([o for o, lod, _ in self.objects if lod == l]),
                              'surfaceAreaPerAxis': self._projected_area([o for o, lod, _ in self.objects if lod == l])}
                     for l in lods},
        }
        meta['bounds'] = meta['lods'][str(lods[0])]['bounds']
        meta.update(extra)
        with (self.out / f'{pid}.part.json').open('w', encoding='utf-8', newline='\n') as f:
            json.dump(meta, f, indent=2)
        if save_blend:
            bpy.ops.wm.save_as_mainfile(filepath=str(self.out / f'{pid}.blend'), check_existing=False)
        print(f"VK_PART_OK {pid} exporter={used} lods={lods} "
              f"tris={[meta['lods'][str(l)]['triangles'] for l in lods]} bounds={meta['bounds']} "
              f"colors=COLOR_0..{len(VERTEX_COLORS) - 1}@1.0x{colored}")
        return meta
