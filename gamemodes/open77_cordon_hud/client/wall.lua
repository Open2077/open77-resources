-- THE CORDON BOUNDARY, PROJECTED.
--
-- ---------------------------------------------------------------------------
-- 2026-09-03, SAME DAY: THIS IS NO LONGER THE BOUNDARY. READ THIS FIRST.
--
-- Everything below is still true and none of it has been changed. What changed
-- is WHEN this file draws: it is now the boundary of `cordonEdge = "hud"` and of
-- nothing else. Under `"world"`, which is what the mode ships, it is silent --
-- `open77_cordon/client/edge.lua`'s `wallEnabled` returns false and no
-- `cordon:edge:wall` payload with panels in it ever arrives.
--
-- WHY, AND IT IS NOT A CHANGE OF MIND ABOUT THE ARGUMENT BELOW. The owner played
-- the mode with this layer live and photographed it: a thin red line drawn over
-- the buildings in front of it, floating at eye height with a gap underneath,
-- breaking into disjoint pieces as the camera turned. Those are, in order,
-- exactly the three costs THE THREE HONEST COSTS section further down had
-- already written out and accepted -- no occlusion, a ground line projecting
-- near the horizon when it is far away, and a nearest-N segment set that is not
-- a contiguous run. The section was right; what was wrong was the premise that
-- there was nothing better available.
--
-- There was. `Open77.props.create` with `kind = "prop"` spawns real barricade
-- meshes -- `wiki/props.md`, measured 2026-08-28 on two clients: "A prop draws
-- the model you ask for" -- and engine geometry is depth-sorted, lit and stands
-- on the ground for free. That is a fix for all three complaints rather than a
-- mitigation, and the boundary moved there. The research behind it, including
-- why the base game has no area-delimiter to call, is in
-- docs/research/battle-royale-and-scale.md (2026-09-03).
--
-- THIS FILE IS KEPT, NOT DELETED, for one reason: under `"hud"` there is no
-- world layer at all, and a mode with no visible boundary is the one thing the
-- design cannot ship. `Config.cordon.edge.wall.enabled = true` forces it back on
-- under `"world"` for a side-by-side, which is the only remaining way to compare
-- the two.
--
-- ---------------------------------------------------------------------------
-- WHY THIS EXISTS, IN ONE PARAGRAPH
--
-- `open77_cordon/client/edge.lua` spent three rounds building a boundary out of
-- world entities -- a red light prop and a 50 m smoke column per post -- and on
-- 2026-09-03 it reported, from the engine's own registry,
-- `posts=32 (props=32 rendered=32 failed=0 vfx=32) ... nearest post d=42m`
-- while the owner stood twenty-two metres away, facing it, looking at an empty
-- street. Geometry right, engine says rendered, no pixels. That is the
-- discriminator: THE PRIMITIVE IS WHAT DOES NOT DRAW.
--
-- `resources/system/open77_groundcircle/client/main.lua` wrote the diagnosis before we
-- did -- "when any link of that chain fails to produce pixels, the native
-- registry still reports the marker as rendered, so a caller cannot tell a drawn
-- ring from an invisible one" -- and answered it by leaving the engine's render
-- path entirely: sample world points, project each one with
-- `Open77.camera.project`, stroke the result as SVG on a transparent surface.
-- WHAT THE LUA COMPUTES IS WHAT THE PLAYER SEES. Nothing in between can succeed
-- quietly. This file is that argument applied to the cordon.
--
-- ---------------------------------------------------------------------------
-- THE SPLIT, AND WHY THE GEOMETRY IS NOT COMPUTED HERE
--
-- The gamemode owns the boundary; this resource owns the pixels.
--
--   open77_cordon/client/edge.lua   walks the open-cell lattice, finds the
--                                   boundary segments inside `drawRadiusMetres`
--                                   sorted nearest-first, and publishes the
--                                   nearest few as `cordon:edge:wall` in WORLD
--                                   metres. On change, plus a 2 s heartbeat.
--   this file                       projects those endpoints against the LIVE
--                                   camera, twenty times a second, and sends
--                                   normalised screen coordinates to the page.
--
-- Re-deriving the boundary here was the obvious alternative and is the wrong
-- one: this resource already receives `cordon:bounds:local`, so it COULD. But
-- that machinery -- the integer open-set index, the chunked scan, the candidate
-- sort, the hysteresis -- took two production outages to get right, and a second
-- copy in a second Lua VM would be a second thing to get wrong, in a resource
-- whose reload policy is `reconnect`. One boundary, one author.
--
-- ---------------------------------------------------------------------------
-- WHAT IS DRAWN
--
-- One PANEL per boundary segment: a vertical quad standing on the segment, 18 m
-- tall by default. Four world points, four projections, and the page strokes
--
--   * the BASE, bright -- the line on the ground you must not cross;
--   * the two RIBS and the TOP, dashed and dim -- what makes it read as a
--     barrier rather than a decal;
--   * a faint curtain fill between them, denser at the bottom.
--
-- Adjacent panels share a rib exactly, so a run of them reads continuous with a
-- slightly brighter post every lattice pitch. That is not an artefact to fix; it
-- is the only thing that gives the wall a sense of scale.
--
-- ---------------------------------------------------------------------------
-- WHY FOUR PROJECTIONS PER PANEL AND NOT FORTY
--
-- A perspective projection maps a STRAIGHT WORLD LINE to a straight screen line.
-- That is the whole reason this is cheap where `open77_groundcircle` is not: a
-- circle has to be sampled point by point because its projection is an ellipse
-- whose axes depend on the camera basis, but a 25 m boundary segment is exactly
-- two points, and a vertical quad is exactly four. A 2 km perimeter costs the
-- same as a 40 m one, because the cost is the number of panels within the draw
-- radius, and that is capped -- not the length of the boundary.
--
-- THE NEAR PLANE IS THE ONE THING THAT BREAKS IT, and it is handled in world
-- space rather than by dropping points. A point at or behind the camera plane
-- projects to garbage -- the perspective divide flips its sign and the line
-- whips across the screen -- and the case matters precisely when the player is
-- STANDING ON the boundary, which is when the boundary matters most.
--
-- The panel is therefore CLIPPED before it is projected, and the arithmetic is
-- exact rather than approximate. Depth along the base is linear in the segment
-- parameter t. The top edge differs from the base only by `+height` in z, so its
-- depth is the base's depth plus a CONSTANT `height * forward.z` -- the whole
-- panel is governed by one linear inequality, solved once per panel with no
-- native call:
--
--     depth(t) >= NEAR_METRES + max(0, -height * forward.z)
--
-- Clipping the parameter range keeps the ribs genuinely vertical (clipping the
-- base and the top independently would not) and guarantees all four corners sit
-- in front of the plane, so all four projections are meaningful. A panel whose
-- range is empty is skipped for zero native calls.
--
-- ---------------------------------------------------------------------------
-- THE THREE HONEST COSTS
--
-- 1. IT IS NOT OCCLUDED. A screen overlay is not depth-tested, so the wall shows
--    through a megabuilding. There is no fix available from Lua: the client
--    exposes no spatial query to a resource (`Open77.world` carries safe areas
--    and environment, no raycast), and the per-vertex raycast pass described in
--    `docs/world-primitives.md` belongs to `Open77.anchors`, which cannot draw
--    an arbitrary polyline -- its `render = "ring"` is a circle. What IS
--    available is a DISTANCE cue, and it is used: every panel is faded and its
--    strokes thinned by range, so a wall behind a building reads as a distant
--    one rather than as a near one. That is a mitigation, not a solution, and
--    the wall will sometimes look like it is inside a wall.
-- 2. IT TRAILS THE CAMERA. The projection is sampled on this Lua tick, not in
--    the frame that presents it, so a fast whip drags the wall by up to a tick.
--    `Open77.anchors` exists to fix exactly this and cannot be used here for the
--    reason above. A 50 m structure slipping a few pixels reads far better than
--    a nameplate doing the same -- which is why nameplates were moved off this
--    path and this can stay on it.
-- 3. IT IS A FOURTH SURFACE. See `client/main.lua` at the page creation for the
--    measurement that makes that a real cost and for what is done about it: the
--    surface is created HIDDEN and is shown only while there is boundary within
--    the draw radius.
--
-- ---------------------------------------------------------------------------
-- THE BUDGET, AND WHY THERE IS A WATCHDOG
--
-- `ResourceHost::Tick` gives every coroutine resume a wall-clock slice of
-- `frameBudget / runningResources`, floored at 50 us when this was written and
-- at 300 us since 2026-09-18 (one 10 000-instruction hook interval) -- on a busy
-- client that is the floor -- and `InstructionHook` raises a Lua
-- error when it is exceeded. `ResumeTask` RETIRES a coroutine that raises. A
-- tick loop that overruns once is gone for the rest of the session, in silence,
-- and the page keeps its last frame: a wall painted at the screen position it
-- had at the instant of death, which looks drawn and is a photograph. That
-- failure has been observed twice on this platform (`open77_groundcircle`, 50 m
-- ring frozen through a 90 degree yaw and an 18 m teleport; `edge.lua`, one
-- error line then fourteen minutes of nothing).
--
-- Three defences, all of them paid for by those two:
--   * the tick body runs under `pcall`;
--   * a heartbeat watchdog restarts the thread if it dies anyway -- the hook can
--     fire between `pcall` returning and `Wait` yielding, outside anything this
--     file can catch;
--   * the panel budget HALVES after repeated failures instead of the overlay
--     dying. A degraded wall is a wall; a retired coroutine is a photograph.

