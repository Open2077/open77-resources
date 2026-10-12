-- =============================================================================
-- open77_containers -- tests/runtime_smoke_test.lua
-- =============================================================================
-- Loads the REAL server/main.lua against a stubbed server runtime: the lab KVP
-- registry (both convars set), the final `open77_transactions` export surface
-- (A13 §7.2: async openWorld/read/setMeta/close/listWorld/reserve/commit/
-- cancel/transfer/status gated on the coordinator's phase; sync info/allowed/
-- subjectOf) backed by the real coordinator and policy over its memory store,
-- its `ready`, `world` and `committed` events delivered asynchronously like
-- host events, recording props / bags / interactions, and a cooperative
-- scheduler for CreateThread/Wait. Then it drives the boot wait, exports,
-- console commands, the prompt net event and the maintenance loop, and
-- "restarts" the resource over the same KVP data and coordinator store.
--
-- Wiring evidence only: nothing here is the real host, a real database or a
-- client (ContainersRuntimeTests runs both shipped resources in the real host).
-- Loaded after the same modules as containers_test.lua.
-- =============================================================================

local realPrint = print
local passed, failed, failures = 0, 0, {}
local function check(condition, message)
    if condition then passed = passed + 1 else failed = failed + 1; failures[#failures + 1] = message end
end

local Model = Open77ContainersModel
local TxModel = Open77TxModel
local MAIN = __open77_read_source and __open77_read_source("server/main.lua")
assert(MAIN, "the harness must provide __open77_read_source")

-- Minimal JSON decoder (the runtime's json.decode is a host function).
local function decodeJson(text)
    local pos = 1
    local function ws() pos = text:find("[^ \t\r\n]", pos) or #text + 1 end
    local value
    local function str()
        local out = {}
        pos = pos + 1
        while true do
            local c = text:sub(pos, pos)
            if c == '"' then pos = pos + 1 break end
            if c == "\\" then
                local n = text:sub(pos + 1, pos + 1)
                local map = { n = "\n", r = "\r", t = "\t", ['"'] = '"', ["\\"] = "\\", ["/"] = "/" }
                if n == "u" then
                    out[#out + 1] = string.char(tonumber(text:sub(pos + 2, pos + 5), 16) % 256)
                    pos = pos + 6
                else
                    out[#out + 1] = map[n] or n
                    pos = pos + 2
                end
            else
                out[#out + 1] = c
                pos = pos + 1
            end
        end
        return table.concat(out)
    end
    function value()
        ws()
        local c = text:sub(pos, pos)
        if c == "{" then
            local out = {}
            pos = pos + 1
            ws()
            if text:sub(pos, pos) == "}" then pos = pos + 1 return out end
            while true do
                ws()
                local key = str()
                ws(); pos = pos + 1 -- :
                out[key] = value()
                ws()
                local sep = text:sub(pos, pos)
                pos = pos + 1
                if sep == "}" then return out end
            end
        elseif c == "[" then
            local out = {}
            pos = pos + 1
            ws()
            if text:sub(pos, pos) == "]" then pos = pos + 1 return out end
            while true do
                out[#out + 1] = value()
                ws()
                local sep = text:sub(pos, pos)
                pos = pos + 1
                if sep == "]" then return out end
            end
        elseif c == '"' then
            return str()
        elseif text:sub(pos, pos + 3) == "true" then pos = pos + 4 return true
        elseif text:sub(pos, pos + 4) == "false" then pos = pos + 5 return false
        elseif text:sub(pos, pos + 3) == "null" then pos = pos + 4 return nil
        else
            local number = text:match("^-?%d+%.?%d*[eE]?[-+]?%d*", pos)
            pos = pos + #number
            return math.tointeger(tonumber(number)) or tonumber(number)
        end
    end
    return value()
end

-- ---------------------------------------------------------------------------
-- Durable state shared by both "processes".
-- ---------------------------------------------------------------------------
local kvpData = {}
local txStore = Open77TxMemoryStore.new({ deferred = false })
local clockMs = 1700000000000

local env -- per-process runtime state

local function dispatch(name, ...)
    for _, handler in ipairs(env.handlers[name] or {}) do handler(...) end
end

local function newProcess(coordinatorReady)
    env = {
        threads = {}, handlers = {}, netHandlers = {}, commands = {}, exported = {}, printed = {},
        props = {}, nextProp = 9000, bags = {}, defines = {}, grants = {}, events = {}, hostEvents = {},
        invoking = nil,
    }
    -- Host events are queued and delivered on the next scheduler pass, never
    -- inside the call that raised them.
    local function raise(name, ...) env.hostEvents[#env.hostEvents + 1] = { name = name, args = table.pack(...) } end
    local phase = { ready = coordinatorReady == true }
    local policy = Open77TxPolicy.new({ writers = "*", rules = {
        "open77_containers sys:* * 1000; rp_salvage sys:salvage * 100" } })
    local coordinator = Open77TxCoordinator.new({
        store = txStore, now = function() return clockMs end, serverTag = "s", policy = policy,
        acl = function(resource, namespace, account) return policy:canWrite(resource, namespace, account) end,
        onCommitted = function(receipt, accounts) raise("open77_transactions:committed", receipt.opId, receipt.kind, accounts) end,
        onWorld = function(id, change, meta) raise("open77_transactions:world", id, change, meta) end,
    })
    coordinator:define({ scrap = { weightG = 1000 } }, "lab")
    local CALLER = "open77_containers"
    -- open77_transactions' exports as server/main.lua there shapes them.
    local function settle(fn)
        local r = table.pack(nil, "internal_error")
        fn(function(...) r = table.pack(...) end)
        return table.unpack(r, 1, r.n)
    end
    local asyncExports = {
        openWorld = function(props) return settle(function(done) coordinator:openWorld(props, CALLER, done) end) end,
        read = function(id) return settle(function(done) coordinator:readAccount(id, done) end) end,
        setMeta = function(id, meta) return settle(function(done) coordinator:setMeta(id, meta, CALLER, done) end) end,
        close = function(id) return settle(function(done) coordinator:close(id, CALLER, done) end) end,
        listWorld = function(after, limit) return settle(function(done) coordinator:listWorld(after, limit, done) end) end,
        transfer = function(spec) return settle(function(done) coordinator:transfer(spec, CALLER, done) end) end,
        reserve = function(spec) return settle(function(done) coordinator:reserve(spec, CALLER, done) end) end,
        commit = function(opId, final) return settle(function(done) coordinator:commit(opId, final, CALLER, done) end) end,
        cancel = function(opId, reason) return coordinator:cancel(opId, reason, CALLER) end,
        status = function(opId, options) return settle(function(done) coordinator:status(opId, options, done) end) end,
    }
    local syncExports = {
        info = function()
            return { store = "lab_kvp", phase = phase.ready and "ready" or "starting", ready = phase.ready,
                schema = 1, serverTag = "s" }
        end,
        allowed = function(resource, target, asset)
            local ns = target:match("^([a-z]+)")
            if ns == nil or TxModel.NAMESPACES[ns] == nil then return false, "invalid_account" end
            if ns == "sys" then
                local mint = asset == nil and { from = target, envelope = true, amount = 0 }
                    or { from = target, asset = asset, amount = 0 }
                local ok, why = policy:check(resource, { mint }, clockMs)
                if ok then return true end
                return false, why
            end
            if policy:canWrite(resource, ns, target:find(":", 1, true) and target or nil) then return true end
            return false, "namespace_denied"
        end,
        subjectOf = function(playerId) return "acct-" .. tostring(playerId) end,
    }

    local convars = {
        open77_containers_store = "lab_kvp",
        open77_containers_lab = "1",
    }
    function GetConvar(name, default) return convars[name] or default end
    function GetConvarInt(name, default) return math.tointeger(tonumber(convars[name] or "")) or default end
    function GetCurrentResourceName() return "open77_containers" end
    function GetResourceState(name)
        if name == "open77_transactions" or name == "open77_interactions" then return "running" end
        return "stopped"
    end
    function GetInvokingResource() return env.invoking end
    function CreateThread(fn) env.threads[#env.threads + 1] = { co = coroutine.create(fn), wake = 0 } end
    function Wait(ms) coroutine.yield(ms or 0) end
    function RegisterNetEvent(name, fn) env.netHandlers[name] = fn end
    function AddEventHandler(name, fn)
        env.handlers[name] = env.handlers[name] or {}
        table.insert(env.handlers[name], fn)
    end
    function TriggerEvent(name, ...) env.events[#env.events + 1] = { name = name, args = { ... } } end
    function RegisterCommand(name, fn, restricted) env.commands[name] = { fn = fn, restricted = restricted } end
    function exports(name, fn) env.exported[name] = fn end
    print = function(line) env.printed[#env.printed + 1] = tostring(line) end
    json = { decode = decodeJson, encode = Model.encode }
    Open77 = {
        time = { unix = function() return clockMs / 1000 end, monotonic = function() return clockMs / 1000 end },
        log = { warn = function(line) env.printed[#env.printed + 1] = "WRN " .. line end },
        database = { ready = function() return false, "database_unavailable" end },
        kvp = {
            get = function(key) return kvpData[key] end,
            set = function(key, value) kvpData[key] = value; return true end,
            find = function(prefix)
                local out = {}
                for key, value in pairs(kvpData) do
                    if key:sub(1, #prefix) == prefix then out[#out + 1] = { key = key, value = value } end
                end
                table.sort(out, function(a, b) return a.key < b.key end)
                return out
            end,
        },
        exports = {
            call = function(resource, name, ...)
                local args = table.pack(...)
                if resource ~= "open77_transactions" or not asyncExports[name] then
                    return nil, "export_not_found"
                end
                return { await = function()
                    if not phase.ready then return nil, "store_unavailable", { retryable = true, detail = "starting" } end
                    return asyncExports[name](table.unpack(args, 1, args.n))
                end }
            end,
            callSync = function(resource, name, ...)
                if resource == "open77_interactions" then
                    if name == "define" then env.defines[#env.defines + 1] = Model.deepCopy((...)) end
                    if name == "grantProp" then env.grants[#env.grants + 1] = { ... } end
                    return true
                end
                if resource == "open77_transactions" and syncExports[name] then return syncExports[name](...) end
                error("export_not_found")
            end,
        },
        props = {
            create = function(def)
                env.nextProp = env.nextProp + 1
                local id = tostring(env.nextProp)
                env.props[id] = { id = id, model = def.model, position = Model.deepCopy(def.position) }
                return id
            end,
            get = function(id) return env.props[id] end,
            remove = function(id) env.props[id] = nil; return true end,
            setTransform = function(id, t) env.props[id].position = Model.deepCopy(t.position); return true end,
            attach = function() return true end,
            detach = function() return true end,
        },
        state = {
            entity = function(kind, id)
                return {
                    set = function(_, key, value)
                        env.bags[id] = env.bags[id] or {}
                        env.bags[id][key] = Model.deepCopy(value)
                        return true
                    end,
                    get = function(_, key) return env.bags[id] and Model.deepCopy(env.bags[id][key]) or nil end,
                }
            end,
        },
        players = {
            position = function(id)
                if id == 7 then return { x = 11.0, y = 2.0, z = 3.0, bucket = 0 } end
                return nil
            end,
        },
    }
    local chunk = assert(load(MAIN, "@open77_containers/server/main.lua", "t"))
    chunk()
    return {
        coordinator = coordinator,
        becomeReady = function()
            phase.ready = true
            raise("open77_transactions:ready", { store = "lab_kvp", schema = 1 })
        end,
    }
end

local function runThreads(advanceMs)
    if advanceMs then clockMs = clockMs + advanceMs end
    for _ = 1, 200 do
        local progressed = false
        while #env.hostEvents > 0 do
            local event = table.remove(env.hostEvents, 1)
            dispatch(event.name, table.unpack(event.args, 1, event.args.n))
            progressed = true
        end
        for index = #env.threads, 1, -1 do
            local thread = env.threads[index]
            if coroutine.status(thread.co) == "dead" then
                table.remove(env.threads, index)
            elseif thread.wake <= clockMs then
                local ok, wait = coroutine.resume(thread.co)
                if not ok then error("thread failed: " .. tostring(wait)) end
                thread.wake = clockMs + (wait or 0)
                if (wait or 0) == 0 then progressed = true end
            end
        end
        if not progressed then return end
    end
end

-- Calls an export the way the host does: in its own task, with the caller set.
local function callExport(caller, name, ...)
    local args = table.pack(...)
    local result
    env.invoking = caller
    local co = coroutine.create(function() result = table.pack(env.exported[name](table.unpack(args, 1, args.n))) end)
    local ok, err = coroutine.resume(co)
    if not ok then error(err) end
    env.invoking = nil
    while coroutine.status(co) ~= "dead" do
        runThreads(0)
        local ok2, err2 = coroutine.resume(co)
        if not ok2 then error(err2) end
    end
    runThreads(0)
    return table.unpack(result, 1, result.n)
end

local function command(name, args)
    env.commands[name].fn(0, args, name)
    runThreads(0)
end

local function printedMatching(pattern)
    for index = #env.printed, 1, -1 do
        if env.printed[index]:find(pattern) then return env.printed[index] end
    end
    return nil
end

-- ---------------------------------------------------------------------------
-- Process 1: the coordinator is still starting when the resource boots.
-- ---------------------------------------------------------------------------
local process = newProcess(false)
runThreads(0)
check(printedMatching("LAB STORE") ~= nil, "the lab store announces itself")
check(printedMatching("open containers rebuilt") == nil, "no boot while the coordinator is starting")
local _, notReady = callExport("rp_salvage", "create", { kind = "crate", position = { x = 1.0, y = 2.0, z = 3.0 } })
check(notReady == "not_ready", "create answers not_ready before the boot join: " .. tostring(notReady))
process.becomeReady()
runThreads(0)
check(printedMatching("0 open containers rebuilt from the lab_kvp registry and the coordinator %(store=lab_kvp%)") ~= nil,
    "the coordinator's ready event starts the boot join")
for _, name in ipairs({ "create", "summary", "list", "find", "access", "projection", "get", "grant", "revoke",
    "reserve", "commit", "cancel", "transfer", "status", "consume", "refill", "place", "carry", "drop", "setPublic",
    "setPrivate", "close" }) do
    check(type(env.exported[name]) == "function", "export " .. name)
end
for _, name in ipairs({ "containers.spawn", "containers.here", "containers.list", "containers.info",
    "containers.remove", "containers.grant", "containers.consume", "containers.refill", "containers.seed" }) do
    check(env.commands[name] and env.commands[name].restricted == true, "restricted command " .. name)
end

local summary, why = callExport("rp_salvage", "create", {
    key = "smoke-crate", kind = "crate", model = "crate.cargo", position = { x = 10.0, y = 2.0, z = 3.0 },
    capacityG = 9000, prompt = { label = "Open", key = "E" },
})
check(summary and type(summary.id) == "string" and summary.id:match("^world:s%.") ~= nil,
    "export create: the coordinator minted " .. tostring(summary and summary.id) .. " " .. tostring(why))
check(summary and env.props[summary.propId] ~= nil, "a prop projects it")
check(summary and env.bags[summary.propId] and env.bags[summary.propId]["open77.container"].id == summary.id,
    "the bag is written through Open77.state.entity")
local id = summary and summary.id
check(id and txStore.containers[id] and txStore.containers[id].meta.key == "smoke-crate",
    "the world row carries the key and placement")
local found = callExport("rp_salvage", "find", "smoke-crate")
check(found and found.id == id, "export find: the caller's key")
check(callExport("rp_thief", "find", "smoke-crate") == nil, "keys are per owner")

command("containers.spawn", { "crate", "20", "2", "3", "model=crate.small", "key=lab-crate-1", "ttl=600" })
check(printedMatching("spawned crate world:s%.[%w.]+ key=lab%-crate%-1") ~= nil, "console spawn with a key")
command("containers.spawn", { "node", "30", "2", "3", "model=none", "key=lab-node-1", "charges=2", "regrow=60" })
check(printedMatching("spawned node world:s%.[%w.]+ key=lab%-node%-1") ~= nil, "console spawn of a point node")
command("containers.spawn", { "crate", "x" })
check(printedMatching("usage: containers.spawn") ~= nil, "bad arguments print the usage")
command("containers.spawn", { "crate", "1", "2", "3", "id=world:mine" })
check(printedMatching("world ids are minted by open77_transactions") ~= nil, "an explicit id is refused at the console")
command("containers.seed", { "lab-crate-1", "scrap", "2" })
check(printedMatching("seeded 2 scrap into world:s%.") ~= nil, "lab seed (open77_containers' own mint rule)")
local labId = env.exported.summary and callExport("open77_containers", "find", "lab-crate-1")
labId = labId and labId.id
check(labId and txStore:count(labId, "scrap") == 2, "the coordinator holds the seed")
command("containers.consume", { "lab-node-1", "1" })
check(printedMatching("charges 1/2") ~= nil, "console consume by key")

-- Prompts are declared by the maintenance loop.
runThreads(1000)
local declared = env.defines[#env.defines]
check(declared and #declared >= 2, "prop and zone prompts declared")

-- The prompt relay: a near player is accepted and logged.
source = 7
env.netHandlers["open77_containers:use"](nil, summary.propId, "use")
check(printedMatching("use player=7 prop=" .. summary.propId) ~= nil, "a near player's prompt use is accepted")
check(#(function()
    local out = {}
    for _, e in ipairs(env.events) do if e.name == "open77_containers:used" then out[#out + 1] = e end end
    return out
end)() == 1, "the owner hears open77_containers:used")

-- Authorization through the exports, the coordinator's `allowed` included.
local _, refused = callExport("rp_thief", "transfer", { opId = "thief:smoke:01", player = 7,
    lines = { { item = "scrap", count = 1, from = labId, to = "char:acct-x" } } })
check(refused == "not_authorized", "a foreign resource is refused: " .. tostring(refused))
local ok = callExport("rp_salvage", "access", id, "take")
check(ok == true, "the creator holds its own rights")
local seeded, seedWhy = callExport("rp_salvage", "transfer", { opId = "salv:smoke:seed1", player = 7,
    lines = { { item = "scrap", count = 1, from = "sys:salvage", to = id } } })
check(seeded and seeded.actor == "char:acct-7", "a mint the caller's own rule allows commits, attributed by subjectOf: "
    .. tostring(seedWhy))
local _, noMint = callExport("rp_salvage", "transfer", { opId = "salv:smoke:seed2", player = 7,
    lines = { { item = "scrap", count = 1, from = "sys:lab", to = id } } })
check(noMint == "mint_denied", "a sys: source the caller has no rule for is refused: " .. tostring(noMint))

-- Placement goes to the coordinator; its own world event is recognised.
local placed = callExport("rp_salvage", "place", id, { position = { x = 12.0, y = 2.0, z = 3.0 } })
check(placed and placed.position.x == 12.0, "export place")
runThreads(0)
check(txStore.containers[id].meta.x == 12.0, "the placement is in the coordinator's world-row metadata")
check(printedMatching("outside open77_containers") == nil, "the echo of its own write is not an outside change")

command("containers.list", {})
check(printedMatching("3 open containers") ~= nil, "console list")

-- ---------------------------------------------------------------------------
-- Process 2: the resource restarts over the same KVP data and coordinator
-- store; the coordinator is already up (its info() answers ready).
-- ---------------------------------------------------------------------------
local firstProp = summary.propId
newProcess(true)
runThreads(0)
check(printedMatching("3 open containers rebuilt from the lab_kvp registry and the coordinator") ~= nil,
    "restart rebuilds three containers without waiting for a ready event")
local after = callExport("rp_salvage", "summary", id)
check(after and after.id == id and after.position.x == 12.0, "same identity and placement after restart")
check(after and after.propId and env.props[after.propId], "a fresh prop")
check(after and after.empty == false, "the listing's weight is known at boot")
local lab = callExport("rp_salvage", "summary", labId)
check(lab and lab.owner == "open77_containers", "console containers belong to open77_containers")
command("containers.info", { "lab-crate-1" })
check(printedMatching('"scrap":2') ~= nil, "contents survive the restart (coordinator)")
local node = callExport("rp_salvage", "find", "lab-node-1")
check(node == nil, "find is per owner (the console's node belongs to open77_containers)")
node = callExport("open77_containers", "find", "lab-node-1")
check(node and node.charges == 1, "node charges survive the restart")
command("containers.refill", { "lab-node-1" })
check(printedMatching("charges 2/2") ~= nil, "console refill to full, by key")
command("containers.remove", { "lab-crate-1" })
check(printedMatching("close refused: not_empty") ~= nil, "remove refuses a non-empty container")
command("containers.remove", { "lab-crate-1", "force" })
check(printedMatching("closed " .. labId:gsub("%p", "%%%0")) ~= nil, "forced remove")
check(txStore.containers[labId] == nil, "the drained world row is deleted")
check(firstProp ~= nil, "first process had a prop")

TestSummary = ("[open77_containers runtime smoke] %d passed, %d failed"):format(passed, failed)
realPrint(TestSummary)
for _, failure in ipairs(failures) do realPrint("  FAIL " .. failure) end
print = realPrint
TestResult = { passed = passed, failed = failed, failures = failures }
