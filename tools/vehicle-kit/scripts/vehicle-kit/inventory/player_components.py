"""Wheel and plate components of every vanilla player vehicle, per entity appearance (offline).

Scope: every gamedataVehicle_Record named Vehicle.*_player* in the installed TweakDB (base +
EP1), cars and motorcycles; AVs and the panzer class are excluded (none carries a _player
name in 2.50, the filter stays for later builds). Quest variants, records named
Vehicle.q<digits>_* (2.50: Vehicle.q000_hym_player_car, Vehicle.q304_songbird_escape_player),
are left out of the whole customization extension by the owner's decision of 2026-11-07:
they are listed under `excludedRecords` with that reason, never analysed, so no rim fit,
plate model or Light RP data is built for them. Records the string table cannot name are
listed under `unnamed` with their entity, never guessed.

For each record (dealer_components.analyse_model does the TweakDB + .ent + .app reading):

  * the player appearance (TweakDB appearanceName, else the entity default) and every
    entity appearance with its .app definition;
  * per appearance, the wheel components the rim fit works on (measure-wheels.ps1 rule:
    rim, tyre, and any other mesh bound to a wheel / brake / axle slot; shadows skipped)
    and the plate components; identical wheel sets are written once (`wheelSets`) and
    referenced by id;
  * `bodies`: records sharing one entity template and .app set, the unit the rim and
    plate packs work on.

Writes metadata only: docs/generated/vehicle-components-player-<ver>.json and .md. With
--measure-plan, also writes (outside the repository) the input of measure-wheels.ps1 -Dealer:
one model per distinct (entity, .app, definition) wheel variant, keyed `v<n>`, with the
records and entity appearances it stands for in `variantOf`.

Usage (repository root):
    python -I scripts/vehicle-kit/inventory/player_components.py --game <install> \
        --names <tweakdbstr.bin|kark> --cache <scratch> --scratch <scratch>/extract \
        [--vehicles-txt <vehicles.txt>] [--measure-plan <scratch>/player-dealer.json]
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import sys
from collections import Counter, OrderedDict

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import cr2w_json as cj  # noqa: E402
import dealer_components as dc  # noqa: E402
import vehicle_inventory as vi  # noqa: E402

PLAYER = re.compile(r"^Vehicle\..*_player", re.I)
EXCLUDED_TYPES = {"AV", "Tank"}  # vehicleType enum names; panzer records are Tank
# Quest variants of a player vehicle (owner's decision, 2026-11-07): out of the extension.
QUEST = re.compile(r"^Vehicle\.q\d+_")
QUEST_REASON = ("quest variant (Vehicle.q<digits>_*): left out of the customization extension "
                "by the owner's decision of 2026-11-07")
EMPTY_CTX = {"decal_targets": set(), "multilayer_targets": set(), "excluded_custom": set(),
             "excluded_generic": set(), "wheel_components": set()}


def key_of(record: str) -> str:
    return record.split(".", 1)[1]


def wheel_role(s: dict, flags: list[str]) -> str | None:
    """measure-wheels.ps1's selection: rim, tyre, or another mesh on a wheel/brake/axle slot."""
    if "shadow" in flags:
        return None
    slot = (s.get("parent") or {}).get("slotName") or ""
    if "rim" in flags:
        return "rim"
    if "tire" in flags:
        return "tire"
    if s.get("mesh") and re.match(r"^(wheel|brake|axle)", slot):
        return "other"
    return None


