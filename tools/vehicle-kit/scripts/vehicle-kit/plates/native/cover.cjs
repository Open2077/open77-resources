// Where the plate quad goes, and the offline proof that no factory print shows around it.
//
// Every vanilla plate mesh draws its printed face ("NC 77...") on one "holo" chunk, a
// parallax-screen layer: a flat rectangle (a bent one on license_plate_angle_01). Our screen
// quad has to hide that layer. The 2026-11-05 rule ("fit" below) fitted the quad INSIDE the
// holo rectangle at the design aspect, in front of the plate's top bar: a band of print
// stayed visible wherever the aspects differ (11 mm above and below on the car plate, 31 mm
// left and right on the Kusanagi plate), and the 11 to 23 mm gap between quad and holo
// widened it at an angle. The lead saw it in game on the Archer Hella (23:00).
//
// The "cover" rule:
//   * depth: the quad goes proudMetres in front of the holo's own outermost point, not in
//     front of the bar, so that the gap g between the quad and the deepest holo point is a
//     few millimetres. Any other plate surface within clearanceMetres of that plane, over
//     the quad, pushes the quad out in front of it (no z-fighting);
//   * size: the holo rectangle grown on every side by g * tan(coverMaxViewDegrees) +
//     coverExtraMetres. A ray leaving any holo point at up to that angle from the plate
//     normal travels at most g * tan(angle) sideways before it reaches the quad plane, so it
//     hits the quad. That holds on its own, without counting on the bar or a frame;
//   * the widget item is authored at the quad's aspect and draws the design inside the holo
//     rectangle, the rest in the design's background colour (inkwidget.cjs). No stretch.
// leakTest() checks the result by casting rays from the holo towards the viewer.
'use strict';
const G = require('./geometry.cjs');

const DEG = Math.PI / 180;
const r4 = (v) => Math.round(v * 1e4) / 1e4;
const mm = (v) => Math.round(v * 1e4) / 10;
const leaf = (p) => p.split('\\').pop();
function fail(message) { throw new Error(message); }

// ----------------------------------------------------------------------------- triangles
function trianglesOf(chunks) {
  const out = [];
  for (const ch of chunks) {
    const P = ch.positions, I = ch.indices;
    for (let k = 0; k + 2 < I.length; k += 3) out.push([P[I[k]], P[I[k + 1]], P[I[k + 2]]]);
  }
  return out;
}

// Triangles packed as [a, b-a, c-a] (9 floats) with one bounding box, for fast ray tests.
function pack(tris) {
  const f = new Float64Array(tris.length * 9);
  const lo = [Infinity, Infinity, Infinity], hi = [-Infinity, -Infinity, -Infinity];
  tris.forEach(([a, b, c], i) => {
    f.set([a[0], a[1], a[2], b[0] - a[0], b[1] - a[1], b[2] - a[2], c[0] - a[0], c[1] - a[1], c[2] - a[2]], i * 9);
    for (const p of [a, b, c]) for (let k = 0; k < 3; k++) { lo[k] = Math.min(lo[k], p[k]); hi[k] = Math.max(hi[k], p[k]); }
  });
  return { f, n: tris.length, lo, hi };
}

// Slab test: does the ray (o, d) touch the box at all?
function boxHit(g, o, d) {
  let t0 = -Infinity, t1 = Infinity;
  for (let k = 0; k < 3; k++) {
    const pad = 1e-6;
    if (Math.abs(d[k]) < 1e-12) { if (o[k] < g.lo[k] - pad || o[k] > g.hi[k] + pad) return false; continue; }
    let a = (g.lo[k] - pad - o[k]) / d[k], b = (g.hi[k] + pad - o[k]) / d[k];
    if (a > b) [a, b] = [b, a];
    t0 = Math.max(t0, a); t1 = Math.min(t1, b);
    if (t0 > t1) return false;
  }
  return t1 > 0;
}

