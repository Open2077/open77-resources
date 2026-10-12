-- tests/compat/fakehost.lua: a stand-in Open77 server host for offline compatibility tests.
--
-- It runs a resource's real server/main.lua with no game, no server and no database. Only the
-- natives the audited resources touch exist; a missing one raises, which is the signal that the
-- fake needs extending, never that the resource is wrong. Everything is recorded in `H`.
--
-- The persistent stores (`H.stores.sql`, `H.stores.kvp`) survive between `H.boot` calls, so a
-- test can model a server restart: same tables and KVP file, fresh resource generation.
-- The SQL side is not a database: each scenario installs `H.sql(sql, params)` that interprets
-- exactly the statements of the resource under test.

H = {
    stores = { sql = {}, kvp = {} },
    now = 1000.0,
    -- Other resources' server exports, installed by a scenario: H.remote[resource][name] = fn.
    -- `exports.res:name(...)`, Open77.exports.call and callSync reach them; a missing resource or
    -- export raises (sugar, callSync) or rejects (call), as on the platform. Kept across H.boot.
    remote = {},
}

local realPrint = print
H.realPrint = realPrint

local function reset(resource, dbMode)
    H.resource = resource
    H.dbMode = dbMode or "sql"    -- "sql" | "none" (no database) | "silent" (configured, never answers)
    H.handlers, H.exports, H.commands, H.threads, H.logs = {}, {}, {}, {}, {}
    H.wake = setmetatable({}, { __mode = "k" })
    H.players = {}
    H.events = {}
end

