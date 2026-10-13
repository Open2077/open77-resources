# B8 compatibility and migration audit: the community RP pack (wave 0)

**Row:** B8 of the world-interaction plan (`wt-world-interaction/docs/world-interaction-plan.md` §4 B). Wave 0 is
the audit; wave 1 is the suite. **Date:** 2026-10-12.
**Baseline:** `Open2077/open77-rp-examples` `origin/main` `5dcdad2`, worktree `C:\Games\cyberm\wt-wi-rp`, branch
`wi/b8-compat`.

**Method.**
- **Static read.** Every file of the 18 audited resources was read, server files in full. `rp_config`,
  `rp_identity`, `rp_inventory`, `rp_economy`, `rp_bank`, `rp_jobs`, `rp_selftest`, `rp_ferrailleur` and `rp_nomade`
  were read directly.
- **Read-only sub-audits.** Three of them covered `rp_garage`/`rp_housing`, `rp_shops`/`rp_shop`/`rp_mecano`/`rp_bar`
  and `rp_medic`/`rp_trauma`/`rp_ripperdoc`/`rp_crime`. Their claims are code-cited, and a sample of each was
  re-verified at source.
- **Mechanical checks.**
  - `luac -p` (Lua 5.4.8) over the 110 non-manifest Lua files: 0 failures.
  - A BOM scan: none found.
  - A cross-resource call extractor, run on all 41 `rp_*` resources.
- **Offline execution.** `rp_economy` was executed offline (§6.2).

Nothing was deployed or launched, no server or database was started, and no `open77_*` tool was called. No
resource behaviour was changed.

**Conventions.**
- Unmarked statements are **facts** seen in source, a log string or a measurement. **Inference** needs a
  measurement. **Open** is a question.
- `path:line` is relative to the repository root. The worktree checks files out with CRLF (`core.autocrlf=true`),
  which does not change line numbers.
- "Session id" means the per-connection `playerId`/`source`. "Identifier" means `Open77.players.identifier(playerId)`.

---

## 0. Summary

**Identity in two lines.**
- Every durable RP record (wallet, pockets, account, job, citizen card, vehicle owner, deed, key, tool wear,
  contract log) is keyed by the **account identifier**: the platform `userId`, one per account. The pack has
  **no character id** (`rp_identity_citizens.identifier` is `UNIQUE`, `rp_identity/server/main.lua:317`).
- Every *live* operation is keyed by the **session id**, and the wallet and pocket exports refuse a player who is
  not connected and loaded. Vehicles are keyed by **plate**, containers by a free **stash string** (`home:<homeId>`),
  societies by **job name**.

**Top durability and compatibility risks** (details in §1, §3 and §5):

| # | Risk | Evidence | Rows hit |
|---|---|---|---|
| R1 | **Per-boot SQL→KVP failover with no reconciliation** in 15 audited resources. A string scan finds the same pattern in at least 11 of the 13 other resources that combine SQL and KVP. A database that is late or unavailable at boot silently gives every player a fresh or stale wallet, empty pockets, no job and no citizen record for that boot. What happens in that boot is never merged back. Measured offline for `rp_economy`: 1 500 €$ in SQL, 500 on the KVP boot, +700 earned, 1 500 again on the next SQL boot. **B3 update (2026-10-12): closed for `rp_economy` and `rp_bank`** (facades over `open77_transactions`, no KVP; `b3-wallet.md`); the other resources are unchanged. | §3.4; `tests/test_compat_economy.py` | B2 B3 B4 B8, plan §3 "Database failure", decision 2 |
| R2 | **No multi-store atomicity and no receipts.** `Open77.database.transaction` is never used. Every write is an asynchronous absolute snapshot, and failures are logged or ignored. Item↔money flows are 2–6 separate export calls whose compensations are unchecked. Wallets and pockets are **online-only**, so a refund to a disconnected player always fails. | §3.5 | A13 B2 B3 C1 |
| R3 | **Account = character, plus non-durable ids in durable places.** There are `"session:<id>"` fallbacks in SQL, session ids inside bank ledger notes, runtime vehicle ids in `rp_mecano_impound` and `rp_shop` KVP, and `"vehicle#<id>"`/`"prop#<id>"` log targets. | §1.3 | B2 A9 B8 |
| R4 | **Unversioned schemas and implicit cross-resource SQL contracts.** 47 tables use `CREATE TABLE IF NOT EXISTS` only: no version table and no `ALTER`. `rp_mdt` reads 8 tables owned by 5 other resources, and `rp_phone` reads `rp_identity_citizens`. | §3.1, §3.6 | B8 migration gate |
| R5 | **Registries and claims live in memory.** Item definitions (last writer wins), loot drops, wreck claims, convoy contracts and cargo, Trauma "down" state, ripperdoc operations in flight and pending weapon refunds all live in memory. A resource restart loses value or duplicates it. The housing stash passes to the next owner. | §1.4, §3.5 | B1 B2 A6 A9 C1 C2 C7 C8 |

Further notable findings:
- **Config overrides are mostly no-ops.** The `rp_config` catalogue has 793 keys, but only `rp_ambiance`,
  `rp_crime` and `rp_radio` read overrides, so `/config set` on any other section does nothing (§2.5).
- **Duplicate systems run by default.** `rp_shop` (v1) and `rp_shops` both auto-start; `rp_shop` keeps its own
  KVP vehicle ledger keyed by runtime id. `rp_medic` and `rp_trauma` both register `/soin` `/reanimer` `/911`
  `/medic`.
- **`rp_selftest` writes to the live database on every boot** (§6.1).

**What `rp_ferrailleur` already gives the C1 pilot** (details in §4.1):
- Seven wreck nodes with a server-side `ready/busy/depleted` claim and a regen timer.
- Reach, height, zone and duty gates.
- A tool requirement with wear.
- A weighted loot table into `rp_inventory`.
- A dealer NPC with drifting prices and a 10 % society share.
- The staging pattern and two host events, `rp_ferrailleur:searched` and `rp_ferrailleur:sold`.

What it lacks:
- **No physical custody:** salvage is item counts in pockets, with no carry, truck or storage.
- **No durable node or claim state.**
- **Not atomic:** loot is rolled and the node depleted *before* capacity is checked; the sale removes items
  before a 3 s bar and pays afterwards.
- **Wear is per scrapper, not per crowbar.**

**Recommended wave-1 suite** (details in §6.3): four layers on two offline engines.
- **L0, static:** contracts, schema snapshot, manifests, BOM, `luac`.
- **L1, contract tests:** the real server scripts on a fake host — economy, inventory, bank, jobs, identity,
  then ferrailleur and nomade.
- **L2, migration fixtures and fault injection:** golden pre-migration stores, a "crash between steps" sweep,
  and expected-failure invariants per gap.
- **L3, live:** an `rp_selftest` v2 (lab only, no writes to production) plus the §5.3 two-client matrix run by the
  integrator.

L0 and an L1 seed ship with this row: 9 tests, all green, one expected failure that documents R1.

---

## 1. Identity model

### 1.1 Platform facts

- `Open77.players.identifier(playerId)` returns the account's durable `userId`. The platform says to key
  persistent data on it, and that `0` or a negative id throws past `pcall` (`wiki/data/api.json`, entry
  `Open77.players.identifier`).
- `Open77.players.identifiers` exposes `open77`/`userId`, `name`, `fingerprint` and `joinedAt`. It deliberately
  has no `license`, `steam` or `discord`.
- The platform table lists `userId` as the key for "Characters, inventories, bans, ACLs, progression"
  (`wt-world-interaction/wiki/identity.md:7-13`). There is no platform character id.
- Server KVP is "one JSON file under this resource's own `data/` directory": 4 096 entries, 1 MiB.
  `Open77.database` is the store to use for data that must "survive the resource directory being redeployed"
  (`wt-world-interaction/wiki/server-api.md:574-575`; API entry `Open77.kvp.set`). `rp_economy/README.md:33` says
  the same thing about the pack's own KVP fallback ("wiped by a redeploy that replaces the folder").

### 1.2 Keys per resource

| Resource | Player / character | Vehicle | Container / other | Source |
|---|---|---|---|---|
| `rp_identity` | identifier, one row per account; `id` (NCID number) is internal and **not exported** | — | — | `rp_identity/server/main.lua:303-325`, `:682-710` |
| `rp_economy` | identifier (`rp_economy_wallets.identifier` PK); live map by session id | — | — | `rp_economy/server/main.lua:46-53`, `:75-80` |
| `rp_bank` | identifier (`rp_bank_accounts.identifier`); `"society:<name>"` in the ledger | — | society = lower-cased name, in practice the job name | `rp_bank/server/main.lua:31-34`, `:90-94`, `:372`, `:1165-1176` |
| `rp_inventory` | identifier (`rp_inventory_items`); live map by session id | none (no trunk exists) | stash id = caller string `^[%w_%-:%.]+$`, ≤64; capacity is caller-supplied and **not stored** | `rp_inventory/server/main.lua:14-16`, `:1088-1098`, `:919`, `:1226-1242` |
| `rp_jobs` | identifier (`rp_jobs_employees` PK); duty in memory only | — | job name = society name = fleet owner `"society:<job>"` | `rp_jobs/server/main.lua:83-86`, `:176-186`; `rp_garage/server/main.lua:26` |
| `rp_garage` | owner/holder = identifier, or `"society:<job>"` | **plate** `NC-XXXX` (PK); runtime id only in memory | keys `(plate, holder)` | `rp_garage/server/main.lua:213-225`, `:271-299` |
| `rp_housing` | owner = identifier, one home per identifier | — | home = config key (`home_id` PK); stash `"home:"..homeId` **per property** | `rp_housing/server/main.lua:124-145`, `:1096` |
| `rp_ferrailleur` | identifier (`rp_ferrailleur_tools`) | — | wreck = config index (memory) | `rp_ferrailleur/server/main.lua:15-18`, `:898-902` |
| `rp_nomade` | contract by session id (memory); history row by identifier **or `"session:<id>"`** | rental truck = runtime id (memory) | crates = runtime prop ids (memory) | `rp_nomade/server/main.lua:18`, `:826-854` |
| `rp_shops` | licence/sales buyer = identifier (or `"?"` in sales) | — | `stock[shopId][itemId]` | sub-audit: `rp_shops/server/main.lua:57-63`, `:349`, `:381-410` |
| `rp_shop` (v1) | KVP `garage:<identifier>` | **runtime vehicle id persisted** | — | sub-audit: `rp_shop/server/main.lua:156-158`, `:321-327` (verified) |
| `rp_mecano` | session ids live; SQL identifiers fall back to `"session:<id>"` | **runtime `vehicle_id` persisted**; plate from state bag | — | sub-audit: `rp_mecano/server/main.lua:165-177`, `:582-583`, `:1235` |
| `rp_bar` | session ids live; ledger identifier or `"session:<id>"` | — | till = society `barman` | sub-audit: `rp_bar/server/main.lua:388-389` |
| `rp_trauma` | contracts and bills by identifier; "down" by session id (memory) | AV = runtime id (memory) | — | sub-audit: `rp_trauma/server/main.lua:34`, `:203-222`, `:1483` |
| `rp_ripperdoc` | log by identifier **or `"session:<id>"`** | — | implant = platform record; `operationId` never stored | sub-audit: `rp_ripperdoc/server/main.lua:841-846`, `:892-894` |
| `rp_crime` | `identifierOf` = identifier **or `"session:<id>"`** | `wanted[runtime id]` (memory); plate via `rp_garage` | crate = runtime prop id (memory) | `rp_crime/server/main.lua:56-58` (verified), `:269-279`, `:992` |
| `rp_medic` | session ids; KVP counters by identifier | — | — | sub-audit: `rp_medic/server/main.lua:145-165` |

