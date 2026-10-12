# open77_doors

This resource makes the world's doors networked: the server decides whether each door is open, locked or sealed, and every player in the same routing bucket sees the same door move with its native animation. Clients find the doors near them and report them; only the server changes a door's state.

- **Docs:** [Networked world doors](https://open2077.net/docs/doors)
- **Starts:** on its own
- **Needs:** `open77_elevators`
- **Runs on:** server and client

## Use it

Doors work as soon as the resource runs: automatic doors open when a player comes close, and manual doors open on request. Elevator landing doors follow their lift, through [open77_elevators](../open77_elevators/).

To control a door from your own server resource, register it. Your resource then owns that door, and another resource cannot change it. A door id is its engine entity id, written as `0x` plus 16 hex digits.

```lua
local door, reason = exports.open77_doors:register({ id = doorId, bucket = 0, position = pos })
exports.open77_doors:setLocked(doorId, 0, true)
exports.open77_doors:setAccess(doorId, 0, playerId, true)   -- let one player through
```

Other server exports:

- `setOpen`, `setSealed`, `setAutomatic` and `configure(id, bucket, patch)` change the state and the open and close radius or delay.
- `setActions(id, bucket, { force = true, pay = true, hack = true })` offers Force Open, Pay or a door hack on a locked door; nothing is offered by default. A pay action waits for your approval: listen for `open77:doors:action` and answer with `resolveAction(ticket, accept, reason)`.
- `setNpcPassage(id, bucket, mode)` decides which network NPCs may pass: `public`, `resource`, `always` or `never`.
- `get`, `list`, `near`, `changes(cursor)`, `linkElevator`, `remove` and `setDiscoveryEnabled`.

On the client, `get`, `list` and `requestOpen(id, open)` read the doors in range and ask the server to move one. The events `open77:doors:streamedIn`, `open77:doors:updated` and `open77:doors:streamedOut` follow what the client sees.
