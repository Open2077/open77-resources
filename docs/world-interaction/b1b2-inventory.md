# B1/B2: item definitions and the inventory facade over open77_transactions (wave 1)

**Rows:** B1 (item definitions and instances) and B2 (inventory adapters) of the world-interaction plan
(`wt-world-interaction/docs/world-interaction-plan.md` §4 B). **Date:** 2026-10-12.
**Branch:** `Open2077/open77-rp-examples` `wi/b1b2-inventory`, from `wi/b8-compat` (d401b40).
**Contract:** `wt-world-interaction/docs/world-interaction/a13-transaction-contract.md` (A13), §3, §7.2-§7.4, §12.
**Coordinator:** the A13 offline prototype, `wt-world-interaction/resources/system/open77_transactions/`, loaded
read-only by the tests; not edited.

**Evidence level.** Everything below was run **offline only**: the real `rp_inventory` server scripts on the B8
fake host, against the real A13 coordinator and its fault-injecting memory store, in Lua 5.4 (KeraLua 1.4.9
`lua54.dll` through ctypes). Nothing was deployed, launched, run against a database or run in game. No sentence
here claims in-game behaviour; §8 lists what the integrator must run.

---

## 0. Summary

1. **B1 schema v1** (`rp_inventory/shared/schema.lua`): every definition the pack has today imports unchanged
   (17 built-ins and the 24 items of nine definers, read from their real configs). It adds `weightG`,
   `maxStack`, `unique`, typed `metadata`, `durability`, `serial`, `quality` and `prop`/`hand`/`loot` mappings.
   Collisions between definers are refused, as are ids over 32 bytes or containing `__`, and unknown or invalid
   metadata. Stacks merge only with equal metadata (stack **variants**); per-unit fields make **instances**. The
   client catalogue is a bounded, versioned, hash-verified page transfer.
2. **B2 facade** (`server/facade.lua`, `server/accounts.lua`, `server/main.lua`): a second backend,
   `transactions`, selected per boot by convar. Pockets `char:<identifier>`, stashes `stash:<id>`, vehicle parts
   `veh:<PLATE>:<part>` and world containers `world:<id>` are coordinator accounts. The seven existing exports
   keep their signatures and tokens (write-behind, A13 §7.4 (i)). 24 new exports are added: 8 synchronous and
   16 async, each async mutation one coordinator operation with a receipt (§7.4 (ii)). Durable keys only. Never KVP.
3. **Migration** (`server/migration.lua`): a one-shot, journaled, idempotent import per subject from
   `rp_inventory_items` / `rp_inventory_stashes`, with explicit refusals (version, divergence, unknown ids,
   source layout, non-durable store).
