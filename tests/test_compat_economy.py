"""B8 compatibility suite, executable half: rp_economy's real server scripts, run offline.

Run with `python -m unittest discover -s tests -p "test_compat*.py"`. Needs a Lua 5.4 engine
(see tests/compat/luahost.py: lupa, or a lua54.dll such as the KeraLua NuGet cache's); the
tests skip with the reason when there is none.

Since B3 (rp_economy 2.0.0) the resource is a facade over the open77_transactions coordinator:
the scenarios run on tests/compat/multihost.lua with the coordinator prototype
(tests/compat/vendor/open77_transactions, or OP77_TX_DIR) behind tests/compat/txhost_wallet.lua.

Gap R1 (docs/world-interaction/b8-compat-audit.md): 1.x fell back to KVP for a whole boot when the
database was unavailable, started every player from the starting balance, and never merged what
was earned during that boot back into SQL. The expected failure that stated the invariant is now a
plain test: an outage refuses instead of forking, and the balance is unchanged afterwards.
"""
import os
import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent / "compat"))
import luahost  # noqa: E402

ROOT = Path(__file__).resolve().parents[1]
COMPAT = ROOT / "tests" / "compat"


def tx_dir():
    explicit = os.environ.get("OP77_TX_DIR")
    if explicit and Path(explicit).is_dir():
        return Path(explicit)
    return COMPAT / "vendor" / "open77_transactions"


def scenario(name):
    return luahost.run_scenario("economy_scenarios.lua", name, {
        "ROOT_DIR": ROOT.as_posix(), "COMPAT_DIR": COMPAT.as_posix(), "TX_DIR": tx_dir().as_posix(),
    })


@unittest.skipIf(luahost.unavailable(), luahost.unavailable())
class EconomyCompat(unittest.TestCase):
    def test_sql_restart_keeps_the_balance_on_the_durable_identifier(self):
        r = scenario("sql_restart")
        self.assertEqual(r["errors"], "0", r["first_error"])
        self.assertEqual(r["first"], "500")
        self.assertEqual(r["after_restart"], "1500")
        self.assertEqual(r["sql_row"], "1500")          # the coordinator's cash:<subject> row
        self.assertEqual(r["kvp_keys"], "0")

    def test_refusal_tokens_are_stable(self):
        r = scenario("refusals")
        self.assertEqual(r["errors"], "0", r["first_error"])
        self.assertEqual(r["bad_id"], "invalid_player_id")
        self.assertEqual(r["unknown_player"], "player_not_found")
        self.assertEqual(r["negative"], "invalid_amount")
        self.assertEqual(r["fraction"], "invalid_amount")
        self.assertEqual(r["overdraw"], "insufficient_funds")
        self.assertEqual(r["long_reason"], "invalid_reason")
        self.assertEqual(r["unknown_balance"], "0")

    def test_gap_r1_measured_behaviour(self):
        """The facade's behaviour around a database outage (R1 closed by B3)."""
        r = scenario("kvp_boot_between_sql_boots")
        self.assertEqual(r["errors"], "0", r["first_error"])
        self.assertEqual(r["sql_balance"], "1500")
        self.assertEqual(r["outage_join"], "0")                          # not loaded, not a fresh 500
        self.assertEqual(r["outage_add"], "nil/player_not_found")        # refused, nothing applied
        self.assertEqual(r["outage_kvp_writes"], "0")
        self.assertEqual(r["sql_rejoin"], "1500")                        # back without a restart
        self.assertEqual(r["midsession_accepted"], "1800/nil")           # accepted before detection
        self.assertEqual(r["midsession_refused"], "nil/store_unavailable")
        self.assertEqual(r["final_durable"], "1800")

    def test_gap_r1_invariant_a_database_outage_never_changes_a_balance(self):
        r = scenario("kvp_boot_between_sql_boots")
        self.assertEqual(r["outage_durable"], r["sql_balance"])
        self.assertEqual(r["sql_rejoin"], r["sql_balance"])
        self.assertEqual(r["outage_kvp_writes"], "0")
        self.assertEqual(r["kvp_keys_end"], "0")
        # Every change accepted is durable exactly once, every refused one never lands.
        self.assertEqual(int(r["final_durable"]), int(r["sql_balance"]) + 300)
        self.assertEqual(r["final_display"], r["final_durable"])


if __name__ == "__main__":
    unittest.main()
