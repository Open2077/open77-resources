resource "open77_vehicles"
version "0.3.2"
open77_version ">=0.0.1"
auto_start true
reload_policy "local"

client_script "client/main.lua"
server_script "server/main.lua"

permissions { "network.events", "world.vehicles", "vehicles.read" }
