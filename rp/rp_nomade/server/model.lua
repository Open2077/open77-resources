-- rp_nomade / server/model.lua: pure rules of the smuggling run. No native, no export: the offline
-- suite and the service use the same functions.
--
--   ids               run keys, crate keys, token instance ids (all derived from one coordinator id)
--   crate records     the public metadata a crate carries in open77_containers (<= 1 KiB)
--   search roll       deterministic per run and checkpoint
--   prices            what the fence pays, the camp's cut, hot goods
--   geometry          the open77_actions yaw convention (0 faces +y), zone containment fallback
--   texts             what a player reads for every typed refusal
--
-- Global: NomadModel.

NomadModel = {}
local M = NomadModel

M.APP = "rp_nomade"
M.META_VERSION = 1

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

-- FNV-1a 32 over a string.
function M.hash(text)
    local h = 2166136261
    text = tostring(text)
    for i = 1, #text do
        h = h ~ text:byte(i)
        h = (h * 16777619) & 0xFFFFFFFF
    end
    return h
end

function M.money(n) return ("%d eddies"):format(math.floor(tonumber(n) or 0)) end

function M.minutesLeft(deadlineMs, nowMs)
    local left = (tonumber(deadlineMs) or 0) - (tonumber(nowMs) or 0)
    if left <= 0 then return 0 end
    return math.max(1, math.floor(left / 60000 + 0.5))
end

-- ---------------------------------------------------------------------------------------------
-- Ids. One run = one coordinator id (`<serverTag>.<boot>.<n>`); everything else derives from it.
--   run key    the coordinator id itself, a key the containers and the coordinator accept
--   crate key  `nmd.<run>.<i>`: the open77_containers key (per owner, never reused once closed)
--   token      `nmdc.<run>.<i>`: the crate's custody instance (<= 64 characters)
-- ---------------------------------------------------------------------------------------------
local SAFE = "^[A-Za-z0-9_.@%-]+$"

function M.runKeyOf(coordinatorId)
    if type(coordinatorId) ~= "string" then return nil end
    local key = coordinatorId:gsub(":", "_")
    if #key < 3 or #key > 40 or not key:match(SAFE) then return nil end
    return key
end

function M.crateKey(runKey, index) return ("nmd.%s.%d"):format(runKey, index) end
function M.tokenOf(runKey, index) return ("nmdc.%s.%d"):format(runKey, index) end

function M.isOurs(meta)
    return type(meta) == "table" and meta.app == M.APP and type(meta.run) == "string" and M.integer(meta.i) ~= nil
end

-- The crate record kept in the container's public metadata (open77_containers: 16 keys, depth 3,
-- 1 KiB). Immutable fields at creation; `f` (failed reason), `w` (plate hint), `p` (checkpoints
-- passed) and `s` (a persisted sale quote) change later.
function M.crateMeta(fields)
    return {
        app = M.APP, v = M.META_VERSION, run = fields.run, i = fields.i, n = fields.n,
        o = fields.owner, r = fields.route, d = fields.deadline, t = fields.created,
        f = fields.failed, w = fields.plate, p = fields.passed and M.copy(fields.passed) or nil,
        s = fields.sale and M.copy(fields.sale) or nil,
    }
end

-- The lines that put one crate's contents in place at the start of a run: goods out of the camp's
-- stash, the token minted.
function M.stockLines(cfg, crates, runKey, owner)
    local lines = {}
    for i, crateId in ipairs(crates) do
        lines[#lines + 1] = { item = cfg.goodsItem, count = cfg.goodsPerCrate, from = cfg.stash, to = crateId,
            reason = "nomad run " .. runKey }
        lines[#lines + 1] = { instance = M.tokenOf(runKey, i), item = cfg.tokenItem, from = cfg.tokens, to = crateId,
            meta = { run = runKey, i = i, owner = owner }, reason = "nomad crate" }
    end
    return lines
end

function M.capacityG(weightsG, goodsItem, tokenItem, goodsPerCrate)
    return (weightsG[goodsItem] or 0) * goodsPerCrate + (weightsG[tokenItem] or 0)
end

function M.goodsIn(snapshot, item)
    if type(snapshot) ~= "table" or type(snapshot.items) ~= "table" then return 0 end
    return M.integer(snapshot.items[item]) or 0
end

function M.tokenHere(snapshot, iid)
    return type(snapshot) == "table" and type(snapshot.instances) == "table" and snapshot.instances[iid] ~= nil
end

-- ---------------------------------------------------------------------------------------------
-- The checkpoint search: deterministic per run and checkpoint. Returns searched, roll (0..99).
-- ---------------------------------------------------------------------------------------------
function M.searchRoll(runKey, checkpointId)
    return M.hash(tostring(runKey) .. "|" .. tostring(checkpointId)) % 100
