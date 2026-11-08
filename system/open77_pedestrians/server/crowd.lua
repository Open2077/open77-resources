-- The walking crowd: civilians that walk the game's own pedestrian traffic around every player, now
-- and then sit on a bench or use a machine of the crowd-spot catalogue, and panic (and die) together
-- with the seated pedestrians of scheduler.lua.
--
-- A walker is hosted: its NPC runs native AI (`aiMode = "tasks"`) on the client the platform elects
-- for it (`authorityPolicy = "balanced"` spreads the walkers over the clients near them), and every
-- other client replays the host's reported motion at the shared server clock
-- (`behavior.observerReplay`). It spawns on a lane of the lane catalogue and joins the game's
-- pedestrian traffic (the `traffic` task) where it stands: the native mover keeps it on the game's
-- lanes and waits at the game's lights, the server plans no route.
-- Fully native: a body in the game's traffic takes no AI command (a `moveTo` or a `flee` stays
-- enqueued and never runs), so the server only swaps traffic tasks. Panic is the crowd's own fear: a
-- traffic task at a run with a threat point. Benches are the game's own workspot visits: when the
-- host's walker enters one, the client ends its traffic task with `workspot`, and the server replays
-- the visit on every client by sitting the walker on the catalogue spot under its body (a native
-- visit alone would be seen on the host only). A walker is
--   walking   in the traffic,
--   seated    in a workspot of a catalogue spot (frozen), afterwards back on tasks and in the traffic,
--   panicking in the traffic running from a threat; it calms fleeTimeoutMs after the panic,
--   dead      a corpse that leaves on the timers.
-- A native body can get stuck: a walker in the traffic that has not moved stuckM in stuckS leaves.
--
-- Density and composition are the vanilla crowd's (crowdsets-generated.lua, from the game's crowd creation
-- registry): every crowd fragment of a lane says how many walkers the game keeps on it in each period of the day
-- (Morning, Day, Evening, Night) and which civilians, with their weights. Around each player the walkers number
-- what the fragments within densityRadiusM want for the hour of its bucket (times crowdDensity, capped by
-- crowdMaxNearPlayer); a new one appears on a fragment drawn by that want and is one of the fragment's civilians
-- for the hour: the homeless of a Watson alley, the suits of Corpo Plaza, fewer people at night. Without the
-- generated sets (an older catalogue) any fragment and any civilian of the city will do.
Open77CrowdScheduler = {}
Open77CrowdScheduler.__index = Open77CrowdScheduler

local S = Open77PedestrianSpatial
local CELL, cellOf, cellKey, addPlayer, query, countGroups = S.CELL, S.cellOf, S.cellKey, S.addPlayer, S.query, S.countGroups
local sqrt, abs, min, max = math.sqrt, math.abs, math.min, math.max

local PANICKABLE = { walking = true, seated = true }
local TERMINAL = { success = true, failure = true, cancelled = true, interrupted = true }

-- One `index` slice: lane vertices and spots examined before the rest waits for the next server tick.
local INDEX_STEPS = 6000
-- Resolution of the random draws behind `uniform` (api.random is an integer draw).
local SCALE = 10000
-- A native visit matches only spots within this height of the body, ...
local SPOT_VERTICAL_M = 3
-- ... and within this distance of it on the ground: the game's workspot puts the body 0.2 to 1.8 m from the spot node
-- (measured live 2026-10-08, when the body was first detected inside the workspot).
local SPOT_MATCH_M = 2.0
-- Diagnostics only (`[crowd] visit` lines): how far around a body no spot matched the nearest catalogue spot is looked for.
local NEAR_SPOT_M = 12

local function uniform(api, low, high) return low + (high - low) * api.random(0, SCALE) / SCALE end

-- The walkers of a bucket by 64 m cell are kept from pass to pass (tens of thousands of walkers must not cost a
-- table per cell per pass): a cell list holds `n` walkers of pass `pass`; a list of an older pass is empty.
local function cellSize(cells, cell) return (cell and cell.pass == cells.pass) and cell.n or 0 end
local function cellAdd(cells, key, walker)
    local cell = cells[key]
    if not cell then cell = { n = 0, pass = cells.pass }; cells[key] = cell end
    if cell.pass ~= cells.pass then
        for i = 1, cell.n do cell[i] = nil end
        cell.n, cell.pass = 0, cells.pass
    end
    cell.n = cell.n + 1
    cell[cell.n] = walker
end

