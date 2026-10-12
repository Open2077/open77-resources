# Bulk admin acceptance — 2026-09-21

- `bulk_test.lua`: passed with Lua 5.4. 32 mock sessions, 750 ms minimum
  dispatch spacing, >=3 m landing separation, frozen origin, ready/life filters,
  disconnect/rejoin guards, ACL revocation, cancellation, snapshot-only targets,
  cross-resource/bucket vehicle removal and occupied exit timeout.
- `AdminIntegrationTests` + `AdminMenuLuaTests`: 17 tests passed using the real
  resource host and shipped Lua menu. The added host test verifies ACL and
  explicit confirmation, separate-tick respawns and revocation during the batch.
  The menu test verifies confirmation defaults to Cancel and revoked actions do
  not send commands.
- Real Freeroam server, two incarnated clients: `admin.bulk.tpall confirm`
  moved the observer to `(384.873, -2402.21, 182.073)` from the operator's
  `(381.873, -2402.212, 182.073)` rendezvous. Server reported 1/1 completed.
- Real `dvall confirm`: removed 3/3 network vehicles, created by
  `open77_vehicles`, `open77_admin` and `freeroam`. The first vehicle had an
  exit-locked driver. It was emptied before removal; afterwards the observer
  was alive, grounded, with no vehicle/workspot, and `vehicle.network` returned
  `count=0`. All three removed vehicles were disposable test spawns.
- Evidence (local, ignored): `artifacts/admin-bulk-server.log` and screenshots
  under `artifacts/admin-bulk-*.png`. The real run proves two-client behaviour,
  not a high-population stress test. Multi-target pacing/spacing is covered by
  deterministic tests, not claimed as a 32-client live measurement.
- Final clean-client acceptance: navigated `/admin` -> Server actions using
  real keyboard input, opened TpAll and cancelled with its default selection,
  then confirmed DVAll through the menu and removed one disposable Freeroam car
  (1/1 completed). Captures: `admin-bulk-live-section.png`,
  `admin-bulk-live-confirm.png`, `admin-bulk-live-dvall-confirm.png`.
  The compact surface explicitly releases focus on creation/open/close so a
  stale capture without an active text form does not disable arrow navigation.

Local Freeroam profile: `server/local-admin-bulk.jsonc`, private/masterless,
loopback `127.0.0.1:11778`, resources directly from the repository. Its database
is intentionally disabled: progression, appearance and ranked data are volatile.
LightRP was stopped without changing its profile, resources or database.
