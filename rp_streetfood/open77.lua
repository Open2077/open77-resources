-- rp_streetfood: the C4 example of the world-interaction campaign, a street-food stall.
-- Cook at a real grill -> the dish waits on the pass -> the cook hands it to a customer who
-- consents to the price -> the customer pays (one atomic sale: dish + price + tip) -> the customer
-- eats or drinks standing at the counter, on the go, or (optional) seated. Built on the wave-1
-- libraries: open77_actions (actions, station claim, eligibility + epoch guards), open77_transactions
-- (every custody change), Open77.playerInteractions (the consented hand-over), rp_jobs (the `cook`
-- job and its work epoch), rp_inventory (item definitions, stocking from pockets), rp_economy (the
-- sale) and, when running, rp_needs (hunger / thirst) and open77_furniture (seat poses).
-- Design and test script: docs/world-interaction/c4-streetfood.md. Status: built offline, NOT
-- proven in game.
resource "rp_streetfood"
version "0.1.0"
open77_version "*"

-- Opt-in: an operator lists it in resources.load. It coexists with rp_bar (README "Which one at a
-- venue"): both are food-and-drink service, they never share a counter or an item.
auto_start false

-- Least privilege, native by native (wiki/data/api.json):
--   players.interactions.control  Open77.playerInteractions.request / cancel (the hand-over with
--                                 consent; an offer is cancelled at once when the cook's work epoch moves)
--   players.interactions.read     Open77.playerInteractions.get (the sweep tells a lost offer from a live one)
--   world.props                   Open77.heldItems.hold (the drink in the cook's, then the customer's hand)
--   players.life.read             Open77.heldItems.hold (declared by the native) and Open77.players.get (alive)
--   network.events                Open77.heldItems.hold / release, Open77.notifications.send (toasts)
-- Animations are played by open77_actions (cook, order, eat, sit) and by the platform (the hand-over),
-- never by this resource: no players.animations.control. No database.access: every durable value lives
-- in open77_transactions (pantry, pass, pockets) or rp_economy (money).
permissions {
    "players.interactions.control",
    "players.interactions.read",
    "world.props",
    "players.life.read",
    "network.events",
}

-- Server scripts only, so server-only packages are fine as dependencies. rp_needs and
-- open77_furniture are optional (reached through pcall'd exports when they run).
dependency "open77_transactions >=0.1.0"        -- custody, receipts (A13)
dependency "open77_actions >=0.1.0"             -- actions, claims, guards (B5)
dependency "open77_player_interactions >=1.0.0" -- the consented hand-over
dependency "open77_notifications"               -- toasts (chat works without them)
dependency "rp_jobs >=2.1.0"                    -- the cook job, duty, work epoch (B4)
dependency "rp_inventory >=1.1.0"               -- definitions, stocking from pockets (B1/B2)
dependency "rp_economy >=2.0.0"                 -- the atomic sale (B3)

server_scripts {
    "server/config.lua",
    "server/model.lua",
    "server/ledger.lua",
    "server/ports.lua",
    "server/service.lua",
    "server/main.lua",
}
