# A9: vehicle legal ownership / keys adapter and cargo layouts

**Row:** A9 of the world-interaction plan (`wt-world-interaction/docs/world-interaction-plan.md` §4 A,
acceptance in §5.3). **Wave:** 1. **Date:** 2026-10-12.
**Branch:** `Open2077/open77-rp-examples` `wi/a9-cargo`, from `wi/b8-compat` (d401b40).
**Read against:** plan §1.2 (Vehicles, Attachments), §1.3, §2 steps 3–5, §3 (Physics and
attachments, Persistent identity), §4 rows A9/B2/C1/C2, §5.3; A13 contract
(`docs/world-interaction/a13-transaction-contract.md` on `feat/world-interaction`) §3.1, §7.3,
§12; the B8 audit (`docs/world-interaction/b8-compat-audit.md`) §1.2, §1.3, §5.5.

**Reconcile (2026-10-12, branch `wi/reconcile-a13`):** the cargo suite now runs the **final**
`open77_transactions` of Open77 `697e9e2f` (vendored, `server/main.lua` included), not a fake; §5 lists
what it resolved. **Status: offline only.** Nothing was built into a deployed artifact, launched, or seen in game.
No server, database or `open77_*` tool was used. Every cargo offset is a starting guess
(`measured: false`). **Fact** = checked in the cited source; **inference** = follows from source,
not measured; **open** = a decision for the integrator.

---

## 0. Summary

1. **Access adapter in `rp_garage`.** `exports.rp_garage:canAccess(playerId, plate, part, action)`
   answers for five callers: owner, key holder, mechanic on a job order, police with a warrant,
   stranger. The policy is a pure module (`rp_garage/server/access.lua`) over a config table
   (`Config.access`). Grants (job orders, warrants) persist **by plate** in a new table
   `rp_garage_grants`, expire, and are revoked. Existing exports are unchanged.
2. **Vehicle identity.** The plate is the durable key. `rp_garage` now raises
   `rp_garage:spawned(plate, vehicleId, record)` and `rp_garage:despawned(plate, vehicleId, reason)`
   whenever a plate gets or loses a runtime id, and exports `describe(plate)` and
   `accountOf(plate, part)` (`veh:<plate>:<part>`, A13 §3.1).
3. **Layouts as data.** `rp_cargo/data/layouts.json`: the three `rp_nomade` trucks (Mackinaw,
   Mackinaw 02, Legatus) and the Thorton Colby pickup, with aliases for records that share an
   entity template. 16 slots, all `measured: false`.
4. **Cargo service `rp_cargo`** (new, opt-in, server-only). Custody in the coordinator account
   `veh:<plate>:cargo`; each crate is an item **instance**; its slot is instance metadata
   `meta.cargo = { slot, layer, model }` written by the commit that moves it in. Props are a
   projection rebuilt from the coordinator on take-out, removal, bucket change, foreign commits,
   restart, and a 15 s sweep.
5. **Lab:** `cargospawn`, `cargotune`, `cargolayout` (JSON to paste back), `cargoclear`,
   `cargoinfo`, console only, explicit ids.
6. **Tests:** 23 new offline tests on the B8 fake host (10 access, 13 cargo), all passing; the B8
   suite still passes (9 tests, 1 expected failure).
7. **Needs from the coordinator** (§5): `metaPatch` on instance moves (N1), `read` that loads on
   demand without creating (N2), a `subjectOf` export (N3), part-scoped namespace ACL (N4): all resolved
   by Open77 `697e9e2f`. One semantic differs from the wave-0 assumption: `metaPatch` merges and never
   deletes, so an unloaded crate keeps `cargo = false` (read as "no slot").
8. **Reconcile additions:** `rp_cargo` declares `dependency "open77_transactions >=0.1.0"`, asks
   `rp_inventory:grantPockets` when the server's writers keep it to `veh/cargo`, passes `subjectOf`
   refusals through; `rp_garage:labIssue` issues a plated, owned vehicle for lab runs (convar
   `rp_garage_lab 1`).

---

## 1. Source facts this row builds on

