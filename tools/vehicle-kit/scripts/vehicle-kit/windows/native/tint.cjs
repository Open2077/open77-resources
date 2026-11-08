// Generator of the window tint packs (route 2, CONTRACT.md §6). Reads data/glass-2.50.json
// (packPlan + meshes: names and depot paths only) and writes the WolvenKit JSON of OUR files,
// built field by field from scratch:
//
//   * CMaterialInstance files <prefix>\materials\glass_tint<n>[_onesided].mi. Each names a
//     vanilla base material by depot path and sets only the packPlan values.
//   * one geometry-less patch CMesh per target glass mesh, <prefix>\windows\<target file>:
//     appearances open77_tint<n>__<source>, each the source's chunk material NAMES with the
//     glass chunks renamed open77_tint<n>[_onesided]; materialEntries = our names (external);
//     externalMaterials = our .mi; no render blob, no local material, no physics.
//
// The vanilla JSON the build script serialized into the git-ignored cache is READ for
// checks only (data still matches the installed game, our names are free in every target,
// every value we set is a parameter of its template). Nothing of it is copied.
//
//   node tint.cjs digest   <glass-2.50.json>          canonical SHA-256 of packPlan + meshes
//   node tint.cjs generate <plan.json>                write the JSON + generated.json
//   node tint.cjs validate <plan.json> <roundTripDir> check the WolvenKit round trip
//   node tint.cjs scan     <plan.json> <dir>          no-vanilla-bytes scan of the cooked files
//
// plan.json: { data, pack, resource, prefix, outDir, reportDir, select: { meshes?, sources?,
//              levels }, vanillaJson: { depot: json }, vanillaFiles: [ raw files, for scan ] }
// Prints TINT_DIGEST / TINT_GENERATED / TINT_ROUNDTRIP_OK / TINT_SCAN_OK on success and
// TINT_FAILED <reason> otherwise.
'use strict';
const fs = require('node:fs');
const path = require('node:path');
const crypto = require('node:crypto');

const BS = '\\';
function fail(message) { throw new Error(message); }
function readJson(file) { return JSON.parse(fs.readFileSync(file, 'utf8')); }
function writeJson(file, value) { fs.mkdirSync(path.dirname(file), { recursive: true }); fs.writeFileSync(file, JSON.stringify(value, null, 2) + '\n', 'utf8'); }
const leaf = (p) => p.split(BS).pop();
const str = (x) => (x && (x.$value !== undefined ? x.$value : x.DepotPath && x.DepotPath.$value)) || '';

// ----------------------------------------------------------------------------- RED4 JSON
const cname = (value) => ({ $type: 'CName', $storage: 'string', $value: value });
const resourcePath = (value) => ({ $type: 'ResourcePath', $storage: 'string', $value: value });
// Flags 'Default', as the Open77 marker meshes (scripts/markers/prepare-native-assets.cjs)
// write their externalMaterials, proven in game.
const resourceRef = (value) => ({ DepotPath: resourcePath(value), Flags: 'Default' });
const vector4 = () => ({ $type: 'Vector4', W: 0, X: 0, Y: 0, Z: 0 });
const HEADER = (archiveFileName) => ({
  WolvenKitVersion: '8.20.0', WKitJsonVersion: '0.0.9', GameVersion: 2310,
  ExportedDateTime: '2000-01-01T00:00:00Z', DataType: 'CR2W', ArchiveFileName: archiveFileName,
});
const doc = (depotPath, root) => ({ Header: HEADER(depotPath), Data: { Version: 195, BuildVersion: 0, RootChunk: root, EmbeddedFiles: [] } });

// WolvenKit writes a ResourcePath it has no name for (our own files) back as its hash:
// FNV-1a 64 of the depot path. Compare paths through this.
function pathHash(text) {
  let h = 0xcbf29ce484222325n;
  for (const byte of Buffer.from(text, 'utf8')) { h ^= BigInt(byte); h = (h * 0x100000001b3n) & 0xffffffffffffffffn; }
  return h.toString();
}
const pathKey = (x) => { const v = x && (x.$value !== undefined ? x : x.DepotPath); return !v ? '' : v.$storage === 'uint64' ? v.$value : pathHash(v.$value); };

