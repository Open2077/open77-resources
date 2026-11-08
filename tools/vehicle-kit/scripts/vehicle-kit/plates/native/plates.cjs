// Generator of the production plate pack (route W). Reads the vanilla appearance
// resources and meshes that build-plates.ps1 extracted from the local game (git-ignored
// artifacts), measures where a plate is, and writes the WolvenKit JSON of OUR files only:
//
//   * one ArchiveXL patch .app per vanilla .app. Each patch definition carries the NAME of a
//     vanilla definition and nothing of it: its compiled package holds our components only
//     (a screen quad over the plate, a WorldWidgetComponent drawing an .inkwidget on it, and
//     for a plate-less definition a mount: the vanilla plate mesh, by depot path). ArchiveXL
//     merges them into that definition when an entity is built (see the README for the
//     source lines). Every root field of the patch .app is an empty default.
//   * optionally our own .inkwidget (design "original"), built from scratch.
//
//   node plates.cjs survey   <plan.json>                  which meshes the generator needs
//   node plates.cjs generate <plan.json>                  write the JSON + reports (+ print-leak proof)
//   node plates.cjs validate <plan.json> <roundTripDir>   check the WolvenKit round trip
//   node plates.cjs scan     <plan.json> <dir>            no-vanilla-bytes scan of cooked files
//   node plates.cjs data     <plan.json> <outDir>         the committed per-model plate table
//   node plates.cjs views    <plan.json> <previewDir>     before/after renders of each plate mesh
//
// plan.json: { spec, design, variant, prefix, outDir, reportDir,
//              apps: { depot: json }, ents: { depot: json }, meshJson: { depot: json },
//              glb: { depot: glb }, vanillaFiles: [ raw extracted files, for scan ] }
// Prints PLATES_SURVEYED / PLATES_GENERATED / PLATES_ROUNDTRIP_OK / PLATES_SCAN_OK /
// PLATES_VIEWS on success and PLATES_FAILED <reason> otherwise.
'use strict';
const fs = require('node:fs');
const path = require('node:path');
const crypto = require('node:crypto');
const G = require('./geometry.cjs');
const ink = require('./inkwidget.cjs');
const cover = require('./cover.cjs');
const png = require('./png.cjs');
const scanRule = require('./scan-rule.cjs');

const BS = '\\';
// Row statuses of a definition that get a patch definition.
const PATCHED = new Set(['plate', 'mount', 'front-only']);
function fail(message) { throw new Error(message); }
function readJson(file) { return JSON.parse(fs.readFileSync(file, 'utf8')); }
function writeJson(file, value) { fs.mkdirSync(path.dirname(file), { recursive: true }); fs.writeFileSync(file, JSON.stringify(value, null, 2) + '\n', 'utf8'); }
function round(v, d = 6) { const f = 10 ** d; return Math.round(v * f) / f; }
const r4 = (v) => round(v, 4);
const leaf = (p) => p.split(BS).pop();
const str = (x) => (x && (x.$value !== undefined ? x.$value : x.DepotPath && x.DepotPath.$value)) || '';

// ----------------------------------------------------------------------------- RED4 JSON
const cname = (value) => ({ $type: 'CName', $storage: 'string', $value: value });
const resourcePath = (value) => value
  ? { $type: 'ResourcePath', $storage: 'string', $value: value }
  : { $type: 'ResourcePath', $storage: 'uint64', $value: '0' };
const resourceRef = (value, flags = 'Default') => ({ DepotPath: resourcePath(value), Flags: flags });
const tagList = (tags) => ({ $type: 'redTagList', tags: tags.map(cname) });
const tweakDbId0 = () => ({ $type: 'TweakDBID', $storage: 'uint64', $value: '0' });
const enableMask = () => ({ $type: 'entTagMask', excludedTags: tagList(['NoBinding']), hardTags: tagList([]), softTags: tagList([]) });
const fixed = (metres) => ({ $type: 'FixedPoint', Bits: Math.round(metres * G.FIXED_POINT) });
const PACKAGE_TYPE = 'WolvenKit.RED4.Archive.Buffer.RedPackage, WolvenKit.RED4, Version=8.20.0.0, Culture=neutral, PublicKeyToken=null';
const HEADER = (archiveFileName) => ({
  WolvenKitVersion: '8.20.0', WKitJsonVersion: '0.0.9', GameVersion: 2310,
  ExportedDateTime: '2000-01-01T00:00:00Z', DataType: 'CR2W', ArchiveFileName: archiveFileName,
});

function worldTransform(t) {
  return {
    $type: 'WorldTransform',
    Orientation: { $type: 'Quaternion', i: round(t.q.i, 9), j: round(t.q.j, 9), k: round(t.q.k, 9), r: round(t.q.r, 9) },
    Position: { $type: 'WorldPosition', x: fixed(t.p[0]), y: fixed(t.p[1]), z: fixed(t.p[2]) },
  };
}
const hardBinding = (bindName) => ({ $type: 'entHardTransformBinding', bindName: cname(bindName), enabled: 1, enableMask: enableMask(), slotName: cname('None') });

// 64-bit FNV-1a, sign bit cleared: a stable component id (CRUID) derived from our own names.
function componentId(text) {
  let h = 0xcbf29ce484222325n;
  for (const byte of Buffer.from(text, 'utf8')) { h ^= BigInt(byte); h = (h * 0x100000001b3n) & 0xffffffffffffffffn; }
  return (h & 0x7fffffffffffffffn).toString();
}

// WolvenKit writes a ResourcePath it has no name for (our own .inkwidget) back as its hash:
// FNV-1a 64 of the depot path. Compare paths through this.
function pathHash(text) {
  let h = 0xcbf29ce484222325n;
  for (const byte of Buffer.from(text, 'utf8')) { h ^= BigInt(byte); h = (h * 0x100000001b3n) & 0xffffffffffffffffn; }
  return h.toString();
}
const pathKey = (x) => { const v = x && (x.$value !== undefined ? x : x.DepotPath); return !v ? '' : v.$storage === 'uint64' ? v.$value : pathHash(v.$value); };

class Handles {
  constructor(start = 0) { this.next = start; }
  wrap(data) { return { HandleId: String(this.next++), Data: data }; }
}
// The chunk owns the binding objects; the editor-side `components` entry refers to them, as in
// the game's own definitions.
function editorCopy(chunk) {
  const copy = {};
  for (const [key, value] of Object.entries(chunk)) {
    copy[key] = value && typeof value === 'object' && Object.prototype.hasOwnProperty.call(value, 'HandleId')
      ? { HandleRefId: value.HandleId } : JSON.parse(JSON.stringify(value));
  }
  return copy;
}
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

// chunkMask: bit n set = chunk n drawn. The vanilla default draws every chunk (bit 63 is
// left clear by the game's own files); burnt definitions hide their plate with 0.
const ALL_CHUNKS = '9223372036854775807';
const maskWithout = (chunks) => (BigInt(ALL_CHUNKS) & ~chunks.reduce((m, c) => m | (1n << BigInt(c)), 0n)).toString();

function meshComponent(h, o) {
  return {
    $type: 'entMeshComponent',
    autoHideDistance: 0,
    castLocalShadows: o.shadows ? 'Always' : 'Never',
    castRayTracedGlobalShadows: 'Always',
    castRayTracedLocalShadows: 'Default',
    castShadows: o.shadows ? 'Always' : 'Never',
    chunkMask: o.chunkMask || ALL_CHUNKS,
    forcedLodDistance: 'Default',
    forceLODLevel: -1,
    id: o.id,
    isEnabled: o.enabled ? 1 : 0,
    isReplicable: 0,
    localTransform: worldTransform(o.transform),
    LODMode: 'Appearance',
    mesh: resourceRef(o.mesh),
    meshAppearance: cname(o.meshAppearance),
    motionBlurScale: 1,
    name: cname(o.name),
    navigationImpact: { $type: 'NavGenNavigationSetting', navmeshImpact: 'Ignored' },
    numInstances: 0,
    objectTypeID: 'ROT_Static',
    order: 0,
    overrideMeshNavigationImpact: 1,
    parentTransform: h.wrap(hardBinding(o.bind)),
    renderingPlane: 'RPl_Scene',
    renderSceneLayerMask: 'Default',
    version: 0,
    visualScale: { $type: 'Vector3', X: o.scale[0], Y: o.scale[1], Z: o.scale[2] },
  };
}

