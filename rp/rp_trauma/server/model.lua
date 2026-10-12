-- rp_trauma / server/model.lua: the pure rules of the Trauma Team service. No native, no export,
-- no clock: every function takes what it needs, so the offline suites load it in a bare Lua 5.4.
--
--   plans      which tier covers what, when it ends, what a purchase or a renewal makes of it
--   charges    how a fee splits between the plan, the patient's wallets, an invoice, the medic's
--              cut and the society, and the coordinator lines that move it (one operation)
--   calls      dispatch order
--   texts      what a player reads for a refusal token
--
-- Global: TraumaModel.

TraumaModel = {}
local M = TraumaModel

function M.playerId(value)
    local n = math.tointeger(tonumber(value))
    if not n or n < 1 then return nil end
    return n
end

function M.round(v) return math.floor(v + 0.5) end

function M.distance(a, b)
    if type(a) ~= "table" or type(b) ~= "table" or type(a.x) ~= "number" or type(b.x) ~= "number" then return nil end
    local dx, dy, dz = a.x - b.x, a.y - b.y, (a.z or 0) - (b.z or 0)
    return math.sqrt(dx * dx + dy * dy + dz * dz)
end

function M.fmtPos(p)
    if type(p) ~= "table" then return "?" end
    return ("%d, %d, %d"):format(M.round(p.x), M.round(p.y), M.round(p.z or 0))
end

function M.money(n) return ("%d eddies"):format(math.floor(tonumber(n) or 0)) end

-- "6 d 23 h", "3 h 12 min", "45 min", "under a minute".
function M.duration(seconds)
    seconds = math.max(0, math.floor(tonumber(seconds) or 0))
    local d, h, m = seconds // 86400, (seconds % 86400) // 3600, (seconds % 3600) // 60
    if d > 0 then return ("%d d %d h"):format(d, h) end
    if h > 0 then return ("%d h %d min"):format(h, m) end
    if m > 0 then return ("%d min"):format(m) end
    return "under a minute"
end

-- FNV-1a 64 as 16 hex digits: a subject may hold `@` or `~`, which an instance id refuses.
function M.fnv(s)
    local h = -3750763034362895579
    s = tostring(s)
    for i = 1, #s do
        h = h ~ s:byte(i)
        h = h * 1099511628211
    end
    return string.format("%016x", h)
end

-- ---------------------------------------------------------------------------------------------
-- Accounts
-- ---------------------------------------------------------------------------------------------
function M.cardInstance(subject) return "tti.card." .. M.fnv(subject) end
function M.fileAccount(subject, part) return ("stash:%s:%s"):format(subject, part or "tti") end

-- ---------------------------------------------------------------------------------------------
-- Plans. A plan is the metadata of the holder's membership card:
--   { tier, untilAt (unix s), startedAt, autoRenew, periods }
-- ---------------------------------------------------------------------------------------------
function M.tierOf(cfg, key)
    if type(key) ~= "string" then return nil end
    return cfg.plans[key]
end

function M.active(plan, now)
    return type(plan) == "table" and type(plan.tier) == "string" and (tonumber(plan.untilAt) or 0) > now
end

-- The tier config of an active plan, and its key; nil without one.
function M.activeTier(cfg, plan, now)
    if not M.active(plan, now) then return nil end
    return cfg.plans[plan.tier], plan.tier
end

-- Fraction of a `kind` fee the plan covers now (0 without an active plan), and the tier key.
function M.coverage(cfg, plan, kind, now)
    local tier, key = M.activeTier(cfg, plan, now)
    if not tier then return 0, nil end
    local c = tonumber(tier.covers and tier.covers[kind]) or 0
    if c < 0 then c = 0 elseif c > 1 then c = 1 end
    return c, key
end

-- What buying `tierKey` at `now` makes of the current plan.
--   same tier, active      -> "renew": one more period after the current end (max prepaid)
--   other tier, active     -> "switch": a fresh period from now, the remaining time is not refunded
--   none / expired         -> "new": a fresh period from now
-- Returns { mode, tier, untilAt, startedAt, periods } | nil, reason
function M.purchase(cfg, current, tierKey, now)
    local tier = M.tierOf(cfg, tierKey)
    if not tier then return nil, "unknown_plan" end
    local period = math.floor((tonumber(tier.periodHours) or 168) * 3600)
    if M.active(current, now) and current.tier == tierKey then
        local untilAt = math.floor(current.untilAt) + period
        if untilAt - now > period * (cfg.maxPrepaidPeriods or 4) then return nil, "max_prepaid" end
        return { mode = "renew", tier = tierKey, untilAt = untilAt, startedAt = current.startedAt or now,
            periods = (tonumber(current.periods) or 1) + 1 }
    end
    return { mode = M.active(current, now) and "switch" or "new", tier = tierKey, untilAt = math.floor(now) + period,
        startedAt = math.floor(now), periods = 1 }
