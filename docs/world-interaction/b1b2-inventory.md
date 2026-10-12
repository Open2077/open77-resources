# B1/B2: item definitions and the inventory facade over open77_transactions (wave 1)

**Rows:** B1 (item definitions and instances) and B2 (inventory adapters) of the world-interaction plan
(`wt-world-interaction/docs/world-interaction-plan.md` §4 B). **Date:** 2026-10-12.
**Branch:** `Open2077/open77-rp-examples` `wi/b1b2-inventory`, from `wi/b8-compat` (d401b40).
**Contract:** `wt-world-interaction/docs/world-interaction/a13-transaction-contract.md` (A13), §3, §7.2-§7.4, §12.
**Coordinator:** since the reconcile of 2026-10-12 (branch `wi/reconcile-a13`), the **final** wave-1
`open77_transactions` of Open77 `697e9e2f` (`wi/a13-coordinator`, merged into `feat/world-interaction`), vendored
unmodified in `tests/compat/vendor/open77_transactions` (blob ids in its `SOURCE.txt`) and run whole, `server/main.lua`
included. The wave-0 build ran against the offline prototype; §7 says what the final coordinator resolved.

**Evidence level.** Everything below was run **offline only**: the real `rp_inventory` server scripts on the B8
fake host, against the real final A13 coordinator (its exports, gate, work queue, policy and events, on
`tests/compat/txsandbox.lua`) and its fault-injecting memory store, in Lua 5.4 (KeraLua 1.4.9
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
5. **Coordinator API needs** (§7): all resolved by Open77 `697e9e2f`; the facade now uses `info().ready`,
   `subjectOf`, `allowed`, lazy `read`, `openWorld`/`close`/`listWorld`, `metaPatch` and the mint rules, and
   follows its rule for reused `opId`s. What remains is listed in §7.
6. **Reconcile (2026-10-12):** `grantPockets` (a one-operation pocket grant for a job or `rp_economy:sale`
   under strict `writers`), drops re-projected after a restart, `in_doubt` drops and pickups settled before
   they are projected (B7 F2), `rp_inventory:settled(opId, state)`, and B7's `pairs` fix (F1).

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
| `char:<subject>` | `open77_transactions:subjectOf(playerId)`: the account id by default (also the default character id, A13 §3.1.1/§12.8), an override provider's key otherwise (`<accountId>~<n>`); a refusal is passed through, never replaced by the account id | missing subject, characters outside `[A-Za-z0-9_.@~-]` |
| `stash:<stashId>` | the caller's stash id, legacy rule `^[%w_%-:%.]+$` ≤ 64 (`home:<homeId>`) | `session…` (`session_key`), all digits and `trunk:/vehicle:/prop:/entity:/player:/drop:/loot:<digits>` (`runtime_id_key`) |
| `veh:<PLATE>:<part>` | the plate, upper-cased; part `^[a-z][a-z0-9_]*$` ≤ 16 | an all-digit plate (`runtime_id_key`), bad part (`invalid_part`) |
| `world:<id>` | minted by the coordinator (`openWorld`: `world:<serverTag>.<boot36>.<n36>`), never chosen by a caller | anything else (`invalid_world_id`; `createWorld` with `opts.worldId` too) |
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
  `vehicleAccount`, `worldAccount`, `registerAuthorizer`, and since the reconcile `grantPockets(opId, playerId,
  ttlMs?)`: the calling resource (one of `Config.pocketGrantees`, default `rp_salvage`, `rp_economy`, `rp_cargo`)
  may touch that loaded player's pockets in the one operation `opId` (the coordinator's `authorize`, spent when it
  commits or is fenced, 30 s by default). It is what lets a server keep `char` to `rp_inventory` in the
  coordinator's `writers`.
