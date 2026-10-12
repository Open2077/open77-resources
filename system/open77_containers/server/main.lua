-- =============================================================================
-- open77_containers -- server/main.lua
-- =============================================================================
-- Runtime wiring of the container service (server/service.lua): the registry
-- store, the A13 coordinator adapter (`open77_transactions`, contract §7.2),
-- the platform natives, the exports, the prompt relay, the maintenance loop
-- and the lab console commands. docs/world-interaction/a6-containers.md is the
-- contract.
--
-- Boot waits for BOTH stores: the registry (SQL migrated, or the lab KVP) and
-- the coordinator's `open77_transactions:ready` (or `info().ready` when it was
-- up first). The coordinator is not a manifest dependency: it ships no client
-- half, and the client validates every dependency of a client-shipped resource
-- (docs/research/rp-server-build-rounds.md).
-- =============================================================================

local RESOURCE = GetCurrentResourceName()
local Model = Open77ContainersModel
local COORDINATOR = "open77_transactions"

local function log(level, message)
    local line = "[open77_containers] " .. tostring(message)
    if level == "warn" and Open77.log and Open77.log.warn then
        Open77.log.warn(line)
    else
        print(line)
    end
end

local function nowMs() return math.floor(Open77.time.unix() * 1000) end

-- ---------------------------------------------------------------------------
-- Registry store: chosen once, here, never switched (A13 §4.1).
-- ---------------------------------------------------------------------------
local storeMode = GetConvar("open77_containers_store", "sql")
local labSwitch = GetConvarInt("open77_containers_lab", 0) == 1

local function jsonDecode(text)
    local ok, value = pcall(json.decode, text)
    if ok then return value end
    return nil
end

local store, storeWhy
if storeMode == "sql" then
    store = Open77ContainersStore.sql(Open77.database, { decode = jsonDecode, now = nowMs })
elseif storeMode == "lab_kvp" then
    if labSwitch then
        store = Open77ContainersStore.kvp(Open77.kvp, { decode = jsonDecode })
        log("warn", "LAB STORE: open77_containers keeps its registry in Open77.kvp; data is disposable")
    else
        storeWhy = "lab_kvp needs the convar open77_containers_lab 1 as well"
    end
else
    storeWhy = "unknown store mode " .. tostring(storeMode)
end

-- ---------------------------------------------------------------------------
-- Coordinator adapter. Every mutating call is an asynchronous export (the
-- coordinator waits on its store). Reasons pass through as the coordinator
-- gives them (A13 §7.2 table), with two of our own:
--   coordinator_unavailable  the request never reached it (not running, not
--                            ready to dispatch, request limit) -- retryable
--   in_doubt                 a WRITE reached it and the answer was lost
--                            (export timeout, the coordinator stopped mid-call):
--                            retry with the same opId or poll `status`, exactly
--                            like the coordinator's own in_doubt
-- ---------------------------------------------------------------------------
local ANSWER_LOST = { export_timeout = true, export_resource_stopped = true, promise_cancelled = true }
local WRITES = { openWorld = true, setMeta = true, close = true, reserve = true, commit = true, transfer = true }

local function txCall(name, cb, ...)
    if GetResourceState(COORDINATOR) ~= "running" then
        return cb(nil, "coordinator_unavailable", { retryable = true, detail = "not_running" })
    end
    local promise, why = Open77.exports.call(COORDINATOR, name, ...)
    if not promise then return cb(nil, "coordinator_unavailable", { retryable = true, detail = why }) end
    CreateThread(function()
        local a, b, c = promise:await()
        if a == nil and type(b) == "string" and ANSWER_LOST[b] then
            if WRITES[name] then return cb(nil, "in_doubt", { retryable = true, detail = b }) end
            return cb(nil, "coordinator_unavailable", { retryable = true, detail = b })
        end
        cb(a, b, c)
    end)
end

