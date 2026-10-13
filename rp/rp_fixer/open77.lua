-- rp_fixer: the fixers' contract board, the hub that ties the RP jobs together.
-- Fixer NPCs (the Afterlife, Wakako's, Regina's corner) and fixers on duty post contracts with
-- an escrowed reward: deliveries (carry a crate from A to B), retrievals (bring a named item),
-- job orders (satisfied by other jobs' `rp:job:completed` events) and cyberpsycho bounties (a
-- hostile server NPC whose death pays its killer). Runners take them at any fixer point, are
-- paid out of escrow in one operation, and earn a reputation that unlocks better contracts.
-- Contracts survive a restart (SQL), expire on schedule and refund the poster.
resource "rp_fixer"
version "2.0.0"
open77_version "*"

-- Opt-in: an operator lists it in resources.load after open77_transactions, open77_actions and
-- rp_economy (README "Setup").
auto_start false

-- Least privilege, native by native (wiki/data/api.json):
--   database.access  Open77.database.*: rp_fixer_contracts, rp_fixer_reputation, rp_fixer_rep_log,
--                    rp_fixer_gigs (history)
--   world.npcs       Open77.npcs.create / remove / get / setAttitude / tasks.guard / tasks.attack /
--                    tasks.hold: the cyberpsychos and the contacts at the boards
--   network.events   TriggerClientEvent / RegisterNetEvent (map pins), Open77.notifications.send
--   ui.vanilla.map   Open77.blips.* on the client: the fixer points, the runner's objectives, the GPS
-- Prompts, the crate prop and every animation belong to open77_actions; money to rp_economy;
-- goods to open77_transactions. No world.props, no players.animations.control.
permissions { "database.access", "world.npcs", "network.events", "ui.vanilla.map" }

-- Both ship a client half, so a manifest delivered to clients may depend on them.
dependency "open77_actions >=0.1.0"   -- the board and hand-over prompt, the delivery crate
dependency "open77_uikit >=1.0.0"     -- the board menu and dialogs (server twins)
-- open77_transactions, rp_economy, rp_jobs and rp_inventory are server-only: a manifest
-- delivered to clients cannot depend on them (missing_dependency). The boot waits for them.

server_scripts {
    "server/config.lua",
    "server/model.lua",
    "server/ledger.lua",
    "server/store.lua",
    "server/ports.lua",
    "server/service.lua",
    "server/main.lua",
}
client_script "client/main.lua"
