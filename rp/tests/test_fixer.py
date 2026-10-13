"""rp_fixer 2.0, the fixers' contract board: post -> escrow -> take -> work -> pay, offline.

Run with `python -m unittest discover -s tests -p "test_fixer*.py"` from the rp/ folder (Lua 5.4:
lupa, or a lua54.dll such as the KeraLua NuGet cache's; see tests/compat/luahost.py).

Each scenario boots, on tests/compat/fixer_world.lua (itself on streetfood_world.lua and
multihost.lua): the real open77_transactions (its memory store plays the database), the real
open77_actions (Open77 resources/system), the real rp_economy and rp_fixer, shims for the public
exports of rp_jobs, rp_inventory and the open77_uikit server twins (the scenario answers for the
player), and fakes for server NPCs and rp_fixer's SQL tables. Scenario code:
tests/compat/fixer_scenarios.lua.

Sources outside this pack are READ in place, never copied or edited:
  OP77_SYS_DIR   the Open77 resources/system folder (open77_actions, open77_transactions,
                 open77_pedestrians for the anchor check; default: this repository's system/ folder)
  OP77_TX_FINAL  the final open77_transactions folder (default: SYS_DIR's copy)

What this cannot show: anything in game (prompts, the UI kit rendering, the crate in the hands,
the cyberpsycho's AI, the platform's hit pricing and its onNpcDied payload on a real kill, map pins),
MariaDB semantics (the SQL here is an interpreter of the exact statements rp_fixer sends), and the
other jobs' real `rp:job:completed` payloads.
"""
import math
import os
import re
import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent / "compat"))
import luahost  # noqa: E402

ROOT = Path(__file__).resolve().parents[1]
COMPAT = ROOT / "tests" / "compat"
FIXER = ROOT / "rp_fixer"


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
    return luahost.run_scenario("fixer_scenarios.lua", name, {
        "ROOT_DIR": ROOT.as_posix(), "COMPAT_DIR": COMPAT.as_posix(),
        "SYS_DIR": sys_dir().as_posix(), "TX_DIR": tx_dir().as_posix(),
    })


def spot_rows(path, rows):
    """{row: (x, y, z, yaw)} from open77_pedestrians' spots-generated.lua (column tables)."""
    text = path.read_text(encoding="utf-8")

    def column(name):
        body = re.search(r"\n    " + name + r" = \{([^}]*)\}", text).group(1)
        return [float(v) for v in re.findall(r"-?\d+(?:\.\d+)?(?:e-?\d+)?", body)]

    x, y, z, yaw = (column(n) for n in ("spotX", "spotY", "spotZ", "spotYaw"))
    return {r: (x[r - 1], y[r - 1], z[r - 1], yaw[r - 1]) for r in rows}


def in_front(spot, metres=1.5):
    """Where a customer stands: `metres` in front of a vendor spot (yaw 0 faces +y, counter-clockwise)."""
    x, y, z, yaw = spot
    a = math.radians(yaw)
    return x - math.sin(a) * metres, y + math.cos(a) * metres, z