CordonWall = {}

local page
local ready = false
local shown = false

-- What the gamemode last published, and when. `wall.points` is a flat array of
-- five numbers per panel: ax, ay, bx, by, z.
local wall = nil
local wallAt = -math.huge

-- Longer than the publisher's 2 s heartbeat by a wide margin, so a dropped pass
-- on a loaded client cannot blank the boundary; short enough that a stopped or
-- reloading gamemode does not leave a ghost wall standing for long. `edge.lua`
-- also retracts explicitly on its stop handler, so this is the backstop and not
-- the mechanism.
local WALL_STALE_SECONDS = 6.0

-- 20 Hz. The surface is declared at 30 fps so CEF never coalesces two updates
-- into one paint; the Lua tick is the slower of the two on purpose. See
-- `client/main.lua` for why this number is not 60.
local FRAME_MS = 50

-- A point closer than this to the camera plane is not projected. 0.4 m is
-- comfortably in front of any near plane the engine uses and keeps the clipped
-- corner off the very edge of the frustum, where the projection is numerically
-- worst.
local NEAR_METRES = 0.4

-- Projected coordinates are normalised, but a point barely in front of the
-- camera can still land thousands of screens away. Clamping keeps the path data
-- small without changing anything the player can see.
local COORD_LIMIT = 4.0

