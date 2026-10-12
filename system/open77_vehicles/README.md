# open77_vehicles

This resource adds `vehicle.*` commands that spawn, lock, paint, damage, repair and seat players in server-owned network vehicles, plus client exports to read them.
`open77_vehicles` is the reference resource for Open77's server-authoritative network vehicle
system. The server owns identity, durable state, occupancy, and physics authority. Clients render a
spatially streamed REDengine projection.

- **Docs:** [Network vehicles](https://open2077.net/docs/vehicles)
- **Starts:** on its own
- **Needs:** nothing
- **Runs on:** server and client

## Authority model

- Only the server can create a network vehicle.
- The server owns the canonical four-seat occupancy ledger.
- The front-left occupant may receive a short physics lease.
- The lease owner sends motion on the unreliable sequenced channel.
- Observers interpolate transform and drivetrain telemetry.
- Unknown locally spawned vehicles are removed during an authenticated session.
- Players mounted in unknown vehicles are forcibly unmounted.

## Server API

Server resources use:

- `Open77.vehicles.create(definition)`
- `Open77.vehicles.update(id, changes)`
- `Open77.vehicles.setTransform(id, transform)`
- `Open77.vehicles.remove(id)`
- `Open77.vehicles.get(id)`
- `Open77.vehicles.all()`
- `Open77.vehicles.setPaint(id, { primary = color, secondary = color })`
- `Open77.vehicles.getPaint(id)` / `resetPaint(id)`
- `Open77.vehicles.warpPlayerIntoVehicle(playerId, vehicleId, seat, options?)`
- `Open77.vehicles.forcePlayerOutOfVehicle(playerId, vehicleId?)`
- `Open77.vehicles.setPlayerExitLocked(playerId, locked, vehicleId?)`
- `Open77.vehicles.getPlayerSeat(playerId)`
- `Open77.vehicles.getDamage(id)` / `setDamage(id, damage)`
- body: `setBodyDamage`, `setBodyCell`, `damageBodyCell`, `setBodyZone`, `damageBodyZone`, `repairBodyCell`, `repairBodyZone`
- glass: `setGlassMask`, `setGlassBroken`, `breakGlass`, `repairGlass`, `breakAllGlass`, `repairAllGlass`
- lights/tyres: `setLightBroken`, `breakLight`, `repairLight`, `setTireBroken`, `breakTire`, `repairTire`
- repair: `Open77.vehicles.repair(id, scope)` where scope is `glass`, `body`, `lights`, `tires`, `visual`, `mechanical`, or `full`

Vehicle snapshots expose occupants as:

```lua
occupants = {
    {
        playerId = 7,
        seat = "seat_front_left",
        flags = 8,
        entering = false,
        exiting = false,
        forcedEntry = false,
        exitLocked = true,
        forcedExit = false,
    },
}
```

Forced assignments are durable until native confirmation and therefore survive a target vehicle
that has not streamed yet, a routing-bucket move, and stream-out/stream-in. All canonical vehicle
operations are cross-resource for every server resource granted `world.vehicles`; the creator name
is provenance and a deterministic cleanup scope, not a mutation lock. Exit lock prevents ordinary
unmount and seat switching; a forced exit overrides it.

Creating or mutating vehicles requires the `world.vehicles` resource permission.

## Client API

Client resources receive read-only `get` and `all` projections and can subscribe to:

- `Open77.vehicles.getPaint(id)`
- `Open77.vehicles.getPlayerSeat(playerId?)`
- `Open77.vehicles.isPlayerExitLocked(playerId?)`
- `Open77.players.getVehicleSeat(playerId?)`

Client events:

- `open77:vehicleCreated`
- `open77:vehicleRemoved`
- `open77:vehicleAuthorityChanged`
- `open77:vehicleOccupancyChanged`
- `open77:vehicleDamageChanged`
- `open77:vehiclePaintChanged`
- `open77:vehicleSeatsChanged`

Snapshots include transform, health, body damage, glass/light/tire masks, colors, doors, windows, occupancy, speed, RPM, gear,
throttle, brake, steering, suspension, burnout, grounded state, and reverse state where available.

The reference package exports `get`, `all`, `getPlayerSeat`, and `isPlayerExitLocked` as read-only
compatibility wrappers.

## Replication behavior

The authority owner keeps native REDengine physics and engine audio. Observers interpolate the
server-approved transform and drivetrain state, then update the vehicle blackboard and scoped audio
parameters.

Wheel phase is derived from replicated velocity but hard-transform wheel bindings are not mutated.
REDengine may expose an incomplete parent graph immediately after streaming attachment, so visual
wheel posing remains native until a lifecycle-safe adapter is available.

## Administrative commands

```text
vehicle.list
vehicle.create
vehicle.create.player
vehicle.remove
vehicle.engine
vehicle.lock
vehicle.health
vehicle.paint
vehicle.paint.reset
vehicle.glass.break
vehicle.glass.repair
vehicle.repair
```

Mutation commands are restricted and require the corresponding `command.vehicle.*` ACL permission
when invoked by a player.

See the [vehicle guide](https://open2077.net/docs/vehicles),
the [Game data reference](https://open2077.net/docs/data-reference) for vehicle records, and the repository [license](../../LICENSE).
