// Open77 vehicle-kit native cook: WolvenKit JSON in, WolvenKit JSON out.
//
//   node cook.cjs prepare  <plan.json>   imported mesh JSON -> prepared mesh/.ent JSON + package.json
//   node cook.cjs validate <plan.json>   checks the serialize round trip and the staged binaries
//
// Geometry is ORIGINAL (Blender, ../blender). The game supplies only:
//   - the container of the imported mesh (a vanilla mesh copied as WolvenKit's import template;
//     its geometry, materials and collision are all replaced or removed here),
//   - the safe game-object host template (base\gameplay\debug\debuginteraction.ent), and
//   - REFERENCES by depot path to engine\materials\metal_base.remt and engine\textures\editor\*.xbm.
// Every written depot path lives under open77\assets\<resource>\<revision>\, so nothing can
// shadow, or be shadowed by, a vanilla or Open77 archive.
//
// The cooked shape follows the Light RP board-game props, the custom meshes proven visible
// in game: ONE mesh per model, ONE appearance named `default`, materials stored LOCALLY in
// localMaterialBuffer (CMaterialInstance on metal_base.remt, PLATFORM_PC, colour by material
// parameters), no external or preloaded material. One appearance per model matters because
// the Open77 mesh backend rewrites every host mesh component to the appearance the caller
// asks for, `default` when none, without reloading the resource (client/src/api/Props.cpp,
// BeginComponentWrite): a host authored on any other appearance is changed under the engine.
'use strict';
const fs = require('node:fs'), path = require('node:path'), crypto = require('node:crypto');

const [operation, planPath] = process.argv.slice(2);
if (!['prepare', 'validate'].includes(operation) || !planPath) {
  console.error('usage: cook.cjs prepare|validate <plan.json>');
  process.exit(2);
}
const plan = readJson(planPath);
const fail = msg => { throw new Error(msg); };

function readJson(p) { return JSON.parse(fs.readFileSync(p, 'utf8')); }
function writeJson(p, v) { fs.mkdirSync(path.dirname(p), { recursive: true }); fs.writeFileSync(p, JSON.stringify(v, null, 2) + '\n'); }
const cname = v => ({ $type: 'CName', $storage: 'string', $value: v });
const resource = v => ({ DepotPath: { $type: 'ResourcePath', $storage: 'string', $value: v }, Flags: 'Default' });
const vec3 = (x, y, z) => ({ $type: 'Vector3', X: x, Y: y, Z: z });
const value = (key, type, v) => ({ $type: type, [key]: v });
const ID = /^[a-z0-9_-]{1,64}$/;
const DEPOT = /^[a-z0-9_\-.\\]{1,240}$/;
const prefix = plan.prefix;
const depotFile = (depot, root) => path.join(root, ...depot.split('\\')) + '.json';

function checkDepot(p, ext) {
  // Same rule as core/include/op77/Core/PropModels.hpp (Path): lowercase, under our owner.
  if (!DEPOT.test(p) || !p.startsWith(`open77\\assets\\${plan.resource}\\`) || !p.endsWith(ext) ||
      p.includes('..') || p.includes('\\\\')) fail(`depot path refused by the registerModel rule: ${p}`);
  return p;
}

// Renumber handles 0..n-1 in document order, keeping HandleRefId links consistent.
function renumberHandles(doc) {
  const map = new Map();
  (function collect(v) {
    if (!v || typeof v !== 'object') return;
    if (typeof v.HandleId === 'string' && !map.has(v.HandleId)) map.set(v.HandleId, String(map.size));
    for (const [k, c] of Object.entries(v)) if (k !== 'HandleId') collect(c);
  })(doc);
  (function apply(v) {
    if (!v || typeof v !== 'object') return;
    if (typeof v.HandleId === 'string') v.HandleId = map.get(v.HandleId);
    if (typeof v.HandleRefId === 'string') {
      if (!map.has(v.HandleRefId)) fail(`dangling HandleRefId ${v.HandleRefId}`);
      v.HandleRefId = map.get(v.HandleRefId);
    }
    for (const [k, c] of Object.entries(v)) if (k !== 'HandleId' && k !== 'HandleRefId') apply(c);
  })(doc);
  return doc;
}

