# open77_forcedoor

This resource adds two chat commands that open the door the player is looking at, even when it is locked. `/forcedoor` also sinks a static door below the floor when it refuses to open.

- **Docs:** [Networked world doors](https://open2077.net/docs/doors)
- **Starts:** on its own
- **Needs:** nothing
- **Runs on:** server and client

## Use it

Aim at a door and type one of these in chat:

```text
/unlockdoor   unlock and open the door you are looking at
/forcedoor    the same, and sink the door out of the way if it still will not open
```

The server receives the command and tells that player's client to act. The client finds the aimed door with `Open77.doors.aimedAny` (which also finds scenery doors), unlocks it and opens it. When the open fails, it resets the door and tries once more. With `/forcedoor`, a door that still does not open is moved 3 m down with `Open77.doors.sink`.

Both commands are registered without the restricted flag, so every player can use them. If players should not have them, leave this resource out of your server's resource list. For doors whose state the server owns and every player shares, use [open77_doors](../open77_doors/).
