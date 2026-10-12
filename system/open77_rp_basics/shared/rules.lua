-- =============================================================================
-- open77_rp_basics -- shared/rules.lua
-- =============================================================================
-- The decisions, with no platform calls in them.
--
-- Everything in this file is a pure function of its arguments: the verb
-- catalogue, the preconditions a verb must satisfy, the claim ledger, the
-- tether decision, and the enumeration of every way a hold can end. The server
-- half reads the world through `Open77.players.*` and then asks this module what
-- to do, which is what makes the rules testable without a game -- see
-- `tests/rules_test.lua` and `Open77.Server.Tests.Resources.RpBasicsRulesTests`.
--
-- Two conventions from the platform are kept exactly:
--   * a refusal is `false, reason` with a stable snake_case token;
--   * a capability that this engine cannot provide REFUSES by name rather than
--     succeeding quietly. `Open77.input.blockableActions()` set that precedent
--     and `carry` is this kit's instance of it.
-- =============================================================================

local Rules = {}

Rules.VERSION = "1.0.0"

-- ---------------------------------------------------------------------------
-- The verb catalogue
-- ---------------------------------------------------------------------------
-- `supported = false` is a first-class answer, not an omission. A server owner
-- porting a FiveM script calls `carry` and gets `carry_unsupported` with a
-- reason he can read, instead of a prompt that appears and a body that never
-- moves.
--
-- `holds` separates a standing claim (cuff, escort -- the target stays held
-- until something releases him) from a bounded action (search -- it finishes on
-- its own). Only a `holds` verb enters the ledger as a lasting record.
Rules.verbs = {
    cuff = {
        id = "cuff",
        permission = "rp.cuff",
        supported = true,
        holds = true,
        -- The body is held by the server freeze and the whole gameplay action
        -- stream is taken on the target's own client.
        movement = "frozen",
        summary = "Hold a player still with his hands up.",
    },
    escort = {
        id = "escort",
        permission = "rp.escort",
        supported = true,
        holds = true,
        -- He walks himself; the tether is what stops him walking away.
        movement = "tethered",
        summary = "Walk a cuffed player, tethered to his escort.",
    },
    search = {
        id = "search",
        permission = "rp.search",
        supported = true,
        holds = false,
        movement = "frozen",
        summary = "Frisk a player: hands up for a beat, then a report.",
    },
    carry = {
        id = "carry",
        permission = "rp.carry",
        supported = false,
        holds = false,
        reason = "carry_unsupported",
        -- Measured, not assumed. See README.md, "Why carry is refused".
        summary = "Not available on 2.31: nothing can parent one player to another.",
    },
}

Rules.verbOrder = { "cuff", "escort", "search", "carry" }

-- ---------------------------------------------------------------------------
-- Defaults
-- ---------------------------------------------------------------------------
Rules.defaults = {
    -- How close the officer must be when he starts a verb.
    maxDistance = 3.0,
    -- How far an escorted player may drift before he is pulled back.
    tetherDistance = 5.0,
    -- Where the pull puts him, measured from the officer.
    tetherPullDistance = 1.6,
    -- The floor between two pulls. A pull is a teleport, and a teleport that
    -- starts before the last one settled is refused `settle_superseded`.
    tetherCooldownMs = 2000,
    -- The hard expiry. A hold whose owner vanished in a way nothing else
    -- caught still ends here, which is why no error path can strand a player.
    maxHoldMs = 900000,
    -- How long a frisk takes.
    searchMs = 4000,
    -- Older than this and a position is not evidence. Matches the server's own
    -- two-second rule for `Open77.players.position`.
    positionMaxAgeMs = 2000,
}

-- ---------------------------------------------------------------------------
-- Every way a hold ends
-- ---------------------------------------------------------------------------
-- This list is the feature. A cuffed player whose cuffing resource errored is a
-- player who cannot move and cannot be freed, so each entry below is a path the
-- server half must actually implement, and `tests/rules_test.lua` asserts that
-- the set the server declares it handles is exactly this set -- no more, and
-- above all no less.
Rules.endReasons = {
    "released",                -- the officer (or the server console) asked
    "expired",                 -- the hold outlived maxHoldMs
    "freed_by_admin",          -- rp.admin, through the export or the command
    "officer_left",            -- the officer disconnected
    "officer_dead",            -- the officer died or went down
    "officer_bucket_changed",  -- he is in another world now
    "target_left",             -- the target disconnected
    "target_dead",             -- the platform drops the freeze anyway; we follow
    "target_bucket_changed",
    "target_mounted",          -- escort only: a tether cannot follow a seated body
    "resource_stopping",       -- stop, reload, or a runtime error in this VM
    "superseded",              -- the same target was claimed again by the same officer
}

local endReasonSet = {}
for _, reason in ipairs(Rules.endReasons) do endReasonSet[reason] = true end

function Rules.isEndReason(value)
    return endReasonSet[value] == true
end

