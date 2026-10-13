-- =============================================================================
-- open77_transactions -- tests/wave1_test.lua
-- =============================================================================
-- Offline suite for what wave 1 added on top of the prototype: deadlock
-- resubmission, the coordinator's own outage tracking (D5) and commit
-- deadline (D7), the mint allowlist with hourly caps and the writers list,
-- world: containers, the non-blocking submit with projected reads, the lab
-- KVP store, receipt and operation pruning.
--
-- Load order: shared/model.lua, server/policy.lua, server/memory_store.lua,
-- server/coordinator.lua, server/sql_store.lua, server/kvp_store.lua, then this
-- file. Sets TestResult and TestSummary like the other suites.
-- =============================================================================

local M, Store, Coordinator, Policy, Kvp = Open77TxModel, Open77TxMemoryStore, Open77TxCoordinator,
    Open77TxPolicy, Open77TxKvpStore
assert(M and Store and Coordinator and Policy and Kvp, "load the model, policy, stores and coordinator first")

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

local A, B = "char:acct-a", "char:acct-b"
local CASH_A, SOC, DEALER, SALVAGE = "cash:acct-a", "soc:ferrailleur", "sys:dealer", "sys:salvage"
local WEIGHTS = { scrap = 500, chip = 50, crowbar = 1500 }

local function world(options)
    options = options or {}
    local clock = { t = 1000000 }
    local store = options.store or Store.new({ deferred = options.deferred == true })
    local co = Coordinator.new({
        store = store, now = function() return clock.t end, serverTag = "lab", policy = options.policy,
        acl = options.policy and function(r, ns, id) return options.policy:canWrite(r, ns, id) end or nil,
        onWorld = options.onWorld, onCommitted = options.onCommitted,
        receiptLimit = options.receiptLimit, opRetentionMs = options.opRetentionMs,
    })
    co:define({ scrap = { weightG = 500 }, chip = { weightG = 50 }, crowbar = { weightG = 1500, unique = true } }, "t")
    if not options.store then
        store:seedContainer(A, 40000, { scrap = 8 }, WEIGHTS)
        store:seedContainer(B, 40000, {}, WEIGHTS)
        store:seedWallet(CASH_A, 100)
        store:seedWallet(SOC, 0)
    end
    return co, store, clock
end

local function capture()
    local box = { done = false }
    return box, function(res, reason, info) box.done, box.res, box.reason, box.info = true, res, reason, info end
end
local function call(co, method, ...)
    local box, cb = capture()
    local args = table.pack(...)
    args[args.n + 1] = cb
    co[method](co, table.unpack(args, 1, args.n + 1))
    return box
end
local function sale(opId, count, money)
    return { opId = opId, kind = "sale", lines = {
        { item = "scrap", count = count or 2, from = A, to = DEALER },
        { money = money or 20, from = DEALER, to = CASH_A },
    } }
end

-- ---------------------------------------------------------------------------
run("W1 a deadlock is resubmitted with the same plan and commits once", function()
    local co, store = world()
    store.faults = { "deadlock" }
    local t = call(co, "transfer", sale("op-dlk-1"), "rp_ferrailleur")
    store:flush()
    check(t.res and t.res.state == "committed", "committed after a retry: " .. tostring(t.reason))
    check(store.commits == 1 and store:balance(CASH_A) == 120, "applied once")
    check(co:operation("op-dlk-1").attempts == 2, "two submissions")
    check(co:health().stats.transientRetries == 1, "retry counted")
end)

run("W2 exhausted deadlock retries settle as a retryable conflict; the opId stays usable", function()
    local co, store = world()
    store.faults = { "deadlock", "deadlock", "deadlock", "deadlock" }
    local t = call(co, "transfer", sale("op-dlk-2"), "rp_ferrailleur")
    store:flush()
    check(t.reason == "conflict" and t.info.retryable == true, "conflict: " .. tostring(t.reason))
    check(store.commits == 0 and store.ops["op-dlk-2"] == nil, "nothing durable, no tombstone")
    local again = call(co, "transfer", { opId = "op-dlk-2b", kind = "sale", lines = sale("x").lines }, "rp_ferrailleur")
    store:flush()
    check(again.res ~= nil, "the goods are free again")
end)

