-- =============================================================================
-- open77_avdoor -- server/sync.lua
-- =============================================================================
-- THE EXIT, ONE SCENE FOR EVERY SCREEN, and what each screen drew of it.
--
-- WHY. Every game draws an exit on its own. The exiting player's game plays
-- the step on its stand-in body; every other game near it first runs the
-- platform's own dismount for that body -- which holds it in its seat for up to
-- 2.5 s (`Remote seat dismount released: player=2 afterMs=2811`, the laptop,
-- XyberRP Staging, 2026-10-28) -- and then plays the step on its copy of the
-- body. A fast game asked for its step 2.2 s after the exit: the slower screen
-- still drew the body in the seat as the step began, and saw it pop out half a
-- second into it. Nothing in the logs said so: only the screens knew.
--
-- WHAT. As a seat of an aircraft empties, every other player within
-- `SYNC.RANGE_METRES` of the hull is told of the exit (`SCENE`, phase `exit`).
-- Each of those screens watches its own copy of the exiting body and says when
-- it is out of its seat (`SCENE_READY`, client/sync.lua). The step starts once
-- every one of them has -- held under the exiting player's curtain, at most
-- `HOLD_MAX_MS` after the exiting game asked and never past `WAIT_MAX_MS` after
-- the exit (server/walkout.lua, `S.Request`). A screen that draws the AV more
-- than `HULL_METRES` from the server's pose gets the server's pose again
-- (`setTransform` on an empty, unposed hull, once an exit).
--
-- THE LOGGER. As the step starts every screen is told (`SCENE`, phase
-- `start`), and every screen that drew it -- the exiting player's own included
-- -- reports what it drew a moment into the step and as it ended
-- (`SCENE_REPORT`): the body against the step's end point, in its seat or not,
-- the AV against the server's pose, the view, the frame rate. Each report is a
-- line here, a warning for anything wrong; every exit ends with a verdict.
-- Reports are evidence, never commands: nothing a client says moves anything
-- but the one re-publish of the server's OWN pose.
--
-- THE STEP AGAINST THE DOOR (1.5.0). The 1.4.0 logger said "nothing wrong"
-- for a step played with the body turned round (Staging, 2026-10-28,
-- 03:15:44): it measured where the body stood, not the way it faced. Each
-- report now carries the heading the screen draws the body at against the
-- step's, the step's first frame -- from that place and that heading --
-- against the door's step on the AV as that screen draws it, on the ground or
-- not, a weapon drawn or not, the age of the movement a remote body is drawn
-- with, and for another player's body its hips a moment into the step (on its
-- feet's point: the step was not drawn there).
--
-- WHO IS TOLD, WHO IS WAITED FOR. Every other player near the exit is told of
-- it; only a screen whose client said hello is waited for (a hello may be
-- lost while a game loads, and a client that is not there cannot answer). A
-- word from a screen that never said hello is taken as its hello.
-- =============================================================================

local M = AvDoor
M.Sync = {}
local Sync = M.Sync

-- Scenes by the exiting player's id.
local scenes = {}
local seq = 0

-- The players whose client half of this resource said hello (it is running,
-- and can answer): by id, when. A player whose client never did is not waited for.
local hello = {}

-- What happened, for the status line.
local counts = { scenes = 0, held = 0, heldMs = 0, late = 0, reports = 0, problems = 0, republished = 0, verdicts = 0,
    lateHellos = 0 }

-- A body's hips this close to its feet's point a moment into the step: the
-- step was not drawn on that screen (its first frame stands them 2.5 m away).
local HIPS_DRAWN_METRES = 0.5

local function cfg() return M.SyncSettings() end

--- What a scene is called in the log: an exit, or a boarding step (1.7.0).
local function word(scene)
    return scene ~= nil and scene.kind == 'enter' and 'boarding' or 'exit'
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
    local x, y, z = finite(value.x or value[1]), finite(value.y or value[2]), finite(value.z or value[3])
    if x == nil or y == nil then return nil end
    return { x = x, y = y, z = z }
end

local function apart(a, b)
    local dx, dy = a.x - b.x, a.y - b.y
    return math.sqrt(dx * dx + dy * dy)
end

local function text(value, limit)
    if type(value) ~= 'string' then return nil end
    return value:sub(1, limit or 80)
end

