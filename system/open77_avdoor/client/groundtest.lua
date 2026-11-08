-- =============================================================================
-- open77_avdoor -- client/groundtest.lua
-- =============================================================================
-- THE GROUND TEST (1.5.3; 1.6.0). The exit clip is drawn only on a body its
-- own game says stands on the ground. What a move, the freeze, a move while
-- held -- and THE NATIVE FADE (1.6.0: a body put beside the AV under the exit's
-- cut to black hung "off the ground (falling)" for as long as the screen was
-- black, and moved the moment the image came back; Staging, 2026-10-28) -- do
-- to that word is asked here on foot, away from any aircraft:
-- `/avdoor.groundtest` in chat (a server command, sent to the typing player's
-- game alone) runs fourteen steps on the standing body, each a second or two,
-- reading its state every frame -- on the ground or not, the air state, its
-- height over the ground, its speed up or down, the screen -- and writes each
-- change and each step's end to this client's log ("ground test ..."). The
-- last three put the screen black, move the body 5 cm up under it, and bring
-- the image back. The body is only ever moved where it stands, and every hold
-- and the fade are let go at the end.
-- =============================================================================

local M = AvDoor
local G = {}
M.GroundTest = G

local running = nil

local function state()
    local character = Open77.character
    if type(character) ~= 'table' or type(character.state) ~= 'function' then return nil end
    local read, s = pcall(character.state)
    if read and type(s) == 'table' then return s end
    return nil
end

local function finite(value)
    value = tonumber(value)
    if value == nil or value ~= value or value == math.huge or value == -math.huge then return nil end
    return value
end

local function groundUnder(x, y, z)
    local world = Open77.world
    if type(world) ~= 'table' or type(world.groundZ) ~= 'function' then return nil end
    local read, ground = pcall(world.groundZ, x, y, z + 1.0)
    if not read then return nil end
    return finite(ground)
end

--- One look: `{ grounded, air, fall, x, y, z, vz, speed, yaw, mounted }`, or nil.
local function look()
    local s = state()
    if s == nil or type(s.position) ~= 'table' then return nil end
    local vehicle = type(s.vehicle) == 'table' and s.vehicle or {}
    return {
        grounded = s.grounded, air = s.air, fall = s.fall,
        x = finite(s.position.x), y = finite(s.position.y), z = finite(s.position.z),
        vz = type(s.velocity) == 'table' and finite(s.velocity.z) or nil,
        speed = finite(s.groundSpeed),
        yaw = finite(s.yaw),
        mounted = vehicle.mounted == true or s.inVehicle == true,
        alive = s.alive ~= false,
    }
end

local function word(r)
    if r == nil then return 'not read' end
    if r.grounded == true then return 'on the ground' end
    if r.grounded == false then return ('off the ground (%s)'):format(tostring(r.air or '?')) end
    return 'ground not said'
end

local function teleport(x, y, z, yaw)
    local travel = Open77.travel
    if type(travel) ~= 'table' or type(travel.teleport) ~= 'function' then return false, 'no Open77.travel.teleport' end
    local read, ok, why = pcall(travel.teleport, x, y, z, yaw)
    if not read then return false, tostring(ok) end
    return ok == true, why
end

local function freeze(on)
    local players = Open77.players
    if type(players) ~= 'table' or type(players.freezePosition) ~= 'function' then
        return false, 'no Open77.players.freezePosition'
    end
    local read, ok, why = pcall(players.freezePosition, on)
    if not read then return false, tostring(ok) end
    return ok == true, why
end

local function restrict(on)
    local character = Open77.character
    if type(character) ~= 'table' or type(character.setFrozen) ~= 'function' then
        return false, 'no Open77.character.setFrozen'
    end
    local read, ok, why = pcall(character.setFrozen, on)
    if not read then return false, tostring(ok) end
    return ok == true, why
end

-- The native fade this test put on, while it is on.
local fadeId = nil

local function fadeOut(ms)
    local screen = Open77.screen
    if type(screen) ~= 'table' or type(screen.fadeOut) ~= 'function' then return false, 'no Open77.screen.fadeOut' end
    local read, id, why = pcall(screen.fadeOut, { durationMs = ms })
    if not read or id == nil then return false, tostring(read and why or id) end
    fadeId = id
    return true
