"""Netrunner contracts (rp_netrunner): post -> take -> timed breach -> trace or shard -> delivery, offline.

Run with `python -m unittest discover -s tests -p "test_netrunner*.py"` (Lua 5.4: lupa, or a lua54.dll
such as the KeraLua NuGet cache's; see tests/compat/luahost.py).

Each scenario boots, on tests/compat/netrunner_world.lua (itself on the street-food world and
multihost.lua): the real open77_transactions resource (its server/main.lua, exports, policy and work
queue; the memory store plays the database), the real open77_actions (Open77 resources/system), the
real rp_economy and rp_netrunner, shims for the public exports of rp_jobs, rp_inventory, rp_ncpd and
the open77_uikit server twins, and fakes for the platform natives (players, animations, player
interactions with consent, the NCPD heat, the hacking kit, the implant framework).
Scenario code: tests/compat/netrunner_scenarios.lua.

Sources outside this pack are READ in place, never copied or edited:
  OP77_SYS_DIR   the Open77 resources/system folder with open77_actions and open77_pedestrians
  OP77_TX_FINAL  the open77_transactions folder (default: SYS_DIR's copy)
A missing source skips the suite with the reason.

What this cannot show: anything in game (the poses at the terminals, prompt placement, the board
and the dialogs as drawn, the hand-over presentation, the native NCPD heat, timing on a live tick),
SQL semantics on MariaDB, the real rp_jobs / rp_inventory / rp_ncpd behind their exports.
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
RESOURCE = ROOT / "rp_netrunner"


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
        return f"open77_transactions not found at {tx_dir()} (set OP77_TX_FINAL)"
    return None


def scenario(name):
    return luahost.run_scenario("netrunner_scenarios.lua", name, {
        "ROOT_DIR": ROOT.as_posix(), "COMPAT_DIR": COMPAT.as_posix(),
        "SYS_DIR": sys_dir().as_posix(), "TX_DIR": tx_dir().as_posix(),
    })


def spot_rows(path, rows):
    """{row: (x, y, z, yaw, profile)} from open77_pedestrians' spots-generated.lua (column tables)."""
    text = path.read_text(encoding="utf-8")
    profiles = re.findall(r'"([^"]+)"', re.search(r"\n    profiles = \{([^}]*)\}", text).group(1))

    def column(name):
        body = re.search(r"\n    " + name + r" = \{([^}]*)\}", text).group(1)
        return [float(v) for v in re.findall(r"-?\d+(?:\.\d+)?(?:e-?\d+)?", body)]

    x, y, z, yaw, prof = (column(n) for n in ("spotX", "spotY", "spotZ", "spotYaw", "spotProfile"))
    return {r: (x[r - 1], y[r - 1], z[r - 1], yaw[r - 1], profiles[int(prof[r - 1]) - 1]) for r in rows}


# The terminals a breach ran on in game (the W3-4 passes): every other point is `measured = false`.
WALKED_SITES = ("watson_junction", "corp_lobby", "club_office")


def config_sites():
    """{key: (x, y, z, yaw, pose, measured)} from rp_netrunner/server/config.lua."""
    text = (RESOURCE / "server" / "config.lua").read_text(encoding="utf-8")
    text = text[text.index("C.sites = {"):text.index("C.maxDistance")]
    out = {}
    for block in re.findall(r"\{\s*\n\s*key = \"[a-z_]+\".*?\n    \},", text, re.S):
        key = re.search(r'key = "([a-z_]+)"', block).group(1)
        pos = re.search(r"position = \{ x = (-?[\d.]+), y = (-?[\d.]+), z = (-?[\d.]+) \}, yaw = (-?[\d.]+), "
                        r"measured = (true|false)", block)
        pose = re.search(r'pose = "([a-z]+)"', block)
        out[key] = (float(pos.group(1)), float(pos.group(2)), float(pos.group(3)), float(pos.group(4)),
                    pose.group(1) if pose else None, pos.group(5) == "true")
    return out


