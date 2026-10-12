-- tests/compat/economy_scenarios.lua: rp_economy across server restarts, offline.
--
-- Loaded after fakehost.lua. `ECONOMY_SCRIPT` (set by the runner) is the path of the real
-- rp_economy/server/main.lua. Each scenario returns a flat table of results; the runner turns
-- it into "key=value" lines. Nothing here changes the resource: it is driven as shipped.

-- The statements rp_economy issues, interpreted over H.stores.sql.wallets.
local function economySql(sql, p)
    local wallets = H.stores.sql.wallets
    if not wallets then
        wallets = {}
        H.stores.sql.wallets = wallets
    end
    if sql:find("CREATE TABLE", 1, true) then return 0 end
    if sql:find("SELECT balance FROM rp_economy_wallets", 1, true) then
        local row = wallets[p[1]]
        return row and { balance = row.balance } or nil
    end
    if sql:find("SELECT COUNT(*)", 1, true) then
        local n = 0
        for _ in pairs(wallets) do n = n + 1 end
        return n
    end
    if sql:find("ON DUPLICATE KEY UPDATE identifier = identifier", 1, true) then
        if not wallets[p[1]] then wallets[p[1]] = { name = p[2], balance = p[3] } end
        return 1
    end
    if sql:find("INSERT INTO rp_economy_wallets", 1, true) then
        wallets[p[1]] = { name = p[2], balance = p[3] }
        return 1
    end
    error("economy_scenarios: unexpected SQL: " .. sql)
end

local PLAYER = { [7] = { identifier = "account-guid-7", name = "V" } }

local function boot(dbMode)
    H.sql = economySql
    return H.boot("rp_economy", ECONOMY_SCRIPT, dbMode, PLAYER, 60)
end

local scenarios = {}

-- Two SQL boots: the balance is keyed by the durable identifier and survives a restart.
function scenarios.sql_restart()
    local ex = boot("sql")
    local first = ex.getBalance(7)
    ex.add(7, 1000, "compat_income")
    ex = boot("sql")
    return {
        first = first,
        after_restart = ex.getBalance(7),
        sql_row = H.stores.sql.wallets["account-guid-7"].balance,
    }
end

-- SQL boot, then a boot without a database (KVP fallback), then SQL again.
function scenarios.kvp_boot_between_sql_boots()
    local ex = boot("sql")
    ex.add(7, 1000, "compat_income")
    local sqlBalance = ex.getBalance(7)
    ex = boot("none")
    local kvpJoin = ex.getBalance(7)
    ex.add(7, 700, "compat_income_kvp")
    local kvpAfter = ex.getBalance(7)
    ex = boot("sql")
    return {
        sql_balance = sqlBalance,
        kvp_join = kvpJoin,
        kvp_after_income = kvpAfter,
        sql_rejoin = ex.getBalance(7),
        kvp_key = H.stores.kvp["balance:account-guid-7"],
    }
end

-- Refusal tokens other resources rely on (rp_bank maps insufficient_funds; callers log reasons).
function scenarios.refusals()
    local ex = boot("sql")
    local function reason(f, ...)
        local v, r = f(...)
        if v == nil then return tostring(r) end
        return "value:" .. tostring(v)
    end
    return {
        bad_id = reason(ex.add, "x", 10, "t"),
        unknown_player = reason(ex.add, 99, 10, "t"),
        negative = reason(ex.add, 7, -5, "t"),
        fraction = reason(ex.add, 7, 1.5, "t"),
        overdraw = reason(ex.remove, 7, 1000000, "t"),
        long_reason = reason(ex.add, 7, 1, string.rep("r", 65)),
        unknown_balance = ex.getBalance(99),
    }
end

function RUN_SCENARIO(name)
    local scenario = assert(scenarios[name], "unknown scenario " .. tostring(name))
    local result = scenario()
    local lines = {}
    for k, v in pairs(result) do lines[#lines + 1] = k .. "=" .. tostring(v) end
    table.sort(lines)
    return table.concat(lines, "\n")
end
