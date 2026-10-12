"""B8 compatibility suite, executable half: rp_economy's real server script, run offline.

Run with `python -m unittest discover -s tests -p "test_compat*.py"`. Needs a Lua 5.4 engine
(see tests/compat/luahost.py: lupa, or a lua54.dll such as the KeraLua NuGet cache's); the
tests skip with the reason when there is none. The fake host is tests/compat/fakehost.lua.

Gap R1 (docs/world-interaction/b8-compat-audit.md): a boot whose database is unavailable falls
back to KVP for the whole boot, starts every player from the starting balance, and what is
earned during that boot is not merged back when SQL returns. The expected-failure test states
the invariant the B3 wallet adapter must provide; it turns into an unexpected success (a suite
failure) once the gap is closed, so the audit and this file are updated together.
"""
import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent / "compat"))
import luahost  # noqa: E402

ROOT = Path(__file__).resolve().parents[1]
SCRIPT = (ROOT / "rp_economy" / "server" / "main.lua").as_posix()


def scenario(name):
    return luahost.run_scenario("economy_scenarios.lua", name, {"ECONOMY_SCRIPT": SCRIPT})


@unittest.skipIf(luahost.unavailable(), luahost.unavailable())
class EconomyCompat(unittest.TestCase):
    def test_sql_restart_keeps_the_balance_on_the_durable_identifier(self):
        r = scenario("sql_restart")
        self.assertEqual(r["first"], "500")
        self.assertEqual(r["after_restart"], "1500")
        self.assertEqual(r["sql_row"], "1500")

    def test_refusal_tokens_are_stable(self):
        r = scenario("refusals")
        self.assertEqual(r["bad_id"], "invalid_player_id")
        self.assertEqual(r["unknown_player"], "player_not_found")
        self.assertEqual(r["negative"], "invalid_amount")
        self.assertEqual(r["fraction"], "invalid_amount")
        self.assertEqual(r["overdraw"], "insufficient_funds")
        self.assertEqual(r["long_reason"], "invalid_reason")
        self.assertEqual(r["unknown_balance"], "0")

    def test_gap_r1_measured_behaviour(self):
        """Characterises gap R1 as shipped at 5dcdad2 (update together with the R1 fix)."""
        r = scenario("kvp_boot_between_sql_boots")
        self.assertEqual(r["sql_balance"], "1500")
        self.assertEqual(r["kvp_join"], "500")           # fresh starting wallet, SQL balance ignored
        self.assertEqual(r["kvp_after_income"], "1200")
        self.assertEqual(r["kvp_key"], "1200")           # the KVP boot's state stays in KVP
        self.assertEqual(r["sql_rejoin"], "1500")         # ...and is never merged back

    @unittest.expectedFailure
    def test_gap_r1_invariant_a_database_outage_never_changes_a_balance(self):
        r = scenario("kvp_boot_between_sql_boots")
        self.assertEqual(r["kvp_join"], r["sql_balance"])
        self.assertEqual(r["sql_rejoin"], r["kvp_after_income"])


if __name__ == "__main__":
    unittest.main()