- **Event (reconcile):** `rp_inventory:settled(opId, state)` when an async operation answered `in_doubt` settles
  in the background (`committed`, or the not-committed state: `aborted`, `failed`...).
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
| `in_doubt` | unknown after 20 s; holds are kept and settlement continues in the background; poll `status(opId)` or listen to `rp_inventory:settled` |
| `mint_denied`, `mint_cap_exceeded` | the coordinator's mint rules (contract §12.6) refuse a credit out of `sys:<caller>`; a write-behind `add` is refused at once when `allowed()` already says so |
| `aborted` | the caller's `opId` was fenced by an earlier `in_doubt`: it can never commit, use a new one. A merely **failed** `opId` (refused, `store_unavailable` without a fence, `conflict`) is a fresh attempt when reused |
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
- **Readiness.** Three steps form a handshake:
  1. `info()` must answer `ready = true` (the coordinator booted its store; a `refused` phase is logged once).
  2. An `opId` prefix through `newOpId`. The prefix is unique per coordinator boot, so rp_inventory-minted
     operation and instance ids cannot collide (world ids are the coordinator's).
  3. The definitions are pushed.

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

- **A drop is a container.** `/drop` mints a `world:<id>` container through `openWorld`, with the metadata
  `{ owner = "rp_inventory", kind = "drop", item, count, x, y, z, bucket }` and `expiresAt` = now + `dropTtlMs`;
  the native loot is its projection (A13 §6.1, option (b)). The loot is created, then one operation moves the
  goods from `char` to `world`. A refusal removes the loot and closes the empty container, so a refused drop
  still costs nothing.
- **Pickup.** A pickup is one `world` → `char` operation under the coordinator's capacity check; the emptied
  container is closed (`close`). A refused pickup leaves the goods in the container and re-creates the loot
  **where it lay**, not at the picker's feet (B8 §3.5).
- **In doubt (B7 F2, reconcile).** A drop answered `in_doubt` projects nothing until it settles: a commit is
  projected where it was dropped, a fence closes the empty container. A pickup answered `in_doubt` is not
  re-projected unless it settles not committed. Offline: `test_in_doubt_drop_and_pickup_settle_their_projection`.
- **Expiry and restart.** Expiry evaporates the goods through a journaled `inv.expire` operation, then closes
  the container. An rp_inventory restart loses the loot projection (A13 F4) but not the goods: at the next
  handshake `reprojectDrops` pages `listWorld`, projects every `rp_inventory` drop again where it lay for the rest
  of its time, evaporates an expired one and closes an empty one (`Config.reprojectLimit`, 500).
- **Not fixed here:** the native pickup still grants the loot record (`Items.money` by default, A13 P3) to the
  picker's game inventory.

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
   - The coordinator must report `store = "sql"` and `ready` (`info()`, asked at every import), or the import is
     refused with `store_not_durable`.
2. **Commit.** The legacy rows become lines from `sys:migration` in chunks of at most 40 lines. Plain rows
   become stack lines. Rows of a unique item become instances whose ids derive from the subject, the item and
   the unit index (`mig1.<fnv(account)>.<item>.<k>`), so the lines of a rerun are byte-identical.
   - **Attempt sequence.** Each chunk walks a **deterministic** attempt sequence: `mig1:<account>:c<k>`, then
     `….a2`, `….a3` … (at most 8). Under the final coordinator's rule (contract §13.5) a **failed** id (a store
     that said no, a conflict, an expired or cancelled reservation) is retried as itself (a fresh attempt, at
     most 3 times per run); only a **fenced** id (`aborted`, A13 §4.4) moves the chunk to the next id. At most one
     id of a chunk can ever commit. An account whose subject carries `~` is named by its hash in the id.
   - **Mint rule.** The import creates value out of `sys:migration`: without a coordinator rule allowing it
     (`rp_inventory sys:migration * <cap>`, or `rp_inventory sys:* * <cap>`) the subject is refused `mint_denied`
     before any chunk, with no marker (`allowed()`).
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

- **Engine and sources.** It needs a Lua 5.4 engine. The coordinator is the vendored final copy
  (`tests/compat/vendor/open77_transactions`, Open77 `697e9e2f`); `OP77_TX_DIR` (or the older `OP77_TX_ROOT`)
  points the suite at another copy. Tests skip with the reason if the engine is missing.
- **Reconcile result (2026-10-12):** `test_compat_inventory.py` 22 tests, OK (about 3.5 s); the whole
  `python -m unittest discover -s tests -p "test_*.py"`: 85 tests, all pass except the pre-existing
  `test_held_actions` (needs `lupa`). Harness: `tests/compat/txsandbox.lua` (the coordinator's own environment,
  threads, exports and events on the fake host) and `tests/compat/txshim.lua` (the only seam: the memory store in
  place of the MySQL bridge). The test server's tunables are in `txhost.lua` (`TX.TUNABLES`: `writers = *`, mint
  rules for `rp_inventory` and the scenario writers).
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
| migration | golden, idempotent, crash between commit and marker (also across a coordinator restart), a fenced first attempt (same run moves to `.a2`), a store failure (the rerun retries the same id), lost markers (no double import), unique items as derived instances, version mismatch, divergence + accept, non-durable store (the real `lab_kvp` boot), layout mismatch, unknown import, no mint rule for `sys:migration` |
| final API (reconcile) | override subject provider keys the pockets, its refusal passes through; mint rules (unlisted source refused at once, burn allowed, over-cap credit compensated); per-part writers (`veh/trunk` yes, cargo no); lazy read creates nothing; minted world ids; failed `opId` fresh, fenced `opId` aborted; `info().ready` gates the handshake; `grantPockets` |
| in doubt (reconcile, B7 F2) | committed drop projected after it settles, committed pickup not re-projected, fenced drop closed; `rp_inventory:settled` |

What the tests **cannot** establish is listed in §8.

