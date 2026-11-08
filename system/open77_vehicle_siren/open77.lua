resource "open77_vehicle_siren"
version "1.0.0"
open77_version ">=0.0.1"

auto_start true
reload_policy "local"

shared_script "config.lua"
client_script "client/main.lua"
server_script "server/main.lua"

permissions { "input.actions", "network.events", "vehicles.read", "world.vehicles" }
