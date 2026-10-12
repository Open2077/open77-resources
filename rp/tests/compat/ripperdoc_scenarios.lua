-- tests/compat/ripperdoc_scenarios.lua: the ripperdoc clinic (rp_ripperdoc) end to end, offline.
--
-- Loaded by tests/test_ripperdoc.py after fakehost.lua (unused here) with the string globals ROOT_DIR,
-- COMPAT_DIR, SYS_DIR and TX_DIR (ripperdoc_world.lua). Players act the way the open77_actions client
-- and the platform's interaction UI make them act: prompt intents, chat commands, the invitation
-- answer and the UI-kit bar's X. Every money and item check reads the coordinator's store.

dofile(COMPAT_DIR .. "/ripperdoc_world.lua")

local scenarios = {}

local RIP, PAT, SEL = "acct-rip", "acct-pat", "acct-sel"
local CHAIR = { x = -1546.92, y = 1234.22, z = 11.6 }
local STATION = { x = -1546.40, y = 1233.74, z = 11.6 }
local NEAR = { x = -1545.5, y = 1233.5, z = 11.6 }        -- 1.6 m from the chair, inside the clinic
local OUTSIDE = { x = -1530.0, y = 1230.0, z = 11.6 }     -- 18 m away: outside the clinic zone
local SUPPLIER = { x = -1171.64, y = 2024.976, z = 7.761 }
local STOCK, THEATRE, SUP, SOC = "stash:rd.viktor:stock", "sys:ripperdoc.theatre", "sys:ripperdoc.supplier", "soc:ripper"
local CHAIR_T, STATION_T, SUPPLIER_T = "rp_ripperdoc:viktor_chair", "rp_ripperdoc:viktor_station", "rp_ripperdoc:kabuki_chrome"
local ITEMS = { "implant_box_arms", "implant_box_arms_ind", "implant_box_legs", "implant_box_legs_ath",
    "implant_box_deck", "implant_box_ice", "implant_box_purge" }

local function svc() return RDW.svc() end

-- A ripper (1) at the station and a patient (2) by the chair; stock and money for the patient.
local function clinic(opts)
    opts = opts or {}
    RDW.boot(opts)
    RDW.join(1, RIP, "Vik", STATION)
    RDW.join(2, PAT, "Jackie", opts.patientAt or NEAR)
    RDW.setupRipper(1)
    if opts.seed ~= false then RDW.seed("all", opts.seed or 1) end
    if opts.money ~= false then RDW.giveMoney("cash:" .. PAT, opts.money or 5000, "start") end
    MH.run(1)
end

local function quote(rip, pat, implant, grade)
    RDW.say(rip, { "quote", tostring(pat), implant, grade })
    MH.run(2)            -- past the 1.5 s refusal cooldown, so the next refusal is told too
    return RDW.offerOf(rip)
end

local function accept(rip) return RDW.answer(rip, true, 4) end

local function lie(pat)
    RDW.intent(pat, "rp_ripperdoc:lie_viktor", CHAIR_T)
    MH.run(1)
end

-- The ripper presses E at the station; runs until the action is terminal.
local function operate(rip, actionId, seconds)
    local mark = RDW.mark()
    RDW.intent(rip, "rp_ripperdoc:" .. actionId, STATION_T)
    return RDW.finish(rip, actionId, seconds or 60, mark)
end

-- Starts the operation and runs `seconds` into the bar (it does not wait for the end).
local function startOperate(rip, actionId, seconds)
    local mark = RDW.mark()
    RDW.intent(rip, "rp_ripperdoc:" .. actionId, STATION_T)
    RDW.waitState(rip, actionId, mark, "presenting", 10)
    MH.run(seconds or 3)
    return mark
end

local function surgeryOf(pid)
    local s = svc().byPlayer[pid]
    return s
end

local function lastSurgery()
    local best
    for _, s in pairs(svc().surgeries) do
        if not best or (s.createdAt or 0) >= (best.createdAt or 0) then best = s end
    end
    return best
end

local function stockOf(item) return RDW.count(STOCK, item) end

-- Items: seeded (minted from the supplier) + bought from players = stock + theatre (installed) +
-- held elsewhere. Money: what the patients paid = what the society received.
local function conserved()
    local problems = {}
    for _, item in ipairs(ITEMS) do
        local minted = -RDW.journal("^sys:ripperdoc%.supplier$", item)
        local installed = RDW.journal("^sys:ripperdoc%.theatre$", item)
        local probe = -RDW.journal("^sys:probe$", item)
        local inPockets = 0
        for _, acct in ipairs({ "char:" .. RIP, "char:" .. PAT, "char:" .. SEL }) do inPockets = inPockets + RDW.count(acct, item) end
        if minted + probe ~= stockOf(item) + installed + inPockets then
            problems[#problems + 1] = ("%s minted=%d probe=%d stock=%d installed=%d pockets=%d"):format(item, minted, probe,
                stockOf(item), installed, inPockets)
        end
    end
    return #problems == 0, table.concat(problems, "; ")
end

local function played(pid, profile, kind)
    for _, p in ipairs(MH.shared.world.played) do
        if p.pid == pid and p.profile == profile and (kind == nil or p.kind == kind) then return p end
    end
    return nil
end

local function menuFor(pid, id)
    for i = #MH.shared.ui.menus, 1, -1 do
        local m = MH.shared.ui.menus[i]
        if m.pid == pid and (id == nil or m.def.id == id) then return m end
    end
    return nil
end

local function barFor(pid)
    for i = #MH.shared.ui.bars, 1, -1 do
        if MH.shared.ui.bars[i].pid == pid then return MH.shared.ui.bars[i] end
    end
    return nil
end

