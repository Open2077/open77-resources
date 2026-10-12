# open77_effects

This resource shows the server's visual and sound effects (fire, smoke, sparks, explosions and more) to every player nearby, and gives admins chat commands to fire one-shot or looping effects in the world. It also offers client resources simple exports to play local effects and sounds.

- **Docs:** [Visual and audio effects](https://open2077.net/docs/effects), [Props and effects](https://open2077.net/docs/props-and-effects)
- **Starts:** on its own
- **Needs:** nothing
- **Runs on:** server and client

## Use it

Gameplay resources play their own effects through the server `Open77.effects` API and keep ownership of them. This resource projects them on each client, and keeps effects attached to a body while it streams in and out. The commands here own only what they create:

```text
/fx.catalog                              the curated effect aliases
/fx.here <effect>                        a one-shot effect where you stand
/fx.play <effect> <x> <y> <z> [bucket]   a one-shot effect at a point
/fx.loop <effect> <x> <y> <z> [bucket]   a looping effect; prints its id
/fx.list [bucket]                        the looping effects these commands made
/fx.stop <id>
```

`fx.list` and `fx.catalog` are open to everyone; the others are restricted commands that need the matching right in the server ACL.

Effects are named by curated aliases such as `fire.small`, `smoke.steam` or `electric.destruction`; `/fx.catalog` lists them.

For local presentation, client resources can use the exports `playVfx(effect, options)`, `playEntityVfx(effect, options)`, `playSfx(event, options)`, `attachVfx(handle, entity, slot)`, `stop(handle)` and `catalog()`, which wrap `Open77.vfx` and `Open77.sfx`. The `looping()` export lists the server-owned looping effects this client is showing.
