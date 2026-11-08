"""Native cook of the sticker pack (wave 2, W2.4): plan.json in, WolvenKit JSON + TweakXL YAML out.

    python st_cook.py prepare  <cook.json>   decal entities, YAML, Lua catalogue, catalogue JSON, package.json
    python st_cook.py validate <cook.json>   serialize round trip of every entity

What the pack carries is OURS: one .ent per decal of the plan (the liveries' decal entity,
lv_cook.decal_entity: one entMeshComponent "decal"), whose component points at the VANILLA
sticker mesh by depot path and carries the vanilla component's meshAppearance, chunkMask,
local transform and scale. No game file is copied; the only references outside the pack are
the plan's sticker meshes (checked here, decision D6).

TweakXL records (Vehicle.* namespace, nothing vanilla is modified):
    Vehicle.o77_st_<model>_<hash>          VehicleDecalAttachment: host component + our .ent.
                                           One per decal, shared by every sticker showing it.
    Vehicle.o77_sticker_st_<model>_<name>  VehicleColorTemplate used as a list holder: its
                                           customDecals = the sticker's decal records. Never
                                           appended to any AppearancesToColorTemplate, so the
                                           game never picks or applies it as a paint job.

Which route uses what (docs/research/vehicle-wave2-packs.md):
    route A, ShowUniqueCustomizationDecalsWithDisolve(array<vehicleVehicleDecalAttachmentData>):
      per decal {componentToAttachTo, decalReference}: the `parts` of the catalogue, or the
      holder's customDecals read from TweakDB (componentToAttachTo + decalResource);
    route B, template composition: the holder's customDecals (record ids) appended to the
      livery template's customDecals, 12 at most in total.
"""
from __future__ import annotations

import json
import math
import re
import sys
from collections import OrderedDict
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parent / "liveries"))
from lv_common import BS, MAX_DECALS_PER_TEMPLATE, cv, flat_name, read_json, write_json  # noqa: E402
from lv_cook import check_depot, decal_entity, depot_paths  # noqa: E402

RECORD_RE = re.compile(r"^Vehicle\.o77_[a-z0-9_]+$")
LUA_SAFE = re.compile(r"^[\x20-\x7e]*$")


def fail(msg):
    raise SystemExit(f"st_cook: {msg}")


def yq(s):
    return "'" + str(s).replace("'", "''") + "'"


def lua_str(s):
    s = str(s)
    if not LUA_SAFE.match(s):
        fail(f"non-ASCII text for Lua: {s!r}")
    return json.dumps(s)


def ent_depot(prefix, key, h):
    return check_depot(f"{prefix}{BS}decals{BS}{key}{BS}{h}.ent", prefix, ".ent")


def apply_component(comp, d):
    """The vanilla sticker component's look and placement on our decal component."""
    x, y, z = d["transform"]["positionBits"]
    i, j, k, r = d["transform"]["orientation"]
    sx, sy, sz = d["visualScale"]
    comp["chunkMask"] = d["chunkMask"]
    comp["localTransform"]["Position"] = {"$type": "WorldPosition",
                                          **{a: {"$type": "FixedPoint", "Bits": int(v)} for a, v in zip("xyz", (x, y, z))}}
    comp["localTransform"]["Orientation"] = {"$type": "Quaternion", "i": i, "j": j, "k": k, "r": r}
    comp["visualScale"] = {"$type": "Vector3", "X": sx, "Y": sy, "Z": sz}


def sticker_entity(d, depot, wk_version):
    doc = decal_entity(d["mesh"], d["meshAppearance"], depot, wk_version)
    root = doc["Data"]["RootChunk"]
    apply_component(root["components"][0], d)
    apply_component(root["compiledData"]["Data"]["Chunks"][1], d)
    return doc


def mesh_facts(mesh_json: Path):
    """(appearance names, chunk count) of a serialized vanilla mesh."""
    root = read_json(mesh_json)["Data"]["RootChunk"]
    names = [cv((a.get("Data") or {}).get("name")) for a in root.get("appearances") or []]
    chunks = None
    blob = ((root.get("renderResourceBlob") or {}).get("Data") or {}).get("header") or {}
    if isinstance(blob.get("renderChunkInfos"), list):
        chunks = len(blob["renderChunkInfos"])
    return [n for n in names if n], chunks


