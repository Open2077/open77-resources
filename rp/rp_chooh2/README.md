# rp_chooh2

Adds the CHOOH2 fuel chain: farmhands harvest Biotechnica corn into crates, haulers truck the crates to the Petrochem refinery, operators ferment the corn into CHOOH2 canisters, and the canisters are sold to the fuel depot or poured into a car's tank.

- **Docs:** [Build a job: prompts, animations, items and pay](https://open2077.net/docs/world-interaction), [Actions and carrying](https://open2077.net/docs/actions), [Durable transactions](https://open2077.net/docs/transactions), [Replicated state bags](https://open2077.net/docs/state-bags)
- **Starts:** with `ensure rp_chooh2` (it declares `auto_start false`)
- **Needs:** `open77_transactions`, `open77_actions`, `open77_containers`, `open77_notifications`, `rp_jobs`, `rp_inventory`, `rp_economy`, `rp_garage`, `rp_cargo`; `open77_fuel` for refuelling
- **Runs on:** server

In Night City, CHOOH2 is the alcohol fuel every car burns: Petrochem makes it from the corn
Biotechnica grows outside the city. Here the corn grows in rows by the Biotechnica protein farm on
the northern edge of Northside, and the refinery is the Petrochem tank farm of the North Sunrise
Oil Field, 1.2 km up the road. Every step that moves value is one coordinator operation with its
own id, so a retry, a double press or a restart never pays, mints or burns twice.

## How to play

| Who | Where | What they do | What they see |
|---|---|---|---|
| Farmhand (job `farmhand`) | farm office | E "Clock in" | "On duty at the farm." |
| Farmhand | a corn row | E "Harvest corn": kneels 8 s | "+4 corn into your crate."; a corn crate appears 1.4 m from the row |
| Farmhand | a corn row | F "Check the row" (3 s) | the crate's corn and the row's harvests left |
| Hauler (`farmhand`, `refinery` or `nomade`, on duty) | the crate | E "Pick up corn crate", walk; G sets it down | the crate in both hands, walking pace |
| Hauler with the truck's key | farm loading bay, or `/chooh2 load` next to the truck | carrying: "Load into the truck" | "Corn crate loaded on NC-1234, slot 1."; the crate in the bed |
| Hauler | refinery unloading bay, or `/chooh2 unload` next to the truck | E "Unload a crate" | the top corn crate lands in their hands |
| Hauler | corn intake hopper | carrying: "Empty into the intake" | "19 corn into the intake (intake: 19)."; the crate is gone |
| Operator (job `refinery`) | Petrochem shift office | E "Clock in" | "On duty at the refinery." |
| Operator | fermenter control station | E "Run a batch": 15 s at the console | "Batch done: 10 corn in, 2 CHOOH2 canister(s) on the rack." |
| Operator | fermenter control station | F "Read the gauges" | the corn in the intake and the canisters on the rack |
| Operator | CHOOH2 output rack | E "Take canisters" (2.5 s) | "+2 CHOOH2 canister(s) in your pockets." |
| Operator | Sunrise fuel depot counter | E "Sell canisters" (2 s) | "Sold 2 canister(s) to the depot clerk: 300 eddies (270 to you, 30 to the refinery society)." |
| Anyone with a canister | depot fuel pump, or `/chooh2 refuel` next to any car | E "Refuel the nearest car": 5 s | "Poured a CHOOH2 canister: +15.0 L, tank 35.0 L." |

- A row gives 4 harvests, then one more every 5 minutes. A picked-clean row only offers "Check
  the row" until it grows back.
- A harvest fills your own crate next to that row (one is opened on the first harvest). A crate
  holds 20 kg of corn: a full crate refuses the next harvest before the bar starts.
- Anyone on duty in a haul job may lift any crate (`pickupBy = "crew"`). Loading needs the
  truck's key (rp_garage, checked by rp_cargo); without it the hauler keeps the crate and reads
  "You hold no key for that truck."
- A batch burns 10 corn from the intake and makes 2 canisters on the rack, in one operation. The
  station takes one operator at a time; a second one reads "Someone is already working there."
- A canister pours 15 L. A tank with less than 3 L of room, a moving car or a stopped
  `open77_fuel` refuse before anything is taken. No key is needed to pour fuel into a car.
- X on any bar, walking off, a vehicle, a weapon, death or a disconnect stops the step: nothing is
  taken or paid, the row keeps its charge, a crate opened for that harvest is closed again.
- `/chooh2 crates` lists your crates and where they are; `/chooh2` alone prints the help line.

Every committed harvest, delivery, batch, sale and refuel fires the server event
`rp:job:completed` with `{ job = "chooh2", kind = "harvest" | "deliver_intake" | "refine" | "sell" |
"refuel", playerId, ref = <coordinator op id>, data = { subject, ... } }` for the fixer board.
`ref` is unique per step: a consumer dedupes on it. A delivery found committed after a restart is
reported once with `playerId = nil` and `data.recovered = true`.

## Setup

1. `resources.load`, in this order of dependencies: `open77_transactions`, `open77_props`,
   `open77_animations`, `open77_interactions`, `open77_uikit`, `open77_notifications`,
   `open77_actions`, `open77_containers`, `open77_fuel`, `rp_jobs`, `rp_inventory`, `rp_economy`,
   `rp_garage`, `rp_cargo`, `rp_chooh2`.
2. Convar `rp_inventory_backend transactions` (canisters must live in coordinator pockets).
3. rp_jobs ships the two jobs (`rp_jobs/shared/config.lua`, `RpJobsConfig.Jobs`): `farmhand`
   (Biotechnica farmhand) and `refinery` (Petrochem operator), both civil, joined at the agency.
   A server with its own rp_jobs table needs them back, or the start says `WARNING: rp_jobs has no
   job farmhand, refinery` and those steps answer `unknown_job`. To use existing jobs instead,
   change `C.jobs` and `C.offices` in `server/config.lua`.
4. rp_economy mints the depot's money on this resource's behalf: it ships `rp_chooh2 = 30000` in
   `EconomyConfig.mint.callers` (`rp_economy/server/config.lua`; without it every sale answers
   `mint_denied`). Optionally add `"refinery"` to `EconomyConfig.societies` (it is loaded on first
   use otherwise).
5. `open77_transactions` tunables (size the hourly caps to your population):

   ```text
   tunable.set open77_transactions writers rp_chooh2:world+stash+char, rp_cargo:veh/cargo, rp_economy:cash+bank+soc, rp_inventory, open77_containers:world
   tunable.set open77_transactions mint1 rp_chooh2 sys:chooh2.fields * 2000; rp_chooh2 sys:chooh2.refinery chooh2_canister 400; rp_inventory sys:* * 2000; rp_economy sys:* money 2000000
   ```

   A server with other jobs lists their writers in the same `writers` line. `sys:chooh2.fields`
   creates the corn and the crate tokens, `sys:chooh2.refinery` the canisters; burning corn into
   the refinery and canisters into `sys:chooh2.burned` needs no rule. rp_economy reaches the
   seller's pockets through `rp_inventory:grantPockets` (rp_economy is one of its
   `pocketGrantees` by default).