// Möller-Trumbore over a packed group, both faces. mode 'any': true on the first hit;
// 'near': the nearest t (or Infinity) with its triangle index; 'all': every t.
function cast(g, o, d, mode, tmin = 1e-7) {
  if (!boxHit(g, o, d)) return mode === 'any' ? false : mode === 'all' ? [] : { t: Infinity, i: -1 };
  const f = g.f;
  let best = Infinity, bi = -1;
  const all = mode === 'all' ? [] : null;
  for (let i = 0; i < g.n; i++) {
    const j = i * 9;
    const e1x = f[j + 3], e1y = f[j + 4], e1z = f[j + 5], e2x = f[j + 6], e2y = f[j + 7], e2z = f[j + 8];
    const hx = d[1] * e2z - d[2] * e2y, hy = d[2] * e2x - d[0] * e2z, hz = d[0] * e2y - d[1] * e2x;
    const det = e1x * hx + e1y * hy + e1z * hz;
    if (det > -1e-14 && det < 1e-14) continue;
    const inv = 1 / det;
    const sx = o[0] - f[j], sy = o[1] - f[j + 1], sz = o[2] - f[j + 2];
    const u = inv * (sx * hx + sy * hy + sz * hz);
    if (u < 0 || u > 1) continue;
    const qx = sy * e1z - sz * e1y, qy = sz * e1x - sx * e1z, qz = sx * e1y - sy * e1x;
    const v = inv * (d[0] * qx + d[1] * qy + d[2] * qz);
    if (v < 0 || u + v > 1) continue;
    const t = inv * (e2x * qx + e2y * qy + e2z * qz);
    if (t <= tmin) continue;
    if (mode === 'any') return true;
    if (all) all.push({ t, i });
    else if (t < best) { best = t; bi = i; }
  }
  return mode === 'any' ? false : all ? all : { t: best, i: bi };
}

// Points spread evenly over triangles, about one per step x step, each with its area.
function sampleTriangles(tris, step) {
  const out = [];
  for (const [a, b, c] of tris) {
    const area = G.len(G.cross(G.sub(b, a), G.sub(c, a))) / 2;
    if (area < 1e-10) continue;
    const n = Math.max(1, Math.ceil(Math.max(G.len(G.sub(b, a)), G.len(G.sub(c, a)), G.len(G.sub(c, b))) / step));
    const pts = [];
    for (let i = 0; i < n; i++) for (let j = 0; i + j < n; j++) {
      pts.push([(i + 1 / 3) / n, (j + 1 / 3) / n]);
      if (i + j < n - 1) pts.push([(i + 2 / 3) / n, (j + 2 / 3) / n]);
    }
    const w = area / pts.length;
    for (const [u, v] of pts) out.push({ p: G.add(a, G.add(G.mul(G.sub(b, a), u), G.mul(G.sub(c, a), v))), w });
  }
  return out;
}

// ----------------------------------------------------------------------------- the plate
// Chunk roles from the mesh's default appearance: the holo layer (the print), the overlays
// (decals and stickers: alpha-tested, not trusted to hide anything) and the opaque body.
function chunkRoles(chunks, materials, holoChunk) {
  const role = (c) => c.chunk === holoChunk ? 'holo' : /decal|sticker/i.test(materials[c.chunk] || '') ? 'overlay' : 'body';
  return {
    holo: chunks.filter((c) => role(c) === 'holo'),
    overlay: chunks.filter((c) => role(c) === 'overlay'),
    body: chunks.filter((c) => role(c) === 'body'),
  };
}

