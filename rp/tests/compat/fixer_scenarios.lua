-- tests/compat/fixer_scenarios.lua: the fixer contract board (rp_fixer 2.0) end to end, offline.
--
-- Loaded by tests/test_fixer.py with the string globals ROOT_DIR, COMPAT_DIR, SYS_DIR and TX_DIR
-- (fixer_world.lua). Players act the way their clients make them act: prompt intents from where
-- they stand, chat commands, and answers to the UI kit dialogs. Every check reads durable truth:
-- the coordinator's store (money, goods) and rp_fixer's SQL tables (contracts, reputation).

dofile(COMPAT_DIR .. "/fixer_world.lua")

local scenarios = {}

local A, B, C = "acct-a", "acct-b", "acct-c"     -- the fixer, the runner, the observer

local function svc() return FXW.svc() end

local function near(p, dx, dy) return { x = p.x + (dx or 0.6), y = p.y + (dy or 0.0), z = p.z } end

local function liveRow(id) return MH.shared.fxdb.contracts[id] end
local function repOf(identifier) local r = MH.shared.fxdb.rep[identifier] return r and r.score or 0 end

local function jobEvent(kind)
    for _, e in ipairs(MH.shared.jobEvents) do
        if e.job == "fixer" and e.kind == kind then return e end
    end
    return nil
end

local function carrying(pid)
    local ok, item = MH.callSync("fx_probe", "open77_actions", "carrying", pid)
    return ok and item ~= nil and item ~= false
end

-- A fixer on duty posts a contract through the board: E, "Post a contract", the template, the
-- form, the escrow confirmation.
local function postThroughBoard(pid, hub, template, reward, hours, brief, mode)
    FXW.script(pid, {
        { kind = "context", value = { id = "post" } },
        { kind = "context", value = { id = "t:" .. template } },
        { kind = "input", value = { reward = reward, hours = tostring(hours), brief = brief, mode = mode } },
        { kind = "alert", value = "confirm" },
    })
    return FXW.board(pid, hub)
end

-- A runner takes a contract through the board: E, the row, "Take the contract".
local function takeThroughBoard(pid, hub, c)
    FXW.script(pid, {
        { kind = "context", value = { id = "c:" .. c.id } },
        { kind = "alert", value = "confirm" },
    })
    return FXW.board(pid, hub)
end

-- NPC fixers post from the console (`fixer.post <template> [hub] [reward]`).
local function npcPost(template, hub, reward)
    local before = svc().seq
    MH.command("fixer.post", 0, { template, hub, reward and tostring(reward) or nil })
    local c
    MH.until_(function()
        for _, x in pairs(svc().contracts) do
            if x.seq > before and x.template == template then c = x end
        end
        return c ~= nil and c.state ~= "posting"
    end, 30)
    MH.run(1)
    return c
end

-- ---------------------------------------------------------------------------------------------
-- Delivery, two players and an observer: the fixer posts through the board (escrow out of their
-- wallet), the runner takes it through the board, carries the crate from Noodle Row to Regina's
-- corner and is paid out of escrow in one operation; the observer sees the contract only while it
-- is open and cannot lift the crate.
-- ---------------------------------------------------------------------------------------------
function scenarios.delivery()
    FXW.boot({ writers = FXW.WRITERS_STRICT })
    local REGINA, NOODLE = FXW.hub("regina"), FXW.point("kabuki_noodle_row")
    FXW.join(1, A, "Fixer Ana", near(REGINA))
    FXW.join(2, B, "Runner Ben", near(REGINA, -0.6))
    FXW.join(3, C, "Observer Cy", near(REGINA, 0, 0.6))
    FXW.setJob(1, "fixer", true)
    FXW.give(1, 5000)
    local cashA0, cashB0 = FXW.balance("cash:" .. A), FXW.balance("cash:" .. B)

    local board1 = postThroughBoard(1, "regina", "regina_noodle_drop", 600, 2, "Do not open it. Really.")
    MH.until_(function() return FXW.contract(1) ~= nil and FXW.contract(1).state == "open" end, 30)
    local c = FXW.contract(1)
    local escrowAfterPost = FXW.balance("soc:fixer_escrow")
    local cashA1 = FXW.balance("cash:" .. A)

    -- The observer's board shows the open contract.
    FXW.script(3, { { kind = "context", cancel = true } })
    FXW.board(3, "regina")
    local seenOpen = FXW.rowsOf(FXW.lastBoard(3))["c:" .. c.id] ~= nil

    -- The runner takes it.
    takeThroughBoard(2, "regina", c)
    FXW.until_(c, "taken", 20)
    MH.run(1)
    local crate = FXW.crateOf(c)
    FXW.script(3, { { kind = "context", cancel = true } })
    FXW.board(3, "regina")
    local seenTaken = FXW.rowsOf(FXW.lastBoard(3))["c:" .. c.id] ~= nil
    local posterToldTaken = FXW.told(1, "was taken by Runner Ben")

    -- The observer cannot lift the runner's crate.
    SFW.move(3, near(NOODLE, 0.4))
    MH.run(1)
    local cPick = FXW.pickup(3, c)
    local observerRefused = table.concat(SFW.refusals(3), ",")

    -- The runner lifts it at Noodle Row.
    SFW.move(2, near(NOODLE, -0.4))
    MH.run(1)
    local pick = FXW.pickup(2, c)
    local carried = c.crate.carried
    -- The wrong drop keeps the crate in the runner's hands.
    SFW.move(2, near(FXW.hub("afterlife")))
    MH.run(1)
    local wrong = FXW.deliver(2, "afterlife")
    local stillCarrying = carrying(2)
    -- The right drop.
    SFW.move(2, near(REGINA, -0.4))
    MH.run(1)
    local drop = FXW.deliver(2, "regina")
    FXW.until_(c, "completed", 40)
    MH.run(1)
    local agrees, agreeText = FXW.escrowAgrees()
    local ev = jobEvent("contract_completed")
    local row = liveRow(c.id)
    return FXW.result({
        board1 = board1 and board1.state, posted = c.state ~= nil, reward = c.reward, net = c.net, cut = c.cut,
        escrow_after_post = escrowAfterPost, poster_paid = cashA0 - cashA1, poster_after = cashA0 - FXW.balance("cash:" .. A),
        seen_open = seenOpen, seen_taken_by_observer = seenTaken, poster_told_taken = posterToldTaken,
        crate_placed = crate ~= nil, observer_pick = cPick and cPick.state or "refused", observer_refused = observerRefused,
        pick = pick and pick.state, carried = carried,
        wrong = wrong and wrong.state, wrong_reason = wrong and wrong.reason, still_carrying = stillCarrying,
        drop = drop and drop.state, state = c.state, runner_paid = FXW.balance("cash:" .. B) - cashB0,
        society = FXW.balance("soc:fixer"), escrow_end = FXW.balance("soc:fixer_escrow"), escrow_agrees = agrees,
        escrow_text = agreeText, rep_b = repOf(B), rep_log = MH.shared.fxdb.replog[c.id .. ":done"] ~= nil,
        row_state = row and row.state, row_live = row and row.live, history = #MH.shared.fxdb.gigs,
        event_player = ev and ev.playerId, event_ref = ev and ev.ref, gig_success = FXW.printed("completed: delivery"),
        runner_told = FXW.told(2, "Contract #1 done: 540 eddies"), poster_told_done = FXW.told(1, "completed by Runner Ben"),
        crate_gone = FXW.crateOf(c) == nil, unbalanced = tostring(SFW.unbalanced()),
        ui_mismatch = MH.shared.uiMismatch or "none",
    })
