-- =============================================================================
-- open77_avdrive -- client/main.lua
-- =============================================================================
-- The one key, the waypoint it reads, and the words the pilot reads.
--
-- THE KEY IS THE WHOLE SURFACE. There is no card, no marker and no menu: a
-- pilot presses the binding, this file reads the pilot's own map waypoint and
-- hands the destination to the server, and every word the pilot reads after
-- that is a notice the server chose. The server re-derives the seat, the hull
-- and the record from the connection, so nothing here is a claim -- the
-- payload is the destination and the honest flag saying the map could not be
-- read, and nothing more.
--
-- `nil` AND `nil, reason` ARE DIFFERENT ANSWERS from the waypoint read: the
-- first is "no waypoint is set" and the second is "the question could not be
-- asked". A pilot who dropped no pin is told to drop one; a host whose map
-- read is broken is told it is broken.
--
-- THE ARRIVAL (1.1.0): the screen, and the ground under the pin. Arriving, the
-- server asks every game aboard to fade out; the pilot's game says when its
-- screen is black (the host's own `open77:screen:black`), the server flies the
-- aircraft to the pin under the black (1.2.0) while the pilot's game says four
-- times a second where it has the aircraft -- its body in it, the engine's
-- own truth -- and whether a loading screen is up, and the server holds the
-- flight for it. Over the pin, the pilot's game measures the ground there --
-- once the world has streamed in, a ray straight down every 250 ms until two
-- agree. Then the screen comes back, and the pilot's game watches for the
-- controls: whether it simulates the aircraft again. Nothing here moves
-- anything: the server moves the aircraft, and believes this game only about
-- its own screen, where it has the aircraft, the height of the ground and
-- whether it has the controls. The fade's own safety deadline (`timeoutMs`)
-- brings the image back if the server never does.
-- =============================================================================

local M = AvDrive

--- Reads the pilot's map waypoint through the platform's own read.
-- @return table|nil `{ x, y, z }`
-- @return boolean whether the read itself failed, rather than no pin being set
local function waypoint()
    local api = type(Open77) == 'table' and Open77.blips or nil
    if type(api) ~= 'table' or type(api.waypoint) ~= 'function' then return nil, true end
    local read, point, reason = pcall(api.waypoint)
    if not read then return nil, true end
    if type(point) ~= 'table' then
        -- A bare nil is no waypoint; a nil WITH a reason is a question the host
        -- could not answer. They name two different notices.
        return nil, reason ~= nil
    end
    local x, y, z = tonumber(point.x), tonumber(point.y), tonumber(point.z)
    if x == nil or y == nil or z == nil then return nil, true end
    return { x = x, y = y, z = z }, false
end

--- The one press: read the pin, hand it over. The OFF half of the toggle needs
--- no destination at all: a run in flight is cancelled by the press whatever
--- the payload says.
local function toggle()
    local position, unreadable = waypoint()
    TriggerServerEvent(M.Event.TOGGLE, { position = position, unreadable = unreadable == true })
    Open77.log.info(('autopilot key: waypoint %s'):format(position ~= nil
        and ('%.0f, %.0f, %.0f'):format(position.x, position.y, position.z)
        or (unreadable and 'unreadable' or 'not set')))
end

RegisterNetEvent(M.Event.NOTICE, function(payload)
    if type(payload) ~= 'table' or type(payload.key) ~= 'string' then return end
    local text = M.Text(payload.key)
    local hud = Open77.hud
    if type(hud) == 'table' and type(hud.notify) == 'function' and pcall(hud.notify, text, { replace = true }) then
        return
    end
    Open77.log.info('notice: ' .. text)
end)

-- ── the arrival (1.1.0; flown under the black since 1.2.0) ───────────────────

--- A finite number, or nil.
local function finite(value)
    local n = tonumber(value)
    if n == nil or n ~= n or n == math.huge or n == -math.huge then return nil end
    return n
end

--- A whole number inside a band, or the fallback.
local function clamp(value, low, high, fallback)
    local n = finite(value)
    if n == nil then return fallback end
    return math.floor(math.max(low, math.min(high, n)))
end

local function point(x, y, z)
    if x == nil or y == nil or z == nil then return '?' end
    return ('%.1f, %.1f, %.1f'):format(x, y, z)
end

local function apart(a, b)
    if a == nil or b == nil then return nil end
    return math.sqrt((a.x - b.x) ^ 2 + (a.y - b.y) ^ 2 + (a.z - b.z) ^ 2)
end

--- The game's own loading screen as this client reports it (1.2.0,
--- `Open77.screen.loadingState`, an updated client): the state, or nil and why
--- this client cannot say. nil is "unknown", never "no loading screen".
local function loadingState()
    local screen = type(Open77) == 'table' and Open77.screen or nil
    if type(screen) ~= 'table' or type(screen.loadingState) ~= 'function' then
        return nil, 'this client cannot say (no Open77.screen.loadingState)'
    end
    local read, state, reason = pcall(screen.loadingState)
    if not read then return nil, 'the read failed: ' .. tostring(state) end
    if type(state) ~= 'table' then return nil, tostring(reason or 'no state') end
    return state, nil