end

local function fadeIn(ms)
    if fadeId == nil then return false, 'no fade of this test is on' end
    local screen = Open77.screen
    local id = fadeId
    fadeId = nil
    if type(screen) ~= 'table' or type(screen.fadeIn) ~= 'function' then return false, 'no Open77.screen.fadeIn' end
    local read, ok, why = pcall(screen.fadeIn, id, { durationMs = ms })
    if not read then return false, tostring(ok) end
    return ok == true, why
end

local function screenText()
    if type(M.ScreenText) == 'function' then
        local read, text = pcall(M.ScreenText)
        if read and type(text) == 'string' then return text end
    end
    return 'the screen not read'
end

--- The steps, in order: `{ name, ms, act(start) -> ok, why }`.
local function steps()
    return {
        { name = 'standing, nobody holding it', ms = 1000 },
        { name = 'moved where it stands (a teleport, free)', ms = 2500,
            act = function(t) return teleport(t.x, t.y, t.z, t.yaw) end },
        { name = 'held by the platform\'s freeze', ms = 1500, act = function() return freeze(true) end },
        { name = 'let go', ms = 1500, act = function() return freeze(false) end },
        { name = 'held, then moved where it stands while held', ms = 2500, act = function(t)
            local ok, why = freeze(true)
            if not ok then return ok, why end
            Wait(300)
            return teleport(t.x, t.y, t.z, t.yaw)
        end },
        { name = 'let go after the move while held', ms = 2000, act = function() return freeze(false) end },
        { name = 'held again', ms = 1500, act = function() return freeze(true) end },
        { name = 'let go again', ms = 1000, act = function() return freeze(false) end },
        { name = 'moved 5 cm up (a teleport, free)', ms = 2500,
            act = function(t) return teleport(t.x, t.y, t.z + 0.05, t.yaw) end },
        { name = 'held by the NoMovement restriction', ms = 1000, act = function() return restrict(true) end },
        { name = 'the restriction let go', ms = 800, act = function() return restrict(false) end },
        -- THE NATIVE FADE (1.6.0): black, nobody holding the body; then moved
        -- 5 cm up where it stands, under the black; then the image back at once.
        { name = 'the screen black (a native fade), nobody holding it', ms = 1500,
            act = function() return fadeOut(250) end },
        { name = 'moved 5 cm up where it stands, under the black', ms = 2000,
            act = function(t) return teleport(t.x, t.y, t.z + 0.05, t.yaw) end },
        { name = 'the image back (the fade lifted at once)', ms = 1500, act = function() return fadeIn(0) end },
    }
end

local function releaseAll()
    freeze(false)
    restrict(false)
    if fadeId ~= nil then fadeIn(0) end
end

