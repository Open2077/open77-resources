-- =============================================================================
-- open77_avdoor -- server/snap.lua
-- =============================================================================
-- THE PAD SNAP (1.7.0): an AV that comes down over one of the game's own AV
-- pads is taken over, glided to the pad's centre, turned to the pad's heading
-- and set down on its gear there; the pilot has it back once it stands.
--
-- THE PADS. `server/padlist.lua` is every AV pad the world sectors of
-- Cyberpunk 2077 2.5 hold (scripts/avpads: 20 315 sectors read): the standard
-- pad's markings, the megabuilding pad module's deck, Militech's and the
-- game's own AV landing areas, a pad known only by its distant stand-in, the
-- lights its builders named after a pad and the quest scenes that land an AV
-- there -- each with its centre, deck height, heading, half width and how far
-- the list may be trusted (`conf`). They are put in a 256 m grid at start.
--
-- CAUGHT, NOT GRABBED. Every scan (`M.Scan`, `SCAN_MS`) each AV with a pilot
-- -- its driver, whoever sits in its pilot seat, else (1.7.1) the seated player
-- whose game simulates it: the Open77 client flies an AV from a back seat too
-- ("seated 2:seat_back_left", Staging, 2026-10-29: never caught, and nothing
-- said why) -- is measured against the pads under it: within `HEIGHT_METRES` over a deck,
-- within its half width plus `MARGIN_METRES` of its centre, slower than
-- `MAX_SPEED` across and not climbing -- `LOOKS` scans in a row. One that flies
-- across a pad, or climbs away from it, is never taken; one this file set down
-- is not taken by the same pad again until it has left it by `REARM_METRES`.
--
-- MEASURED BY THE PILOT'S OWN GAME. The server has no physics world: the
-- pilot's game reads the static ground straight down from where the hull
-- flies, at the pad's centre and under each gear foot as the hull will stand
-- (`SNAP_MEASURE` / `SNAP_GROUND`). The deck must be where the list says
-- (`SURFACE_METRES` by confidence) and flat under the gear (`FLAT_METRES`) --
-- a deck under a canopy, a stacked module's lower level or a pad the list put
-- a little wrong is left alone, and said.
--
-- FLOWN BY THE SERVER. `Open77.vehicles.setFrozen` discards the pilot's own
-- reports (so nobody fights the glide) and `setTransform` poses the hull every
-- `TICK_MS`, the way open77_avdrive flies its autopilot: to the centre while it
-- turns and comes down to `APPROACH_METRES` over its gear, then straight down.
-- An airframe whose gear is known (`AIRFRAMES` ... `LAND`) stands on it; any
-- other is brought to `HOVER_METRES` over the deck for its pilot to set down.
-- `HOLD_MS` later the freeze comes off. A pilot who leaves, a hull that goes,
-- a pose the host refuses or `MAX_MS` end it at once, the freeze off.
--
-- Every catch, measure, refusal, phase and end is a line in the server log,
-- with the pad's id (`avdoor.pads` lists them) and the numbers -- and (1.7.1)
-- an AV with somebody aboard over a pad that is not taken says why, once a
-- reason a pad: nobody flies it, too fast across, climbing, frozen, already
-- standing there.
--
-- WITH SOMEBODY ABOARD, DOCKED UNDER A DIP (1.8.3, `PAD_SNAP.ABOARD`): every
-- pose takes the flight from the pilot's game and the game claims it back, so
-- a glide the server flies flickers the pilot's view from start to end
-- (Staging, 2026-10-30); 1.8.2 left such an AV to its pilot and the pad no
-- longer snapped it. Now (`'dock'`, the default) the measure is the same, then
-- the screens of everybody aboard dip to black, the hull is set on its gear on
-- the deck -- centred, turned -- in ONE move under the black, and the image
-- comes back with it standing there (`Snap.Dip`, `dock`). `true` glides it in
-- view; `false` leaves it to its pilot.
-- =============================================================================

local M = AvDoor

M.Snap = {}
local Snap = M.Snap

local CELL = 256.0

-- The pads, by id, and the grid that finds them: `grid[cx .. ':' .. cy]` = { pad, ... }.
local pads, padList, grid = {}, {}, {}
-- Per hull key: how many scans in a row it was caught, and over which pad.
local caught = {}
-- Per hull key: the last scan's sample `{ t, x, y, z }`, for the climb and the speed.
local lastAt = {}
-- Snaps in flight, by hull key.
local runs = {}
-- Hulls this file set down (or gave up on), by key: `{ pad, until? }` -- not
-- taken by that pad again until they have left it by `REARM_METRES`.
local cooled = {}
-- What happened, for the status line and the console.
local counts = { caught = 0, measured = 0, refused = 0, landed = 0, hovered = 0, ended = 0, poses = 0, refusedPoses = 0,
    passedBy = 0 }
-- Per hull key: the last reason said for not taking it over a pad, `{ pad, kind }`.
local whySaid = {}
local job = nil
local serial = 0
local said = {}

local function settings() return M.SnapSettings() end

local function finite(value)
    local number = tonumber(value)
    if number == nil or number ~= number or number == math.huge or number == -math.huge then return nil end
    return number
end

local function once(key, level, text)
    if said[key] then return end
    said[key] = true
    Open77.log[level](text)
end

local function flat(ax, ay, bx, by)
    local dx, dy = ax - bx, ay - by
    return math.sqrt(dx * dx + dy * dy)
end

-- ── the pads ─────────────────────────────────────────────────────────────────

local function cellOf(x, y) return math.floor(x / CELL), math.floor(y / CELL) end

