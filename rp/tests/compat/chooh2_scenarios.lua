-- tests/compat/chooh2_scenarios.lua: the CHOOH2 chain (rp_chooh2) end to end, offline.
--
-- Loaded by tests/test_w3_chooh2.py with the string globals ROOT_DIR, COMPAT_DIR, SYS_DIR and
-- TX_DIR (chooh2_world.lua). Players act the way the open77_actions client makes them act:
-- prompt intents, the put-down key and X, as net events from their own seat. Every check reads
-- durable truth from the coordinator's store.

dofile(COMPAT_DIR .. "/chooh2_world.lua")

local scenarios = {}

local A, B, C, D = "acct-a", "acct-b", "acct-c", "acct-d"
local CORN, CAN = "biotech_corn", "chooh2_canister"
local INTAKE, OUTPUT = "stash:chooh2.sunrise:intake", "stash:chooh2.sunrise:output"

local AT_FARM_OFFICE = { x = -986.8, y = 2997.6, z = 16.0 }
local AT_ROW = {
    row1 = { x = -978.2, y = 3000.4, z = 16.55 },
    row2 = { x = -980.6, y = 3007.4, z = 15.65 },
    row3 = { x = -983.1, y = 3014.4, z = 14.17 },
    row4 = { x = -985.5, y = 3021.4, z = 13.13 },
    row5 = { x = -987.9, y = 3028.4, z = 12.06 },
}
local FARM_BAY = { x = -994.0, y = 3010.0, z = 14.04 }
local TRUCK_AT_FARM = { x = -996.0, y = 3013.0, z = 14.0 }
local AT_REFINERY_OFFICE = { x = -1470.6, y = 4004.3, z = 7.12 }
local UNLOAD_BAY = { x = -1482.6, y = 4013.5, z = 7.12 }
local TRUCK_AT_REFINERY = { x = -1484.0, y = 4016.0, z = 7.12 }
local AT_INTAKE = { x = -1472.4, y = 4018.4, z = 7.12 }
local AT_CONTROL = { x = -1473.0, y = 4013.5, z = 7.12 }
local AT_CONTROL_2 = { x = -1473.6, y = 4012.9, z = 7.12 }
local AT_OUTPUT = { x = -1472.4, y = 4008.6, z = 7.12 }
local AT_COUNTER = { x = -1464.0, y = 3997.2, z = 7.12 }
local AT_PUMP = { x = -1476.0, y = 3996.5, z = 7.12 }
local TRUCK_AT_PUMP = { x = -1477.0, y = 3999.5, z = 7.12 }
local TRUCK = 701
local PLATE = "NC-CH2O1"

local function svc() return CW.svc() end
local function sync(...) return SW.sync("salvage_probe", ...) end

local function hire(pid, identifier, job, position)
    SW.join(pid, identifier, "player" .. pid, position)
    sync("rp_jobs", "setJob", pid, job, 0)
    sync("rp_jobs", "setDuty", pid, true, { job = job })
    MH.run(1)
end

local function harvest(pid, row, action)
    SW.move(pid, AT_ROW[row])
    return SW.act(pid, "rp_chooh2:" .. (action or "harvest"), "rp_chooh2:node_" .. row, action or "harvest", 30)
end

local function crateAt(identifier, row)
    for _, crate in pairs(svc().crates) do
        if crate.meta and crate.meta.owner == identifier and crate.meta.node == row and crate.state ~= "delivered" then
            return crate
        end
    end
    return nil
end

local function pickup(pid, crate)
    local at = crate.meta.at
    SW.move(pid, { x = at.x + 0.6, y = at.y, z = at.z })
    SW.intent(pid, "open77_actions:carry_pickup", "item:" .. tostring(crate.itemId))
    MH.until_(function() return SW.carrying(pid) ~= nil end, 10)
    MH.run(0.5)
    return SW.carrying(pid)
end

local function putdownAt(pid, targetKey)
    return SW.act(pid, "open77_actions:carry_putdown", targetKey, "carry_putdown", 30)
end

local function moveTruck(position)
    local v = MH.shared.world.vehicles[TRUCK]
    v.x, v.y, v.z = position.x, position.y, position.z
end

local function carryingCrate(pid)
    local item = SW.carrying(pid)
    return item and item.data and item.data.container or nil
end

local function count(account, item) return SW.count(account, item) end

-- Corn: minted out of sys:chooh2.fields = in crates + in the intake + burned by the refinery.
-- Canisters: minted out of sys:chooh2.refinery = on the rack + in pockets + poured + sold.
local function conserved()
    local minted = -SW.journal("^sys:chooh2%.fields$", CORN)
    local held = 0
    for _, hold in ipairs(CW.holdsOf(nil)) do held = held + count(hold, CORN) end
    local intake = count(INTAKE, CORN)
    local burned = SW.journal("^sys:chooh2%.refinery$", CORN)
    local cornOk = minted == held + intake + burned
    local canMinted = -SW.journal("^sys:chooh2%.refinery$", CAN)
    local rack = count(OUTPUT, CAN)
    local pockets = 0
    for _, who in ipairs({ A, B, C, D }) do pockets = pockets + count("char:" .. who, CAN) end
    local poured = SW.journal("^sys:chooh2%.burned$", CAN)
    local sold = SW.journal("^sys:rp_chooh2:depot$", CAN)
    local canOk = canMinted == rack + pockets + poured + sold
    return cornOk and canOk, ("corn minted=%d held=%d intake=%d burned=%d | canisters minted=%d rack=%d pockets=%d " ..
        "poured=%d sold=%d"):format(minted, held, intake, burned, canMinted, rack, pockets, poured, sold)
