# open77_actions

This library runs the part every job action repeats: a prompt on a spot, a timed animation with a progress bar, server checks, one player per spot, and carrying crates into vehicles. A job resource writes only its rules and the hooks that pay, and the server, not the player's client, decides when an action is done.

- **Docs:** [Actions and carrying](https://open2077.net/docs/actions), [Build a job: prompts, animations, items and pay](https://open2077.net/docs/world-interaction)
- **Starts:** with `ensure open77_actions` (it declares `auto_start false`)
- **Needs:** `open77_animations`, `open77_props`, `open77_interactions`, `open77_uikit`
- **Runs on:** server and client

## Use it

List `open77_actions` in `resources.load`, start it with `ensure open77_actions`, and add `dependency "open77_actions >=0.1.0"` to your job resource. Your job needs no client script: prompts, the progress bar (X cancels) and control blocking come from this resource's own client half.

```lua
local actions = exports.open77_actions
actions:define({
    id = "weld", label = "Weld the frame", durationMs = 8000,
    animation = { profile = "amb_1056d7_kneel_welder", at = "target" },
    hooks = { validate = "canWeld", commit = "payWeld", cancel = "weldCancelled" },
})
actions:target({ id = "frame_1", position = { x = -1410.2, y = 958.4, z = 23.4 }, yaw = 90.0, actions = { "weld" } })
```

- A hook is the name of an export on your resource: `validate`, `reserve`, `commit`, `cancel` and `marker`. Call `exports.open77_actions:verify(opId, "commit")` first in a hook.
- A target offers up to four choices on E, F, R and Y. `eligibility` and `epochs` plug in job, grade or duty checks from another resource's exports.
- Carrying: `carryDefine`, `carryPlace`, `carryPickup`, `carryPutdown`, `carryDrop`, `carrying`. The player puts an item down with G (rebindable).
- Shared spots owned by other resources: `claim`, `renewClaim`, `releaseClaim`, `claimHolder`.
- Every step is announced by the server event `open77_actions:transition`. When `open77_actions:ready` fires, this resource has (re)started and forgotten every definition: declare them again.
- Console: `actions.status [playerId]`, `actions.claims [bucket]`, `actions.trace on|off`.
