-- =============================================================================
-- open77_avdoor -- client/walkout.lua
-- =============================================================================
-- The exit, animated, and the view that keeps the head on the body.
--
-- THE WALK-OUT. Rosalind Myers stepping out of her AV in Phantom Liberty
-- (q305), cut into the clips of the `avexit` locomotion package (open77_avexit).
-- A clip ENDS where the player entity stands, facing forward, and STARTS an
-- offset away; so when a seat in an aircraft empties, the exit guard
-- (client/main.lua) puts the body `|offset|` metres out from the seat's door,
-- turned so that the clip's first frame lands on the door (`M.WalkOutPlan`).
-- Then this half asks the server for the clip (`WALKOUT`); the server plays it
-- for every viewer at once and answers (`WALKING`). The body is held still
-- while it plays (`FREEZE`), or a step of the player's own would turn the
-- whole path around the entity mid-clip.
--
-- THE ORDER OF IT (1.6.0), because the native fade holds the body still: a
-- body put beside the door under the exit's cut to black hung 3 cm over the
-- ground, "falling", for the whole fade, where the platform draws no clip, and
-- fell when the image came back (Staging, 2026-10-28, 10:32:56; config.lua
-- `EXIT_FADE`). So, with the image on: (1) PREPARE -- the body is put beside
-- the door and lands there, faces the step's heading (turned back if not),
-- stands `STAND_LOOKS` looks and is held, standing, `HOLD_CHECK_LOOKS` looks
-- more; (2) the CURTAIN comes down (client/main.lua `M.CurtainDown`) over the
-- cameras' change to third person; (3) the VIEW -- third person drawn, the
-- camera swung round the body; (4) the FINAL look -- the plan on the hull as it
-- stands, the door's step within the clip's reach, the heading and the ground,
-- with NOTHING moved: a move that has to be made lifts the curtain first and
-- the step is prepared again in view; (5) the ASK; and the image comes back
-- with the step's first frame.
--
-- THE VIEW. About 1.5 s after an AV exit the Open77 client shows the pilot
-- from behind through its legacy camera path, which draws the game's own
-- first-person body -- the body without a head. From the moment the seat
-- empties this half holds the platform's own third person instead (the
-- stand-in body: dressed, with its head, and the ONLY body the clip plays on
-- on this screen), and lets it go once the player walks off, or at
-- `VIEW_MAX_MS`. The platform still calls the seat it is leaving occupied for
-- a moment (`exiting`): that is not "seated again". The client's chase camera
-- (17 m behind the hull, until its own exit deadline) and then its legacy
-- camera (2.5 m behind the body) are cameras detached under the perspective
-- arbiter's first-person decision, which it answers with its fatal row and so
-- keeps third person out: the legacy camera is turned off the moment it is
-- seen (`LEGACY_VIEW_OFF`; `Open77.camera.view` tells the two apart).
--
-- THE WAIT IS COUNTED IN FRAMES. The arbiter lets go of its fatal row only
-- after twelve clean frames (`exitFrames`, PerspectiveArbiter.hpp) and then
-- reveals the stand-in over a few more: a fifth of a second at 60 frames a
-- second, four seconds at three (Staging, 2026-10-27, 18:57:58: the old 5 s
-- wait ran out just as it let go; the screen stayed black 5.7 s and came back
-- on a clip already playing). So the clip is asked the moment the stand-in is
-- DRAWN -- third person, its body the proxy -- with the screen still faded; a
-- view that never comes is given up after `VIEW_WAIT_MS` AND `VIEW_WAIT_LOOKS`
-- watch passes (each at least a frame long) since the legacy camera went, or
-- at `VIEW_WAIT_MAX_MS`.
--
-- THE SHOT. Before the image comes back the camera swings `ORBIT_DEGREES`
-- round the body (`Open77.camera.orbit`, the platform's preview orbit): the
-- clip is seen from in front -- the body stepping down out of the open door
-- toward the lens -- and the camera goes back behind the body as it ends.
--
-- THE PLAN AGAIN. The walk-out is planned the moment the seat empties, when
-- the engine may still draw the hull where its flight began (2.5 m off after a
-- hop from the back seat: the clip started on nothing beside the open door,
-- Staging, 2026-10-28, 01:10:52), and before the server has set it down on its
-- gear. So it is planned again on the hull as it stands before the clip is
-- asked: the body is moved to an end point that moved, a door whose step hangs
-- higher than the clip's first step can stand on is waited for (and the ground
-- under the gear measured again), and a step that never comes within reach
-- plays no clip -- the body is shown standing, never stepping out of the air.
-- The ask carries the plan; the server checks it against its own hull and
-- may answer with its pose, which is planned on once more.
--
-- THE STEP ON A SLOPE (1.6.2). An AV parked where the ground falls away beside
-- its door had its step 0.92 m over the end point (Staging, 2026-10-28,
-- 14:41:26): past the clip's 0.85 m, no clip. A step out of the clip's band is
-- turned about the door (`STEP_TURNS`: the clip still starts on the door, its
-- end point swung along the hull) -- foreseen while the step is prepared, the
-- set-down still to come taken off, and moved to with the image on; found only
-- at the final look, the curtain is lifted once for the move -- else, when no
-- turn brings it within the band, a step within the relaxed band is played as
-- it is. Each search has a pass of its own: the host counts every instruction
-- of a pass.
--
-- THE STEP'S HEADING (1.5.0). The clip's path turns with the body: on the
-- laptop the step was planned facing 75 deg and the body faced 245.8 as it
-- played (Staging, 2026-10-28, 03:15:44, the game's own position probe) -- its
-- first frame 4.9 m from the door, half a metre up, walking toward the AV. So
-- the body's heading is watched from the placement to the clip's end (every
-- turn a line, with what was going on), checked before the ask (turned back
-- when it is more than `FACING_DEGREES` off, and it must hold for two looks),
-- and checked again as the clip starts. A camera swing that turns the body
-- with it is let go of for the session. A body that is not on the ground when
-- the clip is due is let go of its hold until it stands (the platform plays no
-- clip on a body in the air), then put on the ground once.
--
-- THE DOOR AS THIS GAME DRAWS IT. A known airframe's door slots (`AIRFRAMES`
-- ... `DOOR_SLOTS`) are read off the hull this game draws: their place in the
-- hull's frame says the door is where the plan has it, on the hull's other
-- side (the frame faces the other way: planned on it turned round), or
-- elsewhere (said, with the numbers).
--
-- Every step is a line in the client log: the plan (clip, door, end point,
-- heading), each change of the arbiter's answer while the view is held, the
-- legacy camera turned off (and how far the camera was from the eyes), the
-- wait for third person, the shot, the plan made again (and the step's height),
-- the body's heading and every turn of it, the door slot, the ask, the answer,
-- the freeze, the view held and released.
-- =============================================================================

-- The platform still reports the seat it is leaving for a moment after the
-- exit (the client's own exit waits 1.5 s): a seat in the same hull within
-- this is the exit, not a boarding.
local SEAT_LINGER_MS = 3000
-- The client's own exit holds its chase camera for 1.5 s after its exit code
-- runs, a frame or two after the seat empties (Staging: its legacy exit camera
-- came 1.47 s into the hold at 11 frames a second, 2.07 s at 3). Where the
-- camera stands says which of the two holds the screen; when it cannot be
-- read, nothing is turned off before `LEGACY_AFTER_MS`.
local LEGACY_AFTER_MS = 1600
local LEGACY_EARLIEST_MS = 400
-- The camera measured from the eyes: on them (first person) under
-- `ATTACHED_METRES`; the legacy camera 2.5 m behind and 0.6 m over them
-- (`Api::Camera::SetThirdPerson`); the chase camera 17 m behind the hull
-- (`VehicleChaseRig`, `kArm`) beyond `CHASE_METRES` -- its own deadline ends it.
local EYE_METRES = 1.6
local ATTACHED_METRES = 1.0
local CHASE_METRES = 8.0
-- The legacy camera is turned off at most this often, and this many times an exit.
local LEGACY_EVERY_MS = 200
local LEGACY_MAX = 12
-- What the arbiter answers while a camera is detached under its first-person
-- decision: the fatal row (its single-camera invariant broken), with the
-- foreign camera row held behind it (Staging, 2026-10-27: `fatal_state` for
-- the whole legacy exit camera, third person 0.65 s after it was off).
local BLOCKED = { foreign_camera = true, fatal_state = true, fatal = true }
-- The camera's swing for the shot is tried this many times (a refusal while the
-- rig takes over is tried again on the next passes).
local ORBIT_TRIES = 6
-- A turn of the body of more than this between two looks is a line in the log
-- (at most `TURN_LINES` an exit).
local TURN_SAY_DEGREES = 2.0
local TURN_LINES = 12
-- A turn within this of a camera swing, by about the swing's own angle
-- (`SWING_SLACK_DEGREES`), is the swing turning the body.
local SWING_TURN_MS = 1500
local SWING_SLACK_DEGREES = 25.0
-- While the clip starts its heading is read again for this long, and turned
-- back at most `CLIP_TURNS` times when it is twice `FACING_DEGREES` off.
local CLIP_FACING_MS = 1500
local CLIP_TURNS = 2
-- ON ITS FEET (1.5.1): this many looks in a row with the body on the ground,
-- out of the vehicle and out of any workspot make it "standing"; a hold put on
-- is believed once the body stands this many looks later.
local STAND_LOOKS = 2
local HOLD_CHECK_LOOKS = 2
-- The client's own exit is over once its exit camera went off `EXIT_SETTLE_MS`
-- ago, or third person is drawn, or -- on a client that shows neither -- the
-- seat was left `EXIT_DONE_MS` ago (said in the log; the hold no longer waits
-- for it, 1.6.0). A move is looked at `MOVE_SETTLE_LOOKS` passes before the body
-- is held again.
local EXIT_SETTLE_MS = 400
local EXIT_DONE_MS = 2500
local MOVE_SETTLE_LOOKS = 3
-- THE CURTAIN (1.6.0) waits this long at most after the seat was left for the
-- plan made again on a steady hull (`early`) before it comes down -- before
-- the client's chase camera lets go, 1.5 s after the exit: a plan that still
-- moves the end point after it lifts the curtain for the move.
local CURTAIN_EARLY_WAIT_MS = 1000
-- The body put this far over the ground under it, once, when it has not stood
-- `GROUND_WAIT_MS` after it was put beside the door.
local NUDGE_METRES = 0.05
-- At most this many lines an exit about the body's state changing; and while
-- it is off the ground, its numbers every `BODY_EVERY_MS`, `BODY_STILL_LINES`
-- times at most.
local BODY_LINES = 24
local BODY_EVERY_MS = 500
local BODY_STILL_LINES = 16

local M = AvDoor
local W = {}
M.WalkOut = W

-- THE PASS (1.5.1): the watch's passes are counted, and a move is stamped with
-- the pass it was made in -- the engine applies it on the next frame, so no read
-- in the same pass says where it put the body. A count, not the clock: the clock
-- moves inside a pass (Staging, 2026-10-28, 04:39:23.483: "did not hold", a read
-- in the pass of the turn back). `W.Tick` ends each pass.
local pass = 0

-- The walk-out of the exit in progress:
-- `{ id, seat, clip, target, yaw, door, asked, askedAt, answered, ok, reason,
--    playing = { since, untilAt }, planAt }`.
local walk = nil

-- The view hold: `{ since, why, id, moving, lastAt, last, perspective,
-- legacyAt, legacyOffs, looks, offLooks, offAt, revealed, settled, chaseSaid,
-- seat }`, or nil. `looks` counts the watch passes of the hold (each at least
-- one frame long); `offLooks` is the count when the legacy camera went off.
local view = nil

-- The camera swung round the body for the clip: `{ since, degrees, yawAt }`,
-- or nil; and how many times the swing was tried for this exit.
local orbiting = nil
local orbitTries = 0
-- Set once a swing was seen turning the body with it: no swing on this client
-- for the rest of the session (`{ at, from, to }`).
local orbitTurnsBody = nil

-- The door slots this client was told about a hull's record, by record: once.
local slotsSaid = {}

-- Causes already said in the log, so a missing native is one line.
local said = {}

-- What the server last said about this player's style: `{ ok, style, reason }`,
-- or nil when it has said nothing yet. No yes, no clip.
local style = nil

local function anim() return M.WalkOutSettings() end

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

--- The body's heading as the engine has it (`GetWorldYaw`; REDengine's: 0
--- toward +y, growing toward -x), 0 to 360, or nil.
local function bodyYaw()
    local character = Open77.character
    if type(character) ~= 'table' then return nil end
    if type(character.yaw) == 'function' then
        local read, yaw = pcall(character.yaw)
        yaw = read and finite(yaw) or nil
        if yaw ~= nil then return yaw % 360.0 end
    end
    if type(character.state) == 'function' then
        local read, state = pcall(character.state)
        local yaw = read and type(state) == 'table' and finite(state.yaw) or nil
        if yaw ~= nil then return yaw % 360.0 end
    end
    return nil
end
W.BodyYaw = bodyYaw

--- The body's own snapshot (`Open77.character.state()`), or nil.
local function bodyState()
    local character = Open77.character
    if type(character) ~= 'table' or type(character.state) ~= 'function' then return nil end
    local read, state = pcall(character.state)
    if read and type(state) == 'table' then return state end
    return nil
end