| Id | Fact | Evidence |
|---|---|---|
| S1 | A vehicle's durable key is its plate (`rp_garage_vehicles.plate` primary key); runtime ↔ plate goes through `live[tostring(vehicleId)]` and `plateOf`. | `rp_garage/server/main.lua` (`rowOfVehicle`, `exports("plateOf")`); A13 E4 |
| S2 | Before this row, "who may open a car" was `holdsKey` (owner, key holder, any employee of the owning society) and "owner" was `isOwner` (owner, or the society boss). No mechanic or police notion. | `rp_garage/server/main.lua` `holdsKey`, `isOwner` |
| S3 | `rp_nomade` attaches crates to its rented truck with a root binding in the vehicle frame; its four bed slots and `stackHeight = 0.55` are labelled "starting guesses, not measurements"; crate n takes slot `((n-1) % #slots) + 1`, then the next layer. One bed is used for all three truck records. | `rp_nomade/shared/config.lua:111-141`; `rp_nomade/server/main.lua:521-566` |
| S4 | `rp_nomade`'s truck is a runtime vehicle with no plate (B8 §1.2): under A13 it has no durable container. | B8 audit §1.2 row `rp_nomade`; A13 §3.1 (`vehicle_not_tracked`) |
| S5 | A vehicle parent takes at most 32 attached props across resources; prop and parent must be in the same bucket; vehicle removal and parent bucket changes detach the child on the server; streaming hides and restores the projection with the binding retained. | `wiki/attachments.md:107-109`, `:177-182` (Open77 `feat/world-interaction`) |
| S6 | `onVehicleAuthorityChanged(id, owner, epoch, reason)` exists; physics authority (`Open77.vehicles.owner`) is a lease that moves with the driver. | `wiki/vehicles.md:993`, `:1861-1930` |
| S7 | `Mackinaw` and `Mackinaw 02` have **different** entity templates (`0x8F15…` vs `0xBCDF…`); `Mackinaw 02` shares its template with `mackinaw_ncu_player`; `colby_pickup_player` shares with `colby_pickup_02_player`. | `docs/vehicle-models.md:111-124` (Open77) |
| S8 | `Open77.io.readJson(path)` reads under the resource's `data/` directory, permission `filesystem.read`, 48 KiB JSON limit. | `wiki/server-api.md:478-505` |
| S9 | The vehicles guide's door example comments "Server-side inventory logic can now expose the trunk contents" next to `isDoorOpen`. The plan (§4 B2) says an open trunk is not authorization. `canAccess` never reads door state. | `wiki/vehicles.md:642`; plan §4 B2 |
| S10 | The A13 prototype keeps instance metadata only when an instance is **created** from a `sys:` account; a move line's `meta` is dropped by `normalizeLine`/`buildPlan`, although `_applyPlan` and the memory store already apply `i.meta` on a move. | `resources/system/open77_transactions/shared/model.lua` (`normalizeLine`, `buildPlan`), `server/coordinator.lua` (`_applyPlan`), `server/memory_store.lua:190` (Open77, de8c785d) |
| S11 | The prototype's `read` answers `not_loaded` for an account this VM has not loaded; only `open` (which creates the row) loads a container. | `server/coordinator.lua` (`read`, `open`) |

---

## 2. Access adapter (`rp_garage`)

### 2.1 Model

Three things are kept apart: **legal ownership** (this registry), **physics authority**
(`Open77.vehicles.owner`, never consulted) and **resource permissions** (`world.vehicles` etc. of
the calling resource).

| Role | Who | Vehicle actions | Part actions (cargo, trunk, glovebox) | Gate (refusal) |
|---|---|---|---|---|
| `owner` | owner identifier, or boss of the owning society | drive lock store manage repair | view take put | `impounded` (except `manage`) |
| `key` | duplicate-key holder, or employee of the owning society | drive lock store | view take put | `impounded` |
| `mechanic` | `mecano` employee **on duty** with an active job order on the plate | drive lock repair | cargo view, trunk view | `off_duty`, `no_job_order`, `impounded` |
| `police` | `ncpd` officer **on duty** with a warrant: the plate's wanted flag or an active police grant | drive lock impound | view take | `off_duty`, `warrant_required` (none needed while impounded) |
| stranger | anyone else | — | — | `no_access` |

The first role that permits the action and passes its gate wins; otherwise the most specific
refusal is returned (`action_not_permitted` when a role exists without the action). Everything
is `Config.access` (`rp_garage/shared/config.lua`); `police.withoutWarrant` can open, say,
`"cargo:view"` to any officer on duty.

