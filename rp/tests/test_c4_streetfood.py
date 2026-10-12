"""C4 street-food stall (rp_streetfood): cook -> serve with consent -> pay -> eat, offline.

Run with `python -m unittest discover -s tests -p "test_c4*.py"` (Lua 5.4: lupa, or a lua54.dll
such as the KeraLua NuGet cache's; see tests/compat/luahost.py).

Each scenario boots, on tests/compat/multihost.lua: the FINAL open77_transactions resource (its
server/main.lua, exports, policy and work queue; the memory store plays the database), the real
open77_actions (Open77 repository, resources/system), the real rp_economy and rp_streetfood, shims
for the public exports of rp_jobs, rp_inventory, rp_needs and open77_furniture, and fakes for the
platform natives, including the documented player-interaction lifecycle and native hand items.
Scenario code: tests/compat/streetfood_scenarios.lua; world: tests/compat/streetfood_world.lua.

Sources outside this pack are READ in place, never copied or edited:
  OP77_SYS_DIR   the Open77 resources/system folder with open77_actions (and open77_pedestrians for
                 the anchor check; default: this repository's system/ folder, else
                 ../wt-world-interaction/resources/system)
  OP77_TX_FINAL  the final open77_transactions folder (default: SYS_DIR's copy)
A missing source skips the suite with the reason.

What this cannot show: anything in game (poses, the hand-over presentation, hand items, prompts,
timing on a live tick, real platform event payloads), SQL semantics on MariaDB (the coordinator's
own suites), the real rp_jobs / rp_inventory / rp_needs behind their exports, NPC seat contention.
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


def sys_dir():
    explicit = os.environ.get("OP77_SYS_DIR")
    if explicit and Path(explicit).is_dir():
        return Path(explicit)
    bundled = ROOT.parent / "system"          # this repository's own system/ folder
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
    return luahost.run_scenario("streetfood_scenarios.lua", name, {
        "ROOT_DIR": ROOT.as_posix(), "COMPAT_DIR": COMPAT.as_posix(),
        "SYS_DIR": sys_dir().as_posix(), "TX_DIR": tx_dir().as_posix(),
    })


def spot_rows(path, rows):
    """{row: (x, y, z, yaw, profile)} from open77_pedestrians' spots-generated.lua (column tables)."""
    text = path.read_text(encoding="utf-8")
    profiles = re.findall(r'"([^"]+)"', re.search(r"\n    profiles = \{([^}]*)\}", text).group(1))

    def column(name):
        body = re.search(r"\n    " + name + r" = \{([^}]*)\}", text).group(1)
        return [float(v) for v in re.findall(r"-?\d+(?:\.\d+)?(?:e-?\d+)?", body)]

    x, y, z, yaw, prof = (column(n) for n in ("spotX", "spotY", "spotZ", "spotYaw", "spotProfile"))
    return {r: (x[r - 1], y[r - 1], z[r - 1], yaw[r - 1], profiles[int(prof[r - 1]) - 1]) for r in rows}