const METAL_BASE = 'engine\\materials\\metal_base.remt';
const WHITE = 'engine\\textures\\editor\\white.xbm';

// The shape of CDPR's own chrome on this template
// (base\environment\decoration\furniture\restaurant\bar_a\textures\bar_a_chrome.mi:
// BaseColor and Metalness = white.xbm, grey BaseColorScale, RoughnessScale 0.1), with the
// palette's colour, metalness and roughness, cooked for PC.
//
// metal_base.remt reads each channel as texture x Scale + Bias, and its own defaults are
// Metalness = engine\textures\editor\black.xbm, Roughness = white.xbm, both biases 0. So the
// Metalness texture MUST be set: without it MetalnessScale multiplies zero and every finish
// cooks as a dielectric. That was the matte "chrome" seen in game on 2026-11-05 (packs
// 71f872a21fa7 and c774256c18e1, which copied the board-game props' non-metal values list).
// Roughness is set explicitly too, so the cooked file does not lean on a template default.
function materialInstance(name) {
  const m = plan.palette[name] ?? fail(`palette has no material '${name}'`);
  const [r, g, b] = m.color;
  const white = resource(WHITE);
  const values = [
    value('BaseColor', 'rRef:ITexture', white),
    value('BaseColorScale', 'Vector4', { $type: 'Vector4', X: r, Y: g, Z: b, W: 1 }),
    value('Metalness', 'rRef:ITexture', resource(WHITE)),
    value('MetalnessScale', 'Float', m.metalness),
    value('Roughness', 'rRef:ITexture', resource(WHITE)),
    value('RoughnessScale', 'Float', m.roughness),
  ];
  if ((m.emissiveEV ?? 0) > 0) {
    values.push(value('Emissive', 'rRef:ITexture', white), value('EmissiveEV', 'Float', m.emissiveEV),
      value('EmissiveColor', 'Color', { $type: 'Color', Alpha: 255, Blue: Math.round(b * 255), Green: Math.round(g * 255), Red: Math.round(r * 255) }));
  }
  return { $type: 'CMaterialInstance', baseMaterial: resource(METAL_BASE), values,
           enableMask: 0, resourceVersion: 4, cookingPlatform: 'PLATFORM_PC' };
}

// localMaterialBuffer as WolvenKit 8.x serializes it: the materials, and the same list as
// the CR2W files of the raw buffer. WolvenKit computes rawDataHeaders on deserialize. The
// buffer takes BufferId 0 and the render buffer 1, as in the proven meshes: a shared id
// makes WolvenKit refuse the whole file.
function localMaterialBuffer(doc, mats) {
  const wk = /^(\d+)\.(\d+)\.(\d+)$/.exec(doc.Header?.WolvenKitVersion ?? '') ??
    fail(`unexpected WolvenKitVersion '${doc.Header?.WolvenKitVersion}' in the imported mesh JSON`);
  return { $type: 'meshMeshMaterialBuffer', materials: mats,
    rawData: { BufferId: '0', Flags: 4063232,
      Type: `WolvenKit.RED4.Archive.Buffer.CR2WList, WolvenKit.RED4, Version=${wk[1]}.${wk[2]}.${wk[3]}.0, Culture=neutral, PublicKeyToken=null`,
      Data: { Files: mats.map(m => ({ Version: 195, BuildVersion: 0, RootChunk: structuredClone(m) })) } },
    rawDataHeaders: [] };
}

const meshDepot = (part, finish) => checkDepot(`${prefix}\\${part.id}_${finish}.mesh`, '.mesh');
const entDepot = (part, finish) => checkDepot(`${prefix}\\${part.id}_${finish}_visual.ent`, '.ent');
const modelId = (part, finish) => {
  const id = `${part.id}_${finish}`;
  if (!ID.test(id)) fail(`model id '${id}' must match [a-z0-9_-]{1,64}`);
  return id;
};

