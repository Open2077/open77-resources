-- rp_economy: server-authoritative wallet for an RP server.
-- Version 2: a facade over the open77_transactions coordinator, which owns every balance
-- (world-interaction row B3). Server only: no client script.
resource "rp_economy"
version "2.0.0"
open77_version "*"
auto_start true

-- network.events : required by RegisterNetEvent (the chat:ready suggestion hook)
--                  and by Open77.notifications.send (the toast that accompanies /money).
-- database.access: Open77.database.* for the one-shot import of the 1.x tables and the
--                  read-only archive (rp_economy_wallets, rp_bank_*), plus rp_wallet_migration.
--                  Balances are NOT stored here any more, and there is no KVP fallback.
permissions { "network.events", "database.access" }

-- open77_transactions (Open77 repository, resources/system, auto_start false) must be loaded
-- through resources.load. It is reached at runtime, not through a dependency line, so that a
-- missing coordinator is reported (`store_unavailable`, log line) instead of rp_economy not
-- starting at all. The coordinator ships its manifest (0.1.0 at Open77 697e9e2f); a server that
-- wants the hard start order may add:
--   dependency "open77_transactions >=0.1.0"

server_script "server/config.lua"
server_script "server/tx.lua"
server_script "server/mint.lua"
server_script "server/migrate.lua"
server_script "server/wallets.lua"
server_script "server/main.lua"
