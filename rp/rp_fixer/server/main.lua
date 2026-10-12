-- rp_fixer / server/main.lua: wiring. The hooks open77_actions calls (exports), the public
-- exports, the boot order, the library and platform events, the player commands and the
-- operator's console commands.

local RESOURCE = GetCurrentResourceName()
local cfg, M, L, P, St = FixerConfig, FixerModel, FixerLedger, FixerPorts, FixerStore

local Svc = FixerService.new({ config = cfg, model = M, ledger = L, ports = P, store = St, resource = RESOURCE })
-- Inspection handle for the offline suite: a global of this VM only.
FixerRuntime = { service = Svc }

local function log(fmt, ...) print(("[rp_fixer] " .. fmt):format(...)) end

-- ---------------------------------------------------------------------------------------------
-- Hooks. A hook is an export NAME given to open77_actions; each one checks that its caller is
-- open77_actions (and the mutating ones `verify` the operation). validate is synchronous; the
-- others run asynchronously and may yield.
-- ---------------------------------------------------------------------------------------------
exports("fxBoard", function(ctx) return Svc:boardCommit(ctx) end)
exports("fxHandValidate", function(ctx) return Svc:handValidate(ctx) end)
exports("fxHandReserve", function(ctx) return Svc:handReserve(ctx) end)
exports("fxHandCommit", function(ctx) return Svc:handCommit(ctx) end)
exports("fxHandCancel", function(ctx) return Svc:handCancel(ctx) end)
exports("fxCrateValidate", function(ctx) return Svc:crateValidate(ctx) end)
exports("fxCratePickup", function(ctx) return Svc:cratePickup(ctx) end)
exports("fxCratePutdown", function(ctx) return Svc:cratePutdown(ctx) end)
exports("fxCrateDropped", function(ctx) return Svc:crateDropped(ctx) end)

-- ---------------------------------------------------------------------------------------------
-- Public exports (server)
-- ---------------------------------------------------------------------------------------------
-- reputation(playerId) -> integer score (0 when unknown). Synchronous, never yields.
exports("reputation", function(playerId)
    local pid = M.playerId(playerId)
    local p = pid and Svc.players[pid]
    local rep = p and Svc.reps[p.subject]
    return rep and rep.score or 0
end)

-- contract(idOrNumber) -> summary | nil. Synchronous.
exports("contract", function(ref) return M.summary(Svc:find(ref)) end)