end

local function emitJob(payload)
    MH.resources.fx_probe.env.TriggerEvent("rp:job:completed", payload)
    MH.run(1)
end

local function cmd(pid, verb, ...)
    MH.command("contract", pid, { verb, ... })
    MH.run(2)
end

-- ---------------------------------------------------------------------------------------------
-- Retrieval: a fixer NPC's contract (goods burned), then a player fixer's (goods into their drop
-- box, collected at the board). The hand-over is refused before the bar without the goods.
-- ---------------------------------------------------------------------------------------------
function scenarios.retrieval()
    FXW.boot({ writers = FXW.WRITERS_STRICT })
    local AFTER = FXW.hub("afterlife")
    FXW.join(1, A, "Fixer Ana", near(AFTER))
    FXW.join(2, B, "Runner Ben", near(AFTER, -0.6))
    FXW.setJob(1, "fixer", true)
    FXW.give(1, 5000)
    local c1 = npcPost("afterlife_chips", "afterlife", 600)
    cmd(2, "take", tostring(c1.seq))
    local taken = c1.state
    local cashB0 = FXW.balance("cash:" .. B)
    -- No chips: refused before the bar, and told why.
    local h0 = FXW.handover(2, "afterlife")
    local toldMissing = FXW.told(2, "You do not have everything")
    FXW.giveItem(2, "chip", 5)
    MH.run(1)
    local h1 = FXW.handover(2, "afterlife")
    FXW.until_(c1, "completed", 40)
    MH.run(1)
    local chipsAfter1 = FXW.count("char:" .. B, "chip")
    local burned = SFW.journal("^sys:fixer%.retrieval$", "chip")
    local paid1 = FXW.balance("cash:" .. B) - cashB0
    local repAfter1 = repOf(B)

    -- The player fixer's retrieval: the chips go to the poster's drop box.
    MH.command("contract", 1, { "post", "afterlife_chips", "700", "4" })
    MH.until_(function() return FXW.contract(2) ~= nil and FXW.contract(2).state == "open" end, 30)
    local c2 = FXW.contract(2)
    cmd(2, "take", "2")
    FXW.giveItem(2, "chip", 1)
    MH.run(1)
    local h2 = FXW.handover(2, "afterlife")
    FXW.until_(c2, "completed", 40)
    MH.run(1)
    local boxChips = FXW.count("stash:fxbox." .. A, "chip")
    -- A collects the box at the board.
    FXW.script(1, { { kind = "context", value = { id = "box" } } })
    FXW.board(1, "afterlife")
    MH.run(3)
    local agrees = FXW.escrowAgrees()
    return FXW.result({
        taken = taken, h0 = h0 and h0.state, h0_reason = h0 and h0.reason, h0_stage = h0 and h0.stage,
        told_missing = toldMissing, h1 = h1 and h1.state, c1 = c1.state, chips_after1 = chipsAfter1, burned = burned,
        paid1 = paid1, net1 = c1.net, rep_after1 = repAfter1,
        h2 = h2 and h2.state, c2 = c2.state, box_chips = boxChips, box_after = FXW.count("stash:fxbox." .. A, "chip"),
        a_chips = FXW.count("char:" .. A, "chip"), b_chips = FXW.count("char:" .. B, "chip"), rep_end = repOf(B),
        escrow_agrees = agrees, escrow_end = FXW.balance("soc:fixer_escrow"), society = FXW.balance("soc:fixer"),
        told_box = FXW.told(1, "You collect your drop box: 3 x Data chip"), unbalanced = tostring(SFW.unbalanced()),
        told_label = FXW.told(2, "Handed over: 3 x Data chip"),
        ui_mismatch = MH.shared.uiMismatch or "none",
    })
end

-- ---------------------------------------------------------------------------------------------
-- Job order: satisfied by another job's `rp:job:completed` events, each ref counted once, only
-- the runner's own events, gated by reputation.
-- ---------------------------------------------------------------------------------------------
function scenarios.job_order()
    FXW.boot()
    local WAKAKO = FXW.hub("wakako")
    FXW.setRep(B, 3)
    FXW.join(2, B, "Runner Ben", near(WAKAKO, -0.6))
    FXW.join(3, C, "Observer Cy", near(WAKAKO, 0.6))
    local c = npcPost("wakako_chooh2", "wakako", 2000)
    cmd(3, "take", tostring(c.seq))
    local lowRep = FXW.told(3, "reputation is too low")
    -- An event before anyone holds it counts for nobody.
    emitJob({ job = "chooh2", kind = "refine", playerId = 2, ref = "chooh2:early", data = { canisters = 5 } })
    cmd(2, "take", tostring(c.seq))
    local cashB0 = FXW.balance("cash:" .. B)
    emitJob({ job = "chooh2", kind = "refine", playerId = 2, ref = "chooh2:r1", data = { canisters = 4 } })
    local p1 = c.order.progress
    emitJob({ job = "chooh2", kind = "refine", playerId = 2, ref = "chooh2:r1", data = { canisters = 4 } })   -- replayed
    emitJob({ job = "chooh2", kind = "sell", playerId = 2, ref = "chooh2:s1", data = { canisters = 4 } })     -- other kind
    emitJob({ job = "netrunner", kind = "refine", playerId = 2, ref = "nr:x", data = { canisters = 4 } })     -- other job
    emitJob({ job = "chooh2", kind = "refine", playerId = 3, ref = "chooh2:c1", data = { canisters = 9 } })   -- not the runner
    emitJob({ job = "chooh2", kind = "refine", playerId = "2", ref = "chooh2:bad" })                      -- 1 unit, string id
    emitJob({ job = "chooh2", playerId = 2, ref = "x" })                                                     -- malformed
    emitJob("garbage")
    local p2 = c.order.progress
    local row = FXW.decode(liveRow(c.id).data)
    emitJob({ job = "chooh2", kind = "refine", playerId = 2, ref = "chooh2:r2", data = { canisters = 6 } })
    FXW.until_(c, "completed", 40)
    MH.run(1)
    emitJob({ job = "chooh2", kind = "refine", playerId = 2, ref = "chooh2:r3", data = { canisters = 6 } })   -- after
    local ev = jobEvent("contract_completed")
    -- The operator sets a reputation (SQL and the cache agree).
    MH.command("fixer.setrep", 0, { "3", "4" })
    MH.run(2)
    local setrep = repOf(C) .. "/" .. tostring(svc().reps[C].score)
    return FXW.result({
        setrep = setrep,
        low_rep = lowRep, state = c.state, p1 = p1, p2 = p2, saved_progress = row and row.order.progress,
        saved_refs = row and #row.order.refs, progress_end = c.order.progress,
        paid = FXW.balance("cash:" .. B) - cashB0, net = c.net, rep_b = repOf(B),
        event_kind = ev and ev.kind, event_player = ev and ev.playerId, event_contract_kind = ev and ev.data.contractKind,
        told_progress = FXW.told(2, "Contract #1: 4 / 10"), escrow_agrees = FXW.escrowAgrees(),
        unbalanced = tostring(SFW.unbalanced()),
    })
