-- Proximity zones, polled with hysteresis.
--
-- Open77 has no native zone service (no entTriggerComponent can be created at
-- runtime from a script), so containment is polled. Three details make polling
-- behave rather than chatter:
--
--   * hysteresis. Camera projection and player transforms are sampled
--     independently, so a single hard boundary makes a zone flip enter/exit
--     repeatedly while the player stands still on the edge. The exit test runs
--     the same containment with the zone expanded outward by the hysteresis
--     band; the gap between the two is where neither event fires.
--   * a bounding volume per zone. One squared planar comparison rejects a zone
--     the player is nowhere near, before the real test runs. That is what keeps
--     a polygon affordable: a 32-vertex polygon the player is not standing in
--     costs about the same as a sphere.
--   * squared distances. No square root in the inner loop.
--
-- The containment maths itself is NOT here. It lives in the shared prelude
-- (scripting/lua/open77_zones.lua), published as Open77.zones.contains, and the
-- dedicated server runs those very bytes. That is deliberate and it is the
-- whole point of the feature: this file decides whether a prompt appears and
-- the server decides whether the shop sells, and two implementations that
-- disagree by a centimetre at the boundary would leave a place a player can
-- stand where only one of them is true.
--
-- This is therefore a LOCAL signal for presentation only. It is never proof:
-- the client owns this code and could report anything. Every rule that depends
-- on containment must be re-derived on the server -- Open77.zones.playersIn and
-- Open77.zones.containsPlayer exist so that re-derivation is one call against
-- the same definition, not a hand-rolled second opinion.

local zones = {}
local nextHandle = 1
local ownerGenerations = {}
local nextOwnerSweep = 0
local liveVertices = 0

local MAX_ZONES = 256
local POLL_NEAR_MS = 100    -- 10 Hz while any zone is close
local POLL_FAR_MS = 500     -- 2 Hz when everything is far away
local NEAR_MARGIN = 50.0    -- metres beyond a zone that still counts as "close"

-- The real ceiling is not the zone count, it is how many polygon edges have to
-- be walked on a tick where the player is standing inside them. A zone the
-- player is nowhere near is rejected by its bounding volume for about the cost
-- of a sphere, so 256 distant polygons are free; 256 overlapping 128-gons are
-- 5 ms, which is a visible hitch at 10 Hz. 4096 edges is the measured point
-- where the worst case stays under half a millisecond -- 128 zones of 32
-- vertices, or 256 of 16. Measured numbers are in wiki/zones.md.
local MAX_VERTICES = 4096

local DEG_TO_RAD = math.pi / 180.0

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

--- How many polygon edges this zone costs on a tick where it is not rejected.
-- Counted once at creation and held against the budget until the zone goes
-- away, because the poll loop must not have to work it out.
local function vertexCost(prepared)
    if prepared.shape == "poly" then return prepared.count end
    if prepared.shape == "combo" then
        local total = 0
        for index = 1, prepared.count do
            total = total + vertexCost(prepared.parts[index])
        end
        return total
    end
    return 0
end

local function forget(handle, zone)
    zones[handle] = nil
    liveVertices = liveVertices - zone.vertices
end

local function removeOwner(owner)
    local removed = 0
    for handle, zone in pairs(zones) do
        if zone.owner == owner then
            forget(handle, zone)
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

local function create(definition)
    local owner, callerError = caller()
    if not owner then return response(false, { error = callerError }) end
    if type(definition) ~= "table" then
        return response(false, { error = "definition_must_be_a_table" })
    end
    if not validName(definition.id, 64) then
        return response(false, { error = "invalid_id" })
    end

    -- One validator for every shape, and the same one the server uses. A zone
    -- that this refuses is a zone the server would refuse too, with the same
    -- token, which is the only way a creator can debug a definition once.
    local prepared, reason = Open77.zones.normalize(definition)
    if not prepared then return response(false, { error = reason }) end

    local count = 0
    for _ in pairs(zones) do count = count + 1 end
    if count >= MAX_ZONES then return response(false, { error = "zone_limit" }) end

    local vertices = vertexCost(prepared)
    if liveVertices + vertices > MAX_VERTICES then
        return response(false, { error = "vertex_budget" })
    end

    -- The hysteresis band. A supplied value is clamped; omitted, it scales with
    -- the zone so a big zone gets a proportionate band. `bounds.radius` is the
    -- planar reach of any shape, so a box and a polygon get the same treatment
    -- a sphere always had without the caller doing anything.
    local bounds = prepared.bounds
    local hysteresis = finite(definition.hysteresis) and
        math.max(0.05, math.min(10.0, definition.hysteresis)) or
        math.max(0.25, bounds.radius * 0.08)

    -- Bounds are stated in the zone's declared frame; an attached zone moves,
    -- so the poll loop needs the reach measured from the ANCHOR, which is the
    -- point that moves. Precomputed here, never in the loop.
    local dx, dy = bounds.x - prepared.anchorX, bounds.y - prepared.anchorY
    local reach = math.sqrt(dx * dx + dy * dy) + bounds.radius

    local handle = nextHandle
    nextHandle = nextHandle + 1
    liveVertices = liveVertices + vertices
    zones[handle] = {
        owner = owner,
        id = definition.id,
        handle = handle,
        prepared = prepared,
        vertices = vertices,
        hysteresis = hysteresis,
        reach = reach,
        nearSquared = (reach + NEAR_MARGIN) * (reach + NEAR_MARGIN),
        inside = false,
        -- Reused across ticks rather than rebuilt: the poll loop allocating one
        -- table per zone per tick is the kind of garbage that shows up as a
        -- collection pause rather than as a slow function.
        options = { grace = 0.0 },
        enterEvent = definition.enterEvent,
        exitEvent = definition.exitEvent,
    }
    return response(true, { handle = handle, id = definition.id, shape = prepared.shape })
