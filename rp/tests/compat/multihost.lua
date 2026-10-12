-- tests/compat/multihost.lua: several Open77 server resources at once, offline (B3 wallet suite).
--
-- An addition to fakehost.lua, not a replacement: fakehost runs ONE resource in the global
-- state; this host gives every resource its own environment (its own globals, as its own VM
-- would), so rp_economy, rp_bank, the open77_transactions stand-in and small caller shims can
-- run together and call each other. It models the platform rules the wallet adapters depend on
-- (wiki/server-exports.md, wiki/data/api.json):
--
--   exports.res:fn(...) / Open77.exports.callSync   inline, raises "export res:fn <reason>",
--                                                    a yielding callee fails with export_yielded
--   Open77.exports.call                              Promise, the target runs it as a task on
--                                                    the next pass; await -> values | nil, reason;
--                                                    30 s export_timeout; a stopped target
--                                                    rejects with export_resource_stopped
--   GetInvokingResource()                            the immediate caller inside an export
--                                                    coroutine, nil in threads it spawns
--   TriggerEvent                                     host-wide, queued, delivered at the next pass
--                                                    in resource-name order, arguments copied
--   Open77.database callbacks                        completed on a later pass (never inline);
--                                                    `.await` yields once; a stopped resource's
--                                                    completions are dropped (D6)
--
-- The clock is simulated: MH.run(seconds) advances it in MH.tick steps. Uncaught script errors
-- are collected in MH.errors instead of aborting the run, so a scenario can report them.

MH = {}

local STD = {}
for _, name in ipairs({
    "assert", "error", "ipairs", "next", "pairs", "pcall", "xpcall", "rawequal", "rawget", "rawlen",
    "rawset", "select", "setmetatable", "getmetatable", "tonumber", "tostring", "type", "string",
    "table", "math", "utf8", "coroutine", "os", "load",
}) do
    STD[name] = _G[name]
end

function MH.reset()
    MH.now = 1000.0
    MH.tick = 0.25
    MH.resources = {}
    MH.queue = {}
    MH.players = {}
    MH.kvp = {}            -- [resource] = { key = value }; survives restarts, like the KVP file
    MH.sql = nil           -- function(kind, sql, params, resource) -> result, raises on SQL error
    MH.dbMode = "sql"      -- "sql" | "none" (no database bridge) | "silent" (never answers)
    MH.logs = {}
    MH.errors = {}
    MH.chat = {}
    MH.commands = {}
    MH.convars = {}
    MH.tunables = {}       -- [resource] = { key = value }: the operator's tunable values
    MH.pending = {}
    MH.threadOf = setmetatable({}, { __mode = "k" })
    MH.invoker = setmetatable({}, { __mode = "k" })
    MH.syncCo = setmetatable({}, { __mode = "k" })
    MH.syncDepth = 0
    MH.generation = 0
    MH.shared = {}
end

