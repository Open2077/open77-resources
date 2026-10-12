resource "open77_elevators"
version "1.0.0"
open77_version ">=0.0.1"
auto_start true
reload_policy "local"

server_script "server/main.lua"
client_script "client/main.lua"

permissions {
    "network.events",
    "world.elevators",
    "elevators.read",
    "elevators.request"
}