// The holo rectangle (or the chord of a bent one) with its reading frame R (text right),
// U (text up), N = R x U out of the plate; the holo's depth range along N; and, for the
// superseded rule, the outermost geometry over the rectangle grown by legacyMarginMetres.
function measurePlate(depot, chunks, cfg, materials, placement) {
  const roles = chunkRoles(chunks, materials, cfg.holoChunk);
  const holo = roles.holo[0];
  if (!holo) fail(`${leaf(depot)}: no chunk ${cfg.holoChunk} in the glb`);
  const P = holo.positions;
  const lo = [0, 1, 2].map((i) => Math.min(...P.map((p) => p[i])));
  const hi = [0, 1, 2].map((i) => Math.max(...P.map((p) => p[i])));
  const R = [1, 0, 0];
  let U, center, height;
  const bent = hi[1] - lo[1] > 0.002;
  if (!bent) {
    U = [0, 0, 1];
    center = [(lo[0] + hi[0]) / 2, P.reduce((s, p) => s + p[1], 0) / P.length, (lo[2] + hi[2]) / 2];
    height = hi[2] - lo[2];
  } else {
    const avg = (pts) => [0, 1, 2].map((i) => pts.reduce((s, p) => s + p[i], 0) / pts.length);
    const top = avg(P.filter((p) => p[2] > hi[2] - 0.0015));
    const bottom = avg(P.filter((p) => p[2] < lo[2] + 0.0015));
    const chord = [0, top[1] - bottom[1], top[2] - bottom[2]];
    U = G.norm(chord);
    height = G.len(chord);
    center = [(lo[0] + hi[0]) / 2, (top[1] + bottom[1]) / 2, (top[2] + bottom[2]) / 2];
  }
  const N = G.cross(R, U);
  if (N[1] >= 0) fail(`${leaf(depot)}: holo layer does not face -Y`);
  const width = hi[0] - lo[0];
  if (holo.uvs) {
    const du = G.gradient(P, holo.uvs.map((t) => t[0]));
    const dv = G.gradient(P, holo.uvs.map((t) => t[1]));
    if (G.dot(du, R) <= 0 || G.dot(dv, U) >= 0) fail(`${leaf(depot)}: holo UVs do not read along +X / down (du ${du}, dv ${dv})`);
  }
  const depth = (v) => G.dot(G.sub(v, center), N);
  const along = (v) => [G.dot(G.sub(v, center), R), G.dot(G.sub(v, center), U)];
  // The holo's extent along R and U around the centre: for a bent holo the chord rectangle
  // may not hold every vertex exactly; take the true extent.
  const ab = P.map(along);
  const face = { left: Math.min(...ab.map((x) => x[0])), right: Math.max(...ab.map((x) => x[0])), bottom: Math.min(...ab.map((x) => x[1])), top: Math.max(...ab.map((x) => x[1])) };
  const holoFront = Math.max(...P.map(depth));
  const holoBack = Math.min(...P.map(depth));
  const m = placement.legacyMarginMetres;
  let legacyOutward = 0;
  for (const ch of chunks) {
    for (const v of ch.positions) {
      const [a, b] = along(v);
      if (Math.abs(a) <= width / 2 + m && Math.abs(b) <= height / 2 + m) legacyOutward = Math.max(legacyOutward, depth(v));
    }
  }
  const all = chunks.flatMap((c) => c.positions);
  const bbox = { min: [0, 1, 2].map((i) => Math.min(...all.map((p) => p[i]))), max: [0, 1, 2].map((i) => Math.max(...all.map((p) => p[i]))) };
  return {
    depot, holoChunk: cfg.holoChunk, bent, width: r4(width), height: r4(height),
    center: center.map(r4), R, U: U.map(r4), N: N.map(r4), face: Object.fromEntries(Object.entries(face).map(([k, v]) => [k, r4(v)])),
    holoFront: r4(holoFront), holoBack: r4(holoBack), legacyOutward: r4(legacyOutward), bbox: { min: bbox.min.map(r4), max: bbox.max.map(r4) },
  };
}

// ----------------------------------------------------------------------------- placements
// A placement is a rectangle in the plate's (R, U) frame, relative to the holo centre, at a
// depth along N.

// Superseded rule (2026-11-05, kept to measure the defect): fitted inside the holo at the
// design aspect, proudMetres in front of every vertex over the holo grown by 1.5 cm.
function legacyPlacement(plate, aspect, placement) {
  let width = plate.width, height = width / aspect;
  if (height > plate.height) { height = plate.height; width = height * aspect; }
  return { rule: 'fit', aspect, depth: plate.legacyOutward + placement.proudMetres, rect: { left: -width / 2, right: width / 2, bottom: -height / 2, top: height / 2 } };
}

// The surface seen first from the front, looking down -N, at each point of a grid over the
// rectangle: its depth along N and how parallel it is to the quad (|cos| of the angle
// between the normals). Whatever lies behind it is hidden from the front anyway.
function surfacesOver(plate, group, rect, step) {
  const out = [];
  const N = plate.N, R = plate.R, U = plate.U;
  const d = G.mul(N, -1);
  for (let a = rect.left; a <= rect.right + 1e-9; a += step) {
    for (let b = rect.bottom; b <= rect.top + 1e-9; b += step) {
      const o = G.add(G.add(G.add(plate.center, G.mul(R, a)), G.mul(U, b)), G.mul(N, 0.5));
      const h = cast(group, o, d, 'near');
      if (h.i < 0) continue;
      const j = h.i * 9, f = group.f;
      const n = G.norm(G.cross([f[j + 3], f[j + 4], f[j + 5]], [f[j + 6], f[j + 7], f[j + 8]]));
      out.push({ depth: 0.5 - h.t, a, b, parallel: Math.abs(G.dot(n, N)) });
    }
  }
  return out;
}