end

local function owned(handle)
    local owner, callerError = caller()
    if not owner then return nil, callerError end
    handle = tonumber(handle)
    local zone = handle and zones[handle] or nil
    if not zone then return nil, "zone_not_found" end
    if zone.owner ~= owner then return nil, "not_owner" end
    return zone, nil, handle
end

local function remove(handle)
    local zone, reason, resolved = owned(handle)
    if not zone then return response(false, { error = reason }) end
    forget(resolved, zone)
    return response(true)
end

local function contains(handle)
    local zone, reason = owned(handle)
    if not zone then return response(false, { error = reason }) end
    return response(true, { inside = zone.inside, shape = zone.prepared.shape })
end

exports("create", create)
exports("remove", remove)
exports("contains", contains)

--- Where an attached zone's anchor is right now, and which way it faces.
-- The only impure part of the whole feature, and it is deliberately confined to
-- this function: the shared geometry never touches the world, it is handed the
-- answer. Returns nil when the entity is not resolvable this tick -- despawned,
-- not streamed in, player gone -- and the zone is then simply not tested, which
-- is the honest answer rather than testing it at a stale position.
local function resolveAnchor(zone)
    local attach = zone.prepared.attach
    local entity = attach.entity
    if entity == nil then
        local resolved = Open77.players.entity(attach.player)
        if type(resolved) ~= "number" then return nil end
        entity = resolved
    end

    local ox, oy, oz = attach.offsetX, attach.offsetY, attach.offsetZ
    if not attach.followHeading then
        local x, y, z = Open77.character.position(entity)
        if not finite(x) then return nil end
        return x + ox, y + oy, z + oz, nil
    end

    local state = Open77.character.state(entity)
    if type(state) ~= "table" or not state.attached or type(state.position) ~= "table" or
        not finite(state.yaw) then
        return nil
    end
    -- The offset is expressed in the zone's own frame and turns with it, so
    -- "two metres in front of the NPC" stays in front however the NPC is
    -- facing. Rotating by the same delta the shape is rotated by keeps the two
    -- consistent with each other whatever the engine's yaw convention turns out
    -- to be, which is why they are computed from one angle here.
    local delta = (state.yaw - zone.prepared.anchorRotation) * DEG_TO_RAD
    if delta ~= 0.0 then
        local c, s = math.cos(delta), math.sin(delta)
        ox, oy = ox * c - oy * s, ox * s + oy * c
    end
    return state.position.x + ox, state.position.y + oy, state.position.z + oz, state.yaw
end

CreateThread(function()
    -- Hoisted out of the loop: one table reused for the query point, and the
    -- two namespaces resolved once instead of on every zone of every tick.
    local point = { x = 0.0, y = 0.0, z = 0.0 }
    local origin = { x = 0.0, y = 0.0, z = 0.0 }
    local test = Open77.zones.contains

    while true do
        sweepStoppedOwners()

        local anyNear = false
        local state = Open77.character.state()
        if state and state.attached and state.position then
            local px, py, pz = state.position.x, state.position.y, state.position.z
            point.x, point.y, point.z = px, py, pz

            for _, zone in pairs(zones) do
                local prepared = zone.prepared
                local options = zone.options
                local cx, cy = prepared.anchorX, prepared.anchorY
                local anchored = true

                if prepared.attach ~= nil then
                    local ax, ay, az, heading = resolveAnchor(zone)
                    if ax == nil then
                        anchored = false
                    else
                        origin.x, origin.y, origin.z = ax, ay, az
                        options.origin = origin
                        options.rotation = heading
                        cx, cy = ax, ay
                    end
                end

                -- An anchor that will not resolve contains nobody, and that is
                -- the safe reading rather than the cautious one. The entity is
                -- despawned, gone, or not streamed in -- and a player standing
                -- inside a zone attached to it would have kept it streamed. So
                -- holding the last verdict cannot be right, and it strands a
                -- caller waiting on `exit` forever the day its NPC dies.
                local hit = false
                if anchored then
                    -- The exit test is the enter test with the zone expanded
                    -- outward by the hysteresis band. One rule, every shape:
                    -- a box and a polygon get the behaviour the sphere always
                    -- had without anybody writing a second boundary.
                    local grace = zone.inside and zone.hysteresis or 0.0
                    options.grace = grace

                    local dx, dy = px - cx, py - cy
                    local planar = dx * dx + dy * dy
                    if planar <= zone.nearSquared then anyNear = true end

                    -- The bounding volume is a necessary condition: outside it,
                    -- no shape can contain the point, so the real test -- which
                    -- for a polygon is a walk of every edge -- never runs for a
                    -- zone the player is not near.
                    local hit = false
                    local limit = zone.reach + grace
                    if planar <= limit * limit then
                        hit = test(prepared, point, options) == true
                    end

                    if hit ~= zone.inside then
                        zone.inside = hit
                        local event = hit and zone.enterEvent or zone.exitEvent
                        if event then
                            TriggerEvent(event, { id = zone.id, handle = zone.handle })
                        end
                    end
                end
            end
        end

        Wait(anyNear and POLL_NEAR_MS or POLL_FAR_MS)
    end
end)

AddEventHandler("onClientResourceStop", function(name)
    if name == GetCurrentResourceName() then
        zones, ownerGenerations, nextOwnerSweep, liveVertices = {}, {}, 0, 0
    else
        removeOwner(name)
        ownerGenerations[name] = nil
    end
end)
