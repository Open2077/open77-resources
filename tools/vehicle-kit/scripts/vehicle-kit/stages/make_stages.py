"""Light RP performance stages: TweakXL records derived from vanilla player vehicles (offline).

A stage is a record `Vehicle.<dealer record>_o77s1..s3` (decision D8, experiment E0.8):
TweakXL creates it at game start with `$base` = the dealer record, and points it at new
derived sub-records, so no vanilla record is ever modified in place (many models share
engine, drive-model and wheel records):

    Vehicle.<rec>_o77sN           $base <rec>                 vehEngineData, veh|bikeDriveModelData
    Vehicle.<rec>_o77sN_engine    $base <vanilla engine>      engineMaxTorque
    Vehicle.<rec>_o77sN_drive     $base <vanilla drive model> wheelSetup
    Vehicle.<rec>_o77sN_wheels    $base <vanilla wheel setup> frontPreset, backPreset
    Vehicle.<rec>_o77sN_front     $base <vanilla preset>      brakes, grip, suspension flats
    Vehicle.<rec>_o77sN_back      $base <vanilla preset>      (idem)

Every base value is read from the installed game's `r6/cache/tweakdb.bin` (with
`tweakdb_ep1.bin` layered on top, as the game does) by `../inventory/tdb.py`. Nothing is
written to the game folder. Record names of the vanilla sub-records come from
`base-records.json`, each one verified against the id found in tweakdb.bin; `--names`
regenerates that file from WolvenKit's `tweakdbstr.kark` after a game update.

Usage (repository root; `scripts/vehicle-kit/stages/build-stages.ps1` wraps it):

    uv run --no-project python -I scripts/vehicle-kit/stages/make_stages.py --out-dir <dir>
    uv run --no-project python -I scripts/vehicle-kit/stages/make_stages.py --check <yaml>
    uv run --no-project python -I scripts/vehicle-kit/stages/make_stages.py --update-doc

`--game` defaults to OP77_GAME_DIR (process, then user scope). Generation always ends with
the same check `--check` runs: every `$base` exists, every overridden flat exists on its
base record with the expected type, values are finite and within caps, the record graph is
complete, no TweakDBID (CRC32 + length) of a record or of any flat TweakXL gives it collides with
another one of the packs or with the game's TweakDB (collisions.py, record-properties.json), and
nine deliberately broken copies of the YAML are each refused.
See STAGES.md for the rationale, the stage table and the declared collisions.

Engine sounds (wave 2, W2.3) live in `engine_sounds.py` and are written by the same run into a
second YAML, `open77-lightrp-engine-sounds.yaml`: one record per (model, stage 0..3,
sound of the model's class), `Vehicle.<rec>_o77a<k>` and `Vehicle.<rec>_o77s<n>a<k>`. Their check
(`--check-sounds`, also run after every generation) runs the same TweakDBID check on both YAMLs
together, accepts only the missing combinations collisions.py declares, and refuses nineteen
broken copies. `--no-sounds` writes the stage YAML alone.

Models: the 15 Light RP dealer models (DEALER_MODELS, frozen), then the extended models of
`extended-models.json`, every other vanilla `Vehicle.*_player*` car and bike record of the
installed game but the quest variants `Vehicle.q<digits>_*` (`--refresh-models --names <kark>`
rebuilds that list). An extended model is priced on Light RP's scale: its vanilla reference price
x EXTENDED_PRICE_FACTOR before tiering and pricing, each stage then capped at the highest dealer
stage price of its class (the Semimaru for cars, the Kusanagi for bikes). Both YAMLs write the
dealer models first and the extended ones after a `# ==== Extended models` marker, so the dealer
part stays byte-identical to a dealer-only build. `--out-dir` also writes
`lightrp-vehicle-stage-catalogue.lua` (stage prices and sound counts per record, for the Light RP
gamemode); `--lightrp-config <file>` writes the same file there too.
"""
from __future__ import annotations

import argparse
import copy
import hashlib
import json
import math
import os
import re
import sys
from collections import OrderedDict

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(os.path.dirname(HERE), "inventory"))
sys.path.insert(0, HERE)  # python -I does not put the script's folder on sys.path
import tdb  # noqa: E402
import engine_sounds as es  # noqa: E402
import collisions as col  # noqa: E402

GENERATOR_VERSION = 1
YAML_NAME = "open77-lightrp-stages.yaml"
ZIP_ENTRY = "r6/tweaks/LightRP/" + YAML_NAME
BASE_RECORDS = os.path.join(HERE, "base-records.json")
DOC = os.path.join(HERE, "STAGES.md")
DOC_BEGIN = "<!-- BEGIN GENERATED: make_stages.py --update-doc -->"
DOC_END = "<!-- END GENERATED -->"
DOC_EXT_BEGIN = "<!-- BEGIN GENERATED EXTENDED: make_stages.py --update-doc -->"
DOC_EXT_END = "<!-- END GENERATED EXTENDED -->"
LIGHTRP_CATALOGUE = "lightrp-vehicle-stage-catalogue.lua"

# --------------------------------------------------------------------------- catalogue
# Light RP dealer catalogue, the 15 non-staff models. key, label and record come from
# resources/gamemodes/op77_lightrp/shared/config.lua, price from
# server/config/dealerships.lua (light-rp, read 2026-11-05). The price only places a model
# on its class ladder below; it is the owner's number, change it here when it changes there.
# FROZEN: these 15 keep their own ladder (class ceilings among themselves only), so adding the
# extended records below never changes one of their bytes in either YAML.
DEALER_MODELS = (
    # key        label                 record                                             ladder  price
    ("maimai",   "Makigai MaiMai",     "Vehicle.v_standard2_makigai_maimai_player",       "car",   10000),
    ("galena",   "Thorton Galena",     "Vehicle.v_standard2_thorton_galena_player",       "car",   16000),
    ("hella",    "Archer Hella",       "Vehicle.v_standard2_archer_hella_player",         "car",   30000),
    ("colby",    "Thorton Colby",      "Vehicle.v_standard2_thorton_colby_player",        "car",   35000),
    ("supron",   "Mahir Supron",       "Vehicle.v_standard25_mahir_supron_player",        "car",   40000),
    ("quartz",   "Archer Quartz",      "Vehicle.v_standard2_archer_quartz_player",        "car",   47500),
    ("hozuki",   "Mizutani Hozuki",    "Vehicle.v_standard2_mizutani_hozuki_player",      "car",   60000),
    ("columbus", "Villefort Columbus", "Vehicle.v_standard25_villefort_columbus_player",  "car",   75000),
    ("cortes",   "Villefort Cortes",   "Vehicle.v_standard2_villefort_cortes_player",     "car",   95000),
    ("merrimac", "Thorton Merrimac",   "Vehicle.v_standard25_thorton_merrimac_player",    "car",  115000),
    ("bandit",   "Archer Bandit",      "Vehicle.v_standard2_archer_bandit_player",        "car",  130000),
    ("thrax",    "Chevalier Thrax",    "Vehicle.v_standard2_chevalier_thrax_player",      "car",  155000),
    ("semimaru", "Yaiba Semimaru",     "Vehicle.v_sport1_yaiba_semimaru_player",          "car",  250000),
    ("apollo",   "Brennan Apollo",     "Vehicle.v_sportbike3_brennan_apollo_player",      "bike",  12500),
    ("kusanagi", "Yaiba Kusanagi",     "Vehicle.v_sportbike1_yaiba_kusanagi_player",      "bike", 200000),
)
DEALER_RECORDS = frozenset(m[2] for m in DEALER_MODELS)

# Extended models: every other vanilla `Vehicle.*_player*` record of the installed game, cars and
# bikes (no AV, no Panzer), one entry per record (a trim is its own record). The list is a
# reviewed, committed file, like base-records.json: `--refresh-models --names <kark>` rebuilds it
# from tweakdb.bin and WolvenKit's string table; every run re-verifies it against tweakdb.bin
# (record type, class, entity template, and every vanilla price it was derived from).
EXTENDED_MODELS = os.path.join(HERE, "extended-models.json")
EXTENDED_VERSION = 1
PLAYER_RE = re.compile(r"^Vehicle\.[A-Za-z0-9_]*_player[A-Za-z0-9_]*$")
# Quest variants (`Vehicle.q000_hym_player_car`, `Vehicle.q304_songbird_escape_player`): a mission's
# copy of a car, out of scope (owner, 2026-11-07).
QUEST_RE = re.compile(r"^Vehicle\.q[0-9]+_")
VEHICLES_TSV = os.path.join(HERE, "..", "..", "..", "server", "src", "Open77.Server.Core", "Data", "vehicles-2.31.tsv")
# Stage + sound records the two YAMLs may hold together: TweakXL creates every one at game start.
RECORD_BUDGET = 10000
BYTES_BUDGET = 20 * 1024 * 1024


def _load_extended() -> tuple[tuple, dict]:
    if not os.path.isfile(EXTENDED_MODELS):
        return (), {}
    with open(EXTENDED_MODELS, encoding="utf-8") as fh:
        doc = json.load(fh)
    models = tuple((m["key"], m["label"], m["record"], m["ladder"], int(m["price"])) for m in doc["models"])
    return models, doc


EXTENDED_MODEL_TUPLES, EXTENDED_DOC = _load_extended()
MODELS = DEALER_MODELS + EXTENDED_MODEL_TUPLES
# Class ladders: tier = 1 + number of thresholds <= price. Cars and bikes are separate ladders.
TIER_BANDS = {"car": (20000, 50000, 100000, 200000), "bike": (100000,)}

# --------------------------------------------------------------------------- stage policy
STAGES = (1, 2, 3)
# Cumulative multipliers per stage (s1, s2, s3). See STAGES.md, "Stage policy".
ENGINE = {"car": (1.20, 1.40, 1.60), "bike": (1.10, 1.20, 1.30)}   # engineMaxTorque
BRAKES = (1.10, 1.20, 1.30)                                         # maxBrakingTorque, both axles
GRIP = (1.02, 1.04, 1.06)                                           # frictionMulLongitudinal/Lateral
SPRINGS = {"car": (1.05, 1.10, 1.15), "bike": None}                 # springStiffness, swaybarStiffness
# Dampers follow sqrt(spring factor): the damping ratio c / (2 sqrt(k m)) stays the same.
GRIP_MAX = 1.0        # absolute: the best tyre multiplier of any dealer model (Semimaru rear lateral)
TORQUE_MAX = 1600.0   # absolute engineMaxTorque ceiling, Nm
# E0.8, one measured point: engineMaxTorque x2 took the Hella 0->80 km/h from 9.07 s to 6.13 s,
# i.e. +48 % average acceleration. Used only for the "expected effect" column (an estimate).
ACCEL_PER_TORQUE = 0.48
HELLA_0_80_S = 9.07
# Proposed prices (the owner decides): car price x pct x value weight, floor, rounded up to 500.
PRICE_PCT = (0.10, 0.15, 0.20)
PRICE_FLOOR = (1000, 1500, 2000)
PRICE_ROUND = 500
# Extended models (owner, 2026-11-07): their vanilla reference price is on the game's scale, about
# half Light RP's (dealer price / vanilla price of the same record: 0.42x to 4.56x, median 1.94x).
# It is multiplied by this factor before tiering and pricing; each stage price is then capped at
# the highest dealer stage price of the class (dealer_price_caps: Semimaru, Kusanagi).
EXTENDED_PRICE_FACTOR = 2.0


def scaled_price(vanilla: int) -> int:
    """An extended model's price on Light RP's scale (integer, half up)."""
    return int(math.floor(vanilla * EXTENDED_PRICE_FACTOR + 0.5))

