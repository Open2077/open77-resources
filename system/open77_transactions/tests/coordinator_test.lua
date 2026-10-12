-- =============================================================================
-- open77_transactions -- tests/coordinator_test.lua
-- =============================================================================
-- Offline interleaving and recovery suite for the A13 coordinator
-- (docs/world-interaction/a13-transaction-contract.md, section 8, T1-T20).
-- The store is server/memory_store.lua: deferred completions make every crash
-- window an explicit step, and faults inject the ambiguous outcomes.
--
-- Load order: shared/model.lua, server/memory_store.lua, server/coordinator.lua,
-- then this file. Runner-agnostic: sets TestResult (KeraLua MSTest harness,
-- TransactionsLuaTests.cs) and TestSummary (a string, for engines that only
-- read string globals, such as the B8 luahost.py).
-- =============================================================================

local M, Store, Coordinator = Open77TxModel, Open77TxMemoryStore, Open77TxCoordinator
assert(M and Store and Coordinator, "load model, memory_store and coordinator first")

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

-- ---------------------------------------------------------------------------
-- Fixture
-- ---------------------------------------------------------------------------
local A, B = "char:acct-a", "char:acct-b"
local CASH_A, CASH_B = "cash:acct-a", "cash:acct-b"
local CRATE, CARGO = "world:crate-1", "veh:NC-1234:cargo"
local SOC, DEALER, SALVAGE = "soc:ferrailleur", "sys:dealer", "sys:salvage"
local WEIGHTS = { scrap = 500, component = 300, chip = 50, crowbar = 1500 }

local function world(options)
    options = options or {}
    local clock = { t = 1000 }
    local store = options.store or Store.new()
    local co = Coordinator.new({ store = store, now = function() return clock.t end, serverTag = "lab" })
    co:define({
        scrap = { weightG = 500 }, component = { weightG = 300 }, chip = { weightG = 50 },
        crowbar = { weightG = 1500, unique = true },
    }, "rp_inventory")
    if not options.store then
        store:seedContainer(A, 40000, {}, WEIGHTS)
        store:seedContainer(B, 40000, {}, WEIGHTS)
        store:seedContainer(CRATE, 100000, { scrap = 4 }, WEIGHTS)
        store:seedContainer(CARGO, 200000, {}, WEIGHTS)
        store:seedWallet(CASH_A, 100)
        store:seedWallet(SOC, 0)
    end
    return co, store, clock
end

local function capture()
    local box = { done = false }
    return box, function(res, reason, info)
        box.done, box.res, box.reason, box.info = true, res, reason, info
    end
end

local function reserve(co, spec, resource)
    local box, cb = capture()
    co:reserve(spec, resource or "c1_salvage", cb)
    return box
end

local function commit(co, opId, final, resource)
    local box, cb = capture()
    co:commit(opId, final, resource or "c1_salvage", cb)
    return box
end

local function transfer(co, spec, resource)
    local box, cb = capture()
    co:transfer(spec, resource or "c1_salvage", cb)
    return box
end

local function pickup(opId, count)
    return { opId = opId, kind = "pickup", lines = { { item = "scrap", count = count or 4, from = CRATE, to = A } } }
end

-- ---------------------------------------------------------------------------
-- T1 concurrent pickup: one winner
-- ---------------------------------------------------------------------------
run("T1 two players reserve the one crate content", function()
    local co, store = world()
    local r1 = reserve(co, pickup("op-pick-a"))
    local r2 = reserve(co, { opId = "op-pick-b", lines = { { item = "scrap", count = 4, from = CRATE, to = B } } })
    check(r1.res and r1.res.state == "reserved", "first reserve holds")
    check(r2.res == nil and r2.reason == "insufficient_items", "second refused: " .. tostring(r2.reason))
    local c = commit(co, "op-pick-a")
    store:flush()
    check(c.res and c.res.state == "committed", "winner commits")
    check(store:count(CRATE, "scrap") == 0 and store:count(A, "scrap") == 4, "durable custody moved once")
    local again = reserve(co, { opId = "op-pick-b2", lines = { { item = "scrap", count = 1, from = CRATE, to = B } } })
    check(again.reason == "insufficient_items", "nothing left for a retry")
end)

