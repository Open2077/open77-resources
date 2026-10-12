# open77_animations

This resource plays synchronised role-play animations on players: more than a hundred poses, gestures, dances, workspots and walking actions that every nearby player sees, started with the `/anim` command or from your own resource. The server owns every playback; this resource presents it on each client and lets other client resources ask for one.

- **Docs:** [Role-play animations](https://open2077.net/docs/rp-animations), [RP animation catalogue](https://open2077.net/docs/rp-animation-catalogue)
- **Starts:** on its own
- **Needs:** nothing
- **Runs on:** server and client

## Use it

Players use the chat command:

```text
/anim list          every profile id
/anim info smoke    a profile and its numbered clip variants
/anim smoke 2       play a profile, optionally one variant
/anim stop          stop your current animation
```

`/anim` on its own raises the client event `open77_animations:menu`. This resource draws no menu, so your gamemode can open its own. Gestures such as `wave` or `shrug` play once; holds and workspots loop until `/anim stop`.

From a server resource, call the platform API:

```lua
local state, err = Open77.animations.play(playerId, "handsup", { loop = true })
Open77.animations.stop(playerId)
```

From a client resource, use the exports `list`, `get`, `clip`, `clips`, `state`, `request(profile, options)`, `requestClip(clip, options)`, `sequence(steps, options)`, `cancel`, `isPointing` and `setPointing(enabled)`. A request belongs to the resource that made it and is cancelled when that resource stops. The local events `onPlayerAnimationChanged`, `onAnimationResult` and `onAnimationPlaybackFailed` report what happened.