### 2.2 API (synchronous, cache-only, never yield)

```lua
exports.rp_garage:canAccess(playerId, plate, part, action)        -- true, role, state | false, reason
exports.rp_garage:canAccessVehicle(playerId, vehicleId, part, action)
exports.rp_garage:accountOf(plate, part)                          -- "veh:<plate>:<part>"
exports.rp_garage:describe(plate)                                 -- { plate, record, label, state, owner, society, vehicleId, wanted }
exports.rp_garage:authorize(plate, "mechanic" | "police", holder, { minutes, reason, by })
exports.rp_garage:labIssue(playerId, record, { label?, spawn? })   -- LAB ONLY: convar rp_garage_lab 1
exports.rp_garage:revokeAuthorization(plate, role, holder?, { by })
exports.rp_garage:authorizations(plate)
```

Reasons: `registry_loading`, `invalid_player_id`, `invalid_plate` (a plate is a string; a bare
number is refused so a runtime id is never read as a plate), `invalid_part`, `invalid_action`,
`vehicle_not_tracked`, `player_not_found`, `no_access`, `action_not_permitted`, `impounded`,
`off_duty`, `no_job_order`, `warrant_required`; for grants `invalid_role`, `invalid_holder`
(session-like or all-digit holders are refused), `invalid_duration` (1 min..24 h), `not_owner`,
`not_police`, `grade_too_low` (`warrantMinGrade = 2`), `not_found`.

`labIssue` (reconcile, for the C1 two-client run) registers a new plate owned by the player, with no
payment, and takes it out 4 m from them (`spawn = false`: stored at the public garage). It answers
`{ plate, owner, state, vehicleId? }`, or `lab_disabled` unless the server sets the convar
`rp_garage_lab 1`, `registry_loading`, `invalid_player_id`, `player_not_found`, `invalid_record`,
`no_plate`. Offline: `test_lab_issue_is_gated_and_owned`.

Player and console paths: `/cles ordre <mechanicId> [plate] [minutes]`, `/cles ordre annuler
[plate]` (owner); console `vehwarrant <plate> <minutes> [reason]` / `vehwarrant <plate> off`
(warrant for `job:ncpd`).

### 2.3 Persistence and events

- `rp_garage_grants(plate, role, holder, granted_by, reason, expires_at, at, PK(plate, role,
  holder))`, created with `CREATE TABLE IF NOT EXISTS` next to the two existing tables; KVP
  fallback `grants:<plate>` follows the resource's existing per-boot store choice (so it inherits
  B8 gap R1; not fixed here). Added to `tests/compat/schema-snapshot.json`.
- Expired grants are purged by the existing 30 s snapshot loop; lock exceptions follow.
- New events: `rp_garage:spawned(plate, vehicleId, record)`, `rp_garage:despawned(plate,
  vehicleId, reason)` (`stored`, `impounded`, `lost`); `rp_garage:changed` gains `authorized` and
  `unauthorized`. An adapter holding an open panel re-checks `canAccess` on every `changed`.

### 2.4 Behaviour changes in `rp_garage` (all additive)

- A mechanic on duty with a job order gets a per-player lock exception and is not reported by
  `rp_garage:stolen`.
- The start log line now names three tables and counts grants.
- Unchanged: `hasKey`, `ownerOf`, `plateOf`, `vehiclesOf`, `impound`, `setWanted`, `spawnOwned`,
  key commands, menus, store/take-out, the plate state bag.

---

## 3. Cargo layouts (`rp_cargo/data/layouts.json`)

Schema 1. Per record: `label`, `part` (default `cargo`), `model` (default `crate.small`),
`capacityKg`, `measured`, `entityTemplate`, `basis` (provenance text), `aliases`, `slots[]` with
`id`, `x`, `y`, `z` (vehicle frame of a root binding: **+x right, +y forward, +z up**), `yaw`
(degrees about z), `stackHeight`, `maxStack`, `measured`. Defaults fill missing slot fields.

