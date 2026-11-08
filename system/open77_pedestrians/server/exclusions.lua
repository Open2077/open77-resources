-- Places no pedestrian may be (a server's spawn square, a stage): no pedestrian of either scheduler spawns,
-- sits or visits a crowd spot inside, and a walker that walks in is retired. A zone is a circle on the
-- ground (radius) with a vertical band (height above and below its z), every bucket.
--
-- Two sources: the `open77_pedestrians_exclusions` convar ("x,y,z,radius[,height];..." read at start, owner
-- "convar") and the server exports exclude(key, zone) / unexclude(key), keyed by the calling resource and
-- dropped when it stops. Pure apart from the convar read in main.lua: the offline suites drive it.
Open77PedestrianExclusions = {}
local X = Open77PedestrianExclusions
X.__index = X

X.MIN_RADIUS = 1.0
X.MAX_RADIUS = 300.0
X.DEFAULT_HEIGHT = 20.0
X.MAX_ZONES = 64

local function finite(v) return type(v) == "number" and v == v and v ~= math.huge and v ~= -math.huge end

function X.new()
    return setmetatable({ zones = {}, list = {}, size = 0 }, X)
end

-- A zone table from { x, y, z, radius, height? }; nil, reason when it cannot be one.
function X.parse(zone)
    if type(zone) ~= "table" then return nil, "invalid_zone" end
    local x, y, z = tonumber(zone.x), tonumber(zone.y), tonumber(zone.z)
    local radius, height = tonumber(zone.radius), tonumber(zone.height or X.DEFAULT_HEIGHT)
    if not (finite(x) and finite(y) and finite(z)) then return nil, "invalid_position" end
    if not finite(radius) or radius < X.MIN_RADIUS or radius > X.MAX_RADIUS then return nil, "invalid_radius" end
    if not finite(height) or height <= 0 then return nil, "invalid_height" end
    return { x = x, y = y, z = z, radius = radius, r2 = radius * radius, height = height }
end

-- "x,y,z,radius[,height];..." -> list of zones (a bad entry is skipped and named in `bad`).
function X.parseList(text)
    local out, bad = {}, {}
    for entry in tostring(text or ""):gmatch("[^;]+") do
        local v = {}
        for n in entry:gmatch("[^,]+") do v[#v + 1] = tonumber(n) end
        local zone = #v >= 4 and X.parse({ x = v[1], y = v[2], z = v[3], radius = v[4], height = v[5] }) or nil
        if zone then out[#out + 1] = zone elseif entry:match("%S") then bad[#bad + 1] = entry end
    end
    return out, bad
end

function X:rebuild()
    local list = {}
    for _, zone in pairs(self.zones) do list[#list + 1] = zone end
    self.list = list
end

-- Registers or replaces `owner`'s zone `key`. -> true | nil, reason
function X:set(owner, key, zone)
    if type(owner) ~= "string" or owner == "" then return nil, "owner_unavailable" end
    if type(key) ~= "string" or #key == 0 or #key > 160 then return nil, "invalid_key" end
    local parsed, why = X.parse(zone)
    if not parsed then return nil, why end
    local slot = owner .. "|" .. key
    if not self.zones[slot] then
        if self.size >= X.MAX_ZONES then return nil, "too_many_zones" end
        self.size = self.size + 1
    end
    parsed.owner, parsed.key = owner, key
    self.zones[slot] = parsed
    self:rebuild()
    return true
end

function X:remove(owner, key)
    local slot = tostring(owner) .. "|" .. tostring(key)
    if not self.zones[slot] then return false end
    self.zones[slot] = nil
    self.size = self.size - 1
    self:rebuild()
    return true
end

function X:removeOwner(owner)
    local any = false
    for slot, zone in pairs(self.zones) do
        if zone.owner == owner then self.zones[slot] = nil; self.size = self.size - 1; any = true end
    end
    if any then self:rebuild() end
    return any
end

-- The zone (x, y, z) stands in, or nil.
function X:at(x, y, z)
    local list = self.list
    for i = 1, #list do
        local zone = list[i]
        local dx, dy = x - zone.x, y - zone.y
        if dx * dx + dy * dy <= zone.r2 and math.abs(z - zone.z) <= zone.height then return zone end
    end
    return nil
end
