resource "open77_deathmatch"
version "0.2.0"
open77_version ">=0.0.1"

-- Kabuki Arena: a drop-in free-for-all plus queued 1v1 / 2v2 / 3v3 on one
-- surveyed map. One gamemode per server -- `freeroam` must stay OUT of the
-- resource set alongside this one, because its `autoRespawn` answers every
-- placement this mode issues.
auto_start true

-- The rules engine hot-reloads: tuning a number in shared/config.lua and
-- reloading must take seconds. Presentation owns a CEF surface and lives in
-- `open77_deathmatch_hud` precisely so it can declare "reconnect" without
-- dragging this one down with it.
reload_policy "local"

-- A declared dependency is HARD. `StartRecursive` in scripting/src/ResourceHost.cpp
-- refuses the resource outright with `missing_dependency:<name>` when one is
-- absent, so this list means "Kabuki Arena is not playable without these", not
-- "Kabuki Arena talks to these".
--
-- `open77_interactions` is here because of a MEASUREMENT, not a reading of the
-- manifests: a resource set listing `open77_worldui` WITHOUT it refuses to
-- start, once per second, indefinitely --
--
--   [ERR] Automatic resource start failed: Resource 'open77_interactions' was not found.
--
-- `open77_worldui/open77.lua` declares `dependency "open77_interactions >=0.1.0"`,
-- and the server does not start the set partially and does not stop retrying, so
-- the omission presents as an endless error loop rather than a startup failure.
-- The plan named three world-UI resources; it is four.
--
-- `open77_groundcircle` is listed deliberately, and this is where this manifest
-- DIFFERS from pursuit's -- pursuit leaves it out on purpose so a server without
-- it still runs, degrading to no ring. Kabuki Arena cannot make that trade: on
-- 2.31 the native 3D interaction ring does not draw AT ALL, the ground circle is
-- the only thing the player actually sees, and entry is a station in the world
-- (decision 10). A station nobody can see is not a degraded entry point, it is
-- no entry point. If that trade is ever revisited, move this line out and make
-- the station build tolerate a nil ring -- do not leave it here and hope.
dependencies {
    "open77_weapons >=0.1.0",
    "open77_worldui >=0.1.0",
    "open77_interactions >=0.1.0",
    "open77_groundcircle >=0.2.0",
    "open77_zones >=0.1.0",
}

-- SCRIPTS ARE LISTED ONE PER LINE AND NEVER GLOBBED.
--
-- `client/**/*.lua` requires an intermediate directory and matches NOTHING
-- against a flat `client/main.lua`; the client then refuses the whole session
-- resource set with `script_pattern_empty:client/**/*.lua` and nobody connects.
-- `**` is only safe for `web_files`.
--
-- LOAD ORDER IS MANIFEST ORDER, and the server half depends on it:
--
--   config.lua     the rules, and every player-facing string.
--   kabuki.lua     the surveyed geometry and the one containment test. Both
--                  shared scripts load before any server script.
--   instances.lua  builds the `Deathmatch` global, makes the single
--                  `Open77.tunables.declare` call, and owns the registry.
--                  FIRST of the server scripts, always.
--   mapstore.lua   the runtime map store and the /dm.map live editor. Snapshots
--                  kabuki.lua as the built-in default, adopts the carried map
--                  across a reload, and applies the selected map into
--                  `DeathmatchKabuki` -- before bounds.lua reads it.
--   bounds.lua     hangs `Deathmatch.bounds` off it and needs the helpers.
--   round.lua      the free-for-all loop, per instance.
--   arena.lua      queues, teams, elimination rounds, side swap.
--   loadout.lua    kits across three slots, verification, resupply.
--   scoring.lua    the damage ledger, assists, bonuses, streaks.
--   bots.lua       bot lifecycle inside an instance.
--   survey.lua     the draft-and-dump surveyor, `/dm.where`, and the one 4 Hz
--                  heading reporter (which mapstore.lua borrows rather than
--                  opening a second one).
--   main.lua       LAST: lifecycle, roster, placement, commands, tick, state
--                  push. It consumes everything above and publishes nothing the
--                  others need at load.
--
-- Reordering these lines breaks the resource at load, not at runtime.
-- Rules, hand-authored: buckets, timings, kits, tunables, strings.
shared_script "shared/config.lua"
-- Geometry, GENERATED: `/dm.survey dump` rewrites this file wholesale from
-- coordinates captured in-game. It is shared rather than server-only because
-- the wall is a client-side clamp (decision 15, settled by E2) and the clamp
-- needs exactly this geometry. It must load before any script that reads it --
-- bounds.lua resolves `Config.zones` volume NAMES against it and judges
-- containment with its `locateIn`, so there is one containment test in the
-- resource rather than two that can disagree.
shared_script "shared/kabuki.lua"

