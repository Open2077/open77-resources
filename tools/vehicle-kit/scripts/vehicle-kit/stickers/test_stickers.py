"""Tests of the sticker pack generators (wave 2, W2.4) and of the sticker resource's Lua.

Offline, from the committed survey (data/stickers-dealer-2.50.json) and the spec; no game and no
WolvenKit needed:
- the plan: curation rules, decal limits, exclusions, neutral labels, determinism, and the
  plan check's negative tests (every mutation of a good plan refused);
- the cook (st_cook.py prepare) on stand-in mesh facts: records, entities carrying the vanilla
  look and placement, the reference rule, the Lua catalogue;
- the resource Lua in a real Lua 5.4 (scripts/furniture/luahost.py), three server shapes: every
  field accepted, unknown fields refused (contract rows retried), no wave-2 natives.

The ORIGINAL sticker pack (build-original-stickers.ps1, our own motifs):
- the cook (st_ocook.py prepare) on synthetic placements, the WolvenKit mesh step stubbed:
  record shapes, the 12-decal cap, the reference rule, the catalogue in the registerStickers
  shape, and the resource Lua on that catalogue (lua/original_stickers_scenarios.lua);
- no vanilla bytes: the scan the build runs (plates.cjs scan) catches a shared block, the
  names-table check after it (st_ocook.py scan-names) lets a verified CR2W names table or a
  verified vertex format descriptor through and nothing else (a layout that carries vertices, or
  an enum that names no packing value, is refused), and the committed sticker sources hold no
  game file;
- the themes: each its own catalogue group (Light RP's Auto Studio heading), theme 01's sticker
  ids unchanged, no theme 03, the L/R mirroring rule, every theme's zones under the engine cap and
  its required zones under maxDecalsPerSet;
- with numpy and pillow only (skipped otherwise): the motif art (st_draw/st_art: deterministic,
  theme 01's bytes pinned, no motif touching its texture's edge where it is not cut, tapered
  strokes at full width between their tapers), the spec's rules and their refusals, and the
  placement geometry on synthetic panels: L/R mirroring, the decal offset, the host frame and the
  placement assertions, crop 'u' bands (length, height, the end kept), thin lines measured per
  cell, bands under two cells tall still measured, the rear-door zone, the height a continued
  pinstripe keeps, the fallback emblem, and the optional motifs left out over the set budget.

    uv run --no-project python -I -m unittest discover -s scripts/vehicle-kit/stickers -p "test_*.py" -v
    uv run --no-project --with pillow==13.0.0 --with numpy==2.5.4 python -I -m unittest discover -s scripts/vehicle-kit/stickers -p "test_*.py" -v
"""
from __future__ import annotations

import contextlib
import copy
import hashlib
import importlib.util
import io
import json
import os
import re
import shutil
import struct
import subprocess
import sys
import tempfile
import types
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent
REPO = HERE.parents[2]
sys.path.insert(0, str(HERE))
sys.path.insert(0, str(HERE.parent / "liveries"))
sys.path.insert(0, str(HERE.parent / "inventory"))


