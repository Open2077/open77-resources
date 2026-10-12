-- =============================================================================
-- open77_actions -- tests/fakes.lua
-- =============================================================================
-- A standing-in server platform so the REAL server half (model, claims,
-- engine, carry, main) runs offline. Everything the resource touches is
-- recorded; time and the scheduler are driven by the test.
--
-- Load order: tests/fakes.lua, shared/model.lua, server/claims.lua,
-- server/engine.lua, server/carry.lua, server/main.lua, then a suite.
-- =============================================================================

local F = {
    now = 1000000,                -- monotonic ms
    threads = {},                 -- { co, wakeAt }
    players = {},                 -- [pid] = Open77.players.get read
    vehicles = {},                -- [id] = Open77.vehicles.get read
    anim = {},                    -- [pid] = { playbackId, profile, kind, placed }
    animLog = {},                 -- every play/stop call
    animRefuse = nil,             -- next play refuses with this reason
    nextPlayback = 1,
    profiles = {
        carry_pickup = { id = "carry_pickup", clip = "pick", clipDurationsMs = { pick = 1333 } },
        carry_putdown = { id = "carry_putdown", clip = "put", clipDurationsMs = { put = 2333 } },
        carry = { id = "carry", clip = "hold", clipDurationsMs = { hold = 10000 } },
    },
    props = {},                   -- [id] = { model, position, bucket, yaw, attachment }
    nextProp = 1,
    attachRefuse = nil,           -- { reason = ..., count = n } refuse the next n attaches
    client = {},                  -- { name, target, payload }
    host = {},                    -- { name, payload }
    handlers = {},                -- [event] = { fn }
    netHandlers = {},             -- [event] = fn
    commands = {},
    exports = {},                 -- this resource's exports
    exportHandlers = {},          -- [resource] = { [name] = fn } other resources' exports
    deferred = {},                -- ["res:name"] = true -> async calls stay pending
    pending = {},                 -- { key, args, resolved, values }
    generations = { open77_actions = 7 },
    convars = {},
    invoker = nil, invokerGen = nil,
    logs = {}, prints = {},
    threadErrors = {},            -- never cleared: a suite fails if a thread raised
}
Open77ActionsFakes = F

