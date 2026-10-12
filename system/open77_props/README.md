# open77_props

This resource shows the server's world props and lights to every player near them, and gives admins chat commands to place, move, carry and remove props. The server owns each prop; this resource projects the ones around the player and reports back whether they appeared.

- **Docs:** [Server-owned world props](https://open2077.net/docs/props), [Props and effects](https://open2077.net/docs/props-and-effects)
- **Starts:** on its own
- **Needs:** nothing
- **Runs on:** server and client

## Use it

Gameplay resources create their own props with the server `Open77.props` API and keep ownership of them. The commands here own only what they create:

```text
/prop.catalog                      the curated model aliases
/prop.here <model> [yaw]           place a prop where you stand
/prop.create <model> <x> <y> <z> [yaw] [bucket]
/prop.near [radius]                list props around you (15 m by default)
/prop.list [bucket]
/prop.move <id> <x> <y> <z> [yaw]
/prop.pickup <id>, /prop.drop      carry a prop in your right hand, put it down
/light.here [intensity] [radius] [r] [g] [b]
/light.create <x> <y> <z> [intensity] [radius] [r] [g] [b]
/light.toggle <id> <on|off>
/prop.remove <id>, /prop.clear
```

`prop.list`, `prop.near` and `prop.catalog` are open to everyone; the others are restricted commands that need the matching right in the server ACL. From the server console, give `prop.create` a bucket, since the console has no position of its own.

Props made with these commands disappear when the server restarts, unless you turn on the `persist` tunable ("Persist props across restarts"). It needs the server's database, stores only the props and lights these commands create, and restores them at boot. Switching it off stops saving but deletes nothing.

On the client, the `get(id)` and `all()` exports return the props currently projected for this player.
