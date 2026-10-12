-- rp_trauma: Trauma Team, the RP death and Trauma Team International for a Night City RP
-- server. Absorbs rp_medic (/soin /reanimer /911 /medic) and adds the "down" state, the
-- hospital respawn with its bill, the medic ALT+click actions, the Trauma Team AV, and the
-- Trauma Team International service: Silver / Gold / Platinum plans sold at kiosks, a call
-- per downed player dispatched to the on-duty medics, Stabilise and Evacuate actions on the
-- body (open77_actions), and every charge through the transaction coordinator.
resource "rp_trauma"
version "2.0.0"
open77_version "*"
auto_start true

-- All three ship a client half, so a manifest delivered to clients may depend on them.
--   open77_uikit         : progress bars on the medic and the /contrat menu (server twins)
--   open77_contextmenu   : ALT+click "Stabilise" / "Revive" on another player (client)
--   open77_notifications : toasts (Open77.notifications.send on the server)
dependency "open77_uikit >=1.0.0"
dependency "open77_contextmenu"
dependency "open77_notifications"
--   open77_props         : the client projection that draws the injector / kit while a medic works
dependency "open77_props >=0.1.0"

-- rp_jobs, rp_inventory and rp_identity are reached through pcall: their READMEs ask a
-- resource that ships a client script not to declare them. The Trauma Team service also
-- needs open77_transactions (server-only: a client-delivered manifest cannot depend on it),
-- open77_actions and rp_inventory; it waits for them and starts once they run (README Setup).
-- Money moves through open77_transactions only (server/ledger.lua), never rp_bank/rp_economy
-- synchronous exports; rp_economy sees the wallets change through the coordinator's events.

-- Every permission below is the one the card of a native this resource calls requires:
--   players.stats.read    Open77.stats.get (server: fees / client: the Stabilise predicate)
--   players.stats.apply   Open77.stats.setHealth / restoreHealth / setHealthRegenEnabled
--   players.life.read     Open77.players.isDead / getLifeState (both sides)
--   players.life.revive   Open77.players.revive (medic revive of a dead player)
--   players.life.respawn  Open77.players.respawn (/respawn while the body is still dead)
--   players.life.freeze   Open77.players.setFrozen (the "down" hold)
--   players.teleport      Open77.players.teleport (back to the death spot, to the hospital)
--   world.vehicles        Open77.vehicles.create / remove / warpPlayerIntoVehicle (the AV)
--   network.events        RegisterNetEvent / TriggerClientEvent / Open77.notifications.send,
--                         TriggerServerEvent on the client
--   database.access       Open77.database.* (the one-time import of the 1.x rp_trauma_contracts
--                         and rp_trauma_bills; plans and invoices live in the coordinator)
--   input.blockAll        Open77.input.blockAll (client: a down player cannot act)
--   ui.vanilla.map        Open77.blips.* (client: the down-player pin on a medic's map)
--   players.animations.control  Open77.animations.play / stop (the medic's kneel, the wounded pose of a
--                         down player, the /911 dial; Config.Stage)
--   players.animations.read     Open77.animations.current (a held body's wounded pose is played
--                         again when it stopped)
--   world.props           Open77.props.create / attach / remove (the injector and kit shown while treating)
permissions {
    "players.animations.control",
    "players.animations.read",
    "world.props",
    "players.stats.read",
    "players.stats.apply",
    "players.life.read",
    "players.life.revive",
    "players.life.respawn",
    "players.life.freeze",
    "players.teleport",
    "world.vehicles",
    "network.events",
    "database.access",
    "input.blockAll",
    "ui.vanilla.map",
}

shared_script "shared/config.lua"
server_scripts {
    "server/config.lua",
    "server/model.lua",
    "server/ledger.lua",
    "server/ports.lua",
    "server/service.lua",
    "server/main.lua",
}
client_script "client/main.lua"
