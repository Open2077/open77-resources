-- tests/compat/fake_tx.lua: open77_transactions for the A9 cargo suite: the REAL final coordinator
-- (the vendored copy of Open77 697e9e2f, server/main.lua included, on txsandbox.lua), reached by
-- rp_cargo through fakehost's H.remote, with the FakeTx helpers the scenarios were written with.
--
-- Nothing of the coordinator is faked any more: metaPatch on instance moves (A9 N1), the lazy
-- read (N2), subjectOf (N3), per-part writers (N4), stale versions, capacity, replays and the
-- fence are its own. What stays here is test plumbing:
--   * seeding: containers and instances are created through the coordinator itself (open, and a
--     journaled transfer of kind "seed" out of sys:seed by the resource compat_seed); a world:
--     container, whose id only openWorld may mint, is seeded straight into the store;
--   * faults injected at the export boundary, where an Open77 caller meets them:
--       "unavailable"          the store refuses the next commit (it never reached the database):
--                              the coordinator answers store_unavailable, nothing applied
--       "stale_once"           the caller's snapshot is one version behind (expect - 1): the
--                              coordinator answers stale_version
--       "in_doubt_committed"   the transfer commits, its answer is lost on the way back
--                              (export_timeout, which rp_cargo reads as in_doubt)
--       "in_doubt_aborted"     the transfer never reaches the coordinator, the caller sees
--                              export_timeout; a later status with resolve fences it (aborted)
--     FakeTx.latencyMs delays every transfer (the round trip to another VM);
--     FakeTx.statusOverride[opId] = true makes status calls for that id time out (the
--     coordinator cannot be asked yet);
--   * FakeTx.where / instance / opCount / instancesIn read the store (the "database").
--
-- Globals expected: H (fakehost.lua), COMPAT_DIR, TX_DIR.

dofile(COMPAT_DIR .. "/txsandbox.lua")

FakeTx = { latencyMs = 0, fault = nil, calls = {}, statusOverride = {} }

-- The test server's coordinator settings: every resource may write (`*`), and only the seeding
-- resource may create value (rp_cargo never mints).
FakeTx.TUNABLES = { serverTag = "lab", writers = "*", mint1 = "compat_seed sys:* * 100000000" }

local function copy(v)
    if type(v) ~= "table" then return v end
    local out = {}
    for k, x in pairs(v) do out[k] = copy(x) end
    return out
end

local function start()
    if TXS.running then return end
    TXS.start({ tunables = FakeTx.TUNABLES })
    for _ = 1, 64 do
        if TXS.ready() then break end
        TXS.step()
    end
end

-- Runs one export as `resource` to completion on the coordinator's scheduler (no clock time).
local function now(resource, name, ...)
    start()
    local res
    local ok, why = TXS.call(resource, name, function(...) res = table.pack(...) end, ...)
    if not ok then return nil, why end
    for _ = 1, 200 do
        if res then break end
        TXS.step()
    end
    if not res then return nil, "test_timeout" end
    if not res[1] then return nil, "export_raised " .. tostring(res[2]) end
    return table.unpack(res, 2, res.n)
end

function FakeTx.define(items)
    start()
    return TXS.callSync("rp_cargo_test", "define", items)
end

function FakeTx.seed(account, capacityG)
    start()
    local store = TXS.store
    if account:match("^world:") then
        if not store.containers[account] then store:seedContainer(account, capacityG or 1000000, {}) end
        return store.containers[account]
    end
    if not store.containers[account] then now("compat_seed", "open", account, { capacityG = capacityG or 1000000 }) end
    return store.containers[account]
end

function FakeTx.seedInstance(account, iid, item, meta)
    FakeTx.seed(account)
    local r, why = now("compat_seed", "transfer", { opId = "seed-" .. iid, kind = "seed",
        lines = { { instance = iid, from = "sys:seed", to = account, item = item, meta = meta or {} } } })
    assert(type(r) == "table", "fake_tx: seeding " .. iid .. " refused: " .. tostring(why))
end

function FakeTx.where(iid)
    local i = TXS.store.instances[iid]
    return i and i.container or nil
end

function FakeTx.instance(iid)
    local i = TXS.store.instances[iid]
    if not i then return nil end
    return { item = i.item, meta = copy(i.meta), version = i.version }
end

function FakeTx.instancesIn(account)
    local n = 0
    for _, i in pairs(TXS.store.instances) do if i.container == account then n = n + 1 end end
    return n
end

-- Committed business operations (not the seeding, not the coordinator's own reweighs).
function FakeTx.opCount()
    local n = 0
    for _, op in pairs(TXS.store.ops) do
        if op.state == "committed" and op.kind ~= "seed" and op.kind ~= "reweigh" then n = n + 1 end
    end
    return n
end

-- An external writer (another resource): a transfer straight on the coordinator.
function FakeTx.transferAs(resource, spec)
    return now(resource, "transfer", spec)
end

-- ---------------------------------------------------------------------------------------------
-- The coordinator's exports as rp_cargo reaches them (H.remote), with the boundary faults

local SYNC = { allowed = true, subjectOf = true, info = true, health = true, define = true, definition = true,
    newOpId = true, account = true, cancel = true, authorize = true, registerSubjectProvider = true }

local function caller() return H.resource or "rp_cargo" end
local real = TXS.remoteTable(caller)

local function transfer(spec)
    FakeTx.calls[#FakeTx.calls + 1] = copy(spec)
    if FakeTx.latencyMs > 0 then Wait(FakeTx.latencyMs) end
    local fault = FakeTx.fault
    FakeTx.fault = nil
    if fault == "unavailable" then
        TXS.store.faults = { "refused" }
    elseif fault == "stale_once" then
        spec = copy(spec)
        for account, version in pairs(spec.expect or {}) do spec.expect[account] = version - 1 end
    elseif fault == "in_doubt_aborted" then
        return nil, "export_timeout"
    elseif fault == "in_doubt_committed" then
        real.transfer(spec)
        return nil, "export_timeout"
    end
    return real.transfer(spec)
end

local function status(opId, opts)
    if FakeTx.statusOverride[opId] then return nil, "export_timeout" end
    return real.status(opId, opts)
end

local exportsTable = setmetatable({}, { __index = function(_, name)
    if not TXS.running or not TXS.exports[name] then return nil end
    if name == "transfer" then return transfer end
    if name == "status" then return status end
    if SYNC[name] then return function(...) return TXS.callSync(caller(), name, ...) end end
    return real[name]
end })

function FakeTx.install()
    start()
    H.remote.open77_transactions = exportsTable
end

function FakeTx.uninstall()
    H.remote.open77_transactions = nil
end
