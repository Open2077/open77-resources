-- rp_fixer / server/model.lua: the pure rules of the contract board. No native, no export, no
-- yield: everything here is a function of its arguments, so the offline suite can test it alone.
--
-- A contract lives through these states (durable in SQL, see server/store.lua):
--
--   posting    the record exists, the escrow operation is on its way
--   open       escrowed and on the board (an open bounty can be hunted by anyone)
--   taken      a runner holds it (claimed contracts only)
--   paying     the outcome is "completed": the payout out of escrow is being sent
--   refunding  the outcome is "expired" | "cancelled" | "spoiled": the refund is being sent
--   completed | expired | cancelled | spoiled    settled for good
--   void       the escrow never happened (refused or fenced): nothing moved
--
-- Global: FixerModel.

FixerModel = {}
local M = FixerModel

M.LIVE = { posting = true, open = true, taken = true, paying = true, refunding = true }
M.FINAL = { completed = true, expired = true, cancelled = true, spoiled = true, void = true }
M.KIND_LABEL = { delivery = "Delivery", retrieval = "Retrieval", job = "Job order", bounty = "Bounty" }
M.KIND_ICON = { delivery = "D", retrieval = "R", job = "J", bounty = "B" }
M.OUTCOME_STATE = { completed = "completed", expired = "expired", cancelled = "cancelled", spoiled = "spoiled" }

-- ---------------------------------------------------------------------------------------------
-- Small helpers
-- ---------------------------------------------------------------------------------------------
function M.playerId(value)
    local n = tonumber(value)
    if n == nil or n < 1 or n ~= math.floor(n) or n > 2147483647 then return nil end
    return math.tointeger(n)
end

function M.int(value, default)
    local n = tonumber(value)
    if n == nil or n ~= n then return default end
    return math.tointeger(math.floor(n)) or default
end

function M.distance(a, b)
    if type(a) ~= "table" or type(b) ~= "table" then return nil end
    local ax, ay, az = tonumber(a.x), tonumber(a.y), tonumber(a.z) or 0
    local bx, by, bz = tonumber(b.x), tonumber(b.y), tonumber(b.z) or 0
    if not ax or not ay or not bx or not by then return nil end
    local dx, dy, dz = ax - bx, ay - by, az - bz
    return math.sqrt(dx * dx + dy * dy + dz * dz)
end

function M.copy(value, depth)
    depth = depth or 0
    if type(value) ~= "table" or depth > 8 then return value end
    local out = {}
    for k, v in pairs(value) do out[k] = M.copy(v, depth + 1) end
    return out
end

-- Plain printable ASCII only (prompt cards and the chat render it everywhere), trimmed.
function M.ascii(text, max)
    if type(text) ~= "string" then return "" end
    local out = text:gsub("%c", " "):gsub("[^\32-\126]", ""):gsub("^%s+", ""):gsub("%s+$", ""):gsub("%s%s+", " ")
    if max and #out > max then out = out:sub(1, max) end
    return out
end

-- 1200 -> "1,200 eddies"
function M.money(amount)
    local n = math.floor(tonumber(amount) or 0)
    local s = tostring(math.abs(n))
    local grouped = s:reverse():gsub("(%d%d%d)", "%1,"):reverse():gsub("^,", "")
    return (n < 0 and "-" or "") .. grouped .. " eddies"
end

