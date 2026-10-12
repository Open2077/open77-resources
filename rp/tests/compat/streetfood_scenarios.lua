-- tests/compat/streetfood_scenarios.lua: the C4 street-food stall (rp_streetfood) end to end, offline.
--
-- Loaded by tests/test_c4_streetfood.py after fakehost.lua (unused here) with the string globals
-- ROOT_DIR, COMPAT_DIR, SYS_DIR and TX_DIR (streetfood_world.lua). Players act the way the
-- open77_actions client and the platform's interaction UI make them act: prompt intents from their
-- own seat, chat commands, and the invitation answer. Every check reads durable truth from the
-- coordinator's store.

dofile(COMPAT_DIR .. "/streetfood_world.lua")

local scenarios = {}

local A, B, C = "acct-a", "acct-b", "acct-c"
-- Catalogue anchors (rp_streetfood/server/config.lua): the cook stands on the grill anchor, the
-- customer on the counter anchor 1.45 m in front of it.
local GRILL = { x = -397.617, y = 715.138, z = 115.0 }
local COUNTER = { x = -398.887, y = 715.848, z = 115.0 }
local BESIDE = { x = -397.0, y = 714.0, z = 115.0 }        -- a second cook, 1.29 m from the grill
local NEAR_SEAT1 = { x = -402.6, y = 714.7, z = 115.0 }     -- 0.62 m from seat 1 (A1 #5)
local PANTRY, PASS = "stash:sf.food_court:pantry", "stash:sf.food_court:pass"
local GRILL_T, COUNTER_T = "rp_streetfood:food_court_grill", "rp_streetfood:food_court_counter"
local INGREDIENTS = { "sf_synth_meat", "sf_bun", "sf_sauce", "sf_soda" }
local DISHES = { "sf_skewer", "sf_burger" }

local function svc() return SFW.stall() end

local function setup(cookPid)
    SFW.command("streetfood.lab.setup", { tostring(cookPid) })
    MH.run(1)
end

local function seed(times)
    SFW.command("streetfood.lab.seed", { "food_court", tostring(times or 1) })
    MH.run(3)
end

local function cook(pid, recipe) return SFW.act(pid, "rp_streetfood:cook_" .. recipe, GRILL_T, "cook_" .. recipe, 40) end
local function order(pid, dish) return SFW.act(pid, "rp_streetfood:order_" .. dish, COUNTER_T, "order_" .. dish, 20) end
local function serve(pid) return SFW.act(pid, "rp_streetfood:serve", GRILL_T, "serve", 20) end

-- The cook's open offer: its platform id and the sale op id rp_streetfood minted for it.
local function openOffer(cookPid)
    local id = SFW.offerOf(cookPid)
    local o = id and svc().offers[id]
    return id, o and o.opId, o
end

-- The customer answers the invitation; runs until the sale settled (or the offer was dropped).
local function answer(cookPid, accepted, seconds)
    local id, opId = openOffer(cookPid)
    if not id then return nil end
    local dropped0 = svc().stats.dropped
    SFW.respond(id, accepted)
    MH.until_(function()
        local s = svc()
        return s and ((opId and s.done[opId] ~= nil) or s.stats.dropped > dropped0)
    end, seconds or 40)
    MH.run(1)
    return opId
end

local function countsOf(account, items)
    local out = {}
    for _, item in ipairs(items) do out[item] = SFW.count(account, item) end
    return out
end

-- Ingredients: what the supplier minted + what was stocked from pockets = pantry + burned + sold
-- (resold stock leaves the pantry through a sale). Dishes: minted from the kitchen = pass +
-- every pocket + eaten.
local function conserved(pockets)
    local problems = {}
    for _, item in ipairs(INGREDIENTS) do
        local minted = -SFW.journal("^sys:streetfood%.supplier$", item)      -- restocks
        local labGiven = -SFW.journal("^sys:rp_streetfood$", item)           -- lab gifts into pockets
        local burned = SFW.journal("^sys:streetfood%.kitchen$", item)        -- cooked
        local eaten = SFW.journal("^sys:streetfood%.eaten$", item)           -- drunk (resold stock)
        local inPockets = 0
        for _, acct in ipairs(pockets) do inPockets = inPockets + SFW.count(acct, item) end
        local left = SFW.count(PANTRY, item)
        -- supplier + lab gifts = pantry + burned + in pockets + eaten (stocking and resale move
        -- between pockets and pantry and are counted on both sides)
        if minted + labGiven ~= left + burned + inPockets + eaten then
            problems[#problems + 1] = ("%s minted=%d given=%d pantry=%d burned=%d pockets=%d eaten=%d"):format(item,
                minted, labGiven, left, burned, inPockets, eaten)
        end
    end
    for _, item in ipairs(DISHES) do
        local minted = -SFW.journal("^sys:streetfood%.kitchen$", item) - SFW.journal("^sys:probe$", item)
        local inPockets = 0
        for _, acct in ipairs(pockets) do inPockets = inPockets + SFW.count(acct, item) end
        local eaten = SFW.journal("^sys:streetfood%.eaten$", item)
        local onPass = SFW.count(PASS, item)
        if minted ~= onPass + inPockets + eaten then
            problems[#problems + 1] = ("%s minted=%d pass=%d pockets=%d eaten=%d"):format(item, minted, onPass, inPockets, eaten)
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

-- ---------------------------------------------------------------------------------------------
-- Happy path: cook a skewer, the customer orders (with a tip), the cook hands it over with
-- consent, ONE sale pays the society and the tip, the customer eats at the counter (needs once);
-- then a soda from the pantry with the hand item following the portion, drunk on the go; then the
-- cook stocks the pantry from their pockets. Strict writers: the sale works through the grant.
-- ---------------------------------------------------------------------------------------------
function scenarios.happy_path()
    SFW.boot({ writers = SFW.WRITERS_STRICT })
    SFW.join(1, A, "Cook", GRILL)
    SFW.join(2, B, "Client", COUNTER)
    setup(1)
    seed(1)
    local seeded = countsOf(PANTRY, INGREDIENTS)
    local cash0, cook0 = SFW.balance("cash:" .. B), SFW.balance("cash:" .. A)
    local c1 = cook(1, "skewer")
    local afterCook = countsOf(PANTRY, INGREDIENTS)
    local passAfterCook = SFW.count(PASS, "sf_skewer")
    MH.command("streetfood", 2, { "tip", "2" })
    MH.run(0.5)
    local o1 = order(2, "skewer")
    local ticket = svc().tickets.food_court and svc().tickets.food_court[B]
    local s1 = serve(1)
    local _, opId1 = openOffer(1)
    local toldPrice = SFW.told(2, "18 eddies %+ tip 2 eddies = 20 eddies")
    answer(1, true)
    local paid = cash0 - SFW.balance("cash:" .. B)
    local soc = SFW.balance("soc:cook")
    local tipped = SFW.balance("cash:" .. A) - cook0
    local skewerInPockets = SFW.count("char:" .. B, "sf_skewer")
    local passAfterSale = SFW.count(PASS, "sf_skewer")
    local ticketGone = svc().tickets.food_court[B] == nil
    -- Eat at the counter (the market-grill customer pose at the counter anchor).
    local e1 = SFW.act(2, "rp_streetfood:eat_counter", COUNTER_T, "eat_counter", 40)
    local skewerAfterMeal = SFW.count("char:" .. B, "sf_skewer")
    local needs1 = MH.shared.needs[1]
    -- Soda: resold from the pantry; the can is in the cook's hand while offered, then in the
    -- customer's; drunk on the go with that can.
    order(2, "soda")
    serve(1)
    local cookHeldDuringOffer = SFW.held(1)
    answer(1, true)
    local customerHeld, cookHeldAfter = SFW.held(2), SFW.held(1)
    local mark = SFW.mark()
    MH.command("streetfood", 2, { "drink" })
    local d1 = SFW.finish(2, "drink_go", 40, mark)
    local drink = played(2, "drink_walk")
    local heldAfterDrink = SFW.held(2)
    -- Stocking: two buns from the cook's pockets into the pantry (one rp_inventory moveAsync).
    SFW.command("streetfood.lab.give", { "1", "sf_bun", "2" })
    MH.run(3)
    local bunsBefore = SFW.count(PANTRY, "sf_bun")
    local st1 = SFW.act(1, "rp_streetfood:stock", GRILL_T, "stock", 20)
    local bunsAfter = SFW.count(PANTRY, "sf_bun")
    local cookAt = played(1, "amb_704dff_cook", "playAt")
    local eatAt = played(2, "amb_fd31d1_stand_market_grill", "playAt")
    local ok, detail = conserved({ "char:" .. A, "char:" .. B })
    return SFW.result({
        cook = c1 and c1.state, seeded_meat = seeded.sf_synth_meat,
        meat_used = seeded.sf_synth_meat - afterCook.sf_synth_meat, sauce_used = seeded.sf_sauce - afterCook.sf_sauce,
        bun_untouched = seeded.sf_bun == afterCook.sf_bun, pass_after_cook = passAfterCook,
        order = o1 and o1.state, ticket_tip = ticket and ticket.tip, serve = s1 and s1.state,
        sale_op = opId1 ~= nil, told_price = toldPrice,
        paid = paid, society = soc, tipped = tipped, skewer_in_pockets = skewerInPockets,
        pass_after_sale = passAfterSale, ticket_gone = ticketGone,
        eat = e1 and e1.state, skewer_after_meal = skewerAfterMeal,
        needs_hunger = needs1 and needs1.delta and needs1.delta.hunger, needs_count = #MH.shared.needs,
        consumed_events = #MH.shared.consumed, sold_events = #MH.shared.sold,
        cook_held_offer = tostring(cookHeldDuringOffer), customer_held = tostring(customerHeld),
        cook_held_after = tostring(cookHeldAfter), drink = d1 and d1.state,
        drink_with_can = drink ~= nil and drink.held == "Items.crowd_soda_can_a",
        held_after_drink = tostring(heldAfterDrink), soda_left = SFW.count(PANTRY, "sf_soda"),
        soda_society = SFW.balance("soc:cook") - soc,
        stock = st1 and st1.state, buns_stocked = bunsAfter - bunsBefore, cook_buns = SFW.count("char:" .. A, "sf_bun"),
        cook_at_grill = cookAt ~= nil and math.abs(cookAt.yaw - 64.0) < 1e-6 and math.abs(cookAt.position.x - GRILL.x) < 1e-6,
        eat_at_counter = eatAt ~= nil and math.abs(eatAt.position.y - COUNTER.y) < 1e-6,
        order_gesture = played(2, "order", "play") ~= nil,
        conserved = ok, conservation = detail, unbalanced = tostring(SFW.unbalanced()),
    })
end

-- ---------------------------------------------------------------------------------------------
-- Two cooks, one grill: the station claim lets one cook at a time; the other is refused holding
-- nothing. Serving and stocking do not claim the grill.
-- ---------------------------------------------------------------------------------------------
function scenarios.two_cooks_one_station()
    SFW.boot()
    SFW.join(1, A, "Cook A", GRILL)
    SFW.join(3, C, "Cook C", BESIDE)
    setup(1)
    setup(3)
    seed(1)
    local before = countsOf(PANTRY, INGREDIENTS)
    local mark = SFW.mark()
    SFW.intent(1, "rp_streetfood:cook_skewer", GRILL_T)
    SFW.intent(3, "rp_streetfood:cook_burger", GRILL_T)
    local a = SFW.finish(1, "cook_skewer", 40, mark)
    local cOp = SFW.finish(3, "cook_burger", 5, mark)
    -- The refusal goes to C's client through open77_actions (its client half draws "someone is
    -- already using this"): the claim is refused before any rp_streetfood hook runs.
    local refusedC = table.concat(SFW.refusals(3), ",")
    local after = countsOf(PANTRY, INGREDIENTS)
    -- While A grills again, C stocks the pantry from the same grill prompt (no claim).
    SFW.command("streetfood.lab.give", { "3", "sf_sauce", "1" })
    MH.run(2)
    local mark2 = SFW.mark()
    SFW.intent(1, "rp_streetfood:cook_skewer", GRILL_T)
    SFW.intent(3, "rp_streetfood:stock", GRILL_T)
    local a2 = SFW.finish(1, "cook_skewer", 40, mark2)
    local c2 = SFW.finish(3, "stock", 20, mark2)
    -- A cook who is not on duty is refused by the eligibility provider.
    MH.command("streetfood.lab.clock", 0, { "3", "off" })
    MH.run(1)
    local mark3 = SFW.mark()
    SFW.intent(3, "rp_streetfood:cook_burger", GRILL_T)
    MH.run(1)
    local offDuty = table.concat(SFW.refusals(3), ",")
    local ok, detail = conserved({ "char:" .. A, "char:" .. C })
    return SFW.result({
        a = a and a.state, c_op = cOp and cOp.state or "none", c_refused = refusedC,
        meat_used = before.sf_synth_meat - after.sf_synth_meat, bun_untouched = before.sf_bun == after.sf_bun,
        skewers = SFW.count(PASS, "sf_skewer"), burgers = SFW.count(PASS, "sf_burger"),
        a2 = a2 and a2.state, c2 = c2 and c2.state, off_duty = offDuty,
        conserved = ok, conservation = detail, unbalanced = tostring(SFW.unbalanced()),
    })
end

-- ---------------------------------------------------------------------------------------------
-- The customer declines; then lets the invitation time out; then the cook clocks out while the
-- offer waits (withdrawn at once); then clocks out during the hand-over itself (re-checked at
-- completion). Nothing is ever paid, the portion stays on the pass, the cook's hand is emptied.
-- ---------------------------------------------------------------------------------------------
function scenarios.customer_declines()
    SFW.boot()
    SFW.join(1, A, "Cook", GRILL)
    SFW.join(2, B, "Client", COUNTER)
    setup(1)
    seed(1)
    cook(1, "skewer")
    local cash0 = SFW.balance("cash:" .. B)
    -- 1. Decline.
    order(2, "skewer")
    serve(1)
    answer(1, false)
    local declined = { cash = SFW.balance("cash:" .. B) == cash0, pass = SFW.count(PASS, "sf_skewer"),
        ticket = svc().tickets.food_court[B] == nil, told = SFW.told(1, "declined") }
    -- 2. Soda declined: the can leaves the cook's hand.
    order(2, "soda")
    serve(1)
    local heldOffer = SFW.held(1)
    answer(1, false)
    local heldAfterDecline = SFW.held(1)
    -- 3. No answer: the invitation times out.
    order(2, "skewer")
    serve(1)
    local id3 = SFW.offerOf(1)
    MH.until_(function() return svc().offers[id3] == nil end, 40)
    MH.run(1)
    local timeout = { cash = SFW.balance("cash:" .. B) == cash0, pass = SFW.count(PASS, "sf_skewer"),
        reason = MH.shared.world.ixLog[#MH.shared.world.ixLog].reason }
    -- 4. The cook clocks out while the offer waits for consent: withdrawn at once.
    order(2, "skewer")
    serve(1)
    local id4 = SFW.offerOf(1)
    MH.command("streetfood.lab.clock", 0, { "1", "off" })
    MH.until_(function() return svc().offers[id4] == nil end, 10)
    MH.run(1)
    local withdrawnReason = MH.shared.world.ixLog[#MH.shared.world.ixLog].reason
    -- 5. Clock in again; accepted, then the cook clocks out DURING the hand-over: the completion is
    --    re-checked against the epoch captured at the offer, so nothing is sold.
    MH.command("streetfood.lab.clock", 0, { "1", "on" })
    MH.run(1)
    order(2, "skewer")
    serve(1)
    local id5, opId5 = openOffer(1)
    SFW.respond(id5, true)
    MH.run(0.5)
    -- Drive the epoch change without the event reaching the offer first: a direct duty change of
    -- the job registry, as a grade change would do, while the platform still completes.
    local J = MH.shared.jobs
    J.seq = J.seq + 1
    J.players[1].epoch = J.seq
    MH.until_(function() return svc().stats.dropped >= 5 end, 20)
    MH.run(1)
    local staleCompletion = { cash = SFW.balance("cash:" .. B) == cash0, pass = SFW.count(PASS, "sf_skewer"),
        sold = svc().done[opId5] == nil }
    local ok, detail = conserved({ "char:" .. A, "char:" .. B })
    return SFW.result({
        declined_cash = declined.cash, declined_pass = declined.pass, declined_ticket_dropped = declined.ticket,
        declined_told = declined.told, held_offer = tostring(heldOffer), held_after_decline = tostring(heldAfterDecline),
        timeout_cash = timeout.cash, timeout_pass = timeout.pass, timeout_reason = timeout.reason,
        withdrawn_reason = withdrawnReason, stale_cash = staleCompletion.cash, stale_pass = staleCompletion.pass,
        stale_not_sold = staleCompletion.sold, declined_stat = svc().stats.declined, sales = svc().stats.sales,
        promised_left = next(svc().promised) == nil,
        conserved = ok, conservation = detail, unbalanced = tostring(SFW.unbalanced()),
    })
end

-- ---------------------------------------------------------------------------------------------
-- Payment: a broke customer is refused (nothing moves, the portion stays); a paid sale replays its
-- receipt on the same request and after an rp_economy restart (paid once); a sale whose
-- acknowledgement is lost settles committed once.
-- ---------------------------------------------------------------------------------------------
function scenarios.payment()
    SFW.boot()
    SFW.join(1, A, "Cook", GRILL)
    SFW.join(2, B, "Client", COUNTER)
    setup(1)
    seed(1)
    cook(1, "burger")
    cook(1, "skewer")
    -- B gives all its cash away (one atomic pay to A): broke.
    local all = SFW.balance("cash:" .. B)
    local paidAway = MH.callAsync("sf_probe", "rp_economy", "pay",
        { opId = "test.drain.b.0001", from = { player = 2 }, to = { player = 1 }, amount = all })
    MH.run(2)
    local cashA0 = SFW.balance("cash:" .. A)
    order(2, "burger")
    serve(1)
    answer(1, true)
    local broke = { cash = SFW.balance("cash:" .. B), pass = SFW.count(PASS, "sf_burger"),
        pockets = SFW.count("char:" .. B, "sf_burger"), told = SFW.told(2, "Not enough cash"),
        ticket = svc().tickets.food_court[B] == nil }
    -- A pays B back; B buys the skewer.
    MH.callAsync("sf_probe", "rp_economy", "pay",
        { opId = "test.refill.b.0001", from = { player = 1 }, to = { player = 2 }, amount = 100 })
    MH.run(2)
    local cashB1 = SFW.balance("cash:" .. B)
    order(2, "skewer")
    serve(1)
    local _, opId, o = openOffer(1)
    answer(1, true)
    local spec = o.spec
    local cashB2 = SFW.balance("cash:" .. B)
    -- The same request again (a retry reaching the wallet twice): the stored receipt.
    local again = MH.callAsync("sf_probe", "rp_economy", "sale", spec)
    MH.run(2)
    local cashB3 = SFW.balance("cash:" .. B)
    -- rp_economy restarts (its memory gone): the coordinator answers from the operation row.
    MH.stop("rp_economy")
    SFW.startEconomy()
    MH.run(4)
    local again2 = MH.callAsync("sf_probe", "rp_economy", "sale", spec)
    MH.run(2)
    local cashB4 = SFW.balance("cash:" .. B)
    -- A lost acknowledgement on the next sale: settled committed, paid once.
    MH.until_(function() return MH.resources.rp_economy.env.Wallets.byPlayer[2] ~= nil end, 10)
    cook(1, "skewer")
    order(2, "skewer")
    serve(1)
    local _, opId6 = openOffer(1)
    local cashB5 = SFW.balance("cash:" .. B)
    SFW.store().faults = { "lost_ack" }
    answer(1, true, 60)
    local cashB6 = SFW.balance("cash:" .. B)
    -- rp_economy answers in_doubt (its 20 s wait ran out while the sale was still settling): the
    -- offer waits in `sales`, the sweep follows it through rp_economy:status and finishes it once.
    cook(1, "skewer")
    order(2, "skewer")
    serve(1)
    local id7, opId7 = openOffer(1)
    local ports = svc().P
    local realSale = ports.economy.sale
    local calls = 0
    ports.economy.sale = function(spec)
        calls = calls + 1
        realSale(spec)
        return nil, "in_doubt", { retryable = true, opId = spec.opId }
    end
    local cashB7 = SFW.balance("cash:" .. B)
    SFW.respond(id7, true)
    MH.until_(function() return svc().sales[opId7] ~= nil end, 30)
    local waitedInSales = svc().sales[opId7] ~= nil
    MH.until_(function() return svc().done[opId7] ~= nil end, 60)
    MH.run(4)
    ports.economy.sale = realSale
    local cashB8 = SFW.balance("cash:" .. B)
    local ok, detail = conserved({ "char:" .. A, "char:" .. B })
    return SFW.result({
        doubt_waited = waitedInSales, doubt_done = svc().done[opId7] ~= nil, doubt_paid = cashB7 - cashB8,
        doubt_calls = calls, sold_events = #MH.shared.sold,
        drained = paidAway ~= nil, broke_cash = broke.cash, broke_pass = broke.pass, broke_pockets = broke.pockets,
        broke_told = broke.told, broke_ticket_dropped = broke.ticket,
        paid = cashB1 - cashB2, replay1 = type(again) == "table" and tostring(again.replay) or "nil",
        replay_paid = cashB2 - cashB3, replay2 = type(again2) == "table" and tostring(again2.replay) or "nil",
        replay2_paid = cashB3 - cashB4, lost_ack_paid = cashB5 - cashB6,
        lost_ack_done = opId6 ~= nil and svc().done[opId6] ~= nil,
        skewers_bought = SFW.count("char:" .. B, "sf_skewer"), sales = svc().stats.sales,
        society = SFW.balance("soc:cook"), cook_cash_delta = SFW.balance("cash:" .. A) - cashA0,
        conserved = ok, conservation = detail, unbalanced = tostring(SFW.unbalanced()),
    })
end

-- ---------------------------------------------------------------------------------------------
-- One portion, two cooks, two customers: a portion promised to an open offer is never offered
-- twice; the order being offered is not taken by the other cook; a decline frees the portion.
-- ---------------------------------------------------------------------------------------------
function scenarios.one_portion()
    SFW.boot()
    local NEAR_COUNTER = { x = -398.5, y = 716.5, z = 115.0 }   -- 1.62 m from the grill, 2.9 m from BESIDE
    SFW.join(1, A, "Cook A", GRILL)
    SFW.join(3, C, "Cook C", BESIDE)
    SFW.join(2, B, "Client B", COUNTER)
    SFW.join(4, "acct-d", "Client D", NEAR_COUNTER)
    setup(1)
    setup(3)
    seed(1)
    cook(1, "skewer")                       -- exactly one skewer on the pass
    order(2, "skewer")
    order(4, "skewer")
    local s1 = serve(1)                     -- A offers it to B (the oldest order)
    local idB = SFW.offerOf(1)
    local s2 = serve(3)                     -- C: the only skewer is promised, B's order is in an offer
    local r2 = s2 and s2.reason
    answer(1, false)                        -- B declines: the portion is free again
    local s3 = serve(3)                     -- C offers it to D
    local idD, _, oD = openOffer(3)
    local toD = oD and oD.customer
    answer(3, true)
    local ok, detail = conserved({ "char:" .. A, "char:" .. B, "char:" .. C, "char:acct-d" })
    return SFW.result({
        s1 = s1 and s1.state, offered_b = idB ~= nil, s2 = s2 and s2.state, s2_reason = r2,
        s3 = s3 and s3.state, to_d = toD, d_skewers = SFW.count("char:acct-d", "sf_skewer"),
        b_skewers = SFW.count("char:" .. B, "sf_skewer"), pass = SFW.count(PASS, "sf_skewer"),
        sales = svc().stats.sales, promised_left = next(svc().promised) == nil,
        conserved = ok, conservation = detail, unbalanced = tostring(SFW.unbalanced()),
    })
end

-- ---------------------------------------------------------------------------------------------
-- Refusals before any bar: an empty pantry, a full pass, a customer with nothing to eat; and the
-- authorization row: a civilian at the grill, an action the target does not offer, a forged
-- hand-over completion. Nothing is held, nothing moves.
-- ---------------------------------------------------------------------------------------------
local function presented(pid, actionId, mark)
    local list = MH.shared.transitions
    for i = mark + 1, #list do
        if list[i].playerId == pid and list[i].actionId == actionId and list[i].state == "presenting" then return true end
    end
    return false
end

function scenarios.refusals()
    SFW.boot()
    SFW.join(1, A, "Cook", GRILL)
    SFW.join(2, B, "Client", COUNTER)
    setup(1)
    -- 1. Empty pantry.
    local m1 = SFW.mark()
    SFW.intent(1, "rp_streetfood:cook_skewer", GRILL_T)
    local r1 = SFW.finish(1, "cook_skewer", 20, m1)
    local told1 = SFW.told(1, "short of an ingredient")
    seed(1)
    local pantry0 = countsOf(PANTRY, INGREDIENTS)
    -- 2. The pass is full (a probe puts 8 skewers on it: 2,000 g of 2,000 g).
    local filled = MH.callAsync("sf_probe", "open77_transactions", "transfer", { opId = "test.fill.pass.0001",
        kind = "test.fill", lines = { { item = "sf_skewer", count = 8, from = "sys:probe", to = PASS } } })
    MH.run(2)
    MH.run(2)   -- past the refusal toast cooldown
    local m2 = SFW.mark()
    SFW.intent(1, "rp_streetfood:cook_burger", GRILL_T)
    local r2 = SFW.finish(1, "cook_burger", 20, m2)
    local told2 = SFW.told(1, "The pass is full")
    local pantry1 = countsOf(PANTRY, INGREDIENTS)
    local unchanged = true
    for _, item in ipairs(INGREDIENTS) do unchanged = unchanged and pantry0[item] == pantry1[item] end
    -- 3. A customer with nothing to eat or drink.
    local m3 = SFW.mark()
    MH.command("streetfood", 2, { "eat" })
    local r3 = SFW.finish(2, "eat_go", 20, m3)
    MH.run(2)
    local m4 = SFW.mark()
    MH.command("streetfood", 2, { "drink" })
    local r4 = SFW.finish(2, "drink_go", 20, m4)
    -- 4. Serving with no order waiting: refused at validation.
    local m5 = SFW.mark()
    SFW.intent(1, "rp_streetfood:serve", GRILL_T)
    MH.run(2)
    local serveRefused = table.concat(SFW.refusals(1), ",")
    -- 5. A civilian at the grill (no job): the eligibility provider refuses.
    SFW.move(2, BESIDE)
    SFW.intent(2, "rp_streetfood:cook_skewer", GRILL_T)
    MH.run(1)
    -- 6. An action the target does not offer (a forged intent: cook at the counter).
    SFW.move(2, COUNTER)
    SFW.intent(2, "rp_streetfood:cook_skewer", COUNTER_T)
    MH.run(1)
    local civilian = table.concat(SFW.refusals(2), ",")
    -- 7. A forged hand-over completion for an interaction this stall never offered.
    local salesBefore = svc().stats.sales
    MH.emit("onPlayerInteractionCompleted", { id = "0000000000000000000000000000beef", actor = "1", target = "2",
        kind = "give", phase = "completed" })
    MH.run(2)
    local ok, detail = conserved({ "char:" .. A, "char:" .. B })
    return SFW.result({
        filled = type(filled) == "table",
        r1 = r1 and r1.state, r1_reason = r1 and r1.reason, r1_stage = r1 and r1.stage,
        r1_presented = presented(1, "cook_skewer", m1), told1 = told1,
        r2 = r2 and r2.state, r2_reason = r2 and r2.reason, r2_stage = r2 and r2.stage,
        r2_presented = presented(1, "cook_burger", m2), told2 = told2, pantry_unchanged = unchanged,
        r3 = r3 and r3.state, r3_reason = r3 and r3.reason, r4 = r4 and r4.state, r4_reason = r4 and r4.reason,
        told_no_dish = SFW.told(2, "nothing of that kind"),
        serve_refused = serveRefused, told_no_order = SFW.told(1, "Order at the counter first"),
        civilian = civilian, forged_sales = svc().stats.sales - salesBefore,
        held = next(svc().promised) == nil and next(svc().work) == nil,
        conserved = ok, conservation = detail, unbalanced = tostring(SFW.unbalanced()),
    })
end

-- ---------------------------------------------------------------------------------------------
-- Crash windows of the cook commit (ingredients + dish in one operation), of a meal and of a sale.
-- ---------------------------------------------------------------------------------------------
local function cookWithFault(pid, fault)
    local mark = SFW.mark()
    SFW.intent(pid, "rp_streetfood:cook_skewer", GRILL_T)
    SFW.waitState(pid, "cook_skewer", mark, "presenting", 15)
    SFW.store().faults = { fault }
    return SFW.finish(pid, "cook_skewer", 40, mark)
end

local function crashDuring(pid, actionId, targetKey, mode)
    local mark = SFW.mark()
    SFW.intent(pid, "rp_streetfood:" .. actionId, targetKey)
    SFW.waitState(pid, actionId, mark, "presenting", 15)
    MH.shared.txPaused = true
    SFW.waitState(pid, actionId, mark, "committing", 15)
    MH.until_(function() return SFW.store():pending() > 0 end, 10)
    MH.shared.txOnStop = mode
    MH.stop("open77_transactions")
    local op = SFW.finish(pid, actionId, 40, mark)
    MH.shared.txPaused = false
    MH.shared.txOnStop = nil
    SFW.startCoordinator()
    MH.run(12)        -- the coordinator boots, rp_streetfood's sweep settles the doubt
    return op
end

local function cookWithCrash(pid, mode) return crashDuring(pid, "cook_skewer", GRILL_T, mode) end

-- Committed cooks agree with the ledger: skewers minted = cooks, meat burned = 2 x cooks.
local function tally()
    local cooks = 0
    for _, row in pairs(SFW.store().ops) do
        if row.state == "committed" and row.kind == "streetfood.cook" then cooks = cooks + 1 end
    end
    local minted = -SFW.journal("^sys:streetfood%.kitchen$", "sf_skewer")
    local meat = SFW.journal("^sys:streetfood%.kitchen$", "sf_synth_meat")
    return { cooks = cooks, minted = minted, meat = meat, pass = SFW.count(PASS, "sf_skewer"),
        pantryMeat = SFW.count(PANTRY, "sf_synth_meat") }
end

local function agree(t, seeded)
    return t.minted == t.cooks and t.meat == 2 * t.cooks and t.pass == t.cooks and t.pantryMeat + t.meat == seeded
end

function scenarios.crash_windows()
    SFW.boot()
    SFW.join(1, A, "Cook", GRILL)
    SFW.join(2, B, "Client", COUNTER)
    setup(1)
    seed(2)
    local seeded = SFW.count(PANTRY, "sf_synth_meat")
    -- 1. The store never received the commit: fenced, nothing used, no dish.
    local o1 = cookWithFault(1, "unreachable_before")
    MH.run(6)
    local t1 = tally()
    -- 2. The commit landed, the acknowledgement was lost: the fence finds it, once.
    local o2 = cookWithFault(1, "lost_ack")
    MH.run(6)
    local t2 = tally()
    -- 3. The coordinator stops with the commit queued; it still lands (detached): in doubt, settled.
    local o3 = cookWithCrash(1, "detached")
    local t3 = tally()
    local doubts3 = 0
    for _ in pairs(svc().doubts) do doubts3 = doubts3 + 1 end
    -- 4. Same, but the queued commit never reached the database (discarded): fenced, nothing.
    local o4 = cookWithCrash(1, "discard")
    local t4 = tally()
    -- 5. A meal whose acknowledgement is lost: eaten once, needs applied once.
    order(2, "skewer")
    serve(1)
    answer(1, true)
    local mark = SFW.mark()
    SFW.intent(2, "rp_streetfood:eat_counter", COUNTER_T)
    SFW.waitState(2, "eat_counter", mark, "presenting", 15)
    SFW.store().faults = { "lost_ack" }
    local meal = SFW.finish(2, "eat_counter", 60, mark)
    MH.run(6)
    local eaten = SFW.journal("^sys:streetfood%.eaten$", "sf_skewer")
    -- 5b. A meal whose commit is queued when the coordinator dies (detached): in doubt, settled
    --     committed by the sweep, the needs effect applied once.
    cook(1, "skewer")
    order(2, "skewer")
    serve(1)
    answer(1, true)
    local meal2 = crashDuring(2, "eat_counter", COUNTER_T, "detached")
    MH.run(6)
    local eaten2 = SFW.journal("^sys:streetfood%.eaten$", "sf_skewer")
    local needs2 = #MH.shared.needs
    -- 6. A sale whose commit is queued when the coordinator dies (detached): rp_economy settles it;
    --    the dish moved exactly when the money did.
    MH.until_(function() return MH.resources.rp_economy.env.Wallets.byPlayer[2] ~= nil end, 10)
    order(2, "skewer")
    serve(1)
    local id6, opId6 = openOffer(1)
    local cash6 = SFW.balance("cash:" .. B)
    local pocket6 = SFW.count("char:" .. B, "sf_skewer")
    SFW.respond(id6, true)
    MH.until_(function() return svc().offers[id6] == nil end, 20)   -- completion reached rp_streetfood
    MH.shared.txPaused = true
    MH.until_(function() return SFW.store():pending() > 0 end, 10)
    MH.shared.txOnStop = "detached"
    MH.stop("open77_transactions")
    MH.run(2)
    MH.shared.txPaused = false
    MH.shared.txOnStop = nil
    SFW.startCoordinator()
    MH.until_(function() return svc().done[opId6] ~= nil or svc().stats.dropped > 0 end, 120)
    MH.run(2)
    local paid6 = cash6 - SFW.balance("cash:" .. B)
    local moved6 = SFW.count("char:" .. B, "sf_skewer") - pocket6
    local ok, detail = conserved({ "char:" .. A, "char:" .. B })
    return SFW.result({
        o1 = o1 and o1.state, o1_reason = o1 and o1.reason, t1_cooks = t1.cooks, t1_agree = agree(t1, seeded),
        o2 = o2 and o2.state, t2_cooks = t2.cooks, t2_agree = agree(t2, seeded),
        o3 = o3 and o3.state, t3_cooks = t3.cooks, t3_agree = agree(t3, seeded), doubts_left = doubts3,
        o4 = o4 and o4.state, t4_cooks = t4.cooks, t4_agree = agree(t4, seeded),
        meal = meal and meal.state, eaten = eaten, meal2 = meal2 and meal2.state, eaten2 = eaten2,
        needs2 = needs2, consumed = #MH.shared.consumed,
        sale6_done = svc().done[opId6] ~= nil, paid6 = paid6, moved6 = moved6,
        conserved = ok, conservation = detail, unbalanced = tostring(SFW.unbalanced()),
    })
end

-- ---------------------------------------------------------------------------------------------
-- Cancellations: death mid-cook, the player's cancel key mid-cook, a vehicle mid-meal, an
-- rp_streetfood restart mid-offer; then a dish bought before a restart is still eaten after it.
-- ---------------------------------------------------------------------------------------------
function scenarios.cancellations()
    SFW.boot()
    SFW.join(1, A, "Cook", GRILL)
    SFW.join(2, B, "Client", COUNTER)
    setup(1)
    seed(1)
    local before = countsOf(PANTRY, INGREDIENTS)
    -- Death in the middle of grilling: cancelled, the reservation released, nothing used.
    local mark = SFW.mark()
    SFW.intent(1, "rp_streetfood:cook_skewer", GRILL_T)
    SFW.waitState(1, "cook_skewer", mark, "presenting", 15)
    MH.run(2)
    SFW.kill(1)
    local dead = SFW.finish(1, "cook_skewer", 20, mark)
    local afterDeath = countsOf(PANTRY, INGREDIENTS)
    MH.run(1)
    local heldAfterDeath = MH.callAsync("sf_probe", "open77_transactions", "read", PANTRY)
    MH.players[1].alive = true
    MH.run(1)
    -- The cancel key (X) on the progress bar.
    local mark2 = SFW.mark()
    SFW.intent(1, "rp_streetfood:cook_skewer", GRILL_T)
    SFW.waitState(1, "cook_skewer", mark2, "presenting", 15)
    local opId
    for i = mark2 + 1, #MH.shared.transitions do
        local op = MH.shared.transitions[i]
        if op.playerId == 1 and op.actionId == "cook_skewer" then opId = op.opId end
    end
    SFW.clientCancel(1, opId)
    local byKey = SFW.finish(1, "cook_skewer", 20, mark2)
    local afterKey = countsOf(PANTRY, INGREDIENTS)
    MH.run(1)
    local heldAfterKey = MH.callAsync("sf_probe", "open77_transactions", "read", PANTRY)
    -- A real cook, a sale, then a vehicle in the middle of the meal: the portion stays in pockets.
    cook(1, "skewer")
    order(2, "skewer")
    serve(1)
    answer(1, true)
    local mark3 = SFW.mark()
    SFW.intent(2, "rp_streetfood:eat_counter", COUNTER_T)
    SFW.waitState(2, "eat_counter", mark3, "presenting", 15)
    MH.players[2].inVehicle = true
    MH.emit("onPlayerEnteredVehicle", 2)
    local inCar = SFW.finish(2, "eat_counter", 20, mark3)
    MH.players[2].inVehicle = false
    local pocketsAfterCar = SFW.count("char:" .. B, "sf_skewer")
    -- rp_streetfood restarts while an offer waits for consent: the platform cancels the offer.
    cook(1, "skewer")
    order(2, "skewer")
    serve(1)
    local idR = SFW.offerOf(1)
    local cashR = SFW.balance("cash:" .. B)
    MH.stop("rp_streetfood")
    MH.run(1)
    local cancelledByStop = MH.shared.world.ix[idR] == nil
    SFW.startStall()
    MH.until_(function() return SFW.stall() and SFW.stall().ready end, 30)
    MH.run(1)
    local restartPass = SFW.count(PASS, "sf_skewer")
    local restartCash = SFW.balance("cash:" .. B) == cashR
    -- The skewer bought before the restart is eaten after it, on the go.
    local markGo = SFW.mark()
    MH.command("streetfood", 2, { "eat" })
    local goMeal = SFW.finish(2, "eat_go", 40, markGo)
    local takeout = played(2, "takeout", "play")
    -- No reservation outlived its operation: nothing is held in the pantry or the pockets.
    MH.run(2)
    local pantrySnap = MH.callAsync("sf_probe", "open77_transactions", "read", PANTRY)
    local pocketSnap = MH.callAsync("sf_probe", "open77_transactions", "read", "char:" .. B)
    local function heldNone(snap)
        return type(snap) == "table" and type(snap.held) == "table" and next(snap.held.items or {}) == nil
    end
    local ok, detail = conserved({ "char:" .. A, "char:" .. B })
    return SFW.result({
        dead = dead and dead.state, dead_reason = dead and dead.reason,
        death_kept = afterDeath.sf_synth_meat == before.sf_synth_meat and afterDeath.sf_sauce == before.sf_sauce,
        by_key = byKey and byKey.state, by_key_reason = byKey and byKey.reason,
        key_kept = afterKey.sf_synth_meat == before.sf_synth_meat,
        in_car = inCar and inCar.state, in_car_reason = inCar and inCar.reason, pockets_after_car = pocketsAfterCar,
        cancelled_by_stop = cancelledByStop, restart_pass = restartPass, restart_cash_kept = restartCash,
        go_meal = goMeal and goMeal.state, takeout = takeout ~= nil, left_after_go = SFW.count("char:" .. B, "sf_skewer"),
        nothing_held = heldNone(pantrySnap) and heldNone(pocketSnap),
        released_on_death = heldNone(heldAfterDeath), released_on_key = heldNone(heldAfterKey),
        conserved = ok, conservation = detail, unbalanced = tostring(SFW.unbalanced()),
    })
end

-- ---------------------------------------------------------------------------------------------
-- Seating (optional): seats from A1 furniture become one-winner targets; eating seated plays the
-- seat's pose at the catalogue transform. Two customers on one seat: one winner.
-- ---------------------------------------------------------------------------------------------
function scenarios.seating()
    SFW.boot({ seating = true })
    SFW.join(1, A, "Cook", GRILL)
    SFW.join(2, B, "Client", COUNTER)
    SFW.join(3, C, "Client 2", COUNTER)
    setup(1)
    seed(1)
    local seats = 0
    for _ in pairs(svc().seats) do seats = seats + 1 end
    local seat1 = svc().seats["food_court_seat_1"]
    -- Two portions, one for each customer.
    cook(1, "skewer")
    cook(1, "burger")
    order(2, "skewer")
    serve(1)
    answer(1, true)
    order(3, "burger")
    serve(1)
    answer(1, true)
    SFW.move(2, NEAR_SEAT1)
    SFW.move(3, NEAR_SEAT1)
    local key = "rp_streetfood:eat_seat_chair"
    local mark = SFW.mark()
    SFW.intent(2, key, "rp_streetfood:food_court_seat_1")
    SFW.intent(3, key, "rp_streetfood:food_court_seat_1")
    local b = SFW.finish(2, "eat_seat_chair", 40, mark)
    local cOp = SFW.finish(3, "eat_seat_chair", 5, mark)
    local cRefused = table.concat(SFW.refusals(3), ",")
    local sat = played(2, "chair", "playAt")
    -- After B stood up, C takes the seat.
    local mark2 = SFW.mark()
    SFW.intent(3, key, "rp_streetfood:food_court_seat_1")
    local c2 = SFW.finish(3, "eat_seat_chair", 40, mark2)
    local ok, detail = conserved({ "char:" .. A, "char:" .. B, "char:" .. C })
    return SFW.result({
        seats = seats, seat1_profile = seat1 and seat1.profile, seat1_source = seat1 and seat1.source:match("^(%S+)"),
        furniture_calls = MH.shared.furnitureCalls or 0,
        b = b and b.state, c_op = cOp and cOp.state or "none", c_refused = cRefused,
        sat_at_pose = sat ~= nil and math.abs(sat.position.x - (-403.207)) < 1e-6 and math.abs(sat.yaw - (-100.20)) < 1e-6,
        b_skewers = SFW.count("char:" .. B, "sf_skewer"), c2 = c2 and c2.state,
        c_burgers = SFW.count("char:" .. C, "sf_burger"), needs = #MH.shared.needs,
        conserved = ok, conservation = detail, unbalanced = tostring(SFW.unbalanced()),
    })
end

function scenarios.seating_off()
    SFW.boot()
    SFW.join(1, A, "Cook", GRILL)
    local seats = 0
    for _ in pairs(svc().seats) do seats = seats + 1 end
    SFW.command("streetfood.lab.eat", { "1", "seat:1" })
    MH.run(1)
    return SFW.result({ seats = seats, refused = SFW.printed("no seat seat:1 %(seating off%)") })
end

-- ---------------------------------------------------------------------------------------------
-- Durability: ingredients in the pantry, dishes on the pass and in pockets survive a full server
-- restart (orders and offers do not: they are intent, not value); the loop resumes after it.
-- ---------------------------------------------------------------------------------------------
function scenarios.restart()
    SFW.boot()
    SFW.join(1, A, "Cook", GRILL)
    SFW.join(2, B, "Client", COUNTER)
    setup(1)
    seed(1)
    cook(1, "skewer")
    cook(1, "skewer")
    order(2, "skewer")
    serve(1)
    answer(1, true)
    order(2, "skewer")      -- an order still open at the restart
    local before = { pantry = countsOf(PANTRY, INGREDIENTS), pass = SFW.count(PASS, "sf_skewer"),
        pockets = SFW.count("char:" .. B, "sf_skewer"), cash = SFW.balance("cash:" .. B) }
    local keep = SFW.keep()
    SFW.boot({ keep = keep })
    SFW.join(1, A, "Cook", GRILL)
    SFW.join(2, B, "Client", COUNTER)
    setup(1)
    local after = { pantry = countsOf(PANTRY, INGREDIENTS), pass = SFW.count(PASS, "sf_skewer"),
        pockets = SFW.count("char:" .. B, "sf_skewer"), cash = SFW.balance("cash:" .. B) }
    local same = after.pass == before.pass and after.pockets == before.pockets and after.cash == before.cash
    for _, item in ipairs(INGREDIENTS) do same = same and after.pantry[item] == before.pantry[item] end
    local ordersAfter = next(svc().tickets.food_court or {}) == nil
    -- The loop resumes: order again, serve the waiting skewer, eat the old one at the counter.
    order(2, "skewer")
    serve(1)
    answer(1, true)
    local eat = SFW.act(2, "rp_streetfood:eat_counter", COUNTER_T, "eat_counter", 40)
    local ok, detail = conserved({ "char:" .. A, "char:" .. B })
    return SFW.result({
        before_pass = before.pass, before_pockets = before.pockets, same = same, orders_forgotten = ordersAfter,
        after_sale_pass = SFW.count(PASS, "sf_skewer"), eat = eat and eat.state,
        pockets_end = SFW.count("char:" .. B, "sf_skewer"),
        conserved = ok, conservation = detail, unbalanced = tostring(SFW.unbalanced()),
    })
end

-- ---------------------------------------------------------------------------------------------
-- The whole loop from the lab console, with explicit player ids (the integrator's path).
-- ---------------------------------------------------------------------------------------------
function scenarios.lab_console()
    SFW.boot({ seating = true })
    SFW.join(1, A, "Cook", GRILL)
    SFW.join(2, B, "Client", COUNTER)
    SFW.command("streetfood.lab.setup", { "1" })
    SFW.command("streetfood.lab.setup", { "2", "customer" })
    MH.run(1)
    SFW.command("streetfood.lab.seed", { "food_court", "1" })
    MH.run(3)
    local mark = SFW.mark()
    SFW.command("streetfood.lab.cook", { "1", "skewer" })
    local cookOp = SFW.finish(1, "cook_skewer", 40, mark)
    SFW.command("streetfood.lab.offer", { "1", "2", "skewer", "3" })
    MH.run(2)
    local id = SFW.offerOf(1)
    local opId = id and svc().offers[id] and svc().offers[id].opId
    SFW.respond(id, true)
    MH.until_(function() return opId and svc().done[opId] ~= nil end, 40)
    MH.run(1)
    local mark2 = SFW.mark()
    SFW.command("streetfood.lab.eat", { "2", "counter" })
    local eat = SFW.finish(2, "eat_counter", 40, mark2)
    -- The other paths of the console: order + serve, stock, a seated meal, state and status.
    SFW.command("streetfood.lab.give", { "1", "sf_sauce", "2" })
    MH.run(2)
    local mark3 = SFW.mark()
    SFW.command("streetfood.lab.stock", { "1" })
    local stock = SFW.finish(1, "stock", 20, mark3)
    local mark4 = SFW.mark()
    SFW.command("streetfood.lab.order", { "2", "soda", "1" })
    SFW.finish(2, "order_soda", 20, mark4)
    local mark5 = SFW.mark()
    SFW.command("streetfood.lab.serve", { "1" })
    SFW.finish(1, "serve", 20, mark5)
    local id2, opId2 = openOffer(1)
    SFW.respond(id2, true)
    MH.until_(function() return opId2 and svc().done[opId2] ~= nil end, 40)
    MH.run(1)
    SFW.move(2, NEAR_SEAT1)
    local mark6 = SFW.mark()
    SFW.command("streetfood.lab.eat", { "2", "seat:1", "soda" })
    local seated = SFW.finish(2, "eat_seat_chair", 40, mark6)
    SFW.command("streetfood.lab.state", { "2" })
    SFW.command("streetfood.lab.stall", { "food_court" })
    SFW.command("streetfood.status", {})
    MH.run(3)
    SFW.command("streetfood.lab.clock", { "1", "off" })
    MH.run(1)
    return SFW.result({
        cook = cookOp and cookOp.state, sold = opId ~= nil and svc().done[opId] ~= nil, eat = eat and eat.state,
        stock = stock and stock.state, soda_sold = opId2 ~= nil and svc().done[opId2] ~= nil,
        seated = seated and seated.state,
        state_line = SFW.printed("player 2 subject acct%-b pockets="), receipt_line = SFW.printed("receipt purchase sf%.sale:"),
        stall_line = SFW.printed("stall food_court pass stash:sf%.food_court:pass"),
        seat_line = SFW.printed("seat food_court_seat_1 Chair by the grill furniture 14182403679719868087"),
        status_line = SFW.printed("ready=true seating=on"), clock_line = SFW.printed("duty 1 off: true"),
        restock_line = SFW.printed("restock sf%.restock:"), offer_line = SFW.printed("offer [0-9a-f]+: 1 %-> 2, skewer"),
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
