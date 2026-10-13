# rp_ripperdoc

Adds a ripperdoc job at Viktor's clinic: the ripperdoc quotes a patient, the patient accepts, sits in the operating chair and gets real platform cyberware installed, paid once from a clinic stock the ripperdoc restocks at a chrome dealer or from players.

- **Docs:** [Build a job: prompts, animations, items and pay](https://open2077.net/docs/world-interaction), [Cyberware](https://open2077.net/docs/cyberware), [Player interactions](https://open2077.net/docs/player-interactions)
- **Starts:** with `ensure rp_ripperdoc` (it declares `auto_start false`)
- **Needs:** `open77_transactions`, `open77_actions`, `open77_player_interactions`, `open77_cyberware`, `open77_uikit`, `open77_contextmenu`, `open77_notifications`, `rp_jobs`, `rp_inventory`, `rp_economy`; optional `rp_zones`, `rp_identity`, `open77_seating` + `open77_furniture`, `open77_hacking`
- **Runs on:** server and client

Every eddy and every boxed implant moves through `open77_transactions`, in the hooks of the
`open77_actions` library; the implant itself is the platform's (`Open77.cyberware`). The clinic is
Viktor Vektor's, under the Misty's Esoterica alley in Little China (Watson), inside the `rp_zones`
zone `viktor_clinic`.

## How to play

**The ripperdoc** has the `rp_jobs` job `ripper` (label "Ripperdoc") and is on duty (`/service`).

1. **Quote.** Inside the clinic, within 4 m of a standing patient: hold **ALT**, click the patient,
   pick **Quote** (or `/ripper quote <id>`, or the old `/operer <id>`). The catalogue opens: one row
   per implant grade with its price, the clinic's stock and the time under the knife; an implant the
   patient already carries shows **Remove** at half its grade's price. Picking a row sends the quote.
   `/ripper quote <id> arms street` skips the menu.
2. **Wait for consent.** The patient reads the quote and answers. On accept, the price and the boxed
   implant are put on hold (nothing is paid yet) and the station next to the chair now offers the
   procedure: **E Install Gorilla Arms (Street)**.
3. **Operate.** Once the patient sits in the chair, stand at the station and press **E** (or
   `/ripper operate`). The ripperdoc kneels at the patient's side with a screwdriver (`repair`;
   `examine`, then `tablet2`, when the server lacks it) and a bar runs on both screens (12 to 22 s
   by grade). **X** stops it: nothing is charged. When the bar ends the implant is
   installed, then the hold is paid: the price to the `ripper` society, the box out of the stock.
4. **Restock.** At the chrome dealer in Kabuki Market, **E Buy chrome for the clinic** opens the order
   menu (or `/ripper restock arms industrial 2`). The boxes are delivered to the clinic's stash in the
   same operation, paid by the `ripper` society, or by the ripperdoc's cash when the society is short.
   `/ripper buy <id> <implant> [grade] [count]` buys boxes from a player in the clinic: they accept the
   hand-over, the boxes go into the stash and half their retail price to the seller.
5. `/ripper` shows the board (duty, the current procedure, the stock, the society, today's log);
   `/ripper stock` the stock; `/ripper cancel` withdraws a quote or stops a procedure before the
   implant goes in.

**The patient.**

1. Stand next to the ripperdoc in the clinic and ask for a quote. The quote arrives in chat and as a
   toast (implant, grade, price, time, cyberpsychosis risk), and the platform's offer card opens in the
   middle of the screen: accept with **Y**, refuse with **N** (30 s; the keys are rebindable, and `/interaction accept` or
   `decline` also work).
2. Sit in Vik's operating chair: **E Sit in the operating chair** (or `/ripper lie`, which keeps
   its old name: you sit, you do not lie down). Walk away to get up. A patient already seated when
   the quote comes is stood up for the answer and seated again after accepting.
3. During the operation a bar shows the time under the knife. **X** stops it: nothing is charged.
4. Done: chat, toast, `/implants` lists the chrome as the platform reports it. A patient past the
   cyberpsychosis threshold (4 implants) gets a 60 s `drugged` overlay and a warning.

**Everyone nearby** sees the patient in the chair and the ripperdoc at work; both postures are
played by the server.

**What ends a procedure and gives everything back** (the hold is released, the box stays in stock,
both players are told why): the patient declines or does not answer, walks more than 25 m from the
chair, gets off the chair during the operation, presses X, dies or disconnects; the ripperdoc presses
X, disconnects or clocks out; the accepted quote waits more than 3 minutes; the cyberware framework
refuses the implant or does not answer in time; the clinic restarts before the implant went in.

