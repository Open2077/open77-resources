"""Minimal read-only reader for Cyberpunk 2077 `tweakdb.bin` (blob version 8, parser 4).

The layout follows WolvenKit's `WolvenKit.RED4/TweakDB/TweakDBReader.cs`:

    u32 magic 0x0BB1DB47, i32 blobVersion, i32 parserVersion, u32 recordChecksum,
    i32 flatsOffset, i32 recordsOffset, i32 queriesOffset, i32 groupTagsOffset

    flats   : i32 typeCount, then per type {u64 fnv1a64(typeName), u32 valueCount,
              u32 keyCount, u32 offset}; at `offset`: u32 n, n values, u32 k,
              k x {u64 TweakDBID, i32 valueIndex}
    records : i32 n, n x {u64 TweakDBID, u32 murmur3_32(typeName, 0x5EEDBA5E)}

A TweakDBID is CRC32(name) | len(name) << 32, so the id of a flat `Record.property`
is derived from the record id alone (running CRC), without knowing the record name.
Names, when wanted, come from WolvenKit's `tweakdbstr.kark` string table (see README).

Nothing here writes to the game files.
"""
from __future__ import annotations

import os
import re
import struct
import subprocess
import zlib
from typing import Any, Iterable

ID_MASK = 0xFF_FFFF_FFFF  # crc32 (32 bits) + length (8 bits); the rest is a runtime offset

FLAT_TYPES = [
    "CName", "String", "TweakDBID", "raRef:CResource", "Float", "Bool",
    "Uint8", "Uint16", "Uint32", "Uint64", "Int8", "Int16", "Int32", "Int64",
    "Color", "EulerAngles", "Quaternion", "Vector2", "Vector3", "gamedataLocKeyWrapper",
]

_FIXED = {
    "TweakDBID": ("<Q", 8), "raRef:CResource": ("<Q", 8), "Float": ("<f", 4),
    "Bool": ("<?", 1), "Uint8": ("<B", 1), "Uint16": ("<H", 2), "Uint32": ("<I", 4),
    "Uint64": ("<Q", 8), "Int8": ("<b", 1), "Int16": ("<h", 2), "Int32": ("<i", 4),
    "Int64": ("<q", 8), "Color": ("<4B", 4), "EulerAngles": ("<3f", 12),
    "Quaternion": ("<4f", 16), "Vector2": ("<2f", 8), "Vector3": ("<3f", 12),
    "gamedataLocKeyWrapper": ("<Q", 8),
}


def fnv1a64(text: str | bytes) -> int:
    data = text.encode("utf-8") if isinstance(text, str) else text
    h = 0xCBF29CE484222325
    for b in data:
        h = ((h ^ b) * 0x100000001B3) & 0xFFFFFFFFFFFFFFFF
    return h


def murmur3_32(data: bytes, seed: int) -> int:
    c1, c2 = 0xCC9E2D51, 0x1B873593
    h = seed & 0xFFFFFFFF
    n = len(data) // 4
    for i in range(n):
        k = struct.unpack_from("<I", data, i * 4)[0]
        k = (k * c1) & 0xFFFFFFFF
        k = ((k << 15) | (k >> 17)) & 0xFFFFFFFF
        k = (k * c2) & 0xFFFFFFFF
        h ^= k
        h = ((h << 13) | (h >> 19)) & 0xFFFFFFFF
        h = (h * 5 + 0xE6546B64) & 0xFFFFFFFF
    tail = data[n * 4:]
    k = 0
    if len(tail) >= 3:
        k ^= tail[2] << 16
    if len(tail) >= 2:
        k ^= tail[1] << 8
    if len(tail) >= 1:
        k ^= tail[0]
        k = (k * c1) & 0xFFFFFFFF
        k = ((k << 15) | (k >> 17)) & 0xFFFFFFFF
        k = (k * c2) & 0xFFFFFFFF
        h ^= k
    h ^= len(data)
    h ^= h >> 16
    h = (h * 0x85EBCA6B) & 0xFFFFFFFF
    h ^= h >> 13
    h = (h * 0xC2B2AE35) & 0xFFFFFFFF
    h ^= h >> 16
    return h