6. `ensure rp_chooh2` after its dependencies.

Expected start lines:

```text
[rp_chooh2] coordinator ready (store=sql)
[rp_chooh2] items defined through rp_inventory: 3
[rp_chooh2] 5 corn row(s) ready (5 created)          -- "(0 created)" on later boots
[rp_chooh2] crates rebuilt from the coordinator: N (ground g, in a bed b, delivered d, new n, orphans closed o)
[rp_chooh2] ready: 5 corn rows, farm office and bay, refinery (intake open, control, rack), depot, pump
```

A missing `open77_containers:world` writer leaves the rows out (`row row1 (node.row1) unavailable:
namespace_denied`), asked for again every 30 s; a stopped `open77_fuel` is said once
(`refuelling answers fuel_unavailable until it does`).

### Console

Restricted (console or ACL `command.chooh2.*`), with explicit player ids; each drives the same
server path as the prompts, so the player stands where the prompt would be.

| Command | Does |
|---|---|
| `chooh2.status` | crates per state, counters, intake and rack, each row's charges |
| `chooh2.setup <pid> <job>` | that job (grade 0) and duty on |
| `chooh2.clock <pid> on\|off` | duty in the player's own job |
| `chooh2.truck <pid> [plate]` | that plate's truck out next to the player (rp_garage `spawnOwned`), or a Mackinaw if rp_garage issues one |
| `chooh2.harvest <pid> <row> [harvest\|inspect]` | the row prompt's request (`row1` to `row5`) |
| `chooh2.pickup <pid> [crateKey]` | lifts the nearest ground crate (3 m) or that one |
| `chooh2.load <pid> [vehicleId]` / `chooh2.unload <pid> [vehicleId]` | loads the carried crate / unloads one into the hands |
| `chooh2.deliver <pid>` | puts the carried crate into the intake (stand at the hopper) |
| `chooh2.refine <pid>`, `chooh2.gauges <pid>`, `chooh2.collect <pid>`, `chooh2.sell <pid>` | the station prompts |
| `chooh2.refuel <pid> [vehicleId]` | pours a canister into the nearest car (4 m) or that one |
| `chooh2.drop <pid>` | forces a drop of the carried crate |
| `chooh2.give <pid> <item> <count>` | items through rp_inventory (canisters to try a sale or a refuel) |
| `chooh2.stock <count>` | corn straight into the intake |
| `chooh2.reset [row\|all]` | rows back to full charges in place |
| `chooh2.state <pid>` | the player's crates, canisters, cash, the society and receipts |

