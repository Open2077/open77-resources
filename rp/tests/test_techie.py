"""Techie / weaponsmith (rp_techie): parts -> strip -> tray -> assemble -> sell, offline.

Run with `python -m unittest discover -s tests -p "test_techie*.py"` (Lua 5.4: lupa, or a lua54.dll
such as the KeraLua NuGet cache's; see tests/compat/luahost.py).

Each scenario boots, on tests/compat/multihost.lua: the FINAL open77_transactions resource (its
server/main.lua, exports, policy and work queue; the memory store plays the database), the real
open77_actions (OP77_SYS_DIR), the real rp_economy and rp_techie, shims for the public exports of
rp_jobs (with grades), rp_inventory (definitions with their definer, grantPockets), open77_uikit (the
context menu) and rp_salvage's item definitions, and the platform fakes of streetfood_world.lua
(player interactions with consent, animations, notifications). Scenario code:
tests/compat/techie_scenarios.lua; world: tests/compat/techie_world.lua.

Sources outside this pack are READ in place, never copied or edited:
  OP77_SYS_DIR   the Open77 resources/system folder with open77_actions (and open77_pedestrians for
                 the anchor check; default: this repository's system/ folder, else
                 ../wt-world-interaction/resources/system)
  OP77_TX_FINAL  the final open77_transactions folder (default: SYS_DIR's copy)
A missing source skips the suite with the reason.

What this cannot show: anything in game (poses at the benches, the hand-over presentation,
prompts, timing on a live tick, real platform event payloads), SQL semantics on MariaDB, the real
rp_jobs / rp_inventory / open77_uikit behind their exports, crowd contention for the bench spots.
"""
import os
import re
import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent / "compat"))
import luahost  # noqa: E402

ROOT = Path(__file__).resolve().parents[1]
COMPAT = ROOT / "tests" / "compat"
RESOURCE = ROOT / "rp_techie"


def sys_dir():
    explicit = os.environ.get("OP77_SYS_DIR")
    if explicit and Path(explicit).is_dir():
        return Path(explicit)
    bundled = ROOT.parent / "system"          # this repository's own system/ folder
    if (bundled / "open77_actions").is_dir():
        return bundled
    return ROOT.parent / "wt-world-interaction" / "resources" / "system"


def tx_dir():
    explicit = os.environ.get("OP77_TX_FINAL")
    if explicit and (Path(explicit) / "server" / "main.lua").is_file():
        return Path(explicit)
    return sys_dir() / "open77_transactions"


def missing_sources():
    why = luahost.unavailable()
    if why:
        return why
    if not (sys_dir() / "open77_actions" / "open77.lua").is_file():
        return f"open77_actions not found under {sys_dir()} (set OP77_SYS_DIR)"
    if not (tx_dir() / "server" / "main.lua").is_file():
        return f"final open77_transactions not found at {tx_dir()} (set OP77_TX_FINAL)"
    return None


def scenario(name):
    return luahost.run_scenario("techie_scenarios.lua", name, {
        "ROOT_DIR": ROOT.as_posix(), "COMPAT_DIR": COMPAT.as_posix(),
        "SYS_DIR": sys_dir().as_posix(), "TX_DIR": tx_dir().as_posix(),
    })


def config_text():
    return (RESOURCE / "server" / "config.lua").read_text(encoding="utf-8")


def spot_rows(path, rows):
    """{row: (x, y, z, yaw, profile)} from open77_pedestrians' spots-generated.lua (column tables)."""
    text = path.read_text(encoding="utf-8")
    profiles = re.findall(r'"([^"]+)"', re.search(r"\n    profiles = \{([^}]*)\}", text).group(1))

    def column(name):
        body = re.search(r"\n    " + name + r" = \{([^}]*)\}", text).group(1)
        return [float(v) for v in re.findall(r"-?\d+(?:\.\d+)?(?:e-?\d+)?", body)]

    x, y, z, yaw, prof = (column(n) for n in ("spotX", "spotY", "spotZ", "spotYaw", "spotProfile"))
    return {r: (x[r - 1], y[r - 1], z[r - 1], yaw[r - 1], profiles[int(prof[r - 1]) - 1]) for r in rows}