def check_mesh(cfg, d):
    p = Path(cfg["meshJsonDir"]) / (flat_name(d["mesh"]) + ".json")
    if not p.exists():
        fail(f"vanilla mesh {d['mesh']} was not serialized ({p}): is it in the game archives?")
    names, chunks = mesh_facts(p)
    # The vanilla component may name "default" on a mesh without that appearance (the Galena
    # q000 door stickers: mesh appearance "q000" only) and the game still draws it: the engine
    # falls back to the mesh's first appearance (inference from the vanilla look). We copy the
    # vanilla value as it is and record the fallback; any other unknown name is refused.
    fallback = None
    if d["meshAppearance"] not in names:
        if d["meshAppearance"] != "default" or not names:
            fail(f"{d['record']}: meshAppearance {d['meshAppearance']} not in {d['mesh']} ({', '.join(names)})")
        fallback = names[0]
    mask = int(d["chunkMask"])
    if chunks is not None and chunks < 64 and mask & ((1 << chunks) - 1) == 0:
        fail(f"{d['record']}: chunkMask {mask} shows none of the {chunks} chunks of {d['mesh']}")
    return {"appearances": names, "chunks": chunks, "defaultFallsBackTo": fallback}


def prepare(cfg):
    plan = read_json(cfg["plan"])
    prefix, out = cfg["prefix"], Path(cfg["preparedDir"])
    cap = plan["limits"]["maxDecalsPerCar"]
    if cap > MAX_DECALS_PER_TEMPLATE:
        fail(f"maxDecalsPerCar {cap} is above the engine cap {MAX_DECALS_PER_TEMPLATE}")
    files, decal_records, sticker_records, meshes = [], [], [], {}
    yaml = [
        "# Open77 Light RP vehicle stickers: decal attachments and per-sticker decal lists (TweakXL).",
        f"# Generated by scripts/vehicle-kit/stickers/build-stickers.ps1, revision {cfg['revision'][:12]}. Edit the spec, not this file.",
        "# Each decal = OUR .ent wrapping a VANILLA sticker mesh (referenced by path, never shipped), hung on the",
        "# player appearance's component. Each Vehicle.o77_sticker_* record only lists decals: it is in no",
        "# AppearancesToColorTemplate, so the game never applies it as a paint job.",
        "",
    ]
    catalogue, models_out = [], OrderedDict()
    for m in plan["models"]:
        key = m["key"]
        by_id = {}
        for d in m["decals"]:
            if not RECORD_RE.match(d["record"]):
                fail(f"record name refused: {d['record']}")
            depot = ent_depot(prefix, key, d["id"])
            info = check_mesh(cfg, d)
            kept = meshes.setdefault(d["mesh"], info)
            if info["defaultFallsBackTo"]:
                kept["defaultFallsBackTo"] = info["defaultFallsBackTo"]
            write_json(out / (flat_name(depot) + ".json"), sticker_entity(d, depot, cfg["wolvenkit"]))
            files.append(depot)
            decal_records.append(d["record"])
            by_id[d["id"]] = OrderedDict([("record", d["record"]), ("component", d["component"]), ("decal", depot)])
            yaml += [
                f"{d['record']}:",
                "  $type: VehicleDecalAttachment",
                f"  componentToAttachTo: {yq(d['component'])}",
                f"  decalResource: {yq(depot)}",
                "  onlyForPlayerVehicleAppearances: []",
                "",
            ]
        for s in m["stickers"]:
            if not RECORD_RE.match(s["record"]):
                fail(f"record name refused: {s['record']}")
            parts = [by_id[h] for h in s["parts"]]
            if len(parts) != s["decals"] or not 1 <= len(parts) <= plan["limits"]["maxDecalsPerSticker"]:
                fail(f"{s['id']}: {len(parts)} decals")
            yaml += [
                f"{s['record']}:",
                "  $type: VehicleColorTemplate",
                "  hasCustomPattern: true",
                "  mainColor: []",
                "  secondaryColor: []",
                "  lightsHue: -1.0",
                "  matchingAppearances: []",
                "  matchingColorVariant: []",
                "  partsClearCoatOverrides: []",
                "  customMultilayers: []",
                "  customDecals:",
                *[f"    - {p['record']}" for p in parts],
                "",
            ]
            sticker_records.append(s["record"])
            catalogue.append(OrderedDict([
                ("id", s["id"]), ("label", s["label"]), ("group", s["group"]), ("model", s["model"]),
                ("decals", s["decals"]), ("record", s["record"]), ("parts", parts),
            ]))
        if m["stickers"]:
            models_out[m["record"]] = OrderedDict([("key", key), ("stickers", [s["id"] for s in m["stickers"]])])
    if len(set(decal_records + sticker_records)) != len(decal_records) + len(sticker_records):
        fail("duplicate record names")
    Path(cfg["yamlOut"]).parent.mkdir(parents=True, exist_ok=True)
    Path(cfg["yamlOut"]).write_text("\n".join(yaml), encoding="utf-8", newline="\n")
    # D6: every reference outside the pack must be one of the plan's vanilla sticker meshes.
    allowed = set(meshes)
    for f in files:
        for p in depot_paths(read_json(out / (flat_name(f) + ".json"))):
            if not (p.startswith(prefix + BS) or p in allowed):
                fail(f"{f} references {p}, outside the pack and not a planned sticker mesh")
    rev12 = cfg["revision"][:12]
    lines = [f"-- Generated by build-stickers.ps1 (revision {rev12}). Edit the spec, not this file.",
             "LightRpVehicleStickers = {",
             f"    revision = '{rev12}',",
             f"    depotPrefix = {lua_str(prefix)},",
             f"    maxDecalsPerCar = {cap},",
             f"    maxDecalsPerSticker = {plan['limits']['maxDecalsPerSticker']},",
             "    stickers = {"]
    for e in catalogue:
        lines.append(f"        {{ id = {lua_str(e['id'])}, label = {lua_str(e['label'])}, group = {lua_str(e['group'])}, "
                     f"model = {lua_str(e['model'])}, decals = {e['decals']}, record = {lua_str(e['record'])}, parts = {{")
        for p in e["parts"]:
            lines.append(f"            {{ record = {lua_str(p['record'])}, component = {lua_str(p['component'])}, "
                         f"decal = {lua_str(p['decal'])} }},")
        lines.append("        } },")
    lines += ["    },", "}", ""]
    Path(cfg["luaOut"]).parent.mkdir(parents=True, exist_ok=True)
    Path(cfg["luaOut"]).write_text("\n".join(lines), encoding="utf-8", newline="\n")
    write_json(cfg["catalogueOut"], OrderedDict([
        ("schema", "open77.vehicle-stickers.catalogue/1"), ("revision", rev12), ("depotPrefix", prefix),
        ("note", "registerStickers rows (contract: id, label, group, model, decals) plus, per sticker, its holder "
                 "record and its decals: route A needs component + decal (.ent depot path), route B the decal records."),
        ("maxDecalsPerCar", cap), ("maxDecalsPerSticker", plan["limits"]["maxDecalsPerSticker"]),
        ("stickers", catalogue), ("models", models_out),
    ]))
    write_json(cfg["packageOut"], OrderedDict([
        ("files", sorted(files)), ("decalRecords", decal_records), ("stickerRecords", sticker_records),
        ("referencedMeshes", OrderedDict(sorted(meshes.items()))),
    ]))
    print(f"ST_COOK_PREPARED files={len(files)} decalRecords={len(decal_records)} stickerRecords={len(sticker_records)} "
          f"meshes={len(meshes)}")


