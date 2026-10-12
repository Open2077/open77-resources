-- =============================================================================
-- open77_devices -- client/main.lua
-- =============================================================================
-- Holds the device-interaction claim for the whole server-declared policy, and
-- reports every vanilla device use back.
--
-- The plugin's policy store is per *client resource*, so every server owner's
-- declarations collapse into one claim owned by this package. That is on
-- purpose and it has one consequence worth knowing: if this resource stops,
-- every server-declared policy lifts at once and every vanilla prompt comes
-- back. That is the correct failure -- a device nobody can ever use again is
-- the state this design refuses to allow -- but it means a gamemode must not
-- treat a disabled device as a security boundary. It is presentation.
-- =============================================================================

local RESOURCE = GetCurrentResourceName()

local applied = {}       -- [key] = target, everything WE have set on the plugin
local byOwner = {}       -- [owner] = { [key] = target }

local function available()
    return Open77 ~= nil and Open77.world ~= nil
        and type(Open77.world.setDeviceInteractionEnabled) == "function"
end

local function keyOf(target)
    return type(target) == "number" and ("#" .. tostring(target)) or tostring(target)
end

-- Everything this resource claimed, and nothing else. The plugin already scopes
-- a claim to its owning resource, so this table is not what makes the release
-- safe -- it is what makes it *complete* when only one owner is retracted.
local function drop(key, target)
    if applied[key] == nil then return end
    applied[key] = nil
    local ok, reason = Open77.world.clearDeviceInteraction(target)
    if not ok then
        Open77.log.warn("devices: clear refused for " .. key .. " (" .. tostring(reason) .. ")")
    end
end

local function apply(owner, policies)
    local previous = byOwner[owner] or {}
    local current = {}

    for _, policy in ipairs(policies or {}) do
        local target = policy.target
        if type(target) == "string" or type(target) == "number" then
            local key = keyOf(target)
            local ok, reason = Open77.world.setDeviceInteractionEnabled(target, policy.enabled == true)
            if ok then
                applied[key] = target
                current[key] = target
            else
                Open77.log.warn(
                    "devices: policy refused for " .. key .. " (" .. tostring(reason) .. ")")
            end
        end
    end

    -- Anything this owner used to declare and no longer does.
    for key, target in pairs(previous) do
        if current[key] == nil then
            local claimedByAnother = false
            for otherOwner, set in pairs(byOwner) do
                if otherOwner ~= owner and set[key] ~= nil then claimedByAnother = true end
            end
            if not claimedByAnother then drop(key, target) end
        end
    end

    byOwner[owner] = current
end

local function retract(owner)
    local set = byOwner[owner]
    if set == nil then return end
    byOwner[owner] = nil
    for key, target in pairs(set) do
        local claimedByAnother = false
        for _, other in pairs(byOwner) do
            if other[key] ~= nil then claimedByAnother = true end
        end
        if not claimedByAnother then drop(key, target) end
    end
end

RegisterNetEvent("open77:devices:policy", function(payload)
    if not available() then return end
    if type(payload) ~= "table" then return end
    local owner = tostring(payload.owner or "")
    if owner == "" then return end
    apply(owner, payload.policies)
end)

RegisterNetEvent("open77:devices:retract", function(payload)
    if type(payload) ~= "table" then return end
    retract(tostring(payload.owner or ""))
end)

-- The plugin emits this into every client resource on every use of a vanilla
-- device prompt, allowed or refused. Forwarding it lets a gamemode open its own
-- shop from the server when somebody presses a vending machine; the server half
-- rate-limits it and re-publishes it as a CLAIM, never as authority.
AddEventHandler("open77:deviceUsed", function(engineEntity, className, choice, allowed)
    TriggerServerEvent("open77:devices:used", {
        engineEntity = tonumber(engineEntity),
        className = className,
        choice = choice,
        allowed = allowed == "true" or allowed == true,
    })
end)

AddEventHandler("onClientResourceStart", function(name)
    if name ~= RESOURCE then return end
    if not available() then
        Open77.log.error(
            "devices: Open77.world.setDeviceInteractionEnabled is absent on this client build -- " ..
            "a server-declared device policy cannot be applied. Rebuild the plugin.")
        return
    end
    TriggerServerEvent("open77:devices:sync")
end)

AddEventHandler("onClientResourceStop", function(name)
    if name ~= RESOURCE then return end
    -- The host drops every claim a stopping resource holds, on every path
    -- including a crash. This is the courteous case, not the safety net.
    for key, target in pairs(applied) do drop(key, target) end
    applied, byOwner = {}, {}
end)
