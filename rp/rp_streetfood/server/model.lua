-- rp_streetfood / server/model.lua: pure rules. No platform call lives here: accounts of a stall,
-- the lines of a cook / a meal / a restock, the sale spec, the dish a meal consumes, tips, ticket
-- order and the texts players read.
--
-- Global: StreetfoodModel.

StreetfoodModel = {}
local M = StreetfoodModel

function M.playerId(value)
    local n = tonumber(value)
    if n == nil or n ~= n or n % 1 ~= 0 or n < 1 or n > 2147483647 then return nil end
    return math.tointeger(n)
end

function M.distance(a, b)
    if type(a) ~= "table" or type(b) ~= "table" or not a.x or not b.x then return nil end
    local dx, dy, dz = a.x - b.x, a.y - b.y, (a.z or 0) - (b.z or 0)
    return math.sqrt(dx * dx + dy * dy + dz * dz)
end

-- REDengine convention (props / playAt): yaw in degrees about +Z, 0 faces +Y, so forward is
-- (-sin, cos). Used only to describe arithmetic points; every configured position says its source.
function M.forward(yaw)
    local r = math.rad(tonumber(yaw) or 0)
    return -math.sin(r), math.cos(r)
end

-- A stall's two containers. Deterministic durable ids (no runtime value in them), so a restart
-- opens the same accounts again and needs no listing: `stash:sf.<stall>:pantry` (ingredients and
-- resold stock) and `stash:sf.<stall>:pass` (cooked dishes waiting to be served). The part after
-- the last colon lets an operator grant exactly these two (`rp_streetfood:stash/pantry+stash/pass`).
function M.stallAccounts(stallKey)
    return ("stash:sf.%s:pantry"):format(stallKey), ("stash:sf.%s:pass"):format(stallKey)
end

function M.validStallKey(key)
    return type(key) == "string" and #key >= 1 and #key <= 32 and key:match("^[a-z0-9_]+$") ~= nil
end

