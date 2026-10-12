"""Trauma Team International (rp_trauma): plans, calls, response and billing, offline.

Run with `python -m unittest discover -s tests -p "test_trauma*.py"` (Lua 5.4: lupa, or a lua54.dll
such as the KeraLua NuGet cache's; see tests/compat/luahost.py).

Each scenario boots, on tests/compat/multihost.lua: the FINAL open77_transactions resource (its
server/main.lua, exports, policy and work queue; the memory store plays the database), the real
open77_actions (Open77 repository, resources/system), the real rp_economy and rp_trauma's server
scripts, shims for the public exports of rp_jobs, rp_inventory and open77_uikit (the players'
answers to menus and dialogs are scripted), and fakes for the platform natives, including the
death -> freeroam respawn -> hold sequence of the down state. Scenario code:
tests/compat/trauma_scenarios.lua; world: tests/compat/trauma_world.lua.

Sources outside this pack are READ in place, never copied or edited:
  OP77_SYS_DIR   the Open77 resources/system folder with open77_actions (default: this
                 repository's system/ folder, else ../wt-world-interaction/resources/system)
  OP77_TX_FINAL  the final open77_transactions folder (default: SYS_DIR's copy)
A missing source skips the suite with the reason.

What this cannot show: anything in game (the kneel and wounded poses, the fade, prompt cards
over a body, the UI kit dialog over a blocked-input player, map pins, timing on a live tick),
SQL semantics on MariaDB, the real rp_jobs / rp_inventory / open77_uikit behind their exports.
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
RES = ROOT / "rp_trauma"


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
    return luahost.run_scenario("trauma_scenarios.lua", name, {
        "ROOT_DIR": ROOT.as_posix(), "COMPAT_DIR": COMPAT.as_posix(),
        "SYS_DIR": sys_dir().as_posix(), "TX_DIR": tx_dir().as_posix(),
    })


WEEK = 168 * 3600


class TraumaSources(unittest.TestCase):
    def test_sources_compile_without_bom(self):
        """Every rp_trauma Lua file: UTF-8 without BOM and loads as Lua 5.4 text."""
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
                lua.execute(f"assert(load({luahost.lua_string(data.decode('utf-8'))}, "
                            f"{luahost.lua_string('@' + path.name)}, 't'))", "=compile")
        finally:
            lua.close()

    def test_manifest_scripts_and_dependencies(self):
        """The service's server scripts load in the reference order; a resource that ships a client
        script never declares the server-only coordinator as a dependency; permissions unchanged."""
        text = (RES / "open77.lua").read_text(encoding="utf-8")
        code = "\n".join(line for line in text.splitlines() if not line.lstrip().startswith("--"))
        block = re.search(r"server_scripts\s*\{([^}]*)\}", code).group(1)
        self.assertEqual(re.findall(r'"([^"]+)"', block), [
            "server/config.lua", "server/model.lua", "server/ledger.lua", "server/ports.lua",
            "server/service.lua", "server/main.lua"])
        self.assertIn('client_script "client/main.lua"', code)
        self.assertNotIn("open77_transactions", code)
        self.assertNotIn('dependency "rp_', code)
        perms = sorted(re.findall(r'"([^"]+)"', re.search(r"permissions\s*\{([^}]*)\}", code).group(1)))
        self.assertEqual(perms, sorted([
            "players.animations.control", "players.animations.read", "world.props", "players.stats.read",
            "players.stats.apply",
            "players.life.read", "players.life.revive", "players.life.respawn", "players.life.freeze",
            "players.teleport", "world.vehicles", "network.events", "database.access", "input.blockAll",
            "ui.vanilla.map"]))

    def test_only_the_ledger_talks_to_the_coordinator(self):
        for path in sorted((RES / "server").glob("*.lua")):
            if path.name == "ledger.lua":
                continue
            self.assertNotIn('"open77_transactions"', path.read_text(encoding="utf-8"), path.name)
        main = (RES / "server" / "main.lua").read_text(encoding="utf-8")
        for legacy in ("rp_bank:charge", "rp_economy:remove", "rp_economy:add", "societyAdd"):
            self.assertNotIn(legacy, main)

    def test_kiosks_say_whether_they_were_walked(self):
        config = (RES / "server" / "config.lua").read_text(encoding="utf-8")
        kiosks = re.findall(r"id = \"(tti_kiosk_\w+)\".*?measured = (\w+)", config, re.S)
        self.assertEqual([k for k, _ in kiosks], ["tti_kiosk_pad", "tti_kiosk_market"])
        self.assertTrue(all(m in ("true", "false") for _, m in kiosks))
        self.assertEqual(dict(kiosks)["tti_kiosk_market"], "true")

    def test_prompt_labels_are_plain_ascii(self):
        config = (RES / "server" / "config.lua").read_text(encoding="utf-8")
        for label in re.findall(r'label = "([^"]*)"', config):
            self.assertTrue(all(ord(c) < 128 for c in label), label)
        client = (RES / "client" / "main.lua").read_text(encoding="utf-8")
        self.assertNotIn("€", client)

    def test_readme_standard_format(self):
        text = (RES / "README.md").read_text(encoding="utf-8")
        self.assertTrue(text.startswith("# rp_trauma\n\n"))
        for head in ("- **Docs:**", "- **Starts:**", "- **Needs:**", "- **Runs on:**",
                     "## How to play", "## Setup", "## Config", "## Limits"):
            self.assertIn(head, text)
        self.assertNotIn("—", text)
        for word in ("proven", "experimental", " lab ", "2026"):
            self.assertNotIn(word, text.lower() if word != "2026" else text)
        self.assertIn("tunable.set open77_transactions writers", text)
        self.assertIn("tunable.set open77_transactions mint", text)


@unittest.skipIf(missing_sources(), missing_sources())
class TraumaService(unittest.TestCase):
    def run_ok(self, name):
        r = scenario(name)
        self.assertEqual(r.get("errors"), "0", r.get("first_error"))
        self.assertEqual(r.get("unbalanced", "nil"), "nil")
        return r

    def test_subscribe_renew_switch_decline(self):
        r = self.run_ok("subscribe")
        self.assertEqual((r["o1"], r["o2"], r["o3"]), ("committed", "committed", "committed"))
        self.assertEqual(r["menu_options"], "plan_silver,plan_gold,plan_platinum,leave")
        # Gold, one week, the card in the holder's file, auto-renewal on, paid from the bank
        self.assertEqual((r["tier1"], r["auto1"], r["bank1"], r["soc1"]), ("gold", "true", "26000", "4000"))
        self.assertTrue(WEEK <= int(r["until1"]) <= WEEK + 10)
        self.assertEqual((r["cash_untouched"], r["told1"], r["has_contract"]), ("true", "true", "true"))
        self.assertEqual((r["plan_of"], r["plan_priority"]), ("gold", "2"))
        # renewing the same tier adds one period after the current end
        self.assertEqual((r["tier2"], r["extended"], r["periods2"], r["bank2"]), ("gold", str(WEEK), "2", "22000"))
        # switching starts a fresh period from now
        self.assertEqual((r["tier3"], r["until3_fresh"], r["bank3"]), ("platinum", "true", "12000"))
        # leaving the menu signs nothing
        self.assertEqual((r["o4"], r["o4_reason"], r["bank4"]), ("failed", "declined", "12000"))
        # rp:job:completed once per purchase, the coordinator op id as ref
        self.assertEqual((r["subs"], r["sub_job"], r["sub_player"], r["sub_tier"]), ("3", "trauma", "2", "gold"))
        self.assertTrue(r["sub_ref"].startswith("tt.plan:"))
        self.assertEqual(r["sub_modes"], "new,renew,switch")
        self.assertEqual((r["plan_ops"], r["soc_end"], r["held"]), ("3", "18000", "0"))

    def test_purchase_refusals(self):
        r = self.run_ok("subscribe_refusals")
        self.assertEqual((r["r1"], r["r1_reason"], r["r1_stage"]), ("failed", "insufficient_funds", "reserve"))
        self.assertEqual((r["told1"], r["no_card1"]), ("true", "true"))
        # bank first, then cash, one operation
        self.assertEqual((r["r2"], r["bank2"], r["cash2"], r["tier2"]), ("committed", "0", "0", "silver"))
        # four periods ahead at most
        self.assertEqual((r["s1"], r["s2"], r["s3"]), ("committed:ok", "committed:ok", "committed:ok"))
        self.assertEqual((r["s4"], r["told3"]), ("failed:max_prepaid", "true"))
        self.assertEqual((r["down_refused"], r["far_refused"]), ("patient_down", "too_far"))
        self.assertEqual((r["held_bank"], r["held_cash"]), ("0", "0"))

    def test_gold_subscriber_down_stabilise_evacuate(self):
        r = self.run_ok("gold_response")
        # the down state: held back at the death spot, frozen
        self.assertEqual((r["sub"], r["held"], r["frozen"], r["back_at_death"]), ("committed", "true", "true", "true"))
        # told once, although the respawn reported a second alive phase that held again
        self.assertEqual(r["down_told"], "1")
        # the call: priority 2, dispatched at once to the on-duty medic (chat, pin), the patient told
        self.assertEqual((r["call_id"], r["call_priority"], r["call_tier"]), ("1", "2", "gold"))
        self.assertEqual((r["told_medic"], r["pin_tag"], r["told_patient"]), ("true", "GOLD #1", "true"))
        self.assertEqual(r["target1"], "rp_trauma:tti_stabilise")
        self.assertEqual((r["taken"], r["responder"], r["told_responding"]), ("taken", "1", "true"))
        # stabilise: the medic kneels, the patient is stable but still down, the body offers Evacuate
        self.assertEqual((r["st"], r["kneel"], r["stable"], r["health_stable"]), ("committed", "true", "true", "25"))
        self.assertEqual((r["still_down"], r["target2"]), ("true", "rp_trauma:tti_evacuate"))
        # Gold covers it: the patient pays nothing, the society pays the medic 40 % of the fee
        self.assertEqual((r["patient_paid_stab"], r["medic_bank1"], r["soc_stab"]), ("0", "160", "160"))
        # evacuate: released at Vik's at Gold's health, the call and the target gone
        self.assertEqual((r["ev"], r["released"], r["at_clinic"], r["health_end"]), ("committed", "true", "true", "75"))
        self.assertEqual((r["frozen_end"], r["call_gone"], r["target_gone"], r["closed_events"]),
                         ("false", "true", "true", "1"))
        self.assertEqual((r["medic_bank2"], r["soc_end"], r["patient_paid"]), ("480", "3520", "0"))
        # the fixer events, once each
        self.assertEqual((r["jobs_s"], r["jobs_e"], r["job_s_player"], r["job_s_patient"]), ("1", "1", "1", "2"))
        self.assertEqual((r["job_s_bounty"], r["job_e_moved"]), ("160", "true"))
        self.assertTrue(r["job_e_ref"].startswith("tt.care:"))
        self.assertEqual((r["revived_by"], r["told_clinic"], r["held_soc"]), ("1", "true", "0"))
        # the down state is saved on the fall, saved again once stable, cleared by the evacuation
        self.assertEqual((r["saved_down"], r["saved_stable"], r["saved_end"]), ("true", "true", "true"))

    def test_silver_pays_half_the_evacuation(self):
        r = self.run_ok("silver_partial")
        self.assertEqual((r["delayed"], r["announced"]), ("false", "true"))   # Silver: 5 s dispatch delay
        self.assertEqual((r["st"], r["ev"], r["consent_asked"]), ("committed", "committed", "0"))
        self.assertEqual((r["ev_fee"], r["ev_covered"], r["ev_paid"], r["ev_cut"], r["ev_bounty"]),
                         ("800", "400", "400", "160", "160"))
        self.assertEqual((r["patient_paid"], r["medic_bank"], r["soc_delta"]), ("400", "480", "-80"))
        self.assertEqual((r["health_end"], r["told_charges"]), ("50", "true"))

    def test_uninsured_consents_pays_then_invoice(self):
        r = self.run_ok("uninsured_consent")
        self.assertEqual((r["told_uninsured"], r["early"], r["late"], r["pin_tag"]),
                         ("true", "false", "true", "UNINSURED #1"))
        # asked once per call, paid from the wallet, the medic's cut straight from it
        self.assertEqual((r["st"], r["asked_stab"], r["cash_paid_stab"]), ("committed", "1", "400"))
        self.assertEqual((r["ev"], r["asked_evac"], r["cash_end"], r["owed"], r["owed_export"]),
                         ("committed", "1", "0", "700", "700"))
        self.assertEqual((r["medic_bank"], r["soc_delta"], r["told_invoice"]), ("200", "300", "true"))
        # /tti pay: the invoice burns, the money reaches the society, in one operation
        self.assertEqual((r["owed_after"], r["bank_after"], r["soc_paid"]), ("0", "300", "700"))
        self.assertEqual((r["told_paid"], r["told_nothing"], r["invoice_net"]), ("true", "true", "0"))

    def test_declined_then_unconscious(self):
        r = self.run_ok("consent_declined_then_silent")
        self.assertEqual((r["r1"], r["r1_reason"], r["r1_stage"]), ("failed", "patient_declined", "reserve"))
        self.assertEqual((r["told_medic"], r["asked1"]), ("true", "1"))
        self.assertEqual((r["r2"], r["r2_reason"], r["asked2"]), ("failed", "patient_declined", "1"))
        # no answer: unconscious, treated, billed after (empty wallet: all invoiced)
        self.assertEqual((r["r3"], r["asked3"], r["owed"], r["stable"]), ("committed", "2", "400", "true"))
        self.assertEqual((r["medic_bank"], r["held_cash"]), ("0", "0"))

    def test_one_team_per_call(self):
        r = self.run_ok("one_team")
        self.assertEqual((r["told_taken"], r["s2"], r["refused"]), ("true", "none", "call_taken"))
        self.assertEqual((r["team"], r["st"], r["stabilised_by"]), ("true", "committed", "3"))
        # two medics on one open call in the same tick: one claim, one winner
        self.assertEqual((r["a"], r["responder4"], r["stable4"]), ("committed", "1", "true"))
        self.assertIn("target_claimed", r["claim_refusals"])
        self.assertEqual(r["jobs_s"], "2")
        # the team at the scene shares the cut: 40 % of 400 eddies, 80 each
        self.assertEqual((r["bank1"], r["bank3"], r["told_team_pay"]), ("80", "80", "true"))
        self.assertEqual((r["job_team"], r["job_team_pay"]), ("3,1", "80,80"))
        # the second call is one medic's alone
        self.assertEqual((r["bank1_end"], r["bank3_end"]), ("240", "80"))

    def test_call_closes_on_respawn_revive_and_disconnect(self):
        r = self.run_ok("call_closes")
        self.assertEqual(r["told_wait"], "true")
        # /respawn at Vik's: the bill once per down episode, the call closed, the target removed
        self.assertEqual((r["released"], r["at_clinic"], r["hosp_ops"], r["paid"]), ("true", "true", "1", "500"))
        self.assertEqual((r["closed1"], r["told_medic1"], r["target_gone1"], r["told_not_down"]),
                         ("1", "true", "true", "true"))
        # a revive in place (/reanimer, consent given, empty wallet: invoiced)
        self.assertEqual((r["call2"], r["revived"], r["closed2"], r["revive_ops"]), ("2", "true", "2", "1"))
        self.assertEqual((r["told_revive"], r["jobs_revive"], r["owed"]), ("true", "1", "300"))
        # a disconnect while down
        self.assertEqual((r["call3"], r["call3_gone"], r["closed3"], r["target3_gone"]), ("3", "true", "1", "true"))
        # /respawn and the revive clear the saved down state; the disconnect keeps it
        self.assertEqual((r["saved1_gone"], r["saved2_gone"], r["saved3_kept"]), ("true", "true", "true"))

    def test_healed_elsewhere_or_console_frees_the_hold(self):
        r = self.run_ok("healed_elsewhere")
        self.assertEqual((r["was_held"], r["freed"], r["frozen_after"], r["told_patched"]),
                         ("true", "true", "false", "true"))
        self.assertLess(int(float(r["low_health"])), 50)
        self.assertEqual((r["held_again"], r["released_by_console"], r["told_console"]), ("true", "true", "true"))
        self.assertEqual(r["paid"], "0")
        self.assertEqual((r["saved_healed_gone"], r["saved_again"], r["saved_released_gone"]), ("true", "true", "true"))

    def test_responder_leaves_reopens(self):
        r = scenario("responder_leaves")
        self.assertEqual(r.get("errors"), "0", r.get("first_error"))
        self.assertEqual((r["taken_by"], r["reopened"], r["reannounced"], r["told_patient"]),
                         ("1", "open", "true", "true"))
        self.assertEqual((r["taken2"], r["reopened2"]), ("3", "open"))
        self.assertEqual((r["open_events"], r["taken_events"]), ("3", "2"))

    def test_cancellations_charge_nothing(self):
        r = self.run_ok("cancellations")
        self.assertEqual(r["held_during"], "400")                     # reserved before the bar
        self.assertEqual((r["c1"], r["c1_reason"], r["held_after"]), ("cancelled", "cancelled_by_player", "0"))
        self.assertEqual((r["c2"], r["c2_reason"]), ("cancelled", "too_far"))
        self.assertEqual((r["c3"], r["c3_reason"]), ("cancelled", "patient_gone"))
        self.assertEqual((r["care_ops"], r["stab_charged"], r["held_end"], r["medic_bank"], r["jobs_s"]),
                         ("0", "0", "0", "0", "0"))
        self.assertEqual(r["hospital_paid"], "500")

    def test_restart_keeps_the_plan(self):
        r = self.run_ok("restart_keeps_plan")
        self.assertEqual((r["until_same"], r["tier"], r["has"], r["told_active"]), ("true", "gold", "true", "true"))
        self.assertEqual((r["call_tier"], r["call_priority"]), ("gold", "2"))
        # the held player is held down again after the rp_trauma restart, their Gold call raised again
        self.assertEqual((r["after_restart_tier"], r["frozen_after"], r["patient_target"], r["call2_tier"]),
                         ("gold", "true", "rp_trauma:tti_stabilise", "gold"))

    def test_auto_renewal_once_per_period(self):
        r = self.run_ok("renewal")
        self.assertEqual((r["bank1"], r["extended"], r["periods2"]), ("1700", str(WEEK), "2"))
        self.assertEqual((r["bank2"], r["bank2b"], r["renew_ops"], r["told_renewed"]), ("200", "200", "1", "true"))
        self.assertEqual((r["lapsed"], r["told_failed"], r["auto3"]), ("true", "1", "false"))
        self.assertEqual((r["subs"], r["last_mode"]), ("3", "auto_renew"))
        # a later purchase keeps renewals off
        self.assertEqual((r["again"], r["auto4"], r["mode4"]), ("committed", "false", "new"))

    def test_priority_dispatch(self):
        r = scenario("priority_dispatch")
        self.assertEqual(r.get("errors"), "0", r.get("first_error"))
        self.assertEqual((r["plat0"], r["silver0"], r["none0"]), ("true", "false", "false"))
        self.assertEqual((r["silver6"], r["none6"], r["none18"]), ("true", "false", "true"))
        self.assertEqual((r["order"], r["first"]), ("platinum,silver,none", "1"))
        self.assertEqual((r["calls_export"], r["export_first"]), ("3", "platinum"))

    def test_refusals_and_forged_hooks(self):
        r = self.run_ok("refusals")
        self.assertEqual(r["civilian"], "no_job")
        self.assertEqual((r["ev"], r["not_stable"]), ("none", "invalid_target"))   # Evacuate is offered once stable
        self.assertEqual((r["forged"], r["forged_value"]), ("not_owner", "nil"))
        self.assertEqual((r["forged_v"], r["forged_v_why"]), ("false", "not_owner"))
        self.assertEqual((r["forged_r"], r["forged_r_why"]), ("nil", "not_owner"))
        self.assertEqual((r["self_take"], r["nothing_moved"]), ("true", "true"))

    def test_crash_windows_charge_once(self):
        r = self.run_ok("crash_windows")
        self.assertEqual((r["st"], r["paid_stab"], r["jobs1"], r["stab_ops"]), ("committed", "400", "1", "1"))
        self.assertEqual((r["ev"], r["evacuated"], r["at_clinic"]), ("in_doubt", "true", "true"))
        self.assertEqual((r["evac_ops"], r["jobs_e"], r["doubts"], r["paid_total"]), ("1", "1", "0", "1200"))

    def test_legacy_import_once(self):
        r = self.run_ok("legacy_import")
        self.assertEqual((r["owed"], r["tier"], r["until_at"]), ("400", "gold", "8200"))
        self.assertEqual((r["marked"], r["contract_off"], r["kvp_gone"]), ("true", "true", "true"))
        self.assertEqual((r["owed_again"], r["legacy_ops"]), ("400", "4"))

    def test_down_survives_a_reconnect(self):
        r = self.run_ok("down_reconnect")
        self.assertEqual(r["saved1"], "true")
        # leaving closes the live call (the responder is told), the saved state stays
        self.assertEqual((r["call_gone"], r["closed_left"], r["told_medic_closed"], r["kept_saved"]),
                         ("true", "1", "true", "true"))
        # back: held at the spot where they fell, frozen, at down health, the same deadline
        self.assertEqual((r["back_down"], r["held"], r["frozen"], r["at_death"], r["health"], r["same_deadline"]),
                         ("true", "true", "true", "true", "5", "true"))
        left_back, left_expected = int(r["left_back"]), int(r["left_expected"])
        self.assertLessEqual(abs(left_back - left_expected), 1)
        self.assertTrue(0 < left_back < 50, left_back)
        # a new call: the patient told, the medic dispatched after the uninsured delay, the body targeted
        self.assertEqual((r["call2"], r["open_events"], r["told_call2"], r["told_medic2"], r["target"]),
                         ("2", "2", "true", "true", "rp_trauma:tti_stabilise"))
        # "You are still down" said once, although a second alive phase held the body again
        self.assertEqual((r["still_told"], r["down_told"], r["frozen_end"]), ("1", "1", "true"))

    def test_stable_patient_comes_back_stable(self):
        r = self.run_ok("down_stable_reconnect")
        self.assertEqual((r["st"], r["stable_health"], r["saved_stable"]), ("committed", "25", "true"))
        # back stable at the stable health; the new Gold call is stable: the body offers Evacuate
        self.assertEqual((r["back_stable"], r["held"], r["health"], r["at_death"]), ("true", "true", "25", "true"))
        self.assertEqual((r["call_stable"], r["call_tier"], r["target"], r["still_told"]),
                         ("true", "gold", "rp_trauma:tti_evacuate", "1"))
        # the evacuation of the resumed body: Vik's, the saved state cleared, one stabilisation charged
        self.assertEqual((r["ev"], r["released"], r["at_clinic"], r["saved_gone"], r["stab_ops"]),
                         ("committed", "true", "true", "true", "1"))

    def test_a_held_body_that_fell_through_is_put_back(self):
        r = self.run_ok("down_body_fell_through")
        self.assertEqual((r["put_back"], r["back_at_death"], r["logged"], r["again"], r["still_held"]),
                         ("1", "true", "true", "0", "true"))
        # the patient's own card is hidden from them; the crowd is kept off the body
        self.assertEqual((r["hidden_for"], r["crowd_off"]), ("2", "1.5"))

    def test_down_survives_a_resource_restart(self):
        r = self.run_ok("down_resource_restart")
        # the stop unfreezes and releases the client hold, without healing or regenerating; the
        # saved state stays
        self.assertEqual((r["low_health"], r["stopped_frozen"], r["stopped_regen"], r["stopped_unhold"]),
                         ("5", "false", "false", "false"))
        self.assertEqual((r["stopped_health"], r["health_between"], r["stopped_saved"], r["stopped_logged"]),
                         ("5", "5", "true", "true"))
        # the start holds the body down again, same spot, same deadline, a new call, said once
        self.assertEqual((r["back_down"], r["held"], r["frozen"], r["health"], r["at_death"], r["same_deadline"]),
                         ("true", "true", "true", "5", "true", "true"))
        self.assertEqual((r["call"], r["target"], r["still_told"]), ("1", "rp_trauma:tti_stabilise", "1"))

    def test_down_countdown_ran_out_while_away(self):
        r = self.run_ok("down_expired_while_away")
        # back before the hold: /respawn waits for the body
        self.assertEqual((r["resumed_early"], r["held_early"], r["told_settling"], r["still_after_early"]),
                         ("true", "false", "true", "true"))
        # the connect grace holds it: still down, the countdown at 0, told once, no second "open" line
        self.assertEqual((r["held"], r["frozen"], r["at_death"], r["health"], r["left"]), ("true", "true", "true", "5", "0"))
        self.assertEqual((r["told_ran_out"], r["told_open_again"]), ("1", "0"))
        # /respawn at once, a medic on duty or not: Vik's, billed once, the saved state cleared
        self.assertEqual((r["released"], r["at_clinic"], r["hosp_ops"], r["saved_gone"]), ("true", "true", "1", "true"))

    def test_getting_up_clears_the_saved_down_state(self):
        r = self.run_ok("down_respawn_clears")
        self.assertEqual((r["saved1"], r["released"], r["saved_after"]), ("true", "true", "false"))
        self.assertEqual((r["back_down"], r["frozen"], r["health"], r["at_spawn"], r["still_told"]),
                         ("false", "false", "100", "true", "0"))

    def test_stale_down_state_is_dropped(self):
        r = self.run_ok("down_stale_dropped")
        # a server restart a minute later: still down at the same spot, same deadline
        self.assertEqual((r["restart_down"], r["restart_held"], r["restart_at_death"], r["restart_same_deadline"]),
                         ("true", "true", "true", "true"))
        # five hours later (cap 3 h): dropped at start, the player comes back up
        self.assertEqual((r["purged"], r["saved_after_purge"], r["up_after_purge"]), ("true", "false", "true"))
        # on a return after the (lowered) cap: dropped, up at full health
        self.assertEqual((r["saved_leaver"], r["leaver_down"], r["leaver_frozen"], r["leaver_health"]),
                         ("true", "false", "false", "100"))
        self.assertEqual((r["leaver_saved"], r["leaver_logged"]), ("false", "true"))

    def test_down_persist_off_keeps_the_old_rules(self):
        r = self.run_ok("down_persist_off")
        self.assertEqual((r["saved_off"], r["health_stopped"], r["frozen_stopped"], r["down_after"], r["logged"]),
                         ("false", "100", "false", "false", "true"))

    def test_legacy_acts_billed_through_the_coordinator(self):
        r = self.run_ok("legacy_acts")
        self.assertEqual((r["silent_refused"], r["healed"], r["paid_heal"], r["heal_ops"]), ("true", "true", "100", "1"))
        self.assertEqual((r["revived"], r["asked_revive"], r["paid_revive"], r["revive_ops"], r["call_closed"]),
                         ("true", "0", "0", "1", "true"))


if __name__ == "__main__":
    unittest.main()
