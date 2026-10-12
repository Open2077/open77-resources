"""B8 compatibility suite, static half: run with
`python -m unittest discover -s tests -p "test_compat*.py"`.

Pure Python, no Lua engine, no game, no database. It freezes what the world-interaction
adapters (B1 items, B2 inventory, B3 wallet, B4 jobs) and the garage/housing containers must
keep answering for the resources that exist today, plus the SQL schemas a migration starts from.
A failure here is a contract change: update the frozen value only together with the migration
note in docs/world-interaction/b8-compat-audit.md.
"""
import json
import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent / "compat"))
import contracts  # noqa: E402

# Cross-resource server exports in use at origin/main 5dcdad2, by provider.
FROZEN_SURFACE = {
    "rp_inventory": {"add", "count", "define", "has", "list", "openStash", "remove"},
    # B3 (rp_economy 2.0.0): add/getBalance/remove are the 1.x surface every caller keeps; the
    # other five are rp_bank 2.0.0 calling the wallet facade (docs/world-interaction/b3-wallet.md).
    # B7 (rp_hud): walletStatus / pendingPlayers are rp_economy's read-only HUD exports
    # (docs/world-interaction/b7-ui.md).
    "rp_economy": {"add", "getBalance", "remove",
                   "balanceOf", "pay", "societyRead", "walletMove", "walletRead",
                   "pendingPlayers", "walletStatus"},
    "rp_bank": {"charge", "deposit", "getAccount", "society", "societyAdd", "societyRemove", "withdraw"},
    # B7: rp_hud reads B4's summary (getJob/getGrade/onDuty stay as its fallback).
    "rp_jobs": {"getGrade", "getJob", "hasJob", "isBoss", "listOnDuty", "onDuty", "setJob", "summary"},
    "rp_identity": {"fullName", "get", "isRegistered"},
    # A9 (wave 1): rp_cargo consumes canAccess and describe (docs/world-interaction/a9-cargo.md).
    # B7: the rp_inventory panel's read-only cargo view asks canAccessVehicle(..., "cargo", "view").
    "rp_garage": {"canAccess", "canAccessVehicle", "describe", "hasKey", "ownerOf", "plateOf", "setWanted",
                  "vehiclesOf"},
    "rp_housing": {"homeOf"},
    "rp_config": {"get"},
    "rp_nomade": {"activeContract"},
}
# Reconcile with the final coordinator (697e9e2f): rp_cargo and rp_economy (sale) ask rp_inventory
# for a one-operation pocket grant when the server's writers keep `char` to rp_inventory
# (docs/world-interaction/b1b2-inventory.md section 7, a9-cargo.md section 5).
FROZEN_SURFACE["rp_inventory"] = FROZEN_SURFACE["rp_inventory"] | {"grantPockets"}

SNAPSHOT = Path(__file__).resolve().parent / "compat" / "schema-snapshot.json"


class CompatContracts(unittest.TestCase):
    def test_every_cross_resource_call_targets_a_declared_export(self):
        missing = []
        for (provider, name), sites in sorted(contracts.consumed_exports().items()):
            if (contracts.ROOT / provider).is_dir() and name not in contracts.declared_server_exports(provider):
                missing.append(f"{provider}:{name} used at {sites[0]}")
        self.assertEqual(missing, [])

    def test_adapter_surface_is_frozen(self):
        consumed = {}
        for provider, name in contracts.consumed_exports():
            if provider in FROZEN_SURFACE:
                consumed.setdefault(provider, set()).add(name)
        for provider, frozen in FROZEN_SURFACE.items():
            with self.subTest(provider=provider):
                self.assertEqual(consumed.get(provider, set()), frozen,
                                 "a consumer started or stopped using an export: update the audit")
                self.assertLessEqual(frozen, contracts.declared_server_exports(provider),
                                     "a provider no longer declares an export its consumers call")

    def test_client_manifests_do_not_depend_on_server_only_resources(self):
        ships_client = {r: contracts.manifest(r)["ships_client"] for r in contracts.resources()}
        broken = []
        for resource, client in ships_client.items():
            if not client:
                continue
            for dependency in contracts.manifest(resource)["dependencies"]:
                if dependency in ships_client and not ships_client[dependency]:
                    broken.append(f"{resource} -> {dependency}")
        self.assertEqual(broken, [], "the client session would end with missing_dependency")

    def test_lua_files_have_no_bom(self):
        with_bom = [p.relative_to(contracts.ROOT).as_posix()
                    for p in contracts.ROOT.rglob("*.lua")
                    if ".git" not in p.parts and p.read_bytes()[:3] == b"\xef\xbb\xbf"]
        self.assertEqual(with_bom, [], "a Lua file with a UTF-8 BOM fails to load silently")

    def test_sql_schema_matches_snapshot(self):
        frozen = json.loads(SNAPSHOT.read_text(encoding="utf-8"))
        current = contracts.schema()
        self.assertEqual(sorted(current), sorted(frozen), "a table appeared or disappeared")
        for table in sorted(frozen):
            with self.subTest(table=table):
                self.assertEqual(current[table], frozen[table],
                                 "schema change: ship a versioned migration, never a silent recreate")


if __name__ == "__main__":
    unittest.main()