4. **Tests:** 20 new offline tests (10 Lua scenarios), plus the 9 B8 tests: **29 run, all pass, 1 expected
   failure** (B8's gap R1, unchanged), in about 3.5 s.
5. **Coordinator API needs** (§7): an `info` export, lazy `read`, a fresh attempt for a reused failed `opId`,
   a replay check before holds, persisted container `meta`, weight-drift handling, the mint allowlist, the
   committed event.

## 1. B1: definition schema v1

### 1.1 Shape

The legacy shape `{ label, weight (kg), usable, illegal, permit, effect, record, visual, category }` is **schema
v1 without its optional fields**. `RpItemSchema.normalize` keeps every legacy field under its legacy name, so all
code that reads `Items[id].label/.weight/.usable/.effect` is unchanged, and adds:

| Field | Rule |
|---|---|
| `weightG` | integer grams; derived from `weight` (kg, rounded) when absent; a mismatch with `weight` is refused |
| `maxStack` / `stack` | integer 1..1e6: the most units of **one stack** a container holds (`stack_limit`) |
| `unique` | one instance per unit. Implied by `durability`, `serial` or any non-stack metadata field; `unique = false` with one of them is `unique_required` |
| `metadata` | `{ field = { type, default?, required?, min?, max?, maxLen?, pattern?, values?, stack? } }`. Types: integer, number, string, boolean, enum. Field names `^[a-z][a-z0-9]*$`, at most 16 fields. `stack = true` needs a default and a bounded domain (enum, boolean, or an integer range of at most 32) |
| `durability` | `{ max, start?, breaks? }` or a number. Reserved integer field 0..max; `wearAsync` lowers it with a compare-and-set update; at 0 the unit is destroyed (`sys:broken`) unless `breaks = false` |
| `serial` | `true`: the unit's instance id is its serial; a caller can never supply one (`serial_reserved`) |
| `quality` | `{ min, max, default }` or `{ values, default }`: a reserved **stack** field on stackable items, plain metadata on unique ones |
| `prop`, `hand` | `{ model?, item?, profile?, bone?, offset?, rotation? }`, validated (alias/record patterns, offsets ±10 m, rotations ±360°), never interpreted by rp_inventory |
| `loot` | `{ record, visual }`; the legacy `record` / `visual` fill it |

Unknown **top-level** definition fields are ignored and reported (`details.warnings`), as the legacy `define`
ignored them; unknown **metadata** is always refused.

### 1.2 Stacks, variants and instances

The coordinator's model has fungible stacks `(account, item) -> count` with no metadata, and instances with
metadata (A13 §3.1). B1 maps onto it without a schema change:

- **Stackable items** with stack fields become **variants**. The asset id is `<item>__<field>_<value>[__...]`
  for non-default values and the plain `<item>` when every stack field is at its default. `ore` with
  `{quality = 3}` is `ore__quality_3`, and `{quality = 1}` (the default) is `ore`. Two stacks therefore merge
  exactly when their metadata is equal. Variants are enumerated at definition time (at most 64 per item, ids at
  most 64 bytes) and all pushed to the coordinator, so a persisted variant id always decodes. `__` is reserved
  in item ids for this reason.
- **Unique items** are coordinator instances, created from `sys:` with their canonical metadata and serial.
  The legacy `add(…, "tool", 2)` creates two instances with default metadata. The legacy `remove` destroys the
  most worn first.

### 1.3 Registry rules

- **Collision.** An id owned by another definer is refused (`details.collisions`) and the owner's definition is
  kept (B8 R5). Built-ins are owned by `rp_inventory`. The same definer may define again: this is the restart
  handshake seven resources rely on.
- **Shape freeze (transactions backend only).** Within one rp_inventory generation, a same-definer redefinition
  that changes `weightG`, `unique` or the metadata shape is refused (`definition_changed`). The coordinator keeps
  running weight totals, and persisted variant ids must stay decodable. Label and other presentation changes
  pass.
- **Return value.** `define` still returns `registered, rejected` as **counts**: `rp_selftest` checks `1/1`, and
  `rp_crime` and `rp_fixer` log them. `details` is a third, additive value.
- **Bound.** At most 4,096 definitions (`registry_full`).

### 1.4 Client catalogue

The head is `{ schema, version, hash (FNV-1a 64 of the canonical entry list), pages, items }`. Pages hold at most
64 entries and 24 KiB (an entry is at most 2 KiB), so 4,096 definitions fit in at most 342 pages, far below the
48 KiB event envelope. Each entry is client-safe: no `effect`, no `permit`, no validation internals.

Flow:

1. The server sends the head on `onPlayerReady`, and broadcasts it once, 1 s after a burst of `define` calls.
   The version moves only when a client-visible entry changes.
2. The client (`client/catalogue.lua`) requests the pages one at a time, then reassembles and verifies them
   (`RpItemSchema.assemble`: `missing_page`, `count_mismatch`, `hash_mismatch`).
3. The server refuses more than `pages × 2 + 4` page requests per player and version, and more than 20 per 10 s.
   A stale version gets the head back.

No state bag is used. The panel does not depend on the catalogue.

## 2. B2: accounts and durable keys

| Account | Key | Refused |
|---|---|---|
| `char:<subject>` | `Open77.players.identifier` (the account id, also the default character id, A13 §3.1.1/§12.8) | missing identifier, characters outside `[A-Za-z0-9_.@-]` |
| `stash:<stashId>` | the caller's stash id, legacy rule `^[%w_%-:%.]+$` ≤ 64 (`home:<homeId>`) | `session…` (`session_key`), all digits and `trunk:/vehicle:/prop:/entity:/player:/drop:/loot:<digits>` (`runtime_id_key`) |
| `veh:<PLATE>:<part>` | the plate, upper-cased; part `^[a-z][a-z0-9_]*$` ≤ 16 | an all-digit plate (`runtime_id_key`), bad part (`invalid_part`) |
| `world:<id>` | minted (`w<coordinator opId prefix>.<n>`) or supplied by the projection owner; starts with a letter, 8..64 | anything else (`invalid_world_id`) |
| `sys:<name>` | journal-only sources and sinks: `sys:<caller resource>` (legacy add/remove), `sys:admin`, `sys:used`, `sys:expired`, `sys:broken`, `sys:migration`, buyers | — |

The coordinator applies the same lint again (`invalid_key`). Session ids and runtime entity ids never reach a key.

## 3. B2: the facade API, old and new

### 3.1 Existing exports (both backends, unchanged signatures and tokens)

| Export | Legacy backend | Transactions backend |
|---|---|---|
| `define(items)` | B1 registry (collisions refused) | same, plus a coalesced push to the coordinator |
| `has` / `count` / `list` | memory cache | the view (committed + pending − held); `false`/`0`/`nil, reason` when not loaded, as before |
| `add(id, item, n, meta?)` / `remove(id, item, n, meta?)` | write-through (`meta` validated; only the default stack is storable) | **write-behind**: applied to the view at once, submitted as one single-account operation, serially per account, journaled against `sys:<caller>` |
| `openStash(id, stashId, cap)` | as before | durable-key lint, then a migrated `stash:` account |

Offline proof: the same 30-odd calls, including `/use`, `/give` (reach and weight checks), `/giveitem` and an
rp_inventory restart, return **identical** answers and identical `rp_inventory:changed` sequences on both
backends (`test_existing_exports_answer_the_same_on_both_backends`).

### 3.2 New exports

- **Synchronous:** `backend`, `catalogueVersion`, `itemDefinition`, `accountOf`, `stashAccount`,
  `vehicleAccount`, `worldAccount`, `registerAuthorizer`.
- **Async** (transactions backend only; the legacy backend answers `backend_legacy`): `giveAsync`, `storeAsync`,
  `takeAsync`, `sellAsync`, `openVehicle`, `vehicleStoreAsync`, `vehicleTakeAsync`, `createWorld`,
  `worldPutAsync`, `worldTakeAsync`, `wearAsync`, `addAsync`, `removeAsync`, `moveAsync`, `read`, `status`.

Every async mutation is **one** `transfer` and returns the coordinator receipt. On failure it returns
`nil, reason, info`, and `info.opId` comes back after an `in_doubt`. A caller-supplied `opts.opId` makes a retry
idempotent: the same `opId` twice moves once and the second answer has `replay = true`.

| Refusal | When |
|---|---|
| `not_enough` | the view or the coordinator (`insufficient_items`, `instance_unavailable`) says the units are not there |
| `too_heavy`, `target_too_heavy`, `stash_full` | capacity, named after the receiving side (the coordinator's `capacity_exceeded` carries no account; the facade adds it, and `info.coordinator` says who decided) |
| `stack_limit` | `maxStack` |
| `not_authorized` | an authorizer said no, did not answer, or is required and missing (`info.detail`) |
| `vehicle_not_tracked`, `unknown_container` | the `veh:` or `world:` container was never opened |
| `store_unavailable` | the coordinator is not running or not ready, or a fence proved nothing committed: retry |
| `in_doubt` | unknown after 20 s; holds are kept and settlement continues in the background; poll `status(opId)` |
| `busy` | earlier write-behind changes of the same accounts did not land within 10 s |
| `wallet_not_coordinated` | `sellAsync` while the wallets are not on the coordinator (B3) |
| coordinator tokens | passed through (`op_id_conflict`, `invalid_key`, `operation_too_large`, …) |

### 3.3 Inside the transactions backend

- **Views.** A view is `committed + pending − held`:
  - `committed` is what the coordinator acknowledged.
  - `pending` holds write-behind operations not yet acknowledged.
  - `held` holds the debits of in-flight async operations, so a concurrent synchronous `remove` cannot spend
    them.
  - A reload never runs under an in-flight operation of the view; it is deferred, which is the coordinator's
    own rule.
- **Write-behind failure.** A write the coordinator refuses later, typically because another resource drained
  the stock first, is logged as `write-behind … LOST`. The view resyncs and listeners get a compensating
  `rp_inventory:changed` (`-2, +2, -2` in the drain test, net correct). Retryable outcomes (`store_unavailable`,
  `conflict`, `busy`, dispatch failures) are resubmitted with backoff (0.25…30 s). An `in_doubt` is settled
  through `status(opId, {resolve = true})` before anything is resubmitted. A non-committed attempt is retried
  under a fresh `opId` suffix (`.rN`) and never under one that could still commit.
- **Converted flows.** `/give`, `/saisir`, the panel's store and take, and `/drop` with its pickup are atomic
  coordinator operations. The debit/credit/rollback sequences of the legacy code (B8 §3.5) are gone in this
  backend.
- **Foreign commits.** `open77_transactions:committed(opId, kind, accounts)` reloads any shown container,
  except for this resource's own operations (a bounded set of 4,096 ids).
- **Readiness.** Two steps form a handshake:
  1. The first step obtains an `opId` prefix through `newOpId`. The prefix is unique per coordinator boot, so
     rp_inventory-minted operation, instance and world ids cannot collide.
  2. The second step pushes the definitions.

  Until both succeed, mutations answer `store_unavailable`. Stopping or restarting `open77_transactions` resets
  the handshake. Nothing is ever written to KVP: the tests count zero KVP keys in every scenario.

### 3.4 Authorization hook (vehicles, stashes, world)

`registerAuthorizer(scope, exportName)` takes one of the scopes `veh`, `world`, `stash` or `stash:<prefix>`, and
allows **one resource per scope**. Another resource gets `authorizer_taken`. The scope is released when its
resource stops. Before each move, the facade calls `exports.<resource>:<exportName>(request)` with this request:

```lua
{ playerId, subject = "char:…", account, action = "store"|"take"|"put", item, count, plate?, part?, stashId?, worldId? }
```

- **`veh` fails closed.** Without an authorizer, or when the authorizer does not answer `true`, every
  `vehicleStore/TakeAsync` is `not_authorized`. Opening a trunk on screen is never authorization (plan §4 B2).
  Keys, owners, mechanics and police are A9's to implement (`wt-wi-rp-a9`); this row only exposes the accounts
  and the hook.
- **Stashes keep housing's checks.** `rp_housing` still checks key and guest before `openStash`, exactly as
  today. If it registers `stash:home`, every store and take from the open panel is re-authorized, which closes
  B8's "revoked key, panel still open" inference. Unregistered prefixes are allowed, as today.
- **`world`** is optional: reach, bucket and claims belong to the projection owner (A5/A6).

### 3.5 World containers and `/drop`

- **A drop is a container.** `/drop` creates a `world:<id>` container with the native loot as its projection
  (A13 §6.1, option (b)). The loot is created first, then one operation moves the goods from `char` to `world`.
  A refusal removes the loot, so a refused drop still costs nothing.
- **Pickup.** A pickup is one `world` → `char` operation under the coordinator's capacity check. A refused
  pickup leaves the goods in the container and re-creates the loot **where it lay**, not at the picker's feet
  (B8 §3.5).
- **Expiry and restart.** Expiry evaporates the goods through a journaled `inv.expire` operation, keeping
  today's semantics. An rp_inventory restart loses the loot projection (A13 F4) but no longer the goods.
- **Not fixed here:** the native pickup still grants the loot record (`Items.money` by default, A13 P3) to the
  picker's game inventory, and nothing re-projects drops after a restart until the coordinator persists
  container `meta` (§7, item 5) and a projection owner exists.

## 4. Migration (one-shot, per subject)

`Migration:ensure(account, kind, key, capacityG)` runs on a subject's first load (`migrateOnLoad`, the default)
or from the console with `invmigrate all | char <identifier> | stash <id>`. The command is ACL-gated
(`command.invmigrate`).

1. **Gates.**
   - The marker table must exist.
   - The legacy layout must be absent or exactly the 5dcdad2 one (`information_schema`; otherwise
     `source_schema_mismatch`).
   - Unknown item ids are refused (`unknown_items`) unless `importUnknownItems` is set. Loads wait up to 15 s for
     definers to re-register first.
   - The coordinator must report `store = "sql"`, or the import is refused with `store_not_durable`.
2. **Commit.** The legacy rows become lines from `sys:migration` in chunks of at most 40 lines. Plain rows
   become stack lines. Rows of a unique item become instances whose ids derive from the subject, the item and
   the unit index (`mig1.<fnv(account)>.<item>.<k>`), so the lines of a rerun are byte-identical.
   - **Attempt sequence.** Each chunk walks a **deterministic** attempt sequence: `mig1:<account>:c<k>`, then
     `….a2`, `….a3` … (at most 8). A fenced `aborted` opId can never commit (A13 §4.4), so the next attempt is
     made only once every earlier one is proven not committed: at most one attempt of a chunk can ever commit.
   - **Reruns.** A rerun on any VM, including a restarted coordinator, finds that commit through `status` and
     replays it instead of re-applying.
   - **Legacy changes.** A legacy change under an `opId` already used is an `op_id_conflict`, reported as
     `legacy_changed_during_migration`.
   - **Capacity.** The container is opened at `max(capacity, imported weight)`; the next load reopens it at its
     configured capacity, so an over-capacity import keeps its items and can only be emptied.
3. **Marker.** The marker row in `rp_inventory_migrations` records the account, `version = 1`, the first
   `opId`, the row count, the FNV-1a 64 of the sorted rows, the weight, the capacity, a JSON report and the
   time. The legacy tables are **never modified**: they stay the rollback source.
4. **Refusals.** None of them imports anything or writes a marker:

   | Reason | Cause | Way out |
   |---|---|---|
   | `migration_version_mismatch` | a marker from another format version | none: never re-imported |
   | `legacy_diverged` | the legacy rows changed after the import (a rollback ran the legacy backend) | `invmigrate accept char|stash <key>` keeps the imported state, an explicit operator decision |
   | `marker_write_failed` | the import committed but its marker was not written | rerun: it writes the marker and imports nothing twice |

KVP data is never read (A13 §3.1.1: a separate admin step).

**Golden fixture** (`tests/compat/fixtures/inventory_legacy_5dcdad2.lua`): 7 legacy pockets and 3 stashes, with
an unknown id, a zero row, an over-capacity pocket, a 45-kind pocket (2 chunks) and an all-digit stash id.

- The import produces the expected containers exactly: stacks, `weight_g` and `capacity_g`.
- It commits 6 `migrate` operations with a balanced journal and refuses `acct-c` and the stash `12` explicitly.
- A second run commits 0 operations and 0 journal rows.

## 5. Tests (offline)

Run `python -m unittest discover -s tests -p "test_compat*.py"` from the pack root.

- **Engine and sources.** It needs a Lua 5.4 engine and the A13 prototype: `OP77_TX_ROOT`, else the
  `wt-world-interaction` path. Tests skip with the reason if either is missing.
- **2026-10-12 result.** 29 tests in 3.0-3.5 s: OK, 1 expected failure (B8 R1). Engine: KeraLua 1.4.9
  `lua54.dll` through ctypes, Python 3.12.
- **New files.** `tests/test_compat_inventory.py`, `tests/compat/inventory_scenarios.lua`,
  `tests/compat/txhost.lua` (an additive extension of `fakehost.lua`) and the fixture.

| Test | What it establishes (offline) |
|---|---|
| definitions import unchanged | 17 built-ins and every pack definer (real configs: rp_bar, rp_crime, rp_ferrailleur, rp_fixer, rp_gangs, rp_mecano, rp_netrunner, rp_nomade, rp_ripperdoc) register all, 0 rejected; `rp_selftest` 1/1 |
| collisions and id rules | `0/2` for a colliding definer, owner kept; long, `__`, upper-case, heavy, label-less ids refused |
| metadata and variants | equal metadata = same asset; defaults = plain id; unknown/invalid/serial refused |
| shape freeze | weight change refused under `freezeShape`, label change accepted |
| catalogue bounds and transfer | pages ≤ 64/24 KiB, version stable on identical redefinition, hash tamper and missing page refused, 4,096 → 64 pages, request quota (`6` of 50) |
| export parity | identical answers and events on both backends; persisted across a restart |
| concurrent pickup | two players: one winner (the second refused by the local hold); against a foreign reservation: the coordinator decides |
| full inventory | `too_heavy` decided by the coordinator (`capacity_exceeded`) after a foreign credit; give/store refusals; no operation committed |
| give atomic | lost ack applied once, `unreachable_before` fenced to nothing, retry ok, same `opId` replays |
| crash between steps | give/store/take × none, unreachable_before, lost_ack, failed, refused, coordinator crash (detached execution + new VM), rp_inventory restart mid-flight: **21/21 conserve**, view = store |
| write-behind | serial ordering, LOST on a foreign drain with resync, refusal while the coordinator is down, re-handshake, no phantom after restart, reconnect with a write in flight |
| metadata, instances, wear | variants stored apart, legacy remove order, serial = instance id, wear persisted across restart, break at 0 |
| keys and authorization | session/runtime keys refused, vehicles fail closed, per-player authorizer, `authorizer_taken`, scope released on stop, stash re-authorization per move |
| drop | world container, refused pickup re-projected at origin, expiry journaled, restart keeps goods |
| migration | golden, idempotent, crash between commit and marker (also across a coordinator restart), a fenced first attempt (same run moves to `.a2`), a store failure (rerun walks past it), lost markers (no double import), unique items as derived instances, version mismatch, divergence + accept, non-durable store, layout mismatch, unknown import |

What the tests **cannot** establish is listed in §8.

## 6. Residual risks

- **Write-behind is no stronger than before** (decision §7.4 (i)). A legacy `add` accepted optimistically can be
  lost if another resource changes the same account first, or if rp_inventory stops with a queued write (logged
  at stop). Flows that move value (C1 sale, salvage credit, cargo) must use the async exports.
- **Coordinator holds are not in the synchronous views.** A reservation by another resource is visible only
  after its commit event, so a synchronous `remove` can be accepted and then LOST.
- **Weight drift across restarts.** A definer changing an item's weight between boots changes the per-unit
  weight, while the coordinator's `weight_g` keeps the old total (§7, item 6).
- **Stash, vehicle and world views stay loaded** for the generation. They are bounded by usage; world views are
  released after pickup.
- **`sellAsync` stays disabled** until B3 moves wallets onto the coordinator.

## 7. API changes needed from the coordinator (A13 / `wt-wi-a13b`)

1. **`info()` export** → `{ store = "sql"|"lab_kvp"|"memory", schemaVersion }`. The migration refuses without it
   (`coordinator_info_unavailable`, or `requireDurableStore = false`): stamping markers over a disposable store
   loses subjects.
2. **`read(account)` must load lazily** and answer `exists = false` for a missing container. The prototype's
   `C:read` answers `not_loaded`; the test harness loads first.
3. **A failed operation keeps its `opId` in memory.** `reserve` on an `opId` whose operation `failed` (conflict,
   store_unavailable, expired, cancelled) replays the failure. Contract §3.4 says a definitive failure leaves no
   row and a retry is "a fresh attempt". The facade works around it with `.rN` suffixes and the migration with
   its `.aN` attempt sequence. Either forget non-committed operations, or document that a new `opId` is
   required. A fenced `opId` is unusable forever by design, so any business `opId` scheme needs an attempt
   suffix: worth stating in §3.4.
4. **A committed `opId` the VM does not know** (after a coordinator restart) computes holds before reaching the
   duplicate-key path, so it can answer `capacity_exceeded` or `insufficient_items` instead of a replay. Check
   `readOp` first for unknown `opId`s. The migration calls `status` first as a workaround.
5. **Persist container `meta` and `expiresAt`** on `open` (the §4.2 columns exist) and offer a lookup or listing
   of `world:` containers, so a projection owner can re-create drops after a restart.
6. **Weight drift.** Recompute `weight_g` from stacks × current weights on load, or refuse a weight change for an
   item present in containers.
7. **Mint allowlist (§12.6).** rp_inventory mints and burns on behalf of legacy callers, as `sys:<resource>`,
   `sys:admin`, `sys:used`, `sys:expired`, `sys:broken`, `sys:migration` and buyers. Caps should apply per `sys:`
   account, or every pack resource's minting aggregates under `rp_inventory`.
8. **Emit `open77_transactions:committed(opId, kind, accounts)`** on the host bus, as in §7.2. The facade's
   foreign-commit reload depends on it.
9. **`subjectOf(playerId)`** (non-yielding, §12.5). rp_inventory uses `Open77.players.identifier` until it
   exists.
10. **Item definitions policy.** rp_inventory is the single item definer toward the coordinator. A resource that
    calls the coordinator directly with item lines must define its items through `rp_inventory:define`, never
    through `open77_transactions:define`; otherwise the coordinator refuses it as a collision.

## 8. What the integrator must run in game

None of this was run. The backend is opt-in, and `open77_transactions` needs its wave-1 manifest and export
wiring first; the prototype has neither.

1. **Boot.** In the lab, with a disposable MariaDB: `resources.load` + `open77_transactions`, and the convar
   `rp_inventory_backend transactions`. Expected log lines: `backend: transactions`,
   `transactions backend ready (opId prefix …)` and `rp_inventory_migrations ensured`.
2. **Migration.** Run it on a copy of a real database. Per subject, compare
   `SELECT identifier, item_id, count FROM rp_inventory_items` with the coordinator's `op77_tx_stacks`. Run
   `invmigrate all` twice: the second run must commit nothing. Kill the server during `invmigrate all` and rerun.
3. **Legacy parity (§5.3 presentation and authorization rows).** Run README "Test in 2 minutes" steps 2-9 on two
   clients, A and B, then swap them. Every chat line and panel state must match the legacy backend's.
4. **Durability.**
   - Stop or kill `open77_transactions` during `/give`, during a panel store, and between `/drop` and the
     pickup. Restart, then reconcile the counts on both clients and in SQL.
   - Restart the server: drops are gone, and their goods sit in `world:` containers (`op77_tx_containers`).
5. **Contention.** Both clients pick up one drop at once, and both take the last unit of one stash from their
   panels. The item must exist exactly once.
6. **Catalogue.** The client log must not show `catalogue … rejected`. `catalogueVersion()` (client export) must
   equal the server's version after a definer restarts.
7. **Hash every artifact** that ran. Read `invmigrate status` for LOST, in-doubt and retry counters after each run.

## 9. Research ledger entry (for the integrator to copy)

> **2026-10-12: B1/B2 wave-1 build, offline (RP pack `wi/b1b2-inventory`).**
>
> **Built:**
> - `rp_inventory` B1 schema v1 (`shared/schema.lua`), with collision refusal, typed metadata, stack variants,
>   instances, durability/serial/quality and a paged catalogue.
> - A `transactions` backend: a facade over the A13 `open77_transactions` with `char:/stash:/veh:/world:`
>   accounts, write-behind legacy exports, 24 new exports (16 async, one operation each) and an
>   authorization hook (`veh` fails closed).
> - A one-shot journaled import of `rp_inventory_items`/`rp_inventory_stashes` (`rp_inventory_migrations`).
>
> **Facts (offline, real scripts + A13 prototype, KeraLua lua54.dll):**
> - All 41 pack definitions import unchanged.
> - The seven exports answer identically on both backends.
> - 21/21 crash windows conserve items and keep views equal to the store.
> - Concurrent pickup has one winner; full inventories refuse with nothing committed; the same `opId` moves once.
> - The golden migration matches and a rerun commits nothing, also after a fenced or failed attempt and lost
>   markers.
> - No KVP key is written in any scenario.
> - 29 tests: OK, 1 expected failure (B8 R1).
>
> **Prototype gaps found:**
> - A failed `opId` replays its failure, so a retry is not a fresh attempt.
> - An unknown-but-committed `opId` computes holds before replaying.
> - `read` does not load lazily.
> - `open` does not persist `meta`.
> - There is no `info` export.
>
> **Inferences (unmeasured):** write-behind latency is about one export round trip plus a tick per operation;
> catalogue transfer time is one round trip per 24 KiB page.
>
> **Not done:** in-game proof (§8), SQL execution, C1/A9/B3 integration, re-projection of drops after a restart,
> the vanilla `Items.money` grant on native pickups (P3).
>
> **Next:** the A13 wiring with the §7 changes; then the integrator's §8 lab run; then C1 moves its salvage
> credit and sale to `addAsync`/`sellAsync` (once B3 lands).
