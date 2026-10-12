# open77_equipment

Keeps every player's worn clothing in sync: what you equip in the game goes to the server, the server's record for your character comes back, and other players see the same clothes on your body. It also answers the server's `Open77.clothing` requests, so a server script can dress a player.

- **Docs:** [Official resource exports](https://open2077.net/docs/resource-exports), [Complete server Lua API](https://open2077.net/docs/server-api)
- **Starts:** on its own
- **Needs:** `open77_appearance`
- **Runs on:** client

This is the client half. The server half lives in
[open77_appearance](../../system/open77_appearance/), which owns each character's
equipment and wardrobe record and saves it through the database bridge. Nine slots
are replicated: `Head`, `Face`, `InnerChest`, `OuterChest`, `Legs`, `Feet`, `Outfit`,
`UnderwearTop` and `UnderwearBottom`. An active wardrobe outfit, kept in sync by
[open77_wardrobe](../open77_wardrobe/), changes how this clothing looks on the body.

## Use it

Keep `open77_equipment` and `open77_appearance` in your server's `resources.load`.
Players need nothing more: they change clothes in the game's inventory as usual.

From a server resource that declares `network.events`, dress a player with
`Open77.clothing` (`equip`, `unequip`, `set`, `clear`, `requestSnapshot`) and read the
answer on `open77:clothing:completed`:

```lua
local request = Open77.clothing.set(playerId, { outer_chest = "Items.Jacket_01_basic_01" })
AddEventHandler("open77:clothing:completed", function(player, id, operation, accepted, reason)
    if id == request then print(operation, accepted, reason) end
end)
```

`set` uses the slot names `head`, `face`, `inner_chest`, `outer_chest`, `legs`, `feet`
and `outfit`; `false` empties a slot and omitted slots stay unchanged.

Client resources can read and change the local player's equipment through the
exports `slots()`, `records(options)`, `info(record)`, `registry()`,
`equip(record, slot, options)`, `unequip(slot)` and `apply(slots, options)`.
`beginPreview()` and `endPreview()` are reserved for `open77_wardrobe_ui` and refuse
any other caller with `preview_owner_denied`.