-- The event encoder's ceiling (`kMaximumEventValues`, ResourceHost.cpp) and the
-- level this file trims at. Overshooting does not truncate: `page:send` answers
-- `false, "invalid_webui_event_payload"` and the WHOLE frame is refused, which
-- at 20 Hz leaves a stale wall on screen -- the exact failure this resource
-- exists to replace.
local PAYLOAD_NODE_CAP = 1024
local PAYLOAD_NODE_CEILING = 880

-- Panels per frame. Sixteen is 64 native projections a tick, 1280 a second --
-- the same order as `open77_groundcircle`'s shipped 96-point budget at 30 Hz.
-- `edge.lua` never sends more than 24, so this is the binding cap.
local MAX_PANELS = 16
local MIN_PANELS = 4
local panelBudget = MAX_PANELS

-- Distance fade. Full strength inside a quarter of the draw radius, down to
-- FADE_FLOOR at the radius itself. This is the answer to "the player is inside
-- and nowhere near the edge": at 150 m the wall is drawn at an eighth strength
-- and reads as a horizon, not as clutter.
local FADE_NEAR_FRACTION = 0.25
local FADE_FLOOR = 0.12

-- Diagnostics. One line every REPORT_SECONDS, and only while there is something
-- to say -- see the block at `report` for what each field is for.
local REPORT_SECONDS = 15.0
local reportAt = 0.0
local statProjected, statDrawn, statNodes = 0, 0, 0
local statReason = "no boundary published yet"
local statDrops = 0

-- One reusable table for every projection call of every frame. `LuaCameraProject`
-- only READS x, y, z off it (`ReadVector3`), so a fresh table per point would be
-- sixty-four allocations a tick for nothing -- and allocation is what the
-- execution-budget hook actually kills a pass for.
local probe = { x = 0.0, y = 0.0, z = 0.0 }

local function say(level, message)
    local log = Open77 ~= nil and Open77.log or nil
    if log ~= nil and type(log[level]) == "function" then
        log[level]("open77_cordon_hud wall: " .. message)
    end
end

local function number(value, fallback)
    local n = tonumber(value)
    if n == nil or n ~= n then return fallback or 0 end
    return n
end

