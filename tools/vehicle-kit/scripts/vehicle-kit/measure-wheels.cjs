// Stock wheel measurement and rim mount table for the vehicle kit (driven by measure-wheels.ps1).
//
//   node measure-wheels.cjs measure <plan.json> <measurements.json>
//   node measure-wheels.cjs fit <measurements.json> <spec.json> <fit.json> [<built parts dir>]
//
// measure: reads what measure-wheels.ps1 extracted OUTSIDE the repository (the uncooked
//   glb of each stock rim/tyre mesh, the serialized .app of each model) and measures every
//   finest-LOD vertex after the component's own transform (localTransform + visualScale),
//   in the wheel slot frame: engine axes, metres, spin axis X, outboard toward -X.
// fit: from those numbers and the spec's rim geometry, the per-record fit of every rim:
//   scale so the lip meets the tyre bead (uniform on cars; motorcycles also keep the stock
//   rim width along the axle), X offset so the lip face sits flush with the stock rim face,
//   the stock rim components to hide, and the right-side turn. With the built parts folder
//   (build-pack's work/parts), it also compares the depth of our centres with the stock one.
// Only numbers and component names are written by `fit`; nothing of the game files.
'use strict';
const fs = require('node:fs'), path = require('node:path');

const r4 = x => Math.round(x * 1e4) / 1e4;
const r3 = x => Math.round(x * 1e3) / 1e3;
const readJson = file => JSON.parse(fs.readFileSync(file, 'utf8').replace(/^﻿/, ''));

// ------------------------------------------------------------------------------------ glb
function glbVertices(file) {
  const b = fs.readFileSync(file), n = b.readUInt32LE(12), d = JSON.parse(b.subarray(20, 20 + n));
  const off = 20 + n, bin = b.subarray(off + 8, off + 8 + b.readUInt32LE(off));
  const chunks = [];
  d.meshes.forEach(m => m.primitives.forEach(p => {
    const a = d.accessors[p.attributes.POSITION], v = d.bufferViews[a.bufferView];
    if (a.componentType !== 5126 || a.type !== 'VEC3') throw new Error(`${file}: POSITION is not float VEC3`);
    const stride = v.byteStride || 12, start = (v.byteOffset || 0) + (a.byteOffset || 0);
    const pts = new Array(a.count);
    for (let i = 0; i < a.count; i++) {
      const o = start + i * stride;
      // glTF (x, y, z) = engine (x, z, -y)  =>  engine = (gx, -gz, gy)
      pts[i] = [bin.readFloatLE(o), -bin.readFloatLE(o + 8), bin.readFloatLE(o + 4)];
    }
    chunks.push({ name: m.name, tris: d.accessors[p.indices].count / 3, pts });
  }));
  // Finest LOD only (WolvenKit names the nodes submesh_NN_LOD_L).
  const lod1 = chunks.filter(c => /_LOD_1$/.test(c.name));
  return lod1.length ? lod1 : chunks;
}

// ------------------------------------------------------------------------------------ .app
function appearanceComponents(file, appearance) {
  const doc = readJson(file);
  const handles = {};
  const stack = [doc];
  while (stack.length) {
    const y = stack.pop();
    if (Array.isArray(y)) stack.push(...y);
    else if (y && typeof y === 'object') {
      if ('HandleId' in y && 'Data' in y) handles[y.HandleId] = y.Data;
      stack.push(...Object.values(y));
    }
  }
  const deref = h => (h && 'HandleRefId' in h ? handles[h.HandleRefId] : h && 'Data' in h ? h.Data : h);
  const def = (doc.Data.RootChunk.appearances || []).map(deref).find(a => a && a.name?.$value === appearance);
  if (!def) throw new Error(`${path.basename(file)}: no appearance ${appearance}`);
  let comps = (def.components || []).map(deref).filter(c => c && c.$type);
  if (!comps.length) comps = (def.compiledData?.Data?.Chunks || []).filter(c => c && c.name);
  return comps.map(c => {
    const t = c.localTransform || {}, p = t.Position || {}, q = t.Orientation || {};
    const pt = deref(c.parentTransform);
    return {
      name: c.name?.$value, type: c.$type, mesh: c.mesh?.DepotPath?.$value || null,
      position: ['x', 'y', 'z'].map(k => (p[k]?.Bits ?? 0) / 131072),
      orientation: [q.i ?? 0, q.j ?? 0, q.k ?? 0, q.r ?? 1],
      visualScale: c.visualScale ? [c.visualScale.X, c.visualScale.Y, c.visualScale.Z] : [1, 1, 1],
      bind: pt ? { bindName: pt.bindName?.$value, slotName: pt.slotName?.$value } : null,
    };
  });
}

