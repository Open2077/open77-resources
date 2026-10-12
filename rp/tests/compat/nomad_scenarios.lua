-- tests/compat/nomad_scenarios.lua: the W3-7 nomad smuggling run (rp_nomade) end to end, offline.
--
-- Loaded by tests/test_w3_nomad.py with the string globals ROOT_DIR, COMPAT_DIR, SYS_DIR and TX_DIR
-- (nomad_world.lua). Players act the way the open77_actions client makes them act: prompt intents
-- and the put-down key, as net events from their own seat. Every check reads durable truth from
-- the coordinator's store.

dofile(COMPAT_DIR .. "/nomad_world.lua")

local scenarios = {}

local A, B, C, COP = "acct-nomad-a", "acct-buyer-b", "acct-thief-c", "acct-cop-d"
local AT_BOARD = { x = 1790.0, y = 2252.6, z = 180.3 }
local LOAD = { { x = 1786.3, y = 2256.0, z = 180.3 }, { x = 1788.3, y = 2258.0, z = 180.3 }, { x = 1790.3, y = 2258.5, z = 180.3 },
               { x = 1792.3, y = 2257.0, z = 180.3 } }
local AT_BAY = { x = 1800.0, y = 2240.5, z = 180.2 }
local TRUCK_AT_BAY = { x = 1801.0, y = 2237.0, z = 180.2 }
-- Behind the bed of the truck parked in the bay (yaw 0): the bay prompts follow the truck there.
local AT_TAILGATE = { x = 1801.0, y = 2233.0, z = 180.2 }
local AT_STASH = { x = 1788.2, y = 2254.0, z = 180.3 }
local CK1 = { x = 905.0, y = 1900.0, z = 120.0 }      -- inside badlands_toll
local CK2 = { x = -495.0, y = 1700.0, z = 40.0 }      -- inside watson_ramp
local ROAD = { x = 300.0, y = 1800.0, z = 60.0 }      -- between the two, in no checkpoint
local TRUCK_AT_DROP = { x = -1422.5, y = 975.0, z = 23.35 }
local AT_UNLOAD = { x = -1422.5, y = 971.0, z = 23.35 }  -- behind the bed of the truck at the drop
local AT_FENCE = { x = -1418.5, y = 975.5, z = 24.25 }
local TRUCK = 701
local PLATE = "NC-NMD01"

local function svc() return NW.svc() end

-- Checkpoint chances are set per scenario: deterministic tests, not a dice game.
local function chances(badlands, watson, extra)
    return function(cfg)
        cfg.checkpoints[1].searchChance = badlands
        cfg.checkpoints[2].searchChance = watson
        if extra then extra(cfg) end
    end
end

local function nomad(pid, identifier, position)
    SW.join(pid, identifier, "player" .. pid, position or AT_BOARD)
    NW.setJob(pid, "nomade", true)
    MH.run(1)
end

local function take(pid, route)
    SW.move(pid, AT_BOARD)
    return NW.act(pid, "rp_nomade:run_" .. (route or "afterlife"), "rp_nomade:board", "run_" .. (route or "afterlife"), 30)
end

