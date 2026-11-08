"""Native cook of the livery pack: WolvenKit JSON in, WolvenKit JSON + TweakXL YAML out.

    python lv_cook.py xbm-setup <cook.json>   patch the setups of the imported textures (templates for --keep)
    python lv_cook.py prepare   <cook.json>   meshes, decal entities, mlsetups, YAML, Lua tables, package.json
    python lv_cook.py validate  <cook.json>   serialize round trip + D6 reference check + textures

Everything written lives under the pack prefix open77\\assets\\<resource>\\<rev12>\\. The
game supplies only REFERENCES by depot path, all listed in ALLOWED_REFERENCES (the decal
material, the model's own masks, mltemplates and microblends) and, as never-shipped
templates, the container of the imported decal meshes and the reference paint stacks
whose layer roles the generated .mlsetup files follow.

mlsetup rule (per multilayer of the model's reference template, lv_plan.py), from the
layer roles lv_composite.py roles measured on the visible body against the factory TwinTone
generic mask (layer-roles.json):
  paint   (layer 0, or a layer showing at
           least half on the factory-painted body) -> livery primary paint (finish mltemplate,
                                                      nearest colour of its own palette); layer 0
                                                      at opacity 1, the others keep theirs
  accent  (a paint layer showing at least half on
           the factory secondary region)            -> the livery secondary when the design sets
                                                      "twoTone": true, the primary otherwise
  grime   (dust, dirt, rust, ...)                   -> opacity 0: a livery leaves the shop clean
  trim    (everything else: sills, lower bumpers,
           rubber, chrome, inner arches)            -> the reference layer as it is (paths and
                                                      palette keys only: no texture or mesh data)
  a multilayer painting only wheels                 -> trim and grime only
Until 2026-11-06 a layer whose material or colour differed between the vanilla paint jobs
became the secondary colour: on the Hella that recoloured the black plastic of the sills and
lower bumpers (layer 9, a quarter of the visible body): the white sills of the racing design.

Decal material: enableMask = 1, and the cut-out in both places the vanilla stickers under
stickers.mi carry one, so it holds whichever the shader reads:
  - the diffuse alpha: the full-colour atlases (decals_combatcab_checker_d01,
    decals_6thstreet_d01) are RGBA TCM_QualityColor (BC7) with no MaskTexture;
  - MaskTexture (TCM_QualityR, BC4): the graffiti stickers set one, always with enableMask = 1.
The 66ea08e0cd1f pack shipped an opaque BC1 diffuse plus a BC4 MaskTexture with
enableMask = 0, a combination no vanilla sticker uses, and the game drew the bled atlas,
black outside the artwork, over every decal quad.
"""
from __future__ import annotations

import base64
import copy
import hashlib
import json
import math
import re
import struct
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from lv_common import (BS, MAX_DECALS_PER_TEMPLATE, cname, cv, depot_file, flat_name, hex_rgb, linear_to_srgb, read_json,  # noqa: E402
                       resource, srgb_to_linear, write_json)

STICKERS_MI = 'base\\vehicles\\common\\materials\\stickers.mi'
FLAT_NORMAL = 'engine\\textures\\editor\\normal.xbm'
MICROBLEND = 'base\\surfaces\\microblends\\default.xbm'
FIXED_TIME = '2000-01-01T00:00:00Z'
MAX_PROFILE_ROWS = 1024     # server VehiclePaintProfileCatalogue: profile rows per resource
MAX_PROFILE_RECORDS = 256   # server VehiclePaintProfileCatalogue: records per resource
DEPOT = re.compile(r'^[a-z0-9_\-.\\]{1,240}$')
GRIME = ('\\grunge\\', '\\dust', 'dirt', '\\ground\\', 'rust', 'iron_old', 'damp', 'mud', 'soot', 'moss', 'leak',
         'graffiti', 'burnt', 'stain')
FORBIDDEN_LISTS = ['externalMaterials', 'preloadExternalMaterials', 'preloadLocalMaterialInstances',
                   'localMaterialInstances', 'inplaceResources']
ELEMENT_BYTES = {'PT_Short4N': 8, 'PT_Short4': 8, 'PT_UShort4N': 8, 'PT_UShort4': 8, 'PT_Float16_4': 8,
                 'PT_Float16_2': 4, 'PT_Dec4': 4, 'PT_Color': 4, 'PT_UByte4': 4, 'PT_UByte4N': 4, 'PT_Short2N': 4,
                 'PT_UShort2N': 4, 'PT_Float1': 4, 'PT_Float2': 8, 'PT_Float3': 12, 'PT_Float4': 16, 'PT_UInt4': 16}
