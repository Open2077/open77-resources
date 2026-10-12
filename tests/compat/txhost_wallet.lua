-- tests/compat/txhost_wallet.lua: a TEST stand-in for open77_transactions' runtime wiring (B3 suite).
--
-- The A13 prototype (vendor/open77_transactions or OP77_TX_DIR) is a pure-Lua coordinator in
-- continuation style with no server/main.lua: no exports, no manifest. This file is loaded after
-- shared/model.lua, server/memory_store.lua and server/coordinator.lua, in the same multihost
-- environment, and publishes the contract's export surface (a13-transaction-contract.md §7.2)
-- the way the wave-1 server/main.lua is expected to: every mutating call yields until the store
-- answers; failures follow `nil, reason, info`.
--
-- Exports that §7.2 does not list but the wallet adapters need are marked NEED: they are the
-- coordinator API requests of docs/world-interaction/b3-wallet.md §8.
--
-- Test controls (HOST.shared): txStore (the memory store, i.e. the database; it survives a
-- restart of this resource), txAcl (resource -> namespaces), txPaused (stop the pump to hold a
-- crash window), txOnStop ("detached": queued work still executes and nobody hears about it,
-- DatabaseService.cs:262-266; "discard": it never reached the database), txMode (health's store
-- label), txCalls (count per export).

local RESOURCE = GetCurrentResourceName()
local shared = HOST.shared
local store = shared.txStore
if not store then
    store = Open77TxMemoryStore.new({ deferred = true })
    shared.txStore = store
end
shared.txCalls = shared.txCalls or {}

local coordinator = Open77TxCoordinator.new({
    store = store,
    now = function() return math.floor(HOST.now * 1000) end,
    serverTag = "lab",
    acl = function(resource, namespace)
        local acl = shared.txAcl
        if not acl then return true end
        local allowed = acl[resource]
        return allowed == true or (type(allowed) == "table" and allowed[namespace] == true)
    end,
    onCommitted = function(receipt, accounts)
        TriggerEvent("open77_transactions:committed", receipt.opId, receipt.kind, accounts)
    end,
})
shared.tx = coordinator

-- Continuation -> yielding export body.
local function wait(start)
    local box = {}
    start(function(...) box.res = table.pack(...) end)
    while not box.res do Wait(0) end
    return table.unpack(box.res, 1, box.res.n)
end

local function publish(name, fn)
    exports(name, function(...)
        shared.txCalls[name] = (shared.txCalls[name] or 0) + 1
        return fn(...)
    end)
end

-- NEED: readiness. The contract tracks database health itself (D5 hides outages) but lists no
-- export for it; adapters must refuse while it is false (a13 §4.1 adapter rule).
publish("health", function()
    if store.down then
        return { ready = false, store = shared.txMode or "memory", reason = "store_unavailable" }
    end
    return { ready = true, store = shared.txMode or "memory" }
end)

publish("define", function(items) return coordinator:define(items, GetInvokingResource()) end)
publish("open", function(id, props) return wait(function(done) coordinator:open(id, props, done) end) end)
publish("read", function(id) return coordinator:read(id) end)
publish("reserve", function(spec)
    local caller = GetInvokingResource()
    return wait(function(done) coordinator:reserve(spec, caller, done) end)
end)
publish("commit", function(opId, final)
    local caller = GetInvokingResource()
    return wait(function(done) coordinator:commit(opId, final, caller, done) end)
end)
publish("cancel", function(opId, reason) return coordinator:cancel(opId, reason, GetInvokingResource()) end)
publish("transfer", function(spec)
    local caller = GetInvokingResource()
    return wait(function(done) coordinator:transfer(spec, caller, done) end)
end)
publish("status", function(opId, options)
    return wait(function(done) coordinator:status(opId, options, done) end)
end)
publish("newOpId", function() return coordinator:newOpId() end)

-- NEED: the subject provider (a13 §12 decision 5). Default = the account identifier; a table
-- { identifier = guid } maps an offline identifier the same way. Non-yielding (called inline).
publish("subjectOf", function(who)
    if type(who) == "table" then
        if type(who.identifier) == "string" and who.identifier ~= "" then return who.identifier end
        return nil, "invalid_subject"
    end
    local id = tonumber(who)
    if not id then return nil, "invalid_player" end
    local identifier = Open77.players.identifier(id)
    if not identifier then return nil, "player_not_found" end
    return identifier
end)

-- The pump: completions arrive on a later pass, like the bridge's per-resource queue (D1).
CreateThread(function()
    while true do
        if not shared.txPaused then
            store:flush()
            coordinator:tick()
        end
        Wait(0)
    end
end)

AddEventHandler("onResourceStop", function(name)
    if name == RESOURCE then
        if shared.txOnStop == "discard" then store:discard() else store:runDetached() end
    else
        coordinator:onResourceStop(name)
    end
end)
