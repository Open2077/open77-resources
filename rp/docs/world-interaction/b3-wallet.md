# B3: wallet adapters (`rp_economy`, `rp_bank`) over the transaction coordinator

**Row:** B3 of the world-interaction plan (`wt-world-interaction/docs/world-interaction-plan.md` §4 B), wave 1.
**Date:** 2026-10-12. **Branch:** `wi/b3-wallet` of `Open2077/open77-rp-examples`, from `wi/b8-compat` (d401b40).
**Contract:** `wt-world-interaction/docs/world-interaction/a13-transaction-contract.md` (§3, §7.2–§7.4, §12).

**Status: offline only.** Nothing was deployed, launched or run against a database. Every claim
below comes from the source or from the offline suite (`tests/test_compat_wallet.py`,
`tests/test_compat_economy.py`). Since the reconcile of 2026-10-12 (branch `wi/reconcile-a13`) the
coordinator there is the **final** wave-1 `open77_transactions` of Open77 `697e9e2f`, vendored
unmodified and run whole as a resource (`server/main.lua` included; the only seam is
`tests/compat/txshim.lua`); the wave-0 build used the prototype behind a stand-in. §8 says what the
final coordinator resolved. **Fact** = seen in source or measured offline; **inference** = follows
but unmeasured; **open** = a decision.

---

## 0. Summary

1. **`rp_economy` 2.0.0 and `rp_bank` 2.0.0 are facades.** The coordinator owns every balance
   (`cash:<subject>`, `bank:<subject>`, `soc:<name>`; contract §3.1). `rp_economy` keeps the wallets
   in use in a cache (`server/wallets.lua`); `rp_bank` keeps the ATMs, menus and commands and maps
   its eight exports onto `rp_economy`. Neither has a store of its own any more.
2. **The 1.x synchronous exports keep their signatures** (`add`/`remove`/`getBalance`, the eight
   `rp_bank` exports) through a **write-behind facade** (contract §7.4 option i, decision 2): checked
   on the cache, applied to it at once, committed in the background as one double-entry
   operation. **New asynchronous atomic exports** for the pilot flows (option ii): `pay`, `charge`,
   `invoice`, `sale`, `refund`, plus `status` and `balanceOf`.
3. **R1 closed for these two resources.** No KVP for economic state; while the coordinator is
   missing or reports an outage every change is refused (`store_unavailable` / `bank_not_ready`).
   The B8 expected failure is now a passing test.
4. **Money creation goes through an allowlist with hourly caps** (decision 6), booked per
   *original* calling resource; 21 pack resources credit money from no wallet today (`add`,
   `societyAdd`), so 21 are on the allowlist (§4).
5. **One-shot, journaled, version-checked import** of `rp_economy_wallets`, `rp_bank_accounts`,
   `rp_bank_societies`, paged so the bridge's silent 10 000-row truncation cannot drop accounts;
   the 1.x ledger stays a read-only archive.
6. **Offline suite: 24 tests, OK** (15 new in `test_compat_wallet.py`, the B8 ones updated).
7. **Coordinator API needs** (§8): resolved by Open77 `697e9e2f` (health, subjectOf, replay before
   refusal, fresh attempt after a failure, mint rules, reasons, history, `authorize`); the facade
   uses them. Left: the mint-rule grammar names one `sys:` segment, and the bank statement does not
   read `history` yet (§8).
8. **Reconcile additions (2026-10-12):** `sale` accepts instance lines and asks
   `rp_inventory:grantPockets` under strict writers; `rp_salvage` (C1) on the allowlist;
   `rp_economy:pendingChanged(playerId)` for a HUD (B7).

## 1. Files

