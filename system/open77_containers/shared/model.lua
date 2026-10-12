-- =============================================================================
-- open77_containers -- shared/model.lua
-- =============================================================================
-- Pure data model of durable world containers (world-interaction row A6,
-- docs/world-interaction/a6-containers.md): container ids and keys, the create
-- spec, rights and grants, public/private metadata limits, node charges and
-- their regrowth, the split of a container between the coordinator's world
-- row (identity + placement, `coordinatorMeta`) and this resource's registry
-- row (policy, `registryRecord`), and the server-owned public summary.
--
-- No Open77 native is touched here, so the offline suites load it in a bare
-- Lua 5.4 state. Global: Open77ContainersModel.
-- =============================================================================

Open77ContainersModel = {}
local M = Open77ContainersModel

M.LIMITS = {
    maxCapacityG = 100000000,         -- same ceiling as the A13 coordinator
    maxLabelBytes = 48,
    maxPublicBytes = 1024,            -- inside the 4 KiB bag value with room to spare
    maxPrivateBytes = 2048,
    maxMetaKeys = 16,
    maxMetaDepth = 3,
    maxMetaNodes = 48,
    minTtlMs = 60 * 1000,
    maxTtlMs = 30 * 24 * 3600 * 1000,
    maxReachM = 10.0,
    defaultReachM = 4.0,
    reachToleranceM = 1.5,            -- the server's player snapshot lags a tick
    maxCharges = 1000,
    minRegrowMs = 1000,
    maxRegrowMs = 7 * 24 * 3600 * 1000,
    maxRefs = 32,                     -- consume() idempotency ring per node
    maxGrants = 32,
    minGrantTtlMs = 1000,
    maxGrantTtlMs = 30 * 24 * 3600 * 1000,
    minStreamingRadius = 10.0,
    maxStreamingRadius = 300.0,
    defaultStreamingRadius = 60.0,
    maxPositionAbs = 1000000.0,
}

-- How a container is shown. `prop`: this resource projects a server prop (or,
-- with `model = false`, a point with a zone prompt). `external`: another
-- resource owns the presentation -- typically open77_actions' carry helper,
-- which must own a prop to attach it (`carryPlace`, data = { container = id })
-- -- so no prop, no bag and no prompt are made here; the owner re-places its
-- presentation at boot and reports durable moves with `place`.
M.PROJECTIONS = { prop = true, external = true }

M.KINDS = {
    crate = { despawnWhenEmpty = false },
    pile = { despawnWhenEmpty = true },
    node = { despawnWhenEmpty = false },
}

-- Rights a container's owner may grant to another resource. The owner holds
-- all of them implicitly; nobody else holds any by default.
--   take     debit the container (a line whose `from` is the container)
--   put      credit it (`to`), or update an instance's metadata in it (`at`)
--   target   offer interaction prompts on its prop (an open77_interactions grant)
--   consume  spend node charges
--   move     place / carry / drop its projection
--   meta     replace its public or private metadata
--   read     read its private metadata and contents
--   close    close it (and despawn it)
M.RIGHTS = { "take", "put", "target", "consume", "move", "meta", "read", "close" }
local RIGHT_SET = {}
for _, right in ipairs(M.RIGHTS) do RIGHT_SET[right] = true end
M.RIGHT_SET = RIGHT_SET

local function finite(value)
    return type(value) == "number" and value == value and value > -math.huge and value < math.huge
end
M.finite = finite

local function integer(value)
    if math.type(value) == "integer" then return value end
    if finite(value) and value % 1 == 0 then return math.tointeger(value) end
    return nil
end
M.integer = integer

function M.deepCopy(value)
    if type(value) ~= "table" then return value end
    local out = {}
    for key, item in pairs(value) do out[key] = M.deepCopy(item) end
    return out
end

function M.validResourceName(value)
    return type(value) == "string" and #value > 0 and #value <= 64 and value:match("^[%w_:%-%.]+$") ~= nil
end

-- A container id is the coordinator's `world:` account id. The coordinator
-- MINTS it (`openWorld`: `world:<serverTag>.<boot>.<n>`, A13 §7.2); a caller
-- never chooses one. This only recognises the shape (ASCII [A-Za-z0-9_.@-]
-- after the namespace, at most 96 bytes, never all digits or a session key).
function M.validId(id)
    if type(id) ~= "string" or #id < 8 or #id > 96 then return false end
    local key = id:match("^world:([A-Za-z0-9_.@%-]+)$")
    if not key then return false end
    if key:match("^%d+$") or key:match("^session") then return false end
    return true
