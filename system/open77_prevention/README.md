# open77_prevention

This resource applies the server's police policy (wanted level, the highest level allowed, and whether NCPD is dispatched at all) to each player's own game. The server decides; this client half only carries the decision out.

- **Docs:** [Complete server Lua API](https://open2077.net/docs/server-api)
- **Starts:** on its own
- **Needs:** nothing
- **Runs on:** client

## Use it

You do not call this resource. Set the policy from a server resource with the wanted-level functions of the server API; the platform sends it to the player on `open77:prevention:policy`, and this resource applies it with `Open77.prevention`.

```lua
-- server resource, permissions { "players.wanted", "world.prevention" }
Open77.players.setMaxWanted(playerId, 3)
Open77.players.setWanted(playerId, 2)
Open77.world.setPreventionEnabled(0, false)   -- no dispatch in routing bucket 0
```

- Levels run from 0 to 5. The ceiling is applied before the level, so a raise is never clipped by an old ceiling.
- After every world entry (`open77:playerReset:complete`) the last policy is applied again, because the game resets it.
- If the server never sent a policy, the player keeps the game's normal police behaviour.

Each player's game runs its own police: the officers a wanted level brings belong to that player's game only, and other players do not see them. While world population is suppressed on a client, a raise is refused with `population_suppressed` and logged; clearing to 0 always works.
