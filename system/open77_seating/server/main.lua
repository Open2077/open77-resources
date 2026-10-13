-- =============================================================================
-- open77_seating -- server/main.lua
-- =============================================================================
-- Runtime wiring of the seating lifecycle (server/core.lua): the ports to the
-- platform and to the three resources it composes, the platform events that
-- end a seat, the client transport, the player commands /sit and /stand, the
-- exports other resources call, and the lab console the integrator drives the
-- two-client proof with (docs/world-interaction/b6-seating.md).
--
--   open77_furniture    nearby / get / status: the catalogue (no world query)
--   open77_actions      claim / renewClaim / releaseClaim / claimHolder:
--                       the furniture group's bucket-scoped claim, shared with
--                       every resource that claims "furniture:<version>:<id>"
--   open77_pedestrians  holdSeat / releaseSeat / seatOccupants (optional:
--                       without it nothing spawns NPCs to coordinate with)
-- =============================================================================

local M = Open77SeatingModel
local Core = Open77SeatingCore
assert(M and Core, "open77_seating: shared/model.lua and server/core.lua must load first")

local RESOURCE = GetCurrentResourceName()
local GENERATION = (GetCurrentResourceGeneration and GetCurrentResourceGeneration()) or Open77.resource.generation()
local TICK_MS = 250

local function nowMs() return math.floor(Open77.time.monotonic() * 1000) end

local function convar(name, default)
    if GetConvar == nil then return default end
    local value = GetConvar(name, default)
    if value == nil or value == "" then return default end
    return value
end

-- ---------------------------------------------------------------------------
-- Configuration
-- ---------------------------------------------------------------------------
local function parseVerification(value)
    local set = {}
    for state in tostring(value):gmatch("[^,%s]+") do
        if state == "all" then
            set.measured, set.unverified = true, true
        elseif state == "measured" or state == "unverified" then
            set[state] = true
        end
    end
    if next(set) == nil then set.measured = true end
    return set
end

-- Which postures prompts, /sit and the exports offer: a comma list of sit,
-- lean and lie, or "all" (the default). Lab commands ignore it.
local function parsePostures(value)
    local set = {}
    for posture in tostring(value):gmatch("[^,%s]+") do
        if posture == "all" then
            set.sit, set.lean, set.lie = true, true, true
        elseif posture == "sit" or posture == "lean" or posture == "lie" then
            set[posture] = true
        end
    end
    if next(set) == nil then return M.config().postures end
    return set
end

local function parseBuckets(value)
    if value == nil or value == "" or value == "all" then return nil end
    local set = {}
    for item in tostring(value):gmatch("[^,%s]+") do
        local n = math.tointeger(tonumber(item))
        if n and n >= 0 then set[n] = true end
    end
    return next(set) and set or nil
end

local config = M.config({
    verification = parseVerification(convar("open77_seating_verification", "measured")),
    postures = parsePostures(convar("open77_seating_postures", "all")),
    buckets = parseBuckets(convar("open77_seating_buckets", "all")),
})
local exitMode = convar("open77_seating_exit", "approach")
if M.EXIT_MODES[exitMode] then config.exitMode = exitMode end