-- Carries every crate of the run (still on the ground) to the truck bay and loads it.
local function loadAll(pid, run)
    local results = {}
    for i, crate in ipairs(NW.cratesOf(run.key)) do
        if crate.state == "ground" then
            SW.move(pid, LOAD[i])
            NW.pickup(pid, crate)
            SW.move(pid, AT_TAILGATE)
            local op = NW.putdownAt(pid, "rp_nomade:truck_bay")
            results[#results + 1] = op and op.state or "none"
        end
    end
    return table.concat(results, ",")
end

local function driveTo(position, driver)
    NW.drive(TRUCK, position, driver)
    MH.run(2)
end

-- At the drop: unload one crate and hand it to the fence. Returns unload, sale states.
local function deliverOne(pid)
    SW.move(pid, AT_UNLOAD)
    local un = NW.act(pid, "rp_nomade:unload", "rp_nomade:unload_afterlife", "unload", 30)
    MH.until_(function() return SW.carrying(pid) ~= nil end, 10)
    SW.move(pid, AT_FENCE)
    local sale = NW.putdownAt(pid, "rp_nomade:fence_afterlife")
    MH.run(1)
    return un and un.state, sale and sale.state, sale and sale.reason
end

local function count(account, item) return SW.count(account, item or "nomad_contraband") end
local function tokenAt(crate) return (SW.store().instances[crate.iid] or {}).container end

-- ---------------------------------------------------------------------------------------------
-- Happy path: the stash is supplied at boot, a nomad takes the Afterlife run (3 crates), carries
-- and loads them into their truck, drives past two checkpoints (waved through), unloads at the
-- drop and hands every crate to the fence. Strict writers: the two-party grants carry rp_cargo
-- and rp_economy into the crates.
-- ---------------------------------------------------------------------------------------------
function scenarios.happy_path()
    NW.boot({ writers = NW.WRITERS_STRICT, config = chances(0, 0) })
    SW.watch()
    NW.watchFixer()
    MH.run(6)                                           -- the first sweep supplies the stash
    local stash0 = count("stash:nmd.aldecaldos:goods")
    local bootLines = ("%d/%d/%d"):format(NW.printed("coordinator ready %(store="), NW.printed("items defined through rp_inventory: 2"),
        NW.printed("ready: 2 route%(s%), 2 checkpoint%(s%)"))
    nomad(1, A, AT_BOARD)
    NW.truck(TRUCK, PLATE, A, TRUCK_AT_BAY)
    local t = take(1, "afterlife")
    local run = NW.runOf(A)
    local crates = run and NW.cratesOf(run.key) or {}
    local stash1 = count("stash:nmd.aldecaldos:goods")
    local inCrates, tokensHome, placed = 0, 0, 0
    for _, crate in ipairs(crates) do
        inCrates = inCrates + count(crate.id)
        if tokenAt(crate) == crate.id then tokensHome = tokensHome + 1 end
        if crate.itemId then placed = placed + 1 end
    end
    local navTaken = NW.nav(1)
    MH.run(1.5)
    local function bayAt()
        local p = NW.svc().bayDefs.truck_bay.def.position
        return ("%.1f,%.1f"):format(p.x, p.y)
    end
    local bayWithTruck = bayAt()
    local loads = loadAll(1, run)
    local inBed = 0
    for _, crate in ipairs(crates) do if tokenAt(crate) == "veh:" .. PLATE .. ":cargo" then inBed = inBed + 1 end end
    local navLoaded = NW.nav(1)
    driveTo(ROAD, 1)
    local bayEmpty = bayAt()
    driveTo(CK1, 1)
    MH.run(2)
    driveTo(ROAD, 1)
    driveTo(CK2, 1)
    MH.run(2)
    driveTo(TRUCK_AT_DROP, 1)
    MH.run(2)
    local arrived = NW.told(1, "You made it to Afterlife street")
    local cash0 = SW.balance("cash:" .. A)
    local u1, s1, r1 = deliverOne(1)
    local cash1 = SW.balance("cash:" .. A)
    local u2, s2 = deliverOne(1)
    local u3, s3 = deliverOne(1)
    MH.run(3)
    local closed = 0
    for _, crate in ipairs(crates) do if SW.store().containers[crate.id] == nil then closed = closed + 1 end end
    local retired = 0
    for _, crate in ipairs(crates) do if tokenAt(crate) == "sys:nomad" then retired = retired + 1 end end
    local ok, detail = NW.conserved()
    local deliver = NW.fixer("deliver")
    local pickup = NW.fixer("pickup")
    local passed = NW.fixer("checkpoint_passed")
    local lastRun = run
    return NW.result({
        bay_with_truck = bayWithTruck, bay_empty = bayEmpty,
        boot_lines = bootLines, stash0 = stash0, take = t and t.state, take_reason = t and t.reason,
        crates = #crates, stash_taken = stash0 - stash1, in_crates = inCrates, tokens_home = tokensHome, placed = placed,
        nav_taken = navTaken and navTaken.phase, nav_taken_route = navTaken and tostring(navTaken.route),
        loads = loads, in_bed = inBed, nav_loaded_route = navLoaded and tostring(navLoaded.route),
        passes = svc().stats.passes, arrived = arrived,
        u1 = u1, s1 = s1, r1 = r1, paid1 = cash1 - cash0, u2 = u2, s2 = s2, u3 = u3, s3 = s3,
        paid_total = SW.balance("cash:" .. A) - cash0, society = SW.balance("soc:nomade"),
        closed = closed, retired = retired, run_ended = lastRun and lastRun.ended,
        fixer = NW.fixerKinds(), deliver_job = deliver and deliver.job, deliver_pay = deliver and deliver.data.pay,
        pickup_ref = pickup and pickup.ref, pickup_player = pickup and pickup.playerId,
        passed_ref = passed and passed.ref, nav_end = tostring(NW.nav(1)),
        conserved = ok, conservation = detail, unbalanced = tostring(SW.unbalanced()),
    })
end

-- ---------------------------------------------------------------------------------------------
-- A checkpoint search (chance 100): the goods of the run in the truck go to the evidence stash in
-- ONE operation, the driver is fined and gets heat, the run ends confiscated, the fixer hears it.
-- The next checkpoint finds nothing to do; the emptied crates are thrown away at unloading.
-- ---------------------------------------------------------------------------------------------
function scenarios.checkpoint_search()
    NW.boot({ writers = NW.WRITERS_STRICT, config = chances(100, 100, function(cfg) cfg.search.fine = 300 end) })
    SW.watch()
    NW.watchFixer()
    MH.run(6)
    nomad(1, A, AT_BOARD)
    NW.truck(TRUCK, PLATE, A, TRUCK_AT_BAY)
    take(1, "afterlife")
    local run = NW.runOf(A)
    local crates = NW.cratesOf(run.key)
    loadAll(1, run)
    local cash0, ncpd0 = SW.balance("cash:" .. A), SW.balance("soc:ncpd")
    MH.players[1].inVehicle = true
    driveTo(ROAD, 1)
    driveTo(CK1, 1)
    MH.run(3)
    local evidence = count("stash:ncpd.evidence:seized")
    local left = 0
    for _, crate in ipairs(crates) do left = left + count(crate.id) end
    local inBed = 0
    for _, crate in ipairs(crates) do if tokenAt(crate) == "veh:" .. PLATE .. ":cargo" then inBed = inBed + 1 end end
    local seizeOps = 0
    for opId, row in pairs(SW.store().ops) do
        if row.state == "committed" and opId:find("^nmd%.seize:") then seizeOps = seizeOps + 1 end
    end
    local conf = NW.fixer("confiscated")
    local ended = run.ended
    -- The second checkpoint: nothing left to search, no second event, no second fine.
    driveTo(ROAD, 1)
    driveTo(CK2, 1)
    MH.run(3)
    local fixerAfterCk2 = NW.fixerKinds()
    -- Determinism: the same run meets the same answer at the same checkpoint.
    local M = NW.model()
    local same = true
    for i = 1, 20 do
        local k = "lab-run-" .. i
        if M.searched(k, "watson_ramp", 50) ~= M.searched(k, "watson_ramp", 50) then same = false end
    end
    local yes = 0
    for i = 1, 200 do if M.searched("lab-run-" .. i, "badlands_toll", 25) then yes = yes + 1 end end
    -- At the drop: every crate in the bed is empty and is thrown away.
    MH.players[1].inVehicle = false
    driveTo(TRUCK_AT_DROP, nil)
    SW.move(1, AT_UNLOAD)
    local dumps = {}
    for _ = 1, 3 do
        local op = NW.act(1, "rp_nomade:unload", "rp_nomade:unload_afterlife", "unload", 30)
        dumps[#dumps + 1] = op and op.state or "none"
        MH.run(1)
    end
    local carrying = SW.carrying(1) ~= nil
    local closed = 0
    for _, crate in ipairs(crates) do if SW.store().containers[crate.id] == nil then closed = closed + 1 end end
    local ok, detail = NW.conserved()
    return NW.result({
        evidence = evidence, left = left, in_bed = inBed, seize_ops = seizeOps,
        fined = cash0 - SW.balance("cash:" .. A), ncpd = SW.balance("soc:ncpd") - ncpd0,
        wanted = tostring(MH.shared.world.wanted[1]), record = MH.shared.ncpd.records[1] and MH.shared.ncpd.records[1].kind,
        told = NW.told(1, "NCPD search"), conf_by = conf and conf.data.by, conf_crates = conf and conf.data.crates,
        conf_ck = conf and conf.data.checkpoint, conf_ref = conf and conf.ref, ended = ended,
        fixer = fixerAfterCk2, same = same, roll_share = yes,
        dumps = table.concat(dumps, ","), carrying = carrying, closed = closed, told_dump = NW.told(1, "empty crate"),
        nav = tostring(NW.nav(1)), conserved = ok, conservation = detail, unbalanced = tostring(SW.unbalanced()),
    })
end

-- The fine cannot be paid: a warrant (rp_ncpd) and the reason in chat; the seizure still stands.
function scenarios.unpaid_fine()
    NW.boot({ config = chances(100, 0, function(cfg) cfg.search.fine = 5000 end) })
    SW.watch()
    MH.run(6)
    nomad(1, A, AT_BOARD)
    NW.truck(TRUCK, PLATE, A, TRUCK_AT_BAY)
    take(1, "afterlife")
    local run = NW.runOf(A)
    loadAll(1, run)
    local cash0 = SW.balance("cash:" .. A)
    driveTo(CK1, 1)
    MH.run(3)
    local w = MH.shared.ncpd.warrants[1]
    return NW.result({
        evidence = count("stash:ncpd.evidence:seized"), cash_kept = SW.balance("cash:" .. A) == cash0,
        warrant = w and w.level, warrant_reason = w and w.reason, told = NW.told(1, "unpaid"),
        wanted = tostring(MH.shared.world.wanted[1]),
    })
end

-- ---------------------------------------------------------------------------------------------
-- A player NCPD officer: with a warrant on the plate (authority), with the driver's consent, and
-- refused. Each search is an open77_actions bar; the confiscation is reserved before it and
-- committed at its end.
-- ---------------------------------------------------------------------------------------------
local AT_TRUCK_SIDE = { x = 1799.0, y = 2238.0, z = 180.2 }
local NEAR_COP = { x = 1800.5, y = 2239.5, z = 180.2 }

local function officerSearch(pid)
    local mark = SW.mark()
    MH.command("nomad", pid, { "search" })
    MH.run(1)
    return mark
end

local function dumpBed(pid)
    SW.move(pid, AT_BAY)
    for _ = 1, 4 do
        MH.command("nomad", pid, { "unload" })
        MH.run(2)
    end
end

function scenarios.officer_search()
    NW.boot({ writers = NW.WRITERS_STRICT, config = chances(0, 0) })
    SW.watch()
    NW.watchFixer()
    MH.run(6)
    nomad(1, A, AT_BOARD)
    SW.join(4, COP, "Officer", AT_TRUCK_SIDE)
    NW.truck(TRUCK, PLATE, A, TRUCK_AT_BAY)
    -- Not police: refused.
    SW.join(5, "acct-civ-e", "Civ", AT_TRUCK_SIDE)
    MH.command("nomad", 5, { "search" })
    MH.run(1)
    local civ = NW.told(5, "Only an NCPD officer")
    NW.setJob(4, "ncpd", true)
    -- 1. A warrant on the plate: the officer searches at once.
    take(1, "afterlife")
    local run1 = NW.runOf(A)
    loadAll(1, run1)
    MH.shared.garage.rows[PLATE].warrant = true
    SW.move(1, AT_BOARD)
    local mark = officerSearch(4)
    local s1 = SW.finish(4, "ncpd_search", 30, mark)
    local ev1 = count("stash:ncpd.evidence:seized")
    local conf = NW.fixer("confiscated")
    local record = MH.shared.ncpd.records[1]
    MH.shared.garage.rows[PLATE].warrant = false
    dumpBed(1)
    -- 2. No warrant, the run's nomad is next to the officer and consents.
    SW.command("nomad.stock", { "12" })
    MH.run(2)
    take(1, "afterlife")
    local run2 = NW.runOf(A)
    loadAll(1, run2)
    SW.move(1, NEAR_COP)
    mark = officerSearch(4)
    local asked = NW.told(1, "asks to search the truck")
    NW.respond(1, true)
    local s2 = SW.finish(4, "ncpd_search", 30, mark)
    local ev2 = count("stash:ncpd.evidence:seized")
    dumpBed(1)
    -- 3. No warrant, the nomad declines: nothing is searched, the goods stay in the crates.
    SW.command("nomad.stock", { "12" })
    MH.run(2)
    take(1, "afterlife")
    local run3 = NW.runOf(A)
    loadAll(1, run3)
    SW.move(1, NEAR_COP)
    mark = officerSearch(4)
    NW.respond(1, false)
    MH.run(2)
    local declined = NW.told(4, "refused the search")
    local searched3 = SW.lastOp(4, "ncpd_search", mark) ~= nil
    local kept = 0
    for _, crate in pairs(NW.cratesOf(run3.key)) do kept = kept + count(crate.id) end
    -- 4. No warrant and nobody to ask (the nomad walked away).
    SW.move(1, AT_BOARD)
    MH.command("nomad", 4, { "search" })
    MH.run(1)
    local noConsent = NW.told(4, "has to consent")
    local ok, detail = NW.conserved()
    return NW.result({
        civ = civ, s1 = s1 and s1.state, s1_reason = s1 and s1.reason, ev1 = ev1,
        conf_by = conf and conf.data.by, conf_officer = conf and conf.data.officer, run1 = run1.ended,
        record = record and record.kind, record_by = record and record.by,
        asked = asked, s2 = s2 and s2.state, ev2 = ev2, run2 = run2.ended,
        declined = declined, searched3 = searched3, kept = kept, run3_live = run3.ended == nil and run3.failed == nil,
        no_consent = noConsent, conserved = ok, conservation = detail, unbalanced = tostring(SW.unbalanced()),
    })
end

-- ---------------------------------------------------------------------------------------------
-- A crate handed to another player: the crate on the ground, a consented give, ONE sale (goods
-- into the buyer's pockets, the price split between the run's nomad and the camp). A declined
-- offer and a buyer who cannot pay move nothing.
-- ---------------------------------------------------------------------------------------------
function scenarios.player_sale()
    NW.boot({ writers = NW.WRITERS_STRICT, config = chances(0, 0) })
    SW.watch()
    NW.watchFixer()
    MH.run(6)
    nomad(1, A, AT_BOARD)
    take(1, "afterlife")
    local run = NW.runOf(A)
    local crates = NW.cratesOf(run.key)
    local SPOT = { x = 1786.3, y = 2250.0, z = 180.3 }
    SW.join(2, B, "Buyer", { x = SPOT.x + 1.5, y = SPOT.y, z = SPOT.z })
    -- Crate 1 put down next to the buyer (G).
    SW.move(1, LOAD[1])
    NW.pickup(1, crates[1])
    SW.move(1, SPOT, 0.0)
    SW.putdownKey(1)
    MH.until_(function() return SW.carrying(1) == nil end, 10)
    MH.run(1)
    -- A declined offer.
    MH.command("nomad", 1, { "sell", "2", "400" })
    MH.run(1)
    local offered = NW.told(2, "offers you a crate")
    NW.respond(2, false)
    MH.run(2)
    local declined = NW.told(1, "declined")
    local afterDecline = count(crates[1].id)
    -- A buyer who cannot pay (500 cash, 900 asked).
    MH.command("nomad", 1, { "sell", "2", "900" })
    MH.run(1)
    NW.respond(2, true)
    MH.run(8)
    local broke = NW.told(2, "Not enough eddies")
    local afterBroke = count(crates[1].id)
    -- The real sale.
    local cashA, cashB, soc = SW.balance("cash:" .. A), SW.balance("cash:" .. B), SW.balance("soc:nomade")
    MH.command("nomad", 1, { "sell", "2", "400" })
    MH.run(1)
    NW.respond(2, true)
    MH.run(8)
    local deliver = NW.fixer("deliver")
    local ok, detail = NW.conserved()
    -- Out of range prices are refused before anything is offered.
    MH.command("nomad", 1, { "sell", "2", "99999" })
    MH.run(1)
    return NW.result({
        offered = offered, declined = declined, after_decline = afterDecline, broke = broke, after_broke = afterBroke,
        pockets = count("char:" .. B), paid_seller = SW.balance("cash:" .. A) - cashA,
        paid_buyer = cashB - SW.balance("cash:" .. B), camp = SW.balance("soc:nomade") - soc,
        crate_closed = SW.store().containers[crates[1].id] == nil, token = tokenAt(crates[1]),
        deliver_buyer = deliver and deliver.data.buyer, deliver_pay = deliver and deliver.data.pay,
        bad_price = NW.told(1, "Name a price"), items = SW.items(crates[1].id),
        conserved = ok, conservation = detail, unbalanced = tostring(SW.unbalanced()),
    })
end

-- ---------------------------------------------------------------------------------------------
-- The deadline passes: the run fails (told, navigation back to camp), the fence pays hot prices
-- only (no camp cut, no delivery counted), the crew returns the rest to the stash, and the
-- failed run never blocks the next one.
-- ---------------------------------------------------------------------------------------------
function scenarios.deadline()
    NW.boot({ writers = NW.WRITERS_STRICT, config = chances(0, 0) })
    SW.watch()
    NW.watchFixer()
    MH.run(6)
    nomad(1, A, AT_BOARD)
    NW.truck(TRUCK, PLATE, A, TRUCK_AT_BAY)
    take(1, "afterlife")
    local run = NW.runOf(A)
    local crates = NW.cratesOf(run.key)
    loadAll(1, run)
    SW.command("nomad.op.expire", { "1" })
    MH.run(3)
    local failed = run.failed
    local told = NW.told(1, "Too late")
    local nav = NW.nav(1)
    -- Hot goods at the fence.
    driveTo(TRUCK_AT_DROP, 1)
    local cash0, soc0 = SW.balance("cash:" .. A), SW.balance("soc:nomade")
    local u, s = deliverOne(1)
    local hot = SW.balance("cash:" .. A) - cash0
    local socDelta = SW.balance("soc:nomade") - soc0
    -- Back at the camp: the other two crates go back into the stash.
    driveTo(TRUCK_AT_BAY, nil)
    local stash0 = count("stash:nmd.aldecaldos:goods")
    local returns = {}
    for _ = 1, 2 do
        SW.move(1, AT_BAY)
        MH.command("nomad", 1, { "unload" })
        MH.until_(function() return SW.carrying(1) ~= nil end, 10)
        SW.move(1, AT_STASH)
        local op = NW.putdownAt(1, "rp_nomade:return_bay")
        returns[#returns + 1] = op and op.state or "none"
    end
    MH.run(2)
    local stashBack = count("stash:nmd.aldecaldos:goods") - stash0
    local ended = run.ended
    -- A new run is allowed at once.
    local again = take(1, "afterlife")
    local ok, detail = NW.conserved()
    return NW.result({
        failed = failed, told = told, nav_phase = nav and nav.phase, nav_route = nav and tostring(nav.route),
        unload = u, sale = s, hot = hot, soc_delta = socDelta, returns = table.concat(returns, ","), stash_back = stashBack,
        ended = ended, again = again and again.state, fixer = NW.fixerKinds(),
        closed = (SW.store().containers[crates[1].id] == nil and SW.store().containers[crates[2].id] == nil
            and SW.store().containers[crates[3].id] == nil),
        conserved = ok, conservation = detail, unbalanced = tostring(SW.unbalanced()),
    })
end

-- ---------------------------------------------------------------------------------------------
-- Theft: a crate on the ground is lifted by somebody outside the crew: the run fails, its nomad is
-- told; the thief can fence it hot. With `pickupBy = "crew"` the thief cannot even lift it.
-- ---------------------------------------------------------------------------------------------
function scenarios.theft()
    NW.boot({ writers = NW.WRITERS_STRICT, config = chances(0, 0) })
    SW.watch()
    NW.watchFixer()
    MH.run(6)
    nomad(1, A, AT_BOARD)
    take(1, "afterlife")
    local run = NW.runOf(A)
    local crates = NW.cratesOf(run.key)
    SW.join(3, C, "Thief", LOAD[1])
    local lifted = NW.pickup(3, crates[1]) ~= nil
    MH.run(2)
    local failed = run.failed
    local toldOwner = NW.told(1, "Someone else is carrying")
    SW.move(3, AT_FENCE)
    local cash0 = SW.balance("cash:" .. C)
    local sale = NW.putdownAt(3, "rp_nomade:fence_afterlife")
    MH.run(2)
    local hot = SW.balance("cash:" .. C) - cash0
    -- The owner can still return the other crates.
    SW.move(1, LOAD[2])
    NW.pickup(1, crates[2])
    SW.move(1, AT_STASH)
    local ret = NW.putdownAt(1, "rp_nomade:return_bay")
    local ok, detail = NW.conserved()
    return NW.result({
        lifted = lifted, failed = failed, told_owner = toldOwner, sale = sale and sale.state, hot = hot,
        fixer = NW.fixerKinds(), ret = ret and ret.state, conserved = ok, conservation = detail,
    })
end

-- A crate returned to the stash, then a restart: the run is rebuilt from its open crates, and
-- the returned one (closed) is still counted and named (live 2026-10-13: "gone", "returned 0").
function scenarios.tally_survives_restart()
    NW.boot({ writers = NW.WRITERS_STRICT, config = chances(0, 0) })
    SW.watch()
    MH.run(6)
    nomad(1, A, AT_BOARD)
    NW.truck(TRUCK, PLATE, A, TRUCK_AT_BAY)
    take(1, "afterlife")
    local run = NW.runOf(A)
    local key = run.key
    local crates = NW.cratesOf(key)
    SW.move(1, LOAD[1])
    NW.pickup(1, crates[1])
    SW.move(1, AT_STASH)
    local ret = NW.putdownAt(1, "rp_nomade:return_bay")
    local before = NW.svc():runSummary(A) or {}
    local keep = NW.keep()
    NW.boot({ keep = keep, writers = NW.WRITERS_STRICT, config = chances(0, 0) })
    SW.watch()
    nomad(1, A, AT_BOARD)
    MH.run(2)
    local after = NW.svc():runSummary(A) or {}
    local r = NW.svc().runs[key]
    -- The same return replayed (an operation the coordinator answers again) counts once.
    if r then NW.svc():noteOutcome(r, { i = 1 }, "returned") end
    return NW.result({
        ret = ret and ret.state, returned_before = before.returned, where_before = (before.where or {})[1],
        returned_after = after.returned, where_after = (after.where or {})[1],
        replayed = r and r.returned, left = after.left,
    })
end

function scenarios.crew_only()
    NW.boot({ config = chances(0, 0, function(cfg) cfg.crate.pickupBy = "crew" end) })
    SW.watch()
    MH.run(6)
    nomad(1, A, AT_BOARD)
    take(1, "afterlife")
    local run = NW.runOf(A)
    local crates = NW.cratesOf(run.key)
    SW.join(3, C, "Thief", LOAD[1])
    SW.intent(3, "open77_actions:carry_pickup", "item:" .. tostring(crates[1].itemId))
    MH.run(3)
    local thiefCarries = SW.carrying(3) ~= nil
    local refused = table.concat(SW.refusals(3), ",")
    -- A nomad of the crew (not the run's owner) may lift it: no theft.
    SW.join(6, "acct-crew-f", "Crew", LOAD[1])
    NW.setJob(6, "nomade", true)
    local crewLift = NW.pickup(6, crates[1]) ~= nil
    return NW.result({
        thief_carries = thiefCarries, refused = refused, told = NW.told(3, "Only the crew"),
        crew_lift = crewLift, failed = tostring(run.failed),
    })
end

-- ---------------------------------------------------------------------------------------------
-- Disconnect and restart: crates in the bed, on the ground where they were put down, and in hands
-- at the moment the server dies all come back from the coordinator and open77_containers; the run
-- (owner, route, deadline, checkpoints passed) is rebuilt; everything delivers afterwards.
-- ---------------------------------------------------------------------------------------------
function scenarios.restart()
    NW.boot({ writers = NW.WRITERS_STRICT, config = chances(0, 0) })
    SW.watch()
    NW.watchFixer()
    MH.run(6)
    nomad(1, A, AT_BOARD)
    NW.truck(TRUCK, PLATE, A, TRUCK_AT_BAY)
    take(1, "afterlife")
    local run = NW.runOf(A)
    local key, deadline = run.key, run.deadline
    local crates = NW.cratesOf(key)
    -- Crate 1 in the bed.
    SW.move(1, LOAD[1])
    NW.pickup(1, crates[1])
    SW.move(1, AT_TAILGATE)
    NW.putdownAt(1, "rp_nomade:truck_bay")
    -- Crate 2 carried, then the player disconnects: dropped at their feet, durable.
    SW.move(1, LOAD[2])
    NW.pickup(1, crates[2])
    local DROP = { x = 1795.0, y = 2245.0, z = 180.2 }
    SW.move(1, DROP, 0.0)
    SW.disconnect(1)
    MH.run(3)
    local c2 = NW.svc().crates[crates[2].id]
    local droppedAt = c2 and c2.position and ("%.1f,%.1f"):format(c2.position.x, c2.position.y)
    nomad(1, A, AT_BOARD)
    local navBack = NW.nav(1)
    -- The truck passes the first checkpoint (once), then crate 3 is in hands when the server dies.
    driveTo(CK1, 1)
    MH.run(2)
    driveTo(TRUCK_AT_BAY, nil)
    SW.move(1, LOAD[3])
    NW.pickup(1, crates[3])
    local _, passesBefore = NW.fixerKinds():gsub("checkpoint_passed", "")
    local keep = NW.keep()
    NW.boot({ keep = keep, writers = NW.WRITERS_STRICT, config = chances(0, 0) })
    SW.watch()
    NW.watchFixer()
    nomad(1, A, AT_BOARD)
    NW.truck(TRUCK, PLATE, A, TRUCK_AT_BAY)
    MH.run(2)
    local s = NW.svc()
    local r = s.runs[key]
    local states = {}
    for i = 1, 3 do
        local c = s.crates[crates[i].id]
        states[i] = c and (c.state .. (c.plate and (":" .. c.plate) or "")) or "missing"
    end
    local c2b = s.crates[crates[2].id]
    local c3b = s.crates[crates[3].id]
    local at2 = c2b and c2b.position and ("%.1f,%.1f"):format(c2b.position.x, c2b.position.y)
    local at3 = c3b and c3b.position and ("%.1f,%.1f"):format(c3b.position.x, c3b.position.y)
    local navAfter = NW.nav(1)
    -- The first checkpoint again: already passed, nothing new.
    driveTo(CK1, 1)
    MH.run(2)
    driveTo(TRUCK_AT_BAY, nil)
    local repassed = NW.fixer("checkpoint_passed") ~= nil
    -- Everything delivers.
    SW.move(1, { x = c2b.position.x + 0.5, y = c2b.position.y, z = c2b.position.z })
    NW.pickup(1, c2b)
    SW.move(1, AT_TAILGATE)
    local l2 = NW.putdownAt(1, "rp_nomade:truck_bay")
    SW.move(1, LOAD[3])
    NW.pickup(1, c3b)
    SW.move(1, AT_TAILGATE)
    local l3 = NW.putdownAt(1, "rp_nomade:truck_bay")
    driveTo(TRUCK_AT_DROP, 1)
    local cash0 = SW.balance("cash:" .. A)
    local sales = {}
    for _ = 1, 3 do
        local _, sale = deliverOne(1)
        sales[#sales + 1] = sale or "none"
    end
    local ok, detail = NW.conserved()
    return NW.result({
        dropped_at = droppedAt, nav_back = navBack and navBack.phase, passes_before = passesBefore,
        run_back = r ~= nil, same_deadline = r and r.deadline == deadline, same_owner = r and r.owner == A,
        passed_kept = r and r.passed.badlands_toll == true,
        states = table.concat(states, ","), at2 = at2, at3 = at3, nav_after = navAfter and navAfter.phase,
        repassed = repassed, l2 = l2 and l2.state, l3 = l3 and l3.state, sales = table.concat(sales, ","),
        paid = SW.balance("cash:" .. A) - cash0, ended = r and r.ended,
        conserved = ok, conservation = detail, unbalanced = tostring(SW.unbalanced()),
    })
end

-- ---------------------------------------------------------------------------------------------
-- The truck is wrecked (health 0) or taken away (impounded): the run fails; the goods stay in the
-- crates (nothing is lost or created).
-- ---------------------------------------------------------------------------------------------
function scenarios.truck_lost()
    NW.boot({ config = chances(0, 0) })
    SW.watch()
    MH.run(6)
    nomad(1, A, AT_BOARD)
    NW.truck(TRUCK, PLATE, A, TRUCK_AT_BAY)
    take(1, "afterlife")
    local run = NW.runOf(A)
    loadAll(1, run)
    MH.shared.world.vehicles[TRUCK].health = 0.0
    MH.run(3)
    local wrecked = run.failed
    local toldWreck = NW.told(1, "wrecked")
    -- A second nomad, a second truck, impounded.
    SW.command("nomad.stock", { "12" })
    MH.run(2)
    SW.join(6, "acct-nomad-f", "Nomad F", AT_BOARD)
    NW.setJob(6, "nomade", true)
    MH.shared.world.vehicles[TRUCK] = nil
    NW.truck(702, "NC-NMD02", "acct-nomad-f", TRUCK_AT_BAY)
    take(6, "afterlife")
    local run2 = NW.runOf("acct-nomad-f")
    loadAll(6, run2)
    NW.despawn(702, "impounded")
    MH.run(2)
    local goods = 0
    for _, crate in pairs(NW.cratesOf(run.key)) do goods = goods + count(crate.id) end
    local ok, detail = NW.conserved()
    return NW.result({
        wrecked = wrecked, told_wreck = toldWreck, impounded = run2 and run2.failed, goods_kept = goods,
        conserved = ok, conservation = detail,
    })
end

-- ---------------------------------------------------------------------------------------------
-- Refusals reach the player, and nothing is held after them.
-- ---------------------------------------------------------------------------------------------
function scenarios.refusals()
    NW.boot({ writers = NW.WRITERS_STRICT, config = chances(0, 0, function(cfg) cfg.restock.amount = 0 end) })
    SW.watch()
    MH.run(6)
    -- No job, then off duty.
    SW.join(1, A, "A", AT_BOARD)
    take(1, "afterlife")
    local noJob = table.concat(SW.refusals(1), ",")
    NW.setJob(1, "nomade", false)
    take(1, "afterlife")
    local offDuty = table.concat(SW.refusals(1), ",")
    SW.sync("salvage_probe", "rp_jobs", "setDuty", 1, true, { job = "nomade" })
    -- The camp's stash is empty: refused at the reservation, the crates it opened are closed again.
    local empty = take(1, "afterlife")
    MH.run(2)
    local openAfterEmpty = 0
    for _ in pairs(NW.svc().crates) do openAfterEmpty = openAfterEmpty + 1 end
    local worldRows = 0
    for id, c in pairs(SW.store().containers) do
        if id:match("^world:") and (c.capacityG or 0) > 0 then worldRows = worldRows + 1 end
    end
    local toldEmpty = NW.told(1, "nothing to move")
    -- Stock, take a run, then try a second one.
    SW.command("nomad.stock", { "24" })
    MH.run(2)
    local first = take(1, "afterlife")
    local mark = SW.mark()
    take(1, "kabuki")
    local second = SW.lastOp(1, "run_kabuki", mark)
    local refusedSecond = SW.refusals(1)
    local toldRunning = NW.told(1, "already have a run")
    -- No truck at the bay: the load is refused and the crate stays in the hands.
    local run = NW.runOf(A)
    local crates = NW.cratesOf(run.key)
    SW.move(1, LOAD[1])
    NW.pickup(1, crates[1])
    SW.move(1, AT_BAY)
    local noTruck = NW.putdownAt(1, "rp_nomade:truck_bay")
    local stillCarrying = SW.carrying(1) ~= nil
    -- Somebody else's truck: no key. The bay prompt follows it behind its bed.
    NW.truck(TRUCK, PLATE, "acct-other", TRUCK_AT_BAY)
    MH.run(1.5)
    SW.move(1, AT_TAILGATE)
    local noKey = NW.putdownAt(1, "rp_nomade:truck_bay")
    local stillCarrying2 = SW.carrying(1) ~= nil
    return NW.result({
        no_job = noJob, off_duty = offDuty, second_refused = refusedSecond[#refusedSecond],
        empty = empty and empty.state, empty_reason = empty and empty.reason, open_after_empty = openAfterEmpty,
        world_rows = worldRows, told_empty = toldEmpty,
        first = first and first.state, second_started = second ~= nil,
        told_running = toldRunning, no_truck = noTruck and noTruck.reason, carrying = stillCarrying,
        no_key = noKey and noKey.reason, carrying2 = stillCarrying2,
    })
end

-- ---------------------------------------------------------------------------------------------
-- Exactly once: a replayed take commit moves nothing; a replayed sale pays once; a sale that
-- committed just before a crash (its crate not retired yet) is found at boot and the crate never
-- comes back.
-- ---------------------------------------------------------------------------------------------
function scenarios.exactly_once()
    NW.boot({ config = chances(0, 0) })
    SW.watch()
    MH.run(6)
    nomad(1, A, AT_BOARD)
    NW.truck(TRUCK, PLATE, A, TRUCK_AT_BAY)
    take(1, "afterlife")
    local run = NW.runOf(A)
    local crates = NW.cratesOf(run.key)
    local stash0 = count("stash:nmd.aldecaldos:goods")
    local txOpId = "nmd.run:" .. run.key
    local replay = MH.callAsync("rp_nomade", "open77_transactions", "commit", txOpId)
    local stash1 = count("stash:nmd.aldecaldos:goods")
    local P = NW.svc().P
    local lastSpec
    local realSale = P.economy.sale
    P.economy.sale = function(spec) lastSpec = spec return realSale(spec) end
    loadAll(1, run)
    driveTo(TRUCK_AT_DROP, 1)
    local cash0 = SW.balance("cash:" .. A)
    local _, s1 = deliverOne(1)
    local cash1 = SW.balance("cash:" .. A)
    local again = MH.callAsync("rp_nomade", "rp_economy", "sale", lastSpec)
    MH.run(2)
    local cash2 = SW.balance("cash:" .. A)
    -- Crate 2: the sale commits, the token retire that follows never reaches the store, and the
    -- server dies before the sweep retries it.
    SW.move(1, AT_UNLOAD)
    NW.act(1, "rp_nomade:unload", "rp_nomade:unload_afterlife", "unload", 30)
    MH.until_(function() return SW.carrying(1) ~= nil end, 10)
    SW.move(1, AT_FENCE)
    SW.store().faults = { false, "unreachable_before" }
    local sale2 = NW.putdownAt(1, "rp_nomade:fence_afterlife")
    local s2 = sale2 and sale2.state
    local cash3 = SW.balance("cash:" .. A)
    local pending = NW.svc().crates[crates[2].id] ~= nil
    local keep = NW.keep()
    NW.boot({ keep = keep, config = chances(0, 0) })
    SW.watch()
    nomad(1, A, AT_FENCE)
    MH.run(8)
    return NW.result({
        replay = type(replay) == "table" and tostring(replay.replay) or tostring(replay), stash_same = stash0 == stash1,
        s1 = s1, paid1 = cash1 - cash0, again = type(again) == "table" and tostring(again.replay) or tostring(again),
        paid_again = cash2 - cash1, s2 = s2, paid2 = cash3 - cash2, pending = pending,
        cash_after_restart = SW.balance("cash:" .. A) == cash3,
        crate2_known = NW.svc().crates[crates[2].id] ~= nil, crate2_row = SW.store().containers[crates[2].id] ~= nil,
        crate2_items = SW.items(crates[2].id), unbalanced = tostring(SW.unbalanced()),
    })
end

-- ---------------------------------------------------------------------------------------------
-- The lab console drives the loop with explicit ids (no prompt aiming).
-- ---------------------------------------------------------------------------------------------
function scenarios.operator_console()
    NW.boot({ config = chances(0, 0) })
    SW.watch()
    NW.watchFixer()
    MH.run(6)
    SW.join(1, A, "A", AT_BOARD)
    SW.command("nomad.op.setup", { "1" })
    MH.run(1)
    NW.truck(TRUCK, PLATE, A, TRUCK_AT_BAY)
    local mark = SW.mark()
    SW.command("nomad.op.take", { "1", "afterlife" })
    local t = SW.finish(1, "run_afterlife", 30, mark)
    local run = NW.runOf(A)
    SW.move(1, LOAD[1])
    SW.command("nomad.op.pickup", { "1" })
    MH.until_(function() return SW.carrying(1) ~= nil end, 10)
    SW.move(1, { x = 1800.0, y = 2238.0, z = 180.2 })
    mark = SW.mark()
    SW.command("nomad.op.load", { "1" })
    local l = SW.finish(1, "carry_putdown", 30, mark)
    SW.command("nomad.op.checkpoint", { "1", "watson_ramp", "search" })
    MH.run(3)
    local seized = count("stash:ncpd.evidence:seized")
    SW.command("nomad.status", {})
    SW.command("nomad.stock", { "5" })
    MH.run(2)
    return NW.result({
        take = t and t.state, load = l and l.state, seized = seized, fixer = NW.fixerKinds(),
        status = NW.printed("ready=true stash="), run_line = NW.printed("owner=acct%-nomad%-a"),
        stock = NW.printed("stash %+5: now"), setup = NW.printed("setDuty 1 on: true"),
    })
end

-- ---------------------------------------------------------------------------------------------
-- The pure rules (server/model.lua), without a host.
-- ---------------------------------------------------------------------------------------------
function scenarios.model_rules()
    dofile(ROOT_DIR .. "/rp_nomade/server/model.lua")
    local M = NomadModel
    local live = M.fenceQuote(600, true, 0.2, 0.5)
    local hot = M.fenceQuote(600, false, 0.2, 0.5)
    local refused, why = M.fenceQuote(600, false, 0.2, 0)
    local p1 = M.playerQuote(400, true, 0.2)
    local p2 = M.playerQuote(400, false, 0.2)
    local key = M.runKeyOf("srvtag12345-l2x8k3z9q-zz9")
    local cyl = { shape = "cylinder", position = { x = 0, y = 0, z = 100 }, radius = 50, maxHeight = 20 }
    local lines = M.stockLines({ goodsItem = "g", tokenItem = "t", goodsPerCrate = 4, stash = "stash:s:goods",
        tokens = "sys:nomad" }, { "world:a.1", "world:a.2" }, "run1", "subj")
    return NW.result({
        live = ("%d/%d/%d/%s"):format(live.total, live.owner, live.cut, tostring(live.hot)),
        hot = ("%d/%d/%d/%s"):format(hot.total, hot.owner, hot.cut, tostring(hot.hot)),
        refused = tostring(refused) .. "/" .. tostring(why),
        p1 = ("%d/%d/%d"):format(p1.total, p1.owner, p1.cut), p2 = ("%d/%d/%d"):format(p2.total, p2.owner, p2.cut),
        run_key = tostring(key), crate_key = M.crateKey(key, 4), token = M.tokenOf(key, 4),
        token_len_ok = #M.tokenOf(string.rep("a", 40), 4) <= 64,
        bad_key = tostring(M.runKeyOf("has space")),
        in_cyl = tostring(M.inZone(cyl, { x = 30, y = 30, z = 110 })), out_planar = tostring(M.inZone(cyl, { x = 40, y = 40, z = 100 })),
        out_height = tostring(M.inZone(cyl, { x = 0, y = 0, z = 130 })),
        lines = #lines, line1 = lines[1].item .. ":" .. lines[1].count .. ":" .. lines[1].to,
        line2 = lines[2].instance .. ":" .. lines[2].from,
        text_known = M.textFor("camp_empty"), text_unknown = M.textFor("weird_token"),
        take_refusal = M.takeRefusal("insufficient_items") .. "/" .. M.takeRefusal("namespace_denied"),
        minutes = M.minutesLeft(10 * 60000 + 1000, 0),
    })
end

-- ---------------------------------------------------------------------------------------------
-- A library restarts under a run: open77_containers (a crate in hands stays in hands, the ground
-- crates keep exactly one prompt each), then open77_actions (it forgot every item: the crates
-- are placed again, the one in hands back at its last put-down spot). The run goes on.
-- ---------------------------------------------------------------------------------------------
function scenarios.library_restart()
    NW.boot({ config = chances(0, 0) })
    SW.watch()
    MH.run(6)
    nomad(1, A, AT_BOARD)
    NW.truck(TRUCK, PLATE, A, TRUCK_AT_BAY)
    take(1, "afterlife")
    local run = NW.runOf(A)
    local crates = NW.cratesOf(run.key)
    SW.move(1, LOAD[1])
    NW.pickup(1, crates[1])
    MH.stop("open77_containers")
    MH.run(1)
    SW.startContainers()
    MH.run(6)
    local s = NW.svc()
    local afterContainers = ("%s/%s/%s"):format(s.crates[crates[1].id].state, s.crates[crates[2].id].state,
        s.crates[crates[3].id].state)
    local items2, items3 = SW.items(crates[2].id), SW.items(crates[3].id)
    SW.move(1, AT_TAILGATE)
    local load1 = NW.putdownAt(1, "rp_nomade:truck_bay")
    SW.move(1, LOAD[2])
    NW.pickup(1, s.crates[crates[2].id])
    MH.stop("open77_actions")
    MH.run(1)
    SW.startActions()
    MH.run(4)
    local back2 = s.crates[crates[2].id]
    local at2 = back2.position and ("%.1f,%.1f"):format(back2.position.x, back2.position.y)
    local items = SW.items()
    SW.move(1, LOAD[2])
    local again = NW.pickup(1, back2) ~= nil
    SW.move(1, AT_TAILGATE)
    local load2 = NW.putdownAt(1, "rp_nomade:truck_bay")
    return NW.result({
        after_containers = afterContainers, items2 = items2, items3 = items3, load1 = load1 and load1.state,
        state2 = back2.state, at2 = at2, items_after_actions = items, again = again, load2 = load2 and load2.state,
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
