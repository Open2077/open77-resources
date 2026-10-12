-- rp_garage/server/access.lua: who may do what with a tracked vehicle (row A9 of the
-- world-interaction plan).
--
-- Pure policy, no native: server/main.lua gathers the facts (the row, the caller's durable
-- identifier, keys, jobs, duty, grants) and asks RpGarageAccess.decide. Three things are kept
-- apart on purpose:
--   * the LEGAL owner and key holders (this registry, keyed by plate),
--   * the PHYSICS authority (Open77.vehicles.owner: whoever simulates the car) -- never consulted,
--   * the RESOURCE permissions (world.vehicles / world.props of the calling resource) -- the
--     caller's business.
-- A trunk opened in the world (Open77.vehicles.isDoorOpen) is presentation, never authorization:
-- nothing here reads door state.
--
-- decide(policy, facts, part, action) -> true, role | false, reason
--   part   nil for a vehicle-level action (drive, lock, store, manage, repair, impound),
--          else one of policy.parts (cargo, trunk, glovebox) with view / take / put.
--   facts  {
--            row        = { plate, owner, state, wanted } | nil   (nil: no durable identity)
--            identifier = durable account id of the caller | nil
--            holdsKey   = boolean   (rp_garage_keys row for this identifier)
--            society    = "<job>" | nil     (owner is "society:<job>")
--            employee   = boolean, boss = boolean   (rp_jobs, for that society)
--            mechanic   = { job = bool, duty = bool, order = grant | nil }
--            police     = { job = bool, duty = bool, grade = number, warrant = grant | nil }
--            now        = unix seconds
--          }
-- Roles, in precedence order: owner, key, mechanic, police. The first role that permits the
-- action and passes its gates wins; otherwise the most specific refusal is returned.

RpGarageAccess = {}
local A = RpGarageAccess

A.VEHICLE_ACTIONS = { drive = true, lock = true, store = true, manage = true, repair = true, impound = true }
A.PART_ACTIONS = { view = true, take = true, put = true }
A.ROLES = { "owner", "key", "mechanic", "police" }
A.GRANT_ROLES = { mechanic = true, police = true }

local function contains(list, value)
    if type(list) ~= "table" then return false end
    for _, v in ipairs(list) do
        if v == value then return true end
    end
    return false
end

-- Is `part` one of the policy's parts?
function A.validPart(policy, part)
    return type(part) == "string" and contains(policy.parts, part)
end

-- Validates the (part, action) pair against the vocabulary. Returns true | false, reason.
function A.validRequest(policy, part, action)
    if type(action) ~= "string" then return false, "invalid_action" end
    if part == nil then
        if not A.VEHICLE_ACTIONS[action] then return false, "invalid_action" end
        return true
    end
    if not A.validPart(policy, part) then return false, "invalid_part" end
    if not A.PART_ACTIONS[action] then return false, "invalid_action" end
    return true
end

-- Does the role's table permit (part, action)? A role lists vehicle actions under `vehicle`
-- and per-part actions under `parts[part]` (or `parts["*"]` for every part).
function A.rolePermits(policy, role, part, action)
    local r = policy.roles and policy.roles[role]
    if type(r) ~= "table" then return false end
    if part == nil then return contains(r.vehicle, action) end
    local parts = r.parts or {}
    return contains(parts[part], action) or contains(parts["*"], action)
end

-- An active grant: not expired at `now`.
function A.active(grant, now)
    return type(grant) == "table" and type(grant.expiresAt) == "number" and grant.expiresAt > (now or 0)
end

-- The gate of one role, once the role table permits the action. Returns true | false, reason.
local function gate(policy, facts, role, part, action)
    local row = facts.row
    local impounded = row.state == "impounded"
    if role == "owner" then
        if impounded and action ~= "manage" then return false, "impounded" end
        return true
    elseif role == "key" then
        if impounded then return false, "impounded" end
        return true
    elseif role == "mechanic" then
        local m = facts.mechanic or {}
        if impounded then return false, "impounded" end
        if (policy.requireDuty or {}).mechanic ~= false and not m.duty then return false, "off_duty" end
        if not A.active(m.order, facts.now) then return false, "no_job_order" end
        return true
    elseif role == "police" then
        local p = facts.police or {}
        if (policy.requireDuty or {}).police ~= false and not p.duty then return false, "off_duty" end
        -- The impound lot is the police's own custody: no warrant needed there.
        if impounded then return true end
        local pol = policy.police or {}
        if contains(pol.withoutWarrant, part and (part .. ":" .. action) or action) then return true end
        if pol.wantedIsWarrant ~= false and row.wanted == true then return true end
        if A.active(p.warrant, facts.now) then return true end
        return false, "warrant_required"
    end
    return false, "no_access"
end

-- The roles the caller holds on this vehicle, in precedence order.
function A.rolesOf(facts)
    local row, out = facts.row, {}
    local id = facts.identifier
    if (id and row.owner == id) or (facts.society and facts.employee and facts.boss) then out[#out + 1] = "owner" end
    if facts.holdsKey or (facts.society and facts.employee) then out[#out + 1] = "key" end
    if facts.mechanic and facts.mechanic.job then out[#out + 1] = "mechanic" end
    if facts.police and facts.police.job then out[#out + 1] = "police" end
    return out
end

function A.decide(policy, facts, part, action)
    local ok, why = A.validRequest(policy, part, action)
    if not ok then return false, why end
    if type(facts) ~= "table" or facts.row == nil then return false, "vehicle_not_tracked" end
    if not facts.identifier then return false, "player_not_found" end
    local roles = A.rolesOf(facts)
    if #roles == 0 then return false, "no_access" end
    local refusal
    for _, role in ipairs(roles) do
        if A.rolePermits(policy, role, part, action) then
            local passed, reason = gate(policy, facts, role, part, action)
            if passed then return true, role end
            refusal = refusal or reason
        end
    end
    return false, refusal or "action_not_permitted"
end

-- Grants (mechanic job orders, police warrants) on one plate: the active one matching the
-- caller's identifier or "job:<name>", or nil.
function A.findGrant(grants, role, identifier, jobName, now)
    if type(grants) ~= "table" then return nil end
    for _, g in ipairs(grants) do
        if g.role == role and A.active(g, now)
            and (g.holder == identifier or (jobName and g.holder == "job:" .. jobName)) then
            return g
        end
    end
    return nil
end

-- A grant holder is a durable identifier or "job:<name>"; never a session or runtime id.
function A.validHolder(holder)
    if type(holder) ~= "string" or #holder < 3 or #holder > 64 then return false end
    if holder:match("^job:[a-z0-9_]+$") then return true end
    if holder:match("^%d+$") or holder:lower():match("^session") then return false end
    return holder:match("^[%w%-_.:@]+$") ~= nil
end

return A
