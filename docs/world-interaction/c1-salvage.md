# C1: the salvage pilot (`rp_salvage`) on the wave-1 libraries

**Row:** C1 of the world-interaction plan (`wt-world-interaction/docs/world-interaction-plan.md` §4 C,
acceptance §5.3, authoring contract §6, decision 5). **Design brief:**
`wt-world-interaction/docs/world-interaction/c1-salvage-design.md`. **Date:** 2026-10-12.
**Branch:** `Open2077/open77-rp-examples` `wi/c1-salvage`, from `wi/integration` 8109d7d.

**Status: built and tested offline only.** Nothing was deployed, launched, run against a
database or seen in game; no `open77_*` tool was called. **Fact** below = read in source or
measured by the offline suite; **inference** = follows from source, not measured; **open** = a
decision for the integrator or the owner. Every sentence about players, props or animations
describes what the server asks for, not what renders.

---

## 0. Summary

1. **`rp_salvage` 0.1.0** (new, opt-in, server-only): clock in at a foreman, cut or pry one of
   rp_ferrailleur's seven wrecks (data reused, code not called), fill a crate, carry it, load it on
   a plated truck, unload it at the buyer, sell it. It runs **instead of** `rp_ferrailleur`.
2. **Every value move is one coordinator operation with a receipt**: work (yield + crate token +
   tool wear), load, unload, sale (materials + seller cash + society share), retire. No reward
   is granted from a client callback; completion is open77_actions' server clock.
3. **Built on the libraries, not beside them:** open77_actions (targets, actions, claims,
   carry, eligibility and epoch guards), open77_containers (wreck nodes: durable charges and
   regrowth), open77_transactions **final wave-1 API** (697e9e2f: `openWorld`, `setMeta`,
   `listWorld`, `authorize`, `metaPatch`, `status(resolve)`), rp_jobs (`setDuty`, `eligible`,
   `workEpoch`), rp_inventory (`define`, `addAsync`), rp_garage (`canAccess` inside rp_cargo),
   rp_cargo (`load`/`unload`/`contents`), rp_economy (`sale`).
4. **One adapter module** (`server/ledger.lua`) holds every call to `open77_transactions`.
5. **Offline: 11 tests, all pass** (`tests/test_c1_salvage.py`), on the real libraries: happy
   path end to end, contention (wreck, crate, truck), full crate, four crash windows of the work
   commit, replayed sale and a sale/crash/restart window, restart with crates on the ground / in
   hands / in a bed, stranger cannot load, cancellations (death, vehicle, job change, disconnect,
   resource restart), the whole loop from the lab console.
6. **Library changes needed** (§7): one blocking config entry (rp_economy mint allowlist), plus
   requests to A6, B5, B3, B2, A9 and the asset pipeline. None was made here.

## 1. Files

| File | Role |
|---|---|
| `rp_salvage/open77.lua` | manifest: `auto_start false`, server scripts only, 4 permissions, 9 dependencies |
| `rp_salvage/server/config.lua` | yard positions (reused data + marked arithmetic), items, loot, prices, actions, crate |
| `rp_salvage/server/model.lua` | pure rules: deterministic roll, tool choice and wear line, quote, crate ids, refusal texts |
| `rp_salvage/server/ledger.lua` | **the** coordinator adapter (export names in one table) |
| `rp_salvage/server/ports.lua` | every other cross-resource call and native |
| `rp_salvage/server/service.lua` | hooks, crates, nodes, load/unload/sale, recovery, sweep |
| `rp_salvage/server/main.lua` | hook exports, boot order, library events, `/salvage`, `salvage.*` console |
| `rp_salvage/README.md` | operator guide + author walkthrough (the D1 example) |
| `tests/test_c1_salvage.py`, `tests/compat/salvage_world.lua`, `tests/compat/salvage_scenarios.lua` | the offline suite (new files; shared harness untouched) |

## 2. Decisions taken against the brief, and why

