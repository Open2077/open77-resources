-- =============================================================================
-- open77_transactions -- shared/model.lua
-- =============================================================================
-- Pure data model of the A13 transaction contract
-- (docs/world-interaction/a13-transaction-contract.md): account ids, move
-- lines, validation, canonical encoding/hashing and the store-agnostic commit
-- plan. No Open77 native is touched here, so the offline suites load it in a
-- bare Lua 5.4 state.
--
-- Loaded by server/main.lua (the manifest lists it as a server script, so it is
-- never shipped to clients) and by the offline suites. Not proven in game.
-- Global table: Open77TxModel.
-- =============================================================================

Open77TxModel = {}
local M = Open77TxModel

M.LIMITS = {
    maxStatements = 64,          -- LuaResourceRuntime.cs:4885
    maxParameters = 64,          -- LuaResourceRuntime.cs:4884
    maxSqlBytes = 64 * 1024,     -- LuaResourceRuntime.cs:4883
    maxLines = 48,
    minTtlMs = 1000,
    defaultTtlMs = 30000,
    maxTtlMs = 600000,
    maxCount = 1000000,
    maxMoney = 1000000000000,    -- 1e12, same ceiling as rp_economy
    maxWeightG = 100000000,
    maxMetaBytes = 2048,
    journalRowsPerStatement = 9,  -- 9 rows x 7 parameters = 63 <= 64
    maxReasonBytes = 64,          -- free-text reason on a line or an operation
}

-- Namespace -> account kind. `sys` accounts are unlimited sources/sinks that
-- are journaled but never hold a persisted balance.
M.NAMESPACES = {
    char = "container", veh = "container", stash = "container", world = "container",
    cash = "wallet", bank = "wallet", soc = "wallet",
    sys = "system",
}

local function toInteger(n)
    if math.type(n) == "integer" then return n end
    return math.tointeger(n)
end

-- Account id: <ns>:<key>[:<part>], ASCII [A-Za-z0-9_.:@~-], at most 96 bytes.
-- `~` is allowed for later characters, `char:<accountId>~<n>` (contract
-- section 12, decision 8).
function M.parseAccount(id)
    if type(id) ~= "string" or #id < 3 or #id > 96 or not id:match("^[A-Za-z0-9_.:@~%-]+$") then
        return nil, "invalid_account"
    end
    local ns, rest = id:match("^([a-z]+):(.+)$")
    if not ns or not M.NAMESPACES[ns] or rest == "" then return nil, "invalid_account" end
    return ns, M.NAMESPACES[ns]
end

-- Durable-key lint (B8 audit R3): a key that looks like a session player id or
-- a runtime entity id is refused, never persisted. Session ids are small
-- integers; runtime vehicle/prop ids are integers too. Durable keys are the
-- account identifier (char/cash/bank), the plate (veh), or a minted id (world).
-- Returns a reason string when the key is NOT durable, nil when it is fine.
local DIGIT_KEY_FORBIDDEN = { char = true, cash = true, bank = true, veh = true, world = true }

function M.durableKeyProblem(id)
    local ns, kind = M.parseAccount(id)
    if not ns then return "invalid_account" end
    if kind == "system" then return nil end
    local key = id:match("^[a-z]+:([^:]+)")
    if key == nil then return "invalid_account" end
    if key == "session" or key:match("^session") then return "session_key" end
    if DIGIT_KEY_FORBIDDEN[ns] and key:match("^%d+$") then return "runtime_id_key" end
    return nil
end

function M.accountKind(id)
    local ns, kind = M.parseAccount(id)
    return kind, ns
end

function M.validOpId(id)
    return type(id) == "string" and #id >= 8 and #id <= 96 and id:match("^[A-Za-z0-9_.:@%-]+$") ~= nil
end

function M.validItemId(id)
    return type(id) == "string" and #id >= 1 and #id <= 64 and id:match("^[a-z0-9_]+$") ~= nil
end

function M.validInstanceId(id)
    return type(id) == "string" and #id >= 4 and #id <= 64 and id:match("^[A-Za-z0-9_.:%-]+$") ~= nil
end

