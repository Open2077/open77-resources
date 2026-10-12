-- rp_salvage: the C1 salvage pilot of the world-interaction campaign.
-- Salvage a wreck -> material crate -> carry -> truck -> buyer, built on the wave-1 libraries
-- instead of private state: open77_actions (actions, claims, carry), open77_containers (wreck
-- nodes with charges and regrowth), open77_transactions (every custody change), rp_jobs (duty
-- and the work epoch), rp_inventory (item definitions, tool instances), rp_garage + rp_cargo
-- (truck access and bed slots) and rp_economy (one atomic sale with the society share).
-- Design: docs/world-interaction/c1-salvage.md. Status: built offline, NOT proven in game.
resource "rp_salvage"
version "0.1.1"
open77_version "*"

-- Operator-chosen: a server runs EITHER rp_salvage OR rp_ferrailleur, never both (two scrap
-- economies, plan decision 5). rp_salvage never starts by itself: list it in resources.load
-- (and remove rp_ferrailleur from that list). README.md "Enable it on a server".
auto_start false

-- Least privilege, native by native (wiki/data/api.json):
--   world.props      Open77.props.create / attach / remove: the crowbar shown in the right hand
--                    while prying (the only prop this resource owns; crates are open77_actions'
--                    props, bed crates rp_cargo's)
--   world.vehicles   Open77.vehicles.all / get: the truck next to a bay or a player
--   world.npcs       Open77.npcs.create / remove: the buyer standing at the counter (optional)
--   network.events   Open77.notifications.send: the toasts that accompany chat lines
-- Open77.chat.send, Open77.players.position / get / identifier, exports and RegisterCommand
-- need no capability. No database.access: every durable value lives in open77_transactions
-- (crates, materials, tools, money) or open77_containers (node charges).
permissions { "world.props", "world.vehicles", "world.npcs", "network.events" }

-- This resource ships nothing to clients (server scripts only), so it may depend on server-only
-- packages. Every one of them is part of the loop; a missing one would leave it half-working.
dependency "open77_transactions >=0.1.0"   -- custody, receipts (A13)
dependency "open77_actions >=0.1.0"        -- actions, claims, carry (B5/A5)
dependency "open77_containers >=0.2.0"     -- wreck nodes: keyed, charges + regrowth + refill (A6)
dependency "open77_notifications"          -- toasts (client package; chat works without it)
dependency "rp_jobs >=2.1.0"               -- duty, eligibility, work epoch (B4)
dependency "rp_inventory >=1.1.0"          -- definitions, tool instances (B1/B2, transactions backend)
dependency "rp_economy >=2.0.0"            -- the atomic sale (B3)
dependency "rp_garage"                     -- vehicle access (A9)
dependency "rp_cargo >=0.1.0"              -- bed slots (A9)

server_scripts {
    "server/config.lua",
    "server/model.lua",
    "server/ledger.lua",
    "server/ports.lua",
    "server/service.lua",
    "server/main.lua",
}
