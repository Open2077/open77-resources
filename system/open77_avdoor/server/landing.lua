-- =============================================================================
-- open77_avdoor -- server/landing.lua
-- =============================================================================
-- Where an AV a resource flies may come down: on the ground, at the level of
-- the person it came for, flat under the hull, and open to the sky.
-- (`exports.open77_avdoor:landingSite`, through `Open77.exports.call`.)
--
-- WHY THIS EXISTS. Reported on XyberRP, 2026-10-07: "all avs need to land on
-- the road in game the trauma team av is landing outside on the water while the
-- trauma soldiers or visually walking on air". The AVs a server flew in came
-- down a fixed distance from the body on a fixed bearing, at the body's own
-- height, wherever that fell: over the water off a pier, into a wall, off a
-- ledge. The crew stepped out at that height and walked on nothing.
--
-- A DEDICATED SERVER HAS NO PHYSICS WORLD, so it asks the games
-- (`Open77.world.groundZ`): a connected player's game casts a static ray down
-- from 400 m over a point and answers the height it hit. A point is a place to
-- land when:
--   * the ray hits something -- open water and voids answer nothing at all;
--   * what it hits is at the target's level, within `LEVEL_METRES` -- a ray
--     from 400 m stops on the first roof, overpass or awning over the point, so
--     a covered street, a building and a drop off a quay all fail this one;
--   * the ground `FOOTPRINT_METRES` either side, both ways, is within
--     `FLAT_METRES` of it -- a hull does not stand on stairs, a slope, a kerb
--     against a wall or the edge of a roof.
-- Rings from the caller's own distance out to `FAR_METRES`, every 45 degrees
-- from the caller's bearing; the first place that passes is the one. Roads are
-- where a body in the street has flat, open, level ground nearest, so that is
-- what this finds there.
--
-- AN OBSERVATION, NOT A FACT, AND NEVER A DEFAULT HEIGHT. Nobody near enough
-- to measure is "no observer" and the caller keeps the place it had; the asking
-- is bounded by `BUDGET_SECONDS`. It waits on the games, so it runs in a
-- scheduler coroutine (a thread, an event handler, an export called through
-- `Open77.exports.call`).
--
-- ONLY A GAME CAN MEASURE. The host asks the nearest connected client, and a
-- headless one -- a load-test bot -- never answers: XyberRP's bot lab,
-- 2026-10-07, had every survey wait out a three-second callback on a bot and
-- give up. Nothing the host reports tells a bot from a game. So the first point
-- is asked of up to RACE players near the spot AT ONCE (`options.playerId`,
-- PROBE_MS each), and the first that answers measures the rest; one that does
-- not answer is left out of the next survey for SILENT_MS, and one that did is
-- asked first. A host with no player list lets the platform pick.
-- =============================================================================

local M = AvDoor

M.Landing = {}
local Landing = M.Landing

-- The four corners of the footprint, as offsets of one footprint each.
local CORNERS = { { 1, 0 }, { -1, 0 }, { 0, 1 }, { 0, -1 } }

-- The bearings tried around the caller's own, in order.
local TURNS = { 0, 45, -45, 90, -90, 135, -135, 180 }

local function finite(value)
    local number = tonumber(value)
    if number == nil or number ~= number or number == math.huge or number == -math.huge then return nil end
    return number
end

--- The LANDING block, each number inside a band; nil when it is off.
-- @return table|nil
function Landing.Settings()
    -- Read in two steps: `a and false or nil` is nil, and `false` is the switch.
    local declared = nil
    if type(M.Settings) == 'table' then declared = M.Settings.LANDING end
    if declared == false then return nil end
    local block = type(declared) == 'table' and declared or {}
    return {
        level = M.Number(block.LEVEL_METRES, 0.5, 20.0, 2.5),
        footprint = M.Number(block.FOOTPRINT_METRES, 1.0, 12.0, 4.5),
        flat = M.Number(block.FLAT_METRES, 0.1, 3.0, 0.8),
        far = M.Number(block.FAR_METRES, 10.0, 150.0, 40.0),
        budgetMs = math.floor(M.Number(block.BUDGET_SECONDS, 0.5, 15.0, 4.0) * 1000),
        observer = M.Number(block.OBSERVER_METRES, 50.0, 300.0, 250.0),
        probeMs = math.floor(M.Number(block.PROBE_MS, 250, 3000, 1500)),
    }
end

--- Whether the host can be asked at all: the switch and the query.
-- @return boolean
function Landing.Available()
    if Landing.Settings() == nil then return false end
    local world = type(Open77) == 'table' and Open77.world or nil
    return type(world) == 'table' and type(world.groundZ) == 'function'