// Modelled on the vehicles' own interior_ui widgets (sub-agent H, E0.7, proven in game).
function widgetComponent(h, o) {
  return {
    $type: 'WorldWidgetComponent',
    cursorResource: resourceRef(null),
    glitchValue: 0,
    id: o.id,
    isEnabled: o.enabled ? 1 : 0,
    isReplicable: 0,
    itemNameToSpawn: cname(o.item),
    limitedSpawnDistanceFromVehicle: 0,
    localTransform: worldTransform(G.tIdentity()),
    meshTargetBinding: h.wrap({ $type: 'worlduiMeshTargetBinding', bindName: cname(o.screen), enabled: 1, enableMask: enableMask() }),
    name: cname(o.name),
    parentTransform: h.wrap(hardBinding(o.screen)),
    sceneWidgetProperties: {
      $type: 'worlduiSceneWidgetProperties',
      faceVector: { $type: 'Vector3', X: 0, Y: 0, Z: 0 },
      isAlwaysVisible: 0, isInteractable: 0, isInteractableFromBehind: 0, maxInteractionDistance: 0,
      overrideMaxInteractionDistance: 0, projectionPlaneSize: { $type: 'Vector2', X: 1, Y: 1 },
      renderingPlane: 'RPl_Scene', useCustomFaceVector: 0,
    },
    screenAreaMultiplier: 1,
    screenDefinition: { $type: 'SUIScreenDefinition', screenDefinition: tweakDbId0(), style: tweakDbId0() },
    spawnDistanceOverride: -1,
    staticTextureResource: resourceRef(null),
    textureMaxMipBias: 0,
    textureMinMipBias: 0,
    tintColor: { $type: 'Color', Alpha: 0, Blue: 0, Green: 0, Red: 0 },
    widgetResource: resourceRef(o.widget),
  };
}

// A definition that adds components and nothing else. Every field the game reads from a
// vanilla definition (proxy mesh, tags, parts, dependencies, LOD distance) is empty: the
// patch merges only `components` into the target (props: appearances, components).
function patchDefinition(h, name, chunks) {
  return h.wrap({
    $type: 'appearanceAppearanceDefinition',
    censorFlags: 0,
    compiledData: {
      BufferId: '0', Flags: 0, Type: PACKAGE_TYPE,
      Data: { Version: 4, Sections: 7, CruidIndex: -1, CruidDict: Object.fromEntries(chunks.map((c, i) => [String(i), c.id])), Chunks: chunks },
    },
    components: chunks.map(editorCopy),
    cookedDataPathOverride: resourceRef(null, 'Soft'),
    forcedLodDistance: 0,
    hitRepresentationOverrides: [],
    inheritedVisualTags: tagList([]),
    looseDependencies: [],
    name: cname(name),
    parametersBuffer: { $type: 'entEntityParametersBuffer', parameterBuffers: [] },
    parentAppearance: cname('None'),
    partsMasks: [],
    partsOverrides: [],
    partsValues: [],
    proxyMesh: resourceRef(null, 'Soft'),
    proxyMeshAppearance: cname('None'),
    resolvedDependencies: [],
    visualTags: tagList([]),
  });
}

function patchApp(depotPath, definitions) {
  return {
    Header: HEADER(depotPath),
    Data: {
      Version: 195, BuildVersion: 0,
      RootChunk: {
        $type: 'appearanceAppearanceResource',
        alternateAppearanceMapping: [],
        alternateAppearanceSettingName: cname('None'),
        alternateAppearanceSuffixes: [],
        appearances: definitions,
        baseEntity: resourceRef(null, 'Soft'),
        baseEntityType: cname('None'),
        baseType: cname('None'),
        censorshipMapping: [],
        commonCookData: resourceRef(null, 'Soft'),
        cookingPlatform: 'PLATFORM_PC',
        DismEffects: [],
        DismWoundConfig: { $type: 'entdismembermentWoundsConfigSet', Configs: [] },
        forceCompileProxy: 0,
        generatePlayerBlockingCollisionForProxy: 0,
        partType: cname('None'),
        preset: cname('None'),
        proxyPolyCount: 0,
        Wounds: [],
      },
      EmbeddedFiles: [],
    },
  };
}

// ----------------------------------------------------------------------------- measurement
// The holo layer of each plate mesh, the quad over it and the proof that no print shows
// around the quad live in cover.cjs.

// The screen quad's own reading frame, from its UVs (H measured: u grows towards -X, seen from +Y).
function measureScreen(chunks) {
  const P = chunks.flatMap((c) => c.positions);
  const uv = chunks.flatMap((c) => c.uvs || []);
  if (uv.length !== P.length || !P.length) fail('screen quad: no UVs');
  const lo = [0, 1, 2].map((i) => Math.min(...P.map((p) => p[i])));
  const hi = [0, 1, 2].map((i) => Math.max(...P.map((p) => p[i])));
  if (hi[1] - lo[1] > 0.001) fail('the screen mesh is not a flat XZ quad');
  const du = G.gradient(P, uv.map((t) => t[0]));
  const dv = G.gradient(P, uv.map((t) => t[1]));
  const right = [Math.sign(du[0]) || 1, 0, 0];
  const up = [0, 0, dv[2] < 0 ? 1 : -1];
  const normal = G.cross(right, up);
  return { size: [hi[0] - lo[0], hi[2] - lo[2]], center: [(lo[0] + hi[0]) / 2, (lo[1] + hi[1]) / 2, (lo[2] + hi[2]) / 2], right, up, normal };
}

// Everything the generator, the proof and the previews need about one plate mesh: the holo
// measurement, the cover placement and its transform, the superseded fit placement, the
// widget item layout, and the print-leak test of both placements.
function plateMaterials(plan, depot) {
  const mj = readJson(plan.meshJson[depot]).Data.RootChunk;
  const def = (mj.appearances || []).find((a) => str(a.Data.name) === 'default');
  if (!def) fail(`${leaf(depot)}: no default appearance`);
  return def.Data.chunkMaterials.map(str);
}

