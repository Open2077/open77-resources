resource "open77_cyberware_lab"
version "0.1.0"
open77_version ">=0.0.1"
auto_start false
reload_policy "reconnect"
server_script "server/config.lua"
server_script "server/jackets.lua"
server_script "server/load.lua"
server_script "server/main.lua"
server_script "server/ground-slam.lua"
server_script "server/dash.lua"
server_script "server/reflex.lua"
server_script "server/panel.lua"
server_script "server/freeroam.lua"
dependency "open77_equipment >=0.2.0"
dependency "open77_dash >=0.1.0"
dependency "open77_reflex >=0.1.0"
client_script "client/main.lua"
client_script "client/panel.lua"
web_ui_page "web/index.html"
web_ui_auto_create false
web_files { "web/**" }
permissions { "local.events", "combat.config", "players.life.read", "players.life.control", "players.life.revive", "players.life.kill", "network.events", "world.effects",
    "player.cyberware.read", "player.cyberware.project", "players.cyberware.define",
    "players.cyberware.read", "players.cyberware.manage", "players.damage.read", "players.damage.apply", "players.motion.control", "players.motion.read",
    "players.stats.read", "players.stats.apply", "players.abilities.define", "players.abilities.manage", "players.abilities.read", "players.dash.define", "players.dash.manage", "players.dash.read",
    "players.reflex.define", "players.reflex.manage", "players.reflex.read" }