class FixerSources(unittest.TestCase):
    def test_sources_compile_without_bom(self):
        """Every rp_fixer Lua file: UTF-8 without BOM (a BOM kills a resource silently) and loads as
        Lua 5.4 text."""
        if luahost.unavailable():
            self.skipTest(luahost.unavailable())
        lua = luahost.new_state()
        try:
            for path in sorted(FIXER.rglob("*.lua")):
                data = path.read_bytes()
                self.assertFalse(data.startswith(b"\xef\xbb\xbf"), f"{path} has a BOM")
                data.decode("utf-8")
                if path.name == "open77.lua":
                    continue
                lua.execute(f"assert(load({luahost.lua_string(data.decode('utf-8'))}, "
                            f"{luahost.lua_string('@' + path.name)}, 't'))", "=compile")
        finally:
            lua.close()

    def test_manifest_is_opt_in_and_least_privilege(self):
        text = (FIXER / "open77.lua").read_text(encoding="utf-8")
        code = "\n".join(line for line in text.splitlines() if not line.lstrip().startswith("--"))
        self.assertIn("auto_start false", code)
        block = re.search(r"permissions\s*\{([^}]*)\}", code).group(1)
        self.assertEqual(sorted(re.findall(r'"([^"]+)"', block)),
                         sorted(["database.access", "world.npcs", "network.events", "ui.vanilla.map"]))
        deps = re.findall(r'dependency\s+"([^"\s]+)', code)
        self.assertEqual(sorted(deps), ["open77_actions", "open77_uikit"])   # both ship a client half
        self.assertIn('client_script "client/main.lua"', code)
        for server_only in ("open77_transactions", "rp_economy", "rp_jobs", "rp_inventory"):
            self.assertNotIn(f'dependency "{server_only}', code)

    def test_client_sends_nothing(self):
        """The client only draws map pins: it never asks the server for anything."""
        client = (FIXER / "client" / "main.lua").read_text(encoding="utf-8")
        self.assertNotIn("TriggerServerEvent", client)
        self.assertNotIn("Open77.exports.call", client)

    def test_readme_standard_format(self):
        text = (FIXER / "README.md").read_text(encoding="utf-8")
        self.assertTrue(text.startswith("# rp_fixer\n"))
        for line in ("- **Docs:**", "- **Starts:**", "- **Needs:**", "- **Runs on:**",
                     "## How to play", "## Setup", "## Config", "## Limits"):
            self.assertIn(line, text)
        self.assertNotIn("—", text)                      # no em dash
        for word in ("proven", "experimental"):
            self.assertNotRegex(text.lower(), rf"\b{word}\b")
        self.assertNotRegex(text, r"\blab\b")
        self.assertNotRegex(text, r"\b20\d\d-\d\d-\d\d\b")     # no dates
        self.assertIn("tunable.set open77_transactions writers", text)
        self.assertIn("tunable.set open77_transactions mint", text)

    def test_rp_jobs_knows_the_fixer_job(self):
        text = (ROOT / "rp_jobs" / "shared" / "config.lua").read_text(encoding="utf-8")
        self.assertRegex(text, r'\{ name = "fixer",\s+label = "Fixer"')

    def test_catalogue_anchors(self):
        """Wakako's and Regina's boards and the Japantown pickup stand 1.5 m in front of vanilla
        vendor spots of the pedestrian catalogue; two sightings are catalogue spots themselves."""
        spots = sys_dir() / "open77_pedestrians" / "server" / "spots-generated.lua"
        if not spots.is_file():
            self.skipTest(f"no spots catalogue at {spots}")
        rows = spot_rows(spots, [15042, 29556, 37085, 15215, 8055])
        config = (FIXER / "server" / "config.lua").read_text(encoding="utf-8")

        def configured(key):
            m = re.search(key + r" = \{[^\n]*?position = \{ x = (-?[\d.]+), y = (-?[\d.]+), z = (-?[\d.]+) \}", config,
                          re.S)
            if not m:
                m = re.search(r"\n    " + key + r" = \{.*?position = \{ x = (-?[\d.]+), y = (-?[\d.]+), z = (-?[\d.]+) \}",
                              config, re.S)
            return tuple(float(v) for v in m.groups())

        for key, row, front in (("wakako", 15042, True), ("regina", 29556, True), ("japantown_ripperdoc", 37085, True),
                                ("northside", 8055, False)):
            want = in_front(rows[row]) if front else rows[row][:3]
            got = configured(key)
            for axis in range(3):
                self.assertAlmostEqual(got[axis], want[axis], delta=0.02, msg=f"{key} axis {axis}")

    def test_retrievals_ask_for_the_items_their_jobs_define(self):
        """A retrieval of another job's item names that job's own item id: Regina's CHOOH2 is
        rp_chooh2's refinery canister, Rogue's box is rp_ripperdoc's."""
        config = (FIXER / "server" / "config.lua").read_text(encoding="utf-8")

        def item_of(template):
            return re.search(r"\n    " + template + r" = \{.*?item = \"([a-z0-9_]+)\"", config, re.S).group(1)

        self.assertEqual(item_of("regina_chooh2"), "chooh2_canister")
        chooh2 = (ROOT / "rp_chooh2" / "server" / "config.lua").read_text(encoding="utf-8")
        self.assertRegex(chooh2, r"\n    chooh2_canister = \{ label = ")
        self.assertEqual(item_of("afterlife_box"), "implant_box_arms")
        ripper = (ROOT / "rp_ripperdoc" / "shared" / "config.lua").read_text(encoding="utf-8")
        self.assertIn("implant_box_arms", ripper)

    def test_measured_false_points_are_listed_in_readme(self):
        text = (FIXER / "README.md").read_text(encoding="utf-8")
        for name in ("afterlife", "wakako", "regina", "kabuki_noodle_row", "vik_clinic", "japantown_ripperdoc",
                     "kabuki_alley", "northside", "junkyard"):
            self.assertIn(f"`{name}`", text, name)


