-- =============================================================================
-- open77_seating -- shared/model.lua
-- =============================================================================
-- Pure helpers shared by both halves: the configuration defaults, the
-- approach geometry per furniture kind, prompt labels and the reason
-- vocabulary. No platform call lives here, so the offline suite loads this
-- file as-is.
--
-- Global: Open77SeatingModel. Contract: docs/world-interaction/b6-seating.md.
-- =============================================================================

local M = {}
Open77SeatingModel = M

M.VERSION = "0.1.0"

-- open77_furniture flag bits this resource reads (server/index.lua FLAGS).
M.FLAG_DEPENDENT = 32       -- a pose enabled only while its master spot is occupied
M.FLAG_WIDE = 2048          -- chained poses span more than 0.5 m (a bench row)

-- ---------------------------------------------------------------------------
-- Configuration (server; convars seed some of it, lab commands change it)
-- ---------------------------------------------------------------------------
M.DEFAULTS = {
    -- Prompts: at most `promptLimit` seats within `promptRadius` (3D) and
    -- `promptVertical` of the player, refreshed when the player has moved
    -- `promptMoveM` or every `promptRefreshMs`. Never every row within 40 m.
    promptRadius = 3.0,
    promptVertical = 1.5,
    promptLimit = 3,
    promptMoveM = 0.75,
    promptRefreshMs = 3000,
    promptPlayersPerTick = 16,
    -- A request (prompt, /sit) is honoured for a pose within `sitRange` on the
    -- ground and `sitVertical` in height of the player; lab commands reach
    -- `labReach` (playAt refuses past 5 m from the approach point).
    sitRange = 3.0,
    sitVertical = 1.5,
    labReach = 4.5,
    -- Two bodies closer than this on the ground overlap: the player-player
    -- separation between occupied poses and the radius of the pedestrian
    -- hold around a seat.
    separation = 0.6,
    -- Claims (open77_actions) and pedestrian holds are renewed well inside
    -- their time to live.
    claimTtlMs = 30000,
    renewEveryMs = 10000,
    -- The approach: the actor is placed on a clear point beside the furniture
    -- (never on it) before playAt carries the body onto the anchor, as every
    -- live measurement did (A3 `a3.go`). Skipped when the body already stands
    -- within `approachSkipM` of it; refused when the body lands farther than
    -- `approachToleranceM` from it (furniture or a wall pushed it).
    approachSkipM = 0.35,
    approachToleranceM = 0.75,
    approachTimeoutMs = 12000,
    -- The exit after standing up: "approach" puts the body back on the
    -- approach point when it ended farther than `exitToleranceM` from it,
    -- "check" only when the exit looks unsafe (fell, flung, on top), "none"
    -- never moves it.
    exitMode = "approach",
    exitSettleMs = 1500,
    exitToleranceM = 0.6,
    -- A body farther than this from the seat after an end did not stand up: a
    -- server teleport, a vehicle or a carry moved it (live 2026-10-12: a Warden
    -- teleport of a seated player ended as cancelled_by_player and the exit put
    -- it back beside the stool). The exit never pulls such a body back.
    exitLeftM = 4.0,
    maxPositionAgeMs = 1500,
    -- Which poses a player may take: verification states and postures. Lying
    -- is offered like sitting and leaning: only on poses whose verification is
    -- allowed (the measured bed resource by default, A1 id #9; other beds stay
    -- unverified until walked). The `open77_seating_postures` convar narrows it.
    verification = { measured = true },
    postures = { sit = true, lean = true, lie = true },
    -- Furniture flags never offered (a dependent pose needs its master
    -- occupied first).
    excludeFlags = 32,
    -- Client intents per player per second.
    intentWindowMs = 1000,
    intentBudget = 4,
    versionCheckMs = 10000,
}

function M.config(overrides)
    local out = {}
    for key, value in pairs(M.DEFAULTS) do
        if type(value) == "table" then
            local copy = {}
            for k, v in pairs(value) do copy[k] = v end
            out[key] = copy
        else
            out[key] = value
        end
    end
    for key, value in pairs(overrides or {}) do out[key] = value end
    return out