-- ---------------------------------------------------------------------------
-- Canonical JSON (sorted keys) -- receipts and request hashes. Supports nil,
-- booleans, integers, finite numbers, strings and tables (arrays when keys are
-- exactly 1..n).
-- ---------------------------------------------------------------------------
local function escape(s)
    return (s:gsub('[%c"\\]', function(c)
        local map = { ['"'] = '\\"', ['\\'] = '\\\\', ['\n'] = '\\n', ['\r'] = '\\r', ['\t'] = '\\t' }
        return map[c] or string.format("\\u%04x", c:byte())
    end))
end

local function encodeValue(v, depth, out)
    if depth > 16 then error("encode: too deep", 0) end
    local t = type(v)
    if v == nil then out[#out + 1] = "null"
    elseif t == "boolean" then out[#out + 1] = v and "true" or "false"
    elseif t == "number" then
        if math.type(v) == "integer" then out[#out + 1] = string.format("%d", v)
        elseif v ~= v or v == math.huge or v == -math.huge then error("encode: non-finite number", 0)
        elseif v % 1 == 0 and math.abs(v) < 2^53 then out[#out + 1] = string.format("%d", math.tointeger(v))
        else out[#out + 1] = string.format("%.17g", v) end
    elseif t == "string" then out[#out + 1] = '"' .. escape(v) .. '"'
    elseif t == "table" then
        local n = #v
        local count = 0
        for _ in pairs(v) do count = count + 1 end
        if count == n and (n > 0 or next(v) == nil) then
            out[#out + 1] = "["
            for i = 1, n do
                if i > 1 then out[#out + 1] = "," end
                encodeValue(v[i], depth + 1, out)
            end
            out[#out + 1] = "]"
        else
            local keys = {}
            for k in pairs(v) do
                if type(k) ~= "string" then error("encode: non-string key", 0) end
                keys[#keys + 1] = k
            end
            table.sort(keys)
            out[#out + 1] = "{"
            for i, k in ipairs(keys) do
                if i > 1 then out[#out + 1] = "," end
                out[#out + 1] = '"' .. escape(k) .. '":'
                encodeValue(v[k], depth + 1, out)
            end
            out[#out + 1] = "}"
        end
    else
        error("encode: unsupported type " .. t, 0)
    end
end

function M.encode(v)
    local out = {}
    encodeValue(v, 0, out)
    return table.concat(out)
end

-- FNV-1a 64 over a string, as 16 lowercase hex digits. Lua 5.4 integers wrap
-- modulo 2^64, which is exactly the arithmetic FNV needs.
function M.fnv1a64(s)
    local h = -3750763034362895579 -- 0xcbf29ce484222325 as a signed 64-bit integer
    for i = 1, #s do
        h = h ~ s:byte(i)
        h = h * 1099511628211      -- 0x100000001b3
    end
    return string.format("%016x", h)
end

function M.deepCopy(v, depth)
    depth = depth or 0
    if type(v) ~= "table" then return v end
    if depth > 16 then error("deepCopy: too deep", 0) end
    local out = {}
    for k, x in pairs(v) do out[k] = M.deepCopy(x, depth + 1) end
    return out
end

-- ---------------------------------------------------------------------------
-- Lines
-- ---------------------------------------------------------------------------
-- item     { item, count, from, to }                       containers or sys
-- money    { money, from, to }                             wallets or sys
-- capacity { capacityG, from = sys:*, to = container }     reserve-only envelope
-- instance { instance, from, to [, item, meta] }           move; item+meta when created from sys
-- meta     { instance, at, meta }                          in-place metadata update (CAS)

local function checkPair(from, to, wanted)
    local fk = M.accountKind(from)
    local tk = M.accountKind(to)
    if not fk or not tk then return nil, "invalid_account" end
    if from == to then return nil, "invalid_spec" end
    if fk == "system" and tk == "system" then return nil, "invalid_spec" end
    if (fk ~= "system" and fk ~= wanted) or (tk ~= "system" and tk ~= wanted) then
        return nil, "invalid_account"
    end
    return true
end

local function validMeta(meta)
    if type(meta) ~= "table" then return false end
    local ok, encoded = pcall(M.encode, meta)
    return ok and #encoded <= M.LIMITS.maxMetaBytes
end

-- A free-text reason: 1..64 bytes, no control characters. nil is fine.
function M.validReason(reason)
    return reason == nil or (type(reason) == "string" and #reason >= 1 and #reason <= M.LIMITS.maxReasonBytes
        and not reason:find("%c"))
end

function M.normalizeLine(line)
    if type(line) ~= "table" then return nil, "invalid_spec" end
    if not M.validReason(line.reason) then return nil, "invalid_spec" end
    local out, why = M._normalizeLine(line)
    if out then out.reason = line.reason end
    return out, why
end

function M._normalizeLine(line)
    if line.item ~= nil and line.instance == nil then
        if not M.validItemId(line.item) then return nil, "unknown_item" end
        local n = toInteger(line.count)
        if not n or n < 1 or n > M.LIMITS.maxCount then return nil, "invalid_count" end
        local ok, reason = checkPair(line.from, line.to, "container")
        if not ok then return nil, reason end
        return { kind = "item", item = line.item, count = n, from = line.from, to = line.to }
    elseif line.money ~= nil then
        local n = toInteger(line.money)
        if not n or n < 1 or n > M.LIMITS.maxMoney then return nil, "invalid_amount" end
        local ok, reason = checkPair(line.from, line.to, "wallet")
        if not ok then return nil, reason end
        return { kind = "money", amount = n, from = line.from, to = line.to }
    elseif line.capacityG ~= nil then
        local n = toInteger(line.capacityG)
        if not n or n < 1 or n > M.LIMITS.maxWeightG then return nil, "invalid_count" end
        if M.accountKind(line.from) ~= "system" or M.accountKind(line.to) ~= "container" then
            return nil, "invalid_spec"
        end
        return { kind = "capacity", capacityG = n, from = line.from, to = line.to }
    elseif line.instance ~= nil and line.at ~= nil then
        -- In-place metadata update: `meta` replaces, `metaPatch` merges
        -- (shallow) into the current metadata. Exactly one of the two.
        if not M.validInstanceId(line.instance) then return nil, "invalid_spec" end
        if M.accountKind(line.at) ~= "container" then return nil, "invalid_account" end
        if (line.meta == nil) == (line.metaPatch == nil) then return nil, "invalid_spec" end
        if line.meta ~= nil and not validMeta(line.meta) then return nil, "invalid_spec" end
        if line.metaPatch ~= nil and not validMeta(line.metaPatch) then return nil, "invalid_spec" end
        return { kind = "meta", instance = line.instance, at = line.at, meta = M.deepCopy(line.meta),
            metaPatch = M.deepCopy(line.metaPatch) }
    elseif line.instance ~= nil then
        if not M.validInstanceId(line.instance) then return nil, "invalid_spec" end
        local ok, reason = checkPair(line.from, line.to, "container")
        if not ok then return nil, reason end
        if line.meta ~= nil and line.metaPatch ~= nil then return nil, "invalid_spec" end
        if line.meta ~= nil and not validMeta(line.meta) then return nil, "invalid_spec" end
        if line.metaPatch ~= nil and not validMeta(line.metaPatch) then return nil, "invalid_spec" end
        local out = { kind = "instance", instance = line.instance, from = line.from, to = line.to }
        if M.accountKind(line.from) == "system" then
            if not M.validItemId(line.item) then return nil, "unknown_item" end
            out.item = line.item
            out.meta = M.deepCopy(line.meta or line.metaPatch or {})
        else
            -- A move may carry its metadata with it (for example the cargo
            -- bed slot): `meta` replaces, `metaPatch` merges, both under the
            -- same version compare-and-set as the move itself.
            out.meta = M.deepCopy(line.meta)
            out.metaPatch = M.deepCopy(line.metaPatch)
        end
        return out
    end
    return nil, "invalid_spec"
end

function M.normalizeLines(lines)
    if type(lines) ~= "table" or #lines < 1 or #lines > M.LIMITS.maxLines then return nil, "invalid_spec" end
    local out = {}
    for i = 1, #lines do
        local line, reason = M.normalizeLine(lines[i])
        if not line then return nil, reason, i end
        out[i] = line
    end
    return out
end

function M.hashLines(kind, lines)
    return M.fnv1a64(M.encode({ kind = kind or "", lines = lines }))
end

-- Lines that CREATE value: anything moving out of a `sys:` account into a real
-- account. Burning (into `sys:`) is never a mint. Capacity envelopes are
-- reported with asset = nil (the items are only known at commit).
-- Returns an array of { from, to, asset, amount }.
function M.mintsOf(lines)
    local out = {}
    for _, l in ipairs(lines) do
        if l.from and M.accountKind(l.from) == "system" then
            if l.kind == "item" then
                out[#out + 1] = { from = l.from, to = l.to, asset = l.item, amount = l.count }
            elseif l.kind == "money" then
                out[#out + 1] = { from = l.from, to = l.to, asset = "money", amount = l.amount }
            elseif l.kind == "instance" then
                out[#out + 1] = { from = l.from, to = l.to, asset = l.item, amount = 1 }
            elseif l.kind == "capacity" then
                out[#out + 1] = { from = l.from, to = l.to, asset = nil, amount = 0, envelope = true }
            end
        end
    end
    return out
end

function M.clampTtl(ttlMs)
    if ttlMs == nil then return M.LIMITS.defaultTtlMs end
    local n = toInteger(ttlMs)
    if not n or n < M.LIMITS.minTtlMs or n > M.LIMITS.maxTtlMs then return nil end
    return n
end

-- ---------------------------------------------------------------------------
-- Commit plan: net deltas per row, sorted keys (canonical lock order), journal.
--
-- weights:   function(itemId) -> grams | nil
-- instances: function(instanceId) -> { item, version, container } | nil  (mirror)
-- expect:    { [account] = version } optional optimistic checks
-- ---------------------------------------------------------------------------
-- The metadata an instance line writes: nil (unchanged), `meta` (replace) or
-- the current metadata with `metaPatch` merged in (shallow). The result is
-- bounded like any metadata.
function M.resolveMeta(current, meta, patch)
    if meta ~= nil then return M.deepCopy(meta) end
    if patch == nil then return nil end
    local merged = M.deepCopy(current or {})
    for k, v in pairs(patch) do merged[k] = M.deepCopy(v) end
    if #M.encode(merged) > M.LIMITS.maxMetaBytes then return nil, "invalid_spec" end
    return merged
end

local function sortedKeys(t)
    local keys = {}
    for k in pairs(t) do keys[#keys + 1] = k end
    table.sort(keys)
    return keys
end

function M.buildPlan(args)
    local lines, weights, instanceOf = args.lines, args.weights, args.instances
    local containers, stacks, wallets, insts = {}, {}, {}, {}
    local journal = {}
    local function container(id)
        local c = containers[id]
        if not c then c = { id = id, weightDelta = 0 }; containers[id] = c end
        return c
    end
    local function stack(cid, item, delta)
        local key = cid .. "\0" .. item
        local s = stacks[key]
        if not s then s = { container = cid, item = item, delta = 0 }; stacks[key] = s end
        s.delta = s.delta + delta
    end
    local function wallet(id, delta)
        local w = wallets[id]
        if not w then w = { id = id, delta = 0 }; wallets[id] = w end
        w.delta = w.delta + delta
    end
    local reason
    local function journalPair(from, to, asset, n)
        journal[#journal + 1] = { account = from, asset = asset, delta = -n, reason = reason }
        journal[#journal + 1] = { account = to, asset = asset, delta = n, reason = reason }
    end

    for _, line in ipairs(lines) do
        reason = line.reason or args.reason
        if line.kind == "item" then
            local grams = weights(line.item)
            if grams == nil then return nil, "unknown_item" end
            if M.accountKind(line.from) == "container" then
                stack(line.from, line.item, -line.count)
                container(line.from).weightDelta = container(line.from).weightDelta - grams * line.count
            end
            if M.accountKind(line.to) == "container" then
                stack(line.to, line.item, line.count)
                container(line.to).weightDelta = container(line.to).weightDelta + grams * line.count
            end
            journalPair(line.from, line.to, line.item, line.count)
        elseif line.kind == "money" then
            if M.accountKind(line.from) == "wallet" then wallet(line.from, -line.amount) end
            if M.accountKind(line.to) == "wallet" then wallet(line.to, line.amount) end
            journalPair(line.from, line.to, "money", line.amount)
        elseif line.kind == "instance" then
            local created = M.accountKind(line.from) == "system"
            local current = (not created) and instanceOf(line.instance) or nil
            if not created and (current == nil or current.container ~= line.from) then
                return nil, "instance_unavailable"
            end
            local item = created and line.item or current.item
            local grams = weights(item)
            if grams == nil then return nil, "unknown_item" end
            if insts[line.instance] then return nil, "invalid_spec" end
            local meta
            if created then
                meta = line.meta or {}
            else
                local merged, why = M.resolveMeta(current.meta, line.meta, line.metaPatch)
                if why then return nil, why end
                meta = merged
            end
            insts[line.instance] = {
                id = line.instance, item = item, from = line.from, to = line.to,
                create = created or nil, meta = meta,
                expectVersion = (not created) and current.version or nil,
            }
            if not created then container(line.from).weightDelta = container(line.from).weightDelta - grams end
            if M.accountKind(line.to) == "container" then
                container(line.to).weightDelta = container(line.to).weightDelta + grams
            end
            journalPair(line.from, line.to, "inst:" .. line.instance, 1)
        elseif line.kind == "meta" then
            local current = instanceOf(line.instance)
            if current == nil or current.container ~= line.at then return nil, "instance_unavailable" end
            if insts[line.instance] then return nil, "invalid_spec" end
            local meta, why = M.resolveMeta(current.meta, line.meta, line.metaPatch)
            if why then return nil, why end
            insts[line.instance] = {
                id = line.instance, item = current.item, from = line.at, to = line.at,
                meta = meta, expectVersion = current.version,
            }
            container(line.at)
            journal[#journal + 1] = { account = line.at, asset = "inst:" .. line.instance, delta = 0, reason = reason }
        elseif line.kind == "capacity" then
            return nil, "invalid_spec" -- envelopes never reach a commit
        end
    end

    local plan = {
        opId = args.opId, kind = args.kind or "", actor = args.actor, resource = args.resource or "",
        hash = args.hash, createdAt = args.now or 0, receipt = args.receipt,
        containers = {}, stacks = {}, wallets = {}, instances = {}, journal = journal,
    }
    local expect = args.expect or {}
    for _, id in ipairs(sortedKeys(containers)) do
        local c = containers[id]
        c.expectVersion = expect[id]
        plan.containers[#plan.containers + 1] = c
    end
    for _, key in ipairs(sortedKeys(stacks)) do
        if stacks[key].delta ~= 0 then plan.stacks[#plan.stacks + 1] = stacks[key] end
    end
    for _, id in ipairs(sortedKeys(wallets)) do
        local w = wallets[id]
        w.expectVersion = expect[id]
        if w.delta ~= 0 or w.expectVersion ~= nil then plan.wallets[#plan.wallets + 1] = w end
    end
    for _, id in ipairs(sortedKeys(insts)) do plan.instances[#plan.instances + 1] = insts[id] end
    -- An expectation on an account the lines never touch still has to be checked.
    for account, version in pairs(expect) do
        local kind = M.accountKind(account)
        if kind == "container" and not containers[account] then
            plan.containers[#plan.containers + 1] = { id = account, weightDelta = 0, expectVersion = version }
        elseif kind == "wallet" and not wallets[account] then
            plan.wallets[#plan.wallets + 1] = { id = account, delta = 0, expectVersion = version }
        end
    end
    table.sort(plan.containers, function(a, b) return a.id < b.id end)
    table.sort(plan.wallets, function(a, b) return a.id < b.id end)
    return plan
end

-- Statement budget of a plan, matching server/sql_store.lua exactly
-- (tests/sql_plan_test.lua asserts the equality).
function M.estimateStatements(plan)
    local n = 1 -- operation row
    n = n + 2 * #plan.containers
    for _, s in ipairs(plan.stacks) do n = n + (s.delta < 0 and 2 or 1) end
    n = n + 2 * #plan.instances
    n = n + 2 * #plan.wallets
    n = n + math.ceil(#plan.journal / M.LIMITS.journalRowsPerStatement)
    return n
end

return M
