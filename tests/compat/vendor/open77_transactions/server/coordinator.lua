-- =============================================================================
-- open77_transactions -- server/coordinator.lua
-- =============================================================================
-- The single writer of the A13 contract
-- (docs/world-interaction/a13-transaction-contract.md, sections 3-5):
--
--   reserve(spec)        validate, load mirrors, HOLD (memory only)
--   commit(opId, final)  narrow inside the envelope, build ONE plan, submit it
--                        as one transaction; mirror changes only after the ack
--   cancel / expiry      release holds; nothing durable ever happened
--   in_doubt             an ambiguous completion is never "failed": fence the
--                        opId (tombstone insert) and settle on what it finds
--   replay               a committed opId returns its stored receipt
--
-- Continuation style: every call takes `done(result | nil, reason, info)` and
-- may complete synchronously or later, when the store answers. The runtime
-- wiring (exports, MySQL, tunables, onResourceStop) is server/main.lua; this
-- file touches no Open77 native, so the offline suites drive it directly.
--
-- Global: Open77TxCoordinator. Not proven in game.
-- =============================================================================

Open77TxCoordinator = {}
local M = Open77TxModel
local C = {}
C.__index = C

local REUSABLE = { failed = true, expired = true, cancelled = true }
local REPLAY_CHECK = {
    insufficient_items = true, insufficient_funds = true, instance_unavailable = true,
    capacity_exceeded = true, stale_version = true, balance_limit = true,
}
local RETRYABLE = { conflict = true, busy = true, in_doubt = true, store_unavailable = true, mint_cap_exceeded = true }
local TERMINAL = { committed = true, failed = true, cancelled = true, expired = true, aborted = true }

local function failure(done, reason, info)
    info = info or {}
    info.retryable = RETRYABLE[reason] == true
    if done then done(nil, reason, info) end
    return nil, reason, info
end

