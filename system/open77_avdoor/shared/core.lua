-- =============================================================================
-- open77_avdoor -- shared/core.lua
-- =============================================================================
-- What both halves read the same way: the event names, the refusal codes, the
-- settings each inside a band, the geometry of the exit, the player-facing
-- text, and the three small runtime helpers every file uses (a millisecond
-- clock, a repeating job, a per-player cooldown).
--
-- Everything here is shared because both halves read the same settings and the
-- suite has to be able to call the geometry without a running game.
--
-- Ported from XyberRP's opx_infinity `modules/avdoor` (XEROX710), which ran on
-- the XyberRP servers; the logic is the same, the framework underneath it is
-- the platform's own (CreateThread, events, exports) instead of opx_infinity's.
-- =============================================================================

AvDoor = AvDoor or {}
local M = AvDoor

M.RESOURCE = 'open77_avdoor'
-- The manifest's version, said in the client's hello and the server's logs.
M.VERSION = '1.9.0'
M.Settings = Open77AvDoorConfig or {}

-- THE SETTINGS, READ ONCE (1.5.1). Every reader below turns a config block into
-- a table of numbers inside their bands -- some forty `M.Number` calls for the
-- exit clip's alone -- and the watch called them dozens of times a pass: the
-- most instructions any code of this resource ran (tests/world.lua's profile of
-- the host's budget). The host kills a resume at its 10 000th instruction on a
-- loaded client (scripting/src/ResourceHost.cpp, `InstructionHook`; the laptop,
-- 2026-10-28, 04:39:17 and :23: "Open77 script execution budget exceeded",
-- twice in one exit). So each table is built once and kept until the config
-- table is another one, or `M.SettingsChanged()` says it changed in place (the
-- suites do; a running server never does).
local settingsCache = {}
local settingsOf = nil
function M.SettingsChanged() settingsCache = {} end
local function cached(key, build, ...)
    if settingsOf ~= M.Settings then
        settingsCache, settingsOf = {}, M.Settings
    end
    local hit = settingsCache[key]
    if hit == nil then
        hit = { value = build(...) }
        settingsCache[key] = hit
    end
    return hit.value
end
M.CachedSetting = cached

--- Every network event this resource raises, so both halves agree.
M.Event = {
    -- Server to client, to that client alone: the aircraft door open to this
    -- player right now -- `{ open = true, id, role }` -- or `{ open = false }`.
    -- Sent when it changes, never per scan.
    DOOR = 'open77_avdoor:door',
    -- Client to server: the key, on a hull whose card is up. Judged again in
    -- full; the payload names the hull and nothing more.
    BOARD = 'open77_avdoor:board',
    -- Server to client, to the asker alone: what the press came to.
    BOARDED = 'open77_avdoor:boarded',
    -- Client to server, from the pilot's own client: the flight just did one of
    -- the moments the MaxTac AV has a voice for. Relayed only when the asker is
    -- seated in that hull.
    SOUND = 'open77_avdoor:sound',
    -- Server to client, to every listener within range of the hull, the pilot
    -- included: `{ id, event, which, duration, token }` -- play this on the hull.
    PLAY = 'open77_avdoor:play',
    -- Client to server, from a listener: what its client did with a `PLAY`.
    -- It carries no authority; it exists because a sound that fails on
    -- somebody else's machine leaves no line anywhere else.
    PLAYED = 'open77_avdoor:played',
    -- Client to server, from any client: an aircraft this client does not
    -- simulate is drawn far from where the server's last sample put it, or has
    -- come back. Evidence, never a command.
    SIGHT = 'open77_avdoor:sight',
    -- Server to client: draw the landing pad under this hull, or stop.
    PAD = 'open77_avdoor:pad',
    -- Server to client: play this kind's landing call on the hull, or end it.
    CALL = 'open77_avdoor:call',
    -- Client to server: this client's resource has started and its world is
    -- up, and it knows nothing yet. The server sends it its door, pads and
    -- calls again, waits for it in every exit scene near it (server/sync.lua),
    -- and answers `WELCOME`. Said again every few seconds until it is answered:
    -- one sent while the game was still loading went nowhere (XyberRP Staging,
    -- 2026-10-28: no hello reached the server in any session, so the exit sync
    -- waited for nobody).
    HELLO = 'open77_avdoor:hello',
    -- Server to client, to that client alone: its hello was heard.
    WELCOME = 'open77_avdoor:welcome',
    -- Client to server, from the body that just stepped out: the body stands
    -- where its exit clip ends -- play it, `{ id, clip, seat }` -- or there is
    -- no clip for this exit, `{ id, clip = false, why }` (the server shows the
    -- body to everybody again at once).
    WALKOUT = 'open77_avdoor:walkout',
    -- Server to client, to the asker alone: what the clip came to,
    -- `{ ok = true, clip, durationMs }` or `{ ok = false, reason }`.
    WALKING = 'open77_avdoor:walking',
    -- THE BOARDING, ANIMATED (1.7.0, server/enter.lua, client/enter.lua).
    -- Server to client, to the player who pressed the key: step up into this
    -- door rather than being seated at once -- `{ token, id, seat, record,
    -- clip, hull = { x, y, z, yaw }, durationMs, doorOpenMs, askMs }`.
    ENTER = 'open77_avdoor:enter',
    -- Client to server: the body stands on the clip's first spot, faces the
    -- door, is held and drawn -- play it, `{ token, id, clip, plan }` -- or
    -- there is no step for this boarding, `{ token, clip = false, why }` (the
    -- server seats the body at once).
    ENTER_READY = 'open77_avdoor:enterReady',
    -- Server to client: what the step came to, `{ token, ok = true, clip,
    -- durationMs, seatInMs }` or `{ token, ok = false, reason }` (seated at
    -- once). The seat itself is answered as every boarding is (`BOARDED`).
    ENTERING = 'open77_avdoor:entering',
    -- Client to server (1.7.8): the step is at its end and this screen has put
    -- its stand-in away (first person, the view let go before the seat) --
    -- seat the body now, `{ token, parked, parkMs }`. Without it the server
    -- seats on its own `SEAT_WAIT_MS` after the clip's end.
    ENTER_SEAT = 'open77_avdoor:enterSeat',
    -- Server to client, to that player alone, when it changes: whether their
    -- locomotion style is the exit package's -- `{ ok = true, style }` -- or
    -- why not, `{ ok = false, reason }`. A client plans an exit clip only when
    -- the server said yes; otherwise its exit is the plain one.
    STYLE = 'open77_avdoor:style',
    -- Client to server, from the body that just stepped out of an airframe
    -- that stands on landing gear (`AIRFRAMES` ... `LAND`): the static ground
    -- under each of its gear feet, as this game measured it, `{ id, grounds =
    -- { z, ... }, x, y }`. The server lowers the hull onto its gear once
    -- nobody is aboard -- or says why not in its log. A measure, never a pose:
    -- the height is the server's own sum, inside `MAX_DROP_METRES` of where
    -- the hull stands.
    LAND = 'open77_avdoor:land',
    -- THE EXIT, ONE SCENE FOR EVERY SCREEN (server/sync.lua, client/sync.lua).
    -- Server to client, to every other screen near an exit: `{ scene, phase =
    -- 'exit', player, id, seat, clip, hull, record }` as the seat empties,
    -- `{ scene, phase = 'start', ..., at, yaw, door, durationMs }` as the clip
    -- starts -- the step's end point, the heading it is played at and the door
    -- its first frame stands on, as the server plans them on its own hull.
    SCENE = 'open77_avdoor:scene',
    -- Client to server, from such a screen: the exiting body is out of its seat
    -- here (or why not), `{ scene, free, seen, hullOff, fps, why }`. The clip
    -- waits for it, at most `SYNC.WAIT_MAX_MS` after the exit.
    SCENE_READY = 'open77_avdoor:sceneReady',
    -- Client to server, from every screen that drew the exit, the exiting
    -- player's own included: what it drew at the clip's start and end -- the
    -- body against the end point, its heading against the step's, on the
    -- ground or not, its hips against the door (the step drawn or not), the AV
    -- and its door against the server's. Logged by the server, a warning for
    -- anything wrong. Evidence, never a command.
    SCENE_REPORT = 'open77_avdoor:sceneReport',
    -- THE EXIT'S DRAG (1.6.1), client to server, from the game whose body just
    -- left an aircraft's seat: its engine drew the hull elsewhere at the exit
    -- (dragged back to where its flight began) -- `{ id, engine = { x, y, z },
    -- real = { x, y, z }, body, how }`. The exiting game may have sent that
    -- dragged pose as the hull's own (it simulated the hull): the server puts
    -- a hull it now has THERE back where it stood before the exit
    -- (server/watch.lua). Evidence, never a pose.
    DRAG = 'open77_avdoor:drag',
    -- THE GROUND TEST (1.5.3), server to client, to the player who typed
    -- `avdoor.groundtest`: run it on that body -- what its game says of the
    -- ground after a move, under the platform's freeze, after a move while
    -- held, under the NoMovement restriction (client/groundtest.lua).
    GROUNDTEST = 'open77_avdoor:groundtest',
    -- THE PAD SNAP (1.7.0, server/snap.lua). Server to client, to the pilot of
    -- an AV coming down over a pad: measure the static ground straight down at
    -- these points, `{ token, id, pad, points = { { x, y }, ... }, fromZ }` --
    -- the pad's centre first, then each gear foot as the hull will stand.
    SNAP_MEASURE = 'open77_avdoor:snapMeasure',
    -- Client to server, from that pilot's game: `{ token, id, pad, grounds =
    -- { z | false, ... }, fps }`, one per point (false: no ground there). A
    -- measure, never a pose: the landing height is the server's own sum.
    SNAP_GROUND = 'open77_avdoor:snapGround',
    -- Server to client, to that pilot: the snap's state, for the game's log and
    -- a line on the screen -- `{ state = 'on' | 'landed' | 'off', pad, kind,
    -- why }`.
    SNAP = 'open77_avdoor:snap',
    -- THE EXIT KEY (1.9.0, `LEAVE`). Client to server, from a body seated in an
    -- airframe the game's own exit animates (`EXIT_FORCED`): step me out,
    -- `{ id, seat }`. Judged again in full -- the seat, the hull, the airframe
    -- -- and carried out with the platform's forced exit.
    LEAVE = 'open77_avdoor:leave',
    -- Server to client, to the asker alone: what the ask came to, `{ id, ok =
    -- true }` (the forced exit is under way) or `{ id, ok = false, reason }`.
    LEFT = 'open77_avdoor:left',
    -- THE DOCK (1.8.3, `PAD_SNAP.ABOARD = 'dock'`). Server to the games of
    -- everybody aboard an AV the snap takes: `{ token, id, pad, state, ms,
    -- pilot, timeoutMs, why }` -- 'out': the screen dips to black (only the
    -- pilot's game answers); 'in': the image back.
    SNAP_DIP = 'open77_avdoor:snapDip',
    -- Client to server, from the pilot's game: `{ token, id, state, reason,
    -- ms }` -- 'black' (its screen is covered) or 'failed' (it could not dip).
    -- A word about its own screen, never a pose.
    SNAP_DIP_READY = 'open77_avdoor:snapDipReady',
}

--- The client's own local event: the door card's key (open77_interactions).
M.CHOICE = 'open77_avdoor:choice'

--- Events this resource raises on the SERVER's host bus for other resources:
--- `onBoarded(playerId, vehicleId, seat, role)` after a body was seated
--- through the door, `onExited(playerId, vehicleId, seat, how)` when a seat of
--- an aircraft was left.
M.Notice = {
    BOARDED = 'open77_avdoor:onBoarded',
    EXITED = 'open77_avdoor:onExited',
}

--- Console commands.
M.Command = { WHY = 'avdoor.why', STATUS = 'avdoor.status', GROUNDTEST = 'avdoor.groundtest', PADS = 'avdoor.pads',
    RIDE = 'avdoor.ride' }

--- The moments of a flight the MaxTac AV has a voice for, and the config field
--- each one is read from.
M.SOUNDS = { takeoff = 'TAKEOFF', descent = 'DESCENT', touchdown = 'TOUCHDOWN' }

--- Every moment a pilot's client may report. `abort` has no sound of its own:
--- a hull that climbed back out of its descent ends its landing call.
M.MOMENTS = { takeoff = true, descent = true, touchdown = true, abort = true }

--- Every refusal the door can name, as the text key a player reads.
M.Refusal = {
    no_player = 'refused.noPlayer',
    no_aircraft = 'refused.noAircraft',
    not_aircraft = 'refused.noAircraft',
    wrecked = 'refused.wrecked',
    seated = 'refused.seated',
    down = 'refused.down',
    no_position = 'refused.noPosition',
    too_far = 'refused.tooFar',
    moving = 'refused.moving',
    locked = 'refused.locked',
    not_yours = 'refused.notYours',
    not_crew = 'refused.notCrew',
    no_seat = 'refused.noSeat',
    seats_boarding = 'refused.seatsBoarding',
    busy = 'refused.busy',
    seat_refused = 'refused.failed',
}

-- ── the runtime ──────────────────────────────────────────────────────────────

--- Milliseconds on the host's monotonic clock.
-- @return number
function M.Now()
    local time = type(Open77) == 'table' and Open77.time or nil
    if type(time) == 'table' and type(time.monotonic) == 'function' then
        local read, seconds = pcall(time.monotonic)
        if read and type(seconds) == 'number' then return math.floor(seconds * 1000.0) end
    end
    if type(os) == 'table' and type(os.clock) == 'function' then return math.floor(os.clock() * 1000.0) end
    return 0
end

-- THE JOBS' COST (1.7.0). Every pass of every job (`M.Every`) is timed on the
-- host's clock, and once `COST_FIRST_MS` after the start, then every
-- `COST_EVERY_MS`, one line says what each job cost: its passes, their mean and
-- dearest (and when), how many took `COST_SLOW_MS` or more, and any that
-- failed. The numbers to optimize on, from a running server and every game.
-- 1.7.1: A PASS'S OWN COST is its time less the frames it waited in its breaths
-- (`M.Breathe`, counted by coroutine): 1.7.0 counted them, and a game at four
-- frames a second read a 532 ms "pass" that was two breaths (Staging,
-- 2026-10-29). The longest pass with its waits is said beside it. AND THE
-- NATIVES: every native called through `M.Native` is timed too -- the line ends
-- with the dearest of them -- and one that takes `NATIVE_SLOW_MS` or more is a
-- line at once ("slow native: ...", once a minute a native), with the job it
-- ran in: the one-frame hitches (an exit's pass took 64.5 ms in one frame on
-- the laptop) named by what took them. A host whose clock stands still within
-- a tick (the server's) times nothing from Lua: its line says so.
M.COST_FIRST_MS = 60000
M.COST_EVERY_MS = 300000
M.COST_SLOW_MS = 50.0
M.NATIVE_SLOW_MS = 20.0
local jobCosts = {}
local costFrom, costLines = nil, 0
-- Whether this host's clock ever moved within a pass.
local clockMoved = false
-- The job whose pass runs now (for a native's line), and each running job's
-- waits in its breaths this pass, by coroutine.
local currentJob = nil
local breathBy = {}
-- What each native cost since the last line: `{ [name] = { calls, ms, max, maxJob } }`.
local nativeCosts = {}
local slowSaid = {}

--- What each native called through `M.Native` cost since the last line.
function M.NativeCosts() return nativeCosts end

-- The host's clock, read straight (a native's time is two reads of it).
local monotonic = nil
local function stamp()
    if monotonic == nil then
        local time = type(Open77) == 'table' and Open77.time or nil
        monotonic = (type(time) == 'table' and type(time.monotonic) == 'function') and time.monotonic or false
    end
    if monotonic then return monotonic() * 1000.0 end
    return M.Clock()
end

--- Calls a native through `pcall`, timed (1.7.1): the same answers as `pcall`
--- (three values at most after its own).
-- @param name string for the log ('travel.teleport')
-- @param fn function the native
-- @return boolean, ... as `pcall`
function M.Native(name, fn, ...)
    if type(fn) ~= 'function' then return false, 'no ' .. tostring(name) .. ' on this host' end
    local began = stamp()
    local ok, a, b, c = pcall(fn, ...)
    local spent = stamp() - began
    local row = nativeCosts[name]
    if row == nil then
        row = { calls = 0, ms = 0.0, max = 0.0 }
        nativeCosts[name] = row
    end
    row.calls = row.calls + 1
    row.ms = row.ms + spent
    if spent > row.max then
        row.max, row.maxJob = spent, currentJob
        if spent >= M.NATIVE_SLOW_MS then
            local now = M.Now()
            if slowSaid[name] == nil or now - slowSaid[name] >= 60000 then
                slowSaid[name] = now
                Open77.log.warn(('slow native: %s took %.1f ms in one call (%s; said once a minute a native)'):format(
                    name, spent, currentJob ~= nil and ('the ' .. currentJob .. ' pass') or 'an event or a one-off'))
            end
        end
    end
    return ok, a, b, c
end

local function nativesText()
    local rows = {}
    for name, row in pairs(nativeCosts) do
        if row.ms > 0 then rows[#rows + 1] = { name = name, row = row } end
    end
    table.sort(rows, function(a, b) return a.row.max > b.row.max end)
    local parts = {}
    for i = 1, math.min(#rows, 5) do
        local row = rows[i].row
        parts[#parts + 1] = ('%s %d call(s), %.2f ms on average, %.2f ms the dearest%s'):format(rows[i].name, row.calls,
            row.ms / row.calls, row.max, row.maxJob ~= nil and (' (' .. row.maxJob .. ')') or '')
    end
    return #parts > 0 and ('; natives, the dearest first: ' .. table.concat(parts, '; ')) or ''
end

--- What each job cost since the last line: `{ [name] = { passes, ms, max, maxAt, slow, failures } }`.
function M.JobCosts() return jobCosts end

local function costLine(now)
    local names = {}
    for name in pairs(jobCosts) do names[#names + 1] = name end
    table.sort(names)
    local parts = {}
    for _, name in ipairs(names) do
        local row = jobCosts[name]
        if row.passes > 0 then
            if clockMoved then
                parts[#parts + 1] = ('%s %d pass(es), %.2f ms on average, %.2f ms the dearest (%.0fs ago)%s%s%s'):format(
                    name, row.passes, row.ms / row.passes, row.max, (now - (row.maxAt or now)) / 1000.0,
                    row.wallMax > row.max + 5.0 and (', the longest %.0f ms with its waits'):format(row.wallMax) or '',
                    row.slow > 0 and (', %d of %.0f ms or more'):format(row.slow, M.COST_SLOW_MS) or '',
                    row.failures > 0 and (', %d FAILED'):format(row.failures) or '')
            else
                parts[#parts + 1] = ('%s %d pass(es)%s'):format(name, row.passes,
                    row.failures > 0 and (', %d FAILED'):format(row.failures) or '')
            end
        end
    end
    if #parts > 0 then
        Open77.log.info(('job costs over the last %.0fs (%s): %s%s%s'):format((now - costFrom) / 1000.0,
            M.RESOURCE or 'open77_avdoor', table.concat(parts, '; '), clockMoved and nativesText() or '',
            clockMoved and '' or ' (this host\'s clock stands still within a tick: no pass is timed from Lua here)'))
    end
    jobCosts, nativeCosts = {}, {}
    costFrom = now
    costLines = costLines + 1
end

local function costOf(name, spent, wall, failed)
    local now = M.Now()
    local row = jobCosts[name]
    if row == nil then
        row = { passes = 0, ms = 0.0, max = 0.0, wallMax = 0.0, slow = 0, failures = 0 }
        jobCosts[name] = row
    end
    if wall > 0 then clockMoved = true end
    row.passes = row.passes + 1
    row.ms = row.ms + spent
    if spent > row.max then row.max, row.maxAt = spent, now end
    if wall > row.wallMax then row.wallMax = wall end
    if spent >= M.COST_SLOW_MS then row.slow = row.slow + 1 end
    if failed then row.failures = row.failures + 1 end
    if costFrom == nil then costFrom = now end
    if now - costFrom >= (costLines == 0 and M.COST_FIRST_MS or M.COST_EVERY_MS) then costLine(now) end
end

--- Runs `fn` every `ms` milliseconds on a thread of its own until cancelled.
--- A pass that raises is said in the log and the job goes on: one bad pass
--- must not retire the scan for the session. Every pass is timed (`M.JobCosts`).
-- @param name string for the log
-- @param ms number
-- @param fn function
-- @return table the handle `M.Cancel` takes
function M.Every(name, ms, fn)
    local handle = { name = name, live = true, ms = math.max(0, math.floor(tonumber(ms) or 0)) }
    CreateThread(function()
        local me = type(coroutine) == 'table' and type(coroutine.running) == 'function' and coroutine.running() or nil
        while handle.live do
            Wait(handle.ms)
            if not handle.live then break end
            local began = M.Clock()
            if me ~= nil then breathBy[me] = 0.0 end
            currentJob = name
            local ran, failure = pcall(fn)
            currentJob = nil
            if not ran then
                Open77.log.error(('the %s pass failed: %s'):format(name, tostring(failure)))
            end
            local wall = M.Clock() - began
            local waited = me ~= nil and breathBy[me] or 0.0
            if me ~= nil then breathBy[me] = nil end
            costOf(name, math.max(0.0, wall - waited), wall, not ran)
        end
    end)
    return handle
end

--- Stops a job `M.Every` started. Idempotent.
-- @param handle table|nil
function M.Cancel(handle)
    if type(handle) == 'table' then handle.live = false end
end

--- A breath: the rest of this work in the next resume (`Wait(0)`), when the
--- code runs in a task that may yield (a thread, an event handler).
--
-- THE HOST'S BUDGET (1.5.1). A resume that runs 10 000 VM instructions meets
-- the host's count hook, which kills it when the clock is past its slice -- on
-- a loaded client always (scripting/src/ResourceHost.cpp, `InstructionHook`;
-- "loops split their work into resumes of fewer than 10 000 instructions and
-- yield between them"). The laptop's exit lost two passes to it, mid-way
-- (Staging, 2026-10-28, 04:39:17 and :23). Heavy steps breathe between them.
-- @return boolean whether it yielded
function M.Breathe()
    local co = coroutine
    if type(co) == 'table' and type(co.isyieldable) == 'function' and not co.isyieldable() then return false end
    local from = M.Clock()
    local job = currentJob
    Wait(0)
    currentJob = job
    -- The frames waited are not what a pass cost (client/main.lua, `passCost`;
    -- `M.Every`, by coroutine).
    local waited = M.Clock() - from
    M.Breathed = (M.Breathed or 0) + waited
    local me = type(co) == 'table' and type(co.running) == 'function' and co.running() or nil
    if me ~= nil and breathBy[me] ~= nil then breathBy[me] = breathBy[me] + waited end
    return true
end

--- Milliseconds on the host's monotonic clock, unrounded: what a pass costs
--- (`M.Every`), the frames a breath waited (`M.Breathe`).
-- @return number
function M.Clock()
    local time = type(Open77) == 'table' and Open77.time or nil
    if type(time) == 'table' and type(time.monotonic) == 'function' then
        local read, seconds = pcall(time.monotonic)
        if read and type(seconds) == 'number' then return seconds * 1000.0 end
    end
    return M.Now()
end

-- Per-player windows, by `player|key`.
local cooling = {}

--- Whether one player's action is still inside its cooldown; when it is not,
--- the window starts now.
-- @param playerId any
-- @param key string
-- @param everyMs number
-- @return boolean true when the action must be refused
function M.Cooling(playerId, key, everyMs)
    local id = tonumber(playerId)
    if id == nil or id <= 0 then return false end
    local slot = id .. '|' .. key
    local now = M.Now()
    if cooling[slot] ~= nil and now - cooling[slot] < everyMs then return true end
    cooling[slot] = now
    return false
end

--- Drops a departing player's windows: an id is recycled, and a window left
--- behind would refuse the next holder's first press.
-- @param playerId any
function M.ForgetCooling(playerId)
    local prefix = tostring(tonumber(playerId) or playerId) .. '|'
    for slot in pairs(cooling) do
        if slot:sub(1, #prefix) == prefix then cooling[slot] = nil end
    end
end

--- A result: `{ ok = true, value }` or `{ ok = false, error, detail }`.
function M.Ok(value) return { ok = true, value = value } end
function M.Err(code, detail) return { ok = false, error = code, detail = detail } end

-- ── the records and the settings ─────────────────────────────────────────────

--- Whether a record names an aircraft this resource draws a door on.
-- @param record any
-- @param patterns table|nil Lua patterns; `M.Settings.RECORDS` when nil
-- @return boolean
local function isAircraft(record, list)
    if type(list) ~= 'table' then return false end
    local lowered = record:lower()
    for _, pattern in ipairs(list) do
        if type(pattern) == 'string' and pattern ~= '' then
            local read, found = pcall(string.find, lowered, pattern:lower())
            if read and found ~= nil then return true end
        end
    end
    return false
end

-- MEMOS KEYED BY A SETTINGS TABLE. Plain tables: the client's sandbox has no
-- `setmetatable` (scripting/src/ResourceHost.cpp, `OpenSandbox`), so no weak
-- keys -- 1.5.1's weak tables stopped the resource from loading on every client
-- ("resource activation failed", 2026-10-28). The settings tables are few and
-- live as long as the resource; a memo that ever holds `MEMO_LISTS` of them, or
-- `MEMO_RECORDS` answers for one, starts again.
local MEMO_LISTS, MEMO_RECORDS = 16, 4096

local function memoOf(memo, key)
    local entry = memo.byKey[key]
    if entry == nil or entry.n >= MEMO_RECORDS then
        if entry == nil then
            if memo.n >= MEMO_LISTS then memo.byKey, memo.n = {}, 0 end
            memo.n = memo.n + 1
        end
        entry = { n = 0, answers = {} }
        memo.byKey[key] = entry
    end
    return entry
end

local function memoSet(entry, record, value)
    if entry.answers[record] == nil then entry.n = entry.n + 1 end
    entry.answers[record] = value
end

-- A record's answer, by pattern list: a record never changes what it is, and
-- the watch asks for every vehicle it walks (1.5.1: the host's budget).
local aircraftOf = { byKey = {}, n = 0 }

function M.IsAircraft(record, patterns)
    if type(record) ~= 'string' or record == '' then return false end
    local list = patterns
    if list == nil then
        list = type(M.Settings) == 'table' and M.Settings.RECORDS or nil
    end
    if type(list) ~= 'table' then return false end
    -- Inline on the common path: the walk over every vehicle asks this of each.
    local known = aircraftOf.byKey[list]
    if known == nil or known.n >= MEMO_RECORDS then known = memoOf(aircraftOf, list) end
    local answer = known.answers[record]
    if answer == nil then
        answer = isAircraft(record, list)
        memoSet(known, record, answer)
    end
    return answer
end

--- The landing call a record makes (`CALLOUTS.KINDS`), or nil. Kinds are tried
--- by name, in order, so a record two kinds match always makes the same call.
-- @param record any
-- @param block table|nil the CALLOUTS block; `M.Settings.CALLOUTS` when nil
-- @return string|nil kind
-- @return table|nil that kind's block
local calloutOf = { byKey = {}, n = 0 }

function M.CalloutKind(record, block)
    if block == nil then block = type(M.Settings) == 'table' and M.Settings.CALLOUTS or nil end
    if type(block) ~= 'table' or type(block.KINDS) ~= 'table' then return nil end
    if type(record) ~= 'string' or record == '' then return nil end
    local known = calloutOf.byKey[block]
    if known == nil or known.n >= MEMO_RECORDS then known = memoOf(calloutOf, block) end
    local hit = known.answers[record]
    if hit == nil then
        local name, kind = M.CalloutKindOf(record, block)
        hit = { name = name, kind = kind }
        memoSet(known, record, hit)
    end
    return hit.name, hit.kind
end

--- `M.CalloutKind` without its memory: the kinds tried by name, in order.
function M.CalloutKindOf(record, block)
    local names = {}
    for name in pairs(block.KINDS) do
        if type(name) == 'string' then names[#names + 1] = name end
    end
    table.sort(names)
    for _, name in ipairs(names) do
        local kind = block.KINDS[name]
        if type(kind) == 'table' and M.IsAircraft(record, kind.RECORDS) then return name, kind end
    end
    return nil
end

--- A number from config, finite and inside a band, or the fallback.
-- @param value any
-- @param low number
-- @param high number
-- @param fallback number
-- @return number
function M.Number(value, low, high, fallback)
    local number = tonumber(value)
    if number == nil or number ~= number or number < low or number > high then return fallback end
    return number
end

--- The seats a role may take, in the order they are filled: the airframe's own
--- order (`AIRFRAMES` ... `SEAT_ORDER`, 1.8.0: the Rayfield Excalibur fills its
--- back seats before the one beside the pilot) when it has one, else `SEATS`.
--- A passenger is never offered `seat_front_left` (the flight controls).
-- @param role string `pilot` or `passenger`
-- @param record any|nil the hull's record
-- @return string[]
function M.SeatsFor(role, record)
    local frame = record ~= nil and M.Airframe(record) or nil
    local declared = frame ~= nil and type(frame.SEAT_ORDER) == 'table' and frame.SEAT_ORDER
        or (type(M.Settings) == 'table' and M.Settings.SEATS or nil)
    local seats = {}
    for _, seat in ipairs(type(declared) == 'table' and declared or {}) do
        if type(seat) == 'string' and seat:match('^seat_[%a_]+$') then
            if role ~= 'passenger' or seat ~= 'seat_front_left' then seats[#seats + 1] = seat end
        end
    end
    if #seats == 0 then
        seats = role == 'passenger'
            and { 'seat_front_right', 'seat_back_left', 'seat_back_right' }
            or { 'seat_front_left', 'seat_front_right', 'seat_back_left', 'seat_back_right' }
    end
    return seats
end

--- The canonical seat name of a ledger entry: the platform's own names, or the
--- FiveM numbers a seat is sometimes spelt as.
-- @param seat any
-- @return string|nil
function M.SeatName(seat)
    if type(seat) == 'string' and seat ~= '' then return seat end
    local number = tonumber(seat)
    if number == -1 then return 'seat_front_left' end
    if number == 0 then return 'seat_front_right' end
    if number == 1 then return 'seat_back_left' end
    if number == 2 then return 'seat_back_right' end
    return nil
end

--- The doors the platform names. A name outside this set is never sent to it.
-- The trunk and the hood are doors too: the Rayfield Excalibur's one door is
-- swung by the platform's trunk (open77_avdoor's archive; `AIRFRAMES`).
M.DOOR_NAMES = { frontLeft = true, frontRight = true, backLeft = true, backRight = true, trunk = true, hood = true }

--- The seat the flight controls are at: the one a PILOT's exit is ejected from
--- by the platform's flight code, and the one a passenger is never offered.
M.PILOT_SEAT = 'seat_front_left'

--- The door of the hull a seat uses, or nil when the seat has none.
-- @param seat any
-- @return string|nil the platform's door name
function M.DoorOf(seat)
    local declared = type(M.Settings) == 'table' and M.Settings.DOORS or nil
    if type(declared) ~= 'table' or type(seat) ~= 'string' then return nil end
    local door = declared[seat]
    if type(door) == 'string' and M.DOOR_NAMES[door] == true then return door end
    return nil
end

--- The boarding settings, each one inside a band.
-- @return table `{ delay, hold, settle }` in milliseconds
local function buildBoardSettings()
    local block = type(M.Settings) == 'table' and M.Settings.BOARD or nil
    if type(block) ~= 'table' then block = {} end
    return {
        delay = math.floor(M.Number(block.DELAY_MS, 0, 5000, 450)),
        hold = math.floor(M.Number(block.HOLD_MS, 0, 60000, 1500)),
        settle = math.floor(M.Number(block.SETTLE_MS, 0, 15000, 2500)),
        -- The door shut in flight (1.7.10).
        closeInFlight = block.CLOSE_IN_FLIGHT ~= false,
        flightSpeed = M.Number(block.FLIGHT_SPEED, 0.2, 50.0, 2.0),
        -- A boarding behind a pilot (1.8.4): how far a hull somebody is aboard
        -- is set down for it, and how long it is held there at most.
        aboardDrop = M.Number(block.ABOARD_DROP_METRES, 0.0, 3.0, 1.0),
        aboardHold = math.floor(M.Number(block.ABOARD_HOLD_MS, 2000, 60000, 20000)),
    }
end
function M.BoardSettings() return cached('board', buildBoardSettings) end

--- The exit settings, each one inside a band; a missing or malformed block is
--- the defaults, and `EXIT = false` is no guard and no door at all.
-- @return table
local function buildExitSettings()
    -- NOT `x and x.EXIT or nil`: an `EXIT = false` is the answer, and `false or
    -- nil` would throw it away.
    local declared = nil
    if type(M.Settings) == 'table' then declared = M.Settings.EXIT end
    local off = declared == false
    local block = type(declared) == 'table' and declared or {}
    return {
        off = off,
        place = not off and block.PLACE ~= false,
        side = M.Number(block.SIDE_METRES, 1.0, 20.0, 6.0),
        forward = M.Number(block.FORWARD_METRES, -20.0, 20.0, 1.5),
        lift = M.Number(block.LIFT_METRES, 0.0, 3.0, 0.25),
        air = M.Number(block.MAX_AIR_METRES, 0.5, 50.0, 4.0),
        near = M.Number(block.NEAR_METRES, 2.0, 200.0, 14.0),
        guard = math.floor(M.Number(block.GUARD_MS, 200, 15000, 2800)),
        jump = M.Number(block.JUMP_METRES, 0.5, 30.0, 2.5),
        danger = M.Number(block.DANGER_METRES, 0.0, 20.0, 3.2),
        settle = math.floor(M.Number(block.SETTLE_MS, 0, 5000, 350)),
        doorHold = math.floor(M.Number(block.DOOR_HOLD_MS, 500, 120000, 9000)),
        reassertEvery = math.floor(M.Number(block.DOOR_REASSERT_MS, 100, 5000, 400)),
        reassertFor = math.floor(M.Number(block.DOOR_REASSERT_FOR_MS, 0, 30000, 3200)),
        land = not off and block.LAND ~= false,
        landDelay = math.floor(M.Number(block.LAND_DELAY_MS, 0, 10000, 1200)),
        landWindow = math.floor(M.Number(block.LAND_WINDOW_MS, 1000, 60000, 20000)),
        -- The set-down's glide (1.7.9, server/land.lua).
        glideFrom = M.Number(block.LAND_GLIDE_FROM_METRES, 0.0, 10.0, 0.5),
        glideSpeed = M.Number(block.LAND_GLIDE_SPEED, 0.3, 10.0, 1.5),
        glideTick = math.floor(M.Number(block.LAND_GLIDE_TICK_MS, 20, 500, 50)),
    }
end
function M.ExitSettings() return cached('exit', buildExitSettings) end

-- ── standing on its gear ─────────────────────────────────────────────────────

--- How a known airframe stands on its landing gear (`AIRFRAMES` ... `LAND`),
--- or nil: `{ height, gear = { { right, forward }, ... }, flat, maxDrop }` --
--- the height of the hull's origin over the ground when its gear feet touch
--- it, where those feet are in the hull's own frame (metres right of the
--- centre line, toward the nose), how far apart the ground under them may be
--- and still be one floor, and the most the hull is ever lowered.
-- @param record any the hull's record
-- @return table|nil
local function buildAirframeLand(record)
    local frame = M.Airframe(record)
    local block = frame ~= nil and frame.LAND or nil
    if type(block) ~= 'table' or type(block.GEAR) ~= 'table' then return nil end
    local height = tonumber(block.HEIGHT)
    if height == nil or height ~= height or height < 0.2 or height > 10.0 then return nil end
    local gear = {}
    for _, foot in ipairs(block.GEAR) do
        local right = type(foot) == 'table' and tonumber(foot[1]) or nil
        local forward = type(foot) == 'table' and tonumber(foot[2]) or nil
        if right == nil or forward == nil or right ~= right or forward ~= forward
            or math.abs(right) > 15.0 or math.abs(forward) > 30.0 then
            return nil
        end
        gear[#gear + 1] = { right, forward }
    end
    if #gear < 3 then return nil end
    return {
        height = height,
        gear = gear,
        flat = M.Number(block.FLAT_METRES, 0.02, 2.0, 0.3),
        maxDrop = M.Number(block.MAX_DROP_METRES, 0.05, 6.0, 0.8),
    }
end
function M.AirframeLand(record) return cached('land|' .. tostring(record), buildAirframeLand, record) end

--- Where a hull's gear feet are on the map.
-- @param centre table `{ x, y }` the hull's origin
-- @param forward table `{ x, y }` the way it faces (any length but zero)
-- @param land table `M.AirframeLand(record)`
-- @return table|nil `{ { x, y }, ... }` in the order of `land.gear`
function M.GearPoints(centre, forward, land)
    if type(centre) ~= 'table' or type(forward) ~= 'table' or type(land) ~= 'table' then return nil end
    local cx, cy = tonumber(centre.x), tonumber(centre.y)
    local fx, fy = tonumber(forward.x), tonumber(forward.y)
    if cx == nil or cy == nil or fx == nil or fy == nil then return nil end
    local length = math.sqrt(fx * fx + fy * fy)
    if length < 1e-6 or length ~= length then return nil end
    fx, fy = fx / length, fy / length
    -- The right of a heading, in the game's axes (x east, y north): facing
    -- north (0, 1), the right is east (1, 0).
    local rx, ry = fy, -fx
    local out = {}
    for index, foot in ipairs(land.gear) do
        out[index] = { x = cx + rx * foot[1] + fx * foot[2], y = cy + ry * foot[1] + fy * foot[2] }
    end
    return out
end

--- The height a hull is lowered to so that it stands on its gear, or nil and
--- why not: every foot must have ground under it, the highest and the lowest
--- within `flat` of each other (one floor, not a kerb or a step), and the
--- hull must come DOWN onto it by at least 5 cm and at most `maxDrop` -- a
--- hull that is already on its gear, or one hovering over a drop, is left
--- where it is. The hull rests on the highest foot's ground.
-- @param hullZ number the hull's origin now
-- @param grounds table `{ z, ... }`, one per gear foot (nil: no ground there)
-- @param land table `M.AirframeLand(record)`
-- @return number|nil z
-- @return string|table why not, or `{ highest, spread, drop }`
function M.LandHeight(hullZ, grounds, land)
    hullZ = tonumber(hullZ)
    if hullZ == nil or hullZ ~= hullZ then return nil, 'no_hull_height' end
    if type(grounds) ~= 'table' or type(land) ~= 'table' then return nil, 'no_ground' end
    local highest, lowest = nil, nil
    for index = 1, #land.gear do
        local z = tonumber(grounds[index])
        if z == nil or z ~= z or z == math.huge or z == -math.huge then return nil, 'no_ground_under_a_foot' end
        highest = highest == nil and z or math.max(highest, z)
        lowest = lowest == nil and z or math.min(lowest, z)
    end
    if highest == nil then return nil, 'no_ground' end
    local spread = highest - lowest
    if spread > land.flat then return nil, ('uneven:%.2f'):format(spread) end
    local target = highest + land.height
    local drop = hullZ - target
    if drop < 0.05 then return nil, ('on_its_gear:%.2f'):format(drop) end
    if drop > land.maxDrop then return nil, ('too_far:%.2f'):format(drop) end
    return target, { highest = highest, spread = spread, drop = drop }
end

--- THE SET-DOWN'S GLIDE (1.7.9): how long a set-down of `drop` metres takes,
--- in ms -- 0 for one of at most `exit.glideFrom` (one move), else the drop
--- at `exit.glideSpeed` metres a second on average, two poses at least.
-- @param drop number metres
-- @param exit table `M.ExitSettings()`
-- @return integer ms
--- THE DOOR SHUT BEFORE THE SEAT (1.7.10): how long into a boarding clip its
--- door is closed -- the body inside and on foot, before the seat (the pilot's
--- game draws a door closed after its seat open in flight). A clip that ends
--- in the seat: `doorCloseSeatClip`, at most `viewLead` before its end; a door's
--- clip: `doorCloseDoorLead` before its end.
-- @param clip string
-- @param ms number the clip's length
-- @param settings table `M.EnterSettings()`
-- @return integer ms into the clip
-- @param lead number|nil an airframe's own lead before a door's clip ends
--   (`AIRFRAMES` ... `DOOR_CLOSE_LEAD_MS`, `M.DoorCloseLead`), in place of
--   `doorCloseDoorLead`
function M.DoorCloseInto(clip, ms, settings, lead)
    ms = math.max(0, math.floor(tonumber(ms) or 0))
    if type(settings) ~= 'table' then return ms end
    if M.SeatClip(clip) then
        return math.max(0, math.min(settings.doorCloseSeatClip or 3300, ms - (settings.viewLead or 600)))
    end
    return math.max(0, ms - (tonumber(lead) or settings.doorCloseDoorLead or 300))
end

--- An airframe's own lead before the end of a door's clip at which the boarding
--- closes its door (`AIRFRAMES` ... `DOOR_CLOSE_LEAD_MS`; the Manticore's
--- sliding panels close as its clip ends, the body in the doorway), or nil.
-- @param record any the hull's record
-- @return integer|nil ms
function M.DoorCloseLead(record)
    local frame = M.Airframe(record)
    local lead = frame ~= nil and tonumber(frame.DOOR_CLOSE_LEAD_MS) or nil
    if lead == nil or lead ~= lead then return nil end
    return math.max(0, math.min(5000, math.floor(lead)))
end

--- Whether the game's own exit from this airframe's seats is animated, so
--- that its exit goes through the exit key and the platform's forced exit
--- (`AIRFRAMES` ... `EXIT_FORCED`, `LEAVE`; the Militech Manticore's).
-- @param record any the hull's record
-- @return boolean
function M.ExitForced(record)
    local frame = M.Airframe(record)
    return frame ~= nil and frame.EXIT_FORCED == true
end

--- THE EXIT KEY (1.9.0): `LEAVE`, read once.
local function buildLeaveSettings()
    local block = M.Settings and M.Settings.LEAVE
    if type(block) ~= 'table' then block = {} end
    local ms = function(value, low, high, fallback)
        return math.floor(M.Number(value, low, high, fallback) + 0.5)
    end
    local id = type(block.ID) == 'string' and block.ID:match('^[%w_.:%-]+$') ~= nil and #block.ID <= 64
        and block.ID or 'open77_avdoor_leave'
    return {
        off = block.ON == false,
        key = type(block.KEY) == 'string' and block.KEY ~= '' and block.KEY or 'F',
        id = id,
        name = type(block.NAME) == 'string' and block.NAME ~= '' and block.NAME:sub(1, 96) or 'Step out of an AV',
        askGap = ms(block.ASK_GAP_MS, 200, 10000, 1500),
        asked = ms(block.ASKED_MS, 500, 15000, 4000),
        serverGap = ms(block.SERVER_GAP_MS, 0, 10000, 750),
    }
end
function M.LeaveSettings() return cached('leave', buildLeaveSettings) end

function M.GlideMs(drop, exit)
    drop = tonumber(drop)
    if drop == nil or drop ~= drop or type(exit) ~= 'table' or drop <= (exit.glideFrom or 0.5) then return 0 end
    return math.max(2 * (exit.glideTick or 50), math.floor(drop / (exit.glideSpeed or 1.5) * 1000.0 + 0.5))
end

--- Where a gliding hull stands `elapsed` ms into a glide of `ms` from `fromZ`
--- down to `toZ`: eased in and out (smoothstep) -- it leaves the hover
--- gently, comes down at half again its mean speed at most, and touches down
--- gently.
-- @param fromZ number
-- @param toZ number
-- @param elapsed number ms
-- @param ms number the glide's length
-- @return number z
function M.GlideZ(fromZ, toZ, elapsed, ms)
    if ms == nil or ms <= 0 or elapsed >= ms then return toZ end
    if elapsed <= 0 then return fromZ end
    local u = elapsed / ms
    return fromZ + (toZ - fromZ) * (u * u * (3.0 - 2.0 * u))
end

--- The watch settings (`WATCH`), each one inside a band; a missing or malformed
--- block is the defaults, and `WATCH = false` is no watch at all.
-- @return table
local function buildWatchSettings()
    local declared = nil
    if type(M.Settings) == 'table' then declared = M.Settings.WATCH end
    local block = type(declared) == 'table' and declared or {}
    return {
        off = declared == false,
        sight = math.floor(M.Number(block.SIGHT_MS, 100, 10000, 500)),
        range = M.Number(block.RANGE, 10.0, 1000.0, 350.0),
        hulls = math.floor(M.Number(block.MAX_HULLS, 1, 16, 3)),
        drift = M.Number(block.DRIFT_METRES, 1.0, 500.0, 10.0),
        perSpeed = M.Number(block.DRIFT_PER_SPEED, 0.0, 5.0, 0.4),
        settle = M.Number(block.SETTLE_METRES, 0.5, 100.0, 4.0),
        repeatMs = math.floor(M.Number(block.REPEAT_MS, 500, 600000, 5000)),
        jump = M.Number(block.JUMP_METRES, 5.0, 5000.0, 45.0),
        heal = declared ~= false and block.HEAL ~= false,
        healEvery = math.floor(M.Number(block.HEAL_EVERY_MS, 1000, 600000, 10000)),
        -- The exit's drag put right (1.6.1, server/watch.lua).
        dragUndo = declared ~= false and block.DRAG_UNDO ~= false,
        dragWindow = math.floor(M.Number(block.DRAG_WINDOW_MS, 1000, 60000, 6000)),
        dragMetres = M.Number(block.DRAG_UNDO_METRES, 0.5, 100.0, 2.0),
        dragMatch = M.Number(block.DRAG_MATCH_METRES, 0.5, 50.0, 3.0),
    }
end
function M.WatchSettings() return cached('watch', buildWatchSettings) end

--- The pad snap's settings (`PAD_SNAP`, server/snap.lua), each inside a band;
--- `PAD_SNAP = false` is no snap at all.
-- @return table
local function buildSnapSettings()
    local declared = nil
    if type(M.Settings) == 'table' then declared = M.Settings.PAD_SNAP end
    local block = type(declared) == 'table' and declared or {}
    local surface = type(block.SURFACE_METRES) == 'table' and block.SURFACE_METRES or {}
    local records = {}
    for _, pattern in ipairs(type(block.RECORDS) == 'table' and block.RECORDS or { '^vehicle%.av_', '^vehicle%.max_tac_av$' }) do
        if type(pattern) == 'string' then records[#records + 1] = pattern:lower() end
    end
    -- 1.8.3: how an AV somebody flies is taken (`ABOARD`): 'dock' (the
    -- default: one move under a short dip to black), 'glide' (`true`: flown
    -- down in view, their view flickers) or 'off' (`false`: left to them).
    local mode = 'dock'
    if block.ABOARD == false or block.ABOARD == 'off' then mode = 'off'
    elseif block.ABOARD == true or block.ABOARD == 'glide' then mode = 'glide' end
    local dock = type(block.DOCK) == 'table' and block.DOCK or {}
    return {
        off = declared == false,
        aboard = mode ~= 'off',
        aboardMode = mode,
        dock = {
            out = math.floor(M.Number(dock.FADE_OUT_MS, 0, 2000, 200)),
            wait = math.floor(M.Number(dock.WAIT_MS, 200, 5000, 1000)),
            hold = math.floor(M.Number(dock.HOLD_MS, 0, 5000, 500)),
            back = math.floor(M.Number(dock.FADE_IN_MS, 0, 3000, 350)),
        },
        records = records,
        height = M.Number(block.HEIGHT_METRES, 3.0, 200.0, 40.0),
        margin = M.Number(block.MARGIN_METRES, 0.0, 30.0, 6.0),
        maxSpeed = M.Number(block.MAX_SPEED, 1.0, 60.0, 10.0),
        climbMax = M.Number(block.CLIMB_MAX, 0.0, 10.0, 0.5),
        looks = math.floor(M.Number(block.LOOKS, 1, 10, 2)),
        rearm = M.Number(block.REARM_METRES, 1.0, 200.0, 15.0),
        measureMs = math.floor(M.Number(block.MEASURE_MS, 200, 10000, 2000)),
        surface = {
            high = M.Number(surface.high, 0.2, 50.0, 2.0),
            medium = M.Number(surface.medium, 0.2, 50.0, 4.0),
            low = M.Number(surface.low, 0.2, 100.0, 12.0),
        },
        flat = M.Number(block.FLAT_METRES, 0.05, 3.0, 0.4),
        tickMs = math.floor(M.Number(block.TICK_MS, 20, 500, 50)),
        glide = M.Number(block.GLIDE_SPEED, 0.5, 30.0, 4.0),
        turnRate = M.Number(block.TURN_RATE, 5.0, 360.0, 45.0),
        descent = M.Number(block.DESCENT, 0.2, 20.0, 2.5),
        approach = M.Number(block.APPROACH_METRES, 0.5, 30.0, 3.0),
        touchdown = M.Number(block.TOUCHDOWN, 0.1, 5.0, 0.8),
        hover = M.Number(block.HOVER_METRES, 0.5, 20.0, 2.5),
        holdMs = math.floor(M.Number(block.HOLD_MS, 0, 30000, 1200)),
        maxMs = math.floor(M.Number(block.MAX_MS, 2000, 300000, 30000)),
    }
end
function M.SnapSettings() return cached('snap', buildSnapSettings) end

--- The drift at which a hull moving at `speed` m/s counts as drawn elsewhere.
--- An observer draws a moving hull a jitter buffer (75 to 180 ms, plus up to
--- 180 ms of prediction) behind its newest sample, so a fast hull is always
--- some metres from it; that much is not a drift.
-- @param watch table `M.WatchSettings()`
-- @param speed number|nil
-- @return number metres
function M.DriftLimit(watch, speed)
    local moving = tonumber(speed)
    if moving == nil or moving ~= moving or moving < 0 then moving = 0.0 end
    if moving > 200.0 then moving = 200.0 end
    return watch.drift + watch.perSpeed * moving
end

--- Which side of the hull a seat's door is on: `1` for the left, `-1` for the
--- right. The pilot's seat is the left one.
-- @param seat any
-- @return integer
function M.SeatSide(seat)
    if type(seat) == 'string' and seat:find('right', 1, true) ~= nil then return -1 end
    return 1
end

--- The known airframe a record is (`AIRFRAMES` in shared/config.lua), or nil.
-- @param record any the hull's TweakDB record
-- @return table|nil the airframe's block
local function buildAirframe(record)
    if type(record) ~= 'string' or type(M.Settings) ~= 'table' or type(M.Settings.AIRFRAMES) ~= 'table' then
        return nil
    end
    local lower = record:lower()
    for _, frame in ipairs(M.Settings.AIRFRAMES) do
        if type(frame) == 'table' and type(frame.RECORDS) == 'table' then
            for _, pattern in ipairs(frame.RECORDS) do
                if type(pattern) == 'string' and lower:find(pattern) ~= nil then return frame end
            end
        end
    end
    return nil
end
function M.Airframe(record) return cached('airframe|' .. tostring(record), buildAirframe, record) end

--- The door a seat's body steps out of: the side of the hull it is on, and,
--- for a known airframe, how far out from the centre line its outer face is,
--- how far toward the nose, and the platform's name for it. The Rayfield
--- Excalibur has one door, on the left, so every seat of it leaves on the left.
-- @param record any the hull's record
-- @param seat any the seat that was left
-- @return table `{ side = 1 | -1, out = metres|nil, forward = metres|nil, door = name|nil, airframe = name|nil }`
local function buildSeatDoor(record, seat)
    local frame = M.Airframe(record)
    local spec = frame ~= nil and type(frame.SEATS) == 'table' and type(seat) == 'string' and frame.SEATS[seat] or nil
    if type(spec) ~= 'table' then return { side = M.SeatSide(seat) } end
    local side = M.SeatSide(seat)
    if spec.SIDE == 'left' then side = 1 elseif spec.SIDE == 'right' then side = -1 end
    local out = tonumber(spec.OUT)
    if out ~= nil and (out ~= out or out < 0.3 or out > 15.0) then out = nil end
    local forward = tonumber(spec.FORWARD)
    if forward ~= nil and (forward ~= forward or forward < -30.0 or forward > 30.0) then forward = nil end
    local door = type(spec.DOOR) == 'string' and M.DOOR_NAMES[spec.DOOR] == true and spec.DOOR or nil
    -- The top of the door's step, in metres under the hull's origin: the exit
    -- clip's first frame stands on it (`AIRFRAMES` ... `STEP`).
    local step = tonumber(spec.STEP or frame.STEP)
    if step ~= nil and (step ~= step or step < -3.0 or step > 5.0) then step = nil end
    return { side = side, out = out, forward = forward, door = door, step = step,
        airframe = type(frame.NAME) == 'string' and frame.NAME or nil }
end
function M.SeatDoor(record, seat) return cached('door|' .. tostring(record) .. '|' .. tostring(seat), buildSeatDoor, record, seat) end

-- THE CLIP'S FIRST STEP ON THE DOOR'S STEP. A clip starts `rise` metres over
-- the ground it ends on (`M.WALK_CLIPS`); the door's step must stand within
-- `STEP_UNDER` under and `STEP_OVER` over that, or the first frames are seen in
-- the air beside the door ("the player was floating in air for the exit anim
-- while the av doors where open", XyberRP Staging, 2026-10-28) or sunk in it.
-- The Rayfield Excalibur on its gear: 0.62 m for the step clip's 0.5 m; left
-- where the flight put it, 1.1 m.
M.STEP_UNDER = 0.25
M.STEP_OVER = 0.35
-- THE STEP ON A SLOPE (1.6.2). An AV parked where the ground falls away beside
-- its door leaves its step higher over the clip's end point than on a flat pad:
-- 0.92 m on Staging (2026-10-28, 14:41:26, the Excalibur on its gear, its feet's
-- ground 113.49 to 113.78, the end point's 113.5) -- no clip, by 7 cm. So before
-- an exit gives up its clip, the step is turned about the door (`STEP_TURNS`,
-- degrees: the clip still starts on the door, its end point swings along the
-- hull, where the ground may stand higher); a turn that brings the step into the
-- band wins (the smallest one), else the band is relaxed to `STEP_UNDER_RELAXED`
-- and `STEP_OVER_RELAXED` (the first frames, under the fade-in, a little off the
-- step) on the heading itself, then on a turn; past that there is no clip.
M.STEP_UNDER_RELAXED = 0.35
M.STEP_OVER_RELAXED = 0.5
M.STEP_TURNS = { 0, 15, -15, 30, -30 }
M.STEP_TURN_MAX = 30.0

--- The band of step heights a clip can start from, or nil for a clip that
--- starts on the ground.
-- @param clip string a key of `M.WALK_CLIPS`
-- @param relaxed boolean|nil the relaxed band (`STEP_UNDER_RELAXED`, `STEP_OVER_RELAXED`)
-- @return number|nil lowest
-- @return number|nil highest
function M.StepBand(clip, relaxed)
    local spec = M.WALK_CLIPS ~= nil and M.WALK_CLIPS[clip] or nil
    if spec == nil or (spec.rise or 0) <= 0 then return nil, nil end
    if relaxed then return spec.rise - M.STEP_UNDER_RELAXED, spec.rise + M.STEP_OVER_RELAXED end
    return spec.rise - M.STEP_UNDER, spec.rise + M.STEP_OVER
end

--- How a door's step fits a clip: 'in' (the band), 'relaxed' (only the
--- relaxed band), 'high' or 'low' (past it), or nil when it cannot be judged.
-- @param clip string
-- @param step number|nil metres over the end point's ground
-- @return string|nil
function M.StepFit(clip, step)
    local lo, hi = M.StepBand(clip)
    if lo == nil or step == nil then return nil end
    if step >= lo and step <= hi then return 'in' end
    local rlo, rhi = M.StepBand(clip, true)
    if step >= rlo and step <= rhi then return 'relaxed' end
    return step > rhi and 'high' or 'low'
end

--- A step turn, bounded (`STEP_TURN_MAX`), or 0.
-- @param turn any
-- @return number degrees
function M.StepTurn(turn)
    turn = tonumber(turn)
    if turn == nil or turn ~= turn then return 0.0 end
    return math.max(-M.STEP_TURN_MAX, math.min(M.STEP_TURN_MAX, turn))
end

--- How far over the end point's ground the door's step stands, or nil when
--- the airframe's step is not known.
-- @param hullZ number the hull's origin
-- @param door table `M.SeatDoor(record, seat)`
-- @param ground number|nil the ground under the clip's end point
-- @return number|nil metres
function M.StepHeight(hullZ, door, ground)
    hullZ, ground = tonumber(hullZ), tonumber(ground)
    if type(door) ~= 'table' or door.step == nil or hullZ == nil or ground == nil then return nil end
    return hullZ - door.step - ground
end

-- ── what the engine draws ────────────────────────────────────────────────────
-- `Open77.world.entityGeometry` resolves an ENTITY id of 0 to the local player
-- (client/src/api/ZoneGeometry.cpp: `handle.value==0 ? LocalPlayer() : ...`),
-- and a vehicle snapshot's `entity` is 0 while its hull is not streamed. A
-- hull read through that 0 is the body of whoever asks: on XyberRP Staging
-- (2026-10-28, 20:10:06 local) a landing sign was drawn under the laptop's
-- player for a hull 23 m away that had just appeared. So an entity id is
-- passed only when it names something, and an answer for entity 0 is never a
-- hull's.

--- An engine entity id worth asking about, or nil (0, negative, not a whole
--- number). The suites name entities by text.
-- @param value any
-- @return integer|string|nil
function M.EntityRef(value)
    if type(value) == 'number' then
        if value ~= value or value <= 0 or value ~= math.floor(value) then return nil end
        return math.tointeger(value) or value
    end
    if type(value) == 'string' and value ~= '' and value ~= '0' then return value end
    return nil
end

--- Whether a geometry answer is an entity's own -- not the local player
--- answered for an entity id of 0, and attached.
-- @param answer any
-- @return boolean
function M.EntityAnswer(answer)
    if type(answer) ~= 'table' or answer.attached == false then return false end
    if answer.entity ~= nil and tonumber(answer.entity) == 0 then return false end
    return true
end

--- The platform door to swing for a seat that was left: the airframe's own
--- (`AIRFRAMES`), else the seat's (`DOORS`).
-- @param record any
-- @param seat any
-- @return string|nil
function M.ExitDoorName(record, seat)
    local known = M.SeatDoor(record, seat)
    if known.door ~= nil then return known.door end
    return M.DoorOf(seat)
end

--- Where on the map a body that stepped out of a seat is put. The first
--- attempt is beside that seat's door: `SIDE_METRES` out from the hull's centre
--- and `FORWARD_METRES` toward the nose. The others are the places to try when
--- that one has no ground under it (a hull parked at the edge of a roof): the
--- other side, then behind the hull, then ahead of it. The height is a separate
--- question (`M.ExitLevel`) because the ground has to be measured at THIS point.
-- @param centre table `{ x, y }` the hull's centre
-- @param forward table `{ x, y }` the way the hull faces (any length but zero)
-- @param seat any the seat that was left
-- @param settings table `M.ExitSettings()`
-- @param attempt integer|nil 1 (the default) to `M.EXIT_ATTEMPTS`
-- @param door table|nil `M.SeatDoor(record, seat)`: a known airframe's door
--   side and place along the hull win over the seat's
-- @return number|nil x
-- @return number y
function M.ExitPoint(centre, forward, seat, settings, attempt, door)
    if type(centre) ~= 'table' or type(forward) ~= 'table' then return nil end
    local cx, cy = tonumber(centre.x), tonumber(centre.y)
    local fx, fy = tonumber(forward.x), tonumber(forward.y)
    if cx == nil or cy == nil or fx == nil or fy == nil then return nil end
    if cx ~= cx or cy ~= cy or fx ~= fx or fy ~= fy then return nil end
    local length = math.sqrt(fx * fx + fy * fy)
    if length < 1e-6 then return nil end
    fx, fy = fx / length, fy / length
    -- The left of a heading, in the game's own axes (x east, y north): facing
    -- north (0, 1) the left is west (-1, 0).
    local lx, ly = -fy, fx
    local which = math.floor(tonumber(attempt) or 1)
    local doorSide = type(door) == 'table' and door.side or M.SeatSide(seat)
    local doorAlong = type(door) == 'table' and door.forward or settings.forward
    local side, along = 0.0, 0.0
    if which == 1 then
        side, along = doorSide * settings.side, doorAlong
    elseif which == 2 then
        side, along = -doorSide * settings.side, doorAlong
    elseif which == 3 then
        side, along = 0.0, -settings.side
    else
        side, along = 0.0, settings.side
    end
    return cx + lx * side + fx * along, cy + ly * side + fy * along
end

--- How many places `M.ExitPoint` offers.
M.EXIT_ATTEMPTS = 4

-- ── the animated exit ────────────────────────────────────────────────────────

--- The clips of the `avexit` package (open77_avexit): how long each one plays,
--- and where the door's end of it stands the body relative to the player
--- entity -- the hips, in the entity's own frame (`right` toward +x, `forward`
--- toward +y, metres), the mean of the female and male cuts (they differ by
--- 6 %, the man's legs being shorter in the proxy rig). An exit clip ENDS where
--- the entity stands: `right`/`forward` is its FIRST frame, on the door's step,
--- `rise` metres over the entity's ground. The enter clips (1.7.0, `first`)
--- START where the entity stands: `right`/`forward` is their LAST frame, in
--- the door, `rise` metres up. Either way the door's end lands on the door
--- point for the same plan (`M.WalkOutPlan`). Measured from the cooked banks
--- (`docs/research/av-door-and-autopilot.md`, "The exit, animated" and "The
--- boarding, animated"). The package's `exit` and `exit_m` (from the seat,
--- 7.3 s; never played: the step starts on the door) gave their slots to the
--- enter in open77_avexit 1.1.0.
--- THE SEAT CLIP (1.7.7, open77_avexit 1.2.0, `seat`): `sit` ends SITTING IN
--- A SEAT, not in the door -- the Rayfield Excalibur's boarding in the side
--- quest sq012, into `seat_front_left`. Its `right`/`forward`/`rise` are the
--- root's last key (the place the game's scene puts on the seat's slot), and
--- `turn` the root's turn by then, in degrees (REDengine's: toward -x): the
--- body is put so that this end lands on the seat's slot, facing the slot's way
--- (`M.SitPlan`). Its step up is the scene's raised 0.27 m (the scene's AV
--- stood lower on its pad): `rise` is the seat's height over the ground the
--- clip starts on. It took the slot of `walk` (beside the door, 2.9 s, an exit
--- clip no setting chose).
--- THE COUCH CLIP (1.8.0, open77_avexit 1.3.0, `couch`): Corpo V's boarding of
--- Jenkins' AV in the game's opening (q000), made to end sitting on the Rayfield
--- Excalibur's back-left seat: it starts outside the door FACING the AV, steps
--- into the folded door's tray and up onto the floor, walks in, turns 90 deg to
--- its left and sits down facing ahead. A seat clip like `sit`: its end (the
--- scene's last root key, in the frame of the body's first place) lands on the
--- seat's slot. It took the slot of `enter_m` (the door's clip mirrored, for a
--- door on the hull's right: only the Manticore has one, now boarded plainly).
--- 1.8.1 (open77_avexit 1.3.1): it starts 0.40 m farther from the AV -- its end
--- 1.95 m ahead of its start, not 1.55 -- with a longer first step. The entity
--- stands on the clip's first spot while it plays, and the AV's collision pushed
--- a body put on 1.3.0's spot, 0.19 m outside the tray's rim, 0.34 m out before
--- the clip began (Staging, 2026-10-30): the whole clip played 0.34 m off.
M.WALK_CLIPS = {
    enter = { seconds = 2.6, right = 0.150, forward = 1.1695, rise = 0.525, first = true },
    step = { seconds = 4.3, right = 0.643, forward = -2.386, rise = 0.5 },
    sit = { seconds = 5.6, right = -2.2757, forward = 0.5945, rise = 0.9598, turn = -14.773, first = true, seat = true },
    step_m = { seconds = 4.3, right = -0.643, forward = -2.386, rise = 0.5 },
    couch = { seconds = 4.4, right = 0.4473, forward = 1.9519, rise = 0.96, turn = 90.0, first = true, seat = true },
}

--- Whether a clip ends in a seat (`WALK_CLIPS`, `seat`).
-- @param clip any
-- @return boolean
function M.SeatClip(clip)
    local spec = type(clip) == 'string' and M.WALK_CLIPS[clip] or nil
    return spec ~= nil and spec.seat == true
end

--- Whether a clip is an exit's: it ends where the entity stands (not `first`).
-- @param clip any
-- @return boolean
function M.ExitClip(clip)
    local spec = type(clip) == 'string' and M.WALK_CLIPS[clip] or nil
    return spec ~= nil and spec.first ~= true
end

--- The animated exit's settings, each one inside a band; `EXIT_ANIM = false`
--- (or no block) is no animated exit, but the view hold is its own switch.
-- @return table
local function buildWalkOutSettings()
    local declared = nil
    if type(M.Settings) == 'table' then declared = M.Settings.EXIT_ANIM end
    local block = type(declared) == 'table' and declared or {}
    -- An exit plays an exit clip only: one that ends where the entity stands
    -- (1.7.7: not the boarding's, which start there).
    local function clip(name, fallback)
        local value = block[name]
        if M.ExitClip(value) then return value end
        return fallback
    end
    local records = {}
    if type(block.RECORDS) == 'table' then
        for record, value in pairs(block.RECORDS) do
            if type(record) == 'string' and M.ExitClip(value) then
                records[record:lower()] = value
            end
        end
    end
    local assign = block.ASSIGN
    if assign ~= 'join' and assign ~= 'board' then assign = 'board' end
    local viewWait = math.floor(M.Number(block.VIEW_WAIT_MS, 0, 30000, 5000))
    return {
        off = type(declared) ~= 'table',
        style = type(block.STYLE) == 'string' and block.STYLE ~= '' and block.STYLE or 'avexit',
        clip = clip('CLIP', 'step'),
        mirrorClip = clip('MIRROR_CLIP', 'step_m'),
        records = records,
        assign = assign,
        styleRetry = math.floor(M.Number(block.STYLE_RETRY_MS, 250, 60000, 2000)),
        styleRetryMax = math.floor(M.Number(block.STYLE_RETRY_MAX_MS, 0, 3600000, 300000)),
        door = M.Number(block.DOOR_METRES, 0.5, 10.0, 2.4),
        doorMargin = M.Number(block.DOOR_MARGIN, 0.0, 3.0, 0.3),
        doorMin = M.Number(block.DOOR_MIN, 0.3, 10.0, 1.2),
        doorMax = M.Number(block.DOOR_MAX, 0.5, 15.0, 4.5),
        blendIn = math.floor(M.Number(block.BLEND_IN_MS, 0, 2000, 0)),
        blendOut = math.floor(M.Number(block.BLEND_OUT_MS, 0, 2000, 450)),
        answer = math.floor(M.Number(block.ANSWER_MS, 100, 5000, 1200)),
        pending = math.floor(M.Number(block.PENDING_MS, 0, 4000, 700)),
        window = math.floor(M.Number(block.WINDOW_MS, 1000, 60000, 32000)),
        freeze = block.FREEZE ~= false,
        hide = block.HIDE ~= false,
        hideMax = math.floor(M.Number(block.HIDE_MAX_MS, 500, 30000, 29000)),
        -- THE PLAN AGAIN BEFORE THE ASK: at most `SETTLE_MS` waiting for the
        -- hull to come down on its gear and for a body moved to a new end
        -- point; an end point that moved more than `REPLAN_METRES` is moved to.
        settle = math.floor(M.Number(block.SETTLE_MS, 0, 10000, 3500)),
        replan = M.Number(block.REPLAN_METRES, 0.05, 3.0, 0.3),
        -- The server's own check of the plan: the clip's end point within
        -- `PLAN_METRES` of where the server's hull puts it, the body (as the
        -- server has it) within `BODY_METRES` of that end point.
        planTolerance = M.Number(block.PLAN_METRES, 0.2, 5.0, 0.75),
        bodyTolerance = M.Number(block.BODY_METRES, 0.3, 10.0, 1.5),
        holdView = type(declared) == 'table' and block.HOLD_VIEW ~= false,
        releaseSpeed = M.Number(block.RELEASE_SPEED, 0.1, 10.0, 0.6),
        viewMax = math.floor(M.Number(block.VIEW_MAX_MS, 1000, 600000, 120000)),
        viewWait = viewWait,
        viewWaitLooks = math.floor(M.Number(block.VIEW_WAIT_LOOKS, 0, 600, 30)),
        viewWaitMax = math.max(viewWait, math.floor(M.Number(block.VIEW_WAIT_MAX_MS, 0, 30000, 12000))),
        legacyOff = block.LEGACY_VIEW_OFF ~= false,
        lift = M.Number(block.LIFT_METRES, 0.0, 1.0, 0.03),
        releaseAfterClip = block.RELEASE_AFTER_CLIP ~= false,
        -- `false` or 0: the clip seen from behind.
        orbit = block.ORBIT_DEGREES == false and 0 or M.Number(block.ORBIT_DEGREES, -180.0, 180.0, 160.0),
        -- The door stays open this long after the clip ends.
        doorAfter = math.floor(M.Number(block.DOOR_AFTER_CLIP_MS, 0, 10000, 1500)),
        -- THE STEP'S HEADING: the body is turned back to it when it faces more
        -- than `FACING_DEGREES` away before the clip is asked (`FACING_TRIES`
        -- times at most), and while the clip starts.
        facing = M.Number(block.FACING_DEGREES, 0.5, 45.0, 4.0),
        facingTries = math.floor(M.Number(block.FACING_TRIES, 0, 10, 3)),
        -- ON ITS FEET (1.5.1): a body that does not stand on the ground when the
        -- clip is due is waited for this long and this many looks (the platform
        -- draws no clip on a body its game has in the air), then put just over
        -- the ground once and waited for as long again; then no clip.
        groundWait = math.floor(M.Number(block.GROUND_WAIT_MS, 0, 10000, 1500)),
        groundWaitLooks = math.floor(M.Number(block.GROUND_WAIT_LOOKS, 0, 100, 6)),
        -- The hold: 'position' (the platform's freeze), 'restriction' (the
        -- engine's NoMovement), or 'none'.
        hold = (block.HOLD == 'restriction' or block.HOLD == 'none') and block.HOLD
            or (block.HOLD == false and 'none' or 'position'),
        -- Every slot the hull publishes, listed once a record at its first exit
        -- (1.5.0's diagnostic): off unless asked (1.7.1) -- the door's slot is
        -- read on its own, and the list was the dearest thing an exit did.
        listSlots = block.LIST_SLOTS == true,
    }
end
function M.WalkOutSettings() return cached('walkout', buildWalkOutSettings) end

--- How far apart two headings are, in degrees (0 to 180).
-- @param a number|nil
-- @param b number|nil
-- @return number|nil
function M.YawApart(a, b)
    a, b = tonumber(a), tonumber(b)
    if a == nil or b == nil or a ~= a or b ~= b then return nil end
    local d = (a - b) % 360.0
    return math.min(d, 360.0 - d)
end

--- The heading of a direction on the ground, REDengine's way: 0 toward +y,
--- growing toward -x.
-- @return number|nil degrees, 0 to 360
function M.YawOfDirection(x, y)
    x, y = tonumber(x), tonumber(y)
    if x == nil or y == nil or (x == 0 and y == 0) then return nil end
    return math.deg(math.atan(-x, y)) % 360.0
end

--- A known airframe's door, in the hull's own frame (REDengine's: +x to its
--- right, +y ahead, +z up): the middle of the step the exit clip's first frame
--- stands on, or nil for a door this resource does not know.
-- @param door table `M.SeatDoor(record, seat)`
-- @return table|nil `{ x, y, z }`
function M.DoorLocal(door)
    if type(door) ~= 'table' or door.out == nil then return nil end
    return { x = -(door.side or 1) * door.out, y = door.forward or 0.0, z = door.step ~= nil and -door.step or 0.0 }
end

--- Where the clip's first frame stands for a body at `at` facing `yaw`, with a
--- metre count of how far that is from the door (the logger's "how far off").
-- @return number|nil metres from `door`
function M.StartOffDoor(at, yaw, clip, door)
    if type(at) ~= 'table' or type(door) ~= 'table' or M.WALK_CLIPS[clip] == nil then return nil end
    local ax, ay = tonumber(at.x), tonumber(at.y)
    if ax == nil or ay == nil then return nil end
    local x, y = M.WalkOutStart({ x = ax, y = ay }, tonumber(yaw) or 0.0, clip)
    local dx, dy = x - (tonumber(door.x) or 0.0), y - (tonumber(door.y) or 0.0)
    return math.sqrt(dx * dx + dy * dy)
end

-- ── the hull's own frame ─────────────────────────────────────────────────────
-- REDengine's: +y ahead, +x to the right, +z up; a frame `{ x, y, z, fx, fy }`
-- faces (fx, fy), and its right is (fy, -fx).

--- A world point in a hull's own frame, or nil.
-- @param frame table `{ x, y, z, fx, fy }`
-- @param point table `{ x, y, z }`
-- @return table|nil `{ x = right, y = ahead, z = up }`
function M.ToHullLocal(frame, point)
    if type(frame) ~= 'table' or type(point) ~= 'table' then return nil end
    local fx, fy = tonumber(frame.fx), tonumber(frame.fy)
    local cx, cy = tonumber(frame.x), tonumber(frame.y)
    local px, py = tonumber(point.x), tonumber(point.y)
    if fx == nil or fy == nil or cx == nil or cy == nil or px == nil or py == nil then return nil end
    local length = math.sqrt(fx * fx + fy * fy)
    if length < 1e-6 then return nil end
    fx, fy = fx / length, fy / length
    local dx, dy = px - cx, py - cy
    local dz = (tonumber(point.z) ~= nil and tonumber(frame.z) ~= nil) and (tonumber(point.z) - tonumber(frame.z)) or nil
    return { x = dx * fy - dy * fx, y = dx * fx + dy * fy, z = dz }
end

--- A point of a hull's own frame in the world, or nil.
-- @param frame table `{ x, y, z, fx, fy }`
-- @param offset table `{ x = right, y = ahead, z = up }`
-- @return table|nil `{ x, y, z }`
function M.FromHullLocal(frame, offset)
    if type(frame) ~= 'table' or type(offset) ~= 'table' then return nil end
    local fx, fy = tonumber(frame.fx), tonumber(frame.fy)
    local cx, cy = tonumber(frame.x), tonumber(frame.y)
    local ox, oy = tonumber(offset.x) or 0.0, tonumber(offset.y) or 0.0
    if fx == nil or fy == nil or cx == nil or cy == nil then return nil end
    local length = math.sqrt(fx * fx + fy * fy)
    if length < 1e-6 then return nil end
    fx, fy = fx / length, fy / length
    local z = tonumber(frame.z)
    if z ~= nil then z = z + (tonumber(offset.z) or 0.0) end
    return { x = cx + ox * fy + oy * fx, y = cy - ox * fx + oy * fy, z = z }
end

--- The same frame turned round: a hull drawn facing the other way.
function M.TurnedFrame(frame)
    if type(frame) ~= 'table' then return nil end
    local out = {}
    for k, v in pairs(frame) do out[k] = v end
    out.fx, out.fy = -(tonumber(frame.fx) or 0.0), -(tonumber(frame.fy) or 1.0)
    out.turned = not frame.turned
    return out
end

--- The middle of a known airframe's door step in the world, for a hull frame:
--- where the exit clip's first frame must stand. Nil for a door this resource
--- does not know.
-- @param frame table `{ x, y, z, fx, fy }`
-- @param door table `M.SeatDoor(record, seat)`
-- @return table|nil `{ x, y, z }`
function M.DoorWorld(frame, door)
    local offset = M.DoorLocal(door)
    if offset == nil then return nil end
    return M.FromHullLocal(frame, offset)
end

-- THE DOOR AS EACH GAME DRAWS IT. A known airframe's door hangs on slots of
-- its own entity (`AIRFRAMES` ... `DOOR_SLOTS`; the Rayfield Excalibur's on
-- `vehicle_slots`, docs/research/av-door-and-autopilot.md): read through
-- `Open77.character.bonePosition({ vehicleId }, name)`, a slot is where THAT
-- game draws the door -- the mesh, not a table of numbers. Its place in the
-- hull's frame says on which side the door is drawn, and whether the frame the
-- exit is planned on is the hull every game draws.

--- A known airframe's door slots: `{ names, x, y, tolerance }` (the slot's
--- expected place in the hull's frame), or nil.
-- @param record any
local function buildDoorSlots(record)
    local frame = M.Airframe(record)
    local block = frame ~= nil and type(frame.DOOR_SLOTS) == 'table' and frame.DOOR_SLOTS or nil
    if block == nil or type(block.NAMES) ~= 'table' or #block.NAMES == 0 then return nil end
    local names = {}
    for _, name in ipairs(block.NAMES) do
        if type(name) == 'string' and name:match('^[%w_]+$') then names[#names + 1] = name end
    end
    if #names == 0 then return nil end
    return { names = names, x = M.Number(block.X, -10.0, 10.0, -1.05), y = M.Number(block.Y, -15.0, 15.0, 0.0),
        tolerance = M.Number(block.TOLERANCE, 0.1, 5.0, 0.6), along = M.Number(block.ALONG, 0.1, 15.0, 1.6) }
end
function M.DoorSlots(record) return cached('slots|' .. tostring(record), buildDoorSlots, record) end

--- What a door slot read in a hull's frame says.
-- @param slots table `M.DoorSlots(record)`
-- @param at table the slot's place in the hull's frame (`M.ToHullLocal`)
-- @return string 'right' (where the plan has it) | 'mirrored' (on the other
--   side: the frame faces the other way) | 'off' (anywhere else)
-- @return number how far it stands from where the plan has it, in metres
function M.DoorSlotVerdict(slots, at)
    if type(slots) ~= 'table' or type(at) ~= 'table' then return 'off', math.huge end
    local x, y = tonumber(at.x) or 0.0, tonumber(at.y) or 0.0
    local off = math.abs(x - slots.x)
    local alongOff = math.max(0.0, math.abs(y - slots.y) - slots.along)
    if off <= slots.tolerance and alongOff == 0.0 then return 'right', off end
    -- Turned round, a slot on the left is drawn on the right, its place along
    -- the hull mirrored too.
    local mirror = math.abs(x + slots.x)
    local mirrorAlong = math.max(0.0, math.abs(-y - slots.y) - slots.along)
    if mirror <= slots.tolerance and mirrorAlong == 0.0 then return 'mirrored', mirror end
    return 'off', math.sqrt(off * off + alongOff * alongOff)
end

--- The exit's sync settings (`SYNC`), each one inside a band; `SYNC = false`
--- is no scene: the clip starts when the exiting game asks, as before 1.4.0.
-- @return table
local function buildSyncSettings()
    local declared = nil
    if type(M.Settings) == 'table' then declared = M.Settings.SYNC end
    local block = type(declared) == 'table' and declared or {}
    return {
        off = declared == false,
        range = M.Number(block.RANGE_METRES, 10.0, 1000.0, 150.0),
        readyMax = math.floor(M.Number(block.READY_MAX_MS, 500, 20000, 4500)),
        waitMax = math.floor(M.Number(block.WAIT_MAX_MS, 0, 20000, 5000)),
        holdMax = math.floor(M.Number(block.HOLD_MAX_MS, 0, 20000, 3500)),
        hull = M.Number(block.HULL_METRES, 0.05, 20.0, 0.5),
        body = M.Number(block.BODY_METRES, 0.1, 20.0, 0.75),
        sample = math.floor(M.Number(block.SAMPLE_MS, 0, 5000, 200)),
        republish = block.REPUBLISH ~= false,
        -- What a report calls wrong: a body turned more than `FACING_DEGREES`
        -- from the step's heading, a first step drawn more than `STEP_METRES`
        -- from the door, a body's movement older than `STALE_MS` on a screen
        -- (the platform plays no clip on a body whose movement is stale).
        facing = M.Number(block.FACING_DEGREES, 1.0, 90.0, 15.0),
        step = M.Number(block.STEP_METRES, 0.1, 10.0, 0.6),
        stale = math.floor(M.Number(block.STALE_MS, 50, 10000, 600)),
        -- 1.7.8: another player's boarding seated at once on this screen once
        -- the ledger names the seat (client/sync.lua).
        presentSeat = block.PRESENT_SEAT ~= false,
    }
end
function M.SyncSettings() return cached('sync', buildSyncSettings) end

--- The clip an exit through this seat's door plays: the record's own, else
--- the side's (`CLIP` on the left, `MIRROR_CLIP` on the right).
-- @param record any the hull's record
-- @param seat any the seat that was left
-- @param anim table `M.WalkOutSettings()`
-- @return string the clip id
function M.WalkOutClip(record, seat, anim)
    if type(record) == 'string' then
        local own = anim.records[record:lower()]
        if own ~= nil then return own end
    end
    return M.SeatDoor(record, seat).side < 0 and anim.mirrorClip or anim.clip
end

-- ── the boarding, animated (1.7.0) ───────────────────────────────────────────
-- Myers stepping up into her AV (q305), the clip `enter` of the same package:
-- it STARTS where the player entity stands and ends in the door (`WALK_CLIPS`,
-- `first`). The key opens the door and the server asks the client for the step
-- (server/enter.lua, client/enter.lua); every failure is the plain boarding.

--- The animated boarding's settings, each one inside a band; `ENTER_ANIM =
--- false` (or no block) is the plain boarding. The clip plays on the exit's
--- style (`EXIT_ANIM.STYLE`): no exit animation, no animated boarding either.
-- @return table
local function buildEnterSettings()
    local declared = nil
    if type(M.Settings) == 'table' then declared = M.Settings.ENTER_ANIM end
    local block = type(declared) == 'table' and declared or {}
    -- The door's clips: they start where the entity stands and end in the
    -- door (a seat clip is `SIT_CLIP`'s, planned on the seat).
    local function enterClip(value)
        return type(value) == 'string' and M.WALK_CLIPS[value] ~= nil and M.WALK_CLIPS[value].first == true
            and M.WALK_CLIPS[value].seat ~= true
    end
    local function clip(name, fallback)
        local value = block[name]
        if enterClip(value) then return value end
        return fallback
    end
    local records = {}
    if type(block.RECORDS) == 'table' then
        for record, value in pairs(block.RECORDS) do
            if type(record) == 'string' and enterClip(value) then records[record:lower()] = value end
        end
    end
    local function ms(value, lo, hi, default) return math.floor(M.Number(value, lo, hi, default)) end
    return {
        off = type(declared) ~= 'table',
        clip = clip('CLIP', 'enter'),
        -- A door on the hull's right has no clip of its own since 1.8.0 (the
        -- package's `enter_m` gave its slot to `couch`): boarded plainly unless
        -- `MIRROR_CLIP` names one.
        mirrorClip = clip('MIRROR_CLIP', nil),
        records = records,
        -- An airframe whose door this resource does not know (`AIRFRAMES` ...
        -- `OUT`) has its door guessed from the hull's box, as for the exit:
        -- `KNOWN_DOORS_ONLY = true` boards those plainly.
        knownDoorsOnly = block.KNOWN_DOORS_ONLY == true,
        -- The client's whole preparation, from the ask to the step asked for
        -- (1.7.5: 15 s, the stand-in's wait in it).
        ask = ms(block.ASK_MS, 1000, 30000, 15000),
        -- How long the client waits for the server's word on its step.
        answer = ms(block.ANSWER_MS, 200, 10000, 1500),
        -- The clip starts no sooner than this after the key (the door swings).
        doorOpen = ms(block.DOOR_OPEN_MS, 0, 5000, 700),
        -- A body farther than this from the clip's first spot is seated plainly.
        moveMax = M.Number(block.MOVE_MAX_METRES, 0.5, 50.0, 12.0),
        arrive = M.Number(block.ARRIVE_METRES, 0.05, 2.0, 0.35),
        placeWait = ms(block.PLACE_WAIT_MS, 200, 5000, 1500),
        placeTries = ms(block.PLACE_TRIES, 1, 5, 2),
        facing = M.Number(block.FACING_DEGREES, 0.5, 45.0, 6.0),
        facingTries = ms(block.FACING_TRIES, 0, 10, 2),
        standLooks = ms(block.STAND_LOOKS, 1, 20, 2),
        standWait = ms(block.STAND_WAIT_MS, 200, 10000, 2000),
        holdLooks = ms(block.HOLD_LOOKS, 0, 20, 2),
        hold = block.HOLD ~= false,
        -- THE STAND-IN FIRST (1.7.3): third person asked at the key, the step
        -- asked once this screen draws the stand-in, drawn `viewSettle` (or
        -- settled); `viewWait` counts from the key; none by then: plain.
        viewEarly = block.VIEW_EARLY ~= false,
        viewWait = ms(block.VIEW_WAIT_MS, 0, 25000, 12000),
        viewSettle = ms(block.VIEW_SETTLE_MS, 0, 3000, 250),
        viewRequired = block.VIEW_REQUIRED ~= false,
        -- No black over the boarding unless asked (1.7.1): the change of view
        -- and the seat are cuts.
        curtain = block.CURTAIN == true,
        seatEarly = ms(block.SEAT_EARLY_MS, 0, 2000, 200),
        seatLead = ms(block.SEAT_LEAD_MS, 0, 2000, 350),
        -- THE VIEW BEFORE THE SEAT (1.7.8): the seat taken while this screen
        -- still drew the stand-in left the stand-in standing back on the
        -- clip's first spot, beside the AV, until the pilot flew off (Staging,
        -- 2026-10-29: "after the body sits down it gets moved back out until
        -- you take over the av"). So `VIEW_LEAD_MS` before the clip's end the
        -- client lets go of the hold and of third person (first person
        -- forced, so a player who walks in third person puts the stand-in
        -- away too), waits `PARK_WAIT_MS` at most for the stand-in to be put
        -- away, and asks for the seat (`ENTER_SEAT`); the server seats on its
        -- own `SEAT_WAIT_MS` after the clip's end when no word came.
        -- `SEAT_AFTER_VIEW = false`: the seat `SEAT_EARLY_MS` before the clip's
        -- end, the view let go once seated (1.7.0 to 1.7.7).
        seatAfterView = block.SEAT_AFTER_VIEW ~= false,
        viewLead = ms(block.VIEW_LEAD_MS, 0, 3000, 600),
        doorViewLead = ms(block.DOOR_VIEW_LEAD_MS, 0, 3000, 300),
        parkWait = ms(block.PARK_WAIT_MS, 100, 3000, 700),
        seatWait = ms(block.SEAT_WAIT_MS, 200, 10000, 1500),
        -- The door shut before the seat (1.7.10).
        doorCloseSeatClip = ms(block.DOOR_CLOSE_SEAT_CLIP_MS, 0, 30000, 3300),
        doorCloseDoorLead = ms(block.DOOR_CLOSE_DOOR_CLIP_LEAD_MS, 0, 5000, 300),
        -- THE SEAT UNDER A SHORT FADE (1.8.2, on unless `SEAT_CURTAIN = false`):
        -- putting the stand-in away shows first person from where the player
        -- entity stands -- the clip's first spot, outside the door -- for half
        -- a second before the seat ("a teleport outside the AV's door, then the
        -- pilot screen", Staging, 2026-10-30). The screen fades out
        -- (`SEAT_FADE_OUT_MS`) as first person is forced and comes back
        -- (`SEAT_FADE_IN_MS`) `SEAT_SETTLE_MS` after the seat.
        seatCurtain = block.SEAT_CURTAIN ~= false,
        seatCurtainMax = ms(block.SEAT_CURTAIN_MS, 100, 5000, 1500),
        seatSettle = ms(block.SEAT_SETTLE_MS, 0, 3000, 200),
        seatFadeOut = ms(block.SEAT_FADE_OUT_MS, 0, 2000, 150),
        seatFadeIn = ms(block.SEAT_FADE_IN_MS, 0, 3000, 350),
        -- A hull hanging over its gear is set down before the step (1.7.1).
        setDown = block.SET_DOWN ~= false,
        setDownWait = ms(block.SET_DOWN_WAIT_MS, 0, 5000, 1000),
        setDownLook = ms(block.SET_DOWN_LOOK_MS, 0, 10000, 2000),
        -- A weapon drawn at the key is holstered before the step (1.7.2).
        holster = block.HOLSTER ~= false,
        holsterWait = ms(block.HOLSTER_WAIT_MS, 0, 5000, 1500),
        blendIn = ms(block.BLEND_IN_MS, 0, 2000, 0),
        blendOut = ms(block.BLEND_OUT_MS, 0, 2000, 450),
        planTolerance = M.Number(block.PLAN_METRES, 0.2, 5.0, 0.75),
        bodyTolerance = M.Number(block.BODY_METRES, 0.3, 10.0, 1.5),
        bodyWait = ms(block.BODY_WAIT_MS, 0, 5000, 700),
        orbit = block.ORBIT_DEGREES == false and 0 or M.Number(block.ORBIT_DEGREES, -180.0, 180.0, 0.0),
        -- INTO THE SEAT (1.7.7): a seat whose slot is known (`AIRFRAMES` ...
        -- `SIT`) is boarded with `SIT_CLIP`, which ends sitting in it; the
        -- door's clip when its first spot has not the seat's height over its
        -- ground. The camera swings `SIT_ORBIT_DEGREES` round the body (toward
        -- its left: the door), so the clip is seen through the door.
        sit = block.SIT ~= false,
        sitClip = M.SeatClip(block.SIT_CLIP) and block.SIT_CLIP or 'sit',
        sitOrbit = block.SIT_ORBIT_DEGREES == false and 0 or M.Number(block.SIT_ORBIT_DEGREES, -180.0, 180.0, 90.0),
    }
end
function M.EnterSettings() return cached('enter', buildEnterSettings) end

--- THE GAME'S OWN ENTRY (1.7.4): `NATIVE_ENTRY`, read once.
local function buildNativeSettings()
    local block = M.Settings and M.Settings.NATIVE_ENTRY
    if type(block) ~= 'table' then block = {} end
    local metres = M.Number(block.METRES, 2.0, 50.0, 12.0)
    return {
        shut = block.SHUT ~= false,
        metres = metres,
        release = math.max(metres + 1.0, M.Number(block.RELEASE_METRES, 3.0, 80.0, 16.0)),
        checkEvery = math.floor(M.Number(block.CHECK_EVERY, 1, 100, 4)),
    }
end
function M.NativeSettings() return cached('native', buildNativeSettings) end

--- THE STAND-IN, MADE AHEAD (1.7.5): `STAND_IN`, read once.
local function buildStandInSettings()
    local block = M.Settings and M.Settings.STAND_IN
    if type(block) ~= 'table' then block = { WARM = false } end
    local function ms(value, lo, hi, default) return math.floor(M.Number(value, lo, hi, default)) end
    return {
        warm = block.WARM ~= false,
        after = ms(block.AFTER_MS, 0, 600000, 5000),
        nearCard = block.NEAR_CARD ~= false,
        letGoBy = ms(block.LET_GO_BY_MS, 200, 10000, 2500),
        tries = ms(block.TRIES, 1, 10, 2),
        retry = ms(block.RETRY_MS, 1000, 600000, 15000),
        confirm = ms(block.CONFIRM_MS, 200, 10000, 1500),
    }
end
function M.StandInSettings() return cached('standin', buildStandInSettings) end

--- The enter clip for a seat of a hull: a record's own (`ENTER_ANIM.RECORDS`),
--- else `CLIP` for a door on the hull's left, `MIRROR_CLIP` on its right -- none
--- there since 1.8.0 unless it names one (never the left door's: that one turns
--- the wrong way).
-- @param record any
-- @param seat any
-- @param settings table `M.EnterSettings()`
-- @return string|nil
function M.EnterClip(record, seat, settings)
    if type(record) == 'string' then
        local own = settings.records[record:lower()]
        if own ~= nil then return own end
    end
    if M.SeatDoor(record, seat).side < 0 then return settings.mirrorClip end
    return settings.clip
end

-- ── into the seat (1.7.7) ────────────────────────────────────────────────────
-- The door's clip ends in the door, and the seat is a cut ("the character
-- enters and doesn't sit down", the owner, 2026-10-29). A seat whose slot is
-- known is boarded with a clip that ends sitting in it: the Rayfield
-- Excalibur's boarding in the side quest sq012, which the game's scene plays
-- with its origin on the hull's `seat_front_left` slot and an offset that is
-- the inverse of its last root key -- its end IS the seat's slot. The slot is
-- the entity's (`vehicle_slots`: the rig's bone and the slot's own turn, 180
-- deg for the Excalibur's front seats -- they face the tail; a seated pilot's
-- body was read facing 180 on a hull heading 0, Staging 2026-10-27).

--- A seat's slot in the hull's own frame (`AIRFRAMES` ... `SEATS` ... `SIT`):
--- `{ x, y, z, yaw, clip }` (metres; degrees from the hull's heading; `clip`,
--- 1.8.0, the seat clip that ends in this seat, `SIT.CLIP`, when it names one),
--- or nil.
-- @param record any
-- @param seat any
-- @return table|nil
local function buildSeatSit(record, seat)
    local frame = M.Airframe(record)
    local spec = frame ~= nil and type(frame.SEATS) == 'table' and type(seat) == 'string' and frame.SEATS[seat] or nil
    local sit = type(spec) == 'table' and type(spec.SIT) == 'table' and spec.SIT or nil
    if sit == nil then return nil end
    local x, y, z, yaw = M.Number(sit.X, -10.0, 10.0, nil), M.Number(sit.Y, -15.0, 15.0, nil),
        M.Number(sit.Z, -5.0, 5.0, nil), M.Number(sit.YAW, -360.0, 360.0, nil)
    if x == nil or y == nil or z == nil or yaw == nil then return nil end
    return { x = x, y = y, z = z, yaw = yaw % 360.0, clip = M.SeatClip(sit.CLIP) and sit.CLIP or nil }
end
function M.SeatSit(record, seat) return cached('sit|' .. tostring(record) .. '|' .. tostring(seat), buildSeatSit, record, seat) end

--- The seat clip for a seat of a hull, or nil: the seat's slot known and the
--- boarding into it on (`SIT`). The seat's own (`SIT.CLIP`, 1.8.0: the
--- Excalibur's back-left seat is boarded with `couch`), else `SIT_CLIP`.
-- @param record any
-- @param seat any
-- @param settings table `M.EnterSettings()`
-- @return string|nil
function M.SitClip(record, seat, settings)
    if type(settings) ~= 'table' or not settings.sit then return nil end
    local sit = M.SeatSit(record, seat)
    if sit == nil then return nil end
    if sit.clip ~= nil then return sit.clip end
    if not M.SeatClip(settings.sitClip) then return nil end
    return settings.sitClip
end

--- Where the body must stand, and which way it must face, for a seat clip to
--- end sitting in the seat: the clip's end (`right`, `forward`, turned `turn`)
--- on the seat's slot, facing the slot's way.
-- @param frame table `{ x, y, z, fx, fy }` the hull
-- @param sit table `M.SeatSit(record, seat)`
-- @param clip string a seat clip
-- @return table|nil `{ x, y, yaw, seat = { x, y, z }, seatYaw, reach, clip }`
function M.SitPlan(frame, sit, clip)
    local spec = M.WALK_CLIPS[clip]
    if spec == nil or spec.seat ~= true or type(frame) ~= 'table' or type(sit) ~= 'table' then return nil end
    local seat = M.FromHullLocal(frame, { x = sit.x, y = sit.y, z = sit.z })
    local hullYaw = M.YawOfDirection(frame.fx, frame.fy)
    if seat == nil or hullYaw == nil then return nil end
    local seatYaw = (hullYaw + sit.yaw) % 360.0
    -- The clip's root turns `turn` degrees by its end: it starts turned back.
    local yaw = (seatYaw - (spec.turn or 0.0)) % 360.0
    local r = math.rad(yaw)
    local c, s = math.cos(r), math.sin(r)
    return { x = seat.x - (spec.right * c - spec.forward * s), y = seat.y - (spec.right * s + spec.forward * c),
        yaw = yaw, seat = seat, seatYaw = seatYaw, clip = clip,
        reach = math.sqrt(spec.right * spec.right + spec.forward * spec.forward) }
end

-- THE SEAT'S HEIGHT OVER THE FIRST SPOT. A seat clip ends `rise` metres over
-- the ground it starts on; the seat must stand within `SEAT_UNDER` under and
-- `SEAT_OVER` over that (else the body ends sunk in the seat or over it, and
-- the cut to the seat jumps by as much), `SEAT_UNDER_RELAXED` and
-- `SEAT_OVER_RELAXED` taken when nothing else is. Past that the door's clip
-- boards the body (its step turns about the door on a slope).
M.SEAT_UNDER = 0.15
M.SEAT_OVER = 0.15
M.SEAT_UNDER_RELAXED = 0.25
M.SEAT_OVER_RELAXED = 0.25

--- How a seat's height over the first spot's ground fits a seat clip: 'in',
--- 'relaxed', 'high' or 'low' (past the relaxed band), or nil when it cannot be
--- judged.
-- @param clip string
-- @param height number|nil the seat over the first spot's ground (where the body stands)
-- @return string|nil
--- How long before a boarding clip's end the view goes back (1.7.8): a seat
--- clip's `VIEW_LEAD_MS` (its body is seated by then), a door's clip's
--- `DOOR_VIEW_LEAD_MS` (it steps up into the door to its last frames).
-- @param clip string
-- @param settings table `M.EnterSettings()`
-- @return integer ms
function M.ViewLead(clip, settings)
    return M.SeatClip(clip) and settings.viewLead or settings.doorViewLead
end

function M.SeatFit(clip, height)
    local spec = M.WALK_CLIPS[clip]
    height = tonumber(height)
    if spec == nil or spec.seat ~= true or height == nil or height ~= height then return nil end
    if height >= spec.rise - M.SEAT_UNDER and height <= spec.rise + M.SEAT_OVER then return 'in' end
    if height >= spec.rise - M.SEAT_UNDER_RELAXED and height <= spec.rise + M.SEAT_OVER_RELAXED then return 'relaxed' end
    return height > spec.rise and 'high' or 'low'
end

-- ── the hull's mesh box ──────────────────────────────────────────────────────
-- `Open77.world.entityGeometry` answers `bounds` IN THE HULL'S OWN FRAME on the
-- client (client/src/api/ZoneGeometry.cpp: each corner taken relative to the
-- entity and turned by its inverse orientation; measured on Staging
-- 2026-10-27, an Excalibur at z 101 answered a lowest point of -0.7), whatever
-- the card says. Both are read: a box round the world's origin rather than
-- round the hull is the hull's own.

local function boxOf(bounds)
    if type(bounds) ~= 'table' or type(bounds.min) ~= 'table' or type(bounds.max) ~= 'table' then return nil end
    local lo = { x = tonumber(bounds.min.x), y = tonumber(bounds.min.y), z = tonumber(bounds.min.z) or 0.0 }
    local hi = { x = tonumber(bounds.max.x), y = tonumber(bounds.max.y), z = tonumber(bounds.max.z) or 0.0 }
    for _, v in ipairs({ lo.x, lo.y, lo.z, hi.x, hi.y, hi.z }) do
        if v == nil or v ~= v or v == math.huge or v == -math.huge then return nil end
    end
    if hi.x < lo.x or hi.y < lo.y or hi.z < lo.z then return nil end
    return lo, hi
end

--- Whether a mesh box is in the hull's own frame (true), the world's (false),
--- or there is none (nil).
-- @param bounds table|nil `{ min, max }`
-- @param position table `{ x, y, z }` the hull's origin in the world
function M.BoundsLocal(bounds, position)
    local lo, hi = boxOf(bounds)
    if lo == nil or type(position) ~= 'table' then return nil end
    local cx, cy, cz = (lo.x + hi.x) * 0.5, (lo.y + hi.y) * 0.5, (lo.z + hi.z) * 0.5
    local px, py, pz = tonumber(position.x) or 0.0, tonumber(position.y) or 0.0, tonumber(position.z) or 0.0
    local toOrigin = cx * cx + cy * cy + cz * cz
    local toHull = (cx - px) * (cx - px) + (cy - py) * (cy - py) + (cz - pz) * (cz - pz)
    return toOrigin < toHull
end

--- The hull's orientation: the geometry's own quaternion, else its heading
--- alone (REDengine: yaw 0 faces +y, a turn of psi takes +y to (-sin, cos)).
-- @param orientation table|nil `{ x, y, z, w }`
-- @param forward table|nil `{ x, y }`
-- @return table `{ x, y, z, w }`
function M.HullQuaternion(orientation, forward)
    if type(orientation) == 'table' then
        local x, y = tonumber(orientation.x), tonumber(orientation.y)
        local z, w = tonumber(orientation.z), tonumber(orientation.w)
        if x ~= nil and y ~= nil and z ~= nil and w ~= nil then
            local n = math.sqrt(x * x + y * y + z * z + w * w)
            if n > 1e-6 and n == n then return { x = x / n, y = y / n, z = z / n, w = w / n } end
        end
    end
    local fx = type(forward) == 'table' and tonumber(forward.x) or 0.0
    local fy = type(forward) == 'table' and tonumber(forward.y) or 1.0
    if (fx or 0) == 0 and (fy or 0) == 0 then fy = 1.0 end
    local yaw = math.atan(-(fx or 0), fy or 1)
    return { x = 0.0, y = 0.0, z = math.sin(yaw * 0.5), w = math.cos(yaw * 0.5) }
end

--- A vector of the hull's frame turned into the world's: q v q*.
function M.Rotate(q, v)
    local qx, qy, qz, qw = q.x, q.y, q.z, q.w
    local tx = 2.0 * (qy * v.z - qz * v.y)
    local ty = 2.0 * (qz * v.x - qx * v.z)
    local tz = 2.0 * (qx * v.y - qy * v.x)
    return { x = v.x + qw * tx + (qy * tz - qz * ty), y = v.y + qw * ty + (qz * tx - qx * tz),
        z = v.z + qw * tz + (qx * ty - qy * tx) }
end

--- The mesh box in the world: its centre, its lowest point, its corners, and
--- whether it came in the hull's frame.
-- @param bounds table|nil
-- @param position table `{ x, y, z }`
-- @param orientation table|nil
-- @param forward table|nil
-- @return table|nil `{ centre = { x, y, z }, bottom, top, corners, hullFrame, size = { x, y, z } }`
function M.WorldBox(bounds, position, orientation, forward)
    local lo, hi = boxOf(bounds)
    if lo == nil or type(position) ~= 'table' then return nil end
    local size = { x = hi.x - lo.x, y = hi.y - lo.y, z = hi.z - lo.z }
    local corners = {}
    local hullFrame = M.BoundsLocal(bounds, position) == true
    local q = hullFrame and M.HullQuaternion(orientation, forward) or nil
    local px, py, pz = tonumber(position.x) or 0.0, tonumber(position.y) or 0.0, tonumber(position.z) or 0.0
    local bottom, top = math.huge, -math.huge
    for corner = 0, 7 do
        local v = { x = (corner % 2 == 1) and hi.x or lo.x, y = (math.floor(corner / 2) % 2 == 1) and hi.y or lo.y,
            z = (math.floor(corner / 4) % 2 == 1) and hi.z or lo.z }
        if hullFrame then
            local r = M.Rotate(q, v)
            v = { x = px + r.x, y = py + r.y, z = pz + r.z }
        end
        corners[#corners + 1] = v
        bottom, top = math.min(bottom, v.z), math.max(top, v.z)
    end
    local c = { x = (lo.x + hi.x) * 0.5, y = (lo.y + hi.y) * 0.5, z = (lo.z + hi.z) * 0.5 }
    if hullFrame then
        local r = M.Rotate(q, c)
        c = { x = px + r.x, y = py + r.y, z = pz + r.z }
    end
    return { centre = c, bottom = bottom, top = top, corners = corners, hullFrame = hullFrame, size = size }
end

--- The half width of a box in the hull's own frame (its x is the hull's
--- right): the farther of its two sides from the centre line.
function M.LocalHalfWidth(bounds)
    local lo, hi = boxOf(bounds)
    if lo == nil then return nil end
    local width = math.max(hi.x, -lo.x)
    if width ~= width or width <= 0.0 then return nil end
    return width
end

--- The hull's half width, from its world-space mesh box and its heading. A box
--- of half length L and half width W, turned to face `forward`, has the world
--- half extents hx = L|fx| + W|fy| and hy = L|fy| + W|fx|, so W follows --
--- except for a hull standing within 30 degrees of a diagonal of the map, where
--- the two say nearly the same thing and W cannot be told from L: nil then.
-- @param bounds table|nil `{ min = { x, y }, max = { x, y } }`
-- @param forward table `{ x, y }`
-- @return number|nil metres
function M.HullHalfWidth(bounds, forward)
    if type(bounds) ~= 'table' or type(bounds.min) ~= 'table' or type(bounds.max) ~= 'table'
        or type(forward) ~= 'table' then return nil end
    local x0, y0 = tonumber(bounds.min.x), tonumber(bounds.min.y)
    local x1, y1 = tonumber(bounds.max.x), tonumber(bounds.max.y)
    local fx, fy = tonumber(forward.x), tonumber(forward.y)
    if x0 == nil or y0 == nil or x1 == nil or y1 == nil or fx == nil or fy == nil then return nil end
    if x0 ~= x0 or y0 ~= y0 or x1 ~= x1 or y1 ~= y1 or fx ~= fx or fy ~= fy or x1 < x0 or y1 < y0 then
        return nil
    end
    local length = math.sqrt(fx * fx + fy * fy)
    if length < 1e-6 then return nil end
    local ax, ay = math.abs(fx / length), math.abs(fy / length)
    local det = ax * ax - ay * ay
    if math.abs(det) < 0.5 then return nil end
    local hx, hy = (x1 - x0) * 0.5, (y1 - y0) * 0.5
    local width = (ax * hy - ay * hx) / det
    if width ~= width or width <= 0.0 then return nil end
    return width
end

--- How far the hull reaches from its centre line toward one side, from its
--- world-space mesh bounds: the farthest of the box's four corners, measured
--- along the hull's left. An over-estimate for a hull standing at an angle to
--- the map's axes, which puts the door a little further out, never inside.
-- @param bounds table|nil `{ min = { x, y }, max = { x, y } }`
-- @param centre table `{ x, y }`
-- @param left table `{ x, y }` a unit vector
-- @param side integer `1` (left) or `-1` (right)
-- @return number|nil metres
function M.HalfWidth(bounds, centre, left, side)
    if type(bounds) ~= 'table' or type(bounds.min) ~= 'table' or type(bounds.max) ~= 'table' then return nil end
    local x0, y0 = tonumber(bounds.min.x), tonumber(bounds.min.y)
    local x1, y1 = tonumber(bounds.max.x), tonumber(bounds.max.y)
    if x0 == nil or y0 == nil or x1 == nil or y1 == nil then return nil end
    if x0 ~= x0 or y0 ~= y0 or x1 ~= x1 or y1 ~= y1 or x1 < x0 or y1 < y0 then return nil end
    local best = nil
    for _, corner in ipairs({ { x0, y0 }, { x0, y1 }, { x1, y0 }, { x1, y1 } }) do
        local reach = ((corner[1] - centre.x) * left.x + (corner[2] - centre.y) * left.y) * side
        if best == nil or reach > best then best = reach end
    end
    if best == nil or best <= 0 then return nil end
    return best
end

--- Where the body must stand for its exit clip to start on the door, and
--- which way it must face.
--
-- THE CLIP ENDS WHERE THE ENTITY STANDS. Its first frame is `offset` away in
-- the entity's frame, so the entity is put `|offset|` metres out from the door
-- and turned so that the clip's path, start to end, points straight away from
-- the hull: the start then lands on the door. The door is `width` out from the
-- hull's centre line on the seat's side and `settings.forward` toward the nose
-- (the seat's place along the hull, as for the plain exit).
-- REDengine's yaw: 0 faces +y and grows toward -x; a local vector (a, b) --
-- a to the right, b ahead -- is the world vector a*(cos, sin) + b*(-sin, cos).
-- @param centre table `{ x, y }` the hull's centre
-- @param forward table `{ x, y }` the way the hull faces
-- @param seat any
-- @param exit table `M.ExitSettings()`
-- @param clip string a key of `M.WALK_CLIPS`
-- @param width number the door's distance from the centre line
-- @param door table|nil `M.SeatDoor(record, seat)`: a known airframe's door
--   side and place along the hull win over the seat's side and `FORWARD_METRES`
-- @return table|nil `{ x, y, yaw, door = { x, y }, outward = { x, y }, reach, clip }`
function M.WalkOutPlan(centre, forward, seat, exit, clip, width, door, turn)
    local spec = M.WALK_CLIPS[clip]
    if spec == nil or type(centre) ~= 'table' or type(forward) ~= 'table' then return nil end
    local cx, cy = tonumber(centre.x), tonumber(centre.y)
    local fx, fy = tonumber(forward.x), tonumber(forward.y)
    width = tonumber(width)
    if cx == nil or cy == nil or fx == nil or fy == nil or width == nil then return nil end
    if cx ~= cx or cy ~= cy or fx ~= fx or fy ~= fy or width ~= width then return nil end
    local length = math.sqrt(fx * fx + fy * fy)
    if length < 1e-6 then return nil end
    fx, fy = fx / length, fy / length
    local side = type(door) == 'table' and door.side or M.SeatSide(seat)
    local along = type(door) == 'table' and door.forward or exit.forward
    local ux, uy = -fy * side, fx * side          -- away from the hull, on the door's side
    local doorX = cx + ux * width + fx * along
    local doorY = cy + uy * width + fy * along
    local reach = math.sqrt(spec.right * spec.right + spec.forward * spec.forward)
    -- THE STEP TURNED ABOUT THE DOOR (1.6.2, `STEP_TURNS`): the path swung
    -- `turn` degrees round the door point -- the clip still starts on the door.
    turn = M.StepTurn(turn)
    local px, py = ux, uy
    if turn ~= 0.0 then
        local r = math.rad(turn)
        local c, s = math.cos(r), math.sin(r)
        px, py = ux * c - uy * s, ux * s + uy * c
    end
    -- The heading that turns the clip's path (-offset, in the entity frame) onto
    -- the outward direction: world angle = local angle + yaw.
    local yaw = math.deg(math.atan(py, px) - math.atan(-spec.forward, -spec.right)) % 360.0
    return { x = doorX + px * reach, y = doorY + py * reach, yaw = yaw,
        door = { x = doorX, y = doorY }, outward = { x = ux, y = uy }, reach = reach, clip = clip, turn = turn }
end

--- Where a clip's first frame stands the body, for a body at `at` facing `yaw`
--- (the inverse of `M.WalkOutPlan`, for the log and the suite).
-- @return number x
-- @return number y
function M.WalkOutStart(at, yaw, clip)
    local spec = M.WALK_CLIPS[clip]
    local r = math.rad(yaw)
    local c, s = math.cos(r), math.sin(r)
    return at.x + spec.right * c - spec.forward * s, at.y + spec.right * s + spec.forward * c
end

-- THE HULL AN EXIT IS ABOUT. An exit un-masks a hull flown off its pad, and for
-- a fifth of a second the engine drags it back to where the flight began: 37 m
-- on XyberRP (2026-09-30), 7.2 m on Staging (2026-10-28, 00:52), 2.5 m after a
-- hop from the back seat (01:10:52). A seated body is within `CABIN_METRES` of
-- its hull's origin. The engine's frame is the hull only within `AGREE_METRES`
-- and `AGREE_DEGREES` of where the network has it -- the server's own pose
-- (the server refuses a ground measure 1.5 m off it, and a step a metre off
-- the door is a step on nothing): `DRAG_METRES` let the 2.5 m one through.
M.CABIN_METRES = 5.0
M.DRAG_METRES = 3.0
M.AGREE_METRES = 0.5
M.AGREE_DEGREES = 10.0
-- THE BODY GOES WITH THE DRAG (1.6.1). On 2.50.0+op77.156 the exiting body is
-- carried along with the hull the engine drags back (XyberRP Staging,
-- 2026-10-28, 13:20:09 and :43, an Excalibur flown 14.2 m off its spawn pad:
-- the body 13.3 m and 15.5 m from the hull where it stood, beside the dragged
-- one), and the platform's re-mask (`vpark-remask`, 150 ms after the un-mask,
-- client/src/api/VehicleFlight.cpp) brings the hull back but not the body. So
-- a body within `NEAR_METRES` of the hull this game drew at the exit -- or
-- within `PAD_REACH_METRES` of the pad its engine keeps for the hull (where
-- its first flight on this game began), when the drag went by unseen between
-- two frames -- is an exit, not a move made elsewhere.
M.PAD_REACH_METRES = M.CABIN_METRES + 2.0
-- A network frame this close to the exit's dragged frame is that drag, taken
-- by the server for the hull's pose (the exiting game sent it); for
-- `DRAG_HOLD_MS` after the exit the hull is planned where it stood instead.
M.DRAG_MATCH_METRES = 3.0
M.DRAG_HOLD_MS = 4000
-- A frame kept while the body was aboard is the hull for this long after.
M.FLOWN_FRESH_MS = 2000

--- The angle between two headings given as `{ fx, fy }`, in degrees, or nil.
function M.FrameTurn(a, b)
    if a == nil or b == nil or a.fx == nil or a.fy == nil or b.fx == nil or b.fy == nil then return nil end
    local turn = math.deg(math.atan(a.fx * b.fy - a.fy * b.fx, a.fx * b.fx + a.fy * b.fy))
    return math.abs(turn)
end

--- Which frame of a hull an exit is about: the engine's own (fresh, with the
--- mesh box) when it agrees with where the network has the hull, within
--- `AGREE_METRES` and `AGREE_DEGREES`; else the network's own -- the pose the
--- server holds and every other game draws. Without a network position (an
--- older client): the frame kept aboard when the engine's is far from the body
--- and that one is not, else the engine's.
-- @param engine table|nil `{ x, y, fx, fy, ... }` the engine's frame now
-- @param flown table|nil the frame kept while aboard, `at` its time
-- @param net table|nil where the network has the hull
-- @param at table|nil the body
-- @param exit table `M.ExitSettings()`
-- @param now number|nil
-- @return table|nil the frame
-- @return string|nil 'engine' | 'flown' | 'network'
function M.ExitFrame(engine, flown, net, at, exit, now)
    local function apart(a, b)
        local dx, dy = a.x - b.x, a.y - b.y
        return math.sqrt(dx * dx + dy * dy)
    end
    now = now or M.Now()
    if net ~= nil then
        if engine ~= nil and apart(engine, net) <= M.AGREE_METRES
            and (M.FrameTurn(engine, net) or 0) <= M.AGREE_DEGREES then
            return engine, 'engine'
        end
        return net, 'network'
    end
    if at ~= nil and flown ~= nil and apart(at, flown) <= exit.near
        and (engine == nil or apart(at, engine) > exit.near) then
        return flown, 'flown'
    end
    if engine ~= nil then return engine, 'engine' end
    return nil, nil
end

--- The height a stepped-out body is put at, and whether the hull is in the air.
-- @param hullZ number the hull's centre
-- @param ground number|nil the static ground under the exit point
-- @param settings table `M.ExitSettings()`
-- @return number z
-- @return boolean airborne
-- @return number|nil height the hull's centre over that ground, when known
function M.ExitLevel(hullZ, ground, settings)
    hullZ = tonumber(hullZ) or 0.0
    ground = tonumber(ground)
    if ground ~= nil and ground == ground then
        local height = hullZ - ground
        if height > settings.air then return hullZ - 0.8, true, height end
        return ground + settings.lift, false, height
    end
    -- No ground under the point: a hull at rest has its centre a metre or two
    -- over it (the platform's own eject reckons two), so the body goes a little
    -- under the centre and the mover settles it the rest of the way.
    return hullZ - 1.6 + settings.lift, false, nil
end

--- A platform id as the decimal string its typed targets take, or nil. The
--- 64-bit ids the host issues survive a Lua number only up to 2^53, and are
--- spelt as decimal strings for that reason; a whole number is formatted
--- rather than concatenated, which would print a float as `1.0`.
-- @param id any
-- @return string|nil
local decimals = {}
local decimalCount = 0

function M.DecimalId(id)
    local known = decimals[id]
    if known ~= nil then return known or nil end
    local answer = M.DecimalIdOf(id)
    -- Ids are few (hulls, players); a table that grew past this is not.
    if decimalCount < 4096 and id ~= nil and id == id then
        decimals[id] = answer or false
        decimalCount = decimalCount + 1
    end
    return answer
end

--- `M.DecimalId` without its memory.
function M.DecimalIdOf(id)
    if type(id) == 'number' then
        if id ~= id or id < 0 or id ~= math.floor(id) or id >= 2 ^ 63 then return nil end
        return ('%d'):format(id)
    end
    if type(id) ~= 'string' then return nil end
    if id:match('^%d+$') then return id end
    local hex = id:match('^0[xX](%x+)$')
    if hex ~= nil and (#hex < 16 or (#hex == 16 and tonumber(hex:sub(1, 1), 16) < 8)) then
        return ('%d'):format(tonumber(hex, 16))
    end
    return nil
end

--- The text every table is keyed by for a hull: its decimal spelling.
-- @param id any
-- @return string
function M.KeyOf(id)
    return M.DecimalId(id) or tostring(id)
end

--- A hull id as a Lua integer when it is a whole number (a `{ vehicleId }`
--- selector reads one), else the id as it came.
function M.IdNumber(id)
    local decimal = M.DecimalId(id)
    local number = decimal ~= nil and math.tointeger(tonumber(decimal)) or nil
    if number ~= nil then return number end
    return id
end

--- Whether two spellings of a platform id name the same hull. The host's 64-bit
--- ids reach Lua as an integer, a float or a decimal string depending on the
--- road they came by, and `tostring` spells a float `4294967297.0`.
-- @param a any
-- @param b any
-- @return boolean
function M.SameHull(a, b)
    if a == nil or b == nil then return false end
    if a == b then return true end
    local x, y = M.DecimalId(a), M.DecimalId(b)
    if x ~= nil and y ~= nil then return x == y end
    return tostring(a) == tostring(b)
end

-- ── the words ────────────────────────────────────────────────────────────────
--
-- Log lines stay in English. A player reads these, in English or French (the
-- languages of this resource's two suites of players); any other language
-- reads English.

M.Strings = {
    en = {
        ['prompt.pilot'] = 'Fly the aircraft',
        ['prompt.passenger'] = 'Ride along',
        ['prompt.description'] = 'Board the aircraft',
        ['help.why'] = 'Why the aircraft nearest to you does or does not open its door to you',

        ['refused.noPlayer'] = 'You cannot board right now.',
        ['refused.noAircraft'] = 'There is no aircraft here.',
        ['refused.wrecked'] = 'That aircraft is wrecked.',
        ['refused.seated'] = 'You are already in a vehicle.',
        ['refused.down'] = 'You cannot board while down.',
        ['refused.noPosition'] = 'Your position could not be read.',
        ['refused.tooFar'] = 'Walk up to the aircraft\u{2019}s door.',
        ['refused.moving'] = 'The aircraft is still moving.',
        ['refused.locked'] = 'That aircraft is locked.',
        ['refused.notYours'] = 'That aircraft is not yours to fly.',
        ['refused.notCrew'] = 'Only its crew may board that aircraft.',
        ['refused.noSeat'] = 'Every seat is taken.',
        ['refused.seatsBoarding'] = 'Every free seat is being boarded right now. Try again in a moment.',
        ['refused.busy'] = 'One moment.',
        ['refused.failed'] = 'You could not get in: {reason}',

        ['snap.on'] = 'AV pad {pad}: landing you on its centre.',
        ['snap.landed'] = 'Down on AV pad {pad}. The controls are yours.',

        ['files.missing'] = 'This game has no AV animations from this server: close it and start it again through the Open77 launcher.',
    },
    fr = {
        ['prompt.pilot'] = 'Piloter l\u{2019}aéronef',
        ['prompt.passenger'] = 'Monter en passager',
        ['prompt.description'] = 'Monter dans l\u{2019}aéronef',
        ['help.why'] = 'Pourquoi l\u{2019}aéronef le plus proche vous ouvre ou non sa porte',

        ['refused.noPlayer'] = 'Impossible de monter pour le moment.',
        ['refused.noAircraft'] = 'Il n\u{2019}y a pas d\u{2019}aéronef ici.',
        ['refused.wrecked'] = 'Cet aéronef est détruit.',
        ['refused.seated'] = 'Vous êtes déjà dans un véhicule.',
        ['refused.down'] = 'Impossible de monter à terre.',
        ['refused.noPosition'] = 'Votre position est illisible.',
        ['refused.tooFar'] = 'Approchez-vous de la porte de l\u{2019}aéronef.',
        ['refused.moving'] = 'L\u{2019}aéronef est encore en mouvement.',
        ['refused.locked'] = 'Cet aéronef est verrouillé.',
        ['refused.notYours'] = 'Cet aéronef n\u{2019}est pas le vôtre.',
        ['refused.notCrew'] = 'Seul son équipage peut y monter.',
        ['refused.noSeat'] = 'Toutes les places sont prises.',
        ['refused.seatsBoarding'] = 'Chaque place libre est en train d\u{2019}être prise. Réessayez dans un instant.',
        ['refused.busy'] = 'Un instant.',
        ['refused.failed'] = 'Impossible de monter : {reason}',

        ['snap.on'] = 'Plateforme AV {pad} : atterrissage au centre.',
        ['snap.landed'] = 'Posé sur la plateforme AV {pad}. Les commandes sont à vous.',

        ['files.missing'] = 'Ce jeu n\u{2019}a pas les animations AV de ce serveur : fermez-le et relancez-le par le lanceur Open77.',
    },
}

-- The engine's own codes that are not the two-letter ones.
local ENGINE_CODES = { jp = 'ja', kr = 'ko', cz = 'cs', ua = 'uk' }

--- The languages this player's game runs in, best first -- its voice-over, its
--- text, then the BCP-47 tag -- as two-letter codes. Empty on a server, and on
--- a client whose game has not reported its language yet.
-- @param voiceFirst boolean|nil true for a sound (the voice-over leads), false
--   for text (the text language leads)
-- @return string[]
function M.Languages(voiceFirst)
    local session = type(Open77) == 'table' and Open77.session or nil
    if type(session) ~= 'table' or type(session.locale) ~= 'function' then return {} end
    local read, reported = pcall(session.locale)
    if not read or type(reported) ~= 'table' then return {} end
    local order = voiceFirst and { reported.voiceLanguage, reported.gameLanguage, reported.code }
        or { reported.gameLanguage, reported.code, reported.voiceLanguage }
    local out = {}
    for _, code in ipairs(order) do
        if type(code) == 'string' and #code >= 2 then
            local head = code:sub(1, 2):lower()
            out[#out + 1] = ENGINE_CODES[head] or head
        end
    end
    return out
end

--- The variant of something HEARD in this player's language: `variants` keyed
--- by two-letter code, `fallback` (the English one) when the game's voice-over
--- is English, its language has no variant, or it has not reported.
-- @param variants table|nil
-- @param fallback any
-- @return any the variant
-- @return string its language
function M.ForVoice(variants, fallback)
    if type(variants) == 'table' then
        for _, lang in ipairs(M.Languages(true)) do
            if lang == 'en' then break end
            if variants[lang] ~= nil then return variants[lang], lang end
        end
    end
    return fallback, 'en'
end

--- A player-facing text in this game's language, `{name}` filled from `vars`.
-- @param key string
-- @param vars table|nil
-- @return string
function M.Text(key, vars)
    local lang = 'en'
    for _, code in ipairs(M.Languages(false)) do
        if M.Strings[code] ~= nil then lang = code break end
    end
    local text = (M.Strings[lang] or {})[key] or M.Strings.en[key] or key
    if type(vars) == 'table' then
        text = text:gsub('{(%w+)}', function(name)
            local value = vars[name]
            return value ~= nil and tostring(value) or ('{' .. name .. '}')
        end)
    end
    return text
end

-- ── the animation package on this game (1.7.2) ──────────────────────────────
--
-- The server registers open77_avexit's package from its own files; a game
-- registers it only from the archive it STARTED with. A game started with
-- another world's mods plays no clip however the server asks: on Staging
-- (2026-10-29) the launcher had prepared the owner's game for another copy of
-- the server, and every boarding held the body still for three seconds and
-- seated it, every exit stood it still -- with logs that said "nothing wrong".
-- So this game asks open77_avexit (`exports.open77_avexit:Status()`, 1.1.1)
-- whether its clips can play here, and says no steps when they cannot.

local animPackage = nil

--- Whether open77_avexit's clips can play on THIS game:
--- `{ known, ok, reason, style }`. `known = false` when open77_avexit has not
--- started yet or is older than 1.1.1 (the clips are then taken as playable,
--- as before 1.7.2); asked again until it answers, then kept for the session
--- (a game mounts its archives once, at its start).
-- @return table
function M.AnimPackage()
    if animPackage ~= nil then return animPackage end
    local api = type(Open77) == 'table' and Open77.exports or nil
    if type(api) ~= 'table' or type(api.callSync) ~= 'function' then
        return { known = false, why = 'no Open77.exports.callSync on this host' }
    end
    local read, status = pcall(api.callSync, 'open77_avexit', 'Status')
    if not read or type(status) ~= 'table' then
        return { known = false, why = tostring(status):sub(1, 120) }
    end
    animPackage = { known = true, ok = status.ok == true, style = status.style,
        reason = status.ok == true and nil or tostring(status.reason or 'not registered') }
    return animPackage
end

--- Whether this game has said its clips cannot play (a known "no").
-- @return boolean
-- @return string|nil why
function M.AnimMissing()
    local package = M.AnimPackage()
    if package.known and not package.ok then return true, package.reason end
    return false, nil
end

--- What the launcher told this game at its start, short, for the hello and the
--- log: `{ launched, server, endpoint, digest }` (digest: its first 12 hex), or nil.
-- @return table|nil
function M.LauncherContext()
    local session = type(Open77) == 'table' and Open77.session or nil
    if type(session) ~= 'table' or type(session.launcherContext) ~= 'function' then return nil end
    local read, context = pcall(session.launcherContext)
    if not read or type(context) ~= 'table' then return nil end
    local function short(value, n)
        return type(value) == 'string' and value ~= '' and value:sub(1, n) or nil
    end
    return { launched = context.launched == true, server = short(context.serverId, 40),
        endpoint = short(context.connectEndpoint, 64), digest = short(context.modsDigest, 12) }
end

--- For the suite: forget the package's answer.
function M.ResetAnimPackage() animPackage = nil end
