# open77_nameplates

This resource draws a name above every other player within 35 m, and switches to squad-only plates in competitive modes so a name cannot be used to spot enemies through walls. In competitive play your squadmates keep a plate (with health and shield), and an enemy you have just hit shows a short health and shield readout.

- **Docs:** [Drawing in the world](https://open2077.net/docs/world-drawing)
- **Starts:** on its own
- **Needs:** nothing
- **Runs on:** server and client

## Use it

It works with no setup. The operator retunes it live from Warden (group "Nameplates") or with `tunable.set open77_nameplates <key> <value>`:

| Tunable | Default | Meaning |
|---|---|---|
| `policy` | `auto` | `auto`: plates for everyone until a competitive gamemode says otherwise; `open`: always every player; `competitive`: squad-only always |
| `friendlyPlates` | `true` | keep plates over your squad or team (visible through walls) |
| `friendlyDistance` | `200` m | how far a squadmate's plate is drawn |
| `friendlyVitals` | `true` | add health and shield to a squadmate's plate |
| `enemyVitals` | `engaged` | `engaged`: readout over an enemy you just damaged; `off`: nothing for enemies |
| `enemyVitalsSeconds` | `2.5` s | how long that readout stays after your last hit |
| `enemyVitalsDistance` | `120` m | range of that readout |

In `auto`, the Cordon and deathmatch modes are recognised from their own state events. Any other gamemode declares its teams from a client script:

```lua
exports.open77_nameplates:setFriendlies({ 12, 15, 21 }, { inFight = true })
exports.open77_nameplates:setPolicy("competitive")   -- or "auto", "open"
```

Other client exports: `set(playerId, options)`, `remove(playerId)`, `setEnabled(bool)`, `isEnabled()`, `policy()` and `clear()` (which also switches the plate drawer off).