local function base36(n)
    local digits = "0123456789abcdefghijklmnopqrstuvwxyz"
    if n == 0 then return "0" end
    local out = {}
    while n > 0 do
        local d = n % 36
        out[#out + 1] = digits:sub(d + 1, d + 1)
        n = n // 36
    end
    return string.reverse(table.concat(out))
end

-- Error texts that say "the database did not answer" (as opposed to "the
-- database answered no"). They mark the store down until a probe succeeds,
-- because the bridge's own readiness never goes back (D5).
local function looksUnreachable(detail)
    local text = tostring(detail or "")
    return text:find("unreachable", 1, true) ~= nil or text:find("unavailable", 1, true) ~= nil
        or text:find("(SQL 0)", 1, true) ~= nil or text:find("(SQL 2013)", 1, true) ~= nil
        or text:find("(SQL 2006)", 1, true) ~= nil or text:find("timeout", 1, true) ~= nil
end

function Open77TxCoordinator.new(options)
    assert(type(options) == "table" and type(options.store) == "table", "store required")
    local self = setmetatable({
        store = options.store,
        now = options.now or function() return 0 end,
        serverTag = options.serverTag or "srv",
        acl = options.acl,                 -- function(resource, namespace) -> boolean
        policy = options.policy,           -- mint policy (server/policy.lua); nil = unrestricted (tests)
        onCommitted = options.onCommitted, -- function(receipt, accounts, op)
        onWorld = options.onWorld,         -- function(id, change, meta)
        log = options.log or function() end,
        -- Runs a continuation later (the runtime's work queue). One answer can
        -- release hundreds of waiters -- every reserve that queued behind the
        -- first load of a hot wallet -- and running them all inside one step
        -- would blow the per-pass instruction quota. Offline: immediate.
        defer = options.defer or function(fn) fn() end,
        maxCommitAttempts = options.maxCommitAttempts or 4,
        commitDeadlineMs = options.commitDeadlineMs or 20000,
        probeIntervalMs = options.probeIntervalMs or 2000,
        opRetentionMs = options.opRetentionMs or 600000,
        defs = {},
        accounts = {},
        instanceIndex = {},                -- [instanceId] = containerId (mirror)
        loading = {},
        ops = {},
        receipts = {}, receiptOrder = {}, receiptHead = 1, receiptLimit = options.receiptLimit or 4096,
        counter = 0, submissions = 0, grants = {},
        down = false, nextProbeAt = 0,
        stats = {
            reserves = 0, refusals = 0, commits = 0, replays = 0, conflicts = 0, transientRetries = 0,
            inDoubt = 0, fencedAborted = 0, fencedCommitted = 0, deadlineExpired = 0, storeDown = 0,
        },
    }, C)
    self.bootMs = self.now()
    return self
end

-- ---------------------------------------------------------------------------
-- Definitions (B1 owns them; A13 needs weight and uniqueness only)
-- ---------------------------------------------------------------------------
function C:define(items, definer)
    local registered, rejected, collisions = 0, 0, {}
    if type(items) ~= "table" then return nil, "invalid_spec" end
    for id, def in pairs(items) do
        local grams = type(def) == "table" and math.tointeger(def.weightG) or nil
        if not M.validItemId(id) or not grams or grams < 0 or grams > M.LIMITS.maxWeightG then
            rejected = rejected + 1
        elseif self.defs[id] and self.defs[id].definer ~= definer then
            -- Last writer does NOT win: a collision between definers is refused and reported.
            rejected = rejected + 1
            collisions[#collisions + 1] = id
        else
            self.defs[id] = { weightG = grams, unique = def.unique == true, definer = definer }
            registered = registered + 1
        end
    end
    table.sort(collisions)
    return registered, rejected, collisions
end

function C:definition(id)
    local d = self.defs[id]
    if not d then return nil end
    return { weightG = d.weightG, unique = d.unique, definer = d.definer }
end

function C:newOpId()
    self.counter = self.counter + 1
    return string.format("%s-%s-%s", self.serverTag, base36(self.bootMs), base36(self.counter))
end

-- `world:` ids are minted here, never chosen by a caller: <tag>.<boot>.<n>
-- is unique per server as long as `serverTag` is unique among the servers
-- sharing one database, and its first segment is never all digits (the
-- durable-key lint).
function C:newWorldId()
    self.counter = self.counter + 1
    return string.format("world:%s.%s.%s", self.serverTag, base36(self.bootMs), base36(self.counter))
end

-- ---------------------------------------------------------------------------
-- Store health (D5: the bridge never un-readies, so the coordinator tracks it)
-- ---------------------------------------------------------------------------
function C:_storeFailed(detail)
    if looksUnreachable(detail) and not self.down then
        self.down = true
        self.stats.storeDown = self.stats.storeDown + 1
        self.nextProbeAt = self.now() + self.probeIntervalMs
        self.log("WRN", "store unreachable; mutating calls answer store_unavailable until a probe succeeds")
    end
end

function C:_storeAnswered()
    if self.down then
        self.down = false
        self.log("INF", "store reachable again")
    end
end

function C:health()
    return { down = self.down, active = self:_activeCount(), stats = M.deepCopy(self.stats) }
end

-- ---------------------------------------------------------------------------
-- Mirrors
-- ---------------------------------------------------------------------------
function C:_account(id)
    local a = self.accounts[id]
    if a then return a end
    local kind, ns = M.accountKind(id)
    a = {
        id = id, kind = kind, ns = ns, loaded = false, exists = false, version = 0,
        capacityG = 0, weightG = 0, stacks = {}, instances = {}, balance = 0,
        heldItems = {}, heldWeightIn = 0, heldMoney = 0, heldInstances = {},
        pendingItems = {}, pendingMoney = 0,
        inflight = 0, stale = false,
    }
    self.accounts[id] = a
    return a
end

function C:_mirror(id, row)
    local a = self:_account(id)
    a.loaded, a.stale = true, false
    a.exists = row.exists == true
    a.version = row.version or 0
    if a.kind == "container" then
        for iid in pairs(a.instances) do
            if self.instanceIndex[iid] == id then self.instanceIndex[iid] = nil end
        end
        a.capacityG = row.capacityG or 0
        a.weightG = row.weightG or 0
        a.stacks = M.deepCopy(row.stacks or {})
        a.instances = M.deepCopy(row.instances or {})
        a.meta = M.deepCopy(row.meta)
        a.expiresAt = row.expiresAt
        for iid in pairs(a.instances) do self.instanceIndex[iid] = id end
        self.defer(function() self:_maybeReweigh(id) end)
    elseif a.kind == "wallet" then
        a.balance = row.balance or 0
    end
    return a
end

function C:_load(id, cb)
    local waiting = self.loading[id]
    if waiting then waiting[#waiting + 1] = cb; return end
    waiting = { cb }
    self.loading[id] = waiting
    -- A read that started before one of our own commits was applied must not
    -- overwrite the mirror afterwards: the epoch moves on every apply, and a
    -- result from an older epoch (or one landing under an in-flight commit) is
    -- dropped and the account re-read.
    local a = self:_account(id)
    local epoch = a.epoch or 0
    self.store:load(id, function(row, err)
        self.loading[id] = nil
        if row and not err then
            self:_storeAnswered()
            if a.loaded and ((a.epoch or 0) ~= epoch or a.inflight > 0) then
                a.stale = true
                if a.inflight == 0 then
                    return self:_load(id, function(e)
                        for _, w in ipairs(waiting) do self.defer(function() w(e) end) end
                    end)
                end
            else
                self:_mirror(id, row)
            end
        else
            self:_storeFailed(err or "unavailable")
        end
        local result = err or (row == nil and "unavailable") or nil
        for _, w in ipairs(waiting) do self.defer(function() w(result) end) end
    end)
end

function C:_ensureLoaded(ids, done)
    local missing = {}
    for _, id in ipairs(ids) do
        if M.accountKind(id) ~= "system" then
            local a = self.accounts[id]
            if not a or not a.loaded then missing[#missing + 1] = id end
        end
    end
    if #missing == 0 then return done(true) end
    -- Loads are always attempted, even while the store is marked down: one
    -- that succeeds is itself the proof the outage is over.
    local remaining, failed = #missing, false
    for _, id in ipairs(missing) do
        self:_load(id, function(err)
            if err then failed = true end
            remaining = remaining - 1
            if remaining == 0 then
                if failed then done(nil, "store_unavailable") else done(true) end
            end
        end)
    end
end

function C:isLoaded(id)
    local a = self.accounts[id]
    return a ~= nil and a.loaded
end

-- ---------------------------------------------------------------------------
-- Weight drift. Item weights are definitions (B1), not data: a definition
-- may change between boots while containers keep the weight their contents
-- had when they moved. Left alone, a heavier definition makes the last
-- debit drive weight_g below zero (its guard then refuses forever) and a
-- lighter one leaves phantom weight. So a loaded container whose contents
-- are all defined is re-derived; a difference is committed as a `reweigh`
-- operation (weight only, journaled against sys:reweigh, compare-and-set on
-- the version, no capacity guard: an over-full container may always empty).
-- Items not defined yet are left alone until a later load.
-- ---------------------------------------------------------------------------
function C:_derivedWeight(a)
    local total = 0
    for item, n in pairs(a.stacks) do
        local grams = self:_weight(item)
        if grams == nil then return nil end
        total = total + grams * n
    end
    for _, rec in pairs(a.instances) do
        local grams = self:_weight(rec.item)
        if grams == nil then return nil end
        total = total + grams
    end
    return total
end

function C:_maybeReweigh(id)
    local a = self.accounts[id]
    if not a or a.kind ~= "container" or not a.loaded or not a.exists or a.inflight > 0 or a.reweighing then return end
    if self.down or (a.reweighAttempts or 0) >= 3 then return end
    local derived = self:_derivedWeight(a)
    if derived == nil or derived == a.weightG then return end
    local delta = derived - a.weightG
    a.reweighing = true
    a.reweighAttempts = (a.reweighAttempts or 0) + 1
    self.counter = self.counter + 1
    local opId = string.format("reweigh-%s-%s-%s", self.serverTag, base36(self.bootMs), base36(self.counter))
    local now = self.now()
    local hash = M.fnv1a64(M.encode({ id, delta, a.version }))
    local plan = {
        opId = opId, kind = "reweigh", resource = "open77_transactions", hash = hash, createdAt = now,
        receipt = { opId = opId, kind = "reweigh", state = "committed", at = now, lines = {}, account = id,
            weightDeltaG = delta, hash = hash },
        containers = { { id = id, weightDelta = delta, expectVersion = a.version, reweigh = true } },
        stacks = {}, wallets = {}, instances = {},
        journal = { { account = id, asset = "weight_g", delta = delta },
            { account = "sys:reweigh", asset = "weight_g", delta = -delta } },
    }
    local op = {
        opId = opId, kind = "reweigh", resource = "open77_transactions", state = "committing", hash = hash,
        finalHash = hash, plan = plan, touched = { id }, waiters = {}, attempts = 0, createdAt = now,
        reweigh = id,
    }
    self.ops[opId] = op
    self.log("WRN", ("%s: stored weight %d g, contents weigh %d g with the current definitions; reweighing")
        :format(id, a.weightG, derived))
    self:_inflight(op, 1)
    self:_submit(op)
end

-- Reload from the store, but never under an in-flight commit: a row read while
-- our own commit is landing would be applied twice. Defer instead (stale).
function C:_reload(ids)
    for _, id in ipairs(ids) do
        local a = self.accounts[id]
        if a and a.kind ~= "system" then
            if a.inflight > 0 then a.stale = true else self:_load(id, function() end) end
        end
    end
end

-- Loads (when needed) and returns the snapshot.
function C:load(id, done)
    done = done or function() end
    local kind = M.accountKind(id)
    if not kind or kind == "system" then return failure(done, "invalid_account") end
    if M.durableKeyProblem(id) then return failure(done, "invalid_key") end
    self:_ensureLoaded({ id }, function(ok, why)
        if not ok then return failure(done, why) end
        done(self:read(id))
    end)
end

-- Opens (creates or re-capacities) a char/veh/stash container, or loads a
-- wallet. `world:` containers are minted by openWorld, never opened by id.
function C:open(id, props, resource, done)
    done = done or function() end
    local kind, ns = M.accountKind(id)
    if not kind or kind == "system" then return failure(done, "invalid_account") end
    if M.durableKeyProblem(id) then return failure(done, "invalid_key") end
    if ns == "world" then return failure(done, "invalid_account", { detail = "use openWorld" }) end
    if resource ~= nil and self.acl and not self.acl(resource, ns, id) then return failure(done, "namespace_denied") end
    if kind == "wallet" then
        return self:_ensureLoaded({ id }, function(ok, why)
            if not ok then return failure(done, why) end
            done(self:read(id))
        end)
    end
    if self.down then return failure(done, "store_unavailable") end
    local capacity = math.tointeger(props and props.capacityG)
    if not capacity or capacity < 0 or capacity > M.LIMITS.maxWeightG then return failure(done, "invalid_spec") end
    local slots = props.slots ~= nil and math.tointeger(props.slots) or nil
    if props.slots ~= nil and (not slots or slots < 1 or slots > 1024) then return failure(done, "invalid_spec") end
    if props.meta ~= nil and (type(props.meta) ~= "table" or #M.encode(props.meta) > M.LIMITS.maxMetaBytes) then
        return failure(done, "invalid_spec", { detail = "meta" })
    end
    local meta = props.meta ~= nil and M.deepCopy(props.meta) or nil
    self.store:openContainer(id, { capacityG = capacity, slots = slots, meta = meta }, function(ok, err)
        if not ok then
            self:_storeFailed(err)
            return failure(done, "store_unavailable", { detail = err })
        end
        self:_storeAnswered()
        local a = self.accounts[id]
        if a and a.inflight > 0 then
            a.stale = true
            a.capacityG = capacity
            if meta ~= nil then a.meta = meta end
            return done(self:read(id))
        end
        self:_load(id, function(lerr)
            if lerr then return failure(done, "store_unavailable") end
            done(self:read(id))
        end)
    end)
end

local function validWorldMeta(meta)
    if meta == nil then return true end
    if type(meta) ~= "table" then return false end
    local ok, encoded = pcall(M.encode, meta)
    return ok and #encoded <= M.LIMITS.maxMetaBytes
end

-- Mints a `world:` container for a framework-owned physical drop (a crate, a
-- ground pile). props = { capacityG, meta?, expiresAt?, slots? }. The prop and
-- the interaction target are projections the caller re-creates from `meta`.
function C:openWorld(props, resource, done)
    done = done or function() end
    if type(props) ~= "table" then return failure(done, "invalid_spec") end
    if resource ~= nil and self.acl and not self.acl(resource, "world") then return failure(done, "namespace_denied") end
    if self.down then return failure(done, "store_unavailable") end
    local capacity = math.tointeger(props.capacityG)
    if not capacity or capacity < 0 or capacity > M.LIMITS.maxWeightG then return failure(done, "invalid_spec") end
    if not validWorldMeta(props.meta) then return failure(done, "invalid_spec", { detail = "meta" }) end
    local expiresAt = props.expiresAt ~= nil and math.tointeger(props.expiresAt) or nil
    if props.expiresAt ~= nil and not expiresAt then return failure(done, "invalid_spec") end
    local slots = props.slots ~= nil and math.tointeger(props.slots) or nil
    if props.slots ~= nil and (not slots or slots < 1 or slots > 1024) then return failure(done, "invalid_spec") end
    local id = self:newWorldId()
    local meta = props.meta ~= nil and M.deepCopy(props.meta) or nil
    self.store:openContainer(id, { capacityG = capacity, meta = meta, expiresAt = expiresAt, slots = slots,
        create = true }, function(ok, err)
        if not ok then
            self:_storeFailed(err)
            return failure(done, "store_unavailable", { detail = err })
        end
        self:_storeAnswered()
        self:_mirror(id, { exists = true, capacityG = capacity, weightG = 0, version = 0, stacks = {},
            instances = {}, meta = meta, expiresAt = expiresAt })
        if self.onWorld then self.onWorld(id, "opened", M.deepCopy(meta)) end
        done(self:read(id))
    end)
end

-- Replaces a container's metadata (any container; a world: container's
-- metadata is what its projection is rebuilt from).
function C:setMeta(id, meta, resource, done)
    done = done or function() end
    local kind, ns = M.accountKind(id)
    if kind ~= "container" then return failure(done, "invalid_account") end
    if resource ~= nil and self.acl and not self.acl(resource, ns, id) then return failure(done, "namespace_denied") end
    if type(meta) ~= "table" or not validWorldMeta(meta) then return failure(done, "invalid_spec") end
    if self.down then return failure(done, "store_unavailable") end
    self:_ensureLoaded({ id }, function(ok, why)
        if not ok then return failure(done, why) end
        local a = self.accounts[id]
        if not a.exists then return failure(done, "unknown_account") end
        self.store:setMeta(id, meta, function(stored, err)
            if not stored then
                self:_storeFailed(err)
                return failure(done, "store_unavailable", { detail = err })
            end
            self:_storeAnswered()
            a.meta = M.deepCopy(meta)
            if ns == "world" and self.onWorld then self.onWorld(id, "meta", M.deepCopy(meta)) end
            done(self:read(id))
        end)
    end)
end

-- Closes an EMPTY world container (the row is deleted). A container that
-- still holds something is refused with `container_not_empty`: move its
-- contents first (for example into a `sys:` sink, which is journaled).
function C:close(id, resource, done)
    done = done or function() end
    local _, ns = M.accountKind(id)
    if ns ~= "world" then return failure(done, "invalid_account") end
    if resource ~= nil and self.acl and not self.acl(resource, "world", id) then return failure(done, "namespace_denied") end
    if self.down then return failure(done, "store_unavailable") end
    self:_ensureLoaded({ id }, function(ok, why)
        if not ok then return failure(done, why) end
        local a = self.accounts[id]
        if not a.exists then return failure(done, "unknown_account") end
        if a.inflight > 0 or a.heldWeightIn > 0 or next(a.heldItems) ~= nil or next(a.heldInstances) ~= nil then
            return failure(done, "busy")
        end
        if a.weightG ~= 0 or next(a.stacks) ~= nil or next(a.instances) ~= nil then
            return failure(done, "container_not_empty")
        end
        self.store:closeContainer(id, function(outcome, err)
            if not outcome then
                self:_storeFailed(err)
                return failure(done, "store_unavailable", { detail = err })
            end
            self:_storeAnswered()
            if outcome ~= "closed" then
                self:_reload({ id })
                return failure(done, "container_not_empty")
            end
            self.accounts[id] = nil
            if self.onWorld then self.onWorld(id, "closed", nil) end
            done(true)
        end)
    end)
end

function C:listWorld(after, limit, done)
    return self:list("world", after, limit, done)
end

-- Keyset page of the containers of one namespace (char, veh, stash, world),
-- ordered by id: { id, capacityG, weightG, version, meta, expiresAt }.
function C:list(namespace, after, limit, done)
    done = done or function() end
    if M.NAMESPACES[namespace] ~= "container" then return failure(done, "invalid_account") end
    limit = math.tointeger(limit) or 100
    if limit < 1 or limit > 500 then return failure(done, "invalid_spec") end
    if after ~= nil and type(after) ~= "string" then return failure(done, "invalid_spec") end
    if self.down then return failure(done, "store_unavailable") end
    self.store:listContainers(namespace, after or "", limit, function(rows, err)
        if not rows then
            self:_storeFailed(err)
            return failure(done, "store_unavailable", { detail = err })
        end
        self:_storeAnswered()
        done(rows)
    end)
end

-- Loads on demand (never creates) and answers the snapshot; an account with
-- no row answers `unknown_account`. Synchronous when the mirror is loaded.
function C:readAccount(id, done)
    done = done or function() end
    local kind = M.accountKind(id)
    if not kind or kind == "system" then return failure(done, "invalid_account") end
    if M.durableKeyProblem(id) then return failure(done, "invalid_key") end
    self:_ensureLoaded({ id }, function(ok, why)
        if not ok then return failure(done, why) end
        local a = self.accounts[id]
        if not a or not a.exists then return failure(done, "unknown_account") end
        done(self:read(id))
    end)
end

function C:read(id)
    local a = self.accounts[id]
    if not a or not a.loaded then return nil, "not_loaded" end
    return {
        id = id, kind = a.kind, exists = a.exists, version = a.version,
        capacityG = a.capacityG, weightG = a.weightG, items = M.deepCopy(a.stacks),
        instances = M.deepCopy(a.instances), balance = a.balance, meta = M.deepCopy(a.meta),
        expiresAt = a.expiresAt,
        held = { items = M.deepCopy(a.heldItems), weightIn = a.heldWeightIn, money = a.heldMoney },
        -- Deltas of operations already submitted (committing or in doubt):
        -- what a write-behind facade shows before the acknowledgement.
        pending = { items = M.deepCopy(a.pendingItems), money = a.pendingMoney },
        stale = a.stale or nil,
    }
end

-- ---------------------------------------------------------------------------
-- Holds
-- ---------------------------------------------------------------------------
local function linesAccounts(lines, expect)
    local seen, out = {}, {}
    local function add(id) if id and not seen[id] then seen[id] = true; out[#out + 1] = id end end
    for _, l in ipairs(lines) do add(l.from); add(l.to); add(l.at) end
    for id in pairs(expect or {}) do add(id) end
    table.sort(out)
    return out
end

function C:_weight(item)
    local d = self.defs[item]
    return d and d.weightG or nil
end

function C:_computeHolds(lines, expect)
    local items, money, net, inst, credits = {}, {}, {}, {}, {}
    local function addItems(acct, item, n)
        items[acct] = items[acct] or {}
        items[acct][item] = (items[acct][item] or 0) + n
    end
    local function addNet(acct, grams) net[acct] = (net[acct] or 0) + grams end
    local function container(id)
        local a = self.accounts[id]
        if not a or not a.exists then return nil end
        return a
    end
    for _, l in ipairs(lines) do
        if l.kind == "item" then
            local grams = self:_weight(l.item)
            if not grams then return nil, "unknown_item" end
            if M.accountKind(l.from) == "container" then
                if not container(l.from) then return nil, "unknown_account" end
                addItems(l.from, l.item, l.count)
                addNet(l.from, -grams * l.count)
            end
            if M.accountKind(l.to) == "container" then
                if not container(l.to) then return nil, "unknown_account" end
                addNet(l.to, grams * l.count)
            end
        elseif l.kind == "money" then
            if M.accountKind(l.from) == "wallet" then money[l.from] = (money[l.from] or 0) + l.amount end
            if M.accountKind(l.to) == "wallet" then credits[l.to] = (credits[l.to] or 0) + l.amount end
        elseif l.kind == "capacity" then
            if not container(l.to) then return nil, "unknown_account" end
            addNet(l.to, l.capacityG)
        elseif l.kind == "instance" then
            local created = M.accountKind(l.from) == "system"
            if created then
                local grams = self:_weight(l.item)
                if not grams then return nil, "unknown_item" end
                if self.instanceIndex[l.instance] then return nil, "instance_unavailable" end
                if M.accountKind(l.to) == "container" then
                    if not container(l.to) then return nil, "unknown_account" end
                    addNet(l.to, grams)
                end
            else
                local a = container(l.from)
                if not a then return nil, "unknown_account" end
                local rec = a.instances[l.instance]
                if not rec or a.heldInstances[l.instance] or inst[l.instance] then return nil, "instance_unavailable" end
                local grams = self:_weight(rec.item)
                if not grams then return nil, "unknown_item" end
                inst[l.instance] = l.from
                addNet(l.from, -grams)
                if M.accountKind(l.to) == "container" then
                    if not container(l.to) then return nil, "unknown_account" end
                    addNet(l.to, grams)
                end
            end
        elseif l.kind == "meta" then
            local a = container(l.at)
            if not a then return nil, "unknown_account" end
            if not a.instances[l.instance] or a.heldInstances[l.instance] or inst[l.instance] then
                return nil, "instance_unavailable"
            end
            inst[l.instance] = l.at
        end
    end
    for acct, perItem in pairs(items) do
        local a = self.accounts[acct]
        for item, n in pairs(perItem) do
            if (a.stacks[item] or 0) - (a.heldItems[item] or 0) < n then return nil, "insufficient_items" end
        end
    end
    for acct, n in pairs(money) do
        local a = self.accounts[acct]
        if not a or not a.exists or a.balance - a.heldMoney < n then return nil, "insufficient_funds" end
    end
    local weightIn = {}
    for acct, grams in pairs(net) do
        if grams > 0 then
            local a = self.accounts[acct]
            if a.weightG + a.heldWeightIn + grams > a.capacityG then return nil, "capacity_exceeded" end
            weightIn[acct] = grams
        end
    end
    for acct, n in pairs(credits) do
        local a = self.accounts[acct]
        if a and a.balance + math.max(0, a.pendingMoney) + n > M.LIMITS.maxMoney then return nil, "balance_limit" end
    end
    for acct, version in pairs(expect or {}) do
        local a = self.accounts[acct]
        if not a or a.version ~= version then return nil, "stale_version" end
    end
    return { items = items, money = money, weightIn = weightIn, instances = inst }
end

function C:_applyHolds(op, sign)
    local h = op.holds
    if not h then return end
    for acct, perItem in pairs(h.items) do
        local a = self.accounts[acct]
        if a then
            for item, n in pairs(perItem) do
                local v = (a.heldItems[item] or 0) + sign * n
                a.heldItems[item] = v ~= 0 and v or nil
            end
        end
    end
    for acct, n in pairs(h.money) do
        local a = self.accounts[acct]
        if a then a.heldMoney = a.heldMoney + sign * n end
    end
    for acct, grams in pairs(h.weightIn) do
        local a = self.accounts[acct]
        if a then a.heldWeightIn = a.heldWeightIn + sign * grams end
    end
    for iid, acct in pairs(h.instances) do
        local a = self.accounts[acct]
        if a then a.heldInstances[iid] = sign > 0 and op.opId or nil end
    end
    op.holdsReleased = sign < 0
end

function C:_release(op)
    if op.holds and not op.holdsReleased then self:_applyHolds(op, -1) end
end

function C:_expireIfDue(op)
    if op.state == "reserved" and self.now() >= op.expiresAt then
        self:_release(op)
        self:_terminal(op, "expired", "expired")
    end
end

function C:_terminal(op, state, reason)
    if state == "committed" or state == "aborted" then self.grants[op.opId] = nil end
    op.state = state
    if reason ~= nil then op.reason = reason end
    op.endedAt = self.now()
end

-- ---------------------------------------------------------------------------
-- Reserve
-- ---------------------------------------------------------------------------
local function stateReason(op)
    if op.state == "failed" then return op.reason or "failed" end
    if op.state == "committing" then return "busy" end
    return op.state -- expired | cancelled | aborted | in_doubt
end

function C:_aclCheck(resource, lines, opId)
    if not self.acl then return true end
    local grant = opId and self.grants[opId]
    if grant and grant.expiresAt < self.now() then self.grants[opId], grant = nil, nil end
    for _, id in ipairs(linesAccounts(lines)) do
        local kind, ns = M.accountKind(id)
        if kind ~= "system" and not self.acl(resource, ns, id)
            and not (grant and grant.grantee == resource and grant.accounts[id]) then
            return false
        end
    end
    return true
end

-- Two-party grant (contract section 7.2): a resource that may write some
-- accounts lets another resource touch them in ONE named operation, for a
-- short time. The inventory owner authorizes the wallet's sale of its goods,
-- for example, without either resource gaining the other's namespace.
function C:authorize(opId, grantee, accounts, ttlMs, grantor)
    if not M.validOpId(opId) then return failure(nil, "invalid_op_id") end
    if type(grantee) ~= "string" or grantee == "" or type(accounts) ~= "table" or #accounts < 1 or #accounts > 16 then
        return failure(nil, "invalid_spec")
    end
    local ttl = M.clampTtl(ttlMs)
    if not ttl then return failure(nil, "invalid_spec") end
    local set = {}
    for _, id in ipairs(accounts) do
        local kind, ns = M.accountKind(id)
        if kind == nil or kind == "system" then return failure(nil, "invalid_account", { account = id }) end
        if M.durableKeyProblem(id) then return failure(nil, "invalid_key", { account = id }) end
        if self.acl and not self.acl(grantor, ns, id) then return failure(nil, "namespace_denied", { account = id }) end
        set[id] = true
    end
    self.grants[opId] = { grantee = grantee, grantor = grantor, accounts = set, expiresAt = self.now() + ttl }
    return true
end

-- History of one account, newest first (`before` pages back, in ms).
function C:history(id, options, done)
    done = done or function() end
    local kind = M.accountKind(id)
    if not kind then return failure(done, "invalid_account") end
    options = options or {}
    local limit = math.tointeger(options.limit) or 50
    if limit < 1 or limit > 200 then return failure(done, "invalid_spec") end
    local before = options.before ~= nil and math.tointeger(options.before) or (self.now() + 1)
    if not before then return failure(done, "invalid_spec") end
    if self.down then return failure(done, "store_unavailable") end
    self.store:history(id, before, limit, function(rows, err)
        if not rows then
            self:_storeFailed(err)
            return failure(done, "store_unavailable", { detail = err })
        end
        self:_storeAnswered()
        done(rows)
    end)
end

function C:reserve(spec, resource, done)
    done = done or function() end
    self.stats.reserves = self.stats.reserves + 1
    if type(spec) ~= "table" then return failure(done, "invalid_spec") end
    if not M.validOpId(spec.opId) then return failure(done, "invalid_op_id") end
    if spec.kind ~= nil and (type(spec.kind) ~= "string" or #spec.kind > 32) then return failure(done, "invalid_spec") end
    if spec.actor ~= nil and not M.accountKind(spec.actor) then return failure(done, "invalid_account") end
    if not M.validReason(spec.reason) then return failure(done, "invalid_spec", { detail = "reason" }) end
    local lines, reason = M.normalizeLines(spec.lines)
    if not lines then return failure(done, reason) end
    for _, id in ipairs(linesAccounts(lines, spec.expect)) do
        if M.durableKeyProblem(id) then return failure(done, "invalid_key", { account = id }) end
    end
    local ttl = M.clampTtl(spec.ttlMs)
    if not ttl then return failure(done, "invalid_spec") end
    if spec.expect ~= nil then
        if type(spec.expect) ~= "table" then return failure(done, "invalid_spec") end
        for acct, v in pairs(spec.expect) do
            if not M.accountKind(acct) or not math.tointeger(v) then return failure(done, "invalid_spec") end
        end
    end
    if not self:_aclCheck(resource, lines, spec.opId) then return failure(done, "namespace_denied") end
    local hash = M.hashLines(spec.kind, lines)

    local function existing(op)
        self:_expireIfDue(op)
        if REUSABLE[op.state] then
            -- Contract section 3.4: a definitive failure left no effect and no
            -- row, so the same opId is a fresh attempt. Only a fenced
            -- (aborted) opId is a tombstone.
            self.ops[spec.opId] = nil
            return self:reserve(spec, resource, done)
        end
        if op.hash ~= hash then return failure(done, "op_id_conflict", { opId = spec.opId }) end
        if op.state == "reserved" then
            return done({ opId = op.opId, state = "reserved", expiresAt = op.expiresAt, duplicate = true })
        end
        if op.state == "committed" then
            return failure(done, "already_committed", { opId = op.opId, receipt = M.deepCopy(op.receipt) })
        end
        return failure(done, stateReason(op), { opId = op.opId, state = op.state })
    end
    if self.ops[spec.opId] then return existing(self.ops[spec.opId]) end
    if self.receipts[spec.opId] then
        return failure(done, "already_committed", { opId = spec.opId, receipt = M.deepCopy(self.receipts[spec.opId]) })
    end
    -- After the replay lookups: a replay mints nothing, so it never needs cap room.
    if self.policy then
        local allowed, why = self.policy:check(resource or "", M.mintsOf(lines), self.now())
        if not allowed then return failure(done, why, { opId = spec.opId }) end
    end

    self:_ensureLoaded(linesAccounts(lines, spec.expect), function(ok, why)
        if not ok then return failure(done, why or "store_unavailable") end
        -- Another reserve of the same opId may have completed while we loaded.
        if self.ops[spec.opId] then return existing(self.ops[spec.opId]) end
        local holds, refusal = self:_computeHolds(lines, spec.expect)
        if not holds then
            self.stats.refusals = self.stats.refusals + 1
            -- An opId this VM never saw may have committed before a restart;
            -- its goods are gone, so the holds refuse. The operation row
            -- decides before a business refusal is reported.
            if REPLAY_CHECK[refusal] and not self.down then
                return self.store:readOp(spec.opId, function(row, err)
                    if err or not row then return failure(done, refusal, { opId = spec.opId }) end
                    self:_storeAnswered()
                    if row.state == "committed" then
                        local envelope = false
                        for _, l in ipairs(lines) do if l.kind == "capacity" then envelope = true end end
                        if row.hash ~= hash and not envelope then
                            return failure(done, "op_id_conflict", { opId = spec.opId })
                        end
                        local receipt = row.receipt or { opId = spec.opId, state = "committed" }
                        self:_remember(spec.opId, receipt)
                        return failure(done, "already_committed", { opId = spec.opId, receipt = M.deepCopy(receipt) })
                    end
                    if row.state == "aborted" then return failure(done, "aborted", { opId = spec.opId }) end
                    failure(done, refusal, { opId = spec.opId })
                end)
            end
            return failure(done, refusal, { opId = spec.opId })
        end
        -- Business refusals first (they hold whatever the store does); an
        -- unreachable store then refuses anything that would need it.
        if self.down then return failure(done, "store_unavailable", { opId = spec.opId }) end
        local now = self.now()
        local op = {
            opId = spec.opId, kind = spec.kind or "", actor = spec.actor, resource = resource or "",
            memo = spec.reason,
            lines = lines, hash = hash, holds = holds, expect = M.deepCopy(spec.expect),
            state = "reserved", createdAt = now, expiresAt = now + ttl,
        }
        self.ops[op.opId] = op
        self:_applyHolds(op, 1)
        done({ opId = op.opId, state = "reserved", expiresAt = op.expiresAt })
    end)
end

-- ---------------------------------------------------------------------------
-- Commit
-- ---------------------------------------------------------------------------
-- Final lines must fit inside the reserved envelope, so the holds already
-- taken cover every debit, and the net weight into each container does not
-- exceed its weight hold.
function C:_withinEnvelope(op, final)
    local itemBudget, moneyBudget, capBudget, instBudget = {}, {}, {}, {}
    for _, l in ipairs(op.lines) do
        if l.kind == "item" then
            local k = l.from .. "\0" .. l.to .. "\0" .. l.item
            itemBudget[k] = (itemBudget[k] or 0) + l.count
        elseif l.kind == "money" then
            local k = l.from .. "\0" .. l.to
            moneyBudget[k] = (moneyBudget[k] or 0) + l.amount
        elseif l.kind == "capacity" then
            local k = l.from .. "\0" .. l.to
            capBudget[k] = (capBudget[k] or 0) + l.capacityG
        else
            instBudget[l.instance] = l
        end
    end
    local net = {}
    local function addNet(acct, grams)
        if M.accountKind(acct) == "container" then net[acct] = (net[acct] or 0) + grams end
    end
    for _, l in ipairs(final) do
        if l.kind == "item" then
            local grams = self:_weight(l.item)
            if not grams then return false end
            local k = l.from .. "\0" .. l.to .. "\0" .. l.item
            local cap = l.from .. "\0" .. l.to
            if (itemBudget[k] or 0) >= l.count then
                itemBudget[k] = itemBudget[k] - l.count
            elseif M.accountKind(l.from) == "system" and (capBudget[cap] or 0) >= grams * l.count then
                capBudget[cap] = capBudget[cap] - grams * l.count
            else
                return false
            end
            addNet(l.from, -grams * l.count)
            addNet(l.to, grams * l.count)
        elseif l.kind == "money" then
            local k = l.from .. "\0" .. l.to
            if (moneyBudget[k] or 0) < l.amount then return false end
            moneyBudget[k] = moneyBudget[k] - l.amount
        elseif l.kind == "instance" then
            local reserved = instBudget[l.instance]
            if reserved and reserved.kind == "instance" and reserved.from == l.from and reserved.to == l.to then
                instBudget[l.instance] = nil
            elseif M.accountKind(l.from) == "system" then
                local grams = self:_weight(l.item)
                local cap = l.from .. "\0" .. l.to
                if not grams or (capBudget[cap] or 0) < grams then return false end
                capBudget[cap] = capBudget[cap] - grams
            else
                return false
            end
            local grams = self:_weight(l.item or (self:_instanceRecord(l.instance) or {}).item)
            if not grams then return false end
            if M.accountKind(l.from) ~= "system" then addNet(l.from, -grams) end
            addNet(l.to, grams)
        elseif l.kind == "meta" then
            local reserved = instBudget[l.instance]
            if not (reserved and reserved.kind == "meta" and reserved.at == l.at) then return false end
            instBudget[l.instance] = nil
        else
            return false -- capacity envelopes never commit
        end
    end
    for acct, grams in pairs(net) do
        if grams > 0 and grams > (op.holds.weightIn[acct] or 0) then return false end
    end
    return true
end

function C:_instanceRecord(iid)
    local acct = self.instanceIndex[iid]
    local a = acct and self.accounts[acct]
    local rec = a and a.instances[iid]
    if not rec then return nil end
    return { item = rec.item, version = rec.version, container = acct, meta = rec.meta }
end

local function touchedAccounts(plan)
    local seen, out = {}, {}
    local function add(id) if id and not seen[id] then seen[id] = true; out[#out + 1] = id end end
    for _, c in ipairs(plan.containers) do add(c.id) end
    for _, w in ipairs(plan.wallets) do add(w.id) end
    for _, i in ipairs(plan.instances) do
        if M.accountKind(i.from) == "container" then add(i.from) end
        if M.accountKind(i.to) == "container" then add(i.to) end
    end
    table.sort(out)
    return out
end

function C:_inflight(op, delta)
    for _, id in ipairs(op.touched or {}) do
        local a = self.accounts[id]
        if a then
            a.inflight = a.inflight + delta
            if a.inflight == 0 and a.stale then self:_reload({ id }) end
        end
    end
end

-- Submitted-but-unacknowledged deltas, for projected reads.
function C:_pending(op, sign)
    if op.pendingApplied == (sign > 0) then return end
    op.pendingApplied = sign > 0
    for _, s in ipairs(op.plan.stacks) do
        local a = self.accounts[s.container]
        if a then
            local v = (a.pendingItems[s.item] or 0) + sign * s.delta
            a.pendingItems[s.item] = v ~= 0 and v or nil
        end
    end
    for _, w in ipairs(op.plan.wallets) do
        local a = self.accounts[w.id]
        if a then a.pendingMoney = a.pendingMoney + sign * w.delta end
    end
end

function C:_replay(receipt)
    local r = M.deepCopy(receipt)
    r.replay = true
    self.stats.replays = self.stats.replays + 1
    return r
end

-- Bounded receipt cache (FIFO ring; the operation row is the durable copy).
function C:_remember(opId, receipt)
    if self.receipts[opId] == nil then
        local order = self.receiptOrder
        order[#order + 1] = opId
        while (#order - self.receiptHead + 1) > self.receiptLimit do
            self.receipts[order[self.receiptHead]] = nil
            order[self.receiptHead] = nil
            self.receiptHead = self.receiptHead + 1
        end
        if self.receiptHead > 4096 then
            local compact = {}
            for i = self.receiptHead, #order do compact[#compact + 1] = order[i] end
            self.receiptOrder, self.receiptHead = compact, 1
        end
    end
    self.receipts[opId] = M.deepCopy(receipt)
end

function C:commit(opId, final, resource, done)
    done = done or function() end
    if not M.validOpId(opId) then return failure(done, "invalid_op_id") end
    local op = self.ops[opId]
    if not op then
        local remembered = self.receipts[opId]
        if remembered then return done(self:_replay(remembered)) end
        if self.down then return failure(done, "store_unavailable", { opId = opId }) end
        -- Committed by a previous VM? Only the store knows (D6).
        return self.store:readOp(opId, function(row, err)
            if err then
                self:_storeFailed(err)
                return failure(done, "store_unavailable", { opId = opId })
            end
            self:_storeAnswered()
            if row and row.state == "committed" then
                self:_remember(opId, row.receipt or { opId = opId, state = "committed" })
                return done(self:_replay(row.receipt or { opId = opId, state = "committed" }))
            end
            if row and row.state == "aborted" then return failure(done, "aborted", { opId = opId }) end
            return failure(done, "unknown_operation", { opId = opId })
        end)
    end
    self:_expireIfDue(op)
    local finalLines
    if final ~= nil then
        if type(final) ~= "table" then return failure(done, "invalid_spec") end
        local lines, reason = M.normalizeLines(final.lines)
        if not lines then return failure(done, reason) end
        finalLines = lines
    end
    if op.state == "committed" then
        if finalLines and M.hashLines(op.kind, finalLines) ~= op.finalHash then
            return failure(done, "op_id_conflict", { opId = opId })
        end
        return done(self:_replay(op.receipt))
    end
    if op.state ~= "reserved" then return failure(done, stateReason(op), { opId = opId, state = op.state }) end
    if resource ~= nil and op.resource ~= "" and resource ~= op.resource then
        return failure(done, "not_owner", { opId = opId })
    end
    -- The reservation survives an outage: the caller may commit it once the
    -- store answers again (or let it expire).
    if self.down then return failure(done, "store_unavailable", { opId = opId, state = "reserved" }) end

    if not finalLines then
        finalLines = {}
        for _, l in ipairs(op.lines) do
            if l.kind ~= "capacity" then finalLines[#finalLines + 1] = l end
        end
        if #finalLines == 0 then return failure(done, "invalid_spec", { opId = opId }) end
    elseif not self:_withinEnvelope(op, finalLines) then
        return failure(done, "exceeds_reservation", { opId = opId })
    end

    local now = self.now()
    local finalHash = M.hashLines(op.kind, finalLines)
    local receipt = {
        opId = opId, kind = op.kind, actor = op.actor, state = "committed", at = now,
        lines = M.deepCopy(finalLines), hash = finalHash, reason = op.memo,
    }
    local plan, why = M.buildPlan({
        opId = opId, kind = op.kind, actor = op.actor, resource = op.resource, hash = finalHash, reason = op.memo,
        now = now, lines = finalLines, expect = op.expect, receipt = receipt,
        weights = function(item) return self:_weight(item) end,
        instances = function(iid) return self:_instanceRecord(iid) end,
    })
    if not plan then return failure(done, why, { opId = opId }) end
    if M.estimateStatements(plan) > M.LIMITS.maxStatements then
        return failure(done, "operation_too_large", { opId = opId })
    end
    -- Mint caps are charged at submission (in flight until the outcome is
    -- known), so two concurrent commits cannot both fit under one cap.
    local ticket
    if self.policy then
        local t, refusal = self.policy:begin(op.resource, M.mintsOf(finalLines), now)
        if t == nil then return failure(done, refusal, { opId = opId }) end
        ticket = t or nil -- false: nothing minted, nothing to settle
    end

    op.state = "committing"
    op.finalLines, op.finalHash, op.plan, op.mintTicket = finalLines, finalHash, plan, ticket
    op.touched = touchedAccounts(plan)
    op.waiters = { done }
    op.attempts = 0
    self:_inflight(op, 1)
    self:_pending(op, 1)
    self:_submit(op)
end

function C:_submit(op)
    op.attempts = op.attempts + 1
    self.submissions = self.submissions + 1
    local token = self.submissions
    op.submission = token
    op.submittedAt = self.now()
    self.store:commit(op.plan, function(ok, class, detail)
        -- A completion for a submission the coordinator has given up on (the
        -- deadline moved it to in_doubt) is ignored: the fence decides.
        if op.submission ~= token or op.state ~= "committing" then return end
        self:_onCommitResult(op, ok, class, detail)
    end)
end

-- A non-yielding reserve + commit for accounts whose mirrors are loaded: it
-- answers { opId, state } at once and the commit lands in the background.
-- This is what a write-behind facade (contract section 7.4 (i)) builds on.
function C:submit(spec, resource, done)
    done = done or function() end
    if type(spec) ~= "table" then return failure(done, "invalid_spec") end
    local lines = M.normalizeLines(spec.lines)
    if lines then
        for _, id in ipairs(linesAccounts(lines, spec.expect)) do
            if M.accountKind(id) ~= "system" and not self:isLoaded(id) then
                return failure(done, "not_loaded", { account = id })
            end
        end
    end
    local answered = false
    self:reserve(spec, resource, function(res, reason, info)
        if not res then
            answered = true
            if reason == "already_committed" and info and info.receipt then
                return done({ opId = spec.opId, state = "committed", replay = true })
            end
            return done(nil, reason, info)
        end
        self:commit(spec.opId, nil, resource, function(r, why, inf)
            if not answered then
                answered = true
                if r then return done({ opId = spec.opId, state = "committed" }) end
                return done(nil, why, inf)
            end
        end)
        if not answered then
            answered = true
            done({ opId = spec.opId, state = "committing" })
        end
    end)
end

function C:_notify(op, result, reason, info)
    local waiters = op.waiters or {}
    op.waiters = {}
    for _, w in ipairs(waiters) do
        if result then w(M.deepCopy(result)) else failure(w, reason, M.deepCopy(info or {})) end
    end
end

function C:_applyPlan(plan)
    for _, id in ipairs(touchedAccounts(plan)) do
        local a = self:_account(id)
        a.epoch = (a.epoch or 0) + 1
    end
    for _, c in ipairs(plan.containers) do
        local a = self:_account(c.id)
        a.weightG = a.weightG + c.weightDelta
        a.version = a.version + 1
        a.exists = true
    end
    for _, s in ipairs(plan.stacks) do
        local a = self:_account(s.container)
        local v = (a.stacks[s.item] or 0) + s.delta
        a.stacks[s.item] = v ~= 0 and v or nil
    end
    for _, i in ipairs(plan.instances) do
        local rec
        if i.create then
            rec = { item = i.item, meta = M.deepCopy(i.meta or {}), version = 1 }
        else
            local from = self.accounts[i.from]
            rec = from and from.instances[i.id]
            if from then from.instances[i.id] = nil end
            if self.instanceIndex[i.id] == i.from then self.instanceIndex[i.id] = nil end
            rec = rec or { item = i.item, meta = {}, version = i.expectVersion or 0 }
            rec.version = rec.version + 1
            if i.meta ~= nil then rec.meta = M.deepCopy(i.meta) end
        end
        if M.accountKind(i.to) == "container" then
            self:_account(i.to).instances[i.id] = rec
            self.instanceIndex[i.id] = i.to
        end
    end
    for _, w in ipairs(plan.wallets) do
        local a = self:_account(w.id)
        a.balance = a.balance + w.delta
        a.version = a.version + 1
        a.exists = true
    end
end

function C:_settleCommitted(op, applied, storedReceipt)
    if op.reweigh and self.accounts[op.reweigh] then self.accounts[op.reweigh].reweighing = nil end
    self:_pending(op, -1)
    if applied ~= false then self:_applyPlan(op.plan) end
    self:_release(op)
    self:_inflight(op, -1)
    self:_terminal(op, "committed")
    self.stats.commits = self.stats.commits + 1
    if self.policy and op.mintTicket then self.policy:settle(op.mintTicket, true, self.now()) end
    local receipt = M.deepCopy(storedReceipt or op.plan.receipt)
    receipt.versions = {}
    for _, id in ipairs(op.touched) do
        local a = self.accounts[id]
        if a then receipt.versions[id] = a.version end
    end
    -- applied == false: the row was committed by an earlier attempt or VM.
    receipt.replay = applied == false
    op.receipt = receipt
    op.plan, op.holds, op.lines = nil, nil, nil
    self:_remember(op.opId, receipt)
    if applied == false then self:_reload(op.touched) end
    self:_notify(op, receipt)
    if self.onCommitted then self.onCommitted(M.deepCopy(receipt), M.deepCopy(op.touched), op) end
end

function C:_settleFailed(op, reason, state)
    if op.reweigh and self.accounts[op.reweigh] then self.accounts[op.reweigh].reweighing = nil end
    if op.plan then self:_pending(op, -1) end
    self:_release(op)
    self:_inflight(op, -1)
    self:_terminal(op, state or "failed", reason)
    if self.policy and op.mintTicket then self.policy:settle(op.mintTicket, false, self.now()) end
    op.plan, op.holds = nil, nil
    self:_notify(op, nil, reason, { opId = op.opId, state = op.state })
end

function C:_onCommitResult(op, ok, class, detail)
    if ok then
        self:_storeAnswered()
        return self:_settleCommitted(op)
    end
    op.lastError = detail
    if class == "conflict" then
        self:_storeAnswered()
        self.stats.conflicts = self.stats.conflicts + 1
        -- 1062: a duplicate opId or a failed assertion. Ask the store which.
        return self.store:readOp(op.opId, function(row, err)
            if op.state ~= "committing" then return end
            if err then
                -- Definitively rolled back either way (1062 precedes COMMIT); the
                -- mirror may be stale, so refresh it.
                local touched = op.touched
                self:_settleFailed(op, "conflict")
                return self:_reload(touched)
            end
            if row and row.state == "committed" then
                if row.hash == op.finalHash then
                    -- Committed earlier (a previous VM). Do not re-apply: reload.
                    return self:_settleCommitted(op, false, row.receipt)
                end
                return self:_settleFailed(op, "op_id_conflict")
            end
            if row and row.state == "aborted" then return self:_settleFailed(op, "aborted", "aborted") end
            local touched = op.touched
            self:_settleFailed(op, "conflict")
            self:_reload(touched)
        end)
    end
    if class == "failed" then
        self:_storeAnswered()
        self.log("ERR", "commit " .. op.opId .. " failed definitively: " .. tostring(detail))
        return self:_settleFailed(op, "store_failed")
    end
    -- Refused at submission: never reached the database, nothing to fence.
    if class == "refused" then return self:_settleFailed(op, "store_unavailable") end
    -- Deadlock / lock-wait timeout: InnoDB rolled the whole transaction back,
    -- so the SAME plan is resubmitted (bounded). Exhausted retries settle as a
    -- retryable conflict; nothing landed, so the opId stays usable.
    if class == "transient" then
        self:_storeAnswered()
        self.stats.transientRetries = self.stats.transientRetries + 1
        if op.attempts < self.maxCommitAttempts then return self:_submit(op) end
        local touched = op.touched
        self:_settleFailed(op, "conflict")
        return self:_reload(touched)
    end
    -- Anything else is ambiguous: the COMMIT may have landed.
    self:_storeFailed(detail)
    self:_enterDoubt(op)
end

function C:_enterDoubt(op)
    op.state = "in_doubt"
    op.fenceAttempts = 0
    op.submission = nil
    self.stats.inDoubt = self.stats.inDoubt + 1
    self:_fence(op)
end

function C:_fence(op)
    if op.fencing then return end
    op.fencing = true
    self.store:fence(op.opId, { hash = op.finalHash, resource = op.resource }, function(outcome, row, err)
        op.fencing = false
        if op.state ~= "in_doubt" then return end
        if outcome == "inserted" then
            self:_storeAnswered()
            self.stats.fencedAborted = self.stats.fencedAborted + 1
            return self:_settleFailed(op, "store_unavailable", "aborted")
        end
        if outcome == "exists" and row then
            self:_storeAnswered()
            if row.state == "committed" and row.hash == op.finalHash then
                -- Our acknowledgement was lost; the effects are ours to apply once.
                self.stats.fencedCommitted = self.stats.fencedCommitted + 1
                return self:_settleCommitted(op, true, row.receipt)
            end
            if row.state == "committed" then return self:_settleFailed(op, "op_id_conflict") end
            return self:_settleFailed(op, "store_unavailable", "aborted")
        end
        -- Store unreachable: stay in doubt, keep the holds, retry with backoff.
        self:_storeFailed(err or "unavailable")
        op.fenceAttempts = op.fenceAttempts + 1
        op.nextFenceAt = self.now() + math.min(30000, 1000 * (2 ^ (op.fenceAttempts - 1)))
        self:_notify(op, nil, "in_doubt", { opId = op.opId, state = "in_doubt", detail = err })
    end)
end

-- ---------------------------------------------------------------------------
-- Transfer, cancel, status, maintenance
-- ---------------------------------------------------------------------------
function C:transfer(spec, resource, done)
    done = done or function() end
    self:reserve(spec, resource, function(res, reason, info)
        if not res then
            if reason == "already_committed" and info and info.receipt then return done(self:_replay(info.receipt)) end
            return done(nil, reason, info)
        end
        self:commit(spec.opId, nil, resource, done)
    end)
end

function C:cancel(opId, reason, resource)
    local op = self.ops[opId]
    if not op then return failure(nil, "unknown_operation", { opId = opId }) end
    if resource ~= nil and op.resource ~= "" and resource ~= op.resource then
        return failure(nil, "not_owner", { opId = opId })
    end
    self:_expireIfDue(op)
    if op.state ~= "reserved" then return failure(nil, stateReason(op), { opId = opId, state = op.state }) end
    self:_release(op)
    self:_terminal(op, "cancelled", reason or "cancelled")
    return true
end

-- status(opId, { resolve = true }) fences an opId this VM does not know, so a
-- transaction still in flight from a previous VM can never land afterwards.
function C:status(opId, options, done)
    done = done or function() end
    if not M.validOpId(opId) then return failure(done, "invalid_op_id") end
    local op = self.ops[opId]
    if op then
        self:_expireIfDue(op)
        return done({ state = op.state, reason = op.reason, receipt = M.deepCopy(op.receipt) })
    end
    if self.receipts[opId] then return done({ state = "committed", receipt = M.deepCopy(self.receipts[opId]) }) end
    local function fromRow(row)
        return { state = row.state, receipt = M.deepCopy(row.receipt) }
    end
    if options and options.resolve then
        return self.store:fence(opId, { hash = "", resource = "" }, function(outcome, row, err)
            if err or not outcome then
                self:_storeFailed(err or "unavailable")
                return failure(done, "store_unavailable", { opId = opId })
            end
            self:_storeAnswered()
            if outcome == "inserted" then return done({ state = "aborted" }) end
            if row.state == "committed" and row.receipt then self:_remember(opId, row.receipt) end
            return done(fromRow(row))
        end)
    end
    self.store:readOp(opId, function(row, err)
        if err then
            self:_storeFailed(err)
            return failure(done, "store_unavailable", { opId = opId })
        end
        self:_storeAnswered()
        if row then return done(fromRow(row)) end
        done({ state = "unknown" })
    end)
end

function C:_activeCount()
    local n = 0
    for _, op in pairs(self.ops) do if not TERMINAL[op.state] then n = n + 1 end end
    return n
end

function C:tick()
    local now = self.now()
    for opId, op in pairs(self.ops) do
        if op.state == "reserved" then
            self:_expireIfDue(op)
        elseif op.state == "committing" and op.submittedAt and now - op.submittedAt > self.commitDeadlineMs then
            -- The bridge has no deadline (D7). Past ours, the outcome is in
            -- doubt; the fence waits for the original if it is still running.
            self.stats.deadlineExpired = self.stats.deadlineExpired + 1
            self.log("WRN", "commit " .. opId .. " passed its deadline; resolving through the fence")
            self:_enterDoubt(op)
        elseif op.state == "in_doubt" and not op.fencing and op.nextFenceAt and now >= op.nextFenceAt then
            self:_fence(op)
        elseif TERMINAL[op.state] and op.endedAt and now - op.endedAt > self.opRetentionMs then
            -- The receipt cache and the operation row keep answering replays.
            self.ops[opId] = nil
        end
    end
    for opId, grant in pairs(self.grants) do
        if grant.expiresAt < now and not self.ops[opId] then self.grants[opId] = nil end
    end
    if self.down and now >= self.nextProbeAt and self.store.probe then
        self.nextProbeAt = now + self.probeIntervalMs
        self.store:probe(function(ok)
            if ok then self:_storeAnswered() end
        end)
    end
end

function C:onResourceStop(resource)
    local cancelled = 0
    for _, op in pairs(self.ops) do
        if op.state == "reserved" and op.resource == resource then
            self:_release(op)
            self:_terminal(op, "cancelled", "resource_stopped")
            cancelled = cancelled + 1
        end
    end
    return cancelled
end

-- Read-only view of one operation (tests and diagnostics).
function C:operation(opId)
    local op = self.ops[opId]
    if not op then return nil end
    return { state = op.state, reason = op.reason, expiresAt = op.expiresAt, resource = op.resource,
        attempts = op.attempts }
end

return Open77TxCoordinator
