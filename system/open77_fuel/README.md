# open77_fuel

This resource gives every network vehicle a fuel tank: the server burns fuel from the car's speed and engine state once a second, cuts the engine when the tank is empty, and keeps it off until someone refuels. The fuel level travels in each vehicle's state bag, so every client that streams the car can read it for a gauge.

- **Docs:** [Replicated state bags](https://open2077.net/docs/state-bags)
- **Starts:** on its own
- **Needs:** nothing
- **Runs on:** server and client

## Use it

It works as soon as it runs. Every tank starts full at 60 litres and burns 12 L/100 km while moving and 0.08 L/min while idling; a car with its engine off burns nothing. The rules live in `shared/fuel.lua`, small enough to read and copy.

Server exports (each answers `value` or `nil, reason`):

```lua
local litres = exports.open77_fuel:level(vehicleId)
exports.open77_fuel:refuel(vehicleId, 20)     -- adds litres, never overfills; no amount = a full tank
exports.open77_fuel:set(vehicleId, 35)        -- sets the level
exports.open77_fuel:configure({ multiplier = 2.0 }) -- capacity, litresPerHundredKm, idleLitresPerMinute, multiplier
```

The server also fires the local event `open77:fuel:empty` (vehicleId) when a tank runs out.

On the client, `exports.open77_fuel:level(vehicleId)` and `exports.open77_fuel:current()` (the car the player sits in) read the same number, and `open77:fuel:changed` (vehicleId, litres, previous) fires when it moves. Clients can never set fuel.

Console commands: `fuel <id>` shows a tank, and the admin-only `refuel <id> [litres]`, `fuel.set <id> <litres>` and `fuel.multiplier <factor>` change it.
