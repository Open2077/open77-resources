-- =============================================================================
-- open77_avdrive -- tests/avdrive_test.lua
-- =============================================================================
-- The REAL server half and the REAL client half of the autopilot, each in its
-- own VM, on the simulated platform of open77_avdoor/tests/world.lua: the key,
-- the waypoint read, every refusal and the words it is read in, who flies the
-- aircraft (1.1.0: from any seat), the arrival (the screens of all aboard
-- faded out; 1.2.0: the aircraft flown to the pin under the black in steps, at
-- the pace the pilot's game keeps, held while that game loads or lags, given
-- up where it has the aircraft when it never follows; the ground measured by
-- the pilot's game, the hover raised over a roof, the freeze off, the screens
-- back and the controls watched -- and every way it ends early), the flight
-- (`TRAVEL = 'fly'`: the
-- freeze, the three legs and their poses, the hover hand-over), and every
-- other way a run ends -- the key again, the seat left, the hull removed, the
-- ceiling, a disconnect, the exports and the resource stopping.
--
-- Runs two ways:
--   * in the C# suite (Open77.Server.Tests.Resources.AvDriveLuaTests), which
--     sets `Open77ResourcesRoot` and runs this file;
--   * standalone, from this resource's folder: `lua tests/avdrive_test.lua`.
-- It publishes `TestResult = { passed, failed, failures }`.
-- =============================================================================

local here = debug.getinfo(1, 'S').source:gsub('^@', '')
local ROOT = Open77ResourcesRoot ~= nil and (Open77ResourcesRoot .. '/system/open77_avdrive')
    or (here:match('^(.*)/tests/[^/]+$') or '.')
local W = dofile(ROOT .. '/../open77_avdoor/tests/world.lua')

local SERVER = { 'shared/config.lua', 'shared/core.lua', 'server/main.lua' }
local CLIENT = { 'shared/config.lua', 'shared/core.lua', 'client/main.lua' }

