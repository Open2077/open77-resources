// Generates the WolvenKit JSON of an ArchiveXL lab pack from a spec and the vanilla
// resources the build read from the local game. Nothing here is committed output:
// the vanilla JSON comes in from artifacts/, the generated JSON goes back there.
//
//   node axl-generate.cjs <plan.json>                    generate
//   node axl-generate.cjs validate <plan.json> <dir>     check a WolvenKit round trip
//
// plan.json: { spec, prefix, outDir, vanilla: { ent, app, screenMesh? } }
//   spec        path of specs/<experiment>.json
//   prefix      depot folder of every generated resource (open77\assets\<resource>\<rev12>)
//   outDir      where <file>.<ext>.json are written (one folder: WolvenKit flattens on deserialize)
//   vanilla     WolvenKit JSON of the vanilla .ent, .app and, for E0.7, the screen mesh
//
// What it writes:
//   <app>.json        a standalone .app; each new definition is a deep copy of the
//                     spec's base definition with every handle renumbered, plus the
//                     spec's own components (vanilla meshes and widgets by depot path)
//   <entPatch>.json   an ArchiveXL patch .ent: only the new appearance entries and the
//                     entity visual tags, on a bare entEntity root; no component
//   <part>.json       optional part .ent files (our components only), for partsValues probes
//   generated.json    what was generated, for the build report (next to outDir)
// validate reads the JSON WolvenKit serialized back from the cooked files and checks
// that every entry, definition and added component survived, field by field.
// It prints AXL_GENERATED / AXL_ROUNDTRIP_OK on success and AXL_FAILED <reason> otherwise.
'use strict';
const fs = require('node:fs');
const path = require('node:path');

const FIXED_POINT = 131072;          // WorldPosition FixedPoint: Bits / 2^17 = metres

function fail(message) { throw new Error(message); }
function readJson(file) { return JSON.parse(fs.readFileSync(file, 'utf8')); }
function writeJson(file, value) { fs.writeFileSync(file, JSON.stringify(value, null, 2) + '\n', 'utf8'); }
function clone(value) { return JSON.parse(JSON.stringify(value)); }
function round(value, digits = 6) { const f = 10 ** digits; return Math.round(value * f) / f; }

// ----------------------------------------------------------------------------- RED4 JSON
const cname = (value) => ({ $type: 'CName', $storage: 'string', $value: value });
const resourcePath = (value) => value
  ? { $type: 'ResourcePath', $storage: 'string', $value: value }
  : { $type: 'ResourcePath', $storage: 'uint64', $value: '0' };
const resourceRef = (value, flags = 'Default') => ({ DepotPath: resourcePath(value), Flags: flags });
const tagList = (tags) => ({ $type: 'redTagList', tags: tags.map(cname) });
const tweakDbId0 = () => ({ $type: 'TweakDBID', $storage: 'uint64', $value: '0' });
const enableMask = () => ({ $type: 'entTagMask', excludedTags: tagList(['NoBinding']), hardTags: tagList([]), softTags: tagList([]) });
const fixed = (metres) => ({ $type: 'FixedPoint', Bits: Math.round(metres * FIXED_POINT) });

function yawQuaternion(degrees) {
  const d = ((degrees % 360) + 360) % 360;
  if (d === 0) return { i: 0, j: 0, k: 0, r: 1 };
  if (d === 180) return { i: 0, j: 0, k: 1, r: 0 };
  const h = (d * Math.PI) / 360;
  return { i: 0, j: 0, k: round(Math.sin(h), 9), r: round(Math.cos(h), 9) };
}

function worldTransform(position = [0, 0, 0], quaternion = { i: 0, j: 0, k: 0, r: 1 }) {
  return {
    $type: 'WorldTransform',
    Orientation: { $type: 'Quaternion', ...quaternion },
    Position: { $type: 'WorldPosition', x: fixed(position[0]), y: fixed(position[1]), z: fixed(position[2]) },
  };
}

function hardBinding(bindName, slotName) {
  return { $type: 'entHardTransformBinding', bindName: cname(bindName), enabled: 1, enableMask: enableMask(), slotName: cname(slotName || 'None') };
}

