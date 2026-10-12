-- rp_chooh2 / server/main.lua: wiring. The hooks open77_actions calls (exports), the boot order,
-- the library events, the player command and the operator's console commands.

local RESOURCE = GetCurrentResourceName()
local cfg, M, L, P = Chooh2Config, Chooh2Model, Chooh2Ledger, Chooh2Ports

local Svc = Chooh2Service.new({ config = cfg, model = M, ledger = L, ports = P, resource = RESOURCE })
-- Inspection handle for the offline suite: a global of this VM only.
Chooh2Runtime = { service = Svc }

local function log(line) print("[rp_chooh2] " .. line) end

-- ---------------------------------------------------------------------------------------------
-- Hooks. A hook is an export NAME given to open77_actions; any resource can call an export, so
-- each one checks that its caller is open77_actions (and the mutating ones also `verify` the
-- operation). validate is synchronous; the others run asynchronously and may yield.
-- ---------------------------------------------------------------------------------------------
exports("ch2Validate", function(ctx) return Svc:validate(ctx) end)
exports("ch2Reserve", function(ctx) return Svc:reserve(ctx) end)
exports("ch2Commit", function(ctx) return Svc:commit(ctx) end)
exports("ch2Cancel", function(ctx) return Svc:cancel(ctx) end)
exports("ch2Inspect", function(ctx) return Svc:inspect(ctx) end)
exports("ch2Gauges", function(ctx) return Svc:gauges(ctx) end)
exports("ch2Duty", function(ctx) return Svc:duty(ctx) end)
exports("ch2Unload", function(ctx) return Svc:unloadAction(ctx) end)
exports("ch2Sell", function(ctx) return Svc:sell(ctx) end)
exports("ch2CrateValidate", function(ctx) return Svc:crateValidate(ctx) end)
exports("ch2CratePickup", function(ctx) return Svc:cratePickup(ctx) end)
exports("ch2CratePutdown", function(ctx) return Svc:cratePutdown(ctx) end)
exports("ch2CrateDropped", function(ctx) return Svc:crateDropped(ctx) end)

-- ---------------------------------------------------------------------------------------------
-- Boot: the coordinator ready, then items, stashes, rows, actions, crates. Nothing before.
-- ---------------------------------------------------------------------------------------------
local function waitFor(what, test, seconds)
    local waited, warned = 0, false
    while not test() do
        Wait(500)
        waited = waited + 0.5
        if waited >= (seconds or 30) and not warned then
            warned = true
            log(("still waiting for %s (nothing is accepted until then)"):format(what))
        end
    end
end