end

--- A loading state in words, for the log.
local function loadingText(state, why)
    if type(state) ~= 'table' then return 'loading screen unknown: ' .. tostring(why) end
    if state.active ~= true then return 'no loading screen' end
    local progress = finite(state.progress)
    return ('a LOADING SCREEN up (%s, %.1fs%s)'):format(tostring(state.kind or '?'), (finite(state.elapsedMs) or 0) / 1000.0,
        progress ~= nil and (', %d%%'):format(math.floor(progress * 100 + 0.5)) or '')
end

--- The engine's own fade, in words, for the log (`Open77.screen.nativeState`).
local function fadeText()
    local screen = type(Open77) == 'table' and Open77.screen or nil
    if type(screen) ~= 'table' or type(screen.nativeState) ~= 'function' then return 'the engine fade unknown' end
    local read, state = pcall(screen.nativeState)
    if not read or type(state) ~= 'table' then return 'the engine fade unknown' end
    if state.faded then return 'the engine black' end
    if state.fading then return ('the engine fading (%s ms left)'):format(tostring(state.remainingMs or '?')) end
    return 'the engine clear'
end

--- Where this game has the aircraft it sits in (1.2.0): its copy of the hull
--- -- the last pose it was sent -- and its body in it, the engine's own truth;
--- whether it simulates the aircraft; and, with no aircraft to show, why.
-- @return table `{ id, seat, drawn, bodyAt, body, owned, frozen, streamed, heading, speed, owner, undrawn }`
local function where()
    local out = {}
    local character = type(Open77) == 'table' and Open77.character or nil
    if type(character) == 'table' and type(character.position) == 'function' then
        local read, x, y, z = pcall(character.position)
        if read and finite(x) ~= nil and finite(y) ~= nil and finite(z) ~= nil then
            out.bodyAt = { x = finite(x), y = finite(y), z = finite(z) }
        end
    end
    local vehicles = type(Open77) == 'table' and Open77.vehicles or nil
    if type(vehicles) ~= 'table' or type(vehicles.getPlayerSeat) ~= 'function' or type(vehicles.get) ~= 'function' then
        out.undrawn = 'no api'
        return out
    end
    local read, seat = pcall(vehicles.getPlayerSeat)
    if not read or type(seat) ~= 'table' then
        out.undrawn = 'in no seat'
        return out
    end
    out.id, out.seat = seat.vehicleId, seat.seat
    local readHull, hull = pcall(vehicles.get, seat.vehicleId)
    if not readHull or type(hull) ~= 'table' then
        out.undrawn = 'not streamed'
        return out
    end
    local at = type(hull.position) == 'table' and hull.position or {}
    local x, y, z = finite(at.x), finite(at.y), finite(at.z)
    if x == nil or y == nil or z == nil then
        out.undrawn = 'no position'
        return out
    end
    out.drawn = { x = x, y = y, z = z }
    out.owned, out.frozen, out.streamed = hull.locallyOwned == true, hull.frozen == true, hull.streamed
    out.heading, out.speed, out.owner = finite(hull.heading), finite(hull.speed), hull.physicsOwner
    out.body = apart(out.bodyAt, out.drawn)
    return out
