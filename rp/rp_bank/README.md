# rp_bank

Gives every player a bank account next to their cash, used at ATMs around Night City or from anywhere with chat commands. Players deposit, withdraw and wire money, and every job gets a society account that pays its staff.

- **Docs:** [Durable transactions](https://open2077.net/docs/transactions)
- **Starts:** on its own
- **Needs:** `open77_uikit`, `open77_worldui`
- **Runs on:** server and client

Server-authoritative bank for an Open77 RP server. Version **2.0.0** is a **facade** (world-interaction
row B3): the **account** (`bank:<subject>`), the **society** funds (`soc:<name>`) and the cash
(`cash:<subject>`) are owned by the `open77_transactions` coordinator and cached by `rp_economy`,
the wallet facade; the **ledger** is the coordinator's journal. This resource keeps the ATMs, the
menu, the commands and the eight 1.x exports. Players use it at ATMs placed in the world, or from
anywhere with the phone-style commands. Design and tests:
[`docs/world-interaction/b3-wallet.md`](../docs/world-interaction/b3-wallet.md); nothing of
version 2 has been run in game yet.

## What the player sees

- A map pin, a ground ring and a floating `ATM` label at every configured ATM (`config.lua`).
  Walk up, look at it, press **E**: the server checks you really stand there and opens the menu.
- The menu (UI kit context menu, server-driven): **Deposit**, **Withdraw**, **Wire to a citizen**,
  **Statement** (last 10 operations), **Leave**. Every answer lands in chat as `NC Bank`.
- Chat lines are English, in eddies (`€$`).

## Commands

| Command | Where | Effect |
|---|---|---|
| `/bank` | within 3 m of an ATM | Opens the same menu as the ATM prompt. Refused elsewhere: `No ATM within 3 m.` |
| `/solde` | anywhere | `Cash: 500 €$ · Account: 1 200 €$` |
| `/virement <playerId> <amount>` | anywhere | Wires `amount` to a **connected** player. Fee **1 %** (at least 1 €$), taken from the sender and burned. Both players are told. |
| `/societe` | anywhere | The society balance of the caller's job (`exports.rp_jobs:getJob`, optional through `pcall`). |

From the server console every command answers `run this from the game`.

Validation is server side, always: positive whole amounts (max 10^9 per operation), enough
cash to deposit, enough account to withdraw or wire, the recipient must exist (a connected
player id, or a citizen id = durable identifier that already has an account), never yourself.
Refusals are explained in chat (`Not enough eddies in the account.`, `Unknown recipient. ...`).

## Persistence

None of its own. Every operation is a coordinator operation submitted through `rp_economy`:

| Operation | Coordinator lines (one operation each) |
|---|---|
| deposit / withdraw | `cash:<s>` → `bank:<s>` / `bank:<s>` → `cash:<s>` |
| transfer (+ fee) | `bank:<s>` → `bank:<t>` (+ `bank:<s>` → `sys:rp_bank:fee`, burned) |
| charge | `bank:<s>` → `soc:<name>` |
| societyAdd / societyRemove | `sys:<caller>:legacy` → `soc:<name>` (money created, counted against the caller's mint allowance) / the reverse |

A 1.x deposit removed the cash in `rp_economy` and credited the account in this resource, two
stores and two writes: a crash in between lost or created money. It is one operation now.

The 1.x tables (`rp_bank_accounts`, `rp_bank_transactions`, `rp_bank_societies`) are imported once
by `rp_economy`'s `economy_migrate` and then kept as a **read-only archive**; the statement still
shows the archived ledger lines (`… · archive`). Lines after the cutover are in the coordinator
journal (`op77_tx_journal`); until the coordinator offers a history read, the statement shows this
boot's operations plus the archive.

**No database, no fallback.** While the coordinator (or `rp_economy`) is unavailable every
operation is refused — `bank_not_ready` (`The bank network is unavailable right now. Nothing was
moved`), `wallet_unavailable` when `rp_economy` itself is missing — and nothing is written
anywhere else. The 1.x KVP keys (`acct:`, `soc:`) are never read at runtime: the console command
`bank_kvp_report` lists how they differ from the coordinator.

## Exports (phase 1 contract, synchronous, never yield — unchanged signatures)

```lua
exports.rp_bank:getAccount(playerId)        -- { identifier, balance, createdAt } | nil, reason
exports.rp_bank:deposit(playerId, amount)   -- newBalance | nil, reason  (cash -> account)
exports.rp_bank:withdraw(playerId, amount)  -- newBalance | nil, reason  (account -> cash)
exports.rp_bank:transfer(fromPlayerId, toIdentifier, amount[, fee])
                                            -- sender's newBalance | nil, reason; fee (optional, >= 0) is burned
exports.rp_bank:society(name)               -- { name, balance } (row created on first use) | nil, reason
exports.rp_bank:societyAdd(name, amount, reason)     -- newBalance | nil, reason
exports.rp_bank:societyRemove(name, amount, reason)  -- newBalance | nil, "insufficient_funds" | reason
exports.rp_bank:charge(playerId, amount, society, reason)
                                            -- account -> society in one move (a fine, a bill, a
                                            -- subscription); the player's newBalance | nil, reason
```

Reasons: `invalid_player_id player_not_found bank_not_ready invalid_amount amount_too_large
insufficient_funds insufficient_cash balance_limit unknown_recipient self_transfer
wallet_unavailable invalid_society invalid_reason`, plus `account_not_loaded` (the player's
wallets are still loading) and, from `societyAdd`, `mint_denied` / `mint_cap` (the calling
resource is not allowed to create that much money this hour; see rp_economy's README). Society
names are lower-cased (`[A-Za-z0-9_.-]`, 1..64). `playerId` accepts the string form host events
deliver.

What changed underneath (version 2):
- They are rp_economy's **write-behind** facade: the answer is immediate and computed on the
  cache, the operation commits in the background; a refused commit is reverted and logged by
  rp_economy (`write-behind … refused`).
- `transfer` to an identifier accepts only accounts this server has loaded (an online player, or
  one seen this boot): a synchronous call cannot ask whether an offline account exists. The ATM
  menu and `/virement` use the atomic API instead, which does check, so offline recipients work
  there.
- `society(name)` answers `bank_not_ready` the first time a society this server has not loaded
  yet is asked for (it loads in the background); the job societies of `rp_economy`'s config and
  every society of the 1.x archive are loaded at start. `societyAdd` to such a society is accepted
  (a credit cannot fail) and returns the balance known so far; `societyRemove` needs it loaded.
- `createdAt` is the time this server first served the account (1.x stored it; the coordinator
  does not).

Call them inside `pcall` from another resource (synchronous exports raise when the resource is
missing). A resource **without** a client script may declare `dependency "rp_bank"`; a resource
with one must not (this manifest is delivered to clients).

### Event

```lua
TriggerEvent("rp_bank:changed", playerId, identifier, newBalance, delta, kind)
-- playerId is nil for an offline recipient and for societies (identifier "society:<name>")
```

Re-published from `rp_economy:walletChanged` (one tick later than 1.x). `kind` is one of
`deposit withdraw charge transfer_out transfer_in society_add society_remove`, or `sync` when the
cache caught up with a change made elsewhere. Any other `rp_economy` reason passes through
unchanged as the `kind` (cut to 32 characters), for example `reverted:<reason>` when a change
is rolled back.

## Staging: poses, props and durations

Every action below plays a pose from the server's `open77_animations` catalogue
(`Open77.animations.play`, permission `players.animations.control`), shows a curated prop
attached to the body (`Open77.props.create` + `attach`, permission `world.props`) where one
makes sense, and takes its time behind the UI-kit bar (X cancels; the bar keeps the player
still on the client, the server never freezes anyone). Other players see all of it: poses
and props are server-driven. Everything is in `Config.Stage` (`config.lua`) and follows rp_nomade's carry-pose
pattern: `pose.profiles` is a list tried in order through `Open77.animations.get` -- the
best future name first (the 76-profile catalogue of the pending base PR), then what today's
18-profile eval catalogue has -- and `prop.models` a list of aliases tried in order. A
refusal (unknown profile, `player_in_vehicle`, `animation_owned`, an attach the client
cannot bind) is logged once and never blocks the action. Hand-slot offsets are not measured
on 2.31: if a prop sits wrong, move one axis of `offset` / `rotation` at a time.

| Action | Pose today (future name) | Prop | Duration |
|---|---|---|---|
| the ATM menu (E, `/bank`) | `phone` two-hand tap, looped while the menu is open (`tablet` once it exists) | the profile's holo | until the menu closes |
| deposit / withdraw / wire | a 2 s uncancellable bar (`process`), the typing pose stays | -- | 2 s each |

Log lines (grep `stage`, `gesture`, `hold`):

```text
[rp_bank] player 3 hold atm: pose=phone/stand__2h_phone__03__tap_phone__01 prop=none
[rp_bank] player 3 stage process: pose=none prop=none place=none 2000 ms -> ok
```

`-> ok` means the bar ran to the end; `-> cancelled` the player pressed X;
`-> failed:<reason>` the bar never showed (a plain wait kept the beat). A refused pose reads
`stage <key>: pose <profile> refused for player N: <reason> (the action runs without it)`,
an unknown list `stage <key>: no known profile among [...]`, a refused prop `stage
<key>.prop: attach of <alias> to player N refused: <reason> (no prop shown)`.

## Log (grep-able)

```
[rp_bank] started, 5 ATMs configured (accounts and societies held by open77_transactions through rp_economy)
[rp_bank] player 3 loaded <identifier> account=700
[rp_bank] player 3 deposit 500 op=rp_bank.deposit.<boot>.1.<identifier>          (ATM, atomic)
[rp_bank] player 3 deposit 500 account=1200 op=rp.wb.<boot>.7                    (export, write-behind)
[rp_bank] player 3 transfer 100 fee 1 to <identifier> op=rp_bank.transfer.<boot>.2.<identifier>
[rp_bank] society ncpd +250 fine:3 balance=250 op=rp.wb.<boot>.9
```

## ATM positions

`config.lua` is a `shared_script`: the client places pins/rings/prompts from `Config.Atms`, the
server checks distance against the same list and spawns one **terminal prop** per ATM
(`Open77.props.create`, `Config.AtmProp.model` = the curated prop alias `street.parking_meter`
(see `prop.catalog`; a raw `.mesh` path renders as a white slab), 1 m off the ring, removed on
stop; a refusal only logs). Five real Night City points,
measured — three around the freeroam spawn (Kabuki Market Centre
`-1191.30, 2006.88, 7.82`), two inside landmarks:

| ATM | Ring (x, y, z) | Terminal | Where |
|---|---|---|---|
| `atm_kabuki`, `ATM - Kabuki Market` | -1188.30, 2006.88, 7.82 | -1187.30, 2007.40 | Market Centre, 3 m east of the spawn |
| `atm_southgate`, `ATM - Kabuki South Gate` | -1218.13, 1950.17, 7.98 | -1219.10, 1949.60 | the market's street side, 63 m south-west (pedestrian alley) |
| `atm_noodle`, `ATM - Noodle Row` | -1178.66, 2028.45, 7.95 | -1177.70, 2029.10 | 25 m north-east of the spawn |
| `atm_afterlife`, `ATM - The Afterlife` | -1447.00, 1022.00, 16.60 | -1446.20, 1022.80 | the bar floor by the entrance stairs, 1.0 km south-west |
| `atm_viktor`, `ATM - Vik's Clinic` | -1545.00, 1233.00, 11.60 | -1544.20, 1233.80 | just inside the clinic entrance, 855 m south-west |

The ring `z` is the walked / measured floor (+0.1 m for the two interiors); if a ring is
invisible, stand on the spot, run `/pos`, and paste the ground height — a ring drawn inside the
floor is invisible even though everything reports success. The server tolerates 4 m of height
error (`Config.AtmHeightTolerance`). Up to 8 ATMs get a floating label (UI kit cap). The
terminal's `yaw` turns the prop towards its ring; the prop's forward axis was not measured, so
if a machine shows its back, add 180 to `prop.yaw`.

Manifest permissions: `database.access` (reads the 1.x ledger archive), `network.events` (`RegisterNetEvent`,
`TriggerServerEvent`), `ui.vanilla.map` (`Open77.blips.create`), `world.props` (the terminals),
`players.animations.control` (`Open77.animations.play` / `stop`, the typing pose at the ATM).
Dependencies: `open77_uikit`, `open77_worldui`. `rp_economy` (2.0.0, which needs the
`open77_transactions` coordinator) and `rp_jobs` are reached through `pcall` (server-only
resources).

## Test in 2 minutes

1. Load `open77_transactions`, then `rp_economy` and `rp_bank`, start the server. Log:
   `[rp_economy] coordinator ready (store=sql)`, `[rp_bank] started, 5 ATMs configured …`, five
   `terminal prop <id> for atm_... at ...` lines (or `terminal prop for atm_... not spawned
   (<reason>)`: the ring still works). With 1.x data, run `economy_migrate` first (rp_economy's
   README).
2. Connect. Chat: `NC Bank: Account balance: 0 €$.` (or the imported 1.x balance). Log:
   `[rp_bank] player <id> loaded <identifier> account=0`.
3. `/solde` → `Cash: 500 €$ · Account: 0 €$`.
4. Open the map: five `ATM - ...` pins (three on Kabuki Market, one on the Afterlife, one on
   Vik's). Walk 3 m east from the spawn to the `ATM - Kabuki Market` ring (a data terminal
   stands next to it), look at the ring, press **E** (or type `/bank` within 3 m). The
   `Night City Bank` menu opens.
5. **Deposit eddies** → `300` → chat `Deposited 300 €$. Account: 300 €$.`; `/money` from
   `rp_economy` now says 200. Log: `[rp_bank] player <id> deposit 300 op=…`.
6. **Withdraw eddies** → `1000` → `Not enough eddies in the account.`; `50` → `Withdrew 50 €$.`
7. **Statement** → two rows, newest first, with the balance after each; **Back**.
8. Walk 10 m away, `/bank` → `No ATM within 3 m. Find one on the map.` (Noodle Row's ATM is
   25 m north-east, the South Gate one 63 m south-west; the Afterlife and Vik's are a drive.)
9. Second client (`id2`): `/virement id2 100` → sender `Wired 100 €$ to <name> (fee 1 €$).
   Account: 149 €$.`, recipient `<name> wired you 100 €$. Check /solde.`
   `/virement <self> 10` → refused; `/virement id2 999999` → `Not enough eddies in the account.`
10. At the ATM, **Wire to a citizen** with recipient `id2` (or their citizen id) → no fee.
11. `/societe` with a job from `rp_jobs` → `Society police: 0 €$.`; without → `You have no job, choom.`
12. Reconnect: the balance is back (`[rp_bank] player <id> loaded ... account=...`).
    Stop the database (or `open77_transactions`) and try a deposit: `The bank network is
    unavailable right now. Nothing was moved`; restart it: the balances are unchanged.
13. From another resource: `print(exports.rp_bank:getAccount(id).balance)`,
    `exports.rp_bank:societyAdd("police", 250, "fine:3")`.
