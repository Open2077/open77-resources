#!/usr/bin/env python3
"""Generate shared/weapons.lua from docs/generated/weapons-2.31.csv.

The vehicle catalogue next door derives every facet from the record STRING,
because `v_<class><n>_<maker>_<model>` is structured data. Weapon records are
not: nothing in `Items.Preset_Umbra_Bebe` says "assault rifle", and nothing in
it says the weapon is called Carmen. So this generator reads the extraction
instead, where both facts are flats of the TweakDB record rather than a guess:

    item_type   gamedataWeaponItem_Record.itemType   -> the class
    equip_area  gamedataWeaponItem_Record.equipArea  -> whether the API takes it
    name_fr     the cooked localisation for DisplayName.Key

docs/research/weapons-and-item-records.md documents how that CSV was produced
(TweakDBReader over `tweakdb.bin` + `tweakdb_ep1.bin`, names resolved against
the cooked French `onscreens_final.json`) and what `canonical` means: one row
per distinct display name, preferring `Items.Preset_*`, `_Default` suffixes and
player records over NPC, scene, training and craft variants.

THE FILTER IS THE ALLOWLIST. Three predicates, and each one is a fact of the
record rather than taste:

  * `canonical` -- one row per weapon, not per quality tier and difficulty
    variant. 1925 records collapse to 189.
  * `equip_area == EquipmentArea.Weapon` -- the Lua weapons API supports the
    three ordinary slots and NOTHING else. It rejects `QuickSlot` (grenades),
    `WeaponHeavy` (the portable HMG) and `ArmsCW` (mantis blades, gorilla arms,
    monowire, projectile launcher) with `unsupported_weapon_area`, because
    those areas have different REDengine lifecycles. Shipping them in the
    catalogue would only ship a button that always fails.
  * `deprecated == False` -- the record itself says so.

Everything that survives is `usage == inventory` already, which is the
extraction's own word for "an ordinary item, not a vehicle turret projection or
a test fixture".

Run:
    python resources/system/open77_admin/tools/build-weapons.py

It rewrites resources/system/open77_admin/shared/weapons.lua in place and prints a
summary including the load cost. The output is byte reproducible.

ONE FILE, unlike the vehicle catalogue, and that is a measurement rather than
an inconsistency. The scripting host aborts a script load that crosses 10 000
VM instructions on a stalled frame (scripting/src/ResourceHost.cpp, Prepare())
and rolls back the whole candidate resource set when it does. The vehicle
catalogue is 1372 records and cost ~13 700 instructions, so it had to be split.
189 records cost about a tenth of that -- the summary prints the figure -- so
the file never comes near the stride and splitting it would buy nothing.
"""

from __future__ import annotations

import csv
import io
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
SOURCE = ROOT / "docs" / "generated" / "weapons-2.31.csv"
TARGET = Path(__file__).resolve().parents[1] / "shared" / "weapons.lua"

BUILD = "2.31"

# Same cost model as build-catalog.py, read off `luac -l -l` rather than
# guessed: an array element is one LOADK plus one SETLIST per 50, a facet row
# is a NEWTABLE plus a LOADK/SETFIELD pair per field, an index row is three
# opcodes, and the fixed part is the preamble and the table open/close.
COST_ELEMENT = 1.02
COST_FACET_ROW = 12
COST_INDEX_ROW = 3
COST_FIXED = 60
LOAD_BUDGET = 4000