--- Reads `M.PAD_ROWS` (server/padlist.lua) into the pads and their grid.
-- @return integer how many pads
function Snap.LoadPads(rows)
    pads, padList, grid = {}, {}, {}
    rows = rows or M.PAD_ROWS or {}
    local reach = 30.0 + 20.0     -- the widest half width and margin a cell must hold
    for _, row in ipairs(rows) do
        local id, kind = row[1], row[2]
        local x, y, z = finite(row[3]), finite(row[4]), finite(row[5])
        if type(id) == 'string' and x ~= nil and y ~= nil and z ~= nil then
            local pad = { id = id, kind = tostring(kind), x = x, y = y, z = z, yaw = finite(row[6]),
                half = finite(row[7]) or 6.0, sym = finite(row[8]), conf = tostring(row[9] or 'low') }
            pads[id] = pad
            padList[#padList + 1] = pad
            local x0, y0 = cellOf(x - reach, y - reach)
            local x1, y1 = cellOf(x + reach, y + reach)
            for cx = x0, x1 do
                for cy = y0, y1 do
                    local key = cx .. ':' .. cy
                    local list = grid[key]
                    if list == nil then
                        list = {}
                        grid[key] = list
                    end
                    list[#list + 1] = pad
                end
            end
        end
    end
    return #padList
end

--- The pads whose capture may hold a point (its grid cell's).
-- @return table[]
function Snap.PadsAt(x, y)
    local cx, cy = cellOf(x, y)
    return grid[cx .. ':' .. cy] or {}
end

--- The nearest pads to a point, `{ { pad, metres }, ... }`, at most `n`.
function Snap.Nearest(x, y, n)
    local out = {}
    for _, pad in ipairs(padList) do
        out[#out + 1] = { pad = pad, metres = flat(pad.x, pad.y, x, y) }
    end
    table.sort(out, function(a, b) return a.metres < b.metres end)
    while #out > (n or 5) do table.remove(out) end
    return out
end

function Snap.Pad(id) return pads[id] end
function Snap.Count() return #padList end

--- The heading a hull lands at: the one of the pad's equal headings
--- (`sym` apart) nearest its own; its own on a pad with no heading.
-- @param pad table
-- @param yaw number the hull's
-- @return number
function Snap.Heading(pad, yaw)
    yaw = finite(yaw) or 0.0
    if pad.yaw == nil then return yaw % 360.0 end
    local step = pad.sym ~= nil and pad.sym > 0 and pad.sym or 360.0
    local best, bestOff = pad.yaw % 360.0, nil
    local k = 0
    while k * step < 360.0 - 1e-6 do
        local candidate = (pad.yaw + k * step) % 360.0
        local off = M.YawApart(candidate, yaw) or 180.0
        if bestOff == nil or off < bestOff then best, bestOff = candidate, off end
        k = k + 1
    end
    return best
end

-- ── the hull ─────────────────────────────────────────────────────────────────

local function api() return Open77.vehicles end

local function snapshotOf(id)
    local vehicles = api()
    if type(vehicles) ~= 'table' or type(vehicles.get) ~= 'function' then return nil end
    local read, snapshot = pcall(vehicles.get, id)
    if not read or type(snapshot) ~= 'table' then return nil end
    return snapshot
end

--- Who flies the hull, and how this server knows: the platform's driver, else
--- whoever sits in the airframe's pilot seat (not leaving), else (1.7.1) the
--- player whose game simulates it (`physicsOwner`) seated in any seat, else
--- the platform's own controller of it (`Open77.vehicles.owner(id).driver`:
--- "any occupant of an AV"), seated.
-- @param snapshot table the hull's snapshot
-- @param id any the hull, for the platform's read
-- @return integer|nil the pilot
-- @return string|nil how
local function pilotOf(snapshot, id)
    local driver = tonumber(snapshot.driverPlayerId)
    if driver ~= nil and driver > 0 then return driver, 'the driver' end
    local owner = tonumber(snapshot.physicsOwner)
    local seats = {}
    for _, occupant in ipairs(type(snapshot.occupants) == 'table' and snapshot.occupants or {}) do
        if type(occupant) == 'table' and occupant.exiting ~= true then
            local player, seat = tonumber(occupant.playerId), M.SeatName(occupant.seat)
            if seat == 'seat_front_left' then return player, 'in the pilot seat' end
            if player ~= nil then seats[player] = seat end
        end
    end
    if owner ~= nil and owner > 0 and seats[owner] ~= nil then
        return owner, ('flying it from %s'):format(tostring(seats[owner]))
    end
    local vehicles = api()
    if id ~= nil and next(seats) ~= nil and type(vehicles) == 'table' and type(vehicles.owner) == 'function' then
        local read, info = pcall(vehicles.owner, id)
        if read and type(info) == 'table' then
            local controller = tonumber(info.driver)
            if controller ~= nil and seats[controller] ~= nil then
                return controller, ('its controller from %s (the platform\'s word)'):format(tostring(seats[controller]))
            end
            local leased = tonumber(info.physicsOwner or info.authorityPlayerId)
            if leased ~= nil and seats[leased] ~= nil then
                return leased, ('flying it from %s (the platform\'s lease)'):format(tostring(seats[leased]))
            end
        end
    end
    return nil, nil
end
Snap.PilotOf = pilotOf

--- Who is aboard, for a line: `1:seat_back_left, 3:seat_front_right`, or nil.
local function aboardText(snapshot)
    local parts = {}
    for _, occupant in ipairs(type(snapshot.occupants) == 'table' and snapshot.occupants or {}) do
        if type(occupant) == 'table' and occupant.exiting ~= true then
            parts[#parts + 1] = ('%s:%s'):format(tostring(occupant.playerId), tostring(M.SeatName(occupant.seat)))
        end
    end
    return #parts > 0 and table.concat(parts, ', ') or nil
end

--- Why a hull over a pad is not taken, said once a reason a pad (1.7.1).
local function passedBy(key, over, why, kind)
    local last = whySaid[key]
    if last ~= nil and last.pad == over.pad.id and last.kind == kind then return end
    whySaid[key] = { pad = over.pad.id, kind = kind }
    counts.passedBy = counts.passedBy + 1
    Open77.log.info(('pad snap: aircraft %s over pad %s (%s, %s: %.1f m from its centre, %.1f m over its deck) is not '
        .. 'taken: %s'):format(key, over.pad.id, over.pad.kind, over.pad.conf, over.metres, over.height, why))
end

local function seatedIn(snapshot, playerId)
    for _, occupant in ipairs(type(snapshot.occupants) == 'table' and snapshot.occupants or {}) do
        if type(occupant) == 'table' and tonumber(occupant.playerId) == playerId and occupant.exiting ~= true then
            return true
        end
    end
    return false
end

local function frozenOf(snapshot, id)
    if M.FrozenOf ~= nil then return M.FrozenOf(snapshot, id) end
    return snapshot.frozen == true
end

local function yawOf(snapshot)
    return finite(snapshot.yaw) or finite(snapshot.heading) or 0.0
end

local function flies(record, cfg)
    if type(record) ~= 'string' then return false end
    return M.IsAircraft(record, cfg.records)
end

local function tellPilot(playerId, body)
    if playerId == nil then return end
    pcall(TriggerClientEvent, M.Event.SNAP, playerId, body)
end

-- ── catching ─────────────────────────────────────────────────────────────────

--- The pad a hull is over, caught as this scan sees it, or nil and why not
--- (for the console).
-- @return table|nil `{ pad, metres, height }`
-- @return string|nil why not
function Snap.Over(x, y, z, cfg)
    local best = nil
    for _, pad in ipairs(Snap.PadsAt(x, y)) do
        local metres = flat(x, y, pad.x, pad.y)
        local height = z - pad.z
        if metres <= pad.half + cfg.margin and height >= -0.5 and height <= cfg.height then
            if best == nil or metres < best.metres - 0.01
                or (math.abs(metres - best.metres) <= 0.01 and height < best.height) then
                best = { pad = pad, metres = metres, height = height }
            end
        end
    end
    if best == nil then return nil, 'over no pad' end
    return best
end

local function cool(key, pad, why)
    cooled[key] = { pad = pad.id, why = why, at = M.Now() }
end

--- Whether a cooled hull may be taken again: it has left its pad's capture
--- by `REARM_METRES` (across, or up).
local function rearmed(key, x, y, z, cfg)
    local c = cooled[key]
    if c == nil then return true end
    local pad = pads[c.pad]
    if pad == nil then
        cooled[key] = nil
        return true
    end
    local metres = flat(x, y, pad.x, pad.y)
    if metres > pad.half + cfg.margin + cfg.rearm or z - pad.z > cfg.height + cfg.rearm then
        cooled[key] = nil
        Open77.log.info(('pad snap: aircraft %s has left pad %s (%.1f m across, %.1f m up): it may be taken again')
            :format(key, pad.id, metres, z - pad.z))
        return true
    end
    return false
end

--- One scan's aircraft (`M.Scan`): each AV with a pilot over a pad, coming
--- down or hovering, counted; `LOOKS` in a row and it is asked to be measured.
-- @param hulls table[] `{ id, at, bucket, entry }`
-- @param now number|nil
-- @return integer how many snaps began this scan
function Snap.Observe(hulls, now)
    local cfg = settings()
    if cfg.off or #padList == 0 or type(hulls) ~= 'table' then return 0 end
    now = now or M.Now()
    local began, present = 0, {}
    for _, hull in ipairs(hulls) do
        local key = M.KeyOf(hull.id)
        present[key] = true
        local entry = type(hull.entry) == 'table' and hull.entry or nil
        local at = hull.at
        local was = lastAt[key]
        lastAt[key] = at ~= nil and { t = now, x = at.x, y = at.y, z = at.z } or nil
        if runs[key] == nil and at ~= nil and entry ~= nil and flies(entry.record, cfg)
            and rearmed(key, at.x, at.y, at.z, cfg) then
            local over = Snap.Over(at.x, at.y, at.z, cfg)
            local pilot, how = nil, nil
            if over ~= nil then pilot, how = pilotOf(entry, hull.id) end
            local aboard = over ~= nil and aboardText(entry) or nil
            local ok, why, kind = over ~= nil and pilot ~= nil, nil, nil
            -- Somebody aboard and nobody flying it: said. An empty hull parked
            -- on a pad is the usual thing, and says nothing.
            if over ~= nil and pilot == nil and aboard ~= nil then
                why, kind = ('nobody flies it (aboard: %s; no driver, nobody in the pilot seat, and no one seated '
                    .. 'simulates it)'):format(aboard), 'pilot'
            end
            if ok and frozenOf(entry, hull.id) then ok, why, kind = false, 'frozen by a resource', 'frozen' end
            -- Somebody flies it and `PAD_SNAP.ABOARD = false`: left to them.
            if ok and not cfg.aboard then
                ok, why, kind = false, ('player %d flies it (%s) and PAD_SNAP.ABOARD is false: it is theirs to land '
                    .. '(\'dock\' docks it under a short dip, true glides it in view)'):format(pilot, tostring(how)),
                    'aboard'
            end
            local speed, climb = nil, nil
            if ok and was ~= nil and now > was.t then
                local dt = (now - was.t) / 1000.0
                speed = flat(at.x, at.y, was.x, was.y) / dt
                climb = (at.z - was.z) / dt
            end
            local reported = finite(entry.speed)
            if reported ~= nil and (speed == nil or reported > speed) then speed = reported end
            if ok and speed == nil then ok, why, kind = false, 'its motion is not known yet', 'motion' end
            if ok and speed > cfg.maxSpeed then
                ok, why, kind = false, ('%.1f m/s across (taken under %.1f)'):format(speed, cfg.maxSpeed), 'across'
            end
            if ok and climb ~= nil and climb > cfg.climbMax then
                ok, why, kind = false, ('climbing %.1f m/s'):format(climb), 'climbing'
            end
            -- Already standing there, centred and turned: nothing to do.
            if ok then
                local land = M.AirframeLand(entry.record)
                local rest = (land ~= nil and land.height or cfg.hover) + 0.7
                local heading = Snap.Heading(over.pad, yawOf(entry))
                if over.metres <= 1.0 and over.height <= rest and (M.YawApart(heading, yawOf(entry)) or 180) <= 5.0 then
                    ok, why, kind = false, 'already on it, centred and turned', 'already'
                    cool(key, over.pad, 'already on it')
                end
            end
            if ok then
                local c = caught[key]
                if c == nil or c.pad ~= over.pad.id then
                    c = { pad = over.pad.id, looks = 0, since = now }
                    caught[key] = c
                end
                c.looks = c.looks + 1
                if c.looks == 1 then
                    Open77.log.info(('pad snap: aircraft %s (%s, pilot %d %s) over pad %s (%s, %s): %.1f m from its '
                        .. 'centre, %.1f m over its deck, %.1f m/s across, %s -- taken after %d look(s) in a row')
                        :format(key, tostring(entry.record), pilot, tostring(how), over.pad.id, over.pad.kind,
                            over.pad.conf, over.metres, over.height, speed or 0,
                            climb ~= nil and ('%+.1f m/s up'):format(climb) or 'climb unknown', cfg.looks))
                end
                if c.looks >= cfg.looks then
                    caught[key] = nil
                    local ran, started = pcall(Snap.Engage, hull.id, entry, over, pilot, speed, climb, now, how)
                    if not ran then
                        Open77.log.error('pad snap: the catch failed: ' .. tostring(started))
                    elseif started then
                        began = began + 1
                    end
                end
            else
                -- Why not, once a reason a pad (the first look's missing motion
                -- is no reason: the next scan has it).
                if over ~= nil and why ~= nil and kind ~= 'motion' and (aboard ~= nil or caught[key] ~= nil) then
                    passedBy(key, over, why, kind)
                end
                caught[key] = nil
            end
            if over == nil then whySaid[key] = nil end
        end
    end
    for key in pairs(lastAt) do if not present[key] then lastAt[key] = nil end end
    for key in pairs(caught) do if not present[key] then caught[key] = nil end end
    for key in pairs(cooled) do if not present[key] then cooled[key] = nil end end
    for key in pairs(whySaid) do if not present[key] then whySaid[key] = nil end end
    return began
end

-- ── the measure ──────────────────────────────────────────────────────────────

--- Asks the pilot's game to measure the deck, straight down from the hull.
-- @return boolean whether it was asked
function Snap.Engage(id, entry, over, pilot, speed, climb, now, how)
    local cfg = settings()
    local key = M.KeyOf(id)
    local pad = over.pad
    local yaw = yawOf(entry)
    local heading = Snap.Heading(pad, yaw)
    local land = M.AirframeLand(entry.record)
    local points = { { x = pad.x, y = pad.y } }
    if land ~= nil then
        local r = math.rad(heading)
        local feet = M.GearPoints({ x = pad.x, y = pad.y }, { x = -math.sin(r), y = math.cos(r) }, land)
        for _, foot in ipairs(feet or {}) do points[#points + 1] = { x = foot.x, y = foot.y } end
    end
    serial = serial + 1
    local token = ('%s#%d'):format(key, serial)
    local hullZ = finite(entry.z) or (pad.z + over.height)
    runs[key] = {
        key = key, id = id, pad = pad, pilot = pilot, record = entry.record, land = land, token = token,
        phase = 'measure', askedAt = now, began = now, heading = heading, startYaw = yaw, points = points,
        from = { x = finite(entry.x) or pad.x, y = finite(entry.y) or pad.y, z = hullZ },
        poses = 0, refusedPoses = 0,
    }
    counts.caught = counts.caught + 1
    local sent, failure = pcall(TriggerClientEvent, M.Event.SNAP_MEASURE, pilot, {
        token = token, id = key, pad = pad.id, points = points, fromZ = hullZ - 0.3,
    })
    Open77.log.info(('pad snap: aircraft %s (%s, pilot %d) caught over pad %s (%s, %s: %.1f m from its centre, %.1f m '
        .. 'over its deck, %s, %s): its deck asked of the pilot\'s game (%s) at %d point(s)%s')
        :format(key, tostring(entry.record), pilot, pad.id, pad.kind, pad.conf, over.metres, over.height,
            speed ~= nil and ('%.1f m/s across'):format(speed) or 'speed unknown',
            climb ~= nil and ('%+.1f m/s up'):format(climb) or 'climb unknown', tostring(how or 'the pilot'), #points,
            sent and '' or (' -- not sent: ' .. tostring(failure))))
    if not sent then
        runs[key] = nil
        cool(key, pad, 'the measure could not be asked')
        return false
    end
    return true
end

local function refuse(run, why)
    counts.refused = counts.refused + 1
    runs[run.key] = nil
    cool(run.key, run.pad, why)
    Open77.log.info(('pad snap: aircraft %s is left to its pilot over pad %s (%s, %s): %s')
        :format(run.key, run.pad.id, run.pad.kind, run.pad.conf, why))
end

--- The pilot's game's measure: judged, and the glide begun or refused.
-- @param playerId integer
-- @param payload table `{ token, id, pad, grounds, fps }`
-- @return string 'flying' | 'refused' | 'ignored'
function Snap.Ground(playerId, payload)
    if type(payload) ~= 'table' or payload.id == nil then return 'ignored' end
    local key = M.KeyOf(payload.id)
    local run = runs[key]
    if run == nil or run.phase ~= 'measure' or run.token ~= payload.token or run.pilot ~= playerId then
        return 'ignored'
    end
    local cfg = settings()
    counts.measured = counts.measured + 1
    local grounds = type(payload.grounds) == 'table' and payload.grounds or {}
    local values = {}
    for index = 1, #run.points do
        values[index] = grounds[index] ~= false and finite(grounds[index]) or nil
    end
    local text = {}
    for index = 1, #run.points do text[index] = values[index] ~= nil and ('%.2f'):format(values[index]) or 'none' end
    local measured = table.concat(text, ', ')
    local centre = values[1]
    if centre == nil then
        refuse(run, ('the pilot\'s game found no ground under the pad\'s centre (%s)'):format(measured))
        return 'refused'
    end
    local tolerance = cfg.surface[run.pad.conf] or cfg.surface.low
    local off = centre - run.pad.z
    if math.abs(off) > tolerance then
        refuse(run, ('the deck under its centre is at %.2f, %.2f m from where the pad list has it (%.2f; %.1f m at '
            .. 'most for a %s pad): another floor, a canopy, or not a pad there (%s)'):format(centre, off, run.pad.z,
            tolerance, run.pad.conf, measured))
        return 'refused'
    end
    local snapshot = snapshotOf(run.id)
    if snapshot == nil then
        refuse(run, 'the hull is gone')
        return 'refused'
    end
    if not seatedIn(snapshot, run.pilot) then
        refuse(run, ('pilot %d left the seat'):format(run.pilot))
        return 'refused'
    end
    if frozenOf(snapshot, run.id) then
        refuse(run, 'frozen by a resource since it was caught')
        return 'refused'
    end
    local landZ, how, highest, spread = nil, nil, nil, 0.0
    if run.land ~= nil and #run.points > 1 then
        local lowest = nil
        for index = 2, #run.points do
            local z = values[index]
            if z == nil then
                refuse(run, ('no ground under gear foot %d where the hull would stand (%s)'):format(index - 1, measured))
                return 'refused'
            end
            highest = highest == nil and z or math.max(highest, z)
            lowest = lowest == nil and z or math.min(lowest, z)
        end
        spread = highest - lowest
        if spread > cfg.flat then
            refuse(run, ('the deck is not flat under its gear: its feet\'s ground %.2f m apart (%.2f at most; %s)')
                :format(spread, cfg.flat, measured))
            return 'refused'
        end
        landZ, how = highest + run.land.height, 'on its gear'
    else
        landZ, how = centre + cfg.hover, ('%.1f m over the deck (its gear is not known: its pilot sets it down)')
            :format(cfg.hover)
    end
    local x, y, z = finite(snapshot.x), finite(snapshot.y), finite(snapshot.z)
    if x == nil or y == nil or z == nil then
        refuse(run, 'the server has no position for it')
        return 'refused'
    end
    if z < landZ - 0.3 then
        refuse(run, ('it is already under the height it would be set down at (%.2f against %.2f)'):format(z, landZ))
        return 'refused'
    end
    local vehicles = api()
    if type(vehicles) ~= 'table' or type(vehicles.setFrozen) ~= 'function' or type(vehicles.setTransform) ~= 'function' then
        once('snap:natives', 'warn', 'pad snap: no Open77.vehicles.setFrozen / setTransform on this host: no snap')
        refuse(run, 'no setFrozen / setTransform on this host')
        return 'refused'
    end
    run.landZ, run.how, run.centre, run.spread = landZ, how, centre, spread
    run.target = { x = run.pad.x, y = run.pad.y, z = landZ, yaw = run.heading }
    if cfg.aboardMode == 'dock' then
        return Snap.Dip(run, snapshot, { x = x, y = y, z = z, yaw = yawOf(snapshot) }, off, measured, cfg)
    end
    local called, frozen, reason = pcall(vehicles.setFrozen, run.id, true)
    if not called or frozen ~= true then
        refuse(run, 'setFrozen refused: ' .. tostring(called and (reason or frozen) or frozen))
        return 'refused'
    end
    local now = M.Now()
    run.phase, run.frozenAt, run.lastTick = 'glide', now, now
    run.pose = { x = x, y = y, z = z, yaw = yawOf(snapshot) }
    run.landZ, run.approachZ, run.how, run.centre, run.spread = landZ, landZ + cfg.approach, how, centre, spread
    run.target = { x = run.pad.x, y = run.pad.y, z = landZ, yaw = run.heading }
    Open77.log.info(('pad snap: aircraft %s takes pad %s (%s, %s): the deck at %.2f (the list %.2f, %+.2f m; under '
        .. 'its gear %s), set down %s at %.2f, heading %.0f (from %.0f); from %.1f, %.1f, %.1f -- %.1f m across, '
        .. '%.1f m down, %.0f deg to turn; frozen, posed every %d ms'):format(run.key, run.pad.id, run.pad.kind,
        run.pad.conf, centre, run.pad.z, off, measured, how, landZ, run.heading, run.pose.yaw, x, y, z,
        flat(x, y, run.pad.x, run.pad.y), z - landZ, M.YawApart(run.heading, run.pose.yaw) or 0, cfg.tickMs))
    tellPilot(run.pilot, { state = 'on', pad = run.pad.id, kind = run.pad.kind })
    return 'flying'
end

-- ── the dock (1.8.3) ─────────────────────────────────────────────────────────

--- Everybody aboard a hull (not those stepping out), by player id.
local function crewOf(snapshot)
    local crew = {}
    for _, occupant in ipairs(type(snapshot.occupants) == 'table' and snapshot.occupants or {}) do
        local player = type(occupant) == 'table' and occupant.exiting ~= true and tonumber(occupant.playerId) or nil
        if player ~= nil then crew[player] = M.SeatName(occupant.seat) or tostring(occupant.seat) end
    end
    return crew
end

--- Tells the games of a dock's crew something about the dip; `pilot` says to
--- each whether it is the one that answers.
local function toCrew(run, body)
    for player in pairs(run.crew or {}) do
        local message = {}
        for k, v in pairs(body) do message[k] = v end
        message.pilot = player == run.pilot
        pcall(TriggerClientEvent, M.Event.SNAP_DIP, player, message)
    end
end

--- The image back for everybody aboard, once, whatever ended the dock.
local function dipIn(run, why)
    if not run.dipped or run.dipBack then return end
    run.dipBack = true
    local cfg = settings()
    toCrew(run, { token = run.token, id = run.key, pad = run.pad.id, state = 'in', ms = cfg.dock.back,
        why = tostring(why):sub(1, 80) })
end

--- THE DOCK, ASKED: the measure held, so the screens of everybody aboard dip to
--- black; the move waits for the pilot's game to say its screen is covered
--- (`Snap.DipWord`), or `DOCK.WAIT_MS` (`Snap.Tend`).
-- @return string 'docking'
function Snap.Dip(run, snapshot, pose, off, measured, cfg)
    local now = M.Now()
    run.phase, run.dipAt, run.dipped, run.pose = 'dip', now, true, pose
    run.crew = crewOf(snapshot)
    run.crew[run.pilot] = run.crew[run.pilot] or 'the pilot'
    local names = {}
    for player, seat in pairs(run.crew) do names[#names + 1] = ('%d:%s'):format(player, tostring(seat)) end
    table.sort(names)
    toCrew(run, { token = run.token, id = run.key, pad = run.pad.id, state = 'out', ms = cfg.dock.out,
        timeoutMs = math.max(1000, cfg.dock.out + cfg.dock.wait + cfg.dock.hold + cfg.dock.back + 4000) })
    Open77.log.info(('pad snap: aircraft %s takes pad %s (%s, %s) DOCKED: the deck at %.2f (the list %.2f, %+.2f m; under '
        .. 'its gear %s), set down %s at %.2f, heading %.0f (from %.0f); from %.1f, %.1f, %.1f -- %.1f m across, %.1f m '
        .. 'down, %.0f deg to turn -- in one move once the screens of %s are black (%d ms dip, %d ms at most)')
        :format(run.key, run.pad.id, run.pad.kind, run.pad.conf, run.centre, run.pad.z, off, measured, run.how, run.landZ,
            run.heading, pose.yaw, pose.x, pose.y, pose.z, flat(pose.x, pose.y, run.pad.x, run.pad.y), pose.z - run.landZ,
            M.YawApart(run.heading, pose.yaw) or 0, table.concat(names, ', '), cfg.dock.out, cfg.dock.wait))
    tellPilot(run.pilot, { state = 'on', pad = run.pad.id, kind = run.pad.kind })
    return 'docking'
end

--- THE MOVE: frozen, one pose onto the deck, held; `Snap.Tend` gives it back.
local function dock(run, now, why)
    local cfg = settings()
    local snapshot = snapshotOf(run.id)
    if snapshot == nil then return Snap.Finish(run, 'the hull is gone') end
    if not seatedIn(snapshot, run.pilot) then return Snap.Finish(run, ('pilot %d left the seat'):format(run.pilot)) end
    if frozenOf(snapshot, run.id) then return Snap.Finish(run, 'frozen by a resource since it was caught') end
    local vehicles = api()
    local called, frozen, reason = pcall(vehicles.setFrozen, run.id, true)
    if not called or frozen ~= true then
        return Snap.Finish(run, 'setFrozen refused: ' .. tostring(called and (reason or frozen) or frozen))
    end
    run.frozenAt = now
    local target = run.target
    local x, y, z = finite(snapshot.x) or run.pose.x, finite(snapshot.y) or run.pose.y, finite(snapshot.z) or run.pose.z
    local moved, failure
    called, moved, failure = pcall(vehicles.setTransform, run.id, { x = target.x, y = target.y, z = target.z,
        yaw = target.yaw % 360.0 })
    if not called or moved ~= true then
        run.refusedPoses = run.refusedPoses + 1
        counts.refusedPoses = counts.refusedPoses + 1
        return Snap.Finish(run, 'setTransform refused: ' .. tostring(called and (failure or moved) or moved))
    end
    run.poses = run.poses + 1
    counts.poses = counts.poses + 1
    run.pose = { x = target.x, y = target.y, z = target.z, yaw = target.yaw % 360.0 }
    run.phase, run.holdUntil = 'docked', now + cfg.dock.hold
    run.landed = run.land ~= nil and 'gear' or 'hover'
    Open77.log.info(('pad snap: aircraft %s docked on pad %s -- %s %.2fs after the dip was asked: from %.1f, %.1f, %.1f to '
        .. '%.1f, %.1f, %.2f (%.1f m), heading %.0f, frozen; the image back in %d ms')
        :format(run.key, run.pad.id, why, (now - run.dipAt) / 1000.0, x, y, z, target.x, target.y, target.z,
            math.sqrt((x - target.x) ^ 2 + (y - target.y) ^ 2 + (z - target.z) ^ 2), target.yaw, cfg.dock.hold))
end

--- The pilot's game's word on the dip (`SNAP_DIP_READY`): its screen black,
--- or the dip refused -- the move either way, said.
-- @return string 'docked' | 'ignored'
function Snap.DipWord(playerId, payload)
    if type(payload) ~= 'table' or payload.id == nil then return 'ignored' end
    local run = runs[M.KeyOf(payload.id)]
    if run == nil or run.phase ~= 'dip' or run.token ~= payload.token or run.pilot ~= playerId then return 'ignored' end
    local now = M.Now()
    if payload.state == 'black' then
        dock(run, now, ('the pilot\'s screen is black (%s ms by its clock)'):format(tostring(finite(payload.ms)
            and math.floor(finite(payload.ms)) or '?')))
    else
        dock(run, now, ('the pilot\'s game could not dip (%s): moved in view'):format(tostring(payload.reason):sub(1, 80)))
    end
    return 'docked'
end

-- ── the glide ────────────────────────────────────────────────────────────────

local function release(run)
    local vehicles = api()
    if type(vehicles) ~= 'table' or type(vehicles.setFrozen) ~= 'function' then return 'no setFrozen' end
    local called, ok, reason = pcall(vehicles.setFrozen, run.id, false)
    if not called or ok ~= true then return 'setFrozen(false) refused: ' .. tostring(called and (reason or ok) or ok) end
    return nil
end

--- Ends a snap: the freeze off (if it was on), one line, the hull cooled.
function Snap.Finish(run, why, landed)
    runs[run.key] = nil
    local failure = nil
    if run.frozenAt ~= nil then failure = release(run) end
    counts.ended = counts.ended + 1
    if landed == 'gear' then counts.landed = counts.landed + 1 elseif landed == 'hover' then counts.hovered = counts.hovered + 1 end
    cool(run.key, run.pad, why)
    local now = M.Now()
    local line = ('pad snap: aircraft %s on pad %s: %s -- %.1fs after it was caught, %.1fs flown, %d pose(s)%s; the '
        .. 'freeze %s'):format(run.key, run.pad.id, why, (now - run.began) / 1000.0,
        run.frozenAt ~= nil and (now - run.frozenAt) / 1000.0 or 0.0, run.poses,
        run.refusedPoses > 0 and (', %d refused'):format(run.refusedPoses) or '',
        run.frozenAt == nil and 'never came on' or (failure == nil and 'is off: the pilot has it' or ('could not come off: ' .. failure)))
    if landed ~= nil and failure == nil then Open77.log.info(line) else Open77.log.warn(line) end
    -- A dock's screens come back whatever ended it (1.8.3).
    dipIn(run, why)
    tellPilot(run.pilot, { state = landed ~= nil and 'landed' or 'off', pad = run.pad.id, kind = run.pad.kind, why = why })
end

local function approach(value, target, step)
    if value < target then return math.min(target, value + step) end
    return math.max(target, value - step)
end

--- One step of one snap.
local function step(run, now, cfg)
    local snapshot = snapshotOf(run.id)
    if snapshot == nil then return Snap.Finish(run, 'the hull is gone') end
    if not seatedIn(snapshot, run.pilot) then
        return Snap.Finish(run, ('pilot %d left the seat'):format(run.pilot))
    end
    if now - (run.frozenAt or now) > cfg.maxMs then
        return Snap.Finish(run, ('not down after %.1fs'):format(cfg.maxMs / 1000.0))
    end
    if run.phase == 'hold' then
        if now >= run.holdUntil then
            return Snap.Finish(run, run.landed == 'gear' and ('set down on its gear, centred, heading %.0f'):format(run.heading)
                or ('brought to a hover over the centre, heading %.0f'):format(run.heading), run.landed)
        end
        return
    end
    local dt = math.max(0.0, math.min(0.5, (now - run.lastTick) / 1000.0))
    run.lastTick = now
    if dt <= 0 then return end
    local pose, target = run.pose, run.target
    -- Across: straight to the centre.
    local dx, dy = target.x - pose.x, target.y - pose.y
    local across = math.sqrt(dx * dx + dy * dy)
    local move = math.min(across, cfg.glide * dt)
    local x, y = pose.x, pose.y
    if across > 1e-6 then x, y = x + dx / across * move, y + dy / across * move end
    -- The turn: the short way round.
    local turn = ((target.yaw - pose.yaw + 540.0) % 360.0) - 180.0
    local yaw = pose.yaw + math.max(-cfg.turnRate * dt, math.min(cfg.turnRate * dt, turn))
    -- Down: to the approach height while it is not over the centre, then onto it.
    local centred = flat(x, y, target.x, target.y) <= 0.05 and math.abs(((target.yaw - yaw + 540.0) % 360.0) - 180.0) <= 0.5
    local floor = centred and target.z or math.max(target.z, run.approachZ)
    local z = pose.z
    if z > floor then
        local rate = (z > run.approachZ + 0.01) and cfg.descent or cfg.touchdown
        z = math.max(floor, z - rate * dt)
    end
    if centred then x, y, yaw = target.x, target.y, target.yaw end
    local vehicles = api()
    local called, moved, reason = pcall(vehicles.setTransform, run.id, { x = x, y = y, z = z, yaw = yaw % 360.0 })
    if not called or moved ~= true then
        run.refusedPoses = run.refusedPoses + 1
        counts.refusedPoses = counts.refusedPoses + 1
        return Snap.Finish(run, 'setTransform refused: ' .. tostring(called and (reason or moved) or moved))
    end
    run.poses = run.poses + 1
    counts.poses = counts.poses + 1
    run.pose = { x = x, y = y, z = z, yaw = yaw % 360.0 }
    if run.phase == 'glide' and centred then
        run.phase = 'descend'
        Open77.log.info(('pad snap: aircraft %s over the centre of pad %s, heading %.0f, %.1fs after the freeze: down %.2f m '
            .. 'to %.2f'):format(run.key, run.pad.id, run.heading, (now - run.frozenAt) / 1000.0, z - target.z, target.z))
    end
    if centred and math.abs(z - target.z) <= 0.005 then
        run.phase = 'hold'
        run.holdUntil = now + cfg.holdMs
        run.landed = run.land ~= nil and 'gear' or 'hover'
        Open77.log.info(('pad snap: aircraft %s %s on pad %s at %.2f, %.1fs after the freeze; the pilot has it in %.1fs')
            :format(run.key, run.landed == 'gear' and 'stands on its gear' or 'hovers', run.pad.id, z,
                (now - run.frozenAt) / 1000.0, cfg.holdMs / 1000.0))
    end
end

--- Every `TICK_MS`: measures that never came, and the glides.
function Snap.Tend(now)
    now = now or M.Now()
    local cfg = settings()
    for _, run in pairs(runs) do
        if run.phase == 'measure' then
            if now - run.askedAt > cfg.measureMs then
                refuse(run, ('the pilot\'s game sent no measure of the deck within %.1fs'):format(cfg.measureMs / 1000.0))
            end
        elseif run.phase == 'dip' then
            if now - run.dipAt >= cfg.dock.wait then
                local ran, failure = pcall(dock, run, now, ('no word that the pilot\'s screen is black after %d ms: moved '
                    .. 'all the same'):format(cfg.dock.wait))
                if not ran then
                    Open77.log.error('pad snap: the dock failed: ' .. tostring(failure))
                    pcall(Snap.Finish, run, 'the dock failed: ' .. tostring(failure))
                end
            end
        elseif run.phase == 'docked' then
            if now >= run.holdUntil then
                pcall(Snap.Finish, run, run.landed == 'gear' and ('docked on its gear, centred, heading %.0f'):format(
                    run.heading) or ('docked in a hover over the centre, heading %.0f'):format(run.heading), run.landed)
            end
        else
            local ran, failure = pcall(step, run, now, cfg)
            if not ran then
                Open77.log.error('pad snap: a step failed: ' .. tostring(failure))
                pcall(Snap.Finish, run, 'a step failed: ' .. tostring(failure))
            end
        end
    end
end

-- ── the rest ─────────────────────────────────────────────────────────────────

--- Ends every snap: the freezes off. On stop, and for a cancel.
function Snap.EndAll(why)
    local list = {}
    for _, run in pairs(runs) do list[#list + 1] = run end
    for _, run in ipairs(list) do pcall(Snap.Finish, run, why or 'stopped') end
end

function Snap.Cancel(id, why)
    local run = runs[M.KeyOf(id)]
    if run == nil then return false end
    Snap.Finish(run, why or 'cancelled')
    return true
end

function Snap.Forget(playerId)
    local player = tonumber(playerId)
    for _, run in pairs(runs) do
        if run.pilot == player then pcall(Snap.Finish, run, ('pilot %d left the server'):format(player)) end
    end
end

function Snap.Status()
    local flying = {}
    for key, run in pairs(runs) do
        flying[#flying + 1] = { id = key, pad = run.pad.id, phase = run.phase, pilot = run.pilot }
    end
    return { pads = #padList, flying = flying, caught = counts.caught, measured = counts.measured,
        refused = counts.refused, landed = counts.landed, hovered = counts.hovered, ended = counts.ended,
        poses = counts.poses, refusedPoses = counts.refusedPoses, passedBy = counts.passedBy or 0 }
end

--- The console's answer: the pads near a point, and the snaps in flight.
local COMPASS = { 'north', 'north-east', 'east', 'south-east', 'south', 'south-west', 'west', 'north-west' }

--- Which way a point lies from another, in the game's axes (x east, y north):
--- one of eight, or 'here' within a metre.
-- @return string
function Snap.Compass(fromX, fromY, toX, toY)
    local dx, dy = toX - fromX, toY - fromY
    if dx * dx + dy * dy < 1.0 then return 'here' end
    local bearing = math.deg(math.atan(dx, dy)) % 360.0
    return COMPASS[math.floor((bearing + 22.5) / 45.0) % 8 + 1]
end

--- The pads near a point, for `/avdoor.pads`: how far each is, which way, and
--- how high its deck stands over the asker (`z`, when known).
-- @return string
function Snap.Describe(x, y, n, z)
    local lines = {}
    local status = Snap.Status()
    lines[#lines + 1] = ('pad snap %s: %d pads; %d caught, %d measured, %d refused, %d set down on their gear, %d '
        .. 'brought to a hover, %d poses sent, %d passed by (the server log says why)'):format(
        settings().off and 'OFF' or 'on', status.pads, status.caught, status.measured, status.refused, status.landed,
        status.hovered, status.poses, status.passedBy)
    for _, f in ipairs(status.flying) do
        lines[#lines + 1] = ('  flying: aircraft %s on pad %s (%s), pilot %s'):format(f.id, f.pad, f.phase, tostring(f.pilot))
    end
    if x ~= nil and y ~= nil then
        for _, near in ipairs(Snap.Nearest(x, y, n or 5)) do
            local pad = near.pad
            local height = ''
            if finite(z) ~= nil then
                local up = pad.z - z
                height = math.abs(up) < 1.0 and ', its deck at your height'
                    or (', its deck %.0f m %s you'):format(math.abs(up), up > 0 and 'above' or 'below')
            end
            local way = Snap.Compass(x, y, pad.x, pad.y)
            lines[#lines + 1] = ('  pad %s (%s, %s): %s%s; heading %s, %.1f m half width; the deck at %.1f, %.1f, %.1f')
                :format(pad.id, pad.kind, pad.conf, way == 'here' and 'here' or ('%.0f m %s'):format(near.metres, way),
                    height, pad.yaw ~= nil and ('%.0f'):format(pad.yaw) or 'any', pad.half, pad.x, pad.y, pad.z)
        end
    end
    return table.concat(lines, '\n')
end

function Snap.Start()
    local count = Snap.LoadPads()
    local cfg = settings()
    RegisterNetEvent(M.Event.SNAP_GROUND, function(payload)
        local player = tonumber(source)
        if player == nil then return end
        if M.Cooling(player, 'snapGround', 100) then return end
        local ran, verdict = pcall(Snap.Ground, player, payload)
        if not ran then Open77.log.error('pad snap: a measure failed: ' .. tostring(verdict)) end
    end)
    RegisterNetEvent(M.Event.SNAP_DIP_READY, function(payload)
        local player = tonumber(source)
        if player == nil then return end
        if M.Cooling(player, 'snapDip', 50) then return end
        local ran, verdict = pcall(Snap.DipWord, player, payload)
        if not ran then Open77.log.error('pad snap: a dip word failed: ' .. tostring(verdict)) end
    end)
    if not cfg.off then
        job = M.Every('snap', cfg.tickMs, function() Snap.Tend() end)
    end
    Open77.log.info(('pad snap %s: %d AV pads known (server/padlist.lua); an AV coming down within %.0f m over one, '
        .. 'slower than %.0f m/s, is centred, turned and set down; posed every %d ms; %s')
        :format(cfg.off and 'OFF (PAD_SNAP = false)' or 'on', count, cfg.height, cfg.maxSpeed, cfg.tickMs,
            cfg.aboardMode == 'dock' and ('an AV somebody flies is DOCKED: the screens aboard dip to black (%d ms), one '
                .. 'move onto the deck, held %d ms, the image back (%d ms)'):format(cfg.dock.out, cfg.dock.hold,
                cfg.dock.back)
            or cfg.aboardMode == 'glide' and 'an AV somebody flies is glided down in view (PAD_SNAP.ABOARD = true: '
                .. 'their view flickers through the glide)'
            or 'an AV somebody flies is left to its pilot (PAD_SNAP.ABOARD = false)'))
end

function Snap.Stop()
    Snap.EndAll('the resource stopped')
    if job ~= nil then M.Cancel(job) end
    job = nil
end

function Snap.Reset()
    runs, caught, lastAt, cooled, said, whySaid = {}, {}, {}, {}, {}, {}
    counts = { caught = 0, measured = 0, refused = 0, landed = 0, hovered = 0, ended = 0, poses = 0, refusedPoses = 0,
        passedBy = 0 }
    serial = 0
end
