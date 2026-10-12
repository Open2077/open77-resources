-- tests/compat/fake_tx.lua: a stand-in for the A13 coordinator (open77_transactions) exports,
-- reduced to what rp_cargo calls: open, read, transfer (instance lines), status, newOpId.
--
-- It encodes the contract of docs/world-interaction/a13-transaction-contract.md section 7.2 plus
-- ONE assumption the wave-0 prototype does not implement yet (API need N1 in
-- docs/world-interaction/a9-cargo.md): an instance move line may carry `metaPatch`, a shallow
-- merge into the instance metadata applied by the same commit (`false` removes a key).
-- Store state lives in H.stores.tx and survives H.boot, like the database.
--
-- Faults (one-shot, FakeTx.fault): "unavailable" (store_unavailable, nothing applied),
-- "in_doubt_committed" (applied, answer lost), "in_doubt_aborted" (not applied, answer lost),
-- "stale_once" (stale_version, nothing applied). FakeTx.latencyMs makes transfer Wait first,
-- like the round trip to another VM. FakeTx.statusOverride[opId] pins what status answers.

FakeTx = { latencyMs = 0, fault = nil, calls = {}, statusOverride = {} }

local function store()
    H.stores.tx = H.stores.tx or { accounts = {}, where = {}, ops = {}, defs = {}, counter = 0 }
    return H.stores.tx
end

local function copy(v)
    if type(v) ~= "table" then return v end
    local out = {}
    for k, x in pairs(v) do out[k] = copy(x) end
    return out
end

