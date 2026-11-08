-- =============================================================================
-- open77_avdoor -- client/sync.lua
-- =============================================================================
-- THIS SCREEN'S HALF OF THE EXIT SCENE (server/sync.lua), and what it drew.
--
-- AS A VIEWER. When a player near this one steps out of an aircraft the server
-- says so (`SCENE`, phase `exit`). The platform's own dismount then holds that
-- body in its seat on this screen -- for up to 2.5 s (`Remote seat dismount
-- begun ... graceMs=2500`, then `... released afterMs=2811`, the laptop,
-- XyberRP Staging, 2026-10-28) -- so this half watches its copy of the body
-- (`Open77.players.entity`, `Open77.character.state`: its vehicle mount and
-- its exit workspot) and tells the server the moment it is out of its seat
-- (`SCENE_READY`). The step waits for every screen near the exit. A body this
-- screen does not draw, or one still in its seat after `READY_MAX_MS`, is said
-- too: the server never waits on silence.
--
-- THE LOGGER. As the step starts (`SCENE`, phase `start`) this screen looks
-- again a moment into it and as it ends, and reports what it drew
-- (`SCENE_REPORT`): the body in its seat or out, how far it stands from the
-- step's end point, where it draws the AV against the server's pose, its frame
-- rate. The exiting player's own screen reports its step the same way: its
-- view (third person, the stand-in body), the camera's swing, its body against
-- the end point. Every report is a line here too, a warning for anything wrong.
--
-- THE FRAME RATE. Once a second this half counts three frames (`Wait(0)` ends
-- on the next frame on a client), and each report carries the frame rate. A
-- game under `SLOW_FPS`, or a pass of this resource's watch that costs more
-- than `SLOW_PASS_MS`, is said in the log once a minute; a healthy game once
-- every five.
--
-- THE STEP AGAINST THE DOOR (1.5.0), as this screen draws both: the heading it
-- draws the body at against the step's (`SYNC.FACING_DEGREES`), the step's
-- first frame -- from where the body stands and the way it faces -- against
-- the middle of the door's step on the AV as this screen draws it, that door
-- against the server's and its door slot (`STEP_METRES`), on the ground or
-- not, a weapon drawn or not, and for another player's body the age of the
-- movement it is drawn with (`STALE_MS`) and its hips: on its feet's point a
-- moment into the step, the step was not drawn here.
-- =============================================================================

local M = AvDoor
local C = {}
M.Sync = C

-- A body is out of its seat at the first look that finds it neither mounted
-- nor in a workspot: the platform's own dismount lets go of it on those same
-- two reads (PlayerReplication.cpp: `GetMountedVehicle` answers `NotMounted`
-- and `IsOccupantInWorkspot` false), so one look is the moment it does.
local FREE_LOOKS = 1
-- A body this screen cannot find for this many looks is not drawn here.
local UNSEEN_LOOKS = 3
-- The frame meter: a sample every `FRAME_EVERY_MS`, three frames each, the
-- newest `FRAME_SAMPLES` kept.
local FRAME_EVERY_MS = 1000
local FRAME_SAMPLES = 20
-- The health line: a warning under `SLOW_FPS` or past `SLOW_PASS_MS`, at most
-- every `HEALTH_WARN_MS`; an all-clear every `HEALTH_OK_MS`.
local SLOW_FPS = 15.0
local SLOW_PASS_MS = 8.0
local HEALTH_WARN_MS = 60000
local HEALTH_OK_MS = 300000
-- A scene the server never closes is dropped after this long.
local SCENE_MAX_MS = 40000

-- Scenes this screen watches, by the scene's number:
-- `{ seq, player, id, seat, clip, hull, since, free, unseen, readyAt, startAt,
--    durationMs, at, startHull, sent = { start, end } }`.
local watching = {}

-- This player's own step: `{ seq, id, hull, at, startAt, durationMs, clip, sent }`, or nil.
local own = nil

-- The frame times measured (ms, newest last); the watch passes' cost since the
-- last health line (their sum, count and the dearest, ms). Kept as three
-- numbers: the pass runs inside the client's per-resume script budget.
local frames = {}
local passSum, passCount, passMax = 0, 0, 0
local meter = nil
local healthAt, healthWarned = nil, false
local said = {}

local function cfg() return M.SyncSettings() end

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

local function pointOf(value)
    if type(value) ~= 'table' then return nil end
    local x, y, z = finite(value.x or value[1]), finite(value.y or value[2]), finite(value.z or value[3])
    if x == nil or y == nil then return nil end
    return { x = x, y = y, z = z }
end

local function apart(a, b)
    local dx, dy = a.x - b.x, a.y - b.y
    return math.sqrt(dx * dx + dy * dy)
end

local function apart3(a, b)
    local dx, dy, dz = a.x - b.x, a.y - b.y, (a.z or 0) - (b.z or 0)
    return math.sqrt(dx * dx + dy * dy + dz * dz)
end

--- Milliseconds on the host's monotonic clock, unrounded (a pass's cost is
--- well under a millisecond).
local function clock()
    local time = type(Open77) == 'table' and Open77.time or nil
    if type(time) == 'table' and type(time.monotonic) == 'function' then
        local read, seconds = pcall(time.monotonic)
        if read and type(seconds) == 'number' then return seconds * 1000.0 end
    end
    return M.Now()
end

C.Clock = clock