local function playbackOf(pid)
    local p = MH.shared.world.playing[pid]
    return p and p.playbackId
end

-- ---------------------------------------------------------------------------------------------
-- Happy path: catalogue menu -> quote -> consent -> ONE hold -> the patient lies -> the ripper
-- operates (pose at the station, a bar on both screens) -> install once -> the hold commits.
-- ---------------------------------------------------------------------------------------------
function scenarios.happy_path()
    clinic({ writers = RDW.WRITERS_STRICT })
    local cash0, soc0 = RDW.balance("cash:" .. PAT), RDW.balance(SOC)
    local stock0 = stockOf("implant_box_arms")
    -- ALT+click > Quote: the catalogue opens on the ripper's screen; they pick Gorilla Arms (Street).
    MH.shared.ui.picks[1] = "install:arms:street"
    local R = MH.resources.rp_ripperdoc
    R.env.source = 1
    MH.emit("rp_ripperdoc:quote", 2)
    R.env.source = nil
    MH.run(2)
    local menu = menuFor(1, "rp_ripperdoc_catalogue")
    local menuRows = menu and #menu.def.options or 0
    local offerId = RDW.offerOf(1)
    local toldQuote = RDW.told(2, "QUOTE from Vik: install Gorilla Arms %(Street%) for 1500 eddies, 15 s")
    accept(1)
    local s = lastSurgery()
    local held = s and RDW.status(s.txOpId)
    local heldState = type(held) == "table" and held.state or "none"
    local cashAfterHold = RDW.balance("cash:" .. PAT)
    local stockAfterHold = stockOf("implant_box_arms")
    local journaledReserved = RDW.journalRows()
    local toldAccepted = RDW.told(2, "Quote accepted: 1500 eddies and the implant are on hold")
    lie(2)
    local lying = svc().lying[2] ~= nil
    local toldRipperOnChair = RDW.told(1, "Jackie is on the chair: E Install Gorilla Arms %(Street%)")
    local op = operate(1, "op_arms_street", 60)
    local rec = RDW.record(PAT)
    local arms = rec and rec.arms
    local events = RDW.jobEvents("operation")
    local e = events[1]
    local bar = barFor(2)
    local ok, detail = conserved()
    return RDW.result({
        menu_rows = menuRows, offered = offerId ~= nil, told_quote = toldQuote, told_accepted = toldAccepted,
        held_state = heldState, cash_untouched_by_hold = cashAfterHold == cash0, stock_untouched_by_hold = stockAfterHold == stock0,
        journal_reserved = journaledReserved, lying = lying, told_ripper_on_chair = toldRipperOnChair,
        op = op and op.state, op_receipt_how = op and op.receipt and op.receipt.how,
        paid = cash0 - RDW.balance("cash:" .. PAT), society = RDW.balance(SOC) - soc0,
        stock_used = stock0 - stockOf("implant_box_arms"), theatre = RDW.journal("^sys:ripperdoc%.theatre$", "implant_box_arms"),
        installed_def = arms and arms.definition, installed_grade = arms and arms.grade and arms.grade.id,
        record_op_is_ours = rec and s and rec.operationId == s.cwOpId,
        submits = #RDW.cw().submits, cw_commits = RDW.cw().commits,
        job_events = #events, event_job = e and e.job, event_kind = e and e.kind, event_player = e and e.playerId,
        event_implant = e and e.data and e.data.implant, event_grade = e and e.data and e.data.grade,
        event_ref_is_action = e and op and e.ref == op.opId,
        legacy_events = #MH.shared.operations,
        patient_bar = bar and bar.label, patient_bar_done = bar and bar.done == true,
        ripper_pose = played(1, "repair", "playAt") ~= nil,
        patient_pose = played(2, "seatedsleep", "playAt") ~= nil,
        told_done_patient = RDW.told(2, "Done: Gorilla Arms %(Street%) installed%. You paid 1500 eddies %(cash%)"),
        told_done_ripper = RDW.told(1, "Done: Gorilla Arms %(Street%) installed on Jackie%. 1500 eddies to the ripper society"),
        journal_rows = RDW.journalRows(), station_idle = svc().clinics.viktor.stationChoice,
        history_rows = #(MH.shared.db.ripperdocOps or {}),
        history_paid_via = (MH.shared.db.ripperdocOps or {})[1] and MH.shared.db.ripperdocOps[1].paidVia,
        history_implant = (MH.shared.db.ripperdocOps or {})[1] and MH.shared.db.ripperdocOps[1].implant,
        conserved = ok, conservation = detail, unbalanced = tostring(RDW.unbalanced()),
    })
end

-- ---------------------------------------------------------------------------------------------
-- The patient declines, then lets a quote time out: nothing is held, both are told.
-- ---------------------------------------------------------------------------------------------
function scenarios.decline_and_timeout()
    clinic()
    local cash0 = RDW.balance("cash:" .. PAT)
    local id = quote(1, 2, "legs", "training")
    RDW.answer(1, false, 2)
    local declinedTold = RDW.told(1, "No procedure for Jackie: the patient declined the quote")
        and RDW.told(2, "No procedure: the patient declined the quote%. Nothing was charged")
    local afterDecline = { busy = svc().byPlayer[1] ~= nil or svc().byPlayer[2] ~= nil, quotes = svc().stats.quotes,
        declined = svc().stats.declined }
    quote(1, 2, "legs", "training")
    MH.run(35)
    local timeoutTold = RDW.told(1, "No procedure for Jackie: the quote was not answered in time")
    return RDW.result({
        offered = id ~= nil, declined_told = declinedTold, free_after_decline = not afterDecline.busy,
        declined = afterDecline.declined, timeout_told = timeoutTold, free_after_timeout = svc().byPlayer[1] == nil,
        cash_same = RDW.balance("cash:" .. PAT) == cash0, stock_same = stockOf("implant_box_legs") == 1,
        submits = #RDW.cw().submits, journal_rows = RDW.journalRows(), unbalanced = tostring(RDW.unbalanced()),
    })
