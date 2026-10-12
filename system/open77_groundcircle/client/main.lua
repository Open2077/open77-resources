-- Ground circles drawn on the HUD instead of in the world.
--
-- Open77.markers spawns a real REDengine entity carrying a mesh. That path
-- depends on shipped depot assets (an .ent, a .mesh and a material template)
-- and, when any link of that chain fails to produce pixels, the native
-- registry still reports the marker as rendered -- so a caller cannot tell a
-- drawn ring from an invisible one. This resource needs no game asset at all:
-- it samples points on the world-space circle, projects each one with
-- Open77.camera.project, and strokes the result as an SVG polyline on a
-- transparent surface. What the player sees is therefore exactly what this
-- file computed, with no engine-side render path left to fail silently.
--
-- The trade-off is honest and worth stating: this is a screen overlay, so it
-- is not occluded by walls, does not receive light, and does not exist for any
-- other player. It is a diagnostic and a fallback, not a replacement for a
-- world marker. It is also sampled on the LUA TICK, not per frame, so the ring
-- trails the view under a fast camera whip -- see the note on Open77.anchors
-- below, which explains at length why that cannot be fixed by anchoring.
--
-- Ownership comes from GetInvokingResource(), never from an argument: taking
-- an owner name as a normal Lua value would let any resource remove another's
-- circles.
--
-- ---------------------------------------------------------------------------
-- DROP-IN COMPATIBILITY WITH open77_worldui
-- ---------------------------------------------------------------------------
--
-- `create` reads the same field names open77_worldui.create reads -- id,
-- position, radius, maxDistance, style, groundOffset, color -- and IGNORES the
-- prompt half of that definition (label, description, key, holdSeconds, icon,
-- event, shape) instead of rejecting it. That is deliberate and it is the
-- whole enabling story: the identical definition table can be handed to either
-- resource, so switching a caller over is one line and no other edit.
--
-- To draw pursuit's ready-up ring on the HUD, add ONE line to
-- resources/gamemodes/pursuit/client/main.lua, in build(), directly after the existing
-- open77_worldui create:
--
--     callExport("open77_groundcircle", "create", {
--         id = ready.id, position = readyUpPosition(), radius = ready.radius,
--         style = ready.style, maxDistance = ready.maxDistance,
--         color = ready.color })
--
-- ...or, shorter and exactly equivalent, reuse the table already being built
-- and only change the resource name. Adding the call rather than replacing it
-- is preferable while the native marker is still under repair: both are then
-- drawn, and seeing two rings is the unambiguous signal that the native path
-- came back and this line can be deleted.
--
-- The prerequisite is that this resource is in the server's resource set. Add
-- it to that server's resources.load list:
--
--     "load": [ ..., "open77_groundcircle" ]
--
-- ---------------------------------------------------------------------------
-- WHY NOT Open77.anchors
-- ---------------------------------------------------------------------------
--
-- Open77.anchors exists precisely to kill the lag this file has: it projects a
-- registered world point on every game frame and pushes the result straight to
-- the page, instead of on a Lua timer. Nameplates and interaction prompts were
-- both moved onto it. The obvious next thought is to move the circle too --
-- anchor the CENTRE, send the radius, and let the page draw the ellipse. It
-- does not work, and the reasons are worth writing down so nobody has to
-- rediscover them:
--
--   1. An anchor reports x, y, depth, distance and onScreen. It does NOT report
--      the camera basis or the field of view. A perspective projection maps a
--      ground circle to an ELLIPSE whose axes and orientation depend on the
--      camera's pitch and roll -- from one screen point plus a world radius the
--      page cannot recover any of that. A ground circle at eye level is a
--      near-degenerate sliver; the same circle from above is nearly round. One
--      anchor cannot tell those apart.
--
--   2. Three anchors could, approximately: the centre and two perpendicular rim
--      points give a pair of conjugate semi-diameters, and a bezier ellipse
--      through conjugate diameters is exact under an AFFINE map. But projection
--      is not affine, it is projective, and the error is of order r/d -- the
--      circle's radius over its distance. That is the killer. The ready-up ring
--      is r = 2 m; the player is asked to WALK INTO IT. At 3 m the near rim is
--      1 m away and the far rim 5 m, a 5:1 depth ratio, so a single uniform
--      scale is wrong by 400% across the shape. At 20 m it is still ~20%. Only
--      past ~60 m does the approximation become good -- and at 60 m the ring is
--      a few pixels wide and nobody could tell either way. The approximation is
--      accurate exactly where the circle does not matter and worst exactly
--      where the player needs it.
--
--   3. Standing INSIDE the circle -- the state the whole ready-up interaction
--      is built around -- the centre is under the player's feet and behind the
--      camera plane. Its anchor stops reporting, so a centre-plus-radius scheme
--      draws nothing at the one moment it is most needed. Per-point projection
--      handles this natively: the points behind the plane are dropped and the
--      forward arc is still stroked, split into runs.
--
--   4. Anchoring point-by-point is out on quota alone. The limits are 32 per
--      resource and 128 in total; a single 48-segment ring would exceed the
--      per-resource quota by itself, and two would exhaust the global pool that
--      nameplates and interaction prompts depend on.
--
-- CONCLUSION: keep per-point projection. The cost is accepted knowingly -- the
-- ring is a tick behind the camera and will swim under a fast whip, exactly as
-- the nameplates used to. That is tolerable here and was not there: a plate is
-- glued to a moving head at head height where a few pixels of slip reads as
-- broken, whereas this is a decal on a fixed patch of ground, and the gate it
-- exists to satisfy asks whether a ring is ON SCREEN, not whether it is glued.
--
-- There IS one hybrid that would help and is deliberately NOT implemented: one
-- centre anchor per circle, used only to translate the whole Lua-projected ring
-- so its centre lands on the anchor's fresh position. Under pure camera
-- rotation the projected shape moves almost rigidly, so correcting only the
-- translation removes most of the visible swim, costs one anchor per circle
-- (six at most, well inside the quota) and needs no field of view. It is not
-- here because it is a first-order correction that degrades precisely for a
-- ring large on screen -- the close-range case again -- and because adding an
-- untested dependency to an untested fallback is how a fallback turns out to be
-- broken on the day it is needed. Revisit once C1 is closed.

