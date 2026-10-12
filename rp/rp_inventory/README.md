# rp_inventory

Gives every player pockets with a weight limit, opened as a panel with /inv, where they use, drop and give items. Dropped items become loot on the ground, and shared stashes open in the same panel.

- **Docs:** [Durable transactions](https://open2077.net/docs/transactions), [Server loot and ground drops](https://open2077.net/docs/loot)
- **Starts:** on its own
- **Needs:** `open77_uikit`, `open77_contextmenu`, `open77_loot`
- **Runs on:** server and client

The pockets of a Night City RP server. Server-authoritative: clients only render
and request. Two storage backends, chosen once per boot (convar
`rp_inventory_backend`, else `RpInventoryConfig.backend`), never switched while
running:

- **`legacy`** (default): items live in the server's memory for every connected
  player, every change is written straight through to SQL (`rp_inventory_items`,
  `rp_inventory_stashes`) or, when the server has no database, to the resource's
  `Open77.kvp` store. This is the original behaviour, kept as the rollback path.
- **`transactions`**: a facade over **`open77_transactions`** (the Open77 durable
  transaction coordinator, world-interaction row A13). Pockets, stashes, vehicle
  parts and world containers are coordinator accounts; the synchronous exports
  keep their signatures (write-behind), new `*Async` exports are single atomic
  operations with receipts, and there is **never** a kvp fallback. Legacy rows
  are imported once per subject. See *Transactions backend* below and
  `docs/world-interaction/b1b2-inventory.md`.

Item definitions follow the **B1 schema** (`shared/schema.lua`) in both
backends: the `shared/items.lua` shape imports unchanged, colliding ids are
refused, and optional v1 fields add metadata, durability, serials, quality,
stack limits and prop/hand/loot mappings.

- Max carry weight: **40 kg** (`RpInventoryConfig.maxCarryWeight`).
- Items: `shared/items.lua` (`id, label, weight, usable, illegal, effect`).
- The pockets panel: a WebUI page shipped by this resource (`web/index.html`),
  opened by `/inv`, fed by the server (`rp_inventory:panel`) and driving it with
  intents (`rp_inventory:intent`); a chat listing replaces it when the client
  has no WebUI. Stashes (`openStash`) are the same panel with a second column.
- Player-to-player actions: ALT+click a player (`open77_contextmenu`),
  slash commands as the fallback.
- Ground drops: the loot API (`Open77.loot.*`), picked up with the game's own
  prompt or `/ramasser`.

## Commands

| Command | What it does |
|---|---|
| `/inv` | Opens the **POCKETS** panel: your RP name, the weight bar (`9.0 / 40 kg`), a tile per item (label, count, weight, category glyph, illegal items in red) and, for the selected tile, **Use / Give / Drop** with a count field. Escape or the `x` closes it. Falls back to a chat listing when the client has no WebUI (`Panel unavailable (webui_unavailable); listed in chat.`). |
| `/use <item>` | Uses one unit. A 3 s progress bar (cancellable), then the effect. |
| `/drop <item> [n]` | Removes `n` (default 1) from the pockets and creates a pickable ground drop at the player's feet (30 min TTL). |
| `/ramasser` | Picks up the nearest `rp_inventory` drop within 3 m, for when the native prompt is not convenient. |
| `/give <playerId> <item> [n]` | Hands items to a player within 3 m; the server checks the distance and the receiver's carry weight. ALT+click > **Give item** opens the same thing as a dialog. |
| `/fouiller <playerId>` | Searches a player who is **held by the RP kit** (`open77_rp_basics`) **or has hands up** (`handsup` RP profile). Lists their pockets and names the contraband. ALT+click > **Search pockets** does the same. |
| `/saisir <playerId> <item>` | Seizes every unit of an **illegal** item from a searched player. `implant_box` counts as legal for a `medecin` (rp_jobs). |
| `/giveitem <playerId> <item> [n]` | Admin/console (ACL `command.giveitem`): puts items into a player's pockets. Works from the server console. |

`<item>` accepts the id (`burrito`), the label (`Burrito`) or an unambiguous
prefix (`bur`).

### The panel

`/inv` opens `web/index.html`. The page is presentation only: the **server owns the panel**
and pushes its whole state through `rp_inventory:panel` when it opens and after **every**
change of the pockets, the open stash or the cargo view, whoever caused it (a command, the
page, another resource through `add` / `remove`, another player storing into the same stash,
any resource committing on `open77_transactions`). Every push goes to **one player**
(`TriggerClientEvent(..., playerId, ...)`); nothing of the panel is ever written to a state bag
or broadcast. The `I` key is not bound (the game uses it).

**Focus (world-interaction row B7, `docs/world-interaction/b7-ui.md`).** The surface is created
at start and left visible with an empty, transparent document (a hidden-to-visible surface did
not reliably repaint, `wiki/webui.md`); the page draws only while a state is open.

- Browsing takes the **cursor only** (`setFocus(false, true)`): the keyboard stays with the
  game, so chat, push-to-talk and movement keys are not captured. The keyboard is taken only
  while the count field has the caret (`setFocus(true, true)`), and given back when it leaves.
- The panel never opens over another menu holding the keyboard (`Open77.input.isCaptured`,
  permission `input.actions`): it waits up to a second, then gives up and the server says
  `Another menu holds the keyboard: close it, then /inv again.`
- Every exit releases the focus: the `x`, Escape (the page while typing, `open77:pauseKey`
  while browsing), the server's `{ open = false }` (death, resource stop), another surface taking
  the focus (the panel closes instead of fighting for it), `open77:session:ended`, the
  resource stopping, and a focus that never arrived within `panelFocusGraceMs`. A watchdog
  releases any focus the page still holds while closed.
- The player can walk while it is open, so the stash column closes past `panelStashReach`
  (6 m) from where it opened, and the cargo view past `panelCargoReach` (+1 m) of its vehicle.

State payload (`rp_inventory:panel`, server -> client -> page `state` event):

```lua
{
  open = true, seq = 12, backend = "transactions" | "legacy",
  playerId = 3, name = "Vincent Marino",                    -- rp_identity fullName, else the account name
  pockets = { id = 3, entries = { ... }, weight = 9.0, capacity = 40, sync = { ... }? },
  stash   = { id = "home:12", entries = { ... }, weight = 12.5, capacity = 200, sync = { ... }? },  -- while a stash is open
  cargo   = { plate, record, capacityKg, objects, free, readOnly = true,
              slots = { { slot, maxStack, objects = { { instance, item, label, rank } } } } },     -- read-only cargo view
  nearest = { playerId = 4, name = "Jackie Welles", distance = 1.2 },            -- the Give target, or nil
  pending = { { opId, action, item, label, count, ageSeconds, state } }?,         -- actions answered in_doubt
  notice  = { ok, kind = "ok"|"refused"|"retry"|"pending", text, reason?, code?, opId?, stale? },
}
-- entries: { id, label, count, weight, total, usable, illegal, category, unique?,
--            held?      units leaving in an operation the store has not settled ("in transit")
--            variants?  { { asset, count, meta = { quality = 3 } } }      stackable items with stack fields
--            units?     { { id, meta = { durability, serial, ... } } }   unique items, most worn first (24 per item, 64 per container)
--            moreUnits? }                                                  sorted by label
-- sync (transactions backend): { saving = write-behind not acknowledged, inflight, incomingKg = credits in flight }
-- category (tile glyph only): heal food drink fuel smoke drug stamina tech tool material cargo misc
{ open = false }   -- closes the panel
```

The client adds `def = { durabilityMax, quality, serial }` to each entry from its verified B1
catalogue copy (`client/catalogue.lua`), so the page shows `dur 12/20`; without it the raw
values are shown.

Intents (page `intent` event -> client -> `rp_inventory:intent` -> server). Every one carries
the `seq` of the state it was made on, lands in the function the matching command uses, is
re-validated there and is followed by a state push carrying the `notice`. **One intent at a time
per player**: a second one while the first runs answers `busy_intent`.

| intent | payload | server path |
|---|---|---|
| `use` | `{ item }` | `/use`: 3 s progress bar, effect, one unit debited |
| `drop` | `{ item, count }` | `/drop`: ground drop at the feet, 30 min |
| `give` | `{ item, count }` | `/give` to the **nearest other player within 3 m** (`Open77.players.closest`), same distance / weight checks |
| `store` | `{ item, count }` | pockets -> open stash (capacity checked; one coordinator operation in the transactions backend) |
| `take` | `{ item, count }` | open stash -> pockets (carry weight checked) |
| `cargo` | `{ close? }` | read-only cargo of the vehicle the player sits in, else the nearest registered one within `panelCargoReach`: `rp_garage:canAccessVehicle(..., "cargo", "view")`, then `rp_cargo:contents`. Re-read on every commit on that account, `rp_cargo:changed`, `rp_garage:changed` / `despawned`; closes on refusal |
| `refresh` | | a fresh state, nothing moved |
| `close` | | the server forgets the panel (Escape, the `x`, focus taken, a client restart) |
| `blocked` | `{ reason }` | the client would not open over a menu holding the keyboard |
| `unavailable` | `{ reason }` | sent by the client when `Open77.webui.create` failed: the pockets (and the stash) are listed in chat instead |

A refusal keeps its token (`notice.reason`, plus `notice.code` for the coordinator's own, such
as `capacity_exceeded`), and the state that comes with it is the current one. A click made on an
older state that is refused `not_enough` reads `That changed meanwhile: here is what you have
now.` An action answered **`in_doubt`** is listed under *Pending* (its units shown *in transit*,
never as gone) and its operation is read (read-only `status`, never `resolve`) until it is
committed (`Confirmed: Stored Scrap x2.`) or proven not committed (`Not done: ... Nothing was
lost.`); a closed panel gets the answer in chat.

Money is not an item and never appears on the panel (`rp_economy` owns it; `rp_hud` shows it).

### Items

| id | label | kg | usable | effect |
|---|---|---|---|---|
| `water` | Bottle of water | 0.5 | yes | `rp_needs:consume` (thirst) |
| `burrito` | Burrito | 0.4 | yes | `rp_needs:consume` (hunger) |
| `nicola` | NiCola | 0.4 | yes | `rp_needs:consume` (thirst) |
| `chooh2` | CHOOH2 fuel can | 5.0 | yes | `open77_fuel:refuel(vehicle, 20)` on the vehicle the player sits in |
| `bandage` | Bandage | 0.2 | yes | `Open77.players.heal` +25 |
| `maxdoc` | MaxDoc Mk.1 | 0.3 | yes | heal +60 |
| `bounceback` | Bounce Back Mk.1 | 0.3 | yes | heal +40 and full stamina |
| `phone` | Holophone | 0.3 | no | |
| `radio` | Radio | 0.8 | no | |
| `lockpick` | Lockpick | 0.1 | no | |
| `scrap` | Scrap | 1.0 | no | |
| `component` | Component | 0.5 | no | |
| `chip` | Data chip | 0.05 | no | |
| `cigarettes` | Pack of cigarettes | 0.1 | yes | `rp_needs:consume`: smoking gesture, fatigue +5, hunger -2; flavour if needs is offline |
| `synthcoke` | Synthcoke | 0.1 | yes | **illegal**; full stamina |
| `implant_box` | Implant box | 2.0 | no | **illegal** unless the holder has the `medecin` job |
| `crate` | Cargo crate | 25.0 | no | heavy cargo |

A heal is refused at full health, food and drink are refused when `rp_needs`
says so (`nil, reason`), and the fuel can is refused outside a vehicle or when
no fuel system runs. In every case the item stays in the pockets and the
player is told why.

## Exports (server)

Phase 1 contract, all synchronous-safe (nothing yields), so both spellings work.
Same signatures and refusal tokens on both backends (`tests/test_compat_inventory.py`
runs the same calls on both and compares every answer):

```lua
exports.rp_inventory:add(playerId, "burrito", 2)             -- true | nil, reason
local ok = exports.rp_inventory:remove(playerId, "burrito", 1) -- true | nil, "not_enough" | reason
exports.rp_inventory:has(playerId, "chooh2", 1)              -- boolean
exports.rp_inventory:count(playerId, "scrap")                -- number
local entries, weight, capacity = exports.rp_inventory:list(playerId)
-- entries = { { id, label, count, weight, total, usable, illegal }, ... } sorted by label
exports.rp_inventory:openStash(playerId, "house_12", 200)    -- true (panel scheduled) | nil, reason
```

Reasons: `invalid_player`, `player_not_found`, `not_loaded` (the pockets are
still being read), `unknown_item`, `invalid_count`, `too_heavy`, `not_enough`,
`invalid_stash`, `invalid_capacity`. The transactions backend adds
`store_unavailable` (the coordinator is not running or not ready: nothing
happened), `stack_limit`, `unknown_meta_field`, `invalid_meta`, and for a stash
id that looks like a session or runtime id `session_key` / `runtime_id_key`.

`add` and `remove` take an optional fourth argument, the item's **metadata**
(`exports.rp_inventory:add(id, "ore", 3, { quality = 3 })`): unknown fields and
invalid values are refused; stacks merge only when their metadata is equal. The
legacy backend validates metadata but can only store the default stack
(`meta_unsupported` otherwise). Without metadata, `remove` takes the plain stack
first, then the variants, then the most worn units.

`openStash(playerId, stashId, capacity)` opens the panel in its two-column
form (**POCKETS | STASH `<stashId>`** with the stash capacity, **Store** on a
pocket tile, **Take** on a stash tile, both with a count) on the given player;
`capacity` is in kg (default 100). The stash is loaded from
`rp_inventory_stashes` on first use and every move is persisted. Housing and
vehicle trunks call this with their own stash ids (`home:12`). `/inv` while a
stash is open goes back to the pockets-only panel.

`define(items) -> registered, rejected` lets another resource declare its own
items in the `shared/items.lua` shape (`id = { label, weight, usable, illegal,
effect?, permit? }`, ids `^[a-z0-9_]+$`, label up to 48 chars, weight 0..100 kg).
An item defined this way owns its effect: `/use` only debits one unit and raises
`rp_inventory:used (playerId, itemId)` for the definer to act on; an
`effect = { needs = { thirst = 25 }, text = "Cold and bitter. Good." }` is applied here through
`rp_needs:apply` before the event. Call it from your `onResourceStart` and again whenever `rp_inventory` restarts
(its VM comes back with the built-in table only; rows of an undefined id stay in
SQL and reappear once the id is defined again and the player reconnects):

```lua
local MY_ITEMS = { crowbar = { label = "Crowbar", weight = 1.5, usable = false, illegal = false } }
AddEventHandler("onResourceStart", function(name)
    if name == GetCurrentResourceName() or name == "rp_inventory" then
        pcall(function() exports.rp_inventory:define(MY_ITEMS) end)
    end
end)
```

`define` returns `registered, rejected` (counts, as before) and a third value,
`details = { collisions, reasons, warnings, version }`. An id already defined by
**another** resource is refused (`details.collisions`), never overwritten; the
same resource may define again (the restart handshake above). Ids are at most 32
bytes and never contain `__`. Optional definition schema v1 fields:

| field | meaning |
|---|---|
| `weightG` | integer grams (else `weight` in kg is converted) |
| `maxStack` (`stack`) | most units of one stack a single container holds |
| `unique` | one instance per unit (implied by `durability`, `serial` or a non-stack metadata field) |
| `metadata` | `{ field = { type = "integer"\|"number"\|"string"\|"boolean"\|"enum", default, required, min, max, maxLen, pattern, values, stack } }`; `stack = true` fields (bounded, with a default) select a stack variant |
| `durability` | `{ max, start?, breaks? }` or a number: wear per unit, persisted, `wearAsync` |
| `serial` | `true`: each unit gets its instance id as a serial (never caller-supplied) |
| `quality` | `{ min, max, default }` or `{ values = {...}, default }`: a stack field on stackable items |
| `prop`, `hand` | `{ model?, item?, profile?, bone?, offset?, rotation? }` presentation mappings (validated, not interpreted here) |
| `loot` | `{ record, visual }` for ground drops (the legacy `record` / `visual` map here) |

### New exports

Synchronous (both backends): `backend()`, `catalogueVersion()`,
`itemDefinition(id)`, `accountOf(playerId)`, `stashAccount(stashId)`,
`vehicleAccount(plate, part)`, `worldAccount(id)`, and
`registerAuthorizer(scope, exportName)` (scopes `veh`, `world`, `stash`,
`stash:<prefix>`; one resource per scope; the export answers `true`, or
`false, reason`).

Asynchronous, transactions backend only (call them with
`Open77.exports.call("rp_inventory", name, ...):await()`; the legacy backend
answers `nil, "backend_legacy"`). Each mutation is **one** coordinator
operation and returns its receipt (`receipt.opId`), or `nil, reason, info`;
`opts.opId` makes a retry idempotent; `in_doubt` carries `info.opId` for `status`:

```lua
giveAsync(fromId, toId, itemId, count, opts?)          -- opts: opId, meta, instances, maxDistance
storeAsync(playerId, stashId, itemId, count, opts?)    -- pockets -> stash:<id> (opts.capacity in kg)
takeAsync(playerId, stashId, itemId, count, opts?)     -- stash:<id> -> pockets
sellAsync(playerId, { items = {{item, count}}, buyer = "dealer", payouts = {{to = "cash"|"bank"|"soc:<name>", amount}} })
openVehicle(plate, part, capacityKg)                   -- create / resize veh:<PLATE>:<part>
vehicleStoreAsync(playerId, plate, part, itemId, count, opts?)  -- needs the `veh` authorizer (fails closed)
vehicleTakeAsync(playerId, plate, part, itemId, count, opts?)
createWorld(capacityKg, opts?)                         -- a new world:<id> container
worldPutAsync(playerId, worldId, itemId, count, opts?)
worldTakeAsync(playerId, worldId, itemId, count, opts?) -- concurrent takes: one winner
wearAsync(playerId, itemId, amount, opts?)             -- -> { receipt, instance, durability, broken }
addAsync(playerId, itemId, count, meta?, opts?)        -- durable credit with a capacity refusal
removeAsync(playerId, itemId, count, opts?)
moveAsync(moves, opts?)                                -- server-to-server, explicit durable accounts
read(account)                                          -- items, stacks, instances, weightKg, capacityKg
status(opId)                                           -- { state, receipt? } after an in_doubt
```

`sellAsync` refuses `wallet_not_coordinated` until `RpInventoryConfig.coordinatorWallets`
is set: the money side belongs to the wallet adapter (row B3), and paying a
coordinator `cash:` account that `rp_economy` does not read would fork the money.

## Events (host-wide bus)

```lua
AddEventHandler("rp_inventory:changed", function(playerId, itemId, delta) end) -- every credit/debit
AddEventHandler("rp_inventory:used", function(playerId, itemId) end)           -- after a successful /use
```

Client -> server requests (internal): `rp_inventory:giveMenu(targetPlayerId)`,
`rp_inventory:search(targetPlayerId)`, raised by the ALT+click actions;
`rp_inventory:intent(payload)` from the panel. Server -> client:
`rp_inventory:panel(state)` (see *The panel*).

## Logs

Every change is one grep-able line:

```
[rp_inventory] player 3 +2 burrito total=2 (export add)
[rp_inventory] player 3 -1 burrito total=1 (used)
[rp_inventory] player 3 -1 crate total=0 (dropped as loot 17)
[rp_inventory] player 4 +1 crate total=1 (picked up loot 17)
[rp_inventory] stash house_12 +3 scrap total=3 by player 3
[rp_inventory] player 5 searched player 3
```

## Persistence

### Legacy backend

```sql
rp_inventory_items   (identifier VARCHAR(64), item_id VARCHAR(32), count INT, PRIMARY KEY (identifier, item_id))
rp_inventory_stashes (stash_id   VARCHAR(64), item_id VARCHAR(32), count INT, PRIMARY KEY (stash_id, item_id))
```

Both tables are created inside `Open77.database.ready` with
`CREATE TABLE IF NOT EXISTS`. Rows are keyed by `Open77.players.identifier`,
never the session id. A player's pockets are read on `onPlayerReady` (the
resource waits up to 10 s for a database that is still connecting) and on a hot
reload for everyone already connected; nothing is written at disconnect because
every change was already written. When the server has **no** database
(`database_unavailable`) the kvp store is used instead and the log says so
(`loaded from kvp: database not ready (...)`). A failed SQL read never marks the
pockets loaded: the player is told to reconnect rather than risk a later write
erasing real rows.