local tx = {
    openWorld = function(props, cb) txCall("openWorld", cb, props) end,
    read = function(id, cb) txCall("read", cb, id) end,
    setMeta = function(id, meta, cb) txCall("setMeta", cb, id, meta) end,
    close = function(id, cb) txCall("close", cb, id) end,
    listWorld = function(after, limit, cb) txCall("listWorld", cb, after, limit) end,
    reserve = function(spec, cb) txCall("reserve", cb, spec) end,
    commit = function(opId, final, cb) txCall("commit", cb, opId, final) end,
    cancel = function(opId, reason, cb) txCall("cancel", cb, opId, reason) end,
    transfer = function(spec, cb) txCall("transfer", cb, spec) end,
    status = function(opId, options, cb) txCall("status", cb, opId, options) end,
}

-- The coordinator's synchronous exports (`info`, `allowed`, `subjectOf` never
-- yield). The synchronous form raises on a dispatch failure: pcall it.
local function coordinatorSync(name, ...)
    if GetResourceState(COORDINATOR) ~= "running" then return false end
    return pcall(Open77.exports.callSync, COORDINATOR, name, ...)
end

-- The real caller's right to an account (a namespace, per-part grants
-- included) or to mint an asset from a `sys:` account -- the coordinator's own
-- policy (tunables `writers`, `mint1..6`). No fallback: without the
-- coordinator nothing would commit anyway.
local function allowed(resource, target, asset)
    local ok, answer, why = coordinatorSync("allowed", resource, target, asset)
    if not ok then return false, "coordinator_unavailable" end
    if answer == true then return true end
    return false, type(why) == "string" and why or "namespace_denied"
end

local function subjectOf(playerId)
    local ok, subject = coordinatorSync("subjectOf", playerId)
    if ok and type(subject) == "string" then return subject end
    return nil
end

local function coordinatorInfo()
    local ok, info = coordinatorSync("info")
    if ok and type(info) == "table" then return info end
    return nil
end

-- ---------------------------------------------------------------------------
-- Platform adapters
-- ---------------------------------------------------------------------------
local props = {
    create = function(definition) return Open77.props.create(definition) end,
    get = function(id) return Open77.props.get(id) end,
    remove = function(id) return Open77.props.remove(id) end,
    setTransform = function(id, transform) return Open77.props.setTransform(id, transform) end,
    attach = function(id, binding) return Open77.props.attach(id, binding) end,
    detach = function(id) return Open77.props.detach(id) end,
}

local bags = {
    set = function(propId, key, value)
        local ok, bag = pcall(Open77.state.entity, "prop", propId)
        if not ok or type(bag) ~= "table" then return nil, tostring(bag) end
        local okSet, done, reason = pcall(bag.set, bag, key, value)
        if not okSet then return nil, tostring(done) end
        if not done then return nil, reason end
        return true
    end,
    get = function(propId, key)
        local ok, bag = pcall(Open77.state.entity, "prop", propId)
        if not ok or type(bag) ~= "table" then return nil end
        local okGet, value = pcall(bag.get, bag, key)
        if okGet then return value end
        return nil
    end,
}

local function interactionsCall(name, ...)
    if GetResourceState("open77_interactions") ~= "running" then return nil, "interactions_unavailable" end
    local ok, a, b = pcall(Open77.exports.callSync, "open77_interactions", name, ...)
    if not ok then return nil, tostring(a) end
    return a, b
end

local interactions = {
    define = function(list) return interactionsCall("define", list) end,
    clear = function()
        local ok, why = interactionsCall("clear")
        if not ok and why == "no_declaration" then return true end
        return ok, why
    end,
    grantProp = function(propId, grantee, options) return interactionsCall("grantProp", propId, grantee, options) end,
    revokeProp = function(propId, grantee) return interactionsCall("revokeProp", propId, grantee) end,
}

local players = {
    position = function(playerId)
        if math.type(playerId) ~= "integer" or playerId < 1 then return nil end
        return Open77.players.position(playerId)
    end,
}

local service = Open77ContainersService.new({
    store = store or Open77ContainersStore.memory(), tx = tx, props = props, bags = bags,
    interactions = interactions, players = players, allowed = allowed, subjectOf = subjectOf,
    emit = function(event, ...) TriggerEvent(event, ...) end,
    spawn = function(fn) CreateThread(fn) end,
    nowMs = nowMs, log = log, resourceName = RESOURCE,
})