local circles = {}
local nextHandle = 1
local ownerGenerations = {}
local nextOwnerSweep = 0

-- A world transition invalidates every world coordinate this resource holds.
-- There is no world-EXIT event on the client host -- `open77:worldReady` is the
-- only world lifecycle signal a resource gets -- so circles are stamped with an
-- epoch and the sweep drops the ones older than the current one. Stamping
-- rather than clearing outright matters because TriggerEvent SCHEDULES its
-- handlers: a caller that (correctly) re-creates its circles from its own
-- open77:worldReady handler may run before or after this one, and a blind clear
-- would delete the circles it just made. A circle created after the epoch
-- advanced already carries the new epoch and survives either ordering.
local worldEpoch = 1

local page
local ready = false

-- Native rings.
--
-- Everything below about projection budgets, payload node counts and dropped
-- frames describes the Lua path, and all of it exists because the ring is
-- sampled on a Lua tick and shipped to a page. That path has two costs the file
-- already documents at length: it trails the view under a fast camera whip, and
-- one over-budget tick can freeze the last frame on screen permanently.
--
-- `Open77.anchors.create{ render = "ring" }` moves the whole thing into the
-- plugin: the same per-point projection, on the game thread, in the frame that
-- presents it, drawn as a polyline with no page, no payload and no encoder to
-- overrun. The reasoning for keeping per-point projection is unchanged -- it is
-- written out above and the plugin implements exactly it, camera-plane split
-- included.
--
-- `ringSupport` is nil until the first circle settles it, so a client without
-- the native styles keeps the page path rather than showing nothing.
local ringSupport = nil
local ringAnchors = {}

