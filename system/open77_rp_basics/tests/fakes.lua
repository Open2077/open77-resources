-- =============================================================================
-- open77_rp_basics -- tests/fakes.lua
-- =============================================================================
-- A standing-in platform, so `server/main.lua` can be run and driven without a
-- server. Everything the resource touches is recorded rather than performed,
-- which is what lets the suite assert the thing that actually matters: that the
-- kit RELEASES exactly the claims it TOOK, on every one of the paths a hold can
-- end on.
--
-- Load order is fixed: shared/rules.lua, this file, server/main.lua, then
-- tests/server_test.lua.
-- =============================================================================

local F = {
    now = 1000000,           -- monotonic milliseconds, moved by the test
    players = {},            -- [id] = an Open77.players.get-shaped read
    acl = {},                -- ["<id>|<permission>"] = true
    frozen = {},             -- [id] = how many times THIS resource froze him
    animations = {},         -- [id] = playbackId or nil
    clientEvents = {},       -- { name, target, payload }
    hostEvents = {},         -- { name, ... }
    teleports = {},          -- { player, point }
    logs = {},
    exports = {},            -- [name] = fn
    handlers = {},           -- [event] = { fn, ... }
    netHandlers = {},        -- [event] = fn
    commands = {},           -- [name] = fn
    threads = {},
    teleportResult = { true, nil },
    weapons = { slots = {}, active = 1, drawn = false, source = "report" },
    nextPlayback = 1,
}

RpBasicsFakes = F

-- --- scheduler -------------------------------------------------------------
-- `Wait` yields, `CreateThread` runs until the first yield, `F.tick()` resumes
-- everything once. One tick is one pass of the sweep.
function CreateThread(fn)
    local co = coroutine.create(fn)
    F.threads[#F.threads + 1] = co
    local ok, err = coroutine.resume(co)
    if not ok then F.logs[#F.logs + 1] = "thread error: " .. tostring(err) end
end

function Wait(_ms)
    coroutine.yield()
end

function F.tick(times)
    for _ = 1, (times or 1) do
        local live = {}
        for _, co in ipairs(F.threads) do
            if coroutine.status(co) == "suspended" then
                local ok, err = coroutine.resume(co)
                if not ok then F.logs[#F.logs + 1] = "thread error: " .. tostring(err) end
            end
            if coroutine.status(co) ~= "dead" then live[#live + 1] = co end
        end
        F.threads = live
    end
end

-- --- host globals ----------------------------------------------------------
function GetCurrentResourceName() return "open77_rp_basics" end

function exports(name, fn) F.exports[name] = fn end

function AddEventHandler(name, fn)
    F.handlers[name] = F.handlers[name] or {}
    table.insert(F.handlers[name], fn)
end

function RegisterNetEvent(name, fn) F.netHandlers[name] = fn end

function RegisterCommand(name, fn, _restricted) F.commands[name] = fn end

function TriggerEvent(name, ...)
    F.hostEvents[#F.hostEvents + 1] = { name = name, args = { ... } }
    for _, fn in ipairs(F.handlers[name] or {}) do fn(...) end
    return true
end

function TriggerClientEvent(name, target, payload)
    F.clientEvents[#F.clientEvents + 1] = { name = name, target = target, payload = payload }
    return true
end

-- --- the Open77 surface ----------------------------------------------------
local function promise(value, reason)
    return {
        await = function() return value, reason end,
    }
end

Open77 = {
    time = { monotonic = function() return F.now / 1000 end },
    log = {
        info = function(m) F.logs[#F.logs + 1] = "info: " .. tostring(m) end,
        warn = function(m) F.logs[#F.logs + 1] = "warn: " .. tostring(m) end,
        error = function(m) F.logs[#F.logs + 1] = "error: " .. tostring(m) end,
        debug = function() end,
    },
    acl = {
        isAllowed = function(id, permission) return F.acl[tostring(id) .. "|" .. permission] == true end,
    },
    players = {
        get = function(id) return F.players[id] end,
        setFrozen = function(id, frozen)
            F.frozen[id] = (F.frozen[id] or 0) + (frozen and 1 or -1)
            return true
        end,
        teleport = function(id, point)
            F.teleports[#F.teleports + 1] = { player = id, point = point }
            return promise(F.teleportResult[1], F.teleportResult[2])
        end,
    },
    animations = {
        play = function(id)
            local playback = "pb" .. F.nextPlayback
            F.nextPlayback = F.nextPlayback + 1
            F.animations[id] = playback
            return { playbackId = playback }
        end,
        stop = function(id, playbackId)
            if F.animations[id] ~= nil and (playbackId == nil or F.animations[id] == playbackId) then
                F.animations[id] = nil
            end
            return true
        end,
    },
    weapons = {
        get = function() return F.weapons end,
    },
}

-- --- helpers the test drives the fakes with --------------------------------
function F.player(id, x, y, z, overrides)
    local read = {
        playerId = id, bucket = 0, ready = true, fresh = true, ageMs = 50,
        alive = true, position = { x = x or 0, y = y or 0, z = z or 0 },
    }
    for key, value in pairs(overrides or {}) do read[key] = value end
    F.players[id] = read
    return read
end

function F.grant(id, ...)
    for _, permission in ipairs({ ... }) do F.acl[tostring(id) .. "|" .. permission] = true end
end

function F.fire(event, ...)
    for _, fn in ipairs(F.handlers[event] or {}) do fn(...) end
end

function F.lastClientEvent(target)
    for index = #F.clientEvents, 1, -1 do
        local entry = F.clientEvents[index]
        if target == nil or entry.target == target then return entry end
    end
    return nil
end

function F.hostEventsNamed(name)
    local out = {}
    for _, entry in ipairs(F.hostEvents) do
        if entry.name == name then out[#out + 1] = entry end
    end
    return out
end

function F.reset()
    F.clientEvents, F.hostEvents, F.teleports, F.logs = {}, {}, {}, {}
end

-- No claim may outlive a release. This is the assertion the whole suite exists
-- to make, so it lives here beside the counters it reads.
function F.nothingHeld(id)
    return (F.frozen[id] or 0) == 0 and F.animations[id] == nil
end
