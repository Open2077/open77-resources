"""Offline window-glass inventory of the Light RP dealer models (window tint, campaign E6).

For every dealer model, its factory (player) appearance and each curated Light RP trim, this
lists the glass components, the mesh and mesh appearance each one draws, the material the
glass chunk uses (base `.mi`, material template) and the effective tint parameters. It also
writes the plan of the tint pack route 2 would need (one patched mesh appearance per glass
mesh, source appearance and level), without building anything.

Reads the installed game only (WolvenKit CLI). Extracted files go to a scratch folder outside
the repository; only metadata (names, depot paths, parameter values) reaches the outputs:

    scripts/vehicle-kit/windows/data/glass-<ver>.json
    scripts/vehicle-kit/windows/data/glass-<ver>.md

    python -I scripts/vehicle-kit/windows/glass_inventory.py --game <game dir> \
        --scratch %TEMP%\\op77-window-tint --trims <light-rp>\\resources\\gamemodes\\op77_lightrp\\shared\\vehicle_customization.lua
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import shutil
import subprocess
import sys
from collections import OrderedDict

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, "..", "inventory"))
import cr2w_json as cj  # noqa: E402

BS = chr(92)
DEFAULT_CP77TOOLS = os.path.expanduser(os.path.join("~", ".dotnet", "tools", "cp77tools.exe"))
# Archives that hold vehicle meshes, appearances and the glass materials (game 2.50).
ARCHIVES = [("content", "basegame_1_engine"), ("content", "basegame_3_nightcity"),
            ("content", "basegame_4_appearance"), ("content", "basegame_4_gamedata"),
            ("content", "memoryresident_1_general"), ("ep1", "ep1_1_nightcity"), ("ep1", "ep1_2_gamedata")]
GLASS_TEMPLATES = ("vehicle_glass.mt", "vehicle_glass_onesided.mt", "vehicle_glass_flat_twosided.mt",
                   "vehicle_glass_proxy.mt")
TINT_PARAMS = ("TintColor", "Opacity", "OpacityBackFace", "TintSurface", "FrontFacesReflectionPower",
               "BackFacesReflectionPower", "GlassTint")
WINDSHIELD_COMPONENTS = ("window_f",)
WINDOW_RX = re.compile(r"window|windshield|windscreen")
# Tint levels the pack plan uses (route 2). Each one copies the four tint values of a glass
# instance the game already renders on a player car, so the starting point is known to look
# right; tune in game. `vanilla` names where the values come from.
LEVELS = OrderedDict([
    ("1", {"label": "light", "TintColor": [138, 150, 153, 255], "Opacity": 1.0, "OpacityBackFace": 0.5,
               "BackFacesReflectionPower": 0.0,
               "vanilla": "Yaiba Semimaru factory side glass (window_fl, window_back)"}),
    ("2", {"label": "dark", "TintColor": [99, 110, 113, 255], "Opacity": 1.0, "OpacityBackFace": 0.5,
              "BackFacesReflectionPower": 0.0,
              "vanilla": "glass_exterior_generic_tinted_black.mi as is (Hella `tinted`, Cortes `padre`)"}),
    ("3", {"label": "limo", "TintColor": [33, 33, 33, 255], "Opacity": 1.0, "OpacityBackFace": 0.5,
              "BackFacesReflectionPower": 0.0,
              "vanilla": "TintColor of Chevalier Thrax `black_01` (glass_black_01), opacities of level 2: Thrax's 0.9 / 0.2 rendered lighter than level 2 (2026-11-07)"}),
])
# One canonical vanilla base per glass template: every level instance derives from it by depot
# path, so a level looks the same on every model. Per-mesh local overrides of the source chunk
# (dirt mask tiling, damage influence) are not carried over; the base keeps dirt, cracks and
# bullet-hole shatter set up.
CANONICAL_BASE = {
    "vehicle_glass.mt": "base\\vehicles\\common\\materials\\glass_exterior_generic_tinted_black.mi",
    "vehicle_glass_onesided.mt": "base\\materials\\vehicle_glass_onesided.mt",
}
ONESIDED_PARAMS = ("TintColor", "Opacity")  # vehicle_glass_onesided.mt has no back-face parameters


def listings(game: str, cp77tools: str, cache: str) -> str:
    out = os.path.join(cache, "archive-lists")
    os.makedirs(out, exist_ok=True)
    for sub, name in ARCHIVES:
        src = os.path.join(game, "archive", "pc", sub, name + ".archive")
        dst = os.path.join(out, f"list_{name}.txt")
        if os.path.exists(dst) and os.path.getsize(dst) > 0 and os.path.getmtime(dst) >= os.path.getmtime(src):
            continue
        with open(dst, "w", encoding="utf-8") as fh:
            subprocess.run([cp77tools, "archive", "-l", src], check=True, stdout=fh)
    return out


def read_trims(path: str | None) -> dict[str, list[dict]]:
    """`trims = { key = { { id = "...", label = "..." }, ... }, ... }` from the Light RP table."""
    if not path:
        return {}
    text = open(path, encoding="utf-8").read()
    found = re.search(r"^\s*trims\s*=\s*\{", text, re.M)  # skips the commented example
    if not found:
        return {}
    depth, i = 0, text.index("{", found.start())
    end = i
    for end in range(i, len(text)):
        depth += {"{": 1, "}": -1}.get(text[end], 0)
        if depth == 0:
            break
    body = text[i + 1:end]
    out: dict[str, list[dict]] = {}
    for m in re.finditer(r"(\w+)\s*=\s*\{(.*?)\n\s*\},", body, re.S):
        out[m.group(1)] = [{"id": a, "label": b} for a, b in
                           re.findall(r'id\s*=\s*"([^"]+)"\s*,\s*label\s*=\s*"([^"]*)"', m.group(2))]
    return out


def color(x) -> list | None:
    if isinstance(x, dict) and x.get("$type") == "Color":
        return [x["Red"], x["Green"], x["Blue"], x["Alpha"]]
    return None


def plain(x):
    c = color(x)
    if c is not None:
        return c
    if isinstance(x, dict) and "DepotPath" in x:
        return cj.val(x)
    if isinstance(x, dict) and x.get("$type") == "Vector4":
        return [x["X"], x["Y"], x["Z"], x["W"]]
    return x


def instance_values(inst: dict) -> dict:
    out = {}
    for v in inst.get("values") or []:
        for k, x in v.items():
            if k != "$type":
                out[k] = plain(x)
    return out


def load_json(info: dict, dp: str) -> dict | None:
    v = info.get(dp.lower())
    if not v or not v.get("json"):
        return None
    with open(v["json"], encoding="utf-8") as fh:
        return json.load(fh)["Data"]["RootChunk"]


class Materials:
    """Resolves a material instance chain down to its template, merging parameter values."""

    def __init__(self, game, cp77tools, scratch, index):
        self.game, self.cp77tools, self.scratch, self.index = game, cp77tools, scratch, index
        self.cache: dict[str, dict] = {}

    def prefetch(self, paths) -> None:
        """Extract whole material chains level by level, in one cp77tools pass per level
        (resolving one `.mi` at a time costs a cp77tools start each)."""
        level = {p.lower() for p in paths if p and not p.lower().endswith((".mt", ".remt"))} - set(self.cache)
        seen: set[str] = set()
        while level:
            seen |= level
            info = cj.extract(self.game, self.cp77tools, self.scratch, sorted(level), self.index)
            nxt = set()
            for p in level:
                root = load_json(info, p)
                base = (cj.val(root.get("baseMaterial")) or "").lower() if root else ""
                if base and not base.endswith((".mt", ".remt")) and base not in seen and base not in self.cache:
                    nxt.add(base)
            level = nxt

    def resolve(self, path: str) -> dict:
        path = path.lower()
        if path in self.cache:
            return self.cache[path]
        if path.endswith((".mt", ".remt")):
            res = {"template": path, "values": {}}
            self.cache[path] = res
            return res
        info = cj.extract(self.game, self.cp77tools, self.scratch, [path], self.index)
        root = load_json(info, path)
        if root is None:
            res = {"template": None, "values": {}, "missing": path}
        else:
            parent = self.resolve(cj.val(root["baseMaterial"]))
            values = dict(parent["values"])
            values.update(instance_values(root))
            res = {"template": parent["template"], "values": values}
        self.cache[path] = res
        return res

    def template_params(self, path: str) -> dict:
        info = cj.extract(self.game, self.cp77tools, self.scratch, [path], self.index)
        root = load_json(info, path)
        out = OrderedDict()
        params = (root or {}).get("parameters") or {}
        if isinstance(params, dict):
            params = params.get("Elements") or []
        for stage in params:
            for h in stage:
                d = h.get("Data") or {}
                name = cj.val(d.get("parameterName"))
                if name not in TINT_PARAMS or name in out:
                    continue
                value = None
                for k, x in d.items():
                    if k not in ("$type", "parameterName", "register", "offset", "min", "max"):
                        value = plain(x)
                entry = OrderedDict(type=d.get("$type"), default=value)
                if "min" in d:
                    entry["min"], entry["max"] = d["min"], d["max"]
                out[name] = entry
        return out


def mesh_glass(root: dict, mats: Materials) -> OrderedDict:
    """Every appearance of a mesh: chunk material names and which chunks are glass."""
    entries = {cj.val(e["name"]): e for e in root.get("materialEntries") or []}
    local = ((root.get("localMaterialBuffer") or {}).get("materials")) or []
    if not local:
        local = [x["Data"] for x in root.get("preloadLocalMaterialInstances") or [] if x.get("Data")]
    external = [cj.val(x) for x in root.get("externalMaterials") or []]
    resolved: dict[str, dict] = {}
    for name, e in entries.items():
        idx = e["index"]
        if e["isLocalInstance"]:
            inst = local[idx] if idx < len(local) else None
            if inst is None:
                continue
            base = cj.val(inst["baseMaterial"])
            chain = mats.resolve(base)
            values = dict(chain["values"])
            values.update(instance_values(inst))
            resolved[name] = {"base": base, "template": chain["template"], "values": values,
                              "overrides": sorted(instance_values(inst))}
        else:
            path = external[idx] if idx < len(external) else ""
            chain = mats.resolve(path) if path else {"template": None, "values": {}}
            resolved[name] = {"base": path, "template": chain["template"], "values": chain["values"],
                              "overrides": []}
    out = OrderedDict()
    for a in root.get("appearances") or []:
        a = a["Data"]
        chunks = [cj.val(c) for c in a["chunkMaterials"]]
        glass = []
        for i, c in enumerate(chunks):
            r = resolved.get(c)
            if r and r["template"] and r["template"].rsplit(BS, 1)[-1] in GLASS_TEMPLATES:
                glass.append(i)
        out[cj.val(a["name"])] = {"chunks": chunks, "glassChunks": glass}
    return out, resolved


def tint_view(r: dict) -> OrderedDict:
    return OrderedDict((k, r["values"][k]) for k in TINT_PARAMS if k in r["values"])


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--game", default=os.environ.get("OP77_GAME_DIR"))
    ap.add_argument("--scratch", required=True, help="scratch folder outside the repository")
    ap.add_argument("--trims", help="Light RP shared/vehicle_customization.lua (read only)")
    ap.add_argument("--dealer", default=os.path.join(HERE, "..", "..", "..", "docs", "generated",
                                                     "vehicle-components-dealer-2.50.json"))
    ap.add_argument("--cp77tools", default=DEFAULT_CP77TOOLS)
    ap.add_argument("--version", default="2.50")
    ap.add_argument("--deep", action="store_true",
                    help="also serialize every other mesh of those appearances (body, lights...) to find "
                         "glass chunks a window-named component would miss; slow, heavy scratch kept small")
    a = ap.parse_args(argv)
    repo = os.path.abspath(os.path.join(HERE, "..", "..", ".."))
    if os.path.abspath(a.scratch).lower().startswith(repo.lower()):
        ap.error("--scratch is inside the repository; extracted game files must stay outside it")
    if not a.game or not os.path.isdir(a.game):
        ap.error("--game (or OP77_GAME_DIR) must name the game folder")

    index = cj.archive_index(listings(a.game, a.cp77tools, a.scratch))
    mats = Materials(a.game, a.cp77tools, os.path.join(a.scratch, "x"), index)
    dealer = json.load(open(a.dealer, encoding="utf-8"))
    trims = read_trims(a.trims)

    apps = sorted({ap_["path"] for m in dealer["models"] for ap_ in m["appFiles"]})
    info = cj.extract(a.game, a.cp77tools, os.path.join(a.scratch, "x"), apps, index)
    definitions: dict[tuple, tuple] = {}
    for path in apps:
        v = info.get(path.lower())
        if not v or not v.get("json"):
            continue
        doc = cj.Doc(v["json"])
        for h in doc.root.get("appearances") or []:
            d = doc.deref(h)
            if isinstance(d, dict):
                definitions[(path.lower(), cj.val(d.get("name")))] = (doc, d)

    models_out, mesh_out = [], OrderedDict()
    per_model_targets = []
    named, others = set(), set()
    for m in dealer["models"]:
        by_entry = {e["name"]: e for e in m["appearances"]}
        wanted = [(m["playerAppearance"], "factory", "Factory")]
        wanted += [(t["id"], "trim", t["label"]) for t in trims.get(m["key"], [])]
        rows = []
        for entry_name, role, label in wanted:
            e = by_entry.get(entry_name)
            found = definitions.get((e["app"].lower(), e["appearanceName"])) if e else None
            if not found:
                rows.append({"entityAppearance": entry_name, "role": role, "label": label, "missing": True})
                continue
            doc, d = found
            comps = []
            for c in cj.component_list(doc, d):
                name = cj.val(c.get("name"))
                mesh = cj.val(c.get("mesh")) if c.get("mesh") else ""
                if not mesh:
                    continue
                window = bool(WINDOW_RX.search((name + " " + mesh).lower()))
                parent = cj.binding(doc, c) or {}
                comps.append(OrderedDict(component=name, type=c.get("$type"),
                                         slot=parent.get("slotName") or parent.get("bindName"),
                                         mesh=mesh, meshAppearance=cj.val(c.get("meshAppearance")),
                                         windowNamed=window, windshield=name in WINDSHIELD_COMPONENTS))
                (named if window else others).add(mesh.lower())
            rows.append(OrderedDict(entityAppearance=entry_name, definition=e["appearanceName"], role=role,
                                    label=label, components=comps))
        per_model_targets.append((m, rows))

    material_rows: dict[str, dict] = {}

    # per-mesh results are cached in the scratch folder, so a deep rerun does not serialize the
    # body meshes again (the transient extraction is deleted batch by batch)
    cache_dir = os.path.join(a.scratch, "mesh-glass-cache")
    os.makedirs(cache_dir, exist_ok=True)

    def cache_file(path: str) -> str:
        return os.path.join(cache_dir, hashlib.sha1(path.encode("utf-8")).hexdigest() + ".json")

    def keep(path: str, result: dict) -> None:
        if result.get("missing"):
            mesh_out[path] = {"missing": True}
        elif not result["glass"] and result.get("transient"):
            mesh_out[path] = {"glass": False}
        else:
            mesh_out[path] = OrderedDict(glass=result["glass"], appearances=result["appearances"])
            material_rows[path] = result["resolved"]

    def analyze(paths: list[str], scratch_dir: str, transient: bool) -> None:
        todo = []
        for path in paths:
            if os.path.exists(cache_file(path)):
                with open(cache_file(path), encoding="utf-8") as fh:
                    keep(path, json.load(fh, object_pairs_hook=OrderedDict))
            else:
                todo.append(path)
        # each cp77tools call reopens a whole archive: big batches, few calls
        step = 120
        for i in range(0, len(todo), step):
            batch = todo[i:i + step]
            minfo = cj.extract(a.game, a.cp77tools, scratch_dir, batch, index)
            bases = []
            for path in batch:  # parsed twice rather than holding every mesh in memory
                root = load_json(minfo, path)
                if root is None:
                    continue
                bases += [cj.val(x) for x in root.get("externalMaterials") or []]
                local = list(((root.get("localMaterialBuffer") or {}).get("materials")) or [])
                local += [x["Data"] for x in root.get("preloadLocalMaterialInstances") or [] if x.get("Data")]
                bases += [cj.val(m.get("baseMaterial")) for m in local if isinstance(m, dict)]
            mats.prefetch(bases)
            for path in batch:
                root = load_json(minfo, path)
                if root is None:
                    result = {"missing": True}
                else:
                    apps_, resolved = mesh_glass(root, mats)
                    has_glass = any(x["glassChunks"] for x in apps_.values())
                    result = {"glass": has_glass, "transient": transient}
                    if has_glass or not transient:
                        result.update(appearances=apps_, resolved=resolved)
                    with open(cache_file(path), "w", encoding="utf-8") as fh:
                        json.dump(result, fh)
                keep(path, result)
            if transient:  # body meshes are heavy: keep the scratch small
                shutil.rmtree(scratch_dir, ignore_errors=True)
            print(f"  meshes {min(i + step, len(todo))}/{len(todo)} (cached {len(paths) - len(todo)})", flush=True)

    analyze(sorted(named), os.path.join(a.scratch, "x"), False)
    if a.deep:
        analyze(sorted(others - named), os.path.join(a.scratch, "deep-tmp"), True)

    templates = sorted({r["template"] for res in material_rows.values() for r in res.values()
                        if r["template"] and r["template"].rsplit(BS, 1)[-1] in GLASS_TEMPLATES})
    for m, rows in per_model_targets:
        for row in rows:
            if row.get("missing"):
                continue
            glass = []
            for g in row.pop("components"):
                mesh = mesh_out.get(g["mesh"].lower())
                if mesh is None or mesh.get("glass") is False and not g["windowNamed"]:
                    continue  # not scanned (no --deep) or no glass chunk at all
                app = (mesh.get("appearances") or {}).get(g["meshAppearance"])
                if app is None:
                    g["glassChunks"] = []
                    g["note"] = "mesh appearance not found"
                    glass.append(g)
                    continue
                if not app["glassChunks"] and not g["windowNamed"]:
                    continue  # glass only in other appearances of this mesh
                g["chunks"] = app["chunks"]
                g["glassChunks"] = app["glassChunks"]
                res = material_rows.get(g["mesh"].lower(), {})
                if app["glassChunks"]:
                    first = app["chunks"][app["glassChunks"][0]]
                    r = res[first]
                    g["material"] = first
                    g["glassMaterials"] = sorted({app["chunks"][k] for k in app["glassChunks"]})
                    g["base"] = r["base"]
                    g["template"] = r["template"]
                    g["tint"] = tint_view(r)
                    g["tintable"] = g["windowNamed"] and not g["windshield"]
                    if not g["windowNamed"]:
                        g["note"] = "glass chunk inside a non-window mesh"
                else:
                    g["tintable"] = False
                    g["note"] = "no vehicle_glass chunk (decal or sticker mesh)"
                glass.append(g)
            row["glass"] = glass
        tintable = sorted({g["component"] for row in rows for g in row.get("glass", []) if g.get("tintable")})
        embedded = sorted({g["component"] for row in rows for g in row.get("glass", [])
                           if g.get("glassChunks") and not g["windowNamed"]})
        models_out.append(OrderedDict(
            key=m["key"], label=m["label"], record=m["record"], entity=m["entity"]["path"],
            tintable=bool(tintable),
            reason=None if tintable else "no glass component (motorcycle)",
            tintableComponents=tintable,
            glassInOtherMeshes=embedded if a.deep else None,
            appearances=rows))

    # ---- pack plan (route 2): one appearance per glass mesh, source appearance and level ----
    plan_meshes = OrderedDict()
    used_templates = set()
    for m in models_out:
        for row in m["appearances"]:
            for g in row.get("glass", []):
                if not g.get("tintable"):
                    continue
                pm = plan_meshes.setdefault(g["mesh"], OrderedDict(models=set(), usedByDealer=set()))
                pm["models"].add(m["key"])
                pm["usedByDealer"].add(g["meshAppearance"])
    added = 0
    for mesh, pm in plan_meshes.items():
        apps_ = mesh_out[mesh.lower()]["appearances"]
        res = material_rows[mesh.lower()]
        # every source appearance of the mesh that has a glass chunk, not only the ones the
        # dealer trims use today: a later trim keeps working without a rebuild
        pm["models"] = sorted(pm["models"])
        pm["usedByDealer"] = sorted(pm["usedByDealer"])
        pm["sources"] = OrderedDict()
        for n, ap_ in apps_.items():
            if not ap_["glassChunks"]:
                continue
            swap = OrderedDict()
            for k in ap_["glassChunks"]:
                tmpl = res[ap_["chunks"][k]]["template"].rsplit(BS, 1)[-1]
                if tmpl not in CANONICAL_BASE:
                    swap[str(k)] = OrderedDict(source=ap_["chunks"][k], replacement=None,
                                               note=f"template {tmpl} has no canonical base: chunk kept")
                    continue
                used_templates.add(tmpl)
                swap[str(k)] = OrderedDict(source=ap_["chunks"][k],
                                           replacement="open77_tint<level>" if tmpl == "vehicle_glass.mt"
                                           else "open77_tint<level>_onesided")
            pm["sources"][n] = OrderedDict(chunks=len(ap_["chunks"]), swap=swap,
                                           add=[f"open77_tint{lvl}__{n}" for lvl in LEVELS])
            added += len(LEVELS)
    instances = []
    for tmpl in sorted(used_templates):
        for lvl, v in LEVELS.items():
            onesided = tmpl != "vehicle_glass.mt"
            values = OrderedDict((k, v[k]) for k in ("TintColor", "Opacity", "OpacityBackFace",
                                                     "BackFacesReflectionPower")
                                 if not onesided or k in ONESIDED_PARAMS)
            instances.append(OrderedDict(
                material=f"open77_tint{lvl}" + ("_onesided" if onesided else ""),
                file=f"glass_tint{lvl}" + ("_onesided" if onesided else "") + ".mi",
                baseMaterial=CANONICAL_BASE[tmpl], values=values))
    plan = OrderedDict(
        route=2,
        naming="open77_tint<level>__<source mesh appearance>",
        levels=LEVELS,
        meshes=len(plan_meshes),
        appearancesAdded=added,
        materialInstances=instances,
        perMesh=plan_meshes)

    out = OrderedDict()
    out["generatedBy"] = "scripts/vehicle-kit/windows/glass_inventory.py"
    out["gameVersion"] = a.version
    out["source"] = "installed game archives, serialized with WolvenKit CLI; Light RP trims table"
    out["templates"] = OrderedDict((t, mats.template_params(t)) for t in templates)
    out["baseMaterials"] = OrderedDict(
        (b, OrderedDict(template=mats.resolve(b)["template"],
                        tint=OrderedDict((k, mats.resolve(b)["values"][k]) for k in TINT_PARAMS
                                         if k in mats.resolve(b)["values"])))
        for b in sorted({r["base"] for res in material_rows.values() for r in res.values()
                         if r["template"] and r["template"].rsplit(BS, 1)[-1] in GLASS_TEMPLATES}))
    out["models"] = models_out
    out["meshes"] = OrderedDict((k, v) for k, v in mesh_out.items())
    out["packPlan"] = plan

    data = os.path.join(HERE, "data")
    os.makedirs(data, exist_ok=True)
    jpath = os.path.join(data, f"glass-{a.version}.json")
    with open(jpath, "w", encoding="utf-8", newline="\n") as fh:
        json.dump(out, fh, indent=1, ensure_ascii=False, default=sorted)
        fh.write("\n")
    write_markdown(os.path.join(data, f"glass-{a.version}.md"), out, a.version)
    print(f"wrote {jpath}")
    return 0


def hexrgb(c) -> str:
    if isinstance(c, list):
        return "#%02x%02x%02x" % tuple(c[:3])
    return "—" if c in (None, "") else str(c)


def fnum(x) -> str:
    return ("%.2f" % x).rstrip("0").rstrip(".") if isinstance(x, float) else str(x)


def write_markdown(path: str, doc: dict, version: str) -> None:
    L = []
    L.append(f"# Window glass of the Light RP dealer models ({version})\n")
    L.append("> Generated offline by `scripts/vehicle-kit/windows/glass_inventory.py` from the installed game "
             "(WolvenKit CLI) and the Light RP trims table. Metadata only. Full data: `glass-%s.json`.\n" % version)
    L.append("## Material template\n")
    for t, params in doc["templates"].items():
        L.append(f"`{t}` tint parameters (template defaults):\n")
        L.append("| parameter | type | default | range |")
        L.append("|---|---|---|---|")
        for k, p in params.items():
            d = p["default"]
            d = hexrgb(d) + (f" a={d[3]}" if isinstance(d, list) and len(d) == 4 else "") if isinstance(d, list) else d
            rng = f"{fnum(p['min'])}..{fnum(p['max'])}" if "min" in p else ""
            L.append(f"| `{k}` | {p['type'].replace('CMaterialParameter', '')} | {d} | {rng} |")
        L.append("")
    L.append("## Base material instances used by the glass chunks\n")
    L.append("| base `.mi` | template | TintColor | Opacity | OpacityBackFace | BackFacesReflectionPower |")
    L.append("|---|---|---|---|---|---|")
    for b, v in doc["baseMaterials"].items():
        t = v["tint"]
        L.append(f"| `{b.rsplit(BS, 1)[-1]}` | `{(v['template'] or '').rsplit(BS, 1)[-1]}` | "
                 f"{hexrgb(t.get('TintColor'))} | {fnum(t.get('Opacity', ''))} | {fnum(t.get('OpacityBackFace', ''))} | "
                 f"{fnum(t.get('BackFacesReflectionPower', ''))} |")
    L.append("")
    L.append("## Per model\n")
    L.append("Factory = the record's player appearance; trims = the curated Light RP trims. "
             "**Tintable** = side and rear glass whose chunk material derives from a `vehicle_glass*.mt` "
             "template; the windshield (`window_f`) is listed but left out of the tint.\n")
    L.append("| model | tintable | glass components (tintable) | windshield | meshes | glass mesh appearances used (factory / trims) | base `.mi` | TintColor today | glass in other meshes |")
    L.append("|---|---|---|---|---|---|---|---|---|")
    for m in doc["models"]:
        rows = m["appearances"]
        allg = [g for r in rows for g in r.get("glass", [])]
        tint = sorted({g["component"] for g in allg if g.get("tintable")})
        ws = sorted({g["component"] for g in allg if g["windshield"]})
        meshes = len({g["mesh"] for g in allg if g.get("tintable")})
        used = []
        for r in rows:
            if r.get("missing"):
                used.append(f"{r['label']}: (missing)")
                continue
            apps_ = sorted({g["meshAppearance"] for g in r["glass"] if g.get("tintable")})
            used.append(f"{r['label']}: {', '.join(apps_) or '—'}")
        bases = sorted({g["base"].rsplit(BS, 1)[-1] for g in allg if g.get("tintable")})
        colors = sorted({hexrgb(g["tint"].get("TintColor")) for g in allg if g.get("tintable") and "tint" in g})
        L.append(f"| {m['key']} | {'yes' if m['tintable'] else 'no — ' + (m['reason'] or '')} | "
                 f"{', '.join('`%s`' % c for c in tint) or '—'} | {', '.join('`%s`' % c for c in ws) or '—'} | "
                 f"{meshes} | {'; '.join(used)} | {', '.join(bases) or '—'} | {', '.join(colors) or '—'} | "
                 f"{'not scanned' if m.get('glassInOtherMeshes') is None else (', '.join('`%s`' % c for c in m['glassInOtherMeshes']) or 'none')} |")
    L.append("")
    L.append("## Glass components, factory appearance\n")
    L.append("| model | component | type | slot | mesh | mesh appearance | glass material | base `.mi` | TintColor | Opacity | OpacityBackFace |")
    L.append("|---|---|---|---|---|---|---|---|---|---|---|")
    for m in doc["models"]:
        rows = [r for r in m["appearances"] if r["role"] == "factory" and not r.get("missing")]
        for r in rows:
            for g in r["glass"]:
                t = g.get("tint", {})
                L.append(f"| {m['key']} | `{g['component']}`{' (windshield)' if g['windshield'] else ''} | "
                         f"{g['type'].removeprefix('ent')} | `{g['slot']}` | `{g['mesh'].rsplit(BS, 1)[-1]}` | "
                         f"`{g['meshAppearance']}` | `{g.get('material', g.get('note', ''))}` | "
                         f"`{(g.get('base') or '').rsplit(BS, 1)[-1]}` | {hexrgb(t.get('TintColor', ''))} | "
                         f"{fnum(t.get('Opacity', ''))} | {fnum(t.get('OpacityBackFace', ''))} |")
    L.append("")
    if any(m.get("glassInOtherMeshes") is not None for m in doc["models"]):
        L.append("## Glass chunks outside the window components (`--deep`)\n")
        L.append("Every other mesh of the factory and trim appearances was serialized and its chunk materials "
                 "resolved. A row here is glass the tint would not reach.\n")
        L.append("| model | component | mesh | mesh appearance | glass materials | base |")
        L.append("|---|---|---|---|---|---|")
        any_row = False
        for m in doc["models"]:
            seen = set()
            for r in m["appearances"]:
                for g in r.get("glass", []):
                    if g["windowNamed"] or not g.get("glassChunks"):
                        continue
                    key = (g["component"], g["mesh"], g["meshAppearance"])
                    if key in seen:
                        continue
                    seen.add(key)
                    any_row = True
                    L.append(f"| {m['key']} | `{g['component']}` | `{g['mesh'].rsplit(BS, 1)[-1]}` | "
                             f"`{g['meshAppearance']}` | {', '.join('`%s`' % x for x in g['glassMaterials'])} | "
                             f"`{g['base'].rsplit(BS, 1)[-1]}` |")
        if not any_row:
            L.append("| — | none found | | | | |")
        L.append("")
    p = doc["packPlan"]
    L.append("## Route 2 pack plan (not built)\n")
    L.append(f"- {p['meshes']} glass meshes patched; {p['appearancesAdded']} mesh appearances added, named "
             f"`{p['naming']}`: one per level for every appearance of the mesh that has a glass chunk, so a "
             "trim added later needs no rebuild.")
    L.append("- A new appearance keeps the source's chunk list and swaps only its glass chunks for one of "
             "these original material instances, each naming a vanilla base by depot path:")
    L.append("")
    L.append("| chunk material | file | base (by path) | values set |")
    L.append("|---|---|---|---|")
    for x in p["materialInstances"]:
        vals = ", ".join(f"{k} {hexrgb(v) if isinstance(v, list) else fnum(v)}" for k, v in x["values"].items())
        L.append(f"| `{x['material']}` | `{x['file']}` | `{x['baseMaterial']}` | {vals} |")
    L.append("")
    L.append("| level | label | TintColor | Opacity | OpacityBackFace | BackFacesReflectionPower | values taken from |")
    L.append("|---|---|---|---|---|---|---|")
    for lvl, v in p["levels"].items():
        L.append(f"| {lvl} | {v['label']} | {hexrgb(v['TintColor'])} | {fnum(v['Opacity'])} | {fnum(v['OpacityBackFace'])} | "
                 f"{fnum(v['BackFacesReflectionPower'])} | {v['vanilla']} |")
    L.append("")
    L.append("| mesh | models | appearances with glass | added |")
    L.append("|---|---|---|---|")
    for mesh, pm in p["perMesh"].items():
        L.append(f"| `{mesh.rsplit(BS, 1)[-1]}` | {', '.join(pm['models'])} | "
                 f"{', '.join('`%s`' % s for s in pm['sources'])} | {len(pm['sources']) * len(p['levels'])} |")
    L.append("")
    with open(path, "w", encoding="utf-8", newline="\n") as fh:
        fh.write("\n".join(L))


if __name__ == "__main__":
    sys.exit(main())