end

-- The renewal of an expired plan: one period from its end, or from now when it ended long ago.
function M.renewal(cfg, current, now)
    local tier = type(current) == "table" and M.tierOf(cfg, current.tier)
    if not tier then return nil, "unknown_plan" end
    local period = math.floor((tonumber(tier.periodHours) or 168) * 3600)
    local from = math.floor(tonumber(current.untilAt) or now)
    if now - from > period then from = math.floor(now) end
    return { mode = "renew", tier = current.tier, untilAt = math.max(from + period, math.floor(now) + 60),
        startedAt = current.startedAt or math.floor(now), periods = (tonumber(current.periods) or 1) + 1 }
end

-- The card line of a purchase: created on the first plan, patched afterwards.
function M.cardLine(cfg, subject, exists, plan)
    local file = M.fileAccount(subject, cfg.accounts.filePart)
    local meta = { tier = plan.tier, untilAt = math.floor(plan.untilAt), startedAt = math.floor(plan.startedAt),
        periods = math.floor(plan.periods or 1), autoRenew = plan.autoRenew ~= false }
    if exists then
        return { instance = M.cardInstance(subject), at = file, metaPatch = meta, reason = "trauma plan" }
    end
    return { instance = M.cardInstance(subject), item = "tti_card", from = cfg.accounts.plans, to = file,
        meta = meta, reason = "trauma plan" }
end

-- Deterministic id of the automatic renewal of the period that ends at `untilAt`: two sweeps, a
-- retry or a restart reach the same operation, so one period is never paid twice.
function M.renewOpId(subject, untilAt)
    return ("tt.renew:%s:%d"):format(M.fnv(subject), math.floor(untilAt))
end

-- The plan a card's metadata describes (nil for a malformed card).
function M.planFromCard(meta)
    if type(meta) ~= "table" or type(meta.tier) ~= "string" then return nil end
    return { tier = meta.tier, untilAt = math.floor(tonumber(meta.untilAt) or 0),
        startedAt = math.floor(tonumber(meta.startedAt) or 0), periods = math.floor(tonumber(meta.periods) or 1),
        autoRenew = meta.autoRenew ~= false }
end