**Consequence for "character" adapters (inference).** A B2 "character container" is the account today. Adding a
character layer means re-keying, or adding a column to, every `identifier` column of the 47 tables and every
`<prefix>:<identifier>` KVP key. Keep the account as the default character so no existing row needs to move.

### 1.3 Non-durable identifiers that reach durable storage

| Where | What is stored | Line |
|---|---|---|
| `rp_nomade_contracts.identifier` | `"session:<id>"` when the identifier is missing | `rp_nomade/server/main.lua:829` (contradicts `rp_nomade/README.md:246`) |
| `rp_nomade` society note | `"nomade:contract:<localId>"` while the insert is pending; `localId` restarts at 1 every boot | `rp_nomade/server/main.lua:22`, `:918` |
| `rp_bank_transactions.note` | `"scrap_sale:<sessionId>"`, `"crowbar_sale:<sessionId>"` | `rp_ferrailleur/server/main.lua:723`, `:774` |
| `rp_bank_transactions.note` | `"bill:<sessionId>"`, `"impound:<runtimeVehicleId>"` | `rp_mecano/server/main.lua:632`, `:1242` |
| `rp_ripperdoc_operations.ripper/patient` | `"session:<id>"` fallback | `rp_ripperdoc/server/main.lua:841`, `:843`, `:1344` |
| `rp_crime_log.identifier` / `.target` | `"session:<id>"`, `"vehicle#<runtimeId>"`, `"prop#<runtimeId>"` | `rp_crime/server/main.lua:56-58`, `:825`, `:1107` |
| `rp_mecano_invoices`, `rp_mecano_impound.by_identifier` | `"session:<id>"` | `rp_mecano/server/main.lua:582-583`, `:1235` |
| `rp_mecano_impound.vehicle_id` | runtime vehicle id (BIGINT) | `rp_mecano/server/main.lua:165-177`, `:219-225` |
| `rp_bar_sales.barman/customer` | `"session:<id>"` fallback | `rp_bar/server/main.lua:388-389` |
| `rp_shop` KVP `garage:<identifier>` | `{ id = runtimeVehicleId, record, ... }`, reused after reload | `rp_shop/server/main.lua:200-215`, `:318-330` |

The `"session:"` fallbacks fire only when the identifier is nil. **Inference:** that is rare, because the
identifier exists for every authenticated player. The ledger notes and runtime vehicle ids, by contrast, are
written on every use.

### 1.4 In-memory state that matters and is lost on a resource or server restart

| State | Consequence | Line |
|---|---|---|
| `rp_inventory` item registry (`define`) | Rows of ids not yet re-defined are skipped at load; players loaded in that window never see them until they reconnect | `rp_inventory/server/main.lua:356-358`, `:243`, `:251` |
| `rp_inventory` `drops` map (loot id → item) | A drop picked up after an `rp_inventory` restart is "unknown" and credited to nobody: the item is destroyed | `:16`, `:596-606` |
| `rp_inventory` stash panel session | Authorisation is checked only at `openStash`; an open panel keeps store/take after the key is revoked (**inference**) | `:1016-1044`, `:1088-1098` |
| `rp_ferrailleur` wreck states, claims and prices | Every wreck is back `ready` after a restart (documented) | `rp_ferrailleur/server/main.lua:15-17`; README `:145-146` |
| `rp_nomade` contracts, crates, truck | A crash mid-run loses the 100 €$ deposit (taken, never refunded); the SQL row stays `active` | `rp_nomade/server/main.lua:18`, `:791`; README `:457-458` |
| `rp_jobs` duty | Never restored; cleared on stop and disconnect | `rp_jobs/server/main.lua:1087`, `:1175-1187` |
| `rp_trauma` `down[playerId]` | A disconnect or a resource stop frees the player with no bill and a full heal | sub-audit: `rp_trauma/server/main.lua:1733-1737`, `:1808-1815` |
| `rp_ripperdoc` `ops`/`tickets` | An operation in flight after payment is lost on restart, with no receipt row | sub-audit: `rp_ripperdoc/server/main.lua:420-423`; README `:297-298` |
| `rp_shops` `pendingWeapons` | Payment taken, refund timer in memory | sub-audit: `rp_shops/server/main.lua:1015-1025` |
| `rp_crime` `guttedCrates` | The same crate can be gutted again after an `rp_crime` restart | `rp_crime/server/main.lua:1086-1096` (verified) |
| `rp_garage` vehicle condition/fuel while out | Persisted only on store, impound or loss; after a crash the row comes back `stored` with the take-out snapshot | sub-audit: `rp_garage/server/main.lua:585-610`, `:385`, `:420-425` |

---

## 2. Contracts

### 2.1 Core provider exports (what B1–B4 must keep answering)

All are synchronous and non-yielding, and consumers call them inside `pcall`. A "consumer" is a resource that
calls the export from another resource (`tests/compat/contracts.py`, frozen in `tests/test_compat_contracts.py`).

| Export | Arguments → return / refusal tokens | Consumers |
|---|---|---|
| `rp_economy:getBalance` | `(playerId)` → integer, **0 when unknown or offline** (`rp_economy/server/main.lua:506-512`) | 11 |
| `rp_economy:add` / `remove` | `(playerId, amount, reason?)` → newBalance \| `nil`, `invalid_player_id`/`player_not_found`/`invalid_amount`/`invalid_reason`/`insufficient_funds`/`balance_limit`. `reason` ≤64 bytes, no control characters. **Online and loaded players only** (`:474-544`) | 19 / 20 |
| `rp_bank:getAccount` | `(playerId)` → `{identifier, balance, createdAt}` \| `nil, reason`. Creates the account on first sight (`rp_bank/server/main.lua:201-209`, `:273-277`) | 5 |
| `rp_bank:deposit` / `withdraw` | `(playerId, amount)` → account balance \| `nil`, `insufficient_cash`/`insufficient_funds`/`wallet_unavailable`/… (`:279-313`) | 2 / 3 |
| `rp_bank:transfer` | `(fromPlayerId, toIdentifier, amount, fee?)`. The recipient may be **offline** (by identifier) (`:317-350`) | 0 external (ATM, `/virement`) |
| `rp_bank:society` / `societyAdd` / `societyRemove` | `(name[, amount, reason])` → `{name, balance}` \| balance \| `nil`, `invalid_society`/`bank_not_ready`/`insufficient_funds`/`balance_limit`. The note is ≤128 bytes (`:352-394`) | 6 / 15 / 8 |
| `rp_bank:charge` | `(playerId, amount, society, reason)`: account → society within rp_bank memory (`:398-420`) | 8 |
| `rp_inventory:define` | `(items)` → `registered, rejected` (**counts**). Id `^[%l%d_]+$`, label ≤48, weight 0..100; silently overwrites; records `definedBy` (`rp_inventory/server/main.lua:359-380`) | 10 |
| `rp_inventory:add` / `remove` | `(playerId, itemId, count?)` → `true` \| `nil`, `invalid_player`/`player_not_found`/`not_loaded`/`unknown_item`/`invalid_count`/`too_heavy`/`not_enough` (`:297-327`, `:389-395`) | 10 / 9 |
| `rp_inventory:has` / `count` | → boolean / number; **`false`/`0` when the player is not loaded** (`:382-401`) | 9 / 6 |
| `rp_inventory:list` | → `entries, weight, capacity` \| `nil, reason` (`:405-409`) | 3 |
| `rp_inventory:openStash` | `(playerId, stashId, capacity?)` → `true` \| `nil`, `invalid_stash`/`invalid_capacity`/reason. **No authorisation; the caller decides** (`:1088-1098`) | 1 (`rp_housing`) |
| `rp_jobs:getJob` / `hasJob` / `getGrade` / `isBoss` / `onDuty` | name \| nil; boolean (aliases `police`→`ncpd`, `medecin`→`trauma`, `taxi`→`delamain`); `{level,label}`; boolean; boolean. **`false`/`nil` while the record is not loaded** (`rp_jobs/server/main.lua:988-1018`; aliases `rp_jobs/shared/config.lua:41-45`) | 14 / 16 / 4 / 3 / 15 |
| `rp_jobs:setJob` / `listOnDuty` / `salary` | `true` \| `nil`, `invalid_player_id`/`player_not_found`/`not_loaded`/`unknown_job`/`reserved_job`/`invalid_grade`; `{playerId…}` ascending; integer (`:1020-1074`) | 1 / 11 / 0 |
| `rp_identity:get` / `fullName` / `isRegistered` | `{firstName,lastName,birth,sex,origin}` \| nil; string (falls back to the account name, then `"Unknown citizen"`); boolean (`rp_identity/server/main.lua:682-710`) | 2 / 23 / 3 |
| `rp_config:get` | `(key, default)` → override, else catalogue default, else `default` (`rp_config/README.md:37-79`) | 3 + selftest |

Other exports used across resources:
- `rp_garage`: `hasKey`, `ownerOf`, `plateOf`, `setWanted`, `vehiclesOf` (consumers `rp_crime`, `rp_mdt`).
  `vehiclesOf` returns the **runtime** `vehicleId` (sub-audit: `rp_garage/server/main.lua:1163-1180`).
