-- =============================================================================
-- open77_seating -- server/core.lua
-- =============================================================================
-- The seating lifecycle (row B6 of docs/world-interaction-plan.md), written
-- against injected ports so the offline suite runs it as-is:
--
--   request -> server validation (alive, ready, bucket, fresh position, not
--   in a vehicle or in combat, distance) -> pose choice (best verified pose,
--   a free one on a bench row) -> player/player occupancy -> claim of the
--   furniture GROUP (open77_actions, bucket-scoped) -> pedestrian hold
--   (open77_pedestrians: an NPC on the seat refuses, NPCs keep off it) ->
--   approach point (teleport beside the furniture, never onto it) ->
--   Open77.animations.playAt(profile, anchor, yaw, { arrivalRadius }) ->
--   seated until the actor stands up, dies, leaves, changes bucket, gets in
--   a vehicle, draws a weapon, or the posture ends (anchor_unreached,
--   moved, cancelled by the player) -> every end releases the claim, the
--   hold and the playback once, and a voluntary end puts the body back on
--   its approach point.
--
-- Nothing here holds the player's input or camera: the workspot does while
-- it plays and the platform restores both when the playback ends.
--
-- Global: Open77SeatingCore. Contract: docs/world-interaction/b6-seating.md.
-- =============================================================================

local M = Open77SeatingModel
assert(M ~= nil, "open77_seating: shared/model.lua must load first")

local Core = {}
Core.__index = Core
Open77SeatingCore = Core

local function rank(verification)
    return ({ measured = 1, unverified = 2, refused = 3, none = 4 })[verification] or 5
end

-- Animation end reasons (RpAnimationService) -> the seat's end.
local ANIMATION_END = {
    cancelled = "cancelled_by_player",
    anchor_unreached = "anchor_unreached",
    moved = "moved",
    player_not_alive = "dead",
    player_not_ready = "dead",
    player_unavailable = "disconnected",
    player_in_vehicle = "vehicle",
    bucket_changed = "bucket_changed",
    disconnected = "disconnected",
    resource_stopped = "resource_stopping",
}

function Core.new(P, config)
    return setmetatable({
        P = P,
        config = config or M.config(),
        byPlayer = {},           -- [pid] = session (approaching or seated)
        byPlayback = {},         -- [playbackId] = session
        groups = {},             -- ["bucket|claimKey"] = { bucket, key, token, refs, renewedAt }
        prompts = {},            -- [pid] = { x, y, z, at, signature }
        promptCursor = 0,
        counter = 0,
        version = nil,           -- open77_furniture catalogue version seen last
        versionCheckedAt = -math.huge,
        trace = false,
        pedestrians = "unknown", -- "linked" | "absent" | "unknown"
    }, Core)
end

-- Lifecycle lines (SIT, SEATED, END, EXIT...): printed while tracing (the
-- `open77_seating_trace` convar or `seating.trace on`), which the lab runs
-- with; a production server stays quiet.
function Core:say(fmt, ...)
    if self.trace then self.P.say("[seating] " .. fmt:format(...)) end
end

-- ---------------------------------------------------------------------------
-- Actor validation: everything a client prompt claimed is re-derived here.
-- ---------------------------------------------------------------------------
function Core:readActor(pid)
    if not self.P.connected(pid) then return nil, "player_unavailable" end
    local read = self.P.readPlayer(pid)
    if type(read) ~= "table" then return nil, "player_unavailable" end
    if read.ready == false then return nil, "player_not_ready" end
    if read.alive == false or read.dead == true then return nil, "player_not_alive" end
    if read.inVehicle == true then return nil, "player_in_vehicle" end
    local position = M.vector(read.position)
    if position == nil then return nil, "position_unavailable" end
    if read.ageMs ~= nil and read.ageMs > self.config.maxPositionAgeMs then return nil, "position_stale" end
    local flags = read.flags
    if type(flags) == "table" and flags.combatValid ~= false and (flags.aiming == true or flags.triggerDown == true) then
        return nil, "in_combat"
    end
    local buckets = self.config.buckets
    if buckets ~= nil and not buckets[read.bucket or 0] then return nil, "bucket_not_enabled" end
    return { pid = pid, bucket = read.bucket or 0, position = position, read = read }