end

-- ---------------------------------------------------------------------------------------------
-- A nomad run order: rp_nomade fires `deliver` per crate, `data.complete = true` on the last one.
-- Only the run brought home counts (template `match = { complete = true }`), not its first crate.
-- ---------------------------------------------------------------------------------------------
function scenarios.smuggle_order()
    FXW.boot()
    local AFTER = FXW.hub("afterlife")
    FXW.setRep(B, 3)
    FXW.join(2, B, "Runner Ben", near(AFTER, -0.6))
    local c = npcPost("afterlife_smuggle", "afterlife", 2000)
    cmd(2, "take", tostring(c.seq))
    local taken = c.state
    local function deliver(ref, i, complete)
        emitJob({ job = "nomad", kind = "deliver", playerId = 2, ref = ref,
                  data = { run = "r1", route = "afterlife", crate = i, of = 3, buyer = "fence", complete = complete } })
    end
    deliver("nmd.sale:1", 1, false)
    deliver("nmd.sale:2", 2, false)
    local afterTwo, progressTwo = c.state, c.order.progress
    deliver("nmd.sale:3", 3, true)
    FXW.until_(c, "completed", 40)
    MH.run(1)
    return FXW.result({
        taken = taken, after_two = afterTwo, progress_two = progressTwo, state = c.state,
        progress_end = c.order.progress, escrow_agrees = FXW.escrowAgrees(),
        unbalanced = tostring(SFW.unbalanced()),
    })
end

-- ---------------------------------------------------------------------------------------------
-- Cyberpsycho bounties: an open bounty paid to whoever kills it; a claimed bounty spoiled by a
-- kill of someone else (refund); a claimed bounty whose foreign kill respawns the target, then
-- the runner's kill credited by the last hit and the health backstop.
-- ---------------------------------------------------------------------------------------------
function scenarios.bounty()
    FXW.boot()
    local REGINA = FXW.hub("regina")
    FXW.setRep(B, 8)
    FXW.join(1, A, "Fixer Ana", near(REGINA))
    FXW.join(2, B, "Runner Ben", near(REGINA, -0.6))
    FXW.join(3, C, "Observer Cy", near(REGINA, 0, 0.6))
    FXW.setJob(1, "fixer", true)
    FXW.give(1, 10000)
    local cashC0, cashB0, cashA0 = FXW.balance("cash:" .. C), FXW.balance("cash:" .. B), FXW.balance("cash:" .. A)

    -- 1. Open bounty: held back while a player stands on the sighting, spawned once the spot is
    -- clear; hostile, platform-priced, leashed; engages the nearest player.
    SFW.move(3, near(FXW.sighting("kabuki_alley"), 1))
    local c1 = npcPost("regina_psycho_kabuki", "regina", 2000)
    local heldOnPlayer = FXW.npcOf(c1) == nil
    SFW.move(3, near(FXW.sighting("kabuki_alley"), 10))
    MH.run(12)
    local npc1 = FXW.npcOf(c1)
    local n1 = npc1 and FXW.npc(npc1)
    SFW.move(3, near(FXW.sighting("kabuki_alley"), 10))
    MH.run(3)
    local engaged = n1 and n1.attacking
    local openTake = (function() cmd(2, "take", tostring(c1.seq)) return FXW.told(2, "Open bounty") end)()
    FXW.damage(npc1, "player:3", 150)
    FXW.kill(npc1, "player:3")
    FXW.until_(c1, "completed", 40)
    MH.run(1)
    local c1Paid = FXW.balance("cash:" .. C) - cashC0

    -- 2. Claimed bounty, foreign kill: void, the poster (an NPC) refunded, nobody paid.
    local c2 = npcPost("regina_psycho_northside", "regina", 3000)
    local spawnedBeforeTake = FXW.npcOf(c2) ~= nil
    cmd(2, "take", tostring(c2.seq))
    local npc2 = FXW.npcOf(c2)
    FXW.kill(npc2, "player:3")
    FXW.until_(c2, "spoiled", 40)
    MH.run(1)

    -- 3. Claimed, player-posted, foreign kill respawns; the runner's kill pays.
    SFW.move(3, near(REGINA, 0, 0.6))
    MH.command("contract", 1, { "post", "junkyard_psycho", "3000", "2" })
    MH.until_(function() return FXW.contract(3) ~= nil and FXW.contract(3).state == "open" end, 30)
    local c3 = FXW.contract(3)
    cmd(2, "take", "3")
    local npc3 = FXW.npcOf(c3)
    FXW.kill(npc3, "player:3")
    MH.run(2)
    local afterForeign = c3.state
    MH.run(65)
    local npc3b = FXW.npcOf(c3)
    local respawned = npc3b ~= nil and npc3b ~= npc3
    -- The runner hits it, then it dies of nothing the platform names: the last hit is credited
    -- (here through the health backstop: no onNpcDied at all).
    FXW.damage(npc3b, "player:2", 120)
    MH.shared.world.npcs[npc3b].health = 0
    FXW.until_(c3, "completed", 40)
    MH.run(1)
    return FXW.result({
        c1 = c1.state, npc1 = npc1 ~= nil, held_on_player = heldOnPlayer, record = n1 and n1.record, hit_pricing = n1 and n1.behavior and n1.behavior.hitPricing,
        damage_policy = n1 and n1.damagePolicy, attitude = n1 and n1.attitude, leash = n1 and n1.tasks[1] and n1.tasks[1].type,
        engaged = engaged, open_take_refused = openTake, c1_payee = c1.payee and c1.payee.subject, c1_paid = c1Paid,
        c1_net = c1.net, rep_c = repOf(C),
        spawned_before_take = spawnedBeforeTake, npc2 = npc2 ~= nil, c2 = c2.state, c2_outcome = c2.outcome,
        b_paid_after_c2 = FXW.balance("cash:" .. B) - cashB0 - (c3.state == "completed" and c3.net or 0),
        runner_told_spoiled = FXW.told(2, "Someone else put down the psycho"),
        after_foreign = afterForeign, respawned = respawned, c3 = c3.state, c3_payee = c3.payee and c3.payee.subject,
        b_paid = FXW.balance("cash:" .. B) - cashB0, c3_net = c3.net, rep_b = repOf(B),
        poster_a_paid = cashA0 - FXW.balance("cash:" .. A), c3_reward = c3.reward,
        npc_left = (function() local n = 0 for _ in pairs(MH.shared.world.npcs) do n = n + 1 end return n end)(),
        escrow_end = FXW.balance("soc:fixer_escrow"), escrow_agrees = FXW.escrowAgrees(),
        unbalanced = tostring(SFW.unbalanced()),
    })
