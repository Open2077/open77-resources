# rp_salvage — the scrapyard job, on the world-interaction libraries (pilot C1)

Cut or pry a wreck at the Rancho Coronado junkyard, fill a crate, carry it, load it on a truck,
drive, unload it at the buyer and sell it. Every step that moves value is one durable,
idempotent operation; every prompt, bar, claim and carry comes from a library, not from this
resource.

**Status: built and tested offline only (2026-10-12).** Nothing here was deployed, launched or
seen in game. The two-client test script is in
[`docs/world-interaction/c1-salvage.md`](../docs/world-interaction/c1-salvage.md) §6. Unmeasured
positions are marked `measured = false` in `server/config.lua`.

---

## 1. Enable it on a server (operator)

`rp_salvage` replaces `rp_ferrailleur`; a server runs **one or the other**, never both (two scrap
economies, plan decision 5; both also define the item `crowbar`). It never starts by itself
(`auto_start false`).

1. `resources.load`: remove `rp_ferrailleur`, add, in this order of dependencies:
   `open77_transactions`, `open77_props`, `open77_animations`, `open77_interactions`,
   `open77_uikit`, `open77_notifications`, `open77_actions`, `open77_containers`, `rp_jobs`,
   `rp_inventory`, `rp_economy`, `rp_garage`, `rp_cargo`, `rp_salvage`.
2. Convar `rp_inventory_backend transactions` (tools must live in coordinator pockets).
3. `open77_transactions` tunables (contract §7.2 / §13): `writers` either `*` or at least
   `rp_salvage:world+char, rp_cargo:veh/cargo, rp_economy:cash+bank+soc, rp_inventory`, and a mint
   rule `rp_salvage sys:salvage * 2000` (materials and crate tokens; size the hourly cap to your
   population) plus the wallet's `rp_economy sys:* money <cap>`.
