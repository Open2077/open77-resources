-- Server-side target declaration.
--
-- A job resource should describe its targets once -- "every vehicle gets a
-- Repair option for mechanics", "the ATM model gets a Withdraw option" -- and
-- have every connected client apply them. Doing that per client from a client
-- script means every gamemode reimplements the same fan-out, and gets late
-- joins wrong.
--
-- The wire is an ordinary authenticated net event, not a new protocol message:
-- `open77:interactions:targets` and `open77:interactions:retract`. The client
-- half trusts the `owner` in the message precisely because the message can only
-- have come from the server.
--
-- Nothing here is authority. A target is a prompt, and a prompt is
-- presentation: the client owns the code that decides whether to draw it, so
-- every rule a target seems to enforce -- the group gate, the distance, the
-- vehicle state -- must be re-derived by whatever server handler receives the
-- intent the player's key press produces.
--
-- Prop targets (0.3.0). A `prop` target names server props by id; the prompt
-- follows the prop. Offering a prompt on a prop is a claim about somebody's
-- object, so it is the one target kind this half authorizes: the declaring
-- resource must own the prop (`Open77.props.get(id).resource`) or hold a grant
-- the owner issued (`grantProp`, or `requestProp` answered by the owner). No
-- path lets a resource bypass the prop's owner. What clients receive is the
-- EFFECTIVE set -- every prop id re-checked against ownership, grants and the
-- registry on every push -- so a revoked grant or a removed prop takes the
-- prompt with it within one sweep. A grant still only buys presentation: the
-- handler of the intent must ask `propAccess` again before acting, and the
-- prop's own mutations stay owner-only in the registry whatever is granted here.

local MAX_TARGETS_PER_OWNER = 32
local MAX_DECLARATION_BYTES = 16384
local MAX_PROPS_PER_TARGET = 128
local MAX_GRANTS_PER_PROP = 32
local MAX_PENDING_REQUESTS = 256
local REQUEST_TTL_SECONDS = 30.0
local MIN_GRANT_TTL_MS = 1000
local MAX_GRANT_TTL_MS = 7 * 24 * 3600 * 1000
local SWEEP_SECONDS = 2.0

local declarations = {}
local generations = {}
local pushedSignatures = {}
local nextSweep = 0
-- [propId] = { [owner] = true }: which declarations name a prop, so a removal
-- or a lapsed grant re-evaluates only the owners concerned.
local propDeclarers = {}
-- Owners whose effective prop set may have moved; settled by the next sweep.
-- Mass removals (a resource stopping takes all its props) mark instead of
-- re-pushing per prop, which would be quadratic.
local dirtyOwners = {}
local sweepCount = 0

-- [propId] = { [grantee] = { owner = <prop owner at grant time>, expiresAt = <monotonic s|nil>, note } }
local propGrants = {}
-- [requestId] = { propId, requester, owner, note, expiresAt }
local propRequests = {}
local nextRequestId = 0

local function now() return Open77.time.monotonic() end

local function validName(value, maximum)
    return type(value) == "string" and #value > 0 and #value <= maximum and
        value:match("^[%w_:%-%.]+$") ~= nil
end

