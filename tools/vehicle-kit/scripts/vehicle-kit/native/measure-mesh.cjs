// Prints the layout of game meshes and entities, to measure a convention (pivot, axis,
// radius, LODs, materials) before modelling a part that must fit it.
//
//   node measure-mesh.cjs <file>...
//     <x>.mesh.json   WolvenKit `convert serialize` of a .mesh
//     <x>.ent.json    WolvenKit `convert serialize` of a .ent (components and bindings)
//     <x>.glb         WolvenKit `uncook --mesh-export-type MeshOnly` (per-chunk bounds)
//
// Read-only and print-only: run it on files extracted OUTSIDE the repository
// (measure-vanilla.ps1 does). Bounds are reported in engine axes (metres, X right,
// Y forward, Z up); WolvenKit's glTF is Y-up, so (x, y, z)gltf = (x, z, -y)engine.
'use strict';
const fs = require('node:fs'), path = require('node:path');

const v = x => (x === undefined || x === null ? '-' : typeof x === 'number' ? +x.toFixed(4) : x);
const str = x => x?.$value ?? x?.DepotPath?.$value ?? '';

function mesh(file) {
  const r = JSON.parse(fs.readFileSync(file, 'utf8')).Data.RootChunk;
  const h = r.renderResourceBlob?.Data?.header ?? {};
  console.log(`  boundingBox   min ${JSON.stringify(r.boundingBox?.Min)} max ${JSON.stringify(r.boundingBox?.Max)}`);
  console.log(`  lodLevelInfo  ${JSON.stringify(r.lodLevelInfo)}   renderLODs ${JSON.stringify(h.renderLODs)}`);
  console.log(`  objectType    ${r.objectType ?? '-'}   parameters ${(r.parameters ?? []).map(p => p.Data?.$type).join(', ') || 'none'}`);
  for (const m of r.materialEntries ?? []) console.log(`  material ${m.index}: ${str(m.name)}${m.isLocalInstance ? ' (local)' : ''}`);
  for (const m of r.externalMaterials ?? []) console.log(`  external    ${str(m)}`);
  for (const a of r.appearances ?? []) console.log(`  appearance ${str(a.Data.name)}: ${a.Data.chunkMaterials.map(str).join(', ')}`);
  (h.renderChunkInfos ?? []).forEach((c, i) =>
    console.log(`  chunk ${i}: lodMask ${c.lodMask} tris ${c.numIndices / 3} verts ${c.numVertices}`));
}

function entity(file) {
  const r = JSON.parse(fs.readFileSync(file, 'utf8')).Data.RootChunk;
  const comps = [...(r.components ?? []), ...(r.compiledData?.Data?.Chunks ?? [])].filter(Boolean);
  for (const c of comps) {
    const b = c.parentTransform?.Data;
    const t = c.localTransform;
    const pos = t?.Position ? ['x', 'y', 'z'].map(k => v((t.Position[k]?.Bits ?? 0) / 131072)) : null;
    console.log(`  ${c.$type} '${str(c.name)}'${c.mesh ? ' mesh ' + str(c.mesh) : ''}` +
      (b ? ` bound ${b.$type} -> ${str(b.bindName)}/${str(b.slotName)}` : '') +
      (pos && pos.some(n => n) ? ` at ${pos.join(',')}` : '') +
      (c.objectTypeID ? ` ${c.objectTypeID}` : ''));
  }
}

function glb(file) {
  const b = fs.readFileSync(file), n = b.readUInt32LE(12), d = JSON.parse(b.subarray(20, 20 + n));
  d.meshes.forEach(m => m.primitives.forEach(p => {
    const a = d.accessors[p.attributes.POSITION];
    // gltf (x, y, z) = engine (x, z, -y)  =>  engine x = gx, y = -gz, z = gy
    const min = [a.min[0], -a.max[2], a.min[1]], max = [a.max[0], -a.min[2], a.max[1]];
    const ext = max.map((x, i) => x - min[i]);
    const thin = ext.indexOf(Math.min(...ext));
    const radius = Math.max(...ext.filter((_, i) => i !== thin)) / 2;
    console.log(`  ${m.name}: tris ${d.accessors[p.indices].count / 3} min ${min.map(v)} max ${max.map(v)}` +
      `  thinnest axis ${'XYZ'[thin]} (width ${v(ext[thin])}), radius ${v(radius)}`);
  }));
}

for (const file of process.argv.slice(2)) {
  console.log(`=== ${path.basename(file)}`);
  if (file.endsWith('.glb')) glb(file);
  else if (file.endsWith('.ent.json')) entity(file);
  else mesh(file);
}
