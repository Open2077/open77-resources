-- =============================================================================
-- open77_scenes -- server/core.lua
-- =============================================================================
-- The scene lifecycle, platform-free: every effect goes through the ports `P`
-- (server/main.lua wires the real ones, tests/fakes.lua stand-ins).
--
--   start   validation (alive, on foot, bucket, reach, spot free, not already
--           in an animation) -> P.sequenceAt(enter, idle[hold]) at the spot's
--           anchor, the player's own body waiting at the scene's stand point
--   idle    the next idle, on the same anchor (the device is reused)
--   stand   the exit clip, then the action completes on its own; asked during
--           the entry it is queued until the body is seated
--   end     whatever ends the playback (completed, moved, death, vehicle,
--           bucket, another resource, a disconnect) frees the spot
--
-- The RP animation service is the authority on the playback; this module only
-- remembers which spot a player holds and which phase the scene is in.
-- =============================================================================

local S = Open77Scenes
assert(S, "open77_scenes: shared/scenes.lua must load first")

Open77ScenesCore = {}
local Core = Open77ScenesCore

local DEFAULTS = {
    reach = 3.0,          -- metres from the player to the scene's stand point (prompt and start)
    vertical = 1.6,       -- metres of height difference accepted (floors above and below)
    promptRadius = 3.0,   -- spots offered as prompts within this distance
    promptLimit = 3,
    promptLift = 0.9,     -- the card floats this high above the anchor
    lostAfterMs = 4000,   -- a session whose playback the service no longer has is dropped
    -- The waiting body turns to the get-up's end heading this long before the get-up ends; 0 turns
    -- it once the playback has completed. A client older than the placement settle window
    -- (Emotes.cpp, feature/rp-scenes) ends the get-up on a turn while it plays, so 0 is the default.
    turnBeforeEndMs = 0,
}

function Core.new(P, config)
    local self = {
        P = P, config = {}, spots = {}, byPlayer = {}, taken = {}, prompts = {}, generation = P.generation or 0,
    }
    for key, value in pairs(DEFAULTS) do self.config[key] = (config and config[key] ~= nil) and config[key] or value end
    for name, fn in pairs(Core) do
        if type(fn) == "function" and name ~= "new" then self[name] = fn end
    end
    return self
end

-- -----------------------------------------------------------------------------
-- Spots
-- -----------------------------------------------------------------------------
local function validSpot(spot)
    return type(spot) == "table" and type(spot.id) == "string" and #spot.id > 0 and #spot.id <= 96 and
        type(spot.x) == "number" and type(spot.y) == "number" and type(spot.z) == "number"
end

--- Adds a spot: { id, kind, x, y, z, yaw } for a furniture kind of shared/scenes.lua,
--- or { id, scene, x, y, z, yaw } for an anchor a resource places itself (a prop).
function Core.addSpot(self, spot, owner)
    if not validSpot(spot) then return nil, "invalid_spot" end
    local entry = { id = spot.id, kind = spot.kind, scene = spot.scene, x = spot.x, y = spot.y, z = spot.z,
        yaw = type(spot.yaw) == "number" and spot.yaw or 0.0, owner = owner, label = spot.label }
    if entry.scene == nil then
        local furniture = entry.kind and S.furniture[entry.kind]
        if furniture == nil then return nil, "unknown_kind" end
        entry.scene, entry.label = furniture.scene, entry.label or furniture.label
    end
    if S.definitions[entry.scene] == nil then return nil, "unknown_scene" end
    self.spots[entry.id] = entry
    return entry
end

function Core.removeSpot(self, id, owner)
    local spot = self.spots[id]
    if spot == nil then return true end
    if spot.owner ~= owner then return nil, "spot_owned" end
    self.spots[id] = nil
    return true
end

--- The pose clients spawn the device at, and the scene playing there.
function Core.anchorOf(self, spot)
    local scene = S.definitions[spot.scene]
    if scene == nil then return nil end
    local anchor
    if spot.kind ~= nil then anchor = S.anchorOf(spot)
    else anchor = { x = spot.x, y = spot.y, z = spot.z, yaw = S.wrap(spot.yaw or 0) } end
    if anchor == nil then return nil end
    local stand = scene.stand and S.compose(anchor, scene.stand) or anchor
    return anchor, stand, scene
