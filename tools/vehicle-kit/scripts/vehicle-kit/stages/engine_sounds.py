"""Light RP engine sounds (wave 2, W2.3): TweakXL records per (dealer model, stage, sound).

An engine sound is a vanilla audio set, the pair of String flats `player_audio_resource` and
`traffic_audio_resource` every `Vehicle` record carries (engine, gearbox, horn: the whole set).
A car takes another set by being respawned as another record (`respawnAs`, like a stage):

    Vehicle.<dealer record>_o77a<k>       $base <dealer record>   the 2 audio flats of sound k
    Vehicle.<dealer record>_o77s<n>a<k>   $base <dealer record>   the stage n links + the 2 audio flats

`$base` is always the vanilla dealer record, never the stage record: TweakXL then never has to
resolve a `$base` another tweak creates. A sound record of stage n copies the stage record's link
flats exactly (`vehEngineData`, `vehDriveModelData` or `bikeDriveModelData`, which point at the
`_o77sN_*` sub-records of the stage YAML) and changes nothing else.

The matrix is bounded: the models of make_stages.MODELS only (the 15 dealer models the Auto
Studio sells, then the extended models of extended-models.json: every other vanilla
`Vehicle.*_player*` car and bike record), stages 0..3, the sounds of the model's own class (car
sounds on cars, bike sounds on bikes), and nothing more. `$base` is the model's own vanilla
record (the "dealer record" below), whether it is sold by a dealer or not. A sound equal to the model's factory set is still generated, so the
server can compose any (model, stage, sound) without a special case. The one exception is data:
a combination whose record would collide with another TweakDBID (collisions.py, STAGES.md "TweakDBID
collisions") is not generated, `missing` lists it, and the sound's coverage omits that stage for that
model, so the server never composes it (`VehicleEngineSound.Covers` is false there).

Curation rules, enforced by `check_catalogue` against tweakdb.bin:
- the set and its traffic twin occur together on at least one vanilla record of the class;
- never the three special vehicles (Basilisk, metro, rollercoaster), never a police, NCPD,
  MaxTac or story-only set, never a set named after a real-world licensed brand;
- neutral labels: no word of any vanilla set name except plain engineering words.

This module is imported by make_stages.py, which owns the command line (`--out-dir` writes both
YAMLs, `--check-sounds` validates an existing sound YAML).
"""
from __future__ import annotations

import copy
import json
import re
from collections import Counter, OrderedDict, defaultdict

import tdb

GENERATOR_VERSION = 1
YAML_NAME = "open77-lightrp-engine-sounds.yaml"
ZIP_ENTRY = "r6/tweaks/LightRP/" + YAML_NAME
AUDIO_FLATS = ("player_audio_resource", "traffic_audio_resource")
MAX_PER_CLASS = {"car": 12, "bike": 6}
LABEL_MAX = 32

