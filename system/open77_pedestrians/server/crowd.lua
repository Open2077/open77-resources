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
Open77CrowdScheduler = {}
Open77CrowdScheduler.__index = Open77CrowdScheduler

local S = Open77PedestrianSpatial
local CELL, cellOf, cellKey, addPlayer, query = S.CELL, S.cellOf, S.cellKey, S.addPlayer, S.query
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

-- Frees the spot a walker reserved or sits at; it rests `coolS` (spotCooldownS) before the next.
function Open77CrowdScheduler:release(walker, coolS)
    local spot = walker.spot
    if not spot then return end
    walker.spot = nil
    if self.spotOccupant[spot] == walker.npc then self.spotOccupant[spot] = nil end
    self.spotCooldown[spot] = self.api.now() + (coolS or self.config.crowd.spotCooldownS)
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

-- Off the spot: its NPC gets its tasks back, then it joins the traffic on the anchor, where it stands.
function Open77CrowdScheduler:leaveSpot(walker, why)
    local spots, spot = self.spots, walker.spot
    walker.x, walker.y, walker.z = spots.spotX[spot], spots.spotY[spot], spots.spotZ[spot]
    self:release(walker)
    self.api.setAiMode(walker.npc, "tasks")
    self:walk(walker, nil, why or "stay_over")
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
    local function charge(amount)
        budget.work = budget.work + amount
        if budget.work >= config.scanWorkPerSlice and api.yield then
            api.yield()
            budget.work, budget.slices = 0, budget.slices + 1
        end
    end
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
    charge(#order * 4)

    -- The platform's rows of this resource's NPCs: where each walker is now.
    local rows, snapshot = {}, api.npcs()
    for i = 1, #snapshot do rows[tostring(snapshot[i].id)] = snapshot[i] end
    charge(#snapshot * 3)

    local streamed = c.streamingRadiusM
    local load, watchers, cells, active = {}, {}, {}, 0
    -- Event handlers run while the pass waits between slices and may drop walkers.
    local ids = {}
    for id in pairs(self.walkers) do ids[#ids + 1] = id end
    for _, id in ipairs(ids) do
        local walker = self.walkers[id]
        if walker then
            local row = rows[id]
            local cost = 8
            if not row then
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
                        if not bucketCells then bucketCells = {}; cells[walker.bucket] = bucketCells end
                        local key = cellKey(cellOf(x), cellOf(y))
                        local cell = bucketCells[key]
                        if not cell then cell = {}; bucketCells[key] = cell end
                        cell[#cell + 1] = walker
                        local _, examined = query(alive[walker.bucket], x, y, z, streamed, nil, false, watchers)
                        cost = cost + examined + 2 * #watchers
                        for i = #watchers, 1, -1 do
                            local player = watchers[i]
                            load[player] = (load[player] or 0) + 1
                            watchers[i] = nil
                        end
                    end
                end
            end
            charge(cost)
        end
    end

    -- `pedestrians.crowd off` may have landed while the pass waited between slices.
    if not self.enabled then return end
    -- Round robin over the living players by id, from the one after the last served: one spawn per
    -- player in turn, spawnsPerTick in all, so nobody is served twice before the others.
    local state = { now = now, alive = alive, load = load, cells = cells, charge = charge, active = active }
    local count, created = #order, 0
    if count > 0 then
        table.sort(order, function(a, b) return a.id < b.id end)
        local from = 1
        while from <= count and order[from].id <= self.cursor do from = from + 1 end
        if from > count then from = 1 end
        for step = 0, count - 1 do
            if created >= c.spawnsPerTick or state.active >= config.crowdMaxActive then break end
            local player = order[(from - 1 + step) % count + 1]
            self.cursor = player.id
            if self:spawnFor(state, player) then created = created + 1 end
        end
    end
    self.lastSlices = budget.slices - startSlices
end

-- One spawn attempt for `player`: up to candidateTries lanes picked at random from the lanes with
-- crowd fragments in the cells around it. A candidate point stands spawnMinM..spawnMaxM from the
-- player (and within verticalRangeM of it in height), farther than spawnMinM from every living
-- player and separationM from every walker. The first valid one gets a walker. Whether the platform
-- was asked to create one.
function Open77CrowdScheduler:spawnFor(state, player)
    local api, config, lanes = self.api, self.config, self.lanes
    local c, charge = config.crowd, state.charge
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
        if d2 >= min2 and d2 <= max2 and abs(z - player.z) <= c.verticalRangeM then
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

-- Whether no walker of `cells` (a bucket's walkers by 64 m cell) is within separationM of (x, y).
function Open77CrowdScheduler:separated(cells, x, y)
    if not cells then return true end
    local gap = self.config.crowd.separationM
    local gap2 = gap * gap
    for gx = cellOf(x - gap), cellOf(x + gap) do
        for gy = cellOf(y - gap), cellOf(y + gap) do
            local cell = cells[cellKey(gx, gy)]
            for i = 1, cell and #cell or 0 do
                local dx, dy = cell[i].x - x, cell[i].y - y
                if dx * dx + dy * dy < gap2 then return false end
            end
        end
    end
    return true
end

function Open77CrowdScheduler:create(state, player, lane, x, y, z, heading)
    local api, config, lanes = self.api, self.config, self.lanes
    local c, now = config.crowd, state.now
    self.spawns = self.spawns + 1
    local r = api.random(1, #lanes.records)
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
    local walker = { npc = tostring(npc), bucket = player.bucket, state = "walking", lane = lane,
        x = x, y = y, z = z, record = r, body = lanes.recordBody[r] or 0 }
    self.walkers[walker.npc] = walker
    state.active = state.active + 1
    local bucketCells = state.cells[player.bucket]
    if not bucketCells then bucketCells = {}; state.cells[player.bucket] = bucketCells end
    local key = cellKey(cellOf(x), cellOf(y))
    local cell = bucketCells[key]
    if not cell then cell = {}; bucketCells[key] = cell end
    cell[#cell + 1] = walker
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
function Open77CrowdScheduler:panic(npcId, source, origin)
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
    self:logTask(walker, "panic", source and "damaged" or "neighbour",
        " was=" .. was .. (shooter and (" shooter=" .. shooter) or ""))
    if not walker.task then self:abort(walker, "panic") end
end

-- Every other walker of the bucket within panicRadiusM of `origin` panics (`exceptNpc` is the
-- victim). Hits and deaths reach it through `api.panicNear`, which also scares the seated ones.
function Open77CrowdScheduler:panicNeighbours(bucket, origin, exceptNpc)
    local radius2 = self.config.panicRadiusM * self.config.panicRadiusM
    for npcId, walker in pairs(self.walkers) do
        if npcId ~= exceptNpc and walker.bucket == bucket and PANICKABLE[walker.state] then
            local dx, dy, dz = walker.x - origin.x, walker.y - origin.y, walker.z - origin.z
            if dx * dx + dy * dy + dz * dz <= radius2 then self:panic(npcId, nil, origin) end
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
    return { enabled = self.enabled, lanes = self.lanes.laneCount, points = self.lanes.pointCount,
        spots = #self.spots.spotX, slices = self.lastSlices or 0, active = active, cooldowns = cooldowns,
        failures = self.failures }
end

function Open77CrowdScheduler:reset()
    for _, walker in pairs(self.walkers) do self:drop(walker, true) end
    self.spotCooldown, self.failures, self.cursor = {}, {}, 0
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