- `rp_housing:homeOf` (consumer `rp_gangs`).
- `rp_nomade:activeContract` (consumer `rp_crime`). It returns the runtime `truckId` and an `id` that is the row id
  or the per-boot local id (`rp_nomade/server/main.lua:1648-1665`).
- `rp_needs:get`/`consume`/`apply` are declared through the manifest `server_exports` block, not by `exports()`
  (`rp_needs/open77.lua:28`). An extractor that only looks for `exports(` misses them.

**Mechanical result.** Every cross-resource server export call in the pack resolves to a declared export
(`test_every_cross_resource_call_targets_a_declared_export`). No client manifest depends on a server-only resource
(`test_client_manifests_do_not_depend_on_server_only_resources`).

### 2.2 Host-bus events (TriggerEvent) and who listens

| Event | Payload | Listeners |
|---|---|---|
| `rp_economy:changed` | `(playerId, newBalance, delta, reason)` (`rp_economy/server/main.lua:463`) | `rp_hud`, `rp_selftest` |
| `rp_bank:changed` | `(playerId \| nil, identifier, newBalance, delta, kind)`; `playerId` is nil for societies and offline recipients (`rp_bank/server/main.lua:239-242`) | `rp_hud` |
| `rp_inventory:changed` / `rp_inventory:used` | `(playerId, itemId, delta)` / `(playerId, itemId)` (`rp_inventory/server/main.lua:307`, `:324`, `:538`) | `rp_radio` / `rp_bar` |
| `rp_jobs:changed` / `rp_jobs:duty` | `(playerId, name \| nil)` / `(playerId, name, onDuty)` (`rp_jobs/server/main.lua:403`, `:371`) | 11 resources each |
| `rp_identity:changed` | `(playerId)` (`rp_identity/server/main.lua:559`, `:675`) | `rp_hud`, `rp_phone` |
| `rp_garage:changed` | `(owner, plate, action)`; for key actions the first argument is the owner | `rp_crime` |
| `rp_housing:changed` | `(identifier, homeId, action)`; for key actions the first argument is the holder | none |
| `rp_ferrailleur:searched` / `:sold` | `(playerId, index, itemId, count)` / `(playerId, total, payout, cut)` (`rp_ferrailleur/server/main.lua:637`, `:738`) | none |
| `rp_config:changed` / `:reloaded` | `(key, value)` / `(count, source)` | none |
| `rp_zones:entered` / `:left` | `(playerId, name)` | 7 resources, including `rp_nomade` (`:1548-1581`) |

`rp_nomade` raises no host event.

Client↔server net events (`rp_inventory:intent`, `rp_nomade:pickup|load|unload|return`, `rp_ferrailleur:search`,
…) are internal transport, not API: the READMEs say so (for example `rp_ferrailleur/README.md:105-109`). Adapters
may replace them.

### 2.3 Operator-facing commands an adapter must not break

| Resource | Commands |
|---|---|
| `rp_economy` | `/money`, `/pay`, `/givemoney` (ACL), `/payday` (ACL) (`rp_economy/server/main.lua:699-803`) |
| `rp_inventory` | `/inv`, `/use`, `/drop`, `/ramasser`, `/give`, `/fouiller`, `/saisir`, `/giveitem` (ACL) (`rp_inventory/server/main.lua:1112-1187`) |
| `rp_bank` | `/bank`, `/solde`, `/virement`, `/societe` (`rp_bank/server/main.lua:1120-1179`) |
| `rp_jobs` | `/jobs`, `/job`, `/service`, `/agence`, `/embaucher`, `/virer`, `/promouvoir`, `/setjob` (`rp_jobs/server/main.lua:709-950`) |
| `rp_identity` | `/carte`, `/montrercarte`, `/civil` (ACL) |
| `rp_ferrailleur` | `/ferraille`, `/vendre` |
| `rp_nomade` | `/convoi [annuler]`, `/convois` (boss), `/camp`, `carrytune` (console lab) |

### 2.4 Dependency graph

There are two tiers.
- **Hard `dependency` lines.** They are allowed only towards resources that ship a client half when the manifest
  itself ships one. `rp_economy`, `rp_config`, `rp_crime`, `rp_medic`, `rp_needs`, `rp_logs`, `rp_whitelist`,
  `rp_chat`, `rp_shop`, `rp_selftest` and `rp_taxitest` ship none.
  - `rp_selftest` → `rp_economy`, `rp_jobs`, `rp_identity`, `rp_inventory`, `rp_bank`, `rp_needs`
    (`rp_selftest/open77.lua:8-13`).
  - `rp_crime` → 9 `rp_*` resources (`rp_crime/open77.lua:26-34`).
  - `rp_mecano` → `rp_jobs`, `rp_inventory` (`rp_mecano/open77.lua:45-46`).
  - `rp_medic` → `rp_economy`, `rp_jobs` (`rp_medic/open77.lua:29`).
  - `rp_shop` → `rp_economy`.
  - `rp_chat` → `rp_jobs`, `rp_economy`.
- **Runtime `pcall` calls.** Everything else reaches its providers this way and degrades with a chat line. Several
  manifest comments call `rp_jobs`/`rp_inventory`/`rp_bank` "server-only", but all three ship a client script
  (`rp_jobs/open77.lua:27`, `rp_inventory/open77.lua:25`, `rp_bank/open77.lua:24`). The comments are stale and the
  behaviour is correct.

Runtime fan-in (resources calling the provider): `rp_economy` 25, `rp_jobs` 25, `rp_identity` 24, `rp_bank` 19,
`rp_inventory` 15, `rp_garage` 3, `rp_config` 3 (plus `rp_selftest`).

The pilot pair:

```text
rp_ferrailleur -> rp_jobs(hasJob,onDuty) rp_zones(isIn) rp_inventory(define,count,has,add,remove)
                  rp_economy(add,remove) rp_bank(societyAdd)
rp_nomade      -> rp_identity(fullName) rp_jobs(hasJob,onDuty,isBoss,listOnDuty) rp_zones(isIn)
                  rp_economy(add,remove) rp_bank(societyAdd) rp_inventory(define)
                  [client] open77_interactions(addGlobalVehicle) open77_worldui
rp_crime       -> rp_nomade(activeContract) rp_garage(...)        -- reads only, writes nothing back
```

**Direct SQL across resources.** These reads are schema contracts:
- `rp_mdt` reads `rp_garage_vehicles`, `rp_identity_citizens`, `rp_ncpd_fines`, `rp_ncpd_records`,
  `rp_ncpd_warrants`, `rp_shops_licences`, `rp_trauma_bills` and `rp_trauma_contracts`.
- `rp_phone` reads `rp_identity_citizens`.

These were found by a grep of `FROM|INTO|UPDATE|JOIN rp_*` against the table owner.

### 2.5 Configuration contract

- **The `rp_config` catalogue.** It holds 793 dotted keys across 29 sections (`rp_config/README.md:6-11`), and
  `/config set` persists them (`rp_config/server/main.lua:16-27`, `:187-208`). However, the README itself says
  "Nothing else was touched: the other resources keep their own `shared/config.lua` and are frozen"
  (`rp_config/README.md:15-16`).
  - **Readers.** The only server code that reads overrides is `rp_ambiance/server/main.lua:92`,
    `rp_crime/server/main.lua:22` (19 keys) and `rp_radio/server/main.lua:46`, plus `rp_selftest`.
  - **No-op sections.** Sections exist but are never read for `rp_economy`, `rp_bank`, `rp_inventory`, `rp_jobs`,
    `rp_ferrailleur` (`rp_config/shared/defaults.lua:203`), `rp_nomade` (`:229`), `rp_garage` (`:374`),
    `rp_shops` (`:409`), `rp_housing` (`:453`), `rp_mecano` (`:185`), `rp_bar`, `rp_trauma` and `rp_ripperdoc`.
  - **Stale keys.** Some keys are already stale against the live config, for example garage spawn points
    (sub-audit: `rp_config/shared/defaults.lua:378-382` against `rp_garage/shared/config.lua:66`, `:83`).
  - **READMEs that claim rp_config works.** `rp_housing/README.md:96-97` and `rp_trauma/README.md:177`.
    `rp_config/tools/migrate-configs.md` is the owner's to-do list for wiring them in, not a statement that they
    are wired.
  - **Platform alternative.** The platform offers `Open77.tunables`, which are typed, validated, persisted and
    operator-editable (`wt-world-interaction/wiki/server-api.md:579-584`).
- **Society names are a cross-resource contract.**
  - Job names: `ncpd`, `trauma`, `delamain`, `mecano`, `ripper`, `nomade`, `ferrailleur`, `barman`, `fixer`,
    `netrunner`, `vigile`.
  - Other names: `garage`, `housing`, and the `selftest` society created by `rp_selftest`.
  - `rp_jobs` seeds a job's society once, with a **KVP** flag `seeded:<job>` (`rp_jobs/server/main.lua:421-444`).
    **Inference:** a redeploy that wipes the KVP file re-seeds 50 000 €$ for the next first boss.

---

## 3. Persistence

### 3.1 SQL tables

There are 47 tables, all created with `CREATE TABLE IF NOT EXISTS` and none with an `ALTER` or a version. The full
normalised column lists are frozen in `tests/compat/schema-snapshot.json`. The tables the B rows inherit:

