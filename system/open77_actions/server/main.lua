-- =============================================================================
-- open77_actions -- server/main.lua
-- =============================================================================
-- Runtime wiring of the thin action library (row B5) and the carry helper
-- (row A5): the ports the engine runs on, the exports authors call, the
-- platform events that cancel, the client transport, and the lab commands the
-- integrator drives two-client proofs with.
--
-- Contract: docs/world-interaction/b5-actions.md. Author guide: wiki/actions.md.
-- =============================================================================

local M = Open77ActionsModel
local Engine = Open77ActionsEngine
local Carry = Open77ActionsCarry
assert(M and Engine and Carry, "open77_actions: shared/model.lua, server/claims.lua, server/engine.lua and server/carry.lua must load first")

local RESOURCE = GetCurrentResourceName()
local GENERATION = (GetCurrentResourceGeneration and GetCurrentResourceGeneration()) or Open77.resource.generation()
local SWEEP_MS = 100
local TARGET_CHUNK = 16
local INTENT_WINDOW_MS, INTENT_BUDGET = 1000, 6

local function nowMs() return math.floor(Open77.time.monotonic() * 1000) end

local function log(level, line)
    local fn = Open77.log and Open77.log[level]
    if fn then fn(line) else print(line) end
end

-- ---------------------------------------------------------------------------
-- Roster (a player id is checked before any player native: an id of 0 from the
-- console stops a resource that passes it to `Open77.players.position`)
-- ---------------------------------------------------------------------------
local roster, rosterAt = {}, -math.huge
local function refreshRoster()
    local now = nowMs()
    if now - rosterAt < 250 then return end
    rosterAt = now
    roster = {}
    for _, id in ipairs(GetPlayers() or {}) do
        local n = M.playerId(id)
        if n then roster[n] = true end
    end
end

local function connected(pid)
    pid = M.playerId(pid)
    if pid == nil then return false end
    refreshRoster()
    return roster[pid] == true
end

local function readPlayer(pid)
    if not connected(pid) then return nil end
    local ok, read = pcall(Open77.players.get, pid)
    if not ok or type(read) ~= "table" then return nil end
    return read
end

local function guarded(what, fn, ...)
    local ok, a, b = pcall(fn, ...)
    if not ok then
        log("warn", ("[actions] %s raised: %s"):format(what, tostring(a)))
        return nil, "hook_failed"
    end
    return a, b
end

-- ---------------------------------------------------------------------------
-- Target transport: only targets in the player's bucket, in bounded chunks.
-- The client keeps at most a handful of them live as prompts (nearest first),
-- so the 32-anchor-per-owner quota of open77_interactions is never reached.
-- ---------------------------------------------------------------------------
local function clientTarget(target)
    return {
        key = target.key, position = target.position, bucket = target.bucket,
        label = target.label, description = target.description, distance = target.distance,
        markerDistance = target.markerDistance, marker = target.marker, color = target.color,
        icon = target.icon, requires = target.requires, choices = target.actions,
        promptHeight = target.promptHeight, lookAt = target.lookAt, promptAt = target.promptAt,
        hideFor = target.hideFor,
    }
end

