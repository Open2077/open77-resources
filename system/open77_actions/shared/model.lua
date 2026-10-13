-- =============================================================================
-- open77_actions -- shared/model.lua
-- =============================================================================
-- Pure helpers shared by both halves: names, vectors, the operation states,
-- the reason vocabulary and the normalisers for action, target and carry-kind
-- definitions. No platform call lives here, so the offline suites load this
-- file as-is.
--
-- Global: Open77ActionsModel.
-- =============================================================================

local M = {}
Open77ActionsModel = M

M.VERSION = "0.1.0"

-- ---------------------------------------------------------------------------
-- States
-- ---------------------------------------------------------------------------
-- An operation moves forward only. `committing` is the one state a
-- cancellation cannot interrupt: the commit hook is in flight, so its answer
-- decides. Terminal states never change again; a late callback that finds its
-- operation terminal is dropped.
M.STATES = {
    "validating", "reserving", "presenting", "completing", "committing",
    "committed", "cancelled", "failed", "in_doubt",
}

M.TERMINAL = { committed = true, cancelled = true, failed = true, in_doubt = true }

-- The stage a refusal or failure happened in; returned beside every reason.
M.STAGES = { "request", "validate", "reserve", "present", "complete", "commit", "cancel", "carry" }

-- ---------------------------------------------------------------------------
-- Reason vocabulary
-- ---------------------------------------------------------------------------
-- Every token the library itself produces. A hook may return its own token
-- (for example the coordinator's `capacity_exceeded`); it is passed through
-- verbatim when it is a well-formed token, never rewritten. The C# suite checks
-- that each token below is produced by the server half and exercised by a test.
M.REASONS = {
    -- request shape
    "invalid_player", "invalid_action", "unknown_action", "invalid_target", "unknown_target",
    "invalid_options", "invalid_definition", "owner_unavailable", "not_owner",
    -- actor state, re-derived on the server
    "player_unavailable", "player_not_ready", "player_not_alive", "player_in_vehicle",
    "position_unavailable", "position_stale", "wrong_bucket", "too_far", "in_combat",
    "actor_busy", "carrying", "not_carrying", "weapon_drawn",
    -- shared targets
    "target_claimed", "claim_lost", "item_unavailable", "destination_invalid",
    "destination_too_far", "destination_claimed", "vehicle_unavailable",
    -- hooks, eligibility providers and epoch guards
    "refused_by_owner", "hook_failed", "not_eligible", "stale_job_epoch",
    -- presentation
    "animation_refused", "attach_failed",
    -- cancellation
    "cancelled", "cancelled_by_player", "disconnected", "dead", "bucket_changed",
    "vehicle", "combat", "moved", "superseded", "owner_stopped", "resource_stopping",
    "animation_interrupted", "reserve_timeout",
    -- outcome
    "in_doubt", "unknown_operation", "already_terminal", "commit_in_flight",
}

local reasonSet = {}
for _, reason in ipairs(M.REASONS) do reasonSet[reason] = true end
function M.isReason(value) return reasonSet[value] == true end

-- A hook's own reason is kept when it looks like a token; anything else
-- (prose, a table, a number) collapses to the fallback so a log line and an
-- event payload never carry unbounded text.
function M.token(value, fallback)
    if type(value) == "string" and #value >= 1 and #value <= 64 and value:match("^[%w_:%.%-]+$") then
        return value
    end
    return fallback
end

-- ---------------------------------------------------------------------------
-- Small values
-- ---------------------------------------------------------------------------
function M.validName(value, maximum)
    return type(value) == "string" and #value > 0 and #value <= (maximum or 64) and
        value:match("^[%w_:%.%-]+$") ~= nil
end

-- A local id: no colon, so `owner:id` is unambiguous.
function M.validId(value, maximum)
    return type(value) == "string" and #value > 0 and #value <= (maximum or 48) and
        value:match("^[%w_%.%-]+$") ~= nil
end

-- Default prompt keys of a target's choices, in order (an action may still set its own key).
M.CHOICE_KEYS = { "E", "F", "R", "Y" }

function M.playerId(value)
    local n = tonumber(value)
    if n == nil or n ~= n or n % 1 ~= 0 or n < 1 or n > 2147483647 then return nil end
    return math.tointeger(n)
end

-- Engine entity ids (vehicles, props) are 64-bit handles, not player ids: a live vehicle read
-- 4294967297 on 2026-10-12, past the int32 range M.playerId enforces, so every carry put-down into
-- a truck was refused `destination_invalid`. A double keeps integers exact up to 2^53.
function M.entityId(value)
    local n = tonumber(value)
    if n == nil or n ~= n or n % 1 ~= 0 or n < 1 or n > 9007199254740991 then return nil end
    return math.tointeger(n)
end

function M.integer(value, minimum, maximum, default)
    if value == nil then return default end
    local n = tonumber(value)
    if n == nil or n ~= n or n % 1 ~= 0 then return nil end
    n = math.tointeger(n)
    if n < minimum or n > maximum then return nil end
    return n
end

function M.number(value, minimum, maximum, default)
    if value == nil then return default end
    local n = tonumber(value)
    if n == nil or n ~= n or n == math.huge or n == -math.huge then return nil end
    if n < minimum or n > maximum then return nil end
    return n
end

function M.vector(value)
    if type(value) ~= "table" then return nil end
    local x = tonumber(value.x or value[1])
    local y = tonumber(value.y or value[2])
    local z = tonumber(value.z or value[3])
    if not x or not y or not z then return nil end
    for _, c in ipairs({ x, y, z }) do
        if c ~= c or c == math.huge or c == -math.huge or c > 1e7 or c < -1e7 then return nil end
    end
    return { x = x, y = y, z = z }
end

function M.distance(a, b)
    if not a or not b then return nil end
    local dx, dy, dz = a.x - b.x, a.y - b.y, a.z - b.z
    return math.sqrt(dx * dx + dy * dy + dz * dz)
end

function M.yaw(value)
    local n = tonumber(value) or 0.0
    if n ~= n or n == math.huge or n == -math.huge then return 0.0 end
    n = n % 360.0
    if n > 180.0 then n = n - 360.0 end
    return n
end

-- REDengine convention used by `Open77.props.create` and `playAt`: yaw in
-- degrees about +Z, 0 faces +Y. Forward is therefore (-sin, cos); the A0
-- probe logs this inference beside every computed point.
function M.forward(yaw)
    local r = math.rad(tonumber(yaw) or 0.0)
    return -math.sin(r), math.cos(r)
end

function M.offsetPoint(origin, yaw, ahead, up)
    local fx, fy = M.forward(yaw)
    return { x = origin.x + fx * (ahead or 0), y = origin.y + fy * (ahead or 0), z = origin.z + (up or 0) }
end

local digits = "0123456789abcdefghijklmnopqrstuvwxyz"
function M.base36(n)
    n = math.floor(math.abs(tonumber(n) or 0))
    if n == 0 then return "0" end
    local out = {}
    while n > 0 do
        local d = n % 36
        out[#out + 1] = digits:sub(d + 1, d + 1)
        n = n // 36
    end
    return string.reverse(table.concat(out))
end

-- Bounded copy of plain data (strings, numbers, booleans, nested tables with
-- string or integer keys). Returns nil when the value exceeds the budget, so a
-- caller never ships an unbounded table to a client or into an event.
function M.copyData(value, budget)
    budget = budget or 4096
    local remaining = budget
    local function copy(v, depth)
        local kind = type(v)
        if kind == "string" then
            remaining = remaining - #v - 2
            return remaining >= 0 and v or nil, remaining >= 0
        elseif kind == "number" then
            if v ~= v or v == math.huge or v == -math.huge then return nil, false end
            remaining = remaining - 8
            return v, remaining >= 0
        elseif kind == "boolean" then
            remaining = remaining - 4
            return v, remaining >= 0
        elseif kind == "table" then
            if depth > 6 then return nil, false end
            local out = {}
            for key, item in pairs(v) do
                local kk = type(key)
                if kk ~= "string" and not (kk == "number" and math.tointeger(key)) then return nil, false end
                remaining = remaining - (kk == "string" and #key or 8)
                local c, ok = copy(item, depth + 1)
                if not ok then return nil, false end
                out[key] = c
            end
            return out, remaining >= 0
        elseif kind == "nil" then
            return nil, true
        end
        return nil, false
    end
    local result, ok = copy(value, 0)
    if not ok then return nil end
    return result
end

-- ---------------------------------------------------------------------------
-- Action definitions
-- ---------------------------------------------------------------------------
local HOOKS = { "validate", "reserve", "commit", "cancel", "marker" }
M.HOOKS = HOOKS

local function normalizeHooks(hooks, allowFunctions)
    if hooks == nil then return {} end
    if type(hooks) ~= "table" then return nil end
    local out = {}
    for name, value in pairs(hooks) do
        local known = false
        for _, hook in ipairs(HOOKS) do if hook == name then known = true end end
        if not known then return nil end
        if type(value) == "function" and allowFunctions then
            out[name] = value
        elseif M.validName(value, 64) then
            out[name] = value
        else
            return nil
        end
    end
    return out
end

local function normalizeClaims(value, default)
    -- Client-side control claims for the duration of the presentation.
    -- `move`: block Movement; `attack`: block Attack and Melee; `jump`: block jumping;
    -- `sprint`: block Sprint (walk mode alone lets the player sprint out of its pace);
    -- `walkSpeed`: hold the walk-mode lease at that speed (m/s).
    if value == false then return {} end
    value = value or default or {}
    if type(value) ~= "table" then return nil end
    local out = {}
    if value.move ~= nil then out.move = value.move == true end
    if value.attack ~= nil then out.attack = value.attack == true end
    if value.jump ~= nil then out.jump = value.jump == true end
    if value.sprint ~= nil then out.sprint = value.sprint == true end
    if value.walkSpeed ~= nil then
        out.walkSpeed = M.number(value.walkSpeed, 0.5, 2.5, nil)
        if out.walkSpeed == nil then return nil end
    end
    return out
end
M.normalizeClaims = normalizeClaims

--- Normalises an action definition. `internal` allows Lua functions as hooks
--- (only the library's own built-ins and lab actions; an export boundary
--- never carries a function).
function M.normalizeAction(def, internal)
    if type(def) ~= "table" then return nil, "invalid_definition" end
    if not M.validId(def.id, 48) then return nil, "invalid_definition" end
    local a = { id = def.id }
    a.label = type(def.label) == "string" and def.label:sub(1, 96) or def.id
    a.durationMs = M.integer(def.durationMs, 250, 600000, nil)
    if a.durationMs == nil then return nil, "invalid_definition" end
    a.commitAtMs = M.integer(def.commitAtMs, 0, a.durationMs, a.durationMs)
    if a.commitAtMs == nil then return nil, "invalid_definition" end
    a.maxDistance = M.number(def.maxDistance, 0.5, 25.0, 2.5)
    a.completeSlack = M.number(def.completeSlack, 0.0, 5.0, 0.75)
    a.maxPositionAgeMs = M.integer(def.maxPositionAgeMs, 100, 10000, 2000)
    a.moveTolerance = M.number(def.moveTolerance, 0.0, 25.0, 1.0)
    a.reserveTimeoutMs = M.integer(def.reserveTimeoutMs, 1000, 60000, 20000)
    a.cooldownMs = M.integer(def.cooldownMs, 0, 3600000, 0)
    a.commitRetries = M.integer(def.commitRetries, 0, 5, 2)
    if a.maxDistance == nil or a.completeSlack == nil or a.maxPositionAgeMs == nil or
        a.moveTolerance == nil or a.reserveTimeoutMs == nil or a.cooldownMs == nil or
        a.commitRetries == nil then
        return nil, "invalid_definition"
    end
    a.claim = def.claim ~= false        -- claim the target exclusively (default)
    a.claimTtlMs = M.integer(def.claimTtlMs, 1000, 3600000, a.durationMs + 30000)
    if a.claimTtlMs == nil then return nil, "invalid_definition" end
    a.supersede = def.supersede == true
    a.requiresTarget = def.requiresTarget ~= false
    a.whileCarrying = def.whileCarrying == true

    local cancelOn = def.cancelOn
    if cancelOn ~= nil and type(cancelOn) ~= "table" then return nil, "invalid_definition" end
    cancelOn = cancelOn or {}
    a.cancelOn = {
        combat = cancelOn.combat ~= false,           -- aiming / trigger down in the snapshot
        weaponDrawn = cancelOn.weaponDrawn == true,   -- onPlayerWeaponChanged drawn=true
        vehicle = cancelOn.vehicle ~= false,
        moved = cancelOn.moved ~= false,
    }

    if def.animation ~= nil and def.animation ~= false then
        local an = def.animation
        if type(an) ~= "table" or not M.validName(an.profile, 96) then return nil, "invalid_definition" end
        a.animation = {
            profile = an.profile,
            clip = M.validName(an.clip, 160) and an.clip or nil,
            at = an.at == "target" and "target" or "self",
            yaw = an.yaw ~= nil and M.yaw(an.yaw) or nil,
            yawOffset = M.number(an.yawOffset, -360, 360, 0),
            loop = an.loop ~= false,
            required = an.required ~= false,
            -- `playAt` plays in place when the actor already stands within this
            -- many metres of the target (0.5-1.5, server default 0.5). Raise it for
            -- spots whose geometry pushes a relocated body back (a market grill
            -- behind its counter, 2026-10-12: interrupted player_moving).
            arrivalRadius = an.arrivalRadius ~= nil and M.number(an.arrivalRadius, 0.5, 1.5, nil) or nil,
        }
        if a.animation.yawOffset == nil then return nil, "invalid_definition" end
        if an.arrivalRadius ~= nil and a.animation.arrivalRadius == nil then return nil, "invalid_definition" end
    end

    if def.progress == false then
        a.progress = false
    else
        local pr = def.progress or {}
        if type(pr) ~= "table" then return nil, "invalid_definition" end
        a.progress = {
            label = type(pr.label) == "string" and pr.label:sub(1, 96) or a.label,
            position = (pr.position == "top" or pr.position == "center") and pr.position or "bottom",
            style = pr.style == "circle" and "circle" or "bar",
            color = type(pr.color) == "string" and pr.color:match("^#%x%x%x%x%x%x$") and pr.color or nil,
            cancellable = pr.cancellable ~= false,
        }
    end

    a.claims = normalizeClaims(def.claims, { move = true, attack = true })
    if a.claims == nil then return nil, "invalid_definition" end

    a.markers = {}
    if def.markers ~= nil then
        if type(def.markers) ~= "table" or #def.markers > 8 then return nil, "invalid_definition" end
        for _, marker in ipairs(def.markers) do
            if type(marker) ~= "table" or not M.validId(marker.name, 32) then return nil, "invalid_definition" end
            local at = M.integer(marker.atMs, 0, a.durationMs, nil)
            if at == nil then return nil, "invalid_definition" end
            a.markers[#a.markers + 1] = { name = marker.name, atMs = at }
        end
        table.sort(a.markers, function(l, r) return l.atMs < r.atMs end)
    end

    a.hooks = normalizeHooks(def.hooks, internal)
    if a.hooks == nil then return nil, "invalid_definition" end
    a.eligibility = M.normalizeEligibility(def.eligibility)
    a.epochs = M.normalizeEpochs(def.epochs or def.epoch)
    if a.eligibility == nil or a.epochs == nil then return nil, "invalid_definition" end
    a.data = M.copyData(def.data, 1024)
    -- What the player reads when this action is refused or stops: a reason token -> plain text shown
    -- instead of the library's default, or false to show nothing (the owner tells the player itself).
    if def.messages ~= nil then
        if type(def.messages) ~= "table" then return nil, "invalid_definition" end
        local messages, n = {}, 0
        for reason, text in pairs(def.messages) do
            n = n + 1
            if n > 96 or M.token(reason, nil) == nil then return nil, "invalid_definition" end
            if text == false then
                messages[reason] = false
            elseif type(text) == "string" and #text >= 1 and #text <= 200 and not text:find("%c") then
                messages[reason] = text
            else
                return nil, "invalid_definition"
            end
        end
        a.messages = messages
    end
    return a
end

-- The action's own text for a reason: a string, false (show nothing) or nil (the default text).
function M.messageFor(action, reason)
    if type(action) ~= "table" or type(action.messages) ~= "table" then return nil end
    return action.messages[reason]
end

-- ---------------------------------------------------------------------------
-- Pluggable eligibility and epoch guards (framework-neutral)
-- ---------------------------------------------------------------------------
-- An eligibility provider is any server export that answers synchronously
-- `ok | nil, reason` for `(playerId, args)` -- for example
-- `rp_jobs:eligible(playerId, { job, minGrade, duty })`. It is asked at begin
-- and again before the commit. The library knows nothing about jobs.
--
--   eligibility = { resource = "rp_jobs", export = "eligible", args = { job = "ferrailleur", duty = true } }
--   eligibility = { {...}, {...} }          -- several providers, all must agree
function M.normalizeEligibility(value)
    if value == nil then return {} end
    if type(value) ~= "table" then return nil end
    if value.resource ~= nil then value = { value } end
    if #value > 4 then return nil end
    local out = {}
    for _, e in ipairs(value) do
        if type(e) ~= "table" or not M.validName(e.resource, 64) or not M.validName(e.export, 64) then return nil end
        local args = e.args
        if args ~= nil then
            args = M.copyData(args, 512)
            if args == nil then return nil end
        end
        out[#out + 1] = { resource = e.resource, export = e.export, args = args }
    end
    return out
end

-- An epoch guard captures a per-player counter at begin and refuses the
-- commit when it moved (a job, grade or duty change in between). The counter
-- is read from an export (`read`, authoritative) and/or followed from a
-- host-wide event `(playerId, epoch, ...)` (`event`, which also cancels the
-- running operation at once). Default reason `stale_job_epoch`.
--
--   epochs = { resource = "rp_jobs", read = "workEpoch", event = "rp_jobs:workEpoch" }
function M.normalizeEpochs(value)
    if value == nil then return {} end
    if type(value) ~= "table" then return nil end
    if value.resource ~= nil or value.event ~= nil then value = { value } end
    if #value > 4 then return nil end
    local out = {}
    for _, g in ipairs(value) do
        if type(g) ~= "table" then return nil end
        local read = g.read
        if read ~= nil and (not M.validName(g.resource, 64) or not M.validName(read, 64)) then return nil end
        if g.event ~= nil and not M.validName(g.event, 96) then return nil end
        if read == nil and g.event == nil then return nil end
        out[#out + 1] = {
            resource = g.resource, read = read, event = g.event,
            reason = M.token(g.reason, "stale_job_epoch"),
        }
    end
    return out
end

-- ---------------------------------------------------------------------------
-- Targets (point targets presented through open77_interactions)
-- ---------------------------------------------------------------------------
-- The default lift of a target's prompt card above its point: the
-- open77_worldui default (`labelHeight` 1.0), the shape of the rp_ferrailleur
-- prompt that fired by key live on 2026-10-12.
M.PROMPT_HEIGHT = 1.0
-- An action that places its actor ON a target's stand point (animation `at = "target"`) is refused
-- while another player stands within this many metres of it (planar, and within SPOT_HEIGHT up or
-- down). Measured live 2026-10-13: a second operator placed on the CHOOH2 control while the first
-- still stood there landed on top of her (settled 0.95 m up) and fell when she left. 0.45 m is
-- inside a body's capsule; a neighbour half a metre off the point (a helper beside a bench) is not.
M.SPOT_RADIUS = 0.45
M.SPOT_HEIGHT = 2.0

function M.normalizeTarget(def)
    if type(def) ~= "table" then return nil, "invalid_target" end
    if not M.validId(def.id, 48) then return nil, "invalid_target" end
    local position = M.vector(def.position)
    if position == nil then return nil, "invalid_target" end
    local bucket = M.integer(def.bucket, 0, 2147483647, 0)
    if bucket == nil then return nil, "invalid_target" end
    local t = {
        id = def.id, position = position, bucket = bucket,
        yaw = def.yaw ~= nil and M.yaw(def.yaw) or nil,
        label = type(def.label) == "string" and def.label:sub(1, 96) or nil,
        description = type(def.description) == "string" and def.description:sub(1, 160) or nil,
        distance = M.number(def.distance, 0.5, 25.0, 2.0),
        markerDistance = M.number(def.markerDistance, 1.0, 120.0, 12.0),
        marker = M.validId(def.marker, 16) and def.marker or "dot",
        color = type(def.color) == "string" and def.color:match("^#%x%x%x%x%x%x$") and def.color or nil,
        icon = type(def.icon) == "string" and def.icon:sub(1, 12) or nil,
        requires = (def.requires == "carrying" or def.requires == "empty") and def.requires or nil,
        -- Prompt presentation (client only; the server's reach test is
        -- unchanged). `position` is where the actor stands -- `playAt` places
        -- the body there -- so it is usually a floor point. The card is drawn
        -- `promptHeight` metres above it, where a player walking up looks, and
        -- is live whenever the player is in reach and the card is on screen.
        -- `lookAt = true` also requires the crosshair on the card, for spots
        -- packed closer than their reach. See client/main.lua promptDefinition.
        promptHeight = M.number(def.promptHeight, 0.0, 3.0, M.PROMPT_HEIGHT),
        lookAt = def.lookAt == true,
        -- Where the card is drawn when it is not the stand point (then lifted `promptHeight` above
        -- it): a ripperdoc's station shows its card over the patient, in front of the ripperdoc,
        -- instead of at their own feet where it is off screen. At most 3 m from `position`.
        promptAt = def.promptAt ~= nil and M.vector(def.promptAt) or nil,
        -- Keep the crowd's pedestrians off this point for as long as the target exists (an
        -- open77_pedestrians hold, refreshed): a bench or a counter set on a game workspot then is
        -- not shared with an NPC. `true` = 0.8 m, or a radius 0.3-1.5 m.
        keepCrowdOff = def.keepCrowdOff == true and 0.8 or (type(def.keepCrowdOff) == "number" and
            M.number(def.keepCrowdOff, 0.3, 1.5, nil) or nil),
        -- Per-spot `playAt` arrival radius (0.5-1.5); an action's own wins.
        arrivalRadius = def.arrivalRadius ~= nil and M.number(def.arrivalRadius, 0.5, 1.5, nil) or nil,
        actions = {},
        data = M.copyData(def.data, 1024),
    }
    if t.distance == nil or t.markerDistance == nil or t.promptHeight == nil then return nil, "invalid_target" end
    if def.lookAt ~= nil and type(def.lookAt) ~= "boolean" then return nil, "invalid_target" end
    if def.keepCrowdOff ~= nil and def.keepCrowdOff ~= false and t.keepCrowdOff == nil then return nil, "invalid_target" end
    if def.promptAt ~= nil then
        local p = t.promptAt
        if p == nil then return nil, "invalid_target" end
        local dx, dy, dz = p.x - position.x, p.y - position.y, p.z - position.z
        if dx * dx + dy * dy + dz * dz > 9.0 then return nil, "invalid_target" end
    end
    if def.arrivalRadius ~= nil and t.arrivalRadius == nil then return nil, "invalid_target" end
    -- Players who are not shown the card (at most 8 ids). Presentation only: an intent from one of
    -- them is still judged by the action's own rules. A downed patient is not offered the medic's
    -- "Stabilise" card over their own body.
    if def.hideFor ~= nil then
        if type(def.hideFor) ~= "table" or #def.hideFor > 8 then return nil, "invalid_target" end
        t.hideFor = {}
        for _, id in ipairs(def.hideFor) do
            local pid = M.integer(id, 1, 9007199254740991, nil)
            if pid == nil then return nil, "invalid_target" end
            t.hideFor[#t.hideFor + 1] = pid
        end
    end
    local actions = def.actions
    if type(actions) == "string" then actions = { actions } end
    if type(actions) ~= "table" or #actions < 1 or #actions > 4 then return nil, "invalid_target" end
    -- G is the put-down key of the carry helper; prompts never default to it. T is the Open77
    -- chat key (live 2026-10-12: a fourth choice on T opened the chat instead), X cancels.
    local keys = M.CHOICE_KEYS
    for index, entry in ipairs(actions) do
        local spec = type(entry) == "string" and { action = entry } or entry
        if type(spec) ~= "table" or not M.validName(spec.action, 112) then return nil, "invalid_target" end
        local key = type(spec.key) == "string" and spec.key:upper():match("^[A-Z0-9]$") or keys[index]
        t.actions[#t.actions + 1] = {
            action = spec.action,
            label = type(spec.label) == "string" and spec.label:sub(1, 96) or nil,
            key = key,
            holdSeconds = M.number(spec.holdSeconds, 0, 10, nil),
            icon = type(spec.icon) == "string" and spec.icon:sub(1, 12) or nil,
        }
    end
    return t
end

-- ---------------------------------------------------------------------------
-- Carry kinds (A5)
-- ---------------------------------------------------------------------------
-- The default binding is the one measured on both clients with the `carry`
-- layer (integrator, 2026-10-12; wiki/rp-animations.md "Carrying a box"):
-- Chest slot, hands midpoint. It was tuned for `crate.small` (about 1.2 m
-- tall); a model listed in M.MODEL_BINDINGS gets its own, any other model
-- needs its own offsets.
--
-- First person: the Chest slot does not follow the view's pitch while V's
-- first-person hands do, so a crate placed ahead of the chest floated in the
-- middle of the screen as soon as the player looked down (owner's report,
-- 2026-10-13). Both placements below were measured in game with the camera
-- level and pitched 30 degrees down: the crate rests across the hands at the
-- bottom of the view when looking down, and only its top edge shows when
-- looking ahead, like a box held against the chest.
M.DEFAULT_BINDING = {
    bone = "Chest",
    offset = { x = -0.135, y = -0.60, z = 0.008 },
    rotation = { x = 0.0, y = 90.0, z = 0.0 },
    firstPerson = { offset = { x = 0.10, y = -0.40, z = -0.40 }, rotation = { x = 0.0, y = 90.0, z = 90.0 } },
}

-- Measured bindings per model, used when a carry kind gives none (or leaves a
-- field out). `crate.ammo_box` is the hand-scale box every RP job carries: it
-- sits on the forearms against the chest in third person (measured with
-- actions.lab.bind, 2026-10-12) and lies flat between the hands in first
-- person (2026-10-13).
M.MODEL_BINDINGS = {
    ["crate.small"] = M.DEFAULT_BINDING,
    ["crate.ammo_box"] = {
        bone = "Chest",
        offset = { x = -0.12, y = -0.42, z = -0.22 },
        rotation = { x = 0.0, y = 90.0, z = 0.0 },
        firstPerson = { offset = { x = 0.08, y = -0.32, z = -0.28 }, rotation = { x = 90.0, y = 0.0, z = 0.0 } },
    },
}

-- A carry kind's dropMessage: false (silence), a string (at most 200 characters) or nil.
function M.dropMessage(value)
    if value == false then return false end
    if type(value) == "string" then return value:sub(1, 200) end
    return nil
end

local CARRY_HOOKS = { validate = true, pickup = true, putdown = true, dropped = true, cancel = true }

local function normalizeBinding(value, model)
    local base = (model ~= nil and M.MODEL_BINDINGS[model]) or M.DEFAULT_BINDING
    if value == nil then return base end
    if type(value) ~= "table" then return nil end
    local bone = value.bone or base.bone
    if type(bone) ~= "string" or #bone > 64 or (bone ~= "" and not bone:match("^[%w_%-]+$")) then return nil end
    local offset = value.offset == nil and base.offset or M.vector(value.offset)
    local rotation = value.rotation == nil and base.rotation or M.vector(value.rotation)
    if offset == nil or rotation == nil then return nil end
    local firstPerson
    if value.firstPerson == "hide" then
        firstPerson = "hide"
    elseif value.firstPerson == false then
        firstPerson = nil
    elseif value.firstPerson == nil then
        firstPerson = base.firstPerson
    elseif type(value.firstPerson) == "table" then
        local fo, fr = M.vector(value.firstPerson.offset), M.vector(value.firstPerson.rotation or { 0, 0, 0 })
        if fo == nil or fr == nil then return nil end
        firstPerson = { offset = fo, rotation = fr }
    else
        return nil
    end
    return { bone = bone, offset = offset, rotation = rotation, firstPerson = firstPerson }
end
M.normalizeBinding = normalizeBinding

function M.normalizeCarryKind(def, internal)
    if type(def) ~= "table" or not M.validId(def.id, 48) then return nil, "invalid_definition" end
    if not M.validName(def.model, 128) then return nil, "invalid_definition" end
    local k = {
        id = def.id, model = def.model,
        label = type(def.label) == "string" and def.label:sub(1, 96) or def.id,
        reach = M.number(def.reach, 0.5, 5.0, 2.0),
        pickupProfile = M.validName(def.pickupProfile, 96) and def.pickupProfile or "carry_pickup",
        holdProfile = M.validName(def.holdProfile, 96) and def.holdProfile or "carry",
        putdownProfile = M.validName(def.putdownProfile, 96) and def.putdownProfile or "carry_putdown",
        -- Durations default to the measured `clipDurationsMs` of the carry
        -- family (1,333 / 2,333 ms); the runtime replaces them with the
        -- catalogue's own numbers when `Open77.animations.get` has them.
        pickupMs = M.integer(def.pickupMs, 250, 10000, nil),
        putdownMs = M.integer(def.putdownMs, 250, 10000, nil),
        -- Grip and release are presentation markers, configured separately
        -- from the clip length on purpose: duration is not a hand contact.
        gripMs = M.integer(def.gripMs, 0, 10000, nil),
        releaseMs = M.integer(def.releaseMs, 0, 10000, nil),
        vehicleReach = M.number(def.vehicleReach, 1.0, 8.0, 4.0),
        dropAhead = M.number(def.dropAhead, 0.0, 2.0, 0.7),
        -- The pickup card sits this far above the item's top (its position + 0.5 m). Measured live
        -- 2026-10-13: with the 1.0 m stand-point lift the card hung 1.5 m above a crate on the ground,
        -- at eye level, so whoever stood over the crate and looked down at it saw no card at all.
        promptHeight = M.number(def.promptHeight, 0.0, 2.0, 0.2),
        -- What the carrier reads when the item leaves their hands without a put-down (a punch, a
        -- vehicle, a teleport): nil = the library's words, a string = yours ("%s" is the label),
        -- false = nothing (the owning resource tells the player itself).
        dropMessage = M.dropMessage(def.dropMessage),
        -- `sprint`: measured 2026-10-12, Shift+forward while carrying covered 31 m in
        -- 4 s -- walk mode caps the pace, never the sprint.
        claims = normalizeClaims(def.claims, { walkSpeed = 1.2, jump = true, attack = true, sprint = true }),
        binding = normalizeBinding(def.binding, def.model),
        cancelOn = {
            combat = not (type(def.cancelOn) == "table" and def.cancelOn.combat == false),
            weaponDrawn = not (type(def.cancelOn) == "table" and def.cancelOn.weaponDrawn == false),
            vehicle = true,
        },
        hooks = {},
        eligibility = def.eligibility,
        epochs = def.epochs or def.epoch,
        -- The owner's words for a refused pickup or put-down (reason -> text, or false), the same
        -- table an action takes. Live 2026-10-13: a crate loaded into a truck the carrier held no
        -- key for was refused `no_access` at the commit, and the carrier read nothing at all.
        messages = def.messages,
        data = M.copyData(def.data, 1024),
    }
    if M.normalizeEligibility(k.eligibility) == nil or M.normalizeEpochs(k.epochs) == nil then
        return nil, "invalid_definition"
    end
    if k.reach == nil or k.vehicleReach == nil or k.dropAhead == nil or k.claims == nil or k.binding == nil
            or k.promptHeight == nil then
        return nil, "invalid_definition"
    end
    if def.hooks ~= nil then
        if type(def.hooks) ~= "table" then return nil, "invalid_definition" end
        for name, value in pairs(def.hooks) do
            if not CARRY_HOOKS[name] then return nil, "invalid_definition" end
            if type(value) == "function" and internal then
                k.hooks[name] = value
            elseif M.validName(value, 64) then
                k.hooks[name] = value
            else
                return nil, "invalid_definition"
            end
        end
    end
    return k
end

-- Placement a commit hook (or a destination) asks the carry helper to
-- project once custody has changed.
function M.normalizePlacement(value)
    if type(value) ~= "table" then return nil end
    local kind = value.kind
    if kind == "ground" then
        return { kind = "ground" }
    elseif kind == "point" then
        local p = M.vector(value.position)
        if p == nil then return nil end
        return { kind = "point", position = p, yaw = M.yaw(value.yaw) }
    elseif kind == "vehicle" then
        local id = M.entityId(value.vehicleId)
        if id == nil then return nil end
        local offset = value.offset == nil and { x = 0, y = 0, z = 1.0 } or M.vector(value.offset)
        local rotation = value.rotation == nil and { x = 0, y = 0, z = 0 } or M.vector(value.rotation)
        if offset == nil or rotation == nil then return nil end
        return { kind = "vehicle", vehicleId = id, offset = offset, rotation = rotation }
    elseif kind == "remove" then
        return { kind = "remove" }
    end
    return nil
end

return M
