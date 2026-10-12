resource "open77_ripperdoc_example"
version "0.1.0"
open77_version ">=0.0.1"
auto_start false
dependency "open77_cyberware >=0.1.0"
dependency "open77_interactions >=0.1.0"
server_script "server/config.lua"
server_script "server/main.lua"
client_script "client/main.lua"
permissions { "network.events", "players.life.read", "players.cyberware.define",
    "players.cyberware.read", "players.cyberware.manage" }