### Transactions backend

Select it with the convar `rp_inventory_backend transactions` (or
`RpInventoryConfig.backend = "transactions"`) and put `open77_transactions` in
the server's `resources.load`. `open77_transactions` is server-only, so it is
**not** a manifest dependency of this client-delivered resource; while it is not
running or not ready every mutation answers `store_unavailable`, reads keep the
not-loaded semantics, and nothing is written to kvp, ever.

- **Accounts.** `char:<identifier>` (the account identifier, which is also the
  default character id), `stash:<stashId>`, `veh:<PLATE>:<part>` and
  `world:<id>`. Session ids, all-digit keys and `trunk:<runtimeId>`-style stash
  ids are refused (`session_key`, `runtime_id_key`).
- **Synchronous exports are write-behind.** `add` / `remove` / `/use` /
  `/giveitem` change the view at once and are submitted in the background, one
  operation at a time per account, as deltas journaled against the calling
  resource (`sys:<resource>`, `sys:admin`, `sys:used`). A write the coordinator
  refuses later is logged as LOST and the view resyncs, with a compensating
  `rp_inventory:changed`. This is no stronger than the old write-through: flows
  that must not lose value use the `*Async` exports.
- **Atomic flows.** `/give`, `/saisir`, the panel's store / take and `/drop` /
  pickup are single coordinator operations in this backend: nothing is rolled
  back by hand, and a crash at any step leaves either the old or the new state.
