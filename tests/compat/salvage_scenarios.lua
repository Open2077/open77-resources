-- tests/compat/salvage_scenarios.lua: the C1 salvage pilot (rp_salvage) end to end, offline.
--
-- Loaded by tests/test_c1_salvage.py after fakehost.lua (unused here) with the string globals
-- ROOT_DIR, COMPAT_DIR, SYS_DIR and TX_DIR (salvage_world.lua). Players act the way the
-- open77_actions client makes them act: prompt intents and the put-down key, as net events from
-- their own seat. Every check reads durable truth from the coordinator's store.

dofile(COMPAT_DIR .. "/salvage_world.lua")

local scenarios = {}

local A, B = "acct-a", "acct-b"
local AT_NODE = { x = 1368.0, y = -1689.4, z = 49.4 }      -- 1.4 m from the Burnt-out Thorton
local AT_NODE_B = { x = 1369.2, y = -1689.8, z = 49.4 }    -- beside the same wreck
local AT_FOREMAN = { x = 1374.0, y = -1670.5, z = 49.4 }
local LOAD_BAY = { x = 1378.0, y = -1671.0, z = 49.4 }
local TRUCK_AT_LOAD = { x = 1378.0, y = -1674.0, z = 49.4 }
local UNLOAD_BAY = { x = 1373.0, y = -1678.5, z = 49.4 }
local TRUCK_AT_UNLOAD = { x = 1373.0, y = -1681.0, z = 49.4 }
local COUNTER = { x = 1374.9, y = -1684.4, z = 49.4 }
local TRUCK = 501
local PLATE = "NC-SLV01"
local NODE_T = "rp_salvage:node_thorton"

local function setup(pid, identifier, position, tools)
    SW.join(pid, identifier, "player" .. pid, position or AT_NODE)
    SW.command("salvage.lab.setup", { tostring(pid), tools or "both" })
    MH.run(3)
end

local function svc() return SW.salvage() end

local function crateOf(identifier)
    for _, crate in pairs(svc().crates) do
        if crate.meta and crate.meta.owner == identifier and crate.state ~= "sold" then return crate end
    end
    return nil
end

local function work(pid, action, target)
    return SW.act(pid, "rp_salvage:" .. (action or "cut"), target or NODE_T, action or "cut", 30)
end

local function pickup(pid, crate)
    SW.intent(pid, "open77_actions:carry_pickup", "item:" .. tostring(crate.itemId))
    MH.until_(function() return SW.carrying(pid) ~= nil end, 10)
    MH.run(0.5)
    return SW.carrying(pid)
end

local function putdownAt(pid, targetKey)
    return SW.act(pid, "open77_actions:carry_putdown", targetKey, "carry_putdown", 30)
end

local function materialsIn(account)
    return SW.count(account, "scrap_metal") * 1 + SW.count(account, "copper_wire") * 1 + SW.count(account, "chip")
end