-- The lines of one cook: every input out of the pantry into the kitchen sink, the dish out of the
-- kitchen onto the pass. Reserved before the bar (the inputs are held, the pass capacity is held),
-- committed unchanged after it: one operation, so ingredients and dish move together or not at all.
function M.cookLines(recipe, pantry, pass, kitchen, reason)
    local lines = {}
    for _, input in ipairs(recipe.inputs) do
        lines[#lines + 1] = { item = input.item, count = input.count, from = pantry, to = kitchen, reason = reason }
    end
    lines[#lines + 1] = { item = recipe.output.item, count = recipe.output.count or 1, from = kitchen, to = pass,
        reason = reason }
    return lines
end

function M.restockLines(amounts, supplier, pantry, order)
    local lines = {}
    for _, item in ipairs(order) do
        local n = math.tointeger(amounts[item] or 0) or 0
        if n > 0 then lines[#lines + 1] = { item = item, count = n, from = supplier, to = pantry, reason = "stall restock" } end
    end
    return lines
end

-- One portion eaten (or drunk): out of the pockets into the `eaten` sink.
function M.eatLine(item, subject, sink)
    return { item = item, count = 1, from = "char:" .. subject, to = sink, reason = "street food eaten" }
end

function M.menuKeyOfItem(menu, item)
    for key, entry in pairs(menu) do
        if entry.item == item or key == item then return key end
    end
    return nil
end

local function kindOk(entry, kind)
    return kind == "any" or entry.kind == kind
end

-- The menu entry a meal consumes, from a pockets snapshot `items` ({ [itemId] = count }):
-- the one asked for (`wanted`, a menu key or an item id), else the one in the hand (`held`), else
-- the first of `kind` ("food" | "drink" | "any") in menu order that the pockets hold.
function M.pickDish(menu, order, kind, items, held, wanted)
    items = items or {}
    if wanted ~= nil then
        local key = M.menuKeyOfItem(menu, wanted)
        local entry = key and menu[key]
        if entry and kindOk(entry, kind) and (items[entry.item] or 0) >= 1 then return key end
        return nil
    end
    if held ~= nil then
        local key = M.menuKeyOfItem(menu, held)
        local entry = key and menu[key]
        if entry and kindOk(entry, kind) and (items[entry.item] or 0) >= 1 then return key end
    end
    for _, key in ipairs(order) do
        local entry = menu[key]
        if entry and kindOk(entry, kind) and (items[entry.item] or 0) >= 1 then return key end
    end
    return nil
end

function M.validTip(value, maximum)
    local n = tonumber(value)
    if n == nil or n ~= n or n % 1 ~= 0 or n < 0 or n > (maximum or 0) then return nil end
    return math.tointeger(n)
end

-- The B3 sale of one portion: the dish leaves its stall container into the buyer's pockets, the
-- price goes to the society, the tip to the cook. One rp_economy operation, one receipt; the id is
-- the offer's own, so a retry or a replay returns that receipt and the customer pays once.
function M.saleSpec(o)
    local payees = { { society = o.society, amount = o.price } }
    if (o.tip or 0) > 0 then payees[#payees + 1] = { player = o.cook, amount = o.tip } end
    return {
        opId = o.opId,
        seller = { player = o.cook },
        buyer = { player = o.customer, wallet = o.instrument or "cash" },
        items = { { item = o.item, count = 1, from = o.source } },
        total = o.price + (o.tip or 0),
        payees = payees,
        reason = o.reason,
    }
end

-- Tickets of a stall, oldest first (by sequence).
function M.ticketsInOrder(tickets)
    local list = {}
    for _, t in pairs(tickets or {}) do list[#list + 1] = t end
    table.sort(list, function(a, b) return a.seq < b.seq end)
    return list
end

-- Coordinator refusals, named for the step they happened in.
function M.cookRefusal(reason)
    if reason == "insufficient_items" then return "missing_ingredients" end
    if reason == "capacity_exceeded" then return "pass_full" end
    return reason or "streetfood_unavailable"
end

function M.eatRefusal(reason)
    if reason == "insufficient_items" or reason == "instance_unavailable" then return "no_dish" end
    return reason or "streetfood_unavailable"
end

function M.saleRefusal(reason)
    if reason == "insufficient_items" then return "sold_out" end
    return reason or "streetfood_unavailable"
end

-- ASCII only: prompt cards and chat replace a non-ASCII glyph with "?" (live 2026-10-12: "18 ?$").
function M.money(n) return ("%d eddies"):format(math.tointeger(n) or 0) end

M.TEXT = {
    not_owner = "That is not yours to do.",
    streetfood_unavailable = "The stall is closed for now (the ledger is unavailable).",
    store_unavailable = "The stall's ledger is unavailable: try again in a moment.",
    coordinator_unavailable = "The stall's ledger is unavailable: try again in a moment.",
    in_doubt = "The stall is still settling that: check again in a moment.",
    no_job = "You do not work this stall (no job).",
    wrong_job = "You do not work this stall: you need the cook job.",
    off_duty = "You are off duty: clock in first (/service).",
    stale_job_epoch = "Your shift changed in the middle of that: nothing was done.",
    not_eligible = "You cannot do that at this stall.",
    target_claimed = "Someone is already working there.",
    actor_busy = "Finish what you are doing first.",
    missing_ingredients = "The pantry is short of an ingredient for that.",
    pass_full = "The pass is full: serve what is waiting first.",
    no_dish = "You have nothing of that kind to eat or drink.",
    sold_out = "That portion is gone: ask the cook for another.",
    no_order_ready = "No order is ready to hand over (nothing waiting, nobody at the counter, or the portion is not ready).",
    no_order = "Order at the counter first.",
    unknown_dish = "That is not on the menu.",
    invalid_tip = "A tip is a whole number of eddies.",
    nothing_to_stock = "You carry nothing the pantry takes.",
    insufficient_funds = "Not enough cash for that.",
    customer_busy = "That customer is busy with something else.",
    player_reserved = "One of you is already in a hand-over.",
    too_far = "Get closer to the counter.",
    seating_off = "Seats are not in use at this stall.",
    backend_legacy = "Stocking needs rp_inventory's transactions backend.",
    mint_denied = "The stall cannot create that (operator: mint rule missing).",
    mint_cap_exceeded = "The stall's supplier is out for this hour.",
    namespace_denied = "The stall's accounts are not writable (operator: writers policy).",
    lost = "The hand-over was lost: nothing was paid.",
    customer_gone = "The customer left: nothing was paid.",
    timeout = "Nobody answered the offer: nothing was paid.",
    cancelled = "The hand-over was cancelled: nothing was paid.",
    position_unavailable = "Your position is unknown right now: try again.",
    unknown_stall = "There is no stall here.",
    wrong_station = "That is not cooked at this station.",
    interactions_unavailable = "Hand-overs are unavailable on this server (open77_player_interactions).",
}

function M.textFor(reason)
    return M.TEXT[reason] or "That did not work. Try again in a moment."   -- never the raw code on screen; the server log keeps it
end

return M
