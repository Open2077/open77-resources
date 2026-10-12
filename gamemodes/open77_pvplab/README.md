# open77_pvplab

A test arena for the pieces a PvP arena is built from: server commands raise rings of props as walls, spawn NPC bots, assign teams and apply scripted damage, then print what they asked for and what came back. It is a developer tool, not a game mode for players.

- **Docs:** [Deathmatch — running the Kabuki Arena PvP mode](https://open2077.net/docs/deathmatch)
- **Starts:** on its own
- **Needs:** nothing
- **Runs on:** server and client

## Use it

Run it only on a local development server that nobody else can join. Every command it registers is unrestricted, so any connected player can spawn props and NPCs or damage other players. Never list it in `resources.load` on a public server or add it to a template.

Drive it from chat or the server console. Each readout goes to the server log with a `[pvplab]` prefix and back to the caller.

- `pvplab.ring <model> <radius> <visible 0|1> [scaleX scaleY scaleZ] [count]`: a ring of props around you, the shape of an arena wall.
- `pvplab.bucketring <model>` and `pvplab.quota <model> <count>`: props across routing buckets, and how many props one resource can hold. `pvplab.clear` removes every prop and NPC the lab made.
- `pvplab.npc`, `pvplab.solo`, `pvplab.gangs`, `pvplab.templates`: spawn bots in front of you, and list the NPC templates the server allows.
- `pvplab.npcpolicy`, `pvplab.npcpricing`, `pvplab.npcai`, `pvplab.npcgun`, `pvplab.npchurt`, `pvplab.npcwatch`, `pvplab.npcstate`, `pvplab.tasks`, `pvplab.botshot`: how bots take damage, move, hold a weapon and shoot back.
- `pvplab.ids`, `pvplab.npcowner`, `pvplab.enginewatch`: what the client sees of each bot, who simulates it, and whether engine hits are reported.
- `pvplab.arm`, `pvplab.team <teamId>`, `pvplab.tp`, `pvplab.where`, `pvplab.status`, `pvplab.damagelog`: weapons, teams, movement and readouts.

The client half only reads the streamed NPCs and reports their ids, their simulation owner and engine hits back to the server; it changes nothing.
