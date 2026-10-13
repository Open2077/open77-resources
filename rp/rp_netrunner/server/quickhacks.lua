-- rp_netrunner / server/quickhacks.lua: the quickhacks a netrunner runs on players and on the
-- NCPD radio (kept from rp_netrunner 1.x): Ping, Short Circuit, Overheat, the jammer, and the
-- cyberdeck they need. Every quickhack item is burned through the coordinator (server/ledger.lua):
-- a ping or a jammer in one transfer, an upload held before Open77.hacking.start and committed when
-- the platform accepts it (released when it refuses). The hacks themselves are the platform's kit.
--
-- Global: NetrunnerQuickhacks.

NetrunnerQuickhacks = {}
local Q = {}
Q.__index = Q

local HACK_KINDS = { "short_circuit", "overheat" }

function NetrunnerQuickhacks.new(deps)
    return setmetatable({
        C = deps.shared, cfg = deps.config, M = deps.model, L = deps.ledger, P = deps.ports, svc = deps.service,
        deckDefined = false, deckReason = "not_started",
        jam = nil,            -- { deadline, by, byName } while the NCPD radio is jammed
        cooldowns = {},       -- [playerId] = { [kind] = monotonic deadline (s) }
        pings = {},           -- [playerId] = { [targetId] = token } (the relay threads)
        pendingDeck = {},     -- [playerId] = { ticket, grade, charge? }
        uploads = {},         -- [hacking actionId] = { player, kind, target, name }
    }, Q)
end

function Q:log(fmt, ...) self.P.log(fmt:format(...)) end

function Q:say(pid, text) self.P.say(pid, text, self.C.colors.net) end
function Q:warn(pid, text) self.P.say(pid, text, self.C.colors.warn) end

function Q:displayName(pid)
    local ok, full = pcall(Open77.exports.callSync, "rp_identity", "fullName", pid)
    if ok and type(full) == "string" and full ~= "" then return full end
    return self.P.players.name(pid) or ("#" .. tostring(pid))
end

