-- =============================================================================
-- open77_avdrive -- server/main.lua
-- =============================================================================
-- The autopilot itself: one flight per pilot, posed by this file and handed
-- back at the hover.
--
-- THE FLIGHT IS POSED, NOT SIMULATED. `Open77.vehicles.setTransform` per tick
-- is the primitive: server-authoritative, revoking the physics lease and
-- republishing the canonical transform to every viewer. There is no engine
-- task for an AV (`Open77.vehicles.ai` does not support them), so the three
-- legs below ARE the flight model: climb over where you are, cruise straight
-- to the pin, descend to a hover above it. Each leg is eased at both ends so
-- the phase boundaries read as one continuous flight rather than three snaps.
--
-- FROZEN FOR THE WHOLE RUN, AND THE FREEZE IS THE RIDE. A seated player in an
-- AV is its pilot as far as the platform is concerned: their client claims the
-- hull and reports its own poses. Left alone, that client and this file would
-- be two hands on one airframe. `setFrozen` is the platform's own referee:
-- while the bit is up, the physics owner's transform reports are DISCARDED
-- rather than merged, so the pose this file publishes is the only pose there
-- is and the pilot rides instead of wrestling. The bit comes off the moment
-- the run ends, and the platform then hands the airframe to whoever is seated
-- in it.
--
-- THE SEAT READ IS THE ONLY PROOF. What a toggle claims is nothing; what a body
-- holds is `getPlayerSeat`, and the run checks it every tick. A pilot who
-- leaves the seat, an aircraft taken out of the world, a pilot who disconnects
-- -- each ends the run by name, unfreezes the hull and stops posing. Nobody is
-- ever left frozen in mid-air under a controller that has stopped caring.
--
-- WHOEVER FLIES IT (1.1.0). The Open77 client flies an AV from whichever seat
-- its crew boards through -- the platform counts every occupant of an AV as
-- its controller -- so the pilot is whoever sits in the pilot seat, else the
-- occupant whose game simulates it, else the only one aboard (`M.PilotOf`).
-- 1.0.0, like the opx_infinity module it was ported from, answered "only the
-- pilot's seat has the autopilot" to a player flying from the back seat
-- (opx_infinity's, on Staging, 2026-10-30: `pilot 1 flying it from
-- seat_back_left`).
--
-- ARRIVE, DO NOT FLY (1.1.0, `TRAVEL = 'arrive'`, the default). Every pose of
-- the flight below takes the flight from the pilot's game and the game claims
-- it straight back; its chase camera lets go and first person comes back each
-- time, so the pilot's view flickers between the two for the whole flight --
-- measured on open77_avdoor's pad snap, which flies an AV the same way (129
-- poses in 9.8 s, the hull changing hands 252 times in 10 s, the pilot's chase
-- camera let go 116 times; Staging, 2026-10-30). No platform call moves an AV
-- without that, and a resource cannot hold the view of a player in a vehicle.
-- So by default the screens of everybody aboard fade to black, the aircraft is
-- placed hovering over the pin (one move, under the black), the pilot's game
-- measures the ground there once the world has streamed in and the hover is
-- raised over a roof if it must be, the controls are handed back and the
-- screens come back. `TRAVEL = 'fly'` flies the three legs as 1.0.0 did.
--
-- NOTHING HERE IS OWNED. This resource creates no vehicle and moves no player.
-- It reads the host's own seat and hull reads, poses a hull somebody else
-- created, and puts both hands back on the controls at the end.
--
-- Ported from XyberRP's opx_infinity `avdrive` module.
-- =============================================================================

local M = AvDrive

local RESOURCE = GetCurrentResourceName()

--- The vehicle API, resolved per call rather than captured at load.
local function vehicles()
    return type(Open77) == 'table' and Open77.vehicles or nil
end

--- Live runs, by the pilot who asked for one. One per pilot -- the key is a
--- toggle, and a second press is always the OFF half of it.
local runs = {}

-- Per-player press windows.
local pressed = {}

M.PHASE = { CLIMB = 'climb', CRUISE = 'cruise', DESCEND = 'descend' }
local PHASE = M.PHASE

-- How far a destination may be from the world's centre on each axis, and the
-- band a destination's height may sit in. A payload off the wire is a claim,
-- and a claim is checked before it becomes a flight plan.
local MAX_COORDINATE = 20000.0
local MIN_ALTITUDE = -500.0
local MAX_ALTITUDE = 3000.0

local function settings()
    return type(M.Settings) == 'table' and M.Settings or {}
end

--- A player id the host may be asked about: a whole number of 1 or more.
local function validPlayer(value)
    local id = tonumber(value)
    if id == nil or id < 1 or id ~= math.floor(id) then return nil end
    return math.tointeger(id) or id
end

local function cooldownMs()
    local value = tonumber(settings().COOLDOWN_MS)
    if value == nil or value ~= value or value < 0 then return 400 end
    return value
end

local function lerp(a, b, t) return a + (b - a) * t end

--- Ease-in-out, so a leg starts and ends at rest. A linear lerp snaps the
--- airframe through every phase boundary, which reads as a stutter per phase.
function M.Smooth(t) return t * t * (3.0 - 2.0 * t) end
local smooth = M.Smooth

--- The constant heading of a run: from where it started to where it is going,
--- in the game's degrees -- 0 faces +Y and it grows counter-clockwise, so +X is
--- 270. The airframe turns toward its destination as it climbs and holds that
--- heading for the whole flight. (XyberRP's first version used the math angle,
--- `atan(dy, dx)`, 0 = +X, 90 degrees off: the aircraft flew to the pin
--- side-on.)
function M.HeadingTo(from, to)
    local dx = to.x - from.x
    local dy = to.y - from.y
    if dx == 0.0 and dy == 0.0 then return 0.0 end
    return math.deg(math.atan(-dx, dy)) % 360.0
end

--- A heading `t` of the way from one to another, the short way round.
function M.Turn(from, to, t)
    if t >= 1.0 then return to % 360.0 end
    local delta = ((to - from + 540.0) % 360.0) - 180.0
    return (from + delta * t) % 360.0
end

--- The flight the config names, read fresh for every run. Invalid numbers read
--- as their defaults (the start says each one out loud).
-- @return table
function M.Plan()
    local config = settings()
    local function positive(name, fallback)
        local value = tonumber(config[name])
        if value == nil or value ~= value or value <= 0 then return fallback end
        return value
    end
    local function nonNegative(name, fallback)
        local value = tonumber(config[name])
        if value == nil or value ~= value or value < 0 then return fallback end
        return value
    end
    return {
        cruiseAltitude = positive('CRUISE_ALTITUDE', 120.0),
        cruiseSpeed = positive('CRUISE_SPEED', 22.0),
        climbSpeed = positive('CLIMB_SPEED', 5.0),
        descendSpeed = positive('DESCEND_SPEED', 3.5),
        hoverHeight = nonNegative('HOVER_HEIGHT', 8.0),
        tickMs = math.max(20, math.floor(positive('TICK_MS', 100.0))),
        maxRange = positive('MAX_RANGE', 4000.0),
        maxSeconds = positive('MAX_MINUTES', 20.0) * 60.0,
    }
end

--- A seat as a name (the host may answer a number: -1 the pilot's).
local function seatName(seat)
    if type(seat) == 'string' and seat ~= '' then return seat end
    local number = tonumber(seat)
    if number == -1 then return 'seat_front_left' end
    if number == 0 then return 'seat_front_right' end
    if number == 1 then return 'seat_back_left' end
    if number == 2 then return 'seat_back_right' end
    return nil
end

--- Who is aboard a hull: `{ [playerId] = seat }` (not those stepping out), and
--- how many.
function M.Crew(hull)
    local seats, count = {}, 0
    for _, occupant in ipairs(type(hull) == 'table' and type(hull.occupants) == 'table' and hull.occupants or {}) do
        if type(occupant) == 'table' and occupant.exiting ~= true then
            local player = validPlayer(occupant.playerId)
            if player ~= nil and seats[player] == nil then
                seats[player] = seatName(occupant.seat) or tostring(occupant.seat)
                count = count + 1
            end
        end
    end
    return seats, count
end

--- WHO FLIES THE AIRCRAFT (1.1.0): whoever sits in its pilot seat; else the
--- occupant whose game simulates it (the hull's `physicsOwner`, or the
--- platform's lease and controller, `Open77.vehicles.owner`); else the only one
--- aboard. The Open77 client flies an AV from any seat, and the platform counts
--- every occupant of an AV as its controller.
-- @param hull table the server's snapshot
-- @param hullId any
-- @return integer|nil the pilot
-- @return string|nil how this server knows
function M.PilotOf(hull, hullId)
    local seats, count = M.Crew(hull)
    for player, seat in pairs(seats) do
        if seat == 'seat_front_left' then return player, 'in the pilot seat' end
    end
    local owner = validPlayer(type(hull) == 'table' and hull.physicsOwner or nil)
    if owner ~= nil and seats[owner] ~= nil then
        return owner, ('flying it from %s'):format(seats[owner])
    end
    local api = vehicles()
    if count > 0 and api ~= nil and type(api.owner) == 'function' then
        local read, info = pcall(api.owner, hullId)
        if read and type(info) == 'table' then
            local leased = validPlayer(info.physicsOwner or info.authorityPlayerId)
            if leased ~= nil and seats[leased] ~= nil then
                return leased, ('flying it from %s (the platform\'s lease)'):format(seats[leased])
            end
            local controller = validPlayer(info.driver)
            if controller ~= nil and seats[controller] ~= nil then
                return controller, ('its controller from %s (the platform\'s word)'):format(seats[controller])
            end
        end
    end
    if count == 1 then
        local only, seat = next(seats)
        return only, ('the only one aboard, in %s'):format(seat)
    end
    return nil, nil
end

--- The travel the config names: 'arrive' (the default) or 'fly'.
function M.Travel()
    local value = settings().TRAVEL
    if value == 'fly' then return 'fly' end
    return 'arrive'
end

--- The arrival's numbers (`ARRIVE`), each inside its band.
function M.ArriveSettings()
    local block = type(settings().ARRIVE) == 'table' and settings().ARRIVE or {}
    local function ms(name, low, high, fallback)
        local value = tonumber(block[name])
        if value == nil or value ~= value then return fallback end
        return math.floor(math.max(low, math.min(high, value)))
    end
    local function number(name, low, high, fallback)
        local value = tonumber(block[name])
        if value == nil or value ~= value then return fallback end
        return math.max(low, math.min(high, value))
    end
    return {
        fadeOut = ms('FADE_OUT_MS', 0, 5000, 600),
        fadeWait = ms('FADE_WAIT_MS', 200, 10000, 2000),
        settle = ms('SETTLE_MS', 0, 10000, 1200),
        measure = ms('MEASURE_MS', 500, 20000, 6000),
        handBack = ms('HAND_BACK_MS', 0, 5000, 400),
        fadeIn = ms('FADE_IN_MS', 0, 5000, 800),
        -- 1.2.0: the flight under the black.
        speed = number('SPEED', 20.0, 400.0, 150.0),
        climb = number('CLIMB_SPEED', 5.0, 200.0, 60.0),
        cruiseAbove = number('CRUISE_ABOVE', 0.0, 500.0, 60.0),
        leash = number('LEASH_METRES', 20.0, 1000.0, 200.0),
        stall = ms('STALL_MS', 2000, 60000, 8000),
        loadingWait = ms('LOADING_WAIT_MS', 2000, 50000, 30000),
        pace = ms('PACE_MS', 100, 2000, 250),
        paceStale = ms('PACE_STALE_MS', 500, 10000, 1500),
        maxFlight = ms('MAX_FLIGHT_MS', 5000, 40000, 30000),
        ownWait = ms('OWN_WAIT_MS', 500, 20000, 5000),
        tick = 100,
    }
end

--- A hull's canonical position as the server reads it, or nil.
local function at(hull)
    if type(hull) ~= 'table' then return nil end
    local where = type(hull.position) == 'table' and hull.position or hull
    local x, y, z = tonumber(where.x), tonumber(where.y), tonumber(where.z)
    if x == nil or y == nil or z == nil or x ~= x or y ~= y or z ~= z then return nil end
    return { x = x, y = y, z = z }
end

--- A destination off the wire, checked before it is believed. Finite, inside
--- the world's own bounds, and in the height band an aircraft flies in.
-- @param value any
-- @return table|nil `{ x, y, z }`
function M.Destination(value)
    if type(value) ~= 'table' then return nil end
    local x, y, z = tonumber(value.x), tonumber(value.y), tonumber(value.z)
    if x == nil or y == nil or z == nil then return nil end
    if x ~= x or y ~= y or z ~= z then return nil end
    if math.abs(x) > MAX_COORDINATE or math.abs(y) > MAX_COORDINATE then return nil end
    if z < MIN_ALTITUDE or z > MAX_ALTITUDE then return nil end
    return { x = x, y = y, z = z }
end

--- The pose of a leg at `u` in [0, 1]. Each leg moves one thing at a time --
--- height, then ground, then height -- which keeps the cruise leg level.
function M.Pose(run, phase, u)
    local eased = smooth(u)
    if phase == PHASE.CLIMB then
        return { x = run.from.x, y = run.from.y, z = lerp(run.from.z, run.cruiseZ, eased) }
    end
    if phase == PHASE.CRUISE then
        return { x = lerp(run.from.x, run.to.x, eased), y = lerp(run.from.y, run.to.y, eased), z = run.cruiseZ }
    end
    return { x = run.to.x, y = run.to.y, z = lerp(run.cruiseZ, run.releaseZ, eased) }
end

--- Tells a pilot something, as a text key their own game words.
local function notice(playerId, key, kind)
    local id = validPlayer(playerId)
    if id == nil then return end
    pcall(TriggerClientEvent, M.Event.NOTICE, id, { key = key, kind = kind or 'info' })
end

--- A refusal: the line in the log, and the pilot told why.
local function refuse(playerId, key, detail)
    Open77.log.info(('player %s: autopilot refused (%s)%s'):format(tostring(playerId), key,
        detail ~= nil and (': ' .. tostring(detail)) or ''))
    notice(playerId, key, 'error')
    return false, key
end

--- Ends a run: the posing stops, the freeze comes off, and the reason goes in
--- the log with the notice the pilot reads. Idempotent.
-- @param run table
-- @param why string named reason, for the log line
-- @param key string|nil a text key to tell the pilot with
-- @param kind string|nil
function M.Finish(run, why, key, kind)
    if run == nil or runs[run.playerId] ~= run then return false end
    runs[run.playerId] = nil
    if run.handle ~= nil then
        run.handle.live = false
        run.handle = nil
    end
    -- THE HAND-OVER, IN THE OTHER DIRECTION. The bit comes off before the
    -- notice: a pilot told "you have the controls" while the hull is still
    -- frozen has been told a lie for as long as the packet takes.
    local api = vehicles()
    local released = 'no setFrozen on this host'
    if not run.frozen then
        -- Never frozen by this run (an arrival cancelled before its move): a
        -- freeze somebody else put on is not this run's to take off.
        released = 'never frozen by this run'
    elseif run.frozenOff then
        released = 'released at the hand-back'
    elseif api ~= nil and type(api.setFrozen) == 'function' then
        run.frozenOff = true
        local called, ok, reason = pcall(api.setFrozen, run.hullId, false)
        released = (called and ok ~= false) and 'released' or ('the release was refused: '
            .. tostring(called and reason or ok))
    end
    local where = run.last ~= nil and ('%.0f, %.0f, %.0f'):format(run.last.x, run.last.y, run.last.z) or '?'
    if run.mode == 'arrive' then
        -- The screens back, whatever ended it: nobody is left looking at black.
        M.FadeIn(run, why)
        Open77.log.info(('autopilot for %d (arrive) over after %.1fs in the %s phase (%s): %d move(s), hull %s at %s, %s')
            :format(run.playerId, (M.Now() - run.since) / 1000.0, run.phase, why, run.poses, tostring(run.hullId),
                where, released))
    else
        Open77.log.info(('autopilot for %d off after %.1fs in the %s leg (%s), %d pose(s), %d refused, hull %s at %s, %s')
            :format(run.playerId, run.clock, run.legPhase or PHASE.CLIMB, why, run.poses, run.refused,
                tostring(run.hullId), where, released))
    end
    if key ~= nil then notice(run.playerId, key, kind or 'info') end
    return true
end

--- One tick. THE SEAT IS RE-READ EVERY ONE OF THEM: a body that left the
--- controls is a run that must not keep flying an aircraft they are no longer
--- in, and the read is the platform's own, never the client's word.
-- @param playerId number
-- @param now number|nil the clock, for the suite
function M.Step(playerId, now)
    local run = runs[playerId]
    if run == nil then return end

    local api = vehicles()
    if api == nil or type(api.get) ~= 'function' then
        return M.Finish(run, 'the vehicle API went away', 'cancelled')
    end
    local readHull, hull = pcall(api.get, run.hullId)
    if not readHull or hull == nil then
        return M.Finish(run, 'the airframe was taken away', 'cancelled')
    end
    -- The controls are one seat, for as long as the run lasts (1.1.0: the seat
    -- the pilot flew from when the key was pressed): a pilot who moved seats
    -- has handed them on, and whoever has them now must not find the hull
    -- frozen under somebody else's run.
    local readSeat, seated = false, nil
    if type(api.getPlayerSeat) == 'function' then readSeat, seated = pcall(api.getPlayerSeat, playerId) end
    if not readSeat or type(seated) ~= 'table' or tostring(seated.vehicleId) ~= tostring(run.hullId)
        or (seatName(seated.seat) or tostring(seated.seat)) ~= run.seat then
        return M.Finish(run, 'the pilot left the controls', 'pilotLeft')
    end

    -- The clock is the host's own, clamped: a server that hitched for a second
    -- does not throw the airframe a second's flight in one pose.
    now = now or M.Now()
    local dt = (now - (run.tickAt or now)) / 1000.0
    run.tickAt = now
    if dt < 0 then dt = 0 end
    local ceiling = 2.0 * run.plan.tickMs / 1000.0
    if dt > ceiling then dt = ceiling end

    run.clock = run.clock + dt
    if run.clock > run.plan.maxSeconds then
        return M.Finish(run, 'the flight reached its ceiling of MAX_MINUTES', 'timeout')
    end

    local leg = run.legs[run.leg]
    run.legClock = run.legClock + dt
    local u = leg.seconds > 0.0 and math.min(1.0, run.legClock / leg.seconds) or 1.0
    local to = M.Pose(run, leg.phase, u)
    -- `yaw` is passed every tick on purpose: the platform's `setTransform` reads
    -- an absent heading as 0, not as "keep the current one". The turn toward
    -- the pin is made on the climb, from the heading the hull stood at, so it
    -- never snaps round on the first pose.
    local yaw = leg.phase == PHASE.CLIMB and M.Turn(run.fromYaw, run.heading, smooth(u)) or run.heading
    local called, moved, reason = pcall(api.setTransform, run.hullId, { x = to.x, y = to.y, z = to.z, yaw = yaw })
    run.poses = run.poses + 1
    if not called or moved ~= true then
        run.refused = run.refused + 1
        if run.refused == 1 or run.refused % 50 == 0 then
            Open77.log.warn(('the aircraft of %d refused a pose (%d so far): %s')
                :format(playerId, run.refused, tostring(called and reason or moved)))
        end
    else
        run.last = to
    end

    if u < 1.0 then return end
    run.legPhase = leg.phase
    Open77.log.info(('autopilot for %d: the %s leg done after %.1fs (%.1fs planned), at %.0f, %.0f, %.0f')
        :format(playerId, leg.phase, run.legClock, leg.seconds, to.x, to.y, to.z))
    if run.leg < #run.legs then
        run.leg = run.leg + 1
        run.legClock = 0.0
        return
    end
    M.Finish(run, 'the waypoint was reached', 'arrived', 'success')
end

--- Runs `fn` every `ms` milliseconds until the handle is put down.
local function every(name, ms, fn)
    local handle = { live = true }
    CreateThread(function()
        while handle.live do
            Wait(ms)
            if not handle.live then break end
            local ran, failure = pcall(fn)
            if not ran then Open77.log.error(('the %s pass failed: %s'):format(name, tostring(failure))) end
        end
    end)
    return handle
end

--- Engages the autopilot on the hull the pilot is seated in, flying to the
--- destination named. Every refusal is a notice that says WHICH check said no.
-- @param src number
-- @param payload table|nil `{ position, unreadable }`
-- @param now number|nil the clock; given (the suite), the run is not scheduled
--   and the caller steps it with `M.Step`
-- @return boolean, string|nil
function M.Engage(src, payload, now)
    local plan = M.Plan()
    local api = vehicles()
    if api == nil or type(api.get) ~= 'function' or type(api.setTransform) ~= 'function'
        or type(api.getPlayerSeat) ~= 'function' then
        return refuse(src, 'unavailable', 'the vehicle API is missing')
    end

    -- THE SEAT, THE HULL AND THE RECORD, all from the host and none from the
    -- wire: a client that names an aircraft is not a client sitting in one.
    local readSeat, seated = pcall(api.getPlayerSeat, src)
    if not readSeat or type(seated) ~= 'table' or seated.vehicleId == nil then
        return refuse(src, 'notSeated')
    end
    local hullId = seated.vehicleId
    local readHull, hull = pcall(api.get, hullId)
    if not readHull or type(hull) ~= 'table' then return refuse(src, 'noAircraft', tostring(hullId)) end
    if not M.Flies(hull.record) then return refuse(src, 'notAv', tostring(hull.record)) end
    -- ONE PILOT PER AIRFRAME. Two runs on one hull would be two controllers
    -- posing the same body at the same cadence.
    for _, other in pairs(runs) do
        if tostring(other.hullId) == tostring(hullId) then
            return refuse(src, 'busy', ('run by player %d'):format(other.playerId))
        end
    end
    -- WHOEVER FLIES IT (1.1.0). Being aboard is not flying: a passenger behind
    -- a pilot is in the same hull, and without this read could freeze the
    -- pilot's aircraft and fly it to a pin of their own. But the Open77 client
    -- flies an AV from any seat, so the pilot is whoever flies it.
    local seat = seatName(seated.seat) or tostring(seated.seat)
    local pilot, how = M.PilotOf(hull, hullId)
    if pilot ~= src then
        return refuse(src, 'notPilot', pilot ~= nil and ('player %d flies it (%s); this player sits in %s')
            :format(pilot, tostring(how), seat) or ('nobody aboard can be named its pilot; this player sits in %s')
            :format(seat))
    end

    -- THE DESTINATION IS THE ONLY THING THE PAYLOAD MAY SAY. "No waypoint" and
    -- "the map would not answer" are different things to fix.
    local to = nil
    if type(payload) == 'table' then to = M.Destination(payload.position) end
    if to == nil then
        local unreadable = type(payload) == 'table' and payload.unreadable == true
        return refuse(src, unreadable and 'waypointUnavailable' or 'noWaypoint')
    end

    local from = at(hull)
    if from == nil then return refuse(src, 'noAircraft', 'no canonical position') end
    local dx, dy = to.x - from.x, to.y - from.y
    local range = math.sqrt(dx * dx + dy * dy)
    if range > plan.maxRange then
        return refuse(src, 'tooFar', ('%.0f m, at most %.0f m'):format(range, plan.maxRange))
    end

    -- THE GEOMETRY, ALL ARITHMETIC BEFORE ANYTHING MOVES. The cruise altitude is
    -- measured from the HIGHER of the two ends; the release height is clamped
    -- below the cruise leg so a config that hovers higher than it cruises is a
    -- zero-length descent and not a climb that calls itself a descent.
    if M.Travel() == 'arrive' then return M.Arrive(src, hullId, hull, seat, how, from, to, range, plan, now) end

    local cruiseZ = math.max(from.z, to.z) + plan.cruiseAltitude
    local releaseZ = math.min(to.z + plan.hoverHeight, cruiseZ)
    local run = {
        mode = 'fly', seat = seat, how = how,
        playerId = src, hullId = hullId, plan = plan, from = from, to = to,
        cruiseZ = cruiseZ, releaseZ = releaseZ, heading = M.HeadingTo(from, to), fromYaw = nil,
        leg = 1, legClock = 0.0, legPhase = nil, clock = 0.0, refused = 0, poses = 0,
        handle = nil, tickAt = now or M.Now(), last = from, record = hull.record,
        legs = {
            { phase = PHASE.CLIMB, seconds = math.max(0.0, cruiseZ - from.z) / plan.climbSpeed },
            { phase = PHASE.CRUISE, seconds = range / plan.cruiseSpeed },
            { phase = PHASE.DESCEND, seconds = math.max(0.0, cruiseZ - releaseZ) / plan.descendSpeed },
        },
    }
    local standing = tonumber(hull.yaw or hull.heading)
    if standing ~= nil and standing == standing and math.abs(standing) ~= math.huge then
        run.fromYaw = standing % 360.0
    else
        run.fromYaw = run.heading
    end

    -- FROZEN BEFORE THE FIRST POSE, and the order is the whole of the hand-over:
    -- the pilot's client claims the hull the moment it sees the seat, and a
    -- claim accepted before the freeze is a claim whose reports are merged for
    -- as long as the gap lasts.
    local frozen = 'no setFrozen on this host: the pilot\'s own reports are merged'
    if type(api.setFrozen) == 'function' then
        local called, ok, reason = pcall(api.setFrozen, hullId, true)
        run.frozen = true
        frozen = (called and ok ~= false) and 'frozen' or ('the freeze was refused: '
            .. tostring(called and reason or ok))
    end
    runs[src] = run
    if now == nil then
        run.handle = every(('flight of %d'):format(src), plan.tickMs, function() M.Step(src) end)
    end

    Open77.log.info(('autopilot for %d: %s (%s) from %.0f, %.0f, %.0f to %.0f, %.0f, %.0f -- %.0f m, cruise %.0f m '
        .. 'up, hover %.0f m over the pin, %.1fs of legs (climb %.1f, cruise %.1f, descent %.1f), heading %.0f, %s; '
        .. 'flown (TRAVEL = fly) by %s, %s -- each pose takes the flight from their game: their view flickers')
        :format(src, tostring(hullId), tostring(hull.record), from.x, from.y, from.z, to.x, to.y, to.z, range,
            cruiseZ - from.z, releaseZ - to.z,
            run.legs[1].seconds + run.legs[2].seconds + run.legs[3].seconds,
            run.legs[1].seconds, run.legs[2].seconds, run.legs[3].seconds, run.heading, frozen, tostring(src),
            tostring(how)))
    notice(src, 'engaged', 'success')
    return true
end

-- ── the arrival (1.1.0; flown under the black since 1.2.0) ───────────────────
--
-- 1.1.0 PLACED the aircraft over the pin in one move under the black: 1 080 m
-- on Staging (2026-10-30), and the pilot's game never came back -- "stuck on a
-- loadscreen forever". The platform cannot carry a mounted player far in one
-- move (its own teleport refuses a player in a vehicle for that reason), the
-- game's loading screen keeps that client "not ready", and a client that is
-- not ready may not take its aircraft back. So 1.2.0 FLIES it there under the
-- black, in steps of a few metres, at the pace the pilot's game keeps: it says
-- four times a second where it draws the hull and whether a loading screen is
-- up, and the server holds the flight while that game lags more than
-- `LEASH_METRES` behind or is loading. One that never follows for `STALL_MS`
-- ends the flight where that game draws the hull. No move is ever farther
-- than one step.

local serial = 0

--- Tells the screens of a run's crew something about the arrival. `pilot`
--- says, to each game, whether it is the one that answers.
local function toCrew(run, body)
    for player in pairs(run.crew) do
        local message = {}
        for k, v in pairs(body) do message[k] = v end
        message.pilot = player == run.playerId
        pcall(TriggerClientEvent, M.Event.ARRIVE, player, message)
    end
end

--- The screens back (the arrival's fade in), once: the end of every arrival,
--- whatever ended it. `watch` (1.2.0): the aircraft was handed back, and the
--- pilot's game watches for the controls (`OWN_WAIT_MS`) and says.
-- @param run table
-- @param why string
-- @param watch boolean|nil
function M.FadeIn(run, why, watch)
    if run.fadedIn or not run.fadeAsked then return end
    run.fadedIn = true
    toCrew(run, { token = run.token, state = 'in', ms = run.arrive.fadeIn,
        ownWaitMs = watch and run.arrive.ownWait or nil, why = tostring(why):sub(1, 80) })
end

local function distance(a, b)
    return math.sqrt((a.x - b.x) ^ 2 + (a.y - b.y) ^ 2 + (a.z - b.z) ^ 2)
end

--- One pose of an arrival, said in the log when the host refuses.
local function pose(run, p, why)
    local api = vehicles()
    local called, moved, reason = pcall(api.setTransform, run.hullId, { x = p.x, y = p.y, z = p.z, yaw = run.heading })
    run.poses = run.poses + 1
    if not called or moved ~= true then
        run.refused = run.refused + 1
        if run.refused == 1 or run.refused % 20 == 0 then
            Open77.log.warn(('autopilot for %d (arrive): a pose %s was refused (%d so far): %s'):format(run.playerId,
                why, run.refused, tostring(called and reason or moved)))
        end
        return false
    end
    run.last = { x = p.x, y = p.y, z = p.z }
    return true
end

--- The canonical engine flag, for the log: an aircraft handed back hovering
--- with its engine off is one to look at.
local function engineWord(hullId)
    local api = vehicles()
    if api == nil or type(api.isEngineOn) ~= 'function' then return 'engine unknown (no isEngineOn on this host)' end
    local read, on, reason = pcall(api.isEngineOn, hullId)
    if not read then return 'engine unknown (' .. tostring(on) .. ')' end
    if on == nil then return 'engine unknown (' .. tostring(reason) .. ')' end
    return on and 'engine on' or 'engine OFF'
end

--- The platform's word on who simulates the aircraft, for the log: the lease
--- (`physicsOwner`, its epoch and why it last changed) and the controller.
local function ownerWord(hullId)
    local api = vehicles()
    if api == nil or type(api.owner) ~= 'function' then return 'its owner unknown (no owner on this host)' end
    local read, info, reason = pcall(api.owner, hullId)
    if not read then return 'its owner unknown (' .. tostring(info) .. ')' end
    if type(info) ~= 'table' then return 'its owner unknown (' .. tostring(reason) .. ')' end
    local owner = tonumber(info.physicsOwner or info.authorityPlayerId)
    return ('simulated by %s (epoch %s, %s, %s ms ago), controller %s'):format(
        (owner ~= nil and owner > 0) and ('player ' .. math.floor(owner)) or 'nobody', tostring(info.epoch or '?'),
        tostring(info.reason or '?'), tostring(info.ageMs or '?'), info.driver ~= nil and ('player ' .. tostring(info.driver))
        or 'none')
end

--- The route under the black, as legs: up to the cruise height over where it
--- is, across, down to the hover. A leg shorter than 5 cm is left out.
-- @return table[] `{ a, b, len, speed, name }`
-- @return number the total length
function M.Route(from, to, hoverZ, cruiseZ, cfg)
    local points = { { x = from.x, y = from.y, z = from.z } }
    local function add(p)
        if distance(points[#points], p) > 0.05 then points[#points + 1] = p end
    end
    add({ x = from.x, y = from.y, z = cruiseZ })
    add({ x = to.x, y = to.y, z = cruiseZ })
    add({ x = to.x, y = to.y, z = hoverZ })
    local legs, total = {}, 0.0
    for i = 2, #points do
        local a, b = points[i - 1], points[i]
        local across = math.sqrt((a.x - b.x) ^ 2 + (a.y - b.y) ^ 2)
        local len = distance(a, b)
        legs[#legs + 1] = { a = a, b = b, len = len, speed = across > 0.5 and cfg.speed or cfg.climb,
            name = across > 0.5 and 'across' or (b.z > a.z and 'up' or 'down') }
        total = total + len
    end
    return legs, total
end

--- ARRIVE, DO NOT FLY IN VIEW: everybody aboard fades to black, the hull is
--- flown to the pin under the black (`M.Launch`, `M.StepArrive`), the pilot's
--- game measures the ground there, the controls come back, the screens come
--- back, and the pilot's game is watched taking the aircraft back.
function M.Arrive(src, hullId, hull, seat, how, from, to, range, plan, now)
    local cfg = M.ArriveSettings()
    serial = serial + 1
    local crew = M.Crew(hull)
    crew[src] = crew[src] or seat
    local names = {}
    for player, where in pairs(crew) do names[#names + 1] = ('%d:%s'):format(player, where) end
    table.sort(names)
    local run = {
        mode = 'arrive', seat = seat, how = how, playerId = src, hullId = hullId, plan = plan, from = from, to = to,
        heading = M.HeadingTo(from, to), hoverZ = to.z + plan.hoverHeight, crew = crew, arrive = cfg,
        token = ('%d:%d'):format(src, serial), phase = 'fading', since = now or M.Now(), poses = 0, refused = 0,
        last = from, record = hull.record, clock = 0.0, fadeAsked = false, fadedIn = false, held = 0.0,
    }
    runs[src] = run
    run.fadeAsked = true
    toCrew(run, { token = run.token, state = 'out', ms = cfg.fadeOut, timeoutMs = 60000, paceMs = cfg.pace })
    if now == nil then
        run.handle = every(('arrival of %d'):format(src), cfg.tick, function() M.StepArrive(src) end)
    end
    Open77.log.info(('autopilot for %d: %s (%s) from %.0f, %.0f, %.0f to %.0f, %.0f, %.0f -- %.0f m; ARRIVE (TRAVEL = '
        .. 'arrive): the screens of %s fade out (%d ms), then the aircraft is flown there under the black at %.0f m/s '
        .. '(%.0f up and down) at the pace the pilot\'s game keeps, to %.0f m over the pin facing %.0f; the ground there '
        .. 'measured by the pilot\'s game, the controls and the screens back; the pilot %s, %s')
        :format(src, tostring(hullId), tostring(hull.record), from.x, from.y, from.z, to.x, to.y, to.z, range,
            table.concat(names, ', '), cfg.fadeOut, cfg.speed, cfg.climb, plan.hoverHeight, M.HeadingTo(from, to),
            tostring(how), engineWord(hullId)))
    notice(src, 'arriving', 'success')
    return true
end

--- The pilot's screen is black (or it will not be): frozen, and the flight
--- under the black begins from wherever the hull stands now.
function M.Launch(run, now, how)
    local api = vehicles()
    local frozen = 'no setFrozen on this host: the pilot\'s own reports are merged'
    if type(api.setFrozen) == 'function' then
        local called, ok, reason = pcall(api.setFrozen, run.hullId, true)
        run.frozen = true
        frozen = (called and ok ~= false) and 'frozen' or ('the freeze was refused: ' .. tostring(called and reason or ok))
    end
    local start = nil
    local readHull, hull = pcall(api.get, run.hullId)
    if readHull then start = at(hull) end
    start = start or run.from
    local cfg = run.arrive
    -- The arrival's own height over the higher end (`ARRIVE.CRUISE_ABOVE`):
    -- under the black nobody sees the route, and every metre up is a metre
    -- down again before the screens come back.
    local cruiseZ = math.max(start.z, run.to.z) + cfg.cruiseAbove
    run.legs, run.length = M.Route(start, run.to, run.hoverZ, cruiseZ, cfg)
    -- A long way is flown faster, so the black stays under `MAX_FLIGHT_MS`.
    local estimate = 0.0
    for _, leg in ipairs(run.legs) do estimate = estimate + leg.len / leg.speed end
    run.boost = 1.0
    if estimate * 1000.0 > cfg.maxFlight then run.boost = estimate * 1000.0 / cfg.maxFlight end
    run.leg, run.legPos, run.flown = 1, 0.0, 0.0
    run.phase, run.launchedAt, run.tickAt, run.reportAt = 'flying', now, now, now
    Open77.log.info(('autopilot for %d (arrive): %s %.1fs after the key -- %s; flown under the black from %.0f, %.0f, %.0f: '
        .. '%d leg(s), %.0f m (up %.0f m to %.0f, across %.0f m, down to %.1f), about %.1fs%s; the pilot\'s game reports '
        .. 'every %d ms and the flight holds while its body lags more than %.0f m (%.0fs at most) or it is loading or '
        .. 'silent (%.0fs at most)')
        :format(run.playerId, how, (now - run.since) / 1000.0, frozen, start.x, start.y, start.z, #run.legs, run.length,
            cruiseZ - start.z, cruiseZ, math.sqrt((start.x - run.to.x) ^ 2 + (start.y - run.to.y) ^ 2), run.hoverZ,
            estimate / run.boost, run.boost > 1.0 and (' (%.1fx the speed: the black stays under %.0fs)')
                :format(run.boost, cfg.maxFlight / 1000.0) or '', cfg.pace, cfg.leash, cfg.stall / 1000.0,
            cfg.loadingWait / 1000.0))
end

--- The arrival's hand-over: the freeze off, the screens back a moment later.
local function handBack(run, now, how)
    local api = vehicles()
    local released = 'no setFrozen on this host'
    if not run.frozen then
        released = 'was never on'
    elseif api ~= nil and type(api.setFrozen) == 'function' then
        local called, ok, reason = pcall(api.setFrozen, run.hullId, false)
        released = (called and ok ~= false) and 'is off' or ('could not be taken off: '
            .. tostring(called and reason or ok))
    end
    run.frozenOff = true
    run.phase, run.handAt = 'handing', now
    local here = run.last or run.from
    local where = run.stalled and ('left at %.0f, %.0f, %.1f, %.0f m short of the pin (%s)'):format(here.x, here.y, here.z,
        math.sqrt((here.x - run.to.x) ^ 2 + (here.y - run.to.y) ^ 2), how)
        or ('hovering at %.1f, %.1f m over the pin\'s own height (%s)'):format(here.z, here.z - run.to.z, how)
    Open77.log.info(('autopilot for %d (arrive): %s, %.1fs after the key; the freeze %s, %s, %s -- the pilot\'s game takes '
        .. 'the aircraft back, the screens back in %d ms'):format(run.playerId, where, (now - run.since) / 1000.0, released,
        engineWord(run.hullId), ownerWord(run.hullId), run.arrive.handBack))
end

--- The flight is over the pin: the pilot's game measures the ground there.
local function overPin(run, now)
    run.phase, run.placedAt = 'settling', now
    Open77.log.info(('autopilot for %d (arrive): over the pin at %.0f, %.0f, %.1f after %.1fs under the black -- %d pose(s), '
        .. '%d refused, held %.1fs for the pilot\'s game; the ground there measured in %d ms (%d ms at most)')
        :format(run.playerId, run.to.x, run.to.y, run.hoverZ, (now - run.launchedAt) / 1000.0, run.poses, run.refused,
            run.held, run.arrive.settle, run.arrive.measure))
    pcall(TriggerClientEvent, M.Event.ARRIVE, run.playerId, { token = run.token, state = 'measure', x = run.to.x,
        y = run.to.y, fromZ = run.to.z + 500.0, settleMs = run.arrive.settle, measureMs = run.arrive.measure,
        hoverZ = run.hoverZ, pilot = true })
end

--- The flight given up: the hull is put where the pilot's game draws it (one
--- step back, under the black), handed back, and the screens come back.
local function stall(run, now, why)
    -- Where the pilot's game has the aircraft: its body in it, else its copy
    -- of the hull. The engine's view is what must not jump.
    local back = run.pace and (run.pace.bodyAt or run.pace.drawn) or nil
    local moved = 'left where the server has it'
    if back ~= nil and run.last ~= nil and distance(back, run.last) > 1.0 then
        local before = run.last
        if pose(run, back, 'back to where the pilot\'s game has it') then
            moved = ('put back %.0f m, to where the pilot\'s game has it (%s)'):format(distance(before, back),
                run.pace.bodyAt ~= nil and 'its body' or 'its copy of the aircraft')
        end
    end
    Open77.log.warn(('autopilot for %d (arrive): the flight under the black GIVEN UP after %.1fs, %.0f of %.0f m flown -- %s; '
        .. 'the aircraft %s'):format(run.playerId, (now - run.launchedAt) / 1000.0, run.flown, run.length, why, moved))
    run.stalled = why
    handBack(run, now, 'the flight was given up')
end

--- The point `s` metres into the current leg.
local function onLeg(leg, s)
    local t = leg.len > 0 and math.min(1.0, s / leg.len) or 1.0
    return { x = leg.a.x + (leg.b.x - leg.a.x) * t, y = leg.a.y + (leg.b.y - leg.a.y) * t,
        z = leg.a.z + (leg.b.z - leg.a.z) * t }
end

--- One tick of the flight under the black.
local function fly(run, now)
    local cfg = run.arrive
    local pace = run.pace
    -- WHY IT HOLDS, AND FOR HOW LONG. A game that never said anything, or
    -- whose aircraft is not where the flight is, gets `STALL_MS`; a game that
    -- is loading -- or went silent after it had been talking, which is what a
    -- game stuck in a loading screen looks like from here -- gets
    -- `LOADING_WAIT_MS`.
    local waiting, patience = nil, cfg.stall
    if pace == nil then
        waiting = ('no word from the pilot\'s game yet, %.1fs after the launch'):format((now - run.launchedAt) / 1000.0)
    elseif now - pace.time > cfg.paceStale then
        waiting, patience = ('no word from the pilot\'s game for %.1fs'):format((now - pace.time) / 1000.0),
            cfg.loadingWait
    elseif pace.loading then
        waiting, patience = ('a loading screen is up in the pilot\'s game (%s)'):format(tostring(pace.loadingKind or '?')),
            cfg.loadingWait
    elseif pace.lag == nil and pace.undrawn ~= nil and pace.undrawn ~= 'no api' then
        waiting = ('the pilot\'s game has no aircraft to show (%s)'):format(pace.undrawn)
    elseif pace.lag ~= nil and pace.lag > cfg.leash then
        waiting = ('%s is %.0f m behind the flight'):format(pace.by or 'the pilot\'s game', pace.lag)
    end
    local dt = math.max(0.0, math.min(0.3, (now - (run.tickAt or now)) / 1000.0))
    run.tickAt = now
    if waiting ~= nil then
        if run.heldSince == nil then
            run.heldSince = now
            Open77.log.info(('autopilot for %d (arrive): the flight holds, %.0f of %.0f m flown -- %s'):format(run.playerId,
                run.flown, run.length, waiting))
        end
        run.held = run.held + dt
        if now - run.heldSince >= patience then
            return stall(run, now, ('%s (held %.1fs)'):format(waiting, (now - run.heldSince) / 1000.0))
        end
        return
    end
    if run.heldSince ~= nil then
        Open77.log.info(('autopilot for %d (arrive): the flight goes on after %.1fs held'):format(run.playerId,
            (now - run.heldSince) / 1000.0))
        run.heldSince = nil
    end
    local budget = dt
    local p = nil
    while budget > 0 and run.leg <= #run.legs do
        local leg = run.legs[run.leg]
        local speed = leg.speed * run.boost
        local left = leg.len - run.legPos
        local step = speed * budget
        if step < left then
            run.legPos = run.legPos + step
            run.flown = run.flown + step
            budget = 0
        else
            run.flown = run.flown + left
            budget = budget - left / speed
            run.leg, run.legPos = run.leg + 1, 0.0
            if run.leg <= #run.legs then
                Open77.log.info(('autopilot for %d (arrive): the %s leg done, %.0f of %.0f m flown, %.1fs under the black')
                    :format(run.playerId, leg.name, run.flown, run.length, (now - run.launchedAt) / 1000.0))
            end
        end
        p = run.leg <= #run.legs and onLeg(run.legs[run.leg], run.legPos) or run.legs[#run.legs].b
    end
    if p ~= nil then pose(run, p, 'under the black') end
    if now - (run.reportAt or now) >= 2000 then
        run.reportAt = now
        Open77.log.info(('autopilot for %d (arrive): %.0f of %.0f m flown, %.1fs under the black; %s %s, its body %s from '
            .. 'its copy of the aircraft%s'):format(run.playerId, run.flown, run.length, (now - run.launchedAt) / 1000.0,
            pace.by or 'the pilot\'s game', pace.lag ~= nil and ('%.0f m behind'):format(pace.lag) or 'nowhere to be seen',
            pace.body ~= nil and ('%.1f m'):format(pace.body) or '?', pace.owned and ', simulating it' or ''))
    end
    if run.leg > #run.legs then overPin(run, now) end
end

-- How long a raised hull is left frozen before the hand-over: the raise reaches
-- the pilot's game before the freeze comes off.
local RAISE_SETTLE_MS = 300

--- The end of an arrival that went all the way: once the pilot's game says
--- whether it took the aircraft back (or `OWN_WAIT_MS` passed), a game that
--- did not is handed it by the platform (`requestAuthority`), said either way.
local function settle(run, owned, how)
    local api = vehicles()
    local answer = 'its game took it back'
    local before = ownerWord(run.hullId)
    if not owned then
        -- THE SAFETY NET. The platform's own election, asked by name: the pilot
        -- is the seated controller, so this is the one grant that is not a
        -- steal. A game that cannot keep a lease (one still loading) loses it
        -- again, and the next lines of the log say so.
        if api ~= nil and type(api.requestAuthority) == 'function' then
            local called, read, reason = pcall(api.requestAuthority, run.hullId, run.playerId)
            if called and type(read) == 'table' and reason == 'already_owner' then
                answer = ('the platform was asked to hand it over: its game has it already (owner %s)')
                    :format(tostring(read.physicsOwner))
            elseif called and type(read) == 'table' then
                answer = ('the platform was asked to hand it over: granted (owner %s)'):format(tostring(read.physicsOwner))
            else
                answer = ('the platform was asked to hand it over: refused (%s)'):format(tostring(called and reason or read))
            end
        else
            answer = 'no requestAuthority on this host'
        end
    end
    Open77.log.info(('autopilot for %d (arrive): after the image came back -- %s; %s; the platform had it %s'):format(
        run.playerId, how, answer, before))
    if run.stalled then return M.Finish(run, 'the flight under the black was given up', 'stalled') end
    M.Finish(run, 'arrived over the waypoint', 'arrived', 'success')
end

--- One tick of an arrival. The seat is re-read every one, as for a flight.
function M.StepArrive(playerId, now)
    local run = runs[playerId]
    if run == nil or run.mode ~= 'arrive' then return end
    now = now or M.Now()
    local api = vehicles()
    if api == nil or type(api.get) ~= 'function' then return M.Finish(run, 'the vehicle API went away', 'cancelled') end
    local readHull, hull = pcall(api.get, run.hullId)
    if not readHull or hull == nil then return M.Finish(run, 'the airframe was taken away', 'cancelled') end
    local readSeat, seated = false, nil
    if type(api.getPlayerSeat) == 'function' then readSeat, seated = pcall(api.getPlayerSeat, playerId) end
    if not readSeat or type(seated) ~= 'table' or tostring(seated.vehicleId) ~= tostring(run.hullId)
        or (seatName(seated.seat) or tostring(seated.seat)) ~= run.seat then
        return M.Finish(run, 'the pilot left the controls', 'pilotLeft')
    end
    run.clock = (now - run.since) / 1000.0
    if run.clock > run.plan.maxSeconds then
        return M.Finish(run, 'the arrival reached its ceiling of MAX_MINUTES', 'timeout')
    end
    local cfg = run.arrive
    if run.phase == 'fading' then
        if now - run.since >= cfg.fadeWait then
            M.Launch(run, now, ('no word that the pilot\'s screen is black after %d ms: flown all the same'):format(
                cfg.fadeWait))
        end
        return
    end
    if run.phase == 'flying' then return fly(run, now) end
    if run.phase == 'settling' then
        if now - run.placedAt >= cfg.settle + cfg.measure + 1500 then
            handBack(run, now, ('no measure from the pilot\'s game after %.1fs: %.0f m over the pin\'s height'):format(
                (now - run.placedAt) / 1000.0, run.plan.hoverHeight))
        end
        return
    end
    if run.phase == 'raising' then
        if run.raisedAt == nil then
            local dt = math.max(0.0, math.min(0.3, (now - (run.tickAt or now)) / 1000.0))
            run.tickAt = now
            run.raiseZ = math.min(run.hoverZ, run.raiseZ + cfg.climb * dt)
            pose(run, { x = run.to.x, y = run.to.y, z = run.raiseZ }, 'over the measured ground')
            if run.raiseZ >= run.hoverZ then run.raisedAt = now end
            return
        end
        if now - run.raisedAt >= RAISE_SETTLE_MS then handBack(run, now, run.raiseWhy) end
        return
    end
    if run.phase == 'handing' and now - run.handAt >= cfg.handBack then
        run.phase, run.watchAt = 'watching', now
        M.FadeIn(run, run.stalled and 'the flight was given up' or 'arrived over the waypoint', true)
        return
    end
    if run.phase == 'watching' and now - run.watchAt >= cfg.ownWait + 1000 then
        return settle(run, false, ('no word from the pilot\'s game %.1fs after the screens came back'):format(
            (now - run.watchAt) / 1000.0))
    end
end

--- The pilot's game's word on the arrival (`ARRIVE_READY`): its screen black,
--- its fade refused or cancelled, where it draws the hull while it is flown,
--- the ground under the hover, and whether it took the aircraft back. A word
--- for another token, or out of its phase, moves nothing (said once).
-- @param playerId number the sender (`source`)
-- @param payload table `{ token, state, ... }`
-- @param now number|nil
function M.ArriveWord(playerId, payload, now)
    local run = runs[playerId]
    if run == nil or run.mode ~= 'arrive' or type(payload) ~= 'table' or payload.token ~= run.token then return false end
    now = now or M.Now()
    local state = payload.state
    if run.phase == 'fading' and (state == 'black' or state == 'failed') then
        M.Launch(run, now, state == 'black' and ('the pilot\'s screen is black (%s ms by its clock)'):format(
            tostring(tonumber(payload.ms) and math.floor(tonumber(payload.ms)) or '?'))
            or ('the pilot\'s game could not fade (%s): flown in view'):format(tostring(payload.reason):sub(1, 80)))
        return true
    end
    if state == 'pace' and (run.phase == 'flying' or run.phase == 'fading') then
        -- Where the pilot's game has the aircraft: its copy of the hull (the
        -- last pose it was sent) and, the engine's own truth, its body in it.
        local drawn, bodyAt = M.Destination(payload.drawn), M.Destination(payload.bodyAt)
        local seen = bodyAt or drawn
        local body = tonumber(payload.body)
        run.pace = { time = now, drawn = drawn, bodyAt = bodyAt, loading = payload.loading == true,
            loadingKind = type(payload.loadingKind) == 'string' and payload.loadingKind:sub(1, 20) or nil,
            body = (body ~= nil and body == body) and body or nil, owned = payload.owned == true,
            undrawn = type(payload.undrawn) == 'string' and payload.undrawn:sub(1, 40) or nil,
            by = bodyAt ~= nil and 'the pilot\'s body' or (drawn ~= nil and 'the pilot\'s copy of the aircraft' or nil),
            lag = (seen ~= nil and run.last ~= nil) and distance(seen, run.last) or nil }
        run.paces = (run.paces or 0) + 1
        if run.pace.loading and not run.sawLoading then
            run.sawLoading = true
            Open77.log.warn(('autopilot for %d (arrive): the pilot\'s game reports a LOADING SCREEN (%s) in the %s phase, '
                .. '%.0f of %.0f m flown'):format(run.playerId, tostring(run.pace.loadingKind or '?'), run.phase,
                run.flown or 0, run.length or 0))
        end
        return true
    end
    if run.phase == 'flying' and state == 'failed' then
        -- The pilot's fade ended under the flight (its safety deadline, a vanilla
        -- transition): flying on in view would flicker. Given up where it is drawn.
        stall(run, now, ('the pilot\'s screen came back during the flight (%s)'):format(tostring(payload.reason):sub(1, 60)))
        return true
    end
    if run.phase == 'settling' and state == 'ground' then
        local ground = tonumber(payload.z)
        local reads, ms = tonumber(payload.reads) or 0, tonumber(payload.ms) or 0
        local by = tostring(payload.by or 'a ray'):sub(1, 40)
        local ready = ('; the pilot\'s game draws it %s from the hover, its body %s from it, %s'):format(
            tonumber(payload.drawnOff) and ('%.1f m'):format(tonumber(payload.drawnOff)) or '?',
            tonumber(payload.body) and ('%.1f m'):format(tonumber(payload.body)) or '?',
            payload.loading == true and 'a LOADING SCREEN up' or 'no loading screen')
        if ground ~= nil and ground == ground and ground > run.to.z - 200.0 and ground < run.to.z + 600.0 then
            local wanted = ground + run.plan.hoverHeight
            if wanted > run.hoverZ + 0.5 then
                -- RAISED IN STEPS TOO (1.2.0): up at `CLIMB_SPEED`, never one
                -- move of the whole height.
                local before = run.hoverZ
                run.hoverZ, run.raiseZ, run.tickAt = wanted, before, now
                run.phase, run.raisedAt = 'raising', nil
                run.raiseWhy = ('the ground measured at %.1f by %s (%d read(s), %.1fs): raised %.1f m, from %.1f, to %.0f m '
                    .. 'over it%s'):format(ground, by, reads, ms / 1000.0, wanted - before, before, run.plan.hoverHeight,
                    ready)
                Open77.log.info(('autopilot for %d (arrive): %s -- up at %.0f m/s, the freeze on %d ms more once there')
                    :format(run.playerId, run.raiseWhy, run.arrive.climb, RAISE_SETTLE_MS))
            else
                handBack(run, now, ('the ground measured at %.1f by %s (%d read(s), %.1fs): %.1f m over it%s'):format(ground,
                    by, reads, ms / 1000.0, run.hoverZ - ground, ready))
            end
        else
            handBack(run, now, ('no usable ground from the pilot\'s game (%s, %d read(s), %.1fs): %.0f m over the pin\'s '
                .. 'height%s'):format(tostring(payload.z), reads, ms / 1000.0, run.plan.hoverHeight, ready))
        end
        return true
    end
    if run.phase == 'watching' and state == 'after' then
        settle(run, payload.owned == true, ('its game %s %.1fs after the image came back%s'):format(
            payload.owned == true and 'simulates the aircraft' or 'does NOT simulate the aircraft',
            (tonumber(payload.ms) or 0) / 1000.0, payload.loading == true and ', a LOADING SCREEN up' or ''))
        return true
    end
    -- The pilot's game says where it has the aircraft until the 'measure' or
    -- the 'in' reaches it: a report after the flight is expected, and nothing.
    if state == 'pace' then return false end
    run.ignored = run.ignored or {}
    local word = tostring(state):sub(1, 20)
    if not run.ignored[word .. run.phase] then
        run.ignored[word .. run.phase] = true
        Open77.log.info(('autopilot for %d (arrive): the pilot\'s game said %q in the %s phase -- nothing to do')
            :format(run.playerId, word, run.phase))
    end
    return false
end

--- The one press off the wire. A run in flight is the OFF half of the toggle,
--- wherever the aircraft happens to be; anything else is an ask to engage.
-- @param src number
-- @param payload table|nil
-- @param now number|nil the clock, for the suite
function M.Toggle(src, payload, now)
    src = validPlayer(src)
    if src == nil then return false, 'no_player' end
    local window = cooldownMs()
    local clock = now or M.Now()
    if window > 0 and pressed[src] ~= nil and clock - pressed[src] < window then
        notice(src, 'rateLimited', 'error')
        return false, 'rateLimited'
    end
    pressed[src] = clock
    local run = runs[src]
    if run ~= nil then
        M.Finish(run, 'the pilot took the controls', 'cancelled')
        return true, 'cancelled'
    end
    return M.Engage(src, payload, now)
end

--- What is flying, for the console, the exports and the suite.
-- @return table[] `{ playerId, hullId, leg, clock, poses, refused }`
function M.Status()
    local out = {}
    for _, run in pairs(runs) do
        out[#out + 1] = { playerId = run.playerId, hullId = tostring(run.hullId), mode = run.mode or 'fly',
            leg = run.mode == 'arrive' and run.phase or run.legs[run.leg].phase,
            clock = run.mode == 'arrive' and (M.Now() - run.since) / 1000.0 or run.clock,
            poses = run.poses, refused = run.refused, to = { x = run.to.x, y = run.to.y, z = run.to.z } }
    end
    table.sort(out, function(a, b) return a.playerId < b.playerId end)
    return out
end

--- Ends a pilot's run from another resource or the console.
function M.Cancel(playerId, why)
    local run = runs[validPlayer(playerId) or -1]
    if run == nil then return false end
    return M.Finish(run, why or 'cancelled by the server', 'cancelled')
end

--- Takes every flight down: no aircraft is left frozen at altitude with
--- nobody left to unfreeze it.
function M.Stop(why)
    local list = {}
    for _, run in pairs(runs) do list[#list + 1] = run end
    for index = 1, #list do M.Finish(list[index], why or 'the resource stopped', 'cancelled') end
end

--- Forgets everything, without touching the host: for the suite.
function M.Reset()
    runs, pressed = {}, {}
end

--- Says each bad number by name: the reader falls back to the default, and an
--- operator who mistyped a knob must not learn it by the aircraft flying at
--- the wrong speed.
local function checkConfig()
    local config = settings()
    local function warn(name, line)
        local value = tonumber(config[name])
        if value == nil or value ~= value or value < 0 then
            Open77.log.warn(('config: %s %s, the default is used'):format(name, line))
        end
    end
    warn('CRUISE_ALTITUDE', 'is not a height')
    warn('CRUISE_SPEED', 'is not a speed')
    warn('CLIMB_SPEED', 'is not a rate')
    warn('DESCEND_SPEED', 'is not a rate')
    warn('HOVER_HEIGHT', 'is not a height')
    warn('MAX_RANGE', 'is not a distance')
    warn('MAX_MINUTES', 'is not a duration')
    warn('TICK_MS', 'is not a cadence')
    warn('COOLDOWN_MS', 'is not a window')
    if config.TRAVEL ~= nil and config.TRAVEL ~= 'arrive' and config.TRAVEL ~= 'fly' then
        Open77.log.warn(('config: TRAVEL %s is neither \'arrive\' nor \'fly\': the aircraft arrives')
            :format(tostring(config.TRAVEL)))
    end
    if config.ARRIVE ~= nil and type(config.ARRIVE) ~= 'table' then
        Open77.log.warn('config: ARRIVE is not a table: the defaults are used')
    elseif type(config.ARRIVE) == 'table' then
        local known = {}
        for _, name in ipairs({ 'FADE_OUT_MS', 'FADE_WAIT_MS', 'SETTLE_MS', 'MEASURE_MS', 'HAND_BACK_MS', 'FADE_IN_MS',
            'SPEED', 'CLIMB_SPEED', 'CRUISE_ABOVE', 'LEASH_METRES', 'STALL_MS', 'LOADING_WAIT_MS', 'PACE_MS',
            'PACE_STALE_MS', 'MAX_FLIGHT_MS', 'OWN_WAIT_MS' }) do
            known[name] = true
            local value = config.ARRIVE[name]
            if value ~= nil and (tonumber(value) == nil or tonumber(value) ~= tonumber(value)) then
                Open77.log.warn(('config: ARRIVE.%s is not a number, the default is used'):format(name))
            end
        end
        for name in pairs(config.ARRIVE) do
            if not known[name] then
                Open77.log.warn(('config: ARRIVE.%s is not a setting this version reads'):format(tostring(name)))
            end
        end
    end
end

function M.Start()
    M.Reset()
    checkConfig()

    RegisterNetEvent(M.Event.TOGGLE, function(payload)
        local src = validPlayer(source)
        if src == nil then return end
        local ran, failure = pcall(M.Toggle, src, payload)
        if not ran then Open77.log.error(('the toggle of %d failed: %s'):format(src, tostring(failure))) end
    end)

    -- The pilot's game on the arrival: only the run's own pilot is heard.
    RegisterNetEvent(M.Event.ARRIVE_READY, function(payload)
        local src = validPlayer(source)
        if src == nil then return end
        local ran, failure = pcall(M.ArriveWord, src, payload)
        if not ran then Open77.log.error(('the arrival word of %d failed: %s'):format(src, tostring(failure))) end
    end)

    -- A pilot who vanishes mid-flight leaves an aircraft frozen under a run
    -- nobody will ever press a key for again.
    AddEventHandler('onPlayerDisconnected', function(playerId)
        local id = validPlayer(playerId)
        if id == nil then return end
        pressed[id] = nil
        local run = runs[id]
        if run ~= nil then M.Finish(run, 'the pilot disconnected', nil) end
    end)

    -- An aircraft taken out of the world takes its run with it now, not at
    -- the next tick's read.
    AddEventHandler('onVehicleRemoved', function(id)
        for _, run in pairs(runs) do
            if tostring(run.hullId) == tostring(id) then M.Finish(run, 'the airframe was removed', 'cancelled') end
        end
    end)

    AddEventHandler('onResourceStop', function(name)
        if name == RESOURCE then M.Stop('the resource stopped') end
    end)

    RegisterCommand(M.Command.STATUS, function(source, _, raw)
        local list = M.Status()
        local parts = {}
        for _, run in ipairs(list) do
            parts[#parts + 1] = ('player %d flies %s (%s, %s %s, %.0fs, %d poses, %d refused)')
                :format(run.playerId, run.hullId, run.mode, run.leg, run.mode == 'arrive' and 'phase' or 'leg',
                    run.clock, run.poses, run.refused)
        end
        local text = ('open77_avdrive: %d flight(s)%s'):format(#list, #parts > 0 and (': ' .. table.concat(parts, '; ')) or '')
        print(text)
        local id = validPlayer(source)
        if id ~= nil then pcall(TriggerClientEvent, 'open77:command:result', id, raw or '', true, text) end
    end, true)

    -- ONE AUTOPILOT PER SERVER. XyberRP's opx_infinity carries the module this
    -- resource was ported from; with both, one key press would start two runs.
    local function twin(name)
        if name ~= 'opx_infinity' then return end
        Open77.log.warn('opx_infinity runs on this server too: if its avdrive module is switched on, switch it or '
            .. 'this resource off -- two autopilots would fly one aircraft')
    end
    AddEventHandler('onResourceStart', function(name) twin(name) end)
    if type(GetResourceState) == 'function' then
        local read, state = pcall(GetResourceState, 'opx_infinity')
        if read and state == 'started' then twin('opx_infinity') end
    end

    local plan = M.Plan()
    local cfg = M.ArriveSettings()
    Open77.log.info(('ready (%s): key %s, travel %s, hover %.0f m over the pin, range %.0f m; the pilot is whoever flies '
        .. 'the aircraft, from any seat; flown: cruise %.0f m up at %.0f m/s, climb %.1f m/s, descent %.1f m/s, %d ms '
        .. 'ticks'):format(M.VERSION, tostring(type(settings().KEY) == 'table' and settings().KEY.DEFAULT or '?'),
        M.Travel() == 'arrive' and ('ARRIVE (fade out %d ms; flown under the black at %.0f m/s, %.0f m/s up and down, '
            .. '%.0f m over the higher end, %.0fs at most, paced by the pilot\'s game every %d ms -- held while it is '
            .. '%.0f m behind (%.0fs at most) or loading (%.0fs at most); settle %d ms, measure %d ms at most, fade in '
            .. '%d ms, the pilot\'s game watched %.0fs for the controls)'):format(cfg.fadeOut, cfg.speed, cfg.climb,
            cfg.cruiseAbove, cfg.maxFlight / 1000.0, cfg.pace, cfg.leash, cfg.stall / 1000.0, cfg.loadingWait / 1000.0,
            cfg.settle, cfg.measure, cfg.fadeIn, cfg.ownWait / 1000.0) or 'FLY (the pilot\'s view flickers)',
        plan.hoverHeight, plan.maxRange, plan.cruiseAltitude, plan.cruiseSpeed, plan.climbSpeed, plan.descendSpeed,
        plan.tickMs))
end

exports('status', function() return M.Status() end)
exports('cancel', function(playerId, why)
    return M.Cancel(playerId, type(why) == 'string' and why:sub(1, 80) or nil)
end)

M.Start()