- **Other writers.** The coordinator's `open77_transactions:committed` event
  reloads any container this resource shows.
- **Import.** On a subject's first load (or `invmigrate all` from the console,
  ACL `command.invmigrate`), its legacy rows are committed once from
  `sys:migration` under deterministic operation ids, then marked in
  `rp_inventory_migrations` (format version, row count, hash of the rows). The
  legacy tables are never modified. A rerun imports nothing twice. Refused
  explicitly, never silently: an unknown item id (`importUnknownItems` imports it
  with a placeholder weight of 0 and reports it), a marker from another format
  version (`migration_version_mismatch`), legacy rows changed after the import
  (`legacy_diverged`, until `invmigrate accept char|stash <key>`), a legacy
  layout other than the one above (`source_schema_mismatch`), and a coordinator
  whose store is not durable SQL (`store_not_durable`). Imported pockets above
  40 kg keep their items and can only be emptied. Kvp data is never imported here.

```sql
rp_inventory_migrations (account VARCHAR(96) PRIMARY KEY, version INT, op_id VARCHAR(96), source_rows INT,
                         source_hash CHAR(16), weight_g BIGINT, capacity_g BIGINT, report TEXT, migrated_at BIGINT)
```

## Item catalogue (clients)

The server announces the catalogue's head (`rp_inventory:catalogue`: schema,
version, hash, page count) on join and once after a burst of `define` calls.
`client/catalogue.lua` fetches the pages one at a time
(`rp_inventory:catalogueRequest` -> `rp_inventory:cataloguePage`, at most 64
entries and 24 KiB each, rate-limited per player), verifies the hash and exposes
the client exports `catalogueItem(id)` and `catalogueVersion()`. No state bag
carries it. The panel does not depend on it.