# --------------------------------------------------------------------------- catalogue
# Append-only: an id never changes meaning and is never reused (a car saved with "s06" must keep
# the same sound). Index k = the number in the id; the record suffix is a<k>.
# Labels are PROVISIONAL (written from the source vehicles' engine data, maxRPM and torque, not
# by ear): confirm each one in game before the studio shows it. `set` stays internal.
SOUNDS = (
    # id     label                      class   player set                         traffic set
    ("s01", "Compact, city buzz",       "car",  "v_car_makigai_maimai",            "v_car_makigai_maimai_traffic"),
    ("s02", "Sport six, turbo",         "car",  "v_car_mizutani_shion",            "v_car_mizutani_shion_traffic"),
    ("s03", "Muscle V8, open pipes",    "car",  "v_car_quadra_type_66",            "v_car_quadra_type_66_traffic"),
    ("s04", "Cruiser V8, low rumble",   "car",  "v_car_villefort_alvarado",        "v_car_villefort_alvarado_traffic"),
    ("s05", "Luxury V8, smooth",        "car",  "v_car_chevalier_emperor",         "v_car_chevalier_emperor_traffic"),
    ("s06", "Sport coupe, high revs",   "car",  "v_car_herrera_riptide",           "v_car_herrera_riptide_traffic"),
    ("s07", "Electric, high whine",     "car",  "v_car_rayfield_caliburn",         "v_car_rayfield_caliburn_traffic"),
    ("s08", "Supercar, wide open",      "car",  "v_car_herrera_outlaw",            "v_car_herrera_outlaw_traffic"),
    ("s09", "Turbo sport, hard-edged",  "car",  "v_car_quadra_turbo_r",            "v_car_quadra_turbo_r_traffic"),
    ("s10", "Pickup V8, gruff",         "car",  "v_car_thorton_mackinaw",          "v_car_thorton_mackinaw_traffic"),
    ("s11", "Heavy diesel",             "car",  "v_car_kaukaz_bratsk",             "v_car_kaukaz_bratsk_traffic"),
    ("s12", "Armoured, heavy",          "car",  "v_car_militech_hellhound",        "v_car_militech_hellhound_traffic"),
    ("s13", "Sport bike, high revs",    "bike", "v_mbike_yaiba_asmx_kusanagi",     "v_mbike_yaiba_asmx_kusanagi_traffic"),
    ("s14", "Heavy twin, deep thump",   "bike", "v_mbike_arch_nazare",             "v_mbike_arch_nazare_traffic"),
    ("s15", "Chopper, open pipes",      "bike", "v_mbike_arch_nazare_chopper",     "v_mbike_arch_nazare_chopper_traffic"),
    ("s16", "Street bike, raspy",       "bike", "v_mbike_brennan_cycles_apollo",   "v_mbike_brennan_cycles_apollo_traffic"),
)
# The three special vehicles. Metro and rollercoaster are typed Car in tweakdb.bin, so the class
# rule alone would not keep them out.
SPECIAL_SETS = frozenset({"v_av_basilisk_tank", "v_metro_train", "v_mq006_rollercoaster"})
# A set whose name holds one of these words is never offered: law enforcement, story-only or
# weaponised variants, and real-world licensed brands (the game licenses them for one car).
EXCLUDED_TOKENS = frozenset({
    "police", "ncu", "maxtac", "sheriff", "border", "patrol", "q204", "sq011", "mq006", "rocket", "missle",
    "basilisk", "tank", "metro", "train", "rollercoaster", "av", "atilla", "porsche", "911",
})
# Words of vanilla set names that are plain engineering or body words, allowed in a label. Every
# other word of every vanilla set name (makes, models, gangs, story codes) is a brand token.
GENERIC_TOKENS = frozenset({
    "v", "car", "mbike", "cycles", "traffic", "sport", "turbo", "type", "r", "gt", "pickup", "wagon",
    "cabrio", "chopper", "secondary", "alt", "red", "poor", "nomad", "police", "train", "tank",
    "rocket", "missle", "av", "metro", "rollercoaster", "barrels",
})
# Make and model words that may not appear in any vanilla set name (dealer labels, real brands).
EXTRA_BRAND_TOKENS = frozenset({"porsche", "911", "tygerclaws", "valentinos", "maelstrom", "arasaka",
                                "militech", "kangtao", "delamain", "sti", "targa"})

ID_RE = re.compile(r"^s(\d{2})$")
SET_RE = re.compile(r"^v_[a-z0-9_]+$")
LABEL_RE = re.compile(r"^[A-Z][A-Za-z0-9 ,'-]*$")
NAME_RE = re.compile(r"^(?P<base>Vehicle\.[A-Za-z0-9_]+?)_o77(?:s(?P<stage>[1-9]))?a(?P<index>[1-9][0-9]?)$")


class SoundError(Exception):
    pass


def index_of(sound_id: str) -> int:
    m = ID_RE.match(sound_id)
    if not m or int(m.group(1)) == 0:
        raise SoundError(f"sound id {sound_id!r} is not s01..s99")
    return int(m.group(1))


def sound_name(record: str, stage: int, index: int) -> str:
    return f"{record}_o77" + (f"s{stage}" if stage else "") + f"a{index}"


