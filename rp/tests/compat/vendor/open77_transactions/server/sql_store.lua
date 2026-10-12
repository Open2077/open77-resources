-- =============================================================================
-- open77_transactions -- server/sql_store.lua
-- =============================================================================
-- The SQL side of the A13 contract (section 4 of
-- docs/world-interaction/a13-transaction-contract.md):
--
--   Open77TxSql.MIGRATIONS        forward migrations; [1] is the initial schema
--                                 (InnoDB, op77_tx_* tables, guard row)
--   Open77TxSql.buildCommit(plan) ONE transaction: op row first, then sorted
--                                 deltas, each condition followed by a guard
--                                 assertion, then the journal in chunks
--   Open77TxSql.classify(err)     bridge error text -> conflict | failed |
--                                 transient | ambiguous
--   Open77TxSql.newStore(db, o)   adapter over the oxmysql-shaped MySQL table
--                                 (callback forms), same interface as the
--                                 memory store, plus the boot steps (migrate,
--                                 selfTest) and maintenance (purge, list)
--
-- Facts it relies on (Open77 source, 2026-10-12): a transaction returns only
-- ok (DatabaseService.cs:384-408), 64 statements x 64 parameters x 64 KiB
-- (LuaResourceRuntime.cs:4883-4885), 1062 -> "database_conflict"
-- (DatabaseHealth.cs:54), the SQL error number is carried in the text as
-- "(SQL n)" (DatabaseService.SafeFailureText). Measured against MariaDB by
-- TransactionsMariaDbTests (contract section 10, I1-I3).
--
-- Global: Open77TxSql.
-- =============================================================================

Open77TxSql = {}
local Q = Open77TxSql
local M = Open77TxModel

Q.TABLES = {
    "op77_tx_schema", "op77_tx_containers", "op77_tx_stacks", "op77_tx_instances",
    "op77_tx_wallets", "op77_tx_ops", "op77_tx_journal", "op77_tx_guard",
}

-- Forward migrations. Each entry is applied once, in order, and must be
-- idempotent (a second server booting against the same database may replay
-- a step it raced on): CREATE TABLE IF NOT EXISTS, ADD COLUMN IF NOT EXISTS,
-- INSERT IGNORE. Never edit a shipped entry; append a new one.
Q.MIGRATIONS = {
    [1] = {
        [[CREATE TABLE IF NOT EXISTS op77_tx_containers (
  container_id VARCHAR(96) NOT NULL PRIMARY KEY,
  kind VARCHAR(16) NOT NULL,
  capacity_g BIGINT NOT NULL,
  weight_g BIGINT NOT NULL DEFAULT 0,
  slots INT NULL,
  meta TEXT NULL,
  expires_at BIGINT NULL,
  version BIGINT NOT NULL DEFAULT 0,
  last_op VARCHAR(96) NULL,
  updated_at BIGINT NOT NULL,
  INDEX idx_op77_tx_containers_kind (kind, container_id)
) ENGINE=InnoDB]],
        [[CREATE TABLE IF NOT EXISTS op77_tx_stacks (
  container_id VARCHAR(96) NOT NULL,
  item_id VARCHAR(64) NOT NULL,
  count BIGINT NOT NULL,
  last_op VARCHAR(96) NULL,
  PRIMARY KEY (container_id, item_id)
) ENGINE=InnoDB]],
        [[CREATE TABLE IF NOT EXISTS op77_tx_instances (
  instance_id VARCHAR(64) NOT NULL PRIMARY KEY,
  item_id VARCHAR(64) NOT NULL,
  container_id VARCHAR(96) NOT NULL,
  meta TEXT NOT NULL,
  version BIGINT NOT NULL DEFAULT 0,
  last_op VARCHAR(96) NULL,
  INDEX idx_op77_tx_instances_container (container_id)
) ENGINE=InnoDB]],
        [[CREATE TABLE IF NOT EXISTS op77_tx_wallets (
  account_id VARCHAR(96) NOT NULL PRIMARY KEY,
  balance BIGINT NOT NULL,
  version BIGINT NOT NULL DEFAULT 0,
  last_op VARCHAR(96) NULL,
  updated_at BIGINT NOT NULL
) ENGINE=InnoDB]],
        [[CREATE TABLE IF NOT EXISTS op77_tx_ops (
  op_id VARCHAR(96) NOT NULL PRIMARY KEY,
  kind VARCHAR(32) NOT NULL,
  actor VARCHAR(96) NULL,
  resource VARCHAR(64) NOT NULL,
  state VARCHAR(12) NOT NULL,
  request_hash CHAR(16) NOT NULL,
  receipt TEXT NOT NULL,
  created_at BIGINT NOT NULL,
  INDEX idx_op77_tx_ops_actor (actor, created_at),
  INDEX idx_op77_tx_ops_created (created_at)
) ENGINE=InnoDB]],
        [[CREATE TABLE IF NOT EXISTS op77_tx_journal (
  op_id VARCHAR(96) NOT NULL,
  line SMALLINT NOT NULL,
  account_id VARCHAR(96) NOT NULL,
  asset VARCHAR(72) NOT NULL,
  delta BIGINT NOT NULL,
  reason VARCHAR(64) NOT NULL DEFAULT '',
  created_at BIGINT NOT NULL,
  PRIMARY KEY (op_id, line),
  INDEX idx_op77_tx_journal_account (account_id, created_at),
  INDEX idx_op77_tx_journal_created (created_at)
) ENGINE=InnoDB]],
        [[CREATE TABLE IF NOT EXISTS op77_tx_guard (k TINYINT NOT NULL PRIMARY KEY) ENGINE=InnoDB]],
        [[INSERT IGNORE INTO op77_tx_guard (k) VALUES (1)]],
    },
}
Q.SCHEMA_VERSION = #Q.MIGRATIONS

