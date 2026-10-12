-- rp_inventory / server/facade.lua: the inventory as a facade over open77_transactions (row B2).
--
-- Global table: RpInvFacade. No native is called directly: the host injects
--   call(name, ...)  -> res, reason, info   one open77_transactions export, awaited (yields);
--                                           a dispatch failure answers nil, "coordinator_unavailable",
--                                           { ambiguous = true } when the request may have run
--   callSync(name, ...) -> res, reason      one NON-yielding export (allowed, subjectOf, info), inline;
--                                           nil, "coordinator_unavailable" when it cannot run
--   spawn(fn), wait(ms), now() -> ms, log(fmt, ...), registry (RpItemSchema registry),
--   onView(view, changes)                   effective contents changed by a reload, a lost
--                                           write-behind or a committed async operation
--
-- Two write paths, as decided in A13 7.4 / 12.2:
--   write-behind   the legacy SYNCHRONOUS exports (add/remove, /use, /giveitem): the change is
--                  applied to the local view at once and submitted in the background as a
--                  single-account operation, one at a time per account (ordering-safe deltas).
--                  No stronger than the old write-through, but one source of truth and no KVP.
--   transact       the ASYNC exports (give, store, take, sell, vehicle, world, wear): one
--                  coordinator operation, local holds while it runs, a receipt on success.
--
-- Views: committed (what the coordinator acknowledged) + pending (write-behind not yet
-- acknowledged) - held (in-flight async debits). Reloads never run under an in-flight
-- operation of this view (the coordinator's own rule): they are deferred instead.
--
-- API: the final coordinator, Open77 697e9e2f (contract section 7.2): info().ready before any
-- mutation, lazy read (unknown_account, never creates), openWorld/close for world: containers,
-- metaPatch on instance lines, allowed() for the sys: mint rules, a failed opId is a fresh
-- attempt and a fenced one (`aborted`) is not.
-- Status: offline-tested only (tests/test_compat_inventory.py), against that coordinator.

RpInvFacade = {}
local F = {}
F.__index = F

local Accounts = RpInvAccounts

-- Coordinator refusals after which retrying the SAME request cannot succeed.
local DEFINITIVE = {
    invalid_spec = true, invalid_op_id = true, invalid_account = true, unknown_item = true,
    invalid_count = true, invalid_amount = true, namespace_denied = true, vehicle_not_tracked = true,
    insufficient_items = true, insufficient_funds = true, capacity_exceeded = true,
    instance_unavailable = true, balance_limit = true, exceeds_reservation = true,
    operation_too_large = true, op_id_conflict = true, store_failed = true, not_owner = true,
    stale_version = true, unknown_account = true, invalid_key = true,
    -- The operator's mint rules (contract 12.6). mint_cap_exceeded is retryable for an async
    -- caller, but a write-behind change waiting an hour would hold its account's queue: lost.
    mint_denied = true, mint_cap_exceeded = true,
}
-- Coordinator states in which nothing was committed and nothing can commit any more.
local NOT_COMMITTED = { aborted = true, failed = true, expired = true, cancelled = true, unknown = true }

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

local function sortedKeys(t)
    local keys = {}
    for k in pairs(t) do keys[#keys + 1] = k end
    table.sort(keys)
    return keys
end

local function add(map, key, n)
    local v = (map[key] or 0) + n
    map[key] = v ~= 0 and v or nil
end

function RpInvFacade.new(deps)
    assert(type(deps) == "table" and deps.call and deps.spawn and deps.wait and deps.registry, "facade deps")
    local self = setmetatable({
        call = deps.call, spawn = deps.spawn, wait = deps.wait,
        callSync = deps.callSync or function() return nil, "coordinator_unavailable" end,
        store = nil,                     -- info().store of the coordinator (sql | lab_kvp)
        now = deps.now or function() return 0 end,
        log = deps.log or function() end,
        registry = deps.registry,
        onView = deps.onView or function() end,
        onReady = deps.onReady,          -- function(generation): the handshake succeeded
        -- function(opId, state, receipt): an async operation answered in_doubt has settled in the
        -- background: "committed" (receipt) or a not-committed state (aborted, failed...).
        onSettled = deps.onSettled or function() end,
        resource = deps.resource or "rp_inventory",
        views = {},
        healthy = false, starting = false, generation = 0,
        prefix = nil, counter = 0,
        defsPushed = -1,
        ownOps = {}, ownOrder = {}, ownLimit = deps.ownLimit or 4096,
        stats = { submitted = 0, committed = 0, lost = 0, retried = 0, inDoubt = 0 },
        backoffMs = deps.backoffMs or { 250, 1000, 2000, 4000, 8000, 15000, 30000 },
        drainMs = deps.drainMs or 10000,
        settleMs = deps.settleMs or 20000,
        maxQueue = deps.maxQueue or 256,
    }, F)
    return self
end

function F:_backoff(attempt)
    local list = self.backoffMs
    return list[math.min(attempt, #list)]
end

-- ---------------------------------------------------------------------------
-- Readiness: the coordinator reports ready (info), an opId prefix from it and the definitions
-- pushed. Until all succeed every mutation refuses with store_unavailable (A13 4.1: never a KVP
-- fallback). A coordinator that refused its store at boot (info.phase = "refused") is logged
-- once with its reason; it needs an operator, and the handshake keeps polling.
-- ---------------------------------------------------------------------------
function F:start()
    if self.starting then return end
    self.starting = true
    self.generation = self.generation + 1
    local generation = self.generation
    self.spawn(function()
        local attempt = 0
        local refusedLogged = false
        while generation == self.generation do
            local info = self.call("info")
            local prefix
            if type(info) == "table" and info.ready == true then
                self.store = info.store
                prefix = self.call("newOpId")
            elseif type(info) == "table" and info.phase == "refused" and not refusedLogged then
                refusedLogged = true
                self.log("open77_transactions refused its store (%s): mutations refuse store_unavailable", tostring(info.reason))
            end
            if type(prefix) == "string" and prefix ~= "" and #prefix <= 72 then
                self.prefix = prefix
                self.defsPushed = -1
                if self:_pushDefinitions() then
                    self.healthy = true
                    self.starting = false
                    self.log("transactions backend ready (store %s, opId prefix %s)", tostring(self.store), prefix)
                    if self.onReady then self.onReady(generation) end
                    return
                end
            end
            attempt = attempt + 1
            if attempt == 1 or attempt % 10 == 0 then
                self.log("open77_transactions not ready (attempt %d): mutations refuse store_unavailable", attempt)
            end
            self.wait(self:_backoff(attempt))
        end
    end)
end

-- The coordinator went away (stop event, dispatch failure): refuse until it answers again.
function F:lost(why)
    if self.healthy then self.log("open77_transactions unavailable (%s): mutations refuse", tostring(why)) end
    self.healthy = false
    self.starting = false
    self:start()
end

function F:isReady() return self.healthy end

-- Waits (bounded) for the handshake started by start(). Yields.
function F:awaitReady(ms)
    local waited = 0
    while not self.healthy and waited < ms do
        self.wait(100)
        waited = waited + 100
    end
    return self.healthy
end

function F:_pushDefinitions()
    local version = self.registry.version
    if self.defsPushed == version then return true end
    local registered, rejected, collisions = self.call("define", self.registry:txDefinitions())
    if type(registered) ~= "number" then
        self.log("definitions not pushed to open77_transactions: %s", tostring(rejected))
        return false
    end
    if type(collisions) == "table" and #collisions > 0 then
        -- The coordinator refuses a second definer; rp_inventory must be the only item definer.
        self.log("open77_transactions refused %d definition(s) as collisions: %s", #collisions, table.concat(collisions, ","))
    end
    self.defsPushed = version
    return true
end

-- Remembers an opId this inventory submitted, so its own committed event is not reloaded.
-- Bounded: an operation that never commits never sends the event that would clear it.
function F:_own(opId)
    if self.ownOps[opId] then return end
    self.ownOps[opId] = true
    local order = self.ownOrder
    order[#order + 1] = opId
    if #order > self.ownLimit then
        local old = table.remove(order, 1)
        self.ownOps[old] = nil
    end
end

function F:nextOpId(tag)
    self.counter = self.counter + 1
    return (self.prefix or "inv") .. "." .. (tag or "") .. base36(self.counter)
end

function F:mintInstanceId()
    self.counter = self.counter + 1
    return ("i" .. (self.prefix or "x") .. "." .. base36(self.counter)):sub(1, 64)
end

-- Whether this resource may create value out of `sysAccount` (`asset`: an item id or "money";
-- nil = any item) under the coordinator's mint rules (contract 12.6). Never yields. true, or
-- false plus mint_denied / mint_cap_exceeded. An unreachable coordinator answers true: the
-- operation itself is refused then.
function F:mayMint(sysAccount, asset)
    local ok, allowed, why = pcall(self.callSync, "allowed", self.resource, sysAccount, asset)
    if not ok or allowed == nil then return true end
    if allowed == true then return true end
    return false, why or "mint_denied"
end

-- ---------------------------------------------------------------------------
-- Views
-- ---------------------------------------------------------------------------
local function newView(account, capacityG)
    return {
        account = account, kind = Accounts.kindOf(account), capacityG = capacityG or 0,
        committed = { stacks = {}, instances = {}, weightG = 0, version = 0, exists = false },
        pending = { stacks = {}, add = {}, del = {}, weightG = 0 },
        held = { stacks = {}, inst = {}, weightOut = 0, weightIn = 0 },
        queue = {}, worker = false, inflight = 0, stale = false, loaded = false, loading = false,
    }
end

function F:view(account) return self.views[account] end

local function snapshotInto(view, snap)
    view.committed = {
        stacks = {}, instances = {}, weightG = math.tointeger(snap.weightG) or 0,
        version = snap.version or 0, exists = snap.exists ~= false,
    }
    for asset, n in pairs(snap.items or {}) do
        local c = math.tointeger(n)
        if c and c > 0 then view.committed.stacks[asset] = c end
    end
    for iid, rec in pairs(snap.instances or {}) do
        view.committed.instances[iid] = { item = rec.item, meta = RpItemSchema.copy(rec.meta or {}), version = rec.version }
    end
    if snap.capacityG then view.capacityG = math.tointeger(snap.capacityG) or view.capacityG end
end

-- Loads (open + read) one account. Yields. capacityG nil = read only: the coordinator loads on
-- demand and never creates, so a container that was never opened answers unknown_account.
-- world: containers are minted by openWorld, never opened here. Returns view | nil, reason.
function F:load(account, capacityG)
    local id, why = Accounts.parse(account)
    if not id then return nil, why end
    if not self.healthy then return nil, "store_unavailable" end
    if capacityG and Accounts.kindOf(account) == "world" then capacityG = nil end
    local view = self.views[account]
    if view and view.loaded then
        view.releaseWhenIdle = nil   -- used again (a quick reconnect) before its queue drained
        if capacityG and (capacityG ~= view.capacityG or not view.committed.exists) then
            local snap, reason = self.call("open", account, { capacityG = capacityG })
            if type(snap) ~= "table" then return nil, reason end
            if view.inflight == 0 and #view.queue == 0 then
                snapshotInto(view, snap)
            else
                view.committed.exists = true
            end
            view.capacityG = capacityG
        end
        return view
    end
    if view and view.loading then
        for _ = 1, 400 do
            self.wait(50)
            if view.loaded or not view.loading then break end
        end
        if view.loaded then return view end
        return nil, view.error or "store_unavailable"
    end
    view = view or newView(account, capacityG)
    self.views[account] = view
    view.loading = true
    local snap, reason
    if capacityG then
        snap, reason = self.call("open", account, { capacityG = capacityG })
    else
        snap, reason = self.call("read", account)
    end
    view.loading = false
    if type(snap) ~= "table" then
        view.error = reason or "store_unavailable"
        self.views[account] = nil
        if reason == "coordinator_unavailable" then self:lost(reason) end
        return nil, reason == "coordinator_unavailable" and "store_unavailable" or (reason or "store_unavailable")
    end
    snapshotInto(view, snap)
    if capacityG then view.capacityG = capacityG end
    view.loaded = true
    return view
end

-- Mints a world: container (a ground pile, a crate) and loads its view. Yields.
-- props = { capacityG, meta?, expiresAt? }. Returns view | nil, reason.
function F:openWorld(props)
    if not self.healthy then return nil, "store_unavailable" end
    local snap, reason = self.call("openWorld", props)
    if type(snap) ~= "table" or type(snap.id) ~= "string" then
        if reason == "coordinator_unavailable" then self:lost(reason); return nil, "store_unavailable" end
        return nil, reason or "store_unavailable"
    end
    local view = newView(snap.id, math.tointeger(snap.capacityG) or 0)
    snapshotInto(view, snap)
    view.loaded = true
    view.meta = snap.meta
    self.views[snap.id] = view
    return view
end

-- Deletes an EMPTY world: container (after its last unit was picked up or expired). Yields.
-- true | nil, reason (container_not_empty, busy, unknown_account...).
function F:closeWorld(account)
    local view = self.views[account]
    if view and (#view.queue > 0 or view.inflight > 0) then return nil, "busy" end
    local ok, reason = self.call("close", account)
    if ok == true or reason == "unknown_account" then
        self.views[account] = nil
        return true
    end
    return nil, reason or "store_unavailable"
end

-- Forget a view nobody uses any more, once its write-behind queue has drained.
function F:release(account)
    local view = self.views[account]
    if not view then return end
    if #view.queue == 0 and view.inflight == 0 then
        self.views[account] = nil
    else
        view.releaseWhenIdle = true
    end
end

-- Effective stacks (asset -> n) and instances (iid -> rec), held units excluded.
function F:effective(view)
    local stacks, instances = {}, {}
    for asset, n in pairs(view.committed.stacks) do stacks[asset] = n end
    for asset, n in pairs(view.pending.stacks) do add(stacks, asset, n) end
    for asset, n in pairs(view.held.stacks) do add(stacks, asset, -n) end
    for iid, rec in pairs(view.committed.instances) do instances[iid] = rec end
    for iid in pairs(view.pending.del) do instances[iid] = nil end
    for iid, rec in pairs(view.pending.add) do instances[iid] = rec end
    for iid in pairs(view.held.inst) do instances[iid] = nil end
    for asset, n in pairs(stacks) do if n <= 0 then stacks[asset] = nil end end
    return stacks, instances
end

-- Per base item counts, the shape the legacy code reads in `c.items`.
function F:counts(view)
    local stacks, instances = self:effective(view)
    local out = {}
    for asset, n in pairs(stacks) do
        local itemId = RpItemSchema.splitAsset(asset)
        add(out, itemId, n)
    end
    for _, rec in pairs(instances) do add(out, rec.item, 1) end
    return out
end

function F:weightG(view)
    return view.committed.weightG + view.pending.weightG - view.held.weightOut
end

-- Weight that counts against the capacity: in-flight credits are reserved, in-flight debits are
-- not yet released.
function F:usedG(view)
    return view.committed.weightG + view.pending.weightG + view.held.weightIn
end

-- ---------------------------------------------------------------------------
-- Planning: lines plus the per-account deltas they imply
-- ---------------------------------------------------------------------------
-- Picks what leaves `view` for a legacy count: the plain stack first, then the variants in id
-- order, then instances by lowest durability then id. `meta` restricts to one variant.
function F:pick(view, itemId, n, meta, instanceIds)
    local def = self.registry:get(itemId)
    if not def then return nil, "unknown_item" end
    local stacks, instances = self:effective(view)
    local picks, left = {}, n
    if instanceIds then
        for _, iid in ipairs(instanceIds) do
            local rec = instances[iid]
            if not rec or rec.item ~= itemId then return nil, "not_enough" end
            picks[#picks + 1] = { instance = iid, rec = rec }
        end
        if #picks ~= n then return nil, "invalid_count" end
        return picks
    end
    if meta ~= nil and not def.unique then
        local asset, why = self.registry:assetFor(itemId, meta)
        if not asset then return nil, why end
        if (stacks[asset] or 0) < n then return nil, "not_enough" end
        return { { asset = asset, count = n } }
    end
    local assets = {}
    for asset in pairs(stacks) do
        local base = RpItemSchema.splitAsset(asset)
        if base == itemId then assets[#assets + 1] = asset end
    end
    table.sort(assets, function(a, b)
        if a == itemId then return true end
        if b == itemId then return false end
        return a < b
    end)
    for _, asset in ipairs(assets) do
        if left == 0 then break end
        local take = math.min(left, stacks[asset])
        picks[#picks + 1] = { asset = asset, count = take }
        left = left - take
    end
    if left > 0 then
        local list = {}
        for iid, rec in pairs(instances) do
            if rec.item == itemId then list[#list + 1] = { iid = iid, rec = rec } end
        end
        table.sort(list, function(a, b)
            local da = tonumber(a.rec.meta and a.rec.meta.durability) or math.huge
            local db = tonumber(b.rec.meta and b.rec.meta.durability) or math.huge
            if da ~= db then return da < db end
            return a.iid < b.iid
        end)
        for _, entry in ipairs(list) do
            if left == 0 then break end
            picks[#picks + 1] = { instance = entry.iid, rec = entry.rec }
            left = left - 1
        end
    end
    if left > 0 then return nil, "not_enough" end
    return picks
end

-- Lines for moving picks from one account to another.
local function moveLines(picks, from, to)
    local lines = {}
    for _, p in ipairs(picks) do
        if p.asset then
            lines[#lines + 1] = { item = p.asset, count = p.count, from = from, to = to }
        else
            lines[#lines + 1] = { instance = p.instance, from = from, to = to }
        end
    end
    return lines
end

-- Lines that CREATE n units of an item (stack credit or new instances) from a sys source.
function F:createLines(itemId, n, meta, from, to)
    local asset, canonical, unique = self.registry:assetFor(itemId, meta)
    if not asset then return nil, canonical end
    if not unique then return { { item = asset, count = n, from = from, to = to } } end
    if n > 16 then return nil, "invalid_count" end
    local def = self.registry:get(itemId)
    local lines = {}
    for _ = 1, n do
        local iid = self:mintInstanceId()
        local m = RpItemSchema.copy(canonical)
        if def.serial then m.serial = iid end
        lines[#lines + 1] = { instance = iid, from = from, to = to, item = itemId, meta = m }
    end
    return lines
end

-- The metadata an instance line leaves (the coordinator's rule, model.lua resolveMeta): `meta`
-- replaces, `metaPatch` merges one level into the current metadata.
local function mergedMeta(current, meta, patch)
    if meta ~= nil then return RpItemSchema.copy(meta) end
    local merged = RpItemSchema.copy(current or {})
    for k, v in pairs(patch or {}) do merged[k] = RpItemSchema.copy(v) end
    return merged
end

-- The deltas each loaded view sees once `lines` commit.
function F:deltasOf(lines)
    local deltas = {}
    local function d(account)
        if not self.views[account] then return nil end
        local x = deltas[account]
        if not x then
            x = { stacks = {}, add = {}, del = {}, upd = {}, weightG = 0 }
            deltas[account] = x
        end
        return x
    end
    local function instanceRecord(iid, account)
        local view = self.views[account]
        if not view then return nil end
        local _, instances = self:effective(view)
        return instances[iid] or view.committed.instances[iid] or view.pending.add[iid]
    end
    for _, l in ipairs(lines) do
        if l.item and not l.instance then
            local grams = (self.registry:weightG(l.item) or 0) * l.count
            local f, t = d(l.from), d(l.to)
            if f then add(f.stacks, l.item, -l.count); f.weightG = f.weightG - grams end
            if t then add(t.stacks, l.item, l.count); t.weightG = t.weightG + grams end
        elseif l.instance and l.at then
            local x = d(l.at)
            if x then
                local rec = instanceRecord(l.instance, l.at)
                x.upd[l.instance] = mergedMeta(rec and rec.meta, l.meta, l.metaPatch)
            end
        elseif l.instance then
            local rec = l.item and { item = l.item, meta = RpItemSchema.copy(l.meta or {}), version = 1 }
                or instanceRecord(l.instance, l.from)
            if rec and not l.item and (l.meta ~= nil or l.metaPatch ~= nil) then
                rec = { item = rec.item, meta = mergedMeta(rec.meta, l.meta, l.metaPatch), version = rec.version }
            end
            local grams = rec and (self.registry:weightG(rec.item) or 0) or 0
            local f, t = d(l.from), d(l.to)
            if f then f.del[l.instance] = true; f.weightG = f.weightG - grams end
            if t and rec then
                t.add[l.instance] = { item = rec.item, meta = RpItemSchema.copy(rec.meta or {}), version = (rec.version or 0) + 1 }
                t.weightG = t.weightG + grams
            end
        end
    end
    return deltas
end

local function applyTo(layer, x, sign)
    for asset, n in pairs(x.stacks) do add(layer.stacks, asset, sign * n) end
    layer.weightG = layer.weightG + sign * x.weightG
end

-- committed += deltas (an acknowledged operation)
function F:_commitDeltas(account, x)
    local view = self.views[account]
    if not view then return end
    local c = view.committed
    applyTo(c, x, 1)
    for iid in pairs(x.del) do c.instances[iid] = nil end
    for iid, rec in pairs(x.add) do c.instances[iid] = rec end
    for iid, meta in pairs(x.upd) do
        local rec = c.instances[iid]
        if rec then rec.meta = meta; rec.version = (rec.version or 0) + 1 end
    end
    for asset, n in pairs(c.stacks) do if n <= 0 then c.stacks[asset] = nil end end
end

-- ---------------------------------------------------------------------------
-- Write-behind (legacy synchronous exports)
-- ---------------------------------------------------------------------------
-- credit(view, itemId, n, meta, source) -> true | nil, reason. Never yields.
function F:credit(view, itemId, n, meta, source)
    if not self.healthy then return nil, "store_unavailable" end
    if not view.loaded then return nil, "not_loaded" end
    if #view.queue >= self.maxQueue then return nil, "store_unavailable" end
    local def = self.registry:get(itemId)
    if not def then return nil, "unknown_item" end
    local lines, why = self:createLines(itemId, n, meta, source, view.account)
    if not lines then return nil, why end
    if self:usedG(view) + def.weightG * n > view.capacityG then return nil, "too_heavy" end
    -- A credit out of sys: is a mint: refused at once when the operator's rules do not allow it,
    -- instead of being accepted and lost later.
    if Accounts.kindOf(source) == "sys" then
        local mint, mintWhy = self:mayMint(source, itemId)
        if not mint then return nil, mintWhy end
    end
    if def.maxStack and not def.unique then
        local stacks = self:effective(view)
        if (stacks[lines[1].item] or 0) + n > def.maxStack then return nil, "stack_limit" end
    end
    self:_enqueue(view, { kind = "inv.add", lines = lines })
    return true, lines
end

-- debit(view, itemId, n, meta, sink) -> true | nil, reason. Never yields.
function F:debit(view, itemId, n, meta, sink)
    if not self.healthy then return nil, "store_unavailable" end
    if not view.loaded then return nil, "not_loaded" end
    if #view.queue >= self.maxQueue then return nil, "store_unavailable" end
    local picks, why = self:pick(view, itemId, n, meta)
    if not picks then return nil, why end
    self:_enqueue(view, { kind = "inv.remove", lines = moveLines(picks, view.account, sink) })
    return true, picks
end

function F:_enqueue(view, op)
    op.baseId = self:nextOpId("w")
    op.opId = op.baseId
    op.attempt = 0
    op.deltas = self:deltasOf(op.lines)
    local x = op.deltas[view.account]
    local p = view.pending
    applyTo(p, x, 1)
    for iid in pairs(x.del) do p.del[iid] = true end
    for iid, rec in pairs(x.add) do p.add[iid] = rec end
    view.queue[#view.queue + 1] = op
    self:_ensureWorker(view)
end

function F:_unpend(view, op)
    local x = op.deltas[view.account]
    local p = view.pending
    applyTo(p, x, -1)
    for iid in pairs(x.del) do p.del[iid] = nil end
    for iid in pairs(x.add) do p.add[iid] = nil end
end

function F:_ensureWorker(view)
    if view.worker then return end
    view.worker = true
    self.spawn(function()
        -- Let the synchronous caller finish (its own log line and rp_inventory:changed) first.
        self.wait(0)
        while #view.queue > 0 do
            local op = view.queue[1]
            view.inflight = view.inflight + 1
            local receipt, reason = self:_submitWriteBehind(op)
            view.inflight = view.inflight - 1
            table.remove(view.queue, 1)
            local before = self:counts(view)
            self:_unpend(view, op)
            if receipt then
                self:_commitDeltas(view.account, op.deltas[view.account])
                self.stats.committed = self.stats.committed + 1
            else
                -- A write the caller was told succeeded did not land: say so, resync, and let the
                -- view change notify the listeners (a compensating rp_inventory:changed).
                self.stats.lost = self.stats.lost + 1
                self.log("write-behind %s on %s LOST: %s (%d line(s)); resyncing", op.opId, view.account,
                    tostring(reason), #op.lines)
                view.stale = true
                self:_notifyDiff(view, before)
            end
        end
        view.worker = false
        if view.stale then self:reload(view.account) end
        if view.releaseWhenIdle and view.inflight == 0 then self.views[view.account] = nil end
    end)
end

-- Waits for the coordinator; resubmits until a FINAL outcome: a receipt, or a definitive refusal.
function F:_submitWriteBehind(op)
    local attempt, repushed = 0, false
    while true do
        while not self.healthy do self.wait(500) end
        if self.defsPushed ~= self.registry.version then self:_pushDefinitions() end
        self:_own(op.opId)
        self.stats.submitted = self.stats.submitted + 1
        local res, reason, info = self.call("transfer", { opId = op.opId, kind = op.kind, actor = op.actor, lines = op.lines })
        if type(res) == "table" then return res end
        if reason == "unknown_item" and not repushed then
            repushed = true
            self.defsPushed = -1
            op.opId = self:_freshOpId(op)
        elseif DEFINITIVE[reason] then
            return nil, reason
        elseif reason == "in_doubt" or (info and info.ambiguous) then
            self.stats.inDoubt = self.stats.inDoubt + 1
            local receipt, state = self:settle(op.opId)
            if receipt then return receipt end
            if state == "busy" then
                -- still committing: keep the opId and wait
            else
                op.opId = self:_freshOpId(op)
            end
        elseif reason == "busy" then
            -- same opId, a previous submission is committing
        else
            -- store_unavailable / conflict / aborted / coordinator_unavailable: nothing committed
            if reason == "coordinator_unavailable" then self:lost(info and info.dispatch or reason) end
            op.opId = self:_freshOpId(op)
        end
        attempt = attempt + 1
        self.stats.retried = self.stats.retried + 1
        self.wait(self:_backoff(attempt))
    end
end

function F:_freshOpId(op)
    op.attempt = op.attempt + 1
    return op.baseId .. ".r" .. base36(op.attempt)
end

-- Polls status(opId, { resolve = true }) until the outcome is known. Returns receipt, or
-- nil, state ("aborted"... = nothing committed). With deadlineMs, gives up with nil, "busy".
function F:settle(opId, deadlineMs)
    local started = self.now()
    local attempt = 0
    while true do
        local st, reason = self.call("status", opId, { resolve = true })
        if type(st) == "table" then
            if st.state == "committed" then return st.receipt or { opId = opId, state = "committed" } end
            if NOT_COMMITTED[st.state] then return nil, st.state end
        elseif reason == "coordinator_unavailable" then
            -- The handshake (opId prefix, definitions) restarts; status keeps being asked.
            self:lost(reason)
        end
        attempt = attempt + 1
        if deadlineMs and self.now() - started >= deadlineMs then return nil, "busy" end
        self.wait(self:_backoff(attempt))
    end
end

-- ---------------------------------------------------------------------------
-- Reloads and change notifications
-- ---------------------------------------------------------------------------
function F:_notifyDiff(view, before)
    local after = self:counts(view)
    local changes, any = {}, false
    for itemId, n in pairs(after) do
        local d = n - (before[itemId] or 0)
        if d ~= 0 then changes[itemId] = d; any = true end
    end
    for itemId, n in pairs(before) do
        if after[itemId] == nil then changes[itemId] = -n; any = true end
    end
    if any then self.onView(view, changes) end
end

-- Re-reads one account from the coordinator, never under an in-flight operation of this view.
function F:reload(account)
    local view = self.views[account]
    if not view or not view.loaded then return end
    if view.inflight > 0 or view.reloading then view.stale = true; return end
    view.reloading = true
    self.spawn(function()
        local snap = self.call("read", account)
        view.reloading = false
        if type(snap) ~= "table" then view.stale = true; return end
        if view.inflight > 0 then view.stale = true; return end
        local before = self:counts(view)
        snapshotInto(view, snap)
        view.stale = false
        self:_notifyDiff(view, before)
    end)
end

-- open77_transactions:committed(opId, kind, accounts): an operation by someone else touched a
-- container this inventory shows. Our own operations are already in the views.
function F:onCommitted(opId, accounts)
    if self.ownOps[opId] then self.ownOps[opId] = nil; return end
    for _, account in ipairs(type(accounts) == "table" and accounts or {}) do
        if self.views[account] then self:reload(account) end
    end
end

-- ---------------------------------------------------------------------------
-- Atomic async operations
-- ---------------------------------------------------------------------------
-- transact(op) -> receipt | nil, reason, info. Yields.
--   op.lines       coordinator lines (accounts already resolved)
--   op.kind/actor  journal labels
--   op.opId        caller's business id (idempotency); minted when absent
--   op.capacityReason { [account] = token } for a capacity refusal (too_heavy, stash_full...)
function F:transact(op)
    if not self.healthy then return nil, "store_unavailable", { retryable = true } end
    if type(op.lines) ~= "table" or #op.lines == 0 then return nil, "invalid_spec" end
    if op.opId ~= nil and (type(op.opId) ~= "string" or #op.opId < 8 or #op.opId > 96
        or not op.opId:match("^[A-Za-z0-9_.:@%-]+$")) then
        return nil, "invalid_op_id"
    end
    local accounts, seen = {}, {}
    for _, l in ipairs(op.lines) do
        -- pairs, not ipairs: a metadata update line has no `from`, and ipairs stops at that nil,
        -- which left wearAsync's account out of the holds and its view stale (B7 finding).
        for _, a in pairs({ l.from, l.to, l.at }) do
            if a and not seen[a] then
                seen[a] = true
                local id, why = Accounts.parse(a)
                if not id then return nil, why, { account = a } end
                local kind = Accounts.kindOf(a)
                if kind ~= "sys" and kind ~= "cash" and kind ~= "bank" and kind ~= "soc" then accounts[#accounts + 1] = a end
            end
        end
    end
    table.sort(accounts)
    -- Every container we move items out of or into must be loaded (read) first.
    for _, account in ipairs(accounts) do
        if not (self.views[account] and self.views[account].loaded) then
            local view, why = self:load(account)
            if not view then return nil, why end
        end
    end
    -- Let earlier write-behind changes of these accounts land first: the coordinator must see
    -- what the player was shown.
    local waited = 0
    while true do
        local busy = false
        for _, account in ipairs(accounts) do
            local v = self.views[account]
            if v and #v.queue > 0 then busy = true end
        end
        if not busy then break end
        if waited >= self.drainMs then return nil, "busy", { retryable = true } end
        self.wait(50)
        waited = waited + 50
    end
    -- Local pre-checks with the legacy tokens, then local holds.
    local deltas = self:deltasOf(op.lines)
    for _, account in ipairs(accounts) do
        local v, x = self.views[account], deltas[account]
        if v and x then
            local stacks, instances = self:effective(v)
            for asset, n in pairs(x.stacks) do
                if n < 0 and (stacks[asset] or 0) < -n then return nil, "not_enough", { account = account } end
            end
            for iid in pairs(x.del) do
                if not instances[iid] then return nil, "not_enough", { account = account } end
            end
            if x.weightG > 0 and self:usedG(v) + x.weightG > v.capacityG then
                return nil, (op.capacityReason and op.capacityReason[account]) or "too_heavy", { account = account }
            end
            for asset, n in pairs(x.stacks) do
                local def = n > 0 and self.registry:get(RpItemSchema.splitAsset(asset))
                if def and def.maxStack and (stacks[asset] or 0) + n > def.maxStack then
                    return nil, "stack_limit", { account = account }
                end
            end
        end
    end
    local opId = op.opId or self:nextOpId("a")
    local holds, befores = {}, {}
    for _, account in ipairs(accounts) do
        if self.views[account] and deltas[account] then befores[account] = self:counts(self.views[account]) end
    end
    for _, account in ipairs(accounts) do
        local v, x = self.views[account], deltas[account]
        if v and x then
            for asset, n in pairs(x.stacks) do if n < 0 then add(v.held.stacks, asset, -n) end end
            for iid in pairs(x.del) do v.held.inst[iid] = true end
            if x.weightG < 0 then v.held.weightOut = v.held.weightOut - x.weightG end
            if x.weightG > 0 then v.held.weightIn = v.held.weightIn + x.weightG end
            v.inflight = v.inflight + 1
            holds[#holds + 1] = { view = v, x = x }
        end
    end
    local function release()
        for _, h in ipairs(holds) do
            local v, x = h.view, h.x
            for asset, n in pairs(x.stacks) do if n < 0 then add(v.held.stacks, asset, n) end end
            for iid in pairs(x.del) do v.held.inst[iid] = nil end
            if x.weightG < 0 then v.held.weightOut = v.held.weightOut + x.weightG end
            if x.weightG > 0 then v.held.weightIn = v.held.weightIn - x.weightG end
            v.inflight = v.inflight - 1
        end
    end
    local function finish(receipt)
        release()
        if receipt then
            for _, h in ipairs(holds) do self:_commitDeltas(h.view.account, h.x) end
        end
        for _, h in ipairs(holds) do
            self:_notifyDiff(h.view, befores[h.view.account])
            if h.view.stale and h.view.inflight == 0 then self:reload(h.view.account) end
        end
    end

    if self.defsPushed ~= self.registry.version then self:_pushDefinitions() end
    self:_own(opId)
    self.stats.submitted = self.stats.submitted + 1
    local spec = { opId = opId, kind = op.kind or "inv.move", actor = op.actor, lines = op.lines }
    local receipt, reason, info = self.call("transfer", spec)
    if reason == "unknown_item" then
        -- A restarted coordinator lost the definitions: push them and try once more (the refusal
        -- happened at reserve, before any operation existed, so the same opId is still free).
        self.defsPushed = -1
        if self:_pushDefinitions() then receipt, reason, info = self.call("transfer", spec) end
    end
    if type(receipt) == "table" then
        finish(receipt)
        self.stats.committed = self.stats.committed + 1
        return receipt
    end
    info = info or {}
    if reason == "in_doubt" or info.ambiguous then
        -- Keep the holds while the outcome is unknown; answer in_doubt after the deadline and
        -- settle in the background so the views converge on the real outcome.
        self.stats.inDoubt = self.stats.inDoubt + 1
        local settled, state = self:settle(opId, self.settleMs)
        if settled then
            finish(settled)
            self.stats.committed = self.stats.committed + 1
            return settled
        end
        if state ~= "busy" then
            finish(nil)
            return nil, "store_unavailable", { opId = opId, retryable = true, state = state }
        end
        self.spawn(function()
            local late, lateState = self:settle(opId)
            finish(late)
            if late then self.stats.committed = self.stats.committed + 1 end
            self.onSettled(opId, late and "committed" or (lateState or "aborted"), late)
        end)
        return nil, "in_doubt", { opId = opId, retryable = true }
    end
    finish(nil)
    if reason == "coordinator_unavailable" then
        self:lost(info.dispatch)
        return nil, "store_unavailable", { opId = opId, retryable = true }
    end
    if reason == "conflict" then
        for _, h in ipairs(holds) do self:reload(h.view.account) end
    end
    if reason == "capacity_exceeded" then
        -- The coordinator does not say which container; the caller's token names the receiver.
        local token
        for account, t in pairs(op.capacityReason or {}) do token = token or t end
        return nil, token or "too_heavy", { opId = opId, coordinator = reason }
    end
    if reason == "insufficient_items" or reason == "instance_unavailable" then
        return nil, "not_enough", { opId = opId, coordinator = reason }
    end
    info.opId = opId
    return nil, reason or "store_unavailable", info
end

-- Lines that move n units of itemId from `fromView` to account `to` (legacy pick order).
function F:planMove(fromView, to, itemId, n, meta, instanceIds)
    local picks, why = self:pick(fromView, itemId, n, meta, instanceIds)
    if not picks then return nil, why end
    return moveLines(picks, fromView.account, to)
end

-- Lines for wearing one instance: a CAS metadata update, or its destruction at zero.
function F:planWear(view, itemId, amount, instanceId)
    local def = self.registry:get(itemId)
    if not def or not def.durability then return nil, "not_wearable" end
    local _, instances = self:effective(view)
    local iid = instanceId
    if not iid then
        local best
        for id, rec in pairs(instances) do
            if rec.item == itemId then
                local d = tonumber(rec.meta and rec.meta.durability) or 0
                if not best or d < best.d or (d == best.d and id < best.id) then best = { id = id, d = d } end
            end
        end
        iid = best and best.id
    end
    local rec = iid and instances[iid]
    if not rec or rec.item ~= itemId then return nil, "not_enough" end
    local current = tonumber(rec.meta and rec.meta.durability) or def.durability.start
    local left = math.max(0, current - amount)
    if left == 0 and def.durability.breaks then
        return { { instance = iid, from = view.account, to = "sys:broken" } }, iid, 0, true
    end
    -- A compare-and-set patch of the one field: other metadata (a serial, an origin) is kept
    -- as the coordinator holds it at commit time.
    return { { instance = iid, at = view.account, metaPatch = { durability = left } } }, iid, left, false
end

return RpInvFacade
