# open77_furniture

This resource is a read-only catalogue of the world's furniture spots: about 38,000 chairs, stools, benches, beds, counters, walls and rails across Night City, each with the sit, lean or lie poses an animation can be played at. Other server resources ask it what furniture is near a point; it never claims, prompts or plays anything itself.

- **Docs:** [Furniture: sit and lean](https://open2077.net/docs/furniture)
- **Starts:** with `ensure open77_furniture` (it declares `auto_start false`)
- **Needs:** nothing
- **Runs on:** server

## Use it

List `open77_furniture` in `resources.load` and `ensure` it next to the resource that uses it, such as [open77_seating](../open77_seating/). It needs no permission. At start it builds a spatial index over several server ticks; until that is done, lookups answer `nil, "indexing"`.

Three synchronous exports, each returning a value or `nil, reason`:

```lua
local list, why = exports.open77_furniture:nearby(position, 10, { kind = "bench", limit = 5 })
local furniture = exports.open77_furniture:get(furnitureId)
local state = exports.open77_furniture:status()   -- indexed, version, furniture, spots...
```

- `nearby(position, radius, filter)` returns furniture nearest first, within at most 50 m (10 m by default).
- `filter` fields, all optional: `kind`, `posture` (`sit`, `lie`, `lean`), `profile`, `verification`, `playable`, `vertical`, `excludeFlags`, `limit` (5 by default, up to 32) and `poses` (include each pose).
- Each result gives the furniture `id`, `kind`, `posture`, position and `yaw`, the best matching `pose` with its animation `profile` and `arrivalRadius`, and a `flags` bit mask (interior, Dogtown, NPC spot and more).

The data was extracted from the game files and has not been checked spot by spot in the running game: a pose's `verification` field says whether it was measured.

Console: `furniture.status`, `furniture.near <playerId> [count] [radius] [kind]`, `furniture.at <x> <y> <z> [count] [radius] [kind]`, `furniture.get <id>`.
