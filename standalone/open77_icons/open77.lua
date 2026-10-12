resource "open77_icons"
version "1.0.0"
open77_version ">=0.0.1"

auto_start false
reload_policy "local"
client_scripts { "client/catalogue.lua", "client/main.lua" }
permissions { "ui.vanilla.map" }
files { "icons/lucide/*.svg", "LICENSE-LUCIDE.txt", "catalogue.json" }
