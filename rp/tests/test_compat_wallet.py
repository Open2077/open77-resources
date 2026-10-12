"""B3 wallet suite: rp_economy and rp_bank as facades over the A13 transaction coordinator.

Run with `python -m unittest discover -s tests -p "test_compat*.py"` (Lua 5.4 engine: lupa, or a
lua54.dll such as the KeraLua NuGet cache's; see tests/compat/luahost.py). Offline only: no game,
no server, no database.

Each scenario boots, on tests/compat/multihost.lua, the coordinator prototype
(tests/compat/vendor/open77_transactions, or the folder named by OP77_TX_DIR) behind the test
stand-in tests/compat/txhost_wallet.lua, the real rp_economy (and rp_bank) server scripts, and caller
shims. The coordinator's memory store plays the database; tests/compat/wallet_world.lua holds the
1.x tables. Scenario code: tests/compat/wallet_scenarios.lua.

What this cannot show: SQL semantics on MariaDB (A13 I1-I3), live latency, anything in game.
"""
import hashlib
import os
import re
import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent / "compat"))
import luahost  # noqa: E402

ROOT = Path(__file__).resolve().parents[1]
COMPAT = ROOT / "tests" / "compat"
VENDOR = COMPAT / "vendor" / "open77_transactions"
WALLET_SOURCES = [
    "rp_economy/server/config.lua", "rp_economy/server/tx.lua", "rp_economy/server/mint.lua",
    "rp_economy/server/migrate.lua", "rp_economy/server/wallets.lua", "rp_economy/server/main.lua",
    "rp_bank/config.lua", "rp_bank/server/main.lua",
]


def tx_dir():
    explicit = os.environ.get("OP77_TX_DIR")
    if explicit and Path(explicit).is_dir():
        return Path(explicit)
    return VENDOR


def scenario(name):
    return luahost.run_scenario("wallet_scenarios.lua", name, {
        "ROOT_DIR": ROOT.as_posix(), "COMPAT_DIR": COMPAT.as_posix(), "TX_DIR": tx_dir().as_posix(),
    })


class VendoredCoordinator(unittest.TestCase):
    def test_vendored_coordinator_is_unmodified(self):
        """The copy is the final coordinator of Open77 697e9e2f: the manifest and every server
        script it lists match the git blob ids recorded in SOURCE.txt (LF content)."""
        source = (VENDOR / "SOURCE.txt").read_text(encoding="utf-8")
        self.assertIn("697e9e2f0045587e21907c95716a38cc5089a8a1", source)
        recorded = {}
        for line in source.splitlines():
            parts = line.split()
            if len(parts) == 2 and len(parts[0]) == 40 and parts[1].endswith(".lua"):
                recorded[parts[1]] = parts[0]
        manifest = (VENDOR / "open77.lua").read_text(encoding="utf-8")
        listed = {"open77.lua"} | set(re.findall(r'^server_script "([^"]+)"', manifest, re.M))
        self.assertEqual(set(recorded), listed)
        for rel, blob in recorded.items():
            data = (VENDOR / rel).read_bytes().replace(b"\r\n", b"\n")
            actual = hashlib.sha1(b"blob %d\0" % len(data) + data).hexdigest()
            self.assertEqual(actual, blob, f"{rel} differs from the recorded origin: refresh it, do not edit it")