local passed, failures = 0, {}
local current = '?'
local function check(cond, msg)
    if cond then passed = passed + 1 else failures[#failures + 1] = current .. ': ' .. (msg or 'assertion failed') end
end
-- `AVDRIVE_ONLY` (a piece of a case's name) runs that case alone; `AVDRIVE_DUMP`
-- prints its log lines -- standalone only, where `os.getenv` exists.
local function env(name)
    local read, value = pcall(function() return os.getenv(name) end)
    return read and value or nil
end
local ONLY, DUMP = env('AVDRIVE_ONLY'), env('AVDRIVE_DUMP')
local function run(name, fn)
    if ONLY ~= nil and name:find(ONLY, 1, true) == nil then return end
    current = name
    local ok, err = pcall(fn)
    if DUMP ~= nil then
        for _, entry in ipairs(W.logs) do print(('%9.1f %-28s %-5s %s'):format(entry.at / 1000.0, entry.vm, entry.level, entry.text)) end
    end
    if not ok then failures[#failures + 1] = name .. ': runtime error: ' .. tostring(err) end
    if #W.threadErrors > 0 then
        failures[#failures + 1] = name .. ': thread error: ' .. table.concat(W.threadErrors, ' | ')
        W.threadErrors = {}
    end
    if #W.violations > 0 then
        failures[#failures + 1] = name .. ': a host read a real server throws on: ' .. table.concat(W.violations, ', ')
        W.violations = {}
    end
    local problems = W.problems()
    if #problems > 0 then failures[#failures + 1] = name .. ': error lines: ' .. table.concat(problems, ' | ') end
end

local AV = 'Vehicle.av_rayfield_excalibur'
local TRAUMA = 'Vehicle.q001_trauma_av'
local CAR = 'Vehicle.v_standard2_archer_hella_player'
local HULL = 4294967297
local KEY = 'open77_avdrive_toggle'

local server = nil

local function world(setup, clients)
    W.reset()
    if setup ~= nil then setup() end
    server = W.server('open77_avdrive', ROOT, SERVER)
    for _, id in ipairs(clients or {}) do W.client(id, 'open77_avdrive', ROOT, CLIENT) end
    W.advance(100)
end

--- The flight of 1.0.0 (`TRAVEL = 'fly'`), for the cases about it.
local function flying()
    server.env.AvDrive.Settings.TRAVEL = 'fly'
end

local function lastNotice(playerId)
    local list = W.players[playerId].notices
    return list[#list] and list[#list].text or nil
end

--- The pilot presses the key, and the cooldown is waited out.
local function press(playerId)
    W.pressMapped(playerId, KEY)
    W.advance(450)
end

run('the key is bound, named in the player\'s language, and reads the map waypoint', function()
    world(function()
        W.player(1, 0, 0, 0)
        W.player(2, 0, 0, 0, { locale = { code = 'fr-FR', gameLanguage = 'fr-fr', voiceLanguage = 'en-us' } })
    end, { 1, 2 })
    local spec = W.players[1].keys[KEY]
    check(spec ~= nil and spec.key == 'F10' and spec.name == 'Toggle the AV autopilot', 'F10, named')
    local french = W.players[2].keys[KEY]
    check(french ~= nil and french.name == 'Activer ou couper le pilote automatique de l\u{2019}AV', 'in French')
    W.players[1].waypoint = { x = 100, y = 200, z = 5 }
    W.pressMapped(1, KEY)
    local asked = W.sent('open77_avdrive:toggle')
    check(#asked == 1 and asked[1].from == 1 and asked[1].payload.position.x == 100
        and asked[1].payload.unreadable == false, 'the pin goes to the server')
    W.advance(500)
    W.players[1].waypoint = nil
    W.pressMapped(1, KEY)
    asked = W.sent('open77_avdrive:toggle')
    check(asked[2] ~= nil and asked[2].payload.position == nil and asked[2].payload.unreadable == false,
        'no pin is no pin')
    W.advance(500)
    W.players[1].waypointBroken = true
    W.pressMapped(1, KEY)
    asked = W.sent('open77_avdrive:toggle')
    check(asked[3] ~= nil and asked[3].payload.unreadable == true, 'a map that would not answer says so')
end)

run('every refusal is named, in the pilot\'s own words', function()
    world(function()
        W.vehicle(HULL, AV, 0, 0, 1.5)
        W.vehicle(HULL + 1, CAR, 50, 0, 0.5)
        W.vehicle(HULL + 2, TRAUMA, 100, 0, 1.5)
        W.vehicle(HULL + 3, AV, -100, 0, 1.5)
        W.player(1, 10, 0, 0)
        W.player(2, 0, 0, 0, { locale = { code = 'fr-FR', gameLanguage = 'fr-fr', voiceLanguage = 'fr-fr' } })
        W.player(3, 50, 0, 0)
        W.player(4, 100, 0, 0)
        W.player(5, -100, 0, 0)
    end, { 1, 2, 3, 4, 5 })
    press(1)
    check(lastNotice(1) == 'You are not sitting in anything to fly.', 'not seated: ' .. tostring(lastNotice(1)))
    -- A passenger behind somebody who flies the aircraft.
    W.seat(5, HULL + 3, 'seat_front_left')
    W.seat(2, HULL + 3, 'seat_back_left')
    press(2)
    check(lastNotice(2) == 'Seul celui qui pilote cet aéronef peut utiliser son pilote automatique.',
        'a passenger, in French: ' .. tostring(lastNotice(2)))
    check(W.logged('autopilot refused (notPilot): player 5 flies it (in the pilot seat); this player sits in '
        .. 'seat_back_left', 'server:open77_avdrive') ~= nil, 'the log names who flies it')
    W.seat(3, HULL + 1, 'seat_front_left')
    press(3)
    check(lastNotice(3) == 'The autopilot flies aircraft. That is not one.', 'a car')
    W.seat(4, HULL + 2, 'seat_front_left')
    press(4)
    check(lastNotice(4) == 'The autopilot flies aircraft. That is not one.',
        'a record the client does not fly as an AV')
    W.seat(1, HULL, 'seat_front_left')
    press(1)
    check(lastNotice(1) == 'Drop a waypoint on the map first.', 'no pin')
    W.players[1].waypointBroken = true
    press(1)
    check(lastNotice(1) == 'The map could not be read, so there is nowhere to fly.', 'a broken map')
    W.players[1].waypointBroken = false
    W.players[1].waypoint = { x = 5000, y = 0, z = 0 }
    press(1)
    check(lastNotice(1) == 'That waypoint is too far. Fly closer and try again.', 'beyond 4 km')
    W.players[1].waypoint = { x = 0 / 0, y = 0, z = 0 }
    press(1)
    check(lastNotice(1) == 'Drop a waypoint on the map first.', 'a NaN is no pin')
    W.players[1].waypoint = { x = 100, y = 0, z = 0 }
    W.pressMapped(1, KEY)
    W.advance(10)
    W.pressMapped(1, KEY)
    W.advance(10)
    check(lastNotice(1) == 'Slow down and try again in a moment.', 'a key mashed is told to slow down')
    check(#server.env.AvDrive.Status() == 1, 'the first press engaged')
    check(W.logged('autopilot refused (notSeated)', 'server:open77_avdrive') ~= nil, 'refusals are in the log')
end)

run('1.1.0: whoever flies the aircraft has the autopilot, from any seat (F10 from the back seat)', function()
    world(function()
        W.vehicle(HULL, AV, 0, 0, 2.0)
        W.vehicle(HULL + 1, AV, 100, 0, 2.0)
        W.vehicle(HULL + 2, AV, 200, 0, 2.0)
        W.vehicle(HULL + 3, AV, 300, 0, 2.0)
        for id = 1, 7 do W.player(id, 0, 0, 0) end
    end, { 1, 2, 3, 4, 5, 6, 7 })
    for id = 1, 7 do W.players[id].waypoint = { x = 50, y = 50, z = 10 } end
    -- Alone in a back seat (Staging, 2026-10-30: "only pilot can use autopilot").
    W.seat(1, HULL, 'seat_back_left')
    press(1)
    check(lastNotice(1) == 'Autopilot on: taking you to your waypoint. Press again to take the controls.',
        'alone in the back: engaged -- ' .. tostring(lastNotice(1)))
    check(W.logged('the pilot the only one aboard, in seat_back_left', 'server:open77_avdrive') ~= nil,
        'the log says why it is theirs')
    server.env.AvDrive.Cancel(1, 'the next case')
    -- Flying it from the back, somebody beside the pilot seat: the game that
    -- simulates it (the hull's lease) names the pilot.
    W.seat(2, HULL + 1, 'seat_front_right')
    W.seat(3, HULL + 1, 'seat_back_left')
    W.vehicles[HULL + 1].physicsOwner = 3
    press(2)
    check(lastNotice(2) == 'Only whoever flies this aircraft can use its autopilot.', 'beside it: refused -- '
        .. tostring(lastNotice(2)))
    check(W.logged('player 3 flies it (flying it from seat_back_left); this player sits in seat_front_right',
        'server:open77_avdrive') ~= nil, 'the refusal names who flies it')
    press(3)
    check(lastNotice(3) == 'Autopilot on: taking you to your waypoint. Press again to take the controls.',
        'the one flying it from the back: engaged')
    server.env.AvDrive.Cancel(3, 'the next case')
    -- Nobody leased, two in the back: the platform's controller of it.
    W.seat(4, HULL + 2, 'seat_back_left')
    W.seat(5, HULL + 2, 'seat_back_right')
    W.vehicles[HULL + 2].physicsOwner = 0
    W.vehicles[HULL + 2].ownerDriver = 5
    press(4)
    check(lastNotice(4) == 'Only whoever flies this aircraft can use its autopilot.', 'not its controller: refused')
    press(5)
    check(#server.env.AvDrive.Status() == 1 and server.env.AvDrive.Status()[1].playerId == 5,
        'its controller: engaged')
    check(W.logged('its controller from seat_back_right (the platform\'s word)', 'server:open77_avdrive') ~= nil,
        'and the log says how')
    server.env.AvDrive.Cancel(5, 'the next case')
    -- Two aboard, nobody leased, no controller named: nobody is the pilot.
    W.vehicles[HULL + 2].ownerDriver = nil
    press(4)
    check(lastNotice(4) == 'Only whoever flies this aircraft can use its autopilot.', 'nobody named: refused')
    check(W.logged('nobody aboard can be named its pilot; this player sits in seat_back_left', 'server:open77_avdrive')
        ~= nil, 'and said so')
    -- The pilot seat wins over a lease held from the back.
    W.seat(6, HULL + 3, 'seat_front_left')
    W.seat(7, HULL + 3, 'seat_back_right')
    W.vehicles[HULL + 3].physicsOwner = 7
    press(7)
    check(lastNotice(7) == 'Only whoever flies this aircraft can use its autopilot.', 'the pilot seat wins')
    W.advance(6000)
end)

--- Whether a player's screen was covered by an arrival's fade at a moment:
--- after its fade-out had run and before its fade-in.
local function coveredAt(player, at)
    local out, back = nil, nil
    for _, fade in ipairs(W.players[player].fades) do
        if fade.out and fade.at <= at then out, back = fade, nil end
        if not fade.out and out ~= nil and fade.at >= out.at and back == nil then back = fade end
    end
    if out == nil then return false end
    local black = out.at + (tonumber(out.options and out.options.durationMs) or 500)
    return at >= black and (back == nil or at < back.at)
end

local function distance(a, b)
    return math.sqrt((a.x - b.x) ^ 2 + (a.y - b.y) ^ 2 + (a.z - b.z) ^ 2)
end

--- The longest step between two poses of a hull, from where it stood.
local function longestStep(vehicle, from)
    local longest, last = 0.0, from
    for _, pose in ipairs(vehicle.transforms) do
        longest = math.max(longest, distance(last, pose))
        last = pose
    end
    return longest
end

--- The words a game sent the server on the arrival, of one state.
local function words(state, from)
    return W.sent('open77_avdrive:arriveReady', function(e)
        return e.payload.state == state and (from == nil or e.from == from)
    end)
end

local ARRIVED = 'Autopilot: holding at the waypoint. The controls are yours.'
local STALLED = 'Autopilot off: the aircraft could not be flown there. The controls are yours.'

run('1.2.0: the arrival -- the screens of all aboard fade out, the aircraft is FLOWN to the pin under the black in '
    .. 'steps of a few metres at the pace the pilot\'s game keeps, raised over the roof that game measured, the '
    .. 'controls and the screens back, and the controls watched', function()
    world(function()
        W.vehicle(HULL, AV, 0, 0, 2.0, { heading = 30 })
        W.player(1, 0, 0, 0)
        W.player(2, 0, 0, 0)
        W.seat(1, HULL, 'seat_front_left')
        W.seat(2, HULL, 'seat_back_left')
        -- Every server pose revokes the lease, as the platform does; the pilot's
        -- game claims it back once the freeze is off.
        W.vehicles[HULL].revokeOnTransform = true
        -- A 40 m roof under the pin; the street everywhere else.
        W.groundAt = function(x, y)
            if math.abs(x - 1500) < 20 and math.abs(y - 300) < 20 then return 40.0 end
            return 0.0
        end
    end, { 1, 2 })
    local vehicle = W.vehicles[HULL]
    W.players[1].waypoint = { x = 1500, y = 300, z = 10 }
    local t0 = W.now
    W.pressMapped(1, KEY)
    W.advance(50)
    check(lastNotice(1) == 'Autopilot on: taking you to your waypoint. Press again to take the controls.', 'arriving')
    local f1, f2 = W.players[1].fades[1], W.players[2].fades[1]
    check(f1 ~= nil and f1.out and f1.options.durationMs == 600 and f1.options.timeoutMs == 60000,
        'the pilot\'s screen fades out: 600 ms, its own safety deadline 60 s')
    check(f2 ~= nil and f2.out and f2.options.durationMs == 600, 'and the passenger\'s')
    check(vehicle.x == 0 and #vehicle.transforms == 0 and not vehicle.frozen, 'nothing moved while the screens fade')
    local outs = W.sent('open77_avdrive:arrive', function(e) return e.payload.state == 'out' end)
    check(#outs == 2 and ((outs[1].target == 1) == (outs[1].payload.pilot == true))
        and ((outs[2].target == 1) == (outs[2].payload.pilot == true)) and outs[1].payload.paceMs == 250,
        'each game told whether it answers, and how often the pilot\'s game says where it has the aircraft')
    W.advance(600)
    check(#words('black', 1) == 1, 'the pilot\'s game: black')
    check(#words('pace', 1) >= 2, 'and it says where it has the aircraft from the first moment')
    check(vehicle.frozen == true and vehicle.frozenLog[1].frozen == true, 'frozen at the black')
    W.advance(15600)
    -- THE FLIGHT UNDER THE BLACK: up, across, down; never a step longer than a
    -- tick of the flight at 150 m/s; every pose under both screens' black.
    local poses = #vehicle.transforms
    check(poses >= 100, ('flown in %d poses'):format(poses))
    local step = longestStep(vehicle, { x = 0, y = 0, z = 2 })
    check(step <= 15.5, ('the longest step %.1f m'):format(step))
    check(vehicle.frozenLog[1].at <= vehicle.transforms[1].at, 'frozen before the first pose')
    local covered = true
    for _, pose in ipairs(vehicle.transforms) do
        if not (coveredAt(1, pose.at) and coveredAt(2, pose.at)) then covered = false end
    end
    check(covered, 'every pose under the black of both screens')
    check(vehicle.transforms[1].x == 0 and vehicle.transforms[1].y == 0 and vehicle.transforms[1].z > 2,
        'it climbs first, straight up')
    local top = 0
    for _, pose in ipairs(vehicle.transforms) do top = math.max(top, pose.z) end
    check(math.abs(top - 70) < 1e-6, ('across 60 m over the higher end: %.1f'):format(top))
    local heading = server.env.AvDrive.HeadingTo({ x = 0, y = 0 }, { x = 1500, y = 300 })
    check(vehicle.transforms[1].hadYaw and math.abs(vehicle.heading - heading) < 1e-6, 'facing the way it goes')
    -- The ground measured at 40, the hover raised to 48, the freeze off, the
    -- screens back, the pilot's game simulating it again.
    check(vehicle.x == 1500 and vehicle.y == 300 and math.abs(vehicle.z - 48) < 1e-9,
        ('over the pin, raised over the roof: %.1f, %.1f, %.1f'):format(vehicle.x, vehicle.y, vehicle.z))
    check(math.abs(W.players[1].x - 1500) < 3 and math.abs(W.players[2].x - 1500) < 3, 'both aboard went with it')
    check(vehicle.frozen == false and #vehicle.frozenLog == 2, 'the freeze off')
    local back1 = W.players[1].fades[2]
    local back2 = W.players[2].fades[2]
    check(back1 ~= nil and not back1.out and back1.options.durationMs == 800, 'the pilot\'s screen back over 800 ms')
    check(back2 ~= nil and not back2.out, 'and the passenger\'s')
    check(back1 ~= nil and back1.at - vehicle.frozenLog[2].at >= 400, 'the screens back 400 ms after the freeze came off')
    local last = vehicle.transforms[#vehicle.transforms]
    check(vehicle.frozenLog[2].at - last.at >= 300, 'the raise reached the game before the freeze off')
    check(vehicle.physicsOwner == 1, 'the pilot\'s game simulates it again')
    check(lastNotice(1) == ARRIVED, 'arrived')
    check(#server.env.AvDrive.Status() == 0, 'no run left')
    check(back1 ~= nil and back1.at - t0 < 17000, ('the whole arrival in %.1fs'):format(((back1 and back1.at or t0) - t0) / 1000.0))
    local paces = #words('pace', 1)
    check(paces >= 40, ('%d word(s) from the pilot\'s game on the flight'):format(paces))
    for _, entry in ipairs(W.sent('open77_avdrive:arriveReady')) do check(entry.from == 1, 'only the pilot\'s game answered') end
    local after = words('after', 1)
    check(#after == 1 and after[1].payload.owned == true, 'the pilot\'s game: it has the controls')
    check(#W.authorityAsks == 0, 'nobody asked the platform for it')
    check(W.logged('the pilot\'s screen is black', 'server:open77_avdrive') ~= nil, 'the log: black')
    check(W.logged('flown under the black from 0, 0, 2: 3 leg(s), 1650 m (up 68 m to 70, across 1530 m, down to 18.0), '
        .. 'about 12.2s', 'server:open77_avdrive') ~= nil, 'the log: the route')
    check(W.logged('the up leg done, 68 of 1650 m flown', 'server:open77_avdrive') ~= nil
        and W.logged('the across leg done, 1598 of 1650 m flown', 'server:open77_avdrive') ~= nil, 'the log: each leg')
    check(W.logged('m flown, ', 'server:open77_avdrive') ~= nil
        and W.logged('the pilot\'s body ', 'server:open77_avdrive') ~= nil, 'the log: the progress, every 2 s')
    check(W.logged('over the pin at 1500, 300, 18.0 after', 'server:open77_avdrive') ~= nil, 'the log: over the pin')
    check(W.logged('the ground measured at 40.0 by the static ray', 'server:open77_avdrive') ~= nil
        and W.logged('raised 30.0 m, from 18.0, to 8 m over it', 'server:open77_avdrive') ~= nil, 'the log: raised')
    check(W.logged('the pilot\'s game draws it 0.0 m from the hover', 'server:open77_avdrive') ~= nil,
        'the log: where the pilot\'s game had it over the pin')
    check(W.logged('its game simulates the aircraft', 'server:open77_avdrive') ~= nil
        and W.logged('its game took it back', 'server:open77_avdrive') ~= nil, 'the log: the controls taken back')
    check(W.logged('(arrived over the waypoint)', 'server:open77_avdrive') ~= nil, 'the log: arrived')
    check(W.logged('arrival 1:1 (the pilot): the screen fades out (600 ms', 'client:open77_avdrive:1') ~= nil
        and W.logged('arrival 1:1 (aboard): the screen fades out', 'client:open77_avdrive:2') ~= nil,
        'each game logs its fade')
    check(W.logged('arrival 1:1: flown under the black, report 1 --', 'client:open77_avdrive:1') ~= nil
        and W.logged('no loading screen', 'client:open77_avdrive:1') ~= nil, 'the pilot\'s game logs the flight')
    check(W.logged('the ground under the pin at 40.0 (the static ray, two reads agree)', 'client:open77_avdrive:1') ~= nil,
        'the pilot\'s game logs its measure')
    check(W.logged('arrival 1:1 over (arrived over the waypoint): the image back over 800 ms', 'client:open77_avdrive:1')
        ~= nil, 'and the image back')
    check(W.logged('this game SIMULATES the aircraft again', 'client:open77_avdrive:1') ~= nil, 'and the controls')
    check(W.logged('in seat_front_left of aircraft 4294967297, drawn at 1500.0, 300.0, 48.0', 'client:open77_avdrive:1')
        ~= nil, 'and where its game draws the aircraft and the body at the end')
    W.advance(4000)
    check(W.logged('arrival 1:1: 3s after the image came back', 'client:open77_avdrive:1') ~= nil,
        'and once more, 3 s on: whether the hover holds')
    -- THE CLIENT NEVER NAMES THE AIRCRAFT: every word a game sent this resource
    -- carries the destination or the arrival's own words, nothing else.
    local allowed = { token = true, state = true, ms = true, z = true, reads = true, by = true, agreed = true,
        reason = true, position = true, unreadable = true, drawn = true, bodyAt = true, body = true, owned = true,
        loading = true, loadingKind = true, undrawn = true, drawnOff = true, unknown = true }
    local named, count = {}, 0
    for _, entry in ipairs(W.netLog) do
        if entry.dir == 'toServer' and tostring(entry.name):find('^open77_avdrive:') ~= nil then
            count = count + 1
            for field in pairs(type(entry.payload) == 'table' and entry.payload or {}) do
                if not allowed[field] then named[#named + 1] = entry.name .. '.' .. tostring(field) end
            end
        end
    end
    check(count >= 40 and #named == 0, ('%d word(s) from the games, none naming a hull: %s'):format(count,
        table.concat(named, ', ')))
end)

run('1.2.0: an arrival over the street is not raised; over open water the hover stays over the pin\'s height', function()
    world(function()
        W.vehicle(HULL, AV, 0, 0, 2.0)
        W.player(1, 0, 0, 0)
        W.seat(1, HULL, 'seat_front_left')
    end, { 1 })
    local vehicle = W.vehicles[HULL]
    W.players[1].waypoint = { x = 800, y = 0, z = 10 }
    press(1)
    W.advance(12000)
    check(vehicle.x == 800 and math.abs(vehicle.z - 18) < 1e-9, ('8 m over the pin: %.1f, %.1f'):format(vehicle.x, vehicle.z))
    check(longestStep(vehicle, { x = 0, y = 0, z = 2 }) <= 15.5, 'in steps')
    check(W.logged('the ground measured at 0.0 by the static ray (2 read(s)', 'server:open77_avdrive') ~= nil
        and W.logged('18.0 m over it', 'server:open77_avdrive') ~= nil, 'the street, measured and not raised')
    check(vehicle.frozen == false and lastNotice(1) == ARRIVED, 'handed back')
    -- Open water: no ray meets anything.
    W.groundAt = function() return nil end
    W.players[1].waypoint = { x = 1600, y = 0, z = 0 }
    local before = #vehicle.transforms
    press(1)
    W.advance(20000)
    check(#vehicle.transforms > before + 50 and math.abs(vehicle.z - 8) < 1e-9 and vehicle.x == 1600,
        ('over the water, 8 m up: %.1f, %.1f'):format(vehicle.x, vehicle.z))
    check(W.logged('the ground under the pin NOT found after', 'client:open77_avdrive:1') ~= nil,
        'the pilot\'s game says it found nothing')
    check(W.logged('no usable ground from the pilot\'s game (nil', 'server:open77_avdrive') ~= nil, 'and the server')
    check(vehicle.frozen == false and lastNotice(1) == ARRIVED, 'handed back over the water')
    check(W.players[1].fades[#W.players[1].fades].out == false, 'the screen back')
end)

run('1.2.0: the open terrain (the Badlands) is ground too, on a client whose rays take collision groups', function()
    world(function()
        W.rays = 'groups'
        W.terrainAt = function() return 55.0 end
        W.vehicle(HULL, AV, 0, 0, 2.0)
        W.player(1, 0, 0, 0)
        W.seat(1, HULL, 'seat_front_left')
    end, { 1 })
    local vehicle = W.vehicles[HULL]
    W.players[1].waypoint = { x = 900, y = 900, z = 0 }
    press(1)
    W.advance(16000)
    check(math.abs(vehicle.z - 63) < 1e-9, ('8 m over the terrain: %.1f'):format(vehicle.z))
    check(W.logged('arrival ground: the static meshes and the terrain', 'client:open77_avdrive:1') ~= nil,
        'the client says which ray')
    check(W.logged('the ground measured at 55.0 by the static and terrain ray', 'server:open77_avdrive') ~= nil,
        'and the server')
end)

run('1.2.0: an arrival ended early -- the key again under the black, the seat left while fading -- never leaves a '
    .. 'screen black or a hull frozen', function()
    world(function()
        W.vehicle(HULL, AV, 0, 0, 2.0)
        W.player(1, 0, 0, 0)
        W.player(2, 0, 0, 0)
        W.seat(1, HULL, 'seat_front_left')
        W.seat(2, HULL, 'seat_back_right')
    end, { 1, 2 })
    local vehicle = W.vehicles[HULL]
    W.players[1].waypoint = { x = 700, y = 0, z = 10 }
    press(1)
    W.advance(400)
    check(vehicle.frozen == true and #vehicle.transforms >= 1 and vehicle.z > 2 and vehicle.x == 0,
        ('flown under the black, still climbing: %.1f, %.1f'):format(vehicle.x, vehicle.z))
    press(1)
    check(vehicle.frozen == false and lastNotice(1) == 'Autopilot off. You have the controls.', 'the key again')
    check(W.players[1].fades[2] ~= nil and not W.players[1].fades[2].out
        and W.players[2].fades[2] ~= nil and not W.players[2].fades[2].out, 'both screens back')
    check(W.logged('(the pilot took the controls)', 'server:open77_avdrive') ~= nil, 'and why')
    local moves = #vehicle.transforms
    W.advance(3000)
    check(#vehicle.transforms == moves, 'not one pose more')
    check(W.logged('report(s) on the flight sent', 'client:open77_avdrive:1') ~= nil, 'the pilot\'s game stopped its reports')
    check(#words('ground') == 0 and #words('after') == 0, 'and said nothing more')
    -- The seat left while the screens fade: never frozen, never moved.
    local frozenBefore, movesBefore = #vehicle.frozenLog, #vehicle.transforms
    W.players[1].waypoint = { x = 0, y = 700, z = 10 }
    W.pressMapped(1, KEY)
    W.advance(200)
    vehicle.seats.seat_front_left = nil
    W.players[1].seat = nil
    W.advance(300)
    check(#vehicle.frozenLog == frozenBefore and #vehicle.transforms == movesBefore, 'never frozen, never moved')
    check(lastNotice(1) == 'Autopilot off: you left the controls.', 'pilotLeft')
    check(W.logged('never frozen by this run', 'server:open77_avdrive') ~= nil, 'a freeze it never put on is left alone')
    local last1 = W.players[1].fades[#W.players[1].fades]
    local last2 = W.players[2].fades[#W.players[2].fades]
    check(last1 ~= nil and not last1.out and last2 ~= nil and not last2.out, 'both screens back')
    -- Stale words for an old token move nothing.
    local before = #vehicle.transforms
    server.env.AvDrive.ArriveWord(1, { token = '1:1', state = 'ground', z = 500 })
    server.env.AvDrive.ArriveWord(1, { token = '1:1', state = 'pace', drawn = { x = 9, y = 9, z = 9 } })
    check(#vehicle.transforms == before, 'a stale word is nothing')
end)

run('1.2.0: a game that cannot fade is flown in view; a game that never answers is never flown, and is handed back on '
    .. 'the server\'s own clock', function()
    world(function()
        W.vehicle(HULL, AV, 0, 0, 2.0)
        W.player(1, 0, 0, 0)
        W.player(2, 0, 0, 0)
        W.seat(1, HULL, 'seat_front_left')
        W.players[1].fadeRefused = true
    end, { 1 })
    local vehicle = W.vehicles[HULL]
    W.players[1].waypoint = { x = 600, y = 0, z = 10 }
    press(1)
    check(vehicle.frozen == true and #vehicle.transforms >= 1, 'flown at once')
    check(W.logged('the pilot\'s game could not fade (transition_busy): flown in view', 'server:open77_avdrive') ~= nil,
        'the log says the flight is seen')
    W.advance(10000)
    check(vehicle.x == 600 and vehicle.frozen == false and lastNotice(1) == ARRIVED, 'arrived all the same')
    -- Player 2 has no game running this resource: no word ever comes.
    W.vehicle(HULL + 1, AV, 0, 50, 2.0)
    W.seat(2, HULL + 1, 'seat_front_left')
    local quiet = W.vehicles[HULL + 1]
    local t0 = W.now
    server.env.AvDrive.Toggle(2, { position = { x = 0, y = 900, z = 10 } })
    W.advance(1900)
    check(not quiet.frozen and #quiet.transforms == 0, 'nothing before FADE_WAIT_MS')
    W.advance(300)
    check(quiet.frozen == true and #quiet.transforms == 0, 'frozen after FADE_WAIT_MS, and held: no word, no flight')
    check(W.logged('no word that the pilot\'s screen is black after 2000 ms: flown all the same',
        'server:open77_avdrive') ~= nil and W.logged('no word from the pilot\'s game yet', 'server:open77_avdrive') ~= nil,
        'and says so')
    W.advance(7700)
    check(quiet.frozen == true, 'held for STALL_MS')
    W.advance(300)
    check(quiet.frozen == false and #quiet.transforms == 0, 'given up after STALL_MS, never moved')
    check(W.logged('the flight under the black GIVEN UP after 8.', 'server:open77_avdrive') ~= nil
        and W.logged('the aircraft left where the server has it', 'server:open77_avdrive') ~= nil, 'and says so')
    W.advance(6600)
    check(#server.env.AvDrive.Status() == 0, 'over')
    check(#W.authorityAsks == 1 and W.authorityAsks[1].player == 2, 'the platform asked to hand it to its pilot')
    check(W.logged('no word from the pilot\'s game 6.0s after the screens came back', 'server:open77_avdrive') ~= nil,
        'the controls never confirmed: said')
    local told = W.sent('open77_avdrive:notice', function(e) return e.target == 2 end)
    check(#told >= 2 and told[#told].payload.key == 'stalled', 'the pilot told it could not be flown there')
    check(W.now - t0 < 18000, 'within 18 s')
end)

run('1.2.0: a loading screen in the pilot\'s game holds the flight, and the flight goes on when it is gone', function()
    world(function()
        W.vehicle(HULL, AV, 0, 0, 2.0)
        W.player(1, 0, 0, 0)
        W.seat(1, HULL, 'seat_front_left')
    end, { 1 })
    local vehicle = W.vehicles[HULL]
    W.players[1].waypoint = { x = 1200, y = 0, z = 10 }
    press(1)
    W.advance(1500)
    check(vehicle.frozen == true and #vehicle.transforms > 5, 'flying')
    W.players[1].loading = { active = true, kind = 'fastTravel', elapsedMs = 400 }
    W.advance(600)
    local held = #vehicle.transforms
    W.advance(5000)
    check(#vehicle.transforms == held, ('no pose while it loads (%d then %d)'):format(held, #vehicle.transforms))
    check(W.logged('the flight holds', 'server:open77_avdrive') ~= nil
        and W.logged('a loading screen is up in the pilot\'s game (fastTravel)', 'server:open77_avdrive') ~= nil,
        'the server says why it holds')
    check(W.logged('reports a LOADING SCREEN (fastTravel) in the flying phase', 'server:open77_avdrive', 'warn') ~= nil,
        'and warns')
    check(W.logged('the loading screen CAME UP under the flight', 'client:open77_avdrive:1') ~= nil,
        'the pilot\'s game says it came up')
    check(W.logged('a LOADING SCREEN up (fastTravel', 'client:open77_avdrive:1') ~= nil, 'and logs it in its looks')
    W.players[1].loading = nil
    W.advance(14000)
    check(vehicle.x == 1200 and math.abs(vehicle.z - 18) < 1e-9 and lastNotice(1) == ARRIVED,
        ('arrived once it was done: %.1f, %.1f'):format(vehicle.x, vehicle.z))
    check(W.logged('the flight goes on after', 'server:open77_avdrive') ~= nil, 'the server says it went on')
    check(W.logged('the loading screen went away under the flight', 'client:open77_avdrive:1') ~= nil, 'and the game')
    check(W.logged('GIVEN UP', 'server:open77_avdrive') == nil, 'never given up')
end)

run('1.2.0: a game whose body does not follow is not flown away from: the flight holds, is given up, and the '
    .. 'aircraft is put back where that game has it', function()
    world(function()
        W.vehicle(HULL, AV, 0, 0, 2.0)
        W.player(1, 0, 0, 0)
        W.seat(1, HULL, 'seat_front_left')
    end, { 1 })
    local vehicle = W.vehicles[HULL]
    local body = { x = W.players[1].x, y = W.players[1].y, z = W.players[1].z }
    W.players[1].bodyStuck = true
    W.players[1].waypoint = { x = 2000, y = 0, z = 10 }
    press(1)
    W.advance(6000)
    local far = 0
    for _, pose in ipairs(vehicle.transforms) do far = math.max(far, distance(pose, body)) end
    check(far > 200 and far < 300, ('flown no farther than the leash and a little: %.0f m'):format(far))
    check(W.logged('the pilot\'s body is ', 'server:open77_avdrive') ~= nil
        and W.logged('m behind the flight', 'server:open77_avdrive') ~= nil, 'the server says why it holds')
    W.advance(10000)
    local last = vehicle.transforms[#vehicle.transforms]
    check(distance(last, body) < 1.0, ('put back where the pilot\'s game has it: %.1f m off'):format(distance(last, body)))
    check(W.logged('the flight under the black GIVEN UP after', 'server:open77_avdrive', 'warn') ~= nil
        and W.logged('to where the pilot\'s game has it (its body)', 'server:open77_avdrive') ~= nil, 'and says so')
    check(vehicle.frozen == false and lastNotice(1) == STALLED, 'handed back, and told why')
    check(W.players[1].fades[#W.players[1].fades].out == false, 'the screen back')
    for _, pose in ipairs(vehicle.transforms) do
        if not coveredAt(1, pose.at) then check(false, 'a pose in view') break end
    end
end)

run('1.2.0: a game that goes silent under the flight (what a loading screen looks like from here) is waited for '
    .. 'LOADING_WAIT_MS, then given up; the controls asked of the platform when it never says it has them', function()
    world(function()
        W.vehicle(HULL, AV, 0, 0, 2.0)
        W.player(1, 0, 0, 0)
        W.seat(1, HULL, 'seat_front_left')
    end, { 1 })
    local vehicle = W.vehicles[HULL]
    W.players[1].waypoint = { x = 3000, y = 0, z = 10 }
    press(1)
    W.advance(2500)
    check(#vehicle.transforms > 10, 'flying')
    W.players[1].netReadyAt = W.now + 120000
    W.advance(3000)
    local held = #vehicle.transforms
    check(W.logged('no word from the pilot\'s game for 1.', 'server:open77_avdrive') ~= nil, 'held for the silence')
    W.advance(20000)
    check(#vehicle.transforms == held and vehicle.frozen == true, 'still held, 20 s on')
    W.advance(10000)
    check(vehicle.frozen == false, 'given up after LOADING_WAIT_MS')
    check(W.logged('(held 30.0s)', 'server:open77_avdrive') ~= nil, 'after 30 s of holding')
    W.advance(8000)
    check(#server.env.AvDrive.Status() == 0, 'over')
    check(#W.authorityAsks == 1 and W.authorityAsks[1].player == 1, 'the platform asked to hand it to its pilot')
    check(W.logged('its game has it already (owner 1)', 'server:open77_avdrive') ~= nil, 'and says what it answered')
    check(lastNotice(1) == STALLED, 'the pilot told')
end)

run('1.2.0: a pilot\'s game that does not take the aircraft back once the image is back is handed it by the '
    .. 'platform (Staging, 2026-10-30: "lease of player 0" for good)', function()
    world(function()
        W.vehicle(HULL, AV, 0, 0, 2.0)
        W.player(1, 0, 0, 0)
        W.seat(1, HULL, 'seat_front_left')
        W.vehicles[HULL].revokeOnTransform = true
        W.players[1].neverReclaims = true
    end, { 1 })
    local vehicle = W.vehicles[HULL]
    W.players[1].waypoint = { x = 500, y = 0, z = 10 }
    press(1)
    W.advance(9000)
    check(vehicle.frozen == false and vehicle.physicsOwner == 0, 'over the pin, the freeze off, simulated by nobody')
    W.advance(6000)
    local after = words('after', 1)
    check(#after == 1 and after[1].payload.owned == false and after[1].payload.ms >= 5000,
        'the pilot\'s game: it does not have the controls, after 5 s')
    check(W.logged('this game does NOT simulate the aircraft: the server asks the platform for it',
        'client:open77_avdrive:1', 'warn') ~= nil, 'and says so')
    check(#W.authorityAsks == 1 and W.authorityAsks[1].player == 1 and vehicle.physicsOwner == 1,
        'the platform hands it to the pilot')
    check(W.logged('the platform was asked to hand it over: granted (owner 1); the platform had it simulated by nobody',
        'server:open77_avdrive') ~= nil, 'the server says what it asked and what it found')
    check(lastNotice(1) == ARRIVED, 'arrived')
end)

run('1.2.0: a long way is flown faster, so the black never lasts more than MAX_FLIGHT_MS of flying', function()
    world(function()
        W.vehicle(HULL, AV, 0, 0, 2.0)
        W.player(1, 0, 0, 0)
        W.seat(1, HULL, 'seat_front_left')
    end, { 1 })
    server.env.AvDrive.Settings.ARRIVE.MAX_FLIGHT_MS = 10000
    local vehicle = W.vehicles[HULL]
    W.players[1].waypoint = { x = 3900, y = 0, z = 10 }
    press(1)
    W.advance(10700)
    check(vehicle.x == 3900, ('over the pin within 10 s of flying: %.0f'):format(vehicle.x))
    check(W.logged('x the speed: the black stays under 10s)', 'server:open77_avdrive') ~= nil, 'the boost said')
    W.advance(6000)
    check(lastNotice(1) == ARRIVED, 'arrived')
end)

run('1.2.0: a fade that ends under the flight gives the flight up where the pilot\'s game has the aircraft', function()
    world(function()
        W.vehicle(HULL, AV, 0, 0, 2.0)
        W.player(1, 0, 0, 0)
        W.seat(1, HULL, 'seat_front_left')
    end, { 1 })
    local vehicle = W.vehicles[HULL]
    W.players[1].waypoint = { x = 2000, y = 0, z = 10 }
    press(1)
    W.advance(2000)
    local moves = #vehicle.transforms
    check(moves > 5, 'flying')
    W.clientEvent('open77:screen:cancelled', { id = W.players[1].fades[1].id, reason = 'timeout' })
    W.advance(200)
    check(W.logged('the pilot\'s screen came back during the flight (cancelled: timeout (after the screen was black))',
        'server:open77_avdrive', 'warn') ~= nil, 'the server gives the flight up, and says why')
    check(vehicle.frozen == false and #vehicle.transforms <= moves + 3, 'no flight in view, the freeze off')
    W.advance(8000)
    check(lastNotice(1) == STALLED and #server.env.AvDrive.Status() == 0, 'the pilot told')
end)

run('the flight: frozen, climb, cruise, descent, and the controls handed back in a hover', function()
    world(function()
        W.vehicle(HULL, AV, 0, 0, 2.0, { heading = 0 })
        W.player(1, 0, 0, 0)
        W.seat(1, HULL, 'seat_front_left')
    end, { 1 })
    flying()
    W.players[1].waypoint = { x = 300, y = 0, z = 10 }
    W.pressMapped(1, KEY)
    W.advance(50)
    local vehicle = W.vehicles[HULL]
    check(vehicle.frozen == true and vehicle.frozenLog[1].frozen == true, 'frozen before the first pose')
    check(lastNotice(1) == 'Autopilot on: flying to your waypoint. Press again to take the controls.', 'engaged')
    check(W.logged('-- 300 m, cruise 128 m up, hover 8 m over the pin', 'server:open77_avdrive') ~= nil,
        'the flight plan is in the log')
    -- The climb: 128 m at 5 m/s, straight up, turning toward the pin.
    W.advance(13000)
    check(math.abs(vehicle.x) < 0.01 and vehicle.z > 40 and vehicle.z < 120, 'climbing over the take-off point')
    W.advance(13000)
    check(math.abs(vehicle.z - 130) < 0.5, 'at the cruise altitude, 120 m over the higher end: ' .. vehicle.z)
    check(math.abs(vehicle.heading - 270) < 0.5, 'facing the pin (+X is 270): ' .. vehicle.heading)
    check(W.logged('the climb leg done', 'server:open77_avdrive') ~= nil, 'the climb is in the log')
    -- The cruise: 300 m at 22 m/s.
    W.advance(14500)
    check(math.abs(vehicle.x - 300) < 0.5 and math.abs(vehicle.z - 130) < 0.5, 'over the pin, still level')
    -- The descent: to 8 m over the pin.
    W.advance(36000)
    check(math.abs(vehicle.z - 18) < 0.5, 'hovering 8 m over the pin: ' .. vehicle.z)
    check(vehicle.frozen == false, 'the freeze is off')
    check(lastNotice(1) == 'Autopilot: holding at the waypoint. The controls are yours.', 'arrived')
    local yawless = 0
    for _, pose in ipairs(vehicle.transforms) do if not pose.hadYaw then yawless = yawless + 1 end end
    check(#vehicle.transforms > 500 and yawless == 0, 'every pose carried its heading: ' .. #vehicle.transforms)
    -- No pose jumps more than a tick's worth of the fastest leg.
    local worst = 0
    for i = 2, #vehicle.transforms do
        local a, b = vehicle.transforms[i - 1], vehicle.transforms[i]
        local d = math.sqrt((a.x - b.x) ^ 2 + (a.y - b.y) ^ 2 + (a.z - b.z) ^ 2)
        if d > worst then worst = d end
    end
    check(worst < 22 * 0.2 * 1.6, ('no pose jumps: worst %.2f m'):format(worst))
    local body = W.players[1]
    check(math.abs(body.x - vehicle.x) < 2 and math.abs(body.z - (vehicle.z + 1)) < 0.01, 'the pilot rode along')
    check(W.logged('autopilot for 1 off after', 'server:open77_avdrive') ~= nil
        and W.logged('(the waypoint was reached)', 'server:open77_avdrive') ~= nil, 'the end is in the log')
end)

run('the key again, the seat left, the hull removed: each ends the run and unfreezes the hull', function()
    world(function()
        W.vehicle(HULL, AV, 0, 0, 2.0)
        W.player(1, 0, 0, 0)
        W.seat(1, HULL, 'seat_front_left')
    end, { 1 })
    flying()
    W.players[1].waypoint = { x = 300, y = 0, z = 10 }
    press(1)
    W.advance(3000)
    press(1)
    check(W.vehicles[HULL].frozen == false, 'the key again: unfrozen')
    check(lastNotice(1) == 'Autopilot off. You have the controls.', 'cancelled')
    -- The seat left.
    press(1)
    W.advance(2000)
    W.vehicles[HULL].seats.seat_front_left = nil
    W.players[1].seat = nil
    W.advance(300)
    check(W.vehicles[HULL].frozen == false, 'the seat left: unfrozen')
    check(lastNotice(1) == 'Autopilot off: you left the controls.', 'pilotLeft')
    -- The hull removed.
    W.seat(1, HULL, 'seat_front_left')
    press(1)
    W.advance(1000)
    W.hostEvent('onVehicleRemoved', tostring(HULL), 'despawned')
    W.run()
    check(#server.env.AvDrive.Status() == 0, 'the hull removed: no run')
    check(W.logged('(the airframe was removed)', 'server:open77_avdrive') ~= nil, 'and why')
end)

run('a second controller is refused, the ceiling ends a run, and a disconnect too', function()
    world(function()
        W.vehicle(HULL, AV, 0, 0, 2.0)
        W.player(1, 0, 0, 0)
        W.player(2, 0, 0, 0)
        W.seat(1, HULL, 'seat_front_left')
    end, { 1, 2 })
    flying()
    W.players[1].waypoint = { x = 300, y = 0, z = 10 }
    W.players[2].waypoint = { x = -300, y = 0, z = 10 }
    press(1)
    -- Player 1 is moved to the back and player 2 takes the controls before the
    -- next tick has seen it.
    W.vehicles[HULL].seats.seat_front_left = nil
    W.seat(1, HULL, 'seat_back_left')
    W.seat(2, HULL, 'seat_front_left')
    W.pressMapped(2, KEY)
    W.run()
    check(lastNotice(2) == 'That aircraft is already under autopilot.', 'busy: ' .. tostring(lastNotice(2)))
    W.advance(500)
    check(W.vehicles[HULL].frozen == false, 'the first run ended at its next tick: its pilot left the controls')
    server.env.AvDrive.Settings.MAX_MINUTES = 0.05
    press(2)
    W.advance(4000)
    check(lastNotice(2) == 'Autopilot off: the flight took too long.', 'the ceiling: ' .. tostring(lastNotice(2)))
    server.env.AvDrive.Settings.MAX_MINUTES = 20
    press(2)
    W.advance(1000)
    W.hostEvent('onPlayerDisconnected', '2', 'quit')
    W.run()
    check(W.vehicles[HULL].frozen == false, 'a disconnect unfreezes the hull')
    check(W.logged('(the pilot disconnected)', 'server:open77_avdrive') ~= nil, 'and says so')
end)

run('the exports, the console and the resource stopping', function()
    world(function()
        W.vehicle(HULL, AV, 0, 0, 2.0)
        W.player(1, 0, 0, 0)
        W.seat(1, HULL, 'seat_front_left')
    end, { 1 })
    flying()
    W.players[1].waypoint = { x = 300, y = 0, z = 10 }
    press(1)
    local list = server.exports.status()
    check(#list == 1 and list[1].playerId == 1 and list[1].leg == 'climb', 'status lists the run')
    check(server.exports.cancel(1, 'an admin') == true, 'cancel ends it')
    check(server.exports.cancel(1) == false, 'nothing left to cancel')
    check(server.exports.cancel(0) == false, 'the console is no pilot')
    local command = server.commands['avdrive.status']
    check(command ~= nil and command.restricted == true, 'avdrive.status is restricted')
    press(1)
    command.fn(0, {}, 'avdrive.status')
    check(W.logged('open77_avdrive: 1 flight(s): player 1 flies 4294967297', 'server:open77_avdrive') ~= nil,
        'the console lists it')
    W.stop(server)
    check(W.vehicles[HULL].frozen == false, 'a stopped resource leaves nothing frozen')
    check(lastNotice(1) == 'Autopilot off. You have the controls.', 'and the pilot is told')
end)

run('the geometry: headings and the flight plan', function()
    world(nil, {})
    local M = server.env.AvDrive
    check(math.abs(M.HeadingTo({ x = 0, y = 0 }, { x = 0, y = 10 }) - 0) < 1e-9, '+Y is 0')
    check(math.abs(M.HeadingTo({ x = 0, y = 0 }, { x = 10, y = 0 }) - 270) < 1e-9, '+X is 270')
    check(math.abs(M.HeadingTo({ x = 0, y = 0 }, { x = -10, y = 0 }) - 90) < 1e-9, '-X is 90')
    check(math.abs(M.Turn(350, 10, 0.5) - 0) < 1e-9, 'the short way round')
    check(M.Destination({ x = 1e9, y = 0, z = 0 }) == nil, 'beyond the world')
    check(M.Destination({ x = 0, y = 0, z = 9000 }) == nil, 'above the band')
    local plan = M.Plan()
    check(plan.cruiseSpeed == 22 and plan.climbSpeed == 5 and plan.descendSpeed == 3.5 and plan.hoverHeight == 8,
        'the shipped numbers')
    M.Settings.CRUISE_SPEED = 'fast'
    check(M.Plan().cruiseSpeed == 22, 'a bad number reads as its default')
    M.Settings.CRUISE_SPEED = 22
    -- 1.1.0: the travel and the arrival's numbers.
    check(M.Travel() == 'arrive', 'it arrives by default')
    M.Settings.TRAVEL = 'walk'
    check(M.Travel() == 'arrive', 'an unknown travel arrives')
    M.Settings.TRAVEL = 'fly'
    check(M.Travel() == 'fly', 'fly flies')
    M.Settings.TRAVEL = 'arrive'
    local a = M.ArriveSettings()
    check(a.fadeOut == 600 and a.fadeWait == 2000 and a.settle == 1200 and a.measure == 6000 and a.handBack == 400
        and a.fadeIn == 800, 'the shipped arrival')
    M.Settings.ARRIVE = { FADE_OUT_MS = 'slow', MEASURE_MS = 999999, FADE_WAIT_MS = -5 }
    a = M.ArriveSettings()
    check(a.fadeOut == 600 and a.measure == 20000 and a.fadeWait == 200, 'bad numbers read as defaults, or inside bands')
end)

run('a server that also runs XyberRP\'s opx_infinity is warned: one autopilot per server', function()
    world(function() W.resourceStates.opx_infinity = 'started' end, {})
    check(W.logged('opx_infinity runs on this server too', 'server:open77_avdrive') ~= nil, 'the warning')
end)

TestResult = { passed = passed, failed = #failures, failures = failures }
if Open77ResourcesRoot == nil then
    for _, failure in ipairs(failures) do print('FAIL ' .. failure) end
    print(('%d passed, %d failed'):format(passed, #failures))
    if #failures > 0 then os.exit(1) end
end