// ------------------------------------------------------------------------------------ slot frames
// Reference pose of the entity's slots, in model space: vehicle_slots (slot -> bone +
// relative transform) on top of the deformation rig's bone transforms.
function qmul([ax, ay, az, aw], [bx, by, bz, bw]) {
  return [aw * bx + ax * bw + ay * bz - az * by, aw * by - ax * bz + ay * bw + az * bx,
          aw * bz + ax * by - ay * bx + az * bw, aw * bw - ax * bx - ay * by - az * bz];
}

function slotFrames(entFile, jsonDir, wanted) {
  const root = readJson(entFile).Data.RootChunk;
  const comps = [...(root.components || []), ...(root.compiledData?.Data?.Chunks || [])].filter(c => c && c.$type);
  const slots = comps.find(c => c.$type === 'entSlotComponent' && c.name?.$value === 'vehicle_slots');
  const rigComp = comps.find(c => c.$type === 'entAnimatedComponent' && c.name?.$value === 'deformation_rig');
  if (!slots || !rigComp) return { error: 'no vehicle_slots or deformation_rig component' };
  const rigPath = rigComp.rig?.DepotPath?.$value;
  const rigFile = path.join(jsonDir, path.basename(rigPath) + '.json');
  if (!fs.existsSync(rigFile)) return { error: `rig ${rigPath} not extracted` };
  const rig = readJson(rigFile).Data.RootChunk;
  const names = rig.boneNames.map(b => b.$value), parents = rig.boneParentIndexes, local = rig.boneTransforms;
  const world = [];
  for (let i = 0; i < names.length; i++) {
    const t = local[i], q = [t.Rotation.i, t.Rotation.j, t.Rotation.k, t.Rotation.r], p = [t.Translation.X, t.Translation.Y, t.Translation.Z];
    if (parents[i] < 0) { world[i] = { q, p }; continue; }
    const P = world[parents[i]], pp = rotate(P.q, p);
    world[i] = { q: qmul(P.q, q), p: [P.p[0] + pp[0], P.p[1] + pp[1], P.p[2] + pp[2]] };
  }
  const out = { rig: rigPath, slots: {} };
  for (const s of slots.slots || []) {
    const name = s.slotName?.$value;
    if (!wanted.has(name)) continue;
    const bi = names.indexOf(s.boneName?.$value);
    if (bi < 0) { out.slots[name] = { bone: s.boneName?.$value, error: 'bone not in rig' }; continue; }
    const rq = s.relativeRotation ? [s.relativeRotation.i, s.relativeRotation.j, s.relativeRotation.k, s.relativeRotation.r] : [0, 0, 0, 1];
    const rp = s.relativePosition ? [s.relativePosition.X, s.relativePosition.Y, s.relativePosition.Z] : [0, 0, 0];
    const B = world[bi], off = rotate(B.q, rp);
    out.slots[name] = { bone: names[bi], position: [B.p[0] + off[0], B.p[1] + off[1], B.p[2] + off[2]].map(r4), orientation: qmul(B.q, rq).map(r4) };
  }
  return out;
}

// Frame relation of a right-hand slot to its left twin: 'turned' when its axes are the left
// ones turned 180 degrees about Z (X and Y flipped, Z kept), 'same' when identical.
function rightVsLeft(left, right) {
  if (!left?.orientation || !right?.orientation) return 'unknown';
  const ax = q => [rotate(q, [1, 0, 0]), rotate(q, [0, 1, 0]), rotate(q, [0, 0, 1])];
  const [lx, ly, lz] = ax(left.orientation), [rx, ry, rz] = ax(right.orientation);
  const dot = (a, b) => a[0] * b[0] + a[1] * b[1] + a[2] * b[2];
  if (dot(lx, rx) < -0.99 && dot(ly, ry) < -0.99 && dot(lz, rz) > 0.99) return 'turned180aboutZ';
  if (dot(lx, rx) > 0.99 && dot(ly, ry) > 0.99 && dot(lz, rz) > 0.99) return 'same';
  // A rest-pose spin phase about X changes Y and Z but not the spin axis itself.
  if (dot(lx, rx) < -0.99) return 'xFlipped (spin phase differs)';
  if (dot(lx, rx) > 0.99) return 'xSame (spin phase differs)';
  return `other (x.x ${r3(dot(lx, rx))}, y.y ${r3(dot(ly, ry))}, z.z ${r3(dot(lz, rz))})`;
}

