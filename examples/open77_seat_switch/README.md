# open77_seat_switch

Adds a `/seats` chat command that moves you to another seat of the car you are in, with the seat-change animation, and turns automatic seat switching on or off for you. It prints every seat-switch event, on the server and on your client, so you can follow a switch from request to result.

- **Docs:** [Changing seats inside a vehicle](https://open2077.net/docs/vehicle-seat-switching)
- **Starts:** with `ensure open77_seat_switch` (it declares `auto_start false`)
- **Needs:** nothing
- **Runs on:** server and client

## Use it

Run `ensure open77_seat_switch`. Every player can use the command, and each form affects only the caller. Results print in the server log and the caller's client log.

- `/seats move <seat>`: the server moves you (`Open77.vehicles.switchPlayerSeat`).
- `/seats auto on` or `/seats auto off`: automatic seat switching for you.
- `/seats cancel`: cancels the switch in progress.
- `/seats status`: your seat, the switch in progress and your auto setting.
- `/seats local <seat>`: the same move, requested from your client (`Open77.vehicles.switchSeat`).
- `/seats localauto on` or `/seats localauto off`: the auto setting, changed from your client.

`<seat>` defaults to `driver`; the docs page lists the other seat names.

The server calls to copy:

```lua
local ok, result = Open77.vehicles.switchPlayerSeat(playerId, 'driver')

AddEventHandler('onPlayerVehicleSeatSwitchCompleted', function(player, vehicle, id, before, after, reason)
    print(('player %s moved from %s to %s'):format(player, before, after))
end)
```

The server events come in `Started`, `Completed` and `Failed` variants. On the client, listen for `open77:vehicleSeatSwitchStarted`, `Completed`, `Failed` and `open77:vehicleSeatSwitchDecision`.
