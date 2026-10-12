# Freeroam / Race

Server-authoritative N-player street racing with live course voting, vehicle grids, personal checkpoint zones, live ranking,
GPS/HUD guidance, finish windows, and an ACL-gated in-game course creator.

Race is a submode of `freeroam` (0.6.0+), not a second gamemode. Start `freeroam`;
its manifest loads the Race engine in the same Lua VM, and its menu owns the shared
WebUI surface. The legacy `race` resource is only a dependency alias for old profiles.

## Entering a race

Use `/race`, the **RACE** tab in `/freeroam`, or the world terminal. Menu browsing and
queueing keep the player in Freeroam. Only a starting heat takes its drivers into the
isolated race bucket. Finishing or forfeiting restores the position and bucket captured
when the player left Freeroam. Sandbox teleports and respawns cannot override a driver
or an editor session.

Drivers receive server-authoritative god mode before entering the grid, throughout
loading, countdown, racing, results and dismount. Their previous god-mode setting
is restored on return, disconnect or resource stop. Merely browsing or queueing in
Freeroam does not grant protection. The server reasserts it while Race owns a driver.

Configure the terminal in `race/shared/config.lua`, under `RaceConfig.lobby`:
`center` plus `start.offset` define its world position; `start.radius`, `label`,
`holdSeconds` and `maxDistance` tune its interaction. Set `start.enabled = false`
to use commands and the menu only. `/race` remains available everywhere.

## Checkpoint guidance

Foot racers can use **RETURN TO CHECKPOINT** in the race menu, or **F3** while
running. It returns to the last server-validated checkpoint (the start before
checkpoint 1), including the finish point when beginning another lap. Lap,
progress and elapsed time remain unchanged. The server suppresses checkpoint
crossings until placement settles and rejects repeated pending requests.
In the foot editor the same button/key returns to the last captured checkpoint,
or to the captured start if no checkpoint exists, without editing the draft.
The shortcut can be rebound in Pause → Settings → Key bindings.

Drive beneath the cyan 3D chevron at the GPS point. It floats above the vehicle
and faces the checkpoint's authored driving direction. It advances only when the server accepts the passage, together
with the GPS point and HUD counter. There are no shared solo quest portals or
look-ahead gates competing with the active target. The last target on the last lap
is white and labelled **FINISH LINE**. Ordinary checkpoint, lap and finish cues are
distinct; a lap cue is no longer immediately overwritten by a checkpoint pulse.

The chevron is a native mesh and respects world occlusion. At long range or
behind a building, use the minimap GPS and the top-centre direction arrow. Tune
`visuals.checkpointViewDistance` for its visible range; `visuals.enabled = false`
disables the world marker without disabling guidance or checkpoint authority.
`visuals.checkpointMarker` controls its radius, height and lift above the authored
point; these visual dimensions do not change the server's checkpoint radius.
The editor keeps its radius rings for precise course authoring.
Acceptance checks a bounded swept cylinder between server position samples, so
fast/sloped passages are detected. The default altitude tolerance is 4 m to avoid
accepting another road level; server owners can tune `engine.checkpointZTolerance`.

Each accepted crossing (including lap boundaries and the finish) also fires one
short, visual-only firework above the checkpoint. The server sends it only to
nearby players in the same race bucket, never from a client position or a raw
checkpoint intent. Existing acceptance/debounce rules prevent duplicate rewards.
Tune or disable it with `presentation.checkpointFirework` (`enabled`, `effect`,
`height`, `range`). It does not inflict damage, launch an entire show, or depend
on the optional `rp_fireworks` resource. An effect failure cannot stop progression.

## Creating a course

### Foot races

The **FOOT RACE** tab in `/freeroam`, or `/footrace`, opens the foot-race
catalogue. It shares authoritative timing, checkpoints and results with vehicle
races. Rotations never mix disciplines; the engine runs one heat at a time.
Runners spawn on foot and remain frozen until GO. Entering a vehicle during a
foot race disqualifies that runner.
At GO, runners draw `Items.Preset_Katana_Default` in melee slot 3. Configure or
disable it with `engine.footWeapon`. Overdrive is available on X across Freeroam.
The grid waits for native double-jump and Dash readiness before freezing runners.
Foot checkpoints use a raised native 3D down arrow above a low translucent
cylinder, cyan for the next target and a gold diamond for the final finish.
The editor uses the same checkpoint visuals. The cylinder radius matches the server
acceptance zone; height is only visual and does not change altitude validation.

