-- =============================================================================
-- open77_avdoor -- server/enter.lua
-- =============================================================================
-- The server's half of the animated boarding (1.7.0, client/enter.lua): the
-- key on an aircraft's door asks the client for a step up into the door, the
-- step is checked and played for every viewer, and the body is seated as the
-- step ends. Rosalind Myers boarding her AV in Phantom Liberty (q305), the clip
-- `enter` of the exit's package (`avexit`; a door on the right has no clip since
-- open77_avexit 1.3.0 gave `enter_m`'s slot to `couch`, 1.8.0); a seat whose slot
-- is known, with the clip that ends in it (`sit`, `couch`).
--
-- THE PRESS (`E.Begin`, from `M.Press`): a verdict that seats the body, a
-- client that said it knows the step (`HELLO` ... `enter`), the exit's style
-- (given now if it was not: the body is rebuilt for every viewer as it is), and
-- the hull read here. The door opens now, held through the step and the seat,
-- and the client is asked (`ENTER`). Anything missing: `false`, and the press
-- is the plain boarding.
--
-- THE STEP (`E.Ready`): the client's word comes once its body stands on the
-- clip's first spot, faces the door, is held and drawn in third person. It is
-- judged in full again -- the verdict (the seat still free, the hull at rest,
-- the body within reach), the plan against this server's own hull
-- (`E.CheckPlan`: the first spot within `PLAN_METRES` of where the hull puts it,
-- the door's step within the clip's relaxed reach, the body within
-- `BODY_METRES` of the spot as this server has it, waited for `BODY_WAIT_MS`)
-- -- and the clip is played (`Open77.locomotion.playClip`) no sooner than
-- `DOOR_OPEN_MS` after the key. The answer (`ENTERING`) carries the clip's
-- length and when the seat comes.
--
-- THE SEAT (`E.Tend`): `SEAT_EARLY_MS` before the clip ends -- and never before
-- a hull that appeared a moment ago has settled (`BOARD.SETTLE_MS`) -- the body
-- is seated through the platform's own mount (`M.Board`) and the client told
-- as for any boarding (`BOARDED`).
--
-- THE HULL OVER ITS GEAR (1.7.1, `E.SetDown`): a client whose every step is too
-- high sends the ground under the hull's gear with its "no step"; an empty hull
-- is set down on it (server/land.lua) and the client asked again
-- (`SET_DOWN_WAIT_MS` later, `again`). Once a press. A fresh Excalibur hangs
-- 0.4 m over its gear and its door's step 1.07 m up: the owner's first boarding
-- of one was plain (Staging, 2026-10-29).
--
-- INTO THE SEAT (1.7.7): a seat whose slot is known (`AIRFRAMES` ... `SIT`,
-- the Excalibur's pilot seat) is boarded with `SIT_CLIP`, which ends sitting
-- in it -- the body walks up, steps in and sits down. The ask names the door's
-- clip too (`fallback`): a client whose first spot has not the seat's height
-- over its ground plans that one and says why (`sitWhy`). A seat clip's plan
-- is held against the seat's slot on this server's hull (`E.CheckSit`).
--
-- WHATEVER FAILS -- the client's "no step" (with its reason), a plan this
-- server does not hold, a clip the host refuses, no word within `ASK_MS` --
-- the body is seated at once, plainly, and the log says why. Every boarding is
-- one line at the press, one at the step, one at the seat, with the times.
-- =============================================================================

local M = AvDoor
local E = {}
M.EnterServer = E

-- Boardings in progress, by player id: `{ token, id, seat, record, role,
-- clip, door, at, phase ('asked' | 'waiting' | 'playing'), pose, settleUntil,
-- payload, playAt, seatAt, bodyWaitSince, why }`.
local entries = {}
local serial = 0

-- Which clients said they know the step (`HELLO` with `enter = true`), by player id.
local capable = {}

-- What happened, for the status line and the suite.
local counts = { asked = 0, played = 0, seated = 0, plain = 0, refused = 0, none = 0, silent = 0, failed = 0,
    waited = 0, styleGiven = 0, setDown = 0, reasked = 0, sat = 0, fellBack = 0, onWord = 0 }

local said = {}

local function cfg() return M.EnterSettings() end

local function once(key, level, text)
    if said[key] then return end
    said[key] = true
    Open77.log[level](text)
end

local function validPlayer(playerId)
    local id = tonumber(playerId)
    if id == nil or id < 1 or id ~= math.floor(id) then return nil end
    return id
end

local function finite(value)
    local number = tonumber(value)
    if number == nil or number ~= number or number == math.huge or number == -math.huge then return nil end
    return number
end

local function pointOf(value)
    if type(value) ~= 'table' then return nil end
    local x, y = finite(value.x or value[1]), finite(value.y or value[2])
    if x == nil or y == nil then return nil end
    return { x = x, y = y, z = finite(value.z or value[3]) }
end

local function apart(a, b)
    local dx, dy = a.x - b.x, a.y - b.y
    return math.sqrt(dx * dx + dy * dy)
end

--- The hull's pose as this server holds it: `{ x, y, z, yaw, speed }`, or nil.
local function poseOf(id)
    local api = Open77.vehicles
    if type(api) ~= 'table' or type(api.get) ~= 'function' then return nil end
    local read, snapshot = pcall(api.get, id)
    if not read or type(snapshot) ~= 'table' then return nil end
    local x, y, z = finite(snapshot.x), finite(snapshot.y), finite(snapshot.z)
    if (x == nil or y == nil or z == nil) and type(snapshot.position) == 'table' then
        x, y, z = finite(snapshot.position.x), finite(snapshot.position.y), finite(snapshot.position.z)
    end
    local yaw = finite(snapshot.yaw or snapshot.heading)
    if x == nil or y == nil or z == nil or yaw == nil then return nil end
    return { x = x, y = y, z = z, yaw = yaw, speed = finite(snapshot.speed) or 0.0 }
end

--- The body as this server has it, or nil.
local function bodyAt(player)
    local players = Open77.players
    if type(players) ~= 'table' or type(players.position) ~= 'function' then return nil end
    local read, body = pcall(players.position, player)
    if not read then return nil end
    return pointOf(body)
end

local function clipMs(clip)
    local spec = M.WALK_CLIPS[clip]
    return math.floor((spec ~= nil and spec.seconds or 2.6) * 1000)
end

local function tell(player, body)
    local sent, failure = pcall(TriggerClientEvent, M.Event.ENTERING, player, body)
    if not sent then
        Open77.log.warn(('player %d could not be told what the boarding step came to: %s'):format(player,
            tostring(failure)))
    end
    return body
end

--- A hull held on its gear for this boarding (1.8.4, server/land.lua) is let
--- go of once the boarding is over, whatever ended it.
local function letGo(player, entry, why)
    local land = M.Land
    if land == nil or type(land.Release) ~= 'function' or entry == nil then return end
    local ran, failure = pcall(land.Release, entry.id, player, why)
    if not ran then Open77.log.error('letting go of a hull held for a boarding failed: ' .. tostring(failure)) end
end

--- THE SEATS BEING BOARDED (1.8.4): the seat each boarding in progress on a
--- hull is stepping into, by seat -- `M.Verdict` gives a second body the next
--- free one, and its own clip, instead of the same seat.
-- @param id any the hull
-- @param except integer|nil the asking player (their own boarding is theirs)
-- @return table `{ [seat] = player }`
function E.Reserved(id, except)
    local out = {}
    if id == nil then return out end
    local key = M.KeyOf(id)
    for player, entry in pairs(entries) do
        if player ~= except and type(entry.seat) == 'string' and M.KeyOf(entry.id) == key then out[entry.seat] = player end
    end
    return out
end

--- The body seated now, as any boarding is, and the client told (`BOARDED`).
-- @param player integer
-- @param entry table
-- @param how string 'seat' (the step's end) | 'plain' (the step given up)
-- @param why string for the log
-- @return table the board result
local function seatNow(player, entry, how, why)
    if entries[player] == entry then entries[player] = nil end
    local now = M.Now()
    -- 1.7.10: the door the step opened is shut before the seat (`play`), and
    -- the seat never opens it again -- one still open is shut now.
    local result = M.Board(player, entry.id, { door = entry.door ~= nil and 'close' or true, seat = entry.seat })
    -- THE SEAT REFUSED AS THE STEP ENDS -- by the platform, not by the verdict
    -- (the mount of a body whose clip still plays has not been seen in a
    -- game): tried once more after the clip and its blend have run out.
    if how == 'seat' and not result.ok and result.error == 'seat_refused' and not entry.retried then
        entry.retried = true
        entry.phase = 'playing'
        entry.seatAt = (entry.playAt or now) + clipMs(entry.clip) + cfg().blendOut + 100
        entries[player] = entry
        Open77.log.warn(('boarding step: the seat of player %d was refused as the step ended (%s): tried again in %.2fs, '
            .. 'once the clip is over'):format(player, tostring(result.detail), (entry.seatAt - now) / 1000.0))
        return result
    end
    if M.AnswerBoard ~= nil then M.AnswerBoard(player, result) end
    letGo(player, entry, result.ok and ('player %d seated in %s'):format(player, tostring(entry.seat))
        or ('player %d\'s boarding ended unseated'):format(player))
    if how == 'seat' then
        if result.ok then counts.seated = counts.seated + 1 else counts.failed = counts.failed + 1 end
        local into = entry.playAt ~= nil and (now - entry.playAt) / 1000.0 or 0
        local line = ('boarding step: player %d %s %s of %s %.1fs after the key, %.2fs into the %.1fs clip%s'):format(
            player, result.ok and 'seated in' or 'NOT seated in', tostring(entry.seat), tostring(entry.id),
            (now - entry.at) / 1000.0, into, clipMs(entry.clip) / 1000.0,
            result.ok and '' or (' -- ' .. tostring(result.error) .. (result.detail ~= nil and (' (' .. tostring(result.detail)
                .. ')') or '')))
        if result.ok then Open77.log.info(line) else Open77.log.warn(line) end
    else
        counts.plain = counts.plain + 1
        Open77.log.info(('boarding step: none for player %d (%s) -- %s plainly, %.1fs after the key%s'):format(player,
            why, result.ok and 'seated' or 'not seated', (now - entry.at) / 1000.0,
            result.ok and '' or (': ' .. tostring(result.error))))
    end
    return result
end

--- Asks the client for the step (`ENTER`): at the key, and again (`again`)
--- once the hull has been set down on its gear (1.7.1).
-- @return boolean sent
-- @return any why not
local function askClient(player, entry, again)
    local settings = cfg()
    local pose = entry.pose
    entry.askedAt = M.Now()
    return pcall(TriggerClientEvent, M.Event.ENTER, player, {
        token = entry.token, id = M.KeyOf(entry.id), seat = entry.seat, record = entry.record, clip = entry.clip,
        hull = { x = pose.x, y = pose.y, z = pose.z, yaw = pose.yaw },
        durationMs = clipMs(entry.clip), doorOpenMs = settings.doorOpen, askMs = settings.ask,
        again = again == true or nil,
        -- 1.7.7: the door's clip, for a seat clip whose first spot will not do.
        fallback = entry.fallback, fallbackMs = entry.fallback ~= nil and clipMs(entry.fallback) or nil,
    })
end

-- ── the press ────────────────────────────────────────────────────────────────

--- The key on a door, judged: whether the boarding is a step into the door.
-- @param player integer
-- @param verdict table `M.Verdict`'s: `{ id, role, seat, record }`
-- @return boolean true when this half took the press over (the client is asked)
-- @return string|nil why not, for the log
function E.Begin(player, verdict)
    local settings = cfg()
    if settings.off then return false, 'off' end
    if entries[player] ~= nil then return true, 'already' end
    if not capable[player] then
        once('nohello:' .. player, 'info', ('boarding step: player %d\'s client has not said it knows the step (an older '
            .. 'client, or no hello yet): plain boardings for it'):format(player))
        return false, 'client_without_the_step'
    end
    local clip = M.EnterClip(verdict.record, verdict.seat, settings)
    if M.WALK_CLIPS[clip] == nil then return false, 'no_clip' end
    -- INTO THE SEAT (1.7.7): a seat whose slot is known is boarded with the
    -- clip that ends sitting in it; the door's clip is the client's fallback
    -- (the seat's height off over the first spot's ground).
    local fallback = nil
    local sitClip = M.SitClip(verdict.record, verdict.seat, settings)
    if sitClip ~= nil then clip, fallback = sitClip, clip end
    local door = M.SeatDoor(verdict.record, verdict.seat)
    if door.out == nil and settings.knownDoorsOnly then
        once('unknown:' .. tostring(verdict.record), 'info', ('boarding step: none into %s -- its door is not known '
            .. '(`AIRFRAMES`) and `KNOWN_DOORS_ONLY` is set'):format(tostring(verdict.record)))
        return false, 'door_unknown'
    end
    local walkout = M.WalkOutServer
    if walkout == nil then return false, 'no_exit_animation' end
    local styled, styleWhy = walkout.EnsureStyle(player, 'a boarding')
    if not styled then
        Open77.log.info(('boarding step: none for player %d -- no clip style (%s): plain boarding'):format(player,
            tostring(styleWhy)))
        return false, 'style:' .. tostring(styleWhy)
    end
    if styleWhy == 'assigned' then counts.styleGiven = counts.styleGiven + 1 end
    local pose = poseOf(verdict.id)
    if pose == nil then return false, 'no_pose' end
    serial = serial + 1
    local now = M.Now()
    local token = ('%d.%d'):format(player, serial)
    local doorName = M.ExitDoorName(verdict.record, verdict.seat)
    local ms = clipMs(clip)
    local entry = { token = token, id = verdict.id, seat = verdict.seat, record = verdict.record, role = verdict.role,
        clip = clip, fallback = fallback, door = doorName, at = now, phase = 'asked', pose = pose,
        settleUntil = now + (M.SettleLeft ~= nil and M.SettleLeft(verdict.id) or 0) }
    entries[player] = entry
    counts.asked = counts.asked + 1
    -- A hull held on its gear for another boarding behind its pilot (1.8.4)
    -- is held for this one too.
    if M.Land ~= nil and type(M.Land.Join) == 'function' then pcall(M.Land.Join, verdict.id, player) end
    -- THE DOOR OPENS ON THE KEY, held through the step and the seat: the
    -- client's preparation, the clip, and the boarding's own hold after it.
    local doorText = 'no door to swing'
    if doorName ~= nil then
        local hold = settings.ask + ms + M.BoardSettings().hold + 1000
        local opened, reason = M.OpenDoor(verdict.id, doorName, hold, 'enter')
        doorText = opened and ('its %s door opened for %.1fs'):format(doorName, hold / 1000.0)
            or ('its %s door would not open (%s)'):format(doorName, tostring(reason))
    end
    local sent, failure = askClient(player, entry, false)
    if not sent then
        entries[player] = nil
        letGo(player, entry, 'its client could not be asked')
        Open77.log.warn(('boarding step: player %d could not be asked (%s): plain boarding'):format(player,
            tostring(failure)))
        return false, 'not_sent'
    end
    local sit = fallback ~= nil and M.SeatSit(verdict.record, verdict.seat) or nil
    Open77.log.info(('boarding step %s: player %d boards %s (%s, %s) as %s -- %s; the client is asked to stand on the '
        .. 'clip\'s first spot facing %s (hull at %.2f, %.2f, %.2f heading %.0f; %s; the clip %.1fs; '
        .. 'at most %.1fs to prepare%s)'):format(clip, player, tostring(verdict.id), tostring(verdict.record),
        tostring(verdict.seat), tostring(verdict.role), doorText,
        sit ~= nil and 'away from the seat it ends in' or 'the door', pose.x, pose.y, pose.z, pose.yaw,
        sit ~= nil and ('into the seat: its slot %.2f m %s, %.2f m %s, facing %.0f deg from the hull\'s heading; '
            .. 'the door\'s clip %s if the seat will not do'):format(math.abs(sit.y), sit.y < 0 and 'behind' or 'ahead',
            math.abs(sit.x), sit.x < 0 and 'left' or 'right', sit.yaw, tostring(fallback))
            or (door.out ~= nil and ('the %s\'s door %.2f m out, its step %s'):format(door.airframe or 'airframe', door.out,
                door.step ~= nil and ('%.2f m under the origin'):format(door.step) or 'not known')
                or 'its door guessed from the hull\'s box'), ms / 1000.0, settings.ask / 1000.0,
        entry.settleUntil > now and (', the hull settles %.1fs more'):format((entry.settleUntil - now) / 1000.0) or ''))
    return true, 'asked'
end

--- THE HULL OVER ITS GEAR (1.7.1): the client's measure of the ground under
--- the gear, and the empty hull lowered onto it (server/land.lua, as after an
--- exit) -- the step is asked for again `SET_DOWN_WAIT_MS` later, on the hull
--- where it then stands. A hull this server will not lower says why in its own
--- line ("aircraft ... stays where the flight left it", "already stands on its
--- gear"), and the boarding is the plain one.
-- @param player integer
-- @param entry table
-- @param measure table the client's `{ grounds, x, y, z }`
-- @return boolean whether it was set down
-- @return string what came of it
function E.SetDown(player, entry, measure)
    local land = M.Land
    if land == nil or type(land.Lower) ~= 'function' then return false, 'no set-down on this server' end
    local grounds = {}
    if type(measure.grounds) == 'table' then
        for index = 1, 8 do
            local z = finite(measure.grounds[index])
            if z ~= nil and math.abs(z) <= 100000.0 then grounds[index] = z end
        end
    end
    local ask = { grounds = grounds, x = finite(measure.x), y = finite(measure.y), z = finite(measure.z), at = M.Now() }
    local ran, lowered, _, glideMs = pcall(land.Lower, M.KeyOf(entry.id), { id = entry.id, player = player,
        at = entry.at, record = entry.record, what = 'boarding' }, ask)
    if not ran then return false, 'the set-down failed: ' .. tostring(lowered) end
    if not lowered then return false, 'the line before this one says why' end
    local settings = cfg()
    local pose = poseOf(entry.id)
    if pose ~= nil then entry.pose = pose end
    -- A hull glided down (1.7.9) is asked about once it stands on its gear.
    glideMs = math.max(0, math.floor(tonumber(glideMs) or 0))
    entry.phase, entry.reaskAt = 'lowered', M.Now() + glideMs + settings.setDownWait
    counts.setDown = counts.setDown + 1
    Open77.log.info(('boarding step %s for player %d: the hull hung over its gear -- set down on it first%s; the step '
        .. 'is asked for again in %d ms'):format(entry.clip, player,
        glideMs > 0 and (' (glided down over %.1fs)'):format(glideMs / 1000.0) or '', glideMs + settings.setDownWait))
    return true, 'set down'
end

--- The second ask, once the hull stands on its gear: a new token, the door
--- held open again, the hull where it now stands.
local function reask(player, entry)
    local settings = cfg()
    serial = serial + 1
    entry.token = ('%d.%d'):format(player, serial)
    entry.phase = 'asked'
    local pose = poseOf(entry.id)
    if pose ~= nil then entry.pose = pose end
    if entry.door ~= nil then
        M.OpenDoor(entry.id, entry.door, settings.ask + clipMs(entry.clip) + M.BoardSettings().hold + 1000, 'enter')
    end
    local sent, failure = askClient(player, entry, true)
    if not sent then
        return seatNow(player, entry, 'plain', 'the second ask could not be sent: ' .. tostring(failure))
    end
    counts.reasked = counts.reasked + 1
    Open77.log.info(('boarding step %s: player %d asked again, %.1fs after the key -- the hull on its gear at %.2f, '
        .. '%.2f, %.2f'):format(entry.clip, player, (M.Now() - entry.at) / 1000.0, entry.pose.x, entry.pose.y,
        entry.pose.z))
end

--- Whether a player's boarding step is under way (the key is then busy).
function E.Busy(player)
    return entries[validPlayer(player) or -1] ~= nil
end

-- ── the step ─────────────────────────────────────────────────────────────────

--- The client's plan held against this server's hull.
-- @param player integer
-- @param entry table
-- @param payload table the client's word
-- @return string 'ok' | 'wait' | 'refuse'
-- @return string what was found (or the refusal's reason)
function E.CheckPlan(player, entry, payload)
    local plan = type(payload.plan) == 'table' and payload.plan or nil
    if plan == nil then return 'refuse', 'no_plan' end
    local at = pointOf(plan.at)
    if at == nil then return 'refuse', 'no_first_spot' end
    local settings = cfg()
    local pose = poseOf(entry.id)
    if pose == nil then return 'refuse', 'hull_unreadable' end
    if pose.speed > M.Number((M.Settings or {}).REST_SPEED, 0.0, 50.0, 2.0) then
        return 'refuse', ('hull_moving:%.1f'):format(pose.speed)
    end
    if M.SeatClip(entry.clip) then return E.CheckSit(player, entry, payload, plan, at, pose) end
    local door = M.SeatDoor(entry.record, entry.seat)
    local walk = M.WalkOutSettings()
    local width = door.out or math.max(walk.doorMin, math.min(walk.doorMax, M.Number(plan.width, 0.3, 15.0, walk.door)))
    local turned = plan.turned == true
    local r = math.rad(turned and (pose.yaw + 180.0) or pose.yaw)
    local stepTurn = M.StepTurn(plan.stepTurn)
    local own = M.WalkOutPlan({ x = pose.x, y = pose.y }, { x = -math.sin(r), y = math.cos(r) }, entry.seat,
        M.ExitSettings(), entry.clip, width, door, stepTurn)
    if own == nil then return 'refuse', 'no_plan_of_its_own' end
    local off = apart(own, at)
    local moved = apart(pose, entry.pose)
    if off > settings.planTolerance then
        return 'refuse', ('first_spot_off:%.2f'):format(off)
    end
    -- The door's step over the first spot's ground, on this server's hull.
    local ground = finite(plan.ground)
    local step = M.StepHeight(pose.z, door, ground)
    local lo, hi = M.StepBand(entry.clip, true)
    if step ~= nil and lo ~= nil and (step < lo or step > hi) then
        return 'refuse', ('step_out_of_reach:%.2f'):format(step)
    end
    -- The body, as this server has it.
    local body = bodyAt(player)
    if body ~= nil and apart(body, at) > settings.bodyTolerance then
        return 'wait', ('the body is %.1f m from the first spot as the server has it'):format(apart(body, at))
    end
    local seen = {}
    local facing, facingOff = finite(plan.facing), finite(plan.facingOff)
    if facing ~= nil then
        seen[#seen + 1] = ('the body facing %.0f deg (%.1f off the step\'s %.0f)'):format(facing, facingOff or 0, own.yaw)
    end
    if stepTurn ~= 0 then seen[#seen + 1] = ('the step turned %+.0f deg about the door'):format(stepTurn) end
    if turned then seen[#seen + 1] = 'planned on the hull turned round' end
    if type(plan.source) == 'string' then seen[#seen + 1] = 'planned on the ' .. plan.source:sub(1, 24) .. '\'s frame' end
    -- The step as this server's hull has it: what every screen should draw.
    entry.own = { x = own.x, y = own.y, z = finite(plan.at.z) or at.z, yaw = own.yaw,
        door = { x = own.door.x, y = own.door.y, z = door.step ~= nil and (pose.z - door.step) or nil } }
    return 'ok', ('the first spot %.2f m from the server\'s plan, the hull %.2f m from where it stood at the key, the '
        .. 'door\'s step %s%s'):format(off, moved, step ~= nil and ('%.2f m over the first spot'):format(step)
        or 'not known', #seen > 0 and ('; ' .. table.concat(seen, '; ')) or '')
end

--- INTO THE SEAT (1.7.7): a seat clip's plan held against this server's hull --
--- the first spot within `PLAN_METRES` of where the seat's slot puts it on the
--- hull as this server has it, the seat at the clip's height over the spot's
--- ground (the relaxed band), the body within `BODY_METRES` of the spot.
-- @return string 'ok' | 'wait' | 'refuse'
-- @return string what was found (or the refusal's reason)
function E.CheckSit(player, entry, payload, plan, at, pose)
    local settings = cfg()
    local sit = M.SeatSit(entry.record, entry.seat)
    if sit == nil then return 'refuse', 'no_seat_slot' end
    local r = math.rad(pose.yaw)
    local own = M.SitPlan({ x = pose.x, y = pose.y, z = pose.z, fx = -math.sin(r), fy = math.cos(r) }, sit, entry.clip)
    if own == nil then return 'refuse', 'no_plan_of_its_own' end
    local off = apart(own, at)
    local moved = apart(pose, entry.pose)
    if off > settings.planTolerance then
        return 'refuse', ('first_spot_off:%.2f'):format(off)
    end
    -- The seat over where the body stands, on this server's hull.
    local stands = at.z or finite(plan.ground)
    local height = stands ~= nil and (own.seat.z - stands) or nil
    local fit = M.SeatFit(entry.clip, height)
    if fit == 'high' or fit == 'low' then
        return 'refuse', ('seat_out_of_reach:%.2f'):format(height)
    end
    local body = bodyAt(player)
    if body ~= nil and apart(body, at) > settings.bodyTolerance then
        return 'wait', ('the body is %.1f m from the first spot as the server has it'):format(apart(body, at))
    end
    local seen = {}
    local facing, facingOff = finite(plan.facing), finite(plan.facingOff)
    if facing ~= nil then
        seen[#seen + 1] = ('the body facing %.0f deg (%.1f off the step\'s %.0f)'):format(facing, facingOff or 0, own.yaw)
    end
    if type(plan.source) == 'string' then seen[#seen + 1] = 'planned on the ' .. plan.source:sub(1, 24) .. '\'s frame' end
    -- The step as this server's hull has it: its last frame in the seat.
    entry.own = { x = own.x, y = own.y, z = at.z, yaw = own.yaw, seat = true,
        door = { x = own.seat.x, y = own.seat.y, z = own.seat.z } }
    return 'ok', ('the first spot %.2f m from the server\'s plan, the hull %.2f m from where it stood at the key, the '
        .. 'seat %s%s'):format(off, moved, height ~= nil and ('%.2f m over where the body stands (%s)'):format(height,
        tostring(fit)) or 'at a height not known', #seen > 0 and ('; ' .. table.concat(seen, '; ')) or '')
end

--- Plays the step now and tells the client when the seat comes.
local function play(player, entry)
    local settings = cfg()
    local now = M.Now()
    local loco = Open77.locomotion
    if type(loco) ~= 'table' or type(loco.playClip) ~= 'function' then
        tell(player, { token = entry.token, ok = false, reason = 'locomotion_unavailable_on_this_host' })
        counts.refused = counts.refused + 1
        return seatNow(player, entry, 'plain', 'no locomotion on this host')
    end
    local read, ok, handle = pcall(loco.playClip, player, entry.clip,
        { speed = 1.0, blendInMs = settings.blendIn, blendOutMs = settings.blendOut })
    if not read or ok ~= true then
        local reason = tostring(read and handle or ok)
        counts.refused = counts.refused + 1
        tell(player, { token = entry.token, ok = false, reason = 'clip_refused:' .. reason:sub(1, 60) })
        return seatNow(player, entry, 'plain', 'the host would not play the clip: ' .. reason)
    end
    local ms = clipMs(entry.clip)
    entry.phase, entry.playAt = 'playing', now
    -- THE VIEW BEFORE THE SEAT (1.7.8): the client asks for the seat once its
    -- stand-in is put away (`ENTER_SEAT`); this is the seat when no word comes.
    entry.seatAt = settings.seatAfterView and math.max(now + ms + settings.seatWait, entry.settleUntil)
        or math.max(now + ms - settings.seatEarly, entry.settleUntil)
    counts.played = counts.played + 1
    if M.SeatClip(entry.clip) then counts.sat = counts.sat + 1 end
    -- THE SCENE (server/sync.lua): every screen near it reports what it drew of
    -- the step, and the boarding ends with a verdict.
    local sceneSeq = nil
    if M.Sync ~= nil and type(M.Sync.Boarding) == 'function' and entry.own ~= nil then
        local ran, number = pcall(M.Sync.Boarding, player, { id = entry.id, seat = entry.seat, record = entry.record,
            clip = entry.clip, durationMs = ms, at = { x = entry.own.x, y = entry.own.y, z = entry.own.z },
            yaw = entry.own.yaw, door = entry.own.door })
        if ran then sceneSeq = number else Open77.log.error('the boarding scene could not start: ' .. tostring(number)) end
    end
    tell(player, { token = entry.token, ok = true, clip = entry.clip, durationMs = ms, seatInMs = entry.seatAt - now,
        scene = sceneSeq })
    -- THE DOOR SHUT BEFORE THE SEAT (1.7.10): open through the climb, closed
    -- while the body is still on foot -- the pilot's own game drew a door the
    -- server closed after the seat open through the flight (Staging,
    -- 2026-10-29, 17:25).
    if entry.door ~= nil then
        local closeIn = M.DoorCloseInto(entry.clip, ms, settings, M.DoorCloseLead(entry.record))
        M.OpenDoor(entry.id, entry.door, ms + M.BoardSettings().hold + 1000, 'enter')
        M.CloseDoorAt(entry.id, entry.door, now + closeIn, 'enter')
        entry.doorCloseAt = now + closeIn
        Open77.log.info(('boarding step %s for player %d: the %s door closes %.1fs into the %.1fs clip, %.1fs before '
            .. 'the seat at the latest (%s)'):format(entry.clip, player, entry.door, closeIn / 1000.0, ms / 1000.0,
            math.max(0, entry.seatAt - now - closeIn) / 1000.0, M.SeatClip(entry.clip)
                and 'the body inside, sitting down' or 'the body in the door'))
    end
    if settings.seatAfterView then
        Open77.log.info(('boarding step %s playing for player %d (handle %s), %.1fs after the key: the seat once the '
            .. 'client has put its stand-in away, %.1fs before the clip\'s end -- in %.2fs at the latest%s'):format(
            entry.clip, player, tostring(handle), (now - entry.at) / 1000.0, M.ViewLead(entry.clip, settings) / 1000.0,
            (entry.seatAt - now) / 1000.0, entry.seatAt > now + ms + settings.seatWait
                and ' (after the hull has settled)' or ''))
    else
        Open77.log.info(('boarding step %s playing for player %d (handle %s), %.1fs after the key: the seat in %.2fs%s')
            :format(entry.clip, player, tostring(handle), (now - entry.at) / 1000.0, (entry.seatAt - now) / 1000.0,
                entry.seatAt > now + ms - settings.seatEarly and ' (after the hull has settled)' or ''))
    end
    return true
end

--- THE VIEW BEFORE THE SEAT (1.7.8): the client's word that its stand-in is
--- put away (or that it waited `PARK_WAIT_MS` for it) -- the body is seated
--- now, not at the fallback time. A hull still settling keeps its own time.
-- @param playerId integer
-- @param payload table `{ token, parked, parkMs }`
function E.Seat(playerId, payload)
    local player = validPlayer(playerId)
    if player == nil or type(payload) ~= 'table' then return nil end
    local entry = entries[player]
    if entry == nil or payload.token ~= entry.token then
        Open77.log.info(('boarding step: player %d asks for a seat for a step that is not under way (token %s): '
            .. 'ignored'):format(player, tostring(payload.token):sub(1, 24)))
        return nil
    end
    if entry.phase ~= 'playing' then
        Open77.log.info(('boarding step %s: player %d asks for the seat before the step plays (%s): ignored'):format(
            entry.clip, player, tostring(entry.phase)))
        return nil
    end
    local now = M.Now()
    local into = (now - (entry.playAt or now)) / 1000.0
    local parkMs = finite(payload.parkMs)
    Open77.log.info(('boarding step %s: player %d\'s screen %s %.2fs into the %.1fs clip%s: seated now'):format(
        entry.clip, player, payload.parked == true and 'put its stand-in away' or 'did not see its stand-in put away',
        into, clipMs(entry.clip) / 1000.0, parkMs ~= nil and (' (%.2fs after it let go of the view)'):format(
        parkMs / 1000.0) or ''))
    if now < entry.settleUntil then
        entry.seatAt = entry.settleUntil
        return nil
    end
    counts.onWord = counts.onWord + 1
    return seatNow(player, entry, 'seat', 'the client put its stand-in away')
end

--- The client's word: its body stands on the first spot -- play it -- or there
--- is no step (`clip = false`).
-- @param playerId integer
-- @param payload table `{ token, id, clip, plan }` or `{ token, clip = false, why }`
-- @param again boolean|nil a waiting word looked at again (`E.Tend`)
function E.Ready(playerId, payload, again)
    local player = validPlayer(playerId)
    if player == nil or type(payload) ~= 'table' then return nil end
    local entry = entries[player]
    if entry == nil or payload.token ~= entry.token then
        Open77.log.info(('boarding step: a word from player %d for a step that is not under way (token %s): ignored')
            :format(player, tostring(payload.token):sub(1, 24)))
        return nil
    end
    if payload.clip == false then
        -- THE HULL OVER ITS GEAR (1.7.1): the client asks for it to be set down
        -- first. Once, on an empty hull: then the step is asked for again.
        if type(payload.setDown) == 'table' and not entry.setDownTried and cfg().setDown then
            entry.setDownTried = true
            local lowered, text = E.SetDown(player, entry, payload.setDown)
            if lowered then return nil end
            counts.none = counts.none + 1
            return seatNow(player, entry, 'plain', ('the client: %s; the hull could not be set down first (%s)'):format(
                tostring(payload.why or 'no step'):sub(1, 120), tostring(text)))
        end
        counts.none = counts.none + 1
        return seatNow(player, entry, 'plain', 'the client: ' .. tostring(payload.why or 'no step'):sub(1, 120))
    end
    if entry.phase == 'playing' then return nil end
    -- INTO THE SEAT (1.7.7): the client planned the door's clip instead of the
    -- seat's (the seat's height off over its first spot): the step is that one.
    if type(payload.clip) == 'string' and payload.clip ~= entry.clip then
        if entry.fallback == nil or payload.clip ~= entry.fallback then
            counts.refused = counts.refused + 1
            tell(player, { token = entry.token, ok = false, reason = 'clip_not_asked' })
            return seatNow(player, entry, 'plain', ('the client planned %s, not the %s it was asked for'):format(
                tostring(payload.clip):sub(1, 24), tostring(entry.clip)))
        end
        counts.fellBack = counts.fellBack + 1
        Open77.log.info(('boarding step %s for player %d: the client plans the door\'s clip %s instead -- %s'):format(
            entry.clip, player, entry.fallback, tostring(payload.sitWhy or 'the seat clip would not do'):sub(1, 200)))
        entry.sitClip, entry.clip, entry.fallback = entry.clip, entry.fallback, nil
    end
    local settings = cfg()
    local now = M.Now()
    -- THE VERDICT AGAIN: the seat may have been taken, the hull moved, the body
    -- hurt, since the key.
    local verdict, why = M.Verdict(player, entry.id, { prefer = entry.seat })
    if verdict == nil then
        counts.refused = counts.refused + 1
        if entries[player] == entry then entries[player] = nil end
        letGo(player, entry, 'the verdict changed: ' .. tostring(why))
        tell(player, { token = entry.token, ok = false, reason = tostring(why) })
        Open77.log.info(('boarding step: player %d is not seated -- the verdict changed since the key: %s')
            :format(player, tostring(why)))
        if M.AnswerBoard ~= nil then M.AnswerBoard(player, M.Err(why or 'no_aircraft')) end
        return nil
    end
    if verdict.seat ~= entry.seat then
        Open77.log.info(('boarding step: player %d\'s seat is %s now (was %s): the step plays to it all the same')
            :format(player, tostring(verdict.seat), tostring(entry.seat)))
        entry.seat = verdict.seat
    end
    local result, found = E.CheckPlan(player, entry, payload)
    if result == 'refuse' then
        counts.refused = counts.refused + 1
        tell(player, { token = entry.token, ok = false, reason = found })
        return seatNow(player, entry, 'plain', 'its plan was not held: ' .. found)
    end
    if result == 'wait' then
        entry.bodyWaitSince = entry.bodyWaitSince or now
        if now - entry.bodyWaitSince >= settings.bodyWait then
            counts.refused = counts.refused + 1
            tell(player, { token = entry.token, ok = false, reason = 'body_not_at_the_first_spot' })
            return seatNow(player, entry, 'plain', found)
        end
        if not again then
            counts.waited = counts.waited + 1
            Open77.log.info(('boarding step %s for player %d waits: %s (at most %d ms)'):format(entry.clip, player,
                found, settings.bodyWait))
        end
        entry.phase, entry.payload = 'waiting', payload
        return nil
    end
    entry.bodyWaitSince = nil
    Open77.log.info(('boarding step %s for player %d: the plan holds -- %s'):format(entry.clip, player, found))
    local openAt = entry.at + settings.doorOpen
    if now < openAt then
        entry.phase, entry.payload, entry.playAt = 'door', payload, nil
        entry.doorAt = openAt
        Open77.log.info(('boarding step %s for player %d starts in %d ms, once the door has swung'):format(entry.clip,
            player, openAt - now))
        return nil
    end
    return play(player, entry)
end

--- Every tenth of a second: the steps waiting for the door or the body, the
--- seats due, and the words that never came.
function E.Tend()
    local settings = cfg()
    local now = M.Now()
    for player, entry in pairs(entries) do
        local ran, failure = pcall(function()
            if entry.phase == 'asked' and now - (entry.askedAt or entry.at) > settings.ask + 1000 then
                counts.silent = counts.silent + 1
                seatNow(player, entry, 'plain', ('no word from the client in %.1fs'):format(
                    (now - (entry.askedAt or entry.at)) / 1000.0))
            elseif entry.phase == 'lowered' and now >= (entry.reaskAt or now) then
                reask(player, entry)
            elseif entry.phase == 'waiting' then
                E.Ready(player, entry.payload, true)
            elseif entry.phase == 'door' and now >= (entry.doorAt or now) then
                play(player, entry)
            elseif entry.phase == 'playing' and now >= entry.seatAt then
                seatNow(player, entry, 'seat', 'the step\'s end')
            end
        end)
        if not ran then
            entries[player] = nil
            letGo(player, entry, 'an error')
            counts.failed = counts.failed + 1
            Open77.log.error(('boarding step for player %d failed (%s): plain boarding'):format(player, tostring(failure)))
            pcall(seatNow, player, entry, 'plain', 'an error')
        end
    end
end

--- A client's hello: whether it knows the step -- and, 1.7.2, can draw it (a
--- game without open77_avexit's package says `enter = false`, `anim.ok = false`).
function E.Hello(playerId, info)
    local player = validPlayer(playerId)
    if player == nil then return end
    local knows = type(info) == 'table' and info.enter == true
    if capable[player] ~= knows then
        said['nohello:' .. player] = nil
    end
    capable[player] = knows or nil
    local anim = type(info) == 'table' and type(info.anim) == 'table' and info.anim or nil
    if anim ~= nil and anim.known == true and anim.ok ~= true then
        -- Not "an older client": a game that cannot draw the step.
        said['nohello:' .. player] = true
        once('noclips:' .. player, 'info', ('boarding step: player %d\'s game cannot draw it (no AV animation '
            .. 'package): plain boardings for it, at once'):format(player))
    else
        said['noclips:' .. player] = nil
    end
end

function E.Forget(playerId)
    local player = validPlayer(playerId)
    if player == nil then return end
    if entries[player] ~= nil then letGo(player, entries[player], ('player %d left'):format(player)) end
    entries[player], capable[player] = nil, nil
    said['nohello:' .. player], said['noclips:' .. player] = nil, nil
end

function E.Status()
    local n = 0
    for _ in pairs(entries) do n = n + 1 end
    return { asked = counts.asked, played = counts.played, seated = counts.seated, plain = counts.plain,
        refused = counts.refused, none = counts.none, silent = counts.silent, failed = counts.failed,
        waited = counts.waited, styleGiven = counts.styleGiven, setDown = counts.setDown, reasked = counts.reasked,
        sat = counts.sat, fellBack = counts.fellBack, onWord = counts.onWord, now = n }
end

function E.Start()
    RegisterNetEvent(M.Event.ENTER_READY, function(payload)
        local player = validPlayer(source)
        if player == nil or type(payload) ~= 'table' then return end
        if M.Cooling(player, 'enterReady', 150) then return end
        local ran, failure = pcall(E.Ready, player, payload)
        if not ran then
            Open77.log.error('a boarding step word failed: ' .. tostring(failure))
            local entry = entries[player]
            if entry ~= nil then pcall(seatNow, player, entry, 'plain', 'an error') end
        end
    end)
    RegisterNetEvent(M.Event.ENTER_SEAT, function(payload)
        local player = validPlayer(source)
        if player == nil or type(payload) ~= 'table' then return end
        if M.Cooling(player, 'enterSeat', 150) then return end
        local ran, failure = pcall(E.Seat, player, payload)
        if not ran then
            Open77.log.error('a boarding seat word failed: ' .. tostring(failure))
            local entry = entries[player]
            if entry ~= nil then pcall(seatNow, player, entry, 'plain', 'an error') end
        end
    end)
    local settings = cfg()
    Open77.log.info(('boarding step: %s'):format(settings.off and 'off (`ENTER_ANIM = false`): plain boardings'
        or (('clips %s / %s, %s, the door %d ms before the step, %s, at most %.1fs to prepare'):format(
            settings.clip, tostring(settings.mirrorClip or 'none on the right'),
            settings.sit and ('%s into a seat whose slot is known (or the seat\'s own)'):format(settings.sitClip)
                or 'no seat clip (`SIT = false`)',
            settings.doorOpen, settings.seatAfterView
                and ('the seat once the client has put its stand-in away (%d ms before a seat clip\'s end, %d before a '
                    .. 'door clip\'s; %d ms after it at the latest)'):format(settings.viewLead, settings.doorViewLead,
                    settings.seatWait)
                or ('the seat %d ms before its end'):format(settings.seatEarly),
            settings.ask / 1000.0))))
end

function E.Stop()
    entries, capable = {}, {}
end

function E.Reset()
    entries, capable, said = {}, {}, {}
    serial = 0
    for k in pairs(counts) do counts[k] = 0 end
end
