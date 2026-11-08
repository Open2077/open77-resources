"""Survey of the stickers the game fits to the Light RP dealer models (wave 2, W2.4), offline.

Input: the dealer table `docs/generated/vehicle-components-dealer-2.50.json` (which .app files
each model uses, its player appearance) and those .app files serialized by WolvenKit
(`<json dir>/<depot path with \\ as ~>.json`, as build-stickers.ps1 writes them). Output: one
JSON of depot paths, component names and transforms, nothing else of the game:

    models[].stickers[]   one row per distinct sticker component (mesh, meshAppearance, chunkMask,
                          local transform, binding), with the vanilla appearances that carry it
    models[].attach       how each binding of the sticker components resolves in the PLAYER
                          appearance, the one a dealer car spawns with

A VehicleDecalAttachment hangs its decal entity on a component of the car by name
(`componentToAttachTo`: body_01, door_fl_a, hood_a... in the 188 vanilla records). A sticker
bound to a panel the player appearance also has attaches there directly. A sticker bound to
the slot component (`vehicle_slots`, slot Base) has no component name of its own: it attaches
to the player appearance's component bound to that same slot with an identity transform
(`body_01` on every dealer car), which puts it in the same frame (inference, see
docs/research/vehicle-wave2-packs.md).

    python st_survey.py --json-dir <dir> --out <stickers-dealer-2.50.json>
"""
from __future__ import annotations

import argparse
import json
import math
import os
import re
import sys
from collections import OrderedDict
from pathlib import Path

HERE = Path(__file__).resolve().parent
REPO = HERE.parents[2]
sys.path.insert(0, str(HERE.parent / "inventory"))
import cr2w_json as cj  # noqa: E402

DEALER = REPO / "docs" / "generated" / "vehicle-components-dealer-2.50.json"
SCHEMA = "open77.vehicle-stickers-survey/1"
STICKER_MESH = re.compile(r"sticker|decal|graffit", re.I)
NOT_STICKER = re.compile(r"shadow", re.I)
MESH_TYPES = ("entMeshComponent", "entPhysicalMeshComponent")
INTERIOR = re.compile(r"(^|_)int\d*(_|$)|__int|interior|glove_box|steering|dashboard|seat", re.I)
FIXED_POINT = 131072.0   # WorldPosition FixedPoint: Bits / 2^17 metres
FULL_CHUNK_MASK = "18446744073709551615"
# Parts that come off, open apart from the body or hide (damage, LOD, fx): never a decal host.
DETACHABLE = re.compile(r"bumper|door|hood|trunk|window|wiper|mirror|light|exhaust|fx|cutout|fuel|junk|bags|mount", re.I)


class SurveyError(Exception):
    pass


def flat(depot: str) -> str:
    return depot.replace("\\", "~")


def transform(c: dict) -> OrderedDict:
    lt = c.get("localTransform") or {}
    pos = lt.get("Position") or {}
    ori = lt.get("Orientation") or {}
    p = [int(((pos.get(a) or {}).get("Bits")) or 0) for a in "xyz"]
    q = [float(ori.get(a, 0.0 if a != "r" else 1.0)) for a in "ijkr"]
    return OrderedDict([("positionBits", p), ("orientation", [round(x, 6) for x in q])])


def is_identity(t: dict) -> bool:
    i, j, k, r = t["orientation"]
    return t["positionBits"] == [0, 0, 0] and abs(i) < 1e-6 and abs(j) < 1e-6 and abs(k) < 1e-6 and abs(abs(r) - 1) < 1e-6


def scale(c: dict) -> list[float]:
    vs = c.get("visualScale") or {}
    return [float(vs.get(a, 1)) for a in "XYZ"]


def chunk_mask(c: dict) -> str:
    v = c.get("chunkMask")
    return str(v) if v is not None else FULL_CHUNK_MASK


def appearance_components(doc: cj.Doc) -> dict[str, list[dict]]:
    out = {}
    for h in doc.root.get("appearances") or []:
        a = doc.deref(h)
        if not isinstance(a, dict):
            continue
        out[str(cj.val(a.get("name")))] = [c for c in cj.component_list(doc, a)]
    return out


