resource "open77_hacking"
version "0.5.0"
open77_version ">=0.0.1"
auto_start true
reload_policy "local"
dependency "open77_cyberware >=0.1.0"
dependency "open77_effects >=0.2.0"
dependency "open77_notifications >=1.0.0"
client_scripts { "client/config.lua", "client/main.lua" }
server_script "server/presentation.lua"
permissions { "network.events", "network.client", "input.actions", "world.query", "player.hacking.project", "world.effects", "screen.effects", "players.hacking.read", "player.movement.lock", "player.hacking.status" }