def per_appearance(model: dict, game: str, cp77tools: str, scratch: str, index: dict) -> tuple[dict, list]:
    """wheelSets (id -> components) and the appearance rows, from the cached .app JSON."""
    paths = sorted({a["app"] for a in model["appearances"] if a.get("app")})
    info = cj.extract(game, cp77tools, scratch, paths, index)
    docs: dict[str, cj.Doc | None] = {}
    sets: "OrderedDict[str, list]" = OrderedDict()
    by_sig: dict[str, str] = {}
    rows = []
    for a in model["appearances"]:
        row = OrderedDict(name=a["name"], appearanceName=a["appearanceName"], app=a["app"])
        p = (a["app"] or "").lower()
        if p not in docs:
            j = info.get(p, {}).get("json")
            docs[p] = cj.Doc(j) if j else None
        doc = docs[p]
        d = None
        if doc is not None:
            defs = [doc.deref(x) for x in doc.root.get("appearances") or []]
            d = next((x for x in defs if x and cj.val(x.get("name")) == a["appearanceName"]), None)
        if d is None:
            row["found"] = False
            rows.append(row)
            continue
        wheel, plate = [], []
        for c in cj.component_list(doc, d):
            s = dc.summarize_component(doc, c)
            flags = dc.flags_for(s["name"], s["type"], s.get("mesh", ""), s.get("parent"), EMPTY_CTX)
            role = wheel_role(s, flags)
            if role:
                wheel.append(OrderedDict(name=s["name"], role=role, mesh=s.get("mesh") or None,
                                         slot=(s.get("parent") or {}).get("slotName"),
                                         type=s["type"], flags=flags))
            if "plate" in flags and s["type"] != "WorldWidgetComponent":
                plate.append(OrderedDict(name=s["name"], type=s["type"], mesh=s.get("mesh") or None,
                                         slot=(s.get("parent") or {}).get("slotName")))
        wheel.sort(key=lambda c: (c["slot"] or "", c["role"], c["name"], c["mesh"] or ""))
        sig = json.dumps([[c["name"], c["role"], (c["mesh"] or "").lower(), c["slot"]] for c in wheel])
        if sig not in by_sig:
            by_sig[sig] = f"w{len(sets) + 1}"
            sets[by_sig[sig]] = wheel
        row["found"] = True
        row["wheelSet"] = by_sig[sig]
        row["rims"] = sorted({c["name"] for c in wheel if c["role"] == "rim"})
        row["plates"] = plate
        rows.append(row)
    return sets, rows


def compact(model: dict, sets: dict, rows: list, row_tdb: dict) -> dict:
    out = OrderedDict()
    out["key"] = model["key"]
    out["record"] = model["record"]
    out["displayName"] = row_tdb.get("displayName", "")
    out["vehicleType"] = model["tweakdb"]["vehicleType"]
    out["entity"] = model["entity"]["path"]
    out["entityArchive"] = model["entity"].get("archive")
    out["defaultAppearance"] = model["entity"].get("defaultAppearance")
    out["appearanceName"] = model["tweakdb"]["appearanceName"]
    out["playerAppearance"] = model.get("playerAppearance")
    out["playerAppearanceSource"] = model.get("playerAppearanceSource")
    out["apps"] = [a["path"] for a in model.get("appFiles", [])]
    out["wheelSlots"] = model.get("wheelSlots", [])
    out["wheels"] = model["wheels"]
    out["wheelSets"] = sets
    out["appearances"] = rows
    names_by_role: dict[str, set] = {}
    for comps in sets.values():
        for c in comps:
            names_by_role.setdefault(c["role"], set()).add(c["name"])
    rim_names = names_by_role.get("rim", set())
    clash = sorted(rim_names & (names_by_role.get("tire", set()) | names_by_role.get("other", set())))
    out["rimNames"] = sorted(rim_names)
    if clash:
        out["rimNameClash"] = clash  # a rim in one appearance, a tyre or other part in another
    return out


def body_key(m: dict) -> str:
    return m["entity"].lower() + "|" + ";".join(sorted(a.lower() for a in m["apps"]))


def measure_plan(models: list[dict], full: dict[str, dict]) -> dict:
    """measure-wheels.ps1 -Dealer input: one model per distinct (entity, app, definition)."""
    variants: "OrderedDict[str, dict]" = OrderedDict()
    for m in models:
        src = full[m["record"]]
        for a in m["appearances"]:
            if not a.get("found"):
                continue
            vkey = (m["entity"].lower(), (a["app"] or "").lower(), a["appearanceName"])
            v = variants.get(vkey)
            if v is None:
                comps = []
                for c in m["wheelSets"][a["wheelSet"]]:
                    comp = OrderedDict(name=c["name"], type=c["type"], flags=c["flags"], inPlayerAppearance=True)
                    if c["mesh"]:
                        comp["mesh"] = c["mesh"]
                    if c["slot"]:
                        comp["parent"] = {"slotName": c["slot"]}
                    comps.append(comp)
                v = OrderedDict(
                    key=f"v{len(variants) + 1}", label=f"{m['key']} / {a['name']}",
                    record=f"{m['record']}#{a['name']}", price=None, category="",
                    tweakdb={"vehicleType": m["vehicleType"]}, entity={"path": m["entity"]},
                    wheels=src["wheels"], wheelSlots=m["wheelSlots"],
                    appearances=[{"name": a["name"], "appearanceName": a["appearanceName"], "app": a["app"]}],
                    playerAppearance=a["name"], components=comps, variantOf=[])
                variants[vkey] = v
            v["variantOf"].append({"record": m["record"], "appearance": a["name"]})
    return {"generatedBy": "scripts/vehicle-kit/inventory/player_components.py --measure-plan",
            "gameVersion": None, "models": list(variants.values())}


