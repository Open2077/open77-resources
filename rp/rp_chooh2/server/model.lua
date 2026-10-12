-- rp_chooh2 / server/model.lua: pure rules of the CHOOH2 chain. No native, no export: the offline
-- suite and the service use the same functions.
--
--   rollCount                     the corn one harvest yields, drawn from the operation id
--   crate ids and metadata        a corn crate is ONE coordinator world: container (its hold)
--   refineLines / deliverLines    the coordinator lines of a refining run and of a delivery
--   quote                         a canister sale and its split
--   fuelFill                      how much a canister pours into a tank, or why it does not
--   geometry                      the same yaw convention as open77_actions (0 faces +y)
--   refusal texts                 what a player reads for every typed refusal
--
-- Global: Chooh2Model.

Chooh2Model = {}
local M = Chooh2Model

M.META_VERSION = 1
M.APP = "rp_chooh2"

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

-- The count one harvest yields: uniform in min..max, drawn from `seedText` (the coordinator op
-- id), so a retried commit sends identical lines.
function M.rollCount(spec, seedText)
    local lo, hi = spec.min or 1, spec.max or spec.min or 1
    if hi < lo then hi = lo end
    local state = (1664525 * (M.hash(tostring(seedText)) & 0xFFFFFFFF) + 1013904223) & 0xFFFFFFFF
    return lo + (state % (hi - lo + 1))
end

function M.jobIn(job, list)
    if type(list) == "string" then return job == list end
    for _, name in ipairs(list or {}) do if name == job then return true end end
    return false
end

-- Count of an item a snapshot holds, minus what is reserved out of it (availability = count - held).
function M.available(snapshot, item)
    if type(snapshot) ~= "table" then return 0 end
    local have = type(snapshot.items) == "table" and (M.integer(snapshot.items[item]) or 0) or 0
    local held = type(snapshot.held) == "table" and type(snapshot.held.items) == "table"
        and (M.integer(snapshot.held.items[item]) or 0) or 0
    return math.max(0, have - held)
end

function M.countOf(snapshot, item)
    if type(snapshot) ~= "table" or type(snapshot.items) ~= "table" then return 0 end
    return M.integer(snapshot.items[item]) or 0
end

-- ---------------------------------------------------------------------------------------------
-- Crates: a crate IS a coordinator world: container (its hold). Corn enters at a harvest commit
-- and leaves at the delivery into the intake; the custody token (one `chooh2_crate` instance)
-- sits in the hold while the crate is on the ground or carried, and in `veh:<plate>:cargo` while
-- it rides in a bed.
-- ---------------------------------------------------------------------------------------------
function M.keyOf(holdId)
    return type(holdId) == "string" and holdId:match("^world:(.+)$") or nil
end

function M.tokenOf(holdId)
    local key = M.keyOf(holdId)
    return key and ("ch2crate." .. key) or nil
end

function M.holdOfToken(iid)
    local key = type(iid) == "string" and iid:match("^ch2crate%.(.+)$") or nil
    return key and ("world:" .. key) or nil
end

function M.isOurs(meta)
    return type(meta) == "table" and meta.app == M.APP and meta.kind == "crate"
end

-- The crate record kept in the hold's coordinator metadata (<= 2 KiB). `at` is the durable
-- placement; `deliver` the persisted delivery attempt (op id) while it is in flight.
function M.crateMeta(fields)
    return {
        app = M.APP, kind = "crate", v = M.META_VERSION,
        owner = fields.owner, node = fields.node, created = fields.created,
        at = fields.at and { x = fields.at.x, y = fields.at.y, z = fields.at.z } or nil,
        yaw = fields.yaw or 0.0, bucket = fields.bucket or 0,
        where = fields.where, deliver = fields.deliver and M.copy(fields.deliver) or nil,
    }
end

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
-- Coordinator lines
-- ---------------------------------------------------------------------------------------------
-- A harvest: the rolled corn into the crate, plus the crate token when the crate is new.
function M.harvestLines(cfg, r)
    local count = M.rollCount(cfg.harvest, r.txOpId)
    local lines = { { item = cfg.harvest.item, count = count, from = cfg.accounts.fields, to = r.crate,
        reason = "harvest " .. tostring(r.node) } }
    if r.isNew then
        lines[#lines + 1] = { instance = M.tokenOf(r.crate), item = "chooh2_crate", from = cfg.accounts.fields,
            to = r.crate, meta = { crate = r.crate, owner = r.subject }, reason = "corn crate" }
    end
    return lines, count
