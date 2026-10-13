-- rp_trauma / server/ledger.lua: THE adapter to the open77_transactions coordinator.
--
-- Every call this resource makes to `open77_transactions` goes through this file. What crosses it:
--
--   open       a holder's file stash:<subject>:tti (the membership card, the invoices)
--   read       a file, a wallet (bank / cash / soc) snapshot           async (sync when loaded)
--   reserve    a plan purchase, a treatment charge (before the work)    async
--   commit     the same lines                                         async
--   cancel     a reservation that will not commit                     sync
--   transfer   a renewal, an invoice payment, a legacy import          async
--   status     settle an in-doubt operation (resolve)                 async
--   account / subjectOf / newOpId / info                              sync, never yield
--
-- Failures follow `nil, reason, info`. A rejection of the export layer itself (`export_*`) on a
-- MUTATING call is `in_doubt` (the commit may have landed with nobody listening); on a read it is
-- `coordinator_unavailable`.
--
-- Global: TraumaLedger.

TraumaLedger = {}
local L = TraumaLedger

L.RESOURCE = "open77_transactions"
L.EXPORTS = {
    info = "info", subjectOf = "subjectOf", account = "account", newOpId = "newOpId", allowed = "allowed",
    read = "read", open = "open", reserve = "reserve", commit = "commit", cancel = "cancel",
    transfer = "transfer", status = "status",
}
local MUTATING = { reserve = true, commit = true, transfer = true, open = true }
local AMBIGUOUS = { export_timeout = true, export_resource_stopped = true }

local counter = 0
local bootTag = nil
local subjectFallbackLogged = false

local function log(line) print("[rp_trauma] " .. line) end

local function base36(n)
    local digits = "0123456789abcdefghijklmnopqrstuvwxyz"
    n = math.floor(math.abs(tonumber(n) or 0))
    if n == 0 then return "0" end
    local out = {}
    while n > 0 do
        local d = n % 36
        table.insert(out, 1, digits:sub(d + 1, d + 1))
        n = n // 36
    end
    return table.concat(out)
end

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

-- The durable subject of a player (the coordinator's provider).
function L.subjectOf(playerId)
    local subject, why = callSync("subjectOf", playerId)
    if type(subject) == "string" and subject ~= "" then return subject end
    if why == "coordinator_unavailable" then
        if not subjectFallbackLogged then
            subjectFallbackLogged = true
            log("the coordinator answers no subjectOf: using Open77.players.identifier (the default subject)")
        end
        local identifier = Open77.players.identifier(playerId)
        if type(identifier) == "string" and identifier ~= "" then return identifier end
    end
    return nil, why or "subject_unavailable"
end

-- A player's wallet or pockets account, as the coordinator names it ("bank" | "cash" | "char").
function L.account(playerId, namespace)
    local id, why = callSync("account", playerId, namespace)
    if type(id) == "string" then return id end
    local subject = L.subjectOf(playerId)
    if subject then return namespace .. ":" .. subject end
    return nil, why or "subject_unavailable"
end

-- Operation ids `tt.<kind>:<coordinator newOpId>` (server tag + wall-clock boot + counter). Minted
-- once per business step and kept for its retries; never derived from a client value.
function L.newOpId(kind)
    local id = callSync("newOpId")
    if type(id) ~= "string" or id == "" then
        bootTag = bootTag or (base36(math.floor(Open77.time.unix() * 1000)) .. base36(math.random(0, 1295)))
        counter = counter + 1
        id = bootTag .. "." .. base36(counter)
    end
    return ("tt.%s:%s"):format(kind, id)
end

function L.read(account) return call("read", account) end
function L.readLoaded(account) return callSync("read", account) end
function L.open(account, props) return call("open", account, props) end
function L.reserve(spec) return call("reserve", spec) end
function L.commit(opId, final) return call("commit", opId, final) end
function L.transfer(spec) return call("transfer", spec) end
function L.status(opId, options) return call("status", opId, options) end
function L.cancel(opId, reason) return callSync("cancel", opId, reason) end
function L.allowed(resource, target, asset) return callSync("allowed", resource, target, asset) end

-- Settles an operation whose outcome is unknown: "committed" | "failed" | "aborted" | "pending".
function L.settle(opId)
    local st, why = L.status(opId, { resolve = true })
    if type(st) ~= "table" then return "pending", nil, why end
    if st.state == "committed" then return "committed", st.receipt end
    if st.state == "aborted" then return "aborted" end
    if st.state == "in_doubt" or st.state == "committing" or st.state == "reserved" then return "pending" end
    return "failed", nil, st.reason
end

-- A wallet's spendable balance (0 for a wallet that was never paid).
function L.funds(account)
    if not account then return 0 end
    local snap = L.read(account)
    if type(snap) ~= "table" then return 0 end
    return TraumaModel.available(snap)
end

return L