local MAX_CIRCLES = 32

-- Frame pacing. Each sampled point costs one native round trip, so the cost of
-- a frame is the total point count, not the circle count. 30 Hz is smooth
-- enough for a ground decal that only moves when the camera does, and halves
-- that cost against the 60 Hz the interaction cards run at.
local FRAME_MS = 33

-- The real ceiling is not CPU, it is the host's event encoder.
--
-- `kMaximumEventValues` in scripting/src/ResourceHost.cpp is 1024, and
-- `ReadValue` counts EVERY node: a table costs one, and each of its entries
-- costs one for the key plus the cost of the value. A point is two numbers held
-- as array elements, so it costs four. Overshooting does not truncate --
-- EncodeLuaJson fails, page:send answers `false, "invalid_webui_event_payload"`
-- and the whole frame is refused -- and a refused frame leaves the last one on
-- screen, which at 30 Hz is indistinguishable from a frozen overlay. That is
-- the exact failure mode this resource exists to replace, so the budget is
-- computed rather than guessed, checked before every send, and reported in the
-- log at startup. `payloadNodes` below is the arithmetic, and
-- `worstCaseNodes()` proves the constants leave room.
local PAYLOAD_NODE_CAP = 1024

-- Trim at this rather than at the cap. The gap absorbs any future field added
-- to a circle without turning a cosmetic change into a blank overlay.
local PAYLOAD_NODE_CEILING = 900

local PROJECTION_BUDGET = 96
local MAX_RENDERED = 6

-- Segment counts are chosen per circle from its apparent size. A 48-segment
-- ring seen from 60 m is finer than the display can resolve and still costs 48
-- projections, so far circles get coarser sampling and no one can tell.
local MIN_SEGMENTS = 12
local MAX_SEGMENTS = 32

-- A point whose depth is at or behind the camera plane projects to garbage:
-- the perspective divide flips its sign and the polyline whips across the
-- screen. Such points are dropped and the ring is split into runs instead.
local MIN_DEPTH = 0.15

-- Projected coordinates are normalised, but a point barely in front of the
-- camera can still land thousands of screens away. Clamping keeps the path
-- data small without changing anything the player can see.
local COORD_LIMIT = 6.0

-- A ring can cross the viewport without a single SAMPLED point landing in it:
-- picture standing at the edge of a large circle, where the near arc is below
-- the screen and the far arc above it, and the two visible chords cross the
-- middle. `projected.onScreen` is a per-POINT test and answers false for every
-- one of them, so trusting it drops the circle at exactly the wrong moment. The
-- test used instead is a bounding-box overlap over the whole run, which is
-- conservative in the safe direction: it can keep a circle whose stroke happens
-- to miss, and that costs one empty <path>.
local function overlapsViewport(minX, minY, maxX, maxY)
    return minX <= 1.0 and maxX >= 0.0 and minY <= 1.0 and maxY >= 0.0
end

