resource "open77_cordon"
version "0.1.0"
open77_version ">=0.0.1"
auto_start true
reload_policy "local"

-- CORDON — the Open77 battle royale. Sixty-four players in a sealed Pacifica;
-- NCPD closes the district block by block; the last squad standing is extracted.
-- The plan is docs/gamemode-cordon-plan.md and it is the source of truth.
--
-- ---------------------------------------------------------------------------
-- WHY THIS IS ONE RESOURCE WITH MANY SERVER SCRIPTS.
--
-- Open77's server Lua runtime installs no `exports`, no `GetInvokingResource`
-- and no cross-resource event bus; `TriggerEvent` walks one VM. A second server
-- resource could not be asked for anything. So a gamemode's entire server side
-- is ONE resource whose files share a Lua state and reach each other through a
-- single global (`Cordon`), never through anything callable from outside.
-- The client is the opposite — it does have exports — which is why the HUD is
-- its own resource (open77_cordon_hud) and why it has to be: a WebUI surface
-- needs reload_policy "reconnect" while these rules need "local", and one
-- manifest declares one policy.
--
-- LOAD ORDER IS MANIFEST ORDER AND IS LOAD-BEARING. shared before server;
-- kernel before everything that builds on it; main.lua LAST because it wires
-- the parts together and registers the host event handlers.
-- ---------------------------------------------------------------------------

shared_script "shared/config.lua"      -- rules, schedule presets, loot tables, strings, tunable table
shared_script "shared/grid.lua"        -- pure block math; no engine calls
shared_script "shared/pacifica.lua"    -- the surveyed map (Phase 2 fills the coordinates)
shared_script "shared/watson.lua"      -- compact test map on walked Kabuki ground; see activeMap
shared_script "shared/dogtown.lua"    -- editable owner-supplied center/lobby; remaining points await survey
shared_script "shared/chinatown.lua"  -- 7x7 of 128 m over Little China; SURVEYED 2026-09-03, 44 of 49 cells walkable

server_script "server/kernel.lua"      -- the Cordon global: roster, buckets, placement, tick
server_script "server/combat.lua"      -- fail-closed player damage arbitration
server_script "server/cordon.lua"      -- open blocks, the closure schedule, containment, the bleed
server_script "server/squads.lua"      -- seats, teams, revive at the body, pings, squad voice
server_script "server/bots.lua"        -- contestants that fill a match players did not fill
server_script "server/loot.lua"        -- ground drops, the inventory the mode owns, death drops
server_script "server/holdouts.lua"    -- gang camps on the high-tier marks, the mode's only PvE
server_script "server/npc-combat.lua"  -- player, contestant and holdout hit reports
server_script "server/match.lua"       -- the state machine: staging -> deploy -> live -> extraction
server_script "server/deaths.lua"      -- canonical life-event context and kill attribution
server_script "server/rating.lua"      -- pure placement ELO, no store, no engine binding
server_script "server/ranked.lua"      -- career + rating persistence, and the ladder gate
server_script "server/main.lua"        -- lifecycle, commands, the damage arbiter, state push

-- AFTER main.lua, and that is the one exception to "main.lua is last".
--
-- main.lua is last because everything in it wires parts earlier files defined.
-- That reason applies to the editor MORE strongly, not less: it reads `K.map`,
-- `K.recomputeSurveyed`, `K.publishSurvey`, `K.builtinMaps`, `M.phase` and
-- `C.publish`, every one of which main.lua declares, and it REPLACES `K.map`
-- with the runtime map at load. Placed before main.lua it would apply a map
-- that main.lua then overwrites with `K.resolveMap()`.
--
-- It registers no handler main.lua calls, so the ordering rule main.lua's own
-- header protects is untouched.
server_script "server/editor.lua"      -- /br.map: the in-world map editor and the runtime map store