local function nowSeconds()
    if Open77 == nil or type(Open77.time) ~= "table" or
        type(Open77.time.monotonic) ~= "function" then
        return 0.0
    end
    local ok, value = pcall(Open77.time.monotonic)
    if not ok then return 0.0 end
    return number(value, 0.0)
end

local function cameraAvailable()
    return type(Open77.camera) == "table" and
        type(Open77.camera.view) == "function" and
        type(Open77.camera.project) == "function"
end

-- ---------------------------------------------------------------------------
-- Showing and hiding
--
-- The show/hide EDGE is what costs, not the state: `SurfaceClient::SetVisible`
-- calls CEF's `WasHidden`, which stops the browser rendering entirely, and
-- `WebUiService::Draw` skips a hidden surface before it reaches `AddImage`. So a
-- hidden surface costs its allocated texture and nothing per frame.
--
-- The toggle therefore follows the PUBLISHER, not the camera. A wall that
-- vanished whenever the player turned round would hide and show several times a
-- second, and every one of those is a browser resume; following `edge.lua`'s
-- scan means at most one toggle per rebuild, which is once a second at the very
-- worst and normally once a minute.
-- ---------------------------------------------------------------------------
local function setShown(next)
    if next and CordonTacmap and CordonTacmap.isOpen and CordonTacmap.isOpen() then next = false end
    if next and CordonHud and CordonHud.canPresent and not CordonHud.canPresent() then next = false end
    if page == nil or shown == next then return end
    shown = next
    if next then page:show() else page:hide() end
end

local function send(payload)
    if page == nil or not ready then return end
    local sent, reason = page:send("cordon:wall", payload)
    if sent then return end
    -- `page:send` returns a reason only when the ENCODER refused; a surface-side
    -- refusal is a bare false. Saying which saves the next reader a detour.
    statDrops = statDrops + 1
    statReason = "page:send refused (" ..
        tostring(reason or "surface refused: page destroyed or over its own ceiling") .. ")"
end

-- ---------------------------------------------------------------------------
-- One frame
-- ---------------------------------------------------------------------------

local function project(x, y, z)
    probe.x, probe.y, probe.z = x, y, z
    local point = Open77.camera.project(probe)
    if type(point) ~= "table" then return nil end
    local px, py = point.x, point.y
    if type(px) ~= "number" or px ~= px or type(py) ~= "number" or py ~= py then
        return nil
    end
    return point
end

local function clampCoord(value)
    if value < -COORD_LIMIT then return -COORD_LIMIT end
    if value > COORD_LIMIT then return COORD_LIMIT end
    return value
end

-- Rounded to four decimals before it goes on the wire. At 1920 px wide that is
-- a fifth of a pixel, and it keeps every number in the payload short.
local function coord(value)
    return math.floor(clampCoord(value) * 10000.0) / 10000.0
end

-- Exactly `ReadValue`'s accounting: the wrapper table, one node per key and one
-- per value, and the points array costing one plus two per element. Written out
-- rather than walked so the number can be read against the encoder.
local function payloadNodes(count)
    -- table + (panels, stride, color) as key/value pairs + the points key
    return 1 + 6 + 1 + (1 + 2 * count)
end

