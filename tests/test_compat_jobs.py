"""B4 jobs/duty/grade adapter: rp_jobs' real server script on the B8 fake host, offline.

Run with `python -m unittest discover -s tests -p "test_compat*.py"`. Needs a Lua 5.4 engine
(tests/compat/luahost.py: lupa, or a lua54.dll such as the KeraLua NuGet cache's); the tests
skip with the reason when there is none. Scenarios: tests/compat/jobs_scenarios.lua.

What is frozen here (docs/world-interaction/b4-jobs.md):
- `eligible(playerId, requirement)` answers `true, epoch` or `nil, reason` with stable tokens;
- the work epoch moves on every job, grade and duty change, never repeats for a reused seat
  or after a restart, and a capture older than the current epoch is refused at commit with
  `stale_job_epoch`;
- forged client requests (the hire action, the agency prompt, a commit) grant nothing;
- job, grade and duty round-trip through SQL keyed by the durable subject, with ordered,
  coalesced and retried writes;
- a configured database that does not answer refuses (`store_unavailable`) and never forks
  into KVP (gap R1 closed for rp_jobs); KVP only as the explicit no-database lab store;
- the eight existing exports, their refusal tokens and the legacy events are unchanged;
- the public state-bag summary is small and carries no private field.
"""
import os
import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent / "compat"))
import luahost  # noqa: E402

ROOT = Path(__file__).resolve().parents[1]
def _tx_dir():
    explicit = os.environ.get("OP77_TX_DIR")
    if explicit and Path(explicit).is_dir():
        return Path(explicit).as_posix()
    return (ROOT / "tests" / "compat" / "vendor" / "open77_transactions").as_posix()


GLOBALS = {
    "JOBS_SCRIPT": (ROOT / "rp_jobs" / "server" / "main.lua").as_posix(),
    "JOBS_CONFIG": (ROOT / "rp_jobs" / "shared" / "config.lua").as_posix(),
    "COMPAT_DIR": (ROOT / "tests" / "compat").as_posix(),
    "TX_DIR": _tx_dir(),
}


def scenario(name):
    return luahost.run_scenario("jobs_scenarios.lua", name, GLOBALS)


