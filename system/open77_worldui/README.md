# open77_worldui

This resource puts a point of interest in the world with one call: a ground marker and an action prompt above it, created together under one handle and removed together. A gamemode uses it for start lines, job spots and objectives without holding the marker permission or cleaning up two systems by hand.

- **Docs:** [World-anchored POIs](https://open2077.net/docs/worldui)
- **Starts:** on its own
- **Needs:** `open77_interactions`
- **Runs on:** client

## Use it

Add `dependency "open77_worldui >=0.1.0"` to your manifest and call the exports from a client script:

```lua
local startLine

CreateThread(function()
    local promise = Open77.exports.call("open77_worldui", "create", {
        id = "start_line",
        position = { x = -1460.2, y = 99.9, z = 24.8 },
        style = "objective",   -- interaction, objective, spawn or danger
        label = "Join the race",
        key = "E",
        event = "myrace:startLineSelected",
    })
    local result = promise and promise:await()
    if result and result.ok then startLine = result.handle end
end)

AddEventHandler("myrace:startLineSelected", function()
    TriggerServerEvent("myrace:joinIntent")
end)
```

- Exports: `create(definition)`, `remove(handle)`, `list()` and `dump()` (logs every live marker and whether it really rendered). Each returns a table with `ok`, plus `handle` or `error`.
- Other fields include `shape` (`ring` or `cylinder`), `radius`, `maxDistance`, `groundOffset`, `description`, `holdSeconds`, `promptDistance`, `labelHeight`, `requireLookAt`, `marker`, `icon` and `color`. Leave out `label` for a marker with no prompt.
- Creation is all or nothing: if the prompt fails, the marker is removed too.
- Handles belong to the calling resource. Another resource cannot remove them, and they are cleared when their owner stops or reloads.
- A client holds at most 64 points of interest at once. If `open77_interactions` restarts, the prompts are registered again.
- The event is a local client event: check identity, distance and state on the server before granting anything.
