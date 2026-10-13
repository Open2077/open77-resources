"""B1/B2 inventory suite (world-interaction rows B1 and B2), offline.

Run with `python -m unittest discover -s tests -p "test_compat*.py"`. Needs a Lua 5.4 engine
(tests/compat/luahost.py: lupa, or a lua54.dll such as the KeraLua NuGet cache's). Each test skips
with the reason when there is none.

What runs: the REAL rp_inventory server scripts (both backends) on the B8 fake host
(tests/compat/fakehost.lua + txhost.lua), against the REAL, final A13 coordinator: the vendored
copy of Open77 697e9e2f (tests/compat/vendor/open77_transactions, or the folder named by
OP77_TX_DIR), server/main.lua included, on tests/compat/txsandbox.lua, with its memory store and
fault injection playing the database. Nothing here was run against a database or in game: these
are offline contract tests, not proof of in-game behaviour.
"""
import os
import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent / "compat"))
import luahost  # noqa: E402

ROOT = Path(__file__).resolve().parents[1]
HARNESS = ROOT / "tests" / "compat"


def _tx_dir():
    for name in ("OP77_TX_DIR", "OP77_TX_ROOT"):
        explicit = os.environ.get(name)
        if explicit and Path(explicit).is_dir():
            return Path(explicit)
    return HARNESS / "vendor" / "open77_transactions"


TX_DIR = _tx_dir()


def _skip_reason():
    reason = luahost.unavailable()
    if reason:
        return reason
    if not (TX_DIR / "server" / "main.lua").is_file():
        return f"open77_transactions not found at {TX_DIR} (set OP77_TX_DIR)"
    return None


SKIP = _skip_reason()


def scenario(name):
    return luahost.run_scenario("inventory_scenarios.lua", name, {
        "REPO": ROOT.as_posix(), "HARNESS": HARNESS.as_posix(), "TX_DIR": TX_DIR.as_posix()})


