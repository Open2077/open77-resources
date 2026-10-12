-- tests/compat/txhost_wallet.lua: the test host of the open77_transactions resource in the B3
-- wallet suite (multihost.lua).
--
-- The coordinator runs as a resource of its own: the vendored final coordinator (Open77
-- 697e9e2f: vendor/open77_transactions, or OP77_TX_DIR), every server script of its manifest in
-- order, server/main.lua included, so the wallet adapters meet its real exports, gate, work
-- queue, policy (tunables writers / mint1..6), subject provider and events. This file is loaded
-- in that environment just before tests/compat/txshim.lua and main.lua (WW.txScripts). It only
-- provides what the server would: the database (the memory store, HOST.shared.txStore, which
-- survives a restart of this resource), the bridge's readiness, and the database's own pace.
--
-- Test controls (HOST.shared):
--   txStore     the memory store, i.e. the database (deferred: commits and fences complete on a
--               later pass of the pump below)
--   txPaused    stop the pump: hold a crash window open
--   txOnStop    what queued database work does when this resource stops: "detached" (it still
--               executes, nobody hears about it, DatabaseService.cs:262-266) or "discard" (it
--               never reached the database)
--   tx          the coordinator object main.lua created (assertions only)
-- The database answers (MySQL.ready) once HOST.dbMode is "sql" and the store is not down: a
-- configured database that is down at boot leaves the coordinator `starting`, as on a server.

local RESOURCE = GetCurrentResourceName()
local shared = HOST.shared
local store = shared.txStore
if not store then
    store = Open77TxMemoryStore.new({ deferred = true })
    shared.txStore = store
end

TxTestHost = {
    store = store,
    mysqlReady = function(fn)
        if shared.txNoDatabase then return false, "database_unavailable" end
        CreateThread(function()
            while HOST.dbMode ~= "sql" or store.down do Wait(250) end
            fn()
        end)
        return true
    end,
    onCoordinator = function(co) shared.tx = co end,
}

-- The database's pace: queued commits and fences complete on a later pass (D1).
CreateThread(function()
    while true do
        if not shared.txPaused then store:flush() end
        Wait(0)
    end
end)

AddEventHandler("onResourceStop", function(name)
    if name == RESOURCE then
        if shared.txOnStop == "discard" then store:discard() else store:runDetached() end
    end
end)