// Value types of a CMaterialInstance and the template parameter class each one feeds.
const VALUE_KIND = { TintColor: 'Color', Opacity: 'Float', OpacityBackFace: 'Float', BackFacesReflectionPower: 'Float' };
const PARAMETER_CLASS = { Color: 'CMaterialParameterColor', Float: 'CMaterialParameterScalar' };

function materialValue(name, value) {
  const kind = VALUE_KIND[name] || fail(`no value type known for material parameter ${name}`);
  if (kind === 'Color') {
    if (!Array.isArray(value) || value.length !== 4 || value.some((c) => !Number.isInteger(c) || c < 0 || c > 255)) fail(`${name}: expected [r, g, b, a] bytes`);
    const [r, g, b, a] = value;
    return { $type: 'Color', [name]: { $type: 'Color', Alpha: a, Blue: b, Green: g, Red: r } };
  }
  if (typeof value !== 'number' || !Number.isFinite(value)) fail(`${name}: expected a number`);
  return { $type: 'Float', [name]: value };
}

function materialInstance(m) {
  return {
    $type: 'CMaterialInstance',
    audioTag: cname('None'),
    baseMaterial: resourceRef(m.baseMaterial),
    cookingPlatform: 'PLATFORM_PC',
    enableMask: 0,
    metadata: null,
    resourceVersion: 4,
    values: Object.entries(m.values).map(([k, v]) => materialValue(k, v)),
  };
}

// Every root field of CMesh, at its empty default, except the three the patch is about.
function patchMesh(appearances, materials) {
  return {
    $type: 'CMesh',
    appearances: appearances.map((a, i) => ({ HandleId: String(i), Data: { $type: 'meshMeshAppearance', chunkMaterials: a.chunkMaterials.map(cname), name: cname(a.name), tags: [] } })),
    boneNames: [],
    boneRigMatrices: [],
    boneVertexEpsilons: [],
    boundingBox: { $type: 'Box', Max: vector4(), Min: vector4() },
    castGlobalShadowsCachedInCook: 0,
    castLocalShadowsCachedInCook: 0,
    castsRayTracedShadowsFromOriginalGeometry: 0,
    consoleBias: 0,
    constrainAutoHideDistanceToTerrainHeightMap: 0,
    cookingPlatform: 'PLATFORM_PC',
    externalMaterials: materials.map((m) => resourceRef(m.depot)),
    floatTrackNames: [],
    forceLoadAllAppearances: 0,
    geometryHash: '0',
    inplaceResources: [],
    isPlayerShadowMesh: 0,
    isShadowMesh: 0,
    localMaterialBuffer: { $type: 'meshMeshMaterialBuffer', materials: [], rawData: null, rawDataHeaders: [] },
    localMaterialInstances: [],
    lodBoneMask: [],
    lodLevelInfo: [],
    materialEntries: materials.map((m, i) => ({ $type: 'CMeshMaterialEntry', index: i, isLocalInstance: 0, name: cname(m.material) })),
    objectType: 'ROT_Static',
    parameters: [],
    preloadExternalMaterials: [],
    preloadLocalMaterialInstances: [],
    renderResourceBlob: null,
    resourceVersion: 3,
    // WolvenKit's empty CDateTime: what it writes when the field is absent. '0' is refused
    // by its CDateTime parser on deserialize.
    saveDateTime: '1048576',
    surfaceAreaPerAxis: { $type: 'Vector3', X: 0, Y: 0, Z: 0 },
    useRayTracingShadowLODBias: 0,
  };
}

