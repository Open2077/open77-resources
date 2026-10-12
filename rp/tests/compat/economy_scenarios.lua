-- tests/compat/economy_scenarios.lua: rp_economy across server restarts, offline.
--
-- Since B3, rp_economy 2.0.0 is a facade over the open77_transactions coordinator, so these
-- scenarios run on the multi-resource host (multihost.lua) with the coordinator prototype, the
-- real rp_economy server scripts and a caller shim. They are the B8 scenarios under the same
-- names; the implementations live in wallet_scenarios.lua. The 1.x behaviour they replaced
-- (5dcdad2: 1 500 in SQL, 500 on a KVP boot, +700 lost on the next SQL boot) is recorded in
-- docs/world-interaction/b8-compat-audit.md §3.4 and reproducible from commit d401b40.
--
-- String globals from the runner: ROOT_DIR, COMPAT_DIR, TX_DIR.

dofile(COMPAT_DIR .. "/wallet_scenarios.lua")

local ALIASES = {
    sql_restart = "sql_restart",
    refusals = "refusals",
    -- "A boot without a database between two SQL boots" (gap R1).
    kvp_boot_between_sql_boots = "database_outage_boot",
}

function RUN_SCENARIO(name)
    local target = assert(ALIASES[name], "unknown scenario " .. tostring(name))
    return WALLET_SCENARIOS[target]()
end
