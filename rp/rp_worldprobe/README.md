# rp_worldprobe

Console tools that list the game objects around a player, such as ATMs, vending machines, terminals, doors and props, with their engine class and position, so you can place RP prompts and points of interest on real Night City objects. It can also move a server vehicle and play an animation profile on a player from the console.

- **Docs:** [World queries: raycast, ground height, objects around the player, entity axes, district](https://open2077.net/docs/world-queries)
- **Starts:** on its own
- **Needs:** nothing
- **Runs on:** server and client

## Use it

Type these in the server console. Never load this resource on a public server.

- `wprobe <playerId> [radius] [filter]` asks that player's client for `Open77.world.nearby` and prints every object in the server log, nearest first: kind, engine class, engine id, position and distance. The radius defaults to 25 m. The filter is `device`, `puppet`, `player`, `sensor`, `other` or `all`.
- The client sends its answer back in pages of 40 rows.
- `vwarp <vehicleId> <x> <y> <z> [yaw]` moves a server vehicle.
- `aplay <playerId> <profile> [once]` plays an animation profile on a player, looping unless you add `once`. `astop <playerId>` stops it.
- Every animation change on the server is logged as `[worldprobe] anim <playerId>: profile=... active=... reason=... playbackId=...`.
