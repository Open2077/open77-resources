-- =============================================================================
-- open77_actions -- server/carry.lua  (row A5, the carry helper)
-- =============================================================================
-- Pick up -> carry -> put down, as two engine operations around a carry
-- SESSION:
--
--   carry_pickup  op   sequence(carry_pickup -> carry hold); `grip` marker
--                      attaches the prop to the hands (Chest slot + a
--                      first-person placement); commit = the owner's `pickup`
--                      hook (custody-neutral by default) -> session starts
--   session            the hold: walk-mode lease, no jump, Attack blocked, the
--                      item claim renewed; any death / disconnect / bucket /
--                      vehicle / combat / owner stop ends it as a DROP at the
--                      carrier's feet (custody unchanged, the author is told)
--   carry_putdown op   carry_putdown clip; commit at the `release` marker =
--                      the owner's `putdown` hook, which is where custody
--                      changes; the projection (ground / point / vehicle slot /
--                      removed) follows the commit, never precedes it. A
--                      refused putdown resumes the carry.
--
-- The carried prop is owned by this resource (props are only mutable by their
-- owner), so authors place carriable items through `place` and keep the
-- durable custody in their own store (A13 `world:` containers); the item's
-- `data` carries the author's container id.
--
-- Grip and release markers are configured apart from the clip length:
-- duration is not a hand contact (plan section 8). The defaults below are
-- presentation guesses to calibrate in the lab, not measurements.
--
-- Global: Open77ActionsCarry.
-- =============================================================================

local M = Open77ActionsModel
local Carry = {}
Carry.__index = Carry
Open77ActionsCarry = Carry

local PICKUP_KEY = "open77_actions:carry_pickup"
local PUTDOWN_KEY = "open77_actions:carry_putdown"
Carry.PICKUP_KEY, Carry.PUTDOWN_KEY = PICKUP_KEY, PUTDOWN_KEY

local DEFAULT_PICKUP_MS, DEFAULT_PUTDOWN_MS = 1333, 2333   -- measured clipDurationsMs, wiki/rp-animations.md
local SEQUENCE_MAX_MS = 600000                               -- a sequence's steps may not sum past this
local MAX_ITEMS_PER_OWNER = 128
local ITEM_TOP = 0.5                                          -- the pickup card clears an item this tall
local PROJECTION_RETRIES = 3
local RESUME_WINDOW_MS = 15000                               -- carrier briefly unavailable (teleport): hold resumes

-- Reasons that end a putdown by dropping the item rather than resuming the
-- carry: the carrier can no longer hold anything.
local DROP_REASONS = {
    dead = true, disconnected = true, bucket_changed = true, vehicle = true, combat = true,
    owner_stopped = true, resource_stopping = true, animation_interrupted = true, in_doubt = true,
    player_unavailable = true, player_not_alive = true, player_in_vehicle = true,
}

function Carry.attach(engine)
    local self = setmetatable({
        E = engine, P = engine.P,
        kinds = {},          -- [key] = kind
        items = {},          -- [itemId] = item
        itemCounts = {},     -- [owner] = n
        sessions = {},       -- [playerId] = session
        byPlayback = {},     -- [playbackId] = session
        projections = {},    -- pending projection retries
        counter = 0,
    }, Carry)
    engine.ext = self
    engine.builtins[PICKUP_KEY] = function(initiator, pid, targetRef, options)
        return self:pickup(initiator, pid, targetRef, options)
    end
    engine.builtins[PUTDOWN_KEY] = function(initiator, pid, targetRef, options)
        options = options or {}
        options.target = targetRef
        return self:putdown(initiator, pid, options.destination, options)
    end
    return self
end

-- ---------------------------------------------------------------------------
-- Kinds
-- ---------------------------------------------------------------------------
local function clipLength(P, profileId, fallback)
    local profile = P.animProfile(profileId)
    if type(profile) == "table" and type(profile.clipDurationsMs) == "table" then
        local ms = profile.clipDurationsMs[profile.clip]
        if ms == nil then for _, v in pairs(profile.clipDurationsMs) do ms = v; break end end
        if tonumber(ms) and tonumber(ms) >= 250 then return math.floor(tonumber(ms)) end
    end
    return fallback
end

local function merge(a, b)
    local out = {}
    for k, v in pairs(a or {}) do out[k] = v end
    for k, v in pairs(b or {}) do out[k] = v end
    return out
end