end

-- ---------------------------------------------------------------------------------------------
-- Expiry, cancellation, abandonment: every end that is not a completion refunds the poster in
-- full; the runner loses reputation for walking away or running out of time.
-- ---------------------------------------------------------------------------------------------
function scenarios.expiry()
    FXW.boot()
    local REGINA, NOODLE = FXW.hub("regina"), FXW.point("kabuki_noodle_row")
    FXW.setRep(B, 2)
    FXW.join(1, A, "Fixer Ana", near(REGINA))
    FXW.join(2, B, "Runner Ben", near(REGINA, -0.6))
    FXW.setJob(1, "fixer", true)
    FXW.give(1, 5000)
    local cashA0 = FXW.balance("cash:" .. A)

    -- An NPC contract nobody takes runs out: the escrow goes back where it came from.
    local c1 = npcPost("regina_noodle_drop", "regina", 500)
    MH.command("fixer.expire", 0, { tostring(c1.seq) })
    FXW.until_(c1, "expired", 30)
    MH.run(1)
    local npcRefund = SFW.journal("^sys:rp_fixer:board$", "money")

    -- The poster cancels an open contract.
    MH.command("contract", 1, { "post", "afterlife_chips", "600", "4" })
    MH.until_(function() return FXW.contract(2) ~= nil and FXW.contract(2).state == "open" end, 30)
    local c2 = FXW.contract(2)
    local afterPost = FXW.balance("cash:" .. A)
    cmd(1, "cancel", "2")
    FXW.until_(c2, "cancelled", 30)
    MH.run(1)
    local afterCancel = FXW.balance("cash:" .. A)

    -- The runner abandons a taken delivery, takes it again, and runs out of time.
    MH.command("contract", 1, { "post", "regina_noodle_drop", "500", "1" })
    MH.until_(function() return FXW.contract(3) ~= nil and FXW.contract(3).state == "open" end, 30)
    local c3 = FXW.contract(3)
    cmd(2, "take", "3")
    local crate1 = FXW.crateOf(c3)
    cmd(2, "drop", "3")
    local afterAbandon = c3.state
    local crateGone = FXW.crateOf(c3) == nil and MH.callSync("fx_probe", "open77_actions", "carryGet", crate1) ~= nil
    local repAbandon = repOf(B)
    cmd(2, "take", "3")
    SFW.move(2, near(NOODLE, -0.4))
    MH.run(1)
    local pick = FXW.pickup(2, c3)
    MH.now = MH.now + 3700     -- an hour later
    FXW.until_(c3, "expired", 30)
    MH.run(2)
    local afterExpiry = FXW.balance("cash:" .. A)
    return FXW.result({
        c1 = c1.state, c1_outcome = c1.outcome, npc_refund_net = npcRefund,
        c2 = c2.state, post_paid = cashA0 - afterPost, cancel_back = afterCancel - afterPost,
        after_abandon = afterAbandon, crate_removed = crateGone, rep_abandon = repAbandon,
        pick = pick and pick.state, c3 = c3.state, rep_expire = repOf(B), runner_dropped = not carrying(2),
        a_fixer_net = FXW.fixerDelta("cash:" .. A), a_paydays = afterExpiry - cashA0,
        told_expired = FXW.told(2, "Too slow: contract #3 ran out"),
        told_refund = FXW.told(1, "Contract #3 expired: 500 eddies back"),
        escrow_end = FXW.balance("soc:fixer_escrow"), unbalanced = tostring(SFW.unbalanced()),
        gig_timeout = (function()
            for _, e in ipairs(MH.shared.gigEvents) do if e.phase == "timeout" then return e.seq end end
            return "none"
        end)(),
    })
end