function plateSetup(plan, spec, glbs, screen, screenChunks, depot, withLeaks) {
  const cfg = spec.plateMeshes[depot];
  const chunks = glbs[depot] || fail(`no glb for ${depot}`);
  const materials = plateMaterials(plan, depot);
  if (!/holo/i.test(materials[cfg.holoChunk] || '')) fail(`${leaf(depot)}: chunk ${cfg.holoChunk} uses material ${materials[cfg.holoChunk]}, not a holo layer`);
  const pl = spec.placement;
  const plate = cover.measurePlate(depot, chunks, cfg, materials, pl);
  const placed = cover.coverPlacement(plate, chunks, materials, pl);
  const fit = cover.quadTransform(plate, screen, placed);
  fit.corners = cover.quadCorners(fit, screenChunks);
  const legacy = cover.legacyPlacement(plate, cfg.legacyAspect, pl);
  const legacyFit = cover.quadTransform(plate, screen, legacy);
  legacyFit.corners = cover.quadCorners(legacyFit, screenChunks);
  const layout = ink.layoutFor(cfg.item, cfg.style, placed.rect, plate.face);
  const out = {
    plate, material: materials[cfg.holoChunk], item: cfg.item, layout,
    cover: { ...placed, fit, frontal: cover.frontalMargins(plate, fit) },
    legacy: { ...legacy, fit: legacyFit, frontal: cover.frontalMargins(plate, legacyFit) },
    mountChunkMask: pl.mountHidesHolo ? maskWithout([cfg.holoChunk]) : ALL_CHUNKS,
  };
  if (withLeaks) {
    const opts = { step: pl.leakStepMetres, sideAngles: pl.leakSideDegrees, coneAngles: pl.leakConeDegrees, azimuths: pl.leakAzimuths };
    out.cover.leak = cover.leakTest(plate, chunks, materials, cover.quadTriangles(fit, screenChunks), opts);
    out.legacy.leak = cover.leakTest(plate, chunks, materials, cover.quadTriangles(legacyFit, screenChunks), opts);
    if (out.cover.leak.cone.viewsWithPrint) fail(`${leaf(depot)}: factory print visible around the quad in ${out.cover.leak.cone.viewsWithPrint} of ${out.cover.leak.cone.views} views within ${pl.coverMaxViewDegrees} degrees: ${JSON.stringify(out.cover.leak.cone.worst)}`);
  }
  return out;
}

// The report's per-mesh record: numbers only, no geometry.
function plateRecord(s) {
  const placement = (p) => ({
    rule: p.rule, depthMm: cover.mm(p.depth), gapMm: p.gap !== undefined ? cover.mm(p.gap) : undefined, marginMm: p.margin !== undefined ? cover.mm(p.margin) : undefined,
    aspect: p.aspect, pushes: p.pushes, sizeMm: p.fit.size.map(cover.mm), scale: p.fit.scale, position: p.fit.transform.p.map(r4), frontal: p.frontal, leak: p.leak,
  });
  const P = s.plate;
  return {
    holoChunk: P.holoChunk, material: s.material, bent: P.bent, width: P.width, height: P.height, center: P.center, normal: P.N, up: P.U,
    holoDepthMm: [cover.mm(P.holoBack), cover.mm(P.holoFront)], item: s.item, layout: s.layout, mountChunkMask: s.mountChunkMask,
    cover: placement(s.cover), legacy: placement(s.legacy),
  };
}

// ----------------------------------------------------------------------------- survey
function chunksOf(definition) { return definition.compiledData.Data.Chunks; }
function bindingOf(c) {
  const b = c.parentTransform && c.parentTransform.Data;
  return b ? { bind: str(b.bindName), slot: str(b.slotName) === 'None' ? null : str(b.slotName) } : null;
}
// Walks a component's binding chain up to the entity slot component ("vehicle_slots" or the
// like: a name that is not a component of this definition). Returns the slot and the
// component's transform in that slot's frame.
function chainToSlot(byName, c) {
  let t = G.fromWorldTransform(c.localTransform);
  let cur = c;
  const via = [];
  for (let depth = 0; depth < 16; depth++) {
    const b = bindingOf(cur);
    if (!b) return { slot: null, root: null, t, via };
    const parent = byName.get(b.bind);
    if (!parent) return { slot: b.slot, root: b.bind, t, via };
    via.push(b.bind);
    t = G.tCompose(G.fromWorldTransform(parent.localTransform), t);
    cur = parent;
  }
  fail('binding chain too deep');
}

function survey(plan, spec) {
  const plateMeshes = new Set(Object.keys(spec.plateMeshes));
  const exclude = new RegExp(spec.excludeDefinitions || '^$');
  const apps = {};
  const neededMeshes = new Set();
  for (const model of spec.models) {
    for (const appPath of model.apps) {
      if (apps[appPath]) continue;
      const json = plan.apps[appPath];
      if (!json) fail(`no vanilla JSON for ${appPath}`);
      const app = readJson(json).Data.RootChunk;
      if (app.$type !== 'appearanceAppearanceResource') fail(`${appPath} is not an appearance resource`);
      const defs = [];
      for (const w of app.appearances) {
        const d = w.Data;
        const chunks = chunksOf(d);
        const byName = new Map(chunks.filter((c) => c.name).map((c) => [str(c.name), c]));
        const plates = chunks.filter((c) => c.mesh && plateMeshes.has(str(c.mesh))).map((c) => {
          const chain = chainToSlot(byName, c);
          const own = G.fromWorldTransform(c.localTransform);
          const yaw = G.qYawDegrees(chain.t.q);
          return {
            name: str(c.name), type: c.$type, mesh: str(c.mesh), meshAppearance: str(c.meshAppearance), enabled: c.isEnabled === 1,
            bind: bindingOf(c), local: { p: own.p.map(r4), q: own.q }, slot: chain.slot, slotRoot: chain.root, via: chain.via,
            inSlot: { p: chain.t.p.map(r4), q: chain.t.q }, yaw: round(yaw, 2), side: Math.abs(yaw) < 90 ? 'rear' : 'front',
          };
        });
        // Rear bumper candidates: mesh components chained to a bumper/trunk slot.
        const bumpers = chunks.filter((c) => c.mesh && /^ent(Physical|Skinned)?MeshComponent$/.test(c.$type) && !plateMeshes.has(str(c.mesh)))
          .map((c) => ({ c, chain: chainToSlot(byName, c) }))
          .filter(({ c, chain }) => chain.slot && !/shadow/i.test(str(c.name) + str(c.mesh)))
          .map(({ c, chain }) => ({ name: str(c.name), mesh: str(c.mesh), slot: chain.slot, slotRoot: chain.root, inSlot: chain.t, direct: chain.via.length === 0 }));
        defs.push({ name: str(d.name), excluded: exclude.test(str(d.name)), plates, bumpers, componentNames: [...byName.keys()] });
      }
      apps[appPath] = { definitions: defs };
    }
  }
  // Mount candidates: a definition with no rear plate, a sibling with a rear plate on a slot
  // this definition has a bumper on.
  for (const [appPath, a] of Object.entries(apps)) {
    for (const d of a.definitions) {
      if (d.excluded || d.plates.some((p) => p.side === 'rear')) continue;
      for (const s of a.definitions) {
        const ref = s.plates.find((p) => p.side === 'rear' && p.slot);
        if (!ref) continue;
        const bumper = d.bumpers.find((b) => b.slot === ref.slot && b.slotRoot === ref.slotRoot && b.direct);
        if (bumper) neededMeshes.add(bumper.mesh);
      }
    }
  }
  return { apps, neededMeshes: [...neededMeshes].sort() };
}

// ----------------------------------------------------------------------------- generate
function entriesOf(plan, spec) {
  const out = {};
  for (const model of spec.models) {
    const json = plan.ents[model.entity];
    if (!json) fail(`no vanilla JSON for ${model.entity}`);
    const ent = readJson(json).Data.RootChunk;
    out[model.key] = ent.appearances.map((a) => ({ entry: str(a.name), app: str(a.appearanceResource), definition: str(a.appearanceName) }));
  }
  return out;
}

