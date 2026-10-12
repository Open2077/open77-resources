resource "open77_contextmenu"
version "1.1.0"
open77_version ">=0.0.1"
auto_start true
reload_policy "reconnect"
client_scripts { "shared/config.lua", "client/registry.lua", "client/main.lua" }
web_ui_page "web/index.html"
web_ui_auto_create false
web_files { "web/**" }
permissions { "world.query", "input.actions", "players.controls", "local.events" }