-- ---------------------------------------------------------------------------
run("W3 nothing mints by default; a rule allows it up to its hourly cap", function()
    local policy = Policy.new({ writers = "*", rules = {} })
    local co, store, clock = world({ policy = policy })
    local denied = call(co, "transfer", sale("op-mint-0"), "rp_ferrailleur")
    check(denied.reason == "mint_denied", "no rule: " .. tostring(denied.reason))
    policy:setRules({ "rp_ferrailleur sys:dealer money 50" })
    local first = call(co, "transfer", sale("op-mint-1", 2, 30), "rp_ferrailleur")
    store:flush()
    check(first.res ~= nil, "30 of 50: " .. tostring(first.reason))
    local over = call(co, "transfer", sale("op-mint-2", 2, 30), "rp_ferrailleur")
    check(over.reason == "mint_cap_exceeded" and over.info.retryable == true, "60 > 50: " .. tostring(over.reason))
    local other = call(co, "transfer", sale("op-mint-3", 2, 10), "rp_other")
    check(other.reason == "mint_denied", "the rule is per resource")
    clock.t = clock.t + 3600000 + 60000
    local later = call(co, "transfer", sale("op-mint-4", 2, 30), "rp_ferrailleur")
    store:flush()
    check(later.res ~= nil, "the hour slid: " .. tostring(later.reason))
end)

run("W3b concurrent commits are charged in flight; a failure gives the cap back", function()
    local policy = Policy.new({ rules = { "rp_ferrailleur sys:dealer money 50" } })
    local co, store = world({ policy = policy, deferred = true })
    call(co, "reserve", sale("op-cap-1", 2, 30), "rp_ferrailleur")
    call(co, "reserve", sale("op-cap-2", 2, 30), "rp_ferrailleur")
    store.faults = { "failed" }
    local c1 = call(co, "commit", "op-cap-1", nil, "rp_ferrailleur")
    local c2 = call(co, "commit", "op-cap-2", nil, "rp_ferrailleur")
    check(c2.reason == "mint_cap_exceeded", "the second would overshoot while the first is in flight: " .. tostring(c2.reason))
    store:flush()
    check(c1.reason == "store_failed", "first failed definitively")
    local c2b = call(co, "commit", "op-cap-2", nil, "rp_ferrailleur")
    store:flush()
    check(c2b.res ~= nil, "cap released by the failure: " .. tostring(c2b.reason))
    local snap = policy:snapshot(1000000)
    check(snap[1].used == 30 and snap[1].inflight == 0, "used 30, nothing in flight")
end)

run("W3c a salvage envelope needs an item rule; the roll is charged at commit", function()
    local policy = Policy.new({ rules = { "c1_salvage sys:salvage * 3" } })
    local co, store = world({ policy = policy })
    local r = call(co, "reserve", { opId = "op-env-1", lines = { { capacityG = 2000, from = SALVAGE, to = B } } }, "c1_salvage")
    check(r.res ~= nil, "envelope allowed by an item rule")
    local bad = call(co, "commit", "op-env-1", { lines = { { item = "chip", count = 4, from = SALVAGE, to = B } } }, "c1_salvage")
    check(bad.reason == "mint_cap_exceeded", "4 > 3: " .. tostring(bad.reason))
    local ok = call(co, "commit", "op-env-1", { lines = { { item = "scrap", count = 3, from = SALVAGE, to = B } } }, "c1_salvage")
    store:flush()
    check(ok.res ~= nil and store:count(B, "scrap") == 3, "3 minted")
    local money = call(co, "transfer", { opId = "op-env-2", lines = { { money = 1, from = SALVAGE, to = CASH_A } } }, "c1_salvage")
    check(money.reason == "mint_denied", "an item rule never mints money")
end)

