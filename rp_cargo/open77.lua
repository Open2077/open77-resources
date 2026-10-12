-- rp_cargo: vehicle cargo layouts and the cargo service of the world-interaction pilot (row A9).
-- Custody is the A13 coordinator's (open77_transactions, account "veh:<plate>:cargo"); access is
-- rp_garage's (canAccess); this resource keeps the layouts, the slots and the props players see.
resource "rp_cargo"
version "0.1.0"
open77_version "*"
-- Opt-in: it needs the open77_transactions coordinator, which ships with auto_start false too.
auto_start false

-- world.props     : Open77.props.create / attach / remove / getAttachment / setAttachmentTransform
--                   (one prop per loaded object, attached to the vehicle; the lab crates)
-- world.vehicles  : Open77.vehicles.get / all (record, position, bucket, speed of the vehicle)
-- filesystem.read : Open77.io.readJson("layouts.json") (data/layouts.json)
permissions { "world.props", "world.vehicles", "filesystem.read" }

-- rp_garage: the plate of a runtime vehicle, its identity (describe) and canAccess. It ships a
-- client half, and this resource ships none, so the dependency is allowed either way.
-- open77_props: the client projection that draws attached props.
dependency "rp_garage"
dependency "open77_props >=0.1.0"
-- open77_transactions (Open77 resources/system, auto_start false, version 0.1.0 at 697e9e2f):
-- custody lives there, and this resource ships no client half, so the dependency is declared.
-- The server lists it in resources.load; its writers may keep this resource to `veh/cargo`.
dependency "open77_transactions >=0.1.0"

-- Loaded server-side only: nothing of this resource is delivered to players.
server_scripts {
    "shared/config.lua",
    "server/layout.lua",
    "server/service.lua",
    "server/main.lua",
}