// ----------------------------------------------------------------------------- the plan
// What a pack holds, from packPlan alone. Shared by generate and validate, so the round
// trip is checked against the data, not against the generator's own report.
function expectedPack(plan) {
  const data = readJson(plan.data);
  const pp = data.packPlan;
  if (pp.route !== 2) fail(`packPlan.route is ${pp.route}, expected 2`);
  if (pp.naming !== 'open77_tint<level>__<source mesh appearance>') fail(`unexpected packPlan.naming ${pp.naming}`);
  const sel = plan.select || {};
  const levels = sel.levels || Object.keys(pp.levels).map(Number).sort((a, b) => a - b);
  for (const n of levels) if (!pp.levels[String(n)]) fail(`level ${n} is not in packPlan.levels`);
  const targets = sel.meshes || Object.keys(pp.perMesh);
  const materialOf = new Map(pp.materialInstances.map((m) => [m.material, m]));
  const prefix = plan.prefix;
  if (!/^open77\\assets\\[a-z0-9_]+\\[0-9a-f]{12}$/.test(prefix)) fail(`prefix ${prefix} does not follow open77\\assets\\<resource>\\<rev12>`);
  const usedMaterials = new Set();
  const meshes = targets.map((target) => {
    const row = pp.perMesh[target] || fail(`${target} is not in packPlan.perMesh`);
    const inv = data.meshes[target] || fail(`${target} is not in meshes`);
    const sources = sel.sources ? sel.sources : Object.keys(row.sources);
    const appearances = [];
    const materials = [];
    for (const source of sources) {
      const s = row.sources[source] || fail(`${leaf(target)}: no source appearance ${source} in packPlan`);
      const chunks = (inv.appearances[source] || fail(`${leaf(target)}: no appearance ${source} in meshes`)).chunks;
      if (chunks.length !== s.chunks) fail(`${leaf(target)}/${source}: ${chunks.length} chunks in meshes, ${s.chunks} in packPlan`);
      const glass = (inv.appearances[source].glassChunks || []).slice().sort((a, b) => a - b);
      const swapped = Object.keys(s.swap).map(Number).sort((a, b) => a - b);
      if (JSON.stringify(glass) !== JSON.stringify(swapped)) fail(`${leaf(target)}/${source}: swap ${swapped} != glass chunks ${glass}`);
      for (const n of levels) {
        const name = `open77_tint${n}__${source}`;
        if (!s.add.includes(name)) fail(`${leaf(target)}: ${name} is not in packPlan add`);
        const chunkMaterials = chunks.map((c, i) => {
          const sw = s.swap[String(i)];
          if (!sw) return c;
          if (sw.source !== c) fail(`${leaf(target)}/${source}: swap ${i} expects ${sw.source}, chunk is ${c}`);
          const material = sw.replacement.replace('<level>', String(n));
          const mi = materialOf.get(material) || fail(`${leaf(target)}: replacement ${material} has no material instance`);
          if (!materials.includes(mi)) materials.push(mi);
          usedMaterials.add(material);
          return material;
        });
        appearances.push({ name, source, level: n, chunkMaterials, sourceChunks: chunks, swap: swapped });
      }
    }
    if (!sel.meshes && appearances.length !== Object.values(row.sources).reduce((t, s) => t + s.add.length, 0)) fail(`${leaf(target)}: appearance count differs from packPlan add`);
    materials.sort((a, b) => pp.materialInstances.indexOf(a) - pp.materialInstances.indexOf(b));
    return { target, patch: `${prefix}${BS}windows${BS}${leaf(target)}`, appearances, materials: materials.map((m) => m.material) };
  });
  const materials = pp.materialInstances.filter((m) => usedMaterials.has(m.material)).map((m) => ({ ...m, depot: `${prefix}${BS}materials${BS}${m.file}` }));
  const depotOf = new Map(materials.map((m) => [m.material, m.depot]));
  for (const m of meshes) m.materialDepots = m.materials.map((n) => depotOf.get(n));
  if (!sel.meshes) {
    if (meshes.length !== pp.meshes) fail(`${meshes.length} meshes, packPlan says ${pp.meshes}`);
    const total = meshes.reduce((t, m) => t + m.appearances.length, 0);
    if (total !== pp.appearancesAdded) fail(`${total} appearances, packPlan says ${pp.appearancesAdded}`);
  }
  const leaves = meshes.map((m) => leaf(m.target));
  if (new Set(leaves).size !== leaves.length) fail('two target meshes share a file name; patch paths would collide');
  const files = [...materials.map((m) => m.depot), ...meshes.map((m) => m.patch)].sort();
  return { data, pp, levels, meshes, materials, files };
}