function chunksOf(root) { return root.renderResourceBlob.Data.header.renderChunkInfos; }

// Bytes per packed vertex element, to find PS_Color inside its interleaved stream.
const ELEMENT_BYTES = { PT_Short4N: 8, PT_Short4: 8, PT_UShort4N: 8, PT_UShort4: 8, PT_Float16_4: 8,
  PT_Float16_2: 4, PT_Dec4: 4, PT_Color: 4, PT_UByte4: 4, PT_UByte4N: 4, PT_Short2N: 4, PT_UShort2N: 4,
  PT_Float1: 4, PT_Float2: 8, PT_Float3: 12, PT_Float4: 16, PT_UInt4: 16 };

// Every cooked vertex color must be ffffffff. metal_base.remt multiplies by vertex color
// and alpha: with WolvenKit's 00000000 fill (no COLOR_0 in the glb) a part draws nothing
// in the main pass and still casts its shadow -- the E0.9 failure. Same rule as the
// Light RP prop test (black/transparent cooked vertex colors).
function checkVertexColors(label, root) {
  const bytes = Buffer.from(root.renderResourceBlob.Data.renderBuffer.Bytes, 'base64');
  let checked = 0;
  chunksOf(root).forEach((c, i) => {
    const layout = c.chunkVertices.vertexLayout;
    const elements = layout.elements.Elements.filter(e => e.streamType === 'ST_PerVertex');
    const strides = layout.slotStrides.Elements, starts = c.chunkVertices.byteOffsets.Elements;
    const colors = elements.filter(e => e.usage === 'PS_Color');
    if (!colors.length) fail(`${label}: chunk ${i} has no PS_Color stream`);
    for (const color of colors) {
      const s = color.streamIndex, stream = elements.filter(e => e.streamIndex === s);
      const size = e => ELEMENT_BYTES[e.type] ?? fail(`${label}: unknown vertex element type ${e.type} in stream ${s}`);
      const offset = stream.slice(0, stream.indexOf(color)).reduce((n, e) => n + size(e), 0);
      const total = stream.reduce((n, e) => n + size(e), 0);
      if (total !== strides[s]) fail(`${label}: chunk ${i} stream ${s} stride ${strides[s]} != element bytes ${total}`);
      for (let v = 0; v < c.numVertices; v++) {
        const at = starts[s] + v * strides[s] + offset;
        if (at + 4 > bytes.length) fail(`${label}: chunk ${i} PS_Color runs past the render buffer`);
        if (bytes.readUInt32LE(at) !== 0xFFFFFFFF)
          fail(`${label}: chunk ${i} vertex ${v} PS_Color${color.usageIndex} = ${bytes.subarray(at, at + 4).toString('hex')}, ` +
               'expected ffffffff (black/transparent cooked vertex colors draw nothing in the main pass)');
      }
      checked += c.numVertices;
    }
  });
  return checked;
}

// Material storage of the proven-visible custom meshes: everything in localMaterialBuffer,
// nothing external, nothing preloaded. check-prop-meshes.py measured the vanilla props
// that carry preloadLocalMaterialInstances as the ones that did not render when held; our
// first two E0.9 builds used external .mi files and drew nothing but their shadows.
const FORBIDDEN_LISTS = ['externalMaterials', 'preloadExternalMaterials', 'preloadLocalMaterialInstances',
                         'localMaterialInstances', 'inplaceResources'];
const near = (a, b) => Math.abs(a - b) < 1e-5;

