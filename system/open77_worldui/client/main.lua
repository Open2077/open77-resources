-- POI facade: one call composes a 3D ground marker and a contextual prompt
-- into a single owned handle, and one call removes both.
--
-- The two halves live in different subsystems -- Open77.markers renders a real
-- REDengine worldEffect, open77_interactions renders a screen-projected card
-- driven by camera projection -- so composing them by hand means every caller
-- re-implements partial cleanup. Creation here is transactional: if the prompt
-- fails, the marker it already created is removed before returning.
--
-- Ownership comes from GetInvokingResource(), never from an argument: taking
-- an owner name as a normal Lua value would let any resource remove another's
-- POIs.

local pois = {}
local nextHandle = 1
local ownerGenerations = {}
local nextOwnerSweep = 0

-- Every POI is projected through this adapter's native marker ownership, whose
-- per-resource ceiling is 64. Keep the Lua service limit aligned so callers get
-- a precise `poi_limit` instead of an opaque native `quota_exceeded` failure.
local MAX_POIS = 64

local MARKER_STYLES = {
    interaction = true,
    objective = true,
    spawn = true,
    danger = true,
}

local function response(ok, values)
    values = values or {}
    values.ok = ok == true
    return values
end

local function finite(value)
    return type(value) == "number" and value == value and
        value > -math.huge and value < math.huge
end

local function validName(value, maximum)
    return type(value) == "string" and #value > 0 and #value <= maximum and
        value:match("^[%w_:%-%.]+$") ~= nil
end

local function vector(value)
    if type(value) ~= "table" or not finite(value.x) or not finite(value.y) or
        not finite(value.z) then
        return nil
    end
    return { x = value.x + 0.0, y = value.y + 0.0, z = value.z + 0.0 }
end

local function clamp(value, low, high, fallback)
    if not finite(value) then return fallback end
    return math.max(low, math.min(high, value))
end

local function removeOwner(owner)
    local removed = 0
    for handle, poi in pairs(pois) do
        if poi.owner == owner then
            if poi.markerId then Open77.markers.remove(poi.markerId) end
            if poi.promptHandle then
                Open77.exports.call("open77_interactions", "remove", poi.promptHandle)
            end
            pois[handle] = nil
            removed = removed + 1
        end
    end
    return removed
end

local function caller()
    local owner = GetInvokingResource()
    local generation = GetInvokingResourceGeneration()
    if not validName(owner, 64) or type(generation) ~= "number" then
        return nil, "export_call_required"
    end
    if ownerGenerations[owner] ~= nil and ownerGenerations[owner] ~= generation then
        removeOwner(owner)
    end
    ownerGenerations[owner] = generation
    return owner
end

local function sweepStoppedOwners()
    local now = Open77.time.monotonic()
    if now < nextOwnerSweep then return end
    nextOwnerSweep = now + 1.0
    for owner, generation in pairs(ownerGenerations) do
        if GetResourceState(owner) ~= "running" or
            Open77.resource.generation(owner) ~= generation then
            removeOwner(owner)
            ownerGenerations[owner] = nil
        end
    end
end

-- The interactions service is asynchronous. Calling it from an export means
-- awaiting inside the caller's coroutine, which the scheduler supports.
local function callInteractions(name, ...)
    local promise, reason = Open77.exports.call("open77_interactions", name, ...)
    if not promise then return nil, reason end
    local result, callError = promise:await()
    if not result or not result.ok then
        return nil, callError or (result and result.error) or "interaction_failed"
    end
    return result
end