end

-- ---------------------------------------------------------------------------
-- Occupancy between players: a seat is taken by a session (approaching or
-- seated) on the same non-wide furniture, or by any session whose pose is
-- within `separation` on the ground (and 1 m in height) of this one --
-- alternative poses of one seat, the other side of a crowded spot, the
-- neighbour on a bench row.
-- ---------------------------------------------------------------------------
function Core:takenBy(bucket, furnitureId, wide, pose, except)
    local separation = self.config.separation
    for pid, session in pairs(self.byPlayer) do
        if pid ~= except and session.bucket == bucket then
            if session.furnitureId == furnitureId and not wide then return session end
            if M.ground(session.pose, pose) <= separation and math.abs(session.pose.z - pose.z) <= 1.0 then
                return session
            end
        end
    end
    return nil
end

-- Whether a pose of the catalogue may be offered: a profile (or a lab
-- override), an allowed verification state and posture.
function Core:poseAllowed(pose, options)
    if options.lab then return (options.profile or pose.profile) ~= nil end
    if pose.profile == nil then return false end
    if not self.config.verification[pose.verification] then return false end
    if not self.config.postures[pose.posture] then return false end
    return true
end

-- The pose to play on `entry` (a furniture with its poseList) for an actor
-- standing at `position`: the best verified free pose within reach, nearest
-- first among equals. nil, reason when none fits.
function Core:choosePose(entry, actor, options)
    local reach = options.lab and self.config.labReach or self.config.sitRange
    local wide = (math.tointeger(entry.flags or 0) or 0) & M.FLAG_WIDE ~= 0
    local candidates = {}
    for _, pose in ipairs(entry.poseList or {}) do
        if (options.spot == nil or pose.spot == options.spot) and self:poseAllowed(pose, options) then
            candidates[#candidates + 1] = pose
        end
    end
    if options.spot ~= nil and #candidates == 0 then
        for _, pose in ipairs(entry.poseList or {}) do
            if pose.spot == options.spot then return nil, "no_playable_pose" end
        end
        return nil, "unknown_spot"
    end
    if #candidates == 0 then return nil, "no_playable_pose" end
    table.sort(candidates, function(a, b)
        local ra, rb = rank(a.verification), rank(b.verification)
        if ra ~= rb then return ra < rb end
        local da, db = M.ground(a, actor.position), M.ground(b, actor.position)
        if da ~= db then return da < db end
        return a.spot < b.spot
    end)
    local why = nil
    for _, pose in ipairs(candidates) do
        local ground = M.ground(pose, actor.position)
        if ground > reach or math.abs(pose.z - actor.position.z) > self.config.sitVertical then
            why = why or "too_far"
        else
            local holder = self:takenBy(actor.bucket, entry.id, wide, pose, actor.pid)
            if holder == nil then return pose, nil, wide end
            why = "seat_taken"
        end
    end
    return nil, why or "no_playable_pose"
end

-- ---------------------------------------------------------------------------
-- Group claims (open77_actions): one claim per furniture group and bucket,
-- shared by every session of this resource on it (a bench row seats several).
-- ---------------------------------------------------------------------------
function Core:claimKey(version, furnitureId)
    return "furniture:" .. tostring(version) .. ":" .. furnitureId
end

function Core:acquireGroup(bucket, key)
    local slot = bucket .. "|" .. key
    local group = self.groups[slot]
    if group then
        group.refs = group.refs + 1
        return group
    end
    local token, why = self.P.claim(bucket, key, self.config.claimTtlMs)
    if token == nil then return nil, why or "claims_unavailable" end
    group = { slot = slot, bucket = bucket, key = key, token = token, refs = 1, renewedAt = self.P.now() }
    self.groups[slot] = group
    return group
end

function Core:releaseGroup(group)
    if group == nil or self.groups[group.slot] ~= group then return end
    group.refs = group.refs - 1
    if group.refs > 0 then return end
    self.groups[group.slot] = nil
    self.P.releaseClaim(group.token)
end

-- ---------------------------------------------------------------------------
-- Pedestrian holds (open77_pedestrians, optional)
-- ---------------------------------------------------------------------------
function Core:hold(session, force)
    local ok, why, info = self.P.npcHold(session.bucket, session.holdKey,
        { x = session.pose.x, y = session.pose.y, z = session.pose.z },
        { radius = self.config.separation, ttlMs = self.config.claimTtlMs, force = force == true })
    if ok then
        self.pedestrians = "linked"
        return true, nil, why     -- `why` is the overlapping pedestrian when forced
    end
    if why == "npc_occupied" then
        self.pedestrians = "linked"
        return nil, "npc_occupied", info
    end
    -- open77_pedestrians is not running (or refused for a reason of its own):
    -- no NPC coordination, nothing to keep off the seat.
    self.pedestrians = "absent"
    return true, "absent"
end

-- ---------------------------------------------------------------------------
-- The request
-- ---------------------------------------------------------------------------
-- sit(pid, furnitureId, options?) -> session | nil, reason, info
-- options: spot (a pose's spot id), profile, arrivalRadius, approach (a name
-- of M.APPROACH_NAMES), exit (an exit mode), lab (bypass the verification and
-- posture filters, reach labReach), origin (who asked, for the log).
function Core:sit(pid, furnitureId, options)
    options = options or {}
    pid = M.playerId(pid)
    if pid == nil then return nil, "invalid_player" end
    local id = M.furnitureId(furnitureId)
    if id == nil then return nil, "invalid_furniture" end
    if self.byPlayer[pid] ~= nil then return nil, "already_seated" end
    local actor, why = self:readActor(pid)
    if actor == nil then return nil, why end
    local busy = self.P.actorBusy(pid)
    if busy ~= nil then return nil, "actor_busy", { detail = busy } end
    local entry, reason = self.P.furnitureGet(id)
    if entry == nil then
        if reason == "unknown_furniture" or reason == "indexing" then return nil, reason end
        return nil, "furniture_unavailable", { detail = reason }
    end
    local pose, wide
    pose, why, wide = self:choosePose(entry, actor, options)
    if pose == nil then return nil, why end
    local profile = options.profile or pose.profile
    local arrivalRadius = options.arrivalRadius or pose.arrivalRadius or 0.5
    local version = entry.version or self.version or "unversioned"
    local group, cwhy = self:acquireGroup(actor.bucket, self:claimKey(version, entry.id))
    if group == nil then return nil, cwhy == "target_claimed" and "target_claimed" or "claims_unavailable" end

    self.counter = self.counter + 1
    local session = {
        sid = "s" .. self.counter, pid = pid, bucket = actor.bucket, furnitureId = entry.id, version = version,
        spot = pose.spot, kind = pose.kind or entry.kind, posture = pose.posture or entry.posture,
        pose = { x = pose.x, y = pose.y, z = pose.z, yaw = pose.yaw }, profile = profile,
        arrivalRadius = arrivalRadius, verification = pose.verification, wide = wide, group = group,
        holdKey = "furniture:" .. version .. ":" .. pose.spot, origin = actor.position,
        state = "approaching", startedAt = self.P.now(), exitMode = options.exit or self.config.exitMode,
        lab = options.lab == true,
    }
    local held, hwhy, occupant = self:hold(session, false)
    if not held then
        self:releaseGroup(group)
        return nil, hwhy, occupant
    end
    session.npc = hwhy == "absent" and "absent" or "held"
    session.approach, session.approachRule = M.approachPoint(session.kind, session.pose, options.approach)
    self.byPlayer[pid] = session
    self:say("SIT player=%d furniture=%s spot=%s kind=%s profile=%s verification=%s arrivalRadius=%.2f bucket=%d "
            .. "approach=%s npc=%s claim=%s%s",
        pid, entry.id, pose.spot, tostring(session.kind), tostring(profile), tostring(pose.verification),
        arrivalRadius, actor.bucket, session.approach and ("%.3f,%.3f,%.3f"):format(session.approach.x,
            session.approach.y, session.approach.z) or tostring(session.approachRule), session.npc, group.key,
        session.lab and " lab=true" or "")
    self.P.spawn(function() self:present(session) end)
    return session
end

-- Approach, then the posture. Runs on its own thread: the teleport awaits the
-- client's settle report. Every resumption checks the session is still the
-- player's and not ended (a death or a stand-up may have landed meanwhile).
function Core:present(session)
    local P, config = self.P, self.config
    local function current() return not session.ended and self.byPlayer[session.pid] == session end
    if session.approach ~= nil then
        local read = P.readPlayer(session.pid)
        local at = read and M.vector(read.position)
        if at == nil or M.distance(at, session.approach) > config.approachSkipM then
            local landed, why = P.teleport(session.pid, session.approach, { fade = false, heading = session.pose.yaw })
            if not current() then return end
            if landed == nil then
                self:finish(session, "approach_failed", { detail = why })
                return
            end
            local spot = M.vector(landed)
            if spot == nil or M.ground(spot, session.approach) > config.approachToleranceM or
                math.abs(spot.z - session.approach.z) > 1.0 then
                session.landed = spot
                self:finish(session, "approach_blocked", { detail = spot and ("%.3f,%.3f,%.3f"):format(spot.x, spot.y,
                    spot.z) or "unknown" })
                return
            end
        end
    end
    -- The actor may have died, left, changed bucket or drawn a weapon while the
    -- body moved. (No freshness test here: the settle report just answered.)
    local lost = self:stillAble(session)
    if not current() then return end
    if lost ~= nil then
        self:finish(session, lost)
        return
    end
    local state, refused = P.playAt(session.pid, session.profile,
        { x = session.pose.x, y = session.pose.y, z = session.pose.z }, session.pose.yaw,
        { loop = true, arrivalRadius = session.arrivalRadius })
    if not current() then
        if state and state.playbackId then P.stopAt(state.playbackId) end
        return
    end
    if type(state) ~= "table" or state.playbackId == nil then
        self:finish(session, refused == "animation_owned" and "actor_busy" or "animation_refused",
            { detail = refused })
        return
    end
    session.playbackId = state.playbackId
    session.state = "seated"
    session.seatedAt = P.now()
    self.byPlayback[state.playbackId] = session
    P.toClient(session.pid, "open77:seating:state", {
        seated = true, furnitureId = session.furnitureId, label = M.label(session.kind, session.posture),
        posture = session.posture,
    })
    P.hostEvent("open77_seating:seated", {
        playerId = session.pid, furnitureId = session.furnitureId, spot = session.spot, kind = session.kind,
        posture = session.posture, profile = session.profile, bucket = session.bucket, playbackId = session.playbackId,
    })
    self:say("SEATED player=%d furniture=%s spot=%s playback=%s anchor=%.3f,%.3f,%.3f,%.2f arrivalRadius=%.2f",
        session.pid, session.furnitureId, session.spot, tostring(session.playbackId), session.pose.x, session.pose.y,
        session.pose.z, session.pose.yaw, session.arrivalRadius)
end

-- Why an actor between the request and the posture can no longer sit, or nil.
function Core:stillAble(session)
    local read = self.P.readPlayer(session.pid)
    if type(read) ~= "table" then return "disconnected" end
    if read.alive == false or read.dead == true or read.ready == false then return "dead" end
    if read.inVehicle == true then return "vehicle" end
    if (read.bucket or 0) ~= session.bucket then return "bucket_changed" end
    local flags = read.flags
    if type(flags) == "table" and flags.combatValid ~= false and (flags.aiming == true or flags.triggerDown == true) then
        return "combat"
    end
    return nil
end

-- ---------------------------------------------------------------------------
-- Ends
-- ---------------------------------------------------------------------------
-- The one terminal path. `options.animationEnded` = the platform already
-- ended the playback (nothing to stop); `options.exit` overrides the mode.
function Core:finish(session, reason, options)
    if session == nil or session.ended then return false end
    options = options or {}
    session.ended, session.reason, session.endedAt = true, reason, self.P.now()
    local previous = session.state
    session.state = "ended"
    if self.byPlayer[session.pid] == session then self.byPlayer[session.pid] = nil end
    if session.playbackId ~= nil then
        self.byPlayback[session.playbackId] = nil
        if not options.animationEnded then self.P.stopAt(session.playbackId) end
    end
    self:releaseGroup(session.group)
    if session.npc == "held" then self.P.npcRelease(session.bucket, session.holdKey) end
    self.P.toClient(session.pid, "open77:seating:state", { seated = false, reason = reason,
        furnitureId = session.furnitureId })
    if previous == "approaching" then
        -- The request was accepted but never seated: say why.
        self.P.toClient(session.pid, "open77:seating:refused", { reason = reason })
    end
    self.P.hostEvent("open77_seating:stood", { playerId = session.pid, furnitureId = session.furnitureId,
        spot = session.spot, reason = reason, bucket = session.bucket })
    self:say("END player=%d furniture=%s spot=%s state=%s reason=%s%s", session.pid, session.furnitureId,
        session.spot, previous, reason, options.detail and (" detail=" .. tostring(options.detail)) or "")
    local mode = options.exit or session.exitMode
    if M.EXIT_REASONS[reason] and mode ~= "none" then
        self.P.spawn(function() self:exit(session, mode) end)
    end
    return true
end

-- After a voluntary end: wait for the exit to settle, then put the body on a
-- known clear point when it is not already there. The approach point is the
-- one the body stood on before sitting (it landed there); when the approach
-- itself was blocked, the point it came from.
function Core:exit(session, mode)
    local P, config = self.P, self.config
    P.sleep(config.exitSettleMs)
    if self.byPlayer[session.pid] ~= nil then return end      -- seated again meanwhile
    local read = P.readPlayer(session.pid)
    if type(read) ~= "table" or read.alive == false or read.dead == true or read.inVehicle == true or
        (read.bucket or 0) ~= session.bucket then
        return
    end
    local body = M.vector(read.position)
    local target = session.reason == "approach_blocked" and session.origin or session.approach or session.origin
    if body == nil or target == nil then return end
    local away = M.ground(body, target)
    local fromAnchor = M.ground(body, session.pose)
    local move
    if fromAnchor > config.exitLeftM then
        move = false                       -- moved away on purpose (teleport, vehicle): never pulled back
    elseif mode == "approach" then
        move = away > config.exitToleranceM or math.abs(body.z - target.z) > 1.0
    else
        -- "check": only an exit that looks unsafe -- below the seat's floor
        -- (fell through), well above it (on top of the furniture) or flung.
        move = body.z < session.pose.z - 1.0 or body.z > session.pose.z + 1.6 or M.ground(body, session.pose) > 2.5
    end
    self:say("EXIT player=%d furniture=%s mode=%s body=%.3f,%.3f,%.3f fromAnchor=%.3f fromTarget=%.3f move=%s",
        session.pid, session.furnitureId, mode, body.x, body.y, body.z, M.ground(body, session.pose), away,
        tostring(move))
    if move then
        local landed, why = P.teleport(session.pid, target, { fade = false, heading = session.pose.yaw })
        self:say("EXIT player=%d moved=%s reason=%s", session.pid, tostring(landed ~= nil), tostring(why))
    end
end

function Core:stand(pid, reason, options)
    pid = M.playerId(pid)
    local session = pid and self.byPlayer[pid] or nil
    if session == nil then return nil, "not_seated" end
    self:finish(session, reason or "stood", options)
    return true
end

function Core:cancelPlayer(pid, reason)
    pid = M.playerId(pid)
    local session = pid and self.byPlayer[pid] or nil
    if session ~= nil then self:finish(session, reason) end
end

function Core:onAnimation(pid, state)
    if type(state) ~= "table" or state.playbackId == nil or state.active ~= false then return end
    local session = self.byPlayback[state.playbackId]
    if session == nil or session.pid ~= M.playerId(pid) then return end
    local reason = tostring(state.reason or "")
    self:finish(session, ANIMATION_END[reason] or "animation_interrupted",
        { animationEnded = true, detail = reason })
end

function Core:shutdown()
    local list = {}
    for _, session in pairs(self.byPlayer) do list[#list + 1] = session end
    for _, session in ipairs(list) do self:finish(session, "resource_stopping", { exit = "none" }) end
end

-- ---------------------------------------------------------------------------
-- The sweep: watchdog, claim renewal, pedestrian holds, catalogue version.
-- ---------------------------------------------------------------------------
function Core:watchdog(session, now)
    local read = self.P.readPlayer(session.pid)
    if read == nil then
        if not self.P.connected(session.pid) then return "disconnected" end
        return nil
    end
    if read.alive == false or read.dead == true then return "dead" end
    if read.inVehicle == true then return "vehicle" end
    if read.bucket ~= nil and read.bucket ~= session.bucket then return "bucket_changed" end
    if session.state == "approaching" and now - session.startedAt > self.config.approachTimeoutMs then
        return "approach_timeout"
    end
    return nil
end

function Core:renewGroups(now)
    local lost = {}
    for slot, group in pairs(self.groups) do
        if now - group.renewedAt >= self.config.renewEveryMs then
            local ok = self.P.renewClaim(group.token, self.config.claimTtlMs)
            if not ok then
                -- open77_actions restarted (its claims are gone) or the claim
                -- lapsed: claim again; somebody else holding it now loses us
                -- the seat.
                local token = self.P.claim(group.bucket, group.key, self.config.claimTtlMs)
                if token then group.token = token else lost[#lost + 1] = slot end
            end
            group.renewedAt = now
        end
    end
    for _, slot in ipairs(lost) do
        local group = self.groups[slot]
        local victims = {}
        for _, session in pairs(self.byPlayer) do
            if session.group == group then victims[#victims + 1] = session end
        end
        self.groups[slot] = nil
        group.refs = 0
        for _, session in ipairs(victims) do
            session.group = nil
            self:finish(session, "claim_lost")
        end
    end
end

-- A new catalogue (open77_furniture restarted with regenerated data): keys
-- carry the version, so seated sessions move to the new key when their pose
-- is still there, and stand up otherwise.
function Core:checkVersion(now)
    if now - self.versionCheckedAt < self.config.versionCheckMs then return end
    self.versionCheckedAt = now
    local status = self.P.furnitureStatus()
    if type(status) ~= "table" or not status.indexed or status.version == nil then return end
    if self.version == nil then self.version = status.version; return end
    if status.version == self.version then return end
    self.version = status.version
    local list = {}
    for _, session in pairs(self.byPlayer) do
        if session.version ~= status.version then list[#list + 1] = session end
    end
    for _, session in ipairs(list) do self:rekey(session, status.version) end
end

function Core:rekey(session, version)
    local entry = self.P.furnitureGet(session.spot)
    local same = nil
    for _, pose in ipairs(entry and entry.poseList or {}) do
        if pose.spot == session.spot and M.distance(pose, session.pose) <= 0.05 then same = pose end
    end
    if same == nil then
        self:finish(session, "furniture_changed")
        return
    end
    local group = self:acquireGroup(session.bucket, self:claimKey(version, entry.id))
    if group == nil then
        self:finish(session, "furniture_changed")
        return
    end
    self:releaseGroup(session.group)
    if session.npc == "held" then self.P.npcRelease(session.bucket, session.holdKey) end
    session.group, session.version, session.furnitureId = group, version, entry.id
    session.holdKey = "furniture:" .. version .. ":" .. session.spot
    if session.npc == "held" then self:hold(session, true) end
    self:say("REKEY player=%d furniture=%s version=%s", session.pid, entry.id, version)
end

function Core:tick()
    local now = self.P.now()
    local list = {}
    for _, session in pairs(self.byPlayer) do list[#list + 1] = session end
    for _, session in ipairs(list) do
        local bad = self:watchdog(session, now)
        if bad ~= nil then self:finish(session, bad) end
    end
    self:renewGroups(now)
    -- Pedestrian holds are refreshed with `force`: the player already sits
    -- there, and open77_pedestrians may have restarted (its holds gone).
    for _, session in pairs(self.byPlayer) do
        if session.npc ~= nil and now - (session.heldAt or session.startedAt) >= self.config.renewEveryMs then
            session.heldAt = now
            local ok, why, overlap = self:hold(session, true)
            session.npc = (ok and why ~= "absent") and "held" or "absent"
            if overlap ~= nil and type(overlap) == "table" then
                self:say("NPC_OVERLAP player=%d furniture=%s npc=%s state=%s", session.pid, session.furnitureId,
                    tostring(overlap.npc), tostring(overlap.state))
            end
        end
    end
    self:checkVersion(now)
end

-- ---------------------------------------------------------------------------
-- Prompts: a bounded nearest set per player, never every row around.
-- ---------------------------------------------------------------------------
function Core:filter()
    local verification, postures = {}, {}
    for state, on in pairs(self.config.verification) do if on then verification[#verification + 1] = state end end
    for posture, on in pairs(self.config.postures) do if on then postures[#postures + 1] = posture end end
    table.sort(verification); table.sort(postures)
    return { playable = true, verification = verification, posture = postures, vertical = self.config.promptVertical,
        excludeFlags = self.config.excludeFlags, limit = self.config.promptLimit + 2 }
end

-- The seats to offer `actor` now: nearest first, at most promptLimit, none
-- taken by a player (unless a bench row may still have room) or an NPC.
function Core:seatsFor(actor)
    local config = self.config
    local list = self.P.furnitureNearby(actor.position, config.promptRadius, self:filter())
    if type(list) ~= "table" then return {} end
    local candidates, points = {}, {}
    for _, entry in ipairs(list) do
        local pose = entry.pose or entry
        local wide = ((math.tointeger(entry.flags or 0) or 0) & M.FLAG_WIDE) ~= 0 and (entry.poses or 1) > 1
        if wide or self:takenBy(actor.bucket, entry.id, false, pose, actor.pid) == nil then
            candidates[#candidates + 1] = { entry = entry, pose = pose, wide = wide }
            points[#points + 1] = { x = pose.x, y = pose.y, z = pose.z }
        end
    end
    local occupants = (#points > 0) and self.P.npcOccupants(actor.bucket, points, config.separation) or nil
    local seats = {}
    for i, candidate in ipairs(candidates) do
        local npc = type(occupants) == "table" and occupants[i] or false
        if (npc == false or npc == nil or candidate.wide) and #seats < config.promptLimit then
            local entry, pose = candidate.entry, candidate.pose
            local lift = (pose.posture or entry.posture) == "lean" and 1.0 or 0.6
            seats[#seats + 1] = {
                id = entry.id, kind = pose.kind or entry.kind, posture = pose.posture or entry.posture,
                label = M.label(pose.kind or entry.kind, pose.posture or entry.posture),
                position = { x = pose.x, y = pose.y, z = pose.z + lift },
            }
        end
    end
    return seats
end

local function signature(seats)
    local parts = {}
    for _, seat in ipairs(seats) do parts[#parts + 1] = seat.id end
    return table.concat(parts, ",")
end

-- One pass over at most promptPlayersPerTick players (round robin): a player
-- is re-queried after moving promptMoveM or every promptRefreshMs, and told
-- only when the set changed.
function Core:refreshPrompts(players)
    local config, now = self.config, self.P.now()
    local count = #players
    if count == 0 then return end
    local budget = math.min(count, config.promptPlayersPerTick)
    for _ = 1, budget do
        self.promptCursor = self.promptCursor % count + 1
        local pid = players[self.promptCursor]
        local state = self.prompts[pid]
        if self.byPlayer[pid] ~= nil then
            if state == nil or state.signature ~= "" then
                self.prompts[pid] = { x = 0, y = 0, z = 0, at = now, signature = "" }
                self.P.toClient(pid, "open77:seating:seats", { seats = {} })
            end
        else
            local actor = self:readActor(pid)
            if actor ~= nil then
                local p = actor.position
                if state == nil or now - state.at >= config.promptRefreshMs or
                    M.distance(p, state) >= config.promptMoveM then
                    local seats = self:seatsFor(actor)
                    local sig = signature(seats)
                    local changed = state == nil or state.signature ~= sig
                    self.prompts[pid] = { x = p.x, y = p.y, z = p.z, at = now, signature = sig }
                    if changed then self.P.toClient(pid, "open77:seating:seats", { seats = seats }) end
                end
            elseif state ~= nil and state.signature ~= "" then
                -- Dead, in a vehicle, in combat...: no seat on offer.
                self.prompts[pid] = { x = 0, y = 0, z = 0, at = now, signature = "" }
                self.P.toClient(pid, "open77:seating:seats", { seats = {} })
            end
        end
    end
end

function Core:forgetPlayer(pid)
    self.prompts[pid] = nil
end

-- ---------------------------------------------------------------------------
-- /sit: the nearest free seat within reach.
-- ---------------------------------------------------------------------------
function Core:sitNearest(pid, options)
    options = options or {}
    pid = M.playerId(pid)
    if pid == nil then return nil, "invalid_player" end
    if self.byPlayer[pid] ~= nil then return nil, "already_seated" end
    local actor, why = self:readActor(pid)
    if actor == nil then return nil, why end
    local filter = self:filter()
    filter.limit = 8
    local list, lwhy = self.P.furnitureNearby(actor.position, self.config.sitRange + 0.5, filter)
    if type(list) ~= "table" then
        if lwhy == "indexing" then return nil, "indexing" end
        return nil, "furniture_unavailable", { detail = lwhy }
    end
    local last = "no_playable_pose"
    for _, entry in ipairs(list) do
        local session, reason, info = self:sit(pid, entry.id, options)
        if session then return session end
        -- Only the seat is the problem: try the next one.
        if reason ~= "seat_taken" and reason ~= "npc_occupied" and reason ~= "target_claimed" and
            reason ~= "too_far" and reason ~= "no_playable_pose" then
            return nil, reason, info
        end
        last = reason
    end
    return nil, last
end

-- A summary of a session (exports, lab).
function Core:public(session)
    if session == nil then return nil end
    return {
        playerId = session.pid, furnitureId = session.furnitureId, spot = session.spot, kind = session.kind,
        posture = session.posture, profile = session.profile, state = session.state, bucket = session.bucket,
        playbackId = session.playbackId, arrivalRadius = session.arrivalRadius, verification = session.verification,
        version = session.version, npc = session.npc,
        anchor = { x = session.pose.x, y = session.pose.y, z = session.pose.z, yaw = session.pose.yaw },
        approach = session.approach,
    }
end

return Core