-- rp_jobs refuses a requirement naming a job it does not know (`unknown_job`) before it looks at
-- the player: a probe with no player tells whether the configured jobs exist.
local function checkJobs()
    local names, seen = {}, {}
    local function add(job) if type(job) == "string" and not seen[job] then seen[job] = true names[#names + 1] = job end end
    add(cfg.jobs.harvest)
    add(cfg.jobs.refine)
    for _, job in ipairs(type(cfg.jobs.haul) == "table" and cfg.jobs.haul or { cfg.jobs.haul }) do add(job) end
    local missing = {}
    for _, job in ipairs(names) do
        local _, why = P.jobs.eligible(0, { job = job })
        if why == "unknown_job" then missing[#missing + 1] = job end
    end
    if #missing > 0 then
        log(("WARNING: rp_jobs has no job %s: add it to rp_jobs/shared/config.lua or map the role in " ..
            "server/config.lua (C.jobs); those steps answer unknown_job until then"):format(table.concat(missing, ", ")))
    end
    return #missing
end

local function boot()
    waitFor("open77_transactions (ready)", function() return (L.ready()) end)
    waitFor("open77_actions", function() return P.running("open77_actions") end)
    waitFor("open77_containers", function() return P.running("open77_containers") end)
    local info = L.info()
    log(("coordinator ready (store=%s)"):format(tostring(info and info.store)))
    if info and info.store ~= "sql" then
        log("WARNING: the coordinator runs its disposable store: nothing here survives its reset")
    end
    if P.running("rp_inventory") then
        local backend = P.inventory.backend()
        if backend ~= "transactions" then
            log(("WARNING: rp_inventory backend is %s; canisters in pockets are invisible to the coordinator " ..
                "until rp_inventory_backend is transactions"):format(tostring(backend)))
        end
    end
    Svc:defineItems()
    checkJobs()
    if not P.running("open77_fuel") then
        log("open77_fuel is not running: refuelling answers fuel_unavailable until it does")
    end
    Svc:openStashes()
    waitFor("open77_containers (ready)", function()
        local done, why = Svc:loadNodes()
        return done or not Svc:nodesTransient(why)
    end)
    local missing = 0
    for _, node in pairs(Svc.nodes) do if not node.id then missing = missing + 1 end end
    if missing > 0 then
        log(("WARNING: %d of %d corn rows unavailable (reasons above); asked for again every 30 s")
            :format(missing, #cfg.nodes))
    end
    Svc:declare()
    Svc:loadCrates()
    Svc:spawnClerk()
    Svc.ready = true
    local rows = missing == 0 and tostring(#cfg.nodes) or ("%d of %d"):format(#cfg.nodes - missing, #cfg.nodes)
    log(("ready: %s corn rows, farm office and bay, refinery (intake %s, control, rack), depot, pump"):format(rows,
        Svc.stashesOpen and "open" or "NOT open"))
end

CreateThread(function()
    local ok, err = pcall(boot)
    if not ok then log("boot failed: " .. tostring(err)) end
end)

CreateThread(function()
    while true do
        Wait(cfg.sweepMs)
        local ok, err = pcall(Svc.sweep, Svc)
        if not ok then log("sweep raised: " .. tostring(err)) end
    end
end)

-- ---------------------------------------------------------------------------------------------
-- Library events
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
    CreateThread(function()
        local done, why = Svc:loadNodes()
        if not done then log(("open77_containers is back, rows not all found yet (%s)"):format(tostring(why))) end
        for _, node in pairs(Svc.nodes) do Svc:refreshNodeTarget(node, true) end
        for ref, nodeId in pairs(Svc.pendingConsume) do Svc:consumeNode(nodeId, ref) end
    end)
end)

local function nodeEvent(id)
    local key = Svc.nodeById[id]
    if key and Svc.ready then Svc:refreshNodeTarget(Svc.nodes[key]) end
end
AddEventHandler("open77_containers:depleted", nodeEvent)
AddEventHandler("open77_containers:regrown", nodeEvent)
AddEventHandler("open77_containers:closed", function(id, reason, owner)
    if owner == RESOURCE then Svc:onContainerClosed(id, reason) end
end)

AddEventHandler("onResourceStart", function(name)
    if name == "rp_inventory" and Svc.ready then
        CreateThread(function() Svc:defineItems() end)
    end
end)

AddEventHandler("onResourceStop", function(name)
    if name == RESOURCE then
        Svc:shutdown()
    elseif name == "open77_containers" then
        Svc:containersStopped()
    end
end)

-- ---------------------------------------------------------------------------------------------
-- Commands
-- ---------------------------------------------------------------------------------------------
local function reply(source, message)
    print("[rp_chooh2] " .. message)
    local pid = M.playerId(source)
    if pid then pcall(Open77.chat.send, pid, { author = "CHOOH2", text = message }) end
end

local function argPlayer(source, value)
    local pid = M.playerId(value)
    if not pid or not P.players.name(pid) then
        reply(source, "unknown player id " .. tostring(value))
        return nil
    end
    return pid
end

-- The car nearest to a player (any car: refuelling needs no key).
local function carNear(pid, radius)
    local pos = P.players.position(pid)
    if not pos then return nil, "position_unavailable" end
    local best, bestD
    for _, v in ipairs(P.vehicles.all()) do
        local vp = P.vehicles.position(v)
        local d = vp and M.distance(vp, pos)
        if v.id and d and d <= radius and (v.bucket or 0) == (pos.bucket or 0) and (not bestD or d < bestD) then
            best, bestD = v.id, d
        end
    end
    if not best then return nil, "no_vehicle" end
    return best
end

local function playerLoad(pid)
    if not P.actions.carrying(pid) then return Svc:tell(pid, M.textFor("not_carrying"), "warning") end
    local pos = P.players.position(pid)
    local vid, why = Svc:truckNear(pid, pos, cfg.truckNearM, "put")
    if not vid then return Svc:refuseTo(pid, why) end
    local op, reason = P.actions.carryPutdown(pid, { kind = "vehicle", vehicleId = vid, offset = { x = 0.0, y = -1.5, z = 1.0 } })
    if not op then Svc:refuseTo(pid, reason) end
end

local function playerUnload(pid)
    if P.actions.carrying(pid) then return Svc:tell(pid, M.textFor("carrying"), "warning") end
    local allowed, why = P.jobs.eligible(pid, cfg.eligibility.haul.args)
    if not allowed then return Svc:refuseTo(pid, why) end
    local crate, itemOrWhy = Svc:unloadCrate(pid, nil, P.players.position(pid), cfg.truckNearM, nil)
    if not crate then return Svc:refuseTo(pid, itemOrWhy) end
    local op, reason = P.actions.carryPickup(pid, itemOrWhy)
    if not op then Svc:refuseTo(pid, reason) end
end

local function requestRefuel(pid, vid)
    if not vid then
        local why
        vid, why = carNear(pid, cfg.refuel.reachM)
        if not vid then return nil, why end
    end
    return P.actions.request(pid, "refuel", nil, { data = { vehicleId = vid } })
end

local function describeCrates(subject)
    local out = {}
    for _, crate in ipairs(Svc:cratesOf(subject)) do
        local where = crate.state
        if crate.state == "truck" then where = "in the bed of " .. tostring(crate.plate or crate.meta.where or "?") end
        out[#out + 1] = ("%s (%s)"):format(crate.key, where)
    end
    return out
end

-- Player: /chooh2 [load | unload | refuel | crates]
RegisterCommand("chooh2", function(source, args)
    local pid = M.playerId(source)
    if not pid then return print("[rp_chooh2] /chooh2 is a player command; the console uses chooh2.*") end
    local verb = args and args[1] or ""
    if not Svc.ready then return Svc:tell(pid, M.textFor("chooh2_unavailable"), "warning") end
    if verb == "load" then
        CreateThread(function() playerLoad(pid) end)
    elseif verb == "unload" then
        CreateThread(function() playerUnload(pid) end)
    elseif verb == "refuel" then
        local op, why = requestRefuel(pid, nil)
        if not op then Svc:refuseTo(pid, why) end
    elseif verb == "crates" then
        local subject = L.subjectOf(pid)
        local list = subject and describeCrates(subject) or {}
        Svc:tell(pid, #list > 0 and ("Your crates: " .. table.concat(list, "; ")) or "You have no crate out.", "info")
    else
        Svc:tell(pid, "CHOOH2: farmhands clock in at the farm office and harvest the corn rows (E); crates are " ..
            "carried (E / G) to a truck at the bay or with /chooh2 load; at the refinery, /chooh2 unload or the bay, " ..
            "then put the crate in the intake. Operators run batches, take canisters, sell them at the depot. " ..
            "/chooh2 refuel pours a canister into the car next to you.", "info")
    end
end, false)

-- Operator console (restricted: console, or ACL command.chooh2.*). Explicit player ids; each one
-- drives the same server path as the prompts.
RegisterCommand("chooh2.status", function(source)
    local n = { ground = 0, carried = 0, truck = 0, new = 0, delivered = 0, other = 0 }
    for _, crate in pairs(Svc.crates) do
        local key = n[crate.state] and crate.state or "other"
        n[key] = n[key] + 1
    end
    local doubts, fills = 0, 0
    for _ in pairs(Svc.doubts) do doubts = doubts + 1 end
    for _ in pairs(Svc.pendingFills) do fills = fills + 1 end
    local s = Svc.stats
    reply(source, ("ready=%s stashes=%s crates: ground=%d carried=%d truck=%d new=%d other=%d | harvests=%d loads=%d " ..
        "unloads=%d deliveries=%d runs=%d collected=%d sales=%d refuels=%d refusals=%d doubts=%d (open %d) fills=%d")
        :format(tostring(Svc.ready), tostring(Svc.stashesOpen), n.ground, n.carried, n.truck, n.new, n.other,
        s.harvests, s.loads, s.unloads, s.deliveries, s.runs, s.collected, s.sales, s.refuels, s.refusals, s.doubts,
        doubts, fills))
    local intake = L.readLoaded(cfg.accounts.intake)
    local output = L.readLoaded(cfg.accounts.output)
    reply(source, ("intake corn=%s output canisters=%s"):format(
        tostring(type(intake) == "table" and M.countOf(intake, cfg.harvest.item) or "?"),
        tostring(type(output) == "table" and M.countOf(output, "chooh2_canister") or "?")))
    for _, nodeCfg in ipairs(cfg.nodes) do
        local node = Svc.nodes[nodeCfg.key]
        local summary = node and node.id and P.containers.summary(node.id)
        reply(source, ("row %s id=%s charges=%s/%s depleted=%s"):format(nodeCfg.key, tostring(node and node.id),
            tostring(summary and summary.charges), tostring(summary and summary.maxCharges), tostring(node and node.depleted)))
    end
end, true)

-- chooh2.setup <playerId> <job> [grade]: the job (farmhand, refinery, nomade...) and duty on.
RegisterCommand("chooh2.setup", function(source, args)
    local pid = argPlayer(source, args[1])
    if not pid then return end
    local job = args[2] or cfg.jobs.harvest
    local ok, why = P.jobs.setJob(pid, job, tonumber(args[3]) or 0)
    reply(source, ("setJob %d %s: %s %s"):format(pid, job, tostring(ok), tostring(why or "")))
    local on, dwhy = P.jobs.setDuty(pid, true, { job = job })
    reply(source, ("setDuty %d on: %s %s"):format(pid, tostring(on), tostring(dwhy or "")))
end, true)

-- chooh2.clock <playerId> on|off: duty in the player's own job.
RegisterCommand("chooh2.clock", function(source, args)
    local pid = argPlayer(source, args[1])
    if not pid then return end
    local summary = P.jobs.summary(pid)
    local job = type(summary) == "table" and summary.job or nil
    if not job then return reply(source, ("player %d has no job"):format(pid)) end
    local ok, why = P.jobs.setDuty(pid, args[2] ~= "off", { job = job })
    reply(source, ("duty %d %s (%s): %s %s"):format(pid, args[2] or "on", job, tostring(ok), tostring(why or "")))
end, true)

-- chooh2.truck <playerId> [plate]: that plate's truck out next to the player, or a plated
-- Mackinaw issued by rp_garage when its operator allows it.
RegisterCommand("chooh2.truck", function(source, args)
    local pid = argPlayer(source, args[1])
    if not pid then return end
    if args[2] then
        local id, why = P.garage.spawnOwned(pid, args[2])
        reply(source, id and ("plate %s out as vehicle %s next to player %d"):format(args[2], tostring(id), pid)
            or ("spawnOwned refused: %s"):format(tostring(why)))
        return
    end
    local res, why = P.garage.labIssue(pid, "Vehicle.v_standard3_thorton_mackinaw_player", { label = "Farm truck" })
    if type(res) == "table" then
        reply(source, ("issued plate %s vehicle %s to player %d"):format(tostring(res.plate), tostring(res.vehicleId), pid))
        return
    end
    reply(source, ("rp_garage issued no truck (%s). Buy a Thorton Mackinaw at the dealership, then: chooh2.truck %d <plate>")
        :format(tostring(why), pid))
end, true)

local function requestReply(source, what, op, why, info)
    reply(source, op and ("%s: op %s state %s"):format(what, tostring(op.opId), tostring(op.state))
        or ("%s refused: %s (stage %s)"):format(what, tostring(why), tostring(info and info.stage)))
end

-- chooh2.harvest <playerId> <row> [harvest|inspect]
RegisterCommand("chooh2.harvest", function(source, args)
    local pid = argPlayer(source, args[1])
    if not pid then return end
    local key, action = args[2], args[3] or "harvest"
    if not Svc.nodes[key or ""] then return reply(source, "unknown row " .. tostring(key)) end
    local op, why, info = P.actions.request(pid, action, "node_" .. key)
    requestReply(source, action .. " on " .. key, op, why, info)
end, true)

-- chooh2.pickup <playerId> [crateKey]: the nearest ground crate within 3 m, or that one.
RegisterCommand("chooh2.pickup", function(source, args)
    local pid = argPlayer(source, args[1])
    if not pid then return end
    local pos = P.players.position(pid)
    local best, bestD
    for _, crate in pairs(Svc.crates) do
        if crate.state == "ground" and crate.itemId and (args[2] == nil or crate.key == args[2] or crate.id == args[2]) then
            local d = M.distance(pos, crate.meta.at) or 99
            if (args[2] or d <= 3.0) and (not bestD or d < bestD) then best, bestD = crate, d end
        end
    end
    if not best then return reply(source, "no ground crate there") end
    local op, why = P.actions.carryPickup(pid, best.itemId)
    reply(source, op and ("pickup of %s: op %s"):format(best.key, tostring(op.opId)) or ("pickup refused: " .. tostring(why)))
end, true)

-- chooh2.load <playerId> [vehicleId]
RegisterCommand("chooh2.load", function(source, args)
    local pid = argPlayer(source, args[1])
    if not pid then return end
    local vid = M.playerId(args[2])
    if not vid then
        local why
        vid, why = Svc:truckNear(pid, P.players.position(pid), cfg.truckNearM, "put")
        if not vid then return reply(source, "no truck: " .. tostring(why)) end
    end
    local op, why = P.actions.carryPutdown(pid, { kind = "vehicle", vehicleId = vid, offset = { x = 0.0, y = -1.5, z = 1.0 } })
    reply(source, op and ("load on vehicle %d: op %s"):format(vid, tostring(op.opId)) or ("load refused: " .. tostring(why)))
end, true)

-- chooh2.unload <playerId> [vehicleId]
RegisterCommand("chooh2.unload", function(source, args)
    local pid = argPlayer(source, args[1])
    if not pid then return end
    CreateThread(function()
        local crate, itemOrWhy = Svc:unloadCrate(pid, M.playerId(args[2]), P.players.position(pid), cfg.truckNearM, nil)
        if not crate then return reply(source, "unload refused: " .. tostring(itemOrWhy)) end
        local op, why = P.actions.carryPickup(pid, itemOrWhy)
        reply(source, ("unloaded %s; pickup %s"):format(crate.key, op and ("op " .. tostring(op.opId)) or ("refused: " .. tostring(why))))
    end)
end, true)

-- chooh2.deliver <playerId>: puts the carried crate into the intake (stand at the hopper).
RegisterCommand("chooh2.deliver", function(source, args)
    local pid = argPlayer(source, args[1])
    if not pid then return end
    local op, why = P.actions.carryPutdown(pid, { kind = "point", position = cfg.intake.position, yaw = cfg.intake.yaw },
        { data = { intent = "intake" } })
    reply(source, op and ("delivery put-down: op %s"):format(tostring(op.opId)) or ("delivery refused: " .. tostring(why)))
end, true)

-- chooh2.refine / chooh2.collect / chooh2.sell <playerId>: the station prompts.
for command, spec in pairs({
    ["chooh2.refine"] = { action = "refine", target = "control" },
    ["chooh2.gauges"] = { action = "gauges", target = "control" },
    ["chooh2.collect"] = { action = "collect", target = "output_rack" },
    ["chooh2.sell"] = { action = "sell", target = "depot_counter" },
}) do
    RegisterCommand(command, function(source, args)
        local pid = argPlayer(source, args[1])
        if not pid then return end
        local op, why, info = P.actions.request(pid, spec.action, spec.target)
        requestReply(source, spec.action, op, why, info)
    end, true)
end

-- chooh2.refuel <playerId> [vehicleId]: the nearest car within reach, or that one.
RegisterCommand("chooh2.refuel", function(source, args)
    local pid = argPlayer(source, args[1])
    if not pid then return end
    local op, why, info = requestRefuel(pid, M.playerId(args[2]))
    requestReply(source, "refuel", op, why, info)
end, true)

-- chooh2.drop <playerId>: force a drop (as a death would).
RegisterCommand("chooh2.drop", function(source, args)
    local pid = argPlayer(source, args[1])
    if not pid then return end
    local ok, why = P.actions.carryDrop(pid, "console_drop")
    reply(source, ok and "dropped" or ("drop refused: " .. tostring(why)))
end, true)

-- chooh2.reset [row|all]: rows back to full charges, in place (same node id).
RegisterCommand("chooh2.reset", function(source, args)
    local which = args[1] or "all"
    CreateThread(function()
        for key, node in pairs(Svc.nodes) do
            if which == "all" or which == key then
                local state, why = Svc:resetNode(key)
                reply(source, ("row %s: %s"):format(key, state and ("refilled %s to %s/%s"):format(tostring(node.id),
                    tostring(state.charges), tostring(state.maxCharges)) or ("reset refused: " .. tostring(why))))
            end
        end
    end)
end, true)

-- chooh2.give <playerId> <item> <count>: through rp_inventory (canisters to test a sale or a refuel).
RegisterCommand("chooh2.give", function(source, args)
    local pid = argPlayer(source, args[1])
    if not pid then return end
    local item, count = args[2] or "chooh2_canister", M.playerId(args[3]) or 1
    if not cfg.items[item] then return reply(source, "unknown item " .. tostring(item)) end
    CreateThread(function()
        local receipt, why = P.inventory.addAsync(pid, item, count, nil, { opId = L.newOpId("give") })
        reply(source, ("give %d %s to %d: %s %s"):format(count, item, pid, receipt and "ok" or "refused", tostring(why or "")))
    end)
end, true)

-- chooh2.stock <count>: corn straight into the intake (minted out of the fields' account).
RegisterCommand("chooh2.stock", function(source, args)
    local count = M.playerId(args[1]) or cfg.refine.cornIn
    CreateThread(function()
        local receipt, why = L.transfer({ opId = L.newOpId("stock"), kind = "chooh2.stock", reason = "console stock",
            lines = { { item = cfg.harvest.item, count = count, from = cfg.accounts.fields, to = cfg.accounts.intake } } })
        reply(source, ("stock %d corn into the intake: %s %s"):format(count, receipt and "ok" or "refused", tostring(why or "")))
    end)
end, true)

-- chooh2.state <playerId>: crates (where, contents), canisters, cash, society, receipts.
RegisterCommand("chooh2.state", function(source, args)
    local pid = argPlayer(source, args[1])
    if not pid then return end
    CreateThread(function()
        local subject, why = L.subjectOf(pid)
        if not subject then return reply(source, "no subject: " .. tostring(why)) end
        reply(source, ("player %d subject %s"):format(pid, subject))
        for _, crate in ipairs(Svc:cratesOf(subject)) do
            local snap = L.read(crate.id)
            reply(source, ("crate %s state=%s token=%s at=%s plate=%s corn=%d deliver=%s"):format(
                crate.id, crate.state, tostring(M.tokenHere(snap, crate.iid) and "hold" or "away"),
                crate.meta.at and ("%.1f,%.1f,%.1f"):format(crate.meta.at.x, crate.meta.at.y, crate.meta.at.z) or "-",
                tostring(crate.plate or crate.meta.where or "-"), M.countOf(snap, cfg.harvest.item),
                tostring(crate.meta.deliver and crate.meta.deliver.opId or "-")))
        end
        local pockets = L.read("char:" .. subject)
        reply(source, ("pockets canisters=%d corn=%d"):format(M.countOf(pockets, "chooh2_canister"),
            M.countOf(pockets, cfg.harvest.item)))
        local cash = P.economy.balanceOf({ subject = subject })
        local soc = P.economy.balanceOf({ society = cfg.society })
        reply(source, ("cash=%s society %s=%s"):format(tostring(type(cash) == "table" and cash.balance),
            cfg.society, tostring(type(soc) == "table" and soc.balance)))
        for _, entry in ipairs(Svc.receipts[subject] or {}) do
            reply(source, ("receipt %s %s%s: %s"):format(entry.kind, entry.opId, entry.replay and " (replay)" or "", entry.text or ""))
        end
    end)
end, true)
