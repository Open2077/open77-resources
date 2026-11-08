"""TweakDBID collisions of the Light RP stage and engine-sound packs (STAGES.md, "TweakDBID collisions").

A TweakDBID is CRC32(full name) | len(name) << 32: 40 bits, and TweakDB keys every record and every
flat by them alone. Two different names with the same CRC32 and the same length are ONE id. TweakXL
creates, for every record of a YAML, its record id and one flat `<record>.<property>` per property
of its `$base`'s record type (it clones the base record: the type's properties, plus the extra flats
TweakXL's `Data/ExtraFlats.dat` declares for it), then assigns the flats the YAML sets. When one of
those ids already exists the second record silently gets the first one's value, of another type:

    [warning] Type mismatch for Vehicle.v_sport2_villefort_deleon_player_o77s3a3.player_audio_resource assignment.
    [warning] Vehicle.v_sport2_villefort_deleon_player_o77s3a3.player_audio_resource has hash collision with
              Vehicle.v_standard2_makigai_maimai_player_o77s1a3.drivingParamsGeneric.

(TweakXL log of a lab client, 2026-11-08 02:06: both names are CRC32 0x49c53d2a, 70 bytes.) TweakXL
only warns about names it knows; a collision with a VANILLA flat is silent (it does not load the
vanilla names), and the new record then reads, or overwrites, a flat of an unrelated vanilla record.

`check()` refuses any id the two YAMLs create twice, or that already exists in tweakdb.bin /
tweakdb_ep1.bin (flats and records alike). The property list per record type comes from
`record-properties.json`, a reviewed file like base-records.json: `make_stages.py --names` rebuilds
it from WolvenKit's string table (the properties named on at least half the vanilla records of each
type and present in tweakdb.bin) and TweakXL's ExtraFlats.dat; every run re-verifies it against
tweakdb.bin (every listed property exists on every `$base` the YAMLs clone).

A collision the generator cannot avoid by itself is resolved here, as data, and never on a dealer
record (both YAMLs must keep the exact bytes of the dealer-only build): an extended engine-sound
record is dropped, and the sound's coverage omits that stage for that model (`Covers` is false
there); an extended stage sub-record, which only its own stage record names, is renamed. Each entry
of DECLARED is re-measured on every run (`verify_declared`): the record it drops or renames must
still collide exactly as stated, or the entry is stale and the build fails.
"""
from __future__ import annotations

import hashlib
import json
import os
import struct
from collections import Counter, OrderedDict, defaultdict, namedtuple

import tdb

PROPERTIES = os.path.join(os.path.dirname(os.path.abspath(__file__)), "record-properties.json")
PROPERTIES_SCHEMA = "open77.tweakdb-record-properties/1"
# A property is a type's when it is named on at least this share of the type's named records (the
# string table misses a few names per type; a flat a single record carries is not the type's).
CORE_SHARE = 0.5
EXTRA_FLATS_REL = os.path.join("red4ext", "plugins", "TweakXL", "Data", "ExtraFlats.dat")
# The record types the two YAMLs clone (make_stages.TYPES, and Vehicle for the sound records).
CLONED_TYPES = ("Vehicle", "VehicleEngineData", "VehicleDriveModelData", "BikeDriveModelData",
                "VehicleWheelDrivingSetup_4", "VehicleWheelDrivingSetup_2", "VehicleWheelDrivingPreset")

# kind:      "sound" (an engine-sound record, dropped: a coverage hole) or "stage" (a stage
#            sub-record, renamed: no hole, only its own stage record names it)
# record:    the name the generator would write, canonical
# flat:      the property of `record` whose id collides ("" for the record id itself)
# crc, size: the colliding id, CRC32 and name length
# partner:   the name that already holds that id
# where:     "vanilla" (a flat or record of tweakdb.bin) or "pack" (a record the packs keep)
# renamed:   kind "stage" only: the name used instead
Collision = namedtuple("Collision", "kind record flat crc size partner where renamed")

