-- tests/compat/techie_scenarios.lua: the techie job (rp_techie) end to end, offline.
--
-- Loaded by tests/test_techie.py after fakehost.lua (unused here) with the string globals ROOT_DIR,
-- COMPAT_DIR, SYS_DIR and TX_DIR (techie_world.lua). Players act the way the open77_actions client
-- and the platform's interaction UI make them act: prompt intents from where they stand, chat
-- commands, and the invitation answer. Every check reads durable truth from the coordinator's store.

dofile(COMPAT_DIR .. "/techie_world.lua")

local scenarios = {}

local T, S, B, C = "acct-t", "acct-s", "acct-b", "acct-c"   -- techie, scrapper, buyer, second techie
local TRAY = TW.TRAY

local function svc() return TW.svc() end
local function pockets(subject, item) return SFW.count("char:" .. subject, item) end
local function tray(item) return SFW.count(TRAY, item) end
local function cash(subject) return SFW.balance("cash:" .. subject) end

local function kindsOf(events)
    local out = {}
    for _, e in ipairs(events) do out[#out + 1] = e.kind end
    return table.concat(out, ",")
end

-- ---------------------------------------------------------------------------------------------
-- Happy path, strict writers: a scrapper sells scrap to the techie with consent, the techie buys a
-- copper lot from the dealer, strips both at the workbench (a second techie is refused the claimed
-- bench), assembles a suppressor from the tray and sells it to the gun shop (one rp_economy sale,
-- society share). Every committed step fires rp:job:completed once.
-- ---------------------------------------------------------------------------------------------
function scenarios.happy_path()
    TW.boot({ writers = TW.WRITERS_STRICT })
    SFW.join(1, T, "Tech", TW.WORKBENCH)
    SFW.join(2, S, "Scrapper", TW.NEAR_WORKBENCH)
    SFW.join(3, C, "Tech Two", TW.BESIDE_WORKBENCH)
    TW.setup(1, 0)
    TW.setup(3, 0)
    TW.give(2, "scrap_metal", 6)
    local cashT0, cashS0 = cash(T), cash(S)
    -- 1. The scrapper offers 3 scrap metal for 66 eddies; the techie (the responder) accepts.
    MH.command("techie", 2, { "sell", "1", "scrap_metal", "3", "66" })
    MH.run(1)
    local toldOffer = TW.told(1, "offers to sell you 3 Scrap metal for 66 eddies")
    local tradeOp = TW.answer(1, true)
    local trade = { t = pockets(T, "scrap_metal"), s = pockets(S, "scrap_metal"), paid = cashT0 - cash(T), got = cash(S) - cashS0 }
    -- 2. The dealer: one copper lot (2 for 90).
    SFW.move(1, TW.DEALER)
    local cashT1 = cash(T)
    local b1 = TW.buy(1, "copper_wire")
    local bought = { state = b1 and b1.state, copper = pockets(T, "copper_wire"), paid = cashT1 - cash(T) }
    -- 3. Stage 1 at the workbench; the second techie tries the same bench meanwhile.
    SFW.move(1, TW.WORKBENCH)
    local mark = SFW.mark()
    SFW.intent(1, "rp_techie:craft_strip_plate", TW.KNEEL_T)
    SFW.waitState(1, "craft_strip_plate", mark, "presenting", 15)
    local trayDuring = tray("tch_alloy_plate")
    SFW.intent(3, "rp_techie:craft_strip_wire", TW.KNEEL_T)
    local s1 = SFW.finish(1, "craft_strip_plate", 40, mark)
    local claimed = table.concat(SFW.refusals(3), ",")
    local s2 = TW.craft(1, "strip_wire")
    local afterStrip = { plates = tray("tch_alloy_plate"), looms = tray("tch_wire_loom"), scrap = pockets(T, "scrap_metal"),
        copper = pockets(T, "copper_wire") }
    -- 4. Stage 2: the suppressor out of the tray into the pockets.
    local a1 = TW.craft(1, "assemble_suppressor")
    local afterAssemble = { plates = tray("tch_alloy_plate"), looms = tray("tch_wire_loom"), kits = pockets(T, "tch_mod_suppressor") }
    -- 5. The gun shop buys it: 240, of which 24 to the society.
    SFW.move(1, TW.GUNSHOP)
    local cashT2, soc0 = cash(T), SFW.balance("soc:techie")
    local sh = TW.sellShop(1, "gunshop")
    local shop = { state = sh and sh.state, kits = pockets(T, "tch_mod_suppressor"), paid = cash(T) - cashT2,
        society = SFW.balance("soc:techie") - soc0 }
    local weld = TW.played(1, "amb_1056d7_kneel_welder", "playAt")
    local drill = TW.played(1, "amb_cf84c6_kneel_use_driller", "playAt")
    local events = TW.jobEvents(nil, nil)
    local strips, assembles, sells, buys = TW.jobEvents("strip"), TW.jobEvents("assemble"), TW.jobEvents("sell"), TW.jobEvents("buy_parts")
    local ok, detail = TW.conserved({ "char:" .. T, "char:" .. S, "char:" .. C })
    return TW.result({
        told_offer = toldOffer, trade_done = tradeOp ~= nil and svc().done[tradeOp] ~= nil,
        trade_t = trade.t, trade_s = trade.s, trade_paid = trade.paid, trade_got = trade.got,
        buy = bought.state, buy_copper = bought.copper, buy_paid = bought.paid,
        tray_during = trayDuring, s1 = s1 and s1.state, claimed = claimed, s2 = s2 and s2.state,
        strip_plates = afterStrip.plates, strip_looms = afterStrip.looms, strip_scrap = afterStrip.scrap,
        strip_copper = afterStrip.copper,
        a1 = a1 and a1.state, a_plates = afterAssemble.plates, a_looms = afterAssemble.looms, a_kits = afterAssemble.kits,
        shop = shop.state, shop_kits = shop.kits, shop_paid = shop.paid, shop_society = shop.society,
        weld_at_bench = weld ~= nil and math.abs(weld.yaw - 155.0) < 1e-6 and math.abs(weld.position.x - TW.WORKBENCH.x) < 1e-6,
        drill_at_bench = drill ~= nil and math.abs(drill.position.y - TW.WORKBENCH.y) < 1e-6,
        give_gesture = TW.played(1, "give", "play") ~= nil,
        events = kindsOf(events), strip_events = #strips, assemble_events = #assembles, sell_events = #sells,
        buy_events = #buys, strip_ref = strips[1] and strips[1].ref or "",
        strip_job = strips[1] and strips[1].job or "", strip_pid = strips[1] and strips[1].playerId or "",
        strip_plate_out = strips[1] and strips[1].data and strips[1].data.outputs and strips[1].data.outputs.tch_alloy_plate or "",
        sell_total = sells[1] and sells[1].data and sells[1].data.total or "",
        sell_buyer = sells[1] and sells[1].data and sells[1].data.buyer or "",
        sold_events = #MH.shared.sold, crafted_events = #MH.shared.crafted,
        grants = #MH.shared.grants,
        told_assembled = TW.told(1, "Suppressor kit in your pockets"),
        told_shop = TW.told(1, "Sold to 2nd Amendment: 1 Suppressor kit for 240 eddies"),
        tray_free = TW.nothingHeld(TRAY), pockets_free = TW.nothingHeld("char:" .. T),
        conserved = ok, conservation = detail, unbalanced = tostring(SFW.unbalanced()),
    })
end

-- ---------------------------------------------------------------------------------------------
-- Trades between players: a product sold to a civilian (accepted, declined, a broke buyer), parts
-- bought by the techie from a scrapper (the scrapper consents), the ripperdoc's export, and a
-- clock-out that withdraws a waiting offer. Nothing moves without consent and payment together.
-- ---------------------------------------------------------------------------------------------
function scenarios.trades()
    TW.boot({ writers = TW.WRITERS_STRICT })
    SFW.join(1, T, "Tech", TW.WORKBENCH)
    SFW.join(2, S, "Scrapper", TW.NEAR_WORKBENCH)
    SFW.join(3, B, "Buyer", TW.BESIDE_WORKBENCH)
    TW.setup(1, 0)
    TW.give(1, "tch_mod_suppressor", 3)
    TW.give(1, "tch_cw_servo", 1)
    TW.give(2, "copper_wire", 4)
    -- 1. Accepted: 1 kit to the buyer for 300.
    local cashB0, cashT0 = cash(B), cash(T)
    MH.command("techie", 1, { "sell", "3", "tch_mod_suppressor", "1", "300" })
    MH.run(1)
    local told1 = TW.told(3, "offers to sell you 1 Suppressor kit for 300 eddies")
    local op1 = TW.answer(3, true)
    local accepted = { kits = pockets(B, "tch_mod_suppressor"), paid = cashB0 - cash(B), got = cash(T) - cashT0,
        left = pockets(T, "tch_mod_suppressor") }
    -- 2. Declined: nothing moves.
    MH.command("techie", 1, { "sell", "3", "tch_mod_suppressor", "1", "300" })
    MH.run(1)
    local cashB1 = cash(B)
    TW.answer(3, false)
    local declined = { kits = pockets(B, "tch_mod_suppressor"), cash = cash(B) == cashB1, told = TW.told(1, "declined the trade") }
    -- 3. A broke buyer: the hand-over completes, the payment is refused, nothing moves.
    local all = cash(B)
    MH.callAsync("tch_probe", "rp_economy", "pay", { opId = "test.drain.b.0001", from = { player = 3 }, to = { player = 2 }, amount = all })
    MH.run(2)
    MH.command("techie", 1, { "sell", "3", "tch_mod_suppressor", "1", "300" })
    MH.run(1)
    TW.answer(3, true)
    local broke = { kits = pockets(B, "tch_mod_suppressor"), cash = cash(B), left = pockets(T, "tch_mod_suppressor"),
        told = TW.told(3, "does not have enough cash") }
    MH.callAsync("tch_probe", "rp_economy", "pay", { opId = "test.refill.b.0001", from = { player = 2 }, to = { player = 3 }, amount = all })
    MH.run(2)
    -- 4. The techie asks to buy 2 copper wire from the scrapper for 80; the scrapper consents.
    local cashS0, cashT1 = cash(S), cash(T)
    MH.command("techie", 1, { "buy", "2", "copper_wire", "2", "80" })
    MH.run(1)
    local toldScrapper = TW.told(2, "wants to buy 2 Copper wire from you for 80 eddies")
    local op4 = TW.answer(2, true)
    local parts = { t = pockets(T, "copper_wire"), s = pockets(S, "copper_wire"), got = cash(S) - cashS0, paid = cashT1 - cash(T) }
    -- 5. The ripperdoc job's export: the buyer asks for a servo, the techie (the seller) consents.
    local res, why = MH.callAsync("rp_ripperdoc", "rp_techie", "offer",
        { seller = 1, buyer = 3, item = "tch_cw_servo", count = 1, price = 150, initiator = "buyer" })
    MH.run(1)
    local toldTechie = TW.told(1, "wants to buy 1 Servo actuator from you for 150 eddies")
    local op5 = TW.answer(1, true)
    local servo = { b = pockets(B, "tch_cw_servo"), t = pockets(T, "tch_cw_servo") }
    local denied, deniedWhy = MH.callAsync("tch_probe", "rp_techie", "offer",
        { seller = 1, buyer = 3, item = "tch_mod_suppressor", count = 1, price = 10 })
    -- 6. The techie clocks out while an offer waits: withdrawn at once, nothing moves.
    MH.command("techie", 1, { "sell", "3", "tch_mod_suppressor", "1", "250" })
    MH.run(1)
    local id6 = TW.offerOf(1)
    SFW.command("techie.lab.clock", { "1", "off" })
    MH.until_(function() return svc().offers[id6] == nil end, 10)
    MH.run(1)
    local withdrawn = MH.shared.world.ixLog[#MH.shared.world.ixLog].reason
    local sells = TW.jobEvents("sell", 1)
    local buys = TW.jobEvents("buy_parts", 1)
    local ok, detail = TW.conserved({ "char:" .. T, "char:" .. S, "char:" .. B })
    return TW.result({
        told1 = told1, op1_done = op1 ~= nil and svc().done[op1] ~= nil, acc_kits = accepted.kits, acc_paid = accepted.paid,
        acc_got = accepted.got, acc_left = accepted.left,
        dec_kits = declined.kits, dec_cash = declined.cash, dec_told = declined.told,
        broke_kits = broke.kits, broke_cash = broke.cash, broke_left = broke.left, broke_told = broke.told,
        told_scrapper = toldScrapper, op4_done = op4 ~= nil and svc().done[op4] ~= nil, parts_t = parts.t, parts_s = parts.s,
        parts_got = parts.got, parts_paid = parts.paid,
        export_ok = type(res) == "table" and res.interaction ~= nil, export_why = tostring(why), told_techie = toldTechie,
        servo_b = servo.b, servo_t = servo.t, op5_done = op5 ~= nil and svc().done[op5] ~= nil,
        denied = tostring(denied), denied_why = tostring(deniedWhy),
        withdrawn = withdrawn, offers_left = next(svc().offers) == nil, promised_left = next(svc().promised) == nil,
        sell_events = #sells, buy_events = #buys, trades = svc().stats.trades,
        conserved = ok, conservation = detail, unbalanced = tostring(SFW.unbalanced()),
    })
end

-- ---------------------------------------------------------------------------------------------
-- Refusals before any bar, each told to the player, nothing held: missing parts, missing
-- components, a full tray, a low grade, no job, off duty, nothing to sell, not enough cash for a
-- lot, trade misuse, and forged hook calls.
-- ---------------------------------------------------------------------------------------------
local function presented(pid, actionId, mark)
    local list = MH.shared.transitions
    for i = mark + 1, #list do
        if list[i].playerId == pid and list[i].actionId == actionId and list[i].state == "presenting" then return true end
    end
    return false
end

function scenarios.refusals()
    TW.boot()
    SFW.join(1, T, "Tech", TW.WORKBENCH)
    SFW.join(2, S, "Civilian", TW.NEAR_WORKBENCH)
    TW.setup(1, 0)
    -- 1. Missing parts (empty pockets).
    local m1 = SFW.mark()
    SFW.intent(1, "rp_techie:craft_strip_plate", TW.KNEEL_T)
    local r1 = SFW.finish(1, "craft_strip_plate", 20, m1)
    local told1 = TW.told(1, "Missing: 3 Scrap metal %(have 0%)")
    MH.run(2)
    -- 2. Missing components (empty tray).
    local m2 = SFW.mark()
    SFW.intent(1, "rp_techie:craft_assemble_suppressor", TW.KNEEL_T)
    local r2 = SFW.finish(1, "craft_assemble_suppressor", 20, m2)
    local told2 = TW.told(1, "tray is short of components")
    MH.run(2)
    -- 3. A full tray: a probe fills it (75 plates = 30 kg), then a strip that would add more.
    MH.callAsync("tch_probe", "open77_transactions", "transfer", { opId = "test.fill.tray.0001", kind = "test.fill",
        lines = { { item = "tch_alloy_plate", count = 75, from = "sys:probe", to = TRAY } } })
    TW.give(1, "scrap_metal", 3)
    MH.run(2)
    local m3 = SFW.mark()
    SFW.intent(1, "rp_techie:craft_strip_plate", TW.KNEEL_T)
    local r3 = SFW.finish(1, "craft_strip_plate", 20, m3)
    local told3 = TW.told(1, "tray is full")
    local scrapKept = pockets(T, "scrap_metal")
    MH.run(2)
    -- 4. A grade too low (the sight needs grade 1): asked by command, the bench prompt does not
    --    offer it (a forged prompt intent for it is refused invalid_target).
    MH.command("techie", 1, { "craft", "assemble_sight" })
    MH.run(1)
    SFW.intent(1, "rp_techie:craft_assemble_sight", TW.KNEEL_T)
    MH.run(2)
    -- 5. A civilian at the bench, then an off-duty techie.
    SFW.intent(2, "rp_techie:craft_strip_plate", TW.KNEEL_T)
    MH.run(1)
    SFW.command("techie.lab.clock", { "1", "off" })
    MH.run(1)
    SFW.intent(1, "rp_techie:craft_strip_plate", TW.KNEEL_T)
    MH.run(1)
    local refused1 = table.concat(SFW.refusals(1), ",")
    local refused2 = table.concat(SFW.refusals(2), ",")
    SFW.command("techie.lab.clock", { "1", "on" })
    MH.run(2)
    -- 6. Nothing the shop buys.
    SFW.move(1, TW.GUNSHOP)
    local r6 = TW.sellShop(1, "gunshop")
    local told6 = TW.told(1, "nothing this shop buys")
    MH.run(2)
    -- 7. Not enough cash for the chip lot (220): the techie gives everything away first.
    local all = cash(T)
    MH.callAsync("tch_probe", "rp_economy", "pay", { opId = "test.drain.t.0001", from = { player = 1 }, to = { player = 2 }, amount = all })
    MH.run(2)
    SFW.move(1, TW.DEALER)
    local r7 = TW.buy(1, "chip")
    local told7 = TW.told(1, "Not enough cash")
    local chips = pockets(T, "chip")
    MH.run(2)
    -- 8. Trade misuse.
    SFW.move(1, TW.WORKBENCH)
    MH.callAsync("tch_probe", "open77_transactions", "transfer", { opId = "test.give.c.0001", kind = "test.give",
        lines = { { item = "tch_mod_suppressor", count = 1, from = "sys:probe", to = "char:" .. S } } })
    local function trade(spec)
        local o, why = MH.callAsync("rp_ripperdoc", "rp_techie", "offer", spec)
        return o and "offered" or tostring(why)
    end
    local notTradeable = trade({ seller = 1, buyer = 2, item = "tch_alloy_plate", count = 1, price = 10 })
    local selfTrade = trade({ seller = 1, buyer = 1, item = "tch_mod_suppressor", count = 1, price = 10 })
    local noTechie = trade({ seller = 2, buyer = 1, item = "tch_mod_suppressor", count = 1, price = 10 })
    local badPrice = trade({ seller = 2, buyer = 1, item = "scrap_metal", count = 1, price = -5 })
    local badCount = trade({ seller = 2, buyer = 1, item = "scrap_metal", count = 0, price = 5 })
    local lacking = trade({ seller = 2, buyer = 1, item = "copper_wire", count = 1, price = 5 })
    MH.callAsync("tch_probe", "open77_transactions", "transfer", { opId = "test.give.c.0002", kind = "test.give",
        lines = { { item = "scrap_metal", count = 1, from = "sys:probe", to = "char:" .. S } } })
    SFW.move(2, TW.DEALER)
    SFW.move(1, TW.GUNSHOP)
    local far = trade({ seller = 2, buyer = 1, item = "scrap_metal", count = 1, price = 5 })
    -- 9. Forged hook calls: an export is callable by anyone.
    local forgedCommit, forgedWhy = SFW.sync("tch_probe", "rp_techie", "tchCommit", { opId = "act-x-1", actionId = "craft_strip_plate" })
    local forgedReserve, forgedRWhy = MH.callAsync("tch_probe", "rp_techie", "tchReserve", { opId = "act-x-2", actionId = "buy_kabuki_west_chip" })
    local tradesBefore = svc().stats.trades
    MH.emit("onPlayerInteractionCompleted", { id = "0000000000000000000000000000beef", actor = "1", target = "2", kind = "give" })
    MH.run(2)
    local ok, detail = TW.conserved({ "char:" .. T, "char:" .. S })
    return TW.result({
        r1 = r1 and r1.state, r1_reason = r1 and r1.reason, r1_stage = r1 and r1.stage, r1_presented = presented(1, "craft_strip_plate", m1),
        told1 = told1, r2 = r2 and r2.state, r2_reason = r2 and r2.reason, told2 = told2,
        r3 = r3 and r3.state, r3_reason = r3 and r3.reason, told3 = told3, scrap_kept = scrapKept,
        refused1 = refused1, refused2 = refused2, told_grade = TW.told(1, "grade is too low"),
        r6 = r6 and r6.state, r6_reason = r6 and r6.reason, told6 = told6,
        r7 = r7 and r7.state, r7_reason = r7 and r7.reason, r7_stage = r7 and r7.stage, told7 = told7, chips = chips,
        not_tradeable = notTradeable, self_trade = selfTrade, no_techie = noTechie, bad_price = badPrice,
        bad_count = badCount, lacking = lacking, far = far,
        forged_commit = tostring(forgedCommit), forged_why = tostring(forgedWhy),
        forged_reserve = tostring(forgedReserve), forged_rwhy = tostring(forgedRWhy),
        forged_trades = svc().stats.trades - tradesBefore,
        held = next(svc().work) == nil and TW.nothingHeld("char:" .. T),
        conserved = ok, conservation = detail, unbalanced = tostring(SFW.unbalanced()),
    })
end

-- ---------------------------------------------------------------------------------------------
-- Cancellations: X on the bar, death, a clock-out, walking away and an rp_techie restart in the
-- middle of a stage. Each releases the hold at once: nothing burned, nothing minted.
-- ---------------------------------------------------------------------------------------------
local function opIdSince(pid, actionId, mark)
    for i = mark + 1, #MH.shared.transitions do
        local op = MH.shared.transitions[i]
        if op.playerId == pid and op.actionId == actionId then return op.opId end
    end
    return nil
end

local function started(pid, recipe)
    local mark = SFW.mark()
    TW.startCraft(pid, recipe)
    SFW.waitState(pid, "craft_" .. recipe, mark, "presenting", 15)
    MH.run(2)
    return mark
end

function scenarios.cancellations()
    TW.boot()
    SFW.join(1, T, "Tech", TW.WORKBENCH)
    TW.setup(1, 0)
    TW.give(1, "scrap_metal", 6)
    -- 1. X on the bar.
    local m1 = started(1, "strip_plate")
    local heldDuring = not TW.nothingHeld("char:" .. T)
    SFW.clientCancel(1, opIdSince(1, "craft_strip_plate", m1))
    local c1 = SFW.finish(1, "craft_strip_plate", 20, m1)
    MH.run(1)
    local after1 = { scrap = pockets(T, "scrap_metal"), plates = tray("tch_alloy_plate"), free = TW.nothingHeld("char:" .. T) }
    -- 2. Death in the middle of stripping.
    local m2 = started(1, "strip_plate")
    SFW.kill(1)
    local c2 = SFW.finish(1, "craft_strip_plate", 20, m2)
    MH.run(1)
    MH.players[1].alive = true
    MH.run(1)
    local after2 = { scrap = pockets(T, "scrap_metal"), plates = tray("tch_alloy_plate") }
    -- 3. A real strip, then a clock-out in the middle of the assembly (the epoch event ends it).
    TW.craft(1, "strip_plate")
    TW.craft(1, "strip_plate")
    local plates0 = tray("tch_alloy_plate")
    local m3 = started(1, "assemble_magazine")
    SFW.command("techie.lab.clock", { "1", "off" })
    local c3 = SFW.finish(1, "craft_assemble_magazine", 20, m3)
    MH.run(1)
    local after3 = { plates = tray("tch_alloy_plate"), mags = pockets(T, "tch_mod_magazine"), free = TW.nothingHeld(TRAY) }
    SFW.command("techie.lab.clock", { "1", "on" })
    MH.run(2)
    -- 4. Walking away before the end: refused at the end-of-time check, nothing moves.
    local m4 = started(1, "assemble_magazine")
    SFW.move(1, { x = -1250.0, y = 2010.0, z = 12.0 })
    local c4 = SFW.finish(1, "craft_assemble_magazine", 30, m4)
    MH.run(1)
    local after4 = { plates = tray("tch_alloy_plate"), mags = pockets(T, "tch_mod_magazine"), free = TW.nothingHeld(TRAY) }
    SFW.move(1, TW.WORKBENCH)
    -- 5. rp_techie restarts in the middle of an assembly: the action ends, the hold is released.
    local m5 = started(1, "assemble_magazine")
    MH.stop("rp_techie")
    MH.run(2)
    local c5 = SFW.finish(1, "craft_assemble_magazine", 20, m5)
    TW.startTechie()
    MH.until_(function() return svc() and svc().ready end, 60)
    MH.run(2)
    local after5 = { plates = tray("tch_alloy_plate"), mags = pockets(T, "tch_mod_magazine"), free = TW.nothingHeld(TRAY) }
    -- The work goes on after the restart.
    local done = TW.craft(1, "assemble_magazine")
    local ok, detail = TW.conserved({ "char:" .. T })
    return TW.result({
        held_during = heldDuring, c1 = c1 and c1.state, c1_reason = c1 and c1.reason, scrap1 = after1.scrap,
        plates1 = after1.plates, free1 = after1.free,
        c2 = c2 and c2.state, c2_reason = c2 and c2.reason, scrap2 = after2.scrap, plates2 = after2.plates,
        plates0 = plates0, c3 = c3 and c3.state, c3_reason = c3 and c3.reason, plates3 = after3.plates, mags3 = after3.mags,
        free3 = after3.free,
        c4 = c4 and c4.state, c4_reason = c4 and c4.reason, plates4 = after4.plates, mags4 = after4.mags, free4 = after4.free,
        c5 = c5 and c5.state, c5_reason = c5 and c5.reason, plates5 = after5.plates, mags5 = after5.mags, free5 = after5.free,
        done = done and done.state, mags_end = pockets(T, "tch_mod_magazine"), plates_end = tray("tch_alloy_plate"),
        conserved = ok, conservation = detail, unbalanced = tostring(SFW.unbalanced()),
    })
end

-- ---------------------------------------------------------------------------------------------
-- Disconnects: the techie leaves in the middle of a stage (released, nothing used) and comes back
-- to the same pockets and tray; a buyer leaves while an offer waits (dropped, nothing paid).
-- ---------------------------------------------------------------------------------------------
function scenarios.disconnects()
    TW.boot()
    SFW.join(1, T, "Tech", TW.WORKBENCH)
    SFW.join(3, B, "Buyer", TW.BESIDE_WORKBENCH)
    TW.setup(1, 0)
    TW.give(1, "scrap_metal", 3)
    TW.give(1, "tch_mod_suppressor", 1)
    local m1 = started(1, "strip_plate")
    MH.disconnect(1)
    local c1 = SFW.finish(1, "craft_strip_plate", 20, m1)
    MH.run(2)
    local after1 = { scrap = pockets(T, "scrap_metal"), plates = tray("tch_alloy_plate"), free = TW.nothingHeld("char:" .. T) }
    SFW.join(1, T, "Tech", TW.WORKBENCH)
    TW.setup(1, 0)
    local again = TW.craft(1, "strip_plate")
    local plates = tray("tch_alloy_plate")
    local cashB = cash(B)
    MH.command("techie", 1, { "sell", "3", "tch_mod_suppressor", "1", "300" })
    MH.run(1)
    local offered = TW.offerOf(1) ~= nil
    MH.disconnect(3)
    MH.until_(function() return next(svc().offers) == nil end, 20)
    MH.run(1)
    local ok, detail = TW.conserved({ "char:" .. T, "char:" .. B })
    return TW.result({
        c1 = c1 and c1.state, c1_reason = c1 and c1.reason, scrap1 = after1.scrap, plates1 = after1.plates,
        free1 = after1.free, again = again and again.state, plates = plates,
        offered = offered, offer_gone = next(svc().offers) == nil, kit_kept = pockets(T, "tch_mod_suppressor"),
        buyer_cash_kept = cash(B) == cashB, told_gone = TW.told(1, "other player left"),
        promised_left = next(svc().promised) == nil,
        conserved = ok, conservation = detail, unbalanced = tostring(SFW.unbalanced()),
    })
end

-- ---------------------------------------------------------------------------------------------
-- A full server restart between the two stages: the components wait on the tray (a stash), the
-- assembly finishes after the restart; an offer open at the restart is forgotten, nothing paid.
-- ---------------------------------------------------------------------------------------------
function scenarios.restart_between_stages()
    TW.boot()
    SFW.join(1, T, "Tech", TW.WORKBENCH)
    SFW.join(3, B, "Buyer", TW.BESIDE_WORKBENCH)
    TW.setup(1, 0)
    TW.give(1, "scrap_metal", 3)
    TW.give(1, "copper_wire", 2)
    TW.give(1, "tch_mod_magazine", 1)
    TW.craft(1, "strip_plate")
    TW.craft(1, "strip_wire")
    MH.command("techie", 1, { "sell", "3", "tch_mod_magazine", "1", "200" })
    MH.run(1)
    local offered = TW.offerOf(1) ~= nil
    local before = { plates = tray("tch_alloy_plate"), looms = tray("tch_wire_loom"), cashB = cash(B),
        mags = pockets(T, "tch_mod_magazine") }
    local keep = TW.keep()
    TW.boot({ keep = keep })
    SFW.join(1, T, "Tech", TW.WORKBENCH)
    SFW.join(3, B, "Buyer", TW.BESIDE_WORKBENCH)
    TW.setup(1, 0)
    local after = { plates = tray("tch_alloy_plate"), looms = tray("tch_wire_loom"), cashB = cash(B),
        mags = pockets(T, "tch_mod_magazine"), offers = next(svc().offers) == nil }
    local a1 = TW.craft(1, "assemble_suppressor")
    local ok, detail = TW.conserved({ "char:" .. T, "char:" .. B })
    return TW.result({
        offered = offered, before_plates = before.plates, before_looms = before.looms,
        same = after.plates == before.plates and after.looms == before.looms and after.cashB == before.cashB
            and after.mags == before.mags,
        offers_forgotten = after.offers, a1 = a1 and a1.state, kits = pockets(T, "tch_mod_suppressor"),
        plates_end = tray("tch_alloy_plate"), looms_end = tray("tch_wire_loom"),
        conserved = ok, conservation = detail, unbalanced = tostring(SFW.unbalanced()),
    })
end

-- ---------------------------------------------------------------------------------------------
-- Crash windows of a stage commit (inputs burned + outputs minted in one operation).
-- ---------------------------------------------------------------------------------------------
local function stripWithFault(pid, fault)
    local mark = SFW.mark()
    SFW.intent(pid, "rp_techie:craft_strip_plate", TW.KNEEL_T)
    SFW.waitState(pid, "craft_strip_plate", mark, "presenting", 15)
    SFW.store().faults = { fault }
    return SFW.finish(pid, "craft_strip_plate", 40, mark)
end

local function stripWithCrash(pid, mode)
    local mark = SFW.mark()
    SFW.intent(pid, "rp_techie:craft_strip_plate", TW.KNEEL_T)
    SFW.waitState(pid, "craft_strip_plate", mark, "presenting", 15)
    MH.shared.txPaused = true
    SFW.waitState(pid, "craft_strip_plate", mark, "committing", 15)
    MH.until_(function() return SFW.store():pending() > 0 end, 10)
    MH.shared.txOnStop = mode
    MH.stop("open77_transactions")
    local op = SFW.finish(pid, "craft_strip_plate", 40, mark)
    MH.shared.txPaused = false
    MH.shared.txOnStop = nil
    SFW.startCoordinator()
    MH.run(12)
    return op
end

-- Committed strips agree with the ledger: plates minted = 2 x strips, scrap burned = 3 x strips.
local function tally(seeded)
    local strips = 0
    for _, row in pairs(SFW.store().ops) do
        if row.state == "committed" and row.kind == "techie.strip" then strips = strips + 1 end
    end
    local minted = -SFW.journal("^sys:techie%.workshop$", "tch_alloy_plate")
    local burned = SFW.journal("^sys:techie%.workshop$", "scrap_metal")
    local onTray = tray("tch_alloy_plate")
    local inPockets = pockets(T, "scrap_metal")
    return { strips = strips, agree = minted == 2 * strips and burned == 3 * strips and onTray == minted
        and inPockets + burned == seeded }
end

function scenarios.crash_windows()
    TW.boot()
    SFW.join(1, T, "Tech", TW.WORKBENCH)
    TW.setup(1, 0)
    TW.give(1, "scrap_metal", 15)
    local seeded = pockets(T, "scrap_metal")
    local o1 = stripWithFault(1, "unreachable_before")
    MH.run(6)
    local t1 = tally(seeded)
    local o2 = stripWithFault(1, "lost_ack")
    MH.run(6)
    local t2 = tally(seeded)
    local o3 = stripWithCrash(1, "detached")
    local t3 = tally(seeded)
    local doubts = 0
    for _ in pairs(svc().doubts) do doubts = doubts + 1 end
    local o4 = stripWithCrash(1, "discard")
    local t4 = tally(seeded)
    local events = #TW.jobEvents("strip", 1)
    return TW.result({
        o1 = o1 and o1.state, o1_reason = o1 and o1.reason, t1 = t1.strips, t1_agree = t1.agree,
        o2 = o2 and o2.state, t2 = t2.strips, t2_agree = t2.agree,
        o3 = o3 and o3.state, t3 = t3.strips, t3_agree = t3.agree, doubts_left = doubts,
        o4 = o4 and o4.state, t4 = t4.strips, t4_agree = t4.agree,
        strip_events = events,
        unbalanced = tostring(SFW.unbalanced()),
    })
end

-- ---------------------------------------------------------------------------------------------
-- Shop payment modes: without an rp_economy budget the sale is refused and told; the ledger mode
-- pays through the coordinator; an rp_economy sale in doubt is followed by the sweep and paid once.
-- ---------------------------------------------------------------------------------------------
function scenarios.shop_modes()
    -- 1. No rp_economy mint budget for rp_techie: refused, the kit stays, the techie is told.
    TW.boot({ noEconomyBudget = true })
    SFW.join(1, T, "Tech", TW.GUNSHOP)
    TW.setup(1, 0)
    TW.give(1, "tch_mod_suppressor", 1)
    local r1 = TW.sellShop(1, "gunshop")
    local told1 = TW.told(1, "operator: rp_economy mint budget")
    local kits1 = pockets(T, "tch_mod_suppressor")
    -- 2. Ledger mode: the coordinator pays out of sys:techie.shop.
    TW.boot({ shopPayment = "ledger", writers = TW.WRITERS_STRICT:gsub("rp_techie:stash/tray%+char%+cash",
        "rp_techie:stash/tray+char+cash+soc") })
    SFW.join(1, T, "Tech", TW.MEDPOINT)
    TW.setup(1, 0)
    TW.give(1, "tch_cw_servo", 2)
    local cash2, soc2 = cash(T), SFW.balance("soc:techie")
    local r2 = TW.sellShop(1, "medpoint")
    local ledger = { servos = pockets(T, "tch_cw_servo"), paid = cash(T) - cash2, society = SFW.balance("soc:techie") - soc2,
        minted = -SFW.journal("^sys:techie%.shop$", "money"), burned = SFW.journal("^sys:techie%.shop$", "tch_cw_servo") }
    -- 3. rp_economy answers in_doubt while the sale lands: the action ends in doubt, the sweep
    --    follows the sale through rp_economy:status and finishes it once.
    TW.boot()
    SFW.join(1, T, "Tech", TW.GUNSHOP)
    TW.setup(1, 0)
    TW.give(1, "tch_mod_magazine", 2)
    local ports = svc().P
    local realSale = ports.economy.sale
    local calls = 0
    ports.economy.sale = function(spec)
        calls = calls + 1
        realSale(spec)
        return nil, "in_doubt", { retryable = true, opId = spec.opId }
    end
    local cash3 = cash(T)
    local r3 = TW.sellShop(1, "gunshop")
    local waited = next(svc().sales) ~= nil
    MH.until_(function() return svc().stats.shopSales >= 1 end, 30)
    MH.run(4)
    ports.economy.sale = realSale
    local sells = TW.jobEvents("sell", 1)
    return TW.result({
        r1 = r1 and r1.state, r1_reason = r1 and r1.reason, told1 = told1, kits1 = kits1,
        r2 = r2 and r2.state, servos = ledger.servos, paid2 = ledger.paid, society2 = ledger.society,
        minted2 = ledger.minted, burned2 = ledger.burned,
        r3 = r3 and r3.state, r3_reason = r3 and r3.reason, waited = waited, calls = calls,
        paid3 = cash(T) - cash3, mags3 = pockets(T, "tch_mod_magazine"), shop_sales = svc().stats.shopSales,
        sell_events = #sells,
        unbalanced = tostring(SFW.unbalanced()),
    })
end

-- ---------------------------------------------------------------------------------------------
-- The bench menu: E opens the bench's recipes (open77_uikit context); the pick is requested as its
-- own action at that bench. Without open77_uikit the recipes come as one chat line.
-- ---------------------------------------------------------------------------------------------
function scenarios.menu()
    TW.boot()
    SFW.join(1, T, "Tech", TW.WORKBENCH)
    TW.setup(1, 1)
    TW.give(1, "scrap_metal", 3)
    MH.shared.uikitAnswer = { ok = true, outcome = "ok", value = { id = "strip_plate", menu = "rp_techie_bench" } }
    local mark = SFW.mark()
    SFW.intent(1, "rp_techie:bench_menu", TW.KNEEL_T)
    local menuOp = SFW.finish(1, "bench_menu", 10, mark)
    local crafted = SFW.finish(1, "craft_strip_plate", 40, mark)
    local menu1 = MH.shared.menus[1]
    local ids, missingSuppressor = {}, false
    for _, o in ipairs(menu1 and menu1.def.options or {}) do
        ids[#ids + 1] = o.id
        if o.id == "assemble_suppressor" and tostring(o.description):find("Missing") then missingSuppressor = true end
    end
    -- The electronics bench lists its own four recipes; a cancelled menu starts nothing.
    SFW.move(1, TW.ELECTRONICS)
    MH.shared.uikitAnswer = nil
    local mark2 = SFW.mark()
    SFW.intent(1, "rp_techie:bench_menu", TW.STAND_T)
    SFW.finish(1, "bench_menu", 10, mark2)
    MH.run(2)
    local menu2 = MH.shared.menus[2]
    local ids2 = {}
    for _, o in ipairs(menu2 and menu2.def.options or {}) do ids2[#ids2 + 1] = o.id end
    local nothingStarted = true
    for i = mark2 + 1, #MH.shared.transitions do
        if MH.shared.transitions[i].actionId ~= "bench_menu" then nothingStarted = false end
    end
    -- /techie craft at the bench.
    SFW.move(1, TW.WORKBENCH)
    local mark3 = SFW.mark()
    TW.give(1, "copper_wire", 2)
    MH.command("techie", 1, { "craft", "strip_wire" })
    local byCommand = SFW.finish(1, "craft_strip_wire", 40, mark3)
    -- Without open77_uikit: one chat line.
    TW.boot({ noUikit = true })
    SFW.join(1, T, "Tech", TW.WORKBENCH)
    TW.setup(1, 0)
    SFW.act(1, "rp_techie:bench_menu", TW.KNEEL_T, "bench_menu", 10)
    MH.run(2)
    return TW.result({
        menu_op = menuOp and menuOp.state, crafted = crafted and crafted.state, ids = table.concat(ids, ","),
        missing_suppressor = missingSuppressor, menu_title = menu1 and menu1.def.title or "",
        menu_tray = menu1 and menu1.def.description or "",
        ids2 = table.concat(ids2, ","), nothing_started = nothingStarted,
        by_command = byCommand and byCommand.state,
        chat_list = TW.told(1, "Use /techie craft <recipe>"),
        unbalanced = tostring(SFW.unbalanced()),
    })
end

-- ---------------------------------------------------------------------------------------------
-- The integrator's console drives the whole loop with explicit player ids.
-- ---------------------------------------------------------------------------------------------
function scenarios.lab_console()
    TW.boot()
    SFW.join(1, T, "Tech", TW.WORKBENCH)
    SFW.join(3, B, "Buyer", TW.BESIDE_WORKBENCH)
    SFW.command("techie.lab.setup", { "1", "2" })
    MH.run(1)
    SFW.command("techie.lab.give", { "1", "scrap_metal", "6" })
    SFW.command("techie.lab.give", { "1", "copper_wire", "4" })
    SFW.command("techie.lab.give", { "1", "chip", "1" })
    MH.run(3)
    local mark = SFW.mark()
    SFW.command("techie.lab.craft", { "1", "strip_plate" })
    local s1 = SFW.finish(1, "craft_strip_plate", 40, mark)
    local mark2 = SFW.mark()
    SFW.command("techie.lab.craft", { "1", "strip_wire" })
    local s2 = SFW.finish(1, "craft_strip_wire", 40, mark2)
    SFW.move(1, TW.ELECTRONICS)
    local mark3 = SFW.mark()
    SFW.command("techie.lab.craft", { "1", "strip_chip" })
    local s3 = SFW.finish(1, "craft_strip_chip", 40, mark3)
    SFW.move(1, TW.WORKBENCH)
    local mark4 = SFW.mark()
    SFW.command("techie.lab.craft", { "1", "assemble_sight" })
    local a1 = SFW.finish(1, "craft_assemble_sight", 40, mark4)
    SFW.move(1, TW.DEALER)
    local mark5 = SFW.mark()
    SFW.command("techie.lab.buy", { "1", "scrap_metal" })
    local b1 = SFW.finish(1, "buy_kabuki_west_scrap_metal", 20, mark5)
    SFW.move(1, TW.BESIDE_WORKBENCH)
    SFW.move(3, TW.NEAR_WORKBENCH)
    SFW.command("techie.lab.offer", { "1", "3", "tch_mod_sight", "1", "500" })
    MH.run(2)
    local op = TW.answer(3, true)
    SFW.move(1, TW.GUNSHOP)
    TW.give(1, "tch_mod_magazine", 1)
    local mark6 = SFW.mark()
    SFW.command("techie.lab.shop", { "1", "gunshop" })
    local sh = SFW.finish(1, "sell_gunshop", 20, mark6)
    SFW.command("techie.lab.state", { "1" })
    SFW.command("techie.lab.tray", { "kabuki_west" })
    SFW.command("techie.status", {})
    SFW.command("techie.mintrules", {})
    MH.run(3)
    SFW.command("techie.lab.clock", { "1", "off" })
    MH.run(1)
    return TW.result({
        s1 = s1 and s1.state, s2 = s2 and s2.state, s3 = s3 and s3.state, a1 = a1 and a1.state, b1 = b1 and b1.state,
        sold = op ~= nil and svc().done[op] ~= nil, shop = sh and sh.state, sights_b = pockets(B, "tch_mod_sight"),
        state_line = TW.printed("player 1 subject acct%-t pockets="), receipt_line = TW.printed("receipt strip tch%.strip:"),
        tray_line = TW.printed("workshop kabuki_west tray stash:tch%.kabuki_west:tray"),
        bench_line = TW.printed("bench kabuki_west_kneel Workbench %(workbench%) at %-1238%.890,1998%.180,12%.010 yaw 155%.00"),
        status_line = TW.printed("ready=true targets=5 shopPayment=economy"),
        mint_line = TW.printed("tunable%.set open77_transactions mint3 rp_techie sys:techie%.workshop tch_alloy_plate 400; "),
        mint_last = TW.printed("tunable%.set open77_transactions mint5 [^\n]*rp_techie sys:techie%.dealer chip 40$"),
        mint_longest = (function()
            local longest = 0
            for _, line in ipairs(MH.logs) do
                local value = line:match("^%[rp_techie%] tunable%.set open77_transactions mint%d (.+)$")
                if value and #value > longest then longest = #value end
            end
            return longest
        end)(),
        clock_line = TW.printed("duty 1 off: true"),
        unbalanced = tostring(SFW.unbalanced()),
    })
end

-- ---------------------------------------------------------------------------------------------
-- Exports for the ripperdoc job, and who defines the salvage parts.
-- ---------------------------------------------------------------------------------------------
function scenarios.catalogue_and_parts()
    TW.boot()
    local comps = SFW.sync("rp_ripperdoc", "rp_techie", "components")
    local ids = {}
    for _, c in ipairs(type(comps) == "table" and comps or {}) do ids[#ids + 1] = c.id .. ":" .. tostring(c.shopPrice) end
    local isComp = SFW.sync("rp_ripperdoc", "rp_techie", "isComponent", "tch_cw_servo")
    local notComp = SFW.sync("rp_ripperdoc", "rp_techie", "isComponent", "tch_mod_sight")
    local cat = SFW.sync("rp_ripperdoc", "rp_techie", "catalogue")
    local defScrap = SFW.sync("tch_probe", "rp_inventory", "itemDefinition", "scrap_metal")
    local definedHere = svc().partsDefinedHere.scrap_metal == true
    -- With rp_salvage running, it owns the parts and rp_techie leaves them alone.
    TW.boot({ salvage = true })
    local defScrap2 = SFW.sync("tch_probe", "rp_inventory", "itemDefinition", "scrap_metal")
    local definedHere2 = next(svc().partsDefinedHere) ~= nil
    -- The job unknown to rp_jobs: a warning at boot, every bench refuses.
    TW.boot({ knownJobs = { ferrailleur = true } })
    local warned = TW.printed("rp_jobs does not know the job 'techie'")
    -- Running under another job (the convar).
    TW.boot({ job = "ferrailleur" })
    SFW.join(1, T, "Tech", TW.WORKBENCH)
    TW.setup(1, 0)
    TW.give(1, "scrap_metal", 3)
    local underOther = TW.craft(1, "strip_plate")
    local jobEvent = TW.jobEvents("strip", 1)[1]
    return TW.result({
        components = table.concat(ids, ","), is_comp = tostring(isComp), not_comp = tostring(notComp),
        recipes = type(cat) == "table" and #cat.recipes or 0, products = type(cat) == "table" and #cat.products or 0,
        parts = type(cat) == "table" and #cat.parts or 0,
        scrap_by = type(defScrap) == "table" and defScrap.definedBy or "nil", defined_here = definedHere,
        scrap_by2 = type(defScrap2) == "table" and defScrap2.definedBy or "nil", defined_here2 = definedHere2,
        warned = warned, under_other = underOther and underOther.state,
        event_job = jobEvent and jobEvent.job or "",
        unbalanced = tostring(SFW.unbalanced()),
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