function Carry:defineKind(owner, generation, def, internal)
    local kind, reason = M.normalizeCarryKind(def, internal)
    if not kind then return nil, reason end
    kind.pickupMs = kind.pickupMs or clipLength(self.P, kind.pickupProfile, DEFAULT_PICKUP_MS)
    kind.putdownMs = kind.putdownMs or clipLength(self.P, kind.putdownProfile, DEFAULT_PUTDOWN_MS)
    kind.gripMs = math.min(kind.gripMs or math.floor(kind.pickupMs * 0.6), kind.pickupMs)
    kind.releaseMs = math.min(kind.releaseMs or math.floor(kind.putdownMs * 0.55), kind.putdownMs)
    kind.key, kind.owner, kind.ownerGeneration = owner .. ":" .. kind.id, owner, generation

    local cancelOn = { combat = kind.cancelOn.combat, weaponDrawn = kind.cancelOn.weaponDrawn,
        vehicle = true, moved = false }
    local pickup, why = M.normalizeAction({
        id = "carry_pickup", label = kind.label, durationMs = kind.pickupMs, commitAtMs = kind.pickupMs,
        maxDistance = kind.reach, completeSlack = 1.0, claimTtlMs = 120000, requiresTarget = false,
        progress = false, claims = merge(kind.claims, { move = true }), cancelOn = cancelOn,
        markers = { { name = "grip", atMs = kind.gripMs } },
        hooks = { validate = kind.hooks.validate, commit = kind.hooks.pickup, cancel = kind.hooks.cancel },
        eligibility = kind.eligibility, epochs = kind.epochs, messages = kind.messages,
    }, true)
    if not pickup then return nil, why end
    local putdown
    putdown, why = M.normalizeAction({
        id = "carry_putdown", label = kind.label, durationMs = kind.putdownMs, commitAtMs = kind.releaseMs,
        maxDistance = 25.0, requiresTarget = false, whileCarrying = true, claimTtlMs = 120000,
        progress = false, claims = merge(kind.claims, { move = true }), cancelOn = cancelOn,
        markers = { { name = "release", atMs = kind.releaseMs } },
        hooks = { validate = kind.hooks.validate, commit = kind.hooks.putdown, cancel = kind.hooks.cancel },
        eligibility = kind.eligibility, epochs = kind.epochs, messages = kind.messages,
    }, true)
    if not putdown then return nil, why end
    for _, a in ipairs({ pickup, putdown }) do
        a.owner, a.ownerGeneration = owner, generation
        a.key = a.id == "carry_pickup" and PICKUP_KEY or PUTDOWN_KEY
    end
    kind.pickupAction, kind.putdownAction = pickup, putdown
    self.E:watchEpochEvents(pickup)
    self.kinds[kind.key] = kind
    self.E:noteOwner(owner, generation)
    return kind.key
end

function Carry:resolveKind(ref, caller)
    if type(ref) ~= "string" then return nil end
    if self.kinds[ref] then return self.kinds[ref] end
    if caller and M.validId(ref, 48) then return self.kinds[caller .. ":" .. ref] end
    return nil
end

-- ---------------------------------------------------------------------------
-- Items
-- ---------------------------------------------------------------------------
function Carry:publicItem(item)
    if item == nil then return nil end
    return {
        itemId = item.id, kind = item.kind.key, owner = item.owner, state = item.state,
        carrier = item.carrier, position = item.position, yaw = item.yaw, bucket = item.bucket,
        propId = item.propId, vehicleId = item.vehicleId, data = item.data,
    }
end

function Carry:event(phase, item, extra)
    local payload = { phase = phase, itemId = item.id, kind = item.kind.key, owner = item.owner,
        ownerGeneration = item.ownerGeneration, state = item.state, carrier = item.carrier,
        generation = self.P.generation }
    for k, v in pairs(extra or {}) do payload[k] = v end
    self.P.hostEvent("open77_actions:carry", payload)
    if self.E.trace then
        self.P.log("info", ("[actions] item=%s phase=%s state=%s player=%s reason=%s"):format(
            item.id, phase, item.state, tostring(payload.playerId or item.carrier or "-"),
            tostring(payload.reason or "-")))
    end
end

