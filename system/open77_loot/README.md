# open77_loot

This resource puts server-owned item drops on the ground: the server creates each drop, every client shows it as a real object, and a pickup only counts once the server accepts it. Players cannot create or award loot from their own game.

- **Docs:** [Server loot and ground drops](https://open2077.net/docs/loot)
- **Starts:** on its own
- **Needs:** nothing
- **Runs on:** server and client

## Use it

Your own server resource creates drops with `Open77.loot.create` and keeps ownership of them. This resource projects every drop to the clients and sends their pickups back to the server. It also gives operators a few commands; all but the two list commands are restricted by the ACL.

```text
loot [bucket]                    list drops (same as loot.list)
loot.create <item> <quantity> <x> <y> <z> [bucket] [radius] [visualItem]
loot.create.player <playerId> <item> <quantity> [offsetZ] [radius] [visualItem]
loot.remove <id>                 remove a drop this resource created
```

```lua
-- server
local id, reason = Open77.loot.create({
    item = "Items.money", quantity = 500,
    position = { x = x, y = y, z = z }, bucket = 0, radius = 2.0,
})
AddEventHandler("onLootPickup", function(playerId, dropId, item, quantity, ownerResource)
    -- the server accepted this pickup
end)
```

On the client, the exports `get(id)` and `all()` read the drops in view and `requestPickup(id)` asks the server to pick one up. The local event `open77:loot:result` reports the answer: `id, accepted, reason, item, quantity`.

The physical objects are visuals only: their vanilla pickup prompt is turned off, and every pickup goes through the server. A client whose game was not restarted after an update keeps the resource inactive and says so in its log.