@unittest.skipIf(luahost.unavailable(), luahost.unavailable())
class JobsAdapterCompat(unittest.TestCase):
    def test_eligibility_matrix(self):
        r = scenario("eligibility_matrix")
        expected = {
            "any_loaded": "ok",
            "jobless_any": "ok",
            "job_match": "ok",
            "job_alias": "ok",
            "job_list": "ok",
            "job_wrong": "wrong_job",
            "job_none": "no_job",
            "duty_off": "off_duty",
            "duty_false_is_no_constraint": "ok",
            "duty_on": "ok",
            "duty_jobless": "no_job",
            "grade_low": "grade_too_low",
            "grade_ok": "ok",
            "any_job": "no_job",
            "boss_scoped": "ok",
            "boss_other_job": "wrong_job",
            "society_ok": "ok",
            "society_wrong": "wrong_society",
            "bad_type": "invalid_requirement",
            "bad_key": "invalid_requirement",
            "bad_grade": "invalid_requirement",
            "bad_fraction": "invalid_requirement",
            "bad_duty": "invalid_requirement",
            "bad_list": "invalid_requirement",
            "empty_list": "invalid_requirement",
            "unknown_job": "unknown_job",
            "bad_epoch": "invalid_requirement",
            "bad_id": "invalid_player_id",
            "zero_id": "invalid_player_id",
            "unknown_player": "player_not_found",
            "ok_returns_current_epoch": "true",
            "duty_after_service": "ok",
        }
        for key, value in expected.items():
            with self.subTest(case=key):
                self.assertEqual(r[key], value)

    def test_epoch_invalidates_work_on_setjob_duty_and_grade_changes(self):
        r = scenario("epoch_invalidation")
        self.assertEqual(r["commit_unchanged"], "ok")
        # duty off then on again: eligible now, but the capture from before is stale
        self.assertEqual(r["after_duty_cycle_eligible"], "ok")
        self.assertEqual(r["after_duty_cycle_commit"], "stale_job_epoch")
        # grade change through setjob (same employer, duty kept)
        self.assertEqual(r["after_grade_still_on_duty"], "true")
        self.assertEqual(r["after_grade_commit"], "stale_job_epoch")
        # a setjob/setJob that changes nothing does not move the epoch
        self.assertEqual(r["noop_keeps_epoch"], "ok")
        self.assertEqual(r["after_job_change_commit"], "stale_job_epoch")
        self.assertEqual(r["after_job_change_duty"], "false")
        self.assertEqual(r["after_removal_commit"], "stale_job_epoch")
        self.assertEqual(r["event_reasons"], "duty_off,duty_on,grade_changed,duty_off,job_changed,job_changed")
        self.assertEqual(r["last_event_is_current"], "true")
        self.assertEqual(r["events_increase"], "true")
        # the setDuty export (a foreman target) moves the epoch and answers the new one
        self.assertEqual(r["setDuty_answer"], "true:true")
        self.assertEqual(r["setDuty_commit_old"], "stale_job_epoch")
        self.assertEqual(r["setDuty_commit_new"], "ok")
        self.assertEqual(r["setDuty_noop_keeps_epoch"], "true")

    def test_epoch_never_repeats_across_seats_disconnects_and_restarts(self):
        r = scenario("epoch_invalidation")
        self.assertEqual(r["disconnect_events"], "duty_off,false:unloaded")
        self.assertEqual(r["after_disconnect"], "player_not_found")
        self.assertEqual(r["after_disconnect_epoch"], "player_not_found")
        self.assertEqual(r["seat_reuse_commit_old"], "stale_job_epoch")
        self.assertEqual(r["seat_reuse_new_epoch"], "true")
        self.assertEqual(r["epochs_distinct_between_players"], "true")
        self.assertEqual(r["restart_commit_old"], "stale_job_epoch")
        self.assertEqual(r["restart_loaded_event"], "true")

    def test_forged_prompts_grant_nothing(self):
        r = scenario("forged_prompts")
        self.assertEqual(r["forged_hire_by_jobless"], "nil")
        self.assertEqual(r["forged_hire_answer"], "You have no job, choom. Nobody to hire, fire or promote.")
        self.assertEqual(r["forged_hire_bad_target"], "nil")
        self.assertEqual(r["boss_out_of_range"], "nil")
        self.assertEqual(r["boss_in_range"], "ncpd:0")
        self.assertEqual(r["agency_far_menu_opened"], "0")
        self.assertEqual(r["forged_by_jobless"], "no_job")
        self.assertEqual(r["forged_by_other_job"], "wrong_job")
        self.assertEqual(r["forged_off_duty"], "off_duty")
        self.assertEqual(r["forged_epoch"], "stale_job_epoch")
        self.assertEqual(r["legitimate"], "granted")
        self.assertEqual(r["replayed_after_duty_change"], "stale_job_epoch")
        self.assertEqual(r["granted"], "1")

    def test_persistence_round_trip(self):
        r = scenario("persistence_round_trip")
        self.assertEqual(r["row_on_duty"], "ferrailleur:2:duty=1")
        self.assertEqual(r["row_hired_by"], "console")
        # crash and restart: job and grade come back from SQL, duty is cleared there too
        self.assertEqual(r["after_restart"], "ferrailleur:2:duty=false")
        self.assertEqual(r["row_after_restart"], "ferrailleur:2:duty=0")
        self.assertEqual(r["row_duty_on"], "ferrailleur:2:duty=1")
        self.assertEqual(r["row_after_disconnect"], "ferrailleur:2:duty=0")
        self.assertEqual(r["after_reconnect"], "ferrailleur:duty=false")
        self.assertEqual(r["greeted"], "true")
        self.assertEqual(r["row_after_removal"], "none")

    def test_writes_are_ordered_coalesced_and_retried(self):
        r = scenario("persistence_round_trip")
        self.assertEqual(r["in_flight"], "1")
        self.assertEqual(r["writes_submitted"], "2")
        self.assertEqual(r["row_after_burst"], "mecano:1:duty=0")
        self.assertEqual(r["reconnect_during_write"], "nomade:2")
        self.assertEqual(r["row_after_reconnect"], "nomade:2:duty=0")
        self.assertEqual(r["row_during_outage"], "nomade:2:duty=0")
        self.assertEqual(r["row_after_retry"], "vigile:1:duty=0")
        self.assertEqual(r["retry_logged"], "true")
        self.assertEqual(r["kvp_employment_keys"], "0")

    def test_no_kvp_fork_when_the_database_is_configured(self):
        """Gap R1 closed for rp_jobs: a database outage never changes a job."""
        r = scenario("no_kvp_fork")
        self.assertEqual(r["pending_getJob"], "nil")
        self.assertEqual(r["pending_hasJob"], "false")
        for key in ("pending_eligible", "pending_setJob", "pending_workEpoch", "pending_setDuty"):
            with self.subTest(case=key):
                self.assertEqual(r[key], "store_unavailable")
        self.assertIn("database is not answering", r["pending_service_answer"])
        self.assertEqual(r["pending_setjob_logged"], "true")
        self.assertEqual(r["pending_watchdog_logged"], "true")
        self.assertEqual(r["kvp_employment_keys"], "0")
        self.assertEqual(r["sql_row_untouched"], "ferrailleur:2:duty=0")
        # the database answers later in the same boot: files load from SQL
        self.assertEqual(r["late_answer"], "ferrailleur:2")
        self.assertEqual(r["late_eligible"], "ok")
        # a failed schema refuses rather than forking
        self.assertEqual(r["schema_failed"], "store_unavailable")
        self.assertEqual(r["schema_failed_logged"], "true")
        # ...but an unreachable database during the schema step is retried, then loads
        self.assertEqual(r["schema_transient"], "ferrailleur:true:false")

    def test_no_database_lab_store_is_explicit_and_never_leaks_into_sql(self):
        r = scenario("no_kvp_fork")
        self.assertEqual(r["no_database_refused"], "store_unavailable")
        self.assertEqual(r["no_database_refused_kvp"], "0")
        self.assertEqual(r["lab_store_logged"], "true")
        self.assertEqual(r["lab_store_job"], "nil")
        self.assertEqual(r["lab_store_keys"], "1")
        self.assertEqual(r["sql_after_lab"], "ferrailleur:2")

    def test_existing_exports_and_events_are_compatible(self):
        r = scenario("compat_exports")
        expected = {
            "getJob_unknown": "nil",
            "hasJob_unknown": "false",
            "getGrade_unknown": "nil",
            "isBoss_unknown": "false",
            "onDuty_unknown": "false",
            "set_bad_id": "invalid_player_id",
            "set_unknown_player": "player_not_found",
            "set_unknown_job": "unknown_job",
            "set_reserved": "reserved_job",
            "set_bad_grade": "invalid_grade",
            "set_alias": "value:true",
            "alias_job": "delamain",
            "hasJob_alias": "true",
            "getGrade": "1:employee",
            "isBoss_7": "false",
            "isBoss_9": "true",
            "listOnDuty": "8,9",
            "listOnDuty_unknown": "0",
            "salary": "600",
            "salary_bad": "0",
            # rp_jobs:duty(false) with the OLD job still comes before rp_jobs:changed
            "event_order": "epoch(duty_off) duty(9,ncpd,false) epoch(job_changed) changed(9,trauma)",
            "set_none": "value:true",
            "after_none": "nil",
            "changed_none_payload": "9,nil",
            "setDuty_no_job": "no_job",
            "setDuty_bad_value": "invalid_duty",
            "setDuty_wrong_job": "wrong_job",
            "setDuty_off": "value:true",
            "after_setDuty_off": "false",
            "service_jobless": "No job, no shift. /agence to find one.",
            "setjob_unknown_logged": "true",
            "jobcheck_refused": "true",
            "jobcheck_eligible": "true",
            "jobcheck_unknown": "true",
        }
        for key, value in expected.items():
            with self.subTest(case=key):
                self.assertEqual(r[key], value)

    def test_public_summary_is_small_and_audience_appropriate(self):
        r = scenario("public_summary")
        self.assertEqual(r["bag_off_duty"], "duty=false")
        self.assertEqual(r["bag_on_duty"], "duty=true;grade=senior;job=ncpd;label=NCPD")
        self.assertEqual(r["bag_has_private"], "false")
        self.assertEqual(r["bag_jobless"], "duty=false")
        self.assertEqual(r["bag_after_clock_out"], "duty=false")
        self.assertEqual(r["summary_on_duty"], "grade=2;gradeLabel=senior;job=ncpd;label=NCPD;onDuty=true")
        self.assertEqual(r["summary_jobless"], "grade=false;gradeLabel=false;job=false;label=false;onDuty=false")
        self.assertEqual(r["summary_unknown"], "player_not_found")
        self.assertEqual(r["bag_refusal_logged"], "true")
        self.assertEqual(r["duty_despite_refusal"], "true")
        self.assertEqual(r["bag_disabled"], "true")

    def test_durable_keys_follow_the_subject_provider_rule(self):
        r = scenario("subject_provider")
        self.assertEqual(r["keyed_by_provider"], "true")
        self.assertEqual(r["not_keyed_by_account"], "true")
        self.assertEqual(r["provider_refusal"], "subject_provider_unavailable")
        self.assertEqual(r["default_rule_key"], "true")
        self.assertEqual(r["required_provider_missing"], "subject_unavailable")
        self.assertEqual(r["session_key"], "invalid_key")
        self.assertEqual(r["numeric_key"], "invalid_key")
        self.assertEqual(r["long_key"], "invalid_key")
        self.assertEqual(r["session_setJob"], "invalid_key")
        self.assertEqual(r["rows_for_bad_keys"], "false")

    def test_subject_provider_rule_against_the_final_coordinator(self):
        """open77_transactions:subjectOf of Open77 697e9e2f (vendored), not a stub."""
        r = scenario("subject_provider_real")
        self.assertEqual(r["default_key"], "mecano")             # default provider: the account id
        self.assertEqual(r["register"], "true")
        self.assertEqual(r["override_key"], "ncpd")              # acct-0007~3, a character's row
        self.assertEqual(r["override_refusal"], "no_character")  # passed through, never the account id
        self.assertEqual((r["session_key"], r["numeric_key"]), ("invalid_key", "invalid_key"))
        self.assertEqual(r["rows_for_bad_keys"], "false")


if __name__ == "__main__":
    unittest.main()
