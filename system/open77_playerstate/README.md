# open77_playerstate

Remembers where a player was and what condition they were in, and puts them
back there when they return.

- **Docs:** [The join-time readiness gate](https://open2077.net/docs/readiness-gate), [Configure a SQL database](https://open2077.net/docs/database)
- **Starts:** on its own
- **Needs:** nothing
- **Runs on:** server

A player who disconnects at a spot, on 40% health with 25 armour, reconnects
standing at that spot, on 40% health with 25 armour. Nothing else changes.

This is *world* state only. `open77_appearance` already owns what a player
**looks like** and this resource does not touch it; the two key their rows the
same way and are otherwise independent.

---

## Installing

Drop it in `resources/` and give the server a database. That is the whole
installation: there is no configuration file to edit, and every setting is
reachable from the Warden **Tuning** tab.

```
resources/system/open77_playerstate/
```

With no database configured the resource loads, prints one line saying so, and
does nothing else. It does not error on every join and it does not need to be
removed.

---

## The one thing to know before installing it

**A gamemode owns where its players spawn.** If this resource also places
players, two things move the same player and the last one wins.

### Freeroam: cooperation, not standing down

This resource is built for **freeroam**, and freeroam genuinely does own spawn:
`forceOnJoin` kill/respawns every joiner at a fixed point, retrying for up to
thirty seconds. Standing down for it would make this resource useless on the one
kind of server it is for; standing aside would not work either, because that
retry loop wins any race.

So the two cooperate, and the split is the one a sandbox player expects:

| | Placed by |
| --- | --- |
| Returning player with a fresh saved position | **this resource** |
| First-timer, expired row, or a failed restore | **freeroam**, exactly as before |

The channel is the readiness gate. When the last hold on a player is released,
the host passes the releasing resource's note through as the `detail` of
`onPlayerReady`, which every running resource receives. Releasing with
`playerstate:restored` is therefore a fact freeroam can read without either
resource calling the other, which is the only shape available, since server
resources cannot call each other at all.

It is safe rather than clever for two reasons. This resource only places a
player once no *other* hold remains, so whenever it restores somebody it is by
construction the last releaser and its note is the detail freeroam sees. And
every other outcome releases a note freeroam does not recognise, so the fallback
is freeroam's existing behaviour rather than an error path.

Freeroam carries a small, purely additive change for its half: see
"What freeroam needs" below.

### Other gamemodes

By default the resource still goes **fully inert** (no saving, no restoring,
one log line) while any resource in `spawnOwners` is running. That list
defaults to:

```
pursuit, race
```

Both are match-based: a 1v1 must never start a player in last night's position.
Add your own gamemode if it places players on join and cannot be told to stand
aside for a returning one. `spawnPolicy` is the override:

| `spawnPolicy` | Behaviour |
| --- | --- |
| `auto` (default) | Inert while a resource in `spawnOwners` is running; otherwise saves and restores. |
| `never` | Records state, never places anybody. For collecting the data before turning placement on. |
| `always` | Restores regardless. Correct only if you know nothing else places players. |

Server resources cannot call each other, so no resource can *ask* a gamemode
whether it claims spawn. This is the honest shape for a question only the
operator can answer, and both halves of it are retunable at runtime.

## What freeroam needs

Two things beyond this resource, and neither is optional:

1. **A server binary that has the join-time readiness gate** (`Open77.ready`).
   Without it this resource downgrades itself to recording only and never
   places anybody, and freeroam's deferral is skipped entirely: the pair
   behaves exactly as freeroam alone does today. That is a safe staging state,
   not a working one.
2. **The freeroam change**, already in [freeroam](../../gamemodes/freeroam/) (see below).
   Purely additive; it is inert on a binary with no gate.

## What is saved

| | |
| --- | --- |
| position | x, y, z (the point of the whole thing) |
| heading | estimated from movement; see below |
| health, max health | restored as a fraction, with a floor |
| armour | applied after the respawn has settled |
| name | diagnostics only, never a key |
| routing bucket | recorded, **never restored** |

## What is deliberately not saved

**The vehicle a player was in, and their seat.** The server can answer this, so
the omission is a choice. A vehicle id does not survive a restart; within one
run the car may have been driven off, destroyed or taken by somebody else; and
re-seating means a second placement chasing the respawn transaction. A player
who logs out driving comes back standing at that spot, on foot, which is also
why this resource does not request `world.vehicles`.

**The routing bucket.** It is recorded but restoration always uses bucket 0. A
non-zero bucket is a gamemode's private dimension, and putting somebody back
into a match whose match ended is worse than a fresh spawn.

**Inventory, money, progression, quests.** Not this resource's job.

---

## Save cadence, and what it costs

Two cadences, one thread:

- **every second**: an in-memory snapshot, and the heading estimate. No
  database traffic at all: one dictionary read per tracked player.
- **every `autosaveSeconds`** (default 60): the snapshot is written, but only
  for players who have moved at least `minMoveMetres` (default 1.5 m) since
  their last write. An idle server writes nothing.
- **on disconnect**: one write, unconditionally.

The writes in one interval are batched into transactions of 50, so a tick is
one round trip per chunk rather than one per player. At 32 players all moving
that is 32 rows a minute in one transaction: about 0.5 writes a second against
a pooled connection running on the thread pool.

Because the snapshot is refreshed every second, a graceful disconnect saves a
position **about a second stale**. Only a server that is killed rather than
stopped falls back to the last autosave, which is what `autosaveSeconds`
actually bounds.

---

## Staleness

`expiryHours` (default 336, two weeks) ignores anything older. A position from
three weeks ago, on a server whose world or gamemode has moved on, is often
worse than a fresh spawn. Zero disables expiry.

---

## Restoring safely

Restoration is the dangerous half, and it is guarded three ways.

**It waits for the readiness gate.** The resource declares
`Open77.ready.participate` at load, so every joiner arrives with a hold already
in its name: it is not racing to take one. While any *other* resource still
holds the player (a character creator, say) it heartbeats its own hold rather
than running the clock down, so a slow character creation never costs anybody
their saved position.

**It proves the player exists before touching them.** Acting server-side on a
client that is connected but not incarnated does not fail, it crashes that
client. Three signals are required: the life authority knows them, their phase
is `alive` or `recovering`, and a replicated position resolves. A gate that
opened on a *timeout* is not enough on its own, and is not treated as enough.

**It moves them with kill → respawn, never a transform write**, so the
placement carries the fade, the streaming preload and the grace window. The kill
is tagged `playerstate:restore` so a gamemode with a death rule can reject it.

If the server has no readiness gate at all (a binary predating `Open77.ready`),
the resource downgrades itself to **recording only**, says so in one line, and
never places anybody. Positions keep accumulating for the day the gate is there.
Placing a joining player without it is precisely the collision the gate exists
to prevent.

If any of that fails, the stored row is **left alone**. A player whose
restoration did not land is standing at the default spawn; saving that on their
next disconnect would turn one bad evening into permanent, silent data loss.

---

## Tunables

All in the Warden **Tuning** tab, all applying live.

| Group | Key | Default |
| --- | --- | --- |
| Persistence | `enabled` | `true` |
| | `autosaveSeconds` | `60` |
| | `minMoveMetres` | `1.5` |
| | `expiryHours` | `336` |
| Restoring | `restoreHealth` | `true` |
| | `restoreArmor` | `true` |
| | `minRestoreHealth` | `0.15` |
| Ownership | `spawnPolicy` | `auto` |
| | `spawnOwners` | `pursuit,race` |
| Joining | `readyTimeoutSeconds` | `45` |

---

## Console

All restricted (`command.<name>` ACL; the server console is always allowed).

```text
playerstate                     mode, database, policy, and every tracked player
playerstate.where <playerId>    what the server sees now vs. what is stored
playerstate.save <playerId>     force a write
playerstate.track <playerId>    adopt a player into the roster after a reload
playerstate.forget <playerId>   delete a stored row
```

`playerstate.where` is the one to reach for first. "Nothing happened when I
reconnected" is invisible from every other angle: the player is connected, the
world is up, and every resource is correctly waiting.

### After a reload

A reload gives a fresh VM with an empty roster while the server is still full,
and `onPlayerConnected` does not re-fire. Players connected
before the reload are therefore **not tracked until they reconnect**: nothing
is lost, but nothing new is recorded for them. `playerstate.track <playerId>`
adopts one immediately. The resource says this in its start-up log rather than
leaving it to be discovered.

---

## The freeroam change, and how to turn it off

Purely additive, across two files of [freeroam](../../gamemodes/freeroam/). Nothing
existing was modified.

`freeroam/shared/config.lua`: two keys under `Config.spawn`:

```lua
deferToReadinessGate = true,
placedByDetailPrefixes = { "playerstate:restored" },
```

`freeroam/server/main.lua`: one table and two helpers above
`applyJoinSpawn`, two guards at the top of `applyJoinSpawn`, one
`onPlayerReady` handler, and one line clearing the table on disconnect.

**To disable without touching code:** set `deferToReadinessGate = false`, or
empty `placedByDetailPrefixes`. Either restores the previous behaviour exactly.

`applyJoinSpawn` now returns early in two new cases, and both fall through to
the original body otherwise:

| Condition | Result |
| --- | --- |
| The gate already opened with a `playerstate:restored` detail | skip; latch `deferred` |
| The gate is still closed for this player | latch `waiting`; resume from `onPlayerReady` |
| No gate on this binary, or nothing holding | unchanged: spawn as before |

The deferral is also a genuine bug fix on its own terms: the platform rule is
*do not teleport, spawn, kill or force a respawn on a player until their gate
has opened*, and freeroam predates the gate and has been violating it. It never
hit the appearance collision only because it acts from
`open77:session:gameplayReady` (after the puppet attaches) rather than
`open77:worldReady` (before incarnation).

## Schema

Two prefixed names, in the server owner's own database. The database bridge is
per-server rather than per-resource (every resource holding `database.access`
shares one connection and can see every other resource's tables), so the prefix
is what makes ownership unmistakable.

`open77_playerstate_positions`, keyed `(user_id, character_key)`:

| Column | |
| --- | --- |
| `user_id` | `CHAR(36)`: the master-backed GUID from `GetPlayerIdentifier()`, bound to the client's identity certificate. Same key `open77_appearance` uses. |
| `character_key` | always `'default'` today; see below |
| `name`, `pos_x`, `pos_y`, `pos_z` | |
| `heading`, `heading_known` | |
| `bucket` | recorded, never restored |
| `health`, `max_health`, `armor` | |
| `saved_reason` | `autosave`, `disconnect` or `manual` |
| `created_at`, `updated_at` | `updated_at` is what makes expiry answerable |

Multi-character support belongs to `open77_appearance`, which tracks the active
key in its own VM; server resources cannot call each other, so there is no way
to ask which character a player is currently wearing. Every row keys to
`'default'`, exactly as an appearance row does for a player who has never used a
second slot. The column exists so that the day a character key becomes
readable, it can be filled in without a migration against live rows.

---

## Notes for whoever edits this next

- **Heading is estimated, not read.** There is no live heading for a player
  server-side: `GetPlayerPosition` carries no rotation, and the `yaw` on
  `getLifeState` is the heading of the player's last *life transition*, not the
  direction they are facing now. So heading is derived from the displacement
  between two samples a second apart, using the engine's own convention
  (yaw 0 = +Y, so `yaw = atan2(-dx, dy)`). It is wrong for somebody walking
  backwards into a disconnect and unavailable for somebody who never moved. The
  day a live yaw exists server-side, one function in `main.lua` changes.
- **Health has two scales on two neighbouring APIs.** `getHealth` reports
  absolute health against a maximum that defaults to 100; `respawn` takes a
  *fraction*, validated to 0.01–1.0. `healthFraction` in `restore.lua` is the
  only place that conversion happens.
- **`TINYINT(1)` comes back as a boolean or an integer** depending on the
  operator's connection string (`TreatTinyAsBoolean`). `truthy()` in
  `restore.lua` accepts both.
- **Every statement binds named parameters**, never a positional `?`, and no
  SQL string in this resource contains a comment. The bridge rewrites `?`
  placeholders by scanning the statement, and quoting and comments are the hard
  part of that scan.