function coverPlacement(plate, chunks, materials, placement) {
  const roles = chunkRoles(chunks, materials, plate.holoChunk);
  const others = pack(trianglesOf([...roles.body, ...roles.overlay]));
  const tan = Math.tan(placement.coverMaxViewDegrees * DEG);
  let depth = plate.holoFront + placement.proudMetres;
  const pushes = [];
  for (let iteration = 0; iteration < 8; iteration++) {
    const gap = depth - plate.holoBack;
    const margin = gap * tan + placement.coverExtraMetres;
    const f = plate.face;
    const rect = { left: f.left - margin, right: f.right + margin, bottom: f.bottom - margin, top: f.top + margin };
    // Only a visible surface nearly parallel to the quad and within clearanceMetres of its
    // plane can z-fight with it. One that merely crosses the plane (the bar's sloped front,
    // a frame's sides) meets the quad along a line in the margin, where one hides the other.
    const near = surfacesOver(plate, others, rect, 0.001).filter((s) => s.parallel > Math.cos(placement.parallelDegrees * DEG) && Math.abs(s.depth - depth) < placement.clearanceMetres);
    if (!near.length) return { rule: 'cover', depth, gap, margin, maxViewDegrees: placement.coverMaxViewDegrees, rect, pushes };
    const top = Math.max(...near.map((s) => s.depth));
    pushes.push({ from: r4(depth), surface: r4(top), at: [r4(near[0].a), r4(near[0].b)] });
    depth = top + placement.proudMetres;
  }
  fail(`${leaf(plate.depot)}: no clear depth for the quad after 8 pushes ${JSON.stringify(pushes)}`);
}

// The quad's localTransform and visualScale in the plate component's frame: the quad's own
// reading frame (measured from its UVs) onto the plate's, its centre on the rectangle's.
function quadTransform(plate, screen, placement) {
  const { rect, depth } = placement;
  const width = rect.right - rect.left, height = rect.top - rect.bottom;
  const M = (v) => {
    const a = G.dot(v, screen.right), b = G.dot(v, screen.up), c = G.dot(v, screen.normal);
    return G.add(G.add(G.mul(plate.R, a), G.mul(plate.U, b)), G.mul(plate.N, c));
  };
  const q = G.qFromBasis(M([1, 0, 0]), M([0, 1, 0]), M([0, 0, 1]));
  const scale = [width / screen.size[0], 1, height / screen.size[1]].map((v) => Math.round(v * 1e6) / 1e6);
  const scaledCenter = [screen.center[0] * scale[0], screen.center[1] * scale[1], screen.center[2] * scale[2]];
  const target = G.add(G.add(G.add(plate.center, G.mul(plate.R, (rect.left + rect.right) / 2)), G.mul(plate.U, (rect.bottom + rect.top) / 2)), G.mul(plate.N, depth));
  const p = G.sub(target, G.qRotate(q, scaledCenter)).map((v) => Math.round(v * 1e6) / 1e6);
  return { transform: { p, q }, scale, size: [r4(width), r4(height)] };
}

// The quad's four corners in the plate frame, from the transform the pack will carry.
function quadCorners(fit, screenChunks) {
  const P = screenChunks.flatMap((c) => c.positions);
  return P.map((v) => G.add(fit.transform.p, G.qRotate(fit.transform.q, [v[0] * fit.scale[0], v[1] * fit.scale[1], v[2] * fit.scale[2]])));
}
function quadTriangles(fit, screenChunks) {
  const corners = quadCorners(fit, screenChunks);
  const tris = [];
  let base = 0;
  for (const ch of screenChunks) {
    for (let k = 0; k + 2 < ch.indices.length; k += 3) tris.push([corners[base + ch.indices[k]], corners[base + ch.indices[k + 1]], corners[base + ch.indices[k + 2]]]);
    base += ch.positions.length;
  }
  return tris;
}