local function frame()
    if page == nil then return end
    if (CordonHud and CordonHud.canPresent and not CordonHud.canPresent())
        or (CordonTacmap and CordonTacmap.isOpen and CordonTacmap.isOpen()) then
        setShown(false)
        return
    end
    local now = nowSeconds()

    -- NOTHING TO DRAW is a first-class state and it is the common one. Inside
    -- the cordon and away from its edge, `edge.lua` publishes zero panels, the
    -- surface is hidden, and this resource costs one integer compare per tick.
    if wall == nil or wall.panels <= 0 then
        statReason = wall == nil and "no boundary published yet"
            or "no boundary within the draw radius"
        statProjected, statDrawn, statNodes = 0, 0, 0
        setShown(false)
        return
    end
    if (now - wallAt) > WALL_STALE_SECONDS then
        statReason = ("the gamemode stopped publishing %.0fs ago"):format(now - wallAt)
        statProjected, statDrawn, statNodes = 0, 0, 0
        setShown(false)
        return
    end

    -- THE HANDSHAKE IS NOT A PRECONDITION FOR SHOWING. This surface is created
    -- hidden, and a hidden surface is a CEF browser under `WasHidden(true)`; the
    -- document loads and the script runs, but that is an inference about CEF's
    -- behaviour and not something measured on this client. Showing the page
    -- before requiring its answer makes the wall robust either way: if the
    -- handshake fires while hidden, nothing changes; if it does not, showing the
    -- surface is what lets it fire, and the boundary appears one tick later
    -- instead of never. `send` still refuses to speak to a page that has not
    -- answered, so no frame is delivered into the void.
    if not ready then
        setShown(true)
        return
    end

    if not cameraAvailable() then
        statReason = "Open77.camera.project is unavailable on this client"
        setShown(false)
        return
    end

    local ok, view = pcall(Open77.camera.view)
    if not ok or type(view) ~= "table" or type(view.position) ~= "table" or
        type(view.forward) ~= "table" then
        -- No camera: a load screen, a transition. CLEAR rather than freeze. A
        -- frozen wall is the failure mode this file exists to avoid, and a blank
        -- frame during a load screen is invisible.
        statReason = "no camera this tick"
        statProjected, statDrawn, statNodes = 0, 0, 0
        send({ panels = 0, stride = 9, points = {} })
        return
    end

    local cx = number(view.position.x)
    local cy = number(view.position.y)
    local cz = number(view.position.z)
    local fx = number(view.forward.x)
    local fy = number(view.forward.y)
    local fz = number(view.forward.z)
    local flen = math.sqrt(fx * fx + fy * fy + fz * fz)
    if flen < 1e-4 then
        statReason = "camera forward is degenerate"
        send({ panels = 0, stride = 9, points = {} })
        return
    end
    fx, fy, fz = fx / flen, fy / flen, fz / flen

    local points = wall.points
    local stride = math.max(1, math.floor(number(wall.stride, 5)))
    local height = math.max(1.0, number(wall.height, 18.0))
    local radius = math.max(1.0, number(wall.radius, 150.0))

    -- The single near-plane inequality for the whole wall. See the header: the
    -- top of a panel is the base plus `height` in z, so its depth is the base's
    -- plus the constant `height * forward.z`. Requiring the WORSE of the two to
    -- clear the plane is one comparison per endpoint.
    local minDepth = NEAR_METRES + math.max(0.0, -(height * fz))

    local fadeNear = radius * FADE_NEAR_FRACTION
    local fadeSpan = math.max(1.0, radius - fadeNear)

    local out = {}
    local drawn = 0
    local projected = 0
    local limit = math.min(math.floor(number(wall.panels, 0)), panelBudget)

    for index = 0, limit - 1 do
        local base = index * stride
        local ax, ay = points[base + 1], points[base + 2]
        local bx, by = points[base + 3], points[base + 4]
        local z = points[base + 5]
        if type(ax) == "number" and type(ay) == "number" and
            type(bx) == "number" and type(by) == "number" and type(z) == "number" then

            local da = (ax - cx) * fx + (ay - cy) * fy + (z - cz) * fz
            local db = (bx - cx) * fx + (by - cy) * fy + (z - cz) * fz
            local t0, t1 = 0.0, 1.0
            local usable = true
            if da < minDepth or db < minDepth then
                local span = db - da
                if math.abs(span) < 1e-4 then
                    -- The whole segment is at one depth and that depth is behind
                    -- the plane.
                    usable = false
                else
                    local t = (minDepth - da) / span
                    if span > 0.0 then
                        if t > t0 then t0 = t end
                    else
                        if t < t1 then t1 = t end
                    end
                    if t0 >= t1 then usable = false end
                end
            end

            if usable then
                local ex, ey = bx - ax, by - ay
                local p0x, p0y = ax + ex * t0, ay + ey * t0
                local p1x, p1y = ax + ex * t1, ay + ey * t1
                local b0 = project(p0x, p0y, z)
                local b1 = project(p1x, p1y, z)
                local u0 = project(p0x, p0y, z + height)
                local u1 = project(p1x, p1y, z + height)
                projected = projected + 4
                if b0 ~= nil and b1 ~= nil and u0 ~= nil and u1 ~= nil then
                    local x0, y0 = clampCoord(b0.x), clampCoord(b0.y)
                    local x1, y1 = clampCoord(b1.x), clampCoord(b1.y)
                    local x2, y2 = clampCoord(u1.x), clampCoord(u1.y)
                    local x3, y3 = clampCoord(u0.x), clampCoord(u0.y)
                    -- A BOUNDING-BOX TEST, NOT `onScreen`. `onScreen` is a
                    -- per-POINT answer, and a panel can cross the whole viewport
                    -- with every one of its four corners outside it -- stand
                    -- close to a tall wall and that is the normal case. The box
                    -- overlap is conservative in the safe direction: it can keep
                    -- a panel whose stroke happens to miss, which costs one
                    -- unnecessary path.
                    local minX = math.min(x0, x1, x2, x3)
                    local maxX = math.max(x0, x1, x2, x3)
                    local minY = math.min(y0, y1, y2, y3)
                    local maxY = math.max(y0, y1, y2, y3)
                    if minX <= 1.0 and maxX >= 0.0 and minY <= 1.0 and maxY >= 0.0 then
                        local distance = math.min(number(b0.distance, radius),
                            number(b1.distance, radius))
                        local fade = 1.0 - (1.0 - FADE_FLOOR) *
                            math.max(0.0, math.min(1.0, (distance - fadeNear) / fadeSpan))
                        local slot = drawn * 9
                        -- Quad order: base start, base end, top end, top start.
                        -- The page walks it as one closed path and reuses the
                        -- same four points for the base stroke and the ribs.
                        out[slot + 1] = coord(x0)
                        out[slot + 2] = coord(y0)
                        out[slot + 3] = coord(x1)
                        out[slot + 4] = coord(y1)
                        out[slot + 5] = coord(x2)
                        out[slot + 6] = coord(y2)
                        out[slot + 7] = coord(x3)
                        out[slot + 8] = coord(y3)
                        out[slot + 9] = math.floor(fade * 1000.0) / 1000.0
                        drawn = drawn + 1
                    end
                end
            end
        end
    end

    -- Trim before the encoder can refuse the whole frame. Panels arrive
    -- nearest-first from `edge.lua`, so the tail is the furthest and the
    -- cheapest to lose. With the constants above this cannot trigger; it is here
    -- because a future field would make it, and the symptom would be a wall that
    -- blanks under load with no other sign.
    local nodes = payloadNodes(drawn * 9)
    while nodes > PAYLOAD_NODE_CEILING and drawn > 1 do
        for offset = 1, 9 do out[(drawn - 1) * 9 + offset] = nil end
        drawn = drawn - 1
        nodes = payloadNodes(drawn * 9)
        say("warn", ("payload over the %d-node ceiling; dropped the furthest panel. " ..
            "Trimming keeps the near wall on screen; sending it whole would have had " ..
            "the encoder refuse ALL of it."):format(PAYLOAD_NODE_CEILING))
    end

    statProjected, statDrawn, statNodes = projected, drawn, nodes
    statReason = drawn > 0 and "drawing"
        or "every panel is off screen or behind the camera"

    setShown(true)
    send({
        panels = drawn,
        stride = 9,
        color = type(wall.color) == "string" and wall.color or "#ff5964",
        points = out,
    })
