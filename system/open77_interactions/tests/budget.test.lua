-- The arbitration tick at RP scale, replayed offline with a count hook.
--
-- The scene is the one measured live on 2026-09-19 (see the "arbitration
-- tick" note in client/main.lua): forty worldui-shaped rings all within their
-- 80 m marker distance, two `globalNpc` targets and one `globalVehicle`,
-- eight vanilla puppets, twelve Open77 NPCs, forty vehicle replicas and four
-- players around, a world query answering 128 parts. Every stub counts how
-- often the resource asks it, and a count hook measures every resume in VM
-- instructions -- a number that does not move with the machine, only with the
-- code and the data.
--
-- Two things are pinned:
--
--   * no resume reaches the host's instruction hook (10 000 VM instructions),
--     so the tick survives whatever the resource count on the client;
--   * the resource asks the world, the rosters and the bodies at bounded
--     rates -- one body read per cycle (the local player), the world at the
--     resolve cadence, the rosters once per pass, no Lua projection while the
--     native card draws, no anchor patch when nothing changed. The Lua cannot
--     know what a native costs; it can only be bounded on how often it asks.
--
-- Run from the repository root:
--   lua resources/system/open77_interactions/tests/budget.test.lua

local HOOK_INTERVAL = 10000
local SIMULATED_SECONDS = 10.0
local FRAME_SECONDS = 0.014

local exportsTable, handlers, netHandlers, threads = {}, {}, {}, {}
function exports(name, fn) exportsTable[name] = fn end
function AddEventHandler(name, fn) handlers[name] = fn end
function RegisterNetEvent(name, fn) netHandlers[name] = fn end
function TriggerServerEvent() end
function TriggerEvent() end
function GetInvokingResource() return "rp_housing" end
function GetInvokingResourceGeneration() return 1 end
function GetResourceState() return "running" end
function GetCurrentResourceName() return "open77_interactions" end
function CreateThread(fn) threads[#threads + 1] = fn end
function Wait(ms) coroutine.yield(ms) end
WebUI = { create = function() return { on = function() end, send = function() return true end } end }

local clock = 0.0
local calls = {}
local function count(name) calls[name] = (calls[name] or 0) + 1 end

-- The world.
local playerPos = { x = 0.0, y = 0.0, z = 0.0 }
local anchors, nextAnchor = {}, 1
local puppets, npcs, vehicles, players, world = {}, {}, {}, {}, {}
local placements = {}
for index = 1, 8 do
    local position = { x = 3 + index * 2.5, y = 0, z = 0 }
    puppets[index] = { engineEntity = 6000 + index, className = "NPCPuppet", position = position,
        distance = 3 + index * 2.5, kind = "populationNpc", family = "puppet" }
end
for index = 1, 12 do
    local entity = 9000 + index
    local position = { x = -20 - index * 3, y = 5, z = 0 }
    if index <= 2 then
        -- Two Open77 NPCs stand inside the puppet radius, like a fence and a
        -- buyer; the query identifies them.
        position = { x = 4 + index, y = 2, z = 0 }
        puppets[#puppets + 1] = { engineEntity = 7000 + index, className = "NPCPuppet", position = position,
            distance = 4 + index, kind = "npc", family = "puppet", npcId = index }
    end
    -- The row carries the replica's position, as the client's does.
    npcs[index] = { id = index, entity = entity, record = "Character.fence_" .. index, streamed = true,
        position = position }
    placements[entity] = { position = position, engineId = 7000 + index }
end
for index = 1, 40 do
    local entity = 8000 + index
    local position = { x = 10 + index * 4, y = -10, z = 0 }
    vehicles[index] = { id = 100 + index, entity = entity, engineEntity = 5000 + index,
        record = "Vehicle.v_standard2_archer_hella_player", streamed = true, locked = false,
        doors = 0, occupants = {}, health = 100.0, position = position }
    placements[entity] = { position = position, engineId = 5000 + index }
end
for index = 1, 4 do
    local entity = 3000 + index
    local position = { x = 2 + index * 6, y = 3, z = 0 }
    players[index] = { playerId = 40 + index, entity = entity, position = position,
        distance = 2 + index * 6, name = "P" .. index }
    placements[entity] = { position = position, engineId = 4000 + index }
    puppets[#puppets + 1] = { engineEntity = 4000 + index, className = "PlayerPuppet", position = position,
        distance = 2 + index * 6, kind = "player", family = "puppet", playerId = 40 + index }
end
for index = 1, 128 do
    world[index] = { engineEntity = 20000 + index, className = index % 2 == 0 and "gameObject" or "Device",
        position = { x = index, y = index, z = 0 }, distance = index * 1.4 }
end

Open77 = {
    time = { monotonic = function() return clock end },
    log = { warn = print, info = print },
    character = {
        state = function(entity)
            if entity == nil or entity == 0 then
                count("character.state:local")
                return { attached = true, position = playerPos, isPlayer = true }
            end
            count("character.state:body")
            local placement = placements[entity]
            if not placement then return nil, "unknown_entity" end
            return { attached = true, position = placement.position, engineId = placement.engineId }
        end,
    },
    world = {
        nearby = function(_, filter)
            count("world.nearby:" .. tostring(filter))
            if filter == "puppet" then return puppets end
            return world
        end,
    },
    vehicles = {
        all = function() count("vehicles.all"); return vehicles end,
        nearby = function(radius)
            count("vehicles.nearby")
            local out = {}
            for _, vehicle in ipairs(vehicles) do
                local p = vehicle.position
                local d = math.sqrt((p.x - playerPos.x) ^ 2 + (p.y - playerPos.y) ^ 2 + (p.z - playerPos.z) ^ 2)
                if d <= radius then
                    out[#out + 1] = { id = vehicle.id, entity = vehicle.entity, engineEntity = vehicle.engineEntity,
                        record = vehicle.record, distance = d, streamed = vehicle.streamed, locked = vehicle.locked,
                        occupants = #vehicle.occupants, position = p }
                end
            end
            return out
        end,
        get = function(id)
            count("vehicles.get")
            for _, vehicle in ipairs(vehicles) do if vehicle.id == id then return vehicle end end
            return nil
        end,
    },
    npcs = { all = function() count("npcs.all"); return npcs end },
    players = { nearby = function() count("players.nearby"); return players end },
    camera = { project = function() count("camera.project"); return { x = 0.5, y = 0.5, onScreen = true } end },
    input = {
        isCaptured = function() count("input.isCaptured"); return false end,
        isDown = function() count("input.isDown"); return false end,
    },
    resource = { generation = function() return 1 end },
    state = { localPlayer = function() return { get = function() return nil end } end },
    exports = {
        callSync = function() count("exports.callSync"); return true end,
    },
    anchors = {
        create = function(options)
            count("anchors.create")
            local id = nextAnchor
            nextAnchor = nextAnchor + 1
            anchors[id] = { id = id, position = options.position, entity = options.entity }
            return id
        end,
        update = function() count("anchors.update"); return true end,
        remove = function(id) count("anchors.remove"); anchors[tonumber(id)] = nil; return true end,
        clear = function() anchors = {} end,
        list = function()
            count("anchors.list")
            local out = {}
            for id, anchor in pairs(anchors) do
                local p = anchor.position
                if not p then
                    local placement = placements[tonumber(anchor.entity)]
                    p = placement and placement.position or { x = 0, y = 0, z = 0 }
                end
                local d = math.sqrt((p.x - playerPos.x) ^ 2 + (p.y - playerPos.y) ^ 2 + (p.z - playerPos.z) ^ 2)
                out[#out + 1] = { id = tostring(id), projected = true, onScreen = true,
                    screen = { x = 0.5 + d * 0.001, y = 0.5 }, distance = d, resolved = p }
            end
            return out
        end,
    },
    zones = { normalize = function(zone) return zone end, contains = function() return false end },
}

dofile("resources/system/open77_interactions/client/main.lua")
handlers.onClientResourceStart("open77_interactions")
local loop = assert(threads[1], "no loop thread captured")

-- Forty rings, worldui-shaped: marker distance 80, no look-at.
for index = 1, 40 do
    local radius = 5 + (index % 40) * 1.8
    local angle = index * 0.7
    local result = exportsTable.create({
        id = "poi_" .. index,
        position = { x = math.cos(angle) * radius, y = math.sin(angle) * radius, z = 1 },
        markerDistance = 80, distance = 2.0, label = "Enter", key = "E", marker = "chevron",
        requireLookAt = false, priority = 0, icon = "DIALOG", color = "#00E5FF",
    })
    assert(result.ok, tostring(result.error))
end
-- The three global targets the RP set registers, server-declared.
netHandlers["open77:interactions:targets"]({ owner = "rp_crime", targets = { {
    id = "rp_crime_fence", kind = "globalNpc", distance = 2.5, markerDistance = 15.0, marker = "shop",
    label = "Sell", key = "E", event = "rp_crime:fencePrompt", canInteract = { record = { "Character.fence_1" } },
} } })
netHandlers["open77:interactions:targets"]({ owner = "rp_gangs", targets = { {
    id = "rp_gangs_deal", kind = "globalNpc", distance = 2.5, markerDistance = 30.0, marker = "shop",
    label = "Street deal", key = "E", event = "rp_gangs:dealPrompt", canInteract = "rpGangsIsBuyer",
    npcs = "open77",
} } })
netHandlers["open77:interactions:targets"]({ owner = "rp_nomade", targets = { {
    id = "rp_nomade_truck", kind = "globalVehicle", distance = 3.0, markerDistance = 20.0,
    label = "Load", key = "E", event = "rp_nomade:load",
} } })

local co = coroutine.create(loop)
local instructions = 0
debug.sethook(co, function() instructions = instructions + 1 end, "", 1)

local function run(seconds, stepPerFrame)
    local resumes, worst, total, cycles = 0, 0, 0, 0
    local until_ = clock + seconds
    while clock < until_ do
        instructions = 0
        local ok, wait = coroutine.resume(co)
        if not ok then error(tostring(wait) .. "\n" .. debug.traceback(co)) end
        resumes = resumes + 1
        total = total + instructions
        if instructions > worst then worst = instructions end
        if (wait or 0) > 0 then cycles = cycles + 1 end
        -- Wait(0) resumes on the next host tick, one engine frame later.
        clock = clock + math.max(wait or 0, FRAME_SECONDS * 1000) / 1000
        playerPos.x = playerPos.x + stepPerFrame
    end
    return { resumes = resumes, worst = worst, total = total, cycles = cycles }
end

local function rate(name, seconds) return (calls[name] or 0) / seconds end

-- Warm-up: the first resolve, the anchors, the first full gather.
run(1.0, 0.0)

-- ---------------------------------------------------------------------------
-- 1. Walking: the ranked set is rebuilt every cycle.
-- ---------------------------------------------------------------------------
calls = {}
local walking = run(SIMULATED_SECONDS, 0.01)
print(string.format("walking: %d resumes, worst %d instructions, %.0f instructions/s",
    walking.resumes, walking.worst, walking.total / SIMULATED_SECONDS))
assert(walking.worst < HOOK_INTERVAL * 0.9,
    "a resume reached " .. walking.worst .. " VM instructions; the host hook fires at " .. HOOK_INTERVAL)
-- Both globalNpc targets resolve from the registry -- the fence by its record
-- rule, the buyer by declaration -- so the puppet world query never runs.
assert((calls["world.nearby:puppet"] or 0) == 0,
    "the puppet query ran although every globalNpc target is registry-only: " .. tostring(calls["world.nearby:puppet"]))
assert((calls["world.nearby:nil"] or 0) == 0, "a wide world query ran with no model/class target")
assert((calls["players.nearby"] or 0) == 0, "players listed with no crowd target and no globalPlayer")
assert(rate("npcs.all", SIMULATED_SECONDS) <= 2.6, "npcs listed more than once per pass")
assert((calls["vehicles.all"] or 0) == 0, "the whole vehicle registry was marshalled although nearby exists")
assert(rate("vehicles.nearby", SIMULATED_SECONDS) <= 2.6, "vehicles listed more than once per pass")
assert(rate("vehicles.get", SIMULATED_SECONDS) <= 8 * 2.6, "more snapshots fetched than matches per pass")
assert((calls["character.state:body"] or 0) == 0,
    "the scan read bodies with character.state: " .. tostring(calls["character.state:body"]))
assert((calls["camera.project"] or 0) == 0, "candidates were projected in Lua while the native card draws")
assert(rate("anchors.update", SIMULATED_SECONDS) <= 3.0, "the anchor registry was patched every cycle")
assert(rate("exports.callSync", SIMULATED_SECONDS) <= 8 * 2.6, "predicates ran more than once per match per pass")

-- ---------------------------------------------------------------------------
-- 2. Standing still: the set is reused and the cadence idles.
-- ---------------------------------------------------------------------------
calls = {}
local before = exportsTable.stats(true)
local standing = run(SIMULATED_SECONDS, 0.0)
local report = exportsTable.stats(false)
print(string.format("standing: %d resumes, worst %d instructions, %.0f instructions/s, gathers reused %d of %d cycles",
    standing.resumes, standing.worst, standing.total / SIMULATED_SECONDS, report.gathersSkipped, report.cycles))
assert(standing.worst < HOOK_INTERVAL * 0.9, "a resume reached " .. standing.worst .. " VM instructions standing still")
assert(standing.total < walking.total, "standing still cost more Lua than walking")
assert(report.gathersSkipped > report.cycles * 0.5, "the ranked set was rebuilt while nothing changed")
assert((calls["character.state:body"] or 0) == 0, "a body read while standing still")
assert(rate("character.state:local", SIMULATED_SECONDS) <= 40, "more than one local body read per cycle")
-- Standing still, the pass runs at the idle cadence.
assert(rate("npcs.all", SIMULATED_SECONDS) <= 1.3, "the resolve pass did not idle while standing still: " .. tostring(calls["npcs.all"]))

-- ---------------------------------------------------------------------------
-- 3. A crowd target: the query runs, at the cadence, and no faster.
-- ---------------------------------------------------------------------------
netHandlers["open77:interactions:targets"]({ owner = "rp_talk", targets = { {
    id = "rp_talk_anyone", kind = "globalNpc", distance = 2.5, markerDistance = 30.0,
    label = "Talk", key = "E", event = "rp_talk:prompt",
} } })
calls = {}
local crowd = run(SIMULATED_SECONDS, 0.01)
print(string.format("crowd target: %d resumes, worst %d instructions, puppet queries %.1f/s",
    crowd.resumes, crowd.worst, rate("world.nearby:puppet", SIMULATED_SECONDS)))
assert(crowd.worst < HOOK_INTERVAL * 0.9, "a resume reached " .. crowd.worst .. " VM instructions with a crowd target")
assert(rate("world.nearby:puppet", SIMULATED_SECONDS) <= 2.6, "the puppet query ran faster than the resolve cadence")
assert(rate("world.nearby:puppet", SIMULATED_SECONDS) >= 1.0, "the crowd target did not query the world")
assert((calls["character.state:body"] or 0) == 0, "the crowd pass read a body")
assert(type(before) == "table" and before.phases.gather, "the stats export must name its phases")
assert(report.natives.query > 0 and report.natives.state > 0, "the stats export must count its natives")

print("budget.test.lua: all assertions passed")