--- Where this game draws a known airframe's door: its first door slot that
--- answers (`AIRFRAMES` ... `DOOR_SLOTS`), in the world and in the frame's own
--- axes, and what that says (`M.DoorSlotVerdict`). Nil (and why) for an
--- airframe without slots, a client without the read, or no slot answered.
-- @param id any the hull
-- @param record any its record
-- @param frame table the hull frame the plan is made on
-- @return table|nil `{ name, world, at, verdict, off }`
-- @return string|nil why not
--- WHAT THE HULL PUBLISHES, once a record: the next test then knows its slots.
--- (Its own step: the list is long, and its line too -- the host's budget.)
--- 1.7.1: only when asked (`EXIT_ANIM.LIST_SLOTS = true`): the door's slot is
--- read on its own, and the whole list -- 70 slots on the Excalibur -- went
--- with the dearest frame of an exit (64.5 ms of Lua in one frame, Staging,
--- 2026-10-29; `slow native` lines now name what costs).
local function listSlots(id, record)
    if not anim().listSlots or M.DoorSlots(record) == nil then return end
    local character = Open77.character
    if type(character) ~= 'table' or type(character.bones) ~= 'function' then return end
    local selector = { vehicleId = M.IdNumber(id) }
    local key = tostring(record):lower()
    if not slotsSaid[key] then
        slotsSaid[key] = true
        local read, names, why = M.Native('character.bones', character.bones, selector)
        if read and type(names) == 'table' then
            local shown = {}
            for i = 1, math.min(#names, 48) do shown[#shown + 1] = tostring(names[i]) end
            Open77.log.info(('the AV %s publishes %d slot(s) to this client: %s%s'):format(tostring(record), #names,
                #shown > 0 and table.concat(shown, ', ') or 'none', #names > #shown and ', ...' or ''))
        else
            Open77.log.info(('the AV %s lists no slots to this client: %s'):format(tostring(record),
                tostring(read and why or names)))
        end
    end
end

local function doorSlot(id, record, frame)
    local slots = M.DoorSlots(record)
    if slots == nil then return nil, 'no door slots known for this airframe' end
    local character = Open77.character
    if type(character) ~= 'table' or type(character.bonePosition) ~= 'function' then
        return nil, 'no Open77.character.bonePosition on this client'
    end
    local selector = { vehicleId = M.IdNumber(id) }
    local reasons = {}
    for _, name in ipairs(slots.names) do
        local read, point, why = M.Native('character.bonePosition', character.bonePosition, selector, name)
        if read and type(point) == 'table' and finite(point.x) ~= nil and finite(point.y) ~= nil then
            local world = { x = finite(point.x), y = finite(point.y), z = finite(point.z) }
            local at = M.ToHullLocal(frame, world)
            if at == nil then return nil, 'the hull frame cannot be read' end
            local verdict, off = M.DoorSlotVerdict(slots, at)
            return { name = name, world = world, at = at, verdict = verdict, off = off }
        end
        reasons[#reasons + 1] = ('%s: %s'):format(name, tostring(read and why or point))
    end
    return nil, 'no door slot answered (' .. table.concat(reasons, '; ') .. ')'
end
W.DoorSlot = doorSlot

-- ── the hold ─────────────────────────────────────────────────────────────────
-- THE CLIP PLAYS ONLY ON A BODY ON ITS FEET (1.5.1). The platform's custom
-- locomotion layer -- the exit clip's -- is on for a body only while its own
-- game says it stands on the ground (client/src/puppet/MirrorGraph.cpp: the
-- layer is enabled with `animation.grounded || BridgingGroundContact()`), and
-- every screen draws it from that same sample: the stand-in here, the copies
-- on the other screens.
--
-- WHY THE LAPTOP'S BODY NEVER STOOD (1.6.0). 1.5.0 to 1.5.3 cut the screen to
-- black at the exit's first frame and put the body beside the door under it;
-- the native fade holds the body still wherever it is, so it hung 3 cm over
-- the ground, "off the ground (falling)", 0.00 m/s, for the whole 5.4 to 7.5 s
-- of black -- held or not, let go and held again, put 5 cm over the ground
-- again -- and moved the moment the image came back (the client's "first move"
-- rule, `vflt-exit-tpp-off`, fired then each time: Staging, 2026-10-28,
-- 01:54:23.2, 01:54:39.2, 10:33:02.7). 1.4.0 drew the clip: its placement was
-- made while the engine still mounted the body, before the fade could hold it
-- anywhere. So now the body is put beside the door with the image on, held
-- only once it stands there (`holdReady`), and nothing moves it while the
-- curtain is down. It is never moved while held either: a move lets go first,
-- and the body is held again `MOVE_SETTLE_LOOKS` passes after it stands again.
--
-- THE HOLD IS ONE OF TWO (`EXIT_ANIM.HOLD`): 'position', the platform's forced
-- freeze (`Open77.players.freezePosition`, a locomotion state of its own), or
-- 'restriction', the engine's NoMovement restriction
-- (`Open77.character.setFrozen`, what death applies: nothing in the locomotion
-- state changes). Turning is held with either (`freezeRotation`). A hold that
-- takes a STANDING body off the ground is let go, and the next one tried for
-- the rest of the session; after both, none.

-- What a look at the body says, as a line (defined with the look, below).
local bodyLine

-- The hold this half has on the body: `{ since, untilAt, assertedAt, way }`,
-- or nil.
local frozen = nil
-- The hold that ways down this session: 'position', 'restriction' or 'none'
-- (nil: the configured one).
local holdWay = nil
local holdLifts = {}

--- The hold to use now.
local function wayOfHold()
    if holdWay ~= nil then return holdWay end
    local configured = anim().hold
    if configured == 'restriction' or configured == 'none' then return configured end
    return 'position'
end

--- Puts the hold on (or asserts it again: the host's controls carry a
--- watchdog) for `ms`. Callers wanting the body held use `holdBody`, which
--- waits for the body to stand.
-- @return boolean whether the body is held now
local function freeze(ms)
    if not anim().freeze then return false end
    local way = wayOfHold()
    local players, character = Open77.players, Open77.character
    local now = M.Now()
    local held = false
    if way == 'position' then
        if type(players) ~= 'table' or type(players.freezePosition) ~= 'function' then
            once('freeze', 'warn', 'no Open77.players.freezePosition on this client: the body is held by the NoMovement '
                .. 'restriction instead')
            holdWay = 'restriction'
            way = 'restriction'
        else
            local read, ok, reason = M.Native('players.freezePosition', players.freezePosition, true)
            if not read or ok ~= true then
                Open77.log.warn('the exit clip could not hold the body still: ' .. tostring(read and reason or ok))
            else
                held = true
            end
        end
    end
    if way == 'restriction' then
        if type(character) ~= 'table' or type(character.setFrozen) ~= 'function' then
            once('freeze:restriction', 'warn', 'no Open77.character.setFrozen on this client: the body is not held '
                .. 'for the exit clip')
            holdWay = 'none'
            way = 'none'
        else
            local read, ok, reason = pcall(character.setFrozen, true)
            if not read or ok ~= true then
                Open77.log.warn('the exit clip could not hold the body (NoMovement): ' .. tostring(read and reason or ok))
            else
                held = true
            end
        end
    end
    -- No hold this session (both took the body off the ground, or neither is
    -- on this client): nothing is put on.
    if way == 'none' or not held then return false end
    local turnRead, turnOk = false, false
    if type(players) == 'table' and type(players.freezeRotation) == 'function' then
        turnRead, turnOk = M.Native('players.freezeRotation', players.freezeRotation, true)
    end
    if frozen == nil then
        Open77.log.info(('exit clip: body held for %.1fs (%s; turning %s)'):format(ms / 1000.0,
            way == 'position' and 'the platform\'s freeze' or 'the NoMovement restriction',
            (turnRead and turnOk == true) and 'held too' or 'free'))
    end
    frozen = { since = frozen and frozen.since or now, untilAt = now + ms, assertedAt = now, way = way }
    return true
end

--- The hold put on for the walk's wish (`walk.hold`), and checked from the next
--- pass; one refused twice is not waited for this exit (the clip is asked with
--- the body free rather than never).
local function holdNow(h, now)
    local b = walk ~= nil and walk.body or nil
    local standing = b ~= nil and b.good >= STAND_LOOKS
    if freeze(h.untilAt - now) then
        h.checking, h.checkPass = HOLD_CHECK_LOOKS, pass
        -- Whether the body stood when it was held: a hold that takes a standing
        -- body off the ground is a lift.
        h.wasStanding, h.heldAt, h.heldLooks, h.held = standing, now, 0, false
        h.times = (h.times or 0) + 1
        local yaw = bodyYaw()
        Open77.log.info(('exit clip %s: held %s, %.1fs after the seat was left -- the body %s beside the door (%s), '
            .. 'facing %s; believed once it stands, held, %d looks'):format(walk.clip, h.times > 1 and 'again' or 'now',
            (now - walk.planAt) / 1000.0, standing and 'stands' or 'is not yet standing',
            bodyLine(b ~= nil and b.last or nil), yaw ~= nil and ('%.0f deg'):format(yaw) or 'an unread heading',
            HOLD_CHECK_LOOKS))
        return true
    end
    h.refusals = (h.refusals or 0) + 1
    if h.refusals >= 2 and not h.refused then
        h.refused = true
        Open77.log.warn(('exit clip %s: the hold was refused twice: the clip is asked with the body free'):format(
            walk ~= nil and walk.clip or '?'))
    end
    return false
end

--- Lets go of every hold this half has on the body.
local function unfreeze(why)
    if frozen == nil then return end
    local players, character = Open77.players, Open77.character
    if type(players) == 'table' then
        if type(players.freezePosition) == 'function' then M.Native('players.freezePosition', players.freezePosition, false) end
        if type(players.freezeRotation) == 'function' then M.Native('players.freezeRotation', players.freezeRotation, false) end
    end
    if type(character) == 'table' and type(character.setFrozen) == 'function' and frozen.way == 'restriction' then
        pcall(character.setFrozen, false)
    end
    Open77.log.info(('exit clip: body let go after %.1fs (%s)'):format((M.Now() - frozen.since) / 1000.0, why))
    frozen = nil
end

-- ── the body on its feet ─────────────────────────────────────────────────────

--- The screen in a word, for the body's lines (client/main.lua `M.ScreenState`):
--- the native fade holds the body still for as long as it is out.
local function screenWord()
    local s = M.ScreenState ~= nil and M.ScreenState() or nil
    if s == nil then return nil end
    if s.black then return 'the screen black' end
    if s.fading or s.out then return 'the screen fading to black' end
    if s.busy or (s.remainingMs or 0) > 0 then return 'the screen coming back' end
    return 'the image on'
end

--- What the body's own game says of it this look: `{ grounded, mounted,
--- workspot, air, fall, landing, standing, z, vz }`, or nil when it cannot be read.
local function bodyNow()
    local state = bodyState()
    if state == nil then return nil end
    local vehicle = type(state.vehicle) == 'table' and state.vehicle or {}
    local reading = {
        grounded = state.grounded, air = state.air, fall = state.fall, landing = state.landing,
        mounted = vehicle.mounted == true or state.inVehicle == true, workspot = state.inWorkspot == true,
        z = type(state.position) == 'table' and finite(state.position.z) or nil,
        vz = type(state.velocity) == 'table' and finite(state.velocity.z) or nil,
    }
    -- A host whose snapshot has no `grounded` is taken at its word: standing.
    reading.standing = state.grounded ~= false and not reading.mounted and not reading.workspot
    return reading
end

function bodyLine(b)
    if b == nil then return 'not read' end
    local fall = b.fall ~= nil and b.fall ~= 'none' and (', fall ' .. tostring(b.fall)) or ''
    local parts = { b.grounded == false and ('off the ground (%s%s)'):format(tostring(b.air or '?'), fall)
        or (b.grounded == true and 'on the ground' or 'ground not said') }
    if b.mounted then parts[#parts + 1] = 'mounted in the vehicle' end
    if b.workspot then parts[#parts + 1] = 'in a workspot' end
    return table.concat(parts, ', ')
end

local function holdText()
    if frozen == nil then return 'not held' end
    return frozen.way == 'restriction' and 'held (NoMovement)' or 'held still'
end

--- The numbers of a look at the body: its height over the ground at the clip's
--- end point and its speed up or down, for the log.
local function bodyNumbers(b)
    if b == nil then return '' end
    local parts = {}
    local ground = walk ~= nil and walk.target ~= nil and finite(walk.target.ground) or nil
    if b.z ~= nil and ground ~= nil then parts[#parts + 1] = ('%.2f m over the ground'):format(b.z - ground) end
    if b.vz ~= nil then parts[#parts + 1] = ('%.2f m/s up'):format(b.vz) end
    if #parts == 0 then return '' end
    return ', ' .. table.concat(parts, ', ')
end


--- Whether the body faces the step's heading (or the heading is not watched):
--- a body turned off it is turned back -- a move -- before it is held, so the
--- move lets go of nothing. While the clip plays, always.
local function headingHeld()
    if walk == nil or walk.playing ~= nil then return true end
    local settings = anim()
    if settings.facingTries == 0 or walk.yaw == nil then return true end
    local yaw = bodyYaw()
    if yaw == nil then return true end
    return (M.YawApart(yaw, walk.yaw) or 0) <= settings.facing
end

--- Whether the client's own exit is over (1.5.3): its exit camera went off
--- `EXIT_SETTLE_MS` ago (`view.offAt`), or third person is drawn, or -- on a
--- client that shows neither -- the seat was left `EXIT_DONE_MS` ago.
-- @param now number
-- @return boolean
local function exitOver(now)
    if walk == nil then return false end
    if view ~= nil and view.offAt ~= nil then return now - view.offAt >= EXIT_SETTLE_MS end
    if view ~= nil and view.revealed then return true end
    return now - walk.planAt >= EXIT_DONE_MS
end
W.ExitOver = function() return exitOver(M.Now()) end

--- Whether the body may be held now (1.6.0): it STANDS beside the door -- out
--- of the vehicle and any workspot, its game saying it is on the ground
--- `STAND_LOOKS` looks in a row -- faces the step's heading, and was not moved
--- in the last `MOVE_SETTLE_LOOKS` passes. A body is never held off the ground:
--- the forced freeze keeps a body where it takes it.
-- @param now number
-- @return boolean
local function holdReady(now)
    if walk == nil or not anim().freeze or wayOfHold() == 'none' then return false end
    local h = walk.hold
    if h == nil or h.refused then return false end
    local b = walk.body
    if b == nil or b.last == nil then return false end
    if b.last.mounted or b.last.workspot then return false end
    if b.good < STAND_LOOKS then return false end
    if b.movedPass ~= nil and pass - b.movedPass < MOVE_SETTLE_LOOKS then return false end
    if b.reholdPass ~= nil and pass - b.reholdPass < MOVE_SETTLE_LOOKS then return false end
    return headingHeld()
end

--- The body's hold wanted until `now + ms` (at least, or exactly then with
--- `exact`: the clip's own end): put on as soon as it may be (`holdReady`,
--- `watchBody`).
-- @param ms number
-- @param why string
-- @param exact boolean|nil
local function holdBody(ms, why, exact)
    if walk == nil or not anim().freeze then return end
    local now = M.Now()
    local h = walk.hold
    if h == nil then
        h = { untilAt = 0, why = why }
        walk.hold = h
    end
    h.untilAt = exact and (now + ms) or math.max(h.untilAt, now + ms)
    h.why = why
    local b = walk.body
    if frozen ~= nil then
        freeze(h.untilAt - now)
    elseif holdReady(now) then
        holdNow(h, now)
    elseif not h.waitSaid then
        h.waitSaid = true
        Open77.log.info(('exit clip %s: the body is held once it stands beside the door, facing the step (%s now; %s)')
            :format(walk.clip, bodyLine(b ~= nil and b.last or nil), why))
    end
end

--- The body is about to be moved (by this half, or by the exit guard putting
--- it back): the hold let go first -- a body moved while held may be left off
--- the ground -- and it must stand again before it is held again.
-- @param why string
function W.BodyMoved(why)
    if frozen ~= nil then unfreeze('let go for a move: ' .. tostring(why)) end
    if walk == nil then return end
    local b = walk.body
    if b == nil then
        b = { good = 0, lines = 0, looks = 0 }
        walk.body = b
    end
    b.good = 0
    b.movedPass = pass
    b.moves = (b.moves or 0) + 1
    if walk.hold ~= nil then walk.hold.checking = nil end
    -- A MOVE PREPARES THE STEP AGAIN (1.6.0): the body must land, stand, face the
    -- step and be held again before the curtain comes down (again) and the clip
    -- is asked -- whoever made the move (this half, or the guard putting back a
    -- body the platform moved). The curtain itself is lifted by the move.
    if not walk.asked and walk.phase ~= nil and walk.phase ~= 'prepare' then
        Open77.log.info(('exit clip %s: the body is moved (%s) while the step was %s: it is prepared again with the '
            .. 'image on'):format(walk.clip, tostring(why), walk.phase == 'view' and 'waiting for third person'
                or 'looked at a last time'))
        walk.phase = 'prepare'
        if walk.facing ~= nil then walk.facing.good = 0 end
    end
end

--- A move of the body by this half (`M.ExitRetarget`), the hold let go first.
-- @return boolean whether the move was made
local function moveBody(target, yaw, why, frame)
    if M.ExitRetarget == nil or walk == nil then return false end
    W.BodyMoved(why)
    if not M.ExitRetarget(target, yaw, why, frame) then return false end
    -- The guard's own move marks the body moved too; this one says when.
    W.BodyMoved(why)
    return true
end

--- One look at the body, every pass from the plan to the clip's end: its state
--- (every change a line), standing or not, the hold put on once it stands and
--- checked after, and -- while the clip plays -- the ground under it.
-- @param now number
local function watchBody(now)
    if walk == nil then return end
    local b = walk.body
    if b == nil then
        b = { good = 0, lines = 0, looks = 0 }
        walk.body = b
    end
    -- A move made in this same pass is applied on the next frame: nothing read
    -- now says where it put the body.
    if b.movedPass == pass then return end
    local reading = bodyNow()
    if reading == nil then return end
    b.looks = b.looks + 1
    b.last = reading
    local line = bodyLine(reading)
    local function say(what)
        local screen = screenWord()
        Open77.log.info(('exit body: %s%s, %.1fs after the seat was left (%s%s%s)'):format(what, bodyNumbers(reading),
            (now - walk.planAt) / 1000.0, holdText(), screen ~= nil and (', ' .. screen) or '',
            walk.playing ~= nil and (', the clip %.1fs in'):format((now - walk.playing.since) / 1000.0)
                or (walk.asked and ', the clip asked' or '')))
    end
    if line ~= b.lastLine then
        b.lastLine = line
        b.lines = b.lines + 1
        b.saidAt = now
        if b.lines <= BODY_LINES then say(line) end
    elseif not reading.standing and b.saidAt ~= nil and now - b.saidAt >= BODY_EVERY_MS
        and (b.still or 0) < BODY_STILL_LINES then
        -- OFF THE GROUND FOR A WHILE: the numbers every half second, to see
        -- whether the body hovers, sinks or rests (1.5.3).
        b.saidAt = now
        b.still = (b.still or 0) + 1
        say('still ' .. line)
    end
    if reading.standing then
        b.good = b.good + 1
        if b.good == STAND_LOOKS then
            b.standingAt = b.standingAt or now
            if not b.stoodSaid then
                b.stoodSaid = true
                Open77.log.info(('exit clip %s: the body stands on the ground %.1fs after the seat was left'):format(
                    walk.clip, (now - walk.planAt) / 1000.0))
            end
        end
    else
        b.good = 0
    end
    local h = walk.hold
    -- THE HOLD, once it may go on (`holdReady`); and believed only once the body
    -- stands, held, `HOLD_CHECK_LOOKS` looks in a row.
    if h ~= nil and now < h.untilAt then
        if frozen == nil and holdReady(now) then
            holdNow(h, now)
        elseif frozen ~= nil and h.checkPass ~= pass then
            h.heldLooks = (h.heldLooks or 0) + 1
            -- A held body that stood, off the ground again: checked again.
            if h.held and not reading.standing then
                h.held, h.checking = false, HOLD_CHECK_LOOKS
                Open77.log.warn(('exit clip %s: the held body is %s again (%s)'):format(walk.clip, line, holdText()))
            elseif h.checking ~= nil then
                if reading.standing then
                    h.checking = h.checking - 1
                    if h.checking <= 0 then
                        h.checking = nil
                        h.held = true
                        if not h.heldSaid then
                            h.heldSaid = true
                            Open77.log.info(('exit clip %s: held, and on the ground (%s; %s)'):format(walk.clip,
                                holdText(), h.wasStanding and 'it stood before the hold'
                                    or ('it stood %.1fs after the hold went on'):format((now - (h.heldAt or now)) / 1000.0)))
                        end
                    end
                elseif h.wasStanding then
                    -- THE HOLD TOOK A STANDING BODY OFF THE GROUND: let go, and the
                    -- next way tried from now on.
                    local way = frozen.way
                    holdLifts[way] = (holdLifts[way] or 0) + 1
                    holdWay = way == 'position' and 'restriction' or 'none'
                    Open77.log.warn(('exit clip %s: the hold (%s) took the body off the ground (%s): let go, and this '
                        .. 'client holds a body with %s from now on'):format(walk.clip, way, line,
                        holdWay == 'restriction' and 'the NoMovement restriction' or 'nothing'))
                    h.checking = nil
                    unfreeze('the hold took the body off the ground')
                    b.good = 0
                else
                    -- Held while it was not standing (a hold asked for before it
                    -- stood): counted afresh until it does.
                    h.checking = HOLD_CHECK_LOOKS
                end
            end
        end
    end
    -- WHILE THE CLIP PLAYS: a body off the ground is a clip no screen draws.
    if walk.playing ~= nil and not reading.standing then
        b.airInClip = (b.airInClip or 0) + 1
        if b.airInClip == 1 then
            Open77.log.warn(('exit clip %s: the body is %s %.1fs into the clip -- the platform draws no clip on it, on '
                .. 'any screen (%s)'):format(walk.clip, line, (now - walk.playing.since) / 1000.0, holdText()))
            if frozen ~= nil then unfreeze('the body left the ground during the clip') end
        end
    end
end

-- ── the view ─────────────────────────────────────────────────────────────────

--- The perspective arbiter's answer, or nil.
local function perspectiveState()
    local perspective = Open77.perspective
    if type(perspective) ~= 'table' or type(perspective.state) ~= 'function' then return nil end
    local read, state = pcall(perspective.state)
    if read and type(state) == 'table' then
        -- A stand-in drawn here is a stand-in made (client/standin.lua, 1.7.5).
        if state.body == 'proxy' and M.StandIn ~= nil then M.StandIn.Note(state, 'an exit or a boarding') end
        return state
    end
    return nil
end
W.PerspectiveState = perspectiveState

--- Whether the platform's third person draws the stand-in: the clip, which
--- plays on that body, can be seen. The reveal is under way or done.
local function thirdPersonShown(state)
    return state ~= nil and state.mode == 'tps' and (state.body == 'proxy' or state.settled == true)
end

--- Whether the platform's third person is drawn and settled.
local function thirdPersonSettled(state)
    return state ~= nil and state.mode == 'tps' and state.settled == true
end

--- The watch passes since the legacy camera went off, for the log.
local function looksSinceOff()
    if view == nil or view.offLooks == nil then return '' end
    return (', %d look(s) after the client\'s exit camera went off'):format(view.looks - view.offLooks)
end

--- A line each time the arbiter's answer changes while the view is held.
local function watchPerspective(now, state)
    if view == nil or state == nil then return end
    if not view.revealed and thirdPersonShown(state) then
        view.revealed = true
        Open77.log.info(('exit view: third person drawn (the stand-in, with its head) %.1fs into the hold%s: the '
            .. 'client\'s exit camera is left alone from now on'):format((now - view.since) / 1000.0, looksSinceOff()))
    end
    if not view.settled and thirdPersonSettled(state) then
        view.settled = true
        view.revealed = true
        Open77.log.info(('exit view: third person settled %.1fs into the hold'):format((now - view.since) / 1000.0))
    end
    -- A swing round the body lives on the rig: a view thrown out of third person
    -- loses it, and it is made again once the stand-in is drawn again.
    if orbiting ~= nil and state.mode ~= 'tps' then
        Open77.log.info(('exit view: the camera\'s swing round the body was lost with third person (%s, %s): swung '
            .. 'again when it is back'):format(tostring(state.mode), tostring(state.reason)))
        orbiting = nil
    end
    local line = ('%s, %s, %s (rule %s), camera %s, body %s'):format(tostring(state.mode),
        state.settled == true and 'settled' or tostring(state.transition), tostring(state.reason),
        tostring(state.rule), tostring(state.camera), tostring(state.body))
    if line == view.perspective then return end
    view.perspective = line
    Open77.log.info(('exit view: the platform\'s perspective: %s, %.1fs into the hold%s'):format(line,
        (now - view.since) / 1000.0, state.violations ~= nil and (', %s violation tick(s)'):format(tostring(state.violations)) or ''))
end

--- How far the rendered camera stands from the eyes, in metres, or nil when
--- the camera or the body cannot be read.
local function cameraAway()
    local camera = Open77.camera
    if type(camera) ~= 'table' or type(camera.view) ~= 'function' then return nil end
    local read, seen = pcall(camera.view)
    if not read or type(seen) ~= 'table' or type(seen.position) ~= 'table' then return nil end
    local at = position()
    if at == nil then return nil end
    local x, y, z = finite(seen.position.x), finite(seen.position.y), finite(seen.position.z)
    if x == nil or y == nil or z == nil then return nil end
    local dx, dy, dz = x - at.x, y - at.y, z - (at.z + EYE_METRES)
    return math.sqrt(dx * dx + dy * dy + dz * dz)
end

--- The client's legacy exit camera keeps the arbiter out -- a camera detached
--- under its first-person decision, which it answers as the fatal row (and a
--- foreign camera): turned off the moment it is seen, while the seat is no
--- longer held (gone, or only being left). Its chase camera before it is left
--- to the client's own deadline; a camera that cannot be measured is turned off
--- from `LEGACY_AFTER_MS`. Every `LEGACY_EVERY_MS` at most, `LEGACY_MAX` times.
-- @param seat table|nil this pass's seat read
local function legacyOff(now, state, seat)
    if view == nil or state == nil or not anim().legacyOff then return end
    -- ONCE THE STAND-IN IS DRAWN THE CAMERA IS THE PLATFORM'S: turning the
    -- client's camera off is `SetThirdPerson(false)`, an attach that stops the
    -- rig, and on top of a third person it threw the view to first person for
    -- two seconds (Staging, 2026-10-27, 17:39:21.966). The arbiter puts its own
    -- third person back by itself.
    if view.revealed or view.settled then return end
    if seat ~= nil and seat.exiting ~= true then return end
    local held = now - view.since
    if held < LEGACY_EARLIEST_MS then return end
    if not BLOCKED[tostring(state.reason)] and not BLOCKED[tostring(state.rule)] then return end
    local away = cameraAway()
    if away ~= nil then
        -- On the eyes: the client's camera is off already; the arbiter counts its
        -- clean frames.
        if away < ATTACHED_METRES then return end
        if away > CHASE_METRES then
            if not view.chaseSaid then
                view.chaseSaid = true
                Open77.log.info(('exit view: the client\'s chase camera still holds the screen (%.1f m from the eyes, '
                    .. '%.1fs into the hold): its own exit deadline ends it'):format(away, held / 1000.0))
            end
            return
        end
    elseif held < LEGACY_AFTER_MS then
        return
    end
    if view.legacyAt ~= nil and now - view.legacyAt < LEGACY_EVERY_MS then return end
    if (view.legacyOffs or 0) >= LEGACY_MAX then return end
    local camera = Open77.camera
    if type(camera) ~= 'table' or type(camera.thirdPerson) ~= 'function' then
        return once('legacy', 'warn', 'no Open77.camera.thirdPerson on this client: the legacy exit camera keeps '
            .. 'the platform\'s third person out')
    end
    local read, ok, reason = pcall(camera.thirdPerson, false)
    view.legacyAt, view.legacyOffs = now, (view.legacyOffs or 0) + 1
    local done = read and ok == true
    if done then view.offLooks, view.offAt = view.looks, now end
    Open77.log.info(('exit view: the client\'s legacy exit camera holds the screen (the perspective arbiter '
        .. 'answers %s): turned off (%s), %.1fs into the hold (the camera %s from the eyes)')
        :format(tostring(state.reason), done and 'done' or ('refused: ' .. tostring(read and reason or ok)),
            held / 1000.0, away ~= nil and ('%.1f m'):format(away) or 'not measured'))
end

--- THE SHOT: the camera swung round the body, so the clip is seen from in front.
-- @param now number
local function orbitOn(now)
    local degrees = anim().orbit
    if degrees == 0 or orbiting ~= nil or orbitTries >= ORBIT_TRIES then return end
    -- A swing that turned the body with it once is not made again: the clip's
    -- path turns with the body.
    if orbitTurnsBody ~= nil then
        orbitTries = ORBIT_TRIES
        return once('orbit:turns', 'info', ('exit view: no swing round the body on this client: one turned the body '
            .. 'with it (from %.0f to %.0f deg); the clip is seen from behind'):format(orbitTurnsBody.from,
            orbitTurnsBody.to))
    end
    local camera = Open77.camera
    if type(camera) ~= 'table' or type(camera.orbit) ~= 'function' then
        orbitTries = ORBIT_TRIES
        return once('orbit', 'warn', 'no Open77.camera.orbit on this client: the exit clip is seen from behind')
    end
    orbitTries = orbitTries + 1
    local read, ok, reason = pcall(camera.orbit, degrees)
    if not read or ok ~= true then
        Open77.log.info(('exit view: the camera could not swing round the body (%s, try %d of %d)%s')
            :format(tostring(read and reason or ok), orbitTries, ORBIT_TRIES,
                orbitTries >= ORBIT_TRIES and ': the clip is seen from behind' or ''))
        return
    end
    orbiting = { since = now, degrees = degrees, yawAt = bodyYaw(), pass = pass }
    Open77.log.info(('exit view: the camera swung %.0f deg round the body: the clip is seen from in front, the open '
        .. 'door behind it (the body facing %s)'):format(degrees,
        orbiting.yawAt ~= nil and ('%.0f deg'):format(orbiting.yawAt) or 'an unread heading'))
end

--- Whether a turn of the body to `yaw` is the camera's swing turning it with it:
--- soon after the swing, by about the swing's angle (either way).
local function swungBody(now, yaw)
    if orbiting == nil or orbiting.yawAt == nil or yaw == nil or now - orbiting.since > SWING_TURN_MS then
        return false
    end
    local turned = M.YawApart(yaw, orbiting.yawAt) or 0
    local swing = math.abs(orbiting.degrees) % 360.0
    if swing > 180.0 then swing = 360.0 - swing end
    return math.abs(turned - swing) <= SWING_SLACK_DEGREES
end

--- The swing turned the body with it: let go of, and never made again this session.
local function swingLetGo(yaw)
    if orbiting == nil then return end
    orbitTurnsBody = { at = M.Now(), from = orbiting.yawAt or 0, to = yaw or 0, pass = pass }
    Open77.log.warn(('exit view: the camera\'s swing round the body turned the body with it (from %.0f to %.0f deg, '
        .. 'the swing %.0f deg): the swing is let go, and the clip is seen from behind on this client from now on')
        :format(orbitTurnsBody.from, orbitTurnsBody.to, orbiting.degrees))
    local camera = Open77.camera
    if type(camera) == 'table' and type(camera.clearOrbit) == 'function' then pcall(camera.clearOrbit) end
    orbiting = nil
    orbitTries = ORBIT_TRIES
end

--- The camera back behind the body.
-- @param why string
local function orbitOff(why)
    if orbiting == nil then return end
    local camera = Open77.camera
    if type(camera) == 'table' and type(camera.clearOrbit) == 'function' then pcall(camera.clearOrbit) end
    Open77.log.info(('exit view: the camera back behind the body after %.1fs (%s)')
        :format((M.Now() - orbiting.since) / 1000.0, why))
    orbiting = nil
end

--- Holds the platform's own third person (the stand-in body, with its head).
-- @param why string for the log
-- @param id any the hull the exit is from (its seat lingering is not a boarding)
function W.HoldView(why, id)
    if not anim().holdView or view ~= nil then return end
    local perspective = Open77.perspective
    if type(perspective) ~= 'table' or type(perspective.setThirdPerson) ~= 'function' then
        return once('view', 'warn', 'no Open77.perspective.setThirdPerson on this client: the exit shows the '
            .. 'platform\'s legacy third person (the first-person body, no head)')
    end
    -- The stand-in made ahead (1.7.5) never lets go of a view this exit holds.
    if M.StandIn ~= nil then M.StandIn.Yield('an exit') end
    local read, ok, reason = M.Native('perspective.setThirdPerson', perspective.setThirdPerson, true, true)
    if not read or ok ~= true then
        return Open77.log.warn(('the exit could not hold third person (%s): the platform\'s legacy view of the '
            .. 'exit draws the first-person body, without its head'):format(tostring(read and reason or ok)))
    end
    view = { since = M.Now(), why = why, id = id, moving = 0, looks = 0 }
    orbitTries = 0
    Open77.log.info(('exit view: third person held (%s), the stand-in body with its head'):format(why))
    watchPerspective(view.since, perspectiveState())
end

--- Lets the view go back to the player's own choice.
-- @param why string
function W.ReleaseView(why)
    orbitOff(why)
    if view == nil then return end
    local perspective = Open77.perspective
    if type(perspective) == 'table' and type(perspective.clearThirdPersonOverride) == 'function' then
        pcall(perspective.clearThirdPersonOverride)
    end
    Open77.log.info(('exit view: released after %.1fs (%s)'):format((M.Now() - view.since) / 1000.0, why))
    view = nil
end

-- ── the plan ─────────────────────────────────────────────────────────────────

--- The hull a plan was made on, as the ask carries it: `{ x, y, z, yaw }`.
local function poseOf(frame)
    if frame == nil then return nil end
    return { x = frame.x, y = frame.y, z = frame.z,
        yaw = (frame.fx ~= nil and frame.fy ~= nil) and (math.deg(math.atan(-frame.fx, frame.fy)) % 360.0) or nil }
end

--- A walk-out planned on one frame of the hull, or nil and why.
-- @param was table `{ vehicleId, seat, record }`
-- @param frame table the hull: `{ x, y, z, fx, fy, bounds?, boundsLocal? }`
-- @param exit table `M.ExitSettings()`
-- @param groundBelow function(x, y, fromZ) -> z|nil
-- @param settings table `M.WalkOutSettings()`
-- @param clip string
-- @param knownWidth number|nil the door's distance already measured for this exit
-- @return table|nil `{ x, y, z, yaw, door, reach, width, source, ground, height, spec }`
-- @return string|nil why not
local function planOn(was, frame, exit, groundBelow, settings, clip, knownWidth, turn)
    -- THE DOOR: a known airframe's own (`AIRFRAMES`: its side, how far out its
    -- face is, where along the hull), else the seat's side, the hull's half
    -- width from its mesh box turned by its heading, then `DOOR_METRES`.
    local door = M.SeatDoor(was.record, was.seat)
    local width, source = door.out, nil
    if width ~= nil then
        source = ('the %s\'s door, %s'):format(door.airframe or 'airframe', door.side > 0 and 'left' or 'right')
    elseif knownWidth ~= nil then
        width, source = knownWidth, 'the width measured at the exit'
    else
        -- In the hull's own frame the half width is read off the box; a world
        -- box needs the heading, and fails near a diagonal.
        local measured = frame.boundsLocal and M.LocalHalfWidth(frame.bounds)
            or M.HullHalfWidth(frame.bounds, { x = frame.fx, y = frame.fy })
        if measured ~= nil then
            width = math.max(settings.doorMin, math.min(settings.doorMax, measured + settings.doorMargin))
            source = ('the hull\'s bounds: %.2f m half width'):format(measured)
        else
            width = settings.door
            source = frame.bounds ~= nil and 'DOOR_METRES (the hull stands near a diagonal)' or 'DOOR_METRES'
        end
    end
    local p = M.WalkOutPlan(frame, { x = frame.fx, y = frame.fy }, was.seat, exit, clip, width, door, turn)
    if p == nil then return nil, 'its frame could not be read' end
    local ground = groundBelow(p.x, p.y, frame.z + 2.0)
    local _, airborne, height = M.ExitLevel(frame.z, ground, exit)
    if ground == nil then return nil, ('no ground at the end point (%.1f, %.1f)'):format(p.x, p.y) end
    if airborne then return nil, ('the hull is %.1f m up at the end point (%.1f, %.1f)'):format(height or 0, p.x, p.y) end
    -- THE CLIP ENDS STANDING ON THE GROUND: the body goes `LIFT_METRES` over
    -- it, not the plain exit's lift -- a body put 25 cm up and held still for
    -- the clip ended it in the air and dropped (Staging, 2026-10-27).
    return { x = p.x, y = p.y, z = ground + settings.lift, yaw = p.yaw, door = p.door, reach = p.reach,
        width = width, source = source, ground = ground, height = height, spec = door, turn = p.turn or 0.0 }
end

-- The boarding step plans its first spot the same way (client/enter.lua).
W.PlanOn = planOn

--- The walk-out for a seat that is being left, or nil (and why, in the log).
-- @param was table the seat as `watchSeat` last read it: `{ vehicleId, seat, record }`
-- @param frame table the hull: `{ x, y, z, fx, fy, bounds? }`
-- @param exit table `M.ExitSettings()`
-- @param groundBelow function(x, y, fromZ) -> z|nil
-- @return table|nil `{ target = { x, y, z, ground, airborne, height, attempt }, yaw, clip }`
function W.Plan(was, frame, exit, groundBelow)
    walk = nil
    local settings = anim()
    if settings.off then return nil end
    if style == nil or style.ok ~= true then
        Open77.log.info(('exit clip: none -- %s; the plain exit'):format(style == nil
            and 'the server gave this player no exit style' or ('no exit style: ' .. tostring(style.reason))))
        return nil
    end
    -- A GAME WITHOUT THE CLIPS (1.7.2): the server's style is no use when this
    -- game cannot draw them (open77_avexit's package not registered here) -- no
    -- hold, no wait for a step nobody sees.
    if M.AnimMissing ~= nil then
        local missing, reason = M.AnimMissing()
        if missing then
            if M.FilesMissingNotice ~= nil then M.FilesMissingNotice('an exit', reason) end
            Open77.log.info(('exit clip: none -- this game has no AV animation package (%s): its archive is not in '
                .. 'the game it started with; the plain exit'):format(tostring(reason)))
            return nil
        end
    end
    local clip = M.WalkOutClip(was.record, was.seat, settings)
    local p, why = planOn(was, frame, exit, groundBelow, settings, clip)
    if p == nil then
        Open77.log.info(('exit clip: none -- %s; the plain exit'):format(why))
        return nil
    end
    -- THE DOOR AS THIS GAME DRAWS IT: a door slot on the hull's other side is a
    -- frame that faces the other way from the hull drawn here -- planned again
    -- on it turned round (the drawn door is the one every clip must start on).
    -- In the next resume (the host's budget, `M.Breathe`), and judged against
    -- the hull read again THEN: a slot read frames after the hull was is not
    -- judged against where the hull was (it may have been dragged meanwhile).
    listSlots(was.vehicleId, was.record)
    M.Breathe()
    if M.ExitFrameNow ~= nil then
        local fresh, freshSource = M.ExitFrameNow(was.vehicleId)
        if fresh ~= nil then
            fresh.source = freshSource
            local q = planOn(was, fresh, exit, groundBelow, settings, clip)
            if q ~= nil then frame, p = fresh, q end
        end
    end
    local slot, slotWhy = doorSlot(was.vehicleId, was.record, frame)
    local turned = false
    if slot ~= nil and slot.verdict == 'mirrored' and frame.source ~= 'network' then
        local q = planOn(was, M.TurnedFrame(frame), exit, groundBelow, settings, clip)
        if q ~= nil then
            Open77.log.warn(('exit clip %s: this game draws the AV\'s door on the other side of the hull from the frame '
                .. 'the exit was planned on (slot %s at %.2f across, %.2f along): the hull is drawn facing the other '
                .. 'way, and the step is planned on it turned round'):format(clip, slot.name, slot.at.x, slot.at.y))
            p, turned = q, true
            slot = doorSlot(was.vehicleId, was.record, M.TurnedFrame(frame)) or slot
        end
    end
    walk = { id = was.vehicleId, seat = was.seat, clip = clip, yaw = p.yaw, door = p.door,
        target = { x = p.x, y = p.y, z = p.z, attempt = 1, airborne = false, height = p.height, ground = p.ground },
        planAt = M.Now(), was = { vehicleId = was.vehicleId, seat = was.seat, record = was.record },
        frame = poseOf(turned and M.TurnedFrame(frame) or frame), width = p.width, source = p.source, replaced = 0,
        turnFrame = turned, slot = slot,
        -- The heading: the placement turns the body to the step's, so a look
        -- that finds it elsewhere is a turn something else made.
        lastYaw = p.yaw, turns = 0, facing = { good = 0, back = 0 } }
    Open77.log.info(('exit clip %s planned: door %.2f m out (%s), the body put %.1f m beyond it at %.1f, %.1f, %.1f '
        .. 'facing %.0f deg; the clip starts on the door at %.1f, %.1f')
        :format(clip, p.width, p.source, p.reach, p.x, p.y, p.z, p.yaw, p.door.x, p.door.y))
    if slot ~= nil then
        local line = ('exit clip %s: the AV\'s door as this game draws it -- slot %s at %.2f across, %.2f along, %s up '
            .. 'in the hull\'s frame: %s'):format(clip, slot.name, slot.at.x, slot.at.y,
            slot.at.z ~= nil and ('%.2f'):format(slot.at.z) or '?',
            slot.verdict == 'right' and ('where the plan has it (%.2f m off)'):format(slot.off)
                or (slot.verdict == 'mirrored' and 'on the hull\'s other side'
                    or ('%.2f m from where the plan has it'):format(slot.off)))
        if slot.verdict == 'right' then Open77.log.info(line) else Open77.log.warn(line) end
    elseif M.DoorSlots(was.record) ~= nil then
        once('slot:' .. tostring(slotWhy), 'info', ('exit clip %s: the AV\'s door slot cannot be read here (%s); the '
            .. 'door is the airframe\'s table'):format(clip, tostring(slotWhy)))
    end
    return { target = walk.target, yaw = p.yaw, clip = clip }
end

--- The frame the walk-out is planned on: the hull's, turned round when this
--- game draws the door on its other side (`walk.turnFrame`).
local function framed(frame)
    if walk ~= nil and walk.turnFrame and frame ~= nil then return M.TurnedFrame(frame) end
    return frame
end

-- ── the plan again, before the ask ───────────────────────────────────────────
-- The plan above is made the moment the seat empties -- when the engine may
-- still draw the hull where its flight began, and before the server has set it
-- down on its gear. The clip is asked seconds later: by then the hull stands
-- where every game draws it. So the walk-out is planned again on it, and the
-- body moved to the new end point when that moved (`REPLAN_METRES`); a door
-- whose step hangs over the end point higher than the clip's first step can
-- stand on waits for the hull to come down (measured again once), and plays no
-- clip if it never does (`SETTLE_MS`).

-- A body moved to a new end point has arrived within this, and is waited for
-- at most this long.
local ARRIVE_METRES = 0.3
local PLACE_MS = 1500
-- A plan that turned more than this is moved to, whatever its distance.
local REPLAN_DEGREES = 6.0
-- At most this many moves to a new end point an exit.
local MAX_REPLACES = 3
-- THE PLAN AGAIN, EARLY: as soon as the hull's frame is steady after the exit
-- (the engine's and the network's agree, twice in a row, `STEADY_METRES`),
-- between `EARLY_FROM_MS` and `EARLY_UNTIL_MS` -- before the client's own exit
-- camera comes (about 1.5 s) and, 1.2 s later, arms its "first move" rule
-- (`vflt-exit-tpp-off`: third person off on the body's first move faster than
-- 0.4 m/s), which a body moved later might trip.
local EARLY_FROM_MS = 600
local EARLY_UNTIL_MS = 2400
local STEADY_METRES = 0.15
-- A body moved once third person was drawn may have thrown the view: the clip
-- waits this long at most for the stand-in to be drawn again (the arbiter's
-- twelve clean frames and the reveal: about 2.5 s at 60 frames a second, 6 s
-- at 4).
local VIEW_BACK_MS = 6000

local function apart(a, b)
    local dx, dy = a.x - b.x, a.y - b.y
    return math.sqrt(dx * dx + dy * dy)
end

local function turnOf(a, b)
    if a == nil or b == nil then return 0 end
    local d = math.abs((a - b) % 360.0)
    return math.min(d, 360.0 - d)
end

--- Moves the body to a plan's end point, for the reason given.
-- @return boolean
local function moveTo(p, frame, why, now)
    if (walk.replaced or 0) >= MAX_REPLACES then return false end
    walk.replaced = (walk.replaced or 0) + 1
    local target = { x = p.x, y = p.y, z = p.z, attempt = 1, airborne = false, height = p.height, ground = p.ground }
    if not moveBody(target, p.yaw, why, frame) then return false end
    walk.target, walk.yaw, walk.door, walk.frame = target, p.yaw, p.door, poseOf(frame)
    walk.placing = { since = now, why = why }
    -- Moved with third person already drawn: the view may be thrown, and is
    -- waited for again (`settle`), inside a window stretched for it.
    if view ~= nil and view.revealed then
        walk.movedLate = true
        walk.viewLostSaid = nil
        local settings = anim()
        if walk.settleFrom ~= nil then
            walk.settleFrom = math.max(walk.settleFrom, now - settings.settle + PLACE_MS + VIEW_BACK_MS)
        end
    end
    return true
end

--- The plan made again EARLY, once the hull's frame is steady after the exit
--- (see `EARLY_FROM_MS`): the body moved while no rule of the client's can
--- take the move for a walk.
-- @param now number
local function early(now)
    local held = now - walk.planAt
    if held < EARLY_FROM_MS then return end
    if held > EARLY_UNTIL_MS or M.ExitFrameNow == nil then
        walk.earlyDone = true
        return
    end
    local frame, source = M.ExitFrameNow(walk.id)
    if frame == nil or source ~= 'engine' then
        walk.earlyLast = nil
        return
    end
    local last = walk.earlyLast
    walk.earlyLast = frame
    if last == nil or apart(last, frame) > STEADY_METRES or (M.FrameTurn(last, frame) or 0) > 2.0 then return end
    walk.earlyDone = true
    local settings = anim()
    local p = planOn(walk.was, framed(frame), M.ExitSettings(), M.ExitGround or function() return nil end, settings,
        walk.clip, walk.width, walk.turn)
    if p == nil then return end
    local moved, turned = apart(p, walk.target), turnOf(p.yaw, walk.yaw)
    if moved <= settings.replan and turned <= REPLAN_DEGREES then return end
    Open77.log.info(('exit clip %s planned again %.1fs after the exit, on the hull as it stands now (%.1f, %.1f, the '
        .. 'engine and the network agreeing): the end point moves %.2f m and turns %.0f deg, to %.1f, %.1f, %.1f; the '
        .. 'clip starts on the door at %.1f, %.1f'):format(walk.clip, held / 1000.0, frame.x, frame.y, moved, turned,
        p.x, p.y, p.z, p.door.x, p.door.y))
    if not moveTo(p, frame, 'the clip planned again early', now) then
        Open77.log.info(('exit clip %s: the body could not be moved now; the plan is made again before the ask')
            :format(walk.clip))
        return
    end
    -- The exit's own measure of the ground under the gear was made on the same
    -- wrong frame: made again on this one, so the hull is set down before the ask.
    if M.ExitMeasure ~= nil and M.AirframeLand(walk.was.record) ~= nil then M.ExitMeasure(walk.was, frame) end
end

--- How far the hull hangs over its gear as this game measures the ground under
--- its feet, or nil (gear not known, a foot over nothing): a hull already on its
--- gear will not come down, and is not waited for.
-- @param frame table the hull
-- @return number|nil metres
-- @return table|nil `M.AirframeLand(record)`
local function hoverOf(frame)
    local land = M.AirframeLand(walk.was.record)
    if land == nil or M.ExitGround == nil then return nil, land end
    -- Read once a pass for a hull where it was: the step foreseen and the final
    -- look may both ask in one pass (a client with no third person to wait for).
    local memo = walk.hoverMemo
    if memo ~= nil and memo.pass == pass and memo.x == frame.x and memo.y == frame.y and memo.z == frame.z
        and memo.fx == frame.fx and memo.fy == frame.fy then
        return memo.hover, land
    end
    local hover = nil
    local feet = M.GearPoints({ x = frame.x, y = frame.y }, { x = frame.fx, y = frame.fy }, land)
    if feet ~= nil then
        local highest = nil
        for _, foot in ipairs(feet) do
            local z = M.ExitGround(foot.x, foot.y, frame.z + 1.0)
            if z == nil then
                highest = nil
                break
            end
            highest = highest == nil and z or math.max(highest, z)
        end
        if highest ~= nil then hover = frame.z - land.height - highest end
    end
    walk.hoverMemo = { pass = pass, x = frame.x, y = frame.y, z = frame.z, fx = frame.fx, fy = frame.fy, hover = hover }
    return hover, land
end

--- What is going on around a turn of the body, for its line in the log.
local function turnContext(now)
    local parts = {}
    local state = perspectiveState()
    if state ~= nil then
        parts[#parts + 1] = ('%s, camera %s'):format(tostring(state.mode), tostring(state.camera))
    end
    if view ~= nil then
        if view.chaseSaid and not view.revealed then parts[#parts + 1] = 'the client\'s chase camera seen' end
        if view.offAt ~= nil then
            parts[#parts + 1] = ('the client\'s exit camera off %.1fs ago'):format((now - view.offAt) / 1000.0)
        end
    end
    if orbiting ~= nil then
        parts[#parts + 1] = ('the camera swung round the body %.1fs ago'):format((now - orbiting.since) / 1000.0)
    end
    parts[#parts + 1] = holdText()
    if walk ~= nil and walk.playing ~= nil then
        parts[#parts + 1] = ('the clip %.1fs in'):format((now - walk.playing.since) / 1000.0)
    elseif walk ~= nil and walk.asked then
        parts[#parts + 1] = 'the clip asked'
    end
    return table.concat(parts, '; ')
end

--- THE BODY'S HEADING, every look from the placement to the clip's end: a turn
--- that this half did not make is a line, with what was going on.
-- @param now number
-- @return number|nil the heading read
local function watchTurn(now)
    if walk == nil or walk.yaw == nil then return nil end
    -- A move made in this same pass (a turn back among them) is applied on the
    -- next frame: the heading read now is the one before it (Staging,
    -- 2026-10-28, 04:39:23.483: "did not hold", 0.0 s after the turn back).
    if walk.body ~= nil and walk.body.movedPass == pass then return nil end
    local yaw = bodyYaw()
    if yaw == nil then return nil end
    local last = walk.lastYaw
    walk.lastYaw = yaw
    if last == nil then return yaw end
    local turned = M.YawApart(yaw, last) or 0
    -- A TURN BACK THAT DID NOT HOLD: the body faces where it faced before it
    -- was turned back (the heading was not applied, or the same thing turned
    -- it again) -- said as such, not as a new turn.
    local back = walk.facedBack
    if back ~= nil and (turned >= TURN_SAY_DEGREES or now - back.at > SWING_TURN_MS) then walk.facedBack = nil end
    if back ~= nil and turned >= TURN_SAY_DEGREES and (M.YawApart(yaw, back.from) or 999) < TURN_SAY_DEGREES then
        walk.backMissed = (walk.backMissed or 0) + 1
        Open77.log.warn(('exit clip %s: the turn back to %.0f deg did not hold -- the body faces %.0f again %.1fs later '
            .. '(the heading was not applied, or the same thing turned it again; %s)'):format(walk.clip, walk.yaw, yaw,
            (now - back.at) / 1000.0, turnContext(now)))
        return yaw
    end
    if turned < TURN_SAY_DEGREES then return yaw end
    walk.turns = (walk.turns or 0) + 1
    -- A swing round the body that turns it along: the turn is the swing's.
    if swungBody(now, yaw) then swingLetGo(yaw) end
    if walk.turns <= TURN_LINES then
        Open77.log.info(('exit clip %s: the body turned %.0f deg, from %.0f to %.0f -- %.0f deg off the step\'s %.0f -- '
            .. '%.1fs after the seat was left (%s)'):format(walk.clip, turned, last, yaw, M.YawApart(yaw, walk.yaw) or 0,
            walk.yaw, (now - walk.planAt) / 1000.0, turnContext(now)))
    end
    return yaw
end

--- The body turned back to the step's heading, where it stands.
-- @return boolean
local function faceBack(why)
    if M.ExitRetarget == nil or walk == nil then return false end
    -- On the end point; at the height the body stands at when it is there (a
    -- body put back 3 cm up would have to come down to the ground again).
    local here = position()
    local z = walk.target.z
    if here ~= nil and apart(here, walk.target) <= ARRIVE_METRES and math.abs(here.z - walk.target.z) < 0.5 then
        z = here.z
    end
    local at = { x = walk.target.x, y = walk.target.y, z = z, ground = walk.target.ground, attempt = 1,
        airborne = false, height = walk.target.height }
    local from = bodyYaw()
    if not moveBody(at, walk.yaw, why, nil) then return false end
    walk.lastYaw = walk.yaw
    walk.facedBack = from ~= nil and { from = from, at = M.Now() } or nil
    return true
end

--- THE STEP'S HEADING, before the ask: the body faces the way the plan turned
--- it, for two looks in a row, or it is turned back (`FACING_TRIES` times) --
--- a move, so under the curtain (`canMove` false) the answer is 'lift'.
-- @param now number
-- @param canMove boolean|nil
-- @return string 'ready' | 'wait' | 'abandon' | 'lift'
-- @return string|nil why, for an abandon or a lift
local function facingReady(now, canMove)
    local settings = anim()
    local f = walk.facing
    if walk.body ~= nil and walk.body.movedPass == pass then return 'wait' end
    -- A SWING JUST LET GO OF for turning the body: a body whose heading follows
    -- the camera comes back with it -- looked at a few passes before it is
    -- turned back by a move.
    if orbitTurnsBody ~= nil and orbitTurnsBody.pass ~= nil and pass - orbitTurnsBody.pass < MOVE_SETTLE_LOOKS then
        f.good = 0
        return 'wait'
    end
    local yaw = watchTurn(now) or bodyYaw()
    -- `FACING_TRIES = 0`: never turned back -- the heading is only read and said.
    if settings.facingTries == 0 then
        if yaw ~= nil then f.yaw, f.off = yaw, M.YawApart(yaw, walk.yaw) end
        return 'ready'
    end
    if yaw == nil then
        once('facing:read', 'info', 'exit clip: the body\'s heading cannot be read on this client: the clip is asked '
            .. 'as planned')
        return 'ready'
    end
    local off = M.YawApart(yaw, walk.yaw) or 0
    if off <= settings.facing then
        f.good = f.good + 1
        if f.good < 2 then return 'wait' end
        if f.back > 0 and not f.heldSaid then
            f.heldSaid = true
            Open77.log.info(('exit clip %s: the body holds the step\'s heading now (%.0f deg, %.1f off) after %d turn(s) '
                .. 'back'):format(walk.clip, yaw, off, f.back))
        end
        f.yaw, f.off = yaw, off
        return 'ready'
    end
    f.good = 0
    if f.back >= settings.facingTries then
        return 'abandon', ('the body would not hold the step\'s heading: it faces %.0f deg, %.0f deg off the step\'s '
            .. '%.0f, after %d turn(s) back -- the clip would start %.1f m from the door'):format(yaw, off, walk.yaw,
            f.back, M.StartOffDoor(walk.target, yaw, walk.clip, walk.door) or 0)
    end
    if canMove == false then
        return 'lift', ('the body faces %.0f deg, %.0f deg off the step\'s %.0f (%s): it is to be turned back'):format(yaw,
            off, walk.yaw, turnContext(now))
    end
    f.back = f.back + 1
    Open77.log.info(('exit clip %s: the body faces %.0f deg, %.0f deg off the step\'s %.0f -- the clip would start %.1f '
        .. 'm from the door: turned back (%d of %d; %s)'):format(walk.clip, yaw, off, walk.yaw,
        M.StartOffDoor(walk.target, yaw, walk.clip, walk.door) or 0, f.back, settings.facingTries, turnContext(now)))
    if not faceBack('turned back to the step\'s heading') then
        return 'abandon', 'the body could not be turned back to the step\'s heading'
    end
    return 'wait'
end

--- ON ITS FEET, before the ask (1.6.0): the platform draws no clip on a body
--- its game has off the ground, on any screen. With the image on (nothing of
--- the native fade holding it) a body put beside the door lands there: it must
--- stand `STAND_LOOKS` looks, then it is held (`holdReady`), and it must stand,
--- held, `HOLD_CHECK_LOOKS` looks more. A body that has not stood
--- `GROUND_WAIT_MS` (and `GROUND_WAIT_LOOKS`) after it was put there is put
--- `NUDGE_METRES` over the ground under it once and waited for as long again;
--- then no clip -- the body is shown where it is. Under the curtain
--- (`canMove` false) a body off the ground would stay so: the answer is 'lift'.
-- @param now number
-- @param canMove boolean|nil
-- @return string 'ready' | 'wait' | 'abandon' | 'lift'
-- @return string|nil why, for an abandon or a lift
local function groundReady(now, canMove)
    local settings = anim()
    local b = walk.body
    if b == nil or b.last == nil then
        -- Nothing read yet (no state on this client: taken as standing).
        if bodyState() == nil then return 'ready' end
        return 'wait'
    end
    local h = walk.hold
    local holding = settings.freeze and wayOfHold() ~= 'none' and not (h ~= nil and h.refused)
    if b.good >= STAND_LOOKS then
        if b.waitFrom ~= nil and not b.backSaid then
            b.backSaid = true
            Open77.log.info(('exit clip %s: the body stands on the ground now, %.1fs into the wait (%s)')
                :format(walk.clip, (now - b.waitFrom) / 1000.0, holdText()))
        end
        b.waitFrom, b.waitLooks = nil, nil
        if not holding then return 'ready' end
        -- THE HOLD, now that it stands (and faces the step: `holdReady`); believed
        -- once it stands, held, `HOLD_CHECK_LOOKS` looks.
        holdBody(settings.viewWaitMax + settings.settle + 2 * settings.answer + 500, 'the body stands beside the door')
        if frozen == nil then return 'wait' end
        h = walk.hold
        if h == nil or not h.held then return 'wait' end
        return 'ready'
    end
    -- NOT STANDING. Held (a hold that may have taken it off the ground, or a
    -- look of its game's): `watchBody` judges it; waited for.
    if frozen ~= nil then return 'wait' end
    if canMove == false then
        return 'lift', ('the body is %s (%s): under the curtain the native fade would hold it there'):format(
            bodyLine(b.last), screenWord() or 'the screen not read')
    end
    if b.waitFrom == nil then
        b.waitFrom, b.waitLooks = now, 0
        Open77.log.info(('exit clip %s waits for the body to stand beside the door (%s%s; %s): %.1fs and %d looks, '
            .. 'then put %.2f m over the ground under it once and waited for as long again'):format(walk.clip,
            bodyLine(b.last), bodyNumbers(b.last), screenWord() or 'the screen not read', settings.groundWait / 1000.0,
            settings.groundWaitLooks, NUDGE_METRES))
    end
    b.waitLooks = (b.waitLooks or 0) + 1
    if now - b.waitFrom < settings.groundWait or b.waitLooks < settings.groundWaitLooks then return 'wait' end
    -- ONCE: put just over the ground under it, to land on it.
    if not b.nudged then
        b.nudged = true
        local here = position()
        local ground = here ~= nil and M.ExitGround ~= nil and M.ExitGround(here.x, here.y, here.z + 1.0) or nil
        if here ~= nil and ground ~= nil and math.abs(here.z - ground) < 1.5 then
            Open77.log.info(('exit clip %s: the body does not stand after %.1fs (%s%s; %s): put %.2f m over the ground '
                .. 'under it, to land on it'):format(walk.clip, (now - b.waitFrom) / 1000.0, bodyLine(b.last),
                bodyNumbers(b.last), screenWord() or 'the screen not read', NUDGE_METRES))
            local at = { x = here.x, y = here.y, z = ground + NUDGE_METRES, ground = ground, attempt = 1,
                airborne = false, height = walk.target.height }
            if moveBody(at, walk.yaw, 'put just over the ground, to land on it', nil) then
                walk.lastYaw = walk.yaw
                b.waitFrom, b.waitLooks = now, 0
                return 'wait'
            end
        end
    end
    return 'abandon', ('the body never stood on the ground (%s%s, %.1fs; %s; %s): the platform draws no clip on a '
        .. 'body its game has in the air'):format(bodyLine(b.last), bodyNumbers(b.last), (now - b.waitFrom) / 1000.0,
        holdText(), screenWord() or 'the screen not read')
end

--- The worse of two step fits (`M.StepFit`): 'in' < 'relaxed' < past it.
-- @return string|nil
local function worstFit(clip, a, b)
    local lo, hi = M.StepBand(clip)
    if lo == nil or a == nil or b == nil then return nil end
    if a >= lo and a <= hi and b >= lo and b <= hi then return 'in' end
    local fa, fb = M.StepFit(clip, a), M.StepFit(clip, b)
    if fa == nil or fb == nil then return nil end
    local rank = { ['in'] = 1, relaxed = 2, high = 3, low = 3 }
    return rank[fa] >= rank[fb] and fa or fb
end

--- THE STEP ON A SLOPE (1.6.2): the step turned about the door (`STEP_TURNS`,
--- the clip still starting on it) that brings the door's step into the clip's
--- band -- the smallest turn -- else into the relaxed band (the heading itself
--- first), as this screen and the network's hull have it, `drop` metres taken
--- off for a set-down still to come. Nil when no turn does. The search stops
--- at the first turn within the clip's band (the turns go out from the
--- heading), and the plan already made on the present turn (`known`) is not
--- made again: each turn is a plan and a read of the ground, and the host
--- counts every instruction of the pass.
-- @param frame table the hull
-- @param net table|nil where the network has it
-- @param drop number
-- @param known table|nil `{ turn, plan, here, there }` the plan on the present turn
-- @return table|nil `{ turn, fit, here, there, plan }`
local function bestStep(frame, net, drop, known)
    local settings = anim()
    local best, bestRank = nil, nil
    for _, turn in ipairs(M.STEP_TURNS) do
        local q, h, t = nil, nil, nil
        if known ~= nil and known.turn == turn then
            q, h, t = known.plan, known.here, known.there
        else
            q = planOn(walk.was, framed(frame), M.ExitSettings(), M.ExitGround or function() return nil end, settings,
                walk.clip, walk.width, turn)
            if q ~= nil then
                h = M.StepHeight(frame.z, q.spec, q.ground)
                t = net ~= nil and M.StepHeight(net.z, q.spec, q.ground) or h
            end
        end
        if q ~= nil and h ~= nil and t ~= nil then
            h, t = h - drop, t - drop
            local fit = worstFit(walk.clip, h, t)
            local rank = (fit == 'in' and 1) or (fit == 'relaxed' and 2) or nil
            if rank ~= nil and (bestRank == nil or rank < bestRank) then
                best, bestRank = { turn = turn, fit = fit, here = h, there = t, plan = q }, rank
                if rank == 1 then break end
            end
        end
    end
    return best
end

-- A step is turned at most this many times an exit.
local MAX_STEP_TURNS = 2

--- The plan made again on the hull as it stands now, and the body's own
--- checks (its heading, the ground, the hold). `stage` 'prepare' (the image on,
--- `canMove` true): every move it needs is made -- a body walked off its end
--- point, an end point that moved, a door drawn on the hull's other side, a
--- heading turned back -- and the door's step is not waited for (it is under
--- the curtain). `stage` 'final' (under the curtain, `canMove` false): nothing
--- is moved -- a move it needs is answered 'lift' -- and a door's step higher
--- than the clip's first step can stand on is waited for (`SETTLE_MS`).
-- @param now number
-- @param canMove boolean
-- @param stage string 'prepare' | 'final'
-- @return string 'ready' | 'wait' | 'abandon' | 'lift'
-- @return string|nil why, for an abandon or a lift
local function settle(now, canMove, stage)
    local settings = anim()
    -- The window for the hull to come down and the view to come back after a
    -- move opens with the final look (under the curtain).
    if stage == 'final' and walk.settleFrom == nil then walk.settleFrom = now end
    local over = walk.settleFrom ~= nil and now - walk.settleFrom >= settings.settle
    -- A BODY THE EXIT GUARD IS STILL PUTTING BESIDE THE DOOR (client/main.lua):
    -- its teleport lands on a later frame, and the body is judged once it has
    -- (1.6.1: from the pad an exit's drag left it at, 15.5 m off, it was taken
    -- for a body moved elsewhere, Staging, 2026-10-28, 13:20:43).
    if M.GuardPlacing ~= nil and M.GuardPlacing() then return 'wait' end
    -- A BODY ON ITS WAY to a new end point is waited for.
    if walk.placing ~= nil then
        local at = position()
        if at ~= nil and apart(at, walk.target) <= ARRIVE_METRES then
            Open77.log.info(('exit clip %s: the body stands at the new end point %.1fs after it was moved (%s)')
                :format(walk.clip, (now - walk.placing.since) / 1000.0, walk.placing.why))
            walk.placing = nil
        elseif over or now - walk.placing.since >= PLACE_MS then
            return 'abandon', ('the body did not reach the clip\'s new end point in %.1fs (%s from it)')
                :format((now - walk.placing.since) / 1000.0, at ~= nil and ('%.1f m'):format(apart(at, walk.target)) or '?')
        else
            return 'wait'
        end
    end
    -- A BODY MOVED ONCE THIRD PERSON WAS DRAWN may have thrown the view (the
    -- client's "first move" rule): the stand-in is waited for again.
    if walk.movedLate and view ~= nil and stage == 'final' then
        local state = perspectiveState()
        if state ~= nil and not thirdPersonShown(state) and not over then
            if not walk.viewLostSaid then
                walk.viewLostSaid = true
                Open77.log.info(('exit clip %s: the view left third person when the body was moved (%s, %s): the clip '
                    .. 'waits for the stand-in again'):format(walk.clip, tostring(state.mode), tostring(state.reason)))
            end
            return 'wait'
        end
        if walk.viewLostSaid then
            if state == nil or thirdPersonShown(state) then
                Open77.log.info(('exit clip %s: third person is back after the move'):format(walk.clip))
            else
                Open77.log.warn(('exit clip %s: third person did not come back after the move in time (%s, %s): the '
                    .. 'clip plays for the others; this screen shows its own view'):format(walk.clip,
                    tostring(state.mode), tostring(state.reason)))
            end
        end
        walk.movedLate = false
    end
    -- A BODY THAT WALKED OFF THE END POINT (keys pressed before it was held, or
    -- a client with no hold): put back on it, at most three times.
    if walk.placing == nil and (walk.putBacks or 0) < 3 then
        local here = position()
        local off = here ~= nil and apart(here, walk.target) or 0
        -- A body down, or far away -- a server's move, a respawn -- was not
        -- walked off: the clip is given up, and the body left where it is.
        local character = Open77.character
        if type(character) == 'table' and type(character.isAlive) == 'function' then
            local read, alive = pcall(character.isAlive)
            if read and alive == false then return 'abandon', 'the body is down' end
        end
        if off > M.ExitSettings().near then
            return 'abandon', ('the body was moved elsewhere (%.1f m from the end point)'):format(off)
        end
        if off > ARRIVE_METRES then
            if not canMove then
                return 'lift', ('the body stands %.2f m from the end point: it is to be put back on it'):format(off)
            end
            walk.putBacks = (walk.putBacks or 0) + 1
            Open77.log.info(('exit clip %s: the body stands %.2f m from the end point: put back on it (%d of 3)')
                :format(walk.clip, off, walk.putBacks))
            local target = { x = walk.target.x, y = walk.target.y, z = walk.target.z, ground = walk.target.ground,
                attempt = 1, airborne = false, height = walk.target.height }
            if moveBody(target, walk.yaw, 'put back on the end point', nil) then
                walk.lastYaw = walk.yaw
                walk.placing = { since = now, why = 'put back on the end point' }
                -- Moved with third person already drawn: the view may be thrown,
                -- and is waited for again (as for any move, `moveTo`).
                if view ~= nil and view.revealed then
                    walk.movedLate = true
                    walk.viewLostSaid = nil
                end
                return 'wait'
            end
        end
    end
    -- The body's own checks, whatever the hull: its heading, then the ground.
    local function bodyReady()
        local facing, facingWhy = facingReady(now, canMove)
        if facing ~= 'ready' then return facing, facingWhy end
        return groundReady(now, canMove)
    end
    local frame, source, engine, net = nil, nil, nil, nil
    if walk.serverFrame ~= nil then
        -- The server said where its hull is: that pose, and nothing read here.
        frame, source = walk.serverFrame, 'server'
    elseif M.ExitFrameNow ~= nil then
        frame, source, engine, net = M.ExitFrameNow(walk.id)
    else
        return bodyReady()
    end
    if frame == nil then
        once('settle:frame', 'info', 'exit clip: the hull cannot be read before the ask; the plan made at the exit stands')
        return bodyReady()
    end
    local p, why = planOn(walk.was, framed(frame), M.ExitSettings(), M.ExitGround or function() return nil end,
        settings, walk.clip, walk.width, walk.turn)
    if p == nil then return 'abandon', ('planned again on the hull as it stands: %s'):format(why) end
    -- THE STEP: the door's, over the end point, on this screen and on the
    -- network's hull (every other screen's) -- waited for under the curtain.
    local lo, hi = M.StepBand(walk.clip)
    local here = M.StepHeight(frame.z, p.spec, p.ground)
    local there = net ~= nil and M.StepHeight(net.z, p.spec, p.ground) or here
    -- THE STEP ON A SLOPE, FORESEEN (1.6.2): while the step is prepared (the
    -- image on, the hull's frame steady), a step that will not be within the
    -- clip's band once the hull is on its gear -- the set-down still to come
    -- taken off -- is turned about the door; the body is moved to the new end
    -- point with the image on. The search has a pass of its own (the host
    -- counts every instruction of a pass: each turn tried is a plan and a read
    -- of the ground), the rest of the look the next. A step within the band as
    -- the hull stands (most exits) costs no read of the gear: a set-down only
    -- lowers it.
    if stage == 'prepare' and (walk.earlyDone or now - walk.planAt >= CURTAIN_EARLY_WAIT_MS) and lo ~= nil
        and here ~= nil and there ~= nil and not walk.stepForeseen and (walk.stepTurns or 0) < MAX_STEP_TURNS then
        walk.stepForeseen = true
        if worstFit(walk.clip, here, there) ~= 'in' then
            local hover, land = hoverOf(frame)
            local drop = (hover ~= nil and hover >= 0.05 and (land == nil or hover <= land.maxDrop + 0.05)) and hover
                or 0.0
            local fit = worstFit(walk.clip, here - drop, there - drop)
            local turnNow = walk.turn or 0.0
            if fit ~= nil and fit ~= 'in' then
                local best = bestStep(frame, net, drop, { turn = turnNow, plan = p, here = here, there = there })
                if best ~= nil and best.turn ~= turnNow then
                    walk.turn, walk.stepTurns, walk.turnMove = best.turn, (walk.stepTurns or 0) + 1, true
                    Open77.log.info(('exit clip %s: the door\'s step would stand %.2f m over the end point once the '
                        .. 'hull is on its gear (%.2f m where the network has it), past the clip\'s %.2f to %.2f m: the '
                        .. 'step is turned %+.0f deg about the door, where it stands %.2f m up (%s)'):format(walk.clip,
                        here - drop, there - drop, lo, hi, best.turn, best.here, best.fit == 'in'
                            and 'within the clip\'s reach' or 'within the relaxed reach'))
                end
                -- A search on the hull as it stands (no set-down to come) is not
                -- made again under the curtain for the same turn.
                if drop == 0.0 and (best == nil or best.turn == turnNow) then walk.stepSearched = turnNow end
                return 'wait'
            end
        end
    end
    if stage == 'final' and lo ~= nil and here ~= nil and there ~= nil then
        local high = here > hi or there > hi
        local low = here < lo or there < lo
        if high or low then
            -- A hull that hangs over its gear may still be set down (server/land.lua);
            -- one already on it, or too far over it to be lowered, will not be.
            local hover, land = hoverOf(frame)
            local lowerable = hover == nil or (hover >= 0.05 and (land == nil or hover <= land.maxDrop + 0.05))
            if high and not low and not over and lowerable then
                if not walk.remeasured then
                    walk.remeasured = true
                    if M.ExitMeasure ~= nil then M.ExitMeasure(walk.was, frame) end
                end
                if not walk.hoverSaid then
                    walk.hoverSaid = true
                    Open77.log.info(('exit clip %s waits for the hull to stand on its gear: the door\'s step is %.2f m '
                        .. 'over the end point here (%.2f m where the network has the hull), the clip\'s first step '
                        .. 'stands %.2f to %.2f m up, the hull %s over its gear; %.1fs at most'):format(walk.clip, here,
                        there, lo, hi, hover ~= nil and ('%.2f m'):format(hover) or 'an unknown height',
                        math.max(0, settings.settle - (now - walk.settleFrom)) / 1000.0))
                end
                return 'wait'
            end
            -- THE STEP TURNED, OR RELAXED (1.6.2): a turn about the door that brings
            -- the step within reach is moved to -- with the image on: the curtain
            -- is lifted for it -- else a step within the relaxed band is played.
            -- Searched once a turn; a search that finds nothing better is judged
            -- on the next pass (the search and the verdict in two passes: the
            -- host's budget).
            local turnNow = walk.turn or 0.0
            if walk.stepSearched ~= turnNow and (walk.stepTurns or 0) < MAX_STEP_TURNS then
                walk.stepSearched = turnNow
                local best = bestStep(frame, net, 0.0, { turn = turnNow, plan = p, here = here, there = there })
                if best ~= nil and best.turn ~= turnNow then
                    walk.turn, walk.stepTurns, walk.turnMove = best.turn, (walk.stepTurns or 0) + 1, true
                    return 'lift', ('the door\'s step is %.2f m over the end point here (%.2f m where the network has '
                        .. 'the hull), past the clip\'s %.2f to %.2f m: the step is turned %+.0f deg about the door, '
                        .. 'where it stands %.2f m up (%s)'):format(here, there, lo, hi, best.turn, best.here,
                        best.fit == 'in' and 'within the clip\'s reach' or 'within the relaxed reach')
                end
                return 'wait'
            end
            local fit = worstFit(walk.clip, here, there)
            if fit == 'relaxed' then
                if not walk.relaxedSaid then
                    walk.relaxedSaid = true
                    local rlo, rhi = M.StepBand(walk.clip, true)
                    Open77.log.info(('exit clip %s: the door\'s step is %.2f m over the end point here (%.2f m where the '
                        .. 'network has the hull), past the clip\'s %.2f to %.2f m but within the relaxed %.2f to %.2f m: '
                        .. 'the step is played (its first frames a little %s the step, under the fade-in)'):format(
                        walk.clip, here, there, lo, hi, rlo, rhi, high and 'under' or 'over'))
                end
            else
                return 'abandon', ('the door\'s step is %.2f m over the end point here (%.2f m where the network has '
                    .. 'the hull) and the clip\'s first step stands %.2f to %.2f m up: it would %s%s; no turn about the '
                    .. 'door within %.0f deg brings it within reach'):format(here, there,
                    lo, hi, high and 'start in the air beside the door' or 'start sunk in the step',
                    (high and not lowerable) and (hover ~= nil and hover < 0.05
                        and ' (the hull stands on its gear: the ground falls away under the end point)'
                        or ' (the hull is too far over its gear to be set down)') or '', M.STEP_TURN_MAX)
            end
        end
        if walk.hoverSaid and not walk.landedSaid then
            walk.landedSaid = true
            -- A hull the server glides down (1.7.9) brings the step within reach
            -- a moment before it stands: the server holds the clip for the rest.
            local hover = hoverOf(frame)
            if hover ~= nil and hover > 0.05 then
                Open77.log.info(('exit clip %s: the door\'s step within the clip\'s reach now (%.2f m up), the hull '
                    .. '%.2f m over its gear and coming down, %.1fs into the wait'):format(walk.clip, here, hover,
                    (now - walk.settleFrom) / 1000.0))
            else
                Open77.log.info(('exit clip %s: the hull stands on its gear now (the step %.2f m up), %.1fs into the wait')
                    :format(walk.clip, here, (now - walk.settleFrom) / 1000.0))
            end
        end
    end
    -- THE END POINT, on the hull as it stands -- while the step is prepared, only
    -- once the plan on a steady hull has been made (`early`: a frame read in the
    -- engine's drag of the exit's first moments is not one to move the body to).
    -- A step turned about the door (`turnMove`) is moved to whatever the
    -- distance: the server plans on the same turn, and holds the end point to it.
    local moved = apart(p, walk.target)
    local turned = turnOf(p.yaw, walk.yaw)
    if walk.turnMove
        or ((stage == 'final' or walk.earlyDone) and (moved > settings.replan or turned > REPLAN_DEGREES)) then
        local line = ('exit clip %s planned again on %s frame of the hull (%.1f, %.1f%s): the end point moves %.2f m '
            .. 'and turns %.0f deg, to %.1f, %.1f, %.1f; the clip starts on the door at %.1f, %.1f%s')
            :format(walk.clip, source == 'engine' and 'the engine\'s'
                    or (source == 'server' and 'the server\'s' or 'the network\'s'), frame.x, frame.y,
                (engine ~= nil and net ~= nil) and (', the engine %.1f m from the network'):format(apart(engine, net)) or '',
                moved, turned, p.x, p.y, p.z, p.door.x, p.door.y,
                walk.turnMove and (' (the step turned %+.0f deg about the door)'):format(walk.turn or 0.0) or '')
        if not canMove then
            return 'lift', ('the end point moves %.2f m and turns %.0f deg on the hull as it stands'):format(moved, turned)
        end
        Open77.log.info(line)
        if not moveTo(p, frame, walk.turnMove and 'the step turned about the door' or 'the clip planned again', now) then
            return 'abandon', 'the body could not be moved to the clip\'s new end point'
        end
        walk.turnMove = nil
        return 'wait'
    end
    walk.frame, walk.step = poseOf(frame), here
    -- THE DOOR AS THIS GAME DRAWS IT, once more, on the hull the clip is asked
    -- on (the engine's own frame: the slot is read off the same hull).
    if source == 'engine' and not walk.slotAgain then
        local slot = doorSlot(walk.id, walk.was.record, framed(frame))
        if slot ~= nil and slot.verdict == 'mirrored' and not walk.turnFrame then
            -- Drawn on the hull's other side: planned on the frame turned round.
            local q = planOn(walk.was, M.TurnedFrame(frame), M.ExitSettings(),
                M.ExitGround or function() return nil end, settings, walk.clip, walk.width, walk.turn)
            if q ~= nil then
                if not canMove then
                    return 'lift', ('this game draws the AV\'s door on the other side of the hull (slot %s at %.2f '
                        .. 'across): the step is to be planned on the hull turned round'):format(slot.name, slot.at.x)
                end
                walk.slotAgain = true
                walk.slot = slot
                Open77.log.warn(('exit clip %s: this game draws the AV\'s door on the other side of the hull (slot %s '
                    .. 'at %.2f across, %.2f along): the step is planned on the hull turned round'):format(walk.clip,
                    slot.name, slot.at.x, slot.at.y))
                walk.turnFrame = true
                if moveTo(q, frame, 'the door is drawn on the other side', now) then return 'wait' end
                return 'abandon', 'the body could not be moved to the door this game draws'
            end
        end
        walk.slotAgain = true
        if slot ~= nil then
            local was = walk.slot
            walk.slot = slot
            if slot.verdict ~= 'mirrored' and (was == nil or was.verdict ~= slot.verdict) then
                local line = ('exit clip %s: the AV\'s door as this game draws it before the ask -- slot %s at %.2f '
                    .. 'across, %.2f along: %s'):format(walk.clip, slot.name, slot.at.x, slot.at.y,
                    slot.verdict == 'right' and ('where the plan has it (%.2f m off)'):format(slot.off)
                        or ('%.2f m from where the plan has it'):format(slot.off))
                if slot.verdict == 'right' then Open77.log.info(line) else Open77.log.warn(line) end
            end
        end
    end
    -- THE STEP'S HEADING, held for two looks; then ON THE GROUND, held.
    return bodyReady()
end

--- The plan the ask carries, for the server to check against its own hull.
local function planPayload()
    local f = walk.facing or {}
    local slot = walk.slot
    return { hull = walk.frame, at = { x = walk.target.x, y = walk.target.y, z = walk.target.z }, yaw = walk.yaw,
        ground = walk.target.ground, width = walk.width, step = walk.step,
        -- The body's heading as it was read before the ask, and how many times
        -- it had to be turned back; the door as this game draws it.
        facing = f.yaw, facingOff = f.off, turnedBack = f.back,
        turned = walk.turnFrame == true or nil,
        -- The step turned about the door (1.6.2, `STEP_TURNS`), in degrees.
        stepTurn = (walk.turn ~= nil and walk.turn ~= 0) and walk.turn or nil,
        slot = slot ~= nil and { name = slot.name, verdict = slot.verdict, x = slot.at.x, y = slot.at.y, z = slot.at.z,
            off = slot.off ~= math.huge and slot.off or nil } or nil }
end

--- The exit began: the view is held for every exit of an aircraft that is an
--- exit (not a move made elsewhere); a plan the guard could not use is told
--- to the server, which shows the body again.
-- @param was table
-- @param verdict string what `beginGuard` answered
function W.OnExit(was, verdict)
    -- The game's own exit, animated (1.9.0, client/main.lua `beginExit`): its
    -- view and its body are the game's -- nothing is held.
    if verdict ~= 'far' and verdict ~= 'vanilla' then W.HoldView('the seat was left', was.vehicleId) end
    if walk ~= nil and verdict ~= 'guarded' then
        W.Abandon('the exit was not guarded: ' .. tostring(verdict))
    elseif walk == nil and not anim().off then
        -- No clip for this exit (a plain exit, the game's own animated one, or
        -- a move made elsewhere): the server shows the body to the others at once.
        TriggerServerEvent(M.Event.WALKOUT, { id = M.KeyOf(was.vehicleId), clip = false,
            why = verdict == 'far' and 'moved elsewhere'
                or (verdict == 'vanilla' and 'the game\'s own exit, animated' or 'no plan') })
    end
end

--- The exit's clip will not be played: tell the server (it shows the body).
-- @param why string
function W.Abandon(why)
    if walk == nil then return end
    if not walk.asked then
        TriggerServerEvent(M.Event.WALKOUT, { id = M.KeyOf(walk.id), clip = false, why = why })
    end
    Open77.log.info(('exit clip %s abandoned: %s'):format(walk.clip, why))
    walk = nil
    orbitOff('the clip was given up')
    unfreeze('the clip was given up')
    if M.CurtainUp ~= nil then M.CurtainUp('the clip was given up', nil, true) end
end

--- Whether the wait for third person is over without it: `VIEW_WAIT_MS` and
--- `VIEW_WAIT_LOOKS` watch passes since the legacy camera went off (or since
--- the seat was left, when it never came), or `VIEW_WAIT_MAX_MS`.
-- @return boolean
-- @return string|nil why, for the log
local function waitOver(now, settings)
    local held = now - walk.planAt
    if held >= settings.viewWaitMax then return true, ('the ceiling, %.1fs'):format(settings.viewWaitMax / 1000.0) end
    if held < settings.viewWait then return false end
    local looks = view.looks - (view.offLooks or 0)
    if looks < settings.viewWaitLooks then return false end
    return true, ('%d looks after %s'):format(looks, view.offLooks ~= nil and 'the client\'s exit camera went off'
        or 'the seat was left')
end

--- The ask: the server plays the clip for every screen at once and answers.
-- @param now number
local function ask(now)
    walk.asked, walk.askedAt, walk.phase = true, now, 'asked'
    TriggerServerEvent(M.Event.WALKOUT, { id = M.KeyOf(walk.id), clip = walk.clip, seat = walk.seat,
        plan = planPayload() })
    local f = walk.facing or {}
    local curtain = M.Curtain ~= nil and M.Curtain() or nil
    Open77.log.info(('exit clip %s asked of the server %.1fs after the seat was left (end point %.1f, %.1f, %.1f '
        .. 'facing %.0f deg -- the body faces %s; the door\'s step %s over it%s; %s)'):format(walk.clip,
        (now - walk.planAt) / 1000.0, walk.target.x, walk.target.y, walk.target.z, walk.yaw,
        f.yaw ~= nil and ('%.0f, %.1f deg off'):format(f.yaw, f.off or 0) or 'an unread heading',
        walk.step ~= nil and ('%.2f m'):format(walk.step) or 'not known',
        walk.turnFrame and '; planned on the hull turned round, as its door is drawn here' or '',
        curtain ~= nil and ('under the curtain, %.1fs black'):format((now - curtain.since) / 1000.0)
            or 'in view (no curtain)'))
end

--- A step that will not be played: said, and the server shows the body.
local function giveUp(why)
    Open77.log.warn(('exit clip %s: no clip -- %s; the body is shown standing where it is'):format(walk.clip,
        tostring(why)))
    W.Abandon(why)
end

--- THE STEP, one pass at a time (1.6.0), from the plan to the ask: PREPARE with
--- the image on (the body put, landed, facing the step, standing, held -- every
--- move made here), then the CURTAIN down, the VIEW (third person, the swing),
--- the FINAL look (nothing moved: a move it needs lifts the curtain and goes
--- back to PREPARE), and the ASK.
-- @param now number
local function advance(now)
    if walk == nil or walk.asked then return end
    local settings = anim()
    walk.phase = walk.phase or 'prepare'
    if walk.phase == 'prepare' then
        -- THE PLAN AGAIN, EARLY, once the hull's frame is steady after the exit.
        if not walk.earlyDone and walk.placing == nil then
            local ran, failure = pcall(early, now)
            if not ran then
                walk.earlyDone = true
                Open77.log.error('the exit clip\'s early plan failed: ' .. tostring(failure))
            end
            if walk == nil then return end
        end
        local verdict, why = settle(now, true, 'prepare')
        if walk == nil then return end
        if verdict == 'abandon' then return giveUp(why) end
        if verdict ~= 'ready' then return end
        -- The plan on a steady hull first, if it comes soon (`CURTAIN_EARLY_WAIT_MS`).
        if not walk.earlyDone and now - walk.planAt < CURTAIN_EARLY_WAIT_MS then return end
        walk.earlyDone = true
        walk.readyAt = walk.readyAt or now
        local f = walk.facing or {}
        Open77.log.info(('exit clip %s prepared %.1fs after the seat was left: the body stands beside the door (%s), '
            .. 'faces %s (the step\'s %.0f), %s; %s'):format(walk.clip, (now - walk.planAt) / 1000.0,
            bodyLine(walk.body ~= nil and walk.body.last or nil),
            f.yaw ~= nil and ('%.0f deg'):format(f.yaw) or 'an unread heading', walk.yaw, holdText(),
            M.ScreenText ~= nil and M.ScreenText() or 'the screen not read'))
        if M.Shots ~= nil and not walk.readyShot then
            walk.readyShot = true
            M.Shots.Take('ready', 0, W.ShotMeta)
        end
        if M.CurtainDown ~= nil then
            M.CurtainDown(('the step prepared %.1fs after the seat was left'):format((now - walk.planAt) / 1000.0))
        end
        walk.phase = 'view'
    end
    if walk.phase == 'view' then
        -- A BODY TURNED OFF THE STEP'S HEADING under the curtain (the client's
        -- chase camera letting go may turn it to the seat's view: 1.4.0, planned
        -- 75, drawn 245.8) is turned back at once -- a move, so with the image on
        -- -- not after the wait for third person.
        if settings.facingTries > 0 and walk.yaw ~= nil and (walk.body == nil or walk.body.movedPass ~= pass)
            and (orbitTurnsBody == nil or orbitTurnsBody.pass == nil or pass - orbitTurnsBody.pass >= MOVE_SETTLE_LOOKS) then
            local yaw = bodyYaw()
            local off = yaw ~= nil and M.YawApart(yaw, walk.yaw) or nil
            if off ~= nil and off > settings.facing and (orbiting == nil or orbiting.pass ~= pass) then
                walk.lifts = (walk.lifts or 0) + 1
                local curtain = M.Curtain ~= nil and M.Curtain() or nil
                Open77.log.info(('exit clip %s: the body turned to %.0f deg, %.0f deg off the step\'s %.0f, under the '
                    .. 'curtain (%s) -- %s; it is turned back and held again with the image on (%d)'):format(walk.clip,
                    yaw, off, walk.yaw, turnContext(now), curtain ~= nil and 'the curtain comes up first'
                        or 'no curtain is down', walk.lifts))
                if curtain ~= nil and M.CurtainUp ~= nil then
                    M.CurtainUp(('the step prepared again: the body faces %.0f deg'):format(yaw), 0, false)
                end
                if walk.facing ~= nil then walk.facing.good = 0 end
                walk.phase = 'prepare'
                return
            end
        end
        -- THE VIEW FIRST: on this screen the clip plays on the stand-in body,
        -- which only the platform's third person draws -- asked the moment it is.
        if view ~= nil and settings.viewWait > 0 then
            local state = perspectiveState()
            watchPerspective(now, state)
            if not view.revealed then
                local over, why = waitOver(now, settings)
                if not over then
                    if not walk.waiting then
                        walk.waiting = true
                        Open77.log.info(('exit clip %s waits for the platform\'s third person (the stand-in body it '
                            .. 'plays on here): %.1fs at least and %d looks after the client\'s exit camera went off, '
                            .. '%.1fs at most'):format(walk.clip, settings.viewWait / 1000.0, settings.viewWaitLooks,
                            settings.viewWaitMax / 1000.0))
                    end
                    return
                end
                if not walk.notReadySaid then
                    walk.notReadySaid = true
                    Open77.log.warn(('exit clip %s: the platform\'s third person was not ready after %.1fs (%s; %s): '
                        .. 'the clip plays for the others; this screen shows its own view'):format(walk.clip,
                        (now - walk.planAt) / 1000.0, why, tostring(view.perspective or 'no perspective state')))
                end
            else
                if walk.waiting and not walk.readySaid then
                    walk.readySaid = true
                    Open77.log.info(('exit clip %s: third person ready %.1fs after the seat was left%s')
                        :format(walk.clip, (now - walk.planAt) / 1000.0, looksSinceOff()))
                end
                -- THE SHOT, before the image comes back -- tried only while the
                -- stand-in is drawn (a swing refused out of third person is a
                -- try thrown away).
                if thirdPersonShown(state) then
                    orbitOn(now)
                    -- A swing just made may turn the body on the next frame (a rig
                    -- whose body follows its view): the heading is looked at again,
                    -- twice, after it -- never asked in the same pass.
                    if orbiting ~= nil and orbiting.pass == pass then
                        if walk.facing ~= nil then walk.facing.good = 0 end
                        return
                    end
                end
            end
        end
        walk.phase = 'final'
    end
    if walk.phase == 'final' then
        local verdict, why = settle(now, false, 'final')
        if walk == nil then return end
        if verdict == 'wait' then return end
        if verdict == 'abandon' then return giveUp(why) end
        if verdict == 'lift' then
            walk.lifts = (walk.lifts or 0) + 1
            local curtain = M.Curtain ~= nil and M.Curtain() or nil
            Open77.log.info(('exit clip %s: %s -- %s; the step is prepared again with the image on (%d)'):format(
                walk.clip, tostring(why), curtain ~= nil and 'the curtain comes up first (the native fade would hold '
                    .. 'the body still: moved, or off the ground, under it, it would hang there)' or 'no curtain is down',
                walk.lifts))
            if curtain ~= nil and M.CurtainUp ~= nil then
                M.CurtainUp('the step prepared again: ' .. tostring(why), 0, false)
            end
            -- A body it lets go of stands again before it is held again.
            if walk.facing ~= nil then walk.facing.good = 0 end
            walk.phase = 'prepare'
            return
        end
        ask(now)
    end
end

--- Whether the curtain stays down (client/main.lua asks it every pass): while
--- the step is prepared under it and asked, until the server answers -- the
--- answer lifts it with the step's first frame (`W.Answer`).
-- @param now number
-- @return boolean
function W.KeepCurtain(now)
    if walk == nil or walk.answered then return false end
    return walk.phase ~= 'prepare'
end

--- The server's answer to the ask.
-- @param payload table `{ ok, clip, durationMs, reason }`
function W.Answer(payload)
    if type(payload) ~= 'table' then return end
    if walk == nil or not walk.asked or walk.answered then
        Open77.log.info('exit clip: an answer for no ask in flight, ignored')
        return
    end
    local now = M.Now()
    -- THE OTHER SCREENS ARE NOT READY YET (server/sync.lua): the server holds
    -- the step, under this screen's curtain, until every screen near the exit has
    -- the body out of its seat -- at most `waitMs`. Not an answer: the ask
    -- stays in flight, the time it may take stretched to cover the hold, and
    -- the body held still through it.
    if payload.ok ~= true and payload.hold == true then
        local waitMs = math.floor(M.Number(payload.waitMs, 0, 20000, 0))
        walk.holdUntil = math.max(walk.holdUntil or 0, now + waitMs)
        walk.heldAt = walk.heldAt or now
        walk.holdWhy = payload.reason == 'landing' and 'until the hull stood on its gear' or 'for the other screens'
        holdBody(waitMs + anim().answer + 500, 'the server holds the step')
        -- 1.7.9: held for the hull too, while the server glides it down onto its gear.
        Open77.log.info(('exit clip %s: the server holds the step up to %.1fs %s (%s); %s')
            :format(walk.clip, waitMs / 1000.0, payload.reason == 'landing' and 'until the hull stands on its gear'
                    or 'for the other screens', tostring(payload.waitingFor or 'them'),
                (M.Curtain ~= nil and M.Curtain() ~= nil) and 'the curtain stays down' or 'in view'))
        return
    end
    -- THE SERVER'S HULL IS ELSEWHERE: the walk-out is planned once more on the
    -- pose the server holds, the body moved there, and the clip asked again.
    if payload.ok ~= true and payload.replan == true and type(payload.hull) == 'table' and not walk.replanned then
        walk.replanned = true
        local hull = payload.hull
        local x, y, z, yaw = finite(hull.x), finite(hull.y), finite(hull.z), finite(hull.yaw)
        local frame = nil
        if x ~= nil and y ~= nil and z ~= nil and yaw ~= nil then
            local r = math.rad(yaw)
            frame = { x = x, y = y, z = z, fx = -math.sin(r), fy = math.cos(r) }
        end
        local p, why = nil, 'the server sent no pose'
        if frame ~= nil then
            p, why = planOn(walk.was, framed(frame), M.ExitSettings(), M.ExitGround or function() return nil end, anim(),
                walk.clip, walk.width, walk.turn)
        end
        if p ~= nil then
            Open77.log.info(('exit clip %s: the server has the hull at %.1f, %.1f, %.1f heading %.0f (%s): planned '
                .. 'again on it, the end point %.2f m away at %.1f, %.1f'):format(walk.clip, x, y, z, yaw,
                tostring(payload.reason or 'elsewhere'), apart(p, walk.target), p.x, p.y))
            walk.serverFrame = frame
            -- The move lifts the curtain first (client/main.lua, `M.ExitRetarget`):
            -- the step is prepared again with the image on, and asked again.
            if moveTo(p, frame, 'the server\'s hull', now) then
                walk.asked, walk.answered, walk.askedAt, walk.holdUntil = false, false, nil, nil
                walk.phase = 'prepare'
                if walk.facing ~= nil then walk.facing.good = 0 end
                -- Room for the move, not a new wait: the settle's window is
                -- stretched to `PLACE_MS` from now at least, never restarted.
                walk.settleFrom = math.max(walk.settleFrom or now, now - anim().settle + PLACE_MS)
                return
            end
            why = 'the body could not be moved to the server\'s end point'
        end
        Open77.log.info(('exit clip %s: not planned again on the server\'s hull (%s)'):format(walk.clip, tostring(why)))
        walk.answered, walk.ok, walk.reason = true, false, 'replan_failed'
        TriggerServerEvent(M.Event.WALKOUT, { id = M.KeyOf(walk.id), clip = false, why = 'replan failed' })
        orbitOff('the clip could not be planned again')
        unfreeze('the clip could not be planned again')
        if M.CurtainUp ~= nil then M.CurtainUp('the clip could not be planned again', nil, true) end
        return
    end
    walk.answered = true
    walk.ok = payload.ok == true
    if not walk.ok then
        walk.reason = tostring(payload.reason or 'refused')
        Open77.log.info(('exit clip %s refused by the server: %s'):format(walk.clip, walk.reason))
        orbitOff('the server refused the clip')
        unfreeze('the server refused the clip')
        if M.CurtainUp ~= nil then M.CurtainUp('the server refused the clip', nil, true) end
        return
    end
    local ms = math.floor(M.Number(payload.durationMs, 100, 60000, 4300))
    walk.playing = { since = now, untilAt = now + ms + anim().blendOut }
    Open77.log.info(('exit clip %s playing (%.1fs), answered %d ms after the ask%s%s')
        :format(tostring(payload.clip or walk.clip), ms / 1000.0, now - walk.askedAt,
            walk.heldAt ~= nil and (', held %d ms %s'):format(now - walk.heldAt, walk.holdWhy or 'for the other screens')
                or '',
            payload.scene ~= nil and (' (exit %s)'):format(tostring(payload.scene)) or ''))
    holdBody(ms + anim().blendOut, 'the clip plays', true)
    -- THE IMAGE BACK WITH THE STEP'S FIRST FRAME.
    if M.CurtainUp ~= nil then M.CurtainUp('the step begins', nil, true) end
    -- WHAT THE SCREEN SHOWS (client/shots.lua): the step a moment in, half way,
    -- near its end, and just after it.
    if M.Shots ~= nil then
        for _, at in ipairs({ 600, 1600, 2800, 4000, ms + 500 }) do
            M.Shots.Take(('clip+%.1f'):format(at / 1000.0), at, W.ShotMeta)
        end
    end
    -- The heading as the step begins: read again on the next looks (`W.Tick`).
    local yaw = bodyYaw()
    if yaw ~= nil then
        local off = M.YawApart(yaw, walk.yaw) or 0
        local line = ('exit clip %s: the body faces %.0f deg as the step begins, %.1f deg off the step\'s %.0f'):format(
            walk.clip, yaw, off, walk.yaw)
        if off > anim().facing then Open77.log.warn(line) else Open77.log.info(line) end
    end
    -- THE LOGGER (client/sync.lua): this screen reports its own step a moment
    -- into it and as it ends.
    if M.Sync ~= nil and payload.scene ~= nil then
        local ran, failure = pcall(M.Sync.Own, { scene = payload.scene, hull = payload.hull,
            at = type(payload.at) == 'table' and payload.at or walk.target, durationMs = ms, id = walk.id,
            clip = payload.clip or walk.clip, yaw = finite(payload.yaw) or walk.yaw,
            door = type(payload.door) == 'table' and payload.door or walk.door, record = walk.was.record,
            seat = walk.seat, turned = walk.turnFrame == true })
        if not ran then Open77.log.error('the exit report could not be armed: ' .. tostring(failure)) end
    end
end

--- One look, every pass of the client's watch (100 ms): the freeze, the
--- view's release, the end of a clip.
-- @param seat table|nil this pass's seat read
local function tick(seat)
    local now = M.Now()
    -- Each pass is at least a frame long: the wait for the stand-in counts them.
    if view ~= nil then
        view.looks = view.looks + 1
        view.seat = seat
    end
    -- A PLAN NEVER ASKED FOR in all the time every wait may take (`W.Ceiling`):
    -- it is given up, and the server shows the body.
    if walk ~= nil and not walk.asked and now - walk.planAt > W.Ceiling() + 1000 then
        W.Abandon('never asked')
    end
    -- THE BODY ON ITS FEET, every look from the plan to the clip's end: its
    -- state, and the hold put on once it stands (`watchBody`).
    if walk ~= nil then
        local ran, failure = pcall(watchBody, now)
        if not ran then Open77.log.error('the exit body watch failed: ' .. tostring(failure)) end
    end
    -- A BODY ON ITS WAY to a new end point: its arrival, when it comes.
    if walk ~= nil and walk.placing ~= nil then
        local at = position()
        if at ~= nil and apart(at, walk.target) <= ARRIVE_METRES then
            Open77.log.info(('exit clip %s: the body stands at the new end point %.1fs after it was moved (%s)')
                :format(walk.clip, (now - walk.placing.since) / 1000.0, walk.placing.why))
            walk.placing = nil
        end
    end
    -- THE BODY'S HEADING, every look from the placement to the clip's end; and
    -- AS THE CLIP STARTS, turned back when it is off -- the path turns with it.
    if walk ~= nil and walk.placing == nil then
        local ran, yaw = pcall(watchTurn, now)
        if not ran then
            Open77.log.error('the exit clip\'s heading watch failed: ' .. tostring(yaw))
            yaw = nil
        end
        -- While the ask is in flight (the server may hold the step for the
        -- other screens) and as the clip starts.
        local starting = walk ~= nil and walk.playing ~= nil and now - walk.playing.since <= CLIP_FACING_MS
        local inFlight = walk ~= nil and walk.asked and not walk.answered
        if (starting or inFlight) and yaw ~= nil then
            local off = M.YawApart(yaw, walk.yaw) or 0
            -- SAID, NOT TURNED BACK (1.5.3): turning the body back is a move, and a
            -- move takes the body off the ground -- where no screen draws the clip
            -- -- until it is held again, which a clip asked or playing does not wait for.
            if off > 2 * anim().facing and (walk.clipTurns or 0) < CLIP_TURNS and anim().facingTries > 0 then
                walk.clipTurns = (walk.clipTurns or 0) + 1
                Open77.log.warn(('exit clip %s: the body turned off the step\'s heading %s (it faces %.0f deg, %.0f off '
                    .. 'the step\'s %.0f; %s): not turned back -- a move now would take the body off the ground under '
                    .. 'the clip (%d of %d)'):format(walk.clip,
                    starting and ('as the clip started, %.1fs in'):format((now - walk.playing.since) / 1000.0)
                        or 'while the clip was asked', yaw, off, walk.yaw, turnContext(now), walk.clipTurns, CLIP_TURNS))
            end
        end
    end
    -- THE STEP, from the plan to the ask (`advance`): prepared with the image
    -- on, then the curtain, the view, the final look, the ask.
    if walk ~= nil and not walk.asked then
        local ran, failure = pcall(advance, now)
        if not ran then Open77.log.error('the exit clip\'s step failed: ' .. tostring(failure)) end
    end
    -- NO ANSWER FROM THE SERVER in time (stretched by a hold it said it makes for
    -- the other screens): the image comes back without the clip.
    if walk ~= nil and walk.asked and not walk.answered
        and now >= math.max(walk.askedAt or now, walk.holdUntil or 0) + anim().answer then
        Open77.log.warn(('exit clip %s: no answer from the server in %d ms%s; the image comes back without it')
            :format(walk.clip, now - (walk.askedAt or now),
                walk.holdUntil ~= nil and (' (it held the step %s)'):format(walk.holdWhy or 'for the other screens')
                    or ''))
        walk.answered, walk.ok, walk.reason = true, false, 'no answer'
        unfreeze('no answer from the server')
        if M.CurtainUp ~= nil then M.CurtainUp('no answer from the server', nil, true) end
    end
    -- The shot, while the clip plays: a swing the rig refused a moment ago is
    -- tried again.
    if walk ~= nil and walk.playing ~= nil and orbiting == nil and orbitTries > 0
        and thirdPersonShown(perspectiveState()) then
        orbitOn(now)
    end
    if frozen ~= nil then
        if now >= frozen.untilAt then
            unfreeze((walk ~= nil and walk.playing ~= nil or walk == nil) and 'the clip is over' or 'its time ran out')
        elseif now - frozen.assertedAt >= 1000 then
            freeze(frozen.untilAt - now)
        end
    end
    if walk ~= nil and walk.answered and (walk.playing == nil or now >= walk.playing.untilAt) then
        local played = walk.playing ~= nil
        if played then
            Open77.log.info(('exit clip %s over after %.1fs'):format(walk.clip, (now - walk.playing.since) / 1000.0))
        end
        walk = nil
        orbitOff(played and 'the clip is over' or 'no clip')
        -- THE CLIP IS OVER, AND SO IS THE EXIT'S VIEW: the player's own comes
        -- back now, before the client turns its exit camera off on the first
        -- steps -- which a third person still held here fights (Staging,
        -- 2026-10-27, 17:39:21: two seconds of first person, then third again).
        if played and view ~= nil and anim().releaseAfterClip then return W.ReleaseView('the clip is over') end
    end
    if view == nil then return end
    local state = perspectiveState()
    watchPerspective(now, state)
    legacyOff(now, state, seat)
    -- A seat again (a vehicle's camera owns the view now), or the ceiling. The
    -- seat being left -- still reported, leaving or for a moment after -- is not.
    if seat ~= nil and seat.exiting ~= true then
        local same = view.id ~= nil and M.SameHull(seat.vehicleId, view.id)
        if not same or now - view.since >= SEAT_LINGER_MS then return W.ReleaseView('seated again') end
    end
    if now - view.since >= anim().viewMax then return W.ReleaseView('the ceiling') end
    if walk ~= nil or frozen ~= nil then
        view.last, view.lastAt, view.moving = nil, nil, 0
        return
    end
    local at = position()
    if at == nil then return end
    if view.last ~= nil and now > view.lastAt then
        local dx, dy = at.x - view.last.x, at.y - view.last.y
        local speed = math.sqrt(dx * dx + dy * dy) / ((now - view.lastAt) / 1000.0)
        view.moving = speed >= anim().releaseSpeed and view.moving + 1 or 0
        if view.moving >= 2 then
            view.last = at
            return W.ReleaseView(('the player walked off at %.1f m/s'):format(speed))
        end
    end
    view.last, view.lastAt = at, now
end

--- What a diag picture's words say of this exit now (client/shots.lua): the
--- body's place, heading and ground, the hold, the view, the clip's time.
-- @param now number
-- @return table `{ 'k=v', ... }`
function W.ShotMeta(now)
    local out = {}
    local at = position()
    if at ~= nil then out[#out + 1] = ('body=%.2f,%.2f,%.2f'):format(at.x, at.y, at.z) end
    local yaw = bodyYaw()
    if yaw ~= nil then out[#out + 1] = ('yaw=%.1f'):format(yaw) end
    local b = bodyNow()
    if b ~= nil then out[#out + 1] = 'state=' .. bodyLine(b) end
    out[#out + 1] = 'hold=' .. holdText()
    local state = perspectiveState()
    if state ~= nil then
        out[#out + 1] = ('view=%s/%s/%s'):format(tostring(state.mode), tostring(state.camera), tostring(state.body))
    end
    if walk ~= nil then
        out[#out + 1] = ('step=%s yaw %.0f end %.2f,%.2f'):format(walk.clip, walk.yaw or 0, walk.target.x, walk.target.y)
        if walk.door ~= nil then out[#out + 1] = ('door=%.2f,%.2f'):format(walk.door.x, walk.door.y) end
        if walk.playing ~= nil then out[#out + 1] = ('clip=%.2fs'):format((now - walk.playing.since) / 1000.0) end
    end
    if orbiting ~= nil then out[#out + 1] = ('orbit=%.0f'):format(orbiting.degrees) end
    return out
end

--- The end of each pass of the client's watch: its look (`tick`), then the
--- pass is counted (`pass`).
-- @param seat table|nil this pass's seat read
function W.Tick(seat)
    local ran, failure = pcall(tick, seat)
    pass = pass + 1
    if not ran then error(failure, 0) end
end

--- Whether a walk-out is planned, asked or playing.
function W.Active() return walk ~= nil end

--- What this screen shows of its own step, for the exit's report
--- (client/sync.lua): `{ view, body, orbit, target }`.
function W.Shot()
    local state = perspectiveState()
    return { view = state ~= nil and state.mode or nil, body = state ~= nil and state.body or nil,
        orbit = orbiting ~= nil, target = walk ~= nil and walk.target or nil }
end

--- How long a planned walk-out may take before it is asked: the wait for the
--- view, the plan made again (the hull coming down, a body moved and the view
--- drawn again after it) and two answers -- the server may ask for one more
--- plan, and a move.
function W.Ceiling()
    local settings = anim()
    return settings.viewWaitMax + settings.settle + 2 * PLACE_MS + VIEW_BACK_MS + 2 * settings.answer + 300
end

--- What the console's status line shows.
function W.Status()
    return { walk = walk and walk.clip or nil, asked = walk and walk.asked or false,
        phase = walk ~= nil and walk.phase or nil, lifts = walk ~= nil and walk.lifts or 0,
        playing = walk ~= nil and walk.playing ~= nil, frozen = frozen ~= nil, view = view ~= nil,
        orbit = orbiting ~= nil, settling = walk ~= nil and walk.settleFrom ~= nil and not walk.asked or false,
        moved = walk ~= nil and walk.replaced or 0,
        turnedBack = walk ~= nil and walk.facing ~= nil and walk.facing.back or 0,
        swingTurnsBody = orbitTurnsBody ~= nil,
        standing = walk ~= nil and walk.body ~= nil and walk.body.good >= STAND_LOOKS or false,
        hold = wayOfHold(), holdLifts = { position = holdLifts.position or 0, restriction = holdLifts.restriction or 0 } }
end

--- The server's word about this player's style.
function W.Styled(payload)
    if type(payload) ~= 'table' then return end
    style = { ok = payload.ok == true, style = payload.style, reason = payload.reason }
    Open77.log.info(style.ok and ('exit clips on: this player has the exit style %s'):format(tostring(style.style))
        or ('exit clips off for this player: %s'):format(tostring(style.reason)))
    -- A style given rebuilds this player's body, the stand-in made ahead
    -- included (client/standin.lua, 1.7.6).
    if M.StandIn ~= nil then M.StandIn.Style(style.ok, style.reason) end
end

function W.Start()
    RegisterNetEvent(M.Event.STYLE, function(payload)
        local ran, failure = pcall(W.Styled, payload)
        if not ran then Open77.log.error('the exit style word failed: ' .. tostring(failure)) end
    end)
    RegisterNetEvent(M.Event.WALKING, function(payload)
        local ran, failure = pcall(W.Answer, payload)
        if not ran then Open77.log.error('the exit clip answer failed: ' .. tostring(failure)) end
    end)
end

function W.Stop()
    unfreeze('stopped')
    W.ReleaseView('stopped')
    orbitOff('stopped')
    walk = nil
end