function checkLocalMaterials(label, root, want, roundTrip) {
  for (const key of FORBIDDEN_LISTS) {
    const n = (root[key] ?? []).length;
    if (n) fail(`${label}: ${key} has ${n} entr${n === 1 ? 'y' : 'ies'}; materials must all be local (localMaterialBuffer)`);
  }
  const entries = root.materialEntries ?? [], buffer = root.localMaterialBuffer ?? fail(`${label}: no localMaterialBuffer`);
  const mats = buffer.materials ?? [], files = buffer.rawData?.Data?.Files ?? [];
  const names = entries.map(e => e.name?.$value);
  if (JSON.stringify(names) !== JSON.stringify(want)) fail(`${label}: material entries ${JSON.stringify(names)}, expected ${JSON.stringify(want)}`);
  entries.forEach((e, i) => {
    if (e.isLocalInstance !== 1) fail(`${label}: material entry ${names[i]} is not a local instance (isLocalInstance ${e.isLocalInstance})`);
    if (e.index !== i) fail(`${label}: material entry ${names[i]} has index ${e.index}, expected ${i}`);
  });
  if (mats.length !== entries.length) fail(`${label}: ${mats.length} local materials for ${entries.length} entries`);
  if (files.length !== mats.length) fail(`${label}: the local material raw buffer holds ${files.length} materials, expected ${mats.length}`);
  // WolvenKit writes one header per material when it actually cooked the buffer.
  if (roundTrip && (buffer.rawDataHeaders ?? []).length !== mats.length)
    fail(`${label}: ${buffer.rawDataHeaders?.length ?? 0} local material headers after the round trip, expected ${mats.length}`);
  [...mats, ...files.map(f => f.RootChunk)].forEach((m, k) => {
    const i = k % mats.length, name = names[i], spec = plan.palette[name];
    if (m?.$type !== 'CMaterialInstance') fail(`${label}: local material ${name} is ${m?.$type}`);
    if (m.baseMaterial?.DepotPath?.$value !== METAL_BASE) fail(`${label}: local material ${name} is based on ${m.baseMaterial?.DepotPath?.$value}`);
    if (m.cookingPlatform !== 'PLATFORM_PC') fail(`${label}: local material ${name} cookingPlatform ${m.cookingPlatform}, expected PLATFORM_PC`);
    const v = Object.assign({}, ...(m.values ?? []).map(({ $type, ...rest }) => rest));
    const c = v.BaseColorScale ?? {};
    if (!near(c.X, spec.color[0]) || !near(c.Y, spec.color[1]) || !near(c.Z, spec.color[2]) || !near(c.W, 1) ||
        !near(v.MetalnessScale, spec.metalness) || !near(v.RoughnessScale, spec.roughness) || v.BaseColor?.DepotPath?.$value !== WHITE)
      fail(`${label}: local material ${name} lost its parameters (${JSON.stringify(v).slice(0, 300)})`);
    // Without these two textures the template's defaults apply, and its Metalness default is
    // black.xbm: MetalnessScale would multiply zero (see materialInstance).
    for (const tex of ['Metalness', 'Roughness'])
      if (v[tex]?.DepotPath?.$value !== WHITE)
        fail(`${label}: local material ${name} has ${tex} = ${v[tex]?.DepotPath?.$value ?? 'the template default'}, expected ${WHITE}`);
    for (const bias of ['MetalnessBias', 'RoughnessBias'])
      if (bias in v && !near(v[bias], 0)) fail(`${label}: local material ${name} sets ${bias} ${v[bias]}; the palette drives the Scale only`);
  });
  const apps = root.appearances ?? [];
  if (apps.length !== 1 || apps[0].Data?.name?.$value !== 'default')
    fail(`${label}: appearances ${JSON.stringify(apps.map(a => a.Data?.name?.$value))}, expected exactly ["default"]`);
  const used = apps[0].Data.chunkMaterials.map(c => c.$value);
  if (used.length !== chunksOf(root).length) fail(`${label}: appearance default maps ${used.length} chunks of ${chunksOf(root).length}`);
  for (const n of used) if (!names.includes(n)) fail(`${label}: appearance default names material ${n}, which has no entry`);
}

