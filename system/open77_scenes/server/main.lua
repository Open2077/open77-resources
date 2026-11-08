-- =============================================================================
-- open77_scenes -- server/main.lua
-- =============================================================================
-- Runtime wiring of server/core.lua: the platform ports, the client transport,
-- /scene and /stand-up for players, the exports other resources call and a
-- lab console (`scenes.*`, restricted) used to place and calibrate scenes.
-- =============================================================================

local S = Open77Scenes
local Core = Open77ScenesCore
assert(S and Core and Open77SceneSpots, "open77_scenes: shared/scenes.lua, server/spots-generated.lua and server/core.lua must load first")

local RESOURCE = GetCurrentResourceName()
local GENERATION = (GetCurrentResourceGeneration and GetCurrentResourceGeneration()) or Open77.resource.generation()

local function nowMs() return math.floor(Open77.time.monotonic() * 1000) end
local function playerId(value)
    local n = math.tointeger(tonumber(value))
    if n and n > 0 and n <= 9007199254740991 then return n end
    return nil
end
local function say(fmt, ...) print("[scenes] " .. fmt:format(...)) end

local function convar(name, default)
    if GetConvar == nil then return default end
    local value = GetConvar(name, default)
    if value == nil or value == "" then return default end
    return value
end

-- ---------------------------------------------------------------------------
-- Ports
-- ---------------------------------------------------------------------------
local P = {
    generation = GENERATION,
    now = nowMs,
    readPlayer = function(pid)
        local ok, read = pcall(Open77.players.get, pid)
        if ok and type(read) == "table" then return read end
        return nil
    end,
    sequenceAt = function(pid, steps, position, yaw, options)
        local ok, state, why = pcall(Open77.animations.sequenceAt, pid, steps, position, yaw, options)
        if not ok then return nil, tostring(state) end
        return state, why
    end,
    stopAt = function(playbackId)
        if type(playbackId) == "string" then pcall(Open77.animations.stopAt, playbackId) end
    end,
    current = function(pid)
        local ok, state = pcall(Open77.animations.current, pid)
        if ok and type(state) == "table" then return state end
        return nil
    end,
    setHeading = function(pid, yaw)
        local ok, done, why = pcall(Open77.players.setHeading, pid, yaw)
        if not ok or not done then say("setHeading %s %.1f refused: %s", tostring(pid), yaw, tostring(ok and why or done)) end
    end,
    send = function(name, pid, payload) pcall(TriggerClientEvent, name, pid, payload) end,
    event = function(name, payload)
        if name == "open77_scenes:ended" then
            say("ended player %s scene=%s spot=%s reason=%s", tostring(payload.playerId), tostring(payload.scene),
                tostring(payload.spot), tostring(payload.reason))
        end
        pcall(TriggerEvent, name, payload)
    end,
}

local core = Core.new(P, {
    reach = tonumber(convar("open77_scenes_reach", "3.0")),
    promptRadius = tonumber(convar("open77_scenes_prompt_radius", "3.0")),
    turnBeforeEndMs = tonumber(convar("open77_scenes_turn_before_end_ms", "0")),
})
Open77ScenesRuntime = { core = core, P = P }

-- The scanned furniture: every generated spot whose kind a scene claims.
local loaded, skipped = 0, 0
for _, spot in ipairs(Open77SceneSpots.spots) do
    if core:addSpot(spot, nil) then loaded = loaded + 1 else skipped = skipped + 1 end
end

