"""A9 cargo layouts and cargo service: rp_cargo's real server scripts on the B8 fake host, offline.

Run with `python -m unittest discover -s tests -p "test_*.py"` (or `-p "test_a9*.py"`). Needs a
Lua 5.4 engine (tests/compat/luahost.py). The coordinator is the REAL final open77_transactions
(the vendored copy of Open77 697e9e2f, or OP77_TX_DIR), on tests/compat/txsandbox.lua, seeded and
fault-injected at the export boundary by tests/compat/fake_tx.lua; rp_garage is a stub of its A9
exports (its real access matrix is tests/test_a9_garage_access.py). Nothing here ran in game:
the offsets in rp_cargo/data/layouts.json are starting guesses (measured: false).
"""
import os
import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent / "compat"))
import luahost  # noqa: E402

ROOT = Path(__file__).resolve().parents[1]
COMPAT = (ROOT / "tests" / "compat").as_posix()
CARGO = (ROOT / "rp_cargo").as_posix()
MACKINAW = "Vehicle.v_standard3_thorton_mackinaw_player"


def _tx_dir():
    explicit = os.environ.get("OP77_TX_DIR")
    if explicit and Path(explicit).is_dir():
        return Path(explicit).as_posix()
    return (ROOT / "tests" / "compat" / "vendor" / "open77_transactions").as_posix()


def scenario(name):
    return luahost.run_scenario("cargo_scenarios.lua", name, {"COMPAT_DIR": COMPAT, "CARGO_DIR": CARGO,
                                                              "TX_DIR": _tx_dir()})


