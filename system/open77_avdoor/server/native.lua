-- =============================================================================
-- open77_avdoor -- server/native.lua
-- =============================================================================
-- THE GAME'S OWN ENTRY, SHUT (1.7.4). An aircraft answers F twice: the door
-- card (this resource -- the step up into the door, the seat it may take) and
-- the game's own vehicle entry, which mounts the body in the seat whose door
-- the eye is on, at once, with no step. Which one F reaches depends on where
-- the eye is: the owner's first boarding of a run on Staging (2026-10-29,
-- 01:08:17 local) sat him in `seat_back_left` with no line of this resource;
-- the next, on the card, played the step -- "enter animation isnt working
-- everytime i enter av".
--
-- THE PLATFORM TAKES EVERY MOUNT CHOICE OFF A VEHICLE LOCKED FOR A PLAYER
-- (devkit guide "Entry lock": "the replicated bit synchronously removes every
-- mount choice from the vehicle and is checked again at the mounting
-- boundary"), and a lock can be one player's alone
-- (`Open77.vehicles.setLockedForPlayer`, "the substitution happens at the
-- single point where state reaches a socket"). So, every scan:
--   * a player ON FOOT within `METRES` of an aircraft in their bucket gets it
--     locked for them alone -- the canonical bit, the one keys turn, is never
--     touched, and whatever exception they held is remembered;
--   * past `RELEASE_METRES`, seated (anywhere), gone, or just before the card
--     seats them (`warpPlayerIntoVehicle`, which "intentionally bypasses ...
--     the vehicle's locked flag" -- released all the same, so the mount meets
--     no lock at all), they get back exactly what they had: their own
--     exception, or none;
--   * every `CHECK_EVERY` scans each hold is read back: another resource's
--     `setLockedForAll` takes every exception away, and the hold is set again.
-- WHO MAY BOARD is still the owner's lock (`M.NativeEntry.PolicyFor`): the
-- hold is this resource's, not a lock -- server/main.lua's `lockedFor` asks
-- here first. A player's game reads a held aircraft as locked; a keys row
-- shows it so, and the key still turns the real lock.
-- EVERY BOARDING THROUGH THE GAME'S OWN ENTRY that still happens (a host
-- without the per-player lock, a player faster than a scan) is a WARN line in
-- the server log, with whether a hold stood for that player.
-- =============================================================================

local M = AvDoor
local N = {}
M.NativeEntry = N

-- The holds, by the hull's key then the player:
-- `{ id, before, excepted, since, distance }` -- `before` what the player was
-- told before the hold, `excepted` whether that was an exception of their own
-- (it differed from the canonical bit).
local holds = {}

-- Scans since the start, for `CHECK_EVERY`.
local scans = 0

-- What happened, for `/avdoor.status` and the suite.
local counts = { held = 0, released = 0, reasserted = 0, failed = 0, gameEntries = 0, gameEntriesHeld = 0 }

-- The seats this resource's card gave, by player: `{ key, at }`, so a seat
-- that appears without one is the game's own entry.
local carded = {}

local said = {}
local function once(key, level, text)
    if said[key] then return end
    said[key] = true
    Open77.log[level](text)
end

local function cfg() return M.NativeSettings() end

local function api()
    local vehicles = Open77 ~= nil and Open77.vehicles or nil
    if type(vehicles) ~= 'table' then return nil end
    if type(vehicles.setLockedForPlayer) ~= 'function' or type(vehicles.isLockedForPlayer) ~= 'function'
        or type(vehicles.isLocked) ~= 'function' then
        return nil
    end
    return vehicles
end

local function holdOf(key, playerId)
    local byPlayer = holds[key]
    return byPlayer ~= nil and byPlayer[playerId] or nil
end

local function forget(key, playerId)
    local byPlayer = holds[key]
    if byPlayer == nil then return end
    byPlayer[playerId] = nil
    if next(byPlayer) == nil then holds[key] = nil end
end

--- Locks one aircraft for one player alone. @return boolean held
local function hold(vehicles, hull, playerId, metres)
    local key = M.KeyOf(hull.id)
    local readBefore, before = pcall(vehicles.isLockedForPlayer, hull.id, playerId)
    local readCanon, canonical = pcall(vehicles.isLocked, hull.id)
    if not readBefore or not readCanon or type(before) ~= 'boolean' or type(canonical) ~= 'boolean' then
        return false
    end
    local set, ok, why = pcall(vehicles.setLockedForPlayer, hull.id, playerId, true)
    if not set or ok ~= true then
        counts.failed = counts.failed + 1
        once('hold:' .. key .. ':' .. playerId, 'warn', ('the game\'s own entry to aircraft %s could not be shut for '
            .. 'player %d (%s): F at its door may seat them without the step'):format(key, playerId,
            tostring(set and why or ok)))
        return false
    end
    holds[key] = holds[key] or {}
    holds[key][playerId] = { id = hull.id, before = before, excepted = before ~= canonical, since = M.Now(),
        distance = metres }
    counts.held = counts.held + 1
    Open77.log.info(('the game\'s own entry to aircraft %s shut for player %d (%.1f m away; %s): F at its door is '
        .. 'the door card\'s'):format(key, playerId, metres, before ~= canonical
            and ('their own exception kept for later: ' .. (before and 'locked' or 'unlocked'))
            or ('the owner\'s lock: ' .. (canonical and 'locked' or 'unlocked'))))
    return true
end

--- Gives one player back what they had. @return boolean
local function release(key, playerId, why)
    local h = holdOf(key, playerId)
    if h == nil then return false end
    forget(key, playerId)
    local vehicles = api()
    if vehicles == nil then return false end
    local done, ok, reason
    if h.excepted then
        done, ok, reason = pcall(vehicles.setLockedForPlayer, h.id, playerId, h.before)
    elseif type(vehicles.clearLockedForPlayer) == 'function' then
        done, ok, reason = pcall(vehicles.clearLockedForPlayer, h.id, playerId)
    else
        done, ok, reason = pcall(vehicles.setLockedForPlayer, h.id, playerId, nil)
    end
    counts.released = counts.released + 1
    if done and ok == true then
        Open77.log.info(('the game\'s own entry to aircraft %s open again for player %d (%s), after %.1fs'):format(key,
            playerId, why, (M.Now() - h.since) / 1000.0))
    else
        -- A hull or a player already gone took the exception with it.
        Open77.log.info(('the game\'s own entry to aircraft %s: player %d\'s hold let go (%s; the platform answered %s)')
            :format(key, playerId, why, tostring(done and reason or ok)))
    end
    return true
end

--- What the owner's lock says for this player while this resource holds one
--- of its own, or nil when it holds none (server/main.lua's `lockedFor`).
-- @return boolean|nil
function N.PolicyFor(id, playerId)
    local h = holdOf(M.KeyOf(id), tonumber(playerId))
    if h == nil then return nil end
    local vehicles = Open77 ~= nil and Open77.vehicles or nil
    if type(vehicles) ~= 'table' then return h.before end
    -- THE HOLD TAKEN AWAY MEANWHILE: another resource set this player's view
    -- (keys: an exception of their own) or took every exception away -- what
    -- the player is told now is the policy.
    if type(vehicles.isLockedForPlayer) == 'function' then
        local read, now = pcall(vehicles.isLockedForPlayer, id, playerId)
        if read and now == false then return false end
    end
    if h.excepted then return h.before end
    if type(vehicles.isLocked) ~= 'function' then return h.before end
    local read, canonical = pcall(vehicles.isLocked, id)
    if read and type(canonical) == 'boolean' then return canonical end
    return h.before
end

--- Just before the card seats a player (server/main.lua's `M.Board`): the hold
--- on that hull comes off, and the seat is marked as the card's.
function N.Seating(id, playerId)
    local key = M.KeyOf(id)
    playerId = tonumber(playerId)
    if playerId == nil then return end
    carded[playerId] = { key = key, at = M.Now() }
    release(key, playerId, 'the door card seats them')
end

--- A seat appeared in an aircraft (server/main.lua's occupancy diff): through
--- the card, or through the game's own entry -- said.
function N.SatDown(id, seat, playerId)
    playerId = tonumber(playerId)
    if playerId == nil then return end
    local key = M.KeyOf(id)
    local card = carded[playerId]
    carded[playerId] = nil
    if card ~= nil and card.key == key and M.Now() - card.at <= 10000 then return end
    counts.gameEntries = counts.gameEntries + 1
    local h = holdOf(key, playerId)
    if h ~= nil then counts.gameEntriesHeld = counts.gameEntriesHeld + 1 end
    Open77.log.warn(('player %d boarded aircraft %s (%s) through the game\'s own entry, not the door card: no step '
        .. 'up -- %s'):format(playerId, key, tostring(seat), h ~= nil
            and ('its own entry was shut for them %.1fs before (the platform let the mount through all the same)')
                :format((M.Now() - h.since) / 1000.0)
            or (cfg().shut and api() ~= nil and 'its own entry was not shut for them yet (faster than a scan, or '
                .. 'farther than METRES at the last one)' or 'the game\'s own entry is not shut on this server')))
end

--- One scan: every player on foot against every aircraft in their bucket.
-- @param ids integer[] the players
-- @param hulls table[] `{ id, at, bucket }` (server/main.lua's `aircraftNow`)
-- @param bodyOf function(playerId) -> `{ x, y, z }`, bucket
-- @param seatOf function(playerId) -> seat or nil
function N.Observe(ids, hulls, bodyOf, seatOf)
    local settings = cfg()
    scans = scans + 1
    local present = {}
    for _, hull in ipairs(hulls) do present[M.KeyOf(hull.id)] = hull end
    -- A hull that is gone took every exception with it.
    for key, byPlayer in pairs(holds) do
        if present[key] == nil then
            for playerId in pairs(byPlayer) do
                counts.released = counts.released + 1
                Open77.log.info(('the game\'s own entry to aircraft %s: player %d\'s hold let go (the aircraft is gone)')
                    :format(key, playerId))
            end
            holds[key] = nil
        end
    end
    local connected = {}
    for _, playerId in ipairs(ids) do connected[playerId] = true end
    for key, byPlayer in pairs(holds) do
        for playerId in pairs(byPlayer) do
            if not connected[playerId] then
                forget(key, playerId)
                counts.released = counts.released + 1
                Open77.log.info(('the game\'s own entry to aircraft %s: player %d\'s hold let go (they left the server)')
                    :format(key, playerId))
            end
        end
    end
    for playerId, card in pairs(carded) do
        if not connected[playerId] or M.Now() - card.at > 10000 then carded[playerId] = nil end
    end
    if not settings.shut then
        -- Switched off since the last scan: every hold comes off.
        for key, byPlayer in pairs(holds) do
            for playerId in pairs(byPlayer) do release(key, playerId, 'NATIVE_ENTRY.SHUT is off') end
        end
        return
    end
    local vehicles = api()
    if vehicles == nil then
        once('noapi', 'warn', 'no Open77.vehicles.setLockedForPlayer on this host: the game\'s own entry to an aircraft '
            .. 'cannot be shut -- F at a door may seat a player without the step')
        return
    end
    local check = scans % settings.checkEvery == 0
    local keys = {}
    for i, hull in ipairs(hulls) do keys[i] = M.KeyOf(hull.id) end
    for n, playerId in ipairs(ids) do
        -- THE HOST'S BUDGET: a resume of 10 000 instructions is killed on a
        -- loaded host (shared/core.lua, `M.Breathe`); every eight players
        -- against every aircraft, the rest in the next resume.
        if n % 8 == 0 then M.Breathe() end
        local seated = seatOf(playerId) ~= nil
        local body, bucket = nil, 0
        if not seated then body, bucket = bodyOf(playerId) end
        for i, hull in ipairs(hulls) do
            local key = keys[i]
            local h = holdOf(key, playerId)
            local metres = nil
            if body ~= nil and hull.bucket == bucket then
                local dx, dy, dz = body.x - hull.at.x, body.y - hull.at.y, body.z - hull.at.z
                metres = math.sqrt(dx * dx + dy * dy + dz * dz)
            end
            if h == nil then
                if metres ~= nil and metres <= settings.metres then hold(vehicles, hull, playerId, metres) end
            elseif seated then
                release(key, playerId, 'seated')
            elseif metres == nil then
                release(key, playerId, 'in another bucket, or no position')
            elseif metres > settings.release then
                release(key, playerId, ('%.1f m away'):format(metres))
            elseif check then
                local read, now = pcall(vehicles.isLockedForPlayer, hull.id, playerId)
                if read and now == false then
                    -- Taken away by another resource: what the player is told
                    -- now is theirs -- an exception of their own when it differs
                    -- from the canonical bit, else none (every exception revoked).
                    local readCanon, canonical = pcall(vehicles.isLocked, hull.id)
                    h.before = false
                    h.excepted = not (readCanon and canonical == false)
                    local set, ok = pcall(vehicles.setLockedForPlayer, hull.id, playerId, true)
                    counts.reasserted = counts.reasserted + 1
                    Open77.log.info(('the game\'s own entry to aircraft %s: player %d\'s hold was taken away by '
                        .. 'another resource (%s) -- shut again%s'):format(key, playerId,
                            h.excepted and 'an exception of their own: unlocked' or 'every exception revoked',
                            (set and ok == true) and '' or ' (refused)'))
                end
            end
        end
    end
end

--- Every hold comes off (the resource stops).
function N.Stop()
    local n = 0
    for key, byPlayer in pairs(holds) do
        for playerId in pairs(byPlayer) do
            release(key, playerId, 'the resource stopped')
            n = n + 1
        end
    end
    holds, carded = {}, {}
    return n
end

--- For `/avdoor.status` and the suite.
function N.Status()
    local held = 0
    for _, byPlayer in pairs(holds) do for _ in pairs(byPlayer) do held = held + 1 end end
    return { holding = held, held = counts.held, released = counts.released, reasserted = counts.reasserted,
        failed = counts.failed, gameEntries = counts.gameEntries, gameEntriesHeld = counts.gameEntriesHeld }
end