end

-- ---------------------------------------------------------------------------
-- THE DIAGNOSTIC LINE, AND THE BISECT IT COMPLETES
--
-- `edge.lua`'s own periodic line now carries `wall=N panels live=true|false`.
-- This one carries what happened to those N panels on the way to the screen.
-- Read together they place the fault without a screenshot:
--
--   edge says wall=0            no boundary within the draw radius. Walk toward
--                               it, or check `open=` and `rev=` on the same line.
--   edge says wall=N live=true,
--     this line never appears   the HUD is not receiving the event -- check that
--                               open77_cordon_hud is running and that
--                               client/wall.lua is in its manifest.
--   drawn=0 projected=0         every panel was clipped behind the camera: you
--                               are facing away from the boundary.
--   drawn=0 projected>0         projection is happening and landing off screen.
--   drawn>0 shown=yes, street
--     still empty               the geometry and the projection are right and the
--                               PAGE is what does not draw. That is a CEF-side
--                               fault -- inspect web/wall.js and web/wall.css --
--                               and it is the one branch the world-entity edge
--                               could never be narrowed down to.
-- ---------------------------------------------------------------------------
local function report()
    say("info", ("panels=%d/%d projected=%d drawn=%d nodes=%d/%d shown=%s budget=%d " ..
        "drops=%d reason=%s")
        :format(wall ~= nil and math.floor(number(wall.panels, 0)) or 0,
            MAX_PANELS, statProjected, statDrawn, statNodes, PAYLOAD_NODE_CAP,
            tostring(shown), panelBudget, statDrops, statReason))
end

