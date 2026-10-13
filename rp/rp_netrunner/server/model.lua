-- rp_netrunner / server/model.lua: pure rules of the contract job. No native, no export: the
-- offline suite and the service use the same functions.
--
--   ids               a contract is ONE coordinator instance `nrc.<id>` on the board; its shard is
--                     `nrs.<id>`; the short code players type is derived from the id
--   chance / roll     the breach odds (tier, rp_jobs grade, attempts) and the roll drawn from the
--                     breach's operation id (identical on every retry of that operation)
--   records           the contract's metadata, its patches, its public summary
--   failure           what a failed breach does to the contract (config mode, attempts)
--   pay               the reward, the fixer's cut, the delivery sale (one rp_economy operation)
--   texts             what a player reads for every refusal
--
-- Global: NetrunnerModel.

NetrunnerModel = {}
local M = NetrunnerModel

M.RECORD_VERSION = 1

-- ---------------------------------------------------------------------------------------------
-- Small helpers
-- ---------------------------------------------------------------------------------------------
function M.integer(value)
    local n = tonumber(value)
    if not n or n ~= n or n == math.huge or n == -math.huge or n % 1 ~= 0 then return nil end
    return math.tointeger(n)
end

function M.playerId(value)
    local n = M.integer(value)
    if not n or n < 1 or n > 2147483647 then return nil end
    return n
end

function M.distance(a, b)
    if type(a) ~= "table" or type(b) ~= "table" or not a.x or not b.x then return nil end
    local dx, dy, dz = a.x - b.x, a.y - b.y, (a.z or 0) - (b.z or 0)
    return math.sqrt(dx * dx + dy * dy + dz * dz)
end

function M.copy(value, depth)
    depth = depth or 0
    if type(value) ~= "table" or depth > 8 then return value end
    local out = {}
    for k, v in pairs(value) do out[k] = M.copy(v, depth + 1) end
    return out
end

-- FNV-1a 32 over a string: the seed of the deterministic breach roll and of contract codes.
function M.hash(text)
    local h = 2166136261
    text = tostring(text)
    for i = 1, #text do
        h = h ~ text:byte(i)
        h = (h * 16777619) & 0xFFFFFFFF
    end
    return h
end

local DIGITS = "0123456789ABCDEFGHJKLMNPQRSTUVWXYZ"   -- no I or O: they read as 1 and 0

local function base(n, width)
    local out = {}
    for _ = 1, width do
        local d = n % #DIGITS
        table.insert(out, 1, DIGITS:sub(d + 1, d + 1))
        n = n // #DIGITS
    end
    return table.concat(out)
end

-- ---------------------------------------------------------------------------------------------
-- Ids
-- ---------------------------------------------------------------------------------------------
-- A contract id is the coordinator's newOpId (`<tag>-<boot>-<n>`): unique among the servers that
-- share the database, never reused. The instance and op ids are derived from it.
function M.validContractId(id)
    return type(id) == "string" and #id >= 3 and #id <= 48 and id:match("^[A-Za-z0-9_.%-]+$") ~= nil
end

function M.contractIid(id) return "nrc." .. id end
function M.shardIid(id) return "nrs." .. id end

function M.contractIdOfIid(iid)
    return type(iid) == "string" and iid:match("^nrc%.(.+)$") or nil
end

-- The short code players type (`/netrun take K7Q2`): 4 characters from the id, longer when an
-- active contract already uses it. Stored in the record at posting, so it survives a restart.
function M.codeFor(id, used)
    used = used or {}
    local h = M.hash(id)
    for width = 4, 8 do
        local code = base(h, width)
        if not used[code] then return code end
        h = M.hash(id .. "#" .. width)
    end
    return base(M.hash(id .. "#last"), 10)
end

function M.normalizeCode(text)
    if type(text) ~= "string" then return nil end
    text = text:upper():gsub("[^0-9A-Z]", "")
    if #text < 3 or #text > 10 then return nil end
    return text
end

-- Business operation ids (8..96 characters of [A-Za-z0-9_.:@-]).
function M.opId(kind, id) return ("nr.%s:%s"):format(kind, id) end
function M.deliverOpId(id, attempt) return ("nr.deliver:%s.a%d"):format(id, attempt or 1) end

