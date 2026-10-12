-- rp_economy / server/config.lua: wallet facade settings (server only).
--
-- Balances are owned by the open77_transactions coordinator (A13 contract, decision 2):
-- this resource keeps a cache, applies the legacy synchronous exports as write-behind
-- operations and offers the atomic asynchronous API. See README.md and
-- docs/world-interaction/b3-wallet.md.

EconomyConfig = {}

-- The coordinator resource. Without it, or while it reports a store outage, every mutation is
-- refused with `store_unavailable`: there is no KVP fallback any more (gap R1 closed).
EconomyConfig.coordinator = "open77_transactions"

-- Probe cadence of the coordinator's health (milliseconds).
EconomyConfig.probeHealthyMs = 15000
EconomyConfig.probeUnhealthyMs = 2000

-- Prefix of the operation ids this facade mints. Must be unique among servers that share one
-- database (the convar rp_economy_server_tag overrides it).
EconomyConfig.serverTag = "rp"

-- Gameplay constants (unchanged from 1.0.0).
EconomyConfig.startBalance = 500
EconomyConfig.paydayAmount = 200
EconomyConfig.paydayIntervalMs = 10 * 60 * 1000
EconomyConfig.maxBalance = 1000000000000   -- 1e12, the coordinator's money ceiling too
EconomyConfig.currency = "€$"

-- Write-behind (the legacy synchronous exports). An accepted call is applied to the cache at
-- once and committed in the background; failures that are proven "not committed" are retried
-- with a new attempt id until giveUpSeconds, then the change is reverted and logged.
EconomyConfig.writeBehind = {
    giveUpSeconds = 600,
    backoffMs = { 250, 500, 1000, 2000, 4000, 8000, 15000, 30000 },
    statusPollMs = 1000,
}

-- Asynchronous API: how long an export waits for an in-doubt outcome before answering
-- `in_doubt` (the caller then polls rp_economy:status). Must stay below the 30 s export timeout.
EconomyConfig.asyncWaitSeconds = 20

-- The coordinator has its own mint rules (its tunables mint1..6, contract 12.6; nothing mints by
-- default). This resource creates money as itself out of sys:<caller>:<label> accounts; the rule
-- grammar names one sys: segment, so the coordinator needs one ceiling for it, for example
--   mint1 = "rp_economy sys:* money 2000000"
-- and the per-caller budgets below do the rest. Items are the job's own rule (C1:
-- "rp_salvage sys:salvage * 400").
--
-- Money printing allowlist (A13 decision 6). A credit that comes from no wallet (legacy `add`,
-- `societyAdd`, an NPC buyer, a bounty) is a MINT from `sys:<resource>:<label>`; a debit into
-- `sys:` is a BURN. The cap is on the NET amount minted per resource in a fixed one-hour window
-- (mint minus burn by the same resource), so a resource that moves money between players nets
-- to zero and only real money creation counts. A resource that is not listed may burn but never
-- mint (`mint_denied`); over the cap the call is refused (`mint_cap`). Values: €$ per hour.
-- Derivation per resource: docs/world-interaction/b3-wallet.md §4.
EconomyConfig.mint = {
    windowSeconds = 3600,
    callers = {
        rp_admin = 100000000,      -- setmoney / setbank (admin tools)
        rp_bar = 10000,            -- transfers; refunds after burns
        rp_crime = 50000,          -- fence payouts
        rp_delamain = 10000,       -- transfers; refunds
        rp_ferrailleur = 30000,    -- scrap sales to the NPC dealer, 10 % society share
        rp_fixer = 200000,         -- gig payouts and commissions
        rp_gangs = 60000,          -- zone tribute, NPC deals
        rp_garage = 20000,         -- refunds, impound releases
        rp_housing = 200000,       -- sell-back (70 % of an earlier, older burn)
        rp_jobs = 600000,          -- first-boss society seeding (50 000 per job, once)
        rp_mecano = 20000,         -- impound fees
        rp_medic = 5000,           -- refunds
        rp_ncpd = 5000,            -- refunds
        rp_netrunner = 30000,      -- breach bounties
        rp_techie = 30000,         -- shop sales of weapon mods and cyberware parts
        rp_chooh2 = 30000,         -- CHOOH2 canister sales at the depot
        rp_nomade = 100000,        -- crate sales to the fence (rp_economy `sale`), the camp's share
        rp_ripperdoc = 20000,      -- refunds
        rp_salvage = 30000,        -- C1 salvage: scrap and crate sales to the NPC buyer (sale), society share
        rp_selftest = 1000,        -- the boot probe (+100 / -100 on society selftest)
        rp_shop = 100000,          -- v1 vehicle sell-back (duplicate economy, see README)
        rp_shops = 30000,          -- robbery loot, refunds
        rp_vigile = 20000,         -- corpo guard contracts
    },
    -- This resource's own sources (sys:rp_economy:<label>).
    internal = {
        start = 50000,             -- 500 per new subject
        payday = 100000,           -- 200 every 10 min per ready player
        admin = 100000000,         -- /givemoney
    },
}

-- Resources allowed to call walletMove / walletRead / societyRead and to name the original
-- caller (onBehalfOf) for the mint allowlist. rp_bank is the bank facade over this cache.
EconomyConfig.trustedFacades = { rp_bank = true }

-- Societies loaded when the coordinator becomes ready (job names, B8 audit §2.5); any other
-- name is loaded on first use.
EconomyConfig.societies = {
    "ncpd", "trauma", "delamain", "mecano", "ripper", "nomade", "ferrailleur", "barman",
    "fixer", "netrunner", "vigile", "garage", "housing",
}

-- One-shot import of the 1.x tables into the coordinator (server/migrate.lua).
EconomyConfig.migration = {
    auto = false,          -- true: import at the first ready boot; false: console `economy_migrate`
    pageSize = 500,        -- keyset pages, far below the bridge's 10 000-row maxRows (D8)
    parallel = 16,         -- import operations in flight at once
    reportLimit = 50,      -- skipped rows listed in the log and in the state row
}