Choose **COURSE EDITOR** from that tab, or `/race.editor --foot` (same
`command.race.editor` ACL). No editor car is created. F6 captures the start and
facing direction, F8 adds a checkpoint, F9 undoes the last checkpoint,
F5 opens options, F11 saves, and End exits. F7/F10 are unnecessary on foot.
Every queued runner is placed in one line behind the start, two metres apart.
There is no race-specific player cap; the server's connected-player limit still
applies. Leave enough level ground behind the start. The editor previews the
first five positions to show orientation; that preview is not a capacity limit.
In a sprint the last checkpoint is the finish. Courses persist with `vehicle = "on_foot"` in the
existing schema-2 storage; old vehicle courses are unchanged.

Use `/goto parkour` to reach the first rooftop route's staging area:
`{ x = -1023.235901, y = 1492.811035, z = 25.870430 }`.
The included New Night City Foot Race contains the author-tested 44-checkpoint
rooftop route. The editor can load and extend it.

F11 writes a course JSON under `resources/gamemodes/freeroam/data/race/courses/`.
Local courses survive game/server restarts. Include the validated course file in
the release commit (as with the existing vehicle courses), or copy that one JSON
to the production server's same resource data directory before restarting
Freeroam. Do not replace the whole data directory or its operator settings.

Freeroam loads Cyberlab automatically. Every ready, living player receives
Athlete double-jump legs and Advanced Combined Dash, including outside races.
Legs use the normal persistent installation API; arms are retained. Dash is a
session grant, reapplied after lifecycle loss: 3 charges, 450 ms cooldown,
1500 ms charge regeneration. Native speed is fixed, with one air dash per
airtime. `/cyberlab` opens the panel. Defaults are reapplied if removed;
foreign-resource Dash grants are preserved.

Local testing needs a MariaDB connection through `OP77_DATABASE_CONNECTION`;
cyberware requires the database. Use a private loopback development server.
Clients need the matching `Open77CyberwareLegs.reds` update: older adapters
mistake the grid's temporary movement restriction for a lost double-jump grant.

Grant the operator `command.race.editor` (or `command.race.*`) in `acl.jsonc`, then run:

```text
/race.editor
/race.editor <existing-course-id>
```

The command opens drive mode from Freeroam, keeps the administrator at their current Night City
position, spawns a disposable editor car, and enables a compact non-interactive drive HUD. The
normal game controls remain active. Enter the car, drive the route, and use the mapped actions:

| Default | Editor action |
|---|---|
| `F4` | Respawn the selected editor car in front of the administrator. |
| `F5` | Open the focused metadata/catalogue panel and choose the race vehicle. `Escape` closes only that panel. |
| `F6` | Capture or replace the start/finish reference. |
| `F7` | Add the current pose as an exact vehicle grid slot. |
| `F8` | Add the current pose as the next checkpoint. |
| `F9` / `F10` | Undo the last checkpoint / grid slot. |
| `F11` | Save the current course atomically. |
| `End` | Leave drive mode, remove its car, and return to the captured Freeroam position. |

All actions are registered through `RegisterKeyMapping`. Their effective bindings are shown in the
HUD and can be changed under **Pause → Settings → KEY BINDINGS**. The focused panel is only needed
to edit the course name, description, format, laps, radius and race vehicle, or to load/select/delete catalogue
entries. For each capture, orient the car—or the camera while on foot—in the intended driving
direction:

1. Capture the start/finish reference.
2. Add one exact vehicle grid slot per supported racer. The server rejects slots closer than
   `editor.minimumGridSpacing`, so authored vehicles cannot spawn on top of each other.
3. Drive or move along the route and add checkpoints in crossing order.
4. Open options, choose circuit/sprint, laps, gate radius, name, description and the allow-listed
   race vehicle. `F4` replaces the disposable editor car so the selection can be previewed.
5. Close the panel, then save from drive mode.

Positions always come from server authority: from the canonical editor-car transform while its
driver seat is occupied, otherwise from `Open77.players.position`. The WebUI supplies no position;
the client bridge supplies only vehicle/body heading, so a browser payload cannot forge coordinates.
Every editor network action is ignored
unless `/race.editor` previously created a live ACL-authorized session for that player.

Courses are stored atomically as one JSON document each:

