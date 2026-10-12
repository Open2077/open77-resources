-- =============================================================================
-- open77_transactions -- server/memory_store.lua
-- =============================================================================
-- An in-memory stand-in for the SQL store, with the SAME observable semantics
-- as the statements server/sql_store.lua builds: one plan is applied
-- atomically or not at all; a duplicate opId, a debit below zero, a capacity
-- overflow, a stale version or a missing row fails the whole plan as
-- "conflict" (the 1062 the guard-table assertions raise); a fence inserts a
-- tombstone unless a row already exists.
--
-- It also injects the faults the coordinator must survive:
--   faults = { "unreachable_before" | "lost_ack" | "failed" | "refused" | "deadlock" | false, ... }
--     consumed one per commit, in order (false = no fault for that commit);
--   down = true          every call answers unavailable / ambiguous;
--   deferred (default)   commits and fences complete only when the
--                        test calls step()/flush(), so interleavings are
--                        explicit; runDetached() executes queued work but
--                        drops the callbacks (a coordinator that restarted,
--                        DatabaseService.cs:262-266); discard() loses queued
--                        work that never reached the database.
--
-- Used by the offline suites, and (non-deferred) as the in-memory core of the
-- lab_kvp store (server/kvp_store.lua). Global: Open77TxMemoryStore.
-- =============================================================================

Open77TxMemoryStore = {}
local M = Open77TxModel
local S = {}
S.__index = S

function Open77TxMemoryStore.new(options)
    options = options or {}
    return setmetatable({
        containers = {}, instances = {}, wallets = {}, ops = {}, journal = {},
        queue = {}, faults = {}, down = false, commits = 0,
        deferred = options.deferred ~= false,
        deferLoads = options.deferLoads == true,
        maxMoney = options.maxMoney or M.LIMITS.maxMoney,
    }, S)
end

local copy = M.deepCopy

