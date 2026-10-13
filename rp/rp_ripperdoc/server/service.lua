-- rp_ripperdoc / server/service.lua: the clinic, as hooks of the world-interaction libraries.
--
--   quote     ALT+click > Quote, or /ripper quote: the catalogue (UI kit) on the ripperdoc's screen,
--             then a CONSENTED Open77.playerInteractions offer to the patient. Accepting places ONE
--             coordinator hold: the price out of the patient's wallet and the boxed implant out of
--             the clinic's stock (nothing moves yet). The hold and the cyberware operation id are
--             written to the journal.
--   chair     the patient lies on the operating chair: this resource's `lie_<clinic>` action
--             (placed mode, Open77.animations.playAt at the chair through open77_actions) or a real
--             furniture through open77_seating (seating mode).
--   operate   the station target offers the accepted procedure (`op_<implant>_<grade>` or
--             `rm_<implant>`): an open77_actions action on the ripperdoc. reserve = adopt the hold;
--             commit = Open77.cyberware.install / remove keyed by the surgery's operation id, then
--             the hold commits (price to the society, implant out of stock) exactly once; cancel =
--             the hold is released. A UI-kit bar runs on the patient too (X stops it).
--   restock   the supplier target (`restock` action): the order menu, a reservation (boxes minted
--             out of sys:ripperdoc.supplier, price burned into it from the society or the
--             ripperdoc's cash), committed after the bar.
--   buy-back  /ripper buy: a consented `give` offer to a player, then one transfer (their boxes into
--             the stock, the price to them).
--
-- Durable state: the coordinator (stock, wallets, society) and the patient's cyberware record. The
-- journal (server/journal.lua) only remembers which procedures were in flight, so a restart can
-- release a hold that never installed or settle one that did.
--
-- Global: RipperService.

RipperService = {}
local S = {}
S.__index = S

local HOOKS = { validate = "rdValidate", reserve = "rdReserve", commit = "rdCommit", cancel = "rdCancel" }
local PLAIN = { validate = "rdValidate", commit = "rdCommit" }
local TERMINAL = { committed = true, cancelled = true, failed = true, in_doubt = true }
local LIVE = { offered = true, reserved = true, operating = true, installing = true }

function RipperService.new(deps)
    return setmetatable({
        cfg = deps.config, M = deps.model, L = deps.ledger, P = deps.ports, J = deps.journal,
        resource = deps.resource or "rp_ripperdoc",
        clinics = {},          -- [key] = { key, cfg, stock, opened, stationChoice }
        targetClinic = {},     -- [target key] = clinic key
        actionKinds = {},      -- [actionId] = { kind = "lie"|"idle"|"operate"|"restock", ... }
        surgeries = {},        -- [surgery id] = s (live, then kept 10 minutes for replays)
        offers = {},           -- [interaction id] = s (a quote waiting for consent)
        byPlayer = {},         -- [playerId] = s (ripperdoc and patient of a live quote / surgery)
        byClinic = {},         -- [clinic key] = s (one procedure at a time per clinic)
        byTicket = {},         -- [cyberware ticket] = s
        lying = {},            -- [playerId] = { opId, clinic } (placed chairs)
        buys = {},             -- [interaction id] = buy-back offer
        buyOf = {},            -- [ripperdoc id] = interaction id
        buyDoubts = {},        -- [opId] = buy-back whose transfer is in doubt
        restocks = {},         -- [actions opId] = restock reservation
        doubts = {},           -- [txOpId] = restock reservation whose commit is in doubt
        recovering = {},       -- [surgery id] = journal row of an install a previous boot did not settle
        done = {},             -- [opId] = ms, after-commit steps already run
        notified = {},         -- [playerId] = ms of the last refusal message
        defined = {}, defineReason = {},
        profiles = {},
        ready = false, bootAt = 0,
        stats = { quotes = 0, accepted = 0, declined = 0, operations = 0, installs = 0, removals = 0,
                  cancelled = 0, failed = 0, settled = 0, unpaid = 0, restocks = 0, buybacks = 0,
                  refusals = 0, recovered = 0 },
    }, S)
end

function S:log(fmt, ...) self.P.log(fmt:format(...)) end
function S:warn(fmt, ...) self.P.warn(fmt:format(...)) end

local function fromActions() return GetInvokingResource() == "open77_actions" end
S.fromActions = fromActions

-- ---------------------------------------------------------------------------------------------
-- Players
-- ---------------------------------------------------------------------------------------------
function S:tell(pid, text, kind)
    pid = self.M.playerId(pid)
    if pid then self.P.tell(pid, text, kind) end
end

function S:refuseTo(pid, reason)
    self.stats.refusals = self.stats.refusals + 1
    pid = self.M.playerId(pid)
    if not pid then return end
    local now = self.P.now()
    if (self.notified[pid] or 0) + self.cfg.notifyCooldownMs > now then return end
    self.notified[pid] = now
    self.P.tell(pid, self.M.textFor(reason), "warning")
end

function S:nameOf(pid)
    return self.P.identity.fullName(pid) or self.P.players.name(pid) or ("player " .. tostring(pid))
end

-- The player still is the subject a deferred step is about (session ids are reused).
function S:isSubject(pid, subject)
    return pid ~= nil and subject ~= nil and self.P.players.name(pid) ~= nil and self.L.subjectOf(pid) == subject
end

function S:playerBySubject(subject)
    if not subject then return nil end
    for _, pid in ipairs(self.P.players.all()) do
        if self.L.subjectOf(pid) == subject then return pid end
    end
    return nil
end

-- Tell whoever is connected under that subject now.
function S:tellSubject(subject, text, kind, pidHint)
    local pid = (pidHint and self:isSubject(pidHint, subject)) and pidHint or self:playerBySubject(subject)
    if pid then self:tell(pid, text, kind) end
    return pid
end

function S:posOf(pid)
    local read = self.P.players.get(pid)
    if type(read) == "table" and type(read.position) == "table" then
        return { x = read.position.x, y = read.position.y, z = read.position.z, bucket = read.bucket or 0 }
    end
    local p = self.P.players.position(pid)
    if type(p) == "table" then return { x = p.x, y = p.y, z = p.z, bucket = p.bucket or 0 } end
    return nil
end

function S:isDead(pid)
    local read = self.P.players.get(pid)
    return type(read) == "table" and (read.alive == false or read.dead == true)
end

-- ---------------------------------------------------------------------------------------------
-- Clinics
-- ---------------------------------------------------------------------------------------------
-- Inside the clinic: the rp_zones zone, or (rp_zones stopped, or its tracking late) within
-- `zoneRadius` of the chair.
function S:inClinic(pid, clinic)
    if not clinic.cfg.zone then return true end
    if self.P.zones.isIn(pid, clinic.cfg.zone) then return true end
    local d = self.M.distance(self:posOf(pid), clinic.cfg.chair.position)
    return d ~= nil and d <= (clinic.cfg.zoneRadius or 12.0)
end

function S:clinicOf(pid)
    for _, key in ipairs(self.cfg.clinicOrder) do
        local clinic = self.clinics[key]
        if clinic and clinic.opened and self:inClinic(pid, clinic) then return clinic end
    end
    return nil
end

-- Is the surgery's patient lying on its clinic's chair?
function S:onChair(s)
    local clinic = self.clinics[s.clinic]
    if not clinic then return false end
    if clinic.cfg.chair.mode == "seating" then
        return self:seatedOn(s.patient, clinic)
    end
    local l = self.lying[s.patient]
    return l ~= nil and l.clinic == s.clinic
end

-- Seating mode: the patient's open77_seating session is on the clinic's furniture (and settled).
function S:seatedOn(pid, clinic)
    local session = self.P.seating.current(pid)
    return session ~= nil and (session.state == nil or session.state == "seated")
        and tostring(session.furnitureId) == tostring(clinic.cfg.chair.furniture)
end

function S:isLying(pid)
    if self.lying[pid] then return true end
    for _, clinic in pairs(self.clinics) do
        if clinic.cfg.chair.mode == "seating" and self:seatedOn(pid, clinic) then return true end
    end
    return false
end

-- The patient lies on a chair: get them up for the consent step (the interaction coordinator
-- refuses a participant in an animation). Answers whether they were lying.
function S:standUp(pid)
    local l = self.lying[pid]
    if l then
        self.P.actions.cancel(l.opId, "quote_offered")
        return true
    end
    local session = self.P.seating.current(pid)
    if session then
        for _, clinic in pairs(self.clinics) do
            if tostring(session.furnitureId) == tostring(clinic.cfg.chair.furniture) then
                self.P.seating.stand(pid)
                return true
            end
        end
    end
    return false
end

-- Puts a patient back on the chair (after a quote, when they were lying before it).
function S:lieAgain(pid, clinicKey)
    local clinic = self.clinics[clinicKey]
    if not clinic then return end
    local chair = clinic.cfg.chair
    local ok, why
    if chair.mode == "seating" then
        ok, why = self.P.seating.sit(pid, chair.furniture, chair.spot and { spot = chair.spot } or nil)
    else
        ok, why = self.P.actions.request(pid, "lie_" .. clinic.key, clinic.key .. "_chair")
    end
    if not ok then
        self:tell(pid, ("Sit back in the operating chair (E): %s"):format(self.M.textFor(why)), "info")
    end
end

-- ---------------------------------------------------------------------------------------------
-- Boot steps (re-run whenever a library restarts)
-- ---------------------------------------------------------------------------------------------
function S:defineItems()
    local registered, rejected, details = self.P.inventory.define(self.cfg.items)
    if registered == nil then
        self:warn("rp_inventory:define unavailable (%s): boxed implants not defined yet", tostring(rejected))
        return false
    end
    if (tonumber(rejected) or 0) > 0 then
        local names = {}
        for _, c in ipairs(type(details) == "table" and details.collisions or {}) do names[#names + 1] = tostring(c) end
        self:warn("boxed implants: %s registered, %s refused %s (another definer owns them?)", tostring(registered),
            tostring(rejected), table.concat(names, ","))
    else
        self:log("boxed implants defined through rp_inventory: %s", tostring(registered))
    end
    return true
end

local function platformGrade(grade)
    local g = {}
    for k, v in pairs(grade) do
        if k ~= "label" and k ~= "price" and k ~= "durationMs" and k ~= "hacking" and k ~= "item"
            and k ~= "components" then
            g[k] = v
        end
    end
    return g
end

-- Registers every implant with the platform (and the hacking grade first for the three hacking
-- implants). A refused entry stays in the catalogue as "provider offline".
function S:defineCatalogue()
    for _, entry in ipairs(self.cfg.catalogue) do
        local ok, reason = true, nil
        if entry.hacking then
            local grades = {}
            for _, grade in ipairs(entry.grades) do
                local hg = { id = grade.id }
                for k, v in pairs(grade.hacking or {}) do hg[k] = v end
                grades[#grades + 1] = hg
            end
            local result, why = self.P.hacking.define(entry.hacking,
                { id = entry.definitionId, version = entry.version, grades = grades })
            if not result then ok, reason = false, tostring(why) end
        end
        if ok then
            local grades = {}
            for _, grade in ipairs(entry.grades) do grades[#grades + 1] = platformGrade(grade) end
            local result, why = self.P.cyberware.define({ id = entry.definitionId, version = entry.version,
                slot = entry.slot, profile = entry.profile, grades = grades })
            if not result then ok, reason = false, tostring(why) end
        end
        self.defined[entry.key] = ok or nil
        self.defineReason[entry.key] = (not ok) and reason or nil
        if ok then
            self:log("catalogue %s defined (%s/%s, %d grade(s))", entry.key, entry.slot, entry.profile, #entry.grades)
        else
            self:log("catalogue %s NOT defined: %s", entry.key, tostring(reason))
        end
    end
end

-- Opens (creates or re-capacities) every clinic's stock stash. Deterministic ids: a restart finds
-- the same boxes. Returns how many clinics are open.
function S:openClinics()
    local opened = 0
    for _, key in ipairs(self.cfg.clinicOrder) do
        local cc = self.cfg.clinics[key]
        if cc and self.M.validKey(key) then
            local clinic = self.clinics[key] or { key = key, cfg = cc, stock = self.M.stockAccount(key) }
            self.clinics[key] = clinic
            if not clinic.opened then
                local opened1, why = self.L.open(clinic.stock, { capacityG = cc.stockCapacityG,
                    meta = { app = "rp_ripperdoc", clinic = key, role = "stock" } })
                if type(opened1) == "table" then
                    clinic.opened = true
                else
                    self:warn("clinic %s: stock %s not open (%s)", key, clinic.stock, tostring(why))
                end
            end
            if clinic.opened then opened = opened + 1 end
        end
    end
    return opened
end

-- The first profile of a list the server's RP catalogue knows, or nil (the action then runs
-- without an animation).
function S:resolveProfile(list, what)
    for _, profile in ipairs(list or {}) do
        if self.P.profileKnown(profile) then return profile end
    end
    self:warn("%s: none of [%s] is in the RP animation catalogue; it runs without an animation", what,
        table.concat(list or {}, ", "))
    return nil
end

function S:actionDefinitions()
    local cfg, M = self.cfg, self.M
    local defs, kinds = {}, {}
    local messages = M.actionMessages()
    local function add(def, kind)
        def.messages = def.messages or messages      -- open77_actions shows these words, not the codes
        defs[#defs + 1] = def
        kinds[def.id] = kind
    end
    for _, key in ipairs(cfg.clinicOrder) do
        local clinic = self.clinics[key]
        local chair = clinic and clinic.cfg.chair
        if clinic and chair.mode ~= "seating" then
            local profile = self:resolveProfile(chair.profiles, "the lying posture of " .. key)
            self.profiles["lie_" .. key] = profile
            add({
                id = "lie_" .. key, label = chair.actionLabel or "Sit in the operating chair", durationMs = chair.lieMaxMs or 300000,
                maxDistance = 2.5,
                animation = profile and { profile = profile, at = "target", arrivalRadius = chair.arrivalRadius } or nil,
                -- No bar and no movement lock: the patient's screen stays free for the surgery bar,
                -- and walking off gets them up (the workspot breaks, the action ends).
                progress = false, claims = { attack = true },
                hooks = PLAIN,
            }, { kind = "lie", clinic = key })
        end
    end
    -- The station's choice when no quote is accepted: refuses with a hint.
    add({
        id = "operate", label = "Operate", durationMs = 250, claim = false, progress = false, claims = false,
        eligibility = cfg.eligibility, hooks = { validate = "rdValidate" },
    }, { kind = "idle" })
    local opProfile = self:resolveProfile(cfg.operation.profiles, "the operating pose")
    self.profiles.operate = opProfile
    local entryProfiles = {}
    for _, a in ipairs(M.operateActions(cfg)) do
        local profile = opProfile
        if type(a.entry.operateProfiles) == "table" then
            if entryProfiles[a.entry.key] == nil then
                entryProfiles[a.entry.key] = self:resolveProfile(a.entry.operateProfiles,
                    "the operating pose of " .. a.entry.key) or false
            end
            profile = entryProfiles[a.entry.key] or opProfile
        end
        add({
            id = a.id, label = a.label, durationMs = a.durationMs, maxDistance = cfg.operation.maxDistance,
            reserveTimeoutMs = 15000, commitRetries = 1,
            animation = profile and { profile = profile, at = "target", required = false } or nil,
            progress = { label = a.progress, color = cfg.color },
            claims = { move = true, attack = true },
            eligibility = cfg.eligibility, epochs = cfg.epochs, hooks = HOOKS,
        }, { kind = "operate", id = a.id, proc = a.proc, durationMs = a.durationMs })
    end
    local sup = cfg.supplier
    local supProfile = self:resolveProfile(sup.profiles, "the chrome order")
    self.profiles.restock = supProfile
    add({
        id = "restock", label = "Buy chrome for the clinic", durationMs = sup.durationMs, maxDistance = 2.5,
        reserveTimeoutMs = sup.reserveTimeoutMs,
        animation = supProfile and { profile = supProfile, at = "target", required = false } or nil,
        progress = { label = "Ordering chrome", color = cfg.color },
        eligibility = cfg.eligibility, epochs = cfg.epochs, hooks = HOOKS,
    }, { kind = "restock" })
    return defs, kinds
end

-- The station offers the accepted procedure, or the idle choice that explains how to get one.
-- The chair's "Sit" card, shown while the chair is free and taken down while a patient sits in it:
-- an occupied chair offers nothing (open77_actions would refuse target_claimed), and its card would
-- sit over the patient on top of the station's card.
function S:showChair(clinicKey)
    local clinic = self.clinics[clinicKey]
    local chair = clinic and clinic.cfg.chair
    if not chair or chair.mode == "seating" then return nil end
    local key, why = self.P.actions.target({
        id = clinicKey .. "_chair", position = chair.position, yaw = chair.yaw, bucket = self.cfg.bucket,
        label = chair.label or "Operating chair", distance = 1.5, actions = { "lie_" .. clinicKey },
        arrivalRadius = chair.arrivalRadius, data = { clinic = clinicKey, role = "chair" },
    })
    if key then self.targetClinic[key] = clinicKey else self:warn("chair target %s refused: %s", clinicKey, tostring(why)) end
    return key
end

function S:hideChair(clinicKey)
    pcall(self.P.actions.untarget, clinicKey .. "_chair")
end

function S:refreshStation(clinicKey, force)
    local clinic = self.clinics[clinicKey]
    if not clinic or not clinic.opened then return end
    local s = self.byClinic[clinicKey]
    local choice = false
    if s and (s.state == "reserved" or s.state == "operating" or s.state == "installing") then
        choice = self.M.actionId(s.proc)
    end
    if clinic.stationChoice == choice and not force then return end
    -- No accepted quote: no station card at all (it would stack over the empty chair's "Sit" card).
    if not choice then
        pcall(self.P.actions.untarget, clinicKey .. "_station")
        clinic.stationChoice = false
        return
    end
    local st, chair = clinic.cfg.station, clinic.cfg.chair
    -- The card floats over the patient's head, where the ripperdoc looks (their own point is under
    -- their feet, off screen).
    local key, why = self.P.actions.target({
        id = clinicKey .. "_station", position = st.position, yaw = st.yaw, bucket = self.cfg.bucket,
        label = st.label or "Operating station", distance = 1.5, actions = { choice },
        promptAt = st.promptAt or chair.position, promptHeight = st.promptHeight or 1.35,
        data = { clinic = clinicKey, role = "station" },
    })
    if key then
        clinic.stationChoice = choice
        self.targetClinic[key] = clinicKey
    else
        self:warn("station target %s refused: %s", clinicKey, tostring(why))
    end
end

function S:declare()
    local cfg = self.cfg
    local defs, kinds = self:actionDefinitions()
    self.actionKinds = kinds
    for _, def in ipairs(defs) do
        local key, why = self.P.actions.define(def)
        if not key then self:warn("action %s refused by open77_actions: %s", def.id, tostring(why)) end
    end
    local targets = 0
    for _, key in ipairs(cfg.clinicOrder) do
        local clinic = self.clinics[key]
        if clinic and clinic.opened then
            if clinic.cfg.chair.mode ~= "seating" and self:showChair(key) then targets = targets + 1 end
            clinic.stationChoice = nil
            self:refreshStation(key, true)
            if clinic.stationChoice then targets = targets + 1 end
        end
    end
    local sup = cfg.supplier
    local skey, swhy = self.P.actions.target({
        id = sup.id, position = sup.position, yaw = sup.yaw, bucket = cfg.bucket, label = sup.label,
        distance = 1.5, actions = { "restock" }, data = { role = "supplier", clinic = sup.clinic },
    })
    if skey then targets = targets + 1 else self:warn("supplier target refused: %s", tostring(swhy)) end
    self.targetCount = targets
    return targets
end

-- ---------------------------------------------------------------------------------------------
-- Indexes
-- ---------------------------------------------------------------------------------------------
function S:index(s)
    self.byPlayer[s.ripper] = s
    self.byPlayer[s.patient] = s
    self.byClinic[s.clinic] = s
end

function S:unindex(s)
    if self.byPlayer[s.ripper] == s then self.byPlayer[s.ripper] = nil end
    if s.patient and self.byPlayer[s.patient] == s then self.byPlayer[s.patient] = nil end
    if self.byClinic[s.clinic] == s then self.byClinic[s.clinic] = nil end
    if s.interaction and self.offers[s.interaction] == s then self.offers[s.interaction] = nil end
    if s.ticket and self.byTicket[s.ticket] == s then self.byTicket[s.ticket] = nil end
end

function S:recoveringFor(subject)
    for _, row in pairs(self.recovering) do
        if row.patientSubject == subject then return true end
    end
    return false
end

-- ---------------------------------------------------------------------------------------------
-- The quote
-- ---------------------------------------------------------------------------------------------
-- Everything a quote needs, checked from the server's own reads. Returns { clinic, epoch,
-- patientSubject } or nil, reason. Never yields.
function S:checkQuote(ripper, patient)
    if not self.ready then return nil, "clinic_unavailable" end
    if ripper == patient then return nil, "self_surgery" end
    if not patient or not self.P.players.name(patient) then return nil, "no_patient" end
    local ok, epoch = self.P.jobs.eligible(ripper, self.cfg.eligibility.args)
    if not ok then return nil, epoch or "not_eligible" end
    local clinic = self:clinicOf(ripper)
    if not clinic then return nil, "outside_clinic" end
    if self.byPlayer[ripper] or self.byPlayer[patient] then return nil, "busy" end
    if self.byClinic[clinic.key] then return nil, "clinic_busy" end
    local patientSubject = self.L.subjectOf(patient)
    if not patientSubject then return nil, "no_patient" end
    if self:recoveringFor(patientSubject) then return nil, "records_pending" end
    local a, b = self:posOf(ripper), self:posOf(patient)
    if not a or not b then return nil, "position_unavailable" end
    if (a.bucket or 0) ~= (b.bucket or 0) then return nil, "wrong_bucket" end
    local d = self.M.distance(a, b)
    if d > self.cfg.quote.distance then return nil, "patient_too_far" end
    if self.P.interactions.current(patient) or self.P.interactions.current(ripper) then return nil, "player_reserved" end
    return { clinic = clinic, epoch = epoch, patientSubject = patientSubject }
end

-- A procedure from a choice ({ action, key, grade }) and the patient's record.
function S:procedureFor(record, choice)
    local cfg, M = self.cfg, self.M
    local entry = M.entry(cfg, choice and choice.key)
    if not entry then return nil, "unknown_implant" end
    local implant = M.installedInSlot(record, entry.slot)
    if choice.action == "remove" then
        if not implant then return nil, "slot_empty" end
        local text = M.describeImplant(cfg, implant)
        return { proc = { action = "remove", key = entry.key }, entry = entry, price = M.removalPrice(cfg, entry, implant),
            durationMs = entry.grades[1].durationMs, label = text }
    end
    local grade = choice.grade and M.grade(entry, choice.grade) or entry.grades[1]
    if not grade then return nil, "unknown_implant" end
    if not self.defined[entry.key] then return nil, "provider_offline" end
    if implant then return nil, "slot_taken" end
    return { proc = { action = "install", key = entry.key, grade = grade.id }, entry = entry, grade = grade,
        item = grade.item, price = grade.price, durationMs = grade.durationMs, label = M.label(entry, grade) }
end

-- The catalogue on the ripperdoc's screen (UI-kit context menu). Yields. Returns a choice or nil.
function S:pickProcedure(ripper, patient, record, clinic)
    local cfg, M = self.cfg, self.M
    local stock = self.L.read(clinic.stock)
    local options = {}
    for _, entry in ipairs(cfg.catalogue) do
        local implant = M.installedInSlot(record, entry.slot)
        if implant then
            local text = M.describeImplant(cfg, implant)
            options[#options + 1] = {
                id = M.optionId({ action = "remove", key = entry.key }), label = "Remove " .. entry.label,
                description = ("Installed: %s. %d s under the knife."):format(text, M.seconds(entry.grades[1].durationMs)),
                tone = "danger",
                metadata = { { label = "Price", value = M.money(M.removalPrice(cfg, entry, implant)) } },
            }
        else
            local offline = not self.defined[entry.key]
            for _, grade in ipairs(entry.grades) do
                local n = self.L.available(stock, grade.item)
                options[#options + 1] = {
                    id = M.optionId({ action = "install", key = entry.key, grade = grade.id }),
                    label = M.label(entry, grade),
                    description = offline and ("Provider offline: %s"):format(tostring(self.defineReason[entry.key]))
                        or ("Install, %d s under the knife. In stock: %d."):format(M.seconds(grade.durationMs), n),
                    disabled = offline or n < 1,
                    metadata = {
                        { label = "Price", value = M.money(grade.price) },
                        { label = "Stock", value = tostring(n) },
                        { label = "Time", value = M.seconds(grade.durationMs) .. " s" },
                    },
                }
            end
        end
    end
    local answer, why = self.P.uikit.context(ripper, {
        id = "rp_ripperdoc_catalogue",
        title = ("Ripperdoc - %s"):format(self:nameOf(patient)),
        description = ("%d implant(s) installed. Pick a procedure: the patient gets a quote."):format(#M.installedList(record)),
        options = options,
    })
    if type(answer) ~= "table" then
        self:tell(ripper, "The catalogue could not open: " .. tostring(why), "warning")
        return nil
    end
    if not answer.ok then return nil end
    return M.parseOption(cfg, type(answer.value) == "table" and answer.value.id or answer.value)
end

-- The consent step. The interaction coordinator refuses a participant still in an animation
-- (`animation_busy`) for a moment after a stand-up: retried briefly.
function S:requestConsent(actor, target, kind, options)
    local state, why
    for attempt = 1, 6 do
        state, why = self.P.interactions.request(actor, target, kind, options)
        if not state and why == "invalid_options" and options.label ~= nil then
            options.label = nil                      -- a server from before offer labels
            state, why = self.P.interactions.request(actor, target, kind, options)
        end
        if state or why ~= "animation_busy" or attempt == 6 then break end
        Wait(500)
    end
    return state, why
end

local function riskText(cfg, M, record, proc)
    local threshold = tonumber(cfg.cyberpsychosisThreshold) or 4
    local count = #M.installedList(record)
    if proc.action ~= "install" then return "none, the slot goes back to stock parts" end
    if count + 1 > threshold then
        return ("cyberpsychosis: this would be implant %d, past the %d threshold"):format(count + 1, threshold)
    end
    return ("cyberpsychosis past %d implants (you carry %d)"):format(threshold, count)
end

-- The whole ripperdoc-side quote: checks, catalogue (when `choice` is nil), consent request. Runs
-- in a thread (it may wait for the menu).
function S:quote(ripper, patient, choice)
    local cfg, M = self.cfg, self.M
    local q, why = self:checkQuote(ripper, patient)
    if not q then return self:refuseTo(ripper, why) end
    local record = self.P.cyberware.current(patient)
    if type(record) ~= "table" then return self:refuseTo(ripper, "record_not_ready") end
    if not choice then
        choice = self:pickProcedure(ripper, patient, record, q.clinic)
        if not choice then return end
        q, why = self:checkQuote(ripper, patient)            -- a menu is a long time in Night City
        if not q then return self:refuseTo(ripper, why) end
        record = self.P.cyberware.current(patient)
        if type(record) ~= "table" then return self:refuseTo(ripper, "record_not_ready") end
    end
    local p, pwhy = self:procedureFor(record, choice)
    if not p then return self:refuseTo(ripper, pwhy) end
    if p.item then
        local stock = self.L.read(q.clinic.stock)
        if self.L.available(stock, p.item) < 1 then return self:refuseTo(ripper, "out_of_stock") end
    end
    if self.byPlayer[ripper] or self.byPlayer[patient] or self.byClinic[q.clinic.key] then
        return self:refuseTo(ripper, "busy")
    end
    local relie = self:standUp(patient)
    local verb = p.proc.action == "install" and "install" or "remove"
    local state, ixWhy = self:requestConsent(ripper, patient, "custom", {
        durationMs = cfg.quote.interactionMs, startDistance = cfg.quote.distance,
        breakDistance = math.min(cfg.quote.distance + 3.0, 20.0), inviteTimeoutMs = cfg.quote.inviteTimeoutMs,
        consent = true, actorAnimation = cfg.quote.actorAnimation, targetAnimation = cfg.quote.targetAnimation,
        -- The patient's offer card (a server without offer labels refuses the field: asked again without it).
        label = ("%s: %s %s for %s"):format(self:nameOf(ripper), verb, p.label, M.money(p.price)):sub(1, 120),
    })
    if type(state) ~= "table" or not state.id then
        if relie then self:lieAgain(patient, q.clinic.key) end
        return self:refuseTo(ripper, ixWhy or "interactions_unavailable")
    end
    local now = self.P.now()
    local s = {
        state = "offered", interaction = state.id, clinic = q.clinic.key, stock = q.clinic.stock,
        ripper = ripper, patient = patient, ripperSubject = self.L.subjectOf(ripper), patientSubject = q.patientSubject,
        ripperName = self:nameOf(ripper), patientName = self:nameOf(patient),
        proc = p.proc, entry = p.entry, grade = p.grade, item = p.item, price = p.price, durationMs = p.durationMs,
        label = p.label, epoch = q.epoch, society = cfg.society, relie = relie,
        createdAt = now, lastSeen = now,
    }
    self.offers[state.id] = s
    self:index(s)
    self.stats.quotes = self.stats.quotes + 1
    local what = p.proc.action == "install" and ("install %s"):format(p.label) or ("remove %s"):format(p.label)
    self:tell(patient, ("QUOTE from %s: %s for %s, %d s under the knife. Risk: %s. Nothing is paid until the chrome is in. Answer on the offer card within %d s.")
        :format(s.ripperName, what, M.money(p.price), M.seconds(p.durationMs), riskText(cfg, M, record, p.proc),
        M.seconds(cfg.quote.inviteTimeoutMs)), "info")
    self:tell(ripper, ("Quote sent to %s: %s for %s. Waiting for consent (%d s).")
        :format(s.patientName, what, M.money(p.price), M.seconds(cfg.quote.inviteTimeoutMs)), "info")
    self:log("quote %s: %s %s for %d, player %d -> player %d", state.id, p.proc.action, M.actionId(p.proc), p.price,
        ripper, patient)
    return s
end

-- The patient accepted (the platform completed the consent step): place the hold.
function S:accept(s)
    local cfg, M, L = self.cfg, self.M, self.L
    if s.state ~= "offered" then return end
    local ok, why = self.P.jobs.eligible(s.ripper, { job = cfg.job, duty = true, epoch = s.epoch })
    if not ok then return self:endOffer(s, why == "stale_job_epoch" and "ripper_off_duty" or why) end
    if not self:isSubject(s.patient, s.patientSubject) then return self:endOffer(s, "patient_gone") end
    if not self:isSubject(s.ripper, s.ripperSubject) then return self:endOffer(s, "ripper_gone") end
    s.id = L.newOpId("op")
    s.txOpId = s.id
    s.cwOpId = M.cwOpId(s.id)
    s.wallets = {}
    for _, instrument in ipairs(cfg.payFrom) do s.wallets[instrument] = L.account(s.patient, instrument) end
    local reason = ("%s %s at %s"):format(s.proc.action, M.actionId(s.proc), s.clinic)
    local held, hwhy, short
    if (s.price or 0) <= 0 and not s.item then
        s.free, held = true, true
    else
        -- The wallets in order (cash, then bank): a wallet that cannot pay, or was never opened,
        -- passes to the next one; any other refusal stops.
        for _, instrument in ipairs(cfg.payFrom) do
            local wallet = s.wallets[instrument]
            if wallet then
                held, hwhy = L.reserve({
                    opId = s.txOpId, kind = "ripperdoc.operation", actor = wallet, reason = reason,
                    ttlMs = cfg.operation.holdTtlMs,
                    lines = M.surgeryLines({ wallet = wallet, society = s.society, price = s.price, item = s.item,
                        stock = s.stock, reason = reason }),
                })
                if held then
                    s.instrument, s.wallet = instrument, wallet
                    break
                end
                if hwhy == "insufficient_funds" then short = true
                elseif hwhy ~= "unknown_account" then break end
            end
        end
        if not held and short and (hwhy == "unknown_account" or hwhy == "insufficient_funds") then
            hwhy = "insufficient_funds"
        end
    end
    if not held then
        return self:endOffer(s, hwhy == "insufficient_items" and "out_of_stock" or (hwhy or "no_account"))
    end
    if s.state ~= "offered" then
        -- ended while the hold was being placed (a disconnect): give it back at once
        if not s.free then L.cancel(s.txOpId, "ended") end
        return
    end
    local now = self.P.now()
    s.state = "reserved"
    s.reservedAt, s.holdUntil, s.validUntil = now, now + cfg.operation.holdTtlMs, now + cfg.quote.validMs
    self.surgeries[s.id] = s
    if self.offers[s.interaction] == s then self.offers[s.interaction] = nil end
    local journaled, jwhy = self.J:put(s)
    if not journaled then
        self:warn("surgery %s: journal write refused (%s): the hold is released", s.id, tostring(jwhy))
        return self:release(s, "cancelled", "journal_unavailable")
    end
    self.stats.accepted = self.stats.accepted + 1
    self:refreshStation(s.clinic)
    local clinic = self.clinics[s.clinic]
    local how = clinic.cfg.chair.mode == "seating" and "sit in the operating chair" or "sit in the operating chair (E)"
    self:tell(s.patient, ("Quote accepted: %s and the implant are on hold, nothing is paid yet. Please %s; %s operates from the station.")
        :format(M.money(s.price), how, s.ripperName), "success")
    self:tell(s.ripper, ("%s accepted: %s for %s on hold (%s). Get them on the chair, then E %s at the operating station (or /ripper operate). The quote holds %d s.")
        :format(s.patientName, s.label, M.money(s.price), tostring(s.instrument or "free"), self:operateLabel(s),
        M.seconds(cfg.quote.validMs)), "success")
    self:log("surgery %s reserved: %s for %d via %s, %s -> %s, cyberware op %s", s.id, M.actionId(s.proc), s.price,
        tostring(s.instrument or "free"), tostring(s.ripperSubject), tostring(s.patientSubject), s.cwOpId)
    if s.relie then self:lieAgain(s.patient, s.clinic) end
end

function S:operateLabel(s)
    local kind = self.actionKinds[self.M.actionId(s.proc)]
    for _, a in ipairs(self.M.operateActions(self.cfg)) do
        if a.id == self.M.actionId(s.proc) then return a.label end
    end
    return kind and kind.id or "Operate"
end

-- A quote that will not be operated on (declined, unanswered, refused at the hold). Nothing was
-- held, or the hold was refused: nothing to release.
function S:endOffer(s, reason)
    if s.state ~= "offered" then return end
    s.state = "ended"
    s.endReason = reason
    self:unindex(s)
    if reason == "declined" then self.stats.declined = self.stats.declined + 1 end
    local text = self.M.endText(reason)
    self:tell(s.ripper, ("No procedure for %s: %s"):format(s.patientName, text), "warning")
    if self:isSubject(s.patient, s.patientSubject) then
        self:tell(s.patient, ("No procedure: %s Nothing was charged."):format(text), "warning")
        if s.relie then self:lieAgain(s.patient, s.clinic) end
    end
    self:log("quote %s ended: %s", tostring(s.interaction), tostring(reason))
end

function S:onInteractionCompleted(state)
    local id = type(state) == "table" and state.id or nil
    if not id then return end
    local s = self.offers[id]
    if s then
        self.offers[id] = nil
        return self:accept(s)
    end
    local b = self.buys[id]
    if b then
        self.buys[id] = nil
        if self.buyOf[b.ripper] == id then self.buyOf[b.ripper] = nil end
        return self:completeBuy(b)
    end
end

local function offerReason(raw)
    raw = tostring(raw or "cancelled")
    if raw:find("declin") or raw:find("reject") then return "declined" end
    return raw
end

function S:onInteractionCancelled(state)
    local id = type(state) == "table" and state.id or nil
    if not id then return end
    local s = self.offers[id]
    if s then
        self.offers[id] = nil
        return self:endOffer(s, offerReason(state.reason))
    end
    local b = self.buys[id]
    if b then
        self.buys[id] = nil
        if self.buyOf[b.ripper] == id then self.buyOf[b.ripper] = nil end
        return self:dropBuy(b, offerReason(state.reason))
    end
end

-- ---------------------------------------------------------------------------------------------
-- Ending a surgery without an implant change: the hold is released, nothing moved.
-- Callers guarantee the cyberware operation did not apply (never started, refused, rolled back).
-- ---------------------------------------------------------------------------------------------
function S:release(s, state, reason)
    if not (s.state == "reserved" or s.state == "operating" or s.state == "installing") then return end
    local was = s.state
    s.state = state
    s.endReason = reason
    s.endedAt = self.P.now()
    if s.txOpId and not s.free then self.L.cancel(s.txOpId, reason) end
    self.J:drop(s.id)
    self:unindex(s)
    if s.actionOpId and was ~= "reserved" then self.P.actions.cancel(s.actionOpId, reason) end
    self:closePatientBar(s)
    self:refreshStation(s.clinic)
    self.stats[state] = (self.stats[state] or 0) + 1
    local text = self.M.endText(reason)
    local tail = s.item and "Nothing was charged and the implant stays in stock." or "Nothing was charged."
    local head = state == "failed" and "The procedure failed: " or "Procedure cancelled: "
    self:tellSubject(s.ripperSubject, head .. text .. " " .. tail, "warning", s.ripper)
    self:tellSubject(s.patientSubject, head .. text .. " " .. tail, "warning", s.patient)
    self:log("surgery %s %s: %s (hold released, nothing moved)", tostring(s.id), state, tostring(reason))
end

function S:closePatientBar(s)
    if not s.patientBar then return end
    s.patientBar = false
    s.closingBar = true
    local pid = s.patient
    self.P.spawn(function() self.P.uikit.close(pid) end)
end

-- ---------------------------------------------------------------------------------------------
-- Hooks: validate (synchronous, never yields)
-- ---------------------------------------------------------------------------------------------
function S:canOperate(ctx, kind, s)
    local pid = ctx.playerId
    if not s or s.ripper ~= pid then return nil, "no_quote" end
    if s.state == "offered" then return nil, "quote_pending" end
    if s.state ~= "reserved" then return nil, "surgery_busy" end
    local targetClinic = type(ctx.target) == "table" and type(ctx.target.data) == "table" and ctx.target.data.clinic
    if targetClinic ~= s.clinic then return nil, "wrong_clinic" end
    if self.M.actionId(s.proc) ~= kind.id then return nil, "no_quote" end
    if self.P.now() > s.validUntil then return nil, "quote_expired" end
    if not self:onChair(s) then return nil, "patient_not_on_chair" end
    return true
end

function S:validate(ctx)
    if not fromActions() then return false, "not_owner" end
    if not self.ready then return false, "clinic_unavailable" end
    local kind = self.actionKinds[ctx.actionId]
    if not kind then return false, "unknown_action" end
    if kind.kind == "lie" then
        if ctx.phase == "begin" then
            local s = self.byPlayer[ctx.playerId]
            if s and s.state == "offered" then
                self:refuseTo(ctx.playerId, "quote_pending")
                return false, "quote_pending"
            end
            if s and s.ripper == ctx.playerId then
                self:refuseTo(ctx.playerId, "busy")
                return false, "busy"
            end
        end
        return true
    elseif kind.kind == "idle" then
        self:refuseTo(ctx.playerId, "no_quote")
        return false, "no_quote"
    elseif kind.kind == "operate" then
        local s = self.byPlayer[ctx.playerId]
        if ctx.phase == "begin" then
            local ok, why = self:canOperate(ctx, kind, s)
            if not ok then
                self:refuseTo(ctx.playerId, why)
                return false, why
            end
            return true
        end
        if not s or s.actionOpId ~= ctx.opId or s.state ~= "operating" then return false, "surgery_lost" end
        if not self:onChair(s) then return false, "patient_left" end
        return true
    elseif kind.kind == "restock" then
        return true
    end
    return false, "unknown_action"
end

-- ---------------------------------------------------------------------------------------------
-- Hooks: reserve -> commit, or cancel
-- ---------------------------------------------------------------------------------------------
function S:reserve(ctx)
    if not fromActions() then return nil, "not_owner" end
    if not self.P.actions.verify(ctx.opId, "reserve") then return nil, "not_owner" end
    if not self.ready then return nil, "clinic_unavailable" end
    local kind = self.actionKinds[ctx.actionId]
    if kind and kind.kind == "operate" then return self:reserveOperate(ctx, kind) end
    if kind and kind.kind == "restock" then return self:reserveRestock(ctx) end
    return nil, "unknown_action"
end

-- The operation adopts the quote's hold: no new reservation, the same one, bound to this action.
function S:reserveOperate(ctx, kind)
    local cfg = self.cfg
    local s = self.byPlayer[ctx.playerId]
    local ok, why = self:canOperate(ctx, kind, s)
    if not ok then
        self:refuseTo(ctx.playerId, why)
        return nil, why
    end
    if not s.free then
        -- The hold must still be there (a coordinator restart forgets it) and outlive the bar and
        -- the install.
        local st = self.L.status(s.txOpId)
        if type(st) ~= "table" or st.state ~= "reserved" then
            if s.state == "reserved" then self:release(s, "cancelled", "hold_lost") end
            return nil, "hold_lost"
        end
        if s.holdUntil - self.P.now() < kind.durationMs + cfg.operation.installTimeoutMs + 10000 then
            if s.state == "reserved" then self:release(s, "cancelled", "quote_expired") end
            return nil, "quote_expired"
        end
    end
    if self.byPlayer[ctx.playerId] ~= s or s.state ~= "reserved" then return nil, "surgery_busy" end
    if not self.P.actions.verify(ctx.opId, "reserve") then return nil, "not_owner" end
    s.state = "operating"
    s.actionOpId = ctx.opId
    s.operateAt = self.P.now()
    self.J:put(s)
    self:log("surgery %s operating: action %s", s.id, ctx.opId)
    return { surgery = s.id, clinic = s.clinic }
end

function S:commit(ctx)
    if not fromActions() then return nil, "not_owner" end
    if not self.P.actions.verify(ctx.opId, "commit") then return nil, "not_owner" end
    local kind = self.actionKinds[ctx.actionId]
    if not kind then return nil, "unknown_action" end
    if kind.kind == "lie" then return { lay = true } end
    if kind.kind == "operate" then return self:commitOperate(ctx) end
    if kind.kind == "restock" then return self:commitRestock(ctx) end
    return nil, "unknown_action"
end

function S:cancelHook(ctx)
    if not fromActions() then return end
    local kind = self.actionKinds[ctx.actionId]
    if not kind then return end
    if kind.kind == "operate" then
        local r = ctx.reservation
        local s = type(r) == "table" and self.surgeries[r.surgery] or nil
        if not s or s.actionOpId ~= ctx.opId then return end
        -- Before the install: release. During it (`in_doubt`, or an outcome still on its way): the
        -- cyberware outcome decides, never this hook.
        if s.state == "operating" then self:release(s, "cancelled", ctx.reason) end
        return
    end
    if kind.kind == "restock" then return self:cancelRestock(ctx) end
end

function S:receiptOf(s)
    return { surgery = s.id, tx = s.txOpId, how = s.how, paid = (s.how ~= "unpaid") and s.price or 0 }
end

-- The bar is done and every check passed again: install (or remove) once, then commit the hold.
function S:commitOperate(ctx)
    local r = ctx.reservation
    local s = type(r) == "table" and self.surgeries[r.surgery] or nil
    if not s then return nil, "surgery_lost" end
    if s.actionOpId ~= ctx.opId then return nil, "not_owner" end
    if s.state == "done" or s.state == "unpaid" then return self:receiptOf(s) end   -- a retried commit
    if s.state == "cancelled" or s.state == "failed" then return nil, s.endReason or "cancelled" end
    if s.state == "operating" then
        local ok, why = self:startInstall(s)
        if not ok then
            if s.state == "operating" then self:release(s, "failed", why) end
            return nil, why
        end
    end
    if s.state == "installing" and not s.installed and not s.installError then
        s.waiters = (s.waiters or 0) + 1
        local deadline = self.P.now() + self.cfg.operation.installTimeoutMs
        while s.state == "installing" and not s.installed and not s.installError and self.P.now() < deadline do
            Wait(100)
        end
        s.waiters = s.waiters - 1
        if s.state == "installing" and not s.installed and not s.installError then self:installTimedOut(s) end
    end
    if s.state == "installing" then self:finishInstall(s) end
    if s.state == "done" or s.state == "unpaid" then return self:receiptOf(s) end
    if s.state == "installing" then return nil, "in_doubt" end     -- the sweep finishes it
    return nil, s.endReason or "install_failed"
end

-- Submits the cyberware operation. The journal says `installing` BEFORE the submit, so a restart
-- in between can tell from the patient's record whether it landed.
function S:startInstall(s)
    local M, P = self.M, self.P
    if not self:isSubject(s.patient, s.patientSubject) then return nil, "patient_gone" end
    if not self:onChair(s) then return nil, "patient_left" end
    local record = P.cyberware.current(s.patient)
    if type(record) ~= "table" then return nil, "record_not_ready" end
    if record.operationId == s.cwOpId then
        -- An earlier attempt of this very surgery already landed (a retried commit).
        s.state, s.installed = "installing", true
        self.J:put(s)
        return true
    end
    local implant = M.installedInSlot(record, s.entry.slot)
    if s.proc.action == "install" and implant then return nil, "slot_taken" end
    if s.proc.action == "remove" and not implant then return nil, "slot_empty" end
    s.expectedRevision = record.revision
    s.countBefore = #M.installedList(record)
    s.state = "installing"
    s.submittedAt = P.now()
    local journaled = self.J:put(s)
    if not journaled then
        s.state = "operating"
        return nil, "journal_unavailable"
    end
    local options = { expectedRevision = s.expectedRevision, operationId = s.cwOpId }
    local result, why
    if s.proc.action == "install" then
        result, why = P.cyberware.install(s.patient, s.entry.definitionId, s.grade.id, options)
    else
        options.slot = s.entry.slot
        result, why = P.cyberware.remove(s.patient, options)
    end
    if type(result) ~= "table" then
        s.state = "operating"                -- nothing was staged: the caller releases the hold
        return nil, why or "install_refused"
    end
    if result.ticket then
        s.ticket = result.ticket
        self.byTicket[result.ticket] = s
    else
        s.installed = true                   -- an idempotent replay: already applied
    end
    self:log("surgery %s: cyberware %s submitted for player %d (op %s, ticket %s)", s.id, s.proc.action, s.patient,
        s.cwOpId, tostring(s.ticket))
    return true
end

function S:onCyberwareCompleted(player, ticket, encoded)
    local s = self.byTicket[ticket]
    if not s then return end
    self.byTicket[ticket] = nil
    local result = type(encoded) == "string" and self.P.json.decode(encoded) or encoded
    if type(result) == "table" and result.ok == true then
        s.installed = true
    else
        s.installError = type(result) == "table" and tostring(result.error or "install_failed") or "invalid_result"
    end
    self:log("surgery %s: cyberware answered %s", tostring(s.id), s.installed and "ok" or tostring(s.installError))
    if (s.waiters or 0) == 0 then self.P.spawn(function() self:finishInstall(s) end) end
end

-- No cyberware answer in time: a staged operation can still be rolled back; one already saving
-- cannot, and its outcome is awaited.
function S:installTimedOut(s)
    if not s.ticket then return end
    local ok, why = self.P.cyberware.cancel(s.patient, s.ticket)
    if type(ok) == "table" then
        self.byTicket[s.ticket] = nil
        s.installError = "install_timeout"
        self:log("surgery %s: no cyberware answer, staged operation rolled back", s.id)
    else
        self:log("surgery %s: no cyberware answer yet, cancel answered %s: waiting for the outcome", s.id, tostring(why))
    end
end

function S:finishInstall(s)
    if s.state ~= "installing" or s.finishing then return end
    s.finishing = true
    if not s.installed and s.installError then
        local record = self.P.cyberware.current(s.patient)
        if type(record) == "table" and record.operationId == s.cwOpId then s.installed = true end
    end
    if s.installed then
        self:settle(s)
    elseif s.installError then
        self:release(s, "failed", s.installError)
    end
    s.finishing = false
end

-- The implant is in (or out): commit the hold. A hold the coordinator no longer has (expired, or
-- released by a restart) is replaced by a transfer of the same lines under `rd.settle:<id>`.
function S:settle(s)
    if s.free then return self:completeSurgery(s, nil, "free") end
    local receipt, why = self.L.commit(s.txOpId)
    if type(receipt) == "table" then return self:completeSurgery(s, receipt, "hold") end
    if self.L.RETRYABLE[why] then
        s.settleRetry = true
        self:log("surgery %s: commit answered %s, retried by the sweep", s.id, tostring(why))
        return
    end
    return self:settleByTransfer(s, why)
end

function S:settleByTransfer(s, why)
    local cfg, M, L = self.cfg, self.M, self.L
    local opId = "rd.settle:" .. s.id
    local order, seen = {}, {}
    if s.instrument then order[1], seen[s.instrument] = s.instrument, true end
    for _, instrument in ipairs(cfg.payFrom) do
        if not seen[instrument] then
            seen[instrument] = true
            order[#order + 1] = instrument
        end
    end
    local withItem = s.item ~= nil
    local reason = ("settle %s at %s"):format(M.actionId(s.proc), s.clinic)
    self:log("surgery %s: the hold is gone (%s), settling with %s", s.id, tostring(why), opId)
    for _ = 1, 2 do
        local retryWithout = false
        for _, instrument in ipairs(order) do
            local wallet = s.wallets and s.wallets[instrument]
            if wallet then
                local receipt, twhy = L.transfer({ opId = opId, kind = "ripperdoc.settle", reason = reason,
                    lines = M.surgeryLines({ wallet = wallet, society = s.society, price = s.price, item = s.item,
                        stock = s.stock, reason = reason, withItem = withItem }) })
                if type(receipt) == "table" then
                    s.instrument = instrument
                    self.stats.settled = self.stats.settled + 1
                    return self:completeSurgery(s, receipt, "settled")
                end
                if L.RETRYABLE[twhy] then
                    s.settleRetry = true
                    return
                end
                if twhy == "insufficient_items" and withItem then
                    retryWithout = true
                    break
                end
                if twhy ~= "insufficient_funds" then break end
            end
        end
        if not retryWithout then break end
        self:warn("surgery %s: the stock is short of %s; settling the money only", s.id, tostring(s.item))
        withItem = false
    end
    self.stats.unpaid = self.stats.unpaid + 1
    return self:completeSurgery(s, nil, "unpaid")
end

function S:cyberpsychosisCheck(s)
    local cfg = self.cfg
    if not self:isSubject(s.patient, s.patientSubject) then return end
    local record = self.P.cyberware.current(s.patient)
    local count = type(record) == "table" and #self.M.installedList(record) or ((s.countBefore or 0) + 1)
    local threshold = tonumber(cfg.cyberpsychosisThreshold) or 4
    if count <= threshold then return end
    local fx = cfg.cyberpsychosis
    local ok, why = self.P.screen(s.patient, fx.effect, { strength = fx.strength, duration = fx.durationSeconds })
    if not ok then self:log("cyberpsychosis overlay refused: %s", tostring(why)) end
    self:tell(s.patient, ("WARNING - %d implants: your chrome is fighting your brain. Cyberpsychosis symptoms for %d s. Take it easy, choom.")
        :format(count, fx.durationSeconds), "error")
    self:tellSubject(s.ripperSubject, ("Heads up: %s now carries %d implants, past the %d threshold."):format(s.patientName,
        count, threshold), "warning", s.ripper)
    self:log("cyberpsychosis on player %d (%d implants > %d)", s.patient, count, threshold)
end

function S:completeSurgery(s, receipt, how)
    if s.state == "done" or s.state == "unpaid" then return end
    local cfg, M = self.cfg, self.M
    s.state = (how == "unpaid") and "unpaid" or "done"
    s.how = how
    s.settleRetry = nil
    s.endedAt = self.P.now()
    s.receipt = type(receipt) == "table" and { opId = receipt.opId, replay = receipt.replay == true } or nil
    self.surgeries[s.id] = s
    self.J:drop(s.id)
    self.J:append({ at = s.endedAt, id = s.id, clinic = s.clinic, ripper = s.ripperSubject, ripperName = s.ripperName,
        patient = s.patientSubject, patientName = s.patientName, action = s.proc.action, key = s.proc.key,
        definition = s.entry.definitionId, grade = s.proc.grade or "", price = s.price,
        how = how == "hold" and (s.instrument or "cash") or how })
    self:unindex(s)
    self:refreshStation(s.clinic)
    self.stats.operations = self.stats.operations + 1
    if s.proc.action == "install" then self.stats.installs = self.stats.installs + 1
    else self.stats.removals = self.stats.removals + 1 end
    local what = s.proc.action == "install" and (s.label .. " installed") or (s.label .. " removed")
    local paid = how == "unpaid" and "The patient could not pay: logged as unpaid." or
        ("%s to the %s society."):format(M.money(s.price), s.society)
    self:tellSubject(s.ripperSubject, ("Done: %s on %s. %s"):format(what, s.patientName, paid), "success", s.ripper)
    local patientText = how == "unpaid"
        and ("Done: %s. Your wallet could not cover %s: the clinic logged the debt."):format(what, M.money(s.price))
        or ("Done: %s. You paid %s (%s). /implants to check your chrome."):format(what, M.money(s.price),
            tostring(s.instrument or "on the house"))
    local patientNow = self:tellSubject(s.patientSubject, patientText, "success", s.patient)
    if patientNow then s.patient = patientNow end
    self:log("surgery %s done (%s): %s %s on %s by %s, %d eddies", s.id, how, s.proc.action, M.actionId(s.proc),
        tostring(s.patientSubject), tostring(s.ripperSubject), s.price)
    local ripperNow = self:isSubject(s.ripper, s.ripperSubject) and s.ripper or self:playerBySubject(s.ripperSubject)
    self.P.emit("rp:job:completed", {
        job = cfg.fixerJob, kind = "operation", playerId = ripperNow, ref = s.actionOpId or s.id,
        data = { action = s.proc.action, implant = s.proc.key, definition = s.entry.definitionId,
            grade = s.proc.grade, price = s.price, paid = how ~= "unpaid", patient = patientNow,
            patientSubject = s.patientSubject, ripperSubject = s.ripperSubject, surgery = s.id, clinic = s.clinic },
    })
    self.P.emit("rp_ripperdoc:operation", ripperNow, patientNow, s.proc.action, s.proc.key, s.proc.grade or "", s.price)
    if s.proc.action == "install" then self:cyberpsychosisCheck(s) end
end

-- ---------------------------------------------------------------------------------------------
-- The chair
-- ---------------------------------------------------------------------------------------------
function S:onPatientLay(pid)
    local s = self.byPlayer[pid]
    if s and s.patient == pid and s.state == "reserved" then
        self:tell(pid, ("You sit in the operating chair. %s can start. Walk away to get up."):format(s.ripperName), "info")
        self:tellSubject(s.ripperSubject, ("%s is on the chair: E %s at the operating station, or /ripper operate.")
            :format(s.patientName, self:operateLabel(s)), "info", s.ripper)
        return
    end
    local onDuty = #self.P.jobs.listOnDuty(self.cfg.job)
    if onDuty == 0 then
        self:tell(pid, "You sit in the operating chair. No ripperdoc is on duty right now. Walk away to get up.", "info")
    else
        self:tell(pid, ("You sit in the operating chair. %d ripperdoc(s) on duty can quote you (they ALT+click you > Quote). Walk away to get up.")
            :format(onDuty), "info")
    end
end

function S:onPatientLeft(pid, reason)
    local s = self.byPlayer[pid]
    if not s or s.patient ~= pid then return end
    if s.state == "operating" then
        -- The cancel hook releases the hold (a commit already in flight re-checks the chair).
        if s.actionOpId then self.P.actions.cancel(s.actionOpId, "patient_left") end
    elseif s.state == "reserved" and reason ~= "dead" and reason ~= "disconnected" then
        -- (a death or a disconnect ends the whole procedure right after: no "the quote holds" line)
        self:tellSubject(s.ripperSubject, ("%s got off the chair. The quote holds until it expires.")
            :format(s.patientName), "info", s.ripper)
    end
end

-- ---------------------------------------------------------------------------------------------
-- Action transitions (every resource receives every action: filtered on the owner)
-- ---------------------------------------------------------------------------------------------
function S:onTransition(op)
    if type(op) ~= "table" or op.owner ~= self.resource then return end
    local kind = self.actionKinds[op.actionId]
    if not kind then return end
    local pid = op.playerId
    if kind.kind == "lie" then
        if op.state == "presenting" then
            self.lying[pid] = { opId = op.opId, clinic = kind.clinic }
            self:hideChair(kind.clinic)
            self:onPatientLay(pid)
        elseif TERMINAL[op.state] then
            local l = self.lying[pid]
            if l and l.opId == op.opId then
                self.lying[pid] = nil
                self:showChair(kind.clinic)
                self:onPatientLeft(pid, op.reason)
            end
        end
    elseif kind.kind == "operate" then
        local s = self.byPlayer[pid]
        if op.state == "presenting" and s and s.actionOpId == op.opId and s.state == "operating" then
            self:tell(pid, ("Operating on %s: %s, %d s. X stops it, nothing is charged."):format(s.patientName, s.label,
                self.M.seconds(s.durationMs)), "info")
            self:tell(s.patient, ("%s starts: %s, %d s under the knife. Stay on the chair; X stops it, nothing is charged.")
                :format(s.ripperName, s.label, self.M.seconds(s.durationMs)), "info")
            self:startPatientBar(s, op.opId)
        end
    end
end

-- The surgery bar on the patient's screen (UI kit): the same duration, X stops the operation.
function S:startPatientBar(s, opId)
    if not self:isSubject(s.patient, s.patientSubject) then return end
    s.patientBar = true
    s.closingBar = false
    self.P.spawn(function()
        local answer = self.P.uikit.progress(s.patient, {
            label = "Under the knife: " .. s.label, duration = s.durationMs, position = "bottom", style = "bar",
            color = self.cfg.color, cancellable = true, cancelKey = "X", disable = { move = true, combat = true },
        })
        local mine = s.patientBar and not s.closingBar
        s.patientBar = false
        if type(answer) == "table" and answer.outcome == "cancelled" and mine and s.state == "operating"
            and s.actionOpId == opId then
            self.P.actions.cancel(opId, "patient_stopped")
        end
    end)
end

-- ---------------------------------------------------------------------------------------------
-- Restock at the supplier
-- ---------------------------------------------------------------------------------------------
function S:pickRestock(pid, clinic)
    local cfg, M = self.cfg, self.M
    local stock = self.L.read(clinic.stock)
    local options = {}
    for _, row in ipairs(M.stockItems(cfg)) do
        local n = self.L.available(stock, row.item)
        local priced = cfg.supplier.mode == "components" and "components" or M.money(M.wholesale(cfg, row.grade, 1))
        options[#options + 1] = {
            id = "buy:" .. row.item, label = M.label(row.entry, row.grade),
            description = ("%s a box. %d in the clinic's stock."):format(priced, n),
            disabled = cfg.supplier.mode == "components" and not row.grade.components,
            metadata = { { label = "Price", value = priced }, { label = "Stock", value = tostring(n) } },
        }
    end
    local answer = self.P.uikit.context(pid, {
        id = "rp_ripperdoc_supplier", title = cfg.supplier.label,
        description = ("Boxed implants delivered to %s. One box per order (/ripper restock <implant> [grade] [count] for more).")
            :format(clinic.cfg.label),
        options = options,
    })
    if type(answer) ~= "table" or not answer.ok then return nil end
    local id = type(answer.value) == "table" and answer.value.id or answer.value
    local item = type(id) == "string" and id:match("^buy:([%w_]+)$")
    return item and { item = item, count = 1 } or nil
end

function S:reserveRestock(ctx)
    local cfg, M, L = self.cfg, self.M, self.L
    local pid = ctx.playerId
    local sup = cfg.supplier
    local clinic = self.clinics[sup.clinic]
    if not clinic or not clinic.opened then
        self:refuseTo(pid, "unknown_clinic")
        return nil, "unknown_clinic"
    end
    local want = type(ctx.data) == "table" and ctx.data.item and ctx.data or nil
    if not want then
        want = self:pickRestock(pid, clinic)
        if not want then return nil, "declined" end
        if not self.P.actions.verify(ctx.opId, "reserve") then return nil, "not_owner" end
    end
    local entry, grade = M.byItem(cfg, want.item)
    if not entry then
        self:refuseTo(pid, "unknown_implant")
        return nil, "unknown_implant"
    end
    local count = M.count(want.count or 1, sup.maxCount)
    if not count then
        self:refuseTo(pid, "invalid_count")
        return nil, "invalid_count"
    end
    local txOpId = L.newOpId("restock")
    local ttl = sup.durationMs + 30000
    local held, why, paidBy, cost
    if sup.mode == "components" then
        if type(grade.components) ~= "table" or #grade.components == 0 then
            self:refuseTo(pid, "no_components")
            return nil, "no_components"
        end
        local from = sup.componentsFrom == "char" and L.account(pid, "char") or sup.componentsFrom
        held, why = L.reserve({ opId = txOpId, kind = "ripperdoc.restock", ttlMs = ttl, reason = "chrome components",
            lines = M.restockLines({ mode = "components", components = grade.components, componentsFrom = from,
                count = count, item = grade.item, stock = clinic.stock }) })
        paidBy, cost = "components", 0
    else
        cost = M.wholesale(cfg, grade, count)
        for _, who in ipairs(sup.payFrom) do
            local payer = who == "society" and ("soc:" .. cfg.society) or L.account(pid, "cash")
            if payer then
                held, why = L.reserve({ opId = txOpId, kind = "ripperdoc.restock", ttlMs = ttl, reason = "chrome order",
                    lines = M.restockLines({ mode = "mint", payer = payer, cost = cost, item = grade.item, count = count,
                        stock = clinic.stock }) })
                if held then paidBy = who break end
                if why ~= "insufficient_funds" then break end
            end
        end
    end
    if not held then
        self:refuseTo(pid, why)
        return nil, why
    end
    local r = { txOpId = txOpId, kind = "restock", item = grade.item, count = count, cost = cost, paidBy = paidBy,
        clinic = clinic.key, subject = L.subjectOf(pid), pid = pid, actionOpId = ctx.opId,
        label = M.label(entry, grade) }
    self.restocks[ctx.opId] = r
    return r
end

function S:commitRestock(ctx)
    local r = ctx.reservation
    if type(r) ~= "table" or not r.txOpId then return nil, "no_reservation" end
    local receipt, why = self.L.commit(r.txOpId)
    if type(receipt) ~= "table" then
        if why == "coordinator_unavailable" then why = "in_doubt" end
        if why == "in_doubt" or why == "busy" then self.doubts[r.txOpId] = r end
        return nil, why
    end
    self.restocks[ctx.opId] = nil
    self:afterRestock(r, receipt)
    return { tx = r.txOpId, item = r.item, count = r.count, replay = receipt.replay == true }
end

function S:afterRestock(r, receipt)
    if self.done[r.txOpId] then return end
    self.done[r.txOpId] = self.P.now()
    self.doubts[r.txOpId] = nil
    self.stats.restocks = self.stats.restocks + 1
    local M = self.M
    local paid = r.paidBy == "components" and "paid in components"
        or ("%s paid by %s"):format(M.money(r.cost), r.paidBy == "society" and ("the " .. self.cfg.society .. " society") or "your cash")
    local text = ("Order delivered to %s: %d x %s (%s)."):format(self.clinics[r.clinic].cfg.label, r.count, r.label, paid)
    if self:isSubject(r.pid, r.subject) then self:tell(r.pid, text, "success") end
    self:log("restock %s by %s: %d x %s, %d via %s", r.txOpId, tostring(r.subject), r.count, r.item, r.cost, r.paidBy)
    local pid = self:isSubject(r.pid, r.subject) and r.pid or nil
    self.P.emit("rp:job:completed", { job = self.cfg.fixerJob, kind = "restock", playerId = pid,
        ref = r.actionOpId or r.txOpId, data = { source = "supplier", item = r.item, count = r.count, cost = r.cost,
            paidBy = r.paidBy, clinic = r.clinic, tx = r.txOpId, replay = type(receipt) == "table" and receipt.replay == true } })
end

function S:cancelRestock(ctx)
    self.restocks[ctx.opId] = nil
    local r = ctx.reservation
    if type(r) ~= "table" or not r.txOpId then return end
    if ctx.reason == "in_doubt" then
        self.doubts[r.txOpId] = r
        return
    end
    self.L.cancel(r.txOpId, ctx.reason)
end

-- Operator restock: boxes minted straight into a clinic's stock (the supplier's mint rule).
function S:seedStock(clinicKey, item, count)
    local clinic = self.clinics[clinicKey]
    if not clinic or not clinic.opened then return nil, "unknown_clinic" end
    local lines = {}
    for _, row in ipairs(self.M.stockItems(self.cfg)) do
        if item == nil or row.item == item then
            lines[#lines + 1] = { item = row.item, count = count or 1, from = self.M.SUPPLIER, to = clinic.stock,
                reason = "operator seed" }
        end
    end
    if #lines == 0 then return nil, "unknown_implant" end
    return self.L.transfer({ opId = self.L.newOpId("seed"), kind = "ripperdoc.seed", reason = "operator seed", lines = lines })
end

-- ---------------------------------------------------------------------------------------------
-- Buying chrome from a player (consented `give`, then ONE transfer)
-- ---------------------------------------------------------------------------------------------
function S:offerBuy(ripper, seller, key, gradeId, countArg)
    local cfg, M, L = self.cfg, self.M, self.L
    if not self.ready then return nil, "clinic_unavailable" end
    if ripper == seller then return nil, "self_surgery" end
    if not seller or not self.P.players.name(seller) then return nil, "no_patient" end
    local ok, epoch = self.P.jobs.eligible(ripper, cfg.eligibility.args)
    if not ok then return nil, epoch or "not_eligible" end
    local clinic = self:clinicOf(ripper)
    if not clinic then return nil, "outside_clinic" end
    if self.buyOf[ripper] or self.byPlayer[seller] then return nil, "busy" end
    local entry, grade = M.resolve(cfg, key, gradeId)
    if not entry or not grade then return nil, "unknown_implant" end
    local count = M.count(countArg or 1, cfg.buyback.maxCount)
    if not count then return nil, "invalid_count" end
    local a, b = self:posOf(ripper), self:posOf(seller)
    if not a or not b then return nil, "position_unavailable" end
    if M.distance(a, b) > cfg.buyback.distance then return nil, "patient_too_far" end
    local pockets = L.account(seller, "char")
    local snap = pockets and L.read(pockets)
    if L.available(snap, grade.item) < count then return nil, "seller_short" end
    local price = M.buybackPrice(cfg, grade, count)
    local state, why = self:requestConsent(ripper, seller, "give", {
        durationMs = cfg.buyback.durationMs, startDistance = cfg.buyback.distance,
        breakDistance = math.min(cfg.buyback.distance + 2.0, 20.0), inviteTimeoutMs = cfg.buyback.inviteTimeoutMs,
        consent = true,
        label = ("%s buys %d x %s for %s"):format(self:nameOf(ripper), count, M.label(entry, grade), M.money(price)):sub(1, 120),
    })
    if type(state) ~= "table" or not state.id then return nil, why or "interactions_unavailable" end
    local now = self.P.now()
    local o = { id = state.id, ripper = ripper, seller = seller, ripperSubject = L.subjectOf(ripper),
        sellerSubject = L.subjectOf(seller), clinic = clinic.key, stock = clinic.stock, item = grade.item,
        label = M.label(entry, grade), count = count, price = M.buybackPrice(cfg, grade, count),
        opId = L.newOpId("buy"), epoch = epoch, at = now, lastSeen = now }
    self.buys[o.id] = o
    self.buyOf[ripper] = o.id
    self:tell(seller, ("%s offers %s for %d x %s. Answer on the offer card to sell, or decline it.")
        :format(self:nameOf(ripper), M.money(o.price), count, o.label), "info")
    self:tell(ripper, ("Offer sent to %s: %s for %d x %s."):format(self:nameOf(seller), M.money(o.price), count, o.label), "info")
    self:log("buy-back offer %s: %s -> %s, %d x %s for %d, op %s", o.id, tostring(o.ripperSubject),
        tostring(o.sellerSubject), count, o.item, o.price, o.opId)
    return o
end

function S:completeBuy(o)
    local cfg, M, L = self.cfg, self.M, self.L
    local ok, why = self.P.jobs.eligible(o.ripper, { job = cfg.job, duty = true, epoch = o.epoch })
    if not ok then return self:dropBuy(o, why == "stale_job_epoch" and "ripper_off_duty" or why) end
    if not self:isSubject(o.seller, o.sellerSubject) then return self:dropBuy(o, "patient_gone") end
    local pockets, wallet = L.account(o.seller, "char"), L.account(o.seller, "cash")
    if not pockets or not wallet then return self:dropBuy(o, "no_account") end
    for _, who in ipairs(cfg.buyback.payFrom) do
        local payer = who == "society" and ("soc:" .. cfg.society) or L.account(o.ripper, "cash")
        if payer then
            local receipt, twhy = L.transfer({ opId = o.opId, kind = "ripperdoc.buyback", reason = "chrome bought",
                lines = M.buybackLines({ item = o.item, count = o.count, sellerPockets = pockets, stock = o.stock,
                    payer = payer, sellerWallet = wallet, price = o.price }) })
            if type(receipt) == "table" then return self:finishBuy(o, receipt, who) end
            if twhy == "in_doubt" or twhy == "busy" or twhy == "coordinator_unavailable" then
                o.since, o.paidBy = self.P.now(), who
                self.buyDoubts[o.opId] = o
                self:tell(o.seller, "The payment is still settling: one moment.", "info")
                return
            end
            if twhy ~= "insufficient_funds" then
                return self:dropBuy(o, twhy == "insufficient_items" and "seller_short" or twhy)
            end
        end
    end
    return self:dropBuy(o, "insufficient_funds")
end

function S:finishBuy(o, receipt, paidBy)
    if self.done[o.opId] then return end
    self.done[o.opId] = self.P.now()
    self.buyDoubts[o.opId] = nil
    self.stats.buybacks = self.stats.buybacks + 1
    local M = self.M
    if self:isSubject(o.seller, o.sellerSubject) then
        self:tell(o.seller, ("Sold: %d x %s for %s."):format(o.count, o.label, M.money(o.price)), "success")
    end
    if self:isSubject(o.ripper, o.ripperSubject) then
        self:tell(o.ripper, ("Bought %d x %s for %s (%s); it is in %s's stock."):format(o.count, o.label, M.money(o.price),
            paidBy == "society" and ("the " .. self.cfg.society .. " society paid") or "your cash paid",
            self.clinics[o.clinic].cfg.label), "success")
    end
    self:log("buy-back %s committed%s: %d x %s from %s for %d via %s", o.opId,
        type(receipt) == "table" and receipt.replay and " (replay)" or "", o.count, o.item, tostring(o.sellerSubject),
        o.price, tostring(paidBy))
    self.P.emit("rp:job:completed", { job = self.cfg.fixerJob, kind = "restock",
        playerId = self:isSubject(o.ripper, o.ripperSubject) and o.ripper or nil, ref = o.opId,
        data = { source = "player", item = o.item, count = o.count, cost = o.price, paidBy = paidBy,
            sellerSubject = o.sellerSubject, clinic = o.clinic } })
end

function S:dropBuy(o, reason)
    self.buyDoubts[o.opId] = nil
    local text = self.M.endText(reason)
    if reason == "declined" then text = "the seller declined." end
    self:tell(o.ripper, "No purchase: " .. text, "warning")
    if self:isSubject(o.seller, o.sellerSubject) then self:tell(o.seller, "No sale: " .. text .. " Nothing moved.", "warning") end
    self:log("buy-back offer %s dropped: %s", tostring(o.id), tostring(reason))
end

-- ---------------------------------------------------------------------------------------------
-- Players leaving, clocking out
-- ---------------------------------------------------------------------------------------------
function S:onDisconnected(pid)
    pid = self.M.playerId(pid)
    if not pid then return end
    self.notified[pid] = nil
    local s = self.byPlayer[pid]
    if s then
        local reason = s.patient == pid and "patient_gone" or "ripper_gone"
        if s.state == "reserved" then
            self:release(s, "cancelled", reason)
        elseif s.state == "operating" and s.actionOpId then
            self.P.actions.cancel(s.actionOpId, reason)
        end
        -- offered: the platform cancels the consent step itself; installing: the outcome decides
    end
end

function S:onWorkEpoch(pid, epoch)
    pid = self.M.playerId(pid)
    if not pid then return end
    local s = self.byPlayer[pid]
    if s and s.ripper == pid and s.epoch ~= epoch then
        if s.state == "offered" then
            self.P.interactions.cancel(s.interaction, "ripper_off_duty")
        elseif s.state == "reserved" then
            self:release(s, "cancelled", "ripper_off_duty")
        end
        -- operating: open77_actions' epoch guard ends the action (stale_job_epoch), the cancel
        -- hook releases the hold
    end
    local id = self.buyOf[pid]
    local o = id and self.buys[id]
    if o and o.epoch ~= epoch then self.P.interactions.cancel(o.id, "ripper_off_duty") end
end

-- ---------------------------------------------------------------------------------------------
-- Restart recovery
-- ---------------------------------------------------------------------------------------------
function S:surgeryFromRow(row, patient)
    local M = self.M
    local entry = M.entry(self.cfg, row.key)
    local grade = entry and row.grade and M.grade(entry, row.grade) or nil
    local label = entry and M.label(entry, grade) or tostring(row.key)
    return {
        id = row.id, state = "installing", recovered = true, clinic = row.clinic, stock = row.stock,
        ripper = self:playerBySubject(row.ripperSubject), patient = patient,
        ripperSubject = row.ripperSubject, patientSubject = row.patientSubject,
        ripperName = row.ripperName or "the ripperdoc", patientName = row.patientName or "the patient",
        proc = { action = row.action, key = row.key, grade = row.grade }, entry = entry or { definitionId = "?" },
        grade = grade, item = row.item, price = row.price or 0, instrument = row.instrument, wallets = row.wallets or {},
        society = row.society or self.cfg.society, txOpId = row.txOpId, cwOpId = row.cwOpId,
        actionOpId = row.actionOpId, label = label, createdAt = row.createdAt, free = row.txOpId == nil,
    }
end

-- At boot: a hold of a previous boot is gone (a resource stop cancels it, a server restart
-- forgets it). Before the install nothing happened: release and say so. During the install the
-- patient's record decides, as soon as they are connected (resolveRecovered).
function S:recover()
    self.bootAt = self.P.now()
    local released, pending = 0, 0
    for _, row in ipairs(self.J:open()) do
        if row.state == "installing" then
            self.recovering[row.id] = row
            pending = pending + 1
            self:log("recovery: surgery %s was installing at the restart: settled once %s's record is readable",
                row.id, tostring(row.patientSubject))
        else
            if row.txOpId then self.L.cancel(row.txOpId, "restart") end
            self.J:drop(row.id)
            released = released + 1
            self:tellSubject(row.patientSubject, "The clinic restarted before your operation: nothing was charged.", "warning")
            self:tellSubject(row.ripperSubject, ("The clinic restarted before %s's operation: nothing was charged and the implant stays in stock.")
                :format(tostring(row.patientName)), "warning")
            self:log("recovery: surgery %s (%s) released: nothing was installed", row.id, tostring(row.state))
        end
    end
    return released, pending
end

function S:resolveRecovered(row)
    local pid = self:playerBySubject(row.patientSubject)
    if not pid then return end                                  -- offline: when they are back
    local record = self.P.cyberware.current(pid)
    if type(record) ~= "table" then return end                  -- not bound yet
    if record.operationId == row.cwOpId then
        local outcome, receipt = "aborted", nil
        if row.txOpId then
            outcome, receipt = self.L.settle(row.txOpId)
            if outcome == "pending" then return end
        end
        self.recovering[row.id] = nil
        self.stats.recovered = self.stats.recovered + 1
        local s = self:surgeryFromRow(row, pid)
        s.installed = true
        self.surgeries[s.id] = s
        self:log("recovery: surgery %s had landed on the record; hold %s", s.id, outcome)
        if s.free then return self:completeSurgery(s, nil, "free") end
        if outcome == "committed" then return self:completeSurgery(s, receipt, "hold") end
        return self:settleByTransfer(s, "restart")
    end
    if self.P.now() - self.bootAt < self.cfg.operation.recoveryGraceMs then return end   -- may still land
    self.recovering[row.id] = nil
    self.stats.recovered = self.stats.recovered + 1
    if row.txOpId then self.L.settle(row.txOpId) end            -- fenced: the old hold can never commit
    self.J:drop(row.id)
    local s = self:surgeryFromRow(row, pid)
    self:tell(pid, ("Your operation (%s) did not go through before the clinic restarted: nothing was charged."):format(s.label), "warning")
    self:tellSubject(row.ripperSubject, ("%s's operation did not go through before the restart: nothing was charged and the implant stays in stock.")
        :format(s.patientName), "warning")
    self:log("recovery: surgery %s never landed: released", row.id)
end

-- ---------------------------------------------------------------------------------------------
-- The sweep (bounded: only live quotes, surgeries, offers and doubts)
-- ---------------------------------------------------------------------------------------------
function S:sweep()
    local cfg, M = self.cfg, self.M
    local now = self.P.now()
    for id, s in pairs(self.offers) do
        if self.P.interactions.get(id) then
            s.lastSeen = now
        elseif now - (s.lastSeen or now) > cfg.lostOfferMs then
            self.offers[id] = nil
            self:endOffer(s, "lost")
        end
    end
    for id, o in pairs(self.buys) do
        if self.P.interactions.get(id) then
            o.lastSeen = now
        elseif now - (o.lastSeen or now) > cfg.lostOfferMs then
            self.buys[id] = nil
            if self.buyOf[o.ripper] == id then self.buyOf[o.ripper] = nil end
            self:dropBuy(o, "lost")
        end
    end
    local list = {}
    for _, s in pairs(self.surgeries) do list[#list + 1] = s end
    for _, s in ipairs(list) do
        if s.state == "reserved" then
            local clinic = self.clinics[s.clinic]
            if now > s.validUntil then
                self:release(s, "cancelled", "quote_expired")
            elseif not self:isSubject(s.patient, s.patientSubject) then
                self:release(s, "cancelled", "patient_gone")
            elseif not self:isSubject(s.ripper, s.ripperSubject) then
                self:release(s, "cancelled", "ripper_gone")
            elseif not self.P.jobs.eligible(s.ripper, { job = cfg.job, duty = true, epoch = s.epoch }) then
                self:release(s, "cancelled", "ripper_off_duty")
            elseif self:isDead(s.patient) then
                self:release(s, "cancelled", "patient_dead")
            else
                local d = clinic and M.distance(self:posOf(s.patient), clinic.cfg.chair.position)
                if d and d > cfg.quote.leashM then self:release(s, "cancelled", "patient_walked_away") end
            end
        elseif s.state == "operating" then
            if s.actionOpId and (not self:isSubject(s.patient, s.patientSubject) or self:isDead(s.patient)) then
                self.P.actions.cancel(s.actionOpId, self:isDead(s.patient) and "patient_dead" or "patient_gone")
            end
        elseif s.state == "installing" then
            if s.settleRetry then
                s.settleRetry = nil
                self:finishInstall(s)
            elseif (s.waiters or 0) == 0 and (s.installed or s.installError) then
                self:finishInstall(s)
            elseif (s.waiters or 0) == 0 and s.submittedAt and now - s.submittedAt > cfg.operation.installTimeoutMs then
                local record = self.P.cyberware.current(s.patient)
                if type(record) == "table" and record.operationId == s.cwOpId then
                    s.installed = true
                    self:finishInstall(s)
                elseif s.ticket and not s.timeoutTried then
                    s.timeoutTried = true
                    self:installTimedOut(s)
                    if s.installError then self:finishInstall(s) end
                end
            end
        elseif s.endedAt and now - s.endedAt > 600000 then
            self.surgeries[s.id] = nil
        end
    end
    local rows = {}
    for _, row in pairs(self.recovering) do rows[#rows + 1] = row end
    for _, row in ipairs(rows) do self:resolveRecovered(row) end
    for txOpId, r in pairs(self.doubts) do
        local outcome, receipt = self.L.settle(txOpId)
        if outcome == "committed" then
            self:afterRestock(r, receipt)
        elseif outcome == "failed" or outcome == "aborted" then
            self.doubts[txOpId] = nil
            if self:isSubject(r.pid, r.subject) then self:tell(r.pid, "The chrome order did not go through: nothing was paid.", "warning") end
        end
    end
    for opId, o in pairs(self.buyDoubts) do
        local outcome, receipt = self.L.settle(opId)
        if outcome == "committed" then
            self:finishBuy(o, receipt, o.paidBy)
        elseif outcome == "failed" or outcome == "aborted" then
            self:dropBuy(o, "store_unavailable")
        end
    end
    for id, at in pairs(self.done) do
        if now - at > 600000 then self.done[id] = nil end
    end
end

function S:shutdown()
    -- The coordinator cancels this resource's holds when it stops; the platform cancels its
    -- interactions and open77_actions its actions. The journal keeps what a restart must settle.
end

return S