-- ---------------------------------------------------------------------------
-- Boot: the registry first, then the coordinator's ready, then the join.
-- ---------------------------------------------------------------------------
local registryReady = false
local nextAttemptAt = 0
local said = {}
local function sayOnce(key, level, message)
    if said[key] then return end
    said[key] = true
    log(level, message)
end

local function begin()
    if service.ready or service.starting or not registryReady or nowMs() < nextAttemptAt then return end
    local info = coordinatorInfo()
    if not info then
        return sayOnce("waiting", "info", "waiting for " .. COORDINATOR .. " (list it in resources.load)")
    end
    if info.phase == "refused" then
        return sayOnce("refused", "warn", COORDINATOR .. " refused its store (" .. tostring(info.reason)
            .. "); containers stay inert until it is ready")
    end
    if not info.ready then return end -- its `open77_transactions:ready` follows
    if (info.store == "lab_kvp") ~= (storeMode == "lab_kvp") then
        sayOnce("mixed", "warn", ("registry store %s with coordinator store %s: a disposable half will not "
            .. "survive what the durable half keeps"):format(storeMode, tostring(info.store)))
    end
    service:start(function(count, why)
        if not count then
            nextAttemptAt = nowMs() + 5000
            log("warn", "boot join failed: " .. tostring(why) .. "; retrying in 5 s")
            return
        end
        log("info", ("%d open containers rebuilt from the %s registry and the coordinator (store=%s)")
            :format(count, storeMode, tostring(info.store)))
    end, { yield = function() if coroutine.isyieldable() then Wait(0) end end })
end

if storeWhy then
    log("warn", "refusing to start: " .. storeWhy)
elseif storeMode == "sql" then
    local queued, reason = Open77.database.ready(function()
        store:migrate(function(ok, why)
            if not ok then
                log("warn", "schema migration refused: " .. tostring(why) .. "; containers stay inert")
                return
            end
            registryReady = true
            begin()
        end)
    end)
    if not queued then
        log("warn", "no database (" .. tostring(reason) .. "); containers stay inert. A lab without a database "
            .. "uses open77_containers_store lab_kvp + open77_containers_lab 1.")
    end
else
    registryReady = true
    CreateThread(begin)
end

AddEventHandler("open77_transactions:ready", function()
    if service.ready then
        log("info", COORDINATOR .. " is ready again")
        return
    end
    CreateThread(begin)
end)

-- ---------------------------------------------------------------------------
-- Exports. Mutating exports wait for the store and the coordinator: call them
-- with Open77.exports.call(...):await(), not the synchronous sugar
-- (`export_yielded`). Reads (summary, list, find, access, projection) are
-- synchronous.
-- ---------------------------------------------------------------------------
local function await(fn)
    local done, result = false, nil
    fn(function(...) result, done = table.pack(...), true end)
    while not done do Wait(0) end
    return table.unpack(result, 1, result.n)
end

