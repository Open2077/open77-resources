resource "open77_pedestrians"
version "0.1.0"
auto_start true
reload_policy "local"
-- The catalogues are one script file each (a server script gets its own load budget); the lane points
-- are split over lanes-points-N.lua in order (build/generated/pedestrians/lanes-report.json, pointFiles).
server_scripts {
    "server/config.lua",
    "server/spots-generated.lua",
    "server/lanes-generated.lua",
    "server/lanes-points-1.lua",
    "server/lanes-points-2.lua",
    "server/lanes-points-3.lua",
    "server/crowdspots-generated.lua",
    "server/spatial.lua",
    "server/seatguard.lua",
    "server/scheduler.lua",
    "server/crowd.lua",
    "server/main.lua",
}
client_scripts { "client/main.lua" }
permissions { "world.npcs", "world.environment", "players.life.read", "network.events" }
