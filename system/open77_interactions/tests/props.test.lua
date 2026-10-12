-- The real server half's prop targets and cross-resource prop grants, driven
-- against a stubbed runtime: a prop registry (`Open77.props.get`), resource
-- states, the server-local event bus and the client fan-out.
--
--   lua resources/system/open77_interactions/tests/props.test.lua
--   (also run in-process by server/tests/.../InteractionsLuaTests.cs)

local clock = 100.0
local handlers, netHandlers, exported, threads = {}, {}, {}, {}
local wire, bus = {}, {}
local resourceStates = { owner = "running", crime = "running", other = "running" }
local resourceGenerations = { owner = 1, crime = 1, other = 1 }
local registry = {
    ["101"] = { id = "101", resource = "owner", model = "crate.small" },
    ["102"] = { id = "102", resource = "owner", model = "crate.cargo" },
    ["201"] = { id = "201", resource = "other", model = "container.barrel" },
}

Open77 = {
    time = { monotonic = function() return clock end },
    resource = { generation = function(name) return resourceGenerations[name] end },
    props = { get = function(id) return registry[tostring(id)] end },
}

function TriggerClientEvent(event, target, payload)
    wire[#wire + 1] = { event = event, target = target, payload = payload }
    return true
end
function TriggerEvent(event, ...) bus[#bus + 1] = { event = event, args = { ... } } end
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

local invoking, invokingGeneration = "owner", 1
function GetInvokingResource() return invoking end
function GetInvokingResourceGeneration() return invokingGeneration end

local function as(resource, fn, ...)
    local previousName, previousGeneration = invoking, invokingGeneration
    invoking, invokingGeneration = resource, resourceGenerations[resource] or 1
    local a, b, c = fn(...)
    invoking, invokingGeneration = previousName, previousGeneration
    return a, b, c
end

local function fire(event, ...)
    for _, callback in ipairs(handlers[event] or {}) do callback(...) end
end

local function tick(seconds)
    clock = clock + (seconds or 3.0)
    local ok, reason = coroutine.resume(threads[1])
    assert(ok, reason)
end

local function lastPushFor(owner)
    for index = #wire, 1, -1 do
        local message = wire[index]
        if message.event == "open77:interactions:targets" and message.payload.owner == owner then
            return message.payload
        end
    end
    return nil
end

local function lastBus(event)
    for index = #bus, 1, -1 do
        if bus[index].event == event then return bus[index].args end
    end
    return nil
end

local function propsOf(payload, targetId)
    for _, definition in ipairs(payload.targets) do
        if definition.id == targetId then return definition.props end
    end
    return nil
end

local passed = 0
local function check(condition, message)
    assert(condition, message)
    passed = passed + 1
end

dofile("resources/system/open77_interactions/server/main.lua")

local search = {
    id = "search", kind = "prop", props = { "101" }, distance = 2.0,
    label = "Search", key = "E", event = "crime:search",
}

-- ---------------------------------------------------------------------------
-- 1. The owner declares a prop target on its own props.
-- ---------------------------------------------------------------------------
local ok, reason = as("owner", exported.define, {
    id = "open", kind = "prop", props = { 102, "101", "101" }, label = "Open", key = "E",
})
check(ok, reason)
local pushed = lastPushFor("owner")
check(pushed and #pushed.targets == 1, "owner declaration pushed")
local ids = propsOf(pushed, "open")
check(#ids == 2 and ids[1] == "101" and ids[2] == "102", "ids canonicalised, sorted, de-duplicated")
check(pushed.targets[1].prop == nil, "the singular alias is folded into props")

-- `prop` is accepted for a single id too (a define replaces the owner's set).
check(as("owner", exported.define, {
    { id = "open", kind = "prop", props = { 102, "101" }, label = "Open", key = "E" },
    { id = "one", kind = "prop", prop = "101", label = "One", key = "E" },
}))
check(#lastPushFor("owner").targets == 2, "both prop targets pushed")

-- ---------------------------------------------------------------------------
-- 2. Another resource cannot target the owner's prop without a grant.
-- ---------------------------------------------------------------------------
ok, reason = as("crime", exported.define, search)
check(ok == false and reason == "prop_not_authorized", "foreign prop refused: " .. tostring(reason))
ok, reason = as("crime", exported.define, { id = "x", kind = "prop", props = { "999" }, label = "X", key = "E" })
check(ok == false and reason == "prop_not_found", "unknown prop refused")
ok, reason = as("crime", exported.define, { id = "x", kind = "prop", props = { "abc" }, label = "X", key = "E" })
check(ok == false and reason == "invalid_props", "malformed id refused")
ok, reason = as("crime", exported.define, { id = "x", kind = "prop", props = {}, label = "X", key = "E" })
check(ok == false and reason == "invalid_props", "empty list refused")
local tooMany = {}
for index = 1, 129 do tooMany[index] = tostring(1000 + index) end
ok, reason = as("crime", exported.define, { id = "x", kind = "prop", props = tooMany, label = "X", key = "E" })
check(ok == false and reason == "invalid_props", "over 128 ids refused")

-- Nobody but the owner may grant, revoke or list grants.
ok, reason = as("crime", exported.grantProp, "101", "crime")
check(ok == false and reason == "invalid_grantee", "self grant refused")
ok, reason = as("other", exported.grantProp, "101", "crime")
check(ok == false and reason == "not_prop_owner", "non-owner grant refused")
local list, why = as("crime", exported.propGrants, "101")
check(list == nil and why == "not_prop_owner", "non-owner cannot list grants")
check(as("crime", exported.propAccess, "101") == false, "no access before a grant")

-- ---------------------------------------------------------------------------
-- 3. Request -> owner answers -> grantee declares.
-- ---------------------------------------------------------------------------
local requestId = as("crime", exported.requestProp, "101", { note = "pickpocket crate" })
check(type(requestId) == "string", "request issued")
local event = lastBus("open77_interactions:propRequested")
check(event and event[1] == requestId and event[2] == "101" and event[3] == "crime" and event[5] == "owner",
    "owner hears the request with the requester name the runtime gave")
check(as("crime", exported.requestProp, "101") == requestId, "a repeated request is idempotent")
local selfRequest, selfWhy = as("owner", exported.requestProp, "101")
check(selfRequest == nil and selfWhy == "already_owner", "owner does not request its own prop")

ok, reason = as("other", exported.answerPropRequest, requestId, true)
check(ok == false and reason == "not_prop_owner", "only the prop owner answers")
ok, reason = as("owner", exported.answerPropRequest, requestId, true, { ttlMs = 60000, note = "night shift" })
check(ok, reason)
event = lastBus("open77_interactions:propAnswered")
check(event and event[1] == requestId and event[4] == true, "requester hears the grant")
local access, kind = as("crime", exported.propAccess, "101")
check(access == true and kind == "granted", "grantee has access")
access, kind = as("owner", exported.propAccess, "101")
check(access == true and kind == "owner", "owner has access")
check(as("crime", exported.propAccess, "102") == false, "a grant covers one prop")

ok, reason = as("crime", exported.define, search)
check(ok, reason)
pushed = lastPushFor("crime")
check(pushed and propsOf(pushed, "search")[1] == "101", "grantee's prop target is pushed")

list = as("owner", exported.propGrants, "101")
check(#list == 1 and list[1].grantee == "crime" and list[1].note == "night shift" and list[1].expiresInMs > 0,
    "owner lists the grant")

-- A grant still grants nothing in the registry: this resource never mutates props.
check(registry["101"].resource == "owner", "ownership untouched")

-- ---------------------------------------------------------------------------
-- 4. Revocation withdraws the prompt at once.
-- ---------------------------------------------------------------------------
local before = #wire
ok, reason = as("owner", exported.revokeProp, "101", "crime")
check(ok, reason)
check(#wire > before, "revocation re-pushed the grantee's declaration")
pushed = lastPushFor("crime")
check(#pushed.targets == 0, "the revoked target is withheld from clients")
event = lastBus("open77_interactions:propRevoked")
check(event and event[1] == "101" and event[2] == "crime" and event[3] == "revoked", "revocation announced")
check(as("crime", exported.propAccess, "101") == false, "access gone")
ok, reason = as("owner", exported.revokeProp, "101", "crime")
check(ok == false and reason == "grant_not_found", "double revoke refused")

-- Re-granting restores the declared target (it is still declared).
check(as("owner", exported.grantProp, "101", "crime", { ttlMs = 5000 }))
pushed = lastPushFor("crime")
check(propsOf(pushed, "search") and propsOf(pushed, "search")[1] == "101", "a new grant restores the prompt")

-- ---------------------------------------------------------------------------
-- 5. Expiry: the sweep lapses the grant and re-pushes.
-- ---------------------------------------------------------------------------
tick(6.0)
pushed = lastPushFor("crime")
check(#pushed.targets == 0, "the expired grant withdrew the prompt")
event = lastBus("open77_interactions:propRevoked")
check(event and event[3] == "expired", "expiry announced")

ok, reason = as("owner", exported.grantProp, "101", "crime", { ttlMs = 10 })
check(ok == false and reason == "invalid_ttl", "a sub-second ttl is refused")

-- ---------------------------------------------------------------------------
-- 6. Requests time out, and a denial is an answer.
-- ---------------------------------------------------------------------------
local second = as("crime", exported.requestProp, "102")
check(type(second) == "string", "second request")
tick(31.0)
event = lastBus("open77_interactions:propAnswered")
check(event and event[1] == second and event[4] == false and event[5] == "request_expired", "silence refuses")
local third = as("crime", exported.requestProp, "102")
check(as("owner", exported.answerPropRequest, third, false, { reason = "closed_now" }))
event = lastBus("open77_interactions:propAnswered")
check(event and event[1] == third and event[4] == false and event[5] == "closed_now", "denial carries a reason")
ok, reason = as("owner", exported.answerPropRequest, third, true)
check(ok == false and reason == "request_not_found", "an answered request is gone")

-- ---------------------------------------------------------------------------
-- 7. A removed prop takes its grants, and the owner's prompt, with it.
-- ---------------------------------------------------------------------------
check(as("owner", exported.grantProp, "102", "crime"))
check(as("crime", exported.define, { id = "loot", kind = "prop", props = { "102" }, label = "Loot", key = "E" }))
registry["102"] = nil
local beforeRemoval = #wire
fire("onPropRemoved", "102", "removed", "owner")
check(#wire == beforeRemoval, "a removal marks owners; it does not re-push per prop")
tick(3.0)
pushed = lastPushFor("crime")
check(#pushed.targets == 0, "grantee prompt withdrawn when the prop disappears")
pushed = lastPushFor("owner")
check(propsOf(pushed, "one") and #propsOf(pushed, "open") == 1 and propsOf(pushed, "open")[1] == "101",
    "the owner's target keeps only the props that still exist")
check(as("crime", exported.propAccess, "102") == false, "no access to a removed prop")

-- ---------------------------------------------------------------------------
-- 8. Late join receives the effective set, and non-prop targets are untouched.
-- ---------------------------------------------------------------------------
check(as("other", exported.define, {
    { id = "atm", kind = "model", models = { "AtmMachine" }, label = "Retirer", key = "E" },
    { id = "barrel", kind = "prop", props = { "201" }, label = "Barrel", key = "E" },
}))
local count = #wire
fire("onPlayerConnected", 7)
local joined = {}
for index = count + 1, #wire do
    if wire[index].target == 7 then joined[wire[index].payload.owner] = wire[index].payload end
end
check(joined.other and #joined.other.targets == 2, "late join gets the other resource's two targets")
check(joined.owner and propsOf(joined.owner, "open")[1] == "101", "late join gets the effective prop list")

-- A stopped declarer is retracted by the generation sweep, as before.
resourceStates.other = "stopped"
tick(3.0)
local retracted = false
for index = #wire, 1, -1 do
    if wire[index].event == "open77:interactions:retract" and wire[index].payload.owner == "other" then
        retracted = true
        break
    end
end
check(retracted, "stopped declarer retracted")

print(("[open77_interactions props tests] %d passed"):format(passed))
TestResult = { passed = passed, failed = 0, failures = {} }