# ---------------------------------------------------------------------------
# Classes
#
# `key` is what the panel and the menu route on, `label` is what they draw, and
# `order` is the order the operator meets them: the things people ask for
# first, first, then melee.
#
# `reserve` is the FULL LOAD this package hands out with the weapon, in spare
# rounds. It is a SERVER POLICY and not a game constant -- see the note in
# shared/config.lua, which is where an operator changes it -- but it is BOUNDED
# BY A REAL GAME CEILING, and that ceiling is why these are not simply large
# numbers.
#
# Measured in game on 2.31, 2026-08-30, by asking for more than the engine
# would give and reading back what the character actually held: the carried
# pool is capped PER AMMO TYPE, on the TOTAL, which is reserve + magazine.
# Shotgun ammo topped out at exactly 200 -- 196 spare over a 4-round magazine,
# and asking for exactly 196 then verified; sniper ammo at 175; rifle ammo just
# under 1000; handgun ammo took 500 spare over a 21-round magazine without
# complaint.
#
# Over-asking is not harmless. `Open77WeaponAmmoStep` verifies
# `total == reserve + magazine` in its last phase, so a request the ceiling
# clips answers `ammo_update_rejected`: the weapon is equipped and loaded to
# the cap, but the operator is told it failed. 1500 for an LMG did exactly
# that, and so did 200 for a shotgun -- 200 spare plus a 4-round magazine is
# 204, four rounds over. Every figure below therefore sits under the measured
# ceiling for its ammo type with a full magazine to spare.
#
# The ammo TYPE per class was measured the same way, off the `ammoTweakDbId`
# the engine reports back. Four buckets -- and one of them is not where a
# reasonable person would put it: PRECISION RIFLES DRAW RIFLE AMMO, not sniper
# ammo. An M-179e Achilles reported 0x0000000E5BEC7BB0, the same id as an M2067
# Defender, where an SPT32 Grad reported 0x00000014089D1CBC. That is why they
# get the rifle-sized figure and not the sniper one.
#
# `ammo` is whether the class has an ammo pool worth filling. Skipping the call
# for melee is the difference between "Katana equipped" and "Katana equipped,
# then a failure the operator cannot act on".
#
# The obvious justification is that melee records have no `Ammo()` -- and it is
# NOT quite true, so it is not the one used here. A Katana in game reported a
# real ammo id (0x0000000DA4AED401) with a total of 0, which means
# `WeaponItem_Record.Ammo()` resolved: `Open77WeaponAmmoValues` would have
# returned nothing at all otherwise. What is true is that the pool caps at
# zero, so asking for any reserve fails the `total == reserve + magazine`
# verification. Measured 2026-08-30: `weap.ammo <player> 3 100` on a Katana
# answers `ammo_update_rejected`, not `weapon_has_no_ammo`.
#
# Several item types share one class row on purpose: a Sword, a LongBlade and a
# Chainsword are four rows between them, and a screen with four one-entry
# families on it is worse than one Blades screen with twenty-one.
CLASSES = [
    ("handgun",   "Handguns",         10, True,  500, ["ItemType.Wea_Handgun"]),
    ("revolver",  "Revolvers",        20, True,  500, ["ItemType.Wea_Revolver"]),
    ("smg",       "SMGs",             30, True,  800, ["ItemType.Wea_SubmachineGun"]),
    ("rifle",     "Assault rifles",   40, True,  800, ["ItemType.Wea_Rifle"]),
    ("precision", "Precision rifles", 50, True,  400, ["ItemType.Wea_PrecisionRifle"]),
    ("sniper",    "Sniper rifles",    60, True,  120, ["ItemType.Wea_SniperRifle"]),
    ("shotgun",   "Shotguns",         70, True,  150, ["ItemType.Wea_Shotgun"]),
    ("dual",      "Double-barrels",   80, True,  150, ["ItemType.Wea_ShotgunDual"]),
    ("lmg",       "LMGs",             90, True,  800, ["ItemType.Wea_LightMachineGun"]),
    ("blade",     "Blades",          110, False,   0, [
        "ItemType.Wea_Katana", "ItemType.Wea_Sword", "ItemType.Wea_LongBlade",
        "ItemType.Wea_Chainsword", "ItemType.Wea_Machete", "ItemType.Wea_Axe"]),
    ("knife",     "Knives",          120, False,   0, ["ItemType.Wea_Knife"]),
    ("blunt",     "Blunt",           130, False,   0, [
        "ItemType.Wea_OneHandedClub", "ItemType.Wea_TwoHandedClub",
        "ItemType.Wea_Hammer", "ItemType.Wea_Fists"]),
]

CLASS_OF_TYPE = {
    item_type: key
    for key, _label, _order, _ammo, _reserve, types in CLASSES
    for item_type in types
}

