# open77_gizmos_editor

A worked example of server-authorized placement with the gizmo API: an operator runs `/gizmo.editor`, drags a test chair into place with on-screen handles, and the server checks the proposed transform before it moves the real prop. Copy `authority.lua` when you build your own placement tool.

- **Docs:** [Entity gizmos (client Lua)](https://open2077.net/docs/gizmos)
- **Starts:** on its own
- **Needs:** nothing
- **Runs on:** server and client

## Use it

This is a development example: leave it out of a public server's load list. It
requires a client with the gizmo API. The placement round trip (drag, Enter,
server check, then the accepted transform on the native and replicated prop)
works for the operator who edits; how other players' games show the edit while
it is in progress is not covered yet.

Install this resource under your server resource root, include
`open77_gizmos_editor` in its load list and grant an operator
`command.gizmo.editor` in the server ACL. Reconnect after installing.

- `/gizmo.editor` creates a test chair near that operator (once), waits for its
  native projection and opens its translation gizmo.
- Drag handles; `R` switches to yaw rotation, `T` to translation, `L` to local
  axes. `Ctrl+Z/Y` undo/redo. `Enter` proposes the placement, `Escape` cancels.
- `/gizmo.editor clear` closes the editor and removes only that operator's test
  chair. Disconnect and resource stop also clean up these temporary objects.

The client sends **one** accepted transform, not every mouse frame. The server
checks the authenticated sender, current ACL, identity, fresh/ready/alive state,
resource ownership, routing bucket, target revision, attachment state, ticket
expiry, finite values, normalized yaw-only quaternion, unchanged scale and
distance (25 m from the operator; 10 m maximum displacement). Tickets are single
use and target-locked. No RPC accepts a sender or resource owner from the client.
There is no persistence; integrate your own database only after acceptance.

`authority.lua` is the reusable policy example; `server.lua` adapts it to real
Open77 reads and prop mutations. All adapter calls are synchronous: **do not
yield between revision validation and mutation**. This example owns its props,
so no other resource can change them through the normal prop API. If adapting
this to shared targets, use that system's revision-aware mutation/lease API too.

The Open77 source repository exercises this exact policy in the server's Lua 5.4
runtime with `scripting/tests/gizmo_editor_test.py` (it needs a local server
build). It covers acceptance, spoof/replay, revocation, replacement identity,
revision conflict, bad values, distance, disconnect and expiry. These are
policy tests: they do not check native placement or what other players see.
