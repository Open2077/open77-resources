-- rp_salvage / server/model.lua: pure rules of the salvage loop. No native, no export: the offline
-- suite and the service use the same functions.
--
--   roll / maxYieldG / yieldLines     what one work produces, drawn from the operation id
--   pickTool / wearLine               which tool instance wears and the coordinator line for it
--   quote                             the price of a crate's contents and its split
--   crate ids and metadata            a crate is ONE coordinator world: container (its hold)
--   geometry                          the same yaw convention as open77_actions (0 faces +y)
--   refusal texts                     what a player reads for every typed refusal
--
-- Global: SalvageModel.

SalvageModel = {}
local M = SalvageModel

M.META_VERSION = 1
M.APP = "rp_salvage"

-- ---------------------------------------------------------------------------------------------
-- Small helpers
-- ---------------------------------------------------------------------------------------------
function M.copy(value, depth)
    depth = depth or 0
    if type(value) ~= "table" or depth > 8 then return value end
    local out = {}
    for k, v in pairs(value) do out[k] = M.copy(v, depth + 1) end
    return out
end

function M.integer(value)
    local n = tonumber(value)
    if not n or n ~= n or n % 1 ~= 0 then return nil end
    return math.tointeger(n)
end

function M.playerId(value)
    local n = M.integer(value)
    if not n or n < 1 then return nil end
    return n
end

-- FNV-1a 32 over a string: the seed of a deterministic roll.
function M.hash(text)
    local h = 2166136261
    for i = 1, #text do
        h = h ~ text:byte(i)
        h = (h * 16777619) & 0xFFFFFFFF
    end
    return h
end

-- A tiny deterministic generator (LCG, Numerical Recipes constants), enough for loot.
local function generator(seed)
    local state = seed & 0xFFFFFFFF
    return function(lo, hi)
        state = (1664525 * state + 1013904223) & 0xFFFFFFFF
        if lo == nil then return state end
        return lo + (state % (hi - lo + 1))
    end
end