| Table | Key | Writer, and how it writes | Line |
|---|---|---|---|
| `rp_economy_wallets(identifier PK, name, balance BIGINT, updated_at)` | identifier | async upsert of the **absolute** balance on every change; a failure is only logged | `rp_economy/server/main.lua:46-59`, `:205-228` |
| `rp_bank_accounts(identifier VARCHAR(96) PK, balance, created_at)` | identifier | `INSERT` on first sight (no callback), then `UPDATE … SET balance` (a 0-row update is not detected) | `rp_bank/server/main.lua:121-135`, `:168-180`, `:439-444` |
| `rp_bank_transactions(id AI, identifier, delta, balance_after, kind, note, at)` | append only; `society:<name>` rows share the column | insert with no callback | `:154-165`, `:445-456` |
| `rp_bank_societies(name PK, balance)` | name | as for accounts | `:137-151`, `:457-462` |
| `rp_inventory_items(identifier, item_id VARCHAR(32), count, PK(identifier,item_id))` | identifier+item | per-item upsert or delete, **no callback** | `rp_inventory/server/main.lua:157-171`, `:1227-1234` |
| `rp_inventory_stashes(stash_id VARCHAR(64), item_id, count, PK(stash_id,item_id))` | stash+item | same | `:172-185`, `:1235-1242` |
| `rp_jobs_employees(identifier PK, job, grade, on_duty, hired_at, hired_by)` | identifier | full-row upsert; callbacks `function() end` | `rp_jobs/server/main.lua:176-186`, `:238-273` |
| `rp_identity_citizens(id AI PK, identifier UNIQUE, first_name, last_name, birth, sex, origin, …)` | identifier | insert / per-column update | `rp_identity/server/main.lua:304-322` |
| `rp_ferrailleur_tools(identifier PK, durability, updated_at)` | identifier | upsert, callback `function() end` | `rp_ferrailleur/server/main.lua:128-139`, `:896-910` |
| `rp_nomade_contracts(id AI, identifier, player_name, template, destination, crates, delivered, pay, bonus, society_cut, convoy, status, started_at, ended_at)` | id | insert at start, update at end; history only | `rp_nomade/server/main.lua:173-198`, `:228-273` |
| `rp_garage_vehicles(plate PK, owner, …, props TEXT, wanted, …)` | plate | full-column upsert; **never deleted** | sub-audit: `rp_garage/server/main.lua:271-289`, `:301-309` |
| `rp_garage_keys(plate, holder, holder_name, given_by, at, PK(plate,holder))` | plate+holder | `INSERT IGNORE`; delete by plate | sub-audit: `:291-299`, `:353`, `:365` |
| `rp_housing_homes(home_id PK, identifier, owner_name, paid, bought_at INT, rent_due_at INT, …)` / `rp_housing_keys` | home | upserts and deletes, all callbacks `function() end`; 32-bit timestamps | sub-audit: `rp_housing/server/main.lua:124-145`, `:157-201` |
| `rp_shops_stock` / `rp_shops_sales` / `rp_shops_licences` | shop+item / id / identifier | upsert; sales are SQL only | sub-audit: `rp_shops/server/main.lua:381-410` |
| `rp_mecano_impound` / `rp_mecano_invoices` | id | insert; **runtime `vehicle_id`** | sub-audit: `rp_mecano/server/main.lua:165-188` |
| `rp_bar_sales` | id | insert, queued until the store is chosen | sub-audit: `rp_bar/server/main.lua:360-369` |
| `rp_trauma_contracts` / `rp_trauma_bills` | identifier / id | upsert / insert; a bill is marked paid only if its row id is known | sub-audit: `rp_trauma/server/main.lua:203-222`, `:293-316` |
| `rp_ripperdoc_operations`, `rp_crime_log` | id | insert after the fact | sub-audit |

### 3.2 KVP keys (server, per resource)

| Resource | Keys | Used |
|---|---|---|
| `rp_economy` | `balance:<identifier>`, `migrated:sql` | in fallback; marker once (`rp_economy/server/main.lua:40-41`) |
| `rp_bank` | `acct:<identifier>`, `acct_created:<identifier>`, `soc:<name>` | fallback; the ledger stays in memory (`rp_bank/server/main.lua:131-176`, `:214-233`) |
| `rp_inventory` | `inv:<identifier>:<item>`, `stash:<stashId>:<item>` | fallback **per write**; one entry per item kind against the 4 096-entry store cap (`rp_inventory/server/main.lua:169`, `:182`, `:248`) |
| `rp_jobs` | `emp:<identifier>` = `job\|grade\|hiredAt\|hiredBy`; `seeded:<job>` **always** | `rp_jobs/server/main.lua:188-190`, `:252-264`, `:421-444` |
| `rp_identity` | `citizen:<identifier>` (JSON), `next_id` | fallback **per call**; `next_id` is independent of `AUTO_INCREMENT`, so NCID numbers collide across stores (`rp_identity/server/main.lua:223-225`, `:278-284`) |
| `rp_config` | `override:<key>` | only while SQL is not ready; migrated into SQL and deleted when it answers (`rp_config/server/main.lua:200-207`, `:655-668`) |
| `rp_ferrailleur` | `tool:<identifier>` | fallback (`rp_ferrailleur/server/main.lua:136`, `:162`) |
| `rp_nomade` | `history` (JSON blob, last 50) | fallback (`rp_nomade/server/main.lua:164-165`, `:260-271`) |
| `rp_garage` | `veh:<plate>` (row JSON), `keys:<plate>` | fallback; never deleted (sub-audit) |
| `rp_housing` | `homes`, `keys` (whole-map JSON rewritten on every change) | fallback (sub-audit) |
| `rp_shops` | `stock:<shopId>` (JSON), `licence:<identifier>` | fallback; an empty or corrupt stock re-seeds free opening stock (sub-audit) |
| `rp_shop` | `garage:<identifier>` | **only** store (sub-audit) |
| `rp_medic` | `heal:` / `revive:` / `earned:<identifier>` | always (sub-audit) |
| `rp_trauma` | `contract:<id>:*`, `debt:<id>`, `heal:`/`revive:<id>` | fallback; counters always (sub-audit) |
| others | `rp_mecano` `impound:*` / `invoice:*`, `rp_bar` `sales:*`, `rp_ripperdoc` `operations`, `rp_crime` `log:*` | fallback (sub-audit) |

### 3.3 State bags

The only server write in the audited set is `Open77.state.entity("vehicle", id):set("plate", plate)`
(sub-audit: `rp_garage/server/main.lua:480-493`).
- `rp_mecano` reads that bag to link a runtime car to a garage row (`rp_mecano/server/main.lua:74-82`).
- If the write was refused, an impounded car is not recorded and can be taken out free (sub-audit, **inference**).
- No private data is in a bag.

### 3.4 Store selection and SQL/KVP forks (R1)

Every audited persistent resource picks its store per boot, and none reconciles one store with the other afterwards; `rp_config` is the exception, because it migrates its own overrides. 29 of the 41 resources touch both `Open77.database` and `Open77.kvp`. A string scan for the fallback log lines and the `useKvp` and `store=kvp` patterns also matches `rp_admin`, `rp_fixer`, `rp_gangs`, `rp_logs`, `rp_mdt`, `rp_ncpd`, `rp_needs`, `rp_netrunner`, `rp_phone`, `rp_vigile` and `rp_whitelist`. Those 11 were not audited line by line.

| Behaviour | Resources | Evidence |
|---|---|---|
| Database refused or unreachable for 15–20 s → **KVP for the whole boot**; a late answer is ignored | `rp_economy`, `rp_bank`, `rp_jobs`, `rp_ferrailleur`, `rp_nomade`, `rp_garage`, `rp_housing`, `rp_shops`, `rp_mecano`, `rp_bar`, `rp_ripperdoc` | `rp_economy/server/main.lua:386-436`; `rp_bank/server/main.lua:477-520`; `rp_jobs/server/main.lua:195-235`; `rp_ferrailleur/server/main.lua:141-153`, `:895-914`; `rp_nomade/server/main.lua:167-198`, `:1461-1468`; sub-audits |
| As above, but **a late database flips the store back to SQL mid-boot**, stranding what was written to KVP | `rp_trauma`, `rp_crime` | sub-audit: `rp_trauma/server/main.lua:1778-1790` (verified), `rp_crime/server/main.lua:220-244` |
| Decided **per call** from `isReady()`, so one boot mixes stores | `rp_identity`, `rp_inventory` | `rp_identity/server/main.lua:241-301`; `rp_inventory/server/main.lua:157-186` (`dbReady` false until the schema callback, `:17`, `:1249`) |
| Schema failure → KVP | `rp_economy`, `rp_bank`, `rp_inventory` | `rp_economy/server/main.lua:401-404`; `rp_bank/server/main.lua:496-499`; `rp_inventory/server/main.lua:1243-1247` |
| Schema never answers → **SQL anyway** | `rp_jobs` | `rp_jobs/server/main.lua:223-227` |
| KVP→SQL migration | `rp_economy` once, guarded by `migrated:sql`, and the SQL row wins (`rp_economy/server/main.lua:348-384`); `rp_config` overrides (`rp_config/server/main.lua:655-668`). **Nobody else migrates.** | `rp_economy/README.md:37-41` states that balances changed during a KVP boot are not merged back |

**Measured (offline).** `rp_economy` ran as shipped on the fake host (`tests/compat/economy_scenarios.lua`,
scenario `kvp_boot_between_sql_boots`):
1. **SQL boot:** a new wallet is created at 500, +1000 is added, and SQL holds 1500.
2. **Boot with no database:** the player joins at **500**, because the KVP store has no key for them. +700 brings
   KVP to 1200.
3. **SQL again:** **1500.** The +700 is lost, and the 1500 was invisible during step 2.

**B3 update (2026-10-12).** `rp_economy` 2.0.0 and `rp_bank` 2.0.0 are facades over the `open77_transactions`
coordinator and never touch KVP for economic state. The same scenario name now runs them on the multi-resource fake
host (`tests/compat/multihost.lua`): the outage boot refuses (`player_not_found`, then `store_unavailable`), writes no
KVP key, and the balance is 1 500 again as soon as the database answers, without a restart; a change accepted in the
middle of a session just before the outage is detected lands exactly once. The invariant below is now a plain passing
test. The 5dcdad2 numbers above stay as the record of the 1.x behaviour (reproducible at d401b40). The remaining 13
resources of the table still fork.

The test `test_gap_r1_measured_behaviour` froze these numbers at 5dcdad2. The invariant "a database outage never changes a
balance" is an expected failure (`test_gap_r1_invariant_a_database_outage_never_changes_a_balance`).

**Inferences from the same code paths (not executed).**
- **`rp_inventory`.** A KVP boot shows empty pockets. A player loaded from KVP before `dbReady` flips true is later
  written to SQL item by item with **absolute** counts (`count = VALUES(count)`, `:162-163`). SQL then holds a mix:
  untouched SQL items come back on the next login, and untouched KVP items are lost.
- **`rp_identity`.**
  - A KVP boot asks registered citizens to register again and issues NCID numbers from `next_id`.
  - `storeLoad` references `schemaReady` before its `local` declaration (`:247` against `:303`), so it reads a nil
    global and always waits the full 20×250 ms when SQL is up.
