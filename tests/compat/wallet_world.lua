-- tests/compat/wallet_world.lua: fixtures for the B3 wallet scenarios, on multihost.lua.
--
-- String globals from the runner: ROOT_DIR (the pack), COMPAT_DIR (this folder), TX_DIR (the
-- final open77_transactions, Open77 697e9e2f: vendor/open77_transactions, or OP77_TX_DIR).
--
-- The coordinator is that resource, server/main.lua included, hosted by txhost_wallet.lua (the
-- test seam is txshim.lua); its memory store stands for the database and survives a "server
-- restart" (WW.keep / WW.boot{ keep = ... }). The 1.x wallet
-- tables are an in-memory SQL fixture (MH.shared.db) interpreted statement by statement, with the
-- bridge's silent maxRows truncation (D8) applied to every multi-row read.

WW = {}

WW.WEIGHTS = { scrap = 1000, component = 500, chip = 50, crowbar = 1500 }

-- Script list of a resource in manifest order (shared scripts first, client scripts skipped).
function WW.scripts(resource)
    local file = assert(io.open(ROOT_DIR .. "/" .. resource .. "/open77.lua", "rb"))
    local text = file:read("a")
    file:close()
    local shared, server = {}, {}
    for line in text:gmatch("[^\n]+") do
        if not line:match("^%s*%-%-") then
            local s = line:match('^%s*shared_script%s+"([^"]+)"')
            if s then shared[#shared + 1] = ROOT_DIR .. "/" .. resource .. "/" .. s end
            local v = line:match('^%s*server_script%s+"([^"]+)"')
            if v then server[#server + 1] = ROOT_DIR .. "/" .. resource .. "/" .. v end
        end
    end
    for _, path in ipairs(server) do shared[#shared + 1] = path end
    return shared
end

-- The coordinator's server scripts in its manifest's order, with the test host and the seam
-- loaded just before server/main.lua.
function WW.txScripts()
    local file = assert(io.open(TX_DIR .. "/open77.lua", "rb"))
    local text = file:read("a")
    file:close()
    local out = {}
    for line in text:gmatch("[^\n]+") do
        local s = not line:match("^%s*%-%-") and line:match('^%s*server_script%s+"([^"]+)"')
        if s then
            if s == "server/main.lua" then
                out[#out + 1] = COMPAT_DIR .. "/txhost_wallet.lua"
                out[#out + 1] = COMPAT_DIR .. "/txshim.lua"
            end
            out[#out + 1] = TX_DIR .. "/" .. s
        end
    end
    return out
end

function WW.txVersion()
    local file = assert(io.open(TX_DIR .. "/open77.lua", "rb"))
    local text = file:read("a")
    file:close()
    return text:match('version%s+"([^"]+)"')
end

-- The test server's coordinator settings (its tunables). Nothing mints by default (contract
-- 12.6): rp_economy creates money out of sys:<caller>:<label> accounts and keeps its own
-- allowlist per original caller (server/mint.lua), so the coordinator's rule for it is one
-- ceiling. `writers` stays `*` unless a scenario narrows it.
function WW.txTunables(opts)
    local t = {
        serverTag = "lab", writers = "*",
        mint1 = "rp_economy sys:* money 1000000000000",
    }
    for k, v in pairs(opts and opts.tunables or {}) do t[k] = v end
    return t
end

function WW.startCoordinator(opts)
    MH.tunables.open77_transactions = WW.txTunables(opts)
    MH.start("open77_transactions", WW.txScripts(), { host = true, metadata = { version = WW.txVersion() } })
end

-- ---------------------------------------------------------------------------------------------
-- The 1.x tables

function WW.freshDb()
    return { wallets = {}, accounts = {}, societies = {}, transactions = {}, state = nil,
        maxRows = 10000, truncated = 0, failing = false, statements = 0 }
end

local function tableOf(db, name)
    if name == "rp_economy_wallets" then return db.wallets end
    if name == "rp_bank_accounts" then return db.accounts end
    if name == "rp_bank_societies" then return db.societies end
    error("wallet_world: unknown table " .. tostring(name), 0)
end

local function truncate(db, rows)
    if #rows <= db.maxRows then return rows end
    db.truncated = db.truncated + 1
    local out = {}
    for i = 1, db.maxRows do out[i] = rows[i] end
    return out
end

function WW.sql(kind, sql, p)
    local db = MH.shared.db
    db.statements = db.statements + 1
    if db.failing then error("database_unreachable (SQL 2013): Lost connection to server during query", 0) end
    sql = sql:gsub("^%s+", ""):gsub("%s+$", "")
    if sql:find("^CREATE TABLE IF NOT EXISTS") then return 0 end
    if sql:find("FROM rp_wallet_migration WHERE k = 1", 1, true) then
        return db.state and MH.copy(db.state) or nil
    end
    if sql:find("^INSERT INTO rp_wallet_migration") then
        db.state = { schema_version = p[1], state = p[2], run_id = p[3], started_at = p[4], finished_at = p[5],
            subjects = p[6], societies = p[7], imported = p[8], skipped = p[9], report = p[10] }
        return 1
    end
    local countOf = sql:match("^SELECT COUNT%(%*%) FROM ([%w_]+)$")
    if countOf then
        local n = 0
        for _ in pairs(tableOf(db, countOf)) do n = n + 1 end
        return n
    end
    local name, keyCol, limit = sql:match("^SELECT [%w_, ]+ FROM ([%w_]+) WHERE ([%w_]+) > %? ORDER BY [%w_]+ LIMIT (%d+)$")
    if name then
        local t = tableOf(db, name)
        local keys = {}
        for k in pairs(t) do if k > p[1] then keys[#keys + 1] = k end end
        table.sort(keys)
        local rows = {}
        for i = 1, math.min(#keys, tonumber(limit)) do
            rows[i] = { [keyCol] = keys[i], balance = t[keys[i]].balance }
        end
        return truncate(db, rows)
    end
    local single = sql:match("^SELECT balance FROM ([%w_]+) WHERE identifier = %?$")
    if single then
        local row = tableOf(db, single)[p[1]]
        return row and { balance = row.balance } or nil
    end
    -- rp_bank 1.x boot load, kept to show the truncation it suffered (D8, A13 finding 4).
    if sql == "SELECT identifier, balance, created_at FROM rp_bank_accounts" then
        local keys = {}
        for k in pairs(db.accounts) do keys[#keys + 1] = k end
        table.sort(keys)
        local rows = {}
        for i, k in ipairs(keys) do rows[i] = { identifier = k, balance = db.accounts[k].balance, created_at = 0 } end
        return truncate(db, rows)
    end
    if sql:find("FROM rp_bank_transactions WHERE identifier = ?", 1, true) then
        local rows = {}
        for i = #db.transactions, 1, -1 do
            local r = db.transactions[i]
            if r.identifier == p[1] then
                rows[#rows + 1] = { delta = r.delta, balance_after = r.balance_after, kind = r.kind, note = r.note, at = r.at }
            end
        end
        local limit = tonumber(sql:match("LIMIT (%d+)$")) or #rows
        local out = {}
        for i = 1, math.min(#rows, limit) do out[i] = rows[i] end
        return out
    end
    error("wallet_world: unexpected SQL: " .. sql, 0)
end

-- ---------------------------------------------------------------------------------------------
-- Worlds

-- opts: keep (from WW.keep), db, dbMode, bank (start rp_bank), shims ({ name, source }),
-- noCoordinator, tunables (the coordinator's, merged over WW.txTunables), storeDown, settle
-- (seconds), auto (migration auto).
function WW.boot(opts)
    opts = opts or {}
    MH.reset()
    MH.sql = WW.sql
    if opts.keep and opts.keep.now then MH.now = opts.keep.now + 60 end
    if opts.keep then
        MH.shared.txStore = opts.keep.store
        MH.shared.db = opts.keep.db
        MH.kvp = opts.keep.kvp
    else
        MH.shared.db = opts.db or WW.freshDb()
    end
    MH.dbMode = opts.dbMode or "sql"
    if not opts.noCoordinator then
        if opts.storeDown and MH.shared.txStore then MH.shared.txStore.down = true end
        WW.startCoordinator(opts)
        if opts.storeDown then MH.shared.txStore.down = true end
    end
    for _, shim in ipairs(opts.shims or {}) do
        MH.start(shim.name, { { source = shim.source, name = "shim_" .. shim.name .. ".lua" } })
    end
    MH.start("rp_economy", WW.scripts("rp_economy"))
    if opts.auto ~= nil then MH.resources.rp_economy.env.EconomyConfig.migration.auto = opts.auto end
    if opts.bank then MH.start("rp_bank", WW.scripts("rp_bank")) end
    MH.run(opts.settle or 2)
end

-- What survives a server restart: the database (coordinator store + 1.x tables) and KVP files.
function WW.keep()
    return { store = MH.shared.txStore, db = MH.shared.db, kvp = MH.kvp, now = MH.now }
end

-- A crash: work queued in the store either never reached the database ("discard") or executes
-- with nobody listening ("detached").
function WW.crash(mode)
    local store = MH.shared.txStore
    if mode == "detached" then store:runDetached() else store:discard() end
    return WW.keep()
end

function WW.tx() return MH.shared.tx end
function WW.store() return MH.shared.txStore end

function WW.connect(id, identifier, name)
    MH.connect(id, { identifier = identifier, name = name or ("player" .. id), position = { x = 0, y = 0, z = 0 } })
end

-- Connects a player and runs until rp_economy has loaded the wallets and every operation of the
-- join (the starting balance) has settled.
function WW.join(id, identifier, name)
    WW.connect(id, identifier, name)
    local env = MH.resources.rp_economy.env
    MH.until_(function() return env.Wallets.byPlayer[id] ~= nil end, 30)
    WW.settle()
end

-- Runs until every wallet operation of rp_economy has settled (or `seconds`): no operation
-- pending in the facade, none queued in the store, none active in the coordinator, for two
-- simulated seconds in a row (a join's start grant is submitted only after an archive read, and
-- the coordinator settles a commit over several passes of its work queue).
function WW.settle(seconds)
    local env = MH.resources.rp_economy and MH.resources.rp_economy.env
    local since
    MH.until_(function()
        local idle = not env or (env.Wallets.pendingCount() == 0 and MH.shared.txStore:pending() == 0
            and (not MH.shared.tx or MH.shared.tx:health().active == 0))
        if not idle then since = nil return false end
        since = since or MH.now
        return MH.now - since >= 2
    end, seconds or 30)
    MH.run(1)
end

function WW.economy() return MH.resources.rp_economy.env end

-- Runs until rp_economy's coordinator probe reports healthy again (after an outage or a crash).
function WW.healthy(seconds)
    local env = MH.resources.rp_economy.env
    return MH.until_(function() return env.Tx.healthy end, seconds or 30)
end

-- Synchronous export call as resource `from`: returns a, b (or nil, "raised:<msg>").
function WW.sync(from, target, name, ...)
    local res = table.pack(MH.callSync(from, target, name, ...))
    if not res[1] then return nil, "raised:" .. tostring(res[2]) end
    return table.unpack(res, 2, res.n)
end

-- Asynchronous export call as resource `from`, awaited.
function WW.async(from, target, name, ...)
    return MH.callAsync(from, target, name, ...)
end

-- Durable money of an account in the coordinator store (the "database").
function WW.balance(id) return MH.shared.txStore:balance(id) end
function WW.count(id, item) return MH.shared.txStore:count(id, item) end

-- Sum of the journal deltas of one account and asset (what a sys: account absorbed).
function WW.journalTotal(account, asset)
    local total = 0
    for _, e in ipairs(MH.shared.txStore.journal) do
        if e.account == account and e.asset == asset then total = total + e.delta end
    end
    return total
end

-- A do-nothing resource that only exists to be a caller with a name (mint allowlist keys).
function WW.shim(name, source)
    return { name = name, source = source or "-- caller shim\n" }
end

-- Registers item definitions in the coordinator as a B2 adapter would.
WW.DEFINER = WW.shim("inventory_shim", [[
-- Defines at its own start and again whenever the coordinator (re)starts: definitions live in
-- the coordinator's memory, like rp_inventory's redefinition handshake (B8 §5.1).
AddEventHandler("onResourceStart", function(name)
    if name ~= GetCurrentResourceName() and name ~= "open77_transactions" then return end
    CreateThread(function()
        local p = Open77.exports.call("open77_transactions", "define", {
            scrap = { weightG = 1000 }, component = { weightG = 500 }, chip = { weightG = 50 },
            crowbar = { weightG = 1500, unique = true },
        })
        if p then p:await() end
    end)
end)
]])

-- Flattens a result table into "k=v" lines (the runner's format).
function WW.result(t)
    t.errors = #MH.errors
    t.first_error = MH.errors[1] or ""
    local lines = {}
    for k, v in pairs(t) do lines[#lines + 1] = k .. "=" .. tostring(v) end
    table.sort(lines)
    return table.concat(lines, "\n")
end