@unittest.skipIf(luahost.unavailable(), luahost.unavailable())
class FixerRules(unittest.TestCase):
    def test_model_and_shipped_data(self):
        r = scenario("model")
        self.assertEqual(r.get("errors"), "0", r.get("first_error"))
        self.assertEqual((r["bad_templates"], r["bad_offers"], r["unmarked"], r["non_ascii"]), ("none",) * 4)
        self.assertEqual(r["player_order_complete"], "true")
        self.assertEqual((r["sighting_renamed"], r["sighting_lost"]), ("kabuki_alley", "nil"))
        self.assertEqual((r["split"], r["split_small"]), ("510/90", "1/0"))
        self.assertEqual((r["reward_snap"], r["reward_low"], r["reward_nan"]), ("500", "reward_out_of_range", "invalid_reward"))
        self.assertEqual(r["npc_rewards_ok"], "true")
        self.assertEqual((r["tier0"], r["tier8"], r["tier25"], r["floor"]), ("street", "trusted", "legend", "0"))
        self.assertEqual((r["inc_ok"], r["inc_default"], r["inc_huge"]), ("3", "1", "1"))
        self.assertEqual((r["inc_nomatch"], r["inc_dup"], r["inc_kind"], r["inc_job"]),
                         ("no_match", "duplicate_ref", "other_kind", "other_job"))
        self.assertEqual((r["norm_bad"], r["norm_ref"]), ("invalid_player", "invalid_ref"))
        self.assertEqual((r["take_ok"], r["take_rep"], r["take_own"], r["take_late"], r["take_many"]),
                         ("nil", "reputation_too_low", "own_contract", "contract_expired", "too_many_contracts"))
        self.assertEqual(r["ascii"], 'Caf "ok" done')
        self.assertEqual((r["money"], r["duration"]), ("1,234,567 eddies", "1 h 02 min|2 min|9 s"))
        self.assertEqual((r["pay_op"], r["refund_op"]), ("fixer.pay:x:3", "fixer.ref:x"))


