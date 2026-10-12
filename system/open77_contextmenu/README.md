# open77_contextmenu

This resource gives players an ALT + click context menu on players, vehicles, NPCs, doors, props and the world around them, filled only with the actions your own resources register.
Generic client-side ALT + click targeting framework. **No actions are installed
by default.** Your consumer resource supplies actions through named client exports.
No Freeroam dependency, hardcoded commands, admin privileges or server authority.
This README describes version 1.1.0.

- **Docs:** [Generic context menu — open77_contextmenu](https://open2077.net/docs/context-menu), [Screen picking and cursor utilities](https://open2077.net/docs/screen-picking)
- **Starts:** on its own
- **Needs:** nothing
- **Runs on:** client

The bundled [`freeroam`](../../gamemodes/freeroam/) gamemode and [`open77_admin`](../open77_admin/)
register their own real actions. Remove/stop a consumer and its actions disappear. Do not enable
[`open77_contextmenu_example`](../../examples/open77_contextmenu_example/) in a production load list:
that opt-in example, not this framework, supplies demonstration actions.
For larger integrations, register in small batches (five definitions per awaited
call) to stay within the client's per-resume instruction budget: each definition
costs about 1,000 VM instructions to validate and copy, whatever the registry
already holds.

Install this folder in the server resource tree and add it to `resources.load`
when using an explicit load list. A consumer must declare
`dependency "open77_contextmenu"` and start its client scripts (`auto_start true`).
Use the client build supporting `screenRaycast(..., {self=true})` and native weapon
wheel blocking. Reconnect clients after publishing resource changes.

- Hold ALT, click an entity, surface, visible F7 body or empty space.
- Icon/label rows, actual mouse hover, separate keyboard focus, configurable
  accent/scale/groups in `shared/config.lua`.
- `register`, `registerMany`, `update`, `get`, `unregister`, `unregisterMany`,
  `clear`, `setEnabled`, `list` manage **only the caller's** registrations.
- `registerPlayers`, `registerVehicles`, `registerNpcs`, `registerProps`,
  `registerDoors`, `registerWorld`, `registerSky`, `registerSelf`,
  `registerModels`, `registerEntities` provide typed/filtered registration.
- `isOpen`, `isReady`, `getVersion`, `getContext`, `getTarget`,
  `setTargetingEnabled`, `isTargetingEnabled`, `close` expose UI lifecycle.

All calls use `Open77.exports.call("open77_contextmenu", method, ...):await()`
with a dispatch error check. Helpers accept one definition or an atomic array.
Callbacks must be named exports in **your** resource, not Lua functions passed
across resources. Register on your start and on the context resource's restart.

```lua
exports("selectedSelf", function(ctx)
    print("Self: " .. tostring(ctx.target.playerId))
    return true
end)

AddEventHandler("onClientResourceStart", function(name)
    if name~=GetCurrentResourceName() and name~="open77_contextmenu" then return end
    local promise, err = Open77.exports.call("open77_contextmenu", "registerSelf", {
        id="myself", label="My character", icon="person", onSelect="selectedSelf",
    })
    if not promise then print(tostring(err)); return end
    local token, reason = promise:await()
    if not token then print(tostring(reason)) end
end)
```

Consumer permission: `local.events` for this lifecycle handler, plus permissions
needed by your own actions. Registrations/disable claims are removed on stop.

Sky is explicit opt-in: `registerSky` returns a **direction**, not a ground point.
Self keeps `target.kind="player"`; `ctx.kind="self"` and `isLocalPlayer=true`
identify it. Visual self hits use animated capsules; no gameplay collider is added.
Game effects must still validate authenticated source, distance, routing bucket,
life state and permissions **on your server**. Client predicates are UX only.

Full option schemas, return values, limits, lifecycle and recipes:
[Generic context menu](https://open2077.net/docs/context-menu) and
[Screen picking and cursor utilities](https://open2077.net/docs/screen-picking).
Working consumer: [`open77_contextmenu_example`](../../examples/open77_contextmenu_example/)
(opt in on a private server).