def record_type_key(record_class: str) -> int:
    """`gamedataVehicle_Record` -> murmur3_32("Vehicle", 0x5EEDBA5E)."""
    m = re.fullmatch(r"gamedata(.*)_Record", record_class)
    short = m.group(1) if m else record_class
    return murmur3_32(short.encode("ascii"), 0x5EEDBA5E)


def tdbid(name: str) -> int:
    raw = name.encode("utf-8")
    return (zlib.crc32(raw) & 0xFFFFFFFF) | (len(raw) << 32)


def tdbid_append(base: int, suffix: str) -> int:
    """Id of `<name of base><suffix>`, computed from the id alone (running CRC32)."""
    raw = suffix.encode("utf-8")
    crc = zlib.crc32(raw, base & 0xFFFFFFFF) & 0xFFFFFFFF
    length = ((base >> 32) & 0xFF) + len(raw)
    return crc | ((length & 0xFF) << 32)


def _read_vlq_int32(buf: bytes, pos: int) -> tuple[int, int]:
    b = buf[pos]
    pos += 1
    negative = bool(b & 0x80)
    value = b & 0x3F
    if b & 0x40:
        shift = 6
        while True:
            b = buf[pos]
            pos += 1
            value |= (b & 0x7F) << shift
            shift += 7
            if not (b & 0x80):
                break
    return (-value if negative else value), pos


def _read_string(buf: bytes, pos: int) -> tuple[str, int]:
    prefix, pos = _read_vlq_int32(buf, pos)
    if prefix == 0:
        return "", pos
    if prefix < 0:
        n = -prefix
        return buf[pos:pos + n].decode("utf-8", "replace"), pos + n
    n = prefix * 2
    return buf[pos:pos + n].decode("utf-16-le", "replace"), pos + n


class _TypePool:
    __slots__ = ("name", "elem", "is_array", "buf", "start", "count", "_offsets", "_cache", "_end")

    def __init__(self, name: str, buf: bytes, start: int, count: int):
        self.name = name
        self.is_array = name.startswith("array:")
        self.elem = name[6:] if self.is_array else name
        self.buf = buf
        self.start = start
        self.count = count
        self._offsets: list[int] | None = None
        self._cache: dict[int, Any] = {}

    def _read_scalar(self, pos: int) -> tuple[Any, int]:
        elem = self.elem
        if elem in ("CName", "String"):
            return _read_string(self.buf, pos)
        fmt, size = _FIXED[elem]
        v = struct.unpack_from(fmt, self.buf, pos)
        return (v[0] if len(v) == 1 else list(v)), pos + size

    def _read_value(self, pos: int) -> tuple[Any, int]:
        if not self.is_array:
            return self._read_scalar(pos)
        n, pos = _read_vlq_int32(self.buf, pos)
        out = []
        for _ in range(n):
            v, pos = self._read_scalar(pos)
            out.append(v)
        return out, pos

    def end(self) -> int:
        self._index()
        return self._end

    def _index(self) -> None:
        if self._offsets is not None:
            return
        if not self.is_array and self.elem in _FIXED:
            size = _FIXED[self.elem][1]
            self._offsets = []
            self._end = self.start + size * self.count
            return
        offs = []
        pos = self.start
        for _ in range(self.count):
            offs.append(pos)
            _, pos = self._read_value(pos)
        self._offsets = offs
        self._end = pos

    def value(self, index: int) -> Any:
        if index in self._cache:
            return self._cache[index]
        if not self.is_array and self.elem in _FIXED:
            pos = self.start + _FIXED[self.elem][1] * index
        else:
            self._index()
            pos = self._offsets[index]  # type: ignore[index]
        v, _ = self._read_value(pos)
        self._cache[index] = v
        return v


