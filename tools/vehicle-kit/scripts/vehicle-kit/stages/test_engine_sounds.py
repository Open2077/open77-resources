"""Tests of the engine-sound generator (wave 2, W2.3) and of the stage resource's Lua.

Three layers, each skipped only for a missing prerequisite:
- the curated catalogue and the record naming, offline (no game needed): names of every staged
  model round-trip through every parser (Python, the server's C# suffix regex, the client's
  IsEngineSoundRecord, Light RP's baseRecord), and the server classes every model as its ladder;
- the generator against the installed game's tweakdb.bin (OP77_GAME_DIR, process then user scope):
  record counts, the checks and their negative tests (9 stage, 19 sound), the stage YAML left
  byte-identical, the dealer part of both YAMLs byte-identical to a dealer-only build, the record and
  size budget, and no TweakDBID collision (CRC32 + length) in the pack: the declared ones of
  collisions.py come back exactly when their resolution is undone;
- the resource Lua in a real Lua 5.4 (scripts/furniture/luahost.py: lupa, or the server's lua54.dll):
  every YAML record reachable, stage and sound kept across changes, the registered catalogue.

    uv run --no-project python -I -m unittest discover -s scripts/vehicle-kit/stages -p "test_*.py" -v
"""
from __future__ import annotations

import contextlib
import importlib.util
import io
import os
import re
import sys
import tempfile
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent
REPO = HERE.parents[2]
sys.path.insert(0, str(HERE.parent / "inventory"))
sys.path.insert(0, str(HERE))