function GetCurrentResourceName() return H.resource end
function GetInvokingResource() return "compat_test" end
function print(...)
    local parts = {}
    for i = 1, select("#", ...) do parts[#parts + 1] = tostring(select(i, ...)) end
    H.logs[#H.logs + 1] = table.concat(parts, " ")
end

function AddEventHandler(name, fn)
    H.handlers[name] = H.handlers[name] or {}
    table.insert(H.handlers[name], fn)
end
function RegisterNetEvent(name, fn) if fn then AddEventHandler(name, fn) end end
function RegisterCommand(name, fn) H.commands[name] = fn end
function TriggerEvent(name, ...)
    H.events[#H.events + 1] = { name = name, args = table.pack(...) }
    for _, fn in ipairs(H.handlers[name] or {}) do fn(...) end
    return true
end
function TriggerClientEvent() return true end
-- Host events (onResourceStart, onPlayerReady, ...) run each handler as its own managed task,
-- as the platform does, so a handler may Wait.
function H.emit(name, ...)
    local args = table.pack(...)
    for _, fn in ipairs(H.handlers[name] or {}) do
        CreateThread(function() fn(table.unpack(args, 1, args.n)) end)
    end
end
-- `exports(name, fn)` publishes an export of the resource under test; `exports.other:name(...)`
-- is the synchronous proxy to H.remote (raises when the resource or the export is missing).
local function remoteExport(resource, name)
    local provider = H.remote[resource]
    local fn = provider and provider[name]
    if not fn then error(("fakehost: no export %s:%s"):format(tostring(resource), tostring(name)), 3) end
    return fn
end
exports = setmetatable({}, {
    __call = function(_, name, fn) H.exports[name] = fn return true end,
    __index = function(_, resource)
        return setmetatable({}, {
            __index = function(_, name)
                return function(_, ...) return remoteExport(resource, name)(...) end
            end,
        })
    end,
})

-- Cooperative scheduler on a simulated clock: Wait parks the running thread until H.now
-- reaches its wake time; H.run(seconds) advances the clock and resumes what is due.
function CreateThread(fn)
    local co = coroutine.create(fn)
    H.threads[#H.threads + 1] = co
    local ok, err = coroutine.resume(co)
    if not ok then error(err, 0) end
end
function Wait(ms)
    local co = coroutine.running()
    H.wake[co] = H.now + (ms or 0) / 1000
    coroutine.yield()
end
function SetTimeout(ms, fn) CreateThread(function() Wait(ms) fn() end) return #H.threads end
function ClearTimeout() end
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
    end
end

json = {
    encode = function() error("fakehost: json.encode is not faked", 2) end,
    decode = function() error("fakehost: json.decode is not faked", 2) end,
}

-- Open77.database: the callback form calls back synchronously; `.await` returns the value.
local function statement(sql, params)
    if not H.sql then error("fakehost: no SQL interpreter installed for " .. tostring(H.resource), 2) end
    return H.sql(sql, params or {})
end
local function dbMethod()
    return setmetatable({
        await = function(sql, params) return statement(sql, params) end,
    }, {
        __call = function(_, sql, params, cb)
            local result = statement(sql, params)
            if cb then cb(result, nil) end
            return true
        end,
    })
end

Open77 = {
    database = {
        query = dbMethod(), single = dbMethod(), scalar = dbMethod(),
        insert = dbMethod(), update = dbMethod(),
        ready = function(fn)
            if H.dbMode == "none" then return false, "database_unavailable" end
            if H.dbMode == "silent" then return true end
            CreateThread(fn)
            return true
        end,
        isReady = function()
            if H.dbMode == "sql" then return true end
            if H.dbMode == "silent" then return false, "database_connecting" end
            return false, "database_unavailable"
        end,
    },
    kvp = {
        get = function(key, default)
            local v = H.stores.kvp[key]
            if v == nil then return default end
            return v
        end,
        set = function(key, value) H.stores.kvp[key] = value return true end,
        delete = function(key)
            local had = H.stores.kvp[key] ~= nil
            H.stores.kvp[key] = nil
            return had
        end,
        keys = function(prefix)
            local out = {}
            for k in pairs(H.stores.kvp) do
                if k:sub(1, #(prefix or "")) == (prefix or "") then out[#out + 1] = k end
            end
            table.sort(out)
            return out
        end,
    },
    time = {
        unix = function() return H.now end,
        monotonic = function() return H.now end,
    },
    players = {
        identifier = function(id) return H.players[id] and H.players[id].identifier end,
        name = function(id) return H.players[id] and H.players[id].name end,
        get = function(id) return H.players[id] and { ready = true } or nil end,
        all = function()
            local out = {}
            for id in pairs(H.players) do out[#out + 1] = id end
            table.sort(out)
            return out
        end,
    },
    chat = {
        send = function() return true end,
        addSuggestions = function() return true end,
    },
    -- Promise form: await() runs the stub (it may Wait, like a remote VM's latency) and returns
    -- its values, or nil plus a rejection reason when the export does not exist.
    exports = {
        call = function(resource, name, ...)
            local args = table.pack(...)
            return {
                await = function()
                    local provider = H.remote[resource]
                    if not provider then return nil, "export_resource_not_found" end
                    local fn = provider[name]
                    if not fn then return nil, "export_not_found" end
                    return fn(table.unpack(args, 1, args.n))
                end,
                status = function() return "resolved" end,
            }
        end,
        callSync = function(resource, name, ...) return remoteExport(resource, name)(...) end,
    },
}

-- Starts one generation of `resource` from its server script, with these players connected
-- and the database in `dbMode`, and lets `settle` simulated seconds pass (store decisions).
function H.boot(resource, script, dbMode, players, settle)
    reset(resource, dbMode)
    for id, p in pairs(players or {}) do H.players[id] = p end
    -- `script` is one path or a list of paths loaded in order (shared config, modules, main).
    for _, path in ipairs(type(script) == "table" and script or { script }) do
        local chunk, err = loadfile(path, "t")
        if not chunk then error(err, 0) end
        chunk()
    end
    H.emit("onResourceStart", resource)
    for id in pairs(H.players) do H.emit("onPlayerReady", id) end
    H.run(settle or 60)
    return H.exports
end
