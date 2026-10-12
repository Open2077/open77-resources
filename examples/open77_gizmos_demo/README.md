# open77_gizmos_demo

A test bench for the client gizmo API: an admin opens move, rotate and scale handles on a virtual point, a spawned chair, their own character, a vehicle, an NPC or a prop, and every gizmo event is printed to the client log. Install it on a development server only: it previews edits and is not a production admin tool.

- **Docs:** [Entity gizmos (client Lua)](https://open2077.net/docs/gizmos)
- **Starts:** on its own
- **Needs:** nothing
- **Runs on:** server and client

## Use it

It requires a client with the gizmo API.

Install this folder in your development server's resource tree and add
`open77_gizmos_demo` to its resource load list. The restricted `gizmo.demo`
command requires `command.gizmo.demo` in the caller's ACL (owner/admin wildcard
grants also apply). Use it **once you are fully in the world**, with a living player
on foot, the game focused and no menu capturing input:

```text
/gizmo.demo virtual
/gizmo.demo localProp
/gizmo.demo target player 0
/gizmo.demo targetData vehicle <server-vehicle-id>
/gizmo.demo state
/gizmo.demo cancel
```

The debug bridge can forward those same server commands without the leading
slash. The local `resource.*` forms below are for offline testing only;
they are deliberately refused during a multiplayer session:

```text
resource.start open77_gizmos_demo
resource.emit gizmos:demo virtual
resource.emit gizmos:demo mode rotate
resource.emit gizmos:demo mode scale
resource.emit gizmos:demo space local
resource.emit gizmos:demo state
resource.emit gizmos:demo undo
resource.emit gizmos:demo redo
resource.emit gizmos:demo cancel
resource.emit gizmos:demo localProp
resource.emit gizmos:demo target player 0
resource.emit gizmos:demo target vehicle <server-vehicle-id>
resource.emit gizmos:demo target npc <server-npc-id>
resource.emit gizmos:demo target puppet <client-entity-handle>
resource.emit gizmos:demo target prop <server-prop-id>
resource.emit gizmos:demo clear
resource.stop open77_gizmos_demo
```

`set <x> <y> <z>` exercises numeric edits separately from mouse drags. The `state`
report includes event counts and the live character state; read entity geometry
or the platform's native entity commands independently to prove the target moved.
An API return value alone is not that proof.
`targetData <kind> <id>` uses `preview=false`: manipulate and submit the gizmo's
transform without moving the native body. Use this to compare callback-only and
native-preview side effects; it does not grant server authority either.
When scripting the server commands, wait for the activation/result log before
sending a dependent command: command transport acknowledgment is only a queue
acknowledgment, and back-to-back activation/set requests can be dispatched out
of order. Also inspect `settled` and its `nativeTransform` for the asynchronous
own-player/vehicle restoration paths; the accepted `transform` stays a proposal.

For an **offline** local-puppet test, install this demo in the development
client's bootstrap tree, load a clean world with `session.labload female`,
and verify actual gameplay/attached living player before mutating it. Use
`world.spawn 2 2 0 0`, then `world.list` to obtain its registry handle. Target
that handle with `resource.emit gizmos:demo target puppet <handle>`, move it
with `set`, and commit. Observe `settled`, independently read `entity.inspect`
after at least a second, and check `world.component <handle> MoveComponent status`
has returned to its original enabled state. Repeat undo/redo/cancel and resource
stop. `world.despawn <handle>` removes only the test-owned puppet. Stop/remove
the temporary bootstrap demo before reconnecting to the development server.
These raw world mutations remain deliberately unavailable in multiplayer.

`localProp` spawns one resource-owned metal chair in front of the player and waits
for attachment before opening the editor. `clear` or resource stop removes it.
All other target actions use existing entities and never spawn a server object.
The server forwards only explicitly listed preview actions to the authenticated
admin who ran the command. No authoritative mutation is performed: a network
target's accepted result still needs server validation.

### Server-placement interruption test

The separate restricted `/gizmo.vehicle` command (`command.gizmo.vehicle` ACL)
creates one disposable test car per admin. It never accepts an arbitrary
vehicle ID or position and removes that car on `clear`/disconnect/resource stop.

1. `/gizmo.vehicle spawn`, then `/gizmo.demo target vehicle <returned-id>`.
2. Move its preview with the handles or `/gizmo.demo set <x> <y> <z>`.
3. `/gizmo.vehicle place` moves that **test car only**, two metres from
   its server spawn origin with yaw 90. Expect cancellation with
   `transform_superseded`, and native/server poses converging at that destination.
4. Repeat the edit, then `/gizmo.vehicle placeAfterCommit`: asks the client to
   commit and schedules the same placement 100 ms later, exercising the native
   restoration fence's preemption window. Compare actual event/log timestamps;
   the command alone does not prove the network request arrived inside it.
5. `/gizmo.demo state` logs independent server coordinates; use native entity
   inspection too, wait past five seconds, verify the session remains active
   and a new virtual gizmo can acquire input. `/gizmo.vehicle clear` cleans up.

This fixed-pose server test is intentionally not a production vehicle editor
and does not accept a client's proposed coordinates as authoritative.

### NPC/prop canonical-state interruption

`/gizmo.target npc|prop spawn|place|nudge|turn|state|clear` is restricted by
`command.gizmo.target` and uses only its own disposable objects in your bucket.
Spawn returns a server ID; target it with `/gizmo.demo target npc|prop <id>`.
Preview a different position, then run `state`: canonical coordinates must stay
unchanged. For a locally simulated NPC, keep the preview open past the authority
lease interval and verify the same owner/epoch with `state`. The client sends
stationary baseline keepalives, not the edited body position.

Run `place` during the edit. The server moves its test object two metres from
the spawn origin and sets yaw 90. The editor must cancel (transform superseded,
or authority changed for an NPC lease revocation); independent native readback
must converge to the new server pose, not the preview or the initial pose.
`state` reads the server's record and `clear` removes only that test object.
`nudge` uses a 25 cm X offset from spawn with yaw 90. `turn` retains that position
and changes yaw to 180, checking rotation-only placement after the nudge.

### Native vehicle occupants

Spawn the test car and NPC, then `/gizmo.vehicle board`. Wait for the NPC
task and independently inspect its mount plus `vehicle.status <registry-id>`;
the command acknowledgment alone is not proof of occupancy. Gizmo creation for
that car (including a generic `entity` alias) must refuse
`target_vehicle_occupied`. `/gizmo.vehicle leave` requests normal exit; verify
the native mount is gone and editing becomes possible. Clear the NPC/car after
the check. The commands cannot mount an arbitrary player's character.

Also test an entry **during** a physical preview: start editing the empty car,
move its preview, then run `/gizmo.vehicle board`. Expect cancellation with
`vehicle_entry_requested`, then `settled/native_preview_restored`, followed by
the NPC mount at the original car pose. The NPC task retries while restoration
is pending. Confirm all three using event timestamps and independent native
vehicle/NPC reads; a task submission alone does not validate this sequence.

Controls: drag with left mouse, T/R/S mode, L space, Shift precision, Alt unsnapped,
Ctrl+Z/Y history, Enter accept, Escape cancel drag/session. Close the developer
console before activating: native input cannot be acquired by a background game
or while the console owns focus. The external debug bridge does not open it.

Targets covered: virtual translate/rotate/scale; own player; local puppet;
network NPC; network vehicle; local prop; network prop. For each one, check the
native pose change, undo/redo, cancel restoration, acceptance semantics, input
release, resource stop and stream-out. Check network visibility from another
player's game, not only your own. See the
[gizmo API reference](https://open2077.net/docs/gizmos).
