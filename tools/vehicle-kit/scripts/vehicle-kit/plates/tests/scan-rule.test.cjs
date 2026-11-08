'use strict';
// node --test scripts/vehicle-kit/plates/tests/scan-rule.test.cjs
//
// The no-vanilla-bytes scan's handle-index exception (native/scan-rule.cjs). Synthetic CR2W
// files built here cover every condition. With OP77_PLATES_SCAN_DIR set to a build-plates.ps1
// -OutDir that holds the extracted vanilla .app files and a staged pack, the real block of
// 2026-11-07 is checked too (game files are never in the repository, so that case is skipped
// without them).
const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const rule = require('../native/scan-rule.cjs');

const W = 64;
const u16 = (v) => { const b = Buffer.alloc(2); b.writeUInt16LE(v); return b; };
const u32 = (v) => { const b = Buffer.alloc(4); b.writeUInt32LE(v); return b; };
const words = (...v) => Buffer.concat(v.map(u32));

// A minimal CR2W file: header, string table, name table, export table, chunk data.
function cr2w(names, chunks) {
  const strings = Buffer.concat(names.map((n) => Buffer.from(`${n}\0`, 'utf8')));
  let at = 0;
  const nameTable = Buffer.concat(names.map((n) => { const e = Buffer.concat([u32(at), u32(0)]); at += Buffer.byteLength(n) + 1; return e; }));
  const stringsAt = 160, namesAt = stringsAt + strings.length, exportsAt = namesAt + nameTable.length;
  let dataAt = exportsAt + chunks.length * 24;
  const exportTable = Buffer.concat(chunks.map((c) => { const e = Buffer.concat([u16(c.cls), u16(0), u32(0), u32(c.data.length), u32(dataAt), u32(0), u32(0)]); dataAt += c.data.length; return e; }));
  const header = Buffer.alloc(160);
  header.write('CR2W', 0, 'latin1');
  header.writeUInt32LE(195, 4);
  header.writeUInt32LE(chunks.length, 36);
  [[stringsAt, strings.length], [namesAt, names.length], [0, 0], [0, 0], [exportsAt, chunks.length]].forEach(([o, n], i) => { header.writeUInt32LE(o, 40 + i * 12); header.writeUInt32LE(n, 44 + i * 12); });
  return Buffer.concat([header, strings, nameTable, exportTable, ...chunks.map((c) => c.data)]);
}
const prop = (name, type, value) => Buffer.concat([u16(name), u16(type), u32(4 + value.length), value]);
const propList = (...props) => Buffer.concat([Buffer.from([0]), ...props, u16(0)]);
const handles = (list) => Buffer.concat([u32(list.length), ...list.map(u32)]);
const range = (from, n) => Array.from({ length: n }, (_, i) => from + i);

const NAMES = ['', 'appearanceAppearanceResource', 'appearances', 'array:handle:appearanceAppearanceDefinition',
  'appearanceAppearanceDefinition', 'DismWoundConfig', 'entdismembermentWoundsConfigSet', 'Configs',
  'array:handle:entdismembermentWoundConfigContainer', 'entdismembermentWoundConfigContainer', 'values', 'array:Uint32', 'blob', 'array:Uint8'];
const N = Object.fromEntries(NAMES.map((n, i) => [n, i]));
const leafChunks = (cls, n) => range(0, n).map(() => ({ cls, data: propList() }));

// "Ours": root `appearances` = 33 definitions in chunks 2..34, like the patch .app.
function oursFile(list = range(2, 33)) {
  const root = propList(prop(N.appearances, N['array:handle:appearanceAppearanceDefinition'], handles(list)));
  const buf = cr2w(NAMES, [{ cls: N.appearanceAppearanceResource, data: root }, ...leafChunks(N.appearanceAppearanceDefinition, 33)]);
  return { buf, sizeAt: buf.indexOf(handles(list)) - 4 };
}
// "Vanilla": the same 33-element run nested in a struct (DismWoundConfig.Configs).
function vanillaFile(list = range(2, 33)) {
  const configs = prop(N.Configs, N['array:handle:entdismembermentWoundConfigContainer'], handles(list));
  const root = propList(prop(N.DismWoundConfig, N.entdismembermentWoundsConfigSet, propList(configs)));
  const buf = cr2w(NAMES, [{ cls: N.appearanceAppearanceResource, data: root }, ...leafChunks(N.entdismembermentWoundConfigContainer, 63)]);
  return { buf, sizeAt: buf.indexOf(handles(list)) - 4 };
}
const side = (file, f, offset) => ({ file, buf: f.buf, offset });

test('a size word, a count word and a +1 run of chunk references passes (replica of the 2026-11-07 block)', () => {
  const ours = oursFile(), van = vanillaFile();
  assert.deepEqual(ours.buf.subarray(ours.sizeAt, ours.sizeAt + W), van.buf.subarray(van.sizeAt, van.sizeAt + W));
  assert.deepEqual(ours.buf.subarray(ours.sizeAt, ours.sizeAt + 16), words(0x8c, 0x21, 2, 3));
  assert.equal(rule.sharedIndexBlockReason(side('v.app', van, van.sizeAt), side('o.app', ours, ours.sizeAt), W), null);
  // one header word (block starts on the count) and none (block inside the run) pass too
  assert.equal(rule.sharedIndexBlockReason(side('v.app', van, van.sizeAt + 4), side('o.app', ours, ours.sizeAt + 4), W), null);
  assert.equal(rule.sharedIndexBlockReason(side('v.app', van, van.sizeAt + 8), side('o.app', ours, ours.sizeAt + 8), W), null);
});