client_script "client/main.lua"        -- readiness, the outside-cordon signal, hit forwarding
client_script "client/edge.lua"        -- the in-world boundary: red edge lights and columns
client_script "client/sweep-edge.lua"  -- persistent world FX on shared continuous damage geometry
client_script "client/night.lua"       -- Dogtown match clock through the weather authority
client_script "client/comfort.lua"     -- takes vanilla's walk-only "safe areas" off; the lobby is in one
client_script "client/revive.lua"      -- the prompt that picks a downed squadmate up; the operator command was the only path
client_script "client/self-revive.lua" -- physical held recovery with server heartbeat lease
client_script "client/consumables.lua" -- rebindable armor/healing requests

-- Every script is listed EXPLICITLY, one per line. `client/**/*.lua` matches
-- NOTHING against a flat client/ directory — `**` requires an intermediate
-- directory — and the client then refuses the entire session resource set with
-- `script_pattern_empty`, which means nobody can connect. This is not a style
-- preference; it is a measured outage.

dependency "open77_weather >=0.1.0"
dependency "open77_weapons >=0.1.0"
dependency "open77_loot >=0.1.0"
dependency "open77_worldui >=0.1.0"
dependency "open77_interactions >=0.1.0"
dependency "open77_groundcircle >=0.1.0"
dependency "open77_zones >=0.1.0"
dependency "open-voice >=0.2.0" -- proximity HUD and native voice/PTT dependency

permissions {
    "network.events",
    "input.actions",

    -- Placement is one kill -> respawn primitive; every move in the mode goes
    -- through it, so a placement is always a death the death rule must ignore.
    "players.life.read",
    "players.life.kill",
    "players.life.respawn",
    "players.life.revive",
    "players.life.ghost",

    -- The cordon bleed, spawn shields, plates and heals.
    "players.damage.read",
    "players.damage.apply",
    "players.stats.read",
    "players.stats.apply",

    -- Squads (team ids cancel friendly fire in the platform) and the arbiter.
    "combat.config",

    -- THE AERIAL INSERTION. `Open77.chute` rewrites the local player's fall
    -- gravity and makes him briefly invulnerable for the length of a descent.
    -- It is its own grant rather than a member of `player.travel` on purpose: a
    -- gamemode asking for a parachute should not receive noclip and a teleport
    -- with it. Client-side only; the server half of the drop is god mode, which
    -- `players.stats.apply` above already covers.
    "player.chute",

    -- Ground loot, and turning a picked-up weapon into a verified one.
    "world.loot",
    "player.weapons.edit",

    -- Holdouts and the bots that fill a match players did not fill.
    "world.npcs",

    -- Vehicles at surveyed spots, and the extraction AV.
    "world.vehicles",

    -- The cordon edge and the supply crate.
    "world.props",
    "world.effects",

    -- Vanilla marks the Afterlife, Lizzie's and Clouds as staged, walk-only,
    -- weapons-holstered space, and this mode stages its lobby inside one of
    -- them. client/comfort.lua holds the claim; it is cooperative, released on
    -- stop, and inert outside a live session.
    "world.safeareas",

    -- Squad voice.
    "voice.manage",

    -- Career, rating and the match ledger. Absent is a SUPPORTED state: the
    -- career degrades to a loudly-labelled in-memory table.
    "database.access",

    -- THE MAP EDITOR'S DURABLE STORE (server/editor.lua). `Open77.io` is rooted
    -- at this resource's own `data/` directory and can reach nothing else -- the
    -- host exposes that one directory precisely so that a resource saving
    -- gameplay data cannot rewrite its own manifest or scripts and grant itself
    -- more capabilities on the next reload.
    --
    -- Writing there does NOT hot-reload the session, which is the standing rule
    -- these two grants have to answer to. `ServerResourceHost.Digest()` hashes
    -- only the shared and server scripts declared above plus this file, and the
    -- client package is built from the declared `client_script` / `web_files`
    -- set -- so a file under `data/` is invisible to both. `resources/gamemodes/race` has
    -- persisted its hand-authored courses exactly this way all along.
    --
    -- They exist because `server.cordon-local.jsonc` disables the database: with
    -- these absent the editor still runs and still says so in capitals, but a
    -- walked map dies on the next server restart.
    "filesystem.read",
    "filesystem.write",
}