- **`rp_jobs`.** A KVP boot drops every employment for that boot.
- **`rp_garage` / `rp_housing`.** A KVP boot shows SQL-owned homes as for sale, so they can be sold twice. The
  sub-audit also flags "query fails → empty registry → plate or home re-issued → upsert overwrites the owner". That
  depends on whether `.await` raises on a failed read. `rp_nomade/server/main.lua:280` says it raises, which would
  turn this into a KVP fork rather than an overwrite (**open**, §8).

### 3.5 Non-atomic flows (R2)

`Open77.database.transaction` is used nowhere in the pack. In the table, "unchecked" means the compensation's own
result is ignored.

| Flow | Steps (lines) | Failure mode |
|---|---|---|
| `rp_economy` `/pay` | debit sender → credit target → refund (`rp_economy/server/main.lua:752-763`) | Memory is consistent. Persistence is two independent async absolute writes. **Open:** whether the database worker can reorder them |
| `rp_bank` deposit / withdraw | cash `remove` → account credit (`:285-289`); account debit → cash `add` → restore (`:302-308`) | Two stores (`rp_economy`, `rp_bank`) with separate async writes: a crash between them mints or loses money (**inference**) |
| `rp_jobs` payroll | `societyRemove` → `rp_economy:add` → refund `societyAdd`, unchecked (`rp_jobs/server/main.lua:457-480`) | — |
| `rp_inventory` give / seize / stash moves | debit → credit → rollback credit, unchecked (`rp_inventory/server/main.lua:669-691`, `:792-814`, `:942-972`) | A rollback that fails destroys the item |
| `rp_inventory` drop / pickup | loot create → debit (`:568-577`); native pickup removes the drop before `onLootPickup`, then credit, else **re-drop** at the picker (`:582-606`) | No position → item lost. Restart → unknown drop ignored (`:600-602`) |
| `rp_inventory` use | effect **before** debit (`:534-537`) | A failed debit after the effect gives a free use |
| `rp_ferrailleur` search | claim → 8 s bar → deplete + wear → `add` loot (`rp_ferrailleur/server/main.lua:583-631`) | Pockets full: the loot is **destroyed** ("stays in the dirt", but nothing is dropped) and the wreck and tool are still spent |
| `rp_ferrailleur` sell | count + **remove all** → 3 s bar → `rp_economy:add` → `societyAdd` (log only) (`:681-739`) | Disconnect or crash during the bar: items lost, because re-adding to an offline player fails. A failed economy add triggers a re-add (unchecked). A failed society share is destroyed |
| `rp_ferrailleur` buy crowbar | `remove` cash → `add` item → refund → set durability → `societyAdd` (`:741-782`) | as above |
| `rp_nomade` contract | deposit `remove` → truck/crate spawn → refund on failure (`rp_nomade/server/main.lua:791-815`) | A crash or disconnect after the deposit loses it ("stays with the clan", but no society credit, `:1333-1334`, `:1487`) |
| `rp_nomade` pay | per batch: `add` gross (a failure is only messaged) → convoy bonus per member → `societyAdd` (`:890-929`) | `contract.pay` grows even when the payout failed (`:923`), so the history row overstates pay. A death or disconnect mid-unload returns before `payBatch` (`:1208`, `:1228`): delivered crates go unpaid |
| `rp_shops` purchase | cash `remove` → else `withdraw` + `remove` → `deposit` back, unchecked → `add` item → refund to **cash** → stock → society 70 % (log only) → sale log (sub-audit: `rp_shops/server/main.lua:200-260`, `:933-966`) | Refunds always go to cash. Weapon refund-then-completion duplicates value (`:1017-1034`) |
| `rp_garage` buy / `rp_housing` buy-sell | charge → memory → async upsert (sub-audit: `rp_garage/server/main.lua:734-760`; `rp_housing/server/main.lua:583-636`) | A crash after the charge: **paid, no deed or car**. A crash during a sale can duplicate value |
| `rp_mecano` invoice / paint / refuel / impound | sub-audit: `rp_mecano/server/main.lua:612-645`, `:1127-1144`, `:1299-1312`, `:1238-1252` | Mechanic payout lost. Paid paint with no paint and no refund. Fuel before can. The impound fee is minted |
| `rp_bar` serve / craft / restock | sub-audit: `rp_bar/server/main.lua:1076-1113`, `:875-887`, `:901-914` | The tip can be lost; rollbacks unchecked |
| `rp_ripperdoc` finalize / restock | box → payment → install → event → log row; restock "free" when both money resources are down (sub-audit: `rp_ripperdoc/server/main.lua:883-901`, `:1284-1302`) | Boxes minted; no receipt across restart |
| `rp_trauma` collect / bills | act first, bill after; bill paid twice when its async insert had not returned (sub-audit: `rp_trauma/server/main.lua:314-316`, `:1088-1098`) | — |
| `rp_crime` deal / fence / gut | sub-audit: `rp_crime/server/main.lua:909-937`, `:1206-1214`, `:1090` | The gutted crate is still delivered and paid by `rp_nomade`: value is duplicated |

### 3.6 Schema and version handling

- **No versioning.** No resource versions its schema. Adding a column means a fresh `CREATE TABLE IF NOT EXISTS`
  never reaches existing tables, and the full-column upserts (`rp_garage`, `rp_jobs`) would then fail
  (**inference**).
- **Precedent of an unmigrated layout.** `rp_jobs` v1 → v2 already left one behind: v1 KVP `job:<identifier>` is
  not migrated (`rp_jobs/README.md:215-216`).
- **Silent reinitialisation and drops on corrupt or unknown data:**

  | Resource | Behaviour | Source |
  |---|---|---|
  | `rp_economy` | a corrupt balance resets to 0 | `rp_economy/server/main.lua:238-240` |
  | `rp_ferrailleur` | a failed tool read is treated as "no wear recorded", then overwritten with a fresh 20 | `rp_ferrailleur/server/main.lua:155-160`, `:176-183` (README `:136-137` promises the opposite) |
  | `rp_jobs` | unknown job in KVP: the key is deleted | `rp_jobs/server/main.lua:310` |
  | `rp_jobs` | unknown job in SQL: ignored | `rp_jobs/server/main.lua:296-298` |
  | `rp_shop` | a corrupt ledger restarts empty and is overwritten | sub-audit |
  | `rp_shops` | a corrupt stock is re-seeded | sub-audit |
  | `rp_housing` | KVP rows for unknown homes are dropped at the next save | sub-audit |

- **What is done correctly:**
  - `rp_inventory` never marks a container loaded after a failed read (`:235-240`).
  - `rp_economy` never invents a balance on a read failure (`:308-312`).
  - `rp_jobs` never marks a failed read loaded (`:1094-1098`).

---

## 4. Economy flows relevant to the pilot

### 4.1 `rp_ferrailleur` today

**Gather.**
1. The E prompt fires the client event `rp_ferrailleur:prompt_<i>` → net `rp_ferrailleur:search(index)`
   (`client/main.lua:94-96`; `server/main.lua:978-984`).
2. Checks: position within 3.5 m planar and 4 m height (`:533-541`); `rp_zones:isIn(junkyard)` if running
   (`:543-547`); `rp_jobs` `hasJob(ferrailleur)` + `onDuty` (`:548-552`, `:87-94`); the tool file is loaded
   (`:553-558`); a crowbar is in the pockets (`:559-567`); not already searching; the wreck is `ready`
   (`:568-580`).
3. Claim: `points[i].state = "busy"`, keyed by session id (`:583-586`).
4. Staged 8 s bar (kneel, crowbar prop) (`:589`).
5. Cancel or failure releases the claim (`:593-602`). Re-checks distance and crowbar (`:605-615`).
6. `rollLoot`: scrap ×2–4 (60 %), component ×1–2 (30 %), chip ×1 (10 %) (`:618`; `shared/config.lua:99-103`).
7. `depletePoint`, with a 5 min regen timer (`:619`, `:235-250`).
8. `wearCrowbar`, which can remove a broken crowbar (`:620`, `:186-205`).
9. `rp_inventory:add(item, count)` (`:622`). If refused, the loot is lost.
10. Toast, then `rp_ferrailleur:searched` (`:632-637`).

**Carry.** There is none. Items are weight-only counts in the 40 kg pockets (`rp_inventory/shared/items.lua:13`,
`:40-42`): scrap 1.0 kg, component 0.5 kg, chip 0.05 kg.

**Store.** No container is involved. `/drop` to the ground is the only generic out, and drops are not durable.

**Sell.**
1. The prompt or `/vendre` within 5 m of Rusty (`:674-678`, `:1038-1051`).
2. Menu → `sellAll` (`:784-834`).
3. For `scrap`/`component`/`chip`: count, then **remove all** (`:683-696`).
4. Payout = Σ count × today's price, minus a 10 % society cut (`:701-703`; prices re-rolled ±20 % every 10 min,
   `:104-113`).
5. Staged 3 s bar; a cancel re-adds the items (`:707-712`).
6. `rp_economy:add(payout, "scrap_sale")`, else re-add the items (`:714-721`).
7. `rp_bank:societyAdd("ferrailleur", cut, "scrap_sale:<sessionId>")`, logged on failure (`:722-727`).
8. Event `rp_ferrailleur:sold` (`:738`).

**Tool.**
1. Buy: `rp_economy:remove(250)` → `rp_inventory:add(crowbar)` → refund on failure → durability 20 → society +250
   (`:741-782`).
2. Wear is per identifier (`:128-205`; README `:117-120`).

**Persistence.** Only `rp_ferrailleur_tools`. Nodes, claims and prices live in memory.

### 4.2 `rp_nomade` today

**Accept.**
1. The board ring (5 m) → net `rp_nomade:board` → `nomade` + on duty (`server/main.lua:951-964`).
2. UI-kit menu (`:995-1015`) → re-check duty and that no contract is running (`:1030-1038`).
3. `startContract` (`:776-868`):
   1. Deposit `rp_economy:remove(100, "nomade:rental")` (`:791-799`).
   2. Spawn the rental truck with a TTL (`:800-805`, `:345-363`).
   3. Spawn N crate props at the loading points (`:806-824`); refund on failure.
   4. Build the contract in memory, keyed by session id (`:826-859`).
   5. Insert the history row (`:860`, `:228-246`).

