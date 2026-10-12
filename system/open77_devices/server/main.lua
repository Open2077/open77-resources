-- =============================================================================
-- open77_devices -- server/main.lua
-- =============================================================================
-- Declare once, applied by every client.
--
-- `Open77.world.setDeviceInteractionEnabled` is a client capability: the policy
-- has to be held on the machine that renders the prompt. Doing the fan-out from
-- a gamemode's own client script means every gamemode reimplements the same
-- thing and gets late joins wrong, so this half owns the declaration and the
-- wire, exactly as `open77_devices`' neighbour `open77_interactions` does for
-- targets.
--
-- Nothing here is authority over a device. A device policy is presentation
-- policy: it decides whether a prompt is drawn and whether the vanilla use is
-- refused on that client. Any rule the policy seems to enforce -- who may use
-- the ATM, what the vending machine costs -- must be re-derived by the server
-- handler that receives the intent your own prompt produces.
-- =============================================================================

local MAX_POLICIES_PER_OWNER = 128
local USE_REPORTS_PER_SECOND = 10

local declarations = {}   -- [owner] = { [key] = { target, enabled, bucket } }
local reports = {}        -- [playerId] = { windowSec, count }

local function validTarget(value)
    if type(value) == "number" then
        return value % 1 == 0 and value > 0
    end
    if type(value) ~= "string" then return false end
    if #value == 0 or #value > 128 then return false end
    -- A class name, or a decimal / 0x engine entity id. The client re-validates
    -- through the same native the caller would have used directly.
    return value:match("^[%w_]+$") ~= nil
end

local function keyOf(target)
    return type(target) == "number" and ("#" .. tostring(target)) or tostring(target)
end

local function rows(owner)
    local out = {}
    for _, entry in pairs(declarations[owner] or {}) do out[#out + 1] = entry end
    table.sort(out, function(left, right) return keyOf(left.target) < keyOf(right.target) end)
    return out
end

local function push(target, owner)
    return TriggerClientEvent("open77:devices:policy", target, {
        owner = owner,
        policies = rows(owner),
    })
end

-- A bucket-scoped declaration reaches only the players in that bucket. Sending
-- it to everybody and letting clients filter would hand every client the whole
-- server's device policy, which is both wasteful and a leak of what other
-- worlds are doing.
local function pushScoped(owner)
    local set = declarations[owner]
    if set == nil then return true end
    local buckets = {}
    local global = false
    for _, entry in pairs(set) do
        if entry.bucket == nil then global = true else buckets[entry.bucket] = true end
    end
    if global or next(buckets) == nil then
        return push(-1, owner)
    end
    for bucket in pairs(buckets) do
        for _, playerId in ipairs(Open77.players.inBucket(bucket) or {}) do
            push(playerId, owner)
        end
    end
    return true
end

local function pushAll(playerId)
    for owner in pairs(declarations) do push(playerId, owner) end
end

local function retract(owner)
    declarations[owner] = nil
    TriggerClientEvent("open77:devices:retract", -1, { owner = owner })
end

local function declare(owner, target, enabled, options)
    if type(owner) ~= "string" or #owner == 0 then return false, "invalid_owner" end
    if not validTarget(target) then return false, "invalid_device_target" end

    local bucket = nil
    if type(options) == "table" and options.bucket ~= nil then
        bucket = tonumber(options.bucket)
        if bucket == nil or bucket % 1 ~= 0 or bucket < 0 then return false, "invalid_bucket" end
    end

    local set = declarations[owner]
    if set == nil then set = {}; declarations[owner] = set end
    local key = keyOf(target)
    if set[key] == nil and MAX_POLICIES_PER_OWNER <= 0 then return false, "policy_limit" end

    local count = 0
    for _ in pairs(set) do count = count + 1 end
    if set[key] == nil and count >= MAX_POLICIES_PER_OWNER then return false, "policy_limit" end

    if enabled == nil then
        if set[key] == nil then return false, "no_declaration" end
        set[key] = nil
        if next(set) == nil then
            retract(owner)
            return true
        end
    else
        set[key] = { target = target, enabled = enabled and true or false, bucket = bucket }
    end
    pushScoped(owner)
    return true
end

-- ---------------------------------------------------------------------------
-- Exports
-- ---------------------------------------------------------------------------
exports("disable", function(target, options)
    return declare(GetInvokingResource(), target, false, options)
end)

exports("enable", function(target, options)
    return declare(GetInvokingResource(), target, true, options)
end)

-- Drops this resource's declaration for one target, or all of them.
exports("clear", function(target)
    local owner = GetInvokingResource()
    if target == nil then
        if declarations[owner] == nil then return false, "no_declaration" end
        retract(owner)
        return true
    end
    return declare(owner, target, nil, nil)
end)

exports("list", function()
    return rows(GetInvokingResource())
end)

-- ---------------------------------------------------------------------------
-- Late join, bucket change, and the declaring resource going away
-- ---------------------------------------------------------------------------
RegisterNetEvent("open77:devices:sync", function()
    local player = tonumber(source)
    if player == nil or player <= 0 then return end
    pushAll(player)
end)

AddEventHandler("onPlayerConnected", function(playerId)
    local player = tonumber(playerId)
    if player == nil or player <= 0 then return end
    pushAll(player)
end)

AddEventHandler("onPlayerBucketChange", function(playerId)
    local player = tonumber(playerId)
    if player == nil or player <= 0 then return end
    -- His world changed, so the set of policies that apply to him did too. The
    -- client replaces per owner, so re-pushing is enough: nothing has to be
    -- retracted first.
    pushAll(player)
end)

AddEventHandler("onResourceStop", function(name)
    if name == GetCurrentResourceName() then
        for owner in pairs(declarations) do
            TriggerClientEvent("open77:devices:retract", -1, { owner = owner })
        end
        declarations = {}
        return
    end
    -- A declaring resource that stops takes its policies with it. A device left
    -- un-interactable by a resource that no longer exists is a vending machine
    -- nobody can use again.
    if declarations[name] ~= nil then retract(name) end
end)

-- ---------------------------------------------------------------------------
-- The use report
-- ---------------------------------------------------------------------------
-- `open77:deviceUsed` is a client-side observation, so what arrives here is a
-- CLAIM by that client and nothing more: the entity, the class and the choice
-- are whatever his machine said. It is re-published host-wide for a gamemode
-- that wants to open its own shop when somebody presses a vending machine, and
-- that gamemode must still validate distance, bucket and eligibility itself.
RegisterNetEvent("open77:devices:used", function(payload)
    local player = tonumber(source)
    if player == nil or player <= 0 then return end
    if type(payload) ~= "table" then return end

    local second = math.floor(Open77.time.monotonic())
    local window = reports[player]
    if window == nil or window.second ~= second then
        window = { second = second, count = 0 }
        reports[player] = window
    end
    window.count = window.count + 1
    if window.count > USE_REPORTS_PER_SECOND then return end

    local entity = tonumber(payload.engineEntity)
    if entity == nil or entity % 1 ~= 0 or entity <= 0 then return end
    local className = tostring(payload.className or "")
    local choice = tostring(payload.choice or "")
    if #className > 128 or #choice > 128 then return end

    TriggerEvent("open77_devices:used", player, entity, className, choice,
        payload.allowed == true)
end)

AddEventHandler("onPlayerDisconnected", function(playerId)
    local player = tonumber(playerId)
    if player ~= nil then reports[player] = nil end
end)
