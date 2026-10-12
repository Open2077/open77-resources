# open77_markers

This resource lets any client resource place 3D markers in the world (rings, cylinders, arrows and other shapes) through exports, without asking for the marker permission itself. It is a thin wrapper around `Open77.markers`.

- **Docs:** [3D world markers](https://open2077.net/docs/markers)
- **Starts:** on its own
- **Needs:** nothing
- **Runs on:** client

## Use it

Call the exports from a client resource. `create` takes the same definition as `Open77.markers.create` and returns the marker id, or `nil` and a reason.

```lua
local id, reason = exports.open77_markers:create({
    position = { x = x, y = y, z = z },
    shape = "ring",
    style = "objective",
    radius = 1.0,
    maxDistance = 80.0,
})
exports.open77_markers:update(id, { visible = false })
exports.open77_markers:remove(id)
```

The other exports are `get(id)`, `list()`, `clear()` and `shapes()`, which lists the shape names. The styles are `interaction`, `objective`, `spawn` and `danger`.

Markers made through these exports belong to `open77_markers`, not to your resource: they are not removed when your resource stops, and `clear()` removes every marker made through the exports. If you want your markers cleaned up with your resource, call `Open77.markers` directly and declare the `world.markers` permission.

Markers are local to the player's own game. To show the same marker to several players, send its definition from the server to each client.
