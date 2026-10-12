"""W3-7 nomad smuggling run (rp_nomade): the whole job on the real world-interaction libraries,
offline.

Run with `python -m unittest discover -s tests -p "test_w3_nomad*.py"` (Lua 5.4: lupa, or a
lua54.dll such as the KeraLua NuGet cache's; see tests/compat/luahost.py).

Each scenario boots, on tests/compat/multihost.lua (through nomad_world.lua, built on the C1
salvage world): the FINAL open77_transactions resource (its server/main.lua, exports, policy and
work queue; the memory store plays the database), the real open77_actions and open77_containers
(the Open77 `resources/system` folder), the real rp_economy, rp_cargo and rp_nomade, and shims for
the public exports of rp_jobs, rp_garage (keys and police warrants), rp_inventory, rp_ncpd and the
player-interaction platform. Scenario code: tests/compat/nomad_scenarios.lua.

Sources outside this pack are READ in place, never copied or edited:
  OP77_SYS_DIR   the Open77 resources/system folder with open77_actions and open77_containers
  OP77_TX_FINAL  the final open77_transactions folder (default: SYS_DIR's copy)
A missing source skips the suite with the reason.

What this cannot show: anything in game (prompts, animations, the truck bed props, the GPS route,
the NCPD heat on a client), SQL semantics on MariaDB, the real rp_jobs / rp_garage / rp_ncpd /
rp_inventory behind their exports, the positions (every one is `measured = false`).
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
    for name in ("open77_actions", "open77_containers"):
        if not (sys_dir() / name / "open77.lua").is_file():
            return f"{name} not found under {sys_dir()} (set OP77_SYS_DIR)"
    if not (tx_dir() / "server" / "main.lua").is_file():
        return f"final open77_transactions not found at {tx_dir()} (set OP77_TX_FINAL)"
    return None


def scenario(name):
    return luahost.run_scenario("nomad_scenarios.lua", name, {
        "ROOT_DIR": ROOT.as_posix(), "COMPAT_DIR": COMPAT.as_posix(),
        "SYS_DIR": sys_dir().as_posix(), "TX_DIR": tx_dir().as_posix(),
    })


class NomadSources(unittest.TestCase):
    def test_every_library_reason_has_words(self):
        """A refusal or a stop from open77_actions reaches the player in words: every public reason
        token of the library is in M.TEXT or M.ENDS (the generic fallback never names a code)."""
        import re
        model = (sys_dir() / "open77_actions" / "shared" / "model.lua")
        if not model.is_file():
            self.skipTest(f"open77_actions not found under {sys_dir()} (set OP77_SYS_DIR)")
        def table(text, name):
            return re.search(name + r" = \{(.*?)\n\}", text, re.S).group(1)

        reasons = set(re.findall(r'"([a-z_]+)"', table(model.read_text(encoding="utf-8"), r"M\.REASONS")))
        internal = {"invalid_player", "invalid_options", "invalid_definition", "owner_unavailable", "not_owner",
                    "unknown_operation", "already_terminal", "commit_in_flight"}
        nomad = (ROOT / "rp_nomade" / "server" / "model.lua").read_text(encoding="utf-8")
        worded = set(re.findall(r"\b([a-z_]+) = \"", table(nomad, r"M\.TEXT") + table(nomad, r"M\.ENDS")))
        self.assertEqual(sorted(reasons - internal - worded), [])

    def test_sources_compile_without_bom(self):
        """Every rp_nomade Lua file: UTF-8 without BOM and loads as Lua 5.4 text."""
        if luahost.unavailable():
            self.skipTest(luahost.unavailable())
        lua = luahost.new_state()
        try:
            for path in sorted((ROOT / "rp_nomade").rglob("*.lua")):
                data = path.read_bytes()
                self.assertFalse(data.startswith(b"\xef\xbb\xbf"), f"{path} has a BOM")
                data.decode("utf-8")
                if path.name == "open77.lua":
                    continue
                lua.execute(f"assert(load({luahost.lua_string(data.decode('utf-8'))}, "
                            f"{luahost.lua_string('@' + path.name)}, 't'))", "=compile")
        finally:
            lua.close()

    def test_manifest_client_safe_and_least_privilege(self):
        text = (ROOT / "rp_nomade" / "open77.lua").read_text(encoding="utf-8")
        self.assertIn("auto_start false", text)
        self.assertIn('client_script "client/main.lua"', text)
        deps = [line.split('"')[1].split()[0] for line in text.splitlines() if line.startswith("dependency ")]
        # A client-delivered manifest may name only resources that ship a client half.
        for server_only in ("open77_transactions", "rp_cargo", "rp_economy"):
            self.assertNotIn(server_only, deps)
        perms = text.split("permissions {", 1)[1].split("}", 1)[0]
        for needed in ("network.events", "world.vehicles", "players.wanted", "players.interactions.control",
                       "ui.vanilla.map", "world.props"):   # world.props: the camp's set dressing
            self.assertIn(needed, perms)
        for unneeded in ("database.access", "players.animations.control"):
            self.assertNotIn(unneeded, perms)

    def test_prompt_labels_are_ascii_and_points_flagged(self):
        """Prompt labels in plain ASCII; every place in the config says whether it was walked
        (`measured = true` for the points walked in game, `false` for the estimates)."""
        text = (ROOT / "rp_nomade" / "server" / "config.lua").read_text(encoding="utf-8")
        self.assertTrue(all(ord(ch) < 128 for ch in text), "config.lua has a non-ASCII character")
        self.assertGreaterEqual(text.count("measured = false") + text.count("measured = true"), 12)
        self.assertEqual(text.count("measured = true"), 2)   # the Afterlife drop: bay and fence

    def test_readme_standard_format(self):
        text = (ROOT / "rp_nomade" / "README.md").read_text(encoding="utf-8")
        lines = text.splitlines()
        self.assertEqual(lines[0], "# rp_nomade")
        for head in ("- **Docs:**", "- **Starts:**", "- **Needs:**", "- **Runs on:**", "## How to play", "## Setup",
                     "## Config", "## Limits"):
            self.assertIn(head, text)
        self.assertNotIn("—", text)
        for word in ("proven", "experimental"):
            self.assertNotIn(word, text.lower())


@unittest.skipIf(missing_sources(), missing_sources())
class NomadRun(unittest.TestCase):
    def run_ok(self, name):
        r = scenario(name)
        self.assertEqual(r.get("errors"), "0", r.get("first_error"))
        return r

    def test_model_rules(self):
        r = self.run_ok("model_rules")
        self.assertEqual(r["live"], "600/480/120/false")
        self.assertEqual(r["hot"], "300/300/0/true")
        self.assertEqual(r["refused"], "nil/hot_refused")
        self.assertEqual(r["p1"], "400/320/80")
        self.assertEqual(r["p2"], "400/400/0")
        self.assertEqual(r["token_len_ok"], "true")
        self.assertEqual(r["bad_key"], "nil")
        self.assertEqual((r["in_cyl"], r["out_planar"], r["out_height"]), ("true", "false", "false"))
        self.assertEqual(r["lines"], "4")
        self.assertEqual(r["line1"], "g:4:world:a.1")
        self.assertEqual(r["line2"], "nmdc.run1.1:sys:nomad")
        self.assertEqual(r["text_unknown"], "That did not work. Try again in a moment.")   # never the raw code
        self.assertEqual(r["take_refusal"], "camp_empty/nomad_not_configured")

    def test_happy_path_end_to_end(self):
        """Supply, take the run, carry and load three crates, two checkpoints waved through, unload,
        hand each crate to the fence: pay minus the camp's cut, crates retired, goods conserved."""
        r = self.run_ok("happy_path")
        self.assertEqual(r["boot_lines"], "1/1/1")
        self.assertEqual(r["stash0"], "24")
        self.assertEqual(r["take"], "committed", r.get("take_reason"))
        self.assertEqual(r["crates"], "3")
        self.assertEqual(r["stash_taken"], "12")
        self.assertEqual(r["in_crates"], "12")
        self.assertEqual(r["tokens_home"], "3")
        self.assertEqual(r["placed"], "3")
        self.assertEqual((r["nav_taken"], r["nav_taken_route"]), ("destination", "false"))
        self.assertEqual(r["loads"], "committed,committed,committed")
        # The load prompt follows the parked truck behind its bed, and goes back to the bay after it.
        self.assertEqual((r["bay_with_truck"], r["bay_empty"]), ("1801.0,2233.6", "1800.0,2240.0"))
        self.assertEqual(r["in_bed"], "3")
        self.assertEqual(r["nav_loaded_route"], "true")
        self.assertEqual(r["passes"], "2")
        self.assertEqual(r["arrived"], "true")
        for k in ("u1", "s1", "u2", "s2", "u3", "s3"):
            self.assertEqual(r[k], "committed", k)
        self.assertEqual(r["paid1"], "480")
        self.assertEqual(r["paid_total"], "1440")
        self.assertEqual(r["society"], "360")
        self.assertEqual((r["closed"], r["retired"]), ("3", "3"))
        self.assertEqual(r["run_ended"], "delivered")
        self.assertEqual(r["fixer"], "pickup,checkpoint_passed,checkpoint_passed,deliver,deliver,deliver")
        self.assertEqual((r["deliver_job"], r["deliver_pay"]), ("nomad", "480"))
        self.assertTrue(r["pickup_ref"].startswith("nmd.run:"))
        self.assertEqual(r["pickup_player"], "1")
        self.assertTrue(r["passed_ref"].startswith("nmd.ck:"))
        self.assertEqual(r["nav_end"], "false")
        self.assertEqual(r["conserved"], "true", r["conservation"])
        self.assertEqual(r["unbalanced"], "nil")

    def test_checkpoint_search_confiscates_once(self):
        r = self.run_ok("checkpoint_search")
        self.assertEqual(r["evidence"], "12")
        self.assertEqual(r["left"], "0")
        self.assertEqual(r["in_bed"], "3")                 # emptied crates stay in the bed
        self.assertEqual(r["seize_ops"], "1")              # one operation for the whole truck
        self.assertEqual((r["fined"], r["ncpd"]), ("300", "300"))
        self.assertEqual(r["wanted"], "2")
        self.assertEqual(r["record"], "smuggling")
        self.assertEqual(r["told"], "true")
        self.assertEqual((r["conf_by"], r["conf_crates"], r["conf_ck"]), ("checkpoint", "3", "badlands_toll"))
        self.assertTrue(r["conf_ref"].startswith("nmd.seize:"))
        self.assertEqual(r["ended"], "confiscated")
        self.assertEqual(r["fixer"], "pickup,confiscated")  # the second checkpoint found nothing
        self.assertEqual(r["same"], "true")
        self.assertTrue(30 <= int(r["roll_share"]) <= 75, r["roll_share"])   # ~25 % of 200 runs
        self.assertEqual(r["dumps"], "committed,committed,committed")
        self.assertEqual(r["carrying"], "false")
        self.assertEqual(r["closed"], "3")
        self.assertEqual(r["told_dump"], "true")
        self.assertEqual(r["nav"], "false")
        self.assertEqual(r["conserved"], "true", r["conservation"])
        self.assertEqual(r["unbalanced"], "nil")

    def test_unpaid_fine_becomes_a_warrant(self):
        r = self.run_ok("unpaid_fine")
        self.assertEqual(r["evidence"], "12")
        self.assertEqual(r["cash_kept"], "true")
        self.assertEqual((r["warrant"], r["warrant_reason"]), ("1", "unpaid smuggling fine"))
        self.assertEqual(r["told"], "true")
        self.assertEqual(r["wanted"], "2")

    def test_officer_search_warrant_consent_decline(self):
        r = self.run_ok("officer_search")
        self.assertEqual(r["civ"], "true")
        self.assertEqual(r["s1"], "committed", r.get("s1_reason"))
        self.assertEqual(r["ev1"], "12")
        self.assertEqual((r["conf_by"], r["conf_officer"]), ("officer", "4"))
        self.assertEqual(r["run1"], "confiscated")
        self.assertEqual((r["record"], r["record_by"]), ("smuggling", "4"))
        self.assertEqual(r["asked"], "true")
        self.assertEqual(r["s2"], "committed")
        self.assertEqual(r["ev2"], "24")
        self.assertEqual(r["run2"], "confiscated")
        self.assertEqual(r["declined"], "true")
        self.assertEqual(r["searched3"], "false")
        self.assertEqual(r["kept"], "12")
        self.assertEqual(r["run3_live"], "true")
        self.assertEqual(r["no_consent"], "true")
        self.assertEqual(r["conserved"], "true", r["conservation"])
        self.assertEqual(r["unbalanced"], "nil")

    def test_player_sale_consented_once(self):
        r = self.run_ok("player_sale")
        self.assertEqual((r["offered"], r["declined"], r["after_decline"]), ("true", "true", "4"))
        self.assertEqual((r["broke"], r["after_broke"]), ("true", "4"))
        self.assertEqual(r["pockets"], "4")
        self.assertEqual((r["paid_seller"], r["paid_buyer"], r["camp"]), ("320", "400", "80"))
        self.assertEqual(r["crate_closed"], "true")
        self.assertEqual(r["token"], "sys:nomad")
        self.assertEqual((r["deliver_buyer"], r["deliver_pay"]), ("player", "320"))
        self.assertEqual(r["bad_price"], "true")
        self.assertEqual(r["items"], "0")
        self.assertEqual(r["conserved"], "true", r["conservation"])
        self.assertEqual(r["unbalanced"], "nil")

    def test_deadline_fails_the_run(self):
        r = self.run_ok("deadline")
        self.assertEqual((r["failed"], r["told"]), ("deadline", "true"))
        self.assertEqual((r["nav_phase"], r["nav_route"]), ("camp", "true"))
        self.assertEqual((r["unload"], r["sale"]), ("committed", "committed"))
        self.assertEqual((r["hot"], r["soc_delta"]), ("300", "0"))
        self.assertEqual(r["returns"], "committed,committed")
        self.assertEqual(r["stash_back"], "8")
        self.assertEqual(r["ended"], "deadline")
        self.assertEqual(r["again"], "committed")
        self.assertEqual(r["fixer"], "pickup,pickup")       # no delivery counted for hot goods
        self.assertEqual(r["closed"], "true")
        self.assertEqual(r["conserved"], "true", r["conservation"])
        self.assertEqual(r["unbalanced"], "nil")

    def test_theft_fails_the_run(self):
        r = self.run_ok("theft")
        self.assertEqual((r["lifted"], r["failed"], r["told_owner"]), ("true", "stolen", "true"))
        self.assertEqual((r["sale"], r["hot"]), ("committed", "300"))
        self.assertEqual(r["fixer"], "pickup")
        self.assertEqual(r["ret"], "committed")
        self.assertEqual(r["conserved"], "true", r["conservation"])

    def test_crew_only_pickup(self):
        r = self.run_ok("crew_only")
        self.assertEqual((r["thief_carries"], r["refused"], r["told"]), ("false", "not_crew", "true"))
        self.assertEqual((r["crew_lift"], r["failed"]), ("true", "nil"))

    def test_the_run_tally_survives_a_restart(self):
        r = self.run_ok("tally_survives_restart")
        self.assertEqual(r["ret"], "committed")
        self.assertEqual((r["returned_before"], r["where_before"]), ("1", "returned"))
        self.assertEqual((r["returned_after"], r["where_after"], r["replayed"]), ("1", "returned", "1"))

    def test_disconnect_and_restart_restore_everything(self):
        r = self.run_ok("restart")
        self.assertEqual(r["dropped_at"], "1795.0,2245.7")
        self.assertEqual(r["nav_back"], "destination")
        self.assertEqual(r["passes_before"], "1")
        self.assertEqual((r["run_back"], r["same_deadline"], r["same_owner"], r["passed_kept"]),
                         ("true", "true", "true", "true"))
        self.assertEqual(r["states"], "truck:NC-NMD01,ground,ground")
        self.assertEqual(r["at2"], "1795.0,2245.7")         # where it was dropped
        self.assertEqual(r["at3"], "1790.0,2258.5")         # carried at the crash: its last placement
        self.assertEqual(r["nav_after"], "destination")
        self.assertEqual(r["repassed"], "false")
        self.assertEqual((r["l2"], r["l3"]), ("committed", "committed"))
        self.assertEqual(r["sales"], "committed,committed,committed")
        self.assertEqual(r["paid"], "1440")
        self.assertEqual(r["ended"], "delivered")
        self.assertEqual(r["conserved"], "true", r["conservation"])
        self.assertEqual(r["unbalanced"], "nil")

    def test_truck_wrecked_or_impounded(self):
        r = self.run_ok("truck_lost")
        self.assertEqual((r["wrecked"], r["told_wreck"]), ("truck_destroyed", "true"))
        self.assertEqual(r["impounded"], "impounded")
        self.assertEqual(r["goods_kept"], "12")
        self.assertEqual(r["conserved"], "true", r["conservation"])

    def test_refusals(self):
        r = self.run_ok("refusals")
        self.assertEqual(r["no_job"], "no_job")
        self.assertEqual(r["off_duty"], "no_job,off_duty")
        self.assertEqual((r["empty"], r["empty_reason"]), ("failed", "camp_empty"))
        self.assertEqual((r["open_after_empty"], r["world_rows"]), ("0", "0"))
        self.assertEqual(r["told_empty"], "true")
        self.assertEqual(r["first"], "committed")
        self.assertEqual((r["second_started"], r["second_refused"], r["told_running"]), ("false", "run_running", "true"))
        self.assertEqual((r["no_truck"], r["carrying"]), ("no_truck", "true"))
        self.assertEqual((r["no_key"], r["carrying2"]), ("no_access", "true"))

    def test_exactly_once(self):
        r = self.run_ok("exactly_once")
        self.assertEqual((r["replay"], r["stash_same"]), ("true", "true"))
        self.assertEqual((r["s1"], r["paid1"]), ("committed", "480"))
        self.assertEqual((r["again"], r["paid_again"]), ("true", "0"))
        self.assertEqual((r["s2"], r["paid2"], r["pending"]), ("committed", "480", "true"))
        self.assertEqual(r["cash_after_restart"], "true")
        self.assertEqual((r["crate2_known"], r["crate2_row"], r["crate2_items"]), ("false", "false", "0"))
        self.assertEqual(r["unbalanced"], "nil")

    def test_library_restart_mid_run(self):
        r = self.run_ok("library_restart")
        self.assertEqual(r["after_containers"], "carried/ground/ground")
        self.assertEqual((r["items2"], r["items3"]), ("1", "1"))
        self.assertEqual(r["load1"], "committed")
        self.assertEqual(r["at2"], "1788.0,2258.0")          # back at its loading point
        self.assertEqual(r["items_after_actions"], "2")
        self.assertEqual((r["again"], r["load2"], r["state2"]), ("true", "committed", "truck"))

    def test_operator_console(self):
        r = self.run_ok("operator_console")
        self.assertEqual((r["take"], r["load"]), ("committed", "committed"))
        self.assertEqual(r["seized"], "4")
        self.assertEqual(r["fixer"], "pickup,confiscated")
        for key in ("status", "run_line", "stock", "setup"):
            self.assertEqual(r[key], "1", key)


if __name__ == "__main__":
    unittest.main()