-- ---------------------------------------------------------------------------
-- Argument shapes
-- ---------------------------------------------------------------------------
function Rules.playerId(value)
    local id = tonumber(value)
    if id == nil or id % 1 ~= 0 or id < 1 or id > 2147483647 then return nil end
    return id
end

-- 0 is the server console, the same principal the ACL uses for local
-- administration. It is not a player and must never pass a distance check.
function Rules.actorId(value)
    local id = tonumber(value)
    if id == nil or id % 1 ~= 0 or id < 0 or id > 2147483647 then return nil end
    return id
end

function Rules.config(overrides)
    local out = {}
    for key, value in pairs(Rules.defaults) do out[key] = value end
    if type(overrides) == "table" then
        for key, value in pairs(overrides) do
            if out[key] ~= nil and type(value) == "number" and value == value
                and value > 0 and value < math.huge then
                out[key] = value
            end
        end
    end
    return out
end

-- ---------------------------------------------------------------------------
-- distance
-- ---------------------------------------------------------------------------
function Rules.distance(a, b)
    if type(a) ~= "table" or type(b) ~= "table" then return nil end
    local ax, ay, az = tonumber(a.x), tonumber(a.y), tonumber(a.z)
    local bx, by, bz = tonumber(b.x), tonumber(b.y), tonumber(b.z)
    if ax == nil or ay == nil or az == nil or bx == nil or by == nil or bz == nil then
        return nil
    end
    local dx, dy, dz = ax - bx, ay - by, az - bz
    return math.sqrt(dx * dx + dy * dy + dz * dz)
end

-- ---------------------------------------------------------------------------
-- The gate
-- ---------------------------------------------------------------------------
-- `officer` and `target` are `Open77.players.get`-shaped reads. The kit only
-- ever passes what that call answers, so the gate can be exercised with plain
-- tables and no runtime.
--
--   { playerId, bucket, ready, fresh, ageMs, position = { x, y, z }, alive }
--
-- `held` is the ledger record currently standing against the target, or nil.
local function readable(read, prefix, config)
    if type(read) ~= "table" then return false, prefix .. "_unknown" end
    if read.ready == false then return false, prefix .. "_not_ready" end
    -- `alive` is absent without `players.life.read`; the server half holds that
    -- permission, so an absent field here means the read itself was wrong.
    if read.alive ~= true then return false, prefix .. "_not_alive" end
    if type(read.position) ~= "table" then return false, prefix .. "_no_position" end
    local age = tonumber(read.ageMs)
    if age == nil or age > config.positionMaxAgeMs then
        return false, prefix .. "_position_stale"
    end
    return true
end

function Rules.gate(verb, officer, target, held, config)
    config = config or Rules.defaults

    local definition = Rules.verbs[verb]
    if definition == nil then return false, "unknown_verb" end
    if not definition.supported then return false, definition.reason or "unsupported_verb" end

    if type(officer) ~= "table" or type(target) ~= "table" then
        return false, "invalid_player"
    end
    local officerId = Rules.playerId(officer.playerId)
    local targetId = Rules.playerId(target.playerId)
    if officerId == nil or targetId == nil then return false, "invalid_player" end
    if officerId == targetId then return false, "cannot_target_self" end

    local ok, reason = readable(officer, "officer", config)
    if not ok then return false, reason end
    ok, reason = readable(target, "target", config)
    if not ok then return false, reason end

    if (officer.bucket or 0) ~= (target.bucket or 0) then return false, "different_bucket" end

    local metres = Rules.distance(officer.position, target.position)
    if metres == nil then return false, "invalid_position" end
    if metres > config.maxDistance then return false, "too_far" end

    -- `held` is the record standing against this target IN THE LEDGER THIS VERB
    -- USES: the standing ledger for cuff and escort, the frisk ledger for
    -- search. A search therefore never has to argue with a cuff, and a cuff
    -- never silently overwrites somebody else's frisk.
    if held ~= nil then
        if held.officer ~= officerId then return false, "held_by_another" end
        -- The same officer re-issuing the same verb is a no-op he should see;
        -- a different verb from the same officer replaces the hold.
        if held.verb == verb then return false, "already_held" end
    end

    return true, metres
end