| Record | Aliases | Slots × stack | capacityKg | Basis |
|---|---|---|---|---|
| `Vehicle.v_standard3_thorton_mackinaw_player` | — | 4 × 2 | 300 | S3 |
| `Vehicle.v_standard3_thorton_mackinaw_02_player` | `…_mackinaw_ncu_player` (S7) | 4 × 2 | 300 | S3 copied; different template from the Mackinaw |
| `Vehicle.v_utility4_chevalier_legatus_player` | — | 4 × 2 | 400 | S3 copied; larger "Truck" body |
| `Vehicle.v_standard25_thorton_colby_pickup_player` | `…_pickup_02_player` (S7) | 4 × 2 | 250 | analogy guess |

Validation refuses a whole layout on: bad record id, duplicate slot id, offset beyond ±20 m or
yaw beyond ±360° (S5 attach bounds), `stackHeight` outside (0, 3], `maxStack` outside 1..8, more
than 24 objects (slots × maxStack; S5 leaves 8 of 32 to other resources), missing capacity, or
`measured: true` with an unmeasured slot.

**Inference:** aliases share a body because they share `entityTemplatePath` (S7); appearance
variants could still differ (bed covers, racks). Verify one alias per layout.

---

## 4. Cargo service (`rp_cargo`)

### 4.1 Custody and identity

- Account: `veh:<plate>:<layout.part>` (default `veh:<plate>:cargo`). An untracked vehicle (no
  plate) is refused `vehicle_not_tracked`; a tracked vehicle without a layout `no_cargo_layout`.
- Occupant: an item **instance** in that account. Its slot: `meta.cargo = { slot, layer, model }`,
  written by the load commit through `metaPatch` (N1) and cleared by the unload commit's
  `metaPatch = { cargo = false }`: the final coordinator merges one level and deletes nothing, so the
  unit leaves with `cargo = false`, which every reader treats as "no slot"; other metadata keys (wear,
  origin, a contents reference) are kept.
- `load(playerId, vehicleId, instanceId, opts)` moves from `char:<subject>` (or `opts.from =
  "world:<id>"`) to the cargo account in **one** `transfer` with `expect = { [cargo] = version }`.
  `unload` moves out to `char:<subject>` or `world:<id>`. `contents` lists for `view`.
- Checks before any operation: player id, vehicle exists, plate, layout, subject, same bucket,
  within `Config.reach` (5 m of the vehicle origin), vehicle not moving (> 1 m/s), then
  `rp_garage:canAccess(..., "cargo", "put" | "take" | "view")`.
- Writers (reconcile): before a load or unload, `allowed(rp_cargo, <the pockets or world: side>)`; when
  the server's `writers` gives `rp_cargo` only `veh/cargo`, the pockets come from
  `rp_inventory:grantPockets(opId, playerId)` for that one operation, else the move is refused
  `namespace_denied` and nothing is attempted (`test_per_part_writers_and_pocket_grant`). A `world:`
  side needs `rp_cargo` in `writers` for `world`.

### 4.2 Slots and stacking

- Allocation is **floor first**: the least-filled slot with room, ties in layout order; then the
  next layer (as `rp_nomade` wraps crates, S3). `opts.slot` asks for one slot (`slot_full`,
  `invalid_slot`). A full layout answers `cargo_full`; weight is the coordinator's
  (`capacity_exceeded`).
- The stored `layer` only orders a stack (`max + 1`); the drawn height uses the **rank**, so
  unloading a bottom crate lets the one above settle instead of floating.
- Slotless instances (moved in by another resource) are drawn in the least-filled slot when
  `Config.models[item]` names a model; an item with no model is held but not drawn.

### 4.3 Projection and reconciliation

One prop per drawn instance, created by `rp_cargo` (a cross-resource prop cannot be mutated,
`wiki/attachments.md:24-25`), attached with `parentType = "vehicle"`, `bone = ""`. The job removes its
own carried prop after a successful load.

| Trigger | Action |
|---|---|
| `rp_garage:spawned` | draw the plate's cargo on the new runtime id |
| `rp_garage:despawned` | remove the props; custody untouched |
| `onPropAttachmentChanged` without binding (S5: vehicle removal, bucket change) | redraw from the coordinator |
| `open77_transactions:committed` for a drawn `veh:` account, not ours | redraw |
| `onVehicleAuthorityChanged`, `onPlayerReady` | verify bindings only (no coordinator call, no new prop) |
| start, `rp_garage` restart, sweep every 15 s | scan the world, settle in-doubt operations, verify |