class NetrunnerSources(unittest.TestCase):
    def test_sources_compile_without_bom(self):
        """Every rp_netrunner Lua file: UTF-8 without BOM (a BOM kills a resource silently) and loads
        as Lua 5.4 text."""
        if luahost.unavailable():
            self.skipTest(luahost.unavailable())
        lua = luahost.new_state()
        try:
            for path in sorted(RESOURCE.rglob("*.lua")):
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

    def test_manifest_is_opt_in_and_least_privilege(self):
        text = (RESOURCE / "open77.lua").read_text(encoding="utf-8")
        code = "\n".join(line for line in text.splitlines() if not line.lstrip().startswith("--"))
        self.assertIn("auto_start false", code)
        block = re.search(r"permissions\s*\{([^}]*)\}", code).group(1)
        self.assertEqual(sorted(re.findall(r'"([^"]+)"', block)), sorted([
            "network.events", "players.hacking.define", "players.hacking.read", "players.hacking.activate",
            "players.cyberware.define", "players.cyberware.read", "players.cyberware.manage", "players.life.read",
            "players.interactions.control", "players.interactions.read", "players.wanted", "players.wanted.read",
            "ui.vanilla.map"]))
        for absent in ("database.access", "world.props", "players.animations.control"):
            self.assertNotIn(absent, block)
        # A manifest with a client script may only depend on resources that ship a client half.
        deps = re.findall(r'dependency\s+"([a-z0-9_]+)', code)
        for server_only in ("open77_transactions", "open77_actions", "rp_jobs", "rp_inventory", "rp_economy", "rp_ncpd"):
            self.assertNotIn(server_only, deps)
        self.assertIn("client_script", code)

    def test_sites_come_from_the_catalogue(self):
        """The breach terminals are vanilla AI spots: office workers typing at a desk keyboard
        (sit_chair_table_keyboard, the furniture catalogue's desks), a tablet spot beside two netrunner
        chairs, a kneeling tablet spot over the Afterlife. Not invented."""
        spots = sys_dir() / "open77_pedestrians" / "server" / "spots-generated.lua"
        if not spots.is_file():
            self.skipTest(f"no spots catalogue at {spots}")
        expected = {"watson_junction": (3217, "amb_f8fa00_kneel_ground_tablet", "laptop"),
                    "den_node": (2869, "amb_148b83_stand_ground_tablet", "tablet"),
                    "corp_lobby": (8594, "amb_d7c499_sit_chair_table_keybo", "desk"),
                    "club_office": (25016, "amb_d7c499_sit_chair_table_keybo", "desk"),
                    "plaza_desk": (8727, "amb_d7c499_sit_chair_table_keybo", "desk"),
                    "office_workstation": (31673, "amb_d7c499_sit_chair_table_keybo", "desk")}
        rows = spot_rows(spots, [row for row, _, _ in expected.values()])
        sites = config_sites()
        self.assertEqual(sorted(sites), sorted(expected))
        for key, (row, profile, pose) in expected.items():
            x, y, z, yaw, prof = rows[row]
            got = sites[key]
            self.assertEqual(prof, profile, key)
            self.assertAlmostEqual(got[0], x, places=3)
            self.assertAlmostEqual(got[1], y, places=3)
            self.assertAlmostEqual(got[2], z, places=3)
            self.assertAlmostEqual(got[3], yaw, places=2)
            self.assertEqual(got[4], pose, key)
            self.assertEqual(got[5], key in WALKED_SITES, f"{key}: measured only once a breach ran there in game")

    def test_only_walked_terminals_are_measured(self):
        text = (RESOURCE / "server" / "config.lua").read_text(encoding="utf-8")
        code = "\n".join(line for line in text.splitlines() if not line.lstrip().startswith("--"))
        self.assertEqual(code.count("measured = true"), len(WALKED_SITES))
        self.assertEqual(code.count("measured = false"), 7 - len(WALKED_SITES))   # six sites, one fixer drop
        readme = (RESOURCE / "README.md").read_text(encoding="utf-8")
        for key in WALKED_SITES:
            self.assertRegex(readme, r"\| `" + key + r"` \|[^\n]*\| walked \|", key)

    def test_prompt_labels_are_plain_ascii(self):
        for path in (RESOURCE / "server" / "config.lua", RESOURCE / "server" / "service.lua",
                     RESOURCE / "server" / "model.lua", RESOURCE / "shared" / "config.lua"):
            text = path.read_text(encoding="utf-8")
            self.assertTrue(all(ord(ch) < 128 for ch in text), f"{path.name} has a non-ASCII character")

    def test_rp_jobs_knows_netrunner_and_fixer(self):
        text = (ROOT / "rp_jobs" / "shared" / "config.lua").read_text(encoding="utf-8")
        self.assertRegex(text, r'\{ name = "netrunner",')
        self.assertRegex(text, r'\{ name = "fixer",')

    def test_readme_format(self):
        text = (RESOURCE / "README.md").read_text(encoding="utf-8")
        lines = text.splitlines()
        self.assertEqual(lines[0], "# rp_netrunner")
        for bullet in ("- **Docs:** ", "- **Starts:** ", "- **Needs:** ", "- **Runs on:** "):
            self.assertTrue(any(line.startswith(bullet) for line in lines[:12]), bullet)
        for heading in ("## How to play", "## Setup", "## Config", "## Limits"):
            self.assertIn(heading, lines)
        self.assertNotIn("—", text)
        self.assertIsNone(re.search(r"\b\d{4}-\d{2}-\d{2}\b", text), "no dates")
        for word in ("proven", "lab", "experimental"):
            self.assertIsNone(re.search(r"\b" + word + r"\b", text, re.I), word)
        self.assertIn("tunable.set open77_transactions writers", text)
        self.assertIn("tunable.set open77_transactions mint", text)