-- ---------------------------------------------------------------------------------------------
-- Charges. spec:
--   fee          the act's full price
--   coverage     0..1, the plan's share
--   funds        { bank = n, cash = n } available now (balance - held)
--   order        { "bank", "cash" }: which wallets pay, in order
--   accounts     { bank = "bank:<s>", cash = "cash:<s>", society = "soc:x", file = "stash:<s>:tti",
--                  billing = "sys:...", medic = "bank:<m>" | nil }
--   share        the medic's cut (0..1)
--   societyFunds what the society can spend on a bounty now (0 = no bounty)
--   invoice      true: what the wallets miss becomes an invoice; false: refuse insufficient_funds
--   reason       a line reason (<= 64 bytes)
-- Returns { fee, covered, due, fromBank, fromCash, paid, invoiced, cut, bounty, lines } | nil, reason
-- `lines` may be empty: nothing to move (a covered act with no medic to pay).
-- ---------------------------------------------------------------------------------------------
function M.charge(spec)
    local fee = math.max(0, math.floor(tonumber(spec.fee) or 0))
    local coverage = tonumber(spec.coverage) or 0
    if coverage < 0 then coverage = 0 elseif coverage > 1 then coverage = 1 end
    local covered = math.floor(fee * coverage + 0.5)
    if covered > fee then covered = fee end
    local due = fee - covered
    local funds = spec.funds or {}
    local acc = spec.accounts or {}
    local r = { fee = fee, covered = covered, due = due, fromBank = 0, fromCash = 0, paid = 0, invoiced = 0,
        cut = 0, bounty = 0, lines = {} }
    local left = due
    for _, wallet in ipairs(spec.order or { "bank", "cash" }) do
        if left <= 0 then break end
        local have = math.max(0, math.floor(tonumber(funds[wallet]) or 0))
        local take = math.min(left, have)
        if take > 0 and acc[wallet] then
            if wallet == "bank" then r.fromBank = r.fromBank + take else r.fromCash = r.fromCash + take end
            left = left - take
        end
    end
    r.paid = r.fromBank + r.fromCash
    if left > 0 then
        if not spec.invoice then return nil, "insufficient_funds", r end
        r.invoiced = left
    end
    local share = tonumber(spec.share) or 0
    if share < 0 then share = 0 elseif share > 1 then share = 1 end
    if acc.medic then
        r.cut = math.floor(r.paid * share)
        local bounty = math.floor(covered * share)
        local afford = math.max(0, math.floor(tonumber(spec.societyFunds) or 0))
        r.bounty = math.min(bounty, afford)
    end
    local reason = spec.reason
    local function add(line) line.reason = reason; r.lines[#r.lines + 1] = line end
    -- The medic's cut comes out of the bank part first, then the cash part.
    local cutBank = math.min(r.cut, r.fromBank)
    local cutCash = r.cut - cutBank
    if cutBank > 0 then add({ money = cutBank, from = acc.bank, to = acc.medic }) end
    if r.fromBank - cutBank > 0 then add({ money = r.fromBank - cutBank, from = acc.bank, to = acc.society }) end
    if cutCash > 0 then add({ money = cutCash, from = acc.cash, to = acc.medic }) end
    if r.fromCash - cutCash > 0 then add({ money = r.fromCash - cutCash, from = acc.cash, to = acc.society }) end
    if r.bounty > 0 then add({ money = r.bounty, from = acc.society, to = acc.medic }) end
    if r.invoiced > 0 then add({ item = "tti_invoice", count = r.invoiced, from = acc.billing, to = acc.file }) end
    return r
end

-- What the patient reads about a settled charge.
function M.chargeSentence(r)
    if type(r) ~= "table" then return "nothing charged" end
    local parts = {}
    if (r.covered or 0) > 0 then parts[#parts + 1] = ("%s covered by your plan"):format(M.money(r.covered)) end
    if (r.fromBank or 0) > 0 then parts[#parts + 1] = ("%s from your account"):format(M.money(r.fromBank)) end
    if (r.fromCash or 0) > 0 then parts[#parts + 1] = ("%s in cash"):format(M.money(r.fromCash)) end
    if (r.invoiced or 0) > 0 then parts[#parts + 1] = ("%s invoiced (/tti pay)"):format(M.money(r.invoiced)) end
    if #parts == 0 then return "nothing charged" end
    return table.concat(parts, ", ")
end

-- What a medic reads about their pay for one act.
function M.paySentence(r)
    if type(r) ~= "table" then return "no pay" end
    local total = (r.cut or 0) + (r.bounty or 0)
    if total <= 0 then return "no pay for this one" end
    return ("+%s to your account"):format(M.money(total))
end

-- Invoice payment: up to `owed`, from the wallets in order; the invoice items burn in the same
-- operation. Returns { paid, fromBank, fromCash, lines } (lines empty when nothing can be paid).
function M.settleInvoice(owed, funds, order, accounts, reason)
    owed = math.max(0, math.floor(tonumber(owed) or 0))
    local r = { paid = 0, fromBank = 0, fromCash = 0, lines = {} }
    local left = owed
    for _, wallet in ipairs(order or { "bank", "cash" }) do
        local have = math.max(0, math.floor(tonumber(funds and funds[wallet]) or 0))
        local take = math.min(left, have)
        if take > 0 and accounts[wallet] then
            r.lines[#r.lines + 1] = { money = take, from = accounts[wallet], to = accounts.society, reason = reason }
            if wallet == "bank" then r.fromBank = r.fromBank + take else r.fromCash = r.fromCash + take end
            left = left - take
        end
    end
    r.paid = r.fromBank + r.fromCash
    if r.paid > 0 then
        r.lines[#r.lines + 1] = { item = "tti_invoice", count = r.paid, from = accounts.file, to = accounts.billing,
            reason = reason }
    end
    return r
end

-- Available money in a coordinator wallet snapshot: balance minus holds minus in-flight debits.
function M.available(snapshot)
    if type(snapshot) ~= "table" then return 0 end
    local held = type(snapshot.held) == "table" and tonumber(snapshot.held.money) or 0
    local pending = type(snapshot.pending) == "table" and tonumber(snapshot.pending.money) or 0
    return math.max(0, math.floor((tonumber(snapshot.balance) or 0) - (held or 0) + math.min(0, pending or 0)))
end

-- Units of an item in a container snapshot, minus what is reserved out of it.
function M.itemCount(snapshot, item)
    if type(snapshot) ~= "table" or type(snapshot.items) ~= "table" then return 0 end
    local held = type(snapshot.held) == "table" and type(snapshot.held.items) == "table" and snapshot.held.items[item] or 0
    return math.max(0, (tonumber(snapshot.items[item]) or 0) - (tonumber(held) or 0))
end

-- ---------------------------------------------------------------------------------------------
-- Calls
-- ---------------------------------------------------------------------------------------------
-- Dispatch order: priority (1 first), then the oldest.
function M.sortCalls(list)
    table.sort(list, function(a, b)
        if a.priority ~= b.priority then return a.priority < b.priority end
        if a.raisedAt ~= b.raisedAt then return a.raisedAt < b.raisedAt end
        return a.id < b.id
    end)
    return list
end

-- The tag on a medic's map pin and dispatch line.
function M.callTag(call)
    if call.state ~= "open" then return ("TAKEN #%d"):format(call.id) end
    if call.tierLabel then return ("%s #%d"):format(call.tierLabel:upper(), call.id) end
    return ("UNINSURED #%d"):format(call.id)
end

-- ---------------------------------------------------------------------------------------------
-- Texts
-- ---------------------------------------------------------------------------------------------
local TEXTS = {
    trauma_unavailable = "The Trauma Team network is offline: try again in a moment.",
    coordinator_unavailable = "The Trauma Team network is offline: try again in a moment.",
    store_unavailable = "The Trauma Team network is offline: try again in a moment.",
    in_doubt = "The Trauma Team network did not confirm that yet: it settles on its own, do not pay twice.",
    insufficient_funds = "Not enough eddies in your account and wallet.",
    unknown_plan = "That plan does not exist.",
    max_prepaid = "You already paid as far ahead as Trauma Team allows.",
    declined = "Nothing signed.",
    menu_unavailable = "The kiosk screen did not open: try again.",
    patient_not_down = "This patient is not down.",
    patient_gone = "The patient is gone.",
    patient_not_ready = "The body is still settling: try again in a second.",
    patient_declined = "The patient refuses the charges.",
    self_treatment = "You can't treat yourself, choom.",
    call_taken = "Another Trauma Team unit has this call.",
    already_stable = "This patient is already stable: evacuate them.",
    not_stable = "Stabilise the patient first.",
    no_call = "No open call matches.",
    off_duty = "Trauma Team on duty only: /service to clock in.",
    no_job = "Trauma Team members only.",
    wrong_job = "Trauma Team members only.",
    not_eligible = "Trauma Team on duty only.",
    stale_job_epoch = "Your shift changed: start again.",
    mint_denied = "The Trauma Team service is not set up on this server (mint rule missing).",
    mint_cap_exceeded = "Trauma Team has issued enough cards and invoices for this hour.",
    namespace_denied = "The Trauma Team service is not set up on this server (writers).",
    unknown_item = "The Trauma Team items are not defined yet (rp_inventory).",
    unknown_account = "The Trauma Team service is not set up on this server (file).",
    instance_unavailable = "Your Trauma Team file is busy: try again in a second.",
    busy = "Your Trauma Team file is busy: try again in a second.",
    too_far = "Too far away.",
    target_claimed = "Someone is already working on this.",
    nothing_owed = "You owe Trauma Team nothing.",
    nothing_paid = "Nothing could be paid: fund your account or your wallet.",
    patient_down = "You are down: sign it when you are back on your feet.",
}

function M.textFor(reason)
    return TEXTS[reason] or ("Refused: " .. tostring(reason))
end

-- A word open77_actions accepts as a reason (letters, digits, `_ : . -`, up to 64).
function M.token(reason, fallback)
    if type(reason) == "string" and #reason <= 64 and reason:match("^[%w_:%.%-]+$") then return reason end
    return fallback or "refused"
end

return M
