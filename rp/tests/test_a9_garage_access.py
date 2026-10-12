"""A9 vehicle access adapter: rp_garage's real server scripts on the B8 fake host, offline.

Run with `python -m unittest discover -s tests -p "test_*.py"` (or `-p "test_a9*.py"`). Needs a
Lua 5.4 engine (tests/compat/luahost.py: lupa, or a lua54.dll such as the KeraLua NuGet cache's).

What it pins (docs/world-interaction/a9-cargo.md):
  * the access matrix: owner, key holder, mechanic with / without a job order, police with /
    without a warrant and on / off duty, stranger; the impound lot; a society fleet;
  * grants are keyed by plate, persist across a restart, expire and are revoked;
  * the plate is the identity; a runtime vehicle id is only the current projection.
Nothing here ran in game.
"""
import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent / "compat"))
import luahost  # noqa: E402

ROOT = Path(__file__).resolve().parents[1]
COMPAT = (ROOT / "tests" / "compat").as_posix()
GARAGE = (ROOT / "rp_garage").as_posix()


def scenario(name):
    return luahost.run_scenario("garage_access_scenarios.lua", name, {"COMPAT_DIR": COMPAT, "GARAGE_DIR": GARAGE})


@unittest.skipIf(luahost.unavailable(), luahost.unavailable())
class GarageAccess(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.matrix = scenario("matrix")

    def check(self, results, expected):
        for key, value in expected.items():
            with self.subTest(case=key):
                self.assertEqual(results.get(key), value)

    def test_owner_and_key_holder(self):
        self.check(self.matrix, {
            "owner_cargo_take": "true:owner",
            "owner_manage": "true:owner",
            "owner_plate_without_prefix": "true:owner",
            "key_cargo_put": "true:key",
            "key_drive": "true:key",
            "key_manage": "false:action_not_permitted",
        })

    def test_stranger_is_refused(self):
        self.check(self.matrix, {
            "stranger_cargo_view": "false:no_access",
            "stranger_drive": "false:no_access",
        })

    def test_mechanic_needs_a_job_order_and_duty(self):
        self.check(self.matrix, {
            "mech_no_order_view": "false:no_job_order",
            "order_by_stranger": "nil:not_owner",
            "order_holder": "acct-mech",
            "order_minutes": "30",
            "mech_order_view": "true:mechanic",
            "mech_order_take": "false:action_not_permitted",
            "mech_order_drive": "true:mechanic",
            "mech_order_repair": "true:mechanic",
            "mech_order_glovebox": "false:action_not_permitted",
            "mech_offduty_view": "false:off_duty",
        })

    def test_police_needs_a_warrant_and_duty(self):
        self.check(self.matrix, {
            "police_no_warrant_view": "false:warrant_required",
            "police_wanted_take": "true:police",
            "police_wanted_put": "false:action_not_permitted",
            "police_wanted_impound": "true:police",
            "police_offduty_wanted": "false:off_duty",
            "police_after_unflag": "false:warrant_required",
            "warrant_by_rookie": "nil:grade_too_low",
            "warrant_by_mechanic": "nil:not_police",
            "warrant_holder": "job:ncpd",
            "police_warrant_take": "true:police",
            "rookie_warrant_view": "true:police",
        })

    def test_impound_and_society_fleet(self):
        self.check(self.matrix, {
            "owner_impounded_take": "false:impounded",
            "owner_impounded_manage": "true:owner",
            "police_impounded_view": "true:police",
            "fleet_employee_put": "true:key",
            "fleet_employee_manage": "false:action_not_permitted",
            "fleet_boss_manage": "true:owner",
            "fleet_outsider": "false:no_access",
        })

    def test_vocabulary_and_durable_keys(self):
        self.check(self.matrix, {
            "untracked_plate": "false:vehicle_not_tracked",
            "numeric_plate": "false:invalid_plate",
            "number_plate": "false:invalid_plate",
            "bad_part": "false:invalid_part",
            "bad_action": "false:invalid_action",
            "part_action_on_vehicle": "false:invalid_action",
            "bad_player": "false:invalid_player_id",
            "unknown_player": "false:player_not_found",
            "account": "veh:NC-AAAA:cargo",
            "account_bad_part": "nil:invalid_part",
            "account_untracked": "nil:vehicle_not_tracked",
            "authorizations": "2",
        })
        self.assertIn("NC-AAAA,authorized", self.matrix["changed"])

    def test_grants_persist_expire_and_revoke(self):
        self.check(scenario("grants_persist"), {
            "sql_rows": "1",
            "after_restart": "true:mechanic",
            "after_expiry": "false:no_job_order",
            "sql_rows_after_expiry": "0",
            "after_expiry_restart": "false:no_job_order",
            "revoke_by_stranger": "nil:not_owner",
            "revoke_by_owner": "1:nil",
            "after_revoke": "false:no_job_order",
            "revoke_again": "nil:not_found",
            "bad_holder": "nil:invalid_holder",
            "runtime_holder": "nil:invalid_holder",
            "bad_role": "nil:invalid_role",
            "too_long": "nil:invalid_duration",
        })

    def test_registry_loading_refuses(self):
        self.check(scenario("loading"), {
            "can": "false:registry_loading",
            "authorize": "nil:registry_loading",
        })

    def test_plate_identity_survives_new_runtime_ids(self):
        r = scenario("identity")
        self.check(r, {
            "first_ok": "true",
            "describe_first": "true",
            "key_vehicle_put": "true:key",
            "stranger_vehicle": "false:no_access",
            "mech_exception": "false",           # job order: unlocked for the mechanic
            "key_exception": "false",
            "stranger_exception": "nil",
            "state_after_removal": "stored",
            "no_vehicle_after_removal": "true",
            "old_id": "false:vehicle_not_tracked",
            "new_id_differs": "true",
            "describe_second": "true",
            "new_id": "true:key",
            "plate_of_second": "NC-AAAA",
            "untracked_vehicle": "false:vehicle_not_tracked",
        })
        self.assertEqual(r["spawned"], f"NC-AAAA,<id>,{MACKINAW};NC-AAAA,<id>,{MACKINAW}")
        self.assertEqual(r["despawned"], "NC-AAAA,<id>,lost")

    def test_player_and_console_commands(self):
        self.check(scenario("commands"), {
            "key_before": "true:key",
            "key_after_revoke": "false:no_access",
            "key_rows": "0",
            "mech_after_order": "true:mechanic",
            "stranger_after_order": "false:no_access",
            "mech_after_cancel": "false:no_job_order",
            "police_after_console_warrant": "true:police",
            "police_after_player_attempt": "true:police",
            "police_after_lift": "false:warrant_required",
            "no_grant_left": "true",
        })

    def test_lab_issue_is_gated_and_owned(self):
        """labIssue (C1 two-client runs): convar-gated, a plated vehicle owned by the player."""
        self.check(scenario("lab_issue"), {
            "disabled": "nil:lab_disabled",
            "issued": "out:true:true",
            "owner": "acct-key",
            "owner_cargo": "true:owner",
            "stranger_cargo": "false:no_access",
            "account": "ok",
            "persisted": "true",
            "stored_only": "stored",
            "bad_record": "nil:invalid_record",
            "bad_player": "nil:player_not_found",
        })


MACKINAW = "Vehicle.v_standard3_thorton_mackinaw_player"

if __name__ == "__main__":
    unittest.main()
