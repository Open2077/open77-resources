# open77_pointing

Lets players point with a finger in the direction their camera faces: hold B, or type `/pointing on` and `/pointing off`. The [`open77_animations`](../../system/open77_animations/) service plays and replicates the gesture, so other players see it too.

- **Docs:** [Role-play animations](https://open2077.net/docs/rp-animations)
- **Starts:** with `ensure open77_pointing` (it declares `auto_start false`)
- **Needs:** `open77_animations`
- **Runs on:** server and client

## Use it

Run `ensure open77_pointing`. Every player can then:

- hold **B** to point and release it to stop (a key mapping named `point`, so players can rebind it);
- type `/pointing on` or `/pointing off` in chat;
- type `/pointing status` to print whether they are pointing in their client log.

The command only ever affects the player who types it. The animation service handles interruptions, replication and cleanup when the resource stops.

The call to copy, in a client script whose manifest declares `dependency 'open77_animations >=1.0.0'`:

```lua
RegisterKeyMapping('point', 'Point with your finger', 'B',
    function() Open77.animations.setPointing(true) end,
    function() Open77.animations.setPointing(false) end)
```

`setPointing` returns a request you can `:await()` in a thread to read the result or the refusal reason, as `client.lua` does. `Open77.animations.isPointing()` answers the same way.
