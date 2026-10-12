-- tests/compat/fakeworld.lua: the world natives the A9 suites need, on top of fakehost.lua.
--
-- Vehicles, props (with vehicle attachments), player positions, entity state bags, toasts, the
-- vehicle data card and Open77.io.readJson over the resource's real data/ directory. The world
-- lives in H.world and survives H.boot: restarting a resource does not empty the server.
-- H.stopResource(name) is the platform's resource stop: it removes the props that resource owned.
-- Semantics follow wiki/attachments.md and wiki/vehicles.md (same bucket, 32 children per parent,
-- vehicle removal and parent bucket changes detach the children, removal of an attached child
-- reports a terminal change). It is a stand-in, not a model of the engine.

H.world = H.world or {
    vehicles = {}, props = {}, nextVehicle = 100, nextProp = 5000,
    exceptions = {},       -- [vehicleId][playerId] = false (unlocked for that player) | nil
    resourceDirs = {},     -- resource -> directory holding its data/
}
local W = H.world

local function copy(v)
    if type(v) ~= "table" then return v end
    local out = {}
    for k, x in pairs(v) do out[k] = copy(x) end
    return out
end
H.copy = copy

local function finite(v) return type(v) == "number" and v == v and v ~= math.huge and v ~= -math.huge end

-- ---------------------------------------------------------------------------------------------
-- Vehicles
-- ---------------------------------------------------------------------------------------------

local function vehicleSnapshot(v)
    return {
        id = v.id, record = v.record, resource = v.resource, bucket = v.bucket,
        x = v.x, y = v.y, z = v.z, position = { x = v.x, y = v.y, z = v.z },
        yaw = v.yaw, heading = v.yaw, speed = v.speed or 0, occupants = {}, locked = v.locked,
    }
end

-- Test helper: a vehicle created by some resource (the garage, an admin /car ...).
function H.addVehicle(def)
    W.nextVehicle = W.nextVehicle + 1
    local id = W.nextVehicle
    local p = def.position or { x = 0, y = 0, z = 0 }
    W.vehicles[id] = { id = id, record = def.record, resource = def.resource or H.resource, bucket = def.bucket or 0,
        x = p.x, y = p.y, z = p.z, yaw = def.yaw or 0.0, speed = def.speed or 0, locked = false }
    return id
end

