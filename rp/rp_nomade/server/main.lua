-- rp_nomade / server/main.lua: wiring. The hooks open77_actions calls (exports), the boot order,
-- the library and platform events, the player command and the integrator's console commands.

local RESOURCE = GetCurrentResourceName()
local cfg, M, L, P = NomadConfig, NomadModel, NomadLedger, NomadPorts

local Svc = NomadService.new({ config = cfg, model = M, ledger = L, ports = P, resource = RESOURCE })
-- Inspection handle for the offline suite: a global of this VM only.
NomadRuntime = { service = Svc }

local function log(line) print("[rp_nomade] " .. line) end

-- ---------------------------------------------------------------------------------------------
-- Hooks. A hook is an export NAME given to open77_actions; each checks its caller is
-- open77_actions (and the mutating ones `verify` the operation).
-- ---------------------------------------------------------------------------------------------
exports("nmdValidate", function(ctx) return Svc:validate(ctx) end)
exports("nmdReserve", function(ctx) return Svc:reserveTake(ctx) end)
exports("nmdCommit", function(ctx) return Svc:commitTake(ctx) end)
exports("nmdCancel", function(ctx) return Svc:cancelTake(ctx) end)
exports("nmdUnload", function(ctx) return Svc:unloadAction(ctx) end)
exports("nmdSearchReserve", function(ctx) return Svc:searchReserve(ctx) end)
exports("nmdSearchCommit", function(ctx) return Svc:searchCommit(ctx) end)
exports("nmdSearchCancel", function(ctx) return Svc:searchCancel(ctx) end)
exports("crateValidate", function(ctx) return Svc:crateValidate(ctx) end)
exports("cratePickup", function(ctx) return Svc:cratePickup(ctx) end)
exports("cratePutdown", function(ctx) return Svc:cratePutdown(ctx) end)
exports("crateDropped", function(ctx) return Svc:crateDropped(ctx) end)

-- Public, synchronous, never yield.
exports("activeRun", function(playerId)
    local pid = M.playerId(playerId)
    if not pid then return nil end
    return Svc:runSummary(Svc.subjectOfPid[pid])
end)
exports("hasRun", function(playerId)
    local pid = M.playerId(playerId)
    local run = pid and Svc.subjectOfPid[pid] and Svc:activeRunOf(Svc.subjectOfPid[pid])
    return run ~= nil and not run.failed
end)

-- The rp_nomade 1.x names, kept for the resources that call them (rp_crime): the same run, in the
-- 1.x shape. `status` is "active" while the run is live.
exports("activeContract", function(playerId)
    local pid = M.playerId(playerId)
    local subject = pid and Svc.subjectOfPid[pid]
    local summary = subject and Svc:runSummary(subject)
    if not summary then return nil end
    local loaded, carrying = 0, 0
    for _, where in ipairs(summary.where) do
        if where:find("^truck") then loaded = loaded + 1 elseif where == "carried" then carrying = carrying + 1 end
    end
    local route = Svc.routes[summary.route]
    return { id = summary.run, template = summary.route, label = route and route.label or summary.route,
             destination = summary.route, crates = summary.crates, loaded = loaded,
             delivered = summary.delivered + summary.sold, carrying = carrying,
             status = summary.failed and summary.failed or "active", truckId = nil, ambushed = false }
end)
exports("hasContract", function(playerId)
    local pid = M.playerId(playerId)
    local run = pid and Svc.subjectOfPid[pid] and Svc:activeRunOf(Svc.subjectOfPid[pid])
    return run ~= nil and not run.failed
end)

-- ---------------------------------------------------------------------------------------------
-- Boot: the coordinator ready, then items, stashes, open77_containers, actions, crates.
-- This resource ships a client script, so the server-only libraries cannot be manifest
-- dependencies: the boot waits for them instead.
-- ---------------------------------------------------------------------------------------------
local function waitFor(what, test, seconds)
    local waited, warned = 0, false
    while not test() do
        Wait(500)
        waited = waited + 0.5
        if waited >= (seconds or 30) and not warned then
            warned = true
            log(("still waiting for %s (the camp accepts nothing until then)"):format(what))
        end
    end
end

-- open77_containers answers `not_ready` to every create until its boot join is done (and its
-- `open77_containers:ready` is missed when it was up first). A spec it must refuse is the probe:
-- `not_ready` before the join, a spec refusal after it, and nothing is ever created.
local function containersReady()
    if not P.running("open77_containers") then return false end
    local _, why = P.containers.create({ kind = "probe" })
    return why ~= "not_ready" and why ~= "open77_containers_unavailable"
