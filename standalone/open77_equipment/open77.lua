resource "open77_equipment"
version "0.2.1"
open77_version ">=0.0.1"
auto_start true
reload_policy "local"

client_scripts { "config.lua", "client/main.lua" }
dependency "open77_appearance >=0.1.0"

permissions {
    "network.events",
    "player.equipment.read",
    "player.equipment.edit",
    "puppets.present",
    "players.controls"
}
