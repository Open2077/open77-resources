# rp_garage

Gives players vehicles they own: a dealership sells them, garages store them, plates and duplicate keys decide who can drive, and an impound lot keeps a car until its owner pays. It is also the one place other resources ask whether a player may drive, open or load a vehicle.

- **Docs:** [Network vehicles](https://open2077.net/docs/vehicles)
- **Starts:** on its own
- **Needs:** `open77_uikit`, `open77_worldui`, `open77_contextmenu`, `open77_notifications`
- **Runs on:** server and client

Server-authoritative vehicle ownership for the Night City RP build (Open77 `2.31.13+op77.76`).
Every vehicle this resource creates carries a **plate** `NC-XXXX` (state-bag key `plate`, the one
`rp_mecano` already reads) and a row in SQL with the owner's durable identifier, the record, the
paint, the fuel level and the damage snapshot. Garages store vehicles and take them out, the
dealership sells them, keys are duplicates other citizens hold, the impound lot keeps a vehicle
until the owner pays. `rp_garage` is the **source of truth for ownership**; `rp_mecano` keeps its
own impound log and this resource follows its `rp_mecano:impounded` event.

The client only places three POIs and adds ALT+click entries; every distance, ownership and
payment check happens in `server/main.lua`.

**Access (world-interaction row A9).** `exports.rp_garage:canAccess(playerId, plate, part, action)`
is the one server-side answer to "may this player drive / lock / store this car, or look in, take
from or put into its cargo, trunk or glovebox". It knows five kinds of caller: the owner, a key
holder, a mechanic on a job order, the police with a warrant, and everybody else. Inventory and
cargo adapters (`rp_cargo`, the B2 vehicle container) ask it instead of deciding themselves. See
[Access](#access-a9-owner-keys-job-orders-warrants) below and
`docs/world-interaction/a9-cargo.md`.

## Where things are (world metres, real Night City streets)

The hub is Kabuki Market (freeroam spawn `-1191.30, 2006.88, 7.82`), but its alleys are
pedestrian: the garages sit on the **Afterlife street** (Watson, the crosswalk outside the club's
ramp), the dealership in **Westbrook**, the impound at the **Rancho Coronado junkyard**.

| POI | Position | Vehicles appear at | Who |
|---|---|---|---|
| **Afterlife street lot** (public garage: E prompt, ring, map pin, garage sign prop) | `-1408, 960, 23.5` — the street outside the Afterlife's ramp | bays `-1398 / -1392 / -1386, 953, 23.5`, the road lanes east of the crosswalk, yaw 90, 6 m pitch, 3 m clearance | everybody |
| **Mechanic's garage** (society garage) | `-1396, 966, 23.5` — same street, 12 m east (`rp_mecano`'s workshop street) | `-1380, 953, 23.5`, yaw 90, on the same road further east. Derived from the street line, not probed | `mecano` employees (`rp_jobs`) |
| **Westbrook Motors** (dealership, neon frame prop) | `-1442.2, 127.4, 18.1` — the Westbrook vehicle dealership | `-1450.2, 119.9, 14.8` — the Westbrook race grid, yaw 0 (its facing was not measured) | everybody |
| Impound lot (informative) | `1370, -1680, 49.3` — the Rancho Coronado junkyard (`rp_zones` `junkyard`) | — | the fee is paid at any garage |

Straight-line distances from Kabuki Market Centre: Afterlife street lot 1 070 m, Westbrook
Motors 1 900 m, junkyard 4 500 m — a car, a Delamain (`rp_delamain`) or an admin `tp` is the way.
Everything is in `shared/config.lua` (`Config.garages`, `Config.dealership`, `Config.impound`,
`Config.vehicles`, `Config.reach`, ...). `z` values are the probed street heights (+0.1 for a
ring on a driven point); the server tolerates 4 m of height error on a POI check
(`Config.reach.height`) — the dealership bay stands 3.3 m below its ring.

### Props

On start the server spawns real streamed props next to the rings (`Open77.props.create`,
permission `world.props`, bucket 0) and removes them on stop (`Open77.props.remove`): the
`sign.street` sign 3.2 m south of the public lot ring (`-1408, 956.8, 23.5`, facing the bays),
and a `light.spotlight` (fallback `sign.kiosk_frame`) 1.3 m off the dealership ring
(`-1439.6, 129.4, 18.0`, facing it). `Config.<poi>.props[].models` lists curated prop aliases
(see `prop.catalog`; a raw `.mesh` path renders as a white slab) tried in order; a refused model
only logs (`prop of public refused (...)`) and the ring alone marks the POI.

## What the player sees

- Walk to a ring (the garage sign / the neon frame stand next to it), look at it, press **E**
  (`promptDistance` 3 m) — or type `/garage` / `/concession` within 6 m. The server re-checks the distance and opens a UI-kit context menu.
- **Garage menu**: *Store the <car>* (when a vehicle you hold a key for stands within 8 m and you
  are on foot), *Take out the <car>* for every stored vehicle (condition and fuel shown),
  *Impound: <car>* for every impounded one (pay `Config.impound.fee` = 500 €$), disabled rows for
  vehicles out in the city, *Leave*. The mechanic's garage also lists the `mecano` **fleet**.
- **Dealership menu**: one row per record of `Config.vehicles` with the price; a boss of a job
  that owns a society garage also sees *<car> for the <job> fleet*. A confirmation follows.
- Chat lines are English, in eddies (`€$`); toasts through `open77_notifications`.

## Records for sale (checked with `open77_data vehicles`, all `_player` variants)

| Label | Record | Price |
|---|---|---|
| Archer Hella | `Vehicle.v_standard2_archer_hella_player` | 15 000 €$ |
| Arch Nazare (bike) | `Vehicle.v_sportbike2_arch_player` | 12 000 €$ |
| Thorton Mackinaw | `Vehicle.v_standard3_thorton_mackinaw_player` | 28 000 €$ |
| Villefort Cortes Delamain | `Vehicle.v_standard2_villefort_cortes_delamain_player` | 45 000 €$ |
| Quadra Turbo-R | `Vehicle.v_sport1_quadra_turbo_player` | 60 000 €$ |

Payment: `exports.rp_bank:charge(playerId, price, "garage", "purchase:<record>")` (account →
society `garage`); when the account is short (`insufficient_funds`) the cash wallet pays through
`exports.rp_economy:remove` and the society is credited with `societyAdd`. A fleet purchase is
paid with `exports.rp_bank:societyRemove(<job>, price, ...)`. The plate is reserved **before** the
eddies move, so nothing ever needs a refund. The bought vehicle spawns at the dealership bay,
**locked for the street with a per-player exception for the buyer** (`Open77.vehicles.setLocked`
+ `setLockedForPlayer`): the owner and every key holder can enter, nobody else.

## Commands

| Command | What it does |
|---|---|
| `/garage` | Opens the menu of the garage you stand at (within 6 m of its ring). The mechanic's garage refuses anyone without the `mecano` job. |
| `/concession` | Opens the dealership menu (within 6 m of its ring). |
| `/cles <playerId> [plate]` | Hands a **duplicate key** of your vehicle to a player within **5 m**. Without a plate: the vehicle you sit in, else the nearest vehicle you **own** within 8 m. Keys persist in SQL; the holder can enter the locked car, `/verrouiller` it and store / take it out. Only the owner gives keys. |
| `/cles revoke [plate]` (`retirer` also works) | Cancels every duplicate key of that vehicle; online holders lose their lock exception at once. |
| `/cles ordre <mechanicId> [plate] [minutes]` (`order`) | The owner hands a **job order** to a player with the `mecano` job (default 60 min, at most 24 h): while on duty, the mechanic may drive, lock and repair that car and look in its bed and trunk (`canAccess` role `mechanic`), and gets a lock exception. `/cles ordre annuler [plate]` lifts every order on the car. |
| `/cles` | Lists your vehicles: plate, label, state (`stored` / `out` / `impounded`), who holds keys, the wanted flag. |
| `/verrouiller` | Toggles the entry lock of the vehicle you sit in, else the nearest vehicle **you hold a key for** within **6 m** (`Open77.vehicles.isLocked` / `setLocked`, a short horn confirms). Ownership-aware: a vehicle without a plate on file, or one you hold no key for, is refused with the reason. |
| `/plaque` | The vehicle you sit in, else the nearest server vehicle within **8 m**: plate, label, owner's RP name (`rp_identity`, stored at the last write so an offline owner still has a name), whether you hold a key, distance. A **WANTED** line follows when the vehicle is flagged; NCPD on duty read the reason, everybody else reads "by the NCPD". A vehicle without a row answers *No plate on file: an unregistered ride*. |

**ALT+click** (`open77_contextmenu`): on a player **Give a key** (group *Garage*, 5 m — same
flow as `/cles`); on a vehicle **Lock / unlock** (6 m) and **Read the plate** (8 m). The client
only sends the target id; the server resolves distance and keys again.

From the server console every command answers `run it from the game`. The console has one
command of its own: `vehwarrant <plate> <minutes> [reason]` issues a police warrant on that car
for every NCPD officer on duty (`job:ncpd`), `vehwarrant <plate> off` lifts it (test and admin
use; a judge flow in `rp_mdt` would call `authorize` instead).

**`/car` (freeroam, admin) stays.** It spawns an untracked vehicle: no plate, no owner, no row.
`/plaque` on it says *unregistered ride*, `/verrouiller` refuses it (the platform's
`eval_carlock` `/lock` still works on any vehicle), garages cannot store it. Only vehicles bought
at the dealership (or created through `spawnOwned`) are owned.

## Storing, taking out, losing

- **Store**: the vehicle must be empty and within 8 m; `Open77.vehicles.getProperties` (paint,
  health, doors, the 30-cell body grid, glass / lights / tyres masks, torn-off panels) and
  `exports.open77_fuel:level` are saved, then `Open77.vehicles.remove`. Any public garage takes any
  owned vehicle; the society garage takes personal vehicles and its own fleet.
- **Take out**: `Open77.vehicles.create` at the garage bay (three spots 6 m apart along x, a spot
  is skipped when another server vehicle stands within 3 m — *bay blocked* otherwise), then
  `setProperties` with the saved table (engine off, lights off, locked), `open77_fuel:set`, the
  plate state-bag key, and a lock exception for every online key holder. A vehicle that was a wreck
  comes back rolling: the destroyed / exploded flags are cleared and the health floor
  `Config.minHealthOnTakeOut` (20 %) applies — body damage, broken glass and torn panels stay for
  the mechanic (`/reparer`).
- **Lost**: every 30 s the server refreshes, in memory, the condition and fuel of each vehicle out
  in the city. A tracked vehicle removed by something else (admin `/dv`, an explosion clean-up, a
  TTL) goes back to the garage in that last known state (`rp_garage:changed ... "lost"`).
- **Restart**: the world is empty after a server restart and a resource stop removes the vehicles
  it created, so every `out` row is read back as `stored`.
- **Reconnect**: a key holder who comes back (`onPlayerReady`) gets their lock exceptions again on
  every vehicle out in the city.

## Impound

`exports.rp_garage:impound(vehicleId, reason, byPlayerId)` — for `rp_ncpd` / `rp_mecano`: the
vehicle is snapshotted and removed, the row is marked `impounded` with the reason, the owner (if
online) is told. At any garage the owner (or the boss, for a fleet vehicle) sees *Impound: <car>*
and pays `Config.impound.fee` (500 €$, account first then cash, credited to the `ncpd` society —
`Config.impound.society`); the vehicle is then `stored` there and can be taken out at once.
`rp_mecano`'s `/fourriere` removes the vehicle itself and raises `rp_mecano:impounded`: this
resource marks the plate `impounded` (`towed by the garage`) when it hears it.

## Wanted

`exports.rp_garage:setWanted(plate, true, "hit and run")` flags a vehicle: `/plaque` shows it,
every NCPD officer on duty (`exports.rp_jobs:listOnDuty("ncpd")`) reads an APB line in chat, the
row is written through. `setWanted(plate, false)` clears it. `rp_crime:wantedVehicles()` and
`rp_mdt` can read the flag back through `vehiclesOf`.

## Exports (server, synchronous, never yield — call them inside `pcall`)

```lua
exports.rp_garage:ownerOf(vehicleId)        -- identifier | "society:<job>" | nil (untracked)
exports.rp_garage:hasKey(playerId, vehicleId) -- boolean: owner, key holder, or employee of the owning society
exports.rp_garage:vehiclesOf(playerId)      -- { { plate, record, stored, wanted, label, state, vehicleId }, ... } sorted by plate
exports.rp_garage:plateOf(vehicleId)        -- "NC-XXXX" | nil
exports.rp_garage:impound(vehicleId, reason, byPlayerId)
                                            -- true | nil, "invalid_vehicle_id" | "not_owned" | "not_in_world"
exports.rp_garage:setWanted(plate, boolean, reason)
                                            -- true | nil, "unknown_plate"   (plate with or without the NC- prefix)
exports.rp_garage:spawnOwned(playerId, plate)
                                            -- vehicleId | nil, "invalid_player_id" | "player_not_found" | "unknown_plate"
                                            --   | "not_owner" | "impounded" | "already_out" | "position_unknown"
                                            --   | "bay_blocked" | "spawn_failed:<reason>"
                                            -- spawns a stored vehicle 4 m from the player (rp_mdt, admin tools)
```

`vehicleId` accepts the integer `Open77.vehicles.create` returned or its string form (host events
deliver ids as strings). The exports answer from the in-memory cache; SQL is written through with
the callback forms, never awaited on the export path. `rp_garage` ships a client script: a
resource that also ships one may declare `dependency "rp_garage"`.

Access and identity exports (A9, same rules: synchronous, cache-only, never yield):

```lua
exports.rp_garage:canAccess(playerId, plate, part, action)
    -- true, role, state | false, reason
    -- part nil: action drive | lock | store | manage | repair | impound
    -- part "cargo" | "trunk" | "glovebox": action view | take | put
    -- role owner | key | mechanic | police; state stored | out | impounded
    -- reasons: registry_loading invalid_player_id invalid_plate invalid_part invalid_action
    --          vehicle_not_tracked player_not_found no_access action_not_permitted impounded
    --          off_duty no_job_order warrant_required
exports.rp_garage:canAccessVehicle(playerId, vehicleId, part, action)   -- same, from a runtime id
exports.rp_garage:accountOf(plate, part)    -- "veh:<plate>:<part>" | nil, "vehicle_not_tracked" | "invalid_part"
exports.rp_garage:describe(plate)           -- { plate, record, label, state, owner, society, vehicleId, wanted }
                                            --   | nil, "vehicle_not_tracked"; vehicleId only while out
exports.rp_garage:authorize(plate, role, holder, { minutes, reason, by })
    -- role "mechanic" (job order) | "police" (warrant); holder = player id, identifier or "job:<name>"
    -- by (optional player id): the owner for a job order, an NCPD officer on duty of grade >=
    -- Config.access.police.warrantMinGrade for a warrant. Without `by`, the calling resource is trusted.
    -- -> { role, holder, expiresAt } | nil, "invalid_role" | "invalid_holder" | "invalid_duration"
    --    | "not_owner" | "not_police" | "grade_too_low" | "vehicle_not_tracked" | "invalid_plate"
exports.rp_garage:revokeAuthorization(plate, role, holder?, { by })   -- count | nil, "not_found" | ...
exports.rp_garage:authorizations(plate)     -- { { role, holder, grantedBy, reason, expiresAt }, ... }
```

A plate is always a string (`"NC-K7P2"`, or `"K7P2"` with the prefix added): a bare number is
refused as `invalid_plate`, so a runtime vehicle id can never be mistaken for a plate.

## Events (host bus, `TriggerEvent`)

| Event | Arguments | When |
|---|---|---|
| `rp_garage:changed` | `identifier, plate, action` | `bought`, `stored`, `taken_out`, `impounded`, `released`, `key_given`, `keys_revoked`, `wanted`, `unwanted`, `lost`, `authorized`, `unauthorized` (a job order or warrant issued, revoked or expired). `identifier` is the owner (`society:<job>` for a fleet vehicle). An adapter holding an open panel re-checks `canAccess` on every one of them. |
| `rp_garage:stolen` | `plate, byPlayerId` | A player without a key (and without a job order) took the driver seat of an owned vehicle (`onPlayerEnteredVehicle`, `seat_front_left`). At most once per player and plate every 5 min. The driver is warned, the owner (if online) is told. |
| `rp_garage:spawned` | `plate, vehicleId, record` | A tracked vehicle entered the world under a NEW runtime id (dealership, take-out, `spawnOwned`). Cargo and inventory projections re-bind to it (A9). |
| `rp_garage:despawned` | `plate, vehicleId, reason` | That runtime id is gone (`stored`, `impounded`, `lost`). The plate, its keys, grants and cargo stay. |

Consumed: `rp_mecano:impounded (vehicleId, byPlayerId, record, plate)`, `onVehicleRemoved`,
`onPlayerEnteredVehicle`, `onPlayerReady`, `onPlayerDisconnected`, `chat:ready`.

Internal net events (`rp_garage:open`, `rp_garage:dealer`, `rp_garage:giveKey`,
`rp_garage:action`) are the client/server transport of the POIs and ALT+click entries, not an API.

## Access (A9): owner, keys, job orders, warrants

Three things are kept apart:

- **legal ownership**: this registry (owner, key holders, grants), keyed by **plate**;
- **physics authority**: `Open77.vehicles.owner(id)`, whoever simulates the car right now. It moves
  with the driver and is never consulted for access;
- **resource permissions**: `world.vehicles` / `world.props` of the calling resource, which says
  what the *resource* may do, not what a *player* may.

A trunk opened in the world (`Open77.vehicles.isDoorOpen`) is presentation, never authorization.

| Role | Who | Vehicle actions | Parts (cargo, trunk, glovebox) | Gate |
|---|---|---|---|---|
| `owner` | the owner's identifier, or the boss of the owning society | drive lock store manage repair | view take put | refused `impounded` while at the impound lot (except `manage`) |
| `key` | a duplicate-key holder, or any employee of the owning society | drive lock store | view take put | refused `impounded` |
| `mechanic` | a `mecano` employee **on duty** with an active job order for the plate (`/cles ordre`, or `authorize`) | drive lock repair | cargo view, trunk view | `off_duty`, `no_job_order`, `impounded` |
| `police` | an `ncpd` officer **on duty** with a warrant: the plate's wanted flag (`setWanted`) or an active police grant | drive lock impound | view take | `off_duty`, `warrant_required`; no warrant needed at the impound lot |
| anyone else | | | | `no_access` |

The first role that permits the action and passes its gate wins; otherwise the most specific
refusal comes back (`warrant_required` before `no_access`, `action_not_permitted` when a role
exists but does not include the action). The table is `Config.access` in `shared/config.lua`
(roles, jobs, duty requirements, `police.withoutWarrant` for, say, `"cargo:view"`, grant
durations); the decision itself is the pure `server/access.lua`, tested offline in
`tests/test_a9_garage_access.py`.

Grants (job orders, warrants) are rows keyed by `(plate, role, holder)` with an expiry; they
survive a restart, expire in the 30 s snapshot loop (the lock exceptions follow) and raise
`rp_garage:changed ... "authorized" / "unauthorized"`. A holder is a durable identifier or
`job:<name>`: a session id or a runtime id is refused (`invalid_holder`).

## Persistence

The three tables are created inside `Open77.database.ready(...)` with `CREATE TABLE IF NOT EXISTS`
(permission `database.access`) and loaded once into memory; every change is written through with
the callback forms:

```sql
rp_garage_vehicles (
    plate          VARCHAR(16)  PRIMARY KEY,   -- NC-XXXX
    owner          VARCHAR(64)  NOT NULL,      -- Open77.players.identifier, or society:<job>
    owner_name     VARCHAR(80)  NOT NULL,      -- RP name at the last write (offline /plaque)
    record         VARCHAR(256) NOT NULL,      -- Vehicle.* TweakDB record
    label          VARCHAR(64)  NOT NULL,
    state          VARCHAR(16)  NOT NULL,      -- stored | out | impounded
    garage         VARCHAR(32)  NOT NULL,      -- garage id of the last store (dealership at purchase)
    paint          VARCHAR(32)  NOT NULL,      -- "#RRGGBB/#RRGGBB" when custom paint is applied, else ''
    fuel           DOUBLE       NULL,          -- litres (open77_fuel), NULL without the fuel resource
    props          TEXT         NULL,          -- JSON of Open77.vehicles.getProperties (paint, health, damage...)
    wanted         TINYINT(1)   NOT NULL,
    wanted_reason  VARCHAR(64)  NOT NULL,
    impound_reason VARCHAR(64)  NOT NULL,
    bought_at      BIGINT       NOT NULL,      -- unix seconds
    updated_at     BIGINT       NOT NULL,
    INDEX (owner)
)
rp_garage_keys (
    plate       VARCHAR(16) NOT NULL,
    holder      VARCHAR(64) NOT NULL,          -- identifier of the key holder
    holder_name VARCHAR(80) NOT NULL,
    given_by    VARCHAR(64) NOT NULL,          -- identifier of the owner
    at          BIGINT      NOT NULL,
    PRIMARY KEY (plate, holder)
)
rp_garage_grants (                             -- A9: job orders and warrants
    plate       VARCHAR(16) NOT NULL,
    role        VARCHAR(16) NOT NULL,          -- mechanic | police
    holder      VARCHAR(64) NOT NULL,          -- identifier, or job:<name>
    granted_by  VARCHAR(64) NOT NULL,          -- identifier of the issuer, or the calling resource
    reason      VARCHAR(64) NOT NULL,
    expires_at  BIGINT      NOT NULL,          -- unix seconds
    at          BIGINT      NOT NULL,
    PRIMARY KEY (plate, role, holder)
)
```

`rp_garage_grants` is new in wave 1 (A9): `CREATE TABLE IF NOT EXISTS` adds it to an existing
database without touching the two older tables (`tests/compat/schema-snapshot.json` carries it).

**No database** (`ready` answers `database_unavailable`, or nothing answers 15 s after start):
rows fall back to the resource's `Open77.kvp` store (`veh:<plate>` / `keys:<plate>` /
`grants:<plate>`, JSON) and the log says `[rp_garage] store=kvp reason=...`. The choice is kept for the whole boot. Until the
store has answered, the menus and key commands answer *The garage registry is still loading*.