function rotate([i, j, k, r], [x, y, z]) {
  // v' = q v q*, quaternion (i, j, k, r)
  const tx = 2 * (j * z - k * y), ty = 2 * (k * x - i * z), tz = 2 * (i * y - j * x);
  return [x + r * tx + (j * tz - k * ty), y + r * ty + (k * tx - i * tz), z + r * tz + (i * ty - j * tx)];
}

function transformed(pts, comp) {
  const [sx, sy, sz] = comp.visualScale, q = comp.orientation, [px, py, pz] = comp.position;
  return pts.map(([x, y, z]) => { const [a, b, c] = rotate(q, [x * sx, y * sy, z * sz]); return [a + px, b + py, c + pz]; });
}

// Stats in the slot frame. r is the distance to the spin axis X.
function stats(pts) {
  let xMin = Infinity, xMax = -Infinity, rMin = Infinity, rMax = -Infinity, yMin = Infinity, yMax = -Infinity, zMin = Infinity, zMax = -Infinity;
  for (const [x, y, z] of pts) {
    const r = Math.hypot(y, z);
    if (x < xMin) xMin = x; if (x > xMax) xMax = x;
    if (r < rMin) rMin = r; if (r > rMax) rMax = r;
    if (y < yMin) yMin = y; if (y > yMax) yMax = y;
    if (z < zMin) zMin = z; if (z > zMax) zMax = z;
  }
  return { xMin, xMax, rMin, rMax, centre: [(yMin + yMax) / 2, (zMin + zMax) / 2], extentYZ: [yMax - yMin, zMax - zMin] };
}

function measureRim(pts) {
  const s = stats(pts);
  // Lip: the largest radius within 3 cm of the outboard face.
  const lip = pts.filter(p => p[0] <= s.xMin + 0.03).reduce((m, [, y, z]) => Math.max(m, Math.hypot(y, z)), 0);
  // Share of 10-degree sectors holding a vertex beyond half the radius: 1 for a full
  // wheel or disc, well under 1 for a caliper-like part.
  const bins = new Set(pts.filter(([, y, z]) => Math.hypot(y, z) > s.rMax / 2).map(([, y, z]) => Math.floor((Math.atan2(z, y) + Math.PI) / (Math.PI / 18)) % 36));
  // Centre (hub, spoke roots) within 0.4 of the outer radius: x span, or null for a hubless ring.
  const centre = pts.filter(([, y, z]) => Math.hypot(y, z) < 0.4 * s.rMax).map(p => p[0]);
  const hubX = centre.length ? [r4(centre.reduce((m, x) => Math.min(m, x), Infinity)), r4(centre.reduce((m, x) => Math.max(m, x), -Infinity))] : null;
  return { faceX: r4(s.xMin), innerX: r4(s.xMax), width: r4(s.xMax - s.xMin), outerRadius: r4(s.rMax), lipRadius: r4(lip),
           minRadius: r4(s.rMin), hubX, angularCoverage: r3(bins.size / 36), centreYZ: s.centre.map(r4), extentYZ: s.extentYZ.map(r4) };
}

function measureTyre(pts) {
  const s = stats(pts), mid = (s.xMin + s.xMax) / 2;
  const bead = side => pts.filter(p => (side < 0 ? p[0] <= mid : p[0] > mid)).reduce((m, [, y, z]) => Math.min(m, Math.hypot(y, z)), Infinity);
  return { faceX: r4(s.xMin), innerX: r4(s.xMax), width: r4(s.xMax - s.xMin), outerRadius: r4(s.rMax),
           beadRadiusOutboard: r4(bead(-1)), beadRadiusInboard: r4(bead(1)), centreYZ: s.centre.map(r4) };
}

// ------------------------------------------------------------------------------------ measure
const CAR_SLOTS = ['wheel_front_left', 'wheel_front_right', 'wheel_back_left', 'wheel_back_right'];