end

M.EXIT_MODES = { approach = true, check = true, none = true }

-- ---------------------------------------------------------------------------
-- Approach geometry
-- ---------------------------------------------------------------------------
-- Where the actor stands before the posture carries the body onto the
-- anchor, in the furniture's frame: `ahead` metres along the pose's facing
-- (negative = behind it) and `side` metres to its right. Inference from the
-- kinds, not a measurement except where noted:
--   behind 1.2 m  seats at a table or a counter (the table/counter is in
--                 front): the a3.go stand point every live seat used
--                 (chair, bench through chair poses, barstool, bar seat,
--                 interior chair; A3, A2 and the A1 ten ids);
--   front 1.0 m   the wall/backrest is behind (wall leans, couches,
--                 benches with their own family);
--   right 1.0 m   lying furniture other than beds (couches, benches);
--   player        no offset known: the actor's own position is the
--                 approach (rails: front and back leans share one kind).
M.APPROACH = {
    chair = { ahead = -1.2, side = 0 },
    chair_lean_back = { ahead = -1.2, side = 0 },
    chair_table = { ahead = -1.2, side = 0 },
    barstool = { ahead = -1.2, side = 0 },
    -- Live 2026-10-12 (bar seat #10): the point 1.2 m behind lands on the step of the bar wall
    -- (approach_blocked); playAt from where the player stands seats it (arrivalRadius 0.75).
    bar_seat = "player",
    stool = { ahead = -1.2, side = 0 },
    armchair = { ahead = 1.0, side = 0 },
    netrunner_chair = { ahead = -1.2, side = 0 },
    sit_other = { ahead = -1.2, side = 0 },
    lean_bar = { ahead = -1.0, side = 0 },
    lean_table = { ahead = -1.0, side = 0 },
    lean_wall = { ahead = 1.0, side = 0 },
    couch = { ahead = 1.0, side = 0 },
    bench = { ahead = 1.0, side = 0 },
    ledge = { ahead = -1.0, side = 0 },
    curb = { ahead = 1.0, side = 0 },
    stairs = { ahead = 1.0, side = 0 },
    table = { ahead = 1.0, side = 0 },
    bed_edge = { ahead = 1.0, side = 0 },
    -- Live 2026-10-12, A1 id #9: the point beside the bed was approach_blocked; lying from where the
    -- player stands works on both rigs (with the client's anchored settle window).
    bed = "player",
    couch_lie = { ahead = 0, side = 1.0 },
    bench_lie = { ahead = 0, side = 1.0 },
    lean_rail = "player",
}

-- Named overrides a lab command or an export may pass instead of the kind's.
M.APPROACH_NAMES = {
    back = { ahead = -1.2, side = 0 },
    front = { ahead = 1.0, side = 0 },
    left = { ahead = 0, side = -1.0 },
    right = { ahead = 0, side = 1.0 },
    player = "player",
    none = "none",
}

-- REDengine convention shared by playAt and Open77.props: yaw in degrees
-- about +Z, 0 faces +Y, so forward is (-sin, cos) and right is (cos, sin).
function M.forward(yaw)
    local r = math.rad(tonumber(yaw) or 0.0)
    return -math.sin(r), math.cos(r)
end

function M.right(yaw)
    local r = math.rad(tonumber(yaw) or 0.0)
    return math.cos(r), math.sin(r)
end

-- The approach point of `pose` ({ x, y, z, yaw }) for `kind`, or nil when the
-- actor's own position serves ("player") or none is wanted ("none"). `name`,
-- when given, overrides the kind's rule. The point is 5 cm above the anchor,
-- which sits on the floor under the furniture.
function M.approachPoint(kind, pose, name)
    local rule = name and M.APPROACH_NAMES[name] or M.APPROACH[kind] or M.APPROACH_NAMES.back
    if type(rule) ~= "table" then return nil, rule end
    local fx, fy = M.forward(pose.yaw)
    local rx, ry = M.right(pose.yaw)
    return { x = pose.x + fx * rule.ahead + rx * rule.side, y = pose.y + fy * rule.ahead + ry * rule.side,
        z = pose.z + 0.05 }, "offset"
end

-- ---------------------------------------------------------------------------
-- Small values
-- ---------------------------------------------------------------------------
function M.playerId(value)
    local n = tonumber(value)
    if n == nil or n ~= n or n % 1 ~= 0 or n < 1 or n > 2147483647 then return nil end
    return math.tointeger(n)
end

-- A furniture id is the decimal global node id (it exceeds 2^63: a string).
function M.furnitureId(value)
    if math.type(value) == "integer" and value > 0 then return tostring(value) end
    if type(value) == "string" and #value >= 1 and #value <= 20 and value:match("^%d+$") then return value end
    return nil
end

function M.ground(a, b)
    local dx, dy = a.x - b.x, a.y - b.y
    return math.sqrt(dx * dx + dy * dy)
end

function M.distance(a, b)
    local dx, dy, dz = a.x - b.x, a.y - b.y, a.z - b.z
    return math.sqrt(dx * dx + dy * dy + dz * dz)
end

function M.vector(value)
    if type(value) ~= "table" then return nil end
    local x, y, z = tonumber(value.x), tonumber(value.y), tonumber(value.z)
    if not x or not y or not z or x ~= x or y ~= y or z ~= z then return nil end
    return { x = x, y = y, z = z }
end

-- ---------------------------------------------------------------------------
-- Labels
-- ---------------------------------------------------------------------------
local NOUN = {
    chair = "chair", chair_lean_back = "chair", chair_table = "chair", barstool = "stool", bar_seat = "bar seat",
    stool = "stool", armchair = "armchair", netrunner_chair = "chair", couch = "couch", bench = "bench",
    ledge = "ledge", curb = "curb", stairs = "steps", table = "table", bed_edge = "bed", sit_other = "seat",
    bed = "bed", couch_lie = "couch", bench_lie = "bench", lean_wall = "wall", lean_rail = "rail",
    lean_bar = "counter", lean_table = "table",
}
local VERB = { sit = "Sit on the ", lean = "Lean on the ", lie = "Lie down on the " }

function M.label(kind, posture)
    return (VERB[posture] or "Use the ") .. (NOUN[kind] or "seat")
end

-- ---------------------------------------------------------------------------
-- Reasons (every one is produced by the server half and exercised by the suite)
-- ---------------------------------------------------------------------------
M.REASONS = {
    -- request shape and state
    "invalid_player", "invalid_furniture", "unknown_furniture", "unknown_spot", "furniture_unavailable",
    "indexing", "no_playable_pose", "already_seated", "not_seated", "actor_busy",
    -- actor state, re-derived on the server
    "player_unavailable", "player_not_ready", "player_not_alive", "player_in_vehicle", "position_unavailable",
    "position_stale", "in_combat", "too_far", "bucket_not_enabled",
    -- occupancy
    "seat_taken", "target_claimed", "claims_unavailable", "npc_occupied",
    -- approach and presentation
    "approach_failed", "approach_blocked", "approach_timeout", "animation_refused",
    -- ends of a seat
    "stood", "cancelled_by_player", "anchor_unreached", "moved", "dead", "disconnected", "bucket_changed",
    "vehicle", "combat", "claim_lost", "furniture_changed", "resource_stopping", "animation_interrupted",
}

local reasonSet = {}
for _, reason in ipairs(M.REASONS) do reasonSet[reason] = true end
function M.isReason(value) return reasonSet[value] == true end

-- Ends after which the body is put back on its approach point (when the
-- exit mode asks for it): the actor stood up, or the posture never reached
-- the anchor, or the seat was taken away from under a living actor.
M.EXIT_REASONS = {
    stood = true, cancelled_by_player = true, anchor_unreached = true, claim_lost = true,
    furniture_changed = true, approach_blocked = true,
}

return M
