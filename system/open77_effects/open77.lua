resource "open77_effects"
version "0.2.0"
open77_version ">=0.0.1"
auto_start true
reload_policy "local"

client_script "client/main.lua"
server_script "server/main.lua"

permissions { "network.events", "world.effects" }