end

function M.searched(runKey, checkpointId, chance)
    local roll = M.searchRoll(runKey, checkpointId)
    return roll < (tonumber(chance) or 0), roll
end

-- ---------------------------------------------------------------------------------------------
-- What the fence pays for one crate.
--   live   the seller is of the crew (a nomad on duty) and the crate's run is live (not failed,
--          not past its deadline): the full price, `campCut` to the camp, the rest to the run's
--          nomad, a delivery counted.
--   hot    anything else (a thief, a failed or late run): `hotRatio` of the price to the seller,
--          nothing to the camp, no delivery. A ratio of 0 refuses.
-- Returns { total, owner, cut, hot } | nil, "hot_refused".
-- ---------------------------------------------------------------------------------------------
function M.fenceQuote(price, live, campCut, hotRatio)
    price = math.max(0, math.floor(tonumber(price) or 0))
    if live then
        local cut = math.floor(price * (tonumber(campCut) or 0))
        return { total = price, owner = price - cut, cut = cut, hot = false }
    end
    local hot = math.floor(price * (tonumber(hotRatio) or 0))
    if hot < 1 then return nil, "hot_refused" end
    return { total = hot, owner = hot, cut = 0, hot = true }
end

-- A player buyer pays `price`: the camp cut when the run is live and the seller of the crew.
function M.playerQuote(price, live, campCut)
    price = math.max(0, math.floor(tonumber(price) or 0))
    local cut = live and math.floor(price * (tonumber(campCut) or 0)) or 0
    return { total = price, owner = price - cut, cut = cut, hot = not live }
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

-- The spot behind a truck's bed where a player stands to load or unload: centred on the bed,
-- `behind` metres past its rearmost slot, at the truck's own height (where the player's feet are:
-- the prompt's reach is measured from them; the card is lifted by the target's prompt height).
-- `layout` is rp_cargo's (vehicle frame: x right, y forward, z up); `car` carries x, y, z, yaw. nil
-- without slots.
function M.tailgate(car, layout, behind)
    local slots = type(layout) == "table" and layout.slots
    if type(car) ~= "table" or type(slots) ~= "table" or #slots == 0 then return nil end
    local rear
    for _, s in ipairs(slots) do
        local y = tonumber(s.y)
        if y and (rear == nil or y < rear) then rear = y end
    end
    if rear == nil then return nil end
    local ly = rear - (tonumber(behind) or 1.0)
    local r = math.rad(tonumber(car.yaw) or 0.0)
    return { x = car.x - math.sin(r) * ly, y = car.y + math.cos(r) * ly, z = car.z }
end

function M.compass(from, to)
    local angle = math.deg(math.atan(to.y - from.y, to.x - from.x))   -- 0 = east, 90 = north
    local names = { "east", "north-east", "north", "north-west", "west", "south-west", "south", "south-east" }
    return names[math.floor(((angle + 360 + 22.5) % 360) / 45) + 1] or "?"
end

-- Containment fallback for a zone definition, used when Open77.zones is not there: `cylinder`
-- (planar radius, `maxHeight` either side of z, default 6) and `sphere`.
function M.inZone(zone, point)
    if type(zone) ~= "table" or type(point) ~= "table" or type(zone.position) ~= "table" then return false end
    local r = tonumber(zone.radius) or 0
    if zone.shape == "sphere" then
        local d = M.distance(zone.position, point)
        return d ~= nil and d <= r
    end
    local d = M.planar(zone.position, point)
    if not d or d > r then return false end
    local band = tonumber(zone.maxHeight) or 6.0
    return math.abs((point.z or 0) - (zone.position.z or 0)) <= band
end

