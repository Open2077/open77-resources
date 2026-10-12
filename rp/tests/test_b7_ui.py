"""B7 suite: the minimal job/inventory/wallet UI over the existing kit (world-interaction row B7).

Run with `python -m unittest discover -s tests -p "test_b7*.py"` (or with the whole suite). Needs
a Lua 5.4 engine (tests/compat/luahost.py: lupa, or a lua54.dll such as the KeraLua NuGet
cache's). The coordinator is the A13 prototype vendored in tests/compat/vendor/open77_transactions
(pinned by blob ids); `OP77_TX_ROOT` points the rp_inventory half at another copy and
`OP77_TX_DIR` the rp_economy half, as in the B2/B3 suites.

What runs: the REAL rp_inventory server scripts (transactions backend, the /inv command and the
rp_inventory:intent net event as a client sends them), the REAL rp_hud server script with
stand-in B3/B4 providers, and the REAL rp_economy server scripts for its read-only HUD exports.
What this cannot show: the WebUI pages, focus, chat or voice in a game client, real tick
ordering, the coordinator's wave-1 wiring. The two-client checklist in
docs/world-interaction/b7-ui.md is the integrator's.
"""
import os
import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent / "compat"))
import luahost  # noqa: E402

ROOT = Path(__file__).resolve().parents[1]
COMPAT = ROOT / "tests" / "compat"
VENDOR = COMPAT / "vendor" / "open77_transactions"
TX_ROOT = Path(os.environ.get("OP77_TX_ROOT", VENDOR.as_posix()))
TX_DIR = Path(os.environ.get("OP77_TX_DIR", VENDOR.as_posix()))


def _skip_reason():
    reason = luahost.unavailable()
    if reason:
        return reason
    if not (TX_ROOT / "server" / "coordinator.lua").is_file():
        return f"open77_transactions prototype not found at {TX_ROOT} (set OP77_TX_ROOT)"
    return None


SKIP = _skip_reason()


def ui(name):
    return luahost.run_scenario("b7_ui_scenarios.lua", name, {
        "REPO": ROOT.as_posix(), "HARNESS": COMPAT.as_posix(), "TX_ROOT": TX_ROOT.as_posix()})


def client(name):
    return luahost.run_scenario("b7_client_scenarios.lua", name, {"REPO": ROOT.as_posix()})


def wallet(name):
    return luahost.run_scenario("b7_wallet_scenarios.lua", name, {
        "ROOT_DIR": ROOT.as_posix(), "COMPAT_DIR": COMPAT.as_posix(), "TX_DIR": TX_DIR.as_posix()})


