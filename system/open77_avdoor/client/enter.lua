-- =============================================================================
-- open77_avdoor -- client/enter.lua
-- =============================================================================
-- The boarding, animated (1.7.0): this game's half of the step up into the
-- door (server/enter.lua). Rosalind Myers boarding her AV in Phantom Liberty
-- (q305), the clip `enter` of the exit's own package: it STARTS where the
-- player entity stands -- turned to the door, a metre before it -- and ends in
-- the door, half a metre up (`WALK_CLIPS`, `first`).
--
-- THE ORDER OF IT is the exit's (1.6.0), for the same reasons:
--   1. THE PLAN (`ENTER`, the server's ask): the hull as this game draws it
--      when it agrees with the network, else where the network has it; the
--      exit's own plan for the enter clip (`M.WalkOut.PlanOn`, the door point
--      and the clip's reach), the ground under its first spot, and the door's
--      step over that ground within the clip's reach (turned about the door on
--      a slope, `STEP_TURNS`; the relaxed reach last).
--   2. THE PLACE, with the image on: the body is put on the first spot facing
--      the door (`Open77.travel.teleport`), must land there and stand
--      `STAND_LOOKS` looks, face the door within `FACING_DEGREES` (turned back
--      `FACING_TRIES` times), and is held (`HOLD`: the platform's freeze, and
--      its turning) and must stand, held, `HOLD_LOOKS` looks more. The native
--      fade holds a body still wherever it is, in the air too, where no screen
--      draws a clip: nothing moves the body under the curtain.
--   3. THE VIEW changes to third person (the stand-in body, the only one the
--      clip plays on on this screen): a cut, in view (1.7.1; `CURTAIN = true`:
--      a short black over it). 1.7.3: asked AT THE KEY (`VIEW_EARLY`) -- the
--      first third person of a session makes the stand-in, 2 to 4 s on a slow
--      game -- and the step is asked only once this screen draws the stand-in,
--      for `VIEW_SETTLE_MS` or settled: a clip started while the stand-in is
--      still being made or dressed is never drawn on it (the owner's first
--      boarding on 1.7.2: the stand-in stood still at the door through the
--      clip). None within `VIEW_WAIT_MS` of the key: the plain boarding
--      (`VIEW_REQUIRED`).
--   4. THE ASK (`ENTER_READY`, the plan with it); the server's word
--      (`ENTERING`): the clip plays.
--   5. THE SEAT (1.7.8): `VIEW_LEAD_MS` before the clip's end (a door's clip:
--      `DOOR_VIEW_LEAD_MS`) the hold is let go and first person forced, so the
--      stand-in is put away while the body is still on foot -- a seat taken
--      with it on screen left it standing on the first spot beside the AV
--      until the pilot flew off; once first person shows (or `PARK_WAIT_MS`
--      went by) the seat is asked (`ENTER_SEAT`) and the server seats the
--      body at once; the seat taken (`BOARDED`, or the seat read), the lock on
--      the view is let go and the view is the pilot's. Then the seat is
--      watched four seconds: where this game draws the body (its hips against
--      the seat), the view, the hull, each change a line.
-- INTO THE SEAT (1.7.7): an ask for a seat clip (`sit`, the Excalibur's pilot
-- seat) is planned on the seat's slot instead (`M.SitPlan`): the first spot is
-- where the clip's end lands on the slot, facing the slot's way, and the seat
-- must stand at the clip's height over that spot's ground (`M.SeatFit`; a
-- slope beside the AV, a hull over its gear: set down first). A seat clip
-- that will not do is replaced by the door's clip the ask names (`fallback`),
-- and the word to the server says why (`sitWhy`). The camera swings
-- `SIT_ORBIT_DEGREES` toward the door for it.
-- THE HULL OVER ITS GEAR (1.7.1): when every step the plan tried is too high
-- and the airframe's gear is known, this game measures the ground under its
-- feet and the answer asks the server to set the hull down first (`setDown`);
-- the server's second ask (`again`) is planned on the hull as this game draws
-- it, waited for `SET_DOWN_LOOK_MS` at most to come down.
-- A WEAPON DRAWN at the key (1.7.2) is holstered first, and the step waits
-- for the hands to be empty (`HOLSTER_WAIT_MS`): the platform plays no clip on
-- a body with a weapon drawn. A GAME WITHOUT THE CLIPS (1.7.2: open77_avexit's
-- package not registered here, `AvDoor.AnimMissing`) says no step at once.
-- Any failure before the clip plays gives the step up (`clip = false`, with
-- why): the server seats the body at once. Every step of it is a line in this
-- game's log, with the time since the key, the body's place, heading and
-- footing, the view, and a summary line at the end with the frame rate; and
-- while it runs this game keeps a few small pictures of its own frame
-- (client/shots.lua: `DIAG`).
-- =============================================================================

local M = AvDoor
local E = {}
M.Enter = E

-- The boarding in progress (one at a time), or nil:
-- `{ token, id, seat, record, clip, since, askMs, doorOpenAt, plan, phase,
--    placements, placedAt, movedPass, arrivedAt, good, facingBack, held, holdGood,
--    curtained, viewSince, viewHeld, drawnAt, askedAt, playing, seatPrepared,
--    seatingSince, seatedAt, liftAt, lines, marks }`.
local enter = nil

-- The watch's passes (a teleport is applied on the next frame: no read in the
-- pass it was made in says where it put the body).
local pass = 0

-- What happened, for the status line and the suite.
local counts = { asked = 0, stepped = 0, seated = 0, none = 0, abandoned = 0, holstered = 0, noClips = 0 }

-- How many lines of the body's state a boarding may write.
local BODY_LINES = 16
-- How far the body may stray from the first spot before it is put back.
local STRAY_METRES = 0.5
-- THE BODY OFF ITS SPOT (1.8.1). The entity stands on the clip's first spot
-- while the clip plays (its root motion is in the hips), so a body that stands
-- off the spot plays the whole clip that far off the AV. The AV's collision
-- pushes a body put too near its side out: 0.34 m from open77_avexit 1.3.0's
-- couch spot, 0.19 m outside the folded door's rim (Staging, 2026-10-30) -- the
-- first step came down in the air outside the tray and the body sat down 0.34 m
-- left of the seat's slot until the seat's hand-over moved it in. Beyond `OFF_SPOT_METRES` the arrival
-- and the ask say how far and which way, in the hull's frame; beyond
-- `OFF_SPOT_WARN_METRES` as a warning.
local OFF_SPOT_METRES = 0.05
local OFF_SPOT_WARN_METRES = 0.15
-- A turn of the body this many times `FACING_DEGREES` during the clip is said.
local CLIP_TURN_FACTOR = 2.0

local said = {}

local function cfg() return M.EnterSettings() end

local function once(key, level, text)
    if said[key] then return end
    said[key] = true
    Open77.log[level](text)
end

local function finite(value)
    local number = tonumber(value)
    if number == nil or number ~= number or number == math.huge or number == -math.huge then return nil end
    return number
end

local function position()
    local character = Open77.character
    if type(character) ~= 'table' or type(character.position) ~= 'function' then return nil end
    local read, x, y, z = pcall(character.position)
    if not read then return nil end
    x, y, z = finite(x), finite(y), finite(z)
    if x == nil or y == nil or z == nil then return nil end
    return { x = x, y = y, z = z }
end

local function bodyYaw()
    if M.WalkOut ~= nil and M.WalkOut.BodyYaw ~= nil then return M.WalkOut.BodyYaw() end
    local character = Open77.character
    if type(character) == 'table' and type(character.yaw) == 'function' then
        local read, yaw = pcall(character.yaw)
        yaw = read and finite(yaw) or nil
        if yaw ~= nil then return yaw % 360.0 end
    end
    return nil
end

--- What the body's own game says of it: `{ grounded, standing, mounted, workspot, air }`, or nil.
local function bodyNow()
    local character = Open77.character
    if type(character) ~= 'table' or type(character.state) ~= 'function' then return nil end
    local read, state = pcall(character.state)
    if not read or type(state) ~= 'table' then return nil end
    local vehicle = type(state.vehicle) == 'table' and state.vehicle or {}
    local b = { grounded = state.grounded, air = state.air, fall = state.fall,
        mounted = vehicle.mounted == true or state.inVehicle == true, workspot = state.inWorkspot == true }
    b.standing = state.grounded ~= false and not b.mounted and not b.workspot
    return b
end

