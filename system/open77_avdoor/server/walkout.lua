-- =============================================================================
-- open77_avdoor -- server/walkout.lua
-- =============================================================================
-- The server's half of the animated exit (client/walkout.lua): the locomotion
-- style the clips play on, the clip itself, and what every other game sees of
-- the exit.
--
-- THE STYLE. `Open77.locomotion.playClip` plays a clip of the package a
-- player's style belongs to, and only for the resource that gave that style
-- (`EXIT_ANIM.STYLE`, registered by open77_avexit). Giving a style rebuilds the
-- body every viewer draws for that player, so it is given as the player becomes
-- ready or its client says hello (`ASSIGN = 'join'`, 1.7.0: the boarding step
-- plays on it before any seat), or while the body is hidden in an aircraft seat
-- (`'board'`, and the last chance for 'join'), or at the key on a door when it
-- still has none (server/enter.lua), and kept for the session. A style another
-- resource gave is never taken: that player steps out (and in) unanimated.
--
-- THE CLIP. The client asks once its body stands where the clip ends
-- (`WALKOUT`). The ask is judged here: a seat of an aircraft left a moment ago
-- (`WINDOW_MS`), by this player, and the clip is the one this server derives
-- from that hull's record and that seat -- a client names a clip, it does not
-- choose one. The ask carries the plan, held against the server's own hull
-- (`S.CheckPlan`): an end point the server's hull does not put there is sent
-- that hull to plan on once more, a door's step out of the clip's reach plays
-- no clip, a body not yet where it says is waited for. The answer (`WALKING`)
-- carries the clip and its length.
--
-- WHAT THE OTHERS SEE. The platform drops a pilot inside the cabin and ejects
-- the body under the hull about 1.7 s later; the exit guard puts it beside the
-- door. Every other game would see all of that, so the body is hidden from them
-- (`Open77.players.setVisible`) from the moment the seat empties until the clip
-- starts -- or until the client says there is no clip, or `HIDE_MAX_MS`.
-- =============================================================================

local M = AvDoor
local S = {}
M.WalkOutServer = S

-- Exits a clip may still be asked for, by player id:
-- `{ id, seat, record, at, clip }`.
local exits = {}

-- Players hidden from the others for their exit, by player id: `{ at, untilAt, why }`.
local hidden = {}

-- Clips that ended with "no clip" before the server saw the seat empty (the
-- client is quicker than the occupancy event): by player id, when.
local early = {}

-- Asks that came while the platform still held the seat (flagged as leaving:
-- the leaving game had not confirmed its exit yet, and the host plays no clip
-- on a body in a vehicle): by player id, `{ payload, at, untilAt }`. Looked at
-- again every tenth of a second (`S.Tend`) until the seat is free or `PENDING_MS`.
local pending = {}

-- Players this resource gave the style to, by id: when.
local styled = {}

-- What each player's client was last told about its style, by id: 'ok' or a
-- reason, so a client is told only when it changes.
local toldStyle = {}

-- When the style was last refused as unavailable (the package not running),
-- so a missing package is one line a minute, not one per boarding.
local unavailableAt = nil

-- Players whose game said it cannot draw the clips (1.7.2: open77_avexit's
-- package not registered there), by id: the reason. Their exits are plain:
-- nothing is hidden from the others, no scene waits for them.
local noClips = {}

-- STYLES REFUSED FOR NOW (1.7.6), by player: `{ since, nextAt, tries, reason }`
-- -- asked for again from `S.Tend` until given (see `STYLE_RETRY_MS`).
local retry = {}

-- Refusals no wait can change: the style is not asked for again for them.
local FINAL = {
    off = true, locomotion_unavailable_on_this_host = true, locomotion_package_unavailable = true,
    style_owned_elsewhere = true, error = true,
}

-- What happened, for the status line.
local counts = { asked = 0, played = 0, refused = 0, none = 0, hidden = 0, styled = 0, replans = 0, noClips = 0,
    retried = 0 }

local said = {}

local function anim() return M.WalkOutSettings() end

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

-- ── the style ────────────────────────────────────────────────────────────────

--- Tells a client whether its exit has a clip, when that changed.
local function tellStyle(playerId, ok, reason)
    local key = ok and 'ok' or tostring(reason)
    if toldStyle[playerId] == key then return end
    toldStyle[playerId] = key
    pcall(TriggerClientEvent, M.Event.STYLE, playerId,
        ok and { ok = true, style = anim().style } or { ok = false, reason = tostring(reason) })
