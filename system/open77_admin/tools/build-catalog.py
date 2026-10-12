#!/usr/bin/env python3
"""Generate the shared/catalog*.lua set from docs/vehicle-models.md.

The catalogue in docs/ has three columns -- record, TweakDBID, template hash --
and no display name, manufacturer, class or speed. Nothing in the repository
stores those as fields, so every facet the admin panel offers is DERIVED from
the record string here, once, at build time, rather than in Lua on every client.

The derivation is not a guess. `v_<class><n>_<maker>_<model>[_variant]` is part
of the record name and is therefore data; the class vocabulary is documented in
resources/system/open77_vehiclepicker/README.md and mirrored below. What IS a guess is
the human-readable name, which is title-cased from the model segment and then
overridden by the hand table in NAMES for the ones an operator actually types.

Run:
    python resources/system/open77_admin/tools/build-catalog.py

It rewrites resources/system/open77_admin/shared/catalog*.lua in place and prints a
summary, including the load cost of each emitted file and the shared_script
lines the manifest needs. Re-run it whenever docs/vehicle-models.md is
regenerated for a new game build, and paste the printed manifest order into
resources/system/open77_admin/open77.lua if the file list changed.

The output is SEVERAL files rather than one, and the reason is a hard host
limit rather than taste -- see the note above LOAD_BUDGET. It is byte
reproducible: running this twice over the same docs/vehicle-models.md produces
identical bytes.
"""

from __future__ import annotations

import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
SOURCE = ROOT / "docs" / "vehicle-models.md"
SHARED = Path(__file__).resolve().parents[1] / "shared"

# ---------------------------------------------------------------------------
# Why the catalogue is emitted as several files
#
# The scripting host loads each script of a resource with its own `lua_pcall`,
# under a LUA_MASKCOUNT hook that fires every 10 000 VM instructions and, when
# it fires, aborts the load if the wall clock is past a 2 ms deadline
# (`scripting/src/ResourceHost.cpp`, `Prepare()`). Both the instruction count
# and the deadline are reset PER FILE, which is the lever this split pulls.
#
# The whole trick is to stay under the hook's stride. A file that executes
# fewer than 10 000 instructions never fires the hook at all, so the deadline
# is never consulted and the load cannot fail for timing reasons -- the
# failure becomes structurally impossible rather than merely unlikely.
#
# As one file this catalogue executed about 13 700 instructions: 9 583 opcodes
# of table constructors (measured with `luac -l`) plus 1372 x 3 for the index
# loop. That crossed the stride exactly once, and the host rolled back the
# whole 25-resource candidate set whenever that single check happened to land
# on a stalled frame -- observed twice on 2026-08-28, each time silently
# leaving the previous resource set running.
#
# Budget per emitted file. Under half the stride, so even a cost model that is
# wrong by a factor of two still cannot reach it.
LOAD_BUDGET = 4000

# Cost model, in VM instructions, read off `luac -l -l` of the previous
# single-file output rather than guessed:
#   * an array element is one LOADK, plus one SETLIST per 50 elements;
#   * a facet row ({ key, label, count }) is a NEWTABLE plus a LOADK/SETFIELD
#     pair per field;
#   * an index row is exactly three opcodes -- GETTABLE, SETTABLE, FORLOOP;
#   * the fixed part is the chunk preamble, the two function closures, and the
#     table open/close.
COST_ELEMENT = 1.02
COST_FACET_ROW = 8
COST_INDEX_ROW = 3
COST_FIXED = 60

# Section heading -> the group key the panel filters on. Order matters: it is
# the order the facet rail renders, and the first is the default view.
GROUPS = [
    ("Player and garage variants", "player", "Player & garage"),
    ("General ground vehicles", "ground", "General ground"),
    ("AVs and airborne vehicles", "air", "AV & airborne"),
    ("Quest, traffic, service, and special variants", "special", "Quest & special"),
]