local function fmtSeconds(s)
    s = math.max(0, math.ceil(s))
    if s >= 60 then return ("%d min %02d s"):format(s // 60, s % 60) end
    return ("%d s"):format(s)
end

-- ---------------------------------------------------------------------------------------------
-- Gates: job + duty (rp_jobs), alive, cooldowns
-- ---------------------------------------------------------------------------------------------
function Q:gate(pid)
    local ok, why = self.P.jobs.eligible(pid, { job = self.C.job, duty = true })
    if not ok then
        if why == "no_job" or why == "wrong_job" then
            self:warn(pid, "You are no netrunner. Find a fixer who trusts you with a deck.")
        elseif why == "off_duty" then
            self:warn(pid, "Off duty. /service to jack in first.")
        else
            self:log("quickhack gate for player %d: rp_jobs answered %s", pid, tostring(why))
            self:warn(pid, "The jobs registry is offline. No quickhack can be checked.")
        end
        return false
    end
    if self.P.players.isDead(pid) then
        self:warn(pid, "You are flatlined, choom. No netrunning from the floor.")
        return false
    end
    return true
end

function Q:cooldownLeft(pid, kind)
    local mine = self.cooldowns[pid]
    local deadline = mine and mine[kind]
    if not deadline then return 0 end
    return math.max(0, deadline - self.P.monotonic())
end

function Q:checkCooldown(pid, kind, label)
    local left = self:cooldownLeft(pid, kind)
    if left > 0 then
        self:warn(pid, ("%s is cooling down: %s left."):format(label, fmtSeconds(left)))
        return false
    end
    return true
end

function Q:setCooldown(pid, kind)
    self.cooldowns[pid] = self.cooldowns[pid] or {}
    self.cooldowns[pid][kind] = self.P.monotonic() + self.C.cooldownMs / 1000
end

function Q:itemLabel(item)
    local def = self.C.items[item] or self.cfg.items[item]
    return def and def.label or item
end

-- ---------------------------------------------------------------------------------------------
-- Items: read and burned through the coordinator (yield)
-- ---------------------------------------------------------------------------------------------
function Q:countOf(pid, item)
    local subject = self.L.subjectOf(pid)
    if not subject then return 0 end
    local snap = self.L.read(self.L.pocketsOf(subject))
    return self.L.available(snap, item)
end

local function burnText(self, item, why)
    if why == "insufficient_items" or why == "unknown_account" then
        return ("No %s in your pockets. Buy one on the black market."):format(self:itemLabel(item))
    end
    self:log("burning a %s refused: %s", item, tostring(why))
    return ("Could not burn a %s. %s"):format(self:itemLabel(item), self.M.textFor(why))
end

-- One quickhack burned at once (a ping, a jammer). Returns the receipt or nil (the player was told).
function Q:burn(pid, item, kind)
    local subject, swhy = self.L.subjectOf(pid)
    if not subject then
        self:log("pockets of player %d unreadable: %s", pid, tostring(swhy))
        self:warn(pid, self.M.textFor("no_pockets"))
        return nil
    end
    local receipt, why = self.L.transfer({ opId = self.L.newOpId("qh"), kind = "netrunner.quickhack",
        actor = self.L.pocketsOf(subject), reason = kind, lines = { { item = item, count = 1,
            from = self.L.pocketsOf(subject), to = self.cfg.accounts.sink, reason = kind } } })
    if not receipt then self:warn(pid, burnText(self, item, why)) end
    return receipt
end

-- A quickhack held while the platform decides on an upload. Returns the hold's op id or nil.
function Q:hold(pid, item, kind)
    local subject, swhy = self.L.subjectOf(pid)
    if not subject then
        self:log("pockets of player %d unreadable: %s", pid, tostring(swhy))
        self:warn(pid, self.M.textFor("no_pockets"))
        return nil
    end
    local opId = self.L.newOpId("qh")
    local held, why = self.L.reserve({ opId = opId, kind = "netrunner.quickhack", actor = self.L.pocketsOf(subject),
        reason = kind, ttlMs = 30000, lines = { { item = item, count = 1, from = self.L.pocketsOf(subject),
            to = self.cfg.accounts.sink, reason = kind } } })
    if not held then
        self:warn(pid, burnText(self, item, why))
        return nil
    end
    return opId
end

-- The tap on the deck others see (open77_actions action `qh_tap`, no bar). Presentation only.
function Q:gesture(pid)
    local op, why = self.P.actions.request(pid, "qh_tap", nil, nil)
    if not op then self:log("gesture for player %d skipped: %s", pid, tostring(why)) end
end

function Q:maybeTrace(pid, kind, position)
    if math.random() >= (self.C.traceChance or 0) then return false end
    return self.svc:trace(pid, { label = kind, position = position }, { wanted = false })
end

-- A living, connected target other than the netrunner, within `range` metres.
function Q:resolveTarget(pid, raw, range)
    local P = self.P
    local target = math.tointeger(tonumber(raw))
    if not target or target <= 0 then
        self:warn(pid, "Give a player id: /players lists them.")
        return nil
    end
    if target == pid then self:warn(pid, "Hacking yourself? Your deck refuses.") return nil end
    if not P.players.name(target) then self:warn(pid, ("No player #%d on this server."):format(target)) return nil end
    if P.players.isDead(target) then self:warn(pid, "That choom is already flatlined.") return nil end
    local metres, reason = P.players.distance(pid, target)
    if not metres then
        self:log("no distance to player %d: %s", target, tostring(reason))
        self:warn(pid, "Cannot place the target right now: try again in a moment.")
        return nil
    end
    if metres > range then
        self:warn(pid, ("Out of range (%.0f m). Get within %d m."):format(metres, range))
        return nil
    end
    return target, metres
end

-- ---------------------------------------------------------------------------------------------
-- The cyberdeck: definition, state, loading a grade
-- ---------------------------------------------------------------------------------------------
function Q:defineDeck()
    local C = self.C
    local hackGrades, implantGrades = {}, {}
    for _, kind in ipairs(HACK_KINDS) do
        local h = C.hacks[kind]
        local grade = {
            id = kind, kind = kind, range = h.range, uploadMs = h.uploadMs, staminaCost = h.staminaCost,
            cooldownMs = C.cooldownMs, damage = h.damage, statusMs = h.statusMs,
            recoveryMs = h.recoveryMs, nonlethal = h.nonlethal == true, lockHacking = false,
        }
        if kind == "overheat" and h.burn then grade.burn = h.burn end
        hackGrades[#hackGrades + 1] = grade
        -- The implant schema is shared by every slot: the punch fields must be present and inert.
        implantGrades[#implantGrades + 1] = {
            id = kind, normalDamage = 0, chargedDamage = 0, knockbackMeters = 0, cooldownMs = 100, chargeMs = 100,
        }
    end
    local ok, reason = self.P.hacking.define({ id = C.deck.id, version = C.deck.version, grades = hackGrades })
    if not ok then
        self.deckDefined, self.deckReason = false, "hacking:" .. tostring(reason)
        self:log("Open77.hacking.define refused: %s", tostring(reason))
        return
    end
    local ok2, reason2 = self.P.cyberware.define({ id = C.deck.id, version = C.deck.version, slot = "operating_system",
        profile = "cyberdeck", grades = implantGrades })
    if not ok2 then
        self.deckDefined, self.deckReason = false, "cyberware:" .. tostring(reason2)
        self:log("Open77.cyberware.define refused: %s", tostring(reason2))
        return
    end
    self.deckDefined, self.deckReason = true, nil
    self:log("deck %s v%d defined: %s", C.deck.id, C.deck.version, table.concat(HACK_KINDS, ", "))
end

-- The implant in the operating_system slot, whatever field name the record uses for it.
local function findImplant(record, slot)
    local direct = record[slot]
    if type(direct) == "table" then return direct end
    for _, value in pairs(record) do
        if type(value) == "table" and value.slot == slot then return value end
    end
    return nil
end

-- "unavailable", reason | "none" | "foreign", definitionId | "loaded", gradeId, record
function Q:deckState(pid)
    if not self.deckDefined then return "unavailable", self.deckReason end
    local record, reason = self.P.cyberware.current(pid)
    if not record then return "unavailable", reason or "record_not_ready" end
    local implant = findImplant(record, "operating_system")
    if not implant then return "none", nil, record end
    if implant.definition ~= self.C.deck.id then return "foreign", implant.definition, record end
    return "loaded", implant.grade and implant.grade.id or "?", record
end

-- Loads a grade (a cyberware install). With a price, one rp_economy charge first, refunded once
-- when the install is refused. Yields.
function Q:loadDeck(pid, gradeId, record)
    local C, P = self.C, self.P
    if self.pendingDeck[pid] then
        self:warn(pid, ("Your deck is still committing %s. Wait for 'Deck ready'."):format(C.hacks[self.pendingDeck[pid].grade].label))
        return false
    end
    local charge
    if (C.deck.price or 0) > 0 then
        charge = self.L.newOpId("deck")
        local receipt, why = P.economy.charge({ opId = charge, from = { player = pid }, amount = C.deck.price,
            instrument = "cash", to = { society = C.job }, reason = "netrunner deck" })
        if not receipt then
            self:log("deck charge for player %d refused: %s", pid, tostring(why))
            self:warn(pid, why == "insufficient_funds"
                and ("Loading a grade costs %d eddies in cash: you are short."):format(C.deck.price)
                or ("Loading a grade costs %d eddies and the payment did not go through. %s"):format(C.deck.price,
                    self.M.textFor(why)))
            return false
        end
    end
    local function refund()
        if charge then P.economy.refund({ of = charge, reason = "netrunner deck refused" }) end
    end
    local operationId, err = P.cyberware.newOperationId()
    if not operationId then
        refund()
        self:log("cyberware operation id for player %d refused: %s", pid, tostring(err))
        self:warn(pid, ("The ripper's chair did not answer: %s."):format(self.M.deckText(err)))
        return false
    end
    local result, reason = P.cyberware.install(pid, C.deck.id, gradeId,
        { expectedRevision = record.revision, operationId = operationId })
    if not result then
        refund()
        self:log("deck install for player %d refused: %s", pid, tostring(reason))
        self:warn(pid, ("The ripper's chair refused the deck: %s."):format(self.M.deckText(reason)))
        return false
    end
    if result.ticket then
        self.pendingDeck[pid] = { ticket = result.ticket, grade = gradeId, charge = charge }
        self:say(pid, ("Loading %s into your deck... run the hack again when it says 'Deck ready'."):format(C.hacks[gradeId].label))
    else
        self:say(pid, ("Deck ready: %s already loaded."):format(C.hacks[gradeId].label))
    end
    return true
end

function Q:onCyberwareCompleted(playerId, ticket, encoded)
    local pid = tonumber(playerId)
    local pending = pid and self.pendingDeck[pid]
    if not pending or pending.ticket ~= ticket then return end
    self.pendingDeck[pid] = nil
    local result = (type(encoded) == "string" and json and json.decode(encoded)) or {}
    if result.ok then
        self:say(pid, ("Deck ready: %s loaded."):format(self.C.hacks[pending.grade].label))
        self:log("player %d deck grade=%s installed", pid, pending.grade)
    else
        self:log("deck load for player %d failed: %s", pid, tostring(result.error))
        self:warn(pid, ("Deck load failed: %s."):format(self.M.deckText(result.error)))
        if pending.charge then
            self.P.spawn(function() self.P.economy.refund({ of = pending.charge, reason = "netrunner deck failed" }) end)
        end
    end
end

-- Makes sure the deck holds `kind`; returns true when the hack may start now. May yield.
function Q:ensureDeck(pid, kind)
    local st, detail, record = self:deckState(pid)
    if st == "unavailable" then
        if detail == "record_not_ready" then
            self:warn(pid, "Your implant record is not ready: the character adapter (open77_appearance) has not bound you yet, or no database runs. Try again in a moment.")
        else
            self:log("deck of player %d unavailable: %s", pid, tostring(detail))
            self:warn(pid, "The cyberdeck framework is offline: the operating-system implant cannot be read, so the kit refuses every upload.")
        end
        return false
    end
    if st == "foreign" then
        self:log("player %d OS slot holds %s", pid, tostring(detail))
        self:warn(pid, ("Your operating system slot holds another implant, not the netrunner deck. /netrun deck %s replaces it."):format(kind))
        return false
    end
    if st == "loaded" and detail == kind then return true end
    self:loadDeck(pid, kind, record)
    return false
end

-- ---------------------------------------------------------------------------------------------
-- Ping (yields)
-- ---------------------------------------------------------------------------------------------
function Q:doPing(pid, rawTarget)
    local C, P = self.C, self.P
    if not self:gate(pid) then return end
    local target = self:resolveTarget(pid, rawTarget, C.ping.range)
    if not target then return end
    if not self:checkCooldown(pid, "ping", "Ping") then return end
    if not self:burn(pid, C.ping.item, "ping") then return end
    self:setCooldown(pid, "ping")
    self:gesture(pid)

    local pos = P.players.position(target) or P.players.position(pid) or { x = 0, y = 0, z = 0 }
    local name = self:displayName(target)
    P.toClient("rp_netrunner:ping", pid, target, name, { x = pos.x, y = pos.y, z = pos.z })
    self:say(pid, ("Ping on %s: tracked on your map for %d s."):format(name, C.ping.durationMs // 1000))
    if C.ping.warnTarget then self:warn(target, "Your optics flicker for a second.") end

    self.pings[pid] = self.pings[pid] or {}
    local token = {}
    self.pings[pid][target] = token
    P.spawn(function()
        local deadline = P.monotonic() + C.ping.durationMs / 1000
        while P.monotonic() < deadline do
            P.wait(C.ping.refreshMs)
            if not self.pings[pid] or self.pings[pid][target] ~= token then return end
            if not P.players.name(pid) then return end
            local p = P.players.position(target)
            if not p or not P.players.name(target) then break end
            P.toClient("rp_netrunner:pingUpdate", pid, target, { x = p.x, y = p.y, z = p.z })
        end
        if self.pings[pid] and self.pings[pid][target] == token then self.pings[pid][target] = nil end
        if P.players.name(pid) then
            P.toClient("rp_netrunner:pingEnd", pid, target)
            self:say(pid, ("Ping on %s faded."):format(name))
        end
    end)
    self:log("player %d ping target=%s", pid, tostring(P.players.identifier(target)))
    self:maybeTrace(pid, "ping", P.players.position(pid))
end

-- ---------------------------------------------------------------------------------------------
-- Short Circuit / Overheat (the platform hacking kit; yields)
-- ---------------------------------------------------------------------------------------------
function Q:doHack(pid, kind, rawTarget)
    local C, P, L = self.C, self.P, self.L
    local hack = C.hacks[kind]
    if not hack then return end
    if not self:gate(pid) then return end
    local target, metres = self:resolveTarget(pid, rawTarget, hack.range)
    if not target then return end
    if not self:checkCooldown(pid, kind, hack.label) then return end
    if self:countOf(pid, hack.item) < 1 then
        self:warn(pid, burnText(self, hack.item, "insufficient_items"))
        return
    end
    if not self:ensureDeck(pid, kind) then return end
    local held = self:hold(pid, hack.item, kind)
    if not held then return end
    local operationId = ("rp_netrunner:%s:%d:%d:%d"):format(kind, pid, target, P.now())
    local result, reason = P.hacking.start(pid, target, C.deck.id, kind, { operationId = operationId })
    if not result then
        L.cancel(held, "upload_refused")
        self:log("quickhack %s by player %d refused: %s", kind, pid, tostring(reason))
        self:warn(pid, ("%s refused: %s."):format(hack.label, self.M.hackText(reason)))
        return
    end
    local receipt, why = L.commit(held)
    if not receipt then self:log("quickhack %s burn %s not committed: %s", kind, held, tostring(why)) end
    self:setCooldown(pid, kind)
    if type(result) == "table" and result.actionId then
        self.uploads[result.actionId] = { player = pid, kind = kind, target = target, name = self:displayName(target) }
    end
    self:say(pid, ("%s uploading on %s (%.0f m). Keep line of sight: the kit warns them."):format(hack.label,
        self:displayName(target), metres))
    self:log("player %d %s target=%s", pid, kind, tostring(P.players.identifier(target)))
    self:maybeTrace(pid, kind, P.players.position(pid))
end

-- The hacking ledger: tell the netrunner how the upload ended.
function Q:onHackingTransition(encoded)
    local t = type(encoded) == "string" and json and json.decode(encoded) or encoded
    if type(t) ~= "table" or t.definition ~= self.C.deck.id then return end
    local entry = self.uploads[t.actionId]
    if not entry then return end
    local label = self.C.hacks[entry.kind] and self.C.hacks[entry.kind].label or tostring(t.kind)
    if t.phase == "impact" then
        self:say(entry.player, ("%s landed on %s."):format(label, entry.name))
    elseif t.phase == "blocked" or t.phase == "interrupted" then
        self:log("quickhack %s %s: %s", tostring(t.actionId), t.phase, tostring(t.reason))
        self:warn(entry.player, ("%s %s: %s."):format(label, t.phase, self.M.hackText(t.reason)))
        self.uploads[t.actionId] = nil
    elseif t.phase == "status_expired" or t.phase == "status_purged" or t.phase == "completed" then
        self.uploads[t.actionId] = nil
    end
end

-- ---------------------------------------------------------------------------------------------
-- Jam the NCPD radio (yields)
-- ---------------------------------------------------------------------------------------------
function Q:isJamming()
    return self.jam ~= nil and self.P.monotonic() < self.jam.deadline
end

function Q:doJam(pid)
    local C, P = self.C, self.P
    if not self:gate(pid) then return end
    if self:isJamming() then
        self:warn(pid, ("A jammer is already burning (%s left)."):format(fmtSeconds(self.jam.deadline - P.monotonic())))
        return
    end
    if not self:checkCooldown(pid, "jam", "Jammer") then return end
    if not self:burn(pid, C.jam.item, "jam") then return end
    if self:isJamming() then return end
    self:setCooldown(pid, "jam")
    local jam = { deadline = P.monotonic() + C.jam.durationMs / 1000, by = pid, byName = self:displayName(pid) }
    self.jam = jam
    self:gesture(pid)
    P.emit("rp_netrunner:jammed", true)
    self:say(pid, ("Jammer live: NCPD radio is static for %d s."):format(C.jam.durationMs // 1000))
    self:log("jam started by player %d for %d ms", pid, C.jam.durationMs)
    local origin = P.players.position(pid)
    P.spawn(function()
        local n = 0
        while self.jam == jam and P.monotonic() < jam.deadline do
            n = n + 1
            local line = C.jam.noise[((n - 1) % #C.jam.noise) + 1]
            for _, officer in ipairs(P.jobs.listOnDuty("ncpd")) do
                P.say(officer, line, C.colors.static, "NCPD RADIO")
            end
            P.wait(C.jam.noiseEveryMs)
        end
        if self.jam ~= jam then return end
        self.jam = nil
        P.emit("rp_netrunner:jammed", false)
        self:log("jam ended")
        if P.players.name(pid) then
            self:say(pid, "Jammer burned out. NCPD radio is clear again.")
            -- The trace surfaces once the static clears: dispatch could not read it before.
            self:maybeTrace(pid, "jam", origin)
        end
    end)
end

-- ---------------------------------------------------------------------------------------------
-- /netrun status and deck loading (yield)
-- ---------------------------------------------------------------------------------------------
function Q:statusLines(pid)
    local C, P = self.C, self.P
    local lines = {}
    local ok, why = P.jobs.eligible(pid, { job = C.job, duty = true })
    lines[#lines + 1] = ok and "NETRUN - netrunner on duty." or ("NETRUN - " .. ((why == "no_job" or why == "wrong_job")
        and "not a netrunner" or why == "off_duty" and "netrunner, off duty" or "jobs registry offline") .. ".")
    for _, line in ipairs(self.svc:contractLines(pid)) do lines[#lines + 1] = line end

    local st, detail = self:deckState(pid)
    if st == "unavailable" then
        lines[#lines + 1] = "Implant: cyberdeck framework unavailable. Uploads are refused."
    elseif st == "none" then
        lines[#lines + 1] = "Implant: no operating system. /netrun deck short_circuit loads one."
    elseif st == "foreign" then
        lines[#lines + 1] = "Implant: another implant in the OS slot (not the netrunner deck)."
    else
        lines[#lines + 1] = ("Implant: netrunner deck loaded with %s.%s"):format(C.hacks[detail] and C.hacks[detail].label
            or tostring(detail), self.pendingDeck[pid] and " (reloading...)" or "")
    end

    local subject = self.L.subjectOf(pid)
    local snap = subject and self.L.read(self.L.pocketsOf(subject)) or nil
    local pockets = {}
    for _, id in ipairs({ "qh_ping", "qh_short_circuit", "qh_overheat", "qh_jammer" }) do
        pockets[#pockets + 1] = ("%s x%d"):format(self:itemLabel(id), self.L.available(snap, id))
    end
    local kit = self.cfg.breach and self.cfg.breach.item
    if kit then pockets[#pockets + 1] = ("%s x%d"):format(self:itemLabel(kit), self.L.available(snap, kit)) end
    lines[#lines + 1] = "Pockets: " .. table.concat(pockets, ", ")

    local cds = {}
    local labels = { ping = "Ping", short_circuit = "Short Circuit", overheat = "Overheat", jam = "Jammer" }
    for _, kind in ipairs({ "ping", "short_circuit", "overheat", "jam" }) do
        local left = self:cooldownLeft(pid, kind)
        if left > 0 then cds[#cds + 1] = ("%s %s"):format(labels[kind], fmtSeconds(left)) end
    end
    lines[#lines + 1] = "Cooldowns: " .. (#cds > 0 and table.concat(cds, ", ") or "all clear")

    -- The platform's own ledger: is somebody's hack still gating this netrunner?
    local state = P.hacking.state(pid)
    if type(state) == "table" then
        local gates = {}
        for _, field in ipairs({ "cyberwareSuspendedMs", "malfunctionMs", "frozenMs", "crippledMs", "blindedMs", "weaponGlitchedMs" }) do
            local ms = tonumber(state[field]) or 0
            if ms > 0 then gates[#gates + 1] = ("%s %s"):format(self.M.GATE_LABEL[field] or "hacked", fmtSeconds(ms / 1000)) end
        end
        if #gates > 0 then lines[#lines + 1] = "Kit: hacked - " .. table.concat(gates, ", ") end
    end
    if self:isJamming() then
        lines[#lines + 1] = ("NCPD radio jammed by %s: %s left."):format(self.jam.byName, fmtSeconds(self.jam.deadline - P.monotonic()))
    end
    return lines
end

function Q:netrunDeck(pid, kind)
    local C = self.C
    if not self:gate(pid) then return end
    kind = kind or "short_circuit"
    if not C.hacks[kind] then
        self:warn(pid, "Grades: /netrun deck short_circuit | overheat")
        return
    end
    local st, detail, record = self:deckState(pid)
    if st == "unavailable" then
        self:log("deck of player %d unavailable: %s", pid, tostring(detail))
        self:warn(pid, "The cyberdeck framework is offline: no grade can be loaded right now.")
        return
    end
    if st == "loaded" and detail == kind then
        self:say(pid, ("Deck ready: %s already loaded."):format(C.hacks[kind].label))
        return
    end
    self:loadDeck(pid, kind, record)
end

function Q:onDisconnected(pid)
    self.cooldowns[pid] = nil
    self.pings[pid] = nil
    self.pendingDeck[pid] = nil
    for actionId, entry in pairs(self.uploads) do
        if entry.player == pid then self.uploads[actionId] = nil end
    end
end

function Q:shutdown()
    if self.jam then
        self.jam = nil
        self.P.emit("rp_netrunner:jammed", false)
    end
end

return Q
