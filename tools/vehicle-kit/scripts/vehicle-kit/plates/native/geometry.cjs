// Small geometry kit for the plate pack: quaternions, rigid transforms, a glTF reader
// (WolvenKit `uncook --mesh-export-type MeshOnly` output) and a ray/triangle test.
// Engine axes everywhere: metres, X right, Y forward, Z up. WolvenKit's glTF is Y-up:
// (x, y, z)gltf = (x, z, -y)engine, so engine = (gx, -gz, gy).
'use strict';
const fs = require('node:fs');

const FIXED_POINT = 131072;          // WorldPosition FixedPoint: Bits / 2^17 = metres

const add = (a, b) => [a[0] + b[0], a[1] + b[1], a[2] + b[2]];
const sub = (a, b) => [a[0] - b[0], a[1] - b[1], a[2] - b[2]];
const mul = (a, s) => [a[0] * s, a[1] * s, a[2] * s];
const dot = (a, b) => a[0] * b[0] + a[1] * b[1] + a[2] * b[2];
const cross = (a, b) => [a[1] * b[2] - a[2] * b[1], a[2] * b[0] - a[0] * b[2], a[0] * b[1] - a[1] * b[0]];
const len = (a) => Math.sqrt(dot(a, a));
const norm = (a) => { const l = len(a); return l ? mul(a, 1 / l) : a; };

// Quaternions as { i, j, k, r } (the RED4 field names), r the scalar part.
const qIdentity = () => ({ i: 0, j: 0, k: 0, r: 1 });
function qMul(a, b) {
  return {
    r: a.r * b.r - a.i * b.i - a.j * b.j - a.k * b.k,
    i: a.r * b.i + a.i * b.r + a.j * b.k - a.k * b.j,
    j: a.r * b.j - a.i * b.k + a.j * b.r + a.k * b.i,
    k: a.r * b.k + a.i * b.j - a.j * b.i + a.k * b.r,
  };
}
const qConj = (q) => ({ i: -q.i, j: -q.j, k: -q.k, r: q.r });
function qNorm(q) { const l = Math.hypot(q.i, q.j, q.k, q.r) || 1; return { i: q.i / l, j: q.j / l, k: q.k / l, r: q.r / l }; }
function qRotate(q, v) {
  const p = qMul(qMul(q, { i: v[0], j: v[1], k: v[2], r: 0 }), qConj(q));
  return [p.i, p.j, p.k];
}
// Columns of m are the images of the unit axes.
function qFromBasis(cx, cy, cz) {
  const m00 = cx[0], m10 = cx[1], m20 = cx[2], m01 = cy[0], m11 = cy[1], m21 = cy[2], m02 = cz[0], m12 = cz[1], m22 = cz[2];
  const t = m00 + m11 + m22;
  let q;
  if (t > 0) { const s = Math.sqrt(t + 1) * 2; q = { r: s / 4, i: (m21 - m12) / s, j: (m02 - m20) / s, k: (m10 - m01) / s }; }
  else if (m00 > m11 && m00 > m22) { const s = Math.sqrt(1 + m00 - m11 - m22) * 2; q = { r: (m21 - m12) / s, i: s / 4, j: (m01 + m10) / s, k: (m02 + m20) / s }; }
  else if (m11 > m22) { const s = Math.sqrt(1 + m11 - m00 - m22) * 2; q = { r: (m02 - m20) / s, i: (m01 + m10) / s, j: s / 4, k: (m12 + m21) / s }; }
  else { const s = Math.sqrt(1 + m22 - m00 - m11) * 2; q = { r: (m10 - m01) / s, i: (m02 + m20) / s, j: (m12 + m21) / s, k: s / 4 }; }
  q = qNorm(q);
  if (q.r < 0) q = { i: -q.i, j: -q.j, k: -q.k, r: -q.r };
  return q;
}
// Yaw (degrees, about +Z) of a quaternion's +Y axis, ignoring pitch and roll.
function qYawDegrees(q) { const f = qRotate(q, [0, 1, 0]); return (Math.atan2(-f[0], f[1]) * 180) / Math.PI; }

// Rigid transforms { p: [x, y, z], q }. compose(parent, local) = parent * local.
const tIdentity = () => ({ p: [0, 0, 0], q: qIdentity() });
const tCompose = (a, b) => ({ p: add(a.p, qRotate(a.q, b.p)), q: qNorm(qMul(a.q, b.q)) });
function tInvert(a) { const qi = qConj(a.q); return { p: mul(qRotate(qi, a.p), -1), q: qi }; }
const tPoint = (a, v) => add(a.p, qRotate(a.q, v));
const tDir = (a, v) => qRotate(a.q, v);

function fromWorldTransform(wt) {
  if (!wt) return tIdentity();
  const P = wt.Position || {};
  const o = wt.Orientation || { i: 0, j: 0, k: 0, r: 1 };
  const bits = (f) => (f && typeof f.Bits === 'number' ? f.Bits / FIXED_POINT : 0);
  return { p: [bits(P.x), bits(P.y), bits(P.z)], q: qNorm({ i: +o.i || 0, j: +o.j || 0, k: +o.k || 0, r: o.r === undefined ? 1 : +o.r }) };
}

