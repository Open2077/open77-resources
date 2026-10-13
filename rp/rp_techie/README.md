# rp_techie

Adds the techie job: buy salvage parts from a scrapper or a parts dealer, strip them at a real workbench into components that wait on the workshop tray, assemble weapon mods and cyberware components, and sell them to a shop, to another player with consent, or to a ripperdoc.

- **Docs:** [Build a job: prompts, animations, items and pay](https://open2077.net/docs/world-interaction), [Durable transactions](https://open2077.net/docs/transactions), [Player interactions](https://open2077.net/docs/player-interactions)
- **Starts:** with `ensure rp_techie` (it declares `auto_start false`)
- **Needs:** `open77_transactions`, `open77_actions`, `open77_player_interactions`, `open77_notifications`, `rp_jobs`, `rp_inventory`, `rp_economy`; `open77_uikit` for the bench menu (optional)
- **Runs on:** server

## How to play

**The techie** (rp_jobs job `techie`, on duty with `/service`) works at the Kabuki west workshop,
on the upper floor west of Kabuki Market.

1. **Get parts.** At Sparks' counter (the parts dealer, 4.2 m from the workbench) **E**, **F** and
   **R** read *Buy 3 Scrap metal (75 eddies)*, *Buy 2 Copper wire (90 eddies)*, *Buy 1 Data chip
   (220 eddies)*: a 2 second hand gesture, the parts land in your pockets and the price leaves your
   cash. Or buy from a scrapper standing next to you: `/techie buy <their id> scrap_metal 3 66`
   sends them an offer; when they accept, the parts and the money change hands at once.
2. **Strip (stage 1).** At the **workbench** **E** opens *Work at the bench* (every recipe of the
   bench, with what you lack); **F**, **R**, **Y** are the first three recipes. *Cut scrap into
   alloy plates* kneels you with a welding torch for 8 s (3 Scrap metal become 2 Alloy plates);
   *Strip copper into a wiring loom* kneels you with a screwdriver (2 Copper wire, 1 Wiring loom).
   At the **electronics bench** a standing drill turns 1 Data chip and 1 Copper wire into a Logic
   board. Stage 1 takes the parts from your pockets and leaves the components on the **workshop
   tray**, shared by the workshop's benches.
3. **Assemble (stage 2).** From the tray into your pockets. At the workbench (kneeling, drill):
   *Suppressor kit* (2 plates + 1 loom), *Extended magazine kit* (3 plates), *Reflex sight kit*
   (1 plate + 1 logic board, grade 1). At the electronics bench (standing, tablet): *Servo
   actuator* (2 plates + 2 looms), *Neural link chip* (2 logic boards + 1 loom, grade 1), *Optic
   lens array* (1 logic board + 1 plate + 1 loom, grade 2).
4. **Sell.** Next to **Wilson** at the 2nd Amendment stall (East Row, under the stairs) **E** *Sell
   to 2nd Amendment* sells every weapon mod in your pockets; **Dr. Osei** at Med-Point buys every cyberware
   component. One sale: the shop price, 10 percent of it to the `techie` society. To a player:
   `/techie sell <their id> <item> [count] [price]`; they accept the hand-over and pay from their
   cash. Ripperdocs buy cyberware components this way (`tch_cw_*`).

During a stage you see the pose and a progress bar (**X** cancels). Nothing is taken before the
bar starts, and nothing moves unless the bar ends: a stage burns its inputs and creates its outputs
in one operation. A refusal is a chat line and a toast, for example *You do not carry the parts for
that. Missing: 3 Scrap metal (have 0).*, *The tray is short of components for that: strip some
parts first.*, *Your grade is too low for that recipe.*, *Someone is already working at that bench.*
A success reads *Cut scrap into alloy plates: 2 Alloy plate on the tray of Kabuki west workshop.*

**A scrapper** (any player) sells salvage from their pockets to an on-duty techie:
`/techie sell <techie id> scrap_metal 3 66`, or accepts the techie's `/techie buy` offer.

**A buyer** (any player, a ripperdoc too) sees the offer card *Tech: 1 Suppressor kit for 300
eddies* (and reads in chat *Tech offers to sell you 1 Suppressor kit for 300 eddies. Y to take it
and pay, N to decline.*), accepts with **Y** (or `/interaction accept`) or declines with **N**; on
accept both play the hand-over and the item lands in their pockets as the cash leaves. A techie's
`/techie buy` shows the scrapper *Tech: buys 3 Scrap metal from you for 66 eddies*. Declining,
walking away or letting the invitation run out moves nothing.

**Someone watching** sees the techie kneel or stand at the bench while the stage runs. A second
techie who presses **E** on that bench is told *Someone is already working at that bench.*; the
other bench of the workshop stays free.

Other commands: `/techie` (help), `/techie recipes`, `/techie craft <recipe>` (at a bench),
`/techie tray`, `/techie prices`, `/techie cancel` (withdraws your pending offer).

## Setup

1. **rp_jobs knows the job.** rp_jobs ships the `techie` job (`rp_jobs/shared/config.lua`,
   `RpJobsConfig.Jobs`: civil, joined at the agency, 180 / 260 / 360 / 500 per payroll). A server
   with its own rp_jobs table adds it back, or runs the job under an existing rp_jobs job with the
   convar `rp_techie_job` (below). The boot logs `rp_jobs does not know the job 'techie'` when the
   job is missing.

2. **resources.load**, in this order (`rp_salvage` before `rp_techie` when it runs: it owns
   `scrap_metal` and `copper_wire`; without it rp_techie defines them itself):

   ```text
   open77_transactions, open77_animations, open77_props, open77_interactions, open77_uikit,
   open77_actions, open77_player_interactions, open77_notifications,
   rp_jobs, rp_inventory, rp_economy, rp_salvage (optional), rp_techie
   ```

3. **Coordinator tunables.** With `writers *` nothing is needed for writers. With a writers list,
   add rp_techie's entry to it (it writes the workshop trays, pockets and cash):

   ```text
   tunable.set open77_transactions writers rp_techie:stash/tray+char+cash, rp_economy:cash+bank+soc, rp_inventory
   ```

   Mint rules: one per stage output, one per dealer part; the cap per hour is the supply. A
   tunable holds at most 256 characters, so the twelve rules take three slots. Use three `mintN`
   no other job uses (here 3, 4 and 5); `techie.mintrules [first slot]` on the console prints these
   lines from the config, numbered from the slot you give:

   ```text
   tunable.set open77_transactions mint3 rp_techie sys:techie.workshop tch_alloy_plate 400; rp_techie sys:techie.workshop tch_wire_loom 200; rp_techie sys:techie.workshop tch_mod_suppressor 60; rp_techie sys:techie.workshop tch_mod_magazine 60; rp_techie sys:techie.workshop tch_mod_sight 40
   tunable.set open77_transactions mint4 rp_techie sys:techie.workshop tch_logic_board 100; rp_techie sys:techie.workshop tch_cw_servo 40; rp_techie sys:techie.workshop tch_cw_neural_link 30; rp_techie sys:techie.workshop tch_cw_optic 30; rp_techie sys:techie.dealer scrap_metal 300
   tunable.set open77_transactions mint5 rp_techie sys:techie.dealer copper_wire 200; rp_techie sys:techie.dealer chip 40
   ```

   A server short of slots caps each account once instead, in one slot:
   `rp_techie sys:techie.workshop * 960; rp_techie sys:techie.dealer * 540` (the sums of the caps
   above; a `*` cap is shared by every item of the account, so one output can use all of it).

   Shop sales go through rp_economy, which needs its usual coordinator rule
   (`rp_economy sys:* money <cap>`) and a money budget for rp_techie: rp_economy ships it
   (`EconomyConfig.mint.callers`, `rp_techie = 30000`). Without it a shop sale is refused and the
   techie reads *The shop cannot pay yet (operator: rp_economy mint budget for rp_techie, README
   Setup).* A server that cannot change rp_economy pays the shops through the coordinator instead:
   convar `rp_techie_shop_payment ledger`, writers `rp_techie:stash/tray+char+cash+soc`, and the rule
   `rp_techie sys:techie.shop money 60000` appended with `;` to the last techie slot (`techie.mintrules`
   prints it there once the convar is set).

4. **Convars.** `rp_inventory_backend transactions` (pockets must be coordinator accounts).
   Optional: `rp_techie_job <job>` (default `techie`), `rp_techie_society <society>` (default
   `techie`), `rp_techie_shop_payment economy|ledger` (default `economy`).

5. **Start.** `ensure open77_transactions`, `ensure open77_actions`, then `ensure rp_techie`.
   Expected lines:

   ```text
   [rp_techie] coordinator ready (store=sql)
   [rp_techie] items defined through rp_inventory: 9
   [rp_techie] ready: workshops kabuki_west, 5 targets, shop payment economy (job techie)
   ```

### Console (restricted: console or ACL `command.techie.*`)

| Command | Effect |
|---|---|
| `techie.status` | counters, open offers, operations still settling |
| `techie.mintrules [first slot]` | the mint rules of the current config, one `tunable.set` line per slot (256 characters each), numbered from the first slot (default 3) |
| `techie.lab.setup <pid> [grade]` | job `techie` at that grade, duty on |
| `techie.lab.clock <pid> on\|off` | duty |
| `techie.lab.give <pid> <item> <count>` | items into the pockets (rp_inventory `addAsync`) |
| `techie.lab.craft <pid> <recipe> [workshop]` | the request the bench makes (any recipe of the bench type) |
| `techie.lab.buy <pid> <item> [dealer]` | the dealer prompt's request |
| `techie.lab.shop <pid> <gunshop\|medpoint>` | the shop prompt's request |
| `techie.lab.offer <sellerId> <buyerId> <item> [count] [price] [seller\|buyer]` | a consented trade; the last word says who asked; the other player accepts |
| `techie.lab.state <pid>` | techie items in the pockets, cash, society, pending offer, receipts |
| `techie.lab.tray [workshop]` | the tray (work in progress) and the benches |

No command accepts an offer for a player: consent stays theirs.

## Config

Everything lives in `server/config.lua`.

| Key | What it sets |
|---|---|
| `job`, `society`, `jobId` | the rp_jobs job (convar `rp_techie_job`), the society of the shop share, the job id of `rp:job:completed` (`techie`) |
| `items`, `weightsG` | the nine `tch_*` items (`rp_inventory:define`), grams per unit |
| `parts`, `partDefinitions` | the salvage parts (`scrap_metal`, `copper_wire`, `chip`); the first two are defined here only when nobody else did |
| `recipes`, `recipeOrder` | data per recipe: `stage` (strip, assemble), `bench`, `animation`, `durationMs`, `minGrade`, `inputs` (`item`, `count`, `from` pockets or tray), `outputs` (`item`, `count`, `to` tray or pockets) |
| `animations`, `benchTypes` | the pose per animation key, the bench types |
| `workshops` | per workshop: `trayCapacityG` and its benches (`type`, `position`, `yaw`, `arrivalRadius`); the tray is `stash:tch.<workshop>:tray` |
| `dealers` | the parts dealer counters and their lots (`item`, `count`, `price`) |
| `shops`, `shopPayment`, `societyShare` | the NPC buyers (`accepts`), economy or ledger payment, the society's share |
| `prices` | per item: `shop` (what a shop pays), `suggested` (a trade's default price) |
| `trade` | hand-over distances and timeout, `maxCount`, `maxUnitPrice`, `offerCallers` (resources allowed to call `offer`) |
| `mintCaps` | the caps `techie.mintrules` prints |

Points (`measured = true` once walked in game):

| Point | Position, yaw | Source |
|---|---|---|
| Workbench `kabuki_west_kneel` | -1238.89, 1998.18, 12.010, 155.0 | inside the scaffold, 1.2 m beside the game's own kneeling worker (spot row 37034) |
| Electronics bench `kabuki_west_stand` | -1240.88, 1999.11, 12.010, 155.0 | the wall panel at the end of the workbench scaffold |
| Parts dealer `dealer_kabuki_west` | -1235.566, 2000.680, 12.077, -151.0 | pedestrian spot row 32163 (`amb_2ced53_stand_ground`) |
| Wilson, 2nd Amendment `shop_gunshop` | -1160.02, 2017.85, 7.76, -21.2 | beside rp_shops' East Row ring, facing Wilson |
| Dr. Osei, Med-Point `shop_medpoint` | -1224.52, 1990.59, 7.80, 165.3 | beside rp_shops' Med-Point ring, facing Dr. Osei |
| Gallery workshop (off) | -1172.625, 2071.664, 12.060 / -1171.758, 2079.524, 11.982 | rows 39487 and 31019 |

### Exports and events for other jobs

```lua
exports.rp_techie:components()          -- the cyberware components a ripperdoc buys, stable order:
                                        -- { { id, label, category, weightG, shopPrice, suggestedPrice } }
exports.rp_techie:products()            -- every product, same shape
exports.rp_techie:catalogue()           -- { parts, intermediates, products, cyberware, recipes }
exports.rp_techie:isComponent(itemId)   -- true for tch_cw_neural_link, tch_cw_servo, tch_cw_optic
-- A consented trade between two connected players (callers listed in trade.offerCallers,
-- rp_ripperdoc by default). It reads the seller's pockets: call it from a thread.
Open77.exports.call("rp_techie", "offer", { seller = techieId, buyer = ripperdocId,
    item = "tch_cw_servo", count = 1, price = 400, initiator = "buyer" }):await()
-- -> { interaction, sale, price, count } | nil, reason; the other player accepts the invitation
```

```lua
AddEventHandler("rp:job:completed", function(e) end)  -- { job = "techie", kind = "strip" | "assemble" | "sell" | "buy_parts", playerId, ref, data }
AddEventHandler("rp_techie:crafted", function(playerId, recipe, outputs, opId) end)
AddEventHandler("rp_techie:sold", function(e) end)     -- { kind = "shop" | "player", seller, buyer?, shop?, items, total, opId }
```

`ref` is the coordinator operation id: an event fires once per committed step, a replayed commit
never fires it again.

### Tests

```text
python -m unittest discover -s tests -p "test_techie*.py"
```

Sixteen offline tests run the real open77_transactions, open77_actions, rp_economy and rp_techie:
the whole loop with strict writers, trades (accepted, declined, a broke buyer, parts bought from a
scrapper, the ripperdoc export, a clock-out), refusals before the bar, cancellations (X, death,
clock-out, walking off, a resource restart), disconnects, a server restart between the two stages,
commit crash windows, both shop payment modes, the bench menu, the console, and the README's
tunable lines parsed by the coordinator's own policy parser.

## Limits

- Poses at the benches, the hand-over presentation and the prompts are checked on the server only.
  The benches and Sparks' counter were walked in game (`measured = true`) and keep the server crowd
  off their points while they exist (`keepCrowdOff`, through open77_pedestrians); the Gallery
  workshop (off) is still anchor data.
- The tray is per workshop and shared: any on-duty techie may assemble from what another one
  stripped.
- A scrapper sells to a techie what is in their pockets. rp_salvage keeps its materials in crate
  holds sold whole to its buyer, so a scrapper needs a way to move them into pockets first.
- Trades between players and dealer purchases write cash through the coordinator (one operation
  with the goods): rp_economy offers no sale between two players' pockets that works under a
  writers list, and no purchase from an NPC seller. Shop sales go through rp_economy.
- Mods and cyberware components are RP items: nothing here fits a mod to a game weapon or installs
  a component, and nothing consumes them yet. A ripperdoc buys them as any player does (a
  techie's `/techie sell`; the `offer` export allows rp_ripperdoc, which does not call it yet), and
  rp_ripperdoc's `supplier.mode = "components"` is the hook that would burn them for implant boxes,
  but no grade of its catalogue lists components today.
- A restart between a commit and its messages skips that step's chat line and `rp:job:completed`
  event, never doubles them. Open offers are forgotten on a restart; nothing is paid.
- A bench shows four choices; the rest of its recipes are in the bench menu and `/techie craft`.
- rp_ferrailleur's `scrap` and `component` are not parts here.
