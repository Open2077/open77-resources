"""W3-2 CHOOH2 chain (rp_chooh2): corn -> crate -> truck -> intake -> refinery -> sale / refuel, offline.

Run with `python -m unittest discover -s tests -p "test_w3_chooh2*.py"` (Lua 5.4: lupa, or a
lua54.dll such as the KeraLua NuGet cache's; see tests/compat/luahost.py).

Each scenario boots, on tests/compat/multihost.lua: the FINAL open77_transactions resource (its
server/main.lua, exports, policy and work queue; the memory store plays the database), the real
open77_actions, open77_containers and open77_fuel (resources/system), the real rp_economy, rp_cargo
and rp_chooh2, and shims for the public exports of rp_jobs, rp_garage and rp_inventory.
Scenario code: tests/compat/chooh2_scenarios.lua; world: tests/compat/chooh2_world.lua (on top of
salvage_world.lua).

Sources outside this pack are READ in place, never copied or edited:
  OP77_SYS_DIR   the Open77 resources/system folder with open77_actions, open77_containers and
                 open77_fuel (default: this repository's system/ folder)
  OP77_TX_FINAL  the final open77_transactions folder (default: SYS_DIR's copy)
A missing source skips the suite with the reason.

What this cannot show: anything in game (presentation, the animations, timing on a live tick, real
platform event payloads, the measured positions), SQL semantics on MariaDB, the real rp_jobs /
rp_garage / rp_inventory behind their exports.
"""
import os
import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent / "compat"))
import luahost  # noqa: E402

ROOT = Path(__file__).resolve().parents[1]
COMPAT = ROOT / "tests" / "compat"


def sys_dir():
    explicit = os.environ.get("OP77_SYS_DIR")
    if explicit and Path(explicit).is_dir():
        return Path(explicit)
    bundled = ROOT.parent / "system"
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
    for name in ("open77_actions", "open77_containers", "open77_fuel"):
        if not (sys_dir() / name / "open77.lua").is_file():
            return f"{name} not found under {sys_dir()} (set OP77_SYS_DIR)"
    if not (tx_dir() / "server" / "main.lua").is_file():
        return f"final open77_transactions not found at {tx_dir()} (set OP77_TX_FINAL)"
    return None


def scenario(name):
    return luahost.run_scenario("chooh2_scenarios.lua", name, {
        "ROOT_DIR": ROOT.as_posix(), "COMPAT_DIR": COMPAT.as_posix(),
        "SYS_DIR": sys_dir().as_posix(), "TX_DIR": tx_dir().as_posix(),
    })


class Chooh2Sources(unittest.TestCase):
    def test_sources_compile_without_bom(self):
        """Every rp_chooh2 Lua file: UTF-8 without BOM and loads as Lua 5.4 text."""
        if luahost.unavailable():
            self.skipTest(luahost.unavailable())
        lua = luahost.new_state()
        try:
            for path in sorted((ROOT / "rp_chooh2").rglob("*.lua")):
                data = path.read_bytes()
                self.assertFalse(data.startswith(b"\xef\xbb\xbf"), f"{path} has a BOM")
                data.decode("utf-8")
                if path.name == "open77.lua":
                    continue    # the manifest DSL is parsed by the host, not Lua
                source = data.decode("utf-8")
                lua.execute(f"assert(load({luahost.lua_string(source)}, "
                            f"{luahost.lua_string('@' + path.name)}, 't'))", "=compile")
        finally:
            lua.close()

    def test_manifest_is_opt_in_and_least_privilege(self):
        text = (ROOT / "rp_chooh2" / "open77.lua").read_text(encoding="utf-8")
        self.assertIn("auto_start false", text)
        self.assertIn('permissions { "world.vehicles", "world.npcs", "network.events" }', text)
        self.assertNotIn("database.access", text.split("permissions", 1)[1].split("}", 1)[0])
        self.assertNotIn("client_script", text)
        self.assertNotIn('dependency "open77_fuel', text)      # optional: refuel says so instead

    def test_every_point_says_whether_it_was_walked(self):
        """Rule 1: every place carries `measured` (true once someone walked it in game)."""
        text = (ROOT / "rp_chooh2" / "server" / "config.lua").read_text(encoding="utf-8")
        self.assertGreaterEqual(text.count("measured = true") + text.count("measured = false"), 14)

    def test_prompt_labels_are_plain_ascii(self):
        for name in ("config.lua", "service.lua", "model.lua", "main.lua"):
            text = (ROOT / "rp_chooh2" / "server" / name).read_text(encoding="utf-8")
            self.assertTrue(all(ord(ch) < 128 for ch in text), f"{name} has a non-ASCII character")


