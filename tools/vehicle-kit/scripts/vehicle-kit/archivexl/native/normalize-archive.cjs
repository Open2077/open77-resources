// Pins the per-file timestamps of a WolvenKit-packed RDAR archive so that packing the
// same files twice gives the same bytes, then recomputes the index checksum.
//
//   node normalize-archive.cjs <file.archive>
//
// Layout read here (RDAR version 12, WolvenKit 8.20):
//   0x00 'RDAR'  u32 version  u64 indexPosition ...
//   index + 0x00 u32 tableOffset (always 8)  u32 tableSize  u64 crc64
//   index + 0x10 u32 fileCount  u32 segmentCount  u32 dependencyCount
//   index + 0x1C fileCount records of 56 bytes: u64 nameHash, i64 FILETIME, ...
//   crc64 = CRC-64/XZ over [index + 0x10, index + 8 + tableSize)
// The stored checksum must verify before anything is written: an unexpected layout is
// refused rather than patched. Prints AXL_ARCHIVE_NORMALIZED or AXL_ARCHIVE_FAILED.
'use strict';
const fs = require('node:fs');

const ALL_ONES = (1n << 64n) - 1n;
const POLY = 0xc96c5795d7870f42n;                 // CRC-64/XZ, reflected
const EPOCH_2000 = 125911584000000000n;            // FILETIME of 2000-01-01T00:00:00Z
const RECORD = 56;

const table = Array.from({ length: 256 }, (_, n) => {
  let c = BigInt(n);
  for (let bit = 0; bit < 8; bit++) c = c & 1n ? (c >> 1n) ^ POLY : c >> 1n;
  return c;
});

function crc64(bytes) {
  let c = ALL_ONES;
  for (let i = 0; i < bytes.length; i++) c = table[Number((c ^ BigInt(bytes[i])) & 0xffn)] ^ (c >> 8n);
  return c ^ ALL_ONES;
}

try {
  const file = process.argv[2];
  if (!file) throw new Error('usage: normalize-archive.cjs <file.archive>');
  const data = fs.readFileSync(file);
  if (data.length < 16 || data.toString('latin1', 0, 4) !== 'RDAR') throw new Error('not an RDAR archive');
  const version = data.readUInt32LE(4);
  if (version !== 12) throw new Error(`RDAR version ${version}, expected 12`);
  const index = Number(data.readBigUInt64LE(8));
  if (index + 0x1c > data.length) throw new Error('index position beyond the end of the file');
  const tableOffset = data.readUInt32LE(index);
  const tableSize = data.readUInt32LE(index + 4);
  const fileCount = data.readUInt32LE(index + 0x10);
  const end = index + 8 + tableSize;
  if (tableOffset !== 8) throw new Error(`index table offset ${tableOffset}, expected 8`);
  if (end > data.length || index + 0x1c + fileCount * RECORD > end) throw new Error('file records overrun the index');
  if (crc64(data.subarray(index + 0x10, end)) !== data.readBigUInt64LE(index + 8)) throw new Error('stored index checksum does not verify');
  for (let i = 0; i < fileCount; i++) data.writeBigInt64LE(EPOCH_2000, index + 0x1c + i * RECORD + 8);
  const crc = crc64(data.subarray(index + 0x10, end));
  data.writeBigUInt64LE(crc, index + 8);
  fs.writeFileSync(file, data);
  console.log(`AXL_ARCHIVE_NORMALIZED files=${fileCount} crc=${crc.toString(16)}`);
} catch (e) {
  console.error(`AXL_ARCHIVE_FAILED ${e.message}`);
  process.exit(1);
}
