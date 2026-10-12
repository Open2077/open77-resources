-- rp_chooh2: the CHOOH2 production chain. Biotechnica farmhands harvest corn into crates at the
-- protein farm north of Northside, haulers carry the crates to a truck and drive them to the
-- Petrochem tank farm at the North Sunrise Oil Field, the operators refine the corn into CHOOH2
-- canisters, and the canisters are sold to the fuel depot or poured into a car's tank.
-- Built on the job libraries: open77_actions (prompts, timed actions, claims, carrying),
-- open77_containers (depletable corn rows), open77_transactions (every custody change),
-- rp_jobs (duty, work epoch), rp_inventory (item definitions), rp_garage + rp_cargo (truck keys
-- and bed slots), rp_economy (the canister sale) and open77_fuel (the tank of the refuelled car).
resource "rp_chooh2"
version "0.1.0"
open77_version "*"

-- Opt-in: an operator lists it in resources.load (README "Setup").
auto_start false

-- Least privilege, native by native (wiki/data/api.json):
--   world.vehicles   Open77.vehicles.all / get: the truck next to a bay, the car being refuelled
--   world.npcs       Open77.npcs.create / remove: the depot clerk at the counter (optional)
--   network.events   Open77.notifications.send: the toasts that accompany chat lines
-- Open77.chat.send, Open77.players.position / get / identifier, exports, TriggerEvent and
-- RegisterCommand need no capability. No database.access: every durable value lives in
-- open77_transactions (crates, corn, stashes, canisters, money) or open77_containers (rows).
permissions { "world.vehicles", "world.npcs", "network.events" }

-- Server scripts only, so it may depend on server-only packages. open77_fuel is optional: the
-- refuel step says so and refuses (fuel_unavailable) when it does not run.
dependency "open77_transactions >=0.1.0"   -- custody, receipts
dependency "open77_actions >=0.1.0"        -- actions, claims, carry
dependency "open77_containers >=0.2.0"     -- corn rows: keyed nodes, charges + regrowth + refill
dependency "open77_notifications"          -- toasts (chat works without it)
dependency "rp_jobs >=2.1.0"               -- duty, eligibility, work epoch
dependency "rp_inventory >=1.1.0"          -- definitions (transactions backend)
dependency "rp_economy >=2.0.0"            -- the atomic canister sale
dependency "rp_garage"                     -- truck keys
dependency "rp_cargo >=0.1.0"              -- bed slots

server_scripts {
    "server/config.lua",
    "server/model.lua",
    "server/ledger.lua",
    "server/ports.lua",
    "server/service.lua",
    "server/main.lua",
}
