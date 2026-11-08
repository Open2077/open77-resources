-- =============================================================================
-- open77_scenes -- tests/fakes.lua
-- =============================================================================
-- A standing-in server platform so the REAL server half (shared/scenes.lua,
-- server/core.lua, server/main.lua) runs offline. The RP animation service is
-- faked at its Lua surface: sequenceAt validates the shape the platform
-- refuses (hold without a duration on the last step, standAt within 3 m of the
-- anchor) and records every call. Load order: tests/fakes.lua, shared/scenes.lua,
-- server/core.lua, server/main.lua, tests/scenes_test.lua.
-- =============================================================================

local F = {
    now = 1000000, players = {}, current = {}, calls = {}, sent = {}, events = {}, stops = {},
    nextPlayback = 1, refuseNext = nil, handlers = {}, netHandlers = {}, commands = {}, exports = {}, threads = {},
}
Open77ScenesFakes = F

-- A test furniture kind: the anchor 0.5 m along the chair's +Y, turned 180 degrees.
-- shared/scenes.lua keeps a pre-existing furniture table and adds its own kinds.
Open77Scenes = { furniture = { test_chair = { scene = "ripperdoc", label = "test chair",
    offset = { x = 0, y = 0.5, z = 0, yaw = 0 }, yaw = 180 } } }

-- Spots of the test kind, one far away, and one of a kind no scene claims.
Open77SceneSpots = {
    version = "spots-test",
    spots = {
        { id = "chair@0_0_0", kind = "test_chair", x = 0, y = 0, z = 0, yaw = 0 },
        { id = "chair@4_0_0", kind = "test_chair", x = 4, y = 0, z = 0, yaw = 90 },
        { id = "chair@100_0_0", kind = "test_chair", x = 100, y = 0, z = 0, yaw = 0 },
        { id = "unknown@1_1_1", kind = "nobody_claims_this", x = 1, y = 1, z = 1, yaw = 0 },
    },
}

function F.player(pid, x, y, z, extra)
    local read = { position = { x = x, y = y, z = z }, bucket = 0, alive = true, inVehicle = false }
    for k, v in pairs(extra or {}) do read[k] = v end
    F.players[pid] = read
end

local function copy(v)
    if type(v) ~= "table" then return v end
    local out = {}
    for k, x in pairs(v) do out[k] = copy(x) end
    return out
end

json = { decode = function(text) error("json.decode is not used by these tests: " .. tostring(text)) end }
source = nil

GetCurrentResourceName = function() return "open77_scenes" end
GetCurrentResourceGeneration = function() return 3 end
GetInvokingResource = function() return F.invoker or "open77_scenes" end
GetConvar = function(_, default) return default end
GetPlayers = function()
    local list = {}
    for pid in pairs(F.players) do list[#list + 1] = tostring(pid) end
    table.sort(list)
    return list
end
Wait = function() end
CreateThread = function(fn) F.threads[#F.threads + 1] = fn end
RegisterNetEvent = function(name, fn) F.netHandlers[name] = fn end
AddEventHandler = function(name, fn) F.handlers[name] = F.handlers[name] or {}; table.insert(F.handlers[name], fn) end
RegisterCommand = function(name, fn, restricted) F.commands[name] = { fn = fn, restricted = restricted } end
TriggerClientEvent = function(name, pid, payload) F.sent[#F.sent + 1] = { name = name, pid = pid, payload = copy(payload) } end
TriggerEvent = function(name, payload) F.events[#F.events + 1] = { name = name, payload = copy(payload) } end
exports = function(name, fn) F.exports[name] = fn end

function F.fire(name, ...)
    for _, fn in ipairs(F.handlers[name] or {}) do fn(...) end
end

function F.net(name, pid, ...)
    source = pid
    F.netHandlers[name](...)
    source = nil
end

function F.lastSent(name, pid)
    for i = #F.sent, 1, -1 do
        local s = F.sent[i]
        if s.name == name and (pid == nil or s.pid == pid) then return s.payload end
    end
end

function F.reset()
    F.calls, F.sent, F.events, F.stops, F.current, F.refuseNext = {}, {}, {}, {}, {}, nil
end

Open77 = {
    resource = { generation = function() return 3 end },
    time = { monotonic = function() return F.now / 1000 end },
    players = {
        get = function(pid) return copy(F.players[pid]) end,
        setHeading = function(pid, yaw)
            F.headings = F.headings or {}
            F.headings[#F.headings + 1] = { pid = pid, yaw = yaw }
            return true
        end,
    },
    animations = {
        sequenceAt = function(pid, steps, position, yaw, options)
            local call = { pid = pid, steps = copy(steps), position = copy(position), yaw = yaw, options = copy(options) }
            F.calls[#F.calls + 1] = call
            if F.refuseNext then
                local why = F.refuseNext
                F.refuseNext = nil
                return nil, why
            end
            for i, step in ipairs(steps) do
                local last = i == #steps
                if options.hold and last then
                    if step.durationMs ~= nil then return nil, "invalid_duration" end
                elseif type(step.durationMs) ~= "number" or step.durationMs < 1000 then
                    return nil, "invalid_duration"
                end
            end
            if options.standAt then
                local s = options.standAt
                local dx, dy, dz = s.x - position.x, s.y - position.y, s.z - position.z
                if dx * dx + dy * dy + dz * dz > 9 then return nil, "stand_too_far" end
            end
            local id = "pb" .. F.nextPlayback
            F.nextPlayback = F.nextPlayback + 1
            local state = { playbackId = id, active = true, step = 0, anchor = { x = position.x, y = position.y, z = position.z, yaw = yaw } }
            F.current[pid] = state
            return copy(state)
        end,
        stopAt = function(id)
            F.stops[#F.stops + 1] = id
            for pid, state in pairs(F.current) do
                if state.playbackId == id then F.current[pid] = nil end
            end
            return true
        end,
        current = function(pid) return copy(F.current[pid]) end,
    },
}