## The plate on the vehicle

`Open77.state.entity("vehicle", id):set("plate", plate)` is written on every spawn, so
`Entity(id).state.plate` reads it on both sides (this is the key `rp_mecano` logs). The write
needs `state.write`, and the manifest declares it (without it the write answers
`permission_denied`). If the write is refused at runtime the log says
`plate state bag refused: <reason>` once and nothing else changes: the plate always lives in SQL
and in the exports (`plateOf`, `vehiclesOf`), and `/plaque` never depends on the bag.

## Manifest

Permissions `state.write` (the `plate` state-bag key), `world.vehicles` (every vehicle read and
write), `database.access`, `network.events` (net events, toasts), `world.props` (the garage sign
and the showroom neon, removed on stop). Dependencies — all ship a client half — `open77_uikit`, `open77_worldui`,
`open77_contextmenu`, `open77_notifications`. `rp_bank`, `rp_economy`, `rp_identity` are
server-only and reached through `pcall`; `rp_jobs` (jobs, boss, duty), `rp_mecano` (its event) and
`open77_fuel` are optional (without the fuel resource the fuel column stays NULL and the tank is
whatever the platform gives a new car).

## Log (grep-able)

```text
[rp_garage] started: 2 garage(s), dealership at -1442 127, 5 record(s) for sale, impound fee 500, society garage
[rp_garage] prop 1042 of public at -1408.0 956.8 23.5 (sign.street)
[rp_garage] prop of dealership refused (invalid_model): light.spotlight
[rp_garage] store=sql tables=rp_garage_vehicles,rp_garage_keys,rp_garage_grants vehicles=3 keys=1 grants=0
[rp_garage] player 1 bought Archer Hella (Vehicle.v_standard2_archer_hella_player) plate=NC-K7P2 owner=<identifier> paid=account
[rp_garage] player 1 stored Archer Hella plate=NC-K7P2 at public
[rp_garage] player 1 took out Archer Hella plate=NC-K7P2 at public vehicle=12
[rp_garage] no prop spawned for dealership: the ring alone marks it
[rp_garage] player 1 gave a key of plate NC-K7P2 to player 2 (<identifier>)
[rp_garage] player 1 locked plate NC-K7P2
[rp_garage] plate NC-K7P2 taken by player 3 (<identifier>) without a key
[rp_garage] vehicle 12 plate=NC-K7P2 impounded by player 4 via rp_ncpd: reckless driving
[rp_garage] player 1 released Archer Hella plate=NC-K7P2 fee=500 (account)
[rp_garage] plate NC-K7P2 wanted=true reason=hit and run
[rp_garage] plate NC-K7P2 lost from the world (removed): back in the garage
[rp_garage] plate state bag refused: permission_denied:state.write (the plate stays in SQL, ...)
[rp_garage] grant mechanic on plate NC-K7P2 to <identifier> for 60 min by <identifier> (job order)
[rp_garage] grant police on plate NC-K7P2 to job:ncpd for 15 min by server (warrant)
[rp_garage] grant mechanic on plate NC-K7P2 to <identifier> expired
```