@unittest.skipIf(SKIP, SKIP)
class InventoryPanel(unittest.TestCase):
    def test_refresh_is_private_and_follows_foreign_commits(self):
        r = ui("panel_private_refresh")
        self.assertEqual((r["a_open"], r["b_open"]), ("true", "true"))
        self.assertEqual(r["foreign"], "table")
        self.assertEqual(r["a_scrap"], "3")              # the coordinator's committed event refreshed A
        self.assertEqual(r["targets"], "7x1")            # one push, to A only: B untouched, no -1
        self.assertEqual(r["b_pushes"], "0")
        self.assertEqual(r["broadcast"], "none")         # nothing but the public catalogue head is broadcast
        self.assertEqual(r["a_state_owner"], "7")
        self.assertEqual(r["seq_moved"], "true")
        self.assertEqual(r["backend"], "transactions")

    def test_metadata_variants_and_units(self):
        r = ui("panel_metadata")
        self.assertEqual(r["define"], "2/0")
        self.assertEqual(r["ore_count"], "3")
        self.assertEqual(r["ore_variants"], "ore=1@q1,ore__quality_3=2@q3")   # quality grades kept apart
        self.assertEqual(r["tool_count"], "2")
        self.assertEqual(r["wear"], "dur=15")
        # Most worn first, and the view follows wearAsync (B2 facade fix: the update line has no
        # `from`, which an ipairs over { from, to, at } skipped).
        self.assertEqual(r["tool_durability"], "15,20")
        self.assertEqual(r["tool_serial_is_unit_id"], "true")
        self.assertEqual(r["tool_unique"], "true")
        self.assertEqual(r["held"], "0/0")

    def test_unit_lists_are_bounded(self):
        r = ui("panel_units_budget")
        self.assertEqual(r["knife"], "2+nil")          # sorted by label: Knife takes 2 of the budget of 3
        self.assertEqual(r["tool"], "1+3 count=4")     # Tool gets the last one, the rest is counted

    def test_refusals_keep_their_reason_and_the_state_is_current(self):
        r = ui("panel_refusals")
        self.assertEqual(r["stash_open"], "home:b7")
        # kind|reason|coordinator code|stale
        self.assertEqual(r["local_capacity"], "refused|stash_full|nil|nil")
        self.assertEqual(r["local_capacity_scrap"], "5")
        self.assertEqual(r["fill"], "table")
        self.assertEqual(r["coordinator_capacity"], "refused|stash_full|capacity_exceeded|nil")
        self.assertEqual(r["coordinator_capacity_moved"], "0")
        self.assertEqual(r["after_refusal_pockets"], "5/5")
        self.assertEqual(r["after_refusal_stash_shows_fill"], "4")   # the refused state shows the real stash
        self.assertEqual(r["stale"], "refused|not_enough|nil|true")
        self.assertEqual(r["stale_text"], "That changed meanwhile: here is what you have now.")
        self.assertEqual(r["store_unavailable"], "retry|store_unavailable|nil|nil")
        self.assertEqual(r["store_unavailable_moved"], "0/4")
        self.assertEqual(r["unknown_action"], "refused|unknown_action|nil|nil")

    def test_in_doubt_is_pending_then_confirmed(self):
        r = ui("panel_in_doubt")
        self.assertEqual(r["second_click"], "retry|busy_intent|nil|nil")   # one intent at a time
        self.assertEqual(r["during_pockets"], "2+2 in transit")            # held units shown, not gone
        self.assertEqual(r["during_stash"], "0")
        self.assertEqual(r["during_incoming"], "2.0")
        self.assertEqual(r["intent_done"], "true")
        self.assertEqual(r["pending_notice"], "pending|in_doubt|nil|nil")
        self.assertEqual(r["pending_list"], "store:scrapx2")
        self.assertEqual(r["pending_has_op"], "true")
        self.assertEqual(r["confirmed"], "Confirmed: Stored Scrap x2.")
        self.assertEqual(r["final_pending"], "nil")
        self.assertEqual(r["final_pockets"], "2+0")
        self.assertEqual(r["final_stash"], "2")
        self.assertEqual(r["store_counts"], "2/2")
        self.assertEqual(r["second_pending"], "1")
        self.assertEqual(r["closed_confirmation"], "Confirmed: Stored Scrap x1.")   # panel closed: chat
        self.assertEqual(r["closed_counts"], "1/3")

    def test_cargo_view_is_authorized_private_and_closes(self):
        r = ui("cargo_view")
        self.assertEqual(r["a_cargo"], "B7TRUCK:1/7")
        self.assertEqual(r["a_object"], "Scrap")
        self.assertEqual(r["a_read_only"], "true")
        self.assertEqual(r["b_cargo"], "nil")
        self.assertEqual(r["b_notice"], "refused|no_access|nil|nil")
        self.assertEqual(r["contents_asked_for"], "7")    # rp_garage refused B before rp_cargo was asked
        self.assertEqual(r["targets"], "7x1,8x1")
        self.assertEqual(r["reread_on_commit"], "1")
        self.assertEqual(r["after_revoke"], "nil")
        self.assertEqual(r["after_revoke_notice"], "refused|no_access|nil|nil")
        self.assertEqual(r["reopened"], "true")
        self.assertEqual(r["after_walk"], "nil")
        self.assertEqual(r["after_walk_notice"], "refused|too_far|nil|nil")
        self.assertEqual(r["no_garage"], "retry|garage_unavailable|nil|nil")

    def test_exits_close_the_panel(self):
        r = ui("panel_exits")
        self.assertEqual(r["death_closes"], "1")
        self.assertEqual(r["after_death_refresh"], "false")    # a stale page is put away
        self.assertEqual(r["blocked_chat"], "Another menu holds the keyboard: close it, then /inv again.")
        self.assertEqual(r["after_blocked"], "false")
        self.assertEqual(r["stash_before"], "home:b7r")
        self.assertEqual(r["stash_after_walk"], "nil")
        self.assertEqual(r["stash_after_walk_notice"], "refused|too_far|nil|nil")
        self.assertEqual(r["store_after_walk"], "No stash open.")