A coordinator read failure keeps what is drawn (an outage never empties a truck on screen).

### 4.4 Concurrency, retries, failures

- One operation per plate at a time (`withPlate`; `busy` after `lockTimeoutMs`): two players
  loading one truck are served in turn against fresh state.
- `stale_version` / `conflict`: re-read and re-plan once.
- `in_doubt` / `busy` from the coordinator (and an export timeout or stop on a mutating call):
  the slot stays **claimed** until `status(opId, { resolve = true })` settles it; the sweep then
  redraws. Never reported as a failure.
- Idempotency: callers pass a business `opId`; a retried load of an instance already in the
  cargo returns its placement with `already = true` and moves nothing; reusing an `opId` for
  another crate is the coordinator's `op_id_conflict`.
- Own commits are marked before the call (the committed event can arrive before the answer).

### 4.5 Garage store / take-out and restart

Store (vehicle removed): props go, `veh:<plate>:cargo` keeps the instances. Take-out (new runtime
id): `rp_garage:spawned` redraws the same slots, with no new operation. Server restart: vehicles
come back as stored (`rp_garage` `adoptRow`), so the next take-out redraws; a restart of
`rp_cargo` alone redraws every live tracked vehicle at its start scan.

---

## 5. Coordinator API needs: resolved by Open77 `697e9e2f`

Reconciled 2026-10-12 against the final coordinator (contract §7.2, §13.7: A9 N1–N4 done).

| # | Need | Outcome | rp_cargo now |
|---|---|---|---|
| N1 | `metaPatch` on an instance move, same commit, in the request hash | resolved (moves and in-place lines, one version CAS). **Differs:** a shallow merge that deletes nothing (`false` is stored) | load patches `cargo = { slot, layer, model }`, unload patches `cargo = false`; readers already required a table |
| N2 | lazy `read`, `unknown_account`, never creates; `open` keeps or updates capacity | resolved (`open` re-capacities and keeps `meta` unless given) | `read` without the `not_loaded` branch; nothing is created by looking |
| N3 | `subjectOf` | resolved (non-yielding) | asked inline with `callSync`; a refusal is passed through (no identifier fallback) |
| N4 | part-scoped writers | resolved (`writers = "rp_cargo:veh/cargo"`, `allowed(resource, "veh:<plate>:cargo")`) | `mayWrite` checks, and asks `rp_inventory:grantPockets` for the pockets |
| N5 | `committed` names the invoking resource | **not in 697e9e2f** | still tracks its own opIds |
| N6 | crates are B1 `unique` definitions minted by the job under the mint rules | policy (C1: `rp_salvage sys:salvage * <cap>`) | rp_cargo never mints |

Test seam: `tests/compat/fake_tx.lua` is now `FakeTx` over the real coordinator (seeding through
`open` and journaled `seed` transfers; faults at the export boundary: a refused commit, a stale snapshot,
an answer lost after or before the commit, `export_timeout` on status). Every cargo assertion held
except one, `a_cargo_meta` (`nil` → `false`, the merge semantics above).

**Open (A6/B2/C1):** a crate with contents. A13 does not nest containers: either the crate is an
instance whose metadata references its `world:<uuid>` contents, or contents are flattened into
the instance. rp_cargo works with either (it only moves the instance id).

---

## 6. Lab commands and measurement steps (integrator)

```text
cargospawn <vehicleId> [layers|all] [model]
cargotune  <vehicleId> <slot> <x> <y> <z> [yaw] [stackHeight]
cargolayout <vehicleId>        -- JSON entry to paste over data/layouts.json
cargoclear <vehicleId>
cargoinfo  <vehicleId|plate>
```

They need neither the coordinator nor a plate: any vehicle of a record with a layout works.

1. Two clients (A actor, B observer), server with `rp_garage` and `rp_cargo` started; hash the
   installed artifacts (plan §5.2).
2. Spawn one vehicle per record in an open flat spot
   (`vehicle.create.player <playerId> <record>` from the `open77_vehicles` reference resource,
   `wiki/vehicles.md:2080-2099`); read its id with `vehicle.list`.