@unittest.skipIf(missing_sources(), missing_sources())
class NetrunnerLoop(unittest.TestCase):
    def run_ok(self, name):
        r = scenario(name)
        self.assertEqual(r.get("errors"), "0", r.get("first_error"))
        return r

    def test_happy_path_board_breach_delivery(self):
        r = self.run_ok("happy_path")
        self.assertEqual((r["posted"], r["code_len"], r["cut"], r["net"]), ("true", "4", "75", "425"))
        self.assertEqual((r["talk"], r["board_shown"], r["taken_state"], r["taken_by"]), ("committed", "true", "taken", "acct-a"))
        # ONE breach operation: one chip burned, the contract patched, the shard minted into the pockets
        self.assertEqual((r["breach"], r["chips_used"], r["shard_at"]), ("committed", "1", "char:acct-a"))
        self.assertEqual((r["breached_state"], r["breached_shard"]), ("breached", "true"))
        self.assertEqual(r["observer_sees"], "true")      # the laptop pose at the junction, server-driven
        # ONE delivery sale: the shard burned, 425 to the runner, the 75 cut to the fixer society
        self.assertEqual((r["deliver"], r["paid"], r["society"]), ("committed", "425", "75"))
        self.assertEqual((r["shard_after"], r["board_after"], r["active_after"]), ("sys:rp_netrunner:client", "0", "nil"))
        self.assertEqual((r["success_events"], r["deliver_events"], r["deliver_job"], r["deliver_net"]), ("1", "1", "netrunner", "425"))
        self.assertEqual((r["success_ref"], r["deliver_ref"]), ("true", "true"))
        self.assertEqual(r["phases"], "posted,taken,breached,delivered")
        self.assertEqual((r["told_breach"], r["told_paid"]), ("true", "true"))
        self.assertEqual(r["grants"], "1")                # strict writers: rp_inventory granted the pockets
        self.assertEqual(r["conserved"], "true", r["conservation"])
        self.assertEqual(r["unbalanced"], "nil")

    def test_failure_is_a_trace_and_the_contract_fails_after_three(self):
        r = self.run_ok("failure_trace")
        self.assertEqual((r["b1"], r["chips_left"], r["shard"]), ("committed", "3", "nil"))
        self.assertEqual((r["state1"], r["attempts1"], r["traces1"], r["taker1"]), ("taken", "1", "1", "acct-a"))
        self.assertEqual((r["alert_kind"], r["alert_at_site"], r["alert_anonymous"]), ("netrunner", "true", "true"))
        self.assertIn("Junction box above the Afterlife", r["alert_text"])
        self.assertEqual((r["record_kind"], r["record_pid"]), ("netrunner", "1"))
        self.assertEqual((r["wanted1"], r["wanted_cooled"]), ("1", "0"))
        self.assertEqual((r["traced_site"], r["traced_level"]), ("watson_junction", "1"))
        self.assertEqual((r["failed_events"], r["failed_kind"], r["failed_success"], r["failed_traced"]),
                         ("1", "breach_failed", "false", "true"))
        self.assertEqual((r["retry_op"], r["alert_refused"], r["chips_after_refusal"]), ("nil", "true", "3"))
        self.assertEqual((r["b2"], r["attempts2"], r["b3"]), ("committed", "2", "committed"))
        self.assertEqual((r["contract_gone"], r["contract_where"], r["active_after"]), ("true", "sys:netrunner", "nil"))
        self.assertEqual((r["failed_phase"], r["attempt_phases"]), ("1", "2"))
        self.assertEqual((r["cash_same"], r["chips_end"]), ("true", "1"))
        self.assertEqual((r["told_traced"], r["told_failed"]), ("true", "true"))
        self.assertEqual(r["conserved"], "true", r["conservation"])
        self.assertEqual(r["unbalanced"], "nil")

    def test_failure_reopen_mode(self):
        r = self.run_ok("failure_reopen")
        self.assertEqual((r["b"], r["state"], r["taker"], r["attempts"], r["traces"], r["a_holds"]),
                         ("committed", "open", "false", "1", "1", "nil"))
        self.assertEqual((r["d_took"], r["d_state"]), ("acct-d", "taken"))

    def test_cancellations_use_nothing(self):
        r = self.run_ok("cancellations")
        self.assertEqual((r["x"], r["x_reason"], r["x_chips"], r["x_state"], r["x_attempts"], r["x_told"]),
                         ("cancelled", "cancelled_by_player", "3", "taken", "0", "true"))
        self.assertEqual(r["walked"], "cancelled")
        self.assertIn(r["walked_reason"], ("too_far", "moved", "animation_interrupted"))
        self.assertEqual((r["gone"], r["gone_reason"], r["holds_after_reconnect"]), ("cancelled", "disconnected", "true"))
        self.assertEqual((r["clocked"], r["clocked_reason"]), ("cancelled", "stale_job_epoch"))
        self.assertEqual((r["chips_before_full"], r["attempts_before_full"], r["b"], r["chips_used"]), ("3", "0", "committed", "1"))
        self.assertEqual((r["dx"], r["dx_reason"], r["kept_shard"], r["cash_after_x_same"]),
                         ("cancelled", "cancelled_by_player", "char:acct-a", "true"))
        self.assertEqual((r["d"], r["paid"], r["deliver_events"], r["no_trace"]), ("committed", "510", "1", "true"))
        self.assertEqual(r["conserved"], "true", r["conservation"])
        self.assertEqual(r["unbalanced"], "nil")

    def test_refusals_hold_nothing(self):
        r = self.run_ok("refusals")
        for key in ("no_contract", "citizen", "taken", "second", "told_kit", "wrong_site", "early"):
            self.assertEqual(r[key], "true", key)
        self.assertEqual((r["winners"], r["winner_state"]), ("1", "taken"))
        self.assertEqual((r["no_kit"], r["no_kit_reason"], r["no_kit_attempts"], r["no_shard"]),
                         ("failed", "no_breach_kit", "0", "nil"))
        self.assertEqual((r["forged_validate"], r["forged_commit"], r["forged_reserve"]),
                         ("false:not_owner", "nil:not_owner", "nil:not_owner"))
        self.assertEqual((r["unknown_site"], r["not_fixer"], r["bad_reward"], r["bad_deadline"], r["busy"]),
                         ("unknown_site", "not_fixer", "invalid_reward", "invalid_deadline", "site_busy"))
        self.assertEqual(r["conserved"], "true", r["conservation"])
        self.assertEqual(r["unbalanced"], "nil")

    def test_player_fixer_posts_and_receives_with_consent(self):
        r = self.run_ok("player_fixer")
        self.assertEqual((r["talk"], r["poster"], r["fixer"], r["reward"], r["cut"], r["minutes"]),
                         ("committed", "player", "acct-b", "1200", "180", "45"))
        self.assertEqual((r["told_fixer_taken"], r["b"], r["desk_pose"]), ("true", "committed", "true"))
        self.assertEqual((r["in_person"], r["no_deliver_op"]), ("true", "true"))
        self.assertEqual((r["offer1"], r["told_fixer_offer"], r["declined_shard"], r["declined_cash"], r["declined_told"]),
                         ("true", "true", "char:acct-a", "true", "true"))
        self.assertEqual((r["offer2"], r["runner_paid"], r["fixer_cut"]), ("true", "1020", "180"))
        self.assertEqual((r["shard_after"], r["contract_after"]), ("sys:rp_netrunner:client", "sys:netrunner"))
        self.assertEqual((r["deliver_via"], r["deliver_poster"], r["told_fixer_paid"]), ("handover", "player", "true"))
        self.assertEqual(r["conserved"], "true", r["conservation"])
        self.assertEqual(r["unbalanced"], "nil")

    def test_drop_pays_an_absent_fixer(self):
        r = self.run_ok("fixer_away")
        self.assertEqual((r["d"], r["runner_paid"], r["fixer_cut"], r["net"], r["cut"]), ("committed", "510", "90", "510", "90"))
        self.assertEqual(r["shard_after"], "sys:rp_netrunner:client")
        self.assertEqual(r["unbalanced"], "nil")

    def test_restart_with_a_shard_in_pockets_and_the_sale_crash_window(self):
        r = self.run_ok("restart_with_shard")
        self.assertEqual((r["b"], r["rebuilt_state"], r["rebuilt_taker"], r["shard_kept"]),
                         ("committed", "breached", "acct-a", "char:acct-a"))
        self.assertEqual((r["d"], r["paid"], r["again"], r["paid_again"]), ("committed", "425", "true", "0"))
        self.assertEqual((r["d2"], r["crash_paid"], r["still_on_board"]), ("committed", "340", "true"))
        self.assertEqual((r["recovered"], r["after_restart_paid"], r["recovered_events"]), ("true", "0", "1"))
        self.assertEqual(r["conserved"], "true", r["conservation"])
        self.assertEqual(r["unbalanced"], "nil")

    def test_exactly_once_through_doubts_and_crashes(self):
        r = self.run_ok("exactly_once")
        self.assertEqual((r["lost"], r["lost_state"], r["successes1"]), ("committed", "breached", "1"))
        # the sale reported in doubt while it landed: retried with the same id, finished by the sweep
        self.assertEqual((r["paid"], r["deliveries"]), ("425", "1"))
        self.assertGreaterEqual(int(r["sale_calls"]), 1)
        # the coordinator died with the breach commit queued: detached -> it landed once
        self.assertEqual((r["meta3"], r["chips3"], r["shard3"]), ("breached", "1", "char:acct-a"))
        # discarded -> nothing landed: no chip, no shard, no attempt
        self.assertEqual((r["meta4"], r["attempts4"], r["chips4"], r["shard4"]), ("taken", "0", "0", "nil"))
        self.assertEqual((r["replay"], r["shards_same"]), ("true", "true"))
        self.assertEqual(r["conserved"], "true", r["conservation"])
        self.assertEqual(r["unbalanced"], "nil")

    def test_expiry_retires_contracts_and_stale_shards(self):
        r = self.run_ok("expiry")
        self.assertEqual((r["open_expired"], r["b"], r["shard_before"]), ("sys:netrunner", "committed", "char:acct-a"))
        self.assertEqual((r["contract_after"], r["shard_after"], r["active_after"]), ("sys:netrunner", "sys:netrunner", "nil"))
        self.assertEqual((r["expired_events"], r["told"]), ("2", "true"))
        self.assertEqual(r["unbalanced"], "nil")

    def test_npc_board_keeps_its_contracts_up(self):
        r = self.run_ok("npc_board")
        self.assertEqual((r["open"], r["distinct"], r["rewards_ok"], r["codes"]), ("3", "true", "true", "3"))
        self.assertEqual((r["after_restart"], r["board"]), ("3", "3"))

    def test_exports_for_the_fixer_board(self):
        r = self.run_ok("exports")
        self.assertEqual((r["s1"], r["s1_fixer_name"], r["s1_cut"], r["s1_net"]), ("player", "Fixer", "150", "850"))
        self.assertEqual((r["s2_default"], r["s3"], r["too_many"]), ("1100", "true", "too_many_posted"))
        self.assertEqual((r["list_ok"], r["list_n"], r["one_reward"], r["sites_n"], r["sites_busy"]),
                         ("true", "4", "1000", "6", "4"))
        self.assertIn("NCPD HQ", r["one_area"])
        self.assertEqual((r["none"], r["mine"], r["open_n"]), ("nil", "true", "3"))
        self.assertEqual((r["cancel_other"], r["cancel_taken"], r["cancel_own"], r["cancelled_gone"]),
                         ("nil:not_your_contract", "nil:contract_not_open", "true", "true"))
        self.assertEqual(r["cancelled_by"], "Fixer")
        self.assertEqual((r["posted_events"], r["taken_events"], r["cancelled_events"]), ("4", "1", "1"))

    def test_quickhacks_burn_through_the_coordinator(self):
        r = self.run_ok("quickhacks")
        self.assertEqual((r["no_item"], r["pinged"], r["pings_left"], r["burned_pings"]), ("true", "true", "1", "1"))
        self.assertEqual((r["cooling"], r["pings_after_cooldown"], r["gesture"]), ("true", "1", "true"))
        self.assertEqual((r["loading"], r["sc_after_load"], r["starts"], r["sc_after_upload"]), ("true", "2", "1", "1"))
        self.assertEqual((r["refused_told"], r["sc_after_refusal"]), ("true", "1"))
        self.assertEqual((r["jam_on"], r["static_sent"], r["jam_off"], r["jammer_left"]), ("true", "true", "false", "0"))
        self.assertEqual(r["unbalanced"], "nil")

    def test_console_drives_the_loop(self):
        r = self.run_ok("console")
        for key in ("posted", "delivered", "expired"):
            self.assertEqual(r[key], "true", key)
        self.assertEqual(r["b"], "committed")
        for key in ("state_line", "chance_line", "status_line", "take_line", "expire_line"):
            self.assertGreaterEqual(int(r[key]), 1, key)
        self.assertGreaterEqual(int(r["post_line"]), 1)

    def test_handover_withdrawn_on_clock_off(self):
        r = self.run_ok("handover_epoch")
        self.assertEqual((r["offered"], r["withdrawn"], r["reason"]), ("true", "true", "stale_job_epoch"))
        # Both players read why in words, never the platform's token.
        self.assertEqual((r["told_runner"], r["told_fixer"], r["raw_shown"]), ("true", "true", "false"))
        self.assertEqual((r["shard"], r["cash_a_same"], r["cash_b_same"], r["still_breached"]),
                         ("char:acct-a", "true", "true", "breached"))
        self.assertEqual(r["unbalanced"], "nil")

    def test_library_restarts(self):
        r = self.run_ok("library_restarts")
        self.assertEqual((r["redeclared"], r["defined_again"], r["board_kept"]), ("1", "true", "taken"))
        self.assertEqual((r["b"], r["shard"]), ("committed", "char:acct-a"))
        self.assertEqual(r["unbalanced"], "nil")

    def test_model_rules(self):
        r = self.run_ok("model")
        self.assertEqual((r["roll_deterministic"], r["roll_range"]), ("true", "true"))
        self.assertEqual((r["chance_base"], r["chance_grade3"], r["chance_retry2"], r["chance_floor"], r["chance_cap"]),
                         ("40", "64", "30", "10", "95"))
        self.assertEqual((r["code_len"], r["code_differs"]), ("4", "true"))
        self.assertEqual((r["reward_default"], r["reward_low"], r["reward_ok"], r["minutes_bad"], r["npc_reward_ok"]),
                         ("2200", "invalid_reward", "2000", "invalid_deadline", "true"))
        self.assertEqual((r["cut"], r["cut_zero"]), ("150", "0"))
        self.assertEqual((r["fail_retry"], r["fail_last"], r["fail_reopen"]), ("retry", "fail", "reopen"))
        self.assertEqual((r["sale_total"], r["sale_payees"], r["sale_net"], r["sale_cut_society"], r["sale_seller"],
                          r["sale_buyer"], r["sale_item"], r["sale_from"]),
                         ("1000", "2", "850", "fixer", "7", "client", "nrs.x", "char:s1"))
        self.assertEqual((r["valid_record"], r["invalid_record"]), ("true", "false"))
        self.assertEqual(r["text_unknown"], "That did not work. Try again in a moment.")   # never the raw code


if __name__ == "__main__":
    unittest.main()