def _module(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    mod = importlib.util.module_from_spec(spec)
    sys.modules[name] = mod
    spec.loader.exec_module(mod)
    return mod


sp = _module("st_plan", HERE / "st_plan.py")
sc = _module("st_cook", HERE / "st_cook.py")
luahost = _module("vk_luahost_st", REPO / "scripts" / "furniture" / "luahost.py")
so = _module("st_ocook", HERE / "st_ocook.py")
try:
    import numpy as np
    import PIL  # noqa: F401
    NUMERIC = None
except ImportError:
    NUMERIC = "numpy and pillow absent (run with --with numpy --with pillow)"

DATA = HERE / "data" / "stickers-dealer-2.50.json"
SPEC = HERE / "specs" / "lightrp-stickers.json"
BS = "\\"


def load():
    return json.loads(DATA.read_text(encoding="utf-8")), json.loads(SPEC.read_text(encoding="utf-8"))


class PlanTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.survey, cls.spec = load()
        cls.plan = sp.build_plan(cls.survey, cls.spec)

    def stickers(self):
        return [s for m in self.plan["models"] for s in m["stickers"]]

    def test_plan_passes_its_check_and_every_mutation_is_refused(self):
        sp.check_plan(self.plan, self.spec, self.survey)
        failures, total = sp.negative_tests(self.plan, self.spec, self.survey)
        self.assertEqual(failures, [])
        self.assertGreaterEqual(total, 13)

    def test_decal_limits(self):
        limit = self.spec["maxDecalsPerSticker"]
        self.assertLessEqual(limit, self.spec["maxDecalsPerCar"])
        self.assertLessEqual(self.spec["maxDecalsPerCar"], 12)
        for s in self.stickers():
            self.assertEqual(s["decals"], len(s["parts"]), s["id"])
            self.assertTrue(1 <= s["decals"] <= limit, s["id"])

    def test_contract_exclusions(self):
        words = ("police", "sheriff", "border", "patrol", "ncpd", "maxtac", "arasaka", "delamain")
        for m in self.plan["models"]:
            for d in m["decals"]:
                text = (d["mesh"] + " " + d["sourceComponent"]).lower()
                self.assertFalse([w for w in words if w in text], d["record"])
            for s in m["stickers"]:
                for app in s["source"]:
                    self.assertFalse([w for w in words if w in app.lower()], s["id"])

    def test_labels_are_neutral(self):
        dealer = json.loads((REPO / "docs" / "generated" / "vehicle-components-dealer-2.50.json").read_text(encoding="utf-8"))
        brand = set()
        for m in dealer["models"]:
            brand.update(w for w in re.split(r"[^a-z0-9]+", m["record"].lower()) if len(w) > 2)
        brand -= {"vehicle", "player", "standard2", "standard25", "sportbike1", "sportbike3", "sport", "basic"}
        brand |= {"judy", "nancy", "steve", "steves", "trevor", "trevors", "jackie", "bobas", "growl", "jammer", "rcs"}
        for s in self.stickers():
            words = set(re.split(r"[^a-z0-9]+", s["label"].lower()))
            self.assertFalse(words & brand, f"{s['id']} {s['label']!r}")
            self.assertRegex(s["label"], sp.LABEL_RE)

    def test_no_interior_hidden_or_already_fitted_row(self):
        rows = {m["key"]: {sp.row_hash(r): r for r in m["stickers"]} for m in self.survey["models"]}
        for m in self.plan["models"]:
            for d in m["decals"]:
                r = rows[m["key"]][d["id"]]
                self.assertFalse(r["interior"] or r["chunkMask"] == "0" or r["inPlayerAppearance"], d["record"])
                self.assertIn(d["component"], m["hosts"])

    def test_deterministic(self):
        again = sp.build_plan(copy.deepcopy(self.survey), copy.deepcopy(self.spec))
        self.assertEqual(json.dumps(again, sort_keys=True), json.dumps(self.plan, sort_keys=True))

    def test_an_unclassified_appearance_is_refused(self):
        spec = copy.deepcopy(self.spec)
        spec["appearances"].pop("chevalier_thrax__basic_valentinos_02")
        with self.assertRaisesRegex(sp.PlanError, "does not classify"):
            sp.build_plan(self.survey, spec)

    def test_a_missing_contract_exclusion_is_refused(self):
        spec = copy.deepcopy(self.spec)
        spec["excludeTokens"]["contract"].remove("delamain")
        with self.assertRaisesRegex(sp.PlanError, "delamain"):
            sp.build_plan(self.survey, spec)

    def test_split_keeps_families_together(self):
        decals = [{"family": f} for f in ["body"] * 3 + ["front"] * 2 + ["left"] * 4 + ["right"] * 3 + ["rear"]]
        parts = sp.split(decals, 6)
        self.assertEqual([len(p) for p in parts], [5, 4, 4])
        self.assertEqual([len(p) for p in sp.split([{"family": "body"}] * 8, 6)], [6, 2])

    def test_lua_without_bom_and_ps1_with_bom(self):
        for path in (HERE / "lua").glob("*.lua"):
            self.assertFalse(path.read_bytes().startswith(b"\xef\xbb\xbf"), path.name)
        self.assertTrue((HERE / "build-stickers.ps1").read_bytes().startswith(b"\xef\xbb\xbf"))
        self.assertTrue((HERE / "build-original-stickers.ps1").read_bytes().startswith(b"\xef\xbb\xbf"))


def fake_meshes(plan, folder: Path):
    """Stand-in mesh facts (appearance names only) for every planned vanilla mesh."""
    names = {}
    for m in plan["models"]:
        for d in m["decals"]:
            names.setdefault(d["mesh"], set()).add(d["meshAppearance"])
    for mesh, apps in names.items():
        root = {"appearances": [{"Data": {"name": {"$type": "CName", "$value": a}}} for a in sorted(apps)]}
        p = folder / (mesh.replace(BS, "~") + ".json")
        p.write_text(json.dumps({"Data": {"RootChunk": root}}), encoding="utf-8")


class CookTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        survey, spec = load()
        cls.plan = sp.build_plan(survey, spec)
        cls.tmp = tempfile.TemporaryDirectory()
        t = Path(cls.tmp.name)
        (t / "mesh").mkdir()
        fake_meshes(cls.plan, t / "mesh")
        (t / "plan.json").write_text(json.dumps(cls.plan), encoding="utf-8")
        cls.prefix = "open77\\assets\\lightrp_vehicle_stickers\\0123456789ab"
        cls.cfg = {"plan": str(t / "plan.json"), "prefix": cls.prefix, "resource": "lightrp_vehicle_stickers",
                   "revision": "0123456789ab" + "0" * 52, "wolvenkit": "8.20.0", "meshJsonDir": str(t / "mesh"),
                   "preparedDir": str(t / "prepared"), "roundtripDir": str(t / "rt"),
                   "yamlOut": str(t / "s.yaml"), "luaOut": str(t / "stickers.lua"),
                   "catalogueOut": str(t / "catalogue.json"), "packageOut": str(t / "package.json")}
        with contextlib.redirect_stdout(io.StringIO()):
            sc.prepare(cls.cfg)
        cls.package = json.loads(Path(cls.cfg["packageOut"]).read_text(encoding="utf-8"))

    @classmethod
    def tearDownClass(cls):
        cls.tmp.cleanup()

    def test_records(self):
        text = Path(self.cfg["yamlOut"]).read_text(encoding="utf-8")
        names = re.findall(r"^(Vehicle\.[A-Za-z0-9_]+):$", text, re.M)
        decals = sum(len(m["decals"]) for m in self.plan["models"])
        stickers = sum(len(m["stickers"]) for m in self.plan["models"])
        self.assertEqual(len(names), decals + stickers)
        self.assertEqual(len(set(names)), len(names))
        self.assertEqual(text.count("$type: VehicleDecalAttachment"), decals)
        self.assertEqual(text.count("$type: VehicleColorTemplate"), stickers)
        body = " ".join(line for line in text.splitlines() if not line.startswith("#"))
        self.assertNotIn("AppearancesToColorTemplate", body)
        self.assertNotIn("!append", body)
        for n in names:
            self.assertTrue(n.startswith(("Vehicle.o77_st_", "Vehicle.o77_sticker_")), n)

    def test_entities_carry_the_vanilla_look_and_placement(self):
        for m in self.plan["models"]:
            for d in m["decals"]:
                depot = f"{self.prefix}{BS}decals{BS}{m['key']}{BS}{d['id']}.ent"
                doc = json.loads((Path(self.cfg["preparedDir"]) / (depot.replace(BS, "~") + ".json")).read_text(encoding="utf-8"))
                root = doc["Data"]["RootChunk"]
                for comp in (root["components"][0], root["compiledData"]["Data"]["Chunks"][1]):
                    self.assertEqual(comp["mesh"]["DepotPath"]["$value"], d["mesh"])
                    self.assertEqual(comp["meshAppearance"]["$value"], d["meshAppearance"])
                    self.assertEqual(comp["chunkMask"], d["chunkMask"])
                    self.assertEqual([comp["localTransform"]["Position"][a]["Bits"] for a in "xyz"], d["transform"]["positionBits"])
                    self.assertIsNone(sc.same_look(comp, comp))
                self.assertEqual(doc["Header"]["ArchiveFileName"], depot)

    def test_only_planned_vanilla_meshes_are_referenced(self):
        meshes = {d["mesh"] for m in self.plan["models"] for d in m["decals"]}
        self.assertEqual(set(self.package["referencedMeshes"]), meshes)
        for f in self.package["files"]:
            self.assertTrue(f.startswith(self.prefix + BS) and f.endswith(".ent"), f)

    def test_unknown_mesh_appearance_is_refused(self):
        cfg = dict(self.cfg)
        bad = copy.deepcopy(self.plan)
        d = next(d for m in bad["models"] for d in m["decals"] if d["meshAppearance"] != "default")
        d["meshAppearance"] = "no_such_appearance"
        p = Path(self.tmp.name) / "bad-plan.json"
        p.write_text(json.dumps(bad), encoding="utf-8")
        cfg["plan"] = str(p)
        cfg["preparedDir"] = str(Path(self.tmp.name) / "prepared-bad")
        with contextlib.redirect_stdout(io.StringIO()), self.assertRaises(SystemExit) as e:
            sc.prepare(cfg)
        self.assertIn("meshAppearance", str(e.exception))

    def test_catalogue_json_matches_the_contract_shape(self):
        cat = json.loads(Path(self.cfg["catalogueOut"]).read_text(encoding="utf-8"))
        for s in cat["stickers"]:
            for k in ("id", "label", "group", "model", "decals"):
                self.assertIn(k, s)
            self.assertEqual(len(s["parts"]), s["decals"])
            for p in s["parts"]:
                self.assertTrue(p["decal"].startswith(self.prefix))

    @unittest.skipIf(luahost.unavailable(), luahost.unavailable() or "")
    def test_resource_lua(self):
        for mode in ("full", "strict", "none"):
            with self.subTest(mode=mode):
                got = luahost.run(HERE / "lua" / "stickers_main_scenarios.lua", {
                    "CATALOGUE": self.cfg["luaOut"], "MAIN": str(HERE / "lua" / "stickers_main.lua"), "MODE": mode})
                self.assertEqual(got, "ok")


# ----------------------------------------------------------------------------- original stickers
OSPEC = HERE / "specs" / "original-stickers.json"
OPREFIX = "open77\\assets\\lightrp_vehicle_original_stickers\\0123456789ab"
# Theme 01's motifs as st_art renders them (RGBA bytes, sha256): the pilot's textures, unchanged.
COURSE_ART_SHA256 = {
    "hood": "82b8b8cd2488da2b25c6840c78528f66b527e44a183e5a5de9cd479097e50e1c",
    "roof": "cc629ebd5dfd41ab9bc1e524e7a9d93b4da7a589a7cffa334adb88d8c36fd9cc",
    "trunk": "a299c7bf2f9437d86fd34f00d9495c5a106630fa14382b5029a5e80408a9998f",
    "roundel": "d6da02cd6743e2f82d1120145e8ab1f77b88a0627de0d229e5c727d4ea92eb54",
    "sill": "e83533cf5af3b416f154476a2ea987844a9fb330fa18badcefe2792b299253a4",
    "flag": "8b771da69aa27cf953a012f27f60ac3f2a0a65cc99c39982a2417b8049bd4979",
}
GAME_EXTENSIONS = (".mesh", ".xbm", ".ent", ".app", ".mi", ".mt", ".mlsetup", ".mlmask", ".archive", ".glb", ".rig",
                   ".anims", ".csv", ".bk2", ".wem")


def ospec():
    return json.loads(OSPEC.read_text(encoding="utf-8"))


def synthetic_placements(models, decals_per_set=None, themes=(0,)):
    """placements.json rows for the themes (indexes; the course theme by default) on `models`, one
    decal per zone of the spec, at most maxDecalsPerSet unless decals_per_set says otherwise."""
    spec = ospec()
    sets = []
    for ti in themes:
        theme = spec["themes"][ti]
        zones = [(m["id"], z) for m in theme["motifs"] for z in m["zones"]]
        for key, record in models:
            rows = []
            for i in range(decals_per_set or min(len(zones), spec["maxDecalsPerSet"])):
                motif, zone = zones[i % len(zones)]
                zone = zone if i < len(zones) else f"{zone}{i}"
                rows.append({"zone": zone, "motif": motif, "stem": f"{theme['id']}_{motif}", "host": "body_01",
                             "glb": f"{key}/{theme['id']}_{zone}.glb", "triangles": 8})
            sets.append({"model": key, "record": record, "theme": theme["id"], "decalCount": len(rows), "decals": rows,
                         "skipped": []})
    return {"sets": sets}


def stub_prepare_mesh(references):
    def prepare_mesh(cfg, model_key, comp, info, designs, textures, depot):
        refs = [textures[designs[0]]["d"], textures[designs[0]]["m"]] + list(references)
        doc = {"Header": {"ArchiveFileName": depot},
               "Data": {"RootChunk": {"$type": "CMesh", "refs": [{"DepotPath": {"$type": "ResourcePath", "$value": r}}
                                                                 for r in refs]}}}
        return doc, 0
    return prepare_mesh


class OriginalCookTests(unittest.TestCase):
    """st_ocook.py prepare on synthetic placements; the WolvenKit mesh step (lv_cook.prepare_mesh,
    which needs an imported mesh) is stubbed, everything else is the real cook."""
    MODELS = [("thrax", "Vehicle.v_standard2_chevalier_thrax_player"), ("hella", "Vehicle.v_standard2_archer_hella_player")]

    @classmethod
    def setUpClass(cls):
        cls.tmp = tempfile.TemporaryDirectory()
        cls.cfg = cls.write_cfg(Path(cls.tmp.name) / "ok", synthetic_placements(cls.MODELS))
        cls.run_prepare(cls.cfg)
        cls.package = json.loads(Path(cls.cfg["packageOut"]).read_text(encoding="utf-8"))
        cls.catalogue = json.loads(Path(cls.cfg["catalogueOut"]).read_text(encoding="utf-8"))

    @classmethod
    def tearDownClass(cls):
        cls.tmp.cleanup()

    @staticmethod
    def write_cfg(folder: Path, placements):
        folder.mkdir(parents=True, exist_ok=True)
        (folder / "placements.json").write_text(json.dumps(placements), encoding="utf-8")
        spec = ospec()
        textures = [{"motif": f"{t['id']}_{m['id']}", "kind": k,
                     "depot": f"{OPREFIX}{BS}textures{BS}{t['id']}_{m['id']}_{k}.xbm"}
                    for t in spec["themes"] for m in t["motifs"] for k in ("d", "m")]
        meshes = [{"model": s["model"], "theme": s["theme"], "zone": d["zone"], "importedJson": "unused"}
                  for s in placements["sets"] for d in s["decals"]]
        return {"spec": str(OSPEC), "placements": str(folder / "placements.json"), "prefix": OPREFIX,
                "resource": spec["resource"], "revision": "0123456789ab" + "0" * 52, "wolvenkit": "8.20.0",
                "textures": textures, "meshes": meshes,
                "allowedReferences": ["base\\vehicles\\common\\materials\\stickers.mi", "engine\\textures\\editor\\normal.xbm"],
                "preparedDir": str(folder / "prepared"), "roundtripDir": str(folder / "rt"),
                "yamlOut": str(folder / "o.yaml"), "luaOut": str(folder / "stickers.lua"),
                "catalogueOut": str(folder / "catalogue.json"), "packageOut": str(folder / "package.json")}

    @staticmethod
    def run_prepare(cfg, references=("base\\vehicles\\common\\materials\\stickers.mi",)):
        saved = so.prepare_mesh
        so.prepare_mesh = stub_prepare_mesh(references)
        try:
            with contextlib.redirect_stdout(io.StringIO()):
                so.prepare(cfg)
        finally:
            so.prepare_mesh = saved

    def test_records(self):
        text = Path(self.cfg["yamlOut"]).read_text(encoding="utf-8")
        names = re.findall(r"^(Vehicle\.[A-Za-z0-9_]+):$", text, re.M)
        sets = self.catalogue["stickers"]
        decals = sum(s["decals"] for s in sets)
        self.assertEqual(len(names), decals + len(sets))
        self.assertEqual(len(set(names)), len(names))
        self.assertEqual(text.count("$type: VehicleDecalAttachment"), decals)
        self.assertEqual(text.count("$type: VehicleColorTemplate"), len(sets))
        body = " ".join(line for line in text.splitlines() if not line.startswith("#"))
        self.assertNotIn("AppearancesToColorTemplate", body)
        self.assertNotIn("!append", body)
        for n in names:
            self.assertTrue(n.startswith(("Vehicle.o77_os_", "Vehicle.o77_sticker_os_")), n)
            self.assertRegex(n, r"^Vehicle\.o77_[A-Za-z0-9_]{1,116}\Z")
        for s in sets:      # the holder lists exactly its own decal records, in order
            block = text.split(f"{s['record']}:\n", 1)[1].split("\n\n", 1)[0]
            self.assertEqual(re.findall(r"^    - (\S+)$", block, re.M), [p["record"] for p in s["parts"]])

    def test_catalogue_matches_the_register_stickers_shape(self):
        cat = self.catalogue
        self.assertEqual(cat["schema"], "open77.vehicle-stickers.catalogue/1")
        self.assertEqual(cat["command"], ospec()["command"])
        self.assertEqual(cat["maxDecalsPerCar"], 12)
        self.assertEqual(len(cat["stickers"]), len(self.MODELS))
        for s, (key, record) in zip(cat["stickers"], self.MODELS):
            self.assertEqual(s["id"], f"os.{key}.course")
            self.assertRegex(s["id"], r"^[a-z0-9][a-z0-9_.-]{0,63}\Z")
            self.assertEqual(s["model"], record)
            self.assertIsInstance(s["decals"], int)
            self.assertEqual(s["decals"], len(s["parts"]))
            self.assertTrue(1 <= s["decals"] <= 12)
            self.assertNotRegex(s["label"].lower(), r"police|ncpd|sheriff|border patrol|arasaka|delamain")
            for p in s["parts"]:
                self.assertRegex(p["component"], r"^[A-Za-z0-9_]{1,128}\Z")
                self.assertRegex(p["decal"], r"^[A-Za-z0-9_\-.\\/]{1,250}\.ent\Z")
                self.assertTrue(p["decal"].startswith(OPREFIX + BS))
        lua = Path(self.cfg["luaOut"]).read_bytes()
        self.assertFalse(lua.startswith(b"\xef\xbb\xbf"))
        self.assertIn(b"command = \"osticker\"", lua)

    def test_files_stay_in_the_pack(self):
        for f in self.package["files"]:
            self.assertTrue(f.startswith(OPREFIX + BS) and f.endswith((".mesh", ".ent")), f)
        self.assertEqual(len(self.package["files"]), 2 * len(self.package["decalRecords"]))

    def test_a_set_over_twelve_decals_is_refused(self):
        cfg = self.write_cfg(Path(self.tmp.name) / "cap", synthetic_placements(self.MODELS[:1], decals_per_set=13))
        with self.assertRaises(SystemExit) as e:
            self.run_prepare(cfg)
        self.assertIn("13 decals", str(e.exception))
        cfg = self.write_cfg(Path(self.tmp.name) / "cap12", synthetic_placements(self.MODELS[:1], decals_per_set=12))
        self.run_prepare(cfg)

    def test_a_vanilla_reference_is_refused(self):
        cfg = self.write_cfg(Path(self.tmp.name) / "ref", synthetic_placements(self.MODELS[:1]))
        with self.assertRaises(SystemExit) as e:
            self.run_prepare(cfg, references=("base\\vehicles\\standard\\some_vanilla.mesh",))
        self.assertIn("outside the pack", str(e.exception))

    @unittest.skipIf(luahost.unavailable(), luahost.unavailable() or "")
    def test_resource_lua(self):
        for mode in ("full", "strict", "none"):
            with self.subTest(mode=mode):
                got = luahost.run(HERE / "lua" / "original_stickers_scenarios.lua", {
                    "CATALOGUE": self.cfg["luaOut"], "MAIN": str(HERE / "lua" / "stickers_main.lua"), "MODE": mode,
                    "RESOURCE": ospec()["resource"]})
                self.assertEqual(got, "ok")


class OriginalThemesTests(unittest.TestCase):
    """Every theme of the spec cooked at once (as the build does): one catalogue group per theme,
    theme 01's ids unchanged, and the spec's theme rules."""

    @classmethod
    def setUpClass(cls):
        cls.spec = ospec()
        cls.tmp = tempfile.TemporaryDirectory()
        placements = synthetic_placements(OriginalCookTests.MODELS, themes=range(len(cls.spec["themes"])))
        cls.cfg = OriginalCookTests.write_cfg(Path(cls.tmp.name) / "themes", placements)
        OriginalCookTests.run_prepare(cls.cfg)
        cls.catalogue = json.loads(Path(cls.cfg["catalogueOut"]).read_text(encoding="utf-8"))

    @classmethod
    def tearDownClass(cls):
        cls.tmp.cleanup()

    def test_each_theme_is_its_own_catalogue_group(self):
        themes = {t["id"]: t for t in self.spec["themes"]}
        rows = self.catalogue["stickers"]
        self.assertEqual(len(rows), len(themes) * len(OriginalCookTests.MODELS))
        seen = {}
        for r in rows:
            _prefix, key, theme = r["id"].split(".")
            self.assertEqual(r["id"], f"os.{key}.{theme}")
            self.assertEqual(r["group"], themes[theme]["group"], r["id"])
            self.assertEqual(r["label"], themes[theme]["label"], r["id"])
            self.assertTrue(1 <= r["decals"] <= self.spec["maxDecalsPerSet"], r["id"])
            seen.setdefault(r["group"], set()).add(theme)
        self.assertEqual(len(seen), len(themes))                       # one group per theme, none shared
        self.assertTrue(all(len(v) == 1 for v in seen.values()), seen)
        lua = Path(self.cfg["luaOut"]).read_text(encoding="utf-8")
        for t in themes.values():
            self.assertIn(f'group = "{t["group"]}"', lua)

    def test_theme_01_keeps_its_sticker_ids(self):
        self.assertEqual(self.spec["themes"][0]["id"], "course")
        self.assertEqual((self.spec["idPrefix"], self.spec["resource"]), ("os", "lightrp_vehicle_original_stickers"))
        rows = [r for r in self.catalogue["stickers"] if r["id"].endswith(".course")]
        self.assertEqual([r["id"] for r in rows], [f"os.{k}.course" for k, _ in OriginalCookTests.MODELS])
        self.assertEqual([r["record"] for r in rows], [f"Vehicle.o77_sticker_os_{k}_course" for k, _ in OriginalCookTests.MODELS])

    def test_theme_labels_groups_and_ids(self):
        ids, groups = set(), set()
        for t in self.spec["themes"]:
            self.assertRegex(t["id"], r"^[a-z0-9]{2,16}\Z")
            for k in ("label", "group"):                               # the server's rule: <= 64, no control char
                self.assertRegex(t[k], r"^[\x20-\x7e]{1,64}\Z", f"{t['id']}.{k}")
            self.assertNotRegex(f"{t['label']} {t['group']}".lower(), r"police|ncpd|sheriff|arasaka|delamain|sponsor")
            ids.add(t["id"])
            groups.add(t["group"])
            for m in t["motifs"]:
                self.assertRegex(m["id"], r"^[a-z0-9]{2,16}\Z")
        self.assertEqual(len(ids), len(self.spec["themes"]))
        self.assertEqual(len(groups), len(self.spec["themes"]))
        self.assertEqual(sorted(ids), sorted(["course", "graffiti", "tech", "vague", "filet"]))
        self.assertFalse([t for t in self.spec["themes"] if t["board"].startswith("03") or "sponsor" in t["board"].lower()])

    def test_every_theme_fits_the_caps(self):
        spec = self.spec
        self.assertLessEqual(spec["maxDecalsPerSet"], spec["maxDecalsPerCar"])
        self.assertLessEqual(spec["maxDecalsPerCar"], 12)
        for t in spec["themes"]:
            zones = [z for m in t["motifs"] for z in m["zones"]]
            required = [z for m in t["motifs"] if not m.get("optional") for z in m["zones"]]
            self.assertEqual(len(zones), len(set(zones)), t["id"])
            self.assertLessEqual(len(zones), spec["maxDecalsPerCar"], t["id"])       # never past the engine cap
            self.assertLessEqual(len(required), spec["maxDecalsPerSet"], t["id"])    # the optional ones close the gap

    def test_left_right_mirroring_rule(self):
        # Paired side motifs are mirrored on the right (they point the same way relative to the car),
        # except readable text and numbers: theme 01's number roundel.
        sides = {"door_l", "door_r", "door2_l", "door2_r", "sill_l", "sill_r", "wing_fl", "wing_fr", "wing_rl", "wing_rr"}
        for t in self.spec["themes"]:
            for m in t["motifs"]:
                if set(m["zones"]) & sides:
                    readable = (t["id"], m["id"]) == ("course", "roundel")
                    self.assertEqual(bool(m.get("mirror")), not readable, f"{t['id']}/{m['id']}")

    @unittest.skipIf(luahost.unavailable(), luahost.unavailable() or "")
    def test_resource_lua_on_every_theme(self):
        for mode in ("full", "strict", "none"):
            with self.subTest(mode=mode):
                got = luahost.run(HERE / "lua" / "original_stickers_scenarios.lua", {
                    "CATALOGUE": self.cfg["luaOut"], "MAIN": str(HERE / "lua" / "stickers_main.lua"), "MODE": mode,
                    "RESOURCE": self.spec["resource"]})
                self.assertEqual(got, "ok")


class OriginalTrimsTests(unittest.TestCase):
    """A set that fits trims of its body (placements.json `records`, st_place.trim_records): the
    catalogue row lists them under `models` (primary first, at most 64, the server's MaximumModels),
    every record lists the set, and the resource Lua registers the list."""

    TRIMS = ["Vehicle.v_test_trim_a_player", "Vehicle.v_test_trim_b_player"]

    def placements(self, records):
        placements = synthetic_placements(OriginalCookTests.MODELS[:2], themes=(0, 1))
        placements["sets"][0]["records"] = records
        return placements

    def test_trims_are_listed_and_registered(self):
        with tempfile.TemporaryDirectory() as t:
            primary = OriginalCookTests.MODELS[0][1]
            cfg = OriginalCookTests.write_cfg(Path(t) / "trims", self.placements([primary] + self.TRIMS))
            OriginalCookTests.run_prepare(cfg)
            cat = json.loads(Path(cfg["catalogueOut"]).read_text(encoding="utf-8"))
            first, *others = cat["stickers"]
            self.assertEqual(first["models"], [primary] + self.TRIMS)
            self.assertEqual(first["model"], primary)
            self.assertFalse([s["id"] for s in others if "models" in s])      # one record: no list
            for r in [primary] + self.TRIMS:
                self.assertIn(first["id"], cat["models"][r]["stickers"])
            lua = Path(cfg["luaOut"]).read_text(encoding="utf-8")
            self.assertIn("models = { " + ", ".join(f'"{r}"' for r in [primary] + self.TRIMS) + " }, ", lua)
            if not luahost.unavailable():
                for mode in ("full", "strict", "none"):
                    with self.subTest(mode=mode):
                        got = luahost.run(HERE / "lua" / "original_stickers_scenarios.lua", {
                            "CATALOGUE": cfg["luaOut"], "MAIN": str(HERE / "lua" / "stickers_main.lua"), "MODE": mode,
                            "RESOURCE": ospec()["resource"]})
                        self.assertEqual(got, "ok")

    def test_bad_trim_lists_are_refused(self):
        primary = OriginalCookTests.MODELS[0][1]
        many = [primary] + [f"Vehicle.v_test_trim_{i:02d}_player" for i in range(64)]
        for records, needle in (([self.TRIMS[0], primary], "must start with the primary"),
                                ([primary, self.TRIMS[0], self.TRIMS[0]], "once each"),
                                (many, "64 at most")):
            with self.subTest(needle=needle), tempfile.TemporaryDirectory() as t:
                cfg = OriginalCookTests.write_cfg(Path(t) / "bad", self.placements(records))
                with self.assertRaises(SystemExit) as e:
                    OriginalCookTests.run_prepare(cfg)
                self.assertIn(needle, str(e.exception))


class OriginalScopeTests(unittest.TestCase):
    """The spec covers every vanilla player body of the scope table once: the dealer models
    (strict placement) and extendedModels (lenient), keyed as the component table keys them."""

    def test_models_and_extended_models_cover_the_scope(self):
        spec = ospec()
        scope = json.loads((REPO / "docs" / "generated" / "vehicle-player-scope-2.50.json").read_text(encoding="utf-8"))
        player = json.loads((REPO / "docs" / "generated" / "vehicle-components-player-bodies-2.50.json").read_text(encoding="utf-8"))
        keys = [b["key"] for b in scope["bodies"]]
        listed = spec["models"] + spec["extendedModels"]
        self.assertEqual(len(listed), len(set(listed)))
        self.assertEqual(sorted(listed), sorted(keys))
        self.assertEqual(sorted(m["key"] for m in player["models"]), sorted(keys))
        for k in listed:
            self.assertRegex(k, r"^[a-z0-9_]{1,40}\Z")
            self.assertNotRegex(k, r"police|ncpd|sheriff|border|arasaka|delamain")
        # every trim of a body is a record of the scope, each record in one body only
        records = [r["record"] for b in scope["bodies"] for r in b["records"]]
        self.assertEqual(len(records), len(set(records)))
        self.assertEqual(scope["counts"]["inScope"], len(records))

    def test_quest_variants_are_out_of_scope(self):
        # The owner keeps the quest records (Vehicle.q<digits>_*) out of the whole extension:
        # listed as excluded, never a body or a trim, so no sticker set lists them.
        scope = json.loads((REPO / "docs" / "generated" / "vehicle-player-scope-2.50.json").read_text(encoding="utf-8"))
        player = json.loads((REPO / "docs" / "generated" / "vehicle-components-player-bodies-2.50.json").read_text(encoding="utf-8"))
        quest = re.compile(r"^Vehicle\.q\d+_")
        for b in scope["bodies"]:
            for r in b["records"]:
                self.assertNotRegex(r["record"], quest)
        for m in player["models"]:
            self.assertNotRegex(m["record"], quest)
            for t in m.get("trims") or []:
                self.assertNotRegex(t["record"], quest)
        excluded = {e["record"]: e["reason"] for e in scope["excluded"]}
        for name in ("Vehicle.q000_hym_player_car", "Vehicle.q304_songbird_escape_player"):
            self.assertIn("quest variant", excluded.get(name, ""))


class NoVanillaBytesTests(unittest.TestCase):
    def test_no_game_file_in_the_sticker_sources(self):
        for path in HERE.rglob("*"):
            if "__pycache__" in path.parts or not path.is_file():
                continue
            self.assertFalse(path.name.lower().endswith(GAME_EXTENSIONS), path)
        for path in (HERE / "art").rglob("*") if (HERE / "art").exists() else []:
            if path.is_file():
                self.assertEqual(path.suffix.lower(), ".png", path)

    def test_the_motif_drawings_read_no_file(self):
        src = (HERE / "st_draw.py").read_text(encoding="utf-8")
        for needle in ("open(", "Image.open", "truetype", "ImageFont", "read_bytes", "read_text"):
            self.assertNotIn(needle, src)

    @unittest.skipIf(shutil.which("node") is None, "node not on PATH")
    def test_the_build_scan_catches_a_shared_block(self):
        scan = HERE.parent / "plates" / "native" / "plates.cjs"
        with tempfile.TemporaryDirectory() as t:
            t = Path(t)
            ours, vanilla = t / "ours", t / "vanilla.bin"
            ours.mkdir()
            block = hashlib.sha256(b"a").digest() + hashlib.sha256(b"b").digest()   # content: not ASCII (a name), not a counting run (an index table)
            vanilla.write_bytes(b"\x01\x02" * 32 + block + b"\x07" * 64)
            (ours / "clean.bin").write_bytes(bytes(range(200, 256)) * 4)
            plan = t / "plan.json"
            plan.write_text(json.dumps({"vanillaFiles": [str(vanilla)]}), encoding="utf-8")
            ok = subprocess.run(["node", str(scan), "scan", str(plan), str(ours)], capture_output=True, text=True)
            self.assertEqual(ok.returncode, 0, ok.stderr)
            self.assertIn("PLATES_SCAN_OK", ok.stdout)
            (ours / "leak.bin").write_bytes(b"ours" + block + b"tail")
            bad = subprocess.run(["node", str(scan), "scan", str(plan), str(ours)], capture_output=True, text=True)
            self.assertNotEqual(bad.returncode, 0)
            self.assertIn("binary 64-byte blocks", bad.stdout + bad.stderr)

    def test_the_names_table_hash(self):
        # Measured on 2.31 meshes (the container's names table): CMesh -> 0x6aecd0e1.
        self.assertEqual(so.name_hash(b"CMesh"), 0x6AECD0E1)
        self.assertEqual(so.name_hash(b"cookingPlatform"), 0x6B6B1331)
        self.assertEqual(so.name_hash(b""), 0)

    @staticmethod
    def cr2w(names, payload, corrupt=False, stamp=0):
        """A CR2W file: header (stamp: its timestamp, so two files' headers differ, as real ones
        do), strings and names tables (offset + name_hash), then a payload."""
        strings = b"\0" + b"".join(n + b"\0" for n in names)
        offsets = [0] + [1 + sum(len(m) + 1 for m in names[:i]) for i in range(len(names))]
        table = b"".join(struct.pack("<II", o, so.name_hash(strings[o:strings.index(b"\0", o)])) for o in offsets)
        if corrupt:
            table = table[:-4] + b"\0\0\0\1"
        head = struct.pack("<4sIIQIIIII", b"CR2W", 195, 0, 0x1D5A6B7C8E9F0102 + stamp, 0, 0, 0, 0, 1)
        tables = struct.pack("<III", 160, len(strings), 0) + struct.pack("<III", 160 + len(strings), len(offsets), 0)
        tables += b"\0" * (120 - len(tables))
        return head + tables + strings + table + payload

    @unittest.skipIf(shutil.which("node") is None, "node not on PATH")
    def test_a_shared_names_table_passes_and_shared_content_does_not(self):
        scan = HERE.parent / "plates" / "native" / "plates.cjs"
        names = [f"property{i:02d}".encode() for i in range(24)] + [b"CMesh", b"cookingPlatform"]
        content = hashlib.sha256(b"geometry").digest() * 4                    # 128 bytes, aligned twice at least
        with tempfile.TemporaryDirectory() as t:
            t = Path(t)
            ours, vanilla = t / "ours", t / "container.mesh"
            ours.mkdir()
            vanilla.write_bytes(self.cr2w(names, b"\x05" * 64 + content + b"\x09" * 64))
            plan = t / "plan.json"
            plan.write_text(json.dumps({"vanillaFiles": [str(vanilla)], "reportDir": str(t)}), encoding="utf-8")

            def run(our_bytes):
                (ours / "decal.mesh").write_bytes(our_bytes)
                r = subprocess.run(["node", str(scan), "scan", str(plan), str(ours)], capture_output=True, text=True)
                return r.returncode, r.stdout + r.stderr

            # Our mesh: the same names (so the same names table), our own geometry.
            code, out = run(self.cr2w(names, bytes(range(256)), stamp=1))
            self.assertNotEqual(code, 0)                                      # plates.cjs alone refuses it
            self.assertIn("binary 64-byte blocks", out)
            with contextlib.redirect_stdout(io.StringIO()) as printed:
                so.scan_names(str(plan))
            self.assertIn("ST_SCAN_NAMES_OK", printed.getvalue())
            self.assertIn("shared content blocks=0", printed.getvalue())
            # The same, plus the vanilla geometry: refused.
            code, out = run(self.cr2w(names, bytes(range(256)) + content, stamp=1))
            self.assertNotEqual(code, 0)
            with self.assertRaises(SystemExit) as e:
                so.scan_names(str(plan))
            self.assertIn("are content, not a names table", str(e.exception))
            # A names table whose hashes do not verify explains nothing.
            vanilla.write_bytes(self.cr2w(names, b"\x05" * 64 + content + b"\x09" * 64, corrupt=True))
            code, out = run(self.cr2w(names, bytes(range(256)), corrupt=True, stamp=1))
            self.assertNotEqual(code, 0)
            with self.assertRaises(SystemExit):
                so.scan_names(str(plan))

    LAYOUT_NAMES = [b"chunkVertices", b"rendVertexBufferChunk", b"vertexLayout", b"GpuWrapApiVertexLayoutDesc",
                    b"elements", b"static:32,GpuWrapApiVertexPackingPackingElement", b"type",
                    b"GpuWrapApiVertexPackingePackingType", b"usage", b"GpuWrapApiVertexPackingePackingUsage",
                    b"streamType", b"GpuWrapApiVertexPackingEStreamType", b"streamIndex", b"usageIndex", b"Uint8",
                    b"slotStrides", b"static:8,Uint8", b"slotMask", b"Uint32", b"hash", b"PT_Float3", b"PT_Dec4",
                    b"PT_Float16_2", b"PS_Position", b"PS_Normal", b"PS_TexCoord", b"ST_PerVertex",
                    b"vertices", b"array:Uint8", b"CMesh", b"cookingPlatform"]

    @classmethod
    def vertex_chunk(cls, extra=b""):
        """A serialized chunkVertices (rendVertexBufferChunk) that opens with its vertexLayout
        (GpuWrapApiVertexLayoutDesc), as in a mesh's render buffers: four packing elements, the
        slot strides, the slot mask and the hash. `extra`: more properties inside the layout."""
        ix = {n: i + 1 for i, n in enumerate(cls.LAYOUT_NAMES)}     # cr2w() puts the empty name first

        def prop(name, typ, value):
            return struct.pack("<HHI", ix[name], ix[typ], 4 + len(value)) + value

        def enum(name, typ, value):
            return prop(name, typ, struct.pack("<H", ix[value]))

        elements = b""
        for usage, packing, index in ((b"PS_Position", b"PT_Float3", 0), (b"PS_Normal", b"PT_Dec4", 0),
                                      (b"PS_TexCoord", b"PT_Float16_2", 0), (b"PS_TexCoord", b"PT_Float16_2", 1)):
            elements += (b"\0" + enum(b"type", b"GpuWrapApiVertexPackingePackingType", packing)
                         + enum(b"usage", b"GpuWrapApiVertexPackingePackingUsage", usage)
                         + enum(b"streamType", b"GpuWrapApiVertexPackingEStreamType", b"ST_PerVertex")
                         + prop(b"streamIndex", b"Uint8", b"\0") + prop(b"usageIndex", b"Uint8", bytes([index])) + b"\0\0")
        layout = (b"\0" + prop(b"elements", b"static:32,GpuWrapApiVertexPackingPackingElement", struct.pack("<I", 4) + elements)
                  + prop(b"slotStrides", b"static:8,Uint8", struct.pack("<I", 8) + bytes([12, 4, 8, 0, 0, 0, 0, 0]))
                  + prop(b"slotMask", b"Uint32", struct.pack("<I", 7)) + prop(b"hash", b"Uint32", struct.pack("<I", 0x5EED1234))
                  + extra + b"\0\0")
        return prop(b"chunkVertices", b"rendVertexBufferChunk",
                    b"\0" + prop(b"vertexLayout", b"GpuWrapApiVertexLayoutDesc", layout) + b"\0\0")

    @unittest.skipIf(shutil.which("node") is None, "node not on PATH")
    def test_a_shared_vertex_format_passes_and_shared_vertices_do_not(self):
        scan = HERE.parent / "plates" / "native" / "plates.cjs"
        names = self.LAYOUT_NAMES
        geometry = hashlib.sha256(b"positions").digest() * 4
        vertices = struct.pack("<HHI", names.index(b"vertices") + 1, names.index(b"array:Uint8") + 1, 4 + len(geometry)) + geometry
        with tempfile.TemporaryDirectory() as t:
            t = Path(t)
            ours, vanilla = t / "ours", t / "crystaldome.mesh"
            ours.mkdir()
            plan = t / "plan.json"
            plan.write_text(json.dumps({"vanillaFiles": [str(vanilla)], "reportDir": str(t)}), encoding="utf-8")

            def run(vanilla_chunk, our_chunk):
                vanilla.write_bytes(self.cr2w(names, b"\x05" * 64 + vanilla_chunk + b"\x09" * 64))
                (ours / "decal.mesh").write_bytes(self.cr2w(names, bytes(range(256)) + our_chunk + bytes(range(255, 0, -1)), stamp=1))
                r = subprocess.run(["node", str(scan), "scan", str(plan), str(ours)], capture_output=True, text=True)
                return r.returncode, r.stdout + r.stderr

            # The same vertex format in both meshes (the names table matches as well): explained.
            code, out = run(self.vertex_chunk(), self.vertex_chunk())
            self.assertNotEqual(code, 0)                                      # plates.cjs alone refuses it
            with contextlib.redirect_stdout(io.StringIO()) as printed:
                so.scan_names(str(plan))
            self.assertIn("shared content blocks=0", printed.getvalue())
            self.assertRegex(printed.getvalue(), r"vertex-format blocks=[1-9]")
            self.assertEqual(len(so.layout_regions(vanilla.read_bytes())), 1)
            # The layout carries a vertex stream as well: no longer a format descriptor, refused.
            code, out = run(self.vertex_chunk(vertices), self.vertex_chunk(vertices))
            self.assertNotEqual(code, 0)
            self.assertEqual(so.layout_regions(vanilla.read_bytes()), [])
            with self.assertRaises(SystemExit) as e:
                so.scan_names(str(plan))
            self.assertIn("nor a vertex format descriptor", str(e.exception))
            # An enum that names no packing value (here PS_Normal where PT_ is due) is not one either.
            ix = {n: i + 1 for i, n in enumerate(names)}
            record = struct.pack("<HHI", ix[b"type"], ix[b"GpuWrapApiVertexPackingePackingType"], 6)
            good = self.vertex_chunk()
            self.assertEqual(good.count(record + struct.pack("<H", ix[b"PT_Dec4"])), 1)
            bad = good.replace(record + struct.pack("<H", ix[b"PT_Dec4"]), record + struct.pack("<H", ix[b"PS_Normal"]))
            run(bad, bad)
            self.assertEqual(so.layout_regions(vanilla.read_bytes()), [])
            with self.assertRaises(SystemExit):
                so.scan_names(str(plan))

    @unittest.skipIf(shutil.which("node") is None, "node not on PATH")
    def test_the_livery_scan_accepts_known_blocks_only(self):
        # liveries/lv_scan.py check: a shared content block passes only when the baseline
        # names its game side (<file name>@<offset>); a new one fails, whatever our side is.
        lv_scan = _module("lv_scan", HERE.parent / "liveries" / "lv_scan.py")
        scan = HERE.parent / "plates" / "native" / "plates.cjs"
        names = [f"property{i:02d}".encode() for i in range(24)] + [b"CMesh", b"cookingPlatform"]
        known, fresh = hashlib.sha256(b"layer run").digest() * 2, hashlib.sha256(b"other run").digest() * 2
        with tempfile.TemporaryDirectory() as t:
            t = Path(t)
            ours, vanilla = t / "ours", t / "paint.mlsetup"
            ours.mkdir()
            pad = b"\x05" * (64 + -len(self.cr2w(names, b"")) % 64)               # the scan reads aligned blocks
            data = self.cr2w(names, pad + known + b"\x09" * 64 + fresh + b"\x0b" * 64)
            vanilla.write_bytes(data)
            key = f"paint.mlsetup@{data.index(known)}"
            self.assertEqual(data.index(known) % 64, 0)
            plan = t / "scan-plan.json"
            plan.write_text(json.dumps({"vanillaFiles": [str(vanilla)], "reportDir": str(t)}), encoding="utf-8")
            base = t / "baseline.json"

            def check(our_payload, blocks):
                (ours / "ours.mlsetup").write_bytes(self.cr2w(names, our_payload, stamp=1))
                r = subprocess.run(["node", str(scan), "scan", str(plan), str(ours)], capture_output=True, text=True)
                self.assertNotEqual(r.returncode, 0, r.stdout)              # plates.cjs alone refuses it
                base.write_text(json.dumps({"revision": "test", "window": 64, "blocks": blocks}), encoding="utf-8")
                with contextlib.redirect_stdout(io.StringIO()) as printed:
                    lv_scan.check(str(plan), str(base))
                return printed.getvalue()

            out = check(bytes(range(256)) + known, [key])
            self.assertIn("new shared blocks=0", out)
            self.assertIn("known blocks=1 of 1", out)
            with self.assertRaises(SystemExit) as e:
                check(bytes(range(256)) + known, [])
            self.assertIn("1 shared 64-byte blocks", str(e.exception))
            with self.assertRaises(SystemExit) as e:
                check(bytes(range(256)) + known + fresh, [key])
            self.assertIn(f"paint.mlsetup@{data.index(fresh)}", str(e.exception))


@unittest.skipIf(NUMERIC, NUMERIC or "")
class OriginalArtTests(unittest.TestCase):
    def test_every_motif_renders_its_cut_out_deterministically(self):
        art = _module("st_art", HERE / "st_art.py")
        spec = ospec()
        for theme in spec["themes"]:
            for m in theme["motifs"]:
                with self.subTest(motif=f"{theme['id']}/{m['id']}"):
                    size = art.texture_size(m, spec)
                    for n in size:
                        self.assertEqual(n & (n - 1), 0)
                        self.assertLessEqual(n, spec["maxTexture"])
                    a = art.motif_image(theme, m, spec, size, HERE / "art")
                    b = art.motif_image(theme, m, spec, size, HERE / "art")
                    self.assertEqual(a.size, size)
                    self.assertEqual(a.tobytes(), b.tobytes())
                    alpha = np.asarray(a)[..., 3]
                    self.assertTrue((alpha > 128).any() and (alpha < 8).any(), "opaque art and a cut-out")

    def test_no_motif_touches_its_texture_edge_where_it_is_not_cut(self):
        # A motif drawn into its texture's edge shows a hard straight cut on the car (and bleeds
        # into the opposite edge when the sampler wraps). Only the sides a crop cuts may be
        # opaque: crop 'v' top and bottom, crop 'u' the ends but the one cropKeep keeps.
        art = _module("st_art", HERE / "st_art.py")
        spec = ospec()
        for theme in spec["themes"]:
            for m in theme["motifs"]:
                with self.subTest(motif=f"{theme['id']}/{m['id']}"):
                    alpha = np.asarray(art.motif_image(theme, m, spec, art.texture_size(m, spec), HERE / "art"))[..., 3]
                    cut = {"v": {"top", "bottom"}, "u": {"front", "rear"}}.get(m.get("crop"), set())
                    cut -= {"start": {"front"}, "end": {"rear"}}.get(m.get("cropKeep"), set())
                    for side, px in (("top", alpha[0]), ("bottom", alpha[-1]), ("front", alpha[:, 0]), ("rear", alpha[:, -1])):
                        if side not in cut:
                            self.assertLessEqual(int(px.max()), 8, side)

    def test_a_tapered_stroke_keeps_its_full_width_between_its_tapers(self):
        # A two-point stroke with a width function was read at its two ends only: the pinstripe
        # sill line came out 1 mm wide instead of 7 mm, the wing and rear lines as long wedges.
        draw = _module("st_draw", HERE / "st_draw.py")
        poly = draw.ribbon([(-50.0, 0.0), (50.0, 0.0)], 1.2, wfun=draw.taper(0.1, 0.9, 1.2))
        mid = [y for x, y in poly if abs(x) <= 1.0]
        self.assertAlmostEqual(max(mid) - min(mid), 1.2, places=6)
        ends = [y for x, y in poly if abs(x) >= 49.99]
        self.assertLess(max(ends) - min(ends), 0.2)
        art = _module("st_art", HERE / "st_art.py")
        spec = ospec()
        theme = next(t for t in spec["themes"] if t["id"] == "filet")
        m = next(x for x in theme["motifs"] if x["id"] == "sill")
        w, h = art.texture_size(m, spec)
        alpha = np.asarray(art.motif_image(theme, m, spec, (w, h), HERE / "art"))[..., 3] / 255.0
        width = float(alpha[:, w // 2].sum()) * m["size"][1] / h          # cm of opaque line across its middle
        self.assertTrue(0.55 <= width <= 1.0, width)

    def test_theme_01_art_is_unchanged(self):
        # sha256 of the course motifs as rendered (pillow 13.0.0, numpy 2.5.4: the pinned run),
        # equal to the pilot's textures: adding themes must not touch theme 01's art.
        art = _module("st_art", HERE / "st_art.py")
        spec = ospec()
        theme = spec["themes"][0]
        got = {m["id"]: hashlib.sha256(art.motif_image(theme, m, spec, art.texture_size(m, spec), HERE / "art").tobytes()).hexdigest()
               for m in theme["motifs"]}
        self.assertEqual(got, COURSE_ART_SHA256)


def flat_side_model(sp_, half_width=0.9, length=2.0, height=1.0, names=("door_fl_a", "door_fr_a"), glass_behind=None):
    """A stand-in Model: two vertical panels (x = -w and x = +w), each its own component, identity
    frames; glass_behind (metres): a third component, glass, that far inside the left panel."""
    md = object.__new__(sp_.Model)
    y0, y1, z0, z1 = -length / 2, length / 2, 0.0, height
    tris = []
    xs = [-half_width, half_width] + ([-half_width + glass_behind] if glass_behind is not None else [])
    for x in xs:
        a, b, c, d = (x, y0, z0), (x, y1, z0), (x, y1, z1), (x, y0, z1)
        tris += [(a, b, c), (a, c, d)]
    s = sp_.lv_surface.Surface()
    s.tris = np.array(tris, float)
    s.comp = np.array([0, 0, 1, 1] + ([2, 2] if glass_behind is not None else []))
    s.kind = np.array([sp_.KIND_PAINT] * 4 + ([sp_.KIND_GLASS] * 2 if glass_behind is not None else []))
    names = list(names) + (["window_fl_a"] if glass_behind is not None else [])
    s.names = list(names)
    s.frames = {n: ((0.0, 0.0, 0.0, 1.0), (0.0, 0.0, 0.0)) for n in names}
    md.s, md.key, md.m = s, "flat", {"label": "flat"}
    md.fn = sp_.face_normals(s.tris)
    md.step = 0.01
    pts = s.tris.reshape(-1, 3)
    md.lo, md.hi = pts.min(0) - 0.05, pts.max(0) + 0.05
    md.wheels, md.grids, md.scaled = [], {}, {}
    md.hostable = np.array([True, True] + [False] * (len(names) - 2) + [False])
    md.bumper = np.array([bool(sp_.BUMPER_NAME.search(n)) for n in names] + [False])
    return md


def panel_model(sp_, panels, wheels=((1.5, 0.3), (-1.5, 0.3))):
    """A stand-in Model of vertical panels, each (name, x, y0, y1, z0, z1) its own paint component,
    identity frames; wheels: (y, tyre radius) front and back, on both sides, out of the panels' way."""
    md = object.__new__(sp_.Model)
    tris, comp, names = [], [], []
    for i, (name, x, y0, y1, z0, z1) in enumerate(panels):
        a, b, c, d = (x, y0, z0), (x, y1, z0), (x, y1, z1), (x, y0, z1)
        tris += [(a, b, c), (a, c, d)]
        comp += [i, i]
        names.append(name)
    s = sp_.lv_surface.Surface()
    s.tris, s.comp = np.array(tris, float), np.array(comp)
    s.kind = np.array([sp_.KIND_PAINT] * len(comp))
    s.names = names
    s.frames = {n: ((0.0, 0.0, 0.0, 1.0), (0.0, 0.0, 0.0)) for n in names}
    md.s, md.key, md.m = s, "panels", {"label": "panels"}
    md.fn = sp_.face_normals(s.tris)
    md.step = 0.01
    pts = s.tris.reshape(-1, 3)
    md.lo, md.hi = pts.min(0) - 0.05, pts.max(0) + 0.05
    md.wheels = [{"end": end, "centre": [side * 0.9, y, 0.3], "tyre": r}
                 for end, (y, r) in zip(("front", "back"), wheels) for side in (-1, 1)]
    md.grids, md.scaled = {}, {}
    md.hostable = np.array([True] * len(names) + [False])
    md.bumper = np.array([False] * (len(names) + 1))
    return md


def motif_stub(sp_, alpha, size_cm, mirror, **attrs):
    """A Motif without a spec or a PNG: its alpha, its size (cm), its mirror flag, any other attribute."""
    mo = object.__new__(sp_.Motif)
    rgba = np.zeros(alpha.shape + (4,), np.float32)
    rgba[..., 3] = alpha
    mid = attrs.pop("id", "arrow")
    mo.theme, mo.m = {"id": "t"}, {"id": mid, "zones": attrs.pop("zones", ["door_l", "door_r"])}
    mo.id, mo.stem = mid, f"t_{mid}"
    mo.size = (size_cm[0] / 100, size_cm[1] / 100)
    mo.mirror, mo.crop, mo.crop_keep = mirror, None, "middle"
    mo.min_length, mo.max_length, mo.min_scale = 0.0, mo.size[1], 0.5
    mo.optional, mo.align_to, mo.anchor_z, mo.anchor_offset, mo.anchor_weight, mo.align_tol = False, None, None, 0.0, 0.0, None
    mo.fallback, mo.of = None, None
    for k, v in attrs.items():
        setattr(mo, k, v)
    mo.alpha, mo.rgba = alpha, rgba
    return mo


def arrow_motif(sp_, mirror, size_cm=(30, 20), **attrs):
    """An asymmetric motif: opaque on its first (front-pointing) half of u only."""
    h, w = 64, 96
    alpha = np.zeros((h, w), np.float32)
    alpha[8:-8, 4:w // 2] = 1.0
    return motif_stub(sp_, alpha, size_cm, mirror, **attrs)


def band_motif(sp_, keep="middle", size_cm=(80, 10), min_length=0.2, max_length=2.0, **attrs):
    """A crop 'u' band (a pinstripe): two lines along u, opaque from end to end."""
    h, w = 40, 320
    alpha = np.zeros((h, w), np.float32)
    alpha[14:19, :] = 1.0
    alpha[23:25, :] = 1.0
    attrs.setdefault("zones", ["door_l", "door_r"])
    return motif_stub(sp_, alpha, size_cm, True, id=attrs.pop("id", "band"), crop="u", crop_keep=keep,
                      min_length=min_length, max_length=max_length, min_scale=1.0, **attrs)


@unittest.skipIf(NUMERIC, NUMERIC or "")
class OriginalPlacementTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.sp = _module("st_place", HERE / "st_place.py")

    def zones(self, md):
        sp_ = self.sp
        out = []
        for view, name, ci in (("left", "door_l", 0), ("right", "door_r", 1)):
            g = md.grid(view)
            mask = g.paint & (g.comp == ci)
            out.append(sp_.Zone(name, view, [(ci, mask, (0.0, 0.5))]))
        return out

    def place_pair(self, mirror):
        sp_ = self.sp
        md = flat_side_model(sp_)
        mo = arrow_motif(sp_, mirror)
        zs = self.zones(md)
        pls = sp_.fit_side_at(md, mo, zs, tuple(z.cands[0] for z in zs), 1.0)
        self.assertIsNotNone(pls)
        meshes = [sp_.build_mesh(md, pl, 0.02, 0.004) for pl in pls]
        return md, pls, meshes

    def front_u(self, mesh):
        pos, uv = np.array(mesh["pos"]), np.array(mesh["uv"])
        front = pos[:, 1] >= pos[:, 1].max() - 1e-6
        return float(uv[front, 0].mean())

    def test_a_pair_is_symmetric_and_a_mirrored_motif_points_the_same_way(self):
        md, (left, right), (ml, mr) = self.place_pair(mirror=True)
        self.assertEqual(left.centre, right.centre)
        self.assertFalse(left.mirrored)
        self.assertTrue(right.mirrored)
        self.assertAlmostEqual(self.front_u(ml), 0.0, places=6)      # u starts at the car's front on both sides
        self.assertAlmostEqual(self.front_u(mr), 0.0, places=6)

    def test_an_unmirrored_motif_stays_readable_on_the_right(self):
        md, (left, right), (ml, mr) = self.place_pair(mirror=False)
        self.assertFalse(right.mirrored)
        self.assertAlmostEqual(self.front_u(ml), 0.0, places=6)      # readable: u runs front-to-rear on the left
        self.assertAlmostEqual(self.front_u(mr), 1.0, places=6)      # and rear-to-front on the right
        fp_l = arrow_motif(self.sp, False).footprint("left", False, 1.0, 0.01)
        fp_r = arrow_motif(self.sp, False).footprint("right", False, 1.0, 0.01)
        self.assertTrue((fp_l == fp_r[::-1, :]).all())
        fp_m = arrow_motif(self.sp, True).footprint("right", True, 1.0, 0.01)
        self.assertTrue((fp_l == fp_m).all())

    def test_the_decal_sits_4_mm_out_in_the_host_frame_and_passes_the_assertions(self):
        md, pls, meshes = self.place_pair(mirror=True)
        for pl, mesh, side in zip(pls, meshes, (-1, 1)):
            pos, nor = np.array(mesh["pos"]), np.array(mesh["nor"])
            self.assertTrue(np.allclose(pos[:, 0], side * (0.9 + 0.004)))
            self.assertTrue(np.allclose(nor, [side, 0, 0]))
            for tri in np.array(mesh["world"]):                       # winding faces the camera (outward)
                n = np.cross(tri[1] - tri[0], tri[2] - tri[0])
                self.assertGreater(n[0] * side, 0)
            m = self.sp.check_decal(md, pl, mesh)
            self.assertGreaterEqual(m["carried"], 0.97)
            self.assertEqual(m["visible"], 1.0)
            self.assertEqual(m["onHost"], 1.0)
            self.assertEqual(m["floating"], 0.0)

    def test_a_taken_rectangle_is_not_reused(self):
        sp_ = self.sp
        md = flat_side_model(sp_, length=0.5, height=0.3)
        mo = arrow_motif(sp_, True)
        zs = self.zones(md)
        first = sp_.fit_side_at(md, mo, zs, tuple(z.cands[0] for z in zs), 1.0)
        self.assertIsNotNone(first)
        sp_.take(md, first)
        self.assertIsNone(sp_.fit_side_at(md, mo, zs, tuple(z.cands[0] for z in zs), 1.0))

    def test_spec_rules_and_the_cap(self):
        sp_ = self.sp
        sp_.check_spec(ospec())
        g, f = 1, 4                                                   # graffiti, filet
        for mutate, needle in (
                (lambda s: s["themes"][0]["motifs"][0]["zones"].append("bonnet"), "unknown zone"),
                (lambda s: s["themes"][0]["motifs"][1]["zones"].append("hood"), "named by two motifs"),
                (lambda s: s["themes"][0]["motifs"][3].update(crop="v"), "crop is for the centre zones"),
                (lambda s: s.update(maxDecalsPerCar=5, maxDecalsPerSet=5), "over maxDecalsPerCar"),
                (lambda s: s.update(maxDecalsPerSet=13), "maxDecalsPerSet 13 must be"),
                (lambda s: s["themes"][f]["motifs"][4].pop("optional"), "over maxDecalsPerSet"),
                (lambda s: s["themes"][0]["motifs"][0].update(minScale=0), "minScale"),
                (lambda s: s["themes"][g]["motifs"][3].update(crop="u"), 'crop "u" is for the side zones'),
                (lambda s: s["themes"][g]["motifs"][0].update(cropKeep="start"), "cropKeep is"),
                (lambda s: s["themes"][f]["motifs"][1].update(cropKeep="front"), "cropKeep is"),
                (lambda s: s["themes"][g]["motifs"][0].update(anchorZ="belt"), "need crop"),
                (lambda s: s["themes"][f]["motifs"][0].update(anchorZ="roof"), 'anchorZ must be "belt"'),
                (lambda s: s["themes"][f]["motifs"][1].update(alignTo="hood"), "not an earlier motif"),
                (lambda s: s["themes"][f]["motifs"][0].update(alignTolerance=50), "alignTolerance must be"),
                (lambda s: s["themes"][g]["motifs"][0].update(fallback={"motif": "nope", "minScale": 0.2}), "fallback names"),
                (lambda s: s["themes"][g]["motifs"][0].update(fallback={"motif": "tag", "minScale": 0.2}), "fallback names"),
                (lambda s: s["themes"][g]["motifs"][1].update(fallback={"motif": "burst", "minScale": 0.2}), "fallback names"),
                (lambda s: s["themes"][g]["motifs"][0].update(fallback={"motif": "burst", "minScale": 0}), "fallback minScale")):
            bad = ospec()
            mutate(bad)
            with self.subTest(needle=needle), self.assertRaises(SystemExit) as e:
                sp_.check_spec(bad)
            self.assertIn(needle, str(e.exception))
        self.assertLessEqual(sp_.set_budget(ospec()), ospec()["maxDecalsPerCar"])
        with tempfile.TemporaryDirectory() as t:
            bad = ospec()
            bad["maxDecalsPerCar"] = 13
            p = Path(t) / "spec.json"
            p.write_text(json.dumps(bad), encoding="utf-8")
            shutil.copy(HERE.parent / "specs" / "lightrp-bodykit-fit.json", Path(t) / "fit.json")
            bad["kitFits"] = ["fit.json"]
            p.write_text(json.dumps(bad), encoding="utf-8")
            with self.assertRaises(SystemExit) as e:
                sp_.cmd_place({"spec": str(p), "out": str(Path(t) / "out"), "step": 0.01, "spacing": 0.02,
                               "offset": 0.004, "limits": {}})
            self.assertIn("above the engine cap", str(e.exception))

    def test_mirror_names(self):
        for left, right in (("door_fl_a", "door_fr_a"), ("door_bl_a", "door_br_a"), ("body_01", "body_01"),
                            ("wing_left_01", "wing_right_01"), ("sill_l", "sill_r")):
            self.assertEqual(self.sp.mirror_name(left), right)

    def test_paint_over_glass_is_no_ground(self):
        # The Caliburn's door panels cover its crystal-dome glass a few cm behind them: no sticker there.
        sp_ = self.sp
        shell = flat_side_model(sp_, glass_behind=0.04).grid("left")
        self.assertFalse((shell.paint & (shell.comp == 0)).any())
        self.assertTrue(shell.over_glass[shell.comp == 0].all())
        clear = flat_side_model(sp_, glass_behind=0.30).grid("left")       # glass well inside: a real panel
        self.assertTrue((clear.paint & (clear.comp == 0)).any())
        self.assertTrue((flat_side_model(sp_).grid("right").paint).any())

    def test_a_bumper_hosts_the_rear_zone_only(self):
        sp_ = self.sp
        md = flat_side_model(sp_, names=("bumper_f_a_02", "door_fr_a"))
        g = md.grid("left")
        self.assertEqual(md.hosts_in(g, g.valid), [])
        self.assertEqual(md.hosts_in(g, g.valid, bumpers=True), [0])
        g = md.grid("right")
        self.assertEqual(md.hosts_in(g, g.valid), [1])

    def crop_pair(self, mo, md=None, **kw):
        md = md or flat_side_model(self.sp)                           # two 2 m x 1 m panels
        zs = self.zones(md)
        return md, self.sp.fit_side_crop_at(md, mo, zs, tuple(z.cands[0] for z in zs), 1.0, **kw)

    def test_a_crop_u_band_keeps_its_height_runs_along_the_car_and_keeps_its_named_end(self):
        sp_ = self.sp
        for keep, uv in (("start", ((0.0, 0.0), (0.5, 1.0))), ("end", ((0.5, 0.0), (1.0, 1.0))),
                         ("middle", ((0.25, 0.0), (0.75, 1.0)))):
            with self.subTest(keep=keep):
                md, pls = self.crop_pair(band_motif(sp_, keep, max_length=0.4))
                self.assertIsNotNone(pls)
                left, right = pls
                self.assertEqual(left.centre, right.centre)           # a symmetric pair
                self.assertFalse(left.mirrored)
                self.assertTrue(right.mirrored)
                self.assertAlmostEqual(left.ext[0], 0.4)              # capped at maxLength, along the car
                self.assertAlmostEqual(left.ext[1], 0.10)             # its own height: never squashed
                for pl in pls:
                    self.assertEqual([[round(c, 6) for c in q] for q in pl.uv], [list(q) for q in uv])
                y0, y1 = left.centre[0] - 0.2, left.centre[0] + 0.2
                if keep == "start":                                   # the kept front end out, the cut end at the run's rear end
                    self.assertLess(y0, -0.95)
                elif keep == "end":
                    self.assertGreater(y1, 0.95)
                else:                                                 # middle: nearest the anchor (the panel's centre)
                    self.assertAlmostEqual(left.centre[0], 0.0, delta=0.02)
                meshes = [sp_.build_mesh(md, pl, 0.02, 0.004) for pl in pls]
                for mesh in meshes:                                   # u = 0 at the car's front on both sides
                    pos, uvs = np.array(mesh["pos"]), np.array(mesh["uv"])
                    front, rear = pos[:, 1] >= pos[:, 1].max() - 1e-6, pos[:, 1] <= pos[:, 1].min() + 1e-6
                    self.assertAlmostEqual(float(uvs[front, 0].mean()), uv[0][0], places=5)
                    self.assertAlmostEqual(float(uvs[rear, 0].mean()), uv[1][0], places=5)
                for pl, mesh in zip(pls, meshes):
                    m = sp_.check_decal(md, pl, mesh)
                    self.assertGreaterEqual(m["carried"], 0.97)
                    self.assertEqual((m["visible"], m["onHost"], m["floating"]), (1.0, 1.0, 0.0))

    def test_a_crop_u_band_longer_than_its_art_is_stretched_and_shorter_than_min_length_is_refused(self):
        sp_ = self.sp
        _md, (left, _right) = self.crop_pair(band_motif(sp_, max_length=1.5))
        self.assertAlmostEqual(left.ext[0], 1.5)                      # 80 cm of art over 1.5 m
        self.assertEqual(left.uv, ((0.0, 0.0), (1.0, 1.0)))
        self.assertIsNone(self.crop_pair(band_motif(sp_, min_length=2.5))[1])

    def test_a_thin_line_counts_as_opaque_whatever_its_phase(self):
        # A 4 mm pinstripe is thinner than the 1 cm fit cell: measured per cell (cell_alpha), it is
        # carried and visible wherever it runs; point-sampled, it could vanish between two rows.
        sp_ = self.sp
        h, w = 40, 400
        for row in range(14, 20):
            alpha = np.zeros((h, w), np.float32)
            alpha[row:row + 2, :] = 1.0                               # 0.5 cm of a 10 cm band
            mo = motif_stub(sp_, alpha, (100, 10), True, id="hair", crop="u", min_length=0.2, max_length=0.8, min_scale=1.0)
            md, pls = self.crop_pair(mo)
            for pl in pls:
                m = sp_.check_decal(md, pl, sp_.build_mesh(md, pl, 0.02, 0.004))
                self.assertGreater(m["opaqueCells"], 60, row)
                self.assertGreaterEqual(m["carried"], 0.97, row)
                self.assertEqual(m["visible"], 1.0, row)

    def test_a_band_under_two_cells_tall_keeps_one_row_of_evidence_whatever_its_phase(self):
        # The pinstripe sill line at x0.65 is 1.95 cm tall: shrunk by a quarter on each side and
        # centred on a cell edge, it held no cell centre, so nothing was measured (carried 0).
        sp_ = self.sp
        step = 0.01
        for height in (0.0105, 0.0195, 0.024, 0.04, 0.10):
            for phase in np.linspace(0.0, step, 21):
                pl = types.SimpleNamespace(zone=types.SimpleNamespace(view="left"), mirrored=False, ext=(1.0, height),
                                           centre=(0.0, phase), uv=((0.0, 0.0), (1.0, 1.0)))
                aa, bb = np.meshgrid((np.arange(-60, 60) + 0.5) * step, (np.arange(-12, 12) + 0.5) * step, indexing="ij")
                _u, _v, inside = sp_.expected_uv(pl, aa, bb, step)
                rows = np.nonzero(inside.any(0))[0]
                self.assertGreater(len(rows), 0, (height, phase))
                if height >= 0.04:                                    # a band of 4 cells or more: shrunk by the whole cell
                    self.assertTrue(all(abs(bb[0, r] - phase) <= height / 2 - step + 1e-9 for r in rows))

    def test_a_continued_line_keeps_its_height_or_is_left_out(self):
        sp_ = self.sp
        mo = band_motif(sp_, anchor_weight=5.0)
        _md, pls = self.crop_pair(mo, anchor_z=0.6, tol=0.01)
        self.assertTrue(all(abs(p.centre[1] - 0.6) <= 0.01 + 1e-9 for p in pls))
        self.assertIsNone(self.crop_pair(mo, anchor_z=1.5, tol=0.01)[1])     # no row of the panel near 1.5 m
        _md, pls = self.crop_pair(mo, anchor_z=1.5)                           # not continuing a line: as near as it gets
        self.assertGreater(pls[0].centre[1], 0.85)

    def four_door(self):
        return panel_model(self.sp, [("door_fl_a", -0.9, 0.0, 1.0, 0.0, 1.0), ("door_bl_a", -0.9, -1.0, 0.0, 0.0, 1.0),
                                     ("door_fr_a", 0.9, 0.0, 1.0, 0.0, 1.0), ("door_br_a", 0.9, -1.0, 0.0, 0.0, 1.0)])

    def test_a_four_door_has_a_rear_door_zone_and_a_two_door_none(self):
        sp_ = self.sp
        md = self.four_door()
        zones = sp_.find_zones(md, {"door_l", "door_r", "door2_l", "door2_r"})

        def hosts(name):
            return [md.s.names[c[0]] for c in zones[name].cands]
        self.assertEqual(hosts("door_l")[0], "door_fl_a")              # the front door first
        self.assertEqual(hosts("door_r")[0], "door_fr_a")
        self.assertEqual(hosts("door2_l"), ["door_bl_a"])
        self.assertEqual(hosts("door2_r"), ["door_br_a"])
        self.assertAlmostEqual(zones["door2_l"].belt, 1.0, delta=0.03)  # the top of the front door's paint
        md2 = panel_model(sp_, [("door_fl_a", -0.9, -1.0, 1.0, 0.0, 1.0), ("door_fr_a", 0.9, -1.0, 1.0, 0.0, 1.0)])
        z2 = sp_.find_zones(md2, {"door2_l", "door2_r"})
        self.assertEqual((z2["door2_l"].cands, z2["door2_r"].cands), ([], []))
        self.assertIn("no second door", z2["door2_l"].reason)

    def test_a_belt_line_runs_on_both_doors_at_one_height(self):
        sp_ = self.sp
        md = self.four_door()
        mo = band_motif(sp_, zones=["door_l", "door_r", "door2_l", "door2_r"], min_length=0.3, anchor_z="belt",
                        anchor_offset=-0.2, anchor_weight=5.0, align_tol=0.01)
        zones = sp_.find_zones(md, set(mo.m["zones"]))
        skipped = []
        pls = sp_.fit_motif(md, mo, zones, skipped)
        self.assertEqual(skipped, [])
        self.assertEqual(sorted(p.zone.name for p in pls), ["door2_l", "door2_r", "door_l", "door_r"])
        heights = {round(p.centre[1], 6) for p in pls}
        self.assertEqual(len(heights), 1)                             # one line along the flank
        self.assertAlmostEqual(heights.pop(), 0.8, delta=0.02)        # the belt (1.0) + anchorOffset
        self.assertEqual({p.zone.name: md.s.names[p.host] for p in pls},
                         {"door_l": "door_fl_a", "door_r": "door_fr_a", "door2_l": "door_bl_a", "door2_r": "door_br_a"})

    def test_a_motif_without_room_takes_its_fallback_emblem(self):
        sp_ = self.sp
        md = flat_side_model(sp_, length=0.3, height=0.3)            # a bike's side panel, roughly
        zones = {z.name: z for z in self.zones(md)}
        big = arrow_motif(sp_, True, size_cm=(100, 40), min_scale=0.9)
        emblem = arrow_motif(sp_, True, size_cm=(20, 20), id="emblem", min_scale=0.5)
        emblem.of, big.fallback = big, emblem
        skipped = []
        pls = sp_.fit_motif(md, big, zones, skipped)
        self.assertEqual(skipped, [])
        self.assertEqual([(p.zone.name, p.motif.stem, p.mirrored) for p in pls],
                         [("door_l", "t_emblem", False), ("door_r", "t_emblem", True)])
        for g in md.grids.values():
            g.taken[:] = False
        big.fallback = None
        self.assertEqual(sp_.fit_motif(md, big, zones, skipped), [])
        self.assertEqual(sorted(s["zone"] for s in skipped), ["door_l", "door_r"])

    def test_with_fallbacks_reuses_the_named_art_mirrored_as_the_motif(self):
        from PIL import Image
        sp_ = self.sp
        spec = ospec()
        theme = next(t for t in spec["themes"] if t["id"] == "graffiti")
        with tempfile.TemporaryDirectory() as art_dir:
            for m in theme["motifs"]:
                Image.new("RGBA", (8, 8), (255, 0, 0, 255)).save(Path(art_dir) / f"{theme['id']}_{m['id']}_d.png")
            motifs = sp_.with_fallbacks(theme, [sp_.Motif(theme, m, art_dir) for m in theme["motifs"]], art_dir)
        tag = next(mo for mo in motifs if mo.id == "tag")
        fb = tag.fallback
        burst = next(m for m in theme["motifs"] if m["id"] == "burst")
        self.assertEqual((fb.stem, fb.of, fb.mirror, fb.min_scale), ("graffiti_burst", tag, True, 0.15))
        self.assertEqual(fb.size, (burst["size"][0] / 100, burst["size"][1] / 100))
        self.assertEqual(fb.m["zones"], tag.m["zones"])
        for t in spec["themes"]:                                      # every fallback names an emblem of its theme
            for m in t["motifs"]:
                if "fallback" in m:
                    self.assertIn(m["fallback"]["motif"], [o["id"] for o in t["motifs"] if o is not m])

    def test_optional_motifs_leave_over_the_set_budget_last_first_and_whole(self):
        from types import SimpleNamespace as NS
        sp_ = self.sp
        mos = [NS(id=i, optional=o, of=None) for i, o in (("a", False), ("b", False), ("c", True), ("d", True))]
        counts = {"a": 4, "b": 3, "c": 1, "d": 2}

        def placed(ids):
            return [NS(motif=mo, zone=NS(name=f"{mo.id}{k}")) for mo in mos if mo.id in ids for k in range(counts[mo.id])]

        def kept(pls):
            return [p.motif.id for p in pls]
        skipped = []
        self.assertEqual(kept(sp_.drop_optional(placed("abcd"), mos, 9, skipped)), list("aaaabbbc"))      # 10: d goes
        self.assertEqual(sorted(s["zone"] for s in skipped), ["d0", "d1"])
        self.assertEqual(kept(sp_.drop_optional(placed("abcd"), mos, 7, [])), list("aaaabbb"))           # then c
        self.assertEqual(len(sp_.drop_optional(placed("abcd"), mos, 6, [])), 7)                          # no more to drop
        self.assertEqual(kept(sp_.drop_optional(placed("abc"), mos, 9, [])), list("aaaabbbc"))           # under: kept
        emblem = NS(id="e", optional=False, of=mos[3])                                                   # d's fallback
        pls = placed("abc") + [NS(motif=emblem, zone=NS(name="d0")), NS(motif=emblem, zone=NS(name="d1"))]
        self.assertEqual(kept(sp_.drop_optional(pls, mos, 9, [])), list("aaaabbbc"))                     # goes with d


if __name__ == "__main__":
    unittest.main()
