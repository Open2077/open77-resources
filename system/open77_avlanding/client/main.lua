-- =============================================================================
-- open77_avlanding -- client/main.lua
-- =============================================================================
-- "WARNING", flashing, in a ring of warning words that turns slowly, on the
-- ground under every aircraft this screen draws coming down to it
-- (shared/config.lua says what and when).
--
-- Every `LIST_MS` the aircraft within `RANGE_METRES` are listed; the nearest
-- `MAX_HULLS` are looked at every `LOOK_MS`: where this screen draws the hull
-- (`Open77.world.entityGeometry`: its origin, its heading and its loaded
-- mesh's box), the ground under the box's centre, the clearance under its
-- lowest point, how fast it comes down. In the band the sign is played there,
-- turned so that its top points the way the hull faces, laid on the ground's
-- plane (below), and moved with it; out of the band for `RETIRE_LOOKS` looks
-- it is taken away.
--
-- THE GROUND'S PLANE. The sign is 7.6 m across (its ring). Laid flat at the
-- height of the ground under its centre, it sinks into a slope, a road's
-- camber, a kerb. So the ground is sampled under its whole footprint -- the
-- centre, eight points on the ring's edge, four on the word's -- and a plane
-- fitted to the samples that are that ground: not a wall, a roof's edge or a
-- drop (further from the centre's height than a step and the steepest slope
-- allowed), not a bench (off the plane of the others). Its slope is held to
-- `MAX_TILT_DEGREES`, it is raised until no sample is above it, and the sign
-- lies on it, tilted with it, `LIFT_METRES` up. The ground is the static
-- meshes and, on a client whose rays take collision groups (Stable 156), the
-- open terrain (the Badlands): an older client's static-only ray meets no
-- ground over terrain, and draws no sign there (its log says so).
--
-- IN USE. `Open77.vehicles.nearby` names a hull and counts who is aboard (a
-- number, not a list); whether its engine runs and who owns its physics is in
-- `Open77.vehicles.get`, read with each listing; this player's own seat
-- (`getPlayerSeat`) counts too. A hull in use on the ground keeps its sign.
--
-- Every change is a line in the client log: a hull taken in (record, distance,
-- who is aboard) and let go, a record that is not an aircraft (once), why a
-- watched aircraft is not signed whenever that changes (no ground, too high,
-- hovering, parked and idle), a sign on (hull, record, clearance, ground,
-- heading, the ground's plane), a plane that changed, off (and why), which
-- ground this client's rays meet (once), a refused effect (once), a missing
-- archive (once). Every pass of the three jobs (the list, the look, the ring's
-- turn) is timed, and a minute after the start, then every five minutes, a
-- line says what each cost ("job costs over the last ...", as open77_avdoor's).
-- =============================================================================

local cfg = Open77AvLandingConfig
local RESOURCE = GetCurrentResourceName()

local L = {}
Open77AvLanding = L

-- Hulls looked at, by id as text: `{ id, record, up, handle, ringHandle,
-- lastZ, lastAt, ground, groundAt, groundX, groundY, retire, idleSince, laid,
-- yaw, word }`.
local hulls = {}
-- Set by `L.Stop`: work that breathed past a stop lays nothing.
local stopped = false
-- What has been said once.
local said = {}
-- The jobs, while the resource runs: the look, the list, the ring's turn.
local lookJob, listJob, turnJob = nil, nil, nil
-- How many words went on and off, for the status line; the ring's turns and
-- what they cost since the last health line (`turns`, `turnMs`, `turnMax`).
local counts = { on = 0, off = 0, refused = 0, turns = 0, turnMs = 0.0, turnMax = 0.0, turnRefused = 0 }
local turnSaidAt = nil
-- THE SIGN'S ARCHIVE NOT IN THIS GAME (1.4.2): every sign is the game's own
-- landing hologram (`FALLBACK_EFFECT`) from then on -- a game mounts its
-- archives once, at its start -- and no ring turns. Nil until known.
local fallbackOn = nil

local function now()
    local time = Open77.time
    if type(time) == 'table' and type(time.monotonic) == 'function' then
        local read, seconds = pcall(time.monotonic)
        if read and type(seconds) == 'number' then return math.floor(seconds * 1000.0) end
    end
    return math.floor(os.clock() * 1000.0)
end

--- The clock in fractional milliseconds, for what a pass costs.
local function clock()
    local time = Open77.time
    if type(time) == 'table' and type(time.monotonic) == 'function' then
        local read, seconds = pcall(time.monotonic)
        if read and type(seconds) == 'number' then return seconds * 1000.0 end
    end
    return os.clock() * 1000.0
end

-- THE NATIVES, TIMED (1.4.1). Every native the passes lean on (the ground's
-- rays, the hull's geometry, the effects) is called through `native`: what each
-- cost goes into the job-cost line (`every`, below), and one call of
-- `NATIVE_SLOW_MS` or more is a line at once, with the job it ran in (once a
-- minute a native). The job running now, and each job's waits in its breaths
-- this pass (by coroutine), are kept here, above everything that writes them.
L.NATIVE_SLOW_MS = 20.0
local currentJob = nil
local breathBy = {}
local nativeCosts, slowSaid = {}, {}
local monotonic = nil

local function stamp()
    if monotonic == nil then
        local time = Open77.time
        monotonic = (type(time) == 'table' and type(time.monotonic) == 'function') and time.monotonic or false
    end
    if monotonic then return monotonic() * 1000.0 end
    return clock()
end

--- `pcall(fn, ...)`, timed: the same answers (three values at most after its own).
local function native(name, fn, ...)
    if type(fn) ~= 'function' then return false, 'no ' .. tostring(name) .. ' on this client' end
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
        if spent >= L.NATIVE_SLOW_MS then
            local t = math.floor(stamp())
            if slowSaid[name] == nil or t - slowSaid[name] >= 60000 then
                slowSaid[name] = t
                Open77.log.warn(('slow native: %s took %.1f ms in one call (%s; said once a minute a native)'):format(
                    name, spent, currentJob ~= nil and ('the landing sign\'s ' .. currentJob .. ' pass')
                        or 'an event or a one-off'))
            end
        end
    end
    return ok, a, b, c
end
L.Native = native

--- What each native cost since the last job-cost line.
function L.NativeCosts() return nativeCosts end

local function once(key, level, text)
    if said[key] then return end
    said[key] = true
    Open77.log[level](text)
end

local function finite(value)
    local number = tonumber(value)
    if number == nil or number ~= number or number == math.huge or number == -math.huge then return nil end
    return number
end

local function pointFrom(value)
    if type(value) ~= 'table' then return nil end
    local x, y, z = finite(value.x or value[1]), finite(value.y or value[2]), finite(value.z or value[3])
    if x == nil or y == nil or z == nil then return nil end
    return { x = x, y = y, z = z }
end

local function number(value, low, high, fallback)
    local n = finite(value)
    if n == nil or n < low or n > high then return fallback end
    return n
end

--- The settings, each inside a band.
function L.Settings()
    local c = type(cfg) == 'table' and cfg or {}
    return {
        effect = type(c.EFFECT) == 'string' and c.EFFECT ~= '' and c.EFFECT or nil,
        -- THE RING (1.4.0): its own effect, turned under the word by `L.Turn`.
        ringEffect = type(c.RING_EFFECT) == 'string' and c.RING_EFFECT ~= '' and c.RING_EFFECT or nil,
        ringRate = number(c.RING_DEGREES_PER_SECOND, -360.0, 360.0, 20.0),
        ringMs = math.floor(number(c.RING_MS, 16, 1000, 33)),
        -- A game without the sign's archive (1.4.2): the game's own landing hologram.
        fallback = type(c.FALLBACK_EFFECT) == 'string' and c.FALLBACK_EFFECT ~= '' and c.FALLBACK_EFFECT or nil,
        records = type(c.RECORDS) == 'table' and c.RECORDS or { '^vehicle%.av_', 'max_tac_av' },
        range = number(c.RANGE_METRES, 10.0, 1000.0, 120.0),
        hulls = math.floor(number(c.MAX_HULLS, 1, 32, 6)),
        show = number(c.SHOW_METRES, 0.5, 50.0, 6.0),
        rest = number(c.REST_METRES, 0.0, 20.0, 1.5),
        descend = number(c.DESCEND_SPEED, 0.0, 20.0, 0.4),
        retire = math.floor(number(c.RETIRE_LOOKS, 1, 600, 10)),
        linger = math.floor(number(c.LINGER_MS, 0, 600000, 8000)),
        lift = number(c.LIFT_METRES, -2.0, 5.0, 0.15),
        fitRadius = number(c.FIT_RADIUS_METRES, 0.0, 10.0, 3.9),
        fitInner = number(c.FIT_INNER_METRES, 0.0, 10.0, 2.0),
        maxTilt = number(c.MAX_TILT_DEGREES, 0.0, 45.0, 20.0),
        fitStep = number(c.FIT_STEP_METRES, 0.05, 5.0, 0.6),
        fitResidual = number(c.FIT_RESIDUAL_METRES, 0.05, 5.0, 0.35),
        fitReach = number(c.FIT_REACH_METRES, 0.5, 20.0, 2.5),
        refit = math.floor(number(c.REFIT_MS, 100, 60000, 2000)),
        fitTriples = math.floor(number(c.FIT_TRIPLES, 10, 300, 96)),
        fitsPerLook = math.floor(number(c.FITS_PER_LOOK, 1, 32, 1)),
        ahead = number(c.AHEAD_METRES, -30.0, 30.0, 0.0),
        testAhead = number(c.TEST_AHEAD_METRES, 2.0, 50.0, 8.0),
        testSeconds = number(c.TEST_SECONDS, 1, 600, 20),
        look = math.floor(number(c.LOOK_MS, 16, 2000, 50)),
        list = math.floor(number(c.LIST_MS, 100, 10000, 500)),
        ground = math.floor(number(c.GROUND_MS, 50, 10000, 400)),
    }
end

--- Whether a record is an aircraft this resource signs.
function L.IsAircraft(record, settings)
    if type(record) ~= 'string' then return false end
    local lower = record:lower()
    for _, pattern in ipairs((settings or L.Settings()).records) do
        if type(pattern) == 'string' and lower:find(pattern) ~= nil then return true end
    end
    return false
end

--- The heading that turns the sign so that its top points along `forward`.
--- The sign's quad (the game's "STAY AWAY" quad) shows its text's top toward
--- its own -y and its right toward -x, so its +y must point back along the
--- hull. REDengine's yaw: 0 faces +y, growing toward -x; a turn of ψ takes +y
--- to (-sin ψ, cos ψ).
-- @param forward table `{ x, y }`
-- @return number radians
-- @return table the orientation quaternion `{ x, y, z, w }`
function L.SignYaw(forward)
    local fx, fy = finite(forward and forward.x) or 0.0, finite(forward and forward.y) or 1.0
    local length = math.sqrt(fx * fx + fy * fy)
    if length < 1e-6 then fx, fy, length = 0.0, 1.0, 1.0 end
    fx, fy = fx / length, fy / length
    local yaw = math.atan(fx, -fy)
    return yaw, { x = 0.0, y = 0.0, z = math.sin(yaw * 0.5), w = math.cos(yaw * 0.5) }
end

--- The sign's orientation on the ground's plane: turned like `L.SignYaw`, then
--- tilted with the plane `z = z0 + gx * dx + gy * dy` (its up, the sign's
--- normal, is `(-gx, -gy, 1)`): `q = q_tilt * q_yaw`, the tilt the shortest
--- turn from +z to that normal. A heading read back from it (`2 atan(z, w)`)
--- is the yaw's: the tilt scales both by the same factor.
-- @param forward table `{ x, y }`
-- @param fit table|nil `{ gx, gy }` (nil: flat)
-- @return number radians, the yaw
-- @return table the orientation quaternion `{ x, y, z, w }`
function L.SignOrientation(forward, fit)
    local yaw, flat = L.SignYaw(forward)
    local gx, gy = fit ~= nil and finite(fit.gx) or 0.0, fit ~= nil and finite(fit.gy) or 0.0
    if gx == 0.0 and gy == 0.0 then return yaw, flat end
    local length = math.sqrt(gx * gx + gy * gy + 1.0)
    local nx, ny, nz = -gx / length, -gy / length, 1.0 / length
    -- From +z to n: (z x n, 1 + z.n), normalised.
    local tx, ty, tw = -ny, nx, 1.0 + nz
    local norm = math.sqrt(tx * tx + ty * ty + tw * tw)
    tx, ty, tw = tx / norm, ty / norm, tw / norm
    local sz, cz = flat.z, flat.w
    return yaw, { x = tx * cz + ty * sz, y = ty * cz - tx * sz, z = tw * sz, w = tw * cz }
end

--- THE RING'S TURN (1.4.0): the sign's orientation turned `angle` radians
--- about its own up (its normal): `q * q_z(angle)`. A positive angle turns
--- it counterclockwise seen from above, so the band's words -- read clockwise
--- -- run past like a ticker.
-- @param q table the sign's orientation `{ x, y, z, w }`
-- @param angle number radians
-- @return table
function L.RingOrientation(q, angle)
    local s, c = math.sin(angle * 0.5), math.cos(angle * 0.5)
    return { x = q.x * c + q.y * s, y = q.y * c - q.x * s, z = q.w * s + q.z * c, w = q.w * c - q.z * s }
end

--- The ring's angle at `t` (ms): `RING_DEGREES_PER_SECOND` from the clock,
--- so every sign on this screen turns together, and a sign put up again
--- turns on where the others are.
function L.RingAngle(t, settings)
    local turn = (t / 1000.0) * settings.ringRate % 360.0
    return math.rad(turn)
end

--- A vector of the hull's frame turned into the world's: q v q*.
local function rotate(q, v)
    local tx = 2.0 * (q.y * v.z - q.z * v.y)
    local ty = 2.0 * (q.z * v.x - q.x * v.z)
    local tz = 2.0 * (q.x * v.y - q.y * v.x)
    return { x = v.x + q.w * tx + (q.y * tz - q.z * ty), y = v.y + q.w * ty + (q.z * tx - q.x * tz),
        z = v.z + q.w * tz + (q.x * ty - q.y * tx) }
end

--- The hull's orientation: the geometry's quaternion, else its heading alone
--- (REDengine: a turn of psi takes +y to (-sin psi, cos psi)).
local function hullQuaternion(orientation, forward)
    if type(orientation) == 'table' then
        local x, y, z, w = finite(orientation.x), finite(orientation.y), finite(orientation.z), finite(orientation.w)
        if x ~= nil and y ~= nil and z ~= nil and w ~= nil then
            local n = math.sqrt(x * x + y * y + z * z + w * w)
            if n > 1e-6 then return { x = x / n, y = y / n, z = z / n, w = w / n } end
        end
    end
    local fx, fy = forward and forward.x or 0.0, forward and forward.y or 1.0
    if fx == 0 and fy == 0 then fy = 1.0 end
    local yaw = math.atan(-fx, fy)
    return { x = 0.0, y = 0.0, z = math.sin(yaw * 0.5), w = math.cos(yaw * 0.5) }
end

--- The mesh box in the world. The client answers `bounds` in the HULL'S OWN
--- FRAME (client/src/api/ZoneGeometry.cpp: each corner taken relative to the
--- entity and turned by its inverse orientation -- an Excalibur at z 101 on
--- Staging answered a lowest point of -0.7), whatever the card says: a box
--- round the world's origin rather than round the hull is read as the hull's
--- own and its corners turned out into the world.
-- @return table|nil `{ centre = { x, y }, bottom, hullFrame }`
function L.WorldBox(bounds, position, orientation, forward)
    if type(bounds) ~= 'table' then return nil end
    local low, high = pointFrom(bounds.min), pointFrom(bounds.max)
    if low == nil or high == nil or high.x < low.x or high.y < low.y or high.z < low.z then return nil end
    local c = { x = (low.x + high.x) * 0.5, y = (low.y + high.y) * 0.5, z = (low.z + high.z) * 0.5 }
    local toOrigin = c.x * c.x + c.y * c.y + c.z * c.z
    local dx, dy, dz = c.x - position.x, c.y - position.y, c.z - position.z
    if toOrigin >= dx * dx + dy * dy + dz * dz then
        return { centre = { x = c.x, y = c.y }, bottom = low.z, hullFrame = false }
    end
    local q = hullQuaternion(orientation, forward)
    local bottom = math.huge
    for corner = 0, 7 do
        local v = rotate(q, { x = (corner % 2 == 1) and high.x or low.x,
            y = (math.floor(corner / 2) % 2 == 1) and high.y or low.y, z = (math.floor(corner / 4) % 2 == 1) and high.z or low.z })
        bottom = math.min(bottom, position.z + v.z)
    end
    local r = rotate(q, c)
    return { centre = { x = position.x + r.x, y = position.y + r.y }, bottom = bottom, hullFrame = true }
end

--- Where this screen draws a hull: `{ position, forward, centre, bottom }`, or nil.
local function frameOf(id, entity)
    local world = Open77.world
    if type(world) ~= 'table' or type(world.entityGeometry) ~= 'function' then
        once('geometry', 'warn', 'no Open77.world.entityGeometry on this client: no landing sign is drawn')
        return nil
    end
    local refs = {}
    local integer = math.tointeger(tonumber(id))
    if integer ~= nil then refs[#refs + 1] = { kind = 'vehicle', id = integer } end
    -- NEVER AN ENTITY OF 0: a snapshot's `entity` is 0 while its hull is not
    -- streamed, and the platform answers entity 0 with the LOCAL PLAYER's own
    -- geometry (client/src/api/ZoneGeometry.cpp) -- the sign was drawn under the
    -- laptop's player for a hull 23 m away that had just appeared (XyberRP
    -- Staging, 2026-10-28, 20:10:06 local). An answer for entity 0 is refused too.
    local handle = entity ~= nil and math.tointeger(tonumber(entity)) or nil
    if handle ~= nil and handle > 0 then
        refs[#refs + 1] = { kind = 'entity', id = handle }
    end
    for _, ref in ipairs(refs) do
        local read, answer = native('world.entityGeometry', world.entityGeometry, ref)
        if read and type(answer) == 'table' and answer.attached ~= false
            and not (answer.entity ~= nil and tonumber(answer.entity) == 0) then
            local position = pointFrom(answer.position)
            if position ~= nil then
                local frame = { position = position, centre = { x = position.x, y = position.y }, bottom = nil }
                local forward = pointFrom(answer.forward)
                if forward ~= nil and (forward.x ~= 0 or forward.y ~= 0) then frame.forward = forward end
                local box = L.WorldBox(answer.bounds, position, answer.orientation, frame.forward)
                if box ~= nil then
                    frame.centre, frame.bottom, frame.hullFrame = box.centre, box.bottom, box.hullFrame
                end
                return frame
            end
        end
    end
    return nil
end

-- Whether this client's rays take collision groups (Stable 156), so that the
-- ground is the static meshes AND the terrain: nil until the first ray.
local rayGroups = nil
local GROUND_GROUPS = { 'Static', 'Terrain' }

--- Asks once. A build that knows `groups` refuses them beside `static` by
--- name (`collision_groups_conflict`) before it traces anything; an older one
--- ignores the field and traces Static and Dynamic -- the hulls themselves,
--- which is why it must not be asked for the ground.
local function probeRayGroups(world)
    if type(world.raycast) ~= 'function' then return false, 'no Open77.world.raycast' end
    local read, answer, reason = pcall(world.raycast, { x = 0.0, y = 0.0, z = 1500.0 }, { x = 0.0, y = 0.0, z = 1499.0 },
        { groups = { 'Static' }, static = true })
    if read and answer == nil and reason == 'collision_groups_conflict' then return true, nil end
    return false, read and ('its rays take no collision groups (%s)'):format(answer == nil and tostring(reason) or 'traced')
        or ('the probe ray failed: %s'):format(tostring(answer))
end

--- The ground under a point: the first static mesh -- or terrain, where this
--- client's rays meet it -- straight down from `fromZ`. nil when nothing is
--- below (open water, a hole in the world, terrain on an older client).
local function groundBelow(x, y, fromZ)
    local world = Open77.world
    if type(world) ~= 'table' then return nil end
    if rayGroups == nil then
        local why
        rayGroups, why = probeRayGroups(world)
        if rayGroups then
            Open77.log.info('the ground under a sign: static meshes and terrain (this client\'s rays take collision groups)')
        else
            Open77.log.info(('the ground under a sign: static meshes only, %s: no sign over open terrain'):format(tostring(why)))
        end
    end
    if rayGroups then
        local read, hit, reason = native('world.raycast', world.raycast, { x = x, y = y, z = fromZ }, { x = x, y = y, z = fromZ - 1000.0 },
            { groups = GROUND_GROUPS })
        if read and type(hit) == 'table' then
            if hit.hit ~= true then return nil end
            local at = pointFrom(hit.position)
            return at ~= nil and at.z or nil
        end
        local cause = tostring(read and reason or hit)
        if cause:find('collision_group', 1, true) then
            -- This build does not know one of the groups: static only from now on.
            rayGroups = false
            Open77.log.warn(('the ground under a sign: the terrain ray was refused (%s): static meshes only from now on')
                :format(cause))
        else
            once('ray:' .. cause, 'warn', ('a ground ray was refused (%s): asked again static only'):format(cause))
        end
    end
    if type(world.groundZ) ~= 'function' then return nil end
    local read, z = native('world.groundZ', world.groundZ, x, y, fromZ)
    if not read then return nil end
    return finite(z)
end

--- The sample points of the ground's plane, round the sign's centre: the
--- centre, eight on the ring's edge (`FIT_RADIUS_METRES`), four on the word's
--- (`FIT_INNER_METRES`, between them). A radius of 0 drops its points.
-- @return table `{ { dx, dy }, ... }`
function L.FitOffsets(settings)
    local out = { { 0.0, 0.0 } }
    if settings.fitRadius > 0.0 then
        for k = 0, 7 do
            local a = k * math.pi / 4.0
            out[#out + 1] = { settings.fitRadius * math.cos(a), settings.fitRadius * math.sin(a) }
        end
    end
    if settings.fitInner > 0.0 then
        for k = 0, 3 do
            local a = math.pi / 4.0 + k * math.pi / 2.0
            out[#out + 1] = { settings.fitInner * math.cos(a), settings.fitInner * math.sin(a) }
        end
    end
    return out
end

local function det3(a, b, c, d, e, f, g, h, i)
    return a * (e * i - f * h) - b * (d * i - f * g) + c * (d * h - e * g)
end

--- Least squares `z = a + b dx + c dy` through the points; flat at their mean
--- when they do not span a plane (fewer than three, or in a line).
local function plane(points)
    local n, sx, sy, sz, sxx, syy, sxy, sxz, syz = 0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0
    for _, p in ipairs(points) do
        n = n + 1
        sx, sy, sz = sx + p.dx, sy + p.dy, sz + p.z
        sxx, syy, sxy = sxx + p.dx * p.dx, syy + p.dy * p.dy, sxy + p.dx * p.dy
        sxz, syz = sxz + p.dx * p.z, syz + p.dy * p.z
    end
    if n == 0 then return 0.0, 0.0, 0.0 end
    local det = det3(n, sx, sy, sx, sxx, sxy, sy, sxy, syy)
    if n < 3 or math.abs(det) <= 1e-6 * (1.0 + n * sxx * syy) then return sz / n, 0.0, 0.0 end
    return det3(sz, sx, sy, sxz, sxx, sxy, syz, sxy, syy) / det,
        det3(n, sz, sy, sx, sxz, sxy, sy, syz, syy) / det,
        det3(n, sx, sz, sx, sxx, sxz, sy, sxy, syz) / det
end

--- Of the planes through three samples, the one most samples lie on (within
--- `FIT_RESIDUAL_METRES`; then the nearest): those samples. A cluster of
--- samples on a wall drags a least-squares plane toward it, so that its
--- worst sample is a good one; the consensus is not dragged.
---
--- THE COST IS BOUNDED. The game runs a resource's Lua in slices with an
--- instruction budget, and every triple of thirteen samples -- 286 of them,
--- each tried against all thirteen -- ran out of it on uneven ground (Staging,
--- 2026-10-27, 17:40:21: "main.lua:453: Open77 script execution budget
--- exceeded", an Excalibur taking off over a kerb). So the triples are tried
--- in order -- the centre's first, then the ring's -- at most `FIT_TRIPLES` of
--- them, with the samples in flat arrays; a plane every sample lies on (flat
--- ground, any one slope) ends it at once.
--- A breath (1.3.2): the rest in the next resume. The host kills a resume at
--- its 10 000th instruction when its slice is spent -- on the laptop always
--- (scripting/src/ResourceHost.cpp, `InstructionHook`; open77_avdoor's
--- tests/world.lua emulates it): the triples are tried a dozen at a time.
local function breathe()
    local co = coroutine
    if type(co) == 'table' and type(co.isyieldable) == 'function' and not co.isyieldable() then return end
    local from = stamp()
    local job = currentJob
    Wait(0)
    currentJob = job
    -- The frames waited are not what the pass cost (`every`).
    local me = type(co.running) == 'function' and co.running() or nil
    if me ~= nil and breathBy[me] ~= nil then breathBy[me] = breathBy[me] + (stamp() - from) end
end
local BREATHE_TRIPLES = 12

local function consensus(points, tolerance, maxTriples)
    local n = #points
    if n < 3 then return points end
    -- The rays and the look before them in one resume, the triples in others.
    breathe()
    local X, Y, Z = {}, {}, {}
    for i, p in ipairs(points) do X[i], Y[i], Z[i] = p.dx, p.dy, p.z end
    local bestA, bestB, bestC, bestCount, bestCost = nil, 0.0, 0.0, 0, math.huge
    local tried = 0
    for i = 1, n - 2 do
        for j = i + 1, n - 1 do
            for k = j + 1, n do
                tried = tried + 1
                if tried > maxTriples then goto done end
                if tried % BREATHE_TRIPLES == 0 then breathe() end
                -- The plane through the three -- none when they are in a line,
                -- or when it stands steeper than 60 degrees (no ground is).
                local ux, uy, uz = X[j] - X[i], Y[j] - Y[i], Z[j] - Z[i]
                local vx, vy, vz = X[k] - X[i], Y[k] - Y[i], Z[k] - Z[i]
                local nz = ux * vy - uy * vx
                if nz > 1e-6 or nz < -1e-6 then
                    local b = -(uy * vz - uz * vy) / nz
                    local c = -(uz * vx - ux * vz) / nz
                    if b * b + c * c <= 3.0 then
                        local a = Z[i] - b * X[i] - c * Y[i]
                        local count, cost = 0, 0.0
                        for m = 1, n do
                            local off = Z[m] - (a + b * X[m] + c * Y[m])
                            if off <= tolerance and off >= -tolerance then count, cost = count + 1, cost + off * off end
                        end
                        if count > bestCount or (count == bestCount and cost < bestCost) then
                            bestA, bestB, bestC, bestCount, bestCost = a, b, c, count, cost
                            -- Every sample on it: no plane does better (flat ground ends here).
                            if count == n then goto done end
                        end
                    end
                end
            end
        end
    end
    ::done::
    if bestA == nil then return points end
    local out = {}
    for m, p in ipairs(points) do
        local off = Z[m] - (bestA + bestB * X[m] + bestC * Y[m])
        if off <= tolerance and off >= -tolerance then out[#out + 1] = p end
    end
    return out
end

--- The ground's plane under a sign centred on (x, y): the rays of
--- `L.FitOffsets` straight down from `fromZ`; the samples that can be the
--- ground the centre stands on (within `FIT_STEP_METRES` of its height, plus
--- what `MAX_TILT_DEGREES` allows at their distance: not the street under a
--- roof's edge, not a wall's top); of those, the ones on the plane most of
--- them lie on (a bench, a bollard, a wall's foot left out), fitted by least
--- squares; the samples left out at first that lie on it after all taken
--- back (a slope steeper than the first guess allowed); its slope held to
--- `MAX_TILT_DEGREES`; then raised until no sample kept is above it.
-- @param ground function|nil `(x, y, fromZ) -> z|nil` (the client's rays)
-- @return table|nil `{ x, y, z, gx, gy, tilt, cast, found, used, raised,
--   clamped }`: the plane is `z + gx (X - x) + gy (Y - y)`; nil when no ray
--   met any ground
function L.FitGround(x, y, fromZ, settings, ground)
    ground = ground or groundBelow
    local offsets = L.FitOffsets(settings)
    local slope = math.tan(math.rad(settings.maxTilt))
    local found, centre = {}, nil
    for index, offset in ipairs(offsets) do
        -- Each ray starts as much higher as the steepest slope allowed rises
        -- at its distance: up a hill, the ground there is over `fromZ`.
        local r = math.sqrt(offset[1] * offset[1] + offset[2] * offset[2])
        local z = finite(ground(x + offset[1], y + offset[2], fromZ + r * slope))
        if z ~= nil then
            found[#found + 1] = { dx = offset[1], dy = offset[2], z = z, r = r }
            if index == 1 then centre = z end
        end
    end
    if #found == 0 then return nil end
    local function near(reference)
        local out = {}
        for _, p in ipairs(found) do
            if math.abs(p.z - reference) <= settings.fitStep + p.r * slope then out[#out + 1] = p end
        end
        return out
    end
    -- The ground the sign stands on: the centre's (where the hull comes
    -- down); the samples' median when the centre's ray met nothing.
    local reference = centre
    if reference == nil then
        local heights = {}
        for i, p in ipairs(found) do heights[i] = p.z end
        table.sort(heights)
        reference = heights[math.floor((#heights + 1) / 2)]
    end
    local used = consensus(near(reference), settings.fitResidual, settings.fitTriples)
    breathe()
    local a, b, c = plane(used)
    -- Left out at first, on the plane after all: the same ground, steeper.
    local kept = {}
    for _, p in ipairs(used) do kept[p] = true end
    local back = 0
    for _, p in ipairs(found) do
        if not kept[p] and math.abs(p.z - (a + b * p.dx + c * p.dy)) <= settings.fitResidual then
            used[#used + 1] = p
            back = back + 1
        end
    end
    if back > 0 then a, b, c = plane(used) end
    local grade = math.sqrt(b * b + c * c)
    local clamped = grade > slope + 1e-9
    if clamped then
        local k = grade > 0.0 and slope / grade or 0.0
        b, c, grade = b * k, c * k, slope
    end
    local raised = 0.0
    for _, p in ipairs(used) do
        local over = p.z - (a + b * p.dx + c * p.dy)
        if over > raised then raised = over end
    end
    return { x = x, y = y, z = a + raised, gx = b, gy = c, tilt = math.deg(math.atan(grade)), cast = #offsets,
        found = #found, used = #used, raised = raised, clamped = clamped }
end

--- The plane's height under (x, y), or nil.
local function onPlane(fit, x, y)
    if fit == nil then return nil end
    return fit.z + fit.gx * (x - fit.x) + fit.gy * (y - fit.y)
end

--- The plane, for a log line.
local function planeText(fit)
    if fit == nil then return 'no ground under it: laid flat' end
    local shape
    if fit.tilt < 0.05 then
        shape = 'flat'
    else
        -- The way it falls, as a heading (REDengine: 0 is +y, growing toward -x).
        local falls = math.deg(math.atan(fit.gx, -fit.gy)) % 360.0
        shape = ('%.1f deg slope%s, falling toward heading %.0f deg'):format(fit.tilt,
            fit.clamped and ' (held to the steepest allowed)' or '', falls)
    end
    return ('ground plane %s, %d of %d rays on the ground, %d kept, raised %.2f m'):format(shape, fit.found, fit.cast,
        fit.used, fit.raised)
end

local function stopWord(hull, why)
    local vfx = Open77.vfx
    if type(vfx) == 'table' and type(vfx.stop) == 'function' then
        if hull.handle ~= nil then pcall(vfx.stop, hull.handle) end
        if hull.ringHandle ~= nil then pcall(vfx.stop, hull.ringHandle) end
    end
    hull.ringHandle = nil
    if hull.up then
        counts.off = counts.off + 1
        Open77.log.info(('landing sign under %s (%s) off: %s, after %.1fs')
            :format(hull.key, tostring(hull.record), why, (now() - (hull.upAt or now())) / 1000.0))
    end
    hull.handle, hull.up, hull.laid, hull.retire, hull.upAt, hull.fitSaid = nil, false, nil, 0, nil, nil
end

local function laidAt(point, quat)
    return { x = point.x, y = point.y, z = point.z, qx = quat.x, qy = quat.y, qz = quat.z, qw = quat.w }
end

--- Puts the sign at a point on the ground, turned and tilted: moved when it
--- is up, played when it is not (or its effect is gone).
-- @param detail string|nil said on the line of a sign that comes on (its plane)
-- @return boolean whether it is up
--- The ring under a sign that is up: played when it has none, else moved and
--- turned to the ring's angle now. A ring the game refuses leaves the word
--- alone (one line).
local function layRing(hull, point, quat, settings, t)
    local vfx = Open77.vfx
    if settings.ringEffect == nil or type(vfx) ~= 'table' then return end
    local turned = L.RingOrientation(quat, L.RingAngle(t or now(), settings))
    if hull.ringHandle ~= nil and type(vfx.update) == 'function' then
        local read, ok = native('vfx.update', vfx.update, hull.ringHandle, { position = point, orientation = turned })
        if read and ok == true then return true end
        pcall(vfx.stop, hull.ringHandle)
        hull.ringHandle = nil
    end
    local read, handle, reason = native('vfx.play', vfx.play, settings.ringEffect, { position = point, orientation = turned })
    if not read or handle == nil or handle == false then
        counts.refused = counts.refused + 1
        local cause = tostring(read and reason or handle)
        once('ring:' .. cause, 'warn', ('the landing sign\'s ring %s was refused (%s): the word is drawn alone')
            :format(settings.ringEffect, cause))
        return false
    end
    hull.ringHandle = handle
    return true
end

local function lay(hull, point, quat, settings, why, detail)
    local vfx = Open77.vfx
    if type(vfx) ~= 'table' or type(vfx.play) ~= 'function' then
        once('vfx', 'warn', 'no Open77.vfx on this client: no landing sign is drawn')
        return false
    end
    if hull.handle ~= nil then
        local was = hull.laid
        local moved = was == nil or math.abs(was.x - point.x) > 0.02 or math.abs(was.y - point.y) > 0.02
            or math.abs(was.z - point.z) > 0.02 or math.abs(was.qx - quat.x) > 1e-4 or math.abs(was.qy - quat.y) > 1e-4
            or math.abs(was.qz - quat.z) > 1e-4 or math.abs(was.qw - quat.w) > 1e-4
        if not moved then
            -- The word stays; the ring is kept turning by `L.Turn` (and played
            -- again here when it was refused or lost).
            if hull.ringHandle == nil and settings.ringEffect ~= nil and not fallbackOn then
                layRing(hull, point, quat, settings)
            end
            return true
        end
        if type(vfx.update) == 'function' then
            local read, ok = native('vfx.update', vfx.update, hull.handle, { position = point, orientation = quat })
            if read and ok == true then
                hull.laid = laidAt(point, quat)
                if not fallbackOn then layRing(hull, point, quat, settings) end
                return true
            end
        end
        -- The effect is gone (stopped by the platform, the quota, a stream-out):
        -- played again below.
        pcall(vfx.stop, hull.handle)
        hull.handle = nil
    end
    local effect = (fallbackOn and settings.fallback) or settings.effect
    local read, handle, reason = native('vfx.play', vfx.play, effect, { position = point, orientation = quat })
    local cause = (not read or handle == nil or handle == false) and tostring(read and reason or handle) or nil
    -- THE SIGN'S ARCHIVE NOT IN THIS GAME (1.4.2): the game's own landing
    -- hologram instead, from now on.
    if cause ~= nil and not fallbackOn and (cause == 'not_found' or cause:find('not_found', 1, true)) then
        fallbackOn = settings.fallback ~= nil
        once('missing', 'warn', ('the landing sign %s is not in this game -- its archive is not in the game it started '
            .. 'with: close the game and start it again through the Open77 launcher (it lays this server\'s mods); '
            .. '%s'):format(settings.effect, fallbackOn and ('until then the game\'s own AV landing hologram (%s) '
                .. 'marks a landing'):format(settings.fallback) or 'no landing is marked (`FALLBACK_EFFECT = false`)'))
        if fallbackOn then
            effect = settings.fallback
            read, handle, reason = native('vfx.play', vfx.play, effect, { position = point, orientation = quat })
            cause = (not read or handle == nil or handle == false) and tostring(read and reason or handle) or nil
        end
    end
    if cause ~= nil then
        counts.refused = counts.refused + 1
        if fallbackOn then
            once('fallback:' .. cause, 'warn', ('the game\'s own AV landing hologram %s was refused too (%s): no '
                .. 'landing is marked in this game'):format(tostring(settings.fallback), cause))
        elseif cause == 'not_found' or cause:find('not_found', 1, true) then
            once('missing', 'warn', ('the landing sign %s is not in this game: install open77_avlanding\'s archive '
                .. '(the launcher does it on connect) and restart the game'):format(settings.effect))
        else
            once('refused:' .. cause, 'warn', ('the landing sign was refused: %s'):format(cause))
        end
        return false
    end
    if fallbackOn == nil and effect == settings.effect then fallbackOn = false end
    hull.handle = handle
    hull.laid = laidAt(point, quat)
    if not fallbackOn then layRing(hull, point, quat, settings) end
    if not hull.up then
        hull.up, hull.upAt = true, now()
        counts.on = counts.on + 1
        -- A plane (or false: none) is put in words only here, once.
        if type(detail) == 'table' or detail == false then detail = planeText(detail or nil) end
        Open77.log.info(('landing sign under %s (%s) on: %s, at %.1f, %.1f, %.2f, heading %.0f deg%s; %s')
            :format(hull.key, tostring(hull.record), why, point.x, point.y, point.z,
                math.deg(2.0 * math.atan(quat.z, quat.w)) % 360.0, detail ~= nil and (', ' .. detail) or '',
                fallbackOn and 'the game\'s own landing hologram (no sign archive in this game)'
                    or (hull.ringHandle ~= nil and ('the ring turning %.0f deg/s'):format(settings.ringRate)
                        or 'no ring')))
    end
    return true
end

-- How many ground planes the pass in progress may still measure
-- (`FITS_PER_LOOK`): the thirteen rays and the consensus of one sign are the
-- dearest thing this resource does, and the game runs it in budgeted slices.
-- Outside a pass (the test command), unbounded.
local fitBudget = math.huge

--- The ground's plane under a sign at (x, y), kept on `owner.fit`: measured
--- again once it is `REFIT_MS` old, or once the sign moved half a metre (at
--- most every `GROUND_MS`); in between the sign slides on it. A plane that
--- changed under a sign that is up is a line (one per 5 s at most). A pass
--- that has measured its `FITS_PER_LOOK` leaves the rest for the next one.
-- @return table|nil the plane
-- @return boolean true when this sign has no plane yet and waits for one
local function fitted(owner, x, y, groundZ, t, settings)
    local fit = owner.fit
    -- No ray met the ground the last time: not asked again before GROUND_MS.
    if fit == nil and owner.fitMissAt ~= nil and t - owner.fitMissAt < settings.ground then return nil, false end
    local age = fit ~= nil and (t - (fit.at or 0)) or math.huge
    local moved = fit ~= nil and (math.abs(fit.x - x) > 0.5 or math.abs(fit.y - y) > 0.5)
    if fit == nil or age >= settings.refit or (moved and age >= settings.ground) then
        if fitBudget <= 0 then
            owner.fitWaits = (owner.fitWaits or 0) + 1
            return fit, fit == nil
        end
        fitBudget = fitBudget - 1
        local fresh = L.FitGround(x, y, groundZ + settings.fitReach, settings)
        if fresh ~= nil then
            fresh.at = t
            local said = owner.fitSaid
            if owner.up and said ~= nil and t - (owner.fitSaidAt or 0) >= 5000
                and (math.abs(fresh.tilt - said.tilt) > 3.0 or math.abs(fresh.z - (onPlane(said, x, y) or fresh.z)) > 0.5) then
                Open77.log.info(('landing sign under %s: the ground changed under it: %s'):format(owner.key, planeText(fresh)))
                owner.fitSaid, owner.fitSaidAt = fresh, t
            end
        end
        if fresh == nil and fit ~= nil and not moved then
            -- Nothing met this time (a streaming hiccup): the plane it had stands.
            fit.at = t
        else
            owner.fit, owner.fitMissAt, fit = fresh, fresh == nil and t or nil, fresh
        end
    end
    return fit, false
end

--- Where and how the sign lies over (x, y): on the plane when there is one,
--- else flat on `groundZ`; `LIFT_METRES` up either way.
local function placed(x, y, groundZ, forward, fit, settings)
    local _, quat = L.SignOrientation(forward, fit)
    return { x = x, y = y, z = (onPlane(fit, x, y) or groundZ) + settings.lift }, quat
end

--- How many are aboard, from either shape of snapshot: `vehicles.nearby`
--- counts them (a number), `vehicles.get` lists them (a table).
local function aboard(snapshot)
    if type(snapshot) ~= 'table' then return 0 end
    local occupants = snapshot.occupants
    if type(occupants) == 'number' then return math.max(0, math.floor(occupants)) end
    if type(occupants) == 'table' then return #occupants end
    return 0
end

--- Whether a hull is in use, and by what: somebody aboard (the listing's
--- count, the full snapshot's list, or this player's own seat), its engine, a
--- physics owner.
-- @return boolean
-- @return string|nil what
function L.InUse(hull)
    if type(hull) ~= 'table' then return false, nil end
    if hull.mine then return true, 'this player aboard' end
    local count = math.max(aboard(hull.snapshot), aboard(hull.full))
    if count > 0 then return true, ('%d aboard'):format(count) end
    local full = hull.full
    if type(full) == 'table' then
        if full.engineOn == true then return true, 'its engine on' end
        local owner = tonumber(full.physicsOwner)
        if owner ~= nil and owner ~= 0 then return true, ('physics owned by player %d'):format(owner) end
    end
    return false, nil
end

--- Why a watched aircraft has no sign, said whenever the reason changes (the
--- numbers alone changing are not a change), one line per 2 s at most.
local function whyNot(hull, t, class, text)
    if hull.whyNot == class then return end
    if hull.whyNotAt ~= nil and t - hull.whyNotAt < 2000 then return end
    hull.whyNot, hull.whyNotAt = class, t
    Open77.log.info(('no landing sign under %s (%s): %s'):format(hull.key, tostring(hull.record), text))
end

--- One look at one hull.
-- @param hull table
-- @param t number the time
-- @param settings table
function L.Look(hull, t, settings)
    local frame = frameOf(hull.id, hull.entity)
    if frame == nil then
        if hull.up then stopWord(hull, 'not drawn here') end
        hull.lastZ, hull.lastAt = nil, nil
        return
    end
    local cx, cy, z = frame.centre.x, frame.centre.y, frame.position.z
    -- Where the hull's box was read, once (a box streamed in later is said then).
    local boxState = frame.bottom == nil and 'none' or (frame.hullFrame and 'hull' or 'world')
    if hull.boxSaid ~= boxState and (hull.boxSaid == nil or boxState ~= 'none') then
        hull.boxSaid = boxState
        Open77.log.info(('the mesh box of %s (%s): %s; its centre %.1f, %.1f, its lowest point %s, its origin %.1f, '
            .. '%.1f, %.2f'):format(hull.key, tostring(hull.record), boxState == 'none'
                and 'none yet (not streamed in): its origin stands in for its centre, 1.5 m over its lowest point'
                or (boxState == 'hull' and 'in the hull\'s own frame, turned out into the world' or 'in the world'),
            cx, cy, frame.bottom ~= nil and ('%.2f'):format(frame.bottom) or 'unknown', frame.position.x,
            frame.position.y, z))
    end
    if hull.ground == nil or t - (hull.groundAt or 0) >= settings.ground
        or math.abs((hull.groundX or cx) - cx) > 0.5 or math.abs((hull.groundY or cy) - cy) > 0.5 then
        hull.ground = groundBelow(cx, cy, z + 1.0)
        hull.groundAt, hull.groundX, hull.groundY = t, cx, cy
    end
    local bottom = frame.bottom or (z - 1.5)
    local clearance = hull.ground ~= nil and (bottom - hull.ground) or nil
    local vz = 0.0
    if hull.lastZ ~= nil and hull.lastAt ~= nil and t > hull.lastAt then
        vz = (z - hull.lastZ) / ((t - hull.lastAt) / 1000.0)
        if math.abs(vz) > 60.0 then vz = 0.0 end
    end
    hull.lastZ, hull.lastAt = z, t
    hull.clearance, hull.vz = clearance, vz
    local busy, user = L.InUse(hull)
    hull.busy = busy
    if busy then hull.idleSince = nil elseif hull.idleSince == nil then hull.idleSince = t end
    local idleFor = hull.idleSince ~= nil and (t - hull.idleSince) or 0
    local inBand = clearance ~= nil and clearance > -1.0 and clearance <= settings.show
    local coming = inBand and vz < -settings.descend
    local resting = inBand and clearance <= settings.rest and (busy or idleFor < settings.linger)
    local why = nil
    if coming then
        why = ('coming down at %.1f m/s, %.1f m over the ground'):format(-vz, math.max(0.0, clearance))
    elseif resting then
        why = ('on the ground (%.1f m), %s'):format(math.max(0.0, clearance),
            busy and ('in use: ' .. tostring(user)) or 'idle a moment')
    end
    local keep = hull.up and inBand and (busy or idleFor < settings.linger)
    if why ~= nil or keep then
        hull.retire = 0
        hull.whyNot = nil
        local forward = frame.forward or { x = 0.0, y = 1.0 }
        local x, y, groundZ = cx, cy, hull.ground
        if settings.ahead ~= 0.0 then
            -- Ahead of (or behind) the hull along its own axis, on the ground there.
            local length = math.sqrt(forward.x * forward.x + forward.y * forward.y)
            if length > 1e-6 then
                x = cx + forward.x / length * settings.ahead
                y = cy + forward.y / length * settings.ahead
            end
            if hull.aheadGround == nil or t - (hull.aheadAt or 0) >= settings.ground
                or math.abs((hull.aheadX or x) - x) > 0.5 or math.abs((hull.aheadY or y) - y) > 0.5 then
                hull.aheadGround = groundBelow(x, y, z + 1.0) or hull.ground
                hull.aheadAt, hull.aheadX, hull.aheadY = t, x, y
            end
            groundZ = hull.aheadGround
        end
        local fit, waiting = fitted(hull, x, y, groundZ, t, settings)
        -- THE FIT BREATHES (1.3.2): a hull dropped meanwhile (out of range, removed,
        -- the resource stopped) is not signed -- nothing would ever take its sign
        -- down again.
        if hulls[hull.key] ~= hull or stopped then return end
        -- No plane yet, and this pass has measured its own: laid on the next
        -- pass (a twentieth of a second), never flat first and tilted after.
        if waiting then return end
        local point, quat = placed(x, y, groundZ, forward, fit, settings)
        local wasUp = hull.up
        lay(hull, point, quat, settings, why or 'in the band', fit or false)
        if hull.up and not wasUp then hull.fitSaid, hull.fitSaidAt = fit, t end
        return
    end
    if hull.up then
        hull.retire = hull.retire + 1
        if hull.retire >= settings.retire then
            stopWord(hull, clearance == nil and 'no ground under it'
                or (not inBand and ('%.1f m over the ground, %.1f m/s'):format(clearance, vz))
                or ('parked, idle %.0fs'):format(idleFor / 1000.0))
        end
        return
    end
    -- Not signed, and why (the line changes only when the reason does).
    if clearance == nil then
        whyNot(hull, t, 'ground', ('no ground found under it (its lowest point at %.1f)'):format(bottom))
    elseif not inBand then
        whyNot(hull, t, clearance > settings.show and 'high' or 'under',
            ('%.1f m over the ground (shown within %.1f m)'):format(clearance, settings.show))
    elseif busy then
        whyNot(hull, t, 'hover', ('%.1f m over the ground, %.1f m/s, in use (%s): neither coming down faster than '
            .. '%.1f m/s nor within %.1f m'):format(clearance, vz, tostring(user), settings.descend, settings.rest))
    else
        whyNot(hull, t, 'idle', ('%.1f m over the ground, nobody aboard, engine off, idle %.0fs (a sign stays '
            .. '%.0fs after a hull falls idle)'):format(clearance, idleFor / 1000.0, settings.linger / 1000.0))
    end
end

--- Lists the aircraft in range; the nearest `MAX_HULLS` are kept, the others
--- (and any that left) dropped.
function L.List()
    local settings = L.Settings()
    if settings.effect == nil then return end
    local vehicles = Open77.vehicles
    if type(vehicles) ~= 'table' or type(vehicles.nearby) ~= 'function' then
        once('vehicles', 'warn', 'no Open77.vehicles.nearby on this client: no landing sign is drawn')
        return
    end
    local read, list = pcall(vehicles.nearby, settings.range)
    if not read or type(list) ~= 'table' then return end
    local picked = {}
    for _, snapshot in ipairs(list) do
        if type(snapshot) == 'table' and snapshot.id ~= nil then
            if L.IsAircraft(snapshot.record, settings) then
                picked[#picked + 1] = snapshot
            elseif type(snapshot.record) == 'string' then
                once('record:' .. snapshot.record, 'info', ('%s is not an aircraft for the landing sign (RECORDS in '
                    .. 'shared/config.lua)'):format(snapshot.record))
            end
        end
    end
    table.sort(picked, function(a, b) return (tonumber(a.distance) or 0) < (tonumber(b.distance) or 0) end)
    -- This player's own seat: a hull they sit in is in use, whatever a listing says.
    local seatOf = nil
    if type(vehicles.getPlayerSeat) == 'function' then
        local seatRead, seat = pcall(vehicles.getPlayerSeat)
        if seatRead and type(seat) == 'table' and seat.vehicleId ~= nil and seat.exiting ~= true then
            seatOf = tostring(math.tointeger(tonumber(seat.vehicleId)) or seat.vehicleId)
        end
    end
    local keep = {}
    for index = 1, math.min(#picked, settings.hulls) do
        local snapshot = picked[index]
        local key = tostring(math.tointeger(tonumber(snapshot.id)) or snapshot.id)
        keep[key] = true
        local hull = hulls[key]
        -- The engine and the physics owner are in the full snapshot only.
        local full = nil
        if type(vehicles.get) == 'function' then
            local fullRead, answer = pcall(vehicles.get, snapshot.id)
            if fullRead and type(answer) == 'table' then full = answer end
        end
        if hull == nil then
            hull = { id = snapshot.id, key = key, record = snapshot.record, up = false, retire = 0 }
            hulls[key] = hull
            Open77.log.info(('watching %s (%s) for the landing sign: %.0f m away, %d aboard%s'):format(key,
                tostring(snapshot.record), tonumber(snapshot.distance) or -1, math.max(aboard(snapshot), aboard(full)),
                seatOf == key and ', this player among them' or ''))
        end
        hull.snapshot, hull.full, hull.entity, hull.record = snapshot, full, snapshot.entity, snapshot.record
        hull.mine = seatOf == key
    end
    for key, hull in pairs(hulls) do
        if not keep[key] then
            stopWord(hull, 'out of range')
            Open77.log.info(('no longer watching %s (%s): out of range or not among the %d nearest')
                :format(key, tostring(hull.record), settings.hulls))
            hulls[key] = nil
        end
    end
end

--- One look at every hull kept.
function L.Step()
    if next(hulls) == nil then return end
    local settings = L.Settings()
    if settings.effect == nil then return end
    local t = now()
    fitBudget = settings.fitsPerLook
    -- The hulls of this look, listed first: a look may breathe (`breathe`), and
    -- the list job may add or drop a hull meanwhile.
    local keys = {}
    for key in pairs(hulls) do keys[#keys + 1] = key end
    table.sort(keys)
    for _, key in ipairs(keys) do
        local hull = hulls[key]
        if hull ~= nil then
            local ran, failure = pcall(L.Look, hull, t, settings)
            if not ran then once('look:' .. key, 'error', ('the landing sign under %s failed: %s'):format(key, tostring(failure))) end
            -- One hull a resume.
            if #keys > 1 then breathe() end
        end
    end
    fitBudget = math.huge
end

--- A hull taken out of the world takes its word with it.
function L.Removed(id)
    local key = tostring(math.tointeger(tonumber(id)) or id)
    local hull = hulls[key]
    if hull == nil then return end
    stopWord(hull, 'the hull was removed')
    Open77.log.info(('no longer watching %s (%s): the hull was removed'):format(key, tostring(hull.record)))
    hulls[key] = nil
end

-- The word the test command put up: `{ key, record, up, handle, ... }` like a hull's.
local test = nil

--- `avlanding.test`: the word on the ground `TEST_AHEAD_METRES` in front of the
--- local player for `TEST_SECONDS`, its top pointing away from the player, so
--- it reads the right way up from where they stand -- the sign in this game,
--- without an aircraft. Says in the client log where it went, or why not.
-- @return boolean whether it is up
-- @return string why not
function L.Test()
    local settings = L.Settings()
    if settings.effect == nil then return false, 'no EFFECT in shared/config.lua' end
    local character = Open77.character
    if type(character) ~= 'table' or type(character.position) ~= 'function' then return false, 'no Open77.character' end
    local read, px, py, pz = pcall(character.position)
    px, py, pz = finite(px), finite(py), finite(pz)
    if not read or px == nil or py == nil or pz == nil then return false, 'the player has no position' end
    local degrees = 0.0
    if type(character.yaw) == 'function' then
        local yawRead, value = pcall(character.yaw)
        degrees = yawRead and finite(value) or 0.0
    end
    -- REDengine's yaw: 0 faces +y, growing toward -x.
    local yaw = math.rad(degrees)
    local fx, fy = -math.sin(yaw), math.cos(yaw)
    local x, y = px + fx * settings.testAhead, py + fy * settings.testAhead
    -- The ground there, from FIT_REACH_METRES over the player's feet; up a
    -- hill that starts under it (nothing met, or a ground further down than
    -- a 45-degree fall): asked again from higher, as steep as allowed, then
    -- as steep as 45 degrees.
    local ground, low = nil, nil
    local slope = math.tan(math.rad(settings.maxTilt))
    for _, start in ipairs({ pz + settings.fitReach, pz + settings.fitReach + settings.testAhead * slope,
            pz + settings.fitReach + settings.testAhead }) do
        local z = groundBelow(x, y, start)
        if z ~= nil and z >= pz - settings.testAhead - settings.fitReach then ground = z break end
        low = low or z
    end
    ground = ground or low
    local fit = L.FitGround(x, y, (ground or pz) + settings.fitReach, settings)
    -- The fit breathes: a resource stopped meanwhile lays nothing.
    if stopped then return false, 'the resource stopped' end
    local point, quat = placed(x, y, ground or pz, { x = fx, y = fy }, fit, settings)
    if test ~= nil then stopWord(test, 'a new test') end
    test = { key = 'the test command', record = 'avlanding.test', up = false, retire = 0, fit = fit }
    local mine = test
    local where = ground ~= nil and ('ground %.2f'):format(ground)
        or ('no ground under its centre (the player\'s feet: %.2f)'):format(pz)
    if not lay(mine, point, quat, settings, ('%.0f m in front of the player (yaw %.0f deg), %s')
            :format(settings.testAhead, degrees, where), fit or false) then
        test = nil
        return false, 'the effect was refused (the line above says why)'
    end
    CreateThread(function()
        Wait(math.floor(settings.testSeconds * 1000))
        if test == mine then
            stopWord(mine, 'the test is over')
            test = nil
        end
    end)
    return true
end

--- THE RING'S TURN (1.4.0), every `RING_MS`: each ring up on this screen
--- turned to the ring's angle now, where its sign lies -- one update a ring.
--- What the passes cost is a line once a minute while rings turn.
function L.Turn()
    local settings = L.Settings()
    if settings.ringEffect == nil or settings.ringRate == 0.0 then return end
    local vfx = Open77.vfx
    if type(vfx) ~= 'table' or type(vfx.update) ~= 'function' then return end
    local began = clock()
    local t = now()
    local angle = L.RingAngle(t, settings)
    local n = 0
    local function turn(owner)
        if owner == nil or owner.ringHandle == nil or owner.laid == nil then return end
        local laid = owner.laid
        local q = L.RingOrientation({ x = laid.qx, y = laid.qy, z = laid.qz, w = laid.qw }, angle)
        local read, ok = native('vfx.update', vfx.update, owner.ringHandle,
            { position = { x = laid.x, y = laid.y, z = laid.z }, orientation = q })
        if read and ok == true then
            n = n + 1
        else
            -- Gone (the platform, the quota, a stream-out): played again by the next look.
            counts.turnRefused = counts.turnRefused + 1
            pcall(vfx.stop, owner.ringHandle)
            owner.ringHandle = nil
        end
    end
    for _, hull in pairs(hulls) do turn(hull) end
    turn(test)
    if n == 0 then return end
    local cost = clock() - began
    counts.turns = counts.turns + n
    counts.turnMs = counts.turnMs + cost
    counts.turnPasses = (counts.turnPasses or 0) + 1
    if cost > counts.turnMax then counts.turnMax = cost end
    turnSaidAt = turnSaidAt or t
    if t - turnSaidAt >= 60000 then
        Open77.log.info(('landing sign rings: %d turn(s) in %d pass(es) over the last %.0fs, %.3f ms a pass on average, '
            .. '%.3f ms the dearest, %d refused'):format(counts.turns, counts.turnPasses, (t - turnSaidAt) / 1000.0,
            counts.turnMs / math.max(1, counts.turnPasses), counts.turnMax, counts.turnRefused))
        counts.turns, counts.turnMs, counts.turnMax, counts.turnPasses, counts.turnRefused = 0, 0.0, 0.0, 0, 0
        turnSaidAt = t
    end
end

--- What is drawn, for a diagnostic and the suite.
function L.Status()
    local out = { on = counts.on, off = counts.off, refused = counts.refused, hulls = {}, terrain = rayGroups,
        fallback = fallbackOn }
    for key, hull in pairs(hulls) do
        out.hulls[#out.hulls + 1] = { id = key, record = hull.record, up = hull.up, clearance = hull.clearance,
            ring = hull.ringHandle ~= nil,
            vz = hull.vz, at = hull.laid and { x = hull.laid.x, y = hull.laid.y, z = hull.laid.z } or nil,
            tilt = hull.fit and hull.fit.tilt or nil, busy = hull.busy == true, mine = hull.mine == true,
            whyNot = hull.whyNot }
    end
    table.sort(out.hulls, function(a, b) return a.id < b.id end)
    out.test = test ~= nil and test.up == true and { x = test.laid.x, y = test.laid.y, z = test.laid.z,
        tilt = test.fit and test.fit.tilt or nil } or nil
    return out
end

-- THE JOBS' COST (1.4.0). Every pass of every job is timed on the host's
-- clock; `COST_FIRST_MS` after the start, then every `COST_EVERY_MS`, one line
-- says what each job cost: its passes, their mean and dearest (and when), how
-- many took `COST_SLOW_MS` or more, how many failed, and (1.4.1) the dearest
-- natives (`native`, above). The same line as open77_avdoor's, to optimize on
-- from every running game. 1.4.1: a pass's own cost leaves out the frames it
-- waited in its breaths -- 1.4.0's dearest look, 532 ms on a game at four
-- frames a second, was two breaths (Staging, 2026-10-29); the longest pass
-- with its waits is said beside it.
L.COST_FIRST_MS = 60000
L.COST_EVERY_MS = 300000
L.COST_SLOW_MS = 50.0
local jobCosts, costFrom, costLines = {}, nil, 0
local clockMoved = false

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
function L.JobCosts() return jobCosts end

local function costLine(t)
    local names = {}
    for name in pairs(jobCosts) do names[#names + 1] = name end
    table.sort(names)
    local parts = {}
    for _, name in ipairs(names) do
        local row = jobCosts[name]
        if row.passes > 0 then
            if clockMoved then
                parts[#parts + 1] = ('%s %d pass(es), %.2f ms on average, %.2f ms the dearest (%.0fs ago)%s%s%s'):format(
                    name, row.passes, row.ms / row.passes, row.max, (t - (row.maxAt or t)) / 1000.0,
                    row.wallMax > row.max + 5.0 and (', the longest %.0f ms with its waits'):format(row.wallMax) or '',
                    row.slow > 0 and (', %d of %.0f ms or more'):format(row.slow, L.COST_SLOW_MS) or '',
                    row.failures > 0 and (', %d FAILED'):format(row.failures) or '')
            else
                parts[#parts + 1] = ('%s %d pass(es)%s'):format(name, row.passes,
                    row.failures > 0 and (', %d FAILED'):format(row.failures) or '')
            end
        end
    end
    if #parts > 0 then
        Open77.log.info(('job costs over the last %.0fs (%s): %s%s%s'):format((t - costFrom) / 1000.0, RESOURCE,
            table.concat(parts, '; '), clockMoved and nativesText() or '',
            clockMoved and '' or ' (this host\'s clock stands still within a pass: no pass is timed from Lua here)'))
    end
    jobCosts, costFrom, costLines = {}, t, costLines + 1
    nativeCosts = {}
end

local function costOf(name, spent, wall, failed)
    local t = now()
    local row = jobCosts[name]
    if row == nil then
        row = { passes = 0, ms = 0.0, max = 0.0, wallMax = 0.0, slow = 0, failures = 0 }
        jobCosts[name] = row
    end
    if wall > 0 then clockMoved = true end
    row.passes = row.passes + 1
    row.ms = row.ms + spent
    if wall > row.wallMax then row.wallMax = wall end
    if spent > row.max then row.max, row.maxAt = spent, t end
    if spent >= L.COST_SLOW_MS then row.slow = row.slow + 1 end
    if failed then row.failures = row.failures + 1 end
    if costFrom == nil then costFrom = t end
    if t - costFrom >= (costLines == 0 and L.COST_FIRST_MS or L.COST_EVERY_MS) then costLine(t) end
end

--- Runs `fn` every `ms` on a thread of its own until the handle is put down;
--- a pass that raises is said (once a failure) and the job goes on. Timed.
local function every(name, ms, fn)
    local job = { live = true }
    CreateThread(function()
        local me = type(coroutine) == 'table' and type(coroutine.running) == 'function' and coroutine.running() or nil
        while job.live do
            Wait(ms)
            if not job.live then break end
            local began = stamp()
            if me ~= nil then breathBy[me] = 0.0 end
            currentJob = name
            local ran, failure = pcall(fn)
            currentJob = nil
            if not ran then
                once('job:' .. tostring(failure), 'error', ('the landing sign\'s %s pass failed: %s'):format(name,
                    tostring(failure)))
            end
            local wall = stamp() - began
            local waited = me ~= nil and breathBy[me] or 0.0
            if me ~= nil then breathBy[me] = nil end
            costOf(name, math.max(0.0, wall - waited), wall, not ran)
        end
    end)
    return job
end

function L.Start()
    local settings = L.Settings()
    if settings.effect == nil then
        Open77.log.warn('open77_avlanding: no EFFECT in shared/config.lua, nothing is drawn')
        return
    end
    AddEventHandler('open77:vehicleRemoved', function(id)
        local ran, failure = pcall(L.Removed, id)
        if not ran then Open77.log.warn('a removed hull could not be dropped: ' .. tostring(failure)) end
    end)
    listJob = every('list', settings.list, L.List)
    lookJob = every('look', settings.look, L.Step)
    -- The ring's turn: its own job, so a look that breathes over a ground
    -- plane never holds the ring still.
    if settings.ringEffect ~= nil and settings.ringRate ~= 0.0 then turnJob = every('ring', settings.ringMs, L.Turn) end
    -- The test: asked by the server's `avlanding.test` (a chat hands a /command
    -- to the server), or by the same command typed in a client console.
    local function runTest(how)
        local ran, up, why = pcall(L.Test)
        if not ran then
            Open77.log.error(('avlanding.test (%s) failed: %s'):format(how, tostring(up)))
        elseif up then
            Open77.log.info(('avlanding.test (%s): the sign is on the ground %.0f m in front of you for %d s')
                :format(how, settings.testAhead, settings.testSeconds))
        else
            Open77.log.warn(('avlanding.test (%s): no sign: %s'):format(how, tostring(why)))
        end
    end
    if type(RegisterNetEvent) == 'function' then
        RegisterNetEvent('open77_avlanding:test', function() runTest('asked by the server') end)
    end
    if type(RegisterCommand) == 'function' then
        pcall(RegisterCommand, 'avlanding.test', function() runTest('this game\'s console') end, false)
    end
    Open77.log.info(('ready: "WARNING" under aircraft within %.0f m (%d at most), shown under %.1f m of clearance '
        .. 'coming down or %.1f m at rest, %.1f m ahead of the hull\'s centre, on the ground\'s plane (%d rays within '
        .. '%.1f m, %.0f deg at most), %.2f m up; effect %s; ring %s; /avlanding.test shows it')
        :format(settings.range, settings.hulls, settings.show, settings.rest, settings.ahead, #L.FitOffsets(settings),
            settings.fitRadius, settings.maxTilt, settings.lift, settings.effect,
            settings.ringEffect == nil and 'none' or ('%s, turning %.0f deg/s every %d ms'):format(settings.ringEffect,
                settings.ringRate, settings.ringMs)))
end

function L.Stop()
    stopped = true
    if lookJob ~= nil then lookJob.live = false end
    if listJob ~= nil then listJob.live = false end
    if turnJob ~= nil then turnJob.live = false end
    lookJob, listJob, turnJob = nil, nil, nil
    if test ~= nil then
        stopWord(test, 'the resource stopped')
        test = nil
    end
    for key, hull in pairs(hulls) do
        stopWord(hull, 'the resource stopped')
        hulls[key] = nil
    end
end

AddEventHandler('onClientResourceStop', function(name)
    if name == RESOURCE then L.Stop() end
end)

L.Start()