**Pick up.** Net `rp_nomade:pickup(i)`:
1. Checks: active contract, not busy, hands empty, crate on the ground, within reach (`:1042-1076`).
2. Pickup step clip, `carry_pickup` preferred (`:1078-1082`).
3. `props.attach` to the player's `Chest` slot, or hide the prop and use `heldItems.hold` (`:1083`, `:454-494`).
4. Looping `carry` upper-body layer (`:1087`; `shared/config.lua:180-195`).

**Load.**
1. The truck's `open77_interactions` `addGlobalVehicle` prompt (`client/main.lua:98-110`;
   `shared/config.lua:124` `nativePrompts = true`) → net `rp_nomade:load(vehicleId)`.
2. `truckIntent` checks that it is your truck and within reach (`server/main.lua:1094-1121`).
3. Load clip → `stowCrate` attaches the prop to a bed slot in the vehicle frame (`:1142-1150`, `:521-566`). The
   bed offsets are still "starting guesses" (`shared/config.lua:128-129`).

**Drive.**
- The client draws the pin and GPS.
- The server tracks `rp_zones:entered/left` (`:1548-1581`).
- A 1 s tick handles the deadline, the truck watch and the ambush (`:1587-1642`).

**Unload and sell.** Net `rp_nomade:unload` in the destination zone (`:1165-1185`). For each crate:
1. take clip → carry 1.5 s → put-down clip → crate on the ground for 30 s (`:1196-1237`, `:659-677`).
2. Then `payBatch` (`:1240`, `:890-929`): `rp_economy:add(gross)`, the convoy bonus split among on-duty nomads
   within the radius (`:871-888`), and `rp_bank:societyAdd("nomade", 15 %)`.

The cargo never touches `rp_inventory`. `nomad_crate` is defined but unused (`shared/config.lua:255-257`;
`server/main.lua:1403-1412`), and so is the built-in `crate` item (`rp_inventory/shared/items.lua:50`).

**Return.** Net `rp_nomade:return` inside the camp → `rp_economy:add(100)` refund → `endContract` removes the
props and the truck and writes the history row (`:1245-1274`, `:749-774`).

**Interruptions.**
- Death or downed while carrying → the crate goes back to the bay (`:1491-1510`).
- Disconnect → "abandoned" and the deposit is lost (`:1482-1488`).
- Truck removed → "truck_lost" (`:1512-1521`).
- Deadline (`:1593-1595`).
- `/convoi annuler` (`:1310-1336`).

### 4.3 What C1 can reuse, and what it must add

| C1 need | Existing piece | Gap |
|---|---|---|
| Salvage node, claim, regen | `rp_ferrailleur` wreck state machine | Stable node ids; durable or recoverable claims; NPC/player contention; reserve output capacity **before** depletion |
| Material items | `scrap`/`component`/`chip` built-ins | Physical item ↔ prop mapping (B1); metadata and quality; per-instance tool wear |
| Carry | `rp_nomade` attach + `carry` layer + pickup and put-down steps | Ownership via containers rather than per-contract props; FPP acceptance (plan decision 3) |
| Truck and cargo | `rp_nomade` bed slots on a rented runtime truck | Garage-owned vehicle by plate (A9); a vehicle container (none exists); cargo persistence |
| Buyer and sale | Rusty (`sellAll`) and the `rp_nomade` per-crate pay | One durable coordinator operation (A13/B2/B3) with receipt, society split and idempotent retry |

---

## 5. Migration boundary for B1–B4 (and A9/C2)

General rule, from the evidence above: **adapters wrap, they do not replace**. The provider resources keep their
names, exports, refusal tokens and events. The wave-1 suite (§6) fails if any of them moves.

### 5.1 B1 item definitions

**Must stay stable.**
- `exports.rp_inventory:define(items) -> registered, rejected` (counts). `rp_mecano` and `rp_bar` treat the
  values as lists for logging only (sub-audit).
- The field set `label/weight/usable/illegal/permit/effect/record/visual/category`.
- The id pattern `^[%l%d_]+$`.
- `definedBy` effect ownership, with `rp_inventory:used`.
- The redefinition handshake: definers call `define` again on `onResourceStart("rp_inventory")`. Seven resources do
  this, for example `rp_ferrailleur/server/main.lua:882-886` and `rp_nomade/server/main.lua:1469-1470`.

**Built-in ids consumed elsewhere.** They must not be renamed:

| Id | Consumers |
|---|---|
| `scrap`, `component`, `chip` | `rp_ferrailleur`, `rp_mecano` |
| `chooh2` | `rp_mecano` |
| `lockpick` | `rp_crime`, `rp_shops` |
| `implant_box` | `rp_crime` fence prefix `^implant_box`, `rp_ncpd` exemption (sub-audit) |
| `water`, `burrito`, `nicola`, `cigarettes`, `bandage`, `maxdoc`, `bounceback`, `synthcoke` | the `rp_shops` catalogue |

**Fix deliberately, with a migration note.**
- Refuse ids longer than 32 bytes: `item_id` is `VARCHAR(32)` (`rp_inventory/server/main.lua:1230`) but
  `define` checks no length.
- Report collisions instead of letting the last writer win (`:366`). No collision exists today: every definer's ids
  are distinct.
- Unify `permit`: `rp_inventory` honours it (`:144-151`), `rp_ncpd` ignores it (sub-audit). The built-in
  `implant_box` permit `"medecin"` resolves to `trauma`, not `ripper` (`rp_inventory/shared/items.lua:47-49`
  against `rp_jobs/shared/config.lua:43`).

**Data migration.**
- Definitions are code.
- **Instance migration:**
  - Every `(identifier, item_id, count)` row becomes a stack with empty metadata.
  - `rp_ferrailleur_tools.durability` moves onto **one** crowbar instance per identifier that holds any; spares
    start fresh, matching today's rule (README `:117-120`).
  - Rows of unknown ids are kept, never deleted.

### 5.2 B2 inventory adapters

**Must stay stable.**
- The seven exports and their tokens (§2.1), including the ambiguity `has` = false and `count` = 0 when not
  loaded. Callers rely on it: `rp_ferrailleur/server/main.lua:169-172` and `:560-566` tell "offline" apart only
  through a raised `pcall`.
- `rp_inventory:changed`/`used`, the `/inv` panel and commands, and stash ids `home:<homeId>` with
  caller-supplied capacity (`rp_housing/server/main.lua:1096`; `Config.stashCapacity` 200).

**Containers to introduce.**
- Character = account identifier (§1.2).
- Stash = existing string id.
- **Vehicle = plate:** `trunk:<plate>` fits the stash-id pattern (`rp_inventory/server/main.lua:1091`). There is no
  vehicle container anywhere today.
- Society/shop = society name.
- Decide the housing policy: the stash is per property and **inherited by the next owner** (sub-audit:
  `rp_housing/server/main.lua:1193`). The `northside_container` id was relocated to another flat (sub-audit:
  `rp_housing/shared/config.lua:166-175`).

**Call sites that must become single coordinator operations (A13).**

| Resource | Flows |
|---|---|
| `rp_inventory` | give, seize, stash take/store, drop, pickup |
| `rp_ferrailleur` | search, sell, buy |
| `rp_shops` | purchase, weapon |
| `rp_mecano` | repair, paint, refuel |
| `rp_bar` | serve, craft, restock |
| `rp_crime` | deal, fence, gut (with an `rp_nomade` write-back) |
| `rp_ripperdoc` | finalize, restock |

`rp_fixer`, `rp_gangs`, `rp_ncpd` and `rp_netrunner` use the same exports and were not audited line by line.

**Data migration.**
- `rp_inventory_items` and `rp_inventory_stashes` → container rows. Persist the capacity; it is not stored today.
- KVP `inv:<identifier>:<item>` and `stash:<id>:<item>` imported under an explicit conflict rule that is reported,
  never silently chosen (see R1).
- Add a schema version row before the first change.

### 5.3 B3 wallet adapter

**Must stay stable.**
- `rp_economy` `add`/`remove`/`getBalance`, with the `insufficient_funds` token. `rp_bank` maps it to
  `insufficient_cash` (`rp_bank/server/main.lua:257`), and `rp_ferrailleur:755` and `rp_nomade:793` branch on it.
- The 64-byte reason limit and `rp_economy:changed`.
- All eight `rp_bank` exports, `rp_bank:changed` (`playerId` nil for societies), and ledger identifiers
  `society:<name>`.
- `transfer` to an **identifier**: the ATM's "citizen id" is the account GUID (`rp_bank/server/main.lua:594-606`).
  It is not the `rp_identity` NCID number.
- Society names (§2.5).

**Behaviour the adapter must add, not change.**
- An offline-capable credit path: every refund today fails for a disconnected player (R2).
- Operation ids and receipts.
- Refund to the original instrument: `rp_shops` refunds account payments as cash (sub-audit).
- One split-payout primitive. Today there are three wallet styles: cash then bank (`rp_shops`), atomic `charge`
  (licence, garage, housing, trauma, ripperdoc), and cash only (`rp_mecano`, `rp_bar`, `rp_shop`, `rp_medic`).

**Data migration.**
- `rp_economy_wallets`, `rp_bank_accounts`, `rp_bank_societies`, `rp_bank_transactions`.
- KVP `balance:*`, `acct:*`, `acct_created:*`, `soc:*`.
- The `rp_jobs` flags `seeded:<job>` must move to SQL with the societies, or a redeploy re-seeds them.
- Remove or tag the `selftest` society (§6.1).
- Produce a reconciliation report for any KVP value that differs from SQL. Never pick one silently.

### 5.4 B4 jobs and duty adapter

**Must stay stable.**
- Eight exports.
- Aliases `police`/`medecin`/`taxi`.
- Job names, which are society names and the fleet owner `"society:<job>"`.
- Grade 0..3 with boss = 3.
- The events `rp_jobs:changed`/`duty`, with 11 listeners each (§2.2).
- `false`/`nil` while not loaded.
- Duty never restored across reconnect.

**Existing defects the adapter must not paper over silently.**
- `rp_medic` compares `getJob()` to the legacy `"medecin"`/`"police"`, so no one ever matches in jobs mode
  (`rp_medic/server/main.lua:23-24`, `:98-104`; verified).
- `isBoss` is not scoped to a job.
- Several duty checks differ:
  - `rp_shops` licence exemption: `hasJob` without duty.
  - `rp_bar`: `getJob()==`.
  - `rp_trauma`: `hasJob`+`onDuty`.