end

local ensure

--- Gives the player the exit package's style, unless it is theirs already or
--- another resource's, and tells their client what it came to.
-- @param playerId integer
-- @param why string for the log
-- @return boolean
-- @return string 'assigned' | 'kept' | a reason
function S.EnsureStyle(playerId, why, quiet)
    local ok, reason = ensure(playerId, why, quiet)
    if reason ~= 'off' then tellStyle(playerId, ok, reason) end
    local now = M.Now()
    local wait = retry[playerId]
    if ok then
        if wait ~= nil then
            retry[playerId] = nil
            Open77.log.info(('player %d has the exit style %.1fs after it was first refused (%s; %d more ask(s)): '
                .. 'the boarding finds it, and its third-person body is not rebuilt at the key'):format(playerId,
                (now - wait.since) / 1000.0, wait.reason, wait.tries))
        end
    elseif not FINAL[tostring(reason)] and anim().assign == 'join' then
        -- Not ready yet (or not alive): asked for again, not left for the key.
        if wait == nil then
            local settings = anim()
            retry[playerId] = { since = now, nextAt = now + settings.styleRetry, tries = 0, reason = tostring(reason) }
            Open77.log.info(('the exit style is asked for again for player %d every %.1fs until given (%s, %s), %.0fs '
                .. 'at most'):format(playerId, settings.styleRetry / 1000.0, tostring(reason), why,
                settings.styleRetryMax / 1000.0))
        else
            wait.reason = tostring(reason)
        end
    else
        retry[playerId] = nil
    end
    return ok, reason
end

ensure = function(playerId, why, quiet)
    local settings = anim()
    if settings.off then return false, 'off' end
    local loco = Open77.locomotion
    if type(loco) ~= 'table' or type(loco.set) ~= 'function' then
        once('loco', 'warn', 'no Open77.locomotion on this server (2.31.21+op77.145 or later): exits are not animated')
        return false, 'locomotion_unavailable_on_this_host'
    end
    local now = M.Now()
    if unavailableAt ~= nil and now - unavailableAt < 60000 then return false, 'locomotion_package_unavailable' end
    if type(loco.get) == 'function' then
        local read, current = pcall(loco.get, playerId)
        if read and type(current) == 'table' and current.style ~= nil then
            if current.style == settings.style then
                styled[playerId] = styled[playerId] or now
                return true, 'kept'
            end
            Open77.log.info(('player %d has the locomotion style %s from another resource: their exits are not '
                .. 'animated'):format(playerId, tostring(current.style)))
            return false, 'style_owned_elsewhere'
        end
    end
    local read, ok, reason = pcall(loco.set, playerId, settings.style, { resetOnDeath = false })
    if not read then
        Open77.log.error(('the exit style could not be given to player %d: %s'):format(playerId, tostring(ok)))
        return false, 'error'
    end
    if ok ~= true then
        reason = tostring(reason)
        if reason == 'locomotion_package_unavailable' then
            unavailableAt = now
            Open77.log.warn(('the locomotion style %s is not registered: start open77_avexit (and let the launcher '
                .. 'install its archive) for animated exits; asked again in a minute'):format(settings.style))
        elseif not quiet then
            Open77.log.info(('the exit style was not given to player %d (%s): %s'):format(playerId, why, reason))
        end
        return false, reason
    end
    unavailableAt = nil
    styled[playerId] = now
    counts.styled = counts.styled + 1
    Open77.log.info(('player %d given the exit style %s (%s, revision %s)'):format(playerId, settings.style, why,
        tostring(reason)))
    return true, 'assigned'
end

--- A body sat down in an aircraft: the style, if it has none yet -- the
--- moment `ASSIGN = 'board'` gives it, and the last chance for `'join'` (a
--- player who was ready before this resource started).
function S.Seated(playerId, id, seat)
    local player = validPlayer(playerId)
    if player == nil or anim().off then return end
    if styled[player] ~= nil then return end
    S.EnsureStyle(player, ('seated in %s of %s'):format(tostring(seat), tostring(id)))
end

--- A player became ready: the style, when it is given on joining.
function S.Ready(playerId)
    local player = validPlayer(playerId)
    if player == nil or anim().off or anim().assign ~= 'join' then return end
    S.EnsureStyle(player, 'ready')
end

-- ── the others' view ─────────────────────────────────────────────────────────