function measure(planFile, outFile) {
  const plan = readJson(planFile), root = plan.outDir;
  const glbCache = new Map(), appCache = new Map();
  const glbOf = mesh => {
    if (!glbCache.has(mesh)) {
      const file = path.join(root, 'glb', mesh.replace(/\.mesh$/i, '.glb'));
      if (!fs.existsSync(file)) throw new Error(`no glb for ${mesh} (${file})`);
      const chunks = glbVertices(file);
      glbCache.set(mesh, { chunks: chunks.map(c => ({ name: c.name, tris: c.tris, vertices: c.pts.length })), pts: chunks.flatMap(c => c.pts) });
    }
    return glbCache.get(mesh);
  };
  const models = [];
  for (const m of plan.models) {
    const key = `${m.app}|${m.appearance}`;
    if (!appCache.has(key)) appCache.set(key, appearanceComponents(path.join(root, 'json', path.basename(m.app) + '.json'), m.appearance));
    const appComps = appCache.get(key);
    const wanted = new Set([...CAR_SLOTS, 'wheel_front', 'wheel_back', ...m.wheelSlots, ...m.components.map(c => c.slot).filter(Boolean)]);
    const frames = slotFrames(path.join(root, 'json', path.basename(m.entity) + '.json'), path.join(root, 'json'), wanted);
    // A rim centre bound to brake_<axle>_<side> is measured in the frame of wheel_<axle>_<side>
    // (the brake slot sits elsewhere: 8 cm outboard on the Cortes and Semimaru fronts).
    const toWheelFrame = (pts, slot) => {
      const mm = /^brake_(front|back)_(left|right)$/.exec(slot || '');
      const from = frames.slots?.[slot], to = mm && frames.slots?.[`wheel_${mm[1]}_${mm[2]}`];
      if (!mm || !from?.orientation || !to?.orientation) return null;
      const inv = [-to.orientation[0], -to.orientation[1], -to.orientation[2], to.orientation[3]];
      return { slot: `wheel_${mm[1]}_${mm[2]}`, pts: pts.map(p => {
        const w = rotate(from.orientation, p);
        return rotate(inv, [w[0] + from.position[0] - to.position[0], w[1] + from.position[1] - to.position[1], w[2] + from.position[2] - to.position[2]]);
      }) };
    };
    const comps = [];
    for (const c of m.components) {
      if (!c.mesh) { comps.push({ ...c, skipped: 'no mesh (flat-tyre placeholder)' }); continue; }
      const ac = appComps.filter(a => a.name === c.name && (a.mesh || '').toLowerCase() === c.mesh.toLowerCase());
      if (ac.length !== 1) throw new Error(`${m.key}: ${ac.length} app components named ${c.name} with ${c.mesh}`);
      const a = ac[0];
      const g = glbOf(c.mesh);
      const slot = a.bind?.slotName ?? c.slot;
      let pts = transformed(g.pts, a), frame = slot;
      const moved = toWheelFrame(pts, slot);
      if (moved) { pts = moved.pts; frame = moved.slot; }
      const identity = a.orientation.every((v, i) => Math.abs(v - [0, 0, 0, 1][i]) < 1e-6);
      comps.push({
        name: c.name, role: c.role, flags: c.flags, slot, bindName: a.bind?.bindName ?? null, measuredIn: frame,
        mesh: c.mesh, chunks: g.chunks, position: a.position.map(r4), orientation: a.orientation, identityRotation: identity,
        visualScale: a.visualScale.map(r4),
        measured: c.role === 'tire' ? measureTyre(pts) : measureRim(pts),
      });
    }
    models.push({ key: m.key, label: m.label, record: m.record, vehicleType: m.vehicleType, appearance: m.playerAppearance,
                  tweakdbWheels: m.tweakdbWheels, wheelSlots: m.wheelSlots, slotFrames: frames, components: comps });
  }
  fs.writeFileSync(outFile, JSON.stringify({ schema: 'open77.vehicle-kit.wheel-measurements/1', gameVersion: plan.gameVersion, dealer: plan.dealer, models }, null, 2));
  // Print the table.
  for (const m of models) {
    console.log(`\n=== ${m.key} ${m.record}`);
    const f = m.slotFrames;
    if (f.error) console.log(`  slots: ${f.error}`);
    else for (const [s, x] of Object.entries(f.slots)) {
      if (!/^(wheel|axle|brake)/.test(s) || /_[cd]$/.test(s)) continue;
      console.log(`  slot ${s.padEnd(26)} bone ${String(x.bone).padEnd(26)} ${x.error || `pos ${x.position.join(',')} q ${x.orientation.join(',')}`}`);
    }
    for (const c of m.components) {
      if (c.skipped) continue;
      const x = c.measured;
      const rot = c.identityRotation ? '' : ` ROT ${c.orientation.map(r3)}`;
      const pos = c.position.some(v => v) ? ` POS ${c.position}` : '';
      const tail = c.role === 'tire'
        ? `bead ${x.beadRadiusOutboard}/${x.beadRadiusInboard} outer ${x.outerRadius}`
        : c.role === 'other' ? `r ${x.minRadius}..${x.outerRadius}`
        : `lip ${x.lipRadius} outer ${x.outerRadius} min ${x.minRadius}`;
      const inFrame = c.measuredIn !== c.slot ? ` (in ${c.measuredIn} frame)` : '';
      const cover = c.role === 'tire' ? '' : ` cover ${x.angularCoverage}`;
      console.log(`  ${c.role.padEnd(4)} ${c.name.padEnd(36)} ${String(c.slot).padEnd(24)} vs ${c.visualScale.join(',').padEnd(14)} x[${x.faceX}, ${x.innerX}] ${tail}${cover}${rot}${pos}${inFrame}`);
    }
  }
  console.log(`\nVK_WHEELS_MEASURED models=${models.length} meshes=${glbCache.size} -> ${outFile}`);
}

