resource "open77_interactions"
version "0.1.0"
open77_version ">=0.0.1"
auto_start true

-- Replacing a live CEF surface while gameplay is running has historically
-- caused unstable transitions. Interaction UI updates are applied on reconnect.
reload_policy "reconnect"

client_script "client/main.lua"
server_script "server/main.lua"

web_ui_page "web/index.html"
web_ui_auto_create false
web_files { "web/**" }

-- input.actions   the action keys a prompt reads.
-- network.events  the server half declares targets; the client half receives
--                 them. Both directions are ordinary authenticated net events.
-- world.query     `Open77.world.nearby`, the only source of an RTTI class name
--                 for `model` and `class` targets.
-- vehicles.read   `Open77.vehicles.all`, which is what `globalVehicle` targets
--                 enumerate -- with the vehicle's TweakDB record and door mask.
-- npcs.read       `Open77.npcs.all`, the Open77-managed half of `globalNpc`.
permissions {
    "input.actions",
    "network.events",
    "world.query",
    "vehicles.read",
    "npcs.read",
}
