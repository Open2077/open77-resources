-- =============================================================================
-- open77_avlanding -- tests/avlanding_test.lua
-- =============================================================================
-- The REAL client half, one VM per player, on the simulated platform of
-- open77_avdoor/tests/world.lua: aircraft that come down, land, sit idle, fly
-- level, leave; the sign's place, turn and life, the band, the cap, a game
-- without the archive, and a stop.
--
-- Runs two ways:
--   * in the C# suite (Open77.Server.Tests.Resources.AvLandingLuaTests), which
--     sets `Open77ResourcesRoot` and runs this file;
--   * standalone, from this resource's folder: `lua tests/avlanding_test.lua`.
-- It publishes `TestResult = { passed, failed, failures }`.
-- =============================================================================

local here = debug.getinfo(1, 'S').source:gsub('^@', '')
local ROOT = Open77ResourcesRoot ~= nil and (Open77ResourcesRoot .. '/system/open77_avlanding')
    or (here:match('^(.*)/tests/[^/]+$') or '.')
local DOOR_ROOT = Open77ResourcesRoot ~= nil and (Open77ResourcesRoot .. '/system/open77_avdoor')
    or (ROOT .. '/../open77_avdoor')
local W = dofile(DOOR_ROOT .. '/tests/world.lua')

local CLIENT = { 'shared/config.lua', 'client/main.lua' }
local SERVER = { 'shared/config.lua', 'server/main.lua' }

