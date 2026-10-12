-- rp_nomade / server/ledger.lua: THE adapter to the transaction coordinator (open77_transactions).
--
-- Every call this resource makes to `open77_transactions` goes through this file, so a renamed
-- export or a changed calling convention touches one table and one function. What crosses it:
--
--   read      a crate, the camp's stash, a truck bed                async (sync when loaded)
--   open      the camp's stash and the NCPD evidence stash           async
--   reserve   a run's stock (goods out of the stash, tokens minted)  async
--   commit    that reservation; a search's confiscation               async
--   cancel    a reservation that will not commit                     sync
--   transfer  restock, return to the stash, confiscation, token retire, reclaim   async
--   status    settle an in-doubt operation (resolve)                 async
--   authorize two-party grant: rp_cargo moves a token out of a crate, rp_economy sells from it
--   info / subjectOf / newOpId                                       sync, never yield
--
-- Failures follow the platform convention `nil, reason, info`. A rejection of the export layer
-- itself (`export_*`) on a MUTATING call is `in_doubt` (the commit may have landed with nobody
-- listening); on a read it is `coordinator_unavailable`.
--
-- Global: NomadLedger.

NomadLedger = {}
local L = NomadLedger

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

local function log(line) print("[rp_nomade] " .. line) end

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

-- Asynchronous call (yields): the promise form, export-layer failures normalized.
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

-- Synchronous call (never yields on the coordinator's side): pcall'd, a raise is unavailability.
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

-- The durable subject of a player (the coordinator's provider). Never built here.
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

-- The coordinator's own id (`<serverTag>-<boot>-<n>`), unique among servers sharing the database.
function L.rawId()
    local id = callSync("newOpId")
    if type(id) ~= "string" or id == "" then
        bootTag = bootTag or (base36(math.floor(Open77.time.unix() * 1000)) .. base36(math.random(0, 1295)))
        counter = counter + 1
        id = "nmd-" .. bootTag .. "-" .. base36(counter)
    end
    return id
end

-- Operation ids: `nmd.<kind>:<coordinator id>`. Never derived from an open77_actions opId, whose
-- boot tag restarts with the monotonic clock.
function L.newOpId(kind) return ("nmd.%s:%s"):format(kind, L.rawId()) end

function L.read(account) return call("read", account) end
function L.open(account, props) return call("open", account, props) end
function L.reserve(spec) return call("reserve", spec) end
function L.commit(opId, final) return call("commit", opId, final) end
function L.transfer(spec) return call("transfer", spec) end
function L.status(opId, options) return call("status", opId, options) end
function L.cancel(opId, reason) return callSync("cancel", opId, reason) end

-- Lets `grantee` touch `accounts` in the one operation `opId`. This resource must itself be
-- allowed to write each account (writers policy).
function L.authorize(opId, grantee, accounts, ttlMs)
    return callSync("authorize", opId, grantee, accounts, ttlMs)
end

function L.allowed(resource, target, asset) return callSync("allowed", resource, target, asset) end

-- Settles an operation whose outcome is unknown: "committed" (+ receipt) | "failed" | "aborted" |
-- "pending" (still in doubt: ask again later).
function L.settle(opId)
    local st, why = L.status(opId, { resolve = true })
    if type(st) ~= "table" then return "pending", nil, why end
    if st.state == "committed" then return "committed", st.receipt end
    if st.state == "aborted" then return "aborted" end
    if st.state == "in_doubt" or st.state == "committing" or st.state == "reserved" then return "pending" end
    return "failed", nil, st.reason
end

-- Whether an operation committed, without fencing it (a status read only).
function L.committed(opId)
    local st = L.status(opId)
    return type(st) == "table" and st.state == "committed", st
end

return L
