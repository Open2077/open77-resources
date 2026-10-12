-- rp_bank: bank accounts, ATMs and societies for a Night City RP server.
-- Version 2 (world-interaction row B3): a facade. Accounts and society funds are owned by the
-- open77_transactions coordinator and cached by rp_economy (the wallet facade); the ledger is the
-- coordinator journal. The 1.x tables are a read-only archive.
resource "rp_bank"
version "2.0.0"
open77_version "*"
auto_start true

-- database.access : Open77.database.* (reads the 1.x ledger archive rp_bank_transactions for the statement)
-- network.events  : RegisterNetEvent (ATM intent, chat:ready) on the server, TriggerServerEvent on the client
-- ui.vanilla.map  : Open77.blips.create, one map pin per ATM on the client
-- world.props     : Open77.props.create / remove, the terminal spawned next to every ATM ring (server)
-- players.animations.control : Open77.animations.play / stop, the typing pose while the ATM menu is open (Config.Stage)
permissions { "database.access", "network.events", "ui.vanilla.map", "world.props", "players.animations.control" }

-- open77_uikit  : server twins (context / input) drive the ATM menu, client drawText3D labels the ATMs
-- open77_worldui: one owned marker + prompt per ATM on the client
-- rp_economy and rp_jobs are server-only: a manifest delivered to clients may not depend on them,
-- so their exports are reached through pcall instead of a dependency line. Without rp_economy (or
-- without its coordinator) every operation is refused: wallet_unavailable / bank_not_ready.
dependency "open77_uikit >=1.0.0"
dependency "open77_worldui >=0.1.0"

shared_script "config.lua"
server_script "server/main.lua"
client_script "client/main.lua"