// 64-bit FNV-1a, sign bit cleared: a stable component id (CRUID) derived from our own names.
function componentId(text) {
  let h = 0xcbf29ce484222325n;
  for (const byte of Buffer.from(text, 'utf8')) {
    h ^= BigInt(byte);
    h = (h * 0x100000001b3n) & 0xffffffffffffffffn;
  }
  return (h & 0x7fffffffffffffffn).toString();
}

// ----------------------------------------------------------------------------- handles
class Handles {
  constructor(start) { this.next = start; }
  wrap(data) { return { HandleId: String(this.next++), Data: data }; }
  // Renumbers every HandleId of a subtree and rewrites the HandleRefIds that point into it.
  // A reference that leaves the subtree cannot be renumbered safely: refuse it.
  renumber(subtree) {
    const ids = new Map();
    const collect = (node) => {
      if (Array.isArray(node)) { node.forEach(collect); return; }
      if (!node || typeof node !== 'object') return;
      if (Object.prototype.hasOwnProperty.call(node, 'HandleId')) ids.set(node.HandleId, String(this.next++));
      Object.values(node).forEach(collect);
    };
    const rewrite = (node) => {
      if (Array.isArray(node)) { node.forEach(rewrite); return; }
      if (!node || typeof node !== 'object') return;
      if (Object.prototype.hasOwnProperty.call(node, 'HandleId')) node.HandleId = ids.get(node.HandleId);
      if (Object.prototype.hasOwnProperty.call(node, 'HandleRefId')) {
        if (!ids.has(node.HandleRefId)) fail(`handle reference ${node.HandleRefId} leaves the copied definition`);
        node.HandleRefId = ids.get(node.HandleRefId);
      }
      Object.values(node).forEach(rewrite);
    };
    collect(subtree);
    rewrite(subtree);
    return subtree;
  }
}

// Every serialized buffer (a definition's compiledData, for one) carries a BufferId, and
// WolvenKit wants them unique and numbered 0..n-1 in document order, like the game files.
// Copied definitions duplicate their source's id, so the whole document is renumbered.
function renumberBuffers(doc) {
  let next = 0;
  const visit = (n) => {
    if (Array.isArray(n)) { n.forEach(visit); return; }
    if (!n || typeof n !== 'object') return;
    if (Object.prototype.hasOwnProperty.call(n, 'BufferId')) n.BufferId = String(next++);
    Object.values(n).forEach(visit);
  };
  visit(doc);
  return doc;
}

function maxHandleId(node) {
  let max = 0;
  const visit = (n) => {
    if (Array.isArray(n)) { n.forEach(visit); return; }
    if (!n || typeof n !== 'object') return;
    if (Object.prototype.hasOwnProperty.call(n, 'HandleId')) max = Math.max(max, Number(n.HandleId));
    Object.values(n).forEach(visit);
  };
  visit(node);
  return max;
}

// The chunk carries the binding objects; the editor-side `components` entry refers to them,
// exactly like the vanilla definitions do.
function editorCopy(chunk) {
  const copy = {};
  for (const [key, value] of Object.entries(chunk)) {
    copy[key] = value && typeof value === 'object' && Object.prototype.hasOwnProperty.call(value, 'HandleId')
      ? { HandleRefId: value.HandleId }
      : clone(value);
  }
  return copy;
}

// ----------------------------------------------------------------------------- components
function meshComponent(handles, id, c, transform, scale) {
  return {
    $type: 'entMeshComponent',
    autoHideDistance: 0,
    castLocalShadows: 'Always',
    castRayTracedGlobalShadows: 'Always',
    castRayTracedLocalShadows: 'Default',
    castShadows: 'Always',
    chunkMask: '9223372036854775807',
    forcedLodDistance: 'Default',
    forceLODLevel: -1,
    id,
    isEnabled: 1,
    isReplicable: 0,
    localTransform: transform,
    LODMode: 'Appearance',
    mesh: resourceRef(c.mesh),
    meshAppearance: cname(c.meshAppearance || 'default'),
    motionBlurScale: 1,
    name: cname(c.name),
    navigationImpact: { $type: 'NavGenNavigationSetting', navmeshImpact: 'Ignored' },
    numInstances: 0,
    objectTypeID: 'ROT_Static',
    order: 0,
    overrideMeshNavigationImpact: 1,
    parentTransform: handles.wrap(hardBinding(c.bind, c.slot)),
    renderingPlane: 'RPl_Scene',
    renderSceneLayerMask: 'Default',
    version: 0,
    visualScale: { $type: 'Vector3', X: scale[0], Y: scale[1], Z: scale[2] },
  };
}

