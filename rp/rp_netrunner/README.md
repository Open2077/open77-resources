# rp_netrunner

Adds the netrunner job: fixers post breach contracts on a board, a netrunner takes one, jacks into a real Night City terminal for a timed breach that NCPD can trace, and is paid when the data shard reaches the fixer; plus the Ping, Short Circuit, Overheat and NCPD radio jammer quickhacks.

- **Docs:** [Build a job: prompts, animations, items and pay](https://open2077.net/docs/world-interaction), [Actions and carrying](https://open2077.net/docs/actions), [Durable transactions](https://open2077.net/docs/transactions), [Player interactions](https://open2077.net/docs/player-interactions), [Hacking and counterplay](https://open2077.net/docs/hacking)
- **Starts:** with `ensure rp_netrunner` (it declares `auto_start false`)
- **Needs:** `open77_transactions`, `open77_actions`, `open77_uikit`, `open77_contextmenu`, `open77_player_interactions`, `open77_hacking`, `rp_jobs`, `rp_inventory`, `rp_economy`, `rp_ncpd`; `open77_pedestrians` keeps the crowd off the terminals (optional)
- **Runs on:** server and client

Every step that moves value is one `open77_transactions` operation: the contract is an item on a
board stash, the breach burns a data chip and mints the shard in the same operation, and the
delivery is one `rp_economy` sale. Nothing durable lives in this resource's memory: a restart
rebuilds the board from the coordinator, and a shard in a netrunner's pockets survives it.

## How to play

### The netrunner

1. **Clock in.** Job `netrunner` (rp_jobs), on duty (`/service`).
2. **Take a contract.** In the Afterlife's back room, the fixer drop shows **E Talk to the fixer**.
   The contract board opens: one row per open contract with its code, the terminal and where it
   is, the tier, the pay, the time left and the fixer who posted it. Pick one and confirm. From
   anywhere, `/netrun contracts` lists the board in chat and `/netrun take <code>` takes one. You
   hold one contract at a time.
3. **Bring data chips.** Every completed breach attempt burns one `chip` (success or failure). No
   chip: the breach is refused before the bar starts and nothing is used.
4. **Breach.** `/netrun` says where your terminal is. At it, **E Breach the terminal**: you sit at
   the desk and type (office terminals), stand over a tablet (the netrunner den) or sit on the
   ground with a laptop (the junction box), while a bar runs (12, 18 or 25 seconds by tier).
   Everyone nearby sees you working. **X**, walking away, dying, a car, aiming or clocking off ends
   it: nothing is used. `/breach` at the terminal does the same as **E**.
5. **The odds.** The server rolls the outcome: the tier's base chance (75, 55, 40 %), plus 8 % per
   rp_jobs grade, minus 5 % per attempt already made on that contract, between 10 and 95 %.
6. **Success.** The data shard (`nr_data_shard`, contraband) lands in your pockets.
7. **Failure is a trace.** NCPD officers on duty get a dispatch line and a map pin at the terminal,
   your NCPD record gets an entry, and your game raises its NCPD heat to level 1 for two minutes.
   The terminal's ICE stays on alert for a minute (a new attempt is refused). The contract stays
   yours; after the third failed attempt it burns and leaves the board.
8. **Deliver.** For a contract the NPC fixer posted, go back to the fixer drop: **E** now hands the
   shard over (a short give gesture and a bar). You are paid at once: the reward minus the fixer's
   15 % cut, in cash. For a contract a player fixer posted, hand it to them in person:
   `/netrun deliver <their id>` or ALT+click on them, **Hand over the data shard**. They accept the
   hand-over and you are paid. If that fixer is not in the city, the drop at the fixer point pays
   instead and their cut still reaches them.
9. **Deadline.** A contract not delivered in time expires. A shard of an expired contract goes
   stale and leaves your pockets. `/netrun abandon` gives back a contract you have not breached.

### The fixer

- Clock in as `fixer`. At the fixer drop, **E** shows the board with **Post a contract**: pick a
  terminal, then a reward inside its tier's range and a deadline. Every netrunner on duty hears
  about it. `/netrun sites` lists the terminals and their ranges, `/netrun post <site> [reward]
  [minutes]` posts from chat, `/netrun cancel <code>` pulls an open contract.
- You are told when your contract is taken, breached, delivered, failed or expired. The client
  pays the reward; your cut (15 %) lands in your cash when the shard reaches you.
- You may have three open contracts at once.

### The NPC fixer

The Afterlife's fixer keeps three contracts open on the board, one more every minute while fewer
are open, each on a terminal nobody holds a contract for. Its cut goes to the `fixer` society.

### Observers and NCPD

Other players see the netrunner's pose at the terminal, the tablet or the laptop, and the hand-over
gesture at the drop. Officers see the trace in dispatch, with the terminal's position on the map,
and `/casier` shows the record entry.

### Quickhacks

| Command | What it does |
|---|---|
| `/netrun` | Status: job and duty, your contract and where to go, the deck, quickhacks and chips in your pockets, cooldowns, hacks on you. |
| `/netrun board` | Opens the contract board menu, within 15 m of a fixer drop (what **E** *Talk to the fixer* opens). |
| `/netrun help` | Every `/netrun` command and quickhack in one chat line. |
| `/netrun deck <short_circuit\|overheat>` | Loads that grade into your operating system (the cyberdeck the uploads need). |
| `/ping <id>` | Burns a `qh_ping`: a pin follows that player on your map for 60 s (50 m). |
| `/court_circuit <id>` | Burns a `qh_short_circuit` when the platform accepts the upload: Short Circuit, 25 m, line of sight. |
| `/surchauffe <id>` | Burns a `qh_overheat` when the platform accepts the upload: Overheat with its burn. |
| `/brouiller` | Burns a `qh_jammer`: NCPD radio static for 60 s (`rp_netrunner:jammed`). |

ALT+click on a player offers **Ping**, **Short Circuit**, **Overheat** and **Hand over the data
shard** while you are an on-duty netrunner. A quickhack leaves a trace one time in two (dispatch
and record, no heat). Each kind has a 30 s cooldown.

## Setup

1. `resources.load`, in this order (the two libraries do not start on their own):
   `open77_transactions`, `open77_props`, `open77_animations`, `open77_interactions`,
   `open77_uikit`, `open77_actions`, `open77_player_interactions`, `open77_contextmenu`,
   `open77_hacking`, `rp_jobs`, `rp_inventory`, `rp_economy`, `rp_ncpd`, `rp_netrunner`.
2. Convar `rp_inventory_backend transactions` (chips, quickhacks and shards are coordinator items).
3. The coordinator's tunables, once, in the server console. `writers` lists every job of the
   server; add `rp_netrunner:char+stash/contracts` to yours. The mint rule lets rp_netrunner create
   contract records and shards (300 an hour). `tunable.set` replaces the whole value of a slot:
   put the rule in a `mintN` (1 to 6) no other job uses, as `mint2` below, or append it with `;` to
   the slot that already holds your rules. The money the client pays is rp_economy's own rule
   (`rp_economy sys:* money <cap>`), which the server sets once for every job:

   ```text
   tunable.set open77_transactions writers rp_netrunner:char+stash/contracts, rp_economy:cash+bank+soc, rp_inventory
   tunable.set open77_transactions mint2 rp_netrunner sys:netrunner * 300
   ensure open77_transactions
   ensure open77_actions
   ensure rp_netrunner
   ```

4. rp_economy creates the client's money on rp_netrunner's behalf: `rp_netrunner` is on its mint
   allowlist (`EconomyConfig.mint.callers`, 30 000 an hour). Raise it for a busy server.
5. rp_jobs knows the jobs `netrunner` and `fixer`. rp_inventory lets `rp_economy` take a seller's
   pockets for one sale (`pocketGrantees`, the default).

Start lines:

```text
[rp_netrunner] deck rp_netrunner.deck v1 defined: short_circuit, overheat
[rp_netrunner] coordinator ready (store=sql)
[rp_netrunner] items defined through rp_inventory: 6
[rp_netrunner] ready: 6 breach sites, 1 fixer drop(s), 7 targets, 0 contract(s) on the board (job netrunner)
```

Console commands (restricted: the console, or the ACL `command.netrun.*`), with explicit player
ids, each on the same server path as the prompts:

| Command | Does |
|---|---|
| `netrun.status` | counters, every contract on the board |
| `netrun.setup <id> [netrunner\|fixer] [grade]` | the job, the grade (0 to 3) and duty |
| `netrun.give <id> <item> [count]` | items into a player's pockets (`chip`, `qh_*`) |
| `netrun.post <site> [reward] [minutes] [fixer id]` | posts a contract as that player fixer, or without a fixer id as the board itself: the row then reads `posted by console` |
| `netrun.take <id> <code>` | the board's take |
| `netrun.breach <id> [site]` | the terminal's prompt (the player stands there) |
| `netrun.talk <id>` | the fixer drop's prompt (board, or the delivery) |
| `netrun.deliver <id> [fixer id]` | the drop, or the hand-over to that fixer |
| `netrun.expire <code>` | expires a contract now |
| `netrun.state <id>` | contract, chips, shards, cash, grade, the odds right now, the terminal's position |

## Config

`server/config.lua` (the contract job) and `shared/config.lua` (the quickhacks, also read by the
client).

| Key | Default | Meaning |
|---|---|---|
| `tiers[1..3]` | 12 / 18 / 25 s, 75 / 55 / 40 %, 300-700 / 800-1600 / 1600-3000 eddies, 15-60 / 20-90 / 30-120 min | breach duration, base chance, reward range and deadline range of each tier |
| `difficulty` | +8 % per grade, -5 % per attempt, 10 to 95 % | how grade and attempts move the odds |
| `poses` | `desk`, `tablet`, `laptop` | the open77_actions animation of each kind of terminal |
| `sites` | six terminals (below) | position, yaw, tier, pose, whether the NPC fixer posts on it |
| `fixers` | the Afterlife back room | the fixer drop: board and shard drop |
| `npcBoard` | on, 3 open, one a minute | the NPC fixer's postings |
| `cut` | 15 %, NPC cut to the `fixer` society | the fixer's share of every reward |
| `contracts` | 24 on the board, 3 open per player fixer, one live contract per terminal | limits |
| `failure` | `retry`, 3 attempts, 60 s alert | `retry` keeps the contract, `reopen` puts it back on the board, `fail` burns it |
| `trace` | dispatch, record, heat level 1 for 120 s | what a failed breach leaves (`wantedLevel = 0` turns the heat off; `revealName` names the runner in dispatch) |
| `breach` | `chip` x1 | the kit an attempt burns (`item = nil` for none) |
| `deliver` | 2.5 s, drop when the fixer is away, hand-over 3 m | the delivery |
| `cooldownMs`, `traceChance`, `hacks`, `ping`, `jam`, `deck` | 30 s, 50 %, ... | the quickhacks (`shared/config.lua`) |

The terminals. A terminal a breach ran on in game is `measured = true` (walked); the others are
`measured = false`: stand on it, read `/pos`, correct it.

| Site | Tier | Pose | Position, yaw | Landmark | Source | In game |
|---|---|---|---|---|---|---|
| `watson_junction` | 1 | laptop | -1434.631, 989.401, 23.260, -56 | junction box in the alley over the Afterlife, Watson | pedestrian spot row 3217 (a kneeling tablet worker) | walked |
| `den_node` | 2 | tablet | -1907.820, -1927.096, 48.903, -24 | netrunner den in a market hall, 930 m south of NCPD HQ | spot row 2869, 4.8 m from two netrunner chairs (furniture 16528104635163718811, 16528105734675347022) | not yet |
| `corp_lobby` | 2 | desk | -1450.216, -1038.966, 9.281, -87.24 | corporate lobby terminal, City Center, 310 m east of NCPD HQ | desk furniture 4013872865819777899, spot row 8594 | walked |
| `club_office` | 2 | desk | -2440.810, 51.412, 4.160, 0 | club back-office terminal, 1.4 km south-west of the Afterlife | desk furniture 11181519055687801554, spot row 25016 | walked |
| `plaza_desk` | 3 | desk | -2364.606, -927.932, 12.266, 96 | plaza security desk, 610 m west of NCPD HQ | desk furniture 4080162105142424950, spot row 8727 | not yet |
| `office_workstation` | 3 | desk | -2413.342, 400.497, 11.827, 2 | corporate office workstation, 1.1 km west of the Afterlife | desk furniture 14274856704730037017, spot row 31673 | not yet |
| fixer drop `afterlife` | | | -1419.9, 989.4, 16.6, 0 | the Afterlife back room | rp_netrunner 1.x access point, 21 m from rp_fixer's booth | used for deliveries, still `measured = false` |

The desks are vanilla office workstations (an NPC types there in the base game; the pose is the
same workspot). Each terminal keeps the server crowd off its point while it exists (`keepCrowdOff`,
through open77_pedestrians; `keepCrowdOff = false` on a site turns it off), so an office worker
does not sit at a desk a netrunner needs.

### For other resources

```lua
-- Synchronous reads (never yield):
exports.rp_netrunner:contracts({ state = "open" })   -- summaries: id, code, state, site, siteLabel, area,
                                                     -- position, tier, reward, cut, net, poster, fixerName,
                                                     -- deadline, secondsLeft, takerName, attempts, traces
exports.rp_netrunner:contract("K7Q2")                 -- one summary by code or id
exports.rp_netrunner:sites()                          -- key, label, area, tier, reward and minutes ranges, busy
exports.rp_netrunner:activeContract(playerId)         -- the contract a netrunner holds
exports.rp_netrunner:isJamming()

-- Writes (they yield): post as the NPC board, or as a player fixer on duty (fixer = playerId)
Open77.exports.call("rp_netrunner", "post", { site = "corp_lobby", reward = 1200, minutes = 45, fixer = 3 }):await()
Open77.exports.call("rp_netrunner", "cancel", "K7Q2", 3):await()   -- an open contract, its poster only

-- Events (host-wide):
AddEventHandler("rp:job:completed", function(e) end)
-- { job = "netrunner", kind = "breach_success" | "breach_failed" | "deliver", playerId, ref = <operation id>,
--   data = { contract, code, site, tier, reward, cut, poster, fixer, point,
--            success, chance, grade, attempt, traced, outcome (breaches), net, via (delivery) } }
AddEventHandler("rp_netrunner:contract", function(phase, summary) end)
-- phase: posted, taken, abandoned, breached, attempt_failed, failed, delivered, expired, cancelled
AddEventHandler("rp_netrunner:traced", function(e) end)    -- { playerId, site, label, position, contract, ref, wantedLevel }
AddEventHandler("rp_netrunner:jammed", function(active) end)
```

A trace also raises `rp_ncpd:alert("netrunner", position, text, 0)` and
`exports.rp_ncpd:addRecord(playerId, "netrunner", text, 0)`.

## Limits

- One contract per netrunner, one live contract per terminal, three open contracts per player
  fixer, 24 on the board.
- The breach poses are RP archive profiles: `amb_d7c499_sit_chair_table_keybo` (the desk),
  `tablet2` and `laptop`. A client without the archive runs the breach without the pose.
- The shard belongs to the contract's taker: given to someone else it cannot be delivered by them,
  and it goes stale with the contract.
- A server stop between the delivery sale and the retirement of its contract: the next start finds
  the sale paid and retires the contract (no second payment); the `deliver` event fires again then,
  with `via = "recovered"`.
- The native heat is a policy on the netrunner's own game: the police it brings are local to that
  player. Hand-overs, site alerts, heat timers and quickhack cooldowns are forgotten on a restart.
- The rewards the client pays are new money: rp_economy caps rp_netrunner at 30 000 eddies an hour.
- Replaced from rp_netrunner 1.x: the Afterlife access point (its door breach and data bounty) is
  now the contract board, the SQL activity log and the `trace` export are gone (traces live in the
  NCPD record), and quickhacks are burned through the coordinator.