TEXTURE_SETUPS = {   # the vanilla sticker textures: full-colour atlas with alpha, single-channel mask
    'd': {'group': 'TEXG_Generic_Color', 'compression': 'TCM_QualityColor', 'isGamma': 1, 'rawFormat': 'TRF_TrueColor'},
    'm': {'group': 'TEXG_Generic_Grayscale', 'compression': 'TCM_QualityR', 'isGamma': 0, 'rawFormat': 'TRF_TrueColor'},
}


def fail(msg):
    raise SystemExit(f'lv_cook: {msg}')


def header(doc_header, depot):
    h = dict(doc_header)
    h.update({'ArchiveFileName': depot, 'ExportedDateTime': FIXED_TIME})
    return h


def wk_header(version='8.20.0', depot=''):
    return {'WolvenKitVersion': version, 'WKitJsonVersion': '0.0.9', 'GameVersion': 2310,
            'ExportedDateTime': FIXED_TIME, 'DataType': 'CR2W', 'ArchiveFileName': depot}


def check_depot(path, prefix, ext):
    if not DEPOT.match(path) or not path.startswith(prefix + BS) or not path.endswith(ext) or '..' in path:
        fail(f'depot path refused: {path}')
    return path


def renumber_handles(doc):
    mapping = {}

    def collect(v):
        if isinstance(v, dict):
            if isinstance(v.get('HandleId'), str) and v['HandleId'] not in mapping:
                mapping[v['HandleId']] = str(len(mapping))
            for k, c in v.items():
                if k != 'HandleId':
                    collect(c)
        elif isinstance(v, list):
            for c in v:
                collect(c)

    def apply(v):
        if isinstance(v, dict):
            if isinstance(v.get('HandleId'), str):
                v['HandleId'] = mapping[v['HandleId']]
            if isinstance(v.get('HandleRefId'), str):
                if v['HandleRefId'] not in mapping:
                    fail(f'dangling HandleRefId {v["HandleRefId"]}')
                v['HandleRefId'] = mapping[v['HandleRefId']]
            for k, c in v.items():
                if k not in ('HandleId', 'HandleRefId'):
                    apply(c)
        elif isinstance(v, list):
            for c in v:
                apply(c)

    collect(doc)
    apply(doc)
    return doc


def depot_paths(doc):
    out = []

    def walk(v):
        if isinstance(v, dict):
            dp = v.get('DepotPath')
            if isinstance(dp, dict) and isinstance(dp.get('$value'), str) and dp['$value'] not in ('', '0'):
                out.append(dp['$value'])
            for c in v.values():
                walk(c)
        elif isinstance(v, list):
            for c in v:
                walk(c)
    walk(doc)
    return out


# --------------------------------------------------------------------------- textures
def xbm_setup(cfg):
    for tex in cfg['textures']:
        doc = read_json(tex['json'])
        setup = doc['Data']['RootChunk']['setup']
        setup.update(TEXTURE_SETUPS[tex['kind']])
        setup['allowTextureDowngrade'] = 0
        write_json(tex['json'], doc)
    print(f'LV_XBM_SETUP_OK textures={len(cfg["textures"])}')


def check_texture(tex):
    root = read_json(tex['roundtrip'])['Data']['RootChunk']
    want = TEXTURE_SETUPS[tex['kind']]
    for k, v in want.items():
        if root['setup'][k] != v:
            fail(f'{tex["depot"]}: setup.{k} = {root["setup"][k]}, expected {v}')
    info = root['renderTextureResource']['renderResourceBlobPC']['Data']['header']
    w, h = root['width'], root['height']
    if (w, h) != tuple(tex['size']):
        fail(f'{tex["depot"]}: {w}x{h}, expected {tex["size"]}')
    mips = info['textureInfo']['mipCount']
    if mips < 2:
        fail(f'{tex["depot"]}: no mip chain')
    return {'size': [w, h], 'mips': mips, 'bytes': info['textureInfo']['textureDataSize']}


# --------------------------------------------------------------------------- mlsetup
def palette(cfg, template):
    doc = read_json(Path(cfg['gameJson']) / (flat_name(template) + '.json'))
    return doc['Data']['RootChunk']['overrides']['colorScale']