| File | Role |
|---|---|
| `rp_economy/open77.lua` | 2.0.0; six server scripts; no hard dependency line on the coordinator (a missing coordinator is reported, not a start failure) |
| `rp_economy/server/config.lua` | `EconomyConfig`: coordinator name, probe cadence, server tag, gameplay constants, write-behind retry, mint allowlist and caps, trusted facades, preloaded societies, migration |
| `rp_economy/server/tx.lua` | coordinator client: `Tx.call` (a rejected promise is `in_doubt`, never a failure), `Tx.subjectOf`, health probe, `Tx.resolve` |
| `rp_economy/server/mint.lua` | the allowlist: net mint per resource per fixed hour |
| `rp_economy/server/wallets.lua` | the cache, write-behind (`Wallets.legacy`), atomic runner (`Wallets.run`), ordering, replay probes, player attach |
| `rp_economy/server/migrate.lua` | import of the 1.x tables, state row, KVP report |
| `rp_economy/server/main.lua` | exports (1.x, bank facade, atomic API), payday, lifecycle, commands |
| `rp_bank/server/main.lua` | 2.0.0: exports over `rp_economy:walletMove/walletRead/societyRead`, ATM and `/virement` over `rp_economy:pay`, statement = this boot + archive; staging and ATM placement unchanged |
| `tests/compat/multihost.lua` | multi-resource fake host (new, additive to `fakehost.lua`) |
| `tests/compat/txhost.lua`, `tests/compat/vendor/open77_transactions/` | the A13 prototype (pinned copy, blob ids in `SOURCE.txt`; `OP77_TX_DIR` overrides) behind a **test** stand-in for its exports |
| `tests/compat/wallet_world.lua`, `wallet_scenarios.lua`, `tests/test_compat_wallet.py` | fixtures, scenarios, assertions |
| `tests/compat/economy_scenarios.lua`, `tests/test_compat_economy.py` | the B8 scenarios, retargeted; R1 passes |
| `tests/test_compat_contracts.py`, `tests/compat/schema-snapshot.json` | frozen values updated with the audit note (§6) |

## 2. Facade API: old and new

### 2.1 Unchanged signatures (write-behind)

| Export | 1.x | 2.0.0 |
|---|---|---|
| `rp_economy:getBalance(playerId)` | memory balance, 0 when unknown | cached balance (snapshot + pending changes), 0 when unknown or not loaded |
| `rp_economy:add` / `remove(playerId, amount, reason)` | memory first, absolute SQL write-through (reorderable, A13 finding 1) | one operation `sys:<caller>:legacy` ↔ `cash:<subject>`, applied to the cache at once, committed in the background |
| `rp_bank:getAccount(playerId)` | creates the row on first sight | `{ identifier, balance, createdAt }` from the cache; `createdAt` = first served this boot |
| `rp_bank:deposit` / `withdraw` | two stores, two writes (a crash between = money lost or created) | **one** operation `cash:<s>` ↔ `bank:<s>` |
| `rp_bank:transfer(from, toIdentifier, amount, fee?)` | full-table cache, any known identifier | one operation (+ fee burned to `sys:rp_bank:fee`); only accounts this server has loaded (§2.4) |
| `rp_bank:society(name)` | row created on first use | cached; `bank_not_ready` until a never-seen society has loaded |
| `rp_bank:societyAdd` / `societyRemove` | absolute write | `sys:<original caller>:legacy` ↔ `soc:<name>`; the add is a mint, counted against the **original** caller |
| `rp_bank:charge(playerId, amount, society, reason)` | two cache writes | one operation `bank:<s>` → `soc:<name>` |

Every 1.x refusal token is kept. New ones: `store_unavailable` (rp_bank maps it, and
`migration_*`, to its own `bank_not_ready`), `migration_pending` / `migration_failed` /
`migration_version_newer`, `mint_denied`, `mint_cap`, `account_not_loaded` (rp_bank), and
`caller_denied` (the bank-facade exports for anyone but `rp_bank`).

Events: `rp_economy:changed` as in 1.x (immediate for write-behind); new
`rp_economy:walletChanged(kind, playerId, key, newBalance, delta, reason)` for cash, bank and
societies, re-published by `rp_bank` as the 1.x `rp_bank:changed` (one tick later than 1.x); new
`rp_economy:writeBehindFailed(opId, reason, kind, lines)`.

### 2.2 New: synchronous bank-facade exports (`rp_bank` only)

`walletRead(playerId, kind)`, `societyRead(name)`, `walletMove(spec)` — trusted callers only
(`EconomyConfig.trustedFacades`), because `walletMove` names the original caller for the mint
allowlist (`onBehalfOf`).

### 2.3 New: asynchronous atomic exports

