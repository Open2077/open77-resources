resource "open77_npcs"
version "1.0.0"
open77_version ">=0.0.1"
auto_start true
reload_policy "local"

client_script "client/main.lua"
server_script "server/main.lua"

permissions { "network.events", "world.npcs", "npcs.read" }
