-- The real server half, driven against a stubbed runtime.
--
--   lua resources/system/open77_interactions/tests/declare.test.lua

local clock = 100.0
local handlers, netHandlers, exported, threads = {}, {}, {}, {}
local wire = {}
local resourceStates = { jobs = "running", bank = "running" }
local resourceGenerations = { jobs = 1, bank = 1 }

Open77 = {
    time = { monotonic = function() return clock end },
    resource = { generation = function(name) return resourceGenerations[name] end },
}

function TriggerClientEvent(event, target, payload)
    wire[#wire + 1] = { event = event, target = target, payload = payload }
    return true
end
function RegisterNetEvent(event, callback) netHandlers[event] = callback end
function AddEventHandler(event, callback)
    handlers[event] = handlers[event] or {}
    table.insert(handlers[event], callback)
end
function CreateThread(callback) threads[#threads + 1] = coroutine.create(callback) end
function Wait() coroutine.yield() end
function exports(name, fn) exported[name] = fn end
function GetCurrentResourceName() return "open77_interactions" end
function GetResourceState(name) return resourceStates[name] or "stopped" end

local invoking, invokingGeneration = "jobs", 1
function GetInvokingResource() return invoking end
function GetInvokingResourceGeneration() return invokingGeneration end

local function as(resource, fn, ...)
    local previousName, previousGeneration = invoking, invokingGeneration
    invoking, invokingGeneration = resource, resourceGenerations[resource] or 1
    local ok, reason = fn(...)
    invoking, invokingGeneration = previousName, previousGeneration
    return ok, reason
end

local function fire(event, ...)
    for _, callback in ipairs(handlers[event] or {}) do callback(...) end
end

local function tick(seconds)
    clock = clock + (seconds or 3.0)
    local ok, reason = coroutine.resume(threads[1])
    assert(ok, reason)
end

local function lastFor(event)
    for index = #wire, 1, -1 do
        if wire[index].event == event then return wire[index] end
    end
    return nil
end

dofile("resources/system/open77_interactions/server/main.lua")

-- ---------------------------------------------------------------------------
-- 1. One declaration broadcasts to everyone.
-- ---------------------------------------------------------------------------
local ok, reason = as("jobs", exported.define, {
    id = "atm", kind = "model", models = { "AtmMachine" },
    distance = 2.5, label = "Retirer", key = "E", event = "bank:withdraw",
})
assert(ok, reason)
local message = lastFor("open77:interactions:targets")
assert(message, "define did not broadcast")
assert(message.target == -1, "define must broadcast to every client")
assert(message.payload.owner == "jobs", "the owner comes from the runtime, never the payload")
assert(#message.payload.targets == 1 and message.payload.targets[1].id == "atm")

-- A list of targets is accepted, and so is a single one.
assert(as("jobs", exported.define, {
    { id = "atm", kind = "model", models = { "AtmMachine" }, label = "Retirer", key = "E" },
    { id = "chair", kind = "model", models = { "Chair*" }, label = "S'asseoir", key = "F" },
}))
assert(#lastFor("open77:interactions:targets").payload.targets == 2)

-- ---------------------------------------------------------------------------
-- 2. A late joiner is caught up, and so is a client that asks.
-- ---------------------------------------------------------------------------
wire = {}
fire("onPlayerConnected", "12")
local caught = lastFor("open77:interactions:targets")
assert(caught and caught.target == 12, "a late joiner was not caught up")
assert(#caught.payload.targets == 2)

wire = {}
source = "13"
netHandlers["open77:interactions:sync"]()
assert(lastFor("open77:interactions:targets").target == 13, "the pull path did not answer")

-- ---------------------------------------------------------------------------
-- 3. Refusals are stable snake_case tokens.
-- ---------------------------------------------------------------------------
local function refusal(...)
    local accepted, why = as("jobs", exported.define, ...)
    assert(accepted == false, "expected a refusal")
    return why
end
assert(refusal("nope") == "definitions_must_be_a_table")
assert(refusal({}) == "invalid_target_count")
assert(refusal({ { kind = "model" } }) == "invalid_target_id")
assert(refusal({
    { id = "a", kind = "model" }, { id = "a", kind = "model" },
}) == "duplicate_target_id")
local huge = { id = "big", kind = "model", blob = {} }
for index = 1, 2000 do huge.blob[index] = string.rep("x", 64) end
assert(refusal(huge) == "declaration_too_large")

-- ---------------------------------------------------------------------------
-- 4. Retraction: explicit, and by the declaring resource going away.
-- ---------------------------------------------------------------------------
wire = {}
assert(as("jobs", exported.undefine, "chair"))
assert(#lastFor("open77:interactions:targets").payload.targets == 1,
    "undefine must republish the survivors")

wire = {}
assert(as("jobs", exported.undefine, "atm"))
local retracted = lastFor("open77:interactions:retract")
assert(retracted and retracted.target == -1 and retracted.payload.owner == "jobs",
    "the last target going away must retract the owner")

-- A resource that stops is retracted whether or not it says so.
assert(as("bank", exported.define, {
    id = "vault", kind = "zone", zone = { shape = "sphere", position = { x = 0, y = 0, z = 0 }, radius = 4 },
    label = "Ouvrir", key = "E",
}))
wire = {}
resourceStates.bank = "stopped"
tick()
retracted = lastFor("open77:interactions:retract")
assert(retracted and retracted.payload.owner == "bank",
    "a stopped declaring resource was not retracted")

-- And so is one that merely reloaded.
resourceStates.bank = "running"
assert(as("bank", exported.define, {
    id = "vault", kind = "zone", zone = { shape = "sphere", position = { x = 0, y = 0, z = 0 }, radius = 4 },
    label = "Ouvrir", key = "E",
}))
wire = {}
resourceGenerations.bank = 2
tick()
retracted = lastFor("open77:interactions:retract")
assert(retracted and retracted.payload.owner == "bank",
    "a reloaded declaring resource was not retracted")

-- ---------------------------------------------------------------------------
-- 5. `onResourceStop` on the declaring resource retracts immediately.
-- ---------------------------------------------------------------------------
assert(as("jobs", exported.define, {
    id = "atm", kind = "model", models = { "AtmMachine" }, label = "Retirer", key = "E",
}))
wire = {}
fire("onResourceStop", "jobs")
retracted = lastFor("open77:interactions:retract")
assert(retracted and retracted.payload.owner == "jobs", "onResourceStop did not retract")
assert(as("jobs", exported.undefine) == false, "the declaration should be gone")

print("declare.test.lua: all assertions passed")