PRESET_LEVERS = OrderedDict([
    ("maxBrakingTorque", "brakes"),
    ("frictionMulLongitudinal", "grip"),
    ("frictionMulLateral", "grip"),
    ("springStiffness", "springs"),
    ("swaybarStiffness", "springs"),
    ("springDamping", "dampers"),
    ("springReboundDamping", "dampers"),
    ("springBoundDampingLowRate", "dampers"),
    ("springReboundDampingLowRate", "dampers"),
])
DECIMALS = {"engineMaxTorque": 1, "maxBrakingTorque": 1, "frictionMulLongitudinal": 3,
            "frictionMulLateral": 3, "springStiffness": 2, "swaybarStiffness": 2,
            "springDamping": 0, "springReboundDamping": 0, "springBoundDampingLowRate": 0,
            "springReboundDampingLowRate": 0}

# --------------------------------------------------------------------------- record graph
PART_KIND = {"": "vehicle", "engine": "engine", "drive": "drive", "wheels": "wheels",
             "front": "preset", "back": "preset"}
TYPES = {  # expected TweakDB record type of the $base, per kind and ladder
    "vehicle": {"car": "Vehicle", "bike": "Vehicle"},
    "engine": {"car": "VehicleEngineData", "bike": "VehicleEngineData"},
    "drive": {"car": "VehicleDriveModelData", "bike": "BikeDriveModelData"},
    "wheels": {"car": "VehicleWheelDrivingSetup_4", "bike": "VehicleWheelDrivingSetup_2"},
    "preset": {"car": "VehicleWheelDrivingPreset", "bike": "VehicleWheelDrivingPreset"},
}
TYPE_KEYS = {t: tdb.record_type_key(f"gamedata{t}_Record") for k in TYPES.values() for t in k.values()}
DRIVE_FLAT = {"car": "vehDriveModelData", "bike": "bikeDriveModelData"}
# Whitelist: flat -> (TweakDB flat type, what it points at or which lever it is).
FLATS = {
    "vehicle": {"vehEngineData": ("TweakDBID", "engine"), "vehDriveModelData": ("TweakDBID", "drive"),
                "bikeDriveModelData": ("TweakDBID", "drive")},
    "engine": {"engineMaxTorque": ("Float", "engine")},
    "drive": {"wheelSetup": ("TweakDBID", "wheels")},
    "wheels": {"frontPreset": ("TweakDBID", "front"), "backPreset": ("TweakDBID", "back")},
    "preset": {flat: ("Float", lever) for flat, lever in PRESET_LEVERS.items()},
}
# `_c<k>` after a part: a sub-record renamed because its canonical name collides (collisions.py, declared).
NAME_RE = re.compile(r"^(?P<base>Vehicle\.[A-Za-z0-9_]+?)_o77s(?P<stage>[1-9])"
                     r"(?:_(?P<part>engine|drive|wheels|front|back)(?:_c(?P<salt>[1-9]))?)?$")


class StageError(Exception):
    pass


# --------------------------------------------------------------------------- helpers
def env_both(name: str) -> str | None:
    """Process scope first, then the Windows user scope (agent shells often lack it)."""
    v = os.environ.get(name)
    if v:
        return v
    if sys.platform == "win32":
        import winreg
        try:
            with winreg.OpenKey(winreg.HKEY_CURRENT_USER, "Environment") as key:
                return str(winreg.QueryValueEx(key, name)[0]) or None
        except OSError:
            return None
    return None