## Test in 2 minutes

One client with `rp_economy`, `rp_bank`, `rp_identity`, `open77_uikit`, `open77_worldui`,
`open77_contextmenu`, `open77_notifications` running (`rp_jobs`, `open77_fuel`, `rp_mecano`
optional). Start log: `[rp_garage] started: ...`, `store=sql ...` (or `store=kvp reason=...`),
then `prop <id> of public at -1408.0 956.8 23.5 (...)` and `prop <id> of dealership at ...`.
The POIs are 1–2 km from the Kabuki spawn: **teleport** to them from the console (`tp <id>
-1442 127 18.1` for Westbrook Motors, `tp <id> -1408 960 23.5` for the Afterlife street lot)
or drive.

1. **Console**: `givemoney 1 20000` (the player starts with 500 €$ cash; the dealership takes
   the account first, then cash). Open the map: three pins — *Afterlife street lot*,
   *Mechanic's garage* (Watson, Afterlife street) and *Westbrook Motors* (Westbrook).
2. At **Westbrook Motors** (`-1442.2, 127.4`): the neon frame stands 1.3 m off the ring. Look
   at the ring, press **E** (or `/concession`). Pick **Archer Hella** (15 000 €$) → *Buy the
   Archer Hella?* → **Buy**. Chat: `Congrats, choom: Archer Hella, plate NC-XXXX, paid 15 000 €$
   (cash). It is locked for the street; you hold the keys.` + a toast. The car stands on the
   race grid 11 m south-west of the ring. `/money` shows 5 500 €$. Log: `player 1 bought ...`.