`pay`, `charge`, `invoice`, `sale`, `refund`, `status`, `balanceOf` — spec shapes in
`rp_economy/README.md` "Atomic API". Properties (all tested, §6):

- **One coordinator operation** per call: money lines, the items of a sale, the society share and
  every split commit together or not at all; payees must sum to the total (`invalid_split`).
- **Caller-owned `opId`**, derived from the business identity: a duplicate intent in flight joins
  the same operation; a replay after a restart returns the stored receipt (`replay = true`) and
  pays once. The replay is recognised by the **request**, not by the computed lines, because a
  `cash_then_bank` split depends on the balances of the moment.
- **In-doubt is never failure**: an answer that does not come within 20 s is `in_doubt`; the
  facade keeps resolving (`status(opId, { resolve = true })`) and the caller polls `status`.
- **Offline subjects** can be credited and refunded (`{ identifier = guid }`), closing B8 R2.
- `refund` reverses the money lines of a committed operation onto the **original instruments**
  (B8 §5.3: rp_shops refunded account payments as cash). Goods are not returned.
- `sale` takes goods from `char:<subject>` (or any container named in the spec) to an NPC buyer
  `sys:<caller>:<label>` (goods destroyed, price minted) or a player's pockets. An item entry is
  `{ item, count, from? }` or, since the reconcile, `{ instance, from? }` (one unique unit with its
  metadata, e.g. a C1 salvage crate out of `veh:<plate>:cargo`; `invalid_instance` for a bad id).
- **Strict writers.** When the coordinator's `writers` keeps `char` to `rp_inventory`, `sale` asks
  `rp_inventory:grantPockets(opId, playerId)` (a one-operation `authorize`) for a connected seller's
  pockets before it commits; without it the sale is refused `namespace_denied` and nothing is
  attempted. Goods out of `veh:`/`stash:`/`world:` need `rp_economy` in `writers` for them (no
  grant is requested there).