-- ---------------------------------------------------------------------------------------------
-- Refusals a player reads. An unknown token reads "That did not work. Try again in a moment."
-- (never the raw code on screen); the server log keeps it.
-- ---------------------------------------------------------------------------------------------
M.TEXT = {
    -- this resource
    nomad_unavailable = "The camp's ledger is not ready. Try again in a moment.",
    nomad_not_configured = "The camp is not configured for this (server ledger rules). Tell an admin.",
    unknown_route = "That run is not on the board any more.",
    run_running = "You already have a run going. /nomad status.",
    camp_empty = "The camp has nothing to move right now. Come back after the next supply drop.",
    camp_full = "Too many crates are out already. Bring some home first.",
    crate_unavailable = "That crate is gone.",
    crate_busy = "Someone is already dealing with that crate.",
    crate_empty = "That crate is empty.",
    not_crew = "Only the crew lifts these crates.",
    no_truck = "No truck you hold a key for is parked here.",
    no_nomad_crate = "No crate of the camp in that bed.",
    hot_refused = "The fence does not touch hot goods.",
    not_camp_crate = "That is not one of the camp's crates.",
    nothing_to_search = "Nothing to search here.",
    not_police = "Only an NCPD officer on duty can search a truck.",
    consent_needed = "No warrant on that plate: the driver or the run's nomad has to consent, on foot, next to you.",
    declined = "They refused the search.",
    no_buyer = "That player is not here.",
    bad_price = "Name a price between the camp's limits.",
    no_crate_here = "Put the crate down next to you first, then make the offer.",
    in_doubt = "The camp is still confirming that. Give it a few seconds.",
    -- rp_jobs
    off_duty = "Clock in first (/service).",
    no_job = "Nomad work only, choom. Sign up at the agency.",
    wrong_job = "Nomad work only, choom.",
    stale_job_epoch = "Your job changed in the middle of it: nothing was done.",
    not_eligible = "You cannot do that now.",
    -- rp_garage / rp_cargo
    no_access = "You hold no key for that truck.",
    action_not_permitted = "You may not use that truck's bed.",
    impounded = "That truck is impounded.",
    vehicle_not_tracked = "That vehicle has no plate on file: use a registered truck.",
    no_cargo_layout = "That vehicle has no bed the camp knows.",
    cargo_full = "The bed is full.",
    cargo_empty = "The bed is empty.",
    too_far = "Get closer.",
    vehicle_moving = "Stop the truck first.",
    warrant_required = "No warrant on that plate.",
    -- open77_actions
    target_claimed = "Someone is already using that spot.",
    destination_claimed = "Someone is already using that spot.",
    actor_busy = "Finish what you are doing first.",
    carrying = "Put the crate down first.",
    not_carrying = "You are not carrying a crate.",
    item_unavailable = "That crate is gone.",
    player_in_vehicle = "Get out of the vehicle first.",
    in_combat = "Not while fighting.",
    player_reserved = "One of you is busy with something else.",
    destination_too_far = "Get closer to the truck's bed.",
    weapon_drawn = "Put your weapon away first: you need both hands for the crate.",
    destination_invalid = "You cannot put it down there.",
    vehicle_unavailable = "That truck is not here any more.",
    wrong_bucket = "That is not here.",
    position_unavailable = "Not ready yet. Try again in a second.",
    position_stale = "Not ready yet. Try again in a second.",
    player_unavailable = "Not ready yet. Try again in a second.",
    player_not_ready = "Not ready yet. Try again in a second.",
    player_not_alive = "Not while you are down.",
    attach_failed = "Your hands slipped. Try again.",
    animation_refused = "Your hands slipped. Try again.",
    refused_by_owner = "The camp refused that.",
    hook_failed = "The camp refused that.",
    cancelled = "Cancelled.", cancelled_by_player = "Cancelled.",
    unknown_target = "That is not here any more.", invalid_target = "That is not here any more.",
    unknown_action = "That is not available any more.", invalid_action = "That is not available any more.",
    -- coordinator and wallet
    insufficient_items = "Those goods are not there any more.",
    insufficient_funds = "Not enough eddies.",
    capacity_exceeded = "Not enough room for that.",
    store_unavailable = "The camp's ledger is offline: nothing moved.",
    coordinator_unavailable = "The camp's ledger is offline: nothing moved.",
    conflict = "The camp's ledger was busy: nothing moved. Try again.",
    mint_denied = "The camp is not configured to pay for this. Tell an admin.",
    mint_cap = "The fence is out of cash for this hour.",
    mint_cap_exceeded = "The camp hit its hourly limit. Try again later.",
    namespace_denied = "The camp is not configured for this (server ledger rules). Tell an admin.",
}

M.ENDS = {
    cancelled_by_player = "Stopped.",
    dead = "Interrupted.", disconnected = "Interrupted.", bucket_changed = "Interrupted.",
    vehicle = "Interrupted: you got in a vehicle.", combat = "Interrupted: weapon out.",
    moved = "Interrupted: you moved away.", animation_interrupted = "Interrupted.",
    superseded = "Replaced by a new action.", reserve_timeout = "The camp took too long to answer.",
    claim_lost = "Interrupted.", owner_stopped = "The camp closed.", resource_stopping = "Interrupted.",
}

function M.textFor(reason)
    reason = tostring(reason or "refused")
    return M.TEXT[reason] or M.ENDS[reason] or "That did not work. Try again in a moment."   -- never the raw code on screen; the server log keeps it
end

-- Coordinator refusals of the run's stock reservation, mapped to what the player reads.
function M.takeRefusal(reason)
    if reason == "insufficient_items" then return "camp_empty" end
    if reason == "mint_denied" or reason == "namespace_denied" or reason == "unknown_item"
        or reason == "unknown_account" then
        return "nomad_not_configured"
    end
    return reason
end

return M
