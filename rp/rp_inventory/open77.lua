resource "rp_inventory"
version "1.1.0"
auto_start true

-- Client-delivered packages this resource drives. All three ship a client half,
-- so a manifest that reaches the players may depend on them.
dependency "open77_uikit"
dependency "open77_contextmenu"
dependency "open77_loot"

-- rp_needs, open77_fuel, open77_rp_basics and rp_jobs are server-only (or not
-- guaranteed to run): they are reached through pcall'd exports, never declared.

permissions {
    "network.events",            -- RegisterNetEvent / TriggerServerEvent / TriggerClientEvent
    "database.access",           -- Open77.database / MySQL (rp_inventory_items, rp_inventory_stashes, rp_inventory_migrations)
    "world.loot",                -- Open77.loot.create/get/all/remove + onLootPickup/onLootRemoved
    "world.vehicles",            -- Open77.vehicles.getPlayerSeat / nearby (CHOOH2 can; the panel's read-only cargo view)
    "players.stats.read",        -- Open77.stats.get (full-health check before a heal)
    "players.stats.apply",       -- Open77.players.heal / restoreStamina
    "players.animations.read",   -- Open77.animations.current (hands-up check for /fouiller)
    "input.actions",             -- client: Open77.input.isCaptured (the panel never opens over a menu holding the keyboard)
}

-- open77_transactions (the transactions backend, `rp_inventory_backend transactions`) is
-- server-only, so it is NOT a dependency of this client-delivered manifest: it is reached
-- through Open77.exports.call, and every mutation refuses store_unavailable while it is not
-- running. It must be in resources.load when the transactions backend is selected.

shared_script "shared/items.lua"
shared_script "shared/schema.lua"     -- B1: definitions, metadata, catalogue pages (pure Lua)
client_script "client/main.lua"
client_script "client/catalogue.lua"  -- B1: the bounded, versioned client catalogue
server_script "server/accounts.lua"   -- B2: durable account ids (pure Lua)
server_script "server/facade.lua"     -- B2: the open77_transactions facade (write-behind + atomic ops)
server_script "server/migration.lua"  -- B2: one-shot legacy import per subject
server_script "server/main.lua"

-- The /inv panel: a WebUI page created by client/main.lua (no permission needed,
-- as rp_mdt / rp_phone prove); the server pushes its state, the page sends intents.
web_files { "web/**" }