3. `cargospawn <id> all`. From both clients, third person, side and rear: each crate rests on the
   bed floor (no sinking, no hovering), clears the cab, sides and tailgate; layer 2 sits on
   layer 1. Screenshots per record.
4. `cargotune <id> <slot> x y z [yaw] [stackHeight]` per slot until it looks right on both
   clients; keep left/right symmetric (mirror `x`).
5. Short drive with the crates on (A driving, B observing): the props follow the vehicle. This
   observes the platform attachment, not the layout; note jitter if any.
6. `cargolayout <id>`; paste over the entry in `data/layouts.json`; set `measured: true` on the
   slots checked, and on the layout when all are.
7. Repeat for every record; check one alias record per aliased layout (§3 inference).
8. Then, with the coordinator wired: a load/unload round trip, a garage store/take-out, and B
   reconnecting while loaded (§7 table, live rows).

---

## 7. Tests (offline) and §5.3 coverage

```text
python -m unittest discover -s tests -p "test_compat*.py"   # B8: 9 tests, 1 expected failure
python -m unittest discover -s tests -p "test_a9*.py"       # A9: 23 tests (wave 0); 25 at the reconcile
```

Results on 2026-10-12, Lua 5.4 through the KeraLua NuGet `lua54.dll` (`tests/compat/luahost.py`):
**32 passed, 1 expected failure** (B8 gap R1). `tests/test_held_actions.py` still needs `lupa`,
which is not installed here (pre-existing, B8 §6.1). All new Lua files compile (Lua 5.4 load
check), carry no BOM, and use LF.

| File | Covers |
|---|---|
| `tests/test_a9_garage_access.py` + `compat/garage_access_scenarios.lua` | the real `rp_garage` scripts: access matrix (owner, key, mechanic with/without order and duty, police with/without warrant and duty, stranger, impound lot, society fleet), vocabulary and durable-key refusals, grants persisted across restart, expiry purge, revocation, `registry_loading`, plate identity across take-out / removal / take-out (`spawned`/`despawned`, lock exceptions), `/cles revoke`, `/cles ordre`, console `vehwarrant` |
| `tests/test_a9_cargo.py` + `compat/cargo_scenarios.lua` | the real `rp_cargo` scripts with a fake coordinator: data file and validation, JSON round trip, floor-first allocation and stacking, settle after unload, refusals that move nothing, concurrent loads (distinct slots; one winner for the last place), store/take-out restore with no new operation, resource restart, authority handoff (no-op) and bucket change (redraw), in-doubt claims, idempotent retry and `op_id_conflict`, foreign commits drawn, lab commands, `contents` |

Harness changes (additive): `tests/compat/fakehost.lua` gains cross-resource export stubs
(`H.remote`, `exports.res:fn()`, `Open77.exports.call/callSync`) and multi-script boots; new
`fakeworld.lua` (vehicles, props with vehicle attachments, positions, `Open77.io.readJson`),
`json.lua` (decoder), `fake_tx.lua` (A13 export subset + N1); `FROZEN_SURFACE` gains
`rp_garage:canAccess`/`describe` (consumed by `rp_cargo`), the schema snapshot gains
`rp_garage_grants`.

| §5.3 dimension | Offline here | Still needs the lab |
|---|---|---|
| Presentation | — | every offset (§6); FPP/TPP of the bed; both rigs irrelevant (vehicle parent) |
| Contention | concurrent loads on one truck; last place has one winner | two real clients loading at once |
| Streaming | authority handoff and reconnect are no-ops server-side; bucket change redraws | B reconnecting mid-load sees the cargo; leave/re-enter interest (platform keeps the binding, S5, unverified here) |
| Cancellation | refusals move nothing; in-doubt claims held | death/disconnect mid-carry belongs to A5/C1 |
| Durability | store/take-out, resource restart, retry/replay, store down, in doubt (fake) | real coordinator + MariaDB; server restart |
| Authorization | full matrix; key revocation; grant expiry; refusals passed through | forged intents through a real job resource |

---

## 8. Compatibility and migration notes

- **`rp_nomade` (C2).** Its rented truck has no plate (S4): `rp_cargo` refuses it
  (`vehicle_not_tracked`). C2 needs a garage-tracked truck (a `society:nomade` fleet vehicle, or
  a registration path) and B1 crate instances; then `load`/`unload` replace `stowCrate` and the
  bed config. Nomade stays as is until C2 (plan decision 5).
