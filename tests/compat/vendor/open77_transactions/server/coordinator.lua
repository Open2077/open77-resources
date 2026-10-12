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
-- wiring (exports, MySQL, onResourceStop) is wave-1 work and NOT in this file.
--
-- Status: OFFLINE PROTOTYPE. Not wired, not proven in game.
-- Global: Open77TxCoordinator.
-- =============================================================================

Open77TxCoordinator = {}
local M = Open77TxModel
local C = {}
C.__index = C

local RETRYABLE = { conflict = true, busy = true, in_doubt = true, store_unavailable = true }

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

function Open77TxCoordinator.new(options)
    assert(type(options) == "table" and type(options.store) == "table", "store required")
    local self = setmetatable({
        store = options.store,
        now = options.now or function() return 0 end,
        serverTag = options.serverTag or "srv",
        acl = options.acl,                 -- function(resource, namespace) -> boolean
        onCommitted = options.onCommitted, -- function(receipt, accounts)
        defs = {},
        accounts = {},
        instanceIndex = {},                -- [instanceId] = containerId (mirror)
        loading = {},
        ops = {},
        receipts = {}, receiptOrder = {}, receiptLimit = options.receiptLimit or 4096,
        counter = 0,
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

function C:newOpId()
    self.counter = self.counter + 1
    return string.format("%s-%s-%s", self.serverTag, base36(self.bootMs), base36(self.counter))
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
        for iid in pairs(a.instances) do self.instanceIndex[iid] = id end
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
    self.store:load(id, function(row, err)
        self.loading[id] = nil
        if row and not err then self:_mirror(id, row) end
        for _, w in ipairs(waiting) do w(err or (row == nil and "unavailable") or nil) end
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

function C:open(id, props, done)
    done = done or function() end
    local kind = M.accountKind(id)
    if not kind or kind == "system" then return failure(done, "invalid_account") end
    if M.durableKeyProblem(id) then return failure(done, "invalid_key") end
    if kind == "wallet" then
        return self:_ensureLoaded({ id }, function(ok, why)
            if not ok then return failure(done, why) end
            done(self:read(id))
        end)
    end
    local capacity = math.tointeger(props and props.capacityG)
    if not capacity or capacity < 0 or capacity > M.LIMITS.maxWeightG then return failure(done, "invalid_spec") end
    self.store:openContainer(id, { capacityG = capacity }, function(ok, err)
        if not ok then return failure(done, "store_unavailable", { detail = err }) end
        local a = self.accounts[id]
        if a and a.inflight > 0 then
            a.stale = true
            return done(self:read(id))
        end
        self:_load(id, function(lerr)
            if lerr then return failure(done, "store_unavailable") end
            done(self:read(id))
        end)
    end)
end

function C:read(id)
    local a = self.accounts[id]
    if not a or not a.loaded then return nil, "not_loaded" end
    return {
        id = id, kind = a.kind, exists = a.exists, version = a.version,
        capacityG = a.capacityG, weightG = a.weightG, items = M.deepCopy(a.stacks),
        instances = M.deepCopy(a.instances), balance = a.balance,
        held = { items = M.deepCopy(a.heldItems), weightIn = a.heldWeightIn, money = a.heldMoney },
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
        if a and a.balance + n > M.LIMITS.maxMoney then return nil, "balance_limit" end
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
        for item, n in pairs(perItem) do
            local v = (a.heldItems[item] or 0) + sign * n
            a.heldItems[item] = v ~= 0 and v or nil
        end
    end
    for acct, n in pairs(h.money) do
        local a = self.accounts[acct]
        a.heldMoney = a.heldMoney + sign * n
    end
    for acct, grams in pairs(h.weightIn) do
        local a = self.accounts[acct]
        a.heldWeightIn = a.heldWeightIn + sign * grams
    end
    for iid, acct in pairs(h.instances) do
        self.accounts[acct].heldInstances[iid] = sign > 0 and op.opId or nil
    end
    op.holdsReleased = sign < 0
end

function C:_release(op)
    if op.holds and not op.holdsReleased then self:_applyHolds(op, -1) end
end

function C:_expireIfDue(op)
    if op.state == "reserved" and self.now() >= op.expiresAt then
        self:_release(op)
        op.state = "expired"
        op.reason = "expired"
    end
end

-- ---------------------------------------------------------------------------
-- Reserve
-- ---------------------------------------------------------------------------
local function stateReason(op)
    if op.state == "failed" then return op.reason or "failed" end
    if op.state == "committing" then return "busy" end
    return op.state -- expired | cancelled | aborted | in_doubt
end

function C:_aclCheck(resource, lines)
    if not self.acl then return true end
    for _, id in ipairs(linesAccounts(lines)) do
        local _, ns = M.accountKind(id)
        if not self.acl(resource, ns) then return false end
    end
    return true
end

function C:reserve(spec, resource, done)
    done = done or function() end
    if type(spec) ~= "table" then return failure(done, "invalid_spec") end
    if not M.validOpId(spec.opId) then return failure(done, "invalid_op_id") end
    if spec.kind ~= nil and (type(spec.kind) ~= "string" or #spec.kind > 32) then return failure(done, "invalid_spec") end
    if spec.actor ~= nil and not M.accountKind(spec.actor) then return failure(done, "invalid_account") end
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
    if not self:_aclCheck(resource, lines) then return failure(done, "namespace_denied") end
    local hash = M.hashLines(spec.kind, lines)

    local function existing(op)
        if op.hash ~= hash then return failure(done, "op_id_conflict", { opId = spec.opId }) end
        self:_expireIfDue(op)
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

    self:_ensureLoaded(linesAccounts(lines, spec.expect), function(ok, why)
        if not ok then return failure(done, why or "store_unavailable") end
        -- Another reserve of the same opId may have completed while we loaded.
        if self.ops[spec.opId] then return existing(self.ops[spec.opId]) end
        local holds, refusal = self:_computeHolds(lines, spec.expect)
        if not holds then return failure(done, refusal, { opId = spec.opId }) end
        local now = self.now()
        local op = {
            opId = spec.opId, kind = spec.kind or "", actor = spec.actor, resource = resource or "",
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

function C:_replay(receipt)
    local r = M.deepCopy(receipt)
    r.replay = true
    return r
end

function C:_remember(opId, receipt)
    if self.receipts[opId] == nil then
        self.receiptOrder[#self.receiptOrder + 1] = opId
        while #self.receiptOrder > self.receiptLimit do
            local old = table.remove(self.receiptOrder, 1)
            self.receipts[old] = nil
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
        -- Committed by a previous VM? Only the store knows (D6).
        return self.store:readOp(opId, function(row, err)
            if err then return failure(done, "store_unavailable", { opId = opId }) end
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
        lines = M.deepCopy(finalLines), hash = finalHash,
    }
    local plan, why = M.buildPlan({
        opId = opId, kind = op.kind, actor = op.actor, resource = op.resource, hash = finalHash,
        now = now, lines = finalLines, expect = op.expect, receipt = receipt,
        weights = function(item) return self:_weight(item) end,
        instances = function(iid) return self:_instanceRecord(iid) end,
    })
    if not plan then return failure(done, why, { opId = opId }) end
    if M.estimateStatements(plan) > M.LIMITS.maxStatements then
        return failure(done, "operation_too_large", { opId = opId })
    end

    op.state = "committing"
    op.finalLines, op.finalHash, op.plan = finalLines, finalHash, plan
    op.touched = touchedAccounts(plan)
    op.waiters = { done }
    self:_inflight(op, 1)
    self.store:commit(plan, function(ok, class, detail)
        self:_onCommitResult(op, ok, class, detail)
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
    if applied ~= false then self:_applyPlan(op.plan) end
    self:_release(op)
    self:_inflight(op, -1)
    op.state = "committed"
    local receipt = M.deepCopy(storedReceipt or op.plan.receipt)
    receipt.versions = {}
    for _, id in ipairs(op.touched) do
        local a = self.accounts[id]
        if a then receipt.versions[id] = a.version end
    end
    receipt.replay = false
    op.receipt = receipt
    self:_remember(op.opId, receipt)
    if applied == false then self:_reload(op.touched) end
    self:_notify(op, receipt)
    if self.onCommitted then self.onCommitted(M.deepCopy(receipt), M.deepCopy(op.touched)) end
end

function C:_settleFailed(op, reason, state)
    self:_release(op)
    self:_inflight(op, -1)
    op.state = state or "failed"
    op.reason = reason
    self:_notify(op, nil, reason, { opId = op.opId, state = op.state })
end

function C:_onCommitResult(op, ok, class, detail)
    if ok then return self:_settleCommitted(op) end
    op.lastError = detail
    if class == "conflict" then
        -- 1062: a duplicate opId or a failed assertion. Ask the store which.
        return self.store:readOp(op.opId, function(row, err)
            if err then
                -- Definitively rolled back either way (1062 precedes COMMIT); the
                -- mirror may be stale, so refresh it.
                self:_settleFailed(op, "conflict")
                return self:_reload(op.touched)
            end
            if row and row.state == "committed" then
                if row.hash == op.finalHash then
                    -- Committed earlier (a previous VM). Do not re-apply: reload.
                    return self:_settleCommitted(op, false, row.receipt)
                end
                return self:_settleFailed(op, "op_id_conflict")
            end
            if row and row.state == "aborted" then return self:_settleFailed(op, "aborted", "aborted") end
            self:_settleFailed(op, "conflict")
            self:_reload(op.touched)
        end)
    end
    if class == "failed" then return self:_settleFailed(op, "store_failed") end
    -- Refused at submission: never reached the database, nothing to fence.
    if class == "refused" then return self:_settleFailed(op, "store_unavailable") end
    -- Anything else is ambiguous: the COMMIT may have landed.
    op.state = "in_doubt"
    op.fenceAttempts = 0
    self:_fence(op)
end

function C:_fence(op)
    if op.fencing then return end
    op.fencing = true
    self.store:fence(op.opId, { hash = op.finalHash, resource = op.resource }, function(outcome, row, err)
        op.fencing = false
        if op.state ~= "in_doubt" then return end
        if outcome == "inserted" then
            return self:_settleFailed(op, "store_unavailable", "aborted")
        end
        if outcome == "exists" and row then
            if row.state == "committed" and row.hash == op.finalHash then
                -- Our acknowledgement was lost; the effects are ours to apply once.
                return self:_settleCommitted(op, true, row.receipt)
            end
            if row.state == "committed" then return self:_settleFailed(op, "op_id_conflict") end
            return self:_settleFailed(op, "store_unavailable", "aborted")
        end
        -- Store unreachable: stay in doubt, keep the holds, retry with backoff.
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
    op.state = "cancelled"
    op.reason = reason or "cancelled"
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
            if err then return failure(done, "store_unavailable", { opId = opId }) end
            if outcome == "inserted" then return done({ state = "aborted" }) end
            return done(fromRow(row))
        end)
    end
    self.store:readOp(opId, function(row, err)
        if err then return failure(done, "store_unavailable", { opId = opId }) end
        if row then return done(fromRow(row)) end
        done({ state = "unknown" })
    end)
end

function C:tick()
    local now = self.now()
    for _, op in pairs(self.ops) do
        if op.state == "reserved" then
            self:_expireIfDue(op)
        elseif op.state == "in_doubt" and not op.fencing and op.nextFenceAt and now >= op.nextFenceAt then
            self:_fence(op)
        end
    end
end

function C:onResourceStop(resource)
    local cancelled = 0
    for _, op in pairs(self.ops) do
        if op.state == "reserved" and op.resource == resource then
            self:_release(op)
            op.state = "cancelled"
            op.reason = "resource_stopped"
            cancelled = cancelled + 1
        end
    end
    return cancelled
end

-- Read-only view of one operation (tests and diagnostics).
function C:operation(opId)
    local op = self.ops[opId]
    if not op then return nil end
    return { state = op.state, reason = op.reason, expiresAt = op.expiresAt, resource = op.resource }
end

return Open77TxCoordinator
