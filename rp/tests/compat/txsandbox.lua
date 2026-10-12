-- tests/compat/txsandbox.lua: the REAL open77_transactions resource on the single-resource
-- fake host (fakehost.lua).
--
-- fakehost.lua runs ONE resource, the one under test, in the global state. This file gives the
-- coordinator what its own VM would have on a server: its own environment (globals, exports,
-- event handlers, tunables, convars), its own threads on the same simulated clock, and the
-- platform's export dispatch (a call runs as a task of the coordinator, GetInvokingResource is
-- the caller, a yielding export called synchronously fails with export_yielded). It survives
-- H.boot (a restart of the resource under test) and can stop, crash and start again over the
-- same store, like the resource on a server.
--
-- The scripts are the vendored final coordinator (tests/compat/vendor/open77_transactions, or
-- OP77_TX_DIR), in its manifest's order, server/main.lua included; tests/compat/txshim.lua is the
-- only seam (the memory store stands for the database). See vendor/.../SOURCE.txt.
--
-- Globals expected: H (fakehost.lua), TX_DIR (the coordinator folder; TX_ROOT is accepted too),
-- and COMPAT_DIR or HARNESS (this folder). Public table: TXS.
--
--   TXS.start({ keepStore, tunables, convars, dbMode })  (re)start the resource
--   TXS.stop()                                            stop it (threads die, exports vanish)
--   TXS.call(invoker, name, done, ...)                    async export call (done(ok, ...))
--   TXS.callSync(invoker, name, ...)                      sync export call (raises like callSync)
--   TXS.setTunable(key, value)                            operator change (onTunableChanged)
--   TXS.store, TXS.co                                     the memory store, the coordinator object
--   TXS.events                                            { name, args } raised by the coordinator

TXS = TXS or {}
TXS.tunables = TXS.tunables or {}
TXS.convars = TXS.convars or {}
TXS.dbMode = TXS.dbMode or "sql"
TXS.errors = TXS.errors or {}
TXS.events = TXS.events or {}
TXS.generation = TXS.generation or 0
TXS.threads = TXS.threads or {}
TXS.queue = TXS.queue or {}
TXS.handlers = TXS.handlers or {}
TXS.exports = TXS.exports or {}
TXS.commands = TXS.commands or {}
TXS.running = TXS.running or false

local HERE = COMPAT_DIR or HARNESS
local byCo = setmetatable({}, { __mode = "k" })
local syncCo = setmetatable({}, { __mode = "k" })

-- The host's print records into H.logs, which exists only once a resource has booted.
local function say(...)
    if H.logs then print(...) end
end

local function readFile(path)
    local f = assert(io.open(path, "rb"), "txsandbox: cannot open " .. path)
    local text = f:read("a")
    f:close()
    return text
end