-- ---------------------------------------------------------------------------------------------
-- Loot
-- ---------------------------------------------------------------------------------------------
-- roll(table, seedText) -> { { item, count }, ... } in table order, zero counts left out.
-- The same seed always draws the same lines: a retried commit sends identical lines.
function M.roll(lootTable, seedText)
    local rnd = generator(M.hash(tostring(seedText)))
    local out = {}
    for _, entry in ipairs(lootTable or {}) do
        local hit = rnd(1, 100) <= (entry.chance or 100)
        local count = rnd(entry.min or 1, entry.max or entry.min or 1)
        if hit and count > 0 then out[#out + 1] = { item = entry.item, count = count } end
    end
    return out
end

-- The heaviest draw a table can make: the capacity a work reserves before the bar starts.
function M.maxYieldG(lootTable, weightsG)
    local grams = 0
    for _, entry in ipairs(lootTable or {}) do
        grams = grams + (weightsG[entry.item] or 0) * (entry.max or entry.min or 1)
    end
    return grams
end

function M.weightOf(lines, weightsG)
    local grams = 0
    for _, l in ipairs(lines) do grams = grams + (weightsG[l.item] or 0) * l.count end
    return grams
end

function M.yieldLines(rolled, source, hold, reason)
    local lines = {}
    for _, r in ipairs(rolled) do
        lines[#lines + 1] = { item = r.item, count = r.count, from = source, to = hold, reason = reason }
    end
    return lines
end

-- ---------------------------------------------------------------------------------------------
-- Tools (B1 durability: meta.durability, 0..max; at 0 a `breaks` tool is destroyed)
-- ---------------------------------------------------------------------------------------------
function M.durabilityOf(inst, toolCfg)
    local d = type(inst.meta) == "table" and M.integer(inst.meta.durability) or nil
    if d == nil then d = toolCfg and toolCfg.max or 0 end
    return d
end

-- The most worn usable instance of `item` (B1 wears the lowest first), ties by id.
-- instances = { [iid] = { item, meta, version } } (a coordinator snapshot).
function M.pickTool(instances, item, toolCfg)
    local best
    for iid, inst in pairs(instances or {}) do
        if inst.item == item then
            local d = M.durabilityOf(inst, toolCfg)
            if d > 0 and (best == nil or d < best.durability or (d == best.durability and iid < best.iid)) then
                best = { iid = iid, durability = d, version = inst.version }
            end
        end
    end
    return best
end

-- The coordinator line that wears `tool` by one, and what is left.
function M.wearLine(tool, account, toolCfg, brokenSink, reason)
    local left = math.max(0, tool.durability - 1)
    if left == 0 and toolCfg and toolCfg.breaks then
        return { instance = tool.iid, from = account, to = brokenSink, reason = reason }, 0, true
    end
    return { instance = tool.iid, at = account, metaPatch = { durability = left }, reason = reason }, left, false
end

-- ---------------------------------------------------------------------------------------------
-- Sale
-- ---------------------------------------------------------------------------------------------
-- quote(contents, prices, order, share) -> { items = { { item, count } }, total, society, seller }
-- | nil, "crate_empty". Unpriced items are not sold (they stay in the hold, which then cannot
-- close: an operator sees them in salvage.lab.state).
function M.quote(contents, prices, order, share)
    local items, total = {}, 0
    for _, item in ipairs(order) do
        local n = M.integer(contents and contents[item]) or 0
        if n > 0 and prices[item] then
            items[#items + 1] = { item = item, count = n }
            total = total + n * prices[item]
        end
    end
    if total < 1 then return nil, "crate_empty" end
    local society = math.floor(total * (share or 0))
    return { items = items, total = total, society = society, seller = total - society }
end

-- ---------------------------------------------------------------------------------------------
-- Crates: a crate IS a coordinator world: container (its hold). The hold keeps the materials for
-- the crate's whole life; the crate's custody token (one `salvage_crate` instance) sits in the
-- hold while the crate is on the ground or carried, and in `veh:<plate>:cargo` while it rides in
-- a bed. Nothing else moves: materials enter at a work commit and leave at the sale.
-- ---------------------------------------------------------------------------------------------
function M.keyOf(holdId)
    return type(holdId) == "string" and holdId:match("^world:(.+)$") or nil
end

function M.tokenOf(holdId)
    local key = M.keyOf(holdId)
    return key and ("crate." .. key) or nil
end

function M.holdOfToken(iid)
    local key = type(iid) == "string" and iid:match("^crate%.(.+)$") or nil
    return key and ("world:" .. key) or nil
end

function M.isOurs(meta)
    return type(meta) == "table" and meta.app == M.APP and meta.kind == "crate"
end

-- The crate record kept in the hold's coordinator metadata (<= 2 KiB). `at` is the durable
-- placement (where the crate stands when it is on the ground); `sale` the persisted quote.
function M.crateMeta(fields)
    return {
        app = M.APP, kind = "crate", v = M.META_VERSION,
        owner = fields.owner, node = fields.node, created = fields.created,
        at = fields.at and { x = fields.at.x, y = fields.at.y, z = fields.at.z } or nil,
        yaw = fields.yaw or 0.0, bucket = fields.bucket or 0,
        where = fields.where, sale = fields.sale and M.copy(fields.sale) or nil,
    }
end

-- Where the token is, from a hold snapshot: "hold" | "away".
function M.tokenHere(snapshot, iid)
    return type(snapshot) == "table" and type(snapshot.instances) == "table" and snapshot.instances[iid] ~= nil
end

function M.contentsWeightG(snapshot, weightsG)
    local grams = 0
    for item, n in pairs(type(snapshot) == "table" and snapshot.items or {}) do
        grams = grams + (weightsG[item] or 0) * (M.integer(n) or 0)
    end
    return grams
end

function M.isEmpty(snapshot)
    if type(snapshot) ~= "table" then return true end
    for _, n in pairs(snapshot.items or {}) do if (M.integer(n) or 0) > 0 then return false end end
    return next(snapshot.instances or {}) == nil
end

-- ---------------------------------------------------------------------------------------------
-- Geometry: yaw in degrees about +z, 0 faces +y, forward = (-sin, cos) (open77_actions, props).
-- ---------------------------------------------------------------------------------------------
function M.distance(a, b)
    if type(a) ~= "table" or type(b) ~= "table" then return nil end
    local dx, dy, dz = (a.x or 0) - (b.x or 0), (a.y or 0) - (b.y or 0), (a.z or 0) - (b.z or 0)
    return math.sqrt(dx * dx + dy * dy + dz * dz)
end

function M.planar(a, b)
    if type(a) ~= "table" or type(b) ~= "table" then return nil end
    local dx, dy = (a.x or 0) - (b.x or 0), (a.y or 0) - (b.y or 0)
    return math.sqrt(dx * dx + dy * dy)
end

function M.offsetPoint(origin, yaw, ahead)
    local r = math.rad(tonumber(yaw) or 0.0)
    return { x = origin.x - math.sin(r) * ahead, y = origin.y + math.cos(r) * ahead, z = origin.z }
end

function M.towards(from, to, dist)
    local d = M.planar(from, to)
    if not d or d < 1e-6 then return { x = from.x, y = from.y, z = from.z } end
    local k = math.min(dist, d) / d
    return { x = from.x + (to.x - from.x) * k, y = from.y + (to.y - from.y) * k, z = from.z }
end

function M.yawTowards(from, to)
    local dx, dy = to.x - from.x, to.y - from.y
    if math.abs(dx) < 1e-6 and math.abs(dy) < 1e-6 then return 0.0 end
    return math.deg(math.atan(-dx, dy))
end

-- ---------------------------------------------------------------------------------------------
-- Refusals a player reads. Every typed refusal of the loop and of the libraries it composes has
-- a sentence; an unknown token is shown verbatim so nothing is silent.
-- ---------------------------------------------------------------------------------------------
M.TEXT = {
    -- this resource
    node_depleted = "This wreck is stripped for now. Try another one, it regrows.",
    unknown_node = "Nothing to salvage here.",
    no_tool = "You need the right tool: a cutting torch to cut, a crowbar to pry.",
    tool_busy = "That tool is already in use.",
    crate_full = "Your crate here is full: carry it to the truck first.",
    crate_busy = "Your crate is being filled already.",
    too_many_crates = "You already have too many crates out. Sell or load some first.",
    yard_full = "The yard is full of crates. Clear some first.",
    crate_unavailable = "That crate is gone.",
    crate_empty = "That crate is empty: the buyer will not take it.",
    not_crate_owner = "That crate is someone else's haul.",
    already_sold = "That crate was already sold.",
    no_truck = "No truck you can load is parked at the bay.",
    no_salvage_crate = "No scrap crate of the yard in that bed.",
    unknown_crate = "That crate is not one of the yard's.",
    salvage_unavailable = "The yard's ledger is not ready. Try again in a moment.",
    salvage_not_configured = "The yard is not configured for this (server ledger rules). Tell an admin.",
    in_doubt = "The yard is still confirming that. Give it a few seconds.",
    -- rp_jobs (B4)
    off_duty = "Clock in with the foreman first.",
    no_job = "You do not work at the yard. The employment agency hires scrappers.",
    wrong_job = "You do not work at the yard.",
    stale_job_epoch = "Your job changed in the middle of it: nothing was done.",
    not_eligible = "You cannot do that now.",
    -- rp_garage / rp_cargo (A9)
    no_access = "You hold no key for that truck.",
    action_not_permitted = "You may not load that truck.",
    impounded = "That truck is impounded.",
    vehicle_not_tracked = "That vehicle has no plate on file: use a registered truck.",
    no_cargo_layout = "That vehicle has no cargo bed the yard knows.",
    cargo_full = "The bed is full.",
    too_far = "Get closer.",
    vehicle_moving = "Stop the truck first.",
    cargo_empty = "The bed is empty.",
    -- open77_actions (B5)
    target_claimed = "Someone is already working there.",
    destination_claimed = "Someone is already using that spot.",
    actor_busy = "Finish what you are doing first.",
    carrying = "Put the crate down first.",
    not_carrying = "You are not carrying a crate.",
    item_unavailable = "That crate is gone.",
    player_in_vehicle = "Get out of the vehicle first.",
    in_combat = "Not while fighting.",
    -- coordinator (A13) and wallet (B3)
    capacity_exceeded = "Not enough room for that.",
    store_unavailable = "The yard's ledger is offline: nothing was taken or paid.",
    coordinator_unavailable = "The yard's ledger is offline: nothing was taken or paid.",
    conflict = "The yard's ledger was busy: nothing was taken. Try again.",
    insufficient_items = "Those goods are not there any more.",
    mint_denied = "The yard is not configured to pay for scrap. Tell an admin.",
    mint_cap = "The buyer is out of cash for this hour.",
    mint_cap_exceeded = "The yard hit its hourly limit. Try again later.",
    namespace_denied = "The yard is not configured for this (server ledger rules). Tell an admin.",
}

-- Cancellation reasons are told in plainer words.
M.ENDS = {
    cancelled_by_player = "Stopped.",
    dead = "Interrupted.", disconnected = "Interrupted.", bucket_changed = "Interrupted.",
    vehicle = "Interrupted: you got in a vehicle.", combat = "Interrupted: weapon out.",
    moved = "Interrupted: you moved away.", animation_interrupted = "Interrupted.",
    superseded = "Replaced by a new action.", reserve_timeout = "The yard took too long to answer.",
    claim_lost = "Interrupted.", owner_stopped = "The yard closed.", resource_stopping = "Interrupted.",
}

function M.textFor(reason)
    reason = tostring(reason or "refused")
    return M.TEXT[reason] or M.ENDS[reason] or "That did not work. Try again in a moment."   -- never the raw code on screen; the server log keeps it
end

-- Coordinator refusals of a work reservation, mapped to what the player did wrong.
function M.workRefusal(reason)
    if reason == "capacity_exceeded" then return "crate_full" end
    if reason == "instance_unavailable" then return "tool_busy" end
    if reason == "mint_denied" or reason == "namespace_denied" or reason == "unknown_item" then
        return "salvage_not_configured"
    end
    return reason
end

return M
