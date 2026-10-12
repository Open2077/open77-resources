# open77_icons_demo

Places four map icons from the [`open77_icons`](../../standalone/open77_icons/) library (fuel, hospital, car and grape) in a row near your character shortly after you enter the world, then changes two of them. It shows how a client resource creates, recolours and swaps a Lucide icon blip.

- **Docs:** [Custom SVG blips](https://open2077.net/docs/custom-blip-icons)
- **Starts:** with `ensure open77_icons_demo` (it declares `auto_start false`)
- **Needs:** `open77_icons`
- **Runs on:** client

## Use it

Run `ensure open77_icons_demo` on a development server and join. About six seconds after your character is alive in the world, four icons appear 22 metres north of you, 14 metres apart and visible through walls. 45 seconds later the fuel icon turns cyan and the car icon becomes a wrench. The blips exist only on your client: the demo spawns nothing, teleports no one and changes no server state.

The demo checks that the library reports its full 2,112-icon catalogue and stops with an error in the client log if it does not.

The calls to copy, from a client script whose manifest declares `dependency "open77_icons >=1.0.0"`:

```lua
local id, reason = exports.open77_icons:create({
    icon = "fuel", color = "#FFCC00", size = 48, title = "Fuel",
    position = { x = p.x, y = p.y + 22, z = p.z },
    visibleThroughWalls = true,
})
if not id then print(reason) end
exports.open77_icons:setColor(id, "#00CCFF")
exports.open77_icons:setIcon(id, "wrench", 56)
```

`exports.open77_icons:has(name)`, `list(query)` and `info()` let you check an icon name before you use it.