-- ---------------------------------------------------------------------------
-- T2 full inventory cannot lose a drop
-- ---------------------------------------------------------------------------
run("T2 full inventory refuses before anything moves", function()
    local co, store = world()
    store:seedContainer(A, 1000, { scrap = 2 }, WEIGHTS) -- 1000 g of 1000 g used
    local r = reserve(co, pickup("op-full-1", 1))
    check(r.res == nil and r.reason == "capacity_exceeded", "refused: " .. tostring(r.reason))
    check(store:count(CRATE, "scrap") == 4, "the crate still holds everything")
    check(store.commits == 0, "nothing submitted")
end)

-- ---------------------------------------------------------------------------
-- T3 / T4 replay pays once, also across a coordinator restart
-- ---------------------------------------------------------------------------
local function saleSpec(opId)
    return {
        opId = opId, kind = "sale", actor = A,
        lines = {
            { item = "scrap", count = 4, from = A, to = DEALER },
            { money = 54, from = DEALER, to = CASH_A },
            { money = 6, from = DEALER, to = SOC },
        },
    }
end

run("T3 a replayed sale pays once", function()
    local co, store = world()
    store:seedContainer(A, 40000, { scrap = 4 }, WEIGHTS)
    local first = transfer(co, saleSpec("op-sale-1"))
    store:flush()
    check(first.res and first.res.replay == false, "first commit")
    local second = commit(co, "op-sale-1")
    check(second.res and second.res.replay == true, "second is a replay")
    local third = transfer(co, saleSpec("op-sale-1"))
    check(third.res and third.res.replay == true, "transfer with the same opId is a replay too")
    store:flush()
    check(store:balance(CASH_A) == 154 and store:balance(SOC) == 6, "paid exactly once")
    check(store.commits == 1, "one transaction")
end)

run("T4 replay from the op row after a coordinator restart", function()
    local co, store = world()
    store:seedContainer(A, 40000, { scrap = 4 }, WEIGHTS)
    transfer(co, saleSpec("op-sale-2"))
    store:flush()
    local co2 = world({ store = store }) -- new VM, same database
    local c = commit(co2, "op-sale-2")
    store:flush()
    check(c.res and c.res.replay == true and c.res.opId == "op-sale-2", "stored receipt returned")
    check(store:balance(CASH_A) == 154, "no second payout")
end)

run("T5 same opId with different lines is a conflict", function()
    local co, store = world()
    reserve(co, pickup("op-dup-1", 2))
    local r = reserve(co, pickup("op-dup-1", 3))
    check(r.reason == "op_id_conflict", "refused: " .. tostring(r.reason))
    local same = reserve(co, pickup("op-dup-1", 2))
    check(same.res and same.res.duplicate == true, "identical re-reserve is idempotent")
    check(store.commits == 0, "nothing submitted")
end)

-- ---------------------------------------------------------------------------
-- T6-T9 crash windows
-- ---------------------------------------------------------------------------
run("T6 reserve then coordinator lost: nothing durable, op unknown", function()
    local co, store = world()
    reserve(co, pickup("op-lost-1"))
    local co2 = world({ store = store })
    local c = commit(co2, "op-lost-1")
    store:flush()
    check(c.reason == "unknown_operation", "unknown after restart: " .. tostring(c.reason))
    check(store:count(CRATE, "scrap") == 4 and store:count(A, "scrap") == 0, "goods where they were")
    local r = reserve(co2, pickup("op-lost-2"))
    check(r.res ~= nil, "new VM can reserve the same goods (old holds died with the VM)")
end)

run("T7 failure before COMMIT: in doubt, fence aborts, holds released", function()
    local co, store = world()
    store.faults = { "unreachable_before" }
    reserve(co, pickup("op-net-1"))
    local c = commit(co, "op-net-1")
    store:step() -- the commit completes ambiguously, the fence is queued
    check(co:operation("op-net-1").state == "in_doubt", "in doubt, not failed")
    local blocked = reserve(co, { opId = "op-net-other", lines = { { item = "scrap", count = 1, from = CRATE, to = B } } })
    check(blocked.reason == "insufficient_items", "holds kept while in doubt")
    store:flush()
    check(c.reason == "store_unavailable" and c.info.state == "aborted", "settled aborted: " .. tostring(c.reason))
    check(store:count(CRATE, "scrap") == 4 and store.commits == 0, "nothing durable")
    local late = commit(co, "op-net-1")
    check(late.reason == "aborted", "a fenced op can never commit: " .. tostring(late.reason))
    local retry = reserve(co, { opId = "op-net-2", lines = { { item = "scrap", count = 4, from = CRATE, to = A } } })
    check(retry.res ~= nil, "goods available again")
end)