-- Minted materials (out of sys:salvage) minus sold ones (into the buyer's sys account) = what the
-- holds still contain: nothing created or lost anywhere else.
local function materialsConserved()
    local minted, sold, held = 0, 0, 0
    for _, item in ipairs({ "scrap_metal", "copper_wire", "chip" }) do
        minted = minted - SW.journal("^sys:salvage$", item)
        sold = sold + SW.journal("^sys:rp_salvage:dealer$", item)
        for _, hold in ipairs(SW.holdsOf(nil)) do held = held + SW.count(hold, item) end
    end
    return minted == sold + held, ("minted=%d sold=%d held=%d"):format(minted, sold, held)
end

-- ---------------------------------------------------------------------------------------------
-- Happy path: clock in, cut twice and pry once into one crate, carry, load (strict writers: the
-- two-party grants carry rp_cargo and rp_economy into the hold), drive, unload, sell.
-- ---------------------------------------------------------------------------------------------
-- The five start lines of rp_salvage/README.md section 1, counted from log line `from` on.
local function bootLines(created, from)
    local out = {}
    for _, pattern in ipairs({ "coordinator ready %(store=", "items defined through rp_inventory: 5",
        "5 wreck node%(s%) ready %(" .. created .. " created%)", "crates rebuilt from the coordinator: ",
        "ready: 5 wreck nodes, foreman, loading bay, unloading bay, buyer counter %(job ferrailleur%)" }) do
        local n = 0
        for index = (from or 1), #MH.logs do
            local line = MH.logs[index]
            if line:find("^%[rp_salvage%]") and line:find(pattern) then n = n + 1 end
        end
        out[#out + 1] = tostring(n)
    end
    return table.concat(out, "/")
end

function scenarios.happy_path()
    SW.boot({ writers = SW.WRITERS_STRICT })
    local startLines = bootLines(5)
    local nodeWarnings = SW.printed("unavailable") + SW.printed("not created")
    SW.watch()
    SW.join(1, A, "Vik", AT_FOREMAN)
    SW.sync("salvage_probe", "rp_jobs", "setJob", 1, "ferrailleur", 0)
    -- Clock in at the foreman, through the prompt.
    local clock = SW.act(1, "rp_salvage:clock_in", "rp_salvage:foreman", "clock_in")
    local tools = MH.callAsync("salvage_probe", "rp_inventory", "addAsync", 1, "welder", 1, nil, { opId = "lab.tool.w1" })
    local tools2 = MH.callAsync("salvage_probe", "rp_inventory", "addAsync", 1, "crowbar", 1, nil, { opId = "lab.tool.c1" })
    SW.move(1, AT_NODE)
    local w1 = work(1, "cut")
    local crate = crateOf(A)
    local w2 = work(1, "cut")
    local w3 = work(1, "pry")
    local hold = crate and crate.id
    local afterWork = { scrap = SW.count(hold, "scrap_metal"), wire = SW.count(hold, "copper_wire"), chip = SW.count(hold, "chip") }
    -- "Check the haul" reads the crate (no value moves); the pry showed a hand prop (the fire axe
    -- stands in for the missing tool.crowbar alias) and removed it.
    local inspect = SW.act(1, "rp_salvage:inspect", NODE_T, "inspect")
    local handProps, handLeft = {}, 0
    for _, c in ipairs(MH.shared.world.created) do
        if c.owner == "rp_salvage" and c.model ~= nil then handProps[#handProps + 1] = c.model end
    end
    for _, p in pairs(MH.shared.world.props) do if p.owner == "rp_salvage" then handLeft = handLeft + 1 end end
    local scavenged = false
    for _, e in ipairs(MH.shared.world.played) do if e.pid == 1 and e.profile == "scavenge" then scavenged = true end end
    local tokenHome = (SW.store().instances[crate.iid] or {}).container
    -- Carry it to the loading bay and load it on A's truck.
    SW.truck(TRUCK, PLATE, A, TRUCK_AT_LOAD)
    local carried = pickup(1, crate)
    SW.move(1, LOAD_BAY)
    local load = putdownAt(1, "rp_salvage:load_bay")
    local tokenInBed = (SW.store().instances[crate.iid] or {}).container
    local bedProps = 0
    for _, p in pairs(MH.shared.world.props) do
        if p.owner == "rp_cargo" and p.attachment and p.attachment.parentType == "vehicle" then bedProps = bedProps + 1 end
    end
    -- Drive to the buyer, unload at the bay (the crate lands in A's hands), sell at the counter.
    local v = MH.shared.world.vehicles[TRUCK]
    v.x, v.y, v.z = TRUCK_AT_UNLOAD.x, TRUCK_AT_UNLOAD.y, TRUCK_AT_UNLOAD.z
    SW.move(1, UNLOAD_BAY)
    local unload = SW.act(1, "rp_salvage:unload", "rp_salvage:unload_bay", "unload")
    MH.until_(function() return SW.carrying(1) ~= nil end, 10)
    local carriedAgain = SW.carrying(1) ~= nil
    local tokenBack = (SW.store().instances[crate.iid] or {}).container
    SW.move(1, COUNTER)
    local cashBefore = SW.balance("cash:" .. A)
    local sale = putdownAt(1, "rp_salvage:sell_counter")
    MH.run(3)
    -- Clock out; a player with no yard job is refused at the foreman, with the reason.
    SW.move(1, AT_FOREMAN)
    local out = SW.act(1, "rp_salvage:clock_out", "rp_salvage:foreman", "clock_out")
    local offDuty = select(2, SW.sync("salvage_probe", "rp_jobs", "eligible", 1, { job = "ferrailleur", duty = true }))
    SW.join(2, B, "Civ", AT_FOREMAN)
    local civ = SW.act(2, "rp_salvage:clock_in", "rp_salvage:foreman", "clock_in")
    local expected = afterWork.scrap * 18 + afterWork.wire * 40 + afterWork.chip * 150
    local society = math.floor(expected * 0.10)
    local ok, detail = materialsConserved()
    return SW.result({
        boot_lines = startLines, node_warnings = nodeWarnings,
        clock = clock and clock.state, tools = tostring(tools and "ok") .. "/" .. tostring(tools2 and "ok"),
        w1 = w1 and w1.state, w2 = w2 and w2.state, w3 = w3 and w3.state,
        crate_hold = hold ~= nil, token_home = tokenHome == hold,
        scrap = afterWork.scrap, wire = afterWork.wire,
        welder = SW.toolDurability("char:" .. A, "welder"), crowbar = SW.toolDurability("char:" .. A, "crowbar"),
        carried = carried ~= nil, load = load and load.state, load_reason = load and load.reason,
        token_in_bed = tokenInBed == ("veh:" .. PLATE .. ":cargo"), bed_props = bedProps,
        unload = unload and unload.state, carried_again = carriedAgain, token_back = tokenBack == hold,
        sale = sale and sale.state, sale_reason = sale and sale.reason,
        paid = SW.balance("cash:" .. A) - cashBefore, expected_seller = expected - society,
        society = SW.balance("soc:ferrailleur"), expected_society = society,
        hold_closed = SW.store().containers[hold] == nil,
        token_retired = (SW.store().instances[crate.iid] or {}).container == "sys:salvage",
        conserved = ok, conservation = detail, unbalanced = tostring(SW.unbalanced()),
        node_charges = (SW.sync("salvage_probe", "open77_containers", "summary", svc().nodes.thorton.id) or {}).charges,
        inspect = inspect and inspect.state, told_haul = SW.told(1, "Your crate:"),
        hand_props = table.concat(handProps, ","), hand_props_left = handLeft, scavenged = scavenged,
        buyer_npcs = (function() local n = 0 for _ in pairs(MH.shared.world.npcs) do n = n + 1 end return n end)(),
        clock_out = out and out.state, off_duty = tostring(offDuty),
        civ = civ and civ.state, civ_reason = civ and civ.reason, told_civ = SW.told(2, "employment agency"),
    })
end

-- ---------------------------------------------------------------------------------------------
-- The integrator's console path: every step of the loop from salvage.lab.* commands with explicit
-- player ids (no prompt aiming), then the state print, a node reset, the truck command.
-- ---------------------------------------------------------------------------------------------
function scenarios.lab_console()
    SW.boot()
    SW.watch()
    SW.join(1, A, "Vik", AT_NODE)
    SW.command("salvage.lab.setup", { "1", "both" })
    MH.run(3)
    SW.truck(TRUCK, PLATE, A, TRUCK_AT_LOAD)
    local mark = SW.mark()
    SW.command("salvage.lab.work", { "1", "thorton", "cut" })
    local w = SW.finish(1, "cut", 30, mark)
    SW.command("salvage.lab.pickup", { "1" })
    MH.until_(function() return SW.carrying(1) ~= nil end, 10)
    local picked = SW.carrying(1) ~= nil
    SW.move(1, LOAD_BAY)
    mark = SW.mark()
    SW.command("salvage.lab.load", { "1" })
    local load = SW.finish(1, "carry_putdown", 30, mark)
    local v = MH.shared.world.vehicles[TRUCK]
    v.x, v.y, v.z = TRUCK_AT_UNLOAD.x, TRUCK_AT_UNLOAD.y, TRUCK_AT_UNLOAD.z
    SW.move(1, UNLOAD_BAY)
    SW.command("salvage.lab.unload", { "1" })
    MH.until_(function() return SW.carrying(1) ~= nil end, 10)
    local unloaded = SW.carrying(1) ~= nil
    SW.move(1, COUNTER)
    mark = SW.mark()
    SW.command("salvage.lab.sell", { "1" })
    local sale = SW.finish(1, "carry_putdown", 30, mark)
    SW.command("salvage.lab.state", { "1" })
    MH.run(3)
    SW.command("salvage.status", {})
    local nodeBefore = svc().nodes.thorton.id
    local chargesBefore = (SW.sync("salvage_probe", "open77_containers", "summary", nodeBefore) or {}).charges
    SW.command("salvage.lab.reset", { "thorton" })
    MH.run(3)
    SW.command("salvage.lab.truck", { "1" })
    SW.command("salvage.lab.clock", { "1", "off" })
    MH.run(1)
    return SW.result({
        w = w and w.state, picked = picked, load = load and load.state, unloaded = unloaded,
        sale = sale and sale.state,
        state_tool = SW.printed("tool welder .* durability=29"), state_cash = SW.printed("cash=%d+ society ferrailleur=%d+"),
        state_receipt = SW.printed("receipt sale slv%.sale:"), status = SW.printed("ready=true crates:"),
        -- refill in place (A6-2): same node id, back to 3/3 from the 2 the work left
        reset = SW.printed("node thorton: refilled world:%S+ to 3/3"), charges_before_reset = chargesBefore,
        same_node = svc().nodes.thorton.id == nodeBefore,
        charges = (SW.sync("salvage_probe", "open77_containers", "summary", svc().nodes.thorton.id) or {}).charges,
        truck_hint = SW.printed("no lab issue export yet"), clock = SW.printed("duty 1 off: true"),
    })
end

-- Positions next to the other wrecks used below.
local AT_QUADRA = { x = 1371.6, y = -1689.4, z = 49.4 }
local AT_ARCHER = { x = 1381.0, y = -1689.4, z = 49.4 }
local NEAR_CRATE_B = { x = 1369.6, y = -1688.6, z = 49.4 }

local function committedWorks()
    local n = 0
    for _, row in pairs(SW.store().ops) do
        if row.state == "committed" and type(row.receipt) == "table" and row.receipt.kind == "salvage.work" then n = n + 1 end
    end
    return n
end

local function charges(key)
    local summary = SW.sync("salvage_probe", "open77_containers", "summary", svc().nodes[key].id)
    return summary and summary.charges
end

local function carryingCrate(pid)
    local item = SW.carrying(pid)
    return item and item.data and item.data.container or nil
end

local function waitState(pid, actionId, mark, state, seconds)
    return MH.until_(function()
        local op = SW.lastOp(pid, actionId, mark)
        return op ~= nil and op.state == state
    end, seconds or 15)
end

-- ---------------------------------------------------------------------------------------------
-- Contention: two players claim one wreck in the same pass (one winner, the other refused before
-- anything is held), pick up one crate at once (one carrier), load one truck at once (served in
-- turn, distinct slots).
-- ---------------------------------------------------------------------------------------------
function scenarios.contention()
    SW.boot()
    SW.watch()
    setup(1, A, AT_NODE)
    setup(2, B, AT_NODE_B)
    local mark = SW.mark()
    SW.intent(1, "rp_salvage:cut", NODE_T)
    SW.intent(2, "rp_salvage:cut", NODE_T)
    local opA = SW.finish(1, "cut", 30, mark)
    local opB = SW.lastOp(2, "cut", mark)
    local refusedB = table.concat(SW.refusals(2), ",")
    local crate = crateOf(A)
    -- One crate, two hands.
    SW.move(2, NEAR_CRATE_B)
    SW.intent(1, "open77_actions:carry_pickup", "item:" .. crate.itemId)
    SW.intent(2, "open77_actions:carry_pickup", "item:" .. crate.itemId)
    MH.until_(function() return SW.carrying(1) ~= nil or SW.carrying(2) ~= nil end, 10)
    MH.run(1)
    local carriedBy = (SW.carrying(1) and "A" or "") .. (SW.carrying(2) and "B" or "")
    local pickupRefusals = table.concat(SW.refusals(2), ",")
    -- B gets his own crate at another wreck, then both load A's truck (B holds a key) at once.
    SW.move(2, AT_QUADRA)
    local wB = work(2, "cut", "rp_salvage:node_quadra")
    local crateB = crateOf(B)
    pickup(2, crateB)
    SW.truck(TRUCK, PLATE, A, TRUCK_AT_LOAD, { [B] = true })
    SW.move(1, LOAD_BAY)
    SW.move(2, { x = LOAD_BAY.x + 0.8, y = LOAD_BAY.y, z = LOAD_BAY.z })
    -- The bay is one target: a second put-down on it in the same pass is refused (target_claimed).
    local mark3 = SW.mark()
    SW.intent(1, "open77_actions:carry_putdown", "rp_salvage:load_bay")
    SW.intent(2, "open77_actions:carry_putdown", "rp_salvage:load_bay")
    local l1 = SW.finish(1, "carry_putdown", 30, mark3)
    local bayRefusal = SW.refusals(2)[#SW.refusals(2)]
    local bayOpB = SW.lastOp(2, "carry_putdown", mark3)
    -- Two loads onto one truck at once without a shared target (/salvage load next to the truck):
    -- rp_cargo serves them in turn, each into its own slot.
    SW.move(1, AT_NODE)
    work(1, "cut")
    local second
    for _, c in pairs(svc().crates) do if c.meta.owner == A and c.state == "ground" then second = c end end
    pickup(1, second)
    SW.move(1, LOAD_BAY)
    local mark4 = SW.mark()
    MH.command("salvage", 1, { "load" })
    MH.command("salvage", 2, { "load" })
    local l1b = SW.finish(1, "carry_putdown", 30, mark4)
    local l2 = SW.finish(2, "carry_putdown", 30, mark4)
    local slots = {}
    for _, inst in ipairs(SW.instancesOf("salvage_crate")) do
        if inst.container == "veh:" .. PLATE .. ":cargo" then
            slots[#slots + 1] = tostring(inst.meta and inst.meta.cargo and inst.meta.cargo.slot)
        end
    end
    table.sort(slots)
    local ok, detail = materialsConserved()
    return SW.result({
        a = opA and opA.state, b_op = opB and opB.state or "none", b_refused = refusedB,
        charges = charges("thorton"), b_holds_at_thorton = #SW.holdsOf(B) - (crateB and 1 or 0),
        carried_by = carriedBy, pickup_refused = pickupRefusals,
        wb = wB and wB.state, l1 = l1 and l1.state, bay_b = bayOpB and bayOpB.state or tostring(bayRefusal),
        l1b = l1b and l1b.state, l2 = l2 and l2.state, slots = table.concat(slots, ","),
        conserved = ok, conservation = detail, unbalanced = tostring(SW.unbalanced()),
    })
end

-- ---------------------------------------------------------------------------------------------
-- A full crate refuses before the work starts: the coordinator's capacity check at reserve; no
-- bar, no wear, no charge.
-- ---------------------------------------------------------------------------------------------
function scenarios.full_crate()
    SW.boot({ mint = SW.MINT_RULES .. "; salvage_probe sys:* * 100000" })
    SW.watch()
    setup(1, A, AT_NODE)
    local w1 = work(1, "cut")
    local crate = crateOf(A)
    local weightBefore = SW.store().containers[crate.id].weightG
    local seed = math.max(1, (12000 - weightBefore) // 1000)
    local seeded, seedWhy = MH.callAsync("salvage_probe", "open77_transactions", "transfer", {
        opId = "lab.seed.full.1", kind = "lab.seed",
        lines = { { item = "scrap_metal", count = seed, from = "sys:lab", to = crate.id } },
    })
    MH.run(1)
    local durability = SW.toolDurability("char:" .. A, "welder")
    local chargesBefore = charges("thorton")
    local scrapBefore = SW.count(crate.id, "scrap_metal")
    local mark = SW.mark()
    SW.intent(1, "rp_salvage:cut", NODE_T)
    local op = SW.finish(1, "cut", 30, mark)
    local presented = false
    for i = mark + 1, #MH.shared.transitions do
        local t = MH.shared.transitions[i]
        if t.playerId == 1 and t.opId == (op and op.opId) and t.state == "presenting" then presented = true end
    end
    local op2 = SW.act(1, "rp_salvage:pry", NODE_T, "pry")
    return SW.result({
        w1 = w1 and w1.state, seeded = seeded and "ok" or tostring(seedWhy), weight = SW.store().containers[crate.id].weightG,
        state = op and op.state, reason = op and op.reason, stage = op and op.stage, presented = presented,
        pry_state = op2 and op2.state, pry_reason = op2 and op2.reason,
        durability_kept = SW.toolDurability("char:" .. A, "welder") == durability,
        crowbar = SW.toolDurability("char:" .. A, "crowbar"),
        charges_kept = charges("thorton") == chargesBefore,
        scrap_kept = SW.count(crate.id, "scrap_metal") == scrapBefore,
        holds = #SW.holdsOf(A), told_full = SW.told(1, "crate here is full"),
    })
end

-- ---------------------------------------------------------------------------------------------
-- Crash windows of the work commit (A13 section 5): nothing granted when the store never got the
-- commit, granted exactly once when it landed and the acknowledgement was lost, and the same
-- two outcomes when the coordinator dies with the commit queued (detached / discarded), settled
-- through the fence once it is back. Materials, tool wear and node charges agree every time.
-- ---------------------------------------------------------------------------------------------
local function workWithFault(pid, fault)
    local mark = SW.mark()
    SW.intent(pid, "rp_salvage:cut", NODE_T)
    waitState(pid, "cut", mark, "presenting", 15)
    SW.store().faults = { fault }
    return SW.finish(pid, "cut", 40, mark)
end

local function workWithCrash(pid, mode)
    local mark = SW.mark()
    SW.intent(pid, "rp_salvage:cut", NODE_T)
    waitState(pid, "cut", mark, "presenting", 15)
    MH.shared.txPaused = true
    waitState(pid, "cut", mark, "committing", 15)
    MH.until_(function() return SW.store():pending() > 0 end, 10)
    MH.shared.txOnStop = mode
    MH.stop("open77_transactions")
    local op = SW.finish(pid, "cut", 40, mark)
    MH.shared.txPaused = false
    MH.shared.txOnStop = nil
    SW.startCoordinator()
    MH.run(12)        -- the coordinator boots, rp_salvage's sweep settles the doubt
    return op
end

-- The coordinator is gone BEFORE the commit is submitted (stopped while the bar runs): every
-- attempt is refused at dispatch, so nothing can have landed. open77_actions retries with the same
-- op id, then the action FAILS with `coordinator_unavailable` (B5-3), never in doubt.
local function workCoordinatorGone(pid)
    local mark = SW.mark()
    SW.intent(pid, "rp_salvage:cut", NODE_T)
    waitState(pid, "cut", mark, "presenting", 15)
    MH.stop("open77_transactions")
    local op = SW.finish(pid, "cut", 40, mark)
    SW.startCoordinator()
    MH.run(12)
    return op
end

local function tally()
    local inHolds, minted = 0, 0
    for _, hold in ipairs(SW.holdsOf(A)) do
        for _, item in ipairs({ "scrap_metal", "copper_wire", "chip" }) do inHolds = inHolds + SW.count(hold, item) end
    end
    for _, item in ipairs({ "scrap_metal", "copper_wire", "chip" }) do minted = minted - SW.journal("^sys:salvage$", item) end
    local works = committedWorks()
    return {
        works = works, minted = minted, inHolds = inHolds,
        wear = 30 - (SW.toolDurability("char:" .. A, "welder") or 0),
        spent = 3 - (charges("thorton") or 0),
    }
end

local function agree(t) return t.minted == t.inHolds and t.wear == t.works and t.spent == t.works end

function scenarios.crash_windows()
    SW.boot()
    SW.watch()
    setup(1, A, AT_NODE)
    -- 1. The store never received the commit (unreachable before COMMIT): fenced, nothing granted.
    local o1 = workWithFault(1, "unreachable_before")
    MH.run(6)
    local t1 = tally()
    -- 2. The commit landed, the acknowledgement was lost: the fence finds it, granted once.
    local o2 = workWithFault(1, "lost_ack")
    MH.run(6)
    local t2 = tally()
    -- 3. The coordinator VM stops with the commit queued; it still lands (detached, D6).
    local o3 = workWithCrash(1, "detached")
    local t3 = tally()
    local doubtsLeft = 0
    for _ in pairs(svc().doubts) do doubtsLeft = doubtsLeft + 1 end
    -- 4. Same, but the queued commit never reached the database (discarded): fenced, nothing.
    local works3, wear3 = committedWorks(), t3.wear
    local spent3 = t3.spent
    local o4 = workWithCrash(1, "discard")
    local t4 = tally()
    -- 5. The coordinator is unreachable before the commit: failed, nothing granted, player told.
    local works4 = committedWorks()
    local o5 = workCoordinatorGone(1)
    local t5 = tally()
    local crate = crateOf(A)
    return SW.result({
        o1 = o1 and o1.state, o1_reason = o1 and o1.reason, t1_works = t1.works, t1_agree = agree(t1),
        o2 = o2 and o2.state, t2_works = t2.works, t2_agree = agree(t2),
        o3 = o3 and o3.state, t3_works = t3.works, t3_agree = agree(t3), doubts_left = doubtsLeft,
        o4 = o4 and o4.state, t4_works = t4.works, works_unchanged_4 = t4.works == works3,
        t4_agree = agree(t4), t4_wear_unchanged = t4.wear == wear3, t4_spent_unchanged = t4.spent == spent3,
        o5 = o5 and o5.state, o5_reason = o5 and o5.reason, works_unchanged_5 = t5.works == works4,
        t5_agree = agree(t5), t5_wear_unchanged = t5.wear == t4.wear, t5_spent_unchanged = t5.spent == t4.spent,
        doubts_after_5 = (function() local n = 0 for _ in pairs(svc().doubts) do n = n + 1 end return n end)(),
        told_offline = SW.told(1, "ledger is offline"),
        crate_placed = crate ~= nil and crate.itemId ~= nil, items = SW.items(),
        unbalanced = tostring(SW.unbalanced()),
    })
end

-- ---------------------------------------------------------------------------------------------
-- A replayed sale pays once: the same request again returns the stored receipt; and a sale that
-- committed just before a crash (its crate not retired yet) is found at boot: the crate never
-- comes back.
-- ---------------------------------------------------------------------------------------------
function scenarios.replayed_sale()
    SW.boot()
    SW.watch()
    setup(1, A, AT_NODE)
    local P = svc().P
    local lastSpec
    local realSale = P.economy.sale
    P.economy.sale = function(spec) lastSpec = spec return realSale(spec) end
    work(1, "cut")
    local crate = crateOf(A)
    pickup(1, crate)
    SW.move(1, COUNTER)
    local cash0 = SW.balance("cash:" .. A)
    local s1 = putdownAt(1, "rp_salvage:sell_counter")
    MH.run(2)
    local cash1 = SW.balance("cash:" .. A)
    local soc1 = SW.balance("soc:ferrailleur")
    -- The same request, again (a retry, a double press reaching the wallet twice).
    local again, againWhy = MH.callAsync("rp_salvage", "rp_economy", "sale", lastSpec)
    MH.run(2)
    local cash2 = SW.balance("cash:" .. A)
    -- After an rp_economy restart its memory is gone: the coordinator answers from the op row.
    MH.stop("rp_economy")
    SW.startEconomy()
    MH.run(4)
    local again2, again2Why = MH.callAsync("rp_salvage", "rp_economy", "sale", lastSpec)
    MH.run(2)
    local cash3 = SW.balance("cash:" .. A)
    -- A second crate: its sale commits, the retire that follows does not reach the store, and the
    -- server dies before the sweep retries it.
    SW.move(1, AT_NODE)
    work(1, "cut")
    local crate2 = crateOf(A)
    pickup(1, crate2)
    SW.move(1, COUNTER)
    SW.store().faults = { false, "unreachable_before" }
    local s2 = putdownAt(1, "rp_salvage:sell_counter")
    local cash4 = SW.balance("cash:" .. A)
    local retirePending = svc().crates[crate2.id] and svc().crates[crate2.id].retirePending == true
    local keep = SW.keep()
    SW.boot({ keep = keep })
    SW.watch()
    SW.join(1, A, "Vik", COUNTER)
    MH.run(8)
    return SW.result({
        s1 = s1 and s1.state, paid1 = cash1 - cash0, soc1 = soc1, told_sold = SW.told(1, "Sold to Rusty"),
        again_replay = type(again) == "table" and again.replay == true or tostring(againWhy), paid2 = cash2 - cash1,
        again2 = type(again2) == "table" and ("replay=" .. tostring(again2.replay)) or tostring(again2Why),
        paid3 = cash3 - cash2,
        s2 = s2 and s2.state, retire_pending = retirePending, paid4 = cash4 - cash3,
        cash_after_restart = SW.balance("cash:" .. A) == cash4,
        crate2_known = svc().crates[crate2.id] ~= nil, crate2_hold = SW.store().containers[crate2.id] ~= nil,
        crate2_items = SW.items(crate2.id),
        unbalanced = tostring(SW.unbalanced()),
    })
end

-- ---------------------------------------------------------------------------------------------
-- Server restart with one crate on the ground, one in hands and one in a bed: each comes back
-- once, where its durable record says, and all three sell afterwards.
-- ---------------------------------------------------------------------------------------------
function scenarios.restart()
    SW.boot()
    SW.watch()
    setup(1, A, AT_NODE)
    SW.truck(TRUCK, PLATE, A, TRUCK_AT_LOAD)
    work(1, "cut")
    local ground = crateOf(A)
    SW.move(1, AT_QUADRA)
    work(1, "cut", "rp_salvage:node_quadra")
    local bed
    for _, c in pairs(svc().crates) do if c.meta.node == "quadra" then bed = c end end
    pickup(1, bed)
    SW.move(1, LOAD_BAY)
    local load = putdownAt(1, "rp_salvage:load_bay")
    SW.move(1, AT_ARCHER)
    work(1, "cut", "rp_salvage:node_archer")
    local hands
    for _, c in pairs(svc().crates) do if c.meta.node == "archer" then hands = c end end
    local handsSpot = { x = hands.meta.at.x, y = hands.meta.at.y }
    pickup(1, hands)
    local carriedBefore = carryingCrate(1) == hands.id
    -- The server dies.
    local keep = SW.keep()
    SW.boot({ keep = keep })
    SW.watch()
    SW.join(1, A, "Vik", AT_NODE)
    SW.sync("salvage_probe", "rp_jobs", "setDuty", 1, true, { job = "ferrailleur" })
    SW.truck(TRUCK, PLATE, A, TRUCK_AT_LOAD)        -- the garage takes the truck out again
    MH.run(2)
    local s = svc()
    local g, b, h = s.crates[ground.id], s.crates[bed.id], s.crates[hands.id]
    local bedProps = 0
    for _, p in pairs(MH.shared.world.props) do
        if p.owner == "rp_cargo" and p.attachment and p.attachment.parentType == "vehicle" then bedProps = bedProps + 1 end
    end
    local handsBack = h and h.meta.at and math.abs(h.meta.at.x - handsSpot.x) < 0.01 and math.abs(h.meta.at.y - handsSpot.y) < 0.01
    local itemsAfter = SW.items()
    local states = { ground = g and g.state, bed = b and b.state, hands = h and h.state }
    local groundItem = g and g.itemId and SW.items(g.id) or 0
    local handsItem = h and h.itemId and SW.items(h.id) or 0
    -- Everything sells after the restart.
    local cash0 = SW.balance("cash:" .. A)
    SW.move(1, AT_NODE)
    pickup(1, g)
    SW.move(1, COUNTER)
    local sg = putdownAt(1, "rp_salvage:sell_counter")
    SW.move(1, AT_ARCHER)
    pickup(1, h)
    SW.move(1, COUNTER)
    local sh = putdownAt(1, "rp_salvage:sell_counter")
    local v = MH.shared.world.vehicles[TRUCK]
    v.x, v.y, v.z = TRUCK_AT_UNLOAD.x, TRUCK_AT_UNLOAD.y, TRUCK_AT_UNLOAD.z
    SW.move(1, UNLOAD_BAY)
    local un = SW.act(1, "rp_salvage:unload", "rp_salvage:unload_bay", "unload")
    MH.until_(function() return SW.carrying(1) ~= nil end, 10)
    SW.move(1, COUNTER)
    local sb = putdownAt(1, "rp_salvage:sell_counter")
    MH.run(2)
    local ok, detail = materialsConserved()
    return SW.result({
        load = load and load.state, carried_before = carriedBefore,
        ground = states.ground, bed = states.bed, hands = states.hands, hands_back_at_spot = handsBack == true,
        ground_item = groundItem, hands_item = handsItem,
        items_after = itemsAfter, bed_props = bedProps,
        sold_ground = sg and sg.state, sold_hands = sh and sh.state, unload = un and un.state, sold_bed = sb and sb.state,
        holds_left = #SW.holdsOf(A), earned = SW.balance("cash:" .. A) - cash0 > 0,
        conserved = ok, conservation = detail, unbalanced = tostring(SW.unbalanced()),
    })
end

-- ---------------------------------------------------------------------------------------------
-- Authorization: a scrapper without a key cannot load somebody's truck (the carry resumes, the
-- crate stays in its hold); a player who is not a scrapper on duty cannot even lift a crate.
-- ---------------------------------------------------------------------------------------------
function scenarios.stranger_load()
    SW.boot()
    SW.watch()
    setup(1, A, AT_NODE)
    setup(2, B, AT_QUADRA)
    SW.truck(TRUCK, PLATE, A, TRUCK_AT_LOAD)
    work(2, "cut", "rp_salvage:node_quadra")
    local crateB = crateOf(B)
    pickup(2, crateB)
    SW.move(2, LOAD_BAY)
    local refused = putdownAt(2, "rp_salvage:load_bay")
    MH.run(1)
    local stillCarrying = carryingCrate(2) == crateB.id
    local tokenAt = (SW.store().instances[crateB.iid] or {}).container
    -- The player command next to the truck: the same answer.
    MH.command("salvage", 2, { "load" })
    MH.run(4)
    local stillCarrying2 = carryingCrate(2) == crateB.id
    local bedCount = 0
    for _, inst in ipairs(SW.instancesOf("salvage_crate")) do
        if inst.container == "veh:" .. PLATE .. ":cargo" then bedCount = bedCount + 1 end
    end
    -- A civilian (no job) next to A's crate.
    work(1, "cut")
    local crateA = crateOf(A)
    SW.join(3, "acct-c", "Civ", NEAR_CRATE_B)
    SW.intent(3, "open77_actions:carry_pickup", "item:" .. crateA.itemId)
    MH.run(3)
    -- The owner hands B a key: now it loads.
    MH.shared.garage.rows[PLATE].keys[B] = true
    local granted = putdownAt(2, "rp_salvage:load_bay")
    return SW.result({
        refused = refused and refused.state, reason = refused and refused.reason, still_carrying = stillCarrying,
        token_in_hold = tokenAt == crateB.id, still_carrying_after_command = stillCarrying2, bed = bedCount,
        civilian_carrying = SW.carrying(3) ~= nil, civilian_refused = table.concat(SW.refusals(3), ","),
        with_key = granted and granted.state, told_no_key = SW.told(2, "no key"),
        token_in_bed = (SW.store().instances[crateB.iid] or {}).container == "veh:" .. PLATE .. ":cargo",
    })
end

-- ---------------------------------------------------------------------------------------------
-- open77_containers restarts under a running yard: the nodes come back with the same ids (keyed,
-- durable); a charge spent while it was stopped, then while it was booting (it answers
-- `unknown_container` until its boot join, here held by an absent coordinator), is kept and spent
-- once it is ready again; rp_salvage's own restart finds the five nodes and creates none.
-- ---------------------------------------------------------------------------------------------
function scenarios.containers_restart()
    SW.boot()
    SW.watch()
    setup(1, A, AT_NODE)
    local ids, keys = {}, {}
    for key, node in pairs(svc().nodes) do ids[key] = node.id end
    for key in pairs(ids) do
        local projection = SW.sync("salvage_probe", "open77_containers", "projection", ids[key])
        keys[#keys + 1] = type(projection) == "table" and projection.key == "node." .. key and "ok" or key
    end
    local w1 = work(1, "cut")
    MH.stop("open77_containers")
    local w2 = work(1, "cut")
    local function pending() local n = 0 for _ in pairs(svc().pendingConsume) do n = n + 1 end return n end
    local pendingStopped = pending()
    MH.stop("open77_transactions")
    SW.startContainers()
    MH.run(12)                         -- two rp_salvage sweeps meet `unknown_container`
    local pendingBooting = pending()
    local createdBefore = SW.printed("5 wreck node%(s%) ready %(0 created%)")
    SW.startCoordinator()
    MH.until_(function() return pending() == 0 end, 30)
    MH.run(2)
    local same = true
    for key, node in pairs(svc().nodes) do if node.id ~= ids[key] then same = false end end
    local refound = SW.printed("5 wreck node%(s%) ready %(0 created%)") - createdBefore
    local chargesAfter = charges("thorton")
    local logMark = #MH.logs + 1
    MH.stop("rp_salvage")
    MH.run(1)
    SW.startSalvage()
    MH.until_(function() return SW.salvage() and SW.salvage().ready end, 30)
    MH.run(1)
    local sameAfterSalvage = true
    for key, node in pairs(svc().nodes) do if node.id ~= ids[key] then sameAfterSalvage = false end end
    local nodeRows = 0
    for id, c in pairs(SW.store().containers) do
        if id:match("^world:") and type(c.meta) == "table" and c.meta.by == "open77_containers" then
            nodeRows = nodeRows + 1
        end
    end
    -- An operator closes a node at the console: its prompt goes, its key is spent for good.
    local closedId = svc().nodes.thorton.id
    local targetBefore = SW.engine().engine.targets["rp_salvage:node_thorton"] ~= nil
    SW.command("containers.remove", { "node.thorton" })
    MH.run(40)                         -- includes the 30 s retry of missing nodes
    local closedTarget = SW.engine().engine.targets["rp_salvage:node_thorton"] ~= nil
    return SW.result({
        closed_id_dropped = closedId ~= nil and svc().nodes.thorton.id == nil,
        closed_target = tostring(targetBefore) .. "/" .. tostring(closedTarget),
        closed_warned = SW.printed("node thorton %(node%.thorton%) was closed in open77_containers %(console%)"),
        key_spent = SW.printed("node thorton %(node%.thorton%) unavailable: container_closed"),
        others_kept = svc().nodes.quadra.id == ids.quadra,
        w1 = w1 and w1.state, w2 = w2 and w2.state, keys = table.concat(keys, ","),
        pending_stopped = pendingStopped, pending_booting = pendingBooting, pending_after = pending(),
        same_ids = same, refound = refound, charges = chargesAfter, works = committedWorks(),
        same_after_salvage_restart = sameAfterSalvage,
        salvage_boot_lines = bootLines(0, logMark), node_rows = nodeRows,
    })
end

-- ---------------------------------------------------------------------------------------------
-- Strict writers WITHOUT open77_containers: it cannot mint the nodes' world rows. rp_salvage boots
-- anyway (crates, bays and buyer work), says which nodes are unavailable and why, refuses work on
-- them; once the operator adds `open77_containers:world` live, the sweep brings the nodes back.
-- ---------------------------------------------------------------------------------------------
function scenarios.writers_missing()
    local without = "rp_salvage:world+char, rp_cargo:veh/cargo, rp_economy:cash+bank+soc, rp_inventory"
    SW.boot({ writers = without })
    SW.watch()
    setup(1, A, AT_NODE)
    local missing = 0
    for _, node in pairs(svc().nodes) do if not node.id then missing = missing + 1 end end
    local refused = work(1, "cut")     -- no node id, no wreck target: nothing to choose
    SW.setTunable("open77_transactions", "writers", without .. ", open77_containers:world")
    MH.run(40)                         -- the 30 s retry of missing nodes
    local back = 0
    for _, node in pairs(svc().nodes) do if node.id then back = back + 1 end end
    local w = work(1, "cut")
    return SW.result({
        ready = svc().ready, missing = missing, warned = SW.printed("node thorton %(node%.thorton%) unavailable: namespace_denied"),
        summary_line = SW.printed("WARNING: 5 of 5 wreck nodes unavailable"),
        no_prompt = refused == nil, back = back, ready_line = SW.printed("ready: 0 of 5 wreck nodes, foreman"),
        nodes_line = SW.printed("5 wreck node%(s%) ready %(5 created%)"), w = w and w.state,
        charges = charges("thorton"),
    })
end

-- ---------------------------------------------------------------------------------------------
-- Cancellations: death mid-work (nothing granted, the empty crate closed, no wear), then with a
-- crate in hand: entering a vehicle, a job change (epoch), a disconnect, and a restart of
-- rp_salvage itself. Every time the crate lies down once, custody unchanged, wear exactly once.
-- ---------------------------------------------------------------------------------------------
function scenarios.cancellations()
    SW.boot()
    SW.watch()
    setup(1, A, AT_NODE)
    local mark = SW.mark()
    SW.intent(1, "rp_salvage:cut", NODE_T)
    waitState(1, "cut", mark, "presenting", 15)
    SW.kill(1)
    local dead = SW.finish(1, "cut", 30, mark)
    MH.run(3)
    local afterDeath = { holds = #SW.holdsOf(A), wear = 30 - SW.toolDurability("char:" .. A, "welder"),
        charges = charges("thorton"), works = committedWorks() }
    MH.players[1].alive = true
    MH.emit("onPlayerLifeStateChanged", 1, 2, "alive")
    MH.run(1)
    local w = work(1, "cut")
    local crate = crateOf(A)
    local results = {}
    local function carried(label, cause)
        SW.move(1, AT_NODE)
        local c0 = svc().crates[crate.id]
        if c0 and c0.meta.at then SW.move(1, { x = c0.meta.at.x + 0.6, y = c0.meta.at.y, z = c0.meta.at.z }) end
        pickup(1, svc().crates[crate.id])
        local was = carryingCrate(1) == crate.id
        cause()
        MH.run(2)
        local c = svc().crates[crate.id]
        results[label] = ("%s/%s/%s/%d"):format(tostring(was), tostring(SW.carrying(1) == nil),
            tostring(c and c.state), SW.items(crate.id))
        results[label .. "_token"] = (SW.store().instances[crate.iid] or {}).container == crate.id
    end
    carried("vehicle", function()
        MH.players[1].inVehicle = true
        MH.emit("onPlayerEnteringVehicle", 1)
    end)
    MH.players[1].inVehicle = false
    carried("job_change", function()
        SW.sync("salvage_probe", "rp_jobs", "setJob", 1, "ferrailleur", 1)   -- a promotion moves the epoch
    end)
    SW.sync("salvage_probe", "rp_jobs", "setDuty", 1, true, { job = "ferrailleur" })
    carried("disconnect", function()
        SW.disconnect(1)
        MH.run(1)
        SW.join(1, A, "Vik", AT_NODE)
        SW.sync("salvage_probe", "rp_jobs", "setDuty", 1, true, { job = "ferrailleur" })
    end)
    carried("restart", function()
        MH.stop("rp_salvage")
        MH.run(1)
        SW.startSalvage()
        MH.until_(function() return SW.salvage() and SW.salvage().ready end, 30)
        MH.run(1)
    end)
    local ok, detail = materialsConserved()
    return SW.result({
        dead = dead and dead.state, dead_reason = dead and dead.reason, death_holds = afterDeath.holds,
        death_wear = afterDeath.wear, death_charges = afterDeath.charges, death_works = afterDeath.works,
        w = w and w.state, vehicle = results.vehicle, vehicle_token = results.vehicle_token,
        job_change = results.job_change, job_change_token = results.job_change_token,
        disconnect = results.disconnect, disconnect_token = results.disconnect_token,
        restart = results.restart, restart_token = results.restart_token,
        wear = 30 - SW.toolDurability("char:" .. A, "welder"), works = committedWorks(),
        conserved = ok, conservation = detail,
    })
end

function RUN_SCENARIO(name)
    local scenario = assert(scenarios[name], "unknown scenario " .. tostring(name))
    return scenario()
end

function DEBUG_LOGS(pattern)
    local out = {}
    for _, line in ipairs(MH.logs) do if not pattern or line:find(pattern) then out[#out + 1] = line end end
    return table.concat(out, "\n")
end
