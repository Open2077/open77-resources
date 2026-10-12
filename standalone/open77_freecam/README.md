# open77_freecam

Gives your admins a local free camera: `/freecam` or F9 detaches the view and lets them fly it around while their character stays where it is. It adds no teleport, noclip, invulnerability or server entity change, so the character stays visible to other players and can still be hurt.

- **Docs:** [Scripted cameras](https://open2077.net/docs/cameras)
- **Starts:** with `ensure open77_freecam` (it declares `auto_start false`)
- **Needs:** nothing
- **Runs on:** server and client

On entry from **first person**, a complete third-person body (head, hair, outfit)
is prepared before detaching the view. On exit, the previous player perspective
and FOV resume.

Requires the client with `camera.create({thirdPersonBody=true})` support. Older
clients receive `updated_freecam_client_required`; they are not silently accepted.

## Use it

Copy `open77_freecam` to your server's resource tree, add it to `resources.load`,
then `refresh` / `ensure open77_freecam`. This resource is **not auto-started**.
Grant `command.freecam` through the normal server ACL to the desired admin role.
No dependency on an admin menu or gamemode is needed.

- `/freecam` or **F9**: enter / leave. Opening from F9 uses the server's restricted command.
- `/freecam on`, `/freecam off`, `/freecam state`: explicit lifecycle / diagnostic snapshot.
- **W A S D** (automatically **Z Q S D** on AZERTY), **Space / C**: fly / height.
  Rebind in Pause → Settings → Key bindings.
- Mouse: look. Wheel: speed. **Shift**: boost. **Ctrl**: precision / Ctrl + wheel: FOV.
- **Home**: return the camera behind the body. **Backspace** or **F9**: exit.

`config.lua` sets defaults: 6 m/s, 150 m radius (hard package maximum 200 m),
sensitivity and keys. Menus/chat suspend movement and discard accumulated mouse
input; the passive HUD never captures keyboard or cursor.

## Integrate

Client resource:

```lua
-- dependency 'open77_freecam >=1.0.0'
local ok, reason = exports.open77_freecam:start()
-- asynchronous preparation; use the state export / events below
local state = exports.open77_freecam:state()
exports.open77_freecam:stop()
```

`start()` returns `true` once preparation is scheduled, or `false, reason`.
`state().phase` is `off`, `preparing`, or `active`; `position` is the requested
world pose and `view` the actual engine readback. Local events:
`open77:freecam:started`, `open77:freecam:stopped(reason)`.
An export caller can release only its own session; stopping the caller also
releases it. Admin command/key exits can always close it. Integrators must
authorize their own opening flow; local exports are not a server security gate.

For a different flight UI, use native `Open77.camera.create`, `activate`,
`setTransform`, `destroy` with `thirdPersonBody=true`; see
[Scripted cameras](https://open2077.net/docs/cameras).
Movement/control blocks belong to this resource, so releasing them cannot undo
another activity's blocks. Partial start, errors, death, resource stop and native
camera preemption clean up without requiring a player reconnect.

## Limits

On-foot only. No lens collision. No guarantee that distant interiors are streamed:
world streaming still follows the body, **not the lens**. The range clamp prevents
flying indefinitely into unloaded space. Server teleports are not blocked.
This is not a spectator teleport or an anti-cheat bypass.
