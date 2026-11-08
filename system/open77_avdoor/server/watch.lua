-- =============================================================================
-- open77_avdoor -- server/watch.lua
-- =============================================================================
-- The watch: an aircraft's authority, its canonical moves, and where each
-- viewer says it DRAWS it.
--
-- WHY THIS EXISTS. Reported on XyberRP, 2026-09-30: "the av is driving away on
-- other player screen going through buildings but when i move it comes back to
-- same spot on other play screen". The pilot's own client log of that flight
-- is the log of the screen that was RIGHT, the platform's vehicle authority
-- service writes no line of its own, and nothing journalled an aircraft's
-- physics owner, its epoch or a viewer's picture of it -- so a drift on
-- somebody else's screen left no evidence anywhere. This file is that
-- evidence, in the server's own log:
--
--   * AUTHORITY: every `onVehicleAuthorityChanged` of an aircraft -- who
--     simulates it now, the epoch, the platform's reason, who is seated -- with
--     a per-hull ceiling so a hull two controllers fight over is a count, not a
--     flood;
--   * JUMPS: a canonical move between two scans bigger than `JUMP_METRES`,
--     which no AV flies (the platform caps boost at 34 m/s), on a hull nobody
--     froze -- a frozen hull is one a server is posing on purpose;
--   * SIGHTS: a client that draws an aircraft it does not simulate far from
--     where its last sample put it says so (`client/main.lua`, the watch); the
--     line written here puts the server's own reads beside that word.
--
-- THE ONE THING IT DOES, AND ONLY FOR AN EMPTY HULL. A sight of an EMPTY,
-- unfrozen aircraft drawn far from where the SERVER has it is answered by
-- re-publishing the hull where it stands: `setTransform` to its own canonical
-- position and heading, which is the platform's documented way to put one pose
-- in front of every viewer (it revokes an active physics lease, advances the
-- authority epoch and republishes the canonical transform to every current
-- viewer, `wiki/vehicles.md`), and an epoch change makes every observer drop
-- its buffered path. Nothing moves that was not already there on the server.
-- A hull with anybody aboard is never touched: a seated pilot's lease is
-- theirs, and a server pose would fight it.
--
-- AND THE EXIT'S DRAG (1.6.1), ALSO ONLY FOR AN EMPTY HULL. An exit un-masks
-- the hull on the exiting game, whose engine drags it back to where its flight
-- began for a fifth of a second; that game, simulating the hull, may send the
-- dragged pose as the hull's own, and the server may take it (Staging,
-- 2026-10-28, 18:20:46: the AV jumped 14 m back to its spawn pad on every
-- screen). A hull the server has on the drag the exiting game reported, within
-- `DRAG_WINDOW_MS` of the exit, is put back where the server's own scans had
-- it before the exit (`Watch.Undo`) -- and never re-published where it is.
-- =============================================================================

local M = AvDoor

M.Watch = {}
local Watch = M.Watch

-- The last scan's aircraft, `{ id, at, bucket, entry }`, so a sight is matched
-- against what the server already listed instead of a host call per report.
local listed = {}

-- Where each hull was at the last scan, by id as text: `{ at, t }`.
local lastSeen = {}

-- Authority lines per hull: `{ windowStart, count, suppressed }`.
local authority = {}

-- When each hull was last healed, by id as text.
local healed = {}

-- Open sights per reporter and hull, `player|id` -> `{ since }`, so a client
-- that never sends its `closed` does not hold memory forever.
local sights = {}

