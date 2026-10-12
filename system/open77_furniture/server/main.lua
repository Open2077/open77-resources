-- open77_furniture: read-only lookups over the world's furniture spots (row A1,
-- docs/world-interaction/a1-furniture.md). Opt-in (`auto_start false`).
--
-- Exports (synchronous: `exports.open77_furniture:nearby(...)`; every call
-- answers a value or nil, reason, never raises on bad input):
--   nearby(position, radius?, filter?) -> list | nil, reason
--   get(id)                            -> furniture | nil, reason
--   status()                           -> table
-- See server/index.lua for the fields. No occupancy, claim, prompt or
-- playback lives here: B6 builds those over these lookups.
--
-- Lab console (restricted; the dedicated console is always allowed):
--   furniture.status
--   furniture.near <playerId> [count] [radius] [kind]
--   furniture.at   <x> <y> <z> [count] [radius] [kind]
--   furniture.get  <furnitureId|spotId>
-- Every line printed starts with "[furniture]".

local index = Open77FurnitureIndex.new(Open77FurnitureCatalog)
local buildError = nil
local buildSeconds = nil

local function say(fmt, ...)
    print("[furniture] " .. fmt:format(...))
end

-- ~25 k rows exceed one resume's instruction budget: the grid is filled over
-- several ticks, Index.YIELD_EVERY rows a slice. Lookups answer nil,
-- "indexing" until it is done.
CreateThread(function()
    local started = Open77.time.monotonic()
    local ok, err = pcall(index.build, index, function() Wait(0) end)
    if not ok then
        buildError = tostring(err)
        say("index failed: %s", buildError)
        return
    end
    buildSeconds = Open77.time.monotonic() - started
    local state = index:status()
    say("indexed version=%s furniture=%d spots=%d cells=%d in %.2fs (runtimeValidated=false)",
        tostring(state.version), state.furniture, state.spots, state.cells, buildSeconds)
end)

exports("nearby", function(position, radius, filter)
    if buildError then return nil, "index_failed" end
    return index:nearby(position, radius, filter)
end)

exports("get", function(id)
    if buildError then return nil, "index_failed" end
    return index:get(id)
end)

exports("status", function()
    local state = index:status()
    state.error = buildError
    state.buildSeconds = buildSeconds
    return state
end)

local function describe(rank, entry)
    local pose = entry.pose
    say("%d id=%s kind=%s posture=%s d=%.2f at=%.3f,%.3f,%.3f,%.2f profile=%s verification=%s poses=%d flags=%d "
            .. "pose=%s:%s@%.3f,%.3f,%.3f,%.2f",
        rank, entry.id, entry.kind, entry.posture, entry.distance or 0, entry.x, entry.y, entry.z, entry.yaw,
        tostring(entry.profile), entry.verification, entry.poses, entry.flags,
        pose.spot, pose.kind, pose.x, pose.y, pose.z, pose.yaw)
end

local function near(position, args, first)
    local count = math.tointeger(tonumber(args[first])) or 5
    local radius = tonumber(args[first + 1]) or 15
    local kind = args[first + 2]
    local list, reason = index:nearby(position, radius, { limit = count, kind = kind })
    if not list then
        say("NEAR refused reason=%s", tostring(reason))
        return
    end
    say("NEAR at=%.2f,%.2f,%.2f radius=%.1f kind=%s found=%d version=%s", position.x, position.y, position.z,
        radius, tostring(kind), #list, tostring(Open77FurnitureCatalog.version))
    for rank, entry in ipairs(list) do describe(rank, entry) end
end

RegisterCommand("furniture.status", function()
    local state = index:status()
    say("STATUS indexed=%s version=%s dataset=%s furniture=%d spots=%d cells=%d chunks=%s buildSeconds=%s error=%s",
        tostring(state.indexed), tostring(state.version), tostring(state.datasetId), state.furniture, state.spots,
        state.cells, tostring(state.chunks), buildSeconds and ("%.2f"):format(buildSeconds) or "pending",
        tostring(buildError))
end, true)

RegisterCommand("furniture.near", function(_, args)
    -- Open77.players.position throws on an id below 1: check before the call.
    local id = math.tointeger(tonumber(args[1]))
    if id == nil or id < 1 then
        say("usage: furniture.near <playerId> [count] [radius] [kind]")
        return
    end
    local position = Open77.players.position(id)
    if position == nil then
        say("NEAR player=%d position=unknown", id)
        return
    end
    say("NEAR player=%d bucket=%s", id, tostring(position.bucket))
    near(position, args, 2)
end, true)

RegisterCommand("furniture.at", function(_, args)
    local x, y, z = tonumber(args[1]), tonumber(args[2]), tonumber(args[3])
    if x == nil or y == nil or z == nil then
        say("usage: furniture.at <x> <y> <z> [count] [radius] [kind]")
        return
    end
    near({ x = x, y = y, z = z }, args, 4)
end, true)

RegisterCommand("furniture.get", function(_, args)
    local entry, reason = index:get(args[1])
    if not entry then
        say("GET id=%s refused reason=%s", tostring(args[1]), tostring(reason))
        return
    end
    describe(0, entry)
    for i, pose in ipairs(entry.poseList) do
        say("  pose %d spot=%s kind=%s at=%.3f,%.3f,%.3f,%.2f profile=%s verification=%s arrivalRadius=%.2f "
                .. "resource=%s pedestrianSpot=%s crowdSpot=%s",
            i, pose.spot, pose.kind, pose.x, pose.y, pose.z, pose.yaw, tostring(pose.profile), pose.verification,
            pose.arrivalRadius or 0.5, pose.resource, tostring(pose.pedestrianSpot), tostring(pose.crowdSpot))
    end
end, true)