def nearest(cfg, template, hexcol, cache={}):
    if template not in cache:
        cache[template] = [(c['n']['$value'], c['v']['Elements']) for c in palette(cfg, template)]
    want = [srgb_to_linear(c) for c in hex_rgb(hexcol)]
    best = min(cache[template], key=lambda e: sum((a - b) ** 2 for a, b in zip(e[1], want)))
    got = '#' + ''.join(f'{linear_to_srgb(c):02x}' for c in best[1])
    return best[0], got, math.sqrt(sum((a - b) ** 2 for a, b in zip(best[1], want)))


def paint_layer(cfg, finish_tpl, colour, opacity):
    key, got, err = nearest(cfg, finish_tpl, colour)
    layer = {
        '$type': 'Multilayer_Layer', 'colorScale': cname(key), 'material': resource(finish_tpl),
        'matTile': 1, 'mbTile': 1, 'metalLevelsIn': cname('null'), 'metalLevelsOut': cname('null'),
        'microblend': resource(MICROBLEND), 'microblendContrast': 1, 'microblendNormalStrength': 0,
        'microblendOffsetU': 0, 'microblendOffsetV': 0, 'normalStrength': cname('null'), 'offsetU': 0, 'offsetV': 0,
        'opacity': opacity, 'overrides': cname('None'), 'roughLevelsIn': cname('null'), 'roughLevelsOut': cname('null'),
    }
    return layer, {'want': colour, 'got': got, 'key': key, 'error': round(err, 4)}


def is_grime(path):
    p = path.lower()
    return any(g in p for g in GRIME)


def build_mlsetup(cfg, design, ml, finish_tpl, measured):
    """measured: this multilayer's entry of layer-roles.json (same reference setup)."""
    ref = read_json(Path(cfg['gameJson']) / (flat_name(ml['referenceSetups'][0]) + '.json'))['Data']['RootChunk']
    base = ref['layers']
    if measured['reference'] != ml['referenceSetups'][0] or len(measured['layers']) != len(base):
        fail(f'layer roles were measured on {measured["reference"]} ({len(measured["layers"])} layers), '
             f'the reference is {ml["referenceSetups"][0]} ({len(base)} layers)')
    layers, roles, picks = [], [], {}
    for i, (layer, m) in enumerate(zip(base, measured['layers'])):
        mat = cv(layer['material']) or ''
        if m['material'] != mat or m['colorScale'] != cv(layer['colorScale']):
            fail(f'layer {i} of {ml["referenceSetups"][0]} is not the one measured')
        out = copy.deepcopy(layer)
        which = {'paint': 'primary', 'accent': 'secondary' if design.get('twoTone') else 'primary'}.get(m['role'])
        if m['role'] == 'grime' or is_grime(mat):
            out['opacity'] = 0
            role = 'grime-off'
        elif which is not None:
            out, picks[which] = paint_layer(cfg, finish_tpl, design[which], 1 if i == 0 else layer['opacity'])
            role = which
        else:
            role = 'keep'
        layers.append(out)
        roles.append(role)
    root = {'$type': 'Multilayer_Setup', 'cookingPlatform': 'PLATFORM_PC', 'layers': layers,
            'ratio': ref.get('ratio', 1), 'useNormal': ref.get('useNormal', 1)}
    return root, roles, picks


# --------------------------------------------------------------------------- meshes
def chunks_of(root):
    return root['renderResourceBlob']['Data']['header']['renderChunkInfos']


def check_vertex_colors(label, root):
    data = base64.b64decode(root['renderResourceBlob']['Data']['renderBuffer']['Bytes'])
    checked = 0
    for i, c in enumerate(chunks_of(root)):
        layout = c['chunkVertices']['vertexLayout']
        elements = [e for e in layout['elements']['Elements'] if e['streamType'] == 'ST_PerVertex']
        strides = layout['slotStrides']['Elements']
        starts = c['chunkVertices']['byteOffsets']['Elements']
        colors = [e for e in elements if e['usage'] == 'PS_Color']
        if not colors:
            fail(f'{label}: chunk {i} has no PS_Color stream')
        for color in colors:
            s = color['streamIndex']
            stream = [e for e in elements if e['streamIndex'] == s]
            offset = sum(ELEMENT_BYTES[e['type']] for e in stream[:stream.index(color)])
            if sum(ELEMENT_BYTES[e['type']] for e in stream) != strides[s]:
                fail(f'{label}: chunk {i} stream {s} stride mismatch')
            for v in range(c['numVertices']):
                at = starts[s] + v * strides[s] + offset
                if data[at:at + 4] != b'\xff\xff\xff\xff':
                    fail(f'{label}: chunk {i} vertex {v} PS_Color = {data[at:at + 4].hex()}, expected ffffffff')
            checked += c['numVertices']
    return checked


