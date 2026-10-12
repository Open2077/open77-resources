-- tests/compat/wallet_scenarios.lua: rp_economy and rp_bank as facades over the A13 coordinator.
--
-- Loaded by tests/test_compat_wallet.py after fakehost.lua (unused here) with the string globals
-- ROOT_DIR, COMPAT_DIR and TX_DIR. Each scenario boots real resources on multihost.lua: the
-- coordinator prototype behind txhost_wallet.lua, the real rp_economy (and rp_bank) server scripts, and
-- small caller shims that reproduce how the pack's resources call the exports. Each returns a
-- flat table; the runner turns it into "key=value" lines.

dofile(COMPAT_DIR .. "/multihost.lua")
dofile(COMPAT_DIR .. "/wallet_world.lua")

local scenarios = {}

local A, B, C = "acct-a", "acct-b", "acct-c"

-- Smoke: a new player gets the starting balance once, add/remove write behind, the coordinator
-- holds the result.
function scenarios.smoke()
    WW.boot({ shims = { WW.shim("rp_jobs") } })
    WW.join(7, A, "V")
    local first = WW.sync("rp_jobs", "rp_economy", "getBalance", 7)
    local added, addWhy = WW.sync("rp_jobs", "rp_economy", "add", 7, 1000, "salary")
    local removed, removeWhy = WW.sync("rp_jobs", "rp_economy", "remove", 7, 300, "fine")
    WW.settle()
    return WW.result({
        first = first, added = tostring(added) .. "/" .. tostring(addWhy),
        removed = tostring(removed) .. "/" .. tostring(removeWhy),
        durable = WW.balance("cash:" .. A), display = WW.sync("rp_jobs", "rp_economy", "getBalance", 7),
    })
end

-- ---------------------------------------------------------------------------------------------
-- rp_economy compatibility (tests/test_compat_economy.py)

local function kvpKeys(resource)
    local n = 0
    for _ in pairs(MH.kvp[resource] or {}) do n = n + 1 end
    return n
end

-- The balance is keyed by the durable subject and survives a restart of everything.
function scenarios.sql_restart()
    WW.boot({ shims = { WW.shim("rp_jobs") } })
    WW.join(7, A, "V")
    local first = WW.sync("rp_jobs", "rp_economy", "getBalance", 7)
    WW.sync("rp_jobs", "rp_economy", "add", 7, 1000, "compat_income")
    WW.settle()
    local keep = WW.keep()
    WW.boot({ keep = keep, shims = { WW.shim("rp_jobs") } })
    WW.join(7, A, "V")
    return WW.result({
        first = first,
        after_restart = WW.sync("rp_jobs", "rp_economy", "getBalance", 7),
        sql_row = WW.balance("cash:" .. A),
        kvp_keys = kvpKeys("rp_economy"),
    })
end

-- Gap R1. 1.x: a boot without a database fell back to KVP with a fresh 500 wallet, and what was
-- earned there never came back. The facade: the outage boot refuses, nothing lands in KVP, the
-- balance is back as soon as the database is; an outage in the middle of a session refuses new
-- changes once detected and lands every change it had accepted, exactly once.
function scenarios.database_outage_boot()
    local shims = { WW.shim("rp_jobs") }
    WW.boot({ shims = shims })
    WW.join(7, A, "V")
    WW.sync("rp_jobs", "rp_economy", "add", 7, 1000, "compat_income")
    WW.settle()
    local sqlBalance = WW.balance("cash:" .. A)

    -- Boot with the database down: the coordinator store is unavailable, the bridge too.
    local keep = WW.keep()
    WW.boot({ keep = keep, shims = shims, storeDown = true, dbMode = "none" })
    WW.connect(7, A, "V")
    MH.run(5)
    local outageJoin = WW.sync("rp_jobs", "rp_economy", "getBalance", 7)
    local outageAdd, outageAddWhy = WW.sync("rp_jobs", "rp_economy", "add", 7, 700, "compat_income_outage")
    local kvpWrites = kvpKeys("rp_economy")
    local outageDurable = WW.balance("cash:" .. A)

    -- The database comes back: same boot, no restart needed.
    MH.shared.txStore.down = false
    MH.dbMode = "sql"
    MH.until_(function() return WW.economy().Wallets.byPlayer[7] ~= nil end, 30)
    WW.settle()
    local rejoin = WW.sync("rp_jobs", "rp_economy", "getBalance", 7)

    -- Mid-session outage: a change accepted just before the outage is detected lands once.
    MH.shared.txStore.down = true
    local accepted, acceptedWhy = WW.sync("rp_jobs", "rp_economy", "add", 7, 300, "compat_midsession")
    MH.run(20)
    local refused, refusedWhy = WW.sync("rp_jobs", "rp_economy", "add", 7, 50, "compat_refused")
    MH.shared.txStore.down = false
    WW.settle(60)
    return WW.result({
        sql_balance = sqlBalance,
        outage_join = outageJoin,
        outage_add = tostring(outageAdd) .. "/" .. tostring(outageAddWhy),
        outage_kvp_writes = kvpWrites,
        outage_durable = outageDurable,
        sql_rejoin = rejoin,
        midsession_accepted = tostring(accepted) .. "/" .. tostring(acceptedWhy),
        midsession_refused = tostring(refused) .. "/" .. tostring(refusedWhy),
        final_durable = WW.balance("cash:" .. A),
        final_display = WW.sync("rp_jobs", "rp_economy", "getBalance", 7),
        kvp_keys_end = kvpKeys("rp_economy"),
    })
end