def words(text: str) -> list[str]:
    return re.findall(r"[a-z0-9]+", text.lower())


# --------------------------------------------------------------------------- vanilla scan
class VanillaAudio:
    """Every vanilla Vehicle record's class (`type` -> enumName) and audio pair, from tweakdb.bin."""

    def __init__(self, db: tdb.LayeredTweakDB):
        key = tdb.record_type_key("gamedataVehicle_Record")
        self.pairs: dict[tuple[str, str], Counter] = defaultdict(Counter)   # (player, traffic) -> class counts
        self.player: dict[str, Counter] = defaultdict(Counter)              # player set -> class counts
        self.class_of_record: dict[int, str | None] = {}
        for rid in db.record_ids():
            if db.record_type(rid) != key:
                continue
            cls = self.vehicle_class(db, rid)
            self.class_of_record[rid] = cls
            p, t = db.prop(rid, AUDIO_FLATS[0]), db.prop(rid, AUDIO_FLATS[1])
            if isinstance(p, str) and p:
                self.player[p][cls] += 1
                if isinstance(t, str) and t:
                    self.pairs[(p, t)][cls] += 1
        self.brand_tokens = set(EXTRA_BRAND_TOKENS)
        for (p, t) in self.pairs:
            for name in (p, t):
                self.brand_tokens.update(w for w in name.split("_") if w and w not in GENERIC_TOKENS)

    @staticmethod
    def vehicle_class(db: tdb.LayeredTweakDB, rid: int) -> str | None:
        """'car', 'bike', 'panzer' or None: the enumName of the record the `type` flat points at."""
        v = db.prop(rid, "type")
        if not isinstance(v, int) or not (v & tdb.ID_MASK):
            return None
        name = db.prop(v & tdb.ID_MASK, "enumName")
        return name.lower() if isinstance(name, str) and name else None


# --------------------------------------------------------------------------- catalogue checks
def check_catalogue(sounds, vanilla: VanillaAudio, model_labels=()) -> list[str]:
    errors: list[str] = []
    err = errors.append
    ids, labels, sets = set(), set(), set()
    per_class: Counter = Counter()
    brand = set(vanilla.brand_tokens)
    for label in model_labels:
        # A model label's make and model words are brands; its plain words (Sport, Turbo,
        # Pickup... of the extended records' labels) stay allowed, as in a vanilla set name.
        brand.update(w for w in words(label) if w not in GENERIC_TOKENS)
    for sid, label, cls, player, traffic in sounds:
        tag = f"sound {sid}"
        try:
            index_of(sid)
        except SoundError as e:
            err(str(e))
            continue
        if sid in ids:
            err(f"{tag}: duplicate id")
        ids.add(sid)
        if cls not in MAX_PER_CLASS:
            err(f"{tag}: class {cls!r} is not car or bike")
            continue
        per_class[cls] += 1
        if not LABEL_RE.match(label) or len(label) > LABEL_MAX:
            err(f"{tag}: label {label!r} is not a short plain label (<= {LABEL_MAX} chars, letters, digits, ', -)")
        if label.lower() in labels:
            err(f"{tag}: duplicate label {label!r}")
        labels.add(label.lower())
        bad = sorted(w for w in words(label) if w in brand)
        if bad:
            err(f"{tag}: brand or model word in label {label!r}: {', '.join(bad)}")
        for s in (player, traffic):
            if not SET_RE.match(s):
                err(f"{tag}: set name {s!r} is not v_<lowercase>")
        if player in SPECIAL_SETS or traffic in SPECIAL_SETS:
            err(f"{tag}: special vehicle set {player} (Basilisk, metro and rollercoaster are never offered)")
        hit = sorted(w for w in set(player.split("_")) | set(traffic.split("_")) if w in EXCLUDED_TOKENS)
        if hit:
            err(f"{tag}: excluded set {player} ({', '.join(hit)})")
        if player in sets:
            err(f"{tag}: set {player} listed twice")
        sets.add(player)
        if player not in vanilla.player:
            err(f"{tag}: set {player} is not used by any vanilla Vehicle record")
            continue
        classes = vanilla.player[player]
        if "panzer" in classes:
            err(f"{tag}: set {player} is used by a Panzer record (special vehicle)")
        if classes.get(cls, 0) == 0:
            err(f"{tag}: class mismatch, set {player} is never used by a vanilla {cls} record ({dict(classes)})")
        if vanilla.pairs.get((player, traffic), Counter()).get(cls, 0) == 0:
            err(f"{tag}: audio pair {player} + {traffic} never occurs together on a vanilla {cls} record")
    for cls, n in per_class.items():
        if n > MAX_PER_CLASS[cls]:
            err(f"{n} {cls} sounds, the curated maximum is {MAX_PER_CLASS[cls]}")
    return errors