local function sendTargets(pid, reset, upserts, removes)
    upserts, removes = upserts or {}, removes or {}
    local index = 1
    repeat
        local chunk = {}
        for i = index, math.min(index + TARGET_CHUNK - 1, #upserts) do chunk[#chunk + 1] = clientTarget(upserts[i]) end
        TriggerClientEvent("open77:actions:targets", pid, {
            generation = GENERATION, reset = reset and index == 1 or false,
            upsert = chunk, remove = index == 1 and removes or {},
        })
        index = index + TARGET_CHUNK
    until index > #upserts
end

local engine

local function pushTargets(bucket, upserts, removes)
    local ok, ids = pcall(GetPlayersInBucket, bucket)
    if not ok or type(ids) ~= "table" then return end
    for _, id in ipairs(ids) do
        local pid = M.playerId(id)
        if pid then sendTargets(pid, false, upserts, removes) end
    end
end

-- ---------------------------------------------------------------------------
-- Ports
-- ---------------------------------------------------------------------------
local watched = {}

local P = {
    resource = RESOURCE,
    generation = GENERATION,
    now = nowMs,
    unix = function()
        local clock = Open77.time and Open77.time.unix
        return clock and math.floor(clock()) or nil
    end,
    random = function(lo, hi) return math.random(lo, hi) end,
    log = log,
    connected = connected,
    readPlayer = readPlayer,
    -- Players other than `except` standing within `radius` (planar) and `height` of `position`.
    playersNear = function(bucket, position, radius, height, except)
        local ok, ids = pcall(GetPlayersInBucket, bucket)
        if not ok or type(ids) ~= "table" then return {} end
        local near = {}
        for _, id in ipairs(ids) do
            local pid = M.playerId(id)
            local read = pid and pid ~= except and readPlayer(pid)
            local p = type(read) == "table" and read.position
            if type(p) == "table" and math.abs((p.z or 0) - position.z) <= height then
                local dx, dy = p.x - position.x, p.y - position.y
                if dx * dx + dy * dy <= radius * radius then near[#near + 1] = pid end
            end
        end
        return near
    end,
    animPlay = function(pid, profile, options)
        return guarded("animations.play", Open77.animations.play, pid, profile, options)
    end,
    animPlayAt = function(pid, profile, position, yaw, options)
        return guarded("animations.playAt", Open77.animations.playAt, pid, profile, position, yaw, options)
    end,
    animSequence = function(pid, steps, options)
        return guarded("animations.sequence", Open77.animations.sequence, pid, steps, options)
    end,
    animStop = function(pid, playbackId, placed)
        if placed then return guarded("animations.stopAt", Open77.animations.stopAt, playbackId) end
        if not connected(pid) then return true end
        return guarded("animations.stop", Open77.animations.stop, pid, playbackId)
    end,
    animProfile = function(profileId)
        local ok, profile = pcall(Open77.animations.get, profileId)
        if ok and type(profile) == "table" then return profile end
        return nil
    end,
    toClient = function(pid, name, payload)
        if not connected(pid) then return false end
        local ok, sent = pcall(TriggerClientEvent, name, pid, payload)
        return ok and sent ~= false
    end,
    hostEvent = function(name, payload) pcall(TriggerEvent, name, payload) end,
    hookSync = function(owner, name, ctx)
        local ok, a, b = pcall(Open77.exports.callSync, owner, name, ctx)
        if not ok then
            log("warn", ("[actions] hook %s:%s raised: %s"):format(owner, name, tostring(a)))
            return nil, "hook_failed"
        end
        return a, b
    end,
    hookAsync = function(owner, name, ctx)
        local promise, why = Open77.exports.call(owner, name, ctx)
        if not promise then return nil, why end
        return promise:await()
    end,
    callSync = function(resource, name, ...)
        return pcall(Open77.exports.callSync, resource, name, ...)
    end,
    -- open77_pedestrians (optional): keep the crowd off a target point. A missing resource is fine.
    crowdHold = function(bucket, key, position, radius)
        local ok, held = pcall(Open77.exports.callSync, "open77_pedestrians", "holdSeat", bucket, key, position,
            { radius = radius, ttlMs = 45000, force = true })
        return ok and held == true
    end,
    crowdRelease = function(bucket, key)
        pcall(Open77.exports.callSync, "open77_pedestrians", "releaseSeat", bucket, key)
    end,
    ownerGeneration = function(owner)
        local ok, generation = pcall(Open77.resource.generation, owner)
        return ok and generation or 0
    end,
    spawn = function(fn) CreateThread(fn) end,
    sleep = function(ms) Wait(math.floor(ms)) end,
    vehicle = function(id)
        local ok, v = pcall(Open77.vehicles.get, id)
        if not ok or type(v) ~= "table" then return nil end
        local position = M.vector(v.position) or M.vector(v)
        return { position = position, bucket = v.bucket }
    end,
    props = {
        create = function(def) return guarded("props.create", Open77.props.create, def) end,
        attach = function(id, binding) return guarded("props.attach", Open77.props.attach, id, binding) end,
        detach = function(id) return guarded("props.detach", Open77.props.detach, id) end,
        setTransform = function(id, def) return guarded("props.setTransform", Open77.props.setTransform, id, def) end,
        remove = function(id) return guarded("props.remove", Open77.props.remove, id) end,
    },
    pushTargets = function(bucket, upserts, removes) pushTargets(bucket, upserts, removes) end,
    watchEvent = function(name)
        if watched[name] then return end
        watched[name] = true
        AddEventHandler(name, function(playerId, epoch)
            engine:onEpochEvent(name, playerId, epoch)
        end)
    end,
}

engine = Engine.new(P)
local carry = Carry.attach(engine)
engine.trace = GetConvar and (GetConvar("open77_actions_trace", "0") == "1") or false

-- Inspection handle for the offline suites (tests/*.lua). A global of this VM
-- only: no other resource can reach it.
Open77ActionsRuntime = { engine = engine, carry = carry }

-- ---------------------------------------------------------------------------
-- Caller identity for exports
-- ---------------------------------------------------------------------------
local function caller()
    local owner = GetInvokingResource()
    if not M.validName(owner, 64) then return nil end
    return owner, GetInvokingResourceGeneration()
end

local function result(op, reason, info)
    if op == nil then return nil, reason, info end
    return engine:publicOp(op)
end

-- ---------------------------------------------------------------------------
-- Exports: definitions and targets (synchronous)
-- ---------------------------------------------------------------------------
exports("define", function(def)
    local owner, generation = caller()
    if not owner then return nil, "owner_unavailable" end
    return engine:define(owner, generation, def, false)
end)

exports("undefine", function(id)
    local owner = caller()
    if not owner then return nil, "owner_unavailable" end
    return engine:undefine(owner, id)
end)

exports("target", function(def)
    local owner, generation = caller()
    if not owner then return nil, "owner_unavailable" end
    return engine:addTarget(owner, generation, def)
end)

exports("untarget", function(id)
    local owner = caller()
    if not owner then return nil, "owner_unavailable" end
    local removed = engine:removeTargets(owner, id)
    if removed == 0 then return nil, "unknown_target" end
    return removed
end)

-- ---------------------------------------------------------------------------
-- Exports: the lifecycle
-- ---------------------------------------------------------------------------
-- request: synchronous. Validates, claims and starts; the outcome arrives as
-- `open77_actions:transition` events. Safe from the sugar `exports.x:request`.
exports("request", function(playerId, actionRef, targetRef, options)
    local owner = caller()
    if not owner then return nil, "owner_unavailable" end
    return result(engine:request(owner, playerId, actionRef, targetRef, options))
end)

-- begin: asynchronous (call with Open77.exports.call). Also waits for an
-- async reserve hook, so the typed result already says presenting or why not.
exports("begin", function(playerId, actionRef, targetRef, options)
    local owner = caller()
    if not owner then return nil, "owner_unavailable" end
    local op, reason, info = engine:request(owner, playerId, actionRef, targetRef, options)
    if op == nil then return nil, reason, info end
    while op.state == "reserving" do Wait(25) end
    if M.TERMINAL[op.state] and op.state ~= "committed" then
        return nil, op.reason, { stage = op.stage, opId = op.opId, state = op.state }
    end
    return engine:publicOp(op)
end)

exports("cancel", function(opId, reason)
    local owner = caller()
    if not owner then return nil, "owner_unavailable" end
    local op = engine.ops[opId]
    if op == nil then return nil, "unknown_operation" end
    if op.owner ~= owner and owner ~= RESOURCE then return nil, "not_owner" end
    return engine:cancel(op, M.token(reason, "cancelled"), "cancel")
end)

exports("status", function(opId)
    local op = engine.ops[opId]
    if op == nil then return nil, "unknown_operation" end
    return engine:publicOp(op)
end)

-- verify: what a hook should call first. An export is callable by any
-- resource, so a commit hook asks the library whether this opId is really
-- one of the caller's, in the state the hook is meant to run in.
exports("verify", function(opId, phase)
    local owner = caller()
    local op = engine.ops[opId]
    if op == nil then return false, "unknown_operation" end
    if op.owner ~= owner then return false, "not_owner" end
    local expected = ({ commit = "committing", reserve = "reserving" })[phase]
    if expected ~= nil and op.state ~= expected then return false, "already_terminal" end
    return true
end)

exports("current", function(playerId)
    local pid = M.playerId(playerId)
    if pid == nil then return nil, "invalid_player" end
    local op = engine.active[pid]
    if op == nil then return nil end
    return engine:publicOp(op)
end)

-- ---------------------------------------------------------------------------
-- Exports: claims for shared targets owned by other resources (B6 seats...)
-- ---------------------------------------------------------------------------
exports("claim", function(bucket, key, ttlMs)
    local owner, generation = caller()
    if not owner then return nil, "owner_unavailable" end
    if not M.validName(key, 160) then return nil, "invalid_target" end
    local ttl = M.integer(ttlMs, 1000, 3600000, 30000)
    if ttl == nil then return nil, "invalid_options" end
    -- A resource that only claims is an owner too: its claims go when it stops or reloads (ownerGone),
    -- not only when they lapse.
    engine:noteOwner(owner, generation)
    local token, why, holder = engine.claims:acquire(bucket, key, "res:" .. owner, ttl, owner)
    if token == nil then
        return nil, why, holder and { holder = holder.holder, owner = holder.owner,
            remainingMs = holder.expiresAt - nowMs() } or nil
    end
    return token
end)

exports("renewClaim", function(token, ttlMs)
    local owner = caller()
    local entry = engine.claims:get(token)
    if entry == nil then return nil, "claim_lost" end
    if entry.owner ~= owner then return nil, "not_owner" end
    return engine.claims:renew(token, M.integer(ttlMs, 1000, 3600000, 30000) or 30000)
end)

exports("releaseClaim", function(token)
    local owner = caller()
    local entry = engine.claims:get(token)
    if entry == nil then return nil, "claim_lost" end
    if entry.owner ~= owner then return nil, "not_owner" end
    return engine.claims:release(token)
end)

exports("claimHolder", function(bucket, key)
    local entry = engine.claims:holder(math.tointeger(tonumber(bucket)) or 0, tostring(key))
    if entry == nil then return nil end
    return { holder = entry.holder, owner = entry.owner, remainingMs = entry.expiresAt - nowMs() }
end)

-- ---------------------------------------------------------------------------
-- Exports: the carry helper (A5)
-- ---------------------------------------------------------------------------
exports("carryDefine", function(def)
    local owner, generation = caller()
    if not owner then return nil, "owner_unavailable" end
    return carry:defineKind(owner, generation, def, false)
end)

exports("carryPlace", function(kindRef, placement)
    local owner, generation = caller()
    if not owner then return nil, "owner_unavailable" end
    return carry:place(owner, generation, kindRef, placement)
end)

exports("carryRemove", function(itemId)
    local owner = caller()
    if not owner then return nil, "owner_unavailable" end
    return carry:remove(owner, itemId)
end)

exports("carryGet", function(itemId)
    return carry:publicItem(carry.items[itemId])
end)

exports("carrying", function(playerId)
    local pid = M.playerId(playerId)
    if pid == nil then return nil, "invalid_player" end
    local session = carry.sessions[pid]
    if session == nil then return nil end
    return carry:publicItem(carry.items[session.itemId])
end)

exports("carryPickup", function(playerId, itemId, options)
    local owner = caller()
    if not owner then return nil, "owner_unavailable" end
    local pid = M.playerId(playerId)
    if pid == nil then return nil, "invalid_player" end
    options = type(options) == "table" and options or {}
    options.itemId = itemId
    return result(carry:pickup(owner, pid, nil, options))
end)

exports("carryPutdown", function(playerId, destination, options)
    local owner = caller()
    if not owner then return nil, "owner_unavailable" end
    local pid = M.playerId(playerId)
    if pid == nil then return nil, "invalid_player" end
    return result(carry:putdown(owner, pid, destination, options))
end)

exports("carryDrop", function(playerId, reason)
    local owner = caller()
    local pid = M.playerId(playerId)
    if pid == nil then return nil, "invalid_player" end
    local session = carry.sessions[pid]
    if session == nil then return nil, "not_carrying" end
    local item = carry.items[session.itemId]
    if item and item.owner ~= owner then return nil, "not_owner" end
    return carry:drop(pid, M.token(reason, "cancelled"))
end)

-- ---------------------------------------------------------------------------
-- Client transport
-- ---------------------------------------------------------------------------
local intents = {}

local function allowIntent(pid)
    local now = nowMs()
    local bucket = intents[pid]
    if bucket == nil or now - bucket.since > INTENT_WINDOW_MS then
        intents[pid] = { since = now, count = 1 }
        return true
    end
    bucket.count = bucket.count + 1
    return bucket.count <= INTENT_BUDGET
end

local function reportRefusal(pid, actionKey, reason, info)
    P.toClient(pid, "open77:actions:refused", { generation = GENERATION, action = actionKey, reason = reason,
        stage = info and info.stage or nil, message = M.messageFor(engine.actions[actionKey], reason) })
    if engine.trace then
        log("info", ("[actions] op=%s state=refused reason=%s stage=%s action=%s player=%d"):format(
            info and info.opId or "-", tostring(reason), tostring(info and info.stage or "-"),
            tostring(actionKey), pid))
    end
end

-- The minimum intent: which action, on which target. Everything else is
-- re-derived on the server.
RegisterNetEvent("open77:actions:intent", function(actionKey, targetKey)
    local pid = M.playerId(source)
    if pid == nil or not allowIntent(pid) then return end
    if not M.validName(actionKey, 112) or (targetKey ~= nil and not M.validName(targetKey, 112)) then return end
    local op, reason, info = engine:request("player", pid, actionKey, targetKey, {})
    if op == nil then reportRefusal(pid, actionKey, reason, info) end
end)

RegisterNetEvent("open77:actions:putdown", function()
    local pid = M.playerId(source)
    if pid == nil or not allowIntent(pid) then return end
    local op, reason, info = carry:putdown("player", pid, nil, {})
    if op == nil then reportRefusal(pid, Carry.PUTDOWN_KEY, reason, info) end
end)

RegisterNetEvent("open77:actions:cancel", function(opId)
    local pid = M.playerId(source)
    if pid == nil or type(opId) ~= "string" then return end
    local ok, reason = engine:clientCancel(pid, opId)
    if not ok and engine.trace then
        log("info", ("[actions] op=%s client cancel ignored: %s (player=%d)"):format(opId, tostring(reason), pid))
    end
end)

local function syncPlayer(pid)
    local read = readPlayer(pid)
    local bucket = read and read.bucket or 0
    sendTargets(pid, true, engine:targetsIn(bucket), nil)
    local op = engine.active[pid]
    if op ~= nil and op.state == "presenting" and op.clientShown then
        P.toClient(pid, "open77:actions:present", {
            opId = op.opId, generation = GENERATION, action = op.actionKey, label = op.action.label,
            durationMs = math.max(250, (op.completeAt or nowMs()) - nowMs()),
            progress = op.action.progress or false, claims = op.action.claims,
        })
    end
    local state = carry:stateFor(pid)
    P.toClient(pid, "open77:actions:carry", {
        generation = GENERATION, itemId = state and state.itemId or false,
        sessionId = state and state.sessionId or nil, label = state and state.label or nil,
        claims = state and state.claims or nil,
    })
end

RegisterNetEvent("open77:actions:sync", function()
    local pid = M.playerId(source)
    if pid == nil then return end
    syncPlayer(pid)
end)

-- ---------------------------------------------------------------------------
-- Platform events: every named cancellation path
-- ---------------------------------------------------------------------------
AddEventHandler("onPlayerDisconnected", function(playerId)
    local pid = M.playerId(playerId)
    if pid == nil then return end
    rosterAt = -math.huge
    roster[pid] = nil
    engine:cancelPlayer(pid, "disconnected")
    intents[pid] = nil
end)

AddEventHandler("onPlayerLifeStateChanged", function(playerId, _revision, phase)
    if phase == "alive" then return end
    local pid = M.playerId(playerId)
    if pid then engine:cancelPlayer(pid, "dead") end
end)

AddEventHandler("onPlayerBucketChange", function(playerId)
    local pid = M.playerId(playerId)
    if pid == nil then return end
    engine:cancelPlayer(pid, "bucket_changed")
    -- The prompts follow the player into the new bucket.
    CreateThread(function()
        Wait(250)
        if connected(pid) then syncPlayer(pid) end
    end)
end)

local function vehicleEntry(playerId)
    local pid = M.playerId(playerId)
    if pid then engine:cancelPlayer(pid, "vehicle", "vehicle") end
end
AddEventHandler("onPlayerEnteringVehicle", vehicleEntry)
AddEventHandler("onPlayerEnteredVehicle", vehicleEntry)

AddEventHandler("onPlayerWeaponChanged", function(playerId, _slot, _record, drawn)
    if drawn ~= true and drawn ~= "true" then return end
    local pid = M.playerId(playerId)
    if pid then engine:cancelPlayer(pid, "combat", "weaponDrawn") end
end)

AddEventHandler("onPlayerAnimationChanged", function(playerId, stateJson)
    local pid = M.playerId(playerId)
    if pid == nil then return end
    local state = stateJson
    if type(stateJson) == "string" then
        local ok, decoded = pcall(json.decode, stateJson)
        if not ok then return end
        state = decoded
    end
    engine:onAnimation(pid, state)
end)

AddEventHandler("onResourceStop", function(name)
    if name == RESOURCE then
        engine:shutdown()
        return
    end
    if engine.owners[name] ~= nil then engine:ownerGone(name) end
end)

-- ---------------------------------------------------------------------------
-- The sweep: completion, markers, watchdog, claim expiry, owner reloads.
-- Wrapped so one bad record cannot stop the pass that would end the next one.
-- ---------------------------------------------------------------------------
CreateThread(function()
    while true do
        Wait(SWEEP_MS)
        local ok, err = pcall(engine.tick, engine)
        if not ok then log("error", "[actions] sweep raised: " .. tostring(err)) end
    end
end)

-- Crowd holds (targets with keepCrowdOff) are refreshed well inside their 45 s lifetime; a hold
-- lost to a pedestrians restart comes back on the next pass.
CreateThread(function()
    while true do
        Wait(15000)
        local now, due = P.now(), {}
        for key, target in pairs(engine.targets) do
            if target.keepCrowdOff and now - (target.crowdAt or 0) >= 14000 then due[#due + 1] = key end
        end
        for index, key in ipairs(due) do
            local target = engine.targets[key]          -- re-read: it may be gone after a Wait
            if target and target.keepCrowdOff then
                target.crowdHeld = P.crowdHold(target.bucket, "act:" .. key, target.position, target.keepCrowdOff)
                target.crowdAt = now
            end
            if index % 32 == 0 then Wait(0) end
        end
    end
end)

-- ---------------------------------------------------------------------------
-- Operator and lab commands
-- ---------------------------------------------------------------------------
local function say(line) print(line) end

local function describe(op)
    if op == nil then return "none" end
    return engine:line(op)
end

RegisterCommand("actions.status", function(_source, args)
    local pid = M.playerId(args and args[1])
    if pid then
        say("[actions] player=" .. pid .. " op: " .. describe(engine.active[pid]))
        local session = carry.sessions[pid]
        say("[actions] player=" .. pid .. " carrying: " .. (session and session.itemId or "nothing"))
        return
    end
    local ops, live = 0, 0
    for _, op in pairs(engine.ops) do
        ops = ops + 1
        if not M.TERMINAL[op.state] or op.trailing then live = live + 1 end
    end
    local sessions = 0
    for _ in pairs(carry.sessions) do sessions = sessions + 1 end
    say(("[actions] generation=%s actions=%d targets=%d ops=%d live=%d carrying=%d claims=%d trace=%s"):format(
        tostring(GENERATION), (function() local n = 0 for _ in pairs(engine.actions) do n = n + 1 end return n end)(),
        engine.targetCount, ops, live, sessions, engine.claims:count(), tostring(engine.trace)))
end, true)

RegisterCommand("actions.trace", function(_source, args)
    engine.trace = (args and args[1]) ~= "off"
    say("[actions] trace " .. (engine.trace and "on" or "off"))
end, true)

RegisterCommand("actions.claims", function(_source, args)
    local bucket = args and M.integer(args[1], 0, 2147483647, nil) or nil
    local rows = engine.claims:list(bucket)
    if #rows == 0 then say("[actions] claims: none") end
    for _, row in ipairs(rows) do
        say(("[actions] claim token=%s bucket=%d key=%s holder=%s owner=%s remainingMs=%d"):format(
            row.token, row.bucket, row.key, row.holder, tostring(row.owner), row.remainingMs))
    end
end, true)

-- The lab: one action and one carriable crate owned by this resource, with
-- internal hooks whose commit outcome the operator chooses, so the two-client
-- proof can walk every terminal path without an economy. Off until the
-- `open77_actions_lab` convar is 1 or an operator runs `actions.lab.enable`
-- (restricted, like every lab command; the console always may).
local labEnabled = false
local function enableLab()
    if labEnabled then return false end
    labEnabled = true
    engine.trace = true
    local lab = { commit = "ok", nodes = 0 }
    local LAB_ACTION = RESOURCE .. ":lab_work"
    local LAB_CRATE = RESOURCE .. ":lab_crate"

    local function labCommit(ctx)
        local mode = lab.commit
        if mode == "ok" then
            return { lab = true, opId = ctx.opId, placement = ctx.carry and ctx.carry.destination or nil }
        elseif mode == "indoubt" then
            return nil, "in_doubt"
        elseif mode:sub(1, 6) == "delay:" then
            Wait(tonumber(mode:sub(7)) or 1000)
            return { lab = true, opId = ctx.opId, placement = ctx.carry and ctx.carry.destination or nil }
        end
        return nil, M.token(mode:match("^fail:(.+)$"), "refused_by_owner")
    end

    local function defineLabAction(profile, durationMs)
        return engine:define(RESOURCE, GENERATION, {
            id = "lab_work", label = "Lab work", durationMs = durationMs, maxDistance = 3.0,
            animation = { profile = profile, at = "target" },
            markers = { { name = "midpoint", atMs = math.floor(durationMs / 2) } },
            progress = { label = "Lab work" },
            hooks = { commit = labCommit },
        }, true)
    end

    local function actor(args, index)
        local pid = M.playerId(args and args[index])
        if pid == nil then say("[actions] lab: missing player id"); return nil end
        local read = readPlayer(pid)
        if read == nil or type(read.position) ~= "table" then
            say("[actions] lab: player " .. pid .. " has no readable position"); return nil
        end
        if read.alive == false then say("[actions] lab: player " .. pid .. " is not alive (refused)"); return nil end
        return pid, read
    end

    local function report(pid, actionKey, op, reason, info)
        if op == nil then
            say(("[actions] op=%s state=refused reason=%s stage=%s action=%s player=%d"):format(
                info and info.opId or "-", tostring(reason), tostring(info and info.stage or "-"), actionKey, pid))
        else
            say(describe(op))
        end
    end

    RegisterCommand("actions.lab.node", function(_source, args)
        local pid, read = actor(args, 1)
        if not pid then return end
        local profile = M.validName(args[2], 96) and args[2] or "amb_1056d7_kneel_welder"
        local duration = M.integer(args[3], 1000, 600000, 8000) or 8000
        local key, why = defineLabAction(profile, duration)
        if not key then say("[actions] lab: define refused: " .. tostring(why)); return end
        lab.nodes = lab.nodes + 1
        local heading = read.heading or read.yaw or 0
        local at = M.offsetPoint(read.position, heading, 1.2, 0)
        local target, twhy = engine:addTarget(RESOURCE, GENERATION, {
            id = "lab_node_" .. lab.nodes, position = at, yaw = heading, bucket = read.bucket,
            label = "Lab node " .. lab.nodes, actions = { "lab_work" }, distance = 2.5,
        })
        if not target then say("[actions] lab: target refused: " .. tostring(twhy)); return end
        say(("[actions] lab target=%s bucket=%d position=%.2f,%.2f,%.2f yaw=%.1f profile=%s durationMs=%d"):format(
            target, read.bucket, at.x, at.y, at.z, heading, profile, duration))
    end, true)

    RegisterCommand("actions.lab.begin", function(_source, args)
        local pid = actor(args, 1)
        if not pid then return end
        local target = args[2]
        if target and not target:find(":", 1, true) then target = RESOURCE .. ":" .. target end
        local actionKey = args[3] or LAB_ACTION
        local op, reason, info = engine:request("console", pid, actionKey, target, { trace = true, supersede = args[4] == "supersede" })
        report(pid, actionKey, op, reason, info)
    end, true)

    RegisterCommand("actions.lab.commit", function(_source, args)
        local mode = args[1] or "ok"
        if mode == "fail" then mode = "fail:" .. (args[2] or "refused_by_owner")
        elseif mode == "delay" then mode = "delay:" .. (args[2] or "3000") end
        lab.commit = mode
        say("[actions] lab commit mode=" .. mode)
    end, true)

    RegisterCommand("actions.lab.cancel", function(_source, args)
        local ref = args[1]
        local op = engine.ops[ref or ""]
        if op == nil then
            local pid = M.playerId(ref)
            op = pid and engine.active[pid] or nil
        end
        if op == nil then say("[actions] lab: nothing to cancel"); return end
        local ok, why = engine:cancel(op, "cancelled", "cancel")
        say(("[actions] lab cancel op=%s -> %s"):format(op.opId, ok and "ok" or tostring(why)))
    end, true)

    -- actions.lab.crate <pid> [model] [gripMs] [releaseMs]: the markers are the
    -- calibration knobs (hand contact), independent of the clip lengths.
    RegisterCommand("actions.lab.crate", function(_source, args)
        local pid, read = actor(args, 1)
        if not pid then return end
        local model = M.validName(args[2], 128) and args[2] or "crate.small"
        local key, why = carry:defineKind(RESOURCE, GENERATION, {
            id = "lab_crate", model = model, label = "lab crate",
            gripMs = M.integer(args[3], 0, 10000, nil), releaseMs = M.integer(args[4], 0, 10000, nil),
            hooks = { pickup = labCommit, putdown = labCommit },
        }, true)
        if not key then say("[actions] lab: carry kind refused: " .. tostring(why)); return end
        local heading = read.heading or read.yaw or 0
        local at = M.offsetPoint(read.position, heading, 1.0, 0)
        local itemId, iwhy = carry:place(RESOURCE, GENERATION, key, { position = at, yaw = heading, bucket = read.bucket })
        if not itemId then say("[actions] lab: place refused: " .. tostring(iwhy)); return end
        say(("[actions] lab item=%s model=%s bucket=%d position=%.2f,%.2f,%.2f gripMs=%d releaseMs=%d"):format(
            itemId, model, read.bucket, at.x, at.y, at.z, carry.kinds[key].gripMs, carry.kinds[key].releaseMs))
    end, true)

    RegisterCommand("actions.lab.pickup", function(_source, args)
        local pid = actor(args, 1)
        if not pid then return end
        local op, reason, info = carry:pickup("console", pid, nil, { itemId = args[2], trace = true })
        report(pid, Carry.PICKUP_KEY, op, reason, info)
    end, true)

    -- actions.lab.items [pid]: every carry item, its state and where it is, beside the prop's
    -- own transform (what clients draw), and the distance to that player when one is named.
    RegisterCommand("actions.lab.items", function(_source, args)
        local pid = M.playerId(args and args[1])
        local read = pid and P.readPlayer(pid) or nil
        local here = read and type(read.position) == "table" and read.position or nil
        local function fmt(p) return p and ("%.2f,%.2f,%.2f"):format(p.x or 0, p.y or 0, p.z or 0) or "-" end
        local n = 0
        for id, item in pairs(carry.items) do
            n = n + 1
            local at = carry:itemPosition(item)
            local ok, prop = pcall(Open77.props.get, item.propId)
            local pp = ok and type(prop) == "table" and (type(prop.position) == "table" and prop.position or
                (prop.x and { x = prop.x, y = prop.y, z = prop.z })) or nil
            local d = here and at and M.distance(here, at)
            say(("[actions] lab item=%s kind=%s state=%s carrier=%s at=%s prop=%s%s"):format(id, tostring(item.kind.key),
                tostring(item.state), tostring(item.carrier or "-"), fmt(at), fmt(pp), d and (" d=%.2f"):format(d) or ""))
        end
        say(("[actions] lab items=%d%s"):format(n, here and (" player=" .. pid .. " at " .. fmt(here)) or ""))
    end, true)

    -- actions.lab.bind <pid> <tpp|fpp> <x> <y> <z> [rx ry rz]: re-attaches the carried item's prop with
    -- that placement on the Chest slot (the other placement kept), to measure a model's binding in
    -- game; the line it prints is the `binding` to put in the carry kind.
    RegisterCommand("actions.lab.bind", function(_source, args)
        local pid = M.playerId(args and args[1])
        local session = pid and carry.sessions[pid]
        local item = session and carry.items[session.itemId]
        if not item then say("[actions] lab: that player carries nothing"); return end
        local which = args[2]
        local offset = { x = tonumber(args[3]), y = tonumber(args[4]), z = tonumber(args[5]) }
        local rotation = { x = tonumber(args[6]) or 0.0, y = tonumber(args[7]) or 90.0, z = tonumber(args[8]) or 0.0 }
        if (which ~= "tpp" and which ~= "fpp") or not (offset.x and offset.y and offset.z) then
            say("[actions] lab: usage actions.lab.bind <pid> <tpp|fpp> <x> <y> <z> [rx ry rz]")
            return
        end
        lab.bindings = lab.bindings or {}
        local current = lab.bindings[item.id] or carry:binding(item.kind, pid, true)
        current.parentType, current.parentId = "player", pid
        if which == "tpp" then
            current.offset, current.rotation = offset, rotation
        else
            current.firstPerson = { offset = offset, rotation = rotation }
        end
        lab.bindings[item.id] = current
        local ok, why = P.props.attach(item.propId, current)
        local fp = type(current.firstPerson) == "table" and current.firstPerson or nil
        local function v(t) return t and ("{ x = %.3f, y = %.3f, z = %.3f }"):format(t.x, t.y, t.z) or "nil" end
        say(("[actions] lab bind %s -> %s | binding = { bone = %q, offset = %s, rotation = %s, firstPerson = { offset = %s, rotation = %s } }")
            :format(item.id, ok and "ok" or tostring(why), tostring(current.bone), v(current.offset), v(current.rotation),
            v(fp and fp.offset), v(fp and fp.rotation)))
    end, true)

    -- actions.lab.putdown <pid> [ground | point x y z [yaw] | vehicle <vehicleId> [ox oy oz]] [claimKey]
    RegisterCommand("actions.lab.putdown", function(_source, args)
        local pid = actor(args, 1)
        if not pid then return end
        local mode, dest, claimIndex = args[2] or "ground", nil, 3
        if mode == "point" then
            dest = { kind = "point", position = { x = tonumber(args[3]), y = tonumber(args[4]), z = tonumber(args[5]) },
                yaw = tonumber(args[6]) or 0 }
            claimIndex = 7
        elseif mode == "vehicle" then
            dest = { kind = "vehicle", vehicleId = tonumber(args[3]),
                offset = { x = tonumber(args[4]) or 0, y = tonumber(args[5]) or -1.5, z = tonumber(args[6]) or 1.0 } }
            claimIndex = 7
        else
            dest = { kind = "ground" }
        end
        if args[claimIndex] then dest.claimKey = args[claimIndex] end
        local op, reason, info = carry:putdown("console", pid, dest, { trace = true })
        report(pid, Carry.PUTDOWN_KEY, op, reason, info)
    end, true)

    RegisterCommand("actions.lab.drop", function(_source, args)
        local pid = M.playerId(args and args[1])
        if pid == nil then say("[actions] lab: missing player id"); return end
        say("[actions] lab drop player=" .. pid .. " -> " .. tostring(carry:drop(pid, "cancelled")))
    end, true)

    RegisterCommand("actions.lab.clear", function()
        for _, op in pairs(engine.ops) do
            if op.owner == RESOURCE and (not M.TERMINAL[op.state] or op.trailing) then
                engine:cancel(op, "cancelled", "cancel")
            end
        end
        for _, item in pairs(carry.items) do
            if item.owner == RESOURCE then carry:removeItem(item, "removed") end
        end
        local removed = engine:removeTargets(RESOURCE)
        lab.nodes = 0
        say("[actions] lab cleared, targets removed=" .. removed)
    end, true)

    log("warn", "[actions] LAB MODE: lab commands registered, trace on. Never on a production server.")
    return true
end

if GetConvar and GetConvar("open77_actions_lab", "0") == "1" then enableLab() end

RegisterCommand("actions.lab.enable", function()
    say(enableLab() and "[actions] lab mode enabled" or "[actions] lab mode already enabled")
end, true)

AddEventHandler("onResourceStart", function(name)
    if name ~= RESOURCE then return end
    log("info", ("[actions] open77_actions %s ready (generation %s)"):format(M.VERSION, tostring(GENERATION)))
    -- Tell authors to (re)declare: a restart of this resource dropped every
    -- definition, target and carried prop it held.
    TriggerEvent("open77_actions:ready", { generation = GENERATION, version = M.VERSION })
end)