```text
resources/gamemodes/freeroam/data/race/courses/<course-id>.json
resources/gamemodes/freeroam/data/race/race-settings.json
```

Course files use schema version 2 and contain `vehicle`, `start`, ordered `grid`, ordered
`checkpoints`, author metadata, and revision. `vehicle` is a stable ID resolved exclusively through
`engine.vehicles`; a JSON or browser payload cannot inject an arbitrary TweakDB record. Existing
schema-1 courses are upgraded atomically on load and receive the configured default vehicle. Files
are loaded and validated when the resource starts or reloads. Invalid JSON, unsupported schemas,
overlapping grid slots, unsafe IDs, unknown vehicle IDs, or out-of-range coordinates are logged and
skipped rather than partially entering the live catalogue.

The gamemode ships no built-in or sample circuit. Only editor-created or deliberately installed JSON
files enter the live catalogue and random rotation. Every vehicle route requires an explicitly captured grid;
its number of saved grid slots is that heat's capacity. There is no fixed racer cap
or grid-editor slot ceiling. The FIFO queue accepts every eligible connected player;
only the first N ready drivers enter a course with N surveyed slots. Overflow keeps
its queue position for subsequent heats, including when an admin selects a smaller
course during the join window. The next course's capacity is independent of the
currently running heat. The menu shows waiting players, the next grid size and
whether your queue position fits. The server's own connection limit still applies.

## Commands and ACL

### Live lobby and course voting

The Race lounge shows the live FIFO queue and the current heat's drivers, including
boarding readiness. Course cards display the actual checkpoint route, route length,
vehicle and authored grid size. Timers are server-authored and interpolated locally;
the client never decides when vehicles unlock.

`engine.voting` defaults to `{ enabled = true, candidateCount = 3, revealSeconds = 4,
cooldownMs = 250 }`. The first queued driver opens a ballot with up to three different
installed courses (a smaller catalogue shows all of them). Only ready, queued players
can vote, once per player, and can change their vote until the join window closes.
Leaving/disconnecting removes that player's vote. Votes for an old ballot, unknown
course or after the deadline are ignored; rapid changes are rate-limited.

The most-voted course wins. Ties are drawn randomly among the tied courses; with no
votes, a candidate is drawn at random. The winning route is revealed for four seconds
before automatic grid placement. Overflow retains FIFO priority and gets a fresh
ballot for the next heat. Voting can run during the current heat, with its deadline
starting after the current heat is cleaned up. An explicit admin course selection
overrides voting for one heat; `/race.force` resolves current votes immediately.
Set `engine.voting.enabled = false` to retain the previous random rotation.

Validation: `scripts/race-webui-smoke.mjs` covers responsive lounge layouts, vote
intents, locked ballots and stable focus across live refreshes. `RaceIntegrationTests`
covers admission, changing votes, removal, invalid intents, ties, no votes, winner
reveal, overflow and admin override alongside the grid/vehicle lifecycle tests.

The browser-only collections (`rows`, `roster`, `courses`) travel as JSON strings;
route previews use compact `x,y` polylines. This keeps the payload within the client's
1024-node Lua-event decoding budget even with large grids. The WebUI decodes these
collections and retains card/row DOM nodes between timer updates. Large envelopes
use the platform's chunked client-event transport.

Periodic and dirty state flushes suppress byte-identical ordinary payloads per
recipient. Explicit ready, request-state and menu-open responses always send a
baseline. The cache is bounded to 512 recipients and 8 MiB and records only
successful event admission; failed admission remains retryable. Large latent
states bypass deduplication, and a recipient's ordinary state remains uncached
until its earlier latent streams finish. Checkpoint, lap, GO, finish and course
lifecycle events retain their existing delivery.

Live ranking rows rebuild only when their displayed projection changes. The
full classification board defers DOM construction while hidden and renders the
latest rows on reveal. Timers, countdown and checkpoint guidance continue at
their normal client cadence. These changes reduce repeated idle network/UI work;
they do not establish a particular multiplayer capacity or native frame rate.

`race/tests/state_delivery_test.lua` covers admission, forced refresh, retry,
recipient isolation, bounds, disconnect/reset and latent completion. It is also
registered by `RaceStateDeliveryLuaTests`; its integration fixture checks real
resource idle-state suppression and polled eligibility changes. The Freeroam
headless WebUI smoke includes a 128-row, 200-frame timer/guidance regression.

