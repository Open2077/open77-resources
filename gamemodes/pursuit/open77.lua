resource "pursuit"
version "0.1.0"
open77_version ">=0.0.1"
-- The default gamemode on this server. The match lifecycle owns its own match
-- cars, roadblocks and routing buckets, which is why only one gamemode runs at a
-- time: `race` is off for the same reason, and enabling both puts
-- two lifecycles on the same players.
--
-- It was disabled during the voice-chat merge because that lifecycle conflicts
-- with freeroam, which is still auto_start true. If players end up leashed to a
-- pursuit lobby when they should be roaming, that conflict is why -- turn
-- freeroam off rather than pursuit.
auto_start true

-- The rules engine hot-reloads: tuning a number in shared/config.lua and
-- reloading must take seconds. Presentation that owns a CEF surface lives in a
-- separate resource precisely so it can declare "reconnect" without dragging
-- this one down with it.
reload_policy "local"

-- A declared dependency is HARD. `StartRecursive` in scripting/src/ResourceHost.cpp
-- refuses the resource outright with `missing_dependency:<name>` when one is
-- absent, so this list is "Pursuit is not playable without these", not "Pursuit
-- talks to these".
--
-- `open77_groundcircle` is deliberately NOT here, and that is the whole reason
-- client/main.lua can call it safely. It is the HUD fallback for the ground
-- rings the native marker path cannot draw on 2.31 -- nice to have, never
-- required -- so a server whose resource set omits it must still run. It does:
-- `LuaCallExport` answers `nil, "export_resource_unavailable"` for a resource
-- that is missing or not running, `callExport` turns that into a nil return,
-- and `build()` logs one line and carries on with no ring. Adding it below
-- would convert that graceful degradation into a resource that refuses to
-- start.
dependencies {
    "open77_worldui >=0.1.0",
    "open77_zones >=0.1.0",
    "open77_notifications >=1.0.0",
}

-- Scripts are listed explicitly, not globbed. `client/**/*.lua` requires an
-- intermediate directory and matches nothing against a flat client/main.lua --
-- the client then refuses the whole resource set with
-- `script_pattern_empty:client/**/*.lua`. Every shipped resource lists its
-- scripts one per line; `**` is only safe for web_files.
-- Load order is manifest order, and the Phase E files depend on it. main.lua
-- builds the `Pursuit` global; match.lua adds the match table, the hook
-- registry and the geometry helpers to it; the four files after that register
-- hooks against what match.lua published. Reordering these lines breaks the
-- resource at load, not at runtime.
shared_script "shared/config.lua"
-- The vehicle roster the picker offers. Shared because server/loadout.lua
-- validates a pick against it and the client picker offers from it; this is a
-- byte-identical copy of resources/system/open77_vehiclepicker/shared/roster.lua, since
-- server-side Lua has no exports and no cross-resource bus to share it with.
shared_script "shared/roster.lua"
server_script "server/main.lua"
-- After main.lua, and it must stay there: it hangs `Pursuit.loadout` off the
-- `Pursuit` global main.lua builds, and load order is manifest order.
server_script "server/loadout.lua"
server_script "server/match.lua"
server_script "server/vehicles.lua"
server_script "server/scanner.lua"
server_script "server/bounds.lua"
server_script "server/roadblock.lua"
-- Last, and it only has to be after match.lua: it registers a `countdown`
-- hook and listens for `pursuit:matchResolved`, both published by match.lua,
-- and nothing else in the resource reads anything it defines.
server_script "server/ranked.lua"
-- The roster speed cap. After main.lua and nothing else: it reads the
-- `topSpeedKph` / `throttleAuthority` tunables, which main.lua declares, and
-- it listens for `pursuit:stateChanged` and `pursuit:matchStarted` rather
-- than calling into match.lua. Registering handlers is all it does at load,
-- so it is safe anywhere after the declaration.
server_script "server/performance.lua"
client_script "client/main.lua"
-- The other half of the speed cap, and separate from main.lua on purpose:
-- the native it drives (`Open77.vehicles.setPerformanceClass`) does not exist
-- on 2.31.0+op77.7, so the whole "does this client have a governor?" question
-- is kept in one file that answers it once and degrades to no cap.
client_script "client/performance.lua"

permissions {
    "network.events",
    "players.life.read",
    "players.life.kill",
    "players.life.respawn",
    -- Ghost-on-spawn: placements mark the player non-solid so stacked lobby
    -- slots cannot shove each other; the server auto-clears it on separation.
    "players.life.ghost",
    -- Teams separate cop from runner for the damage arbiter. Requested now so
    -- match creation does not fail on a permission the moment Phase C turns
    -- damage on.
    "combat.config",

    -- Phase E, server side. The gamemode owns the two match cars and the
    -- roadblock entities: they are authoritative server entities in the match's
    -- own routing bucket, created at countdown and removed on resolve.
    "world.vehicles",
    "world.npcs",

    -- The ranked ladder. Ratings have to survive a restart, and the database
    -- bridge is the ONLY persistence server-side Lua has: the sandbox nils out
    -- `io` and `os`, so a resource cannot write a file at all.
    --
    -- Declaring it is safe on a server with no database. The permission grants
    -- access to the binding; it does not require the bridge to be enabled, and
    -- server/ranked.lua degrades to a loudly-labelled in-memory ladder when the
    -- first statement comes back `database_unavailable`.
    "database.access",

    -- Phase E, client side. The scanner is a two-sided mechanic and each side
    -- needs its own capability: `ui.vanilla.map` draws the cop's stale blip,
    -- `world.effects` fires the pulse and the cue that tell the runner he has
    -- just been swept.
    --
    -- These are the mode's own presentation, not a shared service, which is why
    -- they sit here rather than behind `open77_worldui`: the ring on the ground
    -- is furniture any mode could want, whereas the scanner blip IS Pursuit.
    "ui.vanilla.map",
    "world.effects",

    -- The roster speed cap (shared/config.lua `topSpeedKph`,
    -- client/performance.lua). Client-side: it gates
    -- `Open77.vehicles.setPerformanceClass`, which caps a TweakDB record
    -- rather than an instance, so every present and future spawn of a
    -- roster car inherits the ceiling.
    --
    -- Declaring it is safe on a client that has never heard of it. A
    -- permission is a plain string in the manifest -- neither
    -- ResourceManifestParser.cs nor ResourceHost.cpp validates the name
    -- against a list -- so an older client parses it, stores it, and
    -- simply never has a binding that asks for it. The applier finds the
    -- export missing and degrades; it is not refused for the permission.
    "vehicles.performance"
}
