-- rp_ripperdoc / server/main.lua: wiring. The hooks open77_actions calls (exports), the boot order,
-- the library and platform events, the player commands, the exports and the operator console.

local RESOURCE = GetCurrentResourceName()
local cfg, M, L, P = RpRipperConfig, RipperModel, RipperLedger, RipperPorts
local Journal = RipperJournal.new(P, cfg)

local Svc = RipperService.new({ config = cfg, model = M, ledger = L, ports = P, journal = Journal, resource = RESOURCE })
-- Inspection handle for the offline suite: a global of this VM only.
RipperRuntime = { service = Svc }

local function log(line) print("[rp_ripperdoc] " .. line) end

-- ---------------------------------------------------------------------------------------------
-- Hooks. A hook is an export NAME given to open77_actions; any resource can call an export, so
-- each one checks that its caller is open77_actions (and the mutating ones also `verify` the
-- operation). validate is synchronous; the others run asynchronously and may yield.
-- ---------------------------------------------------------------------------------------------
exports("rdValidate", function(ctx) return Svc:validate(ctx) end)
exports("rdReserve", function(ctx) return Svc:reserve(ctx) end)
exports("rdCommit", function(ctx) return Svc:commit(ctx) end)
exports("rdCancel", function(ctx) return Svc:cancelHook(ctx) end)

-- ---------------------------------------------------------------------------------------------
-- Boot: coordinator ready, then items, the catalogue, the stashes, actions and targets, recovery.
-- ---------------------------------------------------------------------------------------------
local function waitFor(what, test, seconds)
    local waited, warned = 0, false
    while not test() do
        Wait(500)
        waited = waited + 0.5
        if waited >= (seconds or 30) and not warned then
            warned = true
            log(("still waiting for %s (the clinic accepts nothing until then)"):format(what))
        end
    end
end

local function pushDuty(pid)
    pid = M.playerId(pid)
    if not pid then return end
    local onDuty = P.jobs.eligible(pid, cfg.eligibility.args) == true
    P.toClient(pid, "rp_ripperdoc:duty", onDuty)
end