-- ---------------------------------------------------------------------------
-- The publisher
-- ---------------------------------------------------------------------------

-- A LOCAL event, not a net event: `open77_cordon/client/edge.lua` raises it with
-- `TriggerEvent` and the host dispatches local events to every running
-- resource's handlers. `RegisterNetEvent` would never fire, which is the same
-- note `client/combat.lua` carries for `cordon:hurt`.
AddEventHandler("cordon:edge:wall", function(payload)
    if type(payload) ~= "table" then return end
    local points = payload.points
    local panels = math.floor(number(payload.panels, 0))
    if type(points) ~= "table" or panels < 0 then return end
    wall = {
        panels = panels,
        stride = math.max(1, math.floor(number(payload.stride, 5))),
        points = points,
        height = number(payload.height, 18.0),
        radius = number(payload.radius, 150.0),
        color = payload.color,
    }
    wallAt = nowSeconds()
end)

-- A world transition invalidates every world coordinate held here. The publisher
-- will re-scan and re-publish on its own, but not necessarily before the player
-- can see the old boundary painted over the new world.
AddEventHandler("open77:worldReady", function()
    wall = nil
    wallAt = -math.huge
end)

-- ---------------------------------------------------------------------------
-- Lifecycle
-- ---------------------------------------------------------------------------

local heartbeat = 0
local generation = 0
local restarts = 0
local failures = 0

local function startTick()
    generation = generation + 1
    local mine = generation
    CreateThread(function()
        while page ~= nil and mine == generation do
            local ok, failure = pcall(frame)
            if ok then
                failures = 0
            else
                failures = failures + 1
                -- DEGRADE, DO NOT DIE. A sustained overrun halves the budget
                -- rather than leaving a photograph on screen; see the budget
                -- note in the header.
                if failures >= 3 and panelBudget > MIN_PANELS then
                    panelBudget = math.max(MIN_PANELS, math.floor(panelBudget / 2))
                    failures = 0
                    say("warn", ("frame budget exceeded repeatedly; panel budget cut to %d. " ..
                        "The wall is coarser and still live. Last error: %s")
                        :format(panelBudget, tostring(failure)))
                elseif failures == 1 then
                    say("error", "frame failed: " .. tostring(failure))
                end
            end
            heartbeat = heartbeat + 1

            local now = nowSeconds()
            if now > 0.0 and now >= reportAt then
                reportAt = now + REPORT_SECONDS
                -- Only while there is a boundary to talk about. A player in
                -- staging, or one nowhere near the edge, writes nothing.
                if wall ~= nil and wall.panels > 0 then pcall(report) end
            end

            Wait(FRAME_MS)
        end
    end)
end

function CordonWall.attach(target)
    page = target
    ready = false
    shown = false
    failures = 0
    panelBudget = MAX_PANELS
    page:on("cordon:wall:ready", function() ready = true end)
    startTick()

    -- THE WATCHDOG OUTLIVES THE TICK, deliberately. `ResumeTask` retires a
    -- coroutine that raises, and the instruction hook can fire in the handful of
    -- VM instructions between `pcall` returning and `Wait` yielding -- outside
    -- anything the loop above can catch. That is a small window per overrun and
    -- the failure it produces is total and silent. One integer compare every
    -- five seconds buys it back.
    CreateThread(function()
        local seen = -1
        while page ~= nil do
            Wait(5000)
            if page == nil then return end
            if heartbeat == seen then
                restarts = restarts + 1
                if restarts <= 3 then
                    say("warn", ("the wall tick stopped (restart %d). The host retires a " ..
                        "coroutine that raises; the boundary would otherwise have frozen " ..
                        "on screen."):format(restarts))
                end
                startTick()
            end
            seen = heartbeat
        end
    end)

    -- Said once, at attach, because a page that never answers `cordon:wall:ready`
    -- is indistinguishable from a page that draws nothing -- and the first is a
    -- manifest or entry-path mistake while the second is a drawing bug.
    CreateThread(function()
        Wait(10000)
        if page ~= nil and not ready then
            say("error", "web/wall.html never answered cordon:wall:ready after 10 s. " ..
                "Nothing will be drawn. Check that web_files covers web/** and that the " ..
                "entry path in client/main.lua matches the file on disk.")
        end
    end)
end

function CordonWall.detach()
    generation = generation + 1
    page, ready, shown = nil, false, false
    wall = nil
    wallAt = -math.huge
end