## 6. Residual risks

- **Write-behind is no stronger than before** (decision §7.4 (i)). A legacy `add` accepted optimistically can be
  lost if another resource changes the same account first, or if rp_inventory stops with a queued write (logged
  at stop). Flows that move value (C1 sale, salvage credit, cargo) must use the async exports.
- **Coordinator holds are not in the synchronous views.** A reservation by another resource is visible only
  after its commit event, so a synchronous `remove` can be accepted and then LOST.
- **Weight drift across restarts:** handled by the coordinator (`reweigh` operations, contract §13.5).
- **Stash, vehicle and world views stay loaded** for the generation. They are bounded by usage; world views are
  released after pickup.
- **`sellAsync` stays opt-in** (`Config.coordinatorWallets`): B3 owns the wallets now, and `rp_economy:sale` is
  the usual path (it applies the money allowlist per original caller); `sellAsync` mints as `rp_inventory` and
  needs a coordinator rule `rp_inventory sys:<buyer> money <cap>`.

## 7. Coordinator API needs (A13): resolved by Open77 `697e9e2f`

Reconciled 2026-10-12 (branch `wi/reconcile-a13`) against the final coordinator, contract §7.2 and §13.7.

| # | Need (wave 0) | Outcome | How the facade uses it now |
|---|---|---|---|
| 1 | `info()` export | resolved | the handshake waits for `info().ready`; the migration requires `store = "sql"` (`lab_kvp` refused, tested on the real lab boot) |
| 2 | lazy `read`, `exists = false` for a missing container | resolved (answers `unknown_account`, never creates) | `Facade:load` passes `unknown_account` through; `vehicle*Async` map it to `vehicle_not_tracked`, `world*Async` to `unknown_container`; the `read` export keeps its shape (`exists = false`) |
| 3 | a failed `opId` should not replay its failure | changed (§13.5): failed = fresh attempt, fenced = `aborted` for ever | write-behind keeps its `.rN` suffixes (always safe); a caller's `opts.opId` may be reused after a failure, not after `aborted`; the migration retries a failed id and moves on only past a fenced one |
| 4 | replay check before holds | resolved | nothing to do: a committed `opId` this VM never saw replays |
| 5 | container `meta`, a `world:` listing | resolved (`openWorld`, `setMeta`, `close`, `list`, `listWorld`) | drops are minted with their metadata and expiry, closed when empty, re-projected after a restart |
| 6 | weight drift | resolved (`reweigh`) | none |
| 7 | caps per `sys:` account | resolved (`mint1..6`: `<resource> <sys:name or sys:*> <item, * or money> <cap>`) | `allowed()` refuses a write-behind credit at once when no rule allows it (`mint_denied`); `mint_cap_exceeded` reported by the coordinator is a LOST write-behind (an hour's wait would hold the account's queue) and passed through on async calls |
| 8 | `open77_transactions:committed` | resolved | unchanged: foreign commits reload the shown views |
| 9 | `subjectOf` | resolved | `char:<subject>` everywhere (the legacy rows stay keyed by the identifier) |
| 10 | single item definer | policy | unchanged: define through `rp_inventory:define` |

**Per-part writers** (A9 N4, `writers = "rp_inventory:char+stash+world+veh/trunk+veh/glovebox, rp_cargo:veh/cargo"`)
work as is; a resource that must touch the pockets without `char` asks `grantPockets` (rp_cargo and rp_economy do).

**Operator configuration** (the coordinator's tunables): nothing mints by default, so a server running the
transactions backend needs at least `rp_inventory sys:* * <cap>` (legacy `add` callers, `/use`, admin, migration)
or one rule per `sys:<caller>` it wants to cap separately.

**What remains (not in the final coordinator):**
- the mint-rule grammar names one `sys:` segment (`sys:<name>` or `sys:*`): fine for `rp_inventory`'s
  `sys:<caller>` accounts, not for multi-segment names (B3's `sys:<resource>:<label>`);
- `allowed()` takes no amount, so it cannot see that the next credit would pass a cap; only an exhausted cap;
- `status` always yields (through the work queue), even for an operation this VM holds in memory; B7 asked for a
  cheap one, and `rp_inventory:settled` covers the panel meanwhile;
- `open77_transactions:committed` does not name the invoking resource (A9 N5), so the facade still tracks its own
  operation ids (bounded at 4,096);
- a `metaPatch` cannot delete a key (`false` is stored as `false`).

## 8. What the integrator must run in game

None of this was run. The backend is opt-in; `open77_transactions` (Open77 `697e9e2f`) has its manifest and
exports now, and needs the mint rules above in its tunables.

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
   - Restart the server (or only `rp_inventory`): the drops come back where they lay (`re-projected N drop(s)`),
     their goods in `world:` containers (`op77_tx_containers`, with their `meta`).
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