# Names for the records an operator reaches for by name, taken VERBATIM from
# resources/gamemodes/freeroam/shared/config.lua so the two packages agree on what to
# call the same gun. Everything else keeps the name the game itself shows,
# which the extraction read out of the cooked localisation -- so a few iconics
# read in French here, because that is the resource the extraction had. An
# English extraction regenerates them; nothing downstream depends on the text.
NAMES = {
    "Items.Preset_Lexington_Default": "M-10AF Lexington",
    "Items.Preset_Unity_Default": "Unity",
    "Items.Preset_Nue_Default": "Nue",
    "Items.Preset_Overture_Default": "Overture",
    "Items.Preset_Quasar_Default": "DR-12 Quasar",
    "Items.Preset_Silverhand_3516": "Malorian Arms 3516",
    "Items.Preset_Saratoga_Default": "M221 Saratoga",
    "Items.Preset_Saratoga_Maelstrom": "Fenrir",
    "Items.Preset_Ajax_Default": "M251s Ajax",
    "Items.Preset_Copperhead_Default": "D5 Copperhead",
    "Items.Preset_Masamune_Default": "HJSH-18 Masamune",
    "Items.Preset_Achilles_Default": "M-179e Achilles",
    "Items.Preset_Sor22_Default": "SOR-22",
    "Items.Preset_Grad_Default": "SPT32 Grad",
    "Items.Preset_Nekomata_Default": "Nekomata",
    "Items.Preset_Ashura_Default": "Ashura",
    "Items.Preset_Carnage_Default": "Carnage",
    "Items.Preset_Satara_Default": "DB-2 Satara",
    "Items.Preset_Zhuo_Default": "L-69 Zhuo",
    "Items.Preset_Defender_Default": "M2067 Defender",
    "Items.Preset_Katana_Default": "Katana",
    "Items.Preset_Knife_Default": "Knife",
    "Items.Preset_Machete_Default": "Machete",
    "Items.Preset_Hammer_Default": "Hammer",
    "Items.Preset_Achilles_Nash": "Widow Maker",
}


def lua_quote(value: str) -> str:
    return '"' + value.replace("\\", "\\\\").replace('"', '\\"') + '"'


def wrap(values: list[str], indent: str, per_line: int) -> str:
    lines = []
    for start in range(0, len(values), per_line):
        lines.append(indent + ", ".join(values[start:start + per_line]) + ",")
    return "\n".join(lines)