function computeMount(appData, d, spec, plateInfo, glbs) {
  const tries = [];
  // Most common rear placement among siblings, per slot.
  const refs = new Map();
  for (const s of appData.definitions) {
    for (const p of s.plates.filter((x) => x.side === 'rear' && x.slot)) {
      const key = JSON.stringify([p.slot, p.slotRoot, p.mesh, p.inSlot.p, [p.inSlot.q.i, p.inSlot.q.j, p.inSlot.q.k, p.inSlot.q.r].map(r4)]);
      const e = refs.get(key) || { p, count: 0, from: [] };
      e.count++; e.from.push(s.name); refs.set(key, e);
    }
  }
  const ordered = [...refs.values()].sort((a, b) => b.count - a.count);
  for (const ref of ordered) {
    const bumper = d.bumpers.find((b) => b.slot === ref.p.slot && b.slotRoot === ref.p.slotRoot && b.direct);
    if (!bumper) { tries.push({ ref: ref.from[0], why: `no rear bumper on slot ${ref.p.slot}` }); continue; }
    const chunks = glbs[bumper.mesh];
    if (!chunks) { tries.push({ ref: ref.from[0], why: `no geometry for ${leaf(bumper.mesh)}` }); continue; }
    const plate = plateInfo[ref.p.mesh].plate;
    const T = { p: ref.p.inSlot.p, q: ref.p.inSlot.q };              // plate in slot frame
    const toBumper = G.tInvert(bumper.inSlot);                          // slot -> bumper mesh frame
    const xs = [plate.bbox.min[0] + 0.01, (plate.bbox.min[0] + plate.bbox.max[0]) / 2, plate.bbox.max[0] - 0.01];
    const zs = [plate.bbox.min[2] + 0.01, (plate.bbox.min[2] + plate.bbox.max[2]) / 2, plate.bbox.max[2] - 0.01];
    const hits = [];
    let centerHit = false;
    for (const [xi, x] of xs.entries()) {
      for (const [zi, z] of zs.entries()) {
        const o = G.tPoint(toBumper, G.tPoint(T, [x, -1, z]));
        const dir = G.tDir(toBumper, G.tDir(T, [0, 1, 0]));
        const t = G.rayMesh(o, dir, chunks);
        if (t !== null && t < 1.5) { hits.push(-1 + t); if (xi === 1 && zi === 1) centerHit = true; }
      }
    }
    if (!centerHit || hits.length < spec.placement.mountMinHits) { tries.push({ ref: ref.from[0], why: `bumper ${leaf(bumper.mesh)} hit by ${hits.length}/9 rays, centre ${centerHit}` }); continue; }
    const shift = Math.min(...hits) - plate.bbox.max[1] - spec.placement.mountGapMetres;
    if (Math.abs(shift) > spec.placement.mountMaxShiftMetres) { tries.push({ ref: ref.from[0], why: `shift ${r4(shift)} m exceeds ${spec.placement.mountMaxShiftMetres}` }); continue; }
    const inSlot = G.tCompose(T, { p: [0, shift, 0], q: G.qIdentity() });
    const inBumper = G.tCompose(toBumper, inSlot);
    return { ok: true, bind: bumper.name, bumperMesh: bumper.mesh, mesh: ref.p.mesh, meshAppearance: ref.p.meshAppearance, reference: { definitions: ref.from.slice(0, 4), count: ref.count, plate: ref.p.name }, shift: r4(shift), hits: hits.length, transform: { p: inBumper.p.map((v) => round(v)), q: inBumper.q } };
  }
  return { ok: false, tries };
}

