# open77_elevators

This resource makes the game's lifts networked: the server owns each elevator's floor, movement and schedule, and every player in the same routing bucket rides the same cabin. Clients only report the lifts they stream in and ask for a floor.

- **Docs:** [Network elevators](https://open2077.net/docs/elevators)
- **Starts:** on its own
- **Needs:** nothing
- **Runs on:** server and client

## Use it

Lifts are adopted on their own: when a player comes within 80 m of a native lift, the server checks the player's position and takes the lift over in that player's routing bucket. Its landing doors are handled by [open77_doors](../open77_doors/).

Operators manage lifts from the console or chat. `elevator.list` is open to everyone; the other commands are restricted by the ACL.

```text
elevator.list [bucket]
elevator.adopt <entityHex> <x> <y> <z> <floorCount> [bucket] [initialFloor]
elevator.adopt.player <entityHex> <playerId> <floorCount> [initialFloor]
elevator.goto <id> <floor> [travelMs]
elevator.teleport <id> <floor>
elevator.pause <id>   /   elevator.resume <id>
elevator.power <id> on|off   /   elevator.lock <id> on|off
elevator.remove <id>
```

From a client resource, `exports.open77_elevators:requestFloor(id, floor)` sends a cabin button press and `requestCall(id, floor)` calls the lift to a landing; the server decides. `get(id)` and `all()` read the lifts in range, and the events `open77:elevator:streamedIn`, `open77:elevator:updated` and `open77:elevator:streamedOut` follow them.