// ------------------------------------------------------------------------------------ fit
// Tuning (metres). The lip may tuck this far under the tyre bead so polygon edges never
// leave a hairline gap; it never exceeds the stock rim's own lip.
const BEAD_TUCK = 0.0015;
// A wheel whose fit differs from the reference wheel by more than this gets its own entry.
const SLOT_TOLERANCE = { offset: 0.002, scale: 0.01 };
// Our centre deeper than the stock one by more than this may clip brake parts.
const CENTRE_DEPTH_WARN = 0.01;

function wheelGroups(model) {
  const bike = model.vehicleType !== 'Car';
  const comps = model.components.filter(c => !c.skipped);
  const groupOf = c => {
    const s = c.slot || '';
    if (bike) return /front/.test(s) ? 'wheel_front' : /back|rear/.test(s) ? 'wheel_back' : null;
    // brake_<axle>_<side> centres belong to their wheel; a _b suffix is a further axle (6x6).
    const m = s.match(/^(?:wheel|brake)_(front|back)_(left|right)(_[a-z])?$/);
    return m ? `wheel_${m[1]}_${m[2]}${m[3] || ''}` : null;
  };
  const groups = {};
  for (const c of comps) {
    const g = groupOf(c);
    if (!g) continue;
    (groups[g] ||= { rims: [], tyres: [], centres: [], others: [] });
    if (c.role === 'tire') groups[g].tyres.push(c);
    else if (c.role === 'other') groups[g].others.push(c);
    else if (/^brake_/.test(c.slot || '')) groups[g].centres.push(c);
    else groups[g].rims.push(c);
  }
  return { bike, groups, extra: comps.filter(c => !groupOf(c)) };
}

