resource "open77_interactions"
-- 0.1.0 client interactions and client targets; 0.2.0 server `define`
-- declarations (shipped while the manifest still said 0.1.0, which is why
-- wiki/interactions.md asked for ">=0.2.0" against a 0.1.0 resource); 0.3.0
-- `prop` targets and the cross-resource prop grant contract
-- (grantProp / requestProp / answerPropRequest / propAccess).
version "0.3.0"
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
-- world.props     server: `Open77.props.get` (who owns a prop a `prop` target
--                 names) and `onPropRemoved`. Read only: this resource creates
--                 no prop. Prop targets resolve positions on the client from the
--                 `open77_props` projection mirror (its `get` export), which is
--                 deliberately NOT a dependency: without it, prop targets
--                 simply match nothing.
permissions {
    "input.actions",
    "network.events",
    "world.query",
    "vehicles.read",
    "npcs.read",
    "world.props",
}