run("T8 COMMIT landed, ack lost: fence finds it, mirror applied once", function()
    local co, store = world()
    store.faults = { "lost_ack" }
    reserve(co, pickup("op-ack-1"))
    local c = commit(co, "op-ack-1")
    store:flush()
    check(c.res and c.res.state == "committed", "success reported late")
    check(store:count(A, "scrap") == 4 and store.commits == 1, "durable once")
    local snap = co:read(A)
    check(snap.items.scrap == 4 and snap.weightG == 2000, "mirror applied exactly once")
    check(co:read(CRATE).items.scrap == nil, "crate mirror empty")
end)

run("T9 fence while the database is down keeps holds, then resolves", function()
    local co, store, clock = world()
    store.faults = { "lost_ack" }
    reserve(co, pickup("op-down-1"))
    local c = commit(co, "op-down-1")
    store:step()           -- commit applied, ack lost
    store.down = true
    store:flush()          -- the fence cannot reach the database
    check(c.reason == "in_doubt", "caller told in_doubt: " .. tostring(c.reason))
    check(co:operation("op-down-1").state == "in_doubt", "still in doubt")
    -- Both mirrors are loaded, so the refusal comes from the holds, not the outage.
    local spend = reserve(co, { opId = "op-down-2", lines = { { item = "scrap", count = 1, from = CRATE, to = A } } })
    check(spend.reason == "insufficient_items", "no double spend while in doubt: " .. tostring(spend.reason))
    local cold = reserve(co, { opId = "op-down-3", lines = { { item = "scrap", count = 1, from = CRATE, to = B } } })
    check(cold.reason == "store_unavailable", "an unloaded account refuses while the database is down")
    store.down = false
    clock.t = clock.t + 2000
    co:tick()
    store:flush()
    check(co:operation("op-down-1").state == "committed", "resolved committed after recovery")
    check(co:read(A).items.scrap == 4, "mirror converged")
end)

-- ---------------------------------------------------------------------------
-- T10-T11 expiry and cancel
-- ---------------------------------------------------------------------------
run("T10 TTL expiry releases holds; a late commit is refused", function()
    local co, store, clock = world()
    reserve(co, { opId = "op-ttl-1", ttlMs = 5000, lines = pickup("x").lines })
    clock.t = clock.t + 5001
    co:tick()
    local c = commit(co, "op-ttl-1")
    check(c.reason == "expired", "expired: " .. tostring(c.reason))
    check(co:read(CRATE).held.items.scrap == nil, "holds released")
    check(store.commits == 0, "nothing submitted")
end)

run("T11 cancel releases holds; commit after cancel is refused", function()
    local co = world()
    reserve(co, pickup("op-cancel-1"))
    local ok = co:cancel("op-cancel-1", "moved_away", "c1_salvage")
    check(ok == true, "cancelled")
    local c = commit(co, "op-cancel-1")
    check(c.reason == "cancelled", "refused: " .. tostring(c.reason))
    local other = co:cancel("op-cancel-1", nil, "someone_else")
    check(other == nil, "a foreign resource cannot cancel")
end)

-- ---------------------------------------------------------------------------
-- T12 stale mirror (another server shares the database)
-- ---------------------------------------------------------------------------
run("T12 external writer drains stock: assertion conflict, mirror reloaded", function()
    local co, store = world()
    reserve(co, pickup("op-ext-1"))
    store.containers[CRATE].stacks.scrap = 1 -- another server took 3
    store.containers[CRATE].weightG = 500
    local c = commit(co, "op-ext-1")
    store:flush()
    check(c.reason == "conflict" and c.info.retryable == true, "conflict: " .. tostring(c.reason))
    check(store:count(A, "scrap") == 0 and store:count(CRATE, "scrap") == 1, "rolled back")
    check(co:read(CRATE).items.scrap == 1, "mirror reloaded from the store")
end)