end

function Core.holder(self, bucket, spotId)
    local map = self.taken[bucket]
    return map and map[spotId] or nil
end

--- Spots within `radius` of `position`, nearest first (stand point distance).
function Core.nearby(self, position, radius, bucket, limit)
    local list = {}
    for _, spot in pairs(self.spots) do
        if math.abs(spot.x - position.x) <= radius + 3 and math.abs(spot.y - position.y) <= radius + 3 then
            local anchor, stand = self:anchorOf(spot)
            if anchor ~= nil and math.abs(stand.z - position.z) <= self.config.vertical then
                local d = S.distance({ x = stand.x, y = stand.y, z = 0 }, { x = position.x, y = position.y, z = 0 })
                if d <= radius then
                    list[#list + 1] = { spot = spot, anchor = anchor, stand = stand, distance = d,
                        holder = bucket ~= nil and self:holder(bucket, spot.id) or nil }
                end
            end
        end
    end
    table.sort(list, function(a, b) return a.distance < b.distance end)
    if limit then for i = #list, limit + 1, -1 do list[i] = nil end end
    return list
end

-- -----------------------------------------------------------------------------
-- Players
-- -----------------------------------------------------------------------------
local function vector(value)
    if type(value) ~= "table" then return nil end
    local x, y, z = value.x or value[1], value.y or value[2], value.z or value[3]
    if type(x) ~= "number" or type(y) ~= "number" or type(z) ~= "number" then return nil end
    return { x = x, y = y, z = z }
end

function Core.actor(self, pid)
    local read = self.P.readPlayer(pid)
    if type(read) ~= "table" then return nil, "player_unavailable" end
    if read.alive == false or read.dead == true or read.ready == false then return nil, "player_not_alive" end
    if read.inVehicle == true then return nil, "player_in_vehicle" end
    local position = vector(read.position)
    if position == nil then return nil, "position_unavailable" end
    return { pid = pid, bucket = read.bucket or 0, position = position }
end

local function state(session, active, reason)
    local scene = S.definitions[session.scene]
    local idles = {}
    for i, idle in ipairs(scene and scene.idles or {}) do idles[i] = idle.label or idle.clip end
    return { active = active, reason = reason, scene = session.scene, spot = session.spot, phase = session.phase,
        idle = session.idle, idles = idles, label = scene and scene.label or session.scene }
end

function Core.publish(self, session, active, reason)
    local payload = state(session, active, reason)
    payload.generation = self.generation
    self.P.send("open77:scenes:state", session.pid, payload)
end

function Core.current(self, pid)
    local session = self.byPlayer[pid]
    if session == nil then return nil end
    local copy = state(session, true)
    copy.playbackId, copy.bucket = session.playbackId, session.bucket
    copy.anchor = { x = session.anchor.x, y = session.anchor.y, z = session.anchor.z, yaw = session.anchor.yaw }
    return copy
end

local function standAt(session)
    local s = session.stand
    return { x = s.x, y = s.y, z = s.z, yaw = session.waitYaw or s.yaw }
end

--- Plays `steps` at the session's anchor (one device for the whole scene).
function Core.play(self, session, steps, hold)
    local a = session.anchor
    local options = { hold = hold, arrivalRadius = session.arrivalRadius }
    if session.stand ~= a then options.standAt = standAt(session) end
    local result, why = self.P.sequenceAt(session.pid, steps, { x = a.x, y = a.y, z = a.z }, a.yaw, options)
    if type(result) ~= "table" or type(result.playbackId) ~= "string" then return nil, why or "animation_refused" end
    session.playbackId = result.playbackId
    session.seenAt = self.P.now()
    return result
end

