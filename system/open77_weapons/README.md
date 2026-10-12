# open77_weapons

This resource gives, removes and reloads the weapons in a player's three weapon slots, and makes explosions push nearby cars and knock down NPCs (and players, when your gamemode allows it) on every screen. It is the official asynchronous facade for the local player's three standard weapon
slots. Templates are exact TweakDB record names such as
`Items.Preset_Lexington_Default`.

- **Docs:** [Weapon Lua API](https://open2077.net/docs/weapons-api), [Weapon customization](https://open2077.net/docs/weapon-customization)
- **Starts:** on its own
- **Needs:** nothing
- **Runs on:** server and client

```lua
CreateThread(function()
    local promise, reason = Open77.exports.call(
        "open77_weapons", "assign",
        "Items.Preset_Lexington_Default", 1, { active = true })
    assert(promise, reason)
    local requestId, callError = promise:await()
    assert(requestId, callError)
end)
```

Client resources may also use the lower-level native method
`Open77.weapons.assign(...)` directly when they declare the weapon permission.

Listen for `open77:weapons:completed` to learn whether REDengine accepted and
verified the change. Server resources use `Open77.weapons.*`; see
[Weapon Lua API](https://open2077.net/docs/weapons-api) for the full contract.

Exact spare and loaded rounds are asynchronous too:

```lua
Open77.weapons.setAmmo(1, {
    reserve = 120,
    magazine = 18,
    activate = true,
})
```

## ACL-gated admin commands

```text
/weapon.give <playerId|me> <template> [slot=1] [active=true]
/weapon.remove <playerId|me> <slot>
/weapon.ammo <playerId|me> <slot> <reserve> [magazine]
```

These commands are registered as restricted server commands. Grant
`command.weapon.give`, `command.weapon.remove`, and/or `command.weapon.ammo` to
an ACL principal (the built-in `admin` role already holds `command.*`).
`weapon.ammo` reports only after the client verifies reserve, magazine,
capacity, and total. `weapon.remove` clears the slot but deliberately keeps the
item in the player's inventory.

## Explosions on every screen (blast relay)

Only the client that simulates a car can move it, and only the client whose
engine ran an explosion applies its physics. `server/blasts.lua` turns an
explosion the server can vouch for into one `open77_weapons:blast` per physics
owner of every other car in reach, and tells every player close enough to hold
a copy of an NPC in reach to knock its own copy down (`client/blasts.lua` calls
`Open77.weapons.applyBlast`). It needs a client DLL with that native; an older
client ignores the relay.

| Source | Accepted when |
|---|---|
| Grenade (`onPlayerExplosion`) | the thrower consumed a frag, incendiary or cutting grenade (`onGadgetConsumed`): one detonation per grenade, near where it was thrown, in its bucket, at grenade cadence |
| Car explosion | the car's canonical `exploded` flag rises; its simulator's own world is not repeated |
| Mounted weapon (`onVehicleWeaponExplosion`) | the vehicle weapon ticket admitted the projectile's explosion |
| `exports.open77_weapons:relayBlast` | another server resource (such as [`rp_weapons_effect`](https://github.com/Open2077/open77-resources/tree/main/rp/rp_weapons_effect)) admitted it; bounded like the rest |

Radius and impulse come from server tables, never from a client; nothing here
deals damage. Players are launched only when the gamemode asks for it:

```lua
-- Server, once per start of the gamemode and of open77_weapons.
Open77.exports.call("open77_weapons", "setBlastPolicy", {
    players = true,                                   -- knock nearby players down
    safeZones = { { x = 0, y = 0, z = 0, radius = 30 } },
    buckets = { 0 },                                  -- optional: street only
})
```

The policy lapses when the resource that set it stops. `open77_blasts off`
(server convar) disables every source; `/weapon.blasts` (ACL
`command.weapon.blasts`) prints counters and refusals, and
`exports.open77_weapons:blastStats()` returns them.