## Ground drops

A drop is an `Open77.loot.create` with the documented `Items.money` /
`Items.MoneyShard` pair (the only record pair the devkit guarantees), the RP
label, and a 30 min TTL. The resource keeps `lootId -> { itemId, count }`, so
`onLootPickup` credits the real RP item, not eddies. A picker who cannot carry
it gets the drop re-created at their feet and a message. Per item,
`record` / `visual` in `shared/items.lua` override the TweakDB records once
verified on your build.

In the transactions backend a drop is a `world:<id>` container holding the
goods; the loot is only its projection. The pickup is one operation from the
container to the picker; a refused pickup leaves the goods in the container and
re-creates the loot **where it lay**; an expired drop evaporates through a
journaled operation. The native loot pickup still grants its record to the
picker's game inventory (the `Items.money` default), as before. An rp_inventory
restart loses the loot projection but not the goods: the coordinator keeps the
drop's metadata, and the next start projects it again where it lay.

## Manifest permissions

`network.events` (events), `database.access` (SQL), `world.loot` (drops),
`world.vehicles` (the seat read for the fuel can; the panel's cargo view finds the vehicle with
`Open77.vehicles.nearby`), `players.stats.read` / `players.stats.apply` (heals),
`players.animations.read` (hands-up check), `input.actions` (client: `Open77.input.isCaptured`,
so the panel never opens over a menu holding the keyboard).
`web_files { "web/**" }` ships the panel page; `Open77.webui.create` needs no
permission (same lines as `rp_mdt`). The transactions backend uses no new
permission: `open77_transactions` is reached through `Open77.exports.call`, and
`database.access` covers `rp_inventory_migrations`. Dependencies: `open77_uikit` (the /use
progress bar and the ALT+click Give dialog), `open77_contextmenu`, `open77_loot`
(all ship a client half). `rp_needs`, `open77_fuel`, `open77_rp_basics` and `rp_jobs` are
reached through exports inside `pcall` and are optional at runtime.