local function boot()
    waitFor("open77_transactions (ready)", function() return (L.ready()) end)
    waitFor("open77_actions", function() return P.running("open77_actions") end)
    waitFor("rp_inventory", function() return P.running("rp_inventory") end)
    local info = L.info()
    log(("coordinator ready (store=%s)"):format(tostring(info and info.store)))
    if info and info.store ~= "sql" then
        log("WARNING: the coordinator runs the DISPOSABLE lab store: nothing here survives a lab reset")
    end
    local backend = P.inventory.backend()
    if backend ~= "transactions" then
        log(("WARNING: rp_inventory backend is %s; pockets are invisible to the coordinator until " ..
            "rp_inventory_backend is transactions (buying chrome from players refuses)"):format(tostring(backend)))
    end
    for _ = 1, 60 do
        if Svc:defineItems() then break end
        Wait(1000)
    end
    Svc:defineCatalogue()
    for _ = 1, 60 do
        if Svc:openClinics() >= #cfg.clinicOrder then break end
        Wait(1000)
    end
    local targets = Svc:declare()
    Journal:setupHistory()
    local released, pending = Svc:recover()
    Svc.ready = true
    for _, pid in ipairs(P.players.all()) do pushDuty(pid) end
    local names = {}
    for key, clinic in pairs(Svc.clinics) do
        if clinic.opened then names[#names + 1] = ("%s (%s chair)"):format(key, clinic.cfg.chair.mode) end
    end
    table.sort(names)
    log(("ready: clinics %s, %d targets, supplier %s, job %s; recovery: %d released, %d to settle")
        :format(table.concat(names, ", "), targets, cfg.supplier.id, cfg.job, released, pending))
end

CreateThread(function()
    local ok, err = pcall(boot)
    if not ok then log("boot failed: " .. tostring(err)) end
end)

CreateThread(function()
    while true do
        Wait(cfg.sweepMs)
        if Svc.ready then
            local ok, err = pcall(Svc.sweep, Svc)
            if not ok then log("sweep raised: " .. tostring(err)) end
        end
    end
end)

-- ---------------------------------------------------------------------------------------------
-- Library and platform events
-- ---------------------------------------------------------------------------------------------
-- open77_actions restarted: it forgot every definition and target.
AddEventHandler("open77_actions:ready", function()
    if not Svc.ready then return end
    CreateThread(function()
        Svc:declare()
        log("open77_actions restarted: actions and targets declared again")
    end)
end)

AddEventHandler("open77_actions:transition", function(op)
    if type(op) ~= "table" or op.owner ~= RESOURCE then return end
    Svc:onTransition(op)
end)

-- The consent steps (quotes and buy-backs), delivered to the owning resource by the platform.
AddEventHandler("onPlayerInteractionCompleted", function(state)
    if type(state) == "string" then state = P.json.decode(state) end
    CreateThread(function() Svc:onInteractionCompleted(state) end)
end)
AddEventHandler("onPlayerInteractionCancelled", function(state)
    if type(state) == "string" then state = P.json.decode(state) end
    CreateThread(function() Svc:onInteractionCancelled(state) end)
end)

AddEventHandler("onCyberwareOperationCompleted", function(playerId, ticket, encoded)
    Svc:onCyberwareCompleted(playerId, ticket, encoded)
end)

-- A seat taken or left on a seating-mode chair.
local function seatingClinic(payload)
    if type(payload) ~= "table" then return nil end
    for key, clinic in pairs(Svc.clinics) do
        local chair = clinic.cfg.chair
        if chair.mode == "seating" and tostring(chair.furniture) == tostring(payload.furnitureId) then return key end
    end
    return nil
end
AddEventHandler("open77_seating:seated", function(payload)
    if seatingClinic(payload) then Svc:onPatientLay(M.playerId(payload.playerId)) end
end)
AddEventHandler("open77_seating:stood", function(payload)
    if seatingClinic(payload) then Svc:onPatientLeft(M.playerId(payload.playerId), payload.reason) end
end)

-- The ripperdoc's shift moved: withdraw a waiting quote, release an accepted one, push the duty flag.
AddEventHandler("rp_jobs:workEpoch", function(playerId, epoch)
    Svc:onWorkEpoch(playerId, epoch)
    pushDuty(playerId)
end)

AddEventHandler("onPlayerDisconnected", function(playerId)
    Svc:onDisconnected(playerId)
end)

AddEventHandler("onResourceStart", function(name)
    if not Svc.ready then return end
    if name == "rp_inventory" then
        CreateThread(function() Svc:defineItems() end)
    elseif name == "open77_cyberware" or name == "open77_hacking" then
        Svc:defineCatalogue()
    elseif name == "rp_jobs" then
        for _, pid in ipairs(P.players.all()) do pushDuty(pid) end
    end
end)

AddEventHandler("onResourceStop", function(name)
    if name == RESOURCE then Svc:shutdown() end
end)

-- Client -> server (requests only: the server checks everything again).
RegisterNetEvent("rp_ripperdoc:clientReady", function()
    local pid = M.playerId(source)
    if pid then pushDuty(pid) end
end)

RegisterNetEvent("rp_ripperdoc:quote", function(target)
    local ripper = M.playerId(source)
    if not ripper then return end
    local patient = M.playerId(target)
    if not patient then return Svc:refuseTo(ripper, "no_patient") end
    CreateThread(function() Svc:quote(ripper, patient) end)
end)

-- ---------------------------------------------------------------------------------------------
-- Commands
-- ---------------------------------------------------------------------------------------------
local function say(pid, text) Svc:tell(pid, text, "info") end

local function sendLines(pid, lines)
    for i, line in ipairs(lines) do
        pcall(Open77.chat.send, pid, { author = "RIPPERDOC", text = line, color = { 181, 123, 255 } })
        if i < #lines then Wait(0) end   -- two sends in one tick arrive in the opposite order
    end
end

local function implantLines(pid)
    local record, reason = P.cyberware.current(pid)
    if type(record) ~= "table" then
        return { ("Your implant record is not ready (%s). Try again in a moment."):format(tostring(reason)) }
    end
    local list = M.installedList(record)
    local lines = { ("Implants: %d installed (cyberpsychosis past %d)."):format(#list, tonumber(cfg.cyberpsychosisThreshold) or 4) }
    for _, slot in ipairs(M.SLOTS) do
        local implant = M.installedInSlot(record, slot)
        local entry = M.entryBySlot(cfg, slot)
        if implant then
            lines[#lines + 1] = ("  %s: %s"):format(slot, (M.describeImplant(cfg, implant)))
        else
            lines[#lines + 1] = ("  %s: - (%s)"):format(slot, entry and entry.label or slot)
        end
    end
    return lines
end

local function stockLines(clinic)
    local snap = L.read(clinic.stock)
    local parts = {}
    for _, row in ipairs(M.stockItems(cfg)) do
        local n = L.available(snap, row.item)
        if n > 0 then parts[#parts + 1] = ("%s x%d"):format(M.label(row.entry, row.grade), n) end
    end
    return ("Stock at %s: %s"):format(clinic.cfg.label, #parts > 0 and table.concat(parts, ", ")
        or "empty. Restock at the chrome dealer (Kabuki Market) or /ripper buy from a player.")
end

local function firstClinic()
    for _, key in ipairs(cfg.clinicOrder) do
        local clinic = Svc.clinics[key]
        if clinic and clinic.opened then return clinic end
    end
    return nil
end

local function ripperBoard(pid)
    local lines = {}
    local onDuty = P.jobs.eligible(pid, cfg.eligibility.args) == true
    lines[#lines + 1] = ("RIPPERDOC %s - grade %s - %s."):format(Svc:nameOf(pid), P.jobs.gradeLabel(pid),
        onDuty and "ON DUTY" or "off duty (/service to clock in)")
    local s = Svc.byPlayer[pid]
    if s then
        lines[#lines + 1] = ("Current: %s %s for %s, %s (%s)."):format(s.proc.action, s.label, s.patientName,
            M.money(s.price), s.state)
    else
        lines[#lines + 1] = "No procedure in progress. ALT+click a patient > Quote, or /ripper quote <id>."
    end
    local clinic = Svc:clinicOf(pid) or firstClinic()
    if clinic then lines[#lines + 1] = stockLines(clinic) end
    local soc = L.read("soc:" .. cfg.society)
    if type(soc) == "table" then
        lines[#lines + 1] = ("Society %s: %s."):format(cfg.society, M.money(soc.balance))
    end
    local since = P.now() - 86400000
    local rows = Journal:recent(clinic and clinic.key, since, cfg.logKept)
    lines[#lines + 1] = ("Last 24 h: %d procedure(s)."):format(#rows)
    for i = 1, math.min(5, #rows) do
        local row = rows[i]
        local entry = M.entry(cfg, row.key)
        local grade = entry and M.grade(entry, row.grade)
        lines[#lines + 1] = ("  %s %s on %s - %s (%s), %d min ago"):format(row.action,
            entry and M.label(entry, grade) or tostring(row.key), tostring(row.patientName), M.money(row.price),
            tostring(row.how), math.floor((P.now() - (tonumber(row.at) or 0)) / 60000))
    end
    return lines
end

local function patientView(pid)
    local lines = implantLines(pid)
    local rippers = P.jobs.listOnDuty(cfg.job)
    if #rippers == 0 then
        lines[#lines + 1] = "Ripperdocs on duty: none. Nobody can give you a quote right now - come back later, choom."
    else
        local names = {}
        for _, id in ipairs(rippers) do names[#names + 1] = Svc:nameOf(id) end
        lines[#lines + 1] = ("Ripperdocs on duty: %s. Go to Vik's clinic and ask for a quote."):format(table.concat(names, ", "))
    end
    local s = Svc.byPlayer[pid]
    if s and s.patient == pid then
        lines[#lines + 1] = ("Your procedure: %s for %s (%s)."):format(s.label, M.money(s.price), s.state)
    end
    return lines
end

local function argPlayer(value) return M.playerId(value) end

local function nearestClinicChair(pid, radius)
    local pos = Svc:posOf(pid)
    local best, bestD
    for _, clinic in pairs(Svc.clinics) do
        if clinic.opened then
            local d = M.distance(pos, clinic.cfg.chair.position)
            if d and d <= radius and (not bestD or d < bestD) then best, bestD = clinic, d end
        end
    end
    return best
end

local function requestFor(pid, action, target, options)
    local op, why = P.actions.request(pid, action, target, options)
    if not op then Svc:refuseTo(pid, why) end
    return op, why
end

local function cancelOwn(pid)
    local s = Svc.byPlayer[pid]
    if not s then return Svc:refuseTo(pid, "nothing_to_cancel") end
    local who = s.ripper == pid and "withdrawn" or "patient_stopped"
    if s.state == "offered" then
        P.interactions.cancel(s.interaction, who)
    elseif s.state == "reserved" then
        Svc:release(s, "cancelled", who)
    elseif s.state == "operating" and s.actionOpId then
        P.actions.cancel(s.actionOpId, who)
    elseif s.state == "installing" then
        Svc:refuseTo(pid, "installing")
    end
end

local USAGE = "Ripperdoc: /ripper quote <id> [implant] [grade] | remove <id> <implant> | operate | cancel | " ..
    "restock [implant] [grade] [count] | buy <id> <implant> [grade] [count] | stock | lie. Implants: arms, legs, deck, ice, purge."

RegisterCommand("ripper", function(source, args)
    local pid = M.playerId(source)
    if not pid then return log("/ripper is a player command; the console uses ripper.status, ripper.seed, ripper.setup and ripper.journal") end
    if not Svc.ready then return Svc:refuseTo(pid, "clinic_unavailable") end
    local verb = args and args[1] and tostring(args[1]):lower() or ""
    CreateThread(function()
        if verb == "quote" then
            local patient = argPlayer(args[2])
            if not patient then return say(pid, "Usage: /ripper quote <playerId> [implant] [grade]") end
            local choice = nil
            if args[3] then
                local entry, grade = M.resolve(cfg, tostring(args[3]):lower(), args[4] and tostring(args[4]):lower())
                if not entry or not grade then return Svc:refuseTo(pid, "unknown_implant") end
                choice = { action = "install", key = entry.key, grade = grade.id }
            end
            Svc:quote(pid, patient, choice)
        elseif verb == "remove" then
            local patient = argPlayer(args[2])
            local entry = args[3] and M.entry(cfg, tostring(args[3]):lower())
            if not patient or not entry then return say(pid, "Usage: /ripper remove <playerId> <implant>") end
            Svc:quote(pid, patient, { action = "remove", key = entry.key })
        elseif verb == "operate" then
            local s = Svc.byPlayer[pid]
            if not s or s.ripper ~= pid then return Svc:refuseTo(pid, "no_quote") end
            requestFor(pid, M.actionId(s.proc), s.clinic .. "_station")
        elseif verb == "cancel" then
            cancelOwn(pid)
        elseif verb == "restock" then
            local options
            if args[2] then
                local entry, grade = M.resolve(cfg, tostring(args[2]):lower(), args[3] and tostring(args[3]):lower())
                if not entry or not grade then return Svc:refuseTo(pid, "unknown_implant") end
                local count = M.count(args[4] or 1, cfg.supplier.maxCount)
                if not count then return say(pid, ("Count must be 1 to %d."):format(cfg.supplier.maxCount)) end
                options = { data = { item = grade.item, count = count } }
            end
            requestFor(pid, "restock", cfg.supplier.id, options)
        elseif verb == "buy" then
            local seller = argPlayer(args[2])
            if not seller or not args[3] then return say(pid, "Usage: /ripper buy <playerId> <implant> [grade] [count]") end
            local o, why = Svc:offerBuy(pid, seller, tostring(args[3]):lower(), args[4] and tostring(args[4]):lower(), args[5])
            if not o then Svc:refuseTo(pid, why) end
        elseif verb == "stock" then
            local clinic = Svc:clinicOf(pid) or firstClinic()
            if not clinic then return Svc:refuseTo(pid, "unknown_clinic") end
            say(pid, stockLines(clinic))
        elseif verb == "lie" then
            local clinic = nearestClinicChair(pid, 3.0)
            if not clinic then return Svc:refuseTo(pid, "too_far") end
            local chair = clinic.cfg.chair
            if chair.mode == "seating" then
                local ok, why = P.seating.sit(pid, chair.furniture, chair.spot and { spot = chair.spot } or nil)
                if not ok then Svc:refuseTo(pid, why) end
            else
                requestFor(pid, "lie_" .. clinic.key, clinic.key .. "_chair")
            end
        elseif verb == "help" then
            say(pid, USAGE)
        elseif P.jobs.eligible(pid, { job = cfg.job }) == true then
            sendLines(pid, ripperBoard(pid))
        else
            sendLines(pid, patientView(pid))
        end
    end)
end, false)

-- The 1.x command, kept: opens the catalogue for that patient (the quote replaces the old flow).
RegisterCommand("operer", function(source, args)
    local pid = M.playerId(source)
    if not pid then return log("/operer is a player command") end
    local patient = argPlayer(args and args[1])
    if not patient then return say(pid, "Usage: /operer <playerId> - the catalogue and a quote for that patient.") end
    CreateThread(function() Svc:quote(pid, patient) end)
end, false)

RegisterCommand("implants", function(source)
    local pid = M.playerId(source)
    if not pid then return log("/implants is a player command") end
    CreateThread(function() sendLines(pid, implantLines(pid)) end)
end, false)

local SUGGESTIONS = {
    { command = "ripper", help = "Ripperdoc: board, stock and today's log (patients: your implants)",
      parameters = { { name = "quote|remove|operate|cancel|restock|buy|stock|lie|help", help = "/ripper help" } } },
    { command = "operer", help = "Ripperdoc on duty: the catalogue and a quote for a patient",
      parameters = { { name = "playerId", help = "the patient" } } },
    { command = "implants", help = "Your installed implants, as the platform reports them", parameters = {} },
}

RegisterNetEvent("chat:ready", function()
    local pid = M.playerId(source)
    if pid then pcall(Open77.chat.addSuggestions, pid, SUGGESTIONS) end
end)

-- ---------------------------------------------------------------------------------------------
-- Operator console (restricted: console, or ACL command.ripper.*)
-- ---------------------------------------------------------------------------------------------
local function reply(source, message)
    print("[rp_ripperdoc] " .. message)
    local pid = M.playerId(source)
    if pid then pcall(Open77.chat.send, pid, { author = "RIPPERDOC", text = message }) end
end

RegisterCommand("ripper.status", function(source)
    local s = Svc.stats
    local live, offers, recovering = 0, 0, 0
    for _, x in pairs(Svc.surgeries) do if x.state == "reserved" or x.state == "operating" or x.state == "installing" then live = live + 1 end end
    for _ in pairs(Svc.offers) do offers = offers + 1 end
    for _ in pairs(Svc.recovering) do recovering = recovering + 1 end
    reply(source, ("ready=%s targets=%s | quotes=%d accepted=%d declined=%d operations=%d installs=%d removals=%d " ..
        "cancelled=%d failed=%d settled=%d unpaid=%d restocks=%d buybacks=%d recovered=%d refusals=%d | " ..
        "live=%d offers=%d recovering=%d")
        :format(tostring(Svc.ready), tostring(Svc.targetCount), s.quotes, s.accepted, s.declined, s.operations,
        s.installs, s.removals, s.cancelled, s.failed, s.settled, s.unpaid, s.restocks, s.buybacks, s.recovered,
        s.refusals, live, offers, recovering))
    for id, x in pairs(Svc.surgeries) do
        if x.state == "reserved" or x.state == "operating" or x.state == "installing" then
            reply(source, ("surgery %s %s %s for %s by %s, %d eddies, cyberware op %s"):format(id, x.state,
                M.actionId(x.proc), tostring(x.patientName), tostring(x.ripperName), x.price, tostring(x.cwOpId)))
        end
    end
end, true)

-- ripper.seed [clinic] [item|all] [count]: boxes minted into a clinic's stock (the supplier's
-- mint rule caps it).
RegisterCommand("ripper.seed", function(source, args)
    local clinic = args[1] or cfg.clinicOrder[1]
    local item = args[2] ~= "all" and args[2] or nil
    local count = M.count(args[3] or 1, 50)
    if not count then return reply(source, "count must be 1 to 50") end
    CreateThread(function()
        local receipt, why = Svc:seedStock(clinic, item, count)
        reply(source, receipt and ("seed %s at %s: committed"):format(tostring(receipt.opId), clinic)
            or ("seed refused: %s"):format(tostring(why)))
    end)
end, true)

-- ripper.setup <playerId>: the ripper job + duty (rp_jobs exports).
RegisterCommand("ripper.setup", function(source, args)
    local pid = argPlayer(args[1])
    if not pid then return reply(source, "usage: ripper.setup <playerId>") end
    local ok, why = P.sync("rp_jobs", "setJob", pid, cfg.job, 0)
    reply(source, ("setJob %d %s: %s %s"):format(pid, cfg.job, tostring(ok), tostring(why or "")))
    local on, dwhy = P.sync("rp_jobs", "setDuty", pid, true, { job = cfg.job })
    reply(source, ("setDuty %d on: %s %s"):format(pid, tostring(on), tostring(dwhy or "")))
end, true)

-- ripper.journal: the open journal rows (what a restart would settle).
RegisterCommand("ripper.journal", function(source)
    local rows = Journal:open()
    reply(source, ("journal: %d open row(s)"):format(#rows))
    for _, row in ipairs(rows) do
        reply(source, ("  %s %s %s/%s patient %s price %s tx %s cw %s"):format(row.id, row.state, tostring(row.action),
            tostring(row.key), tostring(row.patientSubject), tostring(row.price), tostring(row.txOpId), tostring(row.cwOpId)))
    end
end, true)

-- ---------------------------------------------------------------------------------------------
-- Exports (server, synchronous, never yield): read-only views for other resources
-- ---------------------------------------------------------------------------------------------
exports("isOnChair", function(playerId)
    local pid = M.playerId(playerId)
    return pid ~= nil and Svc:isLying(pid)
end)

exports("implantCount", function(playerId)
    local pid = M.playerId(playerId)
    if not pid then return nil, "invalid_player_id" end
    local record, reason = P.cyberware.current(pid)
    if type(record) ~= "table" then return nil, reason or "record_not_ready" end
    return #M.installedList(record)
end)

exports("catalogue", function()
    local list = {}
    for _, entry in ipairs(cfg.catalogue) do
        local grades = {}
        for _, grade in ipairs(entry.grades) do
            grades[#grades + 1] = { id = grade.id, label = grade.label, price = grade.price, durationMs = grade.durationMs,
                item = grade.item }
        end
        list[#list + 1] = {
            key = entry.key, label = entry.label, slot = entry.slot, profile = entry.profile,
            definitionId = entry.definitionId, available = Svc.defined[entry.key] == true,
            reason = Svc.defineReason[entry.key], grades = grades,
        }
    end
    return list
end)

-- The live procedure of a player (ripperdoc or patient), or nil.
exports("procedure", function(playerId)
    local pid = M.playerId(playerId)
    local s = pid and Svc.byPlayer[pid]
    if not s then return nil end
    return { id = s.id, state = s.state, action = s.proc.action, implant = s.proc.key, grade = s.proc.grade,
        price = s.price, clinic = s.clinic, ripper = s.ripper, patient = s.patient }
end)