// ----------------------------------------------------------------------------- the proof
// Front view: how far each holo edge sticks out of the quad, in millimetres (negative = the
// quad overlaps the edge by that much).
function frontalMargins(plate, fit) {
  const corners = fit.corners.map((v) => [G.dot(G.sub(v, plate.center), plate.R), G.dot(G.sub(v, plate.center), plate.U)]);
  const q = { left: Math.min(...corners.map((c) => c[0])), right: Math.max(...corners.map((c) => c[0])), bottom: Math.min(...corners.map((c) => c[1])), top: Math.max(...corners.map((c) => c[1])) };
  const f = plate.face;
  return { top: mm(f.top - q.top), bottom: mm(q.bottom - f.bottom), left: mm(q.left - f.left), right: mm(f.right - q.right), quad: Object.fromEntries(Object.entries(q).map(([k, v]) => [k, mm(v)])) };
}

const SIDES = { right: 0, top: 90, left: 180, bottom: 270 };

// Rays from every holo sample (about one per step x step) towards a viewer at angle theta
// from the plate normal, azimuth phi (0 = towards +R, 90 = towards +U). A sample is print
// on screen when the ray misses the plate's opaque body and the quad. Overlays (decals,
// stickers) are not trusted to hide anything, and the car around the plate is left out:
// both can only hide more.
function leakTest(plate, chunks, materials, fitTris, opts) {
  const roles = chunkRoles(chunks, materials, plate.holoChunk);
  const quad = pack(fitTris);
  const body = pack(trianglesOf(roles.body));
  const samples = sampleTriangles(trianglesOf(roles.holo), opts.step).map((s) => {
    const a = G.dot(G.sub(s.p, plate.center), plate.R), b = G.dot(G.sub(s.p, plate.center), plate.U);
    const f = plate.face;
    return { ...s, inset: { right: f.right - a, left: a - f.left, top: f.top - b, bottom: b - f.bottom } };
  });
  const totalArea = samples.reduce((s, x) => s + x.w, 0);
  const view = (theta, phi) => {
    const t = theta * DEG, p = phi * DEG;
    const d = G.norm(G.add(G.mul(plate.N, Math.cos(t)), G.mul(G.add(G.mul(plate.R, Math.cos(p)), G.mul(plate.U, Math.sin(p))), Math.sin(t))));
    let area = 0, band = 0;
    for (const s of samples) {
      if (cast(quad, s.p, d, 'any') || (body.n && cast(body, s.p, d, 'any'))) continue;
      area += s.w;
      band = Math.max(band, Math.min(s.inset.right, s.inset.left, s.inset.top, s.inset.bottom));
    }
    return { theta, phi, area, band };
  };
  // Per side: the viewer leans towards that side.
  const sides = {};
  for (const [side, phi] of Object.entries(SIDES)) {
    sides[side] = opts.sideAngles.map((theta) => { const v = view(theta, phi); return { theta, bandMm: mm(v.band), areaMm2: Math.round(v.area * 1e6) }; });
  }
  // The whole cone, every azimuth.
  let worst = { area: 0 }, conePrint = 0, coneViews = 0;
  for (const theta of opts.coneAngles) {
    for (let phi = 0; phi < 360; phi += 360 / opts.azimuths) {
      const v = view(theta, phi);
      coneViews++;
      if (v.area > 0) conePrint++;
      if (v.area > worst.area) worst = v;
    }
  }
  return {
    samples: samples.length, holoAreaMm2: Math.round(totalArea * 1e6), sides,
    cone: { maxDegrees: Math.max(...opts.coneAngles), azimuths: opts.azimuths, views: coneViews, viewsWithPrint: conePrint, worst: worst.area ? { theta: worst.theta, phi: worst.phi, areaMm2: Math.round(worst.area * 1e6), bandMm: mm(worst.band) } : null },
  };
}