end

-- ---------------------------------------------------------------------------------------------
-- Every other end refunds: the ripper presses X; the patient presses X on their bar; the patient
-- gets off the chair (the workspot breaks). Each time the hold is released and nothing installs.
-- ---------------------------------------------------------------------------------------------
function scenarios.cancellations()
    clinic({ seed = 3 })
    local cash0 = RDW.balance("cash:" .. PAT)
    local out = {}
    -- 1. The ripper presses X mid-bar.
    quote(1, 2, "arms", "street")
    accept(1)
    lie(2)
    local mark = startOperate(1, "op_arms_street", 4)
    local s1 = lastSurgery()
    local op1 = RDW.lastOp(1, "op_arms_street")
    RDW.clientCancel(1, op1.opId)
    local end1 = RDW.finish(1, "op_arms_street", 10, mark)
    MH.run(1)
    out.x_state, out.x_reason = end1 and end1.state, end1 and end1.reason
    out.x_surgery, out.x_hold = s1.state, (RDW.status(s1.txOpId) or {}).state
    out.x_told = RDW.told(2, "Procedure cancelled: the ripperdoc stopped%. Nothing was charged and the implant stays in stock")
    out.x_patient_bar_closed = #MH.shared.ui.closes >= 1
    -- 2. The patient presses X on their own bar.
    quote(1, 2, "arms", "street")
    accept(1)
    lie(2)
    mark = startOperate(1, "op_arms_street", 4)
    local s2 = lastSurgery()
    MH.shared.ui.cancel[2] = true
    local end2 = RDW.finish(1, "op_arms_street", 10, mark)
    MH.run(1)
    out.px_state, out.px_reason = end2 and end2.state, end2 and end2.reason
    out.px_surgery = s2.state
    out.px_told = RDW.told(1, "Procedure cancelled: the patient stopped it")
    -- 3. The patient gets off the chair mid-bar (their workspot breaks: animation interrupted).
    quote(1, 2, "arms", "street")
    accept(1)
    lie(2)
    mark = startOperate(1, "op_arms_street", 4)
    local s3 = lastSurgery()
    MH.emit("onPlayerAnimationChanged", 2, { playbackId = playbackOf(2), active = false, reason = "moved" })
    local end3 = RDW.finish(1, "op_arms_street", 10, mark)
    MH.run(1)
    out.off_state, out.off_reason = end3 and end3.state, end3 and end3.reason
    out.off_surgery = s3.state
    out.off_told = RDW.told(2, "Procedure cancelled: the patient got off the chair")
    -- Nothing moved, nothing installed.
    out.cash_same = RDW.balance("cash:" .. PAT) == cash0
    out.stock = stockOf("implant_box_arms")
    out.submits = #RDW.cw().submits
    out.arms = tostring(RDW.record(PAT) and RDW.record(PAT).arms)
    out.journal_rows = RDW.journalRows()
    out.cancelled = svc().stats.cancelled
    out.station_idle = svc().clinics.viktor.stationChoice
    out.unbalanced = tostring(RDW.unbalanced())
    return RDW.result(out)
end

-- ---------------------------------------------------------------------------------------------
-- Disconnects, deaths, clock-outs and walking away, before and during the operation.
-- ---------------------------------------------------------------------------------------------
function scenarios.leaving()
    clinic({ seed = 3 })
    local cash0 = RDW.balance("cash:" .. PAT)
    local out = {}
    -- Accepted, then the patient walks off past the leash (25 m from the chair).
    quote(1, 2, "arms", "street")
    accept(1)
    local s1 = lastSurgery()
    RDW.move(2, { x = -1520.0, y = 1230.0, z = 11.6 })
    MH.run(4)
    out.walk_state, out.walk_reason = s1.state, s1.endReason
    out.walk_told = RDW.told(1, "Procedure cancelled: somebody walked away")
    RDW.move(2, NEAR)
    -- Accepted, then the patient dies.
    quote(1, 2, "arms", "street")
    accept(1)
    local s2 = lastSurgery()
    RDW.kill(2)
    MH.run(4)
    out.dead_state, out.dead_reason = s2.state, s2.endReason
    MH.players[2].alive = true
    -- Accepted, then the ripper clocks out.
    quote(1, 2, "arms", "street")
    accept(1)
    local s3 = lastSurgery()
    RDW.clock(1, false)
    MH.run(2)
    out.duty_state, out.duty_reason = s3.state, s3.endReason
    out.duty_told = RDW.told(2, "Procedure cancelled: the ripperdoc clocked out")
    RDW.clock(1, true)
    -- During the operation, the ripper clocks out: open77_actions' epoch guard stops the action.
    quote(1, 2, "arms", "street")
    accept(1)
    lie(2)
    local mark = startOperate(1, "op_arms_street", 4)
    local s4 = lastSurgery()
    RDW.clock(1, false)
    local end4 = RDW.finish(1, "op_arms_street", 10, mark)
    MH.run(1)
    out.op_duty_state, out.op_duty_reason, out.op_duty_surgery = end4 and end4.state, end4 and end4.reason, s4.state
    RDW.clock(1, true)
    -- During the operation, the patient disconnects.
    quote(1, 2, "arms", "street")
    accept(1)
    lie(2)
    mark = startOperate(1, "op_arms_street", 4)
    local s5 = lastSurgery()
    RDW.disconnect(2)
    local end5 = RDW.finish(1, "op_arms_street", 10, mark)
    MH.run(2)
    out.dc_state, out.dc_surgery = end5 and end5.state, s5.state
    out.dc_told_ripper = RDW.told(1, "Procedure cancelled: somebody left the server")
    -- The patient comes back; the ripper disconnects during the operation.
    RDW.join(2, PAT, "Jackie", NEAR)
    quote(1, 2, "arms", "street")
    accept(1)
    lie(2)
    mark = startOperate(1, "op_arms_street", 4)
    local s7 = lastSurgery()
    RDW.disconnect(1)
    MH.run(2)
    out.rdc_op_surgery, out.rdc_op_reason = s7.state, s7.endReason
    out.rdc_op_told = RDW.told(2, "Procedure cancelled: somebody left the server")
    -- The ripper comes back; they disconnect while the quote is accepted.
    RDW.join(1, RIP, "Vik", STATION)
    RDW.clock(1, true)
    quote(1, 2, "arms", "street")
    accept(1)
    local s6 = lastSurgery()
    RDW.disconnect(1)
    MH.run(1)
    out.rdc_state, out.rdc_reason = s6.state, s6.endReason
    out.cash_same = RDW.balance("cash:" .. PAT) == cash0
    out.stock = stockOf("implant_box_arms")
    out.submits = #RDW.cw().submits
    out.journal_rows = RDW.journalRows()
    out.unbalanced = tostring(RDW.unbalanced())
    return RDW.result(out)