local function run(asked)
    local start = look()
    if start == nil or start.x == nil or start.z == nil then
        Open77.log.warn('ground test not run: this client cannot read the body')
        return
    end
    if start.mounted then
        Open77.log.warn('ground test not run: the body is in a vehicle -- step out and stand on flat ground first')
        return
    end
    if not start.alive then
        Open77.log.warn('ground test not run: the body is down')
        return
    end
    if type(M.ExitBusy) == 'function' and M.ExitBusy() then
        Open77.log.warn('ground test not run: an AV exit is under way on this screen -- once it is over, type it again')
        return
    end
    local ground = groundUnder(start.x, start.y, start.z)
    local function over(r)
        if r == nil or r.z == nil or ground == nil then return 'height not measured' end
        return ('%.2f m over the ground'):format(r.z - ground)
    end
    local function numbers(r)
        return ('%s, %s m/s up'):format(over(r), r ~= nil and r.vz ~= nil and ('%.2f'):format(r.vz) or '?')
    end
    local list = steps()
    local total = 0
    for _, step in ipairs(list) do total = total + step.ms end
    Open77.log.info(('ground test (%s): the body on foot at %.2f, %.2f, %.2f facing %s, %s, %s now, %s; %d steps, '
        .. 'about %.0f s -- stand still on flat ground, hands off the keys (the screen goes black for about 3.5 s near '
        .. 'the end)'):format(tostring(asked or 'asked'), start.x, start.y, start.z,
        start.yaw ~= nil and ('%.0f'):format(start.yaw) or '?', over(start), word(start), screenText(), #list,
        total / 1000.0))
    local results = {}
    local moved = 0
    for index, step in ipairs(list) do
        if running == nil or running.stop then break end
        local began = M.Now()
        local ok, why = true, nil
        if step.act ~= nil then ok, why = step.act(start) end
        if not ok then
            Open77.log.warn(('ground test %d/%d (%s): refused -- %s'):format(index, #list, step.name, tostring(why)))
        end
        local last, firstOn, lastOff, onMs, lo, hi, vlo, vhi, prevAt, lines = nil, nil, nil, 0, nil, nil, nil, nil, nil, 0
        while M.Now() - began < step.ms do
            Wait(0)
            local now = M.Now()
            local r = look()
            if r ~= nil then
                local t = (now - began) / 1000.0
                if prevAt ~= nil and last ~= nil and last.grounded == true then onMs = onMs + (now - prevAt) end
                prevAt = now
                if r.grounded == true and firstOn == nil then firstOn = t end
                if r.grounded ~= true then lastOff = t end
                if r.z ~= nil and ground ~= nil then
                    local h = r.z - ground
                    lo, hi = math.min(lo or h, h), math.max(hi or h, h)
                end
                if r.vz ~= nil then vlo, vhi = math.min(vlo or r.vz, r.vz), math.max(vhi or r.vz, r.vz) end
                local w = word(r)
                if last == nil or w ~= word(last) then
                    lines = lines + 1
                    if lines <= 8 then
                        Open77.log.info(('ground test %d/%d (%s): %s at %.2f s, %s'):format(index, #list, step.name, w,
                            t, numbers(r)))
                    end
                end
                last = r
                -- The body walked: the test is about a body standing still.
                if (r.speed or 0) > 1.0 then moved = moved + 1 else moved = 0 end
                if moved >= 6 then
                    if running ~= nil then running.stop = 'the body moved' end
                    break
                end
            end
        end
        local endWord = word(last)
        results[#results + 1] = ('%d %s'):format(index, endWord)
        Open77.log.info(('ground test %d/%d (%s): at its end %s, %s -- on the ground %.1f of %.1f s (first at %s, last '
            .. 'off at %s); height over the ground %s; speed up %s; %s'):format(index, #list, step.name, endWord,
            numbers(last), onMs / 1000.0, step.ms / 1000.0, firstOn ~= nil and ('%.2f s'):format(firstOn) or 'never',
            lastOff ~= nil and ('%.2f s'):format(lastOff) or 'never',
            lo ~= nil and ('%.2f to %.2f m'):format(lo, hi) or 'not measured',
            vlo ~= nil and ('%.2f to %.2f m/s'):format(vlo, vhi) or 'not read', screenText()))
    end
    releaseAll()
    local stopped = running ~= nil and running.stop or nil
    Open77.log.info(('ground test over%s: %s'):format(stopped ~= nil and (' early (%s)'):format(stopped) or '',
        table.concat(results, '; ')))
end

--- Runs the test (once at a time).
function G.Run(asked)
    if running ~= nil then
        Open77.log.info('ground test already running')
        return false
    end
    local handle = { since = M.Now() }
    running = handle
    CreateThread(function()
        local ran, failure = pcall(run, asked)
        if not ran then
            releaseAll()
            Open77.log.error('ground test failed: ' .. tostring(failure))
        end
        if running == handle then running = nil end
    end)
    return true
end

function G.Running() return running ~= nil end

function G.Start()
    RegisterNetEvent(M.Event.GROUNDTEST, function(payload)
        local ran, failure = pcall(G.Run, type(payload) == 'table' and payload.asked or nil)
        if not ran then Open77.log.error('the ground test could not start: ' .. tostring(failure)) end
    end)
end

function G.Stop()
    if running ~= nil then running.stop = 'the resource stopped' end
    releaseAll()
end