def main() -> int:
    if not SOURCE.exists():
        print(f"missing source: {SOURCE}", file=sys.stderr)
        return 1

    with io.open(SOURCE, encoding="utf-8-sig", newline="") as handle:
        rows = list(csv.DictReader(handle))

    kept = []
    skipped_area: dict[str, int] = {}
    unclassified: list[str] = []
    for row in rows:
        if row["canonical"] != "True" or row["deprecated"] != "False":
            continue
        if row["equip_area"] != "EquipmentArea.Weapon":
            skipped_area[row["equip_area"]] = skipped_area.get(row["equip_area"], 0) + 1
            continue
        class_key = CLASS_OF_TYPE.get(row["item_type"])
        if class_key is None:
            unclassified.append(f'{row["record"]} ({row["item_type"]})')
            continue
        # The extraction carries U+00A0 inside a few display names ("Kappa
        # x-MOD2"). It renders as a space and sorts as one everywhere the panel
        # is concerned, so normalise it rather than shipping an invisible
        # difference between two names that look identical.
        name = NAMES.get(row["record"]) or row["name_fr"].replace(" ", " ").strip()
        kept.append((class_key, name, row["record"]))

    if unclassified:
        print("unclassified item types -- extend CLASSES:", file=sys.stderr)
        for entry in unclassified:
            print("  " + entry, file=sys.stderr)
        return 1

    # Class order first, then name, so a screen is alphabetical and the
    # `classOf` runs are contiguous. `position` is what everything else keys on.
    order_of = {key: order for key, _label, order, _ammo, _reserve, _types in CLASSES}
    kept.sort(key=lambda entry: (order_of[entry[0]], entry[1].lower(), entry[2]))

    counts: dict[str, int] = {}
    for class_key, _name, _record in kept:
        counts[class_key] = counts.get(class_key, 0) + 1

    class_index = {}
    class_rows = []
    for position, (key, label, order, ammo, reserve, _types) in enumerate(CLASSES, start=1):
        class_index[key] = position
        class_rows.append(
            "        { key = %s, label = %s, order = %d, ammo = %s, reserve = %d, count = %d },"
            % (lua_quote(key), lua_quote(label), order,
               "true" if ammo else "false", reserve, counts.get(key, 0)))

    records = [lua_quote(record) for _class, _name, record in kept]
    names = [lua_quote(name) for _class, name, _record in kept]
    class_of = [str(class_index[class_key]) for class_key, _name, _record in kept]

    cost = int(COST_FIXED
               + (len(records) + len(names) + len(class_of)) * COST_ELEMENT
               + len(class_rows) * COST_FACET_ROW
               + len(kept) * COST_INDEX_ROW)

    body = f'''-- GENERATED FILE -- do not edit by hand.
--
-- Produced by resources/system/open77_admin/tools/build-weapons.py from
-- docs/generated/weapons-2.31.csv (Cyberpunk 2077 build {BUILD} + Phantom
-- Liberty). Re-run the generator instead of editing; a hand edit is lost on
-- the next build and drifts silently from the extraction it claims to mirror.
--
-- Shared, not server-only: the panel renders it and the server validates
-- against it, so both halves must read the same bytes. THE CATALOGUE IS THE
-- ALLOWLIST -- server/weapons.lua refuses any record that is not in `index`,
-- which is what stops a client naming an arbitrary TweakDB string. See the
-- authority note in wiki/weapons-api.md.
--
-- Every record here is `canonical`, `EquipmentArea.Weapon` and not deprecated.
-- The three areas the Lua weapons API refuses -- QuickSlot (grenades),
-- WeaponHeavy (the portable HMG) and ArmsCW (arm cyberware) -- are filtered
-- out at generation, so nothing in this file can answer
-- `unsupported_weapon_area`.
--
-- Records are parallel arrays, like the vehicle catalogue: {len(kept)} tables of
-- three string keys is Lua state built on every client at load, three arrays
-- is not.
--
-- ONE FILE, unlike shared/catalog*.lua, and that is measured rather than
-- careless: this costs about {cost} VM instructions against the host's
-- 10 000-instruction hook stride, where the {len(kept)}-record vehicle catalogue cost
-- ~13 700 and had to be split. shared/catalog.lua carries the full note.

Open77AdminWeapons = {{
    build = "{BUILD}",
    count = {len(kept)},

    -- Ordered as the operator meets them. `ammo` says whether the class has an
    -- ammo pool at all -- `WeaponItem_Record.Ammo()` is undefined for melee,
    -- and asking for ammo there answers `weapon_has_no_ammo`. `reserve` is the
    -- full load this package hands out with the weapon; Open77AdminConfig
    -- .weapons.reserve overrides it per server.
    classes = {{
{chr(10).join(class_rows)}
    }},

    -- The records. Position in this array is the identity everything else
    -- keys on.
    records = {{
{wrap(records, "        ", 4)}
    }},

    -- Display names, parallel to records.
    names = {{
{wrap(names, "        ", 4)}
    }},

    -- Class row index, parallel to records.
    classOf = {{
{wrap(class_of, "        ", 24)}
    }},
}}

-- record -> position. Built here rather than shipped as a third array: a
-- {len(kept)}-row loop is {len(kept) * COST_INDEX_ROW} opcodes, and shipping the keys would double the
-- file for no gain.
Open77AdminWeapons.index = {{}}
for position = 1, #Open77AdminWeapons.records do
    Open77AdminWeapons.index[Open77AdminWeapons.records[position]] = position
end

--- The class row for a record, or nil when the record is not in the catalogue.
function Open77AdminWeapons.classOfRecord(record)
    local position = Open77AdminWeapons.index[record]
    if position == nil then return nil end
    return Open77AdminWeapons.classes[Open77AdminWeapons.classOf[position]]
end

--- Display name for a record, falling back to the record itself.
function Open77AdminWeapons.nameOf(record)
    local position = Open77AdminWeapons.index[record]
    return position ~= nil and Open77AdminWeapons.names[position] or record
end

assert(#Open77AdminWeapons.records == Open77AdminWeapons.count
    and #Open77AdminWeapons.names == Open77AdminWeapons.count
    and #Open77AdminWeapons.classOf == Open77AdminWeapons.count,
    "open77_admin: weapon catalogue incomplete -- re-run tools/build-weapons.py")
'''

    TARGET.write_text(body, encoding="utf-8", newline="\n")

    print(f"wrote {TARGET.relative_to(ROOT)}")
    print(f"  {len(kept)} records from {len(rows)} rows")
    for key, label, _order, ammo, reserve, _types in CLASSES:
        print(f"    {label:<17} {counts.get(key, 0):>4}"
              f"  {'reserve ' + str(reserve) if ammo else 'no ammo'}")
    for area, count in sorted(skipped_area.items()):
        print(f"  skipped {count} canonical record(s) in {area}")
    print(f"  estimated load cost {cost} of a {LOAD_BUDGET} instruction budget")
    if cost > LOAD_BUDGET:
        print("  OVER BUDGET -- split the file, see build-catalog.py", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