class TweakDB:
    MAGIC = 0x0BB1DB47

    def __init__(self, path: str):
        self.path = path
        with open(path, "rb") as fh:
            self.buf = fh.read()
        buf = self.buf
        magic, blob, parser, checksum, flats_off, records_off, queries_off, tags_off = \
            struct.unpack_from("<IiiIiiii", buf, 0)
        if magic != self.MAGIC:
            raise ValueError(f"{path}: not a tweakdb.bin (magic {magic:#x})")
        if (blob, parser) != (8, 4):
            raise ValueError(f"{path}: unsupported blob/parser version {blob}/{parser}")
        self.blob_version = blob
        self.parser_version = parser
        self.record_checksum = checksum

        type_names = {}
        for t in FLAT_TYPES:
            type_names[fnv1a64(t)] = t
            type_names[fnv1a64("array:" + t)] = "array:" + t

        self.pools: list[_TypePool] = []
        self.flats: dict[int, int] = {}  # id -> pool index << 32 | value index
        (ntypes,) = struct.unpack_from("<i", buf, flats_off)
        p = flats_off + 4
        headers = []
        for _ in range(ntypes):
            th, vcount, kcount, off = struct.unpack_from("<QIII", buf, p)
            p += 20
            headers.append((th, vcount, kcount, off))
        self.unknown_types = []
        for th, vcount, kcount, off in headers:
            name = type_names.get(th)
            if name is None:
                self.unknown_types.append(th)
                continue
            (n,) = struct.unpack_from("<I", buf, off)
            pool = _TypePool(name, buf, off + 4, n)
            pool_index = len(self.pools)
            self.pools.append(pool)
            kpos = pool.end()
            (k,) = struct.unpack_from("<I", buf, kpos)
            kpos += 4
            tag = pool_index << 32
            flats = self.flats
            for fid, vi in struct.iter_unpack("<Qi", buf[kpos:kpos + 12 * k]):
                flats[fid & ID_MASK] = tag | vi

        self.records: dict[int, int] = {}
        (nrec,) = struct.unpack_from("<i", buf, records_off)
        p = records_off + 4
        for rid, key in struct.iter_unpack("<QI", buf[p:p + 12 * nrec]):
            self.records[rid & ID_MASK] = key

    def flat_type(self, fid: int) -> str | None:
        packed = self.flats.get(fid & ID_MASK)
        return None if packed is None else self.pools[packed >> 32].name

    def flat(self, fid: int, default: Any = KeyError) -> Any:
        packed = self.flats.get(fid & ID_MASK)
        if packed is None:
            if default is KeyError:
                raise KeyError(f"{fid:#x}")
            return default
        return self.pools[packed >> 32].value(packed & 0xFFFFFFFF)


class LayeredTweakDB:
    """The game layers tweakdb_ep1.bin over tweakdb.bin: the last layer wins."""

    def __init__(self, paths: Iterable[str]):
        self.layers = [TweakDB(p) for p in paths]

    def flat(self, fid: int, default: Any = None) -> Any:
        for layer in reversed(self.layers):
            packed = layer.flats.get(fid & ID_MASK)
            if packed is not None:
                return layer.pools[packed >> 32].value(packed & 0xFFFFFFFF)
        return default

    def has_flat(self, fid: int) -> bool:
        return any((fid & ID_MASK) in layer.flats for layer in self.layers)

    def prop(self, record_id: int, prop: str, default: Any = None) -> Any:
        return self.flat(tdbid_append(record_id, "." + prop), default)

    def record_type(self, rid: int) -> int | None:
        for layer in reversed(self.layers):
            key = layer.records.get(rid & ID_MASK)
            if key is not None:
                return key
        return None

    def record_ids(self) -> set[int]:
        out: set[int] = set()
        for layer in self.layers:
            out.update(layer.records)
        return out


