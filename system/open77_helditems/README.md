# open77_helditems

This resource is the client half of the server's held-items service: it puts a real game item in the player's hand or another equipment slot when the server asks, takes it away again, and reports the result. Your server resource calls `Open77.heldItems`; this resource does the work in each player's game.

- **Docs:** [Server-owned world props](https://open2077.net/docs/props)
- **Starts:** on its own
- **Needs:** nothing
- **Runs on:** client

## Use it

Keep it running: without it the server's `Open77.heldItems` requests get no answer. Gameplay code does not call it directly.

- Slots: `Head`, `Face`, `InnerChest`, `OuterChest`, `Legs`, `Feet`, `Outfit`, `UnderwearTop`, `UnderwearBottom` and `WeaponRight` (the right hand).
- A right-hand item is shown as a prop on the player's body. This resource waits up to about nine seconds for it to appear, then reports whether it rendered and its attachment status.
- Any other slot changes only that slot: the clothes the player wears and their wardrobe outfit stay as they are.
- A request is refused with `player_not_ready` until the player's character is loaded and alive.
- When the player enters the world again, the body is rebuilt from the server's equipment record and this resource forgets what it had placed.

Client exports: `slots()`, `hold(record, slot)`, `release(slot)` and `snapshot()`. They return `true`, or `false` plus a reason. The right hand is served only through the server API, so pass another slot: `hold` and `release` default to `WeaponRight` and refuse it with `use_server_held_items`.
