resource "open77_appearance"
version "0.1.0"
open77_version ">=0.0.1"
auto_start true
reload_policy "local"

client_script "client/main.lua"
server_script "server/catalog.lua"
server_script "server/presentation.lua"
server_script "server/main.lua"

permissions {
    "network.events",
    "player.appearance.read",
    "player.equipment.read",
    "player.appearance.edit",
    "puppets.present",
    "database.access",
    "players.cyberware.identity"
}