end

--- Where this game draws its own body and the aircraft it sits in, whether a
--- loading screen is up and what the engine's fade is doing, for the log: the
--- evidence of what the pilot saw.
local function aboard(w)
    w = w or where()
    local tail = ('; %s; %s'):format(loadingText(loadingState()), fadeText())
    local body = w.bodyAt ~= nil and point(w.bodyAt.x, w.bodyAt.y, w.bodyAt.z) or '?'
    if w.id == nil then return ('the body at %s, in no seat%s'):format(body, tail) end
    if w.drawn == nil then
        return ('the body at %s, in %s of aircraft %s, which this game does not draw (%s)%s'):format(body,
            tostring(w.seat), tostring(w.id), tostring(w.undrawn), tail)
    end
    return ('in %s of aircraft %s, drawn at %s facing %s (%s by this game, %s, lease of player %s, %.1f m/s%s); the '
        .. 'body at %s, %s from it%s'):format(tostring(w.seat), tostring(w.id), point(w.drawn.x, w.drawn.y, w.drawn.z),
        tostring(w.heading ~= nil and math.floor(w.heading + 0.5) or '?'), w.owned and 'simulated' or 'NOT simulated',
        w.frozen and 'frozen' or 'not frozen', tostring(w.owner), w.speed or 0.0,
        w.streamed == false and ', NOT streamed' or '', body, w.body ~= nil and ('%.1f m'):format(w.body) or '?', tail)
end

-- Whether this client's rays take collision groups (Stable 156), so that the
-- ground is the static meshes AND the open terrain (the Badlands): nil until
-- the first ray. (open77_avlanding asks the same way.)
local rayGroups = nil
local GROUND_GROUPS = { 'Static', 'Terrain' }

--- Asks once. A build that knows `groups` refuses them beside `static` by name
--- (`collision_groups_conflict`) before it traces anything; an older one
--- ignores the field and traces Static and Dynamic -- the hulls, this one
--- among them -- which is why it must not be asked for the ground.
local function probeRayGroups(world)
    if type(world.raycast) ~= 'function' then return false, 'no Open77.world.raycast' end
    local read, answer, reason = pcall(world.raycast, { x = 0.0, y = 0.0, z = 1500.0 }, { x = 0.0, y = 0.0, z = 1499.0 },
        { groups = { 'Static' }, static = true })
    if read and answer == nil and reason == 'collision_groups_conflict' then return true, nil end
    return false, read and ('its rays take no collision groups (%s)'):format(answer == nil and tostring(reason) or 'traced')
        or ('the probe ray failed: %s'):format(tostring(answer))
end