-- Periods of the crowd sets: Morning, Day, Evening and Night start at these game minutes unless the catalogue
-- says otherwise (06:00, 10:00, 18:00, 22:00, the community periods' own starts).
local PERIOD_STARTS = { 360, 600, 1080, 1320 }

-- The period (1..4) a game minute falls in: the last that has started, Night before the first.
local function periodOf(starts, minute)
    local period = #starts
    for p = 1, #starts do
        if minute >= starts[p] then period = p end
    end
    return period
end
Open77CrowdScheduler.periodOf = periodOf

-- A record drawn from a flat { record, weight, ... } draw.
local function drawRecord(api, draw)
    local total = 0
    for i = 2, #draw, 2 do total = total + draw[i] end
    local pick = total * api.random(0, SCALE) / SCALE
    for i = 2, #draw, 2 do
        pick = pick - draw[i]
        if pick <= 0 then return draw[i - 1] end
    end
    return draw[#draw - 1]
end

-- One token of a `[crowd]` log line (key=value pairs): the platform's free-text reasons carry no whitespace into it.
local function token(value)
    value = tostring(value)
    if value == "" or value == "nil" then return "-" end
    return (value:gsub("%s+", "_"))
end

-- Cheap: the spawn-lane and spot indices are built by `index`, in slices, on the scheduler's own thread.
-- The catalogue columns are read in place.
function Open77CrowdScheduler.new(lanes, spots, config, api)
    return setmetatable({
        lanes = lanes, spots = spots, config = config, api = api, enabled = config.crowdEnabled,
        pointX = lanes.pointX, pointY = lanes.pointY, pointZ = lanes.pointZ,
        laneSpawn = lanes.laneSpawn or {},
        spawnLanes = {}, spotCells = {}, clips = {}, bodyClips = {},
        walkers = {}, spotOccupant = {}, spotCooldown = {}, failures = {},
        spawns = 0, cursor = 0, indexed = false,
        -- The crowd fragments, when the catalogue has their sets: lane, range, set, midpoint and four
        -- walkers-per-period values each (fragRate[(f - 1) * 4 + period]), listed per 64 m cell by midpoint.
        fragCount = 0, fragLane = {}, fragRange = {}, fragSet = {}, fragX = {}, fragY = {}, fragZ = {},
        fragRate = {}, fragCells = {},
        periodStarts = lanes.periodStarts or PERIOD_STARTS,
        -- Per player id: its density want, where and for which period it was worked out.
        targets = {}, overflowRetired = 0,
        -- Players holding a drawn weapon (setArmed): the drawn slot by id; since when one is missing from the list.
        armed = {}, armedGone = {}, motion = {},
        overflowCursor = 0,
    }, Open77CrowdScheduler)
end

-- One pass over ~160 k lane vertices exceeds a resource's per-call instruction quota, so
-- `api.yield` (a Wait on the scheduler thread) hands the rest of the pass to the next server tick
-- every few thousand steps.
function Open77CrowdScheduler:index()
    local lanes, spots, api, config = self.lanes, self.spots, self.api, self.config
    local steps = 0
    local function step(amount)
        steps = steps + amount
        if steps >= INDEX_STEPS and api.yield then
            steps = 0
            api.yield()
        end
    end
    local allowed, classes, laneFirst, laneSize = config.laneClasses, lanes.laneClass, lanes.laneFirst, lanes.laneSize
    local px, py = self.pointX, self.pointY
    local spawnSets, spawnRates = lanes.laneSpawnSet, lanes.laneSpawnRate
    -- Sets written for another lane catalogue (a lanes run without the registry left an old file) would point at
    -- the wrong lanes and civilians: they are ignored, and the crowd falls back to any fragment and civilian.
    if lanes.crowdSetsFor and lanes.crowdSetsFor ~= lanes.catalogSha256 then
        api.log("pedestrians: crowdsets-generated.lua was built for lane catalogue %s, not %s; the vanilla density is off",
            tostring(lanes.crowdSetsFor), tostring(lanes.catalogSha256))
        spawnSets, spawnRates = nil, nil
    end
    -- A lane is listed once per cell any of its vertices falls in: `stamp` is the last lane that
    -- listed itself in a cell.
    local stamp = {}
    for lane = 1, lanes.laneCount do
        if allowed[classes[lane]] and self.laneSpawn[lane] ~= nil then
            local first = laneFirst[lane]
            for k = first, first + laneSize[lane] - 1 do
                local key = cellKey(cellOf(px[k]), cellOf(py[k]))
                if stamp[key] ~= lane then
                    stamp[key] = lane
                    local list = self.spawnLanes[key]
                    if not list then list = {}; self.spawnLanes[key] = list end
                    list[#list + 1] = lane
                end
            end
            step(laneSize[lane] + 2)
            local sets, rates, ranges = spawnSets and spawnSets[lane], spawnRates and spawnRates[lane], self.laneSpawn[lane]
            if sets and rates then
                for k = 1, #ranges // 2 do
                    if (sets[k] or 0) > 0 then
                        local f = self.fragCount + 1
                        self.fragCount = f
                        local x, y, z = self:pointAt(lane, (ranges[2 * k - 1] + ranges[2 * k]) / 2)
                        self.fragLane[f], self.fragRange[f], self.fragSet[f] = lane, k, sets[k]
                        self.fragX[f], self.fragY[f], self.fragZ[f] = x, y, z
                        for p = 1, 4 do self.fragRate[(f - 1) * 4 + p] = rates[(k - 1) * 4 + p] or 0 end
                        local key = cellKey(cellOf(x), cellOf(y))
                        local list = self.fragCells[key]
                        if not list then list = {}; self.fragCells[key] = list end
                        list[#list + 1] = f
                        step(laneSize[lane] + 6)
                    end
                end
            end
        else
            step(1)
        end
    end
    local usable = {}
    for index, profile in ipairs(spots.profiles) do
        local clips = api.clips(profile)
        self.clips[index] = clips
        usable[index] = clips ~= nil and #clips > 0
        if not usable[index] then api.log("pedestrians: crowd profile %s has no clips; its spots are not used", profile) end
        step(1)
    end
    local xs, ys, profiles = spots.spotX, spots.spotY, spots.spotProfile
    for spot = 1, #xs do
        if usable[profiles[spot]] then
            local key = cellKey(cellOf(xs[spot]), cellOf(ys[spot]))
            local list = self.spotCells[key]
            if not list then list = {}; self.spotCells[key] = list end
            list[#list + 1] = spot
        end
        step(1)
    end
    self.indexed = true
end

-- Frees the spot a walker reserved or sits at. With `coolS` (a corpse lying there) the spot is refused for
-- that long; otherwise the next walker the game sends there may take it at once. A rest after every stay
-- refused visits the host's game had already started: its body sat or leaned, then stood up and walked
-- off when the server found the spot resting (203 of 259 refused visits on German Unstable, 2026-10-31).
-- The walker that leaves is the one kept from coming straight back, by its own visitsAt (leaveSpot).
function Open77CrowdScheduler:release(walker, coolS)
    local spot = walker.spot
    if not spot then return end
    walker.spot = nil
    if self.spotOccupant[spot] == walker.npc then self.spotOccupant[spot] = nil end
    if coolS then self.spotCooldown[spot] = self.api.now() + coolS end
end

function Open77CrowdScheduler:drop(walker, remove)
    if self.walkers[walker.npc] ~= walker then return end
    self.walkers[walker.npc] = nil
    self:release(walker)
    if remove then self.api.remove(walker.npc) end
end

-- Removes a walker that cannot go on and counts why.
function Open77CrowdScheduler:abort(walker, reason)
    self.failures[reason] = (self.failures[reason] or 0) + 1
    if self.walkers[walker.npc] == walker then self:logTask(walker, "remove", reason) end
    self:drop(walker, true)
end

-- The point `arc` metres along `lane`: x, y, z, heading (degrees about Z, forward = (-sin, cos)) and
-- the left normal of its segment.
function Open77CrowdScheduler:pointAt(lane, arc)
    local px, py, pz = self.pointX, self.pointY, self.pointZ
    local first = self.lanes.laneFirst[lane]
    local last = first + self.lanes.laneSize[lane] - 1
    if last == first then return px[first], py[first], pz[first], 0, 0, 0 end
    local seg, acc, dx, dy, len = first, 0, 0, 0, 0
    for k = first, last - 1 do
        dx, dy = px[k + 1] - px[k], py[k + 1] - py[k]
        len = sqrt(dx * dx + dy * dy)
        seg = k
        if acc + len >= arc then break end
        acc = acc + len
    end
    local t = len > 1e-6 and min(1, max(0, (arc - acc) / len)) or 0
    if len <= 1e-6 then return px[seg], py[seg], pz[seg], 0, 0, 0 end
    return px[seg] + dx * t, py[seg] + dy * t, pz[seg] + (pz[seg + 1] - pz[seg]) * t,
        math.deg(math.atan(-dx, dy)), -dy / len, dx / len
end

-- Whether `walker` may take spot `s`: nobody holds it or has just left it, and its profile has a
-- clip the walker's body fits.
function Open77CrowdScheduler:spotFree(walker, s, now)
    if self.spotOccupant[s] then return false end
    -- A player sits there (open77_seating through the seat guard, row B6): the visit is refused like one
    -- to a held spot, and the walker goes on.
    local held = self.api.seatBlocked
    if held and held(walker.bucket, self.spots.spotX[s], self.spots.spotY[s], self.spots.spotZ[s]) == true then
        return false
    end
    local cooling = self.spotCooldown[s]
    if cooling then
        if cooling > now then return false end
        self.spotCooldown[s] = nil
    end
    local spots = self.spots
    local profile = spots.spotProfile[s]
    return #S.clipsFor(self.bodyClips, spots.clipBodies, profile, walker.body, self.clips[profile]) > 0
end

-- The walker seated on (or a corpse lying) within `radius` (on the ground, 1 m in height) of (x, y, z) in
-- `bucket`, or nil: a player may not sit there (row B6).
function Open77CrowdScheduler:occupantNear(bucket, x, y, z, radius)
    local spots, r2 = self.spots, radius * radius
    for _, walker in pairs(self.walkers) do
        if walker.bucket == bucket then
            local ox, oy, oz
            if walker.state == "seated" and walker.spot then
                ox, oy, oz = spots.spotX[walker.spot], spots.spotY[walker.spot], spots.spotZ[walker.spot]
            elseif walker.state == "dead" then
                ox, oy, oz = walker.x, walker.y, walker.z
            end
            if ox then
                local dx, dy = ox - x, oy - y
                local d2 = dx * dx + dy * dy
                if d2 <= r2 and abs(oz - z) <= 1.0 then
                    return { npc = walker.npc, state = walker.state, source = "crowd", spot = walker.spot,
                        distance = math.floor(sqrt(d2) * 1000 + 0.5) / 1000 }
                end
            end
        end
    end
    return nil
end

-- The free spot nearest to the walker within SPOT_MATCH_M (and SPOT_VERTICAL_M in height), if any.
function Open77CrowdScheduler:matchSpot(walker, now)
    local spots = self.spots
    local sx, sy, sz = spots.spotX, spots.spotY, spots.spotZ
    local x, y, z = walker.x, walker.y, walker.z
    local best, bestD2 = nil, SPOT_MATCH_M * SPOT_MATCH_M
    for gx = cellOf(x - SPOT_MATCH_M), cellOf(x + SPOT_MATCH_M) do
        for gy = cellOf(y - SPOT_MATCH_M), cellOf(y + SPOT_MATCH_M) do
            local cell = self.spotCells[cellKey(gx, gy)]
            for j = 1, cell and #cell or 0 do
                local s = cell[j]
                local dx, dy = sx[s] - x, sy[s] - y
                local d2 = dx * dx + dy * dy
                if d2 <= bestD2 and abs(sz[s] - z) <= SPOT_VERTICAL_M and self:spotFree(walker, s, now) then
                    best, bestD2 = s, d2
                end
            end
        end
    end
    return best
end

-- A decision that changes a walker's task, one `[crowd] task` line each (decisions, not ticks): the offline incident
-- analyzer (scripts/research/npc-crowd-incidents.py) lines these up with the clients' recordings.
function Open77CrowdScheduler:logTask(walker, kind, reason, extra)
    self.api.log("[crowd] task npc=%s kind=%s reason=%s%s", walker.npc, kind, token(reason), extra or "")
end

-- Diagnostics for a visit no spot matched: the catalogue spot nearest to the body within NEAR_SPOT_M and why
-- matchSpot did not take it (none near, beyond SPOT_MATCH_M, at another height, or held / resting). Reads the
-- cells matchSpot reads; changes nothing.
function Open77CrowdScheduler:visitMiss(walker, now)
    local spots = self.spots
    local sx, sy, sz = spots.spotX, spots.spotY, spots.spotZ
    local x, y, z = walker.x, walker.y, walker.z
    local near2 = NEAR_SPOT_M * NEAR_SPOT_M
    local near, nearD2, anyD2 = nil, math.huge, math.huge
    for gx = cellOf(x - NEAR_SPOT_M), cellOf(x + NEAR_SPOT_M) do
        for gy = cellOf(y - NEAR_SPOT_M), cellOf(y + NEAR_SPOT_M) do
            local cell = self.spotCells[cellKey(gx, gy)]
            for j = 1, cell and #cell or 0 do
                local s = cell[j]
                local dx, dy = sx[s] - x, sy[s] - y
                local d2 = dx * dx + dy * dy
                if d2 <= near2 then
                    if d2 < anyD2 then anyD2 = d2 end
                    if d2 < nearD2 and abs(sz[s] - z) <= SPOT_VERTICAL_M then near, nearD2 = s, d2 end
                end
            end
        end
    end
    if not near then
        return anyD2 <= SPOT_MATCH_M * SPOT_MATCH_M and "wrong_height" or "no_spot_near"
    end
    local dist = sqrt(nearD2)
    if nearD2 > SPOT_MATCH_M * SPOT_MATCH_M then return "out_of_range", nil, near, dist end
    -- The nearest spot is within reach: what held matchSpot back is spotFree's (indexed spots always have clips).
    local blocked = self.spotOccupant[near] and "occupied" or "resting"
    return "no_free_spot", blocked, near, dist
end

-- The decision line of a visit report (the host's traffic task ended `success`/`workspot`): where the body
-- stood, the catalogue spot it matched and how far from it, or why none did and what was nearest (`near`).
function Open77CrowdScheduler:logVisit(walker, spot, now)
    local spots = self.spots
    local at = string.format("%.2f,%.2f,%.2f", walker.x, walker.y, walker.z)
    if spot then
        local dx, dy = spots.spotX[spot] - walker.x, spots.spotY[spot] - walker.y
        self.api.log("[crowd] visit npc=%s at=%s spot=%s dist=%.2f profile=%s result=sit reason=matched",
            walker.npc, at, spot, sqrt(dx * dx + dy * dy), token(spots.profiles[spots.spotProfile[spot]]))
        return
    end
    local reason, blocked, near, dist = self:visitMiss(walker, now)
    self.api.log("[crowd] visit npc=%s at=%s spot=none dist=- profile=- result=traffic reason=%s%s near=%s",
        walker.npc, at, reason, blocked and (" blocked=" .. blocked) or "",
        near and string.format("%s:%.2f", near, dist) or "-")
end

-- Puts the walker into the game's pedestrian traffic where it stands: the native mover walks it along
-- the game's lanes, waiting at their lights, until the task ends (it fails, or the body enters a crowd
-- workspot). `visits == false` keeps the game from
-- sending it to crowd workspots. A traffic task it still has is cancelled first, in this same call: the
-- client then keeps the body in the traffic and applies the new task in place, and as a traffic task
-- never ends by itself, a new one would only queue behind it. A walker the platform refuses the task
-- for is removed.
-- `reason` (and `kind`, `traffic` unless the walker calms) only name the decision in its `[crowd] task` line.
function Open77CrowdScheduler:walk(walker, visits, reason, kind)
    local api = self.api
    if walker.task then api.cancel(walker.npc, walker.task, "traffic") end
    local options = { speed = "walk" }
    if visits == false then options.visits = false end
    local task = api.traffic(walker.npc, options)
    if not task then
        self:abort(walker, "traffic")
        return false
    end
    walker.task, walker.state, walker.visitsAt = tostring(task), "walking", nil
    self:logTask(walker, kind or "traffic", reason or "walk", visits == false and " visits=off" or "")
    -- The stuck clock starts with the traffic.
    walker.stillX, walker.stillY, walker.stillZ, walker.movedAt = walker.x, walker.y, walker.z, api.now()
    return true
end

-- The host's walker entered one of the game's crowd workspots: its traffic task ended with `workspot`
-- and the report carries the body's placement. The catalogue spot under the body replays the visit on
-- every client: the walker sits there. With no free spot under it the walker goes on with visits
-- refused for visitRetryS, or the game would send it to the same workspot again at once.
function Open77CrowdScheduler:visited(walker)
    local api = self.api
    local now = api.now()
    local body = api.position(walker.npc)
    if body then walker.x, walker.y, walker.z = body.x, body.y, body.z end
    local spot = self:matchSpot(walker, now)
    self:logVisit(walker, spot, now)
    if spot then
        walker.spot = spot
        self.spotOccupant[spot] = walker.npc
        self:sit(walker)
    elseif self:walk(walker, false, "visit_refused") then
        walker.visitsAt = now + self.config.crowd.visitRetryS
    end
end

-- Sits the walker at the spot it holds: its body stands on the anchor (the game's own visit put it
-- there). Its NPC is frozen as the seated pedestrians' are, and plays a clip its body fits for a few seconds.
function Open77CrowdScheduler:sit(walker)
    local api, c, spots = self.api, self.config.crowd, self.spots
    local spot = walker.spot
    local profile = spots.spotProfile[spot]
    local clips = S.clipsFor(self.bodyClips, spots.clipBodies, profile, walker.body, self.clips[profile])
    api.setAiMode(walker.npc, "frozen")
    -- Not looping: a looping workspot has no end, a finite one succeeds when its duration is over.
    local options = {
        loop = false, clip = clips[api.random(1, #clips)],
        anchor = { x = spots.spotX[spot], y = spots.spotY[spot], z = spots.spotZ[spot], yaw = spots.spotYaw[spot] },
        durationMs = api.random(c.spotStayMinS, c.spotStayMaxS) * 1000,
    }
    local task = api.workspot(walker.npc, spots.profiles[profile], options)
    if task then
        walker.task, walker.state = tostring(task), "seated"
        self:logTask(walker, "workspot", "visit_sit", string.format(" spot=%s profile=%s clip=%s durationMs=%s",
            spot, token(spots.profiles[profile]), token(options.clip), options.durationMs))
        return
    end
    self:leaveSpot(walker, "workspot_refused")
end

-- Off the spot: its NPC gets its tasks back, then it joins the traffic on the anchor, where it stands, with
-- visits refused for visitRetryS so the game does not sit it straight back down where it just was.
function Open77CrowdScheduler:leaveSpot(walker, why)
    local spots, spot = self.spots, walker.spot
    walker.x, walker.y, walker.z = spots.spotX[spot], spots.spotY[spot], spots.spotZ[spot]
    self:release(walker)
    self.api.setAiMode(walker.npc, "tasks")
    if self:walk(walker, false, why or "stay_over") then
        walker.visitsAt = self.api.now() + self.config.crowd.visitRetryS
    end
end

-- Whether a walker in the traffic has stayed within stuckM of one place (where it joined, or where
-- it was last seen to move) for stuckS. The game's walkers wait at red lights for up to ~38 s
-- (measured): stuckS is well past that. A walker no client hosts is not walked at all (only clients
-- host, bots never do): its clock waits for a host instead of churning it away (a 150-bot run
-- removed 2,049 unhosted walkers as stuck in 10 minutes).
function Open77CrowdScheduler:stuck(walker, now, hosted)
    local c = self.config.crowd
    local dx, dy, dz = walker.x - walker.stillX, walker.y - walker.stillY, walker.z - walker.stillZ
    if not hosted or dx * dx + dy * dy + dz * dz >= c.stuckM * c.stuckM then
        walker.stillX, walker.stillY, walker.stillZ, walker.movedAt = walker.x, walker.y, walker.z, now
        return false
    end
    return now - walker.movedAt >= c.stuckS
end

function Open77CrowdScheduler:tick(budget)
    if not self.indexed then self:index() end
    local api, config = self.api, self.config
    if not self.enabled then
        for _, walker in pairs(self.walkers) do self:drop(walker, true) end
        return
    end
    local c, now = config.crowd, api.now()
    -- The pass is sliced as the seated one is (scheduler.lua), against the same budget.
    budget = budget or { work = 0, slices = 0 }
    local startSlices = budget.slices
    local charge = S.slicer(budget, config, api)
    -- `players` holds everyone a client streams NPCs for (the dead and dying included): retirement
    -- counts them. Only the living (`alive`) bring walkers in.
    local players, alive, byId, order = {}, {}, {}, {}
    for _, player in ipairs(api.players()) do
        byId[player.id] = player
        if config.buckets[player.bucket] then
            addPlayer(players, player.bucket, player)
            if player.alive ~= false then
                addPlayer(alive, player.bucket, player)
                order[#order + 1] = player
            end
        end
    end
    self.playersById = byId
    for id in pairs(self.targets) do
        if not byId[id] then self.targets[id] = nil end
    end
    -- A player missing from the list (loading, a bucket change) keeps its drawn weapon for a minute: no new
    -- event follows until it draws or holsters again.
    -- Each living player's direction of travel over the last second (nil standing still): spawnDense keeps new
    -- walkers out of the way ahead of it.
    for _, player in ipairs(order) do
        local m = self.motion[player.id]
        if not m then
            m = { x = player.x, y = player.y, t = now }
            self.motion[player.id] = m
        elseif now - m.t >= 1 then
            local dx, dy = player.x - m.x, player.y - m.y
            local d = sqrt(dx * dx + dy * dy)
            if d >= 1 then m.dx, m.dy = dx / d, dy / d else m.dx, m.dy = nil, nil end
            m.x, m.y, m.t = player.x, player.y, now
        end
    end
    for id in pairs(self.motion) do
        if not byId[id] then self.motion[id] = nil end
    end
    for id in pairs(self.armed) do
        if byId[id] then
            self.armedGone[id] = nil
        elseif not self.armedGone[id] then
            self.armedGone[id] = now
        elseif now - self.armedGone[id] > 60 then
            self.armed[id], self.armedGone[id] = nil, nil
        end
    end
    charge(#order * 4)

    -- The platform's rows of this resource's NPCs: where each walker is now. Keyed by the numeric id (a walker's
    -- `nid`): tens of thousands of NPCs must not cost a string each per pass. The table is kept between passes.
    local rows, snapshot = self.rowsById, api.npcs()
    if not rows then rows = {}; self.rowsById = rows end
    local pass = (self.rowsPass or 0) + 1
    self.rowsPass = pass
    for i = 1, #snapshot do
        local row = snapshot[i]
        local nid = tonumber(row.id)
        if nid then rows[nid] = row; row.seenPass = pass end
    end
    charge(#snapshot * 3)
    if pass % 120 == 0 then
        for nid, row in pairs(rows) do
            if row.seenPass ~= pass then rows[nid] = nil end
        end
    end

    -- Zone clusters (crowd.clusterLinkM): living players chained within that distance share one crowd and one
    -- budget, so fifty players in one market get a crowd sized for the market, not fifty crowds. A cluster's target is
    -- what the game keeps on the fragments around any of its players (each counted once) times crowdDensity, capped
    -- by crowdMaxNearPlayer plus clusterPerPlayer for every extra player (square root: crowds grow slower than
    -- players), and the clusters share crowdMaxActive in proportion to their targets when the server is full.
    local clusterOf, clusters = nil, nil
    if self.fragCount > 0 then
        local work
        _, work, clusterOf = countGroups(alive, c.clusterLinkM)
        charge(work)
        clusters = {}
        for _, player in ipairs(order) do
            local key = clusterOf[player]
            local cluster = clusters[key]
            if not cluster then
                cluster = { members = {}, near = 0, load = 0, stamp = 0, nearStamp = 0, key = key }
                clusters[key] = cluster
            end
            cluster.members[#cluster.members + 1] = player
        end
    end

    -- The period of the day in each bucket with players (the game clock is per bucket).
    local periods = {}
    if self.fragCount > 0 then
        for bucket in pairs(alive) do
            local seconds = api.secondsOfDay and api.secondsOfDay(bucket) or nil
            periods[bucket] = periodOf(self.periodStarts,
                math.floor(((seconds or config.fallbackSecondsOfDay or 43200) % 86400) / 60))
        end
    end
    self.periods = periods

    local streamed = c.streamingRadiusM
    local load, watchers, active = {}, {}, 0
    local cells = self.walkerCells
    if not cells then cells = {}; self.walkerCells = cells end
    for _, bucketCells in pairs(cells) do bucketCells.pass = pass end
    -- `near`: walkers within densityRadiusM of each living player (what its density want is measured against);
    -- `far` (an array kept between passes, valid up to nfar): walking walkers past spawnMaxM of every living
    -- player that some living player streams, the first to go when the hour or a move leaves too many around.
    local near, far, nfar, serial = {}, self.farList, 0, 0
    if not far then far = {}; self.farList = far end
    local density2, ring2 = c.densityRadiusM and c.densityRadiusM * c.densityRadiusM or 0, c.spawnMaxM * c.spawnMaxM
    -- Event handlers run while the pass waits between slices and may drop walkers.
    local ids = {}
    for id in pairs(self.walkers) do ids[#ids + 1] = id end
    for _, id in ipairs(ids) do
        local walker = self.walkers[id]
        if walker then
            local row = rows[walker.nid]
            local cost = 8
            if not row or row.seenPass ~= pass then
                -- Gone from the platform without a report (removed by a stop or a reload).
                self:drop(walker, false)
            else
                local x, y, z = row.x, row.y, row.z
                walker.x, walker.y, walker.z = x, y, z
                local set, retire = players[walker.bucket], true
                if set and walker.state == "dead" then
                    -- A corpse stays until every player is past the range that streams it out; past its
                    -- delay it goes once nobody stands close, past the hard limit regardless.
                    local nearest, examined = query(set, x, y, z, streamed + c.streamingHysteresisM, nil, true)
                    retire, cost = nearest == math.huge, cost + examined
                    local since = walker.diedAt
                    if not retire and now - since >= config.deadRetireS then
                        if now - since >= config.deadRetireMaxS then
                            retire = true
                        else
                            nearest, examined = query(set, x, y, z, config.corpseQuietM, nil, true)
                            retire, cost = nearest == math.huge, cost + examined
                        end
                    end
                elseif set then
                    local nearest, examined = query(set, x, y, z, c.retireRadiusM, nil, true)
                    retire, cost = nearest == math.huge, cost + examined
                    -- An exclusion zone (server/exclusions.lua): a walker that walked or fled in leaves.
                    if not retire and self.api.excluded and self.api.excluded(x, y, z) then
                        retire = true
                        self.excludedRetired = (self.excludedRetired or 0) + 1
                    end
                end
                if retire then
                    self:drop(walker, true)
                elseif walker.state == "walking" and self:stuck(walker, now, (row.authorityPlayerId or 0) ~= 0) then
                    -- A native body can get stuck against geometry: it leaves.
                    self:abort(walker, "stuck")
                else
                    -- A panic that ran its course calms, and a walker whose visits were refused may be
                    -- sent to crowd workspots again: the same traffic, replaced in place.
                    if walker.state == "panicking" and now >= walker.calmAt then
                        self:walk(walker, nil, "flee_timeout", "calm")
                    elseif walker.state == "walking" and walker.visitsAt and now >= walker.visitsAt then
                        self:walk(walker, nil, "visit_retry")
                    end
                    -- A walker the platform refused a task for is gone.
                    if self.walkers[id] == walker then
                        active = active + 1
                        local bucketCells = cells[walker.bucket]
                        if not bucketCells then bucketCells = { pass = pass }; cells[walker.bucket] = bucketCells end
                        cellAdd(bucketCells, cellKey(cellOf(x), cellOf(y)), walker)
                        local _, examined = query(alive[walker.bucket], x, y, z, streamed, nil, false, watchers)
                        cost = cost + examined + 4 * #watchers
                        local closest = math.huge
                        serial = serial + 1
                        for i = 1, #watchers do
                            local player = watchers[i]
                            load[player] = (load[player] or 0) + 1
                            local dx, dy = player.x - x, player.y - y
                            local d2 = dx * dx + dy * dy
                            if d2 <= density2 then near[player] = (near[player] or 0) + 1 end
                            if d2 < closest then closest = d2 end
                            -- Each walker counts once for each cluster streaming it, and once more for each it
                            -- stands near.
                            local cluster = clusters and clusters[clusterOf[player]]
                            if cluster then
                                if cluster.stamp ~= serial then cluster.stamp = serial; cluster.load = cluster.load + 1 end
                                if d2 <= density2 and cluster.nearStamp ~= serial then
                                    cluster.nearStamp = serial; cluster.near = cluster.near + 1
                                end
                            end
                        end
                        if self.fragCount > 0 and walker.state == "walking" and closest > ring2 and #watchers > 0 then
                            nfar = nfar + 1
                            far[nfar] = walker
                        end
                        for i = #watchers, 1, -1 do watchers[i] = nil end
                    end
                end
            end
            charge(cost)
        end
    end

    -- `pedestrians.crowd off` may have landed while the pass waited between slices.
    if not self.enabled then return end
    local state = { now = now, alive = alive, load = load, near = near, cells = cells, charge = charge,
        active = active, periods = periods, clusters = clusters, clusterOf = clusterOf }
    if clusters then self:clusterTargets(state) end
    for i = nfar + 1, #far do far[i] = nil end
    self:overflow(state, far, nfar)
    self:brandish(order, cells, charge)
    -- Round robin over the living players by id, from the one after the last served: one spawn per
    -- player in turn, spawnsPerTick in all, so nobody is served twice before the others.
    local count, created = #order, 0
    if count > 0 then
        table.sort(order, function(a, b) return a.id < b.id end)
        local from = 1
        while from <= count and order[from].id <= self.cursor do from = from + 1 end
        if from > count then from = 1 end
        -- Around again while spawns are left: a lone player gets up to spawnsPerPlayerTick a tick,
        -- not one, and never more (a client entering the world fills in over seconds).
        local perPlayer = c.spawnsPerPlayerTick or c.spawnsPerTick
        local fresh = {}
        for step = 0, math.max(count, c.spawnsPerTick) - 1 do
            if created >= c.spawnsPerTick or state.active >= config.crowdMaxActive then break end
            local player = order[(from - 1 + step) % count + 1]
            if (fresh[player.id] or 0) < perPlayer then
                self.cursor = player.id
                if self:spawnFor(state, player) then
                    created = created + 1
                    fresh[player.id] = (fresh[player.id] or 0) + 1
                end
            end
        end
    end
    self.lastSlices = budget.slices - startSlices
end

-- A cluster's target (state.clusters, built by tick): the union of what its players' fragments want (each fragment once,
-- cached per cluster shape for densityRefreshS), times crowdDensity, capped by crowdMaxNearPlayer + clusterPerPlayer *
-- sqrt(players - 1) and crowdMaxCluster; when the clusters' targets add up past crowdMaxActive, each gets its share in
-- proportion to its target.
function Open77CrowdScheduler:clusterTargets(state)
    local config, c = self.config, self.config.crowd
    local total = 0
    for _, cluster in pairs(state.clusters) do
        local members = cluster.members
        local period = state.periods[members[1].bucket] or 2
        local want = self:clusterWant(cluster, period, state.now, state.charge)
        local cap = config.crowdMaxNearPlayer + c.clusterPerPlayer * math.sqrt(#members - 1)
        cluster.want = want
        cluster.target = math.min(want, math.floor(math.min(cap, config.crowdMaxCluster) + 0.5))
        total = total + cluster.target
    end
    if total > config.crowdMaxActive and total > 0 then
        local share = config.crowdMaxActive / total
        for _, cluster in pairs(state.clusters) do cluster.target = math.floor(cluster.target * share) end
    end
    self.lastClusters = state.clusters
end

-- What the fragments within densityRadiusM of any player of `cluster` want in `period`, each fragment counted once,
-- times crowdDensity. Kept per cluster shape (its players' ids and 64 m cells) for densityRefreshS.
function Open77CrowdScheduler:clusterWant(cluster, period, now, charge)
    local c, config = self.config.crowd, self.config
    local members = cluster.members
    if #members == 1 then
        local want, work = self:targetFor(members[1], period, now)
        charge(work)
        return want
    end
    local parts = {}
    for i = 1, #members do
        local p = members[i]
        parts[i] = p.id .. ":" .. cellOf(p.x) .. ":" .. cellOf(p.y)
    end
    table.sort(parts)
    local shape = period .. "|" .. table.concat(parts, ";")
    local cache = self.clusterCache
    if not cache then cache = {}; self.clusterCache = cache end
    local cached = cache[shape]
    if cached and now - cached.at < c.densityRefreshS then return cached.want end
    local stamp = (self.fragStampSerial or 0) + 1
    self.fragStampSerial = stamp
    local stamps = self.fragStamp
    if not stamps then stamps = {}; self.fragStamp = stamps end
    local radius = c.densityRadiusM
    local r2, span = radius * radius, math.ceil(radius / CELL)
    local fx, fy, fz, rate = self.fragX, self.fragY, self.fragZ, self.fragRate
    local sum, cost = 0, 0
    for i = 1, #members do
        local player = members[i]
        local cx, cy = cellOf(player.x), cellOf(player.y)
        for gx = cx - span, cx + span do
            for gy = cy - span, cy + span do
                local cell = self.fragCells[cellKey(gx, gy)]
                cost = cost + 1 + (cell and #cell or 0)
                for j = 1, cell and #cell or 0 do
                    local f = cell[j]
                    if stamps[f] ~= stamp then
                        local dx, dy = fx[f] - player.x, fy[f] - player.y
                        if dx * dx + dy * dy <= r2 and abs(fz[f] - player.z) <= c.verticalRangeM then
                            stamps[f] = stamp
                            sum = sum + rate[(f - 1) * 4 + period]
                        end
                    end
                end
            end
        end
    end
    charge(cost)
    local want = math.floor(sum * config.crowdDensity + 0.5)
    -- Shapes change as players move: the cache is dropped whole when it grows, a shape costs one entry a refresh.
    self.clusterCacheSize = (self.clusterCacheSize or 0) + 1
    if self.clusterCacheSize > 512 then cache = {}; self.clusterCache = cache; self.clusterCacheSize = 1 end
    cache[shape] = { want = want, at = now }
    return want
end

-- How many walkers `player` wants around it in `period`: what the game keeps on the crowd fragments within
-- densityRadiusM of it, times crowdDensity, rounded; worked out again once the player has moved densityRefreshM,
-- the period changed or densityRefreshS went by. The second result is the work done.
function Open77CrowdScheduler:targetFor(player, period, now)
    local c, config = self.config.crowd, self.config
    local cached = self.targets[player.id]
    if cached and cached.period == period and now - cached.at < c.densityRefreshS
            and abs(cached.x - player.x) < c.densityRefreshM and abs(cached.y - player.y) < c.densityRefreshM then
        return cached.want, 1
    end
    local radius = c.densityRadiusM
    local r2, span = radius * radius, math.ceil(radius / CELL)
    local cx, cy = cellOf(player.x), cellOf(player.y)
    local fx, fy, fz, rate = self.fragX, self.fragY, self.fragZ, self.fragRate
    local sum, cost = 0, 0
    for gx = cx - span, cx + span do
        for gy = cy - span, cy + span do
            local cell = self.fragCells[cellKey(gx, gy)]
            cost = cost + 1
            for i = 1, cell and #cell or 0 do
                local f = cell[i]
                local dx, dy = fx[f] - player.x, fy[f] - player.y
                if dx * dx + dy * dy <= r2 and abs(fz[f] - player.z) <= c.verticalRangeM then
                    sum = sum + rate[(f - 1) * 4 + period]
                end
            end
            cost = cost + (cell and #cell or 0)
        end
    end
    local want = math.floor(sum * config.crowdDensity + 0.5)
    if not cached then cached = {}; self.targets[player.id] = cached end
    cached.x, cached.y, cached.period, cached.at, cached.want = player.x, player.y, period, now, want
    return want, cost
end

-- Too many walkers around: the hour moved to a quieter period, or players walked from a market into a back
-- street. A walker past spawnMaxM of every living player goes (out of the ring walkers appear in, so nobody
-- watches it vanish close by) while every living player streaming it holds more than overflowFactor times its
-- want plus overflowSlack; at most overflowRetiresPerTick a tick, the rest on the next ones.
function Open77CrowdScheduler:overflow(state, far, count)
    local c, api = self.config.crowd, self.api
    if count == 0 or (c.overflowRetiresPerTick or 0) <= 0 then return end
    -- At most 32 walkers a tick, from where the last pass stopped: the first ones of the list may all be a dense
    -- area's that never overflow, and the others' turn must come.
    local watchers, retired, examined = {}, 0, 0
    local start = self.overflowCursor % count
    for step = 1, count do
        if retired >= c.overflowRetiresPerTick or examined >= 32 then break end
        local i = (start + step - 1) % count + 1
        self.overflowCursor = i
        local walker = far[i]
        if self.walkers[walker.npc] == walker and walker.state == "walking" then
            examined = examined + 1
            local set = state.alive[walker.bucket]
            local period = state.periods[walker.bucket] or 2
            local _, cost = query(set, walker.x, walker.y, walker.z, c.streamingRadiusM, nil, false, watchers)
            local over = #watchers > 0
            local clusters, clusterOf = state.clusters, state.clusterOf
            for j = 1, #watchers do
                local player = watchers[j]
                local cluster = clusters and clusters[clusterOf[player]]
                if cluster then
                    -- The cluster streaming it holds more than its target: its budget, not each player's.
                    if cluster.load <= cluster.target * c.overflowFactor + c.overflowSlack then over = false end
                else
                    local want, work = self:targetFor(player, period, state.now)
                    cost = cost + work
                    if (state.load[player] or 0) <= want * c.overflowFactor + c.overflowSlack then over = false end
                end
            end
            if over then
                local seen = {}
                for j = 1, #watchers do
                    local player = watchers[j]
                    state.load[player] = state.load[player] - 1
                    local cluster = clusters and clusters[clusterOf[player]]
                    if cluster and not seen[cluster] then seen[cluster] = true; cluster.load = cluster.load - 1 end
                end
                retired = retired + 1
                self.overflowRetired = self.overflowRetired + 1
                self:logTask(walker, "remove", "overflow")
                self:drop(walker, true)
                state.active = state.active - 1
            end
            for j = #watchers, 1, -1 do watchers[j] = nil end
            state.charge(cost + 4)
        end
    end
end

-- One spawn attempt for `player`: up to candidateTries lanes picked at random from the lanes with
-- crowd fragments in the cells around it. A candidate point stands spawnMinM..spawnMaxM from the
-- player (and within verticalRangeM of it in height), farther than spawnMinM from every living
-- player and separationM from every walker. The first valid one gets a walker. Whether the platform
-- was asked to create one. With the vanilla crowd sets the fragment is drawn by what it wants for the hour
-- (spawnDense) instead.
function Open77CrowdScheduler:spawnFor(state, player)
    local api, config, lanes = self.api, self.config, self.lanes
    local c, charge = config.crowd, state.charge
    -- With the vanilla sets the cap counts the walkers within densityRadiusM (spawnDense); the streamed ones, which
    -- include those walking off past it until overflow recycles them, are only held under half as many again.
    if self.fragCount > 0 then
        -- In a zone cluster the cluster's budget is the cap, however many players share it.
        local cluster = state.clusters and state.clusters[state.clusterOf[player]]
        if cluster then
            if cluster.load >= cluster.target * 1.5 + 2 then return false end
        elseif (state.load[player] or 0) >= config.crowdMaxNearPlayer * 1.5 then
            return false
        end
        return self:spawnDense(state, player)
    end
    if (state.load[player] or 0) >= config.crowdMaxNearPlayer then return false end
    local span = math.ceil(c.spawnMaxM / CELL)
    local cx, cy = cellOf(player.x), cellOf(player.y)
    local window, n, cost = {}, 0, 0
    for gx = cx - span, cx + span do
        for gy = cy - span, cy + span do
            local cell = self.spawnLanes[cellKey(gx, gy)]
            cost = cost + 1
            for i = 1, cell and #cell or 0 do
                n = n + 1
                window[n] = cell[i]
            end
        end
    end
    charge(cost + n)
    if n == 0 then return false end
    local min2, max2 = c.spawnMinM * c.spawnMinM, c.spawnMaxM * c.spawnMaxM
    for _ = 1, c.candidateTries do
        local lane = window[api.random(1, n)]
        local ranges = self.laneSpawn[lane]
        local range = api.random(1, #ranges // 2)
        local arc = uniform(api, ranges[2 * range - 1], ranges[2 * range])
        local x, y, z, heading, nx, ny = self:pointAt(lane, arc)
        local offset = uniform(api, -0.35, 0.35) * lanes.laneWidth[lane]
        x, y = x + nx * offset, y + ny * offset
        local dx, dy = x - player.x, y - player.y
        local d2 = dx * dx + dy * dy
        cost = lanes.laneSize[lane] + 6
        if d2 >= min2 and d2 <= max2 and abs(z - player.z) <= c.verticalRangeM and not (api.excluded and api.excluded(x, y, z)) then
            local nearest, examined = query(state.alive[player.bucket], x, y, z, c.spawnMinM, nil, true)
            cost = cost + examined
            if nearest == math.huge and self:separated(state.cells[player.bucket], x, y) then
                self:create(state, player, lane, x, y, z, heading)
                charge(cost + 20)
                return true
            end
        end
        charge(cost)
    end
    return false
end

-- The vanilla spawn: below its want for the hour (targetFor), the player gets a walker on a crowd fragment of
-- the cells around it, drawn by what the fragment wants in that period (a busy sidewalk more often than a quiet
-- one, a fragment that wants nobody at this hour never), at a random arc of it; the point must pass the checks
-- spawnFor names. The walker is one of the fragment's civilians for the hour, by the game's weights.
function Open77CrowdScheduler:spawnDense(state, player)
    local api, config, lanes = self.api, self.config, self.lanes
    local c, charge = config.crowd, state.charge
    local period = state.periods[player.bucket] or 2
    local want, work = self:targetFor(player, period, state.now)
    charge(work)
    -- In a cluster: under the cluster's target, the walker goes to a player still short of its own want (an edge
    -- of the group the crowd has not reached yet). Alone: the player's want, capped by crowdMaxNearPlayer.
    local cluster = state.clusters and state.clusters[state.clusterOf[player]]
    if cluster then
        if cluster.near >= cluster.target or (state.near[player] or 0) >= want then return false end
    elseif (state.near[player] or 0) >= math.min(want, self.config.crowdMaxNearPlayer) then
        return false
    end
    local heading = self.motion[player.id]
    local dirX, dirY = heading and heading.dx, heading and heading.dy
    local ahead2 = (c.aheadM or 0) * (c.aheadM or 0)
    local span = math.ceil(c.spawnMaxM / CELL)
    local cx, cy = cellOf(player.x), cellOf(player.y)
    local window, n, total, cost = self.window, 0, 0, 0
    if not window then window = {}; self.window = window end
    local rate, fz = self.fragRate, self.fragZ
    for gx = cx - span, cx + span do
        for gy = cy - span, cy + span do
            local cell = self.fragCells[cellKey(gx, gy)]
            cost = cost + 1
            for i = 1, cell and #cell or 0 do
                local f = cell[i]
                local r = rate[(f - 1) * 4 + period]
                if r > 0 and abs(fz[f] - player.z) <= c.verticalRangeM + 20 then
                    n = n + 1
                    window[n] = f
                    total = total + r
                end
            end
            cost = cost + (cell and #cell or 0)
        end
    end
    charge(cost)
    if n == 0 or total <= 0 then return false end
    local min2, max2 = c.spawnMinM * c.spawnMinM, c.spawnMaxM * c.spawnMaxM
    for _ = 1, c.candidateTries do
        local pick, f = total * api.random(0, SCALE) / SCALE, window[n]
        for i = 1, n do
            pick = pick - rate[(window[i] - 1) * 4 + period]
            if pick <= 0 then f = window[i]; break end
        end
        local lane, k = self.fragLane[f], self.fragRange[f]
        local ranges = self.laneSpawn[lane]
        local arc = uniform(api, ranges[2 * k - 1], ranges[2 * k])
        local x, y, z, heading, nx, ny = self:pointAt(lane, arc)
        local offset = uniform(api, -0.35, 0.35) * lanes.laneWidth[lane]
        x, y = x + nx * offset, y + ny * offset
        local dx, dy = x - player.x, y - player.y
        local d2 = dx * dx + dy * dy
        cost = n + lanes.laneSize[lane] + 6
        -- In front of a walking player and close: it would appear in view.
        local inView = dirX and d2 < ahead2 and (dx * dirX + dy * dirY) > c.aheadCos * sqrt(d2)
        if not inView and d2 >= min2 and d2 <= max2 and abs(z - player.z) <= c.verticalRangeM
            and not (api.excluded and api.excluded(x, y, z)) then
            local nearest, examined = query(state.alive[player.bucket], x, y, z, c.spawnMinM, nil, true)
            cost = cost + examined
            if nearest == math.huge and self:separated(state.cells[player.bucket], x, y) then
                local draw = lanes.crowdDraws[lanes.crowdSets[self.fragSet[f]][period]]
                local record = draw and #draw >= 2 and drawRecord(api, draw) or nil
                if record then
                    self:create(state, player, lane, x, y, z, heading, record)
                    state.near[player] = (state.near[player] or 0) + 1
                    if cluster then cluster.near, cluster.load = cluster.near + 1, cluster.load + 1 end
                    charge(cost + 20)
                    return true
                end
            end
        end
        charge(cost)
    end
    return false
end

-- A living player holding a drawn weapon scares the walkers within brandishRadiusM of it (3 m in height): they run
-- from it in the game's traffic, as a panic. `cells` are the pass's walkers by bucket and 64 m cell.
function Open77CrowdScheduler:brandish(order, cells, charge)
    local config = self.config
    if not config.panic or not config.brandishPanic or next(self.armed) == nil then return end
    local radius = config.crowd.brandishRadiusM
    local r2 = radius * radius
    for _, player in ipairs(order) do
        if self.armed[player.id] then
            local bucketCells, cost = cells[player.bucket], 1
            if bucketCells then
                for gx = cellOf(player.x - radius), cellOf(player.x + radius) do
                    for gy = cellOf(player.y - radius), cellOf(player.y + radius) do
                        local cell = bucketCells[cellKey(gx, gy)]
                        local size = cellSize(bucketCells, cell)
                        for i = 1, size do
                            local walker = cell[i]
                            local dx, dy, dz = walker.x - player.x, walker.y - player.y, walker.z - player.z
                            if walker.state == "walking" and self.walkers[walker.npc] == walker and
                                    dx * dx + dy * dy <= r2 and abs(dz) <= 3 then
                                self:panic(walker.npc, "player:" .. player.id, player, "brandish")
                            end
                        end
                        cost = cost + 1 + size
                    end
                end
            end
            charge(cost)
        end
    end
end

-- onPlayerWeaponChanged, raised once per changed slot: `slot` is drawn (`drawn`) or not. The player is armed while
-- the slot last seen drawn stays so; an event about another slot (a pickup into slot 2 while slot 1 is drawn, the
-- whole loadout republished on connect) changes nothing.
function Open77CrowdScheduler:setArmed(playerId, slot, drawn)
    if not playerId then return end
    if drawn then
        self.armed[playerId] = slot or true
    elseif self.armed[playerId] == (slot or true) then
        self.armed[playerId] = nil
    end
end

-- Whether no walker of `cells` (a bucket's walkers by 64 m cell) is within separationM of (x, y).
function Open77CrowdScheduler:separated(cells, x, y)
    if not cells then return true end
    local gap = self.config.crowd.separationM
    local gap2 = gap * gap
    for gx = cellOf(x - gap), cellOf(x + gap) do
        for gy = cellOf(y - gap), cellOf(y + gap) do
            local cell = cells[cellKey(gx, gy)]
            for i = 1, cellSize(cells, cell) do
                local dx, dy = cell[i].x - x, cell[i].y - y
                if dx * dx + dy * dy < gap2 then return false end
            end
        end
    end
    return true
end

-- `record` is the walker's record index; any civilian of the catalogue when it is nil.
function Open77CrowdScheduler:create(state, player, lane, x, y, z, heading, record)
    local api, config, lanes = self.api, self.config, self.lanes
    local c, now = config.crowd, state.now
    self.spawns = self.spawns + 1
    local r = record or api.random(1, #lanes.records)
    local pool = lanes.appearancePools[r]
    -- On tasks with native AI: the platform elects a host for it (balanced: the nearby client with the
    -- fewest NPCs to host) and every other client replays the host's motion.
    local npc, reason = api.create({
        record = lanes.records[r], appearance = pool[(self.spawns - 1) % #pool + 1],
        position = { x = x, y = y, z = z }, yaw = heading,
        bucket = player.bucket, aiMode = "tasks", authorityPolicy = "balanced",
        damagePolicy = config.mortal and "mortal" or "immortal",
        streamingRadius = c.streamingRadiusM, streamingHysteresis = c.streamingHysteresisM,
        -- vehicleContactEnabled: a car hit is reported by the host and played as one knockdown on every copy; without
        -- it each client ran the game's own hit on its copy, and the host's fell while the others stayed up.
        behavior = { aiEnabled = true, combatEnabled = false, perceptionEnabled = false, voiceEnabled = false,
            observerReplay = true, vehicleContactEnabled = true },
    })
    if not npc then
        reason = tostring(reason or "unknown")
        self.failures[reason] = (self.failures[reason] or 0) + 1
        return
    end
    local walker = { npc = tostring(npc), nid = tonumber(npc), bucket = player.bucket, state = "walking", lane = lane,
        x = x, y = y, z = z, record = r, body = lanes.recordBody[r] or 0 }
    self.walkers[walker.npc] = walker
    state.active = state.active + 1
    local bucketCells = state.cells[player.bucket]
    if not bucketCells then bucketCells = { pass = self.rowsPass }; state.cells[player.bucket] = bucketCells end
    cellAdd(bucketCells, cellKey(cellOf(x), cellOf(y)), walker)
    local watchers = {}
    local _, examined = query(state.alive[player.bucket], x, y, z, c.streamingRadiusM, nil, false, watchers)
    for i = 1, #watchers do state.load[watchers[i]] = (state.load[watchers[i]] or 0) + 1 end
    state.charge(examined + 2 * #watchers)
    self:walk(walker, nil, "spawn")
    if self.walkers[walker.npc] ~= walker then state.active = state.active - 1 end
end

-- A walker panics: whatever it was doing stops (a seated one gets its tasks back first) and it runs
-- from the threat in the game's own traffic, where the game's crowd fear drives it: a walker in the
-- traffic takes no command, and a traffic task that replaces its own in this call keeps the body in
-- the traffic. The threat is the shooter's position when known, else `origin` (where the hit or the
-- death was). It calms fleeTimeoutMs later. One already panicking keeps its flight.
function Open77CrowdScheduler:panic(npcId, source, origin, why)
    local walker = self.walkers[npcId]
    if not walker or not PANICKABLE[walker.state] then return end
    local api, config = self.api, self.config
    local was = walker.state
    if walker.task then
        api.cancel(npcId, walker.task, "panic")
        walker.task = nil
    end
    if walker.state == "seated" then
        api.setAiMode(npcId, "tasks")
        self:release(walker)
    end
    local shooter = tonumber(tostring(source or ""):match("^player:(%d+)$"))
    local point = shooter and self.playersById and self.playersById[shooter] or origin
    local task = api.traffic(npcId, { speed = "run", threat = { x = point.x, y = point.y, z = point.z } })
    walker.state, walker.visitsAt = "panicking", nil
    walker.calmAt = api.now() + config.fleeTimeoutMs / 1000
    walker.task = task and tostring(task) or nil
    self:logTask(walker, "panic", why or (source and "damaged" or "neighbour"),
        " was=" .. was .. (shooter and (" shooter=" .. shooter) or ""))
    if not walker.task then self:abort(walker, "panic") end
end

-- Every other walker of the bucket within `radius` (default panicRadiusM) of `origin` panics (`exceptNpc` is
-- the victim). Hits and deaths reach it through `api.panicNear`, which also scares the seated ones; gunfire
-- names its shooter (`source`, `player:<id>`), whom the walkers run from.
function Open77CrowdScheduler:panicNeighbours(bucket, origin, exceptNpc, radius, source)
    radius = radius or self.config.panicRadiusM
    local radius2 = radius * radius
    for npcId, walker in pairs(self.walkers) do
        if npcId ~= exceptNpc and walker.bucket == bucket and PANICKABLE[walker.state] then
            local dx, dy, dz = walker.x - origin.x, walker.y - origin.y, walker.z - origin.z
            if dx * dx + dy * dy + dz * dz <= radius2 then self:panic(npcId, source, origin, source and "gunfire" or nil) end
        end
    end
end

-- Player -> NPC hits reach the server only as the shooter's own report (`open77:npcHit`), so accept
-- one only for a live walker that player can actually be looking at: same bucket, inside the
-- streaming range of where it is.
function Open77CrowdScheduler:admitHit(npcId, playerId)
    local walker = self.walkers[tostring(npcId)]
    if not walker or walker.state == "dead" then return false end
    local player = self.playersById and self.playersById[playerId]
    if not player or player.alive == false then return false end
    local c = self.config.crowd
    local range = c.streamingRadiusM + c.streamingHysteresisM
    local dx, dy, dz = player.x - walker.x, player.y - walker.y, player.z - walker.z
    return player.bucket == walker.bucket and dx * dx + dy * dy + dz * dz <= range * range
end

-- A shot the shooter's client reported: a mortal walker takes the damage (the platform's
-- onNpcDamaged then panics it), an immortal one is only startled.
function Open77CrowdScheduler:onHit(npcId, playerId)
    if not self:admitHit(npcId, playerId) then return end
    local source = "player:" .. playerId
    if self.config.mortal then self.api.damage(npcId, self.config.hitDamage, source)
    else self:onDamaged(npcId, source) end
end

-- Whether the platform still counts the NPC alive. A killing blow reports its damage and the end of
-- the NPC's tasks before its death: those reports are left to `onDied`, which keeps the corpse.
function Open77CrowdScheduler:living(npcId)
    return not self.api.alive or self.api.alive(npcId)
end

function Open77CrowdScheduler:onDamaged(npcId, source)
    local walker = self.walkers[npcId]
    -- A car kills a mortal walker, as the game's cars kill its pedestrians (and the seated ones here, whose hit the
    -- driver reports with the game's own price). A walker's contact is priced by the platform on the players'
    -- curve, 10 HP at a walk to 90 HP at 30 m/s: a 100 HP walker outlived four hits (live 2026-10-09).
    if walker and self.config.mortal and tostring(source):sub(1, 8) == "vehicle:" and self:living(npcId) then
        -- Not re-entered: the kill reports its own damage at once, and a walker the policy change missed stays at 1 HP.
        if not walker.striking then
            walker.striking = true
            self.api.damage(npcId, 1e6, source, "vehicle_contact")
            walker.striking = nil
        end
        return
    end
    if not self.config.panic then return end
    if not walker or not PANICKABLE[walker.state] or not self:living(npcId) then return end
    local origin = { x = walker.x, y = walker.y, z = walker.z }
    self:panic(npcId, source, origin)
    self.api.panicNear(walker.bucket, origin, npcId)
end

function Open77CrowdScheduler:onDied(npcId)
    local walker = self.walkers[npcId]
    if not walker or walker.state == "dead" then return end
    local origin = { x = walker.x, y = walker.y, z = walker.z }
    local c, config = self.config.crowd, self.config
    -- A corpse on a bench keeps it for as long as it stays.
    self:release(walker, max(c.spotCooldownS, config.deadRetireMaxS))
    walker.state, walker.diedAt, walker.task = "dead", self.api.now(), nil
    self:logTask(walker, "dead", "died")
    if config.panic then self.api.panicNear(walker.bucket, origin, npcId) end
end

-- The end of the walker's current task: it is over, so there is nothing left of it to cancel.
function Open77CrowdScheduler:onTaskState(npcId, taskId, status, reason)
    if not TERMINAL[status] then return end
    local walker = self.walkers[npcId]
    if walker and walker.task ~= tostring(taskId) then
        -- A report of a task the server already replaced: ignored, but a terminal that is not the cancel of
        -- its own replacement is a decision racing a report, and it is logged.
        if status ~= "cancelled" then
            self:logTask(walker, "ignored", "stale_task", string.format(" status=%s why=%s task=%s current=%s",
                status, token(reason), token(taskId), token(walker.task)))
        end
        return
    end
    if not walker or not self:living(npcId) then return end
    walker.task = nil
    if walker.state == "seated" then
        -- Its stay is over: off the bench, into the traffic.
        local why = "stay_over"
        if status ~= "success" then
            why = "workspot_" .. status .. ((reason ~= nil and reason ~= "") and (":" .. tostring(reason)) or "")
        end
        self:leaveSpot(walker, why)
    elseif walker.state == "walking" and status == "success" and reason == "workspot" then
        self:visited(walker)
    else
        -- A traffic task never ends by itself, a walking or panicking walker's included: it only fails
        -- when the native mover cannot walk the body, and the walker leaves.
        self:abort(walker, (reason ~= nil and reason ~= "") and tostring(reason) or status)
    end
end

function Open77CrowdScheduler:onRemoved(npcId)
    local walker = self.walkers[npcId]
    if walker then self:drop(walker, false) end
end

function Open77CrowdScheduler:status()
    local active, cooldowns, now = {}, 0, self.api.now()
    for _, walker in pairs(self.walkers) do
        local bucket = active[walker.bucket] or { walking = 0, seated = 0, panicking = 0, dead = 0 }
        bucket[walker.state] = bucket[walker.state] + 1
        active[walker.bucket] = bucket
    end
    for _, expires in pairs(self.spotCooldown) do
        if expires > now then cooldowns = cooldowns + 1 end
    end
    -- Density: the fragments with vanilla sets, the period of each bucket and, per player, its want and how
    -- many walkers stand within densityRadiusM of it (the last pass's count).
    local wants = {}
    for id, target in pairs(self.targets) do wants[id] = target.want end
    return { enabled = self.enabled, lanes = self.lanes.laneCount, points = self.lanes.pointCount,
        spots = #self.spots.spotX, slices = self.lastSlices or 0, active = active, cooldowns = cooldowns,
        failures = self.failures, fragments = self.fragCount, periods = self.periods or {}, wants = wants,
        density = self.config.crowdDensity, overflowRetired = self.overflowRetired }
end

function Open77CrowdScheduler:reset()
    for _, walker in pairs(self.walkers) do self:drop(walker, true) end
    self.spotCooldown, self.failures, self.cursor, self.targets = {}, {}, 0, {}
end

-- `pedestrians.density <factor>`: the share of the game's own crowd that walks (0..4); wants are worked out
-- again at once.
function Open77CrowdScheduler:setDensity(factor)
    self.config.crowdDensity = factor
    self.targets = {}
end

function Open77CrowdScheduler:setEnabled(flag)
    self.enabled = flag
end

-- Runtime switches behind `pedestrians.mortal` / `pedestrians.panic`: living walkers take the new
-- damage policy at once; new spawns, hits and deaths read the config.
function Open77CrowdScheduler:setMortal(flag)
    self.config.mortal = flag
    local policy = flag and "mortal" or "immortal"
    for npcId, walker in pairs(self.walkers) do
        if walker.state ~= "dead" then self.api.setDamagePolicy(npcId, policy) end
    end
end

function Open77CrowdScheduler:setPanic(flag)
    self.config.panic = flag
end
