resource "open77_cyberarena_example"
version "0.1.0"
open77_version ">=0.0.1"
auto_start false
dependency "open77_cyberware >=0.1.0"
server_script "server/config.lua"
server_script "server/main.lua"
permissions { "network.events", "combat.config", "combat.scope.control", "world.vehicles",
    "players.life.read", "players.stats.read", "players.stats.apply",
    "players.cyberware.define", "players.cyberware.read", "players.cyberware.temporary" }