function generate(plan) {
  const spec = readJson(plan.spec);
  if (spec.schema !== 'open77.vehicle-kit.plates/1') fail(`unexpected spec schema ${spec.schema}`);
  if (!/^open77\\assets\\[a-z0-9_]+\\[0-9a-f]{12}$/.test(plan.prefix)) fail(`unexpected depot prefix ${plan.prefix}`);
  const design = spec.designs[plan.design];
  if (!design) fail(spec.retiredDesigns && spec.retiredDesigns[plan.design] ? `design ${plan.design} is retired: ${spec.retiredDesigns[plan.design].why}` : `unknown design ${plan.design}`);
  if (!design.generated) fail(`design ${plan.design} has no generated widget: the cover rule needs a widget authored at each quad's aspect`);
  if (spec.placement.rule !== 'cover') fail(`unexpected placement rule ${spec.placement.rule}`);
  const variant = spec.variants[plan.variant];
  if (!variant) fail(`unknown variant ${plan.variant}`);
  const names = spec.componentNames;
  const sv = survey(plan, spec);
  const glbs = Object.fromEntries(Object.entries(plan.glb).map(([depot, file]) => [depot, G.readGlb(file)]));
  const screenChunks = glbs[spec.screenMesh.path] || fail('no screen glb');
  const screen = measureScreen(screenChunks);
  // The quad's material: screen_ui.mi in the chosen mesh appearance (H's check, repeated).
  const screenJson = readJson(plan.meshJson[spec.screenMesh.path]).Data.RootChunk;
  const sApp = (screenJson.appearances || []).find((a) => str(a.Data.name) === spec.screenMesh.appearance);
  if (!sApp) fail(`screen mesh has no appearance ${spec.screenMesh.appearance}`);
  for (const m of sApp.Data.chunkMaterials) {
    const entry = screenJson.materialEntries.find((e) => str(e.name) === str(m));
    const mat = screenJson.localMaterialBuffer.materials[entry.index];
    if (str((mat.Data || mat).baseMaterial) !== spec.screenMesh.material) fail(`screen appearance uses ${str((mat.Data || mat).baseMaterial)}`);
  }
  // One placement per plate mesh: every definition that shows that mesh gets the same quad
  // in the plate's own frame (the quad binds to the plate component, or to our mount).
  const plateInfo = {};
  for (const depot of Object.keys(spec.plateMeshes)) {
    const s = plateSetup(plan, spec, glbs, screen, screenChunks, depot, true);
    plateInfo[depot] = s;
    const f = (x) => `${x.frontal.top}/${x.frontal.bottom}/${x.frontal.left}/${x.frontal.right}`;
    console.log(`PLATES_COVER ${leaf(depot)} quad=${s.cover.fit.size.map(cover.mm).join('x')}mm depth=${cover.mm(s.cover.depth)} gap=${cover.mm(s.cover.gap)} margin=${cover.mm(s.cover.margin)} item=${s.item} ${s.layout.w}x${s.layout.h} print-views=${s.cover.leak.cone.viewsWithPrint}/${s.cover.leak.cone.views} | before: quad=${s.legacy.fit.size.map(cover.mm).join('x')}mm frontal-uncovered(t/b/l/r)=${f(s.legacy)} print-views=${s.legacy.leak.cone.viewsWithPrint}/${s.legacy.leak.cone.views}`);
  }
  const items = new Set();
  for (const s of Object.values(plateInfo)) { if (items.has(s.item)) fail(`two plate meshes share the item ${s.item}`); items.add(s.item); }
  const widgetPath = `${plan.prefix}${BS}${design.generated}`;
  const entries = entriesOf(plan, spec);
  const files = [];
  const report = {
    design: plan.design, variant: plan.variant, prefix: plan.prefix, widget: widgetPath, screen,
    placement: { rule: spec.placement.rule, coverMaxViewDegrees: spec.placement.coverMaxViewDegrees, proudMetres: spec.placement.proudMetres, mountHidesHolo: spec.placement.mountHidesHolo },
    plates: Object.fromEntries(Object.entries(plateInfo).map(([depot, s]) => [depot, plateRecord(s)])),
    legacyItems: ink.LEGACY_LAYOUTS, apps: {}, models: [], files,
  };
  fs.mkdirSync(plan.outDir, { recursive: true });

  const typeOf = new Map();
  for (const m of spec.models) for (const a of m.apps) typeOf.set(a, m.type);
  for (const [appPath, appData] of Object.entries(sv.apps)) {
    const bike = typeOf.get(appPath) === 'Bike';
    const h = new Handles(0);
    const definitions = [];
    const rows = [];
    for (const d of appData.definitions) {
      const row = { definition: d.name, status: 'none', components: [] };
      rows.push(row);
      if (d.excluded) { row.status = 'excluded'; continue; }
      const chunks = [];
      const id = (n) => componentId(`open77:plates:${leaf(appPath)}:${d.name}:${n}`);
      const addPair = (suffix, bind, plateMesh, why) => {
        const s = plateInfo[plateMesh] || fail(`${d.name}: no placement for ${leaf(plateMesh)}`);
        const fit = s.cover.fit;
        const sName = names.screen + suffix, tName = names.text + suffix;
        for (const n of [sName, tName]) if (d.componentNames.includes(n)) fail(`${d.name}: ${n} already exists`);
        chunks.push(meshComponent(h, { id: id(sName), name: sName, mesh: spec.screenMesh.path, meshAppearance: spec.screenMesh.appearance, bind, transform: fit.transform, scale: fit.scale, enabled: variant.screen, shadows: false }));
        chunks.push(widgetComponent(h, { id: id(tName), name: tName, widget: widgetPath, item: s.item, screen: sName, enabled: variant.text }));
        row.components.push({ screen: sName, text: tName, bind, plateMesh: leaf(plateMesh), item: s.item, size: fit.size, scale: fit.scale, position: fit.transform.p.map(r4), orientation: [fit.transform.q.i, fit.transform.q.j, fit.transform.q.k, fit.transform.q.r].map(r4), why });
      };
      const rear = d.plates.find((p) => p.side === 'rear');
      if (rear) {
        row.status = 'plate';
        row.rear = { component: rear.name, bind: rear.bind, mesh: leaf(rear.mesh), slot: rear.slot, via: rear.via, inSlot: rear.inSlot.p, yaw: rear.yaw };
        addPair('', rear.name, rear.mesh, 'rear plate');
      } else {
        const mount = computeMount(appData, d, spec, plateInfo, glbs);
        if (mount.ok) {
          row.status = 'mount';
          // Our own mounted plate shows no print at all: its holo chunk is masked out.
          const chunkMask = plateInfo[mount.mesh].mountChunkMask;
          row.mount = { bind: mount.bind, mesh: mount.mesh, bumperMesh: leaf(mount.bumperMesh), reference: mount.reference, shift: mount.shift, hits: mount.hits, position: mount.transform.p.map(r4), chunkMask };
          chunks.push(meshComponent(h, { id: id(names.mount), name: names.mount, mesh: mount.mesh, meshAppearance: mount.meshAppearance || 'default', bind: mount.bind, transform: mount.transform, scale: [1, 1, 1], enabled: variant.mount, shadows: true, chunkMask }));
          addPair('', names.mount, mount.mesh, 'mount (no factory rear plate)');
        } else {
          row.status = 'none';
          row.why = mount.tries.length ? mount.tries : 'no rear plate and no sibling placement';
        }
      }
      const front = d.plates.find((p) => p.side === 'front');
      if (front) {
        row.front = { component: front.name, bind: front.bind, mesh: leaf(front.mesh), slot: front.slot, inSlot: front.inSlot.p, yaw: front.yaw };
        if (spec.front) {
          addPair(names.frontSuffix, front.name, front.mesh, 'front plate');
          // A factory front plate and no rear one (nor a mount): the text goes on the front only.
          if (row.status === 'none') row.status = 'front-only';
        }
      }
      if (d.plates.filter((p) => p.side === 'rear').length > 1) row.extraRear = d.plates.filter((p) => p.side === 'rear').slice(1).map((p) => p.name);
      if (chunks.length) definitions.push(patchDefinition(h, d.name, chunks));
    }
    const out = `${plan.prefix}${BS}${leaf(appPath)}`;
    if (definitions.length) {
      writeJson(path.join(plan.outDir, `${leaf(appPath)}.json`), renumberBuffers(patchApp(out, definitions)));
      files.push(out);
    }
    report.apps[appPath] = { patch: definitions.length ? out : null, bike, definitions: rows };
  }

  // Coverage of the entries a dealer car can wear: its player entry and its curated trims.
  for (const model of spec.models) {
    const list = entries[model.key];
    const check = (entry, role) => {
      const e = list.find((x) => x.entry === entry);
      if (!e) return { entry, role, status: 'missing-entry' };
      const app = report.apps[e.app];
      if (!app) return { entry, role, app: e.app, definition: e.definition, status: 'app-not-in-spec' };
      const row = app.definitions.find((x) => x.definition === e.definition);
      return { entry, role, app: leaf(e.app), definition: e.definition, status: row ? row.status : 'missing-definition', front: !!(row && row.front) };
    };
    report.models.push({
      key: model.key, label: model.label, type: model.type, record: model.record,
      player: check(model.playerEntry, 'player'),
      trims: (model.trims || []).map((t) => check(t, 'trim')),
      apps: model.apps.map((a) => {
        const r = report.apps[a].definitions;
        const count = (s) => r.filter((x) => x.status === s).length;
        return { app: leaf(a), definitions: r.length, plate: count('plate'), mount: count('mount'), frontOnly: count('front-only'), none: count('none'), excluded: count('excluded'), front: r.filter((x) => x.front && x.status !== 'none' && x.status !== 'excluded').length };
      }),
    });
  }

  // The library: one item per plate mesh, in spec order, each at its quad's aspect.
  const layouts = Object.values(plateInfo).map((s) => s.layout);
  writeJson(path.join(plan.outDir, `${design.generated}.json`), ink.library(widgetPath, design, HEADER(widgetPath), layouts));
  files.push(widgetPath);
  report.inkwidget = widgetPath;
  report.items = layouts;
  files.sort();
  writeJson(path.join(plan.reportDir, 'generated.json'), report);
  console.log(`PLATES_GENERATED files=${files.length} apps=${Object.keys(report.apps).length} definitions=${Object.values(report.apps).reduce((s, a) => s + a.definitions.filter((d) => PATCHED.has(d.status)).length, 0)}`);
}

// ----------------------------------------------------------------------------- validate
function findJson(dir, depotPath) {
  const name = `${leaf(depotPath)}.json`;
  const hits = [];
  const walk = (d) => { for (const e of fs.readdirSync(d, { withFileTypes: true })) { const p = path.join(d, e.name); if (e.isDirectory()) walk(p); else if (e.name === name) hits.push(p); } };
  walk(dir);
  if (hits.length !== 1) fail(`round trip: ${hits.length} files named ${name}`);
  return readJson(hits[0]).Data.RootChunk;
}

// Everything a patch .app may contain. Anything else would be copied game data.
const ALLOWED_TYPES = new Set(['appearanceAppearanceResource', 'appearanceAppearanceDefinition', 'entMeshComponent', 'WorldWidgetComponent',
  'entHardTransformBinding', 'worlduiMeshTargetBinding', 'entdismembermentWoundsConfigSet', 'entEntityParametersBuffer', 'redTagList', 'entTagMask',
  'CName', 'ResourcePath', 'WorldTransform', 'Quaternion', 'WorldPosition', 'FixedPoint', 'Vector3', 'Vector2', 'Color', 'NavGenNavigationSetting',
  'worlduiSceneWidgetProperties', 'SUIScreenDefinition', 'TweakDBID']);

function structuralCheck(root, allowedResources, ourNames, file) {
  const visit = (n, where) => {
    if (Array.isArray(n)) { n.forEach((x, i) => visit(x, `${where}[${i}]`)); return; }
    if (!n || typeof n !== 'object') return;
    if (n.$type && !ALLOWED_TYPES.has(n.$type)) fail(`${file}: unexpected type ${n.$type} at ${where}`);
    if (n.$type === 'ResourcePath' && n.$storage === 'string' && !allowedResources.has(n.$value)) fail(`${file}: unexpected resource ${n.$value} at ${where}`);
    if (n.$type === 'ResourcePath' && n.$storage === 'uint64' && n.$value !== '0' && ![...allowedResources].some((r) => pathHash(r) === n.$value)) fail(`${file}: unexpected resource hash ${n.$value} at ${where}`);
    for (const [k, v] of Object.entries(n)) visit(v, `${where}.${k}`);
  };
  visit(root, 'root');
  for (const w of root.appearances) for (const c of w.Data.compiledData.Data.Chunks) if (!ourNames.test(str(c.name))) fail(`${file}: component ${str(c.name)} is not ours`);
}