-- --- scheduler ---------------------------------------------------------------
local function resume(entry)
    local ok, err = coroutine.resume(entry.co)
    if not ok then
        F.logs[#F.logs + 1] = "thread error: " .. tostring(err)
        F.threadErrors[#F.threadErrors + 1] = tostring(err)
    end
end

function CreateThread(fn)
    local entry = { co = coroutine.create(fn), wakeAt = F.now }
    F.threads[#F.threads + 1] = entry
    F.current = entry
    resume(entry)
end

function Wait(ms)
    local co = coroutine.running()
    for _, entry in ipairs(F.threads) do
        if entry.co == co then entry.wakeAt = F.now + (tonumber(ms) or 0) end
    end
    coroutine.yield()
end

function F.run()
    for _ = 1, 50 do
        local progressed = false
        local list = {}
        for _, entry in ipairs(F.threads) do list[#list + 1] = entry end
        for _, entry in ipairs(list) do
            if coroutine.status(entry.co) == "suspended" and entry.wakeAt <= F.now then
                local before = entry.wakeAt
                resume(entry)
                if coroutine.status(entry.co) == "dead" or entry.wakeAt ~= before then progressed = true end
            end
        end
        local live = {}
        for _, entry in ipairs(F.threads) do
            if coroutine.status(entry.co) ~= "dead" then live[#live + 1] = entry end
        end
        F.threads = live
        if not progressed then break end
    end
end

-- Advance the clock in 100 ms steps (the sweep period), running threads.
function F.advance(ms)
    local target = F.now + ms
    while F.now < target do
        F.now = math.min(target, F.now + 100)
        F.run()
    end
end

-- --- host globals ------------------------------------------------------------
function GetCurrentResourceName() return "open77_actions" end
function GetCurrentResourceGeneration() return 7 end
function GetInvokingResource() return F.invoker end
function GetInvokingResourceGeneration() return F.invokerGen end
function GetConvar(name, default) return F.convars[name] or default end

function GetPlayers()
    local out = {}
    for id in pairs(F.players) do out[#out + 1] = id end
    table.sort(out)
    return out
end

function GetPlayersInBucket(bucket)
    local out = {}
    for id, read in pairs(F.players) do if read.bucket == bucket then out[#out + 1] = id end end
    table.sort(out)
    return out
end

function exports(name, fn) F.exports[name] = fn end

function AddEventHandler(name, fn)
    F.handlers[name] = F.handlers[name] or {}
    table.insert(F.handlers[name], fn)
end

function RegisterNetEvent(name, fn) F.netHandlers[name] = fn end
function RegisterCommand(name, fn) F.commands[name] = fn end

function TriggerEvent(name, ...)
    F.host[#F.host + 1] = { name = name, args = { ... } }
    for _, fn in ipairs(F.handlers[name] or {}) do fn(...) end
    return true
end

function TriggerClientEvent(name, target, payload)
    F.client[#F.client + 1] = { name = name, target = target, payload = payload }
    return true
end

function print(...)
    local parts = {}
    for i = 1, select("#", ...) do parts[#parts + 1] = tostring((select(i, ...))) end
    F.prints[#F.prints + 1] = table.concat(parts, "\t")
end

json = { decode = function() error("tests pass decoded tables") end, encode = function() return "{}" end }

-- --- promises and cross-resource exports ----------------------------------
local function promise(entry)
    return {
        await = function()
            while not entry.resolved do coroutine.yield() end
            return table.unpack(entry.values, 1, entry.values.n)
        end,
    }
end

local function handler(resource, name)
    local set = F.exportHandlers[resource]
    return set and set[name] or nil
end

Open77 = {
    time = { monotonic = function() return F.now / 1000 end },
    log = {
        info = function(m) F.logs[#F.logs + 1] = "info: " .. tostring(m) end,
        warn = function(m) F.logs[#F.logs + 1] = "warn: " .. tostring(m) end,
        error = function(m) F.logs[#F.logs + 1] = "error: " .. tostring(m) end,
    },
    resource = {
        generation = function(name)
            if name == nil then return 7 end
            return F.generations[name] or 0
        end,
    },
    exports = {
        callSync = function(resource, name, ...)
            local fn = handler(resource, name)
            if fn == nil then error("export_not_found") end
            local saved, savedGen = F.invoker, F.invokerGen
            F.invoker, F.invokerGen = "open77_actions", 7
            local values = table.pack(fn(...))
            F.invoker, F.invokerGen = saved, savedGen
            return table.unpack(values, 1, values.n)
        end,
        call = function(resource, name, ...)
            local fn = handler(resource, name)
            if fn == nil then return nil, "export_not_found" end
            local entry = { key = resource .. ":" .. name, args = table.pack(...), resolved = false }
            F.pending[#F.pending + 1] = entry
            if not F.deferred[entry.key] then
                entry.values = table.pack(fn(...))
                entry.resolved = true
            end
            return promise(entry)
        end,
    },
    players = {
        get = function(pid) return F.players[pid] end,
    },
    animations = {
        get = function(id) return F.profiles[id] end,
    },
    vehicles = {
        get = function(id) return F.vehicles[id] end,
    },
    props = {},
}

-- --- animations ----------------------------------------------------------------
local function startAnimation(pid, profile, kind, placed)
    F.animLog[#F.animLog + 1] = { op = "play", pid = pid, profile = profile, kind = kind }
    if F.animRefuse then
        local reason = F.animRefuse
        F.animRefuse = nil
        return nil, reason
    end
    local pb = "pb" .. F.nextPlayback
    F.nextPlayback = F.nextPlayback + 1
    F.anim[pid] = { playbackId = pb, profile = profile, kind = kind, placed = placed }
    return { playbackId = pb, playerId = pid, active = true }
end

Open77.animations.play = function(pid, profile, options)
    return startAnimation(pid, profile, "play", false)
end
Open77.animations.playAt = function(pid, profile, position, yaw, options)
    local state = startAnimation(pid, profile, "playAt", true)
    if state then
        state.anchor = { x = position.x, y = position.y, z = position.z, yaw = yaw }
        if F.anim[pid] then F.anim[pid].arrivalRadius = type(options) == "table" and options.arrivalRadius or nil end
    end
    return state
end
Open77.animations.sequence = function(pid, steps, options)
    return startAnimation(pid, steps[1].profile .. ">" .. steps[#steps].profile, "sequence", false)
end
Open77.animations.stop = function(pid, pb)
    F.animLog[#F.animLog + 1] = { op = "stop", pid = pid, playbackId = pb }
    local current = F.anim[pid]
    if current == nil then return true end
    if pb ~= nil and current.playbackId ~= pb then return nil, "stale_playback" end
    F.anim[pid] = nil
    return true
end
Open77.animations.stopAt = function(pb)
    F.animLog[#F.animLog + 1] = { op = "stopAt", playbackId = pb }
    for pid, current in pairs(F.anim) do
        if current.playbackId == pb then F.anim[pid] = nil end
    end
    return true
end

-- --- props -----------------------------------------------------------------
Open77.props.create = function(def)
    local id = tostring(F.nextProp)
    F.nextProp = F.nextProp + 1
    F.props[id] = { model = def.model, position = def.position, bucket = def.bucket, yaw = def.yaw }
    return id
end
Open77.props.attach = function(id, binding)
    if F.props[id] == nil then return nil, "invalid_prop_id" end
    if F.attachRefuse and F.attachRefuse.count > 0 then
        F.attachRefuse.count = F.attachRefuse.count - 1
        return nil, F.attachRefuse.reason
    end
    F.props[id].attachment = binding
    return true
end
Open77.props.detach = function(id)
    if F.props[id] == nil then return nil, "invalid_prop_id" end
    F.props[id].attachment = nil
    return true
end
Open77.props.setTransform = function(id, def)
    local prop = F.props[id]
    if prop == nil then return false, "not_found" end
    if prop.attachment then return false, "prop_attached" end
    prop.position, prop.yaw = def.position, def.yaw
    return true
end
Open77.props.remove = function(id)
    if F.props[id] == nil then return false, "not_found" end
    F.props[id] = nil
    return true
end

-- --- helpers the suites drive the fakes with ------------------------------
function F.player(pid, x, y, z, overrides)
    local read = {
        playerId = pid, bucket = 0, ready = true, fresh = true, ageMs = 50, alive = true, dead = false,
        inVehicle = false, heading = 0, position = { x = x or 0, y = y or 0, z = z or 0 },
        flags = { combatValid = true, aiming = false, triggerDown = false },
    }
    for key, value in pairs(overrides or {}) do read[key] = value end
    F.players[pid] = read
    return read
end

function F.fire(event, ...)
    for _, fn in ipairs(F.handlers[event] or {}) do fn(...) end
end

function F.net(event, pid, ...)
    source = pid
    F.netHandlers[event](...)
    source = nil
end

-- Call one of this resource's exports as resource `as`.
function F.call(as, name, ...)
    F.invoker, F.invokerGen = as, F.generations[as] or 1
    local values = table.pack(F.exports[name](...))
    F.invoker, F.invokerGen = nil, nil
    return table.unpack(values, 1, values.n)
end

function F.animEnded(pid, playbackId, reason)
    if F.anim[pid] and F.anim[pid].playbackId == playbackId then F.anim[pid] = nil end
    F.fire("onPlayerAnimationChanged", tostring(pid), { playbackId = playbackId, active = false, reason = reason })
end

function F.clientEvents(name, target)
    local out = {}
    for _, entry in ipairs(F.client) do
        if entry.name == name and (target == nil or entry.target == target) then out[#out + 1] = entry end
    end
    return out
end

function F.lastClient(name, target)
    local list = F.clientEvents(name, target)
    return list[#list]
end

function F.transitions(opId)
    local out = {}
    for _, entry in ipairs(F.host) do
        if entry.name == "open77_actions:transition" and (opId == nil or entry.args[1].opId == opId) then
            out[#out + 1] = entry.args[1].state .. ":" .. tostring(entry.args[1].reason)
        end
    end
    return out
end

function F.carryEvents(itemId)
    local out = {}
    for _, entry in ipairs(F.host) do
        if entry.name == "open77_actions:carry" and (itemId == nil or entry.args[1].itemId == itemId) then
            out[#out + 1] = entry.args[1].phase
        end
    end
    return out
end

function F.resolvePending(key, ...)
    for _, entry in ipairs(F.pending) do
        if entry.key == key and not entry.resolved then
            entry.values = table.pack(...)
            entry.resolved = true
            return true
        end
    end
    return false
end

-- A raise inside a scheduled thread (a commit, a reservation, the sweep) is
-- swallowed by the scheduler in production too, so the suites assert there
-- was none.
function F.noThreadErrors()
    local swept = {}
    for _, line in ipairs(F.threadErrors) do swept[#swept + 1] = line end
    for _, line in ipairs(F.logs) do
        if line:find("sweep raised", 1, true) then swept[#swept + 1] = line end
    end
    return #swept == 0, table.concat(swept, " | ")
end

function F.reset()
    F.client, F.host, F.logs, F.prints, F.animLog, F.pending = {}, {}, {}, {}, {}, {}
end
