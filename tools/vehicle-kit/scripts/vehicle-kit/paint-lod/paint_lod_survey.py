#!/usr/bin/env python3
"""Paint at distance: which vehicle appearances keep a custom paint once the camera backs off (offline).

Why this exists
---------------
A car painted through the vanilla visual customization (generic paint or a colour-template
livery) shows the paint up close and its factory look further away, on some appearances only.
Every distance switch of a vehicle's look is driven by the entity's `AppearanceVisualController`,
whose distance profile comes from the appearance's `forcedLodDistance` byte in the `.app`:
5 = CinematicVehicle (player and story cars), 0 = Default, which a traffic vehicle resolves to
the Vehicle profile. The profile distances live in `engine\\systems\\visual_controller_lod_distances.json`,
one definition per graphics `LODPreset` (Low, Medium, High). Past the last distance the
controller swaps the appearance for its `entAppearanceProxyMeshComponent`, whose mesh is a baked
`engine\\materials\\metal_base.remt` material with no customization input: no paint can show there.
See docs/research/vehicles-api.md, section "Peinture perdue au-dela de 5 m sur les finitions usees".

What it reports, per model and appearance (stock appearance plus the Light RP trims):
- the `.app` appearance behind the entity appearance, its `forcedLodDistance` and resolved profile;
- the profile distances for each LOD preset;
- the proxy mesh, its root materials and whether any can take the paint (root template exposes
  `CustomColorA`, the generic paint input of `base\\materials\\vehicle_destr_blendshape.mt`);
- for every component the `vvc_color` effect paints and the appearance shows: whether each mesh
  LOD keeps a paintable material, and the mesh's own `lodLevelInfo`;
- a verdict: `vehicle-profile` (forcedLodDistance 0: the paint is lost at the Vehicle distances,
  the reported bug), `cinematic-profile` (forcedLodDistance 5: the vanilla player-car distances),
  `mesh-lod-loss` (a far mesh LOD of a painted part is not paintable), or `no paintable body`.

It never launches the game and never writes in the game folder. Game files are extracted and
serialized with WolvenKit CLI (`cp77tools`) into `--work` (default
`artifacts/vehicle-kit/paint-lod`, git-ignored; the script refuses a non-ignored folder inside
the repository), cached between runs and fetched in batches (each extraction scans the whole
archive folder, base content first, then ep1, which shadows it). Nothing it writes may be
committed. Python 3.10+, standard library only.

    python -I scripts/vehicle-kit/paint-lod/paint_lod_survey.py --trims <light-rp>/resources/gamemodes/op77_lightrp/shared/vehicle_customization.lua
    python -I scripts/vehicle-kit/paint-lod/paint_lod_survey.py --models hella,hozuki

Outputs `<work>/paint-lod.json` and `<work>/paint-lod.md`, and ends with `VK_PAINT_LOD_OK`.
"""
from __future__ import annotations

import argparse
import json
import os
import re
import shutil
import subprocess
import sys

REPO = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", "..", ".."))
BS = "\\"
FORCED_LOD = ["Default", "Background", "Regular", "Cinematic", "Vehicle", "CinematicVehicle",
              "VehicleInterior", "VehicleDecoration", "ConsoleLOD"]
PROFILE_FIELD = {"Background": "backgroundDistanceLODs", "Regular": "regularDistanceLODs",
                 "Cinematic": "cinematicDistanceLODs", "Vehicle": "vehicleDistanceLODs",
                 "CinematicVehicle": "cinematicVehicleDistanceLODs",
                 "VehicleInterior": "vehicleInteriorDistanceLODs",
                 "VehicleDecoration": "vehicleDecorationDistanceLODs"}
PRESETS = ["Low", "Medium", "High"]  # LODPreset index -> definitions[index] (clamped to count - 2)
LOD_JSON = BS.join(["engine", "systems", "visual_controller_lod_distances.json"])
PAINT_PARAM = "CustomColorA"