local function setVisible(playerId, visible, why)
    local players = Open77.players
    if type(players) ~= 'table' or type(players.setVisible) ~= 'function' then
        once('visible', 'warn', 'no Open77.players.setVisible on this server: the others see the platform\'s own exit')
        return false
    end
    local read, ok, reason = pcall(players.setVisible, playerId, visible)
    if not read or ok ~= true then
        Open77.log.warn(('player %d could not be %s for the exit: %s'):format(playerId,
            visible and 'shown' or 'hidden', tostring(read and reason or ok)))
        return false
    end
    return true
end

local function show(playerId, why)
    local entry = hidden[playerId]
    if entry == nil then return end
    hidden[playerId] = nil
    setVisible(playerId, true, why)
    Open77.log.info(('player %d shown to the others again after %.1fs (%s)'):format(playerId,
        (M.Now() - entry.at) / 1000.0, why))
end

-- ── the exit and the clip ────────────────────────────────────────────────────

--- A seat of an aircraft was left (from `M.Exited`): the exit is remembered
--- for its clip, and the body hidden from the others until the clip starts.
-- @param playerId any
-- @param id any the hull
-- @param seat string
-- @param how string 'exiting' | 'left' | 'changed'
-- @param record string|nil
function S.Exited(playerId, id, seat, how, record)
    local player = validPlayer(playerId)
    local settings = anim()
    if player == nil or settings.off then return end
    local now = M.Now()
    -- A seat that changed hands is not this player stepping out.
    if how == 'changed' then return end
    -- A GAME WITHOUT THE CLIPS (1.7.2): the plain exit -- the others see it as
    -- it is, nothing waits for a step that game cannot draw.
    if noClips[player] ~= nil then
        counts.noClips = counts.noClips + 1
        Open77.log.info(('exit of player %d from %s of %s: plain -- its game has no AV animation package (%s)')
            :format(player, tostring(seat), tostring(id), noClips[player]))
        return
    end
    exits[player] = { id = id, seat = seat, record = record, at = now,
        clip = M.WalkOutClip(record, seat, settings) }
    -- The client already said there is no clip (its seat read is quicker than
    -- this occupancy event): nothing to hide.
    if early[player] ~= nil and now - early[player] < 3000 then
        early[player] = nil
        return
    end
    -- THE SCENE every screen near the exit draws (server/sync.lua): told of
    -- the exit now, the step waits for each of them to have the body out of
    -- its seat.
    if M.Sync ~= nil then
        local ran, failure = pcall(M.Sync.Begin, player, id, seat, record, exits[player].clip)
        if not ran then Open77.log.error('the exit scene could not begin: ' .. tostring(failure)) end
    end
    if settings.hide and hidden[player] == nil and M.ExitSettings().place then
        if setVisible(player, false, 'exit') then
            hidden[player] = { at = now, untilAt = now + settings.hideMax, why = how }
            counts.hidden = counts.hidden + 1
            Open77.log.info(('player %d hidden from the others for the exit from %s of %s (at most %.1fs)')
                :format(player, tostring(seat), tostring(id), settings.hideMax / 1000.0))
        end
    end
end

--- The seat the platform holds for this player, or nil.
local function seatOf(player)
    if type(Open77.vehicles) ~= 'table' or type(Open77.vehicles.getPlayerSeat) ~= 'function' then return nil end
    local read, seat = pcall(Open77.vehicles.getPlayerSeat, player)
    if read and type(seat) == 'table' and seat.vehicleId ~= nil then return seat end
    return nil
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

-- ── the plan, checked against the server's own hull ──────────────────────────
-- The client plans its walk-out on the hull as its engine draws it; that is not
-- always where the hull is (2.5 m off after a hop from the back seat, Staging,
-- 2026-10-28, 01:10:52 -- the clip started on nothing beside the open door).
-- The ask carries the plan, and before the clip plays for every viewer it is
-- held against the server's pose: the end point within `PLAN_METRES` of where
-- the server's hull puts it (else the client is sent that pose to plan on,
-- once), the door's step within the clip's reach of the end point's ground,
-- and the body, as the server has it, within `BODY_METRES` of the end point.

