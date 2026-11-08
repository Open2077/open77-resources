"""Component inventory of every vanilla player car (offline, from the game files).

The body kit started on the Light RP dealership cars (dealer_components.py). This script
widens the same inventory to every `gamedataVehicle_Record` of the installed game whose
name matches `Vehicle.*_player*` and whose vehicle type is a car: bikes are listed and
skipped (the kit is car parts), panzers and AVs are excluded, and so are the quest
variants of a player car (`Vehicle.q<digits>_*`, owner decision).

Records that share an entity template AND the same exterior (the component name + mesh
set of their own appearance, the set body_measure.py assembles) are one body: they get
one key and one measurement, and the fit table repeats the fit for each of their
records. A record whose appearance changes the exterior (a GT trim with its own bumpers
or wing, a nomad build) is its own body, even on a shared entity.

Dealer models already in --base (docs/generated/vehicle-components-dealer-<ver>.json)
are copied verbatim, so the 14 measured cars keep byte-identical inputs; their sibling
records with the same exterior are added to their `records`.

Writes metadata only, OUTSIDE the repository (refused inside it): one JSON with the same
model shape as the dealer inventory (body_measure.py --dealer reads it) plus `records`
and `bodyGroup` per model, and a `records` table for every candidate record.

Usage (repository root):
    python -I scripts/vehicle-kit/inventory/player_body_components.py --game <install> \\
        --names <tweakdbstr.kark> --cache <scratch> --scratch <scratch>/extract \\
        --base docs/generated/vehicle-components-dealer-2.50.json --out <scratch>/vehicle-body-components-player-2.50.json
"""
from __future__ import annotations

import argparse
import json
import os
import re
import sys
from collections import OrderedDict

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import cr2w_json as cj  # noqa: E402
import dealer_components as dc  # noqa: E402
import tdb  # noqa: E402
import vehicle_inventory as vi  # noqa: E402

PATTERN = r"^Vehicle\.[A-Za-z0-9_]*_player"
# Quest variants of a player car (Vehicle.q000_hym_player_car, Vehicle.q304_songbird_escape_player)
# are out of the kit by the owner's decision (2026-11-07): never a sibling record of a body.
QUEST = re.compile(r"^Vehicle\.q\d+_")
CLASS_PREFIX = re.compile(r"^v_(sport\d|standard\d+|utility\d|sportbike\d)_")
MAKERS = ("archer", "quadra", "mizutani", "thorton", "villefort", "chevalier", "makigai", "mahir", "herrera",
          "rayfield", "yaiba", "porsche", "militech", "brennan", "arch")
# Flags body_measure.py leaves out of the exterior it assembles (kept in step with SKIP_FLAGS).
SKIP_FLAGS = {"placeable", "shadow", "decal", "part:interior", "wheel", "tire", "rim", "part:chassis", "widget"}


def short_key(record: str) -> str:
    """Vehicle.v_sport2_quadra_type66_avenger_player -> type66_avenger."""
    name = record.split(".", 1)[1]
    name = CLASS_PREFIX.sub("", name)
    tokens = [t for t in name.split("_") if t]
    if tokens and tokens[0] in MAKERS:
        tokens = tokens[1:]
    tokens = [t for t in tokens if t != "player"]
    return "_".join(tokens) or name


def exterior_signature(model: dict) -> tuple:
    """The (name, mesh) set body_measure.py assembles for this model's player appearance."""
    rows = []
    for c in model.get("components", []):
        if not c.get("inPlayerAppearance") or not c.get("mesh"):
            continue
        flags = set(c.get("flags") or [])
        if c["type"] == "entAppearanceProxyMeshComponent":
            continue
        if flags & SKIP_FLAGS or "__int01" in c["mesh"] or c["type"] == "entSkinnedMeshComponent":
            continue
        rows.append((c["name"], c["mesh"].lower()))
    return tuple(sorted(rows))