function validate(plan, roundTripDir) {
  const spec = readJson(plan.spec);
  const report = readJson(path.join(plan.reportDir, 'generated.json'));
  const same = (a, b, what) => { if (JSON.stringify(a) !== JSON.stringify(b)) fail(`round trip: ${what}: ${JSON.stringify(a)} != ${JSON.stringify(b)}`); };
  const near = (a, b, what) => { if (Math.abs(a - b) > 1e-4) fail(`round trip: ${what}: ${a} != ${b}`); };
  const names = spec.componentNames;
  const ours = new RegExp(`^(${[names.screen, names.text, names.mount].join('|')})(${names.frontSuffix})?$`);
  const allowed = new Set([spec.screenMesh.path, ...Object.keys(spec.plateMeshes), report.widget]);
  let components = 0, definitions = 0;
  for (const [appPath, a] of Object.entries(report.apps)) {
    if (!a.patch) continue;
    const vanilla = readJson(plan.apps[appPath]).Data.RootChunk;
    const vanillaNames = new Set(vanilla.appearances.map((w) => str(w.Data.name)));
    const root = findJson(roundTripDir, a.patch);
    structuralCheck(root, allowed, ours, leaf(a.patch));
    const expected = a.definitions.filter((d) => PATCHED.has(d.status));
    same(root.appearances.map((w) => str(w.Data.name)), expected.map((d) => d.definition), `${leaf(a.patch)} definition names`);
    for (const w of root.appearances) {
      const d = w.Data;
      if (!vanillaNames.has(str(d.name))) fail(`${leaf(a.patch)}: ${str(d.name)} is not a definition of ${leaf(appPath)} (ArchiveXL would ADD it)`);
      for (const k of ['partsValues', 'partsOverrides', 'resolvedDependencies', 'looseDependencies']) if (d[k].length) fail(`${str(d.name)}: ${k} is not empty`);
      const proxy = d.proxyMesh && d.proxyMesh.DepotPath;
      if (d.visualTags.tags.length || (proxy && !(proxy.$storage === 'uint64' && proxy.$value === '0'))) fail(`${str(d.name)}: carries tags or a proxy`);
      const row = expected.find((x) => x.definition === str(d.name));
      const chunks = d.compiledData.Data.Chunks;
      same(d.components.length, chunks.length, `${str(d.name)} editor/compiled component count`);
      const wanted = [...(row.status === 'mount' ? [names.mount] : []), ...row.components.flatMap((p) => [p.screen, p.text])];
      same(chunks.map((c) => str(c.name)), wanted, `${str(d.name)} components`);
      for (const p of row.components) {
        const s = chunks.find((c) => str(c.name) === p.screen);
        const t = chunks.find((c) => str(c.name) === p.text);
        same(str(s.parentTransform.Data.bindName), p.bind, `${str(d.name)}/${p.screen} binding`);
        ['x', 'y', 'z'].forEach((k, i) => near(s.localTransform.Position[k].Bits / G.FIXED_POINT, p.position[i], `${str(d.name)}/${p.screen} position ${k}`));
        ['X', 'Y', 'Z'].forEach((k, i) => near(s.visualScale[k], p.scale[i], `${str(d.name)}/${p.screen} scale ${k}`));
        same(pathKey(t.widgetResource), pathHash(report.widget), `${str(d.name)}/${p.text} widget (${report.widget})`);
        same(str(t.itemNameToSpawn), p.item, `${str(d.name)}/${p.text} item`);
        same(str(t.meshTargetBinding.Data.bindName), p.screen, `${str(d.name)}/${p.text} target`);
        same(t.isEnabled, spec.variants[report.variant].text ? 1 : 0, `${str(d.name)}/${p.text} isEnabled`);
        same(s.isEnabled, spec.variants[report.variant].screen ? 1 : 0, `${str(d.name)}/${p.screen} isEnabled`);
        components += 2;
      }
      if (row.status === 'mount') {
        const m = chunks.find((c) => str(c.name) === names.mount);
        same(str(m.parentTransform.Data.bindName), row.mount.bind, `${str(d.name)} mount binding`);
        same(m.isEnabled, spec.variants[report.variant].mount ? 1 : 0, `${str(d.name)} mount isEnabled`);
        same(String(m.chunkMask), row.mount.chunkMask, `${str(d.name)} mount chunkMask`);
        components++;
      }
      definitions++;
    }
  }
  if (report.inkwidget) ink.validate(findJson(roundTripDir, report.inkwidget), spec.designs[report.design], report.items);
  console.log(`PLATES_ROUNDTRIP_OK definitions=${definitions} components=${components}${report.inkwidget ? ' inkwidget=ok' : ''}`);
}

// ----------------------------------------------------------------------------- scan
// No vanilla bytes: no cooked file of ours may share a 64-byte block with a vanilla file
// the build read. Every 64-byte window of our files is hashed; every 64-byte block of each
// vanilla file is looked up. Blocks that are all one byte value are not evidence and skipped.
function scan(plan, dir) {
  const W = 64;
  const ourFiles = [];
  const walk = (d) => { for (const e of fs.readdirSync(d, { withFileTypes: true })) { const p = path.join(d, e.name); if (e.isDirectory()) walk(p); else ourFiles.push(p); } };
  walk(dir);
  const windows = new Map();
  const key = (buf) => crypto.createHash('sha1').update(buf).digest('base64');
  let total = 0;
  for (const f of ourFiles) {
    const b = fs.readFileSync(f);
    total += b.length;
    for (let i = 0; i + W <= b.length; i++) { const k = key(b.subarray(i, i + W)); if (!windows.has(k)) windows.set(k, { file: f, offset: i }); }
  }
  const ourHashes = new Set(ourFiles.map((f) => crypto.createHash('sha256').update(fs.readFileSync(f)).digest('hex')));
  const hits = [];
  for (const v of plan.vanillaFiles) {
    const b = fs.readFileSync(v);
    if (ourHashes.has(crypto.createHash('sha256').update(b).digest('hex'))) fail(`scan: ${path.basename(v)} is shipped verbatim`);
    for (let i = 0; i + W <= b.length; i += W) {
      const block = b.subarray(i, i + W);
      if (block.every((x) => x === block[0])) continue;
      const k = key(block);
      if (windows.has(k)) {
        const ascii = block.every((x) => x === 0 || (x >= 0x20 && x < 0x7f));
        const ours = windows.get(k);
        hits.push({ where: `${path.basename(v)}@${i} = ${path.basename(ours.file)}@${ours.offset}`, vanilla: { file: v, buf: b, offset: i }, ours, ascii, counting: !ascii && isCounting(block), text: ascii ? block.toString('latin1') : '' });
      }
    }
  }
  // A shared block made only of printable ASCII and NULs is a run of names: RED4 type and
  // property names, the vanilla definition names a patch must carry, referenced depot paths.
  // That vocabulary is what referencing by name means; the structural round-trip check
  // already proves which names our files hold. Any other shared block fails.
  // A block whose 32-bit words count up by a constant step (0x1b, 0x1c, 0x1d ...) is an
  // index table of the CR2W container: two files of similar size share it whatever they hold.
  // A block inside an `array:handle:*` property of two .app files, made of at most the size
  // and count words then one +1 run of chunk references, is a list of N objects stored in
  // chunks 2..N+1 (scan-rule.cjs states the three conditions and why that is layout).
  const vocabulary = [], counting = [], indexRun = [], binary = [];
  const ruleCache = new Map(), ourBuffers = new Map();
  for (const h of hits) {
    if (h.ascii) { vocabulary.push(h); continue; }
    if (h.counting) { counting.push(h); continue; }
    if (!ourBuffers.has(h.ours.file)) ourBuffers.set(h.ours.file, fs.readFileSync(h.ours.file));
    h.reason = scanRule.sharedIndexBlockReason(h.vanilla, { file: h.ours.file, buf: ourBuffers.get(h.ours.file), offset: h.ours.offset }, W, ruleCache);
    (h.reason ? binary : indexRun).push(h);
  }
  const names = new Set();
  for (const h of vocabulary) for (const s of h.text.split('\0')) if (s.length >= 4) names.add(s);
  if (plan.reportDir) writeJson(path.join(plan.reportDir, 'scan.json'), { window: W, ourFiles: ourFiles.map((f) => path.basename(f)), vanillaFiles: plan.vanillaFiles.length, binary: binary.map((h) => `${h.where} (${h.reason})`), counting: counting.map((h) => h.where), handleIndexRuns: indexRun.map((h) => h.where), vocabulary: vocabulary.length, names: [...names].sort() });
  if (binary.length) fail(`scan: ${binary.length} binary 64-byte blocks of vanilla files found in our files: ${binary.slice(0, 8).map((h) => `${h.where} (${h.reason})`).join('; ')}`);
  console.log(`PLATES_SCAN_OK ours=${ourFiles.length} files ${total} bytes, vanilla=${plan.vanillaFiles.length} files, shared content blocks=0, shared name blocks=${vocabulary.length} (${names.size} names), shared index-run blocks=${counting.length}, shared handle-index blocks=${indexRun.length}`);
}

