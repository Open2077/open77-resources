-- =============================================================================
-- open77_seating -- tests/fakes.lua
-- =============================================================================
-- A standing-in server platform so the REAL server half (shared/model.lua,
-- server/core.lua, server/main.lua) runs offline, against:
--   * the REAL open77_furniture index (server/index.lua) over a small
--     catalogue the suite builds in the generated column format;
--   * the REAL open77_actions claims service (server/claims.lua) behind the
--     claim / renewClaim / releaseClaim / claimHolder exports;
--   * the REAL open77_pedestrians seat guard (server/seatguard.lua) behind
--     holdSeat / releaseSeat / seatOccupants, with pedestrians the suite
--     places by hand.
-- Everything the resource touches is recorded; time and the scheduler are
-- driven by the suite.
--
-- Load order: tests/fakes.lua, ../open77_furniture/server/index.lua,
-- ../open77_actions/server/claims.lua, ../open77_pedestrians/server/seatguard.lua,
-- shared/model.lua, server/core.lua, server/main.lua, tests/seating_test.lua.
-- =============================================================================

local F = {
    now = 5000000,                -- monotonic ms
    threads = {},                 -- { co, wakeAt }
    players = {},                 -- [pid] = Open77.players.get read
    animCurrent = {},             -- [pid] = state answered by Open77.animations.current
    animLog = {},                 -- every playAt / stopAt
    animRefuse = nil,             -- the next playAt refuses with this reason
    nextPlayback = 1,
    teleports = {},               -- every teleport { pid, position, options }
    teleportMode = "settle",      -- "settle" | "refuse" | "defer" | { x, y, z } (lands there)
    deferred = {},                -- pending teleports while teleportMode == "defer"
    client = {},                  -- { name, target, payload }
    host = {},                    -- { name, payload }
    handlers = {},                -- [event] = { fn }
    netHandlers = {},
    commands = {},
    exports = {},                 -- this resource's exports
    exportHandlers = {},          -- [resource] = { [name] = fn }
    running = { open77_furniture = true, open77_actions = true, open77_pedestrians = true },
    actionsBusy = {},             -- [pid] = op answered by open77_actions current
    carrying = {},                -- [pid] = item answered by open77_actions carrying
    npcs = {},                    -- pedestrians the suite places: { npc, state, source, bucket, x, y, z }
    convars = {},
    prints = {},
    threadErrors = {},
    invoker = nil,
}
Open77SeatingFakes = F