# --------------------------------------------------------------------------- records
def link_flats(stage_recs, record: str, stage: int, stage_name) -> "OrderedDict[str, str]":
    """The flats a stage record sets besides $base (its links to the _o77sN_* sub-records)."""
    if stage == 0:
        return OrderedDict()
    rec = stage_recs.get(stage_name(record, stage))
    if rec is None:
        raise SoundError(f"stage record {stage_name(record, stage)} missing from the stage YAML")
    return OrderedDict((k, v) for k, v in rec.items() if k != "$base")


def expected_names(models, stages, sounds=SOUNDS, excluded=frozenset()) -> list[str]:
    """Every (model, stage, sound of its class) record name, but the declared exclusions."""
    out = []
    for key, label, record, ladder in models:
        for stage in (0,) + tuple(stages):
            for sid, _, cls, _, _ in sounds:
                if cls == ladder and sound_name(record, stage, index_of(sid)) not in excluded:
                    out.append(sound_name(record, stage, index_of(sid)))
    return out


def missing(models, stages, excluded, sounds=SOUNDS) -> "OrderedDict[str, OrderedDict[int, list[str]]]":
    """The declared exclusions of this build: model record -> stage -> sound ids not generated."""
    out: OrderedDict = OrderedDict()
    for key, label, record, ladder in models:
        for stage in (0,) + tuple(stages):
            for sid, _, cls, _, _ in sounds:
                if cls == ladder and sound_name(record, stage, index_of(sid)) in excluded:
                    out.setdefault(record, OrderedDict()).setdefault(stage, []).append(sid)
    return out


def build_records(models, stages, stage_recs, stage_name, sounds=SOUNDS,
                  excluded=frozenset()) -> "OrderedDict[str, OrderedDict]":
    """models: (key, label, record, ladder) of every staged model, in catalogue order. A record
    named in `excluded` (collisions.SOUND_EXCLUSIONS) is not generated."""
    recs: OrderedDict[str, OrderedDict] = OrderedDict()
    for key, label, record, ladder in models:
        for stage in (0,) + tuple(stages):
            links = link_flats(stage_recs, record, stage, stage_name)
            for sid, _, cls, player, traffic in sounds:
                if cls != ladder or sound_name(record, stage, index_of(sid)) in excluded:
                    continue
                flats = OrderedDict([("$base", record)])
                flats.update(links)
                flats[AUDIO_FLATS[0]] = player
                flats[AUDIO_FLATS[1]] = traffic
                recs[sound_name(record, stage, index_of(sid))] = flats
    return recs