3. Get in (it is locked for everybody but you) and **drive** north to Watson: the Afterlife
   street lot is at `-1408, 960` (1.9 km — or `tp` there and `spawnOwned`). `/plaque` from the
   seat: `Plate NC-XXXX - Archer Hella - owner: <your RP name> - you hold a key.`
4. Park within 8 m of the **Afterlife street lot** ring (the garage sign marks it), step out,
   look at the ring, press **E** (or `/garage`). The menu shows *Store the Archer Hella* → the
   car vanishes, chat `Archer Hella (plate NC-XXXX) stored at the Afterlife street lot: 100%
   condition, N L.` Log: `player 1 stored ...`. Open the menu again: *Store* is gone, *Take out
   the Archer Hella* is there with its condition.
5. **Take out** → the car appears in the first free bay (`-1398, 953`, then `-1392`, `-1386`),
   at yaw 90, locked for the street, same paint, fuel and damage. Chat `Archer Hella (plate
   NC-XXXX) is out at the Afterlife street lot bay ...`.
6. Stand next to it: `/plaque` → the plate line and the distance. Walk 10 m away: `/plaque` →
   `No server vehicle within 8 m ...`.
7. Next to the car: `/verrouiller` → `Archer Hella (plate NC-XXXX) unlocked.` (short horn),
   again → `... locked for the street.` Spawn an admin car with `/car` and try `/verrouiller`
   next to it → `That ride has no plate on file ...`; `/plaque` on it → `No plate on file: an
   unregistered ride (...)`.