-- ---------------------------------------------------------------------------------------------
-- Restart with open contracts: a carried-then-dropped crate, an open bounty and a taken retrieval
-- survive a server restart; everything comes back where it was and pays once after it.
-- ---------------------------------------------------------------------------------------------
function scenarios.restart()
    FXW.boot({ writers = FXW.WRITERS_STRICT })
    local REGINA, NOODLE, AFTER = FXW.hub("regina"), FXW.point("kabuki_noodle_row"), FXW.hub("afterlife")
    FXW.join(1, A, "Fixer Ana", near(REGINA))
    FXW.join(2, B, "Runner Ben", near(REGINA, -0.6))
    FXW.join(3, C, "Observer Cy", near(AFTER))
    FXW.setJob(1, "fixer", true)
    FXW.give(1, 5000)
    MH.command("contract", 1, { "post", "regina_noodle_drop", "500", "2" })
    MH.until_(function() return FXW.contract(1) ~= nil and FXW.contract(1).state == "open" end, 30)
    cmd(2, "take", "1")
    SFW.move(2, near(NOODLE, -0.4))
    MH.run(1)
    FXW.pickup(2, FXW.contract(1))
    -- Walk 20 m with it and set it down (G).
    SFW.move(2, { x = NOODLE.x - 20, y = NOODLE.y - 5, z = NOODLE.z })
    MH.run(1)
    local R = MH.resources.open77_actions
    R.env.source = 2
    MH.emit("open77:actions:putdown")
    R.env.source = nil
    MH.run(6)
    local dropped = FXW.decode(liveRow(FXW.contract(1).id).data).crate.position
    local c2 = npcPost("regina_psycho_kabuki", "regina", 2000)
    local npcBefore = FXW.npcOf(c2)
    local c3 = npcPost("afterlife_chips", "afterlife", 600)
    cmd(3, "take", tostring(c3.seq))
    local escrowBefore = FXW.balance("soc:fixer_escrow")
    local cashA0 = FXW.balance("cash:" .. A)

    -- The server restarts.
    local keep = FXW.keep()
    FXW.boot({ keep = keep, writers = FXW.WRITERS_STRICT })
    FXW.join(1, A, "Fixer Ana", near(REGINA))
    FXW.join(2, B, "Runner Ben", { x = NOODLE.x - 20, y = NOODLE.y - 5, z = NOODLE.z })
    FXW.join(3, C, "Observer Cy", near(AFTER))
    local s = svc()
    local d1, d2, d3 = FXW.contract(1), FXW.contract(2), FXW.contract(3)
    local loaded = (d1 and d1.state or "-") .. "," .. (d2 and d2.state or "-") .. "," .. (d3 and d3.state or "-")
    local item = FXW.crateOf(d1)
    local ok, carry = MH.callSync("fx_probe", "open77_actions", "carryGet", item)
    local npcAfter = FXW.npcOf(d2)
    local reminded = FXW.told(2, "Your contract #1")
    local escrowAfter = FXW.balance("soc:fixer_escrow")
    -- A new contract continues the numbering.
    local c4 = npcPost("wakako_components", "wakako", 600)
    -- Finish the delivery and the retrieval after the restart.
    SFW.move(2, { x = dropped.x, y = dropped.y + 0.5, z = dropped.z })
    MH.run(1)
    local cashB0 = FXW.balance("cash:" .. B)
    local pick = FXW.pickup(2, d1)
    SFW.move(2, near(REGINA, -0.4))
    MH.run(1)
    local drop = FXW.deliver(2, "regina")
    FXW.until_(d1, "completed", 40)
    FXW.giveItem(3, "chip", 3)
    MH.run(1)
    local cashC0 = FXW.balance("cash:" .. C)
    local hand = FXW.handover(3, "afterlife")
    FXW.until_(d3, "completed", 40)
    MH.run(1)
    return FXW.result({
        loaded = loaded,
        crate_back = ok and type(carry) == "table" and math.abs(carry.position.x - dropped.x) < 0.01
            and math.abs(carry.position.y - dropped.y) < 0.01,
        crate_moved = math.abs(dropped.x - NOODLE.x) > 5,
        psycho_back = npcAfter ~= nil, psycho_new_id = npcAfter ~= npcBefore, escrow_kept = escrowBefore == escrowAfter,
        reminded = reminded, c4_seq = c4.seq, pick = pick and pick.state, drop = drop and drop.state, d1 = d1.state,
        b_paid = FXW.balance("cash:" .. B) - cashB0, d1_net = d1.net, hand = hand and hand.state, d3 = d3.state,
        c_paid = FXW.balance("cash:" .. C) - cashC0, d3_net = d3.net, a_untouched = cashA0 == FXW.balance("cash:" .. A),
        escrow_agrees = FXW.escrowAgrees(), contracts_loaded = FXW.printed("loaded 3 live contracts"),
        unbalanced = tostring(SFW.unbalanced()), ready = tostring(s.ready),
    })
end

-- ---------------------------------------------------------------------------------------------
-- Refusals: who may post and take what, and forged hook calls.
-- ---------------------------------------------------------------------------------------------
function scenarios.refusals()
    FXW.boot()
    local REGINA = FXW.hub("regina")
    FXW.join(1, A, "Fixer Ana", near(REGINA))
    FXW.join(2, B, "Runner Ben", near(REGINA, -0.6))
    FXW.join(3, C, "Observer Cy", near(REGINA, 0, 0.6))
    -- Not a fixer, then off duty.
    cmd(2, "post", "regina_noodle_drop", "500")
    local noJob = FXW.told(2, "Only a fixer on duty posts contracts")
    FXW.setJob(1, "fixer", false)
    cmd(1, "post", "regina_noodle_drop", "500")
    local offDuty = FXW.told(1, "Clock in as a fixer first")
    SFW.sync("fx_probe", "rp_jobs", "setDuty", 1, true)
    -- Out of range, then more than the wallet holds (cash 500, bank 0): void, nothing moved.
    cmd(1, "post", "regina_noodle_drop", "5000")
    local outOfRange = FXW.told(1, "outside the range")
    local cash0 = FXW.balance("cash:" .. A)
    MH.command("contract", 1, { "post", "afterlife_box", "3000" })
    MH.run(5)
    local broke = FXW.told(1, "do not have the eddies")
    local voided = FXW.contract(1) and FXW.contract(1).state
    local cashAfter = FXW.balance("cash:" .. A)
    -- A real post, then the poster takes their own contract, a runner far away, a third contract.
    FXW.give(1, 20000)
    MH.command("contract", 1, { "post", "regina_noodle_drop", "500" })
    MH.until_(function() return FXW.contract(2) ~= nil and FXW.contract(2).state == "open" end, 30)
    cmd(1, "take", "2")
    local own = FXW.told(1, "You posted that one yourself")
    SFW.move(2, { x = REGINA.x + 50, y = REGINA.y, z = REGINA.z })
    MH.run(1)
    cmd(2, "take", "2")
    local far = FXW.told(2, "stand at a fixer point")
    SFW.move(2, near(REGINA, -0.6))
    MH.run(1)
    MH.command("contract", 1, { "post", "regina_chooh2", "500" })
    MH.command("contract", 1, { "post", "afterlife_chips", "500" })
    MH.until_(function() return FXW.contract(4) ~= nil and FXW.contract(4).state == "open" end, 30)
    cmd(2, "take", "2")
    cmd(2, "take", "3")
    cmd(2, "take", "4")
    local tooMany = FXW.told(2, "already hold as many contracts")
    local held = #svc():held(B)
    -- Poster limit (4 live).
    MH.command("contract", 1, { "post", "regina_noodle_drop", "500" })
    MH.run(5)
    MH.command("contract", 1, { "post", "regina_noodle_drop", "500" })
    MH.run(5)
    local posterLimit = FXW.told(1, "as many contracts posted")
    -- The hand-over at a fixer point where none of the runner's contracts is handed over (their
    -- retrieval goes to Regina's corner, they stand at the Afterlife).
    SFW.move(2, near(FXW.hub("afterlife"), -0.6))
    MH.run(1)
    local wrongHub = FXW.handover(2, "afterlife")
    local toldWrongHub = FXW.told(2, "None of your contracts are handed over here")
    -- Forged hook calls from another resource.
    local function forged(name, ctx)
        local okCall, a, b = MH.callSync("fx_probe", "rp_fixer", name, ctx)
        return tostring(a) .. ":" .. tostring(b)
    end
    local fakeCtx = { opId = "act-forged-1", playerId = 2, phase = "commit", target = { data = { hub = "regina" } },
        reservation = { contract = FXW.contract(2).id, txOpId = "x" }, carry = { data = { contract = FXW.contract(2).id } } }
    return FXW.result({
        no_job = noJob, off_duty = offDuty, out_of_range = outOfRange, broke = broke, voided = voided,
        cash_unchanged = cash0 == cashAfter, own = own, far = far, too_many = tooMany, held = held,
        poster_limit = posterLimit, wrong_hub = wrongHub and wrongHub.state or "refused",
        wrong_hub_refused = table.concat(SFW.refusals(2), ","), told_wrong_hub = toldWrongHub,
        forged_commit = forged("fxHandCommit", fakeCtx), forged_putdown = forged("fxCratePutdown", fakeCtx),
        forged_board = forged("fxBoard", fakeCtx), forged_validate = forged("fxHandValidate", fakeCtx),
        escrow_agrees = FXW.escrowAgrees(), unbalanced = tostring(SFW.unbalanced()),
    })
