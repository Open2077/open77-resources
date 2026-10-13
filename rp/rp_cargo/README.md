# rp_cargo

Lets a vehicle carry crates in its bed: each crate is held by the vehicle's plate and drawn on whichever car carries that plate. It is an opt-in service for job resources such as rp_salvage, with console commands to measure and tune each vehicle's bed layout.

- **Docs:** [Durable transactions](https://open2077.net/docs/transactions), [Synchronized attachments](https://open2077.net/docs/attachments)
- **Starts:** with `ensure rp_cargo` (it declares `auto_start false`)
- **Needs:** `rp_garage`, `open77_props`, `open77_transactions`
- **Runs on:** server

Row **A9** of the world-interaction plan: crates and other physical objects carried in a
vehicle's bed, held durably by the **plate**, drawn on whichever runtime vehicle currently
carries that plate. Opt-in (`auto_start false`), server-only.

**Status.** Everything below was written and tested on the fake host
(`tests/test_a9_cargo.py`). One layout was checked in game: the Mackinaw bed
(`Vehicle.v_standard3_thorton_mackinaw_player`) is `measured: true`. Every other offset in
`data/layouts.json` is a **starting guess** (`measured: false`). The design notes, the API needs
from the coordinator and the measurement procedure are in
[`docs/world-interaction/a9-cargo.md`](../docs/world-interaction/a9-cargo.md).

## Three owners, three jobs

| What | Who owns it | Where |
|---|---|---|
| **Custody**: which crate is in which vehicle | the A13 coordinator `open77_transactions` | account `veh:<plate>:cargo`; each crate is an item **instance**, its slot is the instance metadata `meta.cargo = { slot, layer, model }` written by the same commit that moves it in |
| **Access**: may this player put, take or look | `rp_garage` | `exports.rp_garage:canAccess(playerId, plate, "cargo", "put" \| "take" \| "view")` |
| **Projection**: the props players see | `rp_cargo` | one prop per instance, `Open77.props.attach` to the vehicle (root binding), rebuilt from the coordinator |

Nothing durable is keyed by a runtime vehicle id or a prop id. A visual failure after a commit is
retried by the projection; it never re-runs the economic operation. An open tailgate in the
world is not authorization.

## Layouts (`data/layouts.json`)

One entry per vehicle record (with `aliases` for records that share the entity template). Vehicle
frame of the root binding: **+x right, +y forward (towards the cab), +z up**, yaw in degrees
around z. A slot holds `maxStack` objects, each layer `stackHeight` metres above the last.

```json
"Vehicle.v_standard3_thorton_mackinaw_player": {
  "label": "Thorton Mackinaw bed",
  "part": "cargo",
  "capacityKg": 300,
  "measured": true,
  "entityTemplate": "0x8F1579854FD1989D",
  "basis": "where the numbers come from",
  "aliases": [],
  "slots": [
    { "id": 1, "x": -0.55, "y": -1.5, "z": 0.9, "yaw": 0.0, "stackHeight": 0.55, "maxStack": 2, "measured": true }
  ]
}
```

Shipped (only the Mackinaw is `measured: true`, the other three are `measured: false`):

| Record (aliases) | Slots × stack | Basis |
|---|---|---|
| `Vehicle.v_standard3_thorton_mackinaw_player` | 4 × 2 | the bed slots rp_nomade 1.x shipped as starting guesses (its `Truck.bed`; rp_nomade 2.0 keeps no bed layout of its own), checked in game on two clients with `crate.small` over two layers and set to `measured: true` |
| `Vehicle.v_standard3_thorton_mackinaw_02_player` (`_ncu_player`) | 4 × 2 | copied; a **different** entity template from the Mackinaw, measure separately |
| `Vehicle.v_utility4_chevalier_legatus_player` | 4 × 2 | copied; larger body, expect every offset to move |
| `Vehicle.v_standard25_thorton_colby_pickup_player` (`_pickup_02_player`) | 4 × 2 | guess by analogy, smaller bed |

Validation refuses a whole layout (never half-loads it): duplicate slot ids, offsets beyond
±20 m or yaw beyond ±360° (the attach bounds), `maxStack` outside 1..8, more than **24 objects**
(a vehicle carries at most 32 attached props across all resources), no capacity, or
`measured: true` while a slot is not. Refusals are logged at start.

Capacity (`capacityKg`) is a gameplay number enforced by the coordinator from item weights; the
slot count bounds what is drawn.

### Other box models (`shared/config.lua`)

A slot's `z` and `stackHeight` are measured with `crate.small`. A smaller box drawn at those
numbers floats, so two maps adapt them per model alias:

| Key | Shipped | Meaning |
|---|---|---|
| `Config.seats` | `crate.ammo_box = -0.40` | how far that model's origin sits from a `crate.small`'s when both rest on the same floor (metres, added to the slot's `z`). Measured on a Mackinaw with the tailgate open, standing and crouched: an ammo box rests on the bed floor at slot `z` 0.5 where `crate.small` sits at 0.9; at 0.9 it hung at the height of the bed rails. |
| `Config.stackHeights` | `crate.ammo_box = 0.32` | the height one box of that model takes in a stack (metres): a stack rises by the heights of the boxes under it, so a second ammo box rests on the first instead of a hand's width above it. |

A model not listed uses the slot's own numbers (seat 0, the slot's `stackHeight`). The model of an
object is the one its load named (rp_nomade and rp_chooh2 name `crate.ammo_box`), else
`Config.models[item]`, else the layout's.

## Exports

Mutating calls go through the coordinator and **yield**: call them with the promise form.

```lua
local function cargo(name, ...)
    return Open77.exports.call("rp_cargo", name, ...):await()
end

-- Put a crate instance the player carries ("char:<subject>") into the bed of vehicleId.
local res, why, info = cargo("load", playerId, vehicleId, "crate-7f3a01", {
    opId = "salvage:load:" .. claimId,   -- your business id: a retried intent replays, never doubles
    -- from = "world:<id>",              -- or from a ground container instead of the pockets
    -- slot = 3,                         -- a specific slot; default: floor first, then stack
    -- model = "crate.small",            -- the prop drawn; default Config.models[item] or the layout's
})
-- res = { opId, plate, account, slot, layer, propId, replay, already? }

local out = cargo("unload", playerId, vehicleId, nil, { to = "char:<subject>" })  -- the top crate
local view = cargo("contents", playerId, vehicleId)  -- needs "view"; { slots = {...}, objects, free }
cargo("reconcile", "NC-K7P2")                        -- redraw a plate from the coordinator

exports.rp_cargo:layout(record)      -- synchronous: plain copy of a layout, or nil
exports.rp_cargo:projection(plate)   -- synchronous: { vehicleId, props = { { instance, propId, slot, rank } } }
```

Refusals (`nil, reason, info`): `invalid_player_id`, `invalid_vehicle_id`, `invalid_instance`,
`invalid_op_id`, `invalid_source`, `invalid_destination`, `vehicle_not_found`,
`vehicle_not_tracked` (no plate: no durable container), `no_cargo_layout`, `player_not_found`,
`wrong_bucket`, `too_far` (`Config.reach` 6 m), `vehicle_moving`, every `rp_garage:canAccess`
reason (`no_access`, `impounded`, `warrant_required`, ...), `garage_unavailable`,
`cargo_full`, `slot_full`, `invalid_slot`, `cargo_empty`, `not_in_cargo`, `busy`, and the
coordinator's own (`capacity_exceeded`, `instance_unavailable`, `op_id_conflict`,
`store_unavailable`, `coordinator_unavailable`, `in_doubt`, ...).