@unittest.skipIf(luahost.unavailable(), luahost.unavailable())
class PanelFocus(unittest.TestCase):
    """The client half against a fake surface modelling the one focus slot (wiki/webui.md)."""

    def test_every_exit_releases_focus(self):
        r = client("client_focus")
        self.assertEqual(r["boot_intent"], "close")              # a fresh VM: the server forgets any panel
        self.assertEqual(r["boot_focus"], "none")
        self.assertEqual(r["open_focus"], "-C")                  # browsing: cursor only, keyboard to the game
        self.assertEqual(r["open_sent"], "state")
        self.assertEqual(r["typing_focus"], "KC")                # the count field: keyboard too
        self.assertEqual(r["typed_focus"], "-C")
        self.assertEqual(r["page_close"], "none close:page close")
        self.assertEqual(r["server_close"], "none close")
        self.assertEqual(r["pause_close"], "none close:escape")
        self.assertEqual(r["taken"], "chat close:focus_taken")   # another menu took it: we close
        self.assertEqual(r["taken_no_regrab"], "none")           # and never take it back
        self.assertEqual(r["blocked"], "none blocked:panel_blocked focusCalls=0")
        self.assertEqual(r["unblocked"], "-C")
        self.assertEqual(r["never_focused"], "none close:focus_unavailable")
        self.assertEqual(r["stray"], "none")                     # the watchdog releases a stray hold
        self.assertEqual(r["reload_closed"], "close")
        self.assertEqual(r["reload_open"], "-C state")
        self.assertEqual(r["session_end"], "none close")
        self.assertEqual(r["closed_intent_forwarded"], "0")
        self.assertEqual(r["stop"], "none destroyed=true")


@unittest.skipIf(SKIP, SKIP)
class Hud(unittest.TestCase):
    def test_wallet_and_job_from_b3_b4(self):
        r = ui("hud_wallet_and_job")
        self.assertEqual(r["p1_cash"], "1200")
        self.assertEqual(r["p1_account"], "5000")
        self.assertEqual(r["p1_wallet"], "ok incoming=300 inDoubt=1 bank=nil")
        self.assertEqual(r["p1_job"], "NCPD 2 senior duty=true")
        self.assertEqual(r["p1_job_state"], "ok")
        self.assertEqual(r["p2_cash"], "nil")                 # unknown is never drawn as 0
        self.assertEqual(r["p2_wallet"], "store_unavailable")
        self.assertEqual(r["p2_job"], "nil")
        self.assertEqual(r["p2_job_state"], "store_unavailable")
        self.assertEqual(r["pushed_on_pending"], "1")
        self.assertEqual(r["pushed_on_settle"], "2")
        self.assertEqual(r["p1_cash_after"], "1500 pending=nil")
        self.assertEqual(r["p2_untouched"], "0")
        self.assertEqual(r["epoch_push"], "1")
        self.assertEqual(r["health_push"], "1,1")          # store down: both panels redrawn now
        self.assertEqual(r["broadcast"], "false")

    def test_falls_back_to_the_1x_exports(self):
        r = ui("hud_fallback")
        self.assertEqual(r["cash"], "250")
        self.assertEqual(r["account"], "900")
        self.assertEqual(r["wallet"], "nil")
        self.assertEqual(r["job"], "Mechanic 1 duty=false")