class StreetfoodSources(unittest.TestCase):
    def test_sources_compile_without_bom(self):
        """Every rp_streetfood Lua file: UTF-8 without BOM (a BOM kills a resource silently) and
        loads as Lua 5.4 text."""
        if luahost.unavailable():
            self.skipTest(luahost.unavailable())
        lua = luahost.new_state()
        try:
            for path in sorted((ROOT / "rp_streetfood").rglob("*.lua")):
                data = path.read_bytes()
                self.assertFalse(data.startswith(b"\xef\xbb\xbf"), f"{path} has a BOM")
                data.decode("utf-8")
                if path.name == "open77.lua":
                    continue    # the manifest DSL (`auto_start false`) is parsed by the host, not Lua
                source = data.decode("utf-8")
                lua.execute(f"assert(load({luahost.lua_string(source)}, "
                            f"{luahost.lua_string('@' + path.name)}, 't'))", "=compile")
        finally:
            lua.close()

    def test_manifest_is_opt_in_and_least_privilege(self):
        text = (ROOT / "rp_streetfood" / "open77.lua").read_text(encoding="utf-8")
        code = "\n".join(line for line in text.splitlines() if not line.lstrip().startswith("--"))
        self.assertIn("auto_start false", code)
        block = re.search(r"permissions\s*\{([^}]*)\}", code).group(1)
        self.assertEqual(sorted(re.findall(r'"([^"]+)"', block)), sorted([
            "players.interactions.control", "players.interactions.read", "world.props",
            "players.life.read", "network.events"]))
        self.assertNotIn("database.access", block)
        self.assertNotIn("players.animations.control", block)   # open77_actions plays every animation
        self.assertNotIn("client_script", code)

    def test_rp_jobs_knows_the_cook_job(self):
        text = (ROOT / "rp_jobs" / "shared" / "config.lua").read_text(encoding="utf-8")
        self.assertRegex(text, r'\{ name = "cook",\s+label = "Street cook",\s+color = "#[0-9A-F]{6}", civil = true')

    def test_stall_anchors_come_from_the_catalogue(self):
        """The grill and counter of the food-court stall are vanilla AI spots of the pedestrian
        catalogue (a cook at a market grill, a customer standing in front of it), not invented."""
        spots = sys_dir() / "open77_pedestrians" / "server" / "spots-generated.lua"
        if not spots.is_file():
            self.skipTest(f"no spots catalogue at {spots}")
        rows = spot_rows(spots, [9594, 1144, 7736])
        config = (ROOT / "rp_streetfood" / "server" / "config.lua").read_text(encoding="utf-8")

        def configured(label):
            m = re.search(label + r" = \{ position = \{ x = (-?[\d.]+), y = (-?[\d.]+), z = (-?[\d.]+) \}, yaw = (-?[\d.]+)",
                          config)
            return tuple(float(v) for v in m.groups())

        grills = re.findall(r"grill = \{ position = \{ x = (-?[\d.]+), y = (-?[\d.]+), z = (-?[\d.]+) \}, yaw = (-?[\d.]+)",
                            config)
        food_court_grill = tuple(float(v) for v in grills[0])
        kabuki_grill = tuple(float(v) for v in grills[1])
        counter = configured("counter")
        for got, row in ((food_court_grill, 9594), (counter, 1144), (kabuki_grill, 7736)):
            x, y, z, yaw, _ = rows[row]
            self.assertAlmostEqual(got[0], x, places=3)
            self.assertAlmostEqual(got[1], y, places=3)
            self.assertAlmostEqual(got[2], z, places=3)
            self.assertAlmostEqual(got[3], yaw, places=2)
        self.assertEqual(rows[9594][4], "amb_704dff_cook")
        self.assertEqual(rows[7736][4], "amb_704dff_cook")