DECLARED = (
    Collision("sound", "Vehicle.v_sport2_villefort_deleon_player_o77s3a3", "player_audio_resource",
              0x49C53D2A, 70, "Vehicle.v_standard2_makigai_maimai_player_o77s1a3.drivingParamsGeneric", "pack", ""),
    Collision("sound", "Vehicle.v_sport1_quadra_turbo_player_o77s1a1", "customizeLights",
              0x6FAAD9BF, 60, "Character.ep1_combat_zone_service_dining_ma_savable.vendorID", "vanilla", ""),
    Collision("sound", "Vehicle.v_sport1_quadra_turbo_r_player_o77a4", "vehImpactTraffic",
              0x862CCFD5, 61, "Character.arasaka_sumo_hmelee2_fists_mb_rare.stateMachineName", "vanilla", ""),
    Collision("stage", "Vehicle.v_standard3_militech_hellhound_player_o77s2_engine", "gearCurvesPath",
              0x525008E5, 73, "EquipmentGLP.HeavyFastFiringWeaponCloseRangeDamageMult_inline3.weaponType", "vanilla",
              "Vehicle.v_standard3_militech_hellhound_player_o77s2_engine_c1"),
)
SOUND_EXCLUSIONS = frozenset(c.record for c in DECLARED if c.kind == "sound")
STAGE_RENAMES = {c.record: c.renamed for c in DECLARED if c.kind == "stage"}


class CollisionError(Exception):
    pass


def id_of(name: str) -> int:
    return tdb.tdbid(name) & tdb.ID_MASK


def describe(i: int) -> str:
    return f"CRC32 {i & 0xFFFFFFFF:#010x}, length {i >> 32}"


def is_vanilla(db: tdb.LayeredTweakDB, i: int) -> str | None:
    """'flat <type>' or 'record' when the id exists in a layer of the game's TweakDB, else None."""
    for layer in db.layers:
        packed = layer.flats.get(i)
        if packed is not None:
            return f"flat ({layer.pools[packed >> 32].name})"
        if i in layer.records:
            return "record"
    return None


# --------------------------------------------------------------------------- property model
def load_properties(path: str = PROPERTIES) -> dict:
    if not os.path.isfile(path):
        raise CollisionError(f"{path} is missing: run make_stages.py --names <tweakdbstr.kark>")
    with open(path, encoding="utf-8") as fh:
        doc = json.load(fh)
    if doc.get("schema") != PROPERTIES_SCHEMA:
        raise CollisionError(f"{path}: schema {doc.get('schema')!r}, expected {PROPERTIES_SCHEMA}")
    return doc


def type_names(db: tdb.LayeredTweakDB, types) -> dict[int, str]:
    return {tdb.record_type_key(f"gamedata{t}_Record"): t for t in types}


def flats_of(db: tdb.LayeredTweakDB, props: dict, base: str, keys: dict[int, str]) -> tuple[str, ...]:
    """Every property TweakXL gives a record cloned from `base`: its type's, the type's extra flats,
    and any flat the base record alone carries (conservative)."""
    t = keys.get(db.record_type(id_of(base)))
    entry = props["types"].get(t) if t else None
    if entry is None:
        raise CollisionError(f"{base}: record type not in record-properties.json (rerun --names)")
    return tuple(entry["properties"]) + tuple(entry.get("extraFlats", ())) + tuple(props["records"].get(base, ()))


def verify_properties(db: tdb.LayeredTweakDB, props: dict, bases) -> list[str]:
    """record-properties.json against tweakdb.bin: every `$base` listed, every property of its type
    and every flat listed for it present on it (TweakDB stores every property of every record)."""
    errors = []
    keys = type_names(db, props["types"])
    for base in sorted(set(bases)):
        bid = id_of(base)
        t = keys.get(db.record_type(bid))
        if t is None:
            errors.append(f"{base}: record type of the $base is not in record-properties.json (rerun --names)")
            continue
        if base not in props["records"]:
            errors.append(f"{base}: $base not listed in record-properties.json (rerun --names)")
            continue
        for p in tuple(props["types"][t]["properties"]) + tuple(props["records"][base]):
            if not db.has_flat(tdb.tdbid_append(bid, "." + p)):
                errors.append(f"{base}: property {p} of record-properties.json is not a flat of it in "
                              "tweakdb.bin (game update? rerun --names)")
    return errors