-- --- scheduler ---------------------------------------------------------------
local function resume(entry)
    local ok, err = coroutine.resume(entry.co)
    if not ok then F.threadErrors[#F.threadErrors + 1] = tostring(err) end
end

function CreateThread(fn)
    local entry = { co = coroutine.create(fn), wakeAt = F.now }
    F.threads[#F.threads + 1] = entry
    resume(entry)
end

function Wait(ms)
    local co = coroutine.running()
    for _, entry in ipairs(F.threads) do
        if entry.co == co then entry.wakeAt = F.now + (tonumber(ms) or 0) end
    end
    coroutine.yield()
end

function F.run()
    for _ = 1, 50 do
        local progressed = false
        local list = {}
        for _, entry in ipairs(F.threads) do list[#list + 1] = entry end
        for _, entry in ipairs(list) do
            if coroutine.status(entry.co) == "suspended" and entry.wakeAt <= F.now then
                local before = entry.wakeAt
                resume(entry)
                if coroutine.status(entry.co) == "dead" or entry.wakeAt ~= before then progressed = true end
            end
        end
        local live = {}
        for _, entry in ipairs(F.threads) do
            if coroutine.status(entry.co) ~= "dead" then live[#live + 1] = entry end
        end
        F.threads = live
        if not progressed then break end
    end
end

-- Advance the clock in 50 ms steps, running threads.
function F.advance(ms)
    local target = F.now + ms
    while F.now < target do
        F.now = math.min(target, F.now + 50)
        F.run()
    end
end

-- --- host globals ------------------------------------------------------------
function GetCurrentResourceName() return "open77_seating" end
function GetCurrentResourceGeneration() return 3 end
function GetInvokingResource() return F.invoker end
function GetInvokingResourceGeneration() return 1 end
function GetConvar(name, default) return F.convars[name] or default end

function GetPlayers()
    local out = {}
    for id in pairs(F.players) do out[#out + 1] = tostring(id) end
    table.sort(out)
    return out
end

function exports(name, fn) F.exports[name] = fn end

function AddEventHandler(name, fn)
    F.handlers[name] = F.handlers[name] or {}
    table.insert(F.handlers[name], fn)
end

function RegisterNetEvent(name, fn) F.netHandlers[name] = fn end
function RegisterCommand(name, fn, restricted) F.commands[name] = { fn = fn, restricted = restricted } end

function TriggerEvent(name, ...)
    F.host[#F.host + 1] = { name = name, args = { ... } }
    for _, fn in ipairs(F.handlers[name] or {}) do fn(...) end
    return true
end

function TriggerClientEvent(name, target, payload)
    F.client[#F.client + 1] = { name = name, target = target, payload = payload }
    return true
end

function print(...)
    local parts = {}
    for i = 1, select("#", ...) do parts[#parts + 1] = tostring((select(i, ...))) end
    F.prints[#F.prints + 1] = table.concat(parts, "\t")
end

json = { decode = function() error("tests pass decoded tables") end, encode = function() return "{}" end }

-- --- cross-resource exports -------------------------------------------------
Open77 = {
    time = { monotonic = function() return F.now / 1000 end },
    resource = { generation = function() return 3 end },
    exports = {
        callSync = function(resource, name, ...)
            if not F.running[resource] then error("export_resource_unavailable") end
            local set = F.exportHandlers[resource]
            local fn = set and set[name]
            if fn == nil then error("export_not_found") end
            local saved = F.invoker
            F.invoker = "open77_seating"
            local values = table.pack(fn(...))
            F.invoker = saved
            return table.unpack(values, 1, values.n)
        end,
    },
    players = {
        get = function(pid) return F.players[pid] end,
    },
    animations = {},
}

-- --- animations ----------------------------------------------------------------
Open77.animations.current = function(pid) return F.animCurrent[pid] end
Open77.animations.playAt = function(pid, profile, position, yaw, options)
    F.animLog[#F.animLog + 1] = { op = "playAt", pid = pid, profile = profile, position = position, yaw = yaw,
        options = options }
    if F.animRefuse then
        local reason = F.animRefuse
        F.animRefuse = nil
        return nil, reason
    end
    local pb = "pb" .. F.nextPlayback
    F.nextPlayback = F.nextPlayback + 1
    return { playbackId = pb, playerId = pid, active = true,
        anchor = { x = position.x, y = position.y, z = position.z, yaw = yaw } }
end
Open77.animations.stopAt = function(pb)
    F.animLog[#F.animLog + 1] = { op = "stopAt", playbackId = pb }
    return true
end

-- --- teleport ------------------------------------------------------------------
local function promise(entry)
    return {
        await = function()
            while not entry.resolved do coroutine.yield() end
            return table.unpack(entry.values, 1, entry.values.n)
        end,
    }
end

Open77.players.teleport = function(pid, position, options)
    F.teleports[#F.teleports + 1] = { pid = pid, position = position, options = options }
    local mode = F.teleportMode
    if mode == "refuse" then return nil, "player_not_ready" end
    local entry = { resolved = false, pid = pid, position = position }
    if mode == "defer" then
        F.deferred[#F.deferred + 1] = entry
        return promise(entry)
    end
    local at = type(mode) == "table" and mode or position
    if F.players[pid] then F.players[pid].position = { x = at.x, y = at.y, z = at.z } end
    entry.resolved = true
    entry.values = table.pack({ x = at.x, y = at.y, z = at.z, state = "settled" })
    return promise(entry)
end

-- Settles every deferred teleport (or fails it with `reason`).
function F.settleTeleports(reason)
    for _, entry in ipairs(F.deferred) do
        if reason then
            entry.values = table.pack(nil, reason)
        else
            if F.players[entry.pid] then
                F.players[entry.pid].position = { x = entry.position.x, y = entry.position.y, z = entry.position.z }
            end
            entry.values = table.pack({ x = entry.position.x, y = entry.position.y, z = entry.position.z, state = "settled" })
        end
        entry.resolved = true
    end
    F.deferred = {}
    F.run()
end

-- --- the three composed resources ----------------------------------------------
-- open77_furniture: the real index over a catalogue built from `furniture`:
-- { { flags = n, poses = { { gid, x, y, z, yaw, kind, profile, verification, arrival } } } }.
local KIND_POSTURE = { chair = "sit", barstool = "sit", bar_seat = "sit", bed = "lie", lean_wall = "lean", bench = "sit" }
function F.catalog(furniture, version)
    local kinds, kindIndex, postures = {}, {}, { "sit", "lie", "lean" }
    local profiles, profileIndex = {}, {}
    local resources, resourceIndex, resourceKind, resourceArrival = {}, {}, {}, {}
    local verification = { "measured", "unverified", "refused", "none" }
    local verificationIndex = { measured = 1, unverified = 2, refused = 3, none = 4 }
    local chunk = { first = {}, flags = {}, gid = {}, x = {}, y = {}, z = {}, yaw = {}, res = {}, prof = {}, ver = {},
        ped = {}, crowd = {} }
    local spots = 0
    for _, item in ipairs(furniture) do
        chunk.first[#chunk.first + 1] = #chunk.gid + 1
        chunk.flags[#chunk.flags + 1] = item.flags or 0
        for _, pose in ipairs(item.poses) do
            if not kindIndex[pose.kind] then kinds[#kinds + 1] = pose.kind; kindIndex[pose.kind] = #kinds end
            local resource = "res_" .. pose.kind .. "_" .. tostring(pose.arrival or 0.5)
            if not resourceIndex[resource] then
                resources[#resources + 1] = resource
                resourceIndex[resource] = #resources
                resourceKind[#resources] = kindIndex[pose.kind]
                resourceArrival[#resources] = pose.arrival or 0.5
            end
            local prof = 0
            if pose.profile then
                if not profileIndex[pose.profile] then
                    profiles[#profiles + 1] = pose.profile
                    profileIndex[pose.profile] = #profiles
                end
                prof = profileIndex[pose.profile]
            end
            local n = #chunk.gid + 1
            chunk.gid[n], chunk.x[n], chunk.y[n], chunk.z[n], chunk.yaw[n] = pose.gid, pose.x, pose.y, pose.z, pose.yaw or 0
            chunk.res[n], chunk.prof[n] = resourceIndex[resource], prof
            chunk.ver[n] = verificationIndex[pose.verification or (pose.profile and "measured" or "none")]
            chunk.ped[n], chunk.crowd[n] = 0, 0
            spots = spots + 1
        end
    end
    local kindPosture = {}
    for i, kind in ipairs(kinds) do
        local posture = KIND_POSTURE[kind] or "sit"
        kindPosture[i] = posture == "sit" and 1 or posture == "lie" and 2 or 3
    end
    return {
        schema = 1, version = version or "furniture-1-test00000000", datasetId = "test", runtimeValidated = false,
        furniture = #furniture, spots = spots, chunkCount = 1, postures = postures, kinds = kinds,
        kindPosture = kindPosture, profiles = profiles, verification = verification, resources = resources,
        resourceKind = resourceKind, resourceArrival = resourceArrival, chunks = { chunk },
    }
end

function F.installFurniture(furniture, version)
    local index = Open77FurnitureIndex.new(F.catalog(furniture, version))
    index:build()
    F.furnitureIndex = index
    F.exportHandlers.open77_furniture = {
        nearby = function(position, radius, filter) return index:nearby(position, radius, filter) end,
        get = function(id) return index:get(id) end,
        status = function() return index:status() end,
    }
end

-- open77_actions: the real claims service. Seats claim as the resource
-- (holder "res:<owner>"), exactly as the export does.
function F.installActions()
    local claims = Open77ActionsClaims.new({ now = function() return F.now end })
    F.claims = claims
    F.exportHandlers.open77_actions = {
        claim = function(bucket, key, ttl)
            local token, why = claims:acquire(bucket, key, "res:" .. F.invoker, ttl, F.invoker)
            return token, why
        end,
        -- As the real exports: a token is only its owner's to renew or release (a
        -- restarted claims service mints "c1" again for somebody else).
        renewClaim = function(token, ttl)
            local entry = claims:get(token)
            if entry == nil then return nil, "claim_lost" end
            if entry.owner ~= F.invoker then return nil, "not_owner" end
            return claims:renew(token, ttl)
        end,
        releaseClaim = function(token)
            local entry = claims:get(token)
            if entry == nil then return nil, "claim_lost" end
            if entry.owner ~= F.invoker then return nil, "not_owner" end
            return claims:release(token)
        end,
        claimHolder = function(bucket, key)
            local entry = claims:holder(bucket, key)
            if entry == nil then return nil end
            return { holder = entry.holder, owner = entry.owner, remainingMs = entry.expiresAt - F.now }
        end,
        current = function(pid) return F.actionsBusy[pid] end,
        carrying = function(pid) return F.carrying[pid] end,
    }
end

-- open77_pedestrians: the real seat guard; pedestrians are F.npcs rows.
function F.installPedestrians()
    local G = Open77PedestrianSeatGuard
    local guard = G.new(function() return F.now / 1000 end)
    F.guard = guard
    local function occupantNear(bucket, x, y, z, radius)
        for _, npc in ipairs(F.npcs) do
            local dx, dy = npc.x - x, npc.y - y
            if npc.bucket == bucket and dx * dx + dy * dy <= radius * radius and math.abs(npc.z - z) <= 1.0 then
                return { npc = npc.npc, state = npc.state, source = npc.source or "seated" }
            end
        end
        return nil
    end
    F.exportHandlers.open77_pedestrians = {
        holdSeat = function(bucket, key, position, options)
            local request, why = G.parse(bucket, key, position, options)
            if not request then return nil, why end
            local occupant = occupantNear(request.bucket, request.x, request.y, request.z, request.radius)
            if occupant and not request.force then return nil, "npc_occupied", occupant end
            guard:hold(F.invoker, request)
            return true, occupant
        end,
        releaseSeat = function(bucket, key) return guard:release(F.invoker, bucket, key) end,
        seatOccupants = function(bucket, points, radius)
            local out = {}
            for i, p in ipairs(points) do out[i] = occupantNear(bucket, p.x, p.y, p.z, radius) or false end
            return out
        end,
    }
end

-- --- helpers the suite drives the fakes with ------------------------------
function F.player(pid, x, y, z, overrides)
    local read = {
        playerId = pid, bucket = 0, ready = true, fresh = true, ageMs = 50, alive = true, dead = false,
        inVehicle = false, heading = 0, position = { x = x or 0, y = y or 0, z = z or 0 },
        flags = { combatValid = true, aiming = false, triggerDown = false },
    }
    for key, value in pairs(overrides or {}) do read[key] = value end
    F.players[pid] = read
    return read
end

function F.fire(event, ...)
    for _, fn in ipairs(F.handlers[event] or {}) do fn(...) end
end

function F.net(event, pid, ...)
    source = pid
    F.netHandlers[event](...)
    source = nil
end

function F.command(name, src, args)
    F.commands[name].fn(src, args or {}, "")
end

-- Call one of this resource's exports as resource `as`.
function F.call(as, name, ...)
    F.invoker = as
    local values = table.pack(F.exports[name](...))
    F.invoker = nil
    return table.unpack(values, 1, values.n)
end

function F.clientEvents(name, target)
    local out = {}
    for _, entry in ipairs(F.client) do
        if entry.name == name and (target == nil or entry.target == target) then out[#out + 1] = entry end
    end
    return out
end

function F.lastClient(name, target)
    local list = F.clientEvents(name, target)
    return list[#list]
end

function F.anim(op)
    local out = {}
    for _, entry in ipairs(F.animLog) do if entry.op == op then out[#out + 1] = entry end end
    return out
end

function F.printed(fragment)
    for _, line in ipairs(F.prints) do
        if line:find(fragment, 1, true) then return line end
    end
    return nil
end

function F.reset()
    F.client, F.host, F.prints, F.animLog, F.teleports, F.deferred = {}, {}, {}, {}, {}, {}
end