function widgetComponent(handles, id, c) {
  return {
    $type: 'WorldWidgetComponent',
    cursorResource: resourceRef(null),
    glitchValue: 0,
    id,
    isEnabled: 1,
    isReplicable: 0,
    itemNameToSpawn: cname(c.item || 'None'),
    // The vanilla interior UI of the same car sets 1; a plate must stay visible from outside.
    limitedSpawnDistanceFromVehicle: 0,
    localTransform: worldTransform(),
    meshTargetBinding: handles.wrap({ $type: 'worlduiMeshTargetBinding', bindName: cname(c.screen), enabled: 1, enableMask: enableMask() }),
    name: cname(c.name),
    parentTransform: handles.wrap(hardBinding(c.screen, null)),
    sceneWidgetProperties: {
      $type: 'worlduiSceneWidgetProperties',
      faceVector: { $type: 'Vector3', X: 0, Y: 0, Z: 0 },
      isAlwaysVisible: 0,
      isInteractable: 0,
      isInteractableFromBehind: 0,
      maxInteractionDistance: 0,
      overrideMaxInteractionDistance: 0,
      projectionPlaneSize: { $type: 'Vector2', X: 1, Y: 1 },
      renderingPlane: 'RPl_Scene',
      useCustomFaceVector: 0,
    },
    screenAreaMultiplier: 1,
    screenDefinition: { $type: 'SUIScreenDefinition', screenDefinition: tweakDbId0(), style: tweakDbId0() },
    spawnDistanceOverride: -1,
    staticTextureResource: resourceRef(null),
    textureMaxMipBias: 0,
    textureMinMipBias: 0,
    tintColor: { $type: 'Color', Alpha: 0, Blue: 0, Green: 0, Red: 0 },
    widgetResource: resourceRef(c.widget),
  };
}

// Fits the screen quad onto the plate rectangle, in the plate component's frame.
// visualScale applies in the quad's own frame, then the yaw, then the translation.
function plateFit(spec, screenBox, c) {
  const rect = spec.plate.rect;
  const plateW = rect.xMax - rect.xMin;
  const plateH = rect.zMax - rect.zMin;
  let width = plateW;
  let height = width / c.aspect;
  if (height > plateH) { height = plateH; width = height * c.aspect; }
  const center = [(rect.xMin + rect.xMax) / 2, spec.plate.faceY, (rect.zMin + rect.zMax) / 2];
  const q = { w: screenBox.Max.X - screenBox.Min.X, h: screenBox.Max.Z - screenBox.Min.Z };
  const qc = [(screenBox.Max.X + screenBox.Min.X) / 2, (screenBox.Max.Y + screenBox.Min.Y) / 2, (screenBox.Max.Z + screenBox.Min.Z) / 2];
  const scale = [round(width / q.w), 1, round(height / q.h)];
  const s = [qc[0] * scale[0], qc[1] * scale[1], qc[2] * scale[2]];
  const t = (c.yawDegrees * Math.PI) / 180;
  const rotated = [s[0] * Math.cos(t) - s[1] * Math.sin(t), s[0] * Math.sin(t) + s[1] * Math.cos(t), s[2]];
  const position = [round(center[0] - rotated[0]), round(center[1] - rotated[1]), round(center[2] - rotated[2])];
  return { position, scale, quaternion: yawQuaternion(c.yawDegrees), size: [round(width, 4), round(height, 4)], center: center.map((v) => round(v, 4)) };
}