-- Refusal tokens other resources rely on, plus the facade's new ones.
function scenarios.refusals()
    WW.boot({ shims = { WW.shim("rp_jobs"), WW.shim("compat_test") } })
    WW.join(7, A, "V")
    local function reason(from, name, ...)
        local v, r = WW.sync(from, "rp_economy", name, ...)
        if v == nil then return tostring(r) end
        return "value:" .. tostring(v)
    end
    return WW.result({
        bad_id = reason("rp_jobs", "add", "x", 10, "t"),
        unknown_player = reason("rp_jobs", "add", 99, 10, "t"),
        negative = reason("rp_jobs", "add", 7, -5, "t"),
        fraction = reason("rp_jobs", "add", 7, 1.5, "t"),
        overdraw = reason("rp_jobs", "remove", 7, 1000000, "t"),
        long_reason = reason("rp_jobs", "add", 7, 1, string.rep("r", 65)),
        unknown_balance = WW.sync("rp_jobs", "rp_economy", "getBalance", 99),
        unlisted_mint = reason("compat_test", "add", 7, 10, "t"),
        unlisted_burn = reason("compat_test", "remove", 7, 10, "t"),
        untrusted_move = reason("compat_test", "walletMove", { lines = {} }),
    })
end

-- ---------------------------------------------------------------------------------------------
-- Atomic API

local function saleShims() return { WW.DEFINER, WW.shim("rp_ferrailleur"), WW.shim("rp_nomade") } end

local function seedPockets(subject, stacks)
    MH.shared.txStore:seedContainer("char:" .. subject, 40000, stacks, WW.WEIGHTS)
end

local function saleSpec(opId, total)
    total = total or 300
    return {
        opId = opId, seller = { player = 7 },
        items = { { item = "scrap", count = 4 }, { item = "component", count = 2 } },
        buyer = { sys = "dealer" }, total = total,
        payees = { { player = 7, amount = total - 30 }, { society = "ferrailleur", amount = 30 } },
        reason = "scrap_sale",
    }
end