| # | Brief | Built | Why |
|---|---|---|---|
| D1 | haul crate = an `open77_containers` `world:` container projected as a prop | a coordinator `world:` container from **`openWorld`**; its record (owner, wreck, placement, sale quote) is the container's **metadata**; the ground prop is an **open77_actions carry item**; the bed prop is rp_cargo's | (a) A6's `create` opens `world:<uuid>` through `open`, which the final coordinator refuses (`open` → `invalid_account`, "use openWorld", contract §7.2); (b) a carriable prop must be owned by open77_actions (only a prop's owner may attach it: B5 §10 open point, A6 §12); (c) `setMeta` + `listWorld` now give the durable record A6's registry gave. **A6 is used for the wreck nodes**, which have no coordinator account and need its charges and regrowth. |
| D2 | carry: custody moves to the carrier's `char:` account | **custody-neutral carry**: the crate stays in its hold while carried; custody changes only when its token enters or leaves a bed and when its materials are sold | A13 §6.1, A6 §2 and B5 §5 all prescribe it; moving a 14 kg crate into 40 kg pockets would refuse heavy-handed players, double the operations per carry and make a restart mid-carry a custody question. The carrier is a claim (open77_actions), not an owner. |
| D3 | crate custody → `veh:<plate>:cargo` with the slot in line metadata | the crate's **custody token** (one `salvage_crate` instance, `crate.<hold key>`) moves; the materials never leave the hold | rp_cargo slots instances (A9 §4.1); A13 does not nest containers (A9 §5 "Open"). Materials therefore move exactly twice: minted into the hold at a work, sold out of it. |
| D4 | sale = one B3 `sale` | one `rp_economy:sale` for materials + cash + society share, then a **separate retire** (token → `sys:salvage`, close the hold) | B3 `sale` takes stack lines only, so the token cannot leave in the sale. The quote (op id, total, split, seller) is persisted in the hold's record **before** paying: a crash between sale and retire is found at boot and the crate never reappears (tested). Request B3-2 makes it one operation. |
| D5 | (not specified) | rp_cargo and rp_economy reach the hold through **two-party grants** (`authorize(op, grantee, { hold }, ttl)`) | Neither needs the `world` namespace; least-privilege `writers` work (the happy path runs with `rp_salvage:world+char, rp_cargo:veh/cargo, rp_economy:cash+bank+soc, rp_inventory`). |
| D6 | (not specified) | coordinator op ids are `slv.<kind>:<coordinator newOpId>`, the sale's `slv.sale:<hold key>.a<n>`; **never** derived from an open77_actions op id | open77_actions' op ids carry a boot tag from the **monotonic** clock (`engine.lua` `bootTag = base36(P.now())`), which restarts with the process: deriving durable ids from them could replay another boot's receipt. Request B5-1. |
| D7 | the commit does ONE operation: node charge −1, crate + materials, tool wear | ONE coordinator operation (materials + token + wear); the node charge is spent right after it with `consume(node, { ref = op id })` | A node holds no value (A13 §6.1: a lease budget); A6 `consume` is idempotent by ref. A crash between the two leaves one extra charge on a wreck, never value (tested: charges agree with commits in every crash window). |
| D8 | prompts robust: interaction targets with explicit positions + a console path | open77_actions targets at fixed positions (foreman, 7 wrecks, loading bay, counter, unloading bay: 11 targets); a stripped wreck keeps "Check the haul"; **every step** has a `salvage.lab.*` command with explicit player ids | the A0/B5 live run did not show the lab node card once (research ledger B5/A5 live); the console path makes the two-client run independent of prompt aiming. |

## 3. The loop and the crate's states

```text
clock_in (foreman) ── rp_jobs:setDuty
cut | pry (wreck) ── reserve: capacity envelope -> hold, tool wear (CAS) ── 8 s, server clock ──
   commit: roll(op id) + [token if new] + wear ── consume(node, ref = op id)
crate:  new ──commit──> ground ──pickup──> carried ──G / drop──> ground
                                  │                 └─ load bay / /salvage load ──> truck ──unload──> ground (in hands)
                                  └─ counter ──sale──> sold ──retire──> (closed)
```

| State | Token is in | Prop | Durable placement |
|---|---|---|---|
| `new` | nowhere yet (opened at a reserve) | none | the spot next to the wreck |
| `ground` | the hold | open77_actions carry item | `meta.at` |
| `carried` | the hold | in hands (open77_actions) | unchanged (last put-down) |
| `truck` | `veh:<plate>:cargo` | rp_cargo's, attached to the bed | `meta.where` (a hint; the coordinator is the truth) |
| `sold` | retiring to `sys:salvage` | removed | the hold is closed |

Boot (and an open77_actions restart) rebuilds every crate from `listWorld` + `read`: token in the
hold → placed at `meta.at`; contents but no token → in a bed (rp_cargo draws it when the plate
is out); a persisted quote whose sale committed → retired, never placed; empty, no token, older
than 2 min → closed.