@unittest.skipIf(SKIP, SKIP)
class B1Definitions(unittest.TestCase):
    def test_existing_definitions_import_unchanged(self):
        r = scenario("b1_definitions")
        self.assertEqual(r["builtins"], "17")
        self.assertEqual(r["builtin_rejected"], "none")
        self.assertEqual(r["builtin_fields_unchanged"], "true")
        self.assertEqual(r["chip_weightG"], "50")
        # Every definer of the pack, with its real shared config, registers everything.
        # rp_fixer 2.0 defines no item any more (its two 1.0 gig items are gone).
        for definer, expected in {"rp_bar": "7/0", "rp_crime": "1/0", "rp_ferrailleur": "1/0",
                                  "rp_gangs": "1/0", "rp_mecano": "2/0", "rp_netrunner": "4/0",
                                  "rp_nomade": "2/0", "rp_ripperdoc": "7/0"}.items():
            self.assertEqual(r["def_" + definer], expected, definer)
        self.assertEqual(r["registry_count"], "42")
        self.assertEqual(r["selftest"], "1/1")           # rp_selftest reads counts
        self.assertEqual(r["redefine_same_definer"], "1/0")

    def test_collisions_and_id_rules_are_refused(self):
        r = scenario("b1_definitions")
        self.assertEqual(r["collision"], "0/2:stolen_parts,water")
        self.assertEqual(r["water_label_kept"], "Bottle of water")
        self.assertEqual(r["id_rules"], "0/5")
        self.assertEqual(r["reason_long"], "id_too_long")
        self.assertEqual(r["reason_reserved"], "reserved_id")
        self.assertEqual(r["reason_upper"], "invalid_id")
        self.assertEqual(r["reason_heavy"], "invalid_weight")
        self.assertEqual(r["reason_nolabel"], "invalid_label")

    def test_metadata_schema_and_stack_variants(self):
        r = scenario("b1_definitions")
        self.assertEqual(r["v1"], "4/5")
        self.assertEqual(r["v1_badtype"], "invalid_meta_field")
        self.assertEqual(r["v1_badstack"], "stack_field_unbounded")
        self.assertEqual(r["v1_contradiction"], "unique_required")
        self.assertEqual(r["v1_reserved"], "reserved_meta_field")
        self.assertEqual(r["v1_badprop"], "invalid_prop")
        self.assertEqual((r["tool_unique"], r["note_unique"], r["ore_unique"]), ("true", "true", "false"))
        # Stacks merge only with equal metadata; defaults keep the plain id.
        self.assertEqual(r["asset_ore_plain"], "ore")
        self.assertEqual(r["asset_ore_q1"], "ore")
        self.assertEqual(r["asset_ore_q3"], "ore__quality_3")
        self.assertEqual(r["asset_ore_q3_again"], "ore__quality_3")
        self.assertEqual(r["asset_paint_blue"], "paint__colour_blue")
        self.assertEqual(r["decode_q3"], 'ore:{"quality":3}')
        self.assertEqual(r["decode_bogus"], "nil")
        # Unknown or invalid metadata is refused.
        self.assertEqual(r["asset_ore_q9"], "nil:invalid_meta")
        self.assertEqual(r["asset_ore_unknown"], "nil:unknown_meta_field")
        self.assertEqual(r["asset_tool_serial"], "nil:serial_reserved")
        self.assertEqual(r["asset_tool_wear"], "nil:invalid_meta")
        self.assertEqual(r["asset_note_long"], "nil:invalid_meta")
        self.assertEqual(r["tool_default_meta"], '{"durability":20}')
        self.assertEqual(r["tx_variants"], "ok")
        self.assertEqual(r["tx_tool_unique"], "true")

    def test_shape_freeze_under_the_transactions_backend(self):
        r = scenario("b1_definitions")
        self.assertEqual(r["freeze_weight"], "0/1:definition_changed")
        self.assertEqual(r["freeze_label"], "1/0")

    def test_catalogue_is_bounded_versioned_and_verified(self):
        r = scenario("b1_definitions")
        self.assertEqual(r["cat_pages"], "1")
        self.assertEqual(r["cat_page_bytes_ok"], "true")
        self.assertEqual(r["cat_page_items_ok"], "true")
        self.assertEqual(r["cat_assemble"], "ok")
        self.assertEqual(r["cat_no_effect"], "true")
        self.assertEqual(r["cat_version_stable"], "true")
        self.assertEqual(r["cat_version_bumped"], "true")
        self.assertEqual(r["cat_tamper"], "hash_mismatch")
        self.assertEqual(r["cat_missing"], "missing_page")
        self.assertEqual(r["bulk"], "4096/0")
        self.assertEqual(r["bulk_full"], "registry_full")
        self.assertEqual(r["bulk_pages"], "64")

    def test_catalogue_transfer(self):
        r = scenario("b1_catalogue_transfer")
        self.assertEqual(r["head_on_join"], "true")
        self.assertEqual(r["broadcasts"], "1")            # two define calls, one coalesced push
        self.assertEqual(r["broadcast_version"], "true")
        self.assertEqual(r["client_assemble"], "ok")
        self.assertEqual(r["client_has_ore"], "true")
        self.assertEqual(r["stale"], "rp_inventory:catalogue")
        self.assertEqual(r["served_of_50"], "6")          # pages * 2 + 4 per version
        self.assertEqual(r["page_bounds"], "true")