def describe(doc: cj.Doc, c: dict) -> OrderedDict:
    b = cj.binding(doc, c) or {}
    return OrderedDict([
        ("component", str(cj.val(c.get("name")))),
        ("type", c.get("$type")),
        ("mesh", cj.val(c.get("mesh")) or ""),
        ("meshAppearance", str(cj.val(c.get("meshAppearance")) or "default")),
        ("chunkMask", chunk_mask(c)),
        ("transform", transform(c)),
        ("visualScale", scale(c)),
        ("bind", OrderedDict([("name", b.get("bindName") or ""), ("slot", b.get("slotName") or ""),
                              ("type", b.get("type") or "")])),
        ("enabled", int(c.get("isEnabled", 1) or 0)),
    ])


def is_sticker(d: dict) -> bool:
    mesh = d["mesh"]
    return (d["type"] in MESH_TYPES and bool(mesh) and STICKER_MESH.search(os.path.basename(mesh)) is not None
            and NOT_STICKER.search(os.path.basename(mesh)) is None)


def key_of(d: dict) -> str:
    return json.dumps([d["component"], d["mesh"], d["meshAppearance"], d["chunkMask"], d["transform"],
                       d["visualScale"], d["bind"]], sort_keys=True)


def slot_host(cands: list[str]) -> str | None:
    """The slot-bound component a decal should hang on: the body shell first (body_01, then any
    *body* part), never a part that comes off or hides (bumper, door, window, wiper, mirror, light,
    exhaust, fx). None when nothing rigid is left."""
    if "body_01" in cands:
        return "body_01"
    bodies = [c for c in cands if re.search(r"body", c, re.I) and not DETACHABLE.search(c)]
    if bodies:
        return bodies[0]
    rigid = [c for c in cands if not DETACHABLE.search(c) and not re.search(r"interior|engine", c, re.I)]
    return rigid[0] if rigid else None


def resolve_attach(bind: dict, player: dict[str, dict]) -> OrderedDict:
    """Where a sticker bound to `bind` hangs in the player appearance (component name or none)."""
    name, slot = bind["name"], bind["slot"]
    if name and name in player and player[name]["type"] in MESH_TYPES:
        return OrderedDict([("component", name), ("how", "direct"),
                            ("note", "the player appearance has the panel the sticker is bound to")])
    if name == "vehicle_slots" and slot:
        cands = sorted(n for n, d in player.items()
                       if d["type"] in MESH_TYPES and d["bind"]["name"] == "vehicle_slots" and d["bind"]["slot"] == slot
                       and is_identity(d["transform"]) and d["visualScale"] == [1.0, 1.0, 1.0]
                       and not is_sticker(d) and d["enabled"])
        pick = slot_host(cands)
        if pick:
            return OrderedDict([("component", pick), ("how", "slot"),
                                ("note", f"bound to vehicle_slots/{slot}; {pick} is bound to the same slot with an identity transform"),
                                ("candidates", cands)])
        return OrderedDict([("component", None), ("how", "none"),
                            ("note", f"no player-appearance mesh component on vehicle_slots/{slot} with an identity transform")])
    return OrderedDict([("component", None), ("how", "none"),
                        ("note", f"the player appearance has no mesh component named {name or '(empty)'}")])