-- The target stands on the item's base, the point the server measures the reach from; the card is
-- lifted over the item's top (0.5 m) by the kind's `promptHeight`. The client's reach, sqrt(reach^2 +
-- lift^2) from the feet to the card, then matches the server's reach from the feet to the base.
function Carry:showTarget(item)
    local kind = item.kind
    return self.E:addTarget(item.owner, item.ownerGeneration, {
        id = "item_" .. item.id:gsub("[^%w_%.%-]", "_"),
        position = { x = item.position.x, y = item.position.y, z = item.position.z },
        bucket = item.bucket, label = kind.label, distance = kind.reach, markerDistance = 10.0,
        marker = "diamond", requires = "empty", promptHeight = ITEM_TOP + kind.promptHeight,
        actions = { { action = PICKUP_KEY, label = "Pick up " .. kind.label, key = "E" } },
    }, "item:" .. item.id)
end

function Carry:hideTarget(item)
    self.E:removeTarget("item:" .. item.id)
end

function Carry:place(owner, generation, kindRef, placement)
    local kind = self:resolveKind(kindRef, owner)
    if kind == nil then return nil, "unknown_action" end
    if kind.owner ~= owner and owner ~= self.P.resource then return nil, "not_owner" end
    if type(placement) ~= "table" then return nil, "invalid_options" end
    local position = M.vector(placement.position)
    local bucket = M.integer(placement.bucket, 0, 2147483647, 0)
    if position == nil or bucket == nil then return nil, "invalid_options" end
    if (self.itemCounts[kind.owner] or 0) >= MAX_ITEMS_PER_OWNER then return nil, "invalid_options" end
    local yaw = M.yaw(placement.yaw)
    local propId, why = self.P.props.create({ model = kind.model, position = position, yaw = yaw, bucket = bucket })
    if not propId then return nil, M.token(why, "attach_failed") end
    self.counter = self.counter + 1
    local item = {
        id = "it-" .. self.E.bootTag .. "-" .. M.base36(self.counter),
        kind = kind, owner = kind.owner, ownerGeneration = kind.ownerGeneration,
        propId = propId, position = position, yaw = yaw, bucket = bucket, state = "ground",
        data = M.copyData(placement.data, 1024),
    }
    self.items[item.id] = item
    self.itemCounts[kind.owner] = (self.itemCounts[kind.owner] or 0) + 1
    local shown, showWhy = self:showTarget(item)
    if not shown then
        self.P.log("warn", ("[actions] item=%s has no prompt (%s)"):format(item.id, tostring(showWhy)))
    end
    self:event("placed", item)
    return item.id
end

function Carry:removeItem(item, reason)
    if item == nil then return false end
    if item.carrier ~= nil then self:drop(item.carrier, reason or "owner_stopped") end
    self:hideTarget(item)
    if item.propId then self.P.props.remove(item.propId) end
    self.items[item.id] = nil
    self.itemCounts[item.owner] = math.max(0, (self.itemCounts[item.owner] or 1) - 1)
    item.state = "removed"
    self:event("removed", item, { reason = reason })
    return true
end

function Carry:remove(owner, itemId)
    local item = self.items[itemId]
    if item == nil then return nil, "item_unavailable" end
    if item.owner ~= owner and owner ~= self.P.resource then return nil, "not_owner" end
    -- An item in the middle of a pickup or putdown is not removed under the
    -- operation; the operation's own revalidation finds it gone.
    local live = item.carrier and self.E.active[item.carrier]
    if live ~= nil then self.E:cancel(live, "owner_stopped", "carry") end
    return self:removeItem(item, "removed")
end

function Carry:itemPosition(item)
    if item.state == "vehicle" and item.vehicleId then
        local v = self.P.vehicle(item.vehicleId)
        if v and v.position then return v.position, v.bucket end
        return nil
    end
    return item.position, item.bucket
end