end

-- ---------------------------------------------------------------------------------------------
-- Refusals reach the player, before anything is held.
-- ---------------------------------------------------------------------------------------------
function scenarios.refusals()
    clinic({ seed = false, money = false })
    RDW.join(3, SEL, "Misty", NEAR)
    local out = {}
    -- A civilian tries to quote.
    quote(3, 2, "arms", "street")
    out.no_job = RDW.told(3, "You are no ripperdoc")
    -- Off duty.
    RDW.clock(1, false)
    quote(1, 2, "arms", "street")
    out.off_duty = RDW.told(1, "Clock in first")
    RDW.clock(1, true)
    -- Outside the clinic.
    RDW.move(1, OUTSIDE)
    quote(1, 2, "arms", "street")
    out.outside = RDW.told(1, "Work inside the clinic")
    RDW.move(1, STATION)
    -- Too far from the patient (patient 7 m away, still inside the clinic zone).
    RDW.move(2, { x = -1541.0, y = 1230.0, z = 11.6 })
    quote(1, 2, "arms", "street")
    out.too_far = RDW.told(1, "Get closer")
    RDW.move(2, NEAR)
    -- No stock yet.
    quote(1, 2, "arms", "street")
    out.out_of_stock = RDW.told(1, "no box of that implant left")
    out.no_offer = RDW.offerOf(1) == nil
    -- Stock, but the patient cannot pay (500 cash < 1500): refused at the hold, after consent.
    RDW.seed("implant_box_arms", 1)
    quote(1, 2, "arms", "street")
    accept(1)
    out.cannot_pay = RDW.told(1, "No procedure for Jackie: Not enough eddies %(cash or bank%)")
    out.nothing_held = svc().byPlayer[2] == nil
    -- Self-surgery.
    quote(1, 1, "arms", "street")
    out.self = RDW.told(1, "Operating on yourself")
    -- The idle station: no card at all without an accepted quote; /ripper operate says why.
    MH.command("ripper", 1, { "operate" })
    MH.run(1)
    out.idle = svc().clinics.viktor.stationChoice == false and RDW.told(1, "No accepted quote") ~= nil
    -- An accepted quote, but the patient is not on the chair: the operate prompt refuses.
    RDW.giveMoney("cash:" .. PAT, 5000, "late")
    quote(1, 2, "arms", "street")
    accept(1)
    RDW.intent(1, "rp_ripperdoc:op_arms_street", STATION_T)
    MH.run(1)
    out.not_on_chair = RDW.told(1, "The patient must sit in the operating chair first")
    -- The quote expires (180 s) without an operation.
    local s = lastSurgery()
    MH.run(185)
    out.expired_state, out.expired_reason = s.state, s.endReason
    out.expired_told = RDW.told(2, "Procedure cancelled: the quote expired before the operation started")
    -- A slot already taken: install arms, then quote arms again.
    RDW.seed("implant_box_arms", 1)
    quote(1, 2, "arms", "street")
    accept(1)
    lie(2)
    operate(1, "op_arms_street", 60)
    quote(1, 2, "arms", "industrial")
    out.slot_taken = RDW.told(1, "That slot is already taken")
    out.unbalanced = tostring(RDW.unbalanced())
    return RDW.result(out)
end