// rim: the spec's shared rim geometry; centreBack: { partId: centreBackX } from the built
// part metas (optional); axial: also scale along the axle to the stock rim width.
function fitWheel(group, rim, centreBack, axial) {
  const rims = group.rims, tyres = group.tyres;
  if (!rims.length || !tyres.length) return { error: `rim components ${rims.length}, tyre components ${tyres.length}` };
  const faceX = Math.min(...rims.map(c => c.measured.faceX));
  const innerX = Math.max(...rims.map(c => c.measured.innerX));
  const lip = Math.max(...rims.map(c => c.measured.lipRadius));
  const outer = Math.max(...rims.map(c => c.measured.outerRadius));
  const bead = Math.min(...tyres.map(c => c.measured.beadRadiusOutboard));
  const tyreFace = Math.min(...tyres.map(c => c.measured.faceX));
  const tyreInner = Math.max(...tyres.map(c => c.measured.innerX));
  const tyreOuter = Math.max(...tyres.map(c => c.measured.outerRadius));
  const hubs = rims.map(c => c.measured.hubX).filter(Boolean);
  const stockHubX = hubs.length ? [Math.min(...hubs.map(h => h[0])), Math.max(...hubs.map(h => h[1]))] : null;
  const target = Math.min(outer, bead + BEAD_TUCK);
  const s = target / rim.radius;
  // Motorcycles are seen from both sides: the rim also keeps the stock width along the axle.
  const sx = axial ? (innerX - faceX) / rim.width : s;
  const offsetX = faceX - sx * rim.face_x;
  const ourInboard = offsetX + sx * (rim.face_x + rim.width);
  const w = {
    stock: { faceX: r4(faceX), innerX: r4(innerX), width: r4(innerX - faceX), lipRadius: r4(lip), outerRadius: r4(outer),
             hubX: stockHubX && stockHubX.map(r4), visualScale: rims[0].visualScale,
             tyre: { beadRadius: r4(bead), outerRadius: r4(tyreOuter), faceX: r4(tyreFace), innerX: r4(tyreInner) } },
    targetLipRadius: r4(target), scale: [r4(sx), r4(s), r4(s)], offsetX: r4(offsetX),
    ours: { faceX: r4(offsetX + sx * rim.face_x), inboardX: r4(ourInboard), width: r4(sx * rim.width), lipRadius: r4(target) },
    hide: rims.map(c => c.name),
    centres: group.centres.map(c => ({ name: c.name, slot: c.slot, faceX: c.measured.faceX, innerX: c.measured.innerX, outerRadius: c.measured.outerRadius,
                                       angularCoverage: c.measured.angularCoverage })),
    flags: [],
  };
  // Centres on a brake slot (Cortes hub and caliper, Semimaru cover) that reach into the
  // space of the new rim would clip through or cover it: hide them with the rim.
  w.hiddenCentres = w.centres.filter(c => c.faceX < ourInboard).map(c => c.name);
  // Other stock meshes on this wheel (brake, hub, axle), measured in their own slot frame:
  // left in place, reported when they reach inside the new rim.
  w.others = group.others.map(c => ({ name: c.name, slot: c.slot, x: [c.measured.faceX, c.measured.innerX], radius: [c.measured.minRadius, c.measured.outerRadius] }));
  for (const o of w.others) {
    if (o.x[0] < ourInboard && o.x[1] > w.ours.faceX && o.radius[0] < target) w.flags.push(`stock ${o.name} (${o.slot}) shares the rim volume: x ${o.x.join('..')}, r ${o.radius.join('..')}`);
  }
  if (ourInboard > tyreInner + 0.005) w.flags.push(`barrel ends ${r3(ourInboard - tyreInner)} m inboard of the tyre`);
  if (centreBack && stockHubX) {
    const ours = Object.entries(centreBack).map(([id, x]) => [id, offsetX + sx * x]).sort((a, b) => b[1] - a[1]);
    w.ours.centreBackX = { deepest: ours[0][0], x: r4(ours[0][1]), shallowest: ours.at(-1)[0], xMin: r4(ours.at(-1)[1]) };
    const deeper = ours.filter(([, x]) => x > stockHubX[1] + CENTRE_DEPTH_WARN).map(([id, x]) => `${id} +${r3(x - stockHubX[1])}`);
    if (deeper.length) w.flags.push(`centre deeper than stock (${deeper.join(', ')} m)`);
  }
  return w;
}

// Position and spin-axis relation of two slot frames (the bike rims bind to their own slots).
function frameRelation(a, b) {
  if (!a?.orientation || !b?.orientation) return null;
  const xa = rotate(a.orientation, [1, 0, 0]), xb = rotate(b.orientation, [1, 0, 0]);
  return { distance: r4(Math.hypot(a.position[0] - b.position[0], a.position[1] - b.position[1], a.position[2] - b.position[2])),
           spinAxisDot: r3(xa[0] * xb[0] + xa[1] * xb[1] + xa[2] * xb[2]) };
}

function loadCentreBack(partsDir, rims) {
  if (!partsDir) return null;
  const out = {};
  for (const p of rims) {
    // build-pack writes work/parts/<id>/<id>.part.json; a flat folder also works.
    const file = [path.join(partsDir, p.id, `${p.id}.part.json`), path.join(partsDir, `${p.id}.part.json`)].find(f => fs.existsSync(f));
    if (!file) return null;
    const meta = readJson(file), x = meta.mount?.centreBackX ?? meta.meta?.mount?.centreBackX;
    if (typeof x !== 'number') return null;
    out[p.id] = x;
  }
  return out;
}

