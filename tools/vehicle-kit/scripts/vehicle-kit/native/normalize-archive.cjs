// Makes a WolvenKit-packed .archive reproducible: `cp77tools pack` stamps every file
// entry with the time of the pack, so the same staged files give different archive
// bytes on every run. This pins each entry timestamp to 2000-01-01T00:00:00Z (the
// same instant as the ZIP entry) and rewrites the index checksum.
//
//   node normalize-archive.cjs <file.archive>
//
// RDAR layout (version 12), as written by WolvenKit 8.20:
//   header: 'RDAR' u32 version, u64 indexPosition, u32 indexSize, ...
//   index:  u32 tableOffset (8), u32 tableSize, u64 crc, u32 files, u32 segments, u32 deps,
//           files x 56 bytes { u64 nameHash, i64 timestamp (FILETIME), ... }, segments, deps
//   crc = CRC-64/XZ of the index bytes from offset 16 to 8 + tableSize.
// The existing checksum is verified before anything is written, so a different
// container layout is refused instead of being patched blindly.
'use strict';
const fs = require('node:fs');

const MASK = 0xFFFFFFFFFFFFFFFFn;
const TABLE = (() => {
  const t = new Array(256);
  for (let i = 0n; i < 256n; i++) {
    let c = i;
    for (let k = 0; k < 8; k++) c = (c & 1n) ? (c >> 1n) ^ 0xC96C5795D7870F42n : c >> 1n;
    t[Number(i)] = c;
  }
  return t;
})();
function crc64xz(buf) {
  let c = MASK;
  for (const byte of buf) c = TABLE[Number((c ^ BigInt(byte)) & 0xFFn)] ^ (c >> 8n);
  return (c ^ MASK) & MASK;
}

const file = process.argv[2];
const FIXED = 125911584000000000n;   // FILETIME of 2000-01-01T00:00:00Z
try {
  if (!file) throw new Error('usage: normalize-archive.cjs <file.archive>');
  const b = fs.readFileSync(file);
  if (b.toString('latin1', 0, 4) !== 'RDAR' || b.readUInt32LE(4) !== 12) throw new Error('not an RDAR v12 archive');
  const idx = Number(b.readBigUInt64LE(8));
  const tableOffset = b.readUInt32LE(idx), tableSize = b.readUInt32LE(idx + 4);
  const files = b.readUInt32LE(idx + 16);
  const end = idx + 8 + tableSize;
  if (tableOffset !== 8 || end > b.length || idx + 28 + files * 56 > end) throw new Error('unexpected index layout');
  if (crc64xz(b.subarray(idx + 16, end)) !== b.readBigUInt64LE(idx + 8)) throw new Error('index checksum does not verify (layout changed?)');
  for (let i = 0; i < files; i++) b.writeBigInt64LE(FIXED, idx + 28 + i * 56 + 8);
  b.writeBigUInt64LE(crc64xz(b.subarray(idx + 16, end)), idx + 8);
  fs.writeFileSync(file, b);
  console.log(`VK_ARCHIVE_NORMALIZED files=${files} crc=${b.readBigUInt64LE(idx + 8).toString(16)}`);
} catch (e) {
  console.error(`VK_ARCHIVE_FAILED ${e.message}`);
  process.exit(1);
}