## Test in 2 minutes

1. Start the server with `rp_inventory`, `open77_uikit`, `open77_contextmenu`
   and `open77_loot` in the load list; connect two players (ids 1 and 2). The
   client log says nothing about the page unless it failed
   (`[rp_inventory] webui unavailable: <reason>`).
2. From the server console: `giveitem 1 burrito 3`, `giveitem 1 maxdoc 1`,
   `giveitem 1 synthcoke 2`, `giveitem 1 crate 1`. Player 1 sees the toasts in
   chat; the log shows `player 1 +3 burrito total=3 (giveitem by 0)`.
3. Player 1: `/inv`. The POCKETS panel opens with the player's name top right,
   the header bar reading `26.7 / 40 kg` (67%, cyan), four tiles: `Burrito x3`,
   `Cargo crate x1`, `MaxDoc Mk.1 x1` and `Synthcoke x2` tinted red with an
   `ILLEGAL` tag. Click **Burrito**: the right column shows `x3`, `0.4 kg`,
   `1.2 kg`, a count field and **Use / Give / Drop** (Give reads `nobody within
   3 m` and is greyed while alone). **Use**: the button reads `Working...`, a
   3 s bar, chat `You eat the burrito. Better.` (or the `rp_needs` answer), then
   the tile reads `x2`, the bar `26.3 / 40 kg` and a toast `Used Burrito.`
   Escape (or the `x`) closes the panel and gives the game its cursor back
   (expected: the keyboard stays with the game while browsing, so opening the
   chat closes the panel and push-to-talk still transmits); `/inv` reopens it.
   Log: `player 1 -1 burrito total=2 (used)`.
