# rp_economy

Gives every player a cash wallet in eurodollars: 500 to start, 200 every 10 minutes on payday, /money to check it and /pay to give some. Other RP resources move money through its exports, including atomic sales that never half happen.

- **Docs:** [Durable transactions](https://open2077.net/docs/transactions)
- **Starts:** on its own
- **Needs:** nothing
- **Runs on:** server

**Server-only** resource for Open77. Version **2.0.0** is a **facade over the
`open77_transactions` coordinator** (world-interaction row B3): the coordinator owns every
balance, this resource keeps the wallets in use in a cache and offers two APIs — the unchanged
synchronous exports of 1.x, and an atomic asynchronous API for flows that must never half-happen
(a sale, a split payout, an invoice). A new player starts with **500 €$**; every player is keyed
by the durable subject the coordinator's provider returns (today the account identifier).

Design, tests and limits: [`docs/world-interaction/b3-wallet.md`](../docs/world-interaction/b3-wallet.md).
Nothing here has been run in game yet: the behaviour below is proven offline only.

## Requirements

- `open77_transactions` (Open77 repository, `resources/system`, `auto_start false`) loaded through
  `resources.load`, in **`sql`** store mode on any persistent server. The coordinator must grant
  `rp_economy` the namespaces `cash`, `bank`, `soc`, `sys` and, for `sale`, the item containers
  (`char`, `veh`, `stash`, `world`).
- Permission `network.events`: `RegisterNetEvent` (the `chat:ready` suggestion hook) and
  `Open77.notifications.send` (the toast that comes with `/money`).
- Permission `database.access`: only for the one-shot import of the 1.x tables, the read-only
  archive and the `rp_wallet_migration` state row. Balances are not stored by this resource.
- `rp_bank` 2.0.0 is the bank facade over this cache (accounts, societies, ATMs).

## No store of its own, no fallback

| Situation | What happens |
|---|---|
| Coordinator ready | `[rp_economy] coordinator ready (store=sql)`; wallets load when players are ready. |
| Coordinator missing, or its store down | `[rp_economy] coordinator unavailable (<reason>): wallet changes are refused, no fallback`. Every change answers `store_unavailable`; players see `Wallet unavailable (store_unavailable): retrying.` The cache keeps showing what it knew. |
| It comes back | Detected by the probe (2 s while unavailable, 15 s otherwise): wallets load, nothing to merge. |

There is **no KVP fallback** any more (gap R1 of the B8 audit): 1.x gave every player a fresh
500 €$ wallet on a boot without database and lost what was earned there. An outage now refuses
instead of forking.

## Server exports — the 1.x contract, unchanged signatures

```lua
exports.rp_economy:getBalance(playerId)              -- integer, 0 when unknown or not loaded
exports.rp_economy:add(playerId, amount, reason)     -- newBalance | nil, reason
exports.rp_economy:remove(playerId, amount, reason)  -- newBalance | nil, "insufficient_funds" | nil, reason
```

These are **write-behind**: checked against the cache, applied to it at once (the return value
and `rp_economy:changed` are immediate, as in 1.x), and committed in the background as one
double-entry coordinator operation. That is no stronger than 1.x, but every write is a delta (two
writes can no longer land in the wrong order), there is one source of truth, and a change that
cannot be committed is reverted in the cache and logged:
`write-behind <opId> (<kind>) refused by the coordinator: <reason>; the cached change is reverted`
(event `rp_economy:writeBehindFailed(opId, reason, kind, lines)`).

Refusals: the 1.x tokens (`invalid_player_id`, `player_not_found`, `invalid_amount`,
`invalid_reason`, `insufficient_funds`, `balance_limit`) plus:

| Token | Meaning |
|---|---|
| `store_unavailable` | the coordinator is missing or reports a store outage; nothing was applied |
| `migration_pending` / `migration_failed` / `migration_version_newer` | the 1.x import has not completed (below) |
| `mint_denied` | the calling resource is not on the mint allowlist (it may still `remove`) |
| `mint_cap` | the calling resource reached its hourly money-creation cap |

Use them exactly as before: `add`/`remove` stay safe to call synchronously.

### Read-only HUD exports (row B7, additive)

```lua
exports.rp_economy:walletStatus(playerId, { minAgeSeconds = 1.5 }?)
-- { loaded = true, reason? = "store_unavailable",
--   cash = { balance, incoming, outgoing, unconfirmed, inDoubt, ops, oldestSeconds }, bank = { ... } }
-- | { loaded = false, reason = "not_loaded" | "store_unavailable" | "migration_pending" | ... }
-- | nil, "invalid_player_id"
exports.rp_economy:pendingPlayers({ minAgeSeconds = 1.5 }?)   -- { [playerId] = fingerprint }
```

Synchronous, never yield, read the cache only, change nothing. `balance` is what `getBalance`
shows; `incoming` = atomic credits in flight (NOT in the balance yet), `outgoing` = debits in
flight (already subtracted), `unconfirmed` = write-behind credits not acknowledged (already
added), `inDoubt` = operations whose caller was told `in_doubt` (or older than
`asyncWaitSeconds`). `loaded = false` means unknown: never draw it as 0. `rp_hud` is the
consumer (`docs/world-interaction/b7-ui.md`): it pushes the result to that player only.

## Atomic API (asynchronous)

Call with `Open77.exports.call("rp_economy", name, spec)` and `:await()` from a thread, a handler
or a command (they yield). Each is **one** coordinator operation: everything in it commits
together or not at all. `opId` (8–96 characters `[A-Za-z0-9_.:@-]`) is **yours**: derive it from
the business identity (`ferrailleur:sale:<subject>:<intent>`), so a repeated intent, a retry
after a timeout or a replay after a restart returns the original receipt and **pays once**.

A *party* is `{ player = id }`, `{ subject = s }`, `{ identifier = guid }` (offline subjects are
fine for credits), each with an optional `wallet = "cash"|"bank"` (default cash), or
`{ society = name }`, or `{ sys = label }` — money created or destroyed on behalf of the caller
(`sys:<your resource>:<label>`, counted against your mint allowlist).

```lua
-- Pay one or several payees from one payer (freight pay with convoy split and society share).
pay     { opId, from = party, to = party, amount }                        -- or payees = { { party..., amount }, ... }
-- A purchase, a fine, a fee: to a society/player, or burned (default sys:<you>:sink).
charge  { opId, from = party, amount, instrument = "cash"|"bank"|"cash_then_bank", to = party | payees = {...} }
-- A bill split among payees; never paid twice for one opId.
invoice { opId, from = party, amount, instrument, payees = { ... } }      -- payees must sum to amount
-- Goods out + price in + split, one operation. Goods leave char:<seller> (or `from`) to the
-- buyer: an NPC buyer { sys = "dealer" } (money minted, goods destroyed) or a player (their pockets).
sale    { opId, seller = party, items = { { item, count, from? } | { instance, from? } }, buyer = party, total, payees? }
-- The money lines of a committed operation, reversed: each payer gets back what it paid, on the
-- instrument it paid with. Goods are not returned. Default opId "refund:<of>": once per original.
refund  { of = opId, opId?, reason }
status(opId)       -- { state = "committed"|"failed"|"in_doubt"|"aborted"|"unknown", receipt? }
balanceOf(party)   -- { account, balance, exists }, connected or not
```

Answer: a receipt `{ opId, kind, state = "committed", replay, lines, balances = { [account] = n } }`,
or `nil, reason, info` with `info.retryable`. Reasons: `insufficient_funds`,
`insufficient_items`, `capacity_exceeded`, `invalid_split`, `op_id_conflict` (same id, different
request), `mint_denied`, `mint_cap`, `store_unavailable` (retryable; with `info.state = "aborted"`
the id was fenced and can never commit: use a new id), `in_doubt` (no answer within 20 s: poll
`status(opId)`, never assume failure), and the coordinator's own tokens (a13 contract §7.2).

`sale` needs the goods to be coordinator containers: `char:<subject>` pockets come with the B2
inventory adapter (`rp_inventory` as a facade), vehicles `veh:<plate>:<part>` with A9. An
`{ instance }` entry sells one unique unit (a salvage crate) with its metadata. When the
coordinator's `writers` keeps `char` to `rp_inventory`, `sale` asks `rp_inventory:grantPockets` for
a connected seller's pockets (one operation) before committing.

The coordinator (`open77_transactions`, Open77 697e9e2f) needs a money rule for this resource in its
tunables, e.g. `mint1 = "rp_economy sys:* money 2000000"`: nothing mints by default there, and its
rules name one `sys:` segment, so the per-caller caps below are this resource's.
`rp_economy:pendingChanged(playerId)` hints a HUD that the unsettled operations of a connected
player's wallet changed (one went `in_doubt`, or an atomic or in-doubt one settled).

## Mint allowlist

A credit that comes from no wallet (legacy `add`, `rp_bank:societyAdd`, an NPC buyer, a bounty)
creates money; a debit into `sys:` destroys it. The facade books both against the **calling
resource** (`GetInvokingResource`, or the original caller named by `rp_bank`), in a one-hour
window: the **net** amount created (created minus destroyed) may not exceed the resource's cap in
`server/config.lua` (`EconomyConfig.mint.callers`). A resource that moves money between players
nets to zero and never hits its cap; only real money creation counts. An unlisted resource gets
`mint_denied`. This resource's own sources: starting balance, payday, `/givemoney`
(`EconomyConfig.mint.internal`); the 1.x import is uncapped. The caps and how they were sized are
in b3-wallet.md §4.

## Commands

| Command | Who | Effect |
|---|---|---|
| `/money` | any player | Shows the balance (and a toast when notifications are running). |
| `/pay <playerId> <amount>` | any player | One atomic payment to a connected player. |
| `/givemoney <playerId> <amount>` | admin (ACL `command.givemoney`) or console | Credit (a mint from `sys:rp_economy:admin`). |
| `/payday` | admin (ACL `command.payday`) or console | Immediate payday. |
| `economy_migrate` | console | Imports the 1.x tables (idempotent). |
| `economy_kvp_report` | console | Lists 1.x KVP balances against SQL and the coordinator. Imports nothing. |
| `economy_status` | console | Coordinator, store, migration state, pending operations. |

**Automatic payday**: every 10 minutes, each ready player receives 200 €$ (`Payday: +200 €$`).

## Migration from 1.x

At the first boot where the coordinator is ready, rp_economy looks at the 1.x tables
(`rp_economy_wallets`, `rp_bank_accounts`, `rp_bank_societies`). If they hold rows that were never
imported, it refuses every wallet change with `migration_pending` and logs
`<n> 1.x wallet row(s) are not imported yet: wallets are refused until economy_migrate runs` —
so nobody receives a fresh starting balance and then the imported one. Run `economy_migrate` from
the console (or set `EconomyConfig.migration.auto = true`):

- one journaled coordinator operation per subject (cash + bank) and per society, with fixed ids
  `rp.migrate.v1.s.<subject>` / `rp.migrate.v1.soc.<name>`: a re-run replays, it never pays twice;
- the tables are read in pages of 500 and each table's row count is checked against `COUNT(*)`,
  so the bridge's silent 10 000-row truncation cannot drop accounts;
- rows that are not durable keys or not integer balances are **reported** (`migration: skipped
  <table>:<key>:<reason>`), never dropped silently;
- the state row `rp_wallet_migration` carries a schema version: a newer one blocks the facade
  (`migration_version_newer`) instead of re-importing;
- the 1.x tables stay as a read-only archive; `rp_bank_transactions` (the 1.x ledger) is not
  imported, `rp_bank`'s statement shows it;
- KVP values (`balance:<identifier>`) are never imported: `economy_kvp_report` lists the
  differences for an operator to decide.

## Events

```lua
TriggerEvent("rp_economy:changed", playerId, newBalance, delta, reason)               -- cash, as in 1.x
TriggerEvent("rp_economy:walletChanged", kind, playerId, key, newBalance, delta, reason)  -- cash | bank | soc
TriggerEvent("rp_economy:writeBehindFailed", opId, reason, kind, lines)
```

## Log

```
[rp_economy] coordinator ready (store=sql)
[rp_economy] new wallet player 3 <subject> balance=500
[rp_economy] loaded player 3 <subject> cash=500 bank=0
[rp_economy] +1000 player 3 salary by rp_jobs balance=1500 op=rp.wb.<boot>.1
[rp_economy] sale ferrailleur:sale:<subject>:n1 by rp_ferrailleur: 4 line(s)
[rp_economy] migration v1-rp-<t> complete: subjects=12 societies=4 imported=14 already=0 empty=2 skipped=0
```

## Test it

Offline: `python -m unittest discover -s tests -p "test_compat*.py"` (tests/test_compat_wallet.py,
tests/test_compat_economy.py). In game, the checklist of b3-wallet.md §7: load
`open77_transactions` before this resource, check `coordinator ready (store=sql)`, run
`economy_migrate` on a server with 1.x data, join (the 1.x balance, no extra 500), `/pay`, payday,
then stop the database mid-session: changes are refused, no KVP file grows, and the balances are
intact when it returns.
