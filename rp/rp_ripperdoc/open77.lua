-- rp_ripperdoc: a ripperdoc clinic for a Night City RP server, on the world-interaction libraries.
-- Quote with consent (Open77.playerInteractions) -> ONE coordinator hold (price + implant from the
-- clinic's stock) -> the patient lies on the chair -> the ripperdoc's operate action (open77_actions)
-- -> Open77.cyberware.install exactly once -> the hold commits. Restock at a chrome dealer or from
-- players. Built offline; the live two-player script is in the README.
resource "rp_ripperdoc"
version "2.0.0"
open77_version "*"

-- Opt-in: it needs open77_actions and open77_transactions, which an operator lists in resources.load.
auto_start false

-- Platform packages this resource drives. Every one of them ships a client half, so a manifest
-- delivered to clients may depend on them. open77_transactions (server only) is NOT a dependency:
-- the boot waits for it (a client would refuse missing_dependency:open77_transactions). rp_jobs,
-- rp_inventory, rp_economy, rp_zones, rp_identity and open77_seating are reached through pcall'd
-- exports.
dependency "open77_actions >=0.1.0"             -- prompts, claims, the operate / lie / restock actions
dependency "open77_player_interactions >=1.0.0" -- the quote and the buy-back, with consent
dependency "open77_cyberware >=0.1.0"           -- Open77.cyberware.* (definitions, install, remove)
dependency "open77_uikit >=1.0.0"               -- the catalogue and order menus, the patient's bar
dependency "open77_contextmenu"                 -- ALT+click "Quote" (client)
dependency "open77_notifications"               -- toasts (chat works without them)

-- Least privilege, native by native (wiki/data/api.json):
--   network.events                RegisterNetEvent / TriggerClientEvent / Open77.notifications.send
--   players.cyberware.define      Open77.cyberware.define
--   players.cyberware.read        Open77.cyberware.current
--   players.cyberware.manage      Open77.cyberware.install / remove / cancel
--   players.hacking.define        Open77.hacking.define / defineIce / definePurge (the three hacking implants)
--   players.interactions.control  Open77.playerInteractions.request / cancel
--   players.interactions.read     Open77.playerInteractions.get / current
--   players.screenfx              Open77.effects.screen (the cyberpsychosis overlay)
--   players.life.read             Open77.players.get (alive, for an accepted patient)
--   database.access               Open77.database.* (the 1.x history table rp_ripperdoc_operations)
-- Animations are played by open77_actions (lie, operate, order) and by the platform (the buy-back
-- hand-over), never by this resource: no players.animations.control. Value lives in
-- open77_transactions, the in-flight journal in Open77.kvp, the history in SQL.
permissions {
    "network.events",
    "players.cyberware.define",
    "players.cyberware.read",
    "players.cyberware.manage",
    "players.hacking.define",
    "players.interactions.control",
    "players.interactions.read",
    "players.screenfx",
    "players.life.read",
    "database.access",
}

shared_script "shared/config.lua"
client_script "client/main.lua"
server_scripts {
    "server/model.lua",
    "server/ledger.lua",
    "server/ports.lua",
    "server/journal.lua",
    "server/service.lua",
    "server/main.lua",
}