--- The hull's pose as the server holds it: `{ x, y, z, yaw }`, and the snapshot.
local function poseOf(id)
    local api = Open77.vehicles
    if type(api) ~= 'table' or type(api.get) ~= 'function' then return nil, nil end
    local read, snapshot = pcall(api.get, id)
    if not read or type(snapshot) ~= 'table' then return nil, nil end
    local x, y, z = finite(snapshot.x), finite(snapshot.y), finite(snapshot.z)
    if (x == nil or y == nil or z == nil) and type(snapshot.position) == 'table' then
        x, y, z = finite(snapshot.position.x), finite(snapshot.position.y), finite(snapshot.position.z)
    end
    if x == nil or y == nil or z == nil then return nil, snapshot end
    return { x = x, y = y, z = z, yaw = finite(snapshot.yaw or snapshot.heading) or 0.0 }, snapshot
end
Sync.PoseOf = poseOf

--- Where a player stands, and their bucket.
local function bodyOf(playerId)
    local players = Open77.players
    if type(players) ~= 'table' or type(players.position) ~= 'function' then return nil, 0 end
    local read, where = pcall(players.position, playerId)
    if not read or type(where) ~= 'table' then return nil, 0 end
    return pointOf(where), tonumber(where.bucket) or 0
end

--- Every other player within `range` of a point, in that bucket, nearest first.
local function viewersNear(player, at, bucket, range)
    local players = Open77.players
    if type(players) ~= 'table' or type(players.all) ~= 'function' then return {} end
    local listed, ids = pcall(players.all)
    local out = {}
    for _, raw in ipairs(listed and type(ids) == 'table' and ids or {}) do
        local id = validPlayer(raw)
        if id ~= nil and id ~= player then
            local where, b = bodyOf(id)
            if where ~= nil and b == bucket then
                local dz = (where.z or 0) - (at.z or 0)
                local metres = math.sqrt(apart(where, at) ^ 2 + dz * dz)
                if metres <= range then out[#out + 1] = { id = id, metres = metres } end
            end
        end
    end
    table.sort(out, function(a, b) return a.metres < b.metres end)
    return out
end

local function sceneBySeq(number)
    number = tonumber(number)
    if number == nil then return nil end
    for _, scene in pairs(scenes) do
        if scene.seq == number then return scene end
    end
    return nil
end

local function viewerList(scene, ids)
    local parts = {}
    for _, id in ipairs(ids or scene.order) do
        local v = scene.viewers[id]
        parts[#parts + 1] = ('player %d%s'):format(id, v ~= nil and (' (%.0f m)'):format(v.metres) or '')
    end
    return table.concat(parts, ', ')
end

local function fpsText(fps)
    local value = finite(fps)
    if value == nil then return 'frame rate not measured' end
    return ('%.1f fps'):format(value)
end

local function problem(scene, line)
    scene.problems[#scene.problems + 1] = line
    counts.problems = counts.problems + 1
end

-- ── the scene ────────────────────────────────────────────────────────────────

--- A seat of an aircraft was left (server/walkout.lua, `S.Exited`): the scene
--- every nearby screen draws.
-- @param playerId any who stepped out
-- @param id any the hull
-- @param seat string|nil
-- @param record string|nil
-- @param clip string|nil the clip this server plays for that seat
-- @return table|nil the scene
function Sync.Begin(playerId, id, seat, record, clip)
    local c = cfg()
    if c.off then return nil end
    local player = validPlayer(playerId)
    if player == nil or id == nil then return nil end
    local now = M.Now()
    -- A scene of this player that never got its step (the platform's exit and
    -- a new one in quick succession): closed, and the new one replaces it.
    if scenes[player] ~= nil then Sync.Close(player, 'a new exit began') end
    local pose = poseOf(id)
    local body, bucket = bodyOf(player)
    local centre = pose or body
    seq = seq + 1
    local scene = {
        seq = seq, player = player, id = id, key = M.KeyOf(id), seat = seat, record = record, clip = clip,
        at = now, pose = pose, viewers = {}, order = {}, reports = {}, problems = {}, expect = {},
    }
    local silent, waited = {}, {}
    if centre ~= nil then
        for _, v in ipairs(viewersNear(player, centre, bucket, c.range)) do
            -- EVERY SCREEN NEAR IT IS TOLD; only one whose client said hello is
            -- waited for (no client half running there cannot answer, and a
            -- hello lost while the game loaded is said again -- its word here
            -- is taken as its hello).
            local isWaited = hello[v.id] ~= nil
            scene.viewers[v.id] = { id = v.id, metres = v.metres, waited = isWaited }
            scene.order[#scene.order + 1] = v.id
            pcall(TriggerClientEvent, M.Event.SCENE, v.id, { scene = seq, phase = 'exit', player = player,
                id = scene.key, seat = seat, clip = clip, hull = pose, record = record })
            if isWaited then
                waited[#waited + 1] = v.id
            else
                silent[#silent + 1] = ('player %d (%.0f m)'):format(v.id, v.metres)
            end
        end
    end
    scenes[player] = scene
    counts.scenes = counts.scenes + 1
    Open77.log.info(('exit %d of player %d (%s of %s): %s%s'):format(seq, player, tostring(seat), scene.key,
        #waited == 0 and (#silent == 0 and 'no other screen is near it' or 'no screen near it is waited for')
            or ('%d other screen(s) draw it: %s; the step waits for them to have the body out of its seat')
                :format(#waited, viewerList(scene, waited)),
        #silent > 0 and ('; not waited for (no open77_avdoor client said hello): %s -- told all the same')
            :format(table.concat(silent, ', ')) or ''))
    return scene
end

--- THE BOARDING STEP, ONE SCENE TOO (1.7.0, server/enter.lua). No seat to wait
--- for -- the body stands outside the AV -- so it starts as it is played:
--- every screen near it is told (`SCENE`, phase `start`, kind `enter`) and
--- reports what it drew, as for an exit: the body against the step's first
--- spot, its heading against the step's, on its feet, the step's last frame
--- against the door as that screen draws the AV, the hips as the step ends;
--- and every boarding ends with a verdict.
-- @param playerId any
-- @param info table `{ id, seat, record, clip, durationMs, at, yaw, door }`
-- @return integer|nil the scene's number
-- @return table|nil the server's pose of the hull
function Sync.Boarding(playerId, info)
    local c = cfg()
    if c.off then return nil end
    local player = validPlayer(playerId)
    if player == nil or type(info) ~= 'table' or info.id == nil then return nil end
    if scenes[player] ~= nil then Sync.Close(player, 'a boarding began') end
    local pose = poseOf(info.id)
    local body, bucket = bodyOf(player)
    local centre = pose or body
    seq = seq + 1
    local scene = {
        seq = seq, kind = 'enter', player = player, id = info.id, key = M.KeyOf(info.id), seat = info.seat,
        record = info.record, clip = info.clip, at = M.Now(), pose = pose, viewers = {}, order = {}, reports = {},
        problems = {}, expect = {},
    }
    if centre ~= nil then
        for _, v in ipairs(viewersNear(player, centre, bucket, c.range)) do
            scene.viewers[v.id] = { id = v.id, metres = v.metres, waited = hello[v.id] ~= nil }
            scene.order[#scene.order + 1] = v.id
        end
    end
    scenes[player] = scene
    counts.scenes = counts.scenes + 1
    return Sync.Started(player, { clip = info.clip, durationMs = info.durationMs, at = info.at, yaw = info.yaw,
        door = info.door })
end

--- A client half of this resource started on a player's game (`HELLO`): that
--- screen can answer, and is waited for from now on.
function Sync.Hello(playerId)
    local player = validPlayer(playerId)
    if player ~= nil then hello[player] = M.Now() end
end

--- A screen answered an exit without its client having said hello: its word is
--- its hello (the hello was lost), and it is waited for from the next exit on.
local function heardFrom(scene, viewer, what)
    if hello[viewer] ~= nil then return end
    hello[viewer] = M.Now()
    counts.lateHellos = counts.lateHellos + 1
    Open77.log.info(('exit %d of player %d: player %d\'s client %s without having said hello: taken as its hello, its '
        .. 'screen is waited for from the next exit on'):format(scene.seq, scene.player, viewer, what))
end

--- The scene of a player's exit, or nil.
function Sync.SceneOf(playerId)
    return scenes[validPlayer(playerId) or -1]
end

--- A screen's word: the exiting body is out of its seat there (or why not).
-- @param viewerId any who says it (`source`)
-- @param payload table `{ scene, free, seen, why, hullOff, fps, seatedMs }`
-- @return boolean whether it was taken
function Sync.Ready(viewerId, payload)
    local viewer = validPlayer(viewerId)
    if viewer == nil or type(payload) ~= 'table' then return false end
    local scene = sceneBySeq(payload.scene)
    if scene == nil then return false end
    local v = scene.viewers[viewer]
    if v == nil or v.ready ~= nil then return false end
    local now = M.Now()
    if not v.waited then heardFrom(scene, viewer, 'answered the exit') end
    v.ready = now
    v.free = payload.free == true
    v.seen = payload.seen ~= false
    v.why = text(payload.why)
    v.hullOff = finite(payload.hullOff)
    v.fps = finite(payload.fps)
    local after = (now - scene.at) / 1000.0
    local what
    if not v.seen then
        what = ('does not draw player %d (%s): nothing to wait for there'):format(scene.player, v.why or 'not streamed there')
    elseif v.free then
        what = ('drew player %d out of the seat %.1fs after the exit'):format(scene.player, after)
    else
        what = ('still drew player %d in the seat %.1fs after the exit (%s)'):format(scene.player, after,
            v.why or 'its own dismount had not let go')
    end
    local line = ('exit %d of player %d: player %d\'s screen %s%s, %s'):format(scene.seq, scene.player, viewer, what,
        v.hullOff ~= nil and (', the AV %.2f m from the server\'s pose'):format(v.hullOff) or '', fpsText(v.fps))
    if v.seen and not v.free then
        counts.late = counts.late + 1
        problem(scene, ('player %d\'s screen still drew player %d in the seat when the step was due'):format(viewer,
            scene.player))
        Open77.log.warn(line)
    else
        Open77.log.info(line)
    end
    -- THE AV, IN SYNC: a screen that draws it off the server's pose.
    if v.hullOff ~= nil and v.hullOff > cfg().hull then Sync.Republish(scene, viewer, v.hullOff) end
    return true
end

--- The server's own pose of the hull published again, so a screen that drew it
--- elsewhere draws it where every other one does. An empty, unposed hull only,
--- once an exit.
-- @return boolean whether it was done
function Sync.Republish(scene, viewer, off)
    local c = cfg()
    if not c.republish or scene.republished then return false end
    local pose, snapshot = poseOf(scene.id)
    if pose == nil or type(snapshot) ~= 'table' then return false end
    -- Anybody listed in a seat -- a seat still being left too -- is aboard.
    local aboard = 0
    for _, occupant in ipairs(type(snapshot.occupants) == 'table' and snapshot.occupants or {}) do
        if type(occupant) == 'table' then aboard = aboard + 1 end
    end
    local frozen = M.FrozenOf ~= nil and M.FrozenOf(snapshot, scene.id) or snapshot.frozen == true
    if aboard > 0 or frozen then
        Open77.log.info(('exit %d of player %d: player %d\'s screen draws the AV %.2f m off the server\'s pose; not '
            .. 're-published (%s)'):format(scene.seq, scene.player, viewer, off,
            aboard > 0 and ('%d aboard'):format(aboard) or 'a resource poses it'))
        return false
    end
    local api = Open77.vehicles
    if type(api) ~= 'table' or type(api.setTransform) ~= 'function' then return false end
    scene.republished = true
    -- `yaw` is passed on purpose: an absent heading is read as 0.
    local called, moved, why = pcall(api.setTransform, scene.id, { x = pose.x, y = pose.y, z = pose.z, yaw = pose.yaw })
    if called and moved == true then
        counts.republished = counts.republished + 1
        Open77.log.info(('exit %d of player %d: aircraft %s re-published where the server has it (%.1f, %.1f, %.1f, '
            .. 'heading %.0f): player %d\'s screen drew it %.2f m away'):format(scene.seq, scene.player, scene.key,
            pose.x, pose.y, pose.z, pose.yaw, viewer, off))
        return true
    end
    Open77.log.warn(('exit %d of player %d: aircraft %s could not be re-published: %s'):format(scene.seq, scene.player,
        scene.key, tostring(called and (why or moved) or moved)))
    return false
end

--- Whether the step may start now (server/walkout.lua asks before it plays).
-- @param playerId any
-- @param now number|nil
-- @return string 'go' | 'hold'
-- @return number|nil for 'hold': the most the server still waits, ms
-- @return string what it waits for, or what it found
function Sync.Gate(playerId, now)
    local c = cfg()
    local scene = scenes[validPlayer(playerId) or -1]
    if c.off or scene == nil then return 'go', nil, 'no scene' end
    now = now or M.Now()
    scene.askAt = scene.askAt or now
    local waiting, waited = {}, 0
    for _, id in ipairs(scene.order) do
        local v = scene.viewers[id]
        if v ~= nil and v.waited then
            waited = waited + 1
            if v.ready == nil then waiting[#waiting + 1] = id end
        end
    end
    if #waiting == 0 then
        return 'go', nil, waited == 0 and 'no other screen' or ('%d other screen(s) ready'):format(waited)
    end
    local cap = math.min(scene.at + c.waitMax, scene.askAt + c.holdMax)
    if now >= cap then
        for _, id in ipairs(waiting) do
            problem(scene, ('player %d\'s screen never said it had player %d out of the seat'):format(id, scene.player))
        end
        Open77.log.warn(('exit %d of player %d: the step starts without a word from %s, %.1fs after the exit'):format(
            scene.seq, scene.player, viewerList(scene, waiting), (now - scene.at) / 1000.0))
        return 'go', nil, 'without ' .. viewerList(scene, waiting)
    end
    return 'hold', cap - now, ('waiting for %s to have the body out of its seat'):format(viewerList(scene, waiting))
end

--- The step started (server/walkout.lua): every screen is told, to look.
-- @param playerId any
-- @param info table `{ clip, durationMs, at = { x, y, z }, yaw, door = { x, y, z } }`
-- @return number|nil the scene's number
-- @return table|nil the server's pose of the hull
function Sync.Started(playerId, info)
    local scene = scenes[validPlayer(playerId) or -1]
    if scene == nil then return nil, nil end
    local now = M.Now()
    scene.startAt = now
    scene.info = info
    scene.durationMs = math.floor(finite(info and info.durationMs) or 4300)
    scene.heldMs = scene.askAt ~= nil and (now - scene.askAt) or 0
    if scene.heldMs > 50 then
        counts.held = counts.held + 1
        counts.heldMs = counts.heldMs + scene.heldMs
    end
    local pose = poseOf(scene.id) or scene.pose
    scene.startPose = pose
    -- The reports the verdict waits for: the exiting player's own two, and two
    -- from every screen that draws the body (one that said it does not may
    -- still report, and is logged, but is not waited for).
    scene.expect = { [scene.player .. ':start'] = true, [scene.player .. ':end'] = true }
    for _, id in ipairs(scene.order) do
        local v = scene.viewers[id]
        -- The reports of every screen that is waited for or answered, and draws
        -- the body (one that said it does not may still report, and is logged).
        if v ~= nil and (v.waited or v.ready ~= nil) and v.seen ~= false then
            scene.expect[id .. ':start'], scene.expect[id .. ':end'] = true, true
        end
        pcall(TriggerClientEvent, M.Event.SCENE, id, { scene = scene.seq, phase = 'start', player = scene.player,
            id = scene.key, clip = info and info.clip, durationMs = scene.durationMs, at = info and info.at,
            yaw = info and info.yaw, door = info and info.door, turned = info and info.turned or nil, hull = pose,
            seat = scene.seat, record = scene.record, kind = scene.kind })
    end
    local door = type(info) == 'table' and pointOf(info.door) or nil
    local enter = scene.kind == 'enter'
    Open77.log.info(('%s %d of player %d: the step starts %.1fs after the %s%s, for %d other screen(s)%s'):format(
        word(scene), scene.seq, scene.player, (now - scene.at) / 1000.0, enter and 'key' or 'exit',
        scene.heldMs > 50 and (', held %.1fs for the other screens'):format(scene.heldMs / 1000.0) or '',
        #scene.order, (type(info) == 'table' and finite(info.yaw) ~= nil and door ~= nil)
            and ('; facing %.0f deg, its %s frame %s at %.1f, %.1f'):format(finite(info.yaw),
                enter and 'last' or 'first', M.SeatClip(info.clip) and 'in the seat' or 'on the door', door.x, door.y)
            or ''))
    return scene.seq, pose
end

--- The reports the verdict waits for, and how many of them came.
-- @return integer got
-- @return integer expected
local function expectedReports(scene)
    local got, expected = 0, 0
    for key in pairs(scene.expect) do
        expected = expected + 1
        if scene.reports[key] ~= nil then got = got + 1 end
    end
    return got, expected
end

--- A screen's report of what it drew of the step.
-- @param reporterId any (`source`)
-- @param payload table `{ scene, phase, seen, mounted, workspot, off, hullOff, fps, view, body, orbit }`
-- @return boolean whether it was taken
function Sync.Report(reporterId, payload)
    local reporter = validPlayer(reporterId)
    if reporter == nil or type(payload) ~= 'table' then return false end
    local scene = sceneBySeq(payload.scene)
    if scene == nil or scene.startAt == nil then return false end
    local own = reporter == scene.player
    if not own and scene.viewers[reporter] == nil then return false end
    local phase = payload.phase == 'end' and 'end' or 'start'
    local key = reporter .. ':' .. phase
    if scene.reports[key] ~= nil then return false end
    scene.reports[key] = true
    counts.reports = counts.reports + 1
    if not own then heardFrom(scene, reporter, 'reported the step') end
    local c = cfg()
    local parts, wrong = {}, {}
    local off, hullOff = finite(payload.off), finite(payload.hullOff)
    local drawn = own or payload.seen ~= false
    -- A boarding step (1.7.0) starts where the body stands and ends in the
    -- door: its spot is where it starts, its hips leave it late, its door end
    -- is its last frame.
    local enter = scene.kind == 'enter'
    local spotWord = enter and 'the step\'s first spot' or 'the step\'s end point'
    local hipsPhase = enter and 'end' or 'start'
    -- A seat clip (1.7.7) ends in the seat: its last frame against the seat.
    local doorWord = M.SeatClip(scene.clip) and 'the seat' or 'the door'
    -- A boarding its own screen saw seated before the step's last sample
    -- (1.7.5): the seat came first, as it does near the clip's end at a low
    -- frame rate -- the step's end, not a step gone wrong.
    -- 1.7.8: any screen's -- the seat comes as the stepping screen puts its
    -- stand-in away, before the clip's end.
    local seated = enter and phase == 'end' and text(payload.seated, 32) or nil
    if seated ~= nil then
        drawn = false
        parts[#parts + 1] = own and ('already seated (%s): the seat came before its last sample'):format(seated)
            or ('player %d seated (%s): the seat came before its last sample'):format(scene.player, seated)
    elseif own then
        local view, body = text(payload.view, 24), text(payload.body, 24)
        parts[#parts + 1] = ('in %s (%s%s)'):format(view == 'tps' and 'third person' or (view == 'fpp' and 'first person'
            or tostring(view or 'an unknown view')), body == 'proxy' and 'the stand-in body' or tostring(body or '?'),
            payload.orbit == true and ', the camera in front' or '')
        -- 1.7.8: the view let go for the seat as the step ends is its end.
        if enter and phase == 'end' and payload.seating == true then
            parts[#parts + 1] = 'the view let go for the seat'
        elseif view ~= nil and view ~= 'tps' then
            wrong[#wrong + 1] = 'its own screen showed the step in first person'
        end
        if off ~= nil then
            parts[#parts + 1] = ('the body %.2f m from %s'):format(off, spotWord)
            if off > c.body then wrong[#wrong + 1] = ('its body stood %.2f m from %s'):format(off, spotWord) end
        end
    else
        if payload.seen == false then
            parts[#parts + 1] = ('did not draw player %d (%s)'):format(scene.player, text(payload.why) or 'not streamed')
        else
            parts[#parts + 1] = payload.mounted == true and ('player %d STILL IN THE SEAT'):format(scene.player)
                or (payload.workspot == true and ('player %d in a workspot'):format(scene.player)
                    or ('player %d out of the seat'):format(scene.player))
            if payload.mounted == true then wrong[#wrong + 1] = ('drew player %d still in the seat'):format(scene.player) end
            if payload.workspot == true then wrong[#wrong + 1] = ('drew player %d in a workspot'):format(scene.player) end
            if off ~= nil then
                parts[#parts + 1] = ('%.2f m from %s'):format(off, spotWord)
                if off > c.body then
                    wrong[#wrong + 1] = ('drew player %d %.2f m from %s'):format(scene.player, off, spotWord)
                end
            end
        end
    end
    -- THE STEP AGAINST THE DOOR, as that screen drew the body and the AV.
    if drawn then
        local body = own and 'its body' or ('player %d'):format(scene.player)
        local planned = type(scene.info) == 'table' and finite(scene.info.yaw) or nil
        local yaw, yawOff = finite(payload.yaw), finite(payload.yawOff)
        if yaw ~= nil then
            parts[#parts + 1] = ('facing %.0f deg%s'):format(yaw,
                yawOff ~= nil and (' (%.0f off the step\'s)'):format(yawOff) or '')
            if yawOff ~= nil and yawOff > c.facing then
                wrong[#wrong + 1] = ('drew %s facing %.0f deg, %.0f deg off the step\'s %s: the step\'s path is turned '
                    .. 'with it'):format(body, yaw, yawOff, planned ~= nil and ('%.0f'):format(planned) or '?')
            end
        end
        if payload.grounded == false then
            local air = text(payload.air, 24)
            parts[#parts + 1] = ('OFF THE GROUND (%s)'):format(air or '?')
            wrong[#wrong + 1] = ('drew %s off the ground (%s): the platform plays no clip on a body in the air')
                :format(body, air or '?')
        end
        if payload.weapon == true then
            parts[#parts + 1] = 'a WEAPON DRAWN'
            wrong[#wrong + 1] = ('drew %s with a weapon drawn: the platform plays no clip then'):format(body)
        end
        local age = finite(payload.ageMs)
        if age ~= nil and not own then
            parts[#parts + 1] = ('its movement %.0f ms old'):format(age)
            if age > c.stale then
                wrong[#wrong + 1] = ('drew %s from movement %.0f ms old: the platform plays no clip on stale '
                    .. 'movement'):format(body, age)
            end
        end
        local hipsRoot, hipsDoor = finite(payload.hipsRoot), finite(payload.hipsDoor)
        if hipsRoot ~= nil and phase == hipsPhase then
            parts[#parts + 1] = ('the hips %.2f m from the feet\'s point'):format(hipsRoot)
            if hipsRoot < HIPS_DRAWN_METRES then
                wrong[#wrong + 1] = ('drew no step: %s\'s hips stood on its feet\'s point %s (the clip was '
                    .. 'not drawn there)'):format(body, enter and 'as it ended' or ('%.1fs into it'):format(c.sample / 1000.0))
            end
        end
        if hipsDoor ~= nil and phase == hipsPhase then
            parts[#parts + 1] = ('the hips %.2f m from %s'):format(hipsDoor, doorWord)
            if hipsDoor > c.step + 0.2 and (hipsRoot == nil or hipsRoot >= HIPS_DRAWN_METRES) then
                wrong[#wrong + 1] = ('drew %s\'s %s steps %.2f m from %s (its hips)'):format(body,
                    enter and 'last' or 'first', hipsDoor, doorWord)
            end
        end
        local startDoor = finite(payload.startDoor)
        if startDoor ~= nil then
            local frameWord = enter and 'last' or 'first'
            parts[#parts + 1] = ('the step\'s %s frame %.2f m from %s'):format(frameWord, startDoor, doorWord)
            if startDoor > c.step then
                wrong[#wrong + 1] = ('the step\'s %s frame stood %.2f m from %s as it drew %s and the AV')
                    :format(frameWord, startDoor, doorWord, body)
            end
        end
        local doorOff = finite(payload.doorOff)
        if doorOff ~= nil then
            parts[#parts + 1] = ('its %s %.2f m from the server\'s'):format(doorWord:sub(5), doorOff)
            if doorOff > c.step then
                wrong[#wrong + 1] = ('drew the AV\'s %s %.2f m from where the server has it'):format(doorWord:sub(5),
                    doorOff)
            end
        end
        local slot = text(payload.slot, 16)
        if slot ~= nil and slot ~= 'right' then
            parts[#parts + 1] = ('its door slot %s'):format(slot == 'mirrored' and 'ON THE HULL\'S OTHER SIDE' or 'off')
            if slot == 'mirrored' then wrong[#wrong + 1] = 'drew the AV\'s door on the hull\'s other side' end
        end
    end
    if hullOff ~= nil then
        parts[#parts + 1] = ('the AV %.2f m from the server\'s pose'):format(hullOff)
        if hullOff > c.hull then wrong[#wrong + 1] = ('drew the AV %.2f m from the server\'s pose'):format(hullOff) end
    end
    parts[#parts + 1] = fpsText(payload.fps)
    local line = ('%s %d of player %d, %s %s: %s'):format(word(scene), scene.seq, scene.player,
        own and ('player %d\'s own screen'):format(reporter) or ('player %d\'s screen'):format(reporter),
        phase == 'start' and 'as the step began' or 'as the step ended', table.concat(parts, ', '))
    if #wrong > 0 then
        for _, w in ipairs(wrong) do
            problem(scene, ('%s %s'):format(own and ('player %d\'s own screen'):format(reporter)
                or ('player %d\'s screen'):format(reporter), w))
        end
        Open77.log.warn(line .. ' -- WRONG: ' .. table.concat(wrong, '; '))
    else
        Open77.log.info(line)
    end
    local got, expected = expectedReports(scene)
    if got >= expected then Sync.Close(scene.player, 'every screen reported') end
    return true
end

--- The verdict of an exit, and the scene dropped.
-- @param playerId any
-- @param why string
function Sync.Close(playerId, why)
    local player = validPlayer(playerId)
    local scene = player ~= nil and scenes[player] or nil
    if scene == nil then return end
    scenes[player] = nil
    counts.verdicts = counts.verdicts + 1
    local got, expected = expectedReports(scene)
    -- Viewers still told of a scene that never got its step can stop looking.
    if scene.startAt == nil then
        for _, id in ipairs(scene.order) do
            pcall(TriggerClientEvent, M.Event.SCENE, id, { scene = scene.seq, phase = 'end', player = scene.player })
        end
    elseif got < expected then
        local missing = {}
        for key in pairs(scene.expect) do
            if scene.reports[key] == nil then
                local who, phase = key:match('^(%d+):(%a+)$')
                missing[#missing + 1] = ('player %s\'s %s report'):format(tostring(who), tostring(phase))
            end
        end
        table.sort(missing)
        problem(scene, ('%d of %d report(s) never came: %s'):format(expected - got, expected,
            table.concat(missing, ', ')))
    end
    local played = scene.startAt ~= nil and ('the step played %.1fs after the %s%s'):format(
        (scene.startAt - scene.at) / 1000.0, scene.kind == 'enter' and 'key' or 'exit',
        (scene.heldMs or 0) > 50 and (' (held %.1fs for the other screens)'):format(scene.heldMs / 1000.0) or '')
        or 'no step was played'
    local line = ('%s %d of player %d: verdict -- %s; %d other screen(s), %d of %d report(s) (%s)'):format(word(scene),
        scene.seq, scene.player, played, #scene.order, got, expected, why)
    if #scene.problems == 0 then
        Open77.log.info(line .. ': nothing wrong')
    else
        Open77.log.warn(line .. (': %d thing(s) wrong -- %s'):format(#scene.problems, table.concat(scene.problems, '; ')))
    end
end

--- Every tenth of a second: scenes whose reports never came, or whose step
--- never started, are closed.
function Sync.Tend()
    local now = M.Now()
    local window = M.WalkOutSettings().window
    for player, scene in pairs(scenes) do
        if scene.startAt ~= nil then
            if now - scene.startAt > scene.durationMs + 3000 then Sync.Close(player, 'the reports\' time is over') end
        elseif now - scene.at > window + 1000 then
            Sync.Close(player, 'the step was never asked for')
        end
    end
end

--- A player left: their scene is closed, and they are nobody's viewer.
function Sync.Forget(playerId)
    local player = validPlayer(playerId)
    if player == nil then return end
    hello[player] = nil
    if scenes[player] ~= nil then Sync.Close(player, 'the player left') end
    for _, scene in pairs(scenes) do
        local v = scene.viewers[player]
        if v ~= nil and v.ready == nil then
            v.ready, v.seen, v.free, v.why = M.Now(), false, true, 'left the server'
        end
    end
end

function Sync.Status()
    local open, greeted = 0, 0
    for _ in pairs(scenes) do open = open + 1 end
    for _ in pairs(hello) do greeted = greeted + 1 end
    return { scenes = counts.scenes, open = open, held = counts.held, heldMs = counts.heldMs, late = counts.late,
        reports = counts.reports, problems = counts.problems, republished = counts.republished,
        verdicts = counts.verdicts, hellos = greeted, lateHellos = counts.lateHellos }
end

function Sync.Start()
    -- One word and two reports a scene from each screen: the window is the
    -- scene's (two exits at once each get their word through).
    local function window(payload, what)
        local number = type(payload) == 'table' and math.tointeger(tonumber(payload.scene)) or nil
        return ('%s:%s:%s'):format(what, tostring(number or '?'), type(payload) == 'table'
            and tostring(payload.phase == 'end' and 'end' or 'start') or '?')
    end
    RegisterNetEvent(M.Event.SCENE_READY, function(payload)
        local player = validPlayer(source)
        if player == nil or type(payload) ~= 'table' or M.Cooling(player, window(payload, 'ready'), 100) then return end
        local ran, failure = pcall(Sync.Ready, player, payload)
        if not ran then Open77.log.error('a screen\'s word about an exit failed: ' .. tostring(failure)) end
    end)
    RegisterNetEvent(M.Event.SCENE_REPORT, function(payload)
        local player = validPlayer(source)
        if player == nil or type(payload) ~= 'table' or M.Cooling(player, window(payload, 'report'), 100) then return end
        local ran, failure = pcall(Sync.Report, player, payload)
        if not ran then Open77.log.error('a screen\'s report of an exit failed: ' .. tostring(failure)) end
    end)
    local c = cfg()
    Open77.log.info(c.off and 'exit sync: off' or ('exit sync: every screen within %.0f m of an exit; the step waits '
        .. 'for them %.1fs at most after the exit, %.1fs after the ask; the AV re-published past %.2f m'):format(
        c.range, c.waitMax / 1000.0, c.holdMax / 1000.0, c.hull))
end

function Sync.Stop()
    scenes, hello = {}, {}
end