@unittest.skipIf(luahost.unavailable(), luahost.unavailable())
class WalletFacade(unittest.TestCase):
    def run_ok(self, name):
        r = scenario(name)
        self.assertEqual(r.get("errors"), "0", r.get("first_error"))
        return r

    def test_sources_compile(self):
        lua = luahost.new_state()
        try:
            for rel in WALLET_SOURCES:
                source = (ROOT / rel).read_text(encoding="utf-8")
                lua.execute(f"assert(load({luahost.lua_string(source)}, {luahost.lua_string('@' + rel)}, 't'))",
                            "=compile")
        finally:
            lua.close()

    def test_legacy_add_remove_write_behind_and_land_once(self):
        r = self.run_ok("smoke")
        self.assertEqual(r["first"], "500")
        self.assertEqual(r["added"], "1500/nil")
        self.assertEqual(r["removed"], "1200/nil")
        self.assertEqual(r["durable"], "1200")
        self.assertEqual(r["display"], "1200")

    def test_new_refusal_tokens(self):
        r = self.run_ok("refusals")
        self.assertEqual(r["unlisted_mint"], "mint_denied")     # nothing mints by default
        self.assertEqual(r["unlisted_burn"], "value:490")       # burning is never refused
        self.assertEqual(r["untrusted_move"], "caller_denied")  # walletMove is rp_bank's only

    def test_replayed_sale_pays_once(self):
        r = self.run_ok("sale_replay_pays_once")
        self.assertEqual(r["first"], "ok")
        self.assertEqual(r["second"], "ok:replay")
        self.assertEqual(r["conflict"], "op_id_conflict")
        self.assertEqual(r["after_restart"], "ok:replay")
        self.assertEqual(r["new_intent_same_goods"], "insufficient_items")
        self.assertEqual(r["commits_total"], "1")
        self.assertEqual(r["cash"], "770")
        self.assertEqual(r["society"], "30")
        self.assertEqual((r["scrap"], r["component"]), ("0", "0"))
        self.assertEqual(r["journal"], "component:0,money:0,scrap:0")   # double entry per asset
        self.assertEqual(r["display"], "770")

    def test_split_payout_sums(self):
        r = self.run_ok("split_payout_sums")
        self.assertEqual(r["pay"], "ok")
        self.assertEqual(r["commits"], "1")
        self.assertEqual(r["receipt_lines"], "5")
        self.assertEqual(r["bad_split"], "invalid_split")
        self.assertEqual((r["driver"], r["rider1"], r["rider2"], r["society"]), ("1150", "550", "550", "90"))
        self.assertEqual(r["client_absorbed"], "-840")
        self.assertEqual(r["journal"], "money:0")
        self.assertEqual(r["net_minted"], "840")

    def test_crash_between_debit_and_credit(self):
        r = self.run_ok("crash_between_debit_and_credit")
        for mode in ("unreachable_before", "lost_ack", "detached", "discard"):
            with self.subTest(mode=mode):
                self.assertEqual(r[f"{mode}.conserved"], "yes")
        self.assertEqual(r["unreachable_before.sale"], "store_unavailable")
        self.assertEqual(r["unreachable_before.state"], "aborted")
        self.assertEqual(r["unreachable_before.goods_left"], "6")
        self.assertEqual(r["unreachable_before.replay"], "aborted")
        for mode in ("lost_ack", "detached"):
            with self.subTest(mode=mode):
                self.assertEqual(r[f"{mode}.sale"], "ok")
                self.assertEqual(r[f"{mode}.paid"], "270")
                self.assertEqual(r[f"{mode}.society"], "30")
                self.assertEqual(r[f"{mode}.replay"], "ok:replay")
                self.assertEqual(r[f"{mode}.display"], "270")
        self.assertEqual(r["discard.sale"], "aborted")
        self.assertEqual(r["discard.goods_left"], "6")
        self.assertEqual(r["discard.paid"], "0")
        self.assertEqual(r["deposit.result"], "200/nil")
        self.assertEqual((r["deposit.cash"], r["deposit.bank"], r["deposit.total"]), ("300", "200", "500"))

    def test_offline_credit(self):
        r = self.run_ok("offline_credit")
        self.assertEqual(r["pay"], "ok")
        self.assertEqual(r["away_durable"], "250")
        self.assertEqual(r["away_on_join"], "250")
        self.assertEqual(r["charge"], "ok")
        self.assertEqual(r["refund_offline"], "ok")
        self.assertEqual(r["customer_durable"], "500")
        self.assertEqual(r["barman"], "0")
        self.assertEqual(r["wire_from_empty_bank"], "insufficient_funds")

    def test_sync_callers_keep_their_contract(self):
        r = self.run_ok("sync_callers")
        self.assertEqual(r["rp_jobs"], "payroll_cash=900;payroll_society=49600;seed=50000")
        self.assertEqual(r["rp_ferrailleur"], "crowbar=650;crowbar_society=250;too_poor=insufficient_funds")
        self.assertEqual(r["rp_nomade"], "deposit=550;refund=650")
        self.assertEqual(r["rp_admin"],
                         "account=0;overdraw_bank=insufficient_funds;read=true:650;setbank=300;setmoney=1650")
        self.assertEqual(r["rp_shops"], "buy=1290;cash_short=insufficient_funds;share=42;withdraw=insufficient_funds")
        self.assertEqual(r["rp_garage"], "cash=1190;charge=200;society=200")
        self.assertEqual(r["rp_hud"], "bank=200;cash=1190")
        self.assertEqual(r["display_cash"], r["durable_cash"])
        self.assertEqual(r["durable_bank"], "200")
        self.assertEqual((r["society_mecano"], r["society_ferrailleur"], r["society_garage"]), ("49600", "250", "200"))
        self.assertEqual(r["net_minted_rp_jobs"], "50000")   # the seed; payroll nets to zero
        self.assertEqual(r["net_minted_rp_nomade"], "0")     # deposit and refund net to zero
        self.assertEqual(r["write_behind_failed"], "0")
        self.assertEqual(r["hud_changed_events"], "9")
        self.assertEqual(r["hud_bank_events"], "8")

    def test_refused_write_behind_is_reverted_and_logged(self):
        r = self.run_ok("writebehind_refused")
        self.assertEqual(r["accepted"], "100/nil")
        self.assertEqual(r["durable"], "0")
        self.assertEqual(r["display"], "0")
        self.assertEqual(r["refused_logged"], "1")

    def test_bank_facade(self):
        r = self.run_ok("bank_facade")
        self.assertEqual(r["account"], "balance:0")
        self.assertEqual(r["deposit_short"], "nil:insufficient_cash")
        self.assertEqual(r["deposit"], "400")
        self.assertEqual(r["withdraw_short"], "nil:insufficient_funds")
        self.assertEqual(r["withdraw"], "300")
        self.assertEqual(r["transfer"], "148")
        self.assertEqual(r["transfer_unknown"], "nil:unknown_recipient")
        self.assertEqual(r["transfer_self"], "nil:self_transfer")
        self.assertEqual(r["charge"], "98")
        self.assertEqual(r["society_after"], "balance:50")
        self.assertEqual(r["society_remove_short"], "nil:insufficient_funds")
        self.assertEqual(r["society_remove"], "30")
        self.assertEqual(r["society_unknown_debit"], "nil:bank_not_ready")   # funds unknown yet
        self.assertEqual(r["society_unknown_credit"], "7")                    # a credit is safe
        self.assertEqual((r["soc_new"], r["soc_new_read"]), ("7", "balance:7"))
        self.assertEqual(r["amount_too_large"], "nil:amount_too_large")
        self.assertEqual((r["cash_a"], r["bank_a"], r["bank_b"], r["soc_ncpd"]), ("200", "98", "150", "30"))
        self.assertEqual(r["fee_burned"], "2")
        self.assertEqual(r["total"], "1000")                  # 2 x 500 start, conserved

    def test_invoice_paid_once_and_refunded_to_the_original_instruments(self):
        r = self.run_ok("invoice_and_refund")
        self.assertEqual(r["invoice"], "ok")
        self.assertEqual(r["invoice_replay"], "ok:replay")
        self.assertEqual((r["after_bill_cash"], r["after_bill_bank"]), ("0", "100"))   # cash first, then bank
        self.assertEqual((r["mechanic"], r["society_after_bill"]), ("280", "120"))
        self.assertEqual(r["refund"], "ok")
        self.assertEqual(r["refund_again"], "ok:replay")
        self.assertEqual((r["cash"], r["bank"]), ("200", "300"))
        self.assertEqual((r["mechanic_after"], r["society"]), ("0", "0"))

    def test_mint_allowlist_and_hourly_cap(self):
        r = self.run_ok("mint_window")
        self.assertEqual(r["under_cap"], "ok")
        self.assertEqual(r["over_cap"], "mint_cap")
        self.assertEqual(r["burn"], "ok")
        self.assertEqual(r["after_burn"], "ok")
        self.assertEqual(r["net"], "900")
        self.assertEqual(r["next_window"], "ok")
        self.assertEqual(r["unlisted"], "mint_denied")
        self.assertEqual(r["durable"], "3600")      # 500 + 600 - 200 + 500 + 1000 + 6 paydays

    def test_migration_golden_fixture(self):
        r = self.run_ok("migration_golden")
        self.assertEqual(r["state_before"], "pending")
        self.assertEqual(r["join_before"], "0")
        self.assertEqual(r["add_before"], "player_not_found")
        self.assertEqual(r["state"], "complete")
        self.assertEqual(r["state_row"], "complete")
        self.assertEqual(r["summary"], "subjects=4 societies=3 imported=5 already=0 empty=2 skipped=2 failed=0")
        self.assertEqual((r["cash_a"], r["bank_a"], r["cash_b"], r["cash_c"], r["bank_d"]),
                         ("1500", "300", "0", "250", "700"))
        self.assertEqual((r["soc_ferrailleur"], r["soc_nomade"]), ("1200", "10"))
        self.assertEqual(r["join_a"], "1500")
        self.assertEqual(r["join_b_no_start_grant"], "0")
        self.assertEqual(r["join_new_start_grant"], "500")
        self.assertEqual(r["skipped_logged"], "2")
        self.assertEqual(r["journal_a"], "money:0")
        self.assertEqual(r["ledger_rows"], "2")                 # the 1.x ledger is left as an archive
        self.assertEqual(r["rerun"], "imported=0 already=5")    # idempotent
        self.assertEqual((r["cash_a_after_rerun"], r["soc_after_rerun"]), ("1500", "1200"))
        self.assertEqual(r["kvp_differs"], "2")
        self.assertEqual(r["kvp_only_imported"], "0")           # KVP is reported, never imported
        self.assertEqual(r["newer_state"], "blocked")
        self.assertEqual(r["newer_join"], "0")

    def test_migration_reads_past_the_10000_row_truncation(self):
        r = self.run_ok("migration_truncation")
        self.assertEqual(r["legacy_boot_rows"], "10000")        # rp_bank 1.x boot load, silently cut
        self.assertEqual(r["truncated_reads"], "1")             # ...and only that read was cut
        self.assertEqual(r["state"], "complete")
        self.assertEqual(r["subjects_imported"], "10050")
        self.assertEqual(r["cash_total"], r["expected_total"])

    def test_final_coordinator_api(self):
        """Open77 697e9e2f as the wallet adapters use it (contract 7.2, 12.5, 12.6, 13.5)."""
        r = self.run_ok("final_api")
        # Mint rules: one sys: segment per rule, so `sys:rp_economy:start` cannot be named (logged
        # and ignored); without a rule a legacy credit is refused at once (allowed), an atomic
        # one by the coordinator, and burns go through. The reason reaches the journal.
        self.assertEqual(r["rule_ignored"], "1")
        self.assertEqual(r["start_grant"], "200")             # seeded; the 500 grant was refused
        self.assertEqual(r["add_without_rule"], "nil/mint_denied")
        self.assertEqual(r["burn_without_rule"], "150/nil")
        self.assertEqual(r["pay_without_rule"], "mint_denied")
        self.assertEqual(r["durable"], "150")
        self.assertEqual(r["net_minted_after_refusals"], "-50")   # budgets given back
        self.assertEqual(r["journal_reasons"], "fine")
        self.assertEqual(r["pending_changed"], "7")           # rp_economy:pendingChanged (B7)
        # Strict writers: a sale out of the pockets asks rp_inventory for a one-operation grant
        # (grantPockets); without rp_inventory it is refused before anything is attempted.
        self.assertEqual(r["sale_without_grant"], "namespace_denied")
        self.assertEqual(r["grant"], "1")
        self.assertEqual(r["sale_with_grant"], "ok")
        self.assertEqual(r["after_grant"], "0/270/30")
        # A unique unit sold out of a truck bed (C1): one instance line.
        self.assertEqual(r["instance_sale"], "ok:sys:rp_salvage:buyer:100/20")
        self.assertEqual(r["instance_invalid"], "invalid_instance")
        self.assertEqual(r["salvage_minted"], "120")          # rp_salvage is on the allowlist
        # A character provider keys wallets, online and offline; the 1.x key stays the identifier.
        self.assertEqual(r["provider_cash"], "cash:acct-a~1")
        self.assertEqual(r["provider_start"], "500/0")
        self.assertEqual(r["provider_offline"], "ok:25")


if __name__ == "__main__":
    unittest.main()
