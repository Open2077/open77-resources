"""Which vanilla player vehicles the customization content covers, grouped by body (offline).

    python -I scripts/vehicle-kit/inventory/player_scope.py --game <install> \
        --names <tweakdbstr.kark or .bin> --cache <scratch> [--vehicles-txt vehicles.txt]

Reads r6/cache/tweakdb.bin + tweakdb_ep1.bin (tdb.py, ep1 layered on top) of the INSTALLED game
and writes docs/generated/vehicle-player-scope-<ver>.json (metadata only, no game data):

  * every gamedataVehicle_Record whose name matches `Vehicle.*_player*` (names from WolvenKit's
    string table and vehicles.txt; the record must exist in this game's TweakDB);
  * out of scope: any vehicleType other than Car and Bike (AVs, tanks), the panzer class
    (Militech Basilisk), quest variants (records named `Vehicle.q<digits>_*`, such as
    Vehicle.q000_hym_player_car or Vehicle.q304_songbird_escape_player: the owner's call, they
    are neither bodies of their own nor trims of a dealer body), and records without an entity
    template; each is listed in `excluded` with its reason;
  * bodies: the records left, grouped by entity template (.ent): the trims of one body share its
    geometry and differ by entity appearance (`appearanceName`). One record per body is its
    `primary`: the Light RP catalogue record when there is one, else the record whose appearance
    is a `*_player_01` / `*basic_player*` one with visual customization, else the first by name.
  * keys: the Light RP catalogue key when the primary is in the catalogue (hella, galena, ...;
    these keys are load-bearing: sticker ids `os.<key>.<theme>` are saved on players' cars), else
    a short key derived from the record (manufacturer dropped, `_player` dropped). A key never
    contains a word the server's sticker catalogue refuses (police, ncpd, sheriff, border patrol,
    arasaka, delamain).

Never writes in the game folder.
"""
from __future__ import annotations

import argparse
import json
import os
import re
import sys
from collections import OrderedDict

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import tdb  # noqa: E402
import vehicle_inventory as vi  # noqa: E402

PLAYER = re.compile(r"^Vehicle\..*_player")
PANZER = re.compile(r"basilisk|panzer", re.I)
# Quest variants (Vehicle.q000_hym_player_car, Vehicle.q304_songbird_escape_player): out of the
# whole customization extension by the owner's decision, even when they share a dealer body.
QUEST = re.compile(r"^Vehicle\.q\d+_")
# VehicleStickerCatalogue.ExcludedPattern (server): an id with one of these is refused.
EXCLUDED = re.compile(r"police|ncpd|sheriff|border[\s_.-]*patrol|arasaka|delamain", re.I)
# Light RP catalogue keys (resources/gamemodes/op77_lightrp/shared/config.lua, vehicles.catalog):
# the dealer stock, the Caliburn and the two staff-only sports cars. Fixed: ids are saved.
CATALOGUE = OrderedDict([
    ("hella", "Vehicle.v_standard2_archer_hella_player"),
    ("bandit", "Vehicle.v_standard2_archer_bandit_player"),
    ("quartz", "Vehicle.v_standard2_archer_quartz_player"),
    ("cortes", "Vehicle.v_standard2_villefort_cortes_player"),
    ("colby", "Vehicle.v_standard2_thorton_colby_player"),
    ("galena", "Vehicle.v_standard2_thorton_galena_player"),
    ("maimai", "Vehicle.v_standard2_makigai_maimai_player"),
    ("hozuki", "Vehicle.v_standard2_mizutani_hozuki_player"),
    ("thrax", "Vehicle.v_standard2_chevalier_thrax_player"),
    ("supron", "Vehicle.v_standard25_mahir_supron_player"),
    ("columbus", "Vehicle.v_standard25_villefort_columbus_player"),
    ("merrimac", "Vehicle.v_standard25_thorton_merrimac_player"),
    ("semimaru", "Vehicle.v_sport1_yaiba_semimaru_player"),
    ("kusanagi", "Vehicle.v_sportbike1_yaiba_kusanagi_player"),
    ("apollo", "Vehicle.v_sportbike3_brennan_apollo_player"),
    ("type66", "Vehicle.v_sport2_quadra_type66_player"),
    ("shion", "Vehicle.v_sport2_mizutani_shion_player"),
    ("caliburn", "Vehicle.v_sport1_rayfield_caliburn_player"),
])
# Readable keys where the derived one is not (fixed once published, like the catalogue keys).
KEY_OVERRIDES = {
    "Vehicle.v_sportbike2_arch_player": "nazare",
    "Vehicle.v_sportbike2_arch_linas_player": "nazare_linas",
    "Vehicle.v_standard2_villefort_cortes_delamain_player": "cortes_cab",
}
MAKERS = ("archer", "chevalier", "herrera", "mahir", "makigai", "militech", "mizutani", "quadra", "rayfield",
          "thorton", "villefort", "yaiba", "brennan", "arch", "porsche")


