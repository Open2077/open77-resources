-- rp_techie: the techie / weaponsmith job of the RP pack (wave 3, W3-3).
-- Buy salvage parts (from a scrapper, with consent, or from the parts dealer) -> strip them at a
-- real workbench into components that wait on the workshop's tray (durable) -> assemble weapon mods
-- and cyberware components -> sell them to a shop, to another player with consent, or to the
-- ripperdoc. Built on the wave-1 libraries: open77_actions (bench actions, one player per bench,
-- job / grade / duty guards), open77_transactions (every custody change, one operation per stage),
-- Open77.playerInteractions (consented trades), rp_jobs (the `techie` job), rp_inventory (item
-- definitions) and rp_economy (shop sales: one atomic sale with the society share).
resource "rp_techie"
version "0.1.0"
open77_version "*"

-- Opt-in: an operator lists it in resources.load (README "Setup").
auto_start false

-- Least privilege, native by native (wiki/data/api.json):
--   players.interactions.control  Open77.playerInteractions.request / cancel (consented trades)
--   players.interactions.read     Open77.playerInteractions.get (the sweep tells a lost offer from a live one)
--   network.events                Open77.notifications.send (the toasts beside chat lines)
-- Animations are played by open77_actions, never by this resource (no players.animations.control).
-- No database.access: every durable value lives in open77_transactions (tray, pockets, wallets).
permissions {
    "players.interactions.control",
    "players.interactions.read",
    "network.events",
}

-- Server scripts only, so server-only packages are fine as dependencies. open77_uikit (the bench
-- menu) is optional: reached through a pcall'd export when it runs.
dependency "open77_transactions >=0.1.0"        -- custody, receipts
dependency "open77_actions >=0.1.0"             -- bench actions, claims, guards
dependency "open77_player_interactions >=1.0.0" -- consented trades
dependency "open77_notifications"               -- toasts (chat works without them)
dependency "rp_jobs >=2.1.0"                    -- the techie job, grade, duty, work epoch
dependency "rp_inventory >=1.1.0"               -- item definitions
dependency "rp_economy >=2.0.0"                 -- shop sales

server_scripts {
    "server/config.lua",
    "server/model.lua",
    "server/ledger.lua",
    "server/ports.lua",
    "server/service.lua",
    "server/main.lua",
}