-- Ring accent per style. These are the OPEN//77 signal tokens, kept in step
-- with the mirrored `web/open77-ui.css` in the other resources: --op77-accent,
-- --op77-warn, --op77-ok and --op77-signal. The old `objective` yellow
-- (#FFDA26) was the game's own HUD colour, which the design system rules out.
local STYLE_COLORS = {
    interaction = "#22D8E2",
    objective = "#F5C95C",
    spawn = "#4FE3A9",
    danger = "#FF5964",
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

local function color(value, fallback)
    if type(value) == "string" and value:match("^#%x%x%x%x%x%x$") then return value end
    return fallback
end

local function removeOwner(owner)
    local removed = 0
    for handle, circle in pairs(circles) do
        if circle.owner == owner then
            circles[handle] = nil
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
    -- A restarted owner is a different owner: its old handles are unreachable
    -- from the new generation, so drop them rather than leak them.
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
    -- Circles authored against a previous world. See `worldEpoch`.
    local stale = 0
    for handle, circle in pairs(circles) do
        if circle.epoch ~= worldEpoch then
            circles[handle] = nil
            stale = stale + 1
        end
    end
    if stale > 0 then
        Open77.log.info(("open77_groundcircle: dropped %d circle(s) from a previous world")
            :format(stale))
    end
end

local function create(definition)
    local owner, callerError = caller()
    if not owner then return response(false, { error = callerError }) end
    if type(definition) ~= "table" then
        return response(false, { error = "definition_must_be_a_table" })
    end

    local count = 0
    for _ in pairs(circles) do count = count + 1 end
    if count >= MAX_CIRCLES then return response(false, { error = "circle_limit" }) end

    local position = vector(definition.position)
    if not position then return response(false, { error = "invalid_position" }) end
    if definition.id ~= nil and not validName(definition.id, 64) then
        return response(false, { error = "invalid_id" })
    end

    local style = definition.style
    if style ~= nil and STYLE_COLORS[style] == nil then
        return response(false, { error = "unknown_style" })
    end

    local handle = nextHandle
    nextHandle = nextHandle + 1
    circles[handle] = {
        owner = owner,
        epoch = worldEpoch,
        id = definition.id or ("circle_" .. handle),
        position = position,
        -- Same bounds as Open77.markers so a caller can swap one backend for
        -- the other without rediscovering the limits.
        radius = clamp(definition.radius, 0.1, 50.0, 1.5),
        maxDistance = clamp(definition.maxDistance, 1.0, 500.0, 80.0),
        -- Lifted off the floor by default. A circle stroked at exactly ground
        -- height projects onto the surface it sits on and reads as a smear
        -- when the camera is near eye level.
        groundOffset = clamp(definition.groundOffset, 0.0, 2.0, 0.05),
        color = color(definition.color, STYLE_COLORS[style or "objective"]),
        width = clamp(definition.width, 0.5, 8.0, 2.0),
        opacity = clamp(definition.opacity, 0.05, 1.0, 0.85),
        fill = clamp(definition.fill, 0.0, 0.6, 0.0),
        visible = definition.visible ~= false,
    }
        return response(true, { handle = handle, id = circles[handle].id })
end

local function remove(handle)
    local owner, callerError = caller()
    if not owner then return response(false, { error = callerError }) end
    handle = tonumber(handle)
    local circle = handle and circles[handle] or nil
    if not circle then return response(false, { error = "circle_not_found" }) end
    if circle.owner ~= owner then return response(false, { error = "not_owner" }) end
    circles[handle] = nil
    return response(true)
end

-- Drop everything this caller owns, in one call. Symmetric with
-- `Open77.anchors.clear()`, and the honest way for a caller to rebuild on
-- `open77:worldReady` without tracking every handle it ever made.
local function clear()
    local owner, callerError = caller()
    if not owner then return response(false, { error = callerError }) end
    return response(true, { removed = removeOwner(owner) })
end

local function list()
    local owner, callerError = caller()
    if not owner then return response(false, { error = callerError }) end
    local items = {}
    for handle, circle in pairs(circles) do
        if circle.owner == owner then
            items[#items + 1] = {
                handle = handle,
                id = circle.id,
                position = circle.position,
                radius = circle.radius,
                visible = circle.visible,
            }
        end
    end
    return response(true, { circles = items })
end

local function distance(left, right)
    local x, y, z = left.x - right.x, left.y - right.y, left.z - right.z
    return math.sqrt(x * x + y * y + z * z)
end

local function releaseRing(handle)
    local id = ringAnchors[handle]
    if not id then return end
    ringAnchors[handle] = nil
    Open77.anchors.remove(id)
end

-- Reconciles the circle table against the plugin's anchor registry. Called on
-- the same tick as the sweep, because that is when a circle can appear, expire
-- with its owner, or fall out of the current world epoch -- and none of those
-- has anything to do with where the ring is on screen, which the plugin now
-- owns outright.
local function syncRings()
    if ringSupport == false or type(Open77.anchors) ~= "table" then return end

    for handle in pairs(ringAnchors) do
        local circle = circles[handle]
        if not circle or circle.epoch ~= worldEpoch then releaseRing(handle) end
    end

    for handle, circle in pairs(circles) do
        if circle.epoch == worldEpoch and not ringAnchors[handle] then
            -- Opacity rides in the colour's alpha byte rather than as a field of
            -- its own: the drawer takes one packed colour per stroke, and a
            -- separate opacity would be a second way to say the same thing.
            local accent = circle.color ..
                string.format("%02X", math.floor(circle.opacity * 255 + 0.5))
            local id, reason = Open77.anchors.create({
                render = "ring",
                position = circle.position,
                tag = "circle." .. tostring(handle),
                maxDistance = circle.maxDistance,
                visible = circle.visible,
                presentation = {
                    accent = accent,
                    thickness = circle.width,
                    radius = circle.radius,
                    groundOffset = circle.groundOffset,
                },
            })
            if id then
                ringSupport = true
                ringAnchors[handle] = tostring(id)
            elseif ringSupport == nil then
                -- One probe, once. There is no capability query to ask first,
                -- and retrying every tick on an old client would be a log flood.
                ringSupport = false
                Open77.log.warn("open77_groundcircle: native ring unavailable (" ..
                    tostring(reason) .. "); falling back to the Lua projection loop")
                return
            else
                -- Quota pressure is transient; the next tick tries again.
                return
            end
        end
    end
end

local function segmentsFor(radius, viewDistance)
    -- Small-angle apparent size: the arc a metre of radius subtends falls off
    -- as 1/distance. The factor 6 puts a 2 m circle at full detail out to
    -- roughly 12 m and at the floor by 60 m.
    local apparent = radius / math.max(1.0, viewDistance)
    local segments = math.floor(MAX_SEGMENTS * math.min(1.0, apparent * 6.0))
    return math.max(MIN_SEGMENTS, math.min(MAX_SEGMENTS, segments))
end

-- Projects one circle into a list of screen-space runs. A run is a flat array
-- of normalised x, y pairs. There is more than one run whenever the ring
-- crosses the camera plane, which is the common case while standing inside it.
local function projectCircle(circle, segments)
    local runs = {}
    local current
    local z = circle.position.z + circle.groundOffset
    local minX, minY = math.huge, math.huge
    local maxX, maxY = -math.huge, -math.huge
    -- Sample one extra step so the ring closes back onto its first point.
    for index = 0, segments do
        local angle = (index % segments) * (2.0 * math.pi / segments)
        local projected = Open77.camera.project({
            x = circle.position.x + math.cos(angle) * circle.radius,
            y = circle.position.y + math.sin(angle) * circle.radius,
            z = z,
        })
        -- project() answers `nil, reason` when the camera is unavailable --
        -- during a load screen, for instance. Treat it as a break in the ring
        -- rather than an error: the next frame usually has a camera again.
        local usable = projected ~= nil and finite(projected.depth) and
            projected.depth > MIN_DEPTH and finite(projected.x) and finite(projected.y)
        if usable then
            local x = math.max(-COORD_LIMIT, math.min(COORD_LIMIT, projected.x))
            local y = math.max(-COORD_LIMIT, math.min(COORD_LIMIT, projected.y))
            if x < minX then minX = x end
            if x > maxX then maxX = x end
            if y < minY then minY = y end
            if y > maxY then maxY = y end
            current = current or {}
            current[#current + 1] = math.floor(x * 10000) / 10000
            current[#current + 1] = math.floor(y * 10000) / 10000
        elseif current then
            if #current >= 4 then runs[#runs + 1] = current end
            current = nil
        end
    end
    if current and #current >= 4 then runs[#runs + 1] = current end
    -- Only a ring sampled without a single break is a closed shape; anything
    -- else must stay an open stroke or the page would draw a chord across the
    -- gap where the camera plane cut it.
    local closed = #runs == 1 and #runs[1] == (segments + 1) * 2
    local visible = #runs > 0 and overlapsViewport(minX, minY, maxX, maxY)
    return runs, visible, closed
end

-- ------------------------------------------------------------ payload size --

-- Exactly `ReadValue`'s accounting from scripting/src/ResourceHost.cpp: a table
-- is one node, and each entry costs one for its key plus the value's own cost.
-- Written out per level rather than as a generic walk so the numbers can be
-- read against the encoder, and so the startup check below can be arithmetic
-- rather than a measurement.
local function runNodes(run)
    -- one table, then one index and one number per array element
    return 1 + 2 * #run
end

local function circleNodes(entry)
    -- the circle table, its six scalar fields (key + value each), the `runs`
    -- key, and the runs table with its entries
    local nodes = 1 + 12 + 1 + 1
    for _, run in ipairs(entry.runs) do
        nodes = nodes + 1 + runNodes(run)
    end
    return nodes
end

local function payloadNodes(payload)
    -- the wrapper table, the "circles" key, and the circles array table
    local nodes = 3
    for _, entry in ipairs(payload) do
        nodes = nodes + 1 + circleNodes(entry)
    end
    return nodes
end

-- The worst frame the constants above can produce: MAX_RENDERED circles sharing
-- the whole projection budget, each cut into two runs by the camera plane. A
-- plane can cut a circle in at most two arcs, so two runs per circle is the
-- real ceiling, not a guess.
local function worstCaseNodes()
    local circleCount = MAX_RENDERED
    local runsPerCircle = 2
    local points = PROJECTION_BUDGET
    -- per circle: 1 index + 1 table + 12 scalar + 1 runs key + 1 runs table
    --             + per run: 1 index + 1 table
    local fixed = circleCount * (1 + 1 + 12 + 1 + 1 + runsPerCircle * 2)
    return 3 + fixed + 4 * points
end

-- ------------------------------------------------------------------- frame --

-- A sustained overflow must be loud, and must not itself become the
-- performance problem. Same discipline as op77::WebUiFeed::Publish, which logs
-- at most once every five seconds per surface for exactly this reason: the
-- first drop is reported immediately, then a summary carrying the count.
local DROP_LOG_INTERVAL = 5.0
local dropLogAt = -math.huge
local dropsSinceLog = 0

local function reportDrop(circleCount, nodes, reason)
    dropsSinceLog = dropsSinceLog + 1
    local now = Open77.time.monotonic()
    if (now - dropLogAt) < DROP_LOG_INTERVAL then return end
    dropLogAt = now
    Open77.log.warn(("open77_groundcircle: FRAME DROPPED -- %d circle(s), %d payload node(s) " ..
        "of %d allowed, reason=%s (%d drop(s) since the last report). The overlay is now " ..
        "showing a STALE frame, which looks exactly like the invisible native marker this " ..
        "resource replaces.")
        :format(circleCount, nodes, PAYLOAD_NODE_CAP, tostring(reason), dropsSinceLog))
    dropsSinceLog = 0
end

-- An empty frame is only worth sending once. Repeating `{ circles = {} }` at
-- 30 Hz forever is pure IPC for a surface that is already blank, and every
-- shipped per-frame feed on this platform suppresses the identical frame.
local lastSentEmpty = false

local function sendPayload(payload)
    local empty = #payload == 0
    if empty and lastSentEmpty then return end

    -- Trim before the encoder can refuse the whole thing. Circles were sorted
    -- nearest-first, so the last one is the furthest and the cheapest to lose.
    local nodes = payloadNodes(payload)
    while nodes > PAYLOAD_NODE_CEILING and #payload > 1 do
        local dropped = table.remove(payload)
        Open77.log.warn(("open77_groundcircle: payload at %d nodes over the %d ceiling; " ..
            "dropped the furthest circle '%s'. Trimming keeps the near rings on screen; " ..
            "sending it whole would have had the encoder refuse ALL of them.")
            :format(nodes, PAYLOAD_NODE_CEILING, tostring(dropped.id)))
        nodes = payloadNodes(payload)
    end

    local sent, reason = page:send("groundcircle:update", { circles = payload })
    if not sent then
        -- page:send returns two values only when the ENCODER refuses
        -- ("invalid_webui_event_payload"); a surface-side refusal returns a
        -- bare false. Saying which is which saves the next reader a detour.
        reportDrop(#payload, nodes,
            reason or "surface refused the event (page destroyed, or over the host's own ceiling)")
        return
    end
    -- Latched only on SUCCESS. Latching before the send would let one refused
    -- empty frame suppress every empty frame after it, leaving the last drawn
    -- ring on screen forever -- a stale overlay produced by the very
    -- optimisation meant to keep an idle one cheap.
    lastSentEmpty = empty
end

local function push()
    if not page or not ready then return end
    if ringSupport == true then
        -- The plugin draws them now. One empty frame retires whatever the page
        -- still had; `sendPayload` latches on success and will not repeat it.
        sendPayload({})
        return
    end

    local state = Open77.character.state()
    if not state or not state.attached or not state.position then
        sendPayload({})
        return
    end

    local visible = {}
    for _, circle in pairs(circles) do
        if circle.visible and circle.epoch == worldEpoch then
            local viewDistance = distance(circle.position, state.position)
            if viewDistance <= circle.maxDistance then
                visible[#visible + 1] = { circle = circle, viewDistance = viewDistance }
            end
        end
    end
    -- Nearest first, so when the budget runs out it is the distant circles --
    -- the ones already reduced to a dozen segments -- that get dropped.
    table.sort(visible, function(left, right)
        return left.viewDistance < right.viewDistance
    end)

    local payload = {}
    local budget = PROJECTION_BUDGET
    for _, item in ipairs(visible) do
        if #payload >= MAX_RENDERED then break end
        local segments = segmentsFor(item.circle.radius, item.viewDistance)
        if segments + 1 > budget then break end
        budget = budget - (segments + 1)
        local runs, onScreen, closed = projectCircle(item.circle, segments)
        if onScreen then
            payload[#payload + 1] = {
                id = item.circle.id,
                color = item.circle.color,
                width = item.circle.width,
                opacity = item.circle.opacity,
                fill = item.circle.fill,
                closed = closed,
                runs = runs,
            }
        end
    end
    sendPayload(payload)
end

exports("create", create)
exports("remove", remove)
exports("clear", clear)
exports("list", list)

AddEventHandler("onClientResourceStart", function(name)
    if name ~= GetCurrentResourceName() then return end
    local reason
    page, reason = WebUI.create({
        entry = "web/index.html", layer = "hud", width = 1920, height = 1080,
        fps = 30, zIndex = 640, transparent = true, visible = true,
    })
    if not page then
        Open77.log.error("open77_groundcircle: WebUI failed: " .. tostring(reason))
        return
    end
    -- The page answers once its listener is installed. Sending before that
    -- drops the frame silently, which looks like a projection bug.
    page:on("groundcircle:ready", function() ready = true end)

    CreateThread(function()
        -- ONE over-budget tick used to kill this coroutine outright, and with it
        -- the entire overlay. `push` raises `Open77 script execution budget
        -- exceeded` from the instruction hook (scripting/src/ResourceHost.cpp
        -- InstructionHook): that is a luaL_error, it unwinds straight out of the
        -- thread body, and `while page do` never resumes again. Nothing logs a
        -- second time and `page` is still non-nil, so every status read keeps
        -- saying the resource is fine.
        --
        -- The symptom is worse than a blank overlay and is what made this so
        -- hard to see: no further payload is ever sent, so the PAGE KEEPS ITS
        -- LAST FRAME. The ring stays painted at the screen position it had at
        -- the instant of death and stops tracking the camera entirely -- it
        -- looks drawn, and it is a photograph. Measured 2026-08-26 on a pristine
        -- client at 07:26:12, about a minute after world load, and reproduced on
        -- a second client: a 50 m ring frozen as a straight line that did not
        -- move through a 90 degree yaw change or an 18 m teleport.
        --
        -- The instruction counter and the deadline are per RESUME, so a tick
        -- that overruns is over as soon as we Wait(). Catching it here therefore
        -- costs one dropped frame instead of the session.
        local failures = 0
        while page do
            local ok, failure = pcall(function()
                sweepStoppedOwners()
                syncRings()
                push()
            end)
            if not ok then
                failures = failures + 1
                -- Loud for the first few, then rare: a permanent overrun must
                -- not become a per-frame log flood at 30 Hz.
                if failures <= 3 or failures % 300 == 0 then
                    Open77.log.error(("open77_groundcircle: push tick failed (%d): %s")
                        :format(failures, tostring(failure)))
                end
            end
            Wait(FRAME_MS)
        end
    end)

    -- The budget headroom is stated in the log rather than asserted in a
    -- comment, because a comment cannot be wrong out loud. If a future field on
    -- a circle pushes the worst case over the cap, this line says so on the
    -- first start after the change instead of on the first crowded frame.
    local worst = worstCaseNodes()
    Open77.log.info(("open77_groundcircle ready, generation %d -- %d point budget, " ..
        "<= %d circle(s)/frame, worst-case payload %d node(s) of %d (%d spare)"):format(
        Open77.resource.generation(), PROJECTION_BUDGET, MAX_RENDERED,
        worst, PAYLOAD_NODE_CAP, PAYLOAD_NODE_CAP - worst))
    if worst > PAYLOAD_NODE_CAP then
        Open77.log.error(("open77_groundcircle: MISCONFIGURED -- the worst frame is %d nodes " ..
            "and the encoder refuses anything over %d. Lower PROJECTION_BUDGET or " ..
            "MAX_RENDERED; left alone, a crowded frame will blank the overlay with no " ..
            "other symptom."):format(worst, PAYLOAD_NODE_CAP))
    end
end)

-- The world changed underneath us. Advance the epoch rather than clearing:
-- handlers are scheduled, so a caller re-creating its circles from its own
-- open77:worldReady handler may run either side of this one, and a blind clear
-- would delete what it just made. See the note on `worldEpoch`.
AddEventHandler("open77:worldReady", function()
    worldEpoch = worldEpoch + 1
    lastSentEmpty = false
    Open77.log.info(("open77_groundcircle: world epoch %d; circles from earlier worlds will " ..
        "be swept within a second"):format(worldEpoch))
end)

AddEventHandler("onClientResourceStop", function(name)
    if name == GetCurrentResourceName() then
        -- Release the rings before dropping the table they are keyed by, or the
        -- plugin keeps drawing circles this resource can no longer name.
        if type(Open77.anchors) == "table" then Open77.anchors.clear() end
        ringAnchors, ringSupport = {}, nil
        page, ready = nil, false
        circles, ownerGenerations, nextOwnerSweep = {}, {}, 0
        dropLogAt, dropsSinceLog, lastSentEmpty = -math.huge, 0, false
    else
        -- A HOT RELOAD DELIVERS STOP FOR THE OLD GENERATION *AFTER* START FOR
        -- THE NEW ONE. Measured 2026-08-26: reloading `pursuit` logged two
        -- successful `create` calls and then this handler deleted both, so the
        -- overlay went blank and stayed blank for the rest of the session --
        -- with no error anywhere, because removing a circle is not a failure.
        -- `create` records the CALLING generation in ownerGenerations, so when
        -- that still matches the generation currently running, the circles
        -- belong to the live generation and must survive the old one's stop.
        local current = Open77.resource.generation(name)
        if GetResourceState(name) ~= "running" or
            ownerGenerations[name] == nil or ownerGenerations[name] ~= current then
            removeOwner(name)
            ownerGenerations[name] = nil
        end
    end
end)
