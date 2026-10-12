resource "open77_dash"
version "0.1.0"
open77_version ">=0.0.1"
auto_start true
reload_policy "local"
client_script "client/main.lua"
permissions { "network.events", "network.client", "input.actions", "player.dash.project", "player.state.read", "camera.read", "player.travel" }