exports("create", function(spec)
    local caller = GetInvokingResource()
    return await(function(cb) service:create(caller, spec, cb) end)
end)
exports("summary", function(id) return service:summary(id) end)
exports("list", function(filter) return service:list(filter) end)
exports("find", function(key) return service:findByKey(GetInvokingResource(), key) end)
exports("access", function(id, right, resource)
    return service:access(id, resource or GetInvokingResource(), right)
end)
exports("projection", function(id) return service:projectionOf(id) end)
exports("get", function(id)
    local caller = GetInvokingResource()
    return await(function(cb) service:get(caller, id, cb) end)
end)
exports("grant", function(id, grantee, rights, options)
    local caller = GetInvokingResource()
    return await(function(cb) service:grant(caller, id, grantee, rights, options, cb) end)
end)
exports("revoke", function(id, grantee)
    local caller = GetInvokingResource()
    return await(function(cb) service:revoke(caller, id, grantee, cb) end)
end)
exports("reserve", function(spec)
    local caller = GetInvokingResource()
    return await(function(cb) service:reserve(caller, spec, cb) end)
end)
exports("commit", function(opId, final)
    local caller = GetInvokingResource()
    return await(function(cb) service:commit(caller, opId, final, cb) end)
end)
exports("cancel", function(opId, reason)
    local caller = GetInvokingResource()
    return await(function(cb) service:cancel(caller, opId, reason, cb) end)
end)
exports("transfer", function(spec)
    local caller = GetInvokingResource()
    return await(function(cb) service:transfer(caller, spec, cb) end)
end)
exports("status", function(opId, options)
    return await(function(cb) service:status(opId, options, cb) end)
end)
exports("consume", function(id, options)
    local caller = GetInvokingResource()
    return await(function(cb) service:consume(caller, id, options, cb) end)
end)
exports("refill", function(id, options)
    local caller = GetInvokingResource()
    return await(function(cb) service:refill(caller, id, options, cb) end)
end)
exports("place", function(id, placement)
    local caller = GetInvokingResource()
    return await(function(cb) service:place(caller, id, placement, cb) end)
end)
exports("carry", function(id, binding)
    local caller = GetInvokingResource()
    return await(function(cb) service:carryStart(caller, id, binding, cb) end)
end)
exports("drop", function(id, placement)
    local caller = GetInvokingResource()
    return await(function(cb) service:drop(caller, id, placement, cb) end)
end)
exports("setPublic", function(id, meta)
    local caller = GetInvokingResource()
    return await(function(cb) service:setMeta(caller, id, "public", meta, cb) end)
end)
exports("setPrivate", function(id, meta)
    local caller = GetInvokingResource()
    return await(function(cb) service:setMeta(caller, id, "private", meta, cb) end)
end)
exports("close", function(id, options)
    local caller = GetInvokingResource()
    return await(function(cb) service:close(caller, id, options, cb) end)
end)

-- ---------------------------------------------------------------------------
-- Events
-- ---------------------------------------------------------------------------
RegisterNetEvent("open77_containers:use", function(targetId, propId, choiceId)
    local playerId = math.tointeger(tonumber(source))
    if not playerId or playerId < 1 then return end
    local ok, why = service:use(playerId, targetId, propId, choiceId)
    if ok then
        log("info", ("use player=%d prop=%s target=%s choice=%s"):format(playerId, tostring(propId),
            tostring(targetId), tostring(choiceId)))
    elseif why ~= "rate_limited" then
        log("info", ("use refused for player %d: %s"):format(playerId, tostring(why)))
    end
end)

AddEventHandler("open77_transactions:committed", function(opId, kind, accounts)
    service:onCommitted(opId, kind, accounts)
end)

AddEventHandler("open77_transactions:world", function(id, change, meta)
    service:onWorld(id, change, meta)
end)

AddEventHandler("onPropRemoved", function(id, reason, resource)
    if resource == RESOURCE then service:onPropRemoved(tostring(id), reason) end
end)

AddEventHandler("onResourceStop", function(name)
    if name == COORDINATOR then
        log("warn", COORDINATOR .. " stopped; value operations answer coordinator_unavailable until it is back")
    elseif name ~= RESOURCE then
        service:onResourceStop(name)
    end
end)

AddEventHandler("onResourceStart", function(name)
    if name == "open77_interactions" and service.ready then service:reapplyInteractions() end
end)

CreateThread(function()
    local tick = 0
    while true do
        Wait(1000)
        tick = tick + 1
        if not service.ready then
            begin() -- a missed ready event, or a boot join to retry
        else
            local ok, err = pcall(service.sweep, service,
                { verifyBags = tick % 10 == 0, yield = function() Wait(0) end })
            if not ok then log("warn", "sweep failed: " .. tostring(err)) end
        end
    end
end)

-- ---------------------------------------------------------------------------
-- Lab console (restricted commands: the server console always may, a player
-- needs `command.containers.*`). Containers spawned here are owned by
-- open77_containers; remove/grant/consume act with the container OWNER's
-- authority, which is what an operator at the console holds. A container is
-- named by its world id or by its key.
-- ---------------------------------------------------------------------------
local PROMPTS = {
    crate = { label = "Open", key = "E", distance = 2.0 },
    pile = { label = "Pick up", key = "E", distance = 2.0 },
    node = { label = "Search", key = "E", distance = 2.5 },
}

local function reply(source, message)
    print("[open77_containers] " .. message)
    if source and source > 0 and Open77.chat and Open77.chat.send then pcall(Open77.chat.send, source, message) end
