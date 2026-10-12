-- Seats other resources hold for players (row B6 of docs/world-interaction-plan.md, the open77_seating
-- resource): while a player sits on a piece of world furniture, no pedestrian of either scheduler may
-- spawn on, visit or walk back to a spot within the hold's radius of that seat.
--
-- A hold is a point (the seat's pose), a radius on the ground and a vertical band, keyed by its owner
-- resource, bucket and key; it expires unless renewed (the owner refreshes it) and goes when its owner
-- resource stops. Pure: time comes from `now()` (seconds, as the schedulers' api.now), so the offline
-- suites drive it. The schedulers ask `blocks(bucket, x, y, z)` through `api.seatBlocked`.
Open77PedestrianSeatGuard = {}
local Guard = Open77PedestrianSeatGuard
Guard.__index = Guard

Guard.DEFAULT_RADIUS = 0.6       -- metres on the ground: two bodies closer than this overlap
Guard.MIN_RADIUS = 0.3
Guard.MAX_RADIUS = 1.5
Guard.VERTICAL = 1.0             -- a spot more than this above or below the seat is another floor
Guard.DEFAULT_TTL_MS = 30000
Guard.MIN_TTL_MS = 1000
Guard.MAX_TTL_MS = 600000
Guard.MAX_HOLDS = 2048

-- Holds are listed per bucket in 2 m cells; a radius is at most 1.5 m, so a point's own cell and its
-- eight neighbours hold every hold that can reach it.
local CELL = 2
local function cellOf(v) return math.floor(v / CELL) end
local function cellKey(bucket, cx, cy) return bucket .. ":" .. cx .. ":" .. cy end

function Guard.new(now)
    return setmetatable({ now = now or function() return 0 end, holds = {}, cells = {}, size = 0 }, Guard)
end

local function finite(v) return type(v) == "number" and v == v and v ~= math.huge and v ~= -math.huge end

local function slot(owner, bucket, key) return owner .. "|" .. bucket .. "|" .. key end

function Guard:unlist(entry)
    local list = self.cells[entry.cell]
    if not list then return end
    for i = #list, 1, -1 do
        if list[i] == entry then table.remove(list, i) end
    end
    if #list == 0 then self.cells[entry.cell] = nil end
end

function Guard:drop(entry)
    if self.holds[entry.slot] ~= entry then return false end
    self.holds[entry.slot] = nil
    self:unlist(entry)
    self.size = self.size - 1
    return true
end

-- Validates and normalises a hold request; nil, reason when it cannot be one.
function Guard.parse(bucket, key, position, options)
    bucket = math.tointeger(tonumber(bucket))
    if bucket == nil or bucket < 0 then return nil, "invalid_bucket" end
    if type(key) ~= "string" or #key == 0 or #key > 160 then return nil, "invalid_key" end
    if type(position) ~= "table" or not finite(position.x) or not finite(position.y) or not finite(position.z) then
        return nil, "invalid_position"
    end
    if options ~= nil and type(options) ~= "table" then return nil, "invalid_options" end
    options = options or {}
    local radius = options.radius == nil and Guard.DEFAULT_RADIUS or options.radius
    if not finite(radius) or radius < Guard.MIN_RADIUS or radius > Guard.MAX_RADIUS then return nil, "invalid_options" end
    local ttl = options.ttlMs == nil and Guard.DEFAULT_TTL_MS or options.ttlMs
    if not finite(ttl) or ttl < Guard.MIN_TTL_MS or ttl > Guard.MAX_TTL_MS then return nil, "invalid_options" end
    return { bucket = bucket, key = key, x = position.x, y = position.y, z = position.z, radius = radius,
        ttl = ttl / 1000, force = options.force == true }
end

-- Registers or refreshes `owner`'s hold. A refresh keeps the entry and moves its deadline (and its point,
-- if the seat moved). Returns the entry, or nil, "too_many_holds".
function Guard:hold(owner, request)
    local id = slot(owner, request.bucket, request.key)
    local entry = self.holds[id]
    if entry == nil then
        if self.size >= Guard.MAX_HOLDS then return nil, "too_many_holds" end
        entry = { slot = id, owner = owner, bucket = request.bucket, key = request.key }
        self.holds[id] = entry
        self.size = self.size + 1
    else
        self:unlist(entry)
    end
    entry.x, entry.y, entry.z, entry.radius = request.x, request.y, request.z, request.radius
    entry.expiresAt = self.now() + request.ttl
    entry.cell = cellKey(request.bucket, cellOf(request.x), cellOf(request.y))
    local list = self.cells[entry.cell]
    if not list then list = {}; self.cells[entry.cell] = list end
    list[#list + 1] = entry
    return entry
end

function Guard:release(owner, bucket, key)
    local entry = self.holds[slot(owner, math.tointeger(tonumber(bucket)) or -1, tostring(key))]
    return entry ~= nil and self:drop(entry)
end

function Guard:releaseOwner(owner)
    local gone = {}
    for _, entry in pairs(self.holds) do
        if entry.owner == owner then gone[#gone + 1] = entry end
    end
    for _, entry in ipairs(gone) do self:drop(entry) end
    return #gone
end

function Guard:sweep()
    local now, gone = self.now(), {}
    for _, entry in pairs(self.holds) do
        if entry.expiresAt <= now then gone[#gone + 1] = entry end
    end
    for _, entry in ipairs(gone) do self:drop(entry) end
    return #gone
end

-- The live hold that covers (x, y, z) in `bucket`, or nil. An expired hold is dropped on read.
function Guard:blocks(bucket, x, y, z)
    if self.size == 0 or not finite(x) or not finite(y) or not finite(z) then return nil end
    local cx, cy, now = cellOf(x), cellOf(y), self.now()
    for gx = cx - 1, cx + 1 do
        for gy = cy - 1, cy + 1 do
            local list = self.cells[cellKey(bucket, gx, gy)]
            if list then
                for i = #list, 1, -1 do
                    local entry = list[i]
                    if entry.expiresAt <= now then
                        self:drop(entry)
                    else
                        local dx, dy = entry.x - x, entry.y - y
                        if dx * dx + dy * dy <= entry.radius * entry.radius and
                            math.abs(entry.z - z) <= Guard.VERTICAL then
                            return entry
                        end
                    end
                end
            end
        end
    end
    return nil
end

function Guard:list()
    local out, now = {}, self.now()
    for _, entry in pairs(self.holds) do
        if entry.expiresAt > now then
            out[#out + 1] = { owner = entry.owner, bucket = entry.bucket, key = entry.key, x = entry.x, y = entry.y,
                z = entry.z, radius = entry.radius, remainingMs = math.floor((entry.expiresAt - now) * 1000) }
        end
    end
    table.sort(out, function(a, b)
        if a.owner ~= b.owner then return a.owner < b.owner end
        if a.bucket ~= b.bucket then return a.bucket < b.bucket end
        return a.key < b.key
    end)
    return out
end

function Guard:count() return self.size end
