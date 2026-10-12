-- tests/compat/trauma_scenarios.lua: Trauma Team International (rp_trauma) end to end, offline.
--
-- Loaded by tests/test_trauma.py after fakehost.lua (unused here) with the string globals
-- ROOT_DIR, COMPAT_DIR, SYS_DIR and TX_DIR (trauma_world.lua). Players act the way the
-- open77_actions client, the UI kit and the chat make them act: prompt intents, menu and dialog
-- answers, chat commands. Every money check reads durable truth from the coordinator's store.

dofile(COMPAT_DIR .. "/trauma_world.lua")

local scenarios = {}

local MEDIC, PAT, MEDIC2, PAT2, PAT3 = "acct-medic", "acct-pat", "acct-medic2", "acct-pat2", "acct-pat3"
local KIOSK = { x = -1223.91, y = 1989.45, z = 7.98 }          -- tti_kiosk_market (server/config.lua)
local DEATH = { x = -1195.0, y = 2001.0, z = 7.82 }            -- Kabuki Market, where the patient falls
local NEAR = { x = -1194.0, y = 2001.6, z = 7.82 }             -- 1.17 m from the body
local NEAR2 = { x = -1195.8, y = 2001.9, z = 7.82 }            -- a second medic, 1.2 m from the body
local FAR = { x = -1170.0, y = 2001.0, z = 7.82 }              -- 25 m away
local CLINIC = { x = -1546.0, y = 1231.0, z = 11.6 }           -- shared Config.hospital.respawn (Vik's)
local SOC = "soc:trauma"
local WEEK = 168 * 3600

local function svc() return TW.svc() end
local function ui() return MH.shared.trauma.ui end

local function subscribe(pid, tier, seconds)
    ui().context[pid] = "plan_" .. tier
    return TW.act(pid, "tti_plan", "tti_kiosk_market", seconds or 60)
end

local function asked(pid, kind)
    local n = 0
    for _, a in ipairs(MH.shared.trauma.asked) do if a.pid == pid and a.kind == kind then n = n + 1 end end
    return n
end

local function callOf(pid) return svc().calls[pid] end

local function events(state, patient)
    local n = 0
    for _, e in ipairs(MH.shared.trauma.calls) do
        if e.state == state and (patient == nil or e.patient == patient) then n = n + 1 end
    end
    return n
end

local function lastTeleport(pid)
    local list = MH.shared.trauma.teleports
    for i = #list, 1, -1 do if list[i].id == pid then return list[i].position end end
    return nil
end

local function near(a, b, tolerance)
    if not a or not b then return false end
    return math.abs(a.x - b.x) < (tolerance or 0.01) and math.abs(a.y - b.y) < (tolerance or 0.01)
end

local function targetExists(pid)
    local engine = MH.resources.open77_actions.env.Open77ActionsRuntime.engine
    return engine.targets["rp_trauma:tti_patient_" .. pid] ~= nil
end

local function targetActions(pid)
    local engine = MH.resources.open77_actions.env.Open77ActionsRuntime.engine
    local t = engine.targets["rp_trauma:tti_patient_" .. pid]
    if not t then return "none" end
    local out = {}
    for _, c in ipairs(t.actions) do out[#out + 1] = c.action end
    return table.concat(out, ",")
end

local function played(pid, profile)
    for _, p in ipairs(MH.shared.world.played) do
        if p.pid == pid and p.profile == profile then return true end
    end
    return false
end

local function opState(op) return op and op.state or "none" end
local function opReason(op) return op and op.reason or "none" end

-- ---------------------------------------------------------------------------------------------
-- Subscription at a kiosk: Gold (bank), renewal of the same tier, a switch to Platinum, a
-- declined menu, rp:job:completed once per purchase, the card in the holder's file.
-- ---------------------------------------------------------------------------------------------
function scenarios.subscribe()
    TW.boot()
    TW.join(2, PAT, "Patient", KIOSK)
    TW.fund("bank:" .. PAT, 30000)
    local cash0 = TW.balance("cash:" .. PAT)
    local now0 = MH.now
    local o1 = subscribe(2, "gold")
    local card1 = TW.card(PAT) or {}
    local bank1, soc1 = TW.balance("bank:" .. PAT), TW.balance(SOC)
    local menu = MH.shared.trauma.asked[1] or {}
    local told1 = TW.told(2, "Trauma Team Gold signed")
    local hasContract = select(2, MH.callSync("tt_probe", "rp_trauma", "hasContract", 2))
    local planOf = select(2, MH.callSync("tt_probe", "rp_trauma", "planOf", 2)) or {}
    -- Renew Gold: one more period after the current end.
    local o2 = subscribe(2, "gold")
    local card2 = TW.card(PAT) or {}
    local bank2 = TW.balance("bank:" .. PAT)
    -- Switch to Platinum: a fresh period from now, the rest of Gold is lost.
    local o3 = subscribe(2, "platinum")
    local card3 = TW.card(PAT) or {}
    local bank3 = TW.balance("bank:" .. PAT)
    -- The player leaves the menu: nothing signed, nothing held.
    ui().context[2] = "cancel"
    local o4 = TW.act(2, "tti_plan", "tti_kiosk_market", 60)
    local bank4 = TW.balance("bank:" .. PAT)
    local subs = TW.jobs("subscribe")
    return TW.result({
        o1 = opState(o1), o2 = opState(o2), o3 = opState(o3), o4 = opState(o4), o4_reason = opReason(o4),
        menu_options = menu.options or "", tier1 = card1.tier, until1 = (card1.untilAt or 0) - math.floor(now0),
        auto1 = tostring(card1.autoRenew), bank1 = bank1, soc1 = soc1, cash_untouched = TW.balance("cash:" .. PAT) == cash0,
        told1 = told1, has_contract = tostring(hasContract), plan_of = planOf.tier, plan_priority = planOf.priority,
        tier2 = card2.tier, extended = (card2.untilAt or 0) - (card1.untilAt or 0), periods2 = card2.periods, bank2 = bank2,
        tier3 = card3.tier, until3_fresh = (card3.untilAt or 0) - WEEK >= math.floor(now0) and (card3.untilAt or 0) < (card2.untilAt or 0),
        bank3 = bank3, bank4 = bank4, soc_end = TW.balance(SOC),
        subs = #subs, sub_ref = subs[1] and subs[1].ref or "", sub_player = subs[1] and subs[1].playerId or 0,
        sub_tier = subs[1] and subs[1].data and subs[1].data.tier or "", sub_job = subs[1] and subs[1].job or "",
        sub_modes = (subs[1] and subs[1].data.mode or "") .. "," .. (subs[2] and subs[2].data.mode or "") .. "," ..
            (subs[3] and subs[3].data.mode or ""),
        plan_ops = TW.committed("trauma.plan"), held = TW.held("bank:" .. PAT),
        unbalanced = tostring(TW.unbalanced()),
    })
end

-- ---------------------------------------------------------------------------------------------
-- Purchase refusals: not enough money (told, nothing held), the bank-then-cash split, the
-- prepaid ceiling, a down player at the kiosk, a player too far from it.
-- ---------------------------------------------------------------------------------------------
function scenarios.subscribe_refusals()
    TW.boot()
    TW.join(2, PAT, "Patient", KIOSK)
    TW.join(3, PAT2, "Other", KIOSK)
    TW.settle()
    -- 500 cash (the starting wallet), no bank: Silver (1500) is refused before the bar.
    local r1 = subscribe(2, "silver")
    local told1 = TW.told(2, "Not enough eddies")
    local card1 = TW.card(PAT)
    -- 1000 in the bank + 500 cash: one operation takes both.
    TW.fund("bank:" .. PAT, 1000)
    local r2 = subscribe(2, "silver")
    local bank2, cash2 = TW.balance("bank:" .. PAT), TW.balance("cash:" .. PAT)
    local card2 = TW.card(PAT) or {}
    -- The prepaid ceiling: 4 periods ahead at most.
    TW.fund("bank:" .. PAT, 20000)
    local states = {}
    for i = 1, 4 do
        local op = subscribe(2, "silver")
        states[i] = opState(op) .. (op and op.reason and (":" .. op.reason) or "")
    end
    local told3 = TW.told(2, "paid as far ahead")
    -- A down player cannot sign; a player 25 m away gets no prompt.
    TW.move(3, DEATH)
    TW.die(3)
    TW.move(3, KIOSK)
    ui().context[3] = "plan_gold"
    local mark = TW.mark()
    SFW.intent(3, "rp_trauma:tti_plan", "rp_trauma:tti_kiosk_market")
    MH.run(2)
    local downRefused = table.concat(TW.refusals(3), ",")
    TW.move(2, FAR)
    SFW.intent(2, "rp_trauma:tti_plan", "rp_trauma:tti_kiosk_market")
    MH.run(2)
    local farRefused = table.concat(TW.refusals(2), ",")
    return TW.result({
        r1 = opState(r1), r1_reason = opReason(r1), r1_stage = r1 and r1.stage or "", told1 = told1,
        no_card1 = card1 == nil, r2 = opState(r2), bank2 = bank2, cash2 = cash2, tier2 = card2.tier,
        s1 = states[1], s2 = states[2], s3 = states[3], s4 = states[4], told3 = told3,
        down_refused = downRefused, far_refused = farRefused, mark = mark,
        held_bank = TW.held("bank:" .. PAT), held_cash = TW.held("cash:" .. PAT),
        unbalanced = tostring(TW.unbalanced()),
    })
end

-- ---------------------------------------------------------------------------------------------
-- The Gold subscriber goes down: a priority call reaches the on-duty medic (chat, toast, pin),
-- the medic takes it, stabilises the body (kneel, plan covers it, society bounty), then
-- evacuates it to Vik's clinic (fade, released at the tier's health), the call closes.
-- ---------------------------------------------------------------------------------------------
function scenarios.gold_response()
    TW.boot()
    TW.join(1, MEDIC, "Medic", NEAR)
    TW.join(2, PAT, "Patient", KIOSK)
    TW.setup(1)
    TW.fund("bank:" .. PAT, 10000)
    local sub = subscribe(2, "gold")
    TW.move(2, DEATH)
    TW.settle()
    local soc0, bank0 = TW.balance(SOC), TW.balance("bank:" .. PAT)
    local entry = TW.die(2)
    local call = callOf(2) or {}
    local held = entry and entry.held
    local frozen = MH.players[2].frozen
    local backAtDeath = near(MH.players[2].position, DEATH)
    local savedDown = TW.saved(PAT) ~= nil
    -- The platform reports two alive phases per respawn: the second holds again, in silence.
    MH.shared.trauma.revision = MH.shared.trauma.revision + 1
    MH.emit("onPlayerLifeStateChanged", 2, MH.shared.trauma.revision, "alive")
    MH.run(2)
    local downTold = TW.toldCount(2, "^You are down%. Trauma Team")
    local toldMedic = TW.told(1, "%[GOLD #1%] Patient %(id 2%) is down")
    local pins = TW.clientEvents(1, "rp_trauma:downBlip")
    local pinTag = pins[1] and pins[1][4] or ""
    local toldPatient = TW.told(2, "Trauma Team Gold: call #1 placed, priority 2")
    local target1 = targetActions(2)
    -- The medic takes the call.
    TW.say(1, "tti", { "take" })
    local taken = call.state
    local toldResponding = TW.told(2, "Medic is responding to your call #1")
    -- Stabilise: E on the body.
    local st = TW.act(1, "tti_stabilise", "tti_patient_2", 60)
    local kneel = played(1, "examine")
    local stable = call.stable
    local healthStable = MH.players[2].health
    local stillDown = TW.entry(2) ~= nil
    local savedStable = (TW.saved(PAT) or ""):find("stable=1", 1, true) ~= nil
    local target2 = targetActions(2)
    local medicBank1 = TW.balance("bank:" .. MEDIC)
    local socAfterStab = TW.balance(SOC)
    -- Evacuate: E on the body again.
    local ev = TW.act(1, "tti_evacuate", "tti_patient_2", 60)
    MH.run(1)
    local entryAfter = TW.entry(2)
    local atClinic = near(MH.players[2].position, CLINIC)
    local medicBank2 = TW.balance("bank:" .. MEDIC)
    local jobsS, jobsE = TW.jobs("stabilise"), TW.jobs("evacuate")
    local revived = MH.shared.trauma.revived[1] or {}
    return TW.result({
        sub = opState(sub), held = tostring(held), frozen = tostring(frozen), back_at_death = backAtDeath,
        call_id = call.id, call_priority = call.priority, call_tier = call.tierKey, told_medic = toldMedic, down_told = downTold,
        pin_tag = pinTag, told_patient = toldPatient, target1 = target1, taken = taken, responder = call.responder,
        told_responding = toldResponding,
        st = opState(st), kneel = kneel, stable = tostring(stable), health_stable = healthStable, still_down = stillDown,
        target2 = target2, patient_paid_stab = bank0 - TW.balance("bank:" .. PAT),
        medic_bank1 = medicBank1, soc_stab = soc0 - socAfterStab,
        ev = opState(ev), released = entryAfter == nil, at_clinic = atClinic, health_end = MH.players[2].health,
        frozen_end = tostring(MH.players[2].frozen), call_gone = callOf(2) == nil, target_gone = not targetExists(2),
        closed_events = events("closed", 2), medic_bank2 = medicBank2, soc_end = TW.balance(SOC),
        patient_paid = bank0 - TW.balance("bank:" .. PAT),
        jobs_s = #jobsS, jobs_e = #jobsE, job_s_player = jobsS[1] and jobsS[1].playerId or 0,
        job_s_patient = jobsS[1] and jobsS[1].data.patient or 0, job_e_ref = jobsE[1] and jobsE[1].ref or "",
        job_s_bounty = jobsS[1] and jobsS[1].data.bounty or -1, job_e_moved = jobsE[1] and tostring(jobsE[1].data.moved) or "",
        revived_by = revived.by or 0, told_clinic = TW.told(2, "Trauma Team brought you to Vik's clinic"),
        held_soc = TW.held(SOC), unbalanced = tostring(TW.unbalanced()),
        saved_down = savedDown, saved_stable = savedStable, saved_end = TW.saved(PAT) == nil,
    })
end

-- ---------------------------------------------------------------------------------------------
-- Silver: the evacuation is half covered. The patient pays the rest from the bank; the medic gets
-- a cut of it and a society bounty on the covered half.
-- ---------------------------------------------------------------------------------------------
function scenarios.silver_partial()
    TW.boot()
    TW.join(1, MEDIC, "Medic", NEAR)
    TW.join(2, PAT, "Patient", KIOSK)
    TW.setup(1)
    TW.fund("bank:" .. PAT, 5000)
    subscribe(2, "silver")
    TW.move(2, DEATH)
    TW.settle()
    local bank0, soc0 = TW.balance("bank:" .. PAT), TW.balance(SOC)
    TW.die(2)
    local call = callOf(2) or {}
    local delayed = call.announced
    MH.run(6)
    local announced = call.announced
    local st = TW.act(1, "tti_stabilise", "tti_patient_2", 60)
    local consentAsked = asked(2, "alert")
    local ev = TW.act(1, "tti_evacuate", "tti_patient_2", 60)
    MH.run(1)
    local job = TW.jobs("evacuate")[1] or { data = {} }
    return TW.result({
        delayed = tostring(delayed), announced = tostring(announced), st = opState(st), ev = opState(ev),
        consent_asked = consentAsked, patient_paid = bank0 - TW.balance("bank:" .. PAT),
        medic_bank = TW.balance("bank:" .. MEDIC), soc_delta = TW.balance(SOC) - soc0,
        ev_fee = job.data.fee, ev_covered = job.data.covered, ev_paid = job.data.paid, ev_cut = job.data.cut,
        ev_bounty = job.data.bounty, health_end = MH.players[2].health,
        told_charges = TW.told(2, "400 eddies covered by your plan, 400 eddies from your account"),
        unbalanced = tostring(TW.unbalanced()),
    })
end

-- ---------------------------------------------------------------------------------------------
-- No plan, conscious: the patient accepts the charges in a dialog (asked once per call), pays
-- from the wallet, the rest becomes an invoice, paid later with /tti pay.
-- ---------------------------------------------------------------------------------------------
function scenarios.uninsured_consent()
    TW.boot()
    TW.join(1, MEDIC, "Medic", NEAR)
    TW.join(2, PAT, "Patient", DEATH)
    TW.setup(1)
    TW.settle()
    local cash0, soc0 = TW.balance("cash:" .. PAT), TW.balance(SOC)
    TW.die(2)
    local call = callOf(2) or {}
    local toldUninsured = TW.told(2, "No Trauma Team plan: emergency call #1 placed")
    local early = call.announced
    MH.run(16)
    local late = call.announced
    local pinTag = (TW.clientEvents(1, "rp_trauma:downBlip")[1] or {})[4] or ""
    ui().alert[2] = "confirm"
    local st = TW.act(1, "tti_stabilise", "tti_patient_2", 60)
    local askedAfterStab = asked(2, "alert")
    local cashAfterStab = TW.balance("cash:" .. PAT)
    local ev = TW.act(1, "tti_evacuate", "tti_patient_2", 60)
    MH.run(1)
    local askedAfterEvac = asked(2, "alert")
    local owed = TW.count(TW.file(PAT), "tti_invoice")
    local medicBank = TW.balance("bank:" .. MEDIC)
    local socAfter = TW.balance(SOC)
    local toldInvoice = TW.told(2, "700 eddies invoiced")
    local owedExport = select(2, MH.callSync("tt_probe", "rp_trauma", "owed", 2))
    -- Later: money in the bank, /tti pay settles the invoice in one operation.
    TW.fund("bank:" .. PAT, 1000)
    TW.say(2, "tti", { "pay" }, 4)
    local owedAfter = TW.count(TW.file(PAT), "tti_invoice")
    local toldPaid = TW.told(2, "Paid 700 eddies of Trauma Team invoices. Clean slate.")
    TW.say(2, "tti", { "pay" }, 3)
    local toldNothing = TW.told(2, "You owe Trauma Team nothing")
    return TW.result({
        told_uninsured = toldUninsured, early = tostring(early), late = tostring(late), pin_tag = pinTag,
        st = opState(st), asked_stab = askedAfterStab, cash_paid_stab = cash0 - cashAfterStab,
        ev = opState(ev), asked_evac = askedAfterEvac, cash_end = TW.balance("cash:" .. PAT), owed = owed,
        owed_export = owedExport, medic_bank = medicBank, soc_delta = socAfter - soc0, told_invoice = toldInvoice,
        owed_after = owedAfter, bank_after = TW.balance("bank:" .. PAT), soc_paid = TW.balance(SOC) - socAfter,
        told_paid = toldPaid, told_nothing = toldNothing, invoice_net = SFW.journal("^sys:trauma%.billing$", "tti_invoice"),
        unbalanced = tostring(TW.unbalanced()),
    })
end

-- ---------------------------------------------------------------------------------------------
-- No plan: a refusal stops the care (nothing held) and holds for a minute; then no answer at all
-- counts as unconscious: treated, billed after (an invoice when the wallet is empty).
-- ---------------------------------------------------------------------------------------------
function scenarios.consent_declined_then_silent()
    TW.boot()
    TW.join(1, MEDIC, "Medic", NEAR)
    TW.join(2, PAT, "Patient", DEATH)
    TW.setup(1)
    TW.settle()
    TW.drain("cash:" .. PAT)
    TW.die(2)
    TW.say(1, "tti", { "take", "1" })
    ui().alert[2] = "cancel"
    local r1 = TW.act(1, "tti_stabilise", "tti_patient_2", 60)
    local toldMedic = TW.told(1, "Patient refuses the charges")
    local asked1 = asked(2, "alert")
    -- Within the minute: refused again without asking.
    local r2 = TW.act(1, "tti_stabilise", "tti_patient_2", 60)
    local asked2 = asked(2, "alert")
    MH.run(61)
    ui().alert[2] = "none"
    local r3 = TW.act(1, "tti_stabilise", "tti_patient_2", 60)
    local asked3 = asked(2, "alert")
    local owed = TW.count(TW.file(PAT), "tti_invoice")
    return TW.result({
        r1 = opState(r1), r1_reason = opReason(r1), r1_stage = r1 and r1.stage or "", told_medic = toldMedic,
        asked1 = asked1, r2 = opState(r2), r2_reason = opReason(r2), asked2 = asked2,
        r3 = opState(r3), asked3 = asked3, owed = owed, stable = tostring((callOf(2) or {}).stable),
        medic_bank = TW.balance("bank:" .. MEDIC), held_cash = TW.held("cash:" .. PAT),
        unbalanced = tostring(TW.unbalanced()),
    })
end

-- ---------------------------------------------------------------------------------------------
-- One team per call: the second medic's /tti take and E are refused; /tti assist joins the team;
-- two medics pressing E on the same body at once: one target claim, one winner.
-- ---------------------------------------------------------------------------------------------
function scenarios.one_team()
    TW.boot()
    TW.join(1, MEDIC, "Medic", NEAR)
    TW.join(3, MEDIC2, "Second", NEAR2)
    TW.join(2, PAT, "Patient", DEATH)
    TW.join(4, PAT2, "Other", { x = DEATH.x + 30, y = DEATH.y, z = DEATH.z })
    TW.setup(1)
    TW.setup(3)
    TW.fund("bank:" .. PAT, 5000)
    TW.fund("bank:" .. PAT2, 5000)
    TW.settle()
    ui().alert[2] = "confirm"
    ui().alert[4] = "confirm"
    TW.die(2)
    MH.run(16)
    TW.say(1, "tti", { "take", "1" })
    TW.say(3, "tti", { "take", "1" })
    local toldTaken = TW.told(3, "Another Trauma Team unit has this call")
    local s2 = TW.act(3, "tti_stabilise", "tti_patient_2", 30)
    local refused = table.concat(TW.refusals(3), ",")
    TW.say(3, "tti", { "assist", "1" })
    local team = (callOf(2) or { team = {} }).team[3] == true
    local st = TW.act(3, "tti_stabilise", "tti_patient_2", 60)
    local bank1, bank3 = TW.balance("bank:" .. MEDIC), TW.balance("bank:" .. MEDIC2)
    local toldTeamPay = TW.told(1, "Team pay, call #1 stabilised: %+80 eddies")
    local teamJob = TW.jobs("stabilise")[1] or { data = {} }
    -- Second patient: both medics press E in the same tick on an open call.
    TW.move(1, { x = DEATH.x + 31, y = DEATH.y + 0.6, z = DEATH.z })
    TW.move(3, { x = DEATH.x + 29.2, y = DEATH.y + 0.8, z = DEATH.z })
    TW.die(4)
    MH.run(16)
    local mark = TW.mark()
    SFW.intent(1, "rp_trauma:tti_stabilise", "rp_trauma:tti_patient_4")
    SFW.intent(3, "rp_trauma:tti_stabilise", "rp_trauma:tti_patient_4")
    local a = TW.finish(1, "tti_stabilise", 60, mark)
    local claimRefusals = table.concat(TW.refusals(3), ",")
    local call4 = callOf(4) or {}
    return TW.result({
        told_taken = toldTaken, s2 = opState(s2), refused = refused, team = tostring(team), st = opState(st),
        stabilised_by = (callOf(2) or {}).stabilisedBy, a = opState(a), claim_refusals = claimRefusals,
        responder4 = call4.responder, stable4 = tostring(call4.stable), jobs_s = #TW.jobs("stabilise"),
        bank1 = bank1, bank3 = bank3, told_team_pay = toldTeamPay,
        job_team = table.concat(teamJob.data.team or {}, ","), job_team_pay = table.concat(teamJob.data.teamPay or {}, ","),
        bank1_end = TW.balance("bank:" .. MEDIC), bank3_end = TW.balance("bank:" .. MEDIC2),
        unbalanced = tostring(TW.unbalanced()),
    })
end

-- ---------------------------------------------------------------------------------------------
-- The call closes whatever brings the patient up: /respawn at Vik's (billed by the plan, exactly
-- once per down episode), a revive in place (/reanimer), a disconnect.
-- ---------------------------------------------------------------------------------------------
function scenarios.call_closes()
    TW.boot()
    TW.join(1, MEDIC, "Medic", NEAR)
    TW.join(2, PAT, "Patient", DEATH)
    TW.join(3, PAT2, "Leaver", { x = DEATH.x + 5, y = DEATH.y, z = DEATH.z })
    TW.setup(1)
    TW.settle()
    local cash0 = TW.balance("cash:" .. PAT)
    TW.die(2)
    TW.say(1, "tti", { "take", "1" })
    TW.say(2, "respawn", {})
    local toldWait = TW.told(2, "Trauma Team is on duty")
    MH.run(61)
    TW.say(2, "respawn", {}, 4)
    TW.say(2, "respawn", {}, 2)
    local released = TW.entry(2) == nil
    local atClinic = near(MH.players[2].position, CLINIC)
    local hospOps = TW.committed("trauma.hospital")
    local paid = cash0 - TW.balance("cash:" .. PAT)
    local closed1 = events("closed", 2)
    local toldMedic1 = TW.told(1, "Call #1 closed: the patient woke up at Vik's")
    local targetGone1 = not targetExists(2)
    local toldNotDown = TW.told(2, "You are not down")
    local saved1Gone = TW.saved(PAT) == nil
    -- A revive in place closes the next call (consent asked: no plan).
    TW.move(2, DEATH)
    TW.die(2)
    local call2 = callOf(2) or {}
    ui().alert[2] = "confirm"
    TW.say(1, "reanimer", { "2" }, 14)
    local revived = TW.entry(2) == nil
    local closed2 = events("closed", 2)
    local reviveOps = TW.committed("trauma.revive")
    local toldRevive = TW.told(2, "Medic Medic revived you")
    local jobsRevive = #TW.jobs("revive")
    local saved2Gone = TW.saved(PAT) == nil
    -- A disconnect closes the third (the leaver's).
    TW.die(3)
    local call3 = callOf(3) or {}
    MH.disconnect(3)
    MH.run(1)
    return TW.result({
        told_wait = toldWait, released = released, at_clinic = atClinic, hosp_ops = hospOps, paid = paid,
        closed1 = closed1, told_medic1 = toldMedic1, target_gone1 = targetGone1, told_not_down = toldNotDown,
        call2 = call2.id, revived = revived, closed2 = closed2, revive_ops = reviveOps, told_revive = toldRevive,
        jobs_revive = jobsRevive, call3 = call3.id, call3_gone = callOf(3) == nil, closed3 = events("closed", 3),
        target3_gone = not targetExists(3), owed = TW.count(TW.file(PAT), "tti_invoice"),
        unbalanced = tostring(TW.unbalanced()), saved1_gone = saved1Gone, saved2_gone = saved2Gone,
        saved3_kept = TW.saved(PAT2) ~= nil,
    })
end

-- ---------------------------------------------------------------------------------------------
-- Out of the hold without Trauma Team: another resource heals the held body (an admin or
-- gamemode heal), or the console's trauma.release. Neither bills anything.
-- ---------------------------------------------------------------------------------------------
function scenarios.healed_elsewhere()
    TW.boot()
    TW.join(2, PAT, "Patient", DEATH)
    TW.settle()
    local cash0 = TW.balance("cash:" .. PAT)
    local held = TW.die(2)
    local wasHeld = held ~= nil and held.held == true
    local lowHealth = MH.players[2].health
    MH.players[2].health = MH.players[2].maxHealth or 100      -- a heal from another resource
    MH.run(2)
    local freed = TW.entry(2) == nil
    local frozenAfter = MH.players[2].frozen == true
    local toldPatched = TW.told(2, "You were patched up")
    local savedHealedGone = TW.saved(PAT) == nil
    local held2 = TW.die(2)
    local savedAgain = TW.saved(PAT) ~= nil
    MH.command("trauma.release", 0, { "2" })
    MH.run(1)
    return TW.result({
        was_held = wasHeld, low_health = lowHealth, freed = freed, frozen_after = frozenAfter,
        told_patched = toldPatched, held_again = held2 ~= nil, released_by_console = TW.entry(2) == nil,
        told_console = TW.told(2, "An operator got you back on your feet"),
        paid = cash0 - TW.balance("cash:" .. PAT), unbalanced = tostring(TW.unbalanced()),
        saved_healed_gone = savedHealedGone, saved_again = savedAgain, saved_released_gone = TW.saved(PAT) == nil,
    })
end

-- ---------------------------------------------------------------------------------------------
-- The responder disconnects or clocks out: the call opens again and is announced again.
-- ---------------------------------------------------------------------------------------------
function scenarios.responder_leaves()
    TW.boot()
    TW.join(1, MEDIC, "Medic", NEAR)
    TW.join(3, MEDIC2, "Second", NEAR2)
    TW.join(2, PAT, "Patient", DEATH)
    TW.setup(1)
    TW.setup(3)
    TW.settle()
    TW.die(2)
    MH.run(16)
    TW.say(1, "tti", { "take", "1" })
    local call = callOf(2) or {}
    local takenBy = call.responder
    local pins3 = #TW.clientEvents(3, "rp_trauma:downBlip")
    MH.disconnect(1)
    MH.run(1)
    local reopened = call.state
    local reannounced = #TW.clientEvents(3, "rp_trauma:downBlip") > pins3
    local toldPatient = TW.told(2, "Your Trauma Team responder left %(disconnected%)")
    TW.say(3, "tti", { "take" })
    local taken2 = call.responder
    MH.command("tti.setup", 0, { "3" })
    MH.callSync("tt_probe", "rp_jobs", "setDuty", 3, false)
    MH.run(1)
    local reopened2 = call.state
    return TW.result({
        taken_by = takenBy, reopened = reopened, reannounced = tostring(reannounced), told_patient = toldPatient,
        taken2 = taken2, reopened2 = reopened2, open_events = events("open", 2), taken_events = events("taken", 2),
    })
end

-- ---------------------------------------------------------------------------------------------
-- Cancellations: X during the stabilisation, the patient waking up at Vik's during it, the medic
-- walking away. Nothing is charged, nothing stays held.
-- ---------------------------------------------------------------------------------------------
function scenarios.cancellations()
    TW.boot()
    TW.join(1, MEDIC, "Medic", NEAR)
    TW.join(2, PAT, "Patient", DEATH)
    TW.setup(1)
    TW.fund("bank:" .. PAT, 5000)
    TW.settle()
    ui().alert[2] = "confirm"
    TW.die(2)
    TW.say(1, "tti", { "take", "1" })
    local bank0 = TW.balance("bank:" .. PAT)
    -- X on the bar.
    local mark = TW.mark()
    SFW.intent(1, "rp_trauma:tti_stabilise", "rp_trauma:tti_patient_2")
    TW.waitState(1, "tti_stabilise", mark, "presenting", 30)
    local heldDuring = TW.held("bank:" .. PAT)
    local list = MH.shared.transitions
    local opId
    for i = #list, mark + 1, -1 do if list[i].actionId == "tti_stabilise" then opId = list[i].opId break end end
    SFW.clientCancel(1, opId)
    local c1 = TW.finish(1, "tti_stabilise", 30, mark)
    MH.run(1)
    local heldAfter = TW.held("bank:" .. PAT)
    -- The medic walks away during the bar.
    mark = TW.mark()
    SFW.intent(1, "rp_trauma:tti_stabilise", "rp_trauma:tti_patient_2")
    TW.waitState(1, "tti_stabilise", mark, "presenting", 30)
    TW.move(1, FAR)
    local c2 = TW.finish(1, "tti_stabilise", 30, mark)
    TW.move(1, NEAR)
    MH.run(1)
    -- The patient takes /respawn while the medic works: the call closes, the act charges nothing.
    MH.run(61)
    mark = TW.mark()
    SFW.intent(1, "rp_trauma:tti_stabilise", "rp_trauma:tti_patient_2")
    TW.waitState(1, "tti_stabilise", mark, "presenting", 30)
    local bankBefore = TW.balance("bank:" .. PAT)
    TW.say(2, "respawn", {}, 1)
    local c3 = TW.finish(1, "tti_stabilise", 30, mark)
    MH.run(1)
    return TW.result({
        held_during = heldDuring, c1 = opState(c1), c1_reason = opReason(c1), held_after = heldAfter,
        c2 = opState(c2), c2_reason = opReason(c2), c3 = opState(c3), c3_reason = opReason(c3),
        hospital_paid = bankBefore - TW.balance("bank:" .. PAT), care_ops = TW.committed("trauma.stabilise"),
        stab_charged = bank0 - bankBefore, held_end = TW.held("bank:" .. PAT), medic_bank = TW.balance("bank:" .. MEDIC),
        jobs_s = #TW.jobs("stabilise"), unbalanced = tostring(TW.unbalanced()),
    })
end

-- ---------------------------------------------------------------------------------------------
-- A server restart: the plan comes back from the coordinator (not from Lua memory), the holder's
-- next fall is a Gold call; an rp_trauma restart alone reloads the connected players.
-- ---------------------------------------------------------------------------------------------
function scenarios.restart_keeps_plan()
    TW.boot()
    TW.join(2, PAT, "Patient", KIOSK)
    TW.fund("bank:" .. PAT, 10000)
    subscribe(2, "gold")
    local until1 = (TW.card(PAT) or {}).untilAt
    local keep = TW.keep()
    TW.boot({ keep = keep })
    TW.join(1, MEDIC, "Medic", NEAR)
    TW.join(2, PAT, "Patient", DEATH)
    TW.setup(1)
    TW.settle()
    local plan = svc().plans[PAT] or {}
    local has = select(2, MH.callSync("tt_probe", "rp_trauma", "hasContract", 2))
    local toldActive = TW.told(2, "Trauma Team Gold active")
    TW.die(2)
    local call = callOf(2) or {}
    local tier = call.tierKey
    -- rp_trauma alone restarts: the plan is read again, the held player is held down again and
    -- their Gold call goes out again.
    MH.restart("rp_trauma", { { source = SFW.PATCH, name = "p.lua" }, { source = TW.PATCH, name = "t.lua" },
        table.unpack(SFW.scripts(ROOT_DIR .. "/rp_trauma")) }, { host = true })
    MH.until_(function() return TW.svc() and TW.svc().ready and TW.svc().actionsReady end, 30)
    MH.run(3)
    local plan2 = TW.svc().plans[PAT] or {}
    return TW.result({
        until_same = plan.untilAt == until1, tier = plan.tier, has = tostring(has), told_active = toldActive,
        call_tier = tier, call_priority = call.priority, after_restart_tier = plan2.tier,
        frozen_after = tostring(MH.players[2].frozen), patient_target = targetActions(2),
        call2_tier = tostring((callOf(2) or {}).tierKey), unbalanced = tostring(TW.unbalanced()),
    })
end

-- ---------------------------------------------------------------------------------------------
-- Automatic renewal of an ended plan: once per period whatever the number of sweeps; a failed
-- renewal lapses the plan and tells the holder once; auto-renewal can be switched off.
-- ---------------------------------------------------------------------------------------------
function scenarios.renewal()
    TW.boot()
    TW.join(2, PAT, "Patient", KIOSK)
    TW.fund("bank:" .. PAT, 3200)
    subscribe(2, "silver")
    local until1 = (TW.card(PAT) or {}).untilAt
    local bank1 = TW.balance("bank:" .. PAT)
    MH.now = until1 + 10
    MH.run(65)
    local card2 = TW.card(PAT) or {}
    local bank2 = TW.balance("bank:" .. PAT)
    MH.run(65)
    local bank2b = TW.balance("bank:" .. PAT)
    local renewOps = TW.committed("trauma.renew")
    local toldRenewed = TW.told(2, "Trauma Team Silver renewed")
    -- Not enough for the next one: the plan lapses, the holder is told once.
    MH.now = card2.untilAt + 10
    MH.run(65)
    MH.run(65)
    local lapsed = not select(2, MH.callSync("tt_probe", "rp_trauma", "hasContract", 2))
    local toldFailed = TW.toldCount(2, "renewal failed")
    -- Switch auto-renewal off: the card says so.
    TW.say(2, "tti", { "autorenew", "off" }, 3)
    local card3 = TW.card(PAT) or {}
    -- A new purchase keeps the holder's choice.
    TW.fund("bank:" .. PAT, 1500)
    local again = subscribe(2, "silver")
    local card4 = TW.card(PAT) or {}
    local subs = TW.jobs("subscribe")
    return TW.result({
        bank1 = bank1, extended = (card2.untilAt or 0) - until1, periods2 = card2.periods, bank2 = bank2,
        bank2b = bank2b, renew_ops = renewOps, told_renewed = toldRenewed, lapsed = tostring(lapsed),
        told_failed = toldFailed, auto3 = tostring(card3.autoRenew), again = opState(again),
        auto4 = tostring(card4.autoRenew), mode4 = subs[#subs] and subs[#subs].data.mode or "", subs = #subs,
        last_mode = subs[#subs - 1] and subs[#subs - 1].data.mode or "", unbalanced = tostring(TW.unbalanced()),
    })
end

-- ---------------------------------------------------------------------------------------------
-- Priority dispatch: Platinum, Silver and an uninsured player go down together; the calls are
-- held back by tier and `/tti take` without an id answers the Platinum one first.
-- ---------------------------------------------------------------------------------------------
function scenarios.priority_dispatch()
    TW.boot()
    TW.join(1, MEDIC, "Medic", FAR)
    TW.join(2, PAT, "Platinum", KIOSK)
    TW.join(3, PAT2, "Silver", KIOSK)
    TW.join(4, PAT3, "Nobody", DEATH)
    TW.setup(1)
    TW.fund("bank:" .. PAT, 20000)
    TW.fund("bank:" .. PAT2, 5000)
    subscribe(2, "platinum")
    subscribe(3, "silver")
    TW.move(2, { x = DEATH.x + 3, y = DEATH.y, z = DEATH.z })
    TW.move(3, { x = DEATH.x + 6, y = DEATH.y, z = DEATH.z })
    TW.settle()
    TW.die(4, { stayDead = true })
    TW.die(3, { stayDead = true })
    TW.die(2, { stayDead = true })
    local at0 = { (callOf(2) or {}).announced, (callOf(3) or {}).announced, (callOf(4) or {}).announced }
    MH.run(6)
    local at6 = { (callOf(2) or {}).announced, (callOf(3) or {}).announced, (callOf(4) or {}).announced }
    MH.run(12)
    local at18 = (callOf(4) or {}).announced
    local order = {}
    for _, call in ipairs(svc():openCalls()) do order[#order + 1] = call.tierKey or "none" end
    TW.say(1, "tti", { "take" })
    local first = (callOf(2) or {}).responder
    local list = select(2, MH.callSync("tt_probe", "rp_trauma", "calls")) or {}
    return TW.result({
        plat0 = tostring(at0[1]), silver0 = tostring(at0[2]), none0 = tostring(at0[3]),
        silver6 = tostring(at6[2]), none6 = tostring(at6[3]), none18 = tostring(at18),
        order = table.concat(order, ","), first = first, calls_export = #list,
        export_first = list[1] and list[1].tier or "",
    })
end

-- ---------------------------------------------------------------------------------------------
-- Refusals: an off-duty or job-less player, evacuation before stabilisation, a medic treating
-- themselves, a forged hook call from another resource.
-- ---------------------------------------------------------------------------------------------
function scenarios.refusals()
    TW.boot()
    TW.join(1, MEDIC, "Medic", NEAR)
    TW.join(3, MEDIC2, "Civilian", NEAR2)
    TW.join(2, PAT, "Patient", DEATH)
    TW.setup(1)
    TW.settle()
    TW.die(2)
    TW.act(3, "tti_stabilise", "tti_patient_2", 10)
    local civilian = table.concat(TW.refusals(3), ",")
    local ev = TW.act(1, "tti_evacuate", "tti_patient_2", 10)
    local notStable = table.concat(TW.refusals(1), ",")
    local _, forgedValue, forged = MH.callSync("tt_probe", "rp_trauma", "ttiCommit", { opId = "x", actionId = "tti_stabilise" })
    local _, forgedV, forgedVWhy = MH.callSync("tt_probe", "rp_trauma", "ttiValidate", { opId = "x", actionId = "tti_plan" })
    local _, forgedR, forgedRWhy = MH.callSync("tt_probe", "rp_trauma", "ttiReserve", { opId = "x", actionId = "tti_plan" })
    -- The medic goes down: nobody else on duty, and they cannot treat themselves.
    TW.move(1, { x = DEATH.x + 10, y = DEATH.y, z = DEATH.z })
    TW.die(1)
    TW.say(1, "tti", { "take", "2" })
    return TW.result({
        civilian = civilian, ev = opState(ev), not_stable = notStable, forged = tostring(forged),
        forged_value = tostring(forgedValue), forged_v = tostring(forgedV), forged_v_why = tostring(forgedVWhy),
        forged_r = tostring(forgedR), forged_r_why = tostring(forgedRWhy),
        self_take = TW.told(1, "can't treat yourself") or TW.told(1, "Trauma Team on duty only"),
        nothing_moved = TW.balance("bank:" .. MEDIC) == 0, unbalanced = tostring(TW.unbalanced()),
    })
end

-- ---------------------------------------------------------------------------------------------
-- Crash windows: the stabilisation's commit acknowledgement is lost (charged once, the bounty
-- once, the job event once); the evacuation's commit is queued when the coordinator dies (in
-- doubt, settled by the sweep, the patient evacuated once).
-- ---------------------------------------------------------------------------------------------
function scenarios.crash_windows()
    TW.boot()
    TW.join(1, MEDIC, "Medic", NEAR)
    TW.join(2, PAT, "Patient", DEATH)
    TW.setup(1)
    TW.fund("bank:" .. PAT, 5000)
    TW.settle()
    ui().alert[2] = "confirm"
    TW.die(2)
    TW.say(1, "tti", { "take", "1" })
    local bank0 = TW.balance("bank:" .. PAT)
    local mark = TW.mark()
    SFW.intent(1, "rp_trauma:tti_stabilise", "rp_trauma:tti_patient_2")
    TW.waitState(1, "tti_stabilise", mark, "presenting", 30)
    TW.store().faults = { "lost_ack" }
    local st = TW.finish(1, "tti_stabilise", 60, mark)
    MH.run(6)
    local paidStab = bank0 - TW.balance("bank:" .. PAT)
    local jobs1 = #TW.jobs("stabilise")
    -- The evacuation: the commit is queued when the coordinator stops; it still lands.
    mark = TW.mark()
    SFW.intent(1, "rp_trauma:tti_evacuate", "rp_trauma:tti_patient_2")
    TW.waitState(1, "tti_evacuate", mark, "presenting", 30)
    MH.shared.txPaused = true
    TW.waitState(1, "tti_evacuate", mark, "committing", 30)
    MH.until_(function() return TW.store():pending() > 0 end, 10)
    MH.shared.txOnStop = "detached"
    MH.stop("open77_transactions")
    local ev = TW.finish(1, "tti_evacuate", 60, mark)
    MH.shared.txPaused = false
    MH.shared.txOnStop = nil
    TW.startCoordinator()
    MH.until_(function() return TW.entry(2) == nil end, 120)
    MH.run(8)
    return TW.result({
        st = opState(st), paid_stab = paidStab, jobs1 = jobs1, stab_ops = TW.committed("trauma.stabilise"),
        ev = opState(ev), evacuated = TW.entry(2) == nil, at_clinic = near(MH.players[2].position, CLINIC),
        evac_ops = TW.committed("trauma.evacuate"), jobs_e = #TW.jobs("evacuate"), doubts = (function()
            local n = 0 for _ in pairs(svc().doubts) do n = n + 1 end return n end)(),
        paid_total = bank0 - TW.balance("bank:" .. PAT), unbalanced = tostring(TW.unbalanced()),
    })
end

-- ---------------------------------------------------------------------------------------------
-- rp_trauma 1.x state: the unpaid SQL bills and the kvp debt become invoices, the active contract
-- becomes a plan until its paid period ends; a second join imports nothing twice.
-- ---------------------------------------------------------------------------------------------
function scenarios.legacy_import()
    local LEG = "acct-legacy"
    TW.boot({ legacy = {
        bills = { { id = 7, identifier = LEG, amount = 250 }, { id = 9, identifier = LEG, amount = 100 },
                  { id = 11, identifier = "someone-else", amount = 999 } },
        contracts = { { identifier = LEG, active = 1, until_at = 1000 + 7200 } },
    } })
    MH.kvp.rp_trauma = MH.kvp.rp_trauma or {}
    MH.kvp.rp_trauma["debt:" .. LEG] = 50
    TW.join(2, LEG, "Veteran", KIOSK)
    MH.run(4)
    local owed = TW.count(TW.file(LEG), "tti_invoice")
    local card = TW.card(LEG) or {}
    local db = MH.shared.traumaDb
    local marked = db.bills[1].paid_at == 0 and db.bills[2].paid_at == 0 and db.bills[3].paid_at == nil
    local contractOff = db.contracts[1].active == 0
    local kvpGone = MH.kvp.rp_trauma["debt:" .. LEG] == nil
    MH.disconnect(2)
    MH.run(1)
    -- The rows come back unpaid (an operator restore): the operation ids replay, nothing doubles.
    db.bills[1].paid_at = nil
    TW.join(2, LEG, "Veteran", KIOSK)
    MH.run(4)
    return TW.result({
        owed = owed, tier = card.tier, until_at = card.untilAt, marked = marked, contract_off = contractOff,
        kvp_gone = kvpGone, owed_again = TW.count(TW.file(LEG), "tti_invoice"), legacy_ops = TW.committed("trauma.legacy"),
        unbalanced = tostring(TW.unbalanced()),
    })
end

-- ---------------------------------------------------------------------------------------------
-- The legacy acts are billed through the coordinator too: /soin on a standing patient asks first
-- (no answer = no care), /reanimer on a Gold holder is covered.
-- ---------------------------------------------------------------------------------------------
function scenarios.legacy_acts()
    TW.boot()
    TW.join(1, MEDIC, "Medic", NEAR)
    TW.join(2, PAT, "Patient", NEAR2)
    TW.setup(1)
    TW.fund("bank:" .. PAT, 6000)
    TW.settle()
    MH.players[2].health = 40
    ui().alert[2] = "timeout"
    TW.say(1, "soin", { "2" }, 20)
    local silentRefused = TW.told(1, "did not accept the charges") and MH.players[2].health == 40
    ui().alert[2] = "confirm"
    MH.run(11)
    local bank0 = TW.balance("bank:" .. PAT)
    TW.say(1, "soin", { "2" }, 10)
    local healed = MH.players[2].health == 100
    local paidHeal = bank0 - TW.balance("bank:" .. PAT)
    -- Gold, then down, then /reanimer: covered, no dialog.
    TW.move(2, KIOSK)
    subscribe(2, "gold")
    TW.move(2, DEATH)
    TW.move(1, NEAR)
    local asked0 = asked(2, "alert")
    TW.die(2)
    local bank1 = TW.balance("bank:" .. PAT)
    MH.run(11)
    TW.say(1, "reanimer", { "2" }, 12)
    return TW.result({
        silent_refused = silentRefused, healed = healed, paid_heal = paidHeal,
        revived = TW.entry(2) == nil, asked_revive = asked(2, "alert") - asked0,
        paid_revive = bank1 - TW.balance("bank:" .. PAT), heal_ops = TW.committed("trauma.heal"),
        revive_ops = TW.committed("trauma.revive"), call_closed = callOf(2) == nil,
        unbalanced = tostring(TW.unbalanced()),
    })
end

-- ---------------------------------------------------------------------------------------------
-- The down state is durable. Each scenario below reads the saved entry (rp_trauma's kvp store,
-- which survives restarts) and the body itself (spot, freeze, health).
-- ---------------------------------------------------------------------------------------------

-- No escape by leaving: a player down who disconnects is down again when they come back, at the
-- spot where they fell, with what the countdown had left (it runs on while they are away). The
-- call closes while they are away and a new one goes out on their return. Said once.
function scenarios.down_reconnect()
    TW.boot()
    TW.join(1, MEDIC, "Medic", NEAR)
    TW.join(2, PAT, "Patient", DEATH)
    TW.setup(1)
    TW.settle()
    local entry = TW.die(2) or {}
    local deadlineUnix = entry.deadlineUnix or -1
    local saved1 = TW.saved(PAT) ~= nil
    TW.say(1, "tti", { "take", "1" })
    MH.run(8)
    MH.disconnect(2)
    MH.run(1)
    local callGone = callOf(2) == nil
    local closedLeft = events("closed", 2)
    local toldMedicClosed = TW.told(1, "Call #1 closed: the patient disconnected")
    local keptSaved = TW.saved(PAT) ~= nil
    MH.run(15)
    local back = TW.rejoin(2, PAT, "Patient") or {}
    local leftBack = back.deadline and math.ceil(back.deadline - MH.now) or -1
    local leftExpected = deadlineUnix - math.floor(MH.now)
    local held, frozen = back.held == true, MH.players[2].frozen == true
    local atDeath = near(MH.players[2].position, DEATH)
    local health = MH.players[2].health
    local call2 = callOf(2) or {}
    -- A second alive phase of the same spawn holds again, in silence.
    MH.shared.trauma.revision = MH.shared.trauma.revision + 1
    MH.emit("onPlayerLifeStateChanged", 2, MH.shared.trauma.revision, "alive")
    MH.run(18)    -- an uninsured call reaches the medics after 15 s
    return TW.result({
        saved1 = saved1, call_gone = callGone, closed_left = closedLeft, told_medic_closed = toldMedicClosed,
        kept_saved = keptSaved, back_down = back.position ~= nil, held = held, frozen = frozen, at_death = atDeath,
        health = health, same_deadline = back.deadlineUnix == deadlineUnix, left_back = leftBack,
        left_expected = leftExpected, call2 = tostring(call2.id), open_events = events("open", 2),
        told_call2 = TW.told(2, "emergency call #2 placed"),
        told_medic2 = TW.told(1, "%[UNINSURED #2%] Patient %(id 2%) is down"),
        target = targetActions(2), still_told = TW.toldCount(2, "^You are still down where you fell%. Trauma Team"),
        down_told = TW.toldCount(2, "^You are down%. Trauma Team"), frozen_end = tostring(MH.players[2].frozen),
    })
end

-- A stable patient who disconnects comes back stable: same health, a Gold call that is already
-- stable (the body offers Evacuate, the stabilisation is not sold twice), and the evacuation of the
-- resumed body clears the saved state.
function scenarios.down_stable_reconnect()
    TW.boot()
    TW.join(1, MEDIC, "Medic", NEAR)
    TW.join(2, PAT, "Patient", KIOSK)
    TW.setup(1)
    TW.fund("bank:" .. PAT, 10000)
    subscribe(2, "gold")
    TW.move(2, DEATH)
    TW.settle()
    TW.die(2)
    TW.say(1, "tti", { "take" })
    local st = TW.act(1, "tti_stabilise", "tti_patient_2", 60)
    local stableHealth = MH.players[2].health
    local savedStable = (TW.saved(PAT) or ""):find("stable=1", 1, true) ~= nil
    MH.disconnect(2)
    MH.run(5)
    local back = TW.rejoin(2, PAT, "Patient") or {}
    MH.run(2)
    local call = callOf(2) or {}
    local result = {
        st = opState(st), stable_health = stableHealth, saved_stable = savedStable, back_stable = back.stable == true,
        held = back.held == true, health = MH.players[2].health, at_death = near(MH.players[2].position, DEATH),
        call_stable = call.stable == true, call_tier = tostring(call.tierKey), target = targetActions(2),
        still_told = TW.toldCount(2, "^You are still down, but stable"),
    }
    TW.say(1, "tti", { "take" })
    local ev = TW.act(1, "tti_evacuate", "tti_patient_2", 60)
    MH.run(1)
    result.ev = opState(ev)
    result.released = TW.entry(2) == nil
    result.at_clinic = near(MH.players[2].position, CLINIC)
    result.saved_gone = TW.saved(PAT) == nil
    result.stab_ops = TW.committed("trauma.stabilise")
    result.unbalanced = tostring(TW.unbalanced())
    return TW.result(result)
end

-- No escape by a restart: rp_trauma stops while a player is down. The body is unfrozen (the
-- resource is going away) but keeps its down health; the next start holds it down again at the
-- same spot, with the same deadline, and raises a new call.
function scenarios.down_resource_restart()
    TW.boot()
    TW.join(1, MEDIC, "Medic", NEAR)
    TW.join(2, PAT, "Patient", DEATH)
    TW.setup(1)
    TW.settle()
    local entry = TW.die(2) or {}
    local deadlineUnix = entry.deadlineUnix or -1
    local lowHealth = MH.players[2].health
    MH.run(5)
    MH.stop("rp_trauma")
    MH.run(1)
    local holds = TW.clientEvents(2, "rp_trauma:hold")
    local last = holds[#holds] or {}
    local stopped = {
        frozen = tostring(MH.players[2].frozen), health = MH.players[2].health, regen = tostring(MH.players[2].regen),
        unhold = tostring(last[1]), saved = TW.saved(PAT) ~= nil,
        logged = TW.printed("stopped: every held player unfrozen, 1 down state%(s%) kept") == 1,
    }
    MH.run(3)
    local healthBetween = MH.players[2].health
    TW.startTrauma()
    MH.until_(function() return TW.svc() and TW.svc().ready and TW.svc().actionsReady end, 30)
    MH.run(3)
    local back = TW.entry(2) or {}
    return TW.result({
        low_health = lowHealth, stopped_frozen = stopped.frozen, stopped_health = stopped.health,
        stopped_regen = stopped.regen, stopped_unhold = stopped.unhold, stopped_saved = stopped.saved,
        stopped_logged = stopped.logged, health_between = healthBetween,
        back_down = back.position ~= nil, held = back.held == true, frozen = tostring(MH.players[2].frozen),
        health = MH.players[2].health, at_death = near(MH.players[2].position, DEATH),
        same_deadline = back.deadlineUnix == deadlineUnix, call = tostring((callOf(2) or {}).id),
        target = targetActions(2), still_told = TW.toldCount(2, "^You are still down where you fell"),
    })
end

-- A held body that fell through a floor that had not streamed in (2000 m below its spot) is put
-- back on the spot within the down loop's next pass, at most every 5 s, and left alone once there.
function scenarios.down_body_fell_through()
    TW.boot()
    TW.join(1, MEDIC, "Medic", NEAR)
    TW.join(2, PAT, "Patient", DEATH)
    TW.setup(1)
    TW.settle()
    TW.die(2)
    MH.run(2)
    local before = #MH.shared.trauma.teleports
    TW.move(2, { x = DEATH.x, y = DEATH.y, z = DEATH.z - 2000.0 })
    MH.run(2)
    local after = #MH.shared.trauma.teleports
    local back = lastTeleport(2)
    TW.move(2, DEATH)     -- the fake teleport records; the body is where it was sent
    MH.run(12)
    local quiet = #MH.shared.trauma.teleports
    return TW.result({
        put_back = after - before, back_at_death = back ~= nil and near(back, DEATH) and math.abs(back.z - DEATH.z) < 0.01,
        logged = TW.printed("held body [%d%.]+ m from its spot") >= 1, again = quiet - after,
        still_held = (TW.entry(2) or {}).held == true,
        hidden_for = (function()
            local engine = MH.resources.open77_actions.env.Open77ActionsRuntime.engine
            local t = engine.targets["rp_trauma:tti_patient_2"]
            return t and t.hideFor and table.concat(t.hideFor, ",") or "none"
        end)(),
        crowd_off = tostring((MH.resources.open77_actions.env.Open77ActionsRuntime.engine
            .targets["rp_trauma:tti_patient_2"] or {}).keepCrowdOff),
    })
end

-- The countdown ran out while the player was away: they are still down when they come back, and
-- /respawn is open at once (even with a medic on duty). Before the body is held, /respawn waits.
-- This join reports no alive phase after the entry is back: the connect grace holds the body.
function scenarios.down_expired_while_away()
    TW.boot()
    TW.join(1, MEDIC, "Medic", NEAR)
    TW.join(2, PAT, "Patient", DEATH)
    TW.setup(1)
    TW.settle()
    TW.die(2)
    MH.disconnect(2)
    MH.run(70)
    TW.join(2, PAT, "Patient", TW.SPAWN)
    local early = TW.entry(2) or {}
    local resumedEarly, heldEarly = early.position ~= nil, early.held == true
    TW.say(2, "respawn", {}, 1)
    local toldSettling = TW.told(2, "Hold on, the body is still settling")
    local stillAfterEarly = TW.entry(2) ~= nil
    MH.run(15)
    local back = TW.entry(2) or {}
    local left = back.deadline and math.max(0, math.ceil(back.deadline - MH.now)) or -1
    local held, frozen, atDeath = back.held == true, MH.players[2].frozen == true, near(MH.players[2].position, DEATH)
    local health = MH.players[2].health
    local toldRanOut = TW.toldCount(2, "^You are still down where you fell, and your countdown has run out")
    MH.run(3)
    local toldOpenAgain = TW.toldCount(2, "^/respawn is open")
    TW.say(2, "respawn", {}, 4)
    return TW.result({
        resumed_early = resumedEarly, held_early = heldEarly, told_settling = toldSettling,
        still_after_early = stillAfterEarly, held = held, frozen = frozen, at_death = atDeath, health = health,
        left = left, told_ran_out = toldRanOut, told_open_again = toldOpenAgain,
        released = TW.entry(2) == nil, at_clinic = near(MH.players[2].position, CLINIC),
        hosp_ops = TW.committed("trauma.hospital"), saved_gone = TW.saved(PAT) == nil,
        unbalanced = tostring(TW.unbalanced()),
    })
end

-- Getting up clears the saved state: after /respawn at Vik's, a disconnect and a return find the
-- player on their feet.
function scenarios.down_respawn_clears()
    TW.boot()
    TW.join(2, PAT, "Patient", DEATH)
    TW.settle()
    TW.die(2)
    local saved1 = TW.saved(PAT) ~= nil
    MH.run(61)
    TW.say(2, "respawn", {}, 4)
    local released = TW.entry(2) == nil
    local savedAfter = TW.saved(PAT) ~= nil
    MH.disconnect(2)
    MH.run(5)
    TW.rejoin(2, PAT, "Patient")
    MH.run(16)
    return TW.result({
        saved1 = saved1, released = released, saved_after = savedAfter, back_down = TW.entry(2) ~= nil,
        frozen = tostring(MH.players[2].frozen == true), health = MH.players[2].health,
        at_spawn = near(MH.players[2].position, TW.SPAWN), still_told = TW.toldCount(2, "^You are still down"),
        unbalanced = tostring(TW.unbalanced()),
    })
end

-- A stale saved state is dropped. Through a server restart (the kvp file survives it): back a
-- minute later, the player is still down; back five hours later (the cap is 3 h), the start drops
-- the entry and the player comes back up. On a return: an entry older than the cap is dropped.
function scenarios.down_stale_dropped()
    TW.boot()
    TW.join(2, PAT, "Patient", DEATH)
    TW.settle()
    local entry = TW.die(2) or {}
    local deadlineUnix = entry.deadlineUnix or -1
    TW.boot({ keep = TW.keep() })
    local back = TW.rejoin(2, PAT, "Patient") or {}
    local restartDown, restartHeld = back.position ~= nil, back.held == true
    local restartAtDeath = near(MH.players[2].position, DEATH)
    local restartSameDeadline = back.deadlineUnix == deadlineUnix
    local keep = TW.keep()
    keep.now = keep.now + 5 * 3600
    TW.boot({ keep = keep })
    local purged = TW.printed("1 stale saved down state%(s%) dropped") == 1
    local savedAfterPurge = TW.saved(PAT) ~= nil
    TW.rejoin(2, PAT, "Patient")
    MH.run(16)
    local upAfterPurge = TW.entry(2) == nil and MH.players[2].frozen ~= true
    -- On a return: the cap lowered to 2 minutes, the player away for 3.
    TW.join(3, PAT2, "Leaver", DEATH)
    TW.settle()
    TW.die(3)
    local savedLeaver = TW.saved(PAT2) ~= nil
    MH.resources.rp_trauma.env.Config.downPersistMaxSeconds = 120
    MH.disconnect(3)
    MH.run(180)
    TW.rejoin(3, PAT2, "Leaver")
    MH.run(16)
    return TW.result({
        restart_down = restartDown, restart_held = restartHeld, restart_at_death = restartAtDeath,
        restart_same_deadline = restartSameDeadline, purged = purged, saved_after_purge = savedAfterPurge,
        up_after_purge = upAfterPurge, saved_leaver = savedLeaver, leaver_down = TW.entry(3) ~= nil,
        leaver_frozen = tostring(MH.players[3].frozen == true), leaver_health = MH.players[3].health,
        leaver_saved = TW.saved(PAT2) ~= nil, leaver_logged = TW.printed("saved down state dropped %(fell %d+ s ago") == 1,
    })
end

-- Config.downPersist = false: the old rules. Nothing is saved, a stop frees the body at full
-- health, and the next start finds nobody down.
function scenarios.down_persist_off()
    TW.boot()
    TW.join(2, PAT, "Patient", DEATH)
    TW.settle()
    MH.resources.rp_trauma.env.Config.downPersist = false
    TW.die(2)
    local savedOff = TW.saved(PAT) ~= nil
    MH.stop("rp_trauma")
    MH.run(1)
    local healthStopped, frozenStopped = MH.players[2].health, tostring(MH.players[2].frozen == true)
    TW.startTrauma()
    MH.until_(function() return TW.svc() and TW.svc().ready and TW.svc().actionsReady end, 30)
    MH.run(3)
    return TW.result({
        saved_off = savedOff, health_stopped = healthStopped, frozen_stopped = frozenStopped,
        down_after = TW.entry(2) ~= nil, logged = TW.printed("0 down state%(s%) kept") == 1,
    })
end

function RUN_SCENARIO(name)
    local fn = scenarios[name]
    if not fn then error("unknown scenario " .. tostring(name)) end
    local ok, result = xpcall(fn, debug.traceback)
    if not ok then
        return "errors=1\nfirst_error=" .. tostring(result):gsub("\n", " | ")
    end
    return result
end