@unittest.skipIf(missing_sources(), missing_sources())
class StreetfoodLoop(unittest.TestCase):
    def run_ok(self, name):
        r = scenario(name)
        self.assertEqual(r.get("errors"), "0", r.get("first_error"))
        return r

    def test_happy_path_end_to_end(self):
        r = self.run_ok("happy_path")
        self.assertEqual(r["cook"], "committed")
        self.assertEqual((r["meat_used"], r["sauce_used"], r["bun_untouched"]), ("2", "1", "true"))
        self.assertEqual(r["pass_after_cook"], "1")
        self.assertEqual((r["order"], r["ticket_tip"], r["serve"]), ("committed", "2", "committed"))
        self.assertEqual((r["sale_op"], r["told_price"]), ("true", "true"))
        # ONE sale: 18 to the society, 2 tip to the cook, the skewer into the buyer's pockets
        self.assertEqual((r["paid"], r["society"], r["tipped"]), ("20", "18", "2"))
        self.assertEqual((r["skewer_in_pockets"], r["pass_after_sale"], r["ticket_gone"]), ("1", "0", "true"))
        self.assertEqual((r["eat"], r["skewer_after_meal"]), ("committed", "0"))
        self.assertEqual((r["needs_hunger"], r["needs_count"]), ("30", "2"))   # skewer, then soda
        self.assertEqual((r["consumed_events"], r["sold_events"]), ("2", "2"))
        # the hand item follows the portion: cook while offered, customer after the sale
        self.assertEqual(r["cook_held_offer"], "Items.crowd_soda_can_a")
        self.assertEqual((r["customer_held"], r["cook_held_after"]), ("Items.crowd_soda_can_a", "nil"))
        self.assertEqual((r["drink"], r["drink_with_can"], r["held_after_drink"]), ("committed", "true", "nil"))
        self.assertEqual((r["soda_left"], r["soda_society"]), ("5", "6"))
        self.assertEqual((r["stock"], r["buns_stocked"], r["cook_buns"]), ("committed", "2", "0"))
        # presentation requested (server side only: no claim about what renders)
        self.assertEqual((r["cook_at_grill"], r["eat_at_counter"], r["order_gesture"]), ("true", "true", "true"))
        self.assertEqual(r["conserved"], "true", r["conservation"])
        self.assertEqual(r["unbalanced"], "nil")

    def test_two_cooks_one_station(self):
        r = self.run_ok("two_cooks_one_station")
        self.assertEqual(r["a"], "committed")
        self.assertEqual(r["c_op"], "none")                     # refused before anything was held
        self.assertIn("target_claimed", r["c_refused"])       # sent to C's client by open77_actions
        self.assertEqual((r["meat_used"], r["bun_untouched"]), ("2", "true"))
        self.assertEqual((r["skewers"], r["burgers"]), ("2", "0"))
        self.assertEqual((r["a2"], r["c2"]), ("committed", "committed"))   # stocking does not claim the grill
        self.assertIn("off_duty", r["off_duty"])
        self.assertEqual(r["conserved"], "true", r["conservation"])
        self.assertEqual(r["unbalanced"], "nil")

    def test_customer_declines_times_out_or_cook_clocks_out(self):
        r = self.run_ok("customer_declines")
        self.assertEqual((r["declined_cash"], r["declined_pass"], r["declined_ticket_dropped"]), ("true", "1", "true"))
        self.assertEqual(r["declined_told"], "true")
        self.assertEqual((r["held_offer"], r["held_after_decline"]), ("Items.crowd_soda_can_a", "nil"))
        self.assertEqual((r["timeout_cash"], r["timeout_pass"], r["timeout_reason"]), ("true", "1", "timeout"))
        self.assertEqual(r["withdrawn_reason"], "stale_job_epoch")
        self.assertEqual((r["stale_cash"], r["stale_pass"], r["stale_not_sold"]), ("true", "1", "true"))
        self.assertEqual((r["sales"], r["promised_left"]), ("0", "true"))
        self.assertEqual(r["conserved"], "true", r["conservation"])
        self.assertEqual(r["unbalanced"], "nil")

    def test_payment_fails_then_replays_pay_once(self):
        r = self.run_ok("payment")
        self.assertEqual(r["drained"], "true")
        self.assertEqual((r["broke_cash"], r["broke_pass"], r["broke_pockets"]), ("0", "1", "0"))
        self.assertEqual((r["broke_told"], r["broke_ticket_dropped"]), ("true", "true"))
        self.assertEqual(r["paid"], "18")
        self.assertEqual((r["replay1"], r["replay_paid"]), ("true", "0"))
        self.assertEqual((r["replay2"], r["replay2_paid"]), ("true", "0"))
        self.assertEqual((r["lost_ack_paid"], r["lost_ack_done"]), ("18", "true"))
        # rp_economy answered in_doubt: the sweep followed the sale through rp_economy:status, once
        self.assertEqual((r["doubt_waited"], r["doubt_done"], r["doubt_paid"], r["doubt_calls"]),
                         ("true", "true", "18", "1"))
        self.assertEqual((r["skewers_bought"], r["sales"], r["society"], r["sold_events"]), ("3", "3", "54", "3"))
        self.assertEqual(r["conserved"], "true", r["conservation"])
        self.assertEqual(r["unbalanced"], "nil")

    def test_one_portion_is_never_offered_twice(self):
        r = self.run_ok("one_portion")
        self.assertEqual((r["s1"], r["offered_b"]), ("committed", "true"))
        self.assertEqual((r["s2"], r["s2_reason"]), ("failed", "no_order_ready"))
        self.assertEqual((r["s3"], r["to_d"]), ("committed", "4"))
        self.assertEqual((r["d_skewers"], r["b_skewers"], r["pass"], r["sales"]), ("1", "0", "0", "1"))
        self.assertEqual(r["promised_left"], "true")
        self.assertEqual(r["conserved"], "true", r["conservation"])
        self.assertEqual(r["unbalanced"], "nil")

    def test_refusals_before_the_bar_and_forged_intents(self):
        r = self.run_ok("refusals")
        self.assertEqual(r["filled"], "true")
        self.assertEqual((r["r1"], r["r1_reason"], r["r1_stage"], r["r1_presented"]),
                         ("failed", "missing_ingredients", "reserve", "false"))
        self.assertEqual(r["told1"], "true")
        self.assertEqual((r["r2"], r["r2_reason"], r["r2_stage"], r["r2_presented"]),
                         ("failed", "pass_full", "reserve", "false"))
        self.assertEqual((r["told2"], r["pantry_unchanged"]), ("true", "true"))
        self.assertEqual((r["r3"], r["r3_reason"], r["r4"], r["r4_reason"]), ("failed", "no_dish", "failed", "no_dish"))
        self.assertEqual(r["told_no_dish"], "true")
        self.assertIn("no_order", r["serve_refused"])
        self.assertEqual(r["told_no_order"], "true")
        self.assertIn("no_job", r["civilian"])                 # the eligibility provider
        self.assertIn("invalid_target", r["civilian"])         # the counter does not offer cooking
        self.assertEqual((r["forged_sales"], r["held"]), ("0", "true"))
        self.assertEqual(r["conserved"], "true", r["conservation"])
        self.assertEqual(r["unbalanced"], "nil")

    def test_crash_windows_conserve_ingredients_dish_and_money(self):
        r = self.run_ok("crash_windows")
        self.assertEqual((r["o1"], r["o1_reason"]), ("failed", "store_unavailable"))
        self.assertEqual((r["t1_cooks"], r["t1_agree"]), ("0", "true"))
        self.assertEqual((r["o2"], r["t2_cooks"], r["t2_agree"]), ("committed", "1", "true"))
        self.assertEqual((r["o3"], r["t3_cooks"], r["t3_agree"], r["doubts_left"]), ("in_doubt", "2", "true", "0"))
        self.assertEqual((r["o4"], r["t4_cooks"], r["t4_agree"]), ("in_doubt", "2", "true"))
        self.assertEqual((r["meal"], r["eaten"]), ("committed", "1"))
        self.assertEqual((r["meal2"], r["eaten2"], r["needs2"], r["consumed"]), ("in_doubt", "2", "2", "2"))
        self.assertEqual(r["sale6_done"], "true")
        self.assertEqual((r["paid6"], r["moved6"]), ("18", "1"))   # the dish moved exactly when the money did
        self.assertEqual(r["conserved"], "true", r["conservation"])
        self.assertEqual(r["unbalanced"], "nil")

    def test_cancellations_release_and_conserve(self):
        r = self.run_ok("cancellations")
        self.assertEqual((r["dead"], r["dead_reason"], r["death_kept"]), ("cancelled", "dead", "true"))
        self.assertEqual((r["by_key"], r["by_key_reason"], r["key_kept"]), ("cancelled", "cancelled_by_player", "true"))
        self.assertEqual((r["in_car"], r["in_car_reason"], r["pockets_after_car"]), ("cancelled", "vehicle", "1"))
        self.assertEqual((r["cancelled_by_stop"], r["restart_pass"], r["restart_cash_kept"]), ("true", "1", "true"))
        self.assertEqual((r["go_meal"], r["takeout"], r["left_after_go"]), ("committed", "true", "0"))
        self.assertEqual(r["nothing_held"], "true")             # every cancelled reservation was released
        self.assertEqual((r["released_on_death"], r["released_on_key"]), ("true", "true"))   # at once, not at expiry
        self.assertEqual(r["conserved"], "true", r["conservation"])
        self.assertEqual(r["unbalanced"], "nil")

    def test_seating_one_winner_per_seat(self):
        r = self.run_ok("seating")
        self.assertEqual(r["seats"], "3")                       # the barstool is off until measured
        self.assertEqual((r["seat1_profile"], r["seat1_source"]), ("chair", "open77_furniture"))
        self.assertEqual(r["b"], "committed")
        self.assertEqual(r["c_op"], "none")
        self.assertIn("target_claimed", r["c_refused"])
        self.assertEqual(r["sat_at_pose"], "true")
        self.assertEqual((r["b_skewers"], r["c2"], r["c_burgers"]), ("0", "committed", "0"))
        self.assertEqual(r["conserved"], "true", r["conservation"])
        self.assertEqual(r["unbalanced"], "nil")

    def test_seating_off_by_default(self):
        r = self.run_ok("seating_off")
        self.assertEqual((r["seats"], r["refused"]), ("0", "1"))

    def test_restart_keeps_pantry_pass_and_pockets(self):
        r = self.run_ok("restart")
        self.assertEqual((r["before_pass"], r["before_pockets"]), ("1", "1"))
        self.assertEqual((r["same"], r["orders_forgotten"]), ("true", "true"))
        self.assertEqual((r["after_sale_pass"], r["eat"], r["pockets_end"]), ("0", "committed", "1"))
        self.assertEqual(r["conserved"], "true", r["conservation"])
        self.assertEqual(r["unbalanced"], "nil")

    def test_lab_console_drives_the_whole_loop(self):
        r = self.run_ok("lab_console")
        for key in ("cook", "eat", "stock", "seated"):
            self.assertEqual(r[key], "committed", key)
        self.assertEqual((r["sold"], r["soda_sold"]), ("true", "true"))
        for key in ("state_line", "receipt_line", "stall_line", "seat_line", "status_line", "clock_line",
                    "restock_line", "offer_line"):
            self.assertNotEqual(r[key], "0", key)
        self.assertEqual(r["unbalanced"], "nil")


if __name__ == "__main__":
    unittest.main()