--- The ground under a point, straight down from `fromZ`: the first static mesh
--- -- or the terrain, where this client's rays meet it. nil when nothing is
--- below (open water, a world not streamed in yet, terrain on an older client).
-- @return number|nil z
-- @return string what met it, or why nothing could
local function groundBelow(x, y, fromZ)
    local world = type(Open77) == 'table' and Open77.world or nil
    if type(world) ~= 'table' then return nil, 'no Open77.world' end
    if rayGroups == nil then
        local why
        rayGroups, why = probeRayGroups(world)
        Open77.log.info(rayGroups and 'arrival ground: the static meshes and the terrain (this client\'s rays take '
            .. 'collision groups)' or ('arrival ground: the static meshes only, %s'):format(tostring(why)))
    end
    if rayGroups then
        local read, hit, reason = pcall(world.raycast, { x = x, y = y, z = fromZ }, { x = x, y = y, z = fromZ - 1000.0 },
            { groups = GROUND_GROUPS })
        if read and type(hit) == 'table' then
            if hit.hit ~= true then return nil, 'the static and terrain ray met nothing' end
            local at = type(hit.position) == 'table' and hit.position or {}
            return finite(at.z), 'the static and terrain ray'
        end
        local cause = tostring(read and reason or hit)
        if cause:find('collision_group', 1, true) then
            rayGroups = false
            Open77.log.warn(('arrival ground: the terrain ray was refused (%s): the static meshes only from now on')
                :format(cause))
        end
    end
    if type(world.groundZ) ~= 'function' then return nil, 'no Open77.world.groundZ' end
    local read, z, reason = pcall(world.groundZ, x, y, fromZ)
    if not read then return nil, 'the static ray failed: ' .. tostring(z) end
    if finite(z) == nil then return nil, reason ~= nil and ('the static ray: ' .. tostring(reason)) or 'the static ray met nothing' end
    return finite(z), 'the static ray'
end