function buildComponent(spec, handles, key, definitionName, context) {
  const c = spec.components[key];
  if (!c) fail(`unknown component key ${key}`);
  const id = componentId(`open77:${spec.resource}:${definitionName}:${c.name}`);
  if (c.type === 'entMeshComponent') {
    return { chunk: meshComponent(handles, id, c, worldTransform(c.position || [0, 0, 0], yawQuaternion(c.yawDegrees || 0)), c.scale || [1, 1, 1]), info: { key, name: c.name, type: c.type, mesh: c.mesh, meshAppearance: c.meshAppearance || 'default', bind: c.bind, slot: c.slot || null } };
  }
  if (c.type === 'plateScreen') {
    if (!context.screenBox) fail('plateScreen needs vanilla.screenMesh');
    const fit = plateFit(spec, context.screenBox, c);
    const mesh = { name: c.name, mesh: spec.screenMesh.path, meshAppearance: spec.screenMesh.appearance, bind: spec.plate.component, slot: null };
    const chunk = meshComponent(handles, id, mesh, worldTransform(fit.position, fit.quaternion), fit.scale);
    chunk.castShadows = 'Never';
    chunk.castLocalShadows = 'Never';
    return { chunk, info: { key, name: c.name, type: 'entMeshComponent', mesh: spec.screenMesh.path, meshAppearance: spec.screenMesh.appearance, bind: spec.plate.component, yawDegrees: c.yawDegrees, ...fit } };
  }
  if (c.type === 'WorldWidgetComponent') {
    return { chunk: widgetComponent(handles, id, c), info: { key, name: c.name, type: c.type, widget: c.widget, item: c.item, textPath: c.textPath, screen: c.screen } };
  }
  fail(`component ${key}: unsupported type ${c.type}`);
}

// An entity template with a bare entEntity root and the given components: the shape
// WolvenKit gives a new .ent. Every vanilla field of the copied skeleton is emptied, so
// a patch or part template carries no game data at all. (A template with no entity and
// no component serializes to a package WolvenKit itself cannot read back.)
function blankTemplate(root, handles, chunks) {
  const entity = { $type: 'entEntity' };
  root.entity = handles.wrap(clone(entity));
  root.components = chunks.map(editorCopy);
  root.compiledData.Data = {
    Version: 4, Sections: 6, CruidIndex: 0,
    CruidDict: Object.fromEntries([['0', '0'], ...chunks.map((c, i) => [String(i + 1), c.id])]),
    Chunks: [entity, ...chunks],
  };
  for (const key of ['backendDataOverrides', 'bindingOverrides', 'componentResolveSettings', 'includes', 'inplaceResources', 'resolvedDependencies']) root[key] = [];
  root.localData = null;
  root.includeInstanceBuffer = null;
  root.defaultAppearance = cname('None');
}