## Setup

In `resources.load`, after their libraries:

```text
open77_transactions, open77_actions, open77_player_interactions, open77_cyberware, open77_uikit,
open77_contextmenu, open77_notifications, rp_jobs, rp_inventory, rp_economy, rp_zones, rp_identity,
rp_ripperdoc
```

Add `open77_hacking` for the three hacking implants (without it they show as "provider offline"),
and `open77_seating` + `open77_furniture` for a seating-mode chair.

| Setting | Value | Why |
|---|---|---|
| convar `rp_inventory_backend` | `transactions` | the stash, pockets and wallets must be coordinator accounts |
| coordinator `writers` | `*`, or at least `rp_ripperdoc:cash+bank+soc+char+stash/stock, rp_economy:cash+bank+soc, rp_inventory` | the clinic writes the patient's wallets, the society, the seller's pockets and its own stock stash |
| coordinator mint rule | `rp_ripperdoc sys:ripperdoc.supplier * 40` | boxes created at the chrome dealer (size the hourly cap to your server) |
| rp_jobs | the `ripper` job (shipped) | duty and the work epoch |
| database | MariaDB or MySQL | the coordinator and the cyberware records need it; the clinic keeps its 1.x history table `rp_ripperdoc_operations` (one row per finished procedure) |

```text
tunable.set open77_transactions writers rp_ripperdoc:cash+bank+soc+char+stash/stock, rp_economy:cash+bank+soc, rp_inventory, <your other writers>
tunable.set open77_transactions mint3 rp_ripperdoc sys:ripperdoc.supplier * 40      (any free mintN, or appended to one with ";")
ensure rp_ripperdoc
```

No money is ever created: the patient pays the society, the society (or the ripperdoc) pays the
dealer, which burns the money. Expected start lines:

```text
[rp_ripperdoc] coordinator ready (store=sql)
[rp_ripperdoc] boxed implants defined through rp_inventory: 7
[rp_ripperdoc] catalogue arms defined (arms/gorilla_arms, 2 grade(s))
[rp_ripperdoc] history=sql table=rp_ripperdoc_operations
[rp_ripperdoc] ready: clinics viktor (placed chair), 3 targets, supplier kabuki_chrome, job ripper; recovery: 0 released, 0 to settle
```