-- ---------------------------------------------------------------------------
-- Pickup
-- ---------------------------------------------------------------------------
function Carry:pickup(initiator, pid, targetRef, options)
    options = options or {}
    local itemId = options.itemId
    if itemId == nil and type(targetRef) == "string" then
        itemId = targetRef:match("^item:(.+)$") or targetRef
    end
    local item = itemId and self.items[itemId] or nil
    if item == nil then return nil, "item_unavailable", { stage = "request" } end
    local caller = (initiator ~= "player" and initiator ~= "console") and initiator or nil
    if caller ~= nil and caller ~= item.owner and caller ~= self.P.resource then
        return nil, "not_owner", { stage = "request" }
    end
    if self.sessions[pid] then return nil, "carrying", { stage = "request" } end
    if item.state ~= "ground" and item.state ~= "vehicle" then return nil, "item_unavailable", { stage = "request" } end
    -- A client may only pick up what a prompt offered it: an item on the ground.
    if initiator == "player" and item.state ~= "ground" then return nil, "invalid_target", { stage = "request" } end
    local kind = item.kind
    local target = item.state == "ground" and self.E.targets["item:" .. item.id] or nil
    local P = self.P
    return self.E:start({
        kind = "carry_pickup", action = kind.pickupAction, actionKey = PICKUP_KEY,
        owner = item.owner, ownerGeneration = item.ownerGeneration, playerId = pid,
        target = target, targetKey = target and target.key or nil,
        claimKey = "item:" .. item.id, keepClaims = true, keepAnimation = true,
        carry = { itemId = item.id, kindId = kind.key, itemData = item.data, from = item.state },
        data = options.data ~= nil and M.copyData(options.data, 2048) or nil,
        supersede = options.supersede == true, initiator = initiator, trace = options.trace == true,
        check = function(op, read)
            if self.items[item.id] ~= item then return "item_unavailable" end
            -- A drawn weapon (fists included) owns the arms: the carry pose would be interrupted
            -- at once and the item dropped. Measured live 2026-10-12.
            local flags = read.flags
            if type(flags) == "table" and flags.weaponValid ~= false and flags.weaponEquipped == true then
                return "weapon_drawn"
            end
            local at, bucket = self:itemPosition(item)
            if at == nil then return "item_unavailable" end
            if read.bucket ~= bucket then return "wrong_bucket" end
            local reach = item.state == "vehicle" and kind.vehicleReach or kind.reach
            local d = M.distance(read.position, at)
            if d == nil or d > reach then return "too_far" end
            return nil
        end,
        animate = function(op)
            return P.animSequence(pid, {
                { profile = kind.pickupProfile, durationMs = kind.pickupMs },
                { profile = kind.holdProfile, durationMs = SEQUENCE_MAX_MS - kind.pickupMs },
            }, { loop = false })
        end,
    })
end

function Carry:binding(kind, pid, withFirstPerson)
    local b = kind.binding
    local binding = { parentType = "player", parentId = pid, bone = b.bone, offset = b.offset, rotation = b.rotation }
    if withFirstPerson and b.firstPerson ~= nil then binding.firstPerson = b.firstPerson end
    return binding
end

-- Attach to the hands; retry without the first-person placement on a platform
-- that refuses the key (the rp_nomade fallback, kept).
function Carry:attachToPlayer(item, pid)
    local ok, why = self.P.props.attach(item.propId, self:binding(item.kind, pid, true))
    if ok then return true end
    if why == "invalid_attachment" or why == "invalid_attachment_first_person" then
        ok, why = self.P.props.attach(item.propId, self:binding(item.kind, pid, false))
        if ok then
            self.P.log("warn", ("[actions] item=%s attached without firstPerson placement"):format(item.id))
            return true
        end
    end
    return nil, why
end

function Carry:onPresent(op)
    if op.kind == "carry_pickup" then
        local item = self.items[op.carry.itemId]
        if item then
            item.state = "lifting"
            item.carrier = op.playerId
            self:hideTarget(item)
        end
    elseif op.kind == "carry_putdown" then
        local session = self.sessions[op.playerId]
        if session then
            session.putdownOp = op.opId
            if session.playbackId then self.byPlayback[session.playbackId] = nil end
            session.playbackId = nil   -- replaced by the putdown clip
        end
    end
end

function Carry:onMarker(op, name)
    if op.kind ~= "carry_pickup" or name ~= "grip" then return end
    local item = self.items[op.carry.itemId]
    if item == nil then
        self.E:cancel(op, "item_unavailable", "present")
        return
    end
    local ok, why = self:attachToPlayer(item, op.playerId)
    if not ok then
        self.P.log("warn", ("[actions] item=%s grip attach refused: %s"):format(item.id, tostring(why)))
        self.E:cancel(op, "attach_failed", "present")
        return
    end
    op.carry.gripped = true
    self:event("gripped", item, { opId = op.opId, playerId = op.playerId, playbackId = op.playbackId })
end

-- Put a grounded item back where it was (a failed pickup) or at a point.
function Carry:ground(item, position, yaw)
    if item.propId then
        self.P.props.detach(item.propId)
        local ok, why = self.P.props.setTransform(item.propId, { position = position, yaw = yaw or item.yaw })
        if not ok then
            self.P.log("warn", ("[actions] item=%s ground placement refused: %s"):format(item.id, tostring(why)))
        end
    end
    item.position, item.yaw = position, yaw or item.yaw
    item.state, item.carrier, item.vehicleId = "ground", nil, nil
    self:showTarget(item)
end