// ----------------------------------------------------------------------------- glTF
function readGlb(file) {
  const b = fs.readFileSync(file);
  if (b.readUInt32LE(0) !== 0x46546c67) throw new Error(`${file} is not a glb`);
  const jsonLength = b.readUInt32LE(12);
  const doc = JSON.parse(b.subarray(20, 20 + jsonLength).toString('utf8'));
  const binOffset = 20 + jsonLength + 8;
  const bin = b.subarray(binOffset);
  const width = { SCALAR: 1, VEC2: 2, VEC3: 3, VEC4: 4 };
  const bytes = { 5120: 1, 5121: 1, 5122: 2, 5123: 2, 5125: 4, 5126: 4 };
  function accessor(index) {
    const a = doc.accessors[index];
    const view = doc.bufferViews[a.bufferView];
    const n = width[a.type];
    const size = bytes[a.componentType];
    const stride = view.byteStride || n * size;
    const base = (view.byteOffset || 0) + (a.byteOffset || 0);
    const out = new Array(a.count);
    for (let k = 0; k < a.count; k++) {
      const row = new Array(n);
      for (let c = 0; c < n; c++) {
        const at = base + k * stride + c * size;
        let v;
        switch (a.componentType) {
          case 5126: v = bin.readFloatLE(at); break;
          case 5125: v = bin.readUInt32LE(at); break;
          case 5123: v = bin.readUInt16LE(at); if (a.normalized) v /= 65535; break;
          case 5122: v = bin.readInt16LE(at); if (a.normalized) v = Math.max(v / 32767, -1); break;
          case 5121: v = bin.readUInt8(at); if (a.normalized) v /= 255; break;
          case 5120: v = bin.readInt8(at); if (a.normalized) v = Math.max(v / 127, -1); break;
          default: throw new Error(`unsupported component type ${a.componentType}`);
        }
        row[c] = v;
      }
      out[k] = row;
    }
    return out;
  }
  // One entry per chunk of the first LOD: WolvenKit names meshes submesh_<chunk>_LOD_<n>.
  const chunks = [];
  doc.meshes.forEach((m) => {
    const match = /^submesh_(\d+)_LOD_(\d+)/.exec(m.name || '');
    if (!match || match[2] !== '1') return;
    for (const p of m.primitives) {
      const positions = accessor(p.attributes.POSITION).map(([x, y, z]) => [x, -z, y]);
      const uvs = p.attributes.TEXCOORD_0 !== undefined ? accessor(p.attributes.TEXCOORD_0) : null;
      const indices = p.indices !== undefined ? accessor(p.indices).map((r) => r[0]) : positions.map((_, i) => i);
      chunks.push({ chunk: Number(match[1]), name: m.name, positions, uvs, indices });
    }
  });
  chunks.sort((a, b) => a.chunk - b.chunk);
  return chunks;
}

// Least-squares slope of value against each engine axis.
function gradient(points, values) {
  const n = points.length;
  const mean = (arr) => arr.reduce((s, x) => s + x, 0) / n;
  const mv = mean(values);
  return [0, 1, 2].map((axis) => {
    const xs = points.map((p) => p[axis]);
    const mx = mean(xs);
    let num = 0, den = 0;
    for (let k = 0; k < n; k++) { num += (xs[k] - mx) * (values[k] - mv); den += (xs[k] - mx) ** 2; }
    return den > 1e-12 ? num / den : 0;
  });
}

// Möller-Trumbore, both faces. Returns the distance along dir, or null.
function rayTriangle(origin, dir, a, b, c) {
  const e1 = sub(b, a), e2 = sub(c, a);
  const h = cross(dir, e2);
  const det = dot(e1, h);
  if (Math.abs(det) < 1e-12) return null;
  const f = 1 / det;
  const s = sub(origin, a);
  const u = f * dot(s, h);
  if (u < 0 || u > 1) return null;
  const q = cross(s, e1);
  const v = f * dot(dir, q);
  if (v < 0 || u + v > 1) return null;
  const t = f * dot(e2, q);
  return t > 1e-6 ? t : null;
}

function rayMesh(origin, dir, chunks) {
  let best = null;
  for (const ch of chunks) {
    const P = ch.positions, I = ch.indices;
    for (let k = 0; k + 2 < I.length; k += 3) {
      const t = rayTriangle(origin, dir, P[I[k]], P[I[k + 1]], P[I[k + 2]]);
      if (t !== null && (best === null || t < best)) best = t;
    }
  }
  return best;
}

module.exports = {
  FIXED_POINT, add, sub, mul, dot, cross, len, norm,
  qIdentity, qMul, qConj, qNorm, qRotate, qFromBasis, qYawDegrees,
  tIdentity, tCompose, tInvert, tPoint, tDir, fromWorldTransform,
  readGlb, gradient, rayMesh,
};
