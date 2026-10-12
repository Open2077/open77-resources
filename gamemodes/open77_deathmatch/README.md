# open77_deathmatch

Kabuki Arena gives your server player-versus-player combat in Kabuki Market: a drop-in free-for-all you walk into from a station in the world, plus queued 1v1, 2v2 and 3v3 arena rounds on the same map. Bots can complete a roster so a match never waits on a population, and they are always labelled.

- **Docs:** [Deathmatch — running the Kabuki Arena PvP mode](https://open2077.net/docs/deathmatch)
- **Starts:** on its own
- **Needs:** `open77_weapons`, `open77_worldui`, `open77_interactions`, `open77_groundcircle`, `open77_zones`
- **Runs on:** server and client

## Use it

Make Kabuki Arena the only gamemode in the server's resource set: list
`open77_deathmatch`, its HUD [`open77_deathmatch_hud`](../open77_deathmatch_hud/)
and the five resources above in `resources.load`, and leave `freeroam` out. The
mode starts on its own. Players walk to the lobby station and hold **E** to fight,
or type `/dm` for the panel; `/deathmatch.leave` leaves. Admins tune capacity,
round length, kill limit and bots from the Warden **Tuning** tab, and edit the map
in the world with `/dm.map`.

Everything a player can see is **English**. Every notice and label this resource
produces comes from one table in `shared/config.lua`; the HUD keeps its own
table for the same reason in `open77_deathmatch_hud/shared/strings.lua`. So the
next language is one edit per resource rather than a search across Lua, HTML and
JavaScript, and the server sends a *kind*, never a display string, which is
what keeps language out of authoritative code.

## The two products

One resource, two match lifecycles. Conflating them is what made the first
version feel like neither.

**Free-for-all is a place.** It is always running. You walk in, you are alive
and armed within a second, and you leave when you want. It never asks you to
wait, because the round in progress is one you can join.

**Arena is a match.** 1v1, 2v2 and 3v3 cannot be dropped into (teams must be
balanced and rounds must be symmetric), so these genuinely queue. That queue is
the only place in the whole mode where a player waits.

| | Free-for-all | Arena (1v1 · 2v2 · 3v3) |
|---|---|---|
| Entry | Instant. Placed into a live instance on join. | Queued per size; matched when the roster fills. |
| Instance | Persistent, auto-scaled, capacity-capped at 12. | Allocated per match, released on result. |
| Death | Respawn after a delay, same round. | Eliminated for the round; spectate your team. |
| Round end | Kill limit or timer, then standings, then the next round. | Team wiped or timer; round point, sides swapped. |
| Match end | Never. The instance outlives every round. | First to *N* round wins, then back to the lobby. |
| Loadout | Slot 1 rotates and is the same weapon for everyone; slots 2 and 3 are a fixed sidearm and melee. | Kit picked in the buy window; both sides get the same list. |
| Teams | None. | `setTeam` per side; friendly fire cancelled by the platform. |

The equalizer (one rotating weapon for everyone) is the mode's clearest idea
and what keeps free-for-all fights readable. It rotates round-robin rather than
randomly, so consecutive rounds never repeat a weapon, and the reserve is
restored at respawn and at round rollover, so a player who survives a long round
does not run dry. Ammunition is set as a **reserve only**, and that is
load-bearing rather than incidental: `Open77.weapons.setAmmo` fails *as a whole*
if `magazine` exceeds the weapon's capacity, so a Lexington given
`{ reserve = 300, magazine = 60 }` ends on `000 0000` while `{ reserve = 300 }`
produces `000 0300` immediately.

**FFA never queues.** The only refusal it can produce is `instances_full`, and
that is a server-capacity message, not matchmaking. Joiners **fill before they
spread**: a player lands in the fullest instance that still has room, and a new
instance opens only when none does, because a 2-of-12 instance is a dead lobby.

## Getting in

The way in is a station in the lobby, not a command.

| Station | Key | Effect |
|---|---|---|
| **ENTER THE ARENA**: 2.0 m ring, `objective` cyan | **hold E** | Placed into a live FFA instance immediately. No queue, no countdown. |
| **ARENA QUEUE**: 1.6 m ring, `spawn` green | **press E** | Opens the 1v1 / 2v2 / 3v3 panel and queues you for the size you pick. |
| **Leave** | HUD key or `/deathmatch.leave` | You cannot walk back to the lobby from inside an instance, so leaving is never a world prompt. |

Hold for a commitment, press for something reversible. Both cards carry live
numbers (instances up, how full the one you would land in is, how many are
queued per arena size), because a station that cannot tell you whether anyone
is playing is a sign rather than an invitation.

Four platform resources make that station work, and all four are load-bearing:

| Resource | Why it is in the set |
|---|---|
| `open77_worldui` | The POI itself: ring, prompt card, action key, owned handle. |
| `open77_interactions` | `open77_worldui` declares it as a dependency. Leave it out and the server does not fail: it logs `Resource 'open77_interactions' was not found` once a second, forever. |
| `open77_groundcircle` | On 2.31 the native 3D interaction ring **does not draw at all**. This is what the player actually sees; it follows real ground per vertex. |
| `open77_zones` | Client-side enter/exit hysteresis for the lobby and the arena boundary. Every claim it makes is re-derived on the server. |

`freeroam` must never share the set: its `autoRespawn` answers every
`kill → respawn` placement this mode issues.

## The map and the wall

The arena is one surveyed footprint with zones carved out of it: the full
Kabuki Market for FFA and 3v3, the market and lower level for 2v2, the lower
level alone for a 1v1 duel. Bounds are an ordered list of axis-aligned boxes,
not a cylinder: a gallery six metres above a sunken floor makes a cylinder
either clip the bridge off or swallow the street outside.

**The wall is a client-side clamp, and it is not made of props.** Props *are*
solid, but `visible = false` is accepted and the prop renders anyway, so no
arrangement of props can produce an *invisible* wall. The client projects a
player who leaves every volume back to the nearest inside point plus a small
inset; the server keeps its leash as a **backstop**, because a clamp that can be
disabled is not authority. Props may still be used to *draw* the boundary, never
to enforce it, and only on a server whose set includes `open77_props`, since a
server-created prop is projected onto clients by that resource's client half and
by nothing else.

Spawn marks are captured by walking, never derived. Nearby XY does not imply
nearby walkable ground.

### Maps are runtime data, and `/dm.map` edits them by walking

`shared/kabuki.lua` is the **built-in default**, not the only map.
`server/mapstore.lua` snapshots it at load under the name `kabuki` (never
written to, never deleted, always restorable) and holds any number of other
named maps that are created, copied, edited and validated **live**, in the
world, with no file edit and no reload. `/dm.map mark ffa` where you stand and
the very next spawn can use it.

**The server still plays exactly one map at a time.** Which one is the
`activeMap` tunable. The four zones are still carved out of one map, and there
is still exactly one containment test in the resource.

**Nothing is written under `resources/`, and that is the point.** A server with
hot reload watches this tree at 1 Hz and any write hot-swaps the whole resource
set: every bot despawns, every player drops out of their instance. So:

| What | Where | Survives a reload | Survives a restart |
|---|---|---|---|
| Which map is selected | `activeMap` tunable → `server/tunables.json` | yes | yes, **with no database** |
| The geometry | `Open77.database` (`open77_dm_maps`) | yes | yes, when the bridge is on |
| The geometry, meanwhile | the host's carried-state bag | yes | no, by design |

`Open77.tunables` cannot hold the geometry: a tunable string is capped at 256
characters and its keys are declared at load. `Open77.database` is the only
durable store server Lua has (the sandbox nils `io` and `os`, so a resource
cannot open a file at all), and the database bridge is only on when the server
configures one. **When it is off the store is memory only, every readout says so
in capitals, and `/dm.map export` prints the map as pasteable Lua** so a finished
map is promoted into `shared/kabuki.lua` and becomes a built-in under source
control.

The honesty rules above are inherited rather than reimplemented, because the
store writes the same tables every consumer already reads. A zone naming a
volume with no box has containment **SUSPENDED**, not emptied; a format whose
team cluster is short still refuses to start; and `Kabuki.surveyed` is
recomputed on every apply instead of asserted. `/dm.map check` says which of
those is currently true, and why.

## Bots

Bots exist so an arena format can start without enough real players for both
sides.

They **fight with the engine's own combat AI**. A bot draws, aims and fires a
real weapon, and the engine handles its targeting, line of sight and movement.
The client that owns the body reports each hit: the shooter's client for player
fire on a bot, the victim's client for bot fire on a player. That is
duplicate-free for any number of players. Different players may see the same
bot standing in slightly different places, but health never diverges, because the
server ledger is the only thing that writes a health number.

- **Bot → player damage carries attribution.** The NPC id survives into
  `open77:playerDamaged` as the attacker, so the kill feed can name the bot and
  the damage indicator has a real source.
- **The server ledger wins.** A bot's health is a percentage scale on the server
  and is projected onto the engine body as a fraction, so the three gang
  templates need no rebalancing against each other.

Two rules are not negotiable. **Bots are labelled**, on the scoreboard and in
the kill feed: a player who cannot tell whether they just lost a duel to a
person has been cheated of the only thing the mode sells. And **bots never write
to the ladder**: a round containing one is scored, shown, and then not
persisted.

**Three** gang aliases are allowlisted for this mode:
`hostile_female_ranged_lab` (Maelstrom), `gang_valentinos_ranged_01` and
`gang_tygerclaws_ranged_01`. Bots are round-robined across them, so a roster of
six is two of each. Three *mutually hostile* gangs is the point, not the
variety: one faction is one side, and one side does not fight, so the engine's
own attitude matrix needs rivals to resolve.

`civilian_female_relaxed_01` is still in the platform registry and is
**excluded from this mode, permanently**. It resolves to `Character.Panam`, which
carries the TweakDB tag `Invulnerable` (vanilla quest protection that no
attitude change, damage policy or Lua call can lift), so a bot built on it can
never be shot.

More NPC records need to be reviewed into the server-owned registry before bots
stop looking alike. That is a platform step, not a Lua change.

## Commands

Player commands:

| Command | Effect |
|---|---|
| `/dm` | Opens the interactive panel. |
| `/deathmatch.join` | Registers for the next match. |
| `/deathmatch.leave` | Leaves the queue, the instance or the match. |
| `/deathmatch.status` | Prints the authoritative phase and population. |

Map, arena, bot, loadout and stats commands:

| Command | Gate | Effect |
|---|---|---|
| `/dm.where [format]` | open, **self-only** | What the server sees for you: position, bucket, readiness, life, containing volume, verdict and reason. An id argument would let anyone read anyone's position, so a player gets themselves and the console (which has no position of its own) must pass an id. |
| `/dm.map <verb>` | ACL | **The live map editor.** `list` · `show` · `new` · `copy` · `select` · `rename` · `label` · `delete` · `edit on\|off` · `mark` · `marks` · `move` · `remove` · `station` · `box` · `unbox` · `volume` · `zone` · `check` · `export` · `store` · `save` · `reload`. Every verb applies **immediately** (a mark captured now is a candidate for the next spawn) and nothing writes a file under `resources/`, so nothing reloads. Coordinates always come from `Open77.players.position`; a command carries a set name, a volume id and at most a heading, never a place. `dm.map help` prints the list in game. |
| `/dm.survey start\|mark\|box\|list\|dump\|commit\|clear` | ACL | The draft-and-dump surveyor, kept because `dump` is still the promote-to-built-in path. Every coordinate comes from `Open77.players.position`, never from a browser payload. **`commit` pushes a walked draft straight into the live map**, which is the fast path; `dump` prints pasteable Lua for `shared/kabuki.lua`, which is the durable one. This file also owns the single 4 Hz heading reporter that both it and `/dm.map` read. |
| `/dm.queue <1v1\|2v2\|3v3> [bots]` · `leave` · `status` | open, **self-only** | Enter an arena queue without touching the HUD. `bots` completes the roster with bots so the format starts now: explicit consent, honoured whatever `arenaFillWithBots` says, exactly as `/dm.bot fill` is honoured whatever `fillWithBots` says. Bots are labelled on the roster and a match containing one never reaches the ladder. It is the only arena entry point that is not a HUD surface; `/dm.arena` takes no verb and only prints. The console has nobody of its own to queue and may pass `player=<id>`. |
| `/dm.arena` | open | Queue depths, and every running match: round, phase, score, survivors, bot count, both rosters with the bot label on, and whether the match will reach the ladder. |
| `/dm.bot add [n]` · `fill` · `clear` · `list` | ACL | Bot population inside your instance. `list` reports each bot's participant id, callsign, profile, instance, health, state and template. Bots are labelled everywhere they appear and a round containing one is never written to the ladder. |
| `/guns [kit]` | open | The weapon picker. Bare, it opens the panel; `/guns sniper` picks outright, so the feature is testable without the UI. The pick is kept for the session and applies **on the next respawn** unless the player is in the lobby, between rounds or inside spawn protection, where it applies at once. Only meaningful while `loadoutMode` is `choice`; under `equalizer` the pick is recorded and the equalizer still rules. |
| `/dm.loadout [id]` | open | What the server believes a player is holding: the issued plan slot by slot, which slots verified, the arbiter's id, and the `/guns` mode / chosen / carrying / pending line. |
| `/dm.stats` | open, **self-only** | Your career, across sessions and across server restarts: rounds, wins, kills, deaths, K/D, assists, headshots, multi-kills, best streak, score and damage, as one total and then broken out **per format**, because a 1v1 K/D says nothing about a twelve-player free-for-all. Each format's line also carries its **ELO**, marked `*` while the player is still inside the placement window and `?` for a format with no rated round behind it, and the card names the baseline and both K factors rather than printing a number nobody can interpret. There is deliberately no overall rating: an arena rating and a free-for-all rating are not even produced by the same model, so an average of the two would have no definition at all. Every readout names the store that answered it, so a volatile run is never mistaken for a persistent one. The console has no career of its own and may pass an id. |
| `/dm.rating.sim <mode> <r1> <r2> ...` | ACL | What the rating model would do to a synthetic field, best finisher first, **without touching a stored row**. A two-sided format splits the list in half and side 1 wins. It exists for the same reason `/dm.arena.mock` does: otherwise the only way to see what a K change does is to play a round and then read a table. |
| `/dm.stats.of <id>` | ACL | The same card for somebody else. It is a separate command rather than an argument to the one above because `RegisterCommand`'s restriction is per **command**, not per invocation: there is no binding that lets an open handler ask whether its caller is privileged, so one command taking an id would either expose every card to everybody or hide every card from its owner. Same pairing as `/dm.where` ↔ `/dm.survey` and `/dm.arena` ↔ `/dm.arena.mock`. |

## Tuning

Numbers an owner may want to change tonight are declared in
`shared/config.lua` and rendered by the Warden **Tuning** tab: capacity,
instance ceiling, round length, kill limit, spawn protection, best-of and
`fillWithBots` (default **off** in production). Full reference for server
owners: [the Deathmatch docs page](https://open2077.net/docs/deathmatch).

Because several instances run at once, tunables are **captured per instance**
at creation rather than promoted per resource: `promote()` is per-resource, so
promoting when instance B opens would move instance A's finish line too. The
operator consequence is simple and worth stating in a changelog: a change
reaches instances created **after** it, and never a round already in flight.

## Layout

| Path | Owns |
|---|---|
| `open77.lua` | Manifest, permissions, the server-provided loading screen. |
| `shared/*.lua` | Buckets, map geometry, match rules, weapons, strings, tunable declarations. **Downloaded by every connecting client**: publishable prose only, never a secret, an address or an ACL entry. `shared/kabuki.lua` is the **built-in default map**: `server/mapstore.lua` snapshots it at load and replaces its tables in place when another map is selected, so nothing here may be cached across a call. |
| `server/*.lua` | Everything authoritative. One resource, several files, one Lua state: server resources cannot link to each other, so this is the only packaging that works. **Load order is manifest order**: the instance kernel is listed first because every other file hangs off the global it builds, and reordering breaks the resource at load rather than at runtime. |
| `client/main.lua` | Reports, requests and the wall clamp. Never a decision. |
| `web/loading.html` | This server's own loading screen instead of the built-in Open77 cover. |

The HUD is the separate [`open77_deathmatch_hud`](../open77_deathmatch_hud/)
resource, on `reload_policy "reconnect"`, so editing CSS never touches a live
match.

## How to tell what is actually running

Three sources are authoritative in this order, and none of them is prose:

1. **`open77.lua`.** A server script that is not listed there does not run. Load
   order is manifest order, and the instance kernel has to be first, because it
   builds the global every other file hangs off.
2. **`shared/config.lua`.** Anything not yet surveyed carries `provisional =
   true`, and the map carries `surveyed = false`. The startup log says so once.
3. **`/dm.where`.** What the server actually thinks about you right now, which
   settles more arguments than either file.

Two things are worth naming so nobody implements them twice.

**Career stats persist.** `server/ranked.lua` keeps them in two MySQL tables
through `Open77.database`, keyed on the master-backed identifier that
`Open77.players.identifier` answers, never on a player id (ids are reissued, so
keying on one would arm the next arrival with the last occupant's record) and
never carrying a name (the identifier is opaque and durable; the name is
resolved live by whoever reads a card).

**Per-format ELO is built.** `server/rating.lua` is pure arithmetic with no
engine binding and no store of its own, persisted by `ranked.lua` into a third
table beside the other two and printed by `/dm.stats` on each format's own line.
**Two models, because the mode runs two shapes of round.** An arena round
is a two-sided contest and takes a conventional Elo exchange, with a side rated
by the **mean** of its rateable members and every member taking the **whole**
side delta: a win is a win in every format, and splitting it would make a 3v3
win worth a third of a duel. A free-for-all has no sides at all and takes a
**pairwise placement** model: the final standings read as N(N-1)/2 pairwise
results, normalised by N-1 so a twelve-player round is worth one round rather
than eleven. It rewards finishing above people it expected you to finish below;
it does not reward margin, who you actually killed, or how long you were in the
round. The K factors, the baseline and the placement window are declared
tunables (`ratingStart`, `ratingArenaK`, `ratingFfaK`, `ratingEnabled` on the
Warden panel, the rest in `Config.rating`), and `/dm.rating.sim` prints what the
current ones would do to a synthetic field without touching a stored row.

**A round containing a bot moves no rating**, and it is the *same* refusal that
keeps it out of the career rather than a second one: `Ranked.recordRound`
consults `Deathmatch.scoring.ladderEligible` before it reads one standings row,
so no record is built, no commit job is queued and the rating model is never
called at all.

The database bridge is per **server**, not per resource. When it is off, the
career degrades to a volatile table for the run and says so, loudly, in the
startup log and in every `/dm.stats` card. That is the whole difference between
a ladder that is not persisting and one that is not working.