def read_extra_flats(path: str) -> dict[str, list[str]]:
    """TweakXL's Data/ExtraFlats.dat: u64 types, per type {u64 fnv1a64(type), u64 n, n x {u8 len,
    name, u64 flat type hash, u64 foreign type hash}}. Record type -> extra flat names."""
    with open(path, "rb") as fh:
        buf = fh.read()
    (n,) = struct.unpack_from("<Q", buf, 0)
    pos = 8
    out: dict[int, list[str]] = {}
    for _ in range(n):
        th, count = struct.unpack_from("<QQ", buf, pos)
        pos += 16
        names = []
        for _ in range(count):
            ln = buf[pos]
            names.append(buf[pos + 1:pos + 1 + ln].decode("ascii"))
            pos += 1 + ln + 16
        out[th] = names
    if pos != len(buf):
        raise CollisionError(f"{path}: {len(buf) - pos} trailing bytes, not an ExtraFlats.dat this reader knows")
    return out


def build_properties(db: tdb.LayeredTweakDB, names, bases, extra_flats_path: str) -> "OrderedDict":
    """record-properties.json from the string table (`names`: (is_flat, name) pairs, tdb.iter_names)."""
    base_ids = {id_of(b): b for b in bases}
    wanted = {db.record_type(i) for i in base_ids}
    if None in wanted:
        raise CollisionError("a $base is not a record of tweakdb.bin")
    record_type: dict[str, int] = {}
    counts: dict[int, Counter] = defaultdict(Counter)
    named: dict[str, set] = defaultdict(set)
    for is_flat, name in names:
        if not is_flat:
            k = db.record_type(id_of(name))
            if k in wanted:
                record_type[name] = k
            continue
        j = name.rfind(".")
        if j <= 0:
            continue
        k = record_type.get(name[:j])
        if k is None or not db.has_flat(id_of(name)):
            continue  # not a record of a wanted type, or a stale name (another game version)
        counts[k][name[j + 1:]] += 1
        named[name[:j]].add(name[j + 1:])
    per_type = Counter(record_type[r] for r in named)
    extra = read_extra_flats(extra_flats_path)
    types = OrderedDict()
    core: dict[int, set] = {}
    known = type_names(db, CLONED_TYPES)
    for k in sorted(wanted, key=lambda key: CLONED_TYPES.index(known[key]) if key in known else -1):
        t = known.get(k)
        if t is None:
            raise CollisionError(f"$base record type {k} is not one the packs clone ({', '.join(CLONED_TYPES)})")
        # An extra flat is never required on a record (crackLockDifficulty: most cars, no bike).
        ex = set(extra.get(tdb.fnv1a64(f"gamedata{t}_Record"), []))
        core[k] = {p for p, c in counts[k].items() if c >= CORE_SHARE * per_type[k]} | ex
        types[t] = OrderedDict([("namedRecords", per_type[k]), ("properties", sorted(core[k] - ex)),
                                ("extraFlats", sorted(ex))])
    records = OrderedDict()
    for base in sorted(bases):
        records[base] = sorted(named.get(base, set()) - core[db.record_type(id_of(base))])
    with open(extra_flats_path, "rb") as fh:
        extra_sha = hashlib.sha256(fh.read()).hexdigest()
    return OrderedDict([
        ("schema", PROPERTIES_SCHEMA),
        ("note", "Properties TweakXL gives a record cloned from a $base, per record type: the properties named "
                 f"(WolvenKit tweakdbstr) on at least {CORE_SHARE:g} of the type's records and present in tweakdb.bin, "
                 "plus TweakXL's extra flats for the type; `records` lists every $base the packs clone and the "
                 "flats it alone carries. Verified against tweakdb.bin on every run; regenerate with "
                 "make_stages.py --names. collisions.py checks every id these give."),
        ("extraFlatsSha256", extra_sha),
        ("types", types),
        ("records", records),
    ])


# --------------------------------------------------------------------------- collision check
def created_ids(db, props, yamls) -> tuple[dict[int, str], list[tuple[str, str, int]]]:
    """id -> the name that creates it, for every record of `yamls` (parsed YAMLs, in TweakXL's order)
    and every flat TweakXL gives it; and the pairs of different names sharing one id."""
    keys = type_names(db, props["types"])
    owner: dict[int, str] = {}
    twins: list[tuple[str, str, int]] = []
    cache: dict[str, tuple[str, ...]] = {}

    def add(i: int, name: str) -> None:
        held = owner.get(i)
        if held is None:
            owner[i] = name
        elif held != name:
            twins.append((name, held, i))

    for recs in yamls:
        for name, flats in recs.items():
            rid = id_of(name)
            add(rid, name)
            base = flats.get("$base")
            if not isinstance(base, str):
                continue
            if base not in cache:
                cache[base] = flats_of(db, props, base, keys)
            for p in dict.fromkeys(cache[base] + tuple(f for f in flats if f != "$base")):
                add(tdb.tdbid_append(rid, "." + p), f"{name}.{p}")
    return owner, twins