def render_yaml(models, recs, sounds=SOUNDS, extended=frozenset(), marker=()) -> str:
    """`marker` lines go once before the first model whose record is in `extended`, so the part
    above (the dealer models) is byte-identical to a dealer-only build."""
    lines = [
        "# Open77 Light RP engine sounds: TweakXL records derived from the dealer models.",
        f"# GENERATED by scripts/vehicle-kit/stages/make_stages.py (engine_sounds v{GENERATOR_VERSION}). Do not edit:",
        "# change the generator and rebuild with scripts/vehicle-kit/stages/build-stages.ps1.",
        "# Vehicle.<dealer record>_o77a<k> = factory stage with sound k; _o77s<n>a<k> = stage n with sound k.",
        "# $base is always the dealer record; a stage-n record repeats the stage record's links to the",
        "# _o77sN_* sub-records of open77-lightrp-stages.yaml. Only player_audio_resource and",
        "# traffic_audio_resource differ from the stage. No vanilla record is modified.",
        "# Sounds: " + ", ".join(f"a{index_of(s[0])}={s[0]}" for s in sounds),
        "",
    ]
    by_model: dict[str, list[str]] = defaultdict(list)
    for name in recs:
        m = NAME_RE.match(name)
        by_model[m.group("base") if m else ""].append(name)
    marked = False
    for key, label, record, ladder in models:
        if record in extended and not marked:
            lines += list(marker)
            marked = True
        lines.append(f"# ---- {key} ({ladder}): {record}")
        for name in by_model.get(record, []):
            lines.append(f"{name}:")
            for flat, v in recs[name].items():
                lines.append(f"  {flat}: {v}")
            lines.append("")
    return "\n".join(lines).rstrip("\n") + "\n"


def _flat_type(db: tdb.LayeredTweakDB, fid: int) -> str | None:
    fid &= tdb.ID_MASK
    for layer in reversed(db.layers):
        packed = layer.flats.get(fid)
        if packed is not None:
            return layer.pools[packed >> 32].name
    return None


def check_records(db, vanilla: VanillaAudio, models, stages, stage_recs, stage_name, recs,
                  sounds=SOUNDS, known=None, excluded=frozenset()) -> list[str]:
    """Validate parsed sound records against tweakdb.bin, the stage YAML and the catalogue. A
    missing combination is accepted only when `excluded` (collisions.SOUND_EXCLUSIONS: declared,
    collision-justified, listed in STAGES.md) names it, and such a record must then be absent."""
    errors: list[str] = []
    err = errors.append
    known = known if known is not None else db.record_ids()
    model_of = {m[2]: m for m in models}
    by_index = {index_of(s[0]): s for s in sounds}
    audio_types: dict[str, dict[str, str | None]] = {}
    for key, label, record, ladder in models:
        rid = tdb.tdbid(record) & tdb.ID_MASK
        cls = vanilla.class_of_record.get(rid)
        if cls != ladder:
            err(f"{record}: model class {ladder} but tweakdb.bin types it {cls!r}")
        audio_types[record] = {f: _flat_type(db, tdb.tdbid_append(rid, "." + f)) for f in AUDIO_FLATS}
        for f, t in audio_types[record].items():
            if t != "String":
                err(f"{record}: flat {f} is {t} in tweakdb.bin, expected String")
    for name, flats in recs.items():
        if (tdb.tdbid(name) & tdb.ID_MASK) in known:
            err(f"vanilla record {name} would be modified in place (the id already exists in tweakdb.bin)")
            continue
        if name in excluded:
            err(f"{name}: excluded combination present (a declared TweakDBID collision, STAGES.md)")
            continue
        m = NAME_RE.match(name)
        if not m:
            err(f"unknown record name {name}: not Vehicle.<dealer record>_o77[s<n>]a<k>")
            continue
        base, stage, index = m.group("base"), int(m.group("stage") or 0), int(m.group("index"))
        model = model_of.get(base)
        if model is None:
            err(f"unknown record {name}: {base} is not a staged model (dealer or extended)")
            continue
        if stage and stage not in stages:
            err(f"unknown record {name}: stage {stage} outside {tuple(stages)}")
            continue
        sound = by_index.get(index)
        if sound is None:
            err(f"unknown record {name}: sound a{index} is not in the catalogue")
            continue
        sid, _, cls, player, traffic = sound
        if cls != model[3]:
            err(f"{name}: class mismatch, {sid} is a {cls} sound on a {model[3]}")
            continue
        if flats.get("$base") != base:
            err(f"{name}: $base must be the dealer record {base}, found {flats.get('$base')!r}")
            continue
        want = link_flats(stage_recs, base, stage, stage_name)
        for flat, value in flats.items():
            if flat == "$base":
                continue
            if flat in AUDIO_FLATS:
                expect = player if flat == AUDIO_FLATS[0] else traffic
                if value != expect:
                    err(f"{name}: audio flat {flat} = {value!r}, the catalogue says {expect} for {sid}")
                continue
            if flat not in want:
                err(f"{name}: flat not allowed {flat} (a sound record changes only the two audio flats)")
                continue
            if value != want[flat]:
                err(f"{name}: stage link mismatch, {flat} -> {value!r} but stage record "
                    f"{stage_name(base, stage) if stage else base} says {want[flat]!r}")
        for flat in list(want) + list(AUDIO_FLATS):
            if flat not in flats:
                err(f"{name}: flat {flat} missing")
    if errors:
        return errors
    expected = expected_names(models, stages, sounds, excluded)
    absent = [n for n in expected if n not in recs]
    extra = [n for n in recs if n not in set(expected)]
    if absent:
        err(f"missing combination: {len(absent)} record(s), first {absent[0]} (only a declared, "
            "collision-justified exclusion may be missing)")
    if extra:
        err(f"extra combination: {len(extra)} record(s), first {extra[0]}")
    return errors


