-- rp_economy / server/tx.lua: the client of the open77_transactions coordinator.
--
-- Everything here that talks to the coordinator yields (Open77.exports.call + await), so it
-- runs only in threads, handlers or async exports, never inside a synchronous export. The one
-- inline call is the subject provider (subjectOf), which the coordinator keeps non-yielding.
--
-- A rejected Promise (export_timeout, export_resource_stopped, promise_cancelled, a raised
-- coordinator) is NOT a failure: the coordinator may have committed. It is reported as
-- `in_doubt` and resolved through status(opId, { resolve = true }) (A13 §5, finding 6).

Tx = {
    healthy = false,
    reason = "coordinator_starting",
    store = nil,
    warned = {},
    listeners = {},
}

local function log(fmt, ...)
    print(("[rp_economy] " .. fmt):format(...))
end

local function warnOnce(key, fmt, ...)
    if Tx.warned[key] then return end
    Tx.warned[key] = true
    Open77.log.warn(("[rp_economy] " .. fmt):format(...))
end

-- Calls a coordinator export and awaits it. Returns its values, or nil, reason, info.
function Tx.call(name, ...)
    local promise, why = Open77.exports.call(EconomyConfig.coordinator, name, ...)
    if not promise then
        return nil, "coordinator_unavailable", { retryable = true, detail = why, dispatched = false }
    end
    local a, b, c = promise:await()
    local status = promise:status()
    if status == "rejected" or status == "cancelled" then
        return nil, "in_doubt", { retryable = true, detail = b, exportLost = true }
    end
    return a, b, c
end

-- Durable owner key of a connected player, from the coordinator's subject provider (A13
-- decision 5). Adapters never build owner keys themselves; a coordinator without the provider
-- export falls back to its documented default (the account identifier), once, loudly.
function Tx.subjectOf(who)
    local ok, subject, why = pcall(Open77.exports.callSync, EconomyConfig.coordinator, "subjectOf", who)
    if ok then
        if type(subject) == "string" and subject ~= "" then return subject end
        return nil, why or "subject_unavailable"
    end
    if tostring(subject):find("export_not_found", 1, true) then
        warnOnce("subjectOf", "coordinator has no subjectOf export: using the default provider (account identifier)")
        if type(who) == "table" then return who.identifier end
        local identifier = Open77.players.identifier(who)
        if type(identifier) == "string" and identifier ~= "" then return identifier end
        return nil, "identifier_unavailable"
    end
    return nil, "coordinator_unavailable"
end

-- Registers fn(healthy, reason) for every health transition.
function Tx.onChange(fn) Tx.listeners[#Tx.listeners + 1] = fn end

function Tx.setHealthy(healthy, reason, store)
    local changed = healthy ~= Tx.healthy
    Tx.healthy = healthy
    Tx.reason = healthy and nil or (reason or "store_unavailable")
    if store then Tx.store = store end
    if changed then
        if healthy then
            log("coordinator ready (store=%s)", tostring(Tx.store))
        else
            log("coordinator unavailable (%s): wallet changes are refused, no fallback", tostring(Tx.reason))
        end
        for _, fn in ipairs(Tx.listeners) do
            local ok, err = pcall(fn, healthy, Tx.reason)
            if not ok then log("health listener failed: %s", tostring(err)) end
        end
    end
end

-- Failure reasons that say the store or the coordinator is not there.
local OUTAGE = { store_unavailable = true, coordinator_unavailable = true }
function Tx.noteFailure(reason)
    if OUTAGE[reason] then Tx.setHealthy(false, reason) end
end

-- One health probe. `health` is the readiness export (a B3 request to A13); a coordinator
-- without it is probed with a status read, which reaches the operation table.
function Tx.probe()
    local health, why, info = Tx.call("health")
    if type(health) == "table" then
        if health.ready then
            Tx.setHealthy(true, nil, health.store)
        else
            Tx.setHealthy(false, health.reason or "store_unavailable", health.store)
        end
        return
    end
    if type(info) == "table" and info.detail == "export_not_found" then
        warnOnce("health", "coordinator has no health export: probing with status()")
        local status, reason = Tx.call("status", "rp_economy.probe.health")
        if type(status) == "table" then Tx.setHealthy(true, nil, "unknown") return end
        Tx.setHealthy(false, reason or "store_unavailable")
        return
    end
    Tx.setHealthy(false, why == "coordinator_unavailable" and "coordinator_unavailable" or "store_unavailable")
end

function Tx.startProbe()
    CreateThread(function()
        while true do
            Tx.probe()
            Wait(Tx.healthy and EconomyConfig.probeHealthyMs or EconomyConfig.probeUnhealthyMs)
        end
    end)
end

-- Polls status(opId, { resolve = true }) until the outcome is known or `seconds` elapse.
-- Returns "committed", receipt | "aborted" | "failed", reason | "unknown".
function Tx.resolve(opId, seconds)
    local deadline = Open77.time.monotonic() + (seconds or 30)
    local pollMs = EconomyConfig.writeBehind.statusPollMs
    while true do
        local status, why = Tx.call("status", opId, { resolve = true })
        if type(status) == "table" then
            local state = status.state
            if state == "committed" then return "committed", status.receipt end
            if state == "aborted" or state == "expired" or state == "cancelled" then return "aborted" end
            if state == "failed" then return "failed", status.reason end
        else
            Tx.noteFailure(why)
        end
        if Open77.time.monotonic() >= deadline then return "unknown" end
        Wait(pollMs)
    end
end