4. Player 1: `/use maxdoc` at full health: `You are already at full health.`
   Take some damage, use it again: `+60 health`.
5. Player 1: `/drop crate`. A drop appears at the feet; the console
   `giveitem 1 crate 1` again shows `too heavy` only once the pockets exceed
   40 kg. Player 2 walks over and uses the native **Take** prompt, or
   `/ramasser`: `Picked up Cargo crate x1`, log `player 2 +1 crate ... (picked up loot N)`.
6. Player 1 stands next to player 2, `/inv`, click **Burrito**: the Give
   button now reads `to <player 2's name> (1.x m)`. Count `1`, **Give**: chat
   `You hand Burrito x1 to <name>.` on 1, `<name> hands you Burrito x1.` on 2,
   toast `Handed Burrito x1 to <name>.`, the tile drops to `x1`; player 2's own
   open panel (if any) refreshes at once. ALT+click player 2 > **Give item**
   still opens the targeted dialog. Walk 5 m away and `/give 2 burrito`:
   `Get closer. Three metres, arm's length.` From the panel at that distance the
   Give button is greyed (`nobody within 3 m`).
7. Player 2 raises hands (`handsup` RP profile) or is cuffed by an officer with
   the RP kit. Player 1: `/fouiller 2` lists player 2's pockets and names
   `synthcoke` as contraband; `/saisir 2 synthcoke` moves both units. Without
   hands up: `They are neither cuffed nor surrendering.`
