resource "open77_transactions"
version "0.1.0"
open77_version ">=0.0.1"

-- EXPERIMENTAL. The durable transaction coordinator of the world-interaction
-- campaign (row A13): reservations, one-transaction commits, idempotent
-- receipts, in-doubt fencing, world: containers. Author guide:
-- wiki/transactions.md; contract: docs/world-interaction/a13-transaction-contract.md.
--
-- Off by default: it owns the op77_tx_* tables and creates them on first
-- start, so it starts when an operator lists it in `resources.load` (or runs
-- `ensure open77_transactions`), never because it happens to be on disk.
auto_start false

-- Server only. Nothing here is shipped to clients: the shared model is
-- listed as a server script on purpose.
server_script "shared/model.lua"
server_script "server/policy.lua"
server_script "server/memory_store.lua"
server_script "server/sql_store.lua"
server_script "server/kvp_store.lua"
server_script "server/coordinator.lua"
server_script "server/main.lua"

-- Least privilege. `database.access` is the whole of it: the MySQL bridge for
-- the `sql` store. Open77.kvp (the lab store), tunables, convars, exports and
-- the host event bus take no capability.
permissions {
    "database.access",
}