local function sums(opId)
    local out = {}
    for asset, v in pairs(MH.shared.txStore:journalSums(opId)) do out[#out + 1] = asset .. ":" .. v end
    table.sort(out)
    return table.concat(out, ",")
end

local function outcome(r, why)
    if r then return "ok" .. (r.replay and ":replay" or "") end
    return tostring(why)
end

-- A replayed sale (double press, retry after a timeout, restart) pays once.
function scenarios.sale_replay_pays_once()
    WW.boot({ shims = saleShims() })
    seedPockets(A, { scrap = 4, component = 2 })
    WW.join(7, A, "V")
    local commitsBefore = MH.shared.txStore.commits
    local r1, why1 = WW.async("rp_ferrailleur", "rp_economy", "sale", saleSpec("ferrailleur:sale:acct-a:n1"))
    local r2, why2 = WW.async("rp_ferrailleur", "rp_economy", "sale", saleSpec("ferrailleur:sale:acct-a:n1"))
    local conflict, conflictWhy = WW.async("rp_ferrailleur", "rp_economy", "sale", saleSpec("ferrailleur:sale:acct-a:n1", 400))
    WW.settle()
    local commits = MH.shared.txStore.commits - commitsBefore
    -- Restart everything; the caller retries the same intent, then tries to sell the goods again.
    local keep = WW.keep()
    WW.boot({ keep = keep, shims = saleShims() })
    WW.join(7, A, "V")
    local r3, why3 = WW.async("rp_ferrailleur", "rp_economy", "sale", saleSpec("ferrailleur:sale:acct-a:n1"))
    local again, againWhy = WW.async("rp_ferrailleur", "rp_economy", "sale", saleSpec("ferrailleur:sale:acct-a:n2"))
    WW.settle()
    return WW.result({
        first = outcome(r1, why1),
        second = outcome(r2, why2),
        conflict = outcome(conflict, conflictWhy),
        after_restart = outcome(r3, why3),
        new_intent_same_goods = outcome(again, againWhy),
        commits_for_sale = commits,
        commits_total = MH.shared.txStore.commits - commitsBefore,
        cash = WW.balance("cash:" .. A),
        society = WW.balance("soc:ferrailleur"),
        scrap = WW.count("char:" .. A, "scrap"),
        component = WW.count("char:" .. A, "component"),
        journal = sums("ferrailleur:sale:acct-a:n1"),
        display = WW.sync("rp_ferrailleur", "rp_economy", "getBalance", 7),
    })
end

-- Freight pay: delivery gross, convoy bonus split among three members and the society share,
-- in ONE operation whose payees sum to the total; a split that does not sum is refused whole.
function scenarios.split_payout_sums()
    WW.boot({ shims = saleShims() })
    WW.join(7, A, "Driver")
    WW.join(8, B, "Rider1")
    WW.join(9, C, "Rider2")
    local commitsBefore = MH.shared.txStore.commits
    local gross, bonusEach, society = 600, 50, 90
    local spec = {
        opId = "nomade:pay:contract-41:batch-1", from = { sys = "client" }, reason = "nomade:delivery",
        payees = {
            { player = 7, amount = gross }, { player = 7, amount = bonusEach },
            { player = 8, amount = bonusEach }, { player = 9, amount = bonusEach },
            { society = "nomade", amount = society },
        },
    }
    local r, why = WW.async("rp_nomade", "rp_economy", "pay", spec)
    local bad, badWhy = WW.async("rp_nomade", "rp_economy", "invoice", {
        opId = "nomade:invoice:bad-split", from = { player = 8 }, amount = 100,
        payees = { { player = 7, amount = 60 }, { society = "nomade", amount = 30 } },
    })
    WW.settle()
    local lines = 0
    for _ in pairs(r and r.lines or {}) do lines = lines + 1 end
    return WW.result({
        pay = outcome(r, why),
        receipt_lines = lines,
        bad_split = outcome(bad, badWhy),
        commits = MH.shared.txStore.commits - commitsBefore,
        driver = WW.balance("cash:" .. A), rider1 = WW.balance("cash:" .. B), rider2 = WW.balance("cash:" .. C),
        society = WW.balance("soc:nomade"),
        journal = sums("nomade:pay:contract-41:batch-1"),
        client_absorbed = WW.journalTotal("sys:rp_nomade:client", "money"),
        net_minted = WW.economy().Mint.net("rp_nomade"),
    })
end

-- The window that 1.x left open between "goods out" and "money in" (rp_ferrailleur sell, rp_bank
-- deposit) is one operation now. Every crash point leaves goods XOR money, never both or neither.
local function crashSale(mode)
    WW.boot({ shims = saleShims() })
    seedPockets(A, { scrap = 4, component = 2 })
    WW.join(7, A, "V")
    local store = MH.shared.txStore
    local box = {}
    if mode == "unreachable_before" or mode == "lost_ack" then
        store.faults = { mode }
        box.r, box.why, box.info = WW.async("rp_ferrailleur", "rp_economy", "sale", saleSpec("ferrailleur:sale:acct-a:crash"))
    else
        -- The coordinator VM dies with the commit queued: "detached" = it reached the database
        -- and executes with nobody listening (D6); "discard" = it never did.
        MH.shared.txPaused = true
        MH.shared.txOnStop = mode
        local env = MH.resources.rp_ferrailleur.env
        MH.task("rp_ferrailleur", function()
            local p = env.Open77.exports.call("rp_economy", "sale", saleSpec("ferrailleur:sale:acct-a:crash"))
            box.r, box.why, box.info = p:await()
            box.done = true
        end)
        MH.run(2)
        MH.stop("open77_transactions")
        MH.run(3)
        MH.shared.txPaused = false
        WW.startCoordinator()
        MH.until_(function() return box.done end, 40)
    end
    WW.settle(60)
    WW.healthy()
    local replay, replayWhy = WW.async("rp_ferrailleur", "rp_economy", "sale", saleSpec("ferrailleur:sale:acct-a:crash"))
    WW.settle()
    local goods = WW.count("char:" .. A, "scrap") + WW.count("char:" .. A, "component")
    local paid = WW.balance("cash:" .. A) - 500
    return {
        sale = outcome(box.r, box.why), state = box.info and box.info.state or "",
        replay = outcome(replay, replayWhy),
        goods_left = goods, paid = paid, society = WW.balance("soc:ferrailleur"),
        conserved = ((goods == 6 and paid == 0) or (goods == 0 and paid == 270)) and "yes" or "NO",
        display = WW.sync("rp_ferrailleur", "rp_economy", "getBalance", 7) - 500,
    }
end

function scenarios.crash_between_debit_and_credit()
    local out = {}
    for _, mode in ipairs({ "unreachable_before", "lost_ack", "detached", "discard" }) do
        for k, v in pairs(crashSale(mode)) do out[mode .. "." .. k] = v end
        if #MH.errors > 0 then out[mode .. ".error"] = MH.errors[1] end
    end
    -- rp_bank deposit: one operation, so a store failure before COMMIT moves neither leg and the
    -- write-behind lands both on retry.
    WW.boot({ bank = true, shims = { WW.shim("rp_shops") } })
    WW.join(7, A, "V")
    MH.shared.txStore.faults = { "unreachable_before" }
    local deposited, why = WW.sync("rp_shops", "rp_bank", "deposit", 7, 200)
    WW.settle(60)
    out["deposit.result"] = tostring(deposited) .. "/" .. tostring(why)
    out["deposit.cash"] = WW.balance("cash:" .. A)
    out["deposit.bank"] = WW.balance("bank:" .. A)
    out["deposit.total"] = WW.balance("cash:" .. A) + WW.balance("bank:" .. A)
    return WW.result(out)
end

-- Credits reach subjects who are not connected (B8 R2: every 1.x refund to a disconnected player
-- failed); they see the money when they join.
function scenarios.offline_credit()
    WW.boot({ bank = true, shims = { WW.shim("rp_nomade"), WW.shim("rp_shops") } })
    WW.join(7, A, "V")
    local paid, paidWhy = WW.async("rp_nomade", "rp_economy", "pay", {
        opId = "nomade:pay:offline-1", from = { sys = "client" }, to = { identifier = "acct-away" },
        amount = 250, reason = "nomade:delivery",
    })
    -- A player charged, then gone, then refunded.
    WW.join(8, B, "Customer")
    local charged, chargedWhy = WW.async("rp_shops", "rp_economy", "charge", {
        opId = "shops:buy:acct-b:1", from = { player = 8 }, amount = 120, to = { society = "barman" }, reason = "purchase",
    })
    WW.settle()
    MH.disconnect(8)
    MH.run(1)
    local refunded, refundWhy = WW.async("rp_shops", "rp_economy", "refund", { of = "shops:buy:acct-b:1", reason = "refund" })
    local bankWire, bankWhy = WW.async("rp_shops", "rp_economy", "pay", {
        opId = "bank:wire:acct-a:offline", from = { player = 7, wallet = "bank" }, to = { identifier = "acct-away", wallet = "bank" },
        amount = 1, reason = "bank:transfer",
    })
    WW.settle()
    local awayBefore = WW.balance("cash:acct-away")
    WW.join(12, "acct-away", "Away")
    return WW.result({
        pay = outcome(paid, paidWhy), charge = outcome(charged, chargedWhy),
        refund_offline = outcome(refunded, refundWhy), wire_from_empty_bank = outcome(bankWire, bankWhy),
        away_durable = awayBefore, away_on_join = WW.sync("rp_nomade", "rp_economy", "getBalance", 12),
        customer_durable = WW.balance("cash:" .. B), barman = WW.balance("soc:barman"),
    })
end

-- ---------------------------------------------------------------------------------------------
-- The synchronous 1.x surface, called the way the pack calls it (representative sample of the
-- 18 synchronous callers: the helper forms of rp_jobs, rp_ferrailleur, rp_nomade, rp_admin,
-- rp_shops, rp_garage and rp_hud, copied from their server/main.lua).

local CALLER_HELPERS = [[
local function callExport(resource, name, ...)            -- rp_ferrailleur/server/main.lua:65
    local args = table.pack(...)
    local ok, r1, r2 = pcall(function()
        local target = exports[resource]
        return target[name](target, table.unpack(args, 1, args.n))
    end)
    if not ok then return nil, "unavailable:" .. resource end
    return r1, r2
end
local function callSync(resource, name, ...)              -- rp_nomade/server/main.lua:83
    local ok, a, b = pcall(Open77.exports.callSync, resource, name, ...)
    if not ok then return nil, "unavailable:" .. tostring(a) end
    return a, b
end
local function adminCall(resource, name, ...)             -- rp_admin/server/main.lua:97
    local args = table.pack(...)
    local ok, a, b = pcall(function()
        local proxy = exports[resource]
        return proxy[name](proxy, table.unpack(args, 1, args.n or #args))
    end)
    if not ok then return false, nil, resource .. "_offline" end
    return true, a, b
end
RESULTS = {}
HUD = { changed = 0, bank = 0, last = nil }
AddEventHandler("rp_economy:changed", function(playerId, balance, delta, reason)
    HUD.changed = HUD.changed + 1
    HUD.last = ("%s:%s:%s:%s"):format(playerId, balance, delta, tostring(reason))
end)
AddEventHandler("rp_bank:changed", function() HUD.bank = HUD.bank + 1 end)
]]

local function callerShim(name, body)
    return WW.shim(name, CALLER_HELPERS .. "\nfunction RUN(playerId)\n" .. body .. "\nend\n")
end

local function runShim(name, playerId)
    local env = MH.resources[name].env
    local ok, err = pcall(env.RUN, playerId)
    if not ok then return "raised:" .. tostring(err) end
    local out = {}
    for k, v in pairs(env.RESULTS) do out[#out + 1] = k .. "=" .. tostring(v) end
    table.sort(out)
    return table.concat(out, ";")
end

function scenarios.sync_callers()
    local shims = {
        -- rp_jobs payroll (server/main.lua:450-485) and first-boss seeding (:421-444).
        callerShim("rp_jobs", [[
            local okSeed, seeded, seedWhy = pcall(function() return exports.rp_bank:societyAdd("mecano", 50000, "seed") end)
            RESULTS.seed = okSeed and tostring(seeded or seedWhy) or "raised"
            local okRemove, balance, reason = pcall(function() return exports.rp_bank:societyRemove("mecano", 400, "payroll") end)
            RESULTS.payroll_society = okRemove and tostring(balance or reason) or "raised"
            local okAdd, cash = pcall(function() return exports.rp_economy:add(playerId, 400, "salary") end)
            RESULTS.payroll_cash = okAdd and tostring(cash) or "raised"
        ]]),
        -- rp_ferrailleur crowbar purchase (server/main.lua:741-782).
        callerShim("rp_ferrailleur", [[
            local newBalance, reason = callExport("rp_economy", "remove", playerId, 250, "crowbar")
            RESULTS.crowbar = tostring(newBalance or reason)
            local soc, why = callExport("rp_bank", "societyAdd", "ferrailleur", 250, "crowbar_sale:" .. playerId)
            RESULTS.crowbar_society = tostring(soc or why)
            local poor, poorWhy = callExport("rp_economy", "remove", playerId, 999999, "crowbar")
            RESULTS.too_poor = tostring(poor or poorWhy)
        ]]),
        -- rp_nomade rental deposit and refund (server/main.lua:111-131, 791-815).
        callerShim("rp_nomade", [[
            local deposit, why = callSync("rp_economy", "remove", playerId, 100, "nomade:rental")
            RESULTS.deposit = tostring(deposit or why)
            local refund, refundWhy = callSync("rp_economy", "add", playerId, 100, "nomade:rental_refund")
            RESULTS.refund = tostring(refund or refundWhy)
        ]]),
        -- rp_admin setmoney / setbank (server/main.lua:516-568).
        callerShim("rp_admin", [[
            local reachable, balance = adminCall("rp_economy", "getBalance", playerId)
            RESULTS.read = tostring(reachable) .. ":" .. tostring(balance)
            local _, added = adminCall("rp_economy", "add", playerId, 1000, "admin:setmoney")
            RESULTS.setmoney = tostring(added)
            local _, account = adminCall("rp_bank", "getAccount", playerId)
            RESULTS.account = account and tostring(account.balance) or "nil"
            local _, deposited, depWhy = adminCall("rp_bank", "deposit", playerId, 300)
            RESULTS.setbank = tostring(deposited or depWhy)
            local _, withdrawn, wWhy = adminCall("rp_bank", "withdraw", playerId, 1000000)
            RESULTS.overdraw_bank = tostring(withdrawn or wWhy)
        ]]),
        -- rp_shops purchase: cash, else withdraw + remove, then the society share (:200-260).
        callerShim("rp_shops", [[
            local ok, balance, why = pcall(function() return exports.rp_economy:remove(playerId, 5000, "shop:weapon") end)
            RESULTS.cash_short = tostring(balance or why)
            local okW, bank, bankWhy = pcall(function() return exports.rp_bank:withdraw(playerId, 5000) end)
            RESULTS.withdraw = tostring(bank or bankWhy)
            local okR, after, afterWhy = pcall(function() return exports.rp_economy:remove(playerId, 60, "shop:water") end)
            RESULTS.buy = tostring(after or afterWhy)
            local okS, soc, socWhy = pcall(function() return exports.rp_bank:societyAdd("barman", 42, "sale:water") end)
            RESULTS.share = tostring(soc or socWhy)
        ]]),
        -- rp_garage pay(): rp_bank:charge, else cash + societyAdd (server/main.lua:131-145).
        callerShim("rp_garage", [[
            local okBank, balance, why = pcall(function() return exports.rp_bank:charge(playerId, 100, "garage", "impound") end)
            RESULTS.charge = tostring(balance or why)
            local okCash, cash, cashWhy = pcall(function() return exports.rp_economy:remove(playerId, 100, "impound") end)
            RESULTS.cash = tostring(cash or cashWhy)
            local okSoc, soc = pcall(function() return exports.rp_bank:societyAdd("garage", 100, "impound") end)
            RESULTS.society = tostring(soc)
        ]]),
        -- rp_hud: reads both balances (server/main.lua:60-65); events counted by the helpers.
        callerShim("rp_hud", [[
            RESULTS.cash = tostring(exports.rp_economy:getBalance(playerId))
            local account = exports.rp_bank:getAccount(playerId)
            RESULTS.bank = account and tostring(account.balance) or "nil"
        ]]),
    }
    WW.boot({ bank = true, shims = shims })
    WW.join(7, A, "V")
    local out = {}
    for _, name in ipairs({ "rp_jobs", "rp_ferrailleur", "rp_nomade", "rp_admin", "rp_shops", "rp_garage" }) do
        out[name] = runShim(name, 7)
        MH.run(1)
    end
    WW.settle()
    out.rp_hud = runShim("rp_hud", 7)
    MH.run(2)
    local hud = MH.resources.rp_hud.env.HUD
    out.hud_changed_events = hud.changed
    out.hud_bank_events = hud.bank
    out.display_cash = WW.sync("rp_hud", "rp_economy", "getBalance", 7)
    out.durable_cash = WW.balance("cash:" .. A)
    out.durable_bank = WW.balance("bank:" .. A)
    out.society_mecano = WW.balance("soc:mecano")
    out.society_ferrailleur = WW.balance("soc:ferrailleur")
    out.society_garage = WW.balance("soc:garage")
    out.net_minted_rp_jobs = WW.economy().Mint.net("rp_jobs")
    out.net_minted_rp_nomade = WW.economy().Mint.net("rp_nomade")
    out.write_behind_failed = #MH.grep("write%-behind .* refused")
    return WW.result(out)
end

-- A write-behind change the coordinator refuses (another writer drained the wallet between the
-- cache's check and the commit) is reverted in the cache and logged; nothing is half-applied.
function scenarios.writebehind_refused()
    WW.boot({ shims = { WW.shim("rp_jobs"), WW.shim("thief") } })
    WW.join(7, A, "V")
    -- Another writer spends the cash directly at the coordinator; rp_economy hears about it only
    -- through the committed event, a pass later.
    MH.shared.txPaused = true
    local env = MH.resources.thief.env
    MH.task("thief", function()
        local p = env.Open77.exports.call("open77_transactions", "transfer", {
            opId = "thief:drain:acct-a:1", kind = "theft",
            lines = { { money = 500, from = "cash:" .. A, to = "sys:thief:loot" } },
        })
        p:await()
    end)
    local removed, why = WW.sync("rp_jobs", "rp_economy", "remove", 7, 400, "fine")
    MH.shared.txPaused = false
    WW.settle()
    return WW.result({
        accepted = tostring(removed) .. "/" .. tostring(why),
        durable = WW.balance("cash:" .. A),
        display = WW.sync("rp_jobs", "rp_economy", "getBalance", 7),
        refused_logged = #MH.grep("write%-behind .* insufficient_funds"),
    })
end

-- ---------------------------------------------------------------------------------------------
-- rp_bank

function scenarios.bank_facade()
    WW.boot({ bank = true, shims = { WW.shim("rp_shops"), WW.shim("rp_ncpd") } })
    WW.join(7, A, "Sender")
    WW.join(8, B, "Receiver")
    local function call(from, name, ...)
        local v, why = WW.sync(from, "rp_bank", name, ...)
        if v == nil then return "nil:" .. tostring(why) end
        if type(v) == "table" then return "balance:" .. tostring(v.balance) end
        return tostring(v)
    end
    local out = {}
    out.account = call("rp_shops", "getAccount", 7)
    out.deposit_short = call("rp_shops", "deposit", 7, 600)
    out.deposit = call("rp_shops", "deposit", 7, 400)
    out.withdraw_short = call("rp_shops", "withdraw", 7, 401)
    out.withdraw = call("rp_shops", "withdraw", 7, 100)
    out.transfer = call("rp_shops", "transfer", 7, B, 150, 2)
    out.transfer_unknown = call("rp_shops", "transfer", 7, "acct-nobody", 1, 0)
    out.transfer_self = call("rp_shops", "transfer", 7, A, 1, 0)
    out.society = call("rp_ncpd", "society", "ncpd")
    out.charge = call("rp_ncpd", "charge", 7, 50, "ncpd", "fine:speeding")
    out.society_after = call("rp_ncpd", "society", "ncpd")
    out.society_remove_short = call("rp_ncpd", "societyRemove", "ncpd", 51, "payroll")
    out.society_remove = call("rp_ncpd", "societyRemove", "ncpd", 20, "payroll")
    out.society_unknown_debit = call("rp_ncpd", "societyRemove", "brand_new_soc", 1, "x")
    out.society_unknown_credit = call("rp_ncpd", "societyAdd", "another_new_soc", 7, "x")
    out.amount_too_large = call("rp_shops", "deposit", 7, 1000000001)
    WW.settle()
    out.cash_a = WW.balance("cash:" .. A)
    out.bank_a = WW.balance("bank:" .. A)
    out.bank_b = WW.balance("bank:" .. B)
    out.soc_ncpd = WW.balance("soc:ncpd")
    out.soc_new = WW.balance("soc:another_new_soc")
    out.soc_new_read = call("rp_ncpd", "society", "another_new_soc")
    out.fee_burned = WW.journalTotal("sys:rp_bank:fee", "money")
    out.changed_events = #(function()
        local n = {}
        for _, line in ipairs(MH.logs) do if line:find("rp_bank%] player 7") then n[#n + 1] = line end end
        return n
    end)()
    out.total = WW.balance("cash:" .. A) + WW.balance("bank:" .. A) + WW.balance("cash:" .. B) + WW.balance("bank:" .. B)
        + WW.balance("soc:ncpd") + WW.balance("soc:another_new_soc") + out.fee_burned
        + WW.journalTotal("sys:rp_ncpd:legacy", "money")
    return WW.result(out)
end

-- ---------------------------------------------------------------------------------------------
-- Invoices and refunds

function scenarios.invoice_and_refund()
    WW.boot({ bank = true, shims = { WW.shim("rp_mecano"), WW.shim("rp_shops") } })
    WW.join(7, A, "Customer")
    WW.join(8, B, "Mechanic")
    -- 500 cash; move 300 to the bank so cash_then_bank must use both.
    WW.sync("rp_shops", "rp_bank", "deposit", 7, 300)
    WW.settle()
    local bill = {
        opId = "mecano:invoice:77", from = { player = 7 }, amount = 400, instrument = "cash_then_bank",
        payees = { { player = 8, amount = 280 }, { society = "mecano", amount = 120 } }, reason = "mecano:bill",
    }
    local r1, why1 = WW.async("rp_mecano", "rp_economy", "invoice", bill)
    local r2, why2 = WW.async("rp_mecano", "rp_economy", "invoice", bill)
    WW.settle()
    local afterBill = { cash = WW.balance("cash:" .. A), bank = WW.balance("bank:" .. A),
        mechanic = WW.balance("cash:" .. B) - 500, society = WW.balance("soc:mecano") }
    local refund, refundWhy = WW.async("rp_mecano", "rp_economy", "refund", { of = "mecano:invoice:77", reason = "dispute" })
    local again, againWhy = WW.async("rp_mecano", "rp_economy", "refund", { of = "mecano:invoice:77", reason = "dispute" })
    WW.settle()
    return WW.result({
        invoice = outcome(r1, why1), invoice_replay = outcome(r2, why2),
        after_bill_cash = afterBill.cash, after_bill_bank = afterBill.bank,
        mechanic = afterBill.mechanic, society_after_bill = afterBill.society,
        refund = outcome(refund, refundWhy), refund_again = outcome(again, againWhy),
        cash = WW.balance("cash:" .. A), bank = WW.balance("bank:" .. A),
        mechanic_after = WW.balance("cash:" .. B) - 500, society = WW.balance("soc:mecano"),
    })
end

-- ---------------------------------------------------------------------------------------------
-- Mint allowlist

function scenarios.mint_window()
    WW.boot({ shims = { WW.shim("rp_selftest"), WW.shim("compat_test") } })
    WW.join(7, A, "V")
    local function add(from, n)
        local v, why = WW.sync(from, "rp_economy", "add", 7, n, "probe")
        return v and "ok" or tostring(why)
    end
    local out = {}
    out.under_cap = add("rp_selftest", 600)
    out.over_cap = add("rp_selftest", 500)
    out.burn = (WW.sync("rp_selftest", "rp_economy", "remove", 7, 200, "probe")) and "ok" or "refused"
    out.after_burn = add("rp_selftest", 500)
    out.net = WW.economy().Mint.net("rp_selftest")
    MH.run(3600)
    out.next_window = add("rp_selftest", 1000)
    out.unlisted = add("compat_test", 1)
    WW.settle()
    out.durable = WW.balance("cash:" .. A)
    return WW.result(out)
end

-- ---------------------------------------------------------------------------------------------
-- Migration of the 1.x tables

local function legacyDb()
    local db = WW.freshDb()
    db.wallets = {
        [A] = { balance = 1500 }, [B] = { balance = 0 }, [C] = { balance = 250 },
        ["12345"] = { balance = 99 }, ["acct-neg"] = { balance = -5 },
    }
    db.accounts = { [A] = { balance = 300 }, [B] = { balance = 0 }, ["acct-d"] = { balance = 700 } }
    db.societies = { ferrailleur = { balance = 1200 }, NoMade = { balance = 10 }, ncpd = { balance = 0 } }
    db.transactions = {
        { identifier = A, delta = 300, balance_after = 300, kind = "deposit", note = "", at = 900 },
        { identifier = "society:ferrailleur", delta = 30, balance_after = 1200, kind = "society_add", note = "scrap_sale:3", at = 950 },
    }
    return db
end

function scenarios.migration_golden()
    WW.boot({ bank = true, db = legacyDb(), shims = { WW.shim("rp_jobs") } })
    MH.kvp.rp_economy = { ["balance:" .. A] = 999, ["balance:acct-kvp-only"] = 50, ["migrated:sql"] = 900 }
    WW.connect(7, A, "V")
    MH.run(5)
    local env = WW.economy()
    local out = {}
    out.state_before = env.Migrate.state
    out.join_before = WW.sync("rp_jobs", "rp_economy", "getBalance", 7)
    out.add_before = select(2, WW.sync("rp_jobs", "rp_economy", "add", 7, 10, "t")) or "accepted"
    MH.command("economy_migrate", 0, {})
    MH.until_(function() return env.Migrate.state == "complete" end, 120)
    WW.settle()
    MH.until_(function() return env.Wallets.byPlayer[7] ~= nil end, 30)
    WW.join(8, B, "Broke")
    WW.join(9, "acct-new", "Newcomer")
    out.state = env.Migrate.state
    local last = env.Migrate.last or {}
    out.summary = ("subjects=%s societies=%s imported=%s already=%s empty=%s skipped=%s failed=%s"):format(
        last.subjects, last.societies, last.imported, last.already, last.empty, last.skipped, last.failed)
    out.cash_a = WW.balance("cash:" .. A)
    out.bank_a = WW.balance("bank:" .. A)
    out.cash_b = WW.balance("cash:" .. B)
    out.cash_c = WW.balance("cash:" .. C)
    out.bank_d = WW.balance("bank:acct-d")
    out.soc_ferrailleur = WW.balance("soc:ferrailleur")
    out.soc_nomade = WW.balance("soc:nomade")
    out.join_a = WW.sync("rp_jobs", "rp_economy", "getBalance", 7)
    out.join_b_no_start_grant = WW.sync("rp_jobs", "rp_economy", "getBalance", 8)
    out.join_new_start_grant = WW.sync("rp_jobs", "rp_economy", "getBalance", 9)
    out.skipped_logged = #MH.grep("migration: skipped")
    out.ledger_rows = #MH.shared.db.transactions
    out.state_row = MH.shared.db.state and MH.shared.db.state.state or "none"
    out.journal_a = sums(env.Wallets.opIdFor("rp.migrate.v1.s.", A))
    -- Idempotent re-run: forget the state, import again.
    MH.shared.db.state = nil
    env.Migrate.state = "unknown"
    MH.command("economy_migrate", 0, {})
    MH.until_(function() return env.Migrate.state == "complete" end, 120)
    WW.settle()
    local again = env.Migrate.last or {}
    out.rerun = ("imported=%s already=%s"):format(again.imported, again.already)
    out.cash_a_after_rerun = WW.balance("cash:" .. A)
    out.soc_after_rerun = WW.balance("soc:ferrailleur")
    -- KVP: reported, never imported.
    MH.command("economy_kvp_report", 0, {})
    MH.run(5)
    out.kvp_differs = #MH.grep("kvp_report .* DIFFERS")
    out.kvp_only_imported = WW.balance("cash:acct-kvp-only")
    -- A state row from a newer schema blocks the facade instead of re-importing.
    local keep = WW.keep()
    keep.db.state.schema_version = 2
    WW.boot({ keep = keep, bank = true, shims = { WW.shim("rp_jobs") } })
    WW.connect(7, A, "V")
    MH.run(5)
    out.newer_state = WW.economy().Migrate.state
    out.newer_join = WW.sync("rp_jobs", "rp_economy", "getBalance", 7)
    return WW.result(out)
end

-- More rows than the bridge's maxRows (10 000): the 1.x unbounded boot load is silently
-- truncated, the paged import reads and imports every row.
function scenarios.migration_truncation()
    local db = WW.freshDb()
    local n = 10050
    for i = 1, n do db.wallets[("acct-%05d"):format(i)] = { balance = i } end
    for i = 1, n do db.accounts[("acct-%05d"):format(i)] = { balance = 1 } end
    WW.boot({ db = db })
    WW.economy().EconomyConfig.migration.parallel = 64
    -- What rp_bank 1.x did at boot (rp_bank/server/main.lua:437-470 at 5dcdad2).
    local legacyRows = WW.sql("query", "SELECT identifier, balance, created_at FROM rp_bank_accounts")
    MH.command("economy_migrate", 0, {})
    local env = WW.economy()
    MH.until_(function() return env.Migrate.state == "complete" or env.Migrate.state == "failed" end, 3000)
    local imported, total = 0, 0
    for i = 1, n do
        local id = ("acct-%05d"):format(i)
        if WW.balance("cash:" .. id) == i and WW.balance("bank:" .. id) == 1 then imported = imported + 1 end
        total = total + WW.balance("cash:" .. id)
    end
    return WW.result({
        legacy_boot_rows = #legacyRows, truncated_reads = MH.shared.db.truncated,
        state = env.Migrate.state, subjects_imported = imported,
        cash_total = total, expected_total = n * (n + 1) // 2,
        summary = env.Migrate.last and ("imported=" .. tostring(env.Migrate.last.imported)) or "none",
    })
end

WALLET_SCENARIOS = scenarios

-- ---------------------------------------------------------------------------------------------
-- The final coordinator's API (Open77 697e9e2f) as the wallet adapters use it.

-- A character layer's provider: every subject is the account identifier plus `~1`.
local PROVIDER = WW.shim("rp_identity_test", [[
exports("subjectFor", function(who)
    if type(who) == "string" then return who .. "~1" end
    local identifier = Open77.players.identifier(who)
    if not identifier then return nil, "no_character" end
    return identifier .. "~1"
end)
AddEventHandler("onResourceStart", function(name)
    if name ~= GetCurrentResourceName() then return end
    Open77.exports.callSync("open77_transactions", "registerSubjectProvider", "subjectFor")
end)
]])

-- The writer of the pockets: rp_inventory's grantPockets(opId, playerId) as rp_economy calls it
-- (open77_transactions authorize for that one operation); `grant` is the same for a test caller.
local GRANTER = WW.shim("rp_inventory", [[
GRANTS = 0
exports("grantPockets", function(opId, playerId)
    if GetInvokingResource() ~= "rp_economy" then return nil, "caller_not_allowed" end
    GRANTS = GRANTS + 1
    local account = "char:" .. tostring(Open77.players.identifier(playerId))
    return Open77.exports.callSync("open77_transactions", "authorize", opId, "rp_economy", { account }, 30000)
end)
]])

function scenarios.final_api()
    local out = {}
    -- 1. No coordinator mint rule for rp_economy: a legacy credit is refused at once (allowed), an
    --    atomic one by the coordinator; burns are never restricted. The rule grammar names one
    --    sys: segment (`sys:<name>` or `sys:*`): a rule for `sys:rp_economy:start` is ignored.
    local HUD = WW.shim("hud_shim", [[
SEEN = {}
AddEventHandler("rp_economy:pendingChanged", function(playerId) SEEN[#SEEN + 1] = tostring(playerId) end)
]])
    WW.boot({ shims = { WW.shim("rp_jobs"), HUD }, tunables = { mint1 = "rp_economy sys:rp_economy:start money 100000" } })
    MH.shared.txStore:seedWallet("cash:" .. A, 200)
    WW.join(7, A, "V")
    out.rule_ignored = tostring(#MH.grep("mint rules: ignored entry 'rp_economy sys:rp_economy:start money 100000'"))
    out.start_grant = WW.balance("cash:" .. A)
    local v, why = WW.sync("rp_jobs", "rp_economy", "add", 7, 100, "salary")
    out.add_without_rule = tostring(v) .. "/" .. tostring(why)
    v, why = WW.sync("rp_jobs", "rp_economy", "remove", 7, 50, "fine")
    out.burn_without_rule = tostring(v) .. "/" .. tostring(why)
    local r, rwhy = WW.async("rp_jobs", "rp_economy", "pay", { opId = "jobs:pay:final:0001", from = { sys = "payroll" },
        to = { player = 7 }, amount = 10, reason = "payroll" })
    out.pay_without_rule = outcome(r, rwhy)
    WW.settle()
    out.pending_changed = table.concat(MH.resources.hud_shim.env.SEEN, ",")
    out.durable = WW.balance("cash:" .. A)
    out.net_minted_after_refusals = WW.economy().Mint.net("rp_jobs")
    -- the business reason reached the journal (contract 7.2 `reason`)
    local reasons = {}
    for _, e in ipairs(MH.shared.txStore.journal) do
        if e.account == "cash:" .. A then reasons[#reasons + 1] = tostring(e.reason) end
    end
    out.journal_reasons = table.concat(reasons, ",")

    -- 2. Strict writers: rp_economy writes wallets only. A sale out of the pockets is refused
    --    until the pockets' writer authorizes that one operation; then it commits whole.
    WW.boot({ shims = { WW.DEFINER, WW.shim("rp_ferrailleur") },
        tunables = { writers = "rp_economy:cash+bank+soc, rp_inventory:char, inventory_shim" } })
    seedPockets(A, { scrap = 4, component = 2 })
    WW.join(7, A, "V")
    local denied, deniedWhy = WW.async("rp_ferrailleur", "rp_economy", "sale", saleSpec("ferrailleur:sale:acct-a:g1"))
    out.sale_without_grant = outcome(denied, deniedWhy)
    MH.start(GRANTER.name, { { source = GRANTER.source, name = "shim_rp_inventory.lua" } })
    local sold, soldWhy = WW.async("rp_ferrailleur", "rp_economy", "sale", saleSpec("ferrailleur:sale:acct-a:g2"))
    WW.settle()
    out.grant = tostring(MH.resources.rp_inventory.env.GRANTS)
    out.sale_with_grant = outcome(sold, soldWhy)
    out.after_grant = WW.count("char:" .. A, "scrap") .. "/" .. (WW.balance("cash:" .. A) - 500) .. "/" .. WW.balance("soc:ferrailleur")

    -- 2b. A unique unit sold out of a truck bed (C1 salvage crate): an instance line, its
    --     metadata with it, destroyed into the NPC buyer's sys account; one operation.
    WW.boot({ shims = { WW.DEFINER, WW.shim("rp_salvage") } })
    local store = MH.shared.txStore
    store:seedContainer("veh:NC-1:cargo", 300000, {}, WW.WEIGHTS)
    store:seedInstance("crate-0001", "crowbar", "veh:NC-1:cargo", { cargo = { slot = 1 } })
    store.containers["veh:NC-1:cargo"].weightG = WW.WEIGHTS.crowbar
    WW.join(7, A, "V")
    local crate, crateWhy = WW.async("rp_salvage", "rp_economy", "sale", {
        opId = "salvage:sale:acct-a:crate-0001", seller = { player = 7 },
        items = { { instance = "crate-0001", from = "veh:NC-1:cargo" } }, buyer = { sys = "buyer" }, total = 120,
        payees = { { player = 7, amount = 100 }, { society = "salvage", amount = 20 } }, reason = "salvage:crate" })
    local badInstance, badWhy = WW.async("rp_salvage", "rp_economy", "sale", {
        opId = "salvage:sale:acct-a:bad-0001", seller = { player = 7 },
        items = { { instance = "x" } }, buyer = { sys = "buyer" }, total = 1 })
    WW.settle()
    out.instance_sale = outcome(crate, crateWhy) .. ":" .. tostring(store.instances["crate-0001"].container)
        .. ":" .. (WW.balance("cash:" .. A) - 500) .. "/" .. WW.balance("soc:salvage")
    out.instance_invalid = outcome(badInstance, badWhy)
    out.salvage_minted = WW.economy().Mint.net("rp_salvage")

    -- 3. A character layer's provider: wallets follow its subject, for connected players and for
    --    offline identifiers alike; the 1.x tables stay keyed by the identifier.
    WW.boot({ shims = { PROVIDER, WW.shim("rp_nomade") } })
    WW.join(7, A, "V")
    local p = WW.economy().Wallets.byPlayer[7]
    out.provider_cash = tostring(p and p.cash)
    out.provider_start = WW.balance("cash:" .. A .. "~1") .. "/" .. WW.balance("cash:" .. A)
    local paid, paidWhy = WW.async("rp_nomade", "rp_economy", "pay", { opId = "nomade:pay:final:0001", from = { sys = "client" },
        to = { identifier = "acct-away" }, amount = 25, reason = "nomade:delivery" })
    WW.settle()
    out.provider_offline = outcome(paid, paidWhy) .. ":" .. WW.balance("cash:acct-away~1")
    return WW.result(out)
end

function RUN_SCENARIO(name)
    local scenario = assert(scenarios[name], "unknown scenario " .. tostring(name))
    return scenario()
end

-- Diagnostics for a failing run: the collected log lines matching a Lua pattern.
function DEBUG_LOGS(pattern)
    local out = {}
    for _, line in ipairs(MH.logs) do if not pattern or line:find(pattern) then out[#out + 1] = line end end
    return table.concat(out, "\n")
end