8. `/cles` → your vehicle list with `no duplicate key`. **Keys need a second player**: with
   player 2 within 5 m, `/cles 2` (or ALT+click player 2 → **Give a key**) → both are told,
   player 2 can now enter the locked Hella and `/verrouiller` it; `/cles` lists the holder;
   `/cles revoke` cancels it. With player 2 sitting in your Hella and no key: chat `Hot ride:
   ...` on their side, `Somebody just took the wheel ...` on yours, and `rp_garage:stolen` on
   the bus.
9. **Impound** from another resource (console `lua` or a test resource):
   `exports.rp_garage:impound(<vehicleId>, "reckless driving", 0)` → the car is gone, you read
   `Your Archer Hella (plate NC-XXXX) was impounded: reckless driving. Settle 500 €$ at any
   garage ...`. At the Afterlife street lot ring: *Impound: Archer Hella* → *Pay 500 €$* →
   `Impound settled ...` and *Take out* is back. `exports.rp_garage:setWanted("NC-XXXX", true,
   "hit and run")` → `/plaque` adds `WANTED by the NCPD.` (an NCPD officer on duty reads the
   reason and gets an APB line).
10. Reconnect: `/cles` still lists the car (SQL), the garage menu still offers it. Check the row:
    `SELECT plate, owner, state, paint, fuel FROM rp_garage_vehicles;`.

Two-player extra: player 1 with the `mecano` job (`setjob 1 mecano 3`) can use the **Mechanic's
garage** ring at `-1396, 966` (12 m east of the public lot); as boss, the dealership shows *<car> for the mecano fleet* (paid by
the `mecano` society — seed it with `setjob` first), and every `mecano` employee holds a key to
the fleet car and sees it in the mechanic's garage.