local function log(resource, level, ...)
    local parts = {}
    for i = 1, select("#", ...) do parts[#parts + 1] = tostring(select(i, ...)) end
    local line = ("[%s] %s%s"):format(resource, level and (level .. " ") or "", table.concat(parts, " "))
    MH.logs[#MH.logs + 1] = line
end

function MH.grep(pattern)
    local out = {}
    for _, line in ipairs(MH.logs) do
        if line:find(pattern) then out[#out + 1] = line end
    end
    return out
end

-- ---------------------------------------------------------------------------------------------
-- Values cross every boundary by copy, with the platform's refusals.

local function copyValue(v, depth, seen)
    local t = type(v)
    if t == "table" then
        if depth > 16 or seen[v] then error("not_serializable", 0) end
        seen[v] = true
        local out = {}
        for k, x in pairs(v) do
            local kt = type(k)
            if kt ~= "string" and kt ~= "number" then error("not_serializable", 0) end
            out[k] = copyValue(x, depth + 1, seen)
        end
        seen[v] = nil
        return out
    elseif t == "function" or t == "userdata" or t == "thread" then
        error("not_serializable", 0)
    elseif t == "number" and (v ~= v or v == math.huge or v == -math.huge) then
        error("not_serializable", 0)
    end
    return v
end

local function copyPack(p)
    local out = { n = p.n }
    for i = 1, p.n do out[i] = copyValue(p[i], 0, {}) end
    return out
end
MH.copy = function(v) return copyValue(v, 0, {}) end

-- ---------------------------------------------------------------------------------------------
-- Threads

local function spawn(R, fn, invoker, immediate, ...)
    local args = table.pack(...)
    local co = coroutine.create(function() return fn(table.unpack(args, 1, args.n)) end)
    local th = { co = co, wake = MH.now, resource = R }
    R.threads[#R.threads + 1] = th
    MH.threadOf[co] = th
    if invoker then MH.invoker[co] = invoker end
    if immediate then MH.resume(th) end
    return th
end

function MH.resume(th)
    if th.dead or coroutine.status(th.co) ~= "suspended" then return end
    local ok, err = coroutine.resume(th.co)
    if not ok then
        th.dead = true
        local text = ("%s: %s"):format(th.resource.name, tostring(err))
        MH.errors[#MH.errors + 1] = text
        log(th.resource.name, "ERR", "uncaught: " .. tostring(err))
    end
end

local function waitFor(seconds)
    local co = coroutine.running()
    local th = MH.threadOf[co]
    if not th then
        if MH.syncCo[co] then error("export_yielded", 0) end
        error("Wait called outside a managed thread", 2)
    end
    th.wake = MH.now + (seconds or 0)
    coroutine.yield()
end

-- ---------------------------------------------------------------------------------------------
-- Promises (Open77.exports.call)

local Promise = {}
Promise.__index = Promise

function Promise:status() return self.state end

function Promise:await()
    while self.state == "pending" do waitFor(0) end
    if self.state == "resolved" then return table.unpack(self.values, 1, self.values.n) end
    return nil, self.reason
end

local function settle(p, state, reason)
    if p.state ~= "pending" then return end
    p.state = state
    p.reason = reason
    if p.task then p.task.dead = true end
end

-- ---------------------------------------------------------------------------------------------
-- Exports

local function exportError(target, name, reason)
    error(("export %s:%s %s"):format(target, name, reason), 0)
end

local function syncCall(caller, target, name, args)
    local T = MH.resources[target]
    if not T or not T.running then exportError(target, name, "export_resource_unavailable") end
    local fn = T.exports[name]
    if not fn then exportError(target, name, "export_not_found") end
    if MH.syncDepth >= 8 then exportError(target, name, "export_recursion_limit") end
    local okArgs, cargs = pcall(copyPack, args)
    if not okArgs then exportError(target, name, "export_arguments_not_serializable") end
    local co = coroutine.create(function() return fn(table.unpack(cargs, 1, cargs.n)) end)
    MH.syncCo[co] = true
    MH.invoker[co] = caller
    MH.syncDepth = MH.syncDepth + 1
    local res = table.pack(coroutine.resume(co))
    MH.syncDepth = MH.syncDepth - 1
    if not res[1] then
        if res[2] == "export_yielded" then exportError(target, name, "export_yielded") end
        exportError(target, name, "export_raised " .. tostring(res[2]))
    end
    if coroutine.status(co) ~= "dead" then exportError(target, name, "export_yielded") end
    local okRes, values = pcall(copyPack, table.pack(table.unpack(res, 2, res.n)))
    if not okRes then exportError(target, name, "export_results_not_serializable") end
    return table.unpack(values, 1, values.n)
end

local function asyncCall(R, target, name, ...)
    local T = MH.resources[target]
    if not T or not T.running then return nil, "export_resource_unavailable" end
    local fn = T.exports[name]
    if not fn then return nil, "export_not_found" end
    local okArgs, cargs = pcall(copyPack, table.pack(...))
    if not okArgs then return nil, "export_arguments_not_serializable" end
    local p = setmetatable({ state = "pending", caller = R.name, target = target, name = name,
        deadline = MH.now + 30 }, Promise)
    p.task = spawn(T, function()
        local res = table.pack(pcall(fn, table.unpack(cargs, 1, cargs.n)))
        if p.state ~= "pending" then return end
        if res[1] then
            local okRes, values = pcall(copyPack, table.pack(table.unpack(res, 2, res.n)))
            if okRes then
                p.values = values
                p.state = "resolved"
            else
                p.state, p.reason = "rejected", "export_results_not_serializable"
            end
        else
            p.state, p.reason = "rejected", tostring(res[2])
        end
    end, R.name, false)
    MH.pending[#MH.pending + 1] = p
    return p
end

local function makeExports(R)
    local proxies = {}
    return setmetatable({}, {
        __call = function(_, name, fn)
            if type(name) ~= "string" or name == "" or #name > 64 then return nil, "invalid_export_name" end
            if type(fn) ~= "function" then return nil, "export_function_required" end
            R.exports[name] = fn
            return true
        end,
        __index = function(_, target)
            local proxy = proxies[target]
            if proxy then return proxy end
            proxy = setmetatable({}, {
                __index = function(self, name)
                    return function(first, ...)
                        local args
                        if first == self then args = table.pack(...) else args = table.pack(first, ...) end
                        return syncCall(R.name, target, name, args)
                    end
                end,
            })
            proxies[target] = proxy
            return proxy
        end,
        __newindex = function() error("Open77: exports is not assignable", 2) end,
    })
end

-- ---------------------------------------------------------------------------------------------
-- Database bridge over the scenario's interpreter MH.sql(kind, sql, params, resource)

local function runSql(R, kind, sql, params)
    if MH.dbMode ~= "sql" then error("database_unavailable", 0) end
    if not MH.sql then error("multihost: no SQL interpreter installed", 0) end
    return MH.sql(kind, sql, params or {}, R.name)
end

local function dbMethod(R, kind)
    return setmetatable({
        await = function(sql, params)
            waitFor(0)
            return runSql(R, kind, sql, params)
        end,
    }, {
        __call = function(_, sql, params, cb)
            if type(params) == "function" then params, cb = nil, params end
            local generation = R.generation
            R.db[#R.db + 1] = function()
                if R.generation ~= generation or not R.running then return end
                local ok, result = pcall(runSql, R, kind, sql, params)
                if cb then
                    if ok then cb(result, nil) else cb(nil, tostring(result)) end
                end
            end
            return true
        end,
    })
end

local function makeOpen77(R)
    local O = {}
    O.exports = {
        call = function(target, name, ...) return asyncCall(R, target, name, ...) end,
        callSync = function(target, name, ...) return syncCall(R.name, target, name, table.pack(...)) end,
    }
    O.database = {
        query = dbMethod(R, "query"), single = dbMethod(R, "single"), scalar = dbMethod(R, "scalar"),
        insert = dbMethod(R, "insert"), update = dbMethod(R, "update"),
        ready = function(fn)
            if MH.dbMode == "none" then return false, "database_unavailable" end
            if MH.dbMode == "silent" then return true end
            spawn(R, fn, nil, false)
            return true
        end,
        isReady = function()
            if MH.dbMode == "sql" then return true end
            if MH.dbMode == "silent" then return false, "database_connecting" end
            return false, "database_unavailable"
        end,
    }
    local function store()
        MH.kvp[R.name] = MH.kvp[R.name] or {}
        return MH.kvp[R.name]
    end
    O.kvp = {
        get = function(key, default)
            local v = store()[key]
            if v == nil then return default end
            return v
        end,
        set = function(key, value) store()[key] = value return true end,
        delete = function(key)
            local had = store()[key] ~= nil
            store()[key] = nil
            return had
        end,
        keys = function(prefix)
            local out = {}
            for k in pairs(store()) do
                if k:sub(1, #(prefix or "")) == (prefix or "") then out[#out + 1] = k end
            end
            table.sort(out)
            return out
        end,
    }
    O.time = {
        unix = function() return MH.now end,
        monotonic = function() return MH.now end,
    }
    O.players = {
        identifier = function(id) local p = MH.players[tonumber(id)] return p and p.identifier end,
        name = function(id) local p = MH.players[tonumber(id)] return p and p.name end,
        get = function(id) local p = MH.players[tonumber(id)] return p and { ready = p.ready ~= false } or nil end,
        all = function()
            local out = {}
            for id in pairs(MH.players) do out[#out + 1] = id end
            table.sort(out)
            return out
        end,
        position = function(id) local p = MH.players[tonumber(id)] return p and p.position end,
        positions = function()
            local out = {}
            for id, p in pairs(MH.players) do out[id] = p.position end
            return out
        end,
    }
    O.chat = {
        send = function(target, message)
            MH.chat[#MH.chat + 1] = { resource = R.name, target = target, message = message }
            return true
        end,
        addSuggestions = function() return true end,
    }
    O.notifications = { send = function() return "n1" end }
    O.log = {
        info = function(...) log(R.name, "INF", ...) end,
        warn = function(...) log(R.name, "WRN", ...) end,
        error = function(...) log(R.name, "ERR", ...) end,
        debug = function(...) log(R.name, "DBG", ...) end,
    }
    local propSeq = 0
    O.props = {
        create = function() propSeq = propSeq + 1 return R.name .. "#" .. propSeq end,
        attach = function() return true end,
        remove = function() return true end,
    }
    O.animations = {
        get = function() return nil end,
        play = function() return nil, "animations_unavailable" end,
        stop = function() return false, "stale_playback" end,
    }
    -- Open77.tunables.declare: the declared defaults, overridden by MH.tunables[resource] (what an
    -- operator set); MH.setTunable changes one live and raises onTunableChanged in that resource.
    O.tunables = {
        declare = function(declaration)
            R.tunables = declaration
            return setmetatable({}, { __index = function(_, key)
                local set = MH.tunables[R.name]
                if set and set[key] ~= nil then return set[key] end
                local d = declaration[key]
                return d and d.value
            end })
        end,
    }
    O.resource = {
        generation = function(name)
            local T = MH.resources[name or R.name]
            return (T and T.running) and T.generation or 0
        end,
    }
    return O
end

-- ---------------------------------------------------------------------------------------------
-- Resource environments

local function makeEnv(R, options)
    local env = {}
    for k, v in pairs(STD) do env[k] = v end
    env._G = env
    env.print = function(...) log(R.name, nil, ...) end
    env.GetCurrentResourceName = function() return R.name end
    env.GetInvokingResource = function() return MH.invoker[coroutine.running()] end
    env.AddEventHandler = function(name, fn)
        R.handlers[name] = R.handlers[name] or {}
        table.insert(R.handlers[name], fn)
    end
    env.RegisterNetEvent = function(name, fn) if fn then env.AddEventHandler(name, fn) end end
    env.TriggerEvent = function(name, ...)
        local ok, args = pcall(copyPack, table.pack(...))
        if not ok then return false, "event_payload_not_serializable" end
        MH.queue[#MH.queue + 1] = { name = name, args = args, from = R.name }
        return true
    end
    env.TriggerClientEvent = function() return true end
    env.RegisterCommand = function(name, fn, restricted)
        MH.commands[name] = { resource = R.name, fn = fn, restricted = restricted == true }
    end
    env.CreateThread = function(fn) spawn(R, fn, nil, true) end
    env.Wait = function(ms) waitFor((ms or 0) / 1000) end
    env.SetTimeout = function(ms, fn)
        spawn(R, function() waitFor((ms or 0) / 1000) fn() end, nil, true)
        return #R.threads
    end
    env.ClearTimeout = function() end
    env.GetConvar = function(name, default)
        local v = MH.convars[name]
        if v == nil then return default end
        return tostring(v)
    end
    env.GetConvarInt = function(name, default) return tonumber(MH.convars[name]) or default end
    env.GetResourceMetadata = function(name, key)
        local T = MH.resources[name]
        return T and T.metadata and T.metadata[key] or nil
    end
    env.exports = makeExports(R)
    env.Open77 = makeOpen77(R)
    env.MySQL = env.Open77.database
    if options.host then env.HOST = MH end
    return env
end

local function deliver(name, args)
    local names = {}
    for n, T in pairs(MH.resources) do if T.running then names[#names + 1] = n end end
    table.sort(names)
    for _, n in ipairs(names) do
        local T = MH.resources[n]
        for _, fn in ipairs(T.handlers[name] or {}) do
            spawn(T, fn, nil, true, table.unpack(args, 1, args.n))
        end
    end
end

-- Host events (onResourceStart, onPlayerReady, ...): every running resource, each handler as
-- its own task, at once.
function MH.emit(name, ...) deliver(name, table.pack(...)) end

-- Starts `name` from its scripts (paths, or { source = "...", name = "..." } for a test shim),
-- in order, in one environment. options.host exposes
-- the host table as HOST (fixtures only); options.globals are set before the scripts run.
function MH.start(name, scripts, options)
    options = options or {}
    local old = MH.resources[name]
    if old and old.running then error("multihost: " .. name .. " is already running", 2) end
    MH.generation = MH.generation + 1
    local R = { name = name, handlers = {}, exports = {}, threads = {}, db = {},
        generation = MH.generation, running = true, metadata = options.metadata }
    R.env = makeEnv(R, options)
    for k, v in pairs(options.globals or {}) do R.env[k] = v end
    MH.resources[name] = R
    for _, path in ipairs(scripts) do
        local source
        if type(path) == "table" then
            source, path = path.source, path.name or ("=" .. name)
        else
            local file = assert(io.open(path, "rb"), "multihost: cannot open " .. path)
            source = file:read("a")
            file:close()
        end
        local chunk, err = load(source, "@" .. path, "t", R.env)
        if not chunk then error(err, 0) end
        local ok, runErr = pcall(chunk)
        if not ok then error(("%s: %s"):format(name, tostring(runErr)), 0) end
    end
    MH.emit("onResourceStart", name)
    return R
end

function MH.stop(name)
    local R = MH.resources[name]
    if not R or not R.running then return end
    MH.emit("onResourceStop", name)
    R.running = false
    R.db = {}
    for _, th in ipairs(R.threads) do th.dead = true end
    for _, p in ipairs(MH.pending) do
        if p.state == "pending" then
            if p.target == name then settle(p, "rejected", "export_resource_stopped") end
            if p.caller == name then settle(p, "cancelled", "promise_cancelled") end
        end
    end
end

-- An operator changes a tunable of a running resource (live): onTunableChanged(key) in it.
function MH.setTunable(name, key, value)
    MH.tunables[name] = MH.tunables[name] or {}
    MH.tunables[name][key] = value
    local R = MH.resources[name]
    if R and R.running then
        for _, fn in ipairs(R.handlers.onTunableChanged or {}) do spawn(R, fn, nil, true, key, value) end
    end
end

function MH.restart(name, scripts, options)
    MH.stop(name)
    return MH.start(name, scripts, options)
end

function MH.connect(id, identity)
    MH.players[id] = { identifier = identity.identifier, name = identity.name or ("player" .. id),
        ready = true, position = identity.position }
    MH.emit("onPlayerReady", id)
end

function MH.disconnect(id)
    MH.emit("onPlayerDisconnected", id)
    MH.players[id] = nil
end

function MH.command(name, source, args)
    local c = assert(MH.commands[name], "multihost: unknown command " .. tostring(name))
    local R = MH.resources[c.resource]
    spawn(R, c.fn, nil, true, source, args or {}, "")
end

-- Runs fn(...) as a managed task of resource `name` (a test driving a shim), at once.
function MH.task(name, fn, ...)
    local R = assert(MH.resources[name], "multihost: unknown resource " .. tostring(name))
    return spawn(R, fn, nil, true, ...)
end

function MH.step()
    MH.now = MH.now + MH.tick
    local events = MH.queue
    MH.queue = {}
    for _, e in ipairs(events) do deliver(e.name, e.args) end
    local names = {}
    for n, T in pairs(MH.resources) do if T.running then names[#names + 1] = n end end
    table.sort(names)
    for _, n in ipairs(names) do
        local R = MH.resources[n]
        local completions = R.db
        R.db = {}
        for _, fn in ipairs(completions) do spawn(R, fn, nil, true) end
        local list = {}
        for i, th in ipairs(R.threads) do list[i] = th end
        for _, th in ipairs(list) do
            if R.running and not th.dead and th.wake <= MH.now then MH.resume(th) end
        end
        local alive = {}
        for _, th in ipairs(R.threads) do
            if not th.dead and coroutine.status(th.co) == "suspended" then alive[#alive + 1] = th end
        end
        R.threads = alive
    end
    local still = {}
    for _, p in ipairs(MH.pending) do
        if p.state == "pending" then
            if MH.now >= p.deadline then settle(p, "rejected", "export_timeout") else still[#still + 1] = p end
        end
    end
    MH.pending = still
end

function MH.run(seconds)
    local stop = MH.now + seconds
    while MH.now < stop - 1e-9 do MH.step() end
end

-- Runs until `predicate()` is true or `seconds` elapse; returns whether it became true.
function MH.until_(predicate, seconds)
    local stop = MH.now + (seconds or 30)
    while MH.now < stop - 1e-9 do
        if predicate() then return true end
        MH.step()
    end
    return predicate() and true or false
end

-- Calls an export of `target` from resource `from` (a shim), as a task, and runs the clock
-- until the promise settles. Returns the export's values, or nil, reason.
function MH.callAsync(from, target, name, ...)
    local box = {}
    local args = table.pack(...)
    MH.task(from, function()
        local env = MH.resources[from].env
        local p, why = env.Open77.exports.call(target, name, table.unpack(args, 1, args.n))
        if not p then box.res = table.pack(nil, why) return end
        box.res = table.pack(p:await())
    end)
    MH.until_(function() return box.res ~= nil end, 60)
    if not box.res then return nil, "multihost_timeout" end
    return table.unpack(box.res, 1, box.res.n)
end

-- Synchronous export call from resource `from`; returns ok, values... like pcall.
function MH.callSync(from, target, name, ...)
    return pcall(syncCall, from, target, name, table.pack(...))
end

MH.reset()
