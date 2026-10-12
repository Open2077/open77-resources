# open77_cordon

Cordon gives your server a battle royale for up to 64 players: everyone stages in a lobby, deploys onto the map, loots weapons, armor and healing from the ground, and fights while NCPD closes the city block by block until one player or squad is left. It plays as Solo, Duo or Squad, with revives, optional bots and a ranked career.

- **Docs:** [Cordon — battle royale](https://open2077.net/docs/cordon)
- **Starts:** on its own
- **Needs:** `open77_weather`, `open77_weapons`, `open77_loot`, `open77_worldui`, `open77_interactions`, `open77_groundcircle`, `open77_zones`, `open-voice`
- **Runs on:** server and client

## Use it

Pick the Open77 Cordon template in the server setup wizard, or load this resource together with its HUD, [open77_cordon_hud](../open77_cordon_hud/). Run no other gamemode on the same server: [freeroam](../freeroam/) and the others also own spawn and death.

A 64-player match needs `simulation.playerInterestRadius` set to a non-zero value in your server configuration; the Cordon docs give the value to use. A database is optional. Without one, careers and ratings live in memory and are lost on restart.

Players press **Y** to join or leave the next match and **M** to open the tactical map, where they pick a landing spot during deploy. **END** applies an armor plate and **F8** uses a healing item. Every key can be rebound in the game's key bindings.

Format, active map, bot fill, revive window, cordon edge style and pacing are tunables you can change live from Warden's Tuning tab. They are declared in `shared/config.lua`. Bots are off by default, and a match that contains a bot is never rated.

| Command | Who | What it does |
|---|---|---|
| `/br.status` | everyone | One line of match state: phase, format, players alive, squads, bots, map. |
| `/br.where [id]` | everyone | What the server sees for a player, and why a rule refused something. |
| `/br.stats` | everyone | Your own career line. `/br.stats.of <id>` (restricted) reads someone else's. |
| `/br.start`, `/br.end` | restricted | Force the countdown into deploy, or end the match in flight. |
| `/br.bots` | restricted | Show, add or clear bots. Adding bots by hand makes the match unrated. |
| `/br.map` | restricted | The in-game map editor: maps, landing points, loot marks, grid and final cells. Run it with no argument for help. |
| `/br.map.check` | restricted | Survey progress for the active map. |

Restricted commands need the matching ACL entry, for example `command.br.map`. Maps you author are saved to the database when it is enabled, and as JSON files under this resource's `data/maps/` folder.
