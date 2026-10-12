resource "open77_wardrobe_ui"
version "0.1.1"
open77_version ">=0.0.1"
auto_start true
reload_policy "reconnect"
dependencies { "open77_appearance >=0.1.0", "open77_equipment >=0.2.0", "open77_wardrobe >=0.1.0" }
client_script "client/favorites.lua"
client_script "client/main.lua"
web_ui_page "web/index.html"
web_ui_auto_create false
web_files { "web/**" }
permissions { "local.events", "network.events", "network.client", "input.actions", "player.equipment.read", "player.equipment.edit", "camera.preview", "players.life.read" }