-- THE EXIT'S DRAG (1.6.1). Where each aircraft stood at the last scans, newest
-- last, `HISTORY` of them: `{ t, x, y, z, yaw, speed }`; the exits whose hull
-- may yet carry the exiting game's drag, by hull key: `{ id, player, at,
-- resting, report, done }`; and drag reports that came in before the exit did,
-- `key|player` -> report.
local history = {}
local exits = {}
local early = {}
local HISTORY = 8
-- The pose a hull stood at before an exit is the newest scan at least this
-- much older than the exit (a drag taken on the exit's own frame is not it),
-- and one it was standing at (`RESTING_SPEED`).
local RESTING_BEFORE_MS = 250
local RESTING_SPEED = 3.0
-- A drag report waits this long for its exit.
local EARLY_KEEP_MS = 3000

-- The handler registrations are made once per start.
local started = false

-- How many authority lines one hull may write in `AUTHORITY_WINDOW_MS`.
local AUTHORITY_LINES = 6
local AUTHORITY_WINDOW_MS = 10000

-- A reporter must be within this of the hull the server has: the platform
-- streams a vehicle to 425 m, and a client cannot draw what it was never sent.
local SIGHT_REACH = 450.0

-- A coordinate a client may report: the platform's own validation bound.
local MAX_COORDINATE = 1000000.0

local function settings()
    return M.WatchSettings()
end

local function finite(value)
    local number = tonumber(value)
    if number == nil or number ~= number or number == math.huge or number == -math.huge then return nil end
    return number
end

--- A point out of a table with `x/y/z` (or a nested `position`), or nil.
local function pointOf(value)
    if type(value) ~= 'table' then return nil end
    local at = type(value.position) == 'table' and value.position or value
    local x, y, z = finite(at.x), finite(at.y), finite(at.z)
    if x == nil or y == nil or z == nil then return nil end
    return { x = x, y = y, z = z }
end

--- A point a CLIENT sent: finite and inside the world.
local function reported(value)
    local at = pointOf(value)
    if at == nil then return nil end
    if math.abs(at.x) > MAX_COORDINATE or math.abs(at.y) > MAX_COORDINATE
        or math.abs(at.z) > MAX_COORDINATE then
        return nil
    end
    return at
end

local function apart(a, b)
    local dx, dy, dz = a.x - b.x, a.y - b.y, a.z - b.z
    return math.sqrt(dx * dx + dy * dy + dz * dz)
end

--- Who sits where, as `2:seat_front_left, 5:seat_back_left`, or `nobody`.
local function seatedOf(snapshot)
    local occupants = type(snapshot) == 'table' and snapshot.occupants or nil
    if type(occupants) ~= 'table' then return 'nobody', 0 end
    local parts = {}
    for _, occupant in ipairs(occupants) do
        if type(occupant) == 'table' and occupant.playerId ~= nil then
            parts[#parts + 1] = ('%s:%s%s'):format(tostring(occupant.playerId),
                tostring(M.SeatName(occupant.seat) or occupant.seat),
                occupant.exiting == true and '(leaving)' or '')
        end
    end
    if #parts == 0 then return 'nobody', 0 end
    return table.concat(parts, ', '), #parts
end

--- Whether the server has the hull frozen. The platform's own read first, the
--- raw bit (`flags.frozen`) when that read is absent.
local function frozenOf(snapshot, id)
    local api = Open77.vehicles
    if type(api) == 'table' and type(api.isFrozen) == 'function' then
        local read, answer = pcall(api.isFrozen, id)
        if read and type(answer) == 'boolean' then return answer end
    end
    if type(snapshot) == 'table' and snapshot.frozen ~= nil then return snapshot.frozen == true end
    local flags = type(api) == 'table' and type(api.flags) == 'table' and tonumber(api.flags.frozen) or nil
    local bits = type(snapshot) == 'table' and tonumber(snapshot.flags) or nil
    if flags ~= nil and bits ~= nil and flags == math.floor(flags) and bits == math.floor(bits) then
        return (math.floor(bits) & math.floor(flags)) ~= 0
    end
    return false
end
M.FrozenOf = frozenOf

--- A snapshot's owner and epoch, as the journal spells them.
local function ownerText(snapshot)
    if type(snapshot) ~= 'table' then return 'owner ?, epoch ?' end
    local owner = tonumber(snapshot.physicsOwner)
    return ('owner %s, epoch %s'):format(
        (owner == nil and '?') or (owner == 0 and 'nobody') or ('player ' .. tostring(owner)),
        tostring(snapshot.authorityEpoch or '?'))
end

--- The full canonical snapshot of a listed hull.
local function snapshotOf(id)
    local api = Open77.vehicles
    if type(api) ~= 'table' or type(api.get) ~= 'function' then return nil end
    local read, snapshot = pcall(api.get, id)
    if read and type(snapshot) == 'table' then return snapshot end
    return nil
end

--- The listed hull a report names, or nil.
local function listedHull(raw)
    if raw == nil then return nil end
    for _, hull in ipairs(listed) do
        if M.SameHull(hull.id, raw) then return hull end
    end
    return nil
end

--- Forgets everything. Shared by start and stop.
function Watch.Reset()
    listed, lastSeen, authority, healed, sights = {}, {}, {}, {}, {}
    history, exits, early = {}, {}, {}
end

--- The ground distance between two points.
local function flat(a, b)
    local dx, dy = a.x - b.x, a.y - b.y
    return math.sqrt(dx * dx + dy * dy)
end

--- How many sit in a hull and are not leaving it.
local function aboardOf(snapshot)
    local n = 0
    local occupants = type(snapshot) == 'table' and snapshot.occupants or nil
    for _, occupant in ipairs(type(occupants) == 'table' and occupants or {}) do
        if type(occupant) == 'table' and occupant.playerId ~= nil and occupant.exiting ~= true then n = n + 1 end
    end
    return n
end

--- Whether a player sits in a hull (leaving it or not).
local function seatedIn(snapshot, playerId)
    local occupants = type(snapshot) == 'table' and snapshot.occupants or nil
    for _, occupant in ipairs(type(occupants) == 'table' and occupants or {}) do
        if type(occupant) == 'table' and tonumber(occupant.playerId) == playerId then return true end
    end
    return false
end

--- The pose a hull stood at before an exit at `at`: the newest scan at least
--- `RESTING_BEFORE_MS` older, of a hull standing (or slower than
--- `RESTING_SPEED`), or nil.
local function restingOf(key, at)
    local samples = history[key]
    if samples == nil then return nil end
    for i = #samples, 1, -1 do
        local sample = samples[i]
        if sample.t <= at - RESTING_BEFORE_MS then
            if sample.speed ~= nil and sample.speed > RESTING_SPEED then return nil end
            return sample
        end
    end
    return nil
end

--- THE EXIT'S DRAG, PUT RIGHT (1.6.1). An exit un-masks the hull on the
--- exiting game, whose engine drags it back, for a fifth of a second, to where
--- its flight began there (client/src/api/VehicleFlight.cpp, `ParkExit`; the
--- re-mask comes 150 ms later) -- and that game, simulating the hull, may send
--- the dragged pose as the hull's own. A first sample after an authority grant
--- is allowed 300 m (VehicleAuthorityService, `avMaximum`), so the server took
--- it: XyberRP Staging, 2026-10-28, 18:20:46, a player out of the back seat of
--- an Excalibur parked 14 m off its spawn pad -- the hull's REAL pose then
--- refused against the pad ("Vehicle motion rejected ... canonical=(-38.377,
--- 1993.726,102.142) received=(-41.435,2007.588,102.301) ... motion_jump") --
--- and the heal below re-published the pad to every game: the AV jumped 14 m
--- back to where it was spawned. So, for `DRAG_WINDOW_MS` after an exit, an
--- EMPTY, unfrozen hull the server has within `DRAG_MATCH_METRES` of where the
--- exiting game says its engine dragged it (`DRAG`), and more than
--- `DRAG_UNDO_METRES` from where it stood before the exit (the server's own
--- scans), is put back where it stood -- `setTransform`, which also starts a
--- new authority epoch, so the exiting game's late samples are refused -- once
--- an exit. A hull moved anywhere else is left alone, and said.
-- @param key string the hull's key
-- @param why string what looked, for the log
-- @return string|nil 'undone' (put back now), 'held' (the server holds the
--   drag and it could not be put back), or nil
function Watch.Undo(key, why)
    local entry = exits[key]
    if entry == nil then return nil end
    local watch = settings()
    local now = M.Now()
    if now - entry.at > watch.dragWindow then
        exits[key] = nil
        return nil
    end
    if entry.done or entry.report == nil or entry.resting == nil then return nil end
    local snapshot = snapshotOf(entry.id)
    if snapshot == nil and tonumber(entry.id) ~= nil then snapshot = snapshotOf(tonumber(entry.id)) end
    if snapshot == nil then return nil end
    if aboardOf(snapshot) > 0 then
        -- Boarded again: the hull is its new pilot's.
        exits[key] = nil
        return nil
    end
    if frozenOf(snapshot, entry.id) then return nil end
    local here = pointOf(snapshot)
    if here == nil then return nil end
    local resting = entry.resting
    local off = flat(here, resting)
    if off <= watch.dragMetres then return nil end
    local toDrag = flat(here, entry.report.engine)
    if toDrag > watch.dragMatch then
        if not entry.elsewhereSaid then
            entry.elsewhereSaid = true
            Open77.log.info(('drag: aircraft %s moved %.1f m after player %s stepped out, to %.1f, %.1f -- not where '
                .. 'that game\'s engine dragged it (%.1f m from it): left alone (%s)'):format(key, off,
                tostring(entry.player), here.x, here.y, toDrag, tostring(why)))
        end
        return nil
    end
    local api = Open77.vehicles
    if type(api) ~= 'table' or type(api.setTransform) ~= 'function' then return 'held' end
    entry.done = true
    -- `yaw` is passed on purpose: the platform's `setTransform` reads an absent
    -- heading as 0, not as "keep the current one".
    local yaw = resting.yaw or finite(snapshot.heading or snapshot.yaw) or 0.0
    local called, moved, reason = pcall(api.setTransform, entry.id,
        { x = resting.x, y = resting.y, z = resting.z, yaw = yaw })
    if called and moved == true then
        healed[key] = now
        Open77.log.info(('drag: aircraft %s put back where it stood when player %s stepped out (%.1f, %.1f, %.1f, '
            .. 'heading %.0f): the server had taken the exiting game\'s own drag of it for its pose -- %.1f m off, at '
            .. '%.1f, %.1f, where that game\'s engine drew it at the exit (%s); %.1fs after the exit, seen by %s')
            :format(key, tostring(entry.player), resting.x, resting.y, resting.z, yaw, off, here.x, here.y,
                tostring(entry.report.how or '?'), (now - entry.at) / 1000.0, tostring(why)))
        return 'undone'
    end
    Open77.log.warn(('drag: aircraft %s could not be put back where it stood (%.1f m off, on the exit\'s drag): %s')
        :format(key, off, tostring(called and (reason or moved) or moved)))
    return 'held'
end

--- Whether the server has a hull on the exit's drag a game reported: never
--- re-published (the heal), whatever a viewer draws.
local function onDrag(key, server)
    local entry = exits[key]
    if entry == nil or entry.report == nil or server == nil then return false end
    if M.Now() - entry.at > settings().dragWindow then return false end
    return flat(server, entry.report.engine) <= settings().dragMatch
        and (entry.resting == nil or flat(server, entry.resting) > settings().dragMetres)
end

--- An aircraft seat was left (`M.Exited`, server/main.lua): the pose the hull
--- stood at before, and the exit's drag watched for.
-- @param rawId any the hull
-- @param playerId any who stepped out
-- @param how string 'exiting' | 'left' | 'changed'
function Watch.Exited(rawId, playerId, how)
    local watch = settings()
    if watch.off or not watch.dragUndo or how == 'changed' then return end
    local key = M.KeyOf(rawId)
    local player = tonumber(playerId)
    local now = M.Now()
    local entry = exits[key]
    -- The same exit's second word (the seat flagged as leaving, then empty).
    if entry ~= nil and entry.player == player and now - entry.at < watch.dragWindow then return end
    entry = { id = rawId, player = player, at = now, resting = restingOf(key, now) }
    local said = early[key .. '|' .. tostring(player)]
    if said ~= nil and now - said.at <= EARLY_KEEP_MS then entry.report = said end
    early[key .. '|' .. tostring(player)] = nil
    exits[key] = entry
    pcall(Watch.Undo, key, 'the exit')
end

--- The exiting game's word of the drag it saw: where its engine drew the hull
--- at the exit, and where the hull stands. Kept only from a player who sat in
--- that hull; the undo puts the hull back where the SERVER had it, never where
--- a game says.
-- @param playerId number
-- @param payload table `{ id, engine = { x, y, z }, real = { x, y, z }, body?, how? }`
-- @return string `ignored` or `kept`
function Watch.Drag(playerId, payload)
    local watch = settings()
    if watch.off or not watch.dragUndo or type(payload) ~= 'table' then return 'ignored' end
    playerId = tonumber(playerId)
    if playerId == nil or playerId < 1 or playerId ~= math.floor(playerId) then return 'ignored' end
    local raw = payload.id
    if (type(raw) ~= 'string' and type(raw) ~= 'number') or #tostring(raw) > 24 then return 'ignored' end
    local engine, real = reported(payload.engine), reported(payload.real)
    if engine == nil or real == nil then return 'ignored' end
    local key = M.KeyOf(raw)
    local report = { engine = engine, real = real, body = reported(payload.body), at = M.Now(),
        how = type(payload.how) == 'string' and payload.how:sub(1, 40) or nil }
    local entry = exits[key]
    if entry ~= nil and entry.player == playerId then
        entry.report = report
    else
        -- Before the server saw the exit: kept a moment for it, from a player
        -- who sits in that hull.
        local hull = listedHull(raw)
        local snapshot = hull ~= nil and (snapshotOf(hull.id) or hull.entry) or nil
        if snapshot == nil or not seatedIn(snapshot, playerId) then return 'ignored' end
        early[key .. '|' .. tostring(playerId)] = report
    end
    Open77.log.info(('drag: player %d\'s game drew aircraft %s at %.1f, %.1f at the exit, %.1f m from where it stands '
        .. '(%.1f, %.1f; %s)%s'):format(playerId, key, engine.x, engine.y, flat(engine, real), real.x, real.y,
        tostring(report.how or '?'), report.body ~= nil and (', its body %.1f m from that'):format(
            flat(report.body, engine)) or ''))
    pcall(Watch.Undo, key, 'the exiting game\'s word')
    return 'kept'
end

--- One scan's aircraft, measured against the last one: a canonical move no
--- aircraft flies is a line. Called by `M.Scan` with the list it already read.
-- @param hulls table[] `{ id, at, bucket, entry }`
-- @param now number|nil
-- @return integer how many jumps were journalled
function Watch.Observe(hulls, now)
    local watch = settings()
    if watch.off or type(hulls) ~= 'table' then return 0 end
    now = now or M.Now()
    listed = hulls
    local present, jumps = {}, 0
    local ceiling = 2 * math.floor(M.Number(M.Settings and M.Settings.SCAN_MS, 100, 5000, 500))
    for _, hull in ipairs(hulls) do
        local key = M.KeyOf(hull.id)
        present[key] = true
        local was = lastSeen[key]
        if was ~= nil and now - was.t <= ceiling and hull.at ~= nil then
            local moved = apart(was.at, hull.at)
            if moved > watch.jump then
                local snapshot = hull.entry or snapshotOf(hull.id)
                if not frozenOf(snapshot, hull.id) then
                    jumps = jumps + 1
                    Open77.log.warn(('jump: aircraft %s moved %.1f m in %.1f s on the server '
                        .. '(%s, seated %s): %.1f, %.1f, %.1f -> %.1f, %.1f, %.1f')
                        :format(key, moved, (now - was.t) / 1000.0, ownerText(snapshot),
                            (seatedOf(snapshot)), was.at.x, was.at.y, was.at.z,
                            hull.at.x, hull.at.y, hull.at.z))
                end
            end
        end
        if hull.at ~= nil then
            lastSeen[key] = { at = hull.at, t = now }
            -- THE EXIT'S DRAG: where the hull stood, scan by scan.
            local samples = history[key] or {}
            local entry = hull.entry
            samples[#samples + 1] = { t = now, x = hull.at.x, y = hull.at.y, z = hull.at.z,
                yaw = type(entry) == 'table' and finite(entry.heading or entry.yaw) or nil,
                speed = type(entry) == 'table' and finite(entry.speed) or nil }
            if #samples > HISTORY then table.remove(samples, 1) end
            history[key] = samples
        end
    end
    for key in pairs(lastSeen) do
        if not present[key] then lastSeen[key] = nil end
    end
    for key in pairs(history) do
        if not present[key] then history[key] = nil end
    end
    -- An exit's drag, looked for at every scan of its window.
    for key in pairs(exits) do
        local ran, failure = pcall(Watch.Undo, key, 'a scan')
        if not ran then Open77.log.warn('the drag check failed: ' .. tostring(failure)) end
    end
    for said, report in pairs(early) do
        if now - report.at > EARLY_KEEP_MS then early[said] = nil end
    end
    for key in pairs(healed) do
        if not present[key] then healed[key] = nil end
    end
    for key in pairs(authority) do
        if not present[key] then authority[key] = nil end
    end
    return jumps
end

--- An aircraft's physics owner changed: one line, with the platform's reason
--- and who is seated. Raised by the platform with every argument as text.
-- @param rawId any
-- @param owner any
-- @param epoch any
-- @param reason any
-- @return boolean whether a line was written
function Watch.Authority(rawId, owner, epoch, reason)
    local watch = settings()
    if watch.off or rawId == nil then return false end
    local snapshot = snapshotOf(rawId)
    if snapshot == nil and tonumber(rawId) ~= nil then snapshot = snapshotOf(tonumber(rawId)) end
    if snapshot == nil or not M.IsAircraft(snapshot.record) then return false end
    local key = M.KeyOf(rawId)
    -- A hull revoked from the exiting game (its real pose refused against the
    -- drag it sent) is the moment to put it back -- logged or not.
    if exits[key] ~= nil then pcall(Watch.Undo, key, 'an authority change (' .. tostring(reason or '?') .. ')') end
    local now = M.Now()
    local book = authority[key]
    if book == nil or now - book.windowStart >= AUTHORITY_WINDOW_MS then
        if book ~= nil and book.suppressed > 0 then
            Open77.log.info(('authority: aircraft %s changed hands %d more time(s) in the last %.0f s')
                :format(key, book.suppressed, AUTHORITY_WINDOW_MS / 1000.0))
        end
        book = { windowStart = now, count = 0, suppressed = 0 }
        authority[key] = book
    end
    book.count = book.count + 1
    if book.count > AUTHORITY_LINES then
        book.suppressed = book.suppressed + 1
        return false
    end
    local who = tonumber(owner)
    local at = pointOf(snapshot)
    Open77.log.info(('authority: aircraft %s is simulated by %s now (epoch %s, %s); seated %s%s; '
        .. 'at %s')
        :format(key, (who == nil and tostring(owner)) or (who == 0 and 'nobody') or ('player ' .. tostring(who)),
            tostring(epoch), tostring(reason or '?'), (seatedOf(snapshot)),
            frozenOf(snapshot, rawId) and ', FROZEN' or '',
            at ~= nil and ('%.1f, %.1f, %.1f'):format(at.x, at.y, at.z) or '?'))
    return true
end

--- A client's word about where it draws an aircraft it does not simulate.
--
-- CHECKED BEFORE IT IS BELIEVED, and believed only as far as a log line and
-- the one heal: the hull must be one the server listed, in the reporter's
-- bucket, within streaming reach of the reporter's body; every number must be
-- finite and in the world. The heal re-publishes the SERVER's pose, never the
-- client's, so a client that lies can at worst make an empty hull be
-- re-published where it already is, once per `HEAL_EVERY_MS`.
-- @param playerId number
-- @param payload table
-- @return string what was done: `ignored`, `logged`, `healed`
function Watch.Sight(playerId, payload)
    local watch = settings()
    if watch.off or type(payload) ~= 'table' then return 'ignored' end
    playerId = tonumber(playerId)
    -- The host's player reads throw on an id under 1: checked before any read.
    if playerId == nil or playerId < 1 or playerId ~= math.floor(playerId) then return 'ignored' end
    local state = payload.state
    if state ~= 'open' and state ~= 'still' and state ~= 'closed' then return 'ignored' end
    local raw = payload.id
    if (type(raw) ~= 'string' and type(raw) ~= 'number') or #tostring(raw) > 24 then return 'ignored' end
    local hull = listedHull(raw)
    if hull == nil or hull.at == nil then return 'ignored' end
    local key = M.KeyOf(hull.id)

    local players = Open77.players
    local body, bucket = nil, 0
    if type(players) == 'table' and type(players.position) == 'function' then
        local read, at = pcall(players.position, playerId)
        if read and type(at) == 'table' then
            body = pointOf(at)
            bucket = tonumber(at.bucket) or 0
        end
    end
    if body == nil or bucket ~= hull.bucket or apart(body, hull.at) > SIGHT_REACH then return 'ignored' end

    local drawn = reported(payload.drawn)
    local sampled = reported(payload.sampled)
    if drawn == nil then return 'ignored' end
    local worst = finite(payload.worst)
    local seconds = finite(payload.seconds)
    local sightKey = tostring(playerId) .. '|' .. key

    local snapshot = snapshotOf(hull.id) or hull.entry
    local server = pointOf(snapshot) or hull.at
    local fromServer = apart(drawn, server)
    local seatedText, seatedCount = seatedOf(snapshot)
    local frozen = frozenOf(snapshot, hull.id)

    if state == 'closed' then
        sights[sightKey] = nil
        Open77.log.info(('sight: player %d draws aircraft %s where the server has it again '
            .. '(%.1f m off) after %s, %s at worst'):format(playerId, key, fromServer,
            seconds ~= nil and ('%.1f s'):format(math.max(0, seconds)) or '?',
            worst ~= nil and ('%.1f m'):format(math.max(0, worst)) or '?'))
        return 'logged'
    end

    sights[sightKey] = sights[sightKey] or { since = M.Now() }
    local clientOwner = tonumber(payload.owner)
    local clientEpoch = tonumber(payload.epoch)
    local age = finite(payload.sampleAgeMs)
    Open77.log.warn(('sight: player %d draws aircraft %s %.1f m from where the server has it%s '
        .. '(%s). Server: %s, seated %s%s, speed %.1f m/s, at %.1f, %.1f, %.1f. Client: %s, %s epoch %s%s%s%s, '
        .. 'drawn %.1f, %.1f, %.1f%s')
        :format(playerId, key, fromServer,
            state == 'still' and ' still' or '',
            state == 'still' and (seconds ~= nil and ('%.0f s so far, %.1f m at worst'):format(seconds, worst or 0)
                or 'still') or 'new',
            ownerText(snapshot), seatedText, frozen and ', FROZEN' or '',
            finite(snapshot and snapshot.speed) or 0.0, server.x, server.y, server.z,
            payload.seated == true and 'seated in it' or 'on foot or elsewhere',
            clientOwner == nil and 'owner ?' or (clientOwner == 0 and 'owner nobody'
                or ('owner player ' .. tostring(clientOwner))),
            clientEpoch == nil and '?' or tostring(clientEpoch),
            payload.frozen == true and ', frozen' or '',
            age ~= nil and (', last sample %.0f ms old'):format(age) or '',
            payload.extrapolating == true and ', extrapolating' or '',
            drawn.x, drawn.y, drawn.z,
            sampled ~= nil and (', its own last sample %.1f m from the server\'s'):format(apart(sampled, server))
                or ''))

    -- THE EXIT'S DRAG FIRST (1.6.1): a hull the server has on the drag an
    -- exiting game reported is put back where it stood -- never re-published
    -- where it is (on Staging the heal sent the pad to every game).
    if exits[key] ~= nil then
        -- No word of the drag from the exiting game (its exit took the body for
        -- a move, say), but a viewer that draws the hull where it stood before
        -- the exit, and a server pose that left that place with the exit: the
        -- same evidence -- the server's own resting pose against the one it
        -- took on the exit's frame.
        local entry = exits[key]
        if entry.report == nil and entry.resting ~= nil and M.Now() - entry.at <= watch.dragWindow
            and flat(drawn, entry.resting) <= watch.dragMatch and flat(server, entry.resting) > watch.dragMetres then
            entry.report = { engine = server, real = drawn, at = M.Now(),
                how = ('player %d draws it where it stood'):format(playerId) }
        end
        local ran, done = pcall(Watch.Undo, key, ('a sight of player %d'):format(playerId))
        if ran and done == 'undone' then return 'healed' end
        if onDrag(key, server) then
            Open77.log.info(('heal: aircraft %s is not re-published where the server has it: that is the exit\'s '
                .. 'drag (server/watch.lua, `Watch.Undo`)'):format(key))
            return 'logged'
        end
    end
    -- THE HEAL: an empty, unfrozen hull that a viewer draws far from the
    -- server's pose is re-published where the server has it.
    if not watch.heal or seatedCount > 0 or frozen then return 'logged' end
    if fromServer <= M.DriftLimit(watch, 0.0) then return 'logged' end
    local now = M.Now()
    if healed[key] ~= nil and now - healed[key] < watch.healEvery then return 'logged' end
    local api = Open77.vehicles
    if type(api) ~= 'table' or type(api.setTransform) ~= 'function' then return 'logged' end
    local heading = finite(snapshot and (snapshot.heading or snapshot.yaw)) or 0.0
    healed[key] = now
    -- `yaw` is passed on purpose: the platform's `setTransform` reads an absent
    -- heading as 0, not as "keep the current one".
    local called, moved, why = pcall(api.setTransform, hull.id,
        { x = server.x, y = server.y, z = server.z, yaw = heading })
    if called and moved == true then
        Open77.log.info(('heal: aircraft %s re-published where the server has it (%.1f, %.1f, %.1f, '
            .. 'heading %.0f) because player %d drew it %.1f m away with nobody aboard')
            :format(key, server.x, server.y, server.z, heading, playerId, fromServer))
        return 'healed'
    end
    Open77.log.warn(('heal: aircraft %s could not be re-published: %s')
        :format(key, tostring(called and (why or moved) or moved)))
    return 'logged'
end

--- A reporter left: its open sights go with it.
-- @param playerId number
function Watch.Forget(playerId)
    local prefix = tostring(tonumber(playerId) or playerId) .. '|'
    for sightKey in pairs(sights) do
        if sightKey:sub(1, #prefix) == prefix then sights[sightKey] = nil end
    end
end

--- Wires the platform's authority event and the sight report. Once per load:
--- a stopped resource takes its handlers with it, and a second registration
--- would write every line twice.
function Watch.Start()
    if started then return end
    started = true
    AddEventHandler('onVehicleAuthorityChanged', function(id, owner, epoch, reason)
        local ran, failure = pcall(Watch.Authority, id, owner, epoch, reason)
        if not ran then
            Open77.log.error('an authority change could not be read: ' .. tostring(failure))
        end
    end)
    RegisterNetEvent(M.Event.SIGHT, function(payload)
        local player = tonumber(source)
        if player == nil or player < 1 or player ~= math.floor(player) then return end
        -- The client sends at most one report per look (`SIGHT_MS`), so a tighter
        -- pace than that is not a client of ours.
        if M.Cooling(player, 'sight', 300) then return end
        local ran, failure = pcall(Watch.Sight, player, payload)
        if not ran then
            Open77.log.error('a sight report could not be read: ' .. tostring(failure))
        end
    end)
    -- The exiting game's word of the drag it saw (1.6.1): once an exit.
    RegisterNetEvent(M.Event.DRAG, function(payload)
        local player = tonumber(source)
        if player == nil or player < 1 or player ~= math.floor(player) then return end
        if M.Cooling(player, 'drag', 200) then return end
        local ran, failure = pcall(Watch.Drag, player, payload)
        if not ran then
            Open77.log.error('a drag report could not be read: ' .. tostring(failure))
        end
    end)
end

--- How many hulls and sights this half holds, for the suite and the console.
function Watch.Status()
    local open = 0
    for _ in pairs(sights) do open = open + 1 end
    local seen = 0
    for _ in pairs(lastSeen) do seen = seen + 1 end
    local watching = 0
    for _ in pairs(exits) do watching = watching + 1 end
    return { hulls = #listed, seen = seen, sights = open, exits = watching }
end