def _string_table(kark_or_bin: str, cache_dir: str | None, cp77tools: str | None) -> bytes:
    """The decompressed bytes of WolvenKit's `tweakdbstr.kark` (or of its decompressed .bin)."""
    path = kark_or_bin
    with open(path, "rb") as fh:
        head = fh.read(4)
    if head == b"KARK":
        if not cache_dir or not cp77tools:
            raise ValueError("a .kark needs cache_dir and cp77tools to be decompressed")
        os.makedirs(cache_dir, exist_ok=True)
        out = os.path.join(cache_dir, "tweakdbstr.bin")
        if not os.path.exists(out) or os.path.getmtime(out) < os.path.getmtime(path):
            target = os.path.join(cache_dir, "tweakdbstr")
            subprocess.run([cp77tools, "oodle", "decompress", path, target], check=True,
                           stdout=subprocess.DEVNULL)
            produced = target + ".bin" if os.path.exists(target + ".bin") else target
            os.replace(produced, out)
        path = out
    with open(path, "rb") as fh:
        buf = fh.read()
    magic = struct.unpack_from("<I", buf, 0)[0]
    if magic != 0x0BB1DB57:
        raise ValueError(f"{path}: not a TweakDB string table (magic {magic:#x})")
    return buf


def iter_names(kark_or_bin: str, cache_dir: str | None = None, cp77tools: str | None = None,
               want_flats: bool = True) -> Iterable[tuple[bool, str]]:
    """(is_flat, name) of every record name, then (with want_flats) every flat name, of
    WolvenKit's `tweakdbstr.kark`, without holding the 3 million strings in memory."""
    buf = _string_table(kark_or_bin, cache_dir, cp77tools)
    _magic, _version, nrec, nflat, _nq = struct.unpack_from("<IIIII", buf, 0)
    pos = 20
    for i in range(nrec + (nflat if want_flats else 0)):
        s, pos = _read_string(buf, pos)
        yield i >= nrec, s


def load_names(kark_or_bin: str, cache_dir: str | None = None, cp77tools: str | None = None,
               want_flats: bool = False) -> dict[int, str]:
    """Record (and optionally flat) names from WolvenKit's `tweakdbstr.kark`.

    The .kark is an Oodle (Kraken) blob; it is decompressed once with
    `cp77tools oodle decompress` into `cache_dir`. Layout of the decompressed blob:
    u32 magic 0x0BB1DB57, u32 version, u32 records, u32 flats, u32 queries, then
    VLQ length-prefixed strings in that order.
    """
    return {tdbid(s): s for _, s in iter_names(kark_or_bin, cache_dir, cp77tools, want_flats)}


def load_resource_paths(archive_dirs: Iterable[str], cache_dir: str, cp77tools: str) -> dict[int, str]:
    """FNV1a64(depot path) -> depot path, from `cp77tools archive -l` of every archive.

    Listings are cached in `cache_dir` (one text file per archive, refreshed when the
    archive is newer).
    """
    os.makedirs(cache_dir, exist_ok=True)
    paths: dict[int, str] = {}
    for d in archive_dirs:
        if not os.path.isdir(d):
            continue
        for fn in sorted(os.listdir(d)):
            if not fn.endswith(".archive") or fn.startswith(("audio_", "lang_")):
                continue
            src = os.path.join(d, fn)
            listing = os.path.join(cache_dir, f"list_{fn[:-8]}.txt")
            if not os.path.exists(listing) or os.path.getmtime(listing) < os.path.getmtime(src):
                with open(listing, "w", encoding="utf-8") as out:
                    subprocess.run([cp77tools, "archive", "-l", src], check=True, stdout=out)
            with open(listing, encoding="utf-8", errors="replace") as fh:
                for line in fh:
                    line = line.strip()
                    if "\\" in line or "." in line:
                        paths[fnv1a64(line)] = line
    return paths
