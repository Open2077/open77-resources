# open77_groundcircle

This resource draws coloured circles on the ground for the local player, such as a ready-up ring or a job spot, without depending on any game asset to render. It uses the client's native ring drawing when available and falls back to an SVG overlay it projects itself.

- **Docs:** [Drawing in the world](https://open2077.net/docs/world-drawing), [Official resource exports](https://open2077.net/docs/resource-exports)
- **Starts:** on its own
- **Needs:** nothing
- **Runs on:** client

## Use it

If your server uses a `resources.load` list, add `open77_groundcircle` to it. Then call its exports from a client resource. `create` reads the same field names as [open77_worldui](../open77_worldui/) (`id`, `position`, `radius`, `maxDistance`, `style`, `groundOffset`, `color`) and ignores the prompt fields, so one definition table works with both.

```lua
local result = exports.open77_groundcircle:create({
    id = "ready_up", position = { x = x, y = y, z = z },
    radius = 2.0, style = "objective",
})
if result.ok then print(result.handle) else print(result.error) end
```

- Styles: `interaction`, `objective` (the default), `spawn`, `danger`; or give `color` as `#RRGGBB`.
- Also accepted: `width` (0.5 to 8), `opacity` (0.05 to 1), `fill` (0 to 0.6) and `visible`. `radius` is clamped to 0.1 to 50 m and `maxDistance` to 1 to 500 m.
- `remove(handle)`, `clear()` and `list()` act only on your own circles. Every call answers a table with `ok`, and `error` when it fails.
- At most 32 circles exist at once, across every resource.

Circles belong to the resource that created them and disappear when it stops. After a world change (`open77:worldReady`), circles from the previous world are dropped, so re-create yours from that event.

The circle exists only on the local screen: other players do not see it, and the overlay version is not hidden by walls.