function M.duration(seconds)
    seconds = math.max(0, math.floor(tonumber(seconds) or 0))
    if seconds >= 3600 then return ("%d h %02d min"):format(seconds // 3600, (seconds % 3600) // 60) end
    if seconds >= 60 then return ("%d min"):format(seconds // 60) end
    return ("%d s"):format(seconds)
end

function M.code(c) return "#" .. tostring(c and c.seq or "?") end

-- ---------------------------------------------------------------------------------------------
-- Reputation
-- ---------------------------------------------------------------------------------------------
function M.tierOf(score, tiers)
    local index, tier = 1, tiers[1]
    for i, t in ipairs(tiers) do
        if (score or 0) >= t.min then index, tier = i, t end
    end
    return index, tier
end

-- The tier a minimum score asks for (the highest tier whose min <= minRep).
function M.tierFor(minRep, tiers)
    local _, tier = M.tierOf(minRep or 0, tiers)
    return tier
end

-- The new score after a delta, floored.
function M.applyDelta(score, delta, floor)
    return math.max(floor or 0, (score or 0) + (delta or 0))
end

-- ---------------------------------------------------------------------------------------------
-- Money
-- ---------------------------------------------------------------------------------------------
-- The fixers' cut and the runner's net of a gross reward.
function M.split(reward, rate)
    reward = M.int(reward, 0)
    rate = tonumber(rate) or 0
    if rate < 0 then rate = 0 end
    if rate > 0.9 then rate = 0.9 end
    local cut = math.floor(reward * rate + 0.5)
    return reward - cut, cut
end

-- A player's chosen reward, snapped to the step and checked against the template's range.
function M.chooseReward(t, value, step)
    local n = tonumber(value)
    if n == nil then return nil, "invalid_reward" end
    step = step or 1
    n = math.floor(n / step + 0.5) * step
    if n < t.reward.min or n > t.reward.max then return nil, "reward_out_of_range" end
    return math.tointeger(n)
end

-- A fixer NPC's reward: uniform in range, snapped to the step.
function M.npcReward(t, roll, step)
    step = step or 1
    local span = math.max(0, math.floor((t.reward.max - t.reward.min) / step))
    local pick = t.reward.min + math.floor((roll or 0) * (span + 1)) * step
    if pick > t.reward.max then pick = t.reward.max end
    return math.tointeger(pick)
end

-- ---------------------------------------------------------------------------------------------
-- Templates (checked once at start; a bad one is left out and logged)
-- ---------------------------------------------------------------------------------------------
function M.checkTemplate(id, t, cfg)
    if type(id) ~= "string" or #id > 32 or not id:match("^[a-z0-9_]+$") then return "bad_id" end
    if type(t) ~= "table" or not M.KIND_LABEL[t.kind] then return "bad_kind" end
    if type(t.reward) ~= "table" or not M.int(t.reward.min) or not M.int(t.reward.max)
        or t.reward.min < 1 or t.reward.max < t.reward.min then return "bad_reward" end
    if not tonumber(t.hours) or t.hours <= 0 then return "bad_hours" end
    if type(t.posters) ~= "table" or not (t.posters.npc or t.posters.player) then return "bad_posters" end
    if t.kind == "delivery" then
        if not (cfg.points[t.from]) then return "unknown_pickup" end
        if not (cfg.hubs[t.to] or cfg.drops[t.to]) then return "unknown_drop" end
    elseif t.kind == "retrieval" then
        if type(t.item) ~= "string" or not t.item:match("^[a-z0-9_]+$") then return "bad_item" end
        if not M.int(t.count) or t.count < 1 or t.count > 1000 then return "bad_count" end
        if not cfg.hubs[t.drop] then return "unknown_drop" end
    elseif t.kind == "job" then
        if type(t.job) ~= "string" or t.job == "" then return "bad_job" end
        if type(t.kinds) ~= "table" or #t.kinds < 1 then return "bad_job_kinds" end
        if not M.int(t.count) or t.count < 1 or t.count > 100 then return "bad_count" end
    elseif t.kind == "bounty" then
        if not cfg.sightings[t.sighting] then return "unknown_sighting" end
        if t.mode ~= "open" and t.mode ~= "claimed" then return "bad_mode" end
        if t.onForeignKill ~= nil and t.onForeignKill ~= "refund" and t.onForeignKill ~= "respawn" then
            return "bad_foreign_kill"
        end
    end
    return nil
end

-- ---------------------------------------------------------------------------------------------
-- Contracts
-- ---------------------------------------------------------------------------------------------
-- args = { id, seq, templateId, template, hub, poster = { kind, subject?, name }, reward, hours,
--          brief?, mode?, now, cutRate, cfg }
function M.newContract(args)
    local t, cfg = args.template, args.cfg
    local net, cut = M.split(args.reward, args.cutRate)
    local c = {
        id = args.id, seq = args.seq, template = args.templateId, kind = t.kind,
        title = t.title, brief = (args.brief and args.brief ~= "") and args.brief or t.brief,
        hub = args.hub, poster = M.copy(args.poster),
        reward = args.reward, net = net, cut = cut,
        minRep = M.int(t.minRep, 0), repGain = M.int(t.repGain, 1),
        state = "posting", postedAt = args.now,
        expiresAt = args.now + math.floor((args.hours or t.hours) * 3600 + 0.5),
        takes = 0,
        ops = {
            escrow = "fixer.esc:" .. args.id,
            pay = "fixer.pay:" .. args.id,
            refund = "fixer.ref:" .. args.id,
            items = "fixer.ret:" .. args.id,
            attempt = 1,
        },
    }
    if t.kind == "delivery" then
        local from = cfg.points[t.from]
        c.route = { from = t.from, to = t.to }
        c.crate = { position = M.copy(from.position), yaw = from.yaw or 0.0, carried = false }
    elseif t.kind == "retrieval" then
        c.want = { item = t.item, count = t.count, drop = t.drop }
    elseif t.kind == "job" then
        c.order = { job = t.job, kinds = M.copy(t.kinds), count = t.count, match = M.copy(t.match),
                    countField = t.countField, progress = 0, refs = {} }
    elseif t.kind == "bounty" then
        local mode = args.mode or t.mode
        c.mode = mode
        c.target = { sighting = t.sighting, onForeignKill = t.onForeignKill or "refund" }
    end
    c.mode = c.mode or "claimed"
    return c
end

-- The current operation id of a payout or refund (a fenced id moves to the next attempt).
function M.payOpId(c)
    local base = c.state == "refunding" and c.ops.refund or c.ops.pay
    local attempt = M.int(c.ops.attempt, 1)
    if attempt <= 1 then return base end
    return base .. ":" .. attempt
end

-- Whether `viewer` ({ subject, score, held }) may take `c`; nil when allowed, else a reason.
function M.takeRefusal(c, viewer, cfg, now)
    if c.state ~= "open" then return "contract_unavailable" end
    if now >= c.expiresAt then return "contract_expired" end
    if c.mode == "open" then return "open_bounty" end
    if c.poster and c.poster.subject and c.poster.subject == viewer.subject then return "own_contract" end
    if (viewer.score or 0) < (c.minRep or 0) then return "reputation_too_low" end
    if (viewer.held or 0) >= cfg.maxPerRunner then return "too_many_contracts" end
    return nil
end

-- Whether a viewer sees a contract on the board.
function M.visibleTo(c, subject)
    if c.state == "open" then return true end
    if c.state == "taken" then
        return (c.runner and c.runner.subject == subject) or (c.poster and c.poster.subject == subject) or false
    end
    if c.state == "posting" or c.state == "paying" or c.state == "refunding" then
        return (c.poster and c.poster.subject == subject) or (c.runner and c.runner.subject == subject) or false
    end
    return false
end

-- How many units a job event adds to a job-order contract, or nil and why it does not count.
-- ev = { job, kind, playerId, ref, data }
function M.jobIncrement(c, ev)
    if c.kind ~= "job" or c.state ~= "taken" then return nil, "not_a_job_order" end
    local o = c.order
    if ev.job ~= o.job then return nil, "other_job" end
    local kindOk = false
    for _, k in ipairs(o.kinds or {}) do
        if k == "*" or k == ev.kind then kindOk = true break end
    end
    if not kindOk then return nil, "other_kind" end
    for field, want in pairs(o.match or {}) do
        local got = type(ev.data) == "table" and ev.data[field] or nil
        if tostring(got) ~= tostring(want) then return nil, "no_match" end
    end
    for _, seen in ipairs(o.refs or {}) do
        if seen == ev.ref then return nil, "duplicate_ref" end
    end
    local inc = 1
    if o.countField and type(ev.data) == "table" then
        local n = M.int(ev.data[o.countField])
        if n and n >= 1 and n <= 1000 then inc = n end
    end
    return inc
end

-- The job-event payload as received, checked; nil and why for anything malformed.
function M.normalizeJobEvent(payload)
    if type(payload) ~= "table" then return nil, "invalid_payload" end
    local job, kind, ref = payload.job, payload.kind, payload.ref
    if type(job) ~= "string" or job == "" or #job > 32 then return nil, "invalid_job" end
    if type(kind) ~= "string" or kind == "" or #kind > 48 then return nil, "invalid_kind" end
    if type(ref) ~= "string" or ref == "" or #ref > 128 then return nil, "invalid_ref" end
    local pid = M.playerId(payload.playerId)
    if not pid then return nil, "invalid_player" end
    return { job = job, kind = kind, ref = ref, playerId = pid,
             data = type(payload.data) == "table" and payload.data or {} }
end

-- Where the runner should go next: { label, position, sprite } or nil (job orders have none).
function M.objectiveOf(c, cfg)
    if c.state ~= "taken" then return nil end
    if c.kind == "delivery" then
        if c.crate and c.crate.carried then
            local drop = cfg.hubs[c.route.to] or cfg.drops[c.route.to]
            return drop and { label = "Deliver the crate: " .. drop.label, position = M.copy(drop.position), sprite = "objective" }
        end
        return c.crate and { label = "Pick up the crate: " .. cfg.points[c.route.from].label,
            position = M.copy(c.crate.position), sprite = "objective" }
    elseif c.kind == "retrieval" then
        local hub = cfg.hubs[c.want.drop]
        return hub and { label = "Hand over at " .. hub.label, position = M.copy(hub.position), sprite = "objective" }
    elseif c.kind == "bounty" then
        local s = M.sighting(c, cfg)
        return s and { label = "Cyberpsycho: " .. s.label, position = M.copy(s.position), sprite = "BountyHuntVariant" }
    end
    return nil
end

-- The sighting of a bounty: the one it was posted with, or its template's current one when an
-- operator renamed the sighting since (a saved contract keeps the old key); nil when neither is
-- configured.
function M.sighting(c, cfg)
    local key = c.target and c.target.sighting
    if key and cfg.sightings[key] then return cfg.sightings[key], key end
    local t = cfg.templates[c.template or ""]
    key = t and t.sighting
    if key and cfg.sightings[key] then return cfg.sightings[key], key end
    return nil
end

-- One line of progress for /contract.
function M.progressLine(c, cfg, now)
    local left = M.duration((c.expiresAt or now) - now)
    if c.kind == "delivery" then
        local drop = cfg.hubs[c.route.to] or cfg.drops[c.route.to]
        local where = c.crate and c.crate.carried and ("carry it to " .. (drop and drop.label or "?"))
            or ("pick it up at " .. cfg.points[c.route.from].label)
        return ("%s %s: %s, %s left."):format(M.code(c), c.title, where, left)
    elseif c.kind == "retrieval" then
        return ("%s %s: bring %d x %s to %s, %s left."):format(M.code(c), c.title, c.want.count,
            c.want.label or c.want.item, cfg.hubs[c.want.drop].label, left)
    elseif c.kind == "job" then
        return ("%s %s: %d / %d done, %s left."):format(M.code(c), c.title, c.order.progress or 0, c.order.count, left)
    elseif c.kind == "bounty" then
        local s = M.sighting(c, cfg)
        return ("%s %s: %s, %s left."):format(M.code(c), c.title, s and s.label or "sighting unknown", left)
    end
    return ("%s %s"):format(M.code(c), c.title)
end

-- A small copy for exports and events (no internals).
function M.summary(c)
    if type(c) ~= "table" then return nil end
    return {
        id = c.id, seq = c.seq, kind = c.kind, template = c.template, title = c.title, state = c.state,
        outcome = c.outcome, hub = c.hub, reward = c.reward, net = c.net, cut = c.cut, minRep = c.minRep,
        mode = c.mode, expiresAt = c.expiresAt, poster = c.poster and c.poster.name or nil,
        runner = c.runner and c.runner.name or nil,
        progress = c.order and c.order.progress or nil, count = (c.order and c.order.count) or (c.want and c.want.count) or nil,
    }
end

-- ---------------------------------------------------------------------------------------------
-- Player-facing sentences for refusal tokens (plain ASCII).
-- ---------------------------------------------------------------------------------------------
M.TEXT = {
    not_ready = "The board is not ready yet. Try again in a moment.",
    store_unavailable = "The fixer's ledger is offline. Try again in a moment.",
    database_unavailable = "The fixer's ledger is offline. Try again in a moment.",
    not_loaded = "The fixer does not know you yet. Wait a moment, then try again.",
    too_far = "Talk to a fixer: stand at a fixer point.",
    contract_unavailable = "That contract is gone.",
    contract_expired = "That contract ran out.",
    open_bounty = "Open bounty: nobody takes it. Find the target, the kill pays.",
    own_contract = "You posted that one yourself.",
    reputation_too_low = "Your reputation is too low for that one.",
    too_many_contracts = "You already hold as many contracts as the fixers trust you with.",
    not_your_contract = "That is not your contract.",
    contract_taken = "A runner is on it: it cannot be cancelled now.",
    not_a_fixer = "Only a fixer on duty posts contracts.",
    off_duty = "Clock in as a fixer first.",
    no_job = "Only a fixer on duty posts contracts.",
    wrong_job = "Only a fixer on duty posts contracts.",
    board_full = "The board is full. Wait for a contract to close.",
    poster_limit = "You already have as many contracts posted as the board takes from one fixer.",
    unknown_template = "Unknown contract type.",
    not_posted_here = "Players do not post that contract type.",
    reward_out_of_range = "That reward is outside the range for this contract.",
    invalid_reward = "Give the reward as a number.",
    invalid_hours = "Pick one of the offered durations.",
    unknown_item = "That item is not known on this server.",
    insufficient_funds = "You do not have the eddies to back that contract.",
    insufficient_items = "You do not have everything the contract asks for.",
    capacity_exceeded = "Your pockets are full.",
    escrow_pending = "The escrow is still settling: the contract goes up as soon as it clears.",
    no_retrieval_here = "None of your contracts are handed over here.",
    already_handed = "The goods were already handed over: the payout is on its way.",
    not_your_crate = "That crate is for another runner.",
    contract_closed = "That contract is closed.",
    wrong_drop = "This is not where the crate goes.",
    rp_economy_unavailable = "The bank is offline. Try again in a moment.",
    coordinator_unavailable = "The ledger is offline. Try again in a moment.",
    mint_denied = "The fixer cannot fund this board right now (operator: rp_economy mint rule).",
    mint_cap = "The fixer has posted enough for this hour.",
    namespace_denied = "The ledger refuses the move (operator: open77_transactions writers).",
}

function M.textFor(reason)
    return M.TEXT[reason] or "That did not work. Try again in a moment."   -- never the raw code on screen; the server log keeps it
end

return M