**Data migration.**
- `rp_jobs_employees` and KVP `emp:<identifier>`.
- v1 `job:<identifier>` is still unmigrated (`rp_jobs/README.md:215-216`).

### 5.5 Vehicles (A9), housing (C8) and Nomade (C2)

- **Legal owner** = `rp_garage_vehicles.owner` (identifier or `"society:<job>"`). **Durable id** = plate. **Keys** =
  `rp_garage_keys`, per identifier.
  - Runtime ↔ plate goes through the `plate` state bag and `rp_garage:plateOf`.
  - There is no transfer, sale or title API (sub-audit).
- **Second registry.** `rp_shop` (v1) is a second, KVP-only ownership registry on runtime ids. Disable it, or
  migrate it, before A9 ships (decision 5 principle).
- **`rp_mecano`** acts on any vehicle with no owner check, and records impounds by runtime id (sub-audit). A9 must
  give it a plate- and owner-aware path.
- **C2:**
  - `rp_nomade` has no persistent cargo or contract to migrate; only `rp_nomade_contracts` history.
    *Update 2026-10-13 (rp_nomade 2.0, W3-7):* the table is no longer written or read. Runs, crates and
    payouts live in open77_transactions accounts and the resource kvp (`tally:<run>`); existing rows stay as
    history. The `session:<id>` identifier and the `nomade:contract:<localId>` society note (section 1.3)
    no longer occur. `activeContract` is still exported for `rp_crime`.
  - Keep `activeContract`, its only cross-resource API (`rp_crime`).
  - `rp_crime` steals from Nomade cargo without telling `rp_nomade` (sub-audit, verified at
    `rp_crime/server/main.lua:1086-1096`). C2 must close that, or the two economies double-count.

### 5.6 Migration rules the suite enforces

1. **No store is created, dropped or re-seeded implicitly:**
   - Every schema change ships a version bump and a forward migration.
   - The schema snapshot test fails until the snapshot and the audit change together.
2. **KVP is an explicit lab mode** (plan decision 2):
   - A persistent resource that cannot reach SQL refuses persistent operations instead of forking into KVP.
   - Importing KVP data is a one-shot admin step with a report.
3. **Identity migration is 1:1 and checked:**
   - The account identifier becomes the default character id.
   - Counts, metadata and owners are compared before and after.
   - Rollback restores the pre-migration tables or refuses with an explicit version-mismatch reason.

---

## 6. Suite proposal

### 6.1 What exists today

**`rp_selftest`** has **33 checks**: 19 refusal or contract checks in phase 1 and 14 read-only probes in phases
3–5 (`rp_selftest/server/main.lua:6-14`, `:33-118`; summary line `:120`).
- It runs once at `onResourceStart`, on a **live server**, with no player. It calls the real exports, so it
  **cannot run offline**.
- It hard-depends on six resources (`rp_selftest/open77.lua:8-13`).
- **Side effects on the live store:**
  - It defines `crowbar_test` in the item registry (`:60`).
  - It creates the society `selftest` and writes two ledger rows **on every boot** (`:64-69`).
  - Run it only on lab servers until v2 adds a dry-run mode.
- It never exercises a success path that moves money or items for a real player, any persistence round trip, or any
  store failure.

**`tests/test_held_actions.py`** has 5 unit tests. They cut functions out of `rp_inventory/server/main.lua` and
`rp_bar/server/main.lua` by string markers and run them through `lupa`. The tests are offline, but `lupa` is not
installed on this workstation, so the module fails to import here. Installing it needs `pip`, with network access.

**Tooling on this workstation** (2026-10-12):

| Tool | State |
|---|---|
| `lua.exe` / `luajit` | not on PATH |
| `luac.exe` 5.4.8 | in the Open77 build trees (`base/build/ninja-x64/luac.exe`, opt-in target `OP77_BUILD_LUAC`, `wt-world-interaction/scripts/check-lua.ps1`) |
| Python | 3.12, without `lupa` |
| KeraLua 1.4.9 | in the NuGet cache, with `runtimes/win-x64/native/lua54.dll` |

**Open77 precedent.** `server/tests/Open77.Server.Tests/Resources/RpBasicsTests.cs` runs
`resources/system/open77_rp_basics/tests/{rules_test,server_test}.lua` against `tests/fakes.lua` on KeraLua.
This is the same pattern as here: the real `server/main.lua` on a fake host, with a `TestResult` contract.

### 6.2 What this row adds (offline, no behaviour change)

`python -m unittest discover -s tests -p "test_compat*.py"` runs **9 tests, OK, 1 expected failure**, in 0.6 s
on 2026-10-12.

| File | Purpose |
|---|---|
| `tests/compat/contracts.py` | Static extractor: manifests (`dependency`, `server_exports`, client half), declared exports, cross-resource calls, `CREATE TABLE` bodies |
| `tests/test_compat_contracts.py` | L0: every call targets a declared export; the frozen B1–B4/garage/housing/config/nomade surface (§2.1); the client-manifest dependency rule; no Lua BOM; the schema matches `tests/compat/schema-snapshot.json` (47 tables) |
| `tests/compat/fakehost.lua` | Fake server host: event bus, exports, a scheduler on a simulated clock, `Open77.database` callback and `.await` forms over a scenario-supplied interpreter, KVP, players. Stores persist across `H.boot` calls to model restarts |
| `tests/compat/luahost.py` | Lua 5.4 engine: `lupa` if installed, else `lua54.dll` through `ctypes` (`OP77_LUA54_DLL` or the KeraLua NuGet cache). No network |
| `tests/compat/economy_scenarios.lua`, `tests/test_compat_economy.py` | L1 seed: `rp_economy` as shipped. SQL restart round trip; refusal tokens; R1 characterised and its invariant as an expected failure |

**B3 additions (2026-10-12, `docs/world-interaction/b3-wallet.md`):** `tests/compat/multihost.lua` (several resources,
one environment each, the export/event/database rules of the platform), `tests/compat/txhost.lua` and
`tests/compat/vendor/open77_transactions/` (the A13 coordinator prototype behind a test stand-in for its exports),
`tests/compat/wallet_world.lua` and `wallet_scenarios.lua`, and `tests/test_compat_wallet.py`. `economy_scenarios.lua`
now forwards to the wallet scenarios; R1 passes. Two frozen values changed together with this note:
`FROZEN_SURFACE["rp_economy"]` gained the five exports `rp_bank` 2.0.0 calls (`walletRead`, `walletMove`,
`societyRead`, `pay`, `balanceOf`), and `schema-snapshot.json` gained `rp_wallet_migration` (the 1.x table bodies are
unchanged: they are kept, created when missing, as the import source and archive). The whole suite: 24 tests, OK.