// ----------------------------------------------------------------------------- main
function main() {
  const planFile = process.argv[2];
  if (!planFile) fail('usage: axl-generate.cjs <plan.json>');
  const plan = readJson(planFile);
  const spec = readJson(plan.spec);
  if (spec.schema !== 'open77.vehicle-kit.archivexl/1') fail(`unexpected spec schema ${spec.schema}`);
  const prefix = plan.prefix;
  if (!/^open77\\assets\\[a-z0-9_]+\\[0-9a-f]{12}$/.test(prefix)) fail(`unexpected depot prefix ${prefix}`);
  fs.mkdirSync(plan.outDir, { recursive: true });

  const entDoc = readJson(plan.vanilla.ent);
  const appDoc = readJson(plan.vanilla.app);
  const ent = entDoc.Data.RootChunk;
  const app = appDoc.Data.RootChunk;
  if (ent.$type !== 'entEntityTemplate') fail('vanilla .ent is not an entEntityTemplate');
  if (app.$type !== 'appearanceAppearanceResource') fail('vanilla .app is not an appearanceAppearanceResource');

  const context = {};
  if (plan.vanilla.screenMesh) {
    const mesh = readJson(plan.vanilla.screenMesh).Data.RootChunk;
    const box = mesh.boundingBox;
    if (Math.abs(box.Max.Y - box.Min.Y) > 0.001) fail('the screen mesh is not a flat XZ quad');
    const appearance = (mesh.appearances || []).find((a) => a.Data.name.$value === spec.screenMesh.appearance);
    if (!appearance) fail(`the screen mesh has no appearance ${spec.screenMesh.appearance}`);
    const entryNames = appearance.Data.chunkMaterials.map((m) => m.$value);
    const materials = mesh.localMaterialBuffer.materials;
    const bases = entryNames.map((n) => {
      const entry = mesh.materialEntries.find((e) => e.name.$value === n);
      const m = materials[entry.index];
      return (m.Data || m).baseMaterial.DepotPath.$value;
    });
    if (!bases.every((b) => b === 'base\\materials\\screen\\screen_ui.mi')) fail(`screen appearance does not use screen_ui.mi: ${bases.join(', ')}`);
    context.screenBox = box;
    context.screenMaterials = bases;
  }

  // ArchiveXL 1.28.0+Open77 (src/App/Extensions/ResourcePatch/Extension.cpp, the visualTags
  // branch of the .ent patch) assigns an EMPTY handle when the target has no
  // visualTagsSchema and then writes through it: a null dereference on the first load of
  // the vanilla entity, i.e. a client crash as soon as any such car streams in.
  if ((spec.entityVisualTags || []).length && !ent.visualTagsSchema) {
    fail(`${spec.entity} has no visualTagsSchema: patching entity visual tags onto it crashes ArchiveXL 1.28.0+Open77 (null handle); leave entityVisualTags empty`);
  }

  // Base entry and definition.
  const baseEntry = ent.appearances.find((a) => a.name.$value === spec.baseEntry);
  if (!baseEntry) fail(`vanilla .ent has no appearance entry ${spec.baseEntry}`);
  if (baseEntry.appearanceName.$value !== spec.baseDefinition) fail(`${spec.baseEntry} maps to ${baseEntry.appearanceName.$value}, not ${spec.baseDefinition}`);
  if (baseEntry.appearanceResource.DepotPath.$value !== spec.appearanceResource) fail(`${spec.baseEntry} uses ${baseEntry.appearanceResource.DepotPath.$value}`);
  const baseWrapper = app.appearances.find((a) => a.Data.name.$value === spec.baseDefinition);
  if (!baseWrapper) fail(`vanilla .app has no definition ${spec.baseDefinition}`);
  const baseChunks = baseWrapper.Data.compiledData.Data.Chunks;
  const baseNames = new Set(baseChunks.map((c) => c.name.$value));
  const existingEntries = new Set(ent.appearances.map((a) => a.name.$value));
  const existingDefinitions = new Set(app.appearances.map((a) => a.Data.name.$value));

  const appPath = `${prefix}\\${spec.outputs.app}`;
  const entPatchPath = `${prefix}\\${spec.outputs.entPatch}`;
  const partPaths = {};
  for (const [key, part] of Object.entries(spec.parts || {})) partPaths[key] = `${prefix}\\${part.file}`;

  // Standalone .app: vanilla root fields, our definitions only.
  const appOut = clone(appDoc);
  const appRoot = appOut.Data.RootChunk;
  const rootWithoutDefinitions = { ...appRoot, appearances: [] };
  const handles = new Handles(maxHandleId(rootWithoutDefinitions) + 1);
  appRoot.appearances = [];
  const report = { experiment: spec.experiment, resource: spec.resource, prefix, files: [], entries: [], definitions: [] };

  for (const a of spec.appearances) {
    if (existingDefinitions.has(a.definition)) fail(`definition ${a.definition} already exists in the vanilla .app`);
    if (a.entry && existingEntries.has(a.entry)) fail(`entry ${a.entry} already exists in the vanilla .ent`);
    const wrapper = handles.renumber(clone(baseWrapper));
    const def = wrapper.Data;
    def.name = cname(a.definition);
    def.parentAppearance = cname('None');
    const pkg = def.compiledData.Data;
    if (pkg.Chunks.length !== def.components.length) fail('base definition: compiledData and components disagree');
    const added = [];
    const addedNames = new Set();
    for (const key of a.add || []) {
      const built = buildComponent(spec, handles, key, a.definition, context);
      const name = built.chunk.name.$value;
      if (baseNames.has(name) || addedNames.has(name)) fail(`${a.definition}: component name ${name} is not unique`);
      const bind = built.chunk.parentTransform.Data.bindName.$value;
      if (!(spec.entityBindNames || []).includes(bind) && !baseNames.has(bind) && !addedNames.has(bind)) {
        fail(`${a.definition}: ${name} binds to ${bind}, which is neither an entity slot nor a component of ${spec.baseDefinition}`);
      }
      if (built.chunk.$type === 'WorldWidgetComponent' && !addedNames.has(built.chunk.meshTargetBinding.Data.bindName.$value)) {
        fail(`${a.definition}: widget ${name} targets a screen that is not added before it`);
      }
      pkg.CruidDict[String(pkg.Chunks.length)] = built.chunk.id;
      pkg.Chunks.push(built.chunk);
      def.components.push(editorCopy(built.chunk));
      addedNames.add(name);
      added.push(built.info);
    }
    const parts = (a.partsValues || []).map((key) => {
      if (!partPaths[key]) fail(`${a.definition}: unknown part ${key}`);
      return partPaths[key];
    });
    if (parts.length) def.partsValues = parts.map((p) => ({ $type: 'appearanceAppearancePart', resource: resourceRef(p) }));
    if (a.visualTags && a.visualTags.length) {
      const tags = def.visualTags.tags.map((t) => t.$value);
      for (const t of a.visualTags) if (!tags.includes(t)) def.visualTags.tags.push(cname(t));
    }
    appRoot.appearances.push(wrapper);
    report.definitions.push({ name: a.definition, base: spec.baseDefinition, components: pkg.Chunks.length, added, partsValues: parts, visualTags: def.visualTags.tags.map((t) => t.$value), expect: a.expect });
  }
  appOut.Header.ArchiveFileName = appPath;
  writeJson(path.join(plan.outDir, `${spec.outputs.app}.json`), renumberBuffers(appOut));
  report.files.push(appPath);

  // Patch .ent: the new entries and the entity visual tags, nothing else.
  const entOut = clone(entDoc);
  const entRoot = entOut.Data.RootChunk;
  const entHandles = new Handles(1);
  entRoot.appearances = spec.appearances.filter((a) => a.entry).map((a) => {
    report.entries.push({ name: a.entry, appearanceResource: appPath, appearanceName: a.definition });
    return { $type: 'entTemplateAppearance', appearanceName: cname(a.definition), appearanceResource: resourceRef(appPath, 'Soft'), name: cname(a.entry) };
  });
  blankTemplate(entRoot, entHandles, []);
  entRoot.visualTagsSchema = (spec.entityVisualTags || []).length
    ? entHandles.wrap({ $type: 'entVisualTagsSchema', visualTags: tagList(spec.entityVisualTags) })
    : null;
  entOut.Header.ArchiveFileName = entPatchPath;
  writeJson(path.join(plan.outDir, `${spec.outputs.entPatch}.json`), renumberBuffers(entOut));
  report.files.push(entPatchPath);

  // Part .ent files: a bare entEntity root and our components only.
  for (const [key, part] of Object.entries(spec.parts || {})) {
    const partOut = clone(entDoc);
    const partRoot = partOut.Data.RootChunk;
    const partHandles = new Handles(1);
    const chunks = part.components.map((ck) => buildComponent(spec, partHandles, ck, `part:${key}`, context).chunk);
    partRoot.appearances = [];
    blankTemplate(partRoot, partHandles, chunks);
    partRoot.visualTagsSchema = null;
    partOut.Header.ArchiveFileName = partPaths[key];
    writeJson(path.join(plan.outDir, `${part.file}.json`), renumberBuffers(partOut));
    report.files.push(partPaths[key]);
    (report.parts = report.parts || []).push({ path: partPaths[key], components: chunks.map((c) => c.name.$value) });
  }

  report.app = appPath;
  report.entPatch = entPatchPath;
  report.entityVisualTags = spec.entityVisualTags || [];
  if (context.screenMaterials) report.screenMaterials = context.screenMaterials;
  report.files.sort();
  writeJson(path.join(plan.outDir, '..', 'generated.json'), report);
  console.log(`AXL_GENERATED files=${report.files.length} definitions=${report.definitions.length} entries=${report.entries.length}`);
}