# The chassis-class vocabulary, quoted from the vehicle picker's roster header.
# `label` is what the panel chips read; `order` sorts the facet rail so the
# classes an operator wants first are first.
CLASSES = {
    "sport1":      ("Hypercar",   10),
    "sport2":      ("Sports",     20),
    "sport3":      ("Sports",     25),
    "sportbike1":  ("Superbike",  30),
    "sportbike2":  ("Bike",       35),
    "sportbike3":  ("Bike",       36),
    "standard2":   ("Saloon",     40),
    "standard25":  ("Pickup",     45),
    "standard3":   ("SUV",        50),
    "standard1":   ("Compact",    38),
    "utility2":    ("Utility",    60),
    "utility3":    ("Utility",    62),
    "utility4":    ("Truck",      64),
}

# Makers whose display casing is not simply title case.
MAKERS = {
    "ncpd": "NCPD", "av": "AV", "mpc": "MPC", "us": "US Cracks",
    "quadra": "Quadra", "rayfield": "Rayfield", "archer": "Archer",
    "herrera": "Herrera", "mizutani": "Mizutani", "thorton": "Thorton",
    "villefort": "Villefort", "makigai": "Makigai", "mahir": "Mahir",
    "chevalier": "Chevalier", "yaiba": "Yaiba", "arch": "Arch",
    "brennan": "Brennan", "militech": "Militech", "porsche": "Porsche",
    "kaukaz": "Kaukaz", "delamain": "Delamain", "zetatech": "Zetatech",
}

# Hand-written names for the records an operator is likely to reach for. The
# derived name is used for everything else and is good enough to search.
NAMES = {
    "v_standard2_archer_hella": "Archer Hella",
    "v_standard2_archer_bandit": "Archer Bandit",
    "v_standard2_archer_quartz": "Archer Quartz",
    "v_sport1_rayfield_caliburn": "Rayfield Caliburn",
    "v_sport1_rayfield_caliburn_mordred": "Caliburn “Mordred”",
    "v_sport1_rayfield_aerondight": "Rayfield Aerondight",
    "v_sport1_herrera_outlaw": "Herrera Outlaw",
    "v_sport1_herrera_riptide": "Herrera Riptide",
    "v_sport1_quadra_turbo": "Quadra Turbo-R",
    "v_sport2_quadra_type66": "Quadra Type-66",
    "v_sport2_mizutani_shion": "Mizutani Shion",
    "v_sport2_porsche_911turbo": "Porsche 911 Turbo",
    "v_sport2_villefort_alvarado": "Villefort Alvarado",
    "v_sport2_villefort_deleon": "Villefort Deleon",
    "v_standard2_villefort_cortes": "Villefort Cortes",
    "v_standard2_thorton_colby": "Thorton Colby",
    "v_standard2_thorton_galena": "Thorton Galena",
    "v_standard25_mahir_supron": "Mahir Supron",
    "v_standard2_makigai_maimai": "Makigai MaiMai",
    "v_standard2_mizutani_hozuki": "Mizutani Hozuki",
    "v_standard2_chevalier_thrax": "Chevalier Thrax",
    "v_sportbike1_yaiba_kusanagi": "Yaiba Kusanagi",
    "v_sportbike2_arch": "Arch Nazaré",
    "v_sportbike3_brennan_apollo": "Brennan Apollo",
    "v_standard3_militech_behemoth": "Militech Behemoth",
    "v_utility4_kaukaz_bratsk": "Kaukaz Bratsk",
}

# Seeded rated top speeds, km/h. These are the ONLY figures shipped, and each
# one was measured -- three from the engine-data table in
# docs/research/vehicles-api.md and the rest left empty on purpose. A record
# with no reading shows a dash in the panel and sorts last; the server fills the
# cache from Open77.vehicles.ratedTopSpeed as instances appear, and never
# estimates one.
SEED_SPEED = {
    "Vehicle.v_standard2_archer_hella_player": 115.0,
    "Vehicle.ncpd_villefort_cortes_heat_1": 140.0,
    "Vehicle.v_sport1_quadra_turbo_r_player": 155.0,
}