test('three header words fail', () => {
  assert.equal(rule.runAfterHeader([0x8c, 0x21, 7, ...range(2, 13)], 3), -1);
  assert.equal(rule.runAfterHeader([0x8c, 0x21, ...range(2, 14)], 2), 2);
  // in a file, a block that also holds the property's name/type word is outside the array
  const ours = oursFile(), van = vanillaFile();
  const why = rule.sharedIndexBlockReason(side('v.app', van, van.sizeAt - 4), side('o.app', ours, ours.sizeAt - 4), W);
  assert.match(why, /not inside an array:handle property/);
});

test('a gap in the run fails', () => {
  const gap = [...range(2, 6), 9, ...range(10, 26)];
  const ours = oursFile(gap), van = vanillaFile(gap);
  const why = rule.sharedIndexBlockReason(side('v.app', van, van.sizeAt), side('o.app', ours, ours.sizeAt), W);
  assert.match(why, /not one \+1 run/);
});

test('a run that is not a chunk reference fails', () => {
  const far = range(40, 33); // past the 34 chunks of "ours"
  const ours = oursFile(far), van = vanillaFile(far);
  assert.match(rule.sharedIndexBlockReason(side('v.app', van, van.sizeAt), side('o.app', ours, ours.sizeAt), W), /not a chunk reference/);
});

test('real content shared with vanilla fails', () => {
  // the same counting run, but as plain data (array:Uint32), not a handle array
  const run = handles(range(2, 33));
  const data = cr2w(NAMES, [{ cls: N.appearanceAppearanceResource, data: propList(prop(N.values, N['array:Uint32'], run)) }, ...leafChunks(N.appearanceAppearanceDefinition, 33)]);
  const at = data.indexOf(run) - 4;
  assert.match(rule.sharedIndexBlockReason({ file: 'v.app', buf: data, offset: at }, { file: 'o.app', buf: data, offset: at }, W), /not inside an array:handle property/);
  // arbitrary bytes (a float table, say) in a byte array
  const floats = Buffer.alloc(96);
  for (let i = 0; i < 24; i++) floats.writeFloatLE(Math.sin(i) * 0.37, i * 4);
  const blob = cr2w(NAMES, [{ cls: N.appearanceAppearanceResource, data: propList(prop(N.blob, N['array:Uint8'], Buffer.concat([u32(96), floats]))) }]);
  const fat = blob.indexOf(floats);
  assert.match(rule.sharedIndexBlockReason({ file: 'v.app', buf: blob, offset: fat }, { file: 'o.app', buf: blob, offset: fat }, W), /not inside an array:handle property/);
});

test('only .app files', () => {
  const ours = oursFile(), van = vanillaFile();
  assert.match(rule.sharedIndexBlockReason(side('v.mesh', van, van.sizeAt), side('o.app', ours, ours.sizeAt), W), /not an \.app file/);
  assert.match(rule.sharedIndexBlockReason(side('v.app', van, van.sizeAt), side('o.ent', ours, ours.sizeAt), W), /not an \.app file/);
});

// ---------------------------------------------------------------- real files (optional)
const dir = process.env.OP77_PLATES_SCAN_DIR;
const vanillaPath = dir && path.join(dir, 'vanilla', 'base', 'vehicles', 'appearances', 'standard', 'chevalier_emperor__basic.app');
const stageRoot = dir && path.join(dir, 'original', 'work', 'stage', 'open77', 'assets', 'open77_vehicle_plates');
const oursPath = stageRoot && fs.existsSync(stageRoot) && fs.readdirSync(stageRoot).map((r) => path.join(stageRoot, r, 'quadra_sport_r7_basic.app')).find((p) => fs.existsSync(p));
const real = !!(vanillaPath && fs.existsSync(vanillaPath) && oursPath);

test('real: quadra_sport_r7_basic.app@2786 = vanilla chevalier_emperor__basic.app@5696 passes', { skip: real ? false : 'set OP77_PLATES_SCAN_DIR to a plates build -OutDir' }, () => {
  const v = fs.readFileSync(vanillaPath), o = fs.readFileSync(oursPath);
  assert.deepEqual(o.subarray(2786, 2786 + W), v.subarray(5696, 5696 + W));
  assert.equal(rule.sharedIndexBlockReason({ file: vanillaPath, buf: v, offset: 5696 }, { file: oursPath, buf: o, offset: 2786 }, W), null);
});

test('real: content of the vanilla .app (its buffers, its other properties) fails', { skip: real ? false : 'set OP77_PLATES_SCAN_DIR to a plates build -OutDir' }, () => {
  const v = fs.readFileSync(vanillaPath);
  const objectsEnd = v.readUInt32LE(24);
  let checked = 0;
  for (let at = Math.ceil(objectsEnd / W) * W; at + W <= v.length && checked < 200; at += W) {
    const block = v.subarray(at, at + W);
    if (block.every((x) => x === block[0])) continue;
    assert.notEqual(rule.sharedIndexBlockReason({ file: vanillaPath, buf: v, offset: at }, { file: vanillaPath, buf: v, offset: at }, W), null, `buffer block at ${at}`);
    checked++;
  }
  assert.ok(checked > 50, `only ${checked} buffer blocks`);
  // the block 64 bytes before the flagged one: struct headers, not the handle array
  assert.notEqual(rule.sharedIndexBlockReason({ file: vanillaPath, buf: v, offset: 5632 }, { file: vanillaPath, buf: v, offset: 5632 }, W), null);
});
