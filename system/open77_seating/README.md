# open77_seating

This resource lets players sit, lean and lie down on the world's real chairs, stools, benches, counters, walls and beds, with a prompt on E or the `/sit` command, and keeps one player per seat. The server picks the seat, places the body and plays the posture; the stand-up key is X and can be rebound.

- **Docs:** [Furniture: sit and lean](https://open2077.net/docs/furniture)
- **Starts:** with `ensure open77_seating` (it declares `auto_start false`)
- **Needs:** `open77_actions`, `open77_interactions`
- **Runs on:** server and client

## Use it

List `open77_seating`, its dependencies and [open77_furniture](../open77_furniture/) in `resources.load`, then `ensure` them. `open77_furniture` holds the seat catalogue; it is not a manifest dependency (it has no client half), and seating answers `furniture_unavailable` until it runs. When [open77_pedestrians](../open77_pedestrians/) runs, a seat with an NPC on it is refused and NPCs keep off a seat a player holds.

Players get up to three prompts for free seats within 3 m ("Sit on the chair", "Lean on the wall", "Lie down on the bed"), plus `/sit` (nearest free seat or bed in reach) and `/stand`. A bed is lain on from where the player stands. A seat is held through an `open77_actions` claim, so a job that claims the same furniture keeps it free.

Server exports for other resources:

```lua
exports.open77_seating:sitNearest(playerId)          -- or sit(playerId, furnitureId, options)
exports.open77_seating:stand(playerId)
local session = exports.open77_seating:current(playerId)
local ids = exports.open77_seating:occupants(bucket, furnitureId)
```

The server events `open77_seating:seated` and `open77_seating:stood` report each seat taken and left.

Convars:

- `open77_seating_verification`: which poses are offered, `measured` (default), `unverified` or `all`. By default the only bed offered is the measured double bed resource; other beds are `unverified`.
- `open77_seating_postures`: which postures prompts, `/sit` and the exports offer, a comma list of `sit`, `lean` and `lie`, or `all` (default).
- `open77_seating_buckets`: a comma list of routing buckets where seating works, or `all` (default).
- `open77_seating_exit`: after standing up, `approach` (default) puts the body back on its approach point, `check` moves it only when it ended somewhere unsafe, `none` never moves it.

Console: `seating.status`, `seating.near`, `seating.sit`, `seating.stand`, `seating.claims`, `seating.exit`, `seating.verification`, `seating.trace`.