## 4. Failure semantics (what each window leaves behind)

| Window | Outcome | Test |
|---|---|---|
| work: store never got the commit | fenced `aborted`; `failed store_unavailable`; nothing granted, no wear, no charge; the new empty crate closed | `crash_windows` 1 |
| work: commit landed, ack lost | fence finds it; `committed` once; wear and charge once | `crash_windows` 2 |
| work: coordinator dies, commit executes detached | `in_doubt`; settled by the sweep once the coordinator is back: granted once, crate placed, charge spent | `crash_windows` 3 |
| work: coordinator dies, commit discarded | `in_doubt`; fenced: nothing granted, no wear, no charge | `crash_windows` 4 |
| death / vehicle / combat / move / bucket during the bar | `cancelled`; reservation cancelled; empty new crate closed | `cancellations` |
| full crate | `failed crate_full` at **reserve**, no bar | `full_crate` |
| drop while carrying (death, car, disconnect, job change) | crate on the ground at the feet, placement persisted, custody unchanged | `cancellations` |
| rp_salvage restart while carrying | crate back at its last durable placement, one item | `cancellations` |
| load / unload refused (no key, full bed, moving truck) | carry resumes; token unmoved | `stranger_load` |
| load / sale in doubt | open77_actions retries with the same op id; after the retries the crate drops and is re-derived from the coordinator | (by construction; see §9) |
| sale replayed (double press, retry, rp_economy restart) | stored receipt, paid once | `replayed_sale` |
| sale committed, retire lost, server dies | found at boot from the persisted quote; crate retired, never re-placed | `replayed_sale` |
| server restart: crates on ground / in hands / in a bed | ground at its spot; hands back where it was last put down; bed redrawn by rp_cargo; all three sell | `restart` |

## 5. Offline tests

```text
python -m unittest discover -s tests -p "test_c1*.py"     # 11 tests
```

**2026-10-12: 11 tests, OK, about 0.7 s** (KeraLua 1.4.9 `lua54.dll` through ctypes, Python 3.12),
against the final coordinator in both places it exists (`wt-world-interaction` 7ab7c3e0 merged
697e9e2f, and `wt-wi-a13b` 697e9e2f; identical apart from line ends). Two hand mutations each
made the suite fail (no reservation cancel → 2 failures; quote not persisted before the sale →
1 failure).

What runs for real: open77_transactions (model, policy, memory store in deferred mode, coordinator,
**server/main.lua** with its exports, work queue and tunables), open77_actions (engine, claims,
carry, main), open77_containers (model, lab_kvp store, service, main), rp_economy 2.0.0, rp_cargo
0.1.0, rp_salvage. Shims stand in for the **public exports** of rp_jobs, rp_garage and
rp_inventory (their suites cover them), and fakes for the natives (players, animations, props,
vehicles, NPCs, state bags, tunables, readJson). Sources outside the pack are read in place
(`OP77_SYS_DIR`, `OP77_TX_FINAL`); a missing one skips the suite.

| Test | Shows |
|---|---|
| `happy_path` | clock in by prompt; cut, cut, pry into one crate (welder 28/30, crowbar 19/20, wreck 0/3); carry; load at the bay under **strict writers** (grants carry rp_cargo and rp_economy into the hold); token in the bed, one bed prop; unload into the hands; sale: seller and society paid exactly the quote; hold closed, token retired; materials minted = sold; every op balanced; "Check the haul" on a stripped wreck; hand prop falls back to `tool.fire_axe` and is removed; buyer NPC requested; clock out → `off_duty`; a player with no job refused `no_job` and told |
| `contention` | two claims on one wreck in one pass: one `committed`, the other refused `target_claimed` holding nothing; two pickups of one crate: one carrier; two put-downs on the bay: `target_claimed`; two `/salvage load` on one truck at once: both commit, slots 1, 2, 3 distinct |
| `full_crate` | seeded hold: `cut` and `pry` both `failed crate_full` at stage `reserve`, never presented; tool, charges, contents unchanged; player told |
| `crash_windows` | §4 rows 1–4; after each, minted = held, wear = committed works = charges spent |
| `replayed_sale` | same sale request again → `replay=true`, paid 0; after an rp_economy restart → `replay=true`, paid 0; sale committed + retire refused + server restart → crate retired at boot, no hold, no item, cash unchanged |
| `restart` | crates on the ground, in hands, in a bed survive a full restart (states `ground`, `ground` at its last durable spot, `truck`; 2 items, 1 bed prop) and all three sell after it |
| `stranger_load` | a scrapper without a key: `failed no_access`, still carrying, token in the hold, `/salvage load` same; a civilian cannot lift a crate (`no_job`); with a key: loads |
| `cancellations` | death mid-work: `cancelled dead`, no crate, no wear, no charge; vehicle, job change (epoch), disconnect, rp_salvage restart while carrying: each `true/true/ground/1` (was carrying / not any more / on the ground / one item), custody in the hold; wear exactly once |
| `lab_console` | the loop from `salvage.lab.setup/work/pickup/load/unload/sell`; `salvage.lab.state` prints tools, cash, receipts; `salvage.status`; `salvage.lab.reset` back to 3/3; `salvage.lab.truck` prints the manual path; `salvage.lab.clock off` |
| sources | no BOM, LF, Lua 5.4 compile; manifest opt-in and least privilege |