- **`rp_economy:pendingChanged(playerId)`** (reconcile, for B7's HUD): raised when an operation on a
  connected player's wallet enters `in_doubt`, and when an atomic or in-doubt one settles; a hint to
  re-read, coalesce it.

### 2.4 Mapping and policy kept in the adapter (contract §7.3)

| Policy | Where |
|---|---|
| subject of a player | the coordinator's provider `subjectOf` (decision 5), for a player id or an account identifier (offline subjects, the 1.x import); a refusal is passed through and a coordinator that is not running answers `coordinator_unavailable` (no fallback: adapters never build owner keys) |
| limits, reason texts | 1.x checks kept (amount, 64-byte reason, 1e9 per bank operation, 1e12 balance) |
| typo protection on wires | synchronous `transfer`: only accounts this server has loaded (it cannot ask the coordinator without yielding); the ATM and `/virement` use `pay` after `balanceOf(...).exists` |
| funds known before a debit | a society not loaded yet refuses debits (`bank_not_ready`), accepts credits |

## 3. How the cache stays one source of truth

- **Snapshot + effects.** Each cached wallet holds the last coordinator snapshot (balance,
  version). The displayed balance adds every tracked operation the snapshot does not contain yet:
  a write-behind change at once, an atomic debit while in flight (the coordinator holds it), an
  atomic credit once committed. A committed operation is dropped when a snapshot's version reaches
  the version its receipt reports for that wallet (or, without versions, when a read issued after
  the receipt is adopted). A snapshot is not adopted while a counted operation on that wallet is
  still in flight, so nothing is counted twice.
- **Ordering.** A debit was accepted against a display that already counted earlier write-behind
  credits; it therefore waits until every earlier write-behind credit to the wallet it debits has
  settled. Nothing else is ordered. Dependencies point to older operations only, so the oldest
  pending one can always run (no deadlock). **Fact (offline):** without this, a society debit
  raced the not-yet-committed credit that funded it and was refused; the first version of the
  facade, which ordered per debited wallet only, failed `bank_facade` that way.
- **Write-behind retries.** An outcome proven "not committed" (`conflict`, `store_unavailable`,
  `aborted`) is retried under a new attempt id `<opId>-r<n>` for up to 10 minutes, waiting for
  health; `in_doubt` is resolved first, never retried blindly. A definitive refusal reverts the
  cached change and logs `write-behind … refused`.
- **Other writers** (another resource calling the coordinator directly): their
  `open77_transactions:committed` event makes the cache re-read the touched wallets.
- **Operation ids** are `<serverTag>.wb.<bootTag>.<n>` with `bootTag` = wall-clock seconds plus a
  random suffix. **Fact (offline):** a first version took the monotonic clock, which restarts with
  the process: two boots minted the same ids and the second boot's write-behind was refused as
  `op_id_conflict`. Set `rp_economy_server_tag` per server when several share one database.

## 4. Money creation: sources and caps

Booked per original caller, net (created minus destroyed) in a fixed one-hour window; burns
restore budget, so a resource that only moves money between players nets to zero. Unlisted =
`mint_denied`.

**The coordinator's own rule (697e9e2f, contract §12.6).** The coordinator sees one caller,
`rp_economy`, and its rule grammar names one `sys:` segment (`sys:<name>` or `sys:*`), so it cannot
address `sys:<resource>:<label>` one by one (a rule for `sys:rp_economy:start` is ignored with a
warning; `test_final_coordinator_api`). The server therefore sets one ceiling for this resource,
for example `mint1 = "rp_economy sys:* money 2000000"`, and the table below caps each original
caller. `Tx.mayMint` asks `allowed(rp_economy, sys:..., money)` inline, so a missing rule refuses a
write-behind credit at once (`mint_denied`) instead of reverting it later; an exhausted cap
(`mint_cap_exceeded`) reverts it. C1's items are its own rule (`rp_salvage sys:salvage * 400`). Estimates from a read-only survey of every call site (32 active players; the
survey's own assumptions; order of magnitude, **not** measured).

| Resource | Creates money today (call site) | Est. max/h | Cap (€$/h) |
|---|---|---|---|
| `rp_economy` start | 500 per new subject | — | 50 000 |
| `rp_economy` payday | 200 / 10 min per ready player (`:555`) | 38 400 | 100 000 |
| `rp_economy` `/givemoney` | admin, any amount (`:783`) | — | 100 000 000 |
| `rp_admin` | setmoney / setbank (`:524-568`) | — | 100 000 000 |
| `rp_jobs` | first-boss society seed 50 000 per job, once (`:432`); payroll is society → player | ≤ 600 000 ever | 600 000 |
| `rp_fixer` | gig payout + commission (`:580`, `:590`) | 40 000–160 000 | 200 000 |
| `rp_housing` | sell-back 70 % of an older purchase (`:633`) | up to 28 000 per sale | 200 000 |
| `rp_nomade` | crate delivery, convoy bonus, society share (`:899-918`) | ~80 000 | 100 000 |
| `rp_shop` (v1) | vehicle sell-back 50 % (`:764`) | 50 % of a car | 100 000 |
| `rp_gangs` | zone tribute, NPC deal (`:886`, `:1105`) | ~43 000 | 60 000 |
| `rp_crime` | fence payouts (`:1208`) | 3 000–30 000 | 50 000 |
| `rp_ferrailleur` | scrap sale to the NPC dealer + 10 % society (`:714`, `:723`) | 7 000–20 000 | 30 000 |
| `rp_netrunner` | breach bounty (`:852`, `:859`) | 2 500–27 000 | 30 000 |
| `rp_shops` | robbery loot (`:1515`), refunds | ~9 000 | 30 000 |
| `rp_salvage` (C1, reconcile) | scrap and crate sales to the NPC buyer through `sale`, society share | — | 30 000 |
| `rp_mecano` | impound fee to the society with no payer (`:1242`) | ~12 000 | 20 000 |
| `rp_vigile` | corpo guard contracts (`:375-387`) | ~1 200 per zone | 20 000 |
| `rp_garage`, `rp_ripperdoc` | refunds after burns, impound release | ~0 net | 20 000 |
| `rp_bar`, `rp_delamain` | transfers; refunds | ~0 net | 10 000 |
| `rp_medic`, `rp_ncpd` | transfers; refunds | ~0 net | 5 000 |
| `rp_selftest` | +100 / −100 on society `selftest` per boot | 0 net | 1 000 |
| `rp_phone`, `rp_chat`, `rp_hud`, `rp_logs` | burn or read only | 0 | not listed |

`rp_bank` itself mints nothing (deposit/withdraw are cash ↔ bank, fees are burns).
`rp_trauma` 2.0 left the list (it had 10 000 for refunds): its plans, fees and invoices move money
between wallets and `soc:trauma` through the coordinator and never call rp_economy, so it creates
none.
The import (`sys:rp_economy:migration`) is uncapped and only reachable through `economy_migrate`.

Value leaks found by the survey (**facts from source, not fixed here**; they now hit the caps
instead of being unbounded): a gutted Nomad crate pays twice (fence + delivery,
`rp_crime:1089-1096` / `rp_nomade:890-918`); robbing four of the five shops is pure creation
(only `pharmacy` has a society, `rp_shops/shared/config.lua:162`); `rp_vigile` refunds an escrow
without debiting it (`:241`, `:438-448`); refunds pay out even when the matching society debit
fails (`rp_housing:526-535`, `rp_ripperdoc:175-182`); `rp_fixer` pays the commission when the
payout fails (`:579-597`); `rp_mecano` impound credits 100 for any empty vehicle (`:1183-1242`);
`rp_jobs` seeding keyed on a KVP flag re-seeds after a KVP wipe (`:421-444`). These are the
callers' flows; they move to the atomic API (decision 2) with their own rows.

## 5. Migration

`economy_migrate` (console; or `EconomyConfig.migration.auto = true`). Implementation:
`rp_economy/server/migrate.lua`.

1. At every ready boot `Migrate.check()` creates the archive tables if missing (the 1.x DDL,
   unchanged, so a server that never ran 1.x answers "nothing to import" instead of a schema
   error) and the state table `rp_wallet_migration` (one row, `k = 1`, `schema_version`).
   - State row newer than this build → **blocked** (`migration_version_newer`), wallets refused,
     nothing re-imported.
   - State `complete` at this version → serve.
   - No 1.x rows → write `complete`, serve.
   - Otherwise **pending**: every wallet change is refused (`migration_pending`) so nobody gets a
     fresh 500 and then the imported balance.
2. The run reads each table in keyset pages of 500 (`WHERE key > ? ORDER BY key LIMIT 500`) and
   compares the rows read with `COUNT(*)` taken before; a mismatch fails the run (D8: a truncated
   read is only a WRN line on the host). Invalid rows (not a durable key, not an integer balance
   in 0..1e12) are **reported**, never dropped silently.
3. One coordinator operation per subject (`rp.migrate.v1.s.<subject>`, kind `migrate`, a cash line
   and a bank line from `sys:rp_economy:migration`) and per society (`rp.migrate.v1.soc.<name>`);
   zero balances need no operation. Sixteen in flight at once. Fixed ids make a re-run a replay.
4. State `complete` with the counts and a bounded report; or `failed` (re-run: idempotent).
5. A subject with no wallet at first join gets the 500 starting balance **unless** the archive has
   a 1.x wallet or account row for it (a broke 1.x player stays at 0); the grant has a fixed id
   `rp_economy.start.<subject>`, so two servers cannot both pay it.
6. `rp_bank_transactions` is not imported: `rp_bank`'s statement shows it as `archive` lines.
   KVP (`balance:*`, `acct:*`, `soc:*`) is never imported: `economy_kvp_report` and
   `bank_kvp_report` list the differences (B8 §5.6 rule 2).

Not covered: the `rp_jobs` `seeded:<job>` KVP flags (B8 §5.3) stay in `rp_jobs` (B4); the
`selftest` society is imported like any other.

## 6. Offline tests

**Reconcile (2026-10-12):** `test_compat_wallet.py` + `test_compat_economy.py` 20 tests, OK (about
14 s), against the final coordinator; the whole `python -m unittest discover -s tests -p "test_*.py"`
85 tests, all pass but the pre-existing `test_held_actions` (needs `lupa`). The coordinator is a
resource of its own on `multihost.lua` (which gained `Open77.tunables` and `MH.setTunable`), hosted
by `txhost_wallet.lua` (the database: a deferred memory store, its pace, its crash modes);
`WW.txTunables` holds the test server's `writers`/mint rules. New: `test_final_coordinator_api`
(mint rules, reasons, strict writers + grant, instance sale, character provider), and
`test_vendored_coordinator_is_unmodified` checks the eight vendored files against `697e9e2f`.

Wave-0 run: `python -m unittest discover -s tests -p "test_compat*.py"`: **24 tests, OK**, ~8 s, on the
KeraLua `lua54.dll` through ctypes (no `lupa` on this workstation). New engine piece:
`tests/compat/multihost.lua` runs several resources with one environment each, synchronous and
promise exports (`export_yielded`, `export_timeout`, `export_resource_stopped`,
`GetInvokingResource`), the queued host-wide `TriggerEvent`, deferred database callbacks and
per-resource KVP. The coordinator is the vendored A13 prototype (unchanged) with its memory store
playing the database and its fault injection (`unreachable_before`, `lost_ack`, `down`, detached
or discarded work on a VM stop).

| Test (`test_compat_wallet.py`) | Shows |
|---|---|
| `test_replayed_sale_pays_once` | sale twice in flight, then again after a full restart: one commit, cash +270, society +30, goods gone once, journal sums 0 per asset; a different request with the same id → `op_id_conflict`; a new intent for sold goods → `insufficient_items` |
| `test_split_payout_sums` | freight pay: gross + three convoy shares + society in one commit; a split that does not sum → `invalid_split`; the source absorbs exactly −840 |
| `test_crash_between_debit_and_credit` | four crash windows of a sale (store fails before COMMIT; ack lost; coordinator VM dies with the commit reaching the database; dies before it does): goods XOR money every time, replay agrees; an `rp_bank` deposit hit by a failure before COMMIT retries and lands both legs |
| `test_offline_credit` | pay to an offline identifier (seen at join), refund to a disconnected payer, wire to an offline bank account |
| `test_sync_callers_keep_their_contract` | the helper forms of `rp_jobs` (seed, payroll), `rp_ferrailleur` (crowbar), `rp_nomade` (`callSync`), `rp_admin` (`ok, a, b`), `rp_shops` (cash → withdraw fallback), `rp_garage` (charge → cash fallback), `rp_hud` (reads, events): 1.x return shapes and tokens, cache = durable, transfers net 0 against the caps |
| `test_refused_write_behind_is_reverted_and_logged` | another writer drains the wallet between the cache check and the commit: the change is reverted and logged |
| `test_bank_facade` | the eight exports and their tokens; money conserved to the cent (fee burned) |
| `test_invoice_paid_once_and_refunded_to_the_original_instruments` | cash-then-bank invoice paid once (replay by request), refunded once to cash and bank |
| `test_mint_allowlist_and_hourly_cap` | cap, burn credit, next window, unlisted resource |
| `test_migration_golden_fixture` | pending refusal, import counts, skipped rows reported, no start grant for a 1.x subject, idempotent re-run, KVP reported not imported, newer schema blocks |
| `test_migration_reads_past_the_10000_row_truncation` | 10 050 subjects: the 1.x unbounded boot load gets 10 000 rows, the paged import all 10 050 |
| others | sources compile (Lua 5.4 `load`), smoke, new refusal tokens, vendored copy unmodified |

`test_compat_economy.py`: the three B8 scenarios on the facade; **the R1 invariant passes**.

Limits of these tests: the memory store mirrors the coordinator's plan semantics by construction
(A13 §9), so SQL behaviour on MariaDB (A13 I1–I3) is untested; the stand-in `txhost.lua` is not
the coordinator's real wiring; the fake host is not the Open77 scheduler (tick timing, budgets).

## 7. What the integrator must run in game

Lab only, two clients at most, after the coordinator's wave-1 wiring lands (§8 items 1–2 at least):

1. `resources.load`: `open77_transactions` (store `sql`) before `rp_economy` and `rp_bank`. Log:
   `[rp_economy] coordinator ready (store=sql)`.
2. On a server with 1.x data: the WRN `… not imported yet`, then `economy_migrate`; read the
   `migration … complete` summary and any `skipped` lines; compare a few balances with the 1.x
   rows; run `economy_kvp_report` and `bank_kvp_report`.
3. Join with A and B: 1.x balance, no extra 500 for an existing player; a new account gets 500.
4. `/money`, `/pay`, payday (`/payday`), `/givemoney`; ATM deposit / withdraw / wire to an offline
   citizen id; `/virement` (fee); `/societe`; the statement shows `archive` lines.
5. The untouched callers through the write-behind facade: scrap sale at Rusty, a Nomad delivery,
   a payroll tick, a shop purchase. `SELECT * FROM op77_tx_wallets` agrees with `/money`; the log
   has no `write-behind … refused` line.
6. Outage: stop the database (or the coordinator) mid-session. Expect refusals
   (`Wallet unavailable (store_unavailable)`, `The bank network is unavailable`), no new
   `kvp.json` entries for `rp_economy`/`rp_bank`; restart it: balances unchanged, a change accepted
   just before the outage present once.
7. Restart the server between steps 4 and 5: balances and the statement survive.
8. Measure the latency of `/pay` and of an ATM deposit (A13 I4) and watch for `in_doubt`.

## 8. Coordinator API needs: resolved by Open77 `697e9e2f`

Reconciled 2026-10-12 against the final coordinator (contract §7.2, §13.5, §13.7: B3 a–g).

| # | Need (wave 0) | Outcome | Facade now |
|---|---|---|---|
| 1 | `health()` readiness | resolved (`health`, superset of `info`) | `Tx.probe` is healthy only when `ready` and not `coordinator.down` (the coordinator marks the store down after an unreachable answer and clears it itself); the `status()` fallback is gone |
| 2 | `subjectOf(playerId \| identifier)` + one override | resolved | `Tx.subjectOf` passes the identifier string; offline credits, the 1.x import and `isLegacySubject` (keyed by the identifier) follow the provider; `~` accepted in subjects; opIds with a `~` key are hashed |
| 3 | replay before validation | resolved (the operation row is read before a business refusal) | the `status` probe is kept only for `op_id_conflict` (a recomputed cash-then-bank split) and `unknown_account` |
| 4 | fresh attempt after a failure | resolved: failed = fresh attempt, fenced = `aborted` for ever | unchanged and consistent: write-behind retries under `<opId>-r<n>` (always safe), an atomic caller may reuse its id after a failure, never after `aborted` (`info.state`) |
| 5 | receipts (`replay`, `versions`) | partly: `replay` is set; a replayed receipt's `versions` are the stored receipt's (none) or the pre-reload mirror's | a replayed receipt's versions are ignored: the wallet is re-read |
| 6 | mint caps per sys account | resolved for one-segment names | one coordinator ceiling for `rp_economy` (§4) plus this resource's per-caller budgets; `Tx.mayMint` pre-checks |
| 7 | ACL for `sale` | resolved (`writers` per namespace/part, `authorize`) | `sale` asks `rp_inventory:grantPockets` for a connected seller's pockets |
| 8 | bounded `reason` | resolved | every operation carries the business reason (≤ 64 bytes) to the receipt and journal; not part of the request hash |
| 9 | `history`, `soc:` enumeration | `history(account, { limit, before })` resolved; no `soc:` listing (`list` covers containers only) | **not used yet**: the bank statement still shows this boot plus the 1.x archive; merging `history(bank:<subject>)` is a follow-up |
| 10 | `newOpId` boot component | resolved (wall-clock boot) | unchanged (the facade mints its own ids) |

**What remains (not in the final coordinator):** a mint rule cannot name `sys:<resource>:<label>`;
`allowed()` takes no amount; `status` always yields (B7 asked for a cheap one); the `committed`
event names no invoking resource (A9 N5).

## 9. Needed from the `rp_inventory` row (B2/B12; not edited here)

- **Done in B2 and reconciled:** pockets are `char:<subject>` containers with the same subject
  provider; definitions re-sent when the coordinator restarts; `grantPockets` for `sale` under
  strict writers.
- Pockets as coordinator containers **`char:<subject>`**, opened (capacity) at join, with the same
  subject provider; item definitions registered through the coordinator's `define`, re-sent when
  `open77_transactions` restarts (its definitions live in memory).
- Its cache must re-read `char:` containers on `open77_transactions:committed`, because `sale`
  moves goods out of the pockets without calling `rp_inventory`.
- Then `rp_ferrailleur` `sellAll` becomes one `rp_economy:sale` (goods + 90/10 split) and the
  crowbar purchase one `charge` + item line; `rp_nomade` pay one `pay` with the convoy split
  (payees sum to the total). These caller migrations are the pilot rows' work (decision 2).

## 10. Duplicate economies (documented, not fixed)

- **`rp_shop` (v1)** and `rp_shops` both `auto_start true` (`rp_shop/open77.lua:3`,
  `rp_shops/open77.lua:8`). `rp_shop` keeps its own KVP vehicle ledger `garage:<identifier>`
  (`rp_shop/server/main.lua:157`) holding **runtime** vehicle ids, and its `/sell` refunds 50 %
  (`:33`, `:764`) — a mint, now capped at 100 000/h. It still calls the synchronous facade
  (`:88`, `:101`, `:114`) and keeps working. Disable or migrate it before A9 (B8 §5.5).
- **`rp_medic`** and `rp_trauma` both auto-start and both register `/soin`, `/reanimer`, `/911`,
  `/medic` (`rp_medic/server/main.lua:534-681`, `rp_trauma/server/main.lua:1314-1385`). `rp_medic`
  compares `getJob()` with the legacy names `medecin`/`police` (`:23-24`, `:98-104`), so in jobs
  mode no one is a medic. Its fees are patient → medic transfers through the facade (cap 5 000/h
  covers refunds). Owner decision under plan decision 5.

## 11. Risks and open points

- **Write-behind is no stronger than 1.x** (by decision): a change accepted, then lost with the
  server before it was submitted, is gone; one refused later is reverted after the caller already
  acted on it (logged, event raised). Pilot flows must use the atomic API.
- **Inference:** a busy write-behind credit stream makes a later debit of the same wallet wait one
  coordinator round trip per pending credit; not measured.
- **Open:** whether `.await` raises or returns `nil, err` (B8 §8 q1): `migrate.lua` handles both.
- **Open:** `transfer` (synchronous) to offline accounts is refused unless loaded this boot; zero
  external callers today.
- The cache keeps every wallet seen this boot (offline players included); unbounded only by the
  number of distinct players per boot.

## 12. Research ledger entry (for the integrator to copy)

> **2026-10-12 — B3 wallet adapters over the A13 coordinator (RP pack, branch `wi/b3-wallet`).**
>
> **Facts (source, offline suite):**
> - `rp_economy` 2.0.0 / `rp_bank` 2.0.0 are facades over `open77_transactions`; no KVP for economic
>   state; outage = refusal (`store_unavailable` / `bank_not_ready`). B8 R1 passes for both.
> - 1.x synchronous exports unchanged in signature (write-behind, contract §7.4 i); new atomic
>   `pay`/`charge`/`invoice`/`sale`/`refund`/`status`/`balanceOf` (one coordinator operation each,
>   caller-owned idempotent ids, replay pays once, offline credits).
> - Money creation is booked per original caller against hourly net caps; 21 pack resources
>   credit money from no wallet today and are allowlisted.
> - The 1.x import is paged, count-verified, journaled per subject, version-checked and
>   idempotent; the 1.x boot load is silently cut at 10 000 rows (measured offline on 10 050).
> - Offline suite: 24 tests, OK (KeraLua `lua54.dll` through ctypes).
>
> **Prototype gaps found (coordinator, A13):** a replay after a restart re-validates holds before
> the operation row (`insufficient_items` for a sold sale); a failed id is refused until restart
> instead of a fresh attempt; no readiness or subject-provider export. The facade works around the
> first; the list is in b3-wallet.md §8.
>
> **Facade bugs found and fixed offline:** monotonic-clock boot tags repeated operation ids across
> restarts; per-wallet FIFO ordering let a society debit race its funding credit; `x and f()`
> dropped the refusal reason (`mint_cap` reported as `mint_denied`).
>
> **Inferences (unmeasured):** latency of one atomic operation ≈ one export hop + one store round
> trip; MariaDB semantics of the generated SQL (A13 I1–I3).
>
> **Next:** coordinator wave-1 wiring with §8 items 1–4; `rp_inventory` as `char:<subject>`
> containers (B2/B12); move `rp_ferrailleur`/`rp_nomade` pay to `sale`/`pay`; the §7 lab run.
