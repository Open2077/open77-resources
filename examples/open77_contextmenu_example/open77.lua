resource "open77_contextmenu_example"
version "1.0.0"
dependency "open77_contextmenu"
auto_start false
client_script "client.lua"
permissions { "local.events" }