class TechieSources(unittest.TestCase):
    def test_sources_compile_without_bom(self):
        """Every rp_techie Lua file: UTF-8 without BOM (a BOM kills a resource silently) and loads
        as Lua 5.4 text; the test world too."""
        if luahost.unavailable():
            self.skipTest(luahost.unavailable())
        lua = luahost.new_state()
        try:
            paths = sorted(RESOURCE.rglob("*.lua")) + [COMPAT / "techie_world.lua", COMPAT / "techie_scenarios.lua"]
            for path in paths:
                data = path.read_bytes()
                self.assertFalse(data.startswith(b"\xef\xbb\xbf"), f"{path} has a BOM")
                data.decode("utf-8")
                if path.name == "open77.lua":
                    continue    # the manifest DSL (`auto_start false`) is parsed by the host, not Lua
                source = data.decode("utf-8")
                lua.execute(f"assert(load({luahost.lua_string(source)}, "
                            f"{luahost.lua_string('@' + path.name)}, 't'))", "=compile")
        finally:
            lua.close()

    def test_manifest_is_opt_in_and_least_privilege(self):
        text = (RESOURCE / "open77.lua").read_text(encoding="utf-8")
        code = "\n".join(line for line in text.splitlines() if not line.lstrip().startswith("--"))
        self.assertIn("auto_start false", code)
        block = re.search(r"permissions\s*\{([^}]*)\}", code).group(1)
        self.assertEqual(sorted(re.findall(r'"([^"]+)"', block)), sorted([
            "players.interactions.control", "players.interactions.read", "network.events"]))
        self.assertNotIn("client_script", code)
        for dep in ("open77_transactions", "open77_actions", "open77_player_interactions", "rp_jobs",
                    "rp_inventory", "rp_economy"):
            self.assertRegex(code, r'dependency "' + dep)

    def test_ascii_only_and_no_em_dash(self):
        """Prompt cards and chat show a non-ASCII glyph as '?': every string players can read is ASCII."""
        for path in sorted(RESOURCE.rglob("*")):
            if path.is_file():
                data = path.read_bytes()
                self.assertTrue(all(b < 128 for b in data), f"{path} has a non-ASCII byte")

    def test_readme_tunables_parse_and_match_the_config(self):
        """The README's writers and mint lines parse with the coordinator's own policy parser (no
        ignored entry), each fits a tunable (256 characters), and they are exactly the slots
        techie.mintrules prints from the config."""
        if luahost.unavailable():
            self.skipTest(luahost.unavailable())
        policy = tx_dir() / "server" / "policy.lua"
        if not policy.is_file():
            self.skipTest(f"no coordinator policy at {policy}")
        readme = (RESOURCE / "README.md").read_text(encoding="utf-8")
        mint = re.findall(r"tunable\.set open77_transactions mint[345] (.+)", readme)
        writers = re.findall(r"tunable\.set open77_transactions writers (.+)", readme)
        self.assertEqual((len(mint), len(writers)), (3, 1))
        for value in mint:
            self.assertLessEqual(len(value), 256, value)
        lua = luahost.new_state()
        try:
            for path in (policy, RESOURCE / "server" / "config.lua", RESOURCE / "server" / "model.lua"):
                lua.execute(path.read_text(encoding="utf-8"), "@" + path.name)
            lua.execute(f"""
                local rules, problems = Open77TxPolicy.parseRules({{ {', '.join(luahost.lua_string(m) for m in mint)} }})
                local _, wproblems = Open77TxPolicy.parseWriters({luahost.lua_string(writers[0])})
                local got = {{}}
                for _, r in ipairs(rules) do got[#got + 1] = r.resource .. " " .. r.account .. " " .. r.asset .. " " .. r.cap end
                RESULT = #problems .. "|" .. #wproblems .. "|" .. table.concat(got, "; ") .. "|" ..
                    table.concat(TechieModel.mintRules(TechieConfig, "rp_techie"), "; ") .. "|" ..
                    table.concat(TechieModel.mintSlots(TechieModel.mintRules(TechieConfig, "rp_techie")), " // ")
            """, "=policy")
            problems, wproblems, got, want, slots = lua.global_string("RESULT").split("|")
        finally:
            lua.close()
        self.assertEqual((problems, wproblems), ("0", "0"))
        self.assertEqual(got, want)
        self.assertEqual(" // ".join(mint), slots)

    def test_bench_and_counter_anchors_come_from_the_catalogue(self):
        """The benches and the dealer stand on vanilla AI spots of the pedestrian catalogue (walked
        in game); the shop counters stand beside rp_shops' vendors. Every point says `measured`."""
        spots = sys_dir() / "open77_pedestrians" / "server" / "spots-generated.lua"
        if not spots.is_file():
            self.skipTest(f"no spots catalogue at {spots}")
        expected = {32163: "amb_2ced53_stand_ground",
                    39487: "amb_cc2fe0_kneel_ground_tool", 31019: "amb_77e5ea_stand_ground_tablet"}
        rows = spot_rows(spots, list(expected))
        config = config_text()
        points = re.findall(r"position = \{ x = (-?[\d.]+), y = (-?[\d.]+), z = (-?[\d.]+) \}, yaw = (-?[\d.]+),"
                            r"[^}]*?source = \"[^\"]*row (\d+)", config, re.S)
        found = {int(row): tuple(float(v) for v in xyzw) for *xyzw, row in points}
        for row, profile in expected.items():
            self.assertEqual(rows[row][4], profile, row)
            self.assertIn(row, found, f"row {row} not used in config.lua")
            for got, want in zip(found[row], rows[row][:4]):
                self.assertAlmostEqual(got, want, places=2)
        self.assertGreaterEqual(config.count("measured = true") + config.count("measured = false"), 7)