function Carry:startSession(op, item)
    local session = {
        sessionId = op.opId, itemId = item.id, kind = item.kind, playerId = op.playerId,
        playbackId = op.playbackId, claimTokens = op.claimTokens, since = self.P.now(),
        bucket = op.bucket, epochs = op.epochs,
    }
    op.claimTokens = {}
    self.sessions[op.playerId] = session
    if session.playbackId then self.byPlayback[session.playbackId] = session end
    self.E.byPlayback[op.playbackId or ""] = nil
    item.state, item.carrier = "carried", op.playerId
    self.P.toClient(op.playerId, "open77:actions:carry", {
        generation = self.P.generation, itemId = item.id, sessionId = session.sessionId,
        label = item.kind.label, claims = item.kind.claims,
    })
    self:event("picked_up", item, { opId = op.opId, playerId = op.playerId, playbackId = op.playbackId })
    return session
end

-- `dropped`: { reason, label, message } when the item left the hands without a put-down, so the
-- carrier's client says so in words (kind.dropMessage).
function Carry:clearClient(pid, sessionId, dropped)
    self.P.toClient(pid, "open77:actions:carry", { generation = self.P.generation, itemId = false,
        sessionId = sessionId, dropped = dropped and dropped.reason or nil, label = dropped and dropped.label or nil,
        message = dropped and dropped.message })
end

function Carry:endSession(session, dropped)
    for _, token in ipairs(session.claimTokens or {}) do self.E.claims:release(token) end
    session.claimTokens = {}
    if session.playbackId then self.byPlayback[session.playbackId] = nil end
    if self.sessions[session.playerId] == session then self.sessions[session.playerId] = nil end
    self:clearClient(session.playerId, session.sessionId, dropped)
end

-- ---------------------------------------------------------------------------
-- Drop: the carrier can no longer hold the item. Custody does not change; the
-- item goes to the ground at the carrier's last known feet and the owner hears
-- about it.
-- ---------------------------------------------------------------------------
function Carry:drop(pid, reason)
    local session = self.sessions[pid]
    if session == nil then return false end
    local item = self.items[session.itemId]
    local read = self.P.readPlayer(pid)
    local at = (read and type(read.position) == "table") and read.position or session.lastPosition
    local heading = (read and (read.heading or read.yaw)) or session.lastHeading or 0
    if session.playbackId and self.P.connected(pid) then
        self.P.animStop(pid, session.playbackId, false)
    end
    self:endSession(session, item and { reason = tostring(reason), label = item.kind.label, message = item.kind.dropMessage })
    if item == nil then return true end
    local spot = at and M.offsetPoint(at, heading, item.kind.dropAhead, 0) or item.position
    -- Dropped in the air (a jump): on the ground the carrier last stood on, not where they hang.
    local flags = read and read.flags
    local airborne = type(flags) == "table" and flags.animationValid == true and flags.grounded == false
    if airborne and spot and session.lastGroundZ and session.lastGroundZ < spot.z then spot.z = session.lastGroundZ end
    self:ground(item, spot, heading)
    self:event("dropped", item, { playerId = pid, reason = reason, position = spot })
    local hook = item.kind.hooks.dropped
    if hook ~= nil then
        local ctx = { itemId = item.id, kind = item.kind.key, playerId = pid, reason = reason,
            position = spot, data = item.data, sessionId = session.sessionId, generation = self.P.generation }
        self.P.spawn(function()
            if type(hook) == "function" then pcall(hook, ctx) else self.P.hookAsync(item.owner, hook, ctx) end
        end)
    end
    return true
end