end

-- Options after the position: key=value pairs.
--   model=<alias>|none   prop host (none = a point container, prompt on a zone)
--   bucket=<n> capacity=<grams> key=<name> ttl=<seconds> reach=<m> projection=external
--   charges=<n> regrow=<seconds>   (nodes)   label=<text_without_spaces>
local function parseOptions(args, first)
    local options = {}
    for index = first, #args do
        local key, value = tostring(args[index]):match("^([%a]+)=(.+)$")
        if not key then return nil, "bad option " .. tostring(args[index]) end
        if key == "id" then return nil, "world ids are minted by " .. COORDINATOR .. "; name it with key=<name>" end
        options[key] = value
    end
    return options
end

local function resolve(source, text)
    local id, why = service:resolve(text)
    if not id then reply(source, ("%s: %s"):format(tostring(text), tostring(why))) end
    return id
end

local function spawn(source, kind, position, bucket, options)
    if not Model.KINDS[kind] then return reply(source, "kind must be crate, pile or node") end
    local model = options.model
    if model == "none" then model = false end
    local spec = {
        key = options.key, kind = kind, model = model, position = position,
        bucket = math.tointeger(tonumber(options.bucket or "")) or bucket or 0,
        prompt = PROMPTS[kind], label = options.label or ("Lab " .. kind),
        capacityG = math.tointeger(tonumber(options.capacity or "")),
        ttlMs = tonumber(options.ttl or "") and math.floor(tonumber(options.ttl) * 1000) or nil,
        reachM = tonumber(options.reach or ""),
        projection = options.projection,
    }
    if spec.projection == "external" then spec.prompt = nil end
    if kind == "node" then
        spec.node = {
            charges = math.tointeger(tonumber(options.charges or "3")) or 3,
            regrowMs = math.floor((tonumber(options.regrow or "300") or 300) * 1000),
        }
    end
    service:create(RESOURCE, spec, function(summary, why, info)
        if not summary then return reply(source, "spawn refused: " .. tostring(why)) end
        reply(source, ("spawned %s %s%s prop=%s at %.2f %.2f %.2f bucket %d%s"):format(summary.kind, summary.id,
            options.key and (" key=" .. options.key) or "", tostring(summary.propId), summary.position.x,
            summary.position.y, summary.position.z, summary.bucket, info and info.existing and " (existing)" or ""))
    end)
end

RegisterCommand("containers.spawn", function(source, args)
    local x, y, z = tonumber(args[2]), tonumber(args[3]), tonumber(args[4])
    local options, why = parseOptions(args, 5)
    if not args[1] or not x or not y or not z or not options then
        return reply(source, (why and (why .. "; ") or "") .. "usage: containers.spawn <crate|pile|node> <x> <y> <z> "
            .. "[model=<alias>|none] [bucket=] [capacity=] [key=<name>] [ttl=s] [reach=m] [charges=] [regrow=s] "
            .. "[projection=external]")
    end
    spawn(source, args[1], { x = x, y = y, z = z }, 0, options)
end, true)

RegisterCommand("containers.here", function(source, args)
    local pid = math.tointeger(tonumber(args[1] or ""))
    local options, why = parseOptions(args, 3)
    if not pid or pid < 1 or not args[2] or not options then
        return reply(source, (why and (why .. "; ") or "") .. "usage: containers.here <playerId> <crate|pile|node> [key=value ...]")
    end
    local position = Open77.players.position(pid)
    if not position then return reply(source, "player " .. pid .. " has no position") end
    spawn(source, args[2], { x = position.x + 1.5, y = position.y, z = position.z }, position.bucket or 0, options)
end, true)