-- ---------------------------------------------------------------------------
-- T13 split payout, double entry
-- ---------------------------------------------------------------------------
run("T13 split payout conserves value per asset", function()
    local co, store = world()
    store:seedContainer(CARGO, 200000, { scrap = 10 }, WEIGHTS)
    store:seedWallet(CASH_B, 0)
    local spec = {
        opId = "op-split-1", kind = "sale", actor = A,
        lines = {
            { item = "scrap", count = 10, from = CARGO, to = DEALER },
            { money = 68, from = DEALER, to = CASH_A },
            { money = 67, from = DEALER, to = CASH_B },
            { money = 15, from = DEALER, to = SOC },
        },
    }
    local t = transfer(co, spec)
    store:flush()
    check(t.res and t.res.state == "committed", "committed")
    check(store:balance(CASH_A) == 168 and store:balance(CASH_B) == 67 and store:balance(SOC) == 15, "shares exact")
    local sums = store:journalSums("op-split-1")
    check(sums.money == 0 and sums.scrap == 0, "journal sums to zero per asset")
    check(store:count(CARGO, "scrap") == 0, "sold cargo cannot reappear")
end)

-- ---------------------------------------------------------------------------
-- T14 salvage envelope: roll at completion, inside reserved capacity
-- ---------------------------------------------------------------------------
run("T14 salvage roll commits inside its capacity envelope", function()
    local co, store = world()
    store:seedContainer(A, 3000, {}, WEIGHTS)
    local r = reserve(co, { opId = "op-salvage-1", kind = "salvage",
        lines = { { capacityG = 2000, from = SALVAGE, to = A } } })
    check(r.res ~= nil, "envelope reserved")
    local blocked = reserve(co, { opId = "op-salvage-2", lines = { { capacityG = 1500, from = SALVAGE, to = A } } })
    check(blocked.reason == "capacity_exceeded", "capacity is held for the roll")
    local over = commit(co, "op-salvage-1", { lines = { { item = "scrap", count = 5, from = SALVAGE, to = A } } })
    check(over.reason == "exceeds_reservation", "2500 g does not fit 2000 g: " .. tostring(over.reason))
    local c = commit(co, "op-salvage-1", { lines = {
        { item = "scrap", count = 3, from = SALVAGE, to = A },
        { item = "chip", count = 1, from = SALVAGE, to = A },
    } })
    store:flush()
    check(c.res and c.res.state == "committed", "roll committed")
    check(store:count(A, "scrap") == 3 and store:count(A, "chip") == 1, "materials produced once")
    check(co:read(A).held.weightIn == 0, "envelope released")
end)

-- ---------------------------------------------------------------------------
-- T15 tool wear on a unique instance (CAS)
-- ---------------------------------------------------------------------------
run("T15 two operations cannot wear the same crowbar", function()
    local co, store = world()
    store:seedInstance("cb-1", "crowbar", A, { durability = 12 })
    store.containers[A].weightG = 1500
    local w1 = reserve(co, { opId = "op-wear-1", lines = { { instance = "cb-1", at = A, meta = { durability = 11 } } } })
    local w2 = reserve(co, { opId = "op-wear-2", lines = { { instance = "cb-1", at = A, meta = { durability = 11 } } } })
    check(w1.res ~= nil and w2.reason == "instance_unavailable", "second refused while held")
    commit(co, "op-wear-1")
    store:flush()
    check(store.instances["cb-1"].meta.durability == 11 and store.instances["cb-1"].version == 2, "wear persisted")
    store.instances["cb-1"].version = 7 -- changed by another writer
    reserve(co, { opId = "op-wear-3", lines = { { instance = "cb-1", at = A, meta = { durability = 10 } } } })
    local c = commit(co, "op-wear-3")
    store:flush()
    check(c.reason == "conflict", "version CAS refused: " .. tostring(c.reason))
end)