-- ---------------------------------------------------------------------------
-- The tether
-- ---------------------------------------------------------------------------
-- Escort is a leash, not an attachment: the target walks himself and is pulled
-- back only when he leaves the radius. `state` carries `lastPullMs` and
-- `pullPending`; both belong to the caller, so this stays pure.
--
-- Returns `action, payload`:
--   "none"    -- nothing to do
--   "pull"    -- payload is the point to place the target on
--   "end"     -- payload is one of Rules.endReasons
function Rules.tether(officer, target, state, nowMs, config)
    config = config or Rules.defaults
    state = state or {}

    if type(officer) ~= "table" or type(target) ~= "table" then return "none" end
    if officer.ready == false or target.ready == false then return "none" end
    if officer.alive == false then return "end", "officer_dead" end
    if target.alive == false then return "end", "target_dead" end
    if (officer.bucket or 0) ~= (target.bucket or 0) then return "end", "target_bucket_changed" end

    -- A mounted body cannot be teleported (`player_in_vehicle`), so the leash
    -- has nothing left to enforce. Ending is the honest answer: silently
    -- keeping a hold that no longer holds anything is the failure this kit is
    -- built to avoid.
    if target.inVehicle == true then return "end", "target_mounted" end

    local officerAge = tonumber(officer.ageMs)
    local targetAge = tonumber(target.ageMs)
    if officerAge == nil or targetAge == nil then return "none" end
    if officerAge > config.positionMaxAgeMs or targetAge > config.positionMaxAgeMs then
        -- Either body is streaming or loading. Not a reason to end a hold, and
        -- not enough evidence to pull on.
        return "none"
    end

    local metres = Rules.distance(officer.position, target.position)
    if metres == nil then return "none" end
    if metres <= config.tetherDistance then return "none" end

    if state.pullPending then return "none" end
    local last = tonumber(state.lastPullMs) or -math.huge
    if nowMs - last < config.tetherCooldownMs then return "none" end

    -- Put him on the officer's side of the gap rather than inside him: the
    -- direction is the officer-to-target vector, shortened.
    local ox, oy, oz = officer.position.x, officer.position.y, officer.position.z
    local tx, ty, tz = target.position.x, target.position.y, target.position.z
    local dx, dy, dz = tx - ox, ty - oy, tz - oz
    local length = math.sqrt(dx * dx + dy * dy + dz * dz)
    if length <= 0.001 then return "none" end
    local scale = config.tetherPullDistance / length
    return "pull", {
        x = ox + dx * scale,
        y = oy + dy * scale,
        -- Keep the officer's height. The target's own z is where he ran off to,
        -- which may be a floor above or a ledge below.
        z = oz,
    }
end

-- ---------------------------------------------------------------------------
-- The ledger
-- ---------------------------------------------------------------------------
-- One record per held target. A ledger, not a flag: the kit must release
-- exactly what it took, so every claim it has taken on the platform is written
-- down beside the record that asked for it.
function Rules.newLedger()
    local ledger = { records = {}, count = 0 }

    function ledger:get(targetId)
        local id = Rules.playerId(targetId)
        if id == nil then return nil end
        return self.records[id]
    end

    function ledger:byOfficer(officerId)
        local id = Rules.playerId(officerId)
        local out = {}
        if id == nil then return out end
        for _, record in pairs(self.records) do
            if record.officer == id then out[#out + 1] = record end
        end
        table.sort(out, function(left, right) return left.target < right.target end)
        return out
    end

    function ledger:all()
        local out = {}
        for _, record in pairs(self.records) do out[#out + 1] = record end
        table.sort(out, function(left, right) return left.target < right.target end)
        return out
    end

    function ledger:claim(record)
        local targetId = Rules.playerId(record and record.target)
        local officerId = Rules.playerId(record and record.officer)
        if targetId == nil or officerId == nil then return nil, "invalid_player" end
        if Rules.verbs[record.verb] == nil then return nil, "unknown_verb" end
        local previous = self.records[targetId]
        if previous == nil then self.count = self.count + 1 end
        record.target = targetId
        record.officer = officerId
        record.claims = record.claims or {}
        self.records[targetId] = record
        return record, previous
    end

    function ledger:release(targetId)
        local id = Rules.playerId(targetId)
        if id == nil then return nil end
        local record = self.records[id]
        if record == nil then return nil end
        self.records[id] = nil
        self.count = self.count - 1
        return record
    end

    -- Everything whose deadline has passed, oldest first. The sweep calls this
    -- and then releases each one; that is the path that catches a hold whose
    -- owner died in a way no event described.
    function ledger:expired(nowMs)
        local out = {}
        for _, record in pairs(self.records) do
            if type(record.expiresAt) == "number" and nowMs >= record.expiresAt then
                out[#out + 1] = record
            end
        end
        table.sort(out, function(left, right) return left.expiresAt < right.expiresAt end)
        return out
    end

    return ledger
end

-- ---------------------------------------------------------------------------
-- What a record looks like on the wire and in an export result
-- ---------------------------------------------------------------------------
function Rules.publicRecord(record)
    if type(record) ~= "table" then return nil end
    return {
        target = record.target,
        officer = record.officer,
        verb = record.verb,
        since = record.since,
        expiresAt = record.expiresAt,
        owner = record.owner,
    }
end

-- The capability answer. Deliberately shaped like
-- `Open77.input.blockableActions()`: a caller reads it instead of hard-coding
-- what this build can do.
function Rules.capabilities()
    local out = {}
    for _, id in ipairs(Rules.verbOrder) do
        local definition = Rules.verbs[id]
        out[#out + 1] = {
            verb = id,
            supported = definition.supported,
            reason = definition.reason,
            permission = definition.permission,
            holds = definition.holds,
            movement = definition.movement,
            summary = definition.summary,
        }
    end
    return out
end

RpBasicsRules = Rules
return Rules