// ----------------------------------------------------------------------------- vanilla checks (read only)
function templateParameters(rootChunk) {
  const out = new Map();
  const visit = (n) => {
    if (Array.isArray(n)) { n.forEach(visit); return; }
    if (!n || typeof n !== 'object') return;
    if (n.parameterName && n.$type) out.set(str(n.parameterName), n.$type);
    Object.values(n).forEach(visit);
  };
  visit(rootChunk.parameters);
  return out;
}

function vanillaChecks(plan, x) {
  const vj = plan.vanillaJson || fail('plan has no vanillaJson');
  const load = (depot) => readJson(vj[depot] || fail(`no vanilla JSON for ${depot}`)).Data.RootChunk;
  const report = { meshes: 0, appearances: 0, templates: {} };
  for (const m of x.meshes) {
    const v = load(m.target);
    if (v.$type !== 'CMesh') fail(`${leaf(m.target)} is a ${v.$type}`);
    const apps = new Map(v.appearances.map((a) => [str(a.Data.name), a.Data.chunkMaterials.map(str)]));
    const entries = new Set(v.materialEntries.map((e) => str(e.name)));
    for (const a of m.appearances) {
      if (apps.has(a.name)) fail(`${leaf(m.target)} already has an appearance ${a.name}`);
      const src = apps.get(a.source) || fail(`${leaf(m.target)}: the installed game has no appearance ${a.source}`);
      if (JSON.stringify(src) !== JSON.stringify(a.sourceChunks)) fail(`${leaf(m.target)}/${a.source}: chunks ${src} in the game, ${a.sourceChunks} in the data`);
      a.chunkMaterials.forEach((c, i) => {
        if (a.swap.includes(i)) { if (entries.has(c)) fail(`${leaf(m.target)} already has a material named ${c}: the target's would win`); }
        else if (!entries.has(c)) fail(`${leaf(m.target)}/${a.source} chunk ${i}: ${c} is not a material entry of the target`);
      });
      report.appearances++;
    }
    report.meshes++;
  }
  // Every value we set is a parameter of the template the instance resolves to, of the
  // matching kind. A base .mi is followed to its template.
  for (const mi of x.materials) {
    let base = mi.baseMaterial;
    for (let hop = 0; base.endsWith('.mi'); hop++) {
      if (hop > 4) fail(`${mi.file}: base material chain too deep`);
      const r = load(base);
      if (r.$type !== 'CMaterialInstance') fail(`${base} is a ${r.$type}`);
      base = str(r.baseMaterial);
    }
    const t = load(base);
    if (t.$type !== 'CMaterialTemplate') fail(`${base} is a ${t.$type}`);
    const params = templateParameters(t);
    for (const name of Object.keys(mi.values)) {
      const cls = params.get(name);
      if (cls !== PARAMETER_CLASS[VALUE_KIND[name]]) fail(`${mi.file}: ${name} is ${cls || 'not a parameter'} of ${base}, expected ${PARAMETER_CLASS[VALUE_KIND[name]]}`);
    }
    report.templates[mi.file] = { template: base, parameters: Object.keys(mi.values) };
  }
  return report;
}