local function create(definition)
    local owner, callerError = caller()
    if not owner then return response(false, { error = callerError }) end
    if type(definition) ~= "table" then
        return response(false, { error = "definition_must_be_a_table" })
    end

    local count = 0
    for _ in pairs(pois) do count = count + 1 end
    if count >= MAX_POIS then return response(false, { error = "poi_limit" }) end

    local position = vector(definition.position)
    if not position then return response(false, { error = "invalid_position" }) end
    if not validName(definition.id, 64) then
        return response(false, { error = "invalid_id" })
    end

    local style = definition.style or "objective"
    if not MARKER_STYLES[style] then
        return response(false, { error = "unknown_marker_style" })
    end

    -- Open77.markers clamps radius to 0.1..50 and maxDistance to 1..500; clamp
    -- here too so a caller gets a POI rather than an opaque native refusal.
    local radius = clamp(definition.radius, 0.1, 50.0, 1.5)
    local maxDistance = clamp(definition.maxDistance, 1.0, 500.0, 80.0)

    -- Lift the marker off the ground.
    --
    -- A ring is rendered as the marker mesh flattened to 0.04 m, so placed at
    -- exactly floor height it is co-planar with the floor: the entity spawns,
    -- the mesh scales, `rendered` reports true -- and nothing is visible,
    -- because it is inside the geometry. The research notes recommend the same
    -- small lift to avoid z-fighting.
    local groundOffset = finite(definition.groundOffset) and
        math.max(0.0, math.min(2.0, definition.groundOffset)) or 0.06
    local markerPosition = {
        x = position.x,
        y = position.y,
        z = position.z + groundOffset,
    }

    local markerId, markerError = Open77.markers.create({
        position = markerPosition,
        shape = definition.shape == "cylinder" and "cylinder" or "ring",
        style = style,
        radius = radius,
        maxDistance = maxDistance,
    })
    if not markerId then
        return response(false, { error = "marker_failed:" .. tostring(markerError) })
    end

    local handle = nextHandle
    nextHandle = nextHandle + 1

    local promptHandle
    local promptSpec
    if definition.label ~= nil then
        -- The prompt is anchored slightly above the ground so the card does not
        -- sit inside the ring it belongs to.
        promptSpec = {
            id = owner .. "_" .. definition.id,
            position = {
                x = position.x,
                y = position.y,
                z = position.z + (finite(definition.labelHeight) and definition.labelHeight or 1.0),
            },
            distance = clamp(definition.promptDistance, 0.5, 50.0, radius + 0.5),
            markerDistance = maxDistance,
            marker = definition.marker or "chevron",
            markerScale = 1.0,
            markerNearScale = 1.6,
            markerAnimated = definition.animated ~= false,
            focusRadius = clamp(definition.focusRadius, 0.05, 1.0, 0.35),
            requireLookAt = definition.requireLookAt == true,
            label = definition.label,
            description = definition.description,
            key = definition.key or "E",
            holdSeconds = clamp(definition.holdSeconds, 0, 10, 0),
            icon = definition.icon or "DIALOG",
            color = definition.color or "#00E5FF",
            event = definition.event,
        }
        local result, promptError = callInteractions("create", promptSpec)
        if not result then
            -- Transactional: never leave the marker behind when the prompt fails.
            Open77.markers.remove(markerId)
            return response(false, { error = "prompt_failed:" .. tostring(promptError) })
        end
        promptHandle = result.handle
    end

    pois[handle] = {
        owner = owner,
        id = definition.id,
        position = position,
        markerId = markerId,
        promptHandle = promptHandle,
        -- Kept so the prompt can be re-registered if the interactions service
        -- restarts underneath us; see republishPrompts().
        promptSpec = promptSpec,
    }
    return response(true, { handle = handle, id = definition.id })
end

local function remove(handle)
    local owner, callerError = caller()
    if not owner then return response(false, { error = callerError }) end
    handle = tonumber(handle)
    local poi = handle and pois[handle] or nil
    if not poi then return response(false, { error = "poi_not_found" }) end
    if poi.owner ~= owner then return response(false, { error = "not_owner" }) end

    if poi.markerId then Open77.markers.remove(poi.markerId) end
    if poi.promptHandle then
        callInteractions("remove", poi.promptHandle)
    end
    pois[handle] = nil
    return response(true)
end

