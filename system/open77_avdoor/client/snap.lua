-- =============================================================================
-- open77_avdoor -- client/snap.lua
-- =============================================================================
-- The pilot's half of the pad snap (server/snap.lua): this game measures the
-- static ground straight down at the points the server names -- the pad's
-- centre, then each gear foot as the hull will stand -- and sends what it
-- found. The server has no physics world: the deck's height is this game's
-- measure, the landing height the server's own sum. While the server flies
-- the hull onto the pad, a line on the screen says so.
--
-- THE DIP (1.8.3): an AV with somebody aboard is docked under a short fade to
-- black -- every game aboard dips its screen, the pilot's says when it is
-- black, the server sets the hull on the deck in one move, and the image comes
-- back. Each game logs where it draws the hull and its body at the dip and as
-- the image comes back, and whether it simulates the hull.
-- =============================================================================

local M = AvDoor

M.SnapClient = {}
local SnapClient = M.SnapClient

local function finite(value)
    local number = tonumber(value)
    if number == nil or number ~= number or number == math.huge or number == -math.huge then return nil end
    return number
end

local function groundAt(x, y, fromZ)
    local world = Open77.world
    if type(world) ~= 'table' or type(world.groundZ) ~= 'function' then return nil, 'no Open77.world.groundZ' end
    local read, z = pcall(world.groundZ, x, y, fromZ)
    if not read then return nil, tostring(z) end
    return finite(z), z == nil and 'no ground' or nil
end

local function notify(text)
    local hud = Open77.hud
    if type(hud) == 'table' and type(hud.notify) == 'function' then pcall(hud.notify, text, { replace = true }) end
end

--- Where this game draws the hull it sits in and its own body, for the log.
local function aboard()
    local vehicles, character = Open77.vehicles, Open77.character
    local bx, by, bz = nil, nil, nil
    if type(character) == 'table' and type(character.position) == 'function' then
        local read, x, y, z = pcall(character.position)
        if read then bx, by, bz = finite(x), finite(y), finite(z) end
    end
    local body = bx ~= nil and ('%.1f, %.1f, %.1f'):format(bx, by, bz) or '?'
    local seat = nil
    if type(vehicles) == 'table' and type(vehicles.getPlayerSeat) == 'function' then
        local read, value = pcall(vehicles.getPlayerSeat)
        if read and type(value) == 'table' then seat = value end
    end
    if seat == nil or type(vehicles.get) ~= 'function' then return ('the body at %s, in no seat'):format(body) end
    local read, hull = pcall(vehicles.get, seat.vehicleId)
    if not read or type(hull) ~= 'table' then return ('the body at %s; the hull not drawn'):format(body) end
    local at = type(hull.position) == 'table' and hull.position or {}
    local hx, hy, hz = finite(at.x), finite(at.y), finite(at.z)
    local apart = (bx ~= nil and hx ~= nil) and ('%.1f m'):format(math.sqrt((bx - hx) ^ 2 + (by - hy) ^ 2 + (bz - hz) ^ 2))
        or '?'
    return ('the hull drawn at %s (%s by this game, %s), the body at %s, %s from it'):format(
        hx ~= nil and ('%.1f, %.1f, %.2f'):format(hx, hy, hz) or '?', hull.locallyOwned and 'simulated' or 'NOT simulated',
        hull.frozen and 'frozen' or 'not frozen', body, apart)
end

-- This game's dip, while it is down: `{ token, id, pad, fade, pilot, since, black }`.
local dip = nil

local function dipReport(body)
    if dip == nil or not dip.pilot then return end
    body.token, body.id = dip.token, dip.id
    TriggerServerEvent(M.Event.SNAP_DIP_READY, body)
end

--- The server's dip: 'out' (the screen to black) or 'in' (the image back).
function SnapClient.Dip(payload)
    if type(payload) ~= 'table' then return end
    local screen = Open77.screen
    if payload.state == 'out' then
        if dip ~= nil and dip.fade ~= nil and type(screen) == 'table' and type(screen.fadeIn) == 'function' then
            pcall(screen.fadeIn, dip.fade, { durationMs = 0 })
        end
        dip = { token = payload.token, id = payload.id, pad = payload.pad, pilot = payload.pilot == true,
            since = M.Now(), fade = nil, black = nil }
        local ms = math.floor(M.Number(payload.ms, 0, 2000, 200))
        local why = nil
        if M.Curtain ~= nil and M.Curtain() ~= nil then
            why = 'this resource\'s own curtain is down'
        elseif type(screen) ~= 'table' or type(screen.fadeOut) ~= 'function' then
            why = 'no Open77.screen.fadeOut'
        else
            local read, id, reason = pcall(screen.fadeOut, { durationMs = ms,
                timeoutMs = math.floor(M.Number(payload.timeoutMs, 1000, 60000, 6000)) })
            if read and id ~= nil then dip.fade = id else why = tostring(read and reason or id) end
        end
        Open77.log.info(('pad snap: docking on pad %s -- %s (%s) -- %s'):format(tostring(payload.pad),
            dip.fade ~= nil and ('the screen dips to black (%d ms)'):format(ms) or ('NO dip: ' .. tostring(why)),
            dip.pilot and 'the pilot' or 'aboard', aboard()))
        if dip.fade == nil then dipReport({ state = 'failed', reason = why }) end
    elseif payload.state == 'in' then
        local mine = dip
        dip = nil
        local ms = math.floor(M.Number(payload.ms, 0, 3000, 350))
        local ok, refusal = mine ~= nil and mine.fade == nil, 'no dip of this game\'s'
        if mine ~= nil and mine.fade ~= nil and type(screen) == 'table' and type(screen.fadeIn) == 'function' then
            local read, answer, reason = pcall(screen.fadeIn, mine.fade, { durationMs = ms })
            ok, refusal = read and answer == true, read and reason or answer
        end
        Open77.log.info(('pad snap: docked on pad %s (%s) -- the image back over %d ms%s, %.2fs after the dip -- %s')
            :format(tostring(payload.pad), tostring(payload.why), ms, ok and '' or (' (' .. tostring(refusal) .. ')'),
                mine ~= nil and (M.Now() - mine.since) / 1000.0 or 0.0, aboard()))
        CreateThread(function()
            Wait(ms + 1000)
            Open77.log.info(('pad snap: 1s after the image came back on pad %s -- %s'):format(tostring(payload.pad), aboard()))
        end)
    end