def survey_model(m: dict, json_dir: Path) -> OrderedDict:
    pdocs, apps = {}, {}
    for af in m["appFiles"]:
        p = json_dir / (flat(af["path"]) + ".json")
        if not p.exists():
            raise SurveyError(f"{m['key']}: {af['path']} was not serialized ({p})")
        pdocs[af["path"]] = cj.Doc(str(p))
        apps[af["path"]] = appearance_components(pdocs[af["path"]])
    by_full = {a["name"]: a for a in m["appearances"]}
    pa = by_full.get(m["playerAppearance"])
    if not pa or pa.get("app") not in apps:
        raise SurveyError(f"{m['key']}: player appearance {m['playerAppearance']} not found in its .app files")
    pdoc = pdocs[pa["app"]]
    player_list = apps[pa["app"]].get(pa["appearanceName"])
    if player_list is None:
        raise SurveyError(f"{m['key']}: appearance {pa['appearanceName']} missing from {pa['app']}")
    player = OrderedDict()
    for c in player_list:
        d = describe(pdoc, c)
        player[d["component"]] = d
    player_keys = {key_of(d) for d in player.values() if is_sticker(d)}

    rows: dict[str, OrderedDict] = {}
    for full, a in sorted(by_full.items()):
        app_path = a.get("app")
        if app_path not in apps:
            continue
        comps = apps[app_path].get(a["appearanceName"]) or []
        doc = pdocs[app_path]
        for c in comps:
            d = describe(doc, c)
            if not is_sticker(d):
                continue
            k = key_of(d)
            row = rows.get(k)
            if row is None:
                row = rows[k] = d
                row["appearances"] = []
            row["appearances"].append(full)
    stickers = []
    binds = OrderedDict()
    for k, row in sorted(rows.items(), key=lambda kv: (kv[1]["mesh"], kv[1]["component"], kv[0])):
        b = row["bind"]
        bkey = f"{b['name']}/{b['slot']}" if b["slot"] else b["name"]
        if bkey not in binds:
            binds[bkey] = resolve_attach(b, player)
        row["interior"] = bool(INTERIOR.search(row["component"]) or INTERIOR.search(os.path.basename(row["mesh"]))
                               or INTERIOR.search(b["name"]))
        row["inPlayerAppearance"] = k in player_keys
        row["identityTransform"] = is_identity(row["transform"])
        row["archive"] = "ep1" if row["mesh"].lower().startswith("ep1\\") else "base"
        row["attach"] = binds[bkey]["component"]
        row["attachHow"] = binds[bkey]["how"]
        stickers.append(row)
    return OrderedDict([
        ("key", m["key"]), ("record", m["record"]), ("playerAppearance", m["playerAppearance"]),
        ("appFiles", [af["path"] for af in m["appFiles"]]),
        ("attach", binds), ("stickers", stickers),
    ])


def survey(json_dir: Path, dealer_path: Path = DEALER) -> OrderedDict:
    dealer = json.loads(dealer_path.read_text(encoding="utf-8"))
    models = [survey_model(m, json_dir) for m in dealer["models"]]
    return OrderedDict([
        ("schema", SCHEMA),
        ("generatedBy", "scripts/vehicle-kit/stickers/st_survey.py (through build-stickers.ps1 -UpdateData)"),
        ("gameVersion", dealer.get("gameVersion", "2.50")),
        ("source", "docs/generated/vehicle-components-dealer-2.50.json + the dealer .app files serialized by WolvenKit"),
        ("note", "Depot paths, component names and transforms only: no game data. A sticker row is one distinct "
                 "component (mesh, meshAppearance, chunkMask, transform, binding) and the vanilla appearances that "
                 "carry it; `attach` is the component of the PLAYER appearance a VehicleDecalAttachment would use."),
        ("models", models),
    ])


def app_paths(dealer_path: Path = DEALER) -> list[str]:
    dealer = json.loads(dealer_path.read_text(encoding="utf-8"))
    return sorted({af["path"] for m in dealer["models"] for af in m["appFiles"]})


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("--json-dir", help="serialized .app files (flat names)")
    ap.add_argument("--out", help="write the survey JSON here")
    ap.add_argument("--list-apps", action="store_true", help="print the .app depot paths to extract, one per line")
    a = ap.parse_args(argv)
    try:
        if a.list_apps:
            print("\n".join(app_paths()))
            return 0
        if not a.json_dir or not a.out:
            ap.error("--json-dir and --out are required")
        doc = survey(Path(a.json_dir))
        Path(a.out).parent.mkdir(parents=True, exist_ok=True)
        Path(a.out).write_text(json.dumps(doc, indent=1, ensure_ascii=False) + "\n", encoding="utf-8", newline="\n")
        n = sum(len(m["stickers"]) for m in doc["models"])
        ext = sum(1 for m in doc["models"] for s in m["stickers"] if not s["interior"])
        print(f"ST_SURVEY_OK models={len(doc['models'])} stickers={n} exterior={ext} out={a.out}")
        return 0
    except (SurveyError, OSError, KeyError) as e:
        print(f"st_survey: {e}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