def game_dir(arg: str | None) -> str:
    cands = [arg, os.environ.get("OP77_GAME_DIR")]
    if sys.platform == "win32":
        try:
            import winreg
            with winreg.OpenKey(winreg.HKEY_CURRENT_USER, "Environment") as k:
                cands.append(winreg.QueryValueEx(k, "OP77_GAME_DIR")[0])
        except OSError:
            pass
    cands.append(r"C:\Program Files (x86)\Steam\steamapps\common\Cyberpunk 2077")
    for c in cands:
        if c and os.path.isfile(os.path.join(c, "bin", "x64", "Cyberpunk2077.exe")):
            return c
    sys.exit("game folder not found: pass --game or set OP77_GAME_DIR")


class Depot:
    """Extracts + serializes depot files in batches, cached under <work>/raw and <work>/json."""

    def __init__(self, game: str, work: str, cli: str):
        self.game, self.cli = game, cli
        self.raw, self.json = os.path.join(work, "raw"), os.path.join(work, "json")
        self.flat = os.path.join(work, "flat_tmp")
        os.makedirs(self.raw, exist_ok=True)
        os.makedirs(self.json, exist_ok=True)
        self.cache: dict[str, dict | None] = {}
        self.missing: set[str] = set()

    def _jpath(self, p: str) -> str:
        return os.path.join(self.json, p.replace(BS, "~") + ".json")

    def fetch(self, paths) -> None:
        paths = sorted({p for p in paths if p and p not in self.cache and p not in self.missing
                        and not os.path.exists(self._jpath(p))})
        if not paths:
            return
        todo_raw = [p for p in paths if not os.path.exists(os.path.join(self.raw, p))]
        if todo_raw:
            print(f"  extracting {len(todo_raw)} file(s)", flush=True)
            for sub in ("content", "ep1"):  # ep1 last: it shadows base content
                src = os.path.join(self.game, "archive", "pc", sub)
                for i in range(0, len(todo_raw), 60):
                    rx = "|".join("^" + re.escape(p) + "$" for p in todo_raw[i:i + 60])
                    subprocess.run([self.cli, "extract", src, "--regex", rx, "--outpath", self.raw],
                                   capture_output=True, text=True)
        have = [p for p in paths if os.path.exists(os.path.join(self.raw, p))]
        self.missing.update(p for p in paths if p not in have)
        if have:
            if os.path.isdir(self.flat):
                shutil.rmtree(self.flat)
            os.makedirs(self.flat)
            for p in have:
                shutil.copyfile(os.path.join(self.raw, p), os.path.join(self.flat, p.replace(BS, "~")))
            subprocess.run([self.cli, "convert", "serialize", self.flat, "--outpath", self.json],
                           capture_output=True, text=True)
            shutil.rmtree(self.flat)

    def get(self, p: str | None) -> dict | None:
        if not p:
            return None
        if p in self.cache:
            return self.cache[p]
        j = self._jpath(p)
        if not os.path.exists(j):
            self.fetch([p])
        data = None
        if os.path.exists(j):
            with open(j, encoding="utf-8") as fh:
                data = json.load(fh)["Data"]["RootChunk"]
        self.cache[p] = data
        return data


def val(x):
    if isinstance(x, dict):
        if "$value" in x:
            return x["$value"]
        if "DepotPath" in x:
            return val(x["DepotPath"])
    return x


def handles(raw) -> dict[str, dict]:
    out: dict[str, dict] = {}

    def walk(x):
        if isinstance(x, dict):
            if "HandleId" in x and isinstance(x.get("Data"), dict):
                out[x["HandleId"]] = x["Data"]
            for v in x.values():
                walk(v)
        elif isinstance(x, list):
            for v in x:
                walk(v)
    walk(raw)
    return out


def deref(x, table):
    if isinstance(x, dict) and "HandleRefId" in x:
        return table.get(x["HandleRefId"], {})
    if isinstance(x, dict) and isinstance(x.get("Data"), dict):
        return x["Data"]
    return x


