# C4: the street-food stall (`rp_streetfood`) — the second lifecycle example

**Row:** C4 of the world-interaction plan (`wt-world-interaction/docs/world-interaction-plan.md` §4 C:
"Bar/food: furniture, qualified cook action, serving/consumption, optional vending shop. Candidate second
lifecycle example. Hand-item ownership, item/payment commit, both rigs and NPC seating contention"),
§2 step 6, §5.3, §6, §7 decision 5. **Date:** 2026-10-12. **Branch:** `Open2077/open77-rp-examples`
`wi/c4-streetfood`, from `wi/integration` 8109d7d.

**Status: built and tested offline only.** Nothing was deployed, launched, run against a database or seen
in game; no `open77_*` tool was called. **Fact** = read in source or measured by the offline suite;
**inference** = follows from source, not measured; **open** = a decision for the integrator or the owner.
Every sentence about players, props or animations describes what the server asks for, not what renders.

---

## 0. Summary

1. **`rp_streetfood` 0.1.0** (new, opt-in, server-only): cook at a real market grill (catalogue anchor),
   order at the counter in front of it, a **consented hand-over** from cook to customer, **one** rp_economy
   sale (portion + price to the society + tip to the cook), then the customer eats at the counter, on the
   go, or (optional) seated on A1 furniture. Coexists with `rp_bar` (one per venue, README).
2. **Structurally different from C1** on purpose: a *transformation* (inputs burned + dish minted in one
   operation) instead of a yield; deterministic `stash:` stall containers instead of minted `world:`
   crates; **no carry** (hand items are native held items owned by this resource); a **two-player step**
   (Open77.playerInteractions) the B5 single-actor lifecycle does not model; a **player-to-player** sale
   (no mint, no allowlist, no retire step); a **consume** step with an at-most-once side effect in another
   resource (rp_needs); seats as per-operation claimed targets.
3. **Every value move is one coordinator operation with a receipt**: cook, restock, stock-from-pockets
   (B2 `moveAsync`), sale (B3), meal. No reward from a client callback; completion is open77_actions'
   server clock or the platform's interaction completion re-validated on the server.
4. **Offline: 16 tests pass** (`tests/test_c4_streetfood.py`) on the real open77_transactions (final),
   open77_actions, rp_economy and rp_streetfood. Four hand mutations each made a suite fail (§5).
5. **The B5 recipes question** (§8): both examples repeat the same *transacted action* core and the same
   coordinator adapter — extract those as helpers; do **not** extract station/node/counter recipes as a
   declarative DSL yet; the larger gap C4 exposes is a *paired* (two-actor, consented) lifecycle.
6. **Changes outside the resource:** one additive line in `rp_jobs/shared/config.lua` (the `cook` job,
   civil) and its README row. Library/API needs in §7, none made here.

## 1. Files

| File | Role |
|---|---|
| `rp_streetfood/open77.lua` | manifest: `auto_start false`, server scripts only, 5 permissions, 7 dependencies |
| `rp_streetfood/server/config.lua` | stalls (catalogue anchors with sources), items, menu, recipes, profiles, seats, serve/payment, seed |
| `rp_streetfood/server/model.lua` | pure rules: stall accounts, cook / restock / meal lines, dish choice, sale spec, tips, texts |
| `rp_streetfood/server/ledger.lua` | **the** coordinator adapter (export names in one table) |
| `rp_streetfood/server/ports.lua` | every other cross-resource call and native |
| `rp_streetfood/server/service.lua` | hooks, tickets, the hand-over and its sale, meals, hand items, seats, sweep |
| `rp_streetfood/server/main.lua` | hook exports, boot, events, `/streetfood`, `streetfood.*` console |
| `rp_streetfood/README.md` | operator guide + author walkthrough |
| `rp_jobs/shared/config.lua`, `rp_jobs/README.md` | the `cook` job (one line), the table row and counts |
| `tests/test_c4_streetfood.py`, `tests/compat/streetfood_world.lua`, `tests/compat/streetfood_scenarios.lua` | the offline suite (new files; shared harness untouched) |

## 2. Decisions taken, and why

| # | Decision | Why |
|---|---|---|
| D1 | Venue = the **food court** (z 115): grill = pedestrian spot row 9594 (`amb_704dff_cook`, a vanilla cook at a market grill), counter = row 1144 (`stand_ground`, 1.45 m in front, facing it) | the brief asked for catalogue positions; this is the only `amb_704dff_cook` spot with a customer spot in front of it near measured seats; the A3/A1 runs already lead the lab there. Kabuki row 7736 is a disabled sample (its counter is arithmetic). A test re-reads `spots-generated.lua` and checks the config against rows 9594 / 1144 / 7736. |
| D2 | Stall custody = two **deterministic `stash:` accounts** per stall (`stash:sf.<stall>:pantry`, `:pass`) | a stall is fixed: no minting, no listing, no metadata record, no boot recovery (C1 needed all four for crates). The part after the last colon lets an operator grant exactly `stash/pantry+stash/pass`. |
| D3 | Cook = **one reservation** of the exact final lines (inputs `pantry → sys:streetfood.kitchen`, dish `sys:streetfood.kitchen → pass`), committed unchanged | the commit then has no external side effect: any crash window conserves by construction (no node charge to spend afterwards, unlike C1's D7). Empty pantry / full pass refuse before the bar. |
| D4 | The hand-over = **Open77.playerInteractions `give` with consent**, started by an open77_actions prompt (*Serve the next order*) whose commit hook only makes the offer | B5's lifecycle is single-actor; the platform already reserves both players, asks consent and cancels on death/vehicle/separation. This resource adds what neither does: the portion promised to an open offer, the order marked as offered, the cook's epoch re-checked at completion, the offer withdrawn on the epoch event, a lost-offer sweep. |
| D5 | Payment = **one rp_economy `sale`**: portion from the stall container into the buyer's pockets, `payees = { society price, cook tip }`; op id minted at the offer; `authorize(opId, "rp_economy", { stall container, char:<buyer> })` | plan decision 5 (one economy). Player-to-player: no money is created, so no allowlist entry and no mint cap. The grant keeps rp_economy at `cash+bank+soc` under least-privilege writers. Stackable dishes fit `sale` (no B3-2 instance-line need). |
| D6 | Hand items = **resource-owned native held items** (`Open77.heldItems`), soda only | the only food/drink records the platform documents as working are the can/bottle/cigarette/phone (`wiki/rp-animations.md`); a held item survives animations and suppresses the walking layer's default, so `drink_walk` sips the same can. It is a projection: custody is the coordinator's. Food is not drawn in hand (no documented record). |
| D7 | Meals = one reservation `char:<subject> → sys:streetfood.eaten`, committed after the bar; `rp_needs:apply` **at most once** (in memory per op id, only while the same subject holds the seat) + event `rp_streetfood:consumed` | rp_needs has no idempotent "apply by op id"; skipping after a restart is safer than doubling. The event is the documented hook for other effects. |
| D8 | Three meal places: counter (`amb_fd31d1_stand_market_grill` at the counter anchor: the vanilla "buy and eat from grill" customer), on the go (`takeout` for food, `drink_walk` for drinks), seated (the seat's own pose) | the counter profile is one of the four the integrator measured on players; the walking drink keeps locomotion and the hand item; a seated meal has no eating twin yet. |
| D9 | Seating optional (convar `rp_streetfood_seating`), provider "stall": A1 furniture ids → open77_actions targets, poses refreshed from `open77_furniture:get` | B6 has published no export (its worktree carries no seating resource on 2026-10-12). Seats as **action targets** give per-operation one-winner claims; the library's `claim` export would not (§7 B5-a). NPC occupancy is not handled (B6). |
| D10 | Restock = operator/lab mint from `sys:streetfood.supplier` (capped by a mint rule) + cooks stocking from their pockets (B2 `moveAsync`) | B3 has no atomic "society buys goods" export (§7 B3-b); a two-step charge-then-mint would need its own recovery. |
| D11 | Orders and offers are memory only | they are intent, not value: a restart forgets them and loses nothing durable (tested). |
| D12 | Coordinator op ids `sf.<kind>:<newOpId>`, minted per business step and kept for its retries | never derived from a client value; open77_actions' op ids are not reused as durable ids (C1 finding B5-1, now fixed upstream). |

## 3. The loop

```text
cook   grill target: cook_<recipe>  ── reserve: inputs pantry→kitchen + dish kitchen→pass (held) ──
       10-12 s, amb_704dff_cook at the grill anchor ── commit (one op) | cancel / settle
order  counter target: order_<dish> ── `order` gesture ── ticket { stall, subject, dish, tip } (memory)
serve  grill target: serve ── offer: oldest ticket in reach, portion free (count − held − promised) ──
       promise portion, mark ticket, cook holds the can (drinks) ── playerInteractions.request(give, consent)
         declined / timeout / separated / epoch moved ─► drop offer: release promise + hand, nothing paid
         completed ─► eligible{ cook, duty, epoch = captured } ─► authorize rp_economy ─► sale (one op)
           committed (or replayed) ─► ticket closed, can from the cook's hand to the customer's
           in_doubt ─► sweep: rp_economy:status ─► finish once | drop
eat    counter target eat_counter | seat target eat_seat_<profile> | eat_go | drink_go ──
       reserve: one portion char→eaten (stationary meals put the hand item away) ──
       commit (one op) ─► rp_needs:apply once, rp_streetfood:consumed, hand item released
stock  grill target: stock ── rp_inventory:moveAsync(pockets → pantry), one op
```

Where a portion is: on the pass (`stash:sf.<stall>:pass`, cooked) or in the pantry (resold stock), then
in the buyer's pockets (`char:<subject>`), then journaled into `sys:streetfood.eaten`. Nothing else.

## 4. Failure semantics (what each window leaves behind)

| Window | Outcome | Test |
|---|---|---|
| cook: store never got the commit | fenced `aborted`; `failed store_unavailable`; nothing used, no dish | `crash_windows` 1 |
| cook: commit landed, ack lost | fence finds it: committed once | `crash_windows` 2 |
| cook: coordinator dies, commit executes detached | `in_doubt`; the sweep settles committed: used once, dish once | `crash_windows` 3 |
| cook: coordinator dies, commit discarded | `in_doubt`; fenced: nothing | `crash_windows` 4 |
| meal: ack lost / coordinator dies detached | eaten once, needs once, one `consumed` event | `crash_windows` 5, 5b |
| sale: coordinator dies with the sale queued | rp_economy settles it; the dish moved exactly when the money did | `crash_windows` 6 |
| sale: rp_economy answers `in_doubt` | the offer waits in `sales`; the sweep finishes it once from `rp_economy:status` | `payment` |
| empty pantry / full pass / nothing to eat | `failed` at stage `reserve`, never presented | `refusals` |
| death / X / vehicle during a cook or a meal | `cancelled`; reservation released at once (not at expiry) | `cancellations` |
| two cooks, one grill | `target_claimed`, nothing held | `two_cooks_one_station` |
| one portion, two offers | the second cook gets `no_order_ready`; a decline frees the portion | `one_portion` |
| decline / invite timeout / clock-out while waiting / clock-out during the hand-over | nothing paid; promise and hand item released | `customer_declines` |
| broke customer | `insufficient_funds`, nothing moves | `payment` |
| sale replayed (same request, after an rp_economy restart) | `replay=true`, paid once | `payment` |
| rp_streetfood restart mid-offer | the platform cancels the offer: nothing paid | `cancellations` |
| server restart | pantry / pass / pockets / cash intact; orders forgotten; the loop resumes | `restart` |
| forged intent (cook at the counter), civilian at the grill, forged completion event | `invalid_target`, `no_job`, ignored | `refusals` |

## 5. Offline tests

```text
python -m unittest discover -s tests -p "test_c4*.py"     # 16 tests
```

**2026-10-12: 16 tests, OK, about 0.9 s** (KeraLua 1.4.9 `lua54.dll` through ctypes, Python 3.12), against
the final coordinator in `wt-world-interaction/resources/system/open77_transactions` (feat/world-interaction
83f8ab7b, which merged `wi/a13-coordinator`) and its `open77_actions`.

What runs for real: open77_transactions (model, policy, memory store in deferred mode, coordinator,
`server/main.lua` with its exports, work queue and tunables), open77_actions (engine, claims, carry, main),
rp_economy 2.0.0, rp_streetfood. Shims stand in for the **public exports** of rp_jobs (B4 contract incl.
`epoch`), rp_inventory (`define`, `backend`, `moveAsync`, `addAsync`), rp_needs (`apply`) and
open77_furniture (`get`, `status`, with the catalogue's poses). Fakes model the natives, including the
documented player-interaction lifecycle (offered → active → completed, cancelled on decline, timeout,
separation, death, disconnect, owner stop) and native held items (one per player, owner-scoped).

| Test | Shows |
|---|---|
| `happy_path` | strict writers; cook: meat −2, sauce −1, skewer on the pass; order with tip 2; serve; consent; **one sale**: buyer −20, `soc:cook` +18, cook +2, skewer into the pockets, ticket closed; eat at the counter (hunger +30 once); soda resold from the pantry: the can in the cook's hand during the offer, in the customer's after, `drink_walk` played with that can, released after; stocking 2 buns; conservation of every ingredient and dish; every op balanced |
| `two_cooks_one_station` | simultaneous cook intents: one `committed`, the other `target_claimed` holding nothing; stocking while grilling (no claim); off-duty → `off_duty` |
| `one_portion` | one skewer, two orders, two cooks: the second offer is `no_order_ready`; after a decline the other cook sells it |
| `customer_declines` | decline, soda decline (hand emptied), invite timeout, clock-out while waiting (`stale_job_epoch`, withdrawn), epoch moved during the hand-over (completion refused); 0 sales, nothing promised left |
| `payment` | broke buyer refused, nothing moves; paid sale replays (same request; after an rp_economy restart) with 0 extra paid; lost ack paid once; rp_economy `in_doubt` finished by the sweep once |
| `refusals` | empty pantry, full pass, no dish (food and drink) refused at reserve, never presented, pantry unchanged; serve with no order; civilian `no_job`; forged `invalid_target`; forged completion ignored |
| `crash_windows` | the §4 rows for the cook (4 windows), the meal (2) and the sale (1); ledger agrees after each |
| `cancellations` | death, X, vehicle: cancelled, reservations released at once; rp_streetfood restart mid-offer; a dish bought before the restart eaten after it (`takeout`) |
| `seating` / `seating_off` | 3 seats from A1 (barstool off), poses from open77_furniture; one winner per seat; the pose played at the catalogue transform; off by default |
| `restart` | pantry, pass, pockets and cash survive; orders forgotten; the loop resumes |
| `lab_console` | the loop from `streetfood.lab.*` with explicit ids, including a seated soda; state / stall / status lines |
| sources | no BOM, Lua 5.4 compile, manifest opt-in and least privilege, the `cook` job exists, the stall anchors equal the catalogue rows |

**Hand mutations** (each run once, then reverted): no reservation release in the cancel hook →
`cancellations` fails; no grant to rp_economy (strict writers) → `happy_path` fails; no epoch at completion
→ `customer_declines` fails; no portion promise → `one_portion` fails. A runtime check of every scenario
found no read or write of an undefined global in rp_streetfood.

**Other suites on this branch:** `test_compat*` without inventory 35 OK, `test_a9*` 23 OK.
`test_compat_inventory.py` 14 errors/failures and `test_held_actions.py` (no `lupa`) are pre-existing on
`wi/integration` (the inventory suite was written against the coordinator prototype; `wi/reconcile-a13`).

Not established offline: anything in game (poses, the hand-over presentation, hand items, prompts, FPP,
timing on a live tick, real event payloads), SQL on MariaDB, the real rp_jobs / rp_inventory / rp_needs
behind their exports, NPC occupancy.

## 6. Two-client test script (integrator)

Lab profile: two clients A and B, crowd stopped at the food court (world suppression: the grill and the
seats are crowd spots), the A4 `Open77RP.archive` (`E9E64F41…`) for `amb_704dff_cook` /
`amb_fd31d1_stand_market_grill`. Hash what runs (DLL, archives, this branch's commit). After any `ensure` of
a client-distributed resource, reconnect the clients.

**Setup**

1. `resources.load` as README "Enable it", convars `rp_inventory_backend transactions`,
   `open77_actions_trace 1` (and `rp_streetfood_seating 1` for Run 6); coordinator tunables: `writers` as the
   README (or `*`), `mint1 = rp_streetfood sys:streetfood.kitchen * 600; rp_streetfood
   sys:streetfood.supplier * 5000; rp_inventory sys:* * 2000; rp_economy sys:* money 1000000`. Expect the
   three start lines of the README.
2. A and B in the world (`worldReady matched pristine transition`, `alive=yes`), teleported to the food
   court (Warden teleport + bring, never `/goto`): A on the grill (-397.6, 715.1, 115.0), B on the counter
   (-398.9, 715.8, 115.0).
3. `streetfood.lab.setup <A>` → `setJob … true`, `setDuty … true`; `streetfood.lab.seed food_court` →
   `restock sf.restock:… committed`.

**Measure first (no value moves):** stand A on the grill and B on the counter: `/pos`, screenshot both from
the other client. Is there a grill in front of A (the cook profile needs it)? Paste corrections into
`server/config.lua` and flip `measured`.

**Run 1: the loop by prompts (A cook, B customer)**

| Step | Who does | Expect in the server log | Screenshot (the other client) |
|---|---|---|---|
| grill | A: E "Grill a skewer" | `[actions] op=… state=presenting … action=rp_streetfood:cook_skewer … playback=…`; ~10 s later `cook sf.cook:… committed: sf_skewer` | A turning meat at the grill, spatula; A's bar |
| tip + order | B: `/streetfood tip 2`, E "Order Grilled skewer (18 €$)" | `order 1 at food_court: skewer by <B> (tip 2)` | B's order gesture |
| serve | A: E "Serve the next order" | `offer <id>: <A> -> <B>, sf_skewer 18+2, sale sf.sale:…` | — (B's chat: the offer line with `= 20 €$`) |
| consent | B: `/interaction accept` (or the invitation) | `[rp_economy] sale sf.sale:… by rp_streetfood: 3 line(s)`; `sale sf.sale:… committed: … price 18 to soc:cook, tip 2 …` | the give presentation on both bodies |
| eat | B: E "Eat at the counter" | `meal sf.meal:… committed: sf_skewer (counter)` | B eating from the grill at the counter |
| soda | B orders a soda, A serves, B accepts, B `/streetfood drink` | `sale … sf_soda …`, `meal … sf_soda (go)` | the can in A's hand during the offer, in B's after; B sipping while walking (FPP and TPP on B) |
| stock | `streetfood.lab.give <A> sf_bun 2`; A: E "Stock the pantry…" | `stock sf.stock:… : 2 Soy bun` | — |
| state | `streetfood.lab.state <B>`, `streetfood.lab.stall` | pockets, cash, receipts; pantry/pass counts | — |

Swap A and B, repeat with the female rig as cook, then as customer (one run each).

**Run 2: contention.** `streetfood.lab.setup <B>` (B is a cook too). Both press E "Grill a skewer" at once →
one `presenting`, the other refused ("Someone is already using this."). Then one skewer, B orders, A
serves; B (as a second cook) tries "Serve the next order" → "No order is ready…".

**Run 3: refusals and consent.** B declines (`/interaction decline`) → `offer … dropped: declined`; let an
offer time out (20 s) → `dropped: timeout`; A `/service` (clock out) while an offer waits → `dropped:
stale_job_epoch`; empty the pantry (`streetfood.lab.stall` to read it, cook until refused) → "short of an
ingredient", no bar; fill the pass (8 skewers) → "The pass is full", no bar.

**Run 4: payment.** B `/pay <A> <all of B's cash>` (broke), A serves, B accepts → `offer … dropped:
insufficient_funds`, the skewer still on the pass. Stop the database (or `open77_transactions`) during a sale: refused or replayed,
never paid twice; `streetfood.status` shows the doubt count going back to 0.

**Run 5: cancellations.** Kill A mid-grill (`state=cancelled reason=dead`, `streetfood.lab.stall`: nothing
held); X on the bar; B walks away mid-meal at the counter; `ensure rp_streetfood` while an offer waits (the
offer disappears, nothing paid; reconnect the clients).

**Run 6: seating** (`rp_streetfood_seating 1`, restart the resource). `streetfood.lab.stall` lists 3 seats
with `open77_furniture furniture-1-17f2d5e1987b`. B buys a skewer, walks to the chair by the grill (5.6 m),
E "Eat seated" → seated on the chair; A (customer for this run) presses E on the same seat → refused. With
the crowd **on**, watch whether an NPC sits on a stall seat first and record it (NPC occupancy is B6's).

**Run 7: durability.** With dishes on the pass and one in B's pockets: restart the server. Expect the same
counts (`streetfood.lab.stall`, `streetfood.lab.state <B>`), no open order; B eats the old skewer.

**Performance (A12):** both clients at the food court: record frame percentiles; this resource has no
periodic world query and one 2 s sweep; it declares 2 targets (5 with seats).

## 7. Library and API changes needed (none made here)

| Id | Owner | Change | Blocking? |
|---|---|---|---|
| B6-1 | B6 seating | exports to claim a seat by A1 furniture id **with NPC occupancy**, its pose and arrival radius, and release it; then this resource's "stall" provider becomes a B6 provider | no (seating is optional) |
| PED-1 | open77_pedestrians / B6 | a veto or occupancy export for **job station anchors** too (the grill is crowd-spot row 58918), not only seats | no (lab: stop the crowd) |
| B5-a | open77_actions | `claim(bucket, key, ttl)` holds as `res:<owner>`, so one resource claiming one key for two of its players gets the **same token** back (re-acquire renews): it cannot arbitrate between its own players. Add a holder tag, or document; this resource uses per-operation target claims instead | no |
| B5-b | open77_actions | `animation.item` / `itemContact` in action definitions (normalizeAction drops them): a dish-specific record for `drink_walk` / `hold_item_walk` | no (profile default + held item) |
| B5-c | open77_actions | per-choice `data` on a target's actions (the prompt cannot say which dish): one action per menu item / seat profile today | no |
| B5-d | open77_actions | a **paired** operation (two actors, consent, both-sided validation and epochs, one commit) — the ~220 lines this resource writes around Open77.playerInteractions; C7 (treatment) would reuse it | no; decide after C7 |
| B3-a | rp_economy | `sale` with a reserve/commit split, or accepting a caller-held reservation: the portion offered is promised in this resource's memory, not held in the coordinator | no |
| B3-b | rp_economy | a purchase: goods from a supplier `sys:` + price from a payer (a society), one operation, for restocks paid by the till | no |
| B8-a | B8 static audit | `test_adapter_surface_is_frozen` does not see consumers that call through `sync(`/`async(` helpers (rp_streetfood, rp_salvage): rp_jobs `eligible/workEpoch/setDuty/setJob`, rp_economy `sale/status/balanceOf`, rp_inventory `define/backend/moveAsync/addAsync`, rp_needs `apply` are uncounted | no |
| A1-a | A1 furniture | the catalogue still marks the barstool family `refused` (with `barsit`) although `amb_f6ac22_sit_barstool_bar` + radius 1.0 is measured (ledger, A1 #3): regenerate so the barstool seat can be enabled from data | no |
| AS-1 | asset pipeline | native item records for food (a takeout box, a skewer) checked with `heldItems.hold` and a matching grip; a player twin of `sit_chair_asian_takeout` (288 spots) for seated eating | no |
| B4-a | rp_jobs (B4) | confirm the `cook` job line (civil, salary as `barman`) | no |
| config | coordinator tunables | `writers` and the two `mint` rules of the README | per server |

## 8. Comparison with `rp_salvage` (C1): what is shared, what differs — input for the B5 recipes decision

Read-only comparison against `wi/c1-salvage` e39d145 (`rp_salvage/server/*.lua`, `docs/world-interaction/c1-salvage.md`).

**Shared (copied structure — the candidates for extraction)**

| Piece | C1 | C4 | Verdict |
|---|---|---|---|
| Coordinator adapter (`ledger.lua`: promise/sync wrappers, `export_*` → `in_doubt`/`coordinator_unavailable`, prefixed `newOpId`, `settle`) | 155 lines | 149 lines, the same shape | **extract** as a helper owned by open77_transactions (both resources wrote it independently) |
| Transacted action: `reserve` hook = coordinator reserve; `commit` hook = commit, `in_doubt` → doubts; `cancel` hook = cancel, or settle when the reason is `in_doubt`; after-commit idempotent by tx op id; sweep settles doubts | `reserveWork/commitWork/cancelWork/settleWork/afterWork` | `reserveCook/reserveMeal/commitReserved/cancelReserved/settle/afterCommit` | **extract** as a helper that runs in the author's VM (the coordinator ties an operation to its caller, so the library itself must not call it: B5 §4.3); input = a pure line builder + an after-commit callback |
| Eligibility + epoch guard on actions (`rp_jobs:eligible`, `rp_jobs:workEpoch`) | yes | yes | already declarative; nothing to extract |
| Refusal texts with a per-player toast cooldown, receipts ring for the lab | yes | yes | a small helper, optional |
| Lab console with explicit player ids (`setup`, `clock`, `state`, per-step commands) | yes | yes | a convention, not code |
| Op ids minted by the job resource per business step, reused on retries | yes | yes | part of the helper |

**Different (what a recipe must not freeze)**

| Aspect | C1 salvage | C4 street food |
|---|---|---|
| Value shape | yield: mint into a capacity envelope, final lines narrowed at commit (roll) | transformation: burn inputs + mint output, exact lines reserved = committed |
| Custody containers | minted `world:` holds per crate, metadata record, `listWorld` recovery at boot | deterministic `stash:` per stall, nothing to recover |
| Physical items | carry helper (custody-neutral carry, prop owned by open77_actions), truck slots (A9) | no carry; native held items owned by the job resource, projection only |
| Shared nodes | open77_containers (A6) charges + regrowth | none; station = an action target claim |
| Steps | single-actor only | a **two-actor consented step** (playerInteractions) with its own promise, epoch re-check and lost-offer sweep |
| Sale | NPC buyer (money minted, allowlist entry, then a retire step for the instance token) | player-to-player (`payees` society + tip, no mint, stackable goods, no retire), grant over two accounts |
| Consumption | none | terminal burn + at-most-once side effect in another resource (rp_needs) |
| Prompt data | per-node targets carry the node key | per-choice data impossible: one action per dish / seat profile |
| Seating / furniture | none | A1 poses as claimed targets (B6 pending) |

**Recommendation (for the integrator's B5 decision).** Two different jobs now repeat the same *transacted
action* core and the same coordinator adapter, written twice with the same failure handling — that is the
plan §0.5 trigger, but for **helpers**, not for a declarative station DSL: (1) a coordinator client helper
next to `open77_transactions`; (2) a transacted-action helper the author loads in its own VM (a shared Lua
file; whether a manifest can include another resource's file is **open** — otherwise a generated snippet).
The station/node/cargo/counter shapes differ in containers, custody, value shape and steps; a recipe language
would freeze those differences after two samples. The larger missing piece C4 exposes is a **paired
lifecycle** (B5-d): decide it after C7 (paired treatment) uses the same pattern.

## 9. Research ledger entry for the integrator (to copy)

> **2026-10-12 — C4 street-food stall `rp_streetfood`, built offline (RP pack `wi/c4-streetfood`).**
>
> **Built:** a new opt-in server-only resource: cook at the food-court market grill (pedestrian spot row
> 9594 `amb_704dff_cook`), order at the counter in front of it (row 1144), a consented hand-over
> (Open77.playerInteractions `give`), one rp_economy `sale` (portion from the stall into the buyer's
> pockets, price to `soc:cook`, tip to the cook), meals at the counter (`amb_fd31d1_stand_market_grill`),
> on the go (`takeout`, `drink_walk` with the held can) or seated (A1 furniture as one-winner targets,
> optional), `rp_needs:apply` at most once; stall pantry/pass as deterministic `stash:` accounts; the
> `cook` job added to rp_jobs.
>
> **Facts (offline, real open77_transactions final + open77_actions + rp_economy, KeraLua lua54.dll):** 16
> tests pass: ingredients and dish move in one operation in four crash windows of the cook commit; meals
> eaten once with needs once (ack lost, coordinator death); a sale whose commit is queued at a coordinator
> death moves the dish exactly when the money; one winner per grill and per seat; a promised portion is never
> offered twice; decline / timeout / clock-out (waiting or during the hand-over) pay nothing; a broke buyer
> moves nothing; replayed sales pay once (same request, after an rp_economy restart); rp_economy `in_doubt`
> is finished by the sweep once; pantry, pass, pockets and cash survive a restart (orders do not, by
> design); strict writers work through a two-account grant; the stall anchors equal the catalogue rows.
>
> **Findings:** (1) open77_actions' `claim` export holds as the resource, so one resource cannot arbitrate a
> key between two of its players (B5-a); (2) action definitions drop `animation.item` (B5-b) and target
> choices carry no data (B5-c); (3) two-player consented steps sit outside the B5 lifecycle and cost ~220
> lines (B5-d); (4) B3 `sale` has no reserve/commit split (B3-a) and B3 has no supplier purchase (B3-b);
> (5) the crowd can book the grill anchor (crowd-spot row 58918) and the seats: no veto export (PED-1/B6-1);
> (6) the B8 static audit misses consumers that call through `sync`/`async` helpers (B8-a); (7) the A1
> catalogue still marks the measured barstool twin family `refused` (A1-a).
>
> **B5 recipes input:** shared = the coordinator adapter and the transacted-action core (extract as helpers
> in the author's VM); different = value shape, containers, carry vs hand items, paired step, sale shape,
> consumption: no declarative station DSL yet; a paired lifecycle after C7.
>
> **Not done:** anything in game (§6 of c4-streetfood.md), SQL, both rigs, FPP, NPC occupancy, performance.

## 10. Open items and risks

- **Inference:** the counter profile (`amb_fd31d1_stand_market_grill`, a customer "buy and eat from grill")
  played at a `stand_ground` anchor 1.45 m from the grill may stand the customer in the grill's mesh or too
  far from it; Run 1 decides, and a measured offset goes into the counter position.
- **Inference:** the give presentation with a held can in the cook's `WeaponRight` may hide or double the
  can; the held item is a projection, the sale does not depend on it.
- **Risk:** a cook who stays in the grill workspot cannot be offered to (one action per actor): serving waits
  for the cook to finish grilling.
- **Risk:** orders live in memory: a restart forgets them (no value lost; customers order again).
- **Open (owner):** the tip goes entirely to the serving cook, the price entirely to the society; a cook's
  commission or a split with the grill operator is a config/payees change.
- **Open:** a vending shop (plan C4 "optional vending shop") is not built: A7a (device shop adapter) owns
  that path; the food court has vending machines at z 127 (crowd-spot rows 58999/59023…).
