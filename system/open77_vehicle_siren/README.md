# Vehicle siren

Press **F6** while driving a network vehicle to toggle its siren and emergency
lights for nearby players. The vehicle must have a native siren/light bar, such
as `Vehicle.v_standard2_archer_hella_police_siren`; this package does not add one
to ordinary cars. Sound and lights use the existing combined siren switch.

The binding appears as **Vehicle: toggle siren** under Pause → Settings → Key
bindings. Keyboard and mouse bindings use `RegisterKeyMapping` and persist through
reconnects. Edit `defaultKey` in `config.lua` to change the server default; saved
player bindings take priority. F6 avoids the game's original vehicle-light key.
The mapping does not fire while chat or another WebUI owns keyboard focus.

## Install

Copy this directory into your server's resources and add
`"open77_vehicle_siren"` to `resources.load` if you use an explicit list. Restart
the resource/server so clients receive it. The updated Freeroam depends on this
package and loads it automatically. No database, new DLL or protocol change is
needed on clients/servers which already support `Open77.vehicles.setSiren`.

## Behavior and integration

The client sends a toggle request for its current vehicle. The server verifies
the authenticated sender's canonical driver seat and readiness, rejects entry/
exit transitions and destroyed vehicles, and limits repeated requests. Passengers
and players on foot cannot operate another driver's siren. State is read and
changed on the server, so rapid requests do not use a stale client-side value.

Siren state uses the native vehicle replication system, including late joins,
stream-out/in and authority changes. No audio is broadcast through WebUI and no
timer replays the siren. This package does not reset sirens when it stops.

A client resource can use the same checked request path:

```lua
local sent, reason = Open77.exports.callSync("open77_vehicle_siren", "toggle")
```

Server resources can continue to control their own vehicles directly:

```lua
Open77.vehicles.setSiren(vehicleId, true)
Open77.vehicles.setSiren(vehicleId, false)
local enabled = Open77.vehicles.isSirenOn(vehicleId)
```

This package grants the siren control to the current driver; RP job/access rules
can be added in `server/main.lua` before the setter. Test the package policy with
Lua 5.4 from this directory: `lua tests/siren.test.lua`.