-- This game's part in the arrival under way: `{ token, id, since, pilot,
-- black, pacing }` -- `id` the fade this game owns, while it owns one;
-- `pacing` while the pilot's game says where it has the aircraft (1.2.0).
local arrival = nil
-- The measures under way, by token: an 'in' ends its measure.
local measuring = {}

--- Says something to the server about an arrival: the pilot's game only.
local function report(token, body)
    body.token = token
    TriggerServerEvent(M.Event.ARRIVE_READY, body)
end

--- The fade a newer arrival replaces, lifted at once.
local function drop(why)
    if arrival == nil or arrival.id == nil then arrival = nil return end
    local screen = Open77.screen
    if type(screen) == 'table' and type(screen.fadeIn) == 'function' then pcall(screen.fadeIn, arrival.id, { durationMs = 0 }) end
    Open77.log.info(('arrival %s: its fade lifted at once (%s)'):format(tostring(arrival.token), why))
    arrival = nil
end

--- THE PACE (1.2.0). While the aircraft is flown under the black, the pilot's
--- game says every `every` ms where it has the aircraft and whether a loading
--- screen is up; the server flies no farther ahead of it than its leash, and
--- holds while it loads. Nothing here moves anything. A line in the log every
--- 2 s, and one whenever the loading screen comes or goes.
local function pace(token, every)
    CreateThread(function()
        local count, loggedAt, wasLoading = 0, nil, nil
        while arrival ~= nil and arrival.token == token and arrival.pacing do
            local w = where()
            local state = loadingState()
            local loading = type(state) == 'table' and state.active == true
            count = count + 1
            report(token, { state = 'pace', drawn = w.drawn, bodyAt = w.bodyAt, body = w.body, owned = w.owned == true,
                loading = loading, loadingKind = loading and tostring(state.kind or 'unknown') or nil,
                undrawn = w.undrawn })
            local now = M.Now()
            if wasLoading ~= nil and loading ~= wasLoading then
                Open77.log.warn(('arrival %s: the loading screen %s under the flight -- %s'):format(tostring(token),
                    loading and 'CAME UP' or 'went away', aboard(w)))
            end
            wasLoading = loading
            if loggedAt == nil or now - loggedAt >= 2000 then
                loggedAt = now
                Open77.log.info(('arrival %s: flown under the black, report %d -- %s'):format(tostring(token), count,
                    aboard(w)))
            end
            Wait(every)
        end
        Open77.log.info(('arrival %s: %d report(s) on the flight sent'):format(tostring(token), count))
    end)
end

--- 'out': the screen fades out. The pilot's game answers when it is black, and
--- says where it has the aircraft for as long as it is flown.
local function fadeOut(payload)
    if arrival ~= nil then drop('arrival ' .. tostring(payload.token) .. ' began') end
    local ms = clamp(payload.ms, 0, 5000, 600)
    local timeout = clamp(payload.timeoutMs, 1000, 60000, 20000)
    arrival = { token = payload.token, since = M.Now(), pilot = payload.pilot == true, black = nil, id = nil,
        pacing = payload.pilot == true }
    local role = arrival.pilot and 'the pilot' or 'aboard'
    if arrival.pacing then pace(payload.token, clamp(payload.paceMs, 100, 2000, 250)) end
    local screen = Open77.screen
    if type(screen) ~= 'table' or type(screen.fadeOut) ~= 'function' then
        Open77.log.warn(('arrival %s (%s): no Open77.screen.fadeOut on this client -- the flight is seen'):format(
            tostring(payload.token), role))
        if arrival.pilot then report(payload.token, { state = 'failed', reason = 'no Open77.screen.fadeOut' }) end
        return
    end
    local read, id, reason = pcall(screen.fadeOut, { durationMs = ms, timeoutMs = timeout })
    if not read or id == nil then
        local why = tostring(read and reason or id)
        Open77.log.warn(('arrival %s (%s): the screen could not fade out (%s) -- the flight is seen'):format(
            tostring(payload.token), role, why))
        if arrival.pilot then report(payload.token, { state = 'failed', reason = why }) end
        return
    end
    arrival.id = id
    Open77.log.info(('arrival %s (%s): the screen fades out (%d ms; the image back by itself after %.0fs at most) -- %s')
        :format(tostring(payload.token), role, ms, timeout / 1000.0, aboard()))
end

--- 'measure': the aircraft is over the pin; the flight is over, and the pilot's
--- game measures the ground under it once the world there has streamed in.
local function measure(payload)
    local token = payload.token
    if arrival ~= nil and arrival.token == token then arrival.pacing = false end
    local x, y, fromZ = finite(payload.x), finite(payload.y), finite(payload.fromZ)
    local hoverZ = finite(payload.hoverZ)
    local settle = clamp(payload.settleMs, 0, 10000, 1200)
    local window = clamp(payload.measureMs, 500, 20000, 6000)
    if x == nil or y == nil or fromZ == nil then
        Open77.log.warn(('arrival %s: a measure with no point to measure'):format(tostring(token)))
        report(token, { state = 'ground', reads = 0, ms = 0, by = 'no point' })
        return
    end
    measuring[token] = true
    Open77.log.info(('arrival %s: the aircraft is over the pin (the server has it %.1f up) -- %s; the ground under '
        .. '%.1f, %.1f looked for in %d ms, for %d ms at most'):format(tostring(token), hoverZ or 0.0, aboard(), x, y,
        settle, window))
    CreateThread(function()
        Wait(settle)
        local started = M.Now()
        local reads, misses, last, agreed, highest, by, why = 0, 0, nil, nil, nil, nil, nil
        while measuring[token] do
            local z, how = groundBelow(x, y, fromZ)
            reads = reads + 1
            if z == nil then
                misses, last, why = misses + 1, nil, how
            else
                if highest == nil or z > highest then highest, by = z, how end
                if last ~= nil and math.abs(z - last) <= 0.3 then agreed, by = math.max(z, last), how break end
                last = z
            end
            if M.Now() - started >= window then break end
            Wait(250)
        end
        if not measuring[token] then
            Open77.log.info(('arrival %s: the measure stopped after %d read(s) -- the arrival is over'):format(
                tostring(token), reads))
            return
        end
        measuring[token] = nil
        local z = agreed or highest
        local spent = settle + (M.Now() - started)
        -- Where this game has the aircraft against where the server put it:
        -- the evidence that the flight under the black reached this game.
        local w = where()
        local state = loadingState()
        local off = (w.drawn ~= nil and hoverZ ~= nil) and apart(w.drawn, { x = x, y = y, z = hoverZ }) or nil
        Open77.log.info(('arrival %s: the ground under the pin %s after %d read(s), %d miss(es), %.1fs%s -- %s'):format(
            tostring(token), z ~= nil and ('at %.1f (%s, %s)'):format(z, tostring(by), agreed and 'two reads agree'
            or 'the highest of reads that never agreed') or 'NOT found', reads, misses, spent / 1000.0,
            z == nil and (' -- ' .. tostring(why)) or '', aboard(w)))
        report(token, { state = 'ground', z = z, reads = reads, ms = spent, by = by, agreed = agreed ~= nil,
            drawnOff = off, body = w.body, loading = type(state) == 'table' and state.active == true })
    end)
end

--- THE CONTROLS (1.2.0). Once the image is back, the pilot's game watches for
--- the aircraft to be its own again -- this game simulating it -- for
--- `waitMs` at most, and says which: a game that did not get it back is handed
--- it by the server's ask to the platform.
local function watch(token, waitMs)
    CreateThread(function()
        local started = M.Now()
        local w = where()
        while not w.owned and M.Now() - started < waitMs do
            Wait(200)
            w = where()
        end
        local state, why = loadingState()
        local spent = M.Now() - started
        local line = ('arrival %s: %s, %.1fs after the screen began to come back -- %s'):format(tostring(token),
            w.owned and 'this game SIMULATES the aircraft again: the controls are the pilot\'s'
            or 'this game does NOT simulate the aircraft: the server asks the platform for it', spent / 1000.0, aboard(w))
        if w.owned then Open77.log.info(line) else Open77.log.warn(line) end
        report(token, { state = 'after', owned = w.owned == true, ms = spent,
            loading = type(state) == 'table' and state.active == true,
            loadingKind = type(state) == 'table' and state.active == true and tostring(state.kind or 'unknown') or nil,
            unknown = state == nil and tostring(why):sub(1, 60) or nil })
    end)
end

--- 'in': the arrival is over, whatever ended it -- the screen comes back.
local function fadeIn(payload)
    local token = payload.token
    measuring[token] = nil
    local why = tostring(payload.why or '?')
    local ms = clamp(payload.ms, 0, 5000, 800)
    if arrival == nil or arrival.token ~= token then
        Open77.log.info(('arrival %s over (%s): no fade of this game\'s to lift -- %s'):format(tostring(token), why,
            aboard()))
    else
        local mine = arrival
        arrival = nil
        if mine.id == nil then
            Open77.log.info(('arrival %s over (%s): this game\'s screen was not faded -- %s'):format(tostring(token), why,
                aboard()))
        else
            local screen = Open77.screen
            local ok, refusal = false, 'no Open77.screen.fadeIn'
            if type(screen) == 'table' and type(screen.fadeIn) == 'function' then
                local read, answer, reason = pcall(screen.fadeIn, mine.id, { durationMs = ms })
                ok, refusal = read and answer == true, read and reason or answer
            end
            Open77.log.info(('arrival %s over (%s): the image back over %d ms, %.1fs after the fade began%s -- %s'):format(
                tostring(token), why, ms, (M.Now() - mine.since) / 1000.0,
                ok and '' or (' -- the fade-in was refused: ' .. tostring(refusal)), aboard()))
        end
    end
    -- Handed back (not cancelled): the pilot's game watches for the controls.
    if payload.pilot == true and payload.ownWaitMs ~= nil then watch(token, clamp(payload.ownWaitMs, 500, 20000, 5000)) end
    -- Two looks once the image is back: what the pilot sees at last, and
    -- whether the aircraft holds its hover in the pilot's hands.
    CreateThread(function()
        Wait(ms + 1000)
        Open77.log.info(('arrival %s: 1s after the image came back -- %s'):format(tostring(token), aboard()))
        Wait(2000)
        Open77.log.info(('arrival %s: 3s after the image came back -- %s'):format(tostring(token), aboard()))
    end)
end

RegisterNetEvent(M.Event.ARRIVE, function(payload)
    if type(payload) ~= 'table' or type(payload.token) ~= 'string' then return end
    local handlers = { out = fadeOut, measure = measure, ['in'] = fadeIn }
    local handler = handlers[payload.state]
    if handler == nil then return end
    local ran, failure = pcall(handler, payload)
    if not ran then Open77.log.error(('the arrival %s step failed: %s'):format(tostring(payload.state), tostring(failure))) end
end)

-- The host's own word on the fade this game owns.
AddEventHandler('open77:screen:black', function(state)
    if arrival == nil or type(state) ~= 'table' or arrival.id == nil or state.id ~= arrival.id or arrival.black then return end
    arrival.black = M.Now()
    local ms = arrival.black - arrival.since
    Open77.log.info(('arrival %s: the screen is black, %d ms after the ask%s'):format(tostring(arrival.token), ms,
        arrival.pilot and ' -- the server flies the aircraft now' or ''))
    if arrival.pilot then report(arrival.token, { state = 'black', ms = ms }) end
end)

--- A fade that ended before the arrival did: the host's safety deadline, a
--- vanilla transition taking over, a failure. Before the black, the flight is
--- seen; after it (1.2.0), the flight under way is given up where this game has
--- the aircraft -- a flight in view would be one the pilot watches jump.
local function ended(kind)
    return function(state)
        if arrival == nil or type(state) ~= 'table' or arrival.id == nil or state.id ~= arrival.id then return end
        local reason = tostring(state.reason)
        arrival.id = nil
        Open77.log.warn(('arrival %s: the fade was %s (%s) %.1fs after the ask%s -- %s'):format(tostring(arrival.token),
            kind, reason, (M.Now() - arrival.since) / 1000.0, arrival.black and '' or ' -- before the screen was black',
            aboard()))
        if arrival.pilot then
            report(arrival.token, { state = 'failed', reason = kind .. ': ' .. reason
                .. (arrival.black and ' (after the screen was black)' or '') })
        end
    end
end
AddEventHandler('open77:screen:cancelled', ended('cancelled'))
AddEventHandler('open77:screen:failed', ended('failed'))

-- The game's own loading screen, said in the log whenever it opens or closes
-- (1.2.0; an updated client, `screen.read`): the evidence an arrival needs,
-- and nothing else reads it.
for _, edge in ipairs({ 'started', 'finished' }) do
    AddEventHandler('open77:loadingScreen:' .. edge, function(state)
        if type(state) ~= 'table' then return end
        local line = ('the game\'s loading screen %s (%s, %.1fs)%s -- %s'):format(edge, tostring(state.kind or '?'),
            (finite(state.elapsedMs) or 0) / 1000.0, arrival ~= nil and (' during arrival ' .. tostring(arrival.token)) or '',
            aboard())
        if arrival ~= nil then Open77.log.warn(line) else Open77.log.info(line) end
    end)
end

-- THE BINDING. The id is stable because a player's rebind is stored under it;
-- the name is in this game's language.
local declared = type(M.Settings) == 'table' and M.Settings.KEY or nil
if type(declared) == 'table' and declared.DEFAULT ~= false then
    local input = Open77.input
    if type(input) ~= 'table' or type(input.registerKeyMapping) ~= 'function' then
        Open77.log.warn('this client has no Open77.input.registerKeyMapping: the autopilot has no key')
    elseif type(declared.ID) ~= 'string' or type(declared.DEFAULT) ~= 'string' then
        Open77.log.warn('KEY is not a table of ID and DEFAULT: the autopilot has no key')
    else
        local called, effective, reason = pcall(input.registerKeyMapping, {
            id = declared.ID,
            name = M.Text('key.toggle'),
            key = declared.DEFAULT,
            onPressed = function()
                local ran, failure = pcall(toggle)
                if not ran then Open77.log.error('the autopilot key failed: ' .. tostring(failure)) end
            end,
        })
        if not called or effective == nil or effective == false then
            Open77.log.warn(('key mapping %s (%s) not registered: %s')
                :format(declared.ID, declared.DEFAULT, tostring(called and reason or effective)))
        else
            Open77.log.info(('autopilot key: %s (%s)'):format(tostring(effective), declared.ID))
        end
    end
end
