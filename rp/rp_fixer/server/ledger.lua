-- rp_fixer / server/ledger.lua: THE adapter to the open77_transactions coordinator.
--
-- Every call this resource makes to `open77_transactions` goes through this file. What crosses
-- it is goods, never money (money moves through rp_economy, server/ports.lua):
--
--   reserve / commit / cancel   the goods of a retrieval hand-over (pockets -> the poster's drop
--                               box, or burned into sys:fixer.retrieval for a fixer NPC)
--   status                      settle a hand-over whose commit answer was lost
--   open / read / transfer      the poster's drop box: created at post time, emptied into their
--                               pockets when they collect it
--   info / subjectOf / newOpId  sync, never yield
--
-- Failures follow the platform convention `nil, reason, info`. A rejection of the export layer
-- itself (`export_*`) on a MUTATING call is `in_doubt` (the commit may have landed with nobody
-- listening); on a read it is `coordinator_unavailable`.
--
-- Global: FixerLedger.

FixerLedger = {}
local L = FixerLedger

L.RESOURCE = "open77_transactions"
L.EXPORTS = {
    info = "info", subjectOf = "subjectOf", newOpId = "newOpId", account = "account",
    read = "read", open = "open", reserve = "reserve", commit = "commit", cancel = "cancel",
    transfer = "transfer", status = "status",
}
local MUTATING = { reserve = true, commit = true, transfer = true, open = true }
local AMBIGUOUS = { export_timeout = true, export_resource_stopped = true }

local subjectFallbackLogged = false

local function log(line) print("[rp_fixer] " .. line) end

local function call(name, ...)
    local promise, dispatch = Open77.exports.call(L.RESOURCE, L.EXPORTS[name], ...)
    if not promise then return nil, "coordinator_unavailable", { retryable = true, detail = tostring(dispatch) } end
    local r = table.pack(promise:await())
    if r[1] == nil and type(r[2]) == "string" and r[2]:sub(1, 7) == "export_" then
        if AMBIGUOUS[r[2]] and MUTATING[name] then return nil, "in_doubt", { retryable = true, detail = r[2] } end
        return nil, "coordinator_unavailable", { retryable = true, detail = r[2] }
    end
    return table.unpack(r, 1, r.n)
end

local function callSync(name, ...)
    local r = table.pack(pcall(Open77.exports.callSync, L.RESOURCE, L.EXPORTS[name], ...))
    if not r[1] then return nil, "coordinator_unavailable", { retryable = true, detail = tostring(r[2]) } end
    return table.unpack(r, 2, r.n)
end

-- { ready, store, phase, serverTag, ... } | nil, reason
function L.info()
    if GetResourceState(L.RESOURCE) ~= "running" then return nil, "coordinator_unavailable" end
    local info, why = callSync("info")
    if type(info) ~= "table" then return nil, why or "coordinator_unavailable" end
    return info
end

function L.ready()
    local info = L.info()
    return type(info) == "table" and info.ready == true, info
end

-- The durable subject of a connected player (the coordinator's provider). Without the
-- coordinator, the account identifier: the provider's documented default.
function L.subjectOf(playerId)
    local subject, why = callSync("subjectOf", playerId)
    if type(subject) == "string" and subject ~= "" then return subject end
    if why == "coordinator_unavailable" then
        if not subjectFallbackLogged then
            subjectFallbackLogged = true
            log("the coordinator answers no subjectOf: using Open77.players.identifier (its default subject)")
        end
        local pid = math.tointeger(tonumber(playerId))
        if pid and pid >= 1 then
            local identifier = Open77.players.identifier(pid)
            if type(identifier) == "string" and identifier ~= "" then return identifier end
        end
    end
    return nil, why or "subject_unavailable"
end

function L.pockets(subject) return "char:" .. subject end
function L.box(subject) return "stash:fxbox." .. subject end

function L.read(account) return call("read", account) end
function L.open(account, props) return call("open", account, props) end
function L.reserve(spec) return call("reserve", spec) end
function L.commit(opId, final) return call("commit", opId, final) end
function L.transfer(spec) return call("transfer", spec) end
function L.status(opId, options) return call("status", opId, options) end
function L.cancel(opId, reason) return callSync("cancel", opId, reason) end

function L.newOpId(kind)
    local id = callSync("newOpId")
    if type(id) ~= "string" or id == "" then
        id = ("%x.%x"):format(math.floor(Open77.time.unix() * 1000), math.random(0, 0xffffff))
    end
    return ("fixer.%s:%s"):format(kind, id)
end

-- Settles an operation whose outcome is unknown, without fencing it: "committed" (with the
-- receipt) | "pending" (reserved, committing or in doubt: ask again) | "none" (nothing durable).
function L.peek(opId)
    local st, why = L.status(opId)
    if type(st) ~= "table" then return "pending", nil, why end
    if st.state == "committed" then return "committed", st.receipt end
    if st.state == "in_doubt" or st.state == "committing" or st.state == "reserved" then return "pending" end
    return "none", nil, st.state
end

return L
