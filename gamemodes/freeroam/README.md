# freeroam

Freeroam turns your server into an open Night City sandbox: players spawn, call cars, pick weapons, travel across the city and fight, and they can join races, foot races and PvP matches without changing servers.

- **Docs:** [Writing a gamemode](https://open2077.net/docs/writing-a-gamemode)
- **Starts:** on its own
- **Needs:** `open77_weapons`, `open77_cyberware_lab`, `open77_contextmenu`, `open77_props`, `open77_worldui`, `open77_zones`, `open77_notifications`, `open77_animations`, `open77_doors`
- **Runs on:** server and client

`freeroam` is the default example game mode shipped with the Open77 dedicated server. It provides
configurable player spawning, automatic respawn, curated weapon loadouts, server-owned vehicles,
named destinations, map blips, PvP with spawn protection and a kill feed, and player/admin tools.

> [!NOTE]
> This resource is a reference implementation for development servers. Review its commands,
> permissions, spawn points, and vehicle policy before using it on a public server.

## Use it

Pick the Night City Freeroam template in the server setup wizard, or list `freeroam` in `resources.load` with the resources it needs. Add [open77_freeroam](../open77_freeroam/) for MySQL player persistence and the `kick` and `ban` commands. Race and PvP already run inside Freeroam, so do not also load `open77_deathmatch`, `pursuit`, `open77_cordon` or another gamemode on the same server.

Players open the menu with `/freeroam`, call a car with `/car [model]`, travel with `/goto <location>`, and join activities with `/race`, `/footrace` and `/pvp`. Admin commands such as `/freeroam.tp` and `/freeroam.cleanup` need `command.freeroam.*`. Spawn points, destinations, the vehicle and weapon catalogs and the PvP rules live in `shared/config.lua`; see [Configuration](#configuration).

## Group playtests

Admins can use `/admin` → **Freeroam playtest**, or:

- `/admin.playtest.foot`: enrol all ready players in the Foot Race queue.
- `/admin.playtest.race`: enrol everyone in the Vehicle Race queue.
- `/admin.playtest.ffa`: enter the same free-for-all directly.
- `/admin.playtest.blade`: enter the same Blade FFA directly.
- `/admin.playtest.cancel`: cancel pending transfers.

The admin is included. Existing modes return players through their normal
cleanup before admission; mounted players dismount first. Loading/dead players
and active course editors are skipped and counted. Editor drafts are retained.
Race voting/countdown starts after the batch completes. Commands require
`command.admin.playtest.<action>` (covered by operator `command.admin.*`),
are unavailable outside Freeroam, and recheck permission while transferring.
Disconnecting the admin or revoking access stops pending transfers.

Everyone receives Street Overdrive by default: press **X** for a 10-second
boost at **2.5× movement speed**, with a 13-second cooldown after it ends and
23-second charge regeneration from activation.
It speeds up the owner in real time; it never slows the shared world. Existing
Overdrive presets and other resources' grants are preserved. Foot races draw a
katana in melee slot 3 at GO. The FFA keeps its normal weapon loadout.

**Blade FFA** is a separate unranked melee mode on the FFA map. Join from
`/pvp` or `/pvp.blade`. In **Loadout → Blade FFA Weapons**, choose among 13
weapons: katanas (including Errata and Byakko), standard/electric Mantis Blades,
knives, Blue Fang, machete, tomahawk, hammer, bat, baton and chainsword.
`/guns list` lists melee keys while in Blade FFA; `/guns <key>` selects one.
Changes during combat apply on the next respawn; spawn protection allows an
immediate change. Firearm slots and non-melee hits are refused by the server.
The mode keeps double jump, dash and Overdrive; its HUD shows **X**, the active
timer, recharge countdown and a subtle cyan edge pulse while boosted.
Mantis Blades temporarily use the native arm slot; an existing arm implant is
preserved and the mode uses a katana instead. Leaving removes the temporary arms.

Foot racers have god mode throughout the heat, restoring their previous setting
on return. If a native lethal fall still produces a death, they automatically
respawn at their last validated checkpoint (or the start), keeping their progress
and running timer. **F3** also returns a living racer to that checkpoint.

## Structure

| Path | Responsibility |
|---|---|
| `open77.lua` | Manifest, scripts, dependencies, and required permissions. |
| `shared/config.lua` | Spawn points, destinations, vehicle/weapon catalogs, quotas, player tools, and blips. |
| `server/main.lua` | Commands, validated menu actions, weapon requests, respawn policy, vehicle ownership, and teleport transactions. |
| `server/combat.lua` | PvP policy: friendly fire, spawn safe zones, multipliers, and the kill-feed broadcast. |
| `client/main.lua` | Client readiness, map blips, the `/freeroam` menu, the custom HUD, and scoreboard. |
| `client/animations.lua` | RP catalogue and playback controls through the public asynchronous animation API. |
| `client/killfeed.lua` | Combat feedback HUD: kill feed, authoritative hitmarker, damage flash. |
| `web/` | HTML/CSS/JS menu, custom gameplay HUD, scoreboard, and kill-feed surfaces rendered by the Open77 WebUI. |

`shared/config.lua` is downloaded by clients. Never place credentials or private server data in it.

## Menu

Hold **J** to point your finger in the camera direction; release it to stop.
The action is registered as **Point with your finger (hold)** under
**Pause → Settings → Key Bindings** and can be rebound. Put your weapon away
and stop any other animation first. Pointing uses the platform animation API
for replication and interruption, including cancellation of a pending start
when the key is released quickly. **X** remains the Overdrive shortcut.

`/freeroam` opens a centered WebUI workspace (`layer = "menu"`). Its persistent sidebar groups
**Explore & equip**, **Your character**, and **Play together** separately from the scrolling content.
The header and close action stay visible at all scroll positions. Catalogs include result counts,
category filters and explicit empty states; custom models, ammunition, coordinates and sandbox
settings use expandable sections. Destructive player actions are separated from everyday tools.

Keyboard: `Tab` moves through controls, `↑` / `↓` / `Home` / `End` navigate the sidebar without
activating an activity, `Enter` / `Space` selects, `/` focuses the current section's search, and
`Esc` returns to the game. Changing section resets the content scroll but retains search/filter
choices. Reduced-motion preferences disable menu transitions.

- **Vehicles** provides a searchable, category-filtered catalog, including pilotable AVs under
  the **AV** filter, optional custom `Vehicle.*` records, a live owned/maximum counter, and
  repair/engine/lock/light controls for the latest owned vehicle.
- **Weapons** assigns one of the configured templates to slots 1–3, displays the current loadout,
  changes reserve and magazine ammunition, activates or clears a slot, and holsters the weapon.
- **Travel** searches named destinations, districts and spawn points and accepts explicit coordinates.
- **Televisions (administrators only)** places shared screens through `open77_media` and controls
  their URL, sound, playback and placement. Ordinary players cannot open this tab or use `/tv`.
  The server checks `command.media.spawn` before advertising the tab, and the matching
  `command.media.*` permission on every management event/command. Grant `command.tv` for
  the shortcut and `command.media.*` for full TV management to a custom operator role;
  built-in owner/admin already qualify. Passive viewing of administrator-created screens
  remains available to players. URL input is read when spawning, not at catalog reception.
- **Player** returns to spawn, restores health and armor, revives, toggles god mode, or enters the
  normal death/respawn flow. Its status strip reflects authoritative health, armor, and god mode.
- **Race** opens the integrated race activity and course creator.
- **Foot Race** opens foot races and the on-foot course creator. Native 3D
  arrows identify landings above low ground cylinders; the finish is a gold diamond.
- **Cyberware** opens Cyberlab. Freeroam automatically grants everyone
  Athlete double jump and Advanced Combined Dash through Cyberlab, across the city.
- **Animations**, also opened by `/anim`, provides 70 variants in 12 families:
  searchable categories, local favourites, looping/timed actions, **Play & Close**
  and **Stop**. Playback uses `open77_animations` and its server-validated public
  API; no raw clip execution or extra WebUI surface is introduced. Only the default
  clip is verified, on the male body in third person; other clips may not play correctly.
- **PvP** offers free-for-all, 1v1, 2v2 and 3v3, a weapon/kit picker, optional training bots,
  queue status and a leave action. Sandbox mutations are blocked while an activity owns the player.

The page surface remains visible but fully transparent while closed, which avoids the CEF repaint
failure seen when a hidden surface is shown later. The server answers the command with
`freeroam:menu:open`; sandbox button presses return as the `freeroam:menu` net event, are throttled per
player, validated server-side, and executed by an authoritative API. `ESC` closes the menu;
teleport-style actions close it automatically.

UI regression checks (in the Open77 platform repository): `node scripts/freeroam-webui-smoke.mjs` exercises seven sections across six
viewport sizes, keyboard navigation, searches, empty states, activity transitions and action payloads.
`node scripts/race-webui-smoke.mjs` covers the separate Race lounge/HUD/editor on the shared page.

## Race activity

Race is built into this gamemode. `/race`, the **RACE** menu tab and the configurable
world terminal all open the same activity drawer. Queueing leaves the player in the city;
a heat temporarily owns their vehicle, life and routing bucket, then returns them to their
captured Freeroam position. The complete ACL-gated course creator remains available via
`/race.editor` and the editor button. See [Race setup and editor controls](race/README.md).

`/footrace` opens the foot-race catalogue; `/race.editor --foot` starts a draft
without a vehicle. `/goto parkour` reaches the first rooftop course's staging area.
Both disciplines share a single heat engine and keep separate rotations.

## PvP activity

`/pvp` or the **PVP** tab opens the combat activity. `/pvp.join` enters free-for-all;
`/pvp.leave` cancels the queue or leaves the match. Arena queues leave players free to explore
the city until a match forms. Race and PvP reservations are mutually exclusive.

Combat rules run inside `freeroam`; do **not** additionally load `open77_deathmatch` or
`open77_deathmatch_hud` on this server. Those resources remain available for standalone PvP servers.
See [PvP configuration, lifecycle and limitations](pvp/README.md).

## Design-system HUD

Every freeroam-owned surface follows the Open77 Design System source kit: the drawer menu, player/vehicle HUD,
scoreboard, killfeed, hitmarker, and damage vignette. `web/design-system.css` is the production,
offline-safe transcription of those tokens. The reference kit uses public font and icon CDNs;
the game resource deliberately does not. Its four typography roles resolve to installed Windows
fallbacks and the few HUD graphics are CSS geometry, so the UI never needs the network to paint.

A compact bottom-right chat-command hint lists `/freeroam`, `/race`, `/pvp` and `/anim`.
It is non-interactive and disappears while a Freeroam/PvP menu, Race panel/editor,
race, PvP match or PvP queue owns the view, and while dead or waiting for stats.
Hints and activity cards reserve the bottom 96 CSS pixels for the optional
`open-voice` indicator and its transient error; both align to its 32px right inset.
The hint uses the existing offline tokens and respects reduced-motion preferences.

The HUD replacement has a fail-open lifecycle:

1. `web/hud.html` loads and acknowledges `freeroam:hud:ready`.
2. The client obtains a real `Open77.stats` snapshot; page readiness alone is not enough.
3. Only then does the resource claim `health`, `stamina`, `weapon`, and `speedometer` through
   `Open77.hud.setVisible` and hide their vanilla widgets.
4. If either the page or the stats API is unavailable, the vanilla widgets stay visible instead of leaving the player
   without combat information.
5. Stopping or reloading the resource releases every claim.

Health, stamina, armor, active weapon/ammunition, vehicle speed, gear, RPM, and integrity are read
from the public `Open77.stats`, `Open77.weapons`, and `Open77.vehicles` APIs. No value is simulated
in JavaScript. Vitals and weapon/ammunition are anchored at the bottom-left; vehicle speed uses a
compact circular gauge at bottom-center whose 270-degree outline fills against the reported speed.
The multiplayer policy suppresses the vanilla quickslots that normally own the left region. The vanilla minimap,
compass, and clock are intentionally retained: they remain the owner of the native GPS route and
mappin projection and are outside the freeroam redesign.

The browser never supplies an arbitrary weapon template. It sends a short catalog key, and the
server resolves that key through `weapons.catalog` before calling `Open77.weapons`. Weapon
operations are asynchronous: the menu shows the queued result, then receives the authoritative
slot/ammunition snapshot after the client confirms the operation.

Menu mutations are refused when `restrictPlayerCommands = true`, because net events bypass the
ACL enforcement performed by the command dispatcher. Players are told to use the ACL-checked
commands instead.

## Player commands

| Command | Description |
|---|---|
| `/freeroam` | Open the menu UI. |
| `/car [model]` | Spawn a server-owned vehicle near the player. |
| `/dv [all]` | Remove the latest owned vehicle, or every owned vehicle. |
| `/goto <location>` | Move to a configured destination. |
| `/tpc <x> <y> <z> [heading]` | Move to world coordinates. |
| `/locations` | List configured destinations. |
| `/spawn [name]` | Return to a configured spawn point. |
| `/suicide` | Enter the authoritative death flow. |
| `/revive` | Revive in place when dead. |
| `/players` | List known players and their life phase. |
| `/freeroam.status` | Show game-mode diagnostics. |
| `/freeroam.help` | Show available commands. |

Vehicle names can be configured keys such as `hella`, `caliburn`, and `kusanagi`, or full
`Vehicle.*` records when `allowCustomModels` is enabled. See the
[game data reference](https://open2077.net/docs/data-reference).

The shipped `AV` category exposes the flight-capable records supported by the client. Select one
from `/freeroam` exactly like a ground vehicle; it is delivered with extra vertical clearance and
enters the replicated flight controller when the player takes the driver seat.

Weapon templates are player-accessible only through the menu allowlist. The separate ACL-gated
`/weapon.give`, `/weapon.ammo`, and `/weapon.remove` commands remain available to administrators;
see the [Weapon Lua API](https://open2077.net/docs/weapons-api).

## Administrative commands

```text
/noclip [on|off]
/fly [on|off]
/freeroam.tp <playerId> <location>
/freeroam.respawn <playerId> [spawn]
/freeroam.revive <playerId>
/freeroam.cleanup
```

`/noclip`, `/fly` and `/noclip.speed` are provided by **open77_admin**, shipped in
the ready-to-play server. Keep that resource running with `aliases.enabled = true`
to use the short commands. They share the menu's flight state and resource owner;
Freeroam deliberately does not register competing handlers. Their respective
`command.noclip`, `command.fly` and `command.noclip.speed` ACLs remain required.
Namespaced `admin.self.*` commands retain their own ACLs. Native lab mutations
remain unavailable while connected to a multiplayer server.

Administrative commands require `command.freeroam.*`. Set `restrictPlayerCommands = true` to place
player commands behind their corresponding ACL permissions as well.

## PvP

PvP rides on the engine-level damage authority (see the [server Lua API](https://open2077.net/docs/server-api)): the attacker's game computes
hits through the vanilla pipeline, the server validates and owns every health point, and kills are
attributed through the life service. `server/combat.lua` only sets policy:

- `combat.pvpEnabled` turns friendly fire on (the platform default is off).
- `combat.safeZoneRadius` cancels all damage given or received near any configured spawn point,
  through a `Open77.combat.onDamage` arbiter.
- `combat.damageMultiplier` / `combat.headshotMultiplier` scale the server ledger.
- `combat.blastKnockdown` (default `true`) lets grenades, vehicle missiles and car explosions
  knock nearby players down on every screen, through the `open77_weapons` blast relay's
  `setBlastPolicy`: street only (bucket 0), never inside a spawn safe zone or from a thrower
  standing in one, and only while `pvpEnabled`. Other players' cars and network NPCs are moved
  on every screen regardless; `false` keeps vanilla damage only for players.
- `combat.regenPerSecond` grants passive regeneration to every connecting player.
- `combat.killfeed` controls the broadcast rendered by `client/killfeed.lua`: attributed kills show
  `killer ELIM victim`, unattributed deaths show the victim only. The same surface renders the
  server-confirmed hitmarker (`open77:hitConfirmed`, amber on headshot, magenta on kill) and the
  incoming-damage vignette (`open77:localDamaged`).

## Configuration

All game-mode settings live in `shared/config.lua` under `FreeroamConfig`:

- `spawn.points` defines names, labels, positions, and headings.
- `spawn.selection` selects `random`, `nearest`, or `first`.
- `autoRespawn`, `respawnDelayMs`, `health`, and `graceMs` control recovery.
- `teleport.locations` defines `/goto` destinations.
- `vehicles.catalog` controls the searchable garage entries. Each entry has a unique `key`, a
  player-facing `label`, a `category`, and an exact `Vehicle.*` `record`.
- `vehicles.maxPerPlayer` limits server-owned vehicles per player. Once the limit is reached, a
  successful spawn recycles the oldest vehicle. Set it to `0` for no limit.
- `vehicles.allowCustomModels`, `defaultModel`, and `spawnOffset` control custom records and
  delivery. Vehicles otherwise remain until `/dv`, administrative cleanup, or resource removal.
- `weapons.catalog` is the player menu allowlist. Entries use `key`, `label`, `category`, an exact
  `Items.*` `record`, and optional `melee = true` to suppress automatic ammunition.
- `weapons.defaultReserve` is loaded after a firearm is assigned;
  `weapons.maximumReserve` bounds player-entered reserve values.
- `player.allowRestore`, `player.allowGodMode`, and `player.armorOnRestore` control the Player tab.
- `blips` controls destination and spawn markers.

Bundled coordinates are examples validated against Cyberpunk 2077 2.31. Server operators should
replace them with locations appropriate for their game mode.

## WebUI smoke test

From the Open77 platform repository root, `node scripts/freeroam-webui-smoke.mjs` loads the shipped pages in the
installed headless Edge, injects a recording Open77 bridge, renders all four menu tabs plus the
foot HUD, vehicle HUD, scoreboard, and killfeed at 1920×1080, rejects menu overflow, validates
their state/event contracts, and verifies the important action payloads. It writes screenshots to
`artifacts/freeroam-*.png`. This checks every browser surface without starting the game;
authoritative Lua behavior remains covered by `FreeroamIntegrationTests`.

## Runtime behavior

### Teleportation

The current life API performs teleportation through an authoritative kill-and-respawn transaction.
The client applies the complete respawn sequence, including streaming preparation, fade behavior,
and the configured grace period.

### Automatic respawn

The server schedules respawn after a canonical dead-state event and revalidates the state when the
delay expires. Administrative recovery during the delay therefore cancels the pending respawn.

### Vehicle ownership

Vehicles are tracked per authenticated player. When `maxPerPlayer` is positive, successful spawns
recycle the oldest owned vehicle; removal events clean the ownership ledger regardless of which
system removed it.

### Presence

The protected session shell announces `open77:session:gameplayReady` only after the real Night City
world and player puppet are attached. Freeroam applies its forced join spawn from that event;
`freeroam:ready` remains only as compatibility for older clients. Player listings discard sessions
whose names can no longer be resolved by the authoritative server.

See the [ACL guide](https://open2077.net/docs/server-acl) and the repository [license](../../LICENSE).

## Context targeting integration

Freeroam consumes `open77_contextmenu >=1.1.0`, which contains no gameplay actions
itself. ALT-click a network player to copy their ID, or a vehicle to copy its ID
or model. ALT-click your visible F7 body to open Freeroam or the animation menu.
This resource registers those five actions and automatically loses them on stop.
Admin actions are registered separately by `open77_admin` and require its ACL.

The server-only `adminVehicleAction(actor, id, operation, value?, enabled?)` export
accepts only calls from `open77_admin`: `remove`, `repair` (scope), or `flag`
(`locked`, boolean). It rechecks the actual operator's command permission,
resource ownership, bucket, proximity and occupants. It is not a network event
and is not a public client mutation API. Garage cleanup follows `onVehicleRemoved`.

## Server-wide admin tools

PvP uses three times the player's pre-match maximum health (normally 300 HP).
Every PvP respawn starts full, and a credited kill heals to that maximum. The
original maximum is restored on return to Freeroam, including reload recovery;
waiting in a queue does not grant extra health.

Optional server shows use [rp_fireworks](https://github.com/Open2077/open77-resources/tree/main/rp/rp_fireworks)
and [rp_drones](https://github.com/Open2077/open77-resources/tree/main/rp/rp_drones) from the RP pack,
installed as auto-start resources. Admins can use
`/fireworks opening`, `/fireworks stop`, `/droneshow sign`, and `/droneshow stop`.
Drone presets also appear under the admin menu's Effects section. The restricted
commands require `command.fireworks` / `command.droneshow`; do not grant them to
regular players. No show starts automatically when a player joins.

With `open77_admin` loaded, `/admin` → **Server actions** offers confirmed
**TpAll** (ready/alive players gathered in staggered, spaced arrivals) and
**DVAll** (all network vehicles, including those spawned outside Freeroam;
occupants exit first). Commands: `/tpall confirm`, `/dvall confirm`, and
`/admin.bulk.cancel`. See [open77_admin](../../system/open77_admin/) for permissions,
timing configuration and safety limits. These tools are admin-only, not public
Freeroam actions.