Local acceptance, 2026-09-21: two real clients joined, appeared in both rosters,
cast votes through the WebUI, and entered the winning course together. Both driver
seats were confirmed before countdown and GO. Responsive browser checks cover
640, 1280, 1920, 2560 and 3440 px widths, including always-visible queue controls.

### Command reference

| Command | ACL | Purpose |
|---|---|---|
| `/race` | public | Open Freeroam's Race activity menu. |
| `/race.join`, `/race.leave`, `/race.status` | public | Queue, leave, or inspect current state. |
| `/race.course.list` | public | List available courses and formats. |
| `/race.course.select <id>` | `command.race.course.select` | Select a one-heat override. |
| `/race.force` | `command.race.force` | Start with the current queue. |
| `/race.editor [id]` | `command.race.editor` | Open the course creator. |
| `/race.where [player]` | public diagnostic | Print server position/checkpoint state. |
| `/race.probe <x> <y> <z> [heading]` | `command.race.probe` | Validate a surveyed point in game. |

The recommended `operator` ACL role already grants `command.race.*`. The resource manifest grants
`filesystem.read` and `filesystem.write` only to its own `data/` directory through `Open77.io`;
that resource capability is separate from the player-facing command ACL.

## Layout

```text
freeroam/open77.lua               manifest, dependencies, server capabilities
freeroam/race/shared/config.lua   engine/editor/presentation limits and world terminal
freeroam/race/server/courses.lua  JSON catalogue, validation, selection, revisions
freeroam/race/server/main.lua     queue, grids, vehicles, checkpoints, ACL editor sessions
freeroam/race/client/main.lua     projection, control locks, mapped drive-editor actions
freeroam/web/index.html          shared Freeroam / Race page
freeroam/web/race/               activity presentation and design-system theme
freeroam/data/race/courses/      runtime-created custom JSON courses
```

## Authority rules

- Player and vehicle placement uses the server life/vehicle APIs; the WebUI never supplies a world
  position.
- Forming a grid reserves each authoritative driver seat with
  `Open77.vehicles.warpPlayerIntoVehicle(..., { moveBucket = true, exitLocked = true })`. The
  assignment itself keeps an arbitrarily distant vehicle in that player's interest set, so racers
  are streamed and mounted automatically instead of being placed beside a car and asked to press
  `F`. The countdown starts only after the client confirms the native workspot mount and clears the
  durable `ForcedEntry` flag.
- `engine.gridLoadSeconds` is a minimum loading window, set to 20 seconds locally. Early seat
  confirmations do not shorten it; after it expires, the `3, 2, 1, GO!` sequence begins as soon as
  every remaining driver is ready. `engine.gridReadySeconds` remains the longer failure timeout for
  a client that never completes its mount.
- Race cars are created on their surveyed mark with the server-authored `frozen`
  flag. The hold survives streaming, mounts, ownership changes and
  UI reloads; the server rejects owner motion reports while frozen. A 500 ms guard
  verifies/reasserts the hold through loading and countdown. Ignition and throttle
  remain live, so holding acceleration across GO works without another key press.
  GO removes the freeze before announcing the start. A missing vehicle or failed
  hold/release disqualifies that driver instead of silently allowing a false start.
  Client Lua only renders the countdown; it never thaws a server-held car.
- The exit lock stays authoritative through grid, countdown, active racing and results. Forfeit and
  heat cleanup use `forcePlayerOutOfVehicle`, keep the car alive for the native dismount window,
  then remove it and return the player to Freeroam. The editor car remains intentionally unlocked.
- Checkpoint zones are presentation hints. The server re-evaluates every crossing from the latest
  authenticated player position, bucket, vertical tolerance, radius, and bounded movement segment.
- A client cannot open an editor by emitting `race:editorAction`: only the restricted command can
  create the expiring server-side editor session.
- Drive mode runs in world bucket `0`, suppresses the lobby POI, and owns one disposable
  server-created car. Exiting or expiring the session removes it before returning the player to the
  captured Freeroam position and bucket.
- Vehicle controls remain natively locked through the `3, 2, 1` sequence and release on `GO!`.
- Course files never enter the downloaded client package and do not trigger a resource hot reload;
  the catalogue owns them as server data.

See [writing a gamemode](../../../../docs/writing-a-gamemode.md),
[server resource IO](../../../../wiki/server-api.md#resource-local-file-io), and the
[Race runtime research](../../../../docs/research/race-checkpoints-and-ui.md).
