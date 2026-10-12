resource "polyzone"
version "1.0.0"
open77_version ">=0.0.1"
auto_start true
reload_policy "local"
client_script "client/main.lua"
server_script "server/main.lua"
-- Library code explicitly published for require('@polyzone') in dependent VMs.
files { "init.lua", "geometry.lua", "debug.lua", "serialize.lua", "client.lua", "BoxZone.lua", "CircleZone.lua", "EntityZone.lua", "ComboZone.lua" }
web_ui_page "web/index.html"
web_ui_auto_create false
web_files { "web/index.html", "web/editor.js", "web/editor.css" }
permissions { "world.query", "world.debug", "ui.vanilla.map", "input.actions", "clipboard.write", "network.events", "local.events", "filesystem.read", "filesystem.write", "acl.read" }
