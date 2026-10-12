# open77_deathmatch_hud

The combat HUD for [`open77_deathmatch`](../open77_deathmatch/): it shows players the fight (hitmarker, directional damage, health, armor, ammo, crosshair and streak callouts) alongside the match timer, kill feed, standings, enrolment panel and result banner. It decides nothing; it only draws what the gamemode and the server send.

- **Docs:** [Deathmatch — running the Kabuki Arena PvP mode](https://open2077.net/docs/deathmatch)
- **Starts:** on its own
- **Needs:** `open77_deathmatch`
- **Runs on:** server and client

## Use it

List `open77_deathmatch_hud` next to `open77_deathmatch` in `resources.load`. It
starts on its own and has no commands or settings of its own. To translate it,
edit `shared/strings.lua`.

Separate from the gamemode and on `reload_policy "reconnect"` on purpose:
editing a stylesheet or a string here must never reset a live match.

## Two surfaces, split by update rate

Driving a scoreboard at 60 fps to get a responsive hitmarker is how a HUD
starts costing frame budget, so the page is two pages.

| Surface | fps | Carries | Focus |
|---|---|---|---|
| `web/combat.html` | 60 | crosshair, hitmarker, directional damage, health, armor, ammo, spawn-protection ring, callouts | never; pointer events off |
| `web/match.html` | 12 | match band, instance identity, shared weapon, kill feed, notices, countdown, result, standings, death screen, enrolment panel | only the panel, only while open |

`client/combat.lua` pushes the fast half at 25 Hz and lets CSS interpolate
across the gap; `client/match.lua` pushes the slow half at 10 Hz. Nothing else
crosses between them: the match state reaches the combat surface through one
call, `DeathmatchCombat.onMatchState`.

## Language

Every player-facing word lives in `shared/strings.lua` and nowhere else: not
in the HTML, not in the CSS, not inline in the JavaScript. Both pages receive
that table on `dm:ready` and paint their static labels from `data-t`
attributes; dynamic text calls `DMStrings.t` / `DMStrings.fmt`. Translating the
HUD is one edit to one file.

The server never sends display language. It sends a **kind** and a **count**
(`multi`, `streak`, `firstBlood`, `revenge`) and this table names them.

## Authority

The pages are presentation only. The one local calculation they are allowed is
smooth interpolation between snapshots.

| Datum | Source |
|---|---|
| phase, clock, standings, result, instance, teams, spawn protection, kill feed, callouts | the gamemode's authoritative state push and events |
| health, armor, god mode | `Open77.players.getHealthState()`, the client mirror of the **server** damage ledger, not an engine stat pool |
| damage taken, and the health after it | `open77:localDamaged` (server-confirmed) |
| hits dealt | `open77:hitConfirmed` (the server's credit) |
| magazine, capacity, reserve | `Open77.weapons.snapshot()`, the only source that exists, because the magazine drains inside the engine and the server never sees a round leave the chamber |

The single piece of geometry the client computes is turning the world-space hit
direction into a screen bearing for the damage indicator. `lastHitDirection`
points **from the attacker to the victim**, so it is negated once, in
`client/combat.lua`, and never again.

## Screen regions

The HUD follows the Open77 UI screen regions. Two placements are deliberate:
the kill feed does not sit over the vanilla minimap, and the lobby dock does not
sit over the vanilla quickslots.

| Region | Used for |
|---|---|
| `MATCH_BAND` 34–82% x, 7–20% y | match band, shared weapon card, head of the kill feed |
| `STAGE` 25–75% x, 20–62% y | countdown, result, notices, callouts, protection countdown, tail of the feed |
| `GAMEMODE_LOW` 25–75% x, 62–86% y | vitals/ammo dock and the lobby dock, both kept in the upper half (62–75%) because the engine's aim-gated interaction prompt intrudes near 82% y |
| `RETICLE` 50% ±3% | reticle and hitmarker only; no text |

The standings, the enrolment panel and the death screen are modal and therefore
exempt.

## Manifest

Scripts are listed explicitly, one per line. `client/**/*.lua` requires an
intermediate directory and matches **nothing** against a flat `client/`, and an
empty glob refuses the whole session resource set with `script_pattern_empty`,
so no player can connect.

Load order matters: `client/combat.lua` defines `DeathmatchCombat` before
`client/match.lua` calls into it, and `client/main.lua` is last because it
creates both pages and hands them to the two modules.
