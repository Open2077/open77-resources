-- Spatial index and lookups over the generated furniture catalogue (row A1,
-- docs/world-interaction/a1-furniture.md). Pure Lua, no native call: the
-- offline test (scripts/furniture/test_furniture_index.py) runs this file as is.
--
-- The catalogue (furniture-generated-*.lua) is columnar and split in chunks so
-- each file loads within one script's instruction budget. A furniture is a
-- group of world AI spots (alternative poses of one seat, bench, bed, wall or
-- rail); its poses are contiguous in the chunk's pose columns and the first
-- one is its representative: its global node id is the furniture id, and its
-- transform is where distances are measured from.
--
-- Nothing here claims, reserves or plays anything: occupancy belongs to B6,
-- presentation to Open77.animations.playAt.

Open77FurnitureIndex = {}
local Index = Open77FurnitureIndex
Index.__index = Index

-- Furniture references pack the chunk and the furniture's index in it.
local CHUNK_SPAN = 1048576
-- Grid cell edge, metres. The densest 16 m cell of the catalogue holds a few
-- hundred furniture (report.json, densestCells).
local CELL = 16
Index.CELL = CELL
Index.MAX_RADIUS = 50
Index.DEFAULT_RADIUS = 10
Index.DEFAULT_LIMIT = 5
Index.MAX_LIMIT = 32
-- With `poses = true` every result carries its pose list: fewer results keep
-- the reply inside the export payload limits (4,096 values, 48 KiB).
Index.MAX_LIMIT_WITH_POSES = 8
-- Rows handled between two `yield` calls while building, as the pedestrian
-- scheduler does (resources/system/open77_pedestrians/server/scheduler.lua).
Index.YIELD_EVERY = 2000

-- Flag bits of the `flags` column (scripts/furniture/build_furniture_catalog.py).
Index.FLAGS = {
    interior = 1,          -- source sector is an interior streaming sector
    quest = 2,             -- source sector is a quest sector
    ep1 = 4,               -- Phantom Liberty sector (Dogtown)
    multilevel = 8,        -- other furniture within 8 m on the ground and 2.5 m or more above/below
    snap = 16,             -- the spot snaps to the ground (AIActionSpot.snapToGround)
    dependent = 32,        -- a pose is only enabled while its master spot is occupied
    clearance = 64,        -- the spot declares a clipping space (approach/clearance hint)
    bodyRestricted = 128,  -- a pose is authored for one body type (ActorBodytypeE3)
    crowded = 256,         -- another posture, or an opposed seat (yaw > 90 deg apart), within 0.5 m
    npcSeated = 512,       -- a pose is a seated-pedestrian spot (open77_pedestrians spots catalogue)
    npcCrowd = 1024,       -- a pose is a crowd-visit spot (open77_pedestrians crowd catalogue)
    wide = 2048,           -- chained poses span more than 0.5 m (a bench row): one claim covers them all
}

local function cellOf(v) return math.floor(v / CELL) end
local function cellKey(cx, cy) return (cx + 32768) * 65536 + cy + 32768 end

local function finite(v)
    return type(v) == "number" and v == v and v ~= math.huge and v ~= -math.huge
end

local function lookup(list)
    local result = {}
    for i, name in ipairs(list or {}) do result[name] = i end
    return result
end

-- Cheap: `build` does the work, in slices.
function Index.new(catalog)
    return setmetatable({
        catalog = catalog,
        chunks = catalog.chunks or {},
        grid = {},
        byId = {},
        kindIndex = lookup(catalog.kinds),
        postureIndex = lookup(catalog.postures),
        profileIndex = lookup(catalog.profiles),
        verificationIndex = lookup(catalog.verification),
        indexed = false,
        furniture = 0,
        spots = 0,
        cells = 0,
    }, Index)
end

