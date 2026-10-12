resource "open77_hacking_lab"
version "0.4.0"
open77_version ">=0.0.1"
auto_start false
reload_policy "local"
dependency "open77_hacking >=0.1.0"
server_scripts { "server/config.lua", "server/main.lua" }
permissions { "network.events", "players.cyberware.define", "players.cyberware.read", "players.cyberware.manage",
    "players.hacking.define", "players.hacking.read", "players.hacking.activate", "players.hacking.policy",
    "combat.config", "combat.scope.control", "players.life.read", "players.life.kill",
    "players.life.respawn", "players.stats.read", "players.statuses.apply" }