@unittest.skipIf(SKIP, SKIP)
class WalletStatusExport(unittest.TestCase):
    def test_pending_is_reported_until_settled(self):
        r = wallet("wallet_status_pending")
        self.assertEqual(r["errors"], "0", r.get("first_error"))
        self.assertEqual(r["joined"], "cash=500 in=0 out=0 unc=0 doubt=0 ops=0 bank=0")
        self.assertEqual(r["unknown_player"], "unloaded:not_loaded")
        self.assertEqual(r["invalid_id"], "nil:invalid_player_id")
        self.assertEqual(r["pending_idle"], "none")
        self.assertEqual(r["in_flight_young"], "cash=500 in=0 out=0 unc=0 doubt=0 ops=0 bank=0")
        # An atomic credit in flight is NOT in the balance: reported as incoming.
        self.assertEqual(r["in_flight"], "cash=500 in=300 out=0 unc=0 doubt=0 ops=1 bank=0")
        self.assertEqual(r["remove"], "400/nil")
        self.assertEqual(r["with_debit"], "cash=400 in=300 out=100 unc=0 doubt=0 ops=2 bank=0")
        self.assertEqual(r["caller"], "true:in_doubt")
        self.assertEqual(r["in_doubt"], "cash=400 in=300 out=100 unc=0 doubt=2 ops=2 bank=0")
        self.assertEqual(r["pending_players"], "7=cash:300:100:0:2")
        self.assertEqual(r["settled"], "cash=700 in=0 out=0 unc=0 doubt=0 ops=0 bank=0")
        self.assertEqual(r["pending_after"], "none")
        self.assertEqual(r["durable"], "700")


class Static(unittest.TestCase):
    CHANGED = [
        "rp_inventory/client/main.lua", "rp_inventory/client/catalogue.lua", "rp_inventory/server/main.lua",
        "rp_inventory/server/facade.lua", "rp_inventory/shared/items.lua",
        "rp_hud/server/main.lua", "rp_hud/shared/config.lua", "rp_economy/server/main.lua",
        "tests/compat/b7_ui_scenarios.lua", "tests/compat/b7_wallet_scenarios.lua",
        "tests/compat/b7_client_scenarios.lua",
    ]
    # Manifests use the open77.lua directive syntax (`auto_start true`), not plain Lua: BOM check only.
    MANIFESTS = ["rp_inventory/open77.lua"]

    def test_changed_lua_has_no_bom_and_compiles(self):
        for rel in self.CHANGED + self.MANIFESTS:
            data = (ROOT / rel).read_bytes()
            self.assertNotEqual(data[:3], b"\xef\xbb\xbf", rel)
        if luahost.unavailable():
            self.skipTest(luahost.unavailable())
        lua = luahost.new_state()
        try:
            for rel in self.CHANGED:
                path = (ROOT / rel).as_posix()
                lua.execute(f"local f, e = loadfile({luahost.lua_string(path)}, 't'); if not f then error(e, 0) end",
                            "=compile")
        finally:
            lua.close()

    def test_pages_never_reach_the_network(self):
        # The panel and the HUD render what the client script sends; no fetch, socket or remote
        # asset (the WebUI default `strict` policy would refuse them anyway).
        for rel in ["rp_inventory/web/index.html", "rp_hud/html/index.html"]:
            text = (ROOT / rel).read_text(encoding="utf-8")
            for needle in ["fetch(", "XMLHttpRequest", "WebSocket", "http://", "https://"]:
                self.assertNotIn(needle, text, f"{rel}: {needle}")


if __name__ == "__main__":
    unittest.main()