- **`rp_mecano` (C3).** Still acts on any vehicle and persists runtime ids (B8 R3). The
  plate-aware path now exists: `canAccessVehicle(mechanic, vehicleId, nil, "repair")` with a job
  order from the owner (`authorize(..., "mechanic", ...)`, e.g. after an accepted invoice).
  `rp_mecano` was not changed.
- **`rp_shop` v1** keeps its own runtime-id vehicle ledger (B8 §5.5); not touched. Disable or
  migrate it before cargo ships on its vehicles.
- **`rp_crime`** stealing Nomade cargo should become a coordinator move out of `veh:<plate>:cargo`;
  rp_cargo then redraws (tested with a foreign commit).
- **B2 vehicle inventory adapter** (`rp_inventory`, another agent): map `vehicleId → plateOf →
  accountOf(plate, "trunk" | "glovebox")` and ask `canAccess(playerId, plate, part, "view" |
  "take" | "put")` on every intent, not only when a panel opens.

---

## 9. Risks, inferences to measure, open decisions

- **Inference:** the attach offsets are relative to the vehicle root as the platform renders it;
  if a record's root is not where `rp_nomade`'s guesses assumed, every slot moves together.
  Measure (§6).
- **Inference:** a crate on the rank-2 layer looks right with one `stackHeight` per slot; uneven
  crate models may need per-model heights (`model` per layout today).
- **Risk:** attached props are visual only (S5): cargo intersects scenery and does not shift.
  Do not present it as physics.
- **Risk:** 24 objects per layout + other resources' props can still hit 32 per parent
  (`attachment_parent_limit` is logged and retried by the sweep).
- **Open:** whether police with a warrant may `put` (evidence back) — not granted by default.
- **Open:** whether a mechanic's default scope should include `cargo:take` (unloading a bed
  before a repair) — not granted by default; owners can only widen it through config today.
- **Open:** cargo of a stored vehicle at a garage menu (legal answer exists; no reach rule yet).

---

## 10. Research ledger entry (for the integrator to copy)

> **2026-10-12 — A9 wave 1: vehicle access adapter and cargo layouts (RP pack `wi/a9-cargo`,
> offline).**
>
> **Facts (source):**
> - `rp_garage` had no mechanic or police access notion; ownership and keys are keyed by plate,
>   the runtime id only maps through `live`.
> - `rp_nomade`'s four bed slots and 0.55 m stack height are self-declared guesses and are shared
>   by three truck records; its truck has no plate.
> - Mackinaw and Mackinaw 02 have different entity templates (`docs/vehicle-models.md:121-124`).
> - The A13 prototype drops `meta` on instance moves from non-system accounts and loads a
>   container only through `open`.
>
> **Built (offline):** `rp_garage:canAccess` (owner / key / mechanic job order / police warrant /
> stranger) over `Config.access`, grants table `rp_garage_grants` keyed by plate,
> `rp_garage:spawned` / `despawned`, `describe`, `accountOf`; `rp_cargo` (opt-in) with
> `data/layouts.json` (4 layouts + 3 aliases, 16 slots, all `measured: false`), load / unload /
> contents over `veh:<plate>:cargo` instances with `meta.cargo`, projection and reconciliation,
> lab `cargospawn` / `cargotune` / `cargolayout` / `cargoclear` / `cargoinfo`.
>
> **Measurement (offline):** B8 fake host, Lua 5.4 (`lua54.dll`): 23 A9 tests pass, B8 suite
> 9 tests with 1 expected failure. Fake coordinator assumes N1.
>
> **Inferences (unmeasured):** aliases share a bed with their base record (same template); attach
> offsets carry over between clients; the platform keeps cargo bindings across stream-out and
> reconnect (documented, not observed).
>
> **Hypotheses:** the copied Mackinaw slots are wrong for the Legatus and possibly for Mackinaw 02.
>
> **Next:** measure the four layouts on two clients (§6); land N1–N4 in the coordinator build;
> C1 truck = a dealership Mackinaw (has a plate); C2 must move Nomade to plated fleet trucks.
>
> **Open:** police `put`, mechanic `cargo:take`, stored-vehicle cargo access, crate contents
> (instance metadata vs flattened).
