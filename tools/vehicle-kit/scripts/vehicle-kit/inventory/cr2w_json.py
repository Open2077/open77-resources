"""Extract game resources with WolvenKit CLI and read its CR2W JSON serialization.

Everything extracted goes to a scratch folder given by the caller (never the repo):
    <scratch>/raw/<depot path>        unbundled CR2W files
    <scratch>/json/<depot path>.json  `cp77tools convert serialize` output
"""
from __future__ import annotations

import json
import os
import re
import shutil
import subprocess
from typing import Any, Iterable


def archive_index(list_dir: str) -> dict[str, list[str]]:
    """depot path (lowercase) -> archive names holding it, from the cached `archive -l` listings."""
    index: dict[str, list[str]] = {}
    for fn in sorted(os.listdir(list_dir)):
        if not (fn.startswith("list_") and fn.endswith(".txt")):
            continue
        name = fn[5:-4]
        with open(os.path.join(list_dir, fn), encoding="utf-8", errors="replace") as fh:
            for line in fh:
                p = line.strip().lower()
                if p:
                    index.setdefault(p, []).append(name)
    return index


def archive_path(game: str, name: str) -> str:
    sub = "ep1" if name.startswith("ep1_") else "content"
    return os.path.join(game, "archive", "pc", sub, name + ".archive")


def pick_archive(archives: list[str]) -> str:
    """ep1 archives are mounted after the base content and win on duplicate paths (inference,
    consistent with how the patch archives shadow the base game)."""
    ep1 = [a for a in archives if a.startswith("ep1_")]
    return (ep1 or archives)[-1]


def extract(game: str, cp77tools: str, scratch: str, depot_paths: Iterable[str],
            index: dict[str, list[str]], force_archive: dict[str, str] | None = None) -> dict[str, dict]:
    """Unbundle and serialize `depot_paths`. Returns depot path -> {archive, alsoIn, json}."""
    raw_root = os.path.join(scratch, "raw")
    json_root = os.path.join(scratch, "json")
    wanted: dict[str, list[str]] = {}
    info: dict[str, dict] = {}
    for dp in sorted({p.lower() for p in depot_paths}):
        archives = index.get(dp)
        if not archives:
            info[dp] = {"archive": None, "alsoIn": [], "json": None}
            continue
        arch = (force_archive or {}).get(dp) or pick_archive(archives)
        info[dp] = {"archive": arch, "alsoIn": [a for a in archives if a != arch], "json": None}
        out_json = os.path.join(json_root, arch, dp.replace("\\", os.sep) + ".json")
        info[dp]["json"] = out_json
        if not os.path.exists(out_json):
            wanted.setdefault(arch, []).append(dp)
    for arch, paths in wanted.items():
        stage = os.path.join(raw_root, arch)
        # one regex per archive, chunked to keep the command line short
        for i in range(0, len(paths), 40):
            chunk = paths[i:i + 40]
            rx = "^(" + "|".join(re.escape(p) for p in chunk) + ")$"
            subprocess.run([cp77tools, "unbundle", archive_path(game, arch), "-o", stage, "-r", rx],
                           check=True, stdout=subprocess.DEVNULL)
        sources = {}
        for dp in paths:
            src = os.path.join(stage, dp.replace("\\", os.sep))
            if os.path.exists(src):
                sources[os.path.normcase(os.path.abspath(src))] = dp
            else:
                info[dp]["json"] = None
        # `convert serialize` flattens its output names, so serialize in small batches and map
        # each output back through the source path recorded in its JSON header.
        pending = list(sources.items())
        while pending:
            batch, pending = pending[:30], pending[30:]
            names = [os.path.basename(s) for s, _ in batch]
            if len(set(names)) != len(names):  # same file name twice: one at a time
                batch, pending = batch[:1], batch[1:] + pending
            tmp = os.path.join(scratch, "tmp-serialize")
            shutil.rmtree(tmp, ignore_errors=True)
            os.makedirs(tmp)
            subprocess.run([cp77tools, "convert", "serialize", *[s for s, _ in batch], "-o", tmp],
                           check=True, stdout=subprocess.DEVNULL)
            for fn in os.listdir(tmp):
                full = os.path.join(tmp, fn)
                with open(full, encoding="utf-8", errors="replace") as fh:
                    head = fh.read(4096)
                m = re.search(r'"ArchiveFileName":\s*"((?:[^"\\]|\\.)*)"', head)
                src = json.loads('"' + m.group(1) + '"') if m else ""
                dp = sources.get(os.path.normcase(os.path.abspath(src)))
                if dp is None:
                    continue
                out_json = info[dp]["json"]
                os.makedirs(os.path.dirname(out_json), exist_ok=True)
                os.replace(full, out_json)
        for dp in sources.values():
            if not os.path.exists(info[dp]["json"]):
                info[dp]["json"] = None
    return info


# ---- reading WolvenKit JSON ------------------------------------------------------------

def val(x: Any) -> Any:
    """Unwrap CName / ResourcePath / resource reference wrappers to their plain value."""
    if isinstance(x, dict):
        if "DepotPath" in x:
            return val(x["DepotPath"])
        if "$value" in x:
            v = x["$value"]
            if x.get("$storage") == "uint64" and v in ("0", 0):
                return ""
            return v
    return x


class Doc:
    """A serialized CR2W file, with WolvenKit's handle dedup (HandleId / HandleRefId) resolved."""

    def __init__(self, path: str):
        with open(path, encoding="utf-8") as fh:
            self.data = json.load(fh)
        self.root = self.data["Data"]["RootChunk"]
        self.handles: dict[str, Any] = {}
        self._walk(self.data)

    def _walk(self, x: Any) -> None:
        stack = [x]
        while stack:
            y = stack.pop()
            if isinstance(y, dict):
                if "HandleId" in y and "Data" in y:
                    self.handles[y["HandleId"]] = y["Data"]
                stack.extend(y.values())
            elif isinstance(y, list):
                stack.extend(y)

    def deref(self, h: Any) -> Any:
        if not isinstance(h, dict):
            return None
        if "HandleRefId" in h:
            return self.handles.get(h["HandleRefId"])
        if "Data" in h:
            return h["Data"]
        return h


def component_list(doc: Doc, holder: dict) -> list[dict]:
    """Components of an entity template or appearance definition (falls back to the compiled
    package when the plain array is empty)."""
    comps = holder.get("components") or []
    out = [doc.deref(c) if "HandleId" in c or "HandleRefId" in c else c for c in comps]
    out = [c for c in out if isinstance(c, dict) and "$type" in c]
    if out:
        return out
    cd = holder.get("compiledData")
    chunks = (((cd or {}).get("Data") or {}).get("Chunks")) if isinstance(cd, dict) else None
    return [c for c in (chunks or []) if isinstance(c, dict) and "name" in c]


def binding(doc: Doc, comp: dict, key: str = "parentTransform") -> dict | None:
    b = doc.deref(comp.get(key)) if comp.get(key) else None
    if not isinstance(b, dict):
        return None
    out = {"type": b.get("$type"), "bindName": val(b.get("bindName"))}
    slot = val(b.get("slotName"))
    if slot and slot != "None":
        out["slotName"] = slot
    return out