// Decision D6: a cooked file embeds nothing and references only our own depot paths plus
// an explicit list of vanilla resources it names without copying them: the material base
// and texture, and the host's (disabled) interaction definition. The debug-interaction
// host template embeds a vanilla level-design mesh (ld_kit_dcem_computer_screen_station
// .w2mesh, 512 vertices) and lists it in inplaceResources / resolvedDependencies: kept, it
// would ship vanilla geometry inside every host .ent.
const VANILLA_REFS = new Set([METAL_BASE, WHITE, 'base\\gameplay\\debug\\debug_interaction.interaction']);
function checkReferences(label, doc) {
  const embedded = (doc.Data?.EmbeddedFiles ?? []).length;
  if (embedded) fail(`${label}: embeds ${embedded} file(s); a cooked file must embed nothing (D6)`);
  (function walk(v, at) {
    if (!v || typeof v !== 'object') return;
    if (v.$type === 'ResourcePath' && typeof v.$value === 'string' && v.$value) {
      const p = v.$value;
      if (!p.startsWith(`${prefix}\\`) && !VANILLA_REFS.has(p))
        fail(`${label}: references ${p} at ${at} (allowed: ${prefix}\\ and ${[...VANILLA_REFS].join(', ')})`);
    }
    for (const [k, c] of Object.entries(v)) walk(c, `${at}.${k}`);
  })(doc.Data, '');
}

// The same scan as base/scripts/check-prop-meshes.py, on the staged binary: a CR2W file
// lists its property names in its name table, so a name present is a property written.
const BINARY_FORBIDDEN = ['externalMaterials', 'preloadExternalMaterials', 'preloadLocalMaterialInstances', 'inplaceResources'];
function checkBinaryMesh(label, file) {
  const bytes = fs.readFileSync(file);
  for (const marker of BINARY_FORBIDDEN)
    if (bytes.includes(Buffer.from(marker, 'latin1'))) fail(`${label}: the cooked mesh names ${marker} (${file})`);
  if (!bytes.includes(Buffer.from('localMaterialBuffer', 'latin1'))) fail(`${label}: the cooked mesh has no localMaterialBuffer (${file})`);
}

function checkImported(part, meta, root) {
  const chunks = chunksOf(root);
  const subs = meta.submeshes;
  if (chunks.length !== subs.length) fail(`${part.id}: WolvenKit kept ${chunks.length} chunks of ${subs.length} submeshes (a multi-primitive node loses all but its first)`);
  chunks.forEach((c, i) => {
    const s = subs[i];
    if (c.numIndices / 3 !== s.triangles) fail(`${part.id}: chunk ${i} has ${c.numIndices / 3} triangles, ${s.name} has ${s.triangles}`);
    if (c.lodMask !== 1 << (s.lod - 1)) fail(`${part.id}: chunk ${i} lodMask ${c.lodMask}, expected LOD ${s.lod}`);
  });
  const lods = Object.values(meta.lods);
  for (let a = 0; a < 3; a++) {
    const lo = Math.min(...lods.map(l => l.bounds[0][a])), hi = Math.max(...lods.map(l => l.bounds[1][a]));
    const axis = 'XYZ'[a];
    if (Math.abs(root.boundingBox.Min[axis] - lo) > 0.003 || Math.abs(root.boundingBox.Max[axis] - hi) > 0.003)
      fail(`${part.id}: bounds changed on ${axis} (${root.boundingBox.Min[axis]}..${root.boundingBox.Max[axis]} vs ${lo}..${hi}): axis or unit mismatch`);
  }
  part.vertexColorsChecked = checkVertexColors(`${part.id} (import)`, root);
  return chunks;
}

