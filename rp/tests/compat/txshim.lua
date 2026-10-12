-- tests/compat/txshim.lua: the ONE test seam of the vendored open77_transactions resource.
--
-- Loaded in the coordinator's own environment, after every server script of its manifest except
-- server/main.lua, and before it. It changes nothing in the coordinator's logic; it only hands
-- main.lua the test's in-memory store (server/memory_store.lua, with its fault injection) where
-- the server would build the SQL store over the MySQL bridge, or the lab store over the KVP file,
-- and it records the coordinator object so a scenario can assert on it.
--
-- The host defines `TxTestHost` in the same environment first:
--   store          the memory store (the "database"; it outlives a coordinator restart)
--   mysqlReady(fn) the bridge's MySQL.ready: accepted -> fn() runs once the database answers;
--                  false, reason when no database is configured
--   onCoordinator(co)  optional, called with the coordinator main.lua creates

local host = assert(TxTestHost, "txshim: the host must define TxTestHost before this file")

-- `sql` mode: Open77TxSql.newStore(MySQL, options) -> the test store, as the SQL store would be.
Open77TxSql.newStore = function()
    return host.store
end

-- `lab_kvp` mode (tunable store = lab_kvp, convar open77_transactions_lab 1, unmastered host):
-- the same store, reported as hydrated from nothing.
Open77TxKvpStore.new = function()
    local s = host.store
    s.hydrated = s.hydrated or 0
    return s
end

local realNew = Open77TxCoordinator.new
Open77TxCoordinator.new = function(options)
    local co = realNew(options)
    host.coordinator = co
    if host.onCoordinator then host.onCoordinator(co) end
    return co
end

MySQL = {
    ready = function(fn)
        return host.mysqlReady(fn)
    end,
}