-- ---------------------------------------------------------------------------
-- Putdown
-- ---------------------------------------------------------------------------
function Carry:putdown(initiator, pid, destination, options)
    options = options or {}
    local session = self.sessions[pid]
    if session == nil then return nil, "not_carrying", { stage = "request" } end
    local item = self.items[session.itemId]
    if item == nil then return nil, "item_unavailable", { stage = "request" } end
    local caller = (initiator ~= "player" and initiator ~= "console") and initiator or nil
    if caller ~= nil and caller ~= item.owner and caller ~= self.P.resource then
        return nil, "not_owner", { stage = "request" }
    end
    if session.putdownOp then return nil, "actor_busy", { stage = "request" } end
    -- A client can only ask to put the item down in front of itself, or on a
    -- target that offers the put-down (a counter, a drop zone): then the
    -- destination is that target's point, claimed like any target.
    local target
    if initiator == "player" then
        destination = nil
        if options.target ~= nil then
            target = self.E.targets[options.target]
            local offered = false
            for _, choice in ipairs(target and target.actions or {}) do
                if choice.action == PUTDOWN_KEY then offered = true end
            end
            if not offered then return nil, "invalid_target", { stage = "request" } end
            destination = { kind = "point", position = target.position, yaw = target.yaw or 0 }
        end
    end
    local dest = { kind = "ground" }
    local claimKey
    if destination ~= nil then
        dest = M.normalizePlacement(destination)
        if dest == nil or dest.kind == "remove" then return nil, "destination_invalid", { stage = "request" } end
        if destination.claimKey ~= nil then
            if not M.validName(destination.claimKey, 96) then return nil, "destination_invalid", { stage = "request" } end
            claimKey = destination.claimKey
            dest.claimKey = claimKey
        end
        if target ~= nil then dest.target = target.key end
    end
    local kind = item.kind
    local P = self.P
    return self.E:start({
        kind = "carry_putdown", action = kind.putdownAction, actionKey = PUTDOWN_KEY,
        owner = item.owner, ownerGeneration = item.ownerGeneration, playerId = pid,
        target = target, targetKey = target and target.key or nil,
        extraClaims = claimKey and { "dest:" .. claimKey } or nil,
        carry = { itemId = item.id, kindId = kind.key, itemData = item.data, destination = dest },
        data = options.data ~= nil and M.copyData(options.data, 2048) or nil,
        initiator = initiator, trace = options.trace == true,
        epochs = session.epochs,          -- captured at pickup, rechecked at this commit
        check = function(op, read) return self:checkDestination(op, read) end,
        animate = function(op) return P.animPlay(pid, kind.putdownProfile, { loop = false }) end,
    })
end

function Carry:checkDestination(op, read)
    local dest = op.carry.destination
    local kind = self.items[op.carry.itemId] and self.items[op.carry.itemId].kind
    if kind == nil then return "item_unavailable" end
    if self.sessions[op.playerId] == nil or self.sessions[op.playerId].itemId ~= op.carry.itemId then
        return "not_carrying"
    end
    if dest.kind == "point" then
        local d = M.distance(read.position, dest.position)
        if d == nil or d > math.min(5.0, kind.reach + 1.0) then return "destination_too_far" end
    elseif dest.kind == "vehicle" then
        local v = self.P.vehicle(dest.vehicleId)
        if v == nil or v.position == nil then return "vehicle_unavailable" end
        if v.bucket ~= nil and v.bucket ~= read.bucket then return "wrong_bucket" end
        local d = M.distance(read.position, v.position)
        if d == nil or d > kind.vehicleReach then return "destination_too_far" end
    end
    return nil
end

function Carry:checkComplete(op, read)
    if op.kind == "carry_pickup" then
        if self.items[op.carry.itemId] == nil then return "item_unavailable" end
    elseif op.kind == "carry_putdown" then
        return self:checkDestination(op, read)
    end
    return nil
end

-- The projection follows the commit. A refused projection is retried a few
-- times and then falls back to the ground near the carrier: the business
-- outcome is final either way (plan section 6).
function Carry:project(item, placement, pid, read)
    if placement.kind == "remove" then
        self:hideTarget(item)
        if item.propId then self.P.props.remove(item.propId) end
        self.items[item.id] = nil
        self.itemCounts[item.owner] = math.max(0, (self.itemCounts[item.owner] or 1) - 1)
        item.state, item.carrier = "removed", nil
        return true
    elseif placement.kind == "vehicle" then
        local ok, why = self.P.props.attach(item.propId, {
            parentType = "vehicle", parentId = placement.vehicleId, bone = "",
            offset = placement.offset, rotation = placement.rotation,
        })
        if not ok then return nil, why end
        local v = self.P.vehicle(placement.vehicleId)
        item.state, item.carrier, item.vehicleId = "vehicle", nil, placement.vehicleId
        if v and v.position then item.position = v.position end
        return true
    end
    local at, yaw
    if placement.kind == "point" then
        at, yaw = placement.position, placement.yaw
    else
        local origin = (read and read.position) or item.position
        yaw = (read and (read.heading or read.yaw)) or 0
        at = M.offsetPoint(origin, yaw, item.kind.dropAhead, 0)
    end
    self:ground(item, at, yaw)
    return true
end

