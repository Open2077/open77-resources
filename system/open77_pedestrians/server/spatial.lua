-- Helpers shared by the seated scheduler (scheduler.lua) and the walking crowd (crowd.lua): the 64 m
-- player grid, the nearest-player query, the candidate list, the player groups and the body-gated
-- clip lists.

-- Players and spots sit in 64 m cells under one integer key: a string key costs a concatenation
-- and an intern on every lookup.
local CELL = 64
local function cellOf(v) return math.floor(v / CELL) end
local function cellKey(cx, cy) return (cx + 32768) * 65536 + cy + 32768 end

-- The players of one bucket, as a list and by cell.
local function addPlayer(sets, bucket, player)
    local set = sets[bucket]
    if not set then set = { list = {}, cells = {} }; sets[bucket] = set end
    set.list[#set.list + 1] = player
    local key = cellKey(cellOf(player.x), cellOf(player.y))
    local cell = set.cells[key]
    if not cell then cell = {}; set.cells[key] = cell end
    cell[#cell + 1] = player
    set.near = nil
end

-- The players of `set` a point of cell (cx, cy) can have within `radius`: those within it of the
-- cell's square, in the order the window walk reads them (cells by gx, then gy, ascending; a cell's
-- players in list order), so a query over them finds what the walk found, first match and ties
-- included. A pass queries the same few hundred cells thousands of times: each list is built once
-- per set, for the radius rounded up to 8 m (the query still tests its own radius), and the second
-- result is what building it cost.
local RADIUS_STEP = 8
local function candidates(set, cx, cy, radius)
    local near = set.near
    if not near then near = {}; set.near = near end
    local class = math.ceil(radius / RADIUS_STEP)
    local key = cellKey(cx, cy) * 1024 + class
    local found = near[key]
    if found then return found, 0 end
    found = {}
    local reach = class * RADIUS_STEP
    local reach2, span = reach * reach, math.ceil(reach / CELL)
    local left, bottom = cx * CELL, cy * CELL
    local cells, n, cost = set.cells, 0, 0
    for gx = cx - span, cx + span do
        local row = (gx + 32768) * 65536 + 32768
        for gy = cy - span, cy + span do
            local list = cells[row + gy]
            cost = cost + 1
            if list then
                for i = 1, #list do
                    local player = list[i]
                    local px, py = player.x, player.y
                    local ex = px < left and left - px or math.max(0, px - left - CELL)
                    local ey = py < bottom and bottom - py or math.max(0, py - bottom - CELL)
                    if ex * ex + ey * ey <= reach2 then
                        n = n + 1
                        found[n] = player
                    end
                end
                cost = cost + #list
            end
        end
    end
    near[key] = found
    return found, cost
end

-- The distance from (x, y, z) to the nearest player of `set` within `radius`, or math.huge. With
-- `vertical`, the distance is on the ground and a player more than `vertical` above or below does
-- not count (activation); without it, the distance is 3D, the sphere the server streams NPCs in.
-- `stop` returns the first one found instead of the nearest, `out` collects every one. The second
-- result is the work done (cells and players examined), which the tick charges against its slice,
-- the third the nearest player found.
-- A set with fewer players than the window has cells is read whole; otherwise only the players
-- of its `candidates` for the point's cell are, listed for `reach` (default `radius`): a caller whose
-- radius shrinks query by query names the largest, so one list serves them all.
local function query(set, x, y, z, radius, vertical, stop, out, reach)
    if not set then return math.huge, 1 end
    local players, r2, best, who = set.list, radius * radius, math.huge, nil
    reach = reach and reach > radius and reach or radius
    local span = math.ceil(reach / CELL)
    local examined = 2
    if #players > (2 * span + 1) * (2 * span + 1) then
        local built
        players, built = candidates(set, cellOf(x), cellOf(y), reach)
        examined = examined + built
    end
    for i = 1, #players do
        local player = players[i]
        local dx, dy, dz = player.x - x, player.y - y, player.z - z
        local d2 = dx * dx + dy * dy
        if not vertical then
            d2 = d2 + dz * dz
        elseif dz > vertical or dz < -vertical then
            d2 = math.huge
        end
        if d2 <= r2 then
            if out then out[#out + 1] = player end
            if d2 < best then best, who = d2, player end
            if stop then return math.sqrt(best), examined + i, who end
        end
    end
    return math.sqrt(best), examined + #players, who
end

-- A pass's slicing: `charge(amount)` adds the work done and hands the rest of the pass to the next
-- server tick once this resume has run config.sliceMs on `api.clock` (a clock that moves within a
-- resume; read every CLOCK_EVERY units) or done config.scanWorkPerSlice units, the bound that keeps
-- a resume inside the instruction quota (and the only one without a clock). `budget` ({ work,
-- slices }) is the pass's, shared by the passes of one server tick.
local CLOCK_EVERY = 1000
local function slicer(budget, config, api)
    local clock, slice, limit = api.clock, (config.sliceMs or 0) / 1000, config.scanWorkPerSlice
    if clock and not budget.since then budget.since, budget.checkAt = clock(), CLOCK_EVERY end
    return function(amount)
        local work = budget.work + amount
        budget.work = work
        if not api.yield then return end
        local over = work >= limit
        if not over and clock and work >= (budget.checkAt or 0) then
            budget.checkAt = work + CLOCK_EVERY
            over = clock() - budget.since >= slice
        end
        if over then
            api.yield()
            budget.work, budget.slices, budget.checkAt = 0, budget.slices + 1, CLOCK_EVERY
            if clock then budget.since = clock() end
        end
    end
end

-- Keeps `list` the `keep` best candidates, nearest first, ties broken by key.
local function before(a, b)
    if a.distance == b.distance then return a.key < b.key end
    return a.distance < b.distance
end

local function offer(list, candidate, keep)
    local n = #list
    if n >= keep and not before(candidate, list[n]) then return end
    local i = n >= keep and n or n + 1
    while i > 1 and before(candidate, list[i - 1]) do
        list[i] = list[i - 1]
        i = i - 1
    end
    list[i] = candidate
end

-- Whether some player of `a` stands within the radius of some player of `b` (3D), and the pairs tried.
local function linked(a, b, r2)
    for i = 1, #a do
        local p = a[i]
        for j = 1, #b do
            local dx, dy, dz = p.x - b[j].x, p.y - b[j].y, p.z - b[j].z
            if dx * dx + dy * dy + dz * dz <= r2 then return true, i * #b end
        end
    end
    return false, #a * #b
end

-- Groups of players chained by `radius` in 3D (one client's streaming sphere overlapping the next),
-- the group of every player (a key unique across buckets), and the work it took. The union runs
-- over runs of players: the players of one 64 m cell, sorted by height and split wherever two
-- neighbours stand more than `step` apart vertically. Two players of one cell are at most 90.5 m
-- apart on the ground, so within `radius` when less than `step` apart in height: a run is
-- connected. Runs, of the same cell or of a neighbouring one, are then joined by the exact test.
-- (A whole cell counted as one run merged a street and a rooftop above it.)
local function countGroups(players, radius)
    local groups, cost, r2, span = 0, 0, radius * radius, math.ceil(radius / CELL)
    local groupOf, base = {}, 0
    local diagonal2 = 2 * CELL * CELL
    local step = r2 > diagonal2 and math.sqrt(r2 - diagonal2) or -1
    for _, set in pairs(players) do
        local runs, byCell, parent = {}, {}, {}
        local function find(i)
            while parent[i] ~= i do
                parent[i] = parent[parent[i]]
                i = parent[i]
            end
            return i
        end
        for cellId, members in pairs(set.cells) do
            local sorted = table.move(members, 1, #members, 1, {})
            table.sort(sorted, function(a, b) return a.z < b.z end)
            local list, run = {}, nil
            for i = 1, #sorted do
                if not run or sorted[i].z - sorted[i - 1].z > step then
                    run = { cell = cellId, members = {}, index = #runs + 1 }
                    runs[run.index], parent[run.index] = run, run.index
                    list[#list + 1] = run
                end
                run.members[#run.members + 1] = sorted[i]
            end
            byCell[cellId] = list
            cost = cost + #sorted
        end
        for _, run in ipairs(runs) do
            local cx, cy = run.cell // 65536 - 32768, run.cell % 65536 - 32768
            for gx = cx - span, cx + span do
                for gy = cy - span, cy + span do
                    local near = byCell[cellKey(gx, gy)]
                    cost = cost + 1
                    for i = 1, near and #near or 0 do
                        local other = near[i]
                        if other.index > run.index and find(other.index) ~= find(run.index) then
                            local joined, tried = linked(run.members, other.members, r2)
                            cost = cost + tried
                            if joined then parent[find(other.index)] = find(run.index) end
                        end
                    end
                end
            end
        end
        for i = 1, #runs do
            if parent[i] == i then groups = groups + 1 end
            local members, key = runs[i].members, base + find(i)
            for j = 1, #members do groupOf[members[j]] = key end
            cost = cost + #members
        end
        base = base + #runs
    end
    return groups, cost, groupOf
end

-- The clips of a profile (`clips`, its catalogue clip names) an NPC of `body` (its record's or
-- entry's body bits) plays: a clip the workspot authors for other bodies only is left out
-- (`clipBodies[profile][clip]` is the mask of bodies it fits); all of them when the body is unknown
-- or no clip is left. `cache` keeps the answer per profile index and body.
local function clipsFor(cache, clipBodies, profile, body, clips)
    local key = profile * 16 + body
    local cached = cache[key]
    if cached then return cached end
    local gates = (clipBodies or {})[profile]
    local result = clips
    if gates and body ~= 0 then
        result = {}
        for _, clip in ipairs(clips) do
            local admitted = gates[clip]
            if not admitted or admitted & body ~= 0 then result[#result + 1] = clip end
        end
        if #result == 0 then result = clips end
    end
    cache[key] = result
    return result
end

Open77PedestrianSpatial = {
    CELL = CELL, cellOf = cellOf, cellKey = cellKey, addPlayer = addPlayer, query = query, candidates = candidates,
    slicer = slicer,
    offer = offer, countGroups = countGroups, clipsFor = clipsFor,
}