RegisterCommand("containers.list", function(source, args)
    local bucket = args[1] and math.tointeger(tonumber(args[1])) or nil
    local rows = service:list({ bucket = bucket })
    reply(source, ("%d open containers"):format(#rows))
    for index = 1, math.min(#rows, 100) do
        local row = rows[index]
        local key = service.rows[row.id] and service.rows[row.id].key
        reply(source, ("%s%s %s owner=%s prop=%s bucket=%d pos=%.1f,%.1f,%.1f%s%s"):format(row.id,
            key and (" key=" .. key) or "", row.kind, row.owner, tostring(row.propId), row.bucket, row.position.x,
            row.position.y, row.position.z,
            row.empty == nil and (row.fill and (" fill=" .. tostring(row.fill)) or "")
                or (row.empty and " empty" or (" fill=" .. tostring(row.fill))),
            row.charges and (" charges=" .. row.charges .. "/" .. row.maxCharges) or ""))
    end
end, true)

RegisterCommand("containers.info", function(source, args)
    local id = resolve(source, args[1])
    if not id then return end
    local row = service.rows[id]
    service:get(row.owner, id, function(detail, why)
        if not detail then return reply(source, "info refused: " .. tostring(why)) end
        local ok, encoded = pcall(json.encode, {
            summary = detail.summary, key = detail.key, items = detail.items, grants = detail.grants,
            private = detail.private, contentsError = detail.contentsError,
        })
        reply(source, ok and encoded or tostring(encoded))
    end)
end, true)

RegisterCommand("containers.remove", function(source, args)
    local id = resolve(source, args[1])
    if not id then return end
    service:close(service.rows[id].owner, id, { force = args[2] == "force", reason = "console" }, function(ok, why)
        reply(source, ok and ("closed " .. id) or ("close refused: " .. tostring(why)))
    end)
end, true)

RegisterCommand("containers.grant", function(source, args)
    local grantee = args[2]
    if not args[1] or not grantee or not args[3] then
        return reply(source, "usage: containers.grant <id|key> <resource> <right[,right...]> [ttlSeconds]")
    end
    local id = resolve(source, args[1])
    if not id then return end
    local rights = {}
    for right in tostring(args[3]):gmatch("[^,]+") do rights[#rights + 1] = right end
    local ttl = tonumber(args[4] or "")
    service:grant(service.rows[id].owner, id, grantee, rights, ttl and { ttlMs = math.floor(ttl * 1000) } or nil,
        function(ok, why) reply(source, ok and ("granted " .. args[3] .. " to " .. grantee) or ("grant refused: " .. tostring(why))) end)
end, true)

RegisterCommand("containers.consume", function(source, args)
    local id = resolve(source, args[1])
    if not id then return end
    service:consume(service.rows[id].owner, id, { count = math.tointeger(tonumber(args[2] or "1")) or 1,
        ref = "console:" .. tostring(nowMs()) }, function(state, why)
        if not state then return reply(source, "consume refused: " .. tostring(why)) end
        reply(source, ("charges %d/%d%s"):format(state.charges, state.maxCharges, state.depleted and " depleted" or ""))
    end)
end, true)

RegisterCommand("containers.refill", function(source, args)
    local id = resolve(source, args[1])
    if not id then return end
    local charges = args[2] and math.tointeger(tonumber(args[2])) or nil
    service:refill(service.rows[id].owner, id, { charges = charges }, function(state, why)
        if not state then return reply(source, "refill refused: " .. tostring(why)) end
        reply(source, ("charges %d/%d%s"):format(state.charges, state.maxCharges, state.depleted and " depleted" or ""))
    end)
end, true)

-- LAB ONLY: mints items from `sys:lab` into a container, as open77_containers.
-- The coordinator must give open77_containers a mint rule on `sys:lab`
-- (tunable mint1..6, e.g. `open77_containers sys:lab * 100`) and the item must
-- be defined there (`define`, by whichever resource owns the item).
RegisterCommand("containers.seed", function(source, args)
    local item, count = args[2], math.tointeger(tonumber(args[3] or ""))
    if not args[1] or not item or not count then
        return reply(source, "usage: containers.seed <id|key> <item> <count>")
    end
    local id = resolve(source, args[1])
    if not id then return end
    tx.transfer({ opId = "lab-seed-" .. tostring(nowMs()), kind = "lab_seed",
        lines = { { item = item, count = count, from = "sys:lab", to = id } } }, function(receipt, why)
        if not receipt then return reply(source, "seed refused: " .. tostring(why)) end
        service:refreshContents(id)
        reply(source, ("seeded %d %s into %s"):format(count, item, id))
    end)
end, true)
