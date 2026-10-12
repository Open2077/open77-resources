-- rp_trauma / server/service.lua: Trauma Team International, as hooks of the job libraries.
--
--   plans     kiosk target -> action `tti_plan`: the reserve hook shows the tier menu, then holds
--             the price (bank, then cash) and the membership card in ONE coordinator reservation;
--             commit = that operation. The card (a unique item in the holder's file
--             stash:<subject>:tti) carries the plan: tier, end, auto-renewal. Renewals of an
--             expired plan are one transfer whose id is derived from the period it renews.
--   calls     a player going down raises a call (main.lua's down state): priority from the plan,
--             dispatched to every on-duty medic (chat, toast, map pin), taken by one team
--             (/tti take), closed when the patient is up again, whatever brought them up.
--   response  the patient's body is an open77_actions target: `tti_stabilise` (kneel, one medic
--             at a time: the target claim), then `tti_evacuate` (a fade to Vik's clinic). Each act
--             reserves its charge before the work: the plan's share, the patient's part (bank,
--             cash, the rest as an invoice), the medic's cut and a society bounty for the covered
--             part, one operation; commit after the work, cancel on any other end.
--   billing   the same charge serves the legacy acts of main.lua (/soin, /reanimer, ALT+click)
--             and the hospital respawn; invoices are paid with /tti pay.
--
-- Durable state lives in the coordinator (cards, invoices, wallets). What this file keeps (calls,
-- consents, caches) is intent and presentation: a restart loses a call, never an eddy or a plan.
--
-- Global: TraumaService.

TraumaService = {}
local S = {}
S.__index = S

local ACTIONS = "open77_actions"
local HOOKS = { validate = "ttiValidate", reserve = "ttiReserve", commit = "ttiCommit", cancel = "ttiCancel" }

-- Refusals that say the money path is down or misconfigured, not that the patient cannot pay:
-- care goes on unbilled (and the log says why), a plan purchase is refused.
local BILLING_DOWN = { coordinator_unavailable = true, store_unavailable = true, store_failed = true,
    in_doubt = true, busy = true, conflict = true, mint_denied = true, mint_cap_exceeded = true,
    namespace_denied = true, unknown_item = true, unknown_account = true, subject_unavailable = true,
    invalid_key = true, export_timeout = true, op_id_conflict = true }

function TraumaService.new(deps)
    return setmetatable({
        cfg = deps.config, shared = deps.shared or {}, M = deps.model, L = deps.ledger, P = deps.ports,
        resource = deps.resource or "rp_trauma",
        down = nil,          -- main.lua's down state (S:attach)
        ready = false,       -- coordinator ready, items defined
        actionsReady = false,
        kinds = {},          -- [actionId] = "plan" | "stabilise" | "evacuate"
        plans = {},          -- [subject] = plan | false (no card); nil = not loaded
        cards = {},          -- [subject] = true when the file holds a membership card
        owed = {},           -- [subject] = eddies invoiced, not paid
        subjects = {},       -- [playerId] = subject
        files = {},          -- [subject] = true once the file is opened
        calls = {},          -- [patientId] = call
        callById = {},       -- [callId] = call
        callSeq = 0,
        work = {},           -- [actions opId] = reservation
        doubts = {},         -- [txOpId] = reservation whose commit is in doubt
        done = {},           -- [txOpId | actions opId] = ms (its after-commit step ran)
        renewals = {},       -- [renewOpId] = { nextTry, told }
        notified = {},       -- [playerId] = ms of the last refusal message
        receipts = {},       -- [subject] = ring of { kind, opId, text, at }
        legacyChecked = {},  -- [subject] = true once imported
        lastRenewSweep = 0,
        lastDoubtSweep = 0,
        stats = { plans = 0, renewals = 0, stabilised = 0, evacuated = 0, calls = 0, consents = 0, declined = 0,
                  invoiced = 0, invoicesPaid = 0, unbilled = 0, refusals = 0, doubts = 0, legacy = 0 },
    }, S)
end

function S:attach(down) self.down = down end
function S:log(fmt, ...) self.P.log(fmt:format(...)) end
function S:warn(fmt, ...) self.P.warn(fmt:format(...)) end

local function fromActions() return GetInvokingResource() == ACTIONS end

-- ---------------------------------------------------------------------------------------------
-- Telling players
-- ---------------------------------------------------------------------------------------------
function S:tell(pid, text, kind, title)
    pid = self.M.playerId(pid)
    if pid then self.P.tell(pid, text, kind, title) end
end

function S:refuseTo(pid, reason)
    self.stats.refusals = self.stats.refusals + 1
    pid = self.M.playerId(pid)
    if not pid then return end
    local now = self.P.nowMs()
    if (self.notified[pid] or 0) + self.cfg.notifyCooldownMs > now then return end
    self.notified[pid] = now
    self.P.tell(pid, self.M.textFor(reason), "warning")
end

function S:nameOf(pid)
    if self.down and self.down.name then return self.down.name(pid) end
    return self.P.players.name(pid) or ("player " .. tostring(pid))
end

function S:record(subject, entry)
    if not subject then return end
    local ring = self.receipts[subject] or {}
    entry.at = self.P.nowMs()
    ring[#ring + 1] = entry
    while #ring > self.cfg.receiptsKept do table.remove(ring, 1) end
    self.receipts[subject] = ring
end

function S:jobCompleted(kind, pid, ref, data)
    self.P.emit("rp:job:completed", { job = self.cfg.job, kind = kind, playerId = pid, ref = ref, data = data })
end

-- ---------------------------------------------------------------------------------------------
-- Subjects, files and plans
-- ---------------------------------------------------------------------------------------------
function S:subjectOf(pid)
    local s = self.subjects[pid]
    if s then return s end
    s = self.L.subjectOf(pid)
    if s then self.subjects[pid] = s end
    return s
end

function S:fileOf(subject) return self.M.fileAccount(subject, self.cfg.accounts.filePart) end

-- Opens the holder's file once (creates it, or finds it again). Yields.
function S:openFile(subject)
    if self.files[subject] then return true end
    local snap, why = self.L.open(self:fileOf(subject), { capacityG = self.cfg.accounts.fileCapacityG,
        meta = { app = "rp_trauma", role = "file" } })
    if type(snap) ~= "table" then return nil, why end
    self.files[subject] = true
    return true
end

-- Reads a holder's file into the caches: the plan (or false) and the invoices owed. Yields.
-- Returns plan|false, or nil, reason when the coordinator could not answer.
function S:loadFile(subject)
    local snap, why = self.L.read(self:fileOf(subject))
    if type(snap) ~= "table" then
        if why == "unknown_account" then
            self.plans[subject] = false
            self.cards[subject] = false
            self.owed[subject] = 0
            return false
        end
        return nil, why
    end
    self.files[subject] = true
    local card = type(snap.instances) == "table" and snap.instances[self.M.cardInstance(subject)] or nil
    self.cards[subject] = card ~= nil
    self.plans[subject] = card and self.M.planFromCard(card.meta) or false
    self.owed[subject] = self.M.itemCount(snap, "tti_invoice")
    return self.plans[subject]
end

-- The cached plan of a subject, loading it when unknown. Yields on a load.
function S:ensurePlan(subject)
    local plan = self.plans[subject]
    if plan ~= nil then return plan end
    return self:loadFile(subject)
end

-- Synchronous: the active plan of a connected player (cache only), and its tier config.
function S:planOf(pid)
    local subject = self.subjects[pid] or self.L.subjectOf(pid)
    local plan = subject and self.plans[subject]
    if not self.M.active(plan, self.P.now()) then return nil end
    return plan, self.cfg.plans[plan.tier]
end

function S:hasPlan(pid) return self:planOf(pid) ~= nil end

-- Synchronous estimate (cache only) of what a `kind` act costs this player after their plan.
function S:estimate(pid, kind)
    local fee = self.cfg.fees[kind] or 0
    local subject = self.subjects[pid]
    local plan = subject and self.plans[subject] or nil
    local c = self.M.coverage(self.cfg, plan, kind, self.P.now())
    return fee - math.floor(fee * c + 0.5)
end

function S:owedBy(pid)
    local subject = self.subjects[pid] or self.L.subjectOf(pid)
    return subject and self.owed[subject] or 0
end

-- ---------------------------------------------------------------------------------------------
-- Boot steps (re-run whenever a library restarts)
-- ---------------------------------------------------------------------------------------------
function S:defineItems()
    local registered, rejected, details = self.P.inventory.define(self.cfg.items)
    if registered == nil then
        self:warn("rp_inventory:define unavailable (%s): Trauma Team items not defined yet", tostring(rejected))
        return false
    end
    if (tonumber(rejected) or 0) > 0 then
        local names = {}
        for _, c in ipairs(type(details) == "table" and details.collisions or {}) do names[#names + 1] = tostring(c) end
        self:warn("items: %s registered, %s refused %s", tostring(registered), tostring(rejected), table.concat(names, ","))
    else
        self:log("items defined through rp_inventory: %s", tostring(registered))
    end
    return true
end

function S:actionDefinitions()
    local cfg = self.cfg
    local a = cfg.actions
    local eligibility = { resource = "rp_jobs", export = "eligible", args = { job = cfg.job, duty = true } }
    local epochs = { resource = "rp_jobs", read = "workEpoch", event = "rp_jobs:workEpoch" }
    local defs = {
        {
            id = a.subscribe.id, label = a.subscribe.label, durationMs = a.subscribe.durationMs,
            maxDistance = a.subscribe.maxDistance, reserveTimeoutMs = a.subscribe.reserveTimeoutMs,
            animation = { profile = a.subscribe.profile, at = "self", required = false },
            progress = { label = a.subscribe.progress, color = "#FF3B3B" }, hooks = HOOKS,
        },
        {
            id = a.stabilise.id, label = a.stabilise.label, durationMs = a.stabilise.durationMs,
            maxDistance = a.stabilise.maxDistance, reserveTimeoutMs = a.stabilise.reserveTimeoutMs,
            animation = { profile = a.stabilise.profile, at = "self", required = false },
            progress = { label = a.stabilise.progress, color = "#FF3B3B" }, hooks = HOOKS,
            eligibility = eligibility, epochs = epochs,
        },
        {
            id = a.evacuate.id, label = a.evacuate.label, durationMs = a.evacuate.durationMs,
            maxDistance = a.evacuate.maxDistance, reserveTimeoutMs = a.evacuate.reserveTimeoutMs,
            animation = { profile = a.evacuate.profile, at = "self", required = false },
            progress = { label = a.evacuate.progress, color = "#FF3B3B" }, hooks = HOOKS,
            eligibility = eligibility, epochs = epochs,
        },
    }
    self.kinds = { [a.subscribe.id] = "plan", [a.stabilise.id] = "stabilise", [a.evacuate.id] = "evacuate" }
    return defs
end

-- Declares the actions, the kiosks and the live patients' targets. Returns the number of targets.
function S:declare()
    for _, def in ipairs(self:actionDefinitions()) do
        local key, why = self.P.actions.define(def)
        if not key then self:warn("action %s refused by open77_actions: %s", def.id, tostring(why)) end
    end
    local targets = 0
    for _, k in ipairs(self.cfg.kiosks) do
        if k.enabled ~= false then
            local ok, why = self.P.actions.target({
                id = k.id, position = k.position, yaw = k.yaw, bucket = self.cfg.bucket, label = k.label,
                description = "Silver, Gold and Platinum plans", actions = { self.cfg.actions.subscribe.id },
                color = "#FF3B3B", data = { kiosk = k.id },
            })
            if ok then targets = targets + 1 else self:warn("kiosk %s refused: %s", k.id, tostring(why)) end
        end
    end
    self.actionsReady = true
    for _, call in pairs(self.calls) do
        if self:targetPatient(call) then targets = targets + 1 end
    end
    self.targetCount = targets
    return targets
end

-- The patient's body as a target: Stabilise first, Evacuate once stable.
function S:targetPatient(call)
    if not self.actionsReady or call.noTarget then return false end
    local a, t = self.cfg.actions, self.cfg.patientTarget
    local ok, why = self.P.actions.target({
        id = call.targetId, position = call.position, yaw = 0.0, bucket = call.bucket or 0,
        label = ("Trauma Team patient #%d"):format(call.id), distance = t.distance, promptHeight = t.promptHeight,
        markerDistance = t.markerDistance, color = "#FF3B3B", keepCrowdOff = t.keepCrowdOff,
        hideFor = { call.patient },   -- the patient is not offered the medic's card over their own body
        actions = { call.stable and a.evacuate.id or a.stabilise.id },
        data = { patient = call.patient, episode = call.episode, call = call.id },
    })
    if not ok then self:warn("patient target %s refused: %s", call.targetId, tostring(why)) end
    return ok ~= nil and ok ~= false
end

function S:untargetPatient(call)
    if self.actionsReady and call.targetId then self.P.actions.untarget(call.targetId) end
end

-- ---------------------------------------------------------------------------------------------
-- Calls
-- ---------------------------------------------------------------------------------------------
function S:newEpisode() return self.L.newOpId("ep") end

function S:callCount()
    local n = 0
    for _ in pairs(self.calls) do n = n + 1 end
    return n
end

function S:medics(except)
    local out = {}
    for _, id in ipairs(self.P.jobs.listOnDuty(self.cfg.job)) do
        id = self.M.playerId(id)
        if id and id ~= except then out[#out + 1] = id end
    end
    return out
end

function S:isMedic(pid)
    return self.P.jobs.onDutyAs(pid, self.cfg.job)
end

-- A player went down (main.lua, once per down episode), or is still down after a disconnect or a
-- restart: a patient already stable gets a stable call (the body offers Evacuate). Never yields.
function S:raiseCall(patient, entry)
    if self.calls[patient] then return self.calls[patient] end
    local cfg, M, now = self.cfg, self.M, self.P.nowMs()
    local subject = self.subjects[patient] or self.L.subjectOf(patient)
    local plan = subject and self.plans[subject]
    local tier, tierKey = M.activeTier(cfg, plan, self.P.now())
    if not tier and not cfg.calls.uninsured then return nil end
    self.callSeq = self.callSeq + 1
    local pos = self.P.players.position(patient)
    local call = {
        id = self.callSeq, patient = patient, subject = subject, episode = entry.episode,
        position = { x = entry.position.x, y = entry.position.y, z = entry.position.z },
        bucket = type(pos) == "table" and pos.bucket or 0,
        raisedAt = now, tierKey = tierKey, tierLabel = tier and tier.label or nil,
        priority = tier and tier.priority or cfg.calls.uninsuredPriority,
        dispatchAt = now + 1000 * (tier and (tier.dispatchDelaySeconds or 0) or cfg.calls.uninsuredDelaySeconds),
        state = "open", team = {}, stable = entry.stable == true, announced = false, lastAnnounce = 0,
        targetId = "tti_patient_" .. tostring(patient),
    }
    call.noTarget = self:callCount() >= cfg.calls.maxCalls
    self.calls[patient] = call
    self.callById[call.id] = call
    self.stats.calls = self.stats.calls + 1
    self:targetPatient(call)
    if tier then
        self:tell(patient, ("Trauma Team %s: call #%d placed, priority %d. A team is on the way."):format(tier.label,
            call.id, call.priority), "info", "Trauma Team " .. tier.label)
    else
        self:tell(patient, ("No Trauma Team plan: emergency call #%d placed, the care is billed to you. " ..
            "Plans are sold at the Trauma Team kiosks (/tti plans)."):format(call.id), "warning")
    end
    if now >= call.dispatchAt then self:announce(call) end
    self.P.emit("rp_trauma:call", call.id, "open", patient)
    self:log("call #%d raised: player %d %s priority %d at %s%s", call.id, patient, tierKey or "uninsured",
        call.priority, M.fmtPos(call.position), call.noTarget and " (no target: too many calls)" or "")
    return call
end

-- Dispatch line to every on-duty medic (chat, toast, map pin). Returns how many were told.
function S:announce(call, reminder)
    local M = self.M
    local name = self:nameOf(call.patient)
    local tag = M.callTag(call)
    local n = 0
    for _, medic in ipairs(self:medics(call.patient)) do
        local metres = self.P.players.distance(medic, call.position)
        local dist = metres and ("%.0f m"):format(metres) or "unknown distance"
        self.P.tell(medic, ("[%s] %s (id %d) is down at %s, %s away. %s"):format(tag, name, call.patient,
            M.fmtPos(call.position), dist, call.state == "open" and ("/tti take " .. call.id .. " to respond.")
            or "A team is on it."), not reminder and "warning" or nil,
            call.tierLabel and ("Trauma Team " .. call.tierLabel .. " call") or "Trauma Team: citizen down")
        self.P.client("rp_trauma:downBlip", medic, call.patient, call.position, name, tag)
        n = n + 1
    end
    call.announced = true
    call.lastAnnounce = self.P.nowMs()
    return n
end

-- Calls as main.lua's medic pins want them.
function S:callList(except)
    local out = {}
    for pid, call in pairs(self.calls) do
        if pid ~= except and call.announced then
            out[#out + 1] = { playerId = pid, position = call.position, name = self:nameOf(pid),
                tag = self.M.callTag(call), callId = call.id }
        end
    end
    table.sort(out, function(a, b) return a.callId < b.callId end)
    return out
end

function S:openCalls()
    local list = {}
    for _, call in pairs(self.calls) do list[#list + 1] = call end
    return self.M.sortCalls(list)
end

local function teamList(call)
    local out = {}
    for id in pairs(call.team) do out[#out + 1] = id end
    table.sort(out)
    return out
end

function S:retag(call)
    local name = self:nameOf(call.patient)
    for _, medic in ipairs(self:medics(call.patient)) do
        self.P.client("rp_trauma:downBlip", medic, call.patient, call.position, name, self.M.callTag(call))
    end
end

-- One team takes a call: the first medic becomes its responder. Never yields.
function S:assign(call, medic)
    if call.state ~= "open" then
        if call.team[medic] then return true end
        return nil, "call_taken"
    end
    call.state = "taken"
    call.responder = medic
    call.team[medic] = true
    call.takenAt = self.P.nowMs()
    local medicName = self:nameOf(medic)
    self:tell(call.patient, ("Trauma Team medic %s is responding to your call #%d."):format(medicName, call.id),
        "info")
    for _, other in ipairs(self:medics(medic)) do
        if other ~= call.patient then self.P.tell(other, ("Call #%d taken by %s."):format(call.id, medicName)) end
    end
    self:retag(call)
    self.P.emit("rp_trauma:call", call.id, "taken", call.patient, medic)
    self:log("call #%d taken by player %d", call.id, medic)
    return true
end

-- /tti take [id]: the given call, or the best open one. Returns the call or nil, reason.
function S:take(medic, callId)
    local onDuty = self:isMedic(medic)
    if onDuty == nil then return nil, "trauma_unavailable" end
    if not onDuty then return nil, "off_duty" end
    local call
    if callId then
        call = self.callById[callId]
        if not call or not self.calls[call.patient] then return nil, "no_call" end
    else
        for _, c in ipairs(self:openCalls()) do
            if c.state == "open" and c.announced and c.patient ~= medic then call = c break end
        end
        if not call then return nil, "no_call" end
    end
    if call.patient == medic then return nil, "self_treatment" end
    local ok, why = self:assign(call, medic)
    if not ok then return nil, why end
    local M = self.M
    local metres = self.P.players.distance(medic, call.position)
    local pad = self.shared.av and self.shared.av.pad
    local padMetres = pad and self.P.players.distance(medic, pad)
    self.P.tell(medic, ("Call #%d is yours: %s at %s, %s. Stabilise (E on the body), then evacuate. %s"):format(
        call.id, self:nameOf(call.patient), M.fmtPos(call.position),
        metres and ("%.0f m away"):format(metres) or "distance unknown",
        padMetres and ("AV: /trauma av on the pad, %.0f m from you; or drive."):format(padMetres) or "Drive."), "info")
    self.P.client("rp_trauma:downBlip", medic, call.patient, call.position, self:nameOf(call.patient), M.callTag(call))
    return call
end

-- /tti assist <id>: join the team of a taken call.
function S:assist(medic, callId)
    local onDuty = self:isMedic(medic)
    if not onDuty then return nil, onDuty == nil and "trauma_unavailable" or "off_duty" end
    local call = self.callById[callId or -1]
    if not call or not self.calls[call.patient] then return nil, "no_call" end
    if call.patient == medic then return nil, "self_treatment" end
    if call.state == "open" then return self:take(medic, callId) end
    call.team[medic] = true
    self:tell(call.patient, ("Trauma Team medic %s joins your response team."):format(self:nameOf(medic)))
    if call.responder and call.responder ~= medic then
        self.P.tell(call.responder, ("%s joins your team on call #%d."):format(self:nameOf(medic), call.id))
    end
    return call
end

-- A medic leaves a team (dropped the call, clocked out, disconnected). An empty team reopens the call.
function S:leaveTeam(medic, reason)
    for _, call in pairs(self.calls) do
        if call.team[medic] then
            call.team[medic] = nil
            if call.responder == medic then call.responder = teamList(call)[1] end
            if not call.responder then
                call.state = "open"
                call.takenAt = nil
                self:tell(call.patient, ("Your Trauma Team responder left (%s): the call is open again."):format(reason),
                    "warning")
                self:announce(call)
                self.P.emit("rp_trauma:call", call.id, "open", call.patient)
                self:log("call #%d open again: player %d left (%s)", call.id, medic, reason)
            end
        end
    end
end

-- The patient is up (or gone): whatever happened, the call closes. Never yields.
function S:onUp(patient, how, by)
    local call = self.calls[patient]
    if not call then return end
    self.calls[patient] = nil
    self.callById[call.id] = nil
    self:untargetPatient(call)
    for _, medic in ipairs(teamList(call)) do
        if medic ~= by then
            self.P.tell(medic, ("Call #%d closed: the patient %s."):format(call.id, ({
                revived = "was revived", respawned = "woke up at Vik's", evacuated = "was evacuated",
                left = "disconnected", released = "is back on their feet", stopped = "was released" })[how] or how))
        end
    end
    self.P.emit("rp_trauma:call", call.id, "closed", patient, how)
    self:log("call #%d closed: %s%s", call.id, tostring(how), by and (" by player " .. tostring(by)) or "")
end

-- The down position moved (a new death while down).
function S:patientMoved(patient, position)
    local call = self.calls[patient]
    if not call then return end
    call.position = { x = position.x, y = position.y, z = position.z }
    self:targetPatient(call)
    if call.announced then self:retag(call) end
end

-- ---------------------------------------------------------------------------------------------
-- Consent: an uninsured (or uncovered) patient who answers is conscious and decides; no answer
-- counts as unconscious (billed after). Yields up to the dialog's timeout.
-- Returns "accepted" | "declined" | "silent".
-- ---------------------------------------------------------------------------------------------
function S:askConsent(patient, message)
    self.stats.consents = self.stats.consents + 1
    local answer, why = self.P.uikit.alert(patient, {
        title = "Trauma Team", message = message, confirm = "Accept the charges", cancel = "Refuse",
        tone = "warning", timeoutMs = self.cfg.consent.timeoutMs, useWhileDead = true,
    })
    if type(answer) ~= "table" then
        self:log("consent of player %d: no answer (%s), treated as unconscious", patient, tostring(why))
        return "silent"
    end
    if answer.ok and answer.value == "confirm" then return "accepted" end
    if answer.outcome == "timeout" then return "silent" end
    self.stats.declined = self.stats.declined + 1
    return "declined"
end

-- ---------------------------------------------------------------------------------------------
-- Charges: quote (reserve before the work), settle (commit after it), release (cancel).
-- spec = { patient, medic?, team? (medic ids, the acting one first), kind ("stabilise"|"evacuate"|
-- "hospital"|"revive"|"heal"), opId? }
-- Returns a reservation: { txOpId|nil, kind, fee, covered, due, fromBank, fromCash, paid, invoiced,
-- cut, bounty, tier, patient, medic, subject } (txOpId nil: nothing to move), or one with
-- `unbilled = reason` when the money path is down (care goes on), or nil, reason.
-- ---------------------------------------------------------------------------------------------
function S:quote(spec)
    local cfg, M, L = self.cfg, self.M, self.L
    local patient = spec.patient
    local fee = cfg.fees[spec.kind] or 0
    local team = spec.team or (spec.medic and { spec.medic }) or {}
    local base = { kind = spec.kind, patient = patient, medic = spec.medic, fee = fee, covered = 0, due = 0,
        fromBank = 0, fromCash = 0, paid = 0, invoiced = 0, cut = 0, bounty = 0, team = team, teamPay = {} }
    local function unbilled(reason)
        base.unbilled = reason
        self.stats.unbilled = self.stats.unbilled + 1
        self:warn("%s for player %s goes unbilled: %s", spec.kind, tostring(patient), tostring(reason))
        return base
    end
    if fee <= 0 then return base end
    local ready = L.ready()
    if not ready then return unbilled("coordinator_unavailable") end
    local subject, swhy = self:subjectOf(patient)
    if not subject then return unbilled(swhy or "subject_unavailable") end
    base.subject = subject
    local plan = self:ensurePlan(subject)
    local coverage, tierKey = M.coverage(cfg, plan or nil, spec.kind, self.P.now())
    base.tier = tierKey
    local bank, cash = L.account(patient, "bank"), L.account(patient, "cash")
    local accounts = { bank = bank, cash = cash, society = "soc:" .. cfg.society, file = self:fileOf(subject),
        billing = cfg.accounts.billing }
    local societyFunds = 0
    if #team > 0 then
        accounts.medics = {}
        for i, m in ipairs(team) do accounts.medics[i] = L.account(m, cfg.medicWallet) end
        if coverage > 0 then societyFunds = L.funds(accounts.society) end
    end
    local txOpId = spec.opId or L.newOpId("care")
    local res, why
    for attempt = 1, 3 do
        -- A wallet that moved under us twice: the third attempt invoices the whole due part.
        local funds = attempt < 3 and { bank = L.funds(bank), cash = L.funds(cash) } or { bank = 0, cash = 0 }
        local ch = M.charge({ fee = fee, coverage = coverage, funds = funds, order = cfg.invoices.payFrom,
            accounts = accounts, share = cfg.medicShare, societyFunds = societyFunds,
            invoice = cfg.invoices.enabled ~= false, reason = ("trauma %s"):format(spec.kind) })
        if not ch then return nil, "insufficient_funds" end
        for k, v in pairs(ch) do if k ~= "lines" then base[k] = v end end
        if #ch.lines == 0 then return base end
        if ch.invoiced > 0 then
            local opened, owhy = self:openFile(subject)
            if not opened then return unbilled(owhy or "unknown_account") end
        end
        local held
        held, why = L.reserve({ opId = txOpId, kind = "trauma." .. spec.kind, actor = bank or cash,
            reason = ("trauma %s"):format(spec.kind), ttlMs = spec.ttlMs or 120000, lines = ch.lines })
        if held then
            base.txOpId = txOpId
            res = base
            break
        end
        if why ~= "insufficient_funds" and why ~= "conflict" then break end
        societyFunds = 0          -- a race on the society's balance: no bounty this time
        if cfg.invoices.enabled == false and attempt == 2 then break end
    end
    if res then return res end
    if BILLING_DOWN[why] then return unbilled(why) end
    return unbilled(why or "reserve_failed")
end

-- Commits a quote's reservation. Returns the receipt (or true when there was nothing to move), or
-- nil, reason (in_doubt kept for the sweep).
function S:settle(res)
    if type(res) ~= "table" or not res.txOpId then return true end
    local receipt, why = self.L.commit(res.txOpId)
    if not receipt then
        if why == "coordinator_unavailable" then why = "in_doubt" end
        if why == "in_doubt" or why == "busy" then
            self.doubts[res.txOpId] = res
            self.stats.doubts = self.stats.doubts + 1
        end
        return nil, why
    end
    self:afterCharge(res)
    return receipt
end

function S:release(res, reason)
    if type(res) ~= "table" or not res.txOpId then return end
    self.L.cancel(res.txOpId, reason or "cancelled")
end

-- The charge of a legacy medic act (main.lua: /soin, /reanimer, ALT+click), consent included.
-- `conscious` (a standing patient being patched up): any uncovered charge needs their yes, and no
-- answer is a no. A down patient follows the response rules: a plan holder pays the uncovered
-- part by contract; without a plan, a yes or no decides, no answer means billed after. Yields.
-- Returns a quote (see S:quote) or nil, "patient_declined" | reason.
function S:careQuote(patient, medic, kind, conscious)
    local cfg, M = self.cfg, self.M
    local fee = cfg.fees[kind] or 0
    if fee > 0 and self.L.ready() then
        local subject = self:subjectOf(patient)
        local plan = subject and self:ensurePlan(subject) or nil
        local now = self.P.now()
        local coverage = M.coverage(cfg, plan, kind, now)
        if coverage < 1 and (conscious or not M.active(plan, now)) then
            local due = fee - math.floor(fee * coverage + 0.5)
            self:tell(medic, ("Asking %s to accept the charges (%d s)..."):format(self:nameOf(patient),
                math.floor(cfg.consent.timeoutMs / 1000)))
            local state = self:askConsent(patient, ("Trauma Team medic %s offers to %s you for %s (bank, then " ..
                "cash; the rest is invoiced). Accept?"):format(self:nameOf(medic),
                kind == "heal" and "patch up" or "revive", M.money(due)))
            if state == "declined" or (state == "silent" and conscious) then
                self:tell(patient, "You refused Trauma Team's charges.")
                return nil, "patient_declined"
            end
        end
    end
    return self:quote({ patient = patient, medic = medic, kind = kind, ttlMs = 120000 })
end

-- After a committed charge: the invoice cache and the counters (once per operation).
function S:afterCharge(res)
    if res.subject and (res.invoiced or 0) > 0 then
        self.owed[res.subject] = (self.owed[res.subject] or 0) + res.invoiced
        self.stats.invoiced = self.stats.invoiced + res.invoiced
    end
end

-- ---------------------------------------------------------------------------------------------
-- Hooks: validate (synchronous, never yields)
-- ---------------------------------------------------------------------------------------------
function S:patientOf(ctx)
    local data = type(ctx.target) == "table" and type(ctx.target.data) == "table" and ctx.target.data or nil
    if not data then return nil end
    local patient = self.M.playerId(data.patient)
    local call = patient and self.calls[patient]
    if not call or call.episode ~= data.episode then return nil end
    local entry = self.down and self.down.entry(patient)
    if not entry or entry.episode ~= data.episode then return nil end
    return patient, call, entry
end

function S:validate(ctx)
    if not fromActions() then return false, "not_owner" end
    local kind = self.kinds[ctx.actionId]
    if not kind then return false, "unknown_action" end
    if kind == "plan" then
        if not self.ready then return false, "trauma_unavailable" end
        if self.down and self.down.isDown(ctx.playerId) then return false, "patient_down" end
        return true
    end
    local patient, call, entry = self:patientOf(ctx)
    local function refuse(reason)
        if ctx.phase == "begin" then self:refuseTo(ctx.playerId, reason) end
        return false, reason
    end
    if not patient then return refuse("patient_gone") end
    if patient == ctx.playerId then return refuse("self_treatment") end
    if call.state ~= "open" and not call.team[ctx.playerId] then return refuse("call_taken") end
    if entry.applying then return refuse("patient_not_ready") end
    if kind == "stabilise" then
        if call.stable and ctx.phase == "begin" then return refuse("already_stable") end
    elseif kind == "evacuate" then
        if self.cfg.actions.evacuate.requiresStable and not call.stable then return refuse("not_stable") end
        if not entry.held then return refuse("patient_not_ready") end
    end
    return true
end

-- ---------------------------------------------------------------------------------------------
-- Hooks: reserve -> commit, or cancel
-- ---------------------------------------------------------------------------------------------
function S:reserve(ctx)
    if not fromActions() then return nil, "not_owner" end
    if not self.P.actions.verify(ctx.opId, "reserve") then return nil, "not_owner" end
    local kind = self.kinds[ctx.actionId]
    if kind == "plan" then return self:reservePlan(ctx) end
    if kind == "stabilise" or kind == "evacuate" then return self:reserveCare(ctx, kind) end
    return nil, "unknown_action"
end

-- The kiosk: tier menu, then the price and the card held in one reservation.
function S:reservePlan(ctx)
    local cfg, M, L, P = self.cfg, self.M, self.L, self.P
    local pid = ctx.playerId
    if not self.ready then return nil, "trauma_unavailable" end
    local subject, swhy = self:subjectOf(pid)
    if not subject then
        self:refuseTo(pid, "trauma_unavailable")
        return nil, swhy or "subject_unavailable"
    end
    local plan, pwhy = self:ensurePlan(subject)
    if plan == nil then
        self:refuseTo(pid, "trauma_unavailable")
        return nil, M.token(pwhy, "trauma_unavailable")
    end
    local now = P.now()
    local options = {}
    local current = M.activeTier(cfg, plan, now)
    if current then
        options[#options + 1] = { id = "status", label = ("Your plan: %s, %s left"):format(current.label,
            M.duration(plan.untilAt - now)), disabled = true,
            description = ("Auto-renewal %s (/tti autorenew on|off)."):format(plan.autoRenew and "on" or "off") }
    end
    for _, key in ipairs(cfg.planOrder) do
        local t = cfg.plans[key]
        local verb = "Subscribe"
        if current and plan.tier == key then verb = "Renew"
        elseif current then verb = "Switch to" end
        options[#options + 1] = {
            id = "plan_" .. key, label = ("%s %s - %s / %d days"):format(verb, t.label, M.money(t.price),
                math.floor(t.periodHours / 24)),
            description = t.pitch .. (verb == "Switch to" and " Starts now; the rest of your current plan is lost." or ""),
            metadata = { { label = "Priority", value = tostring(t.priority) },
                { label = "Price", value = M.money(t.price) } },
        }
    end
    options[#options + 1] = { id = "leave", label = "Leave" }
    local answer, why = P.uikit.context(pid, { id = "rp_trauma_plans", title = "Trauma Team International",
        description = "Platinum members first. Everyone else waits.", options = options },
        { timeoutMs = cfg.actions.subscribe.menuTimeoutMs })
    if type(answer) ~= "table" then
        self:refuseTo(pid, "menu_unavailable")
        return nil, M.token(why, "menu_unavailable")
    end
    local picked = answer.ok and type(answer.value) == "table" and tostring(answer.value.id or "") or ""
    local tierKey = picked:match("^plan_([%w_]+)$")
    if not tierKey then
        self:tell(pid, M.textFor("declined"))
        return nil, "declined"
    end
    -- The menu took time: the operation may have ended meanwhile.
    if not P.actions.verify(ctx.opId, "reserve") then return nil, "not_owner" end
    now = P.now()
    plan = self.plans[subject]
    local purchase, perr = M.purchase(cfg, plan, tierKey, now)
    if not purchase then
        self:refuseTo(pid, perr)
        return nil, perr
    end
    -- The holder's choice survives a purchase: a plan whose renewals were switched off stays off.
    if type(plan) == "table" and plan.autoRenew ~= nil then
        purchase.autoRenew = plan.autoRenew
    else
        purchase.autoRenew = cfg.autoRenew.default
    end
    local opened, owhy = self:openFile(subject)
    if not opened then
        self:refuseTo(pid, M.token(owhy, "trauma_unavailable"))
        return nil, M.token(owhy, "trauma_unavailable")
    end
    local tier = cfg.plans[tierKey]
    local bank, cash = L.account(pid, "bank"), L.account(pid, "cash")
    local accounts = { bank = bank, cash = cash, society = "soc:" .. cfg.society }
    local txOpId = L.newOpId("plan")
    local held, hwhy, ch
    for _ = 1, 2 do
        local cherr
        ch, cherr = M.charge({ fee = tier.price, coverage = 0, funds = { bank = L.funds(bank), cash = L.funds(cash) },
            order = cfg.payFrom, accounts = accounts, invoice = false, reason = "trauma plan " .. tierKey })
        if not ch then
            self:refuseTo(pid, cherr)
            return nil, cherr
        end
        local lines = ch.lines
        lines[#lines + 1] = M.cardLine(cfg, subject, self.cards[subject] == true, purchase)
        held, hwhy = L.reserve({ opId = txOpId, kind = "trauma.plan", actor = bank or cash,
            reason = ("trauma %s plan"):format(tierKey), ttlMs = cfg.actions.subscribe.durationMs + 60000, lines = lines })
        if held or (hwhy ~= "insufficient_funds" and hwhy ~= "conflict") then break end
    end
    if not held then
        local token = M.token(hwhy, "trauma_unavailable")
        self:refuseTo(pid, token)
        return nil, token
    end
    local r = { kind = "plan", txOpId = txOpId, subject = subject, pid = pid, tier = tierKey, mode = purchase.mode,
        untilAt = purchase.untilAt, startedAt = purchase.startedAt, periods = purchase.periods,
        autoRenew = purchase.autoRenew, price = tier.price, fromBank = ch.fromBank, fromCash = ch.fromCash }
    self.work[ctx.opId] = r
    return r
end

-- The medics paid for an act: the one who acts, then the other members of the call's team who are
-- on duty within `teamShareRadius` of the patient.
function S:teamAtScene(call, medic)
    local team = { medic }
    local radius = self.cfg.teamShareRadius or 0
    for _, m in ipairs(teamList(call)) do
        if m ~= medic and radius > 0 and self:isMedic(m) then
            local d = self.P.players.distance(m, call.position)
            if d and d <= radius then team[#team + 1] = m end
        end
    end
    return team
end

-- A response act on a patient: take the call, ask consent when the patient pays, hold the charge.
function S:reserveCare(ctx, kind)
    local cfg, M = self.cfg, self.M
    local medic = ctx.playerId
    local patient, call = self:patientOf(ctx)
    if not patient then
        self:refuseTo(medic, "patient_gone")
        return nil, "patient_gone"
    end
    local ok, why = self:assign(call, medic)
    if not ok then
        self:refuseTo(medic, why)
        return nil, why
    end
    -- The patient's consent: needed when they pay part of it and hold no plan.
    local subject = self:subjectOf(patient)
    local plan = subject and self:ensurePlan(subject) or nil
    local insured = M.active(plan, self.P.now())
    local coverage = M.coverage(cfg, plan or nil, kind, self.P.now())
    if not insured and coverage < 1 and (cfg.fees[kind] or 0) > 0 then
        local consent = call.consent
        if consent and consent.state == "declined" and self.P.nowMs() - consent.at > cfg.consent.declinedSeconds * 1000 then
            consent = nil
        end
        if not consent then
            local fees = cfg.fees
            self:tell(medic, ("Asking %s to accept the charges (%d s)..."):format(self:nameOf(patient),
                math.floor(cfg.consent.timeoutMs / 1000)))
            -- Stable already (the stabilisation is paid; a restart or a new medic asks again): only
            -- what is left to pay is named.
            local charges = kind == "evacuate" and call.stable
                and ("the evacuation to %s (%s) is charged to you"):format(cfg.evacuation.label, M.money(fees.evacuate))
                or ("stabilisation %s and evacuation to %s %s are charged to you"):format(M.money(fees.stabilise),
                    cfg.evacuation.label, M.money(fees.evacuate))
            local state = self:askConsent(patient, ("A Trauma Team medic is with you. You hold no plan: %s " ..
                "(bank, then cash; the rest is invoiced). Accept?"):format(charges))
            consent = { state = state, at = self.P.nowMs() }
            call.consent = consent
            if not self.P.actions.verify(ctx.opId, "reserve") then return nil, "not_owner" end
            if self:patientOf(ctx) ~= patient then
                self:refuseTo(medic, "patient_gone")
                return nil, "patient_gone"
            end
        end
        if consent.state == "declined" then
            self:tell(medic, ("%s refuses the charges: no treatment."):format(self:nameOf(patient)), "warning")
            self:tell(patient, "You refused Trauma Team's charges.")
            return nil, "patient_declined"
        end
    end
    local res, qwhy = self:quote({ patient = patient, medic = medic, kind = kind, team = self:teamAtScene(call, medic),
        ttlMs = cfg.actions[kind].durationMs + 60000 })
    if not res then
        self:refuseTo(medic, qwhy)
        return nil, M.token(qwhy, "refused")
    end
    local r = { kind = kind, txOpId = res.txOpId, patient = patient, medic = medic, episode = call.episode,
        callId = call.id, subject = res.subject, tier = res.tier, fee = res.fee, covered = res.covered,
        fromBank = res.fromBank, fromCash = res.fromCash, paid = res.paid, invoiced = res.invoiced, cut = res.cut,
        bounty = res.bounty, unbilled = res.unbilled, consent = call.consent and call.consent.state or "plan",
        team = res.team, teamPay = res.teamPay }
    self.work[ctx.opId] = r
    return r
end

function S:commit(ctx)
    if not fromActions() then return nil, "not_owner" end
    if not self.P.actions.verify(ctx.opId, "commit") then return nil, "not_owner" end
    local kind = self.kinds[ctx.actionId]
    local r = ctx.reservation
    if type(r) ~= "table" or r.kind ~= kind then return nil, "no_reservation" end
    if kind == "stabilise" or kind == "evacuate" then
        -- The patient must still be down in the same episode, or nothing is charged.
        local patient = self:patientOf(ctx)
        if patient ~= r.patient and not self.done[r.txOpId or ctx.opId] then return nil, "patient_gone" end
    end
    if r.txOpId then
        local receipt, why = self.L.commit(r.txOpId)
        if not receipt then
            if why == "coordinator_unavailable" then why = "in_doubt" end
            if why == "in_doubt" or why == "busy" then self.doubts[r.txOpId] = r end
            return nil, why
        end
        r.replay = receipt.replay == true
    end
    local ok, err = pcall(self.afterCommit, self, r, r.txOpId or ctx.opId)
    if not ok then self:warn("after commit %s raised: %s", tostring(r.txOpId or ctx.opId), tostring(err)) end
    self.work[ctx.opId] = nil
    return { tx = r.txOpId, kind = kind, replay = r.replay == true }
end

function S:cancelHook(ctx)
    if not fromActions() then return end
    self.work[ctx.opId] = nil
    local r = ctx.reservation
    if type(r) ~= "table" or not r.txOpId then return end
    if ctx.reason == "in_doubt" then
        -- The commit may have happened: never cancel; settle with the coordinator's fence.
        self.doubts[r.txOpId] = r
        self.stats.doubts = self.stats.doubts + 1
        self:settleDoubt(r)
        return
    end
    self.L.cancel(r.txOpId, ctx.reason)
end

-- An in-doubt operation: ask the coordinator; once committed, the after-commit step runs once.
function S:settleDoubt(r)
    local outcome = self.L.settle(r.txOpId)
    if outcome == "committed" then
        self.doubts[r.txOpId] = nil
        local ok, err = pcall(self.afterCommit, self, r, r.txOpId)
        if not ok then self:warn("after commit %s raised: %s", r.txOpId, tostring(err)) end
    elseif outcome == "failed" or outcome == "aborted" then
        self.doubts[r.txOpId] = nil
        self:log("%s %s settled: %s (nothing moved)", tostring(r.kind), r.txOpId, outcome)
        local pid = r.pid or r.medic
        if pid then self:tell(pid, "Trauma Team could not confirm that: nothing was charged, try again.", "warning") end
    end
    return outcome
end

-- What follows a committed act, exactly once per operation.
function S:afterCommit(r, key)
    if self.done[key] then return end
    self.done[key] = self.P.nowMs()
    self.doubts[key] = nil
    if r.kind == "plan" then return self:afterPlan(r) end
    self:afterCharge(r)
    if r.kind == "stabilise" then return self:afterStabilise(r, key) end
    if r.kind == "evacuate" then return self:afterEvacuate(r, key) end
end

function S:afterPlan(r)
    local M, cfg = self.M, self.cfg
    local plan = { tier = r.tier, untilAt = r.untilAt, startedAt = r.startedAt, periods = r.periods,
        autoRenew = r.autoRenew }
    self.plans[r.subject] = plan
    self.cards[r.subject] = true
    self.files[r.subject] = true
    self.stats.plans = self.stats.plans + 1
    local tier = cfg.plans[r.tier]
    local paid = {}
    if (r.fromBank or 0) > 0 then paid[#paid + 1] = M.money(r.fromBank) .. " from your account" end
    if (r.fromCash or 0) > 0 then paid[#paid + 1] = M.money(r.fromCash) .. " in cash" end
    local text = ("Trauma Team %s %s: active for %s (%s). Priority %d. Auto-renewal %s."):format(tier.label,
        r.mode == "renew" and "renewed" or "signed", M.duration(r.untilAt - self.P.now()), table.concat(paid, ", "),
        tier.priority, r.autoRenew and "on" or "off")
    self:record(r.subject, { kind = "plan", opId = r.txOpId, text = text })
    self:log("plan %s: %s %s %s until %d", r.txOpId, tostring(r.subject), r.mode, r.tier, r.untilAt)
    if self:subjectOf(r.pid) == r.subject then self:tell(r.pid, text, "success", "Trauma Team " .. tier.label) end
    self.P.emit("rp_trauma:subscribed", r.pid, r.tier, r.untilAt)
    self:jobCompleted("subscribe", r.pid, r.txOpId, { tier = r.tier, untilAt = r.untilAt, price = r.price,
        mode = r.mode })
end

-- The other team members' pay lines (the acting medic is told with the act's result).
function S:tellTeam(r, callLabel)
    for i, m in ipairs(r.team or {}) do
        if i > 1 and (r.teamPay and r.teamPay[i] or 0) > 0 then
            self:tell(m, ("Team pay, %s: %s."):format(callLabel, self.M.paySentence(r, i)), "success")
        end
    end
end

function S:chargeLine(r)
    if r.unbilled then return "billing offline: nothing charged" end
    return self.M.chargeSentence(r)
end

function S:afterStabilise(r, key)
    local call = self.calls[r.patient]
    if call and call.episode == r.episode then
        call.stable = true
        call.stabilisedBy = r.medic
        self:targetPatient(call)
    end
    self.stats.stabilised = self.stats.stabilised + 1
    if self.down and self.down.stabilise then self.down.stabilise(r.patient, self.cfg.actions.stabilise.health) end
    local medicName, patientName = self:nameOf(r.medic), self:nameOf(r.patient)
    self:tell(r.patient, ("Stabilised by %s. Hold on: evacuation next. Charges: %s."):format(medicName,
        self:chargeLine(r)), "success")
    self:tell(r.medic, ("%s is stable. Evacuate them (E on the body). Pay: %s."):format(patientName,
        self.M.paySentence(r, 1)), "success")
    self:tellTeam(r, ("call #%s stabilised"):format(tostring(r.callId)))
    self:log("stabilise %s: player %d by %d fee=%d covered=%d paid=%d invoiced=%d cut=%d bounty=%d%s", tostring(key),
        r.patient, r.medic, r.fee or 0, r.covered or 0, r.paid or 0, r.invoiced or 0, r.cut or 0, r.bounty or 0,
        r.unbilled and (" unbilled=" .. r.unbilled) or "")
    self:jobCompleted("stabilise", r.medic, key, { patient = r.patient, call = r.callId, tier = r.tier or false,
        fee = r.fee, covered = r.covered, paid = r.paid, invoiced = r.invoiced, cut = r.cut, bounty = r.bounty,
        team = r.team, teamPay = r.teamPay })
end

function S:afterEvacuate(r, key)
    local cfg = self.cfg
    local tier = r.tier and cfg.plans[r.tier]
    local health = tier and tier.evacHealth or self.shared.reviveHealthFraction or 0.5
    local drop = cfg.evacuation.drop or (self.shared.hospital and self.shared.hospital.respawn)
    local heading = cfg.evacuation.heading or (self.shared.hospital and self.shared.hospital.heading) or 0.0
    self.stats.evacuated = self.stats.evacuated + 1
    local moved, why = true, nil
    if self.down and self.down.evacuate then
        moved, why = self.down.evacuate(r.patient, { position = drop, heading = heading, health = health,
            by = r.medic })
    end
    local patientName = self:nameOf(r.patient)
    if moved then
        self:tell(r.patient, ("Trauma Team brought you to %s. Charges: %s."):format(cfg.evacuation.label,
            self:chargeLine(r)), "success", "Trauma Team")
    else
        self:tell(r.patient, ("The evacuation failed (%s): you are released where you lie. Charges: %s."):format(
            tostring(why), self:chargeLine(r)), "warning")
    end
    self:tell(r.medic, ("%s evacuated to %s. Pay: %s."):format(patientName, cfg.evacuation.label,
        self.M.paySentence(r, 1)), "success")
    self:tellTeam(r, ("call #%s evacuated"):format(tostring(r.callId)))
    self:log("evacuate %s: player %d by %d moved=%s%s fee=%d covered=%d paid=%d invoiced=%d cut=%d bounty=%d",
        tostring(key), r.patient, r.medic, tostring(moved), why and (" (" .. tostring(why) .. ")") or "", r.fee or 0,
        r.covered or 0, r.paid or 0, r.invoiced or 0, r.cut or 0, r.bounty or 0)
    self.P.emit("rp_trauma:revived", r.patient, r.medic)
    self:jobCompleted("evacuate", r.medic, key, { patient = r.patient, call = r.callId, tier = r.tier or false,
        destination = cfg.evacuation.label, fee = r.fee, covered = r.covered, paid = r.paid, invoiced = r.invoiced,
        cut = r.cut, bounty = r.bounty, team = r.team, teamPay = r.teamPay, moved = moved == true })
end

-- ---------------------------------------------------------------------------------------------
-- Automatic renewals (connected holders whose plan ended and who keep auto-renewal on)
-- ---------------------------------------------------------------------------------------------
function S:renew(pid, subject, plan)
    local cfg, M, L = self.cfg, self.M, self.L
    local tier = cfg.plans[plan.tier]
    if not tier then return nil, "unknown_plan" end
    local opId = M.renewOpId(subject, plan.untilAt)
    local state = self.renewals[opId] or {}
    self.renewals[opId] = state
    if state.done or (state.nextTry or 0) > self.P.now() then return nil, "waiting" end
    local renewal = M.renewal(cfg, plan, self.P.now())
    renewal.autoRenew = true
    local bank = L.account(pid, "bank")
    local ch, why = M.charge({ fee = tier.price, coverage = 0, funds = { bank = L.funds(bank) },
        order = cfg.autoRenew.from, accounts = { bank = bank, society = "soc:" .. cfg.society }, invoice = false,
        reason = "trauma plan renewal" })
    if ch then
        local lines = ch.lines
        lines[#lines + 1] = M.cardLine(cfg, subject, true, renewal)
        local receipt
        receipt, why = L.transfer({ opId = opId, kind = "trauma.renew", actor = bank,
            reason = ("trauma %s renewal"):format(plan.tier), lines = lines })
        if receipt or why == "op_id_conflict" or why == "already_committed" then
            state.done = true
            if receipt then
                self.plans[subject] = renewal
                self.stats.renewals = self.stats.renewals + 1
                self:tell(pid, ("Trauma Team %s renewed: %s from your account, active for %s."):format(tier.label,
                    M.money(tier.price), M.duration(renewal.untilAt - self.P.now())), "success")
                self:log("renewal %s: %s %s until %d%s", opId, subject, plan.tier, renewal.untilAt,
                    receipt.replay and " (replay)" or "")
                self:jobCompleted("subscribe", pid, opId, { tier = plan.tier, untilAt = renewal.untilAt,
                    price = tier.price, mode = "auto_renew" })
            else
                self:loadFile(subject)
            end
            return true
        end
    end
    if BILLING_DOWN[why] or why == "in_doubt" then return nil, why end   -- next sweep, same id
    state.nextTry = self.P.now() + 600
    if not state.told then
        state.told = true
        self:tell(pid, ("Trauma Team %s ended and its renewal failed (%s): you are not covered. " ..
            "Renew at a Trauma Team kiosk."):format(tier.label, M.textFor(why or "insufficient_funds")), "warning")
    end
    return nil, why
end

function S:renewalSweep()
    local now = self.P.now()
    for _, pid in ipairs(self.P.players.all()) do
        local subject = self.subjects[pid]
        local plan = subject and self.plans[subject]
        if type(plan) == "table" and plan.autoRenew and not self.M.active(plan, now) and self.cfg.plans[plan.tier] then
            self:renew(pid, subject, plan)
        end
    end
end

-- ---------------------------------------------------------------------------------------------
-- Holder commands: status, invoices, auto-renewal
-- ---------------------------------------------------------------------------------------------
function S:statusLines(pid)
    local M, now = self.M, self.P.now()
    local subject = self:subjectOf(pid)
    local plan = subject and self.plans[subject]
    local lines = {}
    local tier = M.activeTier(self.cfg, plan, now)
    if tier then
        lines[#lines + 1] = ("Trauma Team %s, %s left, priority %d, auto-renewal %s."):format(tier.label,
            M.duration(plan.untilAt - now), tier.priority, plan.autoRenew and "on" or "off")
    elseif type(plan) == "table" then
        lines[#lines + 1] = ("Your Trauma Team %s plan has ended: renew it at a kiosk (/tti plans)."):format(
            (self.cfg.plans[plan.tier] or {}).label or plan.tier)
    else
        lines[#lines + 1] = "No Trauma Team plan: kiosks sell Silver, Gold and Platinum (/tti plans)."
    end
    local owed = subject and self.owed[subject] or 0
    if owed > 0 then lines[#lines + 1] = ("Unpaid Trauma Team invoices: %s (/tti pay)."):format(M.money(owed)) end
    return lines
end

function S:planLines()
    local M, out = self.M, {}
    for _, key in ipairs(self.cfg.planOrder) do
        local t = self.cfg.plans[key]
        out[#out + 1] = ("%s: %s per %d days, priority %d. %s"):format(t.label, M.money(t.price),
            math.floor(t.periodHours / 24), t.priority, t.pitch)
    end
    for _, k in ipairs(self.cfg.kiosks) do
        if k.enabled ~= false then out[#out + 1] = ("Kiosk: %s (%s)"):format(k.landmark, M.fmtPos(k.position)) end
    end
    return out
end

-- /tti pay: every invoice the wallets can cover, one operation. Yields.
function S:payInvoices(pid)
    local cfg, M, L = self.cfg, self.M, self.L
    if not L.ready() then return nil, "trauma_unavailable" end
    local subject, why = self:subjectOf(pid)
    if not subject then return nil, why end
    local snap, rwhy = L.read(self:fileOf(subject))
    if type(snap) ~= "table" then
        if rwhy == "unknown_account" then return nil, "nothing_owed" end
        return nil, rwhy
    end
    local owed = M.itemCount(snap, "tti_invoice")
    self.owed[subject] = owed
    if owed <= 0 then return nil, "nothing_owed" end
    local bank, cash = L.account(pid, "bank"), L.account(pid, "cash")
    local r = M.settleInvoice(owed, { bank = L.funds(bank), cash = L.funds(cash) }, cfg.invoices.payFrom,
        { bank = bank, cash = cash, society = "soc:" .. cfg.society, file = self:fileOf(subject),
          billing = cfg.accounts.billing }, "trauma invoice")
    if r.paid <= 0 then return nil, "nothing_paid" end
    local opId = L.newOpId("pay")
    local receipt
    for _ = 1, 3 do
        receipt, why = L.transfer({ opId = opId, kind = "trauma.invoice", actor = bank, reason = "trauma invoices",
            lines = r.lines })
        if receipt or not BILLING_DOWN[why] then break end
        Wait(1000)
    end
    if not receipt then return nil, why end
    self.owed[subject] = math.max(0, owed - r.paid)
    self.stats.invoicesPaid = self.stats.invoicesPaid + r.paid
    self:log("invoices %s: %s paid %d (bank %d, cash %d), %d left", opId, subject, r.paid, r.fromBank, r.fromCash,
        self.owed[subject])
    return r, self.owed[subject]
end

-- /tti autorenew on|off: the card's metadata, one operation. Yields.
function S:setAutoRenew(pid, on)
    local L, M = self.L, self.M
    local subject, why = self:subjectOf(pid)
    if not subject then return nil, why end
    local plan = self:ensurePlan(subject)
    if type(plan) ~= "table" then return nil, plan == false and "no_plan" or "trauma_unavailable" end
    local receipt
    receipt, why = L.transfer({ opId = L.newOpId("pref"), kind = "trauma.pref", reason = "auto-renewal",
        lines = { { instance = M.cardInstance(subject), at = self:fileOf(subject), metaPatch = { autoRenew = on } } } })
    if not receipt then return nil, why end
    plan.autoRenew = on
    return true
end

-- ---------------------------------------------------------------------------------------------
-- rp_trauma 1.x import (once per player): active contract -> plan, unpaid bills -> invoices
-- ---------------------------------------------------------------------------------------------
function S:importLegacy(pid, subject)
    local cfg, M, L, P = self.cfg, self.M, self.L, self.P
    if not cfg.legacy.enabled or self.legacyChecked[subject] then return end
    self.legacyChecked[subject] = true
    local identifier = P.players.identifier(pid)
    if type(identifier) ~= "string" or identifier == "" then return end
    local bills, contract = {}, nil
    local sql = P.db.ready()
    if sql then
        local rows = P.db.query("SELECT id, amount FROM rp_trauma_bills WHERE identifier = ? AND paid_at IS NULL ORDER BY id ASC",
            { identifier })
        for _, row in ipairs(type(rows) == "table" and rows or {}) do
            local amount = math.tointeger(tonumber(row.amount)) or 0
            if amount > 0 then bills[#bills + 1] = { key = "bill:" .. tostring(row.id), amount = amount, id = row.id } end
        end
        local c = P.db.query("SELECT until_at FROM rp_trauma_contracts WHERE identifier = ? AND active = 1", { identifier })
        if type(c) == "table" and c[1] then contract = { untilAt = math.tointeger(tonumber(c[1].until_at)) or 0, sql = true } end
    end
    local debt = math.tointeger(tonumber(P.kvp.get("debt:" .. identifier, 0))) or 0
    if debt > 0 then bills[#bills + 1] = { key = "kvp:" .. M.fnv(identifier), amount = debt, kvp = true } end
    if not contract and (tonumber(P.kvp.get("contract:" .. identifier .. ":active", 0)) or 0) == 1 then
        contract = { untilAt = math.tointeger(tonumber(P.kvp.get("contract:" .. identifier .. ":until", 0))) or 0, kvp = true }
    end
    if #bills == 0 and not contract then return end
    if not self:openFile(subject) then
        self.legacyChecked[subject] = nil
        return
    end
    for _, b in ipairs(bills) do
        local receipt, why = L.transfer({ opId = "tt.legacy." .. b.key, kind = "trauma.legacy", reason = "rp_trauma 1.x bill",
            lines = { { item = "tti_invoice", count = b.amount, from = cfg.accounts.billing, to = self:fileOf(subject) } } })
        if receipt or why == "op_id_conflict" then
            if receipt and not receipt.replay then
                self.owed[subject] = (self.owed[subject] or 0) + b.amount
            end
            if b.id then P.db.update("UPDATE rp_trauma_bills SET paid_at = 0 WHERE id = ?", { b.id }) end
            if b.kvp then P.kvp.delete("debt:" .. identifier) end
            self.stats.legacy = self.stats.legacy + 1
            self:log("legacy bill %s of %s imported as %d eddies invoiced", b.key, subject, b.amount)
        else
            self:warn("legacy bill %s of %s not imported: %s", b.key, subject, tostring(why))
            self.legacyChecked[subject] = nil
        end
    end
    if contract then
        local now = P.now()
        self:ensurePlan(subject)
        local hasCard = self.cards[subject]
        local imported = hasCard ~= nil            -- unknown file: try again on the next join
        if not imported then self.legacyChecked[subject] = nil end
        if imported and contract.untilAt > now and hasCard == false and cfg.plans[cfg.legacy.contractTier] then
            local card = M.cardLine(cfg, subject, false, { tier = cfg.legacy.contractTier, untilAt = contract.untilAt,
                startedAt = now, periods = 1, autoRenew = cfg.autoRenew.default })
            local receipt, why = L.transfer({ opId = ("tt.legacy.contract:%s:%d"):format(M.fnv(identifier), contract.untilAt),
                kind = "trauma.legacy", reason = "rp_trauma 1.x contract", lines = { card } })
            if receipt or why == "op_id_conflict" then
                self:loadFile(subject)
                self:log("legacy contract of %s imported as %s until %d", subject, cfg.legacy.contractTier, contract.untilAt)
            else
                imported = false
                self.legacyChecked[subject] = nil
                self:warn("legacy contract of %s not imported: %s", subject, tostring(why))
            end
        end
        if imported then
            if contract.sql then P.db.update("UPDATE rp_trauma_contracts SET active = 0 WHERE identifier = ?", { identifier }) end
            if contract.kvp then
                for _, k in ipairs({ "active", "until", "failures", "started" }) do P.kvp.delete("contract:" .. identifier .. ":" .. k) end
            end
        end
    end
end

-- ---------------------------------------------------------------------------------------------
-- Players
-- ---------------------------------------------------------------------------------------------
-- A player is in the world: their file is read (plan, invoices), the 1.x import runs once. Yields.
function S:onReady(pid)
    for _ = 1, 60 do
        if self.L.ready() then break end
        Wait(1000)
    end
    if not self.L.ready() then return end
    local subject = self:subjectOf(pid)
    if not subject then return end
    self.plans[subject] = nil
    self:loadFile(subject)
    self:importLegacy(pid, subject)
    local plan = self.plans[subject]
    local now = self.P.now()
    local tier = self.M.activeTier(self.cfg, plan, now)
    if tier then
        self:tell(pid, ("Trauma Team %s active, %s left."):format(tier.label, self.M.duration(plan.untilAt - now)))
    end
    if (self.owed[subject] or 0) > 0 then
        self:tell(pid, ("Trauma Team reminder: %s in unpaid invoices (/tti pay)."):format(self.M.money(self.owed[subject])),
            "warning")
    end
end

function S:onDisconnected(pid)
    self:leaveTeam(pid, "disconnected")
    self.subjects[pid] = nil
    self.notified[pid] = nil
end

function S:onDutyChanged(pid)
    if self:isMedic(pid) == false then self:leaveTeam(pid, "off duty") end
end

-- ---------------------------------------------------------------------------------------------
-- The sweep: dispatch held-back calls, remind untaken ones, settle doubts, renew plans.
-- ---------------------------------------------------------------------------------------------
function S:sweep()
    local now = self.P.nowMs()
    for _, call in pairs(self.calls) do
        if not call.announced then
            if now >= call.dispatchAt then self:announce(call) end
        elseif call.state == "open" and now - call.lastAnnounce >= self.cfg.calls.remindSeconds * 1000 then
            self:announce(call, true)
        end
    end
    if now - self.lastDoubtSweep >= 5000 then
        self.lastDoubtSweep = now
        local n = 0
        for _, r in pairs(self.doubts) do
            n = n + 1
            if n > 16 then break end
            self:settleDoubt(r)
        end
    end
    if self.ready and now - self.lastRenewSweep >= self.cfg.autoRenew.sweepSeconds * 1000 then
        self.lastRenewSweep = now
        self:renewalSweep()
    end
end

function S:shutdown()
    for _, call in pairs(self.calls) do self:untargetPatient(call) end
end

return S