// ----------------------------------------------------------------------------- validate
function findJson(dir, depotPath) {
  const leaf = `${depotPath.split('\\').pop()}.json`;
  const hits = [];
  const walk = (d) => {
    for (const e of fs.readdirSync(d, { withFileTypes: true })) {
      const p = path.join(d, e.name);
      if (e.isDirectory()) walk(p);
      else if (e.name === leaf) hits.push(p);
    }
  };
  walk(dir);
  if (hits.length !== 1) fail(`round trip: ${hits.length} files named ${leaf}`);
  return readJson(hits[0]).Data.RootChunk;
}

function validate(planFile, roundTripDir) {
  const plan = readJson(planFile);
  const report = readJson(path.join(plan.outDir, '..', 'generated.json'));
  const same = (a, b, what) => { if (JSON.stringify(a) !== JSON.stringify(b)) fail(`round trip: ${what}: ${JSON.stringify(a)} != ${JSON.stringify(b)}`); };
  const near = (a, b, what) => { if (Math.abs(a - b) > 1e-4) fail(`round trip: ${what}: ${a} != ${b}`); };

  const ent = findJson(roundTripDir, report.entPatch);
  same(ent.appearances.map((a) => [a.name.$value, a.appearanceName.$value, a.appearanceResource.DepotPath.$value]),
    report.entries.map((e) => [e.name, e.appearanceName, e.appearanceResource]), 'patch .ent entries');
  same(ent.visualTagsSchema ? ent.visualTagsSchema.Data.visualTags.tags.map((t) => t.$value) : [], report.entityVisualTags, 'entity visual tags');
  if (ent.components.length !== 0) fail('round trip: the patch .ent carries components');

  const app = findJson(roundTripDir, report.app);
  same(app.appearances.map((a) => a.Data.name.$value), report.definitions.map((d) => d.name), 'definition names');
  let checked = 0;
  for (const d of report.definitions) {
    const def = app.appearances.find((a) => a.Data.name.$value === d.name).Data;
    const chunks = def.compiledData.Data.Chunks;
    same(chunks.length, d.components, `${d.name} component count`);
    same(def.components.length, d.components, `${d.name} editor component count`);
    same(def.partsValues.map((p) => p.resource.DepotPath.$value), d.partsValues, `${d.name} partsValues`);
    same(def.visualTags.tags.map((t) => t.$value), d.visualTags, `${d.name} visual tags`);
    for (const a of d.added) {
      const c = chunks.find((x) => x.name.$value === a.name);
      if (!c) fail(`round trip: ${d.name} lost ${a.name}`);
      same(c.$type, a.type, `${d.name}/${a.name} type`);
      if (a.type === 'entMeshComponent') {
        same(c.mesh.DepotPath.$value, a.mesh, `${d.name}/${a.name} mesh`);
        same(c.meshAppearance.$value, a.meshAppearance, `${d.name}/${a.name} mesh appearance`);
        same(c.parentTransform.Data.bindName.$value, a.bind, `${d.name}/${a.name} binding`);
        if (a.scale) ['X', 'Y', 'Z'].forEach((k, i) => near(c.visualScale[k], a.scale[i], `${d.name}/${a.name} scale ${k}`));
        if (a.position) ['x', 'y', 'z'].forEach((k, i) => near(c.localTransform.Position[k].Bits / FIXED_POINT, a.position[i], `${d.name}/${a.name} position ${k}`));
      } else {
        same(c.widgetResource.DepotPath.$value, a.widget, `${d.name}/${a.name} widget`);
        same(c.itemNameToSpawn.$value, a.item, `${d.name}/${a.name} item`);
        same(c.meshTargetBinding.Data.bindName.$value, a.screen, `${d.name}/${a.name} mesh target`);
        same(c.parentTransform.Data.bindName.$value, a.screen, `${d.name}/${a.name} binding`);
      }
      checked++;
    }
  }
  for (const p of report.parts || []) {
    const part = findJson(roundTripDir, p.path);
    same(part.compiledData.Data.Chunks.filter((c) => c.name).map((c) => c.name.$value), p.components, `part ${p.path}`);
  }
  console.log(`AXL_ROUNDTRIP_OK entries=${report.entries.length} definitions=${report.definitions.length} components=${checked} parts=${(report.parts || []).length}`);
}

try {
  if (process.argv[2] === 'validate') validate(process.argv[3], process.argv[4]);
  else main();
} catch (e) {
  console.error(`AXL_FAILED ${e.message}`);
  process.exit(1);
}