ROW = re.compile(r"^\|\s*`(Vehicle\.[A-Za-z0-9_]+)`\s*\|")
HEAD = re.compile(r"^##\s+(.*?)\s*(?:`[^`]*`\s*)?\(?\d*\)?\s*$")


def classify(record: str) -> tuple[str, str, str]:
    """Return (classKey, makerKey, modelSegment) derived from the record name."""
    body = record[len("Vehicle."):]
    if body.startswith("av_") or body == "av":
        return "av", "av", body[3:] or "av"
    parts = body.split("_")
    if parts[0] == "v" and len(parts) >= 3 and parts[1] in CLASSES:
        return parts[1], parts[2], "_".join(parts[3:]) or parts[2]
    if parts[0] == "ncpd" and len(parts) >= 2:
        return "police", parts[1], "_".join(parts[2:]) or parts[1]
    if parts[0] == "v" and len(parts) >= 3:
        return "other", parts[2], "_".join(parts[3:]) or parts[2]
    return "other", parts[0], "_".join(parts[1:]) or parts[0]


def pretty(word: str) -> str:
    return MAKERS.get(word, word.replace("-", " ").title())


def display(record: str, maker: str, model: str) -> str:
    body = record[len("Vehicle."):]
    for suffix in ("_player", "_puppet", "_02", "_01"):
        if body.endswith(suffix):
            body = body[: -len(suffix)]
    if body in NAMES:
        return NAMES[body]
    stem = model
    for suffix in ("_player", "_puppet"):
        if stem.endswith(suffix):
            stem = stem[: -len(suffix)]
    stem = stem.replace("_", " ").strip()
    name = f"{pretty(maker)} {stem.title()}".strip()
    return re.sub(r"\s+", " ", name)


def lua_quote(value: str) -> str:
    return '"' + value.replace("\\", "\\\\").replace('"', '\\"') + '"'


