# rp_nomade

Adds Aldecaldos smuggling runs for the nomad job: take a run at the camp's board, carry contraband crates into your truck, drive past the NCPD checkpoints into Night City and hand the crates to a fence (or to a player who accepts), paid minus the camp's cut.

- **Docs:** [Build a job: prompts, animations, items and pay](https://open2077.net/docs/world-interaction), [Actions and carrying](https://open2077.net/docs/actions), [Durable transactions](https://open2077.net/docs/transactions), [Player interactions](https://open2077.net/docs/player-interactions)
- **Starts:** with `ensure rp_nomade` (it declares `auto_start false`)
- **Needs:** `open77_transactions`, `open77_actions`, `open77_containers`, `open77_player_interactions`, `open77_notifications`, `rp_jobs`, `rp_inventory`, `rp_economy`, `rp_garage`, `rp_cargo`; `rp_ncpd` is optional (records and warrants)
- **Runs on:** server and client (the client only draws the map pins and the GPS route)

## How to play

**The nomad** (job `nomade`, on duty with `/service`):

1. **Take a run.** At the Aldecaldos camp, the contracts board offers one run per route
   (**E** *Run to the Afterlife street, 3 crates*, **F** *Run to Lizzie's, Kabuki, 2 crates*).
   A 4 second bar (*Signing the manifest*). The camp's stash pays the goods: if it is empty the
   run is refused before the bar (*The camp has nothing to move right now.*). The crates appear
   at the loading points north of the board, each with an **E** *Pick up nomad crate* prompt.
   Chat: `Run signed: 3 crates of smuggled goods for Afterlife street, Watson, 25 minutes...`.
   A pin marks the drop on the map, and every NCPD checkpoint gets a pin too.
2. **Load.** Lift a crate (**E**), walk it to the convoy truck bay south-east of the board where
   your truck is parked (a truck you own, hold a key for, or a clan fleet truck), and stand behind
   its bed: **E** *Load into the truck* is drawn at the tailgate of the truck parked in the bay (at
   the bay itself while no truck is there). The crate rides in the bed for everyone to see. `/nomad load` loads next to any
   truck you may use. When the last crate is in, the GPS route to the drop starts.
3. **Drive.** The run has a deadline. Each NCPD checkpoint on the roads into the city may search
   the truck: the answer is decided per run and per checkpoint, so the same run always meets the
   same answer at the same checkpoint. Waved through: *the cops wave you through*. Searched:
   every crate of the run in the truck is emptied into the NCPD evidence stash, the driver pays
   a fine (cash, then bank), gets an NCPD wanted level and a criminal record; an unpaid fine
   becomes a warrant. The run ends there.
4. **Deliver.** At the drop, park at the unload bay, go behind the bed, **E** *Unload a crate* (or `/nomad unload`):
   the crate comes out of the bed into your arms. Walk it to the fence and **E** *Hand over to
   Rook*. The fence pays the crate's price in one operation: the camp keeps its cut, the rest goes
   to the nomad who took the run. The crate is gone.
5. **Or sell to a player.** Put a crate down next to a player (**G**) and `/nomad sell <id>
   <price>`. They see the offer card (*Ada Kovac: a crate of smuggled goods for 500 eddies*) and
   accept it with **Y** (**N** declines): they pay, the goods land in their pockets, and the price
   is split the same way.

**What can go wrong.** The deadline passes (the run is off: the fence still pays, but only the
hot price, and the camp gets nothing; the pin and route turn back to the camp, where **E** *Return
to the stash* puts the goods back). Somebody outside the crew lifts one of your crates (the run is
off; they can fence it hot). The truck is wrecked, impounded or lost (the run is off; the crates
keep their goods in the bed). A disconnect drops a carried crate where you stood; the run goes on
and the pins come back when you return. When `rp_nomade` restarts, a carried crate is dropped at
the carrier's feet (`owner_stopped`) and rebuilt on the ground there; crates on the ground and in a
bed come back where they were. After a server crash, a crate that was being carried comes back at
its last put-down spot.

**The NCPD officer** (job `ncpd`, on duty): `/nomad search` next to a truck. With a warrant on its
plate (rp_garage) the search starts at once; otherwise the driver, or the nomad whose run rides
in it, is asked to consent and must be on foot within 5 m. An 8 second bar (*Searching*); the
goods of every camp crate in the bed go to the evidence stash in one operation, and the nomad
gets a record. A crate of the camp left on the ground can be searched without consent.

Commands: `/nomad` (help), `/nomad status`, `/nomad load`, `/nomad unload`, `/nomad sell <id>
<price>`, `/nomad search`, `/nomad camp`.

Refusals reach the player as a chat line and a toast: a run already going, the camp's stash
empty, no truck you hold a key for, a full bed, a buyer who cannot pay, a declined search, and the
libraries' own reasons. A refusal at the very start of a prompt (off duty, no job, too far) is the
prompt library's own notice.

## Setup

1. `resources.load`, in this order of dependencies:
   `open77_transactions`, `open77_props`, `open77_animations`, `open77_interactions`, `open77_uikit`,
   `open77_notifications`, `open77_player_interactions`, `open77_actions`, `open77_containers`,
   `rp_jobs`, `rp_inventory`, `rp_economy`, `rp_garage`, `rp_cargo`, `rp_ncpd`, `rp_nomade`.
2. Convar `rp_inventory_backend transactions` (a buyer's pockets are coordinator accounts).
3. Coordinator tunables (add these entries to the lists your other jobs already use):

```text
tunable.set open77_transactions writers rp_nomade:world+stash+char, rp_cargo:veh/cargo, rp_economy:cash+bank+soc, rp_inventory, open77_containers:world
tunable.set open77_transactions mint1 rp_nomade sys:nomad nomad_crate 500; rp_nomade sys:nomad.supplier nomad_contraband 2000; rp_economy sys:* money 2000000
ensure open77_transactions
ensure open77_actions
ensure open77_containers
ensure rp_cargo
ensure rp_nomade
```

`open77_transactions`, `open77_actions`, `open77_containers` and `rp_cargo` all declare
`auto_start false`: each needs its `ensure` before `rp_nomade`.

- `rp_nomade:world+stash+char`: the crates, the camp's stash and the evidence stash, and the one
  operation grants it gives rp_cargo (a crate into a bed) and rp_economy (a sale out of a crate,
  into a buyer's pockets).
- `open77_containers:world`: it opens the crates' world rows.
- The two mint rules: one token per crate, and the camp's supplier. rp_nomade is already on
  rp_economy's money allowlist (`EconomyConfig.mint.callers`): the fence's eddies are created there.

Expected start lines:

```text
[rp_nomade] coordinator ready (store=sql)
[rp_nomade] items defined through rp_inventory: 2
[rp_nomade] crates rebuilt: 0 (ground 0, in a bed 0, empty 0, sold 0, orphans closed 0); 0 run(s) going
[rp_nomade] ready: 2 route(s), 2 checkpoint(s), board, truck bay, stash (job nomade)
[rp_nomade] camp supply: +24 goods (stash had 0)
```

Without `stash` in its writers the boot waits (`still waiting for the camp's stashes`).

### Operator console (restricted: console or ACL `command.nomad.*`)

| Command | Does |
|---|---|
| `nomad.status` | stash, runs, crates per state, counters |
| `nomad.stock <count>` | goods into the camp's stash (the supplier mint rule caps it) |
| `nomad.op.setup <id> [nomade\|ncpd]` | job grade 0 and duty |
| `nomad.op.truck <id> [plate]` | with a plate: that owned truck next to the player; without: rp_garage's issue export (a server with `rp_garage_lab 1`) |
| `nomad.op.take <id> [route]` | the board prompt |
| `nomad.op.pickup <id>` | lifts the nearest camp crate within 3 m |
| `nomad.op.load <id>` / `nomad.op.unload <id>` | the carried crate onto the nearest truck / the top crate out of it |
| `nomad.op.deliver <id> [route]` | the carried crate to that route's fence |
| `nomad.op.checkpoint <id> <checkpoint> [search\|pass]` | the player's truck enters that checkpoint now; without the last word the run's own answer decides |
| `nomad.op.expire <id>` | the player's run is past its deadline now (until the next restart) |
| `nomad.op.search <id>` / `nomad.op.sell <seller> <buyer> <price>` | `/nomad search` / `/nomad sell` for that player |

### For the fixer board

Every committed step fires a server event:

```lua
AddEventHandler("rp:job:completed", function(ev)
    -- ev = { job = "nomad", kind = "pickup" | "checkpoint_passed" | "confiscated" | "deliver",
    --        playerId = <the run's nomad>, ref = <operation id>, data = { run, route, ... } }
end)
```

`ref` is the coordinator operation (`nmd.run:...`, `nmd.ck:<run>:<checkpoint>`, `nmd.seize:...`,
`nmd.sale:...`): stable across retries, so a listener counts each step once. `deliver` carries
`crate`, `of`, `pay`, `cut`, `buyer` (`fence` or `player`) and `complete`; `confiscated` carries
`by` (`checkpoint` or `officer`) and `crates`. Hot sales fire nothing.

### Exports (server, synchronous)

```lua
exports.rp_nomade:activeRun(playerId)  -- { run, route, crates, deadline, failed, left, where = {...}, ... } | nil
exports.rp_nomade:hasRun(playerId)     -- boolean: a live run
```

## Config

Everything is in `server/config.lua`:

| Key | What |
|---|---|
| `job`, `society`, `fixerJob`, `policeJob` | rp_jobs job (`nomade`), the camp's society, the fixer's job id (`nomad`), the police job |
| `items` | `nomad_contraband` (2.5 kg, illegal) and `nomad_crate` (the crate's token, unique) |
| `accounts` | the camp's stash, the evidence stash, the token and supplier `sys:` accounts |
| `restock` | the camp's supplier: every 10 min, +24 goods while the stash holds fewer than 24 |
| `camp` | board, loading points, truck bay, stash drop point, and `decor`: the props that dress the camp (a table under the board, loaded pallets; the vanilla camp is quest content the multiplayer world does not stream) |
| `bayPrompt` | `followTruck` (the load and unload prompts follow the truck parked in their bay) and `behindBedM` (how far past the bed's last slot the prompt is drawn) |
| `routes` | per route: crates, goods per crate, price per crate, deadline, unload bay, fence |
| `campCut`, `hotRatio` | the camp's share of a live sale (20 %); what the fence pays for hot goods (50 %, 0 refuses) |
| `checkpoints` | each zone (an `Open77.zones` definition checked against the truck) and its `searchChance` |
| `search` | the fine, the wanted level, the warrant when the fine is unpaid |
| `officer` | reach, consent distance, the search bar |
| `crate` | the carried model and binding, `pickupBy` (`anyone` or `crew`) |
| `playerSale` | price limits and the hand-over distances |
| `navigation` | pins, sprites, when the GPS route starts |

Where things are. The Afterlife drop (unload bay and fence) is `measured = true`. The camp's
points (the board, the loading points, the truck bay with its tailgate prompt, the stash) were
used in live runs and keep `measured = false` until someone confirms each with `/pos`; the Kabuki
drop and the checkpoints have not been walked:

| Point | Position | Landmark |
|---|---|---|
| Contracts board | 1790.0, 2252.0, 180.3 | Aldecaldos camp, 4 m north-west of V's tent |
| Loading points 1 to 4 | 1786 / 1788 / 1790 / 1792, 2256 to 2258.5, 180.3 | north of the board |
| Convoy truck bay | 1800.0, 2240.0, 180.2 | 12 m south-east of the board |
| Camp stash | 1788.2, 2253.6, 180.3 | beside the board |
| Afterlife drop: unload bay / fence | -1422.5, 975.0, 23.35 / -1417.5, 975.5, 24.25 | the street outside the Afterlife's ramp, Watson: the lane against the east curb, the fence on the sidewalk (walked) |
| Kabuki drop: unload bay / fence | -1188.9, 1566.2, 22.9 / -1186.4, 1567.5, 22.9 | the street outside Lizzie's Bar, Kabuki |
| Checkpoint `badlands_toll` | 900, 1900 (r 120 m) | on the camp to city corridor where the Badlands end |
| Checkpoint `watson_ramp` | -500, 1700 (r 120 m) | on the corridor where it enters Watson |

The checkpoint centres are placed on the straight line from the camp to Watson, not on a road:
drive the GPS route and move each one onto the road where it really crosses into the city
(`/pos` in the truck).

## Limits

- One run per nomad at a time; a failed run does not block the next one.
- A searched crate stays in the bed, empty, until it is unloaded (then thrown away). A crate in a
  bed is never reclaimed by the camp; one left on the ground two hours past its run's end is.
- The truck is any rp_garage vehicle with an rp_cargo bed layout. rp_garage has no export to take
  a clan fleet truck out of storage or to list a society's fleet: a nomad brings their own (or
  one they hold a key for).
- The checkpoint search reads the truck's position once a second: a truck crossing a zone in
  under a second at full speed can slip through. The zones are 120 m wide for that reason.
- The NCPD wanted level and the police it sends are the driver's own game (per-client heat).
- The officer's search knows only the camp's crates: a truck carrying none is reported clean.
- The ambush of rp_nomade 1.0 is gone; the risk on the road is the NCPD.
- The Kabuki drop, the checkpoints and the bed slots of other trucks than the Mackinaw are not
  measured in game. The carried crate's binding was measured in both views.

## Tests

```text
python -m unittest discover -s tests -p "test_w3_nomad*.py"
```

They run the real open77_transactions, open77_actions, open77_containers, rp_economy, rp_cargo
and rp_nomade offline: the full run, checkpoint searches, the officer (warrant, consent,
refusal), the player sale, deadline, theft, a wrecked and an impounded truck, disconnect and
restart, refusals, replays and a crash between a sale and the crate's retirement.