end

-- A key is the caller's own durable name for a container it creates once and
-- finds again (`junkyard-crate-1`): unique per owner resource, stored with the
-- container, so a create retried with the same key is idempotent. It is not
-- an account id.
function M.validKey(key)
    return type(key) == "string" and #key >= 1 and #key <= 64 and key:match("^[A-Za-z0-9_.@:%-]+$") ~= nil
end

-- ---------------------------------------------------------------------------
-- Metadata: plain JSON-shaped data, bounded in keys, depth, nodes and bytes.
-- ---------------------------------------------------------------------------
local function encodeValue(value, depth, out)
    local kind = type(value)
    if kind == "nil" then out[#out + 1] = "null"
    elseif kind == "boolean" then out[#out + 1] = value and "true" or "false"
    elseif kind == "number" then
        if not finite(value) then error("non_finite", 0) end
        if math.type(value) == "integer" or (value % 1 == 0 and math.abs(value) < 2 ^ 53) then
            out[#out + 1] = string.format("%d", math.tointeger(value))
        else
            out[#out + 1] = string.format("%.17g", value)
        end
    elseif kind == "string" then
        out[#out + 1] = '"' .. value:gsub('[%c"\\]', function(c)
            local map = { ['"'] = '\\"', ['\\'] = '\\\\', ['\n'] = '\\n', ['\r'] = '\\r', ['\t'] = '\\t' }
            return map[c] or string.format("\\u%04x", c:byte())
        end) .. '"'
    elseif kind == "table" then
        if depth > 16 then error("too_deep", 0) end
        local count, n = 0, #value
        for _ in pairs(value) do count = count + 1 end
        if count == n and (n > 0 or next(value) == nil) then
            out[#out + 1] = "["
            for index = 1, n do
                if index > 1 then out[#out + 1] = "," end
                encodeValue(value[index], depth + 1, out)
            end
            out[#out + 1] = "]"
        else
            local keys = {}
            for key in pairs(value) do
                if type(key) ~= "string" then error("non_string_key", 0) end
                keys[#keys + 1] = key
            end
            table.sort(keys)
            out[#out + 1] = "{"
            for index, key in ipairs(keys) do
                if index > 1 then out[#out + 1] = "," end
                encodeValue(key, depth + 1, out)
                out[#out + 1] = ":"
                encodeValue(value[key], depth + 1, out)
            end
            out[#out + 1] = "}"
        end
    else
        error("unsupported_type", 0)
    end
end

-- Canonical JSON (sorted keys): signatures and size measurements.
function M.encode(value)
    local out = {}
    encodeValue(value, 0, out)
    return table.concat(out)
end

local function metaShape(value, depth, budget)
    local kind = type(value)
    if kind == "string" then
        if value:find("[%z]") then return nil end
        return budget - 1
    end
    if kind == "boolean" then return budget - 1 end
    if kind == "number" then return finite(value) and budget - 1 or nil end
    if kind ~= "table" or depth > M.LIMITS.maxMetaDepth then return nil end
    budget = budget - 1
    for key, item in pairs(value) do
        if type(key) == "string" then
            if #key == 0 or #key > 32 or not key:match("^[A-Za-z][A-Za-z0-9_.%-]*$") then return nil end
        elseif math.type(key) ~= "integer" or key < 1 then
            return nil
        end
        budget = metaShape(item, depth + 1, budget)
        if not budget or budget < 0 then return nil end
    end
    return budget
end

-- Returns a deep copy of a valid metadata table, or nil, reason.
function M.normalizeMeta(value, maxBytes, field)
    if value == nil then return {} end
    local reason = "invalid_" .. field
    if type(value) ~= "table" then return nil, reason end
    local keys = 0
    for key in pairs(value) do
        if type(key) ~= "string" then return nil, reason end
        keys = keys + 1
    end
    if keys > M.LIMITS.maxMetaKeys then return nil, field .. "_too_large" end
    if not metaShape(value, 1, M.LIMITS.maxMetaNodes) then return nil, reason end
    local ok, encoded = pcall(M.encode, value)
    if not ok then return nil, reason end
    if #encoded > maxBytes then return nil, field .. "_too_large" end
    return M.deepCopy(value)
end

local function vector(value)
    if type(value) ~= "table" then return nil end
    local x, y, z = value.x, value.y, value.z
    if not finite(x) or not finite(y) or not finite(z) then return nil end
    local bound = M.LIMITS.maxPositionAbs
    if math.abs(x) > bound or math.abs(y) > bound or math.abs(z) > bound then return nil end
    return { x = x + 0.0, y = y + 0.0, z = z + 0.0 }
end
M.vector = vector

local function validText(value, maximum)
    return type(value) == "string" and #value > 0 and #value <= maximum and not value:find("[%c]")
end

local function normalizeYaw(yaw)
    yaw = (yaw or 0.0) + 0.0
    yaw = yaw % 360.0
    if yaw > 180.0 then yaw = yaw - 360.0 end
    return yaw
end
M.normalizeYaw = normalizeYaw

-- The interaction prompt the containers resource declares for a container,
-- validated loosely here (open77_interactions validates presentation again).
local function normalizePrompt(value)
    if value == nil or value == false then return nil end
    if type(value) ~= "table" then return nil, "invalid_prompt" end
    local label = value.label
    if not validText(label, 64) then return nil, "invalid_prompt" end
    local key = value.key or "E"
    if type(key) ~= "string" or not key:match("^[A-Z0-9]$") then return nil, "invalid_prompt" end
    local hold = value.holdSeconds or 0
    if not finite(hold) or hold < 0 or hold > 10 or (hold > 0 and hold < 0.25) then return nil, "invalid_prompt" end
    local distance = value.distance or 2.0
    if not finite(distance) or distance < 0.25 or distance > 10 then return nil, "invalid_prompt" end
    local markerDistance = value.markerDistance or 8.0
    if not finite(markerDistance) or markerDistance < distance or markerDistance > 40 then
        return nil, "invalid_prompt"
    end
    local marker = value.marker or "diamond"
    if type(marker) ~= "string" or not marker:match("^[a-z]+$") or #marker > 16 then return nil, "invalid_prompt" end
    local choiceId = value.choiceId or "use"
    if not M.validResourceName(choiceId) or #choiceId > 32 then return nil, "invalid_prompt" end
    return {
        label = label, key = key, holdSeconds = hold + 0.0, distance = distance + 0.0,
        markerDistance = markerDistance + 0.0, marker = marker, choiceId = choiceId,
    }
end
M.normalizePrompt = normalizePrompt

local function normalizeNode(value, kind)
    if kind ~= "node" then
        if value ~= nil then return nil, "node_requires_node_kind" end
        return nil
    end
    if type(value) ~= "table" then return nil, "invalid_node" end
    local maxCharges = integer(value.maxCharges or value.charges)
    if not maxCharges or maxCharges < 1 or maxCharges > M.LIMITS.maxCharges then return nil, "invalid_node" end
    local charges = integer(value.charges or maxCharges)
    if not charges or charges < 0 or charges > maxCharges then return nil, "invalid_node" end
    local regrowMs = value.regrowMs
    if regrowMs ~= nil then
        regrowMs = integer(regrowMs)
        if not regrowMs or regrowMs < M.LIMITS.minRegrowMs or regrowMs > M.LIMITS.maxRegrowMs then
            return nil, "invalid_node"
        end
    end
    return { charges = charges, maxCharges = maxCharges, regrowMs = regrowMs, refs = {} }
end

-- Validates a create() spec. Returns a fresh registry row (no id, owner or
-- timestamps yet) or nil, reason.
function M.normalizeSpec(spec)
    if type(spec) ~= "table" then return nil, "invalid_spec" end
    local kind = spec.kind or "crate"
    if type(kind) ~= "string" or not M.KINDS[kind] then return nil, "invalid_kind" end
    local position = vector(spec.position)
    if not position then return nil, "invalid_position" end
    if spec.yaw ~= nil and not finite(spec.yaw) then return nil, "invalid_yaw" end
    local bucket = integer(spec.bucket or 0)
    if not bucket or bucket < 0 or bucket > 2147483647 then return nil, "invalid_bucket" end
    local model = spec.model
    if model == nil then model = kind == "node" and false or "crate.small" end
    if model ~= false and (type(model) ~= "string" or #model == 0 or #model > 256 or model:find("[%c]")) then
        return nil, "invalid_model"
    end
    if type(model) == "string" and model:lower():match("%.ent$") then return nil, "invalid_model" end
    local capacity = integer(spec.capacityG or (kind == "node" and 0 or 40000))
    if not capacity or capacity < 0 or capacity > M.LIMITS.maxCapacityG then return nil, "invalid_capacity" end
    if kind ~= "node" and capacity == 0 then return nil, "invalid_capacity" end
    local label = spec.label
    if label ~= nil and not validText(label, M.LIMITS.maxLabelBytes) then return nil, "invalid_label" end
    local public, publicWhy = M.normalizeMeta(spec.public, M.LIMITS.maxPublicBytes, "public")
    if not public then return nil, publicWhy end
    local private, privateWhy = M.normalizeMeta(spec.private, M.LIMITS.maxPrivateBytes, "private")
    if not private then return nil, privateWhy end
    local ttl
    if spec.ttlMs ~= nil then
        ttl = integer(spec.ttlMs)
        if not ttl or ttl < M.LIMITS.minTtlMs or ttl > M.LIMITS.maxTtlMs then return nil, "invalid_ttl" end
    end
    local despawn = spec.despawnWhenEmpty
    if despawn == nil then despawn = M.KINDS[kind].despawnWhenEmpty end
    if type(despawn) ~= "boolean" then return nil, "invalid_despawn_when_empty" end
    if despawn and kind == "node" then return nil, "invalid_despawn_when_empty" end
    local projection = spec.projection
    if projection == nil then projection = "prop" end
    if type(projection) ~= "string" or not M.PROJECTIONS[projection] then return nil, "invalid_projection" end
    -- An externally presented container moves with its presenter (a carried
    -- crate): proximity is the presenter's check, so reach defaults to off.
    local reach = spec.reachM
    if reach == nil then reach = projection == "external" and 0.0 or M.LIMITS.defaultReachM end
    if not finite(reach) or reach < 0 or reach > M.LIMITS.maxReachM then return nil, "invalid_reach" end
    local node, nodeWhy = normalizeNode(spec.node, kind)
    if nodeWhy then return nil, nodeWhy end
    local prompt, promptWhy = normalizePrompt(spec.prompt)
    if promptWhy then return nil, promptWhy end
    if prompt and projection == "external" then return nil, "invalid_prompt" end
    local radius = spec.streamingRadius or M.LIMITS.defaultStreamingRadius
    if not finite(radius) or radius < M.LIMITS.minStreamingRadius or radius > M.LIMITS.maxStreamingRadius then
        return nil, "invalid_streaming_radius"
    end
    if spec.key ~= nil and not M.validKey(spec.key) then return nil, "invalid_key" end
    return {
        kind = kind, key = spec.key, model = model, position = position, yaw = normalizeYaw(spec.yaw),
        bucket = bucket, capacityG = capacity, label = label, public = public, private = private,
        ttlMs = ttl, despawnWhenEmpty = despawn, reachM = reach + 0.0, node = node, prompt = prompt,
        streamingRadius = radius + 0.0, projection = projection ~= "prop" and projection or nil,
    }
end

-- The parts of a spec that define the container's identity for an idempotent
-- create() with a key: the same owner asking again for the same thing gets the
-- existing container, anything else is `already_exists`.
function M.specSignature(row)
    return M.encode({
        kind = row.kind, model = row.model, position = row.position, bucket = row.bucket,
        capacityG = row.capacityG,
    })
end

-- Whether the container holds value. Every container has a coordinator world
-- row (it carries the placement); a node created without capacity has a
-- zero-capacity row that can hold nothing.
function M.hasAccount(row)
    return row.capacityG ~= nil and row.capacityG > 0
end

-- ---------------------------------------------------------------------------
-- The split between the two durable stores. The coordinator's world row is the
-- source of truth for what it holds: identity, capacity, expiry, contents and,
-- in its metadata, the placement a restart re-projects. The registry row keeps
-- only what the coordinator does not hold: policy, presentation, node charges,
-- grants and the tombstone. Owner, kind and key are written to both at create
-- and never change (the registry copy is an index).
-- ---------------------------------------------------------------------------
M.META_BY = "open77_containers"
M.META_VERSION = 1

-- The coordinator metadata of a container (<= 2 KiB, A13 §7.2): flat x/y/z
-- like the wiki's world-container example, plus the owner, kind and key needed
-- to recognise and adopt the row.
function M.coordinatorMeta(row)
    return {
        by = M.META_BY, v = M.META_VERSION, owner = row.owner, kind = row.kind, key = row.key,
        model = row.model, x = row.position.x, y = row.position.y, z = row.position.z,
        yaw = row.yaw, bucket = row.bucket,
    }
end

-- Reads a coordinator listing row ({ id, capacityG, weightG, version, meta,
-- expiresAt }) back into the coordinator half of a container, or nil, reason
-- when the row is not one of ours or its metadata is unusable.
function M.fromCoordinator(listing)
    if type(listing) ~= "table" or not M.validId(listing.id) then return nil, "invalid_row" end
    local meta = listing.meta
    if type(meta) ~= "table" or meta.by ~= M.META_BY then return nil, "foreign" end
    if meta.v ~= M.META_VERSION then return nil, "meta_version" end
    if not M.validResourceName(meta.owner) or not M.KINDS[meta.kind] then return nil, "invalid_meta" end
    if meta.key ~= nil and not M.validKey(meta.key) then return nil, "invalid_meta" end
    local position = vector({ x = meta.x, y = meta.y, z = meta.z })
    local bucket = integer(meta.bucket or 0)
    if not position or not bucket or bucket < 0 then return nil, "invalid_meta" end
    local model = meta.model
    if model ~= false and (type(model) ~= "string" or #model == 0) then return nil, "invalid_meta" end
    if meta.yaw ~= nil and not finite(meta.yaw) then return nil, "invalid_meta" end
    local capacity = integer(listing.capacityG or 0)
    if not capacity or capacity < 0 then return nil, "invalid_row" end
    return {
        id = listing.id, owner = meta.owner, kind = meta.kind, key = meta.key, model = model,
        position = position, yaw = normalizeYaw(meta.yaw), bucket = bucket, capacityG = capacity,
        expiresAt = integer(listing.expiresAt), weightG = integer(listing.weightG),
    }
end

local COORDINATOR_FIELDS = { "model", "position", "yaw", "bucket", "capacityG", "expiresAt" }

-- The registry half of a container row: everything but what the coordinator
-- holds. Owner, kind and key stay (immutable index columns).
function M.registryRecord(row)
    local out = M.deepCopy(row)
    for _, field in ipairs(COORDINATOR_FIELDS) do out[field] = nil end
    return out
end

-- A full in-memory container: the registry half joined to the coordinator half.
function M.join(record, coordinator)
    local out = M.deepCopy(record)
    for _, field in ipairs(COORDINATOR_FIELDS) do out[field] = M.deepCopy(coordinator[field]) end
    return out
end

-- Placement equality (the projection only changes when this does).
function M.samePlacement(a, b)
    return a.model == b.model and a.bucket == b.bucket and (a.yaw or 0) == (b.yaw or 0)
        and a.position.x == b.position.x and a.position.y == b.position.y and a.position.z == b.position.z
end

-- ---------------------------------------------------------------------------
-- Grants
-- ---------------------------------------------------------------------------
function M.normalizeRights(value)
    if type(value) == "string" then value = { value } end
    if type(value) ~= "table" or #value < 1 or #value > #M.RIGHTS then return nil, "invalid_rights" end
    local set, list = {}, {}
    for _, right in ipairs(value) do
        if not RIGHT_SET[right] then return nil, "invalid_rights" end
        if not set[right] then
            set[right] = true
            list[#list + 1] = right
        end
    end
    table.sort(list)
    return list
end

function M.grantLive(grant, nowMs)
    return grant ~= nil and (grant.expiresAt == nil or nowMs < grant.expiresAt)
end

function M.hasRight(row, resource, right, nowMs)
    if row.owner == resource then return true end
    local grant = row.grants and row.grants[resource]
    if not M.grantLive(grant, nowMs) then return false end
    for _, held in ipairs(grant.rights) do
        if held == right then return true end
    end
    return false
end

-- ---------------------------------------------------------------------------
-- Node charges. Regrowth is computed lazily from `regrowFrom` (wall-clock ms),
-- so it continues across a restart without a timer having to survive it: one
-- charge per `regrowMs` elapsed since `regrowFrom`, capped at `maxCharges`.
-- ---------------------------------------------------------------------------
function M.nodeState(node, nowMs)
    if not node then return nil end
    local charges, from = node.charges, node.regrowFrom
    if node.regrowMs and from and charges < node.maxCharges then
        local steps = (nowMs - from) // node.regrowMs
        if steps > 0 then
            charges = math.min(node.maxCharges, charges + steps)
            from = charges >= node.maxCharges and nil or (from + steps * node.regrowMs)
        end
    end
    if charges >= node.maxCharges then from = nil end
    local regrowAt
    if node.regrowMs and charges < node.maxCharges then
        regrowAt = (from or nowMs) + node.regrowMs
    end
    return { charges = charges, maxCharges = node.maxCharges, regrowFrom = from, regrowAt = regrowAt,
        depleted = charges == 0 }
end

-- Applies a consumption to a node row in place. Returns the new state, or
-- nil, reason. `ref` makes it idempotent: a ref already in the ring answers
-- the stored result with `replay = true` and spends nothing.
function M.consume(node, count, ref, nowMs)
    for _, entry in ipairs(node.refs or {}) do
        if entry.ref == ref then
            local state = M.nodeState(node, nowMs)
            state.replay = true
            state.consumed = entry.count
            return state
        end
    end
    local state = M.nodeState(node, nowMs)
    if state.charges < count then return nil, "depleted" end
    local charges = state.charges - count
    local from = state.regrowFrom
    if node.regrowMs and charges < node.maxCharges and from == nil then from = nowMs end
    node.charges = charges
    node.regrowFrom = from
    node.refs = node.refs or {}
    node.refs[#node.refs + 1] = { ref = ref, count = count, at = nowMs }
    while #node.refs > M.LIMITS.maxRefs do table.remove(node.refs, 1) end
    local after = M.nodeState(node, nowMs)
    after.replay = false
    after.consumed = count
    return after
end

-- Sets a node's charges (an operator or lab reset; default: full). Regrowth
-- restarts from now when the node is left short. The consume refs are kept, so
-- a retried consume of an earlier ref still replays instead of spending again.
function M.refill(node, charges, nowMs)
    local target = charges == nil and node.maxCharges or integer(charges)
    if not target or target < 0 or target > node.maxCharges then return nil, "invalid_count" end
    local before = M.nodeState(node, nowMs)
    node.charges = target
    node.regrowFrom = (node.regrowMs and target < node.maxCharges) and nowMs or nil
    local after = M.nodeState(node, nowMs)
    after.before = before.charges
    return after
end

-- ---------------------------------------------------------------------------
-- The server-owned public summary: what may be shown to anybody (and is
-- mirrored into the prop's state bag). Contents stay private: only `empty`
-- and a coarse `fill` leave the server.
-- ---------------------------------------------------------------------------
function M.summary(row, contents, nowMs)
    local out = {
        id = row.id, kind = row.kind, label = row.label, owner = row.owner, state = row.state,
        bucket = row.bucket, position = M.deepCopy(row.position), yaw = row.yaw,
        model = row.model or nil, public = M.deepCopy(row.public or {}), expiresAt = row.expiresAt,
        rev = row.version, projection = row.projection,
    }
    if M.hasAccount(row) then
        out.capacityG = row.capacityG
        if contents then
            -- nil while only the weight is known (after a restart, a zero
            -- weight does not rule out zero-weight items until the first read).
            out.empty = contents.empty
            local weight = contents.weightG or 0
            out.fill = row.capacityG > 0 and math.floor(math.min(1.0, weight / row.capacityG) * 20 + 0.5) / 20 or 0
        end
    end
    if row.node then
        local node = M.nodeState(row.node, nowMs)
        out.charges, out.maxCharges, out.depleted, out.regrowAt = node.charges, node.maxCharges, node.depleted,
            node.regrowAt
    end
    return out
end

-- Contents known from a listing row: the weight only.
function M.contentsFromWeight(weightG)
    local weight = integer(weightG)
    if not weight then return nil end
    local contents = { weightG = weight }
    if weight > 0 then contents.empty = false end
    return contents
end

-- Contents snapshot from a coordinator read: emptiness and weight only.
function M.contentsOf(snapshot)
    if type(snapshot) ~= "table" then return nil end
    local empty = true
    for _, count in pairs(snapshot.items or {}) do
        if count and count > 0 then empty = false break end
    end
    if empty and next(snapshot.instances or {}) ~= nil then empty = false end
    return { empty = empty, weightG = snapshot.weightG or 0 }
end

return Open77ContainersModel