@unittest.skipIf(missing_sources(), missing_sources())
class FixerLoop(unittest.TestCase):
    def run_ok(self, name):
        r = scenario(name)
        self.assertEqual(r.get("errors"), "0", r.get("first_error"))
        self.assertEqual(r.get("unbalanced"), "nil")
        return r

    def test_delivery_two_players_and_an_observer(self):
        r = self.run_ok("delivery")
        self.assertEqual(r["ui_mismatch"], "none")
        # The fixer posts through the board: the reward leaves their wallet into escrow at once.
        self.assertEqual((r["board1"], r["reward"], r["net"], r["cut"]), ("committed", "600", "540", "60"))
        self.assertEqual((r["poster_paid"], r["escrow_after_post"]), ("600", "600"))
        # The observer sees it while open, not once taken; the poster hears it was taken.
        self.assertEqual((r["seen_open"], r["seen_taken_by_observer"], r["poster_told_taken"]), ("true", "false", "true"))
        # The crate is the runner's alone.
        self.assertEqual((r["crate_placed"], r["observer_pick"], r["observer_refused"]), ("true", "refused", "not_your_crate"))
        self.assertEqual((r["pick"], r["carried"]), ("committed", "true"))
        self.assertEqual((r["wrong"], r["wrong_reason"], r["still_carrying"]), ("failed", "wrong_drop", "true"))
        # Delivered: one payout out of escrow, the cut to the fixers' society, reputation once.
        self.assertEqual((r["drop"], r["state"], r["runner_paid"], r["society"]), ("committed", "completed", "540", "60"))
        self.assertEqual((r["escrow_end"], r["escrow_agrees"], r["poster_after"]), ("0", "true", "600"))
        self.assertEqual((r["rep_b"], r["rep_log"], r["row_state"], r["row_live"], r["history"]), ("1", "true", "completed", "0", "1"))
        self.assertEqual((r["event_player"], r["event_ref"]), ("2", "fixer.pay:lab.fx1"))
        self.assertEqual((r["runner_told"], r["poster_told_done"], r["crate_gone"]), ("true", "true", "true"))

    def test_retrieval_npc_and_player_fixer(self):
        r = self.run_ok("retrieval")
        self.assertEqual(r["ui_mismatch"], "none")
        self.assertEqual(r["taken"], "taken")
        # Without the goods the hand-over is refused before the bar, and the player is told why.
        self.assertEqual((r["h0"], r["h0_reason"], r["h0_stage"], r["told_missing"]),
                         ("failed", "insufficient_items", "reserve", "true"))
        # NPC fixer: three chips burned, 510 paid (15 % cut of 600).
        self.assertEqual((r["h1"], r["c1"], r["chips_after1"], r["burned"]), ("committed", "completed", "2", "3"))
        self.assertEqual((r["paid1"], r["net1"], r["rep_after1"]), ("510", "510", "1"))
        # Player fixer: the chips land in their drop box, collected at the board.
        self.assertEqual((r["h2"], r["c2"], r["box_chips"], r["box_after"], r["a_chips"], r["b_chips"]),
                         ("committed", "completed", "3", "0", "3", "0"))
        self.assertEqual((r["told_box"], r["told_label"], r["rep_end"], r["society"]), ("true", "true", "2", "160"))
        self.assertEqual((r["escrow_end"], r["escrow_agrees"]), ("0", "true"))

    def test_job_order_satisfied_by_another_jobs_events(self):
        r = self.run_ok("job_order")
        self.assertEqual(r["low_rep"], "true")                    # reputation gates the better pay
        self.assertEqual((r["p1"], r["p2"]), ("4", "5"))          # replayed ref, other kind/job/player, malformed: ignored
        self.assertEqual((r["saved_progress"], r["saved_refs"]), ("5", "2"))   # progress is durable
        self.assertEqual((r["state"], r["progress_end"], r["paid"], r["net"], r["rep_b"]),
                         ("completed", "10", "1700", "1700", "5"))
        self.assertEqual((r["event_kind"], r["event_player"], r["event_contract_kind"]), ("contract_completed", "2", "job"))
        self.assertEqual((r["told_progress"], r["escrow_agrees"]), ("true", "true"))
        self.assertEqual(r["setrep"], "4/4")

    def test_nomad_run_order_counts_the_whole_run(self):
        r = self.run_ok("smuggle_order")
        self.assertEqual(r["taken"], "taken")
        # Two crates of three handed over: the run is not home yet, nothing counted.
        self.assertEqual((r["after_two"], r["progress_two"]), ("taken", "0"))
        self.assertEqual((r["state"], r["progress_end"], r["escrow_agrees"]), ("completed", "1", "true"))

    def test_cyberpsycho_bounties(self):
        r = self.run_ok("bounty")
        # The target: mortal, hostile, platform-priced hits, leashed to the sighting, engages.
        self.assertEqual((r["npc1"], r["record"], r["hit_pricing"], r["damage_policy"], r["attitude"], r["leash"]),
                         ("true", "Character.cpz_maelstrom_grunt1_ranged1_lexington_wa", "platform", "0", "hostile", "guard"))
        self.assertEqual(r["engaged"], "3")
        # Never spawned on top of a player: held while one stands on the sighting.
        self.assertEqual(r["held_on_player"], "true")
        # Open bounty: nobody takes it, whoever kills it is paid.
        self.assertEqual((r["open_take_refused"], r["c1"], r["c1_payee"], r["c1_paid"], r["c1_net"], r["rep_c"]),
                         ("true", "completed", "acct-c", "1700", "1700", "3"))
        # Claimed bounty killed by someone else: void, refunded, nobody paid.
        self.assertEqual((r["spawned_before_take"], r["npc2"], r["c2"], r["c2_outcome"]), ("false", "true", "spoiled", "spoiled"))
        self.assertEqual((r["b_paid_after_c2"], r["runner_told_spoiled"]), ("0", "true"))
        # Claimed bounty whose foreign kill respawns the target; the runner's kill (last hit,
        # health backstop) pays the runner.
        self.assertEqual((r["after_foreign"], r["respawned"], r["c3"], r["c3_payee"]), ("taken", "true", "completed", "acct-b"))
        self.assertEqual((r["b_paid"], r["c3_net"], r["poster_a_paid"], r["c3_reward"], r["rep_b"]),
                         ("2700", "2700", "3000", "3000", "11"))
        self.assertEqual((r["escrow_end"], r["escrow_agrees"]), ("0", "true"))

    def test_expiry_cancel_and_abandon_refund_the_poster(self):
        r = self.run_ok("expiry")
        self.assertEqual((r["c1"], r["c1_outcome"], r["npc_refund_net"]), ("expired", "expired", "0"))
        self.assertEqual((r["c2"], r["post_paid"], r["cancel_back"]), ("cancelled", "600", "600"))
        self.assertEqual((r["after_abandon"], r["crate_removed"], r["rep_abandon"]), ("open", "true", "1"))
        self.assertEqual((r["pick"], r["c3"], r["rep_expire"], r["runner_dropped"]), ("committed", "expired", "0", "true"))
        self.assertEqual(r["a_fixer_net"], "0")                    # every escrow of the poster came back
        self.assertEqual((r["told_expired"], r["told_refund"], r["gig_timeout"]), ("true", "true", "3"))
        self.assertEqual(r["escrow_end"], "0")

    def test_restart_with_open_contracts(self):
        r = self.run_ok("restart")
        self.assertEqual((r["ready"], r["loaded"], r["contracts_loaded"]), ("true", "taken,open,taken", "1"))
        self.assertEqual((r["crate_moved"], r["crate_back"]), ("true", "true"))     # where it was dropped
        self.assertEqual((r["psycho_back"], r["psycho_new_id"], r["escrow_kept"], r["reminded"]), ("true",) * 4)
        self.assertEqual(r["c4_seq"], "4")
        self.assertEqual((r["pick"], r["drop"], r["d1"], r["b_paid"], r["d1_net"]), ("committed", "committed", "completed", "450", "450"))
        self.assertEqual((r["hand"], r["d3"], r["c_paid"], r["d3_net"]), ("committed", "completed", "510", "510"))
        self.assertEqual((r["a_untouched"], r["escrow_agrees"]), ("true", "true"))

    def test_refusals_and_forged_calls(self):
        r = self.run_ok("refusals")
        self.assertEqual((r["no_job"], r["off_duty"], r["out_of_range"]), ("true", "true", "true"))
        self.assertEqual((r["broke"], r["voided"], r["cash_unchanged"]), ("true", "void", "true"))
        self.assertEqual((r["own"], r["far"], r["too_many"], r["held"], r["poster_limit"]), ("true", "true", "true", "2", "true"))
        self.assertEqual((r["wrong_hub"], r["wrong_hub_refused"], r["told_wrong_hub"]), ("refused", "no_retrieval_here", "true"))
        for key in ("forged_commit", "forged_putdown", "forged_board"):
            self.assertEqual(r[key], "nil:not_owner", key)
        self.assertEqual(r["forged_validate"], "false:not_owner")
        self.assertEqual(r["escrow_agrees"], "true")

    def test_crash_windows_pay_once(self):
        r = self.run_ok("crash")
        # A payout during a ledger outage waits, then pays once (a fenced id moves to the next).
        self.assertEqual((r["stuck"], r["c1"], r["paid1"], r["net1"]), ("paying", "completed", "1275", "1275"))
        # rp_fixer restarted while paying: saved as paying, completed after the restart, once.
        self.assertEqual((r["before2"], r["saved2"], r["d2"], r["paid2"], r["net2"], r["rep2"]),
                         ("paying", "paying", "completed", "1275", "1275", "7"))
        # The same payout again replays; the reputation key refuses a second raise.
        self.assertEqual((r["replay"], r["replay_moved"], r["dup"], r["rep_after_dup"]), ("true", "0", "duplicate", "7"))
        # An escrow whose "open" save was lost opens after the restart without a second charge.
        self.assertEqual((r["loaded_as"], r["d3"], r["escrow3_same"]), ("posting", "open", "true"))
        # An escrow that never committed: the contract is void.
        self.assertEqual((r["c4"], r["c4_reason"]), ("void", "escrow_failed"))
        self.assertEqual(r["escrow_agrees"], "true")

    def test_edges_distance_disconnect_library_restart(self):
        r = self.run_ok("edges")
        self.assertEqual(r["ui_mismatch"], "none")
        # Walking away while the dialog is open: the take is refused at the server's distance check.
        self.assertEqual((r["walked_away"], r["told_far"]), ("open", "true"))
        # A taken contract cannot be cancelled under its runner.
        self.assertEqual(r["cancel_taken"], "true")
        # A disconnect drops the crate where the runner stood; the place is saved; the contract stays theirs.
        self.assertEqual((r["still_taken"], r["saved_x"], r["saved_carried"]), ("taken", "true", "false"))
        self.assertEqual((r["reminded"], r["pins"]), ("true", "1"))
        # open77_actions restarts: the crate comes back where it lay, the prompts work again.
        self.assertEqual((r["crate_new"], r["crate_at"], r["board_after_restart"]), ("true", "true", "committed"))
        self.assertEqual((r["pick"], r["drop"], r["state"], r["paid"]), ("committed", "committed", "completed", "450"))
        self.assertEqual(r["escrow_agrees"], "true")
        # The post dialog offers the template's own duration (6 h) and posts with it.
        self.assertEqual((r["hours_offered"], r["hours_default"], r["c2"], r["c2_hours"]), ("1,2,4,6,8,24", "6", "open", "6"))

    def test_board_in_chat_without_the_ui_kit(self):
        r = self.run_ok("no_uikit")
        self.assertEqual((r["board"], r["listed"], r["hint"], r["nearest"], r["state"]),
                         ("committed", "true", "true", "true", "open"))

    def test_npc_fixers_stock_their_boards(self):
        r = self.run_ok("npc_board")
        self.assertEqual((r["afterlife"], r["wakako"], r["regina"], r["total"]), ("2", "2", "2", "6"))
        self.assertEqual((r["minted_is_escrow"], r["escrow_agrees"], r["contacts"], r["told"]), ("true", "true", "3", "true"))
        # A retrieval of an item no running resource defines is skipped, the other offers are posted.
        self.assertEqual(r["box_posted"], "false")
        self.assertNotEqual(r["box_skipped"], "0")


if __name__ == "__main__":
    unittest.main()