// ----------------------------------------------------------------------------- generate
function generate(plan) {
  const x = expectedPack(plan);
  const vanilla = vanillaChecks(plan, x);
  fs.mkdirSync(plan.outDir, { recursive: true });
  for (const m of x.materials) {
    writeJson(path.join(plan.outDir, 'materials', `${m.file}.json`), doc(m.depot, materialInstance(m)));
  }
  const materialByName = new Map(x.materials.map((m) => [m.material, m]));
  for (const m of x.meshes) {
    writeJson(path.join(plan.outDir, 'windows', `${leaf(m.patch)}.json`), doc(m.patch, patchMesh(m.appearances, m.materials.map((n) => materialByName.get(n)))));
  }
  const report = {
    pack: plan.pack, resource: plan.resource, prefix: plan.prefix,
    counts: { meshes: x.meshes.length, appearances: x.meshes.reduce((t, m) => t + m.appearances.length, 0), materials: x.materials.length, files: x.files.length },
    vanillaChecks: vanilla,
    materials: x.materials.map((m) => ({ material: m.material, depot: m.depot, baseMaterial: m.baseMaterial, values: m.values })),
    meshes: x.meshes.map((m) => ({ target: m.target, patch: m.patch, materials: m.materials, appearances: m.appearances.map((a) => a.name) })),
    files: x.files,
  };
  writeJson(path.join(plan.reportDir, 'generated.json'), report);
  console.log(`TINT_GENERATED pack=${plan.pack} meshes=${report.counts.meshes} appearances=${report.counts.appearances} materials=${report.counts.materials} vanillaChecked=${vanilla.meshes}/${vanilla.appearances}`);
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

const MESH_TYPES = new Set(['CMesh', 'meshMeshAppearance', 'CMeshMaterialEntry', 'meshMeshMaterialBuffer', 'CName', 'ResourcePath', 'Box', 'Vector4', 'Vector3']);
const MI_TYPES = new Set(['CMaterialInstance', 'CName', 'ResourcePath', 'Color', 'Float']);

// Walks a round-tripped file: only allowed types, only allowed resource paths, no buffer or
// handle-borne object we did not write. Returns every CName value seen.
function structuralCheck(root, types, allowedPaths, file) {
  const names = [];
  const visit = (n, where) => {
    if (Array.isArray(n)) { n.forEach((v, i) => visit(v, `${where}[${i}]`)); return; }
    if (!n || typeof n !== 'object') return;
    if (n.$type && !types.has(n.$type)) fail(`${file}: unexpected type ${n.$type} at ${where}`);
    if (Object.prototype.hasOwnProperty.call(n, 'BufferId')) fail(`${file}: unexpected buffer at ${where}`);
    if (n.$type === 'CName') names.push(n.$value);
    if (n.$type === 'ResourcePath') {
      const key = n.$storage === 'uint64' ? n.$value : pathHash(n.$value);
      if (!allowedPaths.has(key)) fail(`${file}: unexpected resource ${n.$value} at ${where}`);
    }
    for (const [k, v] of Object.entries(n)) visit(v, `${where}.${k}`);
  };
  visit(root, 'root');
  return names;
}

function validate(plan, roundTripDir) {
  const x = expectedPack(plan);
  const same = (a, b, what) => { if (JSON.stringify(a) !== JSON.stringify(b)) fail(`round trip: ${what}: ${JSON.stringify(a)} != ${JSON.stringify(b)}`); };
  const near = (a, b, what) => { if (typeof a !== 'number' || Math.abs(a - b) > 1e-6) fail(`round trip: ${what}: ${a} != ${b}`); };
  // Nothing in the round trip that we did not generate.
  const produced = [];
  const walk = (d) => { for (const e of fs.readdirSync(d, { withFileTypes: true })) { const p = path.join(d, e.name); if (e.isDirectory()) walk(p); else produced.push(e.name); } };
  walk(roundTripDir);
  same(produced.sort(), x.files.map((f) => `${leaf(f)}.json`).sort(), 'round-trip file set');

  const levelsOk = new Set(x.levels.map(String));
  for (const m of x.materials) {
    const r = findJson(roundTripDir, m.depot);
    structuralCheck(r, MI_TYPES, new Set([pathHash(m.baseMaterial)]), m.file);
    same(r.$type, 'CMaterialInstance', `${m.file} type`);
    same(str(r.baseMaterial), m.baseMaterial, `${m.file} baseMaterial`);
    same(r.values.map((v) => Object.keys(v).find((k) => k !== '$type')), Object.keys(m.values), `${m.file} value names`);
    for (const v of r.values) {
      const k = Object.keys(v).find((key) => key !== '$type');
      const want = m.values[k];
      same(v.$type, VALUE_KIND[k], `${m.file} ${k} type`);
      if (v.$type === 'Color') same([v[k].Red, v[k].Green, v[k].Blue, v[k].Alpha], want, `${m.file} ${k}`);
      else near(v[k], want, `${m.file} ${k}`);
    }
  }
  const ourMaterial = /^open77_tint[1-9](_onesided)?$/;
  let appearances = 0, swapped = 0, kept = 0;
  for (const m of x.meshes) {
    const file = leaf(m.patch);
    const r = findJson(roundTripDir, m.patch);
    const inv = x.data.meshes[m.target];
    const names = structuralCheck(r, MESH_TYPES, new Set(m.materialDepots.map(pathHash)), file);
    same(r.$type, 'CMesh', `${file} type`);
    if (r.renderResourceBlob !== null) fail(`${file}: has a render blob`);
    for (const k of ['parameters', 'localMaterialInstances', 'preloadLocalMaterialInstances', 'preloadExternalMaterials', 'inplaceResources', 'boneNames', 'lodLevelInfo', 'floatTrackNames'])
      if ((r[k] || []).length) fail(`${file}: ${k} is not empty`);
    if ((r.localMaterialBuffer.materials || []).length) fail(`${file}: has local materials`);
    // materialEntries: our names, external, each pointing at our .mi of the same name.
    same(r.materialEntries.map((e) => str(e.name)), m.materials, `${file} material entries`);
    same(r.externalMaterials.map(pathKey), m.materialDepots.map(pathHash), `${file} external materials`);
    r.materialEntries.forEach((e, i) => {
      if (e.isLocalInstance !== 0 || e.index !== i) fail(`${file}: material entry ${str(e.name)} is not external entry ${i}`);
      if (!ourMaterial.test(str(e.name))) fail(`${file}: material entry ${str(e.name)} is not ours`);
    });
    // Appearances: the naming rule, the source's chunk count, glass swapped, the rest untouched.
    same(r.appearances.map((a) => str(a.Data.name)), m.appearances.map((a) => a.name), `${file} appearance names`);
    for (const h of r.appearances) {
      const a = h.Data;
      const name = str(a.name);
      const rule = /^open77_tint([1-9])__(.+)$/.exec(name) || fail(`${file}: ${name} breaks the naming rule open77_tint<level>__<source>`);
      if (!levelsOk.has(rule[1])) fail(`${file}: ${name} has an unknown level`);
      const source = (inv.appearances[rule[2]] || fail(`${file}: ${name} names no source appearance of the target`)).chunks;
      const got = a.chunkMaterials.map(str);
      same(got.length, source.length, `${file}/${name} chunk count`);
      const glass = inv.appearances[rule[2]].glassChunks;
      got.forEach((c, i) => {
        if (glass.includes(i)) {
          const want = x.pp.perMesh[m.target].sources[rule[2]].swap[String(i)].replacement.replace('<level>', rule[1]);
          if (c !== want) fail(`${file}/${name} chunk ${i}: ${c}, expected ${want}`);
          if (!m.materials.includes(c)) fail(`${file}/${name} chunk ${i}: ${c} has no material entry in the patch`);
          swapped++;
        } else {
          if (c !== source[i]) fail(`${file}/${name} chunk ${i}: ${c}, the source has ${source[i]}`);
          if (ourMaterial.test(c)) fail(`${file}/${name} chunk ${i}: a non-glass chunk got ${c}`);
          kept++;
        }
      });
      if ((a.tags || []).length) fail(`${file}/${name}: has tags`);
      appearances++;
    }
    // Every CName in the file is an appearance name of ours, one of our material names, or a
    // chunk material name of the target's own source appearance (names only, by design).
    const allowed = new Set([...m.appearances.map((a) => a.name), ...m.materials, 'None', ...Object.values(inv.appearances).flatMap((a) => a.chunks)]);
    for (const n of names) if (!allowed.has(n)) fail(`${file}: unexpected name ${n}`);
  }
  console.log(`TINT_ROUNDTRIP_OK pack=${plan.pack} materials=${x.materials.length} meshes=${x.meshes.length} appearances=${appearances} glassChunksSwapped=${swapped} otherChunksKept=${kept}`);
}

// ----------------------------------------------------------------------------- scan
// No vanilla bytes: no cooked file of ours may share a 64-byte block with a vanilla file
// the build read. Every 64-byte window of our files is hashed; every 64-byte block of each
// vanilla file is looked up. Blocks that are all one byte value are not evidence and skipped.
// Same method as plates/native/plates.cjs.
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
    for (let i = 0; i + W <= b.length; i++) { const k = key(b.subarray(i, i + W)); if (!windows.has(k)) windows.set(k, `${path.basename(f)}@${i}`); }
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
        hits.push({ where: `${path.basename(v)}@${i} = ${windows.get(k)}`, ascii, counting: !ascii && isCounting(block), text: ascii ? block.toString('latin1') : '' });
      }
    }
  }
  // A shared block of printable ASCII and NULs is a run of names (RED4 type and property
  // names, the chunk material names a patch appearance must carry, depot paths). A block of
  // 32-bit words counting by a constant step is a CR2W index table. Any other shared block
  // fails the build.
  const vocabulary = [], counting = [], binary = [];
  for (const h of hits) (h.ascii ? vocabulary : h.counting ? counting : binary).push(h);
  const names = new Set();
  for (const h of vocabulary) for (const s of h.text.split('\0')) if (s.length >= 4) names.add(s);
  if (plan.reportDir) writeJson(path.join(plan.reportDir, 'scan.json'), { window: W, ourFiles: ourFiles.map((f) => path.basename(f)), vanillaFiles: plan.vanillaFiles.length, binary: binary.map((h) => h.where), counting: counting.map((h) => h.where), vocabulary: vocabulary.length, names: [...names].sort() });
  if (binary.length) fail(`scan: ${binary.length} binary 64-byte blocks of vanilla files found in our files: ${binary.slice(0, 8).map((h) => h.where).join('; ')}`);
  console.log(`TINT_SCAN_OK ours=${ourFiles.length} files ${total} bytes, vanilla=${plan.vanillaFiles.length} files, shared content blocks=0, shared name blocks=${vocabulary.length} (${names.size} names), shared index-run blocks=${counting.length}`);
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

