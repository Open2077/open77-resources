# open77_perspective

This resource lets players switch between first and third person with a key (F6 by default) and remembers their choice on each server, while the server decides whether third person is allowed at all. It also gives operators a `/perspective` command to set that policy live.

- **Docs:** [Third person](https://open2077.net/docs/perspective)
- **Starts:** on its own
- **Needs:** nothing
- **Runs on:** server and client

## Use it

With no setup, every player may use third person. The policy normally belongs to your gamemode, which calls `Open77.perspective.setPolicy` on the server. To change it live from the console or chat (restricted, ACL `command.perspective`):

```text
/perspective                     show the current policy
/perspective allowed             players choose freely (the platform default)
/perspective default tps         third person unless the player chose otherwise
/perspective forced fpp          pin everyone to first person
/perspective disabled            no third person
```

Once you use the command, this resource also becomes a policy authority: if a gamemode sets one too, the last one written wins.

On the client, the player's preferred view and their toggle key are saved per server and restored on the next join. When a policy pins the view and is later lifted, the player gets their own choice back. Client exports for your own UI:

```lua
exports.open77_perspective:toggle()
exports.open77_perspective:set("tps")       -- or "fpp"
exports.open77_perspective:setKey("f5")     -- letters, digits, F1 to F12 and a few named keys
local state = exports.open77_perspective:state()
```

`get()` and `key()` read the current view and key. Client resources can also listen for the local event `open77:perspective:policyChanged` (policy, perspective). The aiming reticle for third person is a separate resource, [open77_reticle](../open77_reticle/).
