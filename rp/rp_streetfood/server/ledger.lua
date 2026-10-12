-- rp_streetfood / server/ledger.lua: THE adapter to the A13 transaction coordinator.
--
-- Every call to `open77_transactions` made by this resource goes through this file. Contract:
-- docs/world-interaction/a13-transaction-contract.md section 7.2 (wave 1). What crosses it:
--
--   open       the two stash containers of each stall (created or re-capacitied at boot)
--   read       pockets / pantry / pass snapshot              async (synchronous when loaded)
--   reserve    a cook (inputs + dish) or a meal (one portion) async
--   commit     the same lines                                async
--   cancel     a reservation that will not commit            sync
--   transfer   an operator / lab restock (supplier mint)     async
--   status     settle an in-doubt cook or meal (resolve)     async
--   authorize  rp_economy may move the sold portion out of the stall and into the buyer's pockets
--              in the one sale operation (two-party grant)
--   info / subjectOf / newOpId                               sync, never yield
--
-- The money never crosses here: it moves through rp_economy (plan decision 5, one economy).
-- Failures follow `nil, reason, info`. A rejection of the export layer itself (`export_*`) on a
-- MUTATING call is `in_doubt` (the commit may have landed with nobody listening, contract D6); on a
-- read it is `coordinator_unavailable`.
--
-- Global: StreetfoodLedger.

StreetfoodLedger = {}
local L = StreetfoodLedger

L.RESOURCE = "open77_transactions"
L.EXPORTS = {
    info = "info", subjectOf = "subjectOf", newOpId = "newOpId", allowed = "allowed",
    read = "read", open = "open", reserve = "reserve", commit = "commit", cancel = "cancel",
    transfer = "transfer", status = "status", authorize = "authorize",
}
local MUTATING = { reserve = true, commit = true, transfer = true, open = true }
local AMBIGUOUS = { export_timeout = true, export_resource_stopped = true }

local counter = 0
local bootTag = nil
local subjectFallbackLogged = false

local function log(line) print("[rp_streetfood] " .. line) end

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

-- The durable subject of a player (the coordinator's provider, A13 decision 5).
function L.subjectOf(playerId)
    local subject, why = callSync("subjectOf", playerId)
    if type(subject) == "string" and subject ~= "" then return subject end
    if why == "coordinator_unavailable" then
        if not subjectFallbackLogged then
            subjectFallbackLogged = true
            log("the coordinator answers no subjectOf: using Open77.players.identifier (the A13 default subject)")
        end
        local identifier = Open77.players.identifier(playerId)
        if type(identifier) == "string" and identifier ~= "" then return identifier end
    end
    return nil, why or "subject_unavailable"
end

-- Operation ids `sf.<kind>:<coordinator newOpId>` (server tag + wall-clock boot + counter). Minted
-- once per business step and kept for its retries; never derived from a client value.
function L.newOpId(kind)
    local id = callSync("newOpId")
    if type(id) ~= "string" or id == "" then
        bootTag = bootTag or (base36(math.floor(Open77.time.unix() * 1000)) .. base36(math.random(0, 1295)))
        counter = counter + 1
        id = bootTag .. "." .. base36(counter)
    end
    return ("sf.%s:%s"):format(kind, id)
end

function L.read(account) return call("read", account) end

-- Synchronous read for a container this resource keeps loaded (the stall's stashes): never yields.
function L.readLoaded(account) return callSync("read", account) end

function L.open(account, props) return call("open", account, props) end
function L.reserve(spec) return call("reserve", spec) end
function L.commit(opId, final) return call("commit", opId, final) end
function L.transfer(spec) return call("transfer", spec) end
function L.status(opId, options) return call("status", opId, options) end
function L.cancel(opId, reason) return callSync("cancel", opId, reason) end

function L.authorize(opId, grantee, accounts, ttlMs)
    return callSync("authorize", opId, grantee, accounts, ttlMs)
end

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

-- Count of an item a snapshot holds, minus what is reserved out of it (`held.items`, contract 7.2:
-- availability is count - held).
function L.available(snapshot, item)
    if type(snapshot) ~= "table" then return 0 end
    local have = type(snapshot.items) == "table" and (snapshot.items[item] or 0) or 0
    local held = type(snapshot.held) == "table" and type(snapshot.held.items) == "table"
        and (snapshot.held.items[item] or 0) or 0
    return math.max(0, have - held)
end

return L