def mesh_materials(mesh: dict) -> tuple[dict[str, str | None], dict[str, list]]:
    """material name -> base material path; mesh appearance -> chunk material names."""
    entries = mesh.get("materialEntries") or []
    local = (mesh.get("localMaterialBuffer") or {}).get("materials") or mesh.get("preloadLocalMaterialInstances") or []
    ext = mesh.get("externalMaterials") or mesh.get("preloadExternalMaterials") or []
    bases: dict[str, str | None] = {}
    for e in entries:
        n, i = val(e.get("name")), e.get("index", 0)
        if e.get("isLocalInstance"):
            m = local[i] if i < len(local) else {}
            m = m.get("Data", m) if isinstance(m, dict) else {}
            bases[n] = val(m.get("baseMaterial"))
        else:
            bases[n] = val(ext[i]) if i < len(ext) else None
    apps = {}
    for a in mesh.get("appearances") or []:
        a = a.get("Data", a)
        apps[val(a.get("name"))] = [val(c) for c in a.get("chunkMaterials") or []]
    return bases, apps


def chunk_lod_masks(mesh: dict) -> list[int]:
    blob = mesh.get("renderResourceBlob") or {}
    blob = blob.get("Data", blob)
    return [c.get("lodMask", 1) for c in (blob.get("header") or {}).get("renderChunkInfos") or []]


class Materials:
    """Resolves material instance chains to their root template, in batches, and tells paintability."""

    def __init__(self, depot: Depot):
        self.depot = depot

    def prefetch(self, starts) -> None:
        frontier, seen = set(p for p in starts if p), set()
        while frontier:
            self.depot.fetch(frontier)
            seen |= frontier
            nxt = set()
            for p in frontier:
                if p.lower().endswith(".mi"):
                    mi = self.depot.get(p)
                    b = val(mi.get("baseMaterial")) if mi else None
                    if b and b not in seen:
                        nxt.add(b)
            frontier = nxt

    def root_of(self, base: str | None) -> str | None:
        seen = set()
        while base and base.lower().endswith(".mi") and base not in seen:
            seen.add(base)
            mi = self.depot.get(base)
            if mi is None:
                return None
            base = val(mi.get("baseMaterial"))
        return base

    def paintable(self, root: str | None) -> bool | None:
        t = self.depot.get(root)
        if t is None:
            return None
        names = {val(p.get("name")) for stage in t.get("parameterInfo") or [] for p in stage or []}
        return PAINT_PARAM in names