local function bodyText(b)
    if b == nil then return 'not read' end
    local parts = { b.grounded == false and ('off the ground (%s)'):format(tostring(b.air or '?'))
        or (b.grounded == true and 'on the ground' or 'ground not said') }
    if b.mounted then parts[#parts + 1] = 'mounted' end
    if b.workspot then parts[#parts + 1] = 'in a workspot' end
    return table.concat(parts, ', ')
end

local function apart(a, b)
    local dx, dy = a.x - b.x, a.y - b.y
    return math.sqrt(dx * dx + dy * dy)
end

local function alive()
    local character = Open77.character
    if type(character) ~= 'table' or type(character.isAlive) ~= 'function' then return true end
    local read, living = pcall(character.isAlive)
    return not read or living ~= false
end

local function mySeat()
    local api = Open77.vehicles
    if type(api) ~= 'table' or type(api.getPlayerSeat) ~= 'function' then return nil end
    local read, seat = pcall(api.getPlayerSeat)
    if read and type(seat) == 'table' and seat.vehicleId ~= nil then return seat end
    return nil
end

local function perspectiveState()
    if M.WalkOut ~= nil and M.WalkOut.PerspectiveState ~= nil then return M.WalkOut.PerspectiveState() end
    return nil
end

local function thirdPersonShown(state)
    return state ~= nil and state.mode == 'tps' and (state.body == 'proxy' or state.settled == true)
end

local function fps()
    if M.Sync ~= nil and type(M.Sync.Fps) == 'function' then
        local read, value = pcall(M.Sync.Fps)
        if read then return finite(value) end
    end
    return nil
end

--- The seconds since the key, as every line says them.
local function since(e, now)
    return ((now or M.Now()) - e.since) / 1000.0
end

local function mark(e, name, now)
    e.marks[#e.marks + 1] = { name = name, at = now or M.Now() }
end

-- ── the hold and the view ────────────────────────────────────────────────────

local function hold(e)
    local players = Open77.players
    if type(players) ~= 'table' or type(players.freezePosition) ~= 'function' then
        once('freeze', 'warn', 'no Open77.players.freezePosition on this client: the boarding step plays with the body free')
        return false
    end
    local read, ok, reason = M.Native('players.freezePosition', players.freezePosition, true)
    if not read or ok ~= true then
        Open77.log.warn(('boarding step %s: the body could not be held (%s): it plays free'):format(e.clip,
            tostring(read and reason or ok)))
        return false
    end
    local turning = false
    if type(players.freezeRotation) == 'function' then
        local turnRead, turnOk = M.Native('players.freezeRotation', players.freezeRotation, true)
        turning = turnRead and turnOk == true
    end
    e.held, e.heldAt = true, M.Now()
    Open77.log.info(('boarding step %s: the body held still %.1fs after the key (turning %s)'):format(e.clip,
        since(e), turning and 'held too' or 'free'))
    return true
end

local function letGo(e, why)
    if e == nil or not e.held then return end
    local players = Open77.players
    if type(players) == 'table' then
        if type(players.freezePosition) == 'function' then M.Native('players.freezePosition', players.freezePosition, false) end
        if type(players.freezeRotation) == 'function' then M.Native('players.freezeRotation', players.freezeRotation, false) end
    end
    e.held = false
    Open77.log.info(('boarding step %s: the body let go after %.1fs held (%s)'):format(e.clip,
        (M.Now() - (e.heldAt or M.Now())) / 1000.0, why))
end

-- Refusals of third person that do not pass (1.7.3): the server's policy, the
-- manifest, a host without it -- not another resource's lock of the moment.
local PERMANENT_REFUSALS = {
    refused_by_policy = true,
    ['permission_denied:perspective.policy'] = true,
    perspective_unavailable_on_this_host = true,
    ['no third person on this client'] = true,
}

local function viewOn(e, why)
    e.viewTries = (e.viewTries or 0) + 1
    local perspective = Open77.perspective
    if type(perspective) ~= 'table' or type(perspective.setThirdPerson) ~= 'function' then
        e.viewRefused = 'no third person on this client'
        once('view', 'warn', 'no Open77.perspective.setThirdPerson on this client: the boarding step is not seen on '
            .. 'this screen')
        return false
    end
    -- The stand-in made ahead (1.7.5) never lets go of a view this step holds.
    if M.StandIn ~= nil then M.StandIn.Yield('a boarding') end
    local read, ok, reason = M.Native('perspective.setThirdPerson', perspective.setThirdPerson, true, true)
    if not read or ok ~= true then
        e.viewRefused = tostring(read and reason or ok)
        Open77.log.warn(('boarding step %s: third person refused %s (%s, try %d): this screen cannot draw the stand-in '
            .. 'the clip plays on'):format(e.clip, why or '', e.viewRefused, e.viewTries))
        return false
    end
    e.viewHeld, e.viewRefused = true, nil
    e.viewAskedAt = e.viewAskedAt or M.Now()
    -- What the arbiter says the moment it is asked: a stand-in already made
    -- answers within a fifth of a second; the session's first is made now.
    local state = M.WalkOut ~= nil and M.WalkOut.PerspectiveState ~= nil and M.WalkOut.PerspectiveState() or nil
    local made = M.StandIn ~= nil and M.StandIn.Status() or nil
    e.madeAhead = made ~= nil and (made.warmed or made.seen) or nil
    Open77.log.info(('boarding step %s: third person asked %s, %.1fs after the key (the arbiter: %s; the stand-in %s); '
        .. 'the step waits %.1fs from the key at most for this screen to draw the stand-in'):format(e.clip, why or '',
        since(e), state ~= nil and ('%s, %s, %s, body %s'):format(tostring(state.mode), state.settled == true
            and 'settled' or tostring(state.transition), tostring(state.reason), tostring(state.body)) or 'not read',
        made == nil and 'not tracked' or (made.warmed and 'made ahead' or (made.seen and 'drawn earlier this session'
            or ('not made yet%s'):format(made.running and ', a try under way' or ''))),
        cfg().viewWait / 1000.0))
    return true
end

local function orbitOff(e)
    if e == nil or not e.orbiting then return end
    local camera = Open77.camera
    if type(camera) == 'table' and type(camera.clearOrbit) == 'function' then pcall(camera.clearOrbit) end
    e.orbiting = false
end

local function viewOff(e, why)
    if e == nil then return end
    orbitOff(e)
    if not e.viewHeld then return end
    local perspective = Open77.perspective
    if type(perspective) == 'table' and type(perspective.clearThirdPersonOverride) == 'function' then
        pcall(perspective.clearThirdPersonOverride)
    end
    e.viewHeld = false
    Open77.log.info(('boarding step %s: third person let go %.1fs after the key (%s)'):format(e.clip, since(e), why))
end

-- ── the weapon (1.7.2) ───────────────────────────────────────────────────────

--- Whether this game draws the body with a weapon out: true, false, or nil
--- when its state does not say.
local function weaponDrawn()
    local character = Open77.character
    if type(character) ~= 'table' or type(character.state) ~= 'function' then return nil end
    local read, state = pcall(character.state)
    if not read or type(state) ~= 'table' or type(state.weapon) ~= 'table' then return nil end
    if type(state.weapon.drawn) ~= 'boolean' then return nil end
    return state.weapon.drawn
end

--- Puts the weapon away (`Open77.weapons.holster`): the loadout stays.
-- @return boolean asked
local function holster(e, why)
    local weapons = Open77.weapons
    if type(weapons) ~= 'table' or type(weapons.holster) ~= 'function' then
        once('holster', 'warn', 'no Open77.weapons.holster on this client: a boarding with a weapon drawn plays no '
            .. 'clip')
        return false
    end
    local read, request, reason = M.Native('weapons.holster', weapons.holster)
    if not read or request == nil or request == false then
        Open77.log.warn(('boarding step %s: the weapon could not be holstered (%s)'):format(e.clip,
            tostring(read and reason or request)))
        return false
    end
    e.holsterAsks = (e.holsterAsks or 0) + 1
    Open77.log.info(('boarding step %s: a weapon drawn %.1fs after the key -- holstered (%s, request %s); the step '
        .. 'waits %.1fs at most for the hands to be empty'):format(e.clip, since(e), why, tostring(request),
        cfg().holsterWait / 1000.0))
    return true
end

-- ── the plan ─────────────────────────────────────────────────────────────────

--- The server's pose of the hull as a frame, the engine frame's box with it.
local function frameOfPose(pose, engine)
    if type(pose) ~= 'table' then return nil end
    local x, y, z, yaw = finite(pose.x), finite(pose.y), finite(pose.z), finite(pose.yaw)
    if x == nil or y == nil or z == nil or yaw == nil then return nil end
    local r = math.rad(yaw)
    local box = engine ~= nil and engine.boundsLocal and engine.bounds or nil
    return { x = x, y = y, z = z, fx = -math.sin(r), fy = math.cos(r), bounds = box, boundsLocal = box ~= nil,
        network = true }
end

local function poseOf(frame)
    if frame == nil then return nil end
    return { x = frame.x, y = frame.y, z = frame.z,
        yaw = (frame.fx ~= nil and frame.fy ~= nil) and (math.deg(math.atan(-frame.fx, frame.fy)) % 360.0) or nil }
end

--- Where the body stands off the plan's first spot, in the hull's own frame
--- (1.8.1, `OFF_SPOT_METRES`): `0.34 m off it, 0.34 m farther out from the hull
--- (across) and 0.01 m toward its tail`. Nil within `OFF_SPOT_METRES`, or with no
--- hull frame in the plan.
-- @param p table the plan `{ x, y, frame = { x, y, yaw } }`
-- @param at table|nil the body `{ x, y }`
-- @return string|nil the words
-- @return number|nil how far, metres
local function offSpot(p, at)
    if p == nil or at == nil or type(p.frame) ~= 'table' or p.frame.yaw == nil then return nil end
    local dx, dy = at.x - p.x, at.y - p.y
    local distance = math.sqrt(dx * dx + dy * dy)
    if distance <= OFF_SPOT_METRES then return nil end
    local r = math.rad(p.frame.yaw)
    local frame = { x = p.frame.x, y = p.frame.y, fx = -math.sin(r), fy = math.cos(r) }
    local spot, body = M.ToHullLocal(frame, p), M.ToHullLocal(frame, at)
    if spot == nil or body == nil then return ('%.2f m off it'):format(distance), distance end
    -- Across: + farther out from the hull's centre line than the spot.
    local across = math.abs(body.x) - math.abs(spot.x)
    local along = body.y - spot.y
    return ('%.2f m off it, %.2f m %s the hull (across) and %.2f m toward its %s'):format(distance, math.abs(across),
        across >= 0 and 'farther out from' or 'nearer', math.abs(along), along >= 0 and 'nose' or 'tail'), distance
end

--- The step's first spot: on the hull as this game should draw it, the door's
--- step within the clip's reach of the spot's ground.
-- @param payload table the server's ask
-- @return table|nil the plan `{ x, y, z, yaw, door, reach, width, ground, step, fit, turn, frame, frameSource, tried }`
-- @return string|nil why not
--- The hull as this game should draw it for an ask: this game's own frame when
--- it agrees with the network, else where the network (or the server's ask)
--- has it.
-- @return table|nil frame
-- @return string|nil its source
-- @return number|nil how far this game draws it from the network's, metres
local function hullFrame(payload)
    local id = payload.id
    local engine = M.HullFrame ~= nil and M.HullFrame(id) or nil
    local net = M.NetworkFrame ~= nil and M.NetworkFrame(id, engine) or nil
    local server = frameOfPose(payload.hull, engine)
    local frame, source = M.ExitFrame(engine, nil, net or server, position(), M.ExitSettings())
    local drift = (engine ~= nil and (net or server) ~= nil) and apart(engine, net or server) or nil
    return frame, source, drift
end

--- A door's clip: it starts where the entity stands and ends in the door.
local function doorClip(clip)
    return type(clip) == 'string' and M.WALK_CLIPS[clip] ~= nil and M.WALK_CLIPS[clip].first == true
        and not M.SeatClip(clip)
end

local function planStep(payload)
    local clip = payload.clip
    if not doorClip(clip) then
        return nil, ('the server named no enter clip (%s)'):format(tostring(clip))
    end
    if M.WalkOut == nil or M.WalkOut.PlanOn == nil then return nil, 'no exit plan on this client' end
    local frame, source, drift = hullFrame(payload)
    if frame == nil then return nil, 'the hull cannot be read on this game' end
    local was = { vehicleId = id, seat = payload.seat, record = payload.record }
    local door = M.SeatDoor(payload.record, payload.seat)
    local walk, exit = M.WalkOutSettings(), M.ExitSettings()
    local best, relaxed, tried = nil, nil, {}
    -- Whether every turn tried found the door's step too HIGH over its ground:
    -- a hull over its gear (1.7.1), which the server may set down.
    local allHigh = true
    for _, turn in ipairs(M.STEP_TURNS) do
        local p, why = M.WalkOut.PlanOn(was, frame, exit, M.GroundBelow, walk, clip, nil, turn)
        if p == nil then
            allHigh = false
            tried[#tried + 1] = ('%+d deg: %s'):format(turn, tostring(why))
        else
            local step = M.StepHeight(frame.z, door, p.ground)
            local fit = M.StepFit(clip, step)
            p.step, p.fit = step, fit
            if fit ~= 'high' then allHigh = false end
            tried[#tried + 1] = ('%+d deg: the step %s (%s)'):format(turn,
                step ~= nil and ('%.2f m up'):format(step) or 'not known', fit or 'not judged')
            if fit == nil or fit == 'in' then
                best = p
                break
            end
            if fit == 'relaxed' and relaxed == nil then relaxed = p end
        end
    end
    local p = best or relaxed
    if p == nil then
        return nil, ('no first spot within the clip\'s reach (%s)'):format(table.concat(tried, '; ')),
            { frame = frame, high = allHigh and #tried > 0 }
    end
    p.frame, p.frameSource, p.tried = poseOf(frame), source, table.concat(tried, '; ')
    -- Where the network has the hull against where this game draws it, for the log.
    p.drift = drift
    return p, nil, { frame = frame, high = false }
end

--- INTO THE SEAT (1.7.7): the seat clip's first spot -- its end on the seat's
--- slot of the hull as this game should draw it -- and the seat's height over
--- that spot's ground within the clip's (`M.SeatFit`).
-- @param payload table the server's ask
-- @return table|nil the plan `{ x, y, z, yaw, door (the seat), seat, seatYaw, reach, ground, height, fit, frame,
--   frameSource, drift, source, turn }`
-- @return string|nil why not
-- @return table|nil `{ frame, high }`: `high`, the seat too high over the spot's ground
local function planSit(payload)
    local clip = payload.clip
    if not M.SeatClip(clip) then return nil, ('the server named no seat clip (%s)'):format(tostring(clip)) end
    local sit = M.SeatSit(payload.record, payload.seat)
    if sit == nil then return nil, ('no slot known for %s of %s'):format(tostring(payload.seat), tostring(payload.record)) end
    local frame, source, drift = hullFrame(payload)
    if frame == nil then return nil, 'the hull cannot be read on this game' end
    local s = M.SitPlan(frame, sit, clip)
    if s == nil then return nil, 'its frame could not be read', { frame = frame } end
    local ground = M.GroundBelow(s.x, s.y, frame.z + 2.0)
    if ground == nil then
        return nil, ('no ground at the first spot (%.1f, %.1f)'):format(s.x, s.y), { frame = frame }
    end
    local z = ground + M.WalkOutSettings().lift
    local height = s.seat.z - z
    local fit = M.SeatFit(clip, height)
    if fit == 'high' or fit == 'low' then
        return nil, ('the seat %.2f m over the first spot\'s ground, the clip sits down %.2f m up (%s)'):format(height,
            M.WALK_CLIPS[clip].rise, fit == 'high' and 'too high' or 'too low'), { frame = frame, high = fit == 'high' }
    end
    return { x = s.x, y = s.y, z = z, yaw = s.yaw, door = { x = s.seat.x, y = s.seat.y, z = s.seat.z }, seat = s.seat,
        seatYaw = s.seatYaw, reach = s.reach, ground = ground, height = height, fit = fit, turn = 0.0,
        source = 'the seat\'s slot', frame = poseOf(frame), frameSource = source, drift = drift,
        tried = ('the seat %.2f m over the ground (%s)'):format(height, fit) }, nil, { frame = frame, high = false }
end

-- ── the steps ────────────────────────────────────────────────────────────────

local function send(body)
    local read, sent, reason = pcall(TriggerServerEvent, M.Event.ENTER_READY, body)
    if not read or sent == false then
        Open77.log.warn(('boarding step: the word to the server was not sent (%s)'):format(
            tostring(read and (reason or 'refused') or sent)))
        return false
    end
    return true
end

--- No step for this ask: the server seats the body at once.
local function none(token, why, clip)
    counts.none = counts.none + 1
    send({ token = token, clip = false, why = tostring(why):sub(1, 160) })
    Open77.log.info(('boarding step%s: none -- %s; the server seats the body at once'):format(
        clip ~= nil and (' ' .. clip) or '', tostring(why)))
end

--- THE HULL OVER ITS GEAR (1.7.1): the static ground under each gear foot of
--- a known airframe, as this game measures it from the hull it planned on --
--- what server/land.lua lowers a hull by. `{ grounds, x, y, z, hang, feet }`,
--- or nil for an airframe whose gear is not known; `hang` how far the gear
--- stands over its highest foot's ground (nil: a foot over nothing).
local function gearMeasure(frame, record)
    local land = M.AirframeLand(record)
    if land == nil or frame == nil or frame.fx == nil or frame.fy == nil then return nil end
    local feet = M.GearPoints({ x = frame.x, y = frame.y }, { x = frame.fx, y = frame.fy }, land)
    if feet == nil then return nil end
    local grounds, parts, highest, hole = {}, {}, nil, false
    for index, foot in ipairs(feet) do
        local z = M.GroundBelow(foot.x, foot.y, frame.z + 1.0)
        grounds[index] = z
        parts[index] = z ~= nil and ('%.2f'):format(z) or 'none'
        if z == nil then hole = true else highest = highest == nil and z or math.max(highest, z) end
    end
    local hang = (not hole and highest ~= nil) and (frame.z - land.height - highest) or nil
    return { grounds = grounds, x = frame.x, y = frame.y, z = frame.z, hang = hang, feet = table.concat(parts, ', ') }
end

--- No step yet: the hull hangs over its gear, and the server is asked to set
--- it down first (it asks again once it has).
local function askSetDown(token, why, clip, measure)
    counts.setDown = (counts.setDown or 0) + 1
    send({ token = token, clip = false, why = tostring(why):sub(1, 160),
        setDown = { grounds = measure.grounds, x = measure.x, y = measure.y, z = measure.z } })
    Open77.log.info(('boarding step%s: none yet -- %s; the hull hangs %.2f m over its gear as this game measures it '
        .. '(its origin at %.2f, the ground under its feet %s): the server is asked to set it down on its gear, '
        .. 'then to ask for the step again'):format(clip ~= nil and (' ' .. clip) or '', tostring(why), measure.hang,
        measure.z, measure.feet))
end

-- A second ask after the server set the hull down, waiting for this game to
-- draw it there: `{ payload, token, since, untilAt, nextAt, why }`, or nil.
local pending = nil
-- How often a waiting second ask plans again (each plan casts a ray a turn).
local PENDING_EVERY_MS = 200
-- A step only within the relaxed reach on a hull hanging this far over its
-- gear is set down first too: on its gear, the step is within the clip's own.
local SET_DOWN_RELAXED_HANG = 0.15

--- A second ask on a hull this game still draws over its gear: waited for
--- (`SET_DOWN_LOOK_MS` from the first look), planned again every
--- `PENDING_EVERY_MS`.
-- @param payload table the ask as the server sent it
-- @return boolean true while it waits; false once the wait is over
-- The plan of a fallback, made on the watch's next pass (`E.AskDeferred`).
local deferredAsk = nil
-- What follows a plan (`E.Ask`, `E.AskDeferred`), defined after `place`.
local proceed

local function waitDrawnDown(payload, token, why, settings)
    local now = M.Now()
    if pending == nil or pending.token ~= token then
        pending = { payload = payload, token = token, since = now, untilAt = now + settings.setDownLook }
        Open77.log.info(('boarding step %s: the server set the hull down, and this game still draws it over its gear '
            .. '(%s): planned again every %d ms, %.1fs at most'):format(tostring(payload.clip), tostring(why),
            PENDING_EVERY_MS, settings.setDownLook / 1000.0))
    end
    if now < pending.untilAt then
        pending.nextAt, pending.why = now + PENDING_EVERY_MS, why
        return true
    end
    return false
end

local function summary(e, how, now)
    local parts = {}
    local last = e.since
    for _, m in ipairs(e.marks) do
        parts[#parts + 1] = ('%s +%.2fs'):format(m.name, (m.at - last) / 1000.0)
        last = m.at
    end
    local rate = fps()
    return ('boarding step %s over (%s) after %.1fs: %s; %d placement(s), %d turn(s) back, the body %s, held %s%s')
        :format(e.clip, how, since(e, now), #parts > 0 and table.concat(parts, ', ') or 'nothing done',
            e.placements, e.facingBack, e.good >= 1 and 'stood' or 'never stood', e.wasHeld and 'yes' or 'no',
            rate ~= nil and (', %.0f frames a second'):format(rate) or '')
end

--- Everything this half holds is let go: the hold, the view, the curtain.
local function release(e, why)
    letGo(e, why)
    viewOff(e, why)
    if e.curtained and M.Curtain ~= nil and M.Curtain() ~= nil then M.CurtainUp('boarding step: ' .. why, nil, false) end
    e.curtained = false
end

--- Gives the step up: let go of everything, and -- when the server is still
--- owed a word -- tell it there is no step (it seats the body at once).
local function giveUp(why, tellServer)
    local e = enter
    if e == nil then return end
    enter = nil
    counts.abandoned = counts.abandoned + 1
    release(e, why)
    local stepped = e.phase == 'playing' or e.phase == 'parking' or e.phase == 'seating' or e.phase == 'lifting'
    if tellServer ~= false and not stepped then
        send({ token = e.token, clip = false, why = tostring(why):sub(1, 160) })
    end
    Open77.log.warn(('boarding step %s given up %.1fs after the key: %s%s'):format(e.clip, since(e), why,
        (tellServer ~= false and not stepped) and ' -- the server seats the body at once' or ''))
    Open77.log.info(summary(e, 'given up', M.Now()))
end

--- Puts the body on the first spot facing the door, with the image on.
local function place(e, why)
    local travel = Open77.travel
    if type(travel) ~= 'table' or type(travel.teleport) ~= 'function' then
        giveUp('no Open77.travel.teleport on this client')
        return false
    end
    letGo(e, 'a move: ' .. why)
    local p = e.plan
    local read, ok, reason = M.Native('travel.teleport', travel.teleport, p.x, p.y, p.z, p.yaw)
    if not read or ok ~= true then
        giveUp(('the body could not be put on the first spot (%s)'):format(tostring(read and reason or ok)))
        return false
    end
    e.placements = e.placements + 1
    e.placedAt, e.movedPass, e.good, e.holdGood = M.Now(), pass, 0, 0
    if e.phase ~= 'place' then e.phase = 'place' end
    Open77.log.info(('boarding step %s: the body put on the first spot at %.2f, %.2f, %.2f facing %.0f deg (%s, '
        .. 'placement %d, %.1fs after the key)'):format(e.clip, p.x, p.y, p.z, p.yaw, why, e.placements, since(e)))
    return true
end

--- What follows a plan (or its failure): the hull over its gear, the second
--- ask's wait, the move to the first spot and the stand-in asked for.
-- @param payload table the ask this plan is for (the door's clip's copy for a fallback)
-- @param original table the ask as the server sent it
-- @param token string
-- @param p table|nil the plan
-- @param why string|nil why there is none
-- @param info table|nil `{ frame, high }`
-- @param sitWhy string|nil why not into the seat (the door's clip instead)
proceed = function(payload, original, token, p, why, info, sitWhy)
    local settings = cfg()
    if p == nil then
        -- THE HULL OVER ITS GEAR (1.7.1): every step too high, the gear known.
        if info ~= nil and info.high and settings.setDown then
            if payload.again == true then
                -- The server set it down: this game may still draw it where it hung.
                if waitDrawnDown(original, token, why, settings) then return end
                pending = nil
                return none(token, ('%s -- still, %.1fs after the server set the hull down'):format(tostring(why),
                    settings.setDownLook / 1000.0), payload.clip)
            end
            local measure = gearMeasure(info.frame, payload.record)
            if measure ~= nil and measure.hang ~= nil and measure.hang > 0.05 then
                return askSetDown(token, why, payload.clip, measure)
            end
            if measure ~= nil then
                why = ('%s; the hull stands on its gear as this game measures it (%s): not to be set down'):format(
                    tostring(why), measure.hang ~= nil and ('%.2f m over it'):format(measure.hang)
                        or ('a foot over nothing: ' .. measure.feet))
            end
        end
        if sitWhy ~= nil then why = ('%s (and not into the seat: %s)'):format(tostring(why), sitWhy) end
        return none(token, why, payload.clip)
    end
    if pending ~= nil and pending.token == token then
        Open77.log.info(('boarding step %s: this game draws the hull on its gear %.1fs after the server\'s second ask')
            :format(tostring(payload.clip), (M.Now() - pending.since) / 1000.0))
        pending = nil
    end
    -- Only the relaxed reach, on a hull over its gear: set down first as well.
    if p.fit == 'relaxed' and settings.setDown and payload.again ~= true and info ~= nil then
        local measure = gearMeasure(info.frame, payload.record)
        if measure ~= nil and measure.hang ~= nil and measure.hang > SET_DOWN_RELAXED_HANG then
            return askSetDown(token, p.seat ~= nil
                and ('the seat %.2f m over the first spot, only within the seat clip\'s relaxed band'):format(p.height or -1)
                or ('the door\'s step %.2f m up, only within the clip\'s relaxed reach'):format(p.step or -1),
                payload.clip, measure)
        end
    end
    local at = position()
    if at == nil then return none(token, 'the body cannot be read', payload.clip) end
    local distance = apart(at, p)
    if distance > settings.moveMax then
        return none(token, ('the body is %.1f m from the step\'s first spot (at most %.1f)'):format(distance,
            settings.moveMax), payload.clip)
    end
    -- An exit's view still held on this screen is let go: the boarding takes the view.
    if M.WalkOut ~= nil and M.WalkOut.ReleaseView ~= nil then M.WalkOut.ReleaseView('a boarding begins') end
    local now = M.Now()
    enter = { token = token, id = payload.id, seat = payload.seat, record = payload.record, clip = payload.clip,
        since = now, askMs = math.max(1000, math.floor(finite(payload.askMs) or settings.ask)),
        doorOpenAt = now + math.max(0, math.floor(finite(payload.doorOpenMs) or settings.doorOpen)),
        durationMs = math.floor(finite(payload.durationMs) or (M.WALK_CLIPS[payload.clip].seconds * 1000)),
        plan = p, phase = 'place', placements = 0, facingBack = 0, good = 0, holdGood = 0, lines = 0, marks = {},
        -- 1.7.7: why not into the seat (the door's clip instead), and the
        -- camera's swing for this clip.
        sitWhy = sitWhy, orbit = M.SeatClip(payload.clip) and settings.sitOrbit or settings.orbit }
    counts.asked = counts.asked + 1
    if M.SeatClip(payload.clip) then counts.sit = (counts.sit or 0) + 1 end
    if sitWhy ~= nil then counts.fellBack = (counts.fellBack or 0) + 1 end
    local yaw = bodyYaw()
    if p.seat ~= nil then
        Open77.log.info(('boarding step %s asked for %s (%s of %s): into the seat -- the first spot at %.2f, %.2f, %.2f '
            .. 'facing %.0f deg, %.2f m from the seat\'s slot (%.2f, %.2f, %.2f, facing %.0f), the seat %.2f m over the '
            .. 'ground there (the clip sits down %.2f m up: %s); planned on the %s frame (%.2f, %.2f, %.2f heading '
            .. '%.0f%s); the body %.1f m from it, facing %s'):format(enter.clip, tostring(payload.id),
            tostring(payload.seat), tostring(payload.record), p.x, p.y, p.z, p.yaw, p.reach, p.seat.x, p.seat.y,
            p.seat.z, p.seatYaw, p.height, M.WALK_CLIPS[enter.clip].rise, tostring(p.fit), tostring(p.frameSource),
            p.frame.x, p.frame.y, p.frame.z, p.frame.yaw or 0,
            p.drift ~= nil and (', the engine\'s %.2f m off the network\'s'):format(p.drift) or '', distance,
            yaw ~= nil and ('%.0f deg'):format(yaw) or 'an unread heading'))
    else
        Open77.log.info(('boarding step %s asked for %s (%s of %s): the first spot at %.2f, %.2f, %.2f facing %.0f deg, '
            .. '%.2f m out from the door point (%.2f, %.2f; the door %.2f m from the centre line, %s), the ground %.2f, '
            .. 'the door\'s step %s; planned on the %s frame (%.2f, %.2f, %.2f heading %.0f%s); the body %.1f m from '
            .. 'it, facing %s; tried %s%s'):format(enter.clip, tostring(payload.id), tostring(payload.seat),
            tostring(payload.record), p.x, p.y, p.z, p.yaw, p.reach, p.door.x, p.door.y, p.width, tostring(p.source),
            p.ground, p.step ~= nil and ('%.2f m over it (%s)'):format(p.step, tostring(p.fit)) or 'not known',
            tostring(p.frameSource), p.frame.x, p.frame.y, p.frame.z, p.frame.yaw or 0,
            p.drift ~= nil and (', the engine\'s %.2f m off the network\'s'):format(p.drift) or '', distance,
            yaw ~= nil and ('%.0f deg'):format(yaw) or 'an unread heading', p.tried,
            sitWhy ~= nil and ('; not into the seat: ' .. sitWhy) or ''))
    end
    if M.CurtainBegin ~= nil then M.CurtainBegin('a boarding') end
    if M.Shots ~= nil then
        M.Shots.Begin('own', ('boarding %s of %s'):format(tostring(payload.seat), tostring(payload.id)))
        M.Shots.Take('ask', 0, E.ShotMeta)
    end
    -- A WEAPON DRAWN (1.7.2): put away now, while the body is placed and held.
    if settings.holster and weaponDrawn() == true and holster(enter, 'at the key') then
        enter.holstering = { since = now }
        counts.holstered = counts.holstered + 1
    end
    if distance <= settings.arrive and yaw ~= nil and (M.YawApart(yaw, p.yaw) or 180) <= settings.facing then
        enter.phase, enter.arrivedAt = 'stand', now
        Open77.log.info(('boarding step %s: the body already stands on the first spot, facing the door'):format(enter.clip))
        mark(enter, 'on the spot', now)
    elseif not place(enter, 'the first spot') then
        return
    end
    -- THE STAND-IN FIRST (1.7.3): third person asked now, after the move (a
    -- teleport is applied on the next frame; the arbiter takes several), so
    -- the stand-in is made while the body is placed, held and its weapon put
    -- away. The step waits for it from the key (`VIEW_WAIT_MS`).
    local e = enter
    if e ~= nil and settings.viewEarly then
        e.viewSince = e.since
        if viewOn(e, 'at the key') then
            mark(e, 'view asked', now)
        elseif settings.viewRequired and PERMANENT_REFUSALS[tostring(e.viewRefused)] then
            -- This server or this game never gives third person: no step
            -- this screen could show, and no hold for nothing.
            return giveUp(('third person refused (%s): the stand-in body the clip plays on is never drawn on this '
                .. 'screen -- the plain boarding'):format(tostring(e.viewRefused)))
        end
    end
end

--- The server asks for the step (`ENTER`).
-- @param payload table `{ token, id, seat, record, clip, hull, durationMs, doorOpenMs, askMs }`
function E.Ask(payload)
    if type(payload) ~= 'table' or payload.token == nil then return end
    local settings = cfg()
    local token = tostring(payload.token)
    if enter ~= nil then
        if enter.token == token then return end
        giveUp('a new ask came (' .. token .. ')', false)
    end
    -- A fallback still waiting for its pass belongs to an older ask.
    if deferredAsk ~= nil and deferredAsk.token ~= token then deferredAsk = nil end
    if settings.off then return none(token, 'the boarding step is off on this client') end
    -- A GAME WITHOUT THE CLIPS (1.7.2): nothing would be drawn -- no hold, no
    -- step, the seat at once.
    if M.AnimMissing ~= nil then
        local missing, reason = M.AnimMissing()
        if missing then
            counts.noClips = counts.noClips + 1
            if M.FilesMissingNotice ~= nil then M.FilesMissingNotice('a boarding', reason) end
            return none(token, ('this game has no AV animation package (%s): its archive is not in the game it '
                .. 'started with -- restart it through the Open77 launcher'):format(tostring(reason)), payload.clip)
        end
    end
    if mySeat() ~= nil then return none(token, 'already seated') end
    if not alive() then return none(token, 'the body is down') end
    if M.OwnExitBusy ~= nil and M.OwnExitBusy() then
        return none(token, 'this player\'s exit is still under way on this screen (its guard, its curtain or its clip)')
    end
    -- The ask as the server sent it: a second ask waiting for the hull drawn on
    -- its gear plans it again from the start (the seat first).
    local original = payload
    -- INTO THE SEAT (1.7.7): the seat clip first; its first spot without the
    -- seat's height over its ground, the door's clip (`fallback`).
    local p, why, info, sitWhy = nil, nil, nil, nil
    if M.SeatClip(payload.clip) then
        p, why, info = planSit(payload)
        if p == nil then
            sitWhy = why
            -- The seat too high over the spot's ground on a hull over its gear:
            -- set down first (the second ask finds the seat at its height).
            if info ~= nil and info.high and settings.setDown then
                local measure = gearMeasure(info.frame, payload.record)
                if measure ~= nil and measure.hang ~= nil and measure.hang > 0.05 then
                    if payload.again ~= true then return askSetDown(token, why, payload.clip, measure) end
                    -- The server set it down: this game may still draw it where it hung.
                    if waitDrawnDown(original, token, why, settings) then return end
                end
            end
            if not doorClip(payload.fallback) then return none(token, why, payload.clip) end
            -- The door's clip is planned on the watch's next pass, a resume of
            -- its own: both plans in one ran past the host's instruction
            -- budget on a slow game (the suite's 10 000).
            Open77.log.info(('boarding step %s: not into the seat -- %s; the door\'s clip %s instead (planned on '
                .. 'the next pass)'):format(payload.clip, tostring(why), payload.fallback))
            local door = {}
            for k, v in pairs(payload) do door[k] = v end
            door.clip, door.durationMs, door.fallback, door.fallbackMs = payload.fallback, payload.fallbackMs, nil, nil
            deferredAsk = { payload = door, original = original, token = token, sitWhy = sitWhy, at = M.Now() }
            return
        end
        return proceed(payload, original, token, p, why, info, nil)
    end
    p, why, info = planStep(payload)
    return proceed(payload, original, token, p, why, info, nil)
end

--- THE DOOR'S CLIP AFTER THE SEAT'S (1.7.7): the fallback planned on the
--- watch's next pass, a resume of its own.
-- @param d table `{ payload, original, token, sitWhy, at }`
function E.AskDeferred(d)
    if enter ~= nil then return end
    if mySeat() ~= nil then return none(d.token, 'already seated', d.payload.clip) end
    if not alive() then return none(d.token, 'the body is down', d.payload.clip) end
    local p, why, info = planStep(d.payload)
    return proceed(d.payload, d.original, d.token, p, why, info, d.sitWhy)
end

-- ── the view before the seat (1.7.8) ─────────────────────────────────────────
-- 1.7.7 took the seat while this screen still drew the stand-in: the stand-in
-- stood back up on the clip's first spot, beside the AV, and stayed there in
-- the pilot's view until the AV flew off (Staging, 2026-10-29: "after the body
-- sits down it gets moved back out until you take over the av"; back on the
-- first spot, with its head, in the AV's chase camera). The stand-in is put
-- away while the body is still on foot, and only then is the seat asked.

--- The seat asked of the server (`ENTER_SEAT`): the stand-in is put away, or
--- `PARK_WAIT_MS` went by without it.
local function askSeat(e, now, parked, lineView)
    local settings = cfg()
    e.phase, e.seatingSince = 'seating', now
    mark(e, parked and 'stand-in away' or 'stand-in wait over', now)
    local parkMs = now - (e.parkingSince or now)
    local read, sent = pcall(TriggerServerEvent, M.Event.ENTER_SEAT, { token = e.token, parked = parked == true,
        parkMs = parkMs })
    local line = ('boarding step %s: the seat asked of the server %.2fs after the view was let go, %.2fs before the '
        .. 'clip\'s end -- %s (%s)%s'):format(e.clip, parkMs / 1000.0, ((e.playing and e.playing.untilAt or now) - now)
        / 1000.0, parked and 'the stand-in is put away' or ('the stand-in still not put away after %.1fs'):format(
        settings.parkWait / 1000.0), tostring(lineView), (read and sent ~= false) and '' or ' -- NOT SENT')
    if parked then Open77.log.info(line) else Open77.log.warn(line) end
    if settings.seatCurtain and M.CurtainDown ~= nil then
        e.curtained = M.CurtainDown('the boarding step: the seat') == true or e.curtained
    end
    if M.Shots ~= nil then M.Shots.Take('seat', 0, E.ShotMeta) end
end

--- `VIEW_LEAD_MS` before the clip's end: the hold and third person let go --
--- first person FORCED rather than the override cleared, so a player who walks
--- in third person has the stand-in put away too (the override is cleared once
--- seated, `E.Seated`) -- and the seat asked once the stand-in is away.
local function parkView(e, now)
    local settings = cfg()
    letGo(e, 'the view goes back before the seat')
    orbitOff(e)
    e.parkingSince = now
    if not e.viewHeld then
        -- Third person was never held here (refused): nothing to put away.
        e.phase = 'parking'
        return askSeat(e, now, true, 'no third person held')
    end
    -- THE SEAT UNDER A SHORT FADE (1.8.2): first person, forced below, is drawn
    -- from where the player entity stands -- the clip's first spot, outside the
    -- door -- until the seat. The screen goes black first, and stays black
    -- through the stand-in put away and the seat (`E.KeepCurtain`).
    if settings.seatCurtain and M.CurtainDown ~= nil and not e.curtained then
        local down = M.CurtainDown('the boarding step: the view before the seat', settings.seatFadeOut) == true
        e.curtained = down or e.curtained
        if down then
            e.seatFadeAt = now
            Open77.log.info(('boarding step %s: the screen fades out (%d ms) over the change to first person and the '
                .. 'seat -- first person is drawn from the clip\'s first spot, outside the door, until the seat; the '
                .. 'image back %d ms after the seat'):format(e.clip, settings.seatFadeOut, settings.seatSettle))
        else
            Open77.log.warn(('boarding step %s: no fade over the change to first person (the curtain was refused or '
                .. 'spent): first person shows the clip\'s first spot, outside the door, until the seat'):format(e.clip))
        end
    end
    local perspective = Open77.perspective
    local forced = false
    if type(perspective) == 'table' and type(perspective.setThirdPerson) == 'function' then
        local read, ok, reason = M.Native('perspective.setThirdPerson', perspective.setThirdPerson, false, true)
        forced = read and ok == true
        if not forced then
            Open77.log.warn(('boarding step %s: first person could not be forced before the seat (%s): the override '
                .. 'is let go instead'):format(e.clip, tostring(read and reason or ok)))
        end
    end
    if not forced then viewOff(e, 'the view goes back before the seat') end
    e.phase = 'parking'
    mark(e, 'view back', now)
    Open77.log.info(('boarding step %s: third person let go %.2fs before the clip\'s end (%.1fs after the key) -- '
        .. 'first person %s, so the stand-in is put away before the seat; the seat is asked once it is, %.1fs at most')
        :format(e.clip, ((e.playing and e.playing.untilAt or now) - now) / 1000.0, since(e, now),
            forced and 'forced' or 'as the player has it', settings.parkWait / 1000.0))
    if M.Shots ~= nil then M.Shots.Take('view back', 0, E.ShotMeta) end
end

-- THE SEAT, WATCHED (1.7.8): where this game draws the body for `SEAT_WATCH_MS`
-- after the seat -- its hips against the seat's slot and the clip's first
-- spot, the view, the hull -- each change a line, then one line for all of it.
local SEAT_WATCH_MS = 4000
local SEAT_WATCH_EVERY_MS = 250
local SEAT_WATCH_LINES = 12
local SEAT_WATCH_GRACE_MS = 300
local seatWatch = nil

--- The local body's hips as this game draws them, or nil and why.
local function hipsNow()
    local character = Open77.character
    if type(character) ~= 'table' or type(character.bonePosition) ~= 'function' then return nil, 'no bonePosition' end
    local read, hips, reason = M.Native('character.bonePosition', character.bonePosition, nil, 'hips')
    if not read or type(hips) ~= 'table' then return nil, tostring(read and reason or hips) end
    local x, y, z = finite(hips.x), finite(hips.y), finite(hips.z)
    if x == nil or y == nil or z == nil then return nil, 'unreadable' end
    return { x = x, y = y, z = z }
end

local function seatWatchLook(w, now)
    local hips, hipsWhy = hipsNow()
    local at = position()
    local state = perspectiveState()
    local frame = M.HullFrame ~= nil and M.HullFrame(w.id) or nil
    local parts = {}
    if hips ~= nil then
        if w.seat ~= nil then
            local d = math.sqrt((hips.x - w.seat.x) ^ 2 + (hips.y - w.seat.y) ^ 2)
            parts[#parts + 1] = ('the hips %.1f m from the seat, %.1f m over it'):format(d, hips.z - (w.seat.z or hips.z))
        end
        parts[#parts + 1] = ('%.1f m from the first spot'):format(apart(hips, w.first))
    else
        parts[#parts + 1] = 'the hips not read (' .. tostring(hipsWhy) .. ')'
    end
    if at ~= nil and w.seat ~= nil then parts[#parts + 1] = ('the body %.1f m from the seat'):format(apart(at, w.seat)) end
    if state ~= nil then
        parts[#parts + 1] = ('the view %s/%s/%s'):format(tostring(state.mode), tostring(state.camera), tostring(state.body))
    end
    if frame ~= nil and w.hull ~= nil then
        local moved = apart(frame, w.hull)
        if moved >= 0.5 then parts[#parts + 1] = ('the AV moved %.1f m'):format(moved) end
    end
    local text = table.concat(parts, ', ')
    w.looks = w.looks + 1
    -- The mount moves the body a frame or two after the seat's word (1.7.10:
    -- 2.4 m off at 0.05 s, in the seat at 0.44 s, Staging, 2026-10-29): only a
    -- look from `SEAT_WATCH_GRACE_MS` on counts against it.
    if hips ~= nil and w.seat ~= nil and now - w.since >= SEAT_WATCH_GRACE_MS then
        local d = math.sqrt((hips.x - w.seat.x) ^ 2 + (hips.y - w.seat.y) ^ 2)
        w.worst = math.max(w.worst or 0, d)
        if d > 1.0 then w.outLooks = (w.outLooks or 0) + 1 end
    end
    if text ~= w.last and w.lines < SEAT_WATCH_LINES then
        w.last, w.lines = text, w.lines + 1
        Open77.log.info(('boarding step %s, seated %.2fs: %s'):format(w.clip, (now - w.since) / 1000.0, text))
    end
end

local function seatWatchTick(now)
    local w = seatWatch
    if w == nil or now < w.nextAt then return end
    w.nextAt = now + SEAT_WATCH_EVERY_MS
    seatWatchLook(w, now)
    if now >= w.untilAt then
        seatWatch = nil
        local line = ('boarding step %s: the seat watched %.1fs, %d look(s)%s'):format(w.clip, (now - w.since) / 1000.0,
            w.looks, w.seat ~= nil and (': the hips at most %.1f m from the seat, %d look(s) over a metre from it')
                :format(w.worst or 0, w.outLooks or 0) or '')
        if (w.outLooks or 0) > 0 then Open77.log.warn(line .. ' -- THE BODY DRAWN AWAY FROM ITS SEAT')
        else Open77.log.info(line) end
    end
end

-- THE DOOR AS THIS GAME DRAWS IT, ABOARD (1.7.10). The pilot saw the AV's
-- door open through a whole flight the server had closed it for (Staging,
-- 2026-10-29, 17:25), and nothing on this screen said so. From any seat in an
-- airframe whose door slots are known, this game's own drawing of the door is
-- read -- its slot's height in the hull's frame: 0.13 m up shut, 0.65 m down
-- open, the step folded out -- every `DOOR_WATCH_EVERY_MS` for the first
-- `DOOR_WATCH_EARLY_MS`, then every `DOOR_WATCH_LATE_EVERY_MS`, until the seat
-- is left or `DOOR_WATCH_MS` have passed. Each change is a line (drawn, and as
-- the network holds it), a door drawn open while the AV moves faster than
-- `DOOR_WATCH_FLIGHT_SPEED` is a warning, and the end is a summary.
local DOOR_WATCH_MS = 120000
local DOOR_WATCH_EARLY_MS = 20000
local DOOR_WATCH_EVERY_MS = 1000
local DOOR_WATCH_LATE_EVERY_MS = 5000
local DOOR_WATCH_FLIGHT_SPEED = 2.0
local doorWatch = nil
local doorWatchHull = nil

--- The door as this game draws it: 'open' | 'shut' | 'moving', the slot, or nil and why.
local function doorDrawn(w)
    if M.WalkOut == nil or type(M.WalkOut.DoorSlot) ~= 'function' or M.HullFrame == nil then
        return nil, 'no door read on this client'
    end
    local frame = M.HullFrame(w.id)
    if frame == nil then return nil, 'the hull frame cannot be read' end
    local slot, why = M.WalkOut.DoorSlot(w.id, w.record, frame)
    if slot == nil or type(slot.at) ~= 'table' or tonumber(slot.at.z) == nil then return nil, why or 'no slot' end
    local up = tonumber(slot.at.z)
    return up < -0.45 and 'open' or (up > -0.25 and 'shut' or 'moving'), slot, frame
end

--- The door as the network holds it: true (open) | false | nil (unknown).
local function doorHeld(w)
    local api = Open77.vehicles
    if type(api) ~= 'table' or type(api.isDoorOpen) ~= 'function' or w.door == nil then return nil end
    local read, open = pcall(api.isDoorOpen, M.IdNumber ~= nil and M.IdNumber(w.id) or w.id, w.door)
    if not read then return nil end
    if open == true then return true elseif open == false then return false end
    return nil
end

local function doorWatchLook(w, now)
    local drawn, slot, frame = doorDrawn(w)
    local held = doorHeld(w)
    local speed = nil
    if frame ~= nil and w.lastFrame ~= nil and now > w.lastFrameAt then
        speed = apart(frame, w.lastFrame) / ((now - w.lastFrameAt) / 1000.0)
    end
    if frame ~= nil then w.lastFrame, w.lastFrameAt = { x = frame.x, y = frame.y }, now end
    w.looks = w.looks + 1
    local moving = speed ~= nil and speed > DOOR_WATCH_FLIGHT_SPEED
    if drawn == 'open' and moving then
        w.openFlying = w.openFlying + 1
        if w.openFlying >= 2 and not w.warned then
            w.warned = true
            Open77.log.warn(('door watch: aboard %s (%s), %.0fs after the seat -- THE DOOR DRAWN OPEN IN FLIGHT (%.1f m/s; '
                .. 'slot %s %.2f m up in the hull\'s frame; the network holds it %s)'):format(tostring(w.id), tostring(w.seat),
                (now - w.since) / 1000.0, speed, tostring(type(slot) == 'table' and slot.name or nil),
                type(slot) == 'table' and slot.at.z or 0,
                held == nil and 'unknown' or (held and 'OPEN' or 'shut')))
        end
    end
    local key = tostring(drawn) .. '|' .. tostring(held)
    if key ~= w.last then
        w.last = key
        w.changes = w.changes + 1
        if w.changes <= 12 then
            Open77.log.info(('door watch: aboard %s (%s), %.1fs after the seat -- the %s door as this game draws it: %s%s; '
                .. 'the network holds it %s%s'):format(tostring(w.id), tostring(w.seat), (now - w.since) / 1000.0,
                tostring(w.door), drawn ~= nil and drawn:upper() or 'not read',
                type(slot) == 'table' and (' (slot %s %.2f m up, %.2f across)'):format(slot.name, slot.at.z, slot.at.x)
                    or (' (' .. tostring(slot) .. ')'),
                held == nil and 'unknown' or (held and 'open' or 'shut'),
                speed ~= nil and (', the AV at %.1f m/s'):format(speed) or ''))
        end
    end
end

local function doorWatchEnd(w, now, why)
    doorWatch = nil
    local line = ('door watch over (%s) after %.0fs aboard %s: %d look(s), %d change(s), drawn open in flight %d look(s)')
        :format(why, (now - w.since) / 1000.0, tostring(w.id), w.looks, w.changes, w.openFlying)
    if w.openFlying >= 2 then Open77.log.warn(line .. ' -- THE DOOR DRAWN OPEN IN FLIGHT') else Open77.log.info(line) end
end

--- Starts the door watch for a seat just taken, when the airframe's door slots are known.
local function doorWatchStart(seat, now)
    local id = seat.vehicleId
    local record = nil
    local api = Open77.vehicles
    if type(api) == 'table' and type(api.get) == 'function' then
        local read, snapshot = pcall(api.get, M.IdNumber ~= nil and M.IdNumber(id) or id)
        if read and type(snapshot) == 'table' then record = snapshot.record end
    end
    if record == nil or M.DoorSlots(record) == nil then return end
    local seatName = M.SeatName(seat.seat) or tostring(seat.seat)
    doorWatch = { id = id, record = record, seat = seatName, door = M.ExitDoorName(record, seatName), since = now,
        nextAt = now, looks = 0, changes = 0, openFlying = 0 }
end

local function doorWatchTick(seat, now)
    -- A new seat in an airframe: watched from now.
    local hull = seat ~= nil and seat.exiting ~= true and seat.vehicleId or nil
    if hull ~= nil and (doorWatchHull == nil or not M.SameHull(hull, doorWatchHull)) then
        if doorWatch ~= nil then doorWatchEnd(doorWatch, now, 'another seat') end
        doorWatchHull = hull
        doorWatchStart(seat, now)
    elseif hull == nil and doorWatchHull ~= nil then
        doorWatchHull = nil
        if doorWatch ~= nil then doorWatchEnd(doorWatch, now, 'the seat was left') end
    end
    local w = doorWatch
    if w == nil or now < w.nextAt then return end
    w.nextAt = now + ((now - w.since) < DOOR_WATCH_EARLY_MS and DOOR_WATCH_EVERY_MS or DOOR_WATCH_LATE_EVERY_MS)
    doorWatchLook(w, now)
    if now - w.since >= DOOR_WATCH_MS then doorWatchEnd(w, now, ('%.0fs watched'):format(DOOR_WATCH_MS / 1000.0)) end
end

--- The phases, one look a pass.
local function look(seat, now)
    local e = enter
    local settings = cfg()
    -- THE SEAT: the server seated the body (the step's end, or plainly).
    if seat ~= nil and seat.exiting ~= true then
        if e.phase == 'playing' or e.phase == 'parking' or e.phase == 'seating' then
            return E.Seated('the seat read', now)
        end
        if e.phase ~= 'lifting' then
            enter = nil
            release(e, 'seated before the step played')
            Open77.log.info(('boarding step %s: the body was seated %.1fs after the key before its step played (the '
                .. 'server boarded it plainly)'):format(e.clip, since(e, now)))
            Open77.log.info(summary(e, 'seated plainly', now))
            return
        end
    end
    if e.phase == 'lifting' then
        if now >= e.liftAt then
            enter = nil
            if e.curtained and M.Curtain ~= nil and M.Curtain() ~= nil then
                local settings = cfg()
                M.CurtainUp('boarding step: seated', settings.seatFadeIn, false)
                if e.seatFadeAt ~= nil then
                    Open77.log.info(('boarding step %s: the image back on the seat\'s view (fade-in %d ms) %.2fs after '
                        .. 'the fade began, %.2fs after the seat'):format(e.clip, settings.seatFadeIn,
                        (now - e.seatFadeAt) / 1000.0, (now - (e.seatedAt or now)) / 1000.0))
                end
            end
            Open77.log.info(summary(e, 'seated', now))
        end
        return
    end
    if not alive() then return giveUp('the body is down') end
    local early = e.phase ~= 'asked' and e.phase ~= 'playing' and e.phase ~= 'parking' and e.phase ~= 'seating'
    if early and now - e.since > e.askMs then
        return giveUp(('the preparation took more than %.1fs (%s)'):format(e.askMs / 1000.0, e.phase))
    end
    -- A move made in this pass is applied on the next frame.
    if e.movedPass == pass then return end
    local at = position()
    local b = bodyNow()
    local yaw = bodyYaw()
    -- The body's footing, each change a line (`BODY_LINES` at most).
    local line = bodyText(b)
    if line ~= e.bodyLine and e.lines < BODY_LINES then
        e.lines = e.lines + 1
        e.bodyLine = line
        Open77.log.info(('boarding step %s: the body %s (%s, %.1fs after the key%s%s)'):format(e.clip, line, e.phase,
            since(e, now), at ~= nil and (', %.2f m from the first spot'):format(apart(at, e.plan)) or '',
            yaw ~= nil and (', facing %.0f deg'):format(yaw) or ''))
    end
    local p = e.plan
    if e.phase == 'place' then
        if at ~= nil and apart(at, p) <= settings.arrive then
            e.phase, e.arrivedAt, e.good = 'stand', now, 0
            mark(e, 'on the spot', now)
            local off, distance = offSpot(p, at)
            Open77.log.info(('boarding step %s: the body is on the first spot %.2fs after it was put there%s'):format(
                e.clip, (now - e.placedAt) / 1000.0, off ~= nil and (' -- ' .. off) or ''))
            if distance ~= nil and distance > OFF_SPOT_WARN_METRES then
                Open77.log.warn(('boarding step %s: the body stands %s -- the clip plays that far off the AV (its '
                    .. 'collision pushes a body put too near its side out)'):format(e.clip, off))
            end
        elseif now - e.placedAt >= settings.placeWait then
            if e.placements >= settings.placeTries then
                return giveUp(('the body never stood on the first spot (%s from it)'):format(at ~= nil
                    and ('%.2f m'):format(apart(at, p)) or 'not read'))
            end
            place(e, 'the last placement had not held')
        end
        return
    end
    if e.phase == 'stand' or e.phase == 'hold' then
        -- A body that strayed from the spot is put back (a player's key, a shove).
        if at ~= nil and apart(at, p) > settings.arrive + STRAY_METRES then
            if e.placements >= settings.placeTries then
                return giveUp(('the body left the first spot (%.2f m from it)'):format(apart(at, p)))
            end
            return place(e, ('the body left the first spot (%.2f m)'):format(apart(at, p)))
        end
        local off = yaw ~= nil and (M.YawApart(yaw, p.yaw) or 0) or 0
        if off > settings.facing and settings.facingTries > 0 then
            if e.facingBack >= settings.facingTries then
                return giveUp(('the body will not face the door (%.0f deg off)'):format(off))
            end
            e.facingBack = e.facingBack + 1
            Open77.log.info(('boarding step %s: the body faces %.0f deg, %.0f off the step\'s %.0f: turned back (%d of %d)')
                :format(e.clip, yaw, off, p.yaw, e.facingBack, settings.facingTries))
            if e.phase == 'hold' then letGo(e, 'turned back') end
            e.phase = 'stand'
            return place(e, 'turned back to the door')
        end
    end
    if e.phase == 'stand' then
        if b == nil or b.standing then e.good = e.good + 1 else e.good = 0 end
        if e.good >= settings.standLooks then
            mark(e, 'standing', now)
            if settings.hold and hold(e) then
                e.wasHeld = true
                e.phase, e.holdGood = 'hold', 0
                return
            end
            e.phase = 'curtain'
        elseif now - (e.arrivedAt or now) >= settings.standWait then
            return giveUp(('the body never stood on the first spot (%s)'):format(line))
        else
            return
        end
    end
    if e.phase == 'hold' then
        if b ~= nil and not b.standing then
            -- A hold that takes a standing body off the ground plays no clip here
            -- (the platform draws none on a body in the air): let go of.
            Open77.log.warn(('boarding step %s: the hold took the body off the ground (%s): let go -- the step plays '
                .. 'with the body free'):format(e.clip, line))
            letGo(e, 'it took the body off the ground')
            e.phase = 'curtain'
        else
            e.holdGood = e.holdGood + 1
            if e.holdGood < settings.holdLooks then return end
            mark(e, 'held', now)
            e.phase = 'curtain'
        end
    end
    if e.phase == 'curtain' then
        -- THE WEAPON (1.7.2): the step waits for the hands to be empty.
        local drawn = nil
        if settings.holster then drawn = weaponDrawn() end
        if drawn == true then
            if e.holstering == nil then
                -- Drawn since the key (a weapon key while held): put away now.
                if not holster(e, 'drawn while the body was placed') then
                    return giveUp('a weapon drawn, and it could not be holstered: the platform plays no clip on a '
                        .. 'body with a weapon drawn')
                end
                e.holstering = { since = now }
                counts.holstered = counts.holstered + 1
                return
            end
            local waited = now - e.holstering.since
            if waited < settings.holsterWait then
                -- Asked once more halfway, in case the first went unheard.
                if waited >= settings.holsterWait / 2 and (e.holsterAsks or 0) < 2 then
                    holster(e, 'still drawn halfway through the wait')
                end
                return
            end
            return giveUp(('a weapon still drawn %.1fs after it was holstered: the platform plays no clip on a body '
                .. 'with a weapon drawn'):format(waited / 1000.0))
        end
        if e.holstering ~= nil and not e.holstering.done then
            e.holstering.done = true
            mark(e, 'holstered', now)
            Open77.log.info(('boarding step %s: the hands are empty %.2fs after the weapon was holstered%s'):format(
                e.clip, (now - e.holstering.since) / 1000.0, drawn == nil and ' (this game does not say: taken as so)'
                    or ''))
        end
        if settings.curtain and M.CurtainDown ~= nil then
            e.curtained = M.CurtainDown('the boarding step: the view changes') == true
        end
        -- Third person: asked at the key (1.7.3), else now -- or once more,
        -- when the key's ask was refused.
        if not e.viewHeld and (not settings.viewEarly or e.viewRefused ~= nil) and (e.viewTries or 0) < 2 then
            viewOn(e, settings.viewEarly and 'again, the body held' or 'the body held')
        end
        e.phase, e.viewSince = 'view', e.viewSince or now
        mark(e, e.curtained and 'curtain' or 'view', now)
        if M.Shots ~= nil then M.Shots.Take('held', 0, E.ShotMeta) end
        return
    end
    if e.phase == 'view' then
        local state = perspectiveState()
        local shown = thirdPersonShown(state)
        local lineView = state ~= nil and ('%s, %s, %s, body %s'):format(tostring(state.mode),
            state.settled == true and 'settled' or tostring(state.transition), tostring(state.reason),
            tostring(state.body)) or 'not read'
        if lineView ~= e.viewLine then
            e.viewLine = lineView
            Open77.log.info(('boarding step %s: the perspective %s, %.1fs into the wait (%.1fs after the key)'):format(
                e.clip, lineView, (now - e.viewSince) / 1000.0, since(e, now)))
        end
        local waited = now - e.viewSince
        -- THE PLATFORM'S OWN TIMEOUT (1.7.5): a stand-in not made within its
        -- 3 s restores first person (`prepare_timeout`) and is asked for again
        -- 3 s later, the body still being built: waited for, and said.
        if state ~= nil and state.reason == 'prepare_timeout' and not e.timeoutSaid then
            e.timeoutSaid = true
            mark(e, 'platform timeout', now)
            Open77.log.warn(('boarding step %s: the platform did not make the stand-in within its own 3 s and showed '
                .. 'first person again (%s, %.1fs after the key): it asks again about 3 s later, the body still being '
                .. 'built -- waited for, %.1fs from the key at most'):format(e.clip, lineView, since(e, now),
                settings.viewWait / 1000.0))
        end
        if shown then
            -- THE STAND-IN DRAWN (1.7.3), and drawn a moment: a clip started
            -- while it is still being made or dressed is never drawn on it.
            if e.shownAt == nil then
                e.shownAt, e.shownLooks = now, 0
                mark(e, 'third person', now)
                Open77.log.info(('boarding step %s: third person drawn %.1fs after the key (%s)%s'):format(e.clip,
                    since(e, now), lineView, e.viewAskedAt ~= nil
                        and (', %.1fs after it was asked'):format((now - e.viewAskedAt) / 1000.0) or ''))
            end
            e.shownLooks = e.shownLooks + 1
            if state.settled ~= true and (now - e.shownAt < settings.viewSettle or e.shownLooks < 2) then return end
            e.drawnAt = now
            -- The camera's swing round the body (1.7.7: the seat clip's own,
            -- toward the door, so the sitting is seen through it).
            local orbit = e.orbit or settings.orbit
            if orbit ~= 0 then
                local camera = Open77.camera
                if type(camera) == 'table' and type(camera.orbit) == 'function' then
                    local read, ok = pcall(camera.orbit, orbit)
                    e.orbiting = read and ok == true
                    Open77.log.info(('boarding step %s: the camera swung %.0f deg round the body%s'):format(e.clip, orbit,
                        e.orbiting and '' or (' -- refused (%s)'):format(tostring(read and ok or 'an error'))))
                end
            end
        else
            if e.shownAt ~= nil then
                Open77.log.info(('boarding step %s: third person drawn, then not (%s): waited for again'):format(e.clip,
                    lineView))
                e.shownAt = nil
            end
            if e.viewHeld and waited < settings.viewWait then return end
            local why = e.viewHeld and ('not drawn %.1fs after the key (%s)'):format(since(e, now), lineView)
                or ('refused (%s)'):format(tostring(e.viewRefused or 'no third person on this client'))
            if settings.viewRequired then
                -- No step this screen cannot show: the stand-in would stand
                -- still at the door through the clip, then the cut to the seat.
                return giveUp(('third person %s: the stand-in body the clip plays on is not drawn on this screen -- '
                    .. 'the plain boarding'):format(why))
            end
            Open77.log.warn(('boarding step %s: third person %s: the step is asked all the same (VIEW_REQUIRED off) -- '
                .. 'the others see it, this screen %s'):format(e.clip, why, e.viewHeld and 'may not' or 'shows its own view'))
        end
        -- THE ASK, with the plan and what this game reads of the body.
        local facing = yaw
        local body = {
            token = e.token, id = e.id, clip = e.clip,
            sitWhy = e.sitWhy ~= nil and tostring(e.sitWhy):sub(1, 200) or nil,
            plan = { at = { x = p.x, y = p.y, z = p.z }, ground = p.ground, yaw = p.yaw, stepTurn = p.turn or 0,
                width = p.width, source = e.plan.frameSource, hull = p.frame, facing = facing,
                facingOff = facing ~= nil and M.YawApart(facing, p.yaw) or nil, step = p.step, seat = p.height,
                standing = b ~= nil and b.standing or nil, held = e.held, drawn = shown, fps = fps() },
        }
        if not send(body) then return giveUp('the ask could not be sent', false) end
        e.phase, e.askedAt = 'asked', now
        mark(e, 'asked', now)
        local off = offSpot(p, at)
        Open77.log.info(('boarding step %s asked %.1fs after the key: the body %s on the first spot (%s), '
            .. 'facing %s, %s, %s; third person %s'):format(e.clip, since(e, now), line,
            off or ('%.2f m off'):format(at ~= nil and apart(at, p) or -1),
            facing ~= nil and ('%.0f deg'):format(facing) or 'unread',
            e.held and 'held' or 'free', e.curtained and 'under the curtain' or 'in view',
            shown and ('drawn, the stand-in on screen %.2fs (%s)'):format((now - (e.shownAt or now)) / 1000.0,
                lineView) or 'not drawn'))
        if M.Shots ~= nil then M.Shots.Take('asked', 0, E.ShotMeta) end
        return
    end
    if e.phase == 'asked' then
        -- The server may hold the step for the door's swing and the body.
        local budget = settings.answer + math.max(0, e.doorOpenAt - e.askedAt) + settings.bodyWait
        if now - e.askedAt >= budget then
            return giveUp(('no word from the server in %d ms'):format(now - e.askedAt))
        end
        return
    end
    if e.phase == 'playing' then
        -- The clip's path turns with the body: a turn now is said (not turned
        -- back -- a move would take the body off the ground under the clip).
        if yaw ~= nil and not e.turnSaid then
            local off = M.YawApart(yaw, p.yaw) or 0
            if off > CLIP_TURN_FACTOR * settings.facing then
                e.turnSaid = true
                Open77.log.warn(('boarding step %s: the body turned %.0f deg off the step\'s heading %.1fs into the clip '
                    .. '(it faces %.0f): the step\'s end is off the door'):format(e.clip, off,
                    (now - e.playing.since) / 1000.0, yaw))
            end
        end
        if b ~= nil and not b.standing and not e.airSaid then
            e.airSaid = true
            Open77.log.warn(('boarding step %s: the body is off the ground %.1fs into the clip (%s): no screen draws '
                .. 'the clip on it'):format(e.clip, (now - e.playing.since) / 1000.0, line))
        end
        -- THE VIEW BEFORE THE SEAT (1.7.8): the stand-in put away first.
        if settings.seatAfterView then
            if now >= e.playing.untilAt - M.ViewLead(e.clip, settings) then parkView(e, now) end
            return
        end
        if now >= e.playing.seatAt - settings.seatLead then
            letGo(e, 'the seat comes')
            if settings.seatCurtain and M.CurtainDown ~= nil then
                e.curtained = M.CurtainDown('the boarding step: the seat') == true or e.curtained
            end
            e.phase, e.seatingSince = 'seating', now
            mark(e, 'seat curtain', now)
            if M.Shots ~= nil then M.Shots.Take('seat', 0, E.ShotMeta) end
        end
        return
    end
    if e.phase == 'parking' then
        -- The stand-in is put away once the platform shows first person with
        -- the player's own body; the seat is asked then, or after the wait.
        local state = perspectiveState()
        local parked = state ~= nil and state.mode == 'fpp' and state.body ~= 'proxy'
        local lineView = state ~= nil and ('%s, %s, %s, body %s'):format(tostring(state.mode),
            state.settled == true and 'settled' or tostring(state.transition), tostring(state.reason),
            tostring(state.body)) or 'not read'
        if lineView ~= e.parkLine then
            e.parkLine = lineView
            Open77.log.info(('boarding step %s: the perspective %s, %.2fs after the view was let go'):format(e.clip,
                lineView, (now - e.parkingSince) / 1000.0))
        end
        if parked or now - e.parkingSince >= settings.parkWait then askSeat(e, now, parked, lineView) end
        return
    end
    if e.phase == 'seating' then
        local limit = settings.seatAfterView and (settings.seatWait + settings.viewLead + 1000)
            or (settings.seatLead + settings.seatCurtainMax)
        if now - e.seatingSince >= limit then
            return giveUp(('no seat %.1fs after it was due'):format((now - e.seatingSince) / 1000.0), false)
        end
    end
end

--- The server's word on the step (`ENTERING`).
-- @param payload table `{ token, ok, clip, durationMs, seatInMs }` or `{ token, ok = false, reason }`
function E.Answer(payload)
    if type(payload) ~= 'table' then return end
    local e = enter
    if e == nil or tostring(payload.token) ~= e.token then
        if pending ~= nil and tostring(payload.token) == pending.token then
            pending = nil
            Open77.log.info(('boarding step: the server ended the step this game was still waiting for (%s): %s')
                :format(tostring(payload.token), tostring(payload.reason)))
            return
        end
        Open77.log.info(('boarding step: the server\'s word for a step not under way here (%s)'):format(
            tostring(payload.token)))
        return
    end
    local now = M.Now()
    if payload.ok ~= true then
        enter = nil
        counts.abandoned = counts.abandoned + 1
        release(e, 'the server: ' .. tostring(payload.reason))
        Open77.log.info(('boarding step %s refused by the server %.1fs after the key: %s -- it seats the body at once')
            :format(e.clip, since(e, now), tostring(payload.reason)))
        Open77.log.info(summary(e, 'refused', now))
        return
    end
    local duration = math.floor(finite(payload.durationMs) or e.durationMs)
    local seatIn = math.floor(finite(payload.seatInMs) or (duration - cfg().seatEarly))
    e.phase = 'playing'
    e.playing = { since = now, untilAt = now + duration, seatAt = now + seatIn }
    counts.stepped = counts.stepped + 1
    mark(e, 'playing', now)
    -- The image back on the clip's first frame.
    if e.curtained and M.Curtain ~= nil and M.Curtain() ~= nil then
        M.CurtainUp('the boarding step plays', nil, true)
        e.curtained = false
    end
    if M.Shots ~= nil then
        M.Shots.Take('step', 300, E.ShotMeta)
        M.Shots.Take('door', math.floor(duration * 0.75), E.ShotMeta)
    end
    -- THE SCENE (client/sync.lua): this screen reports its own step a moment
    -- into it and as it ends, as every screen near it does.
    if payload.scene ~= nil and M.Sync ~= nil and type(M.Sync.Own) == 'function' then
        local p = e.plan
        pcall(M.Sync.Own, { scene = payload.scene, id = e.id, hull = p.frame, at = { x = p.x, y = p.y, z = p.z },
            durationMs = duration, clip = e.clip, yaw = p.yaw, door = p.door, record = e.record, seat = e.seat,
            kind = 'enter' })
    end
    local state = perspectiveState()
    Open77.log.info(('boarding step %s playing %.1fs after the key (asked %.2fs ago): %.1fs long, the seat in %.2fs; '
        .. 'this screen %s'):format(e.clip, since(e, now), (now - (e.askedAt or now)) / 1000.0, duration / 1000.0,
        seatIn / 1000.0, state == nil and 'does not say its view' or (thirdPersonShown(state)
            and ('draws the stand-in (%s, %s)'):format(state.settled == true and 'settled' or tostring(state.transition),
                tostring(state.body))
            or ('does NOT draw the stand-in (%s, %s, body %s): the clip is not seen here'):format(tostring(state.mode),
                tostring(state.transition), tostring(state.body)))))
end

--- The seat is taken: the seat's own view again, the image back a moment later.
-- @param how string
-- @param now number|nil
function E.Seated(how, now)
    local e = enter
    if e == nil then return end
    now = now or M.Now()
    if e.phase == 'lifting' then return end
    counts.seated = counts.seated + 1
    letGo(e, 'seated')
    viewOff(e, 'seated')
    e.seatedAt = now
    mark(e, 'seated', now)
    local settings = cfg()
    if settings.seatAfterView and e.seatingSince ~= nil then
        Open77.log.info(('boarding step %s: seated %.1fs after the key (%s), %.2fs after the seat was asked, %.2fs %s the '
            .. 'clip\'s end'):format(e.clip, since(e, now), how, (now - e.seatingSince) / 1000.0,
            e.playing ~= nil and math.abs(e.playing.untilAt - now) / 1000.0 or 0,
            (e.playing ~= nil and now > e.playing.untilAt) and 'after' or 'before'))
    else
        Open77.log.info(('boarding step %s: seated %.1fs after the key (%s), %.2fs after the seat was due; the image back '
            .. 'in %d ms'):format(e.clip, since(e, now), how, e.playing ~= nil and (now - e.playing.seatAt) / 1000.0 or 0,
            settings.seatSettle))
    end
    -- WHAT THE SEAT LOOKS LIKE (1.7.2): the owner saw the screen go black as
    -- the body was seated (Staging, 2026-10-29) with no curtain asked for --
    -- two pictures just after the seat say whether the game's own view change
    -- draws black frames.
    if M.Shots ~= nil then
        -- 1.7.3: and one at the seat's own frame, where a black one would be.
        M.Shots.Take('seated+0.0', 0, E.ShotMeta)
        M.Shots.Take('seated+0.15', 150, E.ShotMeta)
        M.Shots.Take('seated+0.6', 600, E.ShotMeta)
        -- 1.7.8: and the pilot's view a moment on (the stand-in left beside the AV).
        M.Shots.Take('seated+1.5', 1500, E.ShotMeta)
        M.Shots.Take('seated+3.0', 3000, E.ShotMeta)
    end
    -- THE SEAT, WATCHED (1.7.8): where this game draws the body after the seat.
    local seatPoint = e.plan ~= nil and e.plan.seat or nil
    local hull = M.HullFrame ~= nil and M.HullFrame(e.id) or nil
    if seatPoint == nil and hull ~= nil and M.SeatSit ~= nil then
        local sit = M.SeatSit(e.record, e.seat)
        if sit ~= nil then seatPoint = M.FromHullLocal(hull, { x = sit.x, y = sit.y, z = sit.z }) end
    end
    seatWatch = { id = e.id, clip = e.clip, since = now, untilAt = now + SEAT_WATCH_MS, nextAt = now,
        seat = seatPoint, first = { x = e.plan.x, y = e.plan.y }, hull = hull ~= nil and { x = hull.x, y = hull.y } or nil,
        looks = 0, lines = 0 }
    e.phase, e.liftAt = 'lifting', now + settings.seatSettle
end

--- What the press came to (`BOARDED`, client/main.lua): the seat, or not.
-- @param payload table `{ ok, seat, role, reason }`
function E.Boarded(payload)
    local e = enter
    if e == nil and pending ~= nil and type(payload) == 'table' then
        Open77.log.info(('boarding step: the press came to %s while this game waited for the hull drawn on its gear')
            :format(payload.ok == true and 'a plain seat' or ('no seat (' .. tostring(payload.reason) .. ')')))
        pending = nil
        return
    end
    if e == nil or type(payload) ~= 'table' then return end
    if payload.ok == true then
        if e.phase == 'playing' or e.phase == 'parking' or e.phase == 'seating' then
            return E.Seated('the server\'s word')
        end
        if e.phase ~= 'lifting' then
            enter = nil
            release(e, 'boarded plainly')
            Open77.log.info(summary(e, 'seated plainly', M.Now()))
        end
        return
    end
    enter = nil
    counts.abandoned = counts.abandoned + 1
    release(e, 'the seat was refused: ' .. tostring(payload.reason))
    Open77.log.warn(('boarding step %s: the seat was refused (%s) %.1fs after the key'):format(e.clip,
        tostring(payload.reason), since(e)))
    Open77.log.info(summary(e, 'not seated', M.Now()))
end

--- Whether the curtain is this boarding's to keep down now.
function E.KeepCurtain(now)
    local e = enter
    if e == nil or not e.curtained then return false end
    return e.phase == 'view' or e.phase == 'asked' or e.phase == 'parking' or e.phase == 'seating'
        or e.phase == 'lifting'
end

--- One look a pass of the client's watch (client/main.lua).
-- @param seat table|nil this pass's seat read
function E.Tick(seat)
    pass = pass + 1
    if seatWatch ~= nil then
        local ran, failure = pcall(seatWatchTick, M.Now())
        if not ran then
            seatWatch = nil
            Open77.log.warn('the seat watch failed: ' .. tostring(failure))
        end
    end
    -- The door as this game draws it, aboard (1.7.10).
    local doorRan, doorFailure = pcall(doorWatchTick, seat, M.Now())
    if not doorRan then
        doorWatch, doorWatchHull = nil, nil
        Open77.log.warn('the door watch failed: ' .. tostring(doorFailure))
    end
    if enter == nil then
        -- THE DOOR'S CLIP AFTER THE SEAT'S (1.7.7): planned in this pass.
        local d = deferredAsk
        if d ~= nil then
            deferredAsk = nil
            local ran, failure = pcall(E.AskDeferred, d)
            if not ran then
                Open77.log.error('the boarding step\'s door clip plan failed: ' .. tostring(failure))
                if enter ~= nil and enter.token == d.token then
                    giveUp('an error: ' .. tostring(failure):sub(1, 80))
                else
                    none(d.token, 'an error: ' .. tostring(failure):sub(1, 80), d.payload.clip)
                end
            end
            return
        end
        -- A second ask waiting for the hull drawn on its gear: planned again.
        local wait = pending
        if wait ~= nil and M.Now() >= (wait.nextAt or 0) then
            if seat ~= nil then
                pending = nil
                Open77.log.info(('boarding step: seated while waiting for the hull drawn on its gear (%s)'):format(
                    tostring(wait.token)))
                return
            end
            local ran, failure = pcall(E.Ask, wait.payload)
            if not ran then
                pending = nil
                Open77.log.error('the boarding step\'s second ask failed: ' .. tostring(failure))
                none(wait.token, 'an error: ' .. tostring(failure):sub(1, 80), wait.payload.clip)
            end
        end
        return
    end
    local ran, failure = pcall(look, seat, M.Now())
    if not ran then
        Open77.log.error('the boarding step\'s look failed: ' .. tostring(failure))
        giveUp('an error: ' .. tostring(failure):sub(1, 80))
    end
end

--- Whether a boarding step is under way on this screen.
function E.Active() return enter ~= nil end

--- What this screen shows of its own step, for the scene's report
--- (client/sync.lua): `{ view, body, orbit, target }`.
function E.Shot()
    local state = perspectiveState()
    local e = enter
    return { view = state ~= nil and state.mode or nil, body = state ~= nil and state.body or nil,
        orbit = e ~= nil and e.orbiting == true or false,
        target = e ~= nil and { x = e.plan.x, y = e.plan.y } or nil,
        -- 1.7.8: the view let go for the seat (the stand-in put away first).
        seating = e ~= nil and (e.phase == 'parking' or e.phase == 'seating') or false }
end

--- What a diag picture's words say of the boarding now (client/shots.lua).
function E.ShotMeta(now)
    local out = {}
    local at = position()
    if at ~= nil then out[#out + 1] = ('body=%.2f,%.2f,%.2f'):format(at.x, at.y, at.z) end
    local yaw = bodyYaw()
    if yaw ~= nil then out[#out + 1] = ('yaw=%.1f'):format(yaw) end
    out[#out + 1] = 'state=' .. bodyText(bodyNow())
    local state = perspectiveState()
    if state ~= nil then out[#out + 1] = ('view=%s/%s/%s'):format(tostring(state.mode), tostring(state.camera),
        tostring(state.body)) end
    local e = enter
    if e ~= nil then
        out[#out + 1] = ('enter=%s %s'):format(e.clip, e.phase)
        out[#out + 1] = ('spot=%.2f,%.2f yaw %.0f'):format(e.plan.x, e.plan.y, e.plan.yaw)
        out[#out + 1] = ('door=%.2f,%.2f'):format(e.plan.door.x, e.plan.door.y)
        if e.playing ~= nil then out[#out + 1] = ('clip=%.2fs'):format(((now or M.Now()) - e.playing.since) / 1000.0) end
    end
    return out
end

function E.Status()
    local e = enter
    return { active = e ~= nil, phase = e ~= nil and e.phase or nil, clip = e ~= nil and e.clip or nil,
        asked = counts.asked, stepped = counts.stepped, seated = counts.seated, none = counts.none,
        abandoned = counts.abandoned, setDown = counts.setDown or 0, waiting = pending ~= nil,
        holstered = counts.holstered, noClips = counts.noClips, sit = counts.sit or 0, fellBack = counts.fellBack or 0,
        held = e ~= nil and e.held or false, view = e ~= nil and e.viewHeld or false }
end

function E.Start()
    RegisterNetEvent(M.Event.ENTER, function(payload)
        local ran, failure = pcall(E.Ask, payload)
        if not ran then
            Open77.log.error('the boarding step\'s ask failed: ' .. tostring(failure))
            if type(payload) == 'table' and payload.token ~= nil then
                if enter ~= nil and enter.token == tostring(payload.token) then
                    giveUp('an error: ' .. tostring(failure):sub(1, 80))
                else
                    none(tostring(payload.token), 'an error: ' .. tostring(failure):sub(1, 80))
                end
            end
        end
    end)
    RegisterNetEvent(M.Event.ENTERING, function(payload)
        local ran, failure = pcall(E.Answer, payload)
        if not ran then
            Open77.log.error('the boarding step\'s answer failed: ' .. tostring(failure))
            giveUp('an error: ' .. tostring(failure):sub(1, 80), false)
        end
    end)
end

function E.Stop()
    local e = enter
    enter, pending = nil, nil
    if e ~= nil then release(e, 'stopped') end
end
