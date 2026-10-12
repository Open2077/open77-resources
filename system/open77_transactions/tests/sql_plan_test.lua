-- =============================================================================
-- open77_transactions -- tests/sql_plan_test.lua
-- =============================================================================
-- T21 of the contract: the SHAPE of the SQL the store would submit, checked
-- against the bridge's real rules (64 statements x 64 parameters x 64 KiB, a
-- contiguous non-nil positional range), plus error classification and the
-- adapter's callback wiring over a fake MySQL table.
--
-- What this does NOT prove: that MariaDB/MySQL execute these statements with
-- the intended semantics (contract section 10, I1-I3). That needs a database.
--
-- Load order: shared/model.lua, server/memory_store.lua, server/coordinator.lua,
-- server/sql_store.lua, then this file. Sets TestResult and TestSummary.
-- =============================================================================

local M, Q, Coordinator = Open77TxModel, Open77TxSql, Open77TxCoordinator
assert(M and Q and Coordinator, "load model, coordinator and sql_store first")

local passed, failures = 0, {}
local current = "?"
local function check(cond, msg)
    if cond then passed = passed + 1 else failures[#failures + 1] = current .. ": " .. (msg or "assertion failed") end
end
local function run(name, fn)
    current = name
    local ok, err = pcall(fn)
    if not ok then failures[#failures + 1] = name .. ": runtime error: " .. tostring(err) end
end

local WEIGHTS = { scrap = 500, chip = 50, crowbar = 1500 }
local function weights(item) return WEIGHTS[item] end
local INSTANCES = { ["cb-1"] = { item = "crowbar", version = 3, container = "char:acct-a" } }
local function instances(iid) return INSTANCES[iid] end

local function plan(lines, extra)
    extra = extra or {}
    local normalized = assert(M.normalizeLines(lines))
    return assert(M.buildPlan({
        opId = extra.opId or "op-sql-1", kind = "sale", actor = extra.actor, resource = "c1",
        hash = M.hashLines("sale", normalized), now = 1700000000000, lines = normalized,
        weights = weights, instances = instances, expect = extra.expect,
        receipt = { opId = extra.opId or "op-sql-1", state = "committed" },
    }))
end

local SALE = {
    { item = "scrap", count = 4, from = "veh:NC-1234:cargo", to = "sys:dealer" },
    { item = "chip", count = 1, from = "char:acct-a", to = "sys:dealer" },
    { money = 270, from = "sys:dealer", to = "cash:acct-a" },
    { money = 30, from = "sys:dealer", to = "soc:ferrailleur" },
    { instance = "cb-1", at = "char:acct-a", meta = { durability = 11 } },
}

run("op row first, journal last", function()
    local s = Q.buildCommit(plan(SALE))
    check(s[1].query:find("^INSERT INTO op77_tx_ops") ~= nil, "first statement inserts the op row")
    check(s[#s].query:find("^INSERT INTO op77_tx_journal") ~= nil, "journal closes the transaction")
    check(s[1].values[3] == "", "absent actor bound as '' (never nil)")
end)

run("statement count equals the model's estimate", function()
    local p = plan(SALE)
    check(#Q.buildCommit(p) == M.estimateStatements(p),
        ("estimate %d vs built %d"):format(M.estimateStatements(p), #Q.buildCommit(p)))
end)

run("every conditional write is followed by its guard assertion", function()
    local s = Q.buildCommit(plan(SALE, { expect = { ["soc:ferrailleur"] = 4 } }))
    local conditional = 0
    for index, st in ipairs(s) do
        local q = st.query
        local needsGuard = q:find("^UPDATE ") ~= nil
            or (q:find("^INSERT INTO op77_tx_wallets") ~= nil)
            or (q:find("^INSERT INTO op77_tx_instances") ~= nil)
        if needsGuard then
            conditional = conditional + 1
            local nextQ = s[index + 1] and s[index + 1].query or ""
            check(nextQ:find("^INSERT INTO op77_tx_guard") ~= nil, "guard after statement " .. index .. ": " .. q:sub(1, 40))
        end
    end
    check(conditional >= 6, "found the conditional writes, got " .. conditional)
    local found = false
    for _, st in ipairs(s) do
        if st.query:find("op77_tx_wallets WHERE account_id = %? AND last_op = %? AND balance <= %? AND version = %?") then
            found = (st.values[4] == 5)
        end
    end
    check(found, "expected wallet version asserted as expected+1")
end)

run("canonical lock order: containers and wallets sorted by key", function()
    local p = plan(SALE)
    local ids = {}
    for _, c in ipairs(p.containers) do ids[#ids + 1] = c.id end
    check(ids[1] == "char:acct-a" and ids[2] == "veh:NC-1234:cargo", "containers sorted: " .. table.concat(ids, ","))
    check(p.wallets[1].id == "cash:acct-a" and p.wallets[2].id == "soc:ferrailleur", "wallets sorted")
end)

run("debits are UPDATE plus count >= 0 guard; credits are upserts", function()
    local s = Q.buildCommit(plan({ { item = "scrap", count = 2, from = "char:acct-a", to = "world:crate-1" } }))
    local debit, credit
    for i, st in ipairs(s) do
        if st.query:find("^UPDATE op77_tx_stacks SET count = count %- %?") then debit = i end
        if st.query:find("^INSERT INTO op77_tx_stacks .* ON DUPLICATE KEY UPDATE count = count %+ %?") then credit = i end
    end
    check(debit and s[debit + 1].query:find("count >= 0") ~= nil, "debit guarded")
    check(credit ~= nil, "credit upserts")
end)

run("bridge rules: no nil parameter, counts match, limits respected", function()
    local ok, why, index = Q.validate(Q.buildCommit(plan(SALE)))
    check(ok == true, "valid: " .. tostring(why) .. " at " .. tostring(index))
    local bad = { { query = "SELECT ?, ?", values = { 1, nil } } }
    check(select(2, Q.validate(bad)) == "parameter_count_mismatch", "trailing nil detected")
    local hole = { { query = "SELECT ?, ?, ?", values = { 1, nil, 3 } } }
    check(select(2, Q.validate(hole)) == "invalid_parameters", "hole detected")
end)

run("journal is chunked at 9 rows (63 parameters)", function()
    local lines = {}
    for i = 1, 15 do lines[#lines + 1] = { money = i, from = "sys:dealer", to = "cash:acct-" .. i } end
    local s = Q.buildCommit(plan(lines))
    local journal = {}
    for _, st in ipairs(s) do if st.query:find("^INSERT INTO op77_tx_journal") then journal[#journal + 1] = st end end
    check(#journal == 4, "30 journal rows -> 4 statements, got " .. #journal)
    for _, st in ipairs(journal) do check(#st.values <= 63, "chunk within 64 parameters") end
    check(Q.validate(s) == true, "still valid")
end)

run("over-budget transactions are refused by validate", function()
    local lines = {}
    for i = 1, 40 do
        WEIGHTS["part_" .. i] = 1
        lines[#lines + 1] = { item = "part_" .. i, count = 1, from = "char:acct-a", to = "sys:dealer" }
    end
    local p = plan(lines)
    check(M.estimateStatements(p) > 64, "estimate exceeds the budget")
    check(select(2, Q.validate(Q.buildCommit(p))) == "operation_too_large", "validate refuses")
end)

run("error classification", function()
    check(Q.classify("database_conflict (SQL 1062): A database operation conflicts") == "conflict", "1062")
    check(Q.classify("database_unreachable (SQL 2013): The configured database is not answering.") == "ambiguous", "lost connection")
    check(Q.classify("database_request_failed (SQL 1213): A database operation failed.") == "transient", "deadlock")
    check(Q.classify("database_request_failed (SQL 1205): A database operation failed.") == "transient", "lock wait")
    check(Q.classify("database_request_failed (SQL 1180): A database operation failed.") == "ambiguous",
        "an error during COMMIT stays ambiguous")
    check(Q.classify("database_schema_error (SQL 1146): A required table") == "failed", "schema")
    check(Q.classify(nil) == "ambiguous", "unknown is ambiguous")
end)

run("schema is InnoDB and carries a version table", function()
    local innodb, versioned = 0, false
    for _, ddl in ipairs(Q.SCHEMA) do
        if ddl:find("^CREATE TABLE") then
            check(ddl:find("ENGINE=InnoDB") ~= nil, "InnoDB: " .. ddl:sub(1, 50))
            innodb = innodb + 1
        end
        if ddl:find("op77_tx_schema") then versioned = true end
    end
    check(innodb == 8 and versioned, "eight tables including op77_tx_schema")
end)

-- ---------------------------------------------------------------------------
-- Adapter wiring over a fake MySQL table (scripted answers, no SQL executed)
-- ---------------------------------------------------------------------------
local function fakeDb(script)
    local db = { log = {} }
    function db.transaction(statements, cb)
        db.log[#db.log + 1] = { kind = "transaction", statements = statements }
        local answer = table.remove(script.transaction, 1)
        if answer == true then cb(true) else cb(nil, answer) end
        return true
    end
    function db.insert(sql, values, cb)
        db.log[#db.log + 1] = { kind = "insert", sql = sql, values = values }
        local answer = table.remove(script.insert, 1)
        if answer == true then cb(1) else cb(nil, answer) end
    end
    function db.single(sql, values, cb)
        db.log[#db.log + 1] = { kind = "single", sql = sql, values = values }
        local answer = table.remove(script.single, 1)
        if type(answer) == "string" then cb(nil, answer) else cb(answer or nil) end
    end
    function db.query(sql, values, cb)
        db.log[#db.log + 1] = { kind = "query", sql = sql, values = values }
        cb(table.remove(script.query, 1) or {})
    end
    function db.update(sql, values, cb)
        db.log[#db.log + 1] = { kind = "update", sql = sql, values = values }
        cb(1)
    end
    return db
end

run("adapter maps transaction answers to classes", function()
    local db = fakeDb({ transaction = { true, "database_conflict (SQL 1062): x", "database_unreachable (SQL 2013): y",
        "database_unavailable" }, insert = {}, single = {}, query = {} })
    local store = Q.newStore(db, {})
    local p = plan(SALE)
    local got = {}
    for _ = 1, 4 do store:commit(p, function(ok, class) got[#got + 1] = ok and "ok" or class end) end
    check(table.concat(got, ",") == "ok,conflict,ambiguous,refused", table.concat(got, ","))
    check(#db.log[1].statements == M.estimateStatements(p), "the built statements were submitted")
end)

run("adapter fence: inserted, or reads the existing row", function()
    local db = fakeDb({ transaction = {}, insert = { true, "database_conflict (SQL 1062): dup", "database_unreachable" },
        single = { { state = "committed", request_hash = "abc", receipt = "{}" } }, query = {} })
    local store = Q.newStore(db, { decode = function() return { opId = "op-f" } end })
    local outcomes = {}
    for _ = 1, 3 do
        store:fence("op-fence-1", { hash = "abc", resource = "c1" }, function(outcome, row, err)
            outcomes[#outcomes + 1] = outcome or ("err:" .. tostring(err))
            if row then check(row.state == "committed" and row.hash == "abc", "row decoded") end
        end)
    end
    check(table.concat(outcomes, ",") == "inserted,exists,err:database_unreachable", table.concat(outcomes, ","))
    check(db.log[1].sql:find("'fence'") ~= nil and db.log[1].sql:find("'aborted'") ~= nil, "tombstone shape")
end)

run("adapter load parses container rows", function()
    local db = fakeDb({ transaction = {}, insert = {},
        single = { { capacity_g = 40000, weight_g = 2050, version = 9 } },
        query = { { { item_id = "scrap", count = 4 }, { item_id = "chip", count = 1 } },
                  { { instance_id = "cb-1", item_id = "crowbar", meta = "{}", version = 3 } } } })
    local store = Q.newStore(db, { decode = function() return { durability = 12 } end })
    local row
    store:load("char:acct-a", function(r) row = r end)
    check(row and row.exists and row.capacityG == 40000 and row.stacks.scrap == 4, "container parsed")
    check(row.instances["cb-1"].item == "crowbar" and row.instances["cb-1"].meta.durability == 12, "instances parsed")
end)

run("coordinator over the SQL adapter: one transaction per commit", function()
    local db = fakeDb({ transaction = { true }, insert = {},
        single = { { capacity_g = 40000, weight_g = 0, version = 0 }, { capacity_g = 100000, weight_g = 2000, version = 0 } },
        query = { {}, {}, { { item_id = "scrap", count = 4 } }, {} } })
    local store = Q.newStore(db, {})
    local co = Coordinator.new({ store = store, now = function() return 5 end })
    co:define({ scrap = { weightG = 500 } }, "t")
    local result
    co:transfer({ opId = "op-wire-1", lines = { { item = "scrap", count = 4, from = "world:crate-1", to = "char:acct-a" } } },
        "c1", function(res, reason) result = res or reason end)
    check(type(result) == "table" and result.state == "committed", "committed: " .. tostring(result))
    local transactions = 0
    for _, e in ipairs(db.log) do if e.kind == "transaction" then transactions = transactions + 1 end end
    check(transactions == 1, "exactly one transaction")
    check(co:read("char:acct-a").items.scrap == 4, "mirror updated after the ack")
end)

TestResult = { passed = passed, failed = #failures, failures = failures }
TestSummary = string.format("passed=%d failed=%d", passed, #failures)
    .. (#failures > 0 and ("\n" .. table.concat(failures, "\n")) or "")
print(string.format("[open77_transactions sql plan tests] %d passed, %d failed", passed, #failures))
for _, f in ipairs(failures) do print("  FAIL: " .. f) end
