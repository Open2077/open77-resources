-- =============================================================================
-- open77_transactions -- server/main.lua
-- =============================================================================
-- Runtime wiring of the durable transaction coordinator (contract:
-- docs/world-interaction/a13-transaction-contract.md; author guide:
-- wiki/transactions.md). EXPERIMENTAL. Not proven in game.
--
--   * tunables: store mode, server tag, writers, mint rules, retention
--   * store chosen ONCE at boot: `sql` (default), or `lab_kvp` only when the
--     tunable asks for it AND convar open77_transactions_lab is 1 AND the host
--     reports the server is not mastered. Anything else refuses; nothing ever
--     falls back to another store.
--   * sql boot: schema version + forward migrations, then the self-test
--     (InnoDB, guard row, a failing transaction must roll back its first
--     statement). A failed boot refuses every call with `store_failed`.
--   * exports (mutating ones yield: call them with Open77.exports.call)
--   * events: open77_transactions:ready, :committed, :world
--   * console: `transactions health | status <opId> | resolve <opId> | read <account> | mints`
-- =============================================================================

local RESOURCE = GetCurrentResourceName()
local M, Policy = Open77TxModel, Open77TxPolicy
local HOUR_MS, DAY_MS = 3600000, 86400000

local function now() return math.floor(Open77.time.unix() * 1000) end
local function log(level, message)
    if level == "ERR" then Open77.log.error(message)
    elseif level == "WRN" then Open77.log.warn(message)
    else Open77.log.info(message) end
end

-- ---------------------------------------------------------------------------
-- Tunables (operator-owned; only this resource and the operator can set them)
-- ---------------------------------------------------------------------------
local declaration = {
    store = { value = "sql", type = "enum", choices = { "sql", "lab_kvp" }, apply = "next_match",
        label = "Store", group = "Store", order = 1,
        description = "Read once at start. lab_kvp is a disposable lab store and also needs convar "
            .. "open77_transactions_lab 1 on a server that is not mastered." },
    serverTag = { value = "srv", type = "string", apply = "next_match", label = "Server tag", group = "Store", order = 2,
        description = "Prefix of minted operation and world ids. Must be unique among servers sharing one database." },
    preloadWorld = { value = 2000, type = "integer", min = 0, max = 20000, apply = "next_match",
        label = "World containers preloaded", group = "Store", order = 3,
        description = "How many world: containers are loaded into memory at start, in chunks." },
    retentionDays = { value = 90, type = "integer", min = 7, max = 3650, apply = "live", unit = "d",
        label = "Journal retention", group = "Store", order = 4,
        description = "Journal rows and operation rows older than this are deleted in bounded chunks." },
    workPerTick = { value = 12, type = "integer", min = 2, max = 64, apply = "live",
        label = "Work items per tick", group = "Store", order = 5,
        description = "Coordinator steps run per server tick. Bounds one pass well under the 1M-instruction "
            .. "quota when hundreds of commits answer at once; raise only after measuring." },
    writers = { value = "*", type = "string", apply = "live", label = "Writers", group = "Policy", order = 10,
        description = "* or a list of resources allowed to mutate, e.g. rp_inventory, rp_economy:cash+bank+soc" },
}
-- A text tunable holds at most 256 characters, and a server running the whole RP pack lists more
-- writers than that: writers2..writers4 continue the list (joined with `writers`, same syntax).
local WRITER_SLOTS = 4
for i = 2, WRITER_SLOTS do
    declaration["writers" .. i] = { value = "", type = "string", apply = "live", label = "Writers " .. i,
        group = "Policy", order = 10,
        description = "more entries for the writers list when it does not fit in one field (ignored while writers is *)" }
end
local MINT_SLOTS = 6
for i = 1, MINT_SLOTS do
    declaration["mint" .. i] = { value = "", type = "string", apply = "live", label = "Mint rules " .. i,
        group = "Policy", order = 10 + i,
        description = "<resource> <sys:account|sys:*> <item|*|money> <capPerHour>; separate rules with ;" }
end
local tune = Open77.tunables.declare(declaration)