def write_markdown(path: str, doc: dict) -> None:
    md = [f"# Wheel and plate components of the vanilla player vehicles (game {doc['gameVersion']})", "",
          "Generated by `scripts/vehicle-kit/inventory/player_components.py` from the local game files; do not edit by hand.",
          "Scope: every `Vehicle.*_player*` record of the installed TweakDB, cars and motorcycles, "
          "except quest variants (`Vehicle.q<digits>_*`, owner's decision of 2026-11-07). "
          "Wheel components follow `measure-wheels.ps1` (rim, tyre, other mesh on a wheel / brake / axle slot); "
          "a wheel set is one distinct list of them.", "",
          f"Records: {len(doc['models'])}; bodies (entity + .app set): {len(doc['bodies'])}; "
          f"quest variants left out: {len(doc['excludedRecords'])}; "
          f"unnamed vehicle records left out: {len(doc['unnamed'])}.", "",
          "| Record | Type | Player appearance | Appearances | Wheel sets | Rim names (all appearances) | Plate meshes |",
          "|---|---|---|---|---|---|---|"]
    for m in doc["models"]:
        found = [a for a in m["appearances"] if a.get("found")]
        plates = Counter(os.path.basename(p["mesh"]) for a in found for p in a["plates"] if p["mesh"])
        plate_txt = ", ".join(f"`{k}`" for k in sorted(plates)) or "none"
        rims = ", ".join(f"`{n}`" for n in m["rimNames"]) or "none"
        clash = f" (clash: {', '.join(m['rimNameClash'])})" if m.get("rimNameClash") else ""
        missing = len(m["appearances"]) - len(found)
        count = f"{len(found)}" + (f" (+{missing} missing)" if missing else "")
        md.append(f"| `{m['record']}` | {m['vehicleType']} | `{m['playerAppearance']}` | {count}"
                  f" | {len(m['wheelSets'])} | {rims}{clash} | {plate_txt} |")
    md += ["", "## Bodies", "", "| Entity | .app files | Records |", "|---|---|---|"]
    for b in doc["bodies"]:
        md.append(f"| `{os.path.basename(b['entity'])}` | {', '.join(f'`{os.path.basename(a)}`' for a in b['apps'])} | "
                  f"{', '.join(f'`{r}`' for r in b['records'])} |")
    if doc["excludedRecords"]:
        md += ["", "## Records left out", "", "| Record | Type | Entity | Reason |", "|---|---|---|---|"]
        for x in doc["excludedRecords"]:
            md.append(f"| `{x['record']}` | {x['vehicleType']} | `{x['entity']}` | {x['reason']} |")
    if doc["unnamed"]:
        md += ["", "## Unnamed vehicle records (string table has no name; scope cannot be decided)", "",
               "| Record id | Type | Entity | appearanceName |", "|---|---|---|---|"]
        for u in doc["unnamed"]:
            md.append(f"| `{u['recordId']}` | {u['vehicleType']} | `{u['entity']}` | `{u['appearanceName']}` |")
    with open(path, "w", encoding="utf-8", newline="\n") as fh:
        fh.write("\n".join(md) + "\n")


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--game", default=os.environ.get("OP77_GAME_DIR"))
    ap.add_argument("--names", required=True, help="WolvenKit tweakdbstr.kark (or its decompressed .bin)")
    ap.add_argument("--cache", required=True, help="scratch dir for archive listings / names")
    ap.add_argument("--scratch", required=True, help="scratch dir for extracted files (outside any repo)")
    ap.add_argument("--vehicles-txt", help="optional list of Vehicle.* names (fills string table holes)")
    ap.add_argument("--cp77tools", default=vi.DEFAULT_CP77TOOLS)
    ap.add_argument("--version", default="2.50")
    ap.add_argument("--only", default="", help="comma-separated record names (debug)")
    ap.add_argument("--measure-plan", help="also write the measure-wheels.ps1 -Dealer input here (outside the repo)")
    a = ap.parse_args(argv)
    repo = os.path.abspath(os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", ".."))
    for p in (a.scratch, a.cache) + ((a.measure_plan,) if a.measure_plan else ()):
        if os.path.abspath(p).lower().startswith(repo.lower()):
            ap.error(f"{p} is inside the repository; extracted game files must stay outside it")

    ctx = vi.open_context(a.game, a.names, a.cache, a.cp77tools)
    index = cj.archive_index(os.path.join(a.cache, "archive-lists"))
    listed = vi.read_listed(a.vehicles_txt)
    only = {x.strip() for x in a.only.split(",") if x.strip()}
    models, full, unnamed, excluded = [], {}, [], []
    for rid in vi.vehicle_record_ids(ctx, listed):
        name = ctx.name(rid)
        row = vi.vehicle_row(ctx, rid, listed)
        if name.startswith("<0x"):
            unnamed.append({"recordId": row["recordId"], "vehicleType": row["vehicleType"],
                            "entity": row["entityTemplatePath"], "appearanceName": row["appearanceName"]})
            continue
        if not PLAYER.match(name) or row["vehicleType"] in EXCLUDED_TYPES or (only and name not in only):
            continue
        if QUEST.match(name):
            excluded.append({"record": name, "vehicleType": row["vehicleType"],
                             "entity": row["entityTemplatePath"], "reason": QUEST_REASON})
            print(f"{name}: left out ({QUEST_REASON})", flush=True)
            continue
        print(f"{name}", flush=True)
        entry = {"key": key_of(name), "label": row["displayName"], "category": "", "price": None, "record": name}
        model = dc.analyse_model(entry, ctx, a.game, a.cp77tools, a.scratch, index)
        if model["entity"].get("error"):
            print(f"   entity not extracted: {model['entity']['path']}", flush=True)
            continue
        sets, rows = per_appearance(model, a.game, a.cp77tools, a.scratch, index)
        full[name] = model
        models.append(compact(model, sets, rows, row))

    bodies: "OrderedDict[str, dict]" = OrderedDict()
    for m in models:
        b = bodies.setdefault(body_key(m), {"entity": m["entity"], "apps": m["apps"], "records": []})
        b["records"].append(m["record"])
    doc = OrderedDict()
    doc["generatedBy"] = "scripts/vehicle-kit/inventory/player_components.py"
    doc["gameVersion"] = a.version
    doc["source"] = "r6/cache/tweakdb.bin + tweakdb_ep1.bin; .ent/.app serialized with WolvenKit CLI"
    doc["scope"] = "Vehicle.*_player* records, vehicleType Car or Bike, except quest variants (Vehicle.q<digits>_*)"
    doc["models"] = models
    doc["bodies"] = list(bodies.values())
    doc["excludedRecords"] = sorted(excluded, key=lambda x: x["record"])
    doc["unnamed"] = unnamed
    out_dir = os.path.join(repo, "docs", "generated")
    os.makedirs(out_dir, exist_ok=True)
    suffix = "" if not only else "-subset"
    jpath = os.path.join(out_dir, f"vehicle-components-player-{a.version}{suffix}.json")
    with open(jpath, "w", encoding="utf-8", newline="\n") as fh:
        json.dump(doc, fh, indent=1, ensure_ascii=False)
        fh.write("\n")
    mpath = os.path.join(out_dir, f"vehicle-components-player-{a.version}{suffix}.md")
    write_markdown(mpath, doc)
    print(f"wrote {jpath} ({len(models)} records, {len(bodies)} bodies, {len(excluded)} quest variants left out)\nwrote {mpath}")
    if a.measure_plan:
        plan = measure_plan(models, full)
        plan["gameVersion"] = a.version
        os.makedirs(os.path.dirname(os.path.abspath(a.measure_plan)), exist_ok=True)
        with open(a.measure_plan, "w", encoding="utf-8", newline="\n") as fh:
            json.dump(plan, fh, indent=1, ensure_ascii=False)
        digest = hashlib.sha256(open(a.measure_plan, "rb").read()).hexdigest()[:12]
        print(f"wrote {a.measure_plan} ({len(plan['models'])} wheel variants, sha256 {digest})")
    return 0


if __name__ == "__main__":
    sys.exit(main())