-- ---------------------------------------------------------------------------------------------
-- Exactly once: a lost acknowledgement on the hold's commit (retried, replayed), a replayed commit
-- hook after the end, a second press of E, a replayed cyberware submit.
-- ---------------------------------------------------------------------------------------------
function scenarios.exactly_once()
    clinic({ seed = 2 })
    local cash0, soc0 = RDW.balance("cash:" .. PAT), RDW.balance(SOC)
    quote(1, 2, "arms", "street")
    accept(1)
    lie(2)
    local mark = RDW.mark()
    RDW.intent(1, "rp_ripperdoc:op_arms_street", STATION_T)
    RDW.waitState(1, "op_arms_street", mark, "presenting", 10)
    -- A second press while it runs: refused (one action per player, one claim per station).
    RDW.intent(1, "rp_ripperdoc:op_arms_street", STATION_T)
    MH.run(0.5)
    local refusals = SFW.refusals(1)
    local second = refusals[#refusals]
    -- The commit's acknowledgement is lost once: the coordinator applied it, the retry replays.
    RDW.store().faults = { "lost_ack" }
    local op = RDW.finish(1, "op_arms_street", 60, mark)
    MH.run(4)
    local s = lastSurgery()
    -- The commit hook called again with the same context after the end: the stored receipt.
    local ctx = { opId = s.actionOpId, actionId = "op_arms_street", reservation = { surgery = s.id } }
    -- The settle step run again: the coordinator replays, completeSurgery is a no-op.
    local R = MH.resources.rp_ripperdoc
    local box = {}
    MH.task("rp_ripperdoc", function()
        box.again = svc():commitOperate(ctx)
        svc():settle(s)
        -- The cyberware submit replayed with the same id and revision: no second install.
        box.r, box.why = R.env.Open77.cyberware.install(2, "rp_ripperdoc.gorilla_arms", "street",
            { expectedRevision = s.expectedRevision, operationId = s.cwOpId })
    end)
    MH.run(2)
    local again = box.again
    local rec = RDW.record(PAT)
    return RDW.result({
        second_press = tostring(second), op = op and op.state,
        paid = cash0 - RDW.balance("cash:" .. PAT), society = RDW.balance(SOC) - soc0,
        commits = RDW.committed("ripperdoc.operation"), installs = RDW.cw().commits, submits = #RDW.cw().submits,
        again_how = type(again) == "table" and again.how or tostring(again), state = s.state,
        replay_ok = type(box.r) == "table" and box.r.ok == true and box.r.ticket == nil,
        cw_replays = RDW.cw().replays, revision = rec.revision,
        job_events = #RDW.jobEvents("operation"), stock = stockOf("implant_box_arms"),
        unbalanced = tostring(RDW.unbalanced()),
    })
end

-- ---------------------------------------------------------------------------------------------
-- Restarts. (a) rp_ripperdoc restarts mid-bar: the coordinator released the hold, the journal row
-- tells both, nothing installs. (b) The implant landed but the completion was lost to a restart:
-- recovery reads the record and settles ONCE with a transfer. (c) A full server restart with the
-- implant landed. (d) A full restart with nothing landed: released after the grace.
-- ---------------------------------------------------------------------------------------------
function scenarios.restarts()
    clinic({ seed = 4, money = 20000 })
    local out = {}
    local cash0, soc0 = RDW.balance("cash:" .. PAT), RDW.balance(SOC)
    -- (a)
    quote(1, 2, "arms", "street")
    accept(1)
    lie(2)
    startOperate(1, "op_arms_street", 4)
    local idA = lastSurgery().id
    RDW.restartRipper()
    MH.run(2)
    out.a_journal = RDW.journalRows()
    out.a_told = RDW.told(2, "The clinic restarted before your operation: nothing was charged")
    out.a_cash_same = RDW.balance("cash:" .. PAT) == cash0
    out.a_submits = #RDW.cw().submits
    out.a_hold = (RDW.status(idA) or {}).state
    -- (b) The completion event is lost (CW.holdEvent) and rp_ripperdoc restarts before it hears it.
    MH.run(2)
    quote(1, 2, "arms", "street")
    accept(1)
    lie(2)
    RDW.cw().holdEvent = true
    local mark = startOperate(1, "op_arms_street", 15.5)
    MH.until_(function() return RDW.cw().commits >= 1 end, 10)
    local sB = lastSurgery()
    local journalStateB = sB.state
    RDW.restartRipper()
    RDW.cw().holdEvent = false
    MH.run(4)
    local recB = RDW.record(PAT)
    out.b_installed = recB.arms ~= nil and recB.operationId == sB.cwOpId
    out.b_paid = cash0 - RDW.balance("cash:" .. PAT)
    out.b_society = RDW.balance(SOC) - soc0
    out.b_settles = RDW.committed("ripperdoc.settle")
    out.b_holds = RDW.committed("ripperdoc.operation")
    out.b_journal = RDW.journalRows()
    out.b_state_before = journalStateB
    out.b_events = #RDW.jobEvents("operation")
    out.b_told = RDW.told(2, "Done: Gorilla Arms %(Street%) installed%. You paid 1500 eddies")
    out.b_stock = stockOf("implant_box_arms")
    -- (c) Legs, landed, then a full server restart before the completion.
    MH.run(2)
    quote(1, 2, "legs", "training")
    accept(1)
    lie(2)
    RDW.cw().holdEvent = true
    startOperate(1, "op_legs_training", 12.5)
    MH.until_(function() return RDW.cw().commits >= 2 end, 10)
    local sC = lastSurgery()
    local keep = RDW.keep()
    RDW.cw().holdEvent = false
    RDW.boot({ keep = keep })
    RDW.join(1, RIP, "Vik", STATION)
    RDW.join(2, PAT, "Jackie", NEAR)
    RDW.setupRipper(1)
    MH.run(4)
    local recC = RDW.record(PAT)
    out.c_installed = recC.legs ~= nil and recC.operationId == sC.cwOpId
    out.c_paid = cash0 - RDW.balance("cash:" .. PAT)
    out.c_settles = RDW.committed("ripperdoc.settle")
    out.c_journal = RDW.journalRows()
    out.c_stock_legs = stockOf("implant_box_legs")
    -- A second boot does not charge again.
    keep = RDW.keep()
    RDW.boot({ keep = keep })
    RDW.join(1, RIP, "Vik", STATION)
    RDW.join(2, PAT, "Jackie", NEAR)
    MH.run(4)
    out.c_paid_after_second_boot = cash0 - RDW.balance("cash:" .. PAT)
    -- (d) Self-ICE, the cyberware never answers, full restart: released after the grace.
    RDW.setupRipper(1)
    quote(1, 2, "ice", "street")
    accept(1)
    lie(2)
    RDW.cw().mode = "hang"
    startOperate(1, "op_ice_street", 14.5)
    MH.run(1)
    local sD = lastSurgery()
    local dState = sD.state
    keep = RDW.keep()
    RDW.boot({ keep = keep })
    RDW.cw().mode = "ok"
    RDW.join(1, RIP, "Vik", STATION)
    RDW.join(2, PAT, "Jackie", NEAR)
    MH.run(5)
    out.d_pending_early = svc().recovering[sD.id] ~= nil
    MH.run(35)
    out.d_state_before = dState
    out.d_pending_late = svc().recovering[sD.id] ~= nil
    out.d_installed = RDW.record(PAT).self_ice ~= nil
    out.d_paid = cash0 - RDW.balance("cash:" .. PAT)
    out.d_journal = RDW.journalRows()
    out.d_told = RDW.told(2, "did not go through before the clinic restarted: nothing was charged")
    out.d_stock_ice = stockOf("implant_box_ice")
    local ok, detail = conserved()
    out.conserved, out.conservation = ok, detail
    out.unbalanced = tostring(RDW.unbalanced())
    return RDW.result(out)
end

-- ---------------------------------------------------------------------------------------------
-- The cyberware refuses (native projection failed), then never answers (timeout, rolled back).
-- ---------------------------------------------------------------------------------------------
function scenarios.install_failures()
    clinic({ seed = 2 })
    local cash0 = RDW.balance("cash:" .. PAT)
    quote(1, 2, "arms", "street")
    accept(1)
    lie(2)
    RDW.cw().mode = "fail"
    local op1 = operate(1, "op_arms_street", 60)
    MH.run(2)
    local s1 = lastSurgery()
    local told1 = RDW.told(2, "The procedure failed: the chrome would not take")
    RDW.cw().mode = "hang"
    quote(1, 2, "arms", "street")
    accept(1)
    lie(2)
    local op2 = operate(1, "op_arms_street", 90)
    MH.run(2)
    local s2 = lastSurgery()
    RDW.cw().mode = "ok"
    return RDW.result({
        fail_op = op1 and op1.state, fail_reason = op1 and op1.reason, fail_surgery = s1.state, fail_told = told1,
        hang_op = op2 and op2.state, hang_reason = op2 and op2.reason, hang_surgery = s2.state,
        cancels = RDW.cw().cancels, cash_same = RDW.balance("cash:" .. PAT) == cash0,
        stock = stockOf("implant_box_arms"), arms = tostring(RDW.record(PAT).arms), journal_rows = RDW.journalRows(),
        unbalanced = tostring(RDW.unbalanced()),
    })
end

-- ---------------------------------------------------------------------------------------------
-- Restock at the chrome dealer: the order menu, paid by the society; the cash fallback; a count
-- from the command; the operator's mint rule.
-- ---------------------------------------------------------------------------------------------
function scenarios.restock()
    clinic({ seed = false, writers = RDW.WRITERS_STRICT })
    RDW.move(1, SUPPLIER)
    RDW.giveMoney(SOC, 2000, "soc")
    local soc0, cash0 = RDW.balance(SOC), RDW.balance("cash:" .. RIP)
    MH.shared.ui.picks[1] = "buy:implant_box_arms"
    local mark = RDW.mark()
    RDW.intent(1, "rp_ripperdoc:restock", SUPPLIER_T)
    local op1 = RDW.finish(1, "restock", 30, mark)
    local menu = menuFor(1, "rp_ripperdoc_supplier")
    local after1 = { stock = stockOf("implant_box_arms"), soc = soc0 - RDW.balance(SOC) }
    -- The society has 1100 left: two Industrial arms (2 x 1920) are paid from the ripper's cash.
    RDW.giveMoney("cash:" .. RIP, 5000, "rip")
    local cashBefore2 = RDW.balance("cash:" .. RIP)
    mark = RDW.mark()
    RDW.say(1, { "restock", "arms", "industrial", "2" })
    MH.run(0.5)
    local op2 = RDW.finish(1, "restock", 30, mark)
    local after2 = { stock = stockOf("implant_box_arms_ind"), cash = cashBefore2 - RDW.balance("cash:" .. RIP),
        soc = RDW.balance(SOC) }
    -- Escape on the menu: nothing ordered.
    MH.shared.ui.picks[1] = false
    mark = RDW.mark()
    RDW.intent(1, "rp_ripperdoc:restock", SUPPLIER_T)
    local op3 = RDW.finish(1, "restock", 30, mark)
    -- Away from the dealer: refused by open77_actions (too far).
    RDW.move(1, STATION)
    RDW.say(1, { "restock", "legs" })
    MH.run(1)
    local farRefused = RDW.told(1, "Get closer")
    local events = RDW.jobEvents("restock")
    return RDW.result({
        op1 = op1 and op1.state, menu_rows = menu and #menu.def.options or 0, stock1 = after1.stock, soc1 = after1.soc,
        op2 = op2 and op2.state, stock2 = after2.stock, cash2 = after2.cash, soc2 = after2.soc,
        op3 = op3 and op3.state, op3_reason = op3 and op3.reason,
        far = farRefused,
        events = #events, event_kind = events[1] and events[1].kind, event_source = events[1] and events[1].data.source,
        event_item = events[1] and events[1].data.item, event_cost = events[1] and events[1].data.cost,
        event_ref = events[1] and op1 and events[1].ref == op1.opId,
        minted = -RDW.journal("^sys:ripperdoc%.supplier$", "implant_box_arms"),
        burned = RDW.journal("^sys:ripperdoc%.supplier$", "money"),
        told = RDW.told(1, "Order delivered to Vik's clinic: 1 x Gorilla Arms %(Street%)"),
        unbalanced = tostring(RDW.unbalanced()),
    })
end

-- Components mode (the techie hook): each box burns its grade's components from the ripperdoc's
-- pockets; no money moves.
function scenarios.restock_components()
    clinic({ seed = false, configPatch = [[
        RpRipperConfig.supplier.mode = "components"
        RpRipperConfig.catalogue[1].grades[1].components = { { item = "tech_component", count = 2 } }
    ]] })
    MH.callSync("rd_probe", "open77_transactions", "define", { tech_component = { weightG = 100 } })
    RDW.grant({ { item = "tech_component", count = 4, from = "sys:probe", to = "char:" .. RIP } }, "probe.components")
    RDW.move(1, SUPPLIER)
    local cash0 = RDW.balance("cash:" .. RIP)
    local mark = RDW.mark()
    RDW.say(1, { "restock", "arms", "street", "2" })
    MH.run(0.5)
    local op = RDW.finish(1, "restock", 30, mark)
    -- A grade without components is refused before the bar.
    mark = RDW.mark()
    RDW.say(1, { "restock", "legs" })
    MH.run(0.5)
    local op2 = RDW.finish(1, "restock", 30, mark)
    return RDW.result({ op = op and op.state, stock = stockOf("implant_box_arms"),
        components_left = RDW.count("char:" .. RIP, "tech_component"),
        burned = RDW.journal("^sys:ripperdoc%.supplier$", "tech_component"),
        cash_same = RDW.balance("cash:" .. RIP) == cash0, op2 = op2 and op2.state, op2_reason = op2 and op2.reason,
        told = RDW.told(1, "has no components recipe"), unbalanced = tostring(RDW.unbalanced()) })
end

-- No mint rule for the supplier: the order is refused before the bar and the player is told.
function scenarios.restock_mint_denied()
    clinic({ seed = false, mint = "rp_inventory sys:* * 100000; rp_economy sys:* money 100000000; rd_probe sys:* * 100000; rd_probe sys:* money 100000000" })
    RDW.move(1, SUPPLIER)
    RDW.giveMoney(SOC, 2000, "soc")
    local mark = RDW.mark()
    RDW.say(1, { "restock", "arms" })
    MH.run(0.5)
    local op = RDW.finish(1, "restock", 30, mark)
    return RDW.result({ op = op and op.state, reason = op and op.reason, stage = op and op.stage,
        told = RDW.told(1, "mint rule missing"), stock = stockOf("implant_box_arms"), soc = RDW.balance(SOC) })
end

-- ---------------------------------------------------------------------------------------------
-- Buying chrome from a player: consented hand-over, ONE transfer (boxes in, money out).
-- ---------------------------------------------------------------------------------------------
function scenarios.buyback()
    clinic({ seed = false, writers = RDW.WRITERS_STRICT })
    RDW.join(3, SEL, "Misty", NEAR)
    RDW.grant({ { item = "implant_box_arms", count = 2, from = "sys:probe", to = "char:" .. SEL } }, "probe.items.sel")
    RDW.giveMoney(SOC, 5000, "soc")
    local cash0, soc0 = RDW.balance("cash:" .. SEL), RDW.balance(SOC)
    RDW.say(1, { "buy", "3", "arms", "street", "2" })
    MH.run(1)
    local offered = RDW.offerOf(1) ~= nil
    local toldOffer = RDW.told(3, "Vik offers 1500 eddies for 2 x Gorilla Arms %(Street%)")
    RDW.answer(1, true, 6)
    local afterSale = { stock = stockOf("implant_box_arms"), pockets = RDW.count("char:" .. SEL, "implant_box_arms"),
        paid = RDW.balance("cash:" .. SEL) - cash0, soc = soc0 - RDW.balance(SOC) }
    local events = RDW.jobEvents("restock")
    -- A second offer the seller declines: nothing moves.
    RDW.grant({ { item = "implant_box_legs", count = 1, from = "sys:probe", to = "char:" .. SEL } }, "probe.items.sel2")
    RDW.say(1, { "buy", "3", "legs" })
    MH.run(1)
    RDW.answer(1, false, 2)
    -- The seller does not carry the box.
    RDW.say(1, { "buy", "3", "deck" })
    MH.run(1)
    return RDW.result({
        offered = offered, told_offer = toldOffer, stock = afterSale.stock, pockets = afterSale.pockets,
        paid = afterSale.paid, soc = afterSale.soc, events = #events, event_source = events[1] and events[1].data.source,
        event_count = events[1] and events[1].data.count, declined_legs = RDW.count("char:" .. SEL, "implant_box_legs"),
        declined_told = RDW.told(1, "No purchase: the seller declined"),
        short_told = RDW.told(1, "The seller does not carry that"),
        unbalanced = tostring(RDW.unbalanced()),
    })
end

-- ---------------------------------------------------------------------------------------------
-- A removal: the fee only, nothing out of stock, the slot back to stock parts.
-- ---------------------------------------------------------------------------------------------
function scenarios.removal()
    clinic({ seed = 1 })
    quote(1, 2, "arms", "industrial")
    MH.run(1)
    local refusedIndustrial = RDW.told(1, "no box of that implant left") == false
    RDW.seed("implant_box_arms_ind", 1)
    quote(1, 2, "arms", "industrial")
    accept(1)
    lie(2)
    operate(1, "op_arms_industrial", 60)
    MH.run(2)
    local installed = RDW.record(PAT).arms ~= nil
    local cash0, soc0 = RDW.balance("cash:" .. PAT), RDW.balance(SOC)
    local stock0 = stockOf("implant_box_arms_ind")
    RDW.say(1, { "remove", "2", "arms" })
    MH.run(1)
    local toldQuote = RDW.told(2, "QUOTE from Vik: remove Gorilla Arms %(Industrial%) for 1600 eddies")
    accept(1)
    lie(2)
    local op = operate(1, "rm_arms", 60)
    MH.run(2)
    local events = RDW.jobEvents("operation")
    return RDW.result({
        installed_first = installed, told_quote = toldQuote, op = op and op.state,
        fee = cash0 - RDW.balance("cash:" .. PAT), society = RDW.balance(SOC) - soc0,
        stock_same = stockOf("implant_box_arms_ind") == stock0, arms = tostring(RDW.record(PAT).arms),
        events = #events, last_action = events[#events] and events[#events].data.action,
        told_done = RDW.told(2, "Done: Gorilla Arms %(Industrial%) removed"),
        refused_before_seed = refusedIndustrial,
        unbalanced = tostring(RDW.unbalanced()),
    })
end

-- ---------------------------------------------------------------------------------------------
-- Seating mode: the chair is a real furniture through open77_seating. The quote stands the
-- patient up, the acceptance seats them again, the operation installs; standing up mid-bar refunds.
-- ---------------------------------------------------------------------------------------------
function scenarios.seating_mode()
    clinic({ seed = 2, seating = true, configPatch = [[
        RpRipperConfig.clinics.viktor.chair.mode = "seating"
        RpRipperConfig.clinics.viktor.chair.furniture = "12345678901234567890"
    ]] })
    local noLieAction = svc().actionKinds.lie_viktor == nil
    local cash0 = RDW.balance("cash:" .. PAT)
    MH.callSync("rd_probe", "open77_seating", "sit", 2, "12345678901234567890")
    MH.run(1)
    quote(1, 2, "arms", "street")
    local stoodForQuote = MH.shared.seating.sessions[2] == nil
    accept(1)
    MH.run(1)
    local seatedAgain = MH.shared.seating.sessions[2] ~= nil
    local op = operate(1, "op_arms_street", 60)
    MH.run(2)
    local paid1 = cash0 - RDW.balance("cash:" .. PAT)
    -- Legs: the patient stands up mid-bar.
    quote(1, 2, "legs", "training")
    accept(1)
    MH.run(1)
    local mark = startOperate(1, "op_legs_training", 4)
    MH.callSync("rd_probe", "open77_seating", "stand", 2)
    local op2 = RDW.finish(1, "op_legs_training", 10, mark)
    MH.run(1)
    return RDW.result({
        no_lie_action = noLieAction, stood_for_quote = stoodForQuote, seated_again = seatedAgain,
        op = op and op.state, paid1 = paid1, arms = RDW.record(PAT).arms ~= nil,
        op2 = op2 and op2.state, op2_reason = op2 and op2.reason, legs = tostring(RDW.record(PAT).legs),
        paid_total = cash0 - RDW.balance("cash:" .. PAT), unbalanced = tostring(RDW.unbalanced()),
    })
end

-- ---------------------------------------------------------------------------------------------
-- Commands and the operator console answer without errors; /ripper cancel releases a hold.
-- ---------------------------------------------------------------------------------------------
local function chatCount(pid)
    local n = 0
    for _, c in ipairs(MH.chat) do if c.target == pid and c.resource == "rp_ripperdoc" then n = n + 1 end end
    return n
end

function scenarios.commands()
    clinic({ seed = 1 })
    quote(1, 2, "arms", "street")
    accept(1)
    lie(2)
    operate(1, "op_arms_street", 60)
    MH.run(1)
    local c0 = chatCount(1)
    RDW.say(1, {})
    MH.run(3)
    local board = chatCount(1) - c0
    local boardLog = RDW.told(1, "Last 24 h: 1 procedure")
    local p0 = chatCount(2)
    RDW.say(2, {})
    MH.run(3)
    local view = chatCount(2) - p0
    local implants = RDW.told(2, "arms: Gorilla Arms %(Street%)")
    MH.command("implants", 2, {})
    MH.run(1)
    RDW.say(1, { "stock" })
    MH.run(1)
    local stock = RDW.told(1, "Stock at Vik's clinic")
    RDW.say(1, { "help" })
    MH.run(1)
    -- An accepted quote cancelled by the ripperdoc before the operation.
    RDW.seed("implant_box_legs", 1)
    quote(1, 2, "legs", "training")
    accept(1)
    local s = lastSurgery()
    RDW.say(1, { "cancel" })
    MH.run(1)
    MH.command("ripper.status", 0, {})
    MH.command("ripper.journal", 0, {})
    MH.command("operer", 1, { "2" })
    MH.run(2)
    return RDW.result({ board = board, board_log = boardLog, view = view, implants = implants, stock = stock,
        cancel_state = s.state, cancel_reason = s.endReason, status_line = RDW.printed("ready=true"),
        journal_line = RDW.printed("journal: 0 open row"), operer_menu = menuFor(1, "rp_ripperdoc_catalogue") ~= nil,
        unbalanced = tostring(RDW.unbalanced()) })
end

-- ---------------------------------------------------------------------------------------------
-- Boot facts: definitions, items through rp_inventory, the stash, targets, profiles.
-- ---------------------------------------------------------------------------------------------
function scenarios.boot()
    RDW.boot()
    local s = svc()
    local defs = 0
    for _ in pairs(RDW.cw().defs) do defs = defs + 1 end
    local hacking = s.defined.deck and s.defined.ice and s.defined.purge
    return RDW.result({
        ready = s.ready, targets = s.targetCount, defs = defs, hacking = hacking and true or false,
        lie_profile = s.profiles.lie_viktor, op_profile = s.profiles.operate, restock_profile = s.profiles.restock,
        station = s.clinics.viktor.stationChoice, stock_open = s.clinics.viktor.opened == true,
        printed_ready = RDW.printed("ready: clinics viktor %(placed chair%)"),
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