-- ---------------------------------------------------------------------------
-- Roster (an id is checked before any player native: an id of 0 from the
-- console stops a resource that passes it to a player native)
-- ---------------------------------------------------------------------------
local roster, rosterList, rosterAt = {}, {}, -math.huge
local function refreshRoster()
    local now = nowMs()
    if now - rosterAt < 250 then return end
    rosterAt = now
    roster, rosterList = {}, {}
    for _, id in ipairs(GetPlayers() or {}) do
        local n = M.playerId(id)
        if n then
            roster[n] = true
            rosterList[#rosterList + 1] = n
        end
    end
    table.sort(rosterList)
end

local function connected(pid)
    pid = M.playerId(pid)
    if pid == nil then return false end
    refreshRoster()
    if roster[pid] then return true end
    -- A player who joined since the last refresh is not refused for 250 ms.
    rosterAt = -math.huge
    refreshRoster()
    return roster[pid] == true
end

local function readPlayer(pid)
    if not connected(pid) then return nil end
    local ok, read = pcall(Open77.players.get, pid)
    if not ok or type(read) ~= "table" then return nil end
    return read
end

-- A synchronous export of another resource: never raises here (a stopped
-- resource answers nil, reason).
local function sync(resource, name, ...)
    local ok, a, b, c = pcall(Open77.exports.callSync, resource, name, ...)
    if not ok then return nil, "unavailable", tostring(a) end
    return a, b, c
end

-- ---------------------------------------------------------------------------
-- Ports
-- ---------------------------------------------------------------------------
local P = {
    now = nowMs,
    say = function(line) print(line) end,
    connected = connected,
    readPlayer = readPlayer,
    furnitureNearby = function(position, radius, filter)
        local list, why = sync("open77_furniture", "nearby", position, radius, filter)
        if type(list) ~= "table" then return nil, why == "unavailable" and "furniture_unavailable" or why end
        return list
    end,
    furnitureGet = function(id)
        local entry, why = sync("open77_furniture", "get", id)
        if type(entry) ~= "table" then return nil, why == "unavailable" and "furniture_unavailable" or why end
        return entry
    end,
    furnitureStatus = function()
        local status = sync("open77_furniture", "status")
        return type(status) == "table" and status or nil
    end,
    claim = function(bucket, key, ttlMs)
        local token, why = sync("open77_actions", "claim", bucket, key, ttlMs)
        if type(token) ~= "string" then
            return nil, why == "target_claimed" and "target_claimed" or "claims_unavailable"
        end
        return token
    end,
    renewClaim = function(token, ttlMs)
        local ok = sync("open77_actions", "renewClaim", token, ttlMs)
        return ok == true
    end,
    releaseClaim = function(token)
        sync("open77_actions", "releaseClaim", token)
    end,
    -- Something else already owns the player's body: an operation or a carry
    -- of open77_actions, or any running animation (an emote, another
    -- resource's posture). playAt would refuse it as animation_owned; asking
    -- first spares the approach move.
    actorBusy = function(pid)
        if sync("open77_actions", "current", pid) ~= nil then return "action" end
        if sync("open77_actions", "carrying", pid) ~= nil then return "carrying" end
        local ok, state = pcall(Open77.animations.current, pid)
        if ok and type(state) == "table" and state.active ~= false then return "animation" end
        return nil
    end,
    npcHold = function(bucket, key, position, options)
        local ok, why, info = sync("open77_pedestrians", "holdSeat", bucket, key, position, options)
        if ok == true then return true, why end
        return nil, why == "npc_occupied" and "npc_occupied" or "pedestrians_unavailable", info
    end,
    npcRelease = function(bucket, key)
        sync("open77_pedestrians", "releaseSeat", bucket, key)
    end,
    npcOccupants = function(bucket, points, radius)
        local list = sync("open77_pedestrians", "seatOccupants", bucket, points, radius)
        return type(list) == "table" and list or nil
    end,
    teleport = function(pid, position, options)
        local ok, promise, why = pcall(Open77.players.teleport, pid, position, options)
        if not ok then return nil, tostring(promise) end
        if promise == nil then return nil, why end
        local done, landed, reason = pcall(function() return promise:await() end)
        if not done then return nil, tostring(landed) end
        return landed, reason
    end,
    playAt = function(pid, profile, position, yaw, options)
        local ok, state, why = pcall(Open77.animations.playAt, pid, profile, position, yaw, options)
        if not ok then return nil, tostring(state) end
        return state, why
    end,
    stopAt = function(playbackId)
        local ok, done, why = pcall(Open77.animations.stopAt, playbackId)
        if not ok then return nil, tostring(done) end
        return done, why
    end,
    toClient = function(pid, name, payload)
        if not connected(pid) then return false end
        payload.generation = GENERATION
        local ok = pcall(TriggerClientEvent, name, pid, payload)
        return ok
    end,
    hostEvent = function(name, payload) pcall(TriggerEvent, name, payload) end,
    spawn = function(fn) CreateThread(fn) end,
    sleep = function(ms) Wait(math.floor(ms)) end,
}

local core = Core.new(P, config)
core.trace = convar("open77_seating_trace", "0") == "1"

-- Inspection handle for the offline suite (tests/*.lua): a global of this VM.
Open77SeatingRuntime = { core = core, config = config, ports = P }

-- ---------------------------------------------------------------------------
-- Exports (server resources: an RP bar, a job, a scene)
-- ---------------------------------------------------------------------------
local function exportOptions(options)
    options = type(options) == "table" and options or {}
    return {
        spot = M.furnitureId(options.spot),
        approach = M.APPROACH_NAMES[options.approach] and options.approach or nil,
        exit = M.EXIT_MODES[options.exit] and options.exit or nil,
    }
end

exports("sit", function(playerId, furnitureId, options)
    local session, why, info = core:sit(playerId, furnitureId, exportOptions(options))
    if session == nil then return nil, why, info end
    return core:public(session)
end)

exports("sitNearest", function(playerId, options)
    local session, why, info = core:sitNearest(playerId, exportOptions(options))
    if session == nil then return nil, why, info end
    return core:public(session)
end)

exports("stand", function(playerId)
    return core:stand(playerId, "stood")
end)

exports("current", function(playerId)
    local pid = M.playerId(playerId)
    return pid and core:public(core.byPlayer[pid]) or nil
end)

-- Who sits on a furniture in a bucket: a list of player ids (empty when free).
exports("occupants", function(bucket, furnitureId)
    bucket = math.tointeger(tonumber(bucket)) or 0
    local id, out = M.furnitureId(furnitureId), {}
    for pid, session in pairs(core.byPlayer) do
        if session.bucket == bucket and session.furnitureId == id then out[#out + 1] = pid end
    end
    table.sort(out)
    return out
end)

-- ---------------------------------------------------------------------------
-- Client transport
-- ---------------------------------------------------------------------------
local intents = {}
local function allowIntent(pid)
    local now = nowMs()
    local bucket = intents[pid]
    if bucket == nil or now - bucket.since > config.intentWindowMs then
        intents[pid] = { since = now, count = 1 }
        return true
    end
    bucket.count = bucket.count + 1
    return bucket.count <= config.intentBudget
end

local function refuse(pid, reason)
    P.toClient(pid, "open77:seating:refused", { reason = reason })
end

-- The minimum intent: which furniture. Everything else is re-derived here.
RegisterNetEvent("open77:seating:sit", function(furnitureId)
    local pid = M.playerId(source)
    if pid == nil or not allowIntent(pid) then return end
    if M.furnitureId(furnitureId) == nil then return end
    local session, why = core:sit(pid, furnitureId, {})
    if session == nil then refuse(pid, why) end
end)

RegisterNetEvent("open77:seating:stand", function()
    local pid = M.playerId(source)
    if pid == nil or not allowIntent(pid) then return end
    core:stand(pid, "stood")
end)

RegisterNetEvent("open77:seating:sync", function()
    local pid = M.playerId(source)
    if pid == nil then return end
    core:forgetPlayer(pid)
    local session = core.byPlayer[pid]
    P.toClient(pid, "open77:seating:state", { seated = session ~= nil and session.state == "seated",
        furnitureId = session and session.furnitureId or nil,
        label = session and M.label(session.kind, session.posture) or nil })
end)

-- Players: /sit (the nearest free seat in reach) and /stand.
RegisterCommand("sit", function(src)
    local pid = M.playerId(src)
    if pid == nil then print("[seating] /sit is a player command; the console uses seating.sit"); return end
    local session, why = core:sitNearest(pid, {})
    if session == nil then refuse(pid, why) end
end, false)

RegisterCommand("stand", function(src)
    local pid = M.playerId(src)
    if pid == nil then return end
    local ok, why = core:stand(pid, "stood")
    if not ok then refuse(pid, why) end
end, false)

-- ---------------------------------------------------------------------------
-- Platform events: every named end of a seat
-- ---------------------------------------------------------------------------
AddEventHandler("onPlayerDisconnected", function(playerId)
    local pid = M.playerId(playerId)
    if pid == nil then return end
    rosterAt = -math.huge
    roster[pid] = nil
    core:cancelPlayer(pid, "disconnected")
    core:forgetPlayer(pid)
    intents[pid] = nil
end)

AddEventHandler("onPlayerLifeStateChanged", function(playerId, _revision, phase)
    if phase == "alive" then return end
    core:cancelPlayer(playerId, "dead")
end)

AddEventHandler("onPlayerBucketChange", function(playerId)
    local pid = M.playerId(playerId)
    if pid == nil then return end
    core:cancelPlayer(pid, "bucket_changed")
    core:forgetPlayer(pid)
end)

local function vehicleEntry(playerId) core:cancelPlayer(playerId, "vehicle") end
AddEventHandler("onPlayerEnteringVehicle", vehicleEntry)
AddEventHandler("onPlayerEnteredVehicle", vehicleEntry)

AddEventHandler("onPlayerWeaponChanged", function(playerId, _slot, _record, drawn)
    if drawn ~= true and drawn ~= "true" then return end
    core:cancelPlayer(playerId, "combat")
end)

AddEventHandler("onPlayerAnimationChanged", function(playerId, stateJson)
    local state = stateJson
    if type(stateJson) == "string" then
        local ok, decoded = pcall(json.decode, stateJson)
        if not ok then return end
        state = decoded
    end
    core:onAnimation(playerId, state)
end)

AddEventHandler("onResourceStop", function(name)
    if name == RESOURCE then core:shutdown() end
end)

-- A restarted dependency lost what it held for us: renew and re-hold now.
AddEventHandler("onResourceStart", function(name)
    if name == "open77_actions" then
        for _, group in pairs(core.groups) do group.renewedAt = -math.huge end
    elseif name == "open77_pedestrians" then
        for _, session in pairs(core.byPlayer) do session.heldAt = -math.huge end
    elseif name == RESOURCE then
        print(("[seating] open77_seating %s ready (generation %s, verification %s, exit %s)"):format(M.VERSION,
            tostring(GENERATION), table.concat((function()
                local list = {}
                for state in pairs(config.verification) do list[#list + 1] = state end
                table.sort(list)
                return list
            end)(), ","), config.exitMode))
    end
end)

-- ---------------------------------------------------------------------------
-- The sweep: watchdog, renewals, version, prompts. One bad record cannot stop
-- the pass that would end the next one.
-- ---------------------------------------------------------------------------
CreateThread(function()
    while true do
        Wait(TICK_MS)
        local ok, err = pcall(core.tick, core)
        if not ok then print("[seating] sweep raised: " .. tostring(err)) end
        refreshRoster()
        ok, err = pcall(core.refreshPrompts, core, rosterList)
        if not ok then print("[seating] prompt pass raised: " .. tostring(err)) end
    end
end)

-- ---------------------------------------------------------------------------
-- Lab console (restricted; the dedicated console is always allowed). Every
-- line starts with "[seating]". docs/world-interaction/b6-seating.md has the
-- two-client script.
-- ---------------------------------------------------------------------------
local function say(fmt, ...) print("[seating] " .. fmt:format(...)) end

local function argument(value)
    if value == nil or value == "-" or value == "" then return nil end
    return value
end

local function npcStatus(bucket, pose)
    local list = P.npcOccupants(bucket, { { x = pose.x, y = pose.y, z = pose.z } }, config.separation)
    if type(list) ~= "table" then return "npc:unlinked" end
    local occupant = list[1]
    if occupant == false or occupant == nil then return nil end
    return ("npc:%s:%s:%s"):format(tostring(occupant.npc), tostring(occupant.state), tostring(occupant.source))
end

local function status(bucket, entry, pose, wide)
    local player = core:takenBy(bucket, entry.id, wide, pose, nil)
    if player then return "player:" .. player.pid end
    local npc = npcStatus(bucket, pose)
    if npc then return npc end
    local holder = sync("open77_actions", "claimHolder", bucket, core:claimKey(entry.version, entry.id))
    if type(holder) == "table" then return "claimed:" .. tostring(holder.owner) end
    return "free"
end

RegisterCommand("seating.status", function()
    local sessions, groups = 0, 0
    for _ in pairs(core.byPlayer) do sessions = sessions + 1 end
    for _ in pairs(core.groups) do groups = groups + 1 end
    local furniture = P.furnitureStatus() or {}
    local states = {}
    for state in pairs(config.verification) do states[#states + 1] = state end
    table.sort(states)
    local postures = {}
    for posture, on in pairs(config.postures) do if on then postures[#postures + 1] = posture end end
    table.sort(postures)
    say("STATUS version=%s indexed=%s sessions=%d groups=%d pedestrians=%s verification=%s postures=%s exit=%s "
            .. "trace=%s promptRadius=%.1f promptLimit=%d sitRange=%.1f separation=%.2f",
        tostring(furniture.version), tostring(furniture.indexed), sessions, groups, core.pedestrians,
        table.concat(states, ","), table.concat(postures, ","), config.exitMode, tostring(core.trace),
        config.promptRadius, config.promptLimit, config.sitRange, config.separation)
end, true)

-- seating.near <playerId> [count=5] [radius=5]: the nearest furniture with a
-- playable pose (any verification) and who holds it.
RegisterCommand("seating.near", function(_, args)
    local pid = M.playerId(args and args[1])
    if pid == nil or not connected(pid) then say("usage: seating.near <playerId> [count] [radius]"); return end
    local read = readPlayer(pid)
    local position = read and M.vector(read.position)
    if position == nil then say("NEAR player=%d position=unknown", pid); return end
    local count = math.max(1, math.min(8, math.tointeger(tonumber(args[2])) or 5))
    local radius = math.max(0.5, math.min(50, tonumber(args[3]) or 5))
    local list, why = P.furnitureNearby(position, radius, { playable = true, limit = count, poses = true })
    if list == nil then say("NEAR refused reason=%s", tostring(why)); return end
    local bucket = read.bucket or 0
    say("NEAR player=%d bucket=%d at=%.2f,%.2f,%.2f radius=%.1f found=%d", pid, bucket, position.x, position.y,
        position.z, radius, #list)
    for rank, entry in ipairs(list) do
        local pose = entry.pose
        local wide = ((math.tointeger(entry.flags or 0) or 0) & M.FLAG_WIDE) ~= 0
        local approach, rule = M.approachPoint(pose.kind, pose)
        say("%d id=%s kind=%s posture=%s d=%.2f spot=%s profile=%s verification=%s arrivalRadius=%.2f poses=%d "
                .. "flags=%d anchor=%.3f,%.3f,%.3f,%.2f approach=%s status=%s",
            rank, entry.id, tostring(entry.kind), tostring(entry.posture), entry.distance or 0, pose.spot,
            tostring(pose.profile), tostring(pose.verification), pose.arrivalRadius or 0.5, entry.poses or 1,
            entry.flags or 0, pose.x, pose.y, pose.z, pose.yaw,
            approach and ("%.3f,%.3f,%.3f"):format(approach.x, approach.y, approach.z) or tostring(rule),
            status(bucket, entry, pose, wide))
    end
end, true)

-- seating.sit <playerId> <furnitureId> [spotId|-] [profile|-] [arrivalRadius|-] [approach|-]
-- Lab: any pose with a profile (or the one given), any verification, reach
-- labReach; occupancy, claims, NPC holds and the approach still apply.
RegisterCommand("seating.sit", function(_, args)
    local pid = M.playerId(args and args[1])
    local id = M.furnitureId(args and args[2])
    if pid == nil or id == nil then
        say("usage: seating.sit <playerId> <furnitureId> [spotId|-] [profile|-] [arrivalRadius|-] "
            .. "[back|front|left|right|player|none|-]")
        return
    end
    local radius = argument(args[5]) and tonumber(args[5]) or nil
    local approach = argument(args[6])
    if approach ~= nil and M.APPROACH_NAMES[approach] == nil then say("unknown approach %s", approach); return end
    local session, why, info = core:sit(pid, id, { lab = true, spot = M.furnitureId(argument(args[3])),
        profile = argument(args[4]), arrivalRadius = radius, approach = approach })
    if session == nil then
        say("SIT player=%d furniture=%s refused reason=%s%s", pid, id, tostring(why),
            type(info) == "table" and (" detail=" .. tostring(info.detail or info.npc or info.state)) or "")
        return
    end
    say("SIT player=%d furniture=%s spot=%s accepted state=%s (watch for SEATED / END lines)", pid, id,
        session.spot, session.state)
end, true)

-- seating.stand <playerId> [approach|check|none]
RegisterCommand("seating.stand", function(_, args)
    local pid = M.playerId(args and args[1])
    if pid == nil then say("usage: seating.stand <playerId> [approach|check|none]"); return end
    local mode = argument(args[2])
    local ok, why = core:stand(pid, "stood", { exit = M.EXIT_MODES[mode] and mode or nil })
    say("STAND player=%d -> %s", pid, ok and "ok" or tostring(why))
end, true)

-- seating.claims: every session, every group claim and its holder.
RegisterCommand("seating.claims", function()
    local any = false
    for pid, session in pairs(core.byPlayer) do
        any = true
        say("SESSION player=%d furniture=%s spot=%s kind=%s state=%s bucket=%d playback=%s profile=%s claim=%s "
                .. "npc=%s version=%s",
            pid, session.furnitureId, session.spot, tostring(session.kind), session.state, session.bucket,
            tostring(session.playbackId), tostring(session.profile), session.group and session.group.key or "-",
            tostring(session.npc), tostring(session.version))
    end
    for _, group in pairs(core.groups) do
        any = true
        local holder = sync("open77_actions", "claimHolder", group.bucket, group.key)
        say("CLAIM bucket=%d key=%s token=%s refs=%d holder=%s remainingMs=%s", group.bucket, group.key,
            tostring(group.token), group.refs, type(holder) == "table" and tostring(holder.owner) or "none",
            type(holder) == "table" and tostring(holder.remainingMs) or "-")
    end
    if not any then say("CLAIMS none") end
end, true)

RegisterCommand("seating.exit", function(_, args)
    local mode = args and args[1]
    if not M.EXIT_MODES[mode] then say("usage: seating.exit <approach|check|none> (now %s)", config.exitMode); return end
    config.exitMode = mode
    say("exit mode=%s", mode)
end, true)

RegisterCommand("seating.verification", function(_, args)
    config.verification = parseVerification(args and args[1] or "measured")
    local states = {}
    for state in pairs(config.verification) do states[#states + 1] = state end
    table.sort(states)
    say("verification=%s (prompts and /sit offer these states)", table.concat(states, ","))
end, true)

RegisterCommand("seating.trace", function(_, args)
    core.trace = (args and args[1]) ~= "off"
    say("trace %s", core.trace and "on" or "off")
end, true)