local passed, failures = 0, {}
local current = '?'
local function check(cond, msg)
    if cond then passed = passed + 1 else failures[#failures + 1] = current .. ': ' .. (msg or 'assertion failed') end
end
local function run(name, fn)
    current = name
    local ok, err = pcall(fn)
    if not ok then failures[#failures + 1] = name .. ': runtime error: ' .. tostring(err) end
    if #W.threadErrors > 0 then
        failures[#failures + 1] = name .. ': thread error: ' .. table.concat(W.threadErrors, ' | ')
        W.threadErrors = {}
    end
    local problems = W.problems()
    if #problems > 0 then failures[#failures + 1] = name .. ': error lines: ' .. table.concat(problems, ' | ') end
end

local AV = 'Vehicle.av_rayfield_excalibur'
local TRAUMA = 'Vehicle.q001_trauma_av'
local CAR = 'Vehicle.v_standard2_archer_hella_player'
local HULL = 4294967297
local EFFECT = 'open77\\fx\\avlanding\\10c786843d78\\open77_warning.effect'
local RING = 'open77\\fx\\avlanding\\10c786843d78\\open77_warning_ring.effect'
local FALLBACK = 'base\\fx\\vehicles\\av\\_landing_area\\v_av_landing_area_hologram.effect'

local client = nil
local server = nil

local function world(setup, players)
    W.reset()
    if setup ~= nil then setup() end
    server = W.server('open77_avlanding', ROOT, SERVER)
    for _, id in ipairs(players or { 1 }) do
        local vm = W.client(id, 'open77_avlanding', ROOT, CLIENT)
        client = client or vm
        if id == (players or { 1 })[1] then client = vm end
    end
    W.advance(600)
end

--- The words up on a player's screen: `{ id = { effect, position, orientation } }`.
local function words(playerId)
    local out = {}
    for id, entry in pairs(W.players[playerId].vfx) do
        if entry.effect == EFFECT then out[#out + 1] = entry end
    end
    return out
end

--- The game's own landing holograms up on a player's screen (1.4.2: a game
--- without the sign's archive).
local function fallbacks(playerId)
    local out = {}
    for _, entry in pairs(W.players[playerId].vfx) do
        if entry.effect == FALLBACK then out[#out + 1] = entry end
    end
    return out
end

--- The rings up on a player's screen (1.4.0: turned under each word).
local function rings(playerId)
    local out = {}
    for id, entry in pairs(W.players[playerId].vfx) do
        if entry.effect == RING then out[#out + 1] = entry end
    end
    return out
end

--- How many times a player's game was asked to play an effect.
local function playsOf(playerId, effect)
    local plays = 0
    for _, entry in ipairs(W.players[playerId].vfxLog) do
        if entry.op == 'play' and (effect == nil or entry.effect == effect) then plays = plays + 1 end
    end
    return plays
end

--- Moves a hull's origin over `ms` milliseconds, in steps of 50 ms.
local function fly(id, to, ms)
    local hull = W.vehicles[id]
    local from = { x = hull.x, y = hull.y, z = hull.z }
    local steps = math.max(1, math.floor(ms / 50))
    for i = 1, steps do
        local f = i / steps
        hull.x = from.x + ((to.x or from.x) - from.x) * f
        hull.y = from.y + ((to.y or from.y) - from.y) * f
        hull.z = from.z + ((to.z or from.z) - from.z) * f
        for _, playerId in pairs(hull.seats) do
            local p = W.players[playerId]
            p.x, p.y, p.z = hull.x, hull.y, hull.z + 1.0
        end
        W.advance(50)
    end
end

--- The direction a sign's text points "up", from its orientation (its -y).
local function textUp(orientation)
    local yaw = 2.0 * math.atan(orientation.z, orientation.w)
    -- +y goes to (-sin, cos); the text's top is -y.
    return math.sin(yaw), -math.cos(yaw)
end

run('a pilot comes down: the sign pops on under the hull in the band, follows it, and stays while aboard', function()
    world(function()
        -- The mesh box reaches 1.5 m under the origin: landed, the origin is 1.5 m up.
        W.vehicle(HULL, AV, 0, 0, 21.5, { heading = 0.0 })
        W.player(1, 0, 0, 22.5)
        W.seat(1, HULL, 'seat_front_left')
    end, { 1 })
    check(#words(1) == 0, 'nothing at 20 m of clearance')
    fly(HULL, { z = 9.0 }, 3000)
    check(#words(1) == 0, 'nothing at 7.5 m')
    fly(HULL, { z = 6.5 }, 1000)
    local up = words(1)
    check(#up == 1, 'on at 5 m coming down: ' .. #up)
    check(up[1] ~= nil and math.abs(up[1].position.x) < 0.01 and math.abs(up[1].position.y) < 0.01
        and math.abs(up[1].position.z - 0.15) < 0.01, 'on the ground under the mesh centre, 15 cm up')
    local ux, uy = textUp(up[1] and up[1].orientation or { z = 0, w = 1 })
    check(math.abs(ux - 0.0) < 1e-6 and math.abs(uy - 1.0) < 1e-6,
        ('its text reads up the way the hull faces (north): %.3f, %.3f'):format(ux, uy))
    check(W.logged('landing sign under 4294967297 (Vehicle.av_rayfield_excalibur) on: coming down at',
        'client:open77_avlanding:1') ~= nil, 'the log says why')
    -- It follows the hull sideways and as it settles, one sign the whole way.
    fly(HULL, { x = 3.0, z = 1.5 }, 2000)
    up = words(1)
    check(#up == 1 and math.abs(up[1].position.x - 3.0) < 0.06 and up[1].updates > 10,
        ('it follows the hull: %.2f after %d moves'):format(up[1] and up[1].position.x or -1, up[1] and up[1].updates or 0))
    check(playsOf(1, EFFECT) == 1 and playsOf(1, RING) == 1, 'the word and its ring played once each, moved after')
    W.advance(30000)
    check(#words(1) == 1, 'on the ground with the pilot aboard, it stays')
end)

run('XyberRP Staging, 2026-10-28, 20:10:06: a hull not yet drawn here is never read through entity 0 -- no sign under the player', function()
    -- A hull that has just appeared 23 m away: this game has no engine entity
    -- for it yet (its snapshot's `entity` is 0), and the platform answers an
    -- entity of 0 with the local player's own geometry.
    world(function()
        local hull = W.vehicle(HULL, AV, 0, 23.0, 1.5)
        hull.entityZeroFor = { [1] = true }
        W.player(1, 0, 0, 0)
    end, { 1 })
    W.advance(1500)
    check(W.selfGeometryAsks == 0, 'entity 0 is never asked about')
    local under = 0
    for _, entry in ipairs(words(1)) do
        if math.abs(entry.position.x) < 1.0 and math.abs(entry.position.y) < 1.0 then under = under + 1 end
    end
    check(under == 0, 'no sign under the player\'s feet')
    check(W.logged('landing sign under 4294967297', 'client:open77_avlanding:1') == nil, 'and no sign at all yet')
    -- Drawn here at last: its sign is under it.
    W.vehicles[HULL].entityZeroFor = nil
    W.advance(1500)
    local up = words(1)
    check(#up == 1 and math.abs(up[1].position.x) < 0.1 and math.abs(up[1].position.y - 23.0) < 0.1,
        ('the sign under the hull once it is drawn here: %s'):format(up[1] ~= nil
            and ('%.1f, %.1f'):format(up[1].position.x, up[1].position.y) or 'none'))
end)

run('landed and left: it goes LINGER_MS after the hull falls idle; level flight never shows it', function()
    world(function()
        W.vehicle(HULL, AV, 0, 0, 7.0)
        W.vehicle(HULL + 1, AV, 40, 0, 5.5)
        W.player(1, 0, 0, 8.0)
        W.seat(1, HULL, 'seat_front_left')
    end, { 1 })
    fly(HULL, { z = 1.5 }, 2000)
    check(#words(1) == 1, 'landed: on')
    W.leave(1, { eject = false })
    W.players[1].x, W.players[1].y, W.players[1].z = -5.0, 0.0, 0.0
    W.advance(7000)
    check(#words(1) == 1, 'still on inside LINGER_MS')
    W.advance(2500)
    check(#words(1) == 0, 'off once the parked hull has been idle LINGER_MS')
    check(W.logged('off: parked, idle', 'client:open77_avlanding:1') ~= nil, 'and why')
    -- The second hull hovers level at 4 m of clearance, empty: never signed.
    for _, entry in ipairs(W.players[1].vfxLog) do
        if entry.op == 'play' then check(entry.at < W.now, 'only one hull ever signed') end
    end
    local status = client.env.Open77AvLanding.Status()
    local hovering = nil
    for _, h in ipairs(status.hulls) do if h.id == tostring(HULL + 1) then hovering = h end end
    check(hovering ~= nil and hovering.up == false and math.abs((hovering.clearance or 0) - 4.0) < 0.01,
        'the level hull is looked at, 4 m up, and not signed')
end)

run('climbing away takes it off after RETIRE_LOOKS looks; a car is never an aircraft', function()
    world(function()
        W.vehicle(HULL, TRAUMA, 0, 0, 1.5)
        W.vehicle(HULL + 1, CAR, 10, 0, 1.5, { engineOn = true })
        W.player(1, 0, 0, 2.5)
        W.seat(1, HULL, 'seat_front_left')
    end, { 1 })
    W.advance(500)
    check(#words(1) == 1, 'the Trauma AV, in use on the ground: on')
    fly(HULL, { z = 12.0 }, 1500)
    check(#words(1) == 0, 'climbed out of the band: off')
    check(W.logged('off: ', 'client:open77_avlanding:1') ~= nil, 'with a line')
    local status = client.env.Open77AvLanding.Status()
    for _, h in ipairs(status.hulls) do check(h.id ~= tostring(HULL + 1), 'the car is not looked at') end
end)

run('the hull\'s heading turns the sign; a game without the archive says so once', function()
    world(function()
        W.vehicle(HULL, AV, 0, 0, 1.5, { heading = -90.0 })   -- facing east (+x)
        W.player(1, 0, 0, 2.5)
        W.seat(1, HULL, 'seat_front_left')
    end, { 1 })
    W.advance(500)
    local up = words(1)
    local ux, uy = textUp(up[1] and up[1].orientation or { z = 0, w = 1 })
    check(math.abs(ux - 1.0) < 1e-6 and math.abs(uy) < 1e-6, ('facing east, the text reads east: %.3f, %.3f'):format(ux, uy))
    -- Without the archive the platform refuses the effect: one warning, no
    -- retry storm in the log -- and (1.4.2) the game's own landing hologram
    -- marks the landing instead, where the sign would lie, without a ring.
    world(function()
        W.vfxRefuse = { [EFFECT] = 'not_found', [RING] = 'not_found' }
        W.vehicle(HULL, AV, 0, 0, 1.5, { heading = -90.0 })
        W.player(1, 0, 0, 2.5)
        W.seat(1, HULL, 'seat_front_left')
    end, { 1 })
    W.advance(3000)
    check(#words(1) == 0 and #rings(1) == 0, 'no sign of ours')
    local held = fallbacks(1)
    check(#held == 1, 'the game\'s own landing hologram instead: ' .. #held)
    check(held[1] ~= nil and math.abs(held[1].position.x) < 1e-6 and math.abs(held[1].position.y) < 1e-6,
        'where the sign would lie (under the hull)')
    local fx, fy = textUp(held[1] and held[1].orientation or { z = 0, w = 1 })
    check(math.abs(fx - 1.0) < 1e-6 and math.abs(fy) < 1e-6, 'turned as the sign would be')
    check(W.count('is not in this game -- its archive is not in the game it started with', 'client:open77_avlanding:1') == 1,
        'one line naming the archive and the launcher')
    check(W.logged('until then the game\'s own AV landing hologram', 'client:open77_avlanding:1') ~= nil,
        'and what marks a landing until then')
    check(W.logged('the game\'s own landing hologram (no sign archive in this game)', 'client:open77_avlanding:1') ~= nil,
        'the on line says which effect')
    check(client.env.Open77AvLanding.Status().fallback == true, 'the status says so')
    W.advance(5000)
    check(#fallbacks(1) == 1 and W.count('is not in this game', 'client:open77_avlanding:1') == 1,
        'it stays, and nothing is asked of the missing effect again')
    -- The fallback refused too: nothing, said once.
    world(function()
        W.vfxRefuse = { [EFFECT] = 'not_found', [FALLBACK] = 'not_found' }
        W.vehicle(HULL, AV, 0, 0, 1.5)
        W.player(1, 0, 0, 2.5)
        W.seat(1, HULL, 'seat_front_left')
    end, { 1 })
    W.advance(3000)
    check(#words(1) == 0 and #fallbacks(1) == 0, 'nothing drawn')
    check(W.count('was refused too', 'client:open77_avlanding:1') == 1, 'one line: no landing is marked')
end)

run('/avlanding.test: the word on the ground in front of the player, reading away from them, for TEST_SECONDS', function()
    world(function()
        W.groundAt = function(x) return x > 15.0 and 2.0 or 0.0 end   -- a step up where the sign goes
        W.player(1, 10.0, 20.0, 0.0, { yaw = -90.0 })                -- facing east (+x)
    end, { 1 })
    -- Typed in chat: the chat hands it to the SERVER, which asks the caller's game.
    local typed = server.commands['avlanding.test']
    check(typed ~= nil and typed.restricted == false, 'a server command anybody may run')
    check(W.logged('ready: /avlanding.test shows the landing sign', 'server:open77_avlanding') ~= nil, 'the server says it is ready')
    typed.fn(1, {}, 'avlanding.test')
    W.advance(100)
    check(#W.sent('open77_avlanding:test') == 1, 'the caller\'s game is asked')
    local result = W.sent('open77:command:result')
    check(#result == 1, 'and the caller is answered: ' .. #result)
    check(W.logged('avlanding.test (asked by the server): the sign is on the ground 8 m in front of you for 20 s',
        'client:open77_avlanding:1') ~= nil, 'the client log says so')
    check(#words(1) == 1, 'one sign')
    typed.fn(1, {}, 'avlanding.test')
    W.advance(100)
    check(#W.sent('open77_avlanding:test') == 1 and W.logged('asked again within 3000 ms', 'server:open77_avlanding') ~= nil,
        'not again within TEST_COOLDOWN_MS')
    typed.fn(0, {}, 'avlanding.test')
    check(W.logged('needs a player', 'server:open77_avlanding') ~= nil, 'the server console has no game to lay it in')
    W.advance(20000)
    check(#words(1) == 0, 'gone after TEST_SECONDS')
    -- The same command in the game's own console.
    local command = client.commands['avlanding.test']
    check(command ~= nil and command.restricted == false, 'also a client command')
    command.fn(0, {}, 'avlanding.test')
    W.advance(100)
    local up = words(1)
    check(#up == 1, 'one sign: ' .. #up)
    check(up[1] ~= nil and math.abs(up[1].position.x - 18.0) < 1e-6 and math.abs(up[1].position.y - 20.0) < 1e-6
        and math.abs(up[1].position.z - 2.15) < 1e-6,
        ('8 m in front, on the ground there, 15 cm up: %.2f, %.2f, %.2f'):format(up[1] and up[1].position.x or -1,
            up[1] and up[1].position.y or -1, up[1] and up[1].position.z or -1))
    local ux, uy = textUp(up[1] and up[1].orientation or { z = 0, w = 1 })
    check(math.abs(ux - 1.0) < 1e-6 and math.abs(uy) < 1e-6, ('its top points away from the player: %.3f, %.3f'):format(ux, uy))
    check(W.logged('avlanding.test (this game\'s console): the sign is on the ground 8 m in front of you for 20 s',
        'client:open77_avlanding:1') ~= nil, 'the log says so')
    check(client.env.Open77AvLanding.Status().test ~= nil, 'the status shows it')
    -- Again: one sign, the new one.
    W.players[1].yaw = 0.0
    command.fn(0, {}, 'avlanding.test')
    W.advance(100)
    up = words(1)
    check(#up == 1 and math.abs(up[1].position.x - 10.0) < 1e-6 and math.abs(up[1].position.y - 28.0) < 1e-6,
        'a second test replaces the first (north of the player now)')
    W.advance(20000)
    check(#words(1) == 0, 'gone after TEST_SECONDS')
    check(W.logged('off: the test is over', 'client:open77_avlanding:1') ~= nil, 'with a line')
    -- A game without the archive (1.4.2): the game's own landing hologram, and
    -- the line says the archive is missing.
    world(function()
        W.vfxRefuse = { [EFFECT] = 'not_found' }
        W.player(1, 0, 0, 0)
    end, { 1 })
    client.commands['avlanding.test'].fn(0, {}, 'avlanding.test')
    check(#fallbacks(1) == 1 and #words(1) == 0, 'the game\'s own landing hologram in front of the player')
    check(W.logged('is not in this game -- its archive is not in the game it started with', 'client:open77_avlanding:1') ~= nil,
        'the line says the archive is missing')
    -- Neither: the test says why.
    world(function()
        W.vfxRefuse = { [EFFECT] = 'not_found', [FALLBACK] = 'not_found' }
        W.player(1, 0, 0, 0)
    end, { 1 })
    client.commands['avlanding.test'].fn(0, {}, 'avlanding.test')
    check(W.logged('avlanding.test (this game\'s console): no sign: the effect was refused', 'client:open77_avlanding:1') ~= nil
        and W.logged('was refused too', 'client:open77_avlanding:1') ~= nil,
        'no sign, and the lines say why')
end)

run('AHEAD_METRES lays the word ahead of the nose, along the hull\'s own axis', function()
    world(function()
        W.vehicle(HULL, AV, 0, 0, 1.5, { heading = -90.0 })   -- facing east (+x)
        W.player(1, 0, 0, 2.5)
        W.seat(1, HULL, 'seat_front_left')
    end, { 1 })
    client.env.Open77AvLandingConfig.AHEAD_METRES = 7.0
    W.advance(500)
    local up = words(1)
    check(#up == 1 and math.abs(up[1].position.x - 7.0) < 1e-6 and math.abs(up[1].position.y) < 1e-6,
        ('7 m ahead of the hull, east: %.2f, %.2f'):format(up[1] and up[1].position.x or -1, up[1] and up[1].position.y or -1))
    local ux, uy = textUp(up[1] and up[1].orientation or { z = 0, w = 1 })
    check(math.abs(ux - 1.0) < 1e-6 and math.abs(uy) < 1e-6, 'still reading the way the hull faces')
    client.env.Open77AvLandingConfig.AHEAD_METRES = 0.0
end)

run('the nearest MAX_HULLS are signed; a removed hull and a stop take theirs away', function()
    world(function()
        for i = 0, 7 do
            W.vehicle(HULL + i, AV, i * 12.0, 0, 1.5, { engineOn = true })
        end
        W.vehicle(HULL + 20, AV, 300.0, 0, 1.5, { engineOn = true })
        W.player(1, 0, 0, 0)
    end, { 1 })
    W.advance(1000)
    check(#words(1) == 6, 'six signs, the nearest six: ' .. #words(1))
    local far = false
    for _, entry in pairs(W.players[1].vfx) do if entry.position.x > 70.0 then far = true end end
    check(not far, 'none for the hulls past the sixth or out of range')
    W.clientEvent('open77:vehicleRemoved', HULL)
    W.vehicles[HULL] = nil
    W.advance(800)
    check(W.logged('off: the hull was removed', 'client:open77_avlanding:1') ~= nil, 'a removed hull: off')
    for _, vm in pairs(W.vms) do if vm.side == 'client' then W.stop(vm) end end
    check(#words(1) == 0, 'a stop takes every sign away')
end)

run('1.3.2: a hull removed while its ground fit breathes (ten frames a second, uneven ground) is never signed after', function()
    local leaks = 0
    for _, delay in ipairs({ 100, 200, 300, 400, 500, 600, 700, 800, 900 }) do
        world(function()
            W.groundAt = function(x, y) return math.sin(x * 1.7) * 0.25 + math.cos(y * 2.3) * 0.25 end
            W.vehicle(HULL, AV, 0, 0, 5.5, { heading = 0.0, engineOn = true })
            W.player(1, 0, 0, 6.5, { frameMs = 100 })
            W.seat(1, HULL, 'seat_front_left')
        end, { 1 })
        fly(HULL, { z = 4.0 }, delay)
        W.clientEvent('open77:vehicleRemoved', HULL)
        W.vehicles[HULL] = nil
        W.players[1].seat = nil
        W.advance(3000)
        if #words(1) > 0 then leaks = leaks + 1 end
    end
    check(leaks == 0, ('no sign left drawn for a removed hull, at any moment of its fit: %d left'):format(leaks))
end)

run('Staging, 2026-10-27: a parked Excalibur, walked up to and boarded in a back seat -- signed while aboard', function()
    world(function()
        W.vehicle(HULL, AV, 0, 0, 1.5, { heading = 0.0 })      -- landed long ago: nobody aboard, engine off
        W.vehicle(HULL + 5, CAR, 20, 0, 0.5)
        W.player(1, 30.0, 0.0, 0.0)
    end, { 1 })
    W.advance(12000)
    check(#words(1) == 0, 'idle for longer than LINGER_MS: no sign')
    check(W.logged('watching 4294967297 (Vehicle.av_rayfield_excalibur) for the landing sign: 30 m away, 0 aboard',
        'client:open77_avlanding:1') ~= nil, 'the log names the hull it watches')
    check(W.logged('no landing sign under 4294967297 (Vehicle.av_rayfield_excalibur): 0.0 m over the ground, nobody '
        .. 'aboard, engine off, idle', 'client:open77_avlanding:1') ~= nil, 'and why it has no sign')
    check(W.logged('Vehicle.v_standard2_archer_hella_player is not an aircraft for the landing sign',
        'client:open77_avlanding:1') ~= nil, 'a car is named once as not an aircraft')
    -- The listing counts who is aboard (a number): the client reads it as such.
    local listed = client.env.Open77.vehicles.nearby(120)
    check(type(listed[1].occupants) == 'number', 'the listing\'s occupants is a count, as the host sends it')
    -- Walked up and boarded -- the platform put the body in the back left seat.
    W.players[1].x, W.players[1].y = 3.0, 0.0
    W.seat(1, HULL, 'seat_back_left')
    W.advance(1000)
    local up = words(1)
    check(#up == 1, 'aboard: the sign is on: ' .. #up)
    check(W.logged('on: on the ground (0.0 m), in use: this player aboard', 'client:open77_avlanding:1') ~= nil,
        'and the line says who uses it')
    local status = client.env.Open77AvLanding.Status()
    check(status.hulls[1] ~= nil and status.hulls[1].busy == true and status.hulls[1].mine == true, 'in use, by this player')
    -- Out again and walked off: it goes LINGER_MS after the hull fell idle.
    W.leave(1, { eject = false })
    W.advance(300)
    W.players[1].x, W.players[1].y = 15.0, 0.0
    W.advance(9500)
    check(#words(1) == 0, 'left and idle: off again')
    -- Another player's pilot in it, this player watching from outside: signed too.
    world(function()
        W.vehicle(HULL, AV, 0, 0, 1.5)
        W.player(1, 25.0, 0.0, 0.0)
        W.player(2, 0.0, 0.0, 2.5)
    end, { 1, 2 })
    W.advance(12000)
    check(#words(1) == 0, 'idle: no sign for the watcher')
    W.seat(2, HULL, 'seat_front_left')
    W.advance(1000)
    check(#words(1) == 1 and W.logged('in use: 1 aboard', 'client:open77_avlanding:1') ~= nil,
        'somebody else aboard: the watcher sees the sign')
end)

run('Staging, 2026-10-27, 17:20: the mesh box comes in the hull\'s own frame -- read as such, the sign under the hull', function()
    -- At (-40, 1996), ground only round there, the hull's origin 1 m up, its
    -- mesh 0.3 m toward the nose and 0.8 m over the origin: the box the client
    -- answers is (-2.5, -4.7, -0.7)..(2.5, 5.3, 2.3) -- "its lowest point at -0.7".
    world(function()
        W.groundAt = function(x, y)
            if math.abs(x + 40.0) < 30.0 and math.abs(y - 1996.0) < 30.0 then return 100.0 end
            return nil
        end
        W.vehicle(HULL, AV, -40.0, 1996.0, 101.0, { heading = 90.0 })   -- facing -x
        W.vehicles[HULL].boxOffset = { x = 0.0, y = 0.3, z = 0.8 }
        W.player(1, -45.0, 1996.0, 100.0)
    end, { 1 })
    W.seat(1, HULL, 'seat_front_left')
    W.advance(1500)
    local up = words(1)
    check(#up == 1, 'aboard on the ground: signed: ' .. #up)
    check(up[1] ~= nil and math.abs(up[1].position.x - (-40.3)) < 1e-6 and math.abs(up[1].position.y - 1996.0) < 1e-6
        and math.abs(up[1].position.z - 100.15) < 1e-6,
        ('under the mesh\'s centre turned out into the world: %.3f, %.3f, %.3f'):format(up[1] and up[1].position.x or -1,
            up[1] and up[1].position.y or -1, up[1] and up[1].position.z or -1))
    check(W.logged('the mesh box of 4294967297 (Vehicle.av_rayfield_excalibur): in the hull\'s own frame, turned out into '
        .. 'the world; its centre -40.3, 1996.0, its lowest point 100.30', 'client:open77_avlanding:1') ~= nil,
        'the log says how the box was read')
    local status = client.env.Open77AvLanding.Status()
    check(status.hulls[1] ~= nil and math.abs((status.hulls[1].clearance or -1) - 0.3) < 1e-6,
        'the clearance from its real lowest point: ' .. tostring(status.hulls[1] and status.hulls[1].clearance))
end)

-- ── the ground's plane ───────────────────────────────────────────────────────

local LIFT = 0.15

--- The sign's up, its normal: q (0, 0, 1) q*.
local function normalOf(q)
    return 2.0 * (q.x * q.z + q.w * q.y), 2.0 * (q.y * q.z - q.w * q.x), 1.0 - 2.0 * (q.x * q.x + q.y * q.y)
end

--- How far from level the sign lies, in degrees.
local function tiltOf(entry)
    local _, _, nz = normalOf(entry.orientation)
    return math.deg(math.acos(math.max(-1.0, math.min(1.0, nz))))
end

--- The height over (x, y) of the plane the sign lies on: through its
--- position less LIFT, square to its normal.
local function planeUnder(entry, x, y)
    local nx, ny, nz = normalOf(entry.orientation)
    local p = entry.position
    return (p.z - LIFT) - (nx * (x - p.x) + ny * (y - p.y)) / nz
end

--- The thirteen points the client samples round (x, y), and a few more on
--- the ring's edge and the word's ends between them.
local function footprint(x, y)
    local out = { { x, y } }
    for k = 0, 15 do
        local a = k * math.pi / 8.0
        out[#out + 1] = { x + 3.8 * math.cos(a), y + 3.8 * math.sin(a) }
    end
    for k = 0, 7 do
        local a = k * math.pi / 4.0
        out[#out + 1] = { x + 3.9 * math.cos(a), y + 3.9 * math.sin(a) }
    end
    for k = 0, 3 do
        local a = math.pi / 4.0 + k * math.pi / 2.0
        out[#out + 1] = { x + 2.0 * math.cos(a), y + 2.0 * math.sin(a) }
    end
    return out
end

--- A pilot brings the Excalibur down on (x, y) over `ground`; its sign.
local function landOn(x, y, ground, setup)
    local base = ground(x, y) or 0.0
    world(function()
        W.groundAt = ground
        if setup ~= nil then setup() end
        W.vehicle(HULL, AV, x, y, base + 7.5, { heading = 0.0 })
        W.player(1, x, y, base + 8.5)
        W.seat(1, HULL, 'seat_front_left')
    end, { 1 })
    fly(HULL, { z = base + 1.5 }, 2000)
    W.advance(500)
    return words(1)[1]
end

run('on a slope the sign tilts with the ground and lies on it, reading the way the hull faces', function()
    local rise = function(x) return 0.1 * x end
    local entry = landOn(0.0, 0.0, rise)
    check(entry ~= nil, 'on')
    if entry == nil then return end
    check(math.abs(tiltOf(entry) - math.deg(math.atan(0.1))) < 0.05, ('tilted 5.7 deg: %.2f'):format(tiltOf(entry)))
    local nx, ny = normalOf(entry.orientation)
    check(nx < -0.09 and math.abs(ny) < 1e-6, ('leaning away from the rise (west): %.3f, %.3f'):format(nx, ny))
    local worst = 0.0
    for _, p in ipairs(footprint(0.0, 0.0)) do
        local over = planeUnder(entry, p[1], p[2]) - rise(p[1])
        check(over > -1e-6, ('never under the ground: %.4f at %.1f, %.1f'):format(over, p[1], p[2]))
        worst = math.max(worst, over)
    end
    check(worst < 0.01, ('and on it, not over it: %.4f'):format(worst))
    local ux, uy = textUp(entry.orientation)
    check(math.abs(ux) < 1e-6 and math.abs(uy - 1.0) < 1e-6, ('its text still reads north: %.3f, %.3f'):format(ux, uy))
    check(W.logged('ground plane 5.7 deg slope, falling toward heading 90 deg, 13 of 13 rays on the ground, 13 kept',
        'client:open77_avlanding:1') ~= nil, 'the line that puts it on says how it lies')
    check(W.logged('the ground under a sign: static meshes only, no Open77.world.raycast', 'client:open77_avlanding:1') ~= nil,
        'and which ground this client\'s rays meet')
end)

run('a kerb under the ring: the sign rises over it instead of sinking into it', function()
    local kerb = function(x) return x > 1.0 and 0.2 or 0.0 end
    local entry = landOn(0.0, 0.0, kerb)
    check(entry ~= nil, 'on')
    if entry == nil then return end
    for _, p in ipairs(footprint(0.0, 0.0)) do
        if math.abs(p[1] - 1.0) > 0.3 then   -- not the kerb's own edge, between two rays
            check(planeUnder(entry, p[1], p[2]) >= kerb(p[1]) - 1e-6,
                ('over the ground at %.1f, %.1f: %.3f over %.2f'):format(p[1], p[2], planeUnder(entry, p[1], p[2]), kerb(p[1])))
        end
    end
    check(tiltOf(entry) < 3.0, ('hardly tilted: %.2f deg'):format(tiltOf(entry)))
    check(entry.position.z - LIFT > -1e-6 and entry.position.z - LIFT < 0.2, ('raised a little: %.3f'):format(entry.position.z))
end)

run('a roof\'s edge and a wall round the pad are not its ground: the sign lies flat on the pad', function()
    -- A rooftop pad, the street 15 m under its west edge.
    local entry = landOn(0.0, 0.0, function(x) return x < -3.0 and -15.0 or 0.0 end)
    check(entry ~= nil and math.abs(entry.position.z - LIFT) < 1e-6 and tiltOf(entry) < 1e-3,
        ('flat on the roof: %.3f, %.4f deg'):format(entry and entry.position.z or -1, entry and tiltOf(entry) or -1))
    check(W.logged('13 of 13 rays on the ground, 12 kept', 'client:open77_avlanding:1') ~= nil, 'the street is not kept')
    -- A 2 m wall along the west side: three rays on top of it.
    entry = landOn(0.0, 0.0, function(x) return x < -2.5 and 2.0 or 0.0 end)
    check(entry ~= nil and math.abs(entry.position.z - LIFT) < 1e-6 and tiltOf(entry) < 1e-3,
        ('flat on the pad: %.3f, %.4f deg'):format(entry and entry.position.z or -1, entry and tiltOf(entry) or -1))
    check(W.logged('13 of 13 rays on the ground, 10 kept', 'client:open77_avlanding:1') ~= nil, 'the wall\'s top is not kept')
    -- A bollard under the centre: the pad round it is the ground.
    entry = landOn(0.0, 0.0, function(x, y) return (x * x + y * y < 0.01) and 0.9 or 0.0 end)
    check(entry ~= nil and math.abs(entry.position.z - LIFT) < 1e-6 and tiltOf(entry) < 1e-3,
        ('flat on the pad round the bollard: %.3f'):format(entry and entry.position.z or -1))
end)

run('ground steeper than MAX_TILT_DEGREES: held to 20 deg and raised over every sample', function()
    local steep = function(x) return 0.7 * x end   -- 35 degrees, rising east
    world(function()
        W.groundAt = steep
        W.player(1, -8.0, 0.0, steep(-8.0), { yaw = -90.0 })   -- below the sign, facing east, up the hill
    end, { 1 })
    client.commands['avlanding.test'].fn(0, {}, 'avlanding.test')
    W.advance(100)
    local entry = words(1)[1]
    check(entry ~= nil and math.abs(entry.position.x) < 1e-6, 'on, 8 m up the hill')
    if entry == nil then return end
    check(math.abs(tiltOf(entry) - 20.0) < 0.01, ('held to 20 deg: %.3f'):format(tiltOf(entry)))
    for k = 0, 7 do
        local a = k * math.pi / 4.0
        local x, y = 3.9 * math.cos(a), 3.9 * math.sin(a)
        check(planeUnder(entry, x, y) >= steep(x) - 1e-6, ('over the hill at %.1f, %.1f'):format(x, y))
    end
    check(W.logged('20.0 deg slope (held to the steepest allowed)', 'client:open77_avlanding:1') ~= nil, 'and the line says so')
end)

run('/avlanding.test on a hillside: tilted with it, on it', function()
    local hill = function(_, y) return 0.15 * y end   -- rising north
    world(function()
        W.groundAt = hill
        W.player(1, 0.0, 0.0, 0.0, { yaw = 0.0 })      -- facing north, up the hill
    end, { 1 })
    client.commands['avlanding.test'].fn(0, {}, 'avlanding.test')
    W.advance(100)
    local entry = words(1)[1]
    check(entry ~= nil and math.abs(entry.position.y - 8.0) < 1e-6, '8 m up the hill')
    if entry == nil then return end
    check(math.abs(tiltOf(entry) - math.deg(math.atan(0.15))) < 0.05, ('tilted 8.5 deg: %.2f'):format(tiltOf(entry)))
    for _, p in ipairs(footprint(0.0, 8.0)) do
        local over = planeUnder(entry, p[1], p[2]) - hill(p[1], p[2])
        check(over > -1e-6 and over < 0.01, ('on the hill at %.1f, %.1f: %.4f'):format(p[1], p[2], over))
    end
    local ux, uy = textUp(entry.orientation)
    check(math.abs(ux) < 1e-6 and math.abs(uy - 1.0) < 1e-6, ('its top points away from the player: %.3f, %.3f'):format(ux, uy))
    local line = W.logged('on: 8 m in front of the player (yaw 0 deg), ground 1.20, at 0.0, 8.0, 1.35, heading 180 deg, '
        .. 'ground plane 8.5 deg slope, falling toward heading 180 deg, 13 of 13 rays on the ground', 'client:open77_avlanding:1')
    check(line ~= nil, 'the line says where and how it lies')
    local shown = client.env.Open77AvLanding.Status().test
    check(shown ~= nil and math.abs((shown.tilt or -1) - math.deg(math.atan(0.15))) < 0.01, 'the status has its tilt')
end)

run('over open terrain: a client whose rays take collision groups signs it; an older one cannot, and says so', function()
    local desert = function(x) return 30.0 + 0.05 * x end
    local function dunes(rays)
        world(function()
            W.rays = rays
            W.groundAt = function() return nil end   -- no static mesh under it: the Badlands
            W.terrainAt = desert
            W.vehicle(HULL, AV, 0, 0, 37.5, { heading = 0.0 })
            W.player(1, 0, 0, 38.5)
            W.seat(1, HULL, 'seat_front_left')
        end, { 1 })
        fly(HULL, { z = 31.5 }, 2000)
        W.advance(500)
    end
    dunes('groups')
    local entry = words(1)[1]
    check(entry ~= nil, 'on over the terrain')
    if entry ~= nil then
        check(math.abs(entry.position.z - (30.0 + LIFT)) < 1e-6, ('on the dunes: %.3f'):format(entry.position.z))
        check(math.abs(tiltOf(entry) - math.deg(math.atan(0.05))) < 0.05, ('tilted with them: %.2f'):format(tiltOf(entry)))
    end
    check(W.logged('the ground under a sign: static meshes and terrain', 'client:open77_avlanding:1') ~= nil, 'the log says which ground')
    check(client.env.Open77AvLanding.Status().terrain == true, 'and the status')
    -- The same dunes on an older client: its rays ignore `groups`.
    dunes('flags')
    check(#words(1) == 0, 'no sign: its static ray meets no ground there')
    check(W.logged('the ground under a sign: static meshes only, its rays take no collision groups (traced): no sign over open terrain',
        'client:open77_avlanding:1') ~= nil, 'and the log says why')
end)

run('an older client\'s rays meet the hulls: its ground is asked static only', function()
    local entry = landOn(0.0, 0.0, function() return 0.0 end, function() W.rays = 'flags' end)
    check(entry ~= nil and math.abs(entry.position.z - LIFT) < 1e-6,
        ('on the ground, not on the hull: %.2f'):format(entry and entry.position.z or -1))
    local status = client.env.Open77AvLanding.Status()
    check(status.terrain == false and status.hulls[1] ~= nil and math.abs((status.hulls[1].clearance or -1) - 0.0) < 1e-6,
        'the clearance is the ground\'s')
end)

run('the ground costs a few rays a second per sign', function()
    world(function()
        W.rays = 'groups'
        W.vehicle(HULL, AV, 0, 0, 1.5, { engineOn = true })
        W.player(1, 0, 0, 0)
    end, { 1 })
    W.advance(1000)
    check(#words(1) == 1, 'on')
    local before = W.rayCount
    W.advance(10000)
    local rays = W.rayCount - before
    -- One ray every GROUND_MS (the clearance), thirteen every REFIT_MS (the plane).
    check(rays <= 100, ('rays in 10 s at rest: %d'):format(rays))
    -- Flying low and level with somebody aboard, the sign follows: the plane
    -- is measured at most every GROUND_MS.
    world(function()
        W.rays = 'groups'
        W.vehicle(HULL, AV, 0, 0, 5.0, { engineOn = true })
        W.player(1, 0, 0, 6.0)
        W.seat(1, HULL, 'seat_front_left')
    end, { 1 })
    fly(HULL, { z = 4.0 }, 1000)
    check(#words(1) == 1, 'on, coming down')
    before = W.rayCount
    fly(HULL, { x = 100.0 }, 10000)
    rays = W.rayCount - before
    check(#words(1) == 1 and math.abs(words(1)[1].position.x - 100.0) < 0.6, 'it followed the hull')
    check(rays <= 560, ('rays in 10 s at 10 m/s: %d'):format(rays))
end)

run('Staging, 2026-10-27, 17:40:21: one plane stays inside the game\'s Lua budget, and one look measures one plane', function()
    world(function() W.player(1, 0, 0, 0) end, { 1 })
    local L = client.env.Open77AvLanding
    local settings = L.Settings()
    -- Rough ground: no plane through any three samples has them all on it
    -- (every triple of the old consensus was tried, against every sample).
    local heights = { 0.31, -0.27, 0.12, -0.33, 0.29, 0.05, -0.18, 0.34, -0.09, 0.22, -0.30, 0.16, -0.21 }
    local i = 0
    local function rough() i = i + 1; return heights[(i - 1) % #heights + 1] end
    local counted = 0
    local fit = nil
    if debug ~= nil and type(debug.sethook) == 'function' then
        debug.sethook(function() counted = counted + 100 end, '', 100)
        fit = L.FitGround(0.0, 0.0, 3.0, settings, rough)
        debug.sethook()
        -- The holograms' probe on the same game measured the slice at about
        -- 60 000 instructions (client log, 17:36:30).
        check(counted < 30000, ('one plane over rough ground: %d instructions (the slice is about 60 000)'):format(counted))
    else
        fit = L.FitGround(0.0, 0.0, 3.0, settings, rough)
    end
    check(fit ~= nil and fit.found == 13 and fit.used >= 3, 'and it is still a plane: ' .. tostring(fit and fit.used))
    check(settings.fitTriples == 96 and settings.fitsPerLook == 1, 'FIT_TRIPLES and FITS_PER_LOOK are read')
    -- Three hulls coming down together, all signed on player 1's screen (the
    -- others' games are not run here): their planes are measured a look apart.
    world(function()
        W.rays = 'groups'
        for k = 0, 2 do
            W.vehicle(HULL + k, AV, k * 30.0, 0, 7.5, { heading = 0.0 })
            W.player(k + 1, k * 30.0, 0, 8.5)
            W.seat(k + 1, HULL + k, 'seat_front_left')
        end
    end, { 1 })
    local perLook = {}
    local before = W.rayCount
    for _ = 1, 40 do
        for k = 0, 2 do W.vehicles[HULL + k].z = math.max(1.5, W.vehicles[HULL + k].z - 0.25) end
        W.advance(50)
        perLook[#perLook + 1] = W.rayCount - before
        before = W.rayCount
    end
    local most = 0
    for _, n in ipairs(perLook) do most = math.max(most, n) end
    -- One plane is thirteen rays; each hull's clearance and ahead rays are one or two more.
    check(most <= 13 + 3 * 2, ('one look casts one plane\'s rays at most: %d'):format(most))
    check(#words(1) == 3, ('and every hull is signed all the same: %d'):format(#words(1)))
end)

-- ── the ring (1.4.0) ─────────────────────────────────────────────────────────

--- The yaw a sign's orientation turns it by about its own up (the twist), degrees 0..360.
local function twistOf(q)
    -- The sign's +x carried into the world, projected on its own plane: atan2 against the
    -- untwisted frame of the same tilt is the twist; for these signs it is 2 atan2(z, w)
    -- of the yaw factor, read off the quaternion with the tilt removed.
    local ax = 1 - 2 * (q.y * q.y + q.z * q.z)
    local ay = 2 * (q.x * q.y + q.z * q.w)
    return math.deg(math.atan(ay, ax)) % 360.0
end

run('1.4.0: the ring under the word -- played with it, where it lies, turning 20 deg/s about its own up, gone with it', function()
    world(function()
        W.vehicle(HULL, AV, 0, 0, 1.5, { heading = 0.0 })
        W.player(1, 0, 0, 2.5)
        W.seat(1, HULL, 'seat_front_left')
    end, { 1 })
    W.advance(500)
    local word, ring = words(1)[1], rings(1)[1]
    check(word ~= nil and ring ~= nil, 'the word and its ring')
    if word == nil or ring == nil then return end
    check(math.abs(ring.position.x - word.position.x) < 1e-6 and math.abs(ring.position.y - word.position.y) < 1e-6
        and math.abs(ring.position.z - word.position.z) < 1e-6, 'the ring lies where the word does')
    local wordTwist = twistOf(word.orientation)
    local a0 = (twistOf(ring.orientation) - wordTwist) % 360.0
    local updates0 = ring.updates
    W.advance(1000)
    ring = rings(1)[1]
    local a1 = (twistOf(ring.orientation) - wordTwist) % 360.0
    local turned = (a1 - a0) % 360.0
    check(math.abs(turned - 20.0) < 1.5, ('turned %.1f deg in a second, counterclockwise'):format(turned))
    check(ring.updates - updates0 >= 25 and ring.updates - updates0 <= 35,
        ('turned every RING_MS: %d updates in a second'):format(ring.updates - updates0))
    check(twistOf(words(1)[1].orientation) == wordTwist, 'the word does not turn')
    check(W.logged('the ring turning 20 deg/s', 'client:open77_avlanding:1') ~= nil, 'the line that puts it on says so')
    -- Taken off with the word.
    W.leave(1, { eject = false })
    W.players[1].x = -6.0
    W.advance(9500)
    check(#words(1) == 0 and #rings(1) == 0, 'gone with the word')
    check(playsOf(1, RING) == 1, 'played once')
end)

run('1.4.0: on a slope the ring turns about the sign\'s own normal, tilted with the word', function()
    local rise = function(x) return 0.1 * x end
    local entry = landOn(0.0, 0.0, rise)
    check(entry ~= nil, 'on')
    if entry == nil then return end
    W.advance(700)
    local ring = rings(1)[1]
    check(ring ~= nil, 'its ring')
    if ring == nil then return end
    local wx, wy, wz = normalOf(entry.orientation)
    local rx, ry, rz = normalOf(ring.orientation)
    check(math.abs(wx - rx) < 1e-6 and math.abs(wy - ry) < 1e-6 and math.abs((wz or 0) - (rz or 0)) < 1e-6,
        ('the same up as the word: %.4f, %.4f against %.4f, %.4f'):format(rx, ry, wx, wy))
end)

run('1.4.0: a ring the game refuses leaves the word alone, said once; /avlanding.test lays both', function()
    world(function()
        W.vfxRefuse = { [RING] = 'not_found' }
        W.vehicle(HULL, AV, 0, 0, 1.5)
        W.player(1, 0, 0, 2.5)
        W.seat(1, HULL, 'seat_front_left')
    end, { 1 })
    W.advance(2000)
    check(#words(1) == 1 and #rings(1) == 0, 'the word, no ring')
    check(W.count('the landing sign\'s ring', 'client:open77_avlanding:1') == 1, 'one line')
    world(function()
        W.player(1, 10.0, 20.0, 0.0, { yaw = -90.0 })
    end, { 1 })
    server.commands['avlanding.test'].fn(1, {}, 'avlanding.test')
    W.advance(500)
    check(#words(1) == 1 and #rings(1) == 1, 'the test lays the word and its ring')
    local ring = rings(1)[1]
    check(ring ~= nil and ring.updates >= 10, 'and the ring turns')
    W.advance(21000)
    check(#words(1) == 0 and #rings(1) == 0, 'both gone after TEST_SECONDS')
end)

run('1.4.0: every job\'s passes are timed, and a minute in the game says what each cost; a failing pass is counted', function()
    world(function()
        W.vehicle(HULL, AV, 0, 0, 1.5)
        W.player(1, 0, 0, 2.5)
        W.seat(1, HULL, 'seat_front_left')
    end, { 1 })
    W.advance(61000)
    local line = W.logged('job costs over the last', 'client:open77_avlanding:1')
    check(line ~= nil and line:find('(open77_avlanding)', 1, true) ~= nil, 'one line, ' .. tostring(line and line:sub(1, 200)))
    for _, job in ipairs({ 'list ', 'look ', 'ring ' }) do
        check(line ~= nil and line:find(job, 1, true) ~= nil, 'with the ' .. job .. 'job')
    end
    check(line ~= nil and line:find('FAILED', 1, true) == nil, 'nothing failed')
    -- Passes that raise (the settings unreadable for two seconds): said once,
    -- counted in the next line, and the jobs go on.
    local L = client.env.Open77AvLanding
    local settings = L.Settings
    L.Settings = function() error('a test failure') end
    W.advance(2000)
    L.Settings = settings
    check(W.count('pass failed: ', 'client:open77_avlanding:1') == 1, 'said once')
    for _, entry in ipairs(W.logs) do
        if entry.text:find('a test failure', 1, true) ~= nil then entry.level = 'expected' end
    end
    W.advance(300000)
    local again = nil
    for _, entry in ipairs(W.logs) do
        if entry.vm == 'client:open77_avlanding:1' and entry.text:find('job costs over the last', 1, true) ~= nil then
            again = entry.text
        end
    end
    check(W.count('job costs over the last', 'client:open77_avlanding:1') == 2, 'then every five minutes')
    check(again ~= nil and again:find('FAILED', 1, true) ~= nil, 'with the failures counted, ' .. tostring(again and again:sub(1, 300)))
    check(#words(1) == 1, 'the sign still up')
end)

run('1.4.1: a native of 20 ms or more is a line at once, with its pass; a look\'s own cost leaves out its breaths', function()
    world(function()
        W.vehicle(HULL, AV, 0, 0, 1.5)
        W.player(1, 0, 0, 2.5, { frameMs = 250 })
        W.seat(1, HULL, 'seat_front_left')
    end, { 1 })
    local L = client.env.Open77AvLanding
    local ok, value = L.Native('test.slow', function(x)
        W.now = W.now + 30
        return x + 1
    end, 41)
    check(ok == true and value == 42, 'pcall\'s answers')
    check(W.logged('slow native: test.slow took 30.0 ms in one call (an event or a one-off', 'client:open77_avlanding:1') ~= nil,
        'said at once')
    W.advance(61000)
    local line = nil
    for _, entry in ipairs(W.logs) do
        if entry.vm == 'client:open77_avlanding:1' and entry.text:find('job costs over the last', 1, true) ~= nil then
            line = entry.text
        end
    end
    check(line ~= nil and line:find('natives, the dearest first: test.slow', 1, true) ~= nil,
        'the dearest natives end the line: ' .. tostring(line and line:sub(1, 300)))
end)

TestResult = { passed = passed, failed = #failures, failures = failures }
if Open77ResourcesRoot == nil then
    for _, failure in ipairs(failures) do print('FAIL ' .. failure) end
    print(('%d passed, %d failed'):format(passed, #failures))
    if #failures > 0 then os.exit(1) end
end
