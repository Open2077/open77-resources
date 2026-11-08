-- =============================================================================
-- open77_avdoor -- tests/avdoor_test.lua
-- =============================================================================
-- The REAL server half and the REAL client half, each in its own VM, joined by
-- the simulated platform in tests/world.lua: the door the server opens, the
-- card the client hangs, the key, the boarding through the swinging door, the
-- settle of a new hull, every refusal and the words it is read in, the rules
-- other resources register, the exit (the door for everybody, the fade, the
-- body beside the door, the platform's eject put back), the MaxTac AV's voice
-- and who heard it, the landing call in each player's language, the landing
-- pad, the landing site survey, the watch and its heal, the console, the
-- exports, and a stop that takes everything down.
--
-- Runs two ways:
--   * in the C# suite (Open77.Server.Tests.Resources.AvDoorLuaTests), which
--     sets `Open77ResourcesRoot` and runs this file;
--   * standalone, from this resource's folder: `lua tests/avdoor_test.lua`.
-- It publishes `TestResult = { passed, failed, failures }`.
-- =============================================================================

local here = debug.getinfo(1, 'S').source:gsub('^@', '')
local ROOT = Open77ResourcesRoot ~= nil and (Open77ResourcesRoot .. '/system/open77_avdoor')
    or (here:match('^(.*)/tests/[^/]+$') or '.')
local W = dofile(ROOT .. '/tests/world.lua')
-- `AVDOOR_BUDGET_KILL=0`: the host's budget only measured, never enforced (a profile).
if os.getenv ~= nil and os.getenv('AVDOOR_BUDGET_KILL') == '0' and W.budget ~= nil then W.budget.kill = false end
if os.getenv ~= nil and os.getenv('AVDOOR_BUDGET_HOT') ~= nil then W.budgetHot = {} end

local SERVER = {
    'shared/config.lua', 'shared/core.lua', 'server/main.lua', 'server/native.lua', 'server/watch.lua', 'server/pad.lua',
    'server/landing.lua', 'server/callout.lua', 'server/walkout.lua', 'server/enter.lua', 'server/land.lua',
    'server/sync.lua',
    'server/padlist.lua', 'server/snap.lua', 'server/leave.lua', 'server/boot.lua',
}
local CLIENT = { 'shared/config.lua', 'shared/core.lua', 'client/pad.lua', 'client/callout.lua',
    'client/walkout.lua', 'client/enter.lua', 'client/sync.lua', 'client/shots.lua', 'client/groundtest.lua',
    'client/snap.lua', 'client/standin.lua', 'client/leave.lua',
    'client/main.lua' }

local passed, failures = 0, {}
local current = '?'
local function check(cond, msg)
    if cond then passed = passed + 1 else failures[#failures + 1] = current .. ': ' .. (msg or 'assertion failed') end
end
local function run(name, fn)
    -- `Open77AvdoorOnly`: a harness may run only the cases whose name holds it.
    if type(Open77AvdoorOnly) == 'string' and name:find(Open77AvdoorOnly, 1, true) == nil then return end
    current = name
    W.caseName = name
    local ok, err = pcall(fn)
    if not ok then failures[#failures + 1] = name .. ': runtime error: ' .. tostring(err) end
    -- `AVDOOR_DUMP=1` (with `Open77AvdoorOnly`): every log line of the case, timed.
    if os.getenv('AVDOOR_DUMP') ~= nil then
        for _, entry in ipairs(W.logs) do
            print(('%8d %-26s %-5s %s'):format(entry.at or 0, tostring(entry.vm), tostring(entry.level), entry.text))
        end
    end
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
    -- THE HOST'S BUDGET: no resume of this resource may run 10 000 instructions
    -- (tests/world.lua, `W.budget`) -- a loaded client kills it there.
    if #W.budgetKills > 0 then
        local where = {}
        for i = 1, math.min(#W.budgetKills, 4) do
            local kill = W.budgetKills[i]
            where[#where + 1] = ('%s at %s'):format(kill.vm, kill.where)
        end
        failures[#failures + 1] = ('%s: %d resume(s) ran past the host\'s 10 000-instruction budget: %s'):format(name,
            #W.budgetKills, table.concat(where, ' | '))
        if os.getenv('AVDOOR_BUDGET_TRACE') ~= nil then print(W.budgetKills[1].trace) end
    end
    W.budgetKills = {}
end

local AV = 'Vehicle.av_rayfield_excalibur'
-- An aircraft whose doors this resource does not know (no `AIRFRAMES` entry):
-- each seat leaves on its own side, the door placed from the hull's mesh box.
local GENERIC = 'Vehicle.av_zetatech_atlus'
local MANTICORE = 'Vehicle.av_militech_manticore'
-- The exit key (1.9.0, `LEAVE.ID`): a Manticore's seat steps out through it.
local LEAVE_KEY = 'open77_avdoor_leave'
local MAXTAC = 'Vehicle.max_tac_av'
local TRAUMA = 'Vehicle.q001_trauma_av'
local CAR = 'Vehicle.v_standard2_archer_hella_player'
local HULL = 4294967297      -- past 2^32: the host's ids are 64-bit
local HULL_TEXT = '4294967297'

local server = nil

--- A fresh world: the server, and a client for each listed player.
local function world(setup, clients)
    W.reset()
    W.standInWarm = nil
    W.sitBoarding = nil
    if setup ~= nil then setup() end
    -- THE STAND-IN MADE AHEAD (1.7.5) asks for third person on its own a few
    -- seconds into a session: off in every world but the ones that test it
    -- (`W.standInWarm = true` in the setup), so the others count only the
    -- views their own steps ask for.
    local warm = W.standInWarm == true
    -- INTO THE SEAT (1.7.7): the Excalibur's pilot seat is boarded with the
    -- seat clip by default; the worlds written for the door's clip (1.7.0 to
    -- 1.7.6) keep it (`ENTER_ANIM.SIT = false`) unless they ask for the seat
    -- (`W.sitBoarding = true` in the setup).
    local sit = W.sitBoarding == true
    server = W.server('open77_avdoor', ROOT, SERVER)
    if server ~= nil and server.env.AvDoor ~= nil and type(server.env.AvDoor.Settings) == 'table' then
        server.env.AvDoor.Settings.ENTER_ANIM.SIT = sit
        server.env.AvDoor.SettingsChanged()
    end
    for _, id in ipairs(clients or {}) do
        local vm = W.client(id, 'open77_avdoor', ROOT, CLIENT)
        local env = vm ~= nil and vm.env or nil
        if env == nil then
            for _, each in pairs(W.vms) do
                if each.side == 'client' and each.playerId == id then env = each.env end
            end
        end
        if env ~= nil and env.AvDoor ~= nil and type(env.AvDoor.Settings) == 'table' then
            env.AvDoor.Settings.STAND_IN = env.AvDoor.Settings.STAND_IN or {}
            env.AvDoor.Settings.STAND_IN.WARM = warm
            env.AvDoor.Settings.ENTER_ANIM.SIT = sit
            env.AvDoor.SettingsChanged()
        end
    end
    W.advance(600)
end

local function settings() return server.env.AvDoor.Settings end
--- The settings were changed in place: every VM reads them again (shared/core.lua
--- keeps each reader's table until told).
local function settingsChanged()
    for _, vm in pairs(W.vms) do
        if vm.env.AvDoor ~= nil and type(vm.env.AvDoor.SettingsChanged) == 'function' then vm.env.AvDoor.SettingsChanged() end
    end
end
local function door(playerId) local e = W.lastTo('open77_avdoor:door', playerId) return e and e.payload or nil end
local function lastNotice(playerId)
    local list = W.players[playerId].notices
    return list[#list] and list[#list].text or nil
end
local function distance2(a, b)
    local dx, dy = a.x - b.x, a.y - b.y
    return math.sqrt(dx * dx + dy * dy)
end

-- ── the door and the card ────────────────────────────────────────────────────

run('the server opens the door to a player in reach and the client hangs the card on the hull', function()
    world(function()
        W.vehicle(HULL, AV, 0, 0, 1.5)
        W.player(1, 5, 0, 0)
        W.player(2, 40, 0, 0)
    end, { 1, 2 })
    local told = door(1)
    check(told ~= nil and told.open == true and told.id == HULL_TEXT and told.role == 'pilot',
        'player 1 is told the door is open to them as pilot')
    check(told ~= nil and type(told.at) == 'table' and told.at.x == 0 and told.at.z == 1.5,
        'the door carries the hull\'s canonical position')
    check(door(2) == nil, 'a player who never stood at an aircraft is sent nothing')
    W.advance(200)
    local cards = W.cards(1)
    check(#cards == 1, 'one card for player 1, got ' .. #cards)
    local card = cards[1] or { choices = { {} } }
    check(card.entity == 'veh:' .. HULL_TEXT, 'the card hangs on the hull\'s own projection')
    check(card.requireLookAt == false and card.distance == 10.5, 'in reach is enough: 9 m and the slack')
    check(card.choices[1].key == 'F' and card.choices[1].label == 'Fly the aircraft', 'F, fly the aircraft')
    check(card.choices[1].event == 'open77_avdoor:choice' and card.choices[1].data.id == HULL_TEXT,
        'the key names the hull and nothing else')
    check(#W.cards(2) == 0, 'nothing for player 2')
    check(W.logged('the door of 4294967297 is open to you (pilot): press F', 'client:open77_avdoor:1') ~= nil,
        'the client says the door is open')
    -- Two scans later nothing new is sent: the door is sent when it changes.
    local before = #W.sent('open77_avdoor:door')
    W.advance(1200)
    check(#W.sent('open77_avdoor:door') == before, 'an unchanged door is not sent again')
end)

run('the key boards the pilot through the door the server swings open', function()
    world(function()
        W.vehicle(HULL, GENERIC, 0, 0, 1.5)
        W.player(1, 4, 1, 0)
    end, { 1 })
    W.advance(200)
    check(W.press(1, 'F'), 'the card takes the key')
    check(W.press(1, 'F'), 'a second press reaches the card too')
    W.run()
    local asks = W.sent('open77_avdoor:board')
    check(#asks == 1 and asks[1].payload.id == HULL_TEXT, 'one press is one ask, naming the hull')
    local opened = W.doorLog[1]
    check(opened ~= nil and opened.door == 'frontLeft' and opened.open == true, 'the pilot\'s door swings open first')
    check(#W.warps == 0, 'the body is not seated at once')
    W.advance(500)
    check(#W.warps == 1 and W.warps[1].seat == 'seat_front_left' and W.warps[1].options.moveBucket == false,
        'seated in the pilot\'s seat half a second later, without a bucket move')
    local answer = W.lastTo('open77_avdoor:boarded', 1)
    check(answer ~= nil and answer.payload.ok == true and answer.payload.role == 'pilot', 'the asker is told')
    local notice = W.sent('open77_avdoor:onBoarded')
    check(#notice == 1 and notice[1].payload[1] == 1 and notice[1].payload[2] == HULL_TEXT
        and notice[1].payload[3] == 'seat_front_left' and notice[1].payload[4] == 'pilot',
        'other resources hear of the boarding on the host bus')
    W.advance(300)
    check(#W.cards(1) == 0, 'the card comes down once the body is seated')
    W.advance(1600)
    local closed = W.doorLog[#W.doorLog]
    check(closed ~= nil and closed.open == false and closed.door == 'frontLeft', 'the door closes after the hold')
    check(W.logged('1 boarded 4294967297 as pilot in seat_front_left', 'server:open77_avdoor') ~= nil,
        'the boarding is in the server log')
end)

run('a second player rides along in a passenger seat', function()
    world(function()
        W.vehicle(HULL, GENERIC, 0, 0, 1.5)
        W.player(1, 4, 1, 0)
        W.player(2, -4, 1, 0, { locale = { code = 'fr-FR', gameLanguage = 'fr-fr', voiceLanguage = 'en-us' } })
    end, { 1, 2 })
    W.advance(200)
    W.press(1, 'F')
    W.advance(1000)
    check(W.players[1].seat ~= nil and W.players[1].seat.seat == 'seat_front_left', 'the pilot is in')
    -- The pilot's seat is taken: everyone else is offered the next one.
    W.advance(600)
    local told = door(2)
    check(told ~= nil and told.open == true and told.role == 'pilot', 'player 2 may still fly it: the next seat')
    W.advance(200)
    local card = W.cards(2)[1]
    check(card ~= nil and card.choices[1].label == 'Piloter l\u{2019}aéronef', 'player 2 reads the card in French')
    W.press(2, 'F')
    W.advance(1000)
    check(W.players[2].seat ~= nil and W.players[2].seat.seat == 'seat_front_right', 'player 2 takes the next seat')
    check(W.doorLog[#W.doorLog - 0] ~= nil, 'doors swung')
    local frontRight = false
    for _, entry in ipairs(W.doorLog) do if entry.door == 'frontRight' and entry.open then frontRight = true end end
    check(frontRight, 'the second body steps in through the right door')
end)

-- ── who may fly what ─────────────────────────────────────────────────────────

run('every refusal is named, and the host is never asked about player 0', function()
    world(function()
        W.vehicle(HULL, AV, 0, 0, 1.5)
        W.vehicle(HULL + 1, CAR, 100, 0, 0.5)
        W.vehicle(HULL + 2, AV, 200, 0, 1.5, { bucket = 7 })
        W.vehicle(HULL + 3, AV, 300, 0, 1.5)
        W.player(1, 4, 0, 0)
        W.player(2, 30, 0, 0)
        W.player(3, 104, 0, 0)
        W.player(4, 204, 0, 0)
        W.player(5, 304, 0, 0)
    end, {})
    local verdict = server.exports.verdict
    local _, why = verdict(2, HULL)
    check(why == 'too_far', 'too far: ' .. tostring(why))
    _, why = verdict(3, HULL + 1)
    check(why == 'not_aircraft', 'a car is not an aircraft: ' .. tostring(why))
    _, why = verdict(4, HULL + 2)
    check(why == 'no_aircraft', 'an aircraft in another bucket is no aircraft: ' .. tostring(why))
    _, why = verdict(1, 999)
    check(why == 'no_aircraft', 'an unknown id: ' .. tostring(why))
    _, why = verdict(0, HULL)
    check(why == 'no_player', 'the console is no player: ' .. tostring(why))
    _, why = verdict(-3, HULL)
    check(why == 'no_player', 'a negative id is no player')

    W.vehicles[HULL].speed = 5
    _, why = verdict(1, HULL)
    check(why == 'moving', 'a hull moving at 5 m/s has no door: ' .. tostring(why))
    W.vehicles[HULL].speed = 0

    W.vehicles[HULL].locked = true
    _, why = verdict(1, HULL)
    check(why == 'locked', 'locked: ' .. tostring(why))
    W.vehicles[HULL].lockedFor[1] = false
    local open = verdict(1, HULL)
    check(open ~= nil and open.role == 'pilot', 'a lock exception opens it to that player')
    W.vehicles[HULL].locked, W.vehicles[HULL].lockedFor = false, {}

    W.players[1].dead = true
    _, why = verdict(1, HULL)
    check(why == 'down', 'down: ' .. tostring(why))
    W.players[1].dead = false

    W.vehicles[HULL].destroyed = true
    _, why = verdict(1, HULL)
    check(why == 'wrecked', 'wrecked: ' .. tostring(why))
    W.vehicles[HULL].destroyed = false

    W.seat(5, HULL + 3, 'seat_back_left')
    _, why = verdict(5, HULL + 3)
    check(why == 'seated', 'already seated: ' .. tostring(why))
    for i, seat in ipairs({ 'seat_front_left', 'seat_front_right', 'seat_back_left', 'seat_back_right' }) do
        W.player(10 + i, 0, 30, 0)
        W.seat(10 + i, HULL, seat)
    end
    _, why = verdict(1, HULL)
    check(why == 'no_seat', 'every seat taken: ' .. tostring(why))
    check(#W.violations == 0, 'no host read was made with a bad id')
end)

run('PILOTS = registered: everybody not named rides along, or is refused without passenger seats', function()
    world(function()
        W.vehicle(HULL, AV, 0, 0, 1.5)
        W.player(1, 4, 0, 0)
    end, {})
    settings().PILOTS = 'registered'
    local verdict = server.exports.verdict
    local seat = verdict(1, HULL)
    -- 1.8.0: the Excalibur fills its back seats first (`SEAT_ORDER`).
    check(seat ~= nil and seat.role == 'passenger' and seat.seat == 'seat_back_left',
        'a passenger, never in the pilot\'s seat: ' .. tostring(seat and seat.seat))
    settings().PASSENGERS = false
    local _, why = verdict(1, HULL)
    check(why == 'not_yours', 'no passenger seats: not yours: ' .. tostring(why))
    settings().PILOTS, settings().PASSENGERS = 'anyone', true
end)

run('a rule another resource registers decides who flies, and goes when that resource stops', function()
    world(function()
        W.vehicle(HULL, AV, 0, 0, 1.5)
        W.player(1, 4, 0, 0)
        W.player(3, -4, 0, 0)
    end, { 1 })
    W.invoker = 'rescue_team'
    check(server.exports.allow(HULL, { pilots = { 3 }, reason = 'not_on_shift' }) == true, 'the rule is taken')
    W.invoker = nil
    local verdict = server.exports.verdict
    local crew = verdict(3, HULL)
    check(crew ~= nil and crew.role == 'pilot', 'the named pilot flies')
    local other = verdict(1, HULL)
    check(other ~= nil and other.role == 'passenger', 'everybody else rides along')
    W.invoker = 'rescue_team'
    server.exports.allow(HULL_TEXT, { pilots = { 3 }, passengers = false, reason = 'not_on_shift' })
    W.invoker = nil
    local _, why = verdict(1, HULL)
    check(why == 'not_on_shift', 'the rule\'s own refusal: ' .. tostring(why))
    W.advance(600)
    W.advance(200)
    check(#W.cards(1) == 0, 'no card for a player the rule refuses')
    -- The resource that registered it stops: the rule goes with it.
    server.fire('onResourceStop', 'rescue_team', 'manual')
    W.run()
    local after = verdict(1, HULL)
    check(after ~= nil and after.role == 'pilot', 'the rule is gone with its resource')
    check(W.logged('rescue_team stopped: 1 rule(s)', 'server:open77_avdoor') ~= nil, 'and that is in the log')
    check(server.exports.forget(HULL) == false, 'nothing left to forget')
end)

run('a refusal is a notice in the player\'s own language', function()
    world(function()
        W.vehicle(HULL, AV, 0, 0, 1.5)
        W.player(1, 4, 0, 0)
        W.player(2, -4, 0, 0, { locale = { code = 'fr-FR', gameLanguage = 'fr-fr', voiceLanguage = 'fr-fr' } })
    end, { 1, 2 })
    W.advance(200)
    -- The hull is locked between the card and the press: the server judges the
    -- press again from scratch.
    W.vehicles[HULL].locked = true
    W.press(1, 'F')
    W.press(2, 'F')
    W.advance(100)
    check(lastNotice(1) == 'That aircraft is locked.', 'English: ' .. tostring(lastNotice(1)))
    check(lastNotice(2) == 'Cet aéronef est verrouillé.', 'French: ' .. tostring(lastNotice(2)))
    check(#W.warps == 0, 'nobody was seated')
    check(W.logged('boarding refused: locked', 'client:open77_avdoor:1') ~= nil, 'the refusal is in the client log')
end)

run('a hull that has just appeared is boarded only once it has settled', function()
    world(function()
        W.vehicle(HULL, AV, 0, 0, 1.5)
        W.player(1, 4, 0, 0)
    end, { 1 })
    W.hostEvent('onVehicleCreated', HULL_TEXT, 'garage', AV)
    W.run()
    local left = server.exports.settleLeft(HULL)
    check(left > 2000 and left <= 2500, 'it settles for 2.5 s: ' .. tostring(left))
    W.advance(200)
    W.press(1, 'F')
    W.advance(600)
    check(#W.warps == 0, 'not seated at the usual half second')
    check(W.logged('boards 4294967297 in', 'server:open77_avdoor') ~= nil, 'the wait is in the log')
    W.advance(2200)
    check(#W.warps == 1, 'seated once the hull settled')
    check(server.exports.settleLeft(HULL) == 0, 'nothing left to settle')
    check(server.exports.fresh(HULL) == 2500, 'a resource can mark a hull fresh itself')
end)

-- ── the exit ─────────────────────────────────────────────────────────────────

run('the exit: the door opens for everybody, the body stands beside it, the eject is put back -- in view, no fade (1.6.0)', function()
    world(function()
        W.vehicle(HULL, GENERIC, 0, 0, 1.5)
        W.player(1, 0, 0, 2.5)
        W.player(2, 20, 0, 0)
        W.seat(1, HULL, 'seat_front_left')
    end, { 1, 2 })
    W.advance(1000)
    W.leave(1)
    W.advance(150)
    local player = W.players[1]
    -- NO CUT TO BLACK AT THE EXIT: the native fade would hold the body where it
    -- is put, in the air (Staging, 2026-10-28, 10:32:56); a plain exit has no curtain.
    check(#player.fades == 0, 'the screen is not covered as the seat starts to empty')
    W.advance(110)
    local opened = nil
    for _, entry in ipairs(W.doorLog) do if entry.door == 'frontLeft' and entry.open then opened = entry end end
    check(opened ~= nil, 'the pilot\'s door is opened for everybody')
    check(#player.teleports >= 1, 'the body is put beside the door')
    local target = player.teleports[1] or { x = 0, y = 0, z = 0 }
    local side = distance2(target, { x = 0, y = 0 })
    check(side > 5.5 and side < 6.6, ('beside the door, 6 m from the hull\'s centre: %.2f'):format(side))
    check(target.x < 0, 'on the pilot\'s side (left of a hull facing north is west)')
    check(math.abs(target.z - 0.25) < 0.01, 'on the ground, a quarter metre up: ' .. tostring(target.z))
    -- The platform's own eject, 1.7 s after the drop, puts the body under the hull.
    W.advance(2000)
    check((player.ejected or 0) == 1, 'the platform ejected the body')
    W.advance(200)
    check(#player.teleports >= 2, 'the eject was put back: ' .. #player.teleports .. ' placement(s)')
    check(distance2(player, target) < 1.5, 'the body ends beside the door')
    W.advance(3000)
    check(player.covered == nil and #player.fades == 0, 'never covered')
    check(W.grounded(player), 'the body stands on the ground')
    check((player.screenMoves or 0) == 0, 'never moved under a fade')
    check(W.logged('exit guard over (done)', 'client:open77_avdoor:1') ~= nil, 'the guard says how it went')
    check(W.logged('something moved the body', 'client:open77_avdoor:1') ~= nil, 'the eject is in the log')
    local exited = W.sent('open77_avdoor:onExited')
    check(#exited >= 1 and exited[1].payload[3] == 'seat_front_left', 'other resources hear of the exit')
    W.advance(4000)
    local closed = false
    for _, entry in ipairs(W.doorLog) do if entry.door == 'frontLeft' and entry.open == false then closed = true end end
    check(closed, 'the door closes nine seconds later (the fade and the clip)')
end)

run('the engine shutting the pilot\'s door is answered by opening it again', function()
    world(function()
        W.vehicle(HULL, GENERIC, 0, 0, 1.5)
        W.player(1, 0, 0, 2.5)
        W.seat(1, HULL, 'seat_front_left')
    end, { 1 })
    W.advance(600)
    W.leave(1, { eject = false })
    W.advance(300)
    W.vehicles[HULL].doors.frontLeft = false
    W.advance(500)
    check(W.vehicles[HULL].doors.frontLeft == true, 'opened again')
    check(W.logged('had been shut again', 'server:open77_avdoor') ~= nil, 'the re-open is in the log')
end)

run('a passenger steps out on their own side, in view', function()
    world(function()
        W.vehicle(HULL, GENERIC, 0, 0, 1.5)
        W.player(1, 0, 0, 2.5)
        W.seat(1, HULL, 'seat_back_right')
    end, { 1 })
    W.advance(600)
    W.leave(1)
    W.advance(300)
    local player = W.players[1]
    local target = player.teleports[1] or { x = 0, y = 0 }
    check(target.x > 0, 'the right side for a right seat')
    W.advance(1200)
    check(player.covered == nil and #player.fades == 0, 'no fade for a plain exit')
    check(W.grounded(player), 'the body stands beside the door')
end)

run('a seat lost far from the hull is a move, not an exit', function()
    world(function()
        W.vehicle(HULL, AV, 0, 0, 1.5)
        W.vehicle(HULL + 1, AV, 1000, 0, 1.5)
        W.player(1, 0, 0, 2.5)
        W.player(2, 1000, 0, 2.5)
        W.seat(1, HULL, 'seat_front_left')
        W.seat(2, HULL + 1, 'seat_front_left')
    end, { 1, 2 })
    W.advance(600)
    -- The server takes player 1 out and puts them 300 m away in one move (the
    -- hull still streamed), and player 2 600 m away (the hull no longer drawn).
    for _, case in ipairs({ { 1, HULL, 300 }, { 2, HULL + 1, 1600 } }) do
        local player, vehicle = W.players[case[1]], W.vehicles[case[2]]
        vehicle.seats.seat_front_left = nil
        player.seat = nil
        player.x = case[3]
        W.hostEvent('onVehicleOccupancyChanged', tostring(case[2]), 99)
    end
    W.advance(1500)
    for _, id in ipairs({ 1, 2 }) do
        check(#W.players[id].fades == 0, 'no fade for ' .. id)
        check(#W.players[id].teleports == 0, 'nothing placed for ' .. id)
    end
    check(W.logged('from it: a move made elsewhere, not an exit', 'client:open77_avdoor:1') ~= nil, 'and why')
    check(W.logged('from where it flew: a move made elsewhere', 'client:open77_avdoor:2') ~= nil,
        'measured against the frame it flew at when the hull is not drawn')
end)

run('a server move during the exit guard is left alone', function()
    world(function()
        W.vehicle(HULL, AV, 0, 0, 1.5)
        W.player(1, 0, 0, 2.5)
        W.seat(1, HULL, 'seat_front_left')
    end, { 1 })
    W.advance(600)
    W.leave(1, { eject = false })
    W.advance(600)
    local placed = #W.players[1].teleports
    check(placed >= 1, 'the exit put the body beside the door')
    W.players[1].x = 300
    W.advance(1000)
    check(#W.players[1].teleports == placed and W.players[1].x == 300, 'the move is not undone')
    check(W.logged('exit guard over (moved elsewhere)', 'client:open77_avdoor:1') ~= nil, 'the guard stood down')
end)

-- ── the exit, animated (client/walkout.lua, server/walkout.lua) ──────────────

local function firstVisibility(playerId, visible)
    for _, entry in ipairs(W.visibilityLog) do
        if entry.player == playerId and entry.visible == visible then return entry end
    end
    return nil
end

local function lastFadeIn(player)
    local found = nil
    for _, fade in ipairs(player.fades) do if fade.out == false then found = fade end end
    return found
end

local function views(player, filter)
    local out = {}
    for _, v in ipairs(player.views) do if filter(v) then out[#out + 1] = v end end
    return out
end

run('the exit clip: the style while seated, the body where the clip ends, Myers\' step out for everybody', function()
    world(function()
        W.exitPackage()
        W.vehicle(HULL, GENERIC, 0, 0, 1.5)
        W.player(1, 0, 0, 2.5)
        W.player(2, 20, 0, 0)
    end, { 1, 2 })
    W.seat(1, HULL, 'seat_front_left')
    W.advance(1000)
    local given = W.locomotion.assignments[1]
    check(given ~= nil and given.style == 'avexit' and given.owner == 'open77_avdoor',
        'the exit style is given (1.7.0: as its client says hello, `ASSIGN = \'join\'`)')
    check(given ~= nil and given.options ~= nil and given.options.resetOnDeath == false, 'and kept through a death')
    check(W.logged('exit clips on: this player has the exit style avexit', 'client:open77_avdoor:1') ~= nil,
        'the client is told')
    check(W.logged('player 1 given the exit style avexit (its client said hello', 'server:open77_avdoor') ~= nil,
        'at its client\'s hello -- before any seat: the boarding step plays on it')
    check(W.lastTo('open77_avdoor:style', 2) ~= nil and W.lastTo('open77_avdoor:style', 2).payload.ok == true,
        'every player with the client is given it the same way')
    local leftAt = W.now
    W.leave(1)
    W.advance(250)
    local player = W.players[1]
    -- The body goes where the clip ends: the door 2.8 m out (the hull's 2.5 m
    -- half width and the 0.3 m margin), 1.5 m toward the nose, and the clip's
    -- reach (2.47 m) beyond it, turned so the clip starts on the door.
    local target = player.teleports[1] or { x = 0, y = 0, z = 0 }
    check(math.abs(target.x - (-5.271)) < 0.02 and math.abs(target.y - 1.5) < 0.02,
        ('the body stands where the step clip ends: %.3f, %.3f'):format(target.x, target.y))
    check(math.abs((target.heading or 0) - 74.9) < 0.2, 'facing so the clip starts on the door: ' .. tostring(target.heading))
    local sx, sy = server.env.AvDoor.WalkOutStart(target, target.heading or 0, 'step')
    check(math.abs(sx - (-2.8)) < 0.01 and math.abs(sy - 1.5) < 0.01,
        ('the clip\'s first frame is on the door: %.3f, %.3f'):format(sx, sy))
    local hid = firstVisibility(1, false)
    check(hid ~= nil and hid.at - leftAt <= 50, 'the others stop seeing the body as the seat empties')
    local held = views(player, function(v) return v.tps == true and v.force == true end)
    check(#held == 1 and held[1].at - leftAt <= 150, 'the exit is seen in the platform\'s own third person (with a head)')
    -- The platform's eject comes and is put back; the clip is asked under the fade.
    W.advance(2600)
    local played = W.locomotion.played[1]
    check(played ~= nil and played.clip == 'step' and played.player == 1, 'the server plays the step clip')
    check(played ~= nil and played.options.blendInMs == 0 and played.options.blendOutMs == 450,
        'cut in, blended out')
    check(played ~= nil and played.at - leftAt >= 2000 and played.at - leftAt <= 3000,
        ('after the platform\'s eject: %d ms after the seat was left'):format(played and played.at - leftAt or -1))
    check(played ~= nil and distance2(played, target) < 0.3, 'with the body standing where the clip ends')
    local shown = firstVisibility(1, true)
    check(shown ~= nil and played ~= nil and math.abs(shown.at - played.at) <= 10, 'the others see the body as the clip starts')
    local back = lastFadeIn(player)
    check(back ~= nil and played ~= nil and back.at >= played.at, 'the image comes back on the first step')
    local froze = player.frozenLog[1]
    check(froze ~= nil and froze.position == true and played ~= nil and froze.at - played.at <= 50,
        'the body is held still for the clip')
    check(player.frozenRotation == true, 'its heading too')
    check(W.lastTo('open77_avdoor:walking', 1) ~= nil and W.lastTo('open77_avdoor:walking', 1).payload.ok == true
        and W.lastTo('open77_avdoor:walking', 1).payload.durationMs == 4300, 'the client is told the clip and its length')
    check(froze ~= nil and froze.grounded == true, 'held only once it stood on the ground')
    check(W.clipDrawn(played) == true, 'the clip is drawn: its body on the ground the whole time')
    W.advance(4800)
    check(player.frozenPosition == false and player.frozenRotation == false, 'free once the clip is over')
    -- The clip is over and so is the exit's view: the player's own comes back
    -- before the client turns its exit camera off on the first steps.
    check(#views(player, function(v) return v.clear == true end) == 1, 'the view is the player\'s own as the clip ends')
    check(W.logged('(the clip is over)', 'client:open77_avdoor:1') ~= nil
        and W.logged('exit view: released after', 'client:open77_avdoor:1') ~= nil, 'and says so')
    -- Walking off asks nothing more of the view.
    for _ = 1, 4 do
        player.x = player.x - 0.3
        W.advance(100)
    end
    check(#views(player, function(v) return v.clear == true end) == 1, 'walking off changes nothing more')
    check(W.logged('exit clip step playing', 'server:open77_avdoor') ~= nil, 'the server logs the clip')
    check(W.logged('exit clip step over', 'client:open77_avdoor:1') ~= nil, 'the client logs its end')
    check(W.locomotion.sets == 2 and W.locomotion.assignments[1].revision == given.revision,
        'the style was given once a player: an exit costs only the clip')
end)

run('Staging, 2026-10-27: the seat still reported, the legacy exit camera, a slow stand-in -- the clip waits for the view', function()
    world(function()
        W.exitPackage()
        W.vehicle(HULL, AV, 0, 0, 1.5)
        W.player(1, 0, 0, 2.5, { tpsReadyMs = 2800 })   -- 10-20 frames a second: the stand-in dresses in ~3 s
        W.player(2, 20, 0, 0)
    end, { 1, 2 })
    W.seat(1, HULL, 'seat_back_left')
    W.advance(800)
    local player = W.players[1]
    local leftAt = W.now
    -- The platform calls the seat occupied (leaving) for the 1.5 s its own exit waits.
    W.leave(1, { confirmMs = 1500 })
    local played = nil
    for _ = 1, 90 do
        W.advance(100)
        played = played or W.locomotion.played[1]
    end
    check(W.logged('exit view: released after 0.0s (seated again)', 'client:open77_avdoor:1') == nil
        and W.logged('(seated again)', 'client:open77_avdoor:1') == nil, 'the seat being left is not "seated again"')
    local legacy = nil
    for _, entry in ipairs(player.cameraLog) do if entry.legacy and entry.on then legacy = entry end end
    check(legacy ~= nil and legacy.at - leftAt >= 1500 and legacy.at - leftAt <= 1700,
        'the client pulled its legacy exit camera 1.6 s after the exit')
    local off = nil
    for _, entry in ipairs(player.cameraLog) do if not entry.legacy and entry.on == false then off = entry end end
    check(off ~= nil and legacy ~= nil and off.at - legacy.at <= 150, 'and the walk-out turned it off within a look')
    check(W.logged('legacy exit camera holds the screen (the perspective arbiter answers fatal_state): turned off (done)',
        'client:open77_avdoor:1') ~= nil, 'saying so')
    check(W.logged('exit view: the platform\'s perspective: fpp, settled, fatal_state (rule fatal)', 'client:open77_avdoor:1') ~= nil
        and W.logged('exit view: the platform\'s perspective: tps, settled, resource_forced (rule resource_forced), camera '
            .. 'open77_rig, body proxy', 'client:open77_avdoor:1') ~= nil, 'every answer of the arbiter is a line')
    check(W.logged('exit clip step waits for the platform\'s third person', 'client:open77_avdoor:1') ~= nil
        and W.logged('exit clip step: third person ready', 'client:open77_avdoor:1') ~= nil, 'the clip waits for the view')
    check(played ~= nil and played.clip == 'step' and played.at - leftAt >= 4300 and played.at - leftAt <= 5200,
        ('asked once the stand-in is up: %d ms after the exit'):format(played and played.at - leftAt or -1))
    local back = lastFadeIn(player)
    check(back ~= nil and played ~= nil and back.at >= played.at, 'the screen stays faded until the clip starts')
    check(W.logged('exit fade over after', 'client:open77_avdoor:1') ~= nil
        and W.logged('(the ceiling)', 'client:open77_avdoor:1') == nil, 'without reaching the fade\'s ceiling')
    local shown = firstVisibility(1, true)
    check(shown ~= nil and played ~= nil and math.abs(shown.at - played.at) <= 10,
        'the others see the body as the clip starts, not before')
    -- A stand-in that never comes: the clip is asked at VIEW_WAIT_MS all the same.
    world(function()
        W.exitPackage()
        W.vehicle(HULL, AV, 0, 0, 1.5)
        W.player(1, 0, 0, 2.5, { tpsReadyMs = false })
    end, { 1 })
    W.seat(1, HULL, 'seat_back_left')
    W.advance(800)
    leftAt = W.now
    W.leave(1, { confirmMs = 1500 })
    played = nil
    for _ = 1, 90 do
        W.advance(100)
        played = played or W.locomotion.played[1]
    end
    check(played ~= nil and played.at - leftAt >= 4900 and played.at - leftAt <= 5600,
        ('no third person: asked at the wait\'s end, %d ms after the exit'):format(played and played.at - leftAt or -1))
    -- (5.0 or 5.1 s: the exit is seen at its first frame, between two of the watch's looks.)
    check(W.logged('exit clip step: the platform\'s third person was not ready after 5.', 'client:open77_avdoor:1') ~= nil,
        'and the log says the view never came')
end)

--- The first entry of a list matching `filter`, or nil.
local function firstOf(list, filter)
    for _, entry in ipairs(list) do if filter(entry) then return entry end end
    return nil
end

run('Staging, 2026-10-27, 18:57:58, four frames a second: the clip waits for the stand-in in frames, seen from in front', function()
    world(function()
        W.exitPackage()
        W.vehicle(HULL, AV, 0, 0, 1.5, { halfWidth = 1.84, halfLength = 4.8 })
        -- 250 ms a frame: the game ran at 3 to 4 frames a second.
        W.player(1, 0, 0, 2.5, { frameMs = 250 })
        W.player(2, 30, 0, 0)
    end, { 1, 2 })
    W.seat(1, HULL, 'seat_front_left')
    W.advance(1500)
    local player = W.players[1]
    local leftAt = W.now
    W.leave(1, { confirmMs = 500 })
    local played = nil
    for _ = 1, 160 do
        W.advance(100)
        played = played or W.locomotion.played[1]
    end
    local name = 'client:open77_avdoor:1'
    -- THE CHASE CAMERA is the client's own: left to its deadline.
    check(W.logged('exit view: the client\'s chase camera still holds the screen (', name) ~= nil,
        'the chase camera, 17 m off, is told apart and left alone')
    local legacy = firstOf(player.cameraLog, function(e) return e.legacy and e.on end)
    local off = firstOf(player.cameraLog, function(e) return not e.legacy and e.on == false end)
    check(legacy ~= nil and off ~= nil and off.at >= legacy.at and off.at - legacy.at <= 350,
        ('the legacy camera off within a frame of coming: %d ms'):format((off and legacy) and off.at - legacy.at or -1))
    check(off ~= nil and legacy ~= nil and off.at >= legacy.at,
        'and never before it came (nothing fights the chase camera)')
    check(W.logged('turned off (done), ', name) ~= nil and W.logged('(the camera 2.6 m from the eyes)', name) ~= nil,
        'saying where the camera was')
    -- THE WAIT IS IN FRAMES: twelve clean frames (3 s here), then the reveal.
    check(played ~= nil and off ~= nil and played.at - off.at >= 3000 + 500,
        ('not asked before the arbiter let go: %d ms after the camera went off'):format((played and off) and played.at - off.at or -1))
    check(played ~= nil and played.at - leftAt > 5000 and played.at - leftAt <= 7000,
        ('asked as the stand-in was drawn, past the old 5 s: %d ms after the exit'):format(played and played.at - leftAt or -1))
    check(W.logged('exit view: third person drawn (the stand-in, with its head)', name) ~= nil, 'the reveal is a line')
    check(W.logged('exit clip step: third person ready', name) ~= nil
        and W.logged('look(s) after the client\'s exit camera went off', name) ~= nil, 'counted in looks')
    check(W.logged('was not ready after', name) == nil, 'the wait did not give up')
    -- THE SHOT: swung round before the image came back, back as the clip ended.
    local swung = firstOf(player.orbitLog, function(e) return e.on and not e.refused end)
    local back = lastFadeIn(player)
    check(swung ~= nil and swung.degrees == 160, 'the camera swung 160 deg round the body')
    check(swung ~= nil and back ~= nil and swung.at <= back.at and played ~= nil and swung.at <= played.at,
        'before the clip and before the image came back')
    check(back ~= nil and played ~= nil and back.at >= played.at, 'the image came back on the clip\'s first step')
    check(W.logged('(the ceiling)', name) == nil, 'not at the fade\'s ceiling')
    local unswung = firstOf(player.orbitLog, function(e) return e.on == false end)
    check(unswung ~= nil and played ~= nil and unswung.at - played.at >= 4300 and unswung.at - played.at <= 5500,
        ('back behind the body as the clip ended: %d ms after it began'):format((unswung and played) and unswung.at - played.at or -1))
    check(W.logged('exit view: the camera swung 160 deg round the body', name) ~= nil
        and W.logged('exit view: the camera back behind the body after', name) ~= nil, 'both are lines')
    -- The others: the body hidden until the clip, the door open through it.
    local shown = firstVisibility(1, true)
    check(shown ~= nil and played ~= nil and math.abs(shown.at - played.at) <= 10, 'the others see the body as the clip starts')
    check(W.logged('the trunk door of 4294967297 held open for the exit clip: closing in 5.8s', 'server:open77_avdoor') ~= nil,
        'the door held open through the clip')
    local closed = firstOf(W.doorLog, function(e) return e.open == false and e.door == 'trunk' end)
    check(closed ~= nil and played ~= nil and closed.at - played.at >= 4300 + 1400,
        ('closed after the clip, not on it: %d ms after it began'):format((closed and played) and closed.at - played.at or -1))
    -- The body held still from the wait to the clip's end, and free after.
    local froze = firstOf(player.frozenLog, function(e) return e.position == true end)
    check(froze ~= nil and played ~= nil and froze.at < played.at, 'the body held still through the wait')
    check(player.frozenPosition == false, 'and free once the clip is over')
end)

run('four frames a second, and the stand-in never comes: given up in looks; the curtain up at its own ceiling first', function()
    world(function()
        W.exitPackage()
        W.vehicle(HULL, AV, 0, 0, 1.5)
        W.player(1, 0, 0, 2.5, { frameMs = 250, tpsReadyMs = false })
    end, { 1 })
    W.seat(1, HULL, 'seat_front_left')
    W.advance(1500)
    local player = W.players[1]
    local leftAt = W.now
    W.leave(1, { confirmMs = 500 })
    local played = nil
    for _ = 1, 160 do
        W.advance(100)
        played = played or W.locomotion.played[1]
    end
    local name = 'client:open77_avdoor:1'
    local off = firstOf(player.cameraLog, function(e) return not e.legacy and e.on == false end)
    check(played ~= nil and off ~= nil and played.at - off.at >= 30 * 250 - 300,
        ('thirty looks after the camera went off: %d ms'):format((played and off) and played.at - off.at or -1))
    check(played ~= nil and played.at - leftAt < 12000 + 300,
        ('inside VIEW_WAIT_MAX_MS: %d ms after the exit'):format(played and played.at - leftAt or -1))
    check(W.logged('exit clip step: the platform\'s third person was not ready after', name) ~= nil
        and W.logged('30 looks after the client\'s exit camera went off', name) ~= nil, 'and the log says why')
    check(#player.orbitLog == 0, 'no shot without the stand-in')
    -- THE CURTAIN'S CEILING (1.6.0, `EXIT_FADE.MAX_MS` 6 s): nobody is kept in
    -- black for the twelve seconds a view may take; the step is then asked in view.
    local down = firstOf(player.fades, function(f) return f.out == true end)
    local back = lastFadeIn(player)
    check(down ~= nil and back ~= nil and back.at - down.at >= 5900 and back.at - down.at <= 6200,
        ('the image back at the curtain\'s ceiling: %d ms black'):format((down and back) and back.at - down.at or -1))
    check(back ~= nil and played ~= nil and back.at < played.at, 'before the step, which is asked in view')
    check(W.logged('exit curtain: 6.0s black, its ceiling', name) ~= nil, 'saying so')
    check(W.grounded(player) and (player.screenMoves or 0) == 0, 'the body never moved under the curtain, on its feet')
end)

run('without Open77.camera.view the legacy camera is turned off from 1.6 s, as before', function()
    world(function()
        W.exitPackage()
        W.vehicle(HULL, AV, 0, 0, 1.5)
        W.player(1, 0, 0, 2.5, { noCameraView = true, tpsReadyMs = 800 })
    end, { 1 })
    W.seat(1, HULL, 'seat_back_left')
    W.advance(800)
    local player = W.players[1]
    local leftAt = W.now
    W.leave(1, { confirmMs = 1500 })
    local played = nil
    for _ = 1, 90 do
        W.advance(100)
        played = played or W.locomotion.played[1]
    end
    local first = firstOf(player.cameraLog, function(e) return not e.legacy and e.on == false end)
    check(first ~= nil and first.at - leftAt >= 1600, 'nothing turned off before 1.6 s')
    check(W.logged('(the camera not measured from the eyes)', 'client:open77_avdoor:1') ~= nil, 'and the log says so')
    check(played ~= nil and played.clip == 'step', 'the clip played')
end)

run('a swing the rig refuses is tried again, and the clip is seen from behind when it never takes', function()
    world(function()
        W.exitPackage()
        W.vehicle(HULL, AV, 0, 0, 1.5)
        W.player(1, 0, 0, 2.5, { tpsReadyMs = 800 })
    end, { 1 })
    local client = W.vms['client:open77_avdoor:1']
    client.env.Open77.camera.orbit = function() return false, 'camera_preview_owned' end
    W.seat(1, HULL, 'seat_back_left')
    W.advance(800)
    W.leave(1, { confirmMs = 1500 })
    local played = nil
    for _ = 1, 110 do
        W.advance(100)
        played = played or W.locomotion.played[1]
    end
    check(played ~= nil, 'the clip played')
    check(W.count('exit view: the camera could not swing round the body (camera_preview_owned', 'client:open77_avdoor:1') == 6,
        'tried six times')
    check(W.logged('try 6 of 6): the clip is seen from behind', 'client:open77_avdoor:1') ~= nil, 'then said once')
end)

--- Every `camera.thirdPerson(false)` the walk-out asked after `t`.
local function legacyOffsAfter(player, t)
    local n = 0
    for _, entry in ipairs(player.cameraLog) do
        if entry.legacy == false and entry.on == false and entry.at > t then n = n + 1 end
    end
    return n
end

run('Staging, 2026-10-27, 17:39:21: after the clip the view is the player\'s own at once; nothing throws it to first person', function()
    world(function()
        W.exitPackage()
        W.vehicle(HULL, AV, 0, 0, 1.5)
        W.player(1, 0, 0, 2.5, { tpsReadyMs = 800 })
    end, { 1 })
    W.seat(1, HULL, 'seat_back_left')
    W.advance(800)
    local player = W.players[1]
    W.leave(1, { confirmMs = 1500 })
    local played = nil
    for _ = 1, 110 do
        W.advance(100)
        played = played or W.locomotion.played[1]
    end
    check(played ~= nil and played.clip == 'step', 'the clip played')
    if played == nil then return end
    check(W.logged('exit view: third person settled', 'client:open77_avdoor:1') ~= nil, 'the settle is a line')
    check(legacyOffsAfter(player, played.at - 1) == 0,
        ('once third person settled, the client\'s exit camera is left alone: %d call(s)'):format(legacyOffsAfter(player, played.at - 1)))
    local released = nil
    for _, v in ipairs(player.views) do if v.clear and released == nil then released = v end end
    check(released ~= nil and released.at - played.at >= 4300 and released.at - played.at <= 5000,
        ('the view goes back as the clip ends: %d ms after it started'):format(released and released.at - played.at or -1))
    -- The first steps: the client turns its own exit camera off -- with the
    -- view the player's own already, that is the camera the player has.
    for _ = 1, 6 do
        player.x = player.x - 0.3
        W.advance(100)
    end
    check(player.exitTppOff ~= nil, 'the client turned its exit camera off on the first steps')
    check((player.attaches or 0) == 0, 'under no third person held by the exit: no first-person flash')
    local state = W.vms['client:open77_avdoor:1'] and W.vms['client:open77_avdoor:1'].env.Open77.perspective.state()
    check(state ~= nil and state.reason == 'player_preference' and state.settled == true,
        'the view is the player\'s own, settled: ' .. tostring(state and state.reason))

    -- HELD UNTIL THE PLAYER WALKS OFF (`RELEASE_AFTER_CLIP = false`): the
    -- client's exit camera off under it is the fatal row, and the walk-out
    -- leaves the camera alone -- the arbiter puts third person back itself.
    world(function()
        W.exitPackage()
        W.vehicle(HULL, AV, 0, 0, 1.5)
        W.player(1, 0, 0, 2.5, { tpsReadyMs = 800 })
    end, { 1 })
    for _, vm in pairs(W.vms) do vm.env.AvDoor.Settings.EXIT_ANIM.RELEASE_AFTER_CLIP = false end
    settingsChanged()
    W.seat(1, HULL, 'seat_back_left')
    W.advance(800)
    player = W.players[1]
    W.leave(1, { confirmMs = 1500 })
    played = nil
    for _ = 1, 110 do
        W.advance(100)
        played = played or W.locomotion.played[1]
    end
    check(played ~= nil, 'the clip played')
    if played == nil then return end
    local clears = 0
    for _, v in ipairs(player.views) do if v.clear then clears = clears + 1 end end
    check(clears == 0, 'held while the player stands')
    -- A step a second: slow enough not to be "walked off", quick enough for the client's 0.4 m/s.
    for _ = 1, 3 do
        player.x = player.x - 0.05
        W.advance(100)
    end
    check(player.exitTppOff ~= nil and (player.attaches or 0) == 1, 'the client\'s exit camera off threw the held view')
    W.advance(3000)
    check(legacyOffsAfter(player, played.at - 1) == 0,
        ('and the walk-out did not throw it again: %d call(s)'):format(legacyOffsAfter(player, played.at - 1)))
    check(W.logged('exit view: the platform\'s perspective: fpp, settled, fatal_state (rule fatal)', 'client:open77_avdoor:1') ~= nil,
        'the fatal row is a line')
    local again = W.vms['client:open77_avdoor:1'].env.Open77.perspective.state()
    check(again.mode == 'tps' and again.settled == true, 'third person back by itself: ' .. tostring(again.reason))
end)

run('a right door plays the mirrored clip, and a record plays its own', function()
    world(function()
        W.exitPackage()
        W.vehicle(HULL, GENERIC, 0, 0, 1.5)
        W.vehicle(HULL + 1, MAXTAC, 100, 0, 1.5)
        W.player(1, 0, 0, 2.5)
        W.player(2, 100, 0, 2.5)
    end, { 1, 2 })
    for _, vm in pairs(W.vms) do vm.env.AvDoor.Settings.EXIT_ANIM.RECORDS = { ['vehicle.max_tac_av'] = 'step_m' } end
    settingsChanged()
    W.seat(1, HULL, 'seat_front_right')
    W.seat(2, HULL + 1, 'seat_back_left')
    W.advance(800)
    W.leave(1)
    W.leave(2)
    W.advance(3200)
    local right = W.players[1].teleports[1] or { x = 0, y = 0 }
    check(right.x > 5 and math.abs((right.heading or 0) - 285.1) < 0.3,
        ('the right door: the mirrored clip\'s end on the right, %.2f facing %.1f'):format(right.x, right.heading or -1))
    local byPlayer = {}
    for _, entry in ipairs(W.locomotion.played) do byPlayer[entry.player] = entry.clip end
    check(byPlayer[1] == 'step_m', 'step_m for the right door, got ' .. tostring(byPlayer[1]))
    check(byPlayer[2] == 'step_m', 'the MaxTac AV plays its own clip, got ' .. tostring(byPlayer[2]))
end)

--- Where a point `(right, ahead)` of a hull's own frame is on the map.
local function onHull(hull, right, ahead)
    local fx, fy, lx, ly = W.axes(hull)
    return hull.x + fx * ahead - lx * right, hull.y + fy * ahead - ly * right
end

local function doorsOpened(name)
    local out = {}
    for _, entry in ipairs(W.doorLog) do
        if entry.open and (name == nil or entry.door == name) then out[#out + 1] = entry end
    end
    return out
end

run('the Rayfield Excalibur: one door, on the left, for every seat -- boarding, the clip and the plain exit', function()
    world(function()
        W.exitPackage()
        W.vehicle(HULL, AV, 0, 0, 1.5, { halfWidth = 1.84, halfLength = 4.8 })
        W.player(1, 0, 0, 2.5)
        W.player(2, 0, 0, 2.5)
        W.player(3, 30, 0, 0)
    end, { 1, 2, 3 })
    local hull = W.vehicles[HULL]
    W.seat(1, HULL, 'seat_front_left')
    W.seat(2, HULL, 'seat_back_right')
    W.advance(1000)
    -- THE PILOT steps out of the one door: the middle of its step, 1.45 m out
    -- on the left, 0.13 m behind the centre, the step clip's first frame on it.
    W.leave(1, { eject = false })
    W.advance(300)
    local pilot = W.players[1].teleports[1] or { x = 0, y = 0 }
    local doorX, doorY = onHull(hull, -1.45, -0.13)
    local sx, sy = server.env.AvDoor.WalkOutStart(pilot, pilot.heading or 0, 'step')
    check(math.abs(sx - doorX) < 0.01 and math.abs(sy - doorY) < 0.01,
        ('the pilot\'s clip starts on the Excalibur\'s door: %.2f, %.2f (door %.2f, %.2f)'):format(sx, sy, doorX, doorY))
    check(pilot.x < -3.0, 'and ends on the left, clear of the hull: ' .. tostring(pilot.x))
    check(W.logged('exit clip step planned: door 1.45 m out (the Rayfield Excalibur\'s door, left)',
        'client:open77_avdoor:1') ~= nil, 'the plan names the airframe')
    check(math.abs((pilot.z or -1) - 0.03) < 1e-6, ('the clip ends ON the ground, 3 cm up: %.3f'):format(pilot.z or -1))
    -- THE RIGHT-HAND PASSENGER leaves through the same door: the unmirrored
    -- clip, on the left, and the left door swings -- not a right one.
    W.advance(4000)
    -- Somebody is still aboard: the hull stays where the flight left it.
    check(#hull.transforms == 0 and hull.z == 1.5, 'not set down while a passenger sits in it')
    check(W.logged('aircraft 4294967297 stays where the flight left it: 1 aboard', 'server:open77_avdoor') ~= nil,
        'and the server says why')
    W.leave(2, { eject = false })
    W.advance(300)
    local passenger = W.players[2].teleports[1] or { x = 0, y = 0 }
    check(passenger.x < -3.0, ('the right seat steps out on the LEFT: %.2f'):format(passenger.x))
    local px, py = server.env.AvDoor.WalkOutStart(passenger, passenger.heading or 0, 'step')
    check(math.abs(px - doorX) < 0.01 and math.abs(py - doorY) < 0.01, 'through the same door')
    W.advance(3000)
    local clips = {}
    for _, entry in ipairs(W.locomotion.played) do clips[entry.player] = entry.clip end
    check(clips[1] == 'step' and clips[2] == 'step', ('both play the step clip: %s, %s')
        :format(tostring(clips[1]), tostring(clips[2])))
    check(#doorsOpened('trunk') >= 2 and #doorsOpened('frontLeft') == 0 and #doorsOpened('backRight') == 0
        and #doorsOpened('frontRight') == 0,
        'the Excalibur\'s one door swings for both -- the platform\'s trunk, which its graph answers -- and no cabin door is asked for')
    -- THE LAST BODY OUT: the hull is set down on its gear, its origin 1.0 m over the ground.
    check(#hull.transforms == 1 and math.abs(hull.z - 1.0) < 1e-6 and hull.transforms[1].hadYaw == true
        and math.abs(hull.transforms[1].yaw - 0.0) < 1e-6,
        ('set down on its gear once nobody is aboard: z %.2f, %d move(s)'):format(hull.z, #hull.transforms))
    check(W.logged('aircraft 4294967297 set down on its gear 0.50 m lower (1.50 -> 1.00', 'server:open77_avdoor') ~= nil,
        'the server says so')
    check(W.logged('it hovers 0.50 m over its gear (origin 1.50, the ground under its 3 feet 0.00, 0.00, 0.00)',
        'client:open77_avdoor:2') ~= nil, 'the exiting game says what it measured')
    -- BOARDING a right-hand seat swings that door too.
    W.doorLog = {}
    W.players[3].x, W.players[3].y, W.players[3].z = -3.0, 0.0, 0.0
    W.advance(1200)
    W.press(3, 'F')
    -- 1.7.0: the boarding step -- the body put a metre before the door, the
    -- step up into it, the seat at its end.
    W.advance(6000)
    check(W.players[3].seat ~= nil, 'player 3 boards')
    local stepped = nil
    for _, entry in ipairs(W.locomotion.played) do if entry.player == 3 then stepped = entry end end
    check(stepped ~= nil and stepped.clip == 'enter', 'with the step up into the door: ' .. tostring(stepped and stepped.clip))
    check(#doorsOpened('trunk') >= 1 and #doorsOpened('frontRight') == 0 and #doorsOpened('backLeft') == 0
        and #doorsOpened('frontLeft') == 0, 'through the one door, whatever the seat')
end)

run('the Rayfield Excalibur on its gear: one floor under its feet, coming down, nobody aboard, nobody posing it', function()
    -- Flies in at 1.5 m (the flight's belly ray: 1.46 on Staging), parked with its nose on the hull's heading.
    local function exitOver(ground, hullZ, setup)
        world(function()
            W.groundAt = ground
            W.vehicle(HULL, AV, 0, 0, hullZ, { heading = 90.0 })
            W.player(1, 0, 0, hullZ + 1.0)
            W.player(2, 30, 0, 0)
            if setup ~= nil then setup() end
        end, { 1, 2 })
        W.seat(1, HULL, 'seat_front_left')
        W.advance(800)
        W.leave(1, { eject = false })
        W.advance(3000)
        return W.vehicles[HULL]
    end
    -- Facing west (heading 90): the nose gear 2.26 m west of the origin, the main gear 3.43 m east.
    local hull = exitOver(function(x) return x < -1.0 and 0.12 or 0.0 end, 1.5)
    check(#hull.transforms == 1 and math.abs(hull.z - 1.12) < 1e-6,
        ('on the highest foot\'s ground (the nose gear on a 12 cm step): %.2f'):format(hull.z))
    check(W.logged('the ground under its 3 feet 0.12, 0.00, 0.00', 'client:open77_avdoor:1') ~= nil,
        'the feet are where the airframe has them, turned with the hull')
    -- A kerb under one foot: not one floor.
    hull = exitOver(function(x) return x < -1.0 and 0.5 or 0.0 end, 1.5)
    check(#hull.transforms == 0 and hull.z == 1.5, 'a kerb under the nose gear: left where it is')
    -- The measure goes to the server either way: the server says why, and the
    -- exit is not left open for another (it was made under the hull itself).
    local lands = W.sent('open77_avdoor:land')
    check(W.logged('the hull is not to be lowered as this game measures it (uneven:0.50', 'client:open77_avdoor:1') ~= nil
        and #lands == 1 and lands[1].payload.why == 'uneven:0.50', 'the game says why, and sends its measure all the same')
    check(W.logged('aircraft 4294967297 stays where the flight left it: uneven:0.50', 'server:open77_avdoor') ~= nil
        and W.logged('the game said: uneven:0.50', 'server:open77_avdoor') ~= nil
        and W.logged('sent no measure', 'server:open77_avdoor') == nil, 'and so does the server')
    -- Already on its gear, or hovering over a drop.
    hull = exitOver(function() return 0.0 end, 1.02)
    check(#hull.transforms == 0 and W.logged('(on_its_gear:0.02', 'client:open77_avdoor:1') ~= nil, 'already on its gear')
    check(W.logged('aircraft 4294967297 already stands on its gear (0.02 m over it', 'server:open77_avdoor') ~= nil
        and W.logged('sent no measure', 'server:open77_avdoor') == nil,
        'the server says so -- not "sent no measure" (Staging, 2026-10-28, 01:11:16)')
    -- 1.7.9: lowered by `MAX_DROP_METRES` (3.0) at most -- 3.5 m over its gear is not a landing.
    hull = exitOver(function() return 0.0 end, 4.5)
    check(#hull.transforms == 0 and W.logged('(too_far:3.50', 'client:open77_avdoor:1') ~= nil,
        'three and a half metres over its gear: not a landing')
    check(W.logged('aircraft 4294967297 stays where the flight left it: too_far:3.50', 'server:open77_avdoor') ~= nil,
        'and the server says why')
    -- Posed by a resource: left alone.
    hull = exitOver(function() return 0.0 end, 1.5, function() W.after(1000, function() W.vehicles[HULL].frozen = true end) end)
    check(#hull.transforms == 0 and W.logged('aircraft 4294967297 stays where the flight left it: it is frozen',
        'server:open77_avdoor') ~= nil, 'a frozen hull is a resource\'s')
    -- Only the exiting player's own measure is used: somebody else's cannot
    -- stand in for it.
    world(function()
        W.vehicle(HULL, AV, 0, 0, 1.5)
        W.player(1, 0, 0, 2.5)
        W.player(2, 5, 0, 0)
    end, { 1, 2 })
    W.seat(1, HULL, 'seat_front_left')
    W.advance(800)
    local function claim(playerId, grounds)
        for _, vm in pairs(W.vms) do
            if vm.playerId == playerId then
                vm.env.TriggerServerEvent('open77_avdoor:land', { id = HULL_TEXT, grounds = grounds, x = 0, y = 0 })
            end
        end
        W.run()
    end
    W.leave(1, { eject = false })
    W.advance(300)
    claim(2, { 0.4, 0.4, 0.4 })
    W.advance(3000)
    hull = W.vehicles[HULL]
    check(#hull.transforms == 1 and math.abs(hull.z - 1.0) < 1e-6,
        ('set down on its own player\'s measure, whatever another game claimed: %.2f'):format(hull.z))
    -- The server sums the height itself, against its own hull: a game that
    -- claims the ground is three metres down cannot sink it past `MAX_DROP_METRES`.
    world(function()
        W.vehicle(HULL, AV, 0, 0, 1.5)
        W.player(1, 0, 0, 2.5)
    end, { 1 })
    W.seat(1, HULL, 'seat_front_left')
    W.advance(800)
    W.leave(1, { eject = false })
    W.advance(600)   -- past the 250 ms between two measures a game may send
    claim(1, { -3.0, -3.0, -3.0 })
    W.advance(3000)
    hull = W.vehicles[HULL]
    check(#hull.transforms == 0 and hull.z == 1.5, ('not sunk into the ground: %.2f'):format(hull.z))
    check(W.logged('aircraft 4294967297 stays where the flight left it: too_far:3.50', 'server:open77_avdoor') ~= nil,
        'the server says why')
    W.groundAt = nil
end)

run('the Rayfield Excalibur without the exit package: the plain exit is on the left for a right seat', function()
    world(function()
        W.vehicle(HULL, AV, 0, 0, 1.5, { heading = 30.0, halfWidth = 1.84, halfLength = 4.8 })
        W.player(1, 0, 0, 2.5)
    end, { 1 })
    local hull = W.vehicles[HULL]
    W.seat(1, HULL, 'seat_front_right')
    W.advance(800)
    W.leave(1, { eject = false })
    W.advance(300)
    local target = W.players[1].teleports[1] or { x = 0, y = 0 }
    local x, y = onHull(hull, -6.0, -0.13)
    check(math.abs(target.x - x) < 0.01 and math.abs(target.y - y) < 0.01,
        ('6 m out on the left, level with the door, the hull turned 30 deg: %.2f, %.2f (expected %.2f, %.2f)')
            :format(target.x, target.y, x, y))
    check(W.logged('(seat_front_right, Rayfield Excalibur, its left door)', 'client:open77_avdoor:1') ~= nil,
        'the guard names the airframe\'s door')
end)

run('the Militech Manticore: four doors 2.45 m out, the back pair 0.65 m behind the centre', function()
    world(function()
        W.exitPackage()
        W.vehicle(HULL, MANTICORE, 10, 20, 1.5, { heading = 90.0, halfWidth = 2.5, halfLength = 6.3 })
        W.player(1, 10, 20, 2.5)
    end, { 1 })
    local hull = W.vehicles[HULL]
    W.seat(1, HULL, 'seat_back_right')
    W.advance(800)
    -- 1.9.0: a Manticore's seat is stepped out of through the exit key (the
    -- game's own exit is animated): the server's forced exit, instant.
    check(W.pressMapped(1, LEAVE_KEY), 'the exit key')
    W.advance(300)
    local target = W.players[1].teleports[1] or { x = 0, y = 0 }
    local doorX, doorY = onHull(hull, 2.45, -0.65)
    local sx, sy = server.env.AvDoor.WalkOutStart(target, target.heading or 0, 'step_m')
    check(math.abs(sx - doorX) < 0.01 and math.abs(sy - doorY) < 0.01,
        ('the mirrored clip starts on the back-right door: %.2f, %.2f (door %.2f, %.2f)'):format(sx, sy, doorX, doorY))
    W.advance(3000)
    check(W.locomotion.played[1] ~= nil and W.locomotion.played[1].clip == 'step_m', 'step_m for the right door')
end)

run('a hull this resource does not know: its half width from the mesh box turned by its heading', function()
    local AvDoor = nil
    world(function()
        W.boundsSpace = 'world'      -- the card's world box (the client answers the hull's own: below)
        W.exitPackage()
        W.vehicle(HULL, GENERIC, 0, 0, 1.5, { heading = 20.0, halfWidth = 2.0, halfLength = 6.0 })
        W.vehicle(HULL + 1, GENERIC, 60, 0, 1.5, { heading = 45.0, halfWidth = 2.0, halfLength = 6.0 })
        W.player(1, 0, 0, 2.5)
        W.player(2, 60, 0, 2.5)
    end, { 1, 2 })
    AvDoor = server.env.AvDoor
    -- The arithmetic, exactly: a 2 x 6 m half box turned 20 degrees.
    local fx, fy = W.axes(W.vehicles[HULL])
    local hx = 6.0 * math.abs(fx) + 2.0 * math.abs(fy)
    local hy = 6.0 * math.abs(fy) + 2.0 * math.abs(fx)
    local width = AvDoor.HullHalfWidth({ min = { x = -hx, y = -hy }, max = { x = hx, y = hy } }, { x = fx, y = fy })
    check(width ~= nil and math.abs(width - 2.0) < 1e-6, 'the half width comes back from the turned box: '
        .. tostring(width))
    check(AvDoor.HullHalfWidth({ min = { x = -5, y = -5 }, max = { x = 5, y = 5 } }, { x = 0.7071, y = 0.7071 }) == nil,
        'not near a diagonal: the box cannot tell width from length there')
    W.seat(1, HULL, 'seat_front_left')
    W.seat(2, HULL + 1, 'seat_front_left')
    W.advance(800)
    W.leave(1, { eject = false })
    W.leave(2, { eject = false })
    W.advance(300)
    check(W.logged('exit clip step planned: door 2.30 m out (the hull\'s bounds: 2.00 m half width)',
        'client:open77_avdoor:1') ~= nil, 'turned 20 degrees: the measured half width and the margin')
    check(W.logged('exit clip step planned: door 2.40 m out (DOOR_METRES (the hull stands near a diagonal))',
        'client:open77_avdoor:2') ~= nil, 'turned 45 degrees: DOOR_METRES, not the box\'s corner 6 m away')
end)

run('the client answers the mesh box in the hull\'s own frame: the half width at any heading, the box turned out', function()
    world(function()
        W.exitPackage()
        W.vehicle(HULL, GENERIC, 0, 0, 1.5, { heading = 20.0, halfWidth = 2.0, halfLength = 6.0 })
        W.vehicle(HULL + 1, GENERIC, 60, 0, 1.5, { heading = 45.0, halfWidth = 2.0, halfLength = 6.0 })
        W.player(1, 0, 0, 2.5)
        W.player(2, 60, 0, 2.5)
    end, { 1, 2 })
    local AvDoor = server.env.AvDoor
    local local_ = { min = { x = -2.0, y = -6.0, z = -1.5 }, max = { x = 2.0, y = 6.0, z = 1.5 } }
    check(AvDoor.BoundsLocal(local_, { x = 1000, y = 2000, z = 100 }) == true, 'a box round the origin is the hull\'s own')
    check(AvDoor.BoundsLocal({ min = { x = 998, y = 1994, z = 98.5 }, max = { x = 1002, y = 2006, z = 101.5 } },
        { x = 1000, y = 2000, z = 100 }) == false, 'a box round the hull is the world\'s')
    check(AvDoor.LocalHalfWidth(local_) == 2.0, 'its half width, read off it')
    -- Turned 90 degrees (facing -x) at (1000, 2000, 100), its centre 1 m toward the nose and 0.7 m down.
    local box = AvDoor.WorldBox({ min = { x = -2.0, y = -5.0, z = -2.2 }, max = { x = 2.0, y = 7.0, z = 0.8 } },
        { x = 1000, y = 2000, z = 100 }, { x = 0, y = 0, z = math.sin(math.pi / 4), w = math.cos(math.pi / 4) })
    check(box ~= nil and box.hullFrame == true and math.abs(box.centre.x - 999.0) < 1e-6
        and math.abs(box.centre.y - 2000.0) < 1e-6 and math.abs(box.bottom - 97.8) < 1e-6,
        ('turned out into the world: centre %.3f, %.3f, lowest %.3f'):format(box and box.centre.x or -1,
            box and box.centre.y or -1, box and box.bottom or -1))
    W.seat(1, HULL, 'seat_front_left')
    W.seat(2, HULL + 1, 'seat_front_left')
    W.advance(800)
    W.leave(1, { eject = false })
    W.leave(2, { eject = false })
    W.advance(300)
    check(W.logged('exit clip step planned: door 2.30 m out (the hull\'s bounds: 2.00 m half width)',
        'client:open77_avdoor:1') ~= nil and W.logged('exit clip step planned: door 2.30 m out (the hull\'s bounds: 2.00 m '
        .. 'half width)', 'client:open77_avdoor:2') ~= nil, 'the half width at 20 and at 45 degrees alike')
end)

run('without open77_avexit the exit is the plain one, said once, and the body shown at once', function()
    world(function()
        W.locomotion = { registered = {}, assignments = {}, played = {}, clips = {} }
        W.vehicle(HULL, AV, 0, 0, 1.5)
        W.player(1, 0, 0, 2.5)
    end, { 1 })
    W.seat(1, HULL, 'seat_front_left')
    W.advance(800)
    check(W.locomotion.assignments[1] == nil, 'no style')
    check(W.logged('is not registered: start open77_avexit', 'server:open77_avdoor', 'warn') ~= nil, 'said in the log')
    check(W.logged('exit clips off for this player: locomotion_package_unavailable', 'client:open77_avdoor:1') ~= nil,
        'the client is told why')
    W.leave(1)
    W.advance(300)
    local target = W.players[1].teleports[1] or { x = 0, y = 0 }
    local side = distance2(target, { x = 0, y = 0 })
    check(side > 5.5 and side < 6.6, ('the plain exit, 6 m out: %.2f'):format(side))
    local hid, shown = firstVisibility(1, false), firstVisibility(1, true)
    check(hid == nil or (shown ~= nil and shown.at - hid.at <= 300), 'the body is not kept from the others')
    W.advance(4000)
    check(#W.locomotion.played == 0, 'no clip')
    check(W.players[1].covered == nil, 'the image is back')
    -- A second boarding a moment later does not ask the host again.
    W.leave(1)
    W.seat(1, HULL, 'seat_front_left')
    W.advance(500)
    check(W.count('is not registered: start open77_avexit', 'server:open77_avdoor') == 1, 'one line a minute')
end)

run('a style another resource gave is kept, and that player steps out unanimated', function()
    world(function()
        W.exitPackage()
        W.styleFrom(1, 'my_walk_menu', 'relaxed')
        W.vehicle(HULL, AV, 0, 0, 1.5)
        W.player(1, 0, 0, 2.5)
    end, { 1 })
    W.seat(1, HULL, 'seat_front_left')
    W.advance(800)
    local kept = W.locomotion.assignments[1]
    check(kept.style == 'relaxed' and kept.owner == 'my_walk_menu', 'the other resource\'s style is not taken')
    check(W.logged('exit clips off for this player: style_owned_elsewhere', 'client:open77_avdoor:1') ~= nil,
        'the client is told')
    W.leave(1)
    W.advance(3500)
    check(#W.locomotion.played == 0, 'no clip')
    check(W.players[1].covered == nil, 'the plain exit ends')
end)

run('a hull in the air: no clip, the body falls from the door, and the view still keeps the head', function()
    world(function()
        W.exitPackage()
        W.vehicle(HULL, AV, 0, 0, 20.0)
        W.player(1, 0, 0, 21.0)
    end, { 1 })
    W.seat(1, HULL, 'seat_front_left')
    W.advance(800)
    W.leave(1, { eject = false })
    W.advance(300)
    check(W.logged('exit clip: none -- the hull is', 'client:open77_avdoor:1') ~= nil, 'no clip in the air')
    local target = W.players[1].teleports[1] or { z = 0 }
    check(math.abs(target.z - 19.2) < 0.01, 'the body is put at the door\'s height: ' .. tostring(target.z))
    check(#views(W.players[1], function(v) return v.tps == true end) == 1, 'the view is held')
    W.advance(4000)
    check(#W.locomotion.played == 0, 'nothing played')
    check(firstVisibility(1, true) ~= nil, 'the body is shown again')
end)

run('a client without the perspective API still steps out, and says why once', function()
    world(function()
        W.exitPackage()
        W.vehicle(HULL, AV, 0, 0, 1.5)
        W.player(1, 0, 0, 2.5, { noPerspective = true })
    end, { 1 })
    W.seat(1, HULL, 'seat_front_left')
    W.advance(800)
    W.leave(1)
    W.advance(3300)
    check(#W.locomotion.played == 1, 'the clip plays')
    check(W.logged('no Open77.perspective.setThirdPerson on this client', 'client:open77_avdoor:1', 'warn') ~= nil,
        'the missing view is a warning')
end)

run('the server judges the ask: no exit, another hull, too late, seated -- and shows the body every time', function()
    world(function()
        W.exitPackage()
        W.vehicle(HULL, AV, 0, 0, 1.5)
        W.vehicle(HULL + 1, AV, 50, 0, 1.5)
        W.player(1, 0, 0, 2.5)
    end, { 1 })
    local S = server.env.AvDoor.WalkOutServer
    local answer = S.Request(1, { id = HULL_TEXT, clip = 'step', seat = 'seat_front_left' })
    check(answer ~= nil and answer.ok == false and answer.reason == 'no_exit', 'no exit, no clip')
    S.Exited(1, HULL, 'seat_front_left', 'left', AV)
    answer = S.Request(1, { id = tostring(HULL + 1), clip = 'step' })
    check(answer ~= nil and answer.reason == 'wrong_hull', 'the exit of another hull')
    check(firstVisibility(1, true) ~= nil, 'a refusal shows the body')
    S.Exited(1, HULL, 'seat_front_left', 'left', AV)
    -- WINDOW_MS (32 s): longer than the client's own fade ceiling -- the slowest
    -- wait for a third person (VIEW_WAIT_MAX_MS, 12 s), the plan made again
    -- (SETTLE_MS, 3.5 s), two moves, the view drawn again after one, two answers.
    local ceiling = server.env.AvDoor.WalkOutSettings()
    local longest = ceiling.viewWaitMax + ceiling.settle + 2 * 1500 + 6000 + 2 * ceiling.answer + 300
    check(ceiling.window >= longest, 'the window covers the client\'s fade ceiling')
    check(ceiling.hideMax >= longest, 'so does the hide')
    W.advance(31500)
    answer = S.Request(1, { id = HULL_TEXT, clip = 'step' })
    check(answer ~= nil and answer.ok == true, 'an exit is still played 31.5 s on (a slow game waits for its third person)')
    S.Exited(1, HULL, 'seat_front_left', 'left', AV)
    W.advance(32500)
    answer = S.Request(1, { id = HULL_TEXT, clip = 'step' })
    check(answer ~= nil and answer.reason == 'no_exit', 'an exit nobody asked for in time is forgotten')
    S.Exited(1, HULL, 'seat_front_left', 'left', AV)
    W.seat(1, HULL, 'seat_front_left')
    W.advance(100)
    answer = S.Request(1, { id = HULL_TEXT, clip = 'step' })
    check(answer ~= nil and answer.reason == 'seated', 'a body back in a seat')
    check(#W.locomotion.played == 1, 'only the one asked in time was played')
    -- A clip the client names is not the clip it gets: the server derives it.
    W.leave(1, { eject = false })
    W.advance(200)
    answer = S.Request(1, { id = HULL_TEXT, clip = 'exit' })
    check(answer ~= nil and answer.ok == true and answer.clip == 'step', 'the server\'s own clip for the left door')
end)

run('an ask that comes while the seat is still being left waits for the seat, and gives up in time', function()
    -- No client VM: the asks are the test's own, timed against the seat.
    world(function()
        W.exitPackage()
        W.vehicle(HULL, AV, 0, 0, 1.5)
        W.player(1, 0, 0, 2.5)
        W.player(2, 0, 0, 2.5)
    end, {})
    W.seat(1, HULL, 'seat_front_left')
    W.seat(2, HULL, 'seat_front_right')
    W.advance(800)
    check(W.locomotion.assignments[1] ~= nil and W.locomotion.assignments[2] ~= nil, 'both styled in their seats')
    local S = server.env.AvDoor.WalkOutServer
    -- The leaving game confirms its exit 450 ms later: until then the platform
    -- holds the seat, flagged as leaving, and the host plays no clip.
    W.leave(1, { eject = false, confirmMs = 450 })
    W.advance(50)
    check(firstVisibility(1, false) ~= nil, 'hidden from the others as the seat starts to empty')
    local answer = S.Request(1, { id = HULL_TEXT, clip = 'step', seat = 'seat_front_left' })
    check(answer == nil, 'no answer while the seat is held')
    check(W.logged('exit clip for player 1 waits for the seat', 'server:open77_avdoor') ~= nil, 'said in the log')
    check(S.Status().waiting == 1, 'one ask waiting')
    W.advance(300)
    check(#W.locomotion.played == 0, 'nothing played on a body in a vehicle')
    W.advance(300)
    local played = W.locomotion.played[1]
    check(played ~= nil and played.clip == 'step' and played.player == 1, 'played once the seat is free')
    local sent = W.lastTo('open77_avdoor:walking', 1)
    check(sent ~= nil and sent.payload.ok == true and sent.payload.durationMs == 4300, 'and answered with its length')
    check(W.logged('the seat is free after', 'server:open77_avdoor') ~= nil, 'how long it waited is logged')
    check(firstVisibility(1, true) ~= nil, 'shown as the clip starts')
    -- A seat held past PENDING_MS: refused inside the client's own wait.
    W.leave(2, { eject = false, confirmMs = 5000 })
    W.advance(50)
    check(S.Request(2, { id = HULL_TEXT, clip = 'step_m' }) == nil, 'player 2 waits too')
    W.advance(600)
    check(W.lastTo('open77_avdoor:walking', 2) == nil, 'inside PENDING_MS: still waiting')
    W.advance(200)
    local refused = W.lastTo('open77_avdoor:walking', 2)
    check(refused ~= nil and refused.payload.ok == false and refused.payload.reason == 'still_seated',
        'refused as still seated after PENDING_MS')
    check(#W.sent('open77_avdoor:walking', function(e) return e.target == 2 end) == 1, 'answered once')
    check(firstVisibility(2, true) ~= nil, 'and the body shown')
    check(#W.locomotion.played == 1, 'nothing played for player 2')
    check(S.Status().waiting == 0, 'nothing left waiting')
    local settings = server.env.AvDoor.WalkOutSettings()
    check(settings.pending + 300 <= settings.answer, 'the server gives up well inside the client\'s wait')
end)

run('a client quicker than the occupancy event keeps its body visible, and a hide has a ceiling', function()
    world(function()
        W.exitPackage()
        W.vehicle(HULL, AV, 0, 0, 1.5)
        W.player(1, 0, 0, 2.5)
        W.player(2, 40, 0, 0)
    end, { 1, 2 })
    local S = server.env.AvDoor.WalkOutServer
    S.Request(1, { id = HULL_TEXT, clip = false, why = 'no plan' })
    S.Exited(1, HULL, 'seat_front_left', 'left', AV)
    check(firstVisibility(1, false) == nil, 'not hidden: the client already said there is no clip')
    S.Exited(2, HULL, 'seat_front_left', 'left', AV)
    check(firstVisibility(2, false) ~= nil, 'player 2 is hidden for their exit')
    -- HIDE_MAX_MS (29 s) covers the walker's own fade ceiling: the wait for its
    -- third person (VIEW_WAIT_MAX_MS, 12 s), the plan made again, moves, answers.
    W.advance(28900)
    check(firstVisibility(2, true) == nil, 'and still hidden inside the ceiling')
    W.advance(300)
    check(firstVisibility(2, true) ~= nil, 'shown again at the ceiling')
    check(W.logged('player 2 shown to the others again after 29.0s (the ceiling)', 'server:open77_avdoor') ~= nil,
        'and why')
end)

run('stopping the resource mid-clip frees the body and the view and shows it to everybody', function()
    world(function()
        W.exitPackage()
        W.vehicle(HULL, AV, 0, 0, 1.5)
        W.player(1, 0, 0, 2.5)
    end, { 1 })
    W.seat(1, HULL, 'seat_front_left')
    W.advance(800)
    W.leave(1)
    W.advance(2800)
    check(#W.locomotion.played == 1 and W.players[1].frozenPosition == true, 'the clip is playing')
    for _, vm in pairs(W.vms) do if vm.side == 'client' then W.stop(vm) end end
    check(W.players[1].frozenPosition == false, 'the body is free')
    check(#views(W.players[1], function(v) return v.clear == true end) == 1, 'the view is given back')
    W.leave(1)
    W.seat(1, HULL, 'seat_front_left')
    W.leave(1)
    W.advance(100)
    W.stop(server)
    local last = W.visibilityLog[#W.visibilityLog]
    check(last ~= nil and last.visible == true, 'the server shows every body it hid')
end)

-- ── the MaxTac AV's voice and the landing call ───────────────────────────────

--- Flies a seated pilot's hull to a height over `ms` milliseconds.
local function fly(id, toZ, ms)
    local vehicle = W.vehicles[id]
    local fromZ = vehicle.z
    local steps = math.max(1, math.floor(ms / 100))
    for i = 1, steps do
        vehicle.z = fromZ + (toZ - fromZ) * i / steps
        for seat, playerId in pairs(vehicle.seats) do W.players[playerId].z = vehicle.z + 1.0 end
        W.advance(100)
    end
end

run('an exit from a hull flown off its pad uses where the network has it, not the engine\'s dragged frame', function()
    world(function()
        W.vehicle(HULL, AV, 0, 0, 1.5)
        W.player(1, 0, 0, 2.5)
        W.seat(1, HULL, 'seat_front_left')
    end, { 1 })
    W.advance(1000)
    -- The exit un-masks the hull and the engine drags it 37 m back to where
    -- its flight began, for a fifth of a second.
    W.vehicles[HULL].drawnOffset = { x = 37, y = 0, z = 0 }
    W.after(250, function() W.vehicles[HULL].drawnOffset = nil end)
    W.leave(1, { eject = false })
    W.advance(400)
    check(W.logged('37.0 m from where the network has it', 'client:open77_avdoor:1') ~= nil
        and W.logged('using the network\'s', 'client:open77_avdoor:1') ~= nil, 'the network\'s frame is used')
    local target = W.players[1].teleports[1]
    check(target ~= nil and distance2(target, { x = 0, y = 0 }) < 6.6, 'the body is put beside the real hull')
    -- 1.6.0: no fade at the exit -- the body lands where it is put, in view.
    check(#W.players[1].fades == 0 and (W.players[1].screenMoves or 0) == 0, 'and nothing is moved under a fade')
    W.advance(400)
    check(W.grounded(W.players[1]), 'it stands there')
end)

run('Staging, 2026-10-28, 00:52:22: after a 7 m hop the engine drags the hull back 7.2 m -- the exit is planned beside the real one', function()
    world(function()
        W.exitPackage()
        W.vehicle(HULL, AV, 0, 0, 1.5, { halfWidth = 1.84, halfLength = 4.8 })
        W.player(1, 0, 0, 2.5)
        W.player(2, 30, 0, 0)
    end, { 1, 2 })
    local hull = W.vehicles[HULL]
    W.seat(1, HULL, 'seat_back_left')
    W.advance(1000)
    -- THE HOP: the pilot flies it 7.2 m north; its body rides along.
    for _ = 1, 8 do
        hull.y = hull.y + 0.9
        W.players[1].y = W.players[1].y + 0.9
        W.advance(250)
    end
    W.advance(500)
    -- The exit un-masks it: the engine's frame back on the pad, 7.2 m south,
    -- for a fifth of a second -- inside NEAR_METRES, so not "a move made elsewhere".
    hull.drawnOffset = { x = 0, y = -7.2, z = 0 }
    W.after(250, function() hull.drawnOffset = nil end)
    W.leave(1, { eject = false })
    W.advance(300)
    local name = 'client:open77_avdoor:1'
    check(W.logged('7.2 m from where the network has it', name) ~= nil
        and W.logged('using the network\'s', name) ~= nil, 'the dragged frame is seen and the network\'s used')
    local pilot = W.players[1].teleports[1] or { x = 0, y = 0 }
    local doorX, doorY = onHull(hull, -1.45, -0.13)
    local sx, sy = server.env.AvDoor.WalkOutStart(pilot, pilot.heading or 0, 'step')
    check(math.abs(sx - doorX) < 0.05 and math.abs(sy - doorY) < 0.05,
        ('the clip starts on the real hull\'s door: %.2f, %.2f (door %.2f, %.2f)'):format(sx, sy, doorX, doorY))
    W.advance(8000)
    check(W.locomotion.played[1] ~= nil, 'the clip played')
    check(W.logged('aircraft 4294967297 set down on its gear', 'server:open77_avdoor') ~= nil
        and W.logged('measured 7.2 m from where the server has it', 'server:open77_avdoor') == nil,
        'and the ground was measured under the real hull: it is set down on its gear')
end)

run('the engine\'s frame never where the network has the hull: the exit is planned on the network\'s', function()
    world(function()
        W.exitPackage()
        W.vehicle(HULL, AV, 0, 8.0, 1.5, { halfWidth = 1.84, halfLength = 4.8 })
        W.player(1, 0, 8.0, 2.5)
    end, { 1 })
    local hull = W.vehicles[HULL]
    -- This game draws it on its old pad the whole time (nothing kept aboard).
    hull.drawnOffset = { x = 0, y = -7.2, z = 0 }
    W.seat(1, HULL, 'seat_back_left')
    W.advance(1200)
    W.leave(1, { eject = false })
    W.advance(300)
    local name = 'client:open77_avdoor:1'
    check(W.logged('using the network\'s', name) ~= nil, 'the network\'s frame is used')
    local pilot = W.players[1].teleports[1] or { x = 0, y = 0 }
    local doorX, doorY = onHull(hull, -1.45, -0.13)
    local sx, sy = server.env.AvDoor.WalkOutStart(pilot, pilot.heading or 0, 'step')
    check(math.abs(sx - doorX) < 0.05 and math.abs(sy - doorY) < 0.05,
        ('the clip starts on the network\'s hull\'s door: %.2f, %.2f (door %.2f, %.2f)'):format(sx, sy, doorX, doorY))
    -- An engine frame that agrees with the network (AGREE_METRES, 0.5 m) is the
    -- engine's; a metre off is not -- 1.3.1 let 3 m through, and a hop of 2.5 m
    -- from the back seat put the clip's first step on nothing (Staging,
    -- 2026-10-28, 01:10:52).
    world(function()
        W.exitPackage()
        W.vehicle(HULL, AV, 0, 0, 1.5)
        W.player(1, 0, 0, 2.5)
    end, { 1 })
    W.vehicles[HULL].drawnOffset = { x = 0.3, y = 0, z = 0 }
    W.seat(1, HULL, 'seat_back_left')
    W.advance(1200)
    W.leave(1, { eject = false })
    W.advance(300)
    check(W.logged('(the engine\'s frame, 0.3 m from where the network has it)', 'client:open77_avdoor:1') ~= nil,
        '0.3 m off is the engine\'s own, said in the log')
    world(function()
        W.exitPackage()
        W.vehicle(HULL, AV, 0, 0, 1.5)
        W.player(1, 0, 0, 2.5)
    end, { 1 })
    W.vehicles[HULL].drawnOffset = { x = 1.0, y = 0, z = 0 }
    W.seat(1, HULL, 'seat_back_left')
    W.advance(1200)
    W.leave(1, { eject = false })
    W.advance(300)
    check(W.logged('1.0 m from where the network has it', 'client:open77_avdoor:1') ~= nil
        and W.logged('using the network\'s', 'client:open77_avdoor:1') ~= nil, 'a metre off is not: the network\'s')
    -- Turned more than AGREE_DEGREES from the network's heading: not the hull either.
    world(function()
        W.exitPackage()
        W.vehicle(HULL, AV, 0, 0, 1.5)
        W.player(1, 0, 0, 2.5)
    end, { 1 })
    W.seat(1, HULL, 'seat_back_left')
    W.advance(1200)
    local vm = nil
    for _, each in pairs(W.vms) do if each.playerId == 1 then vm = each end end
    local geometry = vm.env.Open77.world.entityGeometry
    vm.env.Open77.world.entityGeometry = function(ref)
        local answer, why = geometry(ref)
        if type(answer) == 'table' and answer.entity ~= 0 then
            -- 30 degrees off: (-sin 30, cos 30).
            answer.forward = { x = -0.5, y = 0.8660254, z = 0 }
        end
        return answer, why
    end
    W.leave(1, { eject = false })
    W.advance(300)
    check(W.logged('turned 30 deg from it', 'client:open77_avdoor:1') ~= nil
        and W.logged('using the network\'s', 'client:open77_avdoor:1') ~= nil, 'a frame turned 30 deg: the network\'s')
end)

--- The client VM of a player.
local function clientOf(playerId)
    for _, vm in pairs(W.vms) do if vm.playerId == playerId then return vm end end
    return nil
end

--- Where a clip played from a body standing at `at`, facing `heading`, starts.
local function clipStart(at, heading)
    return server.env.AvDoor.WalkOutStart(at, heading or 0, 'step')
end

run('Staging, 2026-10-28, 01:10:52: a 2.5 m hop from the back seat, dragged back 2.5 m at the exit -- the step starts on the real door', function()
    world(function()
        W.exitPackage()
        -- On its gear already (set down at the exit before): its origin 1.0 m up.
        W.vehicle(HULL, AV, 0, 0, 1.0, { halfWidth = 1.84, halfLength = 4.8 })
        W.player(1, 0, 0, 2.0)
        W.player(2, 30, 0, 0)
    end, { 1, 2 })
    local hull = W.vehicles[HULL]
    W.seat(1, HULL, 'seat_back_left')
    W.advance(1000)
    -- THE HOP: flown from the back seat, 2.5 m west -- toward its own left.
    for _ = 1, 5 do
        hull.x = hull.x - 0.5
        W.players[1].x = W.players[1].x - 0.5
        W.advance(250)
    end
    W.advance(500)
    -- The exit un-masks it: this game's engine draws it back where the hop
    -- began, 2.5 m east, for a fifth of a second -- under 1.3.1's 3 m.
    hull.drawnOffset = { x = 2.5, y = 0, z = 0 }
    W.after(250, function() hull.drawnOffset = nil end)
    local leftAt = W.now
    W.leave(1, { eject = false })
    W.advance(300)
    local name = 'client:open77_avdoor:1'
    check(W.logged('2.5 m from where the network has it', name) ~= nil and W.logged('using the network\'s', name) ~= nil,
        'the 2.5 m drag is seen, and not taken for the hull')
    local doorX, doorY = onHull(hull, -1.45, -0.13)
    local body = W.players[1].teleports[1] or { x = 0, y = 0 }
    local sx, sy = clipStart(body, body.heading)
    check(math.abs(sx - doorX) < 0.05 and math.abs(sy - doorY) < 0.05,
        ('the clip starts on the real door: %.2f, %.2f (door %.2f, %.2f)'):format(sx, sy, doorX, doorY))
    W.advance(8000)
    local played = W.locomotion.played[1]
    check(played ~= nil and played.clip == 'step', 'the clip played')
    local px, py = clipStart(played or { x = 0, y = 0 }, W.players[1].yaw)
    check(played ~= nil and math.abs(px - doorX) < 0.05 and math.abs(py - doorY) < 0.05,
        ('from the real door, for everybody: %.2f, %.2f'):format(px, py))
    check(W.logged('measured 2.', 'server:open77_avdoor') == nil
        and W.logged('aircraft 4294967297 already stands on its gear', 'server:open77_avdoor') ~= nil,
        'the ground was measured under the real hull, which already stands on its gear')
    check(W.logged('exit clip for player 1: the plan holds', 'server:open77_avdoor') ~= nil, 'the server held the plan')
    check(W.logged('planned again', name) == nil, 'and nothing had to be planned again')
    check(played ~= nil and played.at - leftAt < 4000, ('without a wait: %d ms after the exit'):format(played and played.at - leftAt or -1))
end)

run('a hull this game has no engine entity for is never read through entity 0, which is the player\'s own body', function()
    world(function()
        W.exitPackage()
        W.vehicle(HULL, AV, 0, 0, 1.0, { halfWidth = 1.84, halfLength = 4.8 })
        W.player(1, 0, 0, 2.0)
    end, { 1 })
    local hull = W.vehicles[HULL]
    W.seat(1, HULL, 'seat_back_left')
    W.advance(1000)
    -- At the exit this game has no engine entity for the hull: its snapshot's
    -- `entity` is 0, and a `vehicle` read of it is refused.
    hull.entityZeroFor = { [1] = true }
    W.after(400, function() hull.entityZeroFor = nil end)
    W.leave(1, { eject = false })
    W.advance(300)
    check(W.selfGeometryAsks == 0, 'the engine is never asked about entity 0 (it answers the body itself)')
    local doorX, doorY = onHull(hull, -1.45, -0.13)
    local body = W.players[1].teleports[1] or { x = 0, y = 0 }
    local sx, sy = clipStart(body, body.heading)
    check(math.abs(sx - doorX) < 0.05 and math.abs(sy - doorY) < 0.05,
        ('planned on where the network has the hull: the clip starts on its door (%.2f, %.2f)'):format(sx, sy))
    W.advance(8000)
    check(W.locomotion.played[1] ~= nil, 'and the clip played')
    -- The guards themselves.
    local core = server.env.AvDoor
    check(core.EntityRef(0) == nil and core.EntityRef(-3) == nil and core.EntityRef(1.5) == nil
        and core.EntityRef('0') == nil and core.EntityRef(nil) == nil, 'an entity of 0 (or no whole number) is not passed')
    check(core.EntityRef(51539607562) == 51539607562 and core.EntityRef('veh:1') == 'veh:1', 'a real one is')
    check(core.EntityAnswer({ attached = true, entity = 0 }) == false and core.EntityAnswer({ attached = false }) == false
        and core.EntityAnswer({ attached = true, entity = 51539607562 }) == true and core.EntityAnswer({ attached = true }) == true,
        'an answer for entity 0 is never a hull\'s')
end)

run('the plan made again before the ask: the hull read off its place at the exit, the body moved to the real end point', function()
    world(function()
        W.exitPackage()
        W.vehicle(HULL, AV, 0, 0, 1.0, { halfWidth = 1.84, halfLength = 4.8 })
        W.player(1, 0, 0, 2.0)
        W.player(2, 30, 0, 0)
    end, { 1, 2 })
    local hull = W.vehicles[HULL]
    W.seat(1, HULL, 'seat_back_left')
    W.advance(1000)
    -- At the exit the engine AND this game's own newest sample have the hull
    -- 2.5 m east (a sample taken during the drag): nothing here can tell.
    hull.drawnOffset = { x = 2.5, y = 0, z = 0 }
    hull.netOffsetFor = { [1] = { x = 2.5, y = 0, z = 0 } }
    W.after(300, function() hull.drawnOffset, hull.netOffsetFor = nil, nil end)
    W.leave(1, { eject = false })
    W.advance(300)
    local name = 'client:open77_avdoor:1'
    local doorX, doorY = onHull(hull, -1.45, -0.13)
    local first = W.players[1].teleports[1] or { x = 0, y = 0 }
    local fx = clipStart(first, first.heading)
    check(math.abs(fx - (doorX + 2.5)) < 0.05, ('the exit\'s own plan is on the frame it read: %.2f'):format(fx))
    W.advance(8000)
    -- EARLY: once the hull's frame is steady, before the client's exit camera comes.
    local again = W.logged('exit clip step planned again 0.', name)
    check(again ~= nil and again:find('the end point moves 2.50 m', 1, true) ~= nil,
        'planned again on the hull as it stands, 2.5 m off, under a second after the exit')
    local moved = nil
    for _, t in ipairs(W.players[1].teleports) do if t.at - (W.players[1].teleports[1] or t).at > 0 then moved = moved or t end end
    local legacy = firstOf(W.players[1].cameraLog, function(e) return e.legacy and e.on end)
    check(moved ~= nil and legacy ~= nil and moved.at < legacy.at,
        'the body moved before the client\'s exit camera came (nothing can take the move for a walk)')
    check(W.logged('the body stands at the new end point', name) ~= nil, 'the body moved there before the ask')
    check(W.logged('the view left third person', name) == nil, 'and the view never left third person')
    local played = W.locomotion.played[1]
    local teleports = W.players[1].teleports
    local last = teleports[#teleports] or { x = 0, y = 0 }
    local sx, sy = clipStart(last, last.heading)
    check(math.abs(sx - doorX) < 0.05 and math.abs(sy - doorY) < 0.05,
        ('the clip starts on the real door: %.2f, %.2f (door %.2f, %.2f)'):format(sx, sy, doorX, doorY))
    check(played ~= nil and distance2(played, last) < 0.05, 'played where the body was moved to')
    check(W.logged('exit clip for player 1: the plan holds', 'server:open77_avdoor') ~= nil
        and W.logged('the client is sent the server\'s hull', 'server:open77_avdoor') == nil, 'and the server held it')
    local back = lastFadeIn(W.players[1])
    check(back ~= nil and played ~= nil and back.at >= played.at, 'all of it under the fade')
end)

run('four frames a second: the plan made again, the body moved, the server\'s pose sent -- inside the fade\'s ceiling', function()
    world(function()
        W.exitPackage()
        W.vehicle(HULL, AV, 0, 0, 1.5, { halfWidth = 1.84, halfLength = 4.8 })
        W.player(1, 0, 0, 2.5, { frameMs = 250 })
        W.player(2, 30, 0, 0)
    end, { 1, 2 })
    local hull = W.vehicles[HULL]
    W.seat(1, HULL, 'seat_back_left')
    W.advance(1500)
    -- Dragged at the exit (engine and sample) for the exit's first frames --
    -- the plan is made a frame or two in (1.5.1: each step a resume of its own)
    -- -- and afterwards this game draws the hull 1.0 m east for good, which only
    -- the server can tell it.
    hull.drawnOffset = { x = 2.5, y = 0, z = 0 }
    hull.netOffsetFor = { [1] = { x = 2.5, y = 0, z = 0 } }
    W.after(1100, function()
        hull.drawnOffset = { x = 1.0, y = 0, z = 0 }
        hull.netOffsetFor = { [1] = { x = 1.0, y = 0, z = 0 } }
    end)
    local leftAt = W.now
    W.leave(1, { eject = false, confirmMs = 500 })
    local played = nil
    for _ = 1, 220 do
        W.advance(100)
        played = played or W.locomotion.played[1]
    end
    local name = 'client:open77_avdoor:1'
    check(W.logged('after the exit, on the hull as it stands now', name) ~= nil, 'planned again early on the hull as it stands')
    -- The server's pose moves the body once third person is drawn: the
    -- client's "first move" rule throws the view, and the clip waits for it.
    check(W.logged('the view left third person when the body was moved', name) ~= nil
        and W.logged('third person is back after the move', name) ~= nil, 'the view thrown by the move is waited for')
    check(W.logged('the camera\'s swing round the body was lost with third person', name) ~= nil
        and W.count('exit view: the camera swung 160 deg round the body', name) == 2, 'and the camera swung again')
    check(W.logged('the client is sent the server\'s hull', 'server:open77_avdoor') ~= nil
        and W.logged('exit clip step: the server has the hull at 0.0, 0.0, 1.0 heading 0', name) ~= nil,
        'then on the server\'s pose (set down on its gear meanwhile)')
    local teleports = W.players[1].teleports
    local last = teleports[#teleports] or { x = 0, y = 0 }
    local doorX, doorY = onHull(hull, -1.45, -0.13)
    local sx, sy = clipStart(last, last.heading)
    check(played ~= nil and math.abs(sx - doorX) < 0.05 and math.abs(sy - doorY) < 0.05,
        ('the clip from the real door at four frames a second: %.2f, %.2f (door %.2f, %.2f)'):format(sx, sy, doorX, doorY))
    local back = lastFadeIn(W.players[1])
    check(back ~= nil and played ~= nil and back.at >= played.at and W.logged('(the ceiling)', name) == nil,
        'the image back on the clip, not at the fade\'s ceiling')
    check(played ~= nil and played.at - leftAt < 16000, ('%d ms after the exit'):format(played and played.at - leftAt or -1))
    check(firstVisibility(1, true) ~= nil and played ~= nil and math.abs(firstVisibility(1, true).at - played.at) <= 10,
        'the others see the body as the clip starts')
end)

run('a game whose hull stays off its place: the server sends its own, and the clip is planned on that', function()
    world(function()
        W.exitPackage()
        W.vehicle(HULL, AV, 0, 0, 1.0, { halfWidth = 1.84, halfLength = 4.8 })
        W.player(1, 0, 0, 2.0)
        W.player(2, 30, 0, 0)
    end, { 1, 2 })
    local hull = W.vehicles[HULL]
    -- This game draws the hull 1.2 m east the whole time, and its snapshot says the same.
    hull.drawnOffset = { x = 1.2, y = 0, z = 0 }
    hull.netOffsetFor = { [1] = { x = 1.2, y = 0, z = 0 } }
    W.seat(1, HULL, 'seat_back_left')
    W.advance(1000)
    W.leave(1, { eject = false })
    W.advance(9000)
    local name = 'client:open77_avdoor:1'
    check(W.logged('its end point is 1.20 m from where the server\'s hull puts it', 'server:open77_avdoor') ~= nil
        and W.logged('the client is sent the server\'s hull (0.0, 0.0, 1.0, heading 0)', 'server:open77_avdoor') ~= nil,
        'the server sends its own hull')
    check(W.logged('exit clip step: the server has the hull at 0.0, 0.0, 1.0 heading 0', name) ~= nil, 'the client plans on it')
    local asks = W.sent('open77_avdoor:walkout', function(e) return e.payload.clip == 'step' end)
    check(#asks == 2, 'and asks again: ' .. #asks)
    local played = W.locomotion.played[1]
    local teleports = W.players[1].teleports
    local last = teleports[#teleports] or { x = 0, y = 0 }
    local doorX, doorY = onHull(hull, -1.45, -0.13)
    local sx, sy = clipStart(last, last.heading)
    check(played ~= nil and math.abs(sx - doorX) < 0.05 and math.abs(sy - doorY) < 0.05,
        ('the clip plays from the server\'s door: %.2f, %.2f (door %.2f, %.2f)'):format(sx, sy, doorX, doorY))
    check(#W.locomotion.played == 1 and firstVisibility(1, true) ~= nil, 'once, the body shown as it starts')
end)

run('a hull still over its gear when the clip is due: measured again, set down, and the clip waits for it', function()
    -- A: the exit's measure made on a dragged frame -- made again with the early
    -- plan, so the hull is down before the ask.
    world(function()
        W.exitPackage()
        -- Where the flight leaves an Excalibur: 0.5 m over its gear, its step 1.12 m up.
        W.vehicle(HULL, AV, 0, 0, 1.5, { halfWidth = 1.84, halfLength = 4.8 })
        W.player(1, 0, 0, 2.5)
        W.player(2, 30, 0, 0)
    end, { 1, 2 })
    local hull = W.vehicles[HULL]
    W.seat(1, HULL, 'seat_back_left')
    W.advance(1000)
    hull.drawnOffset = { x = 2.5, y = 0, z = 0 }
    hull.netOffsetFor = { [1] = { x = 2.5, y = 0, z = 0 } }
    W.after(300, function() hull.drawnOffset, hull.netOffsetFor = nil, nil end)
    local leftAt = W.now
    W.leave(1, { eject = false })
    W.advance(10000)
    local name = 'client:open77_avdoor:1'
    local lands = W.sent('open77_avdoor:land')
    check(#lands == 2 and math.abs(lands[1].payload.x - 2.5) < 1e-6 and math.abs(lands[2].payload.x) < 1e-6,
        'measured at the exit on the dragged frame, and again on the hull as it stands')
    local lowered = W.logged('aircraft 4294967297 set down on its gear 0.50 m lower', 'server:open77_avdoor')
    check(lowered ~= nil and lowered:find('measured 0.00 m from the server\'s hull', 1, true) ~= nil,
        'set down on the measure made under the hull itself')
    local setDown = hull.transforms[1]
    check(setDown ~= nil and setDown.at - leftAt <= 1300, ('at the land delay: %d ms after the exit'):format(setDown and setDown.at - leftAt or -1))
    check(W.logged('waits for the hull to stand on its gear', name) == nil, 'down before the ask: no wait for it')
    local played = W.locomotion.played[1]
    local teleports = W.players[1].teleports
    local last = teleports[#teleports] or { x = 0, y = 0 }
    local doorX, doorY = onHull(hull, -1.45, -0.13)
    local sx, sy = clipStart(last, last.heading)
    check(played ~= nil and math.abs(sx - doorX) < 0.05 and math.abs(sy - doorY) < 0.05, 'the clip from the real door')
    -- B: the exit's measure never reaches the server: the hull still hangs over
    -- its gear when the clip is due -- measured again, and waited for.
    world(function()
        W.exitPackage()
        W.vehicle(HULL, AV, 0, 0, 1.5, { halfWidth = 1.84, halfLength = 4.8 })
        W.player(1, 0, 0, 2.5)
        W.player(2, 30, 0, 0)
    end, { 1, 2 })
    hull = W.vehicles[HULL]
    local vm = clientOf(1)
    local send = vm.env.TriggerServerEvent
    local dropped = 0
    vm.env.TriggerServerEvent = function(event, ...)
        if event == 'open77_avdoor:land' and dropped == 0 then
            dropped = 1
            return
        end
        return send(event, ...)
    end
    W.seat(1, HULL, 'seat_front_left')
    W.advance(1000)
    W.leave(1, { eject = false })
    W.advance(10000)
    check(dropped == 1, 'the exit\'s measure was lost')
    check(W.logged('exit clip step waits for the hull to stand on its gear: the door\'s step is 1.12 m over the end point',
        name) ~= nil, 'the clip waits for the hull: its step 1.12 m up')
    check(W.logged('(measured again before the clip): it hovers 0.50 m over its gear', name) ~= nil, 'measured again')
    check(W.logged('aircraft 4294967297 set down on its gear 0.50 m lower', 'server:open77_avdoor') ~= nil, 'set down')
    check(W.logged('exit clip step: the hull stands on its gear now (the step 0.62 m up)', name) ~= nil, 'then on its gear')
    played = W.locomotion.played[1]
    setDown = hull.transforms[1]
    check(played ~= nil and setDown ~= nil and played.at >= setDown.at,
        ('the clip after the set-down: %d ms after it'):format((played and setDown) and played.at - setDown.at or -1))
    check(math.abs(hull.z - 1.0) < 1e-6, 'the hull on its gear')
end)

run('a step that never comes within reach plays no clip: the body is shown standing, not stepping out of the air', function()
    world(function()
        W.exitPackage()
        -- A kerb under the nose gear: not one floor, so the hull is never set down.
        W.groundAt = function(x, y) return y > 1.5 and 0.5 or 0.0 end
        W.vehicle(HULL, AV, 0, 0, 1.5, { halfWidth = 1.84, halfLength = 4.8 })
        W.player(1, 0, 0, 2.5)
        W.player(2, 30, 0, 0)
    end, { 1, 2 })
    local player = W.players[1]
    W.seat(1, HULL, 'seat_front_left')
    W.advance(1000)
    local leftAt = W.now
    W.leave(1, { eject = false })
    W.advance(12000)
    local name = 'client:open77_avdoor:1'
    check(W.locomotion.played[1] == nil, 'no clip')
    check(W.logged('exit clip step: no clip -- the door\'s step is 1.12 m over the end point here', name) ~= nil
        and W.logged('it would start in the air beside the door', name) ~= nil, 'the client says why')
    check(W.logged('aircraft 4294967297 stays where the flight left it: uneven:0.50', 'server:open77_avdoor') ~= nil,
        'the server could not set it down')
    check(W.logged('player 1 steps out without a clip', 'server:open77_avdoor') ~= nil and firstVisibility(1, true) ~= nil,
        'the body is shown to the others')
    local back = lastFadeIn(player)
    check(back ~= nil and back.at - leftAt < 9000, ('the image back on the body standing: %d ms'):format(back and back.at - leftAt or -1))
    check(player.frozenPosition ~= true, 'free to walk')
    W.groundAt = nil
end)

run('a hull on its gear over ground that falls away under the end point: no clip, and no wait for a set-down that cannot come', function()
    world(function()
        W.exitPackage()
        -- The pad ends 2.5 m west of the hull: the end point (3.9 m out) is 0.4 m lower.
        W.groundAt = function(x) return x < -2.5 and -0.4 or 0.0 end
        W.vehicle(HULL, AV, 0, 0, 1.0, { halfWidth = 1.84, halfLength = 4.8 })
        W.player(1, 0, 0, 2.0)
    end, { 1 })
    W.seat(1, HULL, 'seat_front_left')
    W.advance(1000)
    local leftAt = W.now
    W.leave(1, { eject = false })
    W.advance(9000)
    local name = 'client:open77_avdoor:1'
    check(W.locomotion.played[1] == nil, 'no clip')
    check(W.logged('the door\'s step is 1.02 m over the end point here', name) ~= nil
        and W.logged('(the hull stands on its gear: the ground falls away under the end point)', name) ~= nil,
        'the client says why')
    check(W.logged('waits for the hull to stand on its gear', name) == nil, 'and does not wait for it')
    local back = lastFadeIn(W.players[1])
    check(back ~= nil and back.at - leftAt < 4000, ('the image back as soon as the view is: %d ms'):format(back and back.at - leftAt or -1))
    W.groundAt = nil
end)

run('this screen draws the set-down after the network has it: the clip waits for the hull here', function()
    world(function()
        W.exitPackage()
        W.vehicle(HULL, AV, 0, 0, 1.5, { halfWidth = 1.84, halfLength = 4.8 })
        W.player(1, 0, 0, 2.5)
        W.player(2, 30, 0, 0)
    end, { 1, 2 })
    local hull = W.vehicles[HULL]
    -- The engine here takes 1.5 s to draw the server's set-down.
    local setTransform = server.env.Open77.vehicles.setTransform
    server.env.Open77.vehicles.setTransform = function(id, transform)
        local was = hull.z
        local ok, why = setTransform(id, transform)
        hull.drawnOffset = { x = 0, y = 0, z = was - hull.z }
        W.after(1500, function() hull.drawnOffset = nil end)
        return ok, why
    end
    W.seat(1, HULL, 'seat_front_left')
    W.advance(1000)
    W.leave(1, { eject = false })
    W.advance(9000)
    local name = 'client:open77_avdoor:1'
    check(W.logged('exit clip step waits for the hull to stand on its gear: the door\'s step is 1.12 m over the end point '
        .. 'here (0.62 m where the network has the hull)', name) ~= nil, 'waits: high here, down on the network')
    local played = W.locomotion.played[1]
    local setDown = hull.transforms[1]
    check(played ~= nil and setDown ~= nil and played.at >= setDown.at + 1500,
        ('played once this screen drew it down: %d ms after the set-down'):format((played and setDown) and played.at - setDown.at or -1))
    check(W.count('set down on its gear', 'server:open77_avdoor') == 1, 'set down once, whatever was measured again')
end)

run('the server holds a clip ask against its own hull: the end point, the door\'s step, the body', function()
    world(function()
        W.exitPackage()
        W.vehicle(HULL, AV, 0, 0, 1.0)
        W.player(1, 0, 0, 0)
    end, {})
    local S = server.env.AvDoor.WalkOutServer
    local core = server.env.AvDoor
    local exit = { id = HULL, seat = 'seat_front_left', record = AV, clip = 'step' }
    local own = core.WalkOutPlan({ x = 0, y = 0 }, { x = 0, y = 1 }, 'seat_front_left', core.ExitSettings(), 'step', 1.45,
        core.SeatDoor(AV, 'seat_front_left'))
    W.players[1].x, W.players[1].y, W.players[1].z = own.x, own.y, 0.03
    local plan = { at = { x = own.x, y = own.y, z = 0.03 }, ground = 0.0, hull = { x = 0, y = 0, z = 1.0, yaw = 0 } }
    local verdict, found = S.CheckPlan(1, exit, { plan = plan })
    check(verdict == 'ok' and found:find('the step 0.62 m up', 1, true) ~= nil, 'a plan on the server\'s hull holds: ' .. tostring(found))
    check(S.CheckPlan(1, exit, {}) == 'ok', 'an older client\'s ask (no plan) plays as before')
    local pose
    verdict, found, pose = S.CheckPlan(1, exit, { plan = { at = { x = own.x + 2.5, y = own.y }, ground = 0.0,
        hull = { x = 2.5, y = 0, z = 1.0, yaw = 0 } } })
    check(verdict == 'replan' and pose ~= nil and pose.x == 0 and pose.z == 1.0 and pose.yaw == 0,
        'an end point 2.5 m off: plan again on the server\'s hull')
    check(found ~= nil and found:find('2.50 m from where the server\'s hull puts it', 1, true) ~= nil
        and found:find('the hull it planned on 2.5 m from the server\'s', 1, true) ~= nil, tostring(found))
    -- The hull hanging 0.5 m over its gear, nothing to set it down: no clip.
    W.vehicles[HULL].z = 1.5
    verdict, found = S.CheckPlan(1, exit, { plan = plan })
    check(verdict == 'refuse' and found == 'step_out_of_reach:1.12', 'a step 1.12 m up is out of reach: ' .. tostring(found))
    -- ... unless it is still to be set down: that is waited for.
    core.Land.Exited(HULL, AV, 1)
    local after
    verdict, found, _, after = S.CheckPlan(1, exit, { plan = plan })
    check(verdict == 'wait' and after == 'step_out_of_reach:1.12', 'waited for while it may still be set down')
    W.vehicles[HULL].z = 1.0
    -- The body, as the server has it, away from the end point: waited for.
    W.players[1].x = own.x - 3.0
    verdict, found, _, after = S.CheckPlan(1, exit, { plan = plan })
    check(verdict == 'wait' and found:find('3.0 m from the clip\'s end point', 1, true) ~= nil
        and after == 'not_at_the_door:3.0', 'a body away from the end point is waited for: ' .. tostring(found))
    -- A whole ask: the second "elsewhere" is a refusal, and the body is shown.
    W.players[1].x = own.x
    S.Exited(1, HULL, 'seat_front_left', 'left', AV)
    local bad = { id = HULL_TEXT, clip = 'step', plan = { at = { x = own.x + 2.5, y = own.y }, ground = 0.0 } }
    local answer = S.Request(1, bad)
    check(answer ~= nil and answer.ok == false and answer.replan == true and type(answer.hull) == 'table',
        'the first: plan again, the server\'s hull sent')
    check(firstVisibility(1, true) == nil, 'the body still hidden')
    W.advance(300)
    answer = S.Request(1, bad)
    check(answer ~= nil and answer.ok == false and answer.reason == 'hull_elsewhere' and answer.replan ~= true,
        'the second: refused')
    check(firstVisibility(1, true) ~= nil and #W.locomotion.played == 0, 'shown, nothing played')
end)

run('a client that starts after the server has spoken says hello and is told again', function()
    world(function()
        W.vehicle(HULL, AV, 0, 0, 1.5)
        W.vehicle(HULL + 1, TRAUMA, 20, 0, 3)
        W.player(1, 4, 0, 0)
    end, {})
    server.exports.pad(HULL + 1, {})
    server.exports.callout(HULL + 1, nil, 'a run')
    W.advance(1200)
    check(door(1) ~= nil and door(1).open == true, 'the door was sent to a game with no handler yet')
    local vm = W.client(1, 'open77_avdoor', ROOT, CLIENT)
    W.advance(1500)
    check(#W.sent('open77_avdoor:hello') == 1, 'the client says hello')
    check(#W.cards(1) == 1, 'the card is up')
    local audio = 0
    for _ in pairs(W.players[1].audio) do audio = audio + 1 end
    check(audio == 1, 'the landing call is heard')
    -- The client resource restarts: the card again, once.
    W.stop(vm)
    W.players[1].cards = {}
    W.client(1, 'open77_avdoor', ROOT, CLIENT)
    W.advance(1500)
    check(#W.cards(1) == 1, 'the card is up again after a restart')
end)

-- ── the exit scene: every screen in step (server/sync.lua, client/sync.lua) ──

local SRV = 'server:open77_avdoor'

local function fromPlayer(name, playerId, filter)
    return W.sent(name, function(e)
        return e.dir == 'toServer' and e.from == playerId and (filter == nil or filter(e.payload))
    end)
end

local function toPlayer(name, playerId, filter)
    return W.sent(name, function(e)
        return e.dir == 'toClient' and e.target == playerId and (filter == nil or filter(e.payload))
    end)
end

local function reportOf(playerId, phase)
    local list = fromPlayer('open77_avdoor:sceneReport', playerId, function(p) return p.phase == phase end)
    return list[1] and list[1].payload or nil
end

--- An Excalibur on its gear with player 1 in its pilot's seat, and the others
--- the case lists: `{ id, x, y, options, client = false }`.
local function excaliburScene(others, setup)
    local clients = { 1 }
    world(function()
        W.exitPackage()
        -- On its gear already: nothing is set down during the exit.
        W.vehicle(HULL, AV, 0, 0, 1.0, { halfWidth = 1.84, halfLength = 4.8 })
        W.player(1, 0, 0, 2.0)
        for _, other in ipairs(others) do
            W.player(other.id, other.x, other.y, 0, other.options)
            if other.client ~= false then clients[#clients + 1] = other.id end
        end
        if setup ~= nil then setup() end
    end, clients)
    W.seat(1, HULL, 'seat_front_left')
    W.advance(1000)
    return W.vehicles[HULL]
end

run('the laptop, 2026-10-28: the other game\'s dismount holds the body 2.8 s -- the step waits for it, and every screen reports', function()
    excaliburScene({ { id = 2, x = -8, y = 0, options = { dismountMs = 2811 } } })
    local leftAt = W.now
    W.leave(1, { eject = false })
    W.advance(9000)
    check(W.logged('exit 1 of player 1 (seat_front_left of 4294967297): 1 other screen(s) draw it: player 2 (', SRV) ~= nil,
        'the server tells the exit to the screen near it')
    local told = toPlayer('open77_avdoor:scene', 2, function(p) return p.phase == 'exit' end)
    check(#told == 1 and told[1].payload.player == 1 and told[1].payload.id == HULL_TEXT and told[1].at - leftAt <= 50,
        'player 2\'s game is told of the exit as the seat empties')
    check(#toPlayer('open77_avdoor:scene', 1) == 0, 'the exiting game is never told of its own exit')
    check(W.logged('exit 1 of player 1: the body is in its seat here; the step waits for it', 'client:open77_avdoor:2') ~= nil,
        'player 2\'s game watches the body held in its seat by its own dismount')
    local ready = fromPlayer('open77_avdoor:sceneReady', 2)
    local released = leftAt + 100 + 2811
    check(#ready == 1 and ready[1].payload.free == true and ready[1].payload.seen == true and ready[1].payload.scene == 1,
        'and says once that the body is out of its seat')
    check(ready[1] ~= nil and ready[1].at >= released and ready[1].at - released <= 300,
        ('as soon as its dismount lets go: %d ms after it'):format(ready[1] and ready[1].at - released or -1))
    local played = W.locomotion.played[1]
    check(played ~= nil and ready[1] ~= nil and played.at >= ready[1].at,
        'the step starts only once the other screen has the body out of its seat')
    check(played ~= nil and played.at - released <= 400,
        ('and at once after: %d ms after the other game let go'):format(played and played.at - released or -1))
    check(W.logged('exit clip for player 1 is held for the other screens', SRV) ~= nil
        and W.logged('exit clip for player 1: held ', SRV) ~= nil, 'the server says it held the step, and for how long')
    check(W.logged('the server holds the step up to', 'client:open77_avdoor:1') ~= nil
        and W.logged('ms for the other screens (exit 1)', 'client:open77_avdoor:1') ~= nil, 'and the exiting game says so too')
    check(W.logged('no answer from the server', 'client:open77_avdoor:1') == nil, 'the hold is not taken for silence')
    local back = lastFadeIn(W.players[1])
    check(back ~= nil and played ~= nil and back.at >= played.at, 'the exiting screen comes back on the first step, after the hold')
    local shown = firstVisibility(1, true)
    check(shown ~= nil and played ~= nil and math.abs(shown.at - played.at) <= 10, 'the others see the body as the step starts')
    -- THE LOGGER: two reports from each screen, and a verdict.
    local start2, end2 = reportOf(2, 'start'), reportOf(2, 'end')
    check(start2 ~= nil and start2.seen == true and start2.mounted == false and start2.workspot == false
        and (start2.off or 9) < 0.1 and (start2.hullOff or 9) < 0.05,
        'player 2 draws the body out of its seat at the end point, and the AV where the server has it')
    check(end2 ~= nil and (end2.off or 9) < 0.1, 'and still at the end point as the step ends')
    local start1, end1 = reportOf(1, 'start'), reportOf(1, 'end')
    check(start1 ~= nil and start1.view == 'tps' and start1.body == 'proxy' and start1.orbit == true
        and (start1.off or 9) < 0.1, 'the exiting screen shows its step in third person, on the stand-in, from in front')
    check(end1 ~= nil and end1.view == 'tps', 'to the end')
    check(W.logged('exit 1 of player 1, player 2\'s screen as the step began: player 1 out of the seat', SRV) ~= nil,
        'every report is a line in the server log')
    check(W.logged('exit 1 of player 1: verdict -- the step played', SRV, 'info') ~= nil
        and W.logged('4 of 4 report(s) (every screen reported): nothing wrong', SRV) ~= nil,
        'and the exit ends with its verdict: nothing wrong')
    check(W.logged('WRONG', SRV) == nil and W.logged('WRONG') == nil, 'nothing was wrong anywhere')
end)

run('a dismount longer than the wait for an answer: the hold stretches it, and the step still plays', function()
    excaliburScene({ { id = 2, x = -8, y = 0, options = { dismountMs = 4000 } } })
    local leftAt = W.now
    W.leave(1, { eject = false })
    W.advance(10000)
    local played = W.locomotion.played[1]
    check(played ~= nil and played.at - leftAt >= 4100 and played.at - leftAt <= 4600,
        ('the step waits for the other game\'s 4 s dismount: %d ms after the exit'):format(played and played.at - leftAt or -1))
    local hold = toPlayer('open77_avdoor:walking', 1, function(p) return p.hold == true end)
    check(#hold == 1 and hold[1].payload.ok == false and (hold[1].payload.waitMs or 0) > 1200,
        'the exiting game is told once that the step is held, and for longer than it waits for an answer')
    check(W.logged('no answer from the server', 'client:open77_avdoor:1') == nil, 'so it does not give up')
    check(W.logged('exit clip step playing', 'client:open77_avdoor:1') ~= nil, 'its clip plays')
    check(W.players[1].frozenLog[1] ~= nil and W.players[1].frozenLog[1].at <= played.at, 'the body was held still through the hold')
end)

run('a game whose dismount never lets go: it says so, the step does not wait past it, and the verdict names it', function()
    excaliburScene({ { id = 2, x = -8, y = 0, options = { dismountMs = 60000 } } })
    local leftAt = W.now
    W.leave(1, { eject = false })
    W.advance(12000)
    local ready = fromPlayer('open77_avdoor:sceneReady', 2)
    check(#ready == 1 and ready[1].payload.free == false and ready[1].payload.seen == true,
        'player 2\'s game says the body is still in its seat')
    check(ready[1] ~= nil and ready[1].at - leftAt >= 4500 and ready[1].at - leftAt <= 4700,
        'after READY_MAX_MS, not never')
    check(W.logged('STILL IN ITS SEAT here', 'client:open77_avdoor:2', 'warn') ~= nil, 'a warning in its own log')
    check(W.logged('player 2\'s screen still drew player 1 in the seat', SRV, 'warn') ~= nil, 'and in the server\'s')
    local played = W.locomotion.played[1]
    check(played ~= nil and played.at - leftAt <= 5100,
        ('the step plays all the same, never past WAIT_MAX_MS after the exit: %d ms'):format(played and played.at - leftAt or -1))
    check(W.logged('-- WRONG: drew player 1 still in the seat', SRV, 'warn') ~= nil,
        'what player 2 drew as the step began is WRONG in the server log')
    check(W.logged('exit 1 of player 1: verdict', SRV, 'warn') ~= nil
        and W.logged('thing(s) wrong -- player 2\'s screen still drew player 1 in the seat when the step was due', SRV) ~= nil,
        'and the verdict says what was wrong')
end)

run('a game with no avdoor client, one that does not draw the body, one far away: nobody is waited for', function()
    excaliburScene({
        { id = 2, x = -8, y = 0, options = { dismountMs = 2811 } },
        { id = 3, x = 12, y = 0, options = { dismountMs = 2811 }, client = false },
        { id = 4, x = 400, y = 0 },
    }, function() W.players[1].unstreamedFor = { [2] = true } end)
    local leftAt = W.now
    W.leave(1, { eject = false })
    W.advance(9000)
    local line = W.logged('exit 1 of player 1 (seat_front_left of 4294967297)', SRV) or ''
    check(line:find('1 other screen(s) draw it: player 2 (', 1, true) ~= nil
        and line:find('not waited for (no open77_avdoor client said hello): player 3 (12 m)', 1, true) ~= nil
        and line:find('player 4', 1, true) == nil, 'the server says who is waited for, who cannot answer, and passes over the far one: ' .. line)
    local ready = fromPlayer('open77_avdoor:sceneReady', 2)
    check(#ready == 1 and ready[1].payload.seen == false and ready[1].payload.why == 'player_not_streamed'
        and ready[1].at - leftAt <= 500, 'player 2\'s game says at once that it does not draw the body')
    check(W.logged('player 2\'s screen does not draw player 1 (player_not_streamed): nothing to wait for there', SRV) ~= nil,
        'the server says so')
    local played = W.locomotion.played[1]
    check(played ~= nil and played.at - leftAt < 100 + 2811, 'the step is not held for a dismount nobody draws')
    check(W.logged('is held for the other screens', SRV) == nil, 'not held at all')
    check(W.logged('exit 1 of player 1: verdict -- the step played', SRV, 'info') ~= nil
        and W.logged('2 of 2 report(s) (every screen reported): nothing wrong', SRV) ~= nil,
        'the verdict waits for the exiting screen\'s own reports only')
    check(#toPlayer('open77_avdoor:scene', 3) >= 1 and #toPlayer('open77_avdoor:scene', 4) == 0,
        'the game with no avdoor client is told all the same (a word from it would be its hello); the far one is not')
end)

run('a game that draws the AV off the server\'s pose has it re-published once, and only an empty hull', function()
    local hull = excaliburScene({ { id = 2, x = -8, y = 0, options = { dismountMs = 1000 } } },
        function() W.vehicles[HULL].drawnOffsetFor = { [2] = { x = 1.2, y = 0, z = 0 } } end)
    W.leave(1, { eject = false })
    W.advance(9000)
    local ready = fromPlayer('open77_avdoor:sceneReady', 2)
    check(#ready == 1 and math.abs((ready[1].payload.hullOff or 0) - 1.2) < 0.01,
        'player 2\'s game says it draws the AV 1.2 m from where the network has it')
    check(W.logged('aircraft 4294967297 re-published where the server has it (0.0, 0.0, 1.0, heading 0): player 2\'s '
        .. 'screen drew it 1.20 m away', SRV) ~= nil, 'the server publishes its own pose again')
    check(#hull.transforms == 1 and hull.transforms[1].hadYaw == true and hull.z == 1.0 and hull.x == 0,
        'once, where it already is, its heading passed')
    local start2 = reportOf(2, 'start')
    check(start2 ~= nil and (start2.hullOff or 9) < 0.05, 'and player 2 draws it where the server has it as the step starts')
    -- WITH SOMEBODY ABOARD the hull is never moved.
    excaliburScene({ { id = 2, x = -8, y = 0, options = { dismountMs = 1000 } }, { id = 3, x = 0, y = 0 } },
        function() W.vehicles[HULL].drawnOffsetFor = { [2] = { x = 1.2, y = 0, z = 0 } } end)
    hull = W.vehicles[HULL]
    W.seat(3, HULL, 'seat_back_right')
    W.advance(1000)
    W.leave(1, { eject = false })
    W.advance(9000)
    check(#hull.transforms == 0, 'a hull with a passenger aboard is not re-published')
    check(W.logged('draws the AV 1.20 m off the server\'s pose; not re-published (1 aboard)', SRV) ~= nil, 'and the server says why')
    check(W.logged('drew the AV 1.20 m from the server\'s pose', SRV, 'warn') ~= nil
        and W.logged('drew the AV\'s door 1.20 m from where the server has it', SRV, 'warn') ~= nil
        and W.logged('the step\'s first frame stood 1.20 m from the door as it drew player 1 and the AV', SRV, 'warn') ~= nil,
        'what player 2 drew of the step is WRONG: the AV and its door 1.2 m off')
end)

run('the logger: a body drawn off its end point, a step shown in first person -- each a WRONG line and the verdict', function()
    excaliburScene({ { id = 2, x = -8, y = 0, options = { dismountMs = 500 } } },
        function() W.players[1].tpsReadyMs = false end)
    W.leave(1, { eject = false })
    W.advance(300)
    W.players[1].drawnOffsetFor = { [2] = { x = 1.5, y = 0, z = 0 } }
    W.advance(16000)
    check(W.locomotion.played[1] ~= nil, 'the step plays for the others')
    local start2 = reportOf(2, 'start')
    check(start2 ~= nil and math.abs((start2.off or 0) - 1.5) < 0.05, 'player 2 draws the body 1.5 m off the end point')
    check(W.logged('player 2\'s screen as the step began: player 1 out of the seat, 1.50 m from the step\'s end point', SRV, 'warn') ~= nil
        and W.logged('-- WRONG: drew player 1 1.50 m from the step\'s end point', SRV) ~= nil, 'a WRONG line in the server log')
    check(W.logged('the body is 1.50 m from the step\'s end point', 'client:open77_avdoor:2', 'warn') ~= nil,
        'and in player 2\'s own log')
    local start1 = reportOf(1, 'start')
    check(start1 ~= nil and start1.view == 'fpp', 'the exiting screen never got its stand-in: first person')
    check(W.logged('-- WRONG: its own screen showed the step in first person', SRV, 'warn') ~= nil, 'WRONG too')
    -- Drawn 1.5 m off, the step starts 1.5 m off the door there too (1.5.0).
    check(W.logged('the step\'s first frame stood 1.50 m from the door as it drew player 1 and the AV', SRV, 'warn') ~= nil
        and W.logged('drew player 1\'s first steps 1.39 m from the door (its hips)', SRV, 'warn') ~= nil,
        'and the step\'s first frame and its hips off the door as player 2 draws them')
    check(W.logged('exit 1 of player 1: verdict', SRV, 'warn') ~= nil
        and W.logged('7 thing(s) wrong', SRV) ~= nil, ('the verdict counts them: %s'):format(
        tostring(W.logged('exit 1 of player 1: verdict', SRV))))
end)

run('a game at 3.4 frames a second: its frame rate is in every word it sends, and its own log warns once a minute', function()
    -- Player 1's game runs at 60 frames a second, on frames (16 ms).
    excaliburScene({ { id = 2, x = -8, y = 0, options = { dismountMs = 2811, frameMs = 294 } } },
        function() W.players[1].frameMs = 16 end)
    W.leave(1, { eject = false })
    W.advance(9000)
    local ready = fromPlayer('open77_avdoor:sceneReady', 2)
    check(#ready == 1 and math.abs((ready[1].payload.fps or 0) - 1000 / 294) < 0.05,
        ('the word carries its frame rate: %s'):format(tostring(ready[1] and ready[1].payload.fps)))
    check(W.logged(', 3.4 fps', SRV) ~= nil, 'the server log shows it')
    check(W.logged('client health: 3.4 fps (frames 294 ms', 'client:open77_avdoor:2', 'warn') ~= nil,
        'its own log warns that the game runs slow')
    check(W.count('client health:', 'client:open77_avdoor:2') == 1, 'once')
    W.advance(61000)
    check(W.count('client health:', 'client:open77_avdoor:2') == 2, 'and again a minute later')
    check(W.logged('client health: 62.5 fps', 'client:open77_avdoor:1', 'info') ~= nil
        and W.logged('client health:', 'client:open77_avdoor:1', 'warn') == nil
        and W.count('client health:', 'client:open77_avdoor:1') == 1,
        'a game at full speed says so once, and then not for five minutes')
    local start1 = reportOf(1, 'start')
    check(start1 ~= nil and start1.fps ~= nil and math.abs(start1.fps - 62.5) < 0.1,
        ('the exiting game\'s reports carry its own frame rate: %s'):format(tostring(start1 and start1.fps)))
end)

run('two players step out of one hull at once: two scenes, each held for the screens near it, two verdicts', function()
    excaliburScene({ { id = 2, x = 0, y = 0 }, { id = 3, x = -8, y = 0, options = { dismountMs = 2811 } } })
    W.seat(2, HULL, 'seat_back_right')
    W.advance(1000)
    W.leave(1, { eject = false })
    W.advance(300)
    W.leave(2, { eject = false })
    W.advance(14000)
    check(#W.locomotion.played == 2, 'both steps play')
    local ready3 = fromPlayer('open77_avdoor:sceneReady', 3)
    check(#ready3 == 2 and ready3[1].payload.scene ~= ready3[2].payload.scene, 'player 3 says its word for each exit')
    check(W.logged('exit 1 of player 1: verdict', SRV) ~= nil and W.logged('exit 2 of player 2: verdict', SRV) ~= nil,
        'each exit has its verdict')
    for _, played in ipairs(W.locomotion.played) do
        local ready = nil
        for _, r in ipairs(ready3) do if r.payload.scene == played.player then ready = r end end
        check(ready ~= nil and played.at >= ready.at, ('player %d\'s step waits for player 3\'s word'):format(played.player))
    end
end)

run('SYNC = false: no scene, the step starts when the exiting game asks', function()
    excaliburScene({ { id = 2, x = -8, y = 0, options = { dismountMs = 2811 } } },
        function() end)
    server.env.AvDoor.Settings.SYNC = false
    for _, vm in pairs(W.vms) do if vm.side == 'client' then vm.env.AvDoor.Settings.SYNC = false end end
    settingsChanged()
    local leftAt = W.now
    W.leave(1, { eject = false })
    W.advance(9000)
    check(#W.sent('open77_avdoor:scene') == 0, 'nobody is told of the exit')
    local played = W.locomotion.played[1]
    check(played ~= nil and played.at - leftAt < 100 + 2811, 'the step is not held')
    check(W.logged('verdict', SRV) == nil, 'and there is no verdict')
end)

-- ── the step's heading, the ground and the door as each game draws it (1.5.0) ─

local CLIENT1 = 'client:open77_avdoor:1'

--- How far apart two headings are (0 to 180), or 999 for a missing one.
local function yawOff(a, b)
    a, b = tonumber(a), tonumber(b)
    if a == nil or b == nil then return 999 end
    local d = (a - b) % 360.0
    return math.min(d, 360.0 - d)
end

--- Where the step played for player 1 starts (from where the body stood and
--- the way it faced as the clip began), against the Excalibur's door.
local function startOnDoor(hull, played, right, ahead)
    local doorX, doorY = onHull(hull, right or -1.45, ahead or -0.13)
    local sx, sy = clipStart(played or { x = 0, y = 0 }, played and played.yaw or 0)
    return math.sqrt((sx - doorX) ^ 2 + (sy - doorY) ^ 2), sx, sy, doorX, doorY
end

run('Staging, 2026-10-28, 03:15:44: the client\'s chase camera turns the body 171 deg as it lets go -- turned back before the ask, the step starts on the door', function()
    local hull = excaliburScene({ { id = 2, x = -8, y = 0, options = { dismountMs = 1000 } } },
        function() W.players[1].turnOnChaseRelease = 171 end)
    W.leave(1, { eject = false })
    W.advance(9000)
    local player = W.players[1]
    check(player.turnLog ~= nil and #player.turnLog == 1 and player.turnLog[1].why == 'chase',
        'the chase camera turned the body once, after the exit placed it')
    check(W.logged('exit clip step: the body turned 171 deg, from 75 to 246 -- 171 deg off the step\'s 75', CLIENT1) ~= nil,
        'the turn is a line in the log, with what was going on')
    check(W.logged('exit clip step: the body faces 246 deg, 171 deg off the step\'s 75 -- the clip would start 4.9 m from '
        .. 'the door: turned back (1 of 3', CLIENT1) ~= nil, 'and the body is turned back before the ask, saying why')
    check(W.logged('exit clip step: the body holds the step\'s heading now (75 deg, 0.0 off) after 1 turn(s) back', CLIENT1) ~= nil,
        'it holds the heading for two looks before the clip is asked')
    local played = W.locomotion.played[1]
    check(played ~= nil and yawOff(played.yaw, 75) < 1, ('the step plays facing the step\'s heading: %s'):format(
        tostring(played and played.yaw)))
    local off, sx, sy, dx, dy = startOnDoor(hull, played)
    check(off < 0.05, ('its first frame on the door: %.2f, %.2f (door %.2f, %.2f)'):format(sx, sy, dx, dy))
    local ask = fromPlayer('open77_avdoor:walkout', 1, function(p) return p.clip == 'step' end)[1]
    check(ask ~= nil and ask.payload.plan.turnedBack == 1 and (ask.payload.plan.facingOff or 9) < 1,
        'the ask says the body was turned back once and faced the step\'s heading')
    check(W.logged('the body facing 75 deg (0.0 off the step\'s 75), turned back 1 time(s)', SRV) ~= nil,
        'the server says so where it holds the plan')
    local start1 = reportOf(1, 'start')
    check(start1 ~= nil and (start1.yawOff or 9) < 1 and (start1.startDoor or 9) < 0.05,
        'the exiting screen reports its body facing the step\'s heading, its first frame on the door')
    local start2 = reportOf(2, 'start')
    check(start2 ~= nil and (start2.yawOff or 9) < 1 and (start2.startDoor or 9) < 0.05 and (start2.hipsRoot or 0) > 2.0
        and (start2.hipsDoor or 9) < 0.3, 'and so does the other screen, the step drawn there from the door (its hips)')
    check(W.logged('WRONG') == nil and W.logged('nothing wrong', SRV) ~= nil, 'nothing was wrong anywhere')
end)

run('the same turn without the heading check (FACING_TRIES = 0): the logger says the step is turned, 4.9 m off the door', function()
    local hull = excaliburScene({ { id = 2, x = -8, y = 0, options = { dismountMs = 1000 } } },
        function() W.players[1].turnOnChaseRelease = 171 end)
    server.env.AvDoor.Settings.EXIT_ANIM.FACING_TRIES = 0
    for _, vm in pairs(W.vms) do if vm.side == 'client' then vm.env.AvDoor.Settings.EXIT_ANIM.FACING_TRIES = 0 end end
    settingsChanged()
    W.leave(1, { eject = false })
    W.advance(9000)
    local played = W.locomotion.played[1]
    local off = startOnDoor(hull, played)
    check(played ~= nil and off > 4.5, ('1.4.0\'s step: the body turned round, its first frame %.1f m from the door'):format(off))
    check(W.logged('exit clip step: the body faces 246 deg as the step begins, 171.0 deg off the step\'s 75', CLIENT1, 'warn') ~= nil,
        'the exiting game warns as the step begins')
    check(W.logged('drew its body facing 246 deg, 171 deg off the step\'s 75: the step\'s path is turned with it', SRV, 'warn') ~= nil
        and W.logged('the step\'s first frame stood 4.9', SRV, 'warn') ~= nil
        and W.logged('m from the door as it drew its body and the AV', SRV, 'warn') ~= nil,
        'the server names it: the heading, and where the first frame stood')
    check(W.logged('drew player 1 facing 246 deg, 171 deg off the step\'s 75', SRV, 'warn') ~= nil,
        'the other screen draws it turned too')
    check(W.logged('exit 1 of player 1: verdict', SRV, 'warn') ~= nil, 'and the verdict is not "nothing wrong"')
end)

run('a turn as the step begins is said, not turned back: a move then would take the body off the ground under the clip (1.5.3)', function()
    local hull = excaliburScene({ { id = 2, x = -8, y = 0, options = { dismountMs = 800 } } })
    W.leave(1, { eject = false })
    local played = nil
    for _ = 1, 400 do
        W.advance(20)
        played = W.locomotion.played[1]
        if played ~= nil then break end
    end
    check(played ~= nil, 'the step plays')
    -- Something turns the body round 20 ms into the step.
    W.advance(20)
    W.players[1].yaw = 246
    W.advance(400)
    check(W.logged('exit clip step: the body turned off the step\'s heading as the clip started, 0.', CLIENT1, 'warn') ~= nil
        and W.logged('(it faces 246 deg, 171 off the step\'s 75', CLIENT1, 'warn') ~= nil
        and W.logged('not turned back -- a move now would take the body off the ground under the clip', CLIENT1, 'warn') ~= nil,
        'the turn is seen as the clip starts, and said')
    check(yawOff(W.players[1].yaw, 246) < 1, 'the body is not moved under the clip')
    check(W.clipDrawn(played) == true, 'the clip goes on, on a body held on its feet')
    W.advance(8000)
    check(W.logged('exit 1 of player 1: verdict', SRV) ~= nil and W.logged('WRONG', SRV) ~= nil,
        'the logger names the heading as wrong')
end)

run('a turn while the server holds the step for another screen is said, not turned back (1.5.3)', function()
    local hull = excaliburScene({ { id = 2, x = -8, y = 0, options = { dismountMs = 4000 } } })
    W.leave(1, { eject = false })
    local held = nil
    for _ = 1, 400 do
        W.advance(20)
        held = W.logged('the server holds the step up to', CLIENT1)
        if held ~= nil then break end
    end
    check(held ~= nil, 'the server holds the step')
    W.players[1].yaw = 246
    W.advance(300)
    check(W.logged('exit clip step: the body turned off the step\'s heading while the clip was asked (it faces 246 deg',
        CLIENT1, 'warn') ~= nil, 'the turn is seen while the ask is in flight')
    W.advance(8000)
    local played = W.locomotion.played[1]
    check(played ~= nil and W.clipDrawn(played) == true, 'the step plays on a body held on its feet, never moved under the ask')
end)

run('a camera swing that turns the body with it: let go, the body turned back, and no swing for the rest of the session', function()
    local hull = excaliburScene({}, function() W.players[1].orbitTurnsBody = true end)
    W.leave(1, { eject = false })
    W.advance(9000)
    check(W.logged('exit view: the camera\'s swing round the body turned the body with it (from 75 to 235 deg, the swing '
        .. '160 deg)', CLIENT1, 'warn') ~= nil, 'the swing is seen turning the body, and let go')
    check(W.logged('turned back (1 of 3', CLIENT1) ~= nil, 'the body is turned back')
    local played = W.locomotion.played[1]
    check(played ~= nil and yawOff(played.yaw, 75) < 1 and startOnDoor(hull, played) < 0.05,
        'the step plays facing its heading, from the door')
    local start1 = reportOf(1, 'start')
    check(start1 ~= nil and start1.orbit == false, 'seen from behind')
    -- The next exit on this client makes no swing.
    W.seat(1, HULL, 'seat_front_left')
    W.advance(1500)
    W.leave(1, { eject = false })
    W.advance(9000)
    check(W.logged('exit view: no swing round the body on this client: one turned the body with it (from 75 to 235 deg)',
        CLIENT1) ~= nil, 'the next exit says why there is no swing')
    check(#W.players[1].orbitLog == 2, 'the swing was made once, and cleared once')
    local second = W.locomotion.played[2]
    check(second ~= nil and yawOff(second.yaw, 75) < 1 and startOnDoor(hull, second) < 0.05, 'and the step is right again')
end)

run('the laptop, a camera swing that turns the held body with it: let go, turned back by a move, held again once the move is in, the step drawn on its feet (1.5.3)', function()
    local hull = excaliburScene({}, function()
        W.players[1].orbitTurnsBody = true
        W.players[1].afterExitAir = true
    end)
    W.leave(1, { eject = false })
    W.advance(12000)
    check(W.logged('exit view: the camera\'s swing round the body turned the body with it', CLIENT1, 'warn') ~= nil,
        'the swing is seen turning the body, and let go')
    check(W.logged('let go for a move', CLIENT1) ~= nil, 'the hold let go before the turn back')
    local played = W.locomotion.played[1]
    check(played ~= nil and yawOff(played.yaw, 75) < 1 and startOnDoor(hull, played) < 0.05 and W.clipDrawn(played) == true,
        'the step plays facing its heading, from the door, drawn')
    check(W.players[1].stuckForGood ~= true, 'never moved while held')
end)

run('a body that will not hold the step\'s heading plays no clip: it is shown standing, never walking the wrong way', function()
    excaliburScene({}, function() W.players[1].stickyYaw = { yaw = 246, times = 99 } end)
    W.leave(1, { eject = false })
    W.advance(12000)
    check(W.count('turned back (', CLIENT1) == 3, 'turned back three times')
    check(W.logged('exit clip step: the turn back to 75 deg did not hold -- the body faces 246 again', CLIENT1, 'warn') ~= nil,
        'each time it faces its own heading again, and the log says the turn back did not hold')
    check(W.logged('no clip -- the body would not hold the step\'s heading: it faces 246 deg, 171 deg off the step\'s 75, '
        .. 'after 3 turn(s) back -- the clip would start 4.9 m from the door', CLIENT1, 'warn') ~= nil,
        'then the clip is given up, saying why')
    check(#W.locomotion.played == 0, 'no clip is played')
    check(firstVisibility(1, true) ~= nil, 'the others see the body standing')
    check(W.logged('exit 1 of player 1: verdict -- no step was played', SRV) ~= nil, 'and the verdict says no step was played')
    check(W.players[1].covered == nil, 'the image is back')
end)

--- Where in the log a line is (its index), or nil.
local function logAt(text, vmName)
    for index, entry in ipairs(W.logs) do
        if (vmName == nil or entry.vm == vmName) and entry.text:find(text, 1, true) ~= nil then return index end
    end
    return nil
end

--- Every hold the client put on the body: `{ at, grounded, way }`.
local function holdsOf(player)
    local out = {}
    for _, entry in ipairs(player.frozenLog) do
        if entry.position == true then out[#out + 1] = { at = entry.at, grounded = entry.grounded, way = 'position' } end
        if entry.restriction == true then out[#out + 1] = { at = entry.at, grounded = entry.grounded, way = 'restriction' } end
    end
    return out
end

run('the native fade holds the body still where it is -- in the air too -- until its fade-in has run (the world, as measured)', function()
    -- THE LAPTOP (Staging, 2026-10-28, 10:32:56, 1.5.3; 01:54:15 and :32, 1.5.2):
    -- a body put beside the AV 3 cm over the ground under the exit's cut to black
    -- hung there "falling", 0.00 m/s, for the whole fade, held or not, put 5 cm
    -- over the ground again or not, and moved the moment the fade-in had run.
    excaliburScene({})
    local player = W.players[1]
    local env = W.vms[CLIENT1].env
    env.AvDoor.Settings.EXIT_ANIM.FREEZE = false
    settingsChanged()
    W.leave(1, { eject = false })
    W.advance(3000)
    check(W.grounded(player), 'on foot after the exit, on the ground (no fade)')
    local id = env.Open77.screen.fadeOut({ durationMs = 0 })
    W.advance(500)
    check(W.grounded(player), 'standing when the fade came: standing under it')
    local z = player.z
    env.Open77.travel.teleport(player.x, player.y, player.z + 0.03, 75)
    W.advance(6000)
    check(not W.grounded(player) and math.abs(player.z - (z + 0.03)) < 1e-6,
        'moved under the fade: in the air where it was put, 6 s later')
    env.Open77.players.freezePosition(true)
    W.advance(1500)
    env.Open77.players.freezePosition(false)
    W.advance(1500)
    check(not W.grounded(player), 'held and let go under the fade: still in the air')
    env.Open77.travel.teleport(player.x, player.y, z + 0.05, 75)
    W.advance(1500)
    check(not W.grounded(player), 'put 5 cm over the ground under the fade: still in the air')
    local state = env.Open77.screen.nativeState()
    check(state.faded == true and state.out == true, 'the engine says the screen is black')
    env.Open77.screen.fadeIn(id, { durationMs = 550 })
    W.advance(400)
    check(not W.grounded(player), 'during the fade-in: still held where it is')
    W.advance(300)
    check(W.grounded(player) and math.abs(player.z - z) < 1e-6, 'the fade-in run: it lands')
    -- The forced freeze (conservative): taken off the ground, it keeps the body off it until let go.
    env.Open77.travel.teleport(player.x, player.y, z + 0.5, 75)
    env.Open77.players.freezePosition(true)
    W.advance(1000)
    check(not W.grounded(player), 'a body the forced freeze takes in the air stays there while held')
    env.Open77.players.freezePosition(false)
    W.advance(200)
    check(W.grounded(player), 'and comes down once let go')
    env.Open77.character.setFrozen(true)
    W.advance(200)
    check(W.grounded(player), 'the NoMovement restriction leaves it on the ground')
    env.Open77.character.setFrozen(false)
end)

run('Staging, 2026-10-28, 10:32:56: the laptop\'s exit -- black first and moved under it, the body hangs "falling" to the end; 1.6.0 lands it first and plays the step', function()
    -- THE OLD ORDER, in this world: the cut to black at the exit, the body put
    -- beside the door under it -- "falling" for the whole fade, landing only
    -- once the image is back (what the laptop's 1.5.3 log and its "reveal"
    -- picture showed: the fall pose 0.4 s into the fade-in).
    excaliburScene({})
    local player = W.players[1]
    local env = W.vms[CLIENT1].env
    env.AvDoor.Settings.EXIT_ANIM = false
    settingsChanged()
    local id = env.Open77.screen.fadeOut({ durationMs = 0 })
    W.leave(1, { eject = false })
    W.advance(150)
    env.Open77.travel.teleport(-42.3 + 38.4, 0, 0.03, 75)
    local stood = false
    for _ = 1, 54 do
        W.advance(100)
        stood = stood or W.grounded(player)
    end
    check(not stood, 'the old order: never on the ground in 5.4 s of black')
    env.Open77.screen.fadeIn(id, { durationMs = 550 })
    W.advance(500)
    check(not W.grounded(player), 'still not on the ground as the image comes back')
    W.advance(200)
    check(W.grounded(player) and (player.screenLandings or 0) == 1, 'it lands once the fade-in has run')

    -- 1.6.0: the same exit, the pilot's seat of the Excalibur.
    world(function()
        W.exitPackage()
        W.vehicle(HULL, AV, 0, 0, 1.0, { halfWidth = 1.84, halfLength = 4.8 })
        W.player(1, 0, 0, 2.0, { frameMs = 23, tpsReadyMs = 300 })
        W.player(2, -8, 0, 0)
    end, { 1, 2 })
    local hull = W.vehicles[HULL]
    W.seat(1, HULL, 'seat_front_left')
    W.advance(1500)
    player = W.players[1]
    local leftAt = W.now
    W.leave(1, { eject = false })
    W.advance(12000)
    local name = CLIENT1
    local played = W.locomotion.played[1]
    -- NO CUT AT THE EXIT; NO MOVE UNDER A FADE.
    local firstFade = firstOf(player.fades, function(f) return f.out == true end)
    local firstMove = player.teleports[1]
    check(firstMove ~= nil and firstFade ~= nil and firstMove.at < firstFade.at,
        'the body is put beside the door before any fade')
    local under = 0
    for _, t in ipairs(player.teleports) do if t.underFade then under = under + 1 end end
    check(under == 0 and (player.screenMoves or 0) == 0, 'nothing moved the body under a fade: ' .. under)
    check(firstFade ~= nil and firstFade.grounded == true, 'the curtain came down on a body standing on the ground')
    local holds = holdsOf(player)
    check(#holds >= 1 and holds[1].grounded == true and firstFade ~= nil and holds[1].at <= firstFade.at,
        'held, standing, before the curtain came down')
    check(firstFade ~= nil and firstFade.at - leftAt <= 1300,
        ('the curtain down before the client\'s chase camera lets go: %d ms after the exit'):format(
            firstFade and firstFade.at - leftAt or -1))
    check(W.logged('exit clip step prepared', name) ~= nil and W.logged('exit curtain down (the step prepared', name) ~= nil,
        'the log says the step was prepared, then the curtain came down')
    check(played ~= nil and startOnDoor(hull, played) < 0.05, 'the step played from the door')
    check(W.clipDrawn(played) == true, ('drawn: its body on the ground at every look (%s of %s off it)'):format(
        tostring(played and played.air or 0), tostring(played and played.looks or 0)))
    local back = lastFadeIn(player)
    check(back ~= nil and played ~= nil and back.at >= played.at and back.at - played.at <= 50,
        'the image back with the step\'s first frame')
    check(back ~= nil and firstFade ~= nil and back.at - firstFade.at <= 3000,
        ('black %d ms in all'):format((back and firstFade) and back.at - firstFade.at or -1))
    check(W.logged('never stood', name) == nil and W.logged('no clip', name) == nil, 'no "never stood", no "no clip"')
    check(W.logged('WRONG') == nil and W.logged('nothing wrong', SRV) ~= nil, 'nothing was wrong anywhere')
end)

run('a platform whose own exit keeps the body off the ground until its chase camera lets go: the curtain waits for it to stand (1.6.0)', function()
    world(function()
        W.exitPackage()
        W.vehicle(HULL, AV, 0, 0, 1.0, { halfWidth = 1.84, halfLength = 4.8 })
        W.player(1, 0, 0, 2.0, { frameMs = 23, tpsReadyMs = 300, exitAirMs = 1700 })
        W.player(2, -8, 0, 0)
    end, { 1, 2 })
    local hull = W.vehicles[HULL]
    W.seat(1, HULL, 'seat_front_left')
    W.advance(1500)
    local player = W.players[1]
    local leftAt = W.now
    W.leave(1, { eject = false })
    W.advance(12000)
    local name = CLIENT1
    local played = W.locomotion.played[1]
    local firstFade = firstOf(player.fades, function(f) return f.out == true end)
    check(firstFade ~= nil and firstFade.grounded == true and firstFade.at - leftAt >= 1700,
        ('the curtain only once the body stood: %d ms after the exit'):format(firstFade and firstFade.at - leftAt or -1))
    local holds = holdsOf(player)
    check(#holds >= 1 and holds[1].grounded == true, 'held only once it stood')
    check(played ~= nil and startOnDoor(hull, played) < 0.05 and W.clipDrawn(played) == true, 'the step drawn from the door')
    check(W.logged('waits for the body to stand beside the door', name) == nil or W.logged('never stood', name) == nil,
        'no "never stood"')
    local under = 0
    for _, t in ipairs(player.teleports) do if t.underFade then under = under + 1 end end
    check(under == 0, 'nothing moved under a fade')
end)

run('Staging, 2026-10-28, 04:39:17: the laptop at ten frames a second steps out of the back seat -- held only once it stands, turned back first, the step drawn on its feet', function()
    world(function()
        W.exitPackage()
        W.vehicle(HULL, AV, 0, 0, 1.0, { halfWidth = 1.84, halfLength = 4.8 })
        -- The laptop: ten frames a second, the stand-in dressed 2.6 s after third
        -- person is let in, and the body turned back to the hull's heading as the
        -- client's chase camera lets go (planned 75, drawn 0 at 04:39:23.483).
        W.player(1, 0, 0, 2.0, { frameMs = 100, tpsReadyMs = 2600, turnOnChaseRelease = -75 })
        W.player(2, -8, 0, 0, { dismountMs = 1000 })
    end, { 1, 2 })
    local hull = W.vehicles[HULL]
    -- The back seat: the passengers' fade hold (0.8 s) -- 1.5.0 held the body
    -- 0.85 s after the exit, while the client's own exit still ran.
    W.seat(1, HULL, 'seat_back_left')
    W.advance(1500)
    local player = W.players[1]
    local leftAt = W.now
    W.leave(1, { eject = false })
    W.advance(14000)
    local holds = holdsOf(player)
    check(#holds >= 1 and holds[1].grounded == true,
        ('the first hold only once the body stood (1.6.0: as soon as it stands): %d ms after the seat was left, %s')
            :format(holds[1] and holds[1].at - leftAt or -1, tostring(holds[1] and holds[1].grounded)))
    local under = 0
    for _, t in ipairs(player.teleports) do if t.underFade then under = under + 1 end end
    check(under == 0, 'the turn back made with the image on, never under the curtain')
    check(W.logged('under the curtain (', CLIENT1) ~= nil and W.logged('it is turned back and held again with the image on',
        CLIENT1) ~= nil, 'the turn under the curtain is seen at once, and the curtain lifted for the turn back')
    local lifted = 0
    for _, hold in ipairs(holds) do if hold.grounded ~= true then lifted = lifted + 1 end end
    check(lifted == 0, 'no hold ever taken off the ground')
    check(W.logged('exit clip step: the body stands on the ground', CLIENT1) ~= nil, 'the log says when the body stood')
    local back = logAt('turned back (1 of 3', CLIENT1)
    local drawn = logAt('exit view: third person drawn', CLIENT1)
    check(back ~= nil and drawn ~= nil and back < drawn, 'the body is turned back before third person is drawn')
    local played = W.locomotion.played[1]
    check(played ~= nil and yawOff(played.yaw, 75) < 1, 'the step plays facing its heading: ' .. tostring(played and played.yaw))
    check(played ~= nil and startOnDoor(hull, played) < 0.05, 'its first frame on the door')
    check(W.clipDrawn(played) == true, ('drawn: its body on the ground at every look (%s of %s off it)'):format(
        tostring(played and played.air or 0), tostring(played and played.looks or 0)))
    check(played ~= nil and played.at - leftAt <= 9500, ('the step %d ms after the seat was left'):format(
        played and played.at - leftAt or -1))
    local start1 = reportOf(1, 'start')
    check(start1 ~= nil and start1.grounded ~= false and (start1.yawOff or 9) < 1, 'its own screen: on its feet, facing it')
    local start2 = reportOf(2, 'start')
    check(start2 ~= nil and (start2.hipsRoot or 0) > 2.0, 'the other screen draws the step (its hips off the feet\'s point)')
    check(W.logged('WRONG') == nil and W.logged('nothing wrong', SRV) ~= nil, 'nothing was wrong anywhere')
end)

--- The pictures one player's store keeps: `{ [set] = { { key, bytes, meta } } }`
--- and the index, in order.
local function picturesOf(playerId)
    local store = W.players[playerId].kvp or {}
    local sets, index = {}, {}
    for id in tostring(store.shots or ''):gmatch('[^,]+') do index[#index + 1] = id end
    -- Each set's words: one value, a line a picture (`nn<TAB>k=v;...`).
    local wordsOf = {}
    for key, value in pairs(store) do
        local set = key:match('^shot:([^:]+):words$')
        if set ~= nil then
            wordsOf[set] = {}
            for n, text in tostring(value):gmatch('(%d+)\t([^\n]*)') do wordsOf[set][tonumber(n)] = text end
        end
    end
    for key, value in pairs(store) do
        local set, n = key:match('^shot:([^:]+):(%d+)$')
        if set ~= nil then
            sets[set] = sets[set] or {}
            sets[set][#sets[set] + 1] = { key = key, n = tonumber(n), bytes = #value,
                meta = (wordsOf[set] or {})[tonumber(n)] }
        end
    end
    for _, list in pairs(sets) do table.sort(list, function(a, b) return a.n < b.n end) end
    return sets, index
end

run('the exit\'s pictures: a frame after the exit, the body beside the door before the curtain, the image back, the step through to its end -- kept on the player\'s own machine, the last two exits', function()
    local hull = excaliburScene({ { id = 2, x = -8, y = 0 } })
    W.leave(1, { eject = false })
    W.advance(16000)
    local sets, index = picturesOf(1)
    check(#index == 1 and sets[index[1]] ~= nil, 'one set of pictures for the exit, in the store\'s index')
    local list = sets[index[1]] or {}
    local labels = {}
    for _, shot in ipairs(list) do labels[#labels + 1] = shot.meta ~= nil and shot.meta:match('label=([^;]+)') or '?' end
    check(table.concat(labels, ' ') == 'exit ready reveal clip+0.6 clip+1.6 clip+2.8 clip+4.0 clip+4.8',
        'the exit, the body ready beside the door, the image back, and the step through to its end: '
            .. table.concat(labels, ' '))
    local captures = W.players[1].captures or {}
    check(#captures == 8 and captures[1].covered == false and captures[3].covered == false,
        'the first with the image on (1.6.0: no cut at the exit), the image back for the rest')
    check(captures[1] ~= nil and captures[1].options.includeOverlay == false and captures[1].options.scale == 0.25
        and captures[1].options.maxBytes <= 60 * 1024, 'the game\'s frame alone, a quarter of its size, under a store value')
    local clipShot = list[4]
    check(clipShot ~= nil and clipShot.meta:find('clip=0.6', 1, true) ~= nil and clipShot.meta:find('state=on the ground', 1, true) ~= nil
        and clipShot.meta:find('hold=held still', 1, true) ~= nil and clipShot.meta:find('step=step yaw 75', 1, true) ~= nil,
        'each with what the client knew: ' .. tostring(clipShot and clipShot.meta))
    -- The other screen: its own set, of the step it drew.
    local theirs, theirIndex = picturesOf(2)
    check(#theirIndex == 1 and #(theirs[theirIndex[1]] or {}) == 4, 'the other screen keeps its own pictures of the step')
    local view = (theirs[theirIndex[1]] or {})[1]
    check(view ~= nil and view.meta:find('label=view+0.6', 1, true) ~= nil and view.meta:find('hips=', 1, true) ~= nil,
        'with the body\'s hips as it drew them: ' .. tostring(view and view.meta))
    -- Two more exits: only the last two are kept.
    for _ = 1, 2 do
        W.seat(1, HULL, 'seat_front_left')
        W.advance(1500)
        W.leave(1, { eject = false })
        W.advance(16000)
    end
    local later, laterIndex = picturesOf(1)
    local n = 0
    for _ in pairs(later) do n = n + 1 end
    check(#laterIndex == 2 and n == 2 and later[index[1]] == nil, 'the last two exits kept, the first let go')
    check(W.logged('WRONG') == nil, 'and nothing wrong')
end)

--- When a log line matching a Lua pattern was first said, or nil.
local function saidAt(pattern, vmName)
    for _, entry in ipairs(W.logs) do
        if (vmName == nil or entry.vm == vmName) and entry.text:find(pattern) ~= nil then return entry.at end
    end
    return nil
end

run('the exit\'s pictures go into the store after the exit, never during it -- one call at a time, a quarter-second apart', function()
    excaliburScene({ { id = 2, x = -8, y = 0 } })
    W.leave(1, { eject = false })
    W.advance(20000)
    local overAt = saidAt('^exit clip .- over after', CLIENT1)
    local ops = W.players[1].kvpOps or {}
    check(overAt ~= nil and #ops > 0, ('the clip over, the store written: %s, %d call(s)'):format(tostring(overAt), #ops))
    local during = 0
    for _, op in ipairs(ops) do if overAt == nil or op.at < overAt then during = during + 1 end end
    check(during == 0, ('no call into the store during the exit (it reads and writes the whole file on the game\'s '
        .. 'thread): %d'):format(during))
    -- One step a resume: the calls of one step share a moment, the steps are apart.
    local moments, last = {}, nil
    for _, op in ipairs(ops) do
        if op.at ~= last then
            moments[#moments + 1] = op.at
            last = op.at
        end
    end
    local closest = math.huge
    for i = 2, #moments do closest = math.min(closest, moments[i] - moments[i - 1]) end
    check(#moments >= 9 and closest >= 250, ('%d steps, the closest %s ms apart'):format(#moments,
        tostring(closest)))
    local sets, index = picturesOf(1)
    check(#index == 1 and #(sets[index[1]] or {}) == 8 and (sets[index[1]][8] or {}).meta ~= nil,
        'all eight in, with their words')
    check(W.logged('in this machine\'s store', CLIENT1) ~= nil, 'and said')
    -- The other screen drew the step: its pictures too, after it.
    local startedAt = saidAt('the step starts %(', 'client:open77_avdoor:2')
    local theirs = W.players[2].kvpOps or {}
    local early = 0
    for _, op in ipairs(theirs) do
        if startedAt == nil or op.at < startedAt + 4000 + 2500 then early = early + 1 end
    end
    check(startedAt ~= nil and #theirs > 0 and early == 0,
        ('the other screen writes its own after the step it drew, and its last picture: %d call(s), %d early')
            :format(#theirs, early))
end)

run('pictures refused by the host: off for the session in one line, the exit as ever; one too large is taken again smaller', function()
    excaliburScene({}, function() W.players[1].captureRefuse = 'permission_denied:screen.capture' end)
    W.leave(1, { eject = false })
    W.advance(10000)
    check(W.count('diag pictures off for this session: the capture was refused (permission_denied:screen.capture)', CLIENT1) == 1,
        'one line')
    check(#(W.players[1].captures or {}) == 0 and W.locomotion.played[1] ~= nil, 'no picture, the step played all the same')
    excaliburScene({}, function()
        W.players[1].captureBytes, W.players[1].captureShrinks = 80 * 1024, true
    end)
    W.leave(1, { eject = false })
    W.advance(16000)
    local sets, index = picturesOf(1)
    local list = sets[index[1] or ''] or {}
    check(#list == 8 and list[1].bytes <= 60 * 1024, ('each taken again at a lower quality and kept: %d, %s bytes'):format(#list,
        tostring(list[1] and list[1].bytes)))
end)

run('a game whose forced freeze takes the body off the ground: let go, held by the NoMovement restriction instead -- for the session', function()
    local hull = excaliburScene({}, function() W.players[1].freezeLifts = true end)
    W.leave(1, { eject = false })
    W.advance(9000)
    check(W.logged('exit clip step: the hold (position) took the body off the ground', CLIENT1, 'warn') ~= nil,
        'the lift is seen, and said')
    local holds = holdsOf(W.players[1])
    local restriction = nil
    for _, hold in ipairs(holds) do if hold.way == 'restriction' then restriction = restriction or hold end end
    check(restriction ~= nil and restriction.grounded == true, 'then the body is held by the NoMovement restriction, on its feet')
    local played = W.locomotion.played[1]
    check(played ~= nil and W.clipDrawn(played) == true and startOnDoor(hull, played) < 0.05, 'the step drawn, from the door')
    -- The next exit holds with the restriction from the first.
    W.seat(1, HULL, 'seat_front_left')
    W.advance(1500)
    local before = #holdsOf(W.players[1])
    W.leave(1, { eject = false })
    W.advance(9000)
    local after = holdsOf(W.players[1])
    check(#after > before and after[before + 1].way == 'restriction', 'the next exit is held by the restriction at once')
    check(W.locomotion.played[2] ~= nil and W.clipDrawn(W.locomotion.played[2]) == true, 'and its step drawn too')
end)

run('keys pressed under the fade before the hold: the body walked off the end point is put back, the step from the door', function()
    local hull = excaliburScene({})
    W.leave(1, { eject = false })
    -- The player walks a metre while the client's own exit camera still holds
    -- the screen (before the body stands, so before it is held).
    W.advance(1500)
    W.players[1].x = W.players[1].x - 1.0
    W.advance(9000)
    check(W.logged('m from the end point: put back on it (1 of 3)', CLIENT1) ~= nil, 'put back on the end point')
    local played = W.locomotion.played[1]
    check(played ~= nil and startOnDoor(hull, played) < 0.05 and W.clipDrawn(played) == true, 'the step from the door, drawn')
end)

run('HOLD = false: the body is never held, and the step is still asked on its feet and drawn', function()
    local hull = excaliburScene({})
    for _, vm in pairs(W.vms) do if vm.side == 'client' then vm.env.AvDoor.Settings.EXIT_ANIM.HOLD = false end end
    settingsChanged()
    W.leave(1, { eject = false })
    W.advance(10000)
    check(#holdsOf(W.players[1]) == 0, 'no hold put on')
    local played = W.locomotion.played[1]
    check(played ~= nil and startOnDoor(hull, played) < 0.05 and W.clipDrawn(played) == true, 'the step drawn, from the door')
    for _, vm in pairs(W.vms) do if vm.side == 'client' then vm.env.AvDoor.Settings.EXIT_ANIM.HOLD = 'position' end end
    settingsChanged()
end)

run('the clock moves inside a pass (the laptop): a move and the reads of its own pass never meet -- one turn back, no false alarm', function()
    world(function()
        W.exitPackage()
        W.vehicle(HULL, AV, 0, 0, 1.0, { halfWidth = 1.84, halfLength = 4.8 })
        W.player(1, 0, 0, 2.0, { frameMs = 100, tpsReadyMs = 2600, turnOnChaseRelease = -75 })
        W.player(2, -8, 0, 0)
    end, { 1, 2 })
    local hull = W.vehicles[HULL]
    W.players[1].clockStepMs = 0.4
    W.seat(1, HULL, 'seat_back_left')
    W.advance(1500)
    W.leave(1, { eject = false })
    W.advance(14000)
    check(W.count('turned back (', CLIENT1) == 1, ('turned back once: %d'):format(W.count('turned back (', CLIENT1)))
    check(W.logged('did not hold', CLIENT1) == nil, 'no "did not hold" from a read in the pass of the turn back')
    local played = W.locomotion.played[1]
    check(played ~= nil and yawOff(played.yaw, 75) < 1 and startOnDoor(hull, played) < 0.05 and W.clipDrawn(played) == true,
        'the step facing its heading, from the door, drawn')
    for _, hold in ipairs(holdsOf(W.players[1])) do check(hold.grounded == true, 'every hold on a body on the ground') end
end)

run('the hull drawn dragged for the exit\'s first frames: its door slot judged against the hull read again, never turned round', function()
    world(function()
        W.exitPackage()
        W.vehicle(HULL, AV, 0, 0, 1.0, { halfWidth = 1.84, halfLength = 4.8 })
        W.player(1, 0, 0, 2.0, { frameMs = 100 })
    end, { 1 })
    local hull = W.vehicles[HULL]
    W.seat(1, HULL, 'seat_back_left')
    W.advance(1500)
    -- Dragged 2.1 m west as the exit begins (engine and sample): against that
    -- frame the left door's slot reads on the RIGHT -- 'mirrored'.
    hull.drawnOffset = { x = -2.1, y = 0, z = 0 }
    hull.netOffsetFor = { [1] = { x = -2.1, y = 0, z = 0 } }
    W.after(150, function() hull.drawnOffset, hull.netOffsetFor = nil, nil end)
    W.leave(1, { eject = false })
    W.advance(10000)
    check(W.logged('draws the AV\'s door on the other side', CLIENT1) == nil, 'no door read on the other side')
    local played = W.locomotion.played[1]
    check(played ~= nil and startOnDoor(hull, played) < 0.05, 'the step from the real door')
    local ask = fromPlayer('open77_avdoor:walkout', 1, function(p) return p.clip == 'step' end)[1]
    check(ask ~= nil and ask.payload.plan.turned ~= true, 'the ask is not planned on the hull turned round')
end)

run('a server\'s move while the exit waits for its view: the clip is given up, the body left where it was moved', function()
    excaliburScene({}, function() W.players[1].tpsReadyMs = 6000 end)
    W.leave(1, { eject = false })
    W.advance(4000)
    local movedAt = W.now
    W.players[1].x, W.players[1].y = 60.0, 40.0
    W.advance(10000)
    check(W.logged('no clip -- the body was moved elsewhere', CLIENT1, 'warn') ~= nil, 'given up, and why')
    local putBack = nil
    for _, entry in ipairs(W.logs) do
        if entry.vm == CLIENT1 and entry.at >= movedAt and entry.text:find('put back on it', 1, true) then putBack = entry end
    end
    check(putBack == nil, 'never put back after the server moved it')
    check(#W.locomotion.played == 0 and math.abs(W.players[1].x - 60.0) < 0.01, 'no clip, the body where it was moved')
end)

run('a hold the host refuses: tried twice, then the clip is asked with the body free -- no long black screen', function()
    excaliburScene({}, function() W.players[1].freezeRefuse = 'player_not_ready' end)
    local leftAt = W.now
    W.leave(1, { eject = false })
    W.advance(10000)
    check(W.logged('the hold was refused twice: the clip is asked with the body free', CLIENT1, 'warn') ~= nil, 'said')
    local played = W.locomotion.played[1]
    check(played ~= nil and played.at - leftAt <= 4000 and W.clipDrawn(played) == true,
        ('the step soon after the view, drawn: %d ms'):format(played and played.at - leftAt or -1))
end)

run('two players out of one hull at once: each screen keeps its own exit\'s pictures and the other\'s, side by side', function()
    excaliburScene({ { id = 2, x = -8, y = 0 } })
    W.seat(2, HULL, 'seat_back_left')
    W.advance(1500)
    W.leave(1, { eject = false })
    W.leave(2, { eject = false })
    W.advance(14000)
    for _, id in ipairs({ 1, 2 }) do
        local sets, index = picturesOf(id)
        local own, view = 0, 0
        for set, list in pairs(sets) do
            if set:sub(1, 1) == 'o' then own = #list else view = #list end
        end
        check(#index == 2 and own == 8 and view == 4, ('player %d: its own exit\'s 8 and the other\'s 4: %d, %d (%d sets)')
            :format(id, own, view, #index))
    end
end)

run('a body moved while held: let go for the move, stands again, held again, then the step -- drawn on its feet', function()
    world(function()
        W.exitPackage()
        W.vehicle(HULL, AV, 0, 0, 1.0, { halfWidth = 1.84, halfLength = 4.8 })
        W.player(1, 0, 0, 2.0)
        W.player(2, 30, 0, 0)
    end, { 1, 2 })
    local hull = W.vehicles[HULL]
    -- This game draws the hull 1.2 m east the whole time: the server sends its
    -- own pose, and the body is moved to it -- after it was held.
    hull.drawnOffset = { x = 1.2, y = 0, z = 0 }
    hull.netOffsetFor = { [1] = { x = 1.2, y = 0, z = 0 } }
    W.seat(1, HULL, 'seat_back_left')
    W.advance(1000)
    W.leave(1, { eject = false })
    W.advance(10000)
    check(W.logged('exit clip: body let go after', CLIENT1) ~= nil and W.logged('let go for a move', CLIENT1) ~= nil,
        'the hold is let go before the body is moved')
    -- Every hold put on found the body on the ground.
    local holds, lifted = 0, 0
    for _, entry in ipairs(W.players[1].frozenLog) do
        if entry.position == true or entry.restriction == true then
            holds = holds + 1
            if entry.grounded ~= true then lifted = lifted + 1 end
        end
    end
    check(holds >= 2 and lifted == 0, ('held again only once it stood: %d hold(s), %d off the ground'):format(holds, lifted))
    local played = W.locomotion.played[1]
    check(played ~= nil and startOnDoor(hull, played) < 0.05, 'the step plays, from the server\'s door')
    check(W.clipDrawn(played) == true, 'drawn: its body on the ground the whole clip')
    local start1 = reportOf(1, 'start')
    check(start1 ~= nil and start1.grounded ~= false, 'on the ground as it begins')
    check(W.logged('OFF THE GROUND') == nil, 'nobody drew it in the air')
end)

run('a body that never stands, with the image on: put 5 cm over the ground once, then no clip -- no curtain, shown where it is (1.6.0)', function()
    excaliburScene({})
    W.leave(1, { eject = false })
    W.players[1].hoverUntil = W.now + 60000
    W.advance(20000)
    check(W.logged('exit clip step waits for the body to stand beside the door (off the ground', CLIENT1) ~= nil
        and W.logged('the image on): 1.5s and 6 looks', CLIENT1) ~= nil,
        'the wait says what the body\'s game says of it, and that the image is on')
    check(W.count('put 0.05 m over the ground under it, to land on it', CLIENT1) == 1, 'put just over the ground once')
    check(W.logged('no clip -- the body never stood on the ground', CLIENT1, 'warn') ~= nil, 'then no clip, and why')
    check(#W.locomotion.played == 0, 'no clip is played: no screen would draw it')
    local holds = 0
    for _, entry in ipairs(W.players[1].frozenLog) do if entry.position == true then holds = holds + 1 end end
    check(holds == 0, 'never held off the ground')
    check(#W.players[1].fades == 0, 'no curtain: it comes down only on a body that stands')
    check(firstVisibility(1, true) ~= nil, 'the others see the body')
end)

run('Staging, 2026-10-28, 01:54:15 and :32: both seats at 20 frames a second -- landed with the image on, held, the curtain, the step drawn from the door (1.6.0)', function()
    world(function()
        W.exitPackage()
        W.vehicle(HULL, AV, 0, 0, 1.0, { halfWidth = 1.84, halfLength = 4.8 })
        W.player(1, 0, 0, 2.0, { frameMs = 50 })
        W.player(2, -8, 0, 0)
    end, { 1, 2 })
    local hull = W.vehicles[HULL]
    for _, seat in ipairs({ 'seat_back_left', 'seat_front_left' }) do
        W.seat(1, HULL, seat)
        W.advance(1500)
        local leftAt = W.now
        local before = #W.locomotion.played
        local fadesBefore = #W.players[1].fades
        local movesBefore = #W.players[1].teleports
        W.leave(1, { eject = false })
        W.advance(12000)
        local player = W.players[1]
        local played = W.locomotion.played[before + 1]
        check(played ~= nil and W.clipDrawn(played) == true,
            ('%s: the step drawn, on a body its game has on its feet'):format(seat))
        check(played ~= nil and startOnDoor(hull, played) < 0.05 and yawOff(played.yaw, 75) < 1,
            ('%s: from the door, facing its heading'):format(seat))
        check(played ~= nil and played.at - leftAt <= 6000, ('%s: %d ms after the seat was left'):format(seat,
            played ~= nil and played.at - leftAt or -1))
        local down = nil
        for i = fadesBefore + 1, #player.fades do if player.fades[i].out == true then down = down or player.fades[i] end end
        local firstHold = nil
        for _, entry in ipairs(player.frozenLog) do
            if entry.position == true and entry.at >= leftAt then firstHold = firstHold or entry end
        end
        check(firstHold ~= nil and firstHold.grounded == true and down ~= nil and firstHold.at <= down.at,
            ('%s: held on its feet before the curtain: %s ms'):format(seat, firstHold and (firstHold.at - leftAt) or '?'))
        check(down ~= nil and down.grounded == true and down.at - leftAt <= 1500,
            ('%s: the curtain down on a standing body, before the chase camera lets go: %s ms'):format(seat,
                down and (down.at - leftAt) or '?'))
        local under = 0
        for i = movesBefore + 1, #player.teleports do if player.teleports[i].underFade then under = under + 1 end end
        check(under == 0, ('%s: nothing moved under the curtain'):format(seat))
        local back = lastFadeIn(player)
        check(back ~= nil and played ~= nil and back.at >= played.at, ('%s: the image back with the step'):format(seat))
        local start1 = reportOf(1, 'start')
        check(start1 ~= nil and start1.grounded ~= false, ('%s: its own screen reports it on its feet'):format(seat))
        W.advance(3000)
    end
    check(W.logged('never stood', CLIENT1) == nil, 'no "never stood"')
end)

run('a game that draws the AV\'s door on the other side of the hull: the step planned on the hull turned round', function()
    local hull = excaliburScene({}, function() W.vehicles[HULL].drawnTurnedFor = { [1] = true } end)
    W.leave(1, { eject = false })
    W.advance(9000)
    check(W.logged('exit clip step: this game draws the AV\'s door on the other side of the hull from the frame the exit was '
        .. 'planned on (slot door_b_01 at 1.05 across, 0.15 along)', CLIENT1, 'warn') ~= nil, 'the slot is read on the right')
    local ask = fromPlayer('open77_avdoor:walkout', 1, function(p) return p.clip == 'step' end)[1]
    check(ask ~= nil and ask.payload.plan.turned == true and ask.payload.plan.slot ~= nil
        and ask.payload.plan.slot.verdict == 'right', 'the ask says it planned on the hull turned round, its slot where that plan has it')
    check(W.logged('planned on the hull turned round, as that game draws its door', SRV) ~= nil
        and W.logged('exit clip for player 1: the plan holds', SRV) ~= nil, 'the server checks it turned the same way')
    local played = W.locomotion.played[1]
    local off, sx, sy, dx, dy = startOnDoor(hull, played, 1.45, 0.13)
    check(played ~= nil and off < 0.05, ('the step starts on the door as this game draws it: %.2f, %.2f (%.2f, %.2f)')
        :format(sx, sy, dx, dy))
    local start1 = reportOf(1, 'start')
    check(start1 ~= nil and (start1.startDoor or 9) < 0.05 and start1.slot == 'right', 'and reports it on that door')
end)

run('the hello: refused while the game loads, said again until the server answers; the exit then waits for that screen', function()
    excaliburScene({ { id = 2, x = -8, y = 0, options = { dismountMs = 1500, netReadyAt = W.now + 3600000 + 7000 } } })
    -- (excaliburScene starts its world 3600 s on: `netReadyAt` is 7 s after it.)
    local name2 = 'client:open77_avdoor:2'
    check(W.logged('hello to the server not sent (network_unavailable; try 1, the resource started)', name2) ~= nil,
        'the first hello is refused while the game loads, and said')
    W.advance(9000)
    check(W.logged('the server heard this client\'s hello (try ', name2) ~= nil, 'a later one is heard and answered')
    check(W.logged('player 2\'s client said hello (try ', SRV) ~= nil, 'the server says it heard it')
    W.leave(1, { eject = false })
    W.advance(9000)
    check(W.logged('exit 1 of player 1 (seat_front_left of 4294967297): 1 other screen(s) draw it: player 2 (', SRV) ~= nil,
        'the exit waits for player 2\'s screen')
end)

run('a hello lost on the way: the screen is told all the same, its word is its hello, and the next exit waits for it', function()
    excaliburScene({ { id = 2, x = -8, y = 0, options = { dismountMs = 1500 } } },
        function() W.dropHello = { [2] = true } end)
    W.advance(60000)
    check(W.droppedHellos >= 20, 'every hello of player 2 is lost: ' .. tostring(W.droppedHellos))
    check(W.logged('the server has not answered this client\'s hello in', 'client:open77_avdoor:2', 'warn') ~= nil,
        'after twenty tries the client warns that no exit waits for it')
    W.leave(1, { eject = false })
    W.advance(9000)
    check(W.logged('exit 1 of player 1 (seat_front_left of 4294967297): no screen near it is waited for; not waited for (no '
        .. 'open77_avdoor client said hello): player 2 (8 m) -- told all the same', SRV) ~= nil, 'player 2 is told, not waited for')
    check(#fromPlayer('open77_avdoor:sceneReady', 2) == 1, 'its screen answers the exit')
    check(W.logged('exit 1 of player 1: player 2\'s client answered the exit without having said hello: taken as its hello',
        SRV) ~= nil, 'and its word is taken as its hello')
    check(reportOf(2, 'start') ~= nil and W.logged('4 of 4 report(s)', SRV) ~= nil, 'its reports are waited for')
    W.seat(1, HULL, 'seat_front_left')
    W.advance(1500)
    W.leave(1, { eject = false })
    W.advance(9000)
    check(W.logged('exit 2 of player 1 (seat_front_left of 4294967297): 1 other screen(s) draw it: player 2 (', SRV) ~= nil,
        'the next exit waits for player 2\'s screen')
end)

run('the logger: a screen that draws the body turned, in the air, armed, from stale movement and without the step', function()
    excaliburScene({ { id = 2, x = -8, y = 0, options = { dismountMs = 800 } } }, function()
        W.players[1].drawnFor[2] = { yaw = 246, grounded = false, weapon = true, ageMs = 900, noClip = true }
    end)
    W.leave(1, { eject = false })
    W.advance(9000)
    local wrongs = {
        'drew player 1 facing 246 deg, 171 deg off the step\'s 75: the step\'s path is turned with it',
        'drew player 1 off the ground (falling): the platform plays no clip on a body in the air',
        'drew player 1 with a weapon drawn: the platform plays no clip then',
        'drew player 1 from movement 900 ms old: the platform plays no clip on stale movement',
        'drew no step: player 1\'s hips stood on its feet\'s point 0.2s into it (the clip was not drawn there)',
        'm from the door as it drew player 1 and the AV',
    }
    for _, text in ipairs(wrongs) do check(W.logged(text, SRV, 'warn') ~= nil, 'WRONG: ' .. text) end
    check(W.logged('no step drawn: the body\'s hips stand on its feet\'s point', 'client:open77_avdoor:2', 'warn') ~= nil,
        'player 2\'s own log says it too')
    local start1 = reportOf(1, 'start')
    check(start1 ~= nil and (start1.yawOff or 9) < 1, 'the exiting screen itself drew it right')
end)

run('the exit is seen at its first frame: the body put beside the door within a few frames, with the image on (1.6.0)', function()
    excaliburScene({}, function() W.players[1].frameMs = 16 end)
    W.advance(500)
    local leftAt = W.now
    W.leave(1, { eject = false })
    W.advance(200)
    check(#W.players[1].fades == 0, 'no cut to black at the exit (the native fade would hold the body where it is put)')
    local placed = W.players[1].teleports[1]
    check(placed ~= nil and placed.at - leftAt <= 120 and placed.underFade == false,
        ('put beside the door %d ms after the seat was let go, the image on'):format(placed and placed.at - leftAt or -1))
    check(W.logged('exit from 4294967297 (seat_front_left) seen at its first frame', CLIENT1) ~= nil
        and W.logged('the image on, the body', CLIENT1) ~= nil, 'and says so, with the screen and the body')
end)

run('without vehicles.nearby the watch walks the vehicle list in slices', function()
    world(function()
        W.vehicle(HULL, AV, 0, 50, 1.5)
        for i = 1, 40 do W.vehicle(HULL + i, CAR, i * 3, -40, 0.5) end
        W.player(2, 0, 0, 0)
    end, {})
    local vm = W.client(2, 'open77_avdoor', ROOT, CLIENT)
    vm.env.Open77.vehicles.nearby = nil
    W.vehicles[HULL].drawnOffset = { x = 30, y = 0, z = 0 }
    W.advance(2500)
    check(W.logged('sight: aircraft 4294967297 is drawn 30.0 m', 'client:open77_avdoor:2') ~= nil,
        'the drift is still seen')
end)

run('a pilot who climbs back out of the descent band calls the landing off', function()
    world(function()
        W.vehicle(HULL, MAXTAC, 0, 0, 1.5)
        W.player(1, 0, 0, 2.5)
        W.seat(1, HULL, 'seat_front_left')
    end, { 1 })
    W.advance(500)
    fly(HULL, 45, 5000)
    fly(HULL, 20, 4000)
    check(server.env.AvDoor.Callout.IsLive(HULL), 'the call is up')
    fly(HULL, 60, 6000)
    local abort = W.sent('open77_avdoor:sound', function(e) return e.payload.which == 'abort' end)
    check(#abort == 1, 'abort is reported once')
    W.advance(600)
    check(not server.env.AvDoor.Callout.IsLive(HULL), 'the call ended')
    check(W.logged('landing call of 4294967297 (maxtac): abort', 'server:open77_avdoor') ~= nil, 'as an abort')
end)


run('a player-flown MaxTac AV speaks for everybody in range, and the landing call follows its descent', function()
    world(function()
        W.vehicle(HULL, MAXTAC, 0, 0, 1.5)
        W.player(1, 0, 0, 2.5)
        W.player(2, 60, 0, 0, { locale = { code = 'fr-FR', gameLanguage = 'fr-fr', voiceLanguage = 'fr-fr' } })
        W.player(3, 500, 0, 0)
        W.seat(1, HULL, 'seat_front_left')
    end, { 1, 2, 3 })
    W.advance(500)
    fly(HULL, 40, 4000)
    local takeoff = W.sent('open77_avdoor:sound', function(e) return e.payload.which == 'takeoff' end)
    check(#takeoff == 1, 'the pilot\'s client reports the take-off once')
    local plays = W.sent('open77_avdoor:play', function(e) return e.payload.which == 'takeoff' end)
    local to = {}
    for _, e in ipairs(plays) do to[e.target] = e.payload end
    check(to[1] ~= nil and to[2] ~= nil and to[3] == nil, 'sent to the pilot and to player 2, not to player 3 500 m away')
    check(to[1] ~= nil and to[1].event == 'av_maxtac_start_ascent', 'the base game\'s own ascent event')
    local played = W.players[2].sfx[1]
    check(played ~= nil and played.event == 'av_maxtac_start_ascent' and played.options.entity == 'veh:' .. HULL_TEXT
        and played.options.emitter == 'vehicle_general_emitter', 'played on the airframe\'s own emitter')
    check(W.logged('player 2 heard av_maxtac_start_ascent', 'server:open77_avdoor') ~= nil, 'the listener answered')
    -- Down again: under 30 m, sinking faster than 1.5 m/s.
    fly(HULL, 20, 4000)
    local descent = W.sent('open77_avdoor:sound', function(e) return e.payload.which == 'descent' end)
    check(#descent == 1, 'the descent is reported once')
    local calls = W.sent('open77_avdoor:call', function(e) return e.payload.on == true end)
    local callTo = {}
    for _, e in ipairs(calls) do callTo[e.target] = e.payload end
    check(callTo[1] ~= nil and callTo[2] ~= nil and callTo[3] == nil, 'the landing call is told within 300 m')
    check(callTo[1] ~= nil and callTo[1].kind == 'maxtac', 'the MaxTac line')
    local englishOn, frenchOn = nil, nil
    for _, a in pairs(W.players[1].audio) do englishOn = a end
    for _, a in pairs(W.players[2].audio) do frenchOn = a end
    check(englishOn ~= nil and englishOn.asset == 'audio/av-callout-maxtac.wav' and englishOn.options.loop == true,
        'the pilot hears it in English, looped')
    check(frenchOn ~= nil and frenchOn.asset == 'audio/av-callout-maxtac-fr.mp3', 'player 2 in French')
    -- The touchdown: within 7 m of the ground and still for 750 ms.
    fly(HULL, 1.5, 6000)
    W.advance(1500)
    local touchdown = W.sent('open77_avdoor:sound', function(e) return e.payload.which == 'touchdown' end)
    check(#touchdown == 1, 'the touchdown is reported once')
    local ended = W.sent('open77_avdoor:call', function(e) return e.payload.on == false end)
    check(#ended >= 2 and ended[1].payload.fadeMs == 400, 'the call fades out on every game that had it')
    W.advance(600)
    check(next(W.players[1].audio) == nil and next(W.players[2].audio) == nil, 'and is released')
    check(W.logged('landing call of 4294967297 (maxtac) ended: touchdown', 'server:open77_avdoor') ~= nil,
        'the server says why it ended')
end)

run('a listener whose game refused the sound is given it through the platform\'s fan-out', function()
    world(function()
        W.vehicle(HULL, MAXTAC, 0, 0, 1.5)
        W.player(1, 0, 0, 2.5)
        W.player(2, 60, 0, 0)
        W.player(3, 80, 0, 0)
        W.seat(1, HULL, 'seat_front_left')
    end, { 1, 2, 3 })
    W.players[2].refuseSfx = true
    W.advance(500)
    fly(HULL, 40, 4000)
    local rescued = W.sounds[1]
    check(rescued ~= nil and rescued.event == 'av_maxtac_start_ascent' and rescued.target.kind == 'vehicle'
        and rescued.target.id == HULL_TEXT, 'the platform plays it on the hull')
    local excluded = {}
    for _, id in ipairs(rescued and rescued.options.excludePlayers or {}) do excluded[id] = true end
    check(excluded[1] and excluded[3] and not excluded[2], 'for player 2 alone: everybody else is excluded')
    check(#W.sounds == 1, 'rescued once, not for the listeners that played it')
    check(W.logged('player 2 could not play av_maxtac_start_ascent', 'server:open77_avdoor') ~= nil, 'in the log')
end)

run('a flight sound is only relayed for a body seated in that hull, and once per floor', function()
    world(function()
        W.vehicle(HULL, MAXTAC, 0, 0, 1.5)
        W.vehicle(HULL + 1, MAXTAC, 50, 0, 1.5)
        W.player(1, 0, 0, 2.5)
        W.player(2, 10, 0, 0)
        W.seat(1, HULL, 'seat_front_left')
    end, {})
    local M = server.env.AvDoor
    check(M.Speak(2, { id = HULL_TEXT, which = 'takeoff' }) == 0, 'a stranger on foot speaks for no flight')
    check(M.Speak(1, { id = tostring(HULL + 1), which = 'takeoff' }) == 0, 'nor a pilot for another hull')
    check(M.Speak(1, { id = HULL_TEXT, which = 'explode' }) == 0, 'nor for a moment the AV has no voice for')
    check(M.Speak(1, { id = HULL_TEXT, which = 'touchdown' }) >= 1, 'the pilot speaks for their own')
    check(M.Speak(1, { id = HULL_TEXT, which = 'touchdown' }) == 0, 'once per six seconds')
end)

run('a resource that flies an AV itself calls, follows, hushes, and its stop ends the call', function()
    world(function()
        W.vehicle(HULL, TRAUMA, 0, 0, 60)
        W.player(1, 40, 0, 0)
        W.player(2, 900, 0, 0)
    end, { 1, 2 })
    W.invoker = 'rescue_team'
    local ok, why = server.exports.callout(HULL, nil, 'a rescue', { x = 0, y = 0, z = 60, bucket = 0 })
    W.invoker = nil
    check(ok == true, 'the call starts: ' .. tostring(why))
    W.run()
    local told = W.lastTo('open77_avdoor:call', 1)
    check(told ~= nil and told.payload.kind == 'trauma', 'the Trauma Team line, by its record')
    check(W.lastTo('open77_avdoor:call', 2) == nil, 'nobody 900 m away is told')
    local playing = nil
    for _, a in pairs(W.players[1].audio) do playing = a end
    check(playing ~= nil and playing.asset == 'audio/av-callout-trauma.wav', 'player 1 plays it')
    check(server.exports.follow(HULL, { x = 0, y = 10, z = 50 }) == true, 'follow moves the point')
    check(server.exports.follow(HULL, { x = 0, y = 10.1, z = 50 }) == false, 'not for 10 cm')
    local again = server.exports.callout(HULL, nil, 'again')
    check(again == true, 'a second call on a calling hull is the same call')
    check(server.exports.hush(HULL, 'landed') == true, 'hushed')
    W.advance(500)
    check(next(W.players[1].audio) == nil, 'faded out and released on the game')
    W.invoker = 'rescue_team'
    server.exports.callout(HULL, 'maxtac', 'another', { x = 0, y = 0, z = 60, bucket = 0 })
    W.invoker = nil
    W.run()
    server.fire('onResourceStop', 'rescue_team', 'manual')
    W.run()
    check(server.env.AvDoor.Callout.IsLive(HULL) == false, 'the caller stopped: the call ended')
    local cut = W.lastTo('open77_avdoor:call', 1)
    check(cut ~= nil and cut.payload.on == false and cut.payload.fadeMs == 0, 'cut at once on the game')
    local _, none = server.exports.callout(HULL + 77, nil, 'nothing')
    check(none == 'no_hull', 'no hull, no call: ' .. tostring(none))
end)

run('a call that never hears its touchdown ends at MAX_SECONDS, and six calls at most', function()
    world(function()
        for i = 0, 7 do W.vehicle(HULL + i, MAXTAC, i * 30, 0, 60) end
        W.player(1, 0, 0, 0)
    end, { 1 })
    for i = 0, 5 do check(server.exports.callout(HULL + i, nil, 'a run') == true, 'call ' .. i) end
    local _, why = server.exports.callout(HULL + 6, nil, 'one too many')
    check(why == 'too_many_calls', 'a seventh is refused: ' .. tostring(why))
    W.advance(91000)
    check(#server.env.AvDoor.Callout.Status() == 0, 'every call ended after 90 s')
    check(W.logged('no touchdown in MAX_SECONDS', 'server:open77_avdoor') ~= nil, 'and why')
end)

-- ── the landing pad ──────────────────────────────────────────────────────────

run('the landing pad: a Trauma AV gets its dust and voice as it comes down (no old beams), a MaxTac AV only measured', function()
    world(function()
        W.vehicle(HULL, TRAUMA, 0, 0, 30, { engineOn = true })
        W.vehicle(HULL + 1, MAXTAC, 100, 0, 1.5)
        W.player(1, 20, 0, 0)
        W.player(2, 600, 0, 0)
    end, { 1, 2 })
    W.invoker = 'rescue_team'
    local ok = server.exports.pad(HULL, { why = 'a rescue' })
    local none, why = server.exports.pad(HULL + 1, {})
    W.invoker = nil
    check(ok == true, 'the Trauma AV has a pad')
    check(none == nil and why == 'platform', 'the client pads a MaxTac AV itself')
    W.run()
    local toldOne = W.sent('open77_avdoor:pad', function(e) return e.target == 1 and e.payload.id == HULL_TEXT end)
    check(#toldOne == 1 and toldOne[1].payload.on == true and toldOne[1].payload.platform == false, 'player 1 is told')
    local measured = W.sent('open77_avdoor:pad', function(e) return e.target == 1 and e.payload.id == tostring(HULL + 1) end)
    check(#measured == 1 and measured[1].payload.platform == true, 'and told the MaxTac AV is only to be measured')
    check(W.lastTo('open77_avdoor:pad', 2) == nil, 'player 2 is too far')
    W.advance(200)
    local beams = 0
    for _ in pairs(W.players[1].vfx) do beams = beams + 1 end
    check(beams == 0, 'nothing while the hull is 30 m up')
    -- Coming down within 6 m of the ground.
    for z = 30, 4, -1 do
        W.vehicles[HULL].z = z
        W.advance(100)
    end
    beams = 0
    local dust = 0
    for _, effect in pairs(W.players[1].vfx) do
        if effect.effect == 'laser.mine' then beams = beams + 1 else dust = dust + 1 end
    end
    check(beams == 0, 'no beams: the ring, its marker and the dot sign are off -- open77_avlanding\'s sign marks the '
        .. 'spot ("i want the old one removed"): ' .. beams)
    check(dust == 1, 'the dust under the hull')
    check(W.logged('no beams (RING and SIGN off: the landing sign marks it), the dust and the voice',
        'client:open77_avdoor:1') ~= nil, 'the pad says what it draws')
    local voice = W.players[1].sfx[1]
    check(voice ~= nil and voice.event == 'v_av_trauma_big_engine_start', 'the engine\'s voice')
    -- A newcomer is told on the next pass.
    W.players[2].x = 30
    W.advance(1100)
    check(W.lastTo('open77_avdoor:pad', 2) ~= nil, 'a newcomer is told')
    check(server.exports.unpad(HULL, 'landed') == true, 'taken away')
    W.advance(100)
    check(next(W.players[1].vfx) == nil, 'every beam and the dust are gone')
    check(W.logged('mesh 5.0 x 10.0 x 3.0 m', 'client:open77_avdoor:1') ~= nil
        or W.logged('mesh', 'client:open77_avdoor:1') ~= nil, 'the hull\'s mesh is measured')
end)

-- ── where an AV may come down ────────────────────────────────────────────────

--- Runs an export that waits, from a thread of the server VM, as
--- `Open77.exports.call` would.
local function survey(target, options)
    local result = nil
    server.env.CreateThread(function()
        result = table.pack(server.exports.landingSite(target, options))
    end)
    W.advance(8000)
    return result and result[1], result and result[2]
end

run('the landing site is ground, at the target\'s level, flat and found from the games', function()
    world(function()
        W.player(1, 0, 0, 0)
    end, {})
    check(server.exports.canSurvey() == true, 'the host can be asked')
    check(server.exports.surveyBudgetMs() == 5500, 'four seconds and one probe')
    local site, why = survey({ x = 0, y = 0, z = 0 }, { bearing = 0, near = 10 })
    check(site ~= nil and math.abs(site.distance - 10) < 0.01 and site.probes == 5, 'the first place: ' .. tostring(why))
    check(site ~= nil and site.observer == 1, 'measured by player 1')
    -- Water in front: the next bearing.
    W.groundAt = function(x, y) if y > 5 then return nil end return 0.0 end
    site, why = survey({ x = 0, y = 0, z = 0 }, { bearing = 90, near = 10 })
    check(site ~= nil and site.y <= 5, 'not on the water: ' .. tostring(why))
    -- A roof over everything near: nowhere at the target's level within 40 m.
    W.groundAt = function() return 12.0 end
    site, why = survey({ x = 0, y = 0, z = 0 }, { near = 10 })
    check(site == nil and tostring(why):find('no flat open ground', 1, true) ~= nil, 'no level ground: ' .. tostring(why))
    W.groundAt = nil
    site, why = survey({ x = 2000, y = 0, z = 0 }, {})
    check(site == nil and tostring(why):find('no_observer', 1, true) ~= nil, 'nobody near: ' .. tostring(why))
end)

run('a game that never answers is passed over for one that does', function()
    world(function()
        W.player(1, 5, 0, 0)    -- a headless bot, nearest
        W.player(2, 50, 0, 0)   -- a real game
    end, {})
    W.observerDown[1] = true
    local site, why = survey({ x = 0, y = 0, z = 0 }, { near = 10 })
    check(site ~= nil and site.observer == 2, 'measured by the game that answers: ' .. tostring(why))
    local again = survey({ x = 0, y = 0, z = 0 }, { near = 10 })
    check(again ~= nil and again.observer == 2, 'the silent one is not asked first again')
end)

-- ── the watch ────────────────────────────────────────────────────────────────

run('the watch: hands, jumps, and a viewer\'s sight, healed for an empty hull only', function()
    world(function()
        W.vehicle(HULL, AV, 0, 0, 1.5, { heading = 90 })
        W.player(2, 60, 0, 0)
    end, { 2 })
    for i = 1, 8 do W.hostEvent('onVehicleAuthorityChanged', HULL_TEXT, tostring(i % 2), tostring(10 + i), 'lease') end
    W.run()
    check(W.count('authority: aircraft 4294967297 is simulated by', 'server:open77_avdoor') == 6,
        'six lines a window, not eight')
    W.vehicles[HULL].x = 80
    W.advance(600)
    check(W.logged('jump: aircraft 4294967297 moved 80.0 m', 'server:open77_avdoor') ~= nil, 'a canonical jump')
    W.vehicles[HULL].x = 0
    W.advance(600)
    -- Player 2's game draws the hull 25 m from its sample.
    W.vehicles[HULL].drawnOffset = { x = 25, y = 0, z = 0 }
    W.advance(1200)
    check(W.logged('sight: aircraft 4294967297 is drawn 25.0 m', 'client:open77_avdoor:2') ~= nil, 'the client sees it')
    check(W.logged('sight: player 2 draws aircraft 4294967297 25.0 m', 'server:open77_avdoor') ~= nil,
        'the server writes it beside its own reads')
    local transforms = W.vehicles[HULL].transforms
    check(#transforms == 1 and transforms[1].x == 0 and transforms[1].yaw == 90 and transforms[1].hadYaw,
        'healed: re-published where the server has it, heading kept')
    W.advance(3000)
    check(#W.vehicles[HULL].transforms == 1, 'once per ten seconds')
    W.vehicles[HULL].drawnOffset = nil
    W.advance(1500)
    check(W.logged('draws aircraft 4294967297 where the server has it again', 'server:open77_avdoor') ~= nil,
        'the episode closes')
    -- With somebody aboard, never touched.
    W.player(1, 0, 0, 2.5)
    W.seat(1, HULL, 'seat_front_left')
    W.vehicles[HULL].physicsOwner = 1
    W.now = W.now + 20000
    W.vehicles[HULL].drawnOffset = { x = 30, y = 0, z = 0 }
    W.advance(1500)
    check(#W.vehicles[HULL].transforms == 1, 'a hull with a pilot aboard is never re-published')
    local M = server.env.AvDoor
    check(M.Watch.Sight(2, { state = 'open', id = '123', drawn = { x = 0, y = 0, z = 0 } }) == 'ignored',
        'a hull the server did not list is ignored')
    check(M.Watch.Sight(2, { state = 'open', id = HULL_TEXT, drawn = { x = 1e9, y = 0, z = 0 } }) == 'ignored',
        'a point outside the world is ignored')
    check(M.Watch.Sight(0, { state = 'open', id = HULL_TEXT, drawn = { x = 0, y = 0, z = 0 } }) == 'ignored',
        'the console reports nothing')
end)

-- ── the console, the card's fallbacks, and the stop ──────────────────────────

run('the console: why the nearest door is open or shut, and the status', function()
    world(function()
        W.vehicle(HULL, AV, 0, 0, 1.5)
        W.player(1, 4, 0, 0)
        W.player(2, 30, 0, 0)
    end, {})
    local why = server.commands['avdoor.why']
    check(why ~= nil and why.restricted == false, 'avdoor.why is for every player')
    check(server.commands['avdoor.status'] ~= nil and server.commands['avdoor.status'].restricted == true,
        'avdoor.status is restricted')
    why.fn(1, {}, 'avdoor.why')
    check(W.logged('the door is OPEN to you as pilot, seat seat_front_left -- press F', 'server:open77_avdoor') ~= nil,
        'open, and how')
    why.fn(2, {}, 'avdoor.why')
    check(W.logged('the door is SHUT to you -- too_far', 'server:open77_avdoor') ~= nil, 'shut, and why')
    why.fn(0, {}, 'avdoor.why')
    check(W.logged('the console has no body to measure', 'server:open77_avdoor') ~= nil, 'the console has no body')
    server.commands['avdoor.status'].fn(0, {}, 'avdoor.status')
    check(W.logged('open77_avdoor: 0 door(s) open', 'server:open77_avdoor') ~= nil, 'the status line')
    local result = W.sent('open77:command:result')
    check(#result == 2, 'the two players are answered in their console, the server console is not: ' .. #result)
end)

run('the card hangs on the server\'s position when the hull cannot anchor it', function()
    world(function()
        W.vehicle(HULL, AV, 0, 0, 1.5)
        W.player(1, 4, 0, 0)
    end, {})
    W.players[1].refuseEntityCards = true
    W.client(1, 'open77_avdoor', ROOT, CLIENT)
    W.advance(1200)
    local cards = W.cards(1)
    check(#cards == 1 and cards[1].position ~= nil and cards[1].position.x == 0 and cards[1].entity == nil,
        'one card, on the position')
    check(W.count('could not hang on the hull', 'client:open77_avdoor:1') == 1, 'said once')
    W.advance(2000)
    check(#W.cards(1) == 1, 'and no churn after it')
    check(W.press(1, 'F'), 'the key still works')
end)

run('stopping the resource takes every card, door, pad and call down', function()
    world(function()
        W.vehicle(HULL, AV, 0, 0, 1.5)
        W.vehicle(HULL + 1, TRAUMA, 30, 0, 3)
        W.player(1, 4, 0, 0)
        W.player(2, 0, 0, 2.5)
        W.seat(2, HULL, 'seat_front_left')
    end, { 1, 2 })
    W.advance(200)
    server.exports.callout(HULL + 1, nil, 'a run')
    server.exports.pad(HULL + 1, {})
    W.leave(2, { eject = false })
    W.advance(300)
    check(W.vehicles[HULL].doors.trunk == true, 'a door is open (the Excalibur\'s, swung by the trunk)')
    W.stop(server)
    check(W.vehicles[HULL].doors.trunk == false, 'the door this resource opened is closed')
    local last = door(1)
    check(last ~= nil and last.open == false, 'the card is taken down')
    local cut = W.lastTo('open77_avdoor:call', 1)
    check(cut ~= nil and cut.payload.on == false and cut.payload.fadeMs == 0, 'the call is cut')
    local pad = W.lastTo('open77_avdoor:pad', 1)
    check(pad ~= nil and pad.payload.on == false, 'the pad is taken away')
    -- The client resource stops too: its card goes, and a fade in progress ends.
    for _, vm in pairs(W.vms) do if vm.playerId == 2 then W.stop(vm) break end end
    check(W.players[2].covered == nil, 'no screen is left covered')
end)

run('a server that also runs XyberRP\'s opx_infinity is warned: one door per server', function()
    world(function()
        W.resourceStates.opx_infinity = 'started'
        W.vehicle(HULL, AV, 0, 0, 1.5)
    end, {})
    check(W.logged('opx_infinity runs on this server too', 'server:open77_avdoor') ~= nil, 'the warning')
end)

if W.budgetHot ~= nil and W.budgetHeavy ~= nil then
    table.sort(W.budgetHeavy, function(a, b) return a.count > b.count end)
    local shown = {}
    for _, heavy in ipairs(W.budgetHeavy) do
        if not shown[heavy.origin] or #shown < 6 then
            shown[heavy.origin] = true
            shown[#shown + 1] = true
            if #shown > 8 then break end
            print(('== a resume of %d from %s (%s)'):format(heavy.count, heavy.origin, tostring(heavy.case)))
            local rows = {}
            for key, n in pairs(heavy.fns) do rows[#rows + 1] = { key = key, n = n } end
            table.sort(rows, function(a, b) return a.n > b.n end)
            for i = 1, math.min(#rows, 18) do print(('   %6d  %s'):format(rows[i].n, rows[i].key)) end
        end
    end
end
-- ── the ground test (1.5.3) ───────────────────────────────────────────────────
-- ── the exit's drag (1.6.1) ──────────────────────────────────────────────────

--- An Excalibur flown `metres` north off its spawn pad with player 1 at the
--- controls, landed, its chassis left on the pad on player 1's game.
local function flownOffPad(metres, setup)
    world(function()
        W.exitPackage()
        W.vehicle(HULL, AV, 0, 0, 1.0, { halfWidth = 1.84, halfLength = 4.8 })
        W.player(1, 0, 0, 2.0)
        if setup ~= nil then setup() end
    end, { 1 })
    local hull = W.vehicles[HULL]
    W.seat(1, HULL, 'seat_front_left')
    W.advance(1000)
    for _ = 1, metres do
        hull.y = hull.y + 1.0
        W.players[1].y = W.players[1].y + 1.0
        W.advance(200)
    end
    W.advance(1500)
    hull.padFor = { [1] = { x = 0, y = 0 } }
    return hull
end

--- Player 1 in the back seat, alone: its game simulates the hull (a lease
--- of its own, its first since boarding).
local function backSeat(hull)
    -- Out of the pilot's seat (a move inside the hull, nothing of an exit).
    for seat, id in pairs(hull.seats) do if id == 1 then hull.seats[seat] = nil end end
    W.seat(1, HULL, 'seat_back_left')
    hull.physicsOwner, hull.epoch = 1, hull.epoch + 1
    W.advance(2000)
end

run('Staging, 2026-10-28, 13:20:09 and 13:20:43: an Excalibur flown 14 m off its pad -- every exit drags the body back to the pad with the hull, and the server took the drag for the hull\'s pose; both exits step out of the real door, the AV stays where it stood', function()
    local hull = flownOffPad(14)
    -- THE PILOT'S EXIT: the body dragged to the pad, 13 m off.
    W.leave(1, { eject = false })
    W.advance(12000)
    local first = W.locomotion.played[1]
    check(first ~= nil and startOnDoor(hull, first) < 0.05 and W.clipDrawn(first) == true,
        'the pilot\'s exit: the step from the real door, drawn')
    check(W.logged('the drag told to the server', CLIENT1) ~= nil or #fromPlayer('open77_avdoor:drag', 1) >= 1,
        'the pilot\'s drag told to the server')
    check(math.abs(hull.x) < 0.01 and math.abs(hull.y - 14.0) < 0.01, 'the AV where it landed')
    -- THE BACK SEAT'S EXIT (the one that failed): 15 m off, past NEAR_METRES,
    -- and the server takes the dragged pose for the hull's.
    backSeat(hull)
    hull.dragTaken = true
    W.leave(1, { eject = false })
    W.advance(1500)
    local name = CLIENT1
    check(W.players[1].dragged ~= nil and hull.dragTakenAt ~= nil, 'the exit dragged the body, and the server took the drag')
    check(W.logged('carried along by the engine\'s drag of the hull back toward where its flight began', name) ~= nil
        and W.logged('an exit all the same', name) ~= nil, 'the client: an exit all the same, and why')
    check(W.logged('a move made elsewhere', name) == nil, 'never "a move made elsewhere"')
    local said = fromPlayer('open77_avdoor:drag', 1)
    check(#said >= 2 and math.abs(said[#said].payload.engine.y) < 1.0 and math.abs(said[#said].payload.real.y - 14.0) < 0.1,
        'the drag told to the server: drawn on the pad, standing 14 m north')
    check(W.logged('drag: aircraft 4294967297 put back where it stood when player 1 stepped out (0.0, 14.0', SRV) ~= nil,
        'the server put the hull back where it stood')
    W.advance(12000)
    check(math.abs(hull.x) < 0.05 and math.abs(hull.y - 14.0) < 0.05,
        ('the AV where it stood, not on its pad: %.1f, %.1f'):format(hull.x, hull.y))
    check(W.logged('re-published where the server has it (0.0, 0.0', SRV) == nil, 'never re-published on the pad')
    local second = W.locomotion.played[2]
    check(second ~= nil and startOnDoor(hull, second) < 0.05 and W.clipDrawn(second) == true,
        'the back seat\'s exit: the step from the real door, drawn')
    check(second ~= nil and math.sqrt((W.players[1].x - second.x) ^ 2 + (W.players[1].y - second.y) ^ 2) < 0.05,
        'the body where the step ends')
    for _, hold in ipairs(holdsOf(W.players[1])) do check(hold.grounded == true, 'every hold on a body on the ground') end
    check(#W.problems(CLIENT1) == 0, 'nothing went wrong: ' .. table.concat(W.problems(CLIENT1), ' | '))
end)

run('Staging, 2026-10-28, 13:21:39: the network\'s frame on the pad too at the exit\'s first look (this game\'s own dragged sample) -- the hull is where it flew, the drag told; the server that took it puts it back', function()
    local hull = flownOffPad(11)
    hull.dragTaken = true
    W.leave(1, { eject = false, netDrag = true })
    W.advance(1500)
    check(W.logged('using the frame it flew at', CLIENT1) ~= nil, 'the frame it flew at is the hull')
    check(W.logged('the engine\'s drag of the hull told to the server', CLIENT1) ~= nil, 'the drag told')
    check(W.logged('drag: aircraft 4294967297 put back where it stood when player 1 stepped out (0.0, 11.0', SRV) ~= nil,
        'the server put the hull back')
    W.advance(12000)
    local played = W.locomotion.played[1]
    check(played ~= nil and startOnDoor(hull, played) < 0.05 and W.clipDrawn(played) == true, 'the step from the real door')
    check(math.abs(hull.y - 11.0) < 0.05, ('the AV where it stood: %.1f'):format(hull.y))
end)

run('the exit\'s drag gone by between two frames (a slow game): the body left on the pad this game learnt at its first boarding -- an exit, stepped out of the real door', function()
    local hull = flownOffPad(14)
    backSeat(hull)
    W.leave(1, { eject = false, dragMs = 0 })
    W.advance(1500)
    check(W.logged('at the pad this game\'s engine keeps for the hull (where it stood when first boarded here)', CLIENT1)
        ~= nil, 'the body at the pad: an exit')
    check(W.logged('a move made elsewhere', CLIENT1) == nil, 'never "a move made elsewhere"')
    W.advance(12000)
    local played = W.locomotion.played[1]
    check(played ~= nil and startOnDoor(hull, played) < 0.05 and W.clipDrawn(played) == true, 'the step from the real door')
end)

run('the exit\'s drag: a hull the server has moved anywhere but the drag is left alone', function()
    local hull = flownOffPad(14)
    backSeat(hull)
    W.leave(1, { eject = false })
    W.advance(150)
    -- Another resource moves the empty hull 40 m east inside the drag's window.
    hull.x = 40.0
    W.advance(3000)
    check(math.abs(hull.x - 40.0) < 0.01, 'the hull stays where it was moved')
    check(W.logged('not where that game\'s engine dragged it', SRV) ~= nil, 'and that is said')
    check(W.logged('put back where it stood', SRV) == nil, 'never put back')
end)

run('the exit\'s drag with no word of it from the exiting game: the hull the server took the drag for, drawn where it stood by a viewer, is put back -- never healed onto the pad', function()
    local hull = flownOffPad(14, function() W.player(2, -10, 14, 0) end)
    -- Player 2 is a viewer near the AV, its game not the hull's: it draws the
    -- hull where the server has it, and says so when the two part.
    backSeat(hull)
    hull.dragTaken = true
    W.lostToServer = { ['open77_avdoor:drag'] = true }
    W.leave(1, { eject = false })
    W.advance(4000)
    check(hull.dragTakenAt ~= nil, 'the server took the drag')
    check(W.logged('drag: aircraft 4294967297 put back where it stood when player 1 stepped out (0.0, 14.0', SRV) ~= nil,
        'put back where it stood, on a viewer\'s word and the server\'s own scans')
    check(W.logged('re-published where the server has it (0.0, 0.0', SRV) == nil, 'never healed onto the pad')
    W.advance(10000)
    check(math.abs(hull.x) < 0.05 and math.abs(hull.y - 14.0) < 0.05,
        ('the AV where it stood: %.1f, %.1f'):format(hull.x, hull.y))
    local played = W.locomotion.played[1]
    check(played ~= nil and startOnDoor(hull, played) < 0.05, 'and the step from the real door')
end)

run('the exit\'s drag: a body the server takes out of its seat and 300 m away is a move, pad or not -- nothing placed, no drag told', function()
    world(function()
        W.vehicle(HULL, AV, 0, 0, 1.5)
        W.player(1, 0, 0, 2.5)
    end, { 1 })
    W.seat(1, HULL, 'seat_front_left')
    W.advance(1500)
    local vehicle, player = W.vehicles[HULL], W.players[1]
    vehicle.seats.seat_front_left = nil
    player.seat = nil
    player.x = 300
    W.hostEvent('onVehicleOccupancyChanged', HULL_TEXT, 99)
    W.advance(1500)
    check(W.logged('a move made elsewhere, not an exit', CLIENT1) ~= nil and #player.teleports == 0, 'a move: nothing placed')
    check(#fromPlayer('open77_avdoor:drag', 1) == 0, 'no drag told')
end)

run('Staging, 2026-10-28, 14:41:26: the ground falls away gently beside the door -- the step 0.92 m up, past the clip\'s 0.85 m by 7 cm and no turn better: played within the relaxed reach, from the door (1.6.2)', function()
    world(function()
        W.exitPackage()
        -- 0.30 m lower from 2 m west of the hull's centre: under the end point,
        -- whichever way the step turns, never under the gear.
        W.groundAt = function(x) return x < -2.0 and -0.30 or 0.0 end
        W.vehicle(HULL, AV, 0, 0, 1.0, { halfWidth = 1.84, halfLength = 4.8 })
        W.player(1, 0, 0, 2.0)
        W.player(2, 30, 0, 0)
    end, { 1, 2 })
    local hull = W.vehicles[HULL]
    W.seat(1, HULL, 'seat_back_left')
    W.advance(1000)
    W.leave(1, { eject = false })
    W.advance(12000)
    local played = W.locomotion.played[1]
    check(played ~= nil and startOnDoor(hull, played) < 0.05 and W.clipDrawn(played) == true,
        'the step played, from the door, drawn')
    check(W.logged('exit clip step: the door\'s step is 0.92 m over the end point here', CLIENT1) ~= nil
        and W.logged('within the relaxed 0.15 to 1.00 m: the step is played', CLIENT1) ~= nil, 'and why, in the log')
    check(W.logged('no clip', CLIENT1) == nil and W.logged('steps out without a clip', SRV) == nil, 'never "no clip"')
    check(W.logged('exit clip for player 1: the plan holds', SRV) ~= nil, 'the server holds the plan')
    check(played ~= nil and yawOff(played.yaw, 75) < 1, 'the step on its own heading, not turned')
    W.groundAt = nil
end)

run('the same exit as on Staging, the hull 0.23 m over its gear as the seat is left (origin 115.00, its feet\'s ground 113.49 to 113.78): set down, the step 0.92 m once on its gear -- no turn better, played within the relaxed reach, the curtain never lifted (1.6.2)', function()
    world(function()
        W.exitPackage()
        W.groundAt = function(x) return x < -2.0 and -0.30 or 0.0 end
        W.vehicle(HULL, AV, 0, 0, 1.23, { halfWidth = 1.84, halfLength = 4.8 })
        W.player(1, 0, 0, 2.23)
    end, { 1 })
    local hull = W.vehicles[HULL]
    W.seat(1, HULL, 'seat_back_left')
    W.advance(1000)
    local leftAt = W.now
    W.leave(1, { eject = false })
    W.advance(12000)
    local played = W.locomotion.played[1]
    check(math.abs(hull.z - 1.0) < 1e-6, 'the hull set down on its gear')
    check(played ~= nil and startOnDoor(hull, played) < 0.05 and W.clipDrawn(played) == true,
        'the step played, from the door, drawn')
    check(W.logged('within the relaxed 0.15 to 1.00 m: the step is played', CLIENT1) ~= nil, 'within the relaxed reach')
    check(W.logged('the step is prepared again with the image on', CLIENT1) == nil, 'the curtain never lifted for it')
    check(W.logged('no clip', CLIENT1) == nil and W.logged('exit clip for player 1: the plan holds', SRV) ~= nil,
        'never "no clip", the server holds the plan')
    check(played ~= nil and played.at - leftAt < 8000, ('the step in %d ms'):format(played and played.at - leftAt or -1))
    W.groundAt = nil
end)

run('a dip beside the door that a turn of the step about the door clears: turned -30 deg, within the clip\'s reach, the server holding the turned plan (1.6.2)', function()
    world(function()
        W.exitPackage()
        -- 0.30 m lower west of the hull and south of y = 1: the end point on the
        -- step's own heading is in it; turned 30 deg toward the nose it is not.
        W.groundAt = function(x, y) return (x < -2.0 and y < 1.0) and -0.30 or 0.0 end
        W.vehicle(HULL, AV, 0, 0, 1.0, { halfWidth = 1.84, halfLength = 4.8 })
        W.player(1, 0, 0, 2.0)
    end, { 1 })
    local hull = W.vehicles[HULL]
    W.seat(1, HULL, 'seat_front_left')
    W.advance(1000)
    W.leave(1, { eject = false })
    W.advance(12000)
    local played = W.locomotion.played[1]
    check(played ~= nil and startOnDoor(hull, played) < 0.05 and W.clipDrawn(played) == true,
        'the step played, still from the door, drawn')
    check(played ~= nil and played.y > 1.0, ('its end point out of the dip: %.2f, %.2f'):format(played and played.x or 0,
        played and played.y or 0))
    check(W.logged('the step is turned -30 deg about the door', CLIENT1) ~= nil, 'the turn, in the log')
    check(W.logged('the step turned -30 deg about the door', SRV) ~= nil
        and W.logged('exit clip for player 1: the plan holds', SRV) ~= nil, 'the server checked the turned plan and holds it')
    check(W.logged('no clip', CLIENT1) == nil, 'never "no clip"')
    W.groundAt = nil
end)

run('the same dip, the hull still hanging over its gear as the step is prepared: the turn foreseen with the set-down to come, moved to with the image on -- no curtain lifted for it (1.6.2)', function()
    world(function()
        W.exitPackage()
        W.groundAt = function(x, y) return (x < -2.0 and y < 1.0) and -0.30 or 0.0 end
        W.vehicle(HULL, AV, 0, 0, 1.5, { halfWidth = 1.84, halfLength = 4.8 })
        W.player(1, 0, 0, 2.5)
    end, { 1 })
    local hull = W.vehicles[HULL]
    W.seat(1, HULL, 'seat_front_left')
    W.advance(1000)
    local leftAt = W.now
    W.leave(1, { eject = false })
    W.advance(12000)
    local played = W.locomotion.played[1]
    check(played ~= nil and startOnDoor(hull, played) < 0.05 and W.clipDrawn(played) == true, 'the step played, from the door')
    check(math.abs(hull.z - 1.0) < 1e-6, 'the hull set down on its gear')
    check(W.logged('would stand 0.92 m over the end point once the hull is on its gear', CLIENT1) ~= nil
        and W.logged('the step is turned -30 deg about the door', CLIENT1) ~= nil, 'foreseen while the step was prepared')
    check(W.logged('the step prepared again', CLIENT1) == nil, 'no curtain lifted for it')
    check(played ~= nil and played.at - leftAt < 6000, ('the step soon: %d ms after the exit'):format(played and played.at - leftAt or -1))
    W.groundAt = nil
end)

run('a dip read only under the curtain (its ground drawn late): the final look turns the step about the door -- the curtain lifted once for the move, the step played from the door, the server holding the turn (1.6.2)', function()
    world(function()
        W.exitPackage()
        W.vehicle(HULL, AV, 0, 0, 1.0, { halfWidth = 1.84, halfLength = 4.8 })
        W.player(1, 0, 0, 2.0)
    end, { 1 })
    local hull = W.vehicles[HULL]
    W.seat(1, HULL, 'seat_front_left')
    W.advance(1000)
    local leftAt = W.now
    W.leave(1, { eject = false })
    -- Flat ground while the step is prepared; the dip from the curtain on.
    local prepared = false
    for _ = 1, 200 do
        W.advance(50)
        if W.logged('after the seat was left: the body stands beside the door', CLIENT1) ~= nil then
            prepared = true
            break
        end
    end
    check(prepared, 'the step prepared on flat ground')
    W.groundAt = function(x, y) return (x < -2.0 and y < 1.0) and -0.30 or 0.0 end
    W.advance(12000)
    local played = W.locomotion.played[1]
    check(played ~= nil and startOnDoor(hull, played) < 0.05 and W.clipDrawn(played) == true,
        'the step played, from the door, drawn')
    check(played ~= nil and played.y > 1.0, ('its end point out of the dip: %.2f, %.2f'):format(played and played.x or 0,
        played and played.y or 0))
    check(W.logged('would stand', CLIENT1) == nil, 'nothing foreseen: the step was within reach as it was prepared')
    check(W.logged('the step is turned -30 deg about the door, where it stands 0.62 m up (within the clip\'s reach) -- the '
        .. 'curtain comes up first', CLIENT1) ~= nil and W.count('the step is prepared again with the image on', CLIENT1) == 1,
        'the turn found by the final look, the curtain lifted once')
    check(W.logged('(the step turned -30 deg about the door)', CLIENT1) ~= nil, 'and the body moved to the turned end point')
    check(W.logged('the step turned -30 deg about the door', SRV) ~= nil
        and W.logged('exit clip for player 1: the plan holds', SRV) ~= nil, 'the server checked the turned plan and holds it')
    check(W.logged('no clip', CLIENT1) == nil, 'never "no clip"')
    check(played ~= nil and played.at - leftAt < 9000, ('the step in %d ms'):format(played and played.at - leftAt or -1))
    W.groundAt = nil
end)

-- ── the boarding step (1.7.0) ────────────────────────────────────────────────
-- server/enter.lua, client/enter.lua: the key on a door asks for Myers' step up
-- into it (the clip `enter`, rooted at its FIRST frame), and the seat comes at
-- its end; every failure is the plain boarding.

--- Where an enter clip played for a body ends: its hips in the door.
local function stepEnd(played, clip)
    return server.env.AvDoor.WalkOutStart({ x = played.x, y = played.y }, played.yaw or 0, clip or played.clip)
end

local function lastPlayed(playerId)
    local found = nil
    for _, entry in ipairs((W.locomotion or {}).played or {}) do
        if entry.player == playerId then found = entry end
    end
    return found
end

local function lastWarp(playerId)
    local found = nil
    for _, entry in ipairs(W.warps or {}) do
        if entry.playerId == playerId then found = entry end
    end
    return found
end

--- An Excalibur on its gear (origin 1.0 m over flat ground, facing north) and
--- player 1 four metres off its left side, player 2 far away.
local function enterWorld(opts)
    opts = opts or {}
    world(function()
        W.exitPackage()
        if opts.ground ~= nil then W.groundAt = opts.ground end
        W.vehicle(HULL, opts.record or AV, 0, 0, opts.z or 1.0, { heading = opts.heading or 0.0, halfWidth = 1.84,
            halfLength = 4.8 })
        W.player(1, opts.px or -4.0, opts.py or 0.5, 0.0, opts.player1)
        W.player(2, 25, 0, 0)
        if opts.setup ~= nil then opts.setup() end
    end, opts.clients or { 1, 2 })
    W.advance(1200)
end

local function fadesOf(player, out)
    local list = {}
    for _, fade in ipairs(player.fades) do if fade.out == out then list[#list + 1] = fade end end
    return list
end

--- The fades of one kind before a moment (1.8.2: the seat comes under a short
--- fade, the change to third person at the key still does not).
local function fadesBefore(player, out, at)
    local list = {}
    for _, fade in ipairs(player.fades) do
        if fade.out == out and at ~= nil and fade.at < at then list[#list + 1] = fade end
    end
    return list
end

run('the boarding step: F on the Excalibur\'s door -- the body a metre before it, Myers\' step up into it for everybody, the seat at its end', function()
    enterWorld()
    local player = W.players[1]
    local hull = W.vehicles[HULL]
    check(#W.cards(1) == 1, 'the card is up')
    local pressAt = W.now
    check(W.press(1, 'F'), 'the key')
    W.advance(60)
    local ask = W.lastTo('open77_avdoor:enter', 1)
    check(ask ~= nil and ask.payload.clip == 'enter' and ask.payload.seat == 'seat_front_left',
        'the server asks for the step: `enter`, the door on the hull\'s left')
    check(ask ~= nil and ask.payload.durationMs == 2600 and ask.payload.hull.z == 1.0, 'with the clip\'s length and the hull')
    local swung = doorsOpened('trunk')
    check(#swung == 1 and swung[1].at - pressAt <= 60, 'the Excalibur\'s door swings at the key')
    check(lastWarp(1) == nil, 'nobody is seated yet')
    -- THE FIRST SPOT: 1.18 m out from the door (the clip's reach), on the
    -- ground, turned so the clip's last frame lands in the door.
    local doorX, doorY = onHull(hull, -1.45, -0.13)
    local spot = player.teleports[1]
    local reach = math.sqrt(0.150 * 0.150 + 1.1695 * 1.1695)
    check(spot ~= nil and math.abs(spot.x - (doorX - reach)) < 0.02 and math.abs(spot.y - doorY) < 0.02,
        ('the body is put %.2f m out from the door: %.3f, %.3f'):format(reach, spot and spot.x or 0, spot and spot.y or 0))
    check(spot ~= nil and math.abs(spot.z - 0.03) < 1e-6, 'on the ground, 3 cm up')
    check(spot ~= nil and spot.underFade == false, 'with the image on')
    local ex, ey = server.env.AvDoor.WalkOutStart(spot or { x = 0, y = 0 }, spot and spot.heading or 0, 'enter')
    check(math.abs(ex - doorX) < 0.01 and math.abs(ey - doorY) < 0.01,
        ('facing so the step ends in the door: %.3f, %.3f (door %.3f, %.3f)'):format(ex, ey, doorX, doorY))
    W.advance(250)
    check(#W.cards(1) == 0, 'the card comes down while the body steps up')
    W.advance(2750)
    local played = lastPlayed(1)
    check(played ~= nil and played.clip == 'enter', 'the server plays the step for everybody')
    check(played ~= nil and played.at - pressAt >= 700 and played.at - pressAt <= 2500,
        ('once the door has swung, the body ready: %d ms after the key'):format(played and played.at - pressAt or -1))
    check(played ~= nil and played.options.blendInMs == 0 and played.options.blendOutMs == 450, 'cut in, blended out')
    local px, py = stepEnd(played or { x = 0, y = 0 })
    check(math.abs(px - doorX) < 0.05 and math.abs(py - doorY) < 0.05,
        ('the step ends in the door as the body stands when it plays: %.3f, %.3f'):format(px, py))
    local froze = nil
    for _, f in ipairs(player.frozenLog) do if f.position == true and froze == nil then froze = f end end
    check(froze ~= nil and froze.grounded == true and played ~= nil and froze.at <= played.at,
        'held still, on its feet, before the clip')
    local turnHeld = nil
    for _, f in ipairs(player.frozenLog) do if f.rotation == true and turnHeld == nil then turnHeld = f end end
    check(turnHeld ~= nil and played ~= nil and turnHeld.at <= played.at, 'its heading too')
    local tps = views(player, function(v) return v.tps == true and v.force == true end)
    check(#tps == 1, 'seen in the platform\'s own third person (the stand-in the clip plays on)')
    -- THE STAND-IN FIRST (1.7.3): asked at the key, after the move.
    check(#tps == 1 and tps[1].at - pressAt <= 60 and spot ~= nil and tps[1].at >= spot.at,
        ('third person asked at the key, after the body was put on its spot: %d ms'):format(
            #tps == 1 and tps[1].at - pressAt or -1))
    check(W.logged('boarding step enter: third person drawn 0.6s after the key', 'client:open77_avdoor:1') ~= nil
        and W.logged('this screen draws the stand-in (settled, proxy)', 'client:open77_avdoor:1') ~= nil,
        'the client says when the stand-in was drawn, and that it draws it as the clip plays')
    -- NO BLACK SCREEN (1.7.1): the change of view is a cut, in view.
    check(played ~= nil and #fadesBefore(player, true, played.at) == 0, 'no curtain over the change of view')
    check(W.lastTo('open77_avdoor:entering', 1) ~= nil and W.lastTo('open77_avdoor:entering', 1).payload.ok == true
        and W.lastTo('open77_avdoor:entering', 1).payload.seatInMs == 4100,
        'the client is told the server seats it 1.5 s after the clip\'s end at the latest')
    W.advance(3000)
    local warp = lastWarp(1)
    check(warp ~= nil and warp.seat == 'seat_front_left' and player.seat ~= nil, 'seated in the pilot\'s seat')
    -- THE VIEW BEFORE THE SEAT (1.7.8): first person forced 0.6 s before the
    -- clip's end, the seat asked once the stand-in is put away.
    check(warp ~= nil and played ~= nil and warp.at - played.at >= 2000 and warp.at - played.at <= 2500,
        ('once the stand-in is put away, before the clip ends: %d ms into it'):format(warp and played
            and warp.at - played.at or -1))
    local fpp = views(player, function(v) return v.tps == false and v.force == true end)
    check(#fpp == 1 and warp ~= nil and played ~= nil and fpp[1].at - played.at >= 2000 and fpp[1].at < warp.at,
        ('first person forced before the seat: %d ms into the clip'):format(#fpp == 1 and played and fpp[1].at - played.at
            or -1))
    check(W.logged('boarding step enter: player 1\'s screen put its stand-in away 2.', 'server:open77_avdoor') ~= nil,
        'the server seats on the client\'s word')
    check(played ~= nil and (played.firstAirAt == nil or (warp ~= nil and played.firstAirAt >= warp.at)),
        'the step drawn on its feet up to the seat')
    local freed = nil
    for _, f in ipairs(player.frozenLog) do if f.position == false then freed = f end end
    check(freed ~= nil and warp ~= nil and freed.at <= warp.at and warp.at - freed.at <= 300,
        'the hold let go just before the seat')
    -- THE SEAT UNDER A SHORT FADE (1.8.2): black from the moment first person is
    -- forced (first person is drawn on the first spot, outside the door, until
    -- the seat), back on the seat's own view 0.2 s after the seat.
    local outs, ins = fadesOf(player, true), fadesOf(player, false)
    check(#outs == 1 and #fpp == 1 and outs[1].at == fpp[1].at and outs[1].options.durationMs == 150,
        ('the screen fades out (150 ms) as first person is forced: %d fade(s), at %d ms into the clip'):format(#outs,
            (#outs >= 1 and played ~= nil) and outs[1].at - played.at or -1))
    check(#ins == 1 and warp ~= nil and ins[1].at - warp.at >= 200 and ins[1].at - warp.at <= 300
        and ins[1].options.durationMs == 350 and player.covered == nil,
        ('and back (350 ms) 0.2 s after the seat: %d ms after it'):format((#ins == 1 and warp ~= nil)
            and ins[1].at - warp.at or -1))
    check(W.logged('boarding step enter: the screen fades out (150 ms) over the change to first person and the seat',
        'client:open77_avdoor:1') ~= nil and W.logged('boarding step enter: the image back on the seat\'s view (fade-in '
        .. '350 ms)', 'client:open77_avdoor:1') ~= nil, 'both said')
    check(#views(player, function(v) return v.clear == true end) >= 1, 'the view the seat\'s own again')
    check(W.lastTo('open77_avdoor:boarded', 1) ~= nil and W.lastTo('open77_avdoor:boarded', 1).payload.ok == true,
        'the client told as for any boarding')
    check(W.logged('boarding step enter: player 1 boards 4294967297', 'server:open77_avdoor') ~= nil
        or W.logged('boarding step enter: player 1 boards', 'server:open77_avdoor') ~= nil, 'the server logs the key')
    check(W.logged('boarding step enter for player 1: the plan holds', 'server:open77_avdoor') ~= nil, 'the plan held')
    check(W.logged('boarding step enter playing for player 1', 'server:open77_avdoor') ~= nil, 'the clip played')
    check(W.logged('boarding step: player 1 seated in seat_front_left', 'server:open77_avdoor') ~= nil, 'the seat')
    check(W.logged('boarding step enter asked for 4294967297', 'client:open77_avdoor:1') ~= nil, 'the client\'s plan')
    check(W.logged('boarding step enter over (seated)', 'client:open77_avdoor:1') ~= nil, 'and its summary')
    local status = server.env.AvDoor.EnterServer.Status()
    check(status.asked == 1 and status.played == 1 and status.seated == 1 and status.plain == 0 and status.now == 0,
        'counted: one asked, played, seated')
    -- THE SCENE (server/sync.lua): every screen near the step reports it.
    check(W.logged('boarding 1 of player 1, player 2\'s screen as the step began: player 1 out of the seat, 0.00 m from '
        .. 'the step\'s first spot', 'server:open77_avdoor') ~= nil, 'the other screen reports the step as it began')
    check(W.logged('boarding 1 of player 1, player 1\'s own screen as the step ended:', 'server:open77_avdoor') ~= nil
        and (W.logged('the view let go for the seat', 'server:open77_avdoor') ~= nil
            or W.logged('already seated (seat_front_left)', 'server:open77_avdoor') ~= nil),
        'and the stepping player\'s own screen as it ended: the view let go for the seat')
    check(W.logged('boarding 1 of player 1, player 2\'s screen as the step ended:', 'server:open77_avdoor') ~= nil,
        'the other screen too')
    check(W.presented ~= nil and #W.presented == 1 and W.presented[1].viewer == 2 and W.presented[1].player == 1
        and W.presented[1].ok == true and W.presented[1].seat == 'seat_front_left',
        'the other screen presents the body in its seat at once')
    check(W.logged('boarding 1 of player 1: verdict -- the step played', 'server:open77_avdoor') ~= nil
        and W.logged('4 of 4 report(s) (every screen reported): nothing wrong', 'server:open77_avdoor') ~= nil,
        'a verdict: nothing wrong')
    check(lastPlayed(2) == nil and W.lastTo('open77_avdoor:enter', 2) == nil, 'nothing for player 2')
end)

run('1.8.0: a door on the right has no step up of its own (open77_avexit 1.3.0 gave `enter_m`\'s slot to `couch`) -- the plain boarding, never the left door\'s clip', function()
    world(function()
        W.exitPackage()
        W.vehicle(HULL, MANTICORE, 0, 0, 1.5, { halfWidth = 2.2, halfLength = 6.0 })
        W.player(1, 0, 0, 2.5)
        W.player(2, 5.0, 1.0, 0.0)
    end, { 1, 2 })
    W.seat(1, HULL, 'seat_front_left')
    W.advance(1200)
    local D = server.env.AvDoor
    check(D.EnterSettings().mirrorClip == nil and D.EnterClip(MANTICORE, 'seat_front_right', D.EnterSettings()) == nil
        and D.EnterClip(MANTICORE, 'seat_front_left', D.EnterSettings()) == 'enter', 'no clip for the right-hand door')
    check(W.press(2, 'F'), 'the passenger\'s key')
    W.advance(60)
    check(W.lastTo('open77_avdoor:enter', 2) == nil, 'no step asked of the client')
    W.advance(2000)
    check(lastPlayed(2) == nil, 'no clip played')
    check(W.players[2].seat ~= nil and W.players[2].seat.seat == 'seat_front_right', 'seated plainly in the right-hand seat')
    -- A server that names a door's clip for the right keeps it.
    D.Settings.ENTER_ANIM.MIRROR_CLIP = 'enter'
    D.SettingsChanged()
    check(D.EnterClip(MANTICORE, 'seat_front_right', D.EnterSettings()) == 'enter', '`MIRROR_CLIP` still names one')
    D.Settings.ENTER_ANIM.MIRROR_CLIP = nil
    D.SettingsChanged()
end)

run('1.9.0: the Militech Manticore\'s doors -- its left door swings with the trunk, its right door with the hood, at the boarding and at the exit', function()
    local D = nil
    world(function()
        W.exitPackage()
        W.vehicle(HULL, MANTICORE, 0, 0, 1.5, { halfWidth = 2.2, halfLength = 6.0 })
        W.player(1, -4.0, 0.5, 0.0)
        W.player(2, 4.0, 0.5, 0.0)
    end, { 1, 2 })
    D = server.env.AvDoor
    for seat, door in pairs({ seat_front_left = 'trunk', seat_back_left = 'trunk', seat_front_right = 'hood',
            seat_back_right = 'hood' }) do
        check(D.ExitDoorName(MANTICORE, seat) == door, ('%s leaves through the %s-swung door'):format(seat, door))
    end
    check(D.ExitForced(MANTICORE) and not D.ExitForced(AV) and not D.ExitForced(GENERIC),
        'only the Manticore\'s exit goes through the key')
    -- The pilot's boarding: the step up into the left door, the trunk swung at the key.
    W.advance(1200)
    local pressAt = W.now
    check(W.press(1, 'F'), 'the pilot\'s key')
    W.advance(60)
    local swung = doorsOpened('trunk')
    check(#swung == 1 and swung[1].at - pressAt <= 60, 'the left door (the trunk) swings at the key')
    check(#doorsOpened('frontLeft') == 0, 'never the cabin door the platform does not move')
    W.advance(8000)
    check(W.players[1].seat ~= nil and W.players[1].seat.seat == 'seat_front_left', 'the pilot is seated')
    local played = lastPlayed(1)
    check(played ~= nil and played.clip == 'enter', 'Myers\' step up into her own AV\'s door')
    check(W.logged('the trunk door closes 2.6s into the 2.6s clip', 'server:open77_avdoor') ~= nil,
        'the sliding door closes as the clip ends, before the seat (`DOOR_CLOSE_LEAD_MS` 0)')
    -- A passenger on the right: boarded plainly (no step up of its own), its door the hood.
    check(W.press(2, 'F'), 'the passenger\'s key')
    W.advance(3000)
    check(W.players[2].seat ~= nil and W.players[2].seat.seat == 'seat_front_right', 'seated on the right')
    check(#doorsOpened('hood') >= 1, 'the right door (the hood) swings for that boarding')
    -- The pilot steps out through the key: the trunk swings for the exit.
    local before = #doorsOpened('trunk')
    check(W.pressMapped(1, LEAVE_KEY), 'the pilot\'s exit key')
    W.advance(400)
    check(#doorsOpened('trunk') > before, 'the left door swings for the pilot\'s exit')
end)

run('1.9.0: the exit key -- F, consumed, while a body sits in a Manticore; the server\'s forced exit, then the Excalibur\'s exit: the body beside the door, the clip', function()
    world(function()
        W.exitPackage()
        W.vehicle(HULL, MANTICORE, 0, 0, 1.5, { halfWidth = 2.2, halfLength = 6.0 })
        W.vehicle(HULL + 1, AV, 40, 0, 1.0, { halfWidth = 1.84, halfLength = 4.8 })
        W.player(1, -4.0, 0.5, 0.0)
        W.player(2, 36.0, 0.5, 0.0)
    end, { 1, 2 })
    local p1, p2 = W.players[1], W.players[2]
    check(p1.keys[LEAVE_KEY] == nil, 'no key on foot: F is the door card\'s')
    W.seat(1, HULL, 'seat_front_left')
    W.seat(2, HULL + 1, 'seat_front_left')
    W.advance(800)
    local key = p1.keys[LEAVE_KEY]
    check(key ~= nil and key.key == 'F' and key.consume == true, 'seated in the Manticore: F, consumed')
    check(key ~= nil and key.name == 'Step out of an AV', 'named in KEY BINDINGS')
    check(p2.keys[LEAVE_KEY] == nil, 'never in an Excalibur (its own exit is instant)')
    check(W.logged('exit key open77_avdoor_leave (F) taken for seat_front_left of', 'client:open77_avdoor:1') ~= nil,
        'the client says it took the key')
    local pressAt = W.now
    check(W.pressMapped(1, LEAVE_KEY), 'pressed')
    W.advance(30)
    local asked = W.sent('open77_avdoor:leave')
    check(#asked == 1 and asked[1].from == 1 and tostring(asked[1].payload.id) == HULL_TEXT
        and asked[1].payload.seat == 'seat_front_left', 'one ask: the hull and the seat')
    W.advance(200)
    check(W.forcedExits ~= nil and #W.forcedExits == 1 and W.forcedExits[1].playerId == 1,
        'the server steps the body out through the forced exit')
    check(W.logged('exit key of player 1: stepped out of seat_front_left of aircraft', 'server:open77_avdoor') ~= nil,
        'the server says so')
    check(W.lastTo('open77_avdoor:left', 1) ~= nil and W.lastTo('open77_avdoor:left', 1).payload.ok == true,
        'and answers the asker')
    check(p1.lastLeave ~= nil and p1.lastLeave.forced == true, 'the platform\'s forced exit (instant)')
    check(W.logged('exit from ' .. HULL_TEXT .. ': asked through the exit key', 'client:open77_avdoor:1') ~= nil,
        'the client knows the exit as the key\'s')
    check(W.logged('the game\'s own exit, animated', 'client:open77_avdoor:1') == nil, 'not the game\'s own')
    -- The Excalibur's exit: the body put beside the left door, the step clip.
    local placed = p1.teleports[1]
    check(placed ~= nil and placed.animated == nil, 'the body is put beside the door, and it holds')
    W.advance(6000)
    local played = lastPlayed(1)
    check(played ~= nil and played.clip == 'step', 'the exit clip plays')
    check(p1.keys[LEAVE_KEY] == nil, 'out: the key is dropped, F is the game\'s again')
    local dropped = firstOf(p1.keyLog or {}, function(e) return e.id == LEAVE_KEY and e.on == false end)
    check(dropped ~= nil and dropped.at - pressAt < 1000, 'dropped as the seat was left')
    check(W.problems('client:open77_avdoor:1')[1] == nil, 'no error line')
end)

run('1.9.0: a Manticore exit the key did not ask for -- the game\'s own, animated -- is left to the game: nothing placed, no clip, the others shown the body', function()
    world(function()
        W.exitPackage()
        W.vehicle(HULL, MANTICORE, 0, 0, 1.5, { halfWidth = 2.2, halfLength = 6.0 })
        W.player(1, -4.0, 0.5, 0.0)
    end, { 1 })
    local p1 = W.players[1]
    W.seat(1, HULL, 'seat_front_left')
    W.advance(800)
    -- Another exit key, a game pad: the game's own exit, the body held mounted
    -- in its workspot for 2.1 s (Staging, 2026-10-30, 22:46:23).
    W.leave(1, { animatedMs = 2100, eject = false })
    W.advance(300)
    check(W.logged('the game\'s own exit, animated -- not asked through the exit key and the engine still mounts the body',
        'client:open77_avdoor:1') ~= nil, 'the client sees the game\'s own exit')
    check(#p1.teleports == 0, 'nothing placed: no placement fights the exit\'s workspot')
    local told = W.sent('open77_avdoor:walkout', function(e) return e.payload.clip == false end)
    check(#told == 1 and told[1].payload.why == 'the game\'s own exit, animated', 'the server is told: no clip')
    W.advance(4000)
    check(lastPlayed(1) == nil, 'no clip')
    check(#p1.teleports == 0, 'still nothing placed once the game let go')
    check(W.logged('exit view: third person held', 'client:open77_avdoor:1') == nil, 'the view is the game\'s own')
    check(p1.keys[LEAVE_KEY] == nil, 'the key is dropped')
    check(#doorsOpened('trunk') >= 1, 'the door still swings for the exit (the server\'s, at the seat\'s release)')
end)

run('1.9.0: the game\'s own exit seen late (its mount not read at the first frame) -- one placement that does not hold, then left to the game', function()
    world(function()
        W.exitPackage()
        W.vehicle(HULL, MANTICORE, 0, 0, 1.5, { halfWidth = 2.2, halfLength = 6.0 })
        W.player(1, -4.0, 0.5, 0.0)
    end, { 1 })
    local p1 = W.players[1]
    W.seat(1, HULL, 'seat_front_left')
    W.advance(800)
    W.leave(1, { animatedMs = 2100, mountUnreadMs = 60, eject = false })
    W.advance(1000)
    check(W.logged('the game\'s own exit, animated -- not asked', 'client:open77_avdoor:1') == nil,
        'not seen at the first frame: the mount was not said')
    check(W.logged('the game\'s own exit, animated, seen late -- the placement did not hold and the engine mounts the body',
        'client:open77_avdoor:1') ~= nil, 'seen once the first placement did not hold')
    check(#p1.teleports == 1, ('one placement, not eight: %d'):format(#p1.teleports))
    check(W.logged('exit guard over (the game\'s own exit)', 'client:open77_avdoor:1') ~= nil, 'the guard ends')
    W.advance(4000)
    check(lastPlayed(1) == nil, 'no clip')
    local told = W.sent('open77_avdoor:walkout', function(e) return e.payload.clip == false end)
    check(#told >= 1, 'the server is told: no clip')
end)

run('1.9.0: a game that cannot consume F keeps the game\'s own exit; the server judges every ask again', function()
    world(function()
        W.exitPackage()
        W.vehicle(HULL, MANTICORE, 0, 0, 1.5, { halfWidth = 2.2, halfLength = 6.0 })
        W.vehicle(HULL + 1, AV, 40, 0, 1.0, { halfWidth = 1.84, halfLength = 4.8 })
        W.player(1, -4.0, 0.5, 0.0, { noConsume = true })
        W.player(2, 36.0, 0.5, 0.0)
        W.player(3, 0, 30, 0.0)
    end, { 1, 2, 3 })
    W.players[1].noConsume = true
    W.seat(1, HULL, 'seat_front_left')
    W.seat(2, HULL + 1, 'seat_front_left')
    W.advance(800)
    check(W.players[1].keys[LEAVE_KEY] == nil, 'no key: the game cannot consume F')
    check(W.logged('exit key: open77_avdoor_leave (F) could not be taken', 'client:open77_avdoor:1') ~= nil,
        'and the client says why (input_consumption_unavailable)')
    -- The server: an ask from a body that is not seated, from another hull,
    -- from an Excalibur, from a body already leaving.
    local function ask(from, id)
        server.net('open77_avdoor:leave', from, { id = id, seat = 'seat_front_left' })
        W.run()
        W.advance(800)
        local answer = W.lastTo('open77_avdoor:left', from)
        return answer ~= nil and answer.payload or {}
    end
    check(ask(3, HULL).reason == 'not_seated', 'not seated')
    check(ask(1, HULL + 1).reason == 'not_this_hull', 'another hull than the asker\'s own')
    check(ask(2, HULL + 1).reason == 'not_an_animated_exit', 'an Excalibur: its own exit is left to the game')
    W.vehicles[HULL].exiting.seat_front_left = true
    check(ask(1, HULL).reason == 'already_leaving', 'a body already leaving: never forced mid-way')
    W.vehicles[HULL].exiting.seat_front_left = nil
    check(W.forcedExits == nil or #W.forcedExits == 0, 'no forced exit for any of them')
    local answer = ask(1, HULL)
    check(answer.ok == true, 'the asker\'s own seat in a Manticore: stepped out')
    check(W.forcedExits ~= nil and #W.forcedExits == 1, 'one forced exit')
end)

run('1.7.1: the boarding step with the curtains asked for (`CURTAIN`, `SEAT_CURTAIN`) -- a short black over the change of view and over the seat, as 1.7.0', function()
    enterWorld()
    for _, vm in pairs(W.vms) do
        if vm.side == 'client' then
            vm.env.AvDoor.Settings.ENTER_ANIM.CURTAIN = true
            vm.env.AvDoor.Settings.ENTER_ANIM.SEAT_CURTAIN = true
        end
    end
    settingsChanged()
    local player = W.players[1]
    check(W.press(1, 'F'), 'the key')
    W.advance(3060)
    local played = lastPlayed(1)
    check(played ~= nil and played.clip == 'enter', 'the step plays')
    local outs = fadesOf(player, true)
    check(#outs >= 1 and outs[1].grounded == true and played ~= nil and outs[1].at < played.at,
        'the curtain over the change of view, the body standing')
    local ins = fadesOf(player, false)
    check(#ins >= 1 and played ~= nil and ins[1].at >= played.at and ins[1].at - played.at <= 150,
        'the image back on the step\'s first frame')
    W.advance(3000)
    local warp = lastWarp(1)
    check(warp ~= nil and player.seat ~= nil, 'seated')
    check(#fadesOf(player, true) == 2 and warp ~= nil and fadesOf(player, true)[2].at <= warp.at,
        'a short curtain over the seat')
    check(player.covered == nil, 'the image back once seated')
end)

-- ── 1.7.3: the stand-in first ────────────────────────────────────────────────
-- The owner's first boarding of a session on 1.7.2 (Staging, 2026-10-29, the
-- laptop at 11 to 18 frames a second): the session's first third person made
-- the stand-in -- 2.4 s from its spawn to dressed -- 1.7.2 gave up waiting at
-- 2.5 s and asked the step anyway, and the diag pictures show the stand-in
-- standing still at the door through the clip, then the cut to the seat.

--- When the client said it asked the step (the client's log line's time).
local function askedAt()
    for _, entry in ipairs(W.logs) do
        if entry.vm == 'client:open77_avdoor:1' and entry.text:find('boarding step enter asked ', 1, true) == 1
            and entry.text:find('after the key', 1, true) ~= nil then
            return entry.at
        end
    end
    return nil
end

run('1.7.3: the session\'s first third person makes the stand-in (3.4 s, 12 frames a second) -- asked at the key, the step asked only once it is drawn, and seen', function()
    enterWorld({ player1 = { tpsReadyMs = 3400, frameMs = 83 } })
    local player = W.players[1]
    local pressAt = W.now
    check(W.press(1, 'F'), 'the key')
    W.advance(200)
    local tps = views(player, function(v) return v.tps == true and v.force == true end)
    check(#tps == 1 and tps[1].at - pressAt <= 200, ('third person asked at the key: %d ms'):format(
        #tps == 1 and tps[1].at - pressAt or -1))
    check(player.teleports[1] ~= nil and #tps == 1 and tps[1].at >= player.teleports[1].at,
        'after the body was put on its spot')
    W.advance(2800)
    -- 3.0 s after the key: 1.7.2 asked the step at 2.5 s, before the stand-in.
    check(lastPlayed(1) == nil and askedAt() == nil, 'no step asked yet: the stand-in is still being made')
    check(W.logged('third person not drawn', 'client:open77_avdoor:1') == nil, 'nothing given up')
    check(player.frozenPosition == true, 'the body held on its spot meanwhile')
    W.advance(1500)
    local played = lastPlayed(1)
    local asked = askedAt()
    check(asked ~= nil and asked - pressAt >= 3400 and asked - pressAt <= 3900,
        ('the step asked once the stand-in is drawn: %d ms after the key'):format(asked and asked - pressAt or -1))
    check(played ~= nil and played.clip == 'enter' and asked ~= nil and played.at >= asked,
        'the server plays it then')
    check(W.logged('boarding step enter: third person drawn 3.', 'client:open77_avdoor:1') ~= nil,
        'the client says when the stand-in was drawn')
    check(W.logged('this screen draws the stand-in (settled, proxy)', 'client:open77_avdoor:1') ~= nil,
        'and that it draws it as the clip begins')
    W.advance(3000)
    local warp = lastWarp(1)
    check(warp ~= nil and played ~= nil and math.abs((warp.at - played.at) - 2400) <= 200,
        ('seated at the step\'s end: %d ms into it'):format(warp and played and warp.at - played.at or -1))
    check(W.logged('no word from the client', 'server:open77_avdoor') == nil, 'inside the server\'s ASK_MS')
    check(W.logged('boarding step enter over (seated)', 'client:open77_avdoor:1') ~= nil
        and W.logged('view asked +0.', 'client:open77_avdoor:1') ~= nil, 'the summary, the view asked first')
end)

run('1.7.3: a stand-in this screen never draws -- the plain boarding VIEW_WAIT_MS (12 s since 1.7.5) after the key, said; no step nobody here would see', function()
    enterWorld({ player1 = { tpsReadyMs = false } })
    local player = W.players[1]
    local pressAt = W.now
    check(W.press(1, 'F'), 'the key')
    W.advance(11500)
    check(lastWarp(1) == nil and lastPlayed(1) == nil, 'still waiting for the stand-in 11.5 s after the key')
    W.advance(1500)
    local warp = lastWarp(1)
    check(warp ~= nil and warp.at - pressAt >= 12000 and warp.at - pressAt <= 12600,
        ('seated plainly %d ms after the key'):format(warp and warp.at - pressAt or -1))
    check(lastPlayed(1) == nil, 'no step played')
    check(W.logged('third person not drawn 12.0s after the key', 'client:open77_avdoor:1') ~= nil
        and W.logged('is not drawn on this screen -- the plain boarding', 'client:open77_avdoor:1') ~= nil,
        'the client says why')
    check(W.logged('boarding step: none for player 1 (the client: third person not drawn', 'server:open77_avdoor') ~= nil,
        'and the server')
    check(player.frozenPosition ~= true and player.lockedView == nil, 'the hold and the view let go')
end)

run('1.7.3: third person refused on this server (its policy) -- the plain boarding at the key, said; no hold for nothing', function()
    enterWorld({ setup = function() W.players[1].perspectivePolicy = 'disabled' end })
    local player = W.players[1]
    local pressAt = W.now
    check(W.press(1, 'F'), 'the key')
    W.advance(1500)
    local warp = lastWarp(1)
    check(warp ~= nil and warp.at - pressAt <= 700, ('seated plainly %d ms after the key'):format(
        warp and warp.at - pressAt or -1))
    check(lastPlayed(1) == nil, 'no step played')
    check(W.logged('third person refused at the key (refused_by_policy, try 1)', 'client:open77_avdoor:1') ~= nil
        and W.logged('third person refused (refused_by_policy): the stand-in body the clip plays on is never drawn',
            'client:open77_avdoor:1') ~= nil, 'the client says why')
    check(player.frozenPosition ~= true, 'the body never held')
end)

run('1.7.3: `VIEW_REQUIRED = false` -- no stand-in drawn, the step asked all the same at VIEW_WAIT_MS, for the others (1.7.2\'s way)', function()
    enterWorld({ player1 = { tpsReadyMs = false } })
    for _, vm in pairs(W.vms) do
        if vm.side == 'client' then vm.env.AvDoor.Settings.ENTER_ANIM.VIEW_REQUIRED = false end
    end
    settingsChanged()
    local pressAt = W.now
    check(W.press(1, 'F'), 'the key')
    W.advance(13000)
    local played = lastPlayed(1)
    check(played ~= nil and played.at - pressAt >= 12000 and played.at - pressAt <= 12600,
        ('the step plays %d ms after the key'):format(played and played.at - pressAt or -1))
    check(W.logged('the step is asked all the same (VIEW_REQUIRED off)', 'client:open77_avdoor:1') ~= nil, 'said')
    check(W.logged('does NOT draw the stand-in', 'client:open77_avdoor:1') ~= nil,
        'and that this screen does not draw it as the clip begins')
end)

run('1.7.3: a stand-in 6.5 s in the making stays inside the server\'s ASK_MS -- the step, not a plain seat', function()
    enterWorld({ player1 = { tpsReadyMs = 6500 } })
    local pressAt = W.now
    check(W.press(1, 'F'), 'the key')
    W.advance(10000)
    local played = lastPlayed(1)
    check(played ~= nil and played.at - pressAt >= 6500 and played.at - pressAt <= 7200,
        ('the step plays %d ms after the key'):format(played and played.at - pressAt or -1))
    local warp = lastWarp(1)
    check(warp ~= nil and played ~= nil and warp.at > played.at, 'seated at its end')
    check(W.logged('no word from the client', 'server:open77_avdoor') == nil, 'the server waited for the word')
end)

-- ── 1.7.4: the game's own entry, shut ────────────────────────────────────────
-- The owner on Staging (2026-10-29, 01:08:17 local): F seated him in
-- `seat_back_left` through the game's own entry -- no line of this resource,
-- no step; F 25 s later, on the card, played the step. "enter animation isnt
-- working everytime i enter av".

local function lockCallsFor(playerId)
    local out = {}
    for _, c in ipairs(W.lockCalls or {}) do if c.player == playerId then out[#out + 1] = c end end
    return out
end

run('1.7.4: a player on foot near an aircraft -- its own entry shut for them alone: F on the back door\'s mount choice does nothing, the card steps them up', function()
    enterWorld()
    local hull = W.vehicles[HULL]
    check(hull.lockedFor[1] == true, 'the aircraft is locked for player 1 alone (4 m away)')
    check(hull.lockedFor[2] == nil, 'not for player 2, 25 m away')
    check(hull.locked == false, 'the canonical lock, the one keys turn, untouched')
    check(W.logged('the game\'s own entry to aircraft 4294967297 shut for player 1', 'server:open77_avdoor') ~= nil,
        'said in the server log')
    local mounted, why = W.gameEntry(1, HULL, 'seat_back_left')
    check(not mounted and tostring(why):find('no mount choice', 1, true) ~= nil,
        'the game\'s own entry offers no mount choice: ' .. tostring(why))
    check(W.players[1].seat == nil, 'the body is not seated by it')
    local d = door(1)
    check(d ~= nil and d.open == true and d.role == 'pilot', 'the door card is open to them, as pilot')
    local pressAt = W.now
    check(W.press(1, 'F'), 'the key on the card')
    W.advance(6000)
    local played = lastPlayed(1)
    check(played ~= nil and played.clip == 'enter', 'the step up plays')
    local warp = lastWarp(1)
    check(warp ~= nil and warp.seat == 'seat_front_left', 'seated by the card in the pilot\'s seat')
    local calls = lockCallsFor(1)
    local cleared = nil
    for _, c in ipairs(calls) do if c.cleared and c.at >= pressAt then cleared = c end end
    check(cleared ~= nil and warp ~= nil and cleared.at <= warp.at, 'the hold given back just before the seat')
    check(hull.lockedFor[1] == nil, 'and not set again while seated')
    check(W.logged('open again for player 1 (the door card seats them)', 'server:open77_avdoor') ~= nil, 'said')
    check(W.logged('through the game\'s own entry', 'server:open77_avdoor') == nil, 'no boarding through the game\'s own entry')
    local status = server.env.AvDoor.NativeEntry.Status()
    check(status.held >= 1 and status.gameEntries == 0, 'counted')
end)

run('1.7.4: walking away gives back exactly what the player had -- no exception, or their own (a key holder\'s)', function()
    enterWorld()
    local hull = W.vehicles[HULL]
    local player = W.players[1]
    check(hull.lockedFor[1] == true, 'held at 4 m')
    player.x = -20.0
    W.advance(1200)
    check(hull.lockedFor[1] == nil, 'past 16 m: no exception, as before')
    check(W.logged('open again for player 1 (20.', 'server:open77_avdoor') ~= nil, 'said, with the distance')
    -- A key holder: the street locked, their own exception open.
    hull.locked = true
    hull.lockedFor[1] = false
    player.x = -4.0
    W.advance(1200)
    check(hull.lockedFor[1] == true, 'held again at 4 m')
    local d = door(1)
    check(d ~= nil and d.open == true, 'their own exception still opens the card to them')
    player.x = -20.0
    W.advance(1200)
    check(hull.lockedFor[1] == false, 'past 16 m: their own exception given back, not dropped')
end)

run('1.7.4: the owner\'s lock still decides the card while a hold stands -- the key turned, the card follows', function()
    enterWorld()
    local hull = W.vehicles[HULL]
    check(hull.lockedFor[1] == true and door(1) ~= nil and door(1).open == true, 'held, and the card open')
    server.env.Open77.vehicles.setLocked(HULL, true)
    W.advance(1200)
    check(door(1) ~= nil and door(1).open == false, 'the owner locks it: the card closes')
    check(hull.lockedFor[1] == true, 'the hold stands')
    server.env.Open77.vehicles.setLocked(HULL, false)
    W.advance(1200)
    check(door(1) ~= nil and door(1).open == true, 'unlocked: the card opens again')
end)

run('1.7.4: another resource takes every exception away (setLockedForAll) -- the hold is set again at the next check', function()
    enterWorld()
    local hull = W.vehicles[HULL]
    check(hull.lockedFor[1] == true, 'held')
    server.env.Open77.vehicles.setLockedForAll(HULL, false)
    check(hull.lockedFor[1] == nil, 'every exception gone')
    W.advance(2600)
    check(hull.lockedFor[1] == true, 'set again')
    check(W.logged('hold was taken away by another resource (every exception revoked) -- shut again', 'server:open77_avdoor')
        ~= nil, 'said')
end)

run('1.7.4: a boarding through the game\'s own entry that still happens is a WARN line -- here before the first scan', function()
    enterWorld({ setup = function() W.noPlayerLocks = true end })
    check(W.logged('no Open77.vehicles.setLockedForPlayer on this host', 'server:open77_avdoor') ~= nil,
        'a host without the per-player lock says so, once')
    local mounted = W.gameEntry(1, HULL, 'seat_back_left')
    check(mounted == true, 'the game\'s own entry mounts the body')
    W.advance(600)
    check(W.logged('player 1 boarded aircraft 4294967297 (seat_back_left) through the game\'s own entry, not the door card: '
        .. 'no step up -- the game\'s own entry is not shut on this server', 'server:open77_avdoor', 'warn') ~= nil,
        'the server log names it')
    check(server.env.AvDoor.NativeEntry.Status().gameEntries == 1, 'counted')
end)

run('1.7.4: a seat switch inside an aircraft is not a boarding through the game\'s own entry', function()
    enterWorld()
    check(W.press(1, 'F'), 'the key')
    W.advance(6000)
    check(W.players[1].seat ~= nil and W.players[1].seat.seat == 'seat_front_left', 'seated by the card')
    local hull = W.vehicles[HULL]
    hull.seats['seat_front_left'] = nil
    W.seat(1, HULL, 'seat_back_left')
    W.advance(600)
    check(W.logged('through the game\'s own entry', 'server:open77_avdoor') == nil, 'no warning for the switch')
end)

run('1.7.4: the resource stopping gives every hold back', function()
    enterWorld()
    local hull = W.vehicles[HULL]
    check(hull.lockedFor[1] == true, 'held')
    W.stop(server)
    check(hull.lockedFor[1] == nil, 'given back')
end)

run('1.7.4: `NATIVE_ENTRY.SHUT = false` -- nothing is held, the game\'s own entry seats as before', function()
    enterWorld({ setup = function() end })
    for _, vm in pairs(W.vms) do
        if vm.side == 'server' then vm.env.AvDoor.Settings.NATIVE_ENTRY.SHUT = false end
    end
    settingsChanged()
    W.advance(1200)
    local hull = W.vehicles[HULL]
    check(hull.lockedFor[1] == nil, 'the hold given back once it is switched off')
    check(W.gameEntry(1, HULL, 'seat_back_left') == true, 'the game\'s own entry seats')
end)

-- ── 1.7.5: the stand-in made ahead ──────────────────────────────────────────
-- Staging, 2026-10-29, 07:04:48 UTC (1.7.4, the laptop at 4 to 18 frames a
-- second): the session's first boarding asked third person at the key; the
-- platform did not make the stand-in within its own 3 s, restored first person
-- (`prepare_timeout`, 3.6 s), asked again 3 s later and showed third person at
-- 7.3 s -- after the step had been given up at 7.0 s: seated plainly. The second
-- boarding (the stand-in made by the exit before it) drew third person 1.9 s
-- after the key and played the step. These worlds run the arbiter as Stable 157
-- has it (tests/world.lua, `arbiter = 'stable157'`).

local REAL = 'stable157'

--- The arbiter's answers for player 1 since `from`, as `mode/transition/reason/body` words.
local function arbTrail(playerId, from)
    local out = {}
    for _, row in ipairs(W.players[playerId].arbLog or {}) do
        if row.at >= (from or 0) then out[#out + 1] = ('%s/%s/%s/%s'):format(row.mode, row.transition, row.reason, row.body) end
    end
    return out
end

local function shownSince(playerId, from)
    for _, row in ipairs(W.players[playerId].arbLog or {}) do
        if row.at >= (from or 0) and row.mode == 'tps' then return row.at end
    end
    return nil
end

local function viewCalls(playerId, from)
    local out = {}
    for _, v in ipairs(W.players[playerId].views or {}) do
        if v.at >= (from or 0) then out[#out + 1] = v end
    end
    return out
end

run('1.7.5: the first boarding of a session, as on Staging -- the platform\'s own 3 s timeout and its try 3 s later: the step waits for third person and plays, not a plain seat', function()
    enterWorld({ player1 = { arbiter = REAL, proxyBuildMs = 4500, frameMs = 100 } })
    local player = W.players[1]
    local pressAt = W.now
    check(W.press(1, 'F'), 'the key')
    W.advance(5500)
    check(player.prepareTimeouts == 1, 'the platform gave up its first try at 3 s: ' .. tostring(player.prepareTimeouts))
    check(W.logged('the platform did not make the stand-in within its own 3 s', 'client:open77_avdoor:1') ~= nil,
        'the client says so, and goes on waiting')
    check(lastWarp(1) == nil and lastPlayed(1) == nil, 'not seated plainly while the platform tries again')
    W.advance(6000)
    local played = lastPlayed(1)
    check(played ~= nil and played.clip == 'enter' and played.at - pressAt >= 6000 and played.at - pressAt <= 8000,
        ('the step plays %d ms after the key, once third person is drawn'):format(played and played.at - pressAt or -1))
    local warp = lastWarp(1)
    check(warp ~= nil and played ~= nil and warp.at > played.at, 'seated at its end')
    check(W.logged('this screen draws the stand-in', 'client:open77_avdoor:1') ~= nil, 'drawn on this screen')
end)

run('1.7.5: the stand-in made ahead -- third person asked AFTER_MS after the server hears the client and let go at `holding_current`: never shown; the first boarding draws third person at once', function()
    enterWorld({ px = -40, setup = function() W.standInWarm = true end,
        player1 = { arbiter = REAL, proxyBuildMs = 4500, frameMs = 100 } })
    local player = W.players[1]
    local startAt = W.now
    check(#W.cards(1) == 0, 'no door card this far away')
    W.advance(2500)
    check(#viewCalls(1) == 0, 'nothing asked before AFTER_MS')
    W.advance(4000)
    local calls = viewCalls(1)
    check(#calls == 2 and calls[1].tps == true and calls[1].force == true and calls[2].clear == true,
        'third person asked, then let go: ' .. #calls .. ' call(s)')
    check(#calls == 2 and calls[2].at - calls[1].at <= 400,
        ('let go %d ms after the ask (two frames: preparing, then holding_current)'):format(
            #calls == 2 and calls[2].at - calls[1].at or -1))
    check(shownSince(1, startAt) == nil, 'third person never on screen: ' .. table.concat(arbTrail(1, startAt), ' > '))
    check(player.softCancels == 1 and player.proxySpawns == 1, 'the platform keeps building the body, parked')
    W.advance(2000)
    check(W.logged('stand-in: made ahead -- the platform built it behind first person', 'client:open77_avdoor:1') ~= nil,
        'said, once first person held through the watch after')
    W.advance(3000)
    -- To the door now: the card, F.
    player.x, player.y = -4.0, 0.5
    W.advance(1500)
    check(#W.cards(1) == 1, 'the card is up')
    local pressAt = W.now
    check(W.press(1, 'F'), 'the key')
    W.advance(3500)
    local played = lastPlayed(1)
    check(played ~= nil and played.at - pressAt <= 2000,
        ('the step plays %d ms after the key: the stand-in was ready'):format(played and played.at - pressAt or -1))
    check((player.prepareTimeouts or 0) == 0, 'the platform never ran out of time')
    check(player.proxySpawns == 1, 'the same stand-in: made once')
    check(W.logged('the stand-in made ahead', 'client:open77_avdoor:1') ~= nil, 'the boarding\'s log says it was')
end)

run('1.7.5: a door card coming up makes the try due at once (NEAR_CARD), the hello answered', function()
    enterWorld({ setup = function() W.standInWarm = true end, player1 = { arbiter = REAL, proxyBuildMs = 1500, frameMs = 50 } })
    local calls = viewCalls(1)
    check(#W.cards(1) == 1, 'the card is up')
    W.advance(1500)
    calls = viewCalls(1)
    check(#calls >= 2 and calls[1].tps == true and calls[2].clear == true, 'asked and let go within 1.5 s of the card')
    check(shownSince(1) == nil, 'never shown')
end)

run('1.7.5: F pressed while a try is in flight -- the boarding takes the view; the try lets nothing go under it', function()
    enterWorld({ px = -40, setup = function() W.standInWarm = true end,
        player1 = { arbiter = REAL, proxyBuildMs = 1500, frameMs = 100 } })
    local player = W.players[1]
    W.advance(1000)
    check(#viewCalls(1) == 0, 'no try yet (AFTER_MS)')
    -- To the door: the card comes up and makes the try due; catch its ask, and
    -- press F on that frame.
    player.x, player.y = -4.0, 0.5
    local guard = 0
    while #viewCalls(1) == 0 and guard < 200 do W.advance(10) guard = guard + 1 end
    local tryAt = W.now
    check(#viewCalls(1) == 1 and viewCalls(1)[1].tps == true, 'the try asked for third person')
    check(W.press(1, 'F'), 'the key, at once')
    W.advance(6000)
    local calls = viewCalls(1, tryAt)
    local clearsBeforeSeat = 0
    local warp = lastWarp(1)
    for _, c in ipairs(calls) do
        if c.clear and (warp == nil or c.at < warp.at - 600) then clearsBeforeSeat = clearsBeforeSeat + 1 end
    end
    check(clearsBeforeSeat == 0, 'nothing let go under the boarding: ' .. clearsBeforeSeat)
    check(W.logged('stand-in: a boarding took the view', 'client:open77_avdoor:1') ~= nil, 'the try says it handed over')
    local played = lastPlayed(1)
    check(played ~= nil and warp ~= nil and warp.at > played.at, 'the step plays, then the seat')
end)

run('1.7.5: the stand-in already drawn this session (third person by the player) -- nothing made ahead', function()
    enterWorld({ px = -40, setup = function() W.standInWarm = true end,
        player1 = { arbiter = REAL, proxyBuildMs = 1000, frameMs = 50 } })
    local player = W.players[1]
    -- The player's own third person (F7): another hand on the view.
    player.lockedView = 'tps'
    W.advance(2000)
    player.lockedView = nil
    W.advance(1000)
    check(W.logged('stand-in: drawn on this screen', 'client:open77_avdoor:1') ~= nil, 'noticed')
    W.advance(10000)
    check(#viewCalls(1) == 0, 'no try: ' .. #viewCalls(1))
    check(W.logged('stand-in: made ahead, try', 'client:open77_avdoor:1') == nil, 'none said')
end)

run('1.7.5: an older client that plays every switch out (no soft cancel) -- third person shown after the let-go: said once, never tried again', function()
    enterWorld({ px = -40, setup = function() W.standInWarm = true end,
        player1 = { arbiter = REAL, proxyBuildMs = 600, frameMs = 50, noSoftCancel = true } })
    W.advance(8000)
    check(W.logged('this client showed third person after the request was let go', 'client:open77_avdoor:1') ~= nil,
        'said')
    W.advance(30000)
    local asks = 0
    for _, v in ipairs(viewCalls(1)) do if v.tps then asks = asks + 1 end end
    check(asks == 1, 'one try only: ' .. asks)
end)

run('1.7.5: no `holding_current` within LET_GO_BY_MS -- let go, tried again RETRY_MS later, TRIES at most', function()
    -- The simple arbiter of the older suites: `preparing` until a body that never comes.
    enterWorld({ px = -40, setup = function() W.standInWarm = true end, player1 = { tpsReadyMs = false } })
    W.advance(8000)
    local calls = viewCalls(1)
    check(#calls == 2 and calls[1].tps == true and calls[2].clear == true and calls[2].at - calls[1].at >= 2500
        and calls[2].at - calls[1].at <= 2700, ('let go after LET_GO_BY_MS: %d call(s)'):format(#calls))
    check(W.logged('stand-in: not made ahead on try 1 of 2 (no holding_current within 2.5s', 'client:open77_avdoor:1') ~= nil,
        'said, with the retry')
    W.advance(20000)
    check(#viewCalls(1) == 4, 'the second try: ' .. #viewCalls(1))
    W.advance(40000)
    check(#viewCalls(1) == 4, 'no third: ' .. #viewCalls(1))
    check(W.players[1].lockedView == nil, 'nothing held')
end)

run('1.7.5: another resource holds the view -- the try waits for it, said once, then runs', function()
    enterWorld({ px = -40, setup = function() W.standInWarm = true end,
        player1 = { arbiter = REAL, proxyBuildMs = 1000, frameMs = 50 } })
    local player = W.players[1]
    player.lockedView = 'fpp'
    W.advance(8000)
    check(#viewCalls(1) == 0, 'nothing asked under another lock')
    check(W.logged('stand-in: made ahead once no resource holds the view any more', 'client:open77_avdoor:1') ~= nil,
        'said once')
    player.lockedView = nil
    W.advance(1000)
    local calls = viewCalls(1)
    check(#calls == 2 and calls[1].tps and calls[2].clear, 'then the try')
    check(shownSince(1) == nil, 'never shown')
end)

run('1.7.5: a boarding seated before its own last sample (a slow game) -- reported as seated, not WRONG', function()
    enterWorld({ player1 = { tpsReadyMs = 300, frameMs = 250 } })
    check(W.press(1, 'F'), 'the key')
    W.advance(9000)
    check(lastPlayed(1) ~= nil and lastWarp(1) ~= nil, 'the step and the seat')
    local wrongEnd = W.logged('as the step ended', 'client:open77_avdoor:1', 'warn')
    check(wrongEnd == nil, 'no WRONG at the step\'s end: ' .. tostring(wrongEnd))
    check(W.logged('as the step ended: in', 'client:open77_avdoor:1') ~= nil
        or W.logged('already seated', 'client:open77_avdoor:1') ~= nil, 'the end reported')
end)

-- ── 1.7.6: the style before the stand-in ─────────────────────────────────────
-- Staging, 2026-10-29, 18:41-18:44 UTC (1.7.5): the stand-in was made ahead at
-- 18:41:59, out of sight; at the first boarding's key the server gave the exit
-- style -- refused twice at the hello (`player_unavailable`: the player joined
-- dead) and never asked again -- and giving a style rebuilds the body every
-- game draws: the stand-in was despawned 0.24 s after it, a new one built, and
-- the step waited 8.6 s.

run('1.7.6: a player not ready at the hello -- the style asked for again until given; the stand-in made after it; the first boarding finds both', function()
    enterWorld({ px = -40, setup = function()
        W.standInWarm = true
        W.players[1].notReadyUntil = W.now + 9000
    end, player1 = { arbiter = REAL, proxyBuildMs = 3000, frameMs = 100 } })
    local player = W.players[1]
    check(W.logged('the exit style is asked for again for player 1 every 2.0s until given (player_unavailable',
        'server:open77_avdoor') ~= nil, 'the server asks again')
    check(W.logged('exit clips off for this player: player_unavailable', 'client:open77_avdoor:1') ~= nil,
        'the client told')
    W.advance(6000)
    check(#viewCalls(1) == 0, 'nothing made before the style')
    check(W.logged('stand-in: made ahead once this player has the exit style', 'client:open77_avdoor:1') ~= nil,
        'said why')
    W.advance(6000)
    check(W.logged('player 1 has the exit style', 'server:open77_avdoor') ~= nil
        and W.logged('exit clips on: this player has the exit style avexit', 'client:open77_avdoor:1') ~= nil,
        'given once the player was ready')
    W.advance(6000)
    check(W.logged('stand-in: made ahead -- the platform built it behind first person', 'client:open77_avdoor:1') ~= nil,
        'then the stand-in, out of sight')
    check(shownSince(1) == nil, 'never shown')
    check(player.proxySpawns == 1 and (player.proxyDrops or 0) == 0, 'built once, after the style: nothing thrown away')
    local given = W.locomotion.assignments[1]
    check(given ~= nil and given.style == 'avexit', 'player 1 has the style')
    local revision = given ~= nil and given.revision or -1
    W.advance(4000)
    player.x, player.y = -4.0, 0.5
    W.advance(1500)
    local pressAt = W.now
    check(W.press(1, 'F'), 'the key')
    W.advance(3500)
    local played = lastPlayed(1)
    check(played ~= nil and played.at - pressAt <= 2000,
        ('the step plays %d ms after the key'):format(played and played.at - pressAt or -1))
    check(player.proxySpawns == 1 and (player.proxyDrops or 0) == 0, 'the same stand-in at the key')
    check(W.locomotion.assignments[1] ~= nil and W.locomotion.assignments[1].revision == revision,
        'no style given at the key')
end)

run('1.7.6: a stand-in drawn before the style came (the player\'s own third person) is made again once the style rebuilds it', function()
    enterWorld({ px = -40, setup = function()
        W.standInWarm = true
        W.players[1].notReadyUntil = W.now + 9000
    end, player1 = { arbiter = REAL, proxyBuildMs = 1000, frameMs = 50 } })
    local player = W.players[1]
    player.lockedView = 'tps'
    W.advance(2500)
    player.lockedView = nil
    W.advance(1000)
    check(player.proxySpawns == 1, 'a stand-in drawn by the player')
    W.advance(10000)
    check((player.proxyDrops or 0) == 1, 'the style rebuilt it: ' .. tostring(player.proxyDrops))
    check(W.logged('stand-in: the exit style came -- the platform rebuilds this player\'s body for it',
        'client:open77_avdoor:1') ~= nil, 'noticed')
    W.advance(8000)
    check(player.proxySpawns == 2, 'made again: ' .. tostring(player.proxySpawns))
    check(shownSince(1, W.now - 8000) == nil, 'out of sight')
end)

run('1.7.6: a style another resource holds -- no step will play, so no stand-in is made ahead', function()
    enterWorld({ px = -40, setup = function()
        W.standInWarm = true
        W.locomotion.registered.other = true
        W.locomotion.assignments[1] = { style = 'other', owner = 'someone_else', revision = 7 }
    end, player1 = { arbiter = REAL, proxyBuildMs = 1000, frameMs = 50 } })
    W.advance(15000)
    check(#viewCalls(1) == 0, 'nothing asked: ' .. #viewCalls(1))
    check(W.logged('stand-in: no exit style for this player (style_owned_elsewhere)', 'client:open77_avdoor:1') ~= nil,
        'said once')
    check(W.logged('the exit style is asked for again', 'server:open77_avdoor') == nil, 'and the server does not ask again')
end)

-- ── into the seat (1.7.7) ────────────────────────────────────────────────────
-- The Excalibur's pilot seat is boarded with the seat clip `sit` (sq012): its
-- plan is made from the seat's slot -- the rig's bone turned 180 deg -- so the
-- clip ends sitting where the seat holds the body.

--- The Excalibur's pilot seat in the world, for a hull: its slot's place.
local function pilotSeat(hull)
    return onHull(hull, -0.398, 0.819)
end

run('1.7.7: M.SitPlan -- the seat clip\'s end on the slot, facing the slot\'s way, on a hull facing north and east', function()
    world(function() W.exitPackage() end, {})
    local D = server.env.AvDoor
    local sit = D.SeatSit(AV, 'seat_front_left')
    check(sit ~= nil and sit.x == -0.398 and sit.y == 0.819 and sit.z == -0.040 and sit.yaw == 180.0,
        'the pilot seat\'s slot is known: ' .. tostring(sit and sit.yaw))
    check(D.SeatSit(AV, 'seat_front_right') == nil and D.SeatSit(AV, 'seat_back_right') == nil
        and D.SeatSit(MANTICORE, 'seat_front_left') == nil, 'the other seats\' are not (1.8.0: but the back-left one)')
    local p = D.SitPlan({ x = 0, y = 0, z = 1.0, fx = 0, fy = 1 }, sit, 'sit')
    check(p ~= nil and math.abs(p.x - (-2.750)) < 0.002 and math.abs(p.y - 0.814) < 0.002,
        ('2.35 m left of the seat: %.3f, %.3f'):format(p and p.x or 0, p and p.y or 0))
    check(p ~= nil and math.abs(p.yaw - 194.773) < 0.001 and math.abs(p.seatYaw - 180.0) < 1e-9,
        ('facing the tail, turned back 14.8 deg: %.3f'):format(p and p.yaw or -1))
    check(p ~= nil and math.abs(p.seat.z - 0.96) < 1e-9, 'the seat 0.04 m under the origin')
    local ex, ey = D.WalkOutStart(p, p.yaw, 'sit')
    check(math.abs(ex - (-0.398)) < 1e-6 and math.abs(ey - 0.819) < 1e-6, 'the clip ends on the slot')
    -- Facing east (heading 270): the seat's left is north of the hull.
    local q = D.SitPlan({ x = 10, y = 20, z = 1.0, fx = 1, fy = 0 }, sit, 'sit')
    local qx, qy = D.WalkOutStart(q, q.yaw, 'sit')
    check(math.abs(qx - (10 + 0.819)) < 1e-6 and math.abs(qy - (20 + 0.398)) < 1e-6,
        ('turned with the hull: the end %.3f, %.3f'):format(qx, qy))
    check(math.abs(q.x - (10 + 0.814)) < 0.002 and math.abs(q.y - (20 + 2.750)) < 0.002 and math.abs(q.yaw - 104.773) < 0.001,
        ('the spot %.3f, %.3f facing %.3f'):format(q.x, q.y, q.yaw))
    check(D.SitPlan({ x = 0, y = 0, z = 1.0, fx = 0, fy = 1 }, sit, 'enter') == nil, 'a door\'s clip has no seat plan')
    check(D.SeatFit('sit', 0.93) == 'in' and D.SeatFit('sit', 1.15) == 'relaxed' and D.SeatFit('sit', 1.25) == 'high'
        and D.SeatFit('sit', 0.68) == 'low' and D.SeatFit('enter', 0.93) == nil, 'the seat\'s height judged')
end)

run('1.7.7: the seat clip is no exit\'s and no door\'s -- `EXIT_ANIM.CLIP = \'sit\'` and `ENTER_ANIM.CLIP = \'sit\'` are refused', function()
    world(function() W.exitPackage() end, {})
    local D = server.env.AvDoor
    D.Settings.EXIT_ANIM.CLIP = 'sit'
    D.Settings.EXIT_ANIM.RECORDS = { ['vehicle.max_tac_av'] = 'enter' }
    D.Settings.ENTER_ANIM.CLIP = 'sit'
    D.Settings.ENTER_ANIM.SIT_CLIP = 'enter'
    D.SettingsChanged()
    check(D.WalkOutSettings().clip == 'step' and D.WalkOutSettings().records['vehicle.max_tac_av'] == nil,
        'the exit keeps `step`')
    check(D.EnterSettings().clip == 'enter' and D.EnterSettings().sitClip == 'sit', 'the boarding keeps `enter` and `sit`')
    check(D.ExitClip('step') and not D.ExitClip('sit') and not D.ExitClip('enter') and D.SeatClip('sit')
        and not D.SeatClip('enter'), 'the kinds of clip')
end)

run('1.7.7: into the seat -- F on the Excalibur\'s door for its pilot seat: the body put where the sit clip ends in the seat\'s slot, the camera swung to the door, the seat at the clip\'s end', function()
    enterWorld({ setup = function() W.sitBoarding = true end })
    local player = W.players[1]
    local hull = W.vehicles[HULL]
    local pressAt = W.now
    check(W.press(1, 'F'), 'the key')
    W.advance(60)
    local ask = W.lastTo('open77_avdoor:enter', 1)
    check(ask ~= nil and ask.payload.clip == 'sit' and ask.payload.seat == 'seat_front_left',
        'the server asks for the seat clip: ' .. tostring(ask and ask.payload.clip))
    check(ask ~= nil and ask.payload.durationMs == 5600 and ask.payload.fallback == 'enter' and ask.payload.fallbackMs == 2600,
        'its length, and the door\'s clip as the fallback')
    check(#doorsOpened('trunk') == 1, 'the door swings at the key')
    local seatX, seatY = pilotSeat(hull)
    local spot = player.teleports[1]
    check(spot ~= nil and math.abs(spot.x - (-2.750)) < 0.02 and math.abs(spot.y - 0.814) < 0.02,
        ('the body put 2.35 m out from the seat, beside the door: %.3f, %.3f'):format(spot and spot.x or 0, spot and spot.y or 0))
    check(spot ~= nil and math.abs((spot.heading or 0) - 194.77) < 0.1,
        ('facing the tail, turned back as the clip turns: %.2f'):format(spot and spot.heading or -1))
    check(spot ~= nil and math.abs(spot.z - 0.03) < 1e-6, 'on the ground, 3 cm up')
    local ex, ey = server.env.AvDoor.WalkOutStart(spot or { x = 0, y = 0 }, spot and spot.heading or 0, 'sit')
    check(math.abs(ex - seatX) < 0.01 and math.abs(ey - seatY) < 0.01,
        ('the clip ends in the seat: %.3f, %.3f (seat %.3f, %.3f)'):format(ex, ey, seatX, seatY))
    W.advance(2940)
    local played = lastPlayed(1)
    check(played ~= nil and played.clip == 'sit', 'the server plays the seat clip for everybody')
    check(played ~= nil and played.at - pressAt >= 700 and played.at - pressAt <= 2500,
        ('once the door has swung: %d ms after the key'):format(played and played.at - pressAt or -1))
    local px, py = stepEnd(played or { x = 0, y = 0 })
    check(math.abs(px - seatX) < 0.05 and math.abs(py - seatY) < 0.05,
        ('it ends in the seat as the body stands when it plays: %.3f, %.3f'):format(px, py))
    local orbit = player.orbitLog[1]
    check(orbit ~= nil and orbit.on == true and orbit.degrees == 90 and played ~= nil and orbit.at <= played.at,
        'the camera swung 90 deg round the body, toward the door, before the clip')
    check(W.logged('boarding step sit: the camera swung 90 deg round the body', CLIENT1) ~= nil, 'said')
    check(W.lastTo('open77_avdoor:entering', 1) ~= nil and W.lastTo('open77_avdoor:entering', 1).payload.seatInMs == 7100,
        'the server seats it 1.5 s after the clip\'s end at the latest')
    W.advance(math.max(0, (played and played.at or W.now) + 4900 - W.now))
    check(lastWarp(1) == nil, 'not seated while the body walks up and sits down')
    W.advance(1000)
    local warp = lastWarp(1)
    check(warp ~= nil and warp.seat == 'seat_front_left' and player.seat ~= nil, 'seated in the pilot\'s seat')
    check(warp ~= nil and played ~= nil and warp.at - played.at >= 5000 and warp.at - played.at <= 5500,
        ('once the stand-in is put away, before the clip ends: %d ms into it'):format(warp and played
            and warp.at - played.at or -1))
    check(W.logged('boarding step sit: the seat asked of the server', CLIENT1) ~= nil
        and W.logged('boarding step sit: third person let go 0.60s before the clip\'s end', CLIENT1) ~= nil,
        'the view first, then the seat')
    check(W.logged('boarding step sit, seated 0.', CLIENT1) ~= nil and W.logged('boarding step sit: the seat watched', CLIENT1)
        == nil, 'the seat watched (still)')
    check(played ~= nil and (played.firstAirAt == nil or (warp ~= nil and played.firstAirAt >= warp.at)),
        'the clip drawn on the body\'s feet up to the seat')
    check(player.orbit == nil and #views(player, function(v) return v.clear == true end) >= 1,
        'the camera and the view the seat\'s own again')
    check(W.logged('boarding step sit: player 1 boards 4294967297', SRV) ~= nil
        and W.logged('into the seat: its slot 0.82 m ahead, 0.40 m left, facing 180 deg from the hull\'s heading; '
            .. 'the door\'s clip enter if the seat will not do', SRV) ~= nil, 'the server logs the key')
    check(W.logged('boarding step sit for player 1: the plan holds -- the first spot 0.00 m from the server\'s plan', SRV)
        ~= nil and W.logged('the seat 0.93 m over where the body stands (in)', SRV) ~= nil, 'the plan held, the seat at its height')
    check(W.logged('boarding step sit asked for 4294967297 (seat_front_left of Vehicle.av_rayfield_excalibur): into the '
        .. 'seat -- the first spot at -2.75, 0.81, 0.03 facing 195 deg', CLIENT1) ~= nil, 'the client\'s plan')
    check(W.logged('boarding step: player 1 seated in seat_front_left', SRV) ~= nil, 'the seat')
    check(W.logged('boarding step sit over (seated)', CLIENT1) ~= nil, 'and its summary')
    check(W.logged('its last frame in the seat at -0.4, 0.8', SRV) ~= nil, 'the scene: the step ends in the seat')
    check(W.logged('boarding 1 of player 1, player 2\'s screen as the step began: player 1 out of the seat', SRV) ~= nil
        and W.logged('the step\'s last frame 0.00 m from the seat', SRV) ~= nil, 'every screen measures it against the seat')
    check(W.logged('boarding 1 of player 1: verdict -- the step played', SRV) ~= nil
        and W.logged('4 of 4 report(s) (every screen reported): nothing wrong', SRV) ~= nil, 'a verdict: nothing wrong')
    local status = server.env.AvDoor.EnterServer.Status()
    check(status.played == 1 and status.sat == 1 and status.fellBack == 0 and status.seated == 1 and status.plain == 0,
        ('counted: %d played, %d into the seat, %d fell back, %d seated'):format(status.played, status.sat,
            status.fellBack, status.seated))
end)

run('1.7.7: a passenger seat of the Excalibur without a slot of its own keeps the door\'s clip (1.8.0: the back-right one, both back-left and the pilot\'s taken)', function()
    enterWorld({ setup = function() W.sitBoarding = true end })
    W.seat(2, HULL, 'seat_front_left')
    W.player(3, 30, 0, 0)
    W.seat(3, HULL, 'seat_back_left')
    W.advance(600)
    check(W.press(1, 'F'), 'the passenger\'s key')
    W.advance(60)
    local ask = W.lastTo('open77_avdoor:enter', 1)
    check(ask ~= nil and ask.payload.clip == 'enter' and ask.payload.fallback == nil and ask.payload.seat == 'seat_back_right',
        ('the door\'s clip for %s'):format(tostring(ask and ask.payload.seat)))
    W.advance(6000)
    check(lastPlayed(1) ~= nil and lastPlayed(1).clip == 'enter' and W.players[1].seat ~= nil, 'stepped up and seated')
end)

run('1.7.7: the ground beside the door 0.3 m lower where the seat clip starts -- the door\'s clip instead, said', function()
    enterWorld({ setup = function()
        W.sitBoarding = true
        W.groundAt = function(x, y) return x < -2.7 and -0.3 or 0.0 end
    end })
    local player = W.players[1]
    local hull = W.vehicles[HULL]
    check(W.press(1, 'F'), 'the key')
    W.advance(60)
    check(W.logged('boarding step sit: not into the seat -- the seat 1.23 m over the first spot\'s ground, the clip sits '
        .. 'down 0.96 m up (too high); the door\'s clip enter instead (planned on the next pass)', CLIENT1) ~= nil,
        'the client says why')
    W.advance(240)
    local spot = player.teleports[1]
    local doorX, doorY = onHull(hull, -1.45, -0.13)
    check(spot ~= nil and math.abs(spot.y - doorY) < 0.05 and spot.x > -2.7,
        ('the body put before the door, on the higher ground: %.2f, %.2f'):format(spot and spot.x or 0, spot and spot.y or 0))
    W.advance(3000)
    local played = lastPlayed(1)
    check(played ~= nil and played.clip == 'enter', 'the door\'s clip plays: ' .. tostring(played and played.clip))
    check(W.logged('boarding step sit for player 1: the client plans the door\'s clip enter instead -- the seat 1.23 m '
        .. 'over the first spot\'s ground', SRV) ~= nil, 'the server says so')
    check(W.lastTo('open77_avdoor:entering', 1) ~= nil and W.lastTo('open77_avdoor:entering', 1).payload.seatInMs == 4100,
        'the seat at the door clip\'s end (1.5 s after it at the latest)')
    W.advance(3000)
    check(lastWarp(1) ~= nil and player.seat ~= nil, 'seated')
    local status = server.env.AvDoor.EnterServer.Status()
    check(status.played == 1 and status.sat == 0 and status.fellBack == 1 and status.plain == 0,
        ('counted: %d played, %d into the seat, %d fell back'):format(status.played, status.sat, status.fellBack))
    W.groundAt = nil
end)

run('1.7.7: an Excalibur hanging 0.45 m over its gear -- the seat too high: set down first, then into the seat', function()
    enterWorld({ z = 1.45, setup = function() W.sitBoarding = true end })
    local hull = W.vehicles[HULL]
    local player = W.players[1]
    check(W.press(1, 'F'), 'the key')
    W.advance(300)
    check(W.logged('the seat 1.38 m over the first spot\'s ground', CLIENT1) ~= nil
        and W.logged('the hull hangs 0.45 m over its gear as this game measures it', CLIENT1) ~= nil,
        'the client measures the gear and asks for the set-down')
    check(math.abs(hull.z - 1.0) < 0.01, ('set down on its gear: %.2f'):format(hull.z))
    W.advance(1000)
    local again = W.lastTo('open77_avdoor:enter', 1)
    check(again ~= nil and again.payload.again == true and again.payload.clip == 'sit' and again.payload.fallback == 'enter',
        'the seat clip asked again, on the hull on its gear')
    W.advance(3500)
    local played = lastPlayed(1)
    check(played ~= nil and played.clip == 'sit', 'into the seat: ' .. tostring(played and played.clip))
    local px, py = stepEnd(played or { x = 0, y = 0 })
    local seatX, seatY = pilotSeat(hull)
    check(math.abs(px - seatX) < 0.05 and math.abs(py - seatY) < 0.05, 'ending in the seat')
    W.advance(6000)
    check(lastWarp(1) ~= nil and player.seat ~= nil, 'seated')
    local status = server.env.AvDoor.EnterServer.Status()
    check(status.setDown == 1 and status.reasked == 1 and status.sat == 1 and status.plain == 0,
        ('counted: %d set down, %d asked again, %d into the seat, %d plain'):format(status.setDown, status.reasked,
            status.sat, status.plain))
end)

run('1.7.7: a seat-clip plan the server\'s hull does not hold -- a first spot off the seat\'s, a seat out of the clip\'s height: refused, the plain seat', function()
    enterWorld({ setup = function() W.sitBoarding = true end })
    check(W.press(1, 'F'), 'the key')
    W.advance(60)
    local ask = W.lastTo('open77_avdoor:enter', 1)
    local E = server.env.AvDoor.EnterServer
    local own = E.CheckSit(1, { record = AV, seat = 'seat_front_left', clip = 'sit', pose = { x = 0, y = 0, z = 1.0, yaw = 0 } },
        {}, { at = { x = -1.0, y = 0.8, z = 0.03 } }, { x = -1.0, y = 0.8, z = 0.03 }, { x = 0, y = 0, z = 1.0, yaw = 0, speed = 0 })
    check(own == 'refuse', 'a first spot 1.75 m off the seat\'s: refused')
    local low, why = E.CheckSit(1, { record = AV, seat = 'seat_front_left', clip = 'sit', pose = { x = 0, y = 0, z = 1.0, yaw = 0 } },
        {}, { at = { x = -2.75, y = 0.814, z = -0.5 } }, { x = -2.75, y = 0.814, z = -0.5 }, { x = 0, y = 0, z = 1.0, yaw = 0, speed = 0 })
    check(low == 'refuse' and why == 'seat_out_of_reach:1.46', 'the seat 1.46 m over where the body stands: ' .. tostring(why))
    E.Ready(1, { token = ask.payload.token, id = HULL, clip = 'sit', plan = { at = { x = -1.0, y = 0.8, z = 0.03 } } })
    check(W.logged('boarding step: none for player 1 (its plan was not held: first_spot_off:1.75)', SRV) ~= nil,
        'the server seats the body plainly and says why')
    W.advance(200)
    check(W.players[1].seat ~= nil and lastPlayed(1) == nil, 'seated, no clip')
end)

run('1.7.7: a client naming a clip it was not asked for -- refused, the plain seat', function()
    enterWorld({ setup = function() W.sitBoarding = true end })
    check(W.press(1, 'F'), 'the key')
    W.advance(60)
    local ask = W.lastTo('open77_avdoor:enter', 1)
    local E = server.env.AvDoor.EnterServer
    E.Ready(1, { token = ask.payload.token, id = HULL, clip = 'step', plan = { at = { x = -2.75, y = 0.81, z = 0.03 } } })
    check(W.logged('boarding step: none for player 1 (the client planned step, not the sit it was asked for)', SRV) ~= nil,
        'the server seats the body plainly and says why')
    W.advance(200)
    check(W.players[1].seat ~= nil, 'seated')
end)

-- ── the back seat (1.8.0) ───────────────────────────────────────────────────
-- Corpo V's boarding of Jenkins' AV in the game's opening (open77_avexit 1.3.0,
-- `couch`) ends sitting on the Excalibur's back-left seat: it starts outside the
-- door FACING the AV, steps into the folded door's tray and up onto the floor,
-- turns left and sits down facing ahead. The back seats are filled before the
-- one beside the pilot, and `/avdoor.ride` boards a player as a passenger.

--- The Excalibur's back-left seat in the world, for a hull: its slot's place.
local function backLeftSeat(hull)
    return onHull(hull, -0.398, -1.482)
end

run('1.8.0: the couch clip -- planned on the Excalibur\'s back-left slot, facing the AV; each seat\'s clip; the back seats filled before the one beside the pilot', function()
    world(function()
        W.exitPackage()
        W.sitBoarding = true
    end, {})
    local D = server.env.AvDoor
    check(D.VERSION == '1.9.0', 'version ' .. tostring(D.VERSION))
    local sit = D.SeatSit(AV, 'seat_back_left')
    check(sit ~= nil and sit.x == -0.398 and sit.y == -1.482 and sit.z == -0.040 and sit.yaw == 0.0 and sit.clip == 'couch',
        'the back-left seat\'s slot is known, boarded with its own clip: ' .. tostring(sit and sit.clip))
    check(D.SeatClip('couch') and not D.ExitClip('couch') and D.WALK_CLIPS.enter_m == nil and D.WALK_CLIPS.couch.seconds == 4.4,
        'a seat clip of 4.4 s, never an exit\'s; no enter_m any more')
    local settings = D.EnterSettings()
    check(D.SitClip(AV, 'seat_front_left', settings) == 'sit' and D.SitClip(AV, 'seat_back_left', settings) == 'couch'
        and D.SitClip(AV, 'seat_back_right', settings) == nil and D.SitClip(AV, 'seat_front_right', settings) == nil
        and D.SitClip(MANTICORE, 'seat_back_left', settings) == nil,
        'the pilot\'s seat `sit`, the back-left `couch`, no other seat a seat clip')
    -- A seat naming a clip that is no seat clip has no clip of its own.
    D.Settings.AIRFRAMES[1].SEATS.seat_back_left.SIT.CLIP = 'enter'
    D.SettingsChanged()
    check(D.SeatSit(AV, 'seat_back_left').clip == nil and D.SitClip(AV, 'seat_back_left', D.EnterSettings()) == 'sit',
        'a seat naming a door\'s clip falls back to `SIT_CLIP`')
    D.Settings.AIRFRAMES[1].SEATS.seat_back_left.SIT.CLIP = 'couch'
    D.SettingsChanged()
    local p = D.SitPlan({ x = 0, y = 0, z = 1.0, fx = 0, fy = 1 }, sit, 'couch')
    check(p ~= nil and math.abs(p.x - (-2.3499)) < 0.001 and math.abs(p.y - (-1.0347)) < 0.001,
        ('1.95 m left of the seat (1.8.1; 1.55 before) and 0.45 m ahead of it, outside the door: %.4f, %.4f'):format(
            p and p.x or 0, p and p.y or 0))
    check(p ~= nil and math.abs(p.yaw - 270.0) < 1e-6 and math.abs(p.seatYaw) < 1e-9,
        ('facing the AV (the hull\'s right), the seat facing ahead: %.3f'):format(p and p.yaw or -1))
    check(p ~= nil and math.abs(p.seat.z - 0.96) < 1e-9, 'the seat 0.96 m over the ground under the gear')
    local ex, ey = D.WalkOutStart(p, p.yaw, 'couch')
    check(math.abs(ex - (-0.398)) < 1e-6 and math.abs(ey - (-1.482)) < 1e-6, 'the clip ends on the slot')
    -- A hull facing east (heading 270): its left is north.
    local q = D.SitPlan({ x = 10, y = 20, z = 1.0, fx = 1, fy = 0 }, sit, 'couch')
    local qx, qy = D.WalkOutStart(q, q.yaw, 'couch')
    check(math.abs(qx - (10 - 1.482)) < 1e-6 and math.abs(qy - (20 + 0.398)) < 1e-6,
        ('turned with the hull: the end %.3f, %.3f'):format(qx, qy))
    check(math.abs(q.x - 8.9653) < 0.001 and math.abs(q.y - 22.3499) < 0.001 and math.abs(q.yaw - 180.0) < 1e-6,
        ('the spot north of the hull facing south, toward it: %.4f, %.4f facing %.3f'):format(q.x, q.y, q.yaw))
    check(D.SeatFit('couch', 0.96) == 'in' and D.SeatFit('couch', 1.15) == 'relaxed' and D.SeatFit('couch', 1.25) == 'high'
        and D.SeatFit('couch', 0.68) == 'low', 'the seat\'s height judged against the couch clip\'s 0.96 m')
    check(D.DoorCloseInto('couch', 4400, settings) == 3300, 'its door shut 3.3 s into the 4.4 s clip, the body inside')
    check(table.concat(D.SeatsFor('pilot', AV), ',') == 'seat_front_left,seat_back_left,seat_back_right,seat_front_right',
        'the Excalibur fills its back seats before the one beside the pilot')
    check(table.concat(D.SeatsFor('passenger', AV), ',') == 'seat_back_left,seat_back_right,seat_front_right',
        'a passenger never in the pilot\'s seat')
    check(table.concat(D.SeatsFor('pilot', MANTICORE), ',') == 'seat_front_left,seat_front_right,seat_back_left,seat_back_right'
        and table.concat(D.SeatsFor('pilot'), ',') == 'seat_front_left,seat_front_right,seat_back_left,seat_back_right',
        'another airframe, and no record, keep `SEATS`')
end)

run('1.8.0: into the back seat -- the second body at an Excalibur climbs in the way Corpo V does, from outside the door facing it, and sits on the back-left seat at the clip\'s end', function()
    enterWorld({ setup = function() W.sitBoarding = true end })
    W.seat(2, HULL, 'seat_front_left')
    W.advance(600)
    local player = W.players[1]
    local hull = W.vehicles[HULL]
    local pressAt = W.now
    check(W.press(1, 'F'), 'the key')
    W.advance(60)
    local ask = W.lastTo('open77_avdoor:enter', 1)
    check(ask ~= nil and ask.payload.clip == 'couch' and ask.payload.seat == 'seat_back_left',
        ('the server asks for the couch clip into the back-left seat: %s, %s'):format(tostring(ask and ask.payload.clip),
            tostring(ask and ask.payload.seat)))
    check(ask ~= nil and ask.payload.durationMs == 4400 and ask.payload.fallback == 'enter' and ask.payload.fallbackMs == 2600,
        'its length, and the door\'s clip as the fallback')
    check(#doorsOpened('trunk') >= 1, 'the door swings at the key')
    local seatX, seatY = backLeftSeat(hull)
    local spot = player.teleports[1]
    check(spot ~= nil and math.abs(spot.x - (-2.350)) < 0.02 and math.abs(spot.y - (-1.035)) < 0.02,
        ('the body put outside the door, 1.95 m left of the seat: %.3f, %.3f'):format(spot and spot.x or 0, spot and spot.y or 0))
    check(spot ~= nil and math.abs((spot.heading or 0) - 270.0) < 0.1,
        ('facing the AV: %.2f'):format(spot and spot.heading or -1))
    check(spot ~= nil and math.abs(spot.z - 0.03) < 1e-6, 'on the ground, 3 cm up')
    local ex, ey = server.env.AvDoor.WalkOutStart(spot or { x = 0, y = 0 }, spot and spot.heading or 0, 'couch')
    check(math.abs(ex - seatX) < 0.01 and math.abs(ey - seatY) < 0.01,
        ('the clip ends on the back-left seat: %.3f, %.3f (seat %.3f, %.3f)'):format(ex, ey, seatX, seatY))
    W.advance(2940)
    local played = lastPlayed(1)
    check(played ~= nil and played.clip == 'couch', 'the server plays the couch clip for everybody')
    check(played ~= nil and played.at - pressAt >= 700 and played.at - pressAt <= 2500,
        ('once the door has swung: %d ms after the key'):format(played and played.at - pressAt or -1))
    local px, py = stepEnd(played or { x = 0, y = 0 })
    check(math.abs(px - seatX) < 0.05 and math.abs(py - seatY) < 0.05,
        ('it ends in the seat as the body stands when it plays: %.3f, %.3f'):format(px, py))
    local orbit = player.orbitLog[1]
    check(orbit ~= nil and orbit.on == true and orbit.degrees == 90 and played ~= nil and orbit.at <= played.at,
        'the camera swung 90 deg round the body, toward its left, before the clip')
    check(W.logged('boarding step couch for player 1: the trunk door closes 3.3s into the 4.4s clip', SRV) ~= nil,
        'the door closes 3.3 s into the clip, the body inside')
    check(W.lastTo('open77_avdoor:entering', 1) ~= nil and W.lastTo('open77_avdoor:entering', 1).payload.seatInMs == 5900,
        'the server seats it 1.5 s after the clip\'s end at the latest')
    W.advance(math.max(0, (played and played.at or W.now) + 3700 - W.now))
    check(lastWarp(1) == nil, 'not seated while the body climbs in and sits down')
    W.advance(1000)
    local warp = lastWarp(1)
    check(warp ~= nil and warp.seat == 'seat_back_left' and player.seat ~= nil, 'seated on the back-left seat')
    check(warp ~= nil and played ~= nil and warp.at - played.at >= 3800 and warp.at - played.at <= 4300,
        ('once the stand-in is put away, before the clip ends: %d ms into it'):format(warp and played
            and warp.at - played.at or -1))
    check(W.logged('boarding step couch: player 1 boards 4294967297', SRV) ~= nil
        and W.logged('into the seat: its slot 1.48 m behind, 0.40 m left, facing 0 deg from the hull\'s heading; '
            .. 'the door\'s clip enter if the seat will not do', SRV) ~= nil, 'the server logs the key')
    check(W.logged('boarding step couch for player 1: the plan holds -- the first spot 0.00 m from the server\'s plan', SRV)
        ~= nil and W.logged('the seat 0.93 m over where the body stands (in)', SRV) ~= nil, 'the plan held, the seat at its height')
    check(W.logged('boarding step couch asked for 4294967297 (seat_back_left of Vehicle.av_rayfield_excalibur): into the '
        .. 'seat -- the first spot at -2.35, -1.03, 0.03 facing 270 deg', CLIENT1) ~= nil, 'the client\'s plan')
    check(W.logged('boarding step couch: the body is on the first spot', CLIENT1) ~= nil
        and W.logged('m off it, ', CLIENT1) == nil, 'a body on its spot: nothing said of an offset')
    check(W.logged('boarding step: player 1 seated in seat_back_left', SRV) ~= nil, 'the seat')
    check(W.logged('boarding step couch over (seated)', CLIENT1) ~= nil, 'and its summary')
    check(W.logged('1 boarded 4294967297 as pilot in seat_back_left', SRV) ~= nil, 'the boarding, as any')
    local status = server.env.AvDoor.EnterServer.Status()
    check(status.played == 1 and status.sat == 1 and status.fellBack == 0 and status.seated == 1 and status.plain == 0,
        ('counted: %d played, %d into the seat, %d fell back, %d seated'):format(status.played, status.sat,
            status.fellBack, status.seated))
end)

-- 1.8.1 (open77_avexit 1.3.1): the AV's collision pushed a body put on the
-- couch clip's first spot, 0.19 m outside the folded door's rim, 0.34 m out
-- before the clip began (Staging, 2026-10-30), and the whole clip played that
-- far off. The clip now starts 0.40 m farther out, clear of it, and a body
-- that stands off its spot all the same says how far and which way.
run('1.8.1: a body the AV pushes off the couch clip\'s first spot -- how far and which way, in the hull\'s frame, a warning beyond 0.15 m; the clip plays where the body stands', function()
    enterWorld({ setup = function() W.sitBoarding = true end })
    W.seat(2, HULL, 'seat_front_left')
    W.advance(600)
    local player = W.players[1]
    -- The hull stands at the origin facing north: its left is west (-x).
    player.pushOut = { x = -0.34, y = 0.01 }
    check(W.press(1, 'F'), 'the key')
    W.advance(3000)
    local spot = player.teleports[1]
    check(spot ~= nil and math.abs(spot.x - (-2.350)) < 0.02 and math.abs(spot.y - (-1.035)) < 0.02,
        ('the first spot 2.35 m out from the hull\'s centre line: %.3f, %.3f'):format(spot and spot.x or 0,
            spot and spot.y or 0))
    check(math.abs(player.x - (-2.690)) < 0.02 and math.abs(player.y - (-1.025)) < 0.02,
        ('the body pushed out to %.3f, %.3f'):format(player.x, player.y))
    local arrived = W.logged('boarding step couch: the body is on the first spot', CLIENT1)
    check(arrived ~= nil and arrived:find('-- 0.34 m off it, 0.34 m farther out from the hull (across) and 0.01 m toward '
        .. 'its nose', 1, true) ~= nil, 'the arrival says how far and which way: ' .. tostring(arrived))
    check(W.logged('boarding step couch: the body stands 0.34 m off it, 0.34 m farther out from the hull (across) and 0.01 m '
        .. 'toward its nose -- the clip plays that far off the AV', CLIENT1, 'warn') ~= nil, 'a warning: beyond 0.15 m')
    check(W.logged('on the first spot (0.34 m off it, 0.34 m farther out from the hull (across) and 0.01 m toward its nose)',
        CLIENT1) ~= nil, 'and the ask')
    local played = lastPlayed(1)
    check(played ~= nil and played.clip == 'couch', 'the clip plays all the same')
    local px, py = stepEnd(played or { x = 0, y = 0 })
    local seatX, seatY = backLeftSeat(W.vehicles[HULL])
    check(math.abs(px - (seatX - 0.34)) < 0.05 and math.abs(py - (seatY + 0.01)) < 0.05,
        ('where the body stands: it ends 0.34 m left of the seat\'s slot, %.3f, %.3f (seat %.3f, %.3f)'):format(px, py, seatX, seatY))
    W.advance(6000)
    check(player.seat ~= nil and player.seat.seat == 'seat_back_left', 'and the seat takes the body in')
end)

run('1.8.1: a body a few centimetres off its first spot, toward the hull -- said in the arrival, no warning', function()
    enterWorld({ setup = function() W.sitBoarding = true end })
    W.seat(2, HULL, 'seat_front_left')
    W.advance(600)
    local player = W.players[1]
    player.pushOut = { x = 0.06, y = -0.05 }
    check(W.press(1, 'F'), 'the key')
    W.advance(3000)
    local arrived = W.logged('boarding step couch: the body is on the first spot', CLIENT1)
    check(arrived ~= nil and arrived:find('-- 0.08 m off it, 0.06 m nearer the hull (across) and 0.05 m toward its tail', 1,
        true) ~= nil, 'how far and which way: ' .. tostring(arrived))
    check(W.logged('the clip plays that far off the AV', CLIENT1) == nil, 'no warning under 0.15 m')
    check(lastPlayed(1) ~= nil and lastPlayed(1).clip == 'couch', 'the clip plays')
end)

run('1.8.0: `/avdoor.ride` -- alone at an Excalibur, a player rides along: the card says so, Corpo V\'s climb onto the back-left seat; asked again, flies', function()
    enterWorld({ setup = function() W.sitBoarding = true end })
    local ride = server.commands['avdoor.ride']
    check(ride ~= nil and ride.restricted == false, 'avdoor.ride is for every player')
    check(door(1) ~= nil and door(1).open == true and door(1).role == 'pilot', 'the card at first: fly the aircraft')
    ride.fn(1, {}, 'avdoor.ride')
    W.advance(600)
    check(door(1) ~= nil and door(1).open == true and door(1).role == 'passenger', 'the card now: ride along')
    check(W.logged('player 1 rides along from now on: a passenger seat wherever one is open to them', SRV) ~= nil,
        'the server says so')
    local answered = W.sent('open77:command:result')
    check(#answered == 1, 'the player is answered in their console')
    check(W.logged('avdoor.ride: you board aircraft as a passenger now', SRV) ~= nil, 'with what it does')
    local verdict = server.exports.verdict(1, HULL)
    check(verdict ~= nil and verdict.role == 'passenger' and verdict.seat == 'seat_back_left', 'the back-left seat, as a passenger')
    check(W.press(1, 'F'), 'the key')
    W.advance(60)
    local ask = W.lastTo('open77_avdoor:enter', 1)
    check(ask ~= nil and ask.payload.clip == 'couch' and ask.payload.seat == 'seat_back_left',
        'the couch clip: ' .. tostring(ask and ask.payload.clip))
    W.advance(8000)
    check(W.players[1].seat ~= nil and W.players[1].seat.seat == 'seat_back_left', 'seated on the back-left seat')
    check(W.logged('1 boarded 4294967297 as passenger in seat_back_left', SRV) ~= nil, 'as a passenger')
    -- Back to flying, and the console has no body to ride with.
    ride.fn(1, { 'off' }, 'avdoor.ride off')
    check(W.logged('player 1 boards as before (avdoor.ride)', SRV) ~= nil
        or W.logged('player 1 boards as before: the controls when the aircraft is theirs to fly', SRV) ~= nil, 'and back')
    ride.fn(0, {}, 'avdoor.ride')
    check(W.logged('avdoor.ride needs a player', SRV) ~= nil, 'the console has no body to ride with')
    -- A rider where the passenger seats are closed is asked as anybody is: flies.
    W.player(4, -4.0, -2.0, 0.0)
    ride.fn(4, { 'on' }, 'avdoor.ride on')
    settings().PASSENGERS = false
    local closed = server.exports.verdict(4, HULL)
    check(closed ~= nil and closed.role == 'pilot' and closed.seat == 'seat_front_left',
        'passenger seats closed: the rider flies -- ' .. tostring(closed and closed.role))
    settings().PASSENGERS = true
    local open = server.exports.verdict(4, HULL)
    check(open ~= nil and open.role == 'passenger' and open.seat == 'seat_back_right',
        'open again: the next back seat -- ' .. tostring(open and open.seat))
end)

-- ── the view before the seat (1.7.8) ─────────────────────────────────────────
-- 1.7.7 took the seat with the stand-in still on screen, and the stand-in
-- stood back up on the clip's first spot beside the AV until the pilot flew
-- off. Now the stand-in is put away (first person forced) before the seat,
-- the seat follows the client's word, and every other screen shows the body
-- in its seat at once.

run('1.7.8: the seat follows the stand-in put away -- first person forced 0.6 s before the clip\'s end, the seat on the client\'s word, the override let go once seated', function()
    enterWorld({ setup = function() W.sitBoarding = true end })
    local player = W.players[1]
    check(W.press(1, 'F'), 'the key')
    W.advance(3000)
    local played = lastPlayed(1)
    check(played ~= nil and played.clip == 'sit', 'the seat clip plays')
    W.advance(math.max(0, played.at + 4950 - W.now))
    check(#views(player, function(v) return v.tps == false and v.force == true end) == 0 and lastWarp(1) == nil,
        'third person held, no seat, 0.65 s before the end')
    W.advance(200)
    local fpp = views(player, function(v) return v.tps == false and v.force == true end)
    check(#fpp == 1 and fpp[1].at - played.at >= 5000 and fpp[1].at - played.at <= 5100,
        ('first person forced 0.6 s before the clip\'s end: %d ms into it'):format(#fpp == 1 and fpp[1].at - played.at or -1))
    local freed = nil
    for _, f in ipairs(player.frozenLog) do if f.position == false then freed = f end end
    check(freed ~= nil and #fpp == 1 and freed.at <= fpp[1].at, 'the hold let go with it')
    W.advance(600)
    local warp = lastWarp(1)
    check(warp ~= nil and #fpp == 1 and warp.at > fpp[1].at and warp.at - fpp[1].at <= 300,
        ('seated on the client\'s word, %d ms after the view was let go'):format(warp and #fpp == 1
            and warp.at - fpp[1].at or -1))
    local cleared = views(player, function(v) return v.clear == true end)
    check(#cleared >= 1 and warp ~= nil and cleared[#cleared].at >= warp.at, 'the lock let go once seated')
    check(server.env.AvDoor.EnterServer.Status().onWord == 1, 'counted: one seat on the word')
    check(W.logged('boarding step sit: the seat asked of the server 0.10s after the view was let go', CLIENT1) ~= nil,
        'said, with the time it took')
    W.advance(4500)
    check(W.logged('boarding step sit: the seat watched 4.', CLIENT1) ~= nil, 'the seat watched for 4 s, one line for it')
end)

run('1.7.8: a stand-in slow to be put away (1 s) -- the seat asked after PARK_WAIT_MS all the same, said', function()
    enterWorld({ setup = function() W.sitBoarding = true end,
        player1 = { arbiter = 'stable157', proxyBuildMs = 300, revealMs = 1000, frameMs = 50 } })
    check(W.press(1, 'F'), 'the key')
    W.advance(4000)
    local played = lastPlayed(1)
    check(played ~= nil and played.clip == 'sit', 'the seat clip plays: ' .. tostring(played and played.clip))
    W.advance(math.max(0, (played and played.at or W.now) + 6000 - W.now))
    local warp = lastWarp(1)
    check(warp ~= nil and played ~= nil and warp.at - played.at >= 5650 and warp.at - played.at <= 5900,
        ('seated 0.7 s after the view was let go: %d ms into the clip'):format(warp and played and warp.at - played.at or -1))
    check(W.logged('the stand-in still not put away after 0.7s', CLIENT1) ~= nil, 'the client says it did not wait longer')
end)

run('1.7.8: the client\'s word lost -- the server seats the body on its own 1.5 s after the clip\'s end', function()
    enterWorld({ setup = function()
        W.sitBoarding = true
        W.dropEvents = { ['open77_avdoor:enterSeat'] = true }
    end })
    check(W.press(1, 'F'), 'the key')
    W.advance(3000)
    local played = lastPlayed(1)
    check(played ~= nil and played.clip == 'sit', 'the seat clip plays')
    W.advance(math.max(0, (played and played.at or W.now) + 7000 - W.now))
    check(lastWarp(1) == nil, 'not seated before its time')
    W.advance(400)
    local warp = lastWarp(1)
    check(warp ~= nil and played ~= nil and math.abs(warp.at - played.at - 7100) <= 120,
        ('seated 1.5 s after the clip\'s end: %d ms into it'):format(warp and played and warp.at - played.at or -1))
    check(W.droppedEvents >= 1 and W.players[1].seat ~= nil, 'the word was lost, the body seated all the same')
    check(server.env.AvDoor.EnterServer.Status().onWord == 0, 'counted: none on the word')
end)

run('1.7.8: `SEAT_AFTER_VIEW = false` -- the seat 0.2 s before the clip\'s end, the view let go once seated (1.7.7)', function()
    enterWorld({ setup = function() W.sitBoarding = true end })
    for _, vm in pairs(W.vms) do vm.env.AvDoor.Settings.ENTER_ANIM.SEAT_AFTER_VIEW = false end
    settingsChanged()
    local player = W.players[1]
    check(W.press(1, 'F'), 'the key')
    W.advance(3000)
    local played = lastPlayed(1)
    W.advance(math.max(0, (played and played.at or W.now) + 6000 - W.now))
    local warp = lastWarp(1)
    check(warp ~= nil and played ~= nil and math.abs(warp.at - played.at - 5400) <= 120,
        ('seated 0.2 s before the clip\'s end: %d ms into it'):format(warp and played and warp.at - played.at or -1))
    check(#views(player, function(v) return v.tps == false and v.force == true end) == 0, 'first person never forced')
end)

run('1.7.8: another screen presents the boarding body in its seat at once, as the ledger names it -- not before', function()
    enterWorld({ setup = function() W.sitBoarding = true end })
    check(W.press(1, 'F'), 'the key')
    W.advance(3000)
    local played = lastPlayed(1)
    W.advance(math.max(0, (played and played.at or W.now) + 4800 - W.now))
    check(W.presented == nil, 'nothing presented while the step plays')
    W.advance(1200)
    local warp = lastWarp(1)
    check(W.presented ~= nil and #W.presented == 1 and W.presented[1].ok == true and warp ~= nil
        and W.presented[1].at >= warp.at and W.presented[1].at - warp.at <= 200,
        ('presented once, at most 0.2 s after the seat: %s'):format(W.presented and W.presented[1]
            and tostring(W.presented[1].at - (warp and warp.at or 0)) or 'never'))
    check(W.logged('boarding 1 of player 1: seated 5.', 'client:open77_avdoor:2') ~= nil
        and W.logged('presented in seat_front_left at once', 'client:open77_avdoor:2') ~= nil, 'said on that screen')
    check(W.logged('boarding 1 of player 1: verdict -- the step played', SRV) ~= nil
        and W.logged('nothing wrong', SRV) ~= nil, 'and nothing wrong in the verdict')
end)

-- ── 1.7.9: a hull left hovering is glided down onto its gear ─────────────────

run('1.7.9: AvDoor.GlideMs and AvDoor.GlideZ -- one move up to LAND_GLIDE_FROM_METRES, else the drop at 1.5 m/s on average, eased in and out', function()
    world(function()
        W.vehicle(HULL, AV, 0, 0, 1.0)
        W.player(1, 5, 0, 0)
    end, { 1 })
    local M = server.env.AvDoor
    local exit = M.ExitSettings()
    check(exit.glideFrom == 0.5 and exit.glideSpeed == 1.5 and exit.glideTick == 50,
        ('the settings: from %.2f m, %.1f m/s, a pose every %d ms'):format(exit.glideFrom, exit.glideSpeed, exit.glideTick))
    check(M.GlideMs(0.45, exit) == 0 and M.GlideMs(0.5, exit) == 0, 'the flight\'s 0.4 to 0.5 m: one move, as before')
    check(M.GlideMs(1.01, exit) == 673 and M.GlideMs(3.0, exit) == 2000,
        ('1.01 m in %d ms, 3 m in %d ms'):format(M.GlideMs(1.01, exit), M.GlideMs(3.0, exit)))
    check(M.GlideMs(0.51, { glideFrom = 0.0, glideSpeed = 10.0, glideTick = 50 }) == 100, 'two poses at least')
    check(M.AirframeLand(AV).maxDrop == 3.0, 'the Excalibur is lowered by 3 m at most')
    check(M.GlideZ(2.0, 1.0, 0, 1000) == 2.0 and M.GlideZ(2.0, 1.0, 1000, 1000) == 1.0
        and M.GlideZ(2.0, 1.0, 5000, 1000) == 1.0 and math.abs(M.GlideZ(2.0, 1.0, 500, 1000) - 1.5) < 1e-9,
        'from the hover to the gear, half way at half time')
    local before, fastest = 2.0, 0.0
    for t = 50, 1000, 50 do
        local z = M.GlideZ(2.0, 1.0, t, 1000)
        check(z <= before + 1e-12, 'never up')
        fastest = math.max(fastest, before - z)
        before = z
    end
    check(fastest <= 0.0751 and 2.0 - M.GlideZ(2.0, 1.0, 50, 1000) < 0.01 and M.GlideZ(2.0, 1.0, 950, 1000) - 1.0 < 0.01,
        ('eased: under a centimetre in the first and last 50 ms, %.3f m at most in any'):format(fastest))
end)

run('1.7.9: Staging, 2026-10-29, 16:49:32 -- the pilot steps out while the AV still hovers 1.01 m over its gear: glided down onto it, the exit clip from its door after', function()
    world(function()
        W.exitPackage()
        -- The Excalibur as the exit read it: its origin 2.01 m over flat ground,
        -- its gear 1.01 m up, its door's step 1.63 m up.
        W.vehicle(HULL, AV, 0, 0, 2.01, { halfWidth = 1.84, halfLength = 4.8 })
        W.player(1, 0, 0, 3.0)
        W.player(2, 30, 0, 0)
    end, { 1, 2 })
    local hull = W.vehicles[HULL]
    W.seat(1, HULL, 'seat_front_left')
    W.advance(1000)
    local leftAt = W.now
    W.leave(1, { eject = false })
    W.advance(12000)
    local name = 'client:open77_avdoor:1'
    check(W.logged('it hovers 1.01 m over its gear (origin 2.01, the ground under its 3 feet 0.00, 0.00, 0.00)', name) ~= nil,
        'the exiting game measures it: 1.01 m, within the set-down now (0.8 m at most before)')
    local lowered = W.logged('aircraft 4294967297 set down on its gear 1.01 m lower (2.01 -> 1.00', SRV)
    check(lowered ~= nil and lowered:find('glided down over 0.7s, a pose every 50 ms, eased in and out', 1, true) ~= nil,
        'the server glides it down, and says so')
    local poses = hull.transforms
    check(#poses >= 13 and #poses <= 15, ('a pose every 50 ms over 0.67 s: %d'):format(#poses))
    local first, last = poses[1] or {}, poses[#poses] or {}
    check(first.at ~= nil and first.at - leftAt >= 1200 and first.at - leftAt <= 1400,
        ('from the land delay on: the first pose %d ms after the exit'):format(first.at and first.at - leftAt or -1))
    local down, still, fastest = true, true, 0.0
    for i = 1, #poses do
        local pose = poses[i]
        if pose.x ~= 0 or pose.y ~= 0 or pose.yaw ~= 0 or pose.hadYaw ~= true then still = false end
        if i > 1 then
            local step = poses[i - 1].z - pose.z
            if step < -1e-12 then down = false end
            fastest = math.max(fastest, step)
        end
    end
    check(down and still, 'straight down, never up, never across, the heading kept (and passed)')
    check(2.01 - (first.z or 0) < 0.05 and fastest <= 0.12,
        ('eased off the hover (%.3f m in the first pose), %.3f m a pose at most'):format(2.01 - (first.z or 0), fastest))
    check(last.z == 1.0 and hull.z == 1.0, ('the last pose on its gear: %.3f'):format(last.z or -1))
    check(W.logged('aircraft 4294967297 stands on its gear at 1.00 (the ground under its feet 0.00): glided 1.01 m down in 0.', SRV)
        ~= nil, 'and it says so when it stands')
    -- THE CLIP: waited for, and played from the hull on its gear.
    local played = W.locomotion.played[1]
    check(played ~= nil and played.clip == 'step', 'the exit clip plays: ' .. tostring(played and played.clip))
    check(played ~= nil and last.at ~= nil and played.at >= last.at,
        ('after the hull stands on its gear: %d ms after the last pose'):format((played and last.at) and played.at - last.at or -1))
    local teleports = W.players[1].teleports
    local at = teleports[#teleports] or { x = 0, y = 0 }
    local doorX, doorY = onHull(hull, -1.45, -0.13)
    local sx, sy = clipStart(at, at.heading)
    check(math.abs(sx - doorX) < 0.05 and math.abs(sy - doorY) < 0.05, 'from the door')
    check(W.logged('no clip --', name) == nil and W.logged('too far over its gear', name) == nil, 'not given up')
    local status = server.env.AvDoor.Land.Status()
    check(status.glided == 1 and status.gliding == 0 and status.glidesCut == 0 and status.poses == #poses,
        ('counted: %d glided, %d gliding, %d cut, %d poses'):format(status.glided, status.gliding, status.glidesCut,
            status.poses))
end)

run('1.7.9: a hull left 3 m over its gear glides 2 s; an ask made while it still comes down is held until it stands, the client told', function()
    world(function()
        W.exitPackage()
        W.vehicle(HULL, AV, 0, 0, 4.0, { halfWidth = 1.84, halfLength = 4.8 })
        W.player(1, 0, 0, 5.0)
        W.player(2, 30, 0, 0)
    end, { 1, 2 })
    local hull = W.vehicles[HULL]
    W.seat(1, HULL, 'seat_front_left')
    W.advance(1000)
    W.leave(1, { eject = false })
    W.advance(14000)
    local name = 'client:open77_avdoor:1'
    check(W.logged('aircraft 4294967297 set down on its gear 3.00 m lower (4.00 -> 1.00', SRV) ~= nil
        and W.logged('glided down over 2.0s', SRV) ~= nil, 'glided 3 m over 2 s')
    local poses = hull.transforms
    check(#poses >= 39 and #poses <= 42 and hull.z == 1.0, ('%d poses, on its gear at %.2f'):format(#poses, hull.z))
    local played = W.locomotion.played[1]
    local last = poses[#poses] or {}
    check(played ~= nil and played.clip == 'step' and played.at >= (last.at or math.huge),
        'the clip once the hull stands on its gear')
    local held = W.logged('exit clip for player 1 is held until the hull stands on its gear', SRV)
    local asks = W.sent('open77_avdoor:walkout', function(e) return e.payload.clip == 'step' end)
    local askAt = asks[1] and asks[1].at or nil
    if askAt ~= nil and askAt < (last.at or 0) then
        check(held ~= nil, 'an ask made while it came down: held, said')
        check(W.logged('the server holds the step up to', name) ~= nil
            and W.logged('until the hull stands on its gear (the hull coming down onto its gear)', name) ~= nil,
            'the client is told, and waits')
    else
        check(W.logged('waits for the hull to stand on its gear', name) ~= nil, 'the client waited for it itself')
    end
    check(W.logged('refused', name) == nil, 'nothing refused')
end)

run('1.7.9: a glide ends where the hull is when a resource freezes it, or somebody boards it', function()
    local function exitAndThen(after, act)
        world(function()
            W.exitPackage()
            W.vehicle(HULL, AV, 0, 0, 3.0, { halfWidth = 1.84, halfLength = 4.8 })
            W.player(1, 0, 0, 4.0)
            W.player(2, -6.0, 0, 0)
        end, { 1, 2 })
        W.seat(1, HULL, 'seat_front_left')
        W.advance(1000)
        W.leave(1, { eject = false })
        W.advance(1200 + after)
        act(W.vehicles[HULL])
        W.advance(4000)
        return W.vehicles[HULL]
    end
    local hull = exitAndThen(500, function(h) h.frozen = true end)
    local poses = #hull.transforms
    check(hull.z > 1.05 and hull.z < 2.95, ('left where it was: %.2f'):format(hull.z))
    check(W.logged('aircraft 4294967297: the glide onto its gear ended', SRV) ~= nil
        and W.logged('it is frozen (a resource poses it)', SRV) ~= nil, 'a resource\'s freeze: said')
    W.advance(2000)
    check(#hull.transforms == poses, 'and never posed again')
    hull = exitAndThen(500, function() W.seat(2, HULL, 'seat_front_left') end)
    check(W.logged('1 aboard: the flight is theirs', SRV) ~= nil, 'somebody aboard: said')
    check(server.env.AvDoor.Land.Status().glidesCut == 1, 'counted as cut')
end)

run('1.7.9: boarding an Excalibur hanging 1.5 m over its gear -- glided down first, the step asked again once it stands', function()
    enterWorld({ z = 2.5 })
    local hull = W.vehicles[HULL]
    local player = W.players[1]
    local pressAt = W.now
    check(W.press(1, 'F'), 'the key')
    W.advance(300)
    check(W.logged('the hull hangs 1.50 m over its gear as this game measures it', CLIENT1) ~= nil, 'the client asks')
    check(W.logged('aircraft 4294967297 set down on its gear 1.50 m lower (2.50 -> 1.00', SRV) ~= nil
        and W.logged('glided down over 1.0s', SRV) ~= nil, 'the server glides it down')
    check(W.logged('set down on it first (glided down over 1.0s); the step is asked for again in 2000 ms', SRV) ~= nil,
        'and asks again once it stands, and a second more')
    W.advance(1000)
    check(math.abs(hull.z - 1.0) < 1e-9, ('on its gear: %.2f'):format(hull.z))
    local again = W.lastTo('open77_avdoor:enter', 1)
    check(again == nil or again.payload.again ~= true, 'not asked again while it came down')
    W.advance(1200)
    again = W.lastTo('open77_avdoor:enter', 1)
    check(again ~= nil and again.payload.again == true and math.abs(again.payload.hull.z - 1.0) < 0.01,
        'asked again, on the hull on its gear')
    W.advance(3500)
    local played = lastPlayed(1)
    check(played ~= nil and played.clip == 'enter', 'the step plays: ' .. tostring(played and played.clip))
    W.advance(4000)
    check(lastWarp(1) ~= nil and player.seat ~= nil, 'seated at its end')
    check(lastWarp(1) == nil or lastWarp(1).at - pressAt > 3000, 'not plainly at once')
end)

-- ── 1.7.10: the door shut before the seat, and in flight ─────────────────────

local function doorEvents(name)
    local out = {}
    for _, entry in ipairs(W.doorLog) do
        if name == nil or entry.door == name then out[#out + 1] = entry end
    end
    return out
end

run('1.7.10: into the pilot seat -- the door opens at the key and is closed 3.3 s into the sit clip, before the seat; the seat never opens it again', function()
    enterWorld({ setup = function() W.sitBoarding = true end })
    local hull = W.vehicles[HULL]
    local pressAt = W.now
    check(W.press(1, 'F'), 'the key')
    W.advance(3000)
    local played = lastPlayed(1)
    check(played ~= nil and played.clip == 'sit', 'the seat clip plays: ' .. tostring(played and played.clip))
    W.advance(9000)
    local warp = lastWarp(1)
    check(warp ~= nil and W.players[1].seat ~= nil, 'seated')
    local events = doorEvents('trunk')
    local opens, closes = {}, {}
    for _, e in ipairs(events) do if e.open then opens[#opens + 1] = e else closes[#closes + 1] = e end end
    check(#opens >= 1 and opens[1].at - pressAt <= 100, 'open at the key')
    local closed = closes[1]
    check(closed ~= nil and played ~= nil and math.abs(closed.at - played.at - 3300) <= 100,
        ('closed 3.3 s into the clip: %d ms'):format(closed and played and closed.at - played.at or -1))
    check(closed ~= nil and warp ~= nil and closed.at < warp.at, ('before the seat (%d ms before)')
        :format(closed and warp and warp.at - closed.at or -1))
    local reopened = false
    for _, e in ipairs(opens) do if closed ~= nil and e.at > closed.at then reopened = true end end
    check(not reopened and hull.doors.trunk == false, 'not opened again at the seat, and shut')
    check(W.logged('boarding step sit for player 1: the trunk door closes 3.3s into the 5.6s clip', SRV) ~= nil
        and W.logged('the trunk door of 4294967297 closed after enter', SRV) ~= nil, 'said, and closed')
end)

run('1.7.10: the door\'s clip (a passenger seat) -- the door closed 0.3 s before the clip\'s end, the seat after it', function()
    enterWorld({ setup = function() W.seat(2, HULL, 'seat_front_left') end })
    check(W.press(1, 'F'), 'the key')
    W.advance(3000)
    local played = lastPlayed(1)
    W.advance(6000)
    local closes = {}
    for _, e in ipairs(doorEvents('trunk')) do if not e.open then closes[#closes + 1] = e end end
    local warp = lastWarp(1)
    check(played ~= nil and played.clip == 'enter', 'the door\'s clip for a passenger: ' .. tostring(played and played.clip))
    check(#closes >= 1 and played ~= nil and math.abs(closes[1].at - played.at - 2300) <= 100,
        ('closed 0.3 s before the 2.6 s clip\'s end: %d ms in'):format(#closes > 0 and played and closes[1].at - played.at or -1))
    check(warp ~= nil and #closes >= 1 and closes[1].at <= warp.at, 'before the seat')
end)

run('1.7.10: a door the network still holds open in flight is shut -- somebody aboard, faster than 2 m/s -- and said', function()
    world(function()
        W.vehicle(HULL, AV, 0, 0, 1.0, { halfWidth = 1.84, halfLength = 4.8 })
        W.player(1, 0, 0, 2.0)
        W.player(2, 30, 0, 0)
    end, { 1, 2 })
    local hull = W.vehicles[HULL]
    W.seat(1, HULL, 'seat_front_left')
    W.advance(1000)
    hull.doors.trunk = true
    hull.speed = 1.0
    W.advance(1200)
    check(hull.doors.trunk == true, 'not at 1 m/s (parked, a boarding may still go on)')
    hull.speed = 12.0
    W.advance(700)
    check(hull.doors.trunk == false, 'shut at 12 m/s')
    check(W.logged('the trunk door of aircraft 4294967297 was open in flight (12.0 m/s, 1 aboard: 1:seat_front_left): closed (ok)',
        SRV) ~= nil, 'and said')
    -- Nobody aboard: an empty hull moving (the glide, a tow) keeps its door.
    W.leave(1, { eject = false })
    W.advance(3000)
    hull.doors.trunk = true
    hull.speed = 12.0
    W.advance(1200)
    check(hull.doors.trunk == true, 'an empty hull\'s door is left alone')
end)

run('1.7.10: the door watch -- aboard, this game\'s own drawing of the door is logged, and a door drawn open in flight is a warning', function()
    world(function()
        W.vehicle(HULL, AV, 0, 0, 1.0, { halfWidth = 1.84, halfLength = 4.8 })
        W.player(1, 0, 0, 2.0)
        W.player(2, 300, 0, 0)
    end, { 1, 2 })
    local hull = W.vehicles[HULL]
    W.seat(1, HULL, 'seat_front_left')
    W.advance(1500)
    check(W.logged('door watch: aboard 4294967297 (seat_front_left), 0.', CLIENT1) ~= nil
        and W.logged('the trunk door as this game draws it: SHUT (slot door_b_01 0.13 m up', CLIENT1) ~= nil
        and W.logged('the network holds it shut', CLIENT1) ~= nil, 'the first look: shut, and so held')
    -- The pilot's game keeps drawing it open while the network holds it shut, in flight.
    hull.drawnDoorFor = { [1] = 'open' }
    for _ = 1, 4 do
        hull.x = hull.x + 15.0
        W.advance(1000)
    end
    check(W.logged('the trunk door as this game draws it: OPEN (slot door_b_01 -0.65 m up', CLIENT1) ~= nil,
        'the change is a line')
    check(W.logged('THE DOOR DRAWN OPEN IN FLIGHT (15.0 m/s', CLIENT1, 'warn') ~= nil
        and W.logged('the network holds it shut)', CLIENT1, 'warn') ~= nil, 'drawn open in flight: a warning, with the network\'s word')
    hull.drawnDoorFor = nil
    W.leave(1, { eject = false })
    W.advance(2000)
    check(W.logged('door watch over (the seat was left)', CLIENT1, 'warn') ~= nil
        and W.logged('drawn open in flight', CLIENT1, 'warn') ~= nil, 'and the summary says it')
end)

run('1.7.1: a fresh Excalibur hanging 0.45 m over its gear (its door\'s step 1.07 m up, past the clip\'s reach) -- set down on its gear first, then the step', function()
    enterWorld({ z = 1.45 })
    local hull = W.vehicles[HULL]
    local player = W.players[1]
    local pressAt = W.now
    check(W.press(1, 'F'), 'the key')
    W.advance(300)
    check(W.logged('no first spot within the clip\'s reach', 'client:open77_avdoor:1') ~= nil
        and W.logged('the hull hangs 0.45 m over its gear as this game measures it', 'client:open77_avdoor:1') ~= nil,
        'the client measures the ground under the gear and asks')
    check(math.abs(hull.z - 1.0) < 0.01, ('the server sets the empty hull down on its gear: %.2f'):format(hull.z))
    check(W.logged('aircraft 4294967297 set down on its gear 0.45 m lower', 'server:open77_avdoor') ~= nil
        and W.logged('pressed the key at its door (a boarding)', 'server:open77_avdoor') ~= nil, 'and says so')
    check(lastWarp(1) == nil and #player.teleports == 0, 'nobody seated, the body not moved yet')
    W.advance(1000)
    local again = W.lastTo('open77_avdoor:enter', 1)
    check(again ~= nil and again.payload.again == true and math.abs(again.payload.hull.z - 1.0) < 0.01,
        'the step asked again, on the hull on its gear')
    check(W.logged('boarding step enter: player 1 asked again', 'server:open77_avdoor') ~= nil, 'said')
    W.advance(3500)
    local played = lastPlayed(1)
    check(played ~= nil and played.clip == 'enter', 'the step plays')
    W.advance(3000)
    check(lastWarp(1) ~= nil and player.seat ~= nil, 'seated at its end')
    local status = server.env.AvDoor.EnterServer.Status()
    check(status.setDown == 1 and status.reasked == 1 and status.played == 1 and status.plain == 0,
        ('counted: %d set down, %d asked again, %d played, %d plain'):format(status.setDown, status.reasked,
            status.played, status.plain))
    check(#fadesBefore(player, true, played and played.at) == 0 and #fadesOf(player, true) == 1,
        'no black screen before the step; the seat under its short fade (1.8.2)')
    check(W.logged('boarding step enter over (seated)', 'client:open77_avdoor:1') ~= nil, 'the summary')
end)

run('1.7.1: a hull 0.4 m over its gear whose door\'s step (1.02 m) is only within the relaxed reach -- set down first all the same', function()
    enterWorld({ z = 1.4 })
    local hull = W.vehicles[HULL]
    check(W.press(1, 'F'), 'the key')
    W.advance(300)
    check(W.logged('only within the clip\'s relaxed reach', 'client:open77_avdoor:1') ~= nil, 'the client asks for the set-down')
    check(math.abs(hull.z - 1.0) < 0.01, 'set down on its gear')
    W.advance(4500)
    local played = lastPlayed(1)
    check(played ~= nil and played.clip == 'enter', 'the step plays')
    check(W.logged('the door\'s step 0.62 m over the first spot', 'server:open77_avdoor') ~= nil,
        'within the clip\'s own reach, on the hull on its gear')
end)

run('1.7.1: the hull set down, and this game still draws it where it hung for a moment -- planned again until it is drawn on its gear', function()
    enterWorld({ z = 1.45 })
    local hull = W.vehicles[HULL]
    check(W.press(1, 'F'), 'the key')
    W.advance(300)
    check(math.abs(hull.z - 1.0) < 0.01, 'set down')
    -- This game keeps drawing the hull 0.45 m up a while longer.
    hull.drawnOffset = { x = 0, y = 0, z = 0.45 }
    W.advance(1300)
    check(W.logged('the server set the hull down, and this game still draws it over its gear', 'client:open77_avdoor:1')
        ~= nil, 'the client waits for it')
    check(lastPlayed(1) == nil and lastWarp(1) == nil, 'no step, no seat yet')
    hull.drawnOffset = nil
    W.advance(500)
    check(W.logged('this game draws the hull on its gear', 'client:open77_avdoor:1') ~= nil, 'then plans on it')
    W.advance(3500)
    check(lastPlayed(1) ~= nil and lastPlayed(1).clip == 'enter', 'the step plays')
    W.advance(3000)
    check(W.players[1].seat ~= nil, 'seated')
end)

run('1.7.1: the hull set down and still drawn where it hung after `SET_DOWN_LOOK_MS` -- the plain boarding, said', function()
    enterWorld({ z = 1.45 })
    local hull = W.vehicles[HULL]
    check(W.press(1, 'F'), 'the key')
    W.advance(300)
    hull.drawnOffset = { x = 0, y = 0, z = 0.45 }
    W.advance(4000)
    check(lastPlayed(1) == nil, 'no step')
    check(lastWarp(1) ~= nil and W.players[1].seat ~= nil, 'seated plainly')
    check(W.logged('still, 2.0s after the server set the hull down', 'client:open77_avdoor:1') ~= nil, 'the client says why')
    check(server.env.AvDoor.EnterServer.Status().plain == 1, 'counted plain')
end)

run('1.7.1: a hull over its gear another resource froze is not set down -- the plain boarding, and why', function()
    enterWorld({ z = 1.45 })
    local hull = W.vehicles[HULL]
    hull.frozen = true
    check(W.press(1, 'F'), 'the key')
    W.advance(800)
    check(math.abs(hull.z - 1.45) < 0.01, 'left where it is')
    check(W.logged('stays where the flight left it: it is frozen', 'server:open77_avdoor') ~= nil, 'said by the set-down')
    check(W.logged('the hull could not be set down first', 'server:open77_avdoor') ~= nil, 'and by the boarding')
    check(lastWarp(1) ~= nil, 'seated plainly')
    hull.frozen = false
end)

-- ── 1.7.2: a weapon drawn, a game without the clips ─────────────────────────

run('1.7.2: a weapon drawn at the key is holstered, and the step waits for the hands to be empty, then plays', function()
    enterWorld({ setup = function() W.players[1].weaponDrawn = true end })
    local pressAt = W.now
    check(W.press(1, 'F'), 'the key')
    W.advance(60)
    check(W.holsters == 1, 'holstered at the key: ' .. tostring(W.holsters))
    check(W.logged('a weapon drawn 0.0s after the key -- holstered (at the key', 'client:open77_avdoor:1') ~= nil,
        'said, with how long the step waits')
    W.advance(3000)
    local played = lastPlayed(1)
    check(played ~= nil and played.clip == 'enter', 'the step plays')
    check(played ~= nil and played.at - pressAt >= 400, ('not before the hands are empty: %d ms after the key'):format(
        played and played.at - pressAt or -1))
    check(W.logged('the hands are empty', 'client:open77_avdoor:1') ~= nil, 'said')
    W.advance(3000)
    check(lastWarp(1) ~= nil and W.players[1].seat ~= nil, 'seated at its end')
    check(W.logged('a WEAPON DRAWN', 'server:open77_avdoor') == nil, 'no screen saw a weapon out during the step')
    check(W.logged('holstered +', 'client:open77_avdoor:1') ~= nil, 'the summary has the holster in its timeline')
    check(W.vms[CLIENT1].env.AvDoor.Enter.Status().holstered == 1, 'counted')
end)

run('1.7.2: a weapon that will not go away -- asked once more halfway, then the plain boarding after HOLSTER_WAIT_MS', function()
    enterWorld({ setup = function() W.players[1].weaponDrawn = true; W.players[1].weaponStuck = true end })
    local pressAt = W.now
    check(W.press(1, 'F'), 'the key')
    W.advance(4000)
    check(lastPlayed(1) == nil, 'no step played on a body with a weapon out')
    check(W.holsters == 2, 'holstered at the key and once more halfway: ' .. tostring(W.holsters))
    check(W.logged('a weapon still drawn', 'client:open77_avdoor:1') ~= nil, 'the client says why')
    check(W.logged('boarding step: none for player 1 (the client: a weapon still drawn', 'server:open77_avdoor') ~= nil,
        'the server seats it plainly, and says why')
    local warp = lastWarp(1)
    check(warp ~= nil and warp.at - pressAt <= 3500, ('seated: %d ms after the key'):format(warp and warp.at - pressAt or -1))
    check(W.players[1].frozenPosition ~= true, 'the hold let go')
end)

run('1.7.2: a game that cannot holster (no permission) boards plainly, and says why', function()
    enterWorld({ setup = function() W.players[1].weaponDrawn = true; W.players[1].holsterRefused = true end })
    check(W.press(1, 'F'), 'the key')
    W.advance(3000)
    check(lastPlayed(1) == nil, 'no step')
    check(W.logged('the weapon could not be holstered (permission_denied:player.weapons.edit)', 'client:open77_avdoor:1') ~= nil,
        'the refusal said')
    check(W.logged('a weapon drawn, and it could not be holstered', 'client:open77_avdoor:1') ~= nil, 'and why no step')
    check(lastWarp(1) ~= nil, 'seated plainly')
end)

run('1.7.2: HOLSTER = false leaves the weapon -- and the step, as before', function()
    enterWorld({ setup = function() W.players[1].weaponDrawn = true end })
    for _, vm in pairs(W.vms) do
        if vm.side == 'client' then vm.env.AvDoor.Settings.ENTER_ANIM.HOLSTER = false end
    end
    settingsChanged()
    check(W.press(1, 'F'), 'the key')
    W.advance(4000)
    check(W.holsters == 0, 'not holstered')
    check(lastPlayed(1) ~= nil, 'the step asked all the same (the screens say what they drew)')
    check(W.logged('a WEAPON DRAWN', 'server:open77_avdoor') ~= nil, 'and the screens say a weapon was out')
end)

run('1.7.2: the boarding\'s pictures go on past the seat -- two just after it, where a black frame would show', function()
    enterWorld()
    check(W.press(1, 'F'), 'the key')
    W.advance(20000)
    local sets, index = picturesOf(1)
    local list = sets[index[#index]] or {}
    local labels = {}
    for _, shot in ipairs(list) do labels[#labels + 1] = shot.meta ~= nil and shot.meta:match('label=([^;]+)') or '?' end
    local text = table.concat(labels, ' ')
    check(text:find('seat seated+0.0 seated+0.15 seated+0.6', 1, true) ~= nil,
        'the seat, then at its own frame (1.7.3), 0.15 s and 0.6 s after it: ' .. text)
    check(text:find('held asked step', 1, true) ~= nil, 'and one as the step is asked (1.7.3): ' .. text)
    local after = list[#list]
    check(after ~= nil and after.meta:find('view=', 1, true) ~= nil, 'with the view as this game had it: '
        .. tostring(after and after.meta))
end)

--- A game whose open77_avexit could not register the package: its archive is
--- not in the game it started with (Staging, 2026-10-29).
local NO_CLIPS = { ok = false, reason = 'locomotion_archive_missing_restart_required', side = 'client' }

run('1.7.2: a game without the clips -- said at its hello, to the player and in both logs; F boards plainly at once', function()
    enterWorld({ setup = function()
        W.players[1].animStatus = NO_CLIPS
        W.players[1].launcher = { connectEndpoint = '88.214.59.166:11840', master = 'alpha',
            serverId = '9dcd2e5a-57d5-4852-9458-ac23f748707e',
            modsDigest = 'fd6aa98697a79ea0d01459ddcfcc135ae0401c62e72aefa25cc809614b386c38', launched = true }
    end })
    local player = W.players[1]
    check(W.logged('this game has no AV animation package (locomotion_archive_missing_restart_required; found by the hello)',
        'client:open77_avdoor:1') ~= nil, 'the client says so at its hello')
    check(W.logged('the launcher started it for server 9dcd2e5a-57d5-4852-9458-ac23f748707e at 88.214.59.166:11840 with the '
        .. 'mods of digest fd6aa98697a7', 'client:open77_avdoor:1') ~= nil, 'with what the launcher prepared it for')
    local told = 0
    for _, notice in ipairs(player.notices) do
        if notice.text:find('start it again through the Open77 launcher', 1, true) then told = told + 1 end
    end
    check(told == 1, 'the player is told once: ' .. told)
    check(W.logged('player 1\'s game has no AV animation package (locomotion_archive_missing_restart_required)',
        'server:open77_avdoor') ~= nil, 'the server says so')
    check(W.logged('its launcher started it for server 9dcd2e5a-57d5-4852-9458-ac23f748707e at 88.214.59.166:11840 with '
        .. 'the mods of digest fd6aa98697a7', 'server:open77_avdoor') ~= nil, 'with the launcher\'s digest to compare')
    check(W.logged('boarding step: player 1\'s game cannot draw it', 'server:open77_avdoor') ~= nil, 'the boarding knows')
    local pressAt = W.now
    check(W.press(1, 'F'), 'the key')
    W.advance(1200)
    check(W.lastTo('open77_avdoor:enter', 1) == nil, 'no step asked of a game that cannot draw it')
    local warp = lastWarp(1)
    check(warp ~= nil and warp.at - pressAt <= 700, ('seated as a plain boarding is: %d ms after the key'):format(
        warp and warp.at - pressAt or -1))
    check(#player.teleports == 0 and #player.frozenLog == 0, 'the body neither moved nor held')
    check(W.logged('player 1\'s client has not said it knows the step', 'server:open77_avdoor') == nil,
        'not taken for an older client')
    -- ITS EXIT: plain, nothing hidden, no scene, no clip.
    W.advance(1000)
    local leftAt = W.now
    W.leave(1)
    W.advance(4000)
    check(firstVisibility(1, false) == nil, 'never hidden from the others')
    check(W.logged('exit of player 1 from seat_front_left of 4294967297: plain -- its game has no AV animation package',
        'server:open77_avdoor') ~= nil, 'the server says the exit is plain, and why')
    check(W.logged('exit clip: none -- this game has no AV animation package', 'client:open77_avdoor:1') ~= nil,
        'and so does the client')
    check(lastPlayed(1) == nil, 'no clip played')
    check(server.env.AvDoor.WalkOutServer.Status().plainNoClips == 1, 'counted')
    local again = 0
    for _, notice in ipairs(player.notices) do
        if notice.text:find('start it again through the Open77 launcher', 1, true) then again = again + 1 end
    end
    check(again == 1, 'the player is not told again')
    check(W.players[1].seat == nil and W.now - leftAt >= 4000, 'out of the aircraft')
end)

run('1.7.2: open77_avexit answers only after the hello -- the hello is said again, and the server learns it', function()
    enterWorld({ setup = function() W.players[1].animStatus = 'raise' end })
    check(W.logged('player 1\'s game has no AV animation package', 'server:open77_avdoor') == nil, 'not known at first')
    W.players[1].animStatus = NO_CLIPS
    W.advance(2600)
    check(W.logged('hello said to the server (try 1, open77_avexit answered after the hello: no clips here)',
        'client:open77_avdoor:1') ~= nil, 'the hello said again')
    check(W.logged('player 1\'s game has no AV animation package', 'server:open77_avdoor') ~= nil, 'the server knows now')
    local pressAt = W.now
    check(W.press(1, 'F'), 'the key')
    W.advance(1200)
    check(W.lastTo('open77_avdoor:enter', 1) == nil and lastWarp(1) ~= nil and lastWarp(1).at - pressAt <= 700,
        'F boards plainly at once')
end)

run('1.7.2: a game the server still asks for a step (an ask before its hello came) says no step at once', function()
    enterWorld({ setup = function() W.players[1].animStatus = NO_CLIPS end })
    -- As if the hello had said nothing of it: the server takes the client as able.
    server.env.AvDoor.EnterServer.Hello(1, { enter = true })
    local pressAt = W.now
    check(W.press(1, 'F'), 'the key')
    W.advance(1200)
    check(W.lastTo('open77_avdoor:enter', 1) ~= nil, 'asked')
    check(W.logged('boarding step enter: none -- this game has no AV animation package', 'client:open77_avdoor:1') ~= nil,
        'the client says no step, and why')
    local warp = lastWarp(1)
    check(warp ~= nil and warp.at - pressAt <= 600, 'seated at once')
    check(#W.players[1].teleports == 0, 'the body never moved')
    check(W.vms[CLIENT1].env.AvDoor.Enter.Status().noClips == 1, 'counted')
end)

run('1.7.2: a game WITH the clips (open77_avexit says so) boards and steps out animated, as before', function()
    enterWorld({ setup = function() W.players[1].animStatus = { ok = true, style = 'avexit', side = 'client' } end })
    check(W.press(1, 'F'), 'the key')
    W.advance(6000)
    check(lastPlayed(1) ~= nil and lastPlayed(1).clip == 'enter', 'the step plays')
    check(W.logged('no AV animation package', 'server:open77_avdoor') == nil
        and W.logged('no AV animation package', 'client:open77_avdoor:1') == nil, 'nothing said of missing clips')
    check(W.statusAsks >= 1, 'open77_avexit was asked')
end)

run('the boarding step: a hull hanging over its pad -- no first spot within the clip\'s reach, the plain boarding at once', function()
    -- 3.5 m over its gear: past `MAX_DROP_METRES` (3.0, 1.7.9), never set down.
    enterWorld({ z = 4.5 })
    local pressAt = W.now
    check(W.press(1, 'F'), 'the key')
    W.advance(1500)
    check(lastPlayed(1) == nil, 'no step played')
    local warp = lastWarp(1)
    check(warp ~= nil and warp.at - pressAt <= 400, ('seated plainly at once: %d ms'):format(warp and warp.at - pressAt or -1))
    check(#W.players[1].teleports == 0, 'the body never moved')
    check(W.logged('no first spot within the clip\'s reach', 'client:open77_avdoor:1') ~= nil, 'the client says why')
    check(W.logged('boarding step: none for player 1 (the client: no first spot', 'server:open77_avdoor') ~= nil,
        'and so does the server')
    check(server.env.AvDoor.EnterServer.Status().none == 1, 'counted as a step the client had none for')
end)

run('the boarding step: an older client (no word of the step in its hello) boards plainly, said once', function()
    W.reset()
    W.exitPackage()
    W.vehicle(HULL, AV, 0, 0, 1.0, { halfWidth = 1.84, halfLength = 4.8 })
    W.player(1, -4.0, 0.5, 0.0)
    server = W.server('open77_avdoor', ROOT, SERVER)
    local older = {}
    for _, file in ipairs(CLIENT) do if file ~= 'client/enter.lua' then older[#older + 1] = file end end
    W.client(1, 'open77_avdoor', ROOT, older)
    W.advance(1800)
    local pressAt = W.now
    check(W.press(1, 'F'), 'the key')
    W.advance(1200)
    check(W.lastTo('open77_avdoor:enter', 1) == nil, 'not asked for a step')
    local warp = lastWarp(1)
    check(warp ~= nil and warp.at - pressAt <= 700, 'seated as before')
    check(W.logged('player 1\'s client has not said it knows the step', 'server:open77_avdoor') ~= nil, 'said')
end)

run('the boarding step: no word from the client -- the server seats the body plainly after ASK_MS, the client lets go', function()
    enterWorld({ setup = function() W.lostToServer = { ['open77_avdoor:enterReady'] = true } end })
    local player = W.players[1]
    local pressAt = W.now
    check(W.press(1, 'F'), 'the key')
    W.advance(4000)
    check(lastWarp(1) == nil, 'not seated while the server waits for the word')
    check(player.frozenPosition ~= true and player.covered == nil, 'the client let go of the body and the screen')
    check(W.logged('no word from the server in', 'client:open77_avdoor:1') ~= nil, 'the client gave up waiting')
    W.advance(13000)
    local warp = lastWarp(1)
    -- `ASK_MS` (15 s since 1.7.5: the stand-in's wait is in it) and a second.
    check(warp ~= nil and warp.at - pressAt >= 15000 and warp.at - pressAt <= 16300,
        ('seated plainly %d ms after the key'):format(warp and warp.at - pressAt or -1))
    check(lastPlayed(1) == nil, 'no step played')
    check(W.logged('no word from the client in', 'server:open77_avdoor') ~= nil, 'the server says why')
    check(server.env.AvDoor.EnterServer.Status().silent == 1, 'counted')
end)

run('the boarding step: the hull moved after the key -- the server does not hold the plan, the plain boarding', function()
    enterWorld()
    check(W.press(1, 'F'), 'the key')
    W.advance(30)
    -- The server's hull two metres on: the client planned on where it stood.
    W.vehicles[HULL].y = W.vehicles[HULL].y + 2.0
    W.advance(3000)
    local word = W.lastTo('open77_avdoor:entering', 1)
    check(word ~= nil and word.payload.ok == false and tostring(word.payload.reason):find('first_spot_off', 1, true) == 1,
        'refused: ' .. tostring(word and word.payload.reason))
    check(lastPlayed(1) == nil, 'no step played')
    check(lastWarp(1) ~= nil, 'seated plainly')
    local player = W.players[1]
    check(player.frozenPosition ~= true and player.covered == nil and player.lockedView == nil,
        'the client let go of the body, the screen and the view')
    check(W.logged('refused by the server', 'client:open77_avdoor:1') ~= nil, 'the client says so')
end)

run('the boarding step: a body that never stands on the first spot -- given up, the plain boarding', function()
    enterWorld({ player1 = { hoverWhenFrozen = false } })
    W.players[1].hoverUntil = W.now + 60000
    check(W.press(1, 'F'), 'the key')
    W.advance(5000)
    check(lastPlayed(1) == nil, 'no step played on a body in the air')
    check(lastWarp(1) ~= nil, 'seated plainly')
    check(W.logged('the body never stood on the first spot', 'client:open77_avdoor:1') ~= nil, 'the client says why')
    check(W.players[1].covered == nil, 'no curtain left down')
end)

run('the boarding step: another player takes the pilot\'s seat meanwhile -- the step plays to the same door, the next seat', function()
    enterWorld({ setup = function() W.player(3, 0, 0, 2.5) end, clients = { 1, 2, 3 } })
    check(W.press(1, 'F'), 'the key')
    W.advance(200)
    W.seat(3, HULL, 'seat_front_left')
    W.advance(6000)
    local played = lastPlayed(1)
    check(played ~= nil and played.clip == 'enter', 'the step plays')
    local warp = lastWarp(1)
    check(warp ~= nil and warp.seat ~= 'seat_front_left', 'into the next seat: ' .. tostring(warp and warp.seat))
    check(W.logged('the step plays to it all the same', 'server:open77_avdoor') ~= nil, 'said')
end)

run('the boarding step: a seat the platform refuses as the step ends is tried once more after the clip', function()
    enterWorld()
    local api = server.env.Open77.vehicles
    local warp = api.warpPlayerIntoVehicle
    local refused = 0
    api.warpPlayerIntoVehicle = function(...)
        if refused == 0 then
            refused = 1
            return false, 'player_busy'
        end
        return warp(...)
    end
    check(W.press(1, 'F'), 'the key')
    W.advance(3000)
    local played = lastPlayed(1)
    check(played ~= nil and played.clip == 'enter', 'the step plays')
    W.advance(4000)
    check(refused == 1 and W.players[1].seat ~= nil, 'seated at the second try')
    local seated = lastWarp(1)
    check(seated ~= nil and played ~= nil and seated.at - played.at >= 2600 + 450,
        ('once the clip and its blend are over: %d ms into it'):format(seated and played and seated.at - played.at or -1))
    check(W.logged('tried again in', 'server:open77_avdoor') ~= nil, 'the server says so')
    check(W.players[1].covered == nil and W.players[1].frozenPosition ~= true, 'the image back, the body free')
    check(W.logged('boarding step enter over (seated)', 'client:open77_avdoor:1') ~= nil, 'the client\'s summary')
end)

run('the boarding step: the key pressed while this player\'s own exit is still under way -- the plain boarding, the exit left alone', function()
    world(function()
        W.exitPackage()
        W.vehicle(HULL, AV, 0, 0, 1.0, { halfWidth = 1.84, halfLength = 4.8 })
        W.player(1, 0, 0, 2.0)
        W.player(2, 25, 0, 0)
    end, { 1, 2 })
    W.seat(1, HULL, 'seat_front_left')
    W.advance(1200)
    W.leave(1, { eject = false })
    W.advance(900)
    local pressed = W.press(1, 'F')
    W.advance(1500)
    if pressed then
        check(W.logged('this player\'s exit is still under way on this screen', 'client:open77_avdoor:1') ~= nil,
            'the client gives the step up')
        check(W.players[1].seat ~= nil and (lastPlayed(1) == nil or lastPlayed(1).clip ~= 'enter'),
            'seated plainly, no step played')
        check(W.players[1].covered == nil and W.players[1].frozenPosition ~= true, 'the exit\'s curtain and hold let go')
    else
        check(true, 'no card up during the exit')
    end
end)

run('the boarding step stays inside the host\'s budget on a slow game (four frames a second)', function()
    enterWorld({ player1 = { frameMs = 250 } })
    -- This case's own resumes (the peak is kept across the suite otherwise).
    W.budgetPeak = {}
    check(W.press(1, 'F'), 'the key')
    W.advance(9000)
    check(lastPlayed(1) ~= nil and lastPlayed(1).clip == 'enter', 'the step plays')
    check(W.players[1].seat ~= nil, 'seated')
    local peak = W.budgetPeak['client:open77_avdoor:1']
    check(peak ~= nil and peak.count < 9000, ('the dearest resume: %s'):format(peak and tostring(peak.count) or '?'))
end)

run('1.7.0: every job\'s passes are timed, and a minute in each side says what each job cost', function()
    world(function()
        W.vehicle(HULL, AV, 0, 0, 1.0)
        W.player(1, -4.0, 0.5, 0.0)
    end, { 1 })
    W.advance(61000)
    local serverLine = W.logged('job costs over the last', 'server:open77_avdoor')
    local clientLine = W.logged('job costs over the last', 'client:open77_avdoor:1')
    check(serverLine ~= nil and serverLine:find('scan ', 1, true) ~= nil and serverLine:find('tend ', 1, true) ~= nil,
        'the server: its scan and its tending job, ' .. tostring(serverLine and serverLine:sub(1, 160)))
    check(clientLine ~= nil and clientLine:find('watch ', 1, true) ~= nil, 'the client: its watch')
    local costs = server.env.AvDoor.JobCosts()
    check(type(costs) == 'table', 'the costs since the line, for a status')
    W.advance(300000)
    check(W.count('job costs over the last', 'server:open77_avdoor') == 2, 'then every five minutes')
end)

run('1.7.1: a native that takes 20 ms or more is a line at once, with the job it ran in; its answers are pcall\'s', function()
    world(function()
        W.vehicle(HULL, AV, 0, 0, 1.0)
        W.player(1, -4.0, 0.5, 0.0)
    end, { 1 })
    local AvDoor = clientOf(1).env.AvDoor
    local ok, value = AvDoor.Native('test.slow', function(x)
        W.now = W.now + 30
        return x * 2
    end, 21)
    check(ok == true and value == 42, 'the answers of pcall')
    check(W.logged('slow native: test.slow took 30.0 ms in one call (an event or a one-off', CLIENT1) ~= nil,
        'said at once, outside any pass')
    local bad, why = AvDoor.Native('test.raise', function() error('boom') end)
    check(bad == false and tostring(why):find('boom', 1, true) ~= nil, 'an error as pcall answers it')
    local none, noWhy = AvDoor.Native('test.missing', nil)
    check(none == false and tostring(noWhy):find('no test.missing', 1, true) ~= nil, 'a missing native says so')
    check(AvDoor.NativeCosts()['test.slow'] ~= nil and AvDoor.NativeCosts()['test.slow'].calls == 1, 'counted')
    -- In a job's pass: named.
    AvDoor.Every('testjob', 100, function()
        AvDoor.Native('test.inpass', function() W.now = W.now + 25 end)
    end)
    W.advance(150)
    check(W.logged('slow native: test.inpass took 25.0 ms in one call (the testjob pass', CLIENT1) ~= nil, 'with its pass')
end)

run('1.7.1: a pass\'s own cost leaves out the frames it waited in its breaths; the line ends with the dearest natives', function()
    world(function()
        W.vehicle(HULL, AV, 0, 0, 1.0)
        W.player(1, -4.0, 0.5, 0.0, { frameMs = 250 })
    end, { 1 })
    local AvDoor = clientOf(1).env.AvDoor
    AvDoor.Every('breather', 1000, function()
        W.now = W.now + 3
        AvDoor.Breathe()
        AvDoor.Native('test.cheap', function() W.now = W.now + 2 end)
    end)
    W.advance(61000)
    local line = nil
    for _, entry in ipairs(W.logs) do
        if entry.vm == CLIENT1 and entry.text:find('job costs over the last', 1, true) ~= nil then line = entry.text end
    end
    check(line ~= nil and line:find('breather ', 1, true) ~= nil, 'the job in the line: ' .. tostring(line and line:sub(1, 160)))
    local mean = line ~= nil and tonumber(line:match('breather %d+ pass%(es%), ([%d.]+) ms on average')) or nil
    check(mean ~= nil and mean >= 4.9 and mean <= 5.1, ('its own 5 ms a pass, not the frame it waited: %s'):format(tostring(mean)))
    check(line ~= nil and line:find('the longest 25%d ms with its waits') ~= nil, 'the longest with its waits beside it')
    check(line ~= nil and line:find('natives, the dearest first: test.cheap', 1, true) ~= nil, 'the natives at the end')
end)

-- ── the pad snap (1.7.0) ─────────────────────────────────────────────────────

local PAD_T = { 'T001', 'std', 100.0, 100.0, 20.0, 30.0, 5.0, 90, 'high' }

--- A world with one pad (the list replaced by `rows`), its deck at `deck` within
--- 9 m of its centre (`deckAt` overrides), the ground 0 elsewhere, and an AV
--- flown by player 1 (a client) at `x, y, z` facing `heading`. The snap takes
--- an AV somebody flies glided in view (`PAD_SNAP.ABOARD = true`) unless
--- `opts.aboard` names the mode: 'default' leaves the shipped one (1.8.3: the
--- dock), false leaves such an AV to its pilot. These worlds test the glide.
local function padWorld(opts)
    opts = opts or {}
    local rows = opts.rows or { PAD_T }
    local deck = opts.deck or 20.0
    world(function()
        W.groundAt = opts.groundAt or function(x, y)
            if math.sqrt((x - 100.0) ^ 2 + (y - 100.0) ^ 2) <= 9.0 then return deck end
            return 0.0
        end
        W.vehicle(HULL, opts.record or AV, opts.x or 106.0, opts.y or 96.0, opts.z or 36.0,
            { halfWidth = 1.84, halfLength = 4.8, heading = opts.heading or 50.0 })
        W.player(1, opts.x or 106.0, opts.y or 96.0, (opts.z or 36.0) + 1.0)
        if opts.setup then opts.setup() end
    end, opts.clients or { 1 })
    server.env.AvDoor.Snap.LoadPads(rows)
    if opts.aboard == nil or opts.aboard == false then
        settings().PAD_SNAP.ABOARD = opts.aboard == nil and true or false
        settingsChanged()
    end
    local hull = W.vehicles[HULL]
    W.seat(1, HULL, opts.seat or 'seat_front_left')
    return hull
end

--- The pilot flies: `vz` m/s up (negative: down) and `vx, vy` across, for `ms`, in
--- 100 ms steps -- discarded while the hull is frozen (the platform drops a
--- frozen hull's owner reports) -- and never under its gear on the ground.
local function fly(hull, ms, vz, vx, vy)
    local steps = math.floor(ms / 100)
    for _ = 1, steps do
        if not hull.frozen then
            hull.x = hull.x + (vx or 0) * 0.1
            hull.y = hull.y + (vy or 0) * 0.1
            hull.z = math.max(W.ground(hull.x, hull.y) + 1.0, hull.z + (vz or 0) * 0.1)
        end
        W.advance(100)
    end
end

run('the pad snap: an Excalibur coming down over a pad is caught, its deck measured by the pilot\'s game, glided to the centre, turned to the pad\'s heading and set down on its gear; the pilot has it back (1.7.0)', function()
    local hull = padWorld()
    fly(hull, 16000, -1.0)
    local SRV_LOG = 'server:open77_avdoor'
    check(W.logged('pad snap: aircraft 4294967297 (Vehicle.av_rayfield_excalibur, pilot 1) caught over pad T001', SRV_LOG) ~= nil,
        'caught over the pad')
    check(W.logged('pad snap: the server asks the deck of pad T001 under aircraft 4294967297: ground 20.00, 20.00, 20.00, 20.00',
        CLIENT1) ~= nil, 'the pilot\'s game measured the deck at its centre and under each foot')
    check(W.logged('pad snap: aircraft 4294967297 takes pad T001 (std, high): the deck at 20.00', SRV_LOG) ~= nil, 'and the server took it')
    check(math.abs(hull.x - 100.0) < 1e-6 and math.abs(hull.y - 100.0) < 1e-6, ('centred: %.3f, %.3f'):format(hull.x, hull.y))
    check(math.abs(hull.z - 21.0) < 1e-6, ('on its gear: %.3f (the deck 20 + 1.0)'):format(hull.z))
    check(math.abs(hull.heading - 30.0) < 1e-6, ('turned to the pad\'s heading nearest its own (50 -> 30): %.2f'):format(hull.heading))
    check(#hull.frozenLog == 2 and hull.frozenLog[1].frozen == true and hull.frozenLog[2].frozen == false
        and hull.frozen == false, 'frozen for the glide, and given back')
    check(#hull.transforms > 60, ('posed every 50 ms: %d poses'):format(#hull.transforms))
    local maxStep, maxDown = 0, 0
    for i = 2, #hull.transforms do
        local a, b = hull.transforms[i - 1], hull.transforms[i]
        maxStep = math.max(maxStep, math.sqrt((a.x - b.x) ^ 2 + (a.y - b.y) ^ 2))
        maxDown = math.max(maxDown, a.z - b.z)
        if b.hadYaw ~= true then check(false, 'every pose carries its heading') end
    end
    check(maxStep <= 0.25 and maxDown <= 0.25, ('small steps: %.3f m across, %.3f m down at most'):format(maxStep, maxDown))
    check(W.logged('stands on its gear on pad T001 at 21.00', SRV_LOG) ~= nil
        and W.logged('set down on its gear, centred, heading 30', SRV_LOG) ~= nil, 'the landing in the log')
    check(lastNotice(1) == 'Down on AV pad T001. The controls are yours.', 'and on the pilot\'s screen: ' .. tostring(lastNotice(1)))
    -- Taking off again: never caught by the pad it was set down on until it left it.
    fly(hull, 6000, 2.0)
    check(W.count('caught over pad T001', SRV_LOG) == 1, 'climbing away: not caught again')
    fly(hull, 3000, 0, 12.0, 0)
    check(W.logged('pad snap: aircraft 4294967297 has left pad T001', SRV_LOG) ~= nil, 'gone by REARM_METRES: it may be taken again')
    check(#W.problems() == 0, 'nothing went wrong: ' .. table.concat(W.problems(), ' | '))
    W.groundAt = nil
end)

-- 1.8.2: the server's poses take the flight from its pilot's game every tick
-- and the game claims it back -- the pilot's view flickers between the chase
-- camera and first person for the whole glide (Staging, 2026-10-30). An AV
-- somebody flies is theirs to land; the log says so, once a pad.
run('1.8.2: PAD_SNAP.ABOARD = false leaves an AV somebody flies to its pilot -- not frozen, not posed, said once a pad', function()
    local hull = padWorld({ aboard = false })
    check(server.env.AvDoor.SnapSettings().aboard == false and server.env.AvDoor.SnapSettings().aboardMode == 'off',
        'PAD_SNAP.ABOARD = false')
    fly(hull, 16000, -1.0)
    local SRV_LOG = 'server:open77_avdoor'
    check(W.logged('caught over pad T001', SRV_LOG) == nil and #hull.frozenLog == 0 and #hull.transforms == 0,
        ('never caught, frozen or posed: %d freeze(s), %d pose(s)'):format(#hull.frozenLog, #hull.transforms))
    check(W.logged('pad snap: aircraft 4294967297 over pad T001 (std, high', SRV_LOG) ~= nil
        and W.logged('is not taken: player 1 flies it (in the pilot seat) and PAD_SNAP.ABOARD is false: it is theirs to '
            .. 'land (\'dock\' docks it under a short dip, true glides it in view)', SRV_LOG) ~= nil, 'and why, in the log')
    check(W.count('player 1 flies it', SRV_LOG) == 1, ('once for the pad: %d line(s)'):format(W.count('player 1 flies it',
        SRV_LOG)))
    check(math.abs(hull.z - 21.0) < 0.01, ('the pilot brought it down by hand: %.2f'):format(hull.z))
    check(W.logged('pad snap: the server asks the deck', CLIENT1) == nil, 'the pilot\'s game is never asked to measure')
    check(#W.problems() == 0, 'nothing went wrong: ' .. table.concat(W.problems(), ' | '))
    W.groundAt = nil
end)

--- Whether a player's screen was covered at a moment: after a fade-out had run
--- and before the fade-in that followed it.
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

-- 1.8.3: "the AV pad isn't snapping the AV to the pad" (Staging, 2026-10-30,
-- 1.8.2 left an AV somebody flies to its pilot). Docked: one move under a dip.
run('1.8.3: the pad snap DOCKS an AV somebody flies -- every screen aboard dips to black, ONE move onto the deck under it, the image back with the AV standing there (the default)', function()
    local hull = padWorld({ aboard = 'default', clients = { 1, 2 }, setup = function()
        W.player(2, 106.0, 96.0, 37.0)
    end })
    W.seat(2, HULL, 'seat_back_left')
    local cfg = server.env.AvDoor.SnapSettings()
    check(cfg.aboardMode == 'dock' and cfg.dock.out == 200 and cfg.dock.wait == 1000 and cfg.dock.hold == 500
        and cfg.dock.back == 350, 'the dock is the default: 200 ms dip, 1 s wait, 500 ms hold, 350 ms back')
    local SRV_LOG = 'server:open77_avdoor'
    fly(hull, 16000, -1.0)
    check(W.logged('pad snap: aircraft 4294967297 (Vehicle.av_rayfield_excalibur, pilot 1) caught over pad T001', SRV_LOG)
        ~= nil, 'caught over the pad')
    check(W.logged('pad snap: aircraft 4294967297 takes pad T001 (std, high) DOCKED: the deck at 20.00', SRV_LOG) ~= nil
        and W.logged('in one move once the screens of 1:seat_front_left, 2:seat_back_left are black (200 ms dip, 1000 ms '
            .. 'at most)', SRV_LOG) ~= nil, 'docked, the crew named')
    check(#hull.transforms == 1, ('ONE move: %d pose(s)'):format(#hull.transforms))
    local pose = hull.transforms[1]
    check(pose ~= nil and math.abs(pose.x - 100.0) < 1e-6 and math.abs(pose.y - 100.0) < 1e-6
        and math.abs(pose.z - 21.0) < 1e-6 and math.abs(pose.yaw - 30.0) < 1e-6 and pose.hadYaw,
        'centred, on its gear, turned to the pad\'s heading')
    check(pose ~= nil and coveredAt(1, pose.at) and coveredAt(2, pose.at), 'the move under the black of both screens')
    check(#hull.frozenLog == 2 and hull.frozenLog[1].frozen and not hull.frozenLog[2].frozen and not hull.frozen
        and pose ~= nil and hull.frozenLog[1].at <= pose.at and hull.frozenLog[2].at - pose.at >= 500,
        'frozen for the move, held 500 ms, given back')
    local f1 = W.players[1].fades
    local f2 = W.players[2].fades
    check(#f1 == 2 and f1[1].out and f1[1].options.durationMs == 200 and not f1[2].out and f1[2].options.durationMs == 350,
        'the pilot\'s screen: 200 ms out, 350 ms back')
    check(#f2 == 2 and f2[1].out and not f2[2].out, 'the passenger\'s too')
    check(f1[2] ~= nil and f1[2].at >= hull.frozenLog[2].at, 'the image back once the freeze is off')
    local dipped = W.sent('open77_avdoor:snapDipReady')
    check(#dipped == 1 and dipped[1].from == 1 and dipped[1].payload.state == 'black', 'only the pilot\'s game answered')
    check(W.logged('pad snap: aircraft 4294967297 docked on pad T001 -- the pilot\'s screen is black', SRV_LOG) ~= nil
        and W.logged('docked on its gear, centred, heading 30', SRV_LOG) ~= nil, 'the dock in the log')
    check(W.logged('pad snap: docking on pad T001 -- the screen dips to black (200 ms) (the pilot)', CLIENT1) ~= nil
        and W.logged('pad snap: docked on pad T001', CLIENT1) ~= nil, 'and in the pilot\'s game\'s log')
    check(lastNotice(1) == 'Down on AV pad T001. The controls are yours.', 'and on the pilot\'s screen: '
        .. tostring(lastNotice(1)))
    check(#W.problems() == 0, 'nothing went wrong: ' .. table.concat(W.problems(), ' | '))
    W.groundAt = nil
end)

run('1.8.3: a dock whose pilot\'s game cannot dip is moved in view and said; one with no word moves after DOCK.WAIT_MS; the pilot leaving during the dip ends it with the screens back', function()
    local SRV_LOG = 'server:open77_avdoor'
    -- The dip refused.
    local hull = padWorld({ aboard = 'default', setup = function() W.players[1].fadeRefused = true end })
    fly(hull, 16000, -1.0)
    check(#hull.transforms == 1 and math.abs(hull.z - 21.0) < 1e-6, 'docked all the same')
    check(W.logged('the pilot\'s game could not dip (transition_busy): moved in view', SRV_LOG) ~= nil, 'and said')
    W.groundAt = nil
    -- No game answers: the pilot runs no avdoor client here.
    hull = padWorld({ aboard = 'default', clients = {} })
    fly(hull, 3000, -1.0)
    -- With no client, nobody measures: the snap is refused after MEASURE_MS.
    check(W.logged('the pilot\'s game sent no measure of the deck', SRV_LOG) ~= nil, 'no game, no measure: refused')
    W.groundAt = nil
    -- A screen that never says black: moved after DOCK.WAIT_MS, and said.
    hull = padWorld({ aboard = 'default', setup = function() W.players[1].fadeNeverBlack = true end })
    fly(hull, 16000, -1.0)
    check(#hull.transforms == 1 and math.abs(hull.z - 21.0) < 1e-6, 'docked after the wait')
    check(W.logged('no word that the pilot\'s screen is black after 1000 ms: moved all the same', SRV_LOG) ~= nil,
        'and said')
    W.groundAt = nil
    -- The pilot leaves during the dip: nothing moved, the screens back.
    hull = padWorld({ aboard = 'default', setup = function() W.players[1].fadeNeverBlack = true end })
    local dipWorld = function()
        for _ = 1, 200 do
            local flying = server.env.AvDoor.Snap.Status().flying
            if flying[1] ~= nil and flying[1].phase == 'dip' then return true end
            fly(hull, 100, -1.0)
        end
        return false
    end
    check(dipWorld(), 'the dip asked')
    hull.seats.seat_front_left = nil
    W.players[1].seat = nil
    W.advance(1200)
    check(#hull.transforms == 0 and #hull.frozenLog == 0, ('never frozen, never moved: %d pose(s), %d freeze(s)')
        :format(#hull.transforms, #hull.frozenLog))
    check(W.logged('pilot 1 left the seat', SRV_LOG) ~= nil, 'ended: the pilot left')
    local fades = W.players[1].fades
    check(fades[#fades] ~= nil and not fades[#fades].out, 'the screen back')
    W.groundAt = nil
end)

run('the pad snap leaves alone an AV flying across a pad, one that climbs, and one another resource froze', function()
    local hull = padWorld({ x = 70.0, y = 100.0, z = 30.0 })
    hull.speed = 20.0
    fly(hull, 3000, 0, 20.0, 0)
    local SRV_LOG = 'server:open77_avdoor'
    check(W.logged('caught over pad', SRV_LOG) == nil, 'across at 20 m/s: never caught')
    hull.speed = 0.0
    hull.x, hull.y, hull.z = 103.0, 100.0, 30.0
    fly(hull, 2000, 3.0)
    check(W.logged('caught over pad', SRV_LOG) == nil, 'climbing: never caught')
    hull.x, hull.y, hull.z = 103.0, 100.0, 30.0
    hull.frozen = true
    fly(hull, 3000, 0)
    check(W.logged('caught over pad', SRV_LOG) == nil and #hull.transforms == 0, 'frozen by another resource: never taken')
    W.groundAt = nil
end)

run('1.7.1: the pad snap takes an AV flown from a back seat -- the seated player whose game simulates it is its pilot (Staging, 2026-10-29)', function()
    local hull = padWorld({ seat = 'seat_back_left' })
    -- The platform made the back seat's game the hull's simulator ("simulated by
    -- player 2 now ... seated 2:seat_back_left").
    hull.physicsOwner = 1
    fly(hull, 16000, -1.0)
    local SRV_LOG = 'server:open77_avdoor'
    check(W.logged('pad snap: aircraft 4294967297 (Vehicle.av_rayfield_excalibur, pilot 1 flying it from seat_back_left) over pad T001', SRV_LOG) ~= nil,
        'watched over the pad, its pilot the back seat\'s')
    check(W.logged('caught over pad T001', SRV_LOG) ~= nil and W.logged('(flying it from seat_back_left) at 4 point(s)', SRV_LOG) ~= nil,
        'caught, the deck asked of that game')
    check(math.abs(hull.x - 100.0) < 1e-6 and math.abs(hull.y - 100.0) < 1e-6 and math.abs(hull.z - 21.0) < 1e-6,
        ('centred and on its gear: %.2f, %.2f, %.2f'):format(hull.x, hull.y, hull.z))
    check(W.logged('stands on its gear on pad T001', SRV_LOG) ~= nil, 'set down')
    W.groundAt = nil
end)

run('1.7.1: the pad snap takes an AV whose controller only the platform names (`Open77.vehicles.owner(id).driver`, any occupant of an AV)', function()
    local hull = padWorld({ seat = 'seat_back_left' })
    hull.physicsOwner = 0
    hull.ownerDriver = 1
    fly(hull, 16000, -1.0)
    local SRV_LOG = 'server:open77_avdoor'
    check(W.logged('pilot 1 its controller from seat_back_left (the platform\'s word)) over pad T001', SRV_LOG) ~= nil,
        'its pilot the platform\'s controller')
    check(W.logged('stands on its gear on pad T001', SRV_LOG) ~= nil, 'set down on the pad')
    W.groundAt = nil
end)

run('1.7.1: an AV over a pad with somebody aboard and nobody flying it is passed by, and the log says why -- once', function()
    local hull = padWorld({ seat = 'seat_back_left' })
    hull.physicsOwner = 0
    fly(hull, 6000, -1.0)
    local SRV_LOG = 'server:open77_avdoor'
    check(W.logged('caught over pad', SRV_LOG) == nil, 'not caught')
    check(W.count('over pad T001 (std, high', SRV_LOG) == 1 and W.logged('is not taken: nobody flies it (aboard: 1:seat_back_left', SRV_LOG) ~= nil,
        ('said once: %d line(s)'):format(W.count('is not taken: nobody flies it', SRV_LOG)))
    W.groundAt = nil
end)

run('1.7.1: an AV with a pilot too fast across a pad, or climbing over it, says why -- once a reason', function()
    local hull = padWorld({ x = 80.0, y = 100.0, z = 30.0 })
    hull.speed = 15.0
    fly(hull, 2000, 0, 12.0, 0)
    local SRV_LOG = 'server:open77_avdoor'
    check(W.count('is not taken: 15.0 m/s across (taken under 10.0)', SRV_LOG) == 1, 'too fast: said once')
    hull.speed = 0.0
    fly(hull, 2000, 3.0)
    check(W.count('is not taken: climbing', SRV_LOG) == 1, 'climbing: said once')
    check(W.logged('caught over pad', SRV_LOG) == nil, 'never caught')
    W.groundAt = nil
end)

run('the pad snap: a deck that is not where the pad list says (another floor, a canopy) is left to the pilot, and said', function()
    local hull = padWorld({ deck = 29.0 })
    fly(hull, 4000, -0.5)
    check(W.logged('is left to its pilot over pad T001 (std, high): the deck under its centre is at 29.00, 9.00 m from where the '
        .. 'pad list has it', 'server:open77_avdoor') ~= nil, 'refused, and why')
    check(#hull.frozenLog == 0 and #hull.transforms == 0, 'never frozen, never posed')
    W.groundAt = nil
end)

run('the pad snap: an airframe whose gear is not known is brought to a hover over the centre, turned, for its pilot to set down', function()
    local hull = padWorld({ record = 'Vehicle.av_militech_manticore' })
    fly(hull, 14000, -1.0)
    local last = hull.transforms[#hull.transforms] or {}
    check(math.abs((last.x or 0) - 100.0) < 1e-6 and math.abs((last.y or 0) - 100.0) < 1e-6 and math.abs((last.z or 0) - 22.5) < 1e-6,
        ('posed last 2.5 m over the deck, over its centre: %.2f, %.2f, %.2f'):format(last.x or 0, last.y or 0, last.z or 0))
    check(W.logged('hovers on pad T001 at 22.50', 'server:open77_avdoor') ~= nil
        and W.logged('brought to a hover over the centre', 'server:open77_avdoor') ~= nil, 'said')
    check(hull.frozen == false, 'and given back')
    W.groundAt = nil
end)

run('the pad snap: a pilot who leaves the seat in the glide ends it at once, the freeze off', function()
    local hull = padWorld()
    fly(hull, 3000, -1.0)
    check(hull.frozen == true, 'gliding')
    W.leave(1, { eject = false })
    W.advance(500)
    check(hull.frozen == false and W.logged('pad snap: aircraft 4294967297 on pad T001: pilot 1 left the seat',
        'server:open77_avdoor') ~= nil, 'ended, the freeze off')
    W.groundAt = nil
end)

run('the pad snap: a pilot\'s game that never measures (no client) is not waited for past MEASURE_MS', function()
    local hull = padWorld({ clients = {} })
    fly(hull, 5000, -0.5)
    check(W.logged('the pilot\'s game sent no measure of the deck within 2.0s', 'server:open77_avdoor') ~= nil, 'said')
    check(#hull.frozenLog == 0, 'never frozen')
    W.groundAt = nil
end)

run('the pad list: every AV pad of the game, loaded and found by the grid', function()
    world(function() end, {})
    local Snap = server.env.AvDoor.Snap
    local count = Snap.LoadPads()
    check(count >= 200, 'the list loads: ' .. count .. ' pads')
    local kinds = {}
    for _, row in ipairs(server.env.AvDoor.PAD_ROWS) do kinds[row[2]] = (kinds[row[2]] or 0) + 1 end
    check((kinds.std or 0) >= 80 and (kinds.mega or 0) >= 25 and (kinds.area or 0) >= 25, 'each kind is there')
    -- Every pad is found by the grid at its own centre, and the nearest is itself.
    local missing = 0
    for _, row in ipairs(server.env.AvDoor.PAD_ROWS) do
        local found = false
        for _, pad in ipairs(Snap.PadsAt(row[3], row[4])) do if pad.id == row[1] then found = true end end
        if not found then missing = missing + 1 end
    end
    check(missing == 0, 'every pad is in its own grid cell: ' .. missing .. ' missing')
    check(Snap.Heading({ yaw = 30.0, sym = 90 }, 50.0) == 30.0 and Snap.Heading({ yaw = 30.0, sym = 90 }, 100.0) == 120.0
        and Snap.Heading({ yaw = 30.0, sym = 180 }, 250.0) == 210.0 and Snap.Heading({ yaw = nil }, 77.0) == 77.0,
        'the landing heading: the pad\'s nearest to the hull\'s own')
    local text = Snap.Describe(-54.0, -36.0, 3)
    check(text:find('pad P', 1, true) ~= nil, 'the console lists the pads near a point')
    -- Which way, in the game's axes (x east, y north), and how high the deck stands over the asker.
    local ways = { { 0, 10, 'north' }, { 10, 10, 'north-east' }, { 10, 0, 'east' }, { 10, -10, 'south-east' },
        { 0, -10, 'south' }, { -10, -10, 'south-west' }, { -10, 0, 'west' }, { -10, 10, 'north-west' }, { 0.2, 0.3, 'here' } }
    local wrong = {}
    for _, w in ipairs(ways) do
        local got = Snap.Compass(0, 0, w[1], w[2])
        if got ~= w[3] then wrong[#wrong + 1] = ('%s for %s'):format(got, w[3]) end
    end
    check(#wrong == 0, 'eight ways round, and here: ' .. table.concat(wrong, ', '))
    local first = server.env.AvDoor.PAD_ROWS[1]
    local near = Snap.Describe(first[3] - 0.5, first[4] - 0.5, 1, first[5] - 30.0)
    check(near:find('pad ' .. first[1] .. ' (', 1, true) ~= nil and near:find(': here, its deck 30 m above you', 1, true) ~= nil,
        'on the pad, how high: ' .. tostring(near:match('\n([^\n]*)')))
    -- The command: the player's own spot, its height too.
    world(function()
        W.player(1, first[3] - 20.0, first[4], first[5] + 2.0)
    end, { 1 })
    local command = server.commands['avdoor.pads']
    check(command ~= nil and command.restricted == false, 'a command every player may type')
    local snapNow = server.env.AvDoor.Snap
    local describe, asked, answer = snapNow.Describe, nil, nil
    snapNow.Describe = function(...)
        asked = { ... }
        answer = describe(...)
        return answer
    end
    command.fn(1, {}, 'avdoor.pads')
    snapNow.Describe = describe
    check(asked ~= nil and type(asked[4]) == 'number' and math.abs(asked[4] - (first[5] + 2.0)) < 0.01,
        'the player\'s height is passed')
    check(type(answer) == 'string' and answer:find('pad ' .. first[1] .. ' (', 1, true) ~= nil
        and answer:find('20 m east, its deck 2 m below you', 1, true) ~= nil,
        'the answer: ' .. tostring(answer and answer:sub(1, 400)))
end)

run('/avdoor.groundtest: on foot, fourteen steps -- a move, the freeze, a move while held, the restriction, the native fade -- each change and each end in the log, every hold and the fade let go', function()
    world(function()
        W.vehicle(HULL, AV, 30, 0, 1.0, { halfWidth = 1.84, halfLength = 4.8 })
        W.player(1, 0, 0, 0)
    end, { 1 })
    local command = server.commands['avdoor.groundtest']
    check(command ~= nil and command.restricted == false, 'a command every player may type')
    command.fn(1, {}, 'avdoor.groundtest')
    W.advance(30000)
    local steps = 0
    for _, entry in ipairs(W.logs) do
        if entry.vm == CLIENT1 and entry.text:find('^ground test %d+/14 %(.-%): at its end') then steps = steps + 1 end
    end
    check(steps == 14, ('every step said at its end: %d'):format(steps))
    check(W.logged('ground test over: 1 on the ground; 2 on the ground; 3 on the ground', CLIENT1) ~= nil,
        'and a line of what each step ended with: ' .. tostring(W.logged('ground test over', CLIENT1)))
    check(W.logged('ground test 5/14 (held, then moved where it stands while held): off the ground', CLIENT1) ~= nil,
        'a move while held takes the body off the ground (this world: the forced freeze keeps it where it took it)')
    -- THE NATIVE FADE (1.6.0): standing when it came, standing under it; moved
    -- under it, in the air until the image is back; then down.
    check(W.logged('ground test 12/14 (the screen black (a native fade), nobody holding it): at its end on the ground',
        CLIENT1) ~= nil, 'standing when the screen went black: standing under it')
    check(W.logged('ground test 13/14 (moved 5 cm up where it stands, under the black): at its end off the ground',
        CLIENT1) ~= nil, 'moved under the black: off the ground to the step\'s end')
    check(W.logged('ground test 14/14 (the image back (the fade lifted at once)): at its end on the ground', CLIENT1) ~= nil,
        'the image back: it lands')
    check(W.logged('the screen black (a native fade: the body held still where it is)', CLIENT1) ~= nil,
        'the screen said in the step lines')
    local player = W.players[1]
    check(player.frozenPosition ~= true and player.restricted ~= true and player.covered == nil,
        'every hold and the fade let go at the end')
    check(math.abs(player.x) < 0.01 and math.abs(player.y) < 0.01, 'the body moved only where it stood')
    command.fn(1, {}, 'avdoor.groundtest')
    check(W.logged('avdoor.groundtest: already running on your game', SRV) == nil, 'asked again later, it runs again')
end)

run('/avdoor.groundtest in a vehicle: not run, and why', function()
    world(function()
        W.exitPackage()
        W.vehicle(HULL, AV, 0, 0, 1.0, { halfWidth = 1.84, halfLength = 4.8 })
        W.player(1, 0, 0, 2.0)
    end, { 1 })
    W.seat(1, HULL, 'seat_front_left')
    W.advance(1000)
    server.commands['avdoor.groundtest'].fn(1, {}, 'avdoor.groundtest')
    W.advance(2000)
    check(W.logged('ground test not run: the body is in a vehicle', CLIENT1, 'warn') ~= nil, 'said')
    check(#W.players[1].frozenLog == 0, 'nothing held')
end)

-- ── the host's sandbox (1.5.2) ───────────────────────────────────────────────
run('every client script loads in the host\'s sandbox: no setmetatable, load, os or debug; the scheduler\'s coroutines', function()
    world(function()
        W.vehicle(HULL, AV, 0, 0, 1.0)
        W.player(1, 0, 0, 0)
    end, { 1 })
    local vm = W.vms[CLIENT1]
    local env = vm ~= nil and vm.env or nil
    check(env ~= nil and type(rawget(env, 'AvDoor')) == 'table' and type(env.AvDoor.VERSION) == 'string'
        and env.AvDoor.WalkOut ~= nil and env.AvDoor.Shots ~= nil and env.AvDoor.Sync ~= nil,
        'every client script ran to its end')
    for _, key in ipairs({ 'setmetatable', 'getmetatable', 'load', 'loadfile', 'dofile', 'collectgarbage', 'os', 'io',
        'debug', 'package' }) do
        check(env ~= nil and env[key] == nil, 'the client has no ' .. key .. ', as in the game')
    end
    check(env ~= nil and env.coroutine.create == nil and env.coroutine.resume == nil and env.coroutine.wrap == nil
        and type(env.coroutine.isyieldable) == 'function', 'its coroutines are the scheduler\'s')
    check(env ~= nil and env.string.dump == nil and type(env.string.format) == 'function', 'no string.dump')
    -- The memos that were weak tables in 1.5.1: plain, and bounded.
    local M = env ~= nil and env.AvDoor or nil
    local lists = 0
    for i = 1, 40 do
        if M ~= nil and M.IsAircraft('Vehicle.av_rayfield_excalibur', { 'av_' .. i, 'excalibur' }) then
            lists = lists + 1
        end
    end
    check(lists == 40, 'an aircraft by any pattern list, forty lists asked: ' .. lists)
    check(M ~= nil and M.IsAircraft('Vehicle.v_sport2_quadra_type66', nil) == false, 'a car is not one')
    check(#W.problems(CLIENT1) == 0, 'and nothing went wrong: ' .. table.concat(W.problems(CLIENT1), ' | '))
    -- THE SUITE LOADS WHAT THE GAME LOADS: the manifest's shared and client
    -- scripts, in its order (a script the manifest names and the suite does not
    -- load would go to the game untested).
    local manifest = io.open(ROOT .. '/open77.lua'):read('a')
    local named = {}
    for kind, file in manifest:gmatch('\n(%a+)_script "([^"]+)"') do
        if kind == 'shared' or kind == 'client' then named[#named + 1] = file end
    end
    check(table.concat(named, ' ') == table.concat(CLIENT, ' '),
        'the suite loads the manifest\'s client scripts: ' .. table.concat(named, ' '))
end)

-- ── 1.8.4: boarding behind a pilot ──────────────────────────────────────────
-- "make sure when other players get in AV while a player is pilot they use the
-- enter anim that is free" (Staging, 2026-10-30). The flight parks an AV its
-- pilot sits in 0.4 m over its gear: the back seat's climb and the door's step
-- both out of reach, and the set-down of 1.7.1 refused with somebody aboard --
-- a plain boarding. And two at the door at once both got the back-left seat.

run('1.8.4: behind a pilot whose flight holds the AV 0.45 m over its gear -- set down for the boarding in ONE move, FROZEN, Corpo V\'s climb into the free back seat, let go once seated', function()
    enterWorld({ z = 1.45, setup = function() W.sitBoarding = true end })
    W.seat(2, HULL, 'seat_front_left')
    local hull = W.vehicles[HULL]
    hull.revokeOnTransform = true
    W.advance(600)
    check(hull.physicsOwner == 2, 'the pilot\'s game simulates it')
    local moves = #hull.transforms
    local player = W.players[1]
    check(W.press(1, 'F'), 'the key')
    W.advance(60)
    local ask = W.lastTo('open77_avdoor:enter', 1)
    check(ask ~= nil and ask.payload.clip == 'couch' and ask.payload.seat == 'seat_back_left',
        ('the free seat and its own clip: %s into %s'):format(tostring(ask and ask.payload.clip),
            tostring(ask and ask.payload.seat)))
    W.advance(400)
    check(#hull.transforms == moves + 1 and math.abs(hull.z - 1.0) < 0.01,
        ('set down on its gear in one move: %.2f, %d move(s)'):format(hull.z, #hull.transforms - moves))
    local frozeAt = hull.frozenLog[#hull.frozenLog]
    check(hull.frozen == true and frozeAt ~= nil and frozeAt.frozen == true and frozeAt.at <= hull.transforms[#hull.transforms].at,
        'frozen first')
    check(W.logged('set down on its gear 0.45 m lower for a boarding', SRV) ~= nil
        and W.logged('1 aboard: ONE move, FROZEN and held on its gear until the boarding body is seated', SRV) ~= nil,
        'said')
    check(W.logged('stays where the flight left it', SRV) == nil, 'not refused for the pilot aboard')
    W.advance(1200)
    local again = W.lastTo('open77_avdoor:enter', 1)
    check(again ~= nil and again.payload.again == true and again.payload.clip == 'couch'
        and math.abs(again.payload.hull.z - 1.0) < 0.01, 'asked again, couch, on the hull on its gear')
    W.advance(3000)
    local played = lastPlayed(1)
    check(played ~= nil and played.clip == 'couch', 'Corpo V\'s climb plays')
    check(hull.frozen == true and math.abs(hull.z - 1.0) < 0.01, 'held on its gear through the climb')
    W.advance(6000)
    local warp = lastWarp(1)
    check(warp ~= nil and warp.seat == 'seat_back_left' and player.seat ~= nil, 'seated on the back-left seat')
    check(W.players[2].seat ~= nil and W.players[2].seat.seat == 'seat_front_left', 'the pilot still in the pilot seat')
    local last = hull.frozenLog[#hull.frozenLog]
    check(hull.frozen == false and last.frozen == false and warp ~= nil and last.at >= warp.at,
        'let go once the body was seated')
    check(W.logged('let go after', SRV) ~= nil and W.logged('the pilot\'s flight has it again', SRV) ~= nil, 'said')
    check(#hull.transforms == moves + 1, 'one move in all: no glide')
    W.advance(400)
    check(hull.physicsOwner == 2, 'the pilot\'s game has it again')
    local status = server.env.AvDoor.EnterServer.Status()
    check(status.plain == 0 and status.played == 1 and status.setDown == 1,
        ('counted: %d plain, %d played, %d set down'):format(status.plain, status.played, status.setDown))
    check(server.env.AvDoor.Land.Status().held == 0, 'nothing held any more')
end)

run('1.8.4: three at the door of an AV whose pilot is aboard, at once -- each into a free seat with that seat\'s own clip, never the same seat: Corpo V\'s climb into the back-left one, the door\'s step into the back-right one and the one beside the pilot', function()
    enterWorld({ setup = function()
        W.sitBoarding = true
        W.player(3, -4.0, -0.3, 0.0)
        W.player(4, -4.0, 1.2, 0.0)
    end, clients = { 1, 2, 3, 4 } })
    W.seat(2, HULL, 'seat_front_left')
    W.advance(600)
    check(W.press(1, 'F'), 'player 1\'s key')
    W.advance(40)
    check(W.press(3, 'F'), 'player 3\'s key')
    W.advance(40)
    check(W.press(4, 'F'), 'player 4\'s key')
    W.advance(60)
    local asks = {}
    for _, id in ipairs({ 1, 3, 4 }) do asks[id] = W.lastTo('open77_avdoor:enter', id) end
    check(asks[1] ~= nil and asks[1].payload.seat == 'seat_back_left' and asks[1].payload.clip == 'couch',
        'player 1: Corpo V\'s climb into the back-left seat')
    check(asks[3] ~= nil and asks[3].payload.seat == 'seat_back_right' and asks[3].payload.clip == 'enter',
        ('player 3: the door\'s step into the back-right seat (%s, %s)'):format(tostring(asks[3] and asks[3].payload.seat),
            tostring(asks[3] and asks[3].payload.clip)))
    check(asks[4] ~= nil and asks[4].payload.seat == 'seat_front_right' and asks[4].payload.clip == 'enter',
        ('player 4: the door\'s step into the seat beside the pilot (%s, %s)'):format(
            tostring(asks[4] and asks[4].payload.seat), tostring(asks[4] and asks[4].payload.clip)))
    W.advance(14000)
    for id, want in pairs({ [1] = { 'couch', 'seat_back_left' }, [3] = { 'enter', 'seat_back_right' },
        [4] = { 'enter', 'seat_front_right' } }) do
        local played, warp = lastPlayed(id), lastWarp(id)
        check(played ~= nil and played.clip == want[1], ('player %d: %s played'):format(id, want[1]))
        check(warp ~= nil and warp.seat == want[2] and W.players[id].seat ~= nil,
            ('player %d seated in %s (%s)'):format(id, want[2], tostring(warp and warp.seat)))
    end
    check(W.players[2].seat ~= nil and W.players[2].seat.seat == 'seat_front_left', 'the pilot where they were')
    check(server.env.AvDoor.EnterServer.Status().plain == 0, 'no plain boarding')
    -- A fifth: every seat taken.
    W.player(5, -4.0, 0.0, 0.0)
    W.client(5, 'open77_avdoor', ROOT, CLIENT)
    W.advance(1500)
    local verdict, why = server.env.AvDoor.Verdict(5, HULL)
    check(verdict == nil and why == 'no_seat', 'a fifth: every seat taken -- ' .. tostring(why))
end)

run('1.8.4: the only free seat is being stepped into -- a second body is told so, and boards once it is free again; a step given up lets its seat go', function()
    enterWorld({ setup = function()
        W.sitBoarding = true
        W.player(3, -4.0, -0.3, 0.0)
        W.player(5, 30, 0, 0)
        W.player(6, 31, 0, 0)
    end, clients = { 1, 2, 3 } })
    W.seat(2, HULL, 'seat_front_left')
    W.seat(5, HULL, 'seat_back_right')
    W.seat(6, HULL, 'seat_front_right')
    W.advance(600)
    check(W.press(1, 'F'), 'player 1 boards the last free seat')
    W.advance(60)
    local verdict, why = server.env.AvDoor.Verdict(3, HULL)
    check(verdict == nil and why == 'seats_boarding', 'player 3: the last seat is being boarded -- ' .. tostring(why))
    check(server.env.AvDoor.Strings.en['refused.seatsBoarding'] ~= nil
        and server.env.AvDoor.Strings.fr['refused.seatsBoarding'] ~= nil, 'in words, both languages')
    -- Player 1 walks away: the step is given up, the seat is free again.
    server.env.AvDoor.EnterServer.Forget(1)
    verdict, why = server.env.AvDoor.Verdict(3, HULL)
    check(verdict ~= nil and verdict.seat == 'seat_back_left', 'free again once that boarding is over -- '
        .. tostring(verdict and verdict.seat or why))
end)

run('1.8.4: a hull held on its gear for a boarding is let go when the boarding is given up, at the latest after BOARD.ABOARD_HOLD_MS; one hanging past ABOARD_DROP_METRES is its pilot\'s; an exit never sets down a hull somebody is aboard', function()
    enterWorld({ z = 1.45, setup = function() W.sitBoarding = true end })
    W.seat(2, HULL, 'seat_front_left')
    local hull = W.vehicles[HULL]
    W.advance(600)
    check(W.press(1, 'F'), 'the key')
    W.advance(500)
    check(hull.frozen == true and math.abs(hull.z - 1.0) < 0.01, 'set down and held')
    -- The boarding player leaves.
    server.env.AvDoor.EnterServer.Forget(1)
    check(hull.frozen == false, 'let go at once')
    check(W.logged('let go after 0.5s on its gear for a boarding (player 1 left)', SRV) ~= nil, 'said why')
    -- Held, and the boarding never ends: let go after ABOARD_HOLD_MS all the same.
    local L = server.env.AvDoor.Land
    hull.z = 1.45
    local ok = L.Lower(HULL_TEXT, { id = HULL, player = 9, at = W.now, record = AV, what = 'boarding' },
        { grounds = { 0.0, 0.0, 0.0 }, x = 0.0, y = 0.0 })
    check(ok == true and hull.frozen == true and L.Status().held == 1 and math.abs(hull.z - 1.0) < 0.01,
        'held for a boarding nobody ends')
    W.advance(19000)
    check(hull.frozen == true, 'still held before ABOARD_HOLD_MS')
    W.advance(1500)
    check(hull.frozen == false and L.Status().held == 0, 'let go after ABOARD_HOLD_MS')
    check(W.logged('the most a boarding may', SRV) ~= nil, 'and said')
    -- 1.6 m over its gear: past ABOARD_DROP_METRES -- the pilot holds it there.
    hull.z = 2.6
    local done = L.Lower(HULL_TEXT, { id = HULL, player = 9, at = W.now, record = AV, what = 'boarding' },
        { grounds = { 0.0, 0.0, 0.0 }, x = 0.0, y = 0.0 })
    check(done == false and hull.frozen == false and math.abs(hull.z - 2.6) < 1e-6, 'not touched')
    check(W.logged('past BOARD.ABOARD_DROP_METRES (1.0): its pilot holds it there', SRV) ~= nil, 'said')
    -- An exit is never this: somebody aboard, nothing moves.
    hull.z = 1.45
    done = L.Lower(HULL_TEXT, { id = HULL, player = 9, at = W.now, record = AV, what = 'exit' },
        { grounds = { 0.0, 0.0, 0.0 }, x = 0.0, y = 0.0 })
    check(done == false and math.abs(hull.z - 1.45) < 1e-6 and W.logged('stays where the flight left it: 1 aboard', SRV)
        ~= nil, 'an exit\'s set-down with somebody aboard is refused, as before')
    -- `ABOARD_DROP_METRES = 0`: a boarding behind a pilot never moves the hull.
    server.env.AvDoor.Settings.BOARD.ABOARD_DROP_METRES = 0
    server.env.AvDoor.SettingsChanged()
    done = L.Lower(HULL_TEXT, { id = HULL, player = 9, at = W.now, record = AV, what = 'boarding' },
        { grounds = { 0.0, 0.0, 0.0 }, x = 0.0, y = 0.0 })
    check(done == false and math.abs(hull.z - 1.45) < 1e-6, 'off: not touched')
end)

if W.budgetHot ~= nil then
    local rows = {}
    for key, row in pairs(W.budgetHot) do rows[#rows + 1] = { key = key, row = row } end
    table.sort(rows, function(a, b) return a.row.self > b.row.self end)
    print('-- self (instructions charged while the function itself ran)')
    for i = 1, math.min(#rows, 45) do
        print(('%9d self %9d incl  %s'):format(rows[i].row.self, rows[i].row.incl, rows[i].key))
    end
end
if os.getenv('AVDOOR_BUDGET_PROFILE') ~= nil then
    local rows = {}
    for origin, row in pairs(W.budgetByOrigin) do rows[#rows + 1] = { origin = origin, row = row } end
    table.sort(rows, function(a, b) return a.row.peak > b.row.peak end)
    for i = 1, math.min(#rows, 40) do
        local r = rows[i]
        print(('%6d peak  %6d resumes  %5d >=6000  %s  (peak at %s)'):format(r.row.peak, r.row.resumes, r.row.over,
            r.origin, tostring(r.row.where)))
    end
end
TestResult = { passed = passed, failed = #failures, failures = failures }
if Open77ResourcesRoot == nil then
    for _, failure in ipairs(failures) do print('FAIL ' .. failure) end
    print(('%d passed, %d failed'):format(passed, #failures))
    if #failures > 0 then os.exit(1) end
end