-- ---------------------------------------------------------------------------------------------
-- Breach odds
-- ---------------------------------------------------------------------------------------------
-- chance in percent: the tier's base, plus the grade bonus, minus the retry penalty, clamped.
function M.breachChance(tier, difficulty, grade, attempts)
    difficulty = difficulty or {}
    local chance = (tier and tier.baseChance or 50) + (difficulty.gradeBonus or 0) * math.max(0, M.integer(grade) or 0)
        - (difficulty.retryPenalty or 0) * math.max(0, M.integer(attempts) or 0)
    chance = math.max(difficulty.minChance or 1, math.min(difficulty.maxChance or 100, chance))
    return math.max(0, math.min(100, math.floor(chance)))
end

-- 1..100 from the operation id: the same operation always rolls the same number.
function M.breachRoll(seed) return (M.hash(seed) % 100) + 1 end

function M.breachSucceeds(seed, chance) return M.breachRoll(seed) <= chance end

-- ---------------------------------------------------------------------------------------------
-- Pay
-- ---------------------------------------------------------------------------------------------
function M.cutOf(reward, rate)
    reward = M.integer(reward) or 0
    rate = tonumber(rate) or 0
    if rate <= 0 or reward <= 0 then return 0 end
    return math.min(reward, math.floor(reward * rate + 0.5))
end

-- A reward asked for by a player fixer: an integer inside the tier's bounds (nil = the default).
function M.reward(tier, value)
    local bounds = tier.reward
    if value == nil then return bounds.default end
    local n = M.integer(value)
    if not n or n < bounds.min or n > bounds.max then return nil, "invalid_reward" end
    return n
end

function M.minutes(tier, value)
    local bounds = tier.minutes
    if value == nil then return bounds.default end
    local n = M.integer(value)
    if not n or n < bounds.min or n > bounds.max then return nil, "invalid_deadline" end
    return n
end

-- The NPC fixer's reward: drawn inside the bounds from a seed, rounded.
function M.npcReward(tier, seed, round)
    local bounds = tier.reward
    round = math.max(1, M.integer(round) or 1)
    local span = math.max(0, bounds.max - bounds.min)
    local raw = bounds.min + (M.hash(seed) % (span + 1))
    local value = math.floor(raw / round + 0.5) * round
    return math.max(bounds.min, math.min(bounds.max, value))
end