def check(db, props, *yamls) -> list[str]:
    """Every TweakDBID collision of the records `yamls` create, among themselves and with the game."""
    owner, twins = created_ids(db, props, yamls)
    errors = [f"TweakDBID collision: {a} and {b} are one id ({describe(i)})" for a, b, i in twins]
    for i, name in owner.items():
        what = is_vanilla(db, i)
        if what:
            errors.append(f"TweakDBID collision: {name} is the id of a vanilla {what} of the game's TweakDB "
                          f"({describe(i)})")
    return errors


def verify_declared(db, props, stage_recs, sound_recs, present_models, dealer_records, base_of) -> list[str]:
    """Each DECLARED entry still justified: its canonical record would collide exactly as stated, it is
    an extended model's, and it is dropped (sound) or renamed (stage) in the output.
    `base_of(canonical record) -> $base` names the vanilla record it would clone.
    `sound_recs` None: a stage-only build, the sound entries are not judged."""
    errors = []
    keys = type_names(db, props["types"])
    shipped = set(stage_recs) | set(sound_recs or ())
    for c in DECLARED:
        model = model_of(c.record)
        if model not in present_models or (c.kind == "sound" and sound_recs is None):
            continue
        tag = f"declared collision {c.record}"
        if model in dealer_records:
            errors.append(f"{tag}: a dealer record is never dropped or renamed")
            continue
        i = id_of(f"{c.record}.{c.flat}" if c.flat else c.record)
        if i != (c.size << 32 | c.crc):
            errors.append(f"{tag}: {c.flat or 'record id'} is {describe(i)}, declared CRC32 {c.crc:#010x}, "
                          f"length {c.size}: stale entry")
            continue
        base = base_of(c.record)
        if c.flat and c.flat not in flats_of(db, props, base, keys):
            errors.append(f"{tag}: {c.flat} is not a property TweakXL gives a clone of {base}: stale entry")
            continue
        if c.where == "vanilla":
            if not is_vanilla(db, i):
                errors.append(f"{tag}: no vanilla flat or record holds {describe(i)} any more: stale entry")
                continue
        elif c.where == "pack":
            if id_of(c.partner) != i or c.partner.rsplit(".", 1)[0] not in shipped:
                errors.append(f"{tag}: its partner {c.partner} is not a shipped name with that id: stale entry")
                continue
        else:
            errors.append(f"{tag}: unknown partner kind {c.where!r}")
            continue
        if c.kind == "sound":
            if c.record in (sound_recs or {}):
                errors.append(f"{tag}: excluded combination present in the engine-sound YAML")
        elif c.kind == "stage":
            if c.record in stage_recs or c.renamed not in stage_recs:
                errors.append(f"{tag}: must be renamed {c.renamed} in the stage YAML")
        else:
            errors.append(f"{tag}: unknown kind {c.kind!r}")
    return errors


def model_of(record: str) -> str:
    """The vanilla model record of a pack record name (`..._o77...` cut)."""
    i = record.rfind("_o77")
    return record[:i] if i > 0 else record


# --------------------------------------------------------------------------- STAGES.md
DOC_BEGIN = "<!-- BEGIN GENERATED COLLISIONS: make_stages.py --update-doc -->"
DOC_END = "<!-- END GENERATED COLLISIONS -->"


def render_doc() -> str:
    out = ["| Kind | Record the generator would write | Colliding id | CRC32 / length | Held by | Resolution |",
           "|---|---|---|---|---|---|"]
    for c in DECLARED:
        held = f"vanilla `{c.partner}`" if c.where == "vanilla" else f"pack `{c.partner}`"
        if c.kind == "sound":
            m = c.record[len(model_of(c.record)):]
            stage = m[len("_o77s"):m.index("a")] if m.startswith("_o77s") else "0"
            fix = f"dropped: sound s{int(m[m.index('a') + 1:]):02d} does not cover stage {stage} of this model"
        else:
            fix = f"renamed `{c.renamed}` (only its stage record names it; no hole)"
        out.append(f"| {c.kind} | `{c.record}` | `.{c.flat}` | {c.crc:#010x} / {c.size} | {held} | {fix} |")
    return "\n".join(out) + "\n"