end

--- The host's word on this game's dip fade.
function SnapClient.Black(state)
    if dip == nil or dip.fade == nil or type(state) ~= 'table' or state.id ~= dip.fade or dip.black ~= nil then return end
    dip.black = M.Now()
    Open77.log.info(('pad snap: the screen is black for the dock on pad %s, %d ms after the ask%s'):format(
        tostring(dip.pad), dip.black - dip.since, dip.pilot and ' -- the server sets the AV down now' or ''))
    dipReport({ state = 'black', ms = dip.black - dip.since })
end

--- The server's ask: measure, and answer at once (a handful of rays).
-- @param payload table `{ token, id, pad, points, fromZ }`
-- @return table the answer sent, for the suite
function SnapClient.Measure(payload)
    if type(payload) ~= 'table' or type(payload.points) ~= 'table' then return nil end
    local fromZ = finite(payload.fromZ)
    local grounds, parts = {}, {}
    for index = 1, math.min(#payload.points, 8) do
        local point = payload.points[index]
        local x, y = type(point) == 'table' and finite(point.x) or nil, type(point) == 'table' and finite(point.y) or nil
        local z, why = nil, 'no point'
        if x ~= nil and y ~= nil then z, why = groundAt(x, y, fromZ) end
        grounds[index] = z ~= nil and z or false
        parts[index] = z ~= nil and ('%.2f'):format(z) or ('none (%s)'):format(tostring(why))
    end
    local answer = { token = payload.token, id = payload.id, pad = payload.pad, grounds = grounds,
        fps = M.FrameRate ~= nil and M.FrameRate() or nil }
    TriggerServerEvent(M.Event.SNAP_GROUND, answer)
    Open77.log.info(('pad snap: the server asks the deck of pad %s under aircraft %s: ground %s (rays from %s)')
        :format(tostring(payload.pad), tostring(payload.id), table.concat(parts, ', '),
            fromZ ~= nil and ('%.1f'):format(fromZ) or 'the default height'))
    return answer
end

--- The snap's state, from the server: a line in this game's log and on screen.
function SnapClient.State(payload)
    if type(payload) ~= 'table' then return end
    local state = tostring(payload.state)
    if state == 'on' then
        Open77.log.info(('pad snap: the server takes this AV onto pad %s (%s)'):format(tostring(payload.pad),
            tostring(payload.kind)))
        notify(M.Text('snap.on', { pad = tostring(payload.pad) }))
    elseif state == 'landed' then
        Open77.log.info(('pad snap: down on pad %s -- %s'):format(tostring(payload.pad), tostring(payload.why)))
        notify(M.Text('snap.landed', { pad = tostring(payload.pad) }))
    else
        Open77.log.info(('pad snap: given back over pad %s -- %s'):format(tostring(payload.pad), tostring(payload.why)))
    end
end

function SnapClient.Start()
    RegisterNetEvent(M.Event.SNAP_MEASURE, function(payload)
        local ran, failure = pcall(SnapClient.Measure, payload)
        if not ran then Open77.log.error('pad snap: the measure failed: ' .. tostring(failure)) end
    end)
    RegisterNetEvent(M.Event.SNAP, function(payload)
        local ran, failure = pcall(SnapClient.State, payload)
        if not ran then Open77.log.warn('pad snap: the state line failed: ' .. tostring(failure)) end
    end)
    RegisterNetEvent(M.Event.SNAP_DIP, function(payload)
        local ran, failure = pcall(SnapClient.Dip, payload)
        if not ran then Open77.log.error('pad snap: the dip failed: ' .. tostring(failure)) end
    end)
    AddEventHandler('open77:screen:black', function(state)
        local ran, failure = pcall(SnapClient.Black, state)
        if not ran then Open77.log.warn('pad snap: the dip\'s black failed: ' .. tostring(failure)) end
    end)
end