@unittest.skipIf(SKIP, SKIP)
class B2Facade(unittest.TestCase):
    def test_existing_exports_answer_the_same_on_both_backends(self):
        legacy = scenario("b2_compat_legacy")
        tx = scenario("b2_compat_transactions")
        self.assertEqual(legacy.pop("backend"), "legacy")
        self.assertEqual(tx.pop("backend"), "transactions")
        # The journal names who minted and burned: the calling resource, the admin, /use.
        self.assertEqual(tx.pop("sys_accounts"), "sys:admin,sys:compat_test,sys:used")
        self.assertEqual(tx, legacy)
        self.assertEqual((tx["after_use"], tx["after_give"], tx["give_too_far"]), ("1", "0+1", "1+1"))
        self.assertEqual(tx["after_restart_burrito"], "1+1")
        self.assertEqual(tx["events"],
                         "7:water:2,7:crate:1,7:water:-1,7:burrito:2,7:burrito:-1,7:burrito:-1,7:burrito:1,7:water:1")
        self.assertEqual(tx["add_crate_again"], "nil:too_heavy")
        self.assertEqual(tx["remove_too_many"], "nil:not_enough")
        self.assertEqual(tx["unknown_player"], "nil:player_not_found")
        self.assertEqual(tx["bad_player"], "nil:invalid_player")
        self.assertEqual(tx["selftest_define"], "1/1")
        self.assertEqual(tx["meta_unknown"], "nil:unknown_meta_field")
        self.assertEqual((tx["persisted_water"], tx["after_restart_water"]), ("2", "2"))
        self.assertEqual(tx["kvp_keys"], "0")

    def test_concurrent_pickup_has_one_winner(self):
        r = scenario("b2_concurrent_pickup")
        self.assertEqual(r["winner"], "table")
        self.assertEqual(r["loser_before_commit"], "nil:not_enough")
        self.assertEqual((r["a_crates"], r["b_crates"], r["world_left"], r["store_total"]), ("1", "0", "0", "1"))
        # Against another resource on the coordinator: the first reservation wins.
        self.assertEqual(r["foreign_first"], "table")
        self.assertEqual(r["inventory_second"], "nil:not_enough")
        self.assertEqual((r["b_crates_after"], r["store_total_after"]), ("0", "2"))
        self.assertEqual(r["journal_balanced"], "true")

    def test_full_inventory_refuses_and_conserves(self):
        r = scenario("b2_full_inventory")
        self.assertEqual(r["b_take"], "nil:too_heavy")
        self.assertEqual(r["a_take"], "nil:too_heavy")
        self.assertEqual(r["a_take_decided_by"], "capacity_exceeded")   # the coordinator, not the view
        self.assertEqual(r["world_crates"], "1")
        self.assertEqual(r["give_full"], "nil:target_too_heavy")
        self.assertEqual(r["store_full"], "nil:stash_full")
        self.assertEqual((r["a_scrap"], r["b_scrap"]), ("14", "14"))
        self.assertEqual(r["ops_added"], "1")             # only the foreign credit committed
        self.assertEqual(r["crates_total"], "3")
        self.assertEqual(r["a_view_crates"], "1")         # the foreign commit reached the view
        self.assertEqual(r["journal_balanced"], "true")

    def test_give_between_players_is_atomic(self):
        r = scenario("b2_give_atomic")
        self.assertEqual((r["give"], r["give_opId"]), ("table", "yes"))
        self.assertEqual((r["a_burrito"], r["b_burrito"]), ("2/2", "2/2"))
        self.assertEqual(r["events"], "7:burrito:-2,8:burrito:2")
        self.assertEqual(r["give_heavy"], "nil:target_too_heavy")
        self.assertEqual(r["a_crate"], "1")
        self.assertEqual((r["give_lost_ack"], r["after_lost_ack"]), ("table", "1+3"))
        self.assertEqual((r["give_unreachable"], r["after_unreachable"]), ("nil:store_unavailable", "1+3"))
        self.assertEqual((r["give_retry"], r["after_retry"]), ("table", "0+4"))
        self.assertEqual((r["same_opid"], r["water"]), ("table,true", "1+1"))
        self.assertEqual(r["total_burrito"], "4")
        self.assertEqual(r["journal_balanced"], "true")

    def test_crash_between_steps_conserves_every_unit(self):
        r = scenario("b2_crash_between_steps")
        self.assertEqual(len(r), 21)
        for case, line in r.items():
            with self.subTest(case=case):
                self.assertTrue(line.startswith("true "), line)
        # Outcomes by window (the store fault decides, the inventory never invents one).
        self.assertIn(" table ", r["give_lost_ack"])
        self.assertIn(" nil:store_unavailable ", r["give_unreachable_before"])
        self.assertIn(" nil:store_failed ", r["take_failed"])
        self.assertIn(" table ", r["store_coordinator_crash"])

    def test_write_behind_is_ordered_resynced_and_never_kvp(self):
        r = scenario("b2_write_behind")
        self.assertEqual((r["view_now"], r["store_now"]), ("2", "0"))
        self.assertEqual((r["store_after"], r["ops"]), ("2", "3"))
        self.assertEqual(r["foreign_drain"], "table")
        self.assertEqual((r["after_drain_view"], r["after_drain_store"]), ("0", "0"))
        self.assertEqual(r["drain_events"], "7:water:-2,7:water:2,7:water:-2")
        self.assertEqual(r["add_while_down"], "nil:store_unavailable")
        self.assertEqual(r["remove_while_down"], "nil:store_unavailable")
        self.assertEqual(r["reads_while_down"], "1/true")
        self.assertEqual(r["kvp_keys"], "0")
        self.assertEqual(r["add_after_restart"], "true")
        self.assertEqual(r["store_final"], "2")
        self.assertEqual(r["after_inventory_restart"], "2/2")
        self.assertEqual((r["add_before_disconnect"], r["add_after_reconnect"]), ("true", "true"))
        self.assertEqual(r["reconnect"], "4/4")
        self.assertEqual(r["journal_balanced"], "true")

    def test_metadata_instances_and_wear_persist(self):
        r = scenario("b2_meta_and_wear")
        self.assertEqual(r["define"], "2/0")
        self.assertEqual((r["store_plain"], r["store_q3"], r["count_ore"]), ("2", "3", "5"))
        self.assertEqual(r["add_q9"], "nil:invalid_meta")
        self.assertEqual(r["add_unknown_meta"], "nil:unknown_meta_field")
        self.assertEqual(r["after_remove"], "0+2")
        self.assertEqual(r["tool_meta"], "dur=3 serial=true")
        self.assertEqual((r["wear1"], r["store_wear"]), ("dur=2 broken=false", "2"))
        self.assertEqual(r["wear_keeps_serial"], "true")     # a metaPatch: the serial is kept
        self.assertEqual(r["wear_view"], "2 serial=true")      # and the view follows (B7 F1)
        self.assertEqual(r["after_restart"], "1 dur=2")
        self.assertEqual(r["wear2"], "dur=0 broken=true")
        self.assertEqual(r["tool_after_break"], "0 in=sys:broken")
        self.assertEqual((r["tool_instances"], r["tool_instances_after"]), ("2", "1"))
        self.assertEqual(r["legacy_meta_variant"], "nil:meta_unsupported")
        self.assertEqual(r["legacy_meta_default"], "true")
        self.assertEqual(r["legacy_meta_unknown"], "nil:unknown_meta_field")
        self.assertEqual(r["journal_balanced"], "true")

    def test_durable_keys_and_authorization_hooks(self):
        r = scenario("b2_keys_and_auth")
        self.assertEqual(r["stash_digits"], "nil:runtime_id_key")
        self.assertEqual(r["stash_session"], "nil:session_key")
        self.assertEqual(r["stash_runtime"], "nil:runtime_id_key")
        self.assertEqual(r["stash_home"], "true")
        self.assertEqual(r["veh_digits"], "nil:runtime_id_key")
        self.assertEqual(r["veh_plate"], "veh:NC-1234:trunk")
        self.assertEqual(r["veh_part"], "nil:invalid_part")
        self.assertEqual(r["world_digits"], "nil:invalid_world_id")
        self.assertEqual(r["account_of"], "char:acct-a")
        self.assertEqual(r["move_digit_char"], "nil:runtime_id_key")
        self.assertEqual(r["move_session_char"], "nil:session_key")
        # Vehicles fail closed; the registered authorizer decides per player and action.
        self.assertEqual(r["veh_before_open"], "nil:not_authorized")
        self.assertEqual(r["veh_no_authorizer"], "nil:not_authorized")
        self.assertEqual(r["register"], "true")
        self.assertEqual(r["register_taken"], "nil:authorizer_taken")
        self.assertEqual(r["register_bad_scope"], "nil:invalid_scope")
        self.assertEqual(r["veh_owner"], "table")
        self.assertEqual(r["request"], "store:veh:NC-1234:trunk:NC-1234")
        self.assertEqual(r["veh_stranger"], "nil:not_authorized")
        self.assertEqual(r["veh_untracked"], "nil:vehicle_not_tracked")
        self.assertEqual(r["veh_owner_take"], "table")
        self.assertEqual(r["trunk"], "1")
        self.assertEqual(r["after_stop"], "nil:not_authorized")
        self.assertEqual(r["stash_store"], "table")
        self.assertEqual(r["stash_take_revoked"], "nil:not_authorized")
        self.assertEqual(r["other_prefix"], "table")
        self.assertEqual(r["journal_balanced"], "true")

    def test_drop_is_a_world_container(self):
        r = scenario("b2_drop_pickup")
        self.assertEqual(r["after_drop"], "0/1")
        self.assertEqual(r["refused_pickup"], "1/1")      # B keeps its own crate; the drop stays
        self.assertEqual(r["reprojected_at_origin"], "true")
        self.assertEqual(r["picked"], "1/0")
        self.assertEqual(r["crates_total"], "2")
        self.assertEqual(r["expired"], "0 ops=1")
        self.assertEqual(r["closed_after_pickup"], "true")       # an emptied world: container is closed
        # The coordinator mints the id and keeps the drop's metadata and expiry...
        self.assertEqual(r["drop_id_minted"], "true")
        self.assertEqual(r["drop_meta"], "rp_inventory:drop:scrap:2")
        self.assertEqual(r["drop_expires"], "true")
        # ...so a restart that lost the loot projects it again where it lay, and it can be picked up.
        self.assertEqual(r["after_restart_scrap_total"], "16")
        self.assertEqual(r["reprojected_after_restart"], "true")
        self.assertEqual(r["reprojected_where"], "0,0")
        self.assertEqual(r["picked_after_restart"], "2 closed=true")
        self.assertEqual(r["world_rows_left"], "0")
        self.assertEqual(r["journal_balanced"], "true")

    def test_in_doubt_drop_and_pickup_settle_their_projection(self):
        """B7 finding F2: an in_doubt drop no longer loses its projection."""
        r = scenario("b2_drop_in_doubt")
        # committed, answer lost: in_doubt to the player, projected once settled, where it lay
        self.assertEqual(r["drop_committed"], "answered 2 loot=1")
        self.assertEqual(r["drop_projected_at"], "0,0")
        # a pickup committed with its answer lost is not re-projected
        self.assertEqual(r["pickup_committed"], "2 loot=0")
        # a fenced drop moved nothing, projects nothing, and its empty container is closed
        self.assertEqual(r["drop_fenced"], "2 loot=0 world_rows=0")
        self.assertEqual(r["settled_events"], "committed,committed,aborted")   # rp_inventory:settled
        self.assertEqual((r["total"], r["journal_balanced"]), ("4", "true"))

    def test_final_coordinator_api(self):
        """Open77 697e9e2f: the semantics the facade now relies on (contract 7.2 and 13.5)."""
        r = scenario("b2_final_api")
        # subjectOf: one override provider keys the pockets; its refusal is passed through.
        self.assertEqual((r["provider"], r["provider_second"]), ("true", "nil:provider_already_registered"))
        self.assertEqual((r["subject_a"], r["subject_b"]), ("char:acct-a~2", "nil:no_character"))
        self.assertEqual((r["add_a"], r["add_b"]), ("true", "nil:not_loaded"))
        self.assertEqual(r["subject_store"], "1/0")
        # Mint rules: an unlisted sys: source is refused at once (allowed), a burn never is; over
        # the hourly cap the coordinator refuses and the write-behind change is compensated.
        self.assertEqual((r["mint_listed"], r["mint_unlisted"], r["burn_unlisted"]), ("true", "nil:mint_denied", "true"))
        self.assertEqual(r["mint_over_cap"], "true")
        self.assertEqual(r["mint_over_cap_store"], "2")
        self.assertEqual(r["mint_over_cap_events"], "7:water:1,7:water:-1")
        self.assertEqual(r["allowed_money"], "false")
        # Per-part writers: trunk yes, cargo bed no.
        self.assertEqual((r["part_trunk"], r["part_cargo"]), ("table", "nil:namespace_denied"))
        self.assertEqual(r["allowed_cargo"], "false:namespace_denied")
        # grantPockets: a job without the char right credits the pockets in one granted operation.
        self.assertEqual(r["job_without_grant"], "nil:namespace_denied")
        self.assertEqual((r["grant_pockets"], r["grant_not_allowed"]), ("true", "nil:caller_not_allowed"))
        self.assertEqual((r["job_with_grant"], r["job_view"]), ("table", "2"))
        # Lazy read: absent, and not created by the read.
        self.assertEqual((r["lazy_read"], r["lazy_read_created"]), ("false", "false"))
        # World ids are minted, never chosen; the caller's metadata is kept.
        self.assertEqual(r["world_chosen_id"], "nil:invalid_world_id")
        self.assertEqual((r["world_minted"], r["world_meta"]), ("true", "crate"))
        # A failed opId is a fresh attempt; a fenced one stays aborted, a new id works.
        self.assertEqual((r["failed_first"], r["failed_same_id"]), ("nil:store_unavailable", "table"))
        self.assertEqual(r["fenced_first"], "nil:store_unavailable:aborted")
        self.assertEqual((r["fenced_same_id"], r["fenced_new_id"]), ("nil:aborted", "table"))
        self.assertEqual(r["water"], "2+2")
        # info().ready gates the handshake.
        self.assertEqual((r["late_info"], r["late_ready_lines"], r["late_create"]), ("starting", "0", "nil:store_unavailable"))
        self.assertEqual((r["late_ready_after"], r["late_create_after"]), ("1", "table"))
        self.assertEqual((r["journal_balanced"], r["kvp_keys"]), ("true", "0"))