-- ---------------------------------------------------------------------------
-- Exports
-- ---------------------------------------------------------------------------
--- start(playerId, spotId, options?) -> state | nil, reason
exports("start", function(pid, spotId, options)
    pid = playerId(pid)
    if pid == nil then return nil, "invalid_player" end
    return core:start(pid, spotId, options)
end)
--- stand(playerId, { instant? }) -> true | nil, reason
exports("stand", function(pid, options)
    pid = playerId(pid)
    if pid == nil then return nil, "invalid_player" end
    return core:stand(pid, options)
end)
--- setIdle(playerId, index?) -> state | nil, reason (nil index: the next idle)
exports("setIdle", function(pid, index)
    pid = playerId(pid)
    if pid == nil then return nil, "invalid_player" end
    return core:setIdle(pid, index)
end)
exports("current", function(pid)
    pid = playerId(pid)
    return pid and core:current(pid) or nil
end)
--- nearby(position, radius?, bucket?) -> { { id, scene, kind, distance, holder, anchor }, ... }
exports("nearby", function(position, radius, bucket)
    if type(position) ~= "table" then return nil, "invalid_position" end
    local out = {}
    for _, near in ipairs(core:nearby({ x = position.x or position[1], y = position.y or position[2], z = position.z or position[3] },
        math.min(tonumber(radius) or 10, 50), math.tointeger(tonumber(bucket)) or 0, 32)) do
        out[#out + 1] = { id = near.spot.id, scene = near.spot.scene, kind = near.spot.kind, distance = near.distance,
            holder = near.holder, anchor = near.anchor }
    end
    return out
end)
--- registerSpot({ id, scene | kind, x, y, z, yaw }) -> spot | nil, reason. Removed with the caller.
exports("registerSpot", function(spot)
    local owner = GetInvokingResource and GetInvokingResource() or "unknown"
    return core:addSpot(spot, owner)
end)
exports("removeSpot", function(id)
    local owner = GetInvokingResource and GetInvokingResource() or "unknown"
    return core:removeSpot(id, owner)
end)
exports("scenes", function()
    local out = {}
    for id, scene in pairs(S.definitions) do out[#out + 1] = { id = id, label = scene.label, profile = scene.profile } end
    table.sort(out, function(a, b) return a.id < b.id end)
    return out
end)

-- ---------------------------------------------------------------------------
-- Client transport (the minimum intent; everything is re-derived here)
-- ---------------------------------------------------------------------------
local intents = {}
local function allow(pid)
    local now = nowMs()
    local entry = intents[pid]
    if entry == nil or now - entry.since > 2000 then
        intents[pid] = { since = now, count = 1 }
        return true
    end
    entry.count = entry.count + 1
    return entry.count <= 6
end

local function refuse(pid, reason)
    P.send("open77:scenes:refused", pid, { generation = GENERATION, reason = reason })
end

RegisterNetEvent("open77:scenes:start", function(spotId)
    local pid = playerId(source)
    if pid == nil or not allow(pid) or type(spotId) ~= "string" or #spotId > 96 then return end
    local state, why = core:start(pid, spotId, {})
    if state == nil then refuse(pid, why) end
end)

RegisterNetEvent("open77:scenes:stand", function()
    local pid = playerId(source)
    if pid == nil or not allow(pid) then return end
    local ok, why = core:stand(pid)
    if not ok then refuse(pid, why) end
end)

RegisterNetEvent("open77:scenes:idle", function()
    local pid = playerId(source)
    if pid == nil or not allow(pid) then return end
    local ok, why = core:setIdle(pid)
    if not ok then refuse(pid, why) end
end)

RegisterNetEvent("open77:scenes:sync", function()
    local pid = playerId(source)
    if pid == nil then return end
    core.prompts[pid] = nil
    local current = core:current(pid)
    P.send("open77:scenes:state", pid, current and (function()
        current.generation = GENERATION
        return current
    end)() or { generation = GENERATION, active = false })
end)

-- /scene: the nearest free spot in reach; /standup ends the caller's scene.
RegisterCommand("scene", function(src)
    local pid = playerId(src)
    if pid == nil then return end
    local actor, why = core:actor(pid)
    if not actor then refuse(pid, why); return end
    for _, near in ipairs(core:nearby(actor.position, core.config.reach, actor.bucket, 4)) do
        if near.holder == nil then
            local state, refused = core:start(pid, near.spot.id, {})
            if state == nil then refuse(pid, refused) end
            return
        end
    end
    refuse(pid, "no_spot")
end, false)

RegisterCommand("standup", function(src)
    local pid = playerId(src)
    if pid == nil then return end
    local ok, why = core:stand(pid)
    if not ok then refuse(pid, why) end
end, false)

-- ---------------------------------------------------------------------------
-- Platform events
-- ---------------------------------------------------------------------------
AddEventHandler("onPlayerDisconnected", function(pid)
    pid = playerId(pid)
    if pid then core:forget(pid); intents[pid] = nil end
end)

AddEventHandler("onPlayerAnimationChanged", function(pid, value)
    pid = playerId(pid)
    if pid == nil or core.byPlayer[pid] == nil then return end
    if type(value) == "string" then
        local ok, decoded = pcall(json.decode, value)
        if not ok then return end
        value = decoded
    end
    core:onAnimation(pid, value)
end)

-- A resource that registered spots took them with it.
AddEventHandler("onResourceStop", function(name)
    if name == RESOURCE then core:shutdown(); return end
    for id, spot in pairs(core.spots) do
        if spot.owner == name then core.spots[id] = nil end
    end
end)

CreateThread(function()
    say("open77_scenes %s ready (generation %s, %d spots from %s, %d skipped)", S.VERSION, tostring(GENERATION),
        loaded, Open77SceneSpots.version, skipped)
    while true do
        Wait(250)
        local ok, err = pcall(core.tick, core)
        if not ok then say("tick raised: %s", tostring(err)) end
        local roster = {}
        for _, id in ipairs(GetPlayers() or {}) do
            local pid = playerId(id)
            if pid then roster[#roster + 1] = pid end
        end
        ok, err = pcall(core.refreshPrompts, core, roster)
        if not ok then say("prompt pass raised: %s", tostring(err)) end
    end
end)

-- ---------------------------------------------------------------------------
-- Lab console (restricted). Lines start with "[scenes]".
-- ---------------------------------------------------------------------------
local function fmt(v) return string.format("%.3f", v) end

RegisterCommand("scenes.status", function()
    local count = 0
    for pid, session in pairs(core.byPlayer) do
        count = count + 1
        say("player %d scene=%s spot=%s phase=%s idle=%d playback=%s", pid, session.scene, session.spot, session.phase,
            session.idle, tostring(session.playbackId))
    end
    local spots = 0
    for _ in pairs(core.spots) do spots = spots + 1 end
    say("%d active, %d spots", count, spots)
end, true)

RegisterCommand("scenes.near", function(_, args)
    local pid = playerId(args[1])
    local actor = pid and core:actor(pid)
    if not actor then say("near: player %s unavailable", tostring(args[1])); return end
    say("player %d at %s %s %s bucket %d", pid, fmt(actor.position.x), fmt(actor.position.y), fmt(actor.position.z), actor.bucket)
    for _, near in ipairs(core:nearby(actor.position, tonumber(args[2]) or 15, actor.bucket, 8)) do
        say("  %s scene=%s d=%.2f anchor=%s,%s,%s yaw=%.1f stand=%s,%s holder=%s", near.spot.id, near.spot.scene, near.distance,
            fmt(near.anchor.x), fmt(near.anchor.y), fmt(near.anchor.z), near.anchor.yaw, fmt(near.stand.x), fmt(near.stand.y),
            tostring(near.holder))
    end
end, true)

RegisterCommand("scenes.start", function(_, args)
    local pid = playerId(args[1])
    if pid == nil then say("usage: scenes.start <player> [spot] [idle]"); return end
    local spot = args[2]
    if spot == nil or spot == "-" then
        local actor = core:actor(pid)
        local near = actor and core:nearby(actor.position, core.config.reach, actor.bucket, 1)[1]
        spot = near and near.spot.id
    end
    local state, why = core:start(pid, spot, { idle = tonumber(args[3]) })
    if state then say("start %d %s -> playback %s", pid, tostring(spot), tostring(state.playbackId))
    else say("start %d %s refused: %s", pid, tostring(spot), tostring(why)) end
end, true)

RegisterCommand("scenes.stand", function(_, args)
    local pid = playerId(args[1])
    local ok, why = core:stand(pid, { instant = args[2] == "instant" })
    say("stand %s -> %s %s", tostring(pid), tostring(ok), tostring(why or ""))
end, true)

RegisterCommand("scenes.idle", function(_, args)
    local pid = playerId(args[1])
    local state, why = core:setIdle(pid, tonumber(args[2]))
    say("idle %s -> %s %s", tostring(pid), state and tostring(state.idle) or "refused", tostring(why or ""))
end, true)

-- Calibration: scenes.tune <kind> <dx> <dy> <dz> <dyaw> moves the anchor of every
-- spot of a furniture kind (furniture frame). Live only: copy the result into
-- shared/scenes.lua once it looks right.
RegisterCommand("scenes.tune", function(_, args)
    local furniture = args[1] and S.furniture[args[1]]
    if furniture == nil then say("usage: scenes.tune <kind> <dx> <dy> <dz> <dyaw>"); return end
    furniture.offset = { x = tonumber(args[2]) or 0, y = tonumber(args[3]) or 0, z = tonumber(args[4]) or 0, yaw = 0 }
    furniture.yaw = tonumber(args[5]) or 0
    say("tune %s offset=%s,%s,%s yaw=%s", args[1], fmt(furniture.offset.x), fmt(furniture.offset.y), fmt(furniture.offset.z), fmt(furniture.yaw))
end, true)
