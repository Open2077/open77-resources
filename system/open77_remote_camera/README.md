# open77_remote_camera

This resource gives a server remote cameras and live video screens: a camera placed in the world renders its own view, which players watch on a screen in the world, in a rectangle of their HUD, or behind a web page. Operators place cameras and screens with an in-game editor, and other resources drive the same service through server exports.

- **Docs:** [Remote cameras and world screens](https://open2077.net/docs/remote-camera)
- **Starts:** on its own
- **Needs:** nothing
- **Runs on:** server and client

## Use it

Operator commands are restricted: each needs its `command.<name>` ACL right.

```text
/remote-camera.editor                 open the placement editor
/remote-camera.editor list            list saved placements
/remote-camera.editor reopen <key>    edit a saved placement     (delete <key> removes one)
/remote-camera.cameras [filter]       list the cameras this resource owns
/remote-camera.hud <key> [x y w h]    watch a camera in a HUD rectangle
/remote-camera.webui <key> [x y w h]  watch it behind a transparent page
/remote-camera.off                    close what these commands opened
/remote-camera.slots [n]              read or set the per-client view budget
```

In the editor, F4 snaps the camera to the surface you aim at, F6 makes it follow your view and F7 makes the surface follow your aim; all three are rebindable. Saved placements are kept in the resource's server KVP.

A server resource uses the exports `create`, `configure`, `get`, `list`, `remove`, `setAccess`, `acquire`, `release`, `createScreen`, `updateScreen`, `getScreen`, `listScreens`, `removeScreen`, `openView`, `updateView`, `getView`, `listViews`, `closeView` and `changes`. Every record belongs to the calling resource and is removed when that resource stops. Getters and creators answer `nil, reason` on refusal, mutators `false, reason`.

The tunable `slotsPerClient` (default 8, range 1 to 64) caps how many camera views one client renders at once, across all resources. Each view is a full extra scene render, so raise it with care.
