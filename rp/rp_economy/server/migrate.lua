-- rp_economy / server/migrate.lua: one-shot import of the 1.x wallet tables into the coordinator.
--
-- Source (frozen at cutover, never written again; kept as a read-only archive):
--   rp_economy_wallets   cash per identifier            -> cash:<subject>
--   rp_bank_accounts     bank account per identifier    -> bank:<subject>
--   rp_bank_societies    society funds per name         -> soc:<name>
--   rp_bank_transactions the 1.x ledger                 -> NOT imported; rp_bank's statement
--                                                          reads it as history
--
-- One journaled coordinator operation per subject (cash and bank lines from
-- sys:rp_economy:migration) and one per society, with deterministic ids
-- `rp.migrate.v1.s.<subject>` / `rp.migrate.v1.soc.<name>`: a re-run replays instead of paying
-- twice. The source is read in keyset pages (EconomyConfig.migration.pageSize rows, far below the
-- bridge's 10 000-row maxRows, whose truncation is silent: D8) and every table's row count is
-- checked against COUNT(*) before anything is marked complete. Rows that cannot be imported
-- (not a durable key, not an integer balance) are reported, never dropped silently.
--
-- State lives in rp_wallet_migration (one row, k = 1) with a schema version. Until the import is
-- complete, the wallet facade refuses every change with `migration_pending`: a player must not
-- receive a fresh starting balance and then the imported one on top. A state row written by a
-- newer version blocks the facade (`migration_version_newer`) instead of re-importing.
--
-- KVP values (the 1.x fallback store, keys balance:<identifier>) are never imported: the console
-- command `economy_kvp_report` lists how they differ from SQL so an operator can decide.

Migrate = {
    VERSION = 1,
    state = "unknown",   -- unknown | unavailable | pending | running | complete | failed | blocked
    reason = "migration_pending",
    running = false,
    last = nil,          -- summary of the last run
}

local DB = Open77.database
local cfg = EconomyConfig

local function log(fmt, ...)
    print(("[rp_economy] " .. fmt):format(...))
end

-- The archive tables keep their 1.x definitions, created when missing so that a server that
-- never ran 1.x answers "nothing to import" instead of a schema error.
local ARCHIVE_DDL = {
    [[
CREATE TABLE IF NOT EXISTS rp_economy_wallets (
    identifier VARCHAR(64) PRIMARY KEY,
    name VARCHAR(64),
    balance BIGINT NOT NULL,
    updated_at BIGINT NOT NULL
)
]],
    [[
        CREATE TABLE IF NOT EXISTS rp_bank_accounts (
            identifier VARCHAR(96) NOT NULL PRIMARY KEY,
            balance BIGINT NOT NULL DEFAULT 0,
            created_at BIGINT NOT NULL DEFAULT 0
        )
    ]],
    [[
        CREATE TABLE IF NOT EXISTS rp_bank_transactions (
            id BIGINT NOT NULL AUTO_INCREMENT PRIMARY KEY,
            identifier VARCHAR(96) NOT NULL,
            delta BIGINT NOT NULL,
            balance_after BIGINT NOT NULL,
            kind VARCHAR(32) NOT NULL,
            note VARCHAR(128) NULL,
            `at` BIGINT NOT NULL,
            INDEX idx_rp_bank_transactions_identifier (identifier, id)
        )
    ]],
    [[
        CREATE TABLE IF NOT EXISTS rp_bank_societies (
            name VARCHAR(64) NOT NULL PRIMARY KEY,
            balance BIGINT NOT NULL DEFAULT 0
        )
    ]],
}

local STATE_DDL = [[
CREATE TABLE IF NOT EXISTS rp_wallet_migration (
    k TINYINT NOT NULL PRIMARY KEY,
    schema_version INT NOT NULL,
    state VARCHAR(16) NOT NULL,
    run_id VARCHAR(64) NOT NULL,
    started_at BIGINT NOT NULL,
    finished_at BIGINT NOT NULL,
    subjects INT NOT NULL,
    societies INT NOT NULL,
    imported INT NOT NULL,
    skipped INT NOT NULL,
    report TEXT NULL
)
]]

local SQL_STATE_READ = "SELECT schema_version, state, run_id FROM rp_wallet_migration WHERE k = 1"
local SQL_STATE_WRITE = [[
INSERT INTO rp_wallet_migration (k, schema_version, state, run_id, started_at, finished_at, subjects, societies, imported, skipped, report)
VALUES (1, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
ON DUPLICATE KEY UPDATE schema_version = VALUES(schema_version), state = VALUES(state), run_id = VALUES(run_id),
    started_at = VALUES(started_at), finished_at = VALUES(finished_at), subjects = VALUES(subjects),
    societies = VALUES(societies), imported = VALUES(imported), skipped = VALUES(skipped), report = VALUES(report)
]]

-- A database call through the `.await` form (yields). The bridge may raise or answer nil, err.
local function q(kind, sql, params)
    local ok, result, err = pcall(DB[kind].await, sql, params)
    if not ok then return nil, tostring(result) end
    if result == nil and err ~= nil then return nil, tostring(err) end
    return result, nil
end

local function toInt(v)
    local n = tonumber(v)
    return n and math.tointeger(n) or nil
end

function Migrate.ready()
    return Migrate.state == "complete"
end

local function setState(state, reason)
    Migrate.state = state
    Migrate.reason = state == "complete" and nil or (reason or ("migration_" .. state))
end

local function writeState(state, runId, startedAt, summary, report)
    summary = summary or {}
    return q("update", SQL_STATE_WRITE, {
        Migrate.VERSION, state, runId, startedAt, math.floor(Open77.time.unix()),
        summary.subjects or 0, summary.societies or 0, summary.imported or 0, summary.skipped or 0,
        report or "",
    })
end

-- Decides whether the facade may serve wallets. Yields. Called whenever the coordinator turns
-- ready; cheap once complete.
function Migrate.check()
    if Migrate.state == "complete" or Migrate.state == "blocked" or Migrate.running then return end
    local ready, why = Open77.database.isReady()
    if not ready then
        -- No SQL bridge at all and a coordinator that is not SQL-backed (a disposable lab):
        -- there is no 1.x SQL data to import. A database that is merely late is waited for.
        if why == "database_unavailable" and Tx.store ~= "sql" then
            setState("complete")
            log("migration: no database on this server (coordinator store=%s), nothing to import", tostring(Tx.store))
            return
        end
        setState("unavailable", "store_unavailable")
        return
    end
    for _, ddl in ipairs(ARCHIVE_DDL) do
        local ok, err = q("update", ddl)
        if ok == nil and err then setState("unavailable", "store_unavailable") log("migration: archive schema: %s", err) return end
    end
    local ok, err = q("update", STATE_DDL)
    if ok == nil and err then setState("unavailable", "store_unavailable") log("migration: state schema: %s", err) return end
    local row, readErr = q("single", SQL_STATE_READ)
    if readErr then setState("unavailable", "store_unavailable") return end
    if row then
        local version = toInt(row.schema_version) or 0
        if version > Migrate.VERSION then
            setState("blocked", "migration_version_newer")
            Open77.log.error(("[rp_economy] rp_wallet_migration is at schema %d, this build knows %d: wallets refused (no re-import)")
                :format(version, Migrate.VERSION))
            return
        end
        if row.state == "complete" and version == Migrate.VERSION then
            setState("complete")
            return
        end
    end
    local total = 0
    for _, t in ipairs({ "rp_economy_wallets", "rp_bank_accounts", "rp_bank_societies" }) do
        local n, countErr = q("scalar", "SELECT COUNT(*) FROM " .. t)
        if countErr then setState("unavailable", "store_unavailable") return end
        total = total + (toInt(n) or 0)
    end
    if total == 0 then
        writeState("complete", "empty", math.floor(Open77.time.unix()), {}, "nothing to import")
        setState("complete")
        log("migration: no 1.x wallet data, nothing to import")
        return
    end
    setState("pending", "migration_pending")
    Open77.log.warn(("[rp_economy] %d 1.x wallet row(s) are not imported yet: wallets are refused until `economy_migrate` runs"):format(total))
    if cfg.migration.auto then
        Migrate.run("auto")
    end
end

-- Reads a whole table in keyset pages. visit(row) per row. Returns rows read | nil, reason.
local function page(tableName, keyCol, cols, visit)
    local size = cfg.migration.pageSize
    local last, total = "", 0
    while true do
        local sql = ("SELECT %s FROM %s WHERE %s > ? ORDER BY %s LIMIT %d"):format(cols, tableName, keyCol, keyCol, size)
        local rows, err = q("query", sql, { last })
        if rows == nil then return nil, err or "query_failed" end
        for _, row in ipairs(rows) do
            visit(row)
            total = total + 1
            last = tostring(row[keyCol])
        end
        if #rows < size then return total end
    end
end

local function count(tableName)
    local n, err = q("scalar", "SELECT COUNT(*) FROM " .. tableName)
    if err then return nil, err end
    return toInt(n) or 0
end

local function validBalance(v)
    local n = toInt(v)
    return n ~= nil and n >= 0 and n <= cfg.maxBalance, n
end

-- Imports everything. Yields (console command or boot thread). Returns the summary | nil, reason.
function Migrate.run(trigger)
    if Migrate.running then return nil, "migration_running" end
    if Migrate.state == "blocked" then return nil, Migrate.reason end
    if not Tx.healthy then return nil, "store_unavailable" end
    Migrate.running = true
    setState("running", "migration_pending")
    local startedAt = math.floor(Open77.time.unix())
    local runId = ("v%d-%s-%s"):format(Migrate.VERSION, cfg.serverTag, Wallets.base36(startedAt))
    writeState("running", runId, startedAt)
    log("migration %s started (%s)", runId, tostring(trigger))

    local subjects, societies, skipped = {}, {}, {}
    local function skip(tableName, key, reason)
        skipped[#skipped + 1] = ("%s:%s:%s"):format(tableName, tostring(key), reason)
    end
    local function subjectRow(identifier)
        local s = subjects[identifier]
        if not s then s = { cash = 0, bank = 0 } subjects[identifier] = s end
        return s
    end

    local function fail(reason)
        Migrate.running = false
        setState("failed", "migration_failed")
        writeState("failed", runId, startedAt, nil, reason)
        Open77.log.error("[rp_economy] migration " .. runId .. " failed: " .. tostring(reason))
        return nil, reason
    end

    local readers = {
        { table = "rp_economy_wallets", key = "identifier", cols = "identifier, balance", visit = function(row)
            local ok, n = validBalance(row.balance)
            if not Wallets.validSubject(row.identifier) then return skip("rp_economy_wallets", row.identifier, "invalid_subject") end
            if not ok then return skip("rp_economy_wallets", row.identifier, "invalid_balance") end
            subjectRow(row.identifier).cash = n
        end },
        { table = "rp_bank_accounts", key = "identifier", cols = "identifier, balance", visit = function(row)
            local ok, n = validBalance(row.balance)
            if not Wallets.validSubject(row.identifier) then return skip("rp_bank_accounts", row.identifier, "invalid_subject") end
            if not ok then return skip("rp_bank_accounts", row.identifier, "invalid_balance") end
            subjectRow(row.identifier).bank = n
        end },
        { table = "rp_bank_societies", key = "name", cols = "name, balance", visit = function(row)
            local ok, n = validBalance(row.balance)
            local name = Wallets.cleanSociety(row.name)
            if not name then return skip("rp_bank_societies", row.name, "invalid_society") end
            if not ok then return skip("rp_bank_societies", row.name, "invalid_balance") end
            societies[name] = (societies[name] or 0) + n
        end },
    }
    for _, r in ipairs(readers) do
        local before, err = count(r.table)
        if before == nil then return fail("count " .. r.table .. ": " .. tostring(err)) end
        local read, pageErr = page(r.table, r.key, r.cols, r.visit)
        if read == nil then return fail("read " .. r.table .. ": " .. tostring(pageErr)) end
        if read ~= before then
            return fail(("%s: read %d rows, COUNT(*) says %d (truncated or changing source)"):format(r.table, read, before))
        end
        log("migration: %s read %d row(s) in pages of %d", r.table, read, cfg.migration.pageSize)
    end

    -- Build one operation per subject and per society.
    local ops = {}
    local names = {}
    for identifier in pairs(subjects) do names[#names + 1] = identifier end
    table.sort(names)
    local empty = 0
    for _, identifier in ipairs(names) do
        local s = subjects[identifier]
        local lines = {}
        -- The wallets of an identifier are the provider's subject's (the identifier itself by
        -- default; a character override provider's key otherwise). The operation id stays named
        -- after the 1.x row, so a re-run under another provider is op_id_conflict, never a
        -- second import.
        local subject, subjectWhy = Tx.subjectOf({ identifier = identifier })
        if not subject or not Wallets.validSubject(subject) then
            skip("subject", identifier, tostring(subject and "invalid_subject" or subjectWhy))
            s = { cash = 0, bank = 0 }
        end
        if s.cash > 0 then lines[#lines + 1] = { money = s.cash, from = "sys:rp_economy:migration", to = "cash:" .. subject } end
        if s.bank > 0 then lines[#lines + 1] = { money = s.bank, from = "sys:rp_economy:migration", to = "bank:" .. subject } end
        if #lines == 0 then
            empty = empty + 1
        else
            ops[#ops + 1] = { opId = Wallets.opIdFor("rp.migrate.v1.s.", identifier), kind = "migrate",
                actor = lines[1].to, lines = lines }
        end
    end
    local socNames = {}
    for name in pairs(societies) do socNames[#socNames + 1] = name end
    table.sort(socNames)
    for _, name in ipairs(socNames) do
        if societies[name] > 0 then
            ops[#ops + 1] = { opId = Wallets.opIdFor("rp.migrate.v1.soc.", name), kind = "migrate",
                lines = { { money = societies[name], from = "sys:rp_economy:migration", to = "soc:" .. name } } }
        else
            empty = empty + 1
        end
    end

    -- Submit with a bounded window.
    local imported, already, failed, failures = 0, 0, 0, {}
    local nextIndex, done = 1, 0
    local workers = math.max(1, math.min(cfg.migration.parallel, #ops))
    for _ = 1, workers do
        CreateThread(function()
            while nextIndex <= #ops do
                local op = ops[nextIndex]
                nextIndex = nextIndex + 1
                local receipt, why, info = Tx.call("transfer", op)
                if type(receipt) == "table" then
                    if receipt.replay then already = already + 1 else imported = imported + 1 end
                elseif why == "already_committed" then
                    already = already + 1
                elseif why == "in_doubt" or why == "busy" then
                    local outcome = Tx.resolve(op.opId, 120)
                    if outcome == "committed" then imported = imported + 1
                    else failed = failed + 1 failures[#failures + 1] = op.opId .. ":" .. tostring(outcome) end
                else
                    failed = failed + 1
                    failures[#failures + 1] = op.opId .. ":" .. tostring(why)
                    Tx.noteFailure(why)
                end
                done = done + 1
            end
        end)
    end
    while done < #ops do Wait(0) end

    local summary = {
        subjects = #names, societies = #socNames, imported = imported, already = already,
        empty = empty, skipped = #skipped, failed = failed, operations = #ops,
    }
    Migrate.last = summary
    local reportParts = {}
    for i = 1, math.min(#skipped, cfg.migration.reportLimit) do
        reportParts[#reportParts + 1] = skipped[i]
        log("migration: skipped %s", skipped[i])
    end
    for i = 1, math.min(#failures, cfg.migration.reportLimit) do
        log("migration: failed %s", failures[i])
    end
    local report = ("imported=%d already=%d empty=%d skipped=%d failed=%d; %s"):format(
        imported, already, empty, #skipped, failed, table.concat(reportParts, "; "))
    if #report > 4000 then report = report:sub(1, 4000) end
    Migrate.running = false
    if failed > 0 then
        setState("failed", "migration_failed")
        writeState("failed", runId, startedAt, summary, report)
        Open77.log.error(("[rp_economy] migration %s: %d operation(s) failed; run economy_migrate again (it is idempotent)")
            :format(runId, failed))
        return nil, "migration_failed", summary
    end
    writeState("complete", runId, startedAt, summary, report)
    setState("complete")
    log("migration %s complete: subjects=%d societies=%d imported=%d already=%d empty=%d skipped=%d",
        runId, summary.subjects, summary.societies, imported, already, empty, #skipped)
    return summary
end

-- Society names of the 1.x archive (preloaded so their balances are known before first use).
-- Yields. Returns a list (empty when the archive is unreadable or absent).
function Migrate.archivedSocieties()
    local names = {}
    local ready = Open77.database.isReady()
    if not ready then return names end
    page("rp_bank_societies", "name", "name, balance", function(row)
        local name = Wallets.cleanSociety(row.name)
        if name then names[#names + 1] = name end
    end)
    return names
end

-- true: the account identifier had a 1.x wallet or bank row (no starting balance); false: new;
-- nil, err. The 1.x tables are keyed by identifier, never by a provider's subject.
function Migrate.isLegacySubject(subject)
    local ready, why = Open77.database.isReady()
    if not ready then
        if why == "database_unavailable" and Tx.store ~= "sql" then return false end
        return nil, why
    end
    local row, err = q("single", "SELECT balance FROM rp_economy_wallets WHERE identifier = ?", { subject })
    if err then return nil, err end
    if row then return true end
    row, err = q("single", "SELECT balance FROM rp_bank_accounts WHERE identifier = ?", { subject })
    if err then return nil, err end
    return row ~= nil
end

-- Lists, never imports, the 1.x KVP balances (this resource's own store) against SQL and the
-- coordinator. Yields. Returns the number of differing keys.
function Migrate.kvpReport()
    local keys = Open77.kvp.keys("balance:", 4096)
    if type(keys) ~= "table" then
        log("kvp_report: keys unreadable")
        return nil, "kvp_unreadable"
    end
    local differ = 0
    for _, key in ipairs(keys) do
        local identifier = key:sub(#"balance:" + 1)
        local kvp = toInt(Open77.kvp.get(key))
        local row = q("single", "SELECT balance FROM rp_economy_wallets WHERE identifier = ?", { identifier })
        local archived = row and toInt(row.balance) or nil
        local current
        if Wallets.validSubject(identifier) then
            local snap = Tx.read("cash:" .. identifier)
            current = type(snap) == "table" and toInt(snap.balance) or nil
        end
        local same = kvp ~= nil and kvp == archived
        if not same then differ = differ + 1 end
        log("kvp_report %s kvp=%s sql_1x=%s coordinator=%s %s", identifier, tostring(kvp), tostring(archived),
            tostring(current), same and "same" or "DIFFERS")
    end
    log("kvp_report: %d key(s), %d differ from the 1.x SQL row; nothing was imported", #keys, differ)
    return differ
end