-- The manifest's server scripts, in order, and its version.
local function manifest(dir)
    local text = readFile(dir .. "/open77.lua")
    local scripts = {}
    for line in text:gmatch("[^\n]+") do
        if not line:match("^%s*%-%-") then
            local s = line:match('^%s*server_script%s+"([^"]+)"')
            if s then scripts[#scripts + 1] = s end
        end
    end
    return scripts, text:match('version%s+"([^"]+)"')
end

-- ---------------------------------------------------------------------------------------------
-- Threads

local function resume(th)
    if th.dead or coroutine.status(th.co) ~= "suspended" then return end
    local ok, err = coroutine.resume(th.co)
    if not ok then
        th.dead = true
        TXS.errors[#TXS.errors + 1] = tostring(err)
        say("[open77_transactions] uncaught: " .. tostring(err))
    end
end

local function spawn(fn, invoker, ...)
    local args = table.pack(...)
    local th = { wake = 0, invoker = invoker, generation = TXS.generation }
    th.co = coroutine.create(function() return fn(table.unpack(args, 1, args.n)) end)
    byCo[th.co] = th
    TXS.threads[#TXS.threads + 1] = th
    resume(th)
    return th
end
TXS.spawn = spawn

local function deliver(e)
    if e.host and H.threads and H.handlers then
        -- Other resources' handlers (the resource under test), in a task of their own; before
        -- any resource has booted nobody listens.
        CreateThread(function() TriggerEvent(e.name, table.unpack(e.args, 1, e.args.n)) end)
    end
    if TXS.running then
        for _, fn in ipairs(TXS.handlers[e.name] or {}) do
            spawn(fn, nil, table.unpack(e.args, 1, e.args.n))
        end
    end
end

-- One scheduler pass of the coordinator: queued events, then every thread that is due.
-- holdHostEvents: events for other resources stay queued for the next pass of the host clock
-- (a pump between two host steps must not run the resource under test).
function TXS.step(holdHostEvents)
    local q = TXS.queue
    TXS.queue = {}
    for _, e in ipairs(q) do
        if holdHostEvents and e.host then
            TXS.queue[#TXS.queue + 1] = { name = e.name, args = e.args, host = true, local_done = true }
            if not e.local_done and TXS.running then
                for _, fn in ipairs(TXS.handlers[e.name] or {}) do spawn(fn, nil, table.unpack(e.args, 1, e.args.n)) end
            end
        elseif e.local_done then
            if e.host and H.threads and H.handlers then
                CreateThread(function() TriggerEvent(e.name, table.unpack(e.args, 1, e.args.n)) end)
            end
        else
            deliver(e)
        end
    end
    local list = {}
    for i, th in ipairs(TXS.threads) do list[i] = th end
    for _, th in ipairs(list) do
        if not th.dead and th.wake <= H.now then resume(th) end
    end
    local alive = {}
    for _, th in ipairs(TXS.threads) do
        if not th.dead and coroutine.status(th.co) == "suspended" then alive[#alive + 1] = th end
    end
    TXS.threads = alive
end

-- fakehost's clock, plus one coordinator pass per step.
function H.run(seconds)
    local stop = H.now + seconds
    while H.now < stop do
        H.now = H.now + 0.25
        for _, co in ipairs(H.threads) do
            if coroutine.status(co) == "suspended" and (H.wake[co] or 0) <= H.now then
                local ok, err = coroutine.resume(co)
                if not ok then error(err, 0) end
            end
        end
        TXS.step()
    end
end

-- Host events reach the coordinator too (onResourceStop of another resource cancels its
-- reservations; onResourceStop of the coordinator itself is ignored by main.lua).
local fakeEmit = H.emit
function H.emit(name, ...)
    fakeEmit(name, ...)
    if TXS.running then
        for _, fn in ipairs(TXS.handlers[name] or {}) do spawn(fn, nil, ...) end
    end
end

-- ---------------------------------------------------------------------------------------------
-- The coordinator's environment

local function newEnv(version)
    local env = setmetatable({}, { __index = _G })
    env._G = env
    env.print = say
    env.GetCurrentResourceName = function() return "open77_transactions" end
    env.GetInvokingResource = function()
        local co = coroutine.running()
        local th = byCo[co]
        if th then return th.invoker end
        return syncCo[co]
    end
    env.GetResourceMetadata = function(_, key) if key == "version" then return version end return nil end
    env.GetConvar = function(name, default)
        local v = TXS.convars[name]
        if v == nil then return default end
        return tostring(v)
    end
    env.CreateThread = function(fn) spawn(fn, nil) end
    env.Wait = function(ms)
        local co = coroutine.running()
        if syncCo[co] then error("export_yielded", 0) end
        local th = byCo[co]
        if not th then error("txsandbox: Wait outside a coordinator thread", 2) end
        th.wake = H.now + (ms or 0) / 1000
        coroutine.yield()
    end
    env.SetTimeout = function(ms, fn) spawn(function() env.Wait(ms) fn() end, nil) end
    env.AddEventHandler = function(name, fn)
        TXS.handlers[name] = TXS.handlers[name] or {}
        table.insert(TXS.handlers[name], fn)
    end
    env.TriggerEvent = function(name, ...)
        local args = table.pack(...)
        TXS.events[#TXS.events + 1] = { name = name, args = args }
        TXS.queue[#TXS.queue + 1] = { name = name, args = args, host = true }
        return true
    end
    env.RegisterCommand = function(name, fn) TXS.commands[name] = fn end
    env.exports = setmetatable({}, {
        __call = function(_, name, fn) TXS.exports[name] = fn return true end,
        __index = function(_, target) return _G.exports[target] end,
    })
    local declared = {}
    local own = {
        tunables = {
            declare = function(declaration)
                for k, v in pairs(declaration) do declared[k] = v end
                return setmetatable({}, { __index = function(_, k)
                    local v = TXS.tunables[k]
                    if v ~= nil then return v end
                    local d = declared[k]
                    return d and d.value
                end })
            end,
        },
        log = {
            info = function(m) say("[open77_transactions] INF " .. tostring(m)) end,
            warn = function(m) say("[open77_transactions] WRN " .. tostring(m)) end,
            error = function(m) say("[open77_transactions] ERR " .. tostring(m)) end,
            debug = function() end,
        },
        time = {
            unix = function() return H.now end,
            monotonic = function() return H.now end,
        },
    }
    -- Everything else (players, kvp, exports, ...) is the host's, looked up live: scenarios
    -- replace host natives after this file is loaded.
    env.Open77 = setmetatable(own, { __index = function(_, k) return Open77[k] end })
    return env
end

-- ---------------------------------------------------------------------------------------------
-- Lifecycle

function TXS.stop()
    if not TXS.running then return end
    TXS.running = false
    for _, th in ipairs(TXS.threads) do th.dead = true end
    TXS.threads = {}
    TXS.queue = {}
    TXS.handlers, TXS.exports, TXS.commands = {}, {}, {}
end

-- options: keepStore (restart over the same store), tunables / convars (merged), dbMode
-- ("sql": the database answers; "late": configured, answers once TXS.dbMode becomes "sql";
-- "none": no database configured).
function TXS.start(options)
    options = options or {}
    TXS.stop()
    for k, v in pairs(options.tunables or {}) do TXS.tunables[k] = v end
    for k, v in pairs(options.convars or {}) do TXS.convars[k] = v end
    if options.dbMode then TXS.dbMode = options.dbMode end
    TXS.generation = TXS.generation + 1
    TXS.running = true
    TXS.handlers, TXS.exports, TXS.commands = {}, {}, {}
    -- TX_DIR; TX_ROOT is the older name some runners still pass (the B2 suite's, B7's).
    local dir = TX_DIR or TX_ROOT
    local scripts, version = manifest(dir)
    local env = newEnv(version)
    TXS.env = env
    local host = {
        mysqlReady = function(fn)
            if TXS.dbMode == "none" then return false, "database_unavailable" end
            spawn(function()
                while TXS.dbMode ~= "sql" do env.Wait(250) end
                fn()
            end, nil)
            return true
        end,
        onCoordinator = function(co)
            -- Wall-clock time moves between two boots on a server; on the simulated clock two
            -- starts can share a millisecond, so keep the boot component of minted ids unique.
            if TXS.lastBootMs and co.bootMs <= TXS.lastBootMs then co.bootMs = TXS.lastBootMs + 1 end
            TXS.lastBootMs = co.bootMs
            TXS.co = co
        end,
    }
    env.TxTestHost = host
    local function run(path, name)
        local chunk, err = load(readFile(path), "@" .. name, "t", env)
        if not chunk then error(err, 0) end
        chunk()
    end
    for _, rel in ipairs(scripts) do
        if rel == "server/main.lua" then
            if not options.keepStore or not TXS.store then
                TXS.store = env.Open77TxMemoryStore.new({ deferred = false })
            end
            host.store = TXS.store
            run(HERE .. "/txshim.lua", "txshim.lua")
        end
        run(dir .. "/" .. rel, "open77_transactions/" .. rel)
    end
    return TXS.co
end

function TXS.setTunable(key, value)
    TXS.tunables[key] = value
    TXS.queue[#TXS.queue + 1] = { name = "onTunableChanged", args = table.pack(key, value), host = false }
end

-- True once main.lua reports `ready` (its info export).
function TXS.ready()
    if not TXS.running or not TXS.exports.info then return false end
    local ok, info = pcall(TXS.callSync, "compat_test", "info")
    return ok and type(info) == "table" and info.ready == true
end

-- ---------------------------------------------------------------------------------------------
-- Export dispatch

-- Asynchronous: the export runs as a task of the coordinator; done(true, ...) with its values or
-- done(false, error) when it raised. Returns false, reason when it cannot be dispatched.
function TXS.call(invoker, name, done, ...)
    if not TXS.running then return false, "export_resource_unavailable" end
    local fn = TXS.exports[name]
    if not fn then return false, "export_not_found" end
    local args = table.pack(...)
    spawn(function()
        local res = table.pack(pcall(fn, table.unpack(args, 1, args.n)))
        if res[1] then done(true, table.unpack(res, 2, res.n)) else done(false, tostring(res[2])) end
    end, invoker)
    return true
end

-- Synchronous: inline, never yields; raises like Open77.exports.callSync.
function TXS.callSync(invoker, name, ...)
    if not TXS.running then error("export_resource_unavailable", 0) end
    local fn = TXS.exports[name]
    if not fn then error("export_not_found", 0) end
    local co = coroutine.create(fn)
    syncCo[co] = invoker or "compat_test"
    local res = table.pack(coroutine.resume(co, ...))
    if not res[1] then
        if res[2] == "export_yielded" then error("export_yielded", 0) end
        error("export_raised " .. tostring(res[2]), 0)
    end
    if coroutine.status(co) ~= "dead" then error("export_yielded", 0) end
    return table.unpack(res, 2, res.n)
end

-- A provider table for hosts whose remote exports are plain functions awaited inline in the
-- caller's coroutine (fakehost's H.remote behind Open77.exports.call): each call is dispatched as
-- a coordinator task and the caller waits on the fake clock. `invoker()` names the caller.
function TXS.remoteTable(invoker)
    return setmetatable({}, { __index = function(_, name)
        if not TXS.running or not TXS.exports[name] then return nil end
        return function(...)
            local res
            local ok, why = TXS.call(invoker(), name, function(...) res = table.pack(...) end, ...)
            if not ok then return nil, why end
            while not res do Wait(0) end
            if not res[1] then return nil, "export_raised " .. tostring(res[2]) end
            return table.unpack(res, 2, res.n)
        end
    end })
end

-- A provider table of synchronous calls (hosts that only use callSync).
function TXS.syncTable(invoker)
    return setmetatable({}, { __index = function(_, name)
        if not TXS.running or not TXS.exports[name] then return nil end
        return function(...) return TXS.callSync(invoker(), name, ...) end
    end })
end