-- Dependency order, and it is load-bearing: a file that reads another's
-- namespace at load must come after it. main.lua is LAST because it consumes
-- everything above and publishes nothing the others need at load time.
--
-- Listing a file that does not exist is not a harmless placeholder. It does not
-- fail with "file not found" -- it breaks the load chain, and the error
-- surfaces somewhere else entirely (here it appeared as a nil Kabuki in
-- bounds.lua, three files away).
-- Order is by LOAD-TIME reads, not by importance. round.lua tests for
-- scoring.lua at load and degrades itself to "no respawns, no kill limit, no
-- eliminations" when it is absent -- and it says so in the log and then STARTS
-- ANYWAY. A resource that reports `started generation=1` while quietly missing
-- its respawns is worse than one that refuses outright, so providers load first.
server_script "server/instances.lua"
-- The runtime map store, and it is SECOND for a load-order reason rather than
-- an aesthetic one: it adopts the carried map across a hot reload
-- SYNCHRONOUSLY and applies it into `DeathmatchKabuki`, so `bounds.lua` below
-- runs its own `Bounds.rebuild()` over the authored geometry instead of over
-- the shipped geometry and then flipping a moment later. It needs
-- `instances.lua` first for `DM.tune`, `DM.log` and `DM.nowMs`.
server_script "server/mapstore.lua"
server_script "server/bounds.lua"
server_script "server/loadout.lua"
server_script "server/scoring.lua"
server_script "server/bots.lua"
server_script "server/round.lua"
server_script "server/arena.lua"
-- rating.lua is PURE ARITHMETIC -- the per-format ELO model and nothing else.
-- It has no engine binding, no database and no state, and it cannot find a
-- round on its own: `ranked.lua` calls it AFTER the decision-12 gate has
-- already refused a round containing a bot, which is what keeps the mode's one
-- ladder gate its only one. It reads only `Deathmatch` and `DeathmatchConfig`
-- at load, so it sits here purely so the manifest reads in the direction of the
-- calls.
server_script "server/rating.lua"
-- ranked.lua reads only `Deathmatch` and `DeathmatchConfig` at load, so its
-- position is free; it sits after the two round layers because THEY call IT and
-- reading the manifest top to bottom should follow the direction of the calls.
-- Both resolve `Deathmatch.ranked` at call time, so a server that removes this
-- line plays exactly the same rounds and simply records none of them.
server_script "server/ranked.lua"
server_script "server/survey.lua"
server_script "server/main.lua"

client_script "client/main.lua"
-- The entry station (decision 10): the ground rings and the held key that are
-- the way IN to the mode. Separate from main.lua because it is the only client
-- file that talks to another resource -- open77_worldui, open77_groundcircle
-- and open77_zones, all three declared above -- and because the wall in
-- main.lua runs at 60 Hz and must never be reloaded to change a label.
client_script "client/station.lua"
-- Combat music for a PvP fight. Separate from main.lua because it is pure
-- presentation with no authority in it at all: it consumes signals the mode
-- already emits and posts Wwise events on the local player. Nothing else in the
-- resource reads it, so it loads last and can be removed by deleting this line.
client_script "client/music.lua"

-- Server-provided loading screen (FiveM-style). The client renders this page,
-- from this resource's verified pack files, in a sandboxed surface during the
-- join -- so this server shows its OWN loading screen instead of the built-in
-- Open77 cover. It is a static declared page: it runs before this resource's
-- Lua does, driven only by the progress events the client forwards to it.
loadscreen "web/loading.html"
web_files { "web/**" }

permissions {
    "network.events",

    -- Placement. Every move is one `kill -> respawn` primitive carrying the
    -- fade, the streaming preload and the grace window -- including the arena
    -- entry, the respawn and the bounds backstop.
    "players.life.read",
    "players.life.kill",
    "players.life.respawn",

    -- Damage arbitration and the per-victim ledger that assists are derived
    -- from.
    --
    -- `players.damage.apply` is still what carries a bot's bullet, but it no
    -- longer INVENTS one. The bot fires a real weapon under vanilla combat AI;
    -- the victim's own client observes the resulting `gameHitEvent` and reports
    -- it, and this permission is what lets the mode enter that observed number
    -- into the ledger. The attribution is what makes it worth doing through
    -- this binding rather than any other: the NPC id survives all the way into
    -- `open77:playerDamaged` as the attacker (measured 2026-08-31), so the kill
    -- feed can name the bot and the directional damage indicator has a real
    -- source to point at.
    "players.damage.read",
    "players.damage.apply",

    "players.stats.read",
    "players.stats.apply",

    -- Teams for the arena formats, and the host-global damage policy. Combat
    -- policy is host-wide: friendly fire and the damage multipliers are shared
    -- by every instance, so per-instance damage tuning is NOT available.
    "combat.config",

    "player.weapons.edit",

    -- The wall. E2 proved a prop cannot be solid and invisible at once, so the
    -- boundary is a client-side clamp and the client needs the one primitive
    -- that writes a transform without the respawn discipline. It is used ONLY
    -- for corrections of a few centimetres -- bounded below so it never fights
    -- locomotion over floating point, and bounded ABOVE so it can never become
    -- the teleport this mechanism exists to avoid. Anything larger is the
    -- server backstop's kill -> respawn onto a surveyed mark.
    "player.travel",

    -- Bots. Server-owned NPCs are bucket-scoped, so a bot lives inside one
    -- instance for free, exactly like a prop.
    "world.npcs",

    -- Combat music (client/music.lua). `Open77.sfx.play` is gated on this one
    -- permission, and it is the whole of what the music needs: no VFX, no
    -- registry, no server side. Without it every post comes back
    -- `permission_denied:world.effects` and the mode is silent again.
    "world.effects",

    -- Drawing the boundary. Props may MARK the wall -- E4 confirmed they never
    -- cross a routing bucket -- but they never enforce it, because E2 proved
    -- `visible = false` does not hide one.
    "world.props",

    -- Career stats and per-format ELO (Phase 8). Declaring this is safe on a
    -- server with no database: the permission grants access to the binding, it
    -- does not require the bridge to be enabled, and the ladder degrades to a
    -- loudly-labelled in-memory table when the first statement comes back
    -- `database_unavailable`. The sandbox nils out `io` and `os`, so the
    -- database bridge is the only persistence server-side Lua has at all.
    "database.access",
}
