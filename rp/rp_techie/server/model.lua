-- rp_techie / server/model.lua: pure rules. No platform call lives here: account ids of a workshop,
-- the lines of a stage / a dealer lot / a trade, the shop quote, what a reservation lacks, prices,
-- trade roles, mint rules and the texts players read.
--
-- Global: TechieModel.

TechieModel = {}
local M = TechieModel

function M.playerId(value)
    local n = tonumber(value)
    if n == nil or n ~= n or n % 1 ~= 0 or n < 1 or n > 2147483647 then return nil end
    return math.tointeger(n)
end

function M.count(value, maximum)
    local n = tonumber(value)
    if n == nil or n ~= n or n % 1 ~= 0 or n < 1 or n > (maximum or 1000000) then return nil end
    return math.tointeger(n)
end

-- A whole number of eddies, 0..maximum.
function M.price(value, maximum)
    local n = tonumber(value)
    if n == nil or n ~= n or n % 1 ~= 0 or n < 0 or n > (maximum or 0) then return nil end
    return math.tointeger(n)
end

function M.distance(a, b)
    if type(a) ~= "table" or type(b) ~= "table" or not a.x or not b.x then return nil end
    local dx, dy, dz = a.x - b.x, a.y - b.y, (a.z or 0) - (b.z or 0)
    return math.sqrt(dx * dx + dy * dy + dz * dz)
end

function M.validKey(key)
    return type(key) == "string" and #key >= 1 and #key <= 24 and key:match("^[a-z0-9_]+$") ~= nil
end

-- The workshop's tray: a deterministic durable id (no runtime value in it), so a restart opens the
-- same account again. The part after the last colon lets an operator grant exactly the trays
-- (`rp_techie:stash/tray`).
function M.trayAccount(workshopKey) return ("stash:tch.%s:tray"):format(workshopKey) end

function M.benchTargetId(workshopKey, benchKey) return workshopKey .. "_" .. benchKey end

-- ---------------------------------------------------------------------------------------------
-- Stages
-- ---------------------------------------------------------------------------------------------
-- The lines of one stage: every input out of its place (pockets or tray) into the workshop sink,
-- every output out of the workshop sink into its place. Reserved before the bar (inputs held, the
-- room for the outputs held), committed unchanged after it: ONE operation, so the inputs burn and
-- the outputs appear together or not at all.
function M.stageLines(recipe, accounts, sink, reason)
    local lines = {}
    for _, input in ipairs(recipe.inputs) do
        lines[#lines + 1] = { item = input.item, count = input.count, from = accounts[input.from or "pockets"], to = sink,
            reason = reason }
    end
    for _, output in ipairs(recipe.outputs) do
        lines[#lines + 1] = { item = output.item, count = output.count or 1, from = sink, to = accounts[output.to or "pockets"],
            reason = reason }
    end
    return lines
end

-- Available count of an item in a coordinator snapshot (count minus what reservations hold).
function M.available(snapshot, item)
    if type(snapshot) ~= "table" then return 0 end
    local have = type(snapshot.items) == "table" and (snapshot.items[item] or 0) or 0
    local held = type(snapshot.held) == "table" and type(snapshot.held.items) == "table"
        and (snapshot.held.items[item] or 0) or 0
    return math.max(0, have - held)
end

