resource "open77_parkour_example"
version "0.1.0"
open77_version ">=0.0.1"
auto_start false
reload_policy "reconnect"
dependency "open77_cyberware >=0.1.0"
dependency "open77_dash >=0.1.0"
dependency "open77_equipment >=0.2.0"
server_script "server/config.lua"
server_script "server/main.lua"
permissions { "network.events", "players.dash.define", "players.dash.manage",
    "players.dash.read", "players.cyberware.read" }