// ----------------------------------------------------------------------------- views
// A small ray tracer for the previews: the plate body in grey, the holo (the print) in
// hatched magenta, the quad textured with the item image (u right, v down). Returns RGBA
// and the number of print pixels.
function renderView(plate, chunks, materials, fitTris, quadInfo, texture, view, size) {
  const roles = chunkRoles(chunks, materials, plate.holoChunk);
  const groups = [
    { kind: 'body', g: pack(trianglesOf(roles.body)), tris: trianglesOf(roles.body) },
    { kind: 'overlay', g: pack(trianglesOf(roles.overlay)), tris: trianglesOf(roles.overlay) },
    { kind: 'holo', g: pack(trianglesOf(roles.holo)), tris: trianglesOf(roles.holo) },
    { kind: 'quad', g: pack(fitTris), tris: fitTris },
  ].filter((x) => x.g.n);
  const [W, H] = size;
  const t = view.theta * DEG, p = view.phi * DEG;
  const dir = G.norm(G.add(G.mul(plate.N, Math.cos(t)), G.mul(G.add(G.mul(plate.R, Math.cos(p)), G.mul(plate.U, Math.sin(p))), Math.sin(t))));
  const fov = 28 * DEG;
  const target = G.add(plate.center, G.mul(plate.N, quadInfo.depth));
  const extent = Math.max(quadInfo.width, plate.width) * 1.25;
  const dist = (extent / 2) / Math.tan(fov / 2);
  const eye = G.add(target, G.mul(dir, dist));
  const fwd = G.mul(dir, -1);
  let right = G.norm(G.cross(fwd, plate.U));
  if (G.len(G.cross(fwd, plate.U)) < 1e-6) right = plate.R;
  const up = G.cross(right, fwd);
  const light = G.norm(G.add(G.mul(plate.N, 0.8), G.add(G.mul(plate.U, 0.5), G.mul(plate.R, -0.3))));
  const rgba = Buffer.alloc(W * H * 4);
  let printPixels = 0;
  const tanH = Math.tan(fov / 2), tanV = tanH * H / W;
  for (let y = 0; y < H; y++) {
    for (let x = 0; x < W; x++) {
      const sx = ((x + 0.5) / W * 2 - 1) * tanH, sy = (1 - (y + 0.5) / H * 2) * tanV;
      const d = G.norm(G.add(fwd, G.add(G.mul(right, sx), G.mul(up, sy))));
      let best = { t: Infinity }, hit = null;
      for (const grp of groups) {
        const h = cast(grp.g, eye, d, 'near');
        if (h.t < best.t) { best = h; hit = grp; }
      }
      let c = [44, 48, 56];
      if (hit) {
        const [a, b, cc] = hit.tris[best.i];
        const n = G.norm(G.cross(G.sub(b, a), G.sub(cc, a)));
        const lambert = 0.35 + 0.65 * Math.abs(G.dot(n, light));
        if (hit.kind === 'body') c = [150, 152, 158].map((v) => v * lambert);
        else if (hit.kind === 'overlay') c = [120, 122, 128].map((v) => v * lambert);
        else if (hit.kind === 'holo') { printPixels++; c = ((x + y) >> 2) & 1 ? [255, 0, 220] : [150, 0, 130]; }
        else {
          const hp = G.add(eye, G.mul(d, best.t));
          const u = (G.dot(G.sub(hp, quadInfo.origin), quadInfo.R) / quadInfo.width);
          const v = 1 - (G.dot(G.sub(hp, quadInfo.origin), quadInfo.U) / quadInfo.height);
          c = texture ? sample(texture, u, v) : [20, 24, 40];
        }
      }
      const k = (y * W + x) * 4;
      rgba[k] = Math.max(0, Math.min(255, Math.round(c[0]))); rgba[k + 1] = Math.max(0, Math.min(255, Math.round(c[1]))); rgba[k + 2] = Math.max(0, Math.min(255, Math.round(c[2]))); rgba[k + 3] = 255;
    }
  }
  return { rgba, width: W, height: H, printPixels };
}

function sample(tex, u, v) {
  const x = Math.max(0, Math.min(tex.width - 1, Math.floor(u * tex.width)));
  const y = Math.max(0, Math.min(tex.height - 1, Math.floor(v * tex.height)));
  const k = (y * tex.width + x) * 4;
  return [tex.rgba[k], tex.rgba[k + 1], tex.rgba[k + 2]];
}

module.exports = {
  measurePlate, legacyPlacement, coverPlacement, quadTransform, quadCorners, quadTriangles,
  frontalMargins, leakTest, renderView, chunkRoles, mm, r4,
};