Not established offline: anything in game (poses, props, prompts, FPP/TPP, timing on a live
tick, real event payloads), SQL on MariaDB (the coordinator's own suites), the real rp_jobs /
rp_garage / rp_inventory behind their exports, performance.

Other suites on this branch: `test_a9*` 23 OK. `test_compat*` (B8/B1/B2/B3): 55 tests, 14 errors or
failures, **all in `test_compat_inventory.py`**: that suite loads the coordinator from
`wt-world-interaction`, which now carries the merged final coordinator, and was written against
the wave-0 prototype (`read` → `not_loaded`, no `openWorld`...). Not caused by this branch (no
shared file changed); it is the reconciliation work of `wi/reconcile-a13`.

## 6. Two-client test script (integrator)

Lab profile: two clients A (actor) and B (observer, then second worker); crowd stopped; the
A4 `Open77RP.archive` (`E9E64F41…`) for the `amb_*` profiles. Hash what runs (DLL, archives,
this branch's commit). After any `ensure` of a client-distributed resource, reconnect the clients
(research ledger: hot-syncing a resource with client scripts ends a session).

**Setup**

1. `resources.load` as README §1 (no `rp_ferrailleur`), convars `rp_inventory_backend
   transactions`, `open77_actions_trace 1`; coordinator tunables: `writers` strict as README §1
   (or `*`), `mint1 = rp_salvage sys:salvage * 2000; rp_inventory sys:* * 2000; rp_economy sys:*
   money 1000000`. Apply the B3-1 allowlist entry (§7) to the lab's rp_economy copy.
   Expect the five start lines of README §1.
2. A and B in the world (`worldReady matched pristine transition`, `alive=yes`), teleported into
   the yard (Warden teleport + bring, 3–4 m apart, never `/goto`).
3. `salvage.lab.setup <A> both`, `salvage.lab.setup <B> both` → `setJob … true`,
   `setDuty … true`, `give welder … ok`, `give crowbar … ok`.
4. Truck: `/givemoney <A> 30000`; A buys a **Thorton Mackinaw** at the dealership (rp_garage
   menu); `salvage.lab.truck <A> <plate>` brings it next to A (`spawnOwned`). Park it with the bed
   on the loading bay marker. (With A9's requested `labIssue`, `salvage.lab.truck <A>` alone.)

**Measure first (no value moves):** stand on the foreman, both bays and the counter; `/pos`;
paste into `server/config.lua` and flip `measured`. Screenshot each marker from B.

**Run 1: the loop by prompts (A actor, B observer)**

| Step | A does | Expect in the server log | Screenshot (B unless noted) |
|---|---|---|---|
| clock | E "Clock in" at the foreman | `[actions] op=… state=committed … action=rp_salvage:clock_in` | — |
| cut | at "Burnt-out Thorton", E "Cut (torch)" | `crate world:… opened for <A> at thorton`; `state=presenting … playback=…`; 8 s later `work slv.work:… committed: +n Scrap metal …` | A kneeling with the torch at the wreck; A's bar (A's own screen) |
| pry | E "Pry (crowbar)" | `work … committed` | A scavenging, an axe in the right hand; prop gone after |
| check | E "Check the haul" | `state=committed … action=rp_salvage:inspect`; A's chat "Your crate: …" | kneeling driller check pose (never called drilling) |
| carry | E "Pick up scrap crate" by the crate | `item=… phase=gripped`, `phase=picked_up` | crate in A's hands (TPP, B); A's FPP view: box low right, "Put down [G]" |
| G | put it down, pick it up again | `phase=put_down` | crate on the ground in front of A |
| load | carrying, at the loading bay: "Load into the truck" | `[rp_cargo] player <A> loaded crate.… into <plate> slot 1 layer 1`; `crate world:… loaded on <plate> …` | crate in the bed (side and rear) |
| drive | A drives out and back to the unloading bay (B observes the bed) | — | the bed crate follows |
| unload | E "Unload a crate" | `[rp_cargo] … unloaded crate.…`; `crate world:… unloaded from <plate>`; then `phase=picked_up` | crate in A's hands |
| sell | carrying, at the counter: "Sell the crate" | `[rp_economy] sale slv.sale:<key>.a1 by rp_salvage`; `sale slv.sale:… total=T seller=S society=s` | the crate gone; A's toast "Sold to Rusty …" |
| state | console `salvage.lab.state <A>` | `cash=… society ferrailleur=…`, `receipt sale slv.sale:…`, `tool welder … durability=29`, `tool crowbar … durability=19` | — |

Swap A and B, repeat with the female rig as actor (one run each).

**Run 2: contention.** Both at the same wreck, both press E at once → one `presenting`, the
other refused "Someone is already working there." A puts a crate down, both press E on it → one
carrier. Both carry crates, both `/salvage load` next to A's truck (B holds a key: `/cles`) →
`slot 1` and `slot 2` (or the next free ones).

**Run 3: cancellations** (one each; `actions.claims` empty after every one; `salvage.lab.state`
shows no lost crate and wear only on committed works): kill A mid-bar (`state=cancelled
reason=dead`, no crate opened when it was the first work); A enters a car while carrying (crate
at A's feet); `salvage.lab.clock <A> off` while carrying (epoch: dropped); A disconnects while
carrying, reconnects (crate where A stood); `ensure rp_salvage` while A carries (crate back at its
last put-down spot after `ready:`).

**Run 4: durability.** With crates on the ground, in A's hands and in the bed: restart the
server. Expect `crates rebuilt from the coordinator: 3 (ground 2, in a bed 1, …)`; the bed crate
redrawn when the truck is taken out again (`salvage.lab.truck <A> <plate>`); sell all three. Then
the sale double press (two fast "Sell" choices: one payment); stop the database (or
`open77_transactions`) during a work: `failed … store_unavailable` or `in_doubt` then settled,
never a double grant; during a sale: refused or replayed, never paid twice.

**Run 5: authorization.** B without a key loads A's truck → "You hold no key for that truck."
and B keeps carrying. A civilian (no job) presses E on a crate → refused (`no_job`).

**Performance (A12):** both clients in the yard with all wrecks and a few crates: record frame
percentiles; this resource has no periodic world query (no `world.nearby`), one 5 s sweep.

## 7. Library and API changes needed (none made here)

| Id | Owner | Change | Blocking? |
|---|---|---|---|
| **B3-1** | rp_economy (B3) | add `rp_salvage = 30000` to `EconomyConfig.mint.callers` (the buyer's money is minted on rp_salvage's behalf, like `rp_ferrailleur`'s; the two never run together) | **yes**: every sale answers `mint_denied` without it (the offline suite patches it at boot) |
| B3-2 | rp_economy (B3) | `sale.items` accepting instance lines `{ instance, from }` so the crate token leaves in the sale: one operation, no retire step | no (retire + persisted quote cover it) |
| A6-1 | open77_containers (A6) | crates: create through `openWorld` (adopt the minted id) instead of `open(world:<uuid>)`, which the final coordinator refuses; and hand carriable projection to open77_actions (or expose a carry-compatible projection). Then rp_salvage's crates can move into A6 in `ledger.lua` / `service.lua` only | no (crates use the coordinator directly) |
| A6-2 | open77_containers | a node `refill`/`setCharges` (owner or lab) instead of close + re-create for a reset | no |
| B5-1 | open77_actions (B5) | op ids from a wall-clock boot tag (or document: never derive durable ids from them) | no (rp_salvage mints its own) |
| B5-2 | open77_actions | `carryPlace` into a player's hands (or `carryPickup` without the walk-up check) for unload-to-hands: today unload places the crate at the feet, then plays the pickup | no |
| B5-3 | open77_actions | treat `coordinator_unavailable`/`store_unavailable` from a commit hook as retryable, or say in the wiki that a hook should map them (rp_salvage maps `coordinator_unavailable` → `in_doubt`) | no |
| B2-1 | rp_inventory (B2) | an `authorizeFor(opId, grantee, playerId)` (the B2 owner grants a job one operation on a pocket) so a job does not need the `char` writer right for tool wear | no (writers `rp_salvage:world+char`) |
| A9-1 | rp_garage (A9) | `labIssue({ owner = playerId \| "society:<job>", record, near })` gated by a lab convar: a plated vehicle next to a player for lab runs | no (dealership + `spawnOwned` works) |
| AS-1 | prop hosts | `tool.crowbar` (RightHand attached host); `debris.scrap` (hand-sized, for loose scrap / a full-crate look); a measured Chest binding for `crate.ammo_box` (today the default, tuned on `crate.small`) | no |
| A13 config | open77_transactions tunables | `mint1`: `rp_salvage sys:salvage * <cap>`; `writers` as README §1 (or `*`) | config, per server |

## 8. Research ledger entry (for the integrator to copy)

> **2026-10-12 — C1 salvage pilot `rp_salvage`, built offline (RP pack `wi/c1-salvage`).**
>
> **Built:** a new opt-in server-only resource replacing `rp_ferrailleur` (operator choice): foreman
> duty (rp_jobs `setDuty`), seven wreck nodes (open77_containers charges/regrowth, rp_ferrailleur's
> positions), cut/pry actions (open77_actions; A4 welder workspot, player `scavenge`), a haul crate
> per player and wreck (coordinator `openWorld` hold + `salvage_crate` token), carry (open77_actions,
> `crate.ammo_box`), load/unload (rp_cargo through two-party `authorize` grants, rp_garage
> `canAccess`), sale (rp_economy `sale` + retire), lab console for every step.
>
> **Facts (offline, real libraries, KeraLua lua54.dll):** 11 tests pass against the final
> coordinator 697e9e2f: conservation of materials / tool wear / node charges in four crash windows of
> the work commit; one winner for a wreck, a crate and the bay; distinct bed slots under concurrent
> loads; a full crate refused at reserve with no bar; a replayed sale pays once (also after an
> rp_economy restart); a committed sale whose retire was lost is found at boot and never re-placed;
> crates on the ground, in hands and in a bed survive a restart and sell; least-privilege writers
> work through `authorize`.
>
> **Findings:** (1) the final coordinator refuses `open(world:<id>)`, so open77_containers' crate
> creation does not work against it (A6-1); (2) open77_actions op ids restart with the monotonic
> clock: durable ids must not derive from them (B5-1); (3) B3 `sale` cannot carry an instance line
> (B3-2); (4) rp_economy's mint allowlist lacks the pilot (B3-1, blocking).
>
> **Inferences (unmeasured):** latency per work ≈ one reserve + one commit (A13 I4: ~6 ticks + ~10 ms
> each); the bay/counter/foreman positions are arithmetic and need `/pos`.
>
> **Not done:** anything in game (§6 of c1-salvage.md), SQL, the female rig, FPP obstruction,
> performance.

## 9. Open items and risks

- **Open (owner):** `pickupBy = "crew"` lets any on-duty scrapper lift (and sell) a crate on the
  ground: crew play and theft both; `"owner"` restricts it. The seller is paid, not the filler.
- **Inference:** a load or sale that stays `in_doubt` past open77_actions' two retries drops the
  crate; `crateDropped` re-derives it from the coordinator (token away → removed as "in a bed";
  quote committed → retired). Not exercised offline for load/sale (only for the work commit).
- **Risk:** the bed counts the token's 2 kg, not the contents (they stay in the hold); a bed
  "capacity" is therefore a slot count in practice.
- **Risk:** a restart during a carry returns the crate to its last put-down spot, which may be
  far from the carrier (by design: custody never left).
- **Open:** tool supply. The pilot does not sell tools (a purchase needs B3 `charge` with an item
  line, or rp_inventory's `addAsync` behind a paid flow); operators give them.
- **Inference:** `open77_containers` nodes are point nodes without prompts; the wreck prompts are
  open77_actions targets (11 in all, under the 32-anchor budget; the client shows the 12 nearest).
