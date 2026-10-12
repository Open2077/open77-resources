# open77_debug

This resource is the privileged developer toolkit for admins: it runs Lua on one player's client from a chat command, shows or hides vanilla HUD parts, and draws an aim inspector that names the object you look at. It is a trusted platform resource, so a downloaded resource can never get the same powers.

- **Docs:** [Privileged in-game Lua laboratory](https://open2077.net/docs/debug-runtime), [Vanilla HUD visibility](https://open2077.net/docs/hud-visibility)
- **Starts:** on its own
- **Needs:** nothing
- **Runs on:** server and client

## Use it

All three commands are restricted: give an admin the matching ACL right (`command.client.exec`, `command.hud`, `command.hudtest`).

```text
/client.exec <playerId> <lua>        run Lua in that player's debug VM and print what it returns
/client.exec 3 return Open77.debug.command('vehicle.list')
/hud <component|all|state> <show|hide|toggle>
/hudtest [show|hide|toggle]          every vanilla HUD component at once
```

- `client.exec` takes up to 32 KB of source, answers with up to 8 KB of text and times out after 10 seconds. Like `hud` and `hudtest`, it must be issued by an admin in game, not from the bare server console. The code runs only inside this resource's own client VM, under the normal memory and time quotas.
- HUD components: `minimap`, `compass`, `clock`, `health`, `stamina`, `weapon`, `speedometer`, `questTracker`, `phone`, `scanner`, `vanillaNotifications`, `crosshair` and `hubMenu`.
- The aim inspector is a transparent overlay that never takes focus. It is switched on and off by the Open77 client itself, not by a command; it shows the class, name, kind, distance and position of what you aim at.

From the developer console, `resource.emit open77:blips:probe <action>` and `resource.emit open77:doors:probe <action>` test map pins and the door you aim at (with no action, or `state`, the door probe only reads).

Do not use it from gameplay code: it is a tool for checking and fixing a live server.
