-- Server-side target declaration.
--
-- A job resource should describe its targets once -- "every vehicle gets a
-- Repair option for mechanics", "the ATM model gets a Withdraw option" -- and
-- have every connected client apply them. Doing that per client from a client
-- script means every gamemode reimplements the same fan-out, and gets late
-- joins wrong.
--
-- The wire is an ordinary authenticated net event, not a new protocol message:
-- `open77:interactions:targets` and `open77:interactions:retract`. The client
-- half trusts the `owner` in the message precisely because the message can only
-- have come from the server.
--
-- Nothing here is authority. A target is a prompt, and a prompt is
-- presentation: the client owns the code that decides whether to draw it, so
-- every rule a target seems to enforce -- the group gate, the distance, the
-- vehicle state -- must be re-derived by whatever server handler receives the
-- intent the player's key press produces.

local MAX_TARGETS_PER_OWNER = 32
local MAX_DECLARATION_BYTES = 16384

local declarations = {}
local generations = {}
local nextSweep = 0

local function validName(value, maximum)
    return type(value) == "string" and #value > 0 and #value <= maximum and
        value:match("^[%w_:%-%.]+$") ~= nil
end

-- Declarations are copied across the export boundary already, so this is not
-- about aliasing: it is a hard bound on what one resource can make the server
-- fan out to every client on every join.
local function measure(value, depth, budget)
    local kind = type(value)
    if kind == "string" then return budget - #value - 2 end
    if kind == "number" or kind == "boolean" or kind == "nil" then return budget - 8 end
    if kind ~= "table" or depth > 8 then return -1 end
    for key, item in pairs(value) do
        budget = measure(key, depth + 1, budget)
        if budget < 0 then return -1 end
        budget = measure(item, depth + 1, budget)
        if budget < 0 then return -1 end
    end
    return budget
end

local function push(target, owner, set)
    local list = {}
    for _, definition in pairs(set) do list[#list + 1] = definition end
    table.sort(list, function(left, right) return left.id < right.id end)
    return TriggerClientEvent("open77:interactions:targets", target, {
        owner = owner,
        targets = list,
    })
end

local function pushAll(target)
    for owner, set in pairs(declarations) do push(target, owner, set) end
end

local function retract(owner)
    declarations[owner] = nil
    generations[owner] = nil
    TriggerClientEvent("open77:interactions:retract", -1, { owner = owner })
end

-- A declaring resource that stops or reloads takes its targets with it. The
-- client half cannot notice this on its own: a server-only job resource has no
-- client VM whose stop it could observe.
local function sweep()
    local now = Open77.time.monotonic()
    if now < nextSweep then return end
    nextSweep = now + 2.0
    for owner, generation in pairs(generations) do
        if GetResourceState(owner) ~= "running" or
            Open77.resource.generation(owner) ~= generation then
            retract(owner)
        end
    end
end

local function define(owner, generation, definitions)
    if not validName(owner, 64) then return false, "invalid_owner" end
    if type(definitions) ~= "table" then return false, "definitions_must_be_a_table" end
    -- One target or a list of them; a job resource declaring a single rule
    -- should not have to wrap it.
    if definitions.kind ~= nil then definitions = { definitions } end
    if #definitions < 1 or #definitions > MAX_TARGETS_PER_OWNER then
        return false, "invalid_target_count"
    end
    if measure(definitions, 0, MAX_DECLARATION_BYTES) < 0 then
        return false, "declaration_too_large"
    end

    local set = {}
    for index = 1, #definitions do
        local definition = definitions[index]
        if type(definition) ~= "table" then return false, "definition_must_be_a_table" end
        local id = definition.id
        if not validName(id, 64) then return false, "invalid_target_id" end
        if set[id] then return false, "duplicate_target_id" end
        -- The client re-validates every field through the same normaliser a
        -- hand-written interaction goes through, so this half deliberately does
        -- not second-guess the shape: it owns identity and fan-out, not schema.
        set[id] = definition
    end

    declarations[owner] = set
    generations[owner] = generation
    push(-1, owner, set)
    return true
end

exports("define", function(definitions)
    return define(GetInvokingResource(), GetInvokingResourceGeneration(), definitions)
end)

exports("undefine", function(id)
    local owner = GetInvokingResource()
    if not validName(owner, 64) then return false, "invalid_owner" end
    local set = declarations[owner]
    if not set then return false, "no_declaration" end
    if id == nil then
        retract(owner)
        return true
    end
    if not validName(id, 64) then return false, "invalid_target_id" end
    if set[id] == nil then return false, "target_not_found" end
    set[id] = nil
    if next(set) == nil then
        retract(owner)
        return true
    end
    push(-1, owner, set)
    return true
end)

exports("clear", function()
    local owner = GetInvokingResource()
    if not validName(owner, 64) then return false, "invalid_owner" end
    if declarations[owner] == nil then return false, "no_declaration" end
    retract(owner)
    return true
end)

exports("list", function()
    local owner = GetInvokingResource()
    local set = declarations[owner]
    if not set then return {} end
    local out = {}
    for id in pairs(set) do out[#out + 1] = id end
    table.sort(out)
    return out
end)

RegisterNetEvent("open77:interactions:sync", function()
    local player = tonumber(source)
    if player == nil or player <= 0 then return end
    pushAll(player)
end)

AddEventHandler("onPlayerConnected", function(playerId)
    local player = tonumber(playerId)
    if player == nil or player <= 0 then return end
    pushAll(player)
end)

AddEventHandler("onResourceStop", function(name)
    if name == GetCurrentResourceName() then
        for owner in pairs(declarations) do
            TriggerClientEvent("open77:interactions:retract", -1, { owner = owner })
        end
        declarations, generations = {}, {}
    elseif declarations[name] then
        retract(name)
    end
end)

CreateThread(function()
    while true do
        sweep()
        Wait(1000)
    end
end)