@unittest.skipIf(luahost.unavailable(), luahost.unavailable())
class Cargo(unittest.TestCase):
    def check(self, results, expected):
        for key, value in expected.items():
            with self.subTest(case=key):
                self.assertEqual(results.get(key), value)

    def test_layout_data_file(self):
        r = scenario("layouts")
        self.check(r, {
            "loaded_log": "true",
            "mackinaw_slots": "4",
            "mackinaw_objects": "8",
            "mackinaw_measured": "true",              # integrator check 2026-10-12, two clients
            "alias_ncu": "Vehicle.v_standard3_thorton_mackinaw_02_player",
            "alias_pickup02": "Vehicle.v_standard25_thorton_colby_pickup_player",
            "unknown": "nil",
            "problems": "0",
            "unmeasured_slots": "12",          # the Mackinaw's 4 were checked on two clients; the rest are guesses
            "roundtrip": "ok",                 # cargolayout's JSON == the data file entry
            "v_ok": "ok",
        })
        self.assertIn("duplicate id", r["v_duplicate"])
        self.assertIn("x must be a number within", r["v_offset"])
        self.assertIn("26 objects", r["v_too_many"])
        self.assertIn("measured is true but", r["v_measured"])
        self.assertIn("capacityKg must be", r["v_capacity"])
        self.assertIn("maxStack must be an integer", r["v_stack"])
        # ammo boxes stack at their own height, not the crate.small step that left them floating
        self.assertEqual((r["stack_z"], r["stack_z_default"]), ("0.90/1.22/1.54", "0.90/1.45/2.00"))
        # ammo boxes on the floor (0.90 - 0.40), the second on the first, crate.small on both
        self.assertEqual(r["stack_z_seated"], "0.50/0.82/1.54")

    def test_slot_allocation_and_projection(self):
        self.check(scenario("allocation"), {
            "order": "1:1,2:1,3:1,4:1,1:2,2:2,3:2,4:2",
            "ninth": "nil:cargo_full",
            "ninth_where": "char:acct-1",
            "children": "8",
            "c5_offset": "-0.55,-1.5,1.45",    # slot 1, second layer: z + stackHeight
            "c2_offset": "0.55,-1.5,0.9",
            "c2_binding": "vehicle:true:",
            "model": "crate.small",
            "meta_slot": "1.1",
            "meta_origin_kept": "salvage",     # metaPatch merges, it does not replace
            "where_c1_01": "veh:NC-TRK1:cargo",
            "access_call": "true",
            "changed_events": "8",
            "too_heavy": "nil:capacity_exceeded",
            "heavy_where": "char:acct-1",
            "pickup_children": "0",
        })

    def test_stacking_and_unloading(self):
        self.check(scenario("stacking"), {
            "a": "ok:1:1",
            "b": "ok:1:2",
            "c_full": "nil:slot_full",
            "bad_slot": "nil:invalid_slot",
            "unload_a": "c1-01@1->char:acct-1",
            "b_settled_z": "0.9",              # the crate above settles to the bed floor
            "b_stored_layer": "2",             # the stored layer only orders the stack
            "c": "ok:1:3",
            "c_z": "1.45",
            "d": "ok:2:1",
            "unload_top": "c1-04",             # top of the last occupied slot
            "a_cargo_meta": "false",           # metaPatch { cargo = false }: merged, not deleted (697e9e2f); reads as no slot
            "a_origin": "salvage",
            "a_where": "char:acct-1",
            "empty": "nil:cargo_empty",
            "children": "0",
            "props": "0",
        })

    def test_refusals_move_nothing(self):
        self.check(scenario("refusals"), {
            "unload_empty": "nil:cargo_empty",
            "stranger": "nil:no_access",
            "garage_reason": "nil:impounded",
            "untracked": "nil:vehicle_not_tracked",
            "no_layout": "nil:no_cargo_layout",
            "not_found": "nil:vehicle_not_found",
            "bad_vehicle": "nil:invalid_vehicle_id",
            "bad_player": "nil:invalid_player_id",
            "too_far": "nil:too_far",
            "wrong_bucket": "nil:wrong_bucket",
            "moving": "nil:vehicle_moving",
            "bad_instance": "nil:invalid_instance",
            "not_mine": "nil:instance_unavailable",
            "bad_source": "nil:invalid_source",
            "bad_op": "nil:invalid_op_id",
            "unload_not_in": "nil:not_in_cargo",
            "unload_bad_destination": "nil:invalid_destination",
            "from_world": "ok:1:1",
            "store_down": "nil:store_unavailable",
            "store_down_where": "char:acct-1",
            "no_coordinator": "nil:coordinator_unavailable",
            "no_garage": "nil:garage_unavailable",
            "take_call": "true",
            "props": "1",
            "children": "1",
        })

    def test_concurrent_loads_get_distinct_slots(self):
        self.check(scenario("concurrency"), {
            "pair1": "ok:3:2|ok:4:2",
            "pair2": "ok:1:3|nil:cargo_full",
            "children": "8",
            "duplicate_place": "false",
            "loser_where": "char:acct-2",
        })

    def test_garage_store_and_take_out_restore_cargo(self):
        self.check(scenario("store_retrieve"), {
            "props_after_store": "0",
            "projection_after_store": "nil",
            "cargo_after_store": "3",
            "new_vehicle": "true",
            "children_new": "3",
            "same_slots": "true",
            "slots": "c1-01@1.1,c1-02@2.1,c1-03@3.1",
            "projection_vehicle": "true",
            "no_new_operation": "true",
        })

    def test_resource_restart_redraws(self):
        self.check(scenario("restart"), {
            "props_after_stop": "0",
            "children_after_restart": "2",
            "slots": "c1-01@1,c1-02@2",
        })

    def test_authority_handoff_and_bucket_change(self):
        self.check(scenario("bucket_authority"), {
            "authority_same_props": "true",
            "authority_no_operation": "true",
            "children_after_bucket": "2",
            "child_buckets": "7,7",
            "props_total": "2",
            "bucket_no_operation": "true",
        })

    def test_outcomes_in_doubt_keep_their_slot(self):
        self.check(scenario("in_doubt"), {
            "first": "nil:in_doubt",
            "first_where": "char:acct-1",
            "second": "ok:2:1",                # slot 1 still claimed by the op in doubt
            "third": "ok:1:1",                 # settled as aborted: slot 1 free again
            "fourth": "nil:in_doubt",
            "fourth_where": "veh:NC-TRK8:cargo",
            "children_before_settle": "2",
            "children_after_settle": "3",      # settled as committed by the sweep: drawn
            "fourth_slot": "3",
        })

    def test_retries_are_idempotent(self):
        self.check(scenario("replay"), {
            "first": "ok:1:1",
            "again": "ok:1:1:already",
            "no_new_operation": "true",
            "children": "1",
            "other_crate_same_op": "nil:op_id_conflict",
            "other_where": "char:acct-1",
            "stale_retried": "ok:2:1",
        })

    def test_other_resources_commits_are_drawn(self):
        self.check(scenario("external"), {
            "move_in": "ok",
            "slotless_drawn": "2.1",           # floor first: the empty slot 2
            "children_with_scrap": "2",
            "children_after_theft": "1",
            "c1_drawn": "false",
        })

    def test_lab_commands(self):
        self.check(scenario("lab"), {
            "one_layer": "4",
            "all_layers": "8",
            "player_ignored": "8",
            "tuned_lab_crates": "0.95@90.0,1.5@90.0",
            "printed_slot2": "0.6,-1.6,0.95,90.0,false",
            "printed_measured": "false",
            "tune_refusals": "2",
            "cleared": "0",
            "no_layout_log": "true",
            "cargo_follows_tune": "-0.5,-1.4,1.0",
            "info_header": "true",
            "info_slot1": "true",
        })

    def test_contents_view(self):
        self.check(scenario("contents"), {
            "objects": "3",
            "free": "5",
            "slot1": "c1-01:1",
            "account": "veh:NC-TRKC:cargo",
            "stranger": "nil:no_access",
            "view_call": "true",
        })


    def test_per_part_writers_and_pocket_grant(self):
        """A9 N4 with the final coordinator: writers `rp_cargo:veh/cargo`; the pockets need
        rp_inventory's one-operation grant (grantPockets), else nothing is attempted."""
        self.check(scenario("per_part_writers"), {
            "allowed_cargo": "true:nil",
            "allowed_trunk": "false:namespace_denied",
            "allowed_char": "false:namespace_denied",
            "no_grant": "nil:namespace_denied",
            "no_grant_ops": "0",
            "with_grant": "ok:1:1",
            "where": "veh:NC-TRKD:cargo",
            "unload": "ok:1:1",
            "where_after": "char:acct-1",
            "grants": "2",
        })

if __name__ == "__main__":
    unittest.main()