def _module(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    mod = importlib.util.module_from_spec(spec)
    sys.modules[name] = mod
    spec.loader.exec_module(mod)
    return mod


es = _module("engine_sounds", HERE / "engine_sounds.py")
ms = _module("make_stages", HERE / "make_stages.py")
col = sys.modules["collisions"]
tdb = sys.modules["tdb"]
luahost = _module("vk_luahost", REPO / "scripts" / "furniture" / "luahost.py")


def game_dir() -> str | None:
    game = ms.env_both("OP77_GAME_DIR")
    if game and os.path.isfile(os.path.join(game, "r6", "cache", "tweakdb.bin")):
        return game
    return None


NO_GAME = None if game_dir() else "OP77_GAME_DIR has no r6/cache/tweakdb.bin"


class CatalogueTests(unittest.TestCase):
    def test_ids_are_unique_and_ordered(self):
        ids = [s[0] for s in es.SOUNDS]
        self.assertEqual(len(ids), len(set(ids)))
        self.assertEqual(ids, sorted(ids))
        for sid in ids:
            self.assertRegex(sid, r"^s\d{2}$")

    def test_classes_and_bounds(self):
        per = {}
        for sid, label, cls, player, traffic in es.SOUNDS:
            self.assertIn(cls, ("car", "bike"))
            per[cls] = per.get(cls, 0) + 1
            self.assertTrue(player.startswith("v_car_" if cls == "car" else "v_mbike_"), sid)
            self.assertEqual(traffic, player + "_traffic", sid)
        self.assertLessEqual(per["car"], es.MAX_PER_CLASS["car"])
        self.assertGreaterEqual(per["bike"], 2)

    def test_no_special_police_or_licensed_set(self):
        for sid, label, cls, player, traffic in es.SOUNDS:
            self.assertNotIn(player, es.SPECIAL_SETS)
            self.assertFalse(set(player.split("_")) & es.EXCLUDED_TOKENS, sid)

    def test_labels_are_neutral(self):
        brand = set(es.EXTRA_BRAND_TOKENS)
        for model in ms.MODELS:
            brand.update(w for w in es.words(model[1]) if w not in es.GENERIC_TOKENS)
        for sid, label, cls, player, traffic in es.SOUNDS:
            brand.update(w for w in player.split("_") if w not in es.GENERIC_TOKENS)
        for sid, label, *_ in es.SOUNDS:
            self.assertFalse(set(es.words(label)) & brand, f"{sid} {label!r}")
            self.assertRegex(label, es.LABEL_RE)
        self.assertEqual(len({s[1].lower() for s in es.SOUNDS}), len(es.SOUNDS))

    def test_names_round_trip_and_never_look_like_stage_records(self):
        record = "Vehicle.v_standard2_archer_hella_player"
        for stage in (0, 1, 2, 3):
            for index in (1, 9, 16):
                name = es.sound_name(record, stage, index)
                m = es.NAME_RE.match(name)
                self.assertTrue(m, name)
                self.assertEqual((m.group("base"), int(m.group("stage") or 0), int(m.group("index"))),
                                 (record, stage, index))
                self.assertIsNone(ms.NAME_RE.match(name), name)
        for part in ("", "engine", "drive"):
            self.assertIsNone(es.NAME_RE.match(ms.stage_name(record, 2, part)))
        self.assertEqual(es.sound_name(record, 0, 1), record + "_o77a1")
        self.assertEqual(es.sound_name(record, 2, 13), record + "_o77s2a13")

    def test_trim_and_variant_names_round_trip_through_every_parser(self):
        """_player_02 / _03 / _missiles / _mr_hands: every parser finds the same base."""
        bases = [m[2] for m in ms.MODELS if re.search(r"_player_(?:0\d|missiles|mr_hands)$", m[2])]
        for want in ("_player_02", "_player_03", "_player_missiles", "_player_mr_hands"):
            self.assertTrue(any(b.endswith(want) for b in bases), f"no staged record ends in {want}")
        # A name ending in _player_car (the quest variant, out of scope) parses the same way.
        bases.append("Vehicle.q000_hym_player_car")
        for record in bases:
            self.assertEqual(_split_cs(record), (record, 0, None), record)
            self.assertEqual(_lightrp_base(record), record)
            self.assertFalse(_client_is_sound(record))
            self.assertIsNone(ms.NAME_RE.match(record))
            self.assertIsNone(es.NAME_RE.match(record))
            for stage in (0, 1, 2, 3):
                for index in (None, 1, 13):
                    if stage == 0 and index is None:
                        continue
                    name = es.sound_name(record, stage, index) if index else ms.stage_name(record, stage)
                    self.assertEqual(_split_cs(name), (record, stage, index), name)
                    self.assertEqual(_lightrp_base(name), record, name)
                    self.assertEqual(_client_is_sound(name), index is not None, name)
                    m = (es.NAME_RE if index else ms.NAME_RE).match(name)
                    self.assertTrue(m and m.group("base") == record, name)
                if stage:
                    for part in ("engine", "drive", "wheels", "front", "back"):
                        m = ms.NAME_RE.match(ms.stage_name(record, stage, part))
                        self.assertEqual((m.group("base"), int(m.group("stage")), m.group("part")), (record, stage, part))

    def test_server_classes_every_model_as_its_ladder(self):
        """VehicleCustomizationData.IsBike (embedded TSVs) must agree with tweakdb.bin's class."""
        data = REPO / "server" / "src" / "Open77.Server.Core" / "Data"
        custom, vehicles = _tsv(data / "vehicle-customization-2.50.tsv"), _tsv(data / "vehicles-2.31.tsv")
        for key, label, record, ladder, price in ms.MODELS:
            if record in custom:
                bike = custom[record]["vehicleType"] == "Bike"
            else:
                bike = record in vehicles and vehicles[record]["seats"] == "1"
            self.assertEqual("bike" if bike else "car", ladder, record)

    def test_extended_models_are_in_scope(self):
        self.assertEqual(len(ms.DEALER_MODELS), 15)
        self.assertGreater(len(ms.EXTENDED_MODEL_TUPLES), 0)
        records = [m[2] for m in ms.MODELS]
        self.assertEqual(len(records), len(set(records)))
        self.assertEqual(len({m[0] for m in ms.MODELS}), len(ms.MODELS))
        for key, label, record, ladder, price in ms.EXTENDED_MODEL_TUPLES:
            self.assertRegex(record, ms.PLAYER_RE)
            self.assertIsNone(ms.QUEST_RE.match(record), record)
            self.assertNotIn("av", record.split(".", 1)[1].split("_"), record)
            self.assertNotIn(record, ms.DEALER_RECORDS)
            self.assertIn(ladder, ("car", "bike"))
            self.assertGreater(price, 0)
        for record in ("Vehicle.v_sport2_quadra_type66_player", "Vehicle.v_sportbike1_yaiba_kusanagi_player_02"):
            self.assertIn(record, records)
        # Quest variants are out of scope (owner, 2026-11-07), and listed as excluded.
        excluded = {e["record"]: e["reason"] for e in ms.EXTENDED_DOC.get("excluded", [])}
        for record in ("Vehicle.q000_hym_player_car", "Vehicle.q304_songbird_escape_player"):
            self.assertNotIn(record, records)
            self.assertIn("quest variant", excluded.get(record, ""), record)
        self.assertTrue(ms.QUEST_RE.match("Vehicle.q115_thrax_player"))
        self.assertIsNone(ms.QUEST_RE.match("Vehicle.v_sport2_quadra_type66_player"))

    def test_lua_without_bom_and_ps1_with_bom(self):
        for path in (HERE / "lua").glob("*.lua"):
            self.assertFalse(path.read_bytes().startswith(b"\xef\xbb\xbf"), path.name)
        self.assertTrue((HERE / "build-stages.ps1").read_bytes().startswith(b"\xef\xbb\xbf"))


class CollisionDeclarationTests(unittest.TestCase):
    """The TweakDBID arithmetic and the declared collisions, offline (no game needed)."""

    def test_the_deleon_maimai_pair_is_one_tweakdbid(self):
        # The in-game bug of 2026-11-08: TweakXL "Type mismatch ... has hash collision with ...".
        a = "Vehicle.v_sport2_villefort_deleon_player_o77s3a3.player_audio_resource"
        b = "Vehicle.v_standard2_makigai_maimai_player_o77s1a3.drivingParamsGeneric"
        self.assertNotEqual(a, b)
        self.assertEqual(len(a), 70)
        self.assertEqual(len(b), 70)
        self.assertEqual(tdb.tdbid(a) & tdb.ID_MASK, 70 << 32 | 0x49C53D2A)
        self.assertEqual(tdb.tdbid(a) & tdb.ID_MASK, tdb.tdbid(b) & tdb.ID_MASK)
        self.assertEqual(col.describe(col.id_of(a)), "CRC32 0x49c53d2a, length 70")
        # A flat id is the record id with ".flat" appended: what TweakXL computes for a clone.
        record = "Vehicle.v_sport2_villefort_deleon_player_o77s3a3"
        self.assertEqual(tdb.tdbid_append(col.id_of(record), ".player_audio_resource"), col.id_of(a))

    def test_every_declared_collision_is_arithmetically_true(self):
        self.assertEqual(len(col.DECLARED), 4)
        for c in col.DECLARED:
            name = f"{c.record}.{c.flat}" if c.flat else c.record
            self.assertEqual(col.id_of(name), c.size << 32 | c.crc, name)
            self.assertEqual(col.id_of(c.partner), c.size << 32 | c.crc, c.partner)
            self.assertNotEqual(name, c.partner)
            self.assertIn(c.where, ("vanilla", "pack"))
            self.assertIn(c.kind, ("sound", "stage"))
            if c.kind == "stage":
                self.assertTrue(c.renamed and col.id_of(f"{c.renamed}.{c.flat}") != col.id_of(name))
                self.assertEqual(ms.stage_name(col.model_of(c.record), 2, "engine"), c.renamed)
            else:
                self.assertEqual(c.renamed, "")
                self.assertTrue(es.NAME_RE.match(c.record), c.record)

    def test_no_dealer_record_is_ever_dropped_or_renamed(self):
        for c in col.DECLARED:
            self.assertNotIn(col.model_of(c.record), ms.DEALER_RECORDS, c.record)
            self.assertIn(col.model_of(c.record), {m[2] for m in ms.MODELS}, c.record)

    def test_stages_md_lists_every_declared_collision_with_its_reason(self):
        doc = Path(ms.DOC).read_text(encoding="utf-8")
        block = col.render_doc()
        self.assertIn(col.DOC_BEGIN + "\n\n" + block + "\n" + col.DOC_END, doc.replace("\r\n", "\n"))
        for c in col.DECLARED:
            self.assertIn(f"`{c.record}`", block)
            self.assertIn(f"{c.crc:#010x} / {c.size}", block)

    def test_missing_names_exactly_the_sound_exclusions(self):
        models = ms.sound_models()
        holes = es.missing(models, ms.STAGES, col.SOUND_EXCLUSIONS)
        named = {es.sound_name(r, st, es.index_of(sid)) for r, stages in holes.items()
                 for st, sids in stages.items() for sid in sids}
        self.assertEqual(named, set(col.SOUND_EXCLUSIONS))
        self.assertEqual(holes["Vehicle.v_sport2_villefort_deleon_player"], {3: ["s03"]})
        self.assertEqual(es.missing(models, ms.STAGES, frozenset()), {})


_CS_SUFFIX = re.compile(r"_o77(?:s(?P<stage>[0-9]+)(?:a(?P<sound>[0-9]+))?|a(?P<only>[0-9]+))\Z")


def _split_cs(record: str):
    """VehicleCustomizationData.TrySplitRecord (server, VehicleVisual.cs): (base, stage, sound)."""
    m = _CS_SUFFIX.search(record)
    if not m or m.start() == 0:
        return record, 0, None
    sound = m.group("sound") or m.group("only")
    return record[:m.start()], int(m.group("stage") or 0), int(sound) if sound else None


def _lightrp_base(record: str) -> str:
    """LightRpConfig.baseRecord (Light RP shared/config.lua): three anchored gsubs, in order."""
    for pattern in (r"_o77s\d+a\d+$", r"_o77a\d+$", r"_o77s\d+$"):
        record = re.sub(pattern, "", record, count=1)
    return record


def _client_is_sound(record: str) -> bool:
    """IsEngineSoundRecord (client/src/api/Vehicles.cpp): rfind("_o77"), [s<digits>] a<digits> to the end."""
    i = record.rfind("_o77")
    return i >= 0 and re.fullmatch(r"(?:s\d+)?a\d+", record[i + 4:]) is not None


def _tsv(path: Path) -> dict[str, dict[str, str]]:
    """A server Data TSV (RecordCatalogue): '#' comments, a header, '@dict <column> values...' rows."""
    header, dicts, rows = None, {}, {}
    for line in path.read_text(encoding="utf-8").splitlines():
        if line.startswith("#") or not line:
            continue
        row = line.split("\t")
        if header is None:
            header = row
            continue
        if row[0] == "@dict":
            dicts[row[1]] = row[2:]
            continue
        rec = {}
        for i, col in enumerate(header):
            v = row[i] if i < len(row) else ""
            if col in dicts and v.isdigit():
                v = dicts[col][int(v)]
            rec[col] = v
        rows[row[0]] = rec
    return rows


@contextlib.contextmanager
def _dealers_only():
    """The generator as it was before the extended models: the 15 dealer models alone."""
    saved = ms.EXTENDED_DOC, ms.EXTENDED_MODEL_TUPLES, ms.MODELS
    ms.EXTENDED_DOC, ms.EXTENDED_MODEL_TUPLES, ms.MODELS = {}, (), ms.DEALER_MODELS
    try:
        yield
    finally:
        ms.EXTENDED_DOC, ms.EXTENDED_MODEL_TUPLES, ms.MODELS = saved


def _generate(out: str, *extra: str) -> str:
    buf = io.StringIO()
    with contextlib.redirect_stdout(buf), contextlib.redirect_stderr(buf):
        code = ms.main(["--game", game_dir(), "--out-dir", out, *extra])
    text = buf.getvalue()
    if code != 0:
        raise AssertionError(text)
    return text


@unittest.skipIf(NO_GAME, NO_GAME or "")
class GeneratorTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.tmp = tempfile.TemporaryDirectory()
        cls.out = os.path.join(cls.tmp.name, "full")
        cls.log = _generate(cls.out)

    @classmethod
    def tearDownClass(cls):
        cls.tmp.cleanup()

    def test_record_matrix(self):
        cars = sum(1 for m in ms.MODELS if m[3] == "car")
        bikes = len(ms.MODELS) - cars
        car_sounds = sum(1 for s in es.SOUNDS if s[2] == "car")
        bike_sounds = len(es.SOUNDS) - car_sounds
        stages = len(ms.STAGES) + 1
        # minus the declared TweakDBID collisions (collisions.SOUND_EXCLUSIONS), each one record
        want = stages * (cars * car_sounds + bikes * bike_sounds) - len(col.SOUND_EXCLUSIONS)
        m = re.search(r"VK_SOUNDS_GEN_OK records=(\d+) models=(\d+) sounds=(\d+) bytes=(\d+)", self.log)
        self.assertTrue(m, self.log)
        self.assertEqual(int(m.group(1)), want)
        self.assertEqual(int(m.group(2)), len(ms.MODELS))
        self.assertEqual(int(m.group(3)), len(es.SOUNDS))
        size = os.path.getsize(os.path.join(self.out, es.YAML_NAME))
        self.assertEqual(int(m.group(4)), size)
        stage_records = int(re.search(r"VK_STAGES_GEN_OK records=(\d+)", self.log).group(1))
        self.assertLessEqual(stage_records + want, ms.RECORD_BUDGET, "records TweakXL creates at game start")
        self.assertLess(size, ms.BYTES_BUDGET)
        self.assertLess(os.path.getsize(os.path.join(self.out, ms.YAML_NAME)), ms.BYTES_BUDGET)
        self.assertIn("VK_BUDGET_OK", self.log)
        # sound check: its mutations, the excluded-combination test and the TweakDBID one (19);
        # stage check: its mutations and the TweakDBID one (9)
        sound_neg = len(es.RECORD_MUTATIONS) + len(es.CATALOGUE_MUTATIONS) + 2
        self.assertEqual(sound_neg, 19)
        self.assertRegex(self.log, rf"VK_SOUNDS_CHECK_OK .*negative_tests={sound_neg}/{sound_neg} ")
        self.assertEqual(len(ms.MUTATIONS) + 1, 9)
        self.assertRegex(self.log, rf"VK_STAGES_CHECK_OK .*negative_tests=9/9 ")

    def _db(self):
        if not hasattr(type(self), "db"):
            type(self).db = ms.load_db(game_dir())[0]
            type(self).props = col.load_properties()
        return type(self).db, type(self).props

    def _yamls(self):
        stages = ms.parse_yaml(Path(self.out, ms.YAML_NAME).read_text(encoding="utf-8"))
        sounds = ms.parse_yaml(Path(self.out, es.YAML_NAME).read_text(encoding="utf-8"))
        return stages, sounds

    def test_no_tweakdbid_collision_in_the_pack(self):
        db, props = self._db()
        stages, sounds = self._yamls()
        self.assertEqual(col.verify_properties(db, props, [f["$base"] for f in stages.values()]), [])
        self.assertEqual(col.check(db, props, sounds, stages), [])
        owner, _ = col.created_ids(db, props, (sounds, stages))
        self.assertGreater(len(owner), 500000, "every record id and every flat TweakXL creates")
        for c in col.DECLARED:
            self.assertNotIn(c.record, stages)
            self.assertNotIn(c.record, sounds)
        self.assertIn("Vehicle.v_standard3_militech_hellhound_player_o77s2_engine_c1", stages)

    def test_the_declared_collisions_come_back_when_undone(self):
        # The pack without its resolutions: every sound record generated, the Hellhound rename undone.
        db, props = self._db()
        stages, _ = self._yamls()
        self.assertTrue(ms._unrename(stages))
        sounds = es.build_records(ms.sound_models(), ms.STAGES, stages, ms.stage_name)
        for c in col.DECLARED:
            self.assertIn(c.record, sounds if c.kind == "sound" else stages)
        errors = col.check(db, props, sounds, stages)
        found = sorted((int(m.group(1), 16), int(m.group(2)))
                       for m in (re.search(r"CRC32 (0x[0-9a-f]{8}), length (\d+)", e) for e in errors))
        self.assertEqual(found, sorted((c.crc, c.size) for c in col.DECLARED), "\n".join(errors))
        self.assertTrue(any("Vehicle.v_sport2_villefort_deleon_player_o77s3a3.player_audio_resource" in e
                            and "Vehicle.v_standard2_makigai_maimai_player_o77s1a3.drivingParamsGeneric" in e
                            for e in errors), errors)

    def test_an_excluded_combination_put_back_is_refused_by_the_sound_check(self):
        stages, sounds = self._yamls()
        back = es.build_records(ms.sound_models(), ms.STAGES, stages, ms.stage_name)
        bad = os.path.join(self.tmp.name, "back.yaml")
        Path(bad).write_text(es.render_yaml(ms.sound_models(), back, extended={m[2] for m in ms.EXTENDED_MODEL_TUPLES},
                                            marker=ms.SOUND_MARKER), encoding="utf-8")
        buf = io.StringIO()
        with contextlib.redirect_stdout(buf), contextlib.redirect_stderr(buf):
            code = ms.main(["--game", game_dir(), "--check-sounds", bad,
                            "--stages-yaml", os.path.join(self.out, ms.YAML_NAME)])
        self.assertEqual(code, 1)
        self.assertIn("excluded combination present", buf.getvalue())

    def test_the_old_pack_is_refused(self):
        # The stage YAML of revision 7c4f42a3cfc2, without the Hellhound rename: refused.
        text = Path(self.out, ms.YAML_NAME).read_text(encoding="utf-8")
        renamed = "Vehicle.v_standard3_militech_hellhound_player_o77s2_engine_c1"
        self.assertIn(renamed, text)
        bad = os.path.join(self.tmp.name, "old-stages.yaml")
        Path(bad).write_text(text.replace(renamed, renamed[:-3]), encoding="utf-8")
        buf = io.StringIO()
        with contextlib.redirect_stdout(buf), contextlib.redirect_stderr(buf):
            code = ms.main(["--game", game_dir(), "--check", bad])
        self.assertEqual(code, 1)
        self.assertIn("renamed only as collisions.py declares", buf.getvalue())

    def test_dealer_part_is_byte_identical_to_a_dealer_only_build(self):
        dealers = os.path.join(self.tmp.name, "dealers")
        with _dealers_only():
            log = _generate(dealers)
        self.assertIn("models=15", log)
        for name in (ms.YAML_NAME, es.YAML_NAME):
            old = Path(dealers, name).read_bytes()
            new = Path(self.out, name).read_bytes()
            self.assertTrue(new.startswith(old), f"{name}: the dealer-only build is not a byte prefix")
            self.assertTrue(new[len(old):].startswith(b"\n# ==== Extended models"), name)
        # The dealer tables of STAGES.md are what a dealer-only build writes.
        table = Path(dealers, "stages-table.md").read_text(encoding="utf-8")
        self.assertIn(table, Path(ms.DOC).read_text(encoding="utf-8"))

    def test_extended_prices_on_lightrp_scale(self):
        manifest = __import__("json").loads(Path(self.out, "stages-manifest.json").read_text(encoding="utf-8"))
        caps = {k: tuple(v) for k, v in manifest["policy"]["extendedStagePriceCap"].items()}
        self.assertEqual(caps, {"car": (25000, 37500, 50000), "bike": (20000, 30000, 40000)})
        self.assertEqual(manifest["policy"]["extendedPriceFactor"], 2.0)
        prices = {}
        for model in manifest["models"]:
            stage_prices = tuple(s["proposedPrice"] for s in model["stages"])
            prices[model["record"]] = stage_prices
            if model["dealer"]:
                self.assertIsNone(model["stagePriceCap"])
                continue
            self.assertEqual(model["price"], 2 * model["referencePrice"], model["record"])
            self.assertEqual(model["tier"], ms.tier_of(model["ladder"], model["price"]), model["record"])
            self.assertEqual(tuple(model["stagePriceCap"]), caps[model["ladder"]])
            for i, p in enumerate(stage_prices):
                self.assertLessEqual(p, caps[model["ladder"]][i], model["record"])
                self.assertGreaterEqual(p, ms.PRICE_FLOOR[i], model["record"])
                self.assertEqual(p % ms.PRICE_ROUND, 0, model["record"])
            self.assertEqual(list(stage_prices), sorted(stage_prices), model["record"])
        # The caps are the dearest dealer stages: the Semimaru and the Kusanagi.
        self.assertEqual(prices["Vehicle.v_sport1_yaiba_semimaru_player"], caps["car"])
        self.assertEqual(prices["Vehicle.v_sportbike1_yaiba_kusanagi_player"], caps["bike"])
        self.assertEqual(prices["Vehicle.v_sport2_quadra_type66_player"], (9000, 13000, 17500))
        self.assertEqual(prices["Vehicle.v_sportbike1_yaiba_kusanagi_player_02"], (15000, 22500, 30000))
        self.assertEqual(prices["Vehicle.v_sport1_rayfield_aerondight_player"], caps["car"])

    def test_lightrp_catalogue(self):
        text = Path(self.out, ms.LIGHTRP_CATALOGUE).read_text(encoding="utf-8")
        self.assertFalse(text.startswith("\ufeff"))
        manifest = __import__("json").loads(Path(self.out, "stages-manifest.json").read_text(encoding="utf-8"))
        self.assertEqual(text.count("] = { class = '"), len(ms.MODELS))
        for model in manifest["models"]:
            prices = ", ".join(str(s["proposedPrice"]) for s in model["stages"])
            line = (f"['{model['record']}'] = {{ class = '{model['ladder']}', tier = {model['tier']}, "
                    f"dealer = {'true' if model['dealer'] else 'false'}, prices = {{ {prices} }}, ")
            self.assertIn(line, text, model["record"])
        self.assertIn("sounds = { car = 12, bike = 4 }", text)

    def test_stage_yaml_is_unchanged_by_sounds(self):
        alone = os.path.join(self.tmp.name, "alone")
        log = _generate(alone, "--no-sounds")
        self.assertNotIn("VK_SOUNDS_GEN_OK", log)
        self.assertFalse(os.path.exists(os.path.join(alone, es.YAML_NAME)))
        a = Path(self.out, ms.YAML_NAME).read_bytes()
        b = Path(alone, ms.YAML_NAME).read_bytes()
        self.assertEqual(a, b)

    def test_check_sounds_against_the_shipped_stage_yaml(self):
        buf = io.StringIO()
        with contextlib.redirect_stdout(buf), contextlib.redirect_stderr(buf):
            code = ms.main(["--game", game_dir(), "--check-sounds", os.path.join(self.out, es.YAML_NAME),
                            "--stages-yaml", os.path.join(self.out, ms.YAML_NAME)])
        self.assertEqual(code, 0, buf.getvalue())
        self.assertIn("VK_SOUNDS_CHECK_OK records=", buf.getvalue())

    def test_a_tampered_yaml_is_refused(self):
        text = Path(self.out, es.YAML_NAME).read_text(encoding="utf-8")
        bad = os.path.join(self.tmp.name, "bad.yaml")
        Path(bad).write_text(text.replace("player_audio_resource: v_car_quadra_type_66",
                                          "player_audio_resource: v_av_basilisk_tank", 1), encoding="utf-8")
        buf = io.StringIO()
        with contextlib.redirect_stdout(buf), contextlib.redirect_stderr(buf):
            code = ms.main(["--game", game_dir(), "--check-sounds", bad])
        self.assertEqual(code, 1)
        self.assertIn("audio flat", buf.getvalue())

    def test_every_sound_record_copies_its_stage_links(self):
        stages = ms.parse_yaml(Path(self.out, ms.YAML_NAME).read_text(encoding="utf-8"))
        sounds = ms.parse_yaml(Path(self.out, es.YAML_NAME).read_text(encoding="utf-8"))
        for name, flats in sounds.items():
            m = es.NAME_RE.match(name)
            base, stage = m.group("base"), int(m.group("stage") or 0)
            self.assertEqual(flats["$base"], base)
            links = {k: v for k, v in flats.items() if k != "$base" and k not in es.AUDIO_FLATS}
            want = {k: v for k, v in stages[ms.stage_name(base, stage)].items() if k != "$base"} if stage else {}
            self.assertEqual(links, want, name)


@unittest.skipIf(NO_GAME or luahost.unavailable(), NO_GAME or luahost.unavailable() or "")
class LuaScenarioTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.tmp = tempfile.TemporaryDirectory()
        cls.out = os.path.join(cls.tmp.name, "out")
        _generate(cls.out)

    @classmethod
    def tearDownClass(cls):
        cls.tmp.cleanup()

    def _run(self, mode: str) -> str:
        names = ms.parse_yaml(Path(self.out, es.YAML_NAME).read_text(encoding="utf-8"))
        return luahost.run(HERE / "lua" / "stages_main_scenarios.lua", {
            "STAGES": os.path.join(self.out, "stages.lua"),
            "SOUNDS": os.path.join(self.out, "engine-sounds.lua") if mode == "full" else "",
            "MAIN": str(HERE / "lua" / "stages_main.lua"),
            "SOUND_NAMES": "\n".join(names),
            "MODE": mode,
        })

    def test_full_build(self):
        self.assertEqual(self._run("full"), "ok")

    def test_stage_only_build(self):
        self.assertEqual(self._run("stages-only"), "ok")


if __name__ == "__main__":
    unittest.main()