def mesh_component(root):
    comps = [c for c in root.get("components") or [] if c.get("$type") == "entMeshComponent"]
    return comps[0] if len(comps) == 1 else None


def same_look(a, b):
    if cv(a["mesh"]) != cv(b["mesh"]) or cv(a["meshAppearance"]) != cv(b["meshAppearance"]):
        return "mesh or appearance"
    if str(a["chunkMask"]) != str(b["chunkMask"]):
        return "chunkMask"
    pa, pb = a["localTransform"]["Position"], b["localTransform"]["Position"]
    if any(int(pa[k]["Bits"]) != int(pb[k]["Bits"]) for k in "xyz"):
        return "position"
    qa, qb = a["localTransform"]["Orientation"], b["localTransform"]["Orientation"]
    if any(not math.isclose(float(qa.get(k, 0)), float(qb.get(k, 0)), abs_tol=1e-6) for k in "ijkr"):
        return "orientation"
    if any(not math.isclose(float(a["visualScale"][k]), float(b["visualScale"][k]), abs_tol=1e-6) for k in "XYZ"):
        return "scale"
    return None


def validate(cfg):
    out, rt = Path(cfg["preparedDir"]), Path(cfg["roundtripDir"])
    pkg = read_json(cfg["packageOut"])
    for f in pkg["files"]:
        a = read_json(out / (flat_name(f) + ".json"))["Data"]["RootChunk"]
        b_path = rt / (flat_name(f) + ".json")
        if not b_path.exists():
            fail(f"round trip lost {f}")
        b = read_json(b_path)["Data"]["RootChunk"]
        if b.get("$type") != "entEntityTemplate":
            fail(f"{f}: type {b.get('$type')} after the round trip")
        ca, cb = mesh_component(a), mesh_component(b)
        if cb is None:
            fail(f"{f}: not exactly one entMeshComponent after the round trip")
        why = same_look(ca, cb)
        if why:
            fail(f"{f}: {why} changed in the round trip")
    print(f"ST_COOK_ROUNDTRIP_OK files={len(pkg['files'])}")


if __name__ == "__main__":
    if len(sys.argv) != 3 or sys.argv[1] not in ("prepare", "validate"):
        fail("usage: st_cook.py prepare|validate <cook.json>")
    c = read_json(sys.argv[2])
    {"prepare": prepare, "validate": validate}[sys.argv[1]](c)