end

local function bootLines(created, from)
    local out = {}
    for _, pattern in ipairs({ "coordinator ready %(store=", "items defined through rp_inventory: 3",
        "5 corn row%(s%) ready %(" .. created .. " created%)", "crates rebuilt from the coordinator: ",
        "ready: 5 corn rows, farm office and bay, refinery %(intake open, control, rack%), depot, pump" }) do
        local n = 0
        for index = (from or 1), #MH.logs do
            local line = MH.logs[index]
            if line:find("^%[rp_chooh2%]") and line:find(pattern) then n = n + 1 end
        end
        out[#out + 1] = tostring(n)
    end
    return table.concat(out, "/")
end

local function kinds()
    local n = {}
    for _, e in ipairs(CW.events()) do n[e.kind] = (n[e.kind] or 0) + 1 end
    return ("harvest=%d deliver_intake=%d refine=%d sell=%d refuel=%d"):format(n.harvest or 0, n.deliver_intake or 0,
        n.refine or 0, n.sell or 0, n.refuel or 0)
end

-- ---------------------------------------------------------------------------------------------
-- The whole chain with three players and strict writers: a farmhand harvests a row clean into
-- one crate, a nomad with a key loads it, drives, unloads and empties it into the intake, an
-- operator runs a batch, takes the canisters, pours one into the truck and sells the other.
-- ---------------------------------------------------------------------------------------------
function scenarios.happy_path()
    CW.boot({ writers = CW.WRITERS_STRICT })
    local startLines = bootLines(5)
    local rowWarnings = CW.printed("unavailable")
    local jobWarning = CW.printed("rp_jobs has no job")
    CW.watch()
    -- The farmhand clocks in at the farm office through the prompt.
    SW.join(1, A, "Mara", AT_FARM_OFFICE)
    sync("rp_jobs", "setJob", 1, "farmhand", 0)
    local clock = SW.act(1, "rp_chooh2:clock_in", "rp_chooh2:farm_office", "clock_in")
    local h = {}
    for i = 1, 4 do h[i] = harvest(1, "row1") end
    local crate = crateAt(A, "row1")
    local cornInCrate = crate and count(crate.id, CORN) or -1
    -- The row is picked clean: the fifth press is refused before anything is held.
    local mark = SW.mark()
    SW.move(1, AT_ROW.row1)
    SW.intent(1, "rp_chooh2:harvest", "rp_chooh2:node_row1")
    MH.run(2)
    local fifth = SW.lastOp(1, "harvest", mark)
    local refusals = SW.refusals(1)
    -- The prompt no longer offers "Harvest corn" (the client cannot pick it); a server-side request
    -- for it is refused by the row itself, and the player reads why.
    SW.command("chooh2.harvest", { "1", "row1" })
    MH.run(1)
    local consoleRefused = CW.printed("harvest on row1 refused: node_depleted")
    local inspect = harvest(1, "row1", "inspect")
    local depletedTarget = SW.engine().engine.targets["rp_chooh2:node_row1"]
    local depletedLabel = depletedTarget and depletedTarget.label or "?"
    -- The hauler (a nomad, with a key to the farmhand's truck) loads the crate at the farm bay.
    hire(2, B, "nomade", AT_FARM_OFFICE)
    SW.truck(TRUCK, PLATE, A, TRUCK_AT_FARM, { [B] = true })
    local carried = pickup(2, crate)
    SW.move(2, FARM_BAY)
    local load = putdownAt(2, "rp_chooh2:farm_bay")
    local tokenInBed = (SW.store().instances[crate.iid] or {}).container
    -- Drive to the refinery, unload at the bay (the crate lands in the hauler's hands).
    moveTruck(TRUCK_AT_REFINERY)
    SW.move(2, UNLOAD_BAY)
    local unload = SW.act(2, "rp_chooh2:unload", "rp_chooh2:unload_bay", "unload")
    MH.until_(function() return SW.carrying(2) ~= nil end, 10)
    local carriedAgain = SW.carrying(2) ~= nil
    -- Empty it into the intake.
    SW.move(2, AT_INTAKE)
    local deliver = putdownAt(2, "rp_chooh2:intake")
    MH.run(2)
    local intakeAfter = count(INTAKE, CORN)
    -- The operator clocks in at the refinery office, runs a batch, reads the gauges, takes canisters.
    SW.join(3, C, "Sol", AT_REFINERY_OFFICE)
    sync("rp_jobs", "setJob", 3, "refinery", 0)
    local clock3 = SW.act(3, "rp_chooh2:clock_in", "rp_chooh2:refinery_office", "clock_in")
    SW.move(3, AT_CONTROL)
    local run = SW.act(3, "rp_chooh2:refine", "rp_chooh2:control", "refine", 40)
    local gauges = SW.act(3, "rp_chooh2:gauges", "rp_chooh2:control", "gauges")
    SW.move(3, AT_OUTPUT)
    local collect = SW.act(3, "rp_chooh2:collect", "rp_chooh2:output_rack", "collect")
    local pocketsAfterCollect = count("char:" .. C, CAN)
    -- Pour one canister into the truck at the depot pump.
    moveTruck(TRUCK_AT_PUMP)
    MH.run(2)
    CW.setFuel(TRUCK, 20.0)
    SW.move(3, AT_PUMP)
    local refuel = SW.act(3, "rp_chooh2:refuel", "rp_chooh2:pump", "refuel", 30)
    MH.run(2)
    local fuelAfter = CW.fuel(TRUCK)
    -- Sell the other one at the depot counter.
    SW.move(3, AT_COUNTER)
    local cash0 = SW.balance("cash:" .. C)
    local sale = SW.act(3, "rp_chooh2:sell", "rp_chooh2:depot_counter", "sell")
    MH.run(2)
    -- The farmhand clocks out; a jobless passer-by is refused at the office with the reason.
    SW.move(1, AT_FARM_OFFICE)
    local out = SW.act(1, "rp_chooh2:clock_out", "rp_chooh2:farm_office", "clock_out")
    SW.join(4, D, "Civ", AT_FARM_OFFICE)
    local civ = SW.act(4, "rp_chooh2:clock_in", "rp_chooh2:farm_office", "clock_in")
    local ok, detail = conserved()
    local ev = CW.events("deliver_intake")[1] or {}
    return SW.result({
        boot_lines = startLines, row_warnings = rowWarnings, job_warning = jobWarning,
        clock = clock and clock.state, h1 = h[1] and h[1].state, h4 = h[4] and h[4].state,
        corn_in_crate = cornInCrate, crate_one = #CW.holdsOf(A),
        fifth = fifth and fifth.state or "none", fifth_refused = refusals[#refusals] or "none",
        console_refused = consoleRefused, told_clean = CW.told(1, "picked clean"), inspect = inspect and inspect.state,
        told_row = CW.told(1, "Corn row 1: 0 / 4 harvests left"), depleted_label = depletedLabel,
        carried = carried ~= nil, load = load and load.state, load_reason = load and load.reason,
        token_in_bed = tokenInBed == ("veh:" .. PLATE .. ":cargo"),
        unload = unload and unload.state, carried_again = carriedAgain,
        deliver = deliver and deliver.state, deliver_reason = deliver and deliver.reason,
        intake = intakeAfter, intake_expected = cornInCrate,
        hold_closed = SW.store().containers[crate.id] == nil,
        token_retired = (SW.store().instances[crate.iid] or {}).container == "sys:chooh2.fields",
        clock3 = clock3 and clock3.state, run = run and run.state, run_reason = run and run.reason,
        intake_after_run = count(INTAKE, CORN), intake_after_run_expected = cornInCrate - 10,
        gauges = gauges and gauges.state, told_gauges = CW.told(3, "Intake: %d+ corn%. Rack: 2 canister"),
        collect = collect and collect.state, pockets_after_collect = pocketsAfterCollect, rack_after = count(OUTPUT, CAN),
        refuel = refuel and refuel.state, refuel_reason = refuel and refuel.reason, fuel_after = fuelAfter,
        told_poured = CW.told(3, "Poured a CHOOH2 canister: %+15%.0 L"),
        sale = sale and sale.state, sale_reason = sale and sale.reason,
        paid = SW.balance("cash:" .. C) - cash0, society = SW.balance("soc:refinery"),
        pockets_end = count("char:" .. C, CAN), pocket_grants = MH.shared.pocketGrants or 0,
        told_sold = CW.told(3, "Sold 1 canister%(s%) to the depot clerk: 150 eddies %(135 to you, 15 to the refinery society%)"),
        clock_out = out and out.state, civ = civ and civ.state, civ_reason = civ and civ.reason,
        told_civ = CW.told(4, "employment agency"),
        events = kinds(), deliver_ref = tostring(ev.ref), deliver_job = tostring(ev.job),
        deliver_corn = tostring(ev.data and ev.data.corn),
        conserved = ok, conservation = detail, unbalanced = tostring(SW.unbalanced()),
        clerk = (function() local n = 0 for _ in pairs(MH.shared.world.npcs) do n = n + 1 end return n end)(),
    })
end

-- ---------------------------------------------------------------------------------------------
-- Cancel mid-harvest: X on the bar, then a death, then walking away from the hold: nothing is
-- granted, the empty crate opened for the harvest is closed, no charge is spent. A harvest after
-- that commits normally.
-- ---------------------------------------------------------------------------------------------
function scenarios.cancel_mid_harvest()
    CW.boot()
    CW.watch()
    hire(1, A, "farmhand", AT_ROW.row2)
    local function startAndStop(stop)
        local mark = SW.mark()
        SW.move(1, AT_ROW.row2)
        SW.intent(1, "rp_chooh2:harvest", "rp_chooh2:node_row2")
        MH.until_(function() local op = SW.lastOp(1, "harvest", mark) return op and op.state == "presenting" end, 15)
        local op = SW.lastOp(1, "harvest", mark)
        local holdsDuring = #CW.holdsOf(A)
        stop(op)
        local fin = SW.finish(1, "harvest", 30, mark)
        MH.run(3)
        return fin, holdsDuring
    end
    local x, holdsDuringX = startAndStop(function(op) CW.cancelKey(1, op.opId) end)
    local afterX = { holds = #CW.holdsOf(A), corn = SW.journal("^sys:chooh2%.fields$", CORN) }
    local dead, holdsDuringDead = startAndStop(function()
        SW.kill(1)
    end)
    local holdsAfterDead = #CW.holdsOf(A)
    MH.players[1].alive = true
    MH.emit("onPlayerLifeStateChanged", 1, 2, "alive")
    MH.run(1)
    local summary = sync("open77_containers", "summary", svc().nodes.row2.id) or {}
    local w = harvest(1, "row2")
    local summary2 = sync("open77_containers", "summary", svc().nodes.row2.id) or {}
    return SW.result({
        x = x and x.state, x_reason = x and x.reason, holds_during_x = holdsDuringX,
        holds_after_x = afterX.holds, corn_after_x = afterX.corn,
        dead = dead and dead.state, dead_reason = dead and dead.reason,
        holds_during_dead = holdsDuringDead, holds_after_dead = holdsAfterDead, charges_before = summary.charges,
        w = w and w.state, charges_after = summary2.charges, holds_end = #CW.holdsOf(A),
        committed = CW.committed("chooh2.harvest"), events = kinds(),
        unbalanced = tostring(SW.unbalanced()),
    })
end

-- ---------------------------------------------------------------------------------------------
-- A hauler without the truck's key: the load is refused (rp_garage through rp_cargo), the crate
-- stays in its hold and in the hauler's hands, by prompt and by command alike; with a key it
-- loads. A player with no CHOOH2 job cannot lift a crate at all.
-- ---------------------------------------------------------------------------------------------
function scenarios.truck_without_key()
    CW.boot({ writers = CW.WRITERS_STRICT })
    CW.watch()
    hire(1, A, "farmhand", AT_ROW.row3)
    hire(2, B, "nomade", AT_ROW.row3)
    SW.truck(TRUCK, PLATE, A, TRUCK_AT_FARM)            -- A's truck, no key for B
    harvest(1, "row3")
    local crate = crateAt(A, "row3")
    pickup(2, crate)
    SW.move(2, FARM_BAY)
    local refused = putdownAt(2, "rp_chooh2:farm_bay")
    MH.run(1)
    local stillCarrying = carryingCrate(2) == crate.id
    local tokenAt = (SW.store().instances[crate.iid] or {}).container
    MH.command("chooh2", 2, { "load" })
    MH.run(4)
    local stillCarrying2 = carryingCrate(2) == crate.id
    -- A civilian next to another crate.
    harvest(1, "row4")
    local crate2 = crateAt(A, "row4")
    SW.join(3, C, "Civ", { x = crate2.meta.at.x + 0.5, y = crate2.meta.at.y, z = crate2.meta.at.z })
    SW.intent(3, "open77_actions:carry_pickup", "item:" .. crate2.itemId)
    MH.run(3)
    -- The owner hands B a key: now it loads.
    MH.shared.garage.rows[PLATE].keys[B] = true
    local granted = putdownAt(2, "rp_chooh2:farm_bay")
    return SW.result({
        refused = refused and refused.state, reason = refused and refused.reason, still_carrying = stillCarrying,
        token_in_hold = tokenAt == crate.id, still_carrying_after_command = stillCarrying2,
        told_no_key = CW.told(2, "no key"),
        civilian_carrying = SW.carrying(3) ~= nil, civilian_refused = table.concat(SW.refusals(3), ","),
        with_key = granted and granted.state,
        token_in_bed = (SW.store().instances[crate.iid] or {}).container == "veh:" .. PLATE .. ":cargo",
    })
end

-- ---------------------------------------------------------------------------------------------
-- Server restart with one crate on the ground, one in the hauler's hands and one in the bed:
-- each comes back once where its durable record says, and all three reach the intake after.
-- ---------------------------------------------------------------------------------------------
function scenarios.restart()
    CW.boot()
    CW.watch()
    hire(1, A, "farmhand", AT_ROW.row1)
    hire(2, B, "nomade", AT_ROW.row1)
    SW.truck(TRUCK, PLATE, A, TRUCK_AT_FARM, { [B] = true })
    harvest(1, "row1")
    harvest(1, "row3")
    harvest(1, "row5")
    local bed, hands, ground = crateAt(A, "row1"), crateAt(A, "row3"), crateAt(A, "row5")
    pickup(2, bed)
    SW.move(2, FARM_BAY)
    local load = putdownAt(2, "rp_chooh2:farm_bay")
    local handsSpot = { x = hands.meta.at.x, y = hands.meta.at.y }
    pickup(2, hands)
    local carriedBefore = carryingCrate(2) == hands.id
    local cornTotal = count(bed.id, CORN) + count(hands.id, CORN) + count(ground.id, CORN)
    -- The server dies.
    local keep = SW.keep()
    local logMark = #MH.logs + 1
    CW.boot({ keep = keep })
    CW.watch()
    local reboot = bootLines(0)
    SW.join(1, A, "Mara", AT_ROW.row1)
    SW.join(2, B, "Jax", AT_ROW.row3)
    sync("rp_jobs", "setDuty", 2, true, { job = "nomade" })
    SW.truck(TRUCK, PLATE, A, TRUCK_AT_FARM, { [B] = true })
    MH.run(2)
    local s = svc()
    local g, h, b = s.crates[ground.id], s.crates[hands.id], s.crates[bed.id]
    local states = ("%s/%s/%s"):format(tostring(g and g.state), tostring(h and h.state), tostring(b and b.state))
    local handsBack = h and h.meta.at and math.abs(h.meta.at.x - handsSpot.x) < 0.01 and math.abs(h.meta.at.y - handsSpot.y) < 0.01
    local items = SW.items()
    -- Everything reaches the intake after the restart: load the two ground crates, drive, unload
    -- the three one by one and empty each into the intake.
    pickup(2, s.crates[ground.id])
    SW.move(2, FARM_BAY)
    local l2 = putdownAt(2, "rp_chooh2:farm_bay")
    pickup(2, s.crates[hands.id])
    SW.move(2, FARM_BAY)
    local l3 = putdownAt(2, "rp_chooh2:farm_bay")
    moveTruck(TRUCK_AT_REFINERY)
    local delivered = 0
    for _ = 1, 3 do
        SW.move(2, UNLOAD_BAY)
        local un = SW.act(2, "rp_chooh2:unload", "rp_chooh2:unload_bay", "unload")
        MH.until_(function() return SW.carrying(2) ~= nil end, 10)
        SW.move(2, AT_INTAKE)
        local d = putdownAt(2, "rp_chooh2:intake")
        if un and un.state == "committed" and d and d.state == "committed" then delivered = delivered + 1 end
    end
    MH.run(2)
    local ok, detail = conserved()
    return SW.result({
        load = load and load.state, carried_before = carriedBefore, reboot_lines = reboot,
        states = states, hands_back_at_spot = handsBack == true, items = items,
        l2 = l2 and l2.state, l3 = l3 and l3.state, delivered = delivered,
        intake = count(INTAKE, CORN), corn_total = cornTotal, holds_left = #CW.holdsOf(A),
        events = kinds(), conserved = ok, conservation = detail, unbalanced = tostring(SW.unbalanced()),
        log_mark = logMark,
    })
end

-- ---------------------------------------------------------------------------------------------
-- The refinery: a double press by the operator and a second operator on the same station in the
-- same pass: one run, one winner; a retried commit replays; an empty intake refuses before the
-- bar; a full rack refuses at the reservation. Exactly once: the intake loses 10 corn per
-- committed run and the rack gains 2 canisters per committed run, never more.
-- ---------------------------------------------------------------------------------------------
function scenarios.refinery_double_press()
    CW.boot()
    CW.watch()
    hire(1, C, "refinery", AT_CONTROL)
    hire(2, D, "refinery", AT_CONTROL_2)
    -- An empty intake: refused at the start, nothing held, the reason told.
    local mark0 = SW.mark()
    SW.intent(1, "rp_chooh2:refine", "rp_chooh2:control")
    MH.run(2)
    local empty = SW.lastOp(1, "refine", mark0)
    local emptyRefusal = SW.refusals(1)[#SW.refusals(1)]
    SW.command("chooh2.stock", { "25" })
    MH.run(2)
    local stocked = count(INTAKE, CORN)
    -- Double press and a second operator, same pass.
    local mark = SW.mark()
    SW.intent(1, "rp_chooh2:refine", "rp_chooh2:control")
    SW.intent(1, "rp_chooh2:refine", "rp_chooh2:control")
    SW.intent(2, "rp_chooh2:refine", "rp_chooh2:control")
    local first = SW.finish(1, "refine", 40, mark)
    local second = SW.lastOp(2, "refine", mark)
    local refusals1 = table.concat(SW.refusals(1), ",")
    local refusals2 = table.concat(SW.refusals(2), ",")
    local afterOne = { corn = count(INTAKE, CORN), cans = count(OUTPUT, CAN) }
    -- The same commit again (a retry reaching the coordinator twice): replayed, nothing moves.
    local txOpId = first and type(first.receipt) == "table" and first.receipt.tx
    local again, againWhy = MH.callAsync("rp_chooh2", "open77_transactions", "commit", txOpId)
    MH.run(2)
    local afterReplay = { corn = count(INTAKE, CORN), cans = count(OUTPUT, CAN) }
    -- A second run commits; the third finds 5 corn: refused at the start.
    local run2 = SW.act(1, "rp_chooh2:refine", "rp_chooh2:control", "refine", 40)
    local mark3 = SW.mark()
    SW.intent(1, "rp_chooh2:refine", "rp_chooh2:control")
    MH.run(2)
    local third = SW.lastOp(1, "refine", mark3)
    -- A lost acknowledgement on a run's commit: granted exactly once.
    SW.command("chooh2.stock", { "10" })
    MH.run(2)
    local before4 = { corn = count(INTAKE, CORN), cans = count(OUTPUT, CAN) }
    local mark4 = SW.mark()
    SW.intent(1, "rp_chooh2:refine", "rp_chooh2:control")
    MH.until_(function() local op = SW.lastOp(1, "refine", mark4) return op and op.state == "presenting" end, 15)
    SW.store().faults = { "lost_ack" }
    local lost = SW.finish(1, "refine", 40, mark4)
    MH.run(8)
    local after4 = { corn = count(INTAKE, CORN), cans = count(OUTPUT, CAN) }
    return SW.result({
        empty = empty and empty.state or "none", empty_refusal = tostring(emptyRefusal), told_empty = CW.told(1, "Not enough corn"),
        stocked = stocked, first = first and first.state, second = second and second.state or "none",
        refusals1 = refusals1, refusals2 = refusals2,
        after_one = ("%d/%d"):format(afterOne.corn, afterOne.cans),
        again = type(again) == "table" and ("replay=" .. tostring(again.replay)) or tostring(againWhy),
        after_replay = ("%d/%d"):format(afterReplay.corn, afterReplay.cans),
        run2 = run2 and run2.state, third = third and third.state or "none",
        after_two = ("%d/%d"):format(count(INTAKE, CORN), count(OUTPUT, CAN)),
        lost = lost and lost.state, before4 = ("%d/%d"):format(before4.corn, before4.cans),
        after4 = ("%d/%d"):format(after4.corn, after4.cans),
        runs = CW.committed("chooh2.refine"), refine_events = #CW.events("refine"),
        unbalanced = tostring(SW.unbalanced()),
    })
end

-- ---------------------------------------------------------------------------------------------
-- A delivery whose answer never comes back (the export layer times out: in doubt). Three cases:
--   landed      the transfer committed, nobody heard it: open77_actions retries the put-down hook,
--               which finds attempt a1 committed and only closes the crate;
--   never_sent  the transfer never reached the coordinator: the retry fences a1 (it can never
--               land later) and commits a2;
--   pending     the coordinator cannot say yet: the put-down fails `in_doubt`, the hauler keeps
--               the crate and is told; the next put-down finds a1 committed.
-- The corn reaches the intake exactly once in every case.
-- ---------------------------------------------------------------------------------------------
local function deliverInDoubt(row, mode)
    harvest(1, row)
    local crate = crateAt(A, row)
    local corn = count(crate.id, CORN)
    pickup(2, crate)
    local L = svc().L
    local realTransfer, realSettle = L.transfer, L.settle
    local injected, holding = false, mode == "pending"
    L.transfer = function(spec)
        if spec.kind == "chooh2.deliver" and not injected then
            injected = true
            if mode ~= "never_sent" then realTransfer(spec) end
            return nil, "in_doubt", { retryable = true, detail = "export_timeout" }
        end
        return realTransfer(spec)
    end
    L.settle = function(opId)
        if holding then return "pending" end
        return realSettle(opId)
    end
    local intake0 = count(INTAKE, CORN)
    SW.move(2, AT_INTAKE)
    MH.run(1)
    local first = putdownAt(2, "rp_chooh2:intake")
    MH.run(2)
    local carrying = carryingCrate(2) == crate.id
    local between = count(INTAKE, CORN) - intake0
    holding = false
    local second
    if carrying then
        MH.run(2)
        second = putdownAt(2, "rp_chooh2:intake")
        MH.run(3)
    end
    L.transfer, L.settle = realTransfer, realSettle
    local attempt = (svc().crates[crate.id] and svc().crates[crate.id].meta.deliver) or {}
    return ("%s/%s/%s/%d/%s/%s/%s"):format(tostring(first and first.state), tostring(first and first.reason),
        tostring(carrying), between, tostring(second and second.state or "none"),
        tostring(count(INTAKE, CORN) - intake0 == corn), tostring(SW.store().containers[crate.id] == nil)), corn
end

function scenarios.delivery_in_doubt()
    CW.boot()
    CW.watch()
    hire(1, A, "farmhand", AT_ROW.row2)
    hire(2, B, "nomade", AT_ROW.row2)
    local landed, c1 = deliverInDoubt("row2", "landed")
    local neverSent, c2 = deliverInDoubt("row4", "never_sent")
    local pending, c3 = deliverInDoubt("row1", "pending")
    MH.run(6)
    local refs = {}
    for _, e in ipairs(CW.events("deliver_intake")) do refs[#refs + 1] = tostring(e.ref):match("%.a%d+$") or "?" end
    return SW.result({
        landed = landed, never_sent = neverSent, pending = pending,
        deliveries = CW.committed("chooh2.deliver"), intake = count(INTAKE, CORN), corn_total = c1 + c2 + c3,
        told_doubt = CW.told(2, "still confirming"), carrying = SW.carrying(2) ~= nil, items = SW.items(),
        holds_left = #CW.holdsOf(A), recovered = CW.printed("delivery ch2%.deliver:%S+%.a1 of %S+ found committed"),
        events = #CW.events("deliver_intake"), attempts = table.concat(refs, ","), unbalanced = tostring(SW.unbalanced()),
    })
end

-- ---------------------------------------------------------------------------------------------
-- Refuel: refused before anything is taken with no canister, a full tank, a moving car, and
-- open77_fuel stopped (each told in words); by command next to a street car; a car removed
-- before the pour loses the fuel but the canister is burned exactly once.
-- ---------------------------------------------------------------------------------------------
function scenarios.refuel()
    CW.boot()
    CW.watch()
    local CAR, CAR2 = 801, 802
    SW.join(1, A, "Mara", { x = 100.0, y = 100.0, z = 10.0 })
    MH.run(1)
    CW.car(CAR, { x = 102.0, y = 100.0, z = 10.0 })
    MH.run(2)
    local spawnedFull = CW.fuel(CAR)
    CW.setFuel(CAR, 10.0)
    local function try()
        local mark = SW.mark()
        MH.command("chooh2", 1, { "refuel" })
        MH.run(3)
        return SW.lastOp(1, "refuel", mark)
    end
    -- No canister: the reservation refuses, nothing starts.
    local none = SW.finish(1, "refuel", 15, (function() local m = SW.mark() MH.command("chooh2", 1, { "refuel" }) return m end)())
    local toldNone = CW.told(1, "no CHOOH2 canister")
    SW.command("chooh2.give", { "1", CAN, "3" })
    MH.run(3)
    local given = count("char:" .. A, CAN)
    -- A full tank.
    CW.setFuel(CAR, 59.0)
    local full = try()
    local toldFull = CW.told(1, "That tank is full")
    -- A moving car.
    CW.setFuel(CAR, 10.0)
    MH.shared.world.vehicles[CAR].speed = 5.0
    local moving = try()
    local toldMoving = CW.told(1, "Stop the car first")
    MH.shared.world.vehicles[CAR].speed = 0
    -- open77_fuel stopped.
    MH.stop("open77_fuel")
    MH.run(1)
    local down = try()
    local toldDown = CW.told(1, "open77_fuel is not running")
    local keptAfterRefusals = count("char:" .. A, CAN)
    CW.startFuel()
    MH.run(2)
    CW.setFuel(CAR, 10.0)
    -- The real thing, by command.
    local mark2 = SW.mark()
    MH.command("chooh2", 1, { "refuel" })
    local ok = SW.finish(1, "refuel", 30, mark2)
    MH.run(2)
    local fuelAfter = CW.fuel(CAR)
    local left = count("char:" .. A, CAN)
    -- A second car that is gone by the time the canister is poured.
    MH.shared.world.vehicles[CAR] = nil
    CW.car(CAR2, { x = 98.5, y = 100.0, z = 10.0 })
    MH.run(2)
    CW.setFuel(CAR2, 10.0)
    local fuelPort = svc().P.fuel
    local realRefuel = fuelPort.refuel
    fuelPort.refuel = function(id, litres)
        MH.shared.world.vehicles[CAR2] = nil
        return realRefuel(id, litres)
    end
    local mark3 = SW.mark()
    MH.command("chooh2", 1, { "refuel" })
    local gone = SW.finish(1, "refuel", 30, mark3)
    MH.run(3)
    fuelPort.refuel = realRefuel
    return SW.result({
        spawned_full = spawnedFull, none = none and none.state or "none", none_reason = none and none.reason,
        none_stage = none and none.stage, told_none = toldNone,
        given = given, full = full and full.state or "none", told_full = toldFull,
        moving = moving and moving.state or "none", told_moving = toldMoving,
        down = down and down.state or "none", told_down = toldDown, kept_after_refusals = keptAfterRefusals,
        ok = ok and ok.state, ok_reason = ok and ok.reason, fuel_after = fuelAfter, left = left,
        told_poured = CW.told(1, "Poured a CHOOH2 canister: %+15%.0 L, tank 25%.0 L"),
        gone = gone and gone.state, gone_reason = gone and gone.reason,
        canisters_end = count("char:" .. A, CAN), burned = SW.journal("^sys:chooh2%.burned$", CAN),
        told_lost = CW.told(1, "the fuel is lost"), events = #CW.events("refuel"),
        fills_left = (function() local n = 0 for _ in pairs(svc().pendingFills) do n = n + 1 end return n end)(),
        unbalanced = tostring(SW.unbalanced()),
    })
end

-- ---------------------------------------------------------------------------------------------
-- The sale pays once: the same rp_economy request again replays its receipt; a seller with no
-- canister is refused before the bar; a farmhand cannot sell (operators sell the plant's fuel).
-- ---------------------------------------------------------------------------------------------
function scenarios.sale_once()
    CW.boot({ writers = CW.WRITERS_STRICT })
    CW.watch()
    hire(1, C, "refinery", AT_COUNTER)
    hire(2, A, "farmhand", AT_COUNTER)
    local mark0 = SW.mark()
    SW.intent(1, "rp_chooh2:sell", "rp_chooh2:depot_counter")
    MH.run(2)
    local empty = SW.lastOp(1, "sell", mark0)
    local emptyRefusal = SW.refusals(1)[#SW.refusals(1)]
    SW.command("chooh2.give", { "1", CAN, "3" })
    SW.command("chooh2.give", { "2", CAN, "1" })
    MH.run(3)
    local P = svc().P
    local lastSpec
    local realSale = P.economy.sale
    P.economy.sale = function(spec) lastSpec = spec return realSale(spec) end
    local cash0 = SW.balance("cash:" .. C)
    local s1 = SW.act(1, "rp_chooh2:sell", "rp_chooh2:depot_counter", "sell")
    MH.run(2)
    local cash1 = SW.balance("cash:" .. C)
    local again, againWhy = MH.callAsync("rp_chooh2", "rp_economy", "sale", lastSpec)
    MH.run(2)
    local cash2 = SW.balance("cash:" .. C)
    P.economy.sale = realSale
    local mark2 = SW.mark()
    SW.intent(2, "rp_chooh2:sell", "rp_chooh2:depot_counter")
    MH.run(2)
    local farmhand = SW.lastOp(2, "sell", mark2)
    local farmhandRefusal = SW.refusals(2)[#SW.refusals(2)]
    return SW.result({
        empty = empty and empty.state or "none", empty_refusal = tostring(emptyRefusal),
        s1 = s1 and s1.state, paid1 = cash1 - cash0, society = SW.balance("soc:refinery"),
        again = type(again) == "table" and ("replay=" .. tostring(again.replay)) or tostring(againWhy),
        paid2 = cash2 - cash1, pockets = count("char:" .. C, CAN),
        farmhand = farmhand and farmhand.state or "none", farmhand_refusal = tostring(farmhandRefusal),
        farmhand_pockets = count("char:" .. A, CAN), sell_events = #CW.events("sell"),
        unbalanced = tostring(SW.unbalanced()),
    })
end

-- ---------------------------------------------------------------------------------------------
-- An rp_jobs without the CHOOH2 jobs: the start says which are missing and the steps answer
-- unknown_job with a sentence; the chain still boots.
-- ---------------------------------------------------------------------------------------------
function scenarios.jobs_missing()
    CW.boot({ knownJobs = { "nomade", "ferrailleur" } })
    CW.watch()
    SW.join(1, A, "Mara", AT_ROW.row1)
    MH.run(1)
    local mark = SW.mark()
    SW.intent(1, "rp_chooh2:harvest", "rp_chooh2:node_row1")
    MH.run(2)
    local op = SW.lastOp(1, "harvest", mark)
    return SW.result({
        ready = svc().ready, warning = CW.printed("WARNING: rp_jobs has no job farmhand, refinery"),
        harvest = op and op.state or "none", refusal = table.concat(SW.refusals(1), ","),
        told = CW.told(1, "no farmhand or refinery job"),
    })
end

-- ---------------------------------------------------------------------------------------------
-- The operator's console drives every step with explicit ids (no prompt aiming).
-- ---------------------------------------------------------------------------------------------
function scenarios.console()
    CW.boot()
    CW.watch()
    SW.join(1, A, "Mara", AT_ROW.row1)
    SW.command("chooh2.setup", { "1", "farmhand" })
    MH.run(1)
    SW.join(2, C, "Sol", AT_CONTROL)
    SW.command("chooh2.setup", { "2", "refinery" })
    MH.run(1)
    local mark = SW.mark()
    SW.command("chooh2.harvest", { "1", "row1" })
    local h = SW.finish(1, "harvest", 30, mark)
    SW.command("chooh2.pickup", { "1" })
    MH.until_(function() return SW.carrying(1) ~= nil end, 10)
    local picked = SW.carrying(1) ~= nil
    SW.command("chooh2.drop", { "1" })
    MH.run(2)
    local dropped = SW.carrying(1) == nil
    SW.command("chooh2.stock", { "12" })
    MH.run(2)
    mark = SW.mark()
    SW.command("chooh2.refine", { "2" })
    local r = SW.finish(2, "refine", 40, mark)
    SW.move(2, AT_OUTPUT)
    mark = SW.mark()
    SW.command("chooh2.collect", { "2" })
    local c = SW.finish(2, "collect", 30, mark)
    SW.move(2, AT_COUNTER)
    mark = SW.mark()
    SW.command("chooh2.sell", { "2" })
    local s = SW.finish(2, "sell", 30, mark)
    SW.command("chooh2.state", { "2" })
    SW.command("chooh2.status", {})
    MH.run(3)
    local nodeBefore = svc().nodes.row1.id
    SW.command("chooh2.reset", { "row1" })
    MH.run(3)
    SW.command("chooh2.clock", { "1", "off" })
    MH.run(1)
    return SW.result({
        h = h and h.state, picked = picked, dropped = dropped, r = r and r.state, c = c and c.state, s = s and s.state,
        state_receipt = CW.printed("receipt sale ch2%.sale:"), state_cash = CW.printed("cash=%d+ society refinery=%d+"),
        status = CW.printed("ready=true stashes=true crates:"), intake_line = CW.printed("intake corn=2 output canisters=0"),
        reset = CW.printed("row row1: refilled world:%S+ to 4/4"), same_node = svc().nodes.row1.id == nodeBefore,
        clock = CW.printed("duty 1 off %(farmhand%): true"),
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