function fit(measureFile, specFile, outFile, partsDir) {
  const meas = readJson(measureFile), spec = readJson(specFile);
  const rims = spec.parts.filter(p => p.kind === 'rim');
  const geo = p => ({ radius: p.params.radius ?? 0.28, face_x: p.params.face_x ?? -0.208, width: p.params.width ?? 0.30 });
  const g0 = geo(rims[0]);
  for (const p of rims) {
    const g = geo(p);
    if (g.radius !== g0.radius || g.face_x !== g0.face_x || g.width !== g0.width) throw new Error(`rim ${p.id} does not share the base geometry of ${rims[0].id}; the fit table assumes one`);
  }
  const centreBack = loadCentreBack(partsDir, rims);
  if (partsDir && !centreBack) console.log(`(no centreBackX in ${partsDir}: centre depth not compared)`);
  const fitByRecord = {}, mountTable = [], excluded = {};
  const policy = spec.fitPolicy || {};
  for (const m of meas.models) {
    const { bike, groups, extra } = wheelGroups(m);
    const main = bike ? ['wheel_front', 'wheel_back'] : CAR_SLOTS;
    const further = bike ? [] : Object.keys(groups).filter(g => !CAR_SLOTS.includes(g)).sort();
    const wheels = {};
    for (const slot of [...main, ...further]) wheels[slot] = groups[slot] ? fitWheel(groups[slot], g0, centreBack, bike) : { error: 'no components on this wheel' };
    const errors = main.filter(s => wheels[s].error).map(s => `${s}: ${wheels[s].error}`);
    const excludeReason = (policy.exclude || {})[m.key];
    const row = { key: m.key, label: m.label, record: m.record, vehicleType: m.vehicleType, appearance: m.appearance, wheels };
    const slotsOf = m.slotFrames.slots || {};
    if (bike) {
      // Where the stock rims bind, against the contract's wheel_front / wheel_back slots.
      row.slotRelation = Object.fromEntries(main.filter(s => groups[s]?.rims.length).map(s => {
        const bound = groups[s].rims[0].slot;
        return [s, { stockSlot: bound, relation: bound === s ? 'same slot' : frameRelation(slotsOf[s], slotsOf[bound]) ?? 'slot frame not found' }];
      }));
    } else {
      // Right-hand slot frames are the left ones turned 180 degrees about Z (spin axis
      // reversed, so -X still points outboard); the stock right rims bind the left mesh
      // with no rotation of their own, or only a spin phase about X (Colby, Merrimac). A
      // rim made for the left side is therefore correct on the right with no extra turn.
      const rig = Object.fromEntries(['front', 'back'].map(a => [a, rightVsLeft(slotsOf[`wheel_${a}_left`], slotsOf[`wheel_${a}_right`])]));
      const rights = ['wheel_front_right', 'wheel_back_right'].flatMap(s => groups[s]?.rims || []);
      const lefts = ['wheel_front_left', 'wheel_back_left'].flatMap(s => groups[s]?.rims || []);
      const leftMeshes = new Set(lefts.map(c => c.mesh.toLowerCase()));
      const aboutX = c => Math.abs(c.orientation[1]) < 1e-4 && Math.abs(c.orientation[2]) < 1e-4;
      const own = rights.every(c => c.identityRotation) ? 'none' : rights.every(aboutX) ? 'spin phase about X only' : 'OTHER';
      const sameMesh = rights.every(c => leftMeshes.has(c.mesh.toLowerCase()));
      const turned = Object.values(rig).every(r => /^turned180aboutZ|^xFlipped/.test(r));
      row.rightSide = { slotFrameVsLeft: rig, stockRightRimRotation: own, stockRightRimsShareLeftMesh: sameMesh,
                        extraTurn: turned && own !== 'OTHER' ? 'none' : 'CHECK' };
    }
    row.stockOnly = extra.filter(c => c.role === 'rim').map(c => ({ name: c.name, slot: c.slot, note: 'not on a wheel slot (spare wheel or prop): left stock' }));
    mountTable.push(row);
    if (errors.length || excludeReason) { excluded[m.record] = excludeReason || errors.join('; '); row.excluded = excluded[m.record]; continue; }
    // One record-level fit (contract §5) from the reference wheel (front-left, or the bike's
    // front); a wheel that differs gets its own entry under `slots`.
    const ref = wheels[main[0]];
    const hideOf = w => [...w.hide, ...w.hiddenCentres];
    const entry = {
      offset: [ref.offsetX, 0, 0], scale: ref.scale,
      hide: [...new Set(main.flatMap(s => hideOf(wheels[s])))].sort(),
    };
    const differs = w => Math.abs(w.offsetX - ref.offsetX) > SLOT_TOLERANCE.offset
      || w.scale.some((v, i) => Math.abs(v / ref.scale[i] - 1) > SLOT_TOLERANCE.scale);
    const overrides = {};
    for (const s of main) if (differs(wheels[s])) overrides[s] = { offset: [wheels[s].offsetX, 0, 0], scale: wheels[s].scale };
    if (Object.keys(overrides).length) entry.slots = overrides;
    // Further axles (Merrimac 6x6): their own slots and hide lists, so a client that only
    // drives the four contract slots leaves those wheels stock instead of rimless.
    if (further.length) {
      entry.extraSlots = Object.fromEntries(further.filter(s => !wheels[s].error).map(s => [s, {
        offset: [wheels[s].offsetX, 0, 0], scale: wheels[s].scale, hide: hideOf(wheels[s]).sort() }]));
    }
    if (bike) entry.slotNames = Object.fromEntries(main.map(s => [s, groups[s].rims[0].slot]));
    fitByRecord[m.record] = entry;
  }
  const variants = p => Object.fromEntries(Object.keys(p.finishes).map(f => [f, `asset:${spec.resource}/${p.id}_${f}`]));
  const out = {
    schema: 'open77.vehicle-kit.rim-fit/1',
    resource: spec.resource,
    generatedBy: 'scripts/vehicle-kit/measure-wheels.ps1 (measure-wheels.cjs fit)',
    gameVersion: meas.gameVersion,
    conventions: {
      frame: 'wheel slot frame: metres, spin axis X, -X outboard on all four car wheels (E0.5); offset and scale are the prop localTransform position and visualScale [x, y, z]',
      rimBase: g0,
      scale: `lip radius = min(stock rim outer radius, tyre bead radius + ${BEAD_TUCK}) / rimBase.radius on Y and Z; X is the same on cars (uniform), the stock rim width / rimBase.width on motorcycles`,
      offset: 'x = stock rim face x (after its visualScale) - scale.x * rimBase.face_x, so the new lip face is flush with the stock one; y = z = 0',
      hide: 'stock rim components of the player appearance on the four contract slots (never the tyre), plus rim centres on brake slots that reach into the new rim',
      slots: 'per-slot offset/scale where a wheel differs from the front-left (car) or front (bike) one; a client that ignores it puts the record-level fit on every wheel',
      extraSlots: 'wheels beyond the contract slots (Merrimac middle axle): slot -> offset, scale, hide; not covered by setWheels as specified',
      slotNames: 'motorcycles: contract slot -> the stock slot the stock rim binds to (the offset is measured in that frame)',
      rightSide: 'no extra turn: right slot frames are the left ones turned 180 deg about Z (so -X stays outboard), and the stock right rims use the left mesh unrotated or with a spin phase about X only (mountTable[].rightSide per model)',
    },
    parts: Object.fromEntries(rims.map(p => [p.id, { kind: 'rim', label: p.label, variants: variants(p) }])),
    fit: fitByRecord,
    excluded,
    mountTable,
  };
  fs.writeFileSync(outFile, JSON.stringify(out, null, 2) + '\n');
  for (const row of mountTable) {
    const f = fitByRecord[row.record];
    console.log(`\n${row.key.padEnd(9)} ${f ? 'FIT ' : 'EXCL'} ${row.record}${row.excluded ? `  -- ${row.excluded}` : ''}`);
    for (const [s, x] of Object.entries(row.wheels)) {
      if (x.error) { console.log(`   ${s.padEnd(22)} ERROR ${x.error}`); continue; }
      const st = x.stock;
      console.log(`   ${s.padEnd(22)} stock face ${st.faceX} width ${st.width} lip ${st.lipRadius} bead ${st.tyre.beadRadius} hub ${st.hubX ? st.hubX.join('..') : '-'}`
        + ` -> scale ${x.scale.join(',')} offset ${x.offsetX} inboard ${x.ours.inboardX} (tyre ${st.tyre.innerX})`
        + `${x.hiddenCentres.length ? ` hide+ ${x.hiddenCentres.join(',')}` : ''}${x.flags.length ? `  !! ${x.flags.join('; ')}` : ''}`);
    }
    if (row.rightSide) console.log(`   right side: ${JSON.stringify(row.rightSide)}`);
    if (row.slotRelation) console.log(`   slots: ${JSON.stringify(row.slotRelation)}`);
    if (f?.slots) console.log(`   per-slot overrides: ${Object.keys(f.slots).join(', ')}`);
    if (f?.extraSlots) console.log(`   extra slots: ${Object.keys(f.extraSlots).join(', ')}`);
    if (row.stockOnly.length) console.log(`   left stock: ${row.stockOnly.map(c => `${c.name} (${c.slot})`).join(', ')}`);
  }
  console.log(`\nVK_RIM_FIT_OK records=${Object.keys(fitByRecord).length} excluded=${Object.keys(excluded).length} -> ${outFile}`);
}

const [cmd, ...args] = process.argv.slice(2);
if (cmd === 'measure') measure(...args);
else if (cmd === 'fit') fit(...args);
else { console.error('usage: measure-wheels.cjs measure <plan> <out> | fit <measurements> <spec> <out> [<parts dir>]'); process.exit(2); }
