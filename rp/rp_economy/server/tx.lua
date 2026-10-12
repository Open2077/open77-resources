-- rp_economy / server/tx.lua: the client of the open77_transactions coordinator.
--
-- Everything here that talks to the coordinator yields (Open77.exports.call + await), so it
-- runs only in threads, handlers or async exports, never inside a synchronous export. The inline
-- calls are the coordinator's non-yielding exports: subjectOf (the subject provider) and allowed
-- (its mint rules). API: the final coordinator, Open77 697e9e2f (contract section 7.2).
--
-- A rejected Promise (export_timeout, export_resource_stopped, promise_cancelled, a raised
-- coordinator) is NOT a failure: the coordinator may have committed. It is reported as
-- `in_doubt` and resolved through status(opId, { resolve = true }) (A13 §5, finding 6).

Tx = {
    healthy = false,
    reason = "coordinator_starting",
    store = nil,
    listeners = {},
}

local function log(fmt, ...)
    print(("[rp_economy] " .. fmt):format(...))
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

-- Durable owner key, from the coordinator's subject provider (A13 decision 5): `who` is a
-- session player id, or an account identifier (a string that is not a number: an offline
-- subject; `{ identifier = guid }` is accepted as the same thing). Adapters never build owner
-- keys themselves: a refusal is passed through, and a coordinator that is not running answers
-- coordinator_unavailable.
function Tx.subjectOf(who)
    if type(who) == "table" then
        who = who.identifier
        if type(who) ~= "string" or who == "" or tonumber(who) ~= nil then return nil, "invalid_subject" end
    end
    local ok, subject, why = pcall(Open77.exports.callSync, EconomyConfig.coordinator, "subjectOf", who)
    if not ok then return nil, "coordinator_unavailable" end
    if type(subject) == "string" and subject ~= "" then return subject end
    return nil, why or "subject_unavailable"
end

-- Whether the coordinator's mint rules let this resource create money out of `sysAccount`
-- (allowed(resource, "sys:...", "money"); non-yielding). true, or false plus mint_denied /
-- mint_cap_exceeded. A coordinator that cannot be asked answers true: the operation itself is
-- refused then.
function Tx.mayMint(sysAccount)
    local ok, allowed, why = pcall(Open77.exports.callSync, EconomyConfig.coordinator, "allowed",
        GetCurrentResourceName(), sysAccount, "money")
    if not ok or allowed == nil or allowed == true then return true end
    return false, why or "mint_denied"
end

-- Reads a wallet. The coordinator loads on demand and never creates: a wallet that was never
-- credited answers unknown_account, read here as an empty wallet (balance 0, version 0, not
-- existing). Yields. snapshot | nil, reason.
function Tx.read(id)
    local snap, why, info = Tx.call("read", id)
    if type(snap) == "table" then return snap end
    if why == "unknown_account" then return { id = id, exists = false, balance = 0, version = 0 } end
    return nil, why, info
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

-- One health probe: the coordinator's health export (contract 7.2, a superset of info). Ready
-- means its store booted (phase ready) AND it has not marked the store down since (an answer
-- that said "the database did not answer"; it probes and clears that itself).
function Tx.probe()
    local health, why = Tx.call("health")
    if type(health) == "table" then
        local down = type(health.coordinator) == "table" and health.coordinator.down == true
        if health.ready and not down then
            Tx.setHealthy(true, nil, health.store)
        else
            Tx.setHealthy(false, down and "store_unavailable" or (health.reason or "store_unavailable"), health.store)
        end
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