-- What a recipe lacks given the snapshots of its places: a list of
-- { item, need, have, from } (empty when everything is there).
function M.missing(recipe, snapshots)
    local need = {}
    for _, input in ipairs(recipe.inputs) do
        local from = input.from or "pockets"
        local key = from .. "|" .. input.item
        need[key] = need[key] or { item = input.item, from = from, need = 0 }
        need[key].need = need[key].need + input.count
    end
    local out = {}
    for _, input in ipairs(recipe.inputs) do
        local from = input.from or "pockets"
        local entry = need[from .. "|" .. input.item]
        if entry and not entry.done then
            entry.done = true
            local have = M.available(snapshots[from], input.item)
            if have < entry.need then
                out[#out + 1] = { item = input.item, need = entry.need, have = have, from = from }
            end
        end
    end
    return out
end

-- Where a recipe's outputs land: "tray", "pockets" or "both".
function M.outputPlace(recipe)
    local tray, pockets = false, false
    for _, output in ipairs(recipe.outputs) do
        if (output.to or "pockets") == "tray" then tray = true else pockets = true end
    end
    if tray and pockets then return "both" end
    return tray and "tray" or "pockets"
end

-- A coordinator refusal of a stage, named for the player. `lacks` is M.missing's answer when the
-- refusal was insufficient_items.
function M.stageRefusal(reason, recipe, lacks)
    if reason == "insufficient_items" then
        for _, l in ipairs(lacks or {}) do
            if l.from == "pockets" then return "missing_parts" end
        end
        if lacks and #lacks > 0 then return "missing_components" end
        return recipe and recipe.stage == "assemble" and "missing_components" or "missing_parts"
    end
    if reason == "capacity_exceeded" then
        local place = recipe and M.outputPlace(recipe) or "pockets"
        return place == "tray" and "tray_full" or "pockets_full"
    end
    if reason == "unknown_account" then return "no_pockets" end
    return reason or "techie_unavailable"
end

-- "3 Scrap metal -> 2 Alloy plate" for menus and chat.
function M.recipeText(recipe, labelOf)
    local ins, outs = {}, {}
    for _, i in ipairs(recipe.inputs) do ins[#ins + 1] = ("%d %s"):format(i.count, labelOf(i.item)) end
    for _, o in ipairs(recipe.outputs) do outs[#outs + 1] = ("%d %s"):format(o.count or 1, labelOf(o.item)) end
    return table.concat(ins, " + ") .. " -> " .. table.concat(outs, " + ")
end

function M.lackText(lacks, labelOf)
    local parts = {}
    for _, l in ipairs(lacks) do
        parts[#parts + 1] = ("%d %s (have %d%s)"):format(l.need, labelOf(l.item), l.have,
            l.from == "tray" and " on the tray" or "")
    end
    return table.concat(parts, ", ")
end

-- ---------------------------------------------------------------------------------------------
-- The parts dealer: one lot = the parts minted into the pockets + the price burned, one operation.
-- ---------------------------------------------------------------------------------------------
function M.dealerLines(lot, pockets, cash, dealer, reason)
    return {
        { item = lot.item, count = lot.count, from = dealer, to = pockets, reason = reason },
        { money = lot.price, from = cash, to = dealer, reason = reason },
    }
end

function M.dealerRefusal(reason)
    if reason == "insufficient_funds" then return "not_enough_cash" end
    if reason == "unknown_account" then return "no_pockets" end
    if reason == "capacity_exceeded" then return "pockets_full" end
    if reason == "mint_cap_exceeded" then return "dealer_sold_out" end
    return reason or "techie_unavailable"
end

-- ---------------------------------------------------------------------------------------------
-- Shops
-- ---------------------------------------------------------------------------------------------
-- What a shop buys from `available` ({ [item] = count }): every accepted item the techie has, at
-- the shop price, split between the techie and the society. nil, "nothing_to_sell" when empty.
function M.shopQuote(shop, available, prices, share, maxLines)
    local items, total = {}, 0
    for _, item in ipairs(shop.accepts or {}) do
        local n = math.tointeger(available[item] or 0) or 0
        local unit = prices[item] and prices[item].shop
        if n > 0 and unit and unit > 0 and #items < (maxLines or 12) then
            items[#items + 1] = { item = item, count = n, unit = unit }
            total = total + n * unit
        end
    end
    if #items == 0 or total <= 0 then return nil, "nothing_to_sell" end
    local society = math.floor(total * (share or 0))
    return { items = items, total = total, society = society, seller = total - society }
end

-- The rp_economy sale of a shop quote: goods out of the seller's pockets to the NPC buyer
-- (sys:rp_techie:<shop>), the price minted and split. One operation, one receipt.
function M.shopSaleSpec(o)
    local items = {}
    for _, it in ipairs(o.quote.items) do items[#items + 1] = { item = it.item, count = it.count } end
    local payees = { { player = o.seller, amount = o.quote.seller } }
    if o.quote.society > 0 then payees[#payees + 1] = { society = o.society, amount = o.quote.society } end
    return {
        opId = o.opId, seller = { player = o.seller }, buyer = { sys = o.shop }, items = items,
        total = o.quote.total, payees = payees, reason = o.reason,
    }
end

-- The same sale as coordinator lines (C.shopPayment = "ledger"): goods burned into the shop sink,
-- the price minted out of it into the seller's cash and the society.
function M.shopLedgerLines(o)
    local lines = {}
    for _, it in ipairs(o.quote.items) do
        lines[#lines + 1] = { item = it.item, count = it.count, from = o.pockets, to = o.sink, reason = o.reason }
    end
    lines[#lines + 1] = { money = o.quote.seller, from = o.sink, to = o.cash, reason = o.reason }
    if o.quote.society > 0 then
        lines[#lines + 1] = { money = o.quote.society, from = o.sink, to = "soc:" .. o.society, reason = o.reason }
    end
    return lines
end

function M.shopRefusal(reason)
    if reason == "insufficient_items" then return "nothing_to_sell" end
    if reason == "mint_cap" or reason == "mint_cap_exceeded" then return "shop_out_of_cash" end
    if reason == "mint_denied" then return "shop_not_configured" end
    return reason or "techie_unavailable"
end

-- ---------------------------------------------------------------------------------------------
-- Trades between players
-- ---------------------------------------------------------------------------------------------
local function contains(list, value)
    for _, v in ipairs(list or {}) do if v == value then return true end end
    return false
end
M.contains = contains

-- "part": the techie is the buyer; "product": the techie is the seller; nil: not tradeable here.
function M.tradeRole(cfg, item)
    if contains(cfg.parts, item) then return "part" end
    if contains(cfg.products, item) then return "product" end
    return nil
end

-- ONE coordinator operation: the goods out of the seller's pockets into the buyer's, the price
-- out of the buyer's cash into the seller's (no line when the price is 0).
function M.tradeLines(o)
    local reason = o.reason or "techie trade"
    local lines = {
        { item = o.item, count = o.count, from = "char:" .. o.sellerSubject, to = "char:" .. o.buyerSubject, reason = reason },
    }
    if (o.price or 0) > 0 then
        lines[#lines + 1] = { money = o.price, from = "cash:" .. o.buyerSubject, to = "cash:" .. o.sellerSubject, reason = reason }
    end
    return lines
end

function M.tradeRefusal(reason)
    if reason == "insufficient_funds" then return "buyer_broke" end
    if reason == "insufficient_items" then return "seller_lacks_items" end
    if reason == "capacity_exceeded" then return "buyer_pockets_full" end
    if reason == "unknown_account" then return "no_pockets" end
    return reason or "techie_unavailable"
end

-- ---------------------------------------------------------------------------------------------
-- Operator help: the mint rules this configuration needs, as `tunable.set` values.
-- ---------------------------------------------------------------------------------------------
function M.mintRules(cfg, resource)
    resource = resource or "rp_techie"
    local rules = {}
    local function add(account, asset, cap) rules[#rules + 1] = ("%s %s %s %d"):format(resource, account, asset, cap) end
    local seen = {}
    for _, key in ipairs(cfg.recipeOrder) do
        local r = cfg.recipes[key]
        for _, o in ipairs(r and r.outputs or {}) do
            if not seen[o.item] then
                seen[o.item] = true
                add(cfg.accounts.workshop, o.item, (cfg.mintCaps.workshop or {})[o.item] or 50)
            end
        end
    end
    local dealt = {}
    for _, key in ipairs(cfg.dealerOrder) do
        local d = cfg.dealers[key]
        for _, lot in ipairs(d and d.lots or {}) do
            if not dealt[lot.item] then
                dealt[lot.item] = true
                add(cfg.accounts.dealer, lot.item, (cfg.mintCaps.dealer or {})[lot.item] or 100)
            end
        end
    end
    if cfg.shopPayment == "ledger" then add(cfg.accounts.shop, "money", cfg.mintCaps.shopMoney or 60000) end
    return rules
end

-- A server tunable holds at most 256 characters (the platform's ResourceTunables.MaximumTextLength),
-- so one `mintN` value cannot carry every rule: they are packed, in order, into as few values as fit.
M.TUNABLE_TEXT_MAX = 256
function M.mintSlots(rules, max)
    max = max or M.TUNABLE_TEXT_MAX
    local slots, current = {}, nil
    for _, rule in ipairs(rules) do
        local joined = current and (current .. "; " .. rule) or rule
        if current and #joined > max then
            slots[#slots + 1] = current
            current = rule
        else
            current = joined
        end
    end
    if current then slots[#slots + 1] = current end
    return slots
end

-- ASCII only: prompt cards and chat replace a non-ASCII glyph with "?".
function M.money(n) return ("%d eddies"):format(math.tointeger(n) or 0) end

M.TEXT = {
    not_owner = "That is not yours to do.",
    techie_unavailable = "The workshop is closed for now (the ledger is unavailable).",
    store_unavailable = "The workshop's ledger is unavailable: try again in a moment.",
    coordinator_unavailable = "The workshop's ledger is unavailable: try again in a moment.",
    in_doubt = "The workshop is still settling that: check again in a moment.",
    no_job = "You are not a techie (no job).",
    wrong_job = "You are not a techie: you need the techie job.",
    off_duty = "You are off duty: clock in first (/service).",
    grade_too_low = "Your grade is too low for that recipe.",
    stale_job_epoch = "Your shift changed in the middle of that: nothing was done.",
    not_eligible = "You cannot work here.",
    target_claimed = "Someone is already working at that bench.",
    actor_busy = "Finish what you are doing first.",
    missing_parts = "You do not carry the parts for that.",
    missing_components = "The tray is short of components for that: strip some parts first.",
    tray_full = "The workshop tray is full: assemble what is waiting first.",
    pockets_full = "Your pockets are full.",
    no_pockets = "Your pockets are not ready (rp_inventory backend).",
    wrong_bench = "That is not made at this bench.",
    unknown_recipe = "There is no such recipe.",
    unknown_bench = "There is no bench here.",
    no_bench_near = "Stand at a bench of the right kind first.",
    not_enough_cash = "Not enough cash for that lot.",
    dealer_sold_out = "The dealer is out of that for this hour.",
    nothing_to_sell = "You carry nothing this shop buys.",
    shop_out_of_cash = "The shop has spent its budget for this hour.",
    shop_not_configured = "The shop cannot pay yet (operator: rp_economy mint budget for rp_techie, README Setup).",
    not_tradeable = "That is not traded here (parts to a techie, products from a techie).",
    techie_required = "One side of this trade must be an on-duty techie.",
    invalid_count = "Give a whole number of units.",
    invalid_price = "Give a whole number of eddies.",
    unknown_player = "There is no such player.",
    self_trade = "You cannot trade with yourself.",
    seller_lacks_items = "The seller does not carry that.",
    buyer_broke = "The buyer does not have enough cash.",
    buyer_pockets_full = "The buyer's pockets are full.",
    player_reserved = "One of you is already in a hand-over.",
    too_far = "Get closer.",
    position_unavailable = "Your position is unknown right now: try again.",
    lost = "The hand-over was lost: nothing was paid.",
    gone = "The other player left: nothing was paid.",
    timeout = "Nobody answered the offer: nothing was paid.",
    cancelled = "The hand-over was cancelled: nothing was paid.",
    declined = "The offer was declined: nothing was paid.",
    caller_not_allowed = "That resource may not start trades.",
    interactions_unavailable = "Hand-overs are unavailable on this server (open77_player_interactions).",
    mint_denied = "The workshop cannot create that (operator: mint rule missing).",
    mint_cap_exceeded = "The workshop has made enough of that for this hour.",
    namespace_denied = "The workshop's accounts are not writable (operator: writers policy).",
    no_offer = "You have no pending offer.",
    withdrawn = "The offer was withdrawn: nothing was paid.",
    player_not_alive = "One of you is down: nothing was paid.",
    resource_stopping = "The workshop closed: nothing was paid.",
    unknown_dealer = "There is no dealer here.",
    unknown_shop = "There is no shop counter here.",
}

function M.textFor(reason)
    return M.TEXT[reason] or "That did not work. Try again in a moment."   -- never the raw code on screen; the server log keeps it
end

return M
