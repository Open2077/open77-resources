-- rp_netrunner / server/main.lua: wiring. The hooks open77_actions calls (exports), the boot order,
-- the library and platform events, the player commands, the exports for other resources (the
-- fixer board) and the restricted console commands.

local RESOURCE = GetCurrentResourceName()
local cfg, M, L, P = NetrunnerConfig, NetrunnerModel, NetrunnerLedger, NetrunnerPorts

-- The quickhack items are declared with the contract items, through rp_inventory.
for id, def in pairs(Config.items or {}) do
    if cfg.items[id] == nil then cfg.items[id] = def end
end

local Svc = NetrunnerService.new({ config = cfg, model = M, ledger = L, ports = P, shared = Config, resource = RESOURCE })
local Qh = NetrunnerQuickhacks.new({ shared = Config, config = cfg, model = M, ledger = L, ports = P, service = Svc })
-- Inspection handle for the offline suite: a global of this VM only.
NetrunnerRuntime = { service = Svc, quickhacks = Qh }

local function log(line) print("[rp_netrunner] " .. line) end

-- ---------------------------------------------------------------------------------------------
-- Hooks. A hook is an export NAME given to open77_actions; any resource can call an export, so
-- each one checks that its caller is open77_actions (and the mutating ones also `verify` the
-- operation). validate is synchronous; the others run asynchronously and may yield.
-- ---------------------------------------------------------------------------------------------
exports("nrValidate", function(ctx) return Svc:validate(ctx) end)
exports("nrReserve", function(ctx) return Svc:reserve(ctx) end)
exports("nrCommit", function(ctx) return Svc:commit(ctx) end)
exports("nrCancel", function(ctx) return Svc:cancelHook(ctx) end)

-- ---------------------------------------------------------------------------------------------
-- Boot: the deck, then the coordinator ready, items, the board, actions and targets.
-- ---------------------------------------------------------------------------------------------
local function waitFor(what, test, seconds)
    local waited, warned = 0, false
    while not test() do
        Wait(500)
        waited = waited + 0.5
        if waited >= (seconds or 30) and not warned then
            warned = true
            log(("still waiting for %s (the contract board accepts nothing until then)"):format(what))
        end
    end
end

-- Duty state pushed to the client, so the ALT+click entries only show for an on-duty netrunner.
local function pushSelf(pid)
    pid = M.playerId(pid)
    if not pid or not P.players.name(pid) then return end
    P.toClient("rp_netrunner:self", pid, P.jobs.eligible(pid, cfg.eligibility.args) == true)
end