local function list()
    local owner, callerError = caller()
    if not owner then return response(false, { error = callerError }) end
    local items = {}
    for handle, poi in pairs(pois) do
        if poi.owner == owner then
            items[#items + 1] = {
                handle = handle,
                id = poi.id,
                position = poi.position,
            }
        end
    end
    return response(true, { pois = items })
end

-- Diagnostic. `rendered` comes from the native marker registry, so it
-- separates "the Lua handle exists" from "the REDengine effect is actually
-- alive" -- from Lua the two failure modes look identical. It lives here
-- rather than in a gamemode because world.markers is this resource's
-- permission; a caller without it cannot read the registry at all.
local function dump()
    local owner, callerError = caller()
    if not owner then return response(false, { error = callerError }) end
    local markers, reason = Open77.markers.list()
    if not markers then
        return response(false, { error = tostring(reason) })
    end
    local items = {}
    for _, marker in ipairs(markers) do
        local position = marker.position or {}
        items[#items + 1] = {
            id = tostring(marker.id),
            owner = tostring(marker.owner),
            shape = tostring(marker.shape),
            style = tostring(marker.style),
            radius = tonumber(marker.radius) or 0,
            rendered = marker.rendered == true,
            x = tonumber(position.x) or 0,
            y = tonumber(position.y) or 0,
            z = tonumber(position.z) or 0,
        }
        Open77.log.info(("MARKER id=%s owner=%s %s/%s r=%.1f rendered=%s at %.1f,%.1f,%.1f"):format(
            items[#items].id, items[#items].owner, items[#items].shape,
            items[#items].style, items[#items].radius,
            tostring(items[#items].rendered),
            items[#items].x, items[#items].y, items[#items].z))
    end
    Open77.log.info(("MARKER total=%d requestedBy=%s"):format(#items, owner))
    return response(true, { markers = items })
end

-- open77_interactions declares reload_policy "reconnect", so ANY change to the
-- session's resource set restarts it -- and on restart it drops every
-- registered entry. Our markers survive (they belong to this resource's
-- generation) but the prompts silently vanish, leaving a ring on the ground
-- with no way to interact with it. Watch its generation and re-register.
local interactionsGeneration

local function republishPrompts()
    if GetResourceState("open77_interactions") ~= "running" then return end
    local generation = Open77.resource.generation("open77_interactions")
    if type(generation) ~= "number" then return end
    if interactionsGeneration == generation then return end

    local previous = interactionsGeneration
    interactionsGeneration = generation
    if previous == nil then return end -- First observation; nothing to restore.

    local restored, failed = 0, 0
    for _, poi in pairs(pois) do
        if poi.promptSpec ~= nil then
            local result = callInteractions("create", poi.promptSpec)
            if result then
                poi.promptHandle = result.handle
                restored = restored + 1
            else
                poi.promptHandle = nil
                failed = failed + 1
            end
        end
    end
    if restored > 0 or failed > 0 then
        Open77.log.info(("open77_interactions restarted (generation %s -> %s); prompts restored=%d failed=%d")
            :format(tostring(previous), tostring(generation), restored, failed))
    end
end

exports("create", create)
exports("remove", remove)
exports("list", list)
exports("dump", dump)

CreateThread(function()
    while true do
        sweepStoppedOwners()
        republishPrompts()
        Wait(1000)
    end
end)

AddEventHandler("onClientResourceStart", function(name)
    if name ~= GetCurrentResourceName() then return end
    Open77.log.info(("open77_worldui ready, generation %d"):format(
        Open77.resource.generation()))
end)

AddEventHandler("onClientResourceStop", function(name)
    if name == GetCurrentResourceName() then
        for handle in pairs(pois) do
            local poi = pois[handle]
            if poi.markerId then Open77.markers.remove(poi.markerId) end
        end
        pois, ownerGenerations, nextOwnerSweep = {}, {}, 0
    else
        removeOwner(name)
        ownerGenerations[name] = nil
    end
end)