local function median(list)
    if #list == 0 then return nil end
    local sorted = {}
    for i, v in ipairs(list) do sorted[i] = v end
    table.sort(sorted)
    return sorted[math.floor((#sorted + 1) / 2)]
end

local function push(list, value, keep)
    list[#list + 1] = value
    while #list > keep do table.remove(list, 1) end
end

-- ── the frame rate ───────────────────────────────────────────────────────────

--- The frame rate this game runs at (the median of the frames measured), or
--- nil when it was not measured.
-- @return number|nil
function C.Fps()
    local frame = median(frames)
    if frame == nil or frame <= 0.5 then return nil end
    return 1000.0 / frame
end

--- One sample: three frames, each the time between two `Wait(0)`.
local function sampleFrames()
    local t0 = clock()
    Wait(0)
    local t1 = clock()
    Wait(0)
    local t2 = clock()
    Wait(0)
    local t3 = clock()
    local f = median({ t1 - t0, t2 - t1, t3 - t2 })
    -- No time between frames: a host that does not tick between them (an
    -- offline suite) says nothing about its frame rate.
    if f ~= nil and f > 0.5 then push(frames, f, FRAME_SAMPLES) end
end

--- A pass of the client's watch, and what it cost (client/main.lua).
-- @param ms number
function C.Pass(ms)
    ms = finite(ms)
    if ms == nil or ms < 0 then return end
    passSum, passCount = passSum + ms, passCount + 1
    if ms > passMax then passMax = ms end
end

--- What this game's health comes to now: `fps`, `frameMs`, the watch's pass
--- cost since the last health line (mean, most, how many passes).
function C.Health()
    return { fps = C.Fps(), frameMs = median(frames), passMs = passCount > 0 and passSum / passCount or nil,
        passMaxMs = passMax, passes = passCount, samples = #frames }
end

local function fpsText(fps)
    if fps == nil then return 'frame rate not measured' end
    return ('%.1f fps'):format(fps)
end

--- The health line: slow frames or a costly pass are said once a minute, an
--- all-clear every five (and once a game that was slow is not any more).
local function health(now)
    if #frames < 5 then return end
    -- At most once a minute: nothing below is worked out before it is due.
    if healthAt ~= nil and now - healthAt < HEALTH_WARN_MS then return end
    local fps = C.Fps()
    local slow = fps ~= nil and fps < SLOW_FPS
    local costly = passMax > SLOW_PASS_MS
    if healthAt ~= nil and not (slow or costly) and not healthWarned and now - healthAt < HEALTH_OK_MS then return end
    healthAt, healthWarned = now, slow or costly
    local h = C.Health()
    local line = ('client health: %s (frames %.0f ms, the median of %d samples); this resource\'s watch pass costs '
        .. '%.1f ms on average, %.1f ms at most, over the last %d passes'):format(fpsText(h.fps), h.frameMs or 0,
        h.samples, h.passMs or 0, h.passMaxMs, h.passes)
    passSum, passCount, passMax = 0, 0, 0
    if slow or costly then
        local why = {}
        if slow then
            why[#why + 1] = ('the game runs under %.0f frames a second: every exit waits longer for its third person, '
                .. 'and the other screens draw it late'):format(SLOW_FPS)
        end
        if costly then why[#why + 1] = ('a watch pass took %.1f ms'):format(h.passMaxMs) end
        Open77.log.warn(line .. ' -- ' .. table.concat(why, '; '))
    else
        Open77.log.info(line)
    end
end

-- ── what this screen draws ───────────────────────────────────────────────────

--- This screen's copy of another player's body: `{ entity, mounted, workspot,
--- position, animation }`, or nil and why.
-- @param playerId integer
local function look(playerId)
    local players, character = Open77.players, Open77.character
    if type(players) ~= 'table' or type(players.entity) ~= 'function' then
        return nil, 'no Open77.players.entity on this client'
    end
    local read, entity, why = pcall(players.entity, playerId)
    if not read then return nil, 'error: ' .. tostring(entity) end
    if entity == nil then return nil, tostring(why or 'not streamed here') end
    -- Entity 0 is the local player for every entity read: never another body.
    if tonumber(entity) == 0 then return nil, 'the platform answered with this player\'s own body' end
    if type(character) ~= 'table' or type(character.state) ~= 'function' then
        return nil, 'no Open77.character.state on this client'
    end
    local got, state, reason = pcall(character.state, entity)
    if not got then return nil, 'error: ' .. tostring(state) end
    if type(state) ~= 'table' then return nil, tostring(reason or 'no state') end
    local vehicle = type(state.vehicle) == 'table' and state.vehicle or {}
    return {
        entity = entity,
        mounted = vehicle.mounted == true or state.inVehicle == true,
        workspot = state.inWorkspot == true,
        position = pointOf(state.position),
        animation = type(state.animation) == 'string' and state.animation ~= '' and state.animation or nil,
    }
end

--- How far this screen's engine draws a hull from a pose, or nil.
-- @param id any the hull
-- @param pose table|nil `{ x, y, z }`; nil: where the network has it on this screen
local function hullOff(id, pose)
    if M.ExitFrameNow == nil or id == nil then return nil end
    local read, _, _, engine, net = pcall(M.ExitFrameNow, id)
    if not read or engine == nil then return nil end
    local against = pointOf(pose) or net
    if against == nil or against.z == nil then return nil end
    return apart3(engine, against)
end

local function myPosition()
    local character = Open77.character
    if type(character) ~= 'table' or type(character.position) ~= 'function' then return nil end
    local read, x, y, z = pcall(character.position)
    if not read then return nil end
    x, y, z = finite(x), finite(y), finite(z)
    if x == nil or y == nil then return nil end
    return { x = x, y = y, z = z }
end

--- This body's seat, when it sits in one.
local function mySeated()
    local vehicles = Open77.vehicles
    if type(vehicles) ~= 'table' or type(vehicles.getPlayerSeat) ~= 'function' then return nil end
    local read, seat = pcall(vehicles.getPlayerSeat)
    if read and type(seat) == 'table' and seat.vehicleId ~= nil then return seat end
    return nil
end

local function sceneName(scene)
    return ('%s %d of player %d'):format(scene.kind == 'enter' and 'boarding' or 'exit', scene.seq, scene.player)
end

-- ── the step against the door ────────────────────────────────────────────────

-- A body's hips this close to its feet's point a moment into the step: the
-- step was not drawn (its first frame stands them 2.5 m away). A screen waits
-- this long into the step for its copy of the clip to be drawn before it
-- reports the step's start.
local HIPS_DRAWN_METRES = 0.5
local HIPS_WAIT_MS = 1000

--- The door as this screen draws the AV: the middle of its step (where the
--- clip's first frame must stand), how far that is from the server's, and its
--- door slot. Nil when the hull is not drawn here.
-- @param id any the hull
-- @param record any its record
-- @param seat any the seat that was left
-- @param serverDoor table|nil the server's own door point
-- @param turned boolean|nil the step was planned on the hull turned round (its
--   door drawn on the other side, client/walkout.lua)
-- @param clip string|nil the step's clip: a seat clip (1.7.7) ends in the
--   seat, and the seat's slot as this screen draws the AV stands for the door
-- @return table|nil `{ door, doorOff, slot }`
local function doorHere(id, record, seat, serverDoor, turned, clip)
    if M.ExitFrameNow == nil or id == nil then return nil end
    local read, _, _, engine = pcall(M.ExitFrameNow, id)
    if not read or engine == nil then return nil end
    if turned then engine = M.TurnedFrame(engine) end
    local out = { door = M.DoorWorld(engine, M.SeatDoor(record, seat)) }
    local sit = M.SeatClip(clip) and M.SeatSit(record, seat) or nil
    if sit ~= nil then
        out.door = M.FromHullLocal(engine, { x = sit.x, y = sit.y, z = sit.z })
        out.seat = true
    end
    if out.door ~= nil and serverDoor ~= nil then out.doorOff = apart(out.door, serverDoor) end
    if M.WalkOut ~= nil and type(M.WalkOut.DoorSlot) == 'function' then
        local got, slot = pcall(M.WalkOut.DoorSlot, id, record, engine)
        if got and type(slot) == 'table' then out.slot = slot end
    end
    return out
end

--- What this screen draws of a body for the step: its heading against the
--- step's, on the ground or not, a weapon drawn, the age of the movement it is
--- drawn with, its hips (another player's body only: on this screen the clip
--- plays on the stand-in, not on the player's own body), and the step's first
--- frame against the door. Every field is nil when it cannot be read.
-- @param entity any nil for this player's own body
-- @param step table `{ yaw, clip, door }` the step as the server plays it, and the door here
-- @param position table|nil where the body stands (as read already)
local function measureBody(entity, step, position)
    local m = {}
    local character = Open77.character
    if type(character) ~= 'table' or type(character.state) ~= 'function' then return m end
    local read, state
    if entity == nil then read, state = pcall(character.state) else read, state = pcall(character.state, entity) end
    if not read or type(state) ~= 'table' then return m end
    position = position or pointOf(state.position)
    local yaw = finite(state.yaw)
    if yaw == nil and type(state.forward) == 'table' then yaw = M.YawOfDirection(state.forward.x, state.forward.y) end
    if entity == nil and M.WalkOut ~= nil and type(M.WalkOut.BodyYaw) == 'function' then
        yaw = M.WalkOut.BodyYaw() or yaw
    end
    if yaw ~= nil then
        m.yaw = yaw % 360.0
        if step.yaw ~= nil then m.yawOff = M.YawApart(m.yaw, step.yaw) end
    end
    if type(state.grounded) == 'boolean' then m.grounded = state.grounded end
    if type(state.air) == 'string' and state.air ~= '' then m.air = state.air:sub(1, 24) end
    if type(state.weapon) == 'table' and type(state.weapon.drawn) == 'boolean' then m.weapon = state.weapon.drawn end
    if entity ~= nil and finite(state.age) ~= nil then m.ageMs = math.floor(finite(state.age) * 1000.0 + 0.5) end
    local door = step.door
    if entity ~= nil and type(character.bonePosition) == 'function' and position ~= nil then
        local got, hips = M.Native('character.bonePosition', character.bonePosition, entity, 'hips')
        hips = got and pointOf(hips) or nil
        if hips ~= nil then
            m.hipsRoot = apart(hips, position)
            if door ~= nil then m.hipsDoor = apart(hips, door) end
        end
    end
    if door ~= nil and position ~= nil and m.yaw ~= nil and step.clip ~= nil and M.WALK_CLIPS[step.clip] ~= nil then
        m.startDoor = M.StartOffDoor(position, m.yaw, step.clip, door)
    end
    return m
end

--- Whether this screen draws another player's step now: its body's hips off
--- its feet's point (true too when the hips cannot be read here: nothing to
--- wait for).
local function stepDrawn(scene)
    local character = Open77.character
    if type(character) ~= 'table' or type(character.bonePosition) ~= 'function' then return true end
    local body = look(scene.player)
    if body == nil or body.position == nil then return true end
    local read, hips = M.Native('character.bonePosition', character.bonePosition, body.entity, 'hips')
    hips = read and pointOf(hips) or nil
    if hips == nil then return true end
    return apart(hips, body.position) >= HIPS_DRAWN_METRES
end

--- The step against the door, for a report: the fields into `payload`, the
--- words into `parts`, what is wrong into `wrong`.
-- @param m table `measureBody`
-- @param here table|nil `doorHere`
-- @param phase string 'start' | 'end'
-- @param who string 'the body' or 'player N'
local function judgeStep(m, here, phase, payload, parts, wrong, who, kind, clip)
    local c = cfg()
    -- A boarding step (1.7.0) leaves the feet's point late and ends in the
    -- door: its hips are judged as it ends, and its door end is its last frame.
    -- A seat clip (1.7.7) ends in the seat: its last frame against the seat.
    local enter = kind == 'enter'
    local hipsPhase = enter and 'end' or 'start'
    local frameWord = enter and 'last' or 'first'
    local doorWord = M.SeatClip(clip) and 'the seat' or 'the door'
    payload.yaw, payload.yawOff, payload.grounded, payload.air = m.yaw, m.yawOff, m.grounded, m.air
    payload.weapon, payload.ageMs, payload.startDoor = m.weapon, m.ageMs, m.startDoor
    if phase == hipsPhase then payload.hipsRoot, payload.hipsDoor = m.hipsRoot, m.hipsDoor end
    if here ~= nil then
        payload.doorOff = here.doorOff
        payload.slot = here.slot ~= nil and here.slot.verdict or nil
    end
    if m.yaw ~= nil then
        parts[#parts + 1] = ('facing %.0f deg%s'):format(m.yaw, m.yawOff ~= nil and (' (%.0f off the step\'s)'):format(m.yawOff) or '')
        if m.yawOff ~= nil and m.yawOff > c.facing then
            wrong[#wrong + 1] = ('%s faces %.0f deg, %.0f deg off the step\'s: the step\'s path is turned with it')
                :format(who, m.yaw, m.yawOff)
        end
    end
    if m.grounded == false then
        parts[#parts + 1] = ('OFF THE GROUND (%s)'):format(m.air or '?')
        wrong[#wrong + 1] = ('%s is off the ground: the platform plays no clip on a body in the air'):format(who)
    end
    if m.weapon == true then
        parts[#parts + 1] = 'a WEAPON DRAWN'
        wrong[#wrong + 1] = ('%s has a weapon drawn: the platform plays no clip then'):format(who)
    end
    if m.ageMs ~= nil then
        parts[#parts + 1] = ('its movement %d ms old'):format(m.ageMs)
        if m.ageMs > c.stale then
            wrong[#wrong + 1] = ('%s is drawn from movement %d ms old: the platform plays no clip on stale movement')
                :format(who, m.ageMs)
        end
    end
    if phase == hipsPhase and m.hipsRoot ~= nil then
        parts[#parts + 1] = ('the hips %.2f m from the feet\'s point'):format(m.hipsRoot)
        if m.hipsRoot < HIPS_DRAWN_METRES then
            wrong[#wrong + 1] = ('no step drawn: %s\'s hips stand on its feet\'s point'):format(who)
        end
    end
    if phase == hipsPhase and m.hipsDoor ~= nil then
        parts[#parts + 1] = ('the hips %.2f m from %s'):format(m.hipsDoor, doorWord)
    end
    if m.startDoor ~= nil then
        parts[#parts + 1] = ('the step\'s %s frame %.2f m from %s'):format(frameWord, m.startDoor, doorWord)
        if m.startDoor > c.step then
            wrong[#wrong + 1] = ('the step\'s %s frame stands %.2f m from %s as this screen draws it')
                :format(frameWord, m.startDoor, doorWord)
        end
    end
    if here ~= nil and here.doorOff ~= nil then
        parts[#parts + 1] = ('%s %.2f m from the server\'s'):format(doorWord, here.doorOff)
        if here.doorOff > c.step then
            wrong[#wrong + 1] = ('the AV\'s %s is drawn %.2f m from where the server has it'):format(
                doorWord:sub(5), here.doorOff)
        end
    end
    if here ~= nil and here.slot ~= nil and here.slot.verdict ~= 'right' then
        parts[#parts + 1] = ('the door slot %s at %.2f across, %.2f along'):format(here.slot.name, here.slot.at.x,
            here.slot.at.y)
        if here.slot.verdict == 'mirrored' then wrong[#wrong + 1] = 'the AV\'s door is drawn on the hull\'s other side' end
    end
end

-- ── the seat, presented at once (1.7.8) ──────────────────────────────────────
-- Another player's boarding step ends seated (the Excalibur's pilot seat) or
-- in the door, and the server seats the body as it ends. The platform's own
-- answer to a seat added live is the vanilla approach, door and workspot for
-- that body -- from where its entity stands, the step's first spot outside
-- the AV: it would walk back in after it was seen sitting down. So once the
-- ledger names the seat, this screen presents the body in it at once
-- (`Open77.vehicles.warpPlayerIntoVehicle`, the client's presentation call).
-- `SYNC.PRESENT_SEAT = false` leaves it to the platform.
local presenting = {}
-- How long after the step's end the seat is looked for.
local PRESENT_EXTRA_MS = 4000

local function presentTick(now)
    if next(presenting) == nil then return end
    local api = Open77.vehicles
    for player, p in pairs(presenting) do
        if now > p.untilAt then
            presenting[player] = nil
            Open77.log.info(('%s: its seat was never named here within %.1fs: not presented'):format(p.name,
                (now - p.since) / 1000.0))
        elseif type(api) ~= 'table' or type(api.getPlayerSeat) ~= 'function'
            or type(api.warpPlayerIntoVehicle) ~= 'function' then
            presenting[player] = nil
        else
            local read, seat = pcall(api.getPlayerSeat, player)
            if read and type(seat) == 'table' and tostring(seat.vehicleId) == tostring(p.id) and seat.seat == p.seat then
                presenting[player] = nil
                local called, placed, reason = M.Native('vehicles.warpPlayerIntoVehicle', api.warpPlayerIntoVehicle,
                    player, p.id, p.seat)
                local ok = called and placed == true
                local line = ('%s: seated %.1fs after the step began -- presented in %s at once%s'):format(p.name,
                    (now - p.since) / 1000.0, p.seat, ok and '' or (' -- REFUSED (%s): the platform\'s own entry plays')
                        :format(tostring(called and reason or placed)))
                if ok then Open77.log.info(line) else Open77.log.warn(line) end
            end
        end
    end
end

-- ── as a viewer ──────────────────────────────────────────────────────────────

--- The word to the server: the body is out of its seat here, or why not.
local function ready(scene, free, seen, why, now)
    scene.readyAt = now
    local off = hullOff(scene.id, nil)
    local fps = C.Fps()
    TriggerServerEvent(M.Event.SCENE_READY, { scene = scene.seq, free = free, seen = seen, why = why,
        hullOff = off, fps = fps })
    local after = (now - scene.since) / 1000.0
    local what
    if not seen then
        what = ('not drawn here (%s): the server need not wait for this screen'):format(tostring(why))
    elseif free then
        what = ('out of its seat here %.1fs after the word'):format(after)
    else
        what = ('STILL IN ITS SEAT here %.1fs after the word (%s): the step may start before this screen lets go')
            :format(after, tostring(why))
    end
    local line = ('%s: the body %s; the AV %s, %s'):format(sceneName(scene), what,
        off ~= nil and ('%.2f m from where the network has it'):format(off) or 'not measured', fpsText(fps))
    if seen and not free then Open77.log.warn(line) else Open77.log.info(line) end
end

--- A look at a viewer's scene before its step: is the body out of its seat?
local function watchExit(scene, now)
    local body, why = look(scene.player)
    if body == nil then
        scene.unseen = scene.unseen + 1
        scene.free = 0
        if scene.unseen >= UNSEEN_LOOKS then return ready(scene, true, false, why, now) end
        return
    end
    scene.unseen = 0
    if body.mounted or body.workspot then
        scene.free = 0
        scene.held = body.mounted and 'in its seat' or 'in its exit workspot'
        if not scene.heldSaid then
            scene.heldSaid = true
            Open77.log.info(('%s: the body is %s here%s; the step waits for it'):format(sceneName(scene), scene.held,
                body.animation ~= nil and (' (%s)'):format(body.animation) or ''))
        end
        if now - scene.since >= cfg().readyMax then
            return ready(scene, false, true, ('this game\'s own dismount still holds it %s'):format(scene.held), now)
        end
        return
    end
    scene.free = scene.free + 1
    if scene.free >= FREE_LOOKS then return ready(scene, true, true, nil, now) end
end

--- What this screen drew of a step, a moment into it or as it ended.
local function reportViewer(scene, phase, now)
    local c = cfg()
    local body, why = look(scene.player)
    local payload = { scene = scene.seq, phase = phase, fps = C.Fps() }
    local wrong = {}
    local parts = {}
    if body == nil then
        payload.seen, payload.why = false, why
        parts[#parts + 1] = ('the body is not drawn here (%s)'):format(tostring(why))
    elseif scene.kind == 'enter' and phase == 'end' and body.mounted then
        -- A BOARDING SEATED BEFORE ITS LAST SAMPLE (1.7.8): the seat comes as
        -- the step's own screen puts its stand-in away, before the clip's end
        -- -- the step's end here, not a body left in a seat.
        payload.seen, payload.mounted, payload.seated = true, true, tostring(scene.seat or '?')
        parts[#parts + 1] = ('the body seated (%s): the seat came before this sample'):format(payload.seated)
    else
        payload.seen = true
        payload.mounted, payload.workspot = body.mounted, body.workspot
        if body.mounted then
            parts[#parts + 1] = 'the body STILL IN ITS SEAT'
            wrong[#wrong + 1] = 'the body is still in its seat'
        elseif body.workspot then
            parts[#parts + 1] = 'the body in its exit workspot'
            wrong[#wrong + 1] = 'the body is in its exit workspot'
        else
            parts[#parts + 1] = 'the body out of its seat'
        end
        local spotWord = scene.kind == 'enter' and 'the step\'s first spot' or 'the step\'s end point'
        if body.position ~= nil and scene.at ~= nil then
            payload.off = apart(body.position, scene.at)
            parts[#parts + 1] = ('%.2f m from %s'):format(payload.off, spotWord)
            if payload.off > c.body then wrong[#wrong + 1] = ('the body is %.2f m from %s'):format(payload.off, spotWord) end
        end
        -- THE STEP AGAINST THE DOOR, as this screen draws the body and the AV.
        local here = doorHere(scene.id, scene.record, scene.seat, scene.door, scene.turned, scene.clip)
        local m = measureBody(body.entity, { yaw = scene.yaw, clip = scene.clip,
            door = here ~= nil and here.door or scene.door }, body.position)
        judgeStep(m, here, phase, payload, parts, wrong, 'the body', scene.kind, scene.clip)
    end
    payload.hullOff = hullOff(scene.id, scene.startHull)
    if payload.hullOff ~= nil then
        parts[#parts + 1] = ('the AV %.2f m from the server\'s pose'):format(payload.hullOff)
        if payload.hullOff > c.hull then wrong[#wrong + 1] = ('the AV is drawn %.2f m from the server\'s pose'):format(payload.hullOff) end
    end
    parts[#parts + 1] = fpsText(payload.fps)
    TriggerServerEvent(M.Event.SCENE_REPORT, payload)
    local line = ('%s, %s here: %s'):format(sceneName(scene), phase == 'start' and 'as the step began' or 'as the step ended',
        table.concat(parts, ', '))
    if #wrong > 0 then Open77.log.warn(line .. ' -- WRONG: ' .. table.concat(wrong, '; ')) else Open77.log.info(line) end
end

-- ── this player's own step ───────────────────────────────────────────────────

--- The exit clip of this player started (client/walkout.lua, the answer).
-- @param info table `{ scene, hull, at, durationMs, id, clip }`
function C.Own(info)
    if type(info) ~= 'table' or tonumber(info.scene) == nil then return end
    own = { seq = math.floor(tonumber(info.scene)), id = info.id, hull = pointOf(info.hull), at = pointOf(info.at),
        startAt = M.Now(), durationMs = math.floor(M.Number(info.durationMs, 100, 60000, 4300)), clip = info.clip,
        yaw = finite(info.yaw), door = pointOf(info.door), record = info.record, seat = info.seat,
        turned = info.turned == true, kind = info.kind == 'enter' and 'enter' or 'exit', sent = {} }
end

local function reportOwn(phase, now)
    local c = cfg()
    local enter = own.kind == 'enter'
    local source = enter and M.Enter or M.WalkOut
    local shot = (source ~= nil and type(source.Shot) == 'function') and source.Shot() or {}
    local payload = { scene = own.seq, phase = phase, fps = C.Fps(), view = shot.view, body = shot.body,
        orbit = shot.orbit == true }
    local parts, wrong = {}, {}
    parts[#parts + 1] = ('in %s (%s%s)'):format(shot.view == 'tps' and 'third person'
            or (shot.view == 'fpp' and 'FIRST PERSON' or tostring(shot.view or 'an unknown view')),
        shot.body == 'proxy' and 'the stand-in body' or tostring(shot.body or '?'),
        payload.orbit and ', the camera in front' or '')
    -- A BOARDING SEATED BEFORE ITS LAST SAMPLE (1.7.5): the seat comes
    -- `SEAT_EARLY_MS` before the clip ends on the server's clock, and a game at
    -- four frames a second takes its last sample after it -- the body in its
    -- seat, the view the seat's own. That is the step's end, not a step gone
    -- wrong (Staging, 2026-10-29: "WRONG: the body is 2.42 m from the step's
    -- first spot", seated 0.4 s before).
    local seated = enter and phase ~= 'start' and mySeated() or nil
    if seated ~= nil then
        payload.seated = tostring(seated.seat or '?')
        parts[#parts + 1] = ('already seated (%s): the seat came before this sample'):format(payload.seated)
        parts[#parts + 1] = fpsText(payload.fps)
        TriggerServerEvent(M.Event.SCENE_REPORT, payload)
        Open77.log.info(('boarding %d (this player\'s own), as the step ended: %s'):format(own.seq,
            table.concat(parts, ', ')))
        return
    end
    -- 1.7.8: the view let go for the seat as the step ends (the stand-in put
    -- away first) is the step's end, not a step shown in first person.
    if enter and phase ~= 'start' and shot.seating == true then
        payload.seating = true
        parts[#parts + 1] = 'the view let go for the seat'
    elseif shot.view ~= nil and shot.view ~= 'tps' then
        wrong[#wrong + 1] = 'the step is shown in first person'
    end
    local at = myPosition()
    local target = own.at or shot.target
    local spotWord = enter and 'the step\'s first spot' or 'the step\'s end point'
    if at ~= nil and target ~= nil then
        payload.off = apart(at, target)
        parts[#parts + 1] = ('the body %.2f m from %s'):format(payload.off, spotWord)
        if payload.off > c.body then wrong[#wrong + 1] = ('the body is %.2f m from %s'):format(payload.off, spotWord) end
    end
    -- THE STEP AGAINST THE DOOR, as this screen draws its own body and the AV
    -- (the door on the hull as drawn here, turned round when its door is drawn
    -- on the other side: the step was planned that way).
    local here = doorHere(own.id, own.record, own.seat, own.door, own.turned, own.clip)
    local m = measureBody(nil, { yaw = own.yaw, clip = own.clip, door = here ~= nil and here.door or own.door }, at)
    judgeStep(m, here, phase, payload, parts, wrong, 'the body', own.kind, own.clip)
    payload.hullOff = hullOff(own.id, own.hull)
    if payload.hullOff ~= nil then
        parts[#parts + 1] = ('the AV %.2f m from the server\'s pose'):format(payload.hullOff)
        if payload.hullOff > c.hull then wrong[#wrong + 1] = ('the AV is drawn %.2f m from the server\'s pose'):format(payload.hullOff) end
    end
    parts[#parts + 1] = fpsText(payload.fps)
    TriggerServerEvent(M.Event.SCENE_REPORT, payload)
    local line = ('%s %d (this player\'s own), %s: %s'):format(enter and 'boarding' or 'exit', own.seq,
        phase == 'start' and 'as the step began' or 'as the step ended', table.concat(parts, ', '))
    if #wrong > 0 then Open77.log.warn(line .. ' -- WRONG: ' .. table.concat(wrong, '; ')) else Open77.log.info(line) end
end

-- ── the pass ─────────────────────────────────────────────────────────────────

--- When a step's reports are due: a moment into it, and as it ends.
local function due(startAt, durationMs)
    local sample = cfg().sample
    return startAt + sample, startAt + math.max(sample + 100, durationMs - 300)
end

--- Every pass of the client's watch (100 ms): the bodies watched, the reports due.
-- @param now number|nil
function C.Tick(now)
    now = now or M.Now()
    if cfg().off then
        watching, own = {}, nil
    end
    for seq, scene in pairs(watching) do
        if scene.startAt == nil then
            if scene.readyAt == nil then
                local ran, failure = pcall(watchExit, scene, now)
                if not ran then
                    scene.readyAt = now
                    Open77.log.error(('%s: the look at the body failed: %s'):format(sceneName(scene), tostring(failure)))
                end
            end
            if now - scene.since > SCENE_MAX_MS then watching[seq] = nil end
        else
            local first, last = due(scene.startAt, scene.durationMs)
            -- THE STEP DRAWN HERE: the platform's clip may reach this game a
            -- moment after the server's word, so the first report waits for
            -- the body's hips to leave its feet's point -- the step drawn --
            -- up to `HIPS_WAIT_MS`, and says what it found then.
            if not scene.sent.start and now >= first and (now - scene.startAt >= HIPS_WAIT_MS or stepDrawn(scene)) then
                scene.sent.start = true
                local ran, failure = pcall(reportViewer, scene, 'start', now)
                if not ran then Open77.log.error('the exit report failed: ' .. tostring(failure)) end
            end
            if not scene.sent['end'] and now >= last then
                scene.sent['end'] = true
                local ran, failure = pcall(reportViewer, scene, 'end', now)
                if not ran then Open77.log.error('the exit report failed: ' .. tostring(failure)) end
                watching[seq] = nil
            elseif now - scene.startAt > scene.durationMs + 3000 then
                watching[seq] = nil
            end
        end
    end
    if own ~= nil then
        local first, last = due(own.startAt, own.durationMs)
        if not own.sent.start and now >= first then
            own.sent.start = true
            local ran, failure = pcall(reportOwn, 'start', now)
            if not ran then Open77.log.error('the exit report failed: ' .. tostring(failure)) end
        end
        if own ~= nil and not own.sent['end'] and now >= last then
            own.sent['end'] = true
            local ran, failure = pcall(reportOwn, 'end', now)
            if not ran then Open77.log.error('the exit report failed: ' .. tostring(failure)) end
            own = nil
        end
    end
    local ran, failure = pcall(presentTick, now)
    if not ran then
        presenting = {}
        Open77.log.error('the seat presentation failed: ' .. tostring(failure))
    end
    health(now)
end

-- ── the server's word ────────────────────────────────────────────────────────

--- A scene from the server: an exit nearby, its step started, or no step.
-- @param payload table `{ scene, phase, player, id, seat, clip, hull, durationMs, at, yaw }`
function C.Scene(payload)
    if type(payload) ~= 'table' then return end
    local seq, player = math.tointeger(tonumber(payload.scene)), math.tointeger(tonumber(payload.player))
    if seq == nil or player == nil then return end
    local now = M.Now()
    if payload.phase == 'exit' then
        if cfg().off then return end
        watching[seq] = { seq = seq, player = player, id = payload.id, seat = payload.seat, clip = payload.clip,
            record = payload.record, hull = pointOf(payload.hull), since = now, free = 0, unseen = 0, sent = {} }
        Open77.log.info(('exit %d of player %d: player %d steps out of %s of %s; this screen watches its body until it '
            .. 'is out of its seat'):format(seq, player, player, tostring(payload.seat), tostring(payload.id)))
        return
    end
    local scene = watching[seq]
    if payload.phase == 'start' then
        if scene == nil then
            -- A step this screen was not told the exit of (it came near since):
            -- reported all the same.
            scene = { seq = seq, player = player, id = payload.id, since = now, free = 0, unseen = 0, sent = {},
                readyAt = now }
            watching[seq] = scene
        end
        if scene.readyAt == nil then
            scene.readyAt = now
            Open77.log.warn(('%s: the step started before this screen had the body out of its seat (%s)')
                :format(sceneName(scene), scene.held or 'not looked at yet'))
        end
        scene.startAt = now
        scene.kind = payload.kind == 'enter' and 'enter' or (scene.kind or 'exit')
        scene.durationMs = math.floor(M.Number(payload.durationMs, 100, 60000, 4300))
        scene.at = pointOf(payload.at)
        scene.startHull = pointOf(payload.hull)
        -- The step as the server plays it: its heading, and the door its first
        -- frame stands on (the server's hull).
        scene.yaw = finite(payload.yaw)
        scene.door = pointOf(payload.door)
        scene.turned = payload.turned == true
        scene.clip = payload.clip or scene.clip
        scene.record = payload.record or scene.record
        scene.seat = payload.seat or scene.seat
        Open77.log.info(('%s: the step starts (%s, %.1fs%s); this screen looks again %.1fs into it and as it ends')
            :format(sceneName(scene), tostring(payload.clip), scene.durationMs / 1000.0,
                scene.yaw ~= nil and (', facing %.0f deg'):format(scene.yaw) or '', cfg().sample / 1000.0))
        -- WHAT THIS SCREEN SHOWS of it (client/shots.lua): pictures through the step.
        if M.Shots ~= nil then
            M.Shots.Begin('view', ('player %d stepping %s %s of %s'):format(player,
                scene.kind == 'enter' and 'into' or 'out of', tostring(scene.seat), tostring(scene.id)))
            local function meta() return C.ViewMeta(scene) end
            local times = { 600, 1600, 2800, 4000 }
            -- 1.7.8: a boarding's body after its seat too.
            if scene.kind == 'enter' then
                times[#times + 1] = scene.durationMs + 600
                times[#times + 1] = scene.durationMs + 2500
            end
            for _, at in ipairs(times) do
                M.Shots.Take(('view+%.1f'):format(at / 1000.0), at, meta, 'view')
            end
        end
        -- THE SEAT, PRESENTED AT ONCE (1.7.8).
        if scene.kind == 'enter' and cfg().presentSeat and scene.id ~= nil and type(scene.seat) == 'string' then
            presenting[player] = { name = sceneName(scene), id = scene.id, seat = scene.seat, since = now,
                untilAt = now + scene.durationMs + PRESENT_EXTRA_MS }
        end
        return
    end
    if payload.phase == 'end' and scene ~= nil then
        watching[seq] = nil
        Open77.log.info(('%s: no step was played (the server closed the exit)'):format(sceneName(scene)))
    end
end

--- What a diag picture's words say of another player's step drawn here
--- (client/shots.lua): that body as this screen has it, and its hips.
-- @param scene table
-- @return table `{ 'k=v', ... }`
function C.ViewMeta(scene)
    local out = { ('player=%d'):format(scene.player) }
    local body = look(scene.player)
    if body ~= nil then
        if body.position ~= nil then
            out[#out + 1] = ('body=%.2f,%.2f,%.2f'):format(body.position.x, body.position.y, body.position.z or 0)
        end
        out[#out + 1] = ('mounted=%s;workspot=%s'):format(tostring(body.mounted), tostring(body.workspot))
        local character = Open77.character
        if type(character) == 'table' and type(character.bonePosition) == 'function' then
            local read, hips = M.Native('character.bonePosition', character.bonePosition, body.entity, 'hips')
            hips = read and pointOf(hips) or nil
            if hips ~= nil then out[#out + 1] = ('hips=%.2f,%.2f,%.2f'):format(hips.x, hips.y, hips.z or 0) end
        end
    end
    if scene.at ~= nil then out[#out + 1] = ('end=%.2f,%.2f'):format(scene.at.x, scene.at.y) end
    if scene.door ~= nil then out[#out + 1] = ('door=%.2f,%.2f'):format(scene.door.x, scene.door.y) end
    if scene.yaw ~= nil then out[#out + 1] = ('stepyaw=%.0f'):format(scene.yaw) end
    return out
end

--- Whether this screen watches or draws a step now: another player's exit it
--- was told of and not yet seen to its end, or this player's own step.
-- @return boolean
function C.Busy()
    return own ~= nil or next(watching) ~= nil
end

--- What the console's status line shows.
function C.Status()
    local n = 0
    for _ in pairs(watching) do n = n + 1 end
    local h = C.Health()
    return { watching = n, own = own ~= nil, fps = h.fps, passMs = h.passMs, passMaxMs = h.passMaxMs }
end

function C.Start()
    RegisterNetEvent(M.Event.SCENE, function(payload)
        local ran, failure = pcall(C.Scene, payload)
        if not ran then Open77.log.error('an exit scene from the server failed: ' .. tostring(failure)) end
    end)
    -- THE FRAME METER: three frames a second, on a thread of its own.
    meter = { live = true }
    local handle = meter
    CreateThread(function()
        while handle.live do
            Wait(FRAME_EVERY_MS)
            if not handle.live then break end
            local ran, failure = pcall(sampleFrames)
            if not ran then
                once('meter', 'warn', 'the frame meter failed: ' .. tostring(failure))
            end
        end
    end)
    local c = cfg()
    Open77.log.info(c.off and 'exit sync: off'
        or ('exit sync: this screen watches every exit the server tells it of, says when the body is out of its '
            .. 'seat (%.1fs at most), and reports each step %.1fs into it and as it ends'):format(c.readyMax / 1000.0,
            c.sample / 1000.0))
end

function C.Stop()
    if meter ~= nil then meter.live = false end
    meter = nil
    watching, own = {}, nil
end
