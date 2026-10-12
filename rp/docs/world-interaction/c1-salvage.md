# C1: the salvage pilot (`rp_salvage`) on the wave-1 libraries

**Row:** C1 of the world-interaction plan (`wt-world-interaction/docs/world-interaction-plan.md` §4 C,
acceptance §5.3, authoring contract §6, decision 5). **Design brief:**
`wt-world-interaction/docs/world-interaction/c1-salvage-design.md`. **Date:** 2026-10-12.
**Branch:** `Open2077/open77-rp-examples` `wi/c1-salvage`, from `wi/integration` 8109d7d;
reconciled the same day with **open77_containers 0.2.0** and open77_actions c926a3d6 + 62925a62
(Open77 `feat/world-interaction` 62925a62).

**Status: built and tested offline only.** Nothing was deployed, launched, run against a
database or seen in game; no `open77_*` tool was called. **Fact** below = read in source or
measured by the offline suite; **inference** = follows from source, not measured; **open** = a
decision for the integrator or the owner. Every sentence about players, props or animations
describes what the server asks for, not what renders.

---

## 0. Summary

1. **`rp_salvage` 0.1.1** (new, opt-in, server-only; 0.1.1 = the open77_containers 0.2.0 reconcile): clock in at a foreman, cut or pry one of
   one of five wrecks walked in the Rancho Coronado yard (rp_ferrailleur's arithmetic points were replaced after the in-game walk), fill a crate, carry it, load it on
   a plated truck, unload it at the buyer, sell it. It runs **instead of** `rp_ferrailleur`.
2. **Every value move is one coordinator operation with a receipt**: work (yield + crate token +
   tool wear), load, unload, sale (materials + seller cash + society share), retire. No reward
   is granted from a client callback; completion is open77_actions' server clock.
3. **Built on the libraries, not beside them:** open77_actions (targets, actions, claims,
   carry, eligibility and epoch guards), open77_containers 0.2.0 (wreck nodes keyed `node.<key>`:
   durable charges, regrowth and refill), open77_transactions **final wave-1 API** (697e9e2f: `openWorld`, `setMeta`,
   `listWorld`, `authorize`, `metaPatch`, `status(resolve)`), rp_jobs (`setDuty`, `eligible`,
   `workEpoch`), rp_inventory (`define`, `addAsync`), rp_garage (`canAccess` inside rp_cargo),
   rp_cargo (`load`/`unload`/`contents`), rp_economy (`sale`).
4. **One adapter module** (`server/ledger.lua`) holds every call to `open77_transactions`.
5. **Offline: 13 tests, all pass** (`tests/test_c1_salvage.py`), on the real libraries: happy
   path end to end, contention (wreck, crate, truck), full crate, five crash windows of the work
   commit, replayed sale and a sale/crash/restart window, restart with crates on the ground / in
   hands / in a bed, stranger cannot load, cancellations (death, vehicle, job change, disconnect,
   resource restart), the whole loop from the lab console, an open77_containers restart under a
   running yard, and a `writers` list without open77_containers.
6. **Library changes** (§7): A6-2, B5-1 and B5-3 are resolved in Open77 and used here; A6-1 is
   available and deliberately not adopted (D1 stays); B3-1, B3-2, B2-1 and A9-1 are resolved on
   `wi/integration` ff0d303, which this branch does not contain yet; one new finding there, R-1
   (rp_cargo's writer pre-check refuses the two-party grant C1 loads with). No library was changed
   here.

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
| D1 | haul crate = an `open77_containers` `world:` container projected as a prop | a coordinator `world:` container from **`openWorld`**; its record (owner, wreck, placement, sale quote) is the container's **metadata**; the ground prop is an **open77_actions carry item**; the bed prop is rp_cargo's | (a) A6's `create` opens `world:<uuid>` through `open`, which the final coordinator refuses (`open` → `invalid_account`, "use openWorld", contract §7.2); (b) a carriable prop must be owned by open77_actions (only a prop's owner may attach it: B5 §10 open point, A6 §12); (c) `setMeta` + `listWorld` now give the durable record A6's registry gave. **A6 is used for the wreck nodes**: in 0.2.0 each is keyed `node.<key>` and is a **zero-capacity coordinator world row** that open77_containers mints (it carries the placement and holds nothing: no value, no mint) plus, in its registry, the charges, regrowth and refill. 0.2.0 also removes (a) and (b) for crates (`openWorld` mint, `projection = "external"`: A6-1); the crates stay on the coordinator directly for this pilot (§7). |
| D2 | carry: custody moves to the carrier's `char:` account | **custody-neutral carry**: the crate stays in its hold while carried; custody changes only when its token enters or leaves a bed and when its materials are sold | A13 §6.1, A6 §2 and B5 §5 all prescribe it; moving a 14 kg crate into 40 kg pockets would refuse heavy-handed players, double the operations per carry and make a restart mid-carry a custody question. The carrier is a claim (open77_actions), not an owner. |
| D3 | crate custody → `veh:<plate>:cargo` with the slot in line metadata | the crate's **custody token** (one `salvage_crate` instance, `crate.<hold key>`) moves; the materials never leave the hold | rp_cargo slots instances (A9 §4.1); A13 does not nest containers (A9 §5 "Open"). Materials therefore move exactly twice: minted into the hold at a work, sold out of it. |
| D4 | sale = one B3 `sale` | one `rp_economy:sale` for materials + cash + society share, then a **separate retire** (token → `sys:salvage`, close the hold) | B3 `sale` takes stack lines only, so the token cannot leave in the sale. The quote (op id, total, split, seller) is persisted in the hold's record **before** paying: a crash between sale and retire is found at boot and the crate never reappears (tested). Request B3-2 makes it one operation. |
| D5 | (not specified) | rp_cargo and rp_economy reach the hold through **two-party grants** (`authorize(op, grantee, { hold }, ttl)`) | Neither needs the `world` namespace; least-privilege `writers` work (the happy path runs with `rp_salvage:world+char, rp_cargo:veh/cargo, rp_economy:cash+bank+soc, rp_inventory`). |
| D6 | (not specified) | coordinator op ids are `slv.<kind>:<coordinator newOpId>`, the sale's `slv.sale:<hold key>.a<n>`; **never** derived from an open77_actions op id | open77_actions' op ids carry a boot tag from the **monotonic** clock (`engine.lua` `bootTag = base36(P.now())`), which restarts with the process: deriving durable ids from them could replay another boot's receipt. B5-1 is resolved since (c926a3d6: wall clock + random boot tag); rp_salvage keeps minting its own ids, which stays correct. |
| D7 | the commit does ONE operation: node charge −1, crate + materials, tool wear | ONE coordinator operation (materials + token + wear); the node charge is spent right after it with `consume(node, { ref = op id })` | A node holds no value (A13 §6.1: a lease budget; its world row has zero capacity); A6 `consume` is idempotent by ref. A crash between the two leaves one extra charge on a wreck, never value (tested: charges agree with commits in every crash window). A charge refused while open77_containers restarts (stopped, or booting and knowing no container yet) is kept and spent once it is ready again (tested). |
| D8 | prompts robust: interaction targets with explicit positions + a console path | open77_actions targets at fixed positions (foreman, 5 wrecks, loading bay, counter, unloading bay: 9 targets); a stripped wreck keeps "Check the haul"; **every step** has a `salvage.lab.*` command with explicit player ids | the A0/B5 live run did not show the lab node card once (research ledger B5/A5 live); the console path makes the two-client run independent of prompt aiming. |

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
| work: coordinator unreachable **before** the commit is submitted | `failed coordinator_unavailable` after open77_actions' retries with the same op id (B5-3): nothing can have landed; no grant, no wear, no charge, no doubt left; the player reads "ledger is offline: nothing was taken" | `crash_windows` 5 |
| death / vehicle / combat / move / bucket during the bar | `cancelled`; reservation cancelled; empty new crate closed | `cancellations` |
| full crate | `failed crate_full` at **reserve**, no bar | `full_crate` |
| drop while carrying (death, car, disconnect, job change) | crate on the ground at the feet, placement persisted, custody unchanged | `cancellations` |
| rp_salvage restart while carrying | crate back at its last durable placement, one item | `cancellations` |
| load / unload refused (no key, full bed, moving truck) | carry resumes; token unmoved | `stranger_load` |
| load / sale in doubt | open77_actions retries with the same op id; after the retries the crate drops and is re-derived from the coordinator | (by construction; see §9) |
| sale replayed (double press, retry, rp_economy restart) | stored receipt, paid once | `replayed_sale` |
| sale committed, retire lost, server dies | found at boot from the persisted quote; crate retired, never re-placed | `replayed_sale` |
| server restart: crates on ground / in hands / in a bed | ground at its spot; hands back where it was last put down; bed redrawn by rp_cargo; all three sell | `restart` |
| open77_containers stopped, then booting (it knows no container until its boot join) | same node ids (keyed); a charge spent meanwhile is kept and spent once `open77_containers:ready` fires; rp_salvage re-runs its node boot then | `containers_restart` |
| an operator closes a node (`containers.remove node.thorton`) | its prompt is withdrawn, a WRN says the key is spent (never reused by open77_containers); the other nodes are untouched; config `containerKey` brings it back | `containers_restart` |
| `writers` without `open77_containers:world` | every node refused `namespace_denied` (said once per node); the yard starts without wreck prompts (`ready: 0 of 5 wreck nodes`); the entry added live: nodes back within 30 s | `writers_missing` |

**Commit hook and transient refusals (B5-3, since open77_actions 62925a62).** The ledger maps a lost
answer to a submitted write (`export_timeout`, `export_resource_stopped`) to `in_doubt`; a refusal
at dispatch, or by the coordinator itself (`coordinator_unavailable`, `store_unavailable`,
`conflict`), means nothing was applied, and `slvCommit` now returns it as is: open77_actions retries
with the same op id, then fails the action with that reason and calls `slvCancel`, which releases
the reservation. The one exception: after an attempt of the same op that may have landed
(`in_doubt`, `busy`), a later transient refusal proves nothing about it and is still answered
`in_doubt`, so the sweep settles it through the fence (`crash_windows` 3 depends on it: the
coordinator dies with the commit queued, and the retries meet a stopped coordinator).

## 5. Offline tests

```text
python -m unittest discover -s tests -p "test_c1*.py"     # 13 tests
```

**2026-10-12: 11 tests, OK, about 0.7 s** (KeraLua 1.4.9 `lua54.dll` through ctypes, Python 3.12),
against the final coordinator in both places it exists (`wt-world-interaction` 7ab7c3e0 merged
697e9e2f, and `wt-wi-a13b` 697e9e2f; identical apart from line ends). Two hand mutations each
made the suite fail (no reservation cancel → 2 failures; quote not persisted before the sale →
1 failure).

**2026-10-12, reconcile with open77_containers 0.2.0: 13 tests, OK, about 1.1 s**, against
`wt-world-interaction` 62925a62 (open77_containers 0.2.0, open77_actions with c926a3d6 +
62925a62, the final coordinator). Before the change the happy path failed there: `create` before
the containers' boot join answered `not_ready`, and under strict writers every node was refused
`namespace_denied` (no `open77_containers:world`), so no node existed and no work committed. Four
hand mutations each made the suite fail: the old blanket `coordinator_unavailable` → `in_doubt`
mapping (crash window 5), dropping the "earlier attempt may have landed" rule (crash window 3
reported `failed`), dropping a charge on `unknown_container` while open77_containers boots, and
not re-running the node boot on `open77_containers:ready` (both `containers_restart`).

What runs for real: open77_transactions (model, policy, memory store in deferred mode, coordinator,
**server/main.lua** with its exports, work queue and tunables), open77_actions (engine, claims,
carry, main), open77_containers 0.2.0 (model, lab_kvp store, service, main), rp_economy 2.0.0, rp_cargo
0.1.0, rp_salvage. Shims stand in for the **public exports** of rp_jobs, rp_garage and
rp_inventory (their suites cover them), and fakes for the natives (players, animations, props,
vehicles, NPCs, state bags, tunables, readJson). Sources outside the pack are read in place
(`OP77_SYS_DIR`, `OP77_TX_FINAL`); a missing one skips the suite.

| Test | Shows |
|---|---|
| `happy_path` | the five start lines of README §1 once each (five nodes created), no node warning; clock in by prompt; cut, cut, pry into one crate (welder 28/30, crowbar 19/20, wreck 0/3); carry; load at the bay under **strict writers** (grants carry rp_cargo and rp_economy into the hold; `open77_containers:world` for the nodes); token in the bed, one bed prop; unload into the hands; sale: seller and society paid exactly the quote; hold closed, token retired; materials minted = sold; every op balanced; "Check the haul" on a stripped wreck; hand prop falls back to `tool.fire_axe` and is removed; buyer NPC requested; clock out → `off_duty`; a player with no job refused `no_job` and told |
| `contention` | two claims on one wreck in one pass: one `committed`, the other refused `target_claimed` holding nothing; two pickups of one crate: one carrier; two put-downs on the bay: `target_claimed`; two `/salvage load` on one truck at once: both commit, slots 1, 2, 3 distinct |
| `full_crate` | seeded hold: `cut` and `pry` both `failed crate_full` at stage `reserve`, never presented; tool, charges, contents unchanged; player told |
| `crash_windows` | §4 rows 1–5; after each, minted = held, wear = committed works = charges spent; window 5 (coordinator gone before the commit): `failed coordinator_unavailable`, no doubt left, player told |
| `replayed_sale` | same sale request again → `replay=true`, paid 0; after an rp_economy restart → `replay=true`, paid 0; sale committed + retire refused + server restart → crate retired at boot, no hold, no item, cash unchanged |
| `restart` | crates on the ground, in hands, in a bed survive a full restart (states `ground`, `ground` at its last durable spot, `truck`; 2 items, 1 bed prop) and all three sell after it |
| `stranger_load` | a scrapper without a key: `failed no_access`, still carrying, token in the hold, `/salvage load` same; a civilian cannot lift a crate (`no_job`); with a key: loads |
| `cancellations` | death mid-work: `cancelled dead`, no crate, no wear, no charge; vehicle, job change (epoch), disconnect, rp_salvage restart while carrying: each `true/true/ground/1` (was carrying / not any more / on the ground / one item), custody in the hold; wear exactly once |
| `lab_console` | the loop from `salvage.lab.setup/work/pickup/load/unload/sell`; `salvage.lab.state` prints tools, cash, receipts; `salvage.status`; `salvage.lab.reset` refills in place (same node id, 2 → 3/3); `salvage.lab.truck` prints the manual path; `salvage.lab.clock off` |
| `containers_restart` | nodes keyed `node.<key>`, five zero-capacity world rows; open77_containers stopped during a work, then booting without the coordinator: the charge is kept both times (1 pending), spent once it is ready (3 → 1 after two works), same node ids, node boot re-run on `:ready`; rp_salvage restarted: the five start lines with `(0 created)`; `containers.remove node.thorton`: prompt withdrawn, key spent (said once), other nodes kept |
| `writers_missing` | strict writers without `open77_containers:world`: five `namespace_denied` warnings, `WARNING: 5 of 5 wreck nodes unavailable`, `ready: 0 of 5 wreck nodes`, no wreck prompt; the entry added live (`onTunableChanged`): five nodes back within 30 s and a work commits |
| sources | no BOM, LF, Lua 5.4 compile; manifest opt-in and least privilege |

Not established offline: anything in game (poses, props, prompts, FPP/TPP, timing on a live
tick, real event payloads), SQL on MariaDB (the coordinator's own suites), the real rp_jobs /
rp_garage / rp_inventory behind their exports, performance.

Other suites on this branch: `test_a9*` 23 OK. `test_compat*` (B8/B1/B2/B3): 55 tests, 14 errors or
failures, **all in `test_compat_inventory.py`**: that suite loads the coordinator from
`wt-world-interaction`, which now carries the merged final coordinator, and was written against
the wave-0 prototype (`read` → `not_loaded`, no `openWorld`...). Not caused by this branch (no
shared file changed); it is the reconciliation work of `wi/reconcile-a13`.

After the containers 0.2.0 reconcile, the whole `tests/` folder on this branch: 92 tests, the same
15 known failures as before it (14 in `test_compat_inventory.py`, and `test_held_actions` needs
`lupa`), every other test passes; only `tests/compat/salvage_*.lua` and `tests/test_c1_salvage.py`
changed. **Checked against `wi/integration` ff0d303** (reconcile-a13 + B7) on a scratch copy of that
tree with this branch's changes applied (the merge itself is not on this branch yet): 111 tests, all
pass but `test_held_actions`, **once R-1 (§7) is fixed in rp_cargo**; without that fix the C1 happy
path fails at the load, `namespace_denied`.

## 6. Two-client test script (integrator)

Lab profile: two clients A (actor) and B (observer, then second worker); crowd stopped; the
A4 `Open77RP.archive` (`E9E64F41…`) for the `amb_*` profiles. Hash what runs (DLL, archives,
this branch's commit). After any `ensure` of a client-distributed resource, reconnect the clients
(research ledger: hot-syncing a resource with client scripts ends a session).

**Setup**

1. `resources.load` as README §1 (no `rp_ferrailleur`), convars `rp_inventory_backend
   transactions`, `open77_actions_trace 1`; coordinator tunables: `writers` strict as README §1,
   i.e. `rp_salvage:world+char, rp_cargo:veh/cargo, rp_economy:cash+bank+soc, rp_inventory,
   open77_containers:world` (open77_containers 0.2.0 mints the nodes' zero-capacity world rows; no
   mint rule needed for them), or `*`; `mint1 = rp_salvage sys:salvage * 2000; rp_inventory sys:*
   * 2000; rp_economy sys:* money 1000000`. The B3-1 allowlist entry (§7) is in rp_economy from
   `wi/integration` ff0d303; an older copy needs it added. With strict writers and the
   ff0d303 rp_cargo, R-1 (§7) must be fixed first, or every load answers `namespace_denied`.
   Expect the five start lines of README §1 (`5 wreck node(s) ready (5 created)` on a fresh
   database, `(0 created)` after).
2. A and B in the world (`worldReady matched pristine transition`, `alive=yes`), teleported into
   the yard (Warden teleport + bring, 3–4 m apart, never `/goto`).
3. `salvage.lab.setup <A> both`, `salvage.lab.setup <B> both` → `setJob … true`,
   `setDuty … true`, `give welder … ok`, `give crowbar … ok`.
4. Truck: `/givemoney <A> 30000`; A buys a **Thorton Mackinaw** at the dealership (rp_garage
   menu); `salvage.lab.truck <A> <plate>` brings it next to A (`spawnOwned`). Park it with the bed
   on the loading bay marker. (With A9-1 `labIssue`, rp_garage from `wi/integration` ff0d303 and the
   convar `rp_garage_lab 1`: `salvage.lab.truck <A>` alone.)

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

**Run 4: durability.** `salvage.status` (note the node ids); `restart open77_containers` → the log
shows `5 wreck node(s) ready (0 created)` and `salvage.status` the same ids; `salvage.lab.reset
thorton` → `node thorton: refilled world:… to 3/3` with the same id. With crates on the ground, in
A's hands and in the bed: restart the server. Expect `crates rebuilt from the coordinator: 3 (ground 2, in a bed 1, …)`; the bed crate
redrawn when the truck is taken out again (`salvage.lab.truck <A> <plate>`); sell all three. Then
the sale double press (two fast "Sell" choices: one payment); stop the database (or
`open77_transactions`) during a work: `failed … store_unavailable` or `in_doubt` then settled,
never a double grant; during a sale: refused or replayed, never paid twice.

**Run 5: authorization.** B without a key loads A's truck → "You hold no key for that truck."
and B keeps carrying. A civilian (no job) presses E on a crate → refused (`no_job`).

**Performance (A12):** both clients in the yard with all wrecks and a few crates: record frame
percentiles; this resource has no periodic world query (no `world.nearby`), one 5 s sweep.

## 7. Library and API changes (none made here)

Status 2026-10-12, after the open77_containers 0.2.0 reconcile. "Open77" = `feat/world-interaction`
62925a62; "integration" = this pack's `wi/integration` ff0d303 (`wi/reconcile-a13` + `wi/b7-ui`),
which this branch does not contain yet.

| Id | Owner | Change | Blocking? | Status |
|---|---|---|---|---|
| **R-1** (new) | rp_cargo (A9, as reconciled on integration) | `mayWrite` (rp_cargo/server/main.lua) asks the coordinator's `allowed` before a load/unload transfer and refuses any non-`char:` account outside rp_cargo's writers, so it refuses the crate hold even when rp_salvage granted that one operation with `authorize` (D5): the coordinator has no export to ask about a per-operation grant. Fix: for a non-`char:` account, return true and let the transfer decide (the coordinator honours `authorize`); or add a coordinator export `granted(opId, resource, account)` | **yes** with strict writers once integration is merged (writers `*` unaffected) | open. Tested on a scratch copy of integration + this branch: with that one-function change, 111 tests pass but `test_held_actions` (lupa); without it the C1 happy path fails at the load |
| **B3-1** | rp_economy (B3) | add `rp_salvage = 30000` to `EconomyConfig.mint.callers` (the buyer's money is minted on rp_salvage's behalf, like `rp_ferrailleur`'s; the two never run together) | **yes**: every sale answers `mint_denied` without it | resolved on integration (`rp_economy/server/config.lua`); the offline suite still patches it at boot (harmless once merged) |
| B3-2 | rp_economy (B3) | `sale.items` accepting instance lines `{ instance, from }` so the crate token leaves in the sale: one operation, no retire step | no (retire + persisted quote cover it) | resolved on integration; **not adopted**: needs the merge, then the sale and retire become one op (the persisted quote and the `replayed_sale` / `restart` windows to re-run) |
| A6-1 | open77_containers (A6) | crates: create through `openWorld` (adopt the minted id) instead of `open(world:<uuid>)`; hand carriable projection to open77_actions | no (crates use the coordinator directly) | **available** in 0.2.0 (`create` mints through `openWorld`; `projection = "external"`: no prop, bag or prompt, the carry helper owns the presentation, `place` makes a put-down durable; a6-containers.md §8). **Not adopted** (D1 stays): moving the crates into A6 later touches `ledger.lua` / `service.lua` only, and would need the pass-through writers (`open77_containers` as writer of `world`, `veh/cargo` and the sale's accounts, a6-containers.md §4) |
| A6-2 | open77_containers | a node `refill`/`setCharges` (owner or lab) instead of close + re-create for a reset | no | **resolved and used**: `salvage.lab.reset` calls `refill` (same node id, consume refs kept; tested) |
| B5-1 | open77_actions (B5) | op ids from a wall-clock boot tag (or document: never derive durable ids from them) | no (rp_salvage mints its own) | **resolved** (c926a3d6: wall clock + random boot tag); rp_salvage keeps minting its own coordinator op ids (D6) |
| B5-2 | open77_actions | `carryPlace` into a player's hands (or `carryPickup` without the walk-up check) for unload-to-hands: today unload places the crate at the feet, then plays the pickup | no | open |
| B5-3 | open77_actions | treat `coordinator_unavailable`/`store_unavailable` from a commit hook as retryable | no | **resolved** (c926a3d6 + 62925a62: `coordinator_unavailable`, `store_unavailable`, `conflict` are retried with the same op id, then the action **fails** with that reason, never `in_doubt`; a retry meeting the fence reports the first reason). rp_salvage no longer maps `coordinator_unavailable` → `in_doubt`, except after an attempt that may have landed (§4; `crash_windows` 3 and 5) |
| B2-1 | rp_inventory (B2) | an `authorizeFor(opId, grantee, playerId)` (the B2 owner grants a job one operation on a pocket) so a job does not need the `char` writer right for tool wear | no (writers `rp_salvage:world+char`) | resolved on integration as `grantPockets(opId, playerId, ttlMs?)` (callers in `Config.pocketGrantees`); **not adopted**: needs the merge; then the work hook would ask it before reserve and commit, and `writers` could drop `+char` |
| A9-1 | rp_garage (A9) | `labIssue` gated by a lab convar: a plated vehicle next to a player for lab runs | no (dealership + `spawnOwned` works) | resolved on integration as `labIssue(playerId, record, opts?)` behind `rp_garage_lab 1`; `salvage.lab.truck <pid>` now calls that signature (says `lab_disabled` / manual path otherwise; this branch's rp_garage has none) |
| AS-1 | prop hosts | `tool.crowbar` (RightHand attached host); `debris.scrap` (hand-sized, for loose scrap / a full-crate look); a measured Chest binding for `crate.ammo_box` (today the default, tuned on `crate.small`) | no | open |
| A13 config | open77_transactions tunables | `mint1`: `rp_salvage sys:salvage * <cap>`; `writers` as README §1 (or `*`), **now including `open77_containers:world`** (it mints the nodes' world rows) | config, per server | — |

## 8. Research ledger entry (for the integrator to copy)

> **2026-10-12 — C1 salvage pilot `rp_salvage`, built offline (RP pack `wi/c1-salvage`).**
>
> **Built:** a new opt-in server-only resource replacing `rp_ferrailleur` (operator choice): foreman
> duty (rp_jobs `setDuty`), five wreck nodes (open77_containers charges/regrowth, walked in game on 2026-10-12; first placed at rp_ferrailleur's
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

> **2026-10-12 (later) — C1 reconciled with open77_containers 0.2.0 and open77_actions B5-1/B5-3
> (Open77 `feat/world-interaction` 62925a62; RP pack `wi/c1-salvage`).**
>
> **Facts (offline, same harness):** against 0.2.0 the pilot's happy path had stopped committing
> work: `create` answers `not_ready` until the containers' boot join (which waits for
> `open77_transactions:ready`), and with strict writers every node was refused `namespace_denied`,
> because open77_containers now mints each node's zero-capacity world row itself. Fixed in
> rp_salvage: nodes keyed `node.<key>` (`find`, then an idempotent keyed `create`), the boot waits
> on the `not_ready` answer itself (the `ready` event is missed when open77_containers was up
> first) and re-runs on `open77_containers:ready`; a charge refused while it restarts is kept;
> `salvage.lab.reset` uses `refill` (same id); a lasting node refusal is logged once and retried
> every 30 s. Writers must include `open77_containers:world`. The commit hook now answers transient
> refusals as they are (B5-3: open77_actions retries them, then fails the action), except after an
> attempt that may have landed. 13 tests pass; four hand mutations each fail it.
>
> **Finding:** R-1, the reconciled rp_cargo's writer pre-check refuses a hold granted for one
> operation with `authorize`, which breaks least-privilege loading once `wi/integration` is merged
> (shown on a scratch copy; a one-function fix makes all 111 tests pass but the lupa one).
>
> **Open:** a node closed with `containers.remove` spends its key for good (config `containerKey`
> brings it back); A6-1 (carriable external crates) not adopted.

## 9. Open items and risks

- **Open (owner):** `pickupBy = "crew"` lets any on-duty scrapper lift (and sell) a crate on the
  ground: crew play and theft both; `"owner"` restricts it. The seller is paid, not the filler.
- **Inference:** a load or sale that stays `in_doubt` past open77_actions' two retries drops the
  crate; `crateDropped` re-derives it from the coordinator (token away → removed as "in a bed";
  quote committed → retired). Not exercised offline for load/sale (only for the work commit).
  Since B5-3 a load or sale refused transiently (`coordinator_unavailable`, `store_unavailable`,
  `conflict`) fails after the retries instead, nothing applied, and the carry is not dropped
  (`in_doubt` is a drop reason in the carry helper, those are not; read in source, not tested).
- **Open:** R-1 (§7) before strict writers can run on the merged `wi/integration`.
- **Risk:** a wreck node closed in open77_containers (`containers.remove`, or its world row closed
  outside) is gone for good under its key: rp_salvage withdraws its prompt and says so; the
  operator gives that node a new `containerKey` in config. `salvage.lab.reset` is the safe reset.
- **Inference:** a node whose config position changes keeps its first placement in
  open77_containers (find by key wins). Harmless here: the prompt is rp_salvage's own target at the
  configured position, and node reach is off.
- **Risk:** the bed counts the token's 2 kg, not the contents (they stay in the hold); a bed
  "capacity" is therefore a slot count in practice.
- **Risk:** a restart during a carry returns the crate to its last put-down spot, which may be
  far from the carrier (by design: custody never left).
- **Open:** tool supply. The pilot does not sell tools (a purchase needs B3 `charge` with an item
  line, or rp_inventory's `addAsync` behind a paid flow); operators give them.
- **Inference:** `open77_containers` nodes are point nodes without prompts; the wreck prompts are
  open77_actions targets (11 in all, under the 32-anchor budget; the client shows the 12 nearest).