function Carry:onTerminal(op)
    if op.kind == "carry_pickup" then
        local item = self.items[op.carry.itemId]
        if op.state == "committed" and item ~= nil then
            if not op.carry.gripped then
                local ok, why = self:attachToPlayer(item, op.playerId)
                if not ok then
                    self.P.log("warn", ("[actions] item=%s late attach refused: %s"):format(item.id, tostring(why)))
                end
                op.carry.gripped = true
            end
            op.animationHandedOff = true    -- the hold step keeps playing under the session
            self:startSession(op, item)
            return
        end
        -- Refused, cancelled or in doubt before the session existed: put the
        -- item back exactly where it was lifted from.
        if item ~= nil and item.state == "lifting" then
            item.carrier = nil
            self:ground(item, item.position, item.yaw)
            self:event("pickup_" .. op.state, item, { opId = op.opId, playerId = op.playerId, reason = op.reason })
        end
        return
    end
    if op.kind ~= "carry_putdown" then return end
    local session = self.sessions[op.playerId]
    local item = self.items[op.carry.itemId]
    if session ~= nil then session.putdownOp = nil end
    if op.state == "committed" and item ~= nil then
        local placement = op.carry.destination
        local asked = type(op.receipt) == "table" and M.normalizePlacement(op.receipt.placement) or nil
        if asked ~= nil then placement = asked end
        local read = self.P.readPlayer(op.playerId)
        if session ~= nil then self:endSession(session) end
        local ok, why = self:project(item, placement, op.playerId, read)
        if not ok then
            self.projections[#self.projections + 1] = { itemId = item.id, placement = placement,
                attempts = 1, pid = op.playerId, origin = read and read.position, heading = read and read.heading }
            self.P.log("warn", ("[actions] item=%s projection refused (%s); retrying"):format(item.id, tostring(why)))
        end
        self:event("put_down", item, { opId = op.opId, playerId = op.playerId, placement = placement.kind,
            vehicleId = placement.vehicleId })
        return
    end
    if session == nil or item == nil then return end
    if DROP_REASONS[op.reason] or op.state == "in_doubt" or op.epochFailed then
        self:drop(op.playerId, op.state == "in_doubt" and "in_doubt" or op.reason)
        return
    end
    -- The putdown was refused (truck full, wrong key, player cancelled): the
    -- item never left the hands, so the carry resumes.
    local state = self.P.animPlay(op.playerId, item.kind.holdProfile, { loop = true })
    if type(state) == "table" and state.playbackId then
        session.playbackId = state.playbackId
        self.byPlayback[state.playbackId] = session
    end
    self:event("putdown_" .. op.state, item, { opId = op.opId, playerId = op.playerId, reason = op.reason })
end

-- ---------------------------------------------------------------------------
-- Session watchdog and events
-- ---------------------------------------------------------------------------
function Carry:sessionProblem(session, read)
    if read == nil then return self.P.connected(session.playerId) and nil or "disconnected" end
    if read.alive == false or read.dead == true then return "dead" end
    if read.bucket ~= nil and read.bucket ~= session.bucket then return "bucket_changed" end
    if read.inVehicle == true then return "vehicle" end
    local flags = read.flags
    if session.kind.cancelOn.combat and type(flags) == "table" and flags.combatValid ~= false and
        (flags.aiming == true or flags.triggerDown == true) then
        return "combat"
    end
    return nil
end

