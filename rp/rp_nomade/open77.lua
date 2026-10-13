-- rp_nomade: Aldecaldos smuggling runs for the `nomade` job. Take a run at the camp's board, carry
-- contraband crates into a truck bed, drive past the NCPD checkpoints into Night City, hand the
-- crates to a fence (or to a player who accepts), get paid minus the camp's cut. Built on the
-- world-interaction libraries: open77_actions (prompts, bars, carrying), open77_containers (the
-- crates: keyed, durable, presented by open77_actions), open77_transactions (every custody move),
-- rp_garage + rp_cargo (truck keys and beds), rp_economy (pay, fines), rp_jobs (duty, epochs).
resource "rp_nomade"
version "2.0.0"
open77_version "*"

-- Opt-in: it needs the world-interaction libraries, which do not start on their own either.
auto_start false

-- Least privilege, native by native (wiki/data/api.json):
--   network.events                 RegisterNetEvent / TriggerClientEvent (the navigation push),
--                                  Open77.notifications.send (toasts)
--   world.vehicles                 Open77.vehicles.all / get / getPosition / getDriver / getHealth
--                                  (the truck near a bay, at a checkpoint, wrecked)
--   world.npcs                     Open77.npcs.create / remove (the fences, presentation only)
--   players.wanted                 Open77.players.setWanted (heat after a checkpoint search)
--   players.interactions.control   Open77.playerInteractions.request / cancel (a crate handed to
--                                  a player, a driver consenting to a search)
--   players.interactions.read      Open77.playerInteractions.get (the sweep tells a lost offer)
--   ui.vanilla.map                 client: Open77.blips (destination, camp and checkpoint pins, GPS)
--   world.props                    Open77.props.create / remove (the camp's set dressing only)
-- Carried crates are open77_actions' props, bed crates rp_cargo's. No database.access: every
-- durable value lives in open77_transactions or open77_containers.
permissions {
    "network.events", "world.vehicles", "world.npcs", "world.props", "players.wanted",
    "players.interactions.control", "players.interactions.read", "ui.vanilla.map",
}

-- This manifest ships a client script, so it names only dependencies that ship a client half.
-- open77_transactions, rp_cargo and rp_economy are server-only: the boot waits for them instead
-- (a client would refuse this resource with missing_dependency otherwise).
dependency "open77_actions >=0.1.0"
dependency "open77_containers >=0.2.0"
dependency "open77_player_interactions >=1.0.0"
dependency "open77_notifications"
dependency "rp_jobs >=2.1.0"
dependency "rp_inventory >=1.1.0"
dependency "rp_garage"

server_scripts {
    "server/config.lua",
    "server/model.lua",
    "server/ledger.lua",
    "server/ports.lua",
    "server/service.lua",
    "server/main.lua",
}
client_script "client/main.lua"