--- Starts `target` (a spot id) for a player. options.idle: the idle index to settle on.
function Core.start(self, pid, target, options)
    options = type(options) == "table" and options or {}
    if self.byPlayer[pid] then return nil, "already_in_scene" end
    local actor, why = self:actor(pid)
    if not actor then return nil, why end
    local spot = type(target) == "string" and self.spots[target] or nil
    if spot == nil then return nil, "unknown_spot" end
    local anchor, stand, scene = self:anchorOf(spot)
    if anchor == nil then return nil, "unknown_scene" end
    if S.distance({ x = stand.x, y = stand.y, z = 0 }, { x = actor.position.x, y = actor.position.y, z = 0 }) > self.config.reach or
        math.abs(stand.z - actor.position.z) > self.config.vertical then
        return nil, "too_far"
    end
    local holder = self:holder(actor.bucket, spot.id)
    if holder ~= nil and holder ~= pid then return nil, "spot_taken" end
    local running = self.P.current(pid)
    if type(running) == "table" and running.active ~= false then return nil, "actor_busy" end
    local idle = math.tointeger(options.idle) or 1
    if scene.idles[idle] == nil then return nil, "unknown_idle" end
    local session = { pid = pid, bucket = actor.bucket, spot = spot.id, scene = scene.id, anchor = anchor, stand = stand,
        arrivalRadius = scene.arrivalRadius, idle = idle, phase = scene.enter and "entering" or "idle",
        waitYaw = scene.waitYaw and S.wrap(anchor.yaw + scene.waitYaw) or nil }
    local steps = {}
    if scene.enter then
        steps[#steps + 1] = { profile = scene.profile, clip = scene.enter.clip, durationMs = scene.enter.durationMs }
    end
    steps[#steps + 1] = { profile = scene.profile, clip = scene.idles[idle].clip }
    local started, refused = self:play(session, steps, true)
    if not started then return nil, refused end
    -- A body already on its stand point is not relocated, so its heading is not either: turn it
    -- to face the furniture, where the platform's RP view hangs its camera behind it.
    if session.waitYaw and self.P.setHeading then self.P.setHeading(pid, session.waitYaw) end
    self.byPlayer[pid] = session
    self.taken[actor.bucket] = self.taken[actor.bucket] or {}
    self.taken[actor.bucket][spot.id] = pid
    self:publish(session, true)
    if self.P.event then self.P.event("open77_scenes:started", { playerId = pid, scene = scene.id, spot = spot.id, bucket = actor.bucket }) end
    return self:current(pid)
end

--- Settles on another idle (index, or the next one when nil).
function Core.setIdle(self, pid, index)
    local session = self.byPlayer[pid]
    if session == nil then return nil, "not_in_scene" end
    if session.phase ~= "idle" then return nil, "scene_busy" end
    local scene = S.definitions[session.scene]
    index = math.tointeger(index) or (session.idle % #scene.idles) + 1
    if scene.idles[index] == nil then return nil, "unknown_idle" end
    local played, why = self:play(session, { { profile = scene.profile, clip = scene.idles[index].clip } }, true)
    if not played then return nil, why end
    session.idle = index
    self:publish(session, true)
    return self:current(pid)
end

--- Gets the player up: the exit clip, after which the action completes on its own.
--- options.instant (or a scene with no exit) stops the playback at once instead.
function Core.stand(self, pid, options)
    local session = self.byPlayer[pid]
    if session == nil then return nil, "not_in_scene" end
    local scene = S.definitions[session.scene]
    if session.phase == "exiting" then return true end
    if (type(options) == "table" and options.instant) or scene.exit == nil then
        self.P.stopAt(session.playbackId)
        self:finish(session, "stood")
        return true
    end
    if session.phase == "entering" then
        session.pendingExit = true
        return true
    end
    local played, why = self:play(session, { { profile = scene.profile, clip = scene.exit.clip, durationMs = scene.exit.durationMs } }, false)
    if not played then
        self.P.stopAt(session.playbackId)
        self:finish(session, "stood")
        return nil, why
    end
    session.phase = "exiting"
    -- Hidden behind the presented body, the player's own body turns to where the get-up ends just
    -- before it ends: the RP view keeps its camera on the chair for the get-up, and the hand-back
    -- is in place and in heading (tick).
    if session.waitYaw and session.stand ~= session.anchor then
        if self.config.turnBeforeEndMs > 0 then
            session.turnAt = self.P.now() + math.max(0, scene.exit.durationMs - self.config.turnBeforeEndMs)
        else
            session.turnOnEnd = true
        end
    end
    self:publish(session, true)
    return true
end

function Core.finish(self, session, reason)
    if self.byPlayer[session.pid] ~= session then return end
    self.byPlayer[session.pid] = nil
    local map = self.taken[session.bucket]
    if map and map[session.spot] == session.pid then map[session.spot] = nil end
    self:publish(session, false, reason)
    if self.P.event then
        self.P.event("open77_scenes:ended", { playerId = session.pid, scene = session.scene, spot = session.spot, reason = reason })
    end
end

--- The platform's playback state for a player (`onPlayerAnimationChanged`).
function Core.onAnimation(self, pid, value)
    local session = self.byPlayer[pid]
    if session == nil or type(value) ~= "table" then return end
    if value.playbackId ~= session.playbackId then
        -- Another action replaced ours (another resource with the control
        -- capability): the scene is over, the device already gone.
        if value.active == true then self:finish(session, "replaced") end
        return
    end
    session.seenAt = self.P.now()
    if value.active == false then
        if session.turnOnEnd and value.reason == "completed" and self.P.setHeading then
            self.P.setHeading(pid, session.stand.yaw)
        end
        self:finish(session, value.reason == "completed" and "stood" or (value.reason or "stopped"))
        return
    end
    if session.phase == "entering" and (tonumber(value.step) or 0) >= 1 then
        session.phase = "idle"
        self:publish(session, true)
        if session.pendingExit then
            session.pendingExit = nil
            self:stand(pid)
        end
    end
end

--- Ends every scene of a player (disconnect) or of the resource (shutdown).
function Core.cancelPlayer(self, pid, reason)
    local session = self.byPlayer[pid]
    if session == nil then return end
    self.P.stopAt(session.playbackId)
    self:finish(session, reason or "cancelled")
end

function Core.shutdown(self)
    for pid in pairs(self.byPlayer) do self:cancelPlayer(pid, "resource_stopped") end
end

--- Reconciles with the service: a session whose playback it no longer runs is dropped.
function Core.tick(self)
    local now = self.P.now()
    for pid, session in pairs(self.byPlayer) do
        if session.turnAt and now >= session.turnAt then
            session.turnAt = nil
            if self.P.setHeading then self.P.setHeading(pid, session.stand.yaw) end
        end
        local value = self.P.current(pid)
        if type(value) == "table" and value.playbackId == session.playbackId and value.active ~= false then
            session.seenAt = now
            self:onAnimation(pid, value)
        elseif now - (session.seenAt or now) > self.config.lostAfterMs then
            self:finish(session, "lost")
        end
    end
end

-- -----------------------------------------------------------------------------
-- Prompts: at most `promptLimit` free spots within `promptRadius`, per player
-- -----------------------------------------------------------------------------
function Core.promptsFor(self, pid)
    if self.byPlayer[pid] then return {} end
    local actor = self:actor(pid)
    if not actor then return {} end
    local result = {}
    for _, near in ipairs(self:nearby(actor.position, self.config.promptRadius, actor.bucket)) do
        if near.holder == nil then
            local scene = S.definitions[near.spot.scene]
            result[#result + 1] = { id = near.spot.id, label = scene.prompt, title = near.spot.label or scene.label,
                position = { x = near.anchor.x, y = near.anchor.y, z = near.anchor.z + self.config.promptLift } }
            if #result >= self.config.promptLimit then break end
        end
    end
    return result
end

function Core.refreshPrompts(self, roster)
    for _, pid in ipairs(roster) do
        local list = self:promptsFor(pid)
        local parts = {}
        for i, item in ipairs(list) do parts[i] = item.id end
        local signature = table.concat(parts, ",")
        if self.prompts[pid] ~= signature then
            self.prompts[pid] = signature
            self.P.send("open77:scenes:spots", pid, { generation = self.generation, spots = list })
        end
    end
end

function Core.forget(self, pid)
    self.prompts[pid] = nil
    self:cancelPlayer(pid, "disconnected")
end
