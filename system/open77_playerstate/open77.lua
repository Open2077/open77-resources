resource "open77_playerstate"
version "0.1.0"
open77_version ">=0.0.1"
auto_start true

-- Nothing here touches a client: no client_script, no shared_script, no web
-- surface. A reload rebuilds the roster from the next event each connected
-- player produces (see ensurePlayer in server/main.lua), so "local" is honest.
reload_policy "local"

-- No dependencies on purpose.
--
-- A declared dependency is HARD -- the host refuses the resource outright with
-- `missing_dependency:<name>` when one is absent. This resource must be
-- installable on any server, including one with no gamemode and no shared
-- services at all, because "a server with nothing else installed" is exactly
-- the case it is FOR. It consults open77_appearance and any gamemode only
-- through the host (the readiness gate and GetResourceState), never by calling
-- them, so neither has to be present.

-- Scripts are listed explicitly, never globbed: `server/**/*.lua` requires an
-- intermediate directory and matches nothing against these flat files, and an
-- empty glob prevents the resource from starting.
--
-- Load order is manifest order, so config.lua must come first (main.lua reads
-- Config at load to declare the tunables) and restore.lua last (it hangs off
-- the `PlayerState` global main.lua publishes).
--
-- config.lua is a server_script and NOT a shared_script, which departs from
-- docs/writing-a-gamemode.md section 8.1 for a reason worth stating: that rule
-- exists to keep the `declare` CALL off the client, because `Open77.tunables`
-- is nil there and a resource set that fails on one client refuses every
-- player. This resource has no client half at all, so putting the table in a
-- shared_script would ship a file to every connecting player that no client
-- code ever reads. The declaration itself still reaches the Warden panel --
-- the host publishes it from the declare call, not from the script.
server_script "server/config.lua"
server_script "server/main.lua"
server_script "server/restore.lua"

permissions {
    -- The only persistence server-side Lua has. The sandbox nils out `io` and
    -- `os`, so a resource cannot write a file at all.
    --
    -- Declaring it is safe on a server with no database: the permission grants
    -- access to the binding, it does not require the bridge to be enabled, and
    -- the schema probe in server/main.lua degrades to a single logged line.
    "database.access",

    -- Reading a life snapshot is how this resource proves a player is really
    -- incarnated before it touches them. Acting server-side on a client that
    -- is not crashes that client, so this is a safety permission, not a
    -- convenience one.
    "players.life.read",

    -- Restoration is a kill -> respawn transaction, never a transform write.
    -- A direct teleport over any real distance drops the player into
    -- unstreamed world; the respawn carries the fade, the streaming preload
    -- and the grace window.
    "players.life.kill",
    "players.life.respawn",

    -- Health and armour are the "what condition were they in" half of the
    -- feature. `read` samples it, `apply` puts the armour back after the
    -- respawn transaction has settled (health rides the respawn itself).
    "players.damage.read",
    "players.damage.apply",
    "players.stats.read",
    "players.stats.apply"

    -- Deliberately NOT requested: world.vehicles. See the vehicle note in
    -- server/main.lua -- this resource never restores a player into a car, so
    -- holding the capability that would let it read seat ledgers would buy a
    -- per-tick scan of every vehicle on the server and nothing else.
    --
    -- Deliberately NOT requested: network.events. Nothing is sent to or
    -- accepted from a client. Position, health and life phase are all read
    -- from authoritative server state, so there is no client claim to
    -- validate and no event surface to defend.
}