end

local function boot()
    waitFor("open77_transactions (ready)", function() return (L.ready()) end)
    waitFor("open77_actions", function() return P.running("open77_actions") end)
    waitFor("open77_containers", function() return P.running("open77_containers") end)
    waitFor("rp_cargo", function() return P.running("rp_cargo") end)
    local info = L.info()
    log(("coordinator ready (store=%s)"):format(tostring(info and info.store)))
    if info and info.store ~= "sql" then
        log("WARNING: the coordinator runs the DISPOSABLE lab store: nothing here survives a lab reset")
    end
    Svc:defineItems()
    waitFor("the camp's stashes (writers: rp_nomade stash)", function() return (Svc:openStashes()) end)
    waitFor("open77_containers (ready)", containersReady)
    Svc.containersUp = true
    Svc:declare()
    Svc:loadCrates()
    Svc:spawnFences()
    Svc:dressCamp()
    Svc.ready = true
    for _, pid in ipairs(P.players.all()) do Svc:onPlayerReady(pid) end
    log(("ready: %d route(s), %d checkpoint(s), board, truck bay, stash (job %s)"):format(#cfg.routes,
        #cfg.checkpoints, cfg.job))
end

CreateThread(function()
    local ok, err = pcall(boot)
    if not ok then log("boot failed: " .. tostring(err)) end
end)

CreateThread(function()
    while true do
        Wait(cfg.tickMs)
        local ok, err = pcall(Svc.tick, Svc)
        if not ok then log("tick raised: " .. tostring(err)) end
    end
end)

CreateThread(function()
    while true do
        Wait(cfg.sweepMs)
        local ok, err = pcall(Svc.sweep, Svc)
        if not ok then log("sweep raised: " .. tostring(err)) end
    end
end)

-- ---------------------------------------------------------------------------------------------
-- Library and platform events
-- ---------------------------------------------------------------------------------------------
AddEventHandler("open77_actions:ready", function()
    if not Svc.ready then return end
    CreateThread(function()
        Svc:declare()
        Svc:reproject()
        log("open77_actions restarted: actions declared again, ground crates re-placed")
    end)
end)

AddEventHandler("open77_actions:transition", function(op)
    if type(op) ~= "table" or op.owner ~= RESOURCE then return end
    CreateThread(function() Svc:onTransition(op) end)
end)

AddEventHandler("open77_containers:ready", function()
    Svc.containersUp = true
    if not Svc.ready then return end
    CreateThread(function() Svc:loadCrates() end)
end)

AddEventHandler("open77_transactions:ready", function()
    if not Svc.ready then return end
    CreateThread(function()
        Svc:defineItems()
        Svc:openStashes()
    end)
end)

AddEventHandler("onPlayerReady", function(pid)
    if not Svc.ready then return end
    CreateThread(function() Svc:onPlayerReady(pid) end)
end)

AddEventHandler("onPlayerDisconnected", function(pid)
    Svc:onPlayerGone(M.playerId(pid))
end)

AddEventHandler("onPlayerInteractionCompleted", function(state)
    if type(state) ~= "table" then return end
    CreateThread(function()
        if not Svc:onOfferEnded(state, true) then Svc:onSearchConsent(state, true) end
    end)
end)

AddEventHandler("onPlayerInteractionCancelled", function(state)
    if type(state) ~= "table" then return end
    CreateThread(function()
        if not Svc:onOfferEnded(state, false) then Svc:onSearchConsent(state, false) end
    end)
end)

AddEventHandler("rp_garage:despawned", function(plate, vehicleId, reason)
    if not Svc.ready or type(plate) ~= "string" then return end
    CreateThread(function() Svc:onDespawned(plate, reason) end)
end)

AddEventHandler("onResourceStart", function(name)
    if name == "rp_inventory" and Svc.ready then CreateThread(function() Svc:defineItems() end) end
end)

AddEventHandler("onResourceStop", function(name)
    if name == RESOURCE then Svc:shutdown() end
end)

-- The client asks for its navigation after a reload.
RegisterNetEvent("rp_nomade:clientReady", function()
    local pid = M.playerId(source)
    if not pid or not Svc.ready then return end
    CreateThread(function()
        local subject = Svc:trackPlayer(pid)
        if subject then Svc:pushNav(subject, true) end
    end)
end)

-- ---------------------------------------------------------------------------------------------
-- Commands
-- ---------------------------------------------------------------------------------------------
local function reply(source, message)
    print("[rp_nomade] " .. message)
    local pid = M.playerId(source)
    if pid then pcall(Open77.chat.send, pid, { author = cfg.ui.author, text = message, color = cfg.ui.color }) end
end

local function argPlayer(source, value)
    local pid = M.playerId(value)
    if not pid or not P.players.name(pid) then
        reply(source, "unknown player id " .. tostring(value))
        return nil
    end
    return pid
end

local function playerLoad(pid)
    if not P.actions.carrying(pid) then return Svc:refuseTo(pid, "not_carrying") end
    local vid, why = Svc:truckNear(pid, P.players.position(pid), cfg.truckNearM, "put")
    if not vid then return Svc:refuseTo(pid, why) end
    local op, reason = P.actions.carryPutdown(pid, { kind = "vehicle", vehicleId = vid, offset = { x = 0.0, y = -1.5, z = 1.0 } })
    if not op then Svc:refuseTo(pid, reason) end
end

local function playerUnload(pid)
    if P.actions.carrying(pid) then return Svc:refuseTo(pid, "carrying") end
    local crate, itemOrWhy = Svc:unloadCrate(pid, nil, P.players.position(pid), cfg.truckNearM, nil)
    if not crate then return Svc:refuseTo(pid, itemOrWhy) end
    if itemOrWhy then
        local op, reason = P.actions.carryPickup(pid, itemOrWhy)
        if not op then Svc:refuseTo(pid, reason) end
    end
end

local function statusLines(pid)
    local summary = Svc:runSummary(Svc:subjectOf(pid))
    if not summary then return { "No run going. The contracts board is at the Aldecaldos camp (/nomad camp)." } end
    local route = Svc.routes[summary.route]
    local lines = {
        ("Run to %s: %d of %d crate(s) still carry goods."):format(route and route.destination.label or summary.route,
            summary.left, summary.crates),
    }
    if summary.failed then
        lines[#lines + 1] = ("The run is off (%s)."):format(summary.failed)
    else
        lines[#lines + 1] = ("Time left: %d min."):format(M.minutesLeft(summary.deadline, P.now()))
    end
    lines[#lines + 1] = "Crates: " .. table.concat(summary.where, ", ") .. "."
    lines[#lines + 1] = ("Delivered %d, sold %d, seized %d, returned %d."):format(summary.delivered, summary.sold,
        summary.seized, summary.returned)
    return lines
end

RegisterCommand("nomad", function(source, args)
    local pid = M.playerId(source)
    if not pid then return print("[rp_nomade] /nomad is a player command; the console uses nomad.*") end
    local verb = args and args[1] or ""
    if not Svc.ready then return Svc:tell(pid, M.textFor("nomad_unavailable"), "warning") end
    if verb == "load" then
        CreateThread(function() playerLoad(pid) end)
    elseif verb == "unload" then
        CreateThread(function() playerUnload(pid) end)
    elseif verb == "status" then
        CreateThread(function() for _, line in ipairs(statusLines(pid)) do Svc:tell(pid, line, "info") end end)
    elseif verb == "sell" then
        CreateThread(function()
            local o, why = Svc:offerCrate(pid, args[2], args[3])
            if not o then Svc:refuseTo(pid, why) end
        end)
    elseif verb == "search" then
        CreateThread(function()
            local res, why = Svc:requestSearch(pid)
            if not res then Svc:refuseTo(pid, why) end
        end)
    elseif verb == "camp" then
        local pos = P.players.position(pid)
        local camp = cfg.camp.position
        local d = pos and M.planar(pos, camp)
        Svc:tell(pid, ("%s: %.0f, %.0f (z %.0f)%s."):format(cfg.camp.label, camp.x, camp.y, camp.z,
            d and (", %.0f m %s of you"):format(d, M.compass(pos, camp)) or ""), "info")
    else
        Svc:tell(pid, "Nomad runs: take one at the camp's board (E), carry the crates (E / G), load them at the truck bay " ..
            "or /nomad load next to your truck, drive, /nomad unload or the unload bay at the drop, hand the crate to the " ..
            "fence. /nomad status, /nomad sell <id> <price> (a crate on the ground next to you), /nomad camp. " ..
            "NCPD: /nomad search next to a truck.", "info")
    end
end, false)

-- Operator / integrator (restricted: console, or ACL command.nomad.*). Explicit player ids; each
-- drives the same server path as the prompts.
RegisterCommand("nomad.status", function(source)
    CreateThread(function()
        local s = Svc.stats
        local runs, live = 0, 0
        for _, run in pairs(Svc.runs) do
            runs = runs + 1
            if not run.ended and not run.failed then live = live + 1 end
        end
        local states = {}
        for _, crate in pairs(Svc.crates) do states[crate.state or "?"] = (states[crate.state or "?"] or 0) + 1 end
        local parts = {}
        for k, v in pairs(states) do parts[#parts + 1] = k .. "=" .. v end
        table.sort(parts)
        reply(source, ("ready=%s stash=%d runs=%d live=%d crates{%s} takes=%d loads=%d unloads=%d deliveries=%d hot=%d " ..
            "playerSales=%d returns=%d seized=%d passes=%d retired=%d reclaimed=%d restocks=%d refusals=%d")
            :format(tostring(Svc.ready), (Svc:stockOf()), runs, live, table.concat(parts, " "), s.takes, s.loads, s.unloads,
            s.deliveries, s.hot, s.playerSales, s.returns, s.seized, s.passes, s.retired, s.reclaimed, s.restocks, s.refusals))
        for key, run in pairs(Svc.runs) do
            if not run.ended then
                reply(source, ("run %s owner=%s route=%s left=%d failed=%s minutes=%d"):format(key, tostring(run.owner),
                    tostring(run.route), Svc:goodsLeft(run), tostring(run.failed), M.minutesLeft(run.deadline, P.now())))
            end
        end
    end)
end, true)

-- nomad.stock <count>: the camp's stash gets goods (mint from the supplier: a mint rule caps it).
RegisterCommand("nomad.stock", function(source, args)
    CreateThread(function()
        local receipt, why = Svc:stock(args[1])
        reply(source, receipt and ("stash +%s: now %d"):format(tostring(args[1]), (Svc:stockOf()))
            or ("stock refused: " .. tostring(why)))
    end)
end, true)

-- nomad.op.setup <playerId> [nomade|ncpd]: job grade 0 + duty.
RegisterCommand("nomad.op.setup", function(source, args)
    local pid = argPlayer(source, args[1])
    if not pid then return end
    local job = args[2] == "ncpd" and cfg.policeJob or cfg.job
    local ok, why = P.jobs.setJob(pid, job, 0)
    reply(source, ("setJob %d %s: %s %s"):format(pid, job, tostring(ok), tostring(why or "")))
    local on, dwhy = P.jobs.setDuty(pid, true, { job = job })
    reply(source, ("setDuty %d on: %s %s"):format(pid, tostring(on), tostring(dwhy or "")))
end, true)

-- nomad.op.truck <playerId> [plate]: a plated, owned Mackinaw next to the player.
RegisterCommand("nomad.op.truck", function(source, args)
    local pid = argPlayer(source, args[1])
    if not pid then return end
    if args[2] then
        local id, why = P.garage.spawnOwned(pid, args[2])
        reply(source, id and ("plate %s out as vehicle %s next to player %d"):format(args[2], tostring(id), pid)
            or ("spawnOwned refused: %s"):format(tostring(why)))
        return
    end
    local res, why = P.garage.labIssue(pid, "Vehicle.v_standard3_thorton_mackinaw_player", { label = "Convoy truck" })
    if type(res) == "table" then
        reply(source, ("issued plate %s vehicle %s to player %d"):format(tostring(res.plate), tostring(res.vehicleId), pid))
    else
        reply(source, ("labIssue refused: %s (rp_garage_lab 1 on a lab server; otherwise buy a Mackinaw at the " ..
            "dealership and run nomad.op.truck %d <plate>)"):format(tostring(why), pid))
    end
end, true)

-- nomad.op.take <playerId> <route>: the board prompt's request.
RegisterCommand("nomad.op.take", function(source, args)
    local pid = argPlayer(source, args[1])
    if not pid then return end
    local route = args[2] or (cfg.routes[1] and cfg.routes[1].id)
    local op, why, info = P.actions.request(pid, "run_" .. tostring(route), "board")
    reply(source, op and ("take %s: op %s state %s"):format(tostring(route), tostring(op.opId), tostring(op.state))
        or ("take refused: %s (stage %s)"):format(tostring(why), tostring(info and info.stage)))
end, true)

-- nomad.op.pickup <playerId>: lifts the nearest camp crate on the ground within 3 m.
RegisterCommand("nomad.op.pickup", function(source, args)
    local pid = argPlayer(source, args[1])
    if not pid then return end
    local pos = P.players.position(pid)
    local best, bestD
    for _, crate in pairs(Svc.crates) do
        if crate.state == "ground" and crate.itemId then
            local d = M.distance(pos, crate.position) or 99
            if d <= 3.0 and (not bestD or d < bestD) then best, bestD = crate, d end
        end
    end
    if not best then return reply(source, "no crate within 3 m") end
    local op, why = P.actions.carryPickup(pid, best.itemId)
    reply(source, op and ("pickup of %s: op %s"):format(best.id, tostring(op.opId)) or ("pickup refused: " .. tostring(why)))
end, true)

-- nomad.op.load <playerId>: the carried crate onto the nearest truck the player holds a key for.
RegisterCommand("nomad.op.load", function(source, args)
    local pid = argPlayer(source, args[1])
    if not pid then return end
    CreateThread(function() playerLoad(pid) end)
end, true)

-- nomad.op.unload <playerId>: the top camp crate of the nearest truck into the player's hands.
RegisterCommand("nomad.op.unload", function(source, args)
    local pid = argPlayer(source, args[1])
    if not pid then return end
    CreateThread(function() playerUnload(pid) end)
end, true)

-- nomad.op.deliver <playerId> [route]: puts the carried crate down at that route's fence.
RegisterCommand("nomad.op.deliver", function(source, args)
    local pid = argPlayer(source, args[1])
    if not pid then return end
    local route = Svc.routes[args[2] or ""] or cfg.routes[1]
    local f = route.destination.fence
    local op, why = P.actions.carryPutdown(pid, { kind = "point", position = f.position, yaw = f.yaw },
        { data = { intent = "fence", route = route.id } })
    reply(source, op and ("delivery put-down: op %s"):format(tostring(op.opId)) or ("delivery refused: " .. tostring(why)))
end, true)

-- nomad.op.checkpoint <playerId> <checkpoint> [search|pass]: the player's truck "enters" that
-- checkpoint now (no 4 km drive). Without the third word the run's own roll decides.
RegisterCommand("nomad.op.checkpoint", function(source, args)
    local pid = argPlayer(source, args[1])
    if not pid then return end
    local ck = Svc.checkpoints[args[2] or ""]
    if not ck then return reply(source, "unknown checkpoint " .. tostring(args[2])) end
    CreateThread(function()
        local run = Svc:activeRunOf(Svc:subjectOf(pid))
        if not run then return reply(source, "player " .. pid .. " has no run") end
        local plate
        for _, id in pairs(run.crates) do
            local crate = Svc.crates[id]
            if crate and crate.state == "truck" and (crate.goods or 0) > 0 then plate = crate.plate end
        end
        if not plate then return reply(source, "no goods of that run in a truck") end
        local force = (args[3] == "search" or args[3] == "pass") and args[3] or nil
        local started = Svc:enterCheckpoint(run, ck, plate, Svc:vehicleOfPlate(plate), force)
        reply(source, started and ("run %s enters %s (%s, roll %d vs %d)"):format(run.key, ck.id, force or "roll",
            M.searchRoll(run.key, ck.id), ck.searchChance) or ("run %s already went through %s"):format(run.key, ck.id))
    end)
end, true)

-- nomad.op.expire <playerId>: the player's run is past its deadline now (memory only: a
-- restart brings the real deadline back).
RegisterCommand("nomad.op.expire", function(source, args)
    local pid = argPlayer(source, args[1])
    if not pid then return end
    local run = Svc:activeRunOf(Svc:subjectOf(pid))
    if not run then return reply(source, "player " .. pid .. " has no run") end
    run.deadline = P.now() - 1
    reply(source, ("run %s: deadline moved to now"):format(run.key))
end, true)

-- nomad.op.search <playerId>: /nomad search for that officer.
RegisterCommand("nomad.op.search", function(source, args)
    local pid = argPlayer(source, args[1])
    if not pid then return end
    CreateThread(function()
        local res, why = Svc:requestSearch(pid)
        reply(source, res and ("search: %s"):format(res.pending and ("waiting for consent " .. res.pending)
            or ("op " .. tostring(res.opId))) or ("search refused: " .. tostring(why)))
    end)
end, true)

-- nomad.op.sell <seller> <buyer> <price>: /nomad sell for that seller.
RegisterCommand("nomad.op.sell", function(source, args)
    local pid = argPlayer(source, args[1])
    if not pid then return end
    CreateThread(function()
        local o, why = Svc:offerCrate(pid, args[2], args[3])
        reply(source, o and ("offer %s (sale %s)"):format(o.id, o.opId) or ("offer refused: " .. tostring(why)))
    end)
end, true)