local function childrenOf(parentType, parentId)
    local out = {}
    for id, prop in pairs(W.props) do
        local a = prop.attachment
        if a and a.parentType == parentType and a.parentId == tostring(parentId) then out[#out + 1] = id end
    end
    table.sort(out)
    return out
end

local function detach(propId, reason)
    local prop = W.props[propId]
    if not prop or not prop.attachment then return end
    local previous = prop.attachment
    prop.attachment = nil
    prop.revision = prop.revision + 1
    H.emit("onPropAttachmentChanged", propId, nil, copy(previous), reason, prop.revision)
end

function H.removeVehicle(id, reason)
    local v = W.vehicles[id]
    if not v then return false end
    local children = childrenOf("vehicle", id)
    W.vehicles[id] = nil            -- gone first: a handler reacting to the detach sees no parent
    W.exceptions[id] = nil
    for _, propId in ipairs(children) do detach(propId, "parent_removed") end
    H.emit("onVehicleRemoved", tostring(id), reason or "removed")
    return true
end

-- A parent bucket change detaches the children on the server (wiki/attachments.md).
function H.setVehicleBucket(id, bucket)
    local v = W.vehicles[id]
    local children = childrenOf("vehicle", id)
    v.bucket = bucket               -- moved first, then the children lose their binding
    for _, propId in ipairs(children) do detach(propId, "parent_bucket") end
end

local function playerPos(playerId)
    local p = H.players[playerId]
    local pos = p and p.position
    if not pos then return nil end
    return { x = pos.x, y = pos.y, z = pos.z, bucket = pos.bucket or 0 }
end

local function distance(a, b)
    local dx, dy, dz = a.x - b.x, a.y - b.y, (a.z or 0) - (b.z or 0)
    return math.sqrt(dx * dx + dy * dy + dz * dz)
end

Open77.vehicles = {
    flags = { locked = 1 },
    create = function(def)
        if type(def) ~= "table" or type(def.record) ~= "string" then return nil, "invalid_argument" end
        return H.addVehicle({ record = def.record, position = def.position, yaw = def.yaw, bucket = def.bucket, resource = H.resource })
    end,
    get = function(id)
        local v = W.vehicles[tonumber(id) or -1]
        return v and vehicleSnapshot(v) or nil
    end,
    all = function(bucket)
        local out = {}
        for _, v in pairs(W.vehicles) do
            if bucket == nil or v.bucket == bucket then out[#out + 1] = vehicleSnapshot(v) end
        end
        table.sort(out, function(a, b) return a.id < b.id end)
        return out
    end,
    remove = function(id) return H.removeVehicle(tonumber(id) or -1, "removed") end,
    getPosition = function(id)
        local v = W.vehicles[tonumber(id) or -1]
        if not v then return nil, "vehicle_not_found" end
        return { x = v.x, y = v.y, z = v.z }
    end,
    nearby = function(anchor, radius, opts)
        local centre = type(anchor) == "table" and anchor or playerPos(anchor)
        if not centre then return {} end
        local out = {}
        for _, v in pairs(W.vehicles) do
            local d = distance(centre, v)
            if d <= radius then out[#out + 1] = { id = v.id, distance = d, record = v.record } end
        end
        table.sort(out, function(a, b) return a.distance < b.distance end)
        return out
    end,
    getPlayerSeat = function() return nil end,
    setLocked = function(id, flag) local v = W.vehicles[tonumber(id) or -1] if v then v.locked = flag end return v ~= nil end,
    isLocked = function(id) local v = W.vehicles[tonumber(id) or -1] return v and v.locked or nil end,
    setLockedForPlayer = function(id, playerId, flag)
        id = tonumber(id)
        W.exceptions[id] = W.exceptions[id] or {}
        W.exceptions[id][playerId] = flag
        return true
    end,
    triggerHorn = function() return true end,
    setProperties = function() return true end,
    getProperties = function() return nil end,
}

-- ---------------------------------------------------------------------------------------------
-- Props
-- ---------------------------------------------------------------------------------------------

local function propSnapshot(p)
    return { id = p.id, model = p.model, resource = p.owner, bucket = p.bucket, x = p.x, y = p.y, z = p.z,
        revision = p.revision, attachment = copy(p.attachment) }
end

local function vectorOk(v, limit)
    if v == nil then return true end
    if type(v) ~= "table" then return false end
    for _, axis in ipairs({ "x", "y", "z" }) do
        local c = v[axis]
        if c ~= nil and (not finite(c) or math.abs(c) > limit) then return false end
    end
    return true
end

Open77.props = {
    create = function(def)
        if type(def) ~= "table" or type(def.model) ~= "string" or def.model == "" then return nil, "invalid_model" end
        if def.model:match("^invalid") then return nil, "invalid_model" end
        W.nextProp = W.nextProp + 1
        local id = tostring(W.nextProp)
        local p = def.position or {}
        W.props[id] = { id = id, model = def.model, owner = H.resource, bucket = def.bucket or 0,
            x = p.x or 0, y = p.y or 0, z = p.z or 0, revision = 1 }
        return id
    end,
    remove = function(id)
        local prop = W.props[tostring(id)]
        if not prop then return false, "not_found" end
        if prop.owner ~= H.resource then return false, "owned_by_another_resource" end
        detach(prop.id, "removed")
        W.props[prop.id] = nil
        return true
    end,
    get = function(id)
        local prop = W.props[tostring(id)]
        return prop and propSnapshot(prop) or nil
    end,
    attach = function(id, binding)
        local prop = W.props[tostring(id)]
        if not prop then return nil, "invalid_prop_id" end
        if prop.owner ~= H.resource then return nil, "owned_by_another_resource" end
        if type(binding) ~= "table" or binding.parentType ~= "vehicle" then return nil, "invalid_attachment_parent" end
        local parent = W.vehicles[tonumber(binding.parentId) or -1]
        if not parent then return nil, "parent_unavailable" end
        if parent.bucket ~= prop.bucket then return nil, "wrong_bucket" end
        if not vectorOk(binding.offset, 20) or not vectorOk(binding.rotation, 360) then return nil, "invalid_attachment_transform" end
        local siblings = childrenOf("vehicle", parent.id)
        local count = 0
        for _, sid in ipairs(siblings) do if sid ~= prop.id then count = count + 1 end end
        if count >= 32 then return nil, "attachment_parent_limit" end
        local previous = prop.attachment
        prop.attachment = { parentType = "vehicle", parentId = tostring(parent.id), bone = binding.bone or "",
            offset = copy(binding.offset or {}), rotation = copy(binding.rotation or {}) }
        prop.revision = prop.revision + 1
        H.emit("onPropAttachmentChanged", prop.id, copy(prop.attachment), copy(previous), "attached", prop.revision)
        return true
    end,
    detach = function(id)
        local prop = W.props[tostring(id)]
        if not prop then return nil, "invalid_prop_id" end
        detach(prop.id, "detached")
        return true
    end,
    getAttachment = function(id)
        local prop = W.props[tostring(id)]
        return prop and copy(prop.attachment) or nil
    end,
    setAttachmentTransform = function(id, offset, rotation)
        local prop = W.props[tostring(id)]
        if not prop then return nil, "not_found" end
        if not prop.attachment then return nil, "not_attached" end
        if not vectorOk(offset, 20) or not vectorOk(rotation, 360) then return nil, "invalid_attachment_transform" end
        if offset then prop.attachment.offset = copy(offset) end
        if rotation then prop.attachment.rotation = copy(rotation) end
        prop.revision = prop.revision + 1
        H.emit("onPropAttachmentChanged", prop.id, copy(prop.attachment), nil, "transform", prop.revision)
        return true
    end,
    attachedTo = function(parentType, parentId)
        local out = {}
        for _, id in ipairs(childrenOf(parentType, parentId)) do out[#out + 1] = propSnapshot(W.props[id]) end
        return out
    end,
    update = function() return true end,
}

-- Test helpers over props.
function H.propsOf(resource)
    local out = {}
    for _, p in pairs(W.props) do
        if p.owner == resource then out[#out + 1] = propSnapshot(p) end
    end
    table.sort(out, function(a, b) return a.id < b.id end)
    return out
end

function H.childrenOf(vehicleId)
    local out = {}
    for _, id in ipairs(childrenOf("vehicle", vehicleId)) do out[#out + 1] = propSnapshot(W.props[id]) end
    return out
end

-- The platform's resource stop: handlers see onResourceStop, the resource's props go.
function H.stopResource(name)
    for _, fn in ipairs(H.handlers["onResourceStop"] or {}) do fn(name) end
    for id, p in pairs(W.props) do
        if p.owner == name then W.props[id] = nil end
    end
end

-- ---------------------------------------------------------------------------------------------
-- Players, state bags, toasts, data cards, resource files
-- ---------------------------------------------------------------------------------------------

Open77.players.position = function(playerId) return playerPos(playerId) end
Open77.players.distance = function(playerId, target)
    local a = playerPos(playerId)
    local b = type(target) == "table" and target or playerPos(target)
    if not a or not b or b.x == nil then return nil end
    return distance(a, b)
end

Open77.state = {
    entity = function() return { set = function() return true end } end,
}
Open77.notifications = { send = function() return true end }
Open77.data = { vehicle = function() return nil end }

-- Open77.io is rooted at the resource's data/ directory (wiki/server-api.md).
Open77.io = {
    readJson = function(path)
        local dir = W.resourceDirs[H.resource]
        if not dir then return nil, "not_found" end
        local f = io.open(dir .. "/data/" .. path, "rb")
        if not f then return nil, "not_found" end
        local text = f:read("a")
        f:close()
        local value, err = CompatJson.decode(text)
        if value == nil then return nil, "invalid_json:" .. tostring(err) end
        return value
    end,
}