function prepare() {
  const template = readJson(plan.templates.entity);
  const out = plan.preparedDir;
  const used = new Set();
  const manifest = { schema: 'open77.prop-package/1', resource: plan.resource, revision: plan.revision,
                     models: {}, nativeValidated: false, runtimeValidated: false, vehicleKit: { parts: {} } };
  for (const part of plan.parts) {
    const meta = readJson(part.meta);
    const doc = readJson(part.importedJson), root = doc.Data.RootChunk;
    const chunks = checkImported(part, meta, root);
    const finishes = Object.entries(part.finishes);
    if (!finishes.length) fail(`${part.id}: no finishes`);
    for (const [finish, slots] of finishes) {
      for (const s of meta.slots) if (!slots[s]) fail(`${part.id}/${finish}: slot '${s}' has no palette material`);
      for (const m of Object.values(slots)) used.add(m);
    }
    // Geometry-wide fixes, shared by every finish of the part.
    // Visual only (decision D5): no collision. The template's box collider is dropped.
    for (const key of ['parameters', 'boneNames', 'boneRigMatrices', 'boneVertexEpsilons', 'floatTrackNames', 'lodBoneMask', ...FORBIDDEN_LISTS])
      root[key] = [];
    const lodCount = Math.max(...meta.submeshes.map(s => s.lod));
    const distances = part.lodDistances.slice(0, lodCount);
    if (distances.length !== lodCount || distances[0] !== 0 || distances.some((d, i) => i && d <= distances[i - 1]))
      fail(`${part.id}: lodDistances must start at 0, increase, and give one entry per LOD (${lodCount})`);
    // WolvenKit writes [0, 0, ...]: every LOD would switch at 0 m and the finest never draw.
    root.lodLevelInfo = distances;
    root.renderResourceBlob.Data.header.renderLODs = distances;
    // The fields the template leaves at its own values, set as on the proven props.
    const finest = meta.lods[String(Math.min(...meta.submeshes.map(s => s.lod)))];
    const area = finest?.surfaceAreaPerAxis ?? fail(`${part.id}: part.json has no surfaceAreaPerAxis (stale Blender output?)`);
    const blob = root.renderResourceBlob.Data;
    Object.assign(root, { objectType: 'ROT_Static', isShadowMesh: 0, isPlayerShadowMesh: 0,
      castGlobalShadowsCachedInCook: 1, castLocalShadowsCachedInCook: 1, surfaceAreaPerAxis: vec3(...area),
      geometryHash: crypto.createHash('sha256').update(Buffer.from(blob.renderBuffer.Bytes, 'base64')).digest().readBigUInt64LE(0).toString() });
    blob.renderBuffer.BufferId = '1';
    // The box template leaves W at -inf in both quantization vectors; the proven props
    // decode W to a plain 1 (offset 1, scale 0). x, y, z stay as WolvenKit computed them.
    blob.header.quantizationOffset.W = 1;
    blob.header.quantizationScale.W = 0;

    const record = { kind: part.kind, materials: 'local', finishes: {}, lodDistances: distances,
                     triangles: Object.fromEntries(Object.entries(meta.lods).map(([l, v]) => [l, v.triangles])),
                     bounds: meta.bounds, mount: meta.mount ?? null, surfaceAreaPerAxis: area, geometryHash: root.geometryHash,
                     vertexColor: { rgba: 'ffffffff', verticesChecked: part.vertexColorsChecked } };
    for (const [finish, slots] of finishes) {
      // One mesh per model: its only appearance is `default`, its materials are this finish's.
      const id = modelId(part, finish), mesh = meshDepot(part, finish), depot = entDepot(part, finish);
      const fdoc = structuredClone(doc), froot = fdoc.Data.RootChunk;
      const names = [...new Set(meta.submeshes.map(s => slots[s.slot]))];
      froot.localMaterialBuffer = localMaterialBuffer(fdoc, names.map(materialInstance));
      froot.materialEntries = names.map((n, i) => ({ $type: 'CMeshMaterialEntry', index: i, isLocalInstance: 1, name: cname(n) }));
      // A HandleId no template handle uses; renumberHandles makes the ids sequential.
      froot.appearances = [{ HandleId: '900000', Data: { $type: 'meshMeshAppearance', name: cname('default'),
        chunkMaterials: meta.submeshes.map(s => cname(slots[s.slot])), tags: [] } }];
      checkLocalMaterials(`${id} (prepare)`, froot, names, false);
      fdoc.Header = { ...fdoc.Header, ArchiveFileName: mesh, ExportedDateTime: '2000-01-01T00:00:00Z' };
      fdoc.Data.EmbeddedFiles = [];
      checkReferences(`${id} mesh (prepare)`, fdoc);
      writeJson(depotFile(mesh, out), renumberHandles(fdoc));

      const ent = structuredClone(template);
      // Drop the template's embedded vanilla mesh and its two references (see checkReferences).
      ent.Data.EmbeddedFiles = [];
      ent.Data.RootChunk.inplaceResources = [];
      ent.Data.RootChunk.resolvedDependencies = [];
      let meshComponents = 0;
      for (const c of [...ent.Data.RootChunk.components, ...ent.Data.RootChunk.compiledData.Data.Chunks]) {
        if (c?.$type === 'gameinteractionsComponent') c.isEnabled = 0;
        if (c?.$type !== 'entMeshComponent') continue;
        meshComponents++;
        // forceLODLevel 0, as build-prop-hosts.ps1 does for every curated host (a multi-LOD
        // mesh attached to a hand fell off its own table there, measured 2026-09-19). Parity
        // only: the kit meshes have a single LOD, and revision b6722bed3fb6 at -1 already
        // drew attached (2026-11-05: wing on the root, rims at -0.6; at 0 0 0 a rim is only
        // buried in the stock wheel, which is what first read as "invisible").
        Object.assign(c, { name: cname('open77VehicleKitMesh'), mesh: resource(mesh), meshAppearance: cname('default'),
          visualScale: vec3(1, 1, 1), chunkMask: '18446744073709551615', autoHideDistance: plan.autoHideDistance,
          forceLODLevel: 0, castShadows: 'Always', castLocalShadows: 'Always' });
      }
      // Both the root list and the compiled chunk copy must change, or the game spawns the template mesh.
      if (meshComponents !== 2) fail('host template layout changed: expected 2 entMeshComponent copies');
      ent.Header = { ...ent.Header, ArchiveFileName: depot, ExportedDateTime: '2000-01-01T00:00:00Z' };
      checkReferences(`${id} host (prepare)`, ent);
      writeJson(depotFile(depot, out), renumberHandles(ent));
      if (manifest.models[id]) fail(`duplicate model id ${id}`);
      manifest.models[id] = { mesh, visualEntity: depot };
      record.finishes[finish] = { model: id, mesh, appearance: 'default', visualEntity: depot, materials: names };
    }
    manifest.vehicleKit.parts[part.id] = record;
    console.log(`VK_COOK_PART ${part.id}: ${chunks.length} chunks, LOD tris ${JSON.stringify(record.triangles)}, ` +
                `lods ${JSON.stringify(distances)}, finishes ${finishes.map(([f]) => f).join(',')}, ` +
                `local materials, PS_Color ffffffff on ${part.vertexColorsChecked} vertices`);
  }
  const all = Object.values(manifest.models).flatMap(m => [m.mesh, m.visualEntity]);
  const bases = new Map();
  for (const depot of new Set(all)) {
    const base = depot.split('\\').pop();
    if (bases.has(base)) fail(`two staged files share the basename ${base} (${bases.get(base)}, ${depot})`);
    bases.set(base, depot);
  }
  manifest.files = [...bases.values()].sort();
  writeJson(plan.packageOut, manifest);
  console.log(`VK_COOK_PREPARED revision=${plan.revision} models=${Object.keys(manifest.models).length} ` +
              `palette materials used=${used.size} (local, one mesh per model)`);
}