function S:_run(fn, deferred)
    if deferred then self.queue[#self.queue + 1] = fn else fn() end
end

function S:pending() return #self.queue end

function S:step()
    local fn = table.remove(self.queue, 1)
    if fn then fn(false); return true end
    return false
end

function S:flush(limit)
    local n = 0
    while #self.queue > 0 and n < (limit or 10000) do self:step(); n = n + 1 end
    return n
end

-- Work already sent to the database still executes; nobody hears about it.
function S:runDetached()
    while #self.queue > 0 do
        local fn = table.remove(self.queue, 1)
        fn(true)
    end
end

-- Runs only the oldest queued request, detached (its caller is gone).
function S:stepDetached()
    local fn = table.remove(self.queue, 1)
    if fn then fn(true); return true end
    return false
end

-- Work that never reached the database is simply gone.
function S:discard() self.queue = {} end

-- ---------------------------------------------------------------------------
-- Reads
-- ---------------------------------------------------------------------------
function S:_row(id)
    local kind = M.accountKind(id)
    if kind == "container" then
        local c = self.containers[id]
        if not c then return { exists = false } end
        local instances = {}
        for iid, inst in pairs(self.instances) do
            if inst.container == id then
                instances[iid] = { item = inst.item, meta = copy(inst.meta), version = inst.version }
            end
        end
        return {
            exists = true, capacityG = c.capacityG, weightG = c.weightG, version = c.version,
            stacks = copy(c.stacks), instances = instances, meta = copy(c.meta), expiresAt = c.expiresAt,
            containerKind = c.kind,
        }
    elseif kind == "wallet" then
        local w = self.wallets[id]
        if not w then return { exists = false } end
        return { exists = true, balance = w.balance, version = w.version }
    end
    return { exists = false }
end

function S:load(id, cb)
    self:_run(function(detached)
        if self.down then if not detached then cb(nil, "unavailable") end return end
        local row = self:_row(id)
        if not detached then cb(row) end
    end, self.deferLoads)
end

function S:openContainer(id, props, cb)
    self:_run(function(detached)
        if self.down then if not detached then cb(nil, "unavailable") end return end
        local c = self.containers[id]
        if c and props.create then
            if not detached then cb(nil, "database_conflict (SQL 1062): duplicate container") end
            return
        end
        if not c then
            local _, ns = M.accountKind(id)
            self.containers[id] = { capacityG = props.capacityG, weightG = 0, version = 0, stacks = {},
                kind = ns, meta = copy(props.meta), expiresAt = props.expiresAt }
        else
            if props.capacityG ~= nil then c.capacityG = props.capacityG end
            if props.meta ~= nil then c.meta = copy(props.meta) end
        end
        self:_touched("c", id)
        if not detached then cb(true) end
    end, self.deferLoads)
end

function S:setMeta(id, meta, cb)
    self:_run(function(detached)
        if self.down then if not detached then cb(nil, "unavailable") end return end
        local c = self.containers[id]
        if c then c.meta = copy(meta); self:_touched("c", id) end
        if not detached then cb(true) end
    end, self.deferLoads)
end

function S:closeContainer(id, cb)
    self:_run(function(detached)
        if self.down then if not detached then cb(nil, "unavailable") end return end
        local c = self.containers[id]
        local empty = c ~= nil and c.weightG == 0 and next(c.stacks) == nil
        if empty then
            for _, inst in pairs(self.instances) do
                if inst.container == id then empty = false; break end
            end
        end
        if not empty then if not detached then cb("not_empty") end return end
        self.containers[id] = nil
        self:_touched("c", id)
        if not detached then cb("closed") end
    end, self.deferLoads)
end

function S:listContainers(kind, after, limit, cb)
    self:_run(function(detached)
        if self.down then if not detached then cb(nil, "unavailable") end return end
        local ids = {}
        for id, c in pairs(self.containers) do
            local _, ns = M.accountKind(id)
            if (c.kind or ns) == kind and id > (after or "") then ids[#ids + 1] = id end
        end
        table.sort(ids)
        local out = {}
        for i = 1, math.min(limit, #ids) do
            local c = self.containers[ids[i]]
            out[i] = { id = ids[i], capacityG = c.capacityG, weightG = c.weightG, version = c.version,
                meta = copy(c.meta), expiresAt = c.expiresAt }
        end
        if not detached then cb(out) end
    end, self.deferLoads)
end

function S:probe(cb)
    if self.down then return cb(nil, "unavailable") end
    cb(true)
end

-- Boot steps of the SQL store; nothing to migrate or test in memory.
function S:migrate(cb) cb(1, nil, 1) end
function S:selfTest(_, cb) cb(true) end
function S:mintHistory(_, cb) cb({}) end
function S:purge(_, _, cb) cb(0, 0, 0) end

function S:history(account, before, limit, cb)
    self:_run(function(detached)
        if self.down then if not detached then cb(nil, "unavailable") end return end
        local out = {}
        for i = #self.journal, 1, -1 do
            local e = self.journal[i]
            if e.account == account and (e.at or 0) < before then
                out[#out + 1] = { opId = e.opId, line = e.line, asset = e.asset, delta = e.delta, reason = e.reason,
                    at = e.at, kind = e.kind, actor = e.actor, resource = e.resource }
                if #out >= limit then break end
            end
        end
        if not detached then cb(out) end
    end, self.deferLoads)
end

-- Persistence hook for the lab_kvp store: records which rows changed.
function S:_touched(kind, id)
    if self.onTouched then self.onTouched(kind, id) end
end

function S:readOp(opId, cb)
    self:_run(function(detached)
        if self.down then if not detached then cb(nil, "unavailable") end return end
        local row = self.ops[opId]
        if not detached then cb(row and copy(row) or false) end
    end, self.deferLoads)
end

-- ---------------------------------------------------------------------------
-- Commit: the plan semantics of sql_store.buildCommit, applied atomically.
-- ---------------------------------------------------------------------------
function S:_apply(plan)
    if self.ops[plan.opId] then return nil, "duplicate_op" end
    local staged = { containers = {}, instances = {}, wallets = {} }
    local function C(id)
        if staged.containers[id] == nil then
            local row = self.containers[id]
            staged.containers[id] = row and copy(row) or false
        end
        return staged.containers[id]
    end
    local function I(id)
        if staged.instances[id] == nil then
            local row = self.instances[id]
            staged.instances[id] = row and copy(row) or false
        end
        return staged.instances[id]
    end
    local function W(id)
        if staged.wallets[id] == nil then
            local row = self.wallets[id]
            staged.wallets[id] = row and copy(row) or false
        end
        return staged.wallets[id]
    end

    for _, c in ipairs(plan.containers) do
        local row = C(c.id)
        if not row then return nil, "assert_container_missing" end
        local before = row.version
        row.weightG = row.weightG + c.weightDelta
        row.version = row.version + 1
        row.lastOp = plan.opId
        if row.weightG < 0 then return nil, "assert_weight_negative" end
        if c.weightDelta > 0 and not c.reweigh and row.weightG > row.capacityG then return nil, "assert_capacity" end
        if c.expectVersion ~= nil and before ~= c.expectVersion then return nil, "assert_version" end
    end
    for _, s in ipairs(plan.stacks) do
        local row = C(s.container)
        if not row then return nil, "assert_container_missing" end
        local current = row.stacks[s.item]
        if s.delta < 0 and (current == nil or current + s.delta < 0) then return nil, "assert_stack" end
        local next = (current or 0) + s.delta
        row.stacks[s.item] = next ~= 0 and next or nil
    end
    for _, i in ipairs(plan.instances) do
        if i.create then
            if I(i.id) then return nil, "duplicate_instance" end
            staged.instances[i.id] = { item = i.item, container = i.to, meta = copy(i.meta or {}), version = 1 }
        else
            local row = I(i.id)
            if not row or row.container ~= i.from then return nil, "assert_instance" end
            if i.expectVersion ~= nil and row.version ~= i.expectVersion then return nil, "assert_instance_version" end
            row.container = i.to
            if i.meta ~= nil then row.meta = copy(i.meta) end
            row.version = row.version + 1
        end
        staged.instances[i.id].lastOp = plan.opId
    end
    for _, w in ipairs(plan.wallets) do
        local row = W(w.id)
        if w.delta > 0 then
            if not row then row = { balance = 0, version = 0 }; staged.wallets[w.id] = row end
            local before = row.version
            row.balance = row.balance + w.delta
            row.version = row.version + 1
            if row.balance > self.maxMoney then return nil, "assert_balance_limit" end
            if w.expectVersion ~= nil and before ~= w.expectVersion then return nil, "assert_version" end
        else
            if not row then return nil, "assert_wallet_missing" end
            local before = row.version
            row.balance = row.balance + w.delta
            row.version = row.version + 1
            if row.balance < 0 then return nil, "assert_balance_negative" end
            if w.expectVersion ~= nil and before ~= w.expectVersion then return nil, "assert_version" end
        end
        row.lastOp = plan.opId
    end

    -- Everything held: publish the staged rows, the journal and the op row.
    for id, row in pairs(staged.containers) do if row then self.containers[id] = row; self:_touched("c", id) end end
    for id, row in pairs(staged.instances) do if row then self.instances[id] = row; self:_touched("i", id) end end
    for id, row in pairs(staged.wallets) do if row then self.wallets[id] = row; self:_touched("w", id) end end
    for index, entry in ipairs(plan.journal) do
        self.journal[#self.journal + 1] = {
            opId = plan.opId, line = index, account = entry.account, asset = entry.asset, delta = entry.delta,
            reason = entry.reason, at = plan.createdAt, kind = plan.kind, actor = plan.actor,
            resource = plan.resource,
        }
    end
    self.ops[plan.opId] = {
        state = "committed", hash = plan.hash, kind = plan.kind, resource = plan.resource,
        receipt = copy(plan.receipt), at = plan.createdAt,
    }
    self:_touched("o", plan.opId)
    self.commits = self.commits + 1
    return true
end

function S:commit(plan, cb)
    local fault = table.remove(self.faults, 1)
    self:_run(function(detached)
        local function answer(...) if not detached then cb(...) end end
        if self.down then return answer(nil, "ambiguous", "database_unreachable") end
        if fault == "unreachable_before" then return answer(nil, "ambiguous", "database_unreachable") end
        if fault == "failed" then return answer(nil, "failed", "database_schema_error") end
        if fault == "refused" then return answer(nil, "refused", "database_unavailable") end
        if fault == "deadlock" then
            return answer(nil, "transient", "database_request_failed (SQL 1213): A database operation failed.")
        end
        local ok, why = self:_apply(plan)
        if not ok then return answer(nil, "conflict", why) end
        if fault == "lost_ack" then return answer(nil, "ambiguous", "database_unreachable") end
        return answer(true)
    end, self.deferred)
end

-- Tombstone insert: "inserted" proves the original never committed and now
-- never can; "exists" hands back whatever row is there.
function S:fence(opId, meta, cb)
    self:_run(function(detached)
        local function answer(...) if not detached then cb(...) end end
        if self.down then return answer(nil, nil, "unavailable") end
        local row = self.ops[opId]
        if row then return answer("exists", copy(row)) end
        self.ops[opId] = { state = "aborted", hash = meta and meta.hash or "", kind = "fence",
            resource = meta and meta.resource or "" }
        self:_touched("o", opId)
        return answer("inserted")
    end, self.deferred)
end

-- ---------------------------------------------------------------------------
-- Test helpers
-- ---------------------------------------------------------------------------
function S:seedContainer(id, capacityG, stacks, weights)
    local weight = 0
    for item, n in pairs(stacks or {}) do weight = weight + (weights and weights[item] or 0) * n end
    self.containers[id] = { capacityG = capacityG, weightG = weight, version = 0, stacks = copy(stacks or {}) }
end

function S:seedWallet(id, balance) self.wallets[id] = { balance = balance, version = 0 } end

function S:seedInstance(iid, item, container, meta)
    self.instances[iid] = { item = item, container = container, meta = copy(meta or {}), version = 1 }
end

function S:count(container, item)
    local c = self.containers[container]
    return c and c.stacks[item] or 0
end

function S:balance(id)
    local w = self.wallets[id]
    return w and w.balance or 0
end

-- Per-op, per-asset sum of journal deltas (must be 0: double entry).
function S:journalSums(opId)
    local sums = {}
    for _, e in ipairs(self.journal) do
        if e.opId == opId then sums[e.asset] = (sums[e.asset] or 0) + e.delta end
    end
    return sums
end

return Open77TxMemoryStore