def parse_trims(path: str | None) -> dict[str, list[tuple[str, str]]]:
    if not path:
        return {}
    text = open(path, encoding="utf-8").read()
    m = re.search(r"\n    trims = \{(.*?)\n    \},", text, re.S)
    if not m:
        sys.exit(f"no `trims = {{...}}` table in {path}")
    out: dict[str, list[tuple[str, str]]] = {}
    for model, body in re.findall(r"\n        (\w+) = \{(.*?)\n        \},", m.group(1), re.S):
        out[model] = re.findall(r'id = "([^"]+)", label = "([^"]+)"', body)
    return out


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("--game")
    ap.add_argument("--work", default=os.path.join(REPO, "artifacts", "vehicle-kit", "paint-lod"))
    ap.add_argument("--cp77tools", default=os.path.expanduser(os.path.join("~", ".dotnet", "tools", "cp77tools.exe")))
    ap.add_argument("--dealer", default=os.path.join(REPO, "docs", "generated", "vehicle-components-dealer-2.50.json"))
    ap.add_argument("--trims", help="Light RP shared/vehicle_customization.lua (table `trims`)")
    ap.add_argument("--models", help="comma-separated dealer keys (default: all)")
    args = ap.parse_args()

    work = os.path.abspath(args.work)
    if os.path.normcase(work).startswith(os.path.normcase(REPO + os.sep)):
        rel = os.path.relpath(work, REPO).replace(BS, "/")
        if subprocess.run(["git", "-C", REPO, "check-ignore", "-q", rel + "/x"]).returncode != 0:
            sys.exit(f"--work {work} is inside the repository and not git-ignored: game files would be committable")
    depot = Depot(game_dir(args.game), work, args.cp77tools)
    mats = Materials(depot)

    lod = depot.get(LOD_JSON)
    if lod is None:
        sys.exit("cannot read " + LOD_JSON)
    defs = lod["root"]["Data"]["root"]["Data"]["definitions"]["Elements"]  # JsonResource > entDistanceLODsPresets
    profiles = {name: {PRESETS[i]: defs[i][field]["Elements"] for i in range(len(PRESETS))}
                for name, field in PROFILE_FIELD.items()}

    dealer = json.load(open(args.dealer, encoding="utf-8"))
    trims = parse_trims(args.trims)
    keys = args.models.split(",") if args.models else [m["key"] for m in dealer["models"]]
    models = [m for m in dealer["models"] if m["key"] in keys]

    # phase 1: entities, then the .app files they point to
    print("entities", flush=True)
    depot.fetch(m["entity"]["path"] for m in models)
    plan = []  # (model, ent_path, ent_raw, app_of, painted, wanted)
    for m in models:
        ent_raw = depot.get(m["entity"]["path"])
        if ent_raw is None:
            plan.append((m, None, {}, [], []))
            continue
        table = handles(ent_raw)
        app_of = {val(a["name"]): (val(a["appearanceResource"]), val(a["appearanceName"]))
                  for a in ent_raw.get("appearances") or []}
        painted: list[str] = []
        for c in ent_raw.get("components") or []:
            if c.get("$type") != "entEffectSpawnerComponent":
                continue
            for d in c.get("effectDescs") or []:
                d = deref(d, table)
                if val(d.get("effectName")) == "vvc_color":
                    painted = [val(n) for n in (d.get("compiledEffectInfo") or {}).get("componentNames") or []]
        stock = m.get("playerAppearance") or m["tweakdb"].get("appearanceName")
        wanted = [(stock, "stock")] if stock and stock != "None" else []
        wanted += [(i, lbl) for i, lbl in trims.get(m["key"], []) if i != stock]
        plan.append((m, ent_raw, app_of, painted, wanted))
    print("appearances", flush=True)
    depot.fetch(app_of[w][0] for _, ent_raw, app_of, _, wanted in plan for w, _ in wanted if w in app_of)

    # phase 2: resolve each appearance, list its proxy and painted meshes
    rows, mesh_paths = [], set()
    for m, ent_raw, app_of, painted, wanted in plan:
        if ent_raw is None:
            rows.append({"model": m["key"], "appearance": "", "label": "", "error": "entity not readable: " + m["entity"]["path"]})
            continue
        for name, label in wanted:
            row = {"model": m["key"], "record": m["record"], "appearance": name, "label": label}
            rows.append(row)
            if name not in app_of:
                row["error"] = "appearance not in " + m["entity"]["path"]
                continue
            app_path, app_name = app_of[name]
            app = depot.get(app_path)
            adef = next((a["Data"] for a in (app or {}).get("appearances", []) if val(a["Data"]["name"]) == app_name), None)
            if adef is None:
                row["error"] = f"{app_name} not in {app_path}"
                continue
            fld = int(adef.get("forcedLodDistance") or 0)
            prof = FORCED_LOD[fld] if fld < len(FORCED_LOD) else str(fld)
            eff = "Vehicle" if prof == "Default" else prof
            comps = adef.get("components") or []
            proxy = val(adef.get("proxyMesh"))
            for c in comps:
                if c.get("$type") == "entAppearanceProxyMeshComponent":
                    proxy = val(c.get("mesh")) or proxy
            meshes = []
            for c in comps:
                if c.get("$type") == "entAppearanceProxyMeshComponent" or "mesh" not in c:
                    continue
                n = val(c.get("name"))
                if n in painted and str(c.get("chunkMask")) != "0" and c.get("isEnabled", 1):
                    meshes.append((n, val(c.get("mesh")), val(c.get("meshAppearance")), c.get("LODMode")))
            row.update(app=app_path, appName=app_name, forcedLodDistance=fld, profile=prof,
                       effectiveProfile=eff, distances=profiles.get(eff), proxyMesh=proxy, _meshes=meshes)
            mesh_paths.add(proxy)
            mesh_paths.update(p for _, p, _, _ in meshes)
    print(f"meshes ({len(mesh_paths)})", flush=True)
    depot.fetch(mesh_paths)
    print("materials", flush=True)
    starts = set()
    for p in mesh_paths:
        mesh = depot.get(p)
        if mesh:
            starts.update(b for b in mesh_materials(mesh)[0].values() if b)
    mats.prefetch(starts)

    # phase 3: verdicts
    for row in rows:
        if "error" in row:
            continue
        meshes = row.pop("_meshes")
        pm = depot.get(row["proxyMesh"])
        if pm is None:
            row["proxyPaintable"] = None
        else:
            bases, _ = mesh_materials(pm)
            roots = {mats.root_of(b) for b in bases.values()}
            row["proxyMaterials"] = sorted(r or "?" for r in roots)
            row["proxyPaintable"] = any(mats.paintable(r) for r in roots)
        comp_rows = []
        for n, p, mapp, mode in meshes:
            mesh = depot.get(p)
            if mesh is None:
                comp_rows.append({"component": n, "mesh": p, "error": "unreadable"})
                continue
            bases, apps = mesh_materials(mesh)
            chunks = apps.get(mapp) or apps.get("default") or (next(iter(apps.values())) if apps else [])
            per_lod: dict[int, bool] = {}
            for mask, mat in zip(chunk_lod_masks(mesh), chunks):
                ok = bool(mats.paintable(mats.root_of(bases.get(mat))))
                for lv in range(8):
                    if mask & (1 << lv):
                        per_lod[lv] = per_lod.get(lv, False) or ok
            comp_rows.append({"component": n, "mesh": p, "meshAppearance": mapp, "LODMode": mode,
                              "lodLevelInfo": mesh.get("lodLevelInfo"),
                              "paintableByLod": [per_lod[k] for k in sorted(per_lod)]})
        row["paintedComponents"] = comp_rows
        lod0 = [c for c in comp_rows if c.get("paintableByLod") and c["paintableByLod"][0]]
        row["farLodLoss"] = [c["component"] for c in lod0 if not all(c["paintableByLod"])]
        if not lod0:
            row["verdict"] = "no paintable body"
        elif row["farLodLoss"]:
            row["verdict"] = "mesh-lod-loss"
        elif row.get("proxyPaintable"):
            row["verdict"] = "proxy-paintable"
        else:
            row["verdict"] = "vehicle-profile" if row["effectiveProfile"] == "Vehicle" else "cinematic-profile"

    out = {"lodPresets": PRESETS, "profiles": profiles, "rows": rows,
           "note": "vehicle-profile = paint lost at the Vehicle profile distances (the reported bug); "
                   "cinematic-profile = the vanilla player-car distances; the proxy never shows paint"}
    with open(os.path.join(work, "paint-lod.json"), "w", encoding="utf-8") as fh:
        json.dump(out, fh, indent=1)
    lines = ["| Model | Appearance | Light RP | forcedLodDistance | Profile, Low / Medium / High (m) | Proxy root material | Painted parts paintable on every mesh LOD | Verdict |",
             "|---|---|---|---|---|---|---|---|"]
    for r in rows:
        if "error" in r:
            lines.append(f"| {r['model']} | `{r.get('appearance', '')}` | {r.get('label', '')} | | | | | error: {r['error']} |")
            continue
        d = r.get("distances") or {}
        dist = " / ".join(",".join(f"{x:g}" for x in d.get(p, [])) for p in PRESETS)
        pmat = ", ".join(x.split(BS)[-1] for x in r.get("proxyMaterials", [])) or "?"
        far = "yes" if not r["farLodLoss"] else "no: " + ", ".join(r["farLodLoss"])
        lines.append(f"| {r['model']} | `{r['appearance']}` | {r['label']} | {r['forcedLodDistance']} ({r['profile']}) | "
                     f"{r['effectiveProfile']} {dist} | {pmat} | {far} | {r['verdict']} |")
    with open(os.path.join(work, "paint-lod.md"), "w", encoding="utf-8") as fh:
        fh.write("\n".join(lines) + "\n")
    print("\n".join(lines))
    print(f"VK_PAINT_LOD_OK rows={len(rows)} vehicle_profile={sum(1 for r in rows if r.get('verdict') == 'vehicle-profile')} "
          f"errors={sum(1 for r in rows if 'error' in r)} missing_files={len(depot.missing)}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