@unittest.skipIf(SKIP, SKIP)
class B2Migration(unittest.TestCase):
    def test_golden_fixture_imports_once(self):
        r = scenario("b2_migration")
        self.assertEqual(r["golden"], "ok")
        self.assertEqual(r["first_run"],
                         "char acct-c: unknown_items | stash 12: runtime_id_key | 8 subject(s) visited, 6 ok, 2 refused")
        self.assertEqual(r["markers"], "true,true,false,true,true,true,false")
        self.assertEqual(r["marker_version"], "1")
        self.assertEqual(r["chunks_acct_e"], "2")
        self.assertEqual(r["migrate_ops"], "6")
        self.assertEqual(r["legacy_untouched"], "true")
        self.assertEqual(r["journal_balanced"], "true")
        self.assertEqual(r["kvp_keys"], "0")

    def test_rerun_is_idempotent_even_after_a_crash(self):
        r = scenario("b2_migration")
        self.assertEqual(r["second_run_ops"], "0/0")
        self.assertEqual(r["golden_after_rerun"], "ok")
        self.assertTrue(r["crash_marker"].startswith("refused: marker_write_failed"), r["crash_marker"])
        self.assertEqual(r["crash_store"], "2")
        self.assertTrue(r["crash_rerun"].startswith("acct-f: migrated"), r["crash_rerun"])
        self.assertEqual(r["crash_store_after"], "2 marker=true")
        # A fenced attempt can never commit: the run moves to the next deterministic attempt id.
        self.assertTrue(r["fenced_first_attempt"].startswith("acct-v: migrated"), r["fenced_first_attempt"])
        self.assertEqual(r["fenced_ops"], "aborted,committed")
        self.assertTrue(r["failed_first_run"].startswith("refused: store_failed"), r["failed_first_run"])
        self.assertTrue(r["failed_rerun"].startswith("acct-w: migrated"), r["failed_rerun"])
        # Lost markers: the rerun finds every commit (unique instances, the .a2 attempt), adds nothing.
        self.assertEqual(r["after_marker_loss"], "3,2,0,1")

    def test_unique_items_import_as_derived_instances(self):
        r = scenario("b2_migration")
        self.assertIn('"instances":3', r["unique_import"])
        self.assertEqual(r["unique_instances"], "mig1.<h>.tool_u.1=5s,mig1.<h>.tool_u.2=5s,mig1.<h>.tool_u.3=5s")

    def test_explicit_refusals(self):
        r = scenario("b2_migration")
        self.assertTrue(r["acct_c_default"].startswith("refused: unknown_items"), r["acct_c_default"])
        self.assertTrue(r["version_mismatch"].startswith("refused: migration_version_mismatch"), r["version_mismatch"])
        self.assertEqual(r["lab_store_reported"], "lab_kvp")    # info().store of the real coordinator
        self.assertTrue(r["not_durable"].startswith("refused: store_not_durable"), r["not_durable"])
        self.assertTrue(r["schema_mismatch"].startswith("refused: source_schema_mismatch"), r["schema_mismatch"])
        self.assertTrue(r["no_mint_rule"].startswith("refused: mint_denied"), r["no_mint_rule"])
        self.assertEqual(r["no_mint_rule_store"], "0 marker=false")
        self.assertEqual(r["diverged"], "0 nil:not_loaded")
        self.assertEqual(r["diverged_reason"], "legacy_diverged")
        self.assertEqual(r["accept"], "char:acct-a: the imported state is kept")
        self.assertEqual(r["after_accept"], "3")

    def test_imported_pockets_load_and_obey_capacity(self):
        r = scenario("b2_migration")
        self.assertEqual(r["load_a"], "3/1")
        self.assertEqual(r["load_b"], "2 capacity=40000")
        self.assertEqual(r["b_add"], "nil:too_heavy")      # over capacity after import: only emptying
        self.assertEqual(r["b_remove"], "true")
        self.assertIn('"unknown":["ghost_item"]', r["acct_c_import_unknown"])
        self.assertEqual(r["ghost_store"], "4")


if __name__ == "__main__":
    unittest.main()