local policy = Policy.new()
local function writersList()
    local first = tostring(tune.writers or "*")
    if first:match("^%s*%*%s*$") then return "*" end
    local parts = { first }
    for i = 2, WRITER_SLOTS do
        local more = tostring(tune["writers" .. i] or "")
        if more:match("%S") then parts[#parts + 1] = more end
    end
    return table.concat(parts, ", ")
end
local function applyPolicy()
    local writerProblems = policy:setWriters(writersList())
    local rules = {}
    for i = 1, MINT_SLOTS do rules[i] = tune["mint" .. i] end
    local ruleProblems = policy:setRules(rules)
    for _, p in ipairs(writerProblems or {}) do log("WRN", "writers: ignored entry '" .. p .. "'") end
    for _, p in ipairs(ruleProblems or {}) do log("WRN", "mint rules: ignored entry '" .. p .. "'") end
end
applyPolicy()

AddEventHandler("onTunableChanged", function(key)
    if tostring(key):match("^writers%d?$") or tostring(key):match("^mint%d$") then
        applyPolicy()
        log("INF", "policy reloaded after a change to " .. tostring(key))
    elseif key == "store" or key == "serverTag" or key == "preloadWorld" then
        log("WRN", key .. " changed; it takes effect when " .. RESOURCE .. " restarts")
    end
end)

-- ---------------------------------------------------------------------------
-- Boot state
-- ---------------------------------------------------------------------------
local state = { phase = "starting", mode = tune.store, reason = nil, detail = nil, schemaVersion = nil, readyAt = nil }
local store, co

local function refuse(reason, detail)
    state.phase, state.reason, state.detail = "refused", reason, detail
    log("ERR", ("store refused (%s): %s. Every call answers store_failed until the cause is fixed and %s restarts.")
        :format(tostring(reason), tostring(detail or ""), RESOURCE))
end

local serverTag = tostring(tune.serverTag)
if #serverTag > 11 or not serverTag:match("^[a-z][a-z0-9_%-]*$") then
    refuse("invalid_server_tag", "serverTag must be 1-11 characters of [a-z0-9_-], starting with a letter")
end

-- ---------------------------------------------------------------------------
-- Work queue. The runtime gives a resource ONE instruction budget (1M) per
-- scheduler pass, shared by every task it resumes. Two hundred commits that
-- answer in the same tick would each settle in that one pass and kill the VM.
-- So every coordinator step -- an export's request, a store answer, the
-- maintenance tick -- is queued and a single worker runs a bounded number of
-- them per pass.
-- ---------------------------------------------------------------------------
local work, workHead, workTail = {}, 1, 0
local function enqueue(fn)
    workTail = workTail + 1
    work[workTail] = fn
end

local function deferred(cb)
    return function(...)
        local args = table.pack(...)
        enqueue(function() cb(table.unpack(args, 1, args.n)) end)
    end
end

-- A store whose every answer is queued instead of run inline.
local function budgeted(inner)
    return setmetatable({}, { __index = function(_, key)
        local value = inner[key]
        if type(value) ~= "function" then return value end
        return function(_, ...)
            local args = table.pack(...)
            if type(args[args.n]) == "function" then args[args.n] = deferred(args[args.n]) end
            return value(inner, table.unpack(args, 1, args.n))
        end
    end })
end

CreateThread(function()
    while true do
        local budget = math.tointeger(tune.workPerTick) or 12
        local n = 0
        while workHead <= workTail and n < budget do
            local fn = work[workHead]
            work[workHead] = nil
            workHead = workHead + 1
            local ok, err = pcall(fn)
            if not ok then log("ERR", "coordinator step failed: " .. tostring(err)) end
            n = n + 1
        end
        if workHead > workTail then work, workHead, workTail = {}, 1, 0 end
        Wait(0)
    end
end)

local function decode(text)
    local ok, value = pcall(json.decode, text)
    if ok then return value end
    return nil
end

local function labStoreAllowed()
    local lab = tostring(GetConvar("open77_transactions_lab", "0")):lower()
    if lab ~= "1" and lab ~= "true" then
        return false, "convar open77_transactions_lab is not 1"
    end
    -- Read-only, host-provided. Absent (an older host) counts as mastered.
    local mastered = tostring(GetConvar("sv_masterServerEnabled", "unknown")):lower()
    if mastered ~= "false" then
        return false, "the server is mastered (sv_masterServerEnabled=" .. mastered .. ")"
    end
    return true
end

if state.phase ~= "refused" then
    if state.mode == "lab_kvp" then
        local allowed, why = labStoreAllowed()
        if not allowed then
            refuse("lab_store_not_allowed", why)
        else
            local lab = Open77TxKvpStore.new(Open77.kvp, { encode = M.encode, decode = decode, log = log })
            log("WRN", ("LAB STORE: lab_kvp is a disposable store with no migration out of it (%d rows hydrated)")
                :format(lab.hydrated))
            store = budgeted(lab)
        end
    elseif state.mode == "sql" then
        store = budgeted(Open77TxSql.newStore(MySQL, { encode = M.encode, decode = decode, now = now, maxRows = 512 }))
    else
        refuse("invalid_store", tostring(state.mode))
    end
end

-- ---------------------------------------------------------------------------
-- Coordinator
-- ---------------------------------------------------------------------------
if store then
    co = Open77TxCoordinator.new({
        store = store, now = now, serverTag = serverTag, policy = policy, log = log, opRetentionMs = 120000,
        defer = enqueue,
        acl = function(resource, namespace, account) return policy:canWrite(resource, namespace, account) end,
        onCommitted = function(receipt, accounts)
            TriggerEvent("open77_transactions:committed", receipt.opId, receipt.kind, accounts)
        end,
        onWorld = function(id, change, meta)
            TriggerEvent("open77_transactions:world", id, change, meta)
        end,
    })
end

local function becomeReady()
    state.phase, state.readyAt = "ready", now()
    log("INF", ("ready: store=%s schema=v%s tag=%s"):format(state.mode, tostring(state.schemaVersion), serverTag))
    TriggerEvent("open77_transactions:ready", { store = state.mode, schema = state.schemaVersion })
end

-- Loads world: containers into memory in pages, yielding between pages, so a
-- projection can read them synchronously and no single resume approaches the
-- 1M-instruction quota.
local function preloadWorld(limit)
    CreateThread(function()
        local after, loaded = "", 0
        while loaded < limit and state.phase == "ready" do
            local page
            local done = false
            co:listWorld(after, math.min(100, limit - loaded), function(rows) page, done = rows, true end)
            while not done do Wait(0) end
            if not page or #page == 0 then break end
            local pending = #page
            for _, row in ipairs(page) do
                co:load(row.id, function() pending = pending - 1 end)
            end
            while pending > 0 do Wait(0) end
            loaded = loaded + #page
            after = page[#page].id
            Wait(0)
        end
        if loaded > 0 then log("INF", ("preloaded %d world containers"):format(loaded)) end
    end)
end

local function bootStore()
    store:migrate(function(version, reason, detail)
        if not version then return refuse(reason, detail) end
        state.schemaVersion = version
        if detail ~= nil and detail ~= version then
            log("INF", ("schema migrated from v%s to v%s"):format(tostring(detail), tostring(version)))
        end
        store:selfTest(serverTag .. "-" .. tostring(now()), function(ok, why, problems)
            if not ok then return refuse(why, table.concat(problems or {}, "; ")) end
            store:mintHistory(now() - HOUR_MS, function(rows)
                local seeded = policy:seed(rows or {})
                if seeded > 0 then log("INF", ("mint caps seeded from %d journal rows"):format(seeded)) end
                becomeReady()
                preloadWorld(math.tointeger(tune.preloadWorld) or 0)
            end)
        end)
    end)
end

CreateThread(function()
    if not co then return end
    if state.mode == "sql" then
        local accepted, why = MySQL.ready(bootStore)
        if not accepted then
            refuse(why == "permission_denied:database.access" and "store_failed" or "store_unavailable", why)
        end
    else
        bootStore()
    end
end)

-- Expiry, deadlines, fence retries, the outage probe, and retention.
local nextPurgeAt = now() + 60000
CreateThread(function()
    while true do
        Wait(250)
        if co and state.phase == "ready" then
            enqueue(function() co:tick() end)
            if state.mode == "sql" and now() >= nextPurgeAt then
                nextPurgeAt = now() + HOUR_MS
                local before = now() - (math.tointeger(tune.retentionDays) or 90) * DAY_MS
                store:purge(before, 2000, function(removed)
                    if removed and removed > 0 then
                        log("INF", ("retention removed %d journal/operation rows"):format(removed))
                        if removed >= 2000 then nextPurgeAt = now() + 5000 end
                    end
                end)
            end
        end
    end
end)

AddEventHandler("onResourceStop", function(name)
    if co and name ~= RESOURCE then
        local cancelled = co:onResourceStop(name)
        if cancelled > 0 then log("INF", ("cancelled %d reservations of stopped %s"):format(cancelled, name)) end
    end
end)

-- ---------------------------------------------------------------------------
-- Subjects (durable owner keys)
-- ---------------------------------------------------------------------------
local provider -- { resource, export }

-- `who` is a session player id (number, or a numeric string) or a durable
-- account identifier (any other string). The default provider answers the
-- account id itself (contract section 12, decision 8); an override provider
-- receives `who` unchanged and must accept both forms.
local function subjectOf(who)
    local pid = math.tointeger(tonumber(who))
    local byIdentifier = type(who) == "string" and pid == nil
    if not byIdentifier and (not pid or pid < 1) then return nil, "invalid_player" end
    local key, why
    if provider then
        local ok, value, reason = pcall(Open77.exports.callSync, provider.resource, provider.export,
            byIdentifier and who or pid)
        if not ok then return nil, "subject_provider_unavailable", { detail = tostring(value) } end
        key, why = value, reason
    elseif byIdentifier then
        key = who
    else
        local ok, value = pcall(Open77.players.identifier, pid)
        key = ok and value or nil
    end
    if type(key) ~= "string" or key == "" then return nil, why or "subject_unavailable" end
    if #key > 80 or not key:match("^[A-Za-z0-9_.@~%-]+$") or M.durableKeyProblem("char:" .. key) then
        return nil, "invalid_key", { subject = key }
    end
    return key
end

-- ---------------------------------------------------------------------------
-- Exports
-- ---------------------------------------------------------------------------
local function caller() return GetInvokingResource() or RESOURCE end

local function gate()
    if state.phase == "ready" then return true end
    if state.phase == "refused" then
        return nil, "store_failed", { retryable = false, detail = state.reason }
    end
    return nil, "store_unavailable", { retryable = true, detail = "starting" }
end

-- Queues a continuation-style call on the work queue and waits for its
-- answer. It always yields, so these exports need the asynchronous form
-- (`Open77.exports.call(...):await()`); the synchronous sugar answers
-- `export_yielded`. `read`, `submit`, `cancel`, `define`, `health`,
-- `newOpId`, `subjectOf` and `account` never yield.
local function await(start)
    local box = { done = false }
    enqueue(function()
        start(function(...)
            box.n, box.v, box.done = select("#", ...), { ... }, true
        end)
    end)
    while not box.done do Wait(0) end
    return table.unpack(box.v, 1, box.n)
end

local function guarded(fn)
    return function(...)
        local ok, why, info = gate()
        if not ok then return nil, why, info end
        return fn(...)
    end
end

-- What an adapter needs to decide whether it may run: the store mode
-- (`sql` | `lab_kvp`), the phase and the schema version.
exports("info", function()
    return {
        store = state.mode, phase = state.phase, ready = state.phase == "ready", reason = state.reason,
        schema = state.schemaVersion, serverTag = serverTag, version = GetResourceMetadata
            and GetResourceMetadata(RESOURCE, "version", 0) or nil,
    }
end)

exports("health", function()
    return {
        phase = state.phase, ready = state.phase == "ready", store = state.mode, reason = state.reason,
        detail = state.detail, schema = state.schemaVersion, serverTag = serverTag,
        coordinator = co and co:health() or nil,
    }
end)

exports("define", function(items)
    if not co then return nil, "store_failed" end
    return co:define(items, caller())
end)

exports("definition", function(itemId)
    if not co then return nil, "store_failed" end
    return co:definition(itemId)
end)

exports("newOpId", function()
    if not co then return nil, "store_failed" end
    return co:newOpId()
end)

exports("subjectOf", subjectOf)

exports("account", function(playerId, namespace, part)
    if namespace ~= "char" and namespace ~= "cash" and namespace ~= "bank" then return nil, "invalid_account" end
    local subject, why, info = subjectOf(playerId)
    if not subject then return nil, why, info end
    if part ~= nil then
        if type(part) ~= "string" or not part:match("^[A-Za-z0-9_.@~%-]+$") then return nil, "invalid_account" end
        return namespace .. ":" .. subject .. ":" .. part
    end
    return namespace .. ":" .. subject
end)

exports("registerSubjectProvider", function(exportName)
    local who = GetInvokingResource()
    if not who then return nil, "invalid_caller" end
    if type(exportName) ~= "string" or not exportName:match("^[%a_][%w_]*$") then return nil, "invalid_spec" end
    if provider and provider.resource ~= who then
        return nil, "provider_already_registered", { resource = provider.resource }
    end
    provider = { resource = who, export = exportName }
    log("INF", ("subject provider: %s.%s"):format(who, exportName))
    return true
end)

-- Loads on demand, never creates; no row answers `unknown_account`. Answers
-- without yielding when the mirror is already loaded (so the synchronous
-- sugar works for accounts a resource keeps warm).
local function readExport(accountId)
    if type(accountId) == "string" and co:isLoaded(accountId) then
        local result = table.pack(nil, "internal_error")
        co:readAccount(accountId, function(...) result = table.pack(...) end)
        return table.unpack(result, 1, result.n)
    end
    return await(function(done) co:readAccount(accountId, done) end)
end
exports("read", guarded(readExport))
exports("load", guarded(readExport)) -- the wave-0 name, kept as an alias

exports("open", guarded(function(accountId, props)
    local who = caller()
    return await(function(done) co:open(accountId, props or {}, who, done) end)
end))

exports("openWorld", guarded(function(props)
    local who = caller()
    return await(function(done) co:openWorld(props, who, done) end)
end))

exports("setMeta", guarded(function(containerId, meta)
    local who = caller()
    return await(function(done) co:setMeta(containerId, meta, who, done) end)
end))

exports("close", guarded(function(worldId)
    local who = caller()
    return await(function(done) co:close(worldId, who, done) end)
end))

exports("listWorld", guarded(function(after, limit)
    return await(function(done) co:listWorld(after, limit, done) end)
end))

exports("list", guarded(function(namespace, after, limit)
    return await(function(done) co:list(namespace, after, limit, done) end)
end))

exports("reserve", guarded(function(spec)
    local who = caller()
    return await(function(done) co:reserve(spec, who, done) end)
end))

exports("commit", guarded(function(opId, final)
    local who = caller()
    return await(function(done) co:commit(opId, final, who, done) end)
end))

exports("transfer", guarded(function(spec)
    local who = caller()
    return await(function(done) co:transfer(spec, who, done) end)
end))

exports("submit", guarded(function(spec)
    local who = caller()
    local result = table.pack(nil, "internal_error")
    co:submit(spec, who, function(...) result = table.pack(...) end)
    return table.unpack(result, 1, result.n)
end))

exports("cancel", guarded(function(opId, reason)
    return co:cancel(opId, reason, caller())
end))

-- Whether `resource` may write `target`: a namespace ("world"), an account
-- ("veh:NC-1234:cargo", which honours per-part grants), or a sys: account,
-- which asks whether it may MINT from it (`asset`: an item id, "money", or
-- nil for any item). Policy only: the store is not asked; a cap already used up
-- answers mint_cap_exceeded.
-- Never yields. Answers true, or false plus the refusal a mutation would get.
exports("allowed", function(resource, target, asset)
    resource = resource or caller()
    if type(resource) ~= "string" or type(target) ~= "string" then return false, "invalid_spec" end
    local ns = target:match("^([a-z]+)")
    if ns == nil or M.NAMESPACES[ns] == nil then return false, "invalid_account" end
    if ns == "sys" then
        local mint = asset == nil and { from = target, envelope = true, amount = 0 }
            or { from = target, asset = asset, amount = 0 }
        local ok, why = policy:check(resource, { mint }, now())
        if ok then return true end
        return false, why
    end
    local account = target:find(":", 1, true) and target or nil
    if policy:canWrite(resource, ns, account) then return true end
    return false, "namespace_denied"
end)

exports("authorize", guarded(function(opId, grantee, accounts, ttlMs)
    return co:authorize(opId, grantee, accounts, ttlMs, caller())
end))

exports("history", guarded(function(accountId, options)
    return await(function(done) co:history(accountId, options, done) end)
end))

exports("status", guarded(function(opId, options)
    return await(function(done) co:status(opId, options, done) end)
end))

-- ---------------------------------------------------------------------------
-- Console
-- ---------------------------------------------------------------------------
local function show(value)
    local ok, text = pcall(M.encode, value)
    return ok and text or tostring(value)
end

RegisterCommand("transactions", function(_, args)
    local verb = args[1] or "health"
    if verb == "health" then
        print(show({ phase = state.phase, store = state.mode, reason = state.reason, detail = state.detail,
            schema = state.schemaVersion, coordinator = co and co:health() or nil }))
    elseif verb == "mints" then
        print(show(policy:snapshot(now())))
    elseif not co or state.phase ~= "ready" then
        print("not ready: " .. tostring(state.phase) .. " " .. tostring(state.reason or ""))
    elseif verb == "read" and args[2] then
        local snap, why = co:read(args[2])
        print(snap and show(snap) or ("read: " .. tostring(why)))
    elseif (verb == "status" or verb == "resolve") and args[2] then
        co:status(args[2], { resolve = verb == "resolve" }, function(res, why)
            print(res and show(res) or ("status: " .. tostring(why)))
        end)
    else
        print("usage: transactions health | mints | read <account> | status <opId> | resolve <opId>")
    end
end, true)