def decal_material(design_id, textures):
    """A vanilla sticker instance: enableMask on (every vanilla sticker instance a chunk draws
    with a cut-out has it), the cut-out in the diffuse alpha and in MaskTexture."""
    values = [
        {'$type': 'rRef:ITexture', 'DiffuseTexture': resource(textures[design_id]['d'])},
        {'$type': 'rRef:ITexture', 'MaskTexture': resource(textures[design_id]['m'])},
        {'$type': 'Color', 'DiffuseColor': {'$type': 'Color', 'Alpha': 255, 'Blue': 255, 'Green': 255, 'Red': 255}},
        {'$type': 'Float', 'DiffuseAlpha': 1},
        {'$type': 'Float', 'UseGradientMap': 0},
        {'$type': 'rRef:ITexture', 'NormalTexture': resource(FLAT_NORMAL)},
        {'$type': 'Float', 'NormalAlpha': 0},
        {'$type': 'Float', 'DirtOpacity': 0},
    ]
    return {'$type': 'CMaterialInstance', 'baseMaterial': resource(STICKERS_MI), 'values': values,
            'enableMask': 1, 'resourceVersion': 4, 'cookingPlatform': 'PLATFORM_PC'}


def local_material_buffer(doc, mats):
    m = re.match(r'^(\d+)\.(\d+)\.(\d+)$', doc['Header'].get('WolvenKitVersion', ''))
    if not m:
        fail(f'unexpected WolvenKitVersion {doc["Header"].get("WolvenKitVersion")}')
    t = (f'WolvenKit.RED4.Archive.Buffer.CR2WList, WolvenKit.RED4, Version={m[1]}.{m[2]}.{m[3]}.0, '
         'Culture=neutral, PublicKeyToken=null')
    return {'$type': 'meshMeshMaterialBuffer', 'materials': mats,
            'rawData': {'BufferId': '0', 'Flags': 4063232, 'Type': t,
                        'Data': {'Files': [{'Version': 195, 'BuildVersion': 0, 'RootChunk': copy.deepcopy(x)} for x in mats]}},
            'rawDataHeaders': []}


def glb_area_per_axis(path):
    data = Path(path).read_bytes()
    n = struct.unpack_from('<I', data, 12)[0]
    doc = json.loads(data[20:20 + n])
    blob = data[20 + n + 8:]
    prim = doc['meshes'][0]['primitives'][0]
    acc = doc['accessors'][prim['attributes']['POSITION']]
    view = doc['bufferViews'][acc['bufferView']]
    pos = struct.unpack_from(f'<{3 * acc["count"]}f', blob, view['byteOffset'])
    ia = doc['accessors'][prim['indices']]
    iv = doc['bufferViews'][ia['bufferView']]
    idx = struct.unpack_from(f'<{ia["count"]}I', blob, iv['byteOffset'])
    area = [0.0, 0.0, 0.0]
    for k in range(0, len(idx), 3):
        a, b, c = (pos[3 * idx[k + j]:3 * idx[k + j] + 3] for j in range(3))
        # glTF Y-up -> engine (x, -z, y)
        a, b, c = ((p[0], -p[2], p[1]) for p in (a, b, c))
        u = [b[i] - a[i] for i in range(3)]
        v = [c[i] - a[i] for i in range(3)]
        cr = (u[1] * v[2] - u[2] * v[1], u[2] * v[0] - u[0] * v[2], u[0] * v[1] - u[1] * v[0])
        for i in range(3):
            area[i] += abs(cr[i]) / 2
    return area, len(idx) // 3


