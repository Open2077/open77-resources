resource "open77_reflex"
version "0.1.0"
open77_version ">=0.0.1"
auto_start true
reload_policy "local"
dependency "open77_effects >=0.2.0"
client_script "client/main.lua"
server_script "server/presentation.lua"
permissions { "network.events", "network.client", "input.actions", "player.reflex.overdrive", "player.state.read", "world.effects", "ui.nameplates" }