-- ---------------------------------------------------------------------------
-- T16 caller resource stops
-- ---------------------------------------------------------------------------
run("T16 caller stop cancels its reservations, not committing operations", function()
    local co, store = world()
    store:seedContainer(A, 40000, { scrap = 4 }, WEIGHTS)
    reserve(co, pickup("op-stop-1", 2), "rp_inventory")
    reserve(co, saleSpec("op-stop-2"), "rp_inventory")
    local c = commit(co, "op-stop-2", nil, "rp_inventory")
    local cancelled = co:onResourceStop("rp_inventory")
    check(cancelled == 1, "one reservation cancelled, got " .. tostring(cancelled))
    store:flush()
    check(c.res and c.res.state == "committed", "the committing sale finished")
    check(co:operation("op-stop-1").reason == "resource_stopped", "reason recorded")
end)

-- ---------------------------------------------------------------------------
-- T17-T18 limits and validation
-- ---------------------------------------------------------------------------
run("T17 an operation over the statement budget is refused before submission", function()
    local co, store = world()
    local items, lines = {}, {}
    for i = 1, 40 do
        local id = string.format("part_%02d", i)
        items[id] = { weightG = 1 }
        lines[#lines + 1] = { item = id, count = 1, from = A, to = DEALER }
    end
    co:define(items, "rp_inventory")
    local stacks, grams = {}, {}
    for id in pairs(items) do stacks[id] = 1; grams[id] = 1 end
    store:seedContainer(A, 40000, stacks, grams)
    local t = transfer(co, { opId = "op-big-1", lines = lines })
    check(t.reason == "operation_too_large", "refused: " .. tostring(t.reason))
    check(store.commits == 0 and store:pending() == 0, "nothing submitted")
end)

run("T18 validation gives typed refusals", function()
    local co = world()
    check(reserve(co, { opId = "short", lines = pickup("x").lines }).reason == "invalid_op_id", "short opId")
    check(reserve(co, { opId = "op-valid-1", lines = {} }).reason == "invalid_spec", "no lines")
    check(reserve(co, { opId = "op-valid-2", lines = { { item = "Scrap!", count = 1, from = CRATE, to = A } } }).reason
        == "unknown_item", "bad item id")
    check(reserve(co, { opId = "op-valid-3", lines = { { item = "scrap", count = 0, from = CRATE, to = A } } }).reason
        == "invalid_count", "zero count")
    check(reserve(co, { opId = "op-valid-4", lines = { { money = 1.5, from = CASH_A, to = SOC } } }).reason
        == "invalid_amount", "fractional money")
    check(reserve(co, { opId = "op-valid-5", lines = { { item = "scrap", count = 1, from = CASH_A, to = A } } }).reason
        == "invalid_account", "item from a wallet")
    check(reserve(co, { opId = "op-valid-6", lines = { { item = "gold", count = 1, from = CRATE, to = A } } }).reason
        == "unknown_item", "undefined item")
    check(reserve(co, { opId = "op-valid-7", lines = { { item = "scrap", count = 1, from = CRATE, to = "stash:nowhere" } } }).reason
        == "unknown_account", "unopened container")
    check(reserve(co, { opId = "op-valid-8", lines = { { money = 500, from = CASH_A, to = SOC } } }).reason
        == "insufficient_funds", "overdraft")
end)

run("T18b durable-key lint refuses session and runtime ids", function()
    local co = world()
    check(reserve(co, { opId = "op-keys-1", lines = { { money = 1, from = DEALER, to = "cash:12" } } }).reason
        == "invalid_key", "a session id is not an owner key")
    check(reserve(co, { opId = "op-keys-2", lines = { { item = "scrap", count = 1, from = CRATE, to = "veh:4711:cargo" } } }).reason
        == "invalid_key", "a runtime vehicle id is not a plate")
    check(M.durableKeyProblem("char:session-12") == "session_key", "session: fallback refused")
    check(M.durableKeyProblem("veh:NC-1234:cargo") == nil, "a plate is durable")
end)

-- ---------------------------------------------------------------------------
-- T19-T20 concurrency on one coordinator
-- ---------------------------------------------------------------------------
run("T19 two in-flight commits on one society wallet both land", function()
    local co, store = world()
    store:seedContainer(A, 40000, { scrap = 8 }, WEIGHTS)
    reserve(co, { opId = "op-soc-1", lines = { { item = "scrap", count = 4, from = A, to = DEALER },
        { money = 10, from = DEALER, to = SOC } } })
    reserve(co, { opId = "op-soc-2", lines = { { item = "scrap", count = 4, from = A, to = DEALER },
        { money = 7, from = DEALER, to = SOC } } })
    local c1, c2 = commit(co, "op-soc-1"), commit(co, "op-soc-2")
    check(store:pending() == 2, "both submitted before either answered")
    store:flush()
    check(c1.res and c2.res, "both committed")
    check(store:balance(SOC) == 17 and co:read(SOC).balance == 17, "store and mirror agree")
end)

run("T20 a second commit call while committing is busy, then replays", function()
    local co, store = world()
    reserve(co, pickup("op-busy-1"))
    local first = commit(co, "op-busy-1")
    local second = commit(co, "op-busy-1")
    check(second.reason == "busy" and second.info.retryable == true, "busy: " .. tostring(second.reason))
    store:flush()
    check(first.res ~= nil and store.commits == 1, "one submission")
    check(commit(co, "op-busy-1").res.replay == true, "later call replays")
end)

-- ---------------------------------------------------------------------------
-- Beyond the list: properties B8 asked for
-- ---------------------------------------------------------------------------
run("refund to a disconnected player: durable keys need no session", function()
    local co, store = world()
    -- No session, no "loaded player": the wallet is credited by its durable key.
    local t = transfer(co, { opId = "op-refund-1", kind = "refund",
        lines = { { money = 250, from = "sys:shop", to = "cash:acct-offline" } } })
    store:flush()
    check(t.res and t.res.state == "committed", "credited")
    check(store:balance("cash:acct-offline") == 250, "wallet row created on credit")
end)

run("item definitions: a collision between definers is refused, not last-writer-wins", function()
    local co = world()
    local registered, rejected, collisions = co:define({ scrap = { weightG = 9999 } }, "rp_other")
    check(registered == 0 and rejected == 1 and collisions[1] == "scrap", "collision reported")
    local r2 = co:define({ scrap = { weightG = 500 } }, "rp_inventory")
    check(r2 == 1, "the owner may re-define (restart handshake)")
end)

run("refused submission is definitive: no fence, holds released", function()
    local co, store = world()
    store.faults = { "refused" }
    reserve(co, pickup("op-ref-1"))
    local c = commit(co, "op-ref-1")
    store:flush()
    check(c.reason == "store_unavailable" and co:operation("op-ref-1").state == "failed", "failed definitively")
    check(store.ops["op-ref-1"] == nil, "no tombstone written")
    check(reserve(co, pickup("op-ref-2")).res ~= nil, "goods available again")
end)

run("status(resolve) fences an op a previous VM may still be committing", function()
    local co, store = world()
    reserve(co, pickup("op-res-1"))
    commit(co, "op-res-1")
    -- The VM restarts before the queued transaction runs; a new VM fences first.
    local co2 = world({ store = store })
    local box, cb = capture()
    co2:status("op-res-1", { resolve = true }, cb)
    -- The fence is queued behind the old VM's transaction, which still runs
    -- (DatabaseService.cs:262-266) but whose completion nobody hears.
    store:stepDetached()
    store:flush()
    check(box.res ~= nil and box.res.state == "committed", "the earlier commit won: " .. tostring(box.res and box.res.state))
    local co3 = world({ store = store })
    local box2, cb2 = capture()
    co3:status("op-never", { resolve = true }, cb2)
    store:flush()
    check(box2.res and box2.res.state == "aborted", "an unknown op is fenced aborted")
end)

-- ---------------------------------------------------------------------------
-- Result contract
-- ---------------------------------------------------------------------------
TestResult = { passed = passed, failed = #failures, failures = failures }
TestSummary = string.format("passed=%d failed=%d", passed, #failures)
    .. (#failures > 0 and ("\n" .. table.concat(failures, "\n")) or "")
print(string.format("[open77_transactions coordinator tests] %d passed, %d failed", passed, #failures))
for _, f in ipairs(failures) do print("  FAIL: " .. f) end
