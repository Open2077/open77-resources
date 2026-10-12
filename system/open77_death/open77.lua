resource "open77_death"
version "0.1.0"
open77_version ">=0.0.1"
auto_start true
reload_policy "local"

client_script "client/main.lua"

permissions { "players.life.read" }