# --------------------------------------------------------------------------- negative tests
def _first(recs, pattern):
    rx = re.compile(pattern)
    for name in recs:
        if rx.search(name):
            return name
    raise SoundError(f"no record matching {pattern} to mutate")


def _rename(recs, old, new):
    items = [(new if k == old else k, v) for k, v in recs.items()]
    recs.clear()
    recs.update(items)


def _bike_index(sounds):
    return next(index_of(s[0]) for s in sounds if s[2] == "bike")


def _other_stage_engine(recs, stage_recs):
    name = _first(recs, r"_o77s2a\d+$")
    if "vehEngineData" not in recs[name]:
        name = next(n for n in recs if re.search(r"_o77s2a\d+$", n) and "vehEngineData" in recs[n])
    recs[name]["vehEngineData"] = recs[name]["vehEngineData"].replace("_o77s2_", "_o77s1_")


RECORD_MUTATIONS = (
    # (label, expected error substring, mutate(recs, models, stage_recs))
    ("class mismatch", "class mismatch",
     lambda r, m, s: _rename(r, _first(r, r"_o77a1$"), _first(r, r"_o77a1$")[:-1] + str(_bike_index(SOUNDS)))),
    ("flat not allowed", "flat not allowed", lambda r, m, s: r[_first(r, r"_o77a\d+$")].__setitem__("vehicleUIData", "Vehicle.o77_ui")),
    ("stage link mismatch", "stage link mismatch", lambda r, m, s: _other_stage_engine(r, s)),
    ("missing combination", "missing combination", lambda r, m, s: r.pop(_first(r, r"_o77s3a\d+$"))),
    ("extra combination", "unknown record",
     lambda r, m, s: r.__setitem__("Vehicle.v_standard2_archer_hella_police_o77a1",
                                   OrderedDict([("$base", "Vehicle.v_standard2_archer_hella_police")]))),
    ("vanilla in place", "modified in place", lambda r, m, s: _rename(r, _first(r, r"_o77a1$"), m[0][2])),
    ("wrong $base", "$base must be", lambda r, m, s: r[_first(r, r"_o77s1a\d+$")].__setitem__(
        "$base", _first(r, r"_o77s1a\d+$").rsplit("a", 1)[0])),
    ("audio set swapped", "audio flat", lambda r, m, s: r[_first(r, r"_o77a1$")].__setitem__(AUDIO_FLATS[0], "v_car_villefort_cortes")),
)


def _replace(sounds, i, **kw):
    out = [list(s) for s in sounds]
    cols = {"id": 0, "label": 1, "cls": 2, "player": 3, "traffic": 4}
    for k, v in kw.items():
        out[i][cols[k]] = v
    return tuple(tuple(s) for s in out)