-- The ONE delivery operation (rp_economy sale): the shard leaves the netrunner's pockets to the
-- client (a sys buyer: burned), the client's money is created and split between the netrunner and
-- the fixer's cut. The id is per contract and attempt, so a retry or a replay pays once.
function M.deliverySale(o)
    local payees = {}
    local net = o.reward - (o.cut or 0)
    if net > 0 then payees[#payees + 1] = { subject = o.taker, amount = net } end
    if (o.cut or 0) > 0 and o.cutTo then
        local p = M.copy(o.cutTo)
        p.amount = o.cut
        payees[#payees + 1] = p
    elseif (o.cut or 0) > 0 then
        payees[#payees + 1] = { subject = o.taker, amount = o.cut }   -- nobody to take it: the runner keeps it
    end
    return {
        opId = o.opId,
        seller = o.sellerPid and { player = o.sellerPid } or { subject = o.taker },
        buyer = { sys = o.buyer or "client" },
        items = { { instance = o.shard, from = o.pockets } },
        total = o.reward,
        payees = payees,
        reason = o.reason,
    }
end

-- ---------------------------------------------------------------------------------------------
-- Records (the board instance's metadata)
-- ---------------------------------------------------------------------------------------------
function M.newContract(f)
    return {
        v = M.RECORD_VERSION, app = "rp_netrunner",
        id = f.id, code = f.code, site = f.site, tier = f.tier,
        reward = f.reward, cut = f.cut,
        poster = f.poster,                   -- "npc" | "player"
        fixer = f.fixer,                     -- the posting fixer's subject, or the NPC fixer's key
        fixerName = f.fixerName,
        point = f.point,                     -- the fixer drop the shard goes to
        posted = f.posted, deadline = f.deadline,
        state = "open", attempts = 0, traces = 0,
        taker = false, takerName = false, taken = false, shard = false,
    }
end

local STATES = { open = true, taken = true, breached = true }

-- A board instance's metadata, checked before it enters the cache (an operator's hand edit or a
-- newer record version is skipped, never guessed at).
function M.validRecord(meta)
    if type(meta) ~= "table" or meta.app ~= "rp_netrunner" or meta.v ~= M.RECORD_VERSION then return false end
    if not M.validContractId(meta.id) or type(meta.code) ~= "string" or type(meta.site) ~= "string" then return false end
    if not STATES[meta.state] then return false end
    if not M.integer(meta.reward) or not M.integer(meta.deadline) then return false end
    if meta.state ~= "open" and type(meta.taker) ~= "string" then return false end
    return true
end

function M.takePatch(subject, name, now)
    return { state = "taken", taker = subject, takerName = name or subject, taken = now }
end

function M.releasePatch()
    return { state = "open", taker = false, takerName = false, taken = false }
end

-- What a failed breach does, from the config and the attempts once this one is counted.
function M.failureOutcome(failure, attemptsAfter)
    failure = failure or {}
    if failure.maxAttempts and attemptsAfter >= failure.maxAttempts then return "fail" end
    local mode = failure.mode
    if mode == "reopen" or mode == "fail" then return mode end
    return "retry"
end

function M.shardMeta(c, site)
    return { contract = c.id, code = c.code, site = c.site, siteLabel = site and site.label or c.site,
        tier = c.tier, point = c.point, deadline = c.deadline }
end

-- Seconds left before a contract expires (negative when past).
function M.secondsLeft(c, now) return (M.integer(c.deadline) or 0) - math.floor(now) end

function M.expired(c, now) return M.secondsLeft(c, now) <= 0 end

function M.clock(seconds)
    seconds = math.max(0, math.floor(seconds or 0))
    if seconds >= 3600 then return ("%d h %02d min"):format(seconds // 3600, (seconds % 3600) // 60) end
    if seconds >= 60 then return ("%d min"):format((seconds + 59) // 60) end
    return ("%d s"):format(seconds)
end

-- ASCII only: prompt cards and chat replace a non-ASCII glyph with "?".
function M.money(n) return ("%d eddies"):format(M.integer(n) or 0) end

-- The public view of a contract (exports, the board, events). Never the internal subjects of
-- other players beyond what a fixer board needs to show.
function M.summary(c, site, tier, now)
    return {
        id = c.id, code = c.code, state = c.state,
        site = c.site, siteLabel = site and site.label or c.site, area = site and site.area or nil,
        position = site and M.copy(site.position) or nil,
        tier = c.tier, tierLabel = tier and tier.label or nil,
        reward = c.reward, cut = c.cut, net = c.reward - (c.cut or 0),
        poster = c.poster, fixer = c.fixer, fixerName = c.fixerName, point = c.point,
        posted = c.posted, deadline = c.deadline, secondsLeft = math.max(0, M.secondsLeft(c, now)),
        taker = c.taker or nil, takerName = c.takerName or nil,
        attempts = c.attempts or 0, traces = c.traces or 0, breached = c.state == "breached",
    }
end

-- One line for chat lists.
function M.line(c, site, tier, now)
    local who = c.state == "open" and "open" or ("%s by %s"):format(c.state, tostring(c.takerName or "?"))
    return ("%s  %s (%s), tier %d %s, %s, %s left, posted by %s, %s"):format(c.code, site and site.label or c.site,
        site and site.area or "?", c.tier, tier and tier.label or "", M.money(c.reward), M.clock(M.secondsLeft(c, now)),
        tostring(c.fixerName or c.fixer), who)
end

-- ---------------------------------------------------------------------------------------------
-- Coordinator refusals, named for the step they happened in.
-- ---------------------------------------------------------------------------------------------
function M.breachRefusal(reason)
    if reason == "insufficient_items" then return "no_breach_kit" end
    if reason == "instance_unavailable" or reason == "stale_version" or reason == "conflict" then return "contract_busy" end
    if reason == "capacity_exceeded" then return "pockets_full" end
    if reason == "unknown_account" then return "no_pockets" end
    return reason or "netrunner_unavailable"
end

function M.deliverRefusal(reason)
    if reason == "insufficient_items" or reason == "instance_unavailable" then return "no_shard" end
    return reason or "netrunner_unavailable"
end

M.TEXT = {
    not_owner = "That is not yours to do.",
    netrunner_unavailable = "The contract board is offline for now (the ledger is unavailable).",
    store_unavailable = "The fixer's ledger is unavailable: try again in a moment.",
    coordinator_unavailable = "The fixer's ledger is unavailable: try again in a moment.",
    in_doubt = "The fixer's ledger is still settling that: check /netrun in a moment.",
    no_job = "You are no netrunner. Find a fixer who trusts you with a deck.",
    wrong_job = "You are no netrunner. Find a fixer who trusts you with a deck.",
    off_duty = "Off duty. /service to jack in first.",
    grade_too_low = "Your grade is too low for that.",
    stale_job_epoch = "Your shift changed in the middle of that: nothing happened.",
    not_eligible = "You cannot do that right now.",
    not_fixer = "Only a fixer on duty posts contracts.",
    target_claimed = "Someone is already jacked into that terminal.",
    actor_busy = "Finish what you are doing first.",
    unknown_contract = "No such contract on the board. /netrun contracts lists them.",
    unknown_site = "No such site. /netrun sites lists them.",
    site_disabled = "That site is closed.",
    site_busy = "That site already has a live contract.",
    board_full = "The board is full.",
    too_many_posted = "You already have the most open contracts a fixer may post.",
    invalid_reward = "That reward is outside the tier's range (/netrun sites).",
    invalid_deadline = "That deadline is outside the tier's range (/netrun sites).",
    contract_taken = "Someone already took that contract.",
    contract_busy = "That contract is busy: try again in a moment.",
    contract_expired = "That contract has expired.",
    contract_not_open = "That contract is not open any more.",
    already_on_contract = "You already hold a contract: finish or abandon it first (/netrun).",
    own_contract = "You posted that contract yourself.",
    no_contract = "You hold no contract. Take one at the fixer's board (/netrun contracts).",
    no_contract_here = "Your contract is not for this terminal. /netrun shows where to go.",
    already_breached = "You already pulled the data: deliver the shard to the fixer.",
    not_breached = "Breach the target first: you have no shard for that contract yet.",
    site_alert = "The ICE on this terminal is on alert after a failed breach: give it a minute.",
    no_breach_kit = "You need a data chip to jack in (the breach kit).",
    pockets_full = "Your pockets are full: no room for the shard.",
    no_pockets = "Your pockets are not ready yet: try again in a moment.",
    no_shard = "You do not carry the data shard for your contract.",
    wrong_drop = "This is not the drop for your contract: /netrun shows where to deliver.",
    deliver_in_person = "The fixer who posted it is in the city: hand them the shard in person (/netrun deliver <their id>).",
    not_the_fixer = "That is not the fixer who posted your contract.",
    fixer_away = "That fixer is not in the city.",
    fixer_far = "Get closer to the fixer (3 m).",
    player_reserved = "One of you is already busy with a hand-over.",
    interactions_unavailable = "Hand-overs are unavailable on this server (open77_player_interactions).",
    insufficient_funds = "The client could not pay.",
    mint_denied = "The board cannot create that (operator: a mint rule is missing).",
    mint_cap_exceeded = "The fixer's client is out of money for this hour.",
    mint_cap = "The fixer's client is out of money for this hour.",
    namespace_denied = "The board's accounts are not writable (operator: writers policy).",
    cannot_abandon = "A breached contract cannot be abandoned: deliver the shard.",
    not_your_contract = "That contract is not yours to cancel.",
    position_unavailable = "Your position is unknown right now: try again.",
    too_far = "Too far away.",
    not_here = "No breach terminal within reach. /netrun shows where to go.",
}

function M.textFor(reason)
    return M.TEXT[reason] or "That did not work. Try again in a moment."   -- never the raw code on screen; the server log keeps it
end

-- Reason tokens -> the words players read after "cancelled: ", "refused: ", "blocked: ". Exact
-- tokens first, then families by substring; an unknown token reads `fallback`, never the token
-- (the server log keeps it).
local function worded(exact, families, fallback)
    return function(reason)
        reason = tostring(reason or "")
        if exact[reason] then return exact[reason] end
        for _, f in ipairs(families) do
            if reason:find(f[1], 1, true) then return f[2] end
        end
        return fallback
    end
end

-- Why a hand-over of the shard to a player fixer stopped (open77_player_interactions' reasons, the
-- runner's rp_jobs refusal, or this resource's own).
M.handoverText = worded({
    declined = "the fixer declined", rejected = "the fixer declined",
    timeout = "the fixer did not answer in time", invite_timeout = "the fixer did not answer in time",
    expired = "the fixer did not answer in time",
    too_far = "one of you walked away", moved = "one of you walked away", distance = "one of you walked away",
    player_moving = "one of you moved during the hand-over",
    cancelled = "it was called off", cancelled_by_player = "it was called off",
    runner_gone = "the netrunner left the city", disconnected = "one of you left the city",
    dead = "one of you went down", vehicle = "one of you got into a vehicle", combat = "a weapon came out",
    animation_interrupted = "the hand-over was interrupted",
    stale_job_epoch = "the netrunner's shift changed", off_duty = "the netrunner clocked off",
    no_job = "the netrunner is no longer a netrunner", wrong_job = "the netrunner is no longer a netrunner",
    not_eligible = "the netrunner cannot work right now",
    lost = "the hand-over was lost on the way",
    owner_stopped = "the contract board restarted", resource_stopping = "the contract board restarted",
}, {
    { "declin", "the fixer declined" }, { "reject", "the fixer declined" }, { "disconnect", "one of you left the city" },
    { "timeout", "the fixer did not answer in time" }, { "alive", "one of you went down" },
    { "far", "one of you walked away" }, { "jobs", "the jobs registry did not answer" },
}, "it did not go through")

-- Why an upload was refused (Open77.hacking.start) or stopped (onHackingTransition `blocked`,
-- `interrupted`).
M.hackText = worded({
    range = "the target is out of range", out_of_range = "the target is out of range",
    visibility_required = "no clear line of sight to the target", visibility_lost = "the line of sight was lost",
    evidence_timeout = "no clear line of sight to the target", stale_evidence = "no clear line of sight to the target",
    invalid_evidence = "no clear line of sight to the target",
    insufficient_stamina = "not enough stamina", cooldown = "your deck is still cooling down",
    recovery_protected = "the target is still recovering from the last hack",
    self_ice = "their Self-ICE bounced it", safe_area = "the target is in a safe area",
    combat_veto = "the city's combat rules protect that target", same_team = "the target is on your side",
    frozen = "you are held in place", cyberware_suspended = "your cyberware is suspended",
    hacker_damaged = "you took damage", hacker_busy = "you are already uploading",
    busy = "you are already uploading", upload_limit = "you are already uploading",
    action_owned = "another upload owns that target", cancelled = "it was cancelled",
    implant_unavailable = "your deck is not ready", definition_unavailable = "your deck is not ready",
    hacking_unavailable = "the hacking kit is offline", invalid_definition = "your deck is not ready",
    resource_stop = "the netrunner kit restarted", resource_stopping = "the netrunner kit restarted",
    owner_removed = "the netrunner kit restarted", lifecycle = "the target changed (death, respawn or reconnect)",
    rate_limit = "too many uploads at once: try again in a moment",
    operation_pending = "too many uploads at once: try again in a moment",
    operation_limit = "too many uploads at once: try again in a moment",
    operation_conflict = "too many uploads at once: try again in a moment",
}, {
    { "permission_denied", "this server does not allow it" }, { "target", "the target is out of reach" },
    { "player", "the target is out of reach" }, { "incarnation", "the target changed (death, respawn or reconnect)" },
    { "bucket", "the target is out of reach" },
    { "evidence", "no clear line of sight to the target" }, { "stamina", "not enough stamina" },
}, "the upload did not go through")

-- Why the deck could not be loaded (Open77.cyberware.newOperationId / install, or the completion).
M.deckText = worded({
    cyberware_storage_unavailable = "the implant records are unavailable on this server",
    player_unavailable = "your character is not ready yet", record_not_ready = "your character is not ready yet",
    resource_stopping = "the netrunner kit is restarting",
}, {
    { "revision", "your implants changed meanwhile: run it again" }, { "conflict", "your implants changed meanwhile: run it again" },
    { "permission_denied", "this server does not allow it" }, { "timeout", "the chair did not answer in time" },
}, "try again in a moment")

-- The platform's running gates on a hacked player (Open77.hacking.state), as players read them.
M.GATE_LABEL = {
    cyberwareSuspendedMs = "cyberware suspended", malfunctionMs = "malfunction", frozenMs = "frozen",
    crippledMs = "crippled", blindedMs = "blinded", weaponGlitchedMs = "weapon jammed",
}

return M
