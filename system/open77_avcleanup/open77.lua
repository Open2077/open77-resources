resource "open77_avcleanup"
version "1.0.0"
open77_version ">=0.0.1"
auto_start true
reload_policy "local"

shared_script "shared/sweep.lua"
server_script "server/main.lua"

permissions { "network.events", "world.vehicles", "vehicles.read" }