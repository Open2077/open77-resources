-- =============================================================================
-- open77_actions -- server/engine.lua
-- =============================================================================
-- The action lifecycle of docs/world-interaction-plan.md section 6:
--
--   intent ──► validate ──► claim + reserve ──► present ──► revalidate ──► commit
--     │            │               │                │              │          │
--     │            └─ refused      └─ refused       └─ cancelled   └─ cancel  ├─ committed ─► projection
--     │               (nothing held)  (nothing held)   (released)     (released)├─ failed (cancel hook)
--     │                                                                        └─ in_doubt (author settles)
--
-- One operation per actor. Every operation has an `opId`; every client message,
-- host event, timer and hook context carries it together with this VM's
-- generation and, once presented, the animation `playbackId`. A callback whose
-- operation is terminal, whose playback id is not the operation's, or whose
-- generation is not ours, changes nothing -- that is what keeps a stale
-- completion from touching the replacement action.
--
-- The server decides completion from its own clock. A client may only ask to
-- cancel its own current operation; it can never report one finished.
--
-- Platform access goes through the `P` ports table that server/main.lua builds
-- from the Open77 globals, so the offline suite runs this file unchanged
-- against fakes.
--
-- Global: Open77ActionsEngine.
-- =============================================================================

local M = Open77ActionsModel
local Claims = Open77ActionsClaims
assert(M ~= nil and Claims ~= nil, "open77_actions: shared/model.lua and server/claims.lua must load first")

local Engine = {}
Engine.__index = Engine
Open77ActionsEngine = Engine

local MAX_ACTIONS_PER_OWNER = 64
local MAX_TARGETS_PER_OWNER = 64
local MAX_TARGETS = 512
local MAX_OPS_RETAINED = 512        -- terminal operations kept for status()/verify()
local RETRYABLE_COMMIT = {
    in_doubt = true, busy = true, export_timeout = true,
    export_resource_stopped = true, export_target_busy = true,
}
-- The coordinator's transient refusals (contract §7.2, C1 finding B5-3): nothing was applied,
-- so they are retried with the SAME opId (a commit that did land answers from its receipt),
-- and once the retries run out the action FAILS with that reason; it is never in doubt.
local TRANSIENT_REFUSAL = { coordinator_unavailable = true, store_unavailable = true, conflict = true }
local ANIMATION_END_REASON = {
    player_in_vehicle = "vehicle", player_not_alive = "dead", player_unavailable = "disconnected",
    bucket_changed = "bucket_changed", moved = "moved",
}

function Engine.new(P)
    local self = setmetatable({
        P = P,
        actions = {},            -- [key] = action (normalised + owner fields)
        targets = {},            -- [key] = target
        targetCount = 0,
        ownerCounts = {},        -- [owner] = { actions, targets }
        owners = {},             -- [owner] = generation seen at registration
        ops = {},                -- [opId] = op
        opOrder = {},            -- terminal op ids, oldest first, for retention
        active = {},             -- [playerId] = op (non-terminal or trailing)
        byPlayback = {},         -- [playbackId] = op
        cooldowns = {},          -- ["<pid>|<key>"] = untilMs
        counter = 0,
        -- Unique across server restarts: the monotonic clock restarts near zero with the
        -- host (live 2026-10-12 ids read `act-0-1`), and the transaction coordinator treats a
        -- reused opId as a replay of its stored receipt. Wall clock + a random suffix.
        bootTag = M.base36(P.unix and P.unix() or P.now()) .. M.base36(P.random and P.random(0, 46655) or 0),
        trace = false,
        epochs = {},             -- [event] = { [playerId] = last epoch seen }
        ext = nil,               -- the carry helper plugs in here
        builtins = {},           -- [actionKey] = function(initiator, pid, targetKey, options)
    }, Engine)
    self.claims = Claims.new({ now = P.now })
    return self
end