end

-- ---------------------------------------------------------------------------------------------
-- Crash windows: a payout while the ledger is down, rp_fixer restarted while paying, an escrow
-- whose "open" save was lost, a refused escrow; money moves exactly once, reputation too.
-- ---------------------------------------------------------------------------------------------
local function restartFixer()
    MH.stop("rp_fixer")
    MH.run(1)
    FXW.startFixer()
    MH.until_(function() return FXW.svc() and FXW.svc().ready end, 60)
    FXW.cfg().npcBoard.enabled = false
    MH.run(1)
end

function scenarios.crash()
    FXW.boot()
    local WAKAKO = FXW.hub("wakako")
    FXW.setRep(B, 3)
    FXW.join(2, B, "Runner Ben", near(WAKAKO, -0.6))
    -- 1. The payout meets a ledger outage, then goes through once.
    local c1 = npcPost("wakako_chooh2", "wakako", 1500)
    cmd(2, "take", tostring(c1.seq))
    local cashB0 = FXW.balance("cash:" .. B)
    MH.shared.txStore.down = true
    emitJob({ job = "chooh2", kind = "refine", playerId = 2, ref = "c:1", data = { canisters = 10 } })
    MH.run(8)
    local stuck = c1.state
    MH.shared.txStore.down = false
    FXW.until_(c1, "completed", 60)
    MH.run(1)
    local paid1 = FXW.balance("cash:" .. B) - cashB0

    -- 2. rp_fixer restarts while a payout is pending: it completes after the restart, once.
    local c2 = npcPost("wakako_chooh2", "wakako", 1500)
    cmd(2, "take", tostring(c2.seq))
    MH.shared.txStore.down = true
    emitJob({ job = "chooh2", kind = "refine", playerId = 2, ref = "c:2", data = { canisters = 10 } })
    MH.run(4)
    local before2 = c2.state
    local saved2 = liveRow(c2.id).state
    restartFixer()
    FXW.join(2, B, "Runner Ben", near(WAKAKO, -0.6))
    MH.shared.txStore.down = false
    local d2 = FXW.contract(c2.seq)
    FXW.until_(d2, "completed", 60)
    MH.run(1)
    local paid2 = FXW.balance("cash:" .. B) - cashB0 - paid1
    local rep2 = repOf(B)
    -- The same payout again (a duplicate retry) replays and moves nothing; the reputation key too.
    local spec = svc():payoutSpec(d2)
    local replay = MH.callAsync("rp_fixer", "rp_economy", "pay", spec)
    local dup = MH.resources.rp_fixer.env.FixerStore
    local dupResult
    MH.task("rp_fixer", function() dupResult = dup.applyRep(B, d2.id .. ":done", 2, 1, 0, 0, 0) end)
    MH.run(2)

    -- 3. The escrow committed but the "open" save was lost: the restart finds the escrow and
    --    opens the contract without charging again.
    local c3 = npcPost("wakako_components", "wakako", 600)
    local escrow3 = FXW.balance("soc:fixer_escrow")
    local row = FXW.decode(liveRow(c3.id).data)
    row.state = "posting"
    MH.shared.fxdb.contracts[c3.id].data = FXW.encode(row)
    MH.shared.fxdb.contracts[c3.id].state = "posting"
    restartFixer()
    local d3 = FXW.contract(c3.seq)
    local loadedAs = d3.state
    MH.now = MH.now + 40
    FXW.until_(d3, "open", 30)
    MH.run(1)

    -- 4. An escrow refused by a ledger outage: the contract is void, nothing moved.
    MH.shared.txStore.down = true
    MH.run(3)
    MH.command("fixer.post", 0, { "wakako_components", "wakako", "600" })
    MH.run(4)
    MH.shared.txStore.down = false
    MH.now = MH.now + 40
    MH.run(12)
    local c4 = FXW.contract(4)
    return FXW.result({
        stuck = stuck, c1 = c1.state, paid1 = paid1, net1 = c1.net,
        before2 = before2, saved2 = saved2, d2 = d2.state, paid2 = paid2, net2 = d2.net, rep2 = rep2,
        replay = replay and tostring(replay.replay), replay_moved = FXW.balance("cash:" .. B) - cashB0 - paid1 - paid2,
        dup = dupResult, rep_after_dup = repOf(B),
        loaded_as = loadedAs, d3 = d3.state, escrow3_same = escrow3 == FXW.balance("soc:fixer_escrow"),
        c4 = c4 and c4.state, c4_reason = c4 and c4.reason,
        escrow_agrees = FXW.escrowAgrees(), unbalanced = tostring(SFW.unbalanced()),
    })
end

-- ---------------------------------------------------------------------------------------------
-- The NPC fixers stock their boards; players who could take a contract are told.
-- ---------------------------------------------------------------------------------------------
function scenarios.npc_board()
    -- rp_ripperdoc is not running: its Gorilla Arms box is not an item here.
    local items = {}
    for id, def in pairs(FXW.ITEMS) do if id ~= "implant_box_arms" then items[id] = def end end
    FXW.boot({ npcBoard = true, items = items })
    -- Three offers and room for three: the box is always tried, the two others are posted.
    FXW.cfg().hubs.afterlife.offers = { "afterlife_box", "afterlife_chips", "afterlife_meds_run" }
    FXW.cfg().hubs.afterlife.keepOpen = 3
    FXW.join(2, B, "Runner Ben", near(FXW.hub("regina"), -0.6))
    MH.run(40)
    local boxPosted = false
    for _, c in pairs(svc().contracts) do if c.template == "afterlife_box" then boxPosted = true end end
    local perHub, minted = {}, -SFW.journal("^sys:rp_fixer:board$", "money")
    local total = 0
    for _, c in pairs(svc().contracts) do
        perHub[c.hub] = (perHub[c.hub] or 0) + 1
        total = total + 1
    end
    local contacts = 0
    for _, n in pairs(MH.shared.world.npcs) do
        if n.template == "civilian_female_relaxed_01" then contacts = contacts + 1 end
    end
    return FXW.result({
        afterlife = perHub.afterlife or 0, wakako = perHub.wakako or 0, regina = perHub.regina or 0, total = total,
        minted_is_escrow = minted == FXW.balance("soc:fixer_escrow"), escrow_agrees = FXW.escrowAgrees(),
        contacts = contacts, told = FXW.told(2, "New contract at"), unbalanced = tostring(SFW.unbalanced()),
        box_posted = boxPosted, box_skipped = FXW.printed("Rogue skips afterlife_box: its item is not defined"),
    })