@unittest.skipIf(missing_sources(), missing_sources())
class TechieLoop(unittest.TestCase):
    def run_ok(self, name):
        r = scenario(name)
        self.assertEqual(r.get("errors"), "0", r.get("first_error"))
        return r

    def test_happy_path_parts_strip_assemble_sell(self):
        r = self.run_ok("happy_path")
        # a scrapper sells 3 scrap metal to the techie: consent, then ONE operation (goods + price)
        self.assertEqual((r["told_offer"], r["trade_done"]), ("true", "true"))
        self.assertEqual((r["trade_t"], r["trade_s"], r["trade_paid"], r["trade_got"]), ("3", "3", "66", "66"))
        # the dealer: a copper lot minted into the pockets, the price burned
        self.assertEqual((r["buy"], r["buy_copper"], r["buy_paid"]), ("committed", "2", "90"))
        # stage 1: nothing on the tray during the bar; a second techie is refused the claimed bench
        self.assertEqual((r["tray_during"], r["s1"], r["claimed"], r["s2"]), ("0", "committed", "target_claimed", "committed"))
        self.assertEqual((r["strip_plates"], r["strip_looms"], r["strip_scrap"], r["strip_copper"]), ("2", "1", "0", "0"))
        # stage 2: out of the tray into the pockets
        self.assertEqual((r["a1"], r["a_plates"], r["a_looms"], r["a_kits"]), ("committed", "0", "0", "1"))
        # the gun shop: ONE rp_economy sale, 240 = 216 to the techie + 24 to the society (strict writers: one pocket grant)
        self.assertEqual((r["shop"], r["shop_kits"], r["shop_paid"], r["shop_society"]), ("committed", "0", "216", "24"))
        self.assertEqual(r["grants"], "1")
        # presentation requested at the bench transform (server side only)
        self.assertEqual((r["weld_at_bench"], r["drill_at_bench"], r["give_gesture"]), ("true", "true", "true"))
        # the fixer board: one event per committed step, with the coordinator op id as ref
        self.assertEqual(r["events"], "buy_parts,buy_parts,strip,strip,assemble,sell")
        self.assertEqual((r["strip_job"], r["strip_pid"], r["strip_plate_out"]), ("techie", "1", "2"))
        self.assertTrue(r["strip_ref"].startswith("tch.strip:"), r["strip_ref"])
        self.assertEqual((r["sell_total"], r["sell_buyer"]), ("240", "shop:gunshop"))
        self.assertEqual((r["sold_events"], r["crafted_events"]), ("2", "3"))
        self.assertEqual((r["told_assembled"], r["told_shop"]), ("true", "true"))
        self.assertEqual((r["tray_free"], r["pockets_free"]), ("true", "true"))
        self.assertEqual(r["conserved"], "true", r["conservation"])
        self.assertEqual(r["unbalanced"], "nil")

    def test_trades_need_consent_and_pay_once(self):
        r = self.run_ok("trades")
        self.assertEqual((r["told1"], r["op1_done"]), ("true", "true"))
        self.assertEqual((r["acc_kits"], r["acc_paid"], r["acc_got"], r["acc_left"]), ("1", "300", "300", "2"))
        self.assertEqual((r["dec_kits"], r["dec_cash"], r["dec_told"]), ("1", "true", "true"))
        self.assertEqual((r["broke_kits"], r["broke_cash"], r["broke_left"], r["broke_told"]), ("1", "0", "2", "true"))
        # the techie buys parts from a scrapper: the scrapper is the one who consents
        self.assertEqual((r["told_scrapper"], r["op4_done"]), ("true", "true"))
        self.assertEqual((r["parts_t"], r["parts_s"], r["parts_got"], r["parts_paid"]), ("2", "2", "80", "80"))
        # the ripperdoc job's export: the techie (seller) consents; other callers are refused
        self.assertEqual((r["export_ok"], r["told_techie"], r["op5_done"]), ("true", "true", "true"))
        self.assertEqual((r["servo_b"], r["servo_t"]), ("1", "0"))
        self.assertEqual((r["denied"], r["denied_why"]), ("nil", "caller_not_allowed"))
        # a clock-out withdraws a waiting offer at once
        self.assertEqual(r["withdrawn"], "stale_job_epoch")
        self.assertEqual((r["offers_left"], r["promised_left"]), ("true", "true"))
        self.assertEqual((r["sell_events"], r["buy_events"], r["trades"]), ("2", "1", "3"))
        self.assertEqual(r["conserved"], "true", r["conservation"])
        self.assertEqual(r["unbalanced"], "nil")

    def test_refusals_before_the_bar_are_told(self):
        r = self.run_ok("refusals")
        self.assertEqual((r["r1"], r["r1_reason"], r["r1_stage"], r["r1_presented"]),
                         ("failed", "missing_parts", "reserve", "false"))
        self.assertEqual(r["told1"], "true")             # "Missing: 3 Scrap metal (have 0)"
        self.assertEqual((r["r2"], r["r2_reason"], r["told2"]), ("failed", "missing_components", "true"))
        self.assertEqual((r["r3"], r["r3_reason"], r["told3"], r["scrap_kept"]), ("failed", "tray_full", "true", "3"))
        self.assertEqual(r["told_grade"], "true")
        self.assertIn("invalid_target", r["refused1"])   # a prompt intent the bench does not offer
        self.assertIn("off_duty", r["refused1"])
        self.assertEqual(r["refused2"], "no_job")
        self.assertEqual((r["r6"], r["r6_reason"], r["told6"]), ("failed", "nothing_to_sell", "true"))
        self.assertEqual((r["r7"], r["r7_reason"], r["r7_stage"], r["told7"], r["chips"]),
                         ("failed", "not_enough_cash", "reserve", "true", "0"))
        self.assertEqual((r["not_tradeable"], r["self_trade"], r["no_techie"]), ("not_tradeable", "self_trade", "techie_required"))
        self.assertEqual((r["bad_price"], r["bad_count"], r["lacking"], r["far"]),
                         ("invalid_price", "invalid_count", "seller_lacks_items", "too_far"))
        self.assertEqual((r["forged_commit"], r["forged_why"]), ("nil", "not_owner"))
        self.assertEqual((r["forged_reserve"], r["forged_rwhy"], r["forged_trades"]), ("nil", "not_owner", "0"))
        self.assertEqual(r["held"], "true")
        self.assertEqual(r["conserved"], "true", r["conservation"])
        self.assertEqual(r["unbalanced"], "nil")

    def test_cancellations_release_the_hold(self):
        r = self.run_ok("cancellations")
        self.assertEqual(r["held_during"], "true")
        self.assertEqual((r["c1"], r["c1_reason"], r["scrap1"], r["plates1"], r["free1"]),
                         ("cancelled", "cancelled_by_player", "6", "0", "true"))
        self.assertEqual((r["c2"], r["c2_reason"], r["scrap2"], r["plates2"]), ("cancelled", "dead", "6", "0"))
        self.assertEqual(r["plates0"], "4")
        self.assertEqual((r["c3"], r["c3_reason"], r["plates3"], r["mags3"], r["free3"]),
                         ("cancelled", "stale_job_epoch", "4", "0", "true"))
        self.assertEqual((r["c4"], r["c4_reason"], r["plates4"], r["mags4"], r["free4"]),
                         ("cancelled", "too_far", "4", "0", "true"))
        self.assertEqual((r["c5"], r["c5_reason"], r["plates5"], r["mags5"], r["free5"]),
                         ("cancelled", "owner_stopped", "4", "0", "true"))
        self.assertEqual((r["done"], r["mags_end"], r["plates_end"]), ("committed", "1", "1"))
        self.assertEqual(r["conserved"], "true", r["conservation"])
        self.assertEqual(r["unbalanced"], "nil")

    def test_disconnects_release_and_drop(self):
        r = self.run_ok("disconnects")
        self.assertEqual((r["c1"], r["c1_reason"], r["scrap1"], r["plates1"], r["free1"]),
                         ("cancelled", "disconnected", "3", "0", "true"))
        self.assertEqual((r["again"], r["plates"]), ("committed", "2"))   # back to the same pockets and tray
        self.assertEqual((r["offered"], r["offer_gone"], r["kit_kept"], r["buyer_cash_kept"], r["told_gone"]),
                         ("true", "true", "1", "true", "true"))
        self.assertEqual(r["promised_left"], "true")
        self.assertEqual(r["conserved"], "true", r["conservation"])
        self.assertEqual(r["unbalanced"], "nil")

    def test_restart_between_stages_loses_nothing(self):
        r = self.run_ok("restart_between_stages")
        self.assertEqual((r["offered"], r["before_plates"], r["before_looms"]), ("true", "2", "1"))
        self.assertEqual((r["same"], r["offers_forgotten"]), ("true", "true"))
        self.assertEqual((r["a1"], r["kits"], r["plates_end"], r["looms_end"]), ("committed", "1", "0", "0"))
        self.assertEqual(r["conserved"], "true", r["conservation"])
        self.assertEqual(r["unbalanced"], "nil")

    def test_crash_windows_burn_and_mint_together(self):
        r = self.run_ok("crash_windows")
        self.assertEqual((r["o1"], r["o1_reason"], r["t1"], r["t1_agree"]), ("failed", "store_unavailable", "0", "true"))
        self.assertEqual((r["o2"], r["t2"], r["t2_agree"]), ("committed", "1", "true"))
        self.assertEqual((r["o3"], r["t3"], r["t3_agree"], r["doubts_left"]), ("in_doubt", "2", "true", "0"))
        self.assertEqual((r["o4"], r["t4"], r["t4_agree"]), ("in_doubt", "2", "true"))
        self.assertEqual(r["strip_events"], "2")         # once per committed strip, settled ones included
        self.assertEqual(r["unbalanced"], "nil")

    def test_shop_payment_modes(self):
        r = self.run_ok("shop_modes")
        self.assertEqual((r["r1"], r["r1_reason"], r["told1"], r["kits1"]), ("failed", "shop_not_configured", "true", "1"))
        # ledger mode: 2 servos x 340 = 680 minted out of sys:techie.shop, 612 + 68
        self.assertEqual((r["r2"], r["servos"], r["paid2"], r["society2"]), ("committed", "0", "612", "68"))
        self.assertEqual((r["minted2"], r["burned2"]), ("680", "2"))
        # rp_economy in doubt on every try: the sweep follows the sale, paid once
        self.assertEqual((r["r3"], r["r3_reason"], r["waited"], r["calls"]), ("in_doubt", "in_doubt", "true", "3"))
        self.assertEqual((r["paid3"], r["mags3"], r["shop_sales"], r["sell_events"]), ("306", "0", "1", "1"))
        self.assertEqual(r["unbalanced"], "nil")

    def test_bench_menu(self):
        r = self.run_ok("menu")
        self.assertEqual((r["menu_op"], r["crafted"]), ("committed", "committed"))
        self.assertEqual(r["ids"], "strip_plate,strip_wire,assemble_suppressor,assemble_magazine,assemble_sight")
        self.assertEqual(r["ids2"], "strip_chip,assemble_servo,assemble_neural,assemble_optic")
        self.assertEqual((r["missing_suppressor"], r["menu_title"], r["menu_tray"]),
                         ("true", "Workbench, Kabuki west workshop", "Tray: empty."))
        self.assertEqual((r["nothing_started"], r["by_command"], r["chat_list"]), ("true", "committed", "true"))
        self.assertEqual(r["unbalanced"], "nil")

    def test_lab_console_drives_the_whole_loop(self):
        r = self.run_ok("lab_console")
        for key in ("s1", "s2", "s3", "a1", "b1", "shop"):
            self.assertEqual(r[key], "committed", key)
        self.assertEqual((r["sold"], r["sights_b"]), ("true", "1"))
        for key in ("state_line", "receipt_line", "tray_line", "bench_line", "status_line", "mint_line", "mint_last",
                    "clock_line"):
            self.assertNotEqual(r[key], "0", key)
        # techie.mintrules prints one tunable line per slot: none longer than a tunable holds.
        self.assertLessEqual(int(r["mint_longest"]), 256)
        self.assertEqual(r["unbalanced"], "nil")

    def test_catalogue_exports_and_parts_ownership(self):
        r = self.run_ok("catalogue_and_parts")
        self.assertEqual(r["components"], "tch_cw_neural_link:800,tch_cw_servo:340,tch_cw_optic:520")
        self.assertEqual((r["is_comp"], r["not_comp"]), ("true", "false"))
        self.assertEqual((r["recipes"], r["products"], r["parts"]), ("9", "6", "3"))
        self.assertEqual((r["scrap_by"], r["defined_here"]), ("rp_techie", "true"))     # no rp_salvage
        self.assertEqual((r["scrap_by2"], r["defined_here2"]), ("rp_salvage", "false"))  # rp_salvage owns them
        self.assertEqual(r["warned"], "1")
        self.assertEqual((r["under_other"], r["event_job"]), ("committed", "techie"))
        self.assertEqual(r["unbalanced"], "nil")


if __name__ == "__main__":
    unittest.main()
