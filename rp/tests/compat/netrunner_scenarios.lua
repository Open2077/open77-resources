-- tests/compat/netrunner_scenarios.lua: the netrunner contract job (rp_netrunner) end to end, offline.
--
-- Loaded by tests/test_netrunner.py after fakehost.lua (unused here) with the string globals ROOT_DIR,
-- COMPAT_DIR, SYS_DIR and TX_DIR (netrunner_world.lua). Players act the way the open77_actions client,
-- the UI kit and the platform's interaction UI make them act: prompt intents from their own seat, chat
-- commands, dialog answers, the invitation answer. Every check reads durable truth from the
-- coordinator's store.

dofile(COMPAT_DIR .. "/netrunner_world.lua")

local scenarios = {}

local A, B, C, D = "acct-a", "acct-b", "acct-c", "acct-d"
local BOARD = "stash:nr.board:contracts"
-- rp_netrunner/server/config.lua (catalogue anchors).
local DROP = { x = -1419.9, y = 989.4, z = 16.6 }                    -- the Afterlife's fixer drop
local JUNCTION = { x = -1434.631, y = 989.401, z = 23.260 }          -- watson_junction (tier 1, laptop)
local NEAR_JUNCTION = { x = -1433.0, y = 988.5, z = 23.260 }         -- 1.9 m from it
local LOBBY = { x = -1450.216, y = -1038.966, z = 9.281 }            -- corp_lobby (tier 2, desk)
local FAR = { x = -1400.0, y = 1100.0, z = 16.6 }

local function svc() return NRW.svc() end

local function setupRunner(pid, grade)
    NRW.command("netrun.setup", { tostring(pid), "netrunner", tostring(grade or 0) })
    MH.run(1)
end

local function setupFixer(pid)
    NRW.command("netrun.setup", { tostring(pid), "fixer", "0" })
    MH.run(1)
end

local function give(pid, item, n)
    NRW.command("netrun.give", { tostring(pid), item, tostring(n or 1) })
    MH.run(3)
end

-- Posted through the export, as another resource (the fixer board) would.
local function post(spec)
    local r = table.pack(MH.callAsync("nr_probe", "rp_netrunner", "post", spec))
    MH.run(1)
    return r[1], r[2]
end

-- Every breach succeeds (true) or fails (false).
local function force(success)
    local cfg = NRW.cfg()
    for _, t in pairs(cfg.tiers) do t.baseChance = success and 100 or 0 end
    cfg.difficulty.minChance = success and 100 or 0
    cfg.difficulty.maxChance = success and 100 or 0
end

local function take(pid, code)
    MH.command("netrun", pid, { "take", code })
    MH.until_(function() return svc().activeOf[MH.players[pid].identifier] ~= nil end, 10)
    MH.run(1)
end

local function breach(pid, site, seconds)
    return NRW.act(pid, "breach_" .. site, "site_" .. site, seconds or 60)
end

-- The fixer drop's E: the delivery (when a shard is due there) or the board.
local function talkThenDeliver(pid, seconds)
    local mark = NRW.mark()
    NRW.intent(pid, "rp_netrunner:talk", "rp_netrunner:fixer_afterlife")
    return NRW.finish(pid, "deliver", seconds or 40, mark)
end

local function opOf(pid, actionId, mark)
    for i = (mark or 0) + 1, #MH.shared.transitions do
        local op = MH.shared.transitions[i]
        if op.playerId == pid and op.actionId == actionId then return op.opId end
    end
    return nil
end