function validate() {
  const rt = plan.roundtripDir;
  const manifest = readJson(plan.packageOut);
  // `convert serialize <folder>` writes every file flat into its outpath, so the round
  // trip is looked up by basename; prepare() guarantees basenames are unique.
  const rel = depot => path.join(rt, depot.split('\\').pop() + '.json');
  const staged = depot => path.join(plan.stageDir, ...depot.split('\\'));
  let files = 0;
  for (const part of plan.parts) {
    const meta = readJson(part.meta);
    const rec = manifest.vehicleKit.parts[part.id];
    for (const [finish, slots] of Object.entries(part.finishes)) {
      const fin = rec.finishes[finish], label = `${fin.model} (round trip)`;
      const meshDoc = readJson(rel(fin.mesh)), mesh = meshDoc.Data.RootChunk; files++;
      checkReferences(`${label} mesh`, meshDoc);
      const q = mesh.renderResourceBlob.Data.header;
      if (q.quantizationOffset.W !== 1 || q.quantizationScale.W !== 0) fail(`${label}: quantization W ${q.quantizationOffset.W}/${q.quantizationScale.W}, expected 1/0`);
      const chunks = chunksOf(mesh);
      if (chunks.length !== meta.submeshes.length) fail(`${label}: lost chunks`);
      chunks.forEach((c, i) => { if (c.numIndices / 3 !== meta.submeshes[i].triangles) fail(`${label}: changed chunk ${i}`); });
      if (mesh.parameters.length) fail(`${label}: visual mesh carries collision parameters`);
      checkVertexColors(label, mesh);
      if (JSON.stringify(mesh.lodLevelInfo) !== JSON.stringify(rec.lodDistances)) fail(`${label}: lodLevelInfo lost`);
      if (JSON.stringify(mesh.renderResourceBlob.Data.header.renderLODs) !== JSON.stringify(rec.lodDistances)) fail(`${label}: renderLODs lost`);
      if (mesh.geometryHash !== rec.geometryHash) fail(`${label}: geometryHash ${mesh.geometryHash}, expected ${rec.geometryHash}`);
      if (mesh.castGlobalShadowsCachedInCook !== 1 || mesh.castLocalShadowsCachedInCook !== 1) fail(`${label}: shadow cook flags lost`);
      checkLocalMaterials(label, mesh, fin.materials, true);
      const want = meta.submeshes.map(s => slots[s.slot]);
      if (JSON.stringify(mesh.appearances[0].Data.chunkMaterials.map(c => c.$value)) !== JSON.stringify(want))
        fail(`${label}: appearance default lost its chunk materials`);
      checkBinaryMesh(fin.model, staged(fin.mesh));
      const entDoc = readJson(rel(fin.visualEntity)), ent = entDoc.Data.RootChunk; files++;
      checkReferences(`${fin.model} host (round trip)`, entDoc);
      if (ent.inplaceResources.length || ent.resolvedDependencies.length) fail(`${fin.model}: host lists template dependencies`);
      const comps = [...ent.components, ...ent.compiledData.Data.Chunks].filter(c => c?.$type?.endsWith('MeshComponent'));
      if (comps.length !== 2) fail(`${fin.model}: host lost a mesh component copy`);
      for (const c of comps) {
        if (c.$type !== 'entMeshComponent') fail(`${fin.model}: host is not a pure visual mesh component`);
        if (c.mesh.DepotPath.$value !== fin.mesh) fail(`${fin.model}: host points at ${c.mesh.DepotPath.$value}`);
        if (c.meshAppearance.$value !== 'default') fail(`${fin.model}: host appearance ${c.meshAppearance.$value}, expected default`);
        if (c.forceLODLevel !== 0) fail(`${fin.model}: host forceLODLevel ${c.forceLODLevel}, expected 0 (attached parts vanish otherwise)`);
      }
    }
  }
  console.log(`VK_COOK_ROUNDTRIP_OK parts=${plan.parts.length} checked=${files} (geometry, vertex colors, LOD table, ` +
              `local materials, binary markers, D6 references, appearances, visual hosts)`);
}

try { operation === 'prepare' ? prepare() : validate(); }
catch (e) { console.error(`VK_COOK_FAILED ${e.message}`); process.exit(1); }