end

-- How many players the first point is asked of at once, and how long one that
-- did not answer is left out. Thirty-two at once: a bot lab puts fifty clients
-- round the one game that can answer, and two rounds fit inside the budget.
local RACE = 32
local SILENT_MS = 600000

-- Players that answered a ground query, and ones that did not, by id: when.
local heard, silent = {}, {}

-- An observer that did not answer, or left: somebody else is asked.
local PASS_OVER = { callback_timeout = true, player_not_found = true, rejected = true, cancelled = true,
    promise_cancelled = true }

--- The players who may measure near a point, best first: within
--- OBSERVER_METRES, not silent lately, the ones that answered before first, then
--- the nearest. nil when the host cannot list players (the platform picks).
-- @return table[]|nil `{ id, distance }`
local function candidates(target, cfg)
    local players = type(Open77) == 'table' and Open77.players or nil
    if type(players) ~= 'table' or type(players.all) ~= 'function' or type(players.position) ~= 'function' then
        return nil
    end
    local now = M.Now()
    local listed, list = pcall(players.all)
    local out = {}
    for _, playerId in ipairs(listed and type(list) == 'table' and list or {}) do
        local id = tonumber(playerId)
        -- The host's player reads throw on an id under 1: checked before any read.
        if id ~= nil and id >= 1 and id == math.floor(id)
            and not (silent[id] ~= nil and now - silent[id] < SILENT_MS) then
            local read, at = pcall(players.position, id)
            local x = read and type(at) == 'table' and finite(at.x) or nil
            local y = read and type(at) == 'table' and finite(at.y) or nil
            if x ~= nil and y ~= nil then
                local distance = math.sqrt((x - target.x) ^ 2 + (y - target.y) ^ 2)
                if distance <= cfg.observer then
                    out[#out + 1] = { id = id, distance = distance, heard = heard[id] ~= nil }
                end
            end
        end
    end
    table.sort(out, function(a, b)
        if a.heard ~= b.heard then return a.heard end
        return a.distance < b.distance
    end)
    return out
end

--- One question to one observer. Answers whether it answered (water is an
--- answer: `no_ground`), the height, and why not.
local function ask(world, x, y, id, cfg)
    local ran, z, why = pcall(world.groundZ, { x = x, y = y }, { playerId = id, timeout = cfg.probeMs })
    if not ran then return false, nil, tostring(z) end
    z = finite(z)
    if z ~= nil then
        heard[id] = M.Now()
        return true, z, nil
    end
    why = tostring(type(why) == 'string' and why or 'no_ground')
    if why == 'no_ground' then
        heard[id] = M.Now()
        return true, nil, why
    end
    if PASS_OVER[why] then silent[id] = M.Now() end
    return false, nil, why
end

--- Asks up to RACE observers about one point at once; the first that answers
--- is the one. Waits for that answer or for every one of them to fail.
-- @return number|nil the observer's id
-- @return number|nil z
-- @return string|nil why not
local function race(world, x, y, cfg, list, deadline)
    local waiting, winner, height, reason, last = 0, nil, nil, nil, nil
    while winner == nil and #list > 0 and M.Now() < deadline do
        local batch = {}
        while #batch < RACE and #list > 0 do batch[#batch + 1] = table.remove(list, 1) end
        waiting = #batch
        for _, entry in ipairs(batch) do
            CreateThread(function()
                local answered, z, why = ask(world, x, y, entry.id, cfg)
                waiting = waiting - 1
                if answered and winner == nil then winner, height, reason = entry.id, z, why end
                if not answered then last = why end
            end)
        end
        local until_ = M.Now() + cfg.probeMs + 1000
        while winner == nil and waiting > 0 and M.Now() < until_ do Wait(20) end
    end
    if winner == nil then return nil, nil, 'no_observer: ' .. tostring(last or 'nobody answered') end
    return winner, height, reason
end

--- The height of the ground under one point, as a game measured it: the chosen
--- observer (`state.id`), or a race over the candidates when there is none
--- yet or it stopped answering; the platform's own nearest when the host
--- cannot list players.
-- @return number|nil
-- @return string|nil why not
local function probe(x, y, cfg, state)
    local world = type(Open77) == 'table' and Open77.world or nil
    if type(world) ~= 'table' or type(world.groundZ) ~= 'function' then return nil, 'no_ground_query' end
    if state.list == nil then
        local ran, z, why = pcall(world.groundZ, { x = x, y = y }, { radius = cfg.observer })
        if not ran then return nil, tostring(z) end
        z = finite(z)
        if z ~= nil then return z end
        why = tostring(type(why) == 'string' and why or 'no_ground')
        -- The platform asks the nearest client every time: one that did not
        -- answer will not answer the next point either.
        if PASS_OVER[why] then return nil, 'no_observer: ' .. why end
        return nil, why
    end
    if state.id ~= nil then
        local answered, z, why = ask(world, x, y, state.id, cfg)
        if answered then return z, why end
        state.id = nil
    end
    local id, z, why = race(world, x, y, cfg, state.list, state.deadline)
    state.id = id
    return z, why
end

-- Answers that end a survey at once: nobody can measure, or the host will not
-- be asked again for a while.
local FATAL = { no_observer = true, no_ground_query = true, callback_request_limit = true,
    ['permission_denied:world.query'] = true, resource_stopping = true,
    await_requires_scheduler_coroutine = true, network_unavailable = true }

--- Whether an answer ends the survey: a FATAL reason, as is or with a detail
--- after it (`no_observer: callback_timeout`).
local function fatal(why)
    local text = tostring(why)
    return FATAL[text] == true or FATAL[text:match('^([%w_]+):') or ''] == true
end

--- A player who left: an id the host gives the next one to connect is
--- nobody's silence and nobody's answer.
function Landing.Forget(playerId)
    local id = tonumber(playerId)
    if id == nil then return end
    heard[id], silent[id] = nil, nil
end

--- Forgets everything: a restart starts clean.
function Landing.Reset()
    heard, silent = {}, {}
end

--- Finds where an AV may come down near a point. BLOCKING: every probe waits
--- for a game's answer, so call it from a scheduler coroutine.
-- @param target table `{ x, y, z }`, the person the AV came for
-- @param options table|nil `{ bearing = degrees to try first, near = metres }`
-- @return table|nil `{ x, y, z, bearing, distance, probes, observer }`, z the ground's
-- @return string|nil why not
function Landing.Find(target, options)
    local cfg = Landing.Settings()
    if cfg == nil then return nil, 'landing_off' end
    local x0 = type(target) == 'table' and finite(target.x) or nil
    local y0 = type(target) == 'table' and finite(target.y) or nil
    local z0 = type(target) == 'table' and finite(target.z) or nil
    if x0 == nil or y0 == nil or z0 == nil then return nil, 'no_target' end
    local opts = type(options) == 'table' and options or {}
    local near = math.max(3.0, math.min(cfg.far, finite(opts.near) or 10.0))
    local bearing = (finite(opts.bearing) or 0.0) % 360.0
    local started = M.Now()
    local deadline = started + cfg.budgetMs

    -- The rings: the caller's distance, then outward to FAR_METRES.
    local rings, distance = {}, near
    while distance < cfg.far and #rings < 6 do
        rings[#rings + 1] = distance
        distance = distance + math.max(6.0, near * 0.6)
    end
    rings[#rings + 1] = cfg.far

    -- Who can measure here; nobody within reach is "no observer" at once.
    local state = { list = candidates({ x = x0, y = y0 }, cfg), id = nil, deadline = deadline }
    if state.list ~= nil and #state.list == 0 then return nil, 'no_observer: nobody within reach' end

    local probes = 0
    for _, ring in ipairs(rings) do
        for _, turn in ipairs(TURNS) do
            if M.Now() >= deadline then
                return nil, ('out of time after %d probe(s)'):format(probes)
            end
            local heading = (bearing + turn) % 360.0
            local radians = math.rad(heading)
            local cx, cy = x0 + math.cos(radians) * ring, y0 + math.sin(radians) * ring
            local z, why = probe(cx, cy, cfg, state)
            probes = probes + 1
            if z == nil and fatal(why) then
                return nil, ('%s after %d probe(s)'):format(why, probes)
            end
            if z ~= nil and math.abs(z - z0) <= cfg.level then
                local flat = true
                for _, corner in ipairs(CORNERS) do
                    local zc, cornerWhy = probe(cx + corner[1] * cfg.footprint, cy + corner[2] * cfg.footprint, cfg,
                        state)
                    probes = probes + 1
                    if zc == nil and fatal(cornerWhy) then
                        return nil, ('%s after %d probe(s)'):format(cornerWhy, probes)
                    end
                    if zc == nil or math.abs(zc - z) > cfg.flat then
                        flat = false
                        break
                    end
                end
                if flat then
                    return { x = cx, y = cy, z = z, bearing = heading, distance = ring, probes = probes,
                        observer = state.id, ms = M.Now() - started }
                end
            end
        end
    end
    return nil, ('no flat open ground at the target\'s level within %.0f m (%d probe(s))'):format(cfg.far, probes)
end