function isCounting(block) {
  for (const big of [false, true]) {
    for (let a = 0; a < 4; a++) {
      const words = [];
      for (let o = a; o + 4 <= block.length; o += 4) words.push(big ? block.readUInt32BE(o) : block.readUInt32LE(o));
      const step = words[1] - words[0];
      if (step !== 0 && words.every((w, i) => i === 0 || w - words[i - 1] === step)) return true;
    }
  }
  return false;
}

// ----------------------------------------------------------------------------- data
// The committed per-model table (data/plates-dealer-2.50.json + .md), from a build's report.
// Definitions that place the plate the same way are grouped. Only names, depot paths and
// measured numbers: no game bytes.
function data(plan, outDir) {
  const spec = readJson(plan.spec);
  const report = readJson(path.join(plan.reportDir, 'generated.json'));
  const groupRows = (rows) => {
    const groups = new Map();
    for (const r of rows) {
      const { definition, components, ...rest } = r;
      const quads = (components || []).map(({ screen, text, bind, plateMesh, size }) => ({ screen, text, bind, plateMesh, size }));
      const key = JSON.stringify({ ...rest, quads });
      const g = groups.get(key) || { ...rest, quads, definitions: [] };
      g.definitions.push(definition);
      groups.set(key, g);
    }
    return [...groups.values()];
  };
  const out = {
    schema: 'open77.vehicle-kit.plates-data/1',
    generatedBy: 'scripts/vehicle-kit/plates/build-plates.ps1 -UpdateData',
    design: report.design,
    frames: 'Engine axes, metres: X right, Y forward, Z up. Plate rectangles are in the plate mesh frame (the holo layer reads correctly from -Y). inSlot is the plate component in the frame of the entity slot its binding chain ends on (vehicle_slots for most cars). yaw ~0 = rear plate, ~180 = front.',
    plates: report.plates,
    quadPlacement: { ...report.placement, rule: spec.placement.rule, coverExtraMetres: spec.placement.coverExtraMetres, clearanceMetres: spec.placement.clearanceMetres, note: spec.placement.note },
    models: report.models.map((m) => ({
      ...m,
      apps: spec.models.find((x) => x.key === m.key).apps.map((a) => ({ app: a, ...m.apps.find((s) => s.app === leaf(a)), groups: groupRows(report.apps[a].definitions) })),
    })),
  };
  writeJson(path.join(outDir, 'plates-dealer-2.50.json'), out);

  const md = [];
  const fmt = (v) => v.map((x) => x.toFixed(3)).join(', ');
  md.push(`# Plate data of the ${out.models.length} models of the plate spec: the Light RP dealer models, the staff-only Caliburn and every other vanilla player vehicle except the quest variants (game 2.50)`, '');
  md.push('Generated by `scripts/vehicle-kit/plates/build-plates.ps1 -UpdateData` from the local game files; do not edit by hand.');
  md.push(`Design used for the quad sizes: \`${report.design}\`. ${out.frames}`, '');
  md.push('## Plate meshes: the holo rectangle and the quad over it', '');
  md.push(`Cover rule: the quad lies ${spec.placement.proudMetres * 1000} mm in front of the holo's outermost point and covers the holo grown on every side by gap x tan ${spec.placement.coverMaxViewDegrees} deg + ${spec.placement.coverExtraMetres * 1000} mm (gap: quad to deepest holo point). The widget item has the quad's aspect and draws the design inside the holo rectangle.`, '');
  md.push('| Mesh | Holo chunk | Holo w x h (mm) | Holo depth range (mm) | Bent | Quad w x h (mm) | Quad depth / gap (mm) | Margin (mm) | Item (px) | Mount chunkMask |', '|---|---|---|---|---|---|---|---|---|---|');
  for (const [depot, p] of Object.entries(out.plates)) {
    const c = p.cover;
    md.push(`| \`${leaf(depot)}\` | ${p.holoChunk} | ${(p.width * 1000).toFixed(1)} x ${(p.height * 1000).toFixed(1)} | ${p.holoDepthMm[0]} .. ${p.holoDepthMm[1]} | ${p.bent ? 'yes (chord)' : 'no'} | ${c.sizeMm[0]} x ${c.sizeMm[1]} | ${c.depthMm} / ${c.gapMm} | ${c.marginMm} | \`${p.item}\` ${p.layout.w}x${p.layout.h}, face ${p.layout.face.w}x${p.layout.face.h} at ${p.layout.face.x},${p.layout.face.y} | \`${p.mountChunkMask}\` |`);
  }
  md.push('', '## Factory print left visible around the quad: before (fit rule, 2026-11-05) and after (cover rule)', '');
  md.push(`Ray cast from every holo sample (one per ${spec.placement.leakStepMetres * 1000} mm squared, both faces) towards the viewer; print = the ray misses the plate body and the quad (decals, stickers and the car are not counted as hiding anything). "Frontal" is the holo edge left outside the quad seen square on (negative = the quad overlaps the edge by that much). "Band" is the widest visible strip of print, in mm, with the viewer leaning towards that side by the given angle. "Cone" counts the views with any print over ${spec.placement.leakAzimuths} azimuths at ${spec.placement.leakConeDegrees.join(', ')} deg.`, '');
  const angles = spec.placement.leakSideDegrees;
  md.push(`| Mesh | Rule | Quad w x h (mm) | Frontal top / bottom / left / right (mm) | Band top, at ${angles.join('/')} deg | Band bottom | Band left | Band right | Cone views with print |`, '|---|---|---|---|---|---|---|---|---|');
  for (const [depot, p] of Object.entries(out.plates)) {
    for (const [name, r] of [['before (fit)', p.legacy], ['after (cover)', p.cover]]) {
      const f = r.frontal, band = (side) => r.leak.sides[side].map((x) => x.bandMm).join(' / ');
      md.push(`| \`${leaf(depot)}\` | ${name} | ${r.sizeMm[0]} x ${r.sizeMm[1]} | ${f.top} / ${f.bottom} / ${f.left} / ${f.right} | ${band('top')} | ${band('bottom')} | ${band('left')} | ${band('right')} | ${r.leak.cone.viewsWithPrint} / ${r.leak.cone.views} |`);
    }
  }
  md.push('', '## Per model', '');
  md.push('| Model | Type | Player entry -> definition | Plate | Front | Trims (curated) | Definitions patched / all |', '|---|---|---|---|---|---|---|');
  for (const m of out.models) {
    const p = m.player;
    const patched = m.apps.reduce((s, a) => s + a.plate + a.mount + a.frontOnly, 0);
    const all = m.apps.reduce((s, a) => s + a.definitions, 0);
    const trims = m.trims.length ? m.trims.map((t) => `${t.entry.replace(/^.*?__?basic_/, '')}: ${t.status}${t.front ? '+front' : ''}`).join('; ') : 'none curated';
    md.push(`| ${m.label} | ${m.type} | \`${p.entry}\` -> \`${p.definition || '?'}\` | ${p.status} | ${p.front ? 'yes' : 'no'} | ${trims} | ${patched} / ${all} |`);
  }
  for (const m of out.models) {
    md.push('', `### ${m.label} (\`${m.key}\`)`, '');
    for (const a of m.apps) {
      md.push(`\`${a.app}\`: ${a.definitions} definitions, ${a.plate} with a rear plate, ${a.mount} with a mounted rear plate, ${a.frontOnly} with a front plate only, ${a.none} without any plate, ${a.excluded} excluded (burnt/destroyed/damaged).`, '');
      md.push('| Definitions | Status | Rear plate -> binding | Plate mesh | Plate in slot (x, y, z) | Front | Quad (w x h) |', '|---|---|---|---|---|---|---|');
      for (const g of a.groups) {
        const names = g.definitions.length > 4 ? `${g.definitions.slice(0, 3).map((n) => `\`${n}\``).join(', ')} +${g.definitions.length - 3}` : g.definitions.map((n) => `\`${n}\``).join(', ');
        let rear = '-', mesh = '-', pos = '-';
        if (g.rear) { rear = `\`${g.rear.component}\` -> \`${g.rear.bind.bind}\`${g.rear.bind.slot ? `/${g.rear.bind.slot}` : ''}`; mesh = `\`${g.rear.mesh}\``; pos = fmt(g.rear.inSlot); }
        else if (g.mount) { rear = `mount -> \`${g.mount.bind}\` (from ${g.mount.reference.definitions[0]}, shift ${g.mount.shift} m)`; mesh = `\`${leaf(g.mount.mesh || 'license_plate.mesh')}\` (mount, holo masked)`; pos = fmt(g.mount.position); }
        else if (g.why) rear = typeof g.why === 'string' ? g.why : g.why.map((w) => w.why).join('; ');
        const front = g.front ? `\`${g.front.component}\` -> \`${g.front.bind.bind}\`` : '-';
        const quad = g.quads.length ? g.quads.map((q) => `${q.size[0].toFixed(3)} x ${q.size[1].toFixed(3)}`).join(' / ') : '-';
        md.push(`| ${names} | ${g.status} | ${rear} | ${mesh} | ${pos} | ${front} | ${quad} |`);
      }
      md.push('');
    }
  }
  fs.writeFileSync(path.join(outDir, 'plates-dealer-2.50.md'), md.join('\n') + '\n', 'utf8');
  console.log(`PLATES_DATA_WRITTEN models=${out.models.length}`);
}