local function validNote(value)
    return value == nil or (type(value) == "string" and #value <= 96 and not value:find("[%c]"))
end

-- Prop ids are decimal strings (the registry is 64-bit). A Lua integer is
-- accepted and canonicalised; nothing is passed through tonumber.
local function canonicalPropId(value)
    if math.type(value) == "integer" and value > 0 then return tostring(value) end
    if type(value) == "number" and value > 0 and value % 1 == 0 and value < 2 ^ 53 then
        return tostring(math.tointeger(value))
    end
    if type(value) == "string" and #value <= 20 and value:match("^[1-9][0-9]*$") then return value end
    return nil
end

local function propRecord(propId)
    if type(Open77.props) ~= "table" or type(Open77.props.get) ~= "function" then return nil end
    local ok, record = pcall(Open77.props.get, propId)
    if ok and type(record) == "table" then return record end
    return nil
end

local function grantLive(grant, record)
    if not grant or not record then return false end
    -- A grant names the owner that issued it. If the prop somehow changed
    -- hands (it cannot today: ids are never reused), the grant is void.
    if grant.owner ~= record.resource then return false end
    return grant.expiresAt == nil or now() < grant.expiresAt
end

-- The one authorization question: may `resource` offer prompts on `propId`?
-- Returns true, "owner" | "granted", or false, reason.
local function propAccess(resource, propId)
    local id = canonicalPropId(propId)
    if not id then return false, "invalid_prop_id" end
    if not validName(resource, 64) then return false, "invalid_resource" end
    local record = propRecord(id)
    if not record then return false, "prop_not_found" end
    if record.resource == resource then return true, "owner" end
    local grants = propGrants[id]
    if grants and grantLive(grants[resource], record) then return true, "granted" end
    return false, "prop_not_authorized"
end

-- Declarations are copied across the export boundary already, so this is not
-- about aliasing: it is a hard bound on what one resource can make the server
-- fan out to every client on every join.
local function measure(value, depth, budget)
    local kind = type(value)
    if kind == "string" then return budget - #value - 2 end
    if kind == "number" or kind == "boolean" or kind == "nil" then return budget - 8 end
    if kind ~= "table" or depth > 8 then return -1 end
    for key, item in pairs(value) do
        budget = measure(key, depth + 1, budget)
        if budget < 0 then return -1 end
        budget = measure(item, depth + 1, budget)
        if budget < 0 then return -1 end
    end
    return budget
end

-- `prop` / `props` -> a sorted, de-duplicated list of canonical ids.
local function normalizePropList(value)
    if type(value) ~= "table" then value = { value } end
    local count = #value
    if count < 1 or count > MAX_PROPS_PER_TARGET then return nil, "invalid_props" end
    local seen, out = {}, {}
    for index = 1, count do
        local id = canonicalPropId(value[index])
        if not id then return nil, "invalid_props" end
        if not seen[id] then
            seen[id] = true
            out[#out + 1] = id
        end
    end
    table.sort(out)
    return out
end

-- What the clients get for one owner: every non-prop target unchanged, every
-- prop target reduced to the ids the owner may still use (a target left with
-- none is withheld), plus a signature that changes exactly when that set does.
local function effective(owner, set)
    local list, parts = {}, {}
    local ids = {}
    for id in pairs(set) do ids[#ids + 1] = id end
    table.sort(ids)
    for _, id in ipairs(ids) do
        local definition = set[id]
        if definition.kind == "prop" then
            local allowed = {}
            for _, propId in ipairs(definition.props) do
                if propAccess(owner, propId) then allowed[#allowed + 1] = propId end
            end
            if #allowed > 0 then
                local copy = {}
                for key, value in pairs(definition) do copy[key] = value end
                copy.props = allowed
                list[#list + 1] = copy
                parts[#parts + 1] = id .. "=" .. table.concat(allowed, ",")
            else
                parts[#parts + 1] = id .. "=-"
            end
        else
            list[#list + 1] = definition
            parts[#parts + 1] = id
        end
    end
    return list, table.concat(parts, ";")
end

local function push(target, owner, set)
    local list, signature = effective(owner, set)
    if target == -1 then pushedSignatures[owner] = signature end
    return TriggerClientEvent("open77:interactions:targets", target, {
        owner = owner,
        targets = list,
    })
end

local function pushAll(target)
    for owner, set in pairs(declarations) do push(target, owner, set) end
end

local function hasPropTargets(set)
    for _, definition in pairs(set) do
        if definition.kind == "prop" then return true end
    end
    return false
end

-- Re-push one owner's declaration when its effective prop set moved. Cheap
-- when nothing changed: one signature comparison.
local function refreshOwner(owner)
    local set = declarations[owner]
    if not set or not hasPropTargets(set) then return end
    local _, signature = effective(owner, set)
    if signature ~= pushedSignatures[owner] then push(-1, owner, set) end
end

local function indexProps(owner, set)
    for propId, owners in pairs(propDeclarers) do
        owners[owner] = nil
        if next(owners) == nil then propDeclarers[propId] = nil end
    end
    for _, definition in pairs(set or {}) do
        if definition.kind == "prop" then
            for _, propId in ipairs(definition.props) do
                propDeclarers[propId] = propDeclarers[propId] or {}
                propDeclarers[propId][owner] = true
            end
        end
    end
end

local function retract(owner)
    declarations[owner] = nil
    generations[owner] = nil
    pushedSignatures[owner] = nil
    dirtyOwners[owner] = nil
    indexProps(owner, nil)
    TriggerClientEvent("open77:interactions:retract", -1, { owner = owner })
end

-- Server-local notification; every server resource may listen, and filters by
-- the names in the arguments.
local function notify(event, ...)
    if type(TriggerEvent) == "function" then pcall(TriggerEvent, event, ...) end
end

local function dropRequest(requestId, granted, reason)
    local request = propRequests[requestId]
    if not request then return end
    propRequests[requestId] = nil
    notify("open77_interactions:propAnswered", requestId, request.propId, request.requester,
        granted == true, reason)
end

-- `immediate` re-pushes now (an explicit revocation); otherwise the owner is
-- marked and the next sweep settles it.
local function dropGrant(propId, grantee, reason, immediate)
    local grants = propGrants[propId]
    if not grants or not grants[grantee] then return false end
    grants[grantee] = nil
    if next(grants) == nil then propGrants[propId] = nil end
    notify("open77_interactions:propRevoked", propId, grantee, reason)
    if immediate then refreshOwner(grantee) else dirtyOwners[grantee] = true end
    return true
end

local function forgetProp(propId, reason)
    for owner in pairs(propDeclarers[propId] or {}) do dirtyOwners[owner] = true end
    propDeclarers[propId] = nil -- prop ids are never reused
    local grants = propGrants[propId]
    if grants then
        local grantees = {}
        for grantee in pairs(grants) do grantees[#grantees + 1] = grantee end
        table.sort(grantees)
        for _, grantee in ipairs(grantees) do dropGrant(propId, grantee, reason) end
    end
    for requestId, request in pairs(propRequests) do
        if request.propId == propId then dropRequest(requestId, false, reason) end
    end
end

-- A declaring resource that stops or reloads takes its targets with it. The
-- client half cannot notice this on its own: a server-only job resource has no
-- client VM whose stop it could observe. The same sweep expires grants and
-- requests and re-pushes any owner whose effective prop set moved (a prop
-- removed, a grant lapsed).
local function sweep()
    local current = now()
    if current < nextSweep then return end
    nextSweep = current + SWEEP_SECONDS
    for owner, generation in pairs(generations) do
        if GetResourceState(owner) ~= "running" or
            Open77.resource.generation(owner) ~= generation then
            retract(owner)
        end
    end
    local expired = {}
    for propId, grants in pairs(propGrants) do
        for grantee, grant in pairs(grants) do
            if grant.expiresAt ~= nil and current >= grant.expiresAt then
                expired[#expired + 1] = { propId, grantee }
            end
        end
    end
    for _, pair in ipairs(expired) do dropGrant(pair[1], pair[2], "expired") end
    for requestId, request in pairs(propRequests) do
        if current >= request.expiresAt then dropRequest(requestId, false, "request_expired") end
    end
    -- Settle the owners something touched; every 15th sweep (30 s) re-check
    -- them all, as a net under a removal whose event never arrived.
    sweepCount = sweepCount + 1
    local owners = dirtyOwners
    if sweepCount % 15 == 0 then
        owners = {}
        for owner in pairs(declarations) do owners[owner] = true end
    end
    dirtyOwners = {}
    for owner in pairs(owners) do refreshOwner(owner) end
end

local function define(owner, generation, definitions)
    if not validName(owner, 64) then return false, "invalid_owner" end
    if type(definitions) ~= "table" then return false, "definitions_must_be_a_table" end
    -- One target or a list of them; a job resource declaring a single rule
    -- should not have to wrap it.
    if definitions.kind ~= nil then definitions = { definitions } end
    if #definitions < 1 or #definitions > MAX_TARGETS_PER_OWNER then
        return false, "invalid_target_count"
    end
    if measure(definitions, 0, MAX_DECLARATION_BYTES) < 0 then
        return false, "declaration_too_large"
    end

    local set = {}
    for index = 1, #definitions do
        local definition = definitions[index]
        if type(definition) ~= "table" then return false, "definition_must_be_a_table" end
        local id = definition.id
        if not validName(id, 64) then return false, "invalid_target_id" end
        if set[id] then return false, "duplicate_target_id" end
        -- The client re-validates every field through the same normaliser a
        -- hand-written interaction goes through, so this half deliberately does
        -- not second-guess the shape: it owns identity and fan-out, not schema.
        -- The exception is `prop`, whose ids are an authorization question
        -- only the server can answer.
        if definition.kind == "prop" then
            local props, reason = normalizePropList(definition.props or definition.prop)
            if not props then return false, reason end
            for _, propId in ipairs(props) do
                local allowed, why = propAccess(owner, propId)
                if not allowed then return false, why end
            end
            definition.props, definition.prop = props, nil
        end
        set[id] = definition
    end

    declarations[owner] = set
    generations[owner] = generation
    indexProps(owner, set)
    push(-1, owner, set)
    return true
end

exports("define", function(definitions)
    return define(GetInvokingResource(), GetInvokingResourceGeneration(), definitions)
end)

exports("undefine", function(id)
    local owner = GetInvokingResource()
    if not validName(owner, 64) then return false, "invalid_owner" end
    local set = declarations[owner]
    if not set then return false, "no_declaration" end
    if id == nil then
        retract(owner)
        return true
    end
    if not validName(id, 64) then return false, "invalid_target_id" end
    if set[id] == nil then return false, "target_not_found" end
    set[id] = nil
    if next(set) == nil then
        retract(owner)
        return true
    end
    indexProps(owner, set)
    push(-1, owner, set)
    return true
end)

exports("clear", function()
    local owner = GetInvokingResource()
    if not validName(owner, 64) then return false, "invalid_owner" end
    if declarations[owner] == nil then return false, "no_declaration" end
    retract(owner)
    return true
end)

exports("list", function()
    local owner = GetInvokingResource()
    local set = declarations[owner]
    if not set then return {} end
    local out = {}
    for id in pairs(set) do out[#out + 1] = id end
    table.sort(out)
    return out
end)

-- ---------------------------------------------------------------------------
-- Cross-resource prop authorization (0.3.0)
-- ---------------------------------------------------------------------------

local function ttlSeconds(options)
    if options == nil or options.ttlMs == nil then return true, nil end
    local ttl = options.ttlMs
    if math.type(ttl) ~= "integer" and not (type(ttl) == "number" and ttl % 1 == 0) then
        return false
    end
    if ttl < MIN_GRANT_TTL_MS or ttl > MAX_GRANT_TTL_MS then return false end
    return true, ttl / 1000.0
end

local function issueGrant(owner, propId, grantee, options)
    local okTtl, seconds = ttlSeconds(options)
    if not okTtl then return false, "invalid_ttl" end
    local note = options and options.note or nil
    if not validNote(note) then return false, "invalid_note" end
    local grants = propGrants[propId]
    if not grants then
        grants = {}
        propGrants[propId] = grants
    end
    if grants[grantee] == nil then
        local count = 0
        for _ in pairs(grants) do count = count + 1 end
        if count >= MAX_GRANTS_PER_PROP then return false, "grant_limit" end
    end
    grants[grantee] = { owner = owner, expiresAt = seconds and (now() + seconds) or nil, note = note }
    for requestId, request in pairs(propRequests) do
        if request.propId == propId and request.requester == grantee then
            dropRequest(requestId, true, "granted")
        end
    end
    refreshOwner(grantee)
    return true
end

-- grantProp(propId, grantee, { ttlMs?, note? }) -> true | false, reason
-- Only the prop's owner may grant. Re-granting replaces the expiry.
exports("grantProp", function(propId, grantee, options)
    local caller = GetInvokingResource()
    if not validName(caller, 64) then return false, "invalid_owner" end
    local id = canonicalPropId(propId)
    if not id then return false, "invalid_prop_id" end
    if not validName(grantee, 64) or grantee == caller then return false, "invalid_grantee" end
    if options ~= nil and type(options) ~= "table" then return false, "invalid_options" end
    local record = propRecord(id)
    if not record then return false, "prop_not_found" end
    if record.resource ~= caller then return false, "not_prop_owner" end
    return issueGrant(caller, id, grantee, options)
end)

-- revokeProp(propId, grantee?) -> true | false, reason. Owner only; without a
-- grantee every grant on the prop goes.
exports("revokeProp", function(propId, grantee)
    local caller = GetInvokingResource()
    local id = canonicalPropId(propId)
    if not id then return false, "invalid_prop_id" end
    local record = propRecord(id)
    local grants = propGrants[id]
    if record and record.resource ~= caller then return false, "not_prop_owner" end
    if not grants then return false, "grant_not_found" end
    if grantee ~= nil then
        local grant = grants[grantee]
        if not grant then return false, "grant_not_found" end
        if grant.owner ~= caller then return false, "not_prop_owner" end
        dropGrant(id, grantee, "revoked", true)
        return true
    end
    local victims = {}
    for name, grant in pairs(grants) do
        if grant.owner == caller then victims[#victims + 1] = name end
    end
    if #victims == 0 then return false, "grant_not_found" end
    table.sort(victims)
    for _, name in ipairs(victims) do dropGrant(id, name, "revoked", true) end
    return true
end)

-- requestProp(propId, { note? }) -> requestId | nil, reason
-- Asks the prop's owner for a grant. The owner hears
-- `open77_interactions:propRequested(requestId, propId, requester, note, owner)`
-- and answers with `answerPropRequest`; the requester hears
-- `open77_interactions:propAnswered(requestId, propId, requester, granted, reason)`.
-- Silence is a refusal after 30 s (`request_expired`).
exports("requestProp", function(propId, options)
    local caller = GetInvokingResource()
    if not validName(caller, 64) then return nil, "invalid_owner" end
    local id = canonicalPropId(propId)
    if not id then return nil, "invalid_prop_id" end
    if options ~= nil and type(options) ~= "table" then return nil, "invalid_options" end
    local note = options and options.note or nil
    if not validNote(note) then return nil, "invalid_note" end
    local record = propRecord(id)
    if not record then return nil, "prop_not_found" end
    if record.resource == caller then return nil, "already_owner" end
    if propAccess(caller, id) then return nil, "already_granted" end
    local pending = 0
    for requestId, request in pairs(propRequests) do
        if request.propId == id and request.requester == caller then return requestId end
        pending = pending + 1
    end
    if pending >= MAX_PENDING_REQUESTS then return nil, "request_limit" end
    nextRequestId = nextRequestId + 1
    local requestId = "pr" .. tostring(nextRequestId)
    propRequests[requestId] = {
        propId = id, requester = caller, owner = record.resource, note = note,
        expiresAt = now() + REQUEST_TTL_SECONDS,
    }
    notify("open77_interactions:propRequested", requestId, id, caller, note, record.resource)
    return requestId
end)

-- answerPropRequest(requestId, allow, { ttlMs?, note?, reason? }) -> true | false, reason
exports("answerPropRequest", function(requestId, allow, options)
    local caller = GetInvokingResource()
    local request = type(requestId) == "string" and propRequests[requestId] or nil
    if not request then return false, "request_not_found" end
    local record = propRecord(request.propId)
    if not record then
        dropRequest(requestId, false, "prop_not_found")
        return false, "prop_not_found"
    end
    if record.resource ~= caller then return false, "not_prop_owner" end
    if options ~= nil and type(options) ~= "table" then return false, "invalid_options" end
    if allow ~= true then
        local reason = options and options.reason or "denied"
        if not validName(reason, 64) then reason = "denied" end
        dropRequest(requestId, false, reason)
        return true
    end
    return issueGrant(caller, request.propId, request.requester, options)
end)

-- propAccess(propId, resource?) -> true, "owner" | "granted" | false, reason
-- The authority helper: a handler acting on a prompt's intent asks it again.
exports("propAccess", function(propId, resource)
    return propAccess(resource or GetInvokingResource(), propId)
end)

-- propGrants(propId) -> { { grantee, expiresInMs?, note? } } | nil, reason. Owner only.
exports("propGrants", function(propId)
    local caller = GetInvokingResource()
    local id = canonicalPropId(propId)
    if not id then return nil, "invalid_prop_id" end
    local record = propRecord(id)
    if not record then return nil, "prop_not_found" end
    if record.resource ~= caller then return nil, "not_prop_owner" end
    local out = {}
    for grantee, grant in pairs(propGrants[id] or {}) do
        if grantLive(grant, record) then
            out[#out + 1] = {
                grantee = grantee, note = grant.note,
                expiresInMs = grant.expiresAt and math.floor((grant.expiresAt - now()) * 1000) or nil,
            }
        end
    end
    table.sort(out, function(left, right) return left.grantee < right.grantee end)
    return out
end)

RegisterNetEvent("open77:interactions:sync", function()
    local player = tonumber(source)
    if player == nil or player <= 0 then return end
    pushAll(player)
end)

AddEventHandler("onPlayerConnected", function(playerId)
    local player = tonumber(playerId)
    if player == nil or player <= 0 then return end
    pushAll(player)
end)

-- Needs `world.props` (the same permission `Open77.props.get` needs). A removed
-- prop takes its grants and requests with it at once rather than at the sweep.
AddEventHandler("onPropRemoved", function(id, reason)
    local propId = canonicalPropId(id)
    if not propId then return end
    forgetProp(propId, "prop_removed")
end)

AddEventHandler("onResourceStop", function(name)
    if name == GetCurrentResourceName() then
        for owner in pairs(declarations) do
            TriggerClientEvent("open77:interactions:retract", -1, { owner = owner })
        end
        declarations, generations, pushedSignatures = {}, {}, {}
        propGrants, propRequests, propDeclarers, dirtyOwners = {}, {}, {}, {}
    elseif declarations[name] then
        retract(name)
    end
end)

CreateThread(function()
    while true do
        sweep()
        Wait(1000)
    end
end)