run("W4 the writers list confines namespaces", function()
    local policy = Policy.new({ writers = "rp_inventory:char+world, rp_economy", rules = { "rp_economy sys:* money 1000" } })
    local co, store = world({ policy = policy })
    local inv = call(co, "transfer", { opId = "op-acl-1", lines = { { item = "scrap", count = 1, from = A, to = B } } }, "rp_inventory")
    store:flush()
    check(inv.res ~= nil, "rp_inventory moves items between characters: " .. tostring(inv.reason))
    local cash = call(co, "transfer", { opId = "op-acl-2", lines = { { money = 5, from = CASH_A, to = SOC } } }, "rp_inventory")
    check(cash.reason == "namespace_denied", "but not money: " .. tostring(cash.reason))
    local eco = call(co, "transfer", { opId = "op-acl-3", lines = { { money = 5, from = CASH_A, to = SOC } } }, "rp_economy")
    store:flush()
    check(eco.res ~= nil, "rp_economy may write every namespace: " .. tostring(eco.reason))
    local stranger = call(co, "transfer", { opId = "op-acl-4", lines = { { item = "scrap", count = 1, from = A, to = B } } }, "rp_other")
    check(stranger.reason == "namespace_denied", "an unlisted resource writes nothing")
    local _, problems = Policy.parseWriters("ok, bad!name")
    check(#problems == 1 and problems[1] == "bad!name", "malformed entries are reported")
    local _, ruleProblems = Policy.parseRules({ "rp_x sys:a money 10; nonsense; rp_y cash:a money 5" })
    check(#ruleProblems == 2, "malformed rules are reported, got " .. #ruleProblems)
end)

-- ---------------------------------------------------------------------------
run("W5 world containers: minted id, metadata, custody, close only when empty", function()
    local events = {}
    local co, store = world({ onWorld = function(id, change, meta) events[#events + 1] = change end })
    local opened = call(co, "openWorld", { capacityG = 50000, meta = { x = 1.5, y = -2, z = 30, bucket = 0, model = "crate" } }, "rp_inventory")
    check(opened.res and opened.res.id:match("^world:lab%.") ~= nil, "minted id: " .. tostring(opened.res and opened.res.id))
    local id = opened.res.id
    check(M.durableKeyProblem(id) == nil, "the minted id passes the durable-key lint")
    check(store.containers[id] and store.containers[id].meta.model == "crate", "meta stored")
    local drop = call(co, "transfer", { opId = "op-drop-1", lines = { { item = "scrap", count = 3, from = A, to = id } } }, "rp_inventory")
    store:flush()
    check(drop.res ~= nil and store:count(id, "scrap") == 3, "dropped into the pile")
    local busy = call(co, "close", id, "rp_inventory")
    check(busy.reason == "container_not_empty", "a pile with goods cannot close: " .. tostring(busy.reason))
    local moved = call(co, "setMeta", id, { x = 9, y = 9, z = 30, bucket = 0, model = "crate" }, "rp_inventory")
    check(moved.res and moved.res.meta.x == 9 and store.containers[id].meta.x == 9, "meta updated")
    local list = call(co, "listWorld", "", 10)
    check(list.res and #list.res == 1 and list.res[1].id == id and list.res[1].meta.x == 9, "listed for projection")
    local pick = call(co, "transfer", { opId = "op-pick-1", lines = { { item = "scrap", count = 3, from = id, to = B } } }, "rp_inventory")
    store:flush()
    check(pick.res ~= nil and store:count(B, "scrap") == 3, "picked up")
    local closed = call(co, "close", id, "rp_inventory")
    check(closed.res == true and store.containers[id] == nil and co:read(id) == nil, "closed and forgotten")
    check(table.concat(events, ",") == "opened,meta,closed", "events: " .. table.concat(events, ","))
    local direct = call(co, "open", "world:chosen-by-caller", { capacityG = 10 }, "rp_inventory")
    check(direct.reason == "invalid_account", "world ids are never chosen by the caller")
    local huge = {}
    for i = 1, 300 do huge["k" .. i] = string.rep("x", 10) end
    check(call(co, "openWorld", { capacityG = 1, meta = huge }, "rp_inventory").reason == "invalid_spec", "meta capped")
end)

-- ---------------------------------------------------------------------------
run("W6 an outage refuses new work at once; a probe brings it back", function()
    local co, store, clock = world()
    call(co, "load", A); call(co, "load", CASH_A)
    store.down = true
    local c = call(co, "load", B)
    check(c.reason == "store_unavailable" and co:health().down == true, "marked down after a failed load")
    local r = call(co, "reserve", sale("op-out-1"), "rp_ferrailleur")
    check(r.reason == "store_unavailable", "loaded mirrors still refuse while down: " .. tostring(r.reason))
    store.down = false
    clock.t = clock.t + 2500
    co:tick()
    check(co:health().down == false, "probe succeeded")
    local ok = call(co, "transfer", sale("op-out-2"), "rp_ferrailleur")
    check(ok.res ~= nil, "accepted again: " .. tostring(ok.reason))
end)

run("W6b a commit refused during an outage keeps its reservation", function()
    local co, store, clock = world()
    call(co, "reserve", sale("op-keep-1"), "rp_ferrailleur")
    co.down = true
    local c = call(co, "commit", "op-keep-1", nil, "rp_ferrailleur")
    check(c.reason == "store_unavailable" and c.info.state == "reserved", "refused, still reserved")
    co.down = false
    local c2 = call(co, "commit", "op-keep-1", nil, "rp_ferrailleur")
    check(c2.res ~= nil, "committed once the store is back")
end)

run("W7 a commit past its deadline is resolved by the fence, never applied twice", function()
    local co, store, clock = world({ deferred = true })
    call(co, "reserve", sale("op-late-1"), "rp_ferrailleur")
    local c = call(co, "commit", "op-late-1", nil, "rp_ferrailleur")
    check(store:pending() == 1, "submitted, unanswered")
    clock.t = clock.t + 21000
    co:tick()
    check(co:operation("op-late-1").state == "in_doubt", "in doubt after the deadline")
    store:flush() -- the original lands first, then the fence finds it
    check(c.res and c.res.state == "committed", "settled committed: " .. tostring(c.reason))
    check(co:read(CASH_A).balance == 120 and store:balance(CASH_A) == 120, "mirror applied once")
    check(co:health().stats.deadlineExpired == 1 and co:health().stats.fencedCommitted == 1, "counted")
end)

-- ---------------------------------------------------------------------------
run("W8 submit answers at once and reads project the pending delta", function()
    local co, store = world({ deferred = true })
    local cold = call(co, "submit", sale("op-wbk-0"), "rp_economy")
    check(cold.reason == "not_loaded", "unloaded accounts refuse: " .. tostring(cold.reason))
    call(co, "load", A); call(co, "load", CASH_A)
    store:flush()
    local s = call(co, "submit", sale("op-wbk-1", 2, 25), "rp_economy")
    check(s.res and s.res.state == "committing", "answered before the ack: " .. tostring(s.res and s.res.state))
    local snap = co:read(CASH_A)
    check(snap.balance == 100 and snap.pending.money == 25, "pending +25 on top of 100")
    check(co:read(A).pending.items.scrap == -2, "goods pending out")
    store:flush()
    snap = co:read(CASH_A)
    check(snap.balance == 125 and snap.pending.money == 0, "applied after the ack")
    local again = call(co, "submit", sale("op-wbk-1", 2, 25), "rp_economy")
    check(again.res and again.res.replay == true, "a resubmitted opId replays")
end)

run("W9 caps are rebuilt from the journal at boot", function()
    local policy = Policy.new({ rules = { "rp_ferrailleur sys:dealer money 50" } })
    local seeded = policy:seed({ { resource = "rp_ferrailleur", from = "sys:dealer", asset = "money", amount = 40, at = 999000 } })
    check(seeded == 1, "one row attributed")
    check(policy:check("rp_ferrailleur", { { from = "sys:dealer", asset = "money", amount = 11 } }, 1000000) == nil,
        "40 + 11 > 50 after a restart")
end)

-- ---------------------------------------------------------------------------
local function fakeKvp()
    local data = {}
    local kvp = { data = data }
    function kvp.find(prefix, limit)
        local keys = {}
        for k in pairs(data) do if k:sub(1, #prefix) == prefix then keys[#keys + 1] = k end end
        table.sort(keys)
        local out = {}
        for i = 1, math.min(#keys, limit or 4096) do out[i] = { key = keys[i], value = data[keys[i]], type = "string" } end
        return out
    end
    function kvp.set(k, v) data[k] = v; return true end
    function kvp.delete(k) local had = data[k] ~= nil; data[k] = nil; return had end
    return kvp
end

-- A tiny JSON decoder for the test (the runtime uses json.decode).
local function decode(text)
    local pos = 1
    local function ws() pos = text:find("[^ \t\r\n]", pos) or #text + 1 end
    local value
    local function str()
        local out = {}
        pos = pos + 1
        while true do
            local c = text:sub(pos, pos)
            if c == '"' then pos = pos + 1; break end
            if c == "\\" then
                local n = text:sub(pos + 1, pos + 1)
                out[#out + 1] = ({ n = "\n", r = "\r", t = "\t" })[n] or n
                pos = pos + 2
            else out[#out + 1] = c; pos = pos + 1 end
        end
        return table.concat(out)
    end
    function value()
        ws()
        local c = text:sub(pos, pos)
        if c == "{" then
            local t = {}
            pos = pos + 1; ws()
            if text:sub(pos, pos) == "}" then pos = pos + 1; return t end
            while true do
                ws(); local k = str(); ws(); pos = pos + 1
                t[k] = value(); ws()
                local d = text:sub(pos, pos); pos = pos + 1
                if d == "}" then return t end
            end
        elseif c == "[" then
            local t = {}
            pos = pos + 1; ws()
            if text:sub(pos, pos) == "]" then pos = pos + 1; return t end
            while true do
                t[#t + 1] = value(); ws()
                local d = text:sub(pos, pos); pos = pos + 1
                if d == "]" then return t end
            end
        elseif c == '"' then return str()
        elseif text:sub(pos, pos + 3) == "true" then pos = pos + 4; return true
        elseif text:sub(pos, pos + 4) == "false" then pos = pos + 5; return false
        elseif text:sub(pos, pos + 3) == "null" then pos = pos + 4; return nil
        else
            local num = text:match("^-?[%d%.eE+-]+", pos)
            pos = pos + #num
            return math.tointeger(tonumber(num)) or tonumber(num)
        end
    end
    return value()
end

run("W10 lab_kvp: rows survive a restart and replays read the persisted op row", function()
    local kvp = fakeKvp()
    local store = Kvp.new(kvp, { decode = decode })
    local clock = { t = 5000 }
    local co = Coordinator.new({ store = store, now = function() return clock.t end, serverTag = "lab" })
    co:define({ scrap = { weightG = 500 } }, "t")
    local opened = call(co, "open", A, { capacityG = 40000 }, "lab")
    check(opened.res ~= nil, "container opened")
    local mint = call(co, "transfer", { opId = "op-kvp-1", lines = {
        { item = "scrap", count = 4, from = SALVAGE, to = A }, { money = 70, from = DEALER, to = CASH_A } } }, "lab")
    check(mint.res and mint.res.state == "committed", "committed synchronously: " .. tostring(mint.reason))
    check(kvp.data["c|" .. A] ~= nil and kvp.data["w|" .. CASH_A] ~= nil and kvp.data["o|op-kvp-1"] ~= nil
        and kvp.data["j|op-kvp-1"] ~= nil, "rows, op and journal persisted")
    -- "Restart": a new store hydrated from the same KVP file, a new coordinator.
    local store2 = Kvp.new(kvp, { decode = decode })
    local co2 = Coordinator.new({ store = store2, now = function() return clock.t end, serverTag = "lab" })
    co2:define({ scrap = { weightG = 500 } }, "t")
    local snap = call(co2, "load", A)
    check(snap.res and snap.res.items.scrap == 4 and snap.res.weightG == 2000, "container restored")
    local wallet = call(co2, "load", CASH_A)
    check(wallet.res and wallet.res.balance == 70 and math.type(wallet.res.balance) == "integer", "wallet restored as an integer")
    local replay = call(co2, "commit", "op-kvp-1", nil, "lab")
    check(replay.res and replay.res.replay == true, "replayed from the persisted op row")
    local spend = call(co2, "transfer", { opId = "op-kvp-2", lines = { { money = 30, from = CASH_A, to = DEALER } } }, "lab")
    check(spend.res ~= nil and store2.memory.wallets[CASH_A].balance == 40, "keeps working after the restart")
end)

-- ---------------------------------------------------------------------------
run("W11 terminal operations are pruned; replays still answer from receipts", function()
    local co, store, clock = world({ opRetentionMs = 1000 })
    call(co, "transfer", sale("op-prune-1"), "rp_ferrailleur")
    clock.t = clock.t + 1001
    co:tick()
    check(co:operation("op-prune-1") == nil, "operation forgotten")
    local again = call(co, "commit", "op-prune-1", nil, "rp_ferrailleur")
    check(again.res and again.res.replay == true, "receipt replay")
end)

run("W12 the receipt cache is bounded; the store answers older replays", function()
    local co, store, clock = world({ receiptLimit = 2, opRetentionMs = 0 })
    for i = 1, 4 do call(co, "transfer", sale("op-ring-" .. i, 1, 1), "rp_ferrailleur") end
    clock.t = clock.t + 1
    co:tick()
    check(co.receipts["op-ring-1"] == nil and co.receipts["op-ring-4"] ~= nil, "oldest evicted")
    local old = call(co, "commit", "op-ring-1", nil, "rp_ferrailleur")
    check(old.res and old.res.replay == true, "replayed from the operation row")
end)

run("W13 later characters: `~` keys are durable", function()
    check(M.parseAccount("char:64c2016b-aaaa~2") == "char", "accepted")
    check(M.durableKeyProblem("cash:64c2016b-aaaa~2") == nil, "durable")
end)

run("W14 the committed callback carries the receipt and the touched accounts", function()
    local seen
    local co, store = world({ onCommitted = function(receipt, accounts) seen = { receipt = receipt, accounts = accounts } end })
    call(co, "transfer", sale("op-evt-1"), "rp_ferrailleur")
    check(seen and seen.receipt.opId == "op-evt-1", "receipt delivered")
    check(seen and table.concat(seen.accounts, ",") == CASH_A .. "," .. A, "accounts: " .. table.concat(seen and seen.accounts or {}, ","))
end)

run("W15 a read that started before our own commit never overwrites the mirror after it", function()
    local mem = Store.new({ deferred = false })
    mem:seedContainer(A, 40000, { scrap = 8 }, WEIGHTS)
    mem:seedWallet(CASH_A, 100)
    local held = {}
    -- A store whose reads are answered late with the row as it was when asked,
    -- like a real database round trip.
    local slow = setmetatable({}, { __index = function(_, k)
        local f = mem[k]
        if type(f) == "function" then return function(_, ...) return f(mem, ...) end end
        return f
    end })
    function slow:load(id, cb)
        local row = mem:_row(id)
        held[#held + 1] = function() cb(row) end
    end
    local co = Coordinator.new({ store = slow, now = function() return 1 end })
    co:define({ scrap = { weightG = 500 } }, "t")
    call(co, "load", A); call(co, "load", CASH_A)
    for _, f in ipairs(held) do f() end
    held = {}
    co:_reload({ A })                         -- a reload is asked (sees scrap = 8) ...
    local t = call(co, "transfer", sale("op-epoch-1"), "rp_ferrailleur")
    check(t.res ~= nil and co:read(A).items.scrap == 6, "... our sale commits first: 6")
    local old = table.remove(held, 1)
    old()                                     -- ... and the old answer arrives last
    check(co:read(A).items.scrap == 6, "the stale answer was dropped: " .. tostring(co:read(A).items.scrap))
    check(#held == 1, "and the account was read again")
    held[1]()
    check(co:read(A).items.scrap == 6 and co:read(A).stale == nil, "converged on the store")
end)

-- ---------------------------------------------------------------------------
-- Adapter needs (A9 N1-N4, B2 1-9, B3 a-g), integrator round of 2026-10-12
-- ---------------------------------------------------------------------------
local CARGO = "veh:NC-1234:cargo"

run("W16 an instance move carries a metaPatch under the same CAS (A9 N1)", function()
    local co, store = world()
    store:seedContainer(CARGO, 200000, {}, WEIGHTS)
    store:seedInstance("crate-01", "crowbar", CARGO, { serial = "SN-1", slot = 2 })
    store.containers[CARGO].weightG = 1500
    local mv = call(co, "transfer", { opId = "op-meta-01", lines = {
        { instance = "crate-01", from = CARGO, to = B, metaPatch = { slot = 7 } } } }, "rp_cargo")
    check(mv.res ~= nil, "moved: " .. tostring(mv.reason))
    local inst = store.instances["crate-01"]
    check(inst.container == B and inst.meta.slot == 7 and inst.meta.serial == "SN-1", "patched, serial kept")
    check(co:read(B).instances["crate-01"].meta.slot == 7, "mirror patched")
    local up = call(co, "transfer", { opId = "op-meta-02", lines = {
        { instance = "crate-01", at = B, metaPatch = { durability = 9 } } } }, "rp_cargo")
    check(up.res ~= nil and store.instances["crate-01"].meta.durability == 9 and store.instances["crate-01"].meta.slot == 7,
        "in-place patch merges")
    local both = call(co, "transfer", { opId = "op-meta-03", lines = {
        { instance = "crate-01", at = B, meta = { a = 1 }, metaPatch = { b = 2 } } } }, "rp_cargo")
    check(both.reason == "invalid_spec", "meta and metaPatch are exclusive")
end)

run("W17 a restarted VM replays a committed opId instead of refusing for missing goods (B3 c, B2 4)", function()
    local co, store = world()
    local first = call(co, "transfer", sale("op-restart-1"), "rp_ferrailleur")
    check(first.res ~= nil, "sold")
    store.containers[A].stacks.scrap = 0
    store.containers[A].weightG = 0
    local co2 = Coordinator.new({ store = store, now = function() return 2000000 end, serverTag = "lab" })
    co2:define({ scrap = { weightG = 500 } }, "t")
    local again = call(co2, "transfer", sale("op-restart-1"), "rp_ferrailleur")
    check(again.res and again.res.replay == true and again.res.opId == "op-restart-1",
        "the stored receipt, not insufficient_items: " .. tostring(again.reason))
    check(store:balance(CASH_A) == 120, "paid once")
end)

run("W18 a failed opId gets a fresh attempt; a fenced one stays aborted (B2 3 / B3 d)", function()
    local co, store = world()
    local poor = call(co, "transfer", { opId = "op-fresh-01", lines = { { money = 500, from = CASH_A, to = SOC } } }, "rp_economy")
    check(poor.reason == "insufficient_funds", "refused")
    store.wallets[CASH_A].balance = 1000
    co:_reload({ CASH_A })
    local retry = call(co, "transfer", { opId = "op-fresh-01", lines = { { money = 500, from = CASH_A, to = SOC } } }, "rp_economy")
    check(retry.res ~= nil and retry.res.replay == false, "same opId, fresh attempt: " .. tostring(retry.reason))
    local fenced = call(co, "status", "op-fence-01", { resolve = true })
    check(fenced.res and fenced.res.state == "aborted", "fenced")
    local after = call(co, "transfer", { opId = "op-fence-01", lines = { { money = 1, from = CASH_A, to = SOC } } }, "rp_economy")
    check(after.reason == "aborted", "a tombstone never commits: " .. tostring(after.reason))
end)

run("W19 a writer may be granted one part of a namespace (A9 N4)", function()
    local policy = Policy.new({ writers = "rp_cargo:veh/cargo, rp_garage:veh/trunk" })
    local co, store = world({ policy = policy })
    store:seedContainer(CARGO, 200000, { scrap = 2 }, WEIGHTS)
    store:seedContainer("veh:NC-1234:trunk", 50000, { scrap = 1 }, WEIGHTS)
    local ok = call(co, "transfer", { opId = "op-part-01", lines = { { item = "scrap", count = 1, from = CARGO, to = "sys:dealer" } } }, "rp_cargo")
    check(ok.res ~= nil, "cargo writer writes cargo: " .. tostring(ok.reason))
    local no = call(co, "transfer", { opId = "op-part-02", lines = { { item = "scrap", count = 1, from = "veh:NC-1234:trunk", to = "sys:dealer" } } }, "rp_cargo")
    check(no.reason == "namespace_denied", "but not the trunk")
    local trunk = call(co, "transfer", { opId = "op-part-03", lines = { { item = "scrap", count = 1, from = "veh:NC-1234:trunk", to = "sys:dealer" } } }, "rp_garage")
    check(trunk.res ~= nil, "the trunk writer may")
end)

run("W20 a two-party grant lets one named operation cross namespaces (B3 f)", function()
    local policy = Policy.new({ writers = "rp_inventory:char, rp_economy:cash+bank+soc",
        rules = { "rp_economy sys:dealer money 1000" } })
    local co, store = world({ policy = policy })
    local spec = { opId = "op-grant-01", kind = "sale", lines = {
        { item = "scrap", count = 2, from = A, to = DEALER }, { money = 20, from = DEALER, to = CASH_A } } }
    check(call(co, "transfer", spec, "rp_economy").reason == "namespace_denied", "no grant: denied")
    local bad = table.pack(co:authorize("op-grant-01", "rp_economy", { CASH_A }, 30000, "rp_inventory"))
    check(bad[1] == nil and bad[2] == "namespace_denied", "a grantor cannot grant what it may not write")
    check(co:authorize("op-grant-01", "rp_economy", { A }, 30000, "rp_inventory") == true, "granted")
    local t = call(co, "transfer", spec, "rp_economy")
    check(t.res ~= nil, "the granted sale goes through: " .. tostring(t.reason))
    check(co.grants["op-grant-01"] == nil, "the grant is spent")
    local other = call(co, "transfer", { opId = "op-grant-02", lines = { { item = "scrap", count = 1, from = A, to = DEALER } } }, "rp_economy")
    check(other.reason == "namespace_denied", "it covered one operation only")
end)

run("W21 reasons ride the lines and the history reads them back (B3 g)", function()
    local co, store = world()
    local t = call(co, "transfer", { opId = "op-why-001", kind = "sale", reason = "scrap sale at Kabuki",
        lines = { { item = "scrap", count = 2, from = A, to = DEALER },
                  { money = 20, from = DEALER, to = CASH_A, reason = "driver share" } } }, "rp_ferrailleur")
    check(t.res and t.res.reason == "scrap sale at Kabuki", "operation reason on the receipt")
    local h = call(co, "history", CASH_A, { limit = 10 })
    check(h.res and #h.res == 1 and h.res[1].delta == 20 and h.res[1].reason == "driver share"
        and h.res[1].kind == "sale", "history row: " .. tostring(h.res and h.res[1] and h.res[1].reason))
    local hA = call(co, "history", A, {})
    check(hA.res and hA.res[1].reason == "scrap sale at Kabuki", "lines without a reason inherit the operation reason")
    check(call(co, "transfer", { opId = "op-why-002", reason = string.rep("x", 65),
        lines = { { money = 1, from = DEALER, to = CASH_A } } }, "t").reason == "invalid_spec", "reasons are bounded")
end)

run("W22 weight drift between boots is reweighed, so the last debit still works (B2 6)", function()
    local co, store = world()
    -- Stored at 500 g a piece; the definition is now 600 g.
    local co2 = Coordinator.new({ store = store, now = function() return 3000000 end, serverTag = "lab" })
    co2:define({ scrap = { weightG = 600 } }, "t")
    local snap = call(co2, "readAccount", A)
    check(store.containers[A].weightG == 4800 and snap.res ~= nil,
        "reweighed to 8 x 600: " .. tostring(store.containers[A].weightG))
    local sellAll = call(co2, "transfer", { opId = "op-drift-1", lines = { { item = "scrap", count = 8, from = A, to = DEALER } } }, "t")
    check(sellAll.res ~= nil and store.containers[A].weightG == 0, "emptied to 0 g: " .. tostring(sellAll.reason))
    local reweighed = false
    for _, row in pairs(store.ops) do if row.kind == "reweigh" then reweighed = true end end
    check(reweighed, "the correction is an operation of its own")
end)

run("W23 read loads on demand and never creates (A9 N2 / B2 2)", function()
    local co, store = world()
    local missing = call(co, "readAccount", "stash:nowhere")
    check(missing.reason == "unknown_account" and store.containers["stash:nowhere"] == nil, "unknown, not created")
    local wallet = call(co, "readAccount", "cash:never-paid")
    check(wallet.reason == "unknown_account", "a never-credited wallet is unknown too")
    local found = call(co, "readAccount", A)
    check(found.res and found.res.items.scrap == 8, "loaded on demand")
end)

run("W24 containers keep metadata and can be listed per namespace (B2 5)", function()
    local co, store = world()
    local opened = call(co, "open", "stash:house_12", { capacityG = 20000, meta = { label = "Kabuki flat" } }, "rp_housing")
    check(opened.res and opened.res.meta.label == "Kabuki flat", "meta on open")
    local reopened = call(co, "open", "stash:house_12", { capacityG = 30000 }, "rp_housing")
    check(reopened.res and reopened.res.capacityG == 30000 and reopened.res.meta.label == "Kabuki flat", "kept on re-open")
    local set = call(co, "setMeta", "stash:house_12", { label = "sold" }, "rp_housing")
    check(set.res and store.containers["stash:house_12"].meta.label == "sold", "setMeta on any container")
    local page = call(co, "list", "stash", "", 10)
    check(page.res and #page.res == 1 and page.res[1].meta.label == "sold", "listed")
    check(call(co, "list", "cash", "", 10).reason == "invalid_account", "wallets are not containers")
end)

TestResult = { passed = passed, failed = #failures, failures = failures }
TestSummary = string.format("passed=%d failed=%d", passed, #failures)
    .. (#failures > 0 and ("\n" .. table.concat(failures, "\n")) or "")
print(string.format("[open77_transactions wave-1 tests] %d passed, %d failed", passed, #failures))
for _, f in ipairs(failures) do print("  FAIL: " .. f) end