-- heldBy(playerId) -> { summary, ... } of the contracts the player holds. Synchronous.
exports("heldBy", function(playerId)
    local pid = M.playerId(playerId)
    local p = pid and Svc.players[pid]
    local out = {}
    for _, c in ipairs(p and Svc:held(p.subject) or {}) do out[#out + 1] = M.summary(c) end
    return out
end)

-- postContract({ template, hub, reward? }) -> summary | nil, reason. Asynchronous (yields):
-- another resource posts a contract in a fixer NPC's name, funded like any NPC contract.
exports("postContract", function(spec)
    local caller = GetInvokingResource() or "?"
    if type(spec) ~= "table" then return nil, "invalid_spec" end
    local c, why = Svc:post({ template = spec.template, hub = spec.hub, kind = "npc", reward = spec.reward })
    log("postContract by %s: %s %s", caller, tostring(spec.template), c and c.id or tostring(why))
    if not c then return nil, why end
    return M.summary(c)
end)

-- ---------------------------------------------------------------------------------------------
-- Boot: the database, open77_actions, rp_economy and the coordinator, then the declarations,
-- the live contracts, the contacts and the players already connected.
-- ---------------------------------------------------------------------------------------------
local function waitFor(what, test, seconds)
    local waited, warned = 0, false
    while not test() do
        Wait(500)
        waited = waited + 0.5
        if waited >= (seconds or 30) and not warned then
            warned = true
            log("still waiting for %s (the board accepts nothing until then)", what)
        end
    end
end

local function boot()
    Svc:checkTemplates()
    local dbDone, dbProblem = false, nil
    local registered, why = St.init(function(ok, reason)
        dbDone, dbProblem = true, (not ok) and (reason or "schema_failed") or nil
    end)
    if not registered then
        log("no database (%s): contracts and reputation need SQL, the board stays closed", tostring(why))
        return
    end
    waitFor("the database", function() return dbDone end)
    if dbProblem then
        log("tables not created (%s): the board stays closed", tostring(dbProblem))
        return
    end
    waitFor("open77_actions", function() return P.running("open77_actions") end)
    waitFor("rp_economy", function() return P.running("rp_economy") end)
    waitFor("open77_transactions (ready)", function() return (L.ready()) end)
    local info = L.info()
    Svc.serverTag = (type(info) == "table" and type(info.serverTag) == "string" and info.serverTag ~= "") and info.serverTag or "srv"
    if not Svc:declare() then log("declarations refused by open77_actions (above): asked again when it restarts") end
    while true do
        local ok, lwhy = Svc:load()
        if ok then break end
        log("live contracts not loaded (%s): trying again in 5 s", tostring(lwhy))
        Wait(5000)
    end
    Svc:spawnContacts()
    for _, pid in ipairs(P.players.all()) do Svc:playerJoined(pid) end
    Svc.ready = true
    Svc.refillAt = P.now() + 10000
    local templates = 0
    for _ in pairs(Svc.templates) do templates = templates + 1 end
    log("ready: %d fixer points, %d templates, escrow society %s, cut society %s", #cfg.hubOrder, templates,
        cfg.escrowSociety, cfg.cutSociety)
end

CreateThread(function()
    local ok, err = pcall(boot)
    if not ok then log("boot failed: %s", tostring(err)) end
end)

CreateThread(function()
    while true do
        Wait(cfg.sweepMs)
        local ok, err = pcall(Svc.sweep, Svc)
        if not ok then log("sweep raised: %s", tostring(err)) end
    end
end)

CreateThread(function()
    while true do
        Wait(1000)
        if Svc.ready then
            local ok, err = pcall(Svc.engage, Svc)
            if not ok then log("engage raised: %s", tostring(err)) end
        end
    end
end)

-- ---------------------------------------------------------------------------------------------
-- Events
-- ---------------------------------------------------------------------------------------------
AddEventHandler("onPlayerReady", function(playerId)
    if not Svc.ready then return end
    CreateThread(function() Svc:playerJoined(tonumber(playerId)) end)
end)

AddEventHandler("onPlayerDisconnected", function(playerId) Svc:playerLeft(tonumber(playerId)) end)

-- open77_actions restarted: it forgot every definition, target and carry item.
AddEventHandler("open77_actions:ready", function()
    if not Svc.ready then return end
    CreateThread(function()
        Svc:declare()
        for id, rt in pairs(Svc.rt) do
            if rt.crate then Svc.crates[rt.crate] = nil; rt.crate = nil end
            local c = Svc.contracts[id]
            if c and c.crate then c.crate.carried = false end
        end
        for _, c in pairs(Svc.contracts) do Svc:materialize(c) end
        log("open77_actions restarted: board, drops and crates declared again")
    end)
end)

AddEventHandler("open77_actions:transition", function(op)
    if type(op) ~= "table" or op.owner ~= RESOURCE then return end
    if op.actionId == "board" and op.state == "committed" then
        local hub = type(op.receipt) == "table" and op.receipt.hub or nil
        CreateThread(function()
            local ok, err = pcall(Svc.openBoard, Svc, op.playerId, hub)
            if not ok then log("board for player %s raised: %s", tostring(op.playerId), tostring(err)) end
        end)
    elseif op.actionId == "handover" then
        if op.state == "committed" then
            local c = type(op.receipt) == "table" and Svc.contracts[op.receipt.contract or ""] or nil
            if c then
                Svc:tell(op.playerId, ("Handed over: %d x %s. The payout of %s is on its way."):format(c.want.count,
                    c.want.label or c.want.item, M.code(c)), "success")
            end
        elseif op.state == "failed" and op.stage == "reserve" then
            Svc:refuse(op.playerId, op.reason)
        end
    end
end)

AddEventHandler("open77_actions:carry", function(payload)
    if type(payload) ~= "table" or payload.owner ~= RESOURCE then return end
    CreateThread(function() Svc:onCarry(payload) end)
end)

-- Other jobs report their committed steps here (wave-3 convention):
-- TriggerEvent("rp:job:completed", { job, kind, playerId, ref, data })
AddEventHandler("rp:job:completed", function(payload)
    CreateThread(function()
        local ok, err = pcall(Svc.onJobCompleted, Svc, payload)
        if not ok then log("job event raised: %s", tostring(err)) end
    end)
end)

AddEventHandler("onNpcDamaged", function(npcId, source, amount) Svc:onNpcDamaged(npcId, source, amount) end)
AddEventHandler("onNpcDied", function(npcId, source, cause)
    CreateThread(function()
        local ok, err = pcall(Svc.onNpcDied, Svc, npcId, source, cause)
        if not ok then log("npc death raised: %s", tostring(err)) end
    end)
end)

AddEventHandler("onResourceStop", function(name)
    if name == RESOURCE then Svc:shutdown() end
end)

-- ---------------------------------------------------------------------------------------------
-- Player commands
-- ---------------------------------------------------------------------------------------------
local SUGGESTIONS = {
    { command = "/contracts", help = "Open the contract board (at a fixer point)" },
    { command = "/contract", help = "Your contracts: take, drop, cancel, box, post",
      parameters = { { name = "action", help = "take <n> | drop <n> | cancel <n> | box | post <template> <reward> [hours]" } } },
}

RegisterNetEvent("chat:ready", function() P.suggest(source, SUGGESTIONS) end)
AddEventHandler("onResourceStart", function(name)
    if name == RESOURCE then P.suggest(-1, SUGGESTIONS) end
end)

local function atHub(pid) return Svc:atHub(pid) end

RegisterCommand("contracts", function(source)
    local pid = M.playerId(source)
    if not pid then return log("/contracts is a player command; the console uses fixer.status and fixer.list") end
    if not Svc.ready then return Svc:refuse(pid, "not_ready") end
    CreateThread(function()
        local hub, nearest, d = atHub(pid)
        if hub then return Svc:openBoard(pid, hub) end
        Svc:chatBoard(pid)
        if nearest then
            Svc:tell(pid, ("Nearest fixer: %s (%s), %d m away."):format(cfg.hubs[nearest].label, cfg.hubs[nearest].fixer,
                math.floor(d or 0)), "info")
        end
    end)
end, false)

local function listMine(pid)
    local v = Svc:viewer(pid)
    if not v then return Svc:refuse(pid, "not_loaded") end
    local now, n = P.unix(), 0
    local _, tier = M.tierOf(v.score, cfg.tiers)
    Svc:tell(pid, ("Reputation %d (%s)."):format(v.score, tier.name), "info")
    for _, c in ipairs(Svc:held(v.subject)) do
        n = n + 1
        Svc:tell(pid, "Yours: " .. M.progressLine(c, cfg, now), "chat")
    end
    for _, c in ipairs(Svc:postedBy(v.subject)) do
        n = n + 1
        Svc:tell(pid, ("Posted: %s %s, %s%s."):format(M.code(c), c.title, c.state,
            c.runner and (" by " .. c.runner.name) or ""), "chat")
    end
    if n == 0 then Svc:tell(pid, "No contract. /contracts at a fixer point.", "info") end
end

RegisterCommand("contract", function(source, args)
    local pid = M.playerId(source)
    if not pid then return log("/contract is a player command") end
    if not Svc.ready then return Svc:refuse(pid, "not_ready") end
    local verb = args and args[1] or ""
    CreateThread(function()
        if verb == "" then return listMine(pid) end
        if verb == "take" then
            if not atHub(pid) then return Svc:refuse(pid, "too_far") end
            local c, why = Svc:take(pid, args[2])
            if not c then Svc:refuse(pid, why) end
        elseif verb == "drop" then
            local c, why = Svc:abandon(pid, args[2])
            if not c then Svc:refuse(pid, why) end
        elseif verb == "cancel" then
            local c, why = Svc:cancel(pid, args[2])
            if c then Svc:tell(pid, ("Contract %s cancelled: the refund is on its way."):format(M.code(c)), "info")
            else Svc:refuse(pid, why) end
        elseif verb == "box" then
            if not atHub(pid) then return Svc:refuse(pid, "too_far") end
            Svc:collectBox(pid)
        elseif verb == "post" then
            local hub = atHub(pid)
            if not hub then return Svc:refuse(pid, "too_far") end
            local c, why = Svc:post({ template = args[2], hub = hub, kind = "player", pid = pid,
                reward = tonumber(args[3]), hours = args[4] and tonumber(args[4]) or nil })
            if not c then
                if why == "escrow_pending" then return Svc:tell(pid, M.textFor(why), "info") end
                Svc:refuse(pid, why)
            end
        else
            Svc:tell(pid, "/contract [take <n> | drop <n> | cancel <n> | box | post <template> <reward> [hours]]", "info")
        end
    end)
end, false)

-- ---------------------------------------------------------------------------------------------
-- Operator commands (restricted: console, or ACL command.fixer.*)
-- ---------------------------------------------------------------------------------------------
local function reply(source, fmt, ...)
    local text = fmt:format(...)
    print("[rp_fixer] " .. text)
    local pid = M.playerId(source)
    if pid then pcall(Open77.chat.send, pid, { author = "FIXER", text = text }) end
end

RegisterCommand("fixer.status", function(source)
    local counts = {}
    for _, c in pairs(Svc.contracts) do counts[c.state] = (counts[c.state] or 0) + 1 end
    local parts = {}
    for state, n in pairs(counts) do parts[#parts + 1] = state .. "=" .. n end
    table.sort(parts)
    local s = Svc.stats
    reply(source, "ready=%s contracts: %s | posted=%d voided=%d taken=%d completed=%d refunded=%d abandoned=%d " ..
        "handovers=%d deliveries=%d jobEvents=%d kills=%d", tostring(Svc.ready), table.concat(parts, " "), s.posted,
        s.voided, s.taken, s.completed, s.refunded, s.abandoned, s.handovers, s.deliveries, s.jobEvents, s.kills)
    CreateThread(function()
        local held, balance, why = Svc:audit()
        reply(source, "escrow: contracts hold %d, soc:%s balance %s%s", held, cfg.escrowSociety, tostring(balance),
            why and (" (" .. tostring(why) .. ")") or "")
    end)
end, true)

RegisterCommand("fixer.list", function(source)
    local list = {}
    for _, c in pairs(Svc.contracts) do list[#list + 1] = c end
    table.sort(list, function(a, b) return a.seq < b.seq end)
    local now = P.unix()
    for _, c in ipairs(list) do
        local rt = Svc.rt[c.id] or {}
        reply(source, "%s %s %s %s at %s reward=%d net=%d cut=%d poster=%s runner=%s left=%s%s%s", M.code(c), c.id, c.state,
            c.template, c.hub, c.reward, c.net, c.cut, c.poster.subject or ("npc:" .. tostring(c.poster.name)),
            c.runner and c.runner.subject or "-", M.duration(c.expiresAt - now),
            rt.crate and (" crate=" .. rt.crate) or "", rt.npc and (" npc=" .. tostring(rt.npc)) or "")
    end
    if #list == 0 then reply(source, "no contract") end
end, true)

-- fixer.post <template> [hub] [reward]: a fixer NPC posts now.
RegisterCommand("fixer.post", function(source, args)
    local template = args[1]
    local t = template and cfg.templates[template]
    if not t then return reply(source, "usage: fixer.post <template> [hub] [reward]") end
    local hub = args[2]
    if not hub then
        for _, key in ipairs(cfg.hubOrder) do
            for _, id in ipairs(cfg.hubs[key].offers or {}) do if id == template then hub = key end end
        end
        hub = hub or cfg.hubOrder[1]
    end
    CreateThread(function()
        local c, why = Svc:post({ template = template, hub = hub, kind = "npc", reward = tonumber(args[3]) })
        reply(source, "post %s at %s: %s", template, hub, c and (M.code(c) .. " " .. c.id .. " " .. c.state) or tostring(why))
    end)
end, true)

-- fixer.expire <n>: the contract runs out now (the next sweep refunds it).
RegisterCommand("fixer.expire", function(source, args)
    local c = Svc:find(args[1])
    if not c then return reply(source, "usage: fixer.expire <number>") end
    CreateThread(function()
        local ok, why = Svc:withLock(c.id, function()
            return Svc:change(c, function(x) x.expiresAt = P.unix() end)
        end)
        reply(source, "%s expires now: %s", M.code(c), ok and "yes" or tostring(why))
    end)
end, true)

-- fixer.job <playerId> <job> <kind> [count] [ref]: the event another job fires (lab check of a
-- job order without running that job).
RegisterCommand("fixer.job", function(source, args)
    local pid = M.playerId(args[1])
    if not pid or not args[2] or not args[3] then return reply(source, "usage: fixer.job <playerId> <job> <kind> [count] [ref]") end
    local ref = args[5] or ("lab:" .. L.newOpId("lab"))
    TriggerEvent("rp:job:completed", { job = args[2], kind = args[3], playerId = pid, ref = ref,
        data = { count = tonumber(args[4]) or 1 } })
    reply(source, "rp:job:completed %s/%s for player %d ref %s", args[2], args[3], pid, ref)
end, true)

-- fixer.kill <n> <playerId>: the bounty's cyberpsycho dies credited to that player (the same
-- path as a real onNpcDied naming "player:<id>"); lab only.
RegisterCommand("fixer.kill", function(source, args)
    local c = Svc:find(args[1])
    local pid = M.playerId(args[2])
    local rt = c and Svc.rt[c.id]
    if not c or not pid then return reply(source, "usage: fixer.kill <number> <playerId>") end
    if not rt or not rt.npc then return reply(source, "%s has no cyberpsycho out", M.code(c)) end
    CreateThread(function()
        Svc:onNpcDied(tostring(rt.npc), "player:" .. pid, "lab")
        reply(source, "%s cyberpsycho killed by player %d", M.code(c), pid)
    end)
end, true)

-- fixer.setrep <playerId> <score>: an operator sets a connected player's reputation (one keyed
-- change, written like any other).
RegisterCommand("fixer.setrep", function(source, args)
    local pid = M.playerId(args[1])
    local score = M.int(args[2])
    local p = pid and Svc.players[pid]
    if not p or not score or score < 0 then return reply(source, "usage: fixer.setrep <playerId> <score>") end
    CreateThread(function()
        local rep = Svc.reps[p.subject] or { score = 0 }
        local result, why = Svc:reputation(p.subject, ("admin:%s:%d"):format(p.subject, P.now()), score - rep.score, 0, 0)
        local now = Svc.reps[p.subject]
        reply(source, "player %d reputation %s: %s", pid, tostring(now and now.score), tostring(result or why))
    end)
end, true)

-- fixer.rep <playerId>: the player's reputation.
RegisterCommand("fixer.rep", function(source, args)
    local pid = M.playerId(args[1])
    local p = pid and Svc.players[pid]
    local rep = p and Svc.reps[p.subject]
    if not rep then return reply(source, "usage: fixer.rep <playerId> (a connected player)") end
    local _, tier = M.tierOf(rep.score, cfg.tiers)
    reply(source, "player %d %s reputation %d (%s) completed %d failed %d", pid, p.subject, rep.score, tier.name,
        rep.completed, rep.failed)
end, true)