4. `rp_economy` must list `rp_salvage` in `EconomyConfig.mint.callers` (the buyer's money is
   created on `rp_salvage`'s behalf). **This entry is not in rp_economy yet**: see c1-salvage.md
   §7 (requested change B3-1). Without it every sale answers `mint_denied`.
5. Lab without a database: `open77_transactions` store `lab_kvp` (+ `open77_transactions_lab 1`,
   unmastered host) and `open77_containers_store lab_kvp` + `open77_containers_lab 1`. A server
   with a database needs neither.

Expected start lines:

```text
[rp_salvage] coordinator ready (store=sql)
[rp_salvage] items defined through rp_inventory: 5
[rp_salvage] 7 wreck node(s) ready (7 created)        -- "(0 created)" on later boots
[rp_salvage] crates rebuilt from the coordinator: N (ground g, in a bed b, sold s, new n, orphans closed o)
[rp_salvage] ready: 7 wreck nodes, foreman, loading bay, unloading bay, buyer counter (job ferrailleur)
```

## 2. Play it

| Step | Where | What the player does | What the server does |
|---|---|---|---|
| Clock in | foreman | E "Clock in" | `rp_jobs:setDuty(player, true, { job = "ferrailleur" })` |
| Work | a wreck | E "Cut (torch)" or "Pry (crowbar)", 8 s bar | reserves capacity + tool wear, commits the yield into **your crate next to the wreck** (opened on the first work) |
| Check | a wreck | "Check the haul" (4 s) | reads your crate and the wreck's charges |
| Carry | the crate | E "Pick up scrap crate", walk; G puts it down | custody does not move; a put-down is a durable placement |
| Load | loading bay (or `/salvage load` next to any truck you hold a key for) | carrying: "Load into the truck" | `rp_cargo:load` moves the crate token into `veh:<plate>:cargo`; the bed crate is rp_cargo's prop |
| Unload | unloading bay (or `/salvage unload`) | E "Unload a crate" | `rp_cargo:unload` moves it back; you lift it |
| Sell | the buyer's counter | carrying: "Sell the crate" | one `rp_economy:sale`: materials out, cash to you, 10 % to the `ferrailleur` society |

Tools: a **cutting torch** (`welder`, 30 uses) to cut, a **crowbar** (20 uses) to pry; both wear
by one per completed work and break at 0. The pilot does not sell tools: an operator gives them
(`salvage.lab.setup`, or any rp_inventory grant).

A crate holds 12 kg of materials. A wreck gives 3 works, then regrows one work every 5 minutes.
A full crate refuses the next work **before** the bar starts.

Player command: `/salvage` (help), `/salvage load`, `/salvage unload`, `/salvage crates`.

## 3. How it is built (author walkthrough, D1)

Six files, one job each:

| File | Role |
|---|---|
| `server/config.lua` | positions, items, loot, prices, actions; nothing else |
| `server/model.lua` | pure rules: the deterministic roll, tool choice and wear line, the quote, crate ids, refusal texts |
| `server/ledger.lua` | **the only file that calls `open77_transactions`** (export names in one table) |
| `server/ports.lua` | every other cross-resource call and every native |
| `server/service.lua` | the hooks and flows |
| `server/main.lua` | exports (hooks), boot order, events, commands |

### 3.1 The custody model

A **crate is one coordinator `world:` container** (minted by `openWorld`), its *hold*:

- its **materials** enter at a work commit and leave at the sale, nowhere else;
- its **custody token**, one `salvage_crate` instance (`crate.<hold key>`), sits in the hold while
  the crate is on the ground or carried, and in `veh:<plate>:cargo` while it rides in a bed
  (rp_cargo moves instances, so the token is what a truck carries);
- its **record** (owner, wreck, durable placement, persisted sale quote) is the hold's metadata.

Carrying is presentation: custody stays in the hold (A13 §6.1, A6 §2, B5 §5). The prop on the
ground is an `open77_actions` carry item (only a prop's owner may attach it); the prop in a bed is
rp_cargo's. Both are rebuilt from the coordinator at boot.

### 3.2 Library calls, in loop order

```lua
-- Definitions: through rp_inventory (the single definer toward the coordinator, B2 §7.10).
exports.rp_inventory:define(SalvageConfig.items)

-- Nodes: open77_containers point nodes (no prop, no account): durable charges + regrowth.
Open77.exports.call("open77_containers", "create", { kind = "node", model = false, position = ...,
    node = { charges = 3, regrowMs = 300000 }, public = { node = "thorton" } }):await()

-- Actions: hooks are EXPORT NAMES of this resource; each checks GetInvokingResource().
exports.open77_actions:define({ id = "cut", durationMs = 8000,
    animation = { profile = "amb_1056d7_kneel_welder", at = "target" },
    hooks = { validate = "slvValidate", reserve = "slvReserve", commit = "slvCommit", cancel = "slvCancel" },
    eligibility = { resource = "rp_jobs", export = "eligible", args = { job = "ferrailleur", duty = true } },
    epochs = { resource = "rp_jobs", read = "workEpoch", event = "rp_jobs:workEpoch" } })
exports.open77_actions:target({ id = "node_thorton", position = ..., actions = { "cut", "pry", "inspect" },
    data = { node = "thorton" } })
```

**Reserve** (`slvReserve`, async): verify the operation, read the pockets, pick the tool, find or
`openWorld` your crate, then ONE reservation:

```lua
ledger.reserve({ opId = "slv.work:<coordinator id>", kind = "salvage.work", actor = "char:<subject>",
    lines = { { capacityG = maxYieldG, from = "sys:salvage", to = hold },          -- room for the best roll
              { instance = tool, at = "char:<subject>", metaPatch = { durability = d - 1 } } } })
```

A full crate is `capacity_exceeded` here (shown as "Your crate here is full"): no bar, no wear.

**Commit** (`slvCommit`, async, at the server's clock): the roll is drawn from the coordinator
op id (a retried commit sends identical lines), plus the token when the crate is new, plus the
same wear line; ONE `commit`. Then the wreck's charge: `consume(node, { ref = op id })`
(idempotent; a lease budget, not value). `in_doubt`/`busy` go back to open77_actions, which
retries with the same context; an unreachable coordinator mid-commit is reported `in_doubt` too.

**Cancel** (`slvCancel`): `cancel` the reservation and close an empty new crate — except on
`in_doubt`, where it settles with `status(op, { resolve = true })` and grants exactly what was
committed (the sweep retries until the coordinator answers).

**Carry** (`carryDefine` kind `crate`, hooks `crateValidate`, `cratePickup`, `cratePutdown`,
`crateDropped`): pickup verifies the token is in the hold; a ground put-down writes the placement;
a drop (death, car, disconnect, job change) re-derives the crate from the coordinator.

**Load** (put-down at the bay, or a `vehicle` destination): two-party grant, then rp_cargo:

```lua
ledger.authorize(opId, "rp_cargo", { hold }, 60000)          -- rp_cargo may move the token out
Open77.exports.call("rp_cargo", "load", player, vehicleId, token,
    { opId = opId, from = hold, item = "salvage_crate", model = "crate.ammo_box" }):await()
-- rp_garage:canAccess(player, plate, "cargo", "put") decides inside rp_cargo; refused -> carry resumes
```

**Unload**: `authorize(opId, "rp_cargo", { hold })`, `rp_cargo:unload(..., { to = hold })`, place the
crate at the player's feet, `carryPickup`.

**Sell** (put-down at the counter): quote persisted in the hold's record *before* paying, grant
the wallet, one sale, then retire the empty crate:

```lua
ledger.setMeta(hold, meta)                                   -- meta.sale = { opId, total, ... }
ledger.authorize(quote.opId, "rp_economy", { hold }, 60000)
Open77.exports.call("rp_economy", "sale", { opId = quote.opId, seller = { subject = s },
    items = { { item = "scrap_metal", count = n, from = hold }, ... }, buyer = { sys = "dealer" },
    total = t, payees = { { subject = s, amount = t - soc }, { society = "ferrailleur", amount = soc } } }):await()
ledger.transfer({ lines = { { instance = token, from = hold, to = "sys:salvage" } } }); ledger.close(hold)
```

The quote's op id is `slv.sale:<hold key>.a<attempt>`: a retried sale replays its receipt; a
fenced or failed attempt moves to `.a<n+1>`; a crash between the sale and the retire is found at
boot (the record holds the quote) and the crate never comes back.

### 3.3 Refusals

Every typed refusal is shown to the player (chat + toast, `SalvageModel.TEXT`): `node_depleted`,
`no_tool`, `crate_full`, `crate_busy`, `too_many_crates`, `crate_unavailable`, `crate_empty`,
`no_truck`, `no_salvage_crate`, `salvage_unavailable`, `salvage_not_configured`, `in_doubt`, and
the libraries' own (`off_duty`, `no_job`, `stale_job_epoch`, `no_access`, `cargo_full`,
`vehicle_not_tracked`, `target_claimed`, `capacity_exceeded`, `store_unavailable`, `mint_denied`,
`mint_cap`...). Unknown tokens are shown verbatim, never dropped.

## 4. Console (restricted: console or ACL `command.salvage.*`)

Explicit player ids; each drives the same server path as the prompts, so a lab run never depends
on aiming at a prompt.

| Command | Does |
|---|---|
| `salvage.status` | crates per state, counters, each wreck's charges |
| `salvage.lab.setup <pid> [crowbar\|welder\|both]` | job `ferrailleur` grade 0, duty on, tool instance(s) through `rp_inventory:addAsync` |
| `salvage.lab.clock <pid> on\|off` | duty |
| `salvage.lab.truck <pid> [plate]` | with a plate: `rp_garage:spawnOwned` next to the player; without: the requested `rp_garage:labIssue` (absent today: prints the manual way) |
| `salvage.lab.work <pid> <node> [cut\|pry\|inspect]` | the prompt's request |
| `salvage.lab.pickup <pid> [crateKey]` | lifts the nearest ground crate (3 m) or that one |
| `salvage.lab.load <pid> [vehicleId]` | puts the carried crate on that truck / the nearest accessible one |
| `salvage.lab.unload <pid> [vehicleId]` | unloads a yard crate into the player's hands |
| `salvage.lab.sell <pid>` | puts the carried crate on the counter (stand at the counter) |
| `salvage.lab.drop <pid>` | forces a drop, as a death would |
| `salvage.lab.reset [node\|all]` | wrecks back to full charges (a new node id: closed ids are tombstones) |
| `salvage.lab.state <pid>` | the player's crates (state, token, placement, contents), tools, cash, society, receipts |

## 5. Limits

- Positions of the foreman, bays and counter are arithmetic, not walked (`measured = false`).
- `tool.crowbar` does not exist as a prop host: the fire axe stands in while prying.
- A crate on the ground can be picked up by any on-duty scrapper (`pickupBy = "crew"`); the
  seller is whoever hands it over. `pickupBy = "owner"` restricts lifting to the filler.
- The bed counts the token's 2 kg, not the contents (they stay in the hold).
- A restart during a carry puts the crate back where it was last put down (custody never left).
- Ground crates are open77_actions items: at most 128 per owner (`maxOpen` 48 here).
