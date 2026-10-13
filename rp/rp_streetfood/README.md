# rp_streetfood

Adds a street-food stall: a cook grills a dish and hands it to a customer, who sees the price and accepts, pays and eats at the counter, on the go or seated. Dish, price and tip move in one sale, built on the platform's job libraries.

- **Docs:** [Build a job: prompts, animations, items and pay](https://open2077.net/docs/world-interaction), [Durable transactions](https://open2077.net/docs/transactions)
- **Starts:** with `ensure rp_streetfood` (it declares `auto_start false`)
- **Needs:** `open77_transactions`, `open77_actions`, `open77_player_interactions`, `open77_notifications`, `rp_jobs`, `rp_inventory`, `rp_economy`
- **Runs on:** server

The second example of the world-interaction campaign (row **C4**): a cook grills at a real
market grill, the dish waits on the pass, the cook hands it to a customer who **sees the price
and accepts**, the customer pays in **one** atomic sale (dish + price + tip), then eats standing at
the counter, on the go, or — optionally — seated on real food-court furniture.

**What it needs.** The platform's `open77_actions`, `open77_transactions`,
`open77_player_interactions` and their sibling libraries (the load list below). They are on this
repository's `next` branch until the next server release. Cook (both rigs), order with a
tip, consented serve, sale with the society share, meals at the counter and seated, a declined
offer, two cooks at one grill and a restart ran in game (crowd pedestrians switched off: they stand
on the grill spot). The `amb_*` cook animations need the `Open77RP.archive` that ships them (not yet in
the release archives). The test script is in
[`docs/world-interaction/c4-streetfood.md`](../docs/world-interaction/c4-streetfood.md) §6.

## Enable it on a server

Opt-in (`auto_start false`), server scripts only. In `resources.load`:

```text
open77_transactions, open77_actions, open77_player_interactions, open77_notifications,
rp_jobs, rp_inventory, rp_economy, rp_needs (optional), open77_furniture (optional), rp_streetfood
```

| Setting | Value | Why |
|---|---|---|
| convar `rp_inventory_backend` | `transactions` | pockets must be coordinator accounts (`char:<subject>`) |
| convar `rp_streetfood_seating` | `1` to use seats (default `0`) | seating is optional until B6 ships |
| coordinator `writers` | `*`, or least privilege: `rp_streetfood:stash/pantry+stash/pass+char, rp_economy:cash+bank+soc, rp_inventory` | the stall writes only its two stash parts and the pockets it eats from; rp_economy reaches the stall and the buyer's pockets through a one-operation grant |
| coordinator `mint1` (or any `mintN`) | `rp_streetfood sys:streetfood.kitchen * 600; rp_streetfood sys:streetfood.supplier * 5000` | cooked dishes are minted from the kitchen (ingredients are burned into it in the same operation); restocks from the supplier |
| rp_economy mint allowlist | nothing | every sale is player → society + cook: no money is created |
| rp_jobs | the `cook` job (added to `rp_jobs/shared/config.lua`, civil: joined at the agency) | duty and the work epoch |

Expected start lines:

```text
[rp_streetfood] coordinator ready (store=sql)
[rp_streetfood] items defined through rp_inventory: 6
[rp_streetfood] ready: stalls food_court, 2 targets, seating off (job cook)
```

### Which one at a venue: rp_bar or rp_streetfood

Both are food-and-drink service and both may run on one server. They never share a counter, a job
or an item: **rp_bar** is the Afterlife bar counter (job `barman`, ingredients in the bartender's
pockets, its own SQL sales ledger, served with consent); **rp_streetfood** is a street stall (job
`cook`, a stall pantry and pass in the coordinator, the sale through rp_economy). Give one venue
one of them: do not add an rp_streetfood stall inside the Afterlife, and do not point rp_bar's
counter at a food court that has a stall.

## Where it is

| Stall | Point | Position, yaw | Source |
|---|---|---|---|
| `food_court` (on) | grill (the cook) | -397.617, 715.138, 115.000, 64.0 | pedestrian spot row 9594 `amb_704dff_cook` (a vanilla cook at a market grill; also crowd-spot row 58918) |
| | counter (the customer) | -398.887, 715.848, 115.000, -107.0 | pedestrian spot row 1144 (`stand_ground`), 1.45 m in front of the grill, facing it |
| | seats (with seating on) | A1 furniture `14182403679719868087` (chair, 5.6 m), `14644536518519442059` (11 m), `9160494166749203069` (24 m); barstool `3931217955540569133` off | research ledger "A1 ten furniture ids verified live" |
| `kabuki` (off) | grill / counter | -1167.426, 2023.262, 7.780, 177 / **arithmetic** counter | spot row 7736; no customer spot stands in front of it |

The food court is the upper floor (z 115) of the pedestrian proof and of the A3/A1
seat runs. The food court's grill and counter are walked points (`measured = true`): the cook
and the customer stand about 0.5 m from their anchors and the 1 m arrival radius plays the pose
there. The `kabuki` stall (off) is still anchor data (`measured = false`). The crowd
can book the grill spot (crowd-spot row 58918) and the seats (`npcSeated`/`npcCrowd`): stop the
crowd (world suppression) for a test run. Nothing in this resource vetoes an NPC.

## Playing it

**Cook** (job `cook`, on duty with `/service`): at the grill, **E** shows *Grill a skewer*,
*Grill a burger*, *Serve the next order*, *Stock the pantry from your pockets*.

- Grilling plays the cook profile at the grill anchor (third person while it plays), 10–12 s with
  a progress bar (X cancels). The ingredients leave the pantry and the dish lands on the pass in
  **one** operation at the end; an empty pantry or a full pass is refused **before** the bar.
- *Serve the next order* takes the oldest order whose customer stands within 3 m and whose portion
  is ready, and offers it. The customer reads who offers what and the price on the offer card and
  accepts (**Y**, or `/interaction accept`) or declines (**N**). A soda is drawn in the cook's hand
  while offered.
- *Stock the pantry* moves every ingredient you carry into the stall's pantry.

**Customer**: at the counter, **E** shows *Order Grilled skewer (18 eddies)*, *Order Grill burger
(24 eddies)*, *Order Soda can (6 eddies)*, *Eat at the counter*. `/streetfood tip <eddies>` adds a tip to
your next order (paid to the cook). After paying: *Eat at the counter* (the market-grill customer
pose at the counter anchor), `/streetfood eat` (takeout, standing where you are), `/streetfood
drink` (sips while walking, with the can in your hand), or **E** on a seat when seating is on.
Eating applies `rp_needs` once (skewer hunger +30, burger hunger +40 / thirst −5, soda thirst +25).

`/streetfood` alone prints help; `/streetfood menu` shows prices and what is ready;
`/streetfood orders` (cooks) lists the orders waiting.

## How it works, library by library (author walkthrough)

The stall is a set of **hooks** on the libraries; it keeps no durable state of its own.

| Step | Library | What this resource writes |
|---|---|---|
| prompts, station claim, duty | **open77_actions** (B5) | `define` one action per recipe / dish / seat profile, `target` the grill and the counter (and seats); `eligibility = rp_jobs:eligible{ job = "cook", duty = true }` and `epochs = rp_jobs:workEpoch` on cook, serve and stock. The grill target is claimed per operation: two cooks, one grill → `target_claimed`. |
| cook | **open77_transactions** (A13) | `reserve` hook: the recipe's lines (inputs `pantry → sys:streetfood.kitchen`, dish `sys:streetfood.kitchen → pass`); `commit` hook: commit that reservation; `cancel` hook: cancel it (or settle it when the commit is in doubt). |
| the stall's goods | open77_transactions | two `stash:` containers per stall with deterministic ids `stash:sf.<stall>:pantry` / `:pass`, opened at boot: a restart finds them again with no listing. |
| order | open77_actions | an action with a gesture (`order` profile) whose commit hook opens a ticket in memory. No value moves. |
| hand-over | **Open77.playerInteractions** | `request(cook, customer, "give", { consent = true, ... })`. The library's lifecycle is single-actor, so this resource reserves the portion itself (`promised`), withdraws the offer when the cook's work epoch moves, and re-checks `eligible{ ..., epoch = captured }` at completion. |
| payment | **rp_economy** (B3) `sale` | one operation: the portion from the stall into the buyer's pockets, price to `soc:cook`, tip to the cook's cash. The op id is minted at the offer, so a retry or a replay returns the stored receipt and the customer pays once. `authorize(opId, "rp_economy", { stall container, buyer pockets })` lets rp_economy touch exactly those two accounts. |
| hand items | **Open77.heldItems** | the soda can is held by the cook during the offer, by the customer after the sale, released when drunk. A projection only: custody is the coordinator's. Food has no documented native record, so it is not drawn in hand. |
| meal | open77_transactions + **rp_needs** | `reserve` hook: one portion `char:<subject> → sys:streetfood.eaten`; `commit` hook: that operation, then `rp_needs:apply` **at most once** and the event `rp_streetfood:consumed`. |
| stocking | **rp_inventory** (B2) `moveAsync` | every stockable item in the cook's pockets into the pantry, one operation (B2 owns the pockets). |
| items | rp_inventory `define` | the six `sf_*` items through the single definer. |
| seats | **open77_furniture** (A1) | `get(furnitureId)` refreshes each seat's pose from the catalogue; each seat is an open77_actions target (one winner per seat). |

Events for other resources (host-wide, `TriggerEvent`):

```lua
AddEventHandler("rp_streetfood:consumed", function(playerId, itemId, opId) end)  -- after the meal commit
AddEventHandler("rp_streetfood:sold", function(cookId, customerId, itemId, opId) end)  -- after the sale
```

## Failure semantics

| What happens | Outcome |
|---|---|
| empty pantry / full pass | refused at reserve (`missing_ingredients` / `pass_full`), no bar, nothing held |
| a second cook at a busy grill | `target_claimed`, nothing held |
| death, X, a vehicle, combat, walking off during a cook or a meal | cancelled, the reservation released at once, nothing used |
| cook commit: store never got it / ack lost / coordinator died (kept or lost) | fenced: nothing / committed once / settled by the sweep: ingredients and dish move together or not at all |
| customer declines, lets the invitation time out, leaves | nothing paid, the portion stays on the pass (and is free again) |
| cook clocks out while the offer waits / during the hand-over | the offer is withdrawn / the completion is refused (`stale_job_epoch`): nothing sold |
| customer cannot pay | `insufficient_funds`: nothing moves |
| rp_economy answers `in_doubt` | the sweep follows `rp_economy:status`; the hand item and receipt follow once |
| the same sale replayed (retry, rp_economy restart) | the stored receipt: paid once |
| server restart | pantry, pass and pockets intact; open orders and offers are forgotten (intent, not value) |
| rp_streetfood restart mid-offer | the platform cancels the offer: nothing paid |

## Test console (restricted: console or ACL)

```text
streetfood.status
streetfood.lab.setup <playerId> [cook|customer]   streetfood.lab.clock <playerId> on|off
streetfood.lab.seed [stall] [times]               streetfood.lab.give <playerId> <item> <count>
streetfood.lab.cook <playerId> <skewer|burger> [stall]
streetfood.lab.stock <playerId> [stall]
streetfood.lab.order <playerId> <skewer|burger|soda> [tip] [stall]
streetfood.lab.serve <cookId> [stall]             streetfood.lab.offer <cookId> <customerId> <dish> [tip] [stall]
streetfood.lab.eat <playerId> <counter|go|drink|seat:<n>> [dish] [stall]
streetfood.lab.state <playerId>                   streetfood.lab.stall [stall]
```

The customer's consent stays the customer's: no test command accepts an offer for them.

## Tests

```text
python -m unittest discover -s tests -p "test_c4*.py"
```

16 offline tests (happy path, two cooks one grill, one portion two offers, declines / timeouts /
clock-outs, payment failures and replays, refusals and forged intents, crash windows, cancellations,
seating on and off, restart, the test console, sources and anchors). They run the real
open77_transactions, open77_actions, rp_economy and rp_streetfood; they prove nothing about what
renders in game.

## Limits

- Not proven in game: poses at the grill and counter, the hand-over presentation, the hand items,
  first person, the female rig, prompt aiming, NPC occupancy. See the doc's §6.
- Seated meals play the seat's pose with no eating clip and no hand item (no player twin of the
  `sit_chair_asian_takeout` family yet).
- A restart between a meal commit and `rp_needs:apply` skips the needs effect (never doubles it).
- Restocking with money (the society pays a supplier) has no atomic B3 export yet: restock is an
  operator mint (`streetfood.lab.seed`, capped) or a cook stocking from their pockets.