def label_of(row: dict, key: str) -> str:
    maker = row["manufacturer"] or ""
    # A key word that repeats the maker is dropped (cortes_delamain by Delamain -> "Delamain Cortes").
    made = {w.lower() for w in maker.split()}
    words = [w for w in key.split("_") if w and w.lower() not in made] or [w for w in key.split("_") if w]
    pretty = []
    for w in words:
        if re.match(r"^\d+$", w):
            pretty.append(w)
        elif w in ("gt", "ncu", "bmf"):
            pretty.append(w.upper())
        else:
            pretty.append(w.capitalize())
    return (maker + " " + " ".join(pretty)).strip()


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--game", default=os.environ.get("OP77_GAME_DIR"))
    ap.add_argument("--names", required=True, help="WolvenKit tweakdbstr.kark")
    ap.add_argument("--vehicles-txt", help="optional list of known Vehicle.* names (vehicles.txt)")
    ap.add_argument("--cache", required=True, help="scratch dir for archive listings / names")
    ap.add_argument("--scratch", required=True, help="scratch dir for extracted files (outside any repo)")
    ap.add_argument("--base", required=True, help="dealer inventory JSON whose models are kept verbatim")
    ap.add_argument("--out", required=True, help="output JSON (outside the repository)")
    ap.add_argument("--pattern", default=PATTERN)
    ap.add_argument("--cp77tools", default=vi.DEFAULT_CP77TOOLS)
    ap.add_argument("--version", default="2.50")
    a = ap.parse_args(argv)
    if not a.game:
        ap.error("--game or OP77_GAME_DIR is required")
    repo = os.path.abspath(os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", ".."))
    for p in (a.scratch, a.cache, a.out):
        if os.path.abspath(p).lower().startswith(repo.lower()):
            ap.error(f"{p} is inside the repository; extracted game data must stay outside it")

    ctx = vi.open_context(a.game, a.names, a.cache, a.cp77tools)
    index = cj.archive_index(os.path.join(a.cache, "archive-lists"))
    listed = vi.read_listed(a.vehicles_txt)
    rx = re.compile(a.pattern)
    rows = []
    for rid in vi.vehicle_record_ids(ctx, listed):
        name = ctx.name(rid)
        if rx.match(name):
            rows.append(vi.vehicle_row(ctx, rid, listed))
    base = json.load(open(a.base, encoding="utf-8"))
    base_by_record = {m["record"]: m for m in base["models"]}

    table, kept = [], []
    for r in sorted(rows, key=lambda r: r["record"]):
        entry = {"record": r["record"], "vehicleType": r["vehicleType"], "entity": r["entityTemplatePath"],
                 "appearanceName": r["appearanceName"]}
        ent = (r["entityTemplatePath"] or "").lower()
        if QUEST.match(r["record"]):
            entry["skipped"] = "quest variant record: excluded from the kit"
        elif not ent:
            entry["skipped"] = "no entity template"
        elif r["vehicleType"] == "Bike":
            entry["skipped"] = "bike: the body kit is car parts"
        elif r["vehicleType"] == "Panzer" or "\\av\\" in ent or "_av_" in ent:
            entry["skipped"] = f"{r['vehicleType'] or 'AV'}: excluded from the kit"
        elif r["vehicleType"] != "Car":
            entry["skipped"] = f"vehicle type {r['vehicleType']!r}"
        else:
            kept.append(r)
        table.append(entry)
    print(f"{len(rows)} records match {a.pattern}: {len(kept)} cars, "
          f"{sum(1 for t in table if 'skipped' in t)} skipped", flush=True)

    models: "OrderedDict[str, dict]" = OrderedDict()   # key -> model
    sigs: dict[tuple, str] = {}                          # (entity, signature) -> key
    for m in base["models"]:
        if m["tweakdb"]["vehicleType"] == "Bike":
            continue
        mm = dict(m)
        mm["records"] = [m["record"]]
        mm["bodyGroup"] = "dealer"
        models[m["key"]] = mm
        sigs[(m["entity"]["path"].lower(), exterior_signature(m))] = m["key"]
    analysed: dict[str, dict] = {}
    for r in kept:
        rec = r["record"]
        if rec in base_by_record:
            continue
        key = short_key(rec)
        print(f"{key}: {rec}", flush=True)
        entry = {"key": key, "label": label_of(r, key), "category": "", "price": None, "record": rec,
                 "publicStock": False, "staffOnly": False}
        m = dc.analyse_model(entry, ctx, a.game, a.cp77tools, a.scratch, index)
        m["publicStock"] = False
        m.pop("staffOnly", None)
        analysed[rec] = m
    # Group: an existing body with the same exterior first, else the first record seen.
    for rec in sorted(analysed, key=lambda x: (len(x), x)):
        m = analysed[rec]
        if not m.get("components"):
            for t in table:
                if t["record"] == rec:
                    t["skipped"] = "entity or appearance not extracted"
            continue
        sig = (m["entity"]["path"].lower(), exterior_signature(m))
        key = sigs.get(sig)
        if key is not None:
            models[key]["records"].append(rec)
            continue
        key = m["key"]
        n = 2
        while key in models:
            key = f"{m['key']}_{n}"
            n += 1
        m["key"] = key
        m["records"] = [rec]
        m["bodyGroup"] = "player"
        models[key] = m
        sigs[sig] = key
    rec_key = {rec: k for k, m in models.items() for rec in m["records"]}
    for t in table:
        if t["record"] in rec_key:
            t["key"] = rec_key[t["record"]]
    for m in models.values():
        m["records"] = sorted(m["records"], key=lambda x: (x != m["record"], x))

    doc = OrderedDict()
    doc["generatedBy"] = "scripts/vehicle-kit/inventory/player_body_components.py"
    doc["gameVersion"] = a.version
    doc["source"] = "r6/cache/tweakdb.bin + tweakdb_ep1.bin; .ent/.app serialized with WolvenKit CLI"
    doc["pattern"] = a.pattern
    doc["records"] = table
    doc["models"] = list(models.values())
    os.makedirs(os.path.dirname(os.path.abspath(a.out)), exist_ok=True)
    with open(a.out, "w", encoding="utf-8", newline="\n") as fh:
        json.dump(doc, fh, indent=1, ensure_ascii=False)
        fh.write("\n")
    print(f"bodies: {len(models)} ({sum(1 for m in models.values() if m['bodyGroup'] == 'player')} new); "
          f"records on them: {sum(len(m['records']) for m in models.values())}")
    for k, m in models.items():
        print(f"  {k:24} {m['playerAppearance']:48} {' '.join(r.split('.', 1)[1] for r in m['records'])}")
    print(f"wrote {a.out}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
