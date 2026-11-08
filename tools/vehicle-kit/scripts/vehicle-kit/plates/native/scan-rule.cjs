'use strict';
// The one exception the no-vanilla-bytes scan (plates.cjs `scan`) makes for a binary 64-byte
// block shared with a vanilla file: a run of chunk references inside a CR2W handle array of
// two .app files. Every other shared binary block still fails the build.
//
// Why such a block is not game content. In a CR2W file an `array:handle:<class>` property is
// written as its size (uint32, counting itself), its element count (uint32), then one uint32
// per element: the referenced chunk's 1-based index in the export table. A resource whose
// chunks are written in order holds 2, 3, 4 ... there. Two unrelated .app files that both
// keep a list of 33 objects in chunks 2..34 therefore share `8c 00 00 00 21 00 00 00 02 00 00
// 00 ...` byte for byte, whatever the objects are: the first such pair (2026-11-07) was our
// quadra_sport_r7_basic.app patch's `appearances` (33 appearance definitions) against the
// vanilla chevalier_emperor__basic.app's DismWoundConfig.Configs (33 dismemberment wound
// containers). The bytes say "33 things, in chunks 2 to 34": layout, not authored data.
//
// A flagged block is accepted only when ALL of these hold, in BOTH files:
//   1. both files are .app, and the block lies inside one `array:handle:*` property, found by
//      walking the CR2W export table and its property headers (nested structs included),
//      from the property's size field to the end of its value;
//   2. at most two leading uint32 header words: the property's size and element count, as
//      the structure places them (the block must start on that property's word boundary);
//   3. every word after them is one run, each exactly 1 more than the previous, and each a
//      valid chunk reference of that file (1 to the export count).

const HEADER_BYTES = 160; // magic, version, flags, timestamp, build, objectsEnd, buffersEnd, crc, chunks, 10 table headers

function cr2wTables(buf) {
  if (buf.length < HEADER_BYTES || buf.toString('latin1', 0, 4) !== 'CR2W') return null;
  const t = [];
  for (let i = 0; i < 10; i++) t.push({ offset: buf.readUInt32LE(40 + i * 12), count: buf.readUInt32LE(44 + i * 12) });
  const end = (k, size) => t[k].offset + t[k].count * size;
  if (end(0, 1) > buf.length || end(1, 8) > buf.length || end(4, 24) > buf.length) return null;
  const strAt = (o) => {
    const s = t[0].offset + o;
    let e = s;
    while (e < end(0, 1) && buf[e]) e++;
    return buf.toString('utf8', s, e);
  };
  const names = [];
  for (let i = 0; i < t[1].count; i++) names.push(strAt(buf.readUInt32LE(t[1].offset + i * 8)));
  const exports = [];
  for (let i = 0; i < t[4].count; i++) {
    const o = t[4].offset + i * 24;
    exports.push({ size: buf.readUInt32LE(o + 8), offset: buf.readUInt32LE(o + 12) });
  }
  return { names, exports };
}

// Property list starting at `p` (a 0 byte, then name u16, type u16, size u32 counting itself,
// value; a 0 name ends it). Returns the properties or null when the bytes do not parse as
// one that ends exactly at `end`, so a value that merely looks like a struct is not entered.
function propertyList(buf, names, p, end) {
  if (p >= end || buf[p] !== 0) return null;
  p += 1;
  const props = [];
  while (p + 2 <= end) {
    const name = buf.readUInt16LE(p);
    if (name === 0) return p + 2 === end ? props : null;
    if (p + 8 > end) return null;
    const type = buf.readUInt16LE(p + 2);
    const size = buf.readUInt32LE(p + 4);
    if (name >= names.length || type >= names.length || size < 4 || p + 4 + size > end) return null;
    props.push({ name: names[name], type: names[type], sizeAt: p + 4, valueAt: p + 8, end: p + 4 + size });
    p += 4 + size;
  }
  return null;
}

// Every `array:handle:*` property of the file, nested structs included: { sizeAt, end, type }.
function handleArrays(buf) {
  const tables = cr2wTables(buf);
  if (!tables) return null;
  const found = [];
  const walk = (props, depth) => {
    for (const pr of props) {
      if (pr.type.startsWith('array:handle:')) { found.push({ sizeAt: pr.sizeAt, end: pr.end, type: pr.type, name: pr.name }); continue; }
      if (depth < 8 && !pr.type.startsWith('array:') && !pr.type.startsWith('handle:')) {
        const inner = propertyList(buf, tables.names, pr.valueAt, pr.end);
        if (inner) walk(inner, depth + 1);
      }
    }
  };
  for (const e of tables.exports) {
    if (e.offset + e.size > buf.length) continue;
    const props = propertyList(buf, tables.names, e.offset, e.offset + e.size);
    if (props) walk(props, 0);
  }
  return { arrays: found, exportCount: tables.exports.length };
}

// Conditions 2 and 3 on the words alone: the run start index (0, 1 or 2), or -1.
function runAfterHeader(words, headerWords) {
  if (headerWords < 0 || headerWords > 2 || headerWords >= words.length - 1) return -1;
  for (let i = headerWords + 1; i < words.length; i++) if (words[i] !== words[i - 1] + 1) return -1;
  return headerWords;
}

// Is the 64-byte block at `offset` of `buf` a handle-array index run? Returns a reason
// string when it is not, or null when it is.
function indexRunReason(buf, offset, length, info) {
  const arr = info.arrays.find((a) => offset >= a.sizeAt && offset + length <= a.end);
  if (!arr) return 'not inside an array:handle property';
  if ((offset - arr.sizeAt) % 4 !== 0) return 'not on the array\'s word boundary';
  const headerWords = Math.max(0, (arr.sizeAt + 8 - offset) / 4);
  const words = [];
  for (let o = offset; o + 4 <= offset + length; o += 4) words.push(buf.readUInt32LE(o));
  if (runAfterHeader(words, headerWords) < 0) return `words after ${headerWords} header words are not one +1 run`;
  for (const w of words.slice(headerWords)) if (w < 1 || w > info.exportCount) return `run value ${w} is not a chunk reference (1..${info.exportCount})`;
  return null;
}

// The scan's question: may this shared block pass? `vanilla` and `ours` are
// { file, buf, offset }. Returns null when accepted, else the reason it is not.
function sharedIndexBlockReason(vanilla, ours, length, cache = new Map()) {
  for (const side of [vanilla, ours]) if (!/\.app$/i.test(side.file)) return `${side.file}: not an .app file`;
  for (const side of [vanilla, ours]) {
    if (!cache.has(side.file)) cache.set(side.file, handleArrays(side.buf));
    const info = cache.get(side.file);
    if (!info) return `${side.file}: not a CR2W file`;
    const why = indexRunReason(side.buf, side.offset, length, info);
    if (why) return `${side.file}@${side.offset}: ${why}`;
  }
  return null;
}

module.exports = { cr2wTables, propertyList, handleArrays, runAfterHeader, indexRunReason, sharedIndexBlockReason };