end

-- The heaviest harvest: the room a harvest reserves in the crate before the bar starts.
function M.maxHarvestG(cfg, isNew)
    local grams = (cfg.weightsG[cfg.harvest.item] or 0) * (cfg.harvest.max or cfg.harvest.min or 1)
    if isNew then grams = grams + cfg.weightsG.chooh2_crate end
    return grams
end

-- A delivery: every corn of the crate into the intake and the token back to its source, one
-- operation (the hold is then empty and can be closed).
function M.deliverLines(cfg, holdId, corn)
    local lines = {}
    if corn > 0 then
        lines[#lines + 1] = { item = cfg.harvest.item, count = corn, from = holdId, to = cfg.accounts.intake,
            reason = "intake" }
    end
    lines[#lines + 1] = { instance = M.tokenOf(holdId), from = holdId, to = cfg.accounts.retired, reason = "crate emptied" }
    return lines
end

-- A refining run: corn burned out of the intake, canisters minted into the output.
function M.refineLines(cfg)
    return {
        { item = cfg.harvest.item, count = cfg.refine.cornIn, from = cfg.accounts.intake, to = cfg.accounts.refinery,
          reason = "fermenter feed" },
        { item = "chooh2_canister", count = cfg.refine.canistersOut, from = cfg.accounts.refinery,
          to = cfg.accounts.output, reason = "CHOOH2 run" },
    }
end

-- ---------------------------------------------------------------------------------------------
-- Sale and refuel
-- ---------------------------------------------------------------------------------------------
-- quote(count, price, share) -> { count, total, society, seller } | nil, "no_canisters"
function M.quote(count, price, share)
    count = M.integer(count) or 0
    if count < 1 or not price or price < 1 then return nil, "no_canisters" end
    local total = count * price
    local society = math.floor(total * (share or 0))
    return { count = count, total = total, society = society, seller = total - society }
end

-- fuelFill(level, capacity, spec) -> litres poured | nil, "tank_full"
function M.fuelFill(level, capacity, spec)
    level, capacity = tonumber(level), tonumber(capacity)
    if not level or not capacity then return nil, "fuel_unavailable" end
    local room = capacity - level
    if room < (spec.minRoomL or 0) then return nil, "tank_full" end
    return math.min(room, spec.litres)
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
-- Refusals a player reads. Every typed refusal of the chain and of the libraries it composes has
-- a sentence; an unknown token is shown verbatim so nothing is silent.
-- ---------------------------------------------------------------------------------------------
M.TEXT = {
    -- this resource
    node_depleted = "This row is picked clean for now. Try another one, it grows back.",
    unknown_node = "Nothing to harvest here.",
    crate_full = "Your crate here is full: carry it to the truck first.",
    crate_busy = "Your crate is being filled already.",
    too_many_crates = "You already have too many crates out. Deliver or load some first.",
    farm_full = "The farm is full of crates. Clear some first.",
    crate_unavailable = "That crate is gone.",
    crate_empty = "That crate is empty.",
    not_crate_owner = "That crate is someone else's harvest.",
    already_delivered = "That crate was already emptied into the intake.",
    no_truck = "No truck you can load is parked here.",
    no_corn_crate = "No corn crate in that bed.",
    unknown_crate = "That crate is not one of the farm's.",
    intake_full = "The intake hopper is full: run a batch first.",
    intake_empty = "Not enough corn in the intake for a batch.",
    output_full = "The output rack is full: take canisters out first.",
    output_empty = "No canisters on the rack.",
    pockets_full = "Your pockets cannot hold that.",
    no_canisters = "You carry no CHOOH2 canister.",
    no_vehicle = "No car within reach to refuel.",
    vehicle_moving = "Stop the car first.",
    tank_full = "That tank is full.",
    fuel_unavailable = "The fuel gauge does not answer (open77_fuel is not running). Nothing was taken.",
    fuel_pending = "The canister is poured; the tank is being topped up.",
    wrong_office = "Clock in at your own employer's office.",
    chooh2_unavailable = "The plant's ledger is not ready. Try again in a moment.",
    chooh2_not_configured = "The plant is not configured for this (server ledger rules). Tell an admin.",
    in_doubt = "The plant is still confirming that. Give it a few seconds.",
    -- rp_jobs
    off_duty = "Clock in at your office first.",
    no_job = "You do not work on the CHOOH2 line. The employment agency hires farmhands and operators.",
    wrong_job = "That is not your job.",
    unknown_job = "The server has no farmhand or refinery job yet. Tell an admin.",
    stale_job_epoch = "Your job changed in the middle of it: nothing was done.",
    not_eligible = "You cannot do that now.",
    -- rp_garage / rp_cargo
    no_access = "You hold no key for that truck.",
    action_not_permitted = "You may not load that truck.",
    impounded = "That truck is impounded.",
    vehicle_not_tracked = "That vehicle has no plate on file: use a registered truck.",
    no_cargo_layout = "That vehicle has no cargo bed the farm knows.",
    cargo_full = "The bed is full.",
    too_far = "Get closer.",
    cargo_empty = "The bed is empty.",
    -- open77_actions
    target_claimed = "Someone is already working there.",
    destination_claimed = "Someone is already using that spot.",
    actor_busy = "Finish what you are doing first.",
    carrying = "Put the crate down first.",
    not_carrying = "You are not carrying a crate.",
    item_unavailable = "That crate is gone.",
    player_in_vehicle = "Get out of the vehicle first.",
    in_combat = "Not while fighting.",
    -- coordinator and wallet
    capacity_exceeded = "Not enough room for that.",
    insufficient_items = "Those goods are not there any more.",
    store_unavailable = "The plant's ledger is offline: nothing was taken or paid.",
    coordinator_unavailable = "The plant's ledger is offline: nothing was taken or paid.",
    conflict = "The plant's ledger was busy: nothing was taken. Try again.",
    mint_denied = "The plant is not configured to pay for that. Tell an admin.",
    mint_cap = "The depot is out of cash for this hour.",
    mint_cap_exceeded = "The plant hit its hourly limit. Try again later.",
    namespace_denied = "The plant is not configured for this (server ledger rules). Tell an admin.",
}

-- Cancellation reasons are told in plainer words.
M.ENDS = {
    cancelled_by_player = "Stopped.",
    dead = "Interrupted.", disconnected = "Interrupted.", bucket_changed = "Interrupted.",
    vehicle = "Interrupted: you got in a vehicle.", combat = "Interrupted: weapon out.",
    moved = "Interrupted: you moved away.", animation_interrupted = "Interrupted.",
    superseded = "Replaced by a new action.", reserve_timeout = "The plant took too long to answer.",
    claim_lost = "Interrupted.", owner_stopped = "The plant closed.", resource_stopping = "Interrupted.",
}

function M.textFor(reason)
    reason = tostring(reason or "refused")
    return M.TEXT[reason] or M.ENDS[reason] or "That did not work. Try again in a moment."   -- never the raw code on screen; the server log keeps it
end

-- Coordinator refusals of a harvest reservation, mapped to what the player did wrong.
function M.harvestRefusal(reason)
    if reason == "capacity_exceeded" then return "crate_full" end
    if reason == "mint_denied" or reason == "namespace_denied" or reason == "unknown_item" then
        return "chooh2_not_configured"
    end
    return reason
end

function M.deliverRefusal(reason)
    if reason == "capacity_exceeded" then return "intake_full" end
    if reason == "namespace_denied" or reason == "unknown_item" then return "chooh2_not_configured" end
    return reason
end

function M.refineRefusal(reason)
    if reason == "insufficient_items" then return "intake_empty" end
    if reason == "capacity_exceeded" then return "output_full" end
    if reason == "mint_denied" or reason == "namespace_denied" or reason == "unknown_item" then
        return "chooh2_not_configured"
    end
    return reason
end

function M.collectRefusal(reason)
    if reason == "insufficient_items" then return "output_empty" end
    if reason == "capacity_exceeded" then return "pockets_full" end
    if reason == "namespace_denied" then return "chooh2_not_configured" end
    return reason
end

function M.saleRefusal(reason)
    if reason == "insufficient_items" then return "no_canisters" end
    return reason
end

return M