-- Fills the grid and the id map. `yield`, when given, is called every
-- YIELD_EVERY rows (Wait(0) on the server: one slice per tick).
function Index:build(yield)
    local catalog, steps = self.catalog, 0
    local function step()
        steps = steps + 1
        if yield and steps % Index.YIELD_EVERY == 0 then yield() end
    end
    local expected = catalog.chunkCount or 0
    for chunkNumber = 1, expected do
        if self.chunks[chunkNumber] == nil then
            error(("furniture chunk %d of %d is missing (manifest order?)"):format(chunkNumber, expected))
        end
    end
    local grid, byId, cells = self.grid, self.byId, 0
    for chunkNumber = 1, expected do
        local chunk = self.chunks[chunkNumber]
        local first, gid, xs, ys = chunk.first, chunk.gid, chunk.x, chunk.y
        local base = chunkNumber * CHUNK_SPAN
        local count = #first
        for f = 1, count do
            local ref = base + f
            local p = first[f]
            local key = cellKey(cellOf(xs[p]), cellOf(ys[p]))
            local cell = grid[key]
            if not cell then cell = {}; grid[key] = cell; cells = cells + 1 end
            cell[#cell + 1] = ref
            local last = (f < count) and first[f + 1] - 1 or #gid
            for q = p, last do byId[gid[q]] = ref end
            self.spots = self.spots + (last - p + 1)
            step()
        end
        self.furniture = self.furniture + count
    end
    self.cells = cells
    self.indexed = true
    return self.furniture
end

local function decode(ref)
    return ref // CHUNK_SPAN, ref % CHUNK_SPAN
end

-- The pose range [first, last] of furniture `f` in `chunk`.
local function poseRange(chunk, f)
    local first = chunk.first
    return first[f], (f < #first) and first[f + 1] - 1 or #chunk.gid
end

-- `value` may be one name or a list of names; returns a set of indices, or
-- nil, reason for an unknown name.
local function nameSet(value, index, what)
    if value == nil then return true end
    local names = type(value) == "table" and value or { value }
    local set = {}
    for _, name in ipairs(names) do
        local i = index[name]
        if not i then return nil, "unknown_" .. what .. ":" .. tostring(name) end
        set[i] = true
    end
    return set
end

-- Parses `filter` once per query into index sets; nil, reason when invalid.
function Index:parseFilter(filter)
    if filter ~= nil and type(filter) ~= "table" then return nil, "invalid_filter" end
    filter = filter or {}
    local parsed = {}
    local reason
    parsed.kinds, reason = nameSet(filter.kind, self.kindIndex, "kind")
    if not parsed.kinds then return nil, reason end
    parsed.postures, reason = nameSet(filter.posture, self.postureIndex, "posture")
    if not parsed.postures then return nil, reason end
    parsed.profiles, reason = nameSet(filter.profile, self.profileIndex, "profile")
    if not parsed.profiles then return nil, reason end
    parsed.verification, reason = nameSet(filter.verification, self.verificationIndex, "verification")
    if not parsed.verification then return nil, reason end
    if filter.vertical ~= nil and (not finite(filter.vertical) or filter.vertical < 0) then
        return nil, "invalid_vertical"
    end
    parsed.vertical = filter.vertical
    parsed.playable = filter.playable == true
    parsed.poses = filter.poses == true
    local exclude = 0
    if filter.excludeFlags ~= nil then
        exclude = finite(filter.excludeFlags) and math.tointeger(filter.excludeFlags) or nil
        if exclude == nil or exclude < 0 then return nil, "invalid_exclude_flags" end
    end
    parsed.excludeFlags = exclude
    local cap = parsed.poses and Index.MAX_LIMIT_WITH_POSES or Index.MAX_LIMIT
    local limit = filter.limit
    if limit == nil then
        limit = math.min(Index.DEFAULT_LIMIT, cap)
    elseif math.type(limit) ~= "integer" and not (finite(limit) and limit % 1 == 0) then
        return nil, "invalid_limit"
    end
    limit = math.tointeger(limit)
    if limit < 1 then return nil, "invalid_limit" end
    parsed.limit = math.min(limit, cap)
    return parsed
end

-- Whether a pose passes the kind/profile/verification part of the filter.
local function poseMatches(catalog, chunk, q, parsed)
    local res = chunk.res[q]
    if parsed.kinds ~= true and not parsed.kinds[catalog.resourceKind[res]] then return false end
    if parsed.postures ~= true and not parsed.postures[catalog.kindPosture[catalog.resourceKind[res]]] then
        return false
    end
    local profile = chunk.prof[q]
    if parsed.playable and profile == 0 then return false end
    if parsed.profiles ~= true and not parsed.profiles[profile] then return false end
    if parsed.verification ~= true and not parsed.verification[chunk.ver[q]] then return false end
    return true
end

function Index:pose(chunk, q)
    local catalog = self.catalog
    local res = chunk.res[q]
    local kind = catalog.resourceKind[res]
    local profile = chunk.prof[q]
    return {
        spot = chunk.gid[q],
        x = chunk.x[q], y = chunk.y[q], z = chunk.z[q], yaw = chunk.yaw[q],
        kind = catalog.kinds[kind],
        posture = catalog.postures[catalog.kindPosture[kind]],
        resource = catalog.resources[res],
        profile = profile ~= 0 and catalog.profiles[profile] or nil,
        verification = catalog.verification[chunk.ver[q]],
        -- The playAt `arrivalRadius` this pose needs (per resource; 0.5 when the catalogue predates it).
        arrivalRadius = catalog.resourceArrival and catalog.resourceArrival[res] or 0.5,
        pedestrianSpot = chunk.ped[q] ~= 0 and chunk.ped[q] or nil,
        crowdSpot = chunk.crowd[q] ~= 0 and chunk.crowd[q] or nil,
    }
end

-- A furniture's summary. `kind`, `posture` and the transform are the
-- representative pose's; `pose` is pose `q`, the best-verified pose that
-- passed the filter (so a filter on a profile reports the pose to play), and
-- `profile` and `verification` repeat that pose's for convenience.
function Index:summary(chunk, f, q, distance, withPoses)
    local catalog = self.catalog
    local p, last = poseRange(chunk, f)
    local kind = catalog.resourceKind[chunk.res[p]]
    local matched = self:pose(chunk, q)
    matched.resource = nil
    local entry = {
        id = chunk.gid[p],
        kind = catalog.kinds[kind],
        posture = catalog.postures[catalog.kindPosture[kind]],
        distance = distance,
        x = chunk.x[p], y = chunk.y[p], z = chunk.z[p], yaw = chunk.yaw[p],
        pose = matched,
        profile = matched.profile,
        verification = matched.verification,
        poses = last - p + 1,
        flags = chunk.flags[f],
        version = catalog.version,
    }
    if withPoses then
        local list = {}
        for i = p, last do list[#list + 1] = self:pose(chunk, i) end
        entry.poseList = list
    end
    return entry
end

-- Nearest first, ties by id: the same order on every server.
local function before(a, b)
    if a.distance == b.distance then return a.id < b.id end
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

-- Furniture whose representative pose lies within `radius` metres (3D) of
-- `position`, nearest first, at most `filter.limit`. `filter` fields, all
-- optional: kind, posture, profile, verification (a name or a list of
-- names), playable (only poses with a player profile), vertical (max height
-- difference, metres), excludeFlags (integer mask of FLAGS), limit, poses
-- (include each result's pose list). Returns the list, or nil, reason.
function Index:nearby(position, radius, filter)
    if not self.indexed then return nil, "indexing" end
    if type(position) ~= "table" or not finite(position.x) or not finite(position.y) or not finite(position.z) then
        return nil, "invalid_position"
    end
    if radius == nil then radius = Index.DEFAULT_RADIUS end
    if not finite(radius) or radius <= 0 then return nil, "invalid_radius" end
    if radius > Index.MAX_RADIUS then return nil, "radius_too_large" end
    local parsed, reason = self:parseFilter(filter)
    if not parsed then return nil, reason end
    local x, y, z = position.x, position.y, position.z
    local r2 = radius * radius
    local vertical = parsed.vertical
    local best = {}
    local catalog, chunks, grid = self.catalog, self.chunks, self.grid
    local cx0, cx1, cy0, cy1 = cellOf(x - radius), cellOf(x + radius), cellOf(y - radius), cellOf(y + radius)
    for gx = cx0, cx1 do
        for gy = cy0, cy1 do
            local cell = grid[cellKey(gx, gy)]
            if cell then
                for i = 1, #cell do
                    local ref = cell[i]
                    local c, f = decode(ref)
                    local chunk = chunks[c]
                    local p, last = poseRange(chunk, f)
                    local dx, dy, dz = chunk.x[p] - x, chunk.y[p] - y, chunk.z[p] - z
                    local d2 = dx * dx + dy * dy + dz * dz
                    if d2 <= r2 and (not vertical or (dz <= vertical and dz >= -vertical))
                            and (chunk.flags[f] & parsed.excludeFlags) == 0 then
                        -- The best-verified pose that passes the filter (the first one on a tie).
                        local match, rank = nil, math.huge
                        local ver = chunk.ver
                        for q = p, last do
                            if ver[q] < rank and poseMatches(catalog, chunk, q, parsed) then
                                match, rank = q, ver[q]
                            end
                        end
                        if match then
                            offer(best, { distance = math.sqrt(d2), id = chunk.gid[p], chunk = c, f = f, q = match },
                                parsed.limit)
                        end
                    end
                end
            end
        end
    end
    local results = {}
    for i, candidate in ipairs(best) do
        local distance = math.floor(candidate.distance * 1000 + 0.5) / 1000
        results[i] = self:summary(chunks[candidate.chunk], candidate.f, candidate.q, distance, parsed.poses)
    end
    return results
end

-- One furniture by its id or by the global node id of any of its spots:
-- the summary of its representative pose plus every pose. nil, reason when
-- unknown.
function Index:get(id)
    if not self.indexed then return nil, "indexing" end
    if math.type(id) == "integer" then id = tostring(id) end
    if type(id) ~= "string" or id == "" then return nil, "invalid_id" end
    local ref = self.byId[id]
    if not ref then return nil, "unknown_furniture" end
    local c, f = decode(ref)
    local chunk = self.chunks[c]
    local p = poseRange(chunk, f)
    return self:summary(chunk, f, p, nil, true)
end

function Index:status()
    local catalog = self.catalog
    return {
        indexed = self.indexed,
        version = catalog.version,
        datasetId = catalog.datasetId,
        catalogSha256 = catalog.catalogSha256,
        runtimeValidated = catalog.runtimeValidated == true,
        furniture = self.furniture,
        spots = self.spots,
        cells = self.cells,
        chunks = catalog.chunkCount,
    }
end
