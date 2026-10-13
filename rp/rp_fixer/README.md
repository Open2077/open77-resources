# rp_fixer

Adds the fixers' contract board: fixer NPCs and fixers on duty post deliveries, retrievals, job orders and cyberpsycho bounties with an escrowed reward, runners take them at the Afterlife, Wakako's or Regina's corner, and get paid in one operation and build a reputation that unlocks better contracts.

- **Docs:** [Build a job: prompts, animations, items and pay](https://open2077.net/docs/world-interaction), [Durable transactions](https://open2077.net/docs/transactions), [Server-owned NPCs](https://open2077.net/docs/npcs), [UI kit](https://open2077.net/docs/ui-kit)
- **Starts:** with `ensure rp_fixer` (it declares `auto_start false`)
- **Needs:** `open77_transactions`, `open77_actions`, `open77_uikit`, `open77_notifications` (the toasts), `rp_economy`, `rp_bank` (the `fixer` society the cut lands in pays rp_jobs' payroll through it), `rp_jobs`, `rp_inventory`, a SQL database; `rp_identity` for character names (optional)
- **Runs on:** server and client (the client only draws map pins)

The board is the hub that ties the RP jobs together: a job order is satisfied by the
`rp:job:completed` events the other jobs fire, so a fixer can ask for "refine 10 CHOOH2" or
"install an implant" and the runner gets paid when the CHOOH2 or ripperdoc job reports it. Every
contract fires `rp:job:completed` itself when it is paid (`job = "fixer"`, `kind =
"contract_completed"`), so other resources can build on it the same way.

## How to play

### The fixer points

Three real Night City places carry a board, each with its fixer's contact standing next to it and
a pin on the map:

| Fixer point | Fixer | Where |
|---|---|---|
| The Afterlife | Rogue | the booth at the back of the club, Little China, Watson |
| Wakako's | Wakako Okada | Japantown, Westbrook |
| Regina's corner | Regina Jones | Kabuki market, Watson |

At a fixer point a prompt reads **E Contract board** (and **F Hand over the goods**). Every board
shows every contract of the city, with what it pays the runner, the fixer who posted it, the time
left and the reputation it needs. Contracts above your reputation are greyed out. `/contracts`
opens the board too when you stand at a fixer point, and lists the board in chat anywhere else
(with the distance to the nearest fixer).

### Runners: take a contract and do it

Pick a row, read the brief, press **Take the contract**. You hold at most two contracts at once.
`/contract` lists yours with their progress and the time left; the map pins and the GPS show
where to go next.

| Kind | What you do | When you are paid |
|---|---|---|
| Delivery | A sealed crate appears at the pickup point (Vik's clinic, Noodle Row, the Japantown ripperdoc). Walk to it, **E Pick up**. Carry it on foot to the drop (a fixer point) and press **E Deliver the crate** there. Only you can lift it. A car, a drawn weapon or a fall drops it where you stand: pick it up again. | the crate touches the drop |
| Retrieval | Bring the named goods (3 data chips, 4 components, 2 CHOOH2 canisters from the Petrochem refinery, a boxed set of Gorilla Arms from the ripperdocs' stock) to the fixer point named in the contract and press **F Hand over the goods**. Without them nothing starts and you are told what is missing. | the hand-over bar ends |
| Job order | Do the other job: refine CHOOH2 at the plant, breach a terminal, install an implant as a ripperdoc, assemble weapons at a techie bench, stabilise or revive downed patients as Trauma Team, bring a nomad run home (every crate of it). Each step that job reports for you counts once; `/contract` shows `4 / 10`. | the count is reached |
| Bounty | A cyberpsycho waits at the sighting (Kabuki north-west of the market, Northside industrial, the Rancho Coronado junkyard). Kill it. | the kill is credited to you |

Paid means: the contract's net reward lands in your cash in one operation, the fixers' cut goes to
the `fixer` society, your reputation rises (1 to 4 points by contract) and the poster is told.
`/contract drop <n>` walks away from a contract: it goes back on the board and you lose 1 point.
A taken contract that runs out costs 1 point too. Reputation tiers: `street` 0, `known` 3,
`trusted` 8, `legend` 20.

**Bounties, open or claimed.** An *open* bounty is never taken: its cyberpsycho is out as soon as
the contract is posted and whoever kills it is paid. A *claimed* bounty spawns its target when a
runner takes it, and only that runner is paid. If someone else kills a claimed target, the
contract says what happens: `refund` (the contract is void, the poster gets the reward back,
nobody is paid) or `respawn` (another one shows up a minute later). The kill is credited from the
platform's death report (`player:<id>`), or to the last player who hit it within 30 seconds.

### Fixers: post a contract

A player with the `fixer` job, on duty (rp_jobs), sees **Post a contract** on any board. Pick a
type, set the reward with the slider, the time to expiry and an optional brief of your own (and,
for a bounty, who gets paid). The reward leaves your wallet at once (cash, then bank) and waits in
escrow: it can always be paid, and it comes back in full if the contract runs out or if you cancel
it while nobody holds it (open the row, **Cancel, refund me**, or `/contract cancel <n>`). The
fixers' cut (10 % of a player's contract) goes to the `fixer` society on completion.

For a retrieval, the goods go into your drop box: **Collect your drop box** appears on the board
when it holds something, and empties it into your pockets in one operation.

The fixer NPCs keep their own boards stocked: two of their contracts at all times, posted again a
few minutes after one closes. Their rewards are created out of `sys:rp_fixer:board` (rp_economy's
mint allowlist) and their cut is 15 %.

### What everybody else sees

The contacts at the boards, the fixer pins on the map, the runner carrying a crate across Kabuki,
the cyberpsycho fighting whoever comes near. A new contract is announced in chat to the players
who could take it.

## Setup

1. A SQL database (the coordinator needs one anyway). rp_fixer creates `rp_fixer_contracts`,
   `rp_fixer_rep_log`, and keeps rp_fixer 1.0's `rp_fixer_reputation` (players keep their score)
   and `rp_fixer_gigs` (one history row per settled contract).
2. In `resources.load`, after the libraries and the RP pack resources it uses:

   ```text
   open77_transactions, open77_actions, open77_uikit, open77_notifications,
   rp_jobs, rp_inventory, rp_economy, rp_bank, rp_fixer
   ```

3. Once, in the server console (merge the `writers` entry into the server's existing list):

   ```text
   tunable.set open77_transactions writers rp_fixer:char+stash, rp_economy:cash+bank+soc, rp_inventory
   tunable.set open77_transactions mint1 rp_economy sys:* money 2000000
   ensure rp_fixer
   ```

   - `rp_fixer:char+stash` lets it take the goods of a retrieval out of the runner's pockets and
     put them in a poster's drop box (`stash:fxbox.<subject>`), and empty that box into the
     poster's pockets. Goods handed to a fixer NPC are burned into `sys:fixer.retrieval`: no mint
     rule is needed for goods.
   - Money moves through rp_economy only. The `mint1` rule is rp_economy's usual ceiling; the
     NPC fixers' rewards count against rp_economy's own allowlist (`rp_fixer = 200000` an hour in
     `rp_economy/server/config.lua`), and come back to it when an NPC contract is refunded.
   - rp_jobs already knows the `fixer` job (`setjob <id> fixer 0`, then `/service`).

Expected start lines:

```text
[rp_fixer] loaded 0 live contracts (), next number 1
[rp_fixer] ready: 3 fixer points, 16 templates, escrow society fixer_escrow, cut society fixer
[rp_fixer] contract srv.fx1 open: delivery afterlife_meds_run reward=700 net=595 cut=105 by npc Rogue at afterlife expires in 1 h 59 min
[rp_fixer] contract srv.fx5 cyberpsycho 4100 at kabuki_alley
```

Console commands (restricted: console or ACL `command.fixer.*`):

| Command | What it does |
|---|---|
| `fixer.status` | counts by state, totals, and the escrow audit (what the contracts hold against the escrow society's balance) |
| `fixer.list` | every contract in memory: number, id, state, template, poster, runner, time left, crate and NPC |
| `fixer.post <template> [hub] [reward]` | a fixer NPC posts now |
| `fixer.expire <n>` | contract `#n` runs out now (the next sweep refunds it) |
| `fixer.job <playerId> <job> <kind> [count] [ref]` | for testing only: fires the `rp:job:completed` event another job would fire, with `data = { count }` (so it never satisfies a `match` field, and a `countField` order counts it as 1) |
| `fixer.kill <n> <playerId>` | for testing only: the cyberpsycho of `#n` dies credited to that player (the same path as a real kill) |
| `fixer.rep <playerId>` | a connected player's reputation |
| `fixer.setrep <playerId> <score>` | sets a connected player's reputation (one logged change) |

Player commands: `/contracts`, `/contract`, `/contract take <n>`, `/contract drop <n>`,
`/contract cancel <n>`, `/contract box`, `/contract post <template> <reward> [hours]` (take, box and
post at a fixer point).

## Config

Everything is in `server/config.lua`.

| Key | Default | Meaning |
|---|---|---|
| `escrowSociety` | `fixer_escrow` | the society account every reward waits in |
| `cutSociety`, `cutRate` | `fixer`, NPC 0.15 / player 0.10 | who receives the fixers' cut, and how much of the reward it is |
| `escrowInstrument` | `cash_then_bank` | how a player fixer funds a contract |
| `npcFunding` | `board` | NPC rewards come from `sys:rp_fixer:board` |
| `tiers`, `reputation` | street 0 / known 3 / trusted 8 / legend 20; abandon -1, expire -1, floor 0 | reputation rules; each template has its `minRep` and `repGain` |
| `maxLive`, `maxPerPoster`, `maxPerRunner` | 48, 4, 2 | board limits |
| `boardReach` | 4 m | how close `/contracts` and `/contract take` need you to a fixer point |
| `sweepMs`, `retryMs`, `postingSettleMs` | 5 s, 15 s, 30 s | expiry, payment retries, escrow settlement |
| `npcBoard` | enabled, refill every 5 min | NPC fixers keep `keepOpen` of their `offers` on the board |
| `hubs` | Afterlife, Wakako's, Regina's corner | position, contact NPC, `offers`, `keepOpen` |
| `points`, `drops` | 3 pickup points, no extra drop | delivery pickups; every fixer point is a drop |
| `sightings` | 3 | where a bounty's cyberpsycho spawns |
| `psycho` | Maelstrom combat record, 400 health | record, health, leash, engage distance, credit window, respawn, body removal, the clear radius (never spawned within 4 m of a player) |
| `contactNpc` | the passive alias `civilian_female_relaxed_01` | the NPC standing at each board; puppet records of Rogue, Wakako and Regina are listed to try |
| `templates`, `templateOrder` | 16 | the contract types (fields documented in the file) |

### Places to walk

Every point below is marked `measured = false` unless the table says walked: stand on it, read `/pos`, correct it.

| Key | Position | Landmark | Source |
|---|---|---|---|
| `afterlife` (fixer point) | -1436.8, 977.0, 17.0 | Rogue's booth, the Afterlife | rp_fixer 1.0 office |
| `wakako` (fixer point) | -652.71, 925.36, 9.39 | Japantown street food, Wakako's side | 1.5 m in front of catalogue spot 15042 |
| `regina` (fixer point) | -1232.77, 1983.04, 7.97 | Kabuki market, west side | 1.5 m in front of catalogue spot 29556 |
| `kabuki_noodle_row` (pickup) | -1178.66, 2028.45, 7.95 | Kabuki market, Noodle Row | rp_fixer 1.0 |
| `vik_clinic` (pickup) | -1548.0, 1230.0, 11.6 | Viktor's clinic door, Little China | rp_zones `viktor_clinic` |
| `japantown_ripperdoc` (pickup) | -713.95, 870.25, 11.99 | Japantown ripperdoc | 1.5 m in front of catalogue spot 37085 |
| `kabuki_alley` (sighting) | -1265.0, 2062.91, 11.98 | Kabuki, the burrito-machine alcove north-west of the market | walked in game (`measured = true`) |
| `northside` (sighting) | -1914.454, 2739.485, 10.899 | Northside industrial district | catalogue spot 8055 |
| `junkyard` (sighting) | 1374.5, -1681.0, 49.3 | Rancho Coronado junkyard lane | rp_salvage's yard |

The contacts stand about 1.6 m beside each board (`hubs.<key>.contact`), on the same floor height.

### For other resources

```lua
-- Another job reports a committed step a contract may ask for (server side):
TriggerEvent("rp:job:completed", { job = "chooh2", kind = "refine", playerId = 3, ref = "<the step's opId>",
    data = { canisters = 4 } })
-- A paid contract (fired by rp_fixer):
-- { job = "fixer", kind = "contract_completed", playerId, ref = "fixer.pay:<id>",
--   data = { contract, seq, contractKind, template, hub, reward, net, cut, poster } }
AddEventHandler("rp_fixer:contract", function(id, state, playerId, summary) end)   -- open, taken, abandoned, completed, expired, cancelled, spoiled
AddEventHandler("rp_fixer:gig", function(seq, phase, playerId) end)               -- rp_fixer 1.0 phases: published, accepted, abandoned, timeout, success

exports.rp_fixer:reputation(playerId)        -- integer score (synchronous)
exports.rp_fixer:contract(idOrNumber)        -- summary or nil (synchronous)
exports.rp_fixer:heldBy(playerId)            -- the player's contracts (synchronous)
-- An NPC fixer posts on your behalf (asynchronous):
Open77.exports.call("rp_fixer", "postContract", { template = "regina_psycho_kabuki", hub = "regina" }):await()
```

A job order counts an event when its `job` and `kind` match the template (`kinds` may list
several, `"*"` is any), every `match` field equals the event's `data` field, and its `ref` was not
counted before for that contract. `countField` names a `data` field holding a count (CHOOH2:
`canisters`); otherwise each event counts 1. Only the runner's own events count, and only while
the contract is taken. The shipped job orders read:

| Template | `job` | `kind` | Counted |
|---|---|---|---|
| `wakako_chooh2` | `chooh2` | `refine` | `data.canisters`, up to 10 |
| `afterlife_breach` | `netrunner` | `breach_success` | 1 |
| `afterlife_implant` | `ripperdoc` | `operation` with `data.action = "install"` | 1 |
| `wakako_hardware` | `techie` | `assemble` | 2 |
| `regina_patch_up` | `trauma` | `stabilise` (E *Stabilise the patient* on a downed body) or `revive` (ALT+click or `/reanimer`) | 2 |
| `afterlife_smuggle` | `nomad` | `deliver` with `data.complete = true` (the crate that empties the run) | 1 |

`regina_chooh2` asks for `chooh2_canister`, rp_chooh2's refinery output (not rp_inventory's
`chooh2` fuel can). Patch up on a standing citizen fires no event, so it never counts.

## Limits

- A delivery crate is carried on foot. Pickups and drops are a few hundred metres apart; no truck,
  no trunk.
- The cyberpsycho record is the Maelstrom combat record players already fight; the real
  cyberpsycho records of the catalogue are listed in the config to try. A target nobody can kill
  (a record that does not spawn on clients) simply expires and refunds.
- A kill is credited by the platform's hit pricing (`hitPricing = "platform"`). On a host where it
  is refused, the target still spawns, but no kill is credited and the bounty expires.
- `rp:job:completed` is a server event: any server resource can fire it, clients cannot. rp_fixer
  trusts the jobs that run next to it and counts each `ref` once.
- `rp:job:completed` for `contract_completed` is fired once, after the payout is saved; a crash in
  that instant loses the event, never the payment.
- Contracts live in SQL. Without a database the board stays closed (`no database` in the log).
- A retrieval of another job's item (the Gorilla Arms box is rp_ripperdoc's, the CHOOH2 canister
  rp_chooh2's) is posted only while that item is defined: without that job the NPC fixer skips it
  and posts its other offers, and a player fixer's post is refused.
- Job orders count the events the other jobs fire with the names in the table above; a job that
  renames a `kind` or a `data` field needs the template changed with it.
- The NPC fixers' rewards are new money (rp_economy's allowlist, 200 000 an hour for rp_fixer). A
  refund gives the allowance back.
- 48 live contracts on the server, 2 per runner, 4 per player fixer; the board shows 56 rows.
- Other resources' crates (a salvage crate) also see the **Deliver the crate** prompt at a fixer
  point while carried; putting one down there is their own resource's business.
