-- tests/compat/txhost.lua: fake-host additions for the B1/B2 inventory suite (rows B1, B2).
--
-- Loaded AFTER fakehost.lua, never instead of it: it only adds what rp_inventory's
-- transactions backend touches (promise, cross-resource exports, loot, positions, convars, an
-- inventory SQL interpreter with error injection) and runs the REAL, final open77_transactions
-- resource (the vendored copy of Open77 697e9e2f, server/main.lua included: its exports, gate,
-- work queue, policy, subject provider and events) on the coordinator sandbox (txsandbox.lua).
-- The coordinator and its store survive H.boot, so a test can restart rp_inventory under a
-- running coordinator, or restart the coordinator over the same store.
--
-- Globals expected from the runner: REPO (pack root), HARNESS (this folder), TX_DIR (the
-- open77_transactions folder: tests/compat/vendor/open77_transactions, or OP77_TX_DIR).

local realBoot = H.boot

-- ---------------------------------------------------------------------------
-- promise (the platform's Open77.Promise shape: resolve / reject / await / status)
-- ---------------------------------------------------------------------------
promise = {}
function promise.new()
    local p = { state = "pending" }
    function p:resolve(...)
        if self.state == "pending" then self.state = "resolved"; self.values = table.pack(...) end
    end
    function p:reject(reason)
        if self.state == "pending" then self.state = "rejected"; self.reason = reason end
    end
    function p:status() return self.state end
    function p:await()
        while self.state == "pending" do
            if not coroutine.isyieldable() then error("await outside a managed task", 2) end
            Wait(0)
        end
        if self.state == "rejected" then return nil, self.reason end
        return table.unpack(self.values, 1, self.values.n)
    end
    return p
end

-- ---------------------------------------------------------------------------
-- Host pieces fakehost.lua does not have
-- ---------------------------------------------------------------------------
H.convars = H.convars or {}
function GetConvar(name, default)
    local v = H.convars[name]
    if v == nil then return default end
    return v
end
function GetInvokingResource() return H.invoker or "compat_test" end

H.client = {}
function TriggerClientEvent(name, target, ...)
    H.client[#H.client + 1] = { name = name, target = target, args = table.pack(...) }
    return true
end
H.chat = {}
Open77.chat.send = function(playerId, msg)
    H.chat[#H.chat + 1] = { playerId = playerId, text = type(msg) == "table" and msg.text or tostring(msg) }
    return true
end

local function pos(id)
    local p = H.players[id] and H.players[id].pos
    if not p then return nil end
    return { x = p.x, y = p.y, z = p.z, bucket = p.bucket or 0 }
end
Open77.players.position = function(id) return pos(id) end
Open77.players.distance = function(a, b)
    local pa, pb = pos(a), pos(b)
    if not pa or not pb then return nil, "position_unknown" end
    return math.sqrt((pa.x - pb.x) ^ 2 + (pa.y - pb.y) ^ 2 + (pa.z - pb.z) ^ 2)
end
Open77.players.closest = function(id, opts)
    local best
    for other in pairs(H.players) do
        if other ~= id then
            local d = Open77.players.distance(id, other)
            if d and d <= ((opts and opts.radius) or 3) and (not best or d < best.distance) then
                best = { playerId = other, distance = d }
            end
        end
    end
    return best
end
Open77.players.nearby = function(id, radius)
    local out = {}
    for other in pairs(H.players) do
        if other ~= id then
            local d = Open77.players.distance(id, other)
            if d and d <= radius then out[#out + 1] = { playerId = other, name = H.players[other].name, distance = d } end
        end
    end
    return out
end
Open77.kvp.find = function(prefix, limit)
    local out = {}
    for _, k in ipairs(Open77.kvp.keys(prefix)) do out[#out + 1] = { key = k, value = H.stores.kvp[k] } end
    return out
end

-- Native loot: a registry plus helpers that play the platform's pickup and expiry.
H.loot = { next = 100, drops = {} }
Open77.loot = {
    create = function(def)
        H.loot.next = H.loot.next + 1
        local id = H.loot.next
        H.loot.drops[id] = { id = id, item = def.item, quantity = def.quantity, position = def.position,
            bucket = def.bucket, owner = H.resource }
        return id
    end,
    remove = function(id)
        if H.loot.drops[id] then H.loot.drops[id] = nil; return true end
        return false
    end,
    all = function()
        local out = {}
        for id, d in pairs(H.loot.drops) do out[#out + 1] = { id = id, position = d.position } end
        table.sort(out, function(a, b) return a.id < b.id end)
        return out
    end,
}
-- LootAuthorityService: the drop is removed BEFORE onLootPickup is raised (A13 F1/F2).
function H.nativePickup(playerId, dropId)
    local d = H.loot.drops[dropId]
    if not d then return false end
    H.loot.drops[dropId] = nil
    H.emit("onLootPickup", playerId, dropId, d.item, d.quantity, d.owner)
    return true
end
function H.expireDrop(dropId)
    local d = H.loot.drops[dropId]
    if not d then return false end
    H.loot.drops[dropId] = nil
    H.emit("onLootRemoved", dropId, "expired", d.owner)
    return true
end

-- ---------------------------------------------------------------------------
-- Cross-resource exports: Open77.exports.call / callSync over H.resources
-- An entry is either a plain function (its returns resolve the promise) or { cps = fn }, where
-- fn(done, ...) completes later through done(...).
-- ---------------------------------------------------------------------------
H.resources = H.resources or {}
H.down = H.down or {}
H.pendingExports = H.pendingExports or {}
Open77.exports = Open77.exports or {}
Open77.exports.call = function(resource, name, ...)
    if H.down[resource] then return nil, "export_resource_unavailable" end
    local r = H.resources[resource]
    local fn = r and r[name]
    if not fn then return nil, r and "export_not_found" or "export_resource_unavailable" end
    local p = promise.new()
    local args = table.pack(...)
    if type(fn) == "table" then
        H.pendingExports[resource] = H.pendingExports[resource] or {}
        H.pendingExports[resource][p] = true
        fn.cps(function(...)
            H.pendingExports[resource][p] = nil
            p:resolve(...)
        end, table.unpack(args, 1, args.n))
    else
        p:resolve(fn(table.unpack(args, 1, args.n)))
    end
    return p
end
Open77.exports.callSync = function(resource, name, ...)
    if H.down[resource] then error("export_resource_unavailable", 0) end
    local r = H.resources[resource]
    local fn = r and r[name]
    if type(fn) == "table" and fn.sync then return fn.sync(...) end
    if type(fn) ~= "function" then error(r and "export_not_found" or "export_resource_unavailable", 0) end
    return fn(...)
end
H.resources.open77_uikit = {
    progress = function() return { ok = true } end,
    input = function() return { ok = false } end,
}

-- ---------------------------------------------------------------------------
-- Database: callback form with (value, reason), error injection through H.sqlFail
-- ---------------------------------------------------------------------------
H.sqlFail = {}  -- [plain substring] = reason (one shot unless .sticky)
local function runSql(sql, params)
    for needle, reason in pairs(H.sqlFail) do
        if sql:find(needle, 1, true) then
            if type(reason) == "table" then return nil, reason.reason end
            H.sqlFail[needle] = nil
            return nil, reason
        end
    end
    if not H.sql then error("txhost: no SQL interpreter", 2) end
    return H.sql(sql, params or {})
end
local function dbMethod()
    return setmetatable({
        await = function(sql, params)
            local v, reason = runSql(sql, params)
            if reason then error(reason, 0) end
            return v
        end,
    }, {
        __call = function(_, sql, params, cb)
            if H.dbMode == "none" then
                if cb then cb(nil, "database_unavailable") end
                return false, "database_unavailable"
            end
            local v, reason = runSql(sql, params)
            if cb then cb(v, reason) end
            return true
        end,
    })
end
Open77.database.query, Open77.database.update = dbMethod(), dbMethod()
Open77.database.single, Open77.database.scalar, Open77.database.insert = dbMethod(), dbMethod(), dbMethod()

-- The statements rp_inventory issues (legacy store, import markers, information_schema), over
-- H.stores.sql.inv, which survives H.boot.
local LEGACY_COLUMNS = {
    rp_inventory_items = { { name = "identifier", type = "varchar(64)" }, { name = "item_id", type = "varchar(32)" },
        { name = "count", type = "int(11)" } },
    rp_inventory_stashes = { { name = "stash_id", type = "varchar(64)" }, { name = "item_id", type = "varchar(32)" },
        { name = "count", type = "int(11)" } },
}
function H.inventoryDb()
    local db = H.stores.sql.inv
    if not db then
        db = { items = {}, stashes = {}, markers = {}, tables = {}, writes = 0 }
        H.stores.sql.inv = db
    end
    return db
end
local function rowsOf(map, key)
    local out = {}
    for item, n in pairs(map[key] or {}) do out[#out + 1] = { item_id = item, count = n } end
    table.sort(out, function(a, b) return a.item_id < b.item_id end)
    return out
end
function H.inventorySql(sql, p)
    local db = H.inventoryDb()
    if sql:find("CREATE TABLE IF NOT EXISTS rp_inventory_migrations", 1, true) then
        db.tables.rp_inventory_migrations = true
        return 0
    end
    if sql:find("CREATE TABLE IF NOT EXISTS rp_inventory_items", 1, true) then db.tables.rp_inventory_items = true; return 0 end
    if sql:find("CREATE TABLE IF NOT EXISTS rp_inventory_stashes", 1, true) then db.tables.rp_inventory_stashes = true; return 0 end
    if sql:find("information_schema.COLUMNS", 1, true) then
        if not db.tables[p[1]] then return {} end
        return (db.columns and db.columns[p[1]]) or LEGACY_COLUMNS[p[1]] or {}
    end
    if sql:find("SELECT item_id, count FROM rp_inventory_items WHERE identifier = ?", 1, true) then return rowsOf(db.items, p[1]) end
    if sql:find("SELECT item_id, count FROM rp_inventory_stashes WHERE stash_id = ?", 1, true) then return rowsOf(db.stashes, p[1]) end
    if sql:find("FROM rp_inventory_migrations WHERE account = ?", 1, true) then
        local m = db.markers[p[1]]
        return m and { { version = m.version, op_id = m.op_id, source_rows = m.source_rows, source_hash = m.source_hash } } or {}
    end
    if sql:find("INSERT INTO rp_inventory_migrations", 1, true) then
        if db.markers[p[1]] then return nil, "database_conflict (SQL 1062): duplicate" end
        for i = 1, 9 do if p[i] == nil then return nil, "invalid_parameters" end end
        db.markers[p[1]] = { version = p[2], op_id = p[3], source_rows = p[4], source_hash = p[5], weight_g = p[6],
            capacity_g = p[7], report = p[8], migrated_at = p[9] }
        return 1
    end
    if sql:find("UPDATE rp_inventory_migrations SET source_hash", 1, true) then
        local m = db.markers[p[3]]
        if not m then return 0 end
        m.source_hash, m.source_rows = p[1], p[2]
        return 1
    end
    local distinct, tbl = sql:match("SELECT DISTINCT ([%w_]+) AS k FROM (rp_inventory_[%w_]+) WHERE")
    if distinct then
        local map = tbl == "rp_inventory_items" and db.items or db.stashes
        local keys = {}
        for k in pairs(map) do if k > p[1] then keys[#keys + 1] = k end end
        table.sort(keys)
        local out = {}
        for i = 1, math.min(200, #keys) do out[i] = { k = keys[i] } end
        return out
    end
    -- Legacy write-through (rp_inventory legacy backend).
    if sql:find("INSERT INTO rp_inventory_items", 1, true) then
        db.writes = db.writes + 1
        db.items[p[1]] = db.items[p[1]] or {}
        db.items[p[1]][p[2]] = p[3]
        return 1
    end
    if sql:find("DELETE FROM rp_inventory_items", 1, true) then
        db.writes = db.writes + 1
        if db.items[p[1]] then db.items[p[1]][p[2]] = nil end
        return 1
    end
    if sql:find("INSERT INTO rp_inventory_stashes", 1, true) then
        db.writes = db.writes + 1
        db.stashes[p[1]] = db.stashes[p[1]] or {}
        db.stashes[p[1]][p[2]] = p[3]
        return 1
    end
    if sql:find("DELETE FROM rp_inventory_stashes", 1, true) then
        db.writes = db.writes + 1
        if db.stashes[p[1]] then db.stashes[p[1]][p[2]] = nil end
        return 1
    end
    error("txhost: unexpected SQL: " .. sql)
end

-- ---------------------------------------------------------------------------
-- open77_transactions: the FINAL coordinator (vendored, txsandbox.lua), its real exports
-- ---------------------------------------------------------------------------
dofile(HARNESS .. "/txsandbox.lua")

TX = TX or {}
-- Operator settings of the test server (the coordinator's tunables). Nothing mints by default
-- (contract section 12.6): rp_inventory mints and burns on behalf of legacy callers through
-- sys:<caller> accounts, the migration from sys:migration, and the scenarios' foreign writers
-- seed from sys:seed. Writers: every resource (the default, `*`).
TX.TUNABLES = {
    serverTag = "lab", writers = "*",
    mint1 = "rp_inventory sys:* * 100000000; rp_inventory sys:* money 1000000000000",
    mint2 = "compat_seed sys:* * 100000000; rp_other sys:* * 100000000",
}

local function caller() return H.resource or "rp_inventory" end

-- H.resources entry for the coordinator: each export is { cps, sync } over the sandbox, so
-- Open77.exports.call dispatches a coordinator task and callSync runs it inline.
local exportsTable = setmetatable({}, { __index = function(_, name)
    if not TXS.running or not TXS.exports[name] then return nil end
    return {
        cps = function(done, ...)
            local ok, why = TXS.call(caller(), name, function(okRun, ...)
                if okRun then done(...) else done(nil, "export_raised " .. tostring((...))) end
            end, ...)
            if not ok then done(nil, why) end
        end,
        sync = function(...) return TXS.callSync(caller(), name, ...) end,
    }
end })

-- Direct calls on the coordinator object (a scenario's foreign writer, seeding): the real
-- coordinator answers store results on main.lua's work queue, so after each call its own
-- scheduler is pumped (no clock time passes, nothing else runs) until the work settles, as the
-- wave-0 harness answered at once. With a deferred store the commit still waits for a flush.
function TX.pump(passes)
    for _ = 1, passes or 16 do TXS.step(true) end
end

function TX.direct(co)
    return setmetatable({}, {
        __index = function(_, key)
            local value = co[key]
            if type(value) ~= "function" then return value end
            return function(_, ...)
                local r = table.pack(value(co, ...))
                TX.pump()
                return table.unpack(r, 1, r.n)
            end
        end,
        __newindex = function(_, key, value) co[key] = value end,
    })
end

-- (Re)starts the coordinator resource. keepStore: a restart over the same store (the database
-- survives); storeMode "lab_kvp" boots it in its lab store (both switches set); tunables merge.
-- The boot (schema, self-test, ready) runs at once on the coordinator's own scheduler.
function TX.start(options)
    options = options or {}
    TX.storeMode = options.storeMode or "sql"
    local tunables = { store = TX.storeMode == "lab_kvp" and "lab_kvp" or "sql" }
    -- Every start begins from the test server's settings (a scenario's overrides do not leak).
    TXS.tunables = {}
    for k, v in pairs(TX.TUNABLES) do tunables[k] = v end
    for k, v in pairs(options.tunables or {}) do tunables[k] = v end
    local convars = { open77_transactions_lab = TX.storeMode == "lab_kvp" and "1" or "0",
        sv_masterServerEnabled = TX.storeMode == "lab_kvp" and "false" or "true" }
    TXS.start({ keepStore = options.keepStore, tunables = tunables, convars = convars, dbMode = options.dbMode or "sql" })
    TX.store, TX.co = TXS.store, TX.direct(TXS.co)
    H.down.open77_transactions = nil
    H.resources.open77_transactions = exportsTable
    for _ = 1, 64 do
        if TXS.ready() then break end
        TXS.step()
    end
    return TX.co
end

-- The coordinator resource stops: its exports vanish and every pending call is rejected the way
-- the export broker does (export_resource_stopped: the caller cannot know whether it ran).
function TX.stop()
    H.down.open77_transactions = true
    for p in pairs(H.pendingExports.open77_transactions or {}) do p:reject("export_resource_stopped") end
    H.pendingExports.open77_transactions = {}
    TXS.stop()
end

-- A coordinator crash: requests already sent to the database still execute (runDetached, A13 D6),
-- their answers are lost, and a new VM starts over the same store.
function TX.crash()
    TX.stop()
    TX.store:runDetached()
    TX.start({ keepStore = true, storeMode = TX.storeMode })
end

-- Totals across every container of the store, for conservation checks.
function TX.total(item)
    local n = 0
    for _, c in pairs(TX.store.containers) do n = n + (c.stacks[item] or 0) end
    return n
end
function TX.instancesOf(item)
    local n = 0
    for _, i in pairs(TX.store.instances) do
        if i.item == item and not i.container:match("^sys:") then n = n + 1 end
    end
    return n
end
function TX.count(account, item) return TX.store:count(account, item) end
-- Committed business operations (a kind, or all but the coordinator's own `reweigh`).
function TX.ops(kind)
    local n = 0
    for _, op in pairs(TX.store.ops) do
        if op.state == "committed" and ((kind and op.kind == kind) or (not kind and op.kind ~= "reweigh")) then n = n + 1 end
    end
    return n
end

-- ---------------------------------------------------------------------------
-- rp_inventory boot: the manifest's script order, then H.boot on server/main.lua
-- ---------------------------------------------------------------------------
function H.bootInventory(options)
    options = options or {}
    H.sql = options.sql or H.inventorySql
    H.convars.rp_inventory_backend = options.backend
    local root = REPO .. "/rp_inventory/"
    dofile(root .. "shared/items.lua")
    for k, v in pairs(options.config or {}) do RpInventoryConfig[k] = v end
    dofile(root .. "shared/schema.lua")
    dofile(root .. "server/accounts.lua")
    dofile(root .. "server/facade.lua")
    dofile(root .. "server/migration.lua")
    H.client, H.chat = {}, {}
    local exports_ = realBoot("rp_inventory", root .. "server/main.lua", options.dbMode or "sql",
        options.players or {}, options.settle or 20)
    return exports_
end

-- Runs fn as a managed task and returns a box filled with its results once it finishes.
function H.task(fn)
    local box = { done = false }
    CreateThread(function()
        local r = table.pack(fn())
        box.done, box.r = true, r
        box[1], box[2], box[3] = r[1], r[2], r[3]
    end)
    return box
end

-- Calls an export the way another resource would (sets the invoking resource for its body).
function H.as(resource, fn, ...)
    local before = H.invoker
    H.invoker = resource
    local r = table.pack(fn(...))
    H.invoker = before
    return table.unpack(r, 1, r.n)
end