8. Reconnect player 1: the pockets come back from SQL (`loaded from sql`).
9. From another resource (rp_housing does it from its home prompt):
   `exports.rp_inventory:openStash(1, "test_stash", 50)`. The panel opens with
   two columns, **POCKETS | STASH `test_stash`** `0.0 / 50 kg`. Click a pocket
   tile: **Store** (`into test_stash`) joins the actions; store two burritos:
   toast `Stored Burrito x2.`, chat the same, the tile moves to the stash
   column, log `stash test_stash +2 burrito total=2 by player 1`. Click the
   stash tile: **Take** brings it back. Escape, reopen: still there
   (`rp_inventory_stashes`). Storing the crate into a 50 kg stash that already
   holds 26 kg: `The stash is full.`
10. Client without a WebUI (or `Open77.webui.create` refused): `/inv` answers
    in chat `Pockets - 26.7 / 40 kg`, the listing, then
    `Panel unavailable (webui_unavailable); listed in chat. Commands: /use /drop /give.`

### Transactions backend (test servers only for now)

Not yet run in game. On a test server with a disposable database:

1. `resources.load` gains `open77_transactions`; the convar
   `rp_inventory_backend transactions`. The log must say
   `backend: transactions` and `transactions backend ready (opId prefix ...)`.
2. Seed the legacy tables (or use a copy of a real database), connect: the log
   says `migrated char:<identifier>: N row(s)` once, then `loaded from
   open77_transactions`. Reconnect: no second import. `invmigrate status` shows
   the counters.
3. Repeat steps 2-9 above: every answer and chat line must match the legacy
   backend's.
4. Stop `open77_transactions`: `/giveitem` and `/use` answer the
   "pockets service is unavailable" line; nothing appears under the resource's
   `data/` kvp file. Start it again: changes work again.
5. Two players pick up the same drop at once: one gets it, the other is told
   `Someone was faster.` or sees nothing happen; the item exists once.