CATALOGUE_MUTATIONS = (
    # (label, expected error substring, mutate(sounds) -> sounds)
    ("special vehicle", "special vehicle", lambda s: _replace(s, 0, player="v_av_basilisk_tank", traffic="v_av_basilisk_tank_traffic")),
    ("metro typed Car", "special vehicle", lambda s: _replace(s, 0, player="v_metro_train", traffic="v_metro_train")),
    ("police set", "excluded set", lambda s: _replace(s, 0, player="v_car_archer_hella_police", traffic="v_car_archer_hella_police_traffic")),
    ("brand label", "brand or model word", lambda s: _replace(s, 0, label="Quadra V8, open pipes")),
    ("dealer model label", "brand or model word", lambda s: _replace(s, 0, label="Galena buzz")),
    ("unknown set", "not used by any vanilla", lambda s: _replace(s, 0, player="v_car_o77_no_such_set", traffic="v_car_o77_no_such_set_traffic")),
    ("bike set on a car", "class mismatch", lambda s: _replace(s, 0, player="v_mbike_arch_nazare", traffic="v_mbike_arch_nazare_traffic")),
    ("unpaired traffic", "never occurs together", lambda s: _replace(s, 0, traffic="v_car_kaukaz_bratsk_traffic")),
    ("duplicate id", "duplicate id", lambda s: _replace(s, 1, id=s[0][0])),
)


def _put_back(recs, models, stage_recs, stage_name, excluded) -> frozenset:
    """A declared exclusion of this build generated anyway; without one (a dealer-only build),
    an undeclared name in the excluded set: the first record's."""
    present = {m[2] for m in models}
    name = next((n for n in sorted(excluded) if NAME_RE.match(n) and NAME_RE.match(n).group("base") in present), None)
    if name is None:
        excluded = frozenset(excluded) | {next(iter(recs))}
        return excluded
    m = NAME_RE.match(name)
    base, stage, index = m.group("base"), int(m.group("stage") or 0), int(m.group("index"))
    sound = next(s for s in SOUNDS if index_of(s[0]) == index)
    flats = OrderedDict([("$base", base)])
    flats.update(link_flats(stage_recs, base, stage, stage_name))
    flats[AUDIO_FLATS[0]], flats[AUDIO_FLATS[1]] = sound[3], sound[4]
    recs[name] = flats
    return excluded


def negative_tests(db, vanilla, models, stages, stage_recs, stage_name, recs, model_labels=(), known=None,
                   excluded=frozenset()) -> tuple[list[str], int]:
    failures = []
    known = known if known is not None else db.record_ids()
    for label, expect, mutate in RECORD_MUTATIONS:
        broken = copy.deepcopy(recs)
        mutate(broken, models, stage_recs)
        errs = check_records(db, vanilla, models, stages, stage_recs, stage_name, broken, known=known,
                             excluded=excluded)
        if not any(expect in e for e in errs):
            failures.append(f"negative test '{label}' was not refused as '{expect}' (got: {errs[:3]})")
    # A declared exclusion generated anyway is refused (collisions.py re-measures the collision itself).
    broken = copy.deepcopy(recs)
    judged = _put_back(broken, models, stage_recs, stage_name, excluded)
    errs = check_records(db, vanilla, models, stages, stage_recs, stage_name, broken, known=known, excluded=judged)
    if not any("excluded combination present" in e for e in errs):
        failures.append(f"negative test 'excluded combination present' was not refused (got: {errs[:3]})")
    for label, expect, mutate in CATALOGUE_MUTATIONS:
        errs = check_catalogue(mutate(SOUNDS), vanilla, model_labels)
        if not any(expect in e for e in errs):
            failures.append(f"negative test '{label}' was not refused as '{expect}' (got: {errs[:3]})")
    return failures, len(RECORD_MUTATIONS) + 1 + len(CATALOGUE_MUTATIONS)


# --------------------------------------------------------------------------- outputs
def factory_sets(db, models) -> dict[str, tuple[str, str]]:
    out = {}
    for key, label, record, ladder in models:
        rid = tdb.tdbid(record) & tdb.ID_MASK
        out[record] = (db.prop(rid, AUDIO_FLATS[0]), db.prop(rid, AUDIO_FLATS[1]))
    return out