end

-- ---------------------------------------------------------------------------------------------
-- Edges: walking away during the take dialog, a disconnect while carrying, an open77_actions
-- restart, a poster cancelling a contract that was taken in the meantime.
-- ---------------------------------------------------------------------------------------------
function scenarios.edges()
    FXW.boot()
    local REGINA, NOODLE = FXW.hub("regina"), FXW.point("kabuki_noodle_row")
    FXW.join(1, A, "Fixer Ana", near(REGINA))
    FXW.join(2, B, "Runner Ben", near(REGINA, -0.6))
    FXW.setJob(1, "fixer", true)
    FXW.give(1, 5000)
    MH.command("contract", 1, { "post", "regina_noodle_drop", "500", "2" })
    MH.until_(function() return FXW.contract(1) ~= nil and FXW.contract(1).state == "open" end, 30)
    local c = FXW.contract(1)
    -- The runner reads the contract, walks off, then presses "Take": refused, too far.
    FXW.script(2, {
        { kind = "context", value = { id = "c:" .. c.id } },
        { kind = "alert", fn = function()
            SFW.move(2, { x = REGINA.x + 30, y = REGINA.y, z = REGINA.z })
            return { ok = true, outcome = "ok", value = "confirm" }
        end },
    })
    FXW.board(2, "regina")
    MH.run(2)
    local walkedAway = c.state
    local toldFar = FXW.told(2, "stand at a fixer point")
    SFW.move(2, near(REGINA, -0.6))
    MH.run(1)
    takeThroughBoard(2, "regina", c)
    FXW.until_(c, "taken", 20)
    -- The poster tries to cancel it now: refused, a runner is on it.
    cmd(1, "cancel", "1")
    local cancelTaken = FXW.told(1, "A runner is on it")
    -- The runner lifts the crate, walks 15 m and disconnects: the crate drops where they stood.
    SFW.move(2, near(NOODLE, -0.4))
    MH.run(1)
    FXW.pickup(2, c)
    local spot = { x = NOODLE.x - 15, y = NOODLE.y, z = NOODLE.z }
    SFW.move(2, spot)
    MH.run(2)
    MH.disconnect(2)
    MH.run(4)
    local savedAt = FXW.decode(liveRow(c.id).data).crate
    local stillTaken = c.state
    -- They come back: reminded, the map pin shows the crate, they deliver it.
    FXW.join(2, B, "Runner Ben", spot)
    local reminded = FXW.told(2, "Your contract #1")
    local pins = 0
    for _, e in ipairs(MH.shared.world.client) do
        if e.resource == "rp_fixer" and e.name == "rp_fixer:objectives" and e.pid == 2 and type(e.args[1]) == "table" then
            pins = #e.args[1]
        end
    end
    -- open77_actions restarts under them: the board, the drop and the crate come back.
    local crateBefore = FXW.crateOf(c)
    MH.stop("open77_actions")
    MH.run(1)
    SFW.startActions()
    MH.run(3)
    local crateAfter = FXW.crateOf(c)
    local ok, item = MH.callSync("fx_probe", "open77_actions", "carryGet", crateAfter)
    local pick = FXW.pickup(2, c)
    SFW.move(2, near(REGINA, -0.4))
    MH.run(1)
    local cashB0 = FXW.balance("cash:" .. B)
    local drop = FXW.deliver(2, "regina")
    FXW.until_(c, "completed", 40)
    MH.run(1)
    FXW.script(1, { { kind = "context", cancel = true } })
    local board = FXW.board(1, "regina")
    -- A template whose own duration is not in the offered list (6 h) is posted with it.
    postThroughBoard(1, "regina", "afterlife_implant", 1500, 6)
    MH.until_(function() return FXW.contract(2) ~= nil and FXW.contract(2).state == "open" end, 30)
    local c2 = FXW.contract(2)
    local hoursOffered = {}
    for i = #MH.shared.ui, 1, -1 do
        local e = MH.shared.ui[i]
        if e.kind == "input" and e.pid == 1 then
            for _, f in ipairs(e.def.fields) do
                if f.id == "hours" then
                    for _, o in ipairs(f.options) do hoursOffered[#hoursOffered + 1] = o.value end
                    hoursOffered.default = f.default
                end
            end
            break
        end
    end
    return FXW.result({
        c2 = c2 and c2.state, c2_hours = c2 and math.floor((c2.expiresAt - c2.postedAt) / 3600 + 0.5),
        hours_offered = table.concat(hoursOffered, ","), hours_default = hoursOffered.default,
        walked_away = walkedAway, told_far = toldFar, cancel_taken = cancelTaken, still_taken = stillTaken,
        saved_x = math.floor(savedAt.position.x + 0.5) == math.floor(spot.x + 0.5) or (savedAt.position.x .. "~" .. spot.x),
        saved_carried = tostring(savedAt.carried), reminded = reminded, pins = pins,
        crate_new = crateAfter ~= nil and crateAfter ~= crateBefore,
        crate_at = ok and type(item) == "table" and math.abs(item.position.x - savedAt.position.x) < 0.01,
        pick = pick and pick.state, drop = drop and drop.state, state = c.state,
        paid = FXW.balance("cash:" .. B) - cashB0, board_after_restart = board and board.state,
        escrow_agrees = FXW.escrowAgrees(), unbalanced = tostring(SFW.unbalanced()),
        ui_mismatch = MH.shared.uiMismatch or "none",
    })
end

-- Without the UI kit (a refused or failed dialog), the board answers in chat.
function scenarios.no_uikit()
    FXW.boot({ noUikit = true })
    local REGINA = FXW.hub("regina")
    FXW.join(2, B, "Runner Ben", near(REGINA, -0.6))
    local c = npcPost("regina_noodle_drop", "regina", 500)
    local board = FXW.board(2, "regina")
    MH.run(2)
    MH.command("contracts", 2, {})
    MH.run(2)
    SFW.move(2, { x = REGINA.x + 200, y = REGINA.y, z = REGINA.z })
    MH.run(1)
    MH.command("contracts", 2, {})
    MH.run(2)
    return FXW.result({
        board = board and board.state, listed = FXW.told(2, "#1 Noodle Row pickup at Regina's corner: pays 425 eddies"),
        hint = FXW.told(2, "/contract take <number>"), nearest = FXW.told(2, "Nearest fixer: Regina's corner"),
        state = c.state, unbalanced = tostring(SFW.unbalanced()),
    })
end

-- ---------------------------------------------------------------------------------------------
-- The pure rules (server/model.lua) and the shipped data (server/config.lua), without a world.
-- ---------------------------------------------------------------------------------------------
function scenarios.model()
    local env = setmetatable({}, { __index = _G })
    for _, file in ipairs({ "server/config.lua", "server/model.lua" }) do
        assert(loadfile(ROOT_DIR .. "/rp_fixer/" .. file, "t", env))()
    end
    local Cf, Mo = env.FixerConfig, env.FixerModel
    local bad = {}
    for id, t in pairs(Cf.templates) do
        local problem = Mo.checkTemplate(id, t, Cf)
        if problem then bad[#bad + 1] = id .. ":" .. problem end
    end
    local offers = {}
    for _, key in ipairs(Cf.hubOrder) do
        for _, id in ipairs(Cf.hubs[key].offers or {}) do
            local t = Cf.templates[id]
            if not t or not t.posters.npc then offers[#offers + 1] = key .. ":" .. id end
        end
    end
    local unmarked = {}
    local function mark(kind, list)
        for key, p in pairs(list) do
            if p.measured ~= false and p.measured ~= true then unmarked[#unmarked + 1] = kind .. ":" .. key end
        end
    end
    mark("hub", Cf.hubs); mark("point", Cf.points); mark("sighting", Cf.sightings); mark("drop", Cf.drops)
    local nonAscii = {}
    for id, t in pairs(Cf.templates) do
        for _, field in ipairs({ "title", "brief" }) do
            if t[field]:find("[^\32-\126]") then nonAscii[#nonAscii + 1] = id .. "." .. field end
        end
    end
    local inPlayerOrder = 0
    for _, id in ipairs(Cf.templateOrder) do if Cf.templates[id] and Cf.templates[id].posters.player then inPlayerOrder = inPlayerOrder + 1 end end
    local playerTemplates = 0
    for _, t in pairs(Cf.templates) do if t.posters.player then playerTemplates = playerTemplates + 1 end end
    -- Rules
    local net, cut = Mo.split(600, 0.15)
    local net2, cut2 = Mo.split(1, 0.15)
    local tpl = { reward = { min = 400, max = 600 } }
    local job = { kind = "job", state = "taken", order = { job = "chooh2", kinds = { "refine" }, count = 10,
        countField = "count", match = { plant = "north" }, refs = { "seen" } } }
    local function inc(ev) local n, why = Mo.jobIncrement(job, ev) return tostring(n or why) end
    local sum = 0
    for i = 0, 99 do
        local r = Mo.npcReward(tpl, i / 100, 50)
        if r < 400 or r > 600 or r % 50 ~= 0 then sum = -1000000 end
        sum = sum + 1
    end
    local c = { state = "open", expiresAt = 100, minRep = 3, mode = "claimed", poster = { subject = "p" } }
    local cfgLimits = { maxPerRunner = 2 }
    return FXW.result({
        bad_templates = #bad == 0 and "none" or table.concat(bad, ","), bad_offers = #offers == 0 and "none" or table.concat(offers, ","),
        unmarked = #unmarked == 0 and "none" or table.concat(unmarked, ","), non_ascii = #nonAscii == 0 and "none" or table.concat(nonAscii, ","),
        player_order_complete = inPlayerOrder == playerTemplates,
        -- a saved bounty naming a sighting the config no longer has falls back to its template's
        sighting_renamed = select(2, Mo.sighting({ template = "regina_psycho_kabuki", target = { sighting = "gone" } }, Cf)),
        sighting_lost = tostring(Mo.sighting({ template = "nope", target = { sighting = "gone" } }, Cf)),
        split = net .. "/" .. cut, split_small = net2 .. "/" .. cut2,
        reward_snap = tostring(Mo.chooseReward(tpl, 512, 50)), reward_low = select(2, Mo.chooseReward(tpl, 100, 50)),
        reward_nan = select(2, Mo.chooseReward(tpl, "abc", 50)), npc_rewards_ok = sum == 100,
        tier0 = select(2, Mo.tierOf(0, Cf.tiers)).name, tier8 = select(2, Mo.tierOf(8, Cf.tiers)).name,
        tier25 = select(2, Mo.tierOf(25, Cf.tiers)).name, floor = Mo.applyDelta(0, -1, 0),
        inc_ok = inc({ job = "chooh2", kind = "refine", ref = "r", data = { count = 3, plant = "north" } }),
        inc_default = inc({ job = "chooh2", kind = "refine", ref = "r2", data = { plant = "north" } }),
        inc_nomatch = inc({ job = "chooh2", kind = "refine", ref = "r3", data = { plant = "south" } }),
        inc_dup = inc({ job = "chooh2", kind = "refine", ref = "seen", data = { plant = "north" } }),
        inc_kind = inc({ job = "chooh2", kind = "sell", ref = "r4", data = {} }),
        inc_job = inc({ job = "netrunner", kind = "refine", ref = "r5", data = {} }),
        inc_huge = inc({ job = "chooh2", kind = "refine", ref = "r6", data = { count = 5000, plant = "north" } }),
        norm_bad = select(2, Mo.normalizeJobEvent({ job = "x", kind = "y", playerId = 0, ref = "z" })),
        norm_ref = select(2, Mo.normalizeJobEvent({ job = "x", kind = "y", playerId = 1 })),
        take_ok = tostring(Mo.takeRefusal(c, { subject = "r", score = 3, held = 0 }, cfgLimits, 50)),
        take_rep = tostring(Mo.takeRefusal(c, { subject = "r", score = 2, held = 0 }, cfgLimits, 50)),
        take_own = tostring(Mo.takeRefusal(c, { subject = "p", score = 9, held = 0 }, cfgLimits, 50)),
        take_late = tostring(Mo.takeRefusal(c, { subject = "r", score = 9, held = 0 }, cfgLimits, 100)),
        take_many = tostring(Mo.takeRefusal(c, { subject = "r", score = 9, held = 2 }, cfgLimits, 50)),
        ascii = Mo.ascii("Caf\195\169  \"ok\"\n\tdone", 20), money = Mo.money(1234567),
        duration = Mo.duration(3725) .. "|" .. Mo.duration(125) .. "|" .. Mo.duration(9),
        pay_op = Mo.payOpId({ state = "paying", ops = { pay = "fixer.pay:x", refund = "fixer.ref:x", attempt = 3 } }),
        refund_op = Mo.payOpId({ state = "refunding", ops = { pay = "fixer.pay:x", refund = "fixer.ref:x", attempt = 1 } }),
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