// ----------------------------------------------------------------------------- views
// Before/after renders of each plate mesh, for preview-plates.ps1: the plate body grey, the
// holo (the factory print) hatched magenta, the quad textured with the item image the
// preview script drew (2D, game fonts). Rows: before (fit rule), after (cover rule, plate
// route), mount (cover rule on our mounted plate, holo masked). Print pixels are counted.
const VIEWS = [
  { name: 'front', theta: 0, phi: 0 }, { name: 'above-30', theta: 30, phi: 90 }, { name: 'above-60', theta: 60, phi: 90 },
  { name: 'below-45', theta: 45, phi: 270 }, { name: 'left-60', theta: 60, phi: 180 }, { name: 'right-60', theta: 60, phi: 0 },
];
function views(plan, previewDir) {
  const spec = readJson(plan.spec);
  const glbs = Object.fromEntries([spec.screenMesh.path, ...Object.keys(spec.plateMeshes)].map((d) => [d, G.readGlb(plan.glb[d] || fail(`no glb for ${d}`))]));
  const screenChunks = glbs[spec.screenMesh.path];
  const screen = measureScreen(screenChunks);
  const itemDir = path.join(previewDir, 'items');
  const outDir = path.join(previewDir, 'views');
  fs.mkdirSync(outDir, { recursive: true });
  const texture = (name) => { const f = path.join(itemDir, `${name}.png`); return fs.existsSync(f) ? png.readPng(f) : fail(`no item image ${f} (preview-plates.ps1 draws it)`); };
  const result = { size: [420, 260], views: VIEWS, meshes: {} };
  for (const depot of Object.keys(spec.plateMeshes)) {
    const s = plateSetup(plan, spec, glbs, screen, screenChunks, depot, false);
    const materials = plateMaterials(plan, depot);
    const chunks = glbs[depot];
    const rows = [
      ['before', s.legacy, texture(`legacy-${spec.plateMeshes[depot].style === 'car' ? 'Car' : 'Moto'}`), chunks],
      ['after', s.cover, texture(s.item), chunks],
      ['mount', s.cover, texture(s.item), chunks.filter((c) => c.chunk !== s.plate.holoChunk)],
    ];
    const rec = {};
    for (const [rule, placed, tex, shown] of rows) {
      const P = s.plate, r = placed.rect;
      const quadInfo = {
        depth: placed.depth, width: r.right - r.left, height: r.top - r.bottom, R: P.R, U: P.U,
        origin: G.add(G.add(G.add(P.center, G.mul(P.R, r.left)), G.mul(P.U, r.bottom)), G.mul(P.N, placed.depth)),
      };
      rec[rule] = {};
      for (const v of VIEWS) {
        const img = cover.renderView(P, shown, materials, cover.quadTriangles(placed.fit, screenChunks), quadInfo, tex, v, result.size);
        const file = path.join(outDir, `${leaf(depot).replace(/\.mesh$/, '')}-${rule}-${v.name}.png`);
        png.writePng(file, img.width, img.height, img.rgba);
        rec[rule][v.name] = img.printPixels;
      }
    }
    result.meshes[leaf(depot)] = { item: s.item, rows: rec };
  }
  writeJson(path.join(outDir, 'views.json'), result);
  const after = Object.values(result.meshes).reduce((n, m) => n + Object.values(m.rows.after).reduce((a, b) => a + b, 0) + Object.values(m.rows.mount).reduce((a, b) => a + b, 0), 0);
  const before = Object.values(result.meshes).reduce((n, m) => n + Object.values(m.rows.before).reduce((a, b) => a + b, 0), 0);
  console.log(`PLATES_VIEWS meshes=${Object.keys(result.meshes).length} views=${VIEWS.length} printPixelsBefore=${before} printPixelsAfter=${after}`);
}

try {
  const [mode, planFile, extra] = process.argv.slice(2);
  const plan = planFile ? readJson(planFile) : fail('usage: plates.cjs <survey|generate|validate|scan> <plan.json> [dir]');
  if (mode === 'survey') {
    const sv = survey(plan, readJson(plan.spec));
    writeJson(path.join(plan.reportDir, 'survey.json'), { neededMeshes: sv.neededMeshes });
    console.log(`PLATES_SURVEYED apps=${Object.keys(sv.apps).length} bumperMeshes=${sv.neededMeshes.length}`);
  } else if (mode === 'generate') generate(plan);
  else if (mode === 'validate') validate(plan, extra);
  else if (mode === 'scan') scan(plan, extra);
  else if (mode === 'data') data(plan, extra);
  else if (mode === 'views') views(plan, extra);
  else fail(`unknown mode ${mode}`);
} catch (e) {
  console.error(`PLATES_FAILED ${e.message}`);
  process.exit(1);
}
