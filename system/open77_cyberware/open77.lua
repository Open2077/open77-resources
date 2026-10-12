resource "open77_cyberware"
version "0.1.0"
open77_version ">=0.0.1"
auto_start true
reload_policy "local"
client_script "client/prediction.lua"
client_script "client/melee-prediction.lua"
client_script "client/main.lua"
client_script "client/ground-slam.lua"
client_script "client/ground-slam-presentation.lua"
server_scripts { "server/capabilities.lua", "server/presentation-config.lua", "server/presentation.lua", "server/ground-slam-presentation.lua" }
permissions { "network.events", "network.client", "world.effects", "player.cyberware.read", "player.cyberware.project", "player.motion.project", "players.cyberware.read",
    "player.abilities.project", "player.abilities.read", "world.query", "input.actions", "players.life.read" }