@unittest.skipIf(missing_sources(), missing_sources())
class Chooh2Chain(unittest.TestCase):
    def run_ok(self, name):
        r = scenario(name)
        self.assertEqual(r.get("errors"), "0", r.get("first_error"))
        return r

    def test_happy_path_three_players_strict_writers(self):
        r = self.run_ok("happy_path")
        self.assertEqual(r["boot_lines"], "1/1/1/1/1")
        self.assertEqual((r["row_warnings"], r["job_warning"]), ("0", "0"))
        self.assertEqual(r["clock"], "committed")
        self.assertEqual((r["h1"], r["h4"]), ("committed", "committed"))
        self.assertGreaterEqual(int(r["corn_in_crate"]), 12)        # four harvests of 3..5
        self.assertLessEqual(int(r["corn_in_crate"]), 20)
        # a picked-clean row: the prompt drops "Harvest corn", a server request is refused, told
        self.assertEqual((r["fifth"], r["fifth_refused"]), ("none", "invalid_target"))
        self.assertEqual((r["console_refused"], r["told_clean"]), ("1", "true"))
        self.assertEqual(r["depleted_label"], "Corn row 1 (picked clean)")
        self.assertEqual((r["inspect"], r["told_row"]), ("committed", "true"))
        # haul: load with a key, unload into the hands, empty into the intake
        self.assertEqual(r["carried"], "true")
        self.assertEqual(r["load"], "committed", r.get("load_reason"))
        self.assertEqual(r["token_in_bed"], "true")
        self.assertEqual((r["unload"], r["carried_again"]), ("committed", "true"))
        self.assertEqual(r["deliver"], "committed", r.get("deliver_reason"))
        self.assertEqual(r["intake"], r["intake_expected"])
        self.assertEqual((r["hold_closed"], r["token_retired"]), ("true", "true"))
        # refine exactly once: -10 corn, +2 canisters; gauges; collect into the pockets
        self.assertEqual(r["clock3"], "committed")
        self.assertEqual(r["run"], "committed", r.get("run_reason"))
        self.assertEqual(r["intake_after_run"], r["intake_after_run_expected"])
        self.assertEqual((r["gauges"], r["told_gauges"]), ("committed", "true"))
        self.assertEqual((r["collect"], r["pockets_after_collect"], r["rack_after"]), ("committed", "2", "0"))
        # one canister into the truck at the pump (open77_fuel, real), one sold at the depot
        self.assertEqual(r["refuel"], "committed", r.get("refuel_reason"))
        self.assertEqual((r["fuel_after"], r["told_poured"]), ("35.0", "true"))
        self.assertEqual(r["sale"], "committed", r.get("sale_reason"))
        self.assertEqual((r["paid"], r["society"], r["pockets_end"]), ("135", "15", "0"))
        self.assertEqual(r["pocket_grants"], "1")                     # rp_economy got the pockets for one op
        self.assertEqual(r["told_sold"], "true")
        # offices and the fixer feed
        self.assertEqual(r["clock_out"], "committed")
        self.assertEqual((r["civ"], r["civ_reason"], r["told_civ"]), ("failed", "no_job", "true"))
        self.assertEqual(r["events"], "harvest=4 deliver_intake=1 refine=1 sell=1 refuel=1")
        self.assertEqual(r["deliver_job"], "chooh2")
        self.assertTrue(r["deliver_ref"].startswith("ch2.deliver:"))
        self.assertEqual(r["deliver_corn"], r["intake_expected"])
        self.assertEqual(r["clerk"], "1")
        self.assertEqual(r["conserved"], "true", r["conservation"])
        self.assertEqual(r["unbalanced"], "nil")

    def test_cancel_mid_harvest_grants_nothing(self):
        r = self.run_ok("cancel_mid_harvest")
        self.assertEqual((r["x"], r["x_reason"]), ("cancelled", "cancelled_by_player"))
        self.assertEqual((r["holds_during_x"], r["holds_after_x"], r["corn_after_x"]), ("1", "0", "0"))
        self.assertEqual((r["dead"], r["dead_reason"]), ("cancelled", "dead"))
        self.assertEqual((r["holds_during_dead"], r["holds_after_dead"]), ("1", "0"))
        self.assertEqual(r["charges_before"], "4")                   # no charge spent by either
        self.assertEqual((r["w"], r["charges_after"], r["committed"]), ("committed", "3", "1"))
        self.assertEqual(r["events"], "harvest=1 deliver_intake=0 refine=0 sell=0 refuel=0")
        self.assertEqual(r["unbalanced"], "nil")

    def test_truck_without_key(self):
        r = self.run_ok("truck_without_key")
        self.assertEqual((r["refused"], r["reason"]), ("failed", "no_access"))
        self.assertEqual((r["still_carrying"], r["token_in_hold"]), ("true", "true"))
        self.assertEqual(r["still_carrying_after_command"], "true")
        self.assertEqual(r["told_no_key"], "true")
        self.assertEqual((r["civilian_carrying"], r["civilian_refused"]), ("false", "no_job"))
        self.assertEqual((r["with_key"], r["token_in_bed"]), ("committed", "true"))

    def test_restart_with_crates_on_ground_in_hands_in_bed(self):
        r = self.run_ok("restart")
        self.assertEqual((r["load"], r["carried_before"]), ("committed", "true"))
        self.assertEqual(r["reboot_lines"], "1/1/1/1/1")             # "(0 created)": same rows
        self.assertEqual(r["states"], "ground/ground/truck")           # ground / hands / bed
        self.assertEqual(r["hands_back_at_spot"], "true")              # last durable placement
        self.assertEqual(r["items"], "2")
        self.assertEqual((r["l2"], r["l3"], r["delivered"]), ("committed", "committed", "3"))
        self.assertEqual(r["intake"], r["corn_total"])
        self.assertEqual(r["holds_left"], "0")
        self.assertEqual(r["conserved"], "true", r["conservation"])
        self.assertEqual(r["unbalanced"], "nil")

    def test_refinery_double_press_runs_once(self):
        r = self.run_ok("refinery_double_press")
        self.assertEqual((r["empty"], r["empty_refusal"], r["told_empty"]), ("none", "intake_empty", "true"))
        self.assertEqual(r["stocked"], "25")
        self.assertEqual((r["first"], r["second"]), ("committed", "none"))
        self.assertIn("actor_busy", r["refusals1"])                    # the same operator's second press
        self.assertEqual(r["refusals2"], "target_claimed")             # another operator, same station
        self.assertEqual(r["after_one"], "15/2")
        self.assertEqual((r["again"], r["after_replay"]), ("replay=true", "15/2"))
        self.assertEqual((r["run2"], r["third"], r["after_two"]), ("committed", "none", "5/6"))
        self.assertEqual((r["lost"], r["before4"], r["after4"]), ("committed", "15/4", "5/6"))
        self.assertEqual((r["runs"], r["refine_events"]), ("3", "3"))
        self.assertEqual(r["unbalanced"], "nil")

    def test_delivery_in_doubt_lands_once(self):
        r = self.run_ok("delivery_in_doubt")
        # first state / reason / still carrying / corn in the intake after it / second / exact / closed
        self.assertEqual(r["landed"], "committed/ok/false/4/none/true/true")
        self.assertEqual(r["never_sent"], "committed/ok/false/5/none/true/true")
        self.assertTrue(r["pending"].startswith("in_doubt/in_doubt/false/4/none/true/"), r["pending"])
        self.assertEqual((r["told_doubt"], r["recovered"], r["holds_left"]), ("true", "1", "0"))
        self.assertEqual(r["intake"], r["corn_total"])
        self.assertEqual((r["deliveries"], r["events"], r["attempts"]), ("3", "3", ".a1,.a2,.a1"))
        self.assertEqual((r["carrying"], r["items"]), ("false", "0"))
        self.assertEqual(r["unbalanced"], "nil")

    def test_refuel_burns_once_and_fills_through_open77_fuel(self):
        r = self.run_ok("refuel")
        self.assertEqual(r["spawned_full"], "60.0")
        self.assertEqual((r["none"], r["none_reason"], r["none_stage"], r["told_none"]),
                         ("failed", "no_canisters", "reserve", "true"))
        self.assertEqual(r["given"], "3")
        for case in ("full", "moving", "down"):
            self.assertEqual(r[case], "none", case)                    # refused before anything started
        self.assertEqual((r["told_full"], r["told_moving"], r["told_down"]), ("true", "true", "true"))
        self.assertEqual(r["kept_after_refusals"], "3")
        self.assertEqual((r["ok"], r["fuel_after"], r["left"], r["told_poured"]), ("committed", "25.0", "2", "true"))
        self.assertEqual((r["gone"], r["told_lost"]), ("committed", "true"))
        self.assertEqual((r["canisters_end"], r["burned"], r["events"], r["fills_left"]), ("1", "2", "2", "0"))
        self.assertEqual(r["unbalanced"], "nil")

    def test_sale_pays_once(self):
        r = self.run_ok("sale_once")
        self.assertEqual((r["empty"], r["empty_refusal"]), ("none", "no_canisters"))
        self.assertEqual((r["s1"], r["paid1"], r["society"], r["pockets"]), ("committed", "405", "45", "0"))
        self.assertEqual((r["again"], r["paid2"]), ("replay=true", "0"))
        self.assertEqual((r["farmhand"], r["farmhand_refusal"], r["farmhand_pockets"]), ("none", "wrong_job", "1"))
        self.assertEqual(r["sell_events"], "1")
        self.assertEqual(r["unbalanced"], "nil")

    def test_jobs_missing_are_reported(self):
        r = self.run_ok("jobs_missing")
        self.assertEqual((r["ready"], r["warning"]), ("true", "1"))
        self.assertEqual((r["harvest"], r["refusal"]), ("none", "unknown_job"))

    def test_console_drives_the_chain(self):
        r = self.run_ok("console")
        self.assertEqual((r["h"], r["picked"], r["dropped"]), ("committed", "true", "true"))
        self.assertEqual((r["r"], r["c"], r["s"]), ("committed", "committed", "committed"))
        for key in ("state_receipt", "state_cash", "status", "intake_line", "reset", "clock"):
            self.assertEqual(r[key], "1", key)
        self.assertEqual(r["same_node"], "true")


if __name__ == "__main__":
    unittest.main()
