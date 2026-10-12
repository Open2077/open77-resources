-- The real client resource, driven against a stubbed runtime.
--
-- Nothing here reimplements the service: `dofile` loads the same
-- client/main.lua the game loads, and every assertion is made on what that file
-- pushes to its page or emits as an event. The stubs are the runtime, not the
-- resource.
--
-- Run from the repository root:
--   lua resources/system/open77_interactions/tests/targets.test.lua

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

-- ---------------------------------------------------------------------------
-- 1. Additive: a hand-written interaction still behaves exactly as before.
-- ---------------------------------------------------------------------------
local created = as("jobs", 1, exported.create, {
    id = "job_center",
    position = vec(1.0, 0.0, 0.0),
    distance = 2.5,
    label = "Consulter les offres",
    key = "E",
    event = "jobs:open",
})
assert(created.ok, created.error)
tick()
assert(contains(visibleChoices(), "Consulter les offres"), "the plain interaction regressed")
assert(as("jobs", 1, exported.remove, created.handle).ok)

-- ---------------------------------------------------------------------------
-- 2. A model target matches, and does not match.
-- ---------------------------------------------------------------------------
world.default = {
    { engineEntity = 4001, className = "VendingMachine", position = vec(1.5, 0, 0), distance = 1.5 },
    { engineEntity = 4002, className = "Streetlight", position = vec(2.0, 0, 0), distance = 2.0 },
}
local vending = as("jobs", 1, exported.addModel, { "Vending_Machine*", "VendingMachine" }, {
    id = "vending",
    distance = 2.5,
    label = "Acheter une boisson",
    key = "E",
    event = "jobs:vending",
})
assert(vending.ok, vending.error)
tick(0.6)
assert(contains(visibleChoices(), "Acheter une boisson"),
    "the model target did not match the vending machine")

local snapshot = as("jobs", 1, exported.getTarget, vending.handle)
assert(snapshot and snapshot.matchCount == 1,
    "exactly one match expected, got " .. tostring(snapshot and snapshot.matchCount))

