resource "open77_pedestrians"
version "0.1.0"
auto_start true
reload_policy "local"
-- The catalogues keep ~40 MB alive and tens of thousands of NPCs add their own: well past the default 64 MB.
lua_memory_mb 256
-- The catalogues are one script file each (a server script gets its own load budget); the lane points
-- are split over lanes-points-N.lua in order (build/generated/pedestrians/lanes-report.json, pointFiles).
server_scripts {
    "server/config.lua",
    "server/spots-generated.lua",
    "server/lanes-generated.lua",
    "server/lanes-points-1.lua",
    "server/lanes-points-2.lua",
    "server/lanes-points-3.lua",
    "server/crowdsets-generated.lua",
    "server/crowdspots-generated.lua",
    "server/spatial.lua",
    "server/seatguard.lua",
    "server/exclusions.lua",
    "server/scheduler.lua",
    "server/crowd.lua",
    "server/main.lua",
}
client_scripts { "client/main.lua" }
permissions { "world.npcs", "world.environment", "players.life.read", "network.events" }