def prepare_mesh(cfg, model_key, comp, info, designs, textures, depot):
    doc = read_json(info['importedJson'])
    root = doc['Data']['RootChunk']
    chunks = chunks_of(root)
    area, ntri = glb_area_per_axis(info['glb'])
    if len(chunks) != 1 or chunks[0]['numIndices'] // 3 != ntri:
        fail(f'{model_key}/{comp}: imported {len(chunks)} chunks / {[c["numIndices"] // 3 for c in chunks]} triangles, glb has {ntri}')
    colours = check_vertex_colors(f'{model_key}/{comp}', root)
    for key in ['parameters', 'boneNames', 'boneRigMatrices', 'boneVertexEpsilons', 'floatTrackNames', 'lodBoneMask'] + FORBIDDEN_LISTS:
        root[key] = []
    root['lodLevelInfo'] = [0]
    blob = root['renderResourceBlob']['Data']
    blob['header']['renderLODs'] = [0]
    blob['renderBuffer']['BufferId'] = '1'
    blob['header']['quantizationOffset']['W'] = 1
    blob['header']['quantizationScale']['W'] = 0
    raw = base64.b64decode(blob['renderBuffer']['Bytes'])
    root.update({'isShadowMesh': 0, 'isPlayerShadowMesh': 0, 'castGlobalShadowsCachedInCook': 0, 'castLocalShadowsCachedInCook': 0,
                 'surfaceAreaPerAxis': {'$type': 'Vector3', 'X': area[0], 'Y': area[1], 'Z': area[2]},
                 'geometryHash': str(int.from_bytes(hashlib.sha256(raw).digest()[:8], 'little'))})
    mats = [decal_material(d, textures) for d in designs]
    root['localMaterialBuffer'] = local_material_buffer(doc, mats)
    root['materialEntries'] = [{'$type': 'CMeshMaterialEntry', 'index': i, 'isLocalInstance': 1, 'name': cname(d)}
                               for i, d in enumerate(designs)]
    apps = [('default', designs[0])] + [(d, d) for d in designs]
    root['appearances'] = [{'HandleId': str(900000 + i), 'Data': {'$type': 'meshMeshAppearance', 'name': cname(n),
                            'chunkMaterials': [cname(mat)], 'tags': []}} for i, (n, mat) in enumerate(apps)]
    doc['Header'] = header(doc['Header'], depot)
    doc['Data']['EmbeddedFiles'] = []
    return renumber_handles(doc), colours


def cruid(text):
    return str(int.from_bytes(hashlib.sha256(text.encode()).digest()[:8], 'little') & 0x7FFF_FFFF_FFFF_FFFF)


def decal_entity(mesh_depot, appearance, depot, wk_version):
    cid = cruid(depot)

    def mesh_component():
        return {
            '$type': 'entMeshComponent', 'autoHideDistance': 0, 'castLocalShadows': 'Never',
            'castRayTracedGlobalShadows': 'Never', 'castRayTracedLocalShadows': 'Default', 'castShadows': 'Never',
            'chunkMask': '9223372036854775807', 'forcedLodDistance': 'Default', 'forceLODLevel': -1, 'id': cid,
            'isEnabled': 1, 'isReplicable': 0,
            'localTransform': {'$type': 'WorldTransform', 'Orientation': {'$type': 'Quaternion', 'i': 0, 'j': 0, 'k': 0, 'r': 1},
                               'Position': {'$type': 'WorldPosition', **{a: {'$type': 'FixedPoint', 'Bits': 0} for a in 'xyz'}}},
            'LODMode': 'AlwaysVisible', 'mesh': resource(mesh_depot), 'meshAppearance': cname(appearance),
            'motionBlurScale': 1, 'name': cname('decal'),
            'navigationImpact': {'$type': 'NavGenNavigationSetting', 'navmeshImpact': 'Ignored'}, 'numInstances': 0,
            'objectTypeID': 'ROT_Static', 'order': 1, 'overrideMeshNavigationImpact': 1, 'parentTransform': None,
            'renderingPlane': 'RPl_Scene', 'renderSceneLayerMask': 'Default', 'version': 0,
            'visualScale': {'$type': 'Vector3', 'X': 1, 'Y': 1, 'Z': 1},
        }
    entity = {'$type': 'entEntity', 'customCameraTarget': 'ECCTV_All', 'renderSceneLayerMask': 'Default'}
    root = {
        '$type': 'entEntityTemplate', 'appearances': [], 'backendDataOverrides': [], 'bindingOverrides': [],
        'compiledData': {'BufferId': '0', 'Flags': 7471104,
                         'Type': f'WolvenKit.RED4.Archive.Buffer.RedPackage, WolvenKit.RED4, Version={wk_version}.0, Culture=neutral, PublicKeyToken=null',
                         'Data': {'Version': 4, 'Sections': 7, 'CruidIndex': 0, 'CruidDict': {'0': '0', '1': cid},
                                  'Chunks': [copy.deepcopy(entity), mesh_component()]}},
        'compiledEntityLODFlags': 0, 'componentResolveSettings': [], 'components': [mesh_component()],
        'cookingPlatform': 'PLATFORM_PC', 'defaultAppearance': cname('default'),
        'entity': {'HandleId': '0', 'Data': entity}, 'includeInstanceBuffer': None, 'includes': [],
        'inplaceResources': [], 'localData': None, 'resolvedDependencies': [], 'visualTagsSchema': None,
    }
    return {'Header': wk_header(wk_version, depot), 'Data': {'Version': 195, 'BuildVersion': 0, 'RootChunk': root, 'EmbeddedFiles': []}}