-- The streetlight must never produce a prompt: remove the machine and the
-- target has nothing left to show.
world.default = {
    { engineEntity = 4002, className = "Streetlight", position = vec(2.0, 0, 0), distance = 2.0 },
}
tick(0.6)
assert(#visibleChoices() == 0, "a non-matching class produced a prompt")
assert(as("jobs", 1, exported.getTarget, vending.handle).matchCount == 0,
    "the match survived its candidate disappearing")
assert(as("jobs", 1, exported.removeTarget, vending.handle).ok)

-- ---------------------------------------------------------------------------
-- 3. A global vehicle target lands on the right vehicle, with the part payload.
-- ---------------------------------------------------------------------------
world.default = {}
-- A replica carries its own position, as `Open77.vehicles.all` reports it;
-- the scan must place it from that, not from a per-vehicle body read.
vehicles = {
    { id = 77, entity = 9001, engineEntity = 5001, record = "Vehicle.v_standard2_villefort_alvarado",
      streamed = true, locked = false, doors = 16, occupants = {}, health = 100.0,
      position = vec(1.2, 0, 0) },
}
placements[9001] = { position = vec(1.2, 0, 0), engineId = 5001 }
local stateReadsBefore = stateReads

local trunk = as("mechanic", 1, exported.addGlobalVehicle, {
    id = "trunk",
    part = "trunk",
    distance = 3.0,
    label = "Ouvrir le coffre",
    key = "E",
    event = "mechanic:trunk",
})
assert(trunk.ok, trunk.error)
tick(0.6)
assert(contains(visibleChoices(), "Ouvrir le coffre"), "the global vehicle target did not appear")
assert(stateReads == stateReadsBefore,
    "the scan read a vehicle body with character.state although the replica carries its position")

-- Fire it and read the payload the owning resource receives.
events = {}
keysDown.E = true
tick()
local fired
for _, entry in ipairs(events) do
    if entry.event == "mechanic:trunk" then fired = entry.payload end
end
keysDown.E = false
assert(fired, "the vehicle prompt did not emit its event")
assert(fired.kind == "globalVehicle", "payload kind: " .. tostring(fired.kind))
assert(fired.vehicleId == 77, "payload vehicleId: " .. tostring(fired.vehicleId))
assert(fired.entity == 9001, "payload entity: " .. tostring(fired.entity))
assert(fired.record == "Vehicle.v_standard2_villefort_alvarado", "payload record")
assert(fired.part == "trunk" and fired.partIndex == 4, "payload part")
-- doors = 16 = 1 << 4, so the trunk bit is set and no other.
assert(fired.partOpen == true, "the trunk door bit was not decoded")
assert(fired.vehicle.locked == false and fired.vehicle.occupied == false, "vehicle state")

-- A second vehicle materialises a second, independent prompt. This replica
-- carries no position, so the bounded fallback read places it.
vehicles[2] = { id = 78, entity = 9002, engineEntity = 5002, record = "Vehicle.v_sport2_quadra_turbo",
    streamed = true, locked = true, doors = 0, occupants = {}, health = 100.0 }
placements[9002] = { position = vec(-10.0, 0, 0), engineId = 5002 }
tick(0.6)
assert(as("mechanic", 1, exported.getTarget, trunk.handle).matchCount == 2,
    "the second vehicle did not materialise")
-- The far one is out of `distance` but inside `markerDistance`, so it exists
-- as an entry and is simply not the winner.
assert(contains(visibleChoices(), "Ouvrir le coffre"), "the near vehicle stopped winning")
assert(as("mechanic", 1, exported.removeTarget, trunk.handle).ok)
vehicles[2], placements[9002] = nil, nil

-- ---------------------------------------------------------------------------
-- 4. canInteract refuses -- as an export, and as a declarative rule.
-- ---------------------------------------------------------------------------
exportResults["mechanic:canOpen"] = function(payload)
    assert(payload.vehicleId == 77, "the predicate payload must carry the match")
    assert(payload.part == "trunk", "the predicate payload must carry the part")
    return payload.vehicle.locked == false
end
local gated = as("mechanic", 1, exported.addGlobalVehicle, {
    id = "gated",
    part = "trunk",
    distance = 3.0,
    label = "Fouiller le coffre",
    key = "F",
    event = "mechanic:search",
    canInteract = "canOpen",
})
assert(gated.ok, gated.error)
tick(0.6)
assert(contains(visibleChoices(), "Fouiller le coffre"), "the export predicate refused an open car")
assert(#exportCalls > 0 and exportCalls[1].resource == "mechanic" and
    exportCalls[1].name == "canOpen", "the predicate must run in the owner's own VM")
local callsAfterFirstResolve = #exportCalls

-- The predicate is resolution-time, not per-frame: several ticks inside one
-- resolve window must not call it again.
tick(0.01)
tick(0.01)
assert(#exportCalls == callsAfterFirstResolve,
    "canInteract was evaluated per tick: " .. #exportCalls .. " calls")

-- And exactly once per resolve, not twice: in the single-choice shorthand the
-- predicate is the target's own and must not be taken as a choice rule as well.
exportCalls = {}
tick(0.6)
assert(#exportCalls == 1,
    "the shorthand predicate ran " .. #exportCalls .. " times in one resolve pass")

vehicles[1].locked = true
tick(0.6)
assert(#visibleChoices() == 0, "the export predicate did not refuse a locked car")

-- A predicate that raises fails closed.
exportResults["mechanic:canOpen"] = function() error("boom") end
vehicles[1].locked = false
tick(0.6)
assert(#visibleChoices() == 0, "a raising predicate must refuse, not grant")
assert(as("mechanic", 1, exported.removeTarget, gated.handle).ok)

-- Declarative form: a group gate read from the player's own state bag.
bagValues.groups = { "ems" }
local police = as("jobs", 1, exported.addGlobalVehicle, {
    id = "impound",
    distance = 3.0,
    label = "Mettre en fourriere",
    key = "G",
    event = "jobs:impound",
    canInteract = { groups = { "police" } },
})
assert(police.ok, police.error)
tick(0.6)
assert(#visibleChoices() == 0, "a player outside the group saw the prompt")
bagValues.groups = { "police", "ems" }
tick(0.6)
assert(contains(visibleChoices(), "Mettre en fourriere"), "the group gate refused a member")
assert(as("jobs", 1, exported.removeTarget, police.handle).ok)

-- A target-level `groups` gate short-circuits before any scan.
bagValues.groups = { "ems" }
local gatedTarget = as("jobs", 1, exported.addGlobalVehicle, {
    id = "policeonly",
    distance = 3.0,
    label = "Saisir",
    key = "H",
    event = "jobs:seize",
    groups = { "police" },
})
assert(gatedTarget.ok, gatedTarget.error)
tick(0.6)
assert(as("jobs", 1, exported.getTarget, gatedTarget.handle).matchCount == 0,
    "a group-gated target materialised for a non-member")
assert(as("jobs", 1, exported.removeTarget, gatedTarget.handle).ok)
bagValues.groups = nil

-- ---------------------------------------------------------------------------
-- 5. globalPlayer and globalNpc, and the player/puppet split.
-- ---------------------------------------------------------------------------
vehicles = {}
placements[7001] = { position = vec(1.0, 0, 0), engineId = 6001 }
nearbyPlayers = { { playerId = 5, entity = 7001, distance = 1.0, position = vec(1.0, 0, 0), name = "Kiwi" } }
world.puppet = {
    { engineEntity = 6001, className = "PlayerPuppet", position = vec(1.0, 0, 0), distance = 1.0 },
    { engineEntity = 6002, className = "NPCPuppet", position = vec(1.4, 0, 0), distance = 1.4 },
}
stateReadsBefore = stateReads
local frisk = as("jobs", 1, exported.addGlobalPlayer, {
    id = "frisk", distance = 3.0, label = "Fouiller", key = "E", event = "jobs:frisk",
})
assert(frisk.ok, frisk.error)
local talk = as("jobs", 1, exported.addGlobalPed, {
    id = "talk", distance = 3.0, label = "Parler", key = "F", event = "jobs:talk",
})
assert(talk.ok, talk.error)
tick(0.6)
assert(as("jobs", 1, exported.getTarget, frisk.handle).matchCount == 1, "globalPlayer match count")
assert(as("jobs", 1, exported.getTarget, talk.handle).matchCount == 1,
    "globalNpc must exclude the player body that is also a puppet")
assert(stateReads == stateReadsBefore,
    "the scan read bodies to tell a player from an NPC: " .. (stateReads - stateReadsBefore))

-- The same, with the identity the world query attaches on a real client: the
-- hit says which player it is, and the roster body is 3 m away (a stale
-- roster frame), so only the id can pair them.
world.puppet = {
    { engineEntity = 6001, className = "PlayerPuppet", position = vec(1.0, 0, 0), distance = 1.0,
      playerId = 5 },
    { engineEntity = 6002, className = "NPCPuppet", position = vec(1.4, 0, 0), distance = 1.4 },
}
nearbyPlayers = { { playerId = 5, entity = 7001, distance = 4.0, position = vec(4.0, 0, 0), name = "Kiwi" } }
tick(0.6)
assert(as("jobs", 1, exported.getTarget, frisk.handle).matchCount == 1, "globalPlayer by identity")
assert(as("jobs", 1, exported.getTarget, talk.handle).matchCount == 1,
    "globalNpc must exclude a player body identified by the world query")

assert(as("jobs", 1, exported.removeTarget, frisk.handle).ok)
assert(as("jobs", 1, exported.removeTarget, talk.handle).ok)

-- A `record`-gated globalNpc can only ever match an Open77 NPC (a crowd puppet
-- carries no record), so it resolves from the NPC registry alone: the row's
-- own position places the fence, no world query runs and no body is read.
npcs = { { id = 31, entity = 7100, record = "Character.fence", streamed = true, position = vec(1.8, 0, 0) } }
world.puppet = {
    { engineEntity = 6002, className = "NPCPuppet", position = vec(1.4, 0, 0), distance = 1.4 },
    { engineEntity = 6003, className = "NPCPuppet", position = vec(1.8, 0, 0), distance = 1.8, npcId = 31 },
}
nearbyPlayers = {}
local fence = as("jobs", 1, exported.addGlobalNpc, {
    id = "fence", distance = 3.0, label = "Vendre", key = "G", event = "jobs:fence",
    canInteract = { record = { "Character.fence" } },
})
assert(fence.ok, fence.error)
assert(as("jobs", 1, exported.getTarget, fence.handle).registryOnly == true,
    "a record-gated globalNpc must be registry-only")
stateReadsBefore = stateReads
local queriesBefore = worldQueries
tick(0.6)
assert(contains(visibleChoices(), "Vendre"), "the record-gated globalNpc did not land on the fence")
assert(stateReads == stateReadsBefore, "placing a registry NPC cost a body read")
assert(worldQueries == queriesBefore, "a registry-only target ran the world query")
local fenceSnapshot = as("jobs", 1, exported.getTarget, fence.handle)
assert(fenceSnapshot.matchCount == 1 and fenceSnapshot.matches[1].key == "n31",
    "the registry match is the fence alone; the crowd puppet is never examined")
assert(as("jobs", 1, exported.removeTarget, fence.handle).ok)

-- The explicit form, `npcs = "open77"`, for a target whose predicate is an
-- export the service cannot see into: registry-only by declaration.
exportResults["jobs:isBuyer"] = function(payload) return payload.npcId == 31 end
local buyer = as("jobs", 1, exported.addGlobalNpc, {
    id = "buyer", distance = 3.0, label = "Deal", key = "G", event = "jobs:deal",
    canInteract = "isBuyer", npcs = "open77",
})
assert(buyer.ok, buyer.error)
assert(as("jobs", 1, exported.getTarget, buyer.handle).registryOnly == true, "npcs = open77 is registry-only")
queriesBefore, stateReadsBefore = worldQueries, stateReads
tick(1.2)
assert(contains(visibleChoices(), "Deal"), "the npcs=open77 target did not land on the buyer")
assert(worldQueries == queriesBefore and stateReads == stateReadsBefore,
    "an npcs=open77 target touched the world or a body")
assert(as("jobs", 1, exported.removeTarget, buyer.handle).ok)
assert(refusalFor(function() return as("jobs", 1, exported.addGlobalNpc, {
    id = "bad", distance = 3.0, label = "x", key = "G", npcs = "vanilla",
}) end) == "invalid_npcs")
assert(refusalFor(function() return as("jobs", 1, exported.addGlobalVehicle, {
    id = "bad2", distance = 3.0, label = "x", key = "G", npcs = "open77",
}) end) == "npcs_requires_global_npc")

-- A host whose NPC rows carry no position (an older client): the registry
-- target still resolves, through the bounded body reads, and still runs no
-- world query.
npcs = { { id = 31, entity = 7100, record = "Character.fence", streamed = true } }
placements[7100] = { position = vec(1.8, 0, 0), engineId = 6003 }
local fence2 = as("jobs", 1, exported.addGlobalNpc, {
    id = "fence2", distance = 3.0, label = "Vendre encore", key = "G", event = "jobs:fence",
    canInteract = { record = { "Character.fence" } },
})
assert(fence2.ok, fence2.error)
queriesBefore = worldQueries
tick(1.2)
assert(contains(visibleChoices(), "Vendre encore"), "the registry target without row positions did not resolve")
assert(worldQueries == queriesBefore, "the fallback ran the world query")
assert(as("jobs", 1, exported.removeTarget, fence2.handle).ok)
placements[7100] = nil

-- A crowd target (no gate) still needs the query, and sees the same NPC once.
local anyone = as("jobs", 1, exported.addGlobalNpc, {
    id = "anyone", distance = 3.0, label = "Parler", key = "G", event = "jobs:talk",
})
assert(anyone.ok, anyone.error)
assert(as("jobs", 1, exported.getTarget, anyone.handle).registryOnly == false, "an ungated globalNpc is a crowd target")
queriesBefore = worldQueries
tick(1.2)
assert(worldQueries > queriesBefore, "a crowd target must query the world")
assert(as("jobs", 1, exported.getTarget, anyone.handle).matchCount == 2,
    "the crowd target sees the crowd puppet and the fence, once each")
assert(as("jobs", 1, exported.removeTarget, anyone.handle).ok)
npcs = {}
nearbyPlayers, world.puppet = {}, {}

-- ---------------------------------------------------------------------------
-- 6. Zones.
-- ---------------------------------------------------------------------------
local counter = as("jobs", 1, exported.addBoxZone, {
    id = "counter",
    position = vec(10.0, 0.0, 0.0),
    size = vec(4.0, 4.0, 3.0),
    distance = 6.0,
    label = "Commander",
    key = "E",
    event = "jobs:order",
})
assert(counter.ok, counter.error)
localPosition = vec(0.0, 0.0, 0.0)
tick(0.6)
assert(as("jobs", 1, exported.getTarget, counter.handle).matchCount == 0,
    "a zone target materialised while the player was outside it")
localPosition = vec(11.0, 1.0, 0.5)
tick(0.6)
assert(as("jobs", 1, exported.getTarget, counter.handle).matchCount == 1,
    "a zone target did not materialise inside its box")
assert(contains(visibleChoices(), "Commander"), "the zone prompt did not appear")
localPosition = vec(13.0, 0.0, 0.0)
tick(0.6)
assert(as("jobs", 1, exported.getTarget, counter.handle).matchCount == 0,
    "the zone target survived leaving the box")
assert(as("jobs", 1, exported.removeTarget, counter.handle).ok)

-- A sphere zone whose card is anchored somewhere other than its centre.
local yard = as("jobs", 1, exported.addZone, {
    id = "yard",
    zone = { shape = "sphere", position = vec(20.0, 0.0, 0.0), radius = 6.0 },
    position = vec(24.0, 0.0, 0.0),
    distance = 4.0,
    label = "Garer",
    key = "E",
    event = "jobs:park",
})
assert(yard.ok, yard.error)
localPosition = vec(21.0, 0.0, 0.0)
tick(0.6)
assert(as("jobs", 1, exported.getTarget, yard.handle).matchCount == 1,
    "the sphere zone did not contain the player")
-- Inside the volume but 3 m from the declared anchor, so still within `distance`.
assert(contains(visibleChoices(), "Garer"), "the zone card did not follow its own anchor")
localPosition = vec(30.0, 0.0, 0.0)
tick(0.6)
assert(as("jobs", 1, exported.getTarget, yard.handle).matchCount == 0,
    "leaving the sphere did not drop the zone target")
assert(as("jobs", 1, exported.removeTarget, yard.handle).ok)

-- Polygon containment.
local lot = as("jobs", 1, exported.addZone, {
    id = "lot",
    zone = { shape = "poly", minZ = -2.0, maxZ = 4.0,
             points = { { x = 40, y = 0 }, { x = 50, y = 0 }, { x = 50, y = 8 }, { x = 40, y = 8 } } },
    distance = 8.0, label = "Deposer", key = "E", event = "jobs:drop",
})
assert(lot.ok, lot.error)
localPosition = vec(45.0, 4.0, 0.0)
tick(0.6)
assert(as("jobs", 1, exported.getTarget, lot.handle).matchCount == 1,
    "the polygon zone did not contain a point inside it")
localPosition = vec(45.0, 4.0, 9.0)
tick(0.6)
assert(as("jobs", 1, exported.getTarget, lot.handle).matchCount == 0,
    "the polygon height band was not applied")
localPosition = vec(60.0, 4.0, 0.0)
tick(0.6)
assert(as("jobs", 1, exported.getTarget, lot.handle).matchCount == 0,
    "the polygon contained a point outside it")
assert(as("jobs", 1, exported.removeTarget, lot.handle).ok)
localPosition = vec(0.0, 0.0, 0.0)

-- ---------------------------------------------------------------------------
-- 7. A server declaration reaches this client, and its retraction removes it.
-- ---------------------------------------------------------------------------
assert(netHandlers["open77:interactions:targets"], "the client never registered the target event")
world.default = {
    { engineEntity = 4100, className = "AtmMachine", position = vec(1.5, 0, 0), distance = 1.5 },
}
netHandlers["open77:interactions:targets"]({
    owner = "bank",
    targets = { {
        id = "atm", kind = "model", models = { "AtmMachine" },
        distance = 2.5, label = "Retirer", key = "E", event = "bank:withdraw",
    } },
})
tick(0.6)
assert(contains(visibleChoices(), "Retirer"), "the server declaration never reached the prompt")

-- The client half of the declaring resource stopping must NOT drop it: a
-- server-declared target belongs to the server.
fire("onClientResourceStop", "bank")
tick(0.6)
assert(contains(visibleChoices(), "Retirer"),
    "a client-side stop dropped a server-declared target")

netHandlers["open77:interactions:retract"]({ owner = "bank" })
tick(0.6)
assert(#visibleChoices() == 0, "the retraction did not remove the server-declared target")

-- ---------------------------------------------------------------------------
-- 8. Cleanup when the declaring resource stops or reloads.
-- ---------------------------------------------------------------------------
world.default = {
    { engineEntity = 4001, className = "VendingMachine", position = vec(1.5, 0, 0), distance = 1.5 },
}
local owned = as("jobs", 1, exported.addModel, { "VendingMachine" }, {
    id = "vending2", distance = 2.5, label = "Acheter", key = "E", event = "jobs:buy",
})
assert(owned.ok, owned.error)
tick(0.6)
assert(contains(visibleChoices(), "Acheter"))

-- A stop of the owner's client VM.
fire("onClientResourceStop", "jobs")
tick(0.6)
assert(#visibleChoices() == 0, "a stopped owner's target kept drawing")
assert(as("jobs", 1, exported.getTarget, owned.handle) == nil, "the target survived the stop")

-- A reload: the generation moves and the owner's previous targets go with it.
-- The runtime's own generation moves with the call: a caller whose generation
-- the runtime does not know is what the sweep below exists to remove.
resourceGenerations.jobs = 2
local reloaded = as("jobs", 2, exported.addModel, { "VendingMachine" }, {
    id = "vending3", distance = 2.5, label = "Acheter encore", key = "E", event = "jobs:buy",
})
assert(reloaded.ok, reloaded.error)
tick(0.6)
assert(contains(visibleChoices(), "Acheter encore"))
resourceGenerations.jobs = 3
-- The periodic sweep notices the generation moved without an export call.
tick(1.2)
tick(0.6)
assert(#visibleChoices() == 0, "a reloaded owner's target survived the generation sweep")

-- ---------------------------------------------------------------------------
-- 9. Refusals are stable snake_case tokens.
-- ---------------------------------------------------------------------------
local function refusal(fn, ...)
    local result = as("jobs", 3, fn, ...)
    assert(result.ok == false, "expected a refusal")
    return result.error
end
assert(refusal(exported.addTarget, { id = "x" }) == "invalid_target_kind")
assert(refusal(exported.addTarget, { id = "x", kind = "model" }) == "invalid_models")
assert(refusal(exported.addTarget, { id = "x", kind = "model", models = {} }) == "invalid_models")
assert(refusal(exported.addTarget, {
    id = "x", kind = "globalPlayer", part = "trunk", label = "a", key = "E",
}) == "part_requires_global_vehicle")
assert(refusal(exported.addTarget, {
    id = "x", kind = "globalVehicle", part = "wing", label = "a", key = "E",
}) == "invalid_vehicle_part")
assert(refusal(exported.addTarget, {
    id = "x", kind = "zone", zone = { shape = "poly", points = { vec(0, 0, 0) } }, label = "a", key = "E",
}) == "invalid_zone_points")
assert(refusal(exported.addTarget, {
    id = "x", kind = "globalVehicle", label = "a", key = "E", maxMatches = 1000,
}) == "invalid_max_matches")
assert(refusal(exported.addTarget, {
    id = "x", kind = "globalVehicle", label = "a", key = "E", distance = 90,
}) == "invalid_distance", "a target must reuse the interaction validator")
assert(refusal(exported.removeTarget, 9999) == "target_not_found")

local duplicate = as("jobs", 3, exported.addTarget, {
    id = "dup", kind = "globalVehicle", label = "a", key = "E",
})
assert(duplicate.ok)
assert(refusal(exported.addTarget, {
    id = "dup", kind = "globalVehicle", label = "a", key = "E",
}) == "duplicate_target_id")

-- ---------------------------------------------------------------------------
-- 10. The cost report names its phases.
-- ---------------------------------------------------------------------------
local report = exported.stats(true)
assert(type(report) == "table" and type(report.phases) == "table", "stats export shape")
assert(report.phases.targets and report.phases.gather and report.phases.select and report.phases.input,
    "every tick phase must be timed")
assert(report.phases.resolve and report.phases.resolve.count > 0, "resolve passes must be counted")
assert(type(report.natives) == "table" and report.natives.query > 0, "native calls must be counted")
assert(report.cycles > 0, "cycles must be counted")

print("targets.test.lua: all assertions passed")