// ----------------------------------------------------------------------------- digest
// The part of the data file a pack depends on, canonicalised: key order sorted at every level.
function canonical(v) {
  if (Array.isArray(v)) return v.map(canonical);
  if (v && typeof v === 'object') return Object.fromEntries(Object.keys(v).sort().map((k) => [k, canonical(v[k])]));
  return v;
}

try {
  const [mode, file, extra] = process.argv.slice(2);
  if (!file) fail('usage: tint.cjs <digest|generate|validate|scan> <file> [dir]');
  if (mode === 'digest') {
    const d = readJson(file);
    if (!d.packPlan || !d.meshes) fail(`${file} has no packPlan or meshes`);
    const text = JSON.stringify(canonical({ packPlan: d.packPlan, meshes: d.meshes }));
    console.log(`TINT_DIGEST ${crypto.createHash('sha256').update(text, 'utf8').digest('hex')}`);
  } else {
    const plan = readJson(file);
    if (mode === 'generate') generate(plan);
    else if (mode === 'validate') validate(plan, extra || fail('validate needs the round-trip folder'));
    else if (mode === 'scan') scan(plan, extra || fail('scan needs the folder to scan'));
    else fail(`unknown mode ${mode}`);
  }
} catch (e) {
  console.error(`TINT_FAILED ${e.message}`);
  process.exit(1);
}