## Config

Everything lives in `server/config.lua`:

| Key | Default | What it sets |
|---|---|---|
| `C.jobs`, `C.offices` | `farmhand`, `refinery`, haulers `farmhand`/`refinery`/`nomade` | who harvests, refines, hauls; who clocks in where |
| `C.nodes`, `C.nodeDefaults` | 5 rows, 4 charges, 5 min regrowth | the corn rows (`containerKey` to give a closed row a new key) |
| `C.harvest` | 3 to 5 corn | what one harvest yields, drawn from the operation id |
| `C.crate` | 20 kg, 4 per player, 48 on the server; reach 2 m, `vehicleReach` 6 m | the crate's size and limits, `pickupBy`; `vehicleReach` is how far from the truck's origin a carried crate may be put in its bed (`/chooh2 load`) |
| `C.truckNearM` | 6 m | how close `/chooh2 load`, `/chooh2 unload` and `/chooh2 refuel` look for a vehicle; keep it equal to `crate.vehicleReach`, or a truck the command finds refuses the crate as too far |
| `C.refine`, `C.collectMax` | 10 corn to 2 canisters, 3 per take | the batch ratio |
| `C.stashes` | intake 400 kg, rack 200 kg | the refinery's two stashes |
| `C.prices`, `C.saleMax`, `C.societyShare`, `C.society` | 150 per canister, 10, 10 %, `refinery` | the depot sale |
| `C.refuel` | 15 L, 3 L of room, 4 m, standing still | the pour |
| `C.actions` | durations, labels, animation profiles | `scavenge`, `examine`, `tablet2`, `mechanic` |
| places | see the file | farm office, rows, lane centre, farm bay; refinery office, unloading bay, intake, control station, output rack, depot, pump |

Every place is `measured = true`: each was walked in game (the corn rows, the farm office and
bay, the refinery's office, unloading bay, intake, control station and rack, the depot and the
pump). A place moved later goes back to `measured = false` until someone stands on it again.

## Limits

- The refuel burns the canister in the coordinator, then adds the litres through
  `open77_fuel:refuel`, which takes no operation id: if the car disappears or the server stops
  between the two, the canister is spent and the fuel is lost (the player is told). Fuel lives in
  the car's state bag: a car stored and taken out again comes back with a full tank.
- A refuel needs no key: anyone may pour their own canister into any car.
- A car has no prompt of its own: refuel at the depot pump, or with `/chooh2 refuel` next to it.
- A crate in a bed is counted at its token's 2 kg; the corn stays in the crate's hold.
- A restart during a carry puts the crate back where it was last put down.
- Ground crates are open77_actions carry items: at most 128 per owning resource (`C.crate.maxOpen`
  48 here).
- Never close a row with `containers.remove`: a closed key is never reused, the row goes dark until
  it gets a `containerKey` in config. `chooh2.reset` refills it in place instead.
- The depot clerk is presentation only: the counter works without the NPC.