Q.SCHEMA_TABLE = [[CREATE TABLE IF NOT EXISTS op77_tx_schema (
  k TINYINT NOT NULL PRIMARY KEY,
  version INT NOT NULL,
  updated_at BIGINT NOT NULL
) ENGINE=InnoDB]]

-- The whole DDL in boot order (schema table first), for shape tests.
Q.SCHEMA = { Q.SCHEMA_TABLE }
for _, ddl in ipairs(Q.MIGRATIONS[1]) do Q.SCHEMA[#Q.SCHEMA + 1] = ddl end

-- The assertion idiom: insert the guard's existing key exactly when the
-- condition does NOT hold -> 1062 -> the whole transaction rolls back.
local function assertion(table, where, values)
    return {
        query = "INSERT INTO op77_tx_guard (k) SELECT 1 FROM DUAL WHERE NOT EXISTS (SELECT 1 FROM "
            .. table .. " WHERE " .. where .. ")",
        values = values,
    }
end

function Q.buildCommit(plan, encode)
    encode = encode or M.encode
    local op, now = plan.opId, plan.createdAt or 0
    local out = {}
    local function add(statement) out[#out + 1] = statement end

    add({
        query = "INSERT INTO op77_tx_ops (op_id, kind, actor, resource, state, request_hash, receipt, created_at) "
            .. "VALUES (?, ?, ?, ?, 'committed', ?, ?, ?)",
        -- Never a nil parameter: the bridge requires a contiguous 1..n
        -- positional range (LuaResourceRuntime.cs:5800-5840), so NULL cannot
        -- be bound positionally. An absent actor is stored as ''.
        values = { op, plan.kind or "", plan.actor or "", plan.resource or "", plan.hash or "",
            encode(plan.receipt or {}), now },
    })

    for _, c in ipairs(plan.containers) do
        add({
            query = "UPDATE op77_tx_containers SET weight_g = weight_g + ?, version = version + 1, "
                .. "last_op = ?, updated_at = ? WHERE container_id = ?",
            values = { c.weightDelta, op, now, c.id },
        })
        local where = "container_id = ? AND last_op = ? AND weight_g >= 0"
        local values = { c.id, op }
        if c.weightDelta > 0 and not c.reweigh then where = where .. " AND weight_g <= capacity_g" end
        if c.expectVersion ~= nil then
            where = where .. " AND version = ?"
            values[#values + 1] = c.expectVersion + 1
        end
        add(assertion("op77_tx_containers", where, values))
    end

    for _, s in ipairs(plan.stacks) do
        if s.delta < 0 then
            add({
                query = "UPDATE op77_tx_stacks SET count = count - ?, last_op = ? WHERE container_id = ? AND item_id = ?",
                values = { -s.delta, op, s.container, s.item },
            })
            add(assertion("op77_tx_stacks", "container_id = ? AND item_id = ? AND last_op = ? AND count >= 0",
                { s.container, s.item, op }))
        else
            add({
                query = "INSERT INTO op77_tx_stacks (container_id, item_id, count, last_op) VALUES (?, ?, ?, ?) "
                    .. "ON DUPLICATE KEY UPDATE count = count + ?, last_op = ?",
                values = { s.container, s.item, s.delta, op, s.delta, op },
            })
        end
    end

    for _, i in ipairs(plan.instances) do
        if i.create then
            add({
                query = "INSERT INTO op77_tx_instances (instance_id, item_id, container_id, meta, version, last_op) "
                    .. "VALUES (?, ?, ?, ?, 1, ?)",
                values = { i.id, i.item, i.to, encode(i.meta or {}), op },
            })
        else
            if i.meta ~= nil then
                add({
                    query = "UPDATE op77_tx_instances SET container_id = ?, meta = ?, version = version + 1, "
                        .. "last_op = ? WHERE instance_id = ? AND container_id = ? AND version = ?",
                    values = { i.to, encode(i.meta), op, i.id, i.from, i.expectVersion },
                })
            else
                add({
                    query = "UPDATE op77_tx_instances SET container_id = ?, version = version + 1, "
                        .. "last_op = ? WHERE instance_id = ? AND container_id = ? AND version = ?",
                    values = { i.to, op, i.id, i.from, i.expectVersion },
                })
            end
        end
        add(assertion("op77_tx_instances", "instance_id = ? AND last_op = ?", { i.id, op }))
    end

    for _, w in ipairs(plan.wallets) do
        local where, values
        if w.delta > 0 then
            add({
                query = "INSERT INTO op77_tx_wallets (account_id, balance, version, last_op, updated_at) "
                    .. "VALUES (?, ?, 1, ?, ?) ON DUPLICATE KEY UPDATE balance = balance + ?, "
                    .. "version = version + 1, last_op = ?, updated_at = ?",
                values = { w.id, w.delta, op, now, w.delta, op, now },
            })
            where, values = "account_id = ? AND last_op = ? AND balance <= ?", { w.id, op, M.LIMITS.maxMoney }
        else
            add({
                query = "UPDATE op77_tx_wallets SET balance = balance + ?, version = version + 1, "
                    .. "last_op = ?, updated_at = ? WHERE account_id = ?",
                values = { w.delta, op, now, w.id },
            })
            where, values = "account_id = ? AND last_op = ? AND balance >= 0", { w.id, op }
        end
        if w.expectVersion ~= nil then
            where = where .. " AND version = ?"
            values[#values + 1] = w.expectVersion + 1
        end
        add(assertion("op77_tx_wallets", where, values))
    end

    local per = M.LIMITS.journalRowsPerStatement
    for first = 1, #plan.journal, per do
        local rows, values = {}, {}
        for index = first, math.min(first + per - 1, #plan.journal) do
            local e = plan.journal[index]
            rows[#rows + 1] = "(?, ?, ?, ?, ?, ?, ?)"
            for _, v in ipairs({ op, index, e.account, e.asset, e.delta, e.reason or "", now }) do
                values[#values + 1] = v
            end
        end
        add({
            query = "INSERT INTO op77_tx_journal (op_id, line, account_id, asset, delta, reason, created_at) VALUES "
                .. table.concat(rows, ", "),
            values = values,
        })
    end
    return out
end

-- Checks a statement list against the bridge's own rules (D3): at most 64
-- statements, 64 KiB of SQL and 64 parameters each, and a contiguous non-nil
-- 1..n positional range whose length equals the number of '?' (the builder
-- never puts a '?' inside a string literal).
function Q.validate(statements)
    if #statements < 1 or #statements > M.LIMITS.maxStatements then return nil, "operation_too_large" end
    for index, s in ipairs(statements) do
        if #s.query > M.LIMITS.maxSqlBytes then return nil, "operation_too_large", index end
        local placeholders = select(2, s.query:gsub("%?", ""))
        if placeholders > M.LIMITS.maxParameters then return nil, "operation_too_large", index end
        local n = 0
        for k in pairs(s.values or {}) do
            if math.type(k) ~= "integer" or k < 1 then return nil, "invalid_parameters", index end
            if k > n then n = k end
        end
        for k = 1, n do
            if s.values[k] == nil then return nil, "invalid_parameters", index end
        end
        if n ~= placeholders then return nil, "parameter_count_mismatch", index end
    end
    return true
end

function Q.fence(opId, meta, now)
    return {
        query = "INSERT INTO op77_tx_ops (op_id, kind, actor, resource, state, request_hash, receipt, created_at) "
            .. "VALUES (?, 'fence', NULL, ?, 'aborted', ?, '{}', ?)",
        values = { opId, (meta and meta.resource) or "", (meta and meta.hash) or "", now or 0 },
    }
end

Q.READ_OP = "SELECT state, request_hash, receipt FROM op77_tx_ops WHERE op_id = ?"

-- Bridge error text (DatabaseHealth.Describe codes, or a submit refusal) to the
-- coordinator's classes:
--   conflict   1062 at a statement, before COMMIT: definitive (duplicate opId
--              or a failed guard assertion)
--   failed     schema/syntax/permission/configuration: definitive, an
--              operator must act
--   transient  deadlock 1213 or lock-wait timeout 1205: InnoDB rolled the
--              transaction back (the bridge never commits after a failed
--              statement), so nothing landed and the SAME plan may be
--              resubmitted
--   ambiguous  everything else -- unreachable, a lost connection, an unknown
--              failure, a timeout -- may hide a COMMIT that landed
local DEFINITIVE = {
    "database_schema_error", "database_query_error", "database_permission_denied",
    "database_configuration_error", "database_missing", "database_auth_failed",
}

function Q.classify(err)
    local text = tostring(err or "")
    if text:find("database_conflict", 1, true) then return "conflict" end
    for _, code in ipairs(DEFINITIVE) do
        if text:find(code, 1, true) then return "failed" end
    end
    if text:find("(SQL 1213)", 1, true) or text:find("(SQL 1205)", 1, true) then return "transient" end
    return "ambiguous"
end

-- Submit-time refusals never reached the database (LuaResourceRuntime.cs
-- MySqlRequest / TryReadTransaction): definitive, nothing to fence. Matched on
-- the leading token, because some carry a detail suffix
-- ("parameter_count_mismatch: found ...").
local SUBMIT_REFUSALS = {
    ["database_unavailable"] = true, ["permission_denied:database.access"] = true,
    ["invalid_sql"] = true, ["invalid_transaction"] = true, ["too_many_parameters"] = true,
    ["invalid_parameters"] = true, ["parameter_count_mismatch"] = true, ["invalid_kind"] = true,
    ["invalid_request_id"] = true,
}

function Q.isSubmitRefusal(err)
    local token = tostring(err or ""):match("^[%w_:%.]+")
    return token ~= nil and SUBMIT_REFUSALS[token] == true
end

local function int(v)
    if v == nil then return nil end
    return math.tointeger(v) or math.tointeger(tonumber(v))
end

-- ---------------------------------------------------------------------------
-- Adapter over the MySQL table (callback forms; never yields itself).
-- options.encode / options.decode: JSON (the runtime's json.encode/decode).
-- options.slots: most stacks/instances one container read may return.
-- ---------------------------------------------------------------------------
function Q.newStore(db, options)
    options = options or {}
    local encode = options.encode or M.encode
    local decode = options.decode or function() return nil end
    local now = options.now or function() return 0 end
    local maxRows = options.maxRows or 512
    local store = { kind = "sql" }

    local function decodeMeta(text)
        if type(text) ~= "string" or text == "" then return nil end
        local ok, value = pcall(decode, text)
        if ok and type(value) == "table" then return value end
        return nil
    end

    function store:load(id, cb)
        local kind = M.accountKind(id)
        if kind == "wallet" then
            db.single("SELECT balance, version FROM op77_tx_wallets WHERE account_id = ?", { id }, function(row, err)
                if err then return cb(nil, err) end
                if not row then return cb({ exists = false }) end
                cb({ exists = true, balance = int(row.balance), version = int(row.version) })
            end)
            return
        end
        db.single("SELECT kind, capacity_g, weight_g, version, meta, expires_at FROM op77_tx_containers "
            .. "WHERE container_id = ?", { id },
            function(row, err)
                if err then return cb(nil, err) end
                if not row then return cb({ exists = false }) end
                local result = {
                    exists = true, capacityG = int(row.capacity_g), weightG = int(row.weight_g),
                    version = int(row.version), stacks = {}, instances = {},
                    meta = decodeMeta(row.meta), expiresAt = int(row.expires_at), containerKind = row.kind,
                }
                -- Bounded reads: a container holds at most `slots` stacks and
                -- instances, far below the bridge's maxRows (D8), so a
                -- truncated read can never be mistaken for an empty one.
                db.query("SELECT item_id, count FROM op77_tx_stacks WHERE container_id = ? AND count > 0 LIMIT ?",
                    { id, maxRows + 1 }, function(rows, err2)
                        if err2 then return cb(nil, err2) end
                        if #(rows or {}) > maxRows then return cb(nil, "container_too_large") end
                        for _, r in ipairs(rows or {}) do result.stacks[r.item_id] = int(r.count) end
                        db.query("SELECT instance_id, item_id, meta, version FROM op77_tx_instances "
                            .. "WHERE container_id = ? LIMIT ?",
                            { id, maxRows + 1 }, function(irows, err3)
                                if err3 then return cb(nil, err3) end
                                if #(irows or {}) > maxRows then return cb(nil, "container_too_large") end
                                for _, r in ipairs(irows or {}) do
                                    result.instances[r.instance_id] = {
                                        item = r.item_id, meta = decodeMeta(r.meta) or {}, version = int(r.version),
                                    }
                                end
                                cb(result)
                            end)
                    end)
            end)
    end

    -- props = { capacityG, meta?, expiresAt?, slots?, create? }. `create`
    -- (world containers, minted ids) inserts and fails on an existing row;
    -- otherwise the row is upserted and only the capacity moves.
    function store:openContainer(id, props, cb)
        local _, ns = M.accountKind(id)
        local columns = { "container_id", "kind", "capacity_g", "weight_g", "version", "updated_at" }
        local marks = { "?", "?", "?", "0", "0", "?" }
        local values = { id, ns, props.capacityG, now() }
        local function column(name, value)
            if value == nil then return end
            columns[#columns + 1] = name
            marks[#marks + 1] = "?"
            values[#values + 1] = value
        end
        column("slots", props.slots)
        column("meta", props.meta ~= nil and encode(props.meta) or nil)
        column("expires_at", props.expiresAt)
        local sql = "INSERT INTO op77_tx_containers (" .. table.concat(columns, ", ") .. ") VALUES ("
            .. table.concat(marks, ", ") .. ")"
        if not props.create then
            sql = sql .. " ON DUPLICATE KEY UPDATE capacity_g = ?"
            values[#values + 1] = props.capacityG
            if props.meta ~= nil then
                sql = sql .. ", meta = ?"
                values[#values + 1] = encode(props.meta)
            end
        end
        db.update(sql, values, function(_, err)
            if err then return cb(nil, err) end
            cb(true)
        end)
    end

    function store:setMeta(id, meta, cb)
        db.update("UPDATE op77_tx_containers SET meta = ?, updated_at = ? WHERE container_id = ?",
            { encode(meta), now(), id }, function(_, err)
                if err then return cb(nil, err) end
                cb(true)
            end)
    end

    -- Deletes an EMPTY container row in one statement: the conditions are
    -- re-checked by the database, so a stale mirror cannot close a container
    -- that still holds something.
    function store:closeContainer(id, cb)
        db.update("DELETE FROM op77_tx_containers WHERE container_id = ? AND weight_g = 0 "
            .. "AND NOT EXISTS (SELECT 1 FROM op77_tx_stacks WHERE container_id = ? AND count > 0) "
            .. "AND NOT EXISTS (SELECT 1 FROM op77_tx_instances WHERE container_id = ?)",
            { id, id, id }, function(affected, err)
                if err then return cb(nil, err) end
                if (int(affected) or 0) < 1 then return cb("not_empty") end
                db.update("DELETE FROM op77_tx_stacks WHERE container_id = ? AND count = 0", { id }, function()
                    cb("closed")
                end)
            end)
    end

    -- Keyset page of containers of one kind, ordered by id. Bounded by
    -- `limit`, so a projection that re-creates every world pile at start
    -- pages through them without ever approaching maxRows (D8).
    function store:listContainers(kind, after, limit, cb)
        db.query("SELECT container_id, capacity_g, weight_g, version, meta, expires_at FROM op77_tx_containers "
            .. "WHERE kind = ? AND container_id > ? ORDER BY container_id LIMIT ?",
            { kind, after or "", limit }, function(rows, err)
                if err then return cb(nil, err) end
                local out = {}
                for _, r in ipairs(rows or {}) do
                    out[#out + 1] = {
                        id = r.container_id, capacityG = int(r.capacity_g), weightG = int(r.weight_g),
                        version = int(r.version), meta = decodeMeta(r.meta), expiresAt = int(r.expires_at),
                    }
                end
                cb(out)
            end)
    end

    function store:commit(plan, cb)
        local statements = Q.buildCommit(plan, encode)
        local valid, why = Q.validate(statements)
        if not valid then return cb(nil, "failed", why) end
        -- A refused submission still answers through this callback (the
        -- prelude schedules cb(nil, reason)); it never reached the database,
        -- so it is "refused", not ambiguous.
        db.transaction(statements, function(result, err)
            if result == true then return cb(true) end
            if Q.isSubmitRefusal(err) then return cb(nil, "refused", err) end
            cb(nil, Q.classify(err), err)
        end)
    end

    function store:fence(opId, meta, cb)
        local f = Q.fence(opId, meta, now())
        db.insert(f.query, f.values, function(_, err)
            if not err then return cb("inserted") end
            if Q.classify(err) ~= "conflict" then return cb(nil, nil, err) end
            db.single(Q.READ_OP, { opId }, function(row, err2)
                if err2 or not row then return cb(nil, nil, err2 or "fence_row_missing") end
                cb("exists", { state = row.state, hash = row.request_hash, receipt = decodeMeta(row.receipt) })
            end)
        end)
    end

    function store:readOp(opId, cb)
        db.single(Q.READ_OP, { opId }, function(row, err)
            if err then return cb(nil, err) end
            if not row then return cb(false) end
            cb({ state = row.state, hash = row.request_hash, receipt = decodeMeta(row.receipt) })
        end)
    end

    -- Liveness: D5 makes the bridge's own readiness one-shot, so the
    -- coordinator asks for itself after an outage.
    function store:probe(cb)
        db.scalar("SELECT 1", {}, function(value, err)
            if err then return cb(nil, err) end
            cb(true)
        end)
    end

    -- -----------------------------------------------------------------------
    -- Boot: schema version and forward migrations
    -- -----------------------------------------------------------------------
    local function runSequence(statements, index, cb)
        if index > #statements then return cb(true) end
        db.update(statements[index], {}, function(_, err)
            if err then return cb(nil, err) end
            runSequence(statements, index + 1, cb)
        end)
    end

    -- cb(version | nil, reason, detail). Refuses a database whose schema is
    -- newer than this build knows (B8 R4: never reinitialize silently).
    function store:migrate(cb)
        db.update(Q.SCHEMA_TABLE, {}, function(_, err)
            if err then return cb(nil, "schema_failed", err) end
            db.single("SELECT version FROM op77_tx_schema WHERE k = 1", {}, function(row, err2)
                if err2 then return cb(nil, "schema_failed", err2) end
                local current = row and int(row.version) or 0
                if current > Q.SCHEMA_VERSION then
                    return cb(nil, "schema_too_new", ("database v%d, build knows v%d"):format(current, Q.SCHEMA_VERSION))
                end
                local function step(v)
                    if v > Q.SCHEMA_VERSION then return cb(Q.SCHEMA_VERSION, nil, current) end
                    runSequence(Q.MIGRATIONS[v], 1, function(ok, err3)
                        if not ok then return cb(nil, "migration_failed", ("v%d: %s"):format(v, tostring(err3))) end
                        db.update("INSERT INTO op77_tx_schema (k, version, updated_at) VALUES (1, ?, ?) "
                            .. "ON DUPLICATE KEY UPDATE version = IF(version < ?, ?, version), updated_at = ?",
                            { v, now(), v, v, now() }, function(_, err4)
                                if err4 then return cb(nil, "migration_failed", tostring(err4)) end
                                step(v + 1)
                            end)
                    end)
                end
                step(current + 1)
            end)
        end)
    end

    -- Boot self-test (contract I2). Every check runs; cb(true) or
    -- cb(nil, "store_refused", { problems }) listing all of them:
    --   1. every op77_tx_* table exists and is InnoDB (MyISAM ignores
    --      transactions, so its rollback would silently keep half a commit);
    --   2. the guard row k = 1 exists (without it every assertion would insert
    --      instead of failing, and no invariant would ever be enforced);
    --   3. a deliberately failing transaction raises 1062 at its guard
    --      assertion AND its first statement is rolled back.
    function store:selfTest(token, cb)
        local problems = {}
        local marks = {}
        for i = 1, #Q.TABLES do marks[i] = "?" end
        db.query("SELECT TABLE_NAME AS name, ENGINE AS engine FROM information_schema.TABLES "
            .. "WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME IN (" .. table.concat(marks, ", ") .. ")",
            Q.TABLES, function(rows, err)
                if err then return cb(nil, "store_refused", { "engine_check_failed: " .. tostring(err) }) end
                local seen = {}
                for _, r in ipairs(rows or {}) do
                    seen[r.name] = true
                    if tostring(r.engine):lower() ~= "innodb" then
                        problems[#problems + 1] = "non_innodb:" .. tostring(r.name) .. "=" .. tostring(r.engine)
                    end
                end
                for _, name in ipairs(Q.TABLES) do
                    if not seen[name] then problems[#problems + 1] = "missing_table:" .. name end
                end
                db.scalar("SELECT COUNT(*) FROM op77_tx_guard WHERE k = 1", {}, function(count, err2)
                    if err2 or int(count) ~= 1 then
                        problems[#problems + 1] = "guard_row_missing"
                    end
                    local opId = "selftest-" .. token
                    db.transaction({
                        { query = "INSERT INTO op77_tx_ops (op_id, kind, actor, resource, state, request_hash, "
                            .. "receipt, created_at) VALUES (?, 'selftest', '', 'open77_transactions', 'aborted', '', '{}', ?)",
                          values = { opId, now() } },
                        { query = "INSERT INTO op77_tx_guard (k) SELECT 1 FROM DUAL WHERE NOT EXISTS "
                            .. "(SELECT 1 FROM op77_tx_guard WHERE k = 2)", values = {} },
                    }, function(result, err3)
                        if result == true then
                            problems[#problems + 1] = "assertion_did_not_fail"
                        elseif Q.classify(err3) ~= "conflict" then
                            problems[#problems + 1] = "assertion_error:" .. tostring(err3)
                        end
                        db.single("SELECT op_id FROM op77_tx_ops WHERE op_id = ?", { opId }, function(row, err4)
                            if err4 then
                                problems[#problems + 1] = "rollback_check_failed"
                            elseif row then
                                problems[#problems + 1] = "rollback_not_honoured"
                                db.update("DELETE FROM op77_tx_ops WHERE op_id = ?", { opId }, function() end)
                            end
                            if #problems > 0 then return cb(nil, "store_refused", problems) end
                            cb(true)
                        end)
                    end)
                end)
            end)
    end

    -- -----------------------------------------------------------------------
    -- Maintenance
    -- -----------------------------------------------------------------------
    -- Mint attribution for the hourly caps, rebuilt at boot from the journal so
    -- a restart does not reset a resource's window: rows leaving a sys:
    -- account since `sinceMs`, per (resource, sys account, asset).
    function store:mintHistory(sinceMs, cb)
        db.query("SELECT o.resource AS resource, j.account_id AS account, j.asset AS asset, "
            .. "SUM(-j.delta) AS amount, MAX(j.created_at) AS at FROM op77_tx_journal j "
            .. "JOIN op77_tx_ops o ON o.op_id = j.op_id "
            .. "WHERE j.created_at >= ? AND j.account_id LIKE 'sys:%' AND j.delta < 0 "
            .. "GROUP BY o.resource, j.account_id, j.asset, FLOOR(j.created_at / 60000) LIMIT 5000",
            { sinceMs }, function(rows, err)
                if err then return cb(nil, err) end
                local out = {}
                for _, r in ipairs(rows or {}) do
                    out[#out + 1] = { resource = r.resource, from = r.account, asset = r.asset,
                        amount = int(r.amount) or 0, at = int(r.at) or sinceMs }
                end
                cb(out)
            end)
    end

    -- An account's history, newest first: journal rows joined with their
    -- operation. `before` (exclusive, ms) pages back; bounded by `limit`.
    function store:history(account, before, limit, cb)
        db.query("SELECT j.op_id AS op_id, j.line AS line, j.asset AS asset, j.delta AS delta, j.reason AS reason, "
            .. "j.created_at AS at, o.kind AS kind, o.actor AS actor, o.resource AS resource "
            .. "FROM op77_tx_journal j JOIN op77_tx_ops o ON o.op_id = j.op_id "
            .. "WHERE j.account_id = ? AND j.created_at < ? ORDER BY j.created_at DESC, j.op_id DESC, j.line DESC LIMIT ?",
            { account, before, limit }, function(rows, err)
                if err then return cb(nil, err) end
                local out = {}
                for _, r in ipairs(rows or {}) do
                    out[#out + 1] = { opId = r.op_id, line = int(r.line), asset = r.asset, delta = int(r.delta),
                        reason = (r.reason ~= "" and r.reason) or nil, at = int(r.at), kind = r.kind,
                        actor = (r.actor ~= "" and r.actor) or nil, resource = r.resource }
                end
                cb(out)
            end)
    end

    -- Retention: one bounded DELETE per table; cb(rowsRemoved). The caller
    -- repeats on a later tick while a full chunk came back.
    function store:purge(beforeMs, limit, cb)
        db.update("DELETE FROM op77_tx_journal WHERE created_at < ? LIMIT ?", { beforeMs, limit }, function(a, err)
            if err then return cb(nil, err) end
            db.update("DELETE FROM op77_tx_ops WHERE created_at < ? LIMIT ?", { beforeMs, limit }, function(b, err2)
                if err2 then return cb(nil, err2) end
                cb((int(a) or 0) + (int(b) or 0), int(a) or 0, int(b) or 0)
            end)
        end)
    end

    return store
end

return Open77TxSql