Operator console (restricted): `ripper.status` (counters and live procedures), `ripper.seed
[clinic] [item|all] [count]` (boxes into a stock under the dealer's mint rule), `ripper.setup
<playerId>` (the `ripper` job and duty), `ripper.journal` (procedures a restart would settle).

## Config

Everything is in `shared/config.lua` (`RpRipperConfig`).

| Key | Default | Meaning |
|---|---|---|
| `job`, `society`, `fixerJob` | `ripper`, `ripper`, `ripperdoc` | the rp_jobs job, the society paid, the job id in `rp:job:completed` |
| `clinics.viktor.chair.mode` | `placed` | `placed`: this resource's own chair action (its id is still `lie`) plays `chair.profiles` at the chair point; `seating`: a real furniture through open77_seating (`chair.furniture`, optional `chair.spot`) |
| `clinics.viktor.chair.position`, `yaw`, `arrivalRadius` | `-1546.92, 1234.22, 11.6`, `145`, `1.0` | Vik's reclining chair; the body sits on it facing the clinic floor |
| `clinics.viktor.chair.profiles`, `actionLabel` | `seatedsleep`, `seated`; `Sit in the operating chair` | the patient's posture (the first one the server knows is played) and the prompt; the bed postures `lie` / `bedsidelie` only suit a flat bed |
| `clinics.viktor.station` | `-1546.40, 1233.74, 11.6`, yaw `55` | where the ripperdoc stands to operate: on the patient's free left side, 0.7 m from the seat, facing them (the instrument cart is on the right) |
| `clinics.viktor.zone`, `stockCapacityG` | `viktor_clinic`, `60000` | the zone to work in, the stash capacity (30 boxes) |
| `supplier.position`, `yaw` | `-1172.45, 2024.30, 7.764`, `-60` | the chrome dealer, Kabuki Market |
| `supplier.mode` | `mint` | `components`: each box burns its grade's `components` (a future techie's parts) from `componentsFrom` instead of money |
| `supplier.payFrom`, `priceFactor`, `maxCount`, `durationMs` | `society, cash`, `0.6`, `5`, `6000` | who pays an order, the wholesale share, boxes per order, the bar |
| `quote.distance`, `inviteTimeoutMs`, `validMs`, `leashM` | `4.0`, `30000`, `180000`, `25.0` | consent reach and time, how long an accepted quote waits, how far the patient may walk |
| `operation.profiles`, `installTimeoutMs`, `holdTtlMs` | `repair`, `examine`, `tablet2`; `20000`; `600000` | the ripperdoc's pose at the station (the first one the server knows: kneeling with a screwdriver, kneeling, a tablet; no drill workspot), the cyberware answer, the coordinator hold |
| `payFrom` | `cash, bank` | the patient's wallets in order |
| `removalPriceFactor` | `0.5` | a removal's price share; it returns nothing to the stock |
| `buyback.ratio`, `maxCount`, `payFrom` | `0.5`, `5`, `society, cash` | buying boxes from players |
| `cyberpsychosisThreshold`, `cyberpsychosis` | `4`, `drugged` 0.5 for 60 s | the overlay past that many implants |
| `catalogue` | 5 implants, 7 grades | price, duration, the boxed `item` and the platform grade fields per grade |
| `items` | 7 boxes | `implant_box_arms` (Street), `_arms_ind`, `_legs` (Training), `_legs_ath`, `_deck`, `_ice`, `_purge`: 2 kg, illegal unless the holder is a `ripper` |

Prices: Gorilla Arms 1500 (Street) / 3200 (Industrial), Reinforced Tendons 1200 (Training) / 2500
(Athlete), Cyberdeck 2000, Self-ICE 1800, Active Purge 1600 eddies; the dealer charges 60 %.

Every new point carries `measured = false` and its `source`: walk it, read `/pos`, correct it.

## For other resources

```lua
-- after every committed step (server, host-wide)
AddEventHandler("rp:job:completed", function(e) end)
-- e = { job = "ripperdoc", kind = "operation", playerId = <ripperdoc>, ref = <action opId>,
--       data = { action = "install" | "remove", implant = "arms", grade = "street", definition, price,
--                paid, patient, patientSubject, ripperSubject, surgery, clinic } }
-- e = { job = "ripperdoc", kind = "restock", playerId, ref,
--       data = { source = "supplier" | "player", item, count, cost, paidBy, clinic } }
AddEventHandler("rp_ripperdoc:operation", function(ripperId, patientId, action, implantKey, gradeId, price) end)

exports.rp_ripperdoc:isOnChair(playerId)     -- boolean
exports.rp_ripperdoc:implantCount(playerId)  -- integer | nil, reason
exports.rp_ripperdoc:catalogue()             -- { { key, label, slot, definitionId, available, reason, grades = { { id, label, price, durationMs, item } } } }
exports.rp_ripperdoc:procedure(playerId)     -- { id, state, action, implant, grade, price, clinic, ripper, patient } | nil
```

## Limits

- **Exactly once.** An accepted quote mints one coordinator operation id and, from it, the cyberware
  operation id. The surgery accepts exactly one operate action: its `opId` is recorded when the
  action adopts the hold and checked at validate, commit and cancel. A retried commit replays the
  coordinator's receipt and the cyberware framework's idempotent answer; a second press is refused.
- **Restarts.** A hold dies with a restart (the coordinator cancels a stopped resource's holds and a
  server restart forgets them). The clinic keeps a small notebook in `Open77.kvp` (no value in it): a
  procedure that had not reached the implant is released at the next start and both players are
  told; one that was installing is settled from the patient's cyberware record when they are back
  (installed: charged once under `rd.settle:<id>`; not installed after 30 s: released). A wallet that
  cannot pay at that point is logged as unpaid (the implant stays: it is the platform's record).
- **One procedure per clinic** at a time; one stock per clinic.
- **Prompts close together.** The chair and the station are 0.7 m apart: a card answers the nearest
  player. Move `station` if the wrong card shows. The ripperdoc is placed on the station while the
  patient sits in the chair; open77_actions only refuses a placement onto another body
  (`spot_taken`) when that body is not itself held in the chair's action.
- **Seating mode** depends on a furniture id near the clinic (`chair.furniture`) and on
  open77_seating's own prompt; until then the chair is `placed`.
- **Hacking implants** need `open77_hacking`; the record shape of their slots is read loosely.
- **Postures.** The patient plays `seatedsleep` (else `seated`) in the chair, the ripperdoc
  `repair` (else `examine`, then `tablet2`) at the station: each list plays the first profile the
  server's catalogue knows, and a server that knows none runs the action without a pose (logged
  once at start).
- **No society refunds.** A procedure that ends without the implant releases the hold: nothing was
  paid, so nothing is refunded.
