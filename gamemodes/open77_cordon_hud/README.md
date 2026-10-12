# open77_cordon_hud

This resource draws the Cordon battle royale interface for each player: crosshair and hitmarker, health, armor and ammo, the staging and deploy panels, kill feed, squad panel, result card, the tactical map and the cordon edge. It holds no rules; everything it shows comes from [open77_cordon](../open77_cordon/) through one state push.

- **Docs:** [Cordon — battle royale](https://open2077.net/docs/cordon)
- **Starts:** on its own
- **Needs:** `open77_cordon`
- **Runs on:** server and client

## Use it

Load it next to `open77_cordon`. The Open77 Cordon template installs both. The HUD is a separate resource because it owns WebUI pages and declares `reload_policy "reconnect"`, while the game rules reload in place. Editing the HUD reconnects players instead of resetting a live match.

It creates four WebUI surfaces:

- `web/combat.html`: crosshair, hitmarker, damage direction, health, armor, ammo, the outside-the-cordon warning and revive progress.
- `web/match.html`: staging and deploy panels, phase band, kill feed, notices, squad panel, inventory strip and result card. It never takes the mouse.
- `web/tacmap.html`: the block grid, closures, squad and pings. It takes the mouse only while it is open.
- `web/wall.html`: the projected cordon edge, shown only while the boundary is within draw range.

It registers two rebindable keys: **Y** joins or leaves the next match and **M** opens the tactical map. Hints on the HUD name the key the player actually bound.

Every player-facing word lives in `shared/strings.lua`; the pages fill their labels from that table. Bots are labelled on every surface that names a player.

Each visible surface is a full-screen WebUI layer, so the HUD uses video memory on every client. Keep that in mind if you run several game clients on one machine.
