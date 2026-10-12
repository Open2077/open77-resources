# open77_contextmenu_example

Adds three demonstration actions to the ALT context menu so you can see how a resource registers its own entries: "Inspect target", "Inspect myself" and "Use this direction". Each one prints the clicked target's identifiers and the full click context to your client log.

- **Docs:** [Generic context menu — open77_contextmenu](https://open2077.net/docs/context-menu)
- **Starts:** with `ensure open77_contextmenu_example` (it declares `auto_start false`)
- **Needs:** `open77_contextmenu`
- **Runs on:** client

## Use it

This is a teaching resource: keep it off a public server. Run `ensure open77_contextmenu_example` on a development server, then hold ALT in game and click a player, a vehicle, an NPC or a prop. "Inspect myself" appears on your own body, and "Use this direction" appears when you click empty sky (it gives a direction, not a point on a surface).

The pattern to copy: expose a named client export as the callback, then register your actions with [`open77_contextmenu`](../../system/open77_contextmenu/) each time your resource or the menu starts.

```lua
exports("inspectTarget", function(context)
    print(context.target.kind, context.playerDistance)
    return true
end)

AddEventHandler("onClientResourceStart", function(name)
    if name ~= GetCurrentResourceName() and name ~= "open77_contextmenu" then return end
    local promise, reason = Open77.exports.call("open77_contextmenu", "registerMany", {
        { id = "inspect", label = "Inspect target", icon = "info", distance = 8, onSelect = "inspectTarget" },
    })
    if not promise then print(reason); return end
    local token, err = promise:await()
    if not token then print(err) end
end)
```

`onSelect` names an export in your own resource, not a Lua function. The other two entries in `client.lua` show the `types`, `allowSelf`, `selfOnly` and `data` options. The manifest only needs the `local.events` permission.
