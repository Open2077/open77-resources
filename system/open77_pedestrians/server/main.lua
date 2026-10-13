local function output(source, raw, success, text)
    print(text)
    if source and source > 0 then
        TriggerClientEvent("open77:command:result", source, raw or "", success == true, text)
    end
end

-- A hit or a death on either kind scares both: `api.panicNear` reaches the two schedulers.
local seated, crowd

local api = {
    players = function()
        local rows = {}
        for playerId, position in pairs(Open77.players.positions() or {}) do
            local id = tonumber(playerId)
            local ready = id ~= nil and Open77.ready.isReady(id) == true
            -- A dead or dying player's client still streams the NPCs around it: it counts as a watcher.
            if ready and position and position.x and position.y and position.z then
                local life = Open77.players.getLifeState(id)
                rows[#rows + 1] = { id = id, x = position.x, y = position.y,
                    z = position.z, bucket = position.bucket or 0,
                    alive = type(life) == "table" and life.phase == "alive" }
            end
        end
        return rows
    end,
    secondsOfDay = function(bucket)
        return (Open77.environment.getState(bucket) or {}).secondsOfDay
    end,
    now = function() return Open77.time.monotonic() end,
    clips = function(profile) return (Open77.animations.get(profile) or {}).clips end,
    -- The seated pedestrians are created frozen (the platform's default) and the walkers on tasks:
    -- each scheduler names its `aiMode`.
    create = function(def)
        def.aiMode = Open77.npcs.ai[def.aiMode or "frozen"]
        def.damagePolicy = Open77.npcs.damage[def.damagePolicy]
        return Open77.npcs.create(def)
    end,
    damage = function(id, amount, source, cause) return Open77.npcs.applyDamage(id, amount, source, cause or "shot") end,
    setDamagePolicy = function(id, policy) return Open77.npcs.setDamagePolicy(id, Open77.npcs.damage[policy]) end,
    remove = function(id) return Open77.npcs.remove(id) end,
    position = function(id)
        local npc = Open77.npcs.get(id)
        return npc and { x = npc.x, y = npc.y, z = npc.z, yaw = npc.yaw }
    end,
    -- This resource's NPC rows (x, y, z, ...), once per crowd tick.
    npcs = function() return Open77.npcs.all() end,
    alive = function(id)
        local npc = Open77.npcs.get(id)
        return npc ~= nil and (npc.flags & Open77.npcs.flags.alive) ~= 0
    end,
    workspot = function(id, profile, options) return Open77.npcs.tasks.workspot(id, profile, options) end,
    cancel = function(id, taskId, reason) return Open77.npcs.tasks.cancel(id, taskId, reason) end,
    setAiMode = function(id, mode) return Open77.npcs.setAiMode(id, Open77.npcs.ai[mode]) end,
    flee = function(id, from, options) return Open77.npcs.tasks.flee(id, from, options) end,
    moveTo = function(id, position, options) return Open77.npcs.tasks.moveTo(id, position, options) end,
    traffic = function(id, options) return Open77.npcs.tasks.traffic(id, options) end,
    panicNear = function(bucket, origin, exceptNpc)
        seated:panicNeighbours(bucket, origin, exceptNpc)
        crowd:panicNeighbours(bucket, origin, exceptNpc)
    end,
    random = function(low, high) return math.random(low, high) end,
    yield = function() Wait(0) end,
    log = function(fmt, ...) print(string.format(fmt, ...)) end,
}

-- Seats players hold (row B6, open77_seating): both schedulers keep their pedestrians off them.
local guard = Open77PedestrianSeatGuard.new(api.now)
api.seatBlocked = function(bucket, x, y, z) return guard:blocks(bucket, x, y, z) ~= nil end

seated = Open77PedestrianScheduler.new(Open77PedestrianSpotCatalog, Open77PedestrianConfig, api)
crowd = Open77CrowdScheduler.new(Open77CrowdLaneCatalog, Open77CrowdSpotCatalog, Open77PedestrianConfig, api)

-- ---------------------------------------------------------------------------
-- Seat holds for other resources (row B6, docs/world-interaction/b6-seating.md)
-- ---------------------------------------------------------------------------
-- The pedestrian holding a seat near a point: a seated (or returning) one at its spot, a corpse where it
-- lies, of either scheduler. Before the schedulers have indexed there is none.
local function occupantNear(bucket, x, y, z, radius)
    return seated:occupantNear(bucket, x, y, z, radius) or crowd:occupantNear(bucket, x, y, z, radius)
end

local function invoker()
    local owner = GetInvokingResource and GetInvokingResource() or nil
    if type(owner) ~= "string" or owner == "" then return nil end
    return owner
end

-- holdSeat(bucket, key, position, options?) -> true[, overlap] | nil, reason[, occupant]
--   options: radius (0.3-1.5 m, default 0.6), ttlMs (1000-600000, default 30000), force.
-- Atomic: refused with "npc_occupied" (and the occupant: npc, state, source, spot, distance) when a
-- pedestrian holds a seat within the radius, else the hold is registered or refreshed. From then on no
-- pedestrian spawns, visits or walks back within the radius until it is released, lapses or its owner
-- stops. `force` registers it anyway and returns the overlapping pedestrian second: the owner refreshes
-- a seat its player already sits on (this resource may have restarted in between).
exports("holdSeat", function(bucket, key, position, options)
    local owner = invoker()
    if not owner then return nil, "owner_unavailable" end
    local request, reason = Open77PedestrianSeatGuard.parse(bucket, key, position, options)
    if not request then return nil, reason end
    local occupant = occupantNear(request.bucket, request.x, request.y, request.z, request.radius)
    if occupant and not request.force then return nil, "npc_occupied", occupant end
    local entry, why = guard:hold(owner, request)
    if not entry then return nil, why end
    return true, occupant
end)

-- releaseSeat(bucket, key) -> boolean: drops the caller's own hold.
exports("releaseSeat", function(bucket, key)
    local owner = invoker()
    if not owner then return false end
    return guard:release(owner, bucket, key)
end)

-- seatOccupants(bucket, points, radius?) -> list aligned with `points` (at most 8 `{ x, y, z }`): false, or
-- the pedestrian holding a seat there. A read for prompts; `holdSeat` decides.
exports("seatOccupants", function(bucket, points, radius)
    bucket = math.tointeger(tonumber(bucket))
    if bucket == nil or type(points) ~= "table" or #points > 8 then return nil, "invalid_request" end
    radius = tonumber(radius) or Open77PedestrianSeatGuard.DEFAULT_RADIUS
    if radius ~= radius or radius < Open77PedestrianSeatGuard.MIN_RADIUS or
        radius > Open77PedestrianSeatGuard.MAX_RADIUS then
        return nil, "invalid_request"
    end
    local out = {}
    for i, point in ipairs(points) do
        local x, y, z = type(point) == "table" and tonumber(point.x), type(point) == "table" and tonumber(point.y),
            type(point) == "table" and tonumber(point.z)
        out[i] = (x and y and z) and occupantNear(bucket, x, y, z, radius) or false
    end
    return out
end)
local stopping = false
-- A fault that lasts would fill the log four times a second: the first failure of a scheduler is
-- printed, then one line a minute with the number of its failures since the previous line.
local REPORT_EVERY_S = 60
local function guarded(label)
    local failures, reportedAt = 0, nil
    return function(ok, err)
        if ok then return end
        failures = failures + 1
        local now = api.now()
        if not reportedAt or now - reportedAt >= REPORT_EVERY_S then
            print(string.format("pedestrians: %stick failed: %s (%d since the last report)",
                label, tostring(err), failures))
            failures, reportedAt = 0, now
        end
    end
end
local reportSeated, reportCrowd = guarded(""), guarded("crowd ")
CreateThread(function()
    -- Both passes spend one work budget a tick: together they stay within the slice the platform's
    -- instruction quota allows between two yields.
    local budget = { work = 0, slices = 0 }
    while not stopping do
        budget.work, budget.slices = 0, 0
        guard:sweep()
        -- An error in one pass (the instruction quota included) costs that pass, not the loop:
        -- the platform drops a thread that errors, and pedestrians would stop for good.
        reportSeated(pcall(seated.tick, seated, budget))
        reportCrowd(pcall(crowd.tick, crowd, budget))
        Wait(Open77PedestrianConfig.tickMs)
    end
end)

AddEventHandler("onResourceStop", function(name)
    if name == GetCurrentResourceName() then
        stopping = true
    else
        -- A resource that held seats is gone: its players no longer sit there.
        guard:releaseOwner(name)
    end
end)
-- Each scheduler ignores the NPCs it does not own.
AddEventHandler("onNpcDamaged", function(npcId, source)
    npcId = tostring(npcId)
    seated:onDamaged(npcId, source)
    crowd:onDamaged(npcId, source)
end)
AddEventHandler("onNpcDied", function(npcId)
    npcId = tostring(npcId)
    seated:onDied(npcId)
    crowd:onDied(npcId)
end)
AddEventHandler("onNpcTaskState", function(npcId, taskId, status, reason)
    npcId, taskId = tostring(npcId), tostring(taskId)
    seated:onTaskState(npcId, taskId, status)
    crowd:onTaskState(npcId, taskId, status, reason)
end)
AddEventHandler("onNpcRemoved", function(npcId)
    npcId = tostring(npcId)
    seated:onRemoved(npcId)
    crowd:onRemoved(npcId)
end)
-- The shooter's client forwards its own hits (client/main.lua); the server prices them.
RegisterNetEvent("open77_pedestrians:hit", function(payload)
    local player = tonumber(source)
    if player == nil or player <= 0 or type(payload) ~= "table" then return end
    local npcId = tostring(payload.npcId)
    seated:onHit(npcId, player)
    crowd:onHit(npcId, player)
end)

RegisterCommand("pedestrians.status", function(source, _, raw)
    local state = seated:status()
    output(source, raw, true, string.format(
        "pedestrians enabled=%s spots=%d entries=%d profiles=%d disabledSpots=%d slices=%d groups=%d share=%d",
        tostring(state.enabled), state.spots, state.entries, state.profiles, state.disabledSpots, state.slices,
        state.groups, state.share))
    for bucket, counts in pairs(state.active) do
        output(source, raw, true, string.format(
            "pedestrians bucket=%s seated=%d panicking=%d cowering=%d returning=%d dead=%d", tostring(bucket),
            counts.seated, counts.panicking, counts.cowering, counts.returning, counts.dead))
    end
    output(source, raw, true, string.format("pedestrians cooldowns=%d", state.cooldowns))
    for reason, count in pairs(state.failures) do
        output(source, raw, true, string.format("pedestrians failure=%s count=%d", reason, count))
    end
    local walking = crowd:status()
    output(source, raw, true, string.format(
        "pedestrians crowd enabled=%s lanes=%d points=%d spots=%d slices=%d",
        tostring(walking.enabled), walking.lanes, walking.points, walking.spots, walking.slices))
    for bucket, counts in pairs(walking.active) do
        output(source, raw, true, string.format(
            "pedestrians crowd bucket=%s walking=%d seated=%d panicking=%d dead=%d", tostring(bucket),
            counts.walking, counts.seated, counts.panicking, counts.dead))
    end
    output(source, raw, true, string.format("pedestrians crowd cooldowns=%d", walking.cooldowns))
    for reason, count in pairs(walking.failures) do
        output(source, raw, true, string.format("pedestrians crowd failure=%s count=%d", reason, count))
    end
end, true)
RegisterCommand("pedestrians.seats", function(source, _, raw)
    local holds = guard:list()
    output(source, raw, true, string.format("pedestrians seat holds=%d", #holds))
    for _, hold in ipairs(holds) do
        output(source, raw, true, string.format(
            "pedestrians seat owner=%s bucket=%d key=%s at=%.3f,%.3f,%.3f radius=%.2f remainingMs=%d",
            hold.owner, hold.bucket, hold.key, hold.x, hold.y, hold.z, hold.radius, hold.remainingMs))
    end
    for reason, count in pairs(seated:status().failures) do
        if reason == "seat_held" then
            output(source, raw, true, string.format("pedestrians seat returnsDiverted=%d", count))
        end
    end
end, true)
RegisterCommand("pedestrians.reset", function(source, _, raw)
    seated:reset()
    crowd:reset()
    output(source, raw, true, "pedestrians reset")
end, true)
RegisterCommand("pedestrians.enable", function(source, args, raw)
    if args.n ~= 1 or (args[1] ~= "on" and args[1] ~= "off") then
        return output(source, raw, false, "usage: pedestrians.enable <on|off>")
    end
    seated:setEnabled(args[1] == "on")
    output(source, raw, true, "pedestrians enabled=" .. tostring(args[1] == "on"))
end, true)
RegisterCommand("pedestrians.crowd", function(source, args, raw)
    if args.n ~= 1 or (args[1] ~= "on" and args[1] ~= "off") then
        return output(source, raw, false, "usage: pedestrians.crowd <on|off>")
    end
    crowd:setEnabled(args[1] == "on")
    output(source, raw, true, "pedestrians crowd enabled=" .. tostring(args[1] == "on"))
end, true)
-- Live switches for the open77_pedestrians_mortal / _panic convars (which only seed them at start).
for name, apply in pairs({ mortal = "setMortal", panic = "setPanic" }) do
    RegisterCommand("pedestrians." .. name, function(source, args, raw)
        if args.n ~= 1 or (args[1] ~= "on" and args[1] ~= "off") then
            return output(source, raw, false, "usage: pedestrians." .. name .. " <on|off>")
        end
        seated[apply](seated, args[1] == "on")
        crowd[apply](crowd, args[1] == "on")
        output(source, raw, true, "pedestrians " .. name .. "=" .. tostring(args[1] == "on"))
    end, true)
end