def derived_key(record: str) -> str:
    """Vehicle.v_standard2_thorton_galena_nomad_player_missiles -> galena_nomad_missiles."""
    s = record.split(".", 1)[1]
    s = re.sub(r"^(v_[a-z]+\d*_|q\d+_)", "", s)
    parts = [p for p in s.split("_") if p and p != "player"]
    if parts and parts[0] in MAKERS:
        parts = parts[1:]
    key = "_".join(parts) or s
    key = re.sub(r"[^a-z0-9_]", "", key.lower())
    return EXCLUDED.sub("x", key)


def primary_score(row: dict, catalogue_records: set[str]) -> tuple:
    app = row["appearanceName"] or ""
    return (row["record"] not in catalogue_records,
            not re.search(r"(_player_01$|basic_player)", app),
            not row["hasVisualCustomization"],
            len(row["record"]), row["record"])


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--game", default=os.environ.get("OP77_GAME_DIR"))
    ap.add_argument("--names", required=True, help="WolvenKit tweakdbstr.kark (or its decompressed .bin)")
    ap.add_argument("--cache", required=True, help="scratch dir for archive listings (outside the repo)")
    ap.add_argument("--vehicles-txt", help="optional list of known Vehicle.* names (vehicles.txt)")
    ap.add_argument("--cp77tools", default=vi.DEFAULT_CP77TOOLS)
    ap.add_argument("--version", default="2.50")
    ap.add_argument("--out", default=None)
    a = ap.parse_args(argv)
    if not a.game:
        ap.error("--game or OP77_GAME_DIR is required")
    repo = os.path.abspath(os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", ".."))
    if os.path.abspath(a.cache).lower().startswith(repo.lower()):
        ap.error("--cache must stay outside the repository")
    out = a.out or os.path.join(repo, "docs", "generated", f"vehicle-player-scope-{a.version}.json")

    ctx = vi.open_context(a.game, a.names, a.cache, a.cp77tools)
    listed = vi.read_listed(a.vehicles_txt)
    ids = vi.vehicle_record_ids(ctx, listed)
    names = [ctx.name(r) for r in ids]
    candidates = [r for r, n in zip(ids, names) if PLAYER.match(n)]
    listed_player = sorted(n for n in listed if PLAYER.match(n))
    rows, excluded = [], []
    for rid in candidates:
        row = vi.vehicle_row(ctx, rid, listed)
        why = None
        if row["vehicleType"] not in ("Car", "Bike"):
            why = f"vehicleType {row['vehicleType'] or '-'} (only Car and Bike are in scope)"
        elif PANZER.search(row["record"]) or PANZER.search(row["entityTemplatePath"] or ""):
            why = "panzer class"
        elif QUEST.match(row["record"]):
            why = "quest variant (Vehicle.q<digits>_*), excluded by the owner"
        elif not row["entityTemplatePath"]:
            why = "no entity template"
        if why:
            excluded.append(OrderedDict([("record", row["record"]), ("reason", why)]))
        else:
            rows.append(row)

    catalogue_records = set(CATALOGUE.values())
    key_of_record = {v: k for k, v in CATALOGUE.items()}
    bodies: "OrderedDict[str, list[dict]]" = OrderedDict()
    for row in sorted(rows, key=lambda r: r["record"]):
        bodies.setdefault(row["entityTemplatePath"].lower(), []).append(row)
    out_bodies, used = [], set()
    for ent, members in bodies.items():
        members.sort(key=lambda r: primary_score(r, catalogue_records))
        primary = members[0]
        key = key_of_record.get(primary["record"]) or KEY_OVERRIDES.get(primary["record"]) or derived_key(primary["record"])
        if EXCLUDED.search(key):
            raise SystemExit(f"player_scope: key {key} carries a word the sticker catalogue refuses")
        base, n = key, 2
        while key in used:
            key, n = f"{base}{n}", n + 1
        used.add(key)
        out_bodies.append(OrderedDict([
            ("key", key),
            ("primary", primary["record"]),
            ("vehicleType", primary["vehicleType"]),
            ("entity", primary["entityTemplatePath"]),
            ("inLightRpCatalogue", primary["record"] in catalogue_records),
            ("records", [OrderedDict([
                ("record", r["record"]),
                ("appearance", r["appearanceName"] if r["appearanceName"] not in ("", "None") else ""),
                ("hasVisualCustomization", r["hasVisualCustomization"]),
                ("hasUniqueCustomization", r["hasUniqueCustomization"]),
                ("twintoneModelName", r["twintoneModelName"] if r["twintoneModelName"] not in ("", "None") else ""),
                ("customizableAppearance", r["customizableAppearance"] if r["customizableAppearance"] not in ("", "None") else ""),
                ("uniqueTemplates", sum(1 for p in json.loads(r["profiles"]) if p.get("pattern"))),
                ("profiles", r["profileCount"]),
            ]) for r in members]),
        ]))
    out_bodies.sort(key=lambda b: (not b["inLightRpCatalogue"], b["key"]))
    found = {ctx.name(r) for r in candidates}
    doc = OrderedDict([
        ("generatedBy", "scripts/vehicle-kit/inventory/player_scope.py"),
        ("gameVersion", a.version),
        ("source", "r6/cache/tweakdb.bin + tweakdb_ep1.bin of the installed game (tdb.py)"),
        ("rule", "Vehicle.*_player* records, Car and Bike only, no panzer, no quest variant (Vehicle.q<digits>_*), "
                 "with an entity template; grouped by entity"),
        ("counts", OrderedDict([
            ("vehicleRecords", len(ids)),
            ("playerRecords", len(candidates)),
            ("inScope", len(rows)),
            ("excluded", len(excluded)),
            ("bodies", len(out_bodies)),
            ("vehiclesTxtPlayerNames", len(listed_player)),
        ])),
        ("vehiclesTxtNotInThisGame", [n for n in listed_player if n not in found]),
        ("notInVehiclesTxt", sorted(n for n in found if n not in listed)),
        ("excluded", excluded),
        ("bodies", out_bodies),
    ])
    os.makedirs(os.path.dirname(out), exist_ok=True)
    with open(out, "w", encoding="utf-8", newline="\n") as fh:
        json.dump(doc, fh, indent=1, ensure_ascii=False)
        fh.write("\n")
    print(json.dumps(doc["counts"]))
    for b in out_bodies:
        print(f"{b['key']:22} {b['vehicleType']:4} {len(b['records'])} {b['primary']}")
    print(f"excluded: {[(e['record'], e['reason']) for e in excluded]}")
    print(f"vehicles.txt names missing from this game: {doc['vehiclesTxtNotInThisGame']}")
    print(f"player records not in vehicles.txt: {doc['notInVehiclesTxt']}")
    print(f"PLAYER_SCOPE_OK wrote {out}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
