# pursuit

Pursuit gives your server a cops-and-runners 1v1 in Night City: players queue in a lobby, get paired into a private match, and one plays the cop while the other tries to break away. This resource holds the server rules, the lobby, the match cars and roadblocks, and a ranked Elo ladder; the HUD is [pursuit_hud](../pursuit_hud/).

- **Docs:** [Writing a gamemode](https://open2077.net/docs/writing-a-gamemode)
- **Starts:** on its own
- **Needs:** `open77_worldui`, `open77_zones`, `open77_notifications`
- **Runs on:** server and client

## Use it

Pick the Pursuit template in the server setup wizard, or load `pursuit` and [pursuit_hud](../pursuit_hud/) together with the resources they need. Enable and disable the two together, and run no other gamemode beside them: [freeroam](../freeroam/) also owns spawn and death.

Players spawn in the lobby, step into the ready-up circle and hold **E** to queue. Each match runs in its own routing bucket, so two pairs never see each other. Server owners tune the rules live from Warden's Tuning tab (the tunables are declared in `shared/config.lua`) or with commands such as `pursuit.mode [foot|vehicle]`. Ratings persist only when the server's database is enabled; see [Ranked](#ranked).

`open77_groundcircle` and `open77_vehiclepicker` are optional. With the first, the lobby rings are drawn on the ground; with the second, players can choose their car for each role.

## Layout

```text
open77.lua              manifest -- script order here is load order, and the match files depend on it
shared/config.lua       every tuning number, and nothing else
server/main.lua         roster, guarded state machine, the placeAt primitive, the lobby leash
server/match.lua        one round: roles, spawns, clocks, win conditions, resolution
server/vehicles.lua     the two match cars
server/scanner.lua      the scanner ping
server/bounds.lua       arena bounds
server/roadblock.lua    the cop's roadblock
server/ranked.lua       the persistent Elo ladder
client/main.lua         lobby POIs, the stale scanner blip, the runner's scan pulse
```

The HUD is a **separate resource**, [pursuit_hud](../pursuit_hud/), because a WebUI
surface must declare `reload_policy "reconnect"` and this one must stay
`"local"` so a tuning change reloads in seconds.

## Why one server resource with seven files

The server runtime installs no `exports`, no `GetInvokingResource` and no
cross-resource event bus, so a second server resource could not be asked for
anything. Files inside one resource share a Lua state instead, and reach each
other through the `Pursuit` global that `server/main.lua` creates and
`server/match.lua` extends.

`server/match.lua` publishes the seam the vehicle, scanner, bounds and roadblock
files register against:

```lua
Pursuit.onMatch("countdown", function(match) ... end)  -- players are on their marks
Pursuit.onMatch("active",    function(match) ... end)  -- the clock started
Pursuit.onMatch("tick",      function(match, now) ... end)  -- 5 Hz, after separation
Pursuit.onMatch("resolved",  function(match) ... end)  -- entities die here
```

Those are **direct calls**, not `TriggerEvent`. `TriggerEvent` on this runtime
schedules the handler as a coroutine, so it is asynchronous: fine for
"something happened" fan-out (`pursuit:matchStarted`, `pursuit:matchResolved`,
which are also emitted), and useless for a hook that must have written the
tick's HUD payload or ended the match on the tick that decided it.

## Modes

`Config.match.mode` selects the distance column for **new** matches: `foot`
or `vehicle` (the default). A match captures its mode at
creation, so `pursuit.mode` never moves the finish line under two people already
playing.

| | Foot | Vehicle |
|---|---|---|
| escape | 100 m: meter, fill 18 s / drain 6 s | 100 m: meter, fill 18 s / drain 6 s, armed 15 s after release |
| bust | 8 m: meter, fill 3 s / drain 5 s | 15 m: meter, fill 5 s / drain 8 s |
| head start | 5 s | **none** |
| duration | 3 min per round | 3 min per round |
| rounds | best of 2, roles swapped | best of 2, roles swapped |

Four rules shape every match, and each is argued in full in `shared/config.lua`:

* **The bust is a METER, not a hold timer.** It fills inside `bustDistance` and
  drains more slowly outside it, so a tail survives a corner. A rule of "within
  5 m for N *consecutive* seconds" could not be satisfied by anyone chasing a
  car that never stopped: the radius was shorter than the vehicle, and any break
  threw the whole hold away. The meter is on the HUD for **both** players.
* **The escape is a WINDOW at 100 m.** Crossing `escapeDistance` starts an
  escape meter that fills over `escapeGraceSeconds` (18 s) and wins the round
  for the runner when it fills; the cop cancels the attempt by pulling the gap
  back under the line, which drains it over `escapeDrainSeconds` (6 s, much
  faster than the fill, so the comeback pays at once and flapping on the line
  loses ground). Vehicle matches have no head start: `escapeArmSeconds`
  protects the opening, when nobody is in a car yet.
* **The clock is the cop's.** A round timer that expires with no completed
  escape hands the round to the COP: surviving the hunt is not an escape, the
  runner must actually shake him.
  The `timeoutWinner` tunable restores the survival rule; either way an
  attempt underway at the buzzer (escape meter filling, arrest closing) plays
  out as sudden-death overtime instead of being cut.
* **Arena bounds are OFF** (`Config.arena.enabled`). The whole map is in play.

Live separation in metres is sent to the **runner only** -- see `separationFor`
in `server/match.lua`. A cop with a live distance readout can trilaterate by
feel, which deletes the stale-scanner mechanic; his readout is the meter, which
says whether he is succeeding rather than how far away something is.

## The one thing that surprises everyone

**The server cannot put a player in a car.** The occupancy ledger is written by
native mount detection; `warpPlayerIntoVehicle` is a client function that only
moves remote proxies. So a vehicle match spawns each player's car beside his
spawn mark, tells him, watches the ledger and confirms when he is aboard. See
the header of `server/vehicles.lua`.

## Commands

They are all server commands. Some only work when issued in game.

| Command | What it answers |
|---|---|
| `pursuit.status` | roster and queue |
| `pursuit.match` | every live match: state, mode, cars, ping age, bounds, roadblock charge |
| `pursuit.mode [foot\|vehicle]` | read or set the mode new matches get |
| `pursuit.where [id]` | what the server sees for one player, and why containment said no |
| `pursuit.slots` | the lobby spawn-slot ledger: who holds which slot, at what offset |
| `pursuit.bounds [id]` | the same question, for the arena (reports OFF -- bounds are disabled) |
| `pursuit.unstick` | run by a player wedged in geometry at spawn: puts him back on his own mark. Opening seconds of a round only, once per round. |
| `pursuit.cars [replant]` | vehicle ids, occupants, positions; optionally re-plant them |
| `pursuit.vehicle [runner\|cop\|show]` | open the vehicle picker for one role, or show your current picks (in game; needs `open77_vehiclepicker`) |
| `pursuit.ping [matchId]` | force a scanner sweep now |
| `pursuit.roadblock` | the cop spends his banked charge (in-game, cop only) |
| `pursuit.forceroadblock [matchId]` | deploy without spending or waiting |
| `pursuit.rank [id\|top\|roles\|config]` | a player's rating, the ladder, the cop/runner tally, the live tuning |
| `pursuit.force <id> <id>` | start a match without the queue |
| `pursuit.release` | end the head start now |
| `pursuit.queue` / `pursuit.lobby` / `pursuit.tp` / `pursuit.tpcircle` | movement and queue |
| `pursuit.hudtrace [s]` | narrate the HUD push contract |
| `pursuit.lifetrace` / `pursuit.life` | check that the placement kill tag survives |
| `pursuit.probe` / `pursuit.survey` | author and verify a spawn mark |
| `pursuit.markers` / `pursuit.projtest` | client-side marker and projection diagnostics |

## Ranked

`server/ranked.lua` keeps a persistent per-player rating. The maths is **Elo**,
not a win counter, and the file opens with the argument for why:

* the change is proportional to the **expectation**, so beating a much stronger
  player pays nearly the full K and farming a weak one pays almost nothing;
* a **1-1 draw** is a real result, `S = 0.5`: a gain against a stronger
  opponent, a loss against a weaker one;
* K is **40 for a player's first ten rated matches**, then 20, so a newcomer
  converges in an evening instead of grinding. That is the one property Glicko
  would otherwise be needed for, bought for one integer of state.

A **match** is rated, never a round. Because `roundsPerMatch` is 2 and the roles
swap, both players take each side exactly once, so any cop/runner imbalance
cancels inside the match and cannot leak into the ladder. The exception is
`tieBreak = "decider"`, whose third round hands one player an extra turn as the
cop, which is why `pursuit_ranked_rounds` records the roles of every round:

```sql
SELECT mode, winner_role, COUNT(*) FROM pursuit_ranked_rounds
 GROUP BY mode, winner_role;
```

An **abandonment is rated exactly as a loss**. The leaver does not escape it
(`finishMatch` already awards the match to whoever stayed, whatever the
scoreline), and a crash is not punished beyond it: a rage-quit, a crash and an
ISP blip reach the gamemode as the same event with no reason attached, so the
server cannot honestly tell them apart. `abandonPenaltyScale` is clamped at 1.0
from below in code, so a leaver can never lose *less* by leaving.

Every dial is in `Config.ranked`, read fresh at the start of each match and
clamped, so a live config editor can turn them without a reload.

### Turning persistence on

Ratings persist through the `database.access` bridge, keyed by
`GetPlayerIdentifier()`. **There is no file-backed alternative**: the server Lua
sandbox nils out `io` and `os`, so a resource cannot write a file at all.

With `database.enabled: false` in the server configuration, the mode runs a
**volatile, in-memory ladder** that says so on every surface: the start-up log
line, every `pursuit.rank` output, and the notification after each match. To
make it real:

1. export `OP77_DATABASE_CONNECTION` in the server's environment (never in the
   config file, never in the repo: it is a credential);
2. set `database.enabled` to `true` in your `server.jsonc`;
3. restart the server. `ranked.lua` creates its three tables itself on the first
   match; there is no migration to run.

**Do step 2 only together with step 1.** An enabled database with no connection
string fails configuration validation and the server refuses to start.

## House rules

- Move players **only** through `Pursuit.placeAt`: kill then respawn, never a
  raw transform write. Every placement is therefore a death, and the death guard
  rejects kills tagged `weapon = "pursuit:*"`.
- The server spells life phases `respawnpending` / `revivepending`; the client
  uses snake_case. Accept both.
- Never decide on one position sample. Every rule is "held continuously for N
  seconds" at `Config.tickHz`, and an unreadable position **freezes** the
  accumulator rather than resetting it.
- Every tuning number lives in `shared/config.lua`. Nothing inline.
- List scripts explicitly in the manifest. `client/**/*.lua` matches nothing
  against a flat `client/main.lua` and the client then refuses the whole
  resource set.

See [Writing a gamemode](https://open2077.net/docs/writing-a-gamemode), the
[server Lua API](https://open2077.net/docs/server-api) and
[Network vehicles](https://open2077.net/docs/vehicles).