--- What to do with a clip ask's plan.
-- @param player integer
-- @param exit table the remembered exit `{ id, seat, record, clip }`
-- @param payload table the ask
-- @return string 'ok' | 'replan' | 'wait' | 'refuse'
-- @return string what was found, for the log (or the refusal's reason)
-- @return table|nil the server's pose `{ x, y, z, yaw }`, for a replan
-- @return string|nil for a wait: the refusal once it runs out
-- @return table|nil for an 'ok': the server's own plan
-- @return number|nil for a wait on a gliding hull (1.7.9): when the glide ends
function S.CheckPlan(player, exit, payload)
    local plan = type(payload.plan) == 'table' and payload.plan or nil
    if plan == nil then return 'ok', 'no plan in the ask (an older client)' end
    local at = pointOf(plan.at)
    if at == nil then return 'ok', 'no end point in the plan' end
    local api = Open77.vehicles
    if type(api) ~= 'table' or type(api.get) ~= 'function' then return 'ok', 'no vehicle read on this host' end
    local read, snapshot = pcall(api.get, exit.id)
    if not read or type(snapshot) ~= 'table' then return 'ok', 'the hull cannot be read' end
    local x, y, z = finite(snapshot.x), finite(snapshot.y), finite(snapshot.z)
    if (x == nil or y == nil or z == nil) and type(snapshot.position) == 'table' then
        x, y, z = finite(snapshot.position.x), finite(snapshot.position.y), finite(snapshot.position.z)
    end
    local yaw = finite(snapshot.yaw or snapshot.heading)
    if x == nil or y == nil or z == nil or yaw == nil then return 'ok', 'the server has no pose for the hull' end
    local settings = anim()
    local door = M.SeatDoor(exit.record, exit.seat)
    local width = door.out or M.Number(plan.width, 0.3, 15.0, settings.door)
    -- THE DOOR AS THAT GAME DRAWS IT: a client whose door slot it reads on the
    -- hull's other side plans on the hull turned round (client/walkout.lua) --
    -- the drawn door is the one the step must start on. Its plan is checked on
    -- the server's hull turned the same way, and said.
    local turned = plan.turned == true
    local r = math.rad(turned and (yaw + 180.0) or yaw)
    -- THE STEP TURNED ABOUT THE DOOR (1.6.2): a client whose door's step stood
    -- out of the clip's reach on a slope turns the step about the door
    -- (`STEP_TURNS`, bounded by `STEP_TURN_MAX`); checked on the server's hull
    -- turned the same.
    local stepTurn = M.StepTurn(plan.stepTurn)
    local own = M.WalkOutPlan({ x = x, y = y }, { x = -math.sin(r), y = math.cos(r) }, exit.seat, M.ExitSettings(),
        exit.clip, width, door, stepTurn)
    if own == nil then return 'ok', 'no plan of the server\'s own' end
    local pose = { x = x, y = y, z = z, yaw = yaw }
    local off = apart(own, at)
    local hull = pointOf(plan.hull)
    local hullText = hull ~= nil and ('%.1f m'):format(apart(hull, pose)) or 'not sent'
    if off > settings.planTolerance then
        return 'replan', ('its end point is %.2f m from where the server\'s hull puts it (the hull it planned on %s '
            .. 'from the server\'s%s)'):format(off, hullText, turned and ', turned round' or ''), pose
    end
    -- THE HULL STILL COMING DOWN ONTO ITS GEAR (1.7.9, server/land.lua): the
    -- step is played from the hull where it will stand, never from one still
    -- moving under it.
    local gliding = M.Land ~= nil and type(M.Land.Gliding) == 'function' and M.Land.Gliding(exit.id) or nil
    if gliding ~= nil then
        return 'wait', ('the hull is still coming down onto its gear (%.2f m over it, %.1fs more)'):format(
            math.max(0.0, (gliding.z or gliding.from) - gliding.to), math.max(0, gliding.endsAt - M.Now()) / 1000.0),
            nil, 'still_coming_down', nil, gliding.endsAt
    end
    -- The door's step over the end point's ground, on the server's hull.
    local ground = finite(plan.ground)
    local step = M.StepHeight(z, door, ground)
    -- The relaxed band (1.6.2): the client plays a step within it when no turn
    -- brings it within the clip's own.
    local lo, hi = M.StepBand(exit.clip, true)
    if step ~= nil and lo ~= nil and (step < lo or step > hi) then
        if M.Land ~= nil and type(M.Land.Waiting) == 'function' and M.Land.Waiting(exit.id) then
            return 'wait', ('the door\'s step is %.2f m over the end point and the hull is still to be set down on its '
                .. 'gear'):format(step), nil, ('step_out_of_reach:%.2f'):format(step)
        end
        return 'refuse', ('step_out_of_reach:%.2f'):format(step)
    end
    -- The body, as the server has it.
    local players = Open77.players
    if type(players) == 'table' and type(players.position) == 'function' then
        local got, body = pcall(players.position, player)
        local where = got and pointOf(body) or nil
        if where ~= nil and apart(where, at) > settings.bodyTolerance then
            return 'wait', ('the body is %.1f m from the clip\'s end point as the server has it'):format(apart(where, at)),
                nil, ('not_at_the_door:%.1f'):format(apart(where, at))
        end
    end
    -- What the client read of the body and the door before it asked (said, never obeyed).
    local seen = {}
    local facing, facingOff = finite(plan.facing), finite(plan.facingOff)
    if facing ~= nil then
        seen[#seen + 1] = ('the body facing %.0f deg (%.1f off the step\'s %.0f)%s'):format(facing, facingOff or 0, own.yaw,
            (tonumber(plan.turnedBack) or 0) > 0 and (', turned back %d time(s)'):format(tonumber(plan.turnedBack)) or '')
    end
    if type(plan.slot) == 'table' then
        local verdict = type(plan.slot.verdict) == 'string' and plan.slot.verdict:sub(1, 16) or '?'
        seen[#seen + 1] = ('its door slot %s %s (%.2f across, %.2f along)'):format(
            type(plan.slot.name) == 'string' and plan.slot.name:sub(1, 32) or '?',
            verdict == 'right' and 'where the plan has it' or (verdict == 'mirrored' and 'on the hull\'s other side'
                or 'off'), finite(plan.slot.x) or 0, finite(plan.slot.y) or 0)
    end
    if turned then seen[#seen + 1] = 'planned on the hull turned round, as that game draws its door' end
    if stepTurn ~= 0 then seen[#seen + 1] = ('the step turned %+.0f deg about the door'):format(stepTurn) end
    -- The door's step the clip's first frame stands on: on the server's hull.
    local doorAt = { x = own.door.x, y = own.door.y, z = door.step ~= nil and (z - door.step) or nil }
    return 'ok', ('the end point %.2f m from the server\'s plan, the hull it planned on %s from the server\'s, the '
        .. 'step %s%s'):format(off, hullText, step ~= nil and ('%.2f m up'):format(step) or 'not known',
        #seen > 0 and ('; ' .. table.concat(seen, '; ')) or ''), nil, nil,
        { x = own.x, y = own.y, z = finite(plan.at.z) or at.z, yaw = own.yaw, door = doorAt, turned = turned or nil }
end

--- The client's ask: play the exit clip now, or there is none.
-- @param playerId integer
-- @param payload table `{ id, clip, seat }` or `{ id, clip = false, why }`
-- @param again boolean|nil a pending ask looked at again (`S.Tend`)
-- @return table|nil the answer sent, for the suite (nil: no answer yet, or none owed)
function S.Request(playerId, payload, again)
    local player = validPlayer(playerId)
    if player == nil or type(payload) ~= 'table' then return nil end
    local settings = anim()
    local now = M.Now()
    local function answer(body)
        pcall(TriggerClientEvent, M.Event.WALKING, player, body)
        return body
    end
    if payload.clip == false then
        counts.none = counts.none + 1
        local why = tostring(payload.why or 'none'):sub(1, 60)
        if hidden[player] ~= nil then
            show(player, 'no exit clip: ' .. why)
        else
            early[player] = now
        end
        exits[player], pending[player] = nil, nil
        Open77.log.info(('player %d steps out without a clip (%s)'):format(player, why))
        if M.Sync ~= nil then pcall(M.Sync.Close, player, 'no clip: ' .. why) end
        return nil
    end
    if not again then
        counts.asked = counts.asked + 1
        -- A second ask replaces one still waiting for the seat.
        pending[player] = nil
    end
    local function refuse(reason)
        counts.refused = counts.refused + 1
        show(player, 'exit clip refused: ' .. reason)
        exits[player], pending[player] = nil, nil
        Open77.log.info(('exit clip for player %d refused: %s'):format(player, reason))
        if M.Sync ~= nil then pcall(M.Sync.Close, player, 'the clip was refused: ' .. reason) end
        return answer({ ok = false, reason = reason })
    end
    if settings.off then return refuse('off') end
    local exit = exits[player]
    if exit == nil then return refuse('no_exit') end
    if now - exit.at > settings.window then return refuse('too_late') end
    if payload.id == nil or not M.SameHull(payload.id, exit.id) then return refuse('wrong_hull') end
    local seat = seatOf(player)
    if seat ~= nil then
        if seat.exiting ~= true then return refuse('seated') end
        -- THE SEAT IS STILL BEING LEFT: the platform holds it until the leaving
        -- game confirms its exit, and the host plays no clip on a body in a
        -- vehicle. The ask waits for the seat, every tenth of a second, at most
        -- `PENDING_MS` -- inside the time the client waits for its answer.
        local wait = pending[player]
        if wait == nil or wait.why ~= 'seat' then
            pending[player] = { payload = payload, at = now, untilAt = now + settings.pending, why = 'seat' }
            Open77.log.info(('exit clip for player %d waits for the seat (%s of %s is still being left), at most '
                .. '%d ms'):format(player, tostring(seat.seat), tostring(seat.vehicleId), settings.pending))
            return nil
        end
        if now < wait.untilAt then return nil end
        return refuse('still_seated')
    end
    local waited = pending[player]
    pending[player] = nil
    if waited ~= nil and waited.why == 'seat' then
        Open77.log.info(('exit clip for player %d: the seat is free after %d ms'):format(player, now - waited.at))
    end
    if type(Open77.players) == 'table' and type(Open77.players.isDead) == 'function' then
        local read, dead = pcall(Open77.players.isDead, player)
        if read and dead == true then return refuse('down') end
    end
    -- THE PLAN, against the server's own hull (`S.CheckPlan`).
    local verdict, found, pose, after, ownPlan, glideEnds = S.CheckPlan(player, exit, payload)
    if verdict == 'replan' then
        exit.replans = (exit.replans or 0) + 1
        if exit.replans > 1 then return refuse('hull_elsewhere') end
        counts.replans = counts.replans + 1
        Open77.log.info(('exit clip for player %d: %s -- the client is sent the server\'s hull (%.1f, %.1f, %.1f, '
            .. 'heading %.0f) to plan on'):format(player, found, pose.x, pose.y, pose.z, pose.yaw))
        return answer({ ok = false, replan = true, reason = 'hull_elsewhere', hull = pose })
    end
    if verdict == 'wait' then
        local since, untilAt = now, now + settings.pending
        local landHeld = waited ~= nil and waited.landHeld or nil
        if waited ~= nil and waited.why == 'plan' then since, untilAt = waited.at, waited.untilAt end
        -- A HULL GLIDING DOWN (1.7.9): waited for until it stands on its gear
        -- (and `PENDING_MS` more for the step's own check), the client told
        -- once how long -- its ask stays in flight that long.
        if glideEnds ~= nil and glideEnds + settings.pending > untilAt then
            untilAt = glideEnds + settings.pending
            if landHeld == nil then
                landHeld = now
                Open77.log.info(('exit clip for player %d is held until the hull stands on its gear, %.1fs at most')
                    :format(player, (untilAt - now) / 1000.0))
                answer({ ok = false, hold = true, reason = 'landing', waitMs = math.floor(untilAt - now),
                    waitingFor = 'the hull coming down onto its gear' })
            end
        end
        if now >= untilAt then return refuse(after or 'plan_not_met') end
        if waited == nil or waited.why ~= 'plan' then
            Open77.log.info(('exit clip for player %d waits: %s (at most %d ms)'):format(player, found,
                math.floor(untilAt - now)))
        end
        pending[player] = { payload = payload, at = since, untilAt = untilAt, why = 'plan', landHeld = landHeld }
        return nil
    end
    if verdict == 'refuse' then return refuse(found) end
    local syncing = waited ~= nil and waited.why == 'sync'
    if not syncing then
        Open77.log.info(('exit clip for player %d: the plan holds%s -- %s'):format(player,
            (waited ~= nil and waited.why == 'plan') and (' after %d ms'):format(now - waited.at) or '', found))
    end
    -- THE OTHER SCREENS (server/sync.lua): the step starts once every screen
    -- near the exit has the body out of its seat -- each game's own dismount
    -- holds it there for up to 2.5 s -- under this player's fade, at most
    -- `SYNC.HOLD_MAX_MS` after the ask and never past `SYNC.WAIT_MAX_MS` after
    -- the exit. Looked at again every tenth of a second (`S.Tend`).
    if M.Sync ~= nil then
        local gate, waitMs, word = M.Sync.Gate(player, now)
        if gate == 'hold' then
            pending[player] = { payload = payload, at = syncing and waited.at or now, untilAt = now + waitMs,
                why = 'sync' }
            if not syncing then
                Open77.log.info(('exit clip for player %d is held for the other screens, %.1fs at most: %s')
                    :format(player, waitMs / 1000.0, word))
                -- The client's ask stays in flight: told how long it may take.
                answer({ ok = false, hold = true, reason = 'syncing', waitMs = math.floor(waitMs), waitingFor = word })
            end
            return nil
        end
        if syncing then
            Open77.log.info(('exit clip for player %d: held %d ms for the other screens (%s)'):format(player,
                now - waited.at, word))
        end
    end
    local clip = exit.clip
    if payload.clip ~= clip then
        Open77.log.info(('player %d named the exit clip %s; this server plays %s for %s of %s')
            :format(player, tostring(payload.clip), clip, tostring(exit.seat), tostring(exit.record)))
    end
    local styledOk, styleWhy = S.EnsureStyle(player, 'the exit')
    if not styledOk then return refuse(styleWhy) end
    local loco = Open77.locomotion
    if type(loco.playClip) ~= 'function' then return refuse('locomotion_unavailable_on_this_host') end
    local read, ok, handle = pcall(loco.playClip, player, clip,
        { speed = 1.0, blendInMs = settings.blendIn, blendOutMs = settings.blendOut })
    if not read then return refuse('error: ' .. tostring(ok)) end
    if ok ~= true then return refuse(tostring(handle)) end
    counts.played = counts.played + 1
    exits[player] = nil
    local ms = math.floor((M.WALK_CLIPS[clip] and M.WALK_CLIPS[clip].seconds or 4.3) * 1000)
    -- Where the step ends: the server's own plan on its own hull (what every
    -- screen should draw), else the end point the client asked with.
    local plan = type(payload.plan) == 'table' and payload.plan or {}
    local endAt = ownPlan or pointOf(plan.at)
    local sceneSeq, hullPose = nil, nil
    local doorAt = ownPlan ~= nil and ownPlan.door or nil
    local stepYaw = ownPlan ~= nil and ownPlan.yaw or finite(plan.yaw)
    if M.Sync ~= nil then
        local ran, number, held = pcall(M.Sync.Started, player, { clip = clip, durationMs = ms,
            at = endAt ~= nil and { x = endAt.x, y = endAt.y, z = endAt.z } or nil,
            yaw = stepYaw, door = doorAt, turned = ownPlan ~= nil and ownPlan.turned or nil })
        if ran then
            sceneSeq, hullPose = number, held
        else
            Open77.log.error('the exit scene could not be started: ' .. tostring(number))
        end
    end
    show(player, 'the exit clip started')
    Open77.log.info(('exit clip %s playing for player %d (%.1fs after the seat was left, %.1fs long, handle %s)')
        :format(clip, player, (now - exit.at) / 1000.0, ms / 1000.0, tostring(handle)))
    -- THE DOOR STAYS OPEN THROUGH THE CLIP: the exit opened it for
    -- `EXIT.DOOR_HOLD_MS`, and a slow game -- which waits for its third person
    -- -- starts the clip late.
    if type(M.HoldExitDoor) == 'function' then
        local held, failure = pcall(M.HoldExitDoor, exit.id, exit.record, exit.seat, ms + settings.doorAfter,
            'exit clip')
        if not held then Open77.log.error('the door could not be held open for the exit clip: ' .. tostring(failure)) end
    end
    return answer({ ok = true, clip = clip, durationMs = ms, scene = sceneSeq, hull = hullPose,
        at = endAt ~= nil and { x = endAt.x, y = endAt.y, z = endAt.z } or nil, yaw = stepYaw, door = doorAt })
end

--- The asks waiting for their seat, the hides that outlived their ceiling,
--- exits nobody asked for, and styles refused for now.
function S.Tend()
    local now = M.Now()
    local settings = anim()
    for player, wait in pairs(retry) do
        if now >= wait.nextAt then
            if now - wait.since > settings.styleRetryMax then
                retry[player] = nil
                Open77.log.warn(('the exit style was still refused for player %d after %.0fs (%s, %d asks): left for '
                    .. 'the first boarding, whose third-person body is then rebuilt at the key'):format(player,
                    (now - wait.since) / 1000.0, wait.reason, wait.tries))
            else
                wait.tries = wait.tries + 1
                wait.nextAt = now + settings.styleRetry
                counts.retried = counts.retried + 1
                -- A line every fifteenth ask (30 s), not every one.
                local ran, failure = pcall(S.EnsureStyle, player, ('asked again, %.0fs after %s'):format(
                    (now - wait.since) / 1000.0, wait.reason), wait.tries % 15 ~= 0)
                if not ran then
                    retry[player] = nil
                    Open77.log.error('the exit style\'s next ask failed: ' .. tostring(failure))
                end
            end
        end
    end
    for player, wait in pairs(pending) do
        local ran, failure = pcall(S.Request, player, wait.payload, true)
        if not ran then
            pending[player] = nil
            Open77.log.error('an exit clip waiting for its seat failed: ' .. tostring(failure))
            show(player, 'error')
        end
    end
    for player, entry in pairs(hidden) do
        if now >= entry.untilAt then show(player, 'the ceiling') end
    end
    local window = anim().window
    for player, exit in pairs(exits) do
        if now - exit.at > window then exits[player] = nil end
    end
    for player, at in pairs(early) do
        if now - at > 3000 then early[player] = nil end
    end
end

function S.Forget(playerId)
    local player = validPlayer(playerId)
    if player == nil then return end
    exits[player], hidden[player], early[player], styled[player], toldStyle[player] = nil, nil, nil, nil, nil
    pending[player], noClips[player], retry[player] = nil, nil, nil
end

--- A client that has just started knows nothing: it is told its style again.
--- With `ASSIGN = 'join'` a player who has none yet is given it now: one who
--- was ready before this resource started (a restart) hears no ready again,
--- and the boarding step plays on it before any seat (1.7.0).
function S.Hello(playerId, info)
    local player = validPlayer(playerId)
    if player == nil then return end
    -- Whether its game can draw the clips (1.7.2): a known "no" makes its
    -- exits plain; a "yes", or a client that does not say (older), does not.
    local clips = type(info) == 'table' and type(info.anim) == 'table' and info.anim or nil
    if clips ~= nil and clips.known == true and clips.ok ~= true then
        noClips[player] = type(clips.reason) == 'string' and clips.reason:gsub('[^%w_%-%.:]', ''):sub(1, 80)
            or 'not registered'
    else
        noClips[player] = nil
    end
    toldStyle[player] = nil
    if styled[player] ~= nil then return tellStyle(player, true) end
    if not anim().off and anim().assign == 'join' then S.EnsureStyle(player, 'its client said hello') end
end

function S.Status()
    local n = 0
    for _ in pairs(hidden) do n = n + 1 end
    local s = 0
    for _ in pairs(styled) do s = s + 1 end
    local w = 0
    for _ in pairs(pending) do w = w + 1 end
    local without = 0
    for _ in pairs(noClips) do without = without + 1 end
    local r = 0
    for _ in pairs(retry) do r = r + 1 end
    return { asked = counts.asked, played = counts.played, refused = counts.refused, none = counts.none,
        hiddenNow = n, styled = s, waiting = w, replans = counts.replans, plainNoClips = counts.noClips,
        playersWithoutClips = without, styleRetrying = r, styleRetries = counts.retried }
end

function S.Start()
    RegisterNetEvent(M.Event.WALKOUT, function(payload)
        local player = validPlayer(source)
        if player == nil or type(payload) ~= 'table' then return end
        if M.Cooling(player, 'walkout', 250) then return end
        local ran, failure = pcall(S.Request, player, payload)
        if not ran then
            Open77.log.error('an exit clip ask failed: ' .. tostring(failure))
            show(player, 'error')
        end
    end)
    AddEventHandler('onPlayerReady', function(playerId)
        local ran, failure = pcall(S.Ready, playerId)
        if not ran then Open77.log.error('the exit style at ready failed: ' .. tostring(failure)) end
    end)
    local settings = anim()
    Open77.log.info(('exit clip: %s'):format(settings.off and 'off'
        or (('style %s given on %s, clip %s / %s, others %s, view held %s')
            :format(settings.style, settings.assign, settings.clip, settings.mirrorClip,
                settings.hide and 'see no platform exit' or 'see the platform exit',
                settings.holdView and 'in third person' or 'by the platform'))))
end

function S.Stop()
    -- The host releases every visibility hold and style of a stopped resource;
    -- this is the polite version, with a line for each.
    for player in pairs(hidden) do show(player, 'the resource stopped') end
    exits, hidden, early, styled, toldStyle, pending, noClips, retry = {}, {}, {}, {}, {}, {}, {}, {}
end