def sha256_file(path: str) -> str:
    h = hashlib.sha256()
    with open(path, "rb") as fh:
        for chunk in iter(lambda: fh.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def floor_to(x: float, decimals: int) -> float:
    """Round down at `decimals`: a scaled value never exceeds its cap because of rounding."""
    q = 10 ** decimals
    return math.floor(x * q + 1e-9) / q


def fmt_float(x: float) -> str:
    s = repr(float(x))
    if not math.isfinite(x) or "e" in s or "E" in s:
        raise StageError(f"cannot format {x!r} as a plain YAML float")
    return s if "." in s else s + ".0"


def short(x: float, decimals: int = 1) -> str:
    s = f"{x:.{decimals}f}"
    return s.rstrip("0").rstrip(".") if "." in s else s


def tier_of(ladder: str, price: int) -> int:
    return 1 + sum(1 for b in TIER_BANDS[ladder] if price >= b)


def flat_type(db: tdb.LayeredTweakDB, fid: int) -> str | None:
    """TweakDB type of a flat (`Float`, `TweakDBID`...), last layer first; None if absent."""
    fid &= tdb.ID_MASK
    for layer in reversed(db.layers):
        packed = layer.flats.get(fid)
        if packed is not None:
            return layer.pools[packed >> 32].name
    return None


_KNOWN: dict[int, set[int]] = {}


def known_records(db: tdb.LayeredTweakDB) -> set[int]:
    if id(db) not in _KNOWN:
        _KNOWN[id(db)] = db.record_ids()
    return _KNOWN[id(db)]


def type_name(key: int | None) -> str:
    for t, k in TYPE_KEYS.items():
        if k == key:
            return t
    return f"<type {key}>"


def load_db(game: str) -> tuple[tdb.LayeredTweakDB, list[dict]]:
    files = [os.path.join(game, "r6", "cache", n) for n in ("tweakdb.bin", "tweakdb_ep1.bin")]
    files = [f for f in files if os.path.isfile(f)]
    if not files or not files[0].endswith("tweakdb.bin"):
        raise StageError(f"r6/cache/tweakdb.bin not found under {game}")
    info = [{"file": os.path.relpath(f, game).replace("\\", "/"), "bytes": os.path.getsize(f),
             "sha256": sha256_file(f)} for f in files]
    return tdb.LayeredTweakDB(files), info


# --------------------------------------------------------------------------- base chain
class Chain:
    """The vanilla record chain of one dealer model and the base values the stages scale."""

    ROLES = ("vehicle", "engine", "drive", "wheels", "front", "back")

    def __init__(self, db: tdb.LayeredTweakDB, model: tuple):
        self.key, self.label, self.record, self.ladder, price = model
        self.dealer = self.record in DEALER_RECORDS
        # The vanilla reference price (Autofixer offer, else derived; see reference_prices) and
        # where it came from (a dealer model's is attached by load_plans, for the record only).
        self.ref_price, self.price_source = price, "dealer price"
        # The price tiers and stage prices read, on Light RP's scale: the dealer price, else the
        # vanilla reference price x EXTENDED_PRICE_FACTOR.
        self.price = price if self.dealer else scaled_price(price)
        self.tier = tier_of(self.ladder, self.price)
        ids = {"vehicle": tdb.tdbid(self.record) & tdb.ID_MASK}
        if db.record_type(ids["vehicle"]) != TYPE_KEYS["Vehicle"]:
            raise StageError(f"{self.record}: not a Vehicle record in tweakdb.bin")
        ids["engine"] = self._ref(db, ids["vehicle"], "vehEngineData", self.record)
        ids["drive"] = self._ref(db, ids["vehicle"], DRIVE_FLAT[self.ladder], self.record)
        ids["wheels"] = self._ref(db, ids["drive"], "wheelSetup", self.record)
        ids["front"] = self._ref(db, ids["wheels"], "frontPreset", self.record)
        ids["back"] = self._ref(db, ids["wheels"], "backPreset", self.record)
        for role in self.ROLES[1:]:
            kind = "preset" if role in ("front", "back") else role
            want = TYPES[kind][self.ladder]
            got = db.record_type(ids[role])
            if got != TYPE_KEYS[want]:
                raise StageError(f"{self.record}: {role} record {ids[role]:#x} is {type_name(got)}, expected {want}")
        self.ids = ids
        self.names: dict[str, str] = {"vehicle": self.record}

        def f(rid: int, flat: str) -> float:
            v = db.prop(rid, flat)
            if not isinstance(v, float) or not math.isfinite(v):
                raise StageError(f"{self.record}: flat {flat} of {rid:#x} is {v!r}, expected a finite Float")
            return v

        self.torque = f(ids["engine"], "engineMaxTorque")
        self.final_gear = f(ids["engine"], "finalGearTorqueDecimationScalor")
        self.max_rpm = f(ids["engine"], "maxRPM")
        gears = db.prop(ids["engine"], "gears") or []
        if not gears:
            raise StageError(f"{self.record}: engine has no gears")
        self.top_speed_ms = max(f(g & tdb.ID_MASK, "maxSpeed") for g in gears)
        self.gear_count = len(gears)
        self.mass = f(ids["drive"], "total_mass")
        self.presets = {role: OrderedDict((flat, f(ids[role], flat)) for flat in PRESET_LEVERS)
                        for role in ("front", "back")}

    @staticmethod
    def _ref(db: tdb.LayeredTweakDB, rid: int, flat: str, owner: str) -> int:
        v = db.prop(rid, flat)
        if not isinstance(v, int) or (v & tdb.ID_MASK) == 0:
            raise StageError(f"{owner}: flat {flat} of {rid:#x} is empty ({v!r})")
        return v & tdb.ID_MASK

    def attach_names(self, table: dict) -> None:
        entry = table.get(self.record)
        if not entry:
            raise StageError(f"{self.record}: missing from base-records.json (rerun with --names)")
        for role in self.ROLES[1:]:
            name = entry.get(role)
            if not name or (tdb.tdbid(name) & tdb.ID_MASK) != self.ids[role]:
                raise StageError(f"{self.record}: base-records.json {role}={name!r} does not hash to the "
                                 f"{role} record {self.ids[role]:#x} found in tweakdb.bin "
                                 "(game update? rerun with --names)")
            self.names[role] = name

    @property
    def index(self) -> float:
        """Specific torque at the final drive, Nm per tonne: torque x final scalar / mass."""
        return self.torque * self.final_gear / self.mass * 1000.0

    @property
    def top_speed_kmh(self) -> float:
        return self.top_speed_ms * 3.6


def ceilings(chains: list[Chain], price=lambda c: c.price) -> dict[str, float | None]:
    """Class ceiling: the lowest 'best stock index' of every more expensive tier of the ladder.

    `price` places each chain on its tier: its Light RP-scale price (Chain.price), the dealer price
    for a dealer model and the scaled vanilla reference price for the others."""
    tiers = {c.key: tier_of(c.ladder, price(c)) for c in chains}
    best: dict[tuple[str, int], float] = {}
    for c in chains:
        k = (c.ladder, tiers[c.key])
        best[k] = max(best.get(k, 0.0), c.index)
    out: dict[str, float | None] = {}
    for c in chains:
        above = [v for (lad, t), v in best.items() if lad == c.ladder and t > tiers[c.key]]
        out[c.key] = min(above) if above else None
    return out


class Plan:
    """Per model: the engine factors (after caps) and every stage's target values."""

    def __init__(self, chain: Chain, ceiling: float | None):
        self.c = chain
        self.ceiling = ceiling
        # Extended models only (load_plans): the highest dealer price of each stage of the class.
        self.price_cap: tuple[int, ...] | None = None
        g = ENGINE[chain.ladder]
        f3, reason = g[2], "stage policy"
        if ceiling is not None and chain.index * f3 > ceiling:
            f3, reason = max(1.0, ceiling / chain.index), "class ceiling"
            if f3 == 1.0:
                reason = "class ceiling (stock already at or above it)"
        if chain.torque * f3 > TORQUE_MAX:
            f3, reason = TORQUE_MAX / chain.torque, "absolute torque cap"
        self.engine_reason = reason
        self.engine_factors = tuple(1.0 + (f3 - 1.0) * (gk - 1.0) / (g[2] - 1.0) for gk in g)
        self.stages: dict[int, dict] = {s: self._stage(s) for s in STAGES}

    def factor(self, lever: str, stage: int) -> float | None:
        i = stage - 1
        if lever == "engine":
            return self.engine_factors[i]
        if lever == "brakes":
            return BRAKES[i]
        if lever == "grip":
            return GRIP[i]
        springs = SPRINGS[self.c.ladder]
        if springs is None:
            return None
        if lever == "springs":
            return springs[i]
        if lever == "dampers":
            return math.sqrt(springs[i])
        raise StageError(f"unknown lever {lever}")

    def _stage(self, stage: int) -> dict:
        out: dict = {"torque": None, "presets": {}}
        fe = self.factor("engine", stage)
        if fe > 1.0:
            t = floor_to(self.c.torque * fe, DECIMALS["engineMaxTorque"])
            if t > self.c.torque:
                out["torque"] = t
        for role in ("front", "back"):
            vals = OrderedDict()
            for flat, lever in PRESET_LEVERS.items():
                fac = self.factor(lever, stage)
                if fac is None:
                    continue
                base = self.c.presets[role][flat]
                target = base * fac
                if lever == "grip":
                    target = min(target, GRIP_MAX)
                v = floor_to(target, DECIMALS[flat])
                if v > base:
                    vals[flat] = v
            out["presets"][role] = vals
        return out

    def torque_at(self, stage: int) -> float:
        t = self.stages[stage]["torque"]
        return self.c.torque if t is None else t

    def preset_at(self, stage: int, role: str, flat: str) -> float:
        return self.stages[stage]["presets"][role].get(flat, self.c.presets[role][flat])

    def value_weight(self) -> float:
        g3 = ENGINE[self.c.ladder][2]
        return 0.5 + 0.5 * (self.engine_factors[2] - 1.0) / (g3 - 1.0)

    def uncapped_price(self, stage: int) -> int:
        i = stage - 1
        raw = max(PRICE_FLOOR[i], self.c.price * PRICE_PCT[i] * self.value_weight())
        return int(math.ceil(raw / PRICE_ROUND) * PRICE_ROUND)

    def price(self, stage: int) -> int:
        p = self.uncapped_price(stage)
        return p if self.price_cap is None else min(p, self.price_cap[stage - 1])

    def capped_stages(self) -> list[int]:
        return [s for s in STAGES if self.price(s) < self.uncapped_price(s)]


def dealer_price_caps(plans: list[Plan]) -> dict[str, tuple[int, ...]]:
    """Per ladder, the highest dealer price of each stage: what an extended stage may cost at most."""
    caps: dict[str, tuple[int, ...]] = {}
    for ladder in TIER_BANDS:
        dealers = [p for p in plans if p.c.dealer and p.c.ladder == ladder]
        if dealers:
            caps[ladder] = tuple(max(p.price(s) for p in dealers) for s in STAGES)
    return caps


# --------------------------------------------------------------------------- YAML out/in
def stage_name(record: str, stage: int, part: str = "") -> str:
    """The record of a stage, or of one of its sub-records; a declared rename wins (collisions.py)."""
    name = f"{record}_o77s{stage}" + (f"_{part}" if part else "")
    return col.STAGE_RENAMES.get(name, name)


def build_records(plans: list[Plan]) -> "OrderedDict[str, OrderedDict]":
    recs: OrderedDict[str, OrderedDict] = OrderedDict()
    for p in plans:
        c = p.c
        for s in STAGES:
            st = p.stages[s]
            front = stage_name(c.record, s, "front")
            back = stage_name(c.record, s, "back") if c.ids["back"] != c.ids["front"] else front
            if st["torque"] is not None:
                recs[stage_name(c.record, s, "engine")] = OrderedDict(
                    [("$base", c.names["engine"]), ("engineMaxTorque", st["torque"])])
            recs[front] = OrderedDict([("$base", c.names["front"])] + list(st["presets"]["front"].items()))
            if back != front:
                recs[back] = OrderedDict([("$base", c.names["back"])] + list(st["presets"]["back"].items()))
            recs[stage_name(c.record, s, "wheels")] = OrderedDict(
                [("$base", c.names["wheels"]), ("frontPreset", front), ("backPreset", back)])
            recs[stage_name(c.record, s, "drive")] = OrderedDict(
                [("$base", c.names["drive"]), ("wheelSetup", stage_name(c.record, s, "wheels"))])
            veh = OrderedDict([("$base", c.record)])
            if st["torque"] is not None:
                veh["vehEngineData"] = stage_name(c.record, s, "engine")
            veh[DRIVE_FLAT[c.ladder]] = stage_name(c.record, s, "drive")
            recs[stage_name(c.record, s)] = veh
    return recs


# Written once, before the first extended model, in both YAMLs. The dealer part above it is
# byte-identical to the 15-model build (the old file is a byte prefix of the new one).
EXTENDED_MARKER = [
    f"# ==== Extended models (extended-models.json v{EXTENDED_VERSION}): every other vanilla Vehicle.*_player*",
    "# ==== record, cars and bikes. Their ladder and stage prices come from the vanilla Autofixer price",
    "# ==== (see STAGES.md, Extended models); the dealer models above keep their own ladder.",
    "",
]


SOUND_MARKER = [
    f"# ==== Extended models (extended-models.json v{EXTENDED_VERSION}): every other vanilla Vehicle.*_player*",
    "# ==== record, cars and bikes, with the same sounds per class. $base is the model's own vanilla record.",
    "",
]


def render_yaml(plans: list[Plan], recs: "OrderedDict[str, OrderedDict]") -> str:
    lines = [
        "# Open77 Light RP performance stages: TweakXL records derived from the dealer models.",
        f"# GENERATED by scripts/vehicle-kit/stages/make_stages.py (generator v{GENERATOR_VERSION}). Do not edit:",
        "# change the generator and rebuild with scripts/vehicle-kit/stages/build-stages.ps1.",
        "# Vehicle.<dealer record>_o77s1..s3 = stage 1..3. Every engine, drive model, wheel setup",
        "# and wheel preset a stage changes is a NEW record (_engine, _drive, _wheels, _front,",
        "# _back); no vanilla record is modified. Gears and maxRPM are untouched: top speed is stock.",
        "",
    ]
    by_model: dict[str, list[str]] = {}
    for name in recs:
        m = NAME_RE.match(name)
        by_model.setdefault(m.group("base"), []).append(name)
    marked = False
    for p in plans:
        c = p.c
        if not c.dealer and not marked:
            lines += EXTENDED_MARKER
            marked = True
        lines.append(f"# ---- {c.label} ({c.key}), {c.ladder} tier {c.tier}: {c.record}")
        for name in by_model.get(c.record, []):
            lines.append(f"{name}:")
            for flat, v in recs[name].items():
                lines.append(f"  {flat}: {fmt_float(v) if isinstance(v, float) else v}")
            lines.append("")
    return "\n".join(lines).rstrip("\n") + "\n"


_TOP = re.compile(r"^(Vehicle\.[A-Za-z0-9_]+):\s*$")
_PROP = re.compile(r"^  (\$base|[A-Za-z_][A-Za-z0-9_]*):\s+(\S+)\s*$")
_FLOAT = re.compile(r"^[-+]?(?:\d+\.\d*|\d*\.\d+|\d+)(?:[eE][-+]?\d+)?$")
_NONFINITE = re.compile(r"^([-+]?)\.?(nan|inf)$", re.IGNORECASE)  # YAML .nan / .inf, refused by the check
_NAME = re.compile(r"^[A-Za-z][A-Za-z0-9_.]*$")


def parse_yaml(text: str) -> "OrderedDict[str, OrderedDict]":
    """Strict parser for the YAML subset this generator writes (and TweakXL reads):
    full-line comments, `Record:` at column 0, `  flat: scalar` below it. Anything else fails."""
    recs: OrderedDict[str, OrderedDict] = OrderedDict()
    cur = None
    for no, line in enumerate(text.splitlines(), 1):
        if not line.strip() or line.lstrip().startswith("#"):
            continue
        m = _TOP.match(line)
        if m:
            if m.group(1) in recs:
                raise StageError(f"line {no}: record {m.group(1)} defined twice")
            cur = recs[m.group(1)] = OrderedDict()
            continue
        m = _PROP.match(line)
        if not m or cur is None:
            raise StageError(f"line {no}: outside the supported YAML subset: {line!r}")
        flat, raw = m.groups()
        if flat in cur:
            raise StageError(f"line {no}: flat {flat} set twice")
        nf = _NONFINITE.match(raw)
        if _FLOAT.match(raw):
            cur[flat] = float(raw)
        elif nf:
            cur[flat] = float(nf.group(1) + nf.group(2))
        elif _NAME.match(raw):
            cur[flat] = raw
        else:
            raise StageError(f"line {no}: value {raw!r} is neither a float nor a record name")
    return recs


# --------------------------------------------------------------------------- check
def check_records(db: tdb.LayeredTweakDB, plans: list[Plan], recs: "OrderedDict[str, OrderedDict]") -> list[str]:
    """Validate parsed stage records against tweakdb.bin and the caps. Returns error strings."""
    errors: list[str] = []
    err = errors.append
    plan_of = {p.c.record: p for p in plans}
    known = known_records(db)
    parsed: dict[str, tuple[str, int, str]] = {}
    for name in recs:
        if (tdb.tdbid(name) & tdb.ID_MASK) in known:
            err(f"vanilla record {name} would be modified in place (the id already exists in tweakdb.bin)")
            continue
        m = NAME_RE.match(name)
        if not m:
            err(f"unknown record name {name}: not Vehicle.<dealer record>_o77s<1-3>[_part]")
            continue
        base, stage, part = m.group("base"), int(m.group("stage")), m.group("part") or ""
        if name != stage_name(base, stage, part):
            err(f"{name}: not the name of stage {stage} {part or 'record'} of {base} ({stage_name(base, stage, part)}: "
                "a sub-record is renamed only as collisions.py declares)")
            continue
        if base not in plan_of:
            err(f"unknown record {name}: {base} is not a staged model (dealer or extended)")
            continue
        if stage not in STAGES:
            err(f"unknown record {name}: stage {stage} outside {STAGES}")
            continue
        parsed[name] = (base, stage, part)

    # one pass per record: $base, flats, types, references, caps
    for name, (base, stage, part) in parsed.items():
        p = plan_of[base]
        c = p.c
        kind = PART_KIND[part]
        flats = recs[name]
        bname = flats.get("$base")
        if not isinstance(bname, str):
            err(f"{name}: $base missing")
            continue
        bid = tdb.tdbid(bname) & tdb.ID_MASK
        if bid not in known:
            err(f"{name}: unknown record {bname} in $base (not in tweakdb.bin)")
            continue
        want_type = TYPES[kind][c.ladder]
        if db.record_type(bid) != TYPE_KEYS[want_type]:
            err(f"{name}: $base {bname} is {type_name(db.record_type(bid))}, expected {want_type}")
        role = part or "vehicle"
        if bid != c.ids[role]:
            err(f"{name}: $base {bname} is not the vanilla {role} record of {base} ({c.names.get(role, hex(c.ids[role]))})")
        for flat, value in flats.items():
            if flat == "$base":
                continue
            spec = FLATS[kind].get(flat)
            if kind == "vehicle" and flat in ("vehDriveModelData", "bikeDriveModelData") and flat != DRIVE_FLAT[c.ladder]:
                spec = None
            ftype = flat_type(db, tdb.tdbid_append(bid, "." + flat))
            if spec is None:
                what = "unknown flat" if ftype is None else "flat not allowed (outside the stage whitelist)"
                err(f"{name}: {what} {flat}")
                continue
            if ftype is None:
                err(f"{name}: unknown flat {flat} on {bname}")
                continue
            if ftype != spec[0]:
                err(f"{name}: flat {flat} is {ftype} in tweakdb.bin, expected {spec[0]}")
                continue
            if spec[0] == "TweakDBID":
                target = spec[1]
                want = stage_name(base, stage, "" if target == "vehicle" else target)
                ok = isinstance(value, str) and value in parsed and value == want
                if target == "back" and value == stage_name(base, stage, "front") and c.ids["back"] == c.ids["front"]:
                    ok = True
                if not ok:
                    err(f"{name}: {flat} -> {value!r}: dangling or wrong reference (expected {want} defined in this file)")
                continue
            # Float lever
            if not isinstance(value, float) or not math.isfinite(value):
                err(f"{name}: {flat} = {value!r} is not a finite number")
                continue
            lever = spec[1]
            if lever == "engine":
                basev = c.torque
            else:
                basev = c.presets[part][flat]
            fac = p.factor(lever, stage)
            if fac is None:
                err(f"{name}: {flat} is a {lever} lever, not part of a {c.ladder} stage")
                continue
            limit = basev * fac
            if lever == "grip":
                limit = min(limit, GRIP_MAX)
                if value > GRIP_MAX + 1e-9:
                    err(f"{name}: cap violation {flat} = {value} > absolute grip cap {GRIP_MAX}")
            if lever == "engine" and value > TORQUE_MAX + 1e-9:
                err(f"{name}: cap violation {flat} = {value} > absolute torque cap {TORQUE_MAX}")
            if value > limit * (1 + 1e-9) + 1e-9:
                err(f"{name}: cap violation {flat} = {value} > {limit:.4f} (base {basev:.4f} x stage {stage} cap {fac:.4f})")
            if value < basev - 1e-6:
                err(f"{name}: {flat} = {value} is below the stock value {basev:.4f} (a stage never downgrades)")

    if errors:
        return errors

    # graph completeness and monotonic stages
    for p in plans:
        c = p.c
        prev_t, prev_p = c.torque, {(r, f): c.presets[r][f] for r in ("front", "back") for f in PRESET_LEVERS}
        for s in STAGES:
            veh = stage_name(c.record, s)
            if veh not in recs:
                err(f"{c.record}: stage {s} record {veh} missing")
                continue
            v = recs[veh]
            drive = v.get(DRIVE_FLAT[c.ladder])
            if drive != stage_name(c.record, s, "drive"):
                err(f"{veh}: {DRIVE_FLAT[c.ladder]} must point at {stage_name(c.record, s, 'drive')}")
                continue
            if p.engine_factors[s - 1] > 1.0 and "vehEngineData" not in v:
                err(f"{veh}: the engine stage is missing (factor {p.engine_factors[s - 1]:.3f})")
            eng = v.get("vehEngineData")
            torque = recs[eng]["engineMaxTorque"] if eng in recs and "engineMaxTorque" in recs[eng] else c.torque
            if torque + 1e-9 < prev_t:
                err(f"{veh}: torque {torque} below the previous stage ({prev_t})")
            prev_t = torque
            if p.ceiling is not None and torque * c.final_gear / c.mass * 1000.0 > max(p.ceiling, c.index) + 1e-6:
                err(f"{veh}: cap violation, specific torque {torque * c.final_gear / c.mass * 1000.0:.1f} Nm/t "
                    f"above the class ceiling {p.ceiling:.1f} Nm/t")
            wheels = recs.get(stage_name(c.record, s, "drive"), {}).get("wheelSetup")
            w = recs.get(wheels or "", {})
            for role, flat in (("front", "frontPreset"), ("back", "backPreset")):
                pr = recs.get(w.get(flat, ""), None)
                if pr is None:
                    err(f"{veh}: {flat} chain is incomplete")
                    continue
                for f in PRESET_LEVERS:
                    val = pr.get(f, c.presets[role][f])
                    if val + 1e-9 < prev_p[(role, f)]:
                        err(f"{veh}: {role} {f} {val} below the previous stage")
                    prev_p[(role, f)] = val

    # orphans: every sub-record must be reachable from its stage record
    reachable: set[str] = set()
    for name, flats in recs.items():
        for flat, value in flats.items():
            if flat != "$base" and isinstance(value, str):
                reachable.add(value)
    for name, (base, stage, part) in parsed.items():
        if part and name not in reachable:
            err(f"{name}: orphan sub-record (nothing points at it)")
    return errors


MUTATIONS = (
    # (label, expected error substring, mutate(recs, plans))
    ("unknown $base", "unknown record", lambda r, p: _set_first(r, "_engine", "$base", "Vehicle.o77_no_such_record")),
    ("unknown flat", "unknown flat", lambda r, p: _set_first(r, "_engine", "engineMaxTorqueBoost", 400.0)),
    ("top speed flat", "flat not allowed", lambda r, p: _set_first(r, "_engine", "maxRPM", 9900.0)),
    ("torque over cap", "cap violation", lambda r, p: _scale_first(r, "_engine", "engineMaxTorque", 2.0)),
    ("grip over 1.0", "cap violation", lambda r, p: _set_first(r, "_front", "frictionMulLateral", 1.2)),
    ("not finite", "not a finite number", lambda r, p: _set_first(r, "_front", "springStiffness", float("nan"))),
    ("vanilla in place", "modified in place", lambda r, p: _rename_first(r, "_engine", p[0].c.names["engine"])),
    ("dangling reference", "dangling", lambda r, p: _set_first(r, "_o77s1", "vehDriveModelData", "Vehicle.o77_missing_drive")),
)


def _first(recs, suffix):
    for name in recs:
        if name.endswith(suffix):
            return name
    raise StageError(f"no record ending in {suffix} to mutate")


def _set_first(recs, suffix, flat, value):
    recs[_first(recs, suffix)][flat] = value


def _scale_first(recs, suffix, flat, k):
    name = _first(recs, suffix)
    recs[name][flat] = recs[name][flat] * k


def _rename_first(recs, suffix, new_name):
    name = _first(recs, suffix)
    items = [(new_name if k == name else k, v) for k, v in recs.items()]
    recs.clear()
    recs.update(items)


def negative_tests(db, plans, recs) -> list[str]:
    failures = []
    for label, expect, mutate in MUTATIONS:
        broken = copy.deepcopy(recs)
        mutate(broken, plans)
        errs = check_records(db, plans, broken)
        if not any(expect in e for e in errs):
            failures.append(f"negative test '{label}' was not refused as '{expect}' (got: {errs[:3]})")
    return failures


# --------------------------------------------------------------------------- outputs
def render_tables(plans: list[Plan]) -> str:
    out = []
    out.append("### Class ladder and engine cap\n")
    out.append("| Model | Ladder, tier | Price | Top speed (rated) | Torque | Specific torque | Class ceiling | Engine s1 / s2 / s3 | Engine cap |")
    out.append("|---|---|---:|---:|---:|---:|---:|---|---|")
    for p in plans:
        c = p.c
        ceil = "none (top tier)" if p.ceiling is None else f"{p.ceiling:.1f} Nm/t"
        fs = " / ".join(f"x{f:.3f}" for f in p.engine_factors)
        out.append(f"| {c.label} | {c.ladder} T{c.tier} | {c.price:,} | {c.top_speed_kmh:.1f} km/h | {short(c.torque)} Nm "
                   f"| {c.index:.1f} Nm/t | {ceil} | {fs} | {p.engine_reason} |")
    out.append("")
    out.append("### Engine (`engineMaxTorque`, Nm) and expected effect\n")
    out.append("Expected acceleration gain = +48 % x (torque factor - 1), fitted on the single E0.8 run "
               "(an estimate until measured). Top speed is unchanged at every stage.\n")
    out.append("| Model | Stock | s1 | s2 | s3 | Avg. acceleration s1 / s2 / s3 |")
    out.append("|---|---:|---:|---:|---:|---|")
    for p in plans:
        c = p.c
        gains = " / ".join(f"+{ACCEL_PER_TORQUE * (p.torque_at(s) / c.torque - 1) * 100:.0f} %" for s in STAGES)
        if c.key == "hella":
            gains += " (0-80 km/h: " + " / ".join(
                f"{HELLA_0_80_S / (1 + ACCEL_PER_TORQUE * (p.torque_at(s) / c.torque - 1)):.2f} s" for s in STAGES) + \
                f", stock {HELLA_0_80_S} s measured)"
        out.append(f"| {c.label} | {short(c.torque)} | " + " | ".join(short(p.torque_at(s)) for s in STAGES) + f" | {gains} |")
    out.append("")
    out.append("### Brakes (`maxBrakingTorque` per wheel, front / rear, Nm)\n")
    out.append("| Model | Stock | s1 | s2 | s3 |")
    out.append("|---|---|---|---|---|")
    for p in plans:
        c = p.c
        cell = lambda s: f"{short(p.preset_at(s, 'front', 'maxBrakingTorque'))} / {short(p.preset_at(s, 'back', 'maxBrakingTorque'))}"
        base = f"{short(c.presets['front']['maxBrakingTorque'])} / {short(c.presets['back']['maxBrakingTorque'])}"
        out.append(f"| {c.label} | {base} | " + " | ".join(cell(s) for s in STAGES) + " |")
    out.append("")
    out.append("### Grip (`frictionMulLongitudinal` / `frictionMulLateral`, front ; rear)\n")
    out.append("| Model | Stock | s1 | s2 | s3 |")
    out.append("|---|---|---|---|---|")
    for p in plans:
        c = p.c

        def g(s):
            vals = []
            for role in ("front", "back"):
                lo = p.preset_at(s, role, "frictionMulLongitudinal") if s else c.presets[role]["frictionMulLongitudinal"]
                la = p.preset_at(s, role, "frictionMulLateral") if s else c.presets[role]["frictionMulLateral"]
                vals.append(f"{lo:.3f} / {la:.3f}")
            return " ; ".join(vals)
        out.append(f"| {c.label} | {g(0)} | " + " | ".join(g(s) for s in STAGES) + " |")
    out.append("")
    out.append("### Suspension (`springStiffness` and `swaybarStiffness`, front ; rear; dampers x sqrt of the spring factor)\n")
    out.append("| Model | Stock springs | s3 springs | Stock swaybar | s3 swaybar | Stock `springDamping` | s3 `springDamping` |")
    out.append("|---|---|---|---|---|---|---|")
    for p in plans:
        c = p.c
        if SPRINGS[c.ladder] is None:
            out.append(f"| {c.label} | unchanged (bike) | | | | | |")
            continue

        def pair(s, flat):
            if s == 0:
                return f"{short(c.presets['front'][flat], 2)} ; {short(c.presets['back'][flat], 2)}"
            return f"{short(p.preset_at(s, 'front', flat), 2)} ; {short(p.preset_at(s, 'back', flat), 2)}"
        out.append(f"| {c.label} | {pair(0, 'springStiffness')} | {pair(3, 'springStiffness')} | {pair(0, 'swaybarStiffness')} "
                   f"| {pair(3, 'swaybarStiffness')} | {pair(0, 'springDamping')} | {pair(3, 'springDamping')} |")
    out.append("")
    out.append("### Proposed prices (PROPOSAL, the owner decides)\n")
    out.append("Price of each stage = car price x 10 / 15 / 20 % x value weight, at least 1,000 / 1,500 / 2,000, "
               "rounded up to 500. Value weight = 0.5 + 0.5 x (engine share actually delivered), so a model whose "
               "engine is capped by the class ceiling pays less.\n")
    out.append("| Model | Car price | Value weight | s1 | s2 | s3 | All three |")
    out.append("|---|---:|---:|---:|---:|---:|---:|")
    for p in plans:
        c = p.c
        pr = [p.price(s) for s in STAGES]
        out.append(f"| {c.label} | {c.price:,} | {p.value_weight():.2f} | " + " | ".join(f"{x:,}" for x in pr) + f" | {sum(pr):,} |")
    return "\n".join(out) + "\n"


def render_lua(plans: list[Plan], yaml_sha: str) -> str:
    lines = [
        "-- GENERATED by scripts/vehicle-kit/stages/make_stages.py -- do not edit.",
        "-- Light RP performance stages: the TweakXL records shipped by this resource's preload_mod.",
        "-- stages[n] is the record of stage n; stage 0 is the dealer record itself.",
        "LightRpVehicleStages = {",
        f"    generator = {GENERATOR_VERSION},",
        f"    yamlSha256 = '{yaml_sha}',",
        "    models = {",
    ]
    for p in plans:
        c = p.c
        stages = ", ".join(f"'{stage_name(c.record, s)}'" for s in STAGES)
        prices = ", ".join(str(p.price(s)) for s in STAGES)
        lines.append(f"        {{ key = '{c.key}', record = '{c.record}', ladder = '{c.ladder}', tier = {c.tier}, "
                     f"ratedTopSpeedKmh = {c.top_speed_kmh:.1f},")
        lines.append(f"          stages = {{ {stages} }},")
        if c.dealer:
            lines.append(f"          proposedPrices = {{ {prices} }} }},")
        else:
            lines.append(f"          proposedPrices = {{ {prices} }},")
            lines.append(f"          extended = true, referencePrice = {c.ref_price}, priceSource = '{c.price_source}' }},")
    lines += ["    },", "}"]
    return "\n".join(lines) + "\n"


def render_extended_tables(plans: list[Plan]) -> str:
    """STAGES.md, Extended models: coverage, reference price and proposed stage prices per record."""
    ext = [p for p in plans if not p.c.dealer]
    doc = EXTENDED_DOC or {}
    out = []
    cars = sum(1 for p in ext if p.c.ladder == "car")
    out.append(f"{len(ext)} extended records ({cars} cars, {len(ext) - cars} bikes) besides the "
               f"{sum(1 for p in plans if p.c.dealer)} dealer models; "
               f"{len(doc.get('excluded', []))} in-scope record(s) excluded; "
               f"{len(doc.get('offers', []))} vanilla offers tied to a record, "
               f"{len(doc.get('unmatchedOffers', []))} unmatched; "
               f"{doc.get('tweakdbUnnamedVehicleRecords', 0)} Vehicle record(s) of tweakdb.bin have no name in "
               "WolvenKit's string table (none of them can be a named `_player` record).\n")
    for e in doc.get("excluded", []):
        out.append(f"- excluded: `{e['record']}`: {e['reason']}")
    if doc.get("excluded"):
        out.append("")
    caps = dealer_price_caps(plans)
    out.append("### Extended models: reference price and proposed stage prices (PROPOSAL, the owner decides)\n")
    out.append(f"Light RP price = vanilla reference price x {EXTENDED_PRICE_FACTOR:g}; the tier and the stage prices "
               "read it. Each stage is then capped at the highest dealer price of that stage in the class ("
               + "; ".join(f"{lad}: " + " / ".join(f"{x:,}" for x in caps[lad]) for lad in caps)
               + "); `Capped` lists the stages the cap lowered.\n")
    out.append("| Model | Record | Ladder, tier | Vanilla reference | Source | Light RP price | Value weight "
               "| s1 | s2 | s3 | All three | Capped |")
    out.append("|---|---|---|---:|---|---:|---:|---:|---:|---:|---:|---|")
    for p in ext:
        c = p.c
        pr = [p.price(s) for s in STAGES]
        capped = ", ".join(f"s{s}" for s in p.capped_stages()) or "-"
        out.append(f"| {c.label} | `{c.record}` | {c.ladder} T{c.tier} | {c.ref_price:,} | {c.price_source} "
                   f"| {c.price:,} | {p.value_weight():.2f} | " + " | ".join(f"{x:,}" for x in pr)
                   + f" | {sum(pr):,} | {capped} |")
    out.append("")
    out.append("### Extended models: engine cap\n")
    out.append("Class ceilings of the extended ladder: every staged record placed on its tier by its Light RP "
               "price (the dealer price for a dealer model, the scaled vanilla reference price for the others). "
               "Brakes, grip and suspension follow the stage policy unchanged (stages-manifest.json lists every "
               "value).\n")
    out.append("| Model | Top speed (rated) | Torque | Specific torque | Class ceiling | Engine s1 / s2 / s3 | Engine cap |")
    out.append("|---|---:|---:|---:|---:|---|---|")
    for p in ext:
        c = p.c
        ceil = "none (top tier)" if p.ceiling is None else f"{p.ceiling:.1f} Nm/t"
        fs = " / ".join(f"x{f:.3f}" for f in p.engine_factors)
        out.append(f"| {c.label} | {c.top_speed_kmh:.1f} km/h | {short(c.torque)} Nm | {c.index:.1f} Nm/t | {ceil} "
                   f"| {fs} | {p.engine_reason} |")
    return "\n".join(out) + "\n"


def sound_counts(with_sounds: bool = True) -> dict[str, int]:
    return {cls: (sum(1 for s in es.SOUNDS if s[2] == cls) if with_sounds else 0) for cls in ("car", "bike")}


def render_lightrp(plans: list[Plan], yaml_sha: str, sound_sha: str | None) -> str:
    """Light RP gamemode data: per staged record, its class, proposed stage prices and sound count."""
    counts = sound_counts(sound_sha is not None)
    lines = [
        "-- GENERATED by Open77 scripts/vehicle-kit/stages/make_stages.py (lightrp-vehicle-stage-catalogue.lua):",
        "-- do not edit, regenerate it with the stage pack it describes.",
        "-- Performance stages and engine sounds of every staged vanilla record: the 15 dealer models, then",
        "-- every other vanilla Vehicle.*_player* car and bike record, keyed by the record a catalogue entry",
        "-- names (quest variants Vehicle.q<digits>_* excluded). prices = the price of stage 1..maxStage",
        "-- (STAGES.md: the dealer formula; an extended model at 2x its vanilla price, each stage capped at",
        "-- the dearest dealer stage of its class); a catalogue key in",
        "-- LightRpCustomizationPricing.performance overrides them. sounds[class] = how many engine",
        "-- sounds the lightrp_vehicle_stages pack registers for that class (0: a stage-only pack).",
        "LightRpVehicleStageCatalogue = {",
        f"    generator = {GENERATOR_VERSION},",
        f"    stagesYamlSha256 = '{yaml_sha}',",
        f"    soundsYamlSha256 = '{sound_sha or ''}',",
        f"    maxStage = {max(STAGES)},",
        f"    sounds = {{ car = {counts['car']}, bike = {counts['bike']} }},",
        "    models = {",
    ]
    for p in plans:
        c = p.c
        prices = ", ".join(str(p.price(s)) for s in STAGES)
        lines.append(f"        ['{c.record}'] = {{ class = '{c.ladder}', tier = {c.tier}, "
                     f"dealer = {'true' if c.dealer else 'false'}, prices = {{ {prices} }}, referencePrice = {c.ref_price} }},")
    lines += ["    },", "}"]
    return "\n".join(lines) + "\n"


def refresh_properties(db, plans, names_path: str, cache: str | None, cp77tools: str | None,
                       extra_flats: str) -> dict:
    """record-properties.json: the properties TweakXL gives a clone of each $base the packs use."""
    if not os.path.isfile(extra_flats):
        raise StageError(f"{extra_flats}: TweakXL's ExtraFlats.dat not found (pass --extra-flats)")
    bases = set()
    for p in plans:
        bases.update(p.c.names.values())
    names = tdb.iter_names(os.path.abspath(names_path), os.path.abspath(cache) if cache else None,
                           os.path.abspath(cp77tools) if cp77tools else None)
    try:
        doc = col.build_properties(db, names, sorted(bases), extra_flats)
    except col.CollisionError as e:
        raise StageError(str(e))
    errs = col.verify_properties(db, doc, bases)
    if errs:
        raise StageError("the rebuilt record-properties.json does not match tweakdb.bin:\n  " + "\n  ".join(errs[:20]))
    write_text(col.PROPERTIES, json.dumps(doc, indent=2) + "\n")
    print(f"wrote {col.PROPERTIES} ({len(doc['types'])} record types, {len(doc['records'])} $base records)")
    return doc


def check_budget(stage_recs: int, stage_bytes: int, sound_recs: int = 0, sound_bytes: int = 0) -> None:
    """Refuse a pack over the record or size budget (TweakXL creates every record at game start)."""
    if stage_recs + sound_recs > RECORD_BUDGET:
        raise StageError(f"{stage_recs} stage + {sound_recs} sound records, over the {RECORD_BUDGET} record budget: "
                         "bound the model list (extended-models.json) before shipping")
    for what, size in (("stage", stage_bytes), ("engine-sound", sound_bytes)):
        if size > BYTES_BUDGET:
            raise StageError(f"the {what} YAML is {size} bytes, over the {BYTES_BUDGET} byte budget")


def manifest(plans, recs, yaml_sha, db_info) -> dict:
    models = []
    for p in plans:
        c = p.c
        models.append(OrderedDict([
            ("key", c.key), ("label", c.label), ("record", c.record), ("ladder", c.ladder), ("tier", c.tier),
            ("price", c.price), ("dealer", c.dealer), ("referencePrice", c.ref_price), ("priceSource", c.price_source),
            ("ladderBasis", "dealer ladder: the 15 dealer models by dealer price" if c.dealer else
             f"extended ladder: every staged record by Light RP price (dealer price, else vanilla reference "
             f"x {EXTENDED_PRICE_FACTOR:g})"),
            ("stagePriceCap", None if p.price_cap is None else list(p.price_cap)),
            ("ratedTopSpeedKmh", round(c.top_speed_kmh, 1)), ("maxRPM", c.max_rpm),
            ("gears", c.gear_count), ("massKg", c.mass), ("stockTorqueNm", c.torque), ("finalGearScalor", c.final_gear),
            ("specificTorqueNmPerT", round(c.index, 2)),
            ("classCeilingNmPerT", None if p.ceiling is None else round(p.ceiling, 2)),
            ("engineCap", p.engine_reason),
            ("baseRecords", OrderedDict((r, c.names[r]) for r in Chain.ROLES)),
            ("stockPresets", c.presets),
            ("stages", [OrderedDict([
                ("stage", s), ("record", stage_name(c.record, s)),
                ("engineFactor", round(p.engine_factors[s - 1], 4)), ("torqueNm", p.torque_at(s)),
                ("presets", p.stages[s]["presets"]), ("proposedPrice", p.price(s)),
                ("records", [n for n in recs if NAME_RE.match(n).group("base") == c.record
                             and int(NAME_RE.match(n).group("stage")) == s]),
            ]) for s in STAGES]),
        ]))
    return OrderedDict([
        ("schema", "open77.vehicle-stages/1"), ("generator", GENERATOR_VERSION),
        ("yaml", OrderedDict([("zipEntry", ZIP_ENTRY), ("sha256", yaml_sha), ("records", len(recs))])),
        ("tweakdb", db_info),
        ("extended", OrderedDict([
            ("file", "extended-models.json"), ("version", EXTENDED_VERSION),
            ("dealerModels", sum(1 for p in plans if p.c.dealer)), ("extendedModels", sum(1 for p in plans if not p.c.dealer)),
            ("excluded", (EXTENDED_DOC or {}).get("excluded", [])),
            ("unmatchedOffers", (EXTENDED_DOC or {}).get("unmatchedOffers", [])),
            ("tweakdbUnnamedVehicleRecords", (EXTENDED_DOC or {}).get("tweakdbUnnamedVehicleRecords")),
            ("recordBudget", RECORD_BUDGET), ("bytesBudget", BYTES_BUDGET),
        ])),
        ("policy", OrderedDict([
            ("engine", ENGINE), ("brakes", BRAKES), ("grip", GRIP), ("springs", SPRINGS),
            ("dampers", "sqrt(spring factor)"), ("gripMax", GRIP_MAX), ("torqueMaxNm", TORQUE_MAX),
            ("tierBands", TIER_BANDS), ("pricePct", PRICE_PCT), ("priceFloor", PRICE_FLOOR),
            ("extendedPriceFactor", EXTENDED_PRICE_FACTOR),
            ("extendedStagePriceCap", dealer_price_caps(plans)),
            ("untouched", ["gears", "maxRPM", "handbrakeBrakingTorque", "brakingFrictionFactor", "tireFrictionCoef",
                           "airResistanceFactor", "vehDriveModelDataAI", "vehicleUIData", "bike suspension"]),
        ])),
        ("models", models),
    ])


def write_text(path: str, text: str) -> None:
    os.makedirs(os.path.dirname(os.path.abspath(path)), exist_ok=True)
    with open(path, "w", encoding="utf-8", newline="\n") as fh:
        fh.write(text)


# --------------------------------------------------------------------------- extended models
# How a record outside the dealer catalogue gets its reference price (STAGES.md, "Extended
# models"). Every rule reads tweakdb.bin; the first that answers wins:
#   1. offer     its own vanilla Autofixer offer: a VehicleOffer record whose `price` names an
#                EconomicAssignment; the price is that record's `overrideValue` (Int32);
#   2. template  the cheapest offer among the in-scope records with the same entityTemplatePath
#                (a trim or story variant of an offered body);
#   3. class     the median (low) offer price of the records of the same body class, the second
#                token of the name (v_sport2_... -> sport2);
#   4. ladder    the median (low) offer price of the ladder (car or bike).
# An offer is tied to its record by, in order: the EconomicAssignment name with the prefix
# swapped (`EconomicAssignment.x` -> `Vehicle.x`); the same name tokens once the body class is
# dropped (`v_sportbike2_arch_02_player` = `v_sportbike2_arch_player_02`); the offer's `name`
# LocKey equal to the record's `displayName`. Each must be unique; an offer that ties to no
# in-scope record is listed as unmatched, never guessed.
OFFER_TYPE_KEY = tdb.record_type_key("gamedataVehicleOffer_Record")


def vehicle_class(db: tdb.LayeredTweakDB, rid: int) -> str | None:
    """'car', 'bike', 'panzer' or None: the enumName of the record the `type` flat points at."""
    return es.VanillaAudio.vehicle_class(db, rid)


def body_class(record: str) -> str | None:
    tokens = record.split(".", 1)[-1].split("_")
    return tokens[1] if len(tokens) > 2 and tokens[0] == "v" else None


def _tokens(name: str) -> tuple[str, ...]:
    tokens = name.split(".", 1)[-1].split("_")
    if len(tokens) > 2 and tokens[0] == "v":
        tokens = tokens[2:]
    return tuple(sorted(tokens))


def _lockey(value) -> int | None:
    if isinstance(value, int):
        return value
    m = re.match(r"^LocKey#(\d+)$", value or "") if isinstance(value, str) else None
    return int(m.group(1)) if m else None


def read_offer(db: tdb.LayeredTweakDB, offer: str) -> tuple[str | None, int | None, int | None]:
    """(EconomicAssignment id as hex, price, name LocKey) of a VehicleOffer record, from tweakdb.bin."""
    rid = tdb.tdbid(offer) & tdb.ID_MASK
    if db.record_type(rid) != OFFER_TYPE_KEY:
        return None, None, None
    ref = db.prop(rid, "price")
    if not isinstance(ref, int) or not (ref & tdb.ID_MASK):
        return None, None, _lockey(db.prop(rid, "name"))
    value = db.prop(ref & tdb.ID_MASK, "overrideValue")
    return f"{ref & tdb.ID_MASK:#x}", value if isinstance(value, int) else None, _lockey(db.prop(rid, "name"))


def match_offers(db: tdb.LayeredTweakDB, offers: list[dict], records: list[str]) -> tuple[list[dict], list[dict]]:
    """Tie each offer {offer, assignment, price} to one in-scope record (see the rules above)."""
    by_name = {r: r for r in records}
    by_tokens: dict[tuple, list[str]] = {}
    by_lockey: dict[int, list[str]] = {}
    for r in records:
        by_tokens.setdefault(_tokens(r), []).append(r)
        key = _lockey(db.prop(tdb.tdbid(r) & tdb.ID_MASK, "displayName"))
        if key is not None:
            by_lockey.setdefault(key, []).append(r)
    matched, unmatched, taken = [], [], {}
    for o in sorted(offers, key=lambda o: o["offer"]):
        guess = "Vehicle." + o["assignment"].split(".", 1)[-1]
        _, _, lockey = read_offer(db, o["offer"])
        found, how = None, None
        if guess in by_name:
            found, how = guess, "name"
        elif len(by_tokens.get(_tokens(guess), [])) == 1:
            found, how = by_tokens[_tokens(guess)][0], "tokens"
        elif lockey is not None and len(by_lockey.get(lockey, [])) == 1:
            found, how = by_lockey[lockey][0], "lockey"
        if found is None:
            unmatched.append(OrderedDict([("offer", o["offer"]), ("assignment", o["assignment"]), ("price", o["price"])]))
            continue
        if found in taken:
            raise StageError(f"offers {taken[found]} and {o['offer']} both tie to {found}")
        taken[found] = o["offer"]
        matched.append(OrderedDict([("offer", o["offer"]), ("assignment", o["assignment"]), ("price", o["price"]),
                                    ("record", found), ("match", how)]))
    return matched, unmatched


def reference_prices(db: tdb.LayeredTweakDB, records: list[str], ladders: dict[str, str],
                     offers: list[dict]) -> "OrderedDict[str, tuple[int, str]]":
    """record -> (reference price, source): rules 1-4 above, from the matched offers."""
    import statistics
    offer_of = {o["record"]: o for o in offers}
    template = {r: db.prop(tdb.tdbid(r) & tdb.ID_MASK, "entityTemplatePath") for r in records}
    by_class: dict[str, list[int]] = {}
    by_ladder: dict[str, list[int]] = {}
    for r, o in offer_of.items():
        if r not in ladders:
            continue
        if body_class(r):
            by_class.setdefault(body_class(r), []).append(o["price"])
        by_ladder.setdefault(ladders[r], []).append(o["price"])
    out: OrderedDict[str, tuple[int, str]] = OrderedDict()
    for r in records:
        if r in offer_of:
            out[r] = (int(offer_of[r]["price"]), f"offer {offer_of[r]['offer']}")
            continue
        siblings = sorted((int(offer_of[s]["price"]), s) for s in records
                          if s != r and s in offer_of and template[s] and template[s] == template[r])
        if siblings:
            out[r] = (siblings[0][0], f"template {siblings[0][1]}")
            continue
        cls = body_class(r)
        if cls and by_class.get(cls):
            prices = sorted(by_class[cls])
            out[r] = (int(statistics.median_low(prices)), f"class {cls} ({len(prices)} offers)")
            continue
        prices = sorted(by_ladder.get(ladders[r], []))
        if not prices:
            raise StageError(f"{r}: no vanilla offer on the {ladders[r]} ladder to derive a price from")
        out[r] = (int(statistics.median_low(prices)), f"ladder {ladders[r]} ({len(prices)} offers)")
    return out


def _labels_from_tsv() -> dict[str, str]:
    """Display names of the server's vehicle catalogue (English), for readable labels only."""
    path = os.path.abspath(VEHICLES_TSV)
    if not os.path.isfile(path):
        return {}
    out, header = {}, None
    with open(path, encoding="utf-8") as fh:
        for line in fh:
            if line.startswith("#"):
                continue
            row = line.rstrip("\n").split("\t")
            if header is None:
                header = row
                continue
            if row[0].startswith("@"):
                continue
            if "displayName" in header and len(row) > header.index("displayName"):
                out[row[0]] = row[header.index("displayName")]
    return out


def _label(record: str, labels: dict[str, str]) -> str:
    label = labels.get(record, "")
    if not label or not re.match(r"^[A-Za-z0-9 .,'()-]+$", label):
        stem = record.split(".", 1)[-1]
        tokens = stem.split("_")[2:] if stem.startswith("v_") else stem.split("_")
        label = " ".join(t.capitalize() for t in tokens if t != "player") or stem
    return label


def scope_records(db: tdb.LayeredTweakDB, names: dict[int, str]) -> tuple[list[str], list[dict], int]:
    """Every named Vehicle.*_player* record of the installed game, and the excluded ones."""
    vkey = tdb.record_type_key("gamedataVehicle_Record")
    vehicles = [r for r in db.record_ids() if db.record_type(r) == vkey]
    unnamed = sum(1 for r in vehicles if r not in names)
    keep, excluded = [], []
    for rid in vehicles:
        name = names.get(rid)
        if not name or not PLAYER_RE.match(name):
            continue
        cls = vehicle_class(db, rid)
        tokens = name.split(".", 1)[-1].split("_")
        why = None
        if QUEST_RE.match(name):
            why = "quest variant (Vehicle.q<digits>_*)"
        elif "av" in tokens:
            why = "AV"
        elif cls == "panzer":
            why = "Panzer class"
        elif cls not in ("car", "bike"):
            why = f"class {cls!r} is neither Car nor Bike"
        elif not db.prop(rid, "entityTemplatePath"):
            why = "no entity template"
        if why:
            excluded.append(OrderedDict([("record", name), ("reason", why)]))
        else:
            keep.append(name)
    return sorted(keep), sorted(excluded, key=lambda e: e["record"]), unnamed


def refresh_models(db: tdb.LayeredTweakDB, names_path: str, cache: str | None, cp77tools: str | None) -> dict:
    """Rebuild extended-models.json from tweakdb.bin and WolvenKit's string table."""
    names = tdb.load_names(os.path.abspath(names_path), os.path.abspath(cache) if cache else None,
                           os.path.abspath(cp77tools) if cp77tools else None)
    in_scope, excluded, unnamed = scope_records(db, names)
    missing = sorted(DEALER_RECORDS - set(in_scope))
    if missing:
        raise StageError(f"dealer records outside the scope scan: {missing}")
    ladders = {r: vehicle_class(db, tdb.tdbid(r) & tdb.ID_MASK) for r in in_scope}
    # Each candidate must carry a complete stage chain, or it is excluded with the reason.
    candidates = []
    for r in in_scope:
        if r in DEALER_RECORDS:
            continue
        try:
            Chain(db, (r.split(".", 1)[1], r, r, ladders[r], 0))
        except StageError as e:
            excluded.append(OrderedDict([("record", r), ("reason", f"incomplete stage chain: {e}")]))
            continue
        candidates.append(r)
    offers = []
    for rid in sorted(db.record_ids()):
        if db.record_type(rid) != OFFER_TYPE_KEY:
            continue
        offer = names.get(rid)
        if not offer:
            raise StageError(f"VehicleOffer {rid:#x} has no name in {names_path}")
        assignment_hex, price, _ = read_offer(db, offer)
        assignment = names.get(int(assignment_hex, 16)) if assignment_hex else None
        if not assignment or not isinstance(price, int) or price <= 0:
            raise StageError(f"{offer}: price record unreadable ({assignment_hex}, {price!r})")
        offers.append({"offer": offer, "assignment": assignment, "price": price})
    staged = sorted(DEALER_RECORDS) + candidates
    matched, unmatched = match_offers(db, offers, staged)
    refs = reference_prices(db, staged, ladders, matched)
    labels = _labels_from_tsv()
    models = [OrderedDict([("key", r.split(".", 1)[1]), ("label", _label(r, labels)), ("record", r),
                           ("ladder", ladders[r]), ("price", refs[r][0]), ("priceSource", refs[r][1])])
              for r in candidates]
    doc = OrderedDict([
        ("schema", "open77.vehicle-stage-extended/1"),
        ("version", EXTENDED_VERSION),
        ("note", "Every vanilla Vehicle.*_player* record (cars and bikes, no AV, no Panzer, no quest variant "
                 "Vehicle.q<digits>_*) besides the 15 dealer "
                 "models, with its vanilla reference price. GENERATED by make_stages.py --refresh-models --names "
                 "<tweakdbstr.kark>; verified against tweakdb.bin on every run. Prices are a PROPOSAL basis."),
        ("tweakdbUnnamedVehicleRecords", unnamed),
        ("dealerReference", OrderedDict((r, OrderedDict([("price", refs[r][0]), ("priceSource", refs[r][1])]))
                                        for r in sorted(DEALER_RECORDS))),
        ("models", models),
        ("excluded", sorted(excluded, key=lambda e: e["record"])),
        ("offers", matched),
        ("unmatchedOffers", unmatched),
    ])
    write_text(EXTENDED_MODELS, json.dumps(doc, indent=2) + "\n")
    print(f"wrote {EXTENDED_MODELS} ({len(models)} extended models, {len(excluded)} excluded, "
          f"{len(matched)} offers tied, {len(unmatched)} unmatched)")
    set_extended(doc)
    return doc


def set_extended(doc: dict) -> None:
    global EXTENDED_DOC, EXTENDED_MODEL_TUPLES, MODELS
    EXTENDED_DOC = doc
    EXTENDED_MODEL_TUPLES = tuple((m["key"], m["label"], m["record"], m["ladder"], int(m["price"])) for m in doc["models"])
    MODELS = DEALER_MODELS + EXTENDED_MODEL_TUPLES


def verify_extended(db: tdb.LayeredTweakDB) -> list[str]:
    """Re-derive what extended-models.json claims from tweakdb.bin; errors as strings."""
    errors: list[str] = []
    if not EXTENDED_DOC:
        return errors
    vkey = tdb.record_type_key("gamedataVehicle_Record")
    ladders = {}
    for key, label, record, ladder, price in DEALER_MODELS + EXTENDED_MODEL_TUPLES:
        rid = tdb.tdbid(record) & tdb.ID_MASK
        if db.record_type(rid) != vkey:
            errors.append(f"{record}: not a Vehicle record in tweakdb.bin")
            continue
        cls = vehicle_class(db, rid)
        if cls != ladder:
            errors.append(f"{record}: ladder {ladder} but tweakdb.bin types it {cls!r}")
        if not PLAYER_RE.match(record) or "av" in record.split(".", 1)[-1].split("_"):
            errors.append(f"{record}: outside the scope (Vehicle.*_player*, no AV)")
        if QUEST_RE.match(record):
            errors.append(f"{record}: a quest variant (Vehicle.q<digits>_*), outside the scope")
        if not db.prop(rid, "entityTemplatePath"):
            errors.append(f"{record}: no entity template")
        ladders[record] = ladder
    keys = [m[0] for m in MODELS]
    if len(set(keys)) != len(keys) or len({m[2] for m in MODELS}) != len(MODELS):
        errors.append("duplicate model key or record")
    for o in EXTENDED_DOC.get("offers", []):
        assignment_hex, price, _ = read_offer(db, o["offer"])
        if assignment_hex is None or int(assignment_hex, 16) != (tdb.tdbid(o["assignment"]) & tdb.ID_MASK):
            errors.append(f"{o['offer']}: no longer a VehicleOffer pointing at {o['assignment']}")
        elif price != o["price"]:
            errors.append(f"{o['offer']}: vanilla price {price} in tweakdb.bin, {o['price']} in extended-models.json")
    if errors:
        return errors
    staged = sorted(DEALER_RECORDS) + [m[2] for m in EXTENDED_MODEL_TUPLES]
    refs = reference_prices(db, staged, ladders, EXTENDED_DOC.get("offers", []))
    claimed = {m["record"]: (m["price"], m["priceSource"]) for m in EXTENDED_DOC["models"]}
    claimed.update({r: (v["price"], v["priceSource"]) for r, v in EXTENDED_DOC.get("dealerReference", {}).items()})
    for r in staged:
        if claimed.get(r) != refs[r]:
            errors.append(f"{r}: reference price {claimed.get(r)} in extended-models.json, {refs[r]} re-derived "
                          "(game update? rerun --refresh-models)")
    return errors


# --------------------------------------------------------------------------- main
def load_plans(db, names_table) -> list[Plan]:
    errs = verify_extended(db)
    if errs:
        raise StageError("extended-models.json does not match tweakdb.bin:\n  " + "\n  ".join(errs))
    chains = [Chain(db, m) for m in MODELS]
    refs = EXTENDED_DOC.get("dealerReference", {}) if EXTENDED_DOC else {}
    sources = {m["record"]: m["priceSource"] for m in EXTENDED_DOC.get("models", [])} if EXTENDED_DOC else {}
    for c in chains:
        c.attach_names(names_table)
        if c.dealer and c.record in refs:
            c.ref_price, c.price_source = int(refs[c.record]["price"]), refs[c.record]["priceSource"]
        elif not c.dealer:
            c.price_source = sources.get(c.record, "")
    # The dealer ladder is frozen: its ceilings come from the 15 dealer models alone, so their
    # stages never move. The extended ladder ranks every record (dealers too) by its Light RP
    # price (dealer price, else the scaled vanilla reference) and caps the extended models only.
    dealer = ceilings([c for c in chains if c.dealer])
    extended = ceilings(chains) if any(not c.dealer for c in chains) else {}
    plans = [Plan(c, dealer[c.key] if c.dealer else extended[c.key]) for c in chains]
    # An extended stage never costs more than the dearest dealer stage of its class.
    caps = dealer_price_caps(plans)
    for p in plans:
        if not p.c.dealer:
            p.price_cap = caps[p.c.ladder]
    return plans


def refresh_names(db, names_path: str, cache: str | None, cp77tools: str | None) -> dict:
    names = tdb.load_names(os.path.abspath(names_path), os.path.abspath(cache) if cache else None,
                           os.path.abspath(cp77tools) if cp77tools else None)
    table = OrderedDict()
    for m in MODELS:
        c = Chain(db, m)
        entry = OrderedDict()
        for role in Chain.ROLES[1:]:
            n = names.get(c.ids[role])
            if not n:
                raise StageError(f"{c.record}: no name for the {role} record {c.ids[role]:#x} in {names_path}")
            entry[role] = n
        table[c.record] = entry
    doc = OrderedDict([
        ("schema", "open77.vehicle-stage-bases/1"),
        ("note", "Vanilla record names of each staged model's engine / drive model / wheel setup / wheel presets. "
                 "Verified by id against tweakdb.bin on every run; regenerate with make_stages.py --names."),
        ("models", table),
    ])
    write_text(BASE_RECORDS, json.dumps(doc, indent=2) + "\n")
    print(f"wrote {BASE_RECORDS} ({len(table)} models)")
    return doc


def run_check(db, plans, yaml_path: str) -> tuple[int, int]:
    with open(yaml_path, encoding="utf-8") as fh:
        text = fh.read()
    if text.startswith("﻿"):
        raise StageError(f"{yaml_path}: starts with a BOM")
    recs = parse_yaml(text)
    errs = check_records(db, plans, recs)
    if errs:
        raise StageError("check failed:\n  " + "\n  ".join(errs))
    props = collision_inputs(db, recs)
    errs = col.check(db, props, recs) + verify_collisions(db, plans, props, recs, None)
    if errs:
        raise StageError("TweakDBID check failed:\n  " + "\n  ".join(errs))
    neg = negative_tests(db, plans, recs) + collision_negative_tests(db, props, recs)
    if neg:
        raise StageError("self-test failed:\n  " + "\n  ".join(neg))
    return len(recs), len(MUTATIONS) + 1


# --------------------------------------------------------------------------- TweakDBID collisions
def collision_inputs(db, stage_recs, sound_recs=None) -> dict:
    """record-properties.json, verified against tweakdb.bin for every $base the YAMLs clone."""
    try:
        props = col.load_properties()
    except col.CollisionError as e:
        raise StageError(str(e))
    bases = [f["$base"] for recs in (stage_recs, sound_recs or {}) for f in recs.values()
             if isinstance(f.get("$base"), str)]
    errs = col.verify_properties(db, props, bases)
    if errs:
        raise StageError("record-properties.json does not match tweakdb.bin:\n  " + "\n  ".join(errs[:20]))
    return props


def declared_base(plans):
    """$base of a canonical record name: a sub-record's vanilla record, else the model record."""
    chains = {p.c.record: p.c for p in plans}

    def base_of(record: str) -> str:
        m = re.match(r"^(?P<base>Vehicle\.[A-Za-z0-9_]+?)_o77s[1-9]_(?P<part>engine|drive|wheels|front|back)$", record)
        if m and m.group("base") in chains:
            return chains[m.group("base")].names[m.group("part")]
        return col.model_of(record)
    return base_of


def verify_collisions(db, plans, props, stage_recs, sound_recs) -> list[str]:
    """The declared resolutions (collisions.DECLARED) re-measured, and listed in STAGES.md."""
    errs = col.verify_declared(db, props, stage_recs, sound_recs, {p.c.record for p in plans}, DEALER_RECORDS,
                               declared_base(plans))
    doc = open(DOC, encoding="utf-8").read() if os.path.isfile(DOC) else ""
    if col.render_doc() not in doc:
        errs.append("STAGES.md does not list the declared TweakDBID collisions with their reason "
                    "(collisions.DECLARED): rerun make_stages.py --update-doc and commit")
    return errs


def _unrename(recs) -> bool:
    """The stage YAML with the first declared rename undone (the canonical, colliding name back)."""
    for canonical, renamed in col.STAGE_RENAMES.items():
        if renamed in recs:
            items = [(canonical if k == renamed else k,
                      OrderedDict((f, canonical if v == renamed else v) for f, v in flats.items()))
                     for k, flats in recs.items()]
            recs.clear()
            recs.update(items)
            return True
    return False


def collision_negative_tests(db, props, recs) -> list[str]:
    """The stage YAML with a declared rename undone (the Hellhound stage-2 engine of 2026-11-08,
    whose .gearCurvesPath is a vanilla flat's id) must be refused as a TweakDBID collision."""
    broken = copy.deepcopy(recs)
    if not _unrename(broken):
        # no renamed model in this build (dealer-only): any id the game already holds
        vanilla_name = next(iter(broken.values()))["$base"]
        broken = OrderedDict([(vanilla_name, OrderedDict([("$base", vanilla_name)]))] + list(broken.items()))
    errs = col.check(db, props, broken)
    if not any("TweakDBID collision" in e for e in errs):
        return [f"negative test 'TweakDBID collision' was not refused (got: {errs[:3]})"]
    return []


# --------------------------------------------------------------------------- engine sounds
def sound_models() -> list[tuple[str, str, str, str]]:
    return [(key, label, record, ladder) for key, label, record, ladder, _ in MODELS]


def run_sound_check(db, plans, stage_recs, yaml_path: str) -> tuple[int, int, int]:
    """Validate an engine-sound YAML against tweakdb.bin and the stage records it links to."""
    with open(yaml_path, encoding="utf-8") as fh:
        text = fh.read()
    if text.startswith("﻿"):
        raise StageError(f"{yaml_path}: starts with a BOM")
    recs = parse_yaml(text)
    models = sound_models()
    vanilla = es.VanillaAudio(db)
    known = known_records(db)
    excluded = col.SOUND_EXCLUSIONS
    errs = es.check_catalogue(es.SOUNDS, vanilla, [m[1] for m in MODELS])
    errs += es.check_records(db, vanilla, models, STAGES, stage_recs, stage_name, recs, known=known,
                             excluded=excluded)
    if errs:
        raise StageError("engine sound check failed:\n  " + "\n  ".join(errs))
    # Both YAMLs together, in TweakXL's order (it reads r6/tweaks/LightRP/*.yaml by name).
    props = collision_inputs(db, stage_recs, recs)
    errs = col.check(db, props, recs, stage_recs) + verify_collisions(db, plans, props, stage_recs, recs)
    if errs:
        raise StageError("TweakDBID check failed:\n  " + "\n  ".join(errs))
    neg, total = es.negative_tests(db, vanilla, models, STAGES, stage_recs, stage_name, recs,
                                   [m[1] for m in MODELS], known=known, excluded=excluded)
    neg += sound_collision_negative_test(db, props, recs, stage_recs)
    if neg:
        raise StageError("engine sound self-test failed:\n  " + "\n  ".join(neg))
    return len(recs), total + 1, len(es.SOUNDS)


def sound_collision_negative_test(db, props, recs, stage_recs) -> list[str]:
    """A declared exclusion put back (the Deleon stage 3 + s03 record seen in game on 2026-11-08) must
    be refused as a TweakDBID collision; without one in the build (dealer-only), a vanilla id."""
    broken = copy.deepcopy(recs)
    back = next((c for c in col.DECLARED if c.kind == "sound" and c.where == "pack"
                 and col.model_of(c.record) in {m[2] for m in MODELS}), None)
    if back is not None:
        m = es.NAME_RE.match(back.record)
        stage, index = int(m.group("stage") or 0), int(m.group("index"))
        sound = next(s for s in es.SOUNDS if es.index_of(s[0]) == index)
        flats = OrderedDict([("$base", m.group("base"))])
        flats.update(es.link_flats(stage_recs, m.group("base"), stage, stage_name))
        flats[es.AUDIO_FLATS[0]], flats[es.AUDIO_FLATS[1]] = sound[3], sound[4]
        broken[back.record] = flats
    else:
        name = next(iter(broken))
        vanilla_name = broken[name]["$base"]
        broken = OrderedDict([(vanilla_name, OrderedDict([("$base", vanilla_name)]))] + list(broken.items()))
    errs = col.check(db, props, broken, stage_recs)
    if not any("TweakDBID collision" in e for e in errs):
        return [f"negative test 'TweakDBID collision' was not refused (got: {errs[:3]})"]
    return []


def write_sounds(db, plans, stage_recs, out: str) -> tuple[str, str, int]:
    models = sound_models()
    recs = es.build_records(models, STAGES, stage_recs, stage_name, excluded=col.SOUND_EXCLUSIONS)
    text = es.render_yaml(models, recs, extended={m[2] for m in EXTENDED_MODEL_TUPLES}, marker=SOUND_MARKER)
    if parse_yaml(text) != recs:
        raise StageError("the rendered engine-sound YAML does not parse back to the same records")
    data = text.encode("utf-8")
    sha = hashlib.sha256(data).hexdigest()
    factory = es.factory_sets(db, models)
    ypath = os.path.join(out, es.YAML_NAME)
    write_text(ypath, text)
    missing = es.missing(models, STAGES, col.SOUND_EXCLUSIONS)
    write_text(os.path.join(out, "engine-sounds.lua"), es.render_lua(models, STAGES, factory, sha, missing=missing))
    write_text(os.path.join(out, "engine-sounds-manifest.json"),
               es.to_json(es.manifest(models, STAGES, recs, factory, sha, len(data), missing=missing)))
    return ypath, sha, len(data)


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("--game", default=None, help="Cyberpunk 2077 install (default: OP77_GAME_DIR, process then user)")
    ap.add_argument("--out-dir", help="write the YAML, stages-manifest.json, stages.lua and stages-table.md here")
    ap.add_argument("--check", metavar="YAML", help="only validate an existing stage YAML")
    ap.add_argument("--check-sounds", metavar="YAML", help="only validate an existing engine-sound YAML")
    ap.add_argument("--stages-yaml", metavar="YAML",
                    help="with --check-sounds: the stage YAML the sounds link to (default: regenerated in memory)")
    ap.add_argument("--no-sounds", action="store_true", help="with --out-dir: write the stage YAML only")
    ap.add_argument("--update-doc", action="store_true", help="rewrite the generated block of STAGES.md")
    ap.add_argument("--names", metavar="KARK", help="regenerate base-records.json from tweakdbstr.kark (or its decompressed .bin)")
    ap.add_argument("--refresh-models", action="store_true",
                    help="with --names: rebuild extended-models.json (every vanilla Vehicle.*_player* record) first")
    ap.add_argument("--lightrp-config", metavar="LUA",
                    help="with --out-dir: also write the Light RP stage catalogue (server/config/vehicle_stage_catalogue.lua) here")
    ap.add_argument("--cache", help="scratch folder for --names (decompressed string table)")
    ap.add_argument("--extra-flats", metavar="DAT",
                    help="with --names: TweakXL's Data/ExtraFlats.dat (default: the one installed in --game)")
    ap.add_argument("--cp77tools", default=os.path.expanduser(r"~\.dotnet\tools\cp77tools.exe"))
    a = ap.parse_args(argv)
    try:
        game = a.game or env_both("OP77_GAME_DIR")
        if not game:
            raise StageError("--game or OP77_GAME_DIR is required")
        db, db_info = load_db(game)
        if a.refresh_models and not a.names:
            raise StageError("--refresh-models needs --names <tweakdbstr.kark>")
        if a.names:
            if a.refresh_models:
                refresh_models(db, a.names, a.cache, a.cp77tools)
            refresh_names(db, a.names, a.cache, a.cp77tools)
        with open(BASE_RECORDS, encoding="utf-8") as fh:
            names_table = json.load(fh)["models"]
        plans = load_plans(db, names_table)
        if a.names:
            refresh_properties(db, plans, a.names, a.cache, a.cp77tools,
                               a.extra_flats or os.path.join(game, col.EXTRA_FLATS_REL))

        if a.check:
            n, neg = run_check(db, plans, a.check)
            print(f"VK_STAGES_CHECK_OK records={n} models={len(plans)} negative_tests={neg}/{neg} yaml={a.check}")
        if a.check_sounds:
            if a.stages_yaml:
                with open(a.stages_yaml, encoding="utf-8") as fh:
                    stage_recs = parse_yaml(fh.read())
            else:
                stage_recs = build_records(plans)
            n, neg, sounds = run_sound_check(db, plans, stage_recs, a.check_sounds)
            print(f"VK_SOUNDS_CHECK_OK records={n} models={len(plans)} sounds={sounds} "
                  f"negative_tests={neg}/{neg} yaml={a.check_sounds}")
        if a.check or a.check_sounds:
            return 0

        recs = build_records(plans)
        yaml_text = render_yaml(plans, recs)
        if parse_yaml(yaml_text) != recs:
            raise StageError("the rendered YAML does not parse back to the same records")
        yaml_sha = hashlib.sha256(yaml_text.encode("utf-8")).hexdigest()
        check_budget(len(recs), len(yaml_text.encode("utf-8")))
        # The dealer block of STAGES.md stays what a dealer-only build writes; the extended
        # models have their own block.
        tables = render_tables([p for p in plans if p.c.dealer])
        ext_tables = render_extended_tables(plans) if any(not p.c.dealer for p in plans) else ""

        if a.update_doc:
            with open(DOC, encoding="utf-8") as fh:
                doc = fh.read()
            for begin, end, text in ((DOC_BEGIN, DOC_END, tables), (DOC_EXT_BEGIN, DOC_EXT_END, ext_tables),
                                     (col.DOC_BEGIN, col.DOC_END, col.render_doc())):
                i = doc.find(begin)
                j = doc.find(end, i) if i >= 0 else -1
                if i < 0 or j < i:
                    raise StageError(f"{DOC}: generated block markers {begin} ... {end} not found")
                doc = doc[:i + len(begin)] + "\n\n" + text + "\n" + doc[j:]
            write_text(DOC, doc)
            print(f"updated {DOC}")

        if a.out_dir:
            out = os.path.abspath(a.out_dir)
            ypath = os.path.join(out, YAML_NAME)
            write_text(ypath, yaml_text)
            write_text(os.path.join(out, "stages-manifest.json"),
                       json.dumps(manifest(plans, recs, yaml_sha, db_info), indent=2) + "\n")
            write_text(os.path.join(out, "stages.lua"), render_lua(plans, yaml_sha))
            write_text(os.path.join(out, "stages-table.md"), tables + ("\n" + ext_tables if ext_tables else ""))
            n, neg = run_check(db, plans, ypath)
            print(f"VK_STAGES_CHECK_OK records={n} models={len(plans)} negative_tests={neg}/{neg} yaml={ypath}")
            # The committed STAGES.md must describe what this run produced.
            doc_text = open(DOC, encoding="utf-8").read() if os.path.isfile(DOC) else ""
            if tables not in doc_text or ext_tables not in doc_text:
                print("WARNING: STAGES.md tables differ from this run; rerun with --update-doc and commit")
            dealers = sum(1 for p in plans if p.c.dealer)
            print(f"VK_STAGES_GEN_OK records={n} models={len(plans)} dealer={dealers} extended={len(plans) - dealers} "
                  f"bytes={len(yaml_text.encode('utf-8'))} sha256={yaml_sha} yaml={ypath}")
            ssha = None
            if not a.no_sounds:
                spath, ssha, sbytes = write_sounds(db, plans, recs, out)
                sn, sneg, sounds = run_sound_check(db, plans, recs, spath)
                check_budget(n, len(yaml_text.encode("utf-8")), sn, sbytes)
                print(f"VK_SOUNDS_CHECK_OK records={sn} models={len(plans)} sounds={sounds} "
                      f"negative_tests={sneg}/{sneg} yaml={spath}")
                print(f"VK_SOUNDS_GEN_OK records={sn} models={len(plans)} sounds={sounds} bytes={sbytes} "
                      f"sha256={ssha} yaml={spath}")
                print(f"VK_BUDGET_OK records={n + sn}/{RECORD_BUDGET} stage_bytes={len(yaml_text.encode('utf-8'))} "
                      f"sound_bytes={sbytes} max_bytes={BYTES_BUDGET}")
            catalogue = render_lightrp(plans, yaml_sha, ssha)
            write_text(os.path.join(out, LIGHTRP_CATALOGUE), catalogue)
            if a.lightrp_config:
                write_text(os.path.abspath(a.lightrp_config), catalogue)
                print(f"wrote {os.path.abspath(a.lightrp_config)} ({len(plans)} records)")
        elif a.lightrp_config:
            ap.error("--lightrp-config needs --out-dir (the catalogue names the YAMLs it describes)")
        elif not a.update_doc and not a.names:
            ap.error("nothing to do: pass --out-dir, --check, --check-sounds or --update-doc")
        return 0
    except (StageError, es.SoundError, col.CollisionError) as e:
        print(f"VK_STAGES_FAILED {e}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