-- Conservation: every shard minted is in a pocket or burned; every contract minted is on the board
-- or retired; chips burned = completed breaches.
local function conserved()
    local problems = {}
    local store = NRW.store()
    local minted, live, burned = 0, 0, 0
    for iid, inst in pairs(store.instances) do
        if iid:match("^nrs%.") then
            minted = minted + 1
            if inst.container:match("^char:") then live = live + 1
            elseif inst.container == "sys:netrunner" or inst.container:match("^sys:") then burned = burned + 1
            else problems[#problems + 1] = "shard " .. iid .. " in " .. inst.container end
        end
    end
    if minted ~= live + burned then problems[#problems + 1] = "shards do not add up" end
    local breaches = 0
    for _, row in pairs(store.ops) do
        if row.state == "committed" and row.kind == "netrunner.breach" then breaches = breaches + 1 end
    end
    local chipsBurned = NRW.journal("^sys:netrunner$", "chip")
    if chipsBurned ~= breaches then problems[#problems + 1] = ("chips burned %d ~= breaches %d"):format(chipsBurned, breaches) end
    return #problems == 0, table.concat(problems, "; ")
end

-- ---------------------------------------------------------------------------------------------
-- Happy path: an NPC contract posted by another resource, read on the board at the fixer drop and
-- taken through the UI kit; a timed breach at the junction box (the observer sees the netrunner
-- sitting with the laptop), one chip burned, the contract patched and the shard minted in ONE
-- operation; the shard delivered at the drop: ONE rp_economy sale (shard burned, the client's money
-- to the runner, the fixer's cut to the fixer society); events for the fixer board. Strict writers.
-- ---------------------------------------------------------------------------------------------
function scenarios.happy_path()
    NRW.boot({ writers = NRW.WRITERS_STRICT })
    NRW.join(1, A, "Runner", DROP)
    NRW.join(3, C, "Observer", NEAR_JUNCTION)
    setupRunner(1, 2)
    give(1, "chip", 2)
    force(true)
    local s, why = post({ site = "watson_junction", reward = 500, minutes = 30, name = "Rogue" })
    local posted = s ~= nil and NRW.boardContract(s.id) ~= nil
    -- E at the drop: the board (context), the contract, the confirmation.
    NRW.answer(1, { { kind = "context", value = { id = "c:" .. (s and s.id or "?") } }, { kind = "alert", value = "confirm" } })
    local talk = NRW.act(1, "talk", "fixer_afterlife", 20)
    MH.until_(function() return svc().activeOf[A] ~= nil end, 20)
    MH.run(1)
    local boardShown = MH.shared.nr.shown[1] and MH.shared.nr.shown[1].kind == "context"
    local takenMeta = s and NRW.boardContract(s.id)
    -- The breach at the junction box.
    NRW.move(1, JUNCTION)
    local chips0 = NRW.count("char:" .. A, "chip")
    local b = breach(1, "watson_junction")
    local chips1 = NRW.count("char:" .. A, "chip")
    local shard = s and ("nrs." .. s.id)
    local shardAt = shard and NRW.whereIs(shard)
    local breachedMeta = s and NRW.boardContract(s.id)
    local laptop = NRW.played(1, "laptop", "playAt")
    -- Back to the drop: E delivers.
    NRW.move(1, DROP)
    local cash0, soc0 = NRW.balance("cash:" .. A), NRW.balance("soc:fixer")
    local d = talkThenDeliver(1)
    MH.run(2)
    local cash1, soc1 = NRW.balance("cash:" .. A), NRW.balance("soc:fixer")
    local deliverEvents = NRW.jobEvents("deliver")
    local successEvents = NRW.jobEvents("breach_success")
    local ok, detail = conserved()
    return NRW.result({
        posted = posted, post_why = tostring(why), code_len = s and #s.code or 0, cut = s and s.cut, net = s and s.net,
        talk = talk and talk.state, board_shown = boardShown,
        taken_state = takenMeta and takenMeta.state, taken_by = takenMeta and takenMeta.taker,
        breach = b and b.state, chips_used = chips0 - chips1,
        shard_at = tostring(shardAt), breached_state = breachedMeta and breachedMeta.state,
        breached_shard = breachedMeta and breachedMeta.shard == shard,
        observer_sees = laptop ~= nil and math.abs(laptop.position.x - JUNCTION.x) < 1e-6 and math.abs(laptop.yaw - (-56.0)) < 1e-6,
        deliver = d and d.state, paid = cash1 - cash0, society = soc1 - soc0,
        shard_after = tostring(shard and NRW.whereIs(shard)), board_after = NRW.boardCount(),
        active_after = tostring(svc().activeOf[A]),
        success_events = #successEvents, deliver_events = #deliverEvents,
        deliver_ref = deliverEvents[1] and tostring(deliverEvents[1].ref):match("^nr%.deliver:") ~= nil,
        deliver_job = deliverEvents[1] and deliverEvents[1].job, deliver_net = deliverEvents[1] and deliverEvents[1].data.net,
        success_ref = successEvents[1] and tostring(successEvents[1].ref):match("^nr%.breach:") ~= nil,
        phases = (function()
            local out = {}
            for _, e in ipairs(MH.shared.contractEvents) do out[#out + 1] = e.phase end
            return table.concat(out, ",")
        end)(),
        told_breach = NRW.told(1, "Breach complete"), told_paid = NRW.told(1, "Shard delivered"),
        grants = MH.shared.nr.grants,
        conserved = ok, conservation = detail, unbalanced = tostring(NRW.unbalanced()),
    })
end

-- ---------------------------------------------------------------------------------------------
-- A failed breach is a trace: the chip is burned, no shard, the contract counts the attempt and
-- stays with the runner (mode "retry"); NCPD gets a dispatch at the site and a record entry, the
-- runner gets the native heat (cooled after wantedMs), rp_netrunner:traced and breach_failed fire.
-- The site's ICE is alert for a minute (a retry is refused before anything is held); after the
-- third failure the contract fails and leaves the board.
-- ---------------------------------------------------------------------------------------------
function scenarios.failure_trace()
    NRW.boot()
    NRW.join(1, A, "Runner", JUNCTION)
    setupRunner(1, 0)
    give(1, "chip", 4)
    force(false)
    local s = post({ site = "watson_junction", reward = 500, minutes = 60 })
    take(1, s.code)
    local cash0 = NRW.balance("cash:" .. A)
    local b1 = breach(1, "watson_junction")
    local meta1 = NRW.boardContract(s.id)
    local chips1 = NRW.count("char:" .. A, "chip")
    local alert = MH.shared.nr.alerts[1]
    local record = MH.shared.nr.records[1]
    local wanted1 = MH.shared.nr.wanted[1]
    local traced = MH.shared.traced[1]
    local failed = NRW.jobEvents("breach_failed")
    -- An immediate retry: the ICE is alert, refused before anything is held.
    local mark = NRW.mark()
    NRW.intent(1, "rp_netrunner:breach_watson_junction", "rp_netrunner:site_watson_junction")
    MH.run(2)
    local retryOp = opOf(1, "breach_watson_junction", mark)
    local alertRefused = false
    for _, r in ipairs(NRW.refusals(1)) do if r == "site_alert" then alertRefused = true end end
    local chipsAfterRefusal = NRW.count("char:" .. A, "chip")
    -- The heat this resource raised comes back down after wantedMs (120 s).
    MH.run(125)
    local wantedCooled = MH.shared.nr.wanted[1]
    local b2 = breach(1, "watson_junction")
    local meta2 = NRW.boardContract(s.id)
    MH.run(61)
    local b3 = breach(1, "watson_junction")
    MH.run(2)
    local ok, detail = conserved()
    return NRW.result({
        b1 = b1 and b1.state, chips_left = chips1, shard = tostring(NRW.whereIs("nrs." .. s.id)),
        state1 = meta1 and meta1.state, attempts1 = meta1 and meta1.attempts, traces1 = meta1 and meta1.traces,
        taker1 = meta1 and meta1.taker,
        alert_kind = alert and alert.kind, alert_text = alert and alert.text,
        alert_at_site = alert ~= nil and math.abs(alert.position.x - JUNCTION.x) < 1e-6,
        alert_anonymous = alert ~= nil and alert.by == 0,
        record_kind = record and record.kind, record_pid = record and record.pid,
        wanted1 = wanted1, wanted_cooled = wantedCooled,
        traced_site = traced and traced.site, traced_level = traced and traced.wantedLevel,
        failed_events = #failed, failed_success = failed[1] and tostring(failed[1].data.success),
        failed_traced = failed[1] and tostring(failed[1].data.traced), failed_kind = failed[1] and failed[1].kind,
        retry_op = tostring(retryOp), alert_refused = alertRefused, chips_after_refusal = chipsAfterRefusal,
        b2 = b2 and b2.state, attempts2 = meta2 and meta2.attempts,
        b3 = b3 and b3.state, contract_gone = NRW.boardContract(s.id) == nil,
        contract_where = tostring(NRW.whereIs("nrc." .. s.id)), active_after = tostring(svc().activeOf[A]),
        failed_phase = #NRW.contractEvents("failed"), attempt_phases = #NRW.contractEvents("attempt_failed"),
        cash_same = NRW.balance("cash:" .. A) == cash0, chips_end = NRW.count("char:" .. A, "chip"),
        told_traced = NRW.told(1, "TRACE"), told_failed = NRW.told(1, "Breach failed"),
        conserved = ok, conservation = detail, unbalanced = tostring(NRW.unbalanced()),
    })
end

-- ---------------------------------------------------------------------------------------------
-- failure.mode = "reopen": a failed breach puts the contract back on the board; another runner takes it.
-- ---------------------------------------------------------------------------------------------
function scenarios.failure_reopen()
    NRW.boot({ config = function(cfg) cfg.failure.mode = "reopen" end })
    NRW.join(1, A, "Runner", JUNCTION)
    NRW.join(4, D, "Runner two", NEAR_JUNCTION)
    setupRunner(1)
    setupRunner(4)
    give(1, "chip", 1)
    force(false)
    local s = post({ site = "watson_junction" })
    take(1, s.code)
    local b = breach(1, "watson_junction")
    local meta = NRW.boardContract(s.id)
    local heldByA = svc().activeOf[A]
    take(4, s.code)
    local meta2 = NRW.boardContract(s.id)
    return NRW.result({
        b = b and b.state, state = meta and meta.state, taker = tostring(meta and meta.taker),
        attempts = meta and meta.attempts, traces = meta and meta.traces, a_holds = tostring(heldByA),
        d_took = meta2 and meta2.taker, d_state = meta2 and meta2.state,
        unbalanced = tostring(NRW.unbalanced()),
    })
end

-- ---------------------------------------------------------------------------------------------
-- Cancellations: X mid-breach, walking off, a disconnect (the contract survives the reconnect), a
-- clock-off: nothing is used each time. Then one breach completes (one chip in all); X during the
-- hand-in keeps the shard; the next one pays once.
-- ---------------------------------------------------------------------------------------------
local function startBreach(pid, site)
    local mark = NRW.mark()
    NRW.intent(pid, "rp_netrunner:breach_" .. site, "rp_netrunner:site_" .. site)
    NRW.waitState(pid, "breach_" .. site, mark, "presenting", 15)
    return mark, opOf(pid, "breach_" .. site, mark)
end

function scenarios.cancellations()
    NRW.boot()
    NRW.join(1, A, "Runner", JUNCTION)
    setupRunner(1)
    give(1, "chip", 3)
    force(true)
    local s = post({ site = "watson_junction", reward = 600 })
    take(1, s.code)
    local chips0 = NRW.count("char:" .. A, "chip")
    -- 1. X
    local mark, op = startBreach(1, "watson_junction")
    MH.run(2)
    NRW.clientCancel(1, op)
    local x = NRW.finish(1, "breach_watson_junction", 20, mark)
    local afterX = { chips = NRW.count("char:" .. A, "chip"), meta = NRW.boardContract(s.id),
        told = NRW.told(1, "Breach aborted") }
    -- 2. walking off
    mark = startBreach(1, "watson_junction")
    MH.run(2)
    NRW.move(1, FAR)
    local walked = NRW.finish(1, "breach_watson_junction", 20, mark)
    NRW.move(1, JUNCTION)
    MH.run(1)
    -- 3. a disconnect mid-breach; the contract is the subject's, it survives the reconnect
    mark = startBreach(1, "watson_junction")
    MH.run(2)
    MH.disconnect(1)
    local gone = NRW.finish(1, "breach_watson_junction", 20, mark)
    NRW.join(1, A, "Runner", JUNCTION)
    setupRunner(1)
    local holdsAfterReconnect = svc().activeOf[A] == s.id
    -- 4. clocking off mid-breach
    mark = startBreach(1, "watson_junction")
    MH.run(2)
    MH.callSync("nr_probe", "rp_jobs", "setDuty", 1, false)
    local clocked = NRW.finish(1, "breach_watson_junction", 20, mark)
    local chipsBefore = NRW.count("char:" .. A, "chip")
    local attemptsBefore = NRW.boardContract(s.id).attempts
    -- 5. a full breach: one chip in all
    setupRunner(1)
    local b = breach(1, "watson_junction")
    local chipsUsed = chips0 - NRW.count("char:" .. A, "chip")
    -- 6. X during the hand-in keeps the shard
    NRW.move(1, DROP)
    local cash0 = NRW.balance("cash:" .. A)
    local m2 = NRW.mark()
    NRW.intent(1, "rp_netrunner:talk", "rp_netrunner:fixer_afterlife")
    NRW.waitState(1, "deliver", m2, "presenting", 15)
    NRW.clientCancel(1, opOf(1, "deliver", m2))
    local dx = NRW.finish(1, "deliver", 20, m2)
    local keptShard = NRW.whereIs("nrs." .. s.id)
    local cashAfterX = NRW.balance("cash:" .. A)
    local d = talkThenDeliver(1)
    MH.run(2)
    local ok, detail = conserved()
    return NRW.result({
        x = x and x.state, x_reason = x and x.reason, x_chips = afterX.chips, x_state = afterX.meta and afterX.meta.state,
        x_attempts = afterX.meta and afterX.meta.attempts, x_told = afterX.told,
        walked = walked and walked.state, walked_reason = walked and walked.reason,
        gone = gone and gone.state, gone_reason = gone and gone.reason, holds_after_reconnect = holdsAfterReconnect,
        clocked = clocked and clocked.state, clocked_reason = clocked and clocked.reason,
        chips_before_full = chipsBefore, attempts_before_full = attemptsBefore,
        b = b and b.state, chips_used = chipsUsed,
        dx = dx and dx.state, dx_reason = dx and dx.reason, kept_shard = tostring(keptShard),
        cash_after_x_same = cashAfterX == cash0, d = d and d.state, paid = NRW.balance("cash:" .. A) - cash0,
        no_trace = #MH.shared.nr.alerts == 0, deliver_events = #NRW.jobEvents("deliver"),
        conserved = ok, conservation = detail, unbalanced = tostring(NRW.unbalanced()),
    })
end

-- ---------------------------------------------------------------------------------------------
-- Refusals reach the player and hold nothing: no contract, a citizen taking, a taken contract, a
-- second contract, two takes in the same tick (one winner), no breach kit, the wrong terminal, a
-- delivery before the breach, forged hook calls, and the export's posting rules.
-- ---------------------------------------------------------------------------------------------
local function has(list, value)
    for _, v in ipairs(list) do if v == value then return true end end
    return false
end

function scenarios.refusals()
    NRW.boot()
    NRW.join(1, A, "Runner", JUNCTION)
    NRW.join(3, C, "Citizen", NEAR_JUNCTION)        -- not on the stand point: the runner is placed there
    NRW.join(4, D, "Runner two", NEAR_JUNCTION)
    NRW.join(5, "acct-e", "Runner three", NEAR_JUNCTION)
    setupRunner(1)
    setupRunner(4)
    setupRunner(5)
    force(true)
    -- no contract
    NRW.intent(1, "rp_netrunner:breach_watson_junction", "rp_netrunner:site_watson_junction")
    MH.run(1)
    local noContract = has(NRW.refusals(1), "no_contract")
    local s = post({ site = "watson_junction" })
    local s2 = post({ site = "corp_lobby" })
    -- a citizen cannot take
    MH.command("netrun", 3, { "take", s.code })
    MH.run(2)
    local citizen = NRW.told(3, "You are no netrunner")
    -- runner 1 takes s; runner 4 cannot; runner 1 cannot take a second one
    take(1, s.code)
    MH.command("netrun", 4, { "take", s.code })
    MH.run(2)
    local taken = NRW.told(4, "Someone already took")
    MH.command("netrun", 1, { "take", s2.code })
    MH.run(2)
    local second = NRW.told(1, "You already hold a contract")
    -- two takes in the same tick: one winner
    MH.command("netrun", 4, { "take", s2.code })
    MH.command("netrun", 5, { "take", s2.code })
    MH.run(3)
    local meta2 = NRW.boardContract(s2.id)
    local winners = (svc().activeOf[D] == s2.id and 1 or 0) + (svc().activeOf["acct-e"] == s2.id and 1 or 0)
    -- no breach kit: refused at reserve, nothing held, no attempt
    local mark = NRW.mark()
    NRW.intent(1, "rp_netrunner:breach_watson_junction", "rp_netrunner:site_watson_junction")
    local noKit = NRW.finish(1, "breach_watson_junction", 20, mark)
    local metaNoKit = NRW.boardContract(s.id)
    local toldKit = NRW.told(1, "data chip")
    -- the wrong terminal
    NRW.move(1, LOBBY)
    MH.run(1)
    NRW.intent(1, "rp_netrunner:breach_corp_lobby", "rp_netrunner:site_corp_lobby")
    MH.run(1)
    local wrongSite = has(NRW.refusals(1), "no_contract_here")
    -- a delivery before the breach (after the refusal toast cooldown)
    NRW.move(1, DROP)
    MH.run(2)
    MH.command("netrun", 1, { "deliver" })
    MH.run(2)
    local early = NRW.told(1, "Breach the target first")
    -- forged hook calls (any resource can call an export)
    local okV, vAllowed, vWhy = MH.callSync("nr_probe", "rp_netrunner", "nrValidate", { actionId = "breach_watson_junction",
        playerId = 1, phase = "begin" })
    local cRes, cWhy = MH.callAsync("nr_probe", "rp_netrunner", "nrCommit", { opId = "act-forged-1",
        actionId = "breach_watson_junction", playerId = 1, reservation = { txOpId = "nr.breach:forged" } })
    local rRes, rWhy = MH.callAsync("nr_probe", "rp_netrunner", "nrReserve", { opId = "act-forged-2",
        actionId = "breach_watson_junction", playerId = 1 })
    -- the export's posting rules
    local _, unknownSite = post({ site = "nowhere" })
    local _, notFixer = post({ site = "den_node", fixer = 3 })
    local _, badReward = post({ site = "den_node", reward = 99999 })
    local _, badDeadline = post({ site = "den_node", minutes = 5 })
    local _, busy = post({ site = "corp_lobby" })
    local ok, detail = conserved()
    return NRW.result({
        no_contract = noContract, citizen = citizen, taken = taken, second = second,
        winners = winners, winner_state = meta2 and meta2.state,
        no_kit = noKit and noKit.state, no_kit_reason = noKit and noKit.reason,
        no_kit_attempts = metaNoKit and metaNoKit.attempts, told_kit = toldKit,
        no_shard = tostring(NRW.whereIs("nrs." .. s.id)),
        wrong_site = wrongSite, early = early,
        forged_validate = tostring(vAllowed) .. ":" .. tostring(vWhy), forged_validate_ok = okV,
        forged_commit = tostring(cRes) .. ":" .. tostring(cWhy), forged_reserve = tostring(rRes) .. ":" .. tostring(rWhy),
        unknown_site = unknownSite, not_fixer = notFixer, bad_reward = badReward, bad_deadline = badDeadline, busy = busy,
        conserved = ok, conservation = detail, unbalanced = tostring(NRW.unbalanced()),
    })
end

-- ---------------------------------------------------------------------------------------------
-- A player fixer posts through the board (context, sites, reward and deadline), a runner takes it,
-- breaches the corporate desk (the seated keyboard pose), the drop refuses while the fixer is in the
-- city, the fixer declines the first hand-over (nothing moves) and accepts the second: ONE sale,
-- the runner paid, the fixer's cut to the fixer's own cash. Strict writers.
-- ---------------------------------------------------------------------------------------------
local function offerOf(runnerPid)
    for id, st in pairs(MH.shared.world.ix) do
        if tonumber(st.actor) == runnerPid then return id, st end
    end
    return nil
end

function scenarios.player_fixer()
    NRW.boot({ writers = NRW.WRITERS_STRICT })
    NRW.join(1, A, "Runner", DROP)
    NRW.join(2, B, "Fixer", DROP)
    setupRunner(1, 1)
    setupFixer(2)
    give(1, "chip", 1)
    force(true)
    NRW.answer(2, {
        { kind = "context", value = { id = "post" } },
        { kind = "context", value = { id = "s:corp_lobby" } },
        { kind = "input", value = { reward = 1200, minutes = 45 } },
    })
    local talk = NRW.act(2, "talk", "fixer_afterlife", 20)
    MH.until_(function() return next(svc().contracts) ~= nil end, 20)
    MH.run(1)
    local id = next(svc().contracts)
    local c = svc().contracts[id]
    local posted = { poster = c.poster, fixer = c.fixer, reward = c.reward, cut = c.cut, minutes = (c.deadline - c.posted) // 60 }
    take(1, c.code)
    local toldFixerTaken = NRW.told(2, "took your contract")
    NRW.move(1, LOBBY)
    local b = breach(1, "corp_lobby")
    local desk = NRW.played(1, "amb_d7c499_sit_chair_table_keybo", "playAt")
    NRW.move(1, DROP)
    -- The drop refuses while the fixer is in the city.
    NRW.intent(1, "rp_netrunner:talk", "rp_netrunner:fixer_afterlife")
    MH.run(3)
    local inPerson = NRW.told(1, "hand them the shard in person")
    local noDeliverOp = opOf(1, "deliver", 0) == nil
    -- Hand-over, declined.
    local cashA0, cashB0 = NRW.balance("cash:" .. A), NRW.balance("cash:" .. B)
    MH.command("netrun", 1, { "deliver", "2" })
    MH.run(1)
    local ix1 = offerOf(1)
    local toldFixerOffer = NRW.told(2, "hands you the data shard")
    NRW.respond(ix1, false)
    MH.run(2)
    local declined = { shard = NRW.whereIs("nrs." .. id), cashA = NRW.balance("cash:" .. A) == cashA0,
        told = NRW.told(1, "declined") }
    -- Hand-over, accepted.
    MH.command("netrun", 1, { "deliver", "2" })
    MH.run(1)
    local ix2 = offerOf(1)
    NRW.respond(ix2, true)
    MH.until_(function() return svc().contracts[id] == nil end, 20)
    MH.run(2)
    local deliver = NRW.jobEvents("deliver")[1]
    local ok, detail = conserved()
    return NRW.result({
        talk = talk and talk.state, poster = posted.poster, fixer = posted.fixer, reward = posted.reward, cut = posted.cut,
        minutes = posted.minutes, told_fixer_taken = toldFixerTaken,
        b = b and b.state, desk_pose = desk ~= nil and math.abs(desk.position.y - LOBBY.y) < 1e-6,
        in_person = inPerson, no_deliver_op = noDeliverOp,
        offer1 = ix1 ~= nil, told_fixer_offer = toldFixerOffer,
        declined_shard = tostring(declined.shard), declined_cash = declined.cashA, declined_told = declined.told,
        offer2 = ix2 ~= nil, runner_paid = NRW.balance("cash:" .. A) - cashA0, fixer_cut = NRW.balance("cash:" .. B) - cashB0,
        shard_after = tostring(NRW.whereIs("nrs." .. id)), contract_after = tostring(NRW.whereIs("nrc." .. id)),
        deliver_via = deliver and deliver.data.via, deliver_poster = deliver and deliver.data.poster,
        told_fixer_paid = NRW.told(2, "your cut"), grants = MH.shared.nr.grants,
        conserved = ok, conservation = detail, unbalanced = tostring(NRW.unbalanced()),
    })
end

-- ---------------------------------------------------------------------------------------------
-- The posting fixer left the city: the drop at the fixer point pays, the cut reaches the fixer's
-- cash while they are offline.
-- ---------------------------------------------------------------------------------------------
function scenarios.fixer_away()
    NRW.boot()
    NRW.join(1, A, "Runner", DROP)
    NRW.join(2, B, "Fixer", DROP)
    setupRunner(1)
    setupFixer(2)
    give(1, "chip", 1)
    force(true)
    local s = post({ site = "watson_junction", fixer = 2, reward = 600, minutes = 30 })
    take(1, s.code)
    NRW.move(1, JUNCTION)
    breach(1, "watson_junction")
    NRW.move(1, DROP)
    local cashB0 = NRW.balance("cash:" .. B)
    MH.disconnect(2)
    MH.run(1)
    local cashA0 = NRW.balance("cash:" .. A)
    local d = talkThenDeliver(1)
    MH.run(2)
    return NRW.result({
        d = d and d.state, runner_paid = NRW.balance("cash:" .. A) - cashA0, fixer_cut = NRW.balance("cash:" .. B) - cashB0,
        cut = s.cut, net = s.net, shard_after = tostring(NRW.whereIs("nrs." .. s.id)),
        unbalanced = tostring(NRW.unbalanced()),
    })
end

-- ---------------------------------------------------------------------------------------------
-- Restart: a full server restart with a shard in the runner's pockets (the board is rebuilt from
-- the coordinator; the delivery pays once); then a crash between a sale and the retirement of its
-- contract: rp_netrunner restarts, finds the sale committed and retires it without paying again.
-- ---------------------------------------------------------------------------------------------
function scenarios.restart_with_shard()
    NRW.boot()
    NRW.join(1, A, "Runner", JUNCTION)
    setupRunner(1)
    give(1, "chip", 2)
    force(true)
    local s = post({ site = "watson_junction", reward = 500, minutes = 60 })
    take(1, s.code)
    local b = breach(1, "watson_junction")
    local keep = NRW.keep()
    NRW.boot({ keep = keep })
    NRW.join(1, A, "Runner", DROP)
    setupRunner(1)
    force(true)
    local rebuilt = svc().contracts[s.id]
    local shardAt = NRW.whereIs("nrs." .. s.id)
    local cash0 = NRW.balance("cash:" .. A)
    local d = talkThenDeliver(1)
    MH.run(2)
    local cash1 = NRW.balance("cash:" .. A)
    MH.command("netrun", 1, { "deliver" })
    MH.run(2)
    local again = NRW.told(1, "You hold no contract")
    local cash2 = NRW.balance("cash:" .. A)
    -- The crash window between a sale and the retirement of its contract.
    local s2 = post({ site = "watson_junction", reward = 400, minutes = 60 })
    take(1, s2.code)
    NRW.move(1, JUNCTION)
    breach(1, "watson_junction")
    NRW.move(1, DROP)
    local realRetire = svc().retire
    svc().retire = function() return nil, "crashed" end
    local cash3 = NRW.balance("cash:" .. A)
    local d2 = talkThenDeliver(1)
    MH.run(1)
    local stillOnBoard = NRW.boardContract(s2.id) ~= nil
    local cash4 = NRW.balance("cash:" .. A)
    NRW.restartResource()
    MH.run(15)
    local ok, detail = conserved()
    return NRW.result({
        b = b and b.state, rebuilt_state = rebuilt and rebuilt.state, rebuilt_taker = rebuilt and rebuilt.taker,
        shard_kept = tostring(shardAt), d = d and d.state, paid = cash1 - cash0, again = again, paid_again = cash2 - cash1,
        d2 = d2 and d2.state, crash_paid = cash4 - cash3, still_on_board = stillOnBoard,
        recovered = NRW.boardContract(s2.id) == nil, after_restart_paid = NRW.balance("cash:" .. A) - cash4,
        recovered_events = (function()
            local n = 0
            for _, e in ipairs(NRW.jobEvents("deliver")) do if e.data.via == "recovered" then n = n + 1 end end
            return n
        end)(),
        real_retire = realRetire ~= nil,
        conserved = ok, conservation = detail, unbalanced = tostring(NRW.unbalanced()),
    })
end

-- ---------------------------------------------------------------------------------------------
-- Exactly once: a breach commit whose acknowledgement is lost (settled once); a delivery sale that
-- rp_economy reports in doubt while it lands (open77_actions retries the commit, the sweep finishes
-- it, paid once); a coordinator that dies with a breach commit queued, landing (detached) or not
-- (discarded): settled, the shard minted exactly when the chip was burned; a replayed commit.
-- ---------------------------------------------------------------------------------------------
local function crashBreach(pid, site, mode)
    local mark = NRW.mark()
    NRW.intent(pid, "rp_netrunner:breach_" .. site, "rp_netrunner:site_" .. site)
    NRW.waitState(pid, "breach_" .. site, mark, "presenting", 15)
    MH.shared.txPaused = true
    NRW.waitState(pid, "breach_" .. site, mark, "committing", 40)
    MH.until_(function() return NRW.store():pending() > 0 end, 10)
    MH.shared.txOnStop = mode
    MH.stop("open77_transactions")
    local op = NRW.finish(pid, "breach_" .. site, 40, mark)
    MH.shared.txPaused = false
    MH.shared.txOnStop = nil
    SFW.startCoordinator()
    MH.run(15)
    return op
end

function scenarios.exactly_once()
    NRW.boot()
    NRW.join(1, A, "Runner", JUNCTION)
    setupRunner(1)
    give(1, "chip", 5)
    force(true)
    -- 1. lost acknowledgement of the breach commit
    local s1 = post({ site = "watson_junction", reward = 500 })
    take(1, s1.code)
    local mark = NRW.mark()
    NRW.intent(1, "rp_netrunner:breach_watson_junction", "rp_netrunner:site_watson_junction")
    NRW.waitState(1, "breach_watson_junction", mark, "presenting", 15)
    NRW.store().faults = { "lost_ack" }
    local lost = NRW.finish(1, "breach_watson_junction", 60, mark)
    MH.run(6)
    local lostMeta = NRW.boardContract(s1.id)
    local successes1 = #NRW.jobEvents("breach_success")
    -- 2. the delivery sale reported in doubt while it lands
    NRW.move(1, DROP)
    local ports = svc().P
    local realSale = ports.economy.sale
    local calls = 0
    ports.economy.sale = function(spec)
        calls = calls + 1
        realSale(spec)
        return nil, "in_doubt", { retryable = true, opId = spec.opId }
    end
    local cash0 = NRW.balance("cash:" .. A)
    local d = talkThenDeliver(1, 60)
    MH.until_(function() return svc().contracts[s1.id] == nil end, 60)
    MH.run(6)
    ports.economy.sale = realSale
    local paid = NRW.balance("cash:" .. A) - cash0
    local deliveries = #NRW.jobEvents("deliver")
    -- 3. the coordinator dies with a breach commit queued: detached (it lands) / discarded (it does not)
    local s2 = post({ site = "watson_junction", reward = 500 })
    take(1, s2.code)
    NRW.move(1, JUNCTION)
    local chipsA = NRW.count("char:" .. A, "chip")
    local o3 = crashBreach(1, "watson_junction", "detached")
    local meta3 = NRW.boardContract(s2.id)
    local chipsB = NRW.count("char:" .. A, "chip")
    local shard3 = NRW.whereIs("nrs." .. s2.id)
    NRW.move(1, DROP)
    talkThenDeliver(1)
    MH.run(2)
    local s3 = post({ site = "watson_junction", reward = 500 })
    take(1, s3.code)
    NRW.move(1, JUNCTION)
    local chipsC = NRW.count("char:" .. A, "chip")
    local o4 = crashBreach(1, "watson_junction", "discard")
    local meta4 = NRW.boardContract(s3.id)
    local chipsD = NRW.count("char:" .. A, "chip")
    -- 4. a replayed commit of a committed breach: the stored receipt, nothing moves
    local firstBreach
    for opId, row in pairs(NRW.store().ops) do
        if row.state == "committed" and row.kind == "netrunner.breach" then firstBreach = opId break end
    end
    local shardsBefore = 0
    for iid in pairs(NRW.store().instances) do if iid:match("^nrs%.") then shardsBefore = shardsBefore + 1 end end
    local replay = MH.callAsync("nr_probe", "open77_transactions", "commit", firstBreach)
    MH.run(1)
    local shardsAfter = 0
    for iid in pairs(NRW.store().instances) do if iid:match("^nrs%.") then shardsAfter = shardsAfter + 1 end end
    local ok, detail = conserved()
    return NRW.result({
        lost = lost and lost.state, lost_state = lostMeta and lostMeta.state, successes1 = successes1,
        lost_shard = tostring(NRW.whereIs("nrs." .. s1.id)),
        d = d and d.state, sale_calls = calls, paid = paid, deliveries = deliveries,
        o3 = o3 and o3.state, meta3 = meta3 and meta3.state, chips3 = chipsA - chipsB, shard3 = tostring(shard3),
        o4 = o4 and o4.state, meta4 = meta4 and meta4.state, attempts4 = meta4 and meta4.attempts, chips4 = chipsC - chipsD,
        shard4 = tostring(NRW.whereIs("nrs." .. s3.id)),
        replay = type(replay) == "table" and tostring(replay.replay) or tostring(replay),
        shards_same = shardsBefore == shardsAfter,
        conserved = ok, conservation = detail, unbalanced = tostring(NRW.unbalanced()),
    })
end

-- ---------------------------------------------------------------------------------------------
-- Expiry: an open contract past its deadline leaves the board; a breached one takes its stale shard
-- with it (from the runner's pockets, in the same operation).
-- ---------------------------------------------------------------------------------------------
function scenarios.expiry()
    NRW.boot({ config = function(cfg) cfg.tiers[1].minutes.min = 1 end })
    NRW.join(1, A, "Runner", JUNCTION)
    setupRunner(1)
    give(1, "chip", 1)
    force(true)
    local s1 = post({ site = "watson_junction", minutes = 1 })
    MH.run(75)
    local open1 = NRW.whereIs("nrc." .. s1.id)
    local s2 = post({ site = "watson_junction", minutes = 2 })
    take(1, s2.code)
    local b = breach(1, "watson_junction")
    local shardBefore = NRW.whereIs("nrs." .. s2.id)
    MH.run(130)
    return NRW.result({
        open_expired = tostring(open1), b = b and b.state, shard_before = tostring(shardBefore),
        contract_after = tostring(NRW.whereIs("nrc." .. s2.id)), shard_after = tostring(NRW.whereIs("nrs." .. s2.id)),
        active_after = tostring(svc().activeOf[A]), expired_events = #NRW.contractEvents("expired"),
        told = NRW.told(1, "expired: the shard went stale"), unbalanced = tostring(NRW.unbalanced()),
    })
end

-- ---------------------------------------------------------------------------------------------
-- The NPC board keeps `open` contracts up (one a minute, on distinct free sites, rewards inside the
-- tier's bounds), and never more, also across a restart.
-- ---------------------------------------------------------------------------------------------
function scenarios.npc_board()
    NRW.boot({ npcBoard = true })
    MH.run(4 * 60 + 10)
    local function npcOpen()
        local n, sites, rewardsOk, codes = 0, {}, true, {}
        for _, c in pairs(svc().contracts) do
            if c.poster == "npc" and c.state == "open" then
                n = n + 1
                sites[c.site] = (sites[c.site] or 0) + 1
                local tier = NRW.cfg().tiers[c.tier]
                if c.reward < tier.reward.min or c.reward > tier.reward.max or c.reward % 50 ~= 0 then rewardsOk = false end
                codes[c.code] = true
            end
        end
        local distinct, ncodes = true, 0
        for _, k in pairs(sites) do if k > 1 then distinct = false end end
        for _ in pairs(codes) do ncodes = ncodes + 1 end
        return n, distinct, rewardsOk, ncodes
    end
    local n1, distinct, rewardsOk, codes = npcOpen()
    NRW.restartResource(function(cfg) cfg.npcBoard.enabled = true end)
    MH.run(130)
    local n2 = npcOpen()
    return NRW.result({ open = n1, distinct = distinct, rewards_ok = rewardsOk, codes = codes, after_restart = n2,
        board = NRW.boardCount(), unbalanced = tostring(NRW.unbalanced()) })
end

-- ---------------------------------------------------------------------------------------------
-- Exports for the fixer board: reads (contracts, contract, sites, activeContract), posting limits
-- per fixer, cancelling (only the poster, only open), and the contract events.
-- ---------------------------------------------------------------------------------------------
function scenarios.exports()
    NRW.boot()
    NRW.join(1, A, "Runner", JUNCTION)
    NRW.join(2, B, "Fixer", DROP)
    NRW.join(3, C, "Citizen", DROP)
    setupRunner(1)
    setupFixer(2)
    local s1 = post({ site = "corp_lobby", fixer = 2, reward = 1000, minutes = 30 })
    local s2 = post({ site = "den_node", fixer = 2 })
    local s3 = post({ site = "club_office", fixer = 2 })
    local _, tooMany = post({ site = "plaza_desk", fixer = 2 })
    local s4 = post({ site = "watson_junction" })
    local okList, list = MH.callSync("nr_probe", "rp_netrunner", "contracts", nil)
    local okOne, one = MH.callSync("nr_probe", "rp_netrunner", "contract", s1.code)
    local okSites, sites = MH.callSync("nr_probe", "rp_netrunner", "sites")
    local busy = 0
    for _, site in ipairs(sites or {}) do if site.busy then busy = busy + 1 end end
    local okNone, none = MH.callSync("nr_probe", "rp_netrunner", "activeContract", 1)
    take(1, s4.code)
    local okMine, mine = MH.callSync("nr_probe", "rp_netrunner", "activeContract", 1)
    local okOpen, openOnly = MH.callSync("nr_probe", "rp_netrunner", "contracts", { state = "open" })
    local c1, c1why = MH.callAsync("nr_probe", "rp_netrunner", "cancel", s1.code, 3)
    local c2, c2why = MH.callAsync("nr_probe", "rp_netrunner", "cancel", s4.code)
    local c3 = MH.callAsync("nr_probe", "rp_netrunner", "cancel", s1.code, 2)
    MH.run(1)
    local phases = {}
    for _, e in ipairs(MH.shared.contractEvents) do phases[e.phase] = (phases[e.phase] or 0) + 1 end
    local cancelled = NRW.contractEvents("cancelled")[1]
    return NRW.result({
        s1 = s1 and s1.poster, s1_fixer_name = s1 and s1.fixerName, s1_cut = s1 and s1.cut, s1_net = s1 and s1.net,
        s2_default = s2 and s2.reward, s3 = s3 ~= nil, too_many = tooMany,
        list_ok = okList, list_n = list and #list, one_reward = okOne and one and one.reward,
        one_area = okOne and one and one.area, sites_n = sites and #sites, sites_busy = busy,
        none = tostring(okNone and none), mine = okMine and mine and mine.code == s4.code, open_n = okOpen and #openOnly,
        cancel_other = tostring(c1) .. ":" .. tostring(c1why), cancel_taken = tostring(c2) .. ":" .. tostring(c2why),
        cancel_own = tostring(c3), cancelled_gone = NRW.boardContract(s1.id) == nil,
        cancelled_by = cancelled and cancelled.summary.by,
        posted_events = phases.posted, taken_events = phases.taken, cancelled_events = phases.cancelled,
        unbalanced = tostring(NRW.unbalanced()),
    })
end

-- ---------------------------------------------------------------------------------------------
-- Quickhacks kept from 1.x, every item burned through the coordinator: a ping (refused without the
-- item, cooldown), a Short Circuit (the deck loads first; the item is burned only when the platform
-- accepts the upload, released when it refuses), the jammer (events on and off).
-- ---------------------------------------------------------------------------------------------
function scenarios.quickhacks()
    NRW.boot()
    NRW.join(1, A, "Runner", JUNCTION)
    NRW.join(2, B, "Target", NEAR_JUNCTION)
    NRW.join(5, "acct-e", "Officer", DROP)
    setupRunner(1)
    MH.callSync("nr_probe", "rp_jobs", "setJob", 5, "ncpd", 0)
    MH.callSync("nr_probe", "rp_jobs", "setDuty", 5, true)
    MH.command("ping", 1, { "2" })
    MH.run(2)
    local noItem = NRW.told(1, "No Quickhack: Ping")
    give(1, "qh_ping", 2)
    MH.command("ping", 1, { "2" })
    MH.run(2)
    local pinged = false
    for _, e in ipairs(MH.shared.world.client) do
        if e.name == "rp_netrunner:ping" and e.pid == 1 then pinged = true end
    end
    local pingsLeft = NRW.count("char:" .. A, "qh_ping")
    MH.command("ping", 1, { "2" })
    MH.run(2)
    local cooling = NRW.told(1, "Ping is cooling down")
    local pingsAfterCooldown = NRW.count("char:" .. A, "qh_ping")
    local gesture = NRW.played(1, "phonecheck") ~= nil
    -- Short Circuit
    give(1, "qh_short_circuit", 2)
    MH.command("court_circuit", 1, { "2" })
    MH.run(2)
    local loading = NRW.told(1, "Loading Short Circuit")
    local scAfterLoad = NRW.count("char:" .. A, "qh_short_circuit")
    MH.command("court_circuit", 1, { "2" })
    MH.run(2)
    local starts = #MH.shared.nr.hackStarts
    local scAfterUpload = NRW.count("char:" .. A, "qh_short_circuit")
    MH.run(31)
    MH.shared.nr.hackRefuse = "self_ice"
    MH.command("court_circuit", 1, { "2" })
    MH.run(2)
    local refusedTold = NRW.told(1, "Short Circuit refused: their Self%-ICE bounced it%.")
        and not NRW.told(1, "self_ice")
    local scAfterRefusal = NRW.count("char:" .. A, "qh_short_circuit")
    -- Jammer
    give(1, "qh_jammer", 1)
    MH.command("brouiller", 1, {})
    MH.run(2)
    local jamOn = MH.shared.jammed[1]
    local staticSent = false
    for _, c in ipairs(MH.chat) do
        if c.target == 5 and c.resource == "rp_netrunner" and type(c.message) == "table" and c.message.author == "NCPD RADIO" then
            staticSent = true
        end
    end
    MH.run(62)
    local jamOff = MH.shared.jammed[2]
    return NRW.result({
        no_item = noItem, pinged = pinged, pings_left = pingsLeft, cooling = cooling, pings_after_cooldown = pingsAfterCooldown,
        gesture = gesture, burned_pings = NRW.journal("^sys:netrunner$", "qh_ping"),
        loading = loading, sc_after_load = scAfterLoad, starts = starts, sc_after_upload = scAfterUpload,
        refused_told = refusedTold, sc_after_refusal = scAfterRefusal,
        jam_on = tostring(jamOn), static_sent = staticSent, jam_off = tostring(jamOff),
        jammer_left = NRW.count("char:" .. A, "qh_jammer"),
        unbalanced = tostring(NRW.unbalanced()),
    })
end

-- ---------------------------------------------------------------------------------------------
-- The whole loop from the restricted console, with explicit player ids.
-- ---------------------------------------------------------------------------------------------
function scenarios.console()
    NRW.boot()
    NRW.join(1, A, "Runner", LOBBY)
    NRW.join(2, B, "Fixer", DROP)
    NRW.command("netrun.setup", { "1", "netrunner", "3" })
    NRW.command("netrun.setup", { "2", "fixer" })
    MH.run(1)
    NRW.command("netrun.give", { "1", "chip", "1" })
    MH.run(3)
    force(true)
    NRW.command("netrun.post", { "corp_lobby", "1000", "30", "2" })
    MH.run(3)
    local id = next(svc().contracts)
    local c = id and svc().contracts[id]
    NRW.command("netrun.take", { "1", c and c.code or "?" })
    MH.run(3)
    local mark = NRW.mark()
    NRW.command("netrun.breach", { "1" })
    local b = NRW.finish(1, "breach_corp_lobby", 60, mark)
    NRW.command("netrun.state", { "1" })
    NRW.command("netrun.status", {})
    MH.run(3)
    NRW.move(1, DROP)
    NRW.command("netrun.deliver", { "1", "2" })
    MH.run(2)
    local ix = offerOf(1)
    if ix then NRW.respond(ix, true) end
    MH.until_(function() return id and svc().contracts[id] == nil end, 20)
    MH.run(1)
    NRW.command("netrun.post", { "watson_junction" })
    MH.run(3)
    local id2 = next(svc().contracts)
    local c2 = id2 and svc().contracts[id2]
    NRW.command("netrun.expire", { c2 and c2.code or "?" })
    MH.run(3)
    return NRW.result({
        posted = c ~= nil and c.poster == "player", b = b and b.state, delivered = id ~= nil and svc().contracts[id] == nil,
        state_line = NRW.printed("player 1 subject acct%-a contract=%w+ state=breached chips=0 shards=%[nrs%."),
        chance_line = NRW.printed("chance now 100%%"), status_line = NRW.printed("ready=true board=true"),
        post_line = NRW.printed("posted %w+ %(lab"), take_line = NRW.printed("player 1 took"),
        expired = id2 ~= nil and NRW.boardContract(id2) == nil, expire_line = NRW.printed("expire %w+: retired"),
        unbalanced = tostring(NRW.unbalanced()),
    })
end

-- ---------------------------------------------------------------------------------------------
-- The pure rules (server/model.lua): the roll, the odds, codes, bounds, the failure outcome, the sale.
-- ---------------------------------------------------------------------------------------------
function scenarios.model()
    dofile(ROOT_DIR .. "/rp_netrunner/server/model.lua")
    local M = NetrunnerModel
    local tier = { baseChance = 40, reward = { min = 1600, max = 3000, default = 2200 }, minutes = { min = 30, max = 120, default = 60 } }
    local diff = { gradeBonus = 8, retryPenalty = 5, minChance = 10, maxChance = 95 }
    local same = M.breachRoll("nr.breach:lab-x-1") == M.breachRoll("nr.breach:lab-x-1")
    local inRange = true
    for i = 1, 500 do
        local r = M.breachRoll("seed" .. i)
        if r < 1 or r > 100 then inRange = false end
    end
    local used = {}
    local code1 = M.codeFor("lab-a-1", used)
    used[code1] = true
    local code2 = M.codeFor("lab-a-1", used)
    local sale = M.deliverySale({ opId = "nr.deliver:x.a1", taker = "s1", sellerPid = 7, shard = "nrs.x", pockets = "char:s1",
        reward = 1000, cut = 150, cutTo = { society = "fixer" }, buyer = "client", reason = "r" })
    local npcReward = M.npcReward(tier, "seed", 50)
    return NRW.result({
        roll_deterministic = same, roll_range = inRange,
        chance_base = M.breachChance(tier, diff, 0, 0), chance_grade3 = M.breachChance(tier, diff, 3, 0),
        chance_retry2 = M.breachChance(tier, diff, 0, 2), chance_floor = M.breachChance(tier, diff, 0, 20),
        chance_cap = M.breachChance({ baseChance = 99 }, diff, 3, 0),
        code_len = #code1, code_differs = code1 ~= code2,
        reward_default = M.reward(tier, nil), reward_low = tostring(select(2, M.reward(tier, 10))),
        reward_ok = M.reward(tier, 2000), minutes_bad = tostring(select(2, M.minutes(tier, 500))),
        npc_reward_ok = npcReward >= 1600 and npcReward <= 3000 and npcReward % 50 == 0,
        cut = M.cutOf(1000, 0.15), cut_zero = M.cutOf(1000, 0),
        fail_retry = M.failureOutcome({ mode = "retry", maxAttempts = 3 }, 1),
        fail_last = M.failureOutcome({ mode = "retry", maxAttempts = 3 }, 3),
        fail_reopen = M.failureOutcome({ mode = "reopen", maxAttempts = 3 }, 2),
        sale_total = sale.total, sale_payees = #sale.payees, sale_net = sale.payees[1].amount,
        sale_cut_society = sale.payees[2].society, sale_seller = sale.seller.player, sale_buyer = sale.buyer.sys,
        sale_item = sale.items[1].instance, sale_from = sale.items[1].from,
        valid_record = M.validRecord(M.newContract({ id = "lab-a-1", code = "ABCD", site = "x", tier = 1, reward = 10,
            cut = 1, poster = "npc", fixer = "afterlife", point = "afterlife", posted = 1, deadline = 2 })),
        invalid_record = M.validRecord({ app = "other" }),
        text_known = M.textFor("no_breach_kit"), text_unknown = M.textFor("weird_token"),
    })
end

-- ---------------------------------------------------------------------------------------------
-- A hand-over waiting for the fixer's consent is withdrawn when the runner clocks off (the work
-- epoch moved): nothing is paid, the shard stays; a completion after an epoch change is refused.
-- ---------------------------------------------------------------------------------------------
function scenarios.handover_epoch()
    NRW.boot()
    NRW.join(1, A, "Runner", DROP)
    NRW.join(2, B, "Fixer", DROP)
    setupRunner(1)
    setupFixer(2)
    give(1, "chip", 1)
    force(true)
    local s = post({ site = "watson_junction", fixer = 2, reward = 600, minutes = 30 })
    take(1, s.code)
    NRW.move(1, JUNCTION)
    breach(1, "watson_junction")
    NRW.move(1, DROP)
    local cashA0, cashB0 = NRW.balance("cash:" .. A), NRW.balance("cash:" .. B)
    MH.command("netrun", 1, { "deliver", "2" })
    MH.run(1)
    local offered = offerOf(1) ~= nil
    MH.callSync("nr_probe", "rp_jobs", "setDuty", 1, false)
    MH.run(2)
    local withdrawn = offerOf(1) == nil
    local reason
    for _, e in ipairs(MH.shared.world.ixLog) do if e.op == "cancelled" then reason = e.reason end end
    return NRW.result({
        offered = offered, withdrawn = withdrawn, reason = tostring(reason),
        told_runner = NRW.told(1, "The hand%-over was cancelled: the netrunner's shift changed%. You keep the shard%."),
        told_fixer = NRW.told(2, "The hand%-over was cancelled: the netrunner's shift changed%."),
        raw_shown = NRW.told(1, "stale_job_epoch") or NRW.told(2, "stale_job_epoch"),
        shard = tostring(NRW.whereIs("nrs." .. s.id)), cash_a_same = NRW.balance("cash:" .. A) == cashA0,
        cash_b_same = NRW.balance("cash:" .. B) == cashB0, still_breached = NRW.boardContract(s.id).state,
        unbalanced = tostring(NRW.unbalanced()),
    })
end

-- ---------------------------------------------------------------------------------------------
-- Library restarts: open77_actions forgets every action and target (declared again on its ready
-- event, a breach works after it); rp_inventory comes back with its built-ins only (the items are
-- defined again); the coordinator restarts (the board is read again, nothing is lost).
-- ---------------------------------------------------------------------------------------------
function scenarios.library_restarts()
    NRW.boot()
    NRW.join(1, A, "Runner", JUNCTION)
    setupRunner(1)
    give(1, "chip", 1)
    force(true)
    local s = post({ site = "watson_junction" })
    take(1, s.code)
    MH.stop("open77_actions")
    SFW.startActions()
    MH.run(3)
    local redeclared = NRW.printed("open77_actions restarted: actions and targets declared again")
    local defines0 = NRW.printed("items defined through rp_inventory")
    MH.stop("rp_inventory")
    SFW.shim("rp_inventory", NRW.INVENTORY)
    NRW.defineChip()      -- a built-in of the real rp_inventory
    MH.run(3)
    local defines1 = NRW.printed("items defined through rp_inventory")
    MH.stop("open77_transactions")
    SFW.startCoordinator()
    MH.run(10)
    local board = svc().contracts[s.id]
    local b = breach(1, "watson_junction")
    return NRW.result({
        redeclared = redeclared, defined_again = defines1 > defines0, board_kept = board ~= nil and board.state,
        b = b and b.state, shard = tostring(NRW.whereIs("nrs." .. s.id)), unbalanced = tostring(NRW.unbalanced()),
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
