# open77_death

This resource gives client resources a read-only view of which players are alive or dead, and repeats every life-state change as one local event. The server decides every death and revival; this resource never changes anyone's state.

- **Docs:** [Official resource exports](https://open2077.net/docs/resource-exports)
- **Starts:** on its own
- **Needs:** nothing
- **Runs on:** client

## Use it

Call the exports from a client resource. Leave `playerId` out to ask about the local player.

```lua
if exports.open77_death:isDead(playerId) then return end
local state = exports.open77_death:getState(playerId)

AddEventHandler("open77:death:stateChanged", function(state, phase, revision)
    -- a player's life state changed
end)
```

- `isDead(playerId?)`: whether the player is dead.
- `getState(playerId?)`: the player's life-state snapshot.
- `getLocalDeathContext()`: the local player's death context, or the last state this resource saw.
- `all()`: the life states of every known player.

The event `open77:death:stateChanged` fires for every `open77:playerLifeStateChanged` the platform sends, with the new state, its phase and its revision number.