`in_doubt` means the commit may have happened: the slot stays claimed until the coordinator
settles it (`status` with `resolve`), then the sweep redraws. Never treat it as a failure.

Event: `rp_cargo:changed(plate, "loaded" | "unloaded", instanceId, slot, layer)`.

## When the projection is rebuilt

| Trigger | What happens |
|---|---|
| `rp_garage:spawned(plate, vehicleId)` (take-out, dealership, `spawnOwned`) | the plate's cargo is drawn on the new runtime id, same slots |
| `rp_garage:despawned` (stored, impounded, lost) | the props go; the cargo stays in `veh:<plate>:cargo` |
| `onPropAttachmentChanged` with no binding (vehicle removed, parent bucket changed) | redraw (in the vehicle's new bucket) |
| `open77_transactions:committed` touching a drawn `veh:` account, from another resource | redraw (an inventory move, a theft, an admin fix) |
| `onVehicleAuthorityChanged`, `onPlayerReady` | verify only: the binding is on the canonical vehicle id, a new driver or a reconnect changes nothing |
| start, `rp_garage` restart, every `Config.sweepMs` (15 s) | scan the world, settle operations in doubt, verify every prop |

Operations on one plate run one at a time (two players loading the same truck are served in
turn, never into the same slot). Slotless objects moved in by another resource are drawn in the
least-filled slot when their item has a model in `Config.models`.

## Test commands (console only, explicit ids)

| Command | What it does |
|---|---|
| `cargospawn <vehicleId> [layers\|all] [model]` | a test crate at every slot of the vehicle's layout (and every layer with `all`); works on any vehicle of a known record, tracked or not |
| `cargotune <vehicleId> <slot> <x> <y> <z> [yaw] [stackHeight]` | moves one slot of that record's layout live: test crates and cargo already drawn follow; until restart |
| `cargolayout <vehicleId>` | prints the record's layout as JSON: paste it over the entry in `data/layouts.json` |
| `cargoclear <vehicleId>` | removes the test crates |
| `cargoinfo <vehicleId\|plate>` | plate, account, version, occupancy per slot, drawn prop ids |

A tuned slot stays `measured: false`: flip it to `true` in the data file only after checking it
on both clients (see the measurement steps in the A9 doc).

## Manifest

Permissions `world.props`, `world.vehicles`, `filesystem.read` (the data file). Dependencies
`rp_garage`, `open77_props >=0.1.0` and `open77_transactions >=0.1.0` (Open77 `697e9e2f`; list it in
`resources.load`). Under a per-part `writers` list (`rp_cargo:veh/cargo`) the pockets side of a
load or unload is granted per operation by `rp_inventory:grantPockets`.

## Log (grep-able)

```text
[rp_cargo] 4 layout(s) from data/layouts.json, 3 not measured yet (starting guesses)
[rp_cargo] layout refused: Vehicle.x: slot 2: duplicate id 1
[rp_cargo] player 1 loaded crate-7f3a01 into NC-K7P2 slot 1 layer 1 (op salvage:load:42)
[rp_cargo] load of crate-7f3a02 into NC-K7P2 in doubt (op ...): slot 2 stays claimed
[rp_cargo] operation ... on plate NC-K7P2 settled: committed
[rp_cargo] plate NC-K7P2: 3 cargo prop(s) removed (despawned)
[rp_cargo] attach of crate-7f3a01 to vehicle 812 (plate NC-K7P2, slot 1) refused: attachment_parent_limit
[rp_cargo] the coordinator answers no subjectOf: using Open77.players.identifier (the A13 default subject)
```

## Tests

```text
python -m unittest discover -s tests -p "test_a9*.py"
```

`tests/test_a9_cargo.py` (14 tests) runs this resource's real server scripts on the B8 fake host
with a fake coordinator (`tests/compat/fake_tx.lua`) and a stub of `rp_garage`'s A9 exports.
`tests/test_a9_garage_access.py` (11 tests) runs the real `rp_garage` access matrix.