local function canonical(v)
    local t = type(v)
    if t ~= "table" then return tostring(v) end
    local keys = {}
    for k in pairs(v) do keys[#keys + 1] = tostring(k) end
    table.sort(keys)
    local parts = {}
    for _, k in ipairs(keys) do
        local x = v[k]
        if x == nil then x = v[tonumber(k)] end
        parts[#parts + 1] = k .. "=" .. canonical(x)
    end
    return "{" .. table.concat(parts, ",") .. "}"
end

local function validAccount(id)
    return type(id) == "string" and id:match("^[a-z]+:[A-Za-z0-9_.:@%-]+$") ~= nil and #id <= 96
end

function FakeTx.define(items)
    for id, def in pairs(items) do store().defs[id] = copy(def) end
end

function FakeTx.seed(account, capacityG)
    local s = store()
    s.accounts[account] = s.accounts[account] or { id = account, version = 0, capacityG = capacityG or 1000000, weightG = 0, instances = {} }
    return s.accounts[account]
end

function FakeTx.seedInstance(account, iid, item, meta)
    local s = store()
    local a = FakeTx.seed(account)
    a.instances[iid] = { item = item, meta = copy(meta or {}), version = 1 }
    a.weightG = a.weightG + ((s.defs[item] or {}).weightG or 0)
    s.where[iid] = account
end

function FakeTx.where(iid) return store().where[iid] end
function FakeTx.instance(iid)
    local s = store()
    local a = s.accounts[s.where[iid] or ""]
    return a and copy(a.instances[iid]) or nil
end
function FakeTx.opCount()
    local n = 0
    for _, op in pairs(store().ops) do if op.state == "committed" then n = n + 1 end end
    return n
end

local function snapshot(a)
    return { id = a.id, version = a.version, capacityG = a.capacityG, weightG = a.weightG, instances = copy(a.instances), items = {} }
end

local function apply(spec, s)
    for _, line in ipairs(spec.lines) do
        local from, to = s.accounts[line.from], s.accounts[line.to]
        local rec = from.instances[line.instance]
        from.instances[line.instance] = nil
        local w = (s.defs[rec.item] or {}).weightG or 0
        from.weightG = from.weightG - w
        to.weightG = to.weightG + w
        rec.version = rec.version + 1
        if type(line.metaPatch) == "table" then
            for k, v in pairs(line.metaPatch) do
                if v == false then rec.meta[k] = nil else rec.meta[k] = copy(v) end
            end
        end
        to.instances[line.instance] = rec
        s.where[line.instance] = line.to
        from.version = from.version + 1
        to.version = to.version + 1
    end
end

local exportsTable = {}

function exportsTable.newOpId()
    local s = store()
    s.counter = s.counter + 1
    return ("faketx-%06d"):format(s.counter)
end

function exportsTable.open(id, props)
    if not validAccount(id) then return nil, "invalid_account" end
    if id:match("^veh:%d+:") then return nil, "invalid_key" end
    local capacity = math.tointeger(props and props.capacityG)
    if not capacity or capacity < 0 then return nil, "invalid_spec" end
    local a = FakeTx.seed(id, capacity)
    return snapshot(a)
end

function exportsTable.read(id)
    if not validAccount(id) then return nil, "invalid_account" end
    local a = store().accounts[id]
    if not a then return nil, "unknown_account" end
    return snapshot(a)
end

-- transfer(spec): instance lines only. Returns receipt | nil, reason, info.
function exportsTable.transfer(spec)
    FakeTx.calls[#FakeTx.calls + 1] = copy(spec)
    if FakeTx.latencyMs > 0 then Wait(FakeTx.latencyMs) end
    local s = store()
    if type(spec) ~= "table" or type(spec.opId) ~= "string" or #spec.opId < 8 or type(spec.lines) ~= "table" or #spec.lines == 0 then
        return nil, "invalid_spec", { retryable = false }
    end
    local hash = canonical({ kind = spec.kind or "", lines = spec.lines })
    local prior = s.ops[spec.opId]
    if prior and prior.state == "committed" then
        if prior.hash ~= hash then return nil, "op_id_conflict", { retryable = false, opId = spec.opId } end
        local receipt = copy(prior.receipt)
        receipt.replay = true
        return receipt
    end
    if prior and prior.state == "aborted" then return nil, "aborted", { retryable = false, opId = spec.opId } end
    local fault = FakeTx.fault
    FakeTx.fault = nil
    if fault == "unavailable" then return nil, "store_unavailable", { retryable = true, opId = spec.opId } end
    if fault == "stale_once" then return nil, "stale_version", { retryable = false, opId = spec.opId } end
    for account, version in pairs(spec.expect or {}) do
        local a = s.accounts[account]
        if not a then return nil, "unknown_account", { retryable = false } end
        if a.version ~= version then return nil, "stale_version", { retryable = false, opId = spec.opId } end
    end
    for _, line in ipairs(spec.lines) do
        if type(line.instance) ~= "string" then return nil, "invalid_spec", { retryable = false } end
        if not validAccount(line.from) or not validAccount(line.to) then return nil, "invalid_account", { retryable = false } end
        local from, to = s.accounts[line.from], s.accounts[line.to]
        if not from or not to then return nil, "unknown_account", { retryable = false } end
        local rec = from.instances[line.instance]
        if not rec then return nil, "instance_unavailable", { retryable = false } end
        local w = (s.defs[rec.item] or {}).weightG or 0
        if to.weightG + w > to.capacityG then return nil, "capacity_exceeded", { retryable = false } end
    end
    if fault == "in_doubt_aborted" then
        s.ops[spec.opId] = { state = "aborted", hash = hash }
        return nil, "in_doubt", { retryable = true, opId = spec.opId, state = "in_doubt" }
    end
    apply(spec, s)
    local accounts, versions = {}, {}
    for _, line in ipairs(spec.lines) do
        for _, id in ipairs({ line.from, line.to }) do
            if versions[id] == nil then
                accounts[#accounts + 1] = id
                versions[id] = s.accounts[id].version
            end
        end
    end
    table.sort(accounts)
    local receipt = { opId = spec.opId, kind = spec.kind, state = "committed", replay = false, lines = copy(spec.lines), versions = versions }
    s.ops[spec.opId] = { state = "committed", hash = hash, receipt = copy(receipt) }
    TriggerEvent("open77_transactions:committed", spec.opId, spec.kind, accounts)
    if fault == "in_doubt_committed" then
        return nil, "in_doubt", { retryable = true, opId = spec.opId, state = "in_doubt" }
    end
    return receipt
end

function exportsTable.status(opId, opts)
    -- statusOverride[opId] = "in_doubt" keeps an outcome unsettled (the store is still down).
    if FakeTx.statusOverride[opId] then return { state = FakeTx.statusOverride[opId] } end
    local op = store().ops[opId]
    if op then return { state = op.state, receipt = copy(op.receipt) } end
    if opts and opts.resolve then
        store().ops[opId] = { state = "aborted", hash = "" }   -- the fence: it can never commit now
        return { state = "aborted" }
    end
    return nil, "unknown_operation"
end

-- An external writer (another resource): a transfer that is not rp_cargo's.
function FakeTx.transferAs(resource, spec)
    return exportsTable.transfer(spec)
end

function FakeTx.install()
    H.remote.open77_transactions = exportsTable
end

function FakeTx.uninstall()
    H.remote.open77_transactions = nil
end
