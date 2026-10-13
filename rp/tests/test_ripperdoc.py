"""Ripperdoc clinic (rp_ripperdoc): quote with consent -> one hold -> chair -> operate -> install once.

Run with `python -m unittest discover -s tests -p "test_ripperdoc*.py"` (Lua 5.4: lupa, or a lua54.dll
such as the KeraLua NuGet cache's; see tests/compat/luahost.py).

Each scenario boots, on tests/compat/multihost.lua: the FINAL open77_transactions resource (its
server/main.lua, exports, policy and work queue; the memory store plays the database), the real
open77_actions (Open77 repository, resources/system), the real rp_economy and rp_ripperdoc, shims for
the public exports of rp_jobs, rp_inventory, rp_zones and open77_seating, and fakes for the platform
natives, including the documented player-interaction lifecycle, the cyberware framework (records that
survive a restart, staged operations, the completion event) and the UI kit's server twins.
Scenario code: tests/compat/ripperdoc_scenarios.lua; world: tests/compat/ripperdoc_world.lua.

Sources outside this pack are READ in place, never copied or edited:
  OP77_SYS_DIR   the Open77 resources/system folder with open77_actions (default: this repository's
                 system/ folder, else ../wt-world-interaction/resources/system)
  OP77_TX_FINAL  the final open77_transactions folder (default: SYS_DIR's copy)
A missing source skips the suite with the reason.

What this cannot show: anything in game (poses at the chair and the station, the consent prompt,
the bars, the native implant), timing on a live tick, real platform event payloads, the real
rp_jobs / rp_inventory / rp_zones behind their exports.
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
RES = ROOT / "rp_ripperdoc"


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
    if not (sys_dir() / "open77_actions" / "open77.lua").is_file():
        return f"open77_actions not found under {sys_dir()} (set OP77_SYS_DIR)"
    if not (tx_dir() / "server" / "main.lua").is_file():
        return f"final open77_transactions not found at {tx_dir()} (set OP77_TX_FINAL)"
    return None


def scenario(name):
    return luahost.run_scenario("ripperdoc_scenarios.lua", name, {
        "ROOT_DIR": ROOT.as_posix(), "COMPAT_DIR": COMPAT.as_posix(),
        "SYS_DIR": sys_dir().as_posix(), "TX_DIR": tx_dir().as_posix(),
    })


def manifest_code():
    text = (RES / "open77.lua").read_text(encoding="utf-8")
    return "\n".join(line.split("--", 1)[0] for line in text.splitlines())


class RipperdocSources(unittest.TestCase):
    def test_sources_compile_without_bom(self):
        """Every rp_ripperdoc Lua file: UTF-8 without BOM (a BOM kills a resource silently), Lua 5.4."""
        if luahost.unavailable():
            self.skipTest(luahost.unavailable())
        lua = luahost.new_state()
        try:
            for path in sorted(RES.rglob("*.lua")):
                data = path.read_bytes()
                self.assertFalse(data.startswith(b"\xef\xbb\xbf"), f"{path} has a BOM")
                data.decode("utf-8")
                if path.name == "open77.lua":
                    continue
                source = data.decode("utf-8")
                lua.execute(f"assert(load({luahost.lua_string(source)}, "
                            f"{luahost.lua_string('@' + path.name)}, 't'))", "=compile")
        finally:
            lua.close()

    def test_manifest_least_privilege_and_client_safe_dependencies(self):
        code = manifest_code()
        self.assertIn("auto_start false", code)
        block = re.search(r"permissions\s*\{([^}]*)\}", code).group(1)
        self.assertEqual(sorted(re.findall(r'"([^"]+)"', block)), sorted([
            "network.events", "players.cyberware.define", "players.cyberware.read", "players.cyberware.manage",
            "players.hacking.define", "players.interactions.control", "players.interactions.read",
            "players.screenfx", "players.life.read", "database.access"]))
        self.assertNotIn("players.animations.control", block)     # open77_actions plays every animation
        self.assertIn('client_script "client/main.lua"', code)
        deps = re.findall(r'dependency\s+"([a-z0-9_]+)', code)
        # A manifest delivered to clients never depends on a server-only resource.
        for server_only in ("open77_transactions", "open77_furniture", "rp_economy", "rp_jobs", "rp_inventory"):
            self.assertNotIn(server_only, deps)
        self.assertIn("open77_actions", deps)
        self.assertIn("open77_player_interactions", deps)
        self.assertIn("open77_cyberware", deps)

    def test_ascii_texts_and_no_dashes(self):
        """Prompt labels and player texts are plain ASCII (a non-ASCII glyph shows as '?')."""
        for path in sorted(RES.rglob("*.lua")):
            text = path.read_text(encoding="utf-8")
            self.assertTrue(all(ord(c) < 128 for c in text), f"{path} has non-ASCII text")
        readme = (RES / "README.md").read_text(encoding="utf-8")
        self.assertTrue(all(ord(c) < 128 for c in readme), "README has non-ASCII text (no em dashes)")
        for word in (r"\bproven\b", r"\blab\b", r"\bexperimental\b",
                     r"\b20\d\d-\d\d-\d\d\b"):
            self.assertIsNone(re.search(word, readme, re.I), word)
        self.assertTrue(readme.startswith("# rp_ripperdoc\n"))
        for line in ("- **Docs:**", "- **Starts:**", "- **Needs:**", "- **Runs on:**", "## How to play", "## Setup",
                     "## Config", "## Limits"):
            self.assertIn(line, readme)

    def test_points_declare_whether_they_were_walked(self):
        config = (RES / "shared" / "config.lua").read_text(encoding="utf-8")
        flags = config.count("measured = true,") + config.count("measured = false,")
        self.assertGreaterEqual(flags, 3)                                   # chair, station, supplier
        self.assertGreaterEqual(config.count("source = "), flags)

    def test_item_ids_follow_the_inventory_rules(self):
        config = (RES / "shared" / "config.lua").read_text(encoding="utf-8")
        block = re.search(r"\nC\.items = \{(.*?)\n\}", config, re.S).group(1)
        ids = re.findall(r"^\s+([a-z0-9_]+)\s+=\s+\{", block, re.M)
        self.assertEqual(len(ids), 7)
        for item in ids:
            self.assertLessEqual(len(item), 32)
            self.assertNotIn("__", item)
        # every grade of the catalogue is stocked as one of them
        grades = re.findall(r'item = "([a-z0-9_]+)"', config)
        self.assertEqual(sorted(set(grades)), sorted(ids))


@unittest.skipIf(missing_sources(), missing_sources())
class RipperdocLoop(unittest.TestCase):
    def run_ok(self, name):
        r = scenario(name)
        self.assertEqual(r.get("errors"), "0", r.get("first_error"))
        return r

    def test_boot(self):
        r = self.run_ok("boot")
        self.assertEqual(r["ready"], "true")
        self.assertEqual(r["defs"], "5")
        self.assertEqual(r["hacking"], "true")
        self.assertEqual(r["targets"], "2")                       # chair, dealer (station: during a surgery)
        self.assertEqual((r["lie_profile"], r["op_profile"], r["restock_profile"]),
                         ("seatedsleep", "repair", "tablet2"))
        self.assertEqual(r["station"], "false")                     # no station card until a quote is accepted
        self.assertEqual(r["stock_open"], "true")
        self.assertNotEqual(r["printed_ready"], "0")

    def test_happy_path(self):
        r = self.run_ok("happy_path")
        self.assertGreaterEqual(int(r["menu_rows"]), 7)
        self.assertEqual((r["offered"], r["told_quote"], r["told_accepted"]), ("true", "true", "true"))
        # ONE hold, nothing moved yet, written to the journal
        self.assertEqual(r["held_state"], "reserved")
        self.assertEqual((r["cash_untouched_by_hold"], r["stock_untouched_by_hold"]), ("true", "true"))
        self.assertEqual(r["journal_reserved"], "1")
        self.assertEqual((r["lying"], r["told_ripper_on_chair"]), ("true", "true"))
        self.assertEqual((r["op"], r["op_receipt_how"]), ("committed", "hold"))
        # the price to the society, the box out of stock into the patient, once
        self.assertEqual((r["paid"], r["society"], r["stock_used"], r["theatre"]), ("1500", "1500", "1", "1"))
        self.assertEqual((r["installed_def"], r["installed_grade"]), ("rp_ripperdoc.gorilla_arms", "street"))
        self.assertEqual((r["record_op_is_ours"], r["submits"], r["cw_commits"]), ("true", "1", "1"))
        # the fixer hears one operation, with the implant and the grade, keyed by the action
        self.assertEqual((r["job_events"], r["event_job"], r["event_kind"], r["event_player"]),
                         ("1", "ripperdoc", "operation", "1"))
        self.assertEqual((r["event_implant"], r["event_grade"], r["event_ref_is_action"]), ("arms", "street", "true"))
        self.assertEqual(r["legacy_events"], "1")
        # both players see a bar; both poses were requested at their anchors
        self.assertEqual((r["patient_bar"], r["patient_bar_done"]), ("Under the knife: Gorilla Arms (Street)", "true"))
        self.assertEqual((r["ripper_pose"], r["patient_pose"]), ("true", "true"))
        self.assertEqual((r["told_done_patient"], r["told_done_ripper"]), ("true", "true"))
        self.assertEqual((r["journal_rows"], r["station_idle"]), ("0", "false"))
        # the 1.x SQL history keeps its rows
        self.assertEqual((r["history_rows"], r["history_paid_via"], r["history_implant"]),
                         ("1", "cash", "rp_ripperdoc.gorilla_arms"))
        self.assertEqual(r["conserved"], "true", r["conservation"])
        self.assertEqual(r["unbalanced"], "nil")

    def test_decline_and_timeout(self):
        r = self.run_ok("decline_and_timeout")
        self.assertEqual((r["offered"], r["declined_told"], r["free_after_decline"], r["declined"]),
                         ("true", "true", "true", "1"))
        self.assertEqual((r["timeout_told"], r["free_after_timeout"]), ("true", "true"))
        self.assertEqual((r["cash_same"], r["stock_same"], r["submits"], r["journal_rows"]), ("true", "true", "0", "0"))
        self.assertEqual(r["unbalanced"], "nil")

    def test_cancellations_refund(self):
        r = self.run_ok("cancellations")
        self.assertEqual((r["x_state"], r["x_reason"], r["x_surgery"], r["x_hold"]),
                         ("cancelled", "cancelled_by_player", "cancelled", "cancelled"))
        self.assertEqual((r["x_told"], r["x_patient_bar_closed"]), ("true", "true"))
        self.assertEqual((r["px_state"], r["px_reason"], r["px_surgery"], r["px_told"]),
                         ("cancelled", "patient_stopped", "cancelled", "true"))
        self.assertEqual((r["off_state"], r["off_reason"], r["off_surgery"], r["off_told"]),
                         ("cancelled", "patient_left", "cancelled", "true"))
        self.assertEqual((r["cash_same"], r["stock"], r["submits"], r["arms"]), ("true", "3", "0", "nil"))
        self.assertEqual((r["journal_rows"], r["cancelled"], r["station_idle"]), ("0", "3", "false"))
        self.assertEqual(r["unbalanced"], "nil")

    def test_leaving_refunds(self):
        r = self.run_ok("leaving")
        self.assertEqual((r["walk_state"], r["walk_reason"], r["walk_told"]), ("cancelled", "patient_walked_away", "true"))
        self.assertEqual((r["dead_state"], r["dead_reason"]), ("cancelled", "patient_dead"))
        self.assertEqual((r["duty_state"], r["duty_reason"], r["duty_told"]), ("cancelled", "ripper_off_duty", "true"))
        self.assertEqual((r["op_duty_state"], r["op_duty_reason"], r["op_duty_surgery"]),
                         ("cancelled", "stale_job_epoch", "cancelled"))
        self.assertEqual((r["dc_state"], r["dc_surgery"], r["dc_told_ripper"]), ("cancelled", "cancelled", "true"))
        self.assertEqual((r["rdc_op_surgery"], r["rdc_op_reason"], r["rdc_op_told"]),
                         ("cancelled", "disconnected", "true"))
        self.assertEqual((r["rdc_state"], r["rdc_reason"]), ("cancelled", "ripper_gone"))
        self.assertEqual((r["cash_same"], r["stock"], r["submits"], r["journal_rows"]), ("true", "3", "0", "0"))
        self.assertEqual(r["unbalanced"], "nil")

    def test_refusals_reach_the_player(self):
        r = self.run_ok("refusals")
        for key in ("no_job", "off_duty", "outside", "too_far", "out_of_stock", "no_offer", "cannot_pay",
                    "nothing_held", "self", "idle", "not_on_chair", "expired_told", "slot_taken"):
            self.assertEqual(r[key], "true", key)
        self.assertEqual((r["expired_state"], r["expired_reason"]), ("cancelled", "quote_expired"))
        self.assertEqual(r["unbalanced"], "nil")

    def test_exactly_once(self):
        r = self.run_ok("exactly_once")
        self.assertIn(r["second_press"], ("actor_busy", "target_claimed"))
        self.assertEqual((r["paid"], r["society"], r["commits"]), ("1500", "1500", "1"))
        self.assertEqual((r["installs"], r["submits"], r["state"], r["again_how"]), ("1", "1", "done", "hold"))
        self.assertEqual((r["replay_ok"], r["cw_replays"], r["revision"]), ("true", "1", "1"))
        self.assertEqual((r["job_events"], r["stock"]), ("1", "1"))
        self.assertEqual(r["unbalanced"], "nil")

    def test_restarts_release_or_settle_once(self):
        r = self.run_ok("restarts")
        # (a) restart before the install: released, told, nothing submitted
        self.assertEqual((r["a_journal"], r["a_told"], r["a_cash_same"], r["a_submits"]), ("0", "true", "true", "0"))
        self.assertEqual(r["a_hold"], "cancelled")
        # (b) the implant landed, the completion was lost to a restart: settled once by transfer
        self.assertEqual((r["b_state_before"], r["b_installed"]), ("installing", "true"))
        self.assertEqual((r["b_paid"], r["b_society"], r["b_settles"], r["b_holds"]), ("1500", "1500", "1", "0"))
        self.assertEqual((r["b_journal"], r["b_events"], r["b_told"], r["b_stock"]), ("0", "1", "true", "3"))
        # (c) a full server restart after the install: settled once, never again on the next boot
        self.assertEqual((r["c_installed"], r["c_paid"], r["c_settles"], r["c_journal"]), ("true", "2700", "2", "0"))
        self.assertEqual((r["c_stock_legs"], r["c_paid_after_second_boot"]), ("3", "2700"))
        # (d) nothing landed: kept for the grace, then released and told
        self.assertEqual((r["d_state_before"], r["d_pending_early"], r["d_pending_late"]), ("installing", "true", "false"))
        self.assertEqual((r["d_installed"], r["d_paid"], r["d_journal"], r["d_told"]), ("false", "2700", "0", "true"))
        self.assertEqual(r["d_stock_ice"], "4")
        self.assertEqual(r["conserved"], "true", r["conservation"])
        self.assertEqual(r["unbalanced"], "nil")

    def test_install_failures_release(self):
        r = self.run_ok("install_failures")
        self.assertEqual((r["fail_op"], r["fail_reason"], r["fail_surgery"], r["fail_told"]),
                         ("failed", "native_projection_failed", "failed", "true"))
        self.assertEqual((r["hang_op"], r["hang_reason"], r["hang_surgery"], r["cancels"]),
                         ("failed", "install_timeout", "failed", "1"))
        self.assertEqual((r["cash_same"], r["stock"], r["arms"], r["journal_rows"]), ("true", "2", "nil", "0"))
        self.assertEqual(r["unbalanced"], "nil")

    def test_restock_at_the_dealer(self):
        r = self.run_ok("restock")
        self.assertEqual((r["op1"], r["stock1"], r["soc1"]), ("committed", "1", "900"))
        self.assertEqual(r["menu_rows"], "7")
        self.assertEqual((r["op2"], r["stock2"], r["cash2"], r["soc2"]), ("committed", "2", "3840", "1100"))
        self.assertEqual((r["op3"], r["op3_reason"]), ("failed", "declined"))
        self.assertEqual(r["far"], "true")
        self.assertEqual((r["events"], r["event_kind"], r["event_source"], r["event_item"], r["event_cost"]),
                         ("2", "restock", "supplier", "implant_box_arms", "900"))
        self.assertEqual(r["event_ref"], "true")
        self.assertEqual((r["minted"], r["burned"], r["told"]), ("1", "4740", "true"))
        self.assertEqual(r["unbalanced"], "nil")

    def test_restock_with_components(self):
        r = self.run_ok("restock_components")
        self.assertEqual((r["op"], r["stock"], r["components_left"], r["burned"], r["cash_same"]),
                         ("committed", "2", "0", "4", "true"))
        self.assertEqual((r["op2"], r["op2_reason"], r["told"]), ("failed", "no_components", "true"))
        self.assertEqual(r["unbalanced"], "nil")

    def test_restock_without_mint_rule(self):
        r = self.run_ok("restock_mint_denied")
        self.assertEqual((r["op"], r["reason"], r["stage"], r["told"]), ("failed", "mint_denied", "reserve", "true"))
        self.assertEqual((r["stock"], r["soc"]), ("0", "2000"))

    def test_buyback_from_a_player(self):
        r = self.run_ok("buyback")
        self.assertEqual((r["offered"], r["told_offer"]), ("true", "true"))
        self.assertEqual((r["stock"], r["pockets"], r["paid"], r["soc"]), ("2", "0", "1500", "1500"))
        self.assertEqual((r["events"], r["event_source"], r["event_count"]), ("1", "player", "2"))
        self.assertEqual((r["declined_legs"], r["declined_told"], r["short_told"]), ("1", "true", "true"))
        self.assertEqual(r["unbalanced"], "nil")

    def test_removal(self):
        r = self.run_ok("removal")
        self.assertEqual((r["installed_first"], r["told_quote"], r["op"]), ("true", "true", "committed"))
        self.assertEqual((r["fee"], r["society"], r["stock_same"], r["arms"]), ("1600", "1600", "true", "nil"))
        self.assertEqual((r["events"], r["last_action"], r["told_done"]), ("2", "remove", "true"))
        self.assertEqual(r["unbalanced"], "nil")

    def test_commands_and_console(self):
        r = self.run_ok("commands")
        self.assertGreaterEqual(int(r["board"]), 5)
        self.assertGreaterEqual(int(r["view"]), 6)
        for key in ("board_log", "implants", "stock", "operer_menu"):
            self.assertEqual(r[key], "true", key)
        self.assertEqual((r["cancel_state"], r["cancel_reason"]), ("cancelled", "withdrawn"))
        self.assertNotEqual(r["status_line"], "0")
        self.assertNotEqual(r["journal_line"], "0")
        self.assertEqual(r["unbalanced"], "nil")

    def test_seating_mode(self):
        r = self.run_ok("seating_mode")
        self.assertEqual((r["no_lie_action"], r["stood_for_quote"], r["seated_again"]), ("true", "true", "true"))
        self.assertEqual((r["op"], r["paid1"], r["arms"]), ("committed", "1500", "true"))
        self.assertEqual((r["op2"], r["op2_reason"], r["legs"], r["paid_total"]),
                         ("cancelled", "patient_left", "nil", "1500"))
        self.assertEqual(r["unbalanced"], "nil")


if __name__ == "__main__":
    unittest.main()