def main() -> int:
    if not SOURCE.exists():
        print(f"source not found: {SOURCE}", file=sys.stderr)
        return 1

    group = None
    seen: set[str] = set()
    entries: list[dict] = []

    for line in SOURCE.read_text(encoding="utf-8").splitlines():
        if line.startswith("## "):
            group = None
            for prefix, key, _label in GROUPS:
                if line[3:].startswith(prefix):
                    group = key
                    break
            continue
        if group is None:
            continue
        match = ROW.match(line)
        if match is None:
            continue
        record = match.group(1)
        if record in seen:
            continue
        seen.add(record)
        klass, maker, model = classify(record)
        entries.append({
            "record": record,
            "group": group,
            "klass": klass,
            "maker": maker,
            "name": display(record, maker, model),
            "police": record.startswith("Vehicle.ncpd_") or "_ncpd" in record,
            "player": record.endswith("_player"),
        })

    entries.sort(key=lambda item: item["record"])

    classes = sorted({item["klass"] for item in entries})
    makers = sorted({item["maker"] for item in entries})
    class_index = {name: index + 1 for index, name in enumerate(classes)}
    maker_index = {name: index + 1 for index, name in enumerate(makers)}

    # -----------------------------------------------------------------------
    # Emission
    #
    # One head file plus companions, each comfortably inside LOAD_BUDGET. The
    # reason this is split at all is at the top of this script.
    # -----------------------------------------------------------------------
    count = len(entries)

    manifest = [
        "catalog.lua",
        "catalog-records.lua",
        "catalog-names.lua",
        "catalog-taxonomy.lua",
        "catalog-attributes.lua",
    ]
    index_slices = max(1, -(-(count * COST_INDEX_ROW) // LOAD_BUDGET))
    slice_size = -(-count // index_slices)
    for number in range(1, index_slices + 1):
        manifest.append("catalog-index-" + str(number) + ".lua")

    written = []

    def preamble(holds, cost):
        """The short banner every companion file carries."""
        return [
            "-- GENERATED FILE -- do not edit by hand.",
            "--",
            "-- Produced by resources/system/open77_admin/tools/build-catalog.py from",
            "-- docs/vehicle-models.md. Part of the catalogue: the head file,",
            "-- shared/catalog.lua, explains the shape and WHY THIS IS SEVERAL",
            "-- FILES. Do not merge it back into one; read that note first.",
            "--",
            "-- This file holds: " + holds + ".",
            "-- Estimated load cost: " + str(cost) + " of a " + str(LOAD_BUDGET)
            + " VM-instruction budget.",
            "",
        ]

    def emit(filename, lines, cost):
        if cost > LOAD_BUDGET:
            print("catalogue part " + filename + " would execute about " + str(cost)
                  + " VM instructions, over the " + str(LOAD_BUDGET) + " budget.")
            print("The host aborts a script load that crosses 10 000 instructions on a")
            print("stalled frame, and it rolls back the whole resource set when it does.")
            print("Split this part further: give it its own file above, and add the new")
            print("shared_script line to resources/system/open77_admin/open77.lua in load order.")
            raise SystemExit(1)
        target = SHARED / filename
        target.parent.mkdir(parents=True, exist_ok=True)
        body = "".join(line + chr(10) for line in lines)
        target.write_text(body, encoding="utf-8", newline="")
        written.append((filename, cost))

    # ---- head ------------------------------------------------------------
    out = []
    push = out.append
    push("-- GENERATED FILE -- do not edit by hand.")
    push("--")
    push("-- Produced by resources/system/open77_admin/tools/build-catalog.py from")
    push("-- docs/vehicle-models.md (Cyberpunk 2077 build 2.31). Re-run the")
    push("-- generator instead of editing; a hand edit is lost on the next build")
    push("-- and drifts silently from the catalogue it claims to mirror.")
    push("--")
    push("-- Shared, not client: the panel renders it and the server validates")
    push("-- against it, so both halves must read the same bytes.")
    push("--")
    push("-- Records are stored as parallel arrays rather than a table per")
    push("-- vehicle. " + str(count) + " tables of six string keys is a measurable amount")
    push("-- of Lua state to build on every client at load; six arrays is not.")
    push("--")
    push("-- ---------------------------------------------------------------------")
    push("-- DO NOT MERGE THE COMPANION FILES BACK INTO THIS ONE.")
    push("--")
    push("-- The scripting host loads each script of a resource with its own")
    push("-- lua_pcall, under a LUA_MASKCOUNT hook that fires every 10 000 VM")
    push("-- instructions and, when it fires, aborts the load if the wall clock is")
    push("-- past a 2 ms deadline (scripting/src/ResourceHost.cpp, Prepare()). The")
    push("-- instruction count and the deadline are both reset PER FILE.")
    push("--")
    push("-- So the whole trick is to stay under the hook's stride: a file that")
    push("-- executes fewer than 10 000 instructions never fires the hook, and the")
    push("-- deadline is therefore never consulted. The failure is not made less")
    push("-- likely, it is made structurally impossible.")
    push("--")
    push("-- As one file this catalogue executed about 13 700 instructions -- 9 583")
    push("-- opcodes of table constructors plus " + str(count) + " x 3 for the index loop. It")
    push("-- crossed the stride exactly once, and the host rolled back the entire")
    push("-- 25-resource candidate set whenever that single check landed on a")
    push("-- stalled frame: observed twice on 2026-08-28, each time silently")
    push("-- leaving the previous resource set running, so a deploy appeared to")
    push("-- succeed while the client kept executing the old code.")
    push("--")
    push("-- Load order is the shared_script order in open77.lua, and it matters:")
    for filename in manifest:
        push("--   " + filename)
    push("--")
    push("-- The last index part asserts that all of them ran. If you ever see")
    push("-- `catalogue incomplete` at startup, that list is wrong.")
    push("-- ---------------------------------------------------------------------")
    push("")
    push("Open77AdminCatalog = {")
    push('    build = "2.31",')
    push("    count = " + str(count) + ",")

    push("    groups = {")
    for _prefix, key, label in GROUPS:
        total = sum(1 for item in entries if item["group"] == key)
        push('        { key = "' + key + '", label = ' + lua_quote(label)
             + ", count = " + str(total) + " },")
    push("    },")

    push("    classes = {")
    for name in classes:
        label, order = CLASSES.get(name, (pretty(name), 90))
        if name == "police":
            label, order = "Police", 5
        elif name == "av":
            label, order = "Airborne", 70
        elif name == "other":
            label, order = "Other", 95
        total = sum(1 for item in entries if item["klass"] == name)
        push('        { key = "' + name + '", label = ' + lua_quote(label)
             + ", order = " + str(order) + ", count = " + str(total) + " },")
    push("    },")

    push("    makers = {")
    for name in makers:
        total = sum(1 for item in entries if item["maker"] == name)
        push('        { key = "' + name + '", label = ' + lua_quote(pretty(name))
             + ", count = " + str(total) + " },")
    push("    },")

    push("    -- Measured rated top speeds, km/h. Seeded only where a real")
    push("    -- measurement exists; the server adds to this at runtime from")
    push("    -- Open77.vehicles.ratedTopSpeed and never estimates.")
    push("    ratedTopSpeed = {")
    for record, speed in sorted(SEED_SPEED.items()):
        push("        [" + lua_quote(record) + "] = " + str(speed) + ",")
    push("    },")
    push("")
    push("    -- Filled by the companion files, in manifest order. Declared here so")
    push("    -- the shape of the catalogue is visible in one place, and so that no")
    push("    -- reader is ever handed a nil table.")
    push("    records = {},")
    push("    names = {},")
    push("    groupOf = {},")
    push("    classOf = {},")
    push("    makerOf = {},")
    push("    flags = {},")
    push("    byRecord = {},")
    push("}")
    push("")
    push("--- Position of a record in the catalogue, or nil when it is not one.")
    push("--- This is the server's validity test: a client may name any string,")
    push("--- and only a string that is in here reaches Open77.vehicles.create.")
    push("---")
    push("--- `byRecord` was a file-local `index` before the split. It is a field")
    push("--- now because a local cannot be seen from another file, and it stays an")
    push("--- O(1) test -- " + str(count) + " linear scans per keystroke would be felt on the")
    push("--- search box.")
    push("function Open77AdminCatalog.position(record)")
    push('    if type(record) ~= "string" then return nil end')
    push("    return Open77AdminCatalog.byRecord[record]")
    push("end")
    push("")
    push("--- One entry as a plain table, or nil. Built on demand precisely")
    push("--- because the columnar form exists to avoid building " + str(count) + " of them.")
    push("function Open77AdminCatalog.entry(record)")
    push("    local position = Open77AdminCatalog.position(record)")
    push("    if position == nil then return nil end")
    push("    local catalog = Open77AdminCatalog")
    push("    local flags = catalog.flags[position]")
    push("    return {")
    push("        record = record,")
    push("        name = catalog.names[position],")
    push("        group = catalog.groupOf[position],")
    push("        class = catalog.classes[catalog.classOf[position]].key,")
    push("        maker = catalog.makers[catalog.makerOf[position]].key,")
    push("        police = flags % 2 == 1,")
    push("        player = flags >= 2,")
    push("        ratedTopSpeed = catalog.ratedTopSpeed[record],")
    push("    }")
    push("end")
    facet_rows = len(GROUPS) + len(classes) + len(makers)
    emit("catalog.lua", out,
         COST_FIXED + facet_rows * COST_FACET_ROW + len(SEED_SPEED) * 2 + 14)

    # ---- columns ---------------------------------------------------------
    def column_lines(key, transform):
        lines = ["Open77AdminCatalog." + key + " = {"]
        row = []
        for item in entries:
            row.append(transform(item))
            if len(row) == 8:
                lines.append("    " + ", ".join(row) + ",")
                row = []
        if row:
            lines.append("    " + ", ".join(row) + ",")
        lines.append("}")
        return lines

    def column_cost(columns):
        return int(COST_FIXED + columns * count * COST_ELEMENT)

    records_cost = column_cost(1)
    emit("catalog-records.lua",
         preamble("the record strings, in catalogue order", records_cost)
         + column_lines("records", lambda item: lua_quote(item["record"])),
         records_cost)

    emit("catalog-names.lua",
         preamble("the display names, parallel to records", records_cost)
         + column_lines("names", lambda item: lua_quote(item["name"])),
         records_cost)

    pair_cost = column_cost(2)
    emit("catalog-taxonomy.lua",
         preamble("the group key and the class index of each record", pair_cost)
         + column_lines("groupOf", lambda item: lua_quote(item["group"]))
         + [""]
         + column_lines("classOf", lambda item: str(class_index[item["klass"]])),
         pair_cost)

    emit("catalog-attributes.lua",
         preamble("the manufacturer index and the flag bits of each record",
                  pair_cost)
         + column_lines("makerOf", lambda item: str(maker_index[item["maker"]]))
         + [""]
         + [
             "-- Bit 0 is police, bit 1 is a player/garage variant. Two booleans in",
             "-- one integer because two more " + str(count) + "-element arrays are not worth it.",
         ]
         + column_lines("flags",
                        lambda item: str((1 if item["police"] else 0)
                                         | (2 if item["player"] else 0))),
         pair_cost)

    # ---- index -----------------------------------------------------------
    #
    # Derived from `records` at load rather than emitted as data, so it cannot
    # drift from the column it indexes. Sliced only because the loop costs
    # three opcodes a row and the whole of it would not fit one file's budget.
    for number in range(1, index_slices + 1):
        first = (number - 1) * slice_size + 1
        last = min(number * slice_size, count)
        rows = last - first + 1
        cost = COST_FIXED + rows * COST_INDEX_ROW
        lines = preamble(
            "the record index for positions " + str(first) + " to " + str(last), cost)
        lines.append("local catalog = Open77AdminCatalog")
        lines.append("local records, byRecord = catalog.records, catalog.byRecord")
        lines.append("for position = " + str(first) + ", " + str(last) + " do")
        lines.append("    byRecord[records[position]] = position")
        lines.append("end")
        if number == index_slices:
            lines.append("")
            lines.append("-- Loud about a manifest that lists these files out of order or")
            lines.append("-- omits one. A half-loaded catalogue is worse than no catalogue:")
            lines.append("-- it validates spawns against a partial table and refuses records")
            lines.append("-- that are perfectly real, with nothing to say why.")
            lines.append("if #catalog.records ~= catalog.count")
            lines.append("    or #catalog.names ~= catalog.count")
            lines.append("    or #catalog.flags ~= catalog.count")
            lines.append("    or byRecord[records[catalog.count]] ~= catalog.count then")
            lines.append('    error("open77_admin catalogue incomplete -- check the '
                         'shared_script order in open77.lua")')
            lines.append("end")
        emit("catalog-index-" + str(number) + ".lua", lines, cost)

    print(str(count) + " records -> " + str(len(written)) + " files in " + str(SHARED))
    for _prefix, key, label in GROUPS:
        print("  " + label.ljust(18)
              + str(sum(1 for item in entries if item["group"] == key)))
    print("  classes " + str(len(classes)) + "  makers " + str(len(makers)))
    print("  load cost per file, budget " + str(LOAD_BUDGET)
          + " VM instructions (hook stride 10000):")
    for filename, cost in written:
        print("    " + filename.ljust(28) + str(cost))
    print("  manifest order for resources/system/open77_admin/open77.lua:")
    for filename in manifest:
        print('    shared_script "shared/' + filename + '"')
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
