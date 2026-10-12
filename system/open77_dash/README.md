# open77_dash

This resource gives players the native ground dash and Air Dash once your server grants it to them: the player presses a key and the body dashes on that frame, in the direction they are moving or looking. The server stays in charge of who may dash, how often, and whether each dash counts.

- **Docs:** [Native Dash and Air Dash](https://open2077.net/docs/dash), [Ability activation leases](https://open2077.net/docs/ability-activation-leases)
- **Starts:** on its own
- **Needs:** nothing
- **Runs on:** client

## Use it

Leave it running. It defines no loadout and grants nothing by itself: your server resource defines a dash and grants it to a player (the server API is on the docs page), and this resource projects that grant onto the player's body.

The definition it accepts has `profile = "dash"` and a `config` with:

- `inputKey`: a lowercase letter or digit, `f1` to `f12`, or a name such as `space`, `shift`, `ctrl`, `alt`, `tab`, `left`, `pageup`;
- `allowGround` and `allowAir` (at least one `true`), `movementProfile = "native"`;
- `presentation`: `native`, `silent` or `none`;
- `maxFallSpeed` between 0.1 and 30.

The dash goes the way the movement keys point (forward when none is held), relative to the camera. It is refused when the player is dead, in a vehicle or in a workspot, or while a UI page has the keyboard. One Air Dash is allowed per airtime.

Two client exports report the local state:

```lua
local caps = exports.open77_dash:capabilities() -- profile, maxAirUses, projection = "ready" | "pending" | "absent"
local now = exports.open77_dash:activity()      -- phase, mode, sequence, elapsedMs, reason
```

When the server holds an activation lease for the player, a press is spent locally and reported afterwards; when it does not, the client asks for a permit first. A dash the server rejects is cancelled, and the body can be moved back to the position the server gives.
