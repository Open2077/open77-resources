-- Client prop targets (0.3.0), driven against the same stubbed runtime as
-- targets.test.lua: the real client/main.lua, a stubbed `open77_props` mirror.
--
-- Run from the repository root:
--   lua resources/system/open77_interactions/tests/proptargets.test.lua
--   (also run in-process by server/tests/.../InteractionsLuaTests.cs)


local clock = 1000.0
local handlers, netHandlers, exported, threads = {}, {}, {}, {}
local events, serverEvents, sent = {}, {}, {}
local onReady
local keysDown, captured = {}, false

-- The world the stubbed runtime reports.
local world = { default = {}, puppet = {} }
local vehicles = {}
local npcs = {}
local nearbyPlayers = {}
local placements = {}
local bagValues = {}
local exportResults = {}
local exportCalls = {}
local localPosition = { x = 0.0, y = 0.0, z = 0.0 }
local resourceStates = { jobs = "running", mechanic = "running" }
local resourceGenerations = { jobs = 1, mechanic = 1 }

local function vec(x, y, z) return { x = x, y = y, z = z } end

local page = {}
function page:on(event, callback)
    if event == "interactions:ready" then onReady = callback end
end
function page:send(event, payload) sent[#sent + 1] = { event = event, payload = payload } end

-- Body reads the resource makes for something other than the local player.
-- The scan must place NPCs, players and vehicles from the lists that already
-- carry their positions; every one of these was a native call the plugin
-- answered with a walk over every vehicle in the world.
local stateReads = 0
local worldQueries = 0
Open77 = {
    time = { monotonic = function() return clock end },
    log = { warn = print, info = print },
    character = {
        state = function(entity)
            if entity == nil or entity == 0 then
                return { attached = true, position = localPosition, isPlayer = true }
            end
            stateReads = stateReads + 1
            local placement = placements[entity]
            if not placement then return nil, "unknown_entity" end
            return { attached = true, position = placement.position, engineId = placement.engineId }
        end,
    },
    world = {
        nearby = function(_, filter)
            worldQueries = worldQueries + 1
            if filter == "puppet" then return world.puppet end
            return world.default
        end,
    },
    vehicles = {
        all = function() return vehicles end,
        get = function(id)
            for _, vehicle in ipairs(vehicles) do
                if vehicle.id == id then return vehicle end
            end
            return nil
        end,
    },
    npcs = { all = function() return npcs end },
    players = { nearby = function() return nearbyPlayers end },
    camera = { project = function() return { x = 0.5, y = 0.5, onScreen = true } end },
    input = {
        isCaptured = function() return captured end,
        isDown = function(key) return keysDown[key] == true end,
    },
    resource = { generation = function(name) return resourceGenerations[name] end },
    state = {
        localPlayer = function()
            return setmetatable({}, { __index = {
                get = function(_, key) return bagValues[key] end,
            } })
        end,
    },
    exports = {
        callSync = function(resource, name, payload)
            exportCalls[#exportCalls + 1] = { resource = resource, name = name, payload = payload }
            local entry = exportResults[resource .. ":" .. name]
            if entry == nil then error("export_not_found") end
            if type(entry) == "function" then return entry(payload) end
            return entry
        end,
    },
}

WebUI = { create = function() return page end }

-- The zone geometry is the runtime's shared prelude, loaded from the source
-- tree exactly as the client embeds it -- the containment answers here are
-- the ones the game gives.
dofile("scripting/lua/open77_zones.lua")

function AddEventHandler(event, callback)
    handlers[event] = handlers[event] or {}
    table.insert(handlers[event], callback)
end
function RegisterNetEvent(event, callback) netHandlers[event] = callback end
function TriggerEvent(event, payload) events[#events + 1] = { event = event, payload = payload } end
function TriggerServerEvent(event, ...) serverEvents[#serverEvents + 1] = { event = event, args = { ... } } end
function CreateThread(callback) threads[#threads + 1] = coroutine.create(callback) end
function Wait(ms) coroutine.yield(ms or 0) end
function exports(name, fn) exported[name] = fn end
function GetCurrentResourceName() return "open77_interactions" end
function GetResourceState(name) return resourceStates[name] or "stopped" end

local invoking, invokingGeneration = "jobs", 1
function GetInvokingResource() return invoking end
function GetInvokingResourceGeneration() return invokingGeneration end

local function as(resource, generation, fn, ...)
    local previousName, previousGeneration = invoking, invokingGeneration
    invoking, invokingGeneration = resource, generation or resourceGenerations[resource] or 1
    local result = fn(...)
    invoking, invokingGeneration = previousName, previousGeneration
    return result
end

local function fire(event, ...)
    for _, callback in ipairs(handlers[event] or {}) do callback(...) end
end

-- One arbitration CYCLE, which is several resumes: the tick yields `Wait(0)`
-- between its phases and inside its chunked walks, and ends the cycle with a
-- positive wait. Resuming until that positive wait is what makes one `tick`
-- here one cycle in the game.
local function tick(seconds)
    clock = clock + (seconds or 0.05)
    sent = {}
    for _ = 1, 64 do
        local ok, wait = coroutine.resume(threads[1])
        assert(ok, wait)
        if (wait or 0) > 0 then return end
    end
    error("the arbitration tick never finished a cycle")
end

local function lastUpdate()
    for index = #sent, 1, -1 do
        if sent[index].event == "interaction:update" then return sent[index].payload end
    end
    return nil
end

local function visibleChoices()
    local update = lastUpdate()
    if not update or update.visible ~= true then return {} end
    local labels = {}
    for _, choice in ipairs(update.choices or {}) do
        if choice.enabled then labels[#labels + 1] = choice.label end
    end
    return labels
end

local function contains(list, value)
    for _, item in ipairs(list) do
        if item == value then return true end
    end
    return false
end

local function refusalFor(fn)
    local result = fn()
    assert(result.ok == false, "expected a refusal")
    return result.error
end

dofile("resources/system/open77_interactions/client/main.lua")
fire("onClientResourceStart", "open77_interactions")
assert(onReady, "the page never registered its ready handler")
onReady()
assert(#serverEvents == 1 and serverEvents[1].event == "open77:interactions:sync",
    "the client must ask the server for standing declarations on start")

-- The `open77_props` projection mirror: what this client currently projects.
local projected = {}
exportResults["open77_props:get"] = function(id) return projected[tostring(id)] end
exportResults["open77_props:all"] = function()
    local out = {}
    for _, record in pairs(projected) do out[#out + 1] = record end
    return out
end
-- What open77_props raises as it projects and drops props.
local function project(id, record)
    projected[id] = record
    fire("open77:props:added", tonumber(id), record)
end
local function unproject(id)
    projected[id] = nil
    fire("open77:props:removed", tonumber(id), "stream_out")
end
resourceStates.crime = "running"
resourceGenerations.crime = 1

local passed = 0
local function check(condition, message)
    assert(condition, message)
    passed = passed + 1
end

local function firedPayload(eventName)
    for _, entry in ipairs(events) do
        if entry.event == eventName then return entry.payload end
    end
    return nil
end

local function entryFor(owner, id)
    for _, entry in ipairs(as(owner, 1, exported.all)) do
        if entry.id == id then return entry end
    end
    return nil
end

-- ---------------------------------------------------------------------------
-- 1. A client-declared prop target on the resource's OWN prop.
-- ---------------------------------------------------------------------------
projected["101"] = { id = 101, resource = "jobs", model = "crate.small", kind = "prop",
    position = vec(1.5, 0.0, 0.0), visible = true }
projected["102"] = { id = 102, resource = "other", model = "crate.cargo", kind = "prop",
    position = vec(1.0, 0.5, 0.0), visible = true }

local crate = as("jobs", 1, exported.addProp, { "101", 102 }, {
    id = "crate", distance = 2.5, label = "Ouvrir la caisse", key = "E", event = "jobs:crate",
})
check(crate.ok, crate.error)
local before = worldQueries
tick(0.6)
check(worldQueries == before, "a prop target must never run a world query")
check(contains(visibleChoices(), "Ouvrir la caisse"), "the own-prop prompt did not appear")
local snapshot = as("jobs", 1, exported.getTarget, crate.handle)
check(snapshot.kind == "prop" and snapshot.matchCount == 1,
    "only the resource's own prop may match a client-declared target, got " .. tostring(snapshot.matchCount))
local entry = entryFor("jobs", "crate:prop:101")
check(entry and math.abs(entry.position.x - 1.5) < 1e-6, "the entry sits on the prop")
check(entry.offset.z == 0.5, "a prop target lifts its card by default")

-- Pressing E carries the prop identity, as a claim.
events = {}
keysDown.E = true
tick()
keysDown.E = false
local fired = firedPayload("jobs:crate")
check(fired, "the prop prompt did not emit its event")
check(fired.kind == "prop" and fired.propId == "101", "payload propId: " .. tostring(fired and fired.propId))
check(fired.propModel == "crate.small" and fired.propOwner == "jobs", "payload model/owner")
check(fired.targetId == "crate", "payload targetId")

-- ---------------------------------------------------------------------------
-- 2. The prompt follows the prop: a move shows at the next resolve pass.
-- ---------------------------------------------------------------------------
projected["101"].position = vec(1.8, 0.4, 0.0)
tick(1.1)
entry = entryFor("jobs", "crate:prop:101")
check(entry and math.abs(entry.position.x - 1.8) < 1e-6 and math.abs(entry.position.y - 0.4) < 1e-6,
    "the materialised entry did not follow the moved prop")

-- Hidden, attached and streamed-out props drop the match.
projected["101"].attachment = { parentType = "player", parentId = 3 }
tick(1.1)
check(as("jobs", 1, exported.getTarget, crate.handle).matchCount == 0, "a carried prop keeps no prompt")
projected["101"].attachment = nil
tick(1.1)
check(as("jobs", 1, exported.getTarget, crate.handle).matchCount == 1, "a set-down prop gets its prompt back")
unproject("101")
tick(1.1)
check(as("jobs", 1, exported.getTarget, crate.handle).matchCount == 0, "a streamed-out prop drops its prompt")
local callsBefore = #exportCalls
tick(1.1)
local getCalls = 0
for index = callsBefore + 1, #exportCalls do
    if exportCalls[index].name == "get" and exportCalls[index].payload == "101" then getCalls = getCalls + 1 end
end
check(getCalls == 0, "a prop that is not projected costs no export call")
check(#visibleChoices() == 0, "no card left behind")
check(as("jobs", 1, exported.removeTarget, crate.handle).ok)

-- ---------------------------------------------------------------------------
-- 3. Server-declared prop targets: the server authorized them, so a foreign
--    prop matches; maxMatches keeps the nearest.
-- ---------------------------------------------------------------------------
project("101", { id = 101, resource = "jobs", model = "crate.small", kind = "prop",
    position = vec(1.5, 0.0, 0.0), visible = true })
project("103", { id = 103, resource = "other", model = "crate.cargo", kind = "prop",
    position = vec(4.0, 0.0, 0.0), visible = true })
project("104", { id = 104, resource = "other", model = "crate.cargo", kind = "prop",
    position = vec(60.0, 0.0, 0.0), visible = true })
netHandlers["open77:interactions:targets"]({
    owner = "crime",
    targets = {
        { id = "search", kind = "prop", props = { "102", "103", "104" }, distance = 2.5,
          markerDistance = 12.0, maxMatches = 1, label = "Fouiller", key = "F", event = "crime:search" },
    },
})
tick(0.6)
local serverTarget
for _, target in ipairs(as("crime", 1, exported.allTargets)) do
    if target.id == "search" then serverTarget = target end
end
check(serverTarget and serverTarget.source == "server", "the server declaration was applied")
check(serverTarget.matchCount == 1, "maxMatches = 1 keeps one match, got " .. tostring(serverTarget.matchCount))
check(entryFor("crime", "search:prop:102") ~= nil, "the nearest authorized prop wins the match")
check(entryFor("crime", "search:prop:104") == nil, "a prop beyond markerDistance never materialises")

-- The server withdrawing a prop (grant revoked) removes it on the next push.
netHandlers["open77:interactions:targets"]({ owner = "crime", targets = {} })
tick(0.6)
check(entryFor("crime", "search:prop:102") == nil, "the retracted server prop target left an entry")

-- ---------------------------------------------------------------------------
-- 4. Refusals.
-- ---------------------------------------------------------------------------
check(refusalFor(function() return as("jobs", 1, exported.addProp, {}, { label = "x", key = "E" }) end)
    == "invalid_props", "empty prop list")
check(refusalFor(function() return as("jobs", 1, exported.addProp, { "0012" }, { label = "x", key = "E" }) end)
    == "invalid_props", "non-canonical id")
check(refusalFor(function() return as("jobs", 1, exported.addTarget,
    { kind = "prop", props = { "1" }, includeAttached = "yes", label = "x", key = "E" }) end)
    == "invalid_include_attached", "includeAttached must be boolean")
check(refusalFor(function() return as("jobs", 1, exported.addTarget,
    { kind = "prop", props = { "1" }, label = "x", key = "nope" }) end)
    == "unsupported_action_key", "presentation is still validated by the shared normaliser")

-- No `open77_props` running: prop targets match nothing, and nothing raises.
exportResults["open77_props:get"] = nil
local orphan = as("jobs", 1, exported.addProp, "101", { id = "orphan", label = "Orphan", key = "E" })
check(orphan.ok, orphan.error)
tick(1.1)
check(as("jobs", 1, exported.getTarget, orphan.handle).matchCount == 0, "no mirror, no match")

print(("[open77_interactions prop target tests] %d passed"):format(passed))
TestResult = { passed = passed, failed = 0, failures = {} }
