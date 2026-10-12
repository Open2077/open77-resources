# open77_cordonlab

A test arena for the building blocks of the Cordon battle royale: each server command runs one experiment, such as a high drop, ghost spectating, cordon damage, the loot loop, revive at the body, a line of edge lights, vehicles, a server-flown AV or teams, and prints what it asked for and what came back. It is a developer tool, not a game mode for players.

- **Docs:** [Cordon — battle royale](https://open2077.net/docs/cordon)
- **Starts:** on its own
- **Needs:** nothing
- **Runs on:** server and client

## Use it

Run it only on a local development server that nobody else can join. Every command it registers is unrestricted, so any connected player can use them, and `lab.exec` runs Lua on a player's client. Never list it in `resources.load` on a public server or add it to a template.

Drive it from the server console or from chat. Each readout goes to the server log with a `[cordonlab]` prefix and back to the caller. The resource also logs every life, damage, weapon and loot event with its context. Many commands take an optional player id so the console can target someone.

- `lab.where`, `lab.tp`, `lab.hop`, `lab.spawn`, `lab.autospawn on|off`: position and placement.
- `lab.drop <height>`, `lab.ghost <0|1>`, `lab.god <0|1>`: the drop, ghost spectating and god mode.
- `lab.hurt`, `lab.hurt.tick`, `lab.shoot`, `lab.kill`, `lab.revive`, `lab.heal`: damage, death and revive.
- `lab.loot`, `lab.drops`, `lab.pickup`, `lab.arm`, `lab.verified`: ground loot and weapons.
- `lab.lights`, `lab.car`, `lab.av`, `lab.team`, `lab.place`: edge lights, vehicles, the AV and teams. `lab.lights.clear`, `lab.av.stop` and `lab.vehicles.clear` clean up.
- `lab.probe`, `lab.probe.line`, `lab.probe.grid`, `lab.mark`, `lab.marks`: ground probes and position captures for surveying a map. `lab.marks` prints the captures as Lua you can paste.
- `lab.exec`, `lab.bridge` and `lab.facts` work through [open77_debug](../../system/open77_debug/) on the player's client.

The client half of this resource only turns noclip on for the ghost spectator and sends loot pickup requests for `lab.pickup`.