local function boot()
    Svc:loadConfig()
    Qh:defineDeck()
    waitFor("open77_transactions (ready)", function() return (L.ready()) end)
    waitFor("open77_actions", function() return P.running("open77_actions") end)
    waitFor("rp_inventory", function() return P.running("rp_inventory") end)
    local info = L.info()
    log(("coordinator ready (store=%s)"):format(tostring(info and info.store)))
    if info and info.store ~= "sql" then
        log("WARNING: the coordinator runs a DISPOSABLE store: nothing here survives its reset")
    end
    local backend = P.inventory.backend()
    if backend ~= "transactions" then
        log(("WARNING: rp_inventory backend is %s; pockets are invisible to the coordinator until " ..
            "rp_inventory_backend is transactions (breaches and quickhacks refuse)"):format(tostring(backend)))
    end
    for _ = 1, 60 do
        if Svc:defineItems() then break end
        Wait(1000)
    end
    local opened, why
    for _ = 1, 60 do
        opened, why = Svc:openBoard()
        if opened then break end
        Wait(1000)
    end
    if not opened then log(("WARNING: the contract board did not open (%s): retried by the sweep"):format(tostring(why))) end
    Svc:refresh()
    local targets = Svc:declare()
    Svc.ready = true
    local sites, contracts = 0, 0
    for _ in pairs(Svc.sites) do sites = sites + 1 end
    for _ in pairs(Svc.contracts) do contracts = contracts + 1 end
    log(("ready: %d breach sites, %d fixer drop(s), %d targets, %d contract(s) on the board (job %s)"):format(sites,
        #cfg.fixers, targets, contracts, cfg.job))
    for _, pid in ipairs(P.players.all()) do
        Svc:onReady(pid)
        pushSelf(pid)
    end
end

CreateThread(function()
    local ok, err = pcall(boot)
    if not ok then log("boot failed: " .. tostring(err)) end
end)

CreateThread(function()
    while true do
        Wait(cfg.sweepMs)
        if Svc.ready and not Svc.boardLoaded then pcall(Svc.openBoard, Svc) end
        local ok, err = pcall(Svc.sweep, Svc)
        if not ok then log("sweep raised: " .. tostring(err)) end
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
    CreateThread(function() Svc:onTransition(op) end)
end)

-- The hand-over to a player fixer (delivered to the owning resource by the platform).
AddEventHandler("onPlayerInteractionCompleted", function(state)
    CreateThread(function() Svc:onInteractionCompleted(state) end)
end)
AddEventHandler("onPlayerInteractionCancelled", function(state)
    CreateThread(function() Svc:onInteractionCancelled(state) end)
end)

AddEventHandler("rp_jobs:workEpoch", function(playerId, epoch)
    Svc:onWorkEpoch(playerId, epoch)
    pushSelf(playerId)
end)
AddEventHandler("rp_jobs:duty", function(playerId) pushSelf(playerId) end)
AddEventHandler("rp_jobs:changed", function(playerId) pushSelf(playerId) end)

AddEventHandler("onPlayerReady", function(playerId)
    Svc:onReady(playerId)
end)

AddEventHandler("onPlayerDisconnected", function(playerId)
    local pid = M.playerId(playerId)
    if not pid then return end
    Svc:onDisconnected(pid)
    Qh:onDisconnected(pid)
end)

AddEventHandler("onResourceStart", function(name)
    if name == "rp_inventory" and Svc.ready then
        CreateThread(function() Svc:defineItems() end)
    end
end)

AddEventHandler("onResourceStop", function(name)
    if name == RESOURCE then
        Svc:shutdown()
        Qh:shutdown()
    end
end)

AddEventHandler("onCyberwareOperationCompleted", function(playerId, ticket, encoded)
    Qh:onCyberwareCompleted(playerId, ticket, encoded)
end)

AddEventHandler("onHackingTransition", function(encoded)
    Qh:onHackingTransition(encoded)
end)

-- ---------------------------------------------------------------------------------------------
-- Player commands
-- ---------------------------------------------------------------------------------------------
local function fromGame(source, name)
    if M.playerId(source) then return true end
    print(("[rp_netrunner] %s: run it from the game (the console uses netrun.*)"):format(name))
    return false
end

local function refuse(pid, why) Svc:refuseTo(pid, why) end

-- The breach site whose terminal is within reach of the player (the prompt's request).
local function siteNear(pid)
    local pos = P.players.position(pid)
    local best, bestD
    for key, site in pairs(Svc.sites) do
        local d = M.distance(pos, site.position)
        if d and d <= cfg.maxDistance and (not bestD or d < bestD) then best, bestD = key, d end
    end
    return best
end

local function fixerNear(pid, radius)
    local pos = P.players.position(pid)
    for key, fixer in pairs(Svc.fixers) do
        local d = M.distance(pos, fixer.position)
        if d and d <= radius then return key end
    end
    return nil
end

local HELP = "Netrunner: /netrun (status), /netrun contracts, /netrun board (at a fixer drop), /netrun take <code>, " ..
    "/netrun abandon, /breach at the terminal, /netrun deliver [fixer id], /netrun deck <short_circuit|overheat>. " ..
    "Fixers: /netrun sites, /netrun post <site> [reward] [minutes], /netrun cancel <code>. Quickhacks: /ping, " ..
    "/court_circuit, /surchauffe, /brouiller. /netrun help shows this line."

RegisterCommand("netrun", function(source, args)
    if not fromGame(source, "netrun") then return end
    local pid = M.playerId(source)
    local verb = args and args[1] or ""
    CreateThread(function()
        if verb == "" or verb == "status" then
            for _, line in ipairs(Qh:statusLines(pid)) do P.say(pid, line) end
        elseif verb == "help" then
            P.say(pid, HELP)
        elseif verb == "deck" then
            Qh:netrunDeck(pid, args[2])
        elseif not Svc.ready then
            refuse(pid, "netrunner_unavailable")
        elseif verb == "contracts" or verb == "list" then
            Svc:listTo(pid)
        elseif verb == "sites" then
            Svc:sitesTo(pid)
        elseif verb == "board" then
            local point = fixerNear(pid, 15.0)
            if not point then return refuse(pid, "too_far") end
            Svc:showBoard(pid, point)
        elseif verb == "take" then
            local summary, why = Svc:take(pid, args[2])
            if not summary then refuse(pid, why) end
        elseif verb == "abandon" then
            local ok, why = Svc:abandon(pid)
            if ok then P.tell(pid, "Contract dropped: it is back on the board.", "info") else refuse(pid, why) end
        elseif verb == "deliver" then
            local subject = L.subjectOf(pid)
            local c = Svc:activeContract(subject)
            if c and c.poster ~= "player" then
                local point = fixerNear(pid, cfg.maxDistance)
                if not point then return refuse(pid, "wrong_drop") end
                local op, why = P.actions.request(pid, "deliver", "fixer_" .. point)
                if not op then refuse(pid, why) end
                return
            end
            local o, why = Svc:handover(pid, args[2])
            if not o then refuse(pid, why) end
        elseif verb == "post" then
            if args[3] and not M.integer(args[3]) then return refuse(pid, "invalid_reward") end
            if args[4] and not M.integer(args[4]) then return refuse(pid, "invalid_deadline") end
            local summary, why = Svc:post({ site = args[2], fixer = pid, reward = M.integer(args[3]),
                minutes = M.integer(args[4]), point = fixerNear(pid, 15.0) })
            if not summary then refuse(pid, why) end
        elseif verb == "cancel" then
            local ok, why = Svc:cancelContract(args[2], pid)
            if ok then P.tell(pid, "Contract pulled from the board.", "info") else refuse(pid, why) end
        else
            P.say(pid, HELP)
        end
    end)
end, false)

-- The breach prompt's request from chat (the terminal within reach).
RegisterCommand("breach", function(source)
    if not fromGame(source, "breach") then return end
    local pid = M.playerId(source)
    if not Svc.ready then return refuse(pid, "netrunner_unavailable") end
    local key = siteNear(pid)
    if not key then return refuse(pid, "not_here") end
    local op, why = P.actions.request(pid, "breach_" .. key, "site_" .. key)
    if not op then refuse(pid, why) end
end, false)

RegisterCommand("ping", function(source, args)
    if not fromGame(source, "ping") then return end
    CreateThread(function() Qh:doPing(M.playerId(source), args[1]) end)
end, false)

RegisterCommand("court_circuit", function(source, args)
    if not fromGame(source, "court_circuit") then return end
    CreateThread(function() Qh:doHack(M.playerId(source), "short_circuit", args[1]) end)
end, false)

RegisterCommand("surchauffe", function(source, args)
    if not fromGame(source, "surchauffe") then return end
    CreateThread(function() Qh:doHack(M.playerId(source), "overheat", args[1]) end)
end, false)

RegisterCommand("brouiller", function(source)
    if not fromGame(source, "brouiller") then return end
    CreateThread(function() Qh:doJam(M.playerId(source)) end)
end, false)

-- ALT+click on a player (client context menu): only the kind and the target id cross.
RegisterNetEvent("rp_netrunner:action", function(kind, targetId)
    local pid = M.playerId(source)
    if not pid then return end
    CreateThread(function()
        if kind == "ping" then
            Qh:doPing(pid, targetId)
        elseif kind == "short_circuit" or kind == "overheat" then
            Qh:doHack(pid, kind, targetId)
        elseif kind == "handover" then
            local o, why = Svc:handover(pid, targetId)
            if not o then refuse(pid, why) end
        end
    end)
end)

RegisterNetEvent("rp_netrunner:clientReady", function() pushSelf(source) end)

local SUGGESTIONS = {
    { command = "/netrun", help = "Netrunner: status, contracts, take, abandon, deliver, deck; fixers: sites, post, cancel",
      parameters = { { name = "verb", help = "contracts | take <code> | abandon | deliver [fixer id] | deck <grade> | sites | post <site> [reward] [minutes] | cancel <code>" } } },
    { command = "/breach", help = "Breach the terminal you stand at (your contract's site)" },
    { command = "/ping", help = "Ping a player: a 60 s tracking pin on your map", parameters = { { name = "playerId", help = "target session id" } } },
    { command = "/court_circuit", help = "Short Circuit a player within 25 m (line of sight)", parameters = { { name = "playerId", help = "target session id" } } },
    { command = "/surchauffe", help = "Overheat a player within 25 m (line of sight)", parameters = { { name = "playerId", help = "target session id" } } },
    { command = "/brouiller", help = "Jam the NCPD radio for 60 s" },
}

RegisterNetEvent("chat:ready", function()
    pcall(Open77.chat.addSuggestions, source, SUGGESTIONS)
end)
CreateThread(function() pcall(Open77.chat.addSuggestions, -1, SUGGESTIONS) end)

-- ---------------------------------------------------------------------------------------------
-- Exports for other resources (the fixer board). Synchronous ones read the cache and never yield;
-- `post` and `cancel` write the coordinator: call them with Open77.exports.call(...):await().
-- ---------------------------------------------------------------------------------------------
exports("contracts", function(filter)
    local out = {}
    for i, c in ipairs(Svc:sorted(type(filter) == "table" and filter or nil)) do out[i] = Svc:summaryOf(c) end
    return out
end)

exports("contract", function(ref)
    local c = Svc:find(type(ref) == "string" and ref or tostring(ref))
    return c and Svc:summaryOf(c) or nil
end)

exports("sites", function()
    local out = {}
    for _, site in ipairs(cfg.sites) do
        if Svc.sites[site.key] then
            local tier = cfg.tiers[site.tier]
            out[#out + 1] = { key = site.key, label = site.label, area = site.area, tier = site.tier, tierLabel = tier.label,
                position = M.copy(site.position), reward = M.copy(tier.reward), minutes = M.copy(tier.minutes),
                busy = Svc.siteOf[site.key] ~= nil, npc = site.npc == true }
        end
    end
    return out
end)

exports("activeContract", function(playerId)
    local pid = M.playerId(playerId)
    local subject = pid and L.subjectOf(pid)
    local c = subject and Svc:activeContract(subject)
    return c and Svc:summaryOf(c) or nil
end)

exports("isJamming", function() return Qh:isJamming() end)

-- post { site, reward?, minutes?, fixer = playerId? (a player fixer on duty), point?, name? }
exports("post", function(spec)
    if type(spec) ~= "table" then return nil, "invalid_spec" end
    local copy = M.copy(spec)
    copy.poster = nil
    log(("post requested by %s: site %s, fixer %s"):format(tostring(GetInvokingResource()), tostring(spec.site),
        tostring(spec.fixer)))
    return Svc:post(copy)
end)

-- cancel(ref, byPlayerId?): an open contract; with a player id, only its own poster may.
exports("cancel", function(ref, byPlayerId)
    local pid = byPlayerId ~= nil and M.playerId(byPlayerId) or nil
    if byPlayerId ~= nil and not pid then return nil, "invalid_player_id" end
    return Svc:cancelContract(ref, pid, GetInvokingResource())
end)

-- ---------------------------------------------------------------------------------------------
-- Operator / integrator (restricted: console, or ACL command.netrun.*)
-- ---------------------------------------------------------------------------------------------
local function reply(source, message)
    print("[rp_netrunner] " .. message)
    local pid = M.playerId(source)
    if pid then P.say(pid, message) end
end

local function argPlayer(source, value)
    local pid = M.playerId(value)
    if not pid or not P.players.name(pid) then
        reply(source, "unknown player id " .. tostring(value))
        return nil
    end
    return pid
end

RegisterCommand("netrun.status", function(source)
    local s = Svc.stats
    local n, doubts, sales, offers = 0, 0, 0, 0
    for _ in pairs(Svc.contracts) do n = n + 1 end
    for _ in pairs(Svc.doubts) do doubts = doubts + 1 end
    for _ in pairs(Svc.sales) do sales = sales + 1 end
    for _ in pairs(Svc.offers) do offers = offers + 1 end
    reply(source, ("ready=%s board=%s contracts=%d targets=%s | posted=%d taken=%d breaches=%d failures=%d deliveries=%d " ..
        "expired=%d cancelled=%d abandoned=%d traces=%d refusals=%d doubts=%d | breach doubts=%d sale doubts=%d offers=%d jam=%s")
        :format(tostring(Svc.ready), tostring(Svc.boardLoaded), n, tostring(Svc.targetCount), s.posted, s.taken, s.breaches,
        s.failures, s.deliveries, s.expired, s.cancelled, s.abandoned, s.traces, s.refusals, s.doubts, doubts, sales, offers,
        tostring(Qh:isJamming())))
    for _, c in ipairs(Svc:sorted()) do reply(source, M.line(c, Svc.sites[c.site], cfg.tiers[c.tier], P.nowS())) end
end, true)

-- netrun.setup <playerId> [netrunner|fixer] [grade 0-3]: the job + duty.
RegisterCommand("netrun.setup", function(source, args)
    local pid = argPlayer(source, args[1])
    if not pid then return end
    local job = args[2] == "fixer" and cfg.fixerJob or cfg.job
    local grade = math.max(0, math.min(3, M.integer(args[3]) or 0))
    local ok, why = P.jobs.setJob(pid, job, grade)
    reply(source, ("setJob %d %s %d: %s %s"):format(pid, job, grade, tostring(ok), tostring(why or "")))
    local on, dwhy = P.jobs.setDuty(pid, true, { job = job })
    reply(source, ("setDuty %d on: %s %s"):format(pid, tostring(on), tostring(dwhy or "")))
end, true)

-- netrun.give <playerId> <item> [count]: items into a player's pockets (rp_inventory addAsync).
RegisterCommand("netrun.give", function(source, args)
    local pid = argPlayer(source, args[1])
    if not pid then return end
    local item, n = args[2], M.integer(args[3] or "1") or 1
    if not item or not (cfg.items[item] or item == "chip") then return reply(source, "unknown item " .. tostring(item)) end
    CreateThread(function()
        local receipt, why = P.inventory.addAsync(pid, item, n, nil, { opId = L.newOpId("give") })
        reply(source, ("give %d %s to %d: %s %s"):format(n, item, pid, receipt and "ok" or "refused", tostring(why or "")))
    end)
end, true)

-- netrun.post <site> [reward] [minutes] [fixerPlayerId]
RegisterCommand("netrun.post", function(source, args)
    local fixer = args[4] and argPlayer(source, args[4]) or nil
    if args[4] and not fixer then return end
    CreateThread(function()
        local summary, why = Svc:post({ site = args[1], reward = args[2] and M.integer(args[2]),
            minutes = args[3] and M.integer(args[3]), fixer = fixer, name = fixer and nil or "console" })
        reply(source, summary and ("posted %s (%s) on %s reward %d cut %d deadline in %s"):format(summary.code, summary.id,
            summary.site, summary.reward, summary.cut, M.clock(summary.secondsLeft)) or ("post refused: " .. tostring(why)))
    end)
end, true)

-- netrun.take <playerId> <code>
RegisterCommand("netrun.take", function(source, args)
    local pid = argPlayer(source, args[1])
    if not pid then return end
    CreateThread(function()
        local summary, why = Svc:take(pid, args[2])
        reply(source, summary and ("player %d took %s"):format(pid, summary.code) or ("take refused: " .. tostring(why)))
    end)
end, true)

-- netrun.breach <playerId> [site]: the site prompt's request (the player must stand there).
RegisterCommand("netrun.breach", function(source, args)
    local pid = argPlayer(source, args[1])
    if not pid then return end
    local key = args[2] or siteNear(pid)
    if not key or not Svc.sites[key] then return reply(source, "no site " .. tostring(key)) end
    local op, why, info = P.actions.request(pid, "breach_" .. key, "site_" .. key)
    reply(source, op and ("breach %s: op %s state %s"):format(key, tostring(op.opId), tostring(op.state))
        or ("breach refused: %s (stage %s)"):format(tostring(why), tostring(info and info.stage)))
end, true)

-- netrun.talk <playerId> [fixerKey]: the fixer drop's prompt (board, or the delivery).
RegisterCommand("netrun.talk", function(source, args)
    local pid = argPlayer(source, args[1])
    if not pid then return end
    local key = args[2] or cfg.fixers[1].key
    local op, why = P.actions.request(pid, "talk", "fixer_" .. key)
    reply(source, op and ("talk %s: op %s"):format(key, tostring(op.opId)) or ("talk refused: " .. tostring(why)))
end, true)

-- netrun.deliver <playerId> [fixerPlayerId]: the drop at the fixer point, or the hand-over.
RegisterCommand("netrun.deliver", function(source, args)
    local pid = argPlayer(source, args[1])
    if not pid then return end
    CreateThread(function()
        if args[2] then
            local fixer = argPlayer(source, args[2])
            if not fixer then return end
            local o, why = Svc:handover(pid, fixer)
            reply(source, o and ("hand-over %s offered: the fixer accepts with Y on the offer card, or /interaction accept"):format(o.id)
                or ("hand-over refused: " .. tostring(why)))
            return
        end
        local op, why = P.actions.request(pid, "deliver", "fixer_" .. cfg.fixers[1].key)
        reply(source, op and ("deliver: op %s"):format(tostring(op.opId)) or ("deliver refused: " .. tostring(why)))
    end)
end, true)

-- netrun.expire <code>: the contract's deadline is now (the sweep expires it).
RegisterCommand("netrun.expire", function(source, args)
    local c = Svc:find(args[1] or "")
    if not c then return reply(source, "no contract " .. tostring(args[1])) end
    CreateThread(function()
        Svc:expire(c)
        reply(source, ("expire %s: %s"):format(c.code, Svc.contracts[c.id] and "still on the board" or "retired"))
    end)
end, true)

-- netrun.state <playerId>: contract, shard, kits, cash.
RegisterCommand("netrun.state", function(source, args)
    local pid = argPlayer(source, args[1])
    if not pid then return end
    CreateThread(function()
        local subject, why = L.subjectOf(pid)
        if not subject then return reply(source, "no subject: " .. tostring(why)) end
        local snap = L.read(L.pocketsOf(subject))
        local c = Svc:activeContract(subject)
        local shards = {}
        for iid, inst in pairs(type(snap) == "table" and snap.instances or {}) do
            if inst.item == "nr_data_shard" then shards[#shards + 1] = iid end
        end
        local cash = P.economy.balanceOf({ subject = subject })
        reply(source, ("player %d subject %s contract=%s state=%s chips=%d shards=[%s] cash=%s grade=%d"):format(pid, subject,
            c and c.code or "-", c and c.state or "-", L.available(snap, cfg.breach.item or "chip"), table.concat(shards, ","),
            tostring(type(cash) == "table" and cash.balance), Svc:gradeOf(pid)))
        if c then
            local site = Svc.sites[c.site]
            local tier = cfg.tiers[c.tier]
            reply(source, ("contract %s site %s tier %d chance now %d%% attempts %d traces %d reward %d cut %d"):format(c.code,
                c.site, c.tier, M.breachChance(tier, cfg.difficulty, Svc:gradeOf(pid), c.attempts), c.attempts or 0,
                c.traces or 0, c.reward, c.cut or 0))
            if site then reply(source, ("site %s at %.3f, %.3f, %.3f yaw %.2f"):format(site.key, site.position.x,
                site.position.y, site.position.z, site.yaw or 0)) end
        end
    end)
end, true)
