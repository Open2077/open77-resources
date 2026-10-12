resource "open77_worldui"
version "0.1.0"
open77_version ">=0.0.1"
auto_start true
reload_policy "local"

dependency "open77_interactions >=0.1.0"

client_script "client/main.lua"

permissions {
    "world.markers"
}