**B7 additions (2026-10-12, `docs/world-interaction/b7-ui.md`):** `tests/compat/b7_ui_scenarios.lua`,
`tests/compat/b7_wallet_scenarios.lua` and `tests/test_b7_ui.py`. Three frozen values changed together with this
note, all additive consumers: `FROZEN_SURFACE["rp_economy"]` gained `walletStatus` and `pendingPlayers` (new
read-only HUD exports, consumed by `rp_hud`), `FROZEN_SURFACE["rp_jobs"]` gained `summary` (B4's, now consumed by
`rp_hud`), and `FROZEN_SURFACE["rp_garage"]` gained `canAccessVehicle` (A9's, consumed by the `rp_inventory`
panel's read-only cargo view). No schema change.

**W3-4 netrunner contracts (`rp_netrunner` 2.0.0):** the netrunner keeps its durable state in
`open77_transactions` (the contract board stash `stash:nr.board:contracts`, data shards in the pockets) and
no longer creates or writes `rp_netrunner_log`. Existing rows stay in the database as a read-only archive;
nothing reads them (the 1.x `trace` export is gone, traces are rp_ncpd record entries). One frozen value
changed together with this note: `schema-snapshot.json` lost `rp_netrunner_log`. No table is dropped.

### 6.3 Wave-1 suite shape

**Layers.**

| Layer | Content | Runs |
|---|---|---|
| L0 static | as shipped here, plus `luac -p` when `OP77_LUAC` points at the 5.4.8 build, a `rp_config` key→reader report, and a "no `session:` or runtime id persisted" lint over SQL/KVP write sites | everywhere, seconds |
| L1 contract | Fake-host scenarios for **`rp_economy`, `rp_inventory`, `rp_bank`, `rp_jobs`, `rp_identity`** first (the B1–B4 providers), then **`rp_ferrailleur`, `rp_nomade`** (pilot consumers), then **`rp_garage`, `rp_housing`** (plate/stash containers). Each provider: export signatures and refusal tokens, a persistence round trip across `H.boot`, not-loaded semantics, events raised | offline, seconds |
| L2 migration and fault injection | (a) **Golden pre-migration fixtures**: SQL rows and KVP files from the 5dcdad2 schemas; migrate; assert counts, identity, owner and metadata preserved, plus an explicit refusal on a version mismatch or rollback. (b) **Crash-between-steps sweep**: for each flow in §3.5, fail or abort after step k and assert conservation (items + money + society), or an explicit, logged compensation. (c) **Expected-failure invariants** per gap (R1–R5) that flip to unexpected success when fixed | offline |
| L3 live | `rp_selftest` v2: lab-only guard, no writes to production stores, adapter probes. Plus the plan §5.3 two-client matrix (durability, authorization and cancellation rows) through `open77-testing`, run by the integrator | lab only |

**Gating.** L0 and L1 on every change to the pack. L2 before any adapter merge (B1–B4) and before C1. L3 per proof
window.

**Engine choice.** Write the scenarios in Lua, so they can be hosted by the Python runner here or by a KeraLua
`[TestClass]` in the Open77 server tests (the `RpBasicsTests` pattern). `lupa` and the NuGet `lua54.dll` are
both accepted.

**Representative resources and why.**

| Resource | Why |
|---|---|
| `rp_economy`, `rp_bank`, `rp_inventory`, `rp_jobs`, `rp_identity` | providers |
| `rp_ferrailleur` | node, tool and sale; C1 base |
| `rp_nomade` | carry and cargo; C2 |
| `rp_housing` | stash container |
| `rp_garage` | plate identity |
| `rp_shops` | the richest money flow |
| `rp_ripperdoc` | rollback and platform install receipt |
| `rp_mdt` | direct SQL reader of 8 foreign tables |
| `rp_crime` | 9 dependencies, reads Nomade and garage |

---

## 7. Plan cross-check (where the worktree differs from the plan's references)

The plan's review scanned `C:\Games\cyberm\rp-scripts`, an older snapshot (2026-09-19, no git history). Against
`5dcdad2`, ignoring line endings:
- The audited resources are identical except `rp_inventory` (server smoke effect), `rp_nomade` (config, server,
  manifest, README) and `rp_bar` (config, server, manifest, README).
- Outside the audited set, `rp_needs`, `rp_phone` and `rp_fireworks` changed.
- `rp_weapons_effect`, `platform/` (`open77_prediction`, `prediction_policy_example`), `tests/` and `docs/` are new.

| Plan reference | Worktree fact | Status |
|---|---|---|
| Header and §1.1: "39 resources excluding `rp_worldprobe` (40 `rp_*` manifests)", "140 Lua files" | 41 `rp_*` resources (adds `rp_weapons_effect`) with 145 Lua files, plus `platform/` and `eval_taxi` (9 more) | **outdated counts** |
| §1.1: RP resources do not use "class targets, `deviceUsed`, `zones.create` or animation-owned items" | Class targets, `deviceUsed` and `zones.create` are still unused; the only class-target mention is a comment in the lab-only `rp_worldprobe`. **Animation-owned items are now used implicitly:** `rp_needs` (`server/main.lua:56`, `:60`, `:68`), `rp_bar` (`shared/config.lua:134`, `:164`) and `rp_phone` (`shared/config.lua:19-20`) select `*_walk` layer profiles whose default native hand item is owned by the animation (`docs/held-actions.md`); no explicit `options.item` | **partly contradicted** |
| §1.3: `shared/config.lua:124` `nativePrompts = true`; `client/main.lua:100` registers vehicle targets; the stale "off until PR #37" comment | Unchanged: `rp_nomade/shared/config.lua:124`, `client/main.lua:98-100` | matches |
| §1.3: `shared/config.lua:128,184,215` and `README.md:450` | `:128` still holds the bed-offset "guesses". `:184` is now the carry-layer comment (the old carry-pose block starts at `:180`). `:215` → `steps = {` is at `:205`. `README.md:450` → `:457-464`, and the text now says the carry is an **upper-body layer that keeps locomotion** (`rp_nomade/README.md:18-19`, `:460`), not a stationary workspot | **lines moved; "fallback poses" now applies only to the `tablet2`/`phone` fallbacks** |
| §4 B: start with `rp-scripts/rp_inventory/server/main.lua:359` (item exports) | `:359` is `define`; the item exports span `:359-409`, `openStash` `:1088` | matches |
| §4 B: `rp-scripts/rp_garage/README.md:135` (owner/key API) | The Exports section starts at `:137`; `:135` is the `rp_mdt` note | off by 2 |
| §3 "Persistent identity: use character … identities" | The pack has **no character id**; the account identifier is the character (§1.2) | gap the plan assumes is fillable; B2 must define it |
| §3 "Database failure: no automatic SQL-to-KVP failover"; §7 decision 2 | 15 audited resources fail over today (two flip back mid-boot), and at least 11 more show the pattern (§3.4) | **contradicted by existing code** (expected; B8 now measures it) |
| §1.2 "Inventory and economy … no second independent economy by default"; decision 5 "avoid two enabled independent" systems | `rp_shop` v1 and `rp_shops` both `auto_start true`; `rp_shop` keeps its own vehicle ledger; `rp_medic` and `rp_trauma` both auto-start the same commands | **already violated** for shops and medics |
| §5.1 Day 2 "salvage → carry → truck → sale with existing resources/minimal adapters" | No existing path links them. `rp_ferrailleur` loot is pocket counts sold in the same yard; `rp_nomade` cargo is per-contract props that never enter an inventory | feasible only with new glue (§4.3) |
| Status ledger: "`rp_selftest` (33 checks)" (row brief) | 33 confirmed | matches |

---

## 8. Open questions

1. **Does `Open77.database.query.await` / `update.await` raise or return nil on a failed statement?**
   `rp_nomade/server/main.lua:280` says it raises.
   - If it raises, the garage and housing "empty registry, then overwrite" path becomes a KVP fork instead, and
     `rp_shops`/`rp_bar` can stay "booting" forever (sub-audits).
   - If it returns nil, the overwrite path is live.
2. **Does the database worker preserve the submission order of callback-form writes from one resource?** Every
   wallet and inventory write is an absolute snapshot; out-of-order commits would persist an older value.
3. **Are runtime vehicle ids ever reused within a boot, and do `persistent` vehicles keep them across a restart?**
   This decides whether `rp_mecano_impound.vehicle_id` and the `rp_shop` ledger mean anything after a restart.
4. **Ordering of `onVehicleRemoved` against `rp_mecano:impounded`, and can `vehicles.get` answer nil for a live
   car?** If it can, the garage duplicates a take-out (sub-audit).
5. **Housing stash on sale or eviction:** inherit, clear, or move to the seller? This is a product decision for
   C8/B2.
6. **Should `rp_shop` v1 and `rp_medic` stay `auto_start`?** This is an owner decision under plan decision 5.
7. **Which event does the platform raise for `rp_crime`'s fence prompt?** It declares `rp_crime:fencePrompt`, but
   no handler exists (sub-audit: `rp_crime/server/main.lua:1269`).

---

## 9. Research ledger entry (for the integrator to copy)

> **2026-10-12 — B8 wave-0 compatibility audit (RP pack 5dcdad2).**
>
> **Facts (source):**
> - Every durable RP row is keyed by the account identifier (`userId`); there is no character id. Live state is
>   keyed by session id, vehicles by plate, containers by stash string (`home:<id>`), societies by job name.
> - 47 unversioned tables, all created with `CREATE TABLE IF NOT EXISTS`. `Open77.database.transaction` is used
>   nowhere.
> - 15 audited resources fail over SQL→KVP per boot with no reconciliation (at least 11 others show the same
>   pattern by string scan): `rp_trauma`/`rp_crime` flip back mid-boot, and `rp_identity`/`rp_inventory` decide
>   per call.
> - Wallets and pockets are online-only, so refunds to disconnected players fail.
> - Item definitions, loot drops, wreck claims, convoy contracts and cargo live in memory.
> - `rp_config` has 793 keys but only 3 resources read overrides.
> - `rp_shop` v1 and `rp_medic` duplicate `rp_shops`/`rp_trauma` and auto-start.
> - `rp_selftest` (33 checks) is live-only and writes a `selftest` society on every boot.
>
> **Measurement (offline):** `rp_economy` as shipped, on a fake host, Lua 5.4 through KeraLua's `lua54.dll`:
> 1 500 €$ in SQL → 500 on a no-database boot → +700 → 1 500 on the next SQL boot. The KVP boot's income was lost
> and the SQL balance was invisible during it (`tests/test_compat_economy.py`).
>
> **Inferences (unmeasured):**
> - `rp_inventory` mixes stores within one boot and can resurrect or lose items.
> - A redeploy wiping KVP re-seeds job societies (`seeded:<job>`).
> - `rp_garage`/`rp_housing` may re-issue a plate or home if a failed SQL read returns nil.
>
> **Pilot base:** `rp_ferrailleur` provides nodes, claims, tool, loot, dealer and society share, but no physical
> custody, no durable claims and no atomic sale. `rp_nomade` provides attach/carry/bed slots on a rented truck, but
> its cargo never enters an inventory.
>
> **Shipped:** `docs/world-interaction/b8-compat-audit.md` and offline L0/L1-seed tests: 9 tests, 1 expected
> failure for gap R1. Engine: `lupa`, or `lua54.dll` via ctypes.
>
> **Next:** freeze the A13 operation contract against the §3.5 flow list; L1 fake-host suites for inventory, bank,
> jobs and identity; L2 golden fixtures and a crash-between-steps sweep before B2/B3 merge; `rp_selftest` v2 with
> a lab-only guard.
>
> **Open:** whether `.await` raises on a failed statement; database write ordering; runtime vehicle-id reuse.

---

## 10. Contract changes after this audit

Appended, never rewritten: each later row records here what it changed in the frozen contract.

- **2026-10-12, rows B1/B2** (`wi/b1b2-inventory`, `docs/world-interaction/b1b2-inventory.md`).
  - **Schema.** One new table, `rp_inventory_migrations` (per-subject import markers, transactions
    backend only), added to `tests/compat/schema-snapshot.json`. The two legacy tables are unchanged and
    are never written by the transactions backend.
  - **Exports.** The seven frozen `rp_inventory` exports keep their signatures and tokens on both
    backends (`tests/test_compat_inventory.py`, `test_existing_exports_answer_the_same_on_both_backends`).
    `add`/`remove` gain an optional fourth argument (`meta`); `define` gains a third return value
    (`details`). New exports are additive; no consumer calls them yet, so `FROZEN_SURFACE` is unchanged.
  - **Behaviour deliberately fixed (5.1).** `define` refuses colliding ids (`details.collisions`), ids
    over 32 bytes and ids containing `__`. No collision exists in the pack (all nine definers register
    every item unchanged, offline).
- **2026-10-12, reconcile with the final coordinator** (`wi/reconcile-a13`; Open77 `697e9e2f`).
  - **Migration rule changed (5.6, B2/B3 imports).** A failed operation id is a fresh attempt when reused;
    only a fenced one (`aborted`) is final (contract §13.5). `rp_inventory`'s import retries a failed chunk
    id and moves to the next id of its sequence only past a fence. Both imports need a coordinator mint
    rule (`rp_inventory sys:migration *`, `rp_economy sys:* money`): nothing mints by default, and a
    missing rule refuses the subject before any chunk. The 1.x wallet import keys wallets by
    `subjectOf(identifier)` (the identifier by default), and the opIds stay named after the 1.x row.
  - **Exports.** Additive only: `rp_inventory:grantPockets` (consumed by `rp_cargo` and `rp_economy`'s
    `sale`, so `FROZEN_SURFACE["rp_inventory"]` gained it), `rp_garage:labIssue` (lab, convar-gated),
    events `rp_inventory:settled` and `rp_economy:pendingChanged`; `rp_economy:sale` accepts
    `{ instance, from? }` entries. No signature or token of a frozen export changed. No schema change.
  - **Suite.** The coordinator in every suite is the vendored final resource
    (`tests/compat/vendor/open77_transactions`, `server/main.lua` included); the B8 suite runs unchanged.
