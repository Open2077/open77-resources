# open77_reflex

This resource runs reflex overdrive, a boost your server grants: the player presses a key and their own body moves and attacks faster for a few seconds, while the world and every other player keep normal speed. Other players see the boost on the boosted body (glow, sparks, foot trails and an `// OVERDRIVE` tag on the nameplate) and hear its start and end.

- **Docs:** [Reflex overdrive](https://open2077.net/docs/reflex-overdrive), [Ability activation leases](https://open2077.net/docs/ability-activation-leases)
- **Starts:** on its own
- **Needs:** `open77_effects`
- **Runs on:** server and client

## Use it

Leave it running. It grants nothing by itself: your server resource defines an overdrive and grants it to a player (the server API is on the docs page). No clock is slowed, no bullet and no other player is affected.

The definition it accepts has `profile = "reflex_overdrive"` and a `config` with:

- `tier`: `reflex` or `reflex_heavy` (the heavy tier adds an electric arc on the right hand);
- `durationMs`: 500 to 15000;
- `inputKey`: the server's default key (a letter or digit, `f1` to `f12`, or a name such as `space` or `shift`);
- `presentation`: `native` (effects and sounds), `silent` (effects only) or `none`.

The key is a rebindable action, `reflex_overdrive` ("Overdrive: engage the reflex boost"), registered on `X` until a grant arrives. A player's own rebind in the pause menu settings wins over the server default. A press is refused while a UI page has the keyboard, and the boost ends on its deadline, on death, in a vehicle or a workspot, or when the server cancels it.

Two client exports report the local state:

```lua
local caps = exports.open77_reflex:capabilities() -- maximumDurationMs = 15000, projection = "ready" | "absent"
local now = exports.open77_reflex:state()         -- phase, kind, remainingMs, reason
```

The observer presentation lives in `server/presentation.lua` and uses the public `Open77.effects` API, so you can read it as an example of attaching timed effects and sounds to a player.
