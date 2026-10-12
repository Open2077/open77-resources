"""C1 salvage pilot (rp_salvage): the whole loop on the real wave-1 libraries, offline.

Run with `python -m unittest discover -s tests -p "test_c1*.py"` (Lua 5.4: lupa, or a lua54.dll
such as the KeraLua NuGet cache's; see tests/compat/luahost.py).

Each scenario boots, on tests/compat/multihost.lua: the FINAL open77_transactions resource (its
server/main.lua, exports, policy and work queue; the memory store plays the database), the real
open77_actions and open77_containers (Open77 repository, resources/system), the real rp_economy,
rp_cargo and rp_salvage, and shims for the public exports of rp_jobs, rp_garage and rp_inventory.
Scenario code: tests/compat/salvage_scenarios.lua; world: tests/compat/salvage_world.lua.

Sources outside this pack are READ in place, never copied or edited:
  OP77_SYS_DIR   the Open77 resources/system folder with open77_actions and open77_containers
                 (default: this repository's system/ folder, else ../wt-world-interaction/resources/system)
  OP77_TX_FINAL  the final open77_transactions folder (default: SYS_DIR's copy when it has a
                 server/main.lua, else ../wt-wi-a13b/resources/system/open77_transactions)
A missing source skips the suite with the reason.

What this cannot show: anything in game (presentation, timing on a live tick, real platform
event payloads), SQL semantics on MariaDB (the coordinator's own suites), the real rp_jobs /
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
    bundled = ROOT.parent / "system"          # this repository's own system/ folder
    if (bundled / "open77_actions").is_dir():
        return bundled
    return ROOT.parent / "wt-world-interaction" / "resources" / "system"


def tx_dir():
    explicit = os.environ.get("OP77_TX_FINAL")
    if explicit and (Path(explicit) / "server" / "main.lua").is_file():
        return Path(explicit)
    merged = sys_dir() / "open77_transactions"
    if (merged / "server" / "main.lua").is_file():
        return merged
    return ROOT.parent / "wt-wi-a13b" / "resources" / "system" / "open77_transactions"


def missing_sources():
    why = luahost.unavailable()
    if why:
        return why
    for name in ("open77_actions", "open77_containers"):
        if not (sys_dir() / name / "open77.lua").is_file():
            return f"{name} not found under {sys_dir()} (set OP77_SYS_DIR)"
    if not (tx_dir() / "server" / "main.lua").is_file():
        return f"final open77_transactions not found at {tx_dir()} (set OP77_TX_FINAL)"
    return None


def scenario(name):
    return luahost.run_scenario("salvage_scenarios.lua", name, {
        "ROOT_DIR": ROOT.as_posix(), "COMPAT_DIR": COMPAT.as_posix(),
        "SYS_DIR": sys_dir().as_posix(), "TX_DIR": tx_dir().as_posix(),
    })


class SalvageSources(unittest.TestCase):
    def test_sources_compile_without_bom(self):
        """Every rp_salvage Lua file: UTF-8 without BOM (a BOM kills a resource silently) and loads
        as Lua 5.4 text. Line ends are not checked: the repository stores LF, and a checkout with
        core.autocrlf may turn them into CRLF, which Lua accepts."""
        if luahost.unavailable():
            self.skipTest(luahost.unavailable())
        lua = luahost.new_state()
        try:
            for path in sorted((ROOT / "rp_salvage").rglob("*.lua")):
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
        text = (ROOT / "rp_salvage" / "open77.lua").read_text(encoding="utf-8")
        self.assertIn("auto_start false", text)
        self.assertIn('permissions { "world.props", "world.vehicles", "world.npcs", "network.events" }', text)
        self.assertNotIn("database.access", text.split("permissions", 1)[1].split("}", 1)[0])
        self.assertNotIn("client_script", text)


@unittest.skipIf(missing_sources(), missing_sources())
class SalvageLoop(unittest.TestCase):
    def run_ok(self, name):
        r = scenario(name)
        self.assertEqual(r.get("errors"), "0", r.get("first_error"))
        return r

    def test_happy_path_end_to_end(self):
        r = self.run_ok("happy_path")
        # README section 1 start lines, once each (a first boot creates the five nodes)
        self.assertEqual(r["boot_lines"], "1/1/1/1/1")
        self.assertEqual(r["node_warnings"], "0")
        self.assertEqual(r["clock"], "committed")
        self.assertEqual(r["tools"], "ok/ok")
        self.assertEqual((r["w1"], r["w2"], r["w3"]), ("committed", "committed", "committed"))
        self.assertEqual(r["crate_hold"], "true")
        self.assertEqual(r["token_home"], "true")
        self.assertEqual(r["welder"], "28")
        self.assertEqual(r["crowbar"], "19")
        self.assertEqual(r["carried"], "true")
        self.assertEqual(r["load"], "committed", r.get("load_reason"))
        self.assertEqual(r["token_in_bed"], "true")
        self.assertEqual(r["bed_props"], "1")
        self.assertEqual(r["unload"], "committed")
        self.assertEqual(r["carried_again"], "true")
        self.assertEqual(r["token_back"], "true")
        self.assertEqual(r["sale"], "committed", r.get("sale_reason"))
        self.assertEqual(r["paid"], r["expected_seller"])
        self.assertEqual(r["society"], r["expected_society"])
        self.assertEqual(r["hold_closed"], "true")
        self.assertEqual(r["token_retired"], "true")
        self.assertEqual(r["conserved"], "true", r["conservation"])
        self.assertEqual(r["unbalanced"], "nil")
        self.assertEqual(r["node_charges"], "0")
        # presentation around the loop (server side only: no claim about what renders)
        self.assertEqual(r["inspect"], "committed")          # still offered on a stripped wreck
        self.assertEqual(r["told_haul"], "true")
        self.assertEqual(r["scavenged"], "true")
        self.assertEqual(r["hand_props"], "tool.fire_axe")   # tool.crowbar refused -> fallback alias
        self.assertEqual(r["hand_props_left"], "0")
        self.assertEqual(r["buyer_npcs"], "1")
        self.assertEqual(r["clock_out"], "committed")
        self.assertEqual(r["off_duty"], "off_duty")
        self.assertEqual((r["civ"], r["civ_reason"], r["told_civ"]), ("failed", "no_job", "true"))

    def test_lab_console_drives_the_whole_loop(self):
        """Every salvage.lab.* step with explicit player ids, then state / status / reset / truck."""
        r = self.run_ok("lab_console")
        self.assertEqual(r["w"], "committed")
        self.assertEqual(r["picked"], "true")
        self.assertEqual(r["load"], "committed")
        self.assertEqual(r["unloaded"], "true")
        self.assertEqual(r["sale"], "committed")
        for key in ("state_tool", "state_cash", "state_receipt", "status", "reset", "truck_hint", "clock"):
            self.assertEqual(r[key], "1", key)
        self.assertEqual(r["charges_before_reset"], "2")
        self.assertEqual(r["same_node"], "true")             # refill in place, not close + re-create
        self.assertEqual(r["charges"], "3")

    def test_contention_one_winner_each(self):
        """Same wreck, same crate, same truck at once: one winner, explicit refusals, distinct slots."""
        r = self.run_ok("contention")
        self.assertEqual(r["a"], "committed")
        self.assertEqual(r["b_op"], "none")                  # refused before anything was held
        self.assertEqual(r["b_refused"], "target_claimed")
        self.assertEqual(r["b_holds_at_thorton"], "0")
        self.assertEqual(r["carried_by"], "A")
        self.assertIn("item_unavailable", r["pickup_refused"])
        self.assertEqual(r["bay_b"], "target_claimed")
        self.assertEqual((r["l1"], r["l1b"], r["l2"]), ("committed", "committed", "committed"))
        self.assertEqual(r["slots"], "1,2,3")
        self.assertEqual(r["conserved"], "true", r["conservation"])
        self.assertEqual(r["unbalanced"], "nil")

    def test_full_crate_refuses_before_work(self):
        r = self.run_ok("full_crate")
        self.assertEqual(r["seeded"], "ok")
        self.assertEqual((r["state"], r["reason"], r["stage"]), ("failed", "crate_full", "reserve"))
        self.assertEqual(r["presented"], "false")           # no bar ever started
        self.assertEqual((r["pry_state"], r["pry_reason"]), ("failed", "crate_full"))
        self.assertEqual(r["durability_kept"], "true")
        self.assertEqual(r["crowbar"], "20")
        self.assertEqual(r["charges_kept"], "true")
        self.assertEqual(r["scrap_kept"], "true")
        self.assertEqual(r["holds"], "1")                   # no second crate opened
        self.assertEqual(r["told_full"], "true")

    def test_crash_windows_conserve(self):
        """Work commit: never received / ack lost / coordinator dies (detached, discarded) /
        coordinator gone before the commit was submitted."""
        r = self.run_ok("crash_windows")
        self.assertEqual((r["o1"], r["o1_reason"]), ("failed", "store_unavailable"))
        self.assertEqual((r["t1_works"], r["t1_agree"]), ("0", "true"))
        self.assertEqual((r["o2"], r["t2_works"], r["t2_agree"]), ("committed", "1", "true"))
        self.assertEqual((r["o3"], r["t3_works"], r["t3_agree"]), ("in_doubt", "2", "true"))
        self.assertEqual(r["doubts_left"], "0")
        self.assertEqual(r["o4"], "in_doubt")
        self.assertEqual((r["works_unchanged_4"], r["t4_agree"]), ("true", "true"))
        self.assertEqual((r["t4_wear_unchanged"], r["t4_spent_unchanged"]), ("true", "true"))
        # 5: nothing was submitted, so nothing can have landed: failed with the reason, not in doubt
        self.assertEqual((r["o5"], r["o5_reason"]), ("failed", "coordinator_unavailable"))
        self.assertEqual((r["works_unchanged_5"], r["t5_agree"]), ("true", "true"))
        self.assertEqual((r["t5_wear_unchanged"], r["t5_spent_unchanged"]), ("true", "true"))
        self.assertEqual(r["doubts_after_5"], "0")
        self.assertEqual(r["told_offline"], "true")
        self.assertEqual(r["crate_placed"], "true")
        self.assertEqual(r["items"], "1")
        self.assertEqual(r["unbalanced"], "nil")

    def test_replayed_sale_pays_once(self):
        r = self.run_ok("replayed_sale")
        self.assertEqual(r["s1"], "committed")
        self.assertGreater(int(r["paid1"]), 0)
        self.assertGreater(int(r["soc1"]), 0)
        self.assertEqual(r["told_sold"], "true")
        self.assertEqual(r["again_replay"], "true")
        self.assertEqual(r["paid2"], "0")
        self.assertEqual(r["again2"], "replay=true")       # after an rp_economy restart
        self.assertEqual(r["paid3"], "0")
        # A sale that committed right before a crash, its crate not retired yet:
        self.assertEqual(r["s2"], "committed")
        self.assertEqual(r["retire_pending"], "true")
        self.assertGreater(int(r["paid4"]), 0)
        self.assertEqual(r["cash_after_restart"], "true")
        self.assertEqual(r["crate2_known"], "false")        # retired at boot, never re-placed
        self.assertEqual(r["crate2_hold"], "false")
        self.assertEqual(r["crate2_items"], "0")
        self.assertEqual(r["unbalanced"], "nil")

    def test_restart_with_crates_on_ground_in_hands_in_bed(self):
        r = self.run_ok("restart")
        self.assertEqual(r["load"], "committed")
        self.assertEqual(r["carried_before"], "true")
        self.assertEqual((r["ground"], r["hands"], r["bed"]), ("ground", "ground", "truck"))
        self.assertEqual(r["hands_back_at_spot"], "true")   # last durable placement
        self.assertEqual((r["ground_item"], r["hands_item"]), ("1", "1"))
        self.assertEqual(r["items_after"], "2")
        self.assertEqual(r["bed_props"], "1")
        self.assertEqual((r["sold_ground"], r["sold_hands"], r["unload"], r["sold_bed"]),
                         ("committed", "committed", "committed", "committed"))
        self.assertEqual(r["holds_left"], "0")
        self.assertEqual(r["earned"], "true")
        self.assertEqual(r["conserved"], "true", r["conservation"])
        self.assertEqual(r["unbalanced"], "nil")

    def test_stranger_cannot_load_a_truck(self):
        r = self.run_ok("stranger_load")
        self.assertEqual((r["refused"], r["reason"]), ("failed", "no_access"))
        self.assertEqual(r["still_carrying"], "true")
        self.assertEqual(r["token_in_hold"], "true")
        self.assertEqual(r["still_carrying_after_command"], "true")
        self.assertEqual(r["bed"], "0")
        self.assertEqual(r["told_no_key"], "true")
        self.assertEqual(r["civilian_carrying"], "false")
        self.assertEqual(r["civilian_refused"], "no_job")
        self.assertEqual(r["with_key"], "committed")
        self.assertEqual(r["token_in_bed"], "true")

    def test_containers_restart_keeps_nodes_and_charges(self):
        """open77_containers 0.2.0 restarts (stopped, then booting without the coordinator): same
        keyed node ids, the charge spent meanwhile kept and applied once it is ready; rp_salvage
        restarts and finds the nodes without creating any."""
        r = self.run_ok("containers_restart")
        self.assertEqual((r["w1"], r["w2"]), ("committed", "committed"))
        self.assertEqual(r["keys"], ",".join(["ok"] * 5))    # every node keyed node.<key>
        self.assertEqual((r["pending_stopped"], r["pending_booting"], r["pending_after"]), ("1", "1", "0"))
        self.assertEqual(r["same_ids"], "true")
        self.assertEqual(r["refound"], "1")                  # re-run on open77_containers:ready
        self.assertEqual((r["charges"], r["works"]), ("1", "2"))
        self.assertEqual(r["same_after_salvage_restart"], "true")
        self.assertEqual(r["salvage_boot_lines"], "1/1/1/1/1")  # its restart: "(0 created)"
        self.assertEqual(r["node_rows"], "5")                # zero-capacity world rows, one per node
        # an operator closes a node: prompt withdrawn, key spent (said once), the others untouched
        self.assertEqual((r["closed_id_dropped"], r["closed_target"]), ("true", "true/false"))
        self.assertEqual((r["closed_warned"], r["key_spent"], r["others_kept"]), ("1", "1", "true"))

    def test_writers_without_containers_leave_nodes_out_until_fixed(self):
        """open77_containers must be a `world` writer: without it the nodes are refused
        (namespace_denied), the yard still boots without wreck prompts and says so; fixed live,
        the sweep restores them."""
        r = self.run_ok("writers_missing")
        self.assertEqual((r["ready"], r["missing"]), ("true", "5"))
        self.assertEqual((r["warned"], r["summary_line"]), ("1", "1"))
        self.assertEqual((r["no_prompt"], r["ready_line"]), ("true", "1"))   # no wreck target declared
        self.assertEqual((r["back"], r["nodes_line"]), ("5", "1"))
        self.assertEqual((r["w"], r["charges"]), ("committed", "2"))

    def test_cancellations_release_and_conserve(self):
        r = self.run_ok("cancellations")
        self.assertEqual((r["dead"], r["dead_reason"]), ("cancelled", "dead"))
        self.assertEqual((r["death_holds"], r["death_wear"], r["death_charges"], r["death_works"]), ("0", "0", "3", "0"))
        self.assertEqual(r["w"], "committed")
        for case in ("vehicle", "job_change", "disconnect", "restart"):
            # was carrying / not carrying after / crate on the ground / exactly one item
            self.assertEqual(r[case], "true/true/ground/1", case)
            self.assertEqual(r[case + "_token"], "true", case)
        self.assertEqual((r["wear"], r["works"]), ("1", "1"))
        self.assertEqual(r["conserved"], "true", r["conservation"])


if __name__ == "__main__":
    unittest.main()