function Carry:tick(now)
    local list = {}
    for _, session in pairs(self.sessions) do list[#list + 1] = session end
    for _, session in ipairs(list) do
        if session.putdownOp == nil then
            local read = self.P.readPlayer(session.playerId)
            local bad = self:sessionProblem(session, read)
            if bad then
                self:drop(session.playerId, bad)
            elseif session.resumeDeadline then
                -- Suspended by a server move: replay the hold as soon as the player is back.
                local item = self.items[session.itemId]
                local state = (read and item) and self.P.animPlay(session.playerId, item.kind.holdProfile, { loop = true }) or nil
                if type(state) == "table" and state.playbackId then
                    session.resumeDeadline = nil
                    session.playbackId = state.playbackId
                    self.byPlayback[state.playbackId] = session
                    self:event("carry_resumed", item, { playerId = session.playerId })
                elseif self.P.now() > session.resumeDeadline then
                    session.resumeDeadline = nil
                    self:drop(session.playerId, "animation_interrupted")
                end
            else
                if read and type(read.position) == "table" then
                    session.lastPosition = read.position
                    session.lastHeading = read.heading or read.yaw
                    local flags = read.flags
                    if type(flags) == "table" and flags.animationValid == true and flags.grounded == true then
                        session.lastGroundZ = read.position.z
                    end
                end
                for _, token in ipairs(session.claimTokens) do self.E.claims:renew(token, 120000) end
            end
        end
    end
    if #self.projections > 0 then
        local pending = self.projections
        self.projections = {}
        for _, job in ipairs(pending) do
            local item = self.items[job.itemId]
            -- Still on the carrier's chest: the commit happened, the projection did not.
            if item ~= nil and item.state == "carried" and
                (self.sessions[job.pid] == nil or self.sessions[job.pid].itemId ~= item.id) then
                local ok = self:project(item, job.placement, job.pid, nil)
                if not ok then
                    job.attempts = job.attempts + 1
                    if job.attempts > PROJECTION_RETRIES then
                        local fallback = job.origin and M.offsetPoint(job.origin, job.heading or 0, item.kind.dropAhead, 0) or item.position
                        self:ground(item, fallback, job.heading)
                        self.P.log("warn", ("[actions] item=%s projection_failed; placed on the ground"):format(item.id))
                        self:event("projection_failed", item, { placement = job.placement.kind })
                    else
                        self.projections[#self.projections + 1] = job
                    end
                end
            end
        end
    end
end

function Carry:onAnimation(pid, state)
    local session = self.byPlayback[state.playbackId]
    if session == nil or session.playerId ~= pid or state.active ~= false then return end
    if self.sessions[pid] ~= session or session.putdownOp then return end
    self.byPlayback[state.playbackId] = nil
    session.playbackId = nil
    local reason = tostring(state.reason or "")
    local item = self.items[session.itemId]
    if reason == "completed" and item then
        -- The hold step ran out (the sequence is capped at 600 s): keep holding.
        local next_ = self.P.animPlay(pid, item.kind.holdProfile, { loop = true })
        if type(next_) == "table" and next_.playbackId then
            session.playbackId = next_.playbackId
            self.byPlayback[next_.playbackId] = session
        end
        return
    end
    if reason == "player_unavailable" and item and self.P.connected(pid) then
        -- A server move (Warden teleport, travel, respawn transition) takes the body away for
        -- a moment while the carrier stays connected. Measured 2026-10-12: a teleport ended the
        -- hold pose with `player_unavailable` and the item was dropped as "disconnected". The
        -- prop stays attached to the player, so keep custody and replay the hold once the
        -- player is available again (Carry:tick); only a carrier that does not come back in
        -- RESUME_WINDOW_MS loses the item.
        session.resumeDeadline = self.P.now() + RESUME_WINDOW_MS
        self:event("carry_suspended", item, { playerId = pid, reason = reason })
        return
    end
    local mapped = ({ player_in_vehicle = "vehicle", player_not_alive = "dead", bucket_changed = "bucket_changed",
        player_unavailable = "disconnected" })[reason] or "animation_interrupted"
    self:drop(pid, mapped)
end

function Carry:isCarrying(pid) return self.sessions[pid] ~= nil end

-- An epoch guard's event during a carry: the hold was started under a job
-- state that no longer holds, so the item goes down (custody unchanged).
function Carry:onEpochEvent(event, pid, epoch)
    local session = self.sessions[pid]
    if session == nil or session.putdownOp or session.epochs == nil then return end
    for index, guard in ipairs(session.kind.pickupAction.epochs or {}) do
        if guard.event == event and session.epochs[index] ~= epoch then
            self:drop(pid, guard.reason)
            return
        end
    end
end

function Carry:cancelPlayer(pid, reason, flag)
    local session = self.sessions[pid]
    if session == nil or session.putdownOp then return end
    if flag ~= nil and not session.kind.cancelOn[flag] then return end
    self:drop(pid, reason)
end

function Carry:clientCancel(_pid, _opId) return false end

function Carry:ownerGone(owner)
    for pid, session in pairs(self.sessions) do
        local item = self.items[session.itemId]
        if item and item.owner == owner then self:drop(pid, "owner_stopped") end
    end
    for _, item in pairs(self.items) do
        if item.owner == owner then self:removeItem(item, "owner_stopped") end
    end
    for key, kind in pairs(self.kinds) do
        if kind.owner == owner then self.kinds[key] = nil end
    end
    self.itemCounts[owner] = nil
end

function Carry:shutdown()
    for pid in pairs(self.sessions) do self:drop(pid, "resource_stopping") end
end

function Carry:stateFor(pid)
    local session = self.sessions[pid]
    if session == nil then return nil end
    return { itemId = session.itemId, sessionId = session.sessionId, label = session.kind.label,
        claims = session.kind.claims }
end

return Carry