# --------------------------------------------------------------------------- YAML
def yq(s):
    return "'" + str(s).replace("'", "''") + "'"


def ylist(items, indent):
    pad = ' ' * indent
    if not items:
        return ' []'
    return ''.join(f'\n{pad}- {yq(x)}' for x in items)


def prepare(cfg):
    spec, plan, decals = read_json(cfg['spec']), read_json(cfg['plan']), read_json(cfg['decals'])
    prefix, out = cfg['prefix'], Path(cfg['preparedDir'])
    designs = {d['id']: d for d in spec['designs']}
    textures = {d: {k: check_depot(f'{prefix}{BS}textures{BS}{d}_{k}.xbm', prefix, '.xbm') for k in TEXTURE_SETUPS} for d in designs}
    layer_roles = read_json(cfg['layerRoles'])['models']
    imported = {(t['model'], t['component']): t for t in cfg['meshes']}
    files, records, report = [], [], {'models': {}}
    yaml = [
        '# Open77 Light RP vehicle liveries: unique TwinTone colour templates (TweakXL).',
        f'# Generated by scripts/vehicle-kit/liveries/build-liveries.ps1, revision {cfg["revision"][:12]}. Edit the spec, not this file.',
        '# Each record = our .mlsetup over the model\'s own (vanilla, referenced) mask + our decal entities.',
        '# matchingAppearances stays empty: the game never picks one by itself; only setPaintProfile applies it.',
        '',
    ]
    appends = {}
    lua_models = []
    for mp in plan['models']:
        key = mp['key']
        dm = decals['models'].get(key) or fail(f'decals.json has no {key}')
        mrep = {'record': mp['record'], 'profiles': {}, 'meshes': {}, 'mlsetups': {}}
        # meshes: one per component, one appearance per design that covers it
        mesh_depot = {}
        for comp, info in sorted(dm['components'].items()):
            covering = [d for d in designs if comp in dm['designs'].get(d, [])]
            if not covering:
                continue
            t = imported.get((key, comp)) or fail(f'no imported mesh for {key}/{comp}')
            depot = check_depot(f'{prefix}{BS}meshes{BS}{key}{BS}{comp.lower()}.mesh', prefix, '.mesh')
            doc, colours = prepare_mesh(cfg, key, comp, {**info, **t}, covering, textures, depot)
            write_json(out / (flat_name(depot) + '.json'), doc)
            files.append(depot)
            mesh_depot[comp] = depot
            mrep['meshes'][comp] = {'designs': covering, 'triangles': info['triangles'], 'vertexColorsChecked': colours}
        lua_profiles, lua_decals = {}, {}
        for did, d in designs.items():
            rec = f'{spec["recordPrefix"]}{did}_{key}'
            ml_lines, roles_rep = [], []
            for i, ml in enumerate(mp['multilayers']):
                ml_depot = check_depot(f'{prefix}{BS}mlsetups{BS}{key}{BS}{did}_{i}.mlsetup', prefix, '.mlsetup')
                root, roles, picks = build_mlsetup(cfg, d, ml, spec['finishes'][d['finish']], layer_roles[key]['multilayers'][i])
                write_json(out / (flat_name(ml_depot) + '.json'),
                           {'Header': wk_header(cfg['wolvenkit'], ml_depot),
                            'Data': {'Version': 195, 'BuildVersion': 0, 'RootChunk': root, 'EmbeddedFiles': []}})
                files.append(ml_depot)
                roles_rep.append({'mask': ml['mask'], 'roles': roles, 'paint': picks})
                ml_lines += [
                    '    - $type: VehicleCustomMultilayer',
                    f'      customMlSetup: {yq(ml_depot)}',
                    f'      customMlMask: {yq(ml["mask"])}',
                    f'      affectedComponents:{ylist(ml["affected"], 8)}',
                    f'      excludedComponents:{ylist(ml["excluded"], 8)}',
                    '      onlyForPlayerVehicleAppearances: []',
                    f'      coatLayerMin: {ml["coatLayerMin"]}',
                    f'      coatLayerMax: {ml["coatLayerMax"]}',
                ]
            dec_lines = []
            for comp in sorted(dm['designs'].get(did, [])):
                if comp not in mesh_depot:
                    continue
                ent_depot = check_depot(f'{prefix}{BS}decals{BS}{key}{BS}{did}_{comp.lower()}.ent', prefix, '.ent')
                write_json(out / (flat_name(ent_depot) + '.json'),
                           decal_entity(mesh_depot[comp], did, ent_depot, cfg['wolvenkit']))
                files.append(ent_depot)
                dec_lines += [
                    '    - $type: VehicleDecalAttachment',
                    f'      componentToAttachTo: {yq(comp)}',
                    f'      decalResource: {yq(ent_depot)}',
                    '      onlyForPlayerVehicleAppearances: []',
                ]
            if len(dec_lines) // 4 > MAX_DECALS_PER_TEMPLATE:
                fail(f'{rec}: {len(dec_lines) // 4} decals, over the engine cap of {MAX_DECALS_PER_TEMPLATE} '
                     'per template (13 crash every client at spawn; lv_plan.py decalHosts folds them)')
            yaml += [
                f'{rec}:',
                '  $type: VehicleColorTemplate',
                '  hasCustomPattern: true',
                '  mainColor: []',
                '  secondaryColor: []',
                '  lightsHue: -1.0',
                '  matchingAppearances: []',
                '  matchingColorVariant: []',
                '  partsClearCoatOverrides: []',
                '  customMultilayers:',
                *ml_lines,
                '  customDecals:' + ('' if dec_lines else ' []'),
                *dec_lines,
                '',
            ]
            records.append(rec)
            appends.setdefault(mp['appearancesToColorTemplate'], []).append(rec)
            lua_profiles[did] = rec
            lua_decals[did] = len(dec_lines) // 4
            mrep['profiles'][did] = {'record': rec, 'decals': len(dec_lines) // 4, 'multilayers': roles_rep}
        lua_models.append((key, mp, lua_profiles, lua_decals))
        report['models'][key] = mrep
    for a2c, recs in appends.items():
        yaml.append(f'{a2c}:')
        yaml.append('  colorTemplates:')
        yaml += [f'    - !append-once {r}' for r in recs]
        yaml.append('')
    Path(cfg['yamlOut']).parent.mkdir(parents=True, exist_ok=True)
    Path(cfg['yamlOut']).write_text('\n'.join(yaml), encoding='utf-8', newline='\n')
    # D6: every reference outside the pack must be one we chose to reference.
    allowed = set(cfg['allowedReferences'])
    for mp in plan['models']:
        allowed.update(ml['mask'] for ml in mp['multilayers'])
    for f in files:
        doc = read_json(out / (flat_name(f) + '.json'))
        for p in depot_paths(doc):
            if p.startswith(prefix + BS) or p in allowed or p.startswith(('base\\surfaces\\materials\\', 'base\\surfaces\\microblends\\')):
                continue
            fail(f'{f} references {p}, outside the pack and not an allowed reference')
    # Lua tables for the resource (no BOM)
    lines = ['-- Generated by build-liveries.ps1 (revision ' + cfg['revision'][:12] + '). Edit the spec, not this file.',
             'LightRpVehicleLiveries = {', f"    revision = '{cfg['revision'][:12]}',", '    designs = {']
    rgb = lambda h: '{ ' + ', '.join(str(c) for c in hex_rgb(h)) + ' }'
    for d in spec['designs']:
        lines.append(f"        {{ id = '{d['id']}', label = {json.dumps(d['label'], ensure_ascii=True)}, group = '{d['group']}', "
                     f"job = {json.dumps(d['job']) if d['job'] else 'nil'}, main = {rgb(d['primary'])}, sec = {rgb(d['secondary'])} }},")
    lines += ['    },', '    models = {']
    # decals[design] = the template's customDecals count: the server counts it in the per-car
    # decal budget (12 at most, livery and stickers together; wave 2, W2.4).
    # records = the trims of the body that take the same templates (lv_plan.py `records`).
    rows = sum(len(profs) * len(mp.get('records') or [mp['record']]) for _k, mp, profs, _d in lua_models)
    if rows > MAX_PROFILE_ROWS or sum(len(mp.get('records') or [mp['record']]) for _k, mp, _p, _d in lua_models) > MAX_PROFILE_RECORDS:
        fail(f'{rows} profile rows: over the server catalogue limits (VehiclePaintProfileCatalogue: '
             f'{MAX_PROFILE_ROWS} rows, {MAX_PROFILE_RECORDS} records per resource)')
    for key, mp, profs, decs in lua_models:
        trims = mp.get('records') or []
        listed = (", records = { " + ', '.join(f"'{r}'" for r in trims) + ' }') if trims else ''
        lines.append(f"        {{ key = '{key}', record = '{mp['record']}'{listed}, profiles = {{")
        lines += [f"            {did} = '{rec}'," for did, rec in profs.items()]
        lines.append('        }, decals = {')
        lines += [f"            {did} = {decs[did]}," for did in profs]
        lines.append('        } },')
    lines += ['    },', '}', '']
    Path(cfg['luaOut']).parent.mkdir(parents=True, exist_ok=True)
    Path(cfg['luaOut']).write_text('\n'.join(lines), encoding='utf-8', newline='\n')
    # Catalogue rows in the server's profile shape (VehicleCustomizationData.ParseProfiles).
    catalogue = {r: [{'id': p, 'label': designs[did]['label'], 'main': list(hex_rgb(designs[did]['primary'])),
                      'sec': list(hex_rgb(designs[did]['secondary'])), 'match': [], 'pattern': True}
                     for did, p in profs.items()]
                 for _key, mp, profs, _decs in lua_models for r in (mp.get('records') or [mp['record']])}
    write_json(cfg['profilesOut'], {'schema': 'open77.vehicle-liveries.profiles/1', 'revision': cfg['revision'][:12],
                                    'note': 'Rows in the shape of the server catalogue column `profiles` (vehicle-customization-2.50.tsv); '
                                            'the server must learn them before setPaintProfile accepts them (docs/liveries.md).',
                                    'records': catalogue})
    report.update({'files': sorted(files), 'records': records, 'textures': textures})
    write_json(cfg['packageOut'], report)
    print(f'LV_COOK_PREPARED files={len(files)} records={len(records)} a2c={len(appends)}')


def validate(cfg):
    out, rt = Path(cfg['preparedDir']), Path(cfg['roundtripDir'])
    pkg = read_json(cfg['packageOut'])
    for f in pkg['files']:
        a = read_json(out / (flat_name(f) + '.json'))['Data']['RootChunk']
        b_path = rt / (flat_name(f) + '.json')
        if not b_path.exists():
            fail(f'round trip lost {f}')
        b = read_json(b_path)['Data']['RootChunk']
        if a['$type'] != b['$type']:
            fail(f'{f}: type {a["$type"]} became {b["$type"]}')
        if f.endswith('.mesh'):
            if [cv(x['Data']['name']) for x in b['appearances']] != [cv(x['Data']['name']) for x in a['appearances']]:
                fail(f'{f}: appearances changed in the round trip')
            if len(b['localMaterialBuffer']['materials']) != len(a['localMaterialBuffer']['materials']):
                fail(f'{f}: local materials lost')
            for key in FORBIDDEN_LISTS:
                if b.get(key):
                    fail(f'{f}: {key} is not empty after the round trip')
            check_vertex_colors(f, b)
        elif f.endswith('.ent'):
            comps = [c for c in b['components'] if c.get('$type') == 'entMeshComponent']
            if len(comps) != 1 or cv(comps[0]['mesh']) != cv(a['components'][0]['mesh']):
                fail(f'{f}: decal component lost in the round trip')
        elif f.endswith('.mlsetup'):
            if [cv(x['colorScale']) for x in b['layers']] != [cv(x['colorScale']) for x in a['layers']]:
                fail(f'{f}: layers changed in the round trip')
    tex = {t['depot']: check_texture(t) for t in cfg['textures']}
    pkg['texturesChecked'] = tex
    write_json(cfg['packageOut'], pkg)
    print(f'LV_COOK_ROUNDTRIP_OK files={len(pkg["files"])} textures={len(tex)}')


if __name__ == '__main__':
    if len(sys.argv) != 3 or sys.argv[1] not in ('xbm-setup', 'prepare', 'validate'):
        fail('usage: lv_cook.py xbm-setup|prepare|validate <cook.json>')
    c = read_json(sys.argv[2])
    {'xbm-setup': xbm_setup, 'prepare': prepare, 'validate': validate}[sys.argv[1]](c)