-- ---------------------------------------------------------------------------
-- Logging and notices
-- ---------------------------------------------------------------------------
-- One line per transition, in the shape the integrator's lab greps for:
--   [actions] op=<id> state=<state> reason=<reason> action=<key> player=<id> ...
function Engine:line(op, extra)
    local parts = {
        "[actions] op=" .. op.opId,
        "state=" .. op.state,
        "reason=" .. tostring(op.reason or "-"),
    }
    if op.stage then parts[#parts + 1] = "stage=" .. op.stage end
    parts[#parts + 1] = "action=" .. op.actionKey
    parts[#parts + 1] = "player=" .. tostring(op.playerId)
    if op.targetKey then parts[#parts + 1] = "target=" .. op.targetKey end
    if op.playbackId then parts[#parts + 1] = "playback=" .. tostring(op.playbackId) end
    if extra then parts[#parts + 1] = extra end
    return table.concat(parts, " ")
end

function Engine:publicOp(op)
    return {
        opId = op.opId, action = op.actionKey, actionId = op.action.id, owner = op.owner,
        ownerGeneration = op.ownerGeneration, playerId = op.playerId, bucket = op.bucket,
        target = op.targetKey, state = op.state, reason = op.reason, stage = op.stage,
        playbackId = op.playbackId, generation = self.P.generation, kind = op.kind,
        startedAtMs = op.startedAt, completeAtMs = op.completeAt, receipt = op.receipt,
        trailing = op.trailing == true, itemId = op.carry and op.carry.itemId or nil,
    }
end

function Engine:transition(op, state, reason, stage, extra)
    op.state = state
    if reason ~= nil then op.reason = reason end
    if stage ~= nil then op.stage = stage end
    op.updatedAt = self.P.now()
    if self.trace or op.trace then self.P.log("info", self:line(op, extra)) end
    self.P.hostEvent("open77_actions:transition", self:publicOp(op))
end

-- ---------------------------------------------------------------------------
-- Registries
-- ---------------------------------------------------------------------------
local function counts(self, owner)
    local c = self.ownerCounts[owner]
    if c == nil then
        c = { actions = 0, targets = 0 }
        self.ownerCounts[owner] = c
    end
    return c
end

function Engine:noteOwner(owner, generation)
    if owner ~= self.P.resource then self.owners[owner] = generation end
end

function Engine:define(owner, generation, def, internal)
    if not M.validName(owner, 64) then return nil, "owner_unavailable" end
    local action, reason = M.normalizeAction(def, internal)
    if not action then return nil, reason end
    local key = owner .. ":" .. action.id
    local existing = self.actions[key]
    if existing == nil and counts(self, owner).actions >= MAX_ACTIONS_PER_OWNER then
        return nil, "invalid_definition"
    end
    action.key, action.owner, action.ownerGeneration = key, owner, generation
    if existing == nil then counts(self, owner).actions = counts(self, owner).actions + 1 end
    self:watchEpochEvents(action)
    -- Redefining replaces the definition for NEW operations only; a running
    -- operation keeps the table it started with.
    self.actions[key] = action
    self:noteOwner(owner, generation)
    return key
end

function Engine:watchEpochEvents(action)
    for _, guard in ipairs(action.epochs or {}) do
        if guard.event and self.P.watchEvent then self.P.watchEvent(guard.event) end
    end
end

function Engine:undefine(owner, id)
    local removed = 0
    for key, action in pairs(self.actions) do
        if action.owner == owner and (id == nil or action.id == id) then
            self.actions[key] = nil
            counts(self, owner).actions = counts(self, owner).actions - 1
            removed = removed + 1
        end
    end
    if removed == 0 then return nil, "unknown_action" end
    return removed
end

-- Resolve an action reference: "owner:id" as given, or a bare id against the
-- caller's own definitions.
function Engine:resolveAction(ref, caller)
    if type(ref) ~= "string" then return nil end
    if self.actions[ref] then return self.actions[ref], ref end
    if caller and M.validId(ref, 48) then
        local key = caller .. ":" .. ref
        if self.actions[key] then return self.actions[key], key end
    end
    return nil
end

function Engine:resolveTarget(ref, caller)
    if type(ref) ~= "string" then return nil end
    if self.targets[ref] then return self.targets[ref], ref end
    if caller and M.validId(ref, 48) then
        local key = caller .. ":" .. ref
        if self.targets[key] then return self.targets[key], key end
    end
    return nil
end

function Engine:addTarget(owner, generation, def, internalKey)
    local target, reason = M.normalizeTarget(def)
    if not target then return nil, reason end
    local key = internalKey or (owner .. ":" .. target.id)
    local existing = self.targets[key]
    if existing == nil then
        if counts(self, owner).targets >= MAX_TARGETS_PER_OWNER and internalKey == nil then
            return nil, "invalid_target"
        end
        if self.targetCount >= MAX_TARGETS then return nil, "invalid_target" end
        -- Carry-item prompts (internal keys) count against the global bound
        -- only; the per-owner budget is for targets an author declares.
        if internalKey == nil then counts(self, owner).targets = counts(self, owner).targets + 1 end
        self.targetCount = self.targetCount + 1
    end
    target.key, target.owner, target.ownerGeneration = key, owner, generation
    target.internal = internalKey ~= nil
    -- Action references are qualified against the declaring owner, so a
    -- target can only offer its owner's actions and the built-ins.
    for _, choice in ipairs(target.actions) do
        if not choice.action:find(":", 1, true) then choice.action = owner .. ":" .. choice.action end
        if choice.label == nil then
            local action = self.actions[choice.action]
            choice.label = action and action.label or target.label or choice.action
        end
    end
    self.targets[key] = target
    self:noteOwner(owner, generation)
    if existing and existing.keepCrowdOff and (not target.keepCrowdOff or existing.bucket ~= target.bucket) and
        self.P.crowdRelease then
        self.P.crowdRelease(existing.bucket, "act:" .. key)
    end
    if target.keepCrowdOff and self.P.crowdHold then
        target.crowdHeld = self.P.crowdHold(target.bucket, "act:" .. key, target.position, target.keepCrowdOff)
        target.crowdAt = self.P.now()
    end
    if existing and existing.bucket ~= target.bucket then self.P.pushTargets(existing.bucket, nil, { key }) end
    self.P.pushTargets(target.bucket, { target }, nil)
    return key
end

function Engine:removeTarget(key)
    local target = self.targets[key]
    if target == nil then return false end
    self.targets[key] = nil
    self.targetCount = self.targetCount - 1
    if target.keepCrowdOff and self.P.crowdRelease then self.P.crowdRelease(target.bucket, "act:" .. key) end
    if not target.internal then counts(self, target.owner).targets = counts(self, target.owner).targets - 1 end
    self.P.pushTargets(target.bucket, nil, { key })
    return true
end

function Engine:removeTargets(owner, id)
    local removed = 0
    for key, target in pairs(self.targets) do
        if target.owner == owner and (id == nil or target.id == id) then
            if self:removeTarget(key) then removed = removed + 1 end
        end
    end
    return removed
end

function Engine:targetsIn(bucket)
    local out = {}
    for _, target in pairs(self.targets) do
        if target.bucket == bucket and target.hidden ~= true then out[#out + 1] = target end
    end
    table.sort(out, function(l, r) return l.key < r.key end)
    return out
end

-- ---------------------------------------------------------------------------
-- Operation records
-- ---------------------------------------------------------------------------
function Engine:newOpId()
    self.counter = self.counter + 1
    return "act-" .. self.bootTag .. "-" .. M.base36(self.counter)
end

function Engine:retain(op)
    self.opOrder[#self.opOrder + 1] = op.opId
    while #self.opOrder > MAX_OPS_RETAINED do
        local old = table.remove(self.opOrder, 1)
        local record = self.ops[old]
        if record and M.TERMINAL[record.state] and not record.trailing then self.ops[old] = nil end
    end
end

function Engine:context(op, phase, extra)
    local target = op.target
    local ctx = {
        opId = op.opId, action = op.actionKey, actionId = op.action.id,
        owner = op.owner, ownerGeneration = op.ownerGeneration,
        playerId = op.playerId, bucket = op.bucket, phase = phase,
        target = target and {
            key = target.key, id = target.id, position = target.position, yaw = target.yaw,
            data = target.data,
        } or nil,
        data = op.data, reservation = op.reservation, receipt = op.receipt,
        startedAtMs = op.startedAt, generation = self.P.generation,
        playbackId = op.playbackId, kind = op.kind,
    }
    if op.carry then
        ctx.carry = { itemId = op.carry.itemId, kind = op.carry.kindId, data = op.carry.itemData,
            destination = op.carry.destination }
    end
    if extra then for k, v in pairs(extra) do ctx[k] = v end end
    return ctx
end

-- ---------------------------------------------------------------------------
-- Hooks
-- ---------------------------------------------------------------------------
-- A hook is either an export NAME on the owner resource (the only thing that
-- crosses a VM boundary) or, for the library's own built-ins and lab actions,
-- a Lua function. validate/marker run synchronously and must not yield;
-- reserve/commit/cancel run asynchronously and may await the coordinator.
function Engine:hookSync(op, name, ctx)
    local hook = op.action.hooks[name]
    if hook == nil then return true end
    if type(hook) == "function" then
        local ok, a, b = pcall(hook, ctx, self)
        if not ok then
            self.P.log("warn", ("[actions] op=%s hook=%s raised: %s"):format(op.opId, name, tostring(a)))
            return nil, "hook_failed"
        end
        return a, b
    end
    return self.P.hookSync(op.owner, hook, ctx)
end

function Engine:hookAsync(op, name, ctx)
    local hook = op.action.hooks[name]
    if hook == nil then return nil, nil, "absent" end
    if type(hook) == "function" then
        local ok, a, b = pcall(hook, ctx, self)
        if not ok then
            self.P.log("warn", ("[actions] op=%s hook=%s raised: %s"):format(op.opId, name, tostring(a)))
            return nil, "hook_failed"
        end
        return a, b
    end
    return self.P.hookAsync(op.owner, hook, ctx)
end

-- The cancel hook runs exactly once per operation and never before the reserve
-- hook has answered: a cancel that lands while the reservation is in flight is
-- delivered by the reserve thread when it returns, so the author can always
-- release what it reserved.
function Engine:fireCancelHook(op, reason)
    if op.cancelHookFired then return end
    if op.action.hooks.cancel == nil then
        op.cancelHookFired = true
        return
    end
    if op.reserveInFlight then
        op.cancelHookPending = reason
        return
    end
    op.cancelHookFired = true
    local ctx = self:context(op, "cancel", { reason = reason })
    self.P.spawn(function()
        local _, why = self:hookAsync(op, "cancel", ctx)
        if why ~= nil and why ~= "absent" then
            self.P.log("warn", ("[actions] op=%s cancel hook answered %s"):format(op.opId, tostring(why)))
        end
    end)
end

-- ---------------------------------------------------------------------------
-- Validation
-- ---------------------------------------------------------------------------
function Engine:readActor(pid)
    if not self.P.connected(pid) then return nil, "player_unavailable" end
    local read = self.P.readPlayer(pid)
    if type(read) ~= "table" then return nil, "player_unavailable" end
    return read
end

-- Everything a client prompt claimed is re-derived here from the server's own
-- reads: life, readiness, vehicle seat, bucket, position age, distance, combat.
function Engine:checkActor(op, read, phase)
    local action = op.action
    if read.ready == false then return "player_not_ready" end
    if read.alive == false or read.dead == true then return "player_not_alive" end
    if read.inVehicle == true and action.cancelOn.vehicle then return "player_in_vehicle" end
    if type(read.position) ~= "table" then return "position_unavailable" end
    if read.ageMs ~= nil and read.ageMs > action.maxPositionAgeMs then return "position_stale" end
    if phase == "complete" and read.bucket ~= op.bucket then return "wrong_bucket" end
    local flags = read.flags
    if action.cancelOn.combat and type(flags) == "table" and flags.combatValid ~= false and
        (flags.aiming == true or flags.triggerDown == true) then
        return "in_combat"
    end
    local target = op.target
    if target ~= nil then
        if read.bucket ~= target.bucket then return "wrong_bucket" end
        local limit = action.maxDistance + (phase == "complete" and action.completeSlack or 0)
        local d = M.distance(read.position, target.position)
        if d == nil or d > limit then return "too_far" end
    end
    return nil
end

-- A placed action (animation `at = "target"`) puts the actor on the target's stand point: refused
-- while somebody else stands there, or the actor would be placed on top of them. Someone working
-- this very target is left to the claim stage, whose `target_claimed` says more (an owner may claim
-- under its own key). A player held in a placed action of another target (a patient lying in the
-- chair beside the ripperdoc's station, 0.7 m away) is anchored to that target's own measured
-- point and does not block.
function Engine:checkSpot(op)
    local an, target = op.action.animation, op.target
    if an == nil or an.at ~= "target" or target == nil or self.P.playersNear == nil then return nil end
    local near = self.P.playersNear(target.bucket, target.position, M.SPOT_RADIUS, M.SPOT_HEIGHT, op.playerId)
    local blocked = false
    for _, pid in ipairs(type(near) == "table" and near or {}) do
        local other = self.active[pid]
        local otherTarget = other ~= nil and other.target or nil
        if otherTarget ~= nil and otherTarget.key == target.key then return nil end
        if not (other ~= nil and other.placed and otherTarget ~= nil) then blocked = true end
    end
    return blocked and "spot_taken" or nil
end

-- Eligibility providers (rp_jobs:eligible and the like): synchronous exports
-- asked at begin and again before the commit.
function Engine:checkEligibility(op)
    for _, e in ipairs(op.action.eligibility or {}) do
        local ok, allowed, why = self.P.callSync(e.resource, e.export, op.playerId, e.args)
        if not ok then
            self.P.log("warn", ("[actions] op=%s eligibility %s:%s raised: %s"):format(
                op.opId, e.resource, e.export, tostring(allowed)))
            return "hook_failed"
        end
        if not allowed then return M.token(why, "not_eligible") end
    end
    return nil
end

function Engine:readEpoch(guard, pid)
    if guard.read then
        local ok, value = self.P.callSync(guard.resource, guard.read, pid)
        if not ok then return nil, "hook_failed" end
        if value == nil then return false end
        return value
    end
    local seen = self.epochs[guard.event]
    local value = seen and seen[pid]
    if value == nil then return false end
    return value
end

function Engine:captureEpochs(op)
    op.epochs = {}
    for index, guard in ipairs(op.action.epochs or {}) do
        local value, why = self:readEpoch(guard, op.playerId)
        if why then return why end
        op.epochs[index] = value
    end
    return nil
end

function Engine:checkEpochs(op)
    for index, guard in ipairs(op.action.epochs or {}) do
        local value, why = self:readEpoch(guard, op.playerId)
        if why then return why end
        if op.epochs == nil or value ~= op.epochs[index] then
            op.epochFailed = true
            return guard.reason
        end
    end
    return nil
end

-- A guard's event: remember the value, and cancel the actor's operation at
-- once when it no longer matches what was captured at begin.
function Engine:onEpochEvent(event, pid, epoch)
    pid = M.playerId(pid)
    if pid == nil then return end
    self.epochs[event] = self.epochs[event] or {}
    self.epochs[event][pid] = epoch
    local op = self.active[pid]
    if op ~= nil and not M.TERMINAL[op.state] and op.state ~= "committing" and op.epochs then
        for index, guard in ipairs(op.action.epochs or {}) do
            if guard.event == event and op.epochs[index] ~= epoch then
                op.epochFailed = true
                self:cancel(op, guard.reason, "present")
                break
            end
        end
    end
    if self.ext and self.ext.onEpochEvent then self.ext:onEpochEvent(event, pid, epoch) end
end

function Engine:runValidateHook(op, phase)
    local allowed, why = self:hookSync(op, "validate", self:context(op, phase))
    if allowed == true or (op.action.hooks.validate == nil) then return nil end
    if allowed == nil and why == "hook_failed" then return "hook_failed" end
    return M.token(why, "refused_by_owner")
end

-- ---------------------------------------------------------------------------
-- Begin
-- ---------------------------------------------------------------------------
local function refusal(reason, stage, op, holder)
    return nil, reason, { stage = stage, opId = op and op.opId or nil, state = op and op.state or nil,
        retryable = reason == "target_claimed" or reason == "destination_claimed" or reason == "actor_busy",
        holder = holder and holder.holder or nil }
end

--- request(initiator, playerId, actionRef, targetRef, options)
--- Validates synchronously and starts the operation. Returns the operation
--- (state `presenting`, or `reserving` while an async reserve hook runs) or
--- nil, reason, info. `initiator` is the calling resource name, or "player"
--- for a client intent, or "console".
function Engine:request(initiator, playerId, actionRef, targetRef, options)
    options = options or {}
    if type(options) ~= "table" then return refusal("invalid_options", "request") end
    local pid = M.playerId(playerId)
    if pid == nil then return refusal("invalid_player", "request") end
    local caller = (initiator ~= "player" and initiator ~= "console") and initiator or nil

    local builtin = type(actionRef) == "string" and self.builtins[actionRef] or nil
    if builtin then return builtin(initiator, pid, targetRef, options) end

    local action, key = self:resolveAction(actionRef, caller)
    if action == nil then
        return refusal(type(actionRef) == "string" and "unknown_action" or "invalid_action", "request")
    end
    -- A resource may only start its own actions; a client may start any action
    -- a target offers it, and the server checks the target offers it.
    if caller ~= nil and caller ~= action.owner and caller ~= self.P.resource then
        return refusal("not_owner", "request")
    end

    local target
    if targetRef == false then targetRef = nil end
    if targetRef ~= nil then
        target = self:resolveTarget(targetRef, action.owner)
        if target == nil then return refusal("unknown_target", "request") end
        if initiator == "player" then
            local offered = false
            for _, choice in ipairs(target.actions) do
                if choice.action == key then offered = true end
            end
            if not offered then return refusal("invalid_target", "request") end
        end
    elseif action.requiresTarget then
        return refusal("invalid_target", "request")
    end
    if initiator == "player" and target == nil then return refusal("invalid_target", "request") end

    return self:start({
        kind = "action", action = action, actionKey = key, owner = action.owner,
        ownerGeneration = action.ownerGeneration, playerId = pid, target = target,
        targetKey = target and target.key or nil,
        data = options.data ~= nil and M.copyData(options.data, 2048) or nil,
        supersede = options.supersede == true or action.supersede,
        initiator = initiator, trace = options.trace == true,
    })
end

-- Shared by actions and the carry helper. `spec.claimKey` overrides the
-- target-derived claim; `spec.extraClaims` adds more (a truck slot).
function Engine:start(spec)
    local action, pid = spec.action, spec.playerId
    if self.P.ownerGeneration(spec.owner) ~= spec.ownerGeneration and spec.owner ~= self.P.resource then
        return refusal("owner_unavailable", "request")
    end

    -- One operation per actor.
    local current = self.active[pid]
    if current ~= nil then
        if current.trailing then
            self:endPresentation(current, "superseded")
        elseif current.state == "committing" or not spec.supersede then
            return refusal("actor_busy", "request", current)
        else
            self:cancel(current, "superseded", "request")
            if self.active[pid] ~= nil then return refusal("actor_busy", "request", current) end
        end
    end
    if self.ext and not action.whileCarrying and spec.kind == "action" and self.ext:isCarrying(pid) then
        return refusal("carrying", "request")
    end
    local cooldownKey = pid .. "|" .. spec.actionKey
    local until_ = self.cooldowns[cooldownKey]
    if until_ ~= nil and until_ > self.P.now() then return refusal("actor_busy", "request") end

    local op = {
        opId = self:newOpId(), kind = spec.kind, action = action, actionKey = spec.actionKey,
        owner = spec.owner, ownerGeneration = spec.ownerGeneration, playerId = pid,
        target = spec.target, targetKey = spec.targetKey, data = spec.data,
        initiator = spec.initiator, trace = spec.trace, carry = spec.carry,
        claimKey = spec.claimKey, extraClaims = spec.extraClaims,
        animate = spec.animate, keepAnimation = spec.keepAnimation, keepClaims = spec.keepClaims,
        state = "validating", createdAt = self.P.now(), claimTokens = {}, markersFired = {},
    }

    local read, why = self:readActor(pid)
    if read == nil then return refusal(why, "validate") end
    op.bucket = read.bucket
    op.origin = read.position and { x = read.position.x, y = read.position.y, z = read.position.z } or nil
    op.heading = read.heading or read.yaw
    local bad = self:checkActor(op, read, "begin")
    if bad == nil and spec.check then bad = spec.check(op, read) end
    if bad == nil then bad = self:checkEligibility(op) end
    if bad == nil then
        if spec.epochs ~= nil then
            op.epochs = spec.epochs        -- inherited (a putdown keeps its pickup's capture)
        else
            bad = self:captureEpochs(op)
        end
    end
    if bad == nil then bad = self:runValidateHook(op, "begin") end
    -- After the job, duty and the owner's own checks: those say more than a body on the spot.
    if bad == nil then bad = self:checkSpot(op) end
    if bad ~= nil then return refusal(bad, "validate") end

    -- Claims: the target (or the explicit key) first, then any extras. One
    -- winner; a loser is refused and holds nothing.
    local wanted = {}
    if spec.claimKey then
        wanted[#wanted + 1] = spec.claimKey
    elseif op.target ~= nil and action.claim then
        wanted[#wanted + 1] = "target:" .. op.target.key
    end
    for _, extra in ipairs(spec.extraClaims or {}) do wanted[#wanted + 1] = extra end
    for _, claimKey in ipairs(wanted) do
        local token, claimWhy, holder = self.claims:acquire(op.bucket, claimKey, op.opId, action.claimTtlMs, op.owner)
        if token == nil then
            self.claims:releaseHolder(op.opId)
            local reason = claimWhy
            if claimKey:sub(1, 5) == "dest:" and claimWhy == "target_claimed" then reason = "destination_claimed" end
            return refusal(reason, "reserve", nil, holder)
        end
        op.claimTokens[#op.claimTokens + 1] = token
    end

    self.ops[op.opId] = op
    self.active[pid] = op
    self:transition(op, "validating", nil, "validate")

    if action.hooks.reserve ~= nil then
        self:transition(op, "reserving", nil, "reserve")
        op.reserveDeadline = self.P.now() + action.reserveTimeoutMs
        op.reserveInFlight = true
        local ctx = self:context(op, "reserve")
        self.P.spawn(function() self:runReserve(op, ctx) end)
        return op
    end
    self:present(op)
    if M.TERMINAL[op.state] then return refusal(op.reason, op.stage, op) end
    return op
end

function Engine:runReserve(op, ctx)
    local result, why = self:hookAsync(op, "reserve", ctx)
    op.reserveInFlight = false
    if op.state ~= "reserving" then
        -- Cancelled (or timed out) while the reservation was in flight. Whatever
        -- the hook reserved is released through the cancel hook now; the
        -- operation itself is already terminal and a replacement may be running.
        if op.cancelHookPending then
            local reason = op.cancelHookPending
            op.cancelHookPending = nil
            if result then op.reservation = M.copyData(result, 2048) end
            self:fireCancelHook(op, reason)
        end
        return
    end
    if not result then
        self:finish(op, "failed", M.token(why, "refused_by_owner"), "reserve")
        return
    end
    op.reservation = M.copyData(result, 2048)
    self:present(op)
end

-- ---------------------------------------------------------------------------
-- Presentation
-- ---------------------------------------------------------------------------
function Engine:playAnimation(op)
    if op.animate then return op.animate(op, self) end
    local an = op.action.animation
    if an == nil then return true end
    local options = { loop = an.loop }
    if an.clip then options.clip = an.clip end
    if not an.loop then options.durationMs = op.action.durationMs end
    if an.at == "target" and op.target ~= nil then
        local yaw = an.yaw or op.target.yaw or 0.0
        yaw = M.yaw(yaw + (an.yawOffset or 0))
        local arrival = an.arrivalRadius or op.target.arrivalRadius
        if arrival then options.arrivalRadius = arrival end
        op.placed = true
        return self.P.animPlayAt(op.playerId, an.profile, op.target.position, yaw, options)
    end
    return self.P.animPlay(op.playerId, an.profile, options)
end

function Engine:present(op)
    local action = op.action
    local now = self.P.now()
    op.startedAt = now
    op.completeAt = now + action.durationMs
    op.commitAt = now + action.commitAtMs
    op.moveCheck = action.cancelOn.moved and action.moveTolerance > 0 and action.animation == nil and
        op.kind == "action"

    local state, why = self:playAnimation(op)
    if state == nil or state == false then
        local required = op.animate ~= nil or (action.animation and action.animation.required)
        if required then
            self:finish(op, "failed", "animation_refused", "present", "detail=" .. tostring(why))
            return
        end
        self.P.log("warn", ("[actions] op=%s animation refused (%s), continuing without it"):format(
            op.opId, tostring(why)))
    elseif type(state) == "table" and state.playbackId ~= nil then
        op.playbackId = state.playbackId
        self.byPlayback[op.playbackId] = op
    end

    op.clientShown = true
    self.P.toClient(op.playerId, "open77:actions:present", {
        opId = op.opId, generation = self.P.generation, action = op.actionKey,
        label = action.label, durationMs = action.durationMs,
        progress = action.progress or false, claims = action.claims,
    })
    self:transition(op, "presenting", nil, "present")
    if self.ext and self.ext.onPresent then self.ext:onPresent(op) end
end

function Engine:stopAnimation(op)
    local playback = op.playbackId
    if playback == nil or op.animationHandedOff or op.animationEnded then return end
    self.byPlayback[playback] = nil
    local ok, why = self.P.animStop(op.playerId, playback, op.placed)
    if not ok and why ~= "stale_playback" then
        self.P.log("warn", ("[actions] op=%s animation stop answered %s"):format(op.opId, tostring(why)))
    end
end

function Engine:endPresentation(op, reason)
    if op.presentationEnded then return end
    op.presentationEnded = true
    op.trailing = false
    self:stopAnimation(op)
    if op.clientShown then
        self.P.toClient(op.playerId, "open77:actions:end", {
            opId = op.opId, generation = self.P.generation, state = op.state, reason = reason or op.reason,
            message = M.messageFor(op.action, reason or op.reason),
        })
    end
    if self.active[op.playerId] == op then self.active[op.playerId] = nil end
end

-- Terminal bookkeeping shared by every end. Claims go back unless the carry
-- helper took them over; the presentation ends unless a committed operation
-- still has frames to play (`trailing`).
function Engine:finish(op, state, reason, stage, extra)
    if M.TERMINAL[op.state] then return false end
    op.terminalAt = self.P.now()
    if not op.keepClaims or state ~= "committed" then
        self.claims:releaseHolder(op.opId)
        op.claimTokens = {}
    end
    local trailing = state == "committed" and op.completeAt ~= nil and self.P.now() < op.completeAt and
        not op.endOnCommit
    self:transition(op, state, reason, stage, extra)
    if state == "committed" then
        local cooldown = op.action.cooldownMs or 0
        if cooldown > 0 then self.cooldowns[op.playerId .. "|" .. op.actionKey] = self.P.now() + cooldown end
    end
    if state ~= "committed" then self:fireCancelHook(op, reason) end
    if self.ext and self.ext.onTerminal then self.ext:onTerminal(op) end
    if trailing then
        op.trailing = true
    else
        self:endPresentation(op, reason)
    end
    self:retain(op)
    return true
end

-- ---------------------------------------------------------------------------
-- Cancellation
-- ---------------------------------------------------------------------------
function Engine:cancel(op, reason, stage)
    if op == nil then return nil, "unknown_operation" end
    if op.trailing then
        -- Business is final; only the frames are cut short.
        self:endPresentation(op, reason)
        return nil, "already_terminal"
    end
    if M.TERMINAL[op.state] then return nil, "already_terminal" end
    if op.state == "committing" then
        op.cancelRequested = reason
        return nil, "commit_in_flight"
    end
    self:finish(op, "cancelled", reason or "cancelled", stage or "cancel")
    return true
end

-- `flag` names the `cancelOn` switch an event depends on (`vehicle`,
-- `weaponDrawn`); nil means the event always cancels (death, disconnect...).
function Engine:cancelPlayer(pid, reason, flag)
    local op = self.active[pid]
    if op ~= nil and (flag == nil or op.action.cancelOn[flag]) then self:cancel(op, reason, "cancel") end
    if self.ext and self.ext.cancelPlayer then self.ext:cancelPlayer(pid, reason, flag) end
end

function Engine:ownerGone(owner)
    for _, op in pairs(self.ops) do
        if op.owner == owner and (not M.TERMINAL[op.state] or op.trailing) then
            self:cancel(op, "owner_stopped", "cancel")
        end
    end
    if self.ext and self.ext.ownerGone then self.ext:ownerGone(owner) end
    self:undefine(owner)
    self:removeTargets(owner)
    self.claims:releaseOwner(owner)
    self.owners[owner] = nil
    self.ownerCounts[owner] = nil
end

function Engine:shutdown()
    for _, op in pairs(self.ops) do
        if not M.TERMINAL[op.state] or op.trailing then self:cancel(op, "resource_stopping", "cancel") end
    end
    if self.ext and self.ext.shutdown then self.ext:shutdown() end
end

-- ---------------------------------------------------------------------------
-- Completion and commit
-- ---------------------------------------------------------------------------
function Engine:complete(op)
    op.state = "completing"
    op.stage = "complete"
    local read, why = self:readActor(op.playerId)
    local bad = read == nil and (why == "player_unavailable" and "disconnected" or why) or
        self:checkActor(op, read, "complete")
    if bad == nil then
        for _, token in ipairs(op.claimTokens) do
            if self.claims:get(token) == nil then bad = "claim_lost" end
        end
    end
    if bad == nil and self.ext and self.ext.checkComplete then bad = self.ext:checkComplete(op, read) end
    if bad == nil then bad = self:checkEligibility(op) end
    if bad == nil then bad = self:checkEpochs(op) end
    if bad == nil then bad = self:runValidateHook(op, "complete") end
    if bad ~= nil then
        op.state = "presenting"   -- so finish() treats it as a live cancellation
        self:finish(op, "cancelled", bad, "complete")
        return
    end
    self:transition(op, "committing", nil, "commit")
    local ctx = self:context(op, "commit")
    self.P.spawn(function() self:runCommit(op, ctx) end)
end

function Engine:runCommit(op, ctx)
    local attempt = 0
    local result, why, previous
    while true do
        if op.action.hooks.commit == nil then
            result, why = { opId = op.opId, local_ = true }, nil
        else
            result, why = self:hookAsync(op, "commit", ctx)
        end
        if result then break end
        why = M.token(why, "refused_by_owner")
        -- A retry that meets the fence the coordinator left after a transient refusal answers
        -- `aborted`: nothing was committed, and the first reason says why to the player.
        if why == "aborted" and TRANSIENT_REFUSAL[previous] then why = previous; break end
        previous = why
        if not (RETRYABLE_COMMIT[why] or TRANSIENT_REFUSAL[why]) or attempt >= op.action.commitRetries then break end
        attempt = attempt + 1
        -- Same opId, same context: the coordinator replays a committed
        -- operation, so a retry can never apply twice.
        self.P.sleep(500 * (2 ^ (attempt - 1)))
    end
    if op.state ~= "committing" then return end      -- resource stopping tore it down
    if result then
        op.receipt = type(result) == "table" and M.copyData(result, 2048) or { ok = true }
        op.state = "presenting"                       -- let finish() run the full path
        -- A cancellation that arrived while the commit was in flight does not
        -- undo it: the commit's answer decides, and the log says both.
        self:finish(op, "committed", "ok", "commit",
            op.cancelRequested and ("cancel_requested=" .. op.cancelRequested) or nil)
        return
    end
    op.state = "presenting"
    if RETRYABLE_COMMIT[why] then
        -- Out of retries with the outcome unknown. The holds stay with the
        -- coordinator; the author settles with its `status`. Never "failed":
        -- the commit may have happened.
        self:finish(op, "in_doubt", "in_doubt", "commit", "detail=" .. why)
    else
        self:finish(op, "failed", why, "commit")
    end
end

-- ---------------------------------------------------------------------------
-- The sweep
-- ---------------------------------------------------------------------------
function Engine:watchdog(op, read)
    if read == nil then return self.P.connected(op.playerId) and nil or "disconnected" end
    local action = op.action
    if read.alive == false or read.dead == true then return "dead" end
    if read.bucket ~= nil and read.bucket ~= op.bucket then return "bucket_changed" end
    if action.cancelOn.vehicle and read.inVehicle == true then return "vehicle" end
    local flags = read.flags
    if action.cancelOn.combat and type(flags) == "table" and flags.combatValid ~= false and
        (flags.aiming == true or flags.triggerDown == true) then
        return "combat"
    end
    if op.moveCheck and op.origin and type(read.position) == "table" then
        local d = M.distance(read.position, op.origin)
        if d ~= nil and d > action.moveTolerance then return "moved" end
    end
    return nil
end

function Engine:fireMarkers(op, elapsed)
    for _, marker in ipairs(op.action.markers) do
        if not op.markersFired[marker.name] and marker.atMs <= elapsed then
            op.markersFired[marker.name] = true
            if self.ext and self.ext.onMarker then self.ext:onMarker(op, marker.name) end
            if M.TERMINAL[op.state] then return end
            if op.action.hooks.marker ~= nil then
                self:hookSync(op, "marker", self:context(op, "marker", { marker = marker.name }))
            end
            self.P.hostEvent("open77_actions:marker", { opId = op.opId, marker = marker.name,
                owner = op.owner, playerId = op.playerId, playbackId = op.playbackId,
                generation = self.P.generation })
        end
    end
end

function Engine:tick()
    local now = self.P.now()
    for _, lapsed in ipairs(self.claims:sweep()) do
        local op = self.ops[lapsed.holder]
        if op ~= nil and not M.TERMINAL[op.state] then self:cancel(op, "claim_lost", "cancel") end
        if self.ext and self.ext.onClaimLapsed then self.ext:onClaimLapsed(lapsed) end
    end
    for owner, generation in pairs(self.owners) do
        if self.P.ownerGeneration(owner) ~= generation then self:ownerGone(owner) end
    end
    local live = {}
    for pid, op in pairs(self.active) do live[#live + 1] = op end
    for _, op in ipairs(live) do
        if op.state == "reserving" then
            if op.reserveDeadline and now > op.reserveDeadline then self:cancel(op, "reserve_timeout", "reserve") end
        elseif op.state == "presenting" or op.trailing then
            local read = self.P.readPlayer(op.playerId)
            local bad = self:watchdog(op, read)
            if bad ~= nil then
                self:cancel(op, bad, "present")
            elseif op.trailing then
                if now >= op.completeAt then self:endPresentation(op, "completed") end
            else
                self:fireMarkers(op, now - op.startedAt)
                if op.state == "presenting" and now >= op.commitAt then self:complete(op) end
            end
        end
    end
    if self.ext and self.ext.tick then self.ext:tick(now) end
end

-- ---------------------------------------------------------------------------
-- Platform events
-- ---------------------------------------------------------------------------
function Engine:onAnimation(pid, state)
    if type(state) ~= "table" or state.playbackId == nil then return end
    local op = self.byPlayback[state.playbackId]
    if op == nil then
        if self.ext and self.ext.onAnimation then self.ext:onAnimation(pid, state) end
        return
    end
    if state.active ~= false then return end
    -- A notice for a playback that is not this operation's current one is a
    -- stale notice: dropped.
    if op.playbackId ~= state.playbackId or op.playerId ~= pid then return end
    if op.animationHandedOff then return end
    local reason = tostring(state.reason or "")
    if reason == "completed" then
        op.animationCompleted = true
        return
    end
    self.byPlayback[state.playbackId] = nil
    op.animationEnded = true         -- already ended on the platform; nothing to stop
    if op.trailing then
        self:endPresentation(op, "animation_" .. reason)
        return
    end
    if M.TERMINAL[op.state] then return end
    local mapped = ANIMATION_END_REASON[reason] or "animation_interrupted"
    -- A connected player's body made briefly unavailable by a server move (teleport) is not a
    -- disconnect; name it for what ends the action.
    if mapped == "disconnected" and self.P.connected(op.playerId) then mapped = "moved" end
    self:cancel(op, mapped, "present")
end

function Engine:clientCancel(pid, opId)
    local op = self.active[pid]
    if op == nil or op.opId ~= opId then
        if self.ext and self.ext.clientCancel and self.ext:clientCancel(pid, opId) then return true end
        return nil, "unknown_operation"
    end
    if op.action.progress and op.action.progress.cancellable == false and not op.trailing then
        return nil, "invalid_options"
    end
    return self:cancel(op, "cancelled_by_player", "cancel")
end

return Engine