def _lua_str(s: str) -> str:
    if "'" in s or "\\" in s or "\n" in s:
        raise SoundError(f"cannot write {s!r} as a plain Lua string")
    return f"'{s}'"


def render_lua(models, stages, factory, yaml_sha: str, sounds=SOUNDS, missing=None) -> str:
    lines = [
        "-- GENERATED by scripts/vehicle-kit/stages/make_stages.py (engine_sounds) -- do not edit.",
        "-- Light RP engine sounds: the TweakXL records shipped by this resource's preload_mod.",
        "-- Record of model M at stage n (0..maxStage) with sound s: M .. '_o77' .. (n > 0 and 's' .. n or '')",
        "-- .. 'a' .. s.index. Labels are provisional until heard in game; `set` stays internal.",
        "LightRpEngineSounds = {",
        f"    generator = {GENERATOR_VERSION},",
        f"    yamlSha256 = '{yaml_sha}',",
        f"    maxStage = {max(stages)},",
        "    sounds = {",
    ]
    for sid, label, cls, player, traffic in sounds:
        lines.append(f"        {{ id = {_lua_str(sid)}, label = {_lua_str(label)}, class = {_lua_str(cls)}, "
                     f"set = {_lua_str(player)}, index = {index_of(sid)} }},")
    lines += ["    },", "    models = {"]
    for key, label, record, ladder in models:
        p, t = factory[record]
        lines.append(f"        [{_lua_str(record)}] = {{ key = {_lua_str(key)}, class = {_lua_str(ladder)}, "
                     f"factorySet = {_lua_str(p)} }},")
    lines += ["    },"]
    # Written only when a combination is missing, so a build without one keeps its bytes.
    if missing:
        lines += ["    -- Combinations the pack does not generate: their record would collide with another",
                  "    -- TweakDBID (STAGES.md, TweakDBID collisions). record -> stage -> sound ids.",
                  "    missing = {"]
        for record, stages_of in missing.items():
            inner = ", ".join(f"[{stage}] = {{ {', '.join(_lua_str(sid) for sid in ids)} }}"
                              for stage, ids in stages_of.items())
            lines.append(f"        [{_lua_str(record)}] = {{ {inner} }},")
        lines += ["    },"]
    lines += ["}"]
    return "\n".join(lines) + "\n"


def manifest(models, stages, recs, factory, yaml_sha: str, yaml_bytes: int, sounds=SOUNDS, missing=None) -> dict:
    per_model = []
    for key, label, record, ladder in models:
        names = [n for n in recs if NAME_RE.match(n).group("base") == record]
        per_model.append(OrderedDict([
            ("key", key), ("record", record), ("class", ladder),
            ("factorySet", factory[record][0]), ("factoryTrafficSet", factory[record][1]),
            ("records", len(names)),
        ]))
    return OrderedDict([
        ("schema", "open77.vehicle-engine-sounds/1"), ("generator", GENERATOR_VERSION),
        ("yaml", OrderedDict([("zipEntry", ZIP_ENTRY), ("sha256", yaml_sha), ("bytes", yaml_bytes),
                              ("records", len(recs))])),
        ("stages", [0] + list(stages)),
        ("sounds", [OrderedDict([("id", s[0]), ("index", index_of(s[0])), ("label", s[1]), ("class", s[2]),
                                 ("set", s[3]), ("trafficSet", s[4]), ("labelStatus", "provisional")])
                    for s in sounds]),
        ("models", per_model),
        ("missing", [OrderedDict([("record", record), ("stage", stage), ("sound", sid),
                                  ("reason", "TweakDBID collision (STAGES.md, collisions.py)")])
                     for record, stages_of in (missing or {}).items() for stage, ids in stages_of.items()
                     for sid in ids]),
        ("policy", OrderedDict([
            ("specialSets", sorted(SPECIAL_SETS)), ("excludedTokens", sorted(EXCLUDED_TOKENS)),
            ("maxPerClass", MAX_PER_CLASS),
        ])),
    ])


def to_json(obj) -> str:
    return json.dumps(obj, indent=2) + "\n"
